import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

const configFileName = "config.json";

export function configPath(configDir) {
  return join(configDir, configFileName);
}

export async function loadConfig(configDir) {
  const path = configPath(configDir);
  let parsed;
  try {
    parsed = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new Error(
        `Drover Notify is not paired. Run bin/pair.mjs with --config-dir ${configDir}.`,
      );
    }
    throw error;
  }
  if (
    typeof parsed?.hostId !== "string" ||
    typeof parsed?.credential !== "string" ||
    typeof parsed?.notificationUrl !== "string"
  ) {
    throw new Error(`Invalid Drover Notify config at ${path}.`);
  }
  return parsed;
}

export async function saveConfig(configDir, config) {
  const path = configPath(configDir);
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporaryPath = `${path}.${process.pid}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(config)}\n`, {
    mode: 0o600,
  });
  await chmod(temporaryPath, 0o600);
  await rename(temporaryPath, path);
  await chmod(path, 0o600);
}
