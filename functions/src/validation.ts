const deviceIdPattern = /^[A-Za-z0-9_-]{1,128}$/;
const pairingCodePattern = /^[A-Za-z0-9_-]{32,128}$/;
const paneIdPattern = /^[^\s/][^\r\n/]{0,255}$/;

const platforms = ["android", "ios", "macos"] as const;
const notificationEvents = ["blocked", "done"] as const;

export type DevicePlatform = (typeof platforms)[number];
export type NotificationEvent = (typeof notificationEvents)[number];

export interface DeviceRegistration {
  deviceId: string;
  fcmToken: string;
  platform: DevicePlatform;
  notifyOnBlocked?: boolean;
  notifyOnDone?: boolean;
}

export interface PairingCodeRequest {
  hostId: string;
}

export interface PairingCompletion {
  pairingCode: string;
}

export interface BlockedNotification {
  hostId: string;
  paneId: string;
  eventId: string;
  agentName?: string;
  status: NotificationEvent;
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value != null
    ? (value as Record<string, unknown>)
    : null;
}

export function parseDeviceId(value: unknown): string | null {
  const input = record(value);
  if (input == null) {
    return null;
  }
  const { deviceId } = input;
  return typeof deviceId === "string" && deviceIdPattern.test(deviceId)
    ? deviceId
    : null;
}

export function parseDeviceRegistration(
  value: unknown,
): DeviceRegistration | null {
  const deviceId = parseDeviceId(value);
  const input = record(value);
  if (deviceId == null || input == null) {
    return null;
  }

  const { fcmToken, platform, notifyOnBlocked, notifyOnDone } = input;
  if (
    typeof fcmToken !== "string" ||
    fcmToken.length < 32 ||
    fcmToken.length > 4096 ||
    !platforms.includes(platform as DevicePlatform) ||
    (notifyOnBlocked != null && typeof notifyOnBlocked !== "boolean") ||
    (notifyOnDone != null && typeof notifyOnDone !== "boolean")
  ) {
    return null;
  }
  return {
    deviceId,
    fcmToken,
    platform: platform as DevicePlatform,
    ...(notifyOnBlocked != null ? { notifyOnBlocked } : {}),
    ...(notifyOnDone != null ? { notifyOnDone } : {}),
  };
}

export function parsePairingCodeRequest(
  value: unknown,
): PairingCodeRequest | null {
  const input = record(value);
  if (input == null || typeof input.hostId !== "string") {
    return null;
  }
  return deviceIdPattern.test(input.hostId) ? { hostId: input.hostId } : null;
}

export function parsePairingCompletion(
  value: unknown,
): PairingCompletion | null {
  const input = record(value);
  if (input == null || typeof input.pairingCode !== "string") {
    return null;
  }
  return pairingCodePattern.test(input.pairingCode)
    ? { pairingCode: input.pairingCode }
    : null;
}

export function parseBlockedNotification(
  value: unknown,
): BlockedNotification | null {
  const input = record(value);
  if (
    input == null ||
    !isDocumentId(input.hostId) ||
    !isDocumentId(input.eventId) ||
    typeof input.paneId !== "string" ||
    !paneIdPattern.test(input.paneId)
  ) {
    return null;
  }
  if (
    input.agentName != null &&
    (typeof input.agentName !== "string" || input.agentName.length > 256)
  ) {
    return null;
  }
  if (
    input.status != null &&
    !notificationEvents.includes(input.status as NotificationEvent)
  ) {
    return null;
  }
  const agentName =
    typeof input.agentName === "string"
      ? sanitizeSingleLine(input.agentName)
      : "";
  return {
    hostId: input.hostId,
    paneId: input.paneId,
    eventId: input.eventId,
    ...(agentName.length > 0 ? { agentName } : {}),
    status: (input.status as NotificationEvent | undefined) ?? "blocked",
  };
}

export function notificationContent(
  status: NotificationEvent,
  agentName: string,
): { title: string; body: string; event: NotificationEvent } {
  return status === "done"
    ? {
        title: "Agent finished",
        body: `${agentName} finished.`,
        event: "done",
      }
    : {
        title: "Agent needs your input",
        body: `${agentName} is blocked.`,
        event: "blocked",
      };
}

export function deviceAllowsEvent(
  fields: { notifyOnBlocked?: unknown; notifyOnDone?: unknown },
  event: NotificationEvent,
): boolean {
  // ponytail: asymmetric on purpose — pre-1.0.6 devices send neither field, so
  // "done" fails closed (opt-in) while "blocked" keeps failing open, until no
  // such device remains registered and this can collapse to one check.
  return event === "done"
    ? fields.notifyOnDone === true
    : fields.notifyOnBlocked !== false;
}

// agentName is interpolated into the push-notification body, so collapse CR/LF
// and other whitespace runs into single spaces to stop caller-supplied text
// from faking extra notification lines.
function sanitizeSingleLine(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function isDocumentId(value: unknown): value is string {
  return typeof value === "string" && deviceIdPattern.test(value);
}
