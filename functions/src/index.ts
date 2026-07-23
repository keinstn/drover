import { initializeApp } from "firebase-admin/app";
import {
  type DocumentReference,
  FieldValue,
  getFirestore,
  type QueryDocumentSnapshot,
} from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { setGlobalOptions } from "firebase-functions";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall } from "firebase-functions/v2/https";

import { parseDeviceId, parseDeviceRegistration } from "./validation.js";

initializeApp();

setGlobalOptions({ region: "us-central1", maxInstances: 10 });

const db = getFirestore();
const messaging = getMessaging();
const maxDevicesPerUser = 20;
const testNotificationsPerMinute = 5;

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
  const devices = await db
    .collection("users")
    .doc(uid)
    .collection("devices")
    .get();
  const registrations = tokenRegistrations(devices.docs);

  if (registrations.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "No registered notification devices.",
    );
  }
  await consumeTestNotificationAllowance(uid);

  let successCount = 0;
  let failureCount = 0;
  let removedTokenCount = 0;

  for (let start = 0; start < registrations.length; start += 500) {
    const batch = registrations.slice(
      start,
      Math.min(start + 500, registrations.length),
    );
    const response = await messaging.sendEachForMulticast({
      tokens: batch.map((entry) => entry.token),
      notification: {
        title: "Drover notifications are ready",
        body: "This is a test notification.",
      },
      data: { type: "test" },
      android: {
        priority: "high",
        notification: { channelId: "drover_notifications", sound: "default" },
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

  logger.info("Sent test notification.", {
    uid,
    tokenCount: registrations.length,
    successCount,
    failureCount,
    removedTokenCount,
  });
  return {
    tokenCount: registrations.length,
    successCount,
    failureCount,
    removedTokenCount,
  };
});
