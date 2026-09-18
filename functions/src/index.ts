import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { initializeApp } from "firebase-admin/app";
import {
  type DocumentReference,
  FieldValue,
  getFirestore,
  type QueryDocumentSnapshot,
  Timestamp,
} from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { setGlobalOptions } from "firebase-functions";
import * as logger from "firebase-functions/logger";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";

import {
  deviceAllowsEvent,
  type NotificationEvent,
  notificationContent,
  parseBlockedNotification,
  parseDeviceId,
  parseDeviceRegistration,
  parsePairingCodeRequest,
  parsePairingCompletion,
  parseVoiceSessionId,
} from "./validation.js";
import {
  debitedMint,
  voiceCallCost,
  voiceMintDecision,
  walletCredits,
} from "./wallet.js";

initializeApp();

// maxInstances x concurrency is the in-flight request ceiling: 10 x 10 = 100.
// Pinned explicitly instead of inheriting the platform default (80 requests per
// instance) so the ceiling is visible here and a flood against the two publicly
// invokable onRequest endpoints stays bounded.
setGlobalOptions({
  region: "us-central1",
  maxInstances: 10,
  concurrency: 10,
});

const db = getFirestore();
const messaging = getMessaging();
const maxDevicesPerUser = 20;
const testNotificationsPerMinute = 5;
const pairingCodeLifetimeMs = 10 * 60 * 1000;
const eventDeduplicationLifetimeMs = 24 * 60 * 60 * 1000;
const functionsBaseUrl = `https://us-central1-${process.env.GCLOUD_PROJECT}.cloudfunctions.net`;
const retryableFcmFailureCodes = new Set([
  "messaging/internal-error",
  "messaging/server-unavailable",
  "messaging/unknown-error",
]);

interface TokenRegistration {
  token: string;
  refs: DocumentReference[];
}

function requireUid(auth: { uid: string } | undefined): string {
  if (auth == null) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }
  return auth.uid;
}

function deviceRef(uid: string, deviceId: string) {
  return db.collection("users").doc(uid).collection("devices").doc(deviceId);
}

function hostRef(hostId: string) {
  return db.collection("hosts").doc(hostId);
}

function pairingCodeRef(pairingCode: string) {
  return db.collection("pairingCodes").doc(secretHash(pairingCode));
}

function secretHash(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function matchingSecret(expectedHash: unknown, value: string): boolean {
  if (typeof expectedHash !== "string") return false;
  const expected = Buffer.from(expectedHash, "hex");
  const actual = Buffer.from(secretHash(value), "hex");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

function tokenRegistrations(
  devices: QueryDocumentSnapshot[],
  eventKind?: NotificationEvent,
): TokenRegistration[] {
  const refsByToken = new Map<string, DocumentReference[]>();
  for (const document of devices) {
    if (eventKind != null && !deviceAllowsEvent(document.data(), eventKind)) {
      continue;
    }
    const token = document.get("fcmToken");
    if (typeof token !== "string" || token.length === 0) {
      continue;
    }
    const refs = refsByToken.get(token) ?? [];
    refs.push(document.ref);
    refsByToken.set(token, refs);
  }
  return Array.from(refsByToken, ([token, refs]) => ({ token, refs }));
}

async function removeInvalidTokenRegistrations(
  registrations: TokenRegistration[],
): Promise<number> {
  return db.runTransaction(async (transaction) => {
    const tokenRefs = registrations.flatMap((registration) =>
      registration.refs.map((ref) => ({ token: registration.token, ref })),
    );
    const currentDocuments = await Promise.all(
      tokenRefs.map(({ ref }) => transaction.get(ref)),
    );

    let deletedCount = 0;
    for (let index = 0; index < tokenRefs.length; index += 1) {
      if (currentDocuments[index].get("fcmToken") === tokenRefs[index].token) {
        transaction.delete(tokenRefs[index].ref);
        deletedCount += 1;
      }
    }
    return deletedCount;
  });
}

interface NotificationDelivery {
  tokenCount: number;
  successCount: number;
  failureCount: number;
  removedTokenCount: number;
  retryableFailureCount: number;
  failureCodes: string[];
}

async function deliverNotification(
  uid: string,
  notification: { title: string; body: string },
  data: Record<string, string>,
  eventKind?: NotificationEvent,
): Promise<NotificationDelivery> {
  const devices = await db
    .collection("users")
    .doc(uid)
    .collection("devices")
    .get();
  const registrations = tokenRegistrations(devices.docs, eventKind);

  let successCount = 0;
  let failureCount = 0;
  let removedTokenCount = 0;
  let retryableFailureCount = 0;
  const failureCodes = new Set<string>();

  for (let start = 0; start < registrations.length; start += 500) {
    const batch = registrations.slice(
      start,
      Math.min(start + 500, registrations.length),
    );
    const response = await messaging.sendEachForMulticast({
      tokens: batch.map((entry) => entry.token),
      notification,
      data,
      android: {
        priority: "high",
        notification: {
          channelId: "drover_notifications",
          sound: "default",
        },
      },
      apns: { payload: { aps: { sound: "default" } } },
    });

    successCount += response.successCount;
    failureCount += response.failureCount;

    const invalidRegistrations: TokenRegistration[] = [];
    for (let index = 0; index < response.responses.length; index += 1) {
      const result = response.responses[index];
      const code = result.error?.code;
      if (!result.success && code != null) {
        failureCodes.add(code);
      }
      if (
        !result.success &&
        code != null &&
        retryableFcmFailureCodes.has(code)
      ) {
        retryableFailureCount += 1;
      }
      if (
        !result.success &&
        (code === "messaging/invalid-registration-token" ||
          code === "messaging/registration-token-not-registered")
      ) {
        invalidRegistrations.push(batch[index]);
      }
    }

    if (invalidRegistrations.length > 0) {
      removedTokenCount +=
        await removeInvalidTokenRegistrations(invalidRegistrations);
    }
  }

  return {
    tokenCount: registrations.length,
    successCount,
    failureCount,
    removedTokenCount,
    retryableFailureCount,
    failureCodes: Array.from(failureCodes),
  };
}

async function consumeTestNotificationAllowance(uid: string): Promise<void> {
  const ref = db
    .collection("users")
    .doc(uid)
    .collection("_rateLimits")
    .doc("sendTestNotification");
  const now = Date.now();
  const windowDurationMs = 60_000;

  await db.runTransaction(async (transaction) => {
    const current = await transaction.get(ref);
    const windowStartedAt = current.get("windowStartedAt");
    const requestCount = current.get("requestCount");
    const validWindowStartedAt =
      typeof windowStartedAt === "number" ? windowStartedAt : now;
    const validRequestCount =
      typeof requestCount === "number" ? requestCount : 0;
    const inCurrentWindow = now - validWindowStartedAt < windowDurationMs;

    if (inCurrentWindow && validRequestCount >= testNotificationsPerMinute) {
      throw new HttpsError(
        "resource-exhausted",
        "Too many test notifications. Try again in a minute.",
      );
    }

    transaction.set(
      ref,
      {
        windowStartedAt: inCurrentWindow ? validWindowStartedAt : now,
        requestCount: inCurrentWindow ? validRequestCount + 1 : 1,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

export const registerDevice = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const uid = requireUid(request.auth);
    const registration = parseDeviceRegistration(request.data);
    if (registration == null) {
      throw new HttpsError("invalid-argument", "Invalid device registration.");
    }

    const ref = deviceRef(uid, registration.deviceId);
    await db.runTransaction(async (transaction) => {
      const [existing, devices, matchingTokens] = await Promise.all([
        transaction.get(ref),
        transaction.get(ref.parent),
        transaction.get(
          ref.parent.where("fcmToken", "==", registration.fcmToken),
        ),
      ]);
      const duplicateTokenDocs = matchingTokens.docs.filter(
        (document) => document.id !== ref.id,
      );
      const deviceCountAfterRegistration =
        devices.size - duplicateTokenDocs.length + (existing.exists ? 0 : 1);
      if (deviceCountAfterRegistration > maxDevicesPerUser) {
        throw new HttpsError(
          "resource-exhausted",
          "Too many registered notification devices.",
        );
      }

      for (const document of duplicateTokenDocs) {
        transaction.delete(document.ref);
      }
      transaction.set(
        ref,
        {
          fcmToken: registration.fcmToken,
          platform: registration.platform,
          updatedAt: FieldValue.serverTimestamp(),
          ...(registration.notifyOnBlocked != null
            ? { notifyOnBlocked: registration.notifyOnBlocked }
            : {}),
          ...(registration.notifyOnDone != null
            ? { notifyOnDone: registration.notifyOnDone }
            : {}),
          ...(existing.exists
            ? {}
            : { createdAt: FieldValue.serverTimestamp() }),
        },
        { merge: true },
      );
    });

    return { deviceId: registration.deviceId };
  },
);

export const unregisterDevice = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const uid = requireUid(request.auth);
    const deviceId = parseDeviceId(request.data);
    if (deviceId == null) {
      throw new HttpsError("invalid-argument", "Invalid device ID.");
    }

    await deviceRef(uid, deviceId).delete();
    return { deviceId };
  },
);

export const sendTestNotification = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const uid = requireUid(request.auth);
    await consumeTestNotificationAllowance(uid);
    const delivery = await deliverNotification(
      uid,
      {
        title: "Drover notifications are ready",
        body: "This is a test notification.",
      },
      { type: "test" },
    );
    if (delivery.tokenCount === 0) {
      throw new HttpsError(
        "failed-precondition",
        "No registered notification devices.",
      );
    }
    if (delivery.successCount === 0 && delivery.retryableFailureCount > 0) {
      throw new HttpsError(
        "unavailable",
        "Notification delivery is temporarily unavailable.",
      );
    }

    logger.info("Sent test notification.", {
      uid,
      ...delivery,
    });
    return delivery;
  },
);

export const createPairingCode = onCall(
  { enforceAppCheck: true },
  async (request) => {
    const uid = requireUid(request.auth);
    const pairing = parsePairingCodeRequest(request.data);
    if (pairing == null) {
      throw new HttpsError("invalid-argument", "Invalid host ID.");
    }

    const existingHost = await hostRef(pairing.hostId).get();
    if (existingHost.exists && existingHost.get("uid") !== uid) {
      throw new HttpsError("permission-denied", "Host ID is already paired.");
    }

    const pairingCode = randomBytes(32).toString("base64url");
    await pairingCodeRef(pairingCode).set({
      uid,
      hostId: pairing.hostId,
      expiresAt: Timestamp.fromMillis(Date.now() + pairingCodeLifetimeMs),
      createdAt: FieldValue.serverTimestamp(),
    });
    return {
      pairingCode,
      hostId: pairing.hostId,
      completionUrl: `${functionsBaseUrl}/completePairing`,
    };
  },
);

export const revokeHost = onCall({ enforceAppCheck: true }, async (request) => {
  const uid = requireUid(request.auth);
  const pairing = parsePairingCodeRequest(request.data);
  if (pairing == null) {
    throw new HttpsError("invalid-argument", "Invalid host ID.");
  }

  const host = await hostRef(pairing.hostId).get();
  if (host.exists && host.get("uid") !== uid) {
    throw new HttpsError("permission-denied", "Host ID is not owned by user.");
  }

  const pairingCodes = await db
    .collection("pairingCodes")
    .where("hostId", "==", pairing.hostId)
    .where("uid", "==", uid)
    .limit(500)
    .get();
  const batch = db.batch();
  batch.delete(hostRef(pairing.hostId));
  for (const pairingCode of pairingCodes.docs) {
    batch.delete(pairingCode.ref);
  }
  await batch.commit();
  return { hostId: pairing.hostId };
});

// The Gemini API key. It stays in Secret Manager, is bound to this one
// function, and never reaches the client or a log line — keeping the key here
// is the whole point of minting server side.
const geminiApiKey = defineSecret("GEMINI_API_KEY");

// How long a minted Live token lives. It must stay LONGER than
// `kVoiceSessionCap` in app/lib/src/voice/voice_session.dart (5 minutes), so
// the session always ends before its token does and no window boundary ever
// falls inside a conversation — on a device the reconnect across one is
// audible as a gap in the talk, which is not worth a finer meter.
//
// So one mint is one call, and that is the unit a wallet will charge for: the
// balance is checked here, once, at the start of a session.
//
// `expireTime` is the only bound that matters. `uses` counts session starts
// and is not consumed by a resumption reconnect, so it bounds nothing
// (measured 2026-09-18, see app/tool/token_probe.dart).
const voiceTokenLifetimeMs = 6 * 60 * 1000;

// How long the token may be used to open a session at all. Short: the app
// connects right after minting, or holds the token for the few seconds until
// the current window ends.
const voiceTokenNewSessionLifetimeMs = 60 * 1000;

// Locked into the token. The model is the cost-relevant field and belongs to
// the server; everything else in the client's setup (system prompt, tools,
// speech config, transcription, context-window compression) stays the
// client's, and `fieldMask` names exactly what is frozen.
//
// Must stay equal to `kVoiceModel` in app/lib/src/voice/voice_transport.dart,
// which the client sends in its own setup: bump one without the other and the
// constrained endpoint refuses every session.
const voiceModel = "models/gemini-3.1-flash-live-preview";

// The wallet and its ledger.
//
// `users/{uid}/wallet` names a collection rather than a document — a Firestore
// document path has an odd number of segments — so the balance lives in the
// one document inside it. `firestore.rules` denies every client read and
// write, so this Function's admin SDK is the only writer and no device can
// read its own balance, let alone change it.
//
// Credits get in by hand for now: edit `credits` here in the Firebase console.
// That leaves no ledger row, so reconciliation shows such a grant as
// unexplained — the real purchase path will write both together.
function walletRef(uid: string) {
  return db.collection("users").doc(uid).collection("wallet").doc("credits");
}

// One immutable row per movement, under an auto-ID: nothing ever rewrites one,
// so the ledger is the history and the wallet is only the running total.
function ledgerRef(uid: string) {
  return db.collection("users").doc(uid).collection("ledger").doc();
}

// ponytail: one document per call and nothing reaps them. A stale one is
// harmless — it is older than the window, so the next mint under that id pays
// — but they accumulate. A Firestore TTL policy on `startedAt` clears them
// without any code here.
function voiceSessionRef(sessionId: string) {
  return db.collection("voiceSessions").doc(sessionId);
}

// Claims one voice call against the balance and says whether it took a credit.
//
// One conversation re-mints — shortly before its token expires, and again
// after a genuine drop — and every one of those carries the session ID the app
// made when the call started. So the first mint pays and the rest are free:
// charging each of them would bill a single conversation several times over.
async function claimVoiceCall(
  uid: string,
  sessionId: string,
): Promise<boolean> {
  const wallet = walletRef(uid);
  const session = voiceSessionRef(sessionId);
  const nowMs = Date.now();
  return db.runTransaction(async (transaction) => {
    const [walletDocument, sessionDocument] = await Promise.all([
      transaction.get(wallet),
      transaction.get(session),
    ]);
    const startedAt = sessionDocument.get("startedAt");
    const credits = walletDocument.get("credits");
    const decision = voiceMintDecision({
      uid,
      credits,
      session: sessionDocument.exists
        ? {
            uid: sessionDocument.get("uid"),
            startedAtMs:
              startedAt instanceof Timestamp ? startedAt.toMillis() : null,
          }
        : null,
      nowMs,
    });
    if (decision === "reuse") {
      return false;
    }
    if (decision === "foreign") {
      throw new HttpsError(
        "permission-denied",
        "Voice session ID belongs to another account.",
      );
    }
    if (decision === "empty") {
      throw new HttpsError("resource-exhausted", "No voice credits left.");
    }

    transaction.set(
      wallet,
      {
        credits: walletCredits(credits) - voiceCallCost,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    transaction.set(ledgerRef(uid), {
      type: "voiceCall",
      credits: -voiceCallCost,
      sessionId,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.set(session, { uid, startedAt: Timestamp.fromMillis(nowMs) });
    return true;
  });
}

// Hands one credit back when the mint that it paid for failed.
//
// The session document goes with it: left behind, it would make the retry on
// the same session ID a free mint, which is the double charge's mirror image.
async function refundVoiceCall(uid: string, sessionId: string): Promise<void> {
  const batch = db.batch();
  batch.set(
    walletRef(uid),
    {
      credits: FieldValue.increment(voiceCallCost),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  batch.set(ledgerRef(uid), {
    type: "voiceCallRefund",
    credits: voiceCallCost,
    sessionId,
    createdAt: FieldValue.serverTimestamp(),
  });
  batch.delete(voiceSessionRef(sessionId));
  await batch.commit();
}

// Mints a short-lived Gemini Live API token for a signed-in app install.
//
// Auth and App Check are verified by the callable itself; the balance is
// checked here, and one call costs `voiceCallCost`.
//
// Over REST the constraint field is `bidiGenerateContentSetup` plus a
// `fieldMask`; the documented `liveConnectConstraints` is the SDK name and a
// 400 here (measured 2026-09-18).
export const mintVoiceToken = onCall(
  { enforceAppCheck: true, secrets: [geminiApiKey] },
  async (request) => {
    const uid = requireUid(request.auth);
    const sessionId = parseVoiceSessionId(request.data);
    if (sessionId == null) {
      throw new HttpsError("invalid-argument", "Invalid voice session ID.");
    }
    return debitedMint(
      () => claimVoiceCall(uid, sessionId),
      () => mintLiveToken(),
      async () => {
        // The mint's own failure is what the caller should see, so a failed
        // compensation is logged rather than thrown. It means one lost credit.
        await refundVoiceCall(uid, sessionId).catch((error: unknown) => {
          logger.error("Returning a voice credit failed.", {
            uid,
            sessionId,
            error,
          });
        });
      },
    );
  },
);

async function mintLiveToken(): Promise<{ token: string; expireTime: string }> {
  const expireTime = new Date(Date.now() + voiceTokenLifetimeMs).toISOString();
  const response = await fetch(
    "https://generativelanguage.googleapis.com/v1alpha/auth_tokens",
    {
      method: "POST",
      headers: {
        "x-goog-api-key": geminiApiKey.value(),
        "content-type": "application/json",
      },
      body: JSON.stringify({
        uses: 1,
        expireTime,
        newSessionExpireTime: new Date(
          Date.now() + voiceTokenNewSessionLifetimeMs,
        ).toISOString(),
        bidiGenerateContentSetup: {
          model: voiceModel,
          generationConfig: { responseModalities: ["AUDIO"] },
        },
        fieldMask: "model,generationConfig.responseModalities",
      }),
    },
  );
  if (!response.ok) {
    // Status only. The error body echoes the request, and nothing in it is
    // worth logging next to the risk of logging the key.
    logger.error("Minting a voice token failed.", {
      status: response.status,
    });
    throw new HttpsError("unavailable", "Could not mint a voice token.");
  }
  const minted = (await response.json()) as {
    name?: unknown;
    expireTime?: unknown;
  };
  if (typeof minted.name !== "string" || minted.name.length === 0) {
    throw new HttpsError("unavailable", "Could not mint a voice token.");
  }
  // The token name is a bearer credential; it is returned, never logged.
  return {
    token: minted.name,
    expireTime:
      typeof minted.expireTime === "string" ? minted.expireTime : expireTime,
  };
}

function requestBody(request: { body: unknown }): unknown {
  return request.body;
}

function bearerToken(request: { get(name: string): string | undefined }) {
  const authorization = request.get("Authorization");
  return authorization?.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : null;
}

function requestError(
  response: { status(status: number): { json(value: object): void } },
  status: number,
  message: string,
) {
  response.status(status).json({ error: message });
}

export const completePairing = onRequest(
  { cors: false },
  async (request, response) => {
    if (request.method !== "POST") {
      requestError(response, 405, "Method not allowed.");
      return;
    }
    const completion = parsePairingCompletion(requestBody(request));
    if (completion == null) {
      requestError(response, 400, "Invalid pairing code.");
      return;
    }

    const credential = randomBytes(32).toString("base64url");
    const pairingRef = pairingCodeRef(completion.pairingCode);
    let hostId: string;
    try {
      hostId = await db.runTransaction(async (transaction) => {
        const pairing = await transaction.get(pairingRef);
        const expiresAt = pairing.get("expiresAt");
        const pairedHostId = pairing.get("hostId");
        const uid = pairing.get("uid");
        if (
          !pairing.exists ||
          !(expiresAt instanceof Timestamp) ||
          expiresAt.toMillis() < Date.now() ||
          typeof pairedHostId !== "string" ||
          typeof uid !== "string"
        ) {
          throw new HttpsError(
            "failed-precondition",
            "Pairing code is invalid.",
          );
        }

        const ref = hostRef(pairedHostId);
        const existingHost = await transaction.get(ref);
        if (existingHost.exists && existingHost.get("uid") !== uid) {
          throw new HttpsError(
            "permission-denied",
            "Host ID is already paired.",
          );
        }
        transaction.delete(pairingRef);
        transaction.set(
          ref,
          {
            uid,
            credentialHash: secretHash(credential),
            updatedAt: FieldValue.serverTimestamp(),
            ...(existingHost.exists
              ? {}
              : { createdAt: FieldValue.serverTimestamp() }),
          },
          { merge: true },
        );
        return pairedHostId;
      });
    } catch (error) {
      if (error instanceof HttpsError) {
        requestError(response, 400, error.message);
        return;
      }
      throw error;
    }

    response.status(200).json({
      hostId,
      credential,
      notificationUrl: `${functionsBaseUrl}/sendBlockedNotification`,
    });
  },
);

async function authorizeHost(
  hostId: string,
  credential: string,
): Promise<string | null> {
  const host = await hostRef(hostId).get();
  if (!host.exists || !matchingSecret(host.get("credentialHash"), credential)) {
    return null;
  }
  const uid = host.get("uid");
  return typeof uid === "string" ? uid : null;
}

export const sendBlockedNotification = onRequest(
  { cors: false },
  async (request, response) => {
    if (request.method !== "POST") {
      requestError(response, 405, "Method not allowed.");
      return;
    }
    const notification = parseBlockedNotification(requestBody(request));
    const credential = bearerToken(request);
    if (notification == null || credential == null) {
      requestError(response, 400, "Invalid notification request.");
      return;
    }

    const uid = await authorizeHost(notification.hostId, credential);
    if (uid == null) {
      requestError(response, 401, "Unauthorized.");
      return;
    }

    const eventRef = hostRef(notification.hostId)
      .collection("events")
      .doc(notification.eventId);
    const claimed = await db.runTransaction(async (transaction) => {
      const existing = await transaction.get(eventRef);
      if (existing.exists) return false;
      transaction.create(eventRef, {
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(
          Date.now() + eventDeduplicationLifetimeMs,
        ),
      });
      return true;
    });
    if (!claimed) {
      response.status(200).json({ duplicate: true });
      return;
    }

    try {
      const agentName = notification.agentName ?? "An agent";
      const content = notificationContent(notification.status, agentName);
      const delivery = await deliverNotification(
        uid,
        { title: content.title, body: content.body },
        {
          event: content.event,
          eventId: notification.eventId,
          hostId: notification.hostId,
          paneId: notification.paneId,
        },
        content.event,
      );
      if (delivery.successCount === 0 && delivery.retryableFailureCount > 0) {
        throw new HttpsError(
          "unavailable",
          "Notification delivery is temporarily unavailable.",
        );
      }
      logger.info("Sent blocked notification.", {
        hostId: notification.hostId,
        paneId: notification.paneId,
        eventId: notification.eventId,
        status: notification.status,
        ...delivery,
      });
      response.status(200).json({ duplicate: false, ...delivery });
    } catch (error) {
      await eventRef.delete();
      throw error;
    }
  },
);
