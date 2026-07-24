import {
  chmod,
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { join } from "node:path";

import { isPrivateIPv4 } from "./network-endpoint.mjs";
import {
  canonicalJSONString,
  parseCanonicalJSON,
} from "./security.mjs";

const FILENAME = "runtime.json";

export async function writeRuntimeRecord({
  stateDirectory,
  value,
}) {
  validate(value);
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  await chmod(stateDirectory, 0o700);
  const path = join(stateDirectory, FILENAME);
  const temporaryPath = `${path}.${process.pid}.${Date.now()}.tmp`;
  try {
    await writeFile(temporaryPath, canonicalJSONString(value), { mode: 0o600 });
    await chmod(temporaryPath, 0o600);
    await rename(temporaryPath, path);
    await chmod(path, 0o600);
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

export async function readRuntimeRecord({ stateDirectory }) {
  try {
    const raw = await readFile(join(stateDirectory, FILENAME), "utf8");
    const value = parseCanonicalJSON(raw);
    validate(value);
    return value;
  } catch {
    throw new Error("VisionClaw broker is not running or its state is invalid.");
  }
}

export async function removeRuntimeRecord({ stateDirectory }) {
  await rm(join(stateDirectory, FILENAME), { force: true });
}

export function runtimeRecordIsLive(
  record,
  { isProcessAlive = defaultIsProcessAlive } = {},
) {
  try {
    validate(record);
    return isProcessAlive(record.pid) === true;
  } catch {
    return false;
  }
}

function validate(value) {
  const expected = ["brokerID", "host", "pid", "port", "startedAt"];
  if (
    !value
    || typeof value !== "object"
    || Array.isArray(value)
    || Object.keys(value).sort().join("\0") !== expected.join("\0")
    || !/^broker_[A-Za-z0-9_-]{32,128}$/.test(value.brokerID)
    || !isSafeHost(value.host)
    || !Number.isSafeInteger(value.pid)
    || value.pid < 1
    || !Number.isSafeInteger(value.port)
    || value.port < 1
    || value.port > 65_535
    || !Number.isSafeInteger(value.startedAt)
    || value.startedAt < 1
  ) {
    throw new Error("Broker runtime record is invalid.");
  }
}

function isSafeHost(host) {
  return host === "127.0.0.1" || host === "::1" || isPrivateIPv4(host);
}

function defaultIsProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}
