import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { BrokerServer } from "../src/broker-server.mjs";
import { pairingVerificationDetails } from "../src/cli.mjs";
import { ensureBrokerIdentity } from "../src/runtime-state.mjs";
import { writeRuntimeRecord } from "../src/runtime-record.mjs";
import {
  LOCAL_ADMIN_SECRET_NAME,
  SecurityStateStore,
} from "../src/security-state-store.mjs";

const execFileAsync = promisify(execFile);
const brokerDirectory = dirname(fileURLToPath(new URL("../package.json", import.meta.url)));

async function withCLI(argv, stateDirectory) {
  const { stdout, stderr } = await execFileAsync(
    process.execPath,
    ["src/cli.mjs", ...argv],
    {
      cwd: brokerDirectory,
      env: {
        ...process.env,
        VISIONCLAW_BROKER_STATE_DIR: stateDirectory,
      },
    },
  );
  return { stdout, stderr };
}

test("CLI pairings and revoke use the loopback admin API with safe references", async (t) => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-cli-"));
  const identity = await ensureBrokerIdentity({ stateDirectory });
  const adminToken = createAdminToken(stateDirectory);
  const pairings = [{
    pairingReference: `vcp_${"a".repeat(43)}`,
    deviceName: "Jaack iPhone",
    pairedAt: 1_800_000_000_000,
    revokedAt: null,
    status: "active",
  }];
  const calls = [];
  const server = new BrokerServer({
    application: {
      async handleNodeRequest(_request, response) {
        response.writeHead(404, { "content-type": "application/json" });
        response.end('{"error":{"code":"not_found"}}');
      },
    },
    pairingService: {
      begin() {
        throw new Error("not used");
      },
      listPairings(request) {
        calls.push(["listPairings", request]);
        return { pairings };
      },
      revokePairing(request) {
        calls.push(["revokePairing", request]);
        return {
          ...pairings[0],
          pairingReference: request.pairingReference,
          revokedAt: 1_800_000_010_000,
          status: "revoked",
        };
      },
    },
    identity,
    host: "127.0.0.1",
    port: 0,
    adminToken,
  });
  await server.start();
  t.after(() => server.stop());

  await writeRuntimeRecord({
    stateDirectory,
    value: {
      brokerID: identity.brokerID,
      host: "127.0.0.1",
      pid: process.pid,
      port: server.port,
      startedAt: Date.now(),
    },
  });

  const listed = await withCLI(["pairings", "--port", String(server.port)], stateDirectory);
  assert.match(listed.stdout, /Active: Jaack iPhone \(vcp_[A-Za-z0-9_-]{43}\)/);
  assert.equal(listed.stderr, "");

  const revoked = await withCLI(
    ["revoke", pairings[0].pairingReference, "--port", String(server.port)],
    stateDirectory,
  );
  assert.match(revoked.stdout, /Revoked pairing vcp_[A-Za-z0-9_-]{43}\./);
  assert.equal(revoked.stderr, "");

  assert.deepEqual(calls, [
    ["listPairings", { requestedByLoopback: true }],
    ["revokePairing", {
      pairingReference: pairings[0].pairingReference,
      requestedByLoopback: true,
    }],
  ]);
});

test("CLI pair prints the private endpoint, broker suffix, and TLS fingerprint for comparison", async (t) => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-cli-pair-"));
  const identity = await ensureBrokerIdentity({ stateDirectory });
  const adminToken = createAdminToken(stateDirectory);
  const endpoint = "https://192.168.1.16:38443";
  const expiresAt = Date.now() + 120_000;
  const calls = [];
  const server = new BrokerServer({
    application: {
      async handleNodeRequest(_request, response) {
        response.writeHead(404, { "content-type": "application/json" });
        response.end('{"error":{"code":"not_found"}}');
      },
    },
    pairingService: {
      begin(request) {
        calls.push(request);
        return {
          version: 1,
          brokerID: identity.brokerID,
          endpoint,
          tlsPinSHA256: identity.tlsPinSHA256,
          pairingSecret: "pairing-secret-value-with-high-entropy-123456",
          expiresAt,
        };
      },
      listPairings() {
        throw new Error("not used");
      },
      revokePairing() {
        throw new Error("not used");
      },
    },
    identity,
    host: "127.0.0.1",
    port: 0,
    adminToken,
  });
  await server.start();
  t.after(() => server.stop());

  await writeRuntimeRecord({
    stateDirectory,
    value: {
      brokerID: identity.brokerID,
      host: "127.0.0.1",
      pid: process.pid,
      port: server.port,
      startedAt: Date.now(),
    },
  });

  const result = await withCLI(
    ["pair", "--port", String(server.port)],
    stateDirectory,
  );
  const fingerprint = identity.tlsPinSHA256
    .match(/.{2}/g)
    .map((octet) => octet.toUpperCase())
    .join(":");
  assert.match(result.stdout, /Verify these values match/);
  assert.match(result.stdout, new RegExp(`Private endpoint: ${endpoint}`));
  assert.match(
    result.stdout,
    new RegExp(`Broker suffix: ${identity.brokerID.slice(-6)}`),
  );
  assert.match(
    result.stdout,
    new RegExp(`TLS SHA-256 fingerprint: ${fingerprint}`),
  );
  assert.match(result.stdout, /Pairing expires at /);
  assert.equal(result.stderr, "");
  assert.deepEqual(calls, [{ requestedByLoopback: true }]);
});

function createAdminToken(stateDirectory) {
  const store = new SecurityStateStore({
    path: join(stateDirectory, "broker.sqlite3"),
  });
  try {
    return store.getOrCreateSecret(LOCAL_ADMIN_SECRET_NAME, 32).reveal();
  } finally {
    store.close();
  }
}

test("pair verification details reject public endpoints and identity mismatches", () => {
  const identity = {
    brokerID: `broker_${"a".repeat(43)}`,
    tlsPinSHA256: "b".repeat(64),
  };
  const offer = {
    brokerID: identity.brokerID,
    endpoint: "https://8.8.8.8:38443",
    tlsPinSHA256: identity.tlsPinSHA256,
  };

  assert.throws(
    () => pairingVerificationDetails(offer, identity),
    /private IPv4/i,
  );
  assert.throws(
    () => pairingVerificationDetails(
      { ...offer, endpoint: "https://192.168.1.16:38443" },
      { ...identity, brokerID: `broker_${"c".repeat(43)}` },
    ),
    /mismatched pairing identity/i,
  );
  assert.throws(
    () => pairingVerificationDetails(
      { ...offer, endpoint: "https://192.168.1.16:38443" },
      { ...identity, tlsPinSHA256: "d".repeat(64) },
    ),
    /mismatched TLS fingerprint/i,
  );
});
