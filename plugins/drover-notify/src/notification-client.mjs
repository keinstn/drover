const retryDelaysMs = [250, 1000, 4000];

class PermanentRequestError extends Error {}

export async function completePairing({ completionUrl, pairingCode }) {
  const response = await fetch(completionUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairingCode }),
  });
  if (!response.ok) {
    throw new Error(`Pairing failed (${response.status}): ${await response.text()}`);
  }
  const responseBody = await response.json();
  if (
    typeof responseBody?.hostId !== "string" ||
    typeof responseBody?.credential !== "string" ||
    typeof responseBody?.notificationUrl !== "string"
  ) {
    throw new Error("Pairing response is malformed.");
  }
  return responseBody;
}

export async function sendBlockedNotification(config, event) {
  const payload = {
    hostId: config.hostId,
    paneId: event.paneId,
    eventId: event.eventId,
    ...(event.agentName == null ? {} : { agentName: event.agentName }),
  };
  let lastError;
  for (const delay of retryDelaysMs) {
    try {
      const response = await fetch(config.notificationUrl, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${config.credential}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });
      if (response.ok) return;
      if (response.status >= 400 && response.status < 500) {
        throw new PermanentRequestError(
          `Notification request was rejected (${response.status}): ${await response.text()}`,
        );
      }
      lastError = new Error(
        `Notification request failed (${response.status}): ${await response.text()}`,
      );
    } catch (error) {
      if (error instanceof PermanentRequestError) throw error;
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
  throw lastError ?? new Error("Notification request failed.");
}
