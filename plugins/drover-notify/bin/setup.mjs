#!/usr/bin/env node
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import { saveConfig } from "../src/config.mjs";
import { completePairing } from "../src/notification-client.mjs";

const execFileAsync = promisify(execFile);

function option(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1] ?? null;
}

async function readPairingCode() {
  if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== "function") {
    throw new Error(
      "Run setup.mjs from an interactive terminal to enter the pairing code.",
    );
  }

  process.stdout.write("Pairing code: ");
  process.stdin.setRawMode(true);
  process.stdin.setEncoding("utf8");
  process.stdin.resume();

  return new Promise((resolve, reject) => {
    let code = "";
    const cleanup = () => {
      process.stdin.off("data", onData);
      process.stdin.setRawMode(false);
      process.stdin.pause();
    };
    const onData = (input) => {
      for (const character of input) {
        if (character === "\r" || character === "\n") {
          cleanup();
          process.stdout.write("\n");
          resolve(code);
          return;
        }
        if (character === "\u0003") {
          cleanup();
          reject(new Error("Pairing cancelled."));
          return;
        }
        if (character === "\b" || character === "\u007f") {
          code = code.slice(0, -1);
          continue;
        }
        code += character;
      }
    };
    process.stdin.on("data", onData);
  });
}

const completionUrl = option("--completion-url");
if (completionUrl == null) {
  throw new Error("Usage: setup.mjs --completion-url <url>");
}

const configuredHerdrBin = option("--herdr-bin") ?? process.env.HERDR_BIN_PATH ?? "herdr";
const herdrBin =
  configuredHerdrBin.startsWith("~/") && typeof process.env.HOME === "string"
    ? `${process.env.HOME}/${configuredHerdrBin.slice(2)}`
    : configuredHerdrBin;
const { stdout } = await execFileAsync(herdrBin, [
  "plugin",
  "config-dir",
  "drover.notify",
]);
const configDir = stdout.trim();
if (configDir.length === 0) {
  throw new Error("Herdr did not return a plugin config directory.");
}

const pairingCode = await readPairingCode();
if (pairingCode.length === 0) {
  throw new Error("A pairing code is required.");
}
const pairing = await completePairing({ completionUrl, pairingCode });
await saveConfig(configDir, pairing);
process.stdout.write(`Paired Drover Notify host ${pairing.hostId}.\n`);
