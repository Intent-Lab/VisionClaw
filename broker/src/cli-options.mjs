import { canonicalJSONString } from "./security.mjs";

const DEFAULT_PORT = 38_443;

export function parseCLIOptions(argv) {
  const [command, ...rawArguments] = argv;
  if (!["start", "pair", "status", "pairings", "revoke"].includes(command)) {
    throw usageError();
  }
  const flags = [...rawArguments];
  let pairingReference = null;
  if (command === "revoke") {
    pairingReference = flags.shift();
    if (
      !/^vcp_[A-Za-z0-9_-]{43}$/.test(String(pairingReference))
    ) {
      throw usageError();
    }
  }
  let port = DEFAULT_PORT;
  let lan = false;
  let sawPort = false;
  let sawLAN = false;

  for (let index = 0; index < flags.length; index += 1) {
    const flag = flags[index];
    if (flag === "--lan") {
      if (command !== "start" || sawLAN) {
        throw new Error("Unknown or duplicate flag. " + usageText());
      }
      sawLAN = true;
      lan = true;
      continue;
    }
    if (flag === "--port" || flag.startsWith("--port=")) {
      if (sawPort) {
        throw new Error("Duplicate port flag. " + usageText());
      }
      sawPort = true;
      const value = flag === "--port"
        ? flags[++index]
        : flag.slice("--port=".length);
      port = parsePort(value);
      continue;
    }
    throw new Error(`Unknown flag ${String(flag)}. ${usageText()}`);
  }

  if (command === "start") {
    return {
      command,
      host: lan ? "0.0.0.0" : "127.0.0.1",
      port,
    };
  }
  if (command === "revoke") {
    return { command, pairingReference, port };
  }
  return { command, port };
}

export function formatPairingURI(offer) {
  assertPairingOffer(offer);
  const payload = Buffer.from(canonicalJSONString(offer)).toString("base64url");
  const url = new URL("visionclaw://pair");
  url.searchParams.set("payload", payload);
  return url.toString();
}

function parsePort(value) {
  if (!/^[0-9]{1,5}$/.test(String(value))) {
    throw new Error("Broker port is invalid.");
  }
  const port = Number(value);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error("Broker port is invalid.");
  }
  return port;
}

function assertPairingOffer(offer) {
  const fields = [
    "brokerID",
    "endpoint",
    "expiresAt",
    "pairingSecret",
    "tlsPinSHA256",
    "version",
  ];
  if (
    !offer
    || typeof offer !== "object"
    || Array.isArray(offer)
    || Object.keys(offer).sort().join("\0") !== fields.sort().join("\0")
    || offer.version !== 1
    || typeof offer.brokerID !== "string"
    || typeof offer.endpoint !== "string"
    || !URL.canParse(offer.endpoint)
    || new URL(offer.endpoint).protocol !== "https:"
    || !/^[a-f0-9]{64}$/.test(offer.tlsPinSHA256)
    || !/^[A-Za-z0-9_-]{40,}$/.test(offer.pairingSecret)
    || !Number.isSafeInteger(offer.expiresAt)
  ) {
    throw new Error("Pairing offer is invalid.");
  }
}

function usageError() {
  return new Error(usageText());
}

function usageText() {
  return [
    "Usage: visionclaw-broker start [--lan] [--port N]",
    "| pair [--port N]",
    "| pairings [--port N]",
    "| revoke PAIRING_REFERENCE [--port N]",
    "| status [--port N]",
  ].join(" ");
}
