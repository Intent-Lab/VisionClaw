import { spawn as spawnProcess } from "node:child_process";

const DEFAULT_CANDIDATES = [
  "/opt/homebrew/bin/qrencode",
  "/usr/local/bin/qrencode",
  "qrencode",
];
const MAX_URI_CHARACTERS = 8_192;
const MAX_OUTPUT_BYTES = 1024 * 1024;

export async function renderTerminalQRCode(
  uri,
  {
    spawn = spawnProcess,
    candidates = DEFAULT_CANDIDATES,
  } = {},
) {
  if (
    typeof uri !== "string"
    || !uri.startsWith("visionclaw://pair?")
    || uri.length > MAX_URI_CHARACTERS
  ) {
    throw new Error("Pairing QR payload is invalid or too long.");
  }
  let lastError;
  for (const candidate of candidates) {
    try {
      return await renderWith(candidate, uri, spawn);
    } catch (error) {
      lastError = error;
      if (error?.code !== "ENOENT") break;
    }
  }
  throw new Error(
    lastError?.code === "ENOENT"
      ? "qrencode is not installed."
      : "Pairing QR could not be rendered.",
  );
}

function renderWith(command, uri, spawn) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(command, ["-t", "UTF8", "-r", "-"], {
        shell: false,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      reject(error);
      return;
    }
    const chunks = [];
    let length = 0;
    let settled = false;
    const finish = (callback) => {
      if (settled) return;
      settled = true;
      callback();
    };
    child.once("error", (error) => finish(() => reject(error)));
    child.stdout.on("data", (chunk) => {
      length += chunk.length;
      if (length > MAX_OUTPUT_BYTES) {
        child.kill?.("SIGTERM");
        finish(() => reject(new Error("Pairing QR output was too large.")));
        return;
      }
      chunks.push(Buffer.from(chunk));
    });
    child.stderr.on("data", () => {
      // Never surface utility output; it may echo malformed input.
    });
    child.once("close", (code) => finish(() => {
      if (code !== 0) {
        reject(new Error("Pairing QR utility failed."));
        return;
      }
      resolve(Buffer.concat(chunks, length).toString("utf8").trimEnd());
    }));
    child.stdin.end(uri);
  });
}
