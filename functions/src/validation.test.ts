import assert from "node:assert/strict";
import test from "node:test";

import { parseDeviceId, parseDeviceRegistration } from "./validation.js";

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
