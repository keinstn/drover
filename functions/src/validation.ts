const deviceIdPattern = /^[A-Za-z0-9_-]{1,128}$/;

const platforms = ["android", "ios", "macos"] as const;

export type DevicePlatform = (typeof platforms)[number];

export interface DeviceRegistration {
  deviceId: string;
  fcmToken: string;
  platform: DevicePlatform;
}

export function parseDeviceId(value: unknown): string | null {
  if (typeof value !== "object" || value == null) {
    return null;
  }
  const deviceId = (value as Record<string, unknown>).deviceId;
  return typeof deviceId === "string" && deviceIdPattern.test(deviceId)
    ? deviceId
    : null;
}

export function parseDeviceRegistration(
  value: unknown,
): DeviceRegistration | null {
  const deviceId = parseDeviceId(value);
  if (deviceId == null || typeof value !== "object" || value == null) {
    return null;
  }

  const { fcmToken, platform } = value as Record<string, unknown>;
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
