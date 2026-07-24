#!/usr/bin/env node

import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import { join } from "node:path";

import { createBrokerRuntime } from "./broker-runtime.mjs";
import {
  formatPairingURI,
  parseCLIOptions,
} from "./cli-options.mjs";
import { LocalAdminClient } from "./local-admin-client.mjs";
import {
  readRuntimeRecord,
  removeRuntimeRecord,
  runtimeRecordIsLive,
} from "./runtime-record.mjs";
import { isPrivateIPv4 } from "./network-endpoint.mjs";
import { ensureBrokerIdentity } from "./runtime-state.mjs";
import { redactSecrets } from "./security.mjs";
import {
  LOCAL_ADMIN_SECRET_NAME,
  SecurityStateStore,
} from "./security-state-store.mjs";
import { renderTerminalQRCode } from "./terminal-qr.mjs";

export async function runCLI(
  argv,
  {
    stateDirectory = process.env.VISIONCLAW_BROKER_STATE_DIR
      || join(homedir(), ".visionclaw-broker"),
    output = (value) => process.stdout.write(`${value}\n`),
  } = {},
) {
  const options = parseCLIOptions(argv);
  if (options.command === "start") {
    const runtime = await createBrokerRuntime({
      stateDirectory,
      host: options.host,
      port: options.port,
    });
    await runtime.start();
    const record = await readRuntimeRecord({ stateDirectory });
    output(
      `VisionClaw broker ready at https://${record.host}:${record.port}`,
    );
    output(
      options.host === "127.0.0.1"
        ? "Loopback-only mode. Restart with --lan when you are ready to pair the iPhone."
        : "LAN discovery is active. In another terminal, run: npm run pair",
    );
    await waitForShutdownSignal();
    await runtime.stop();
    return { stopped: true };
  }

  const identity = await ensureBrokerIdentity({ stateDirectory });
  const record = await readRuntimeRecord({ stateDirectory });
  if (!runtimeRecordIsLive(record)) {
    await removeRuntimeRecord({ stateDirectory });
    throw new Error("VisionClaw broker is not running.");
  }
  if (record.port !== options.port) {
    throw new Error(
      `Broker is running on port ${record.port}; retry with --port ${record.port}.`,
    );
  }
  const adminToken = options.command === "status"
    ? null
    : loadLocalAdminToken(stateDirectory);
  const client = new LocalAdminClient({
    certificatePath: identity.certificatePath,
    host: "127.0.0.1",
    port: record.port,
    adminToken,
  });

  if (options.command === "status") {
    const status = await client.status();
    output(
      status.ready
        ? `VisionClaw broker is ready (${status.version}).`
        : `VisionClaw broker is running but not ready (${status.version}).`,
    );
    return status;
  }

  if (options.command === "pairings") {
    const result = await client.pairings();
    if (result.pairings.length === 0) {
      output("No paired devices.");
      return result;
    }
    for (const pairing of result.pairings) {
      const label = pairing.status === "revoked" ? "Revoked" : "Active";
      output(
        `${label}: ${pairing.deviceName} (${pairing.pairingReference})`,
      );
    }
    return result;
  }

  if (options.command === "revoke") {
    const result = await client.revokePairing(options.pairingReference);
    output(`Revoked pairing ${result.pairingReference}.`);
    return result;
  }

  const offer = await client.pairingOffer();
  const verification = pairingVerificationDetails(offer, identity);
  const pairingURI = formatPairingURI(offer);
  output("Verify these values match the pairing screen on your iPhone:");
  output(`Private endpoint: ${verification.privateEndpoint}`);
  output(`Broker suffix: ${verification.brokerSuffix}`);
  output(`TLS SHA-256 fingerprint: ${verification.tlsFingerprintSHA256}`);
  output("Scan this one-time QR with the iPhone Camera, then open VisionClaw:");
  try {
    output(await renderTerminalQRCode(pairingURI));
  } catch {
    output(pairingURI);
  }
  output(`Pairing expires at ${new Date(offer.expiresAt).toLocaleTimeString()}.`);
  return offer;
}

function loadLocalAdminToken(stateDirectory) {
  const store = new SecurityStateStore({
    path: join(stateDirectory, "broker.sqlite3"),
  });
  try {
    const secret = store.getSecret(LOCAL_ADMIN_SECRET_NAME);
    if (!secret) {
      throw new Error(
        "Broker admin credential is unavailable. Restart the VisionClaw broker.",
      );
    }
    return secret.reveal();
  } finally {
    store.close();
  }
}

export function pairingVerificationDetails(offer, identity) {
  if (!offer || typeof offer !== "object" || Array.isArray(offer)) {
    throw new Error("Broker returned an invalid pairing offer.");
  }
  let endpoint;
  try {
    endpoint = new URL(offer.endpoint);
  } catch {
    throw new Error("Broker returned an invalid pairing endpoint.");
  }
  if (
    endpoint.protocol !== "https:"
    || endpoint.username
    || endpoint.password
    || endpoint.pathname !== "/"
    || endpoint.search
    || endpoint.hash
    || !isPrivateIPv4(endpoint.hostname)
  ) {
    throw new Error(
      "Pairing requires a literal private IPv4 HTTPS endpoint.",
    );
  }
  if (
    !/^broker_[A-Za-z0-9_-]{43}$/.test(offer.brokerID)
    || offer.brokerID !== identity?.brokerID
  ) {
    throw new Error("Broker returned a mismatched pairing identity.");
  }
  if (
    !/^[a-f0-9]{64}$/.test(offer.tlsPinSHA256)
    || offer.tlsPinSHA256 !== identity?.tlsPinSHA256
  ) {
    throw new Error("Broker returned a mismatched TLS fingerprint.");
  }

  return Object.freeze({
    privateEndpoint: `${endpoint.protocol}//${endpoint.host}`,
    brokerSuffix: offer.brokerID.slice(-6),
    tlsFingerprintSHA256: offer.tlsPinSHA256
      .match(/.{2}/g)
      .map((octet) => octet.toUpperCase())
      .join(":"),
  });
}

function waitForShutdownSignal() {
  return new Promise((resolve) => {
    const finish = () => {
      process.off("SIGINT", finish);
      process.off("SIGTERM", finish);
      resolve();
    };
    process.once("SIGINT", finish);
    process.once("SIGTERM", finish);
  });
}

async function main() {
  try {
    await runCLI(process.argv.slice(2));
  } catch (error) {
    const message = redactSecrets(error?.message ?? "Broker command failed.");
    process.stderr.write(`VisionClaw broker: ${message}\n`);
    process.exitCode = 1;
  }
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  await main();
}
