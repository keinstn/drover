#!/usr/bin/env node
import { randomUUID } from "node:crypto";

import { loadConfig } from "../src/config.mjs";
import { blockedEventFromEnvironment } from "../src/event.mjs";
import { sendBlockedNotification } from "../src/notification-client.mjs";

const event = blockedEventFromEnvironment(process.env);
if (event == null) process.exit(0);

const configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;
if (typeof configDir !== "string" || configDir.length === 0) {
  throw new Error("HERDR_PLUGIN_CONFIG_DIR is not set.");
}

await sendBlockedNotification(await loadConfig(configDir), {
  ...event,
  eventId: randomUUID(),
});
