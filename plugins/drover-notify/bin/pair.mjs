#!/usr/bin/env node
import { readFile } from "node:fs/promises";

import { saveConfig } from "../src/config.mjs";
import { completePairing } from "../src/notification-client.mjs";

function option(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1] ?? null;
}

const completionUrl = option("--completion-url");
const configDir = option("--config-dir");
if (completionUrl == null || configDir == null) {
  throw new Error(
    "Usage: pair.mjs --completion-url <url> --config-dir <dir> < pairing-code.txt",
  );
}

const pairingCode = (await readFile(0, "utf8")).trim();
if (pairingCode.length === 0) {
  throw new Error("A pairing code must be provided through standard input.");
}

const pairing = await completePairing({ completionUrl, pairingCode });
await saveConfig(configDir, pairing);
process.stdout.write(`Paired Drover Notify host ${pairing.hostId}.\n`);
