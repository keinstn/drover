const deviceIdPattern = /^[A-Za-z0-9_-]{1,128}$/;
const pairingCodePattern = /^[A-Za-z0-9_-]{32,128}$/;
const paneIdPattern = /^[^\s/][^\r\n/]{0,255}$/;

const platforms = ["android", "ios", "macos"] as const;

export type DevicePlatform = (typeof platforms)[number];

export interface DeviceRegistration {
  deviceId: string;
  fcmToken: string;
  platform: DevicePlatform;
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

  const { fcmToken, platform } = input;
  if (
    typeof fcmToken !== "string" ||
    fcmToken.length < 32 ||
    fcmToken.length > 4096 ||
    !platforms.includes(platform as DevicePlatform)
  ) {
    return null;
  }
  return { deviceId, fcmToken, platform: platform as DevicePlatform };
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
  const agentName =
    typeof input.agentName === "string"
      ? sanitizeSingleLine(input.agentName)
      : "";
  return {
    hostId: input.hostId,
    paneId: input.paneId,
    eventId: input.eventId,
    ...(agentName.length > 0 ? { agentName } : {}),
  };
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
