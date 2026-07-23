import assert from "node:assert/strict";
import test from "node:test";

import {
  parseBlockedNotification,
  parseDeviceId,
  parseDeviceRegistration,
  parsePairingCodeRequest,
  parsePairingCompletion,
} from "./validation.js";

void test("accepts a valid device registration", () => {
  assert.deepEqual(
    parseDeviceRegistration({
      deviceId: "9cc2cb08-4d52-4f64-b49b-3580a3edb87b",
      fcmToken: "a".repeat(32),
      platform: "ios",
    }),
    {
      deviceId: "9cc2cb08-4d52-4f64-b49b-3580a3edb87b",
      fcmToken: "a".repeat(32),
      platform: "ios",
    },
  );
});

void test("rejects device IDs that cannot form document paths", () => {
  assert.equal(parseDeviceId({ deviceId: "../other-device" }), null);
});

void test("rejects incomplete and unsupported registrations", () => {
  assert.equal(
    parseDeviceRegistration({
      deviceId: "valid-device",
      fcmToken: "short",
      platform: "ios",
    }),
    null,
  );
  assert.equal(
    parseDeviceRegistration({
      deviceId: "valid-device",
      fcmToken: "a".repeat(32),
      platform: "windows",
    }),
    null,
  );
});

void test("accepts pairing and blocked notification payloads", () => {
  assert.deepEqual(parsePairingCodeRequest({ hostId: "host_123" }), {
    hostId: "host_123",
  });
  assert.deepEqual(parsePairingCompletion({ pairingCode: "a".repeat(43) }), {
    pairingCode: "a".repeat(43),
  });
  assert.deepEqual(
    parseBlockedNotification({
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: "Claude",
    }),
    {
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: "Claude",
    },
  );
});

void test("rejects unsafe pairing and notification payloads", () => {
  assert.equal(parsePairingCodeRequest({ hostId: "../host" }), null);
  assert.equal(parsePairingCompletion({ pairingCode: "short" }), null);
  assert.equal(
    parseBlockedNotification({
      hostId: "host",
      paneId: "../pane",
      eventId: "event",
    }),
    null,
  );
});
