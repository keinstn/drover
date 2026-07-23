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
import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";

import {
  parseBlockedNotification,
  parseDeviceId,
  parseDeviceRegistration,
  parsePairingCodeRequest,
  parsePairingCompletion,
} from "./validation.js";

initializeApp();

setGlobalOptions({ region: "us-central1", maxInstances: 10 });

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
): TokenRegistration[] {
  const refsByToken = new Map<string, DocumentReference[]>();
  for (const document of devices) {
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
}

async function deliverNotification(
  uid: string,
  notification: { title: string; body: string },
  data: Record<string, string>,
): Promise<NotificationDelivery> {
  const devices = await db
    .collection("users")
    .doc(uid)
    .collection("devices")
    .get();
  const registrations = tokenRegistrations(devices.docs);

  let successCount = 0;
  let failureCount = 0;
  let removedTokenCount = 0;
  let retryableFailureCount = 0;

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

export const registerDevice = onCall(async (request) => {
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
        ...(existing.exists ? {} : { createdAt: FieldValue.serverTimestamp() }),
      },
      { merge: true },
    );
  });

  return { deviceId: registration.deviceId };
});

export const unregisterDevice = onCall(async (request) => {
  const uid = requireUid(request.auth);
  const deviceId = parseDeviceId(request.data);
  if (deviceId == null) {
    throw new HttpsError("invalid-argument", "Invalid device ID.");
  }

  await deviceRef(uid, deviceId).delete();
  return { deviceId };
});

export const sendTestNotification = onCall(async (request) => {
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
});

export const createPairingCode = onCall(async (request) => {
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
});

export const revokeHost = onCall(async (request) => {
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
      const delivery = await deliverNotification(
        uid,
        {
          title: "Agent needs your input",
          body: `${agentName} is blocked.`,
        },
        {
          event: "blocked",
          eventId: notification.eventId,
          hostId: notification.hostId,
          paneId: notification.paneId,
        },
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
        ...delivery,
      });
      response.status(200).json({ duplicate: false, ...delivery });
    } catch (error) {
      await eventRef.delete();
      throw error;
    }
  },
);
