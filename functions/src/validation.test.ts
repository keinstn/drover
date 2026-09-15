import assert from "node:assert/strict";
import test from "node:test";

import {
  deviceAllowsEvent,
  notificationContent,
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
      status: "blocked",
    },
  );
});

void test("accepts an explicit done status and rejects unknown ones", () => {
  assert.deepEqual(
    parseBlockedNotification({
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      status: "done",
    }),
    {
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      status: "done",
    },
  );
  assert.equal(
    parseBlockedNotification({
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      status: "finished",
    }),
    null,
  );
});

void test("maps status to push content", () => {
  assert.deepEqual(notificationContent("blocked", "Claude"), {
    title: "Agent needs your input",
    body: "Claude is blocked.",
    event: "blocked",
  });
  assert.deepEqual(notificationContent("done", "Claude"), {
    title: "Agent finished",
    body: "Claude finished.",
    event: "done",
  });
});

void test("accepts per-device notification preferences and rejects non-booleans", () => {
  assert.deepEqual(
    parseDeviceRegistration({
      deviceId: "valid-device",
      fcmToken: "a".repeat(32),
      platform: "ios",
      notifyOnBlocked: false,
      notifyOnDone: true,
    }),
    {
      deviceId: "valid-device",
      fcmToken: "a".repeat(32),
      platform: "ios",
      notifyOnBlocked: false,
      notifyOnDone: true,
    },
  );
  assert.equal(
    parseDeviceRegistration({
      deviceId: "valid-device",
      fcmToken: "a".repeat(32),
      platform: "ios",
      notifyOnBlocked: "false",
    }),
    null,
  );
});

void test("deviceAllowsEvent: blocked fails open, done requires opt-in", () => {
  // Devices registered before the preference switches existed send neither
  // field. Blocked must still fire for them — collapsing these two rules into
  // one uniform check silently kills a shipped feature.
  assert.equal(deviceAllowsEvent({}, "blocked"), true);
  assert.equal(deviceAllowsEvent({}, "done"), false);
  assert.equal(
    deviceAllowsEvent(
      { notifyOnBlocked: false, notifyOnDone: true },
      "blocked",
    ),
    false,
  );
  assert.equal(
    deviceAllowsEvent({ notifyOnBlocked: false, notifyOnDone: true }, "done"),
    true,
  );
  assert.equal(deviceAllowsEvent({ notifyOnDone: false }, "blocked"), true);
});

void test("collapses whitespace runs in agent names", () => {
  assert.deepEqual(
    parseBlockedNotification({
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: "Claude\r\nAn agent is blocked.\r\nClaude",
    }),
    {
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: "Claude An agent is blocked. Claude",
      status: "blocked",
    },
  );
  assert.deepEqual(
    parseBlockedNotification({
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: "  codex\tcli  ",
    }),
    {
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: "codex cli",
      status: "blocked",
    },
  );
});

void test("drops agent names that sanitize to nothing", () => {
  assert.deepEqual(
    parseBlockedNotification({
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: " \r\n\t ",
    }),
    {
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      status: "blocked",
    },
  );
});

void test("bounds agent name length before sanitizing", () => {
  assert.equal(
    parseBlockedNotification({
      hostId: "host_123",
      paneId: "workspace:pane",
      eventId: "event_123",
      agentName: `claude${" ".repeat(251)}codex`,
    }),
    null,
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
