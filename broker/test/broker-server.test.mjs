import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import https from "node:https";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  BrokerServer,
  isLocalAdminConnection,
  isLoopbackAddress,
} from "../src/broker-server.mjs";
import { selectLANAddress } from "../src/network-endpoint.mjs";
import { ensureBrokerIdentity } from "../src/runtime-state.mjs";

const ADMIN_TOKEN = "A".repeat(43);

test("TLS server delegates public routes and keeps pairing-offer creation loopback-only", async (t) => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-server-"));
  const identity = await ensureBrokerIdentity({ stateDirectory });
  const calls = [];
  const pairingService = {
    begin(request) {
      calls.push(["pairing", request]);
      return {
        version: 1,
        brokerID: identity.brokerID,
        endpoint: "https://visionclaw.local:38443",
        tlsPinSHA256: identity.tlsPinSHA256,
        pairingSecret: "pairing-secret-value-with-high-entropy",
        expiresAt: 1_800_000_120_000,
      };
    },
    listPairings(request) {
      calls.push(["list-pairings", request]);
      return {
        pairings: [{
          pairingReference: `vcp_${"a".repeat(43)}`,
          deviceName: "Jaack iPhone",
          pairedAt: 1_800_000_000_000,
          revokedAt: null,
          status: "active",
        }],
      };
    },
    revokePairing(request) {
      calls.push(["revoke-pairing", request]);
      return {
        pairingReference: request.pairingReference,
        deviceName: "Jaack iPhone",
        pairedAt: 1_800_000_000_000,
        revokedAt: 1_800_000_010_000,
        status: "revoked",
      };
    },
  };
  const application = {
    async handleNodeRequest(_request, response) {
      calls.push(["application"]);
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"ready":true}');
    },
  };
  const server = new BrokerServer({
    application,
    pairingService,
    identity,
    host: "127.0.0.1",
    port: 0,
    adminToken: ADMIN_TOKEN,
  });
  await server.start();
  t.after(() => server.stop());

  const certificate = await readFile(identity.certificatePath);
  const unauthenticated = await requestJSON({
    certificate,
    port: server.port,
    method: "POST",
    path: "/v1/admin/pairing-offer",
    body: "{}",
  });
  assert.equal(unauthenticated.statusCode, 404);
  assert.equal(unauthenticated.json.error.code, "not_found");
  assert.deepEqual(calls, []);

  const incorrectlyAuthenticated = await requestJSON({
    certificate,
    port: server.port,
    method: "POST",
    path: "/v1/admin/pairing-offer",
    body: "{}",
    adminToken: "B".repeat(43),
  });
  assert.equal(incorrectlyAuthenticated.statusCode, 404);
  assert.equal(incorrectlyAuthenticated.json.error.code, "not_found");
  assert.deepEqual(calls, []);

  const offer = await requestJSON({
    certificate,
    port: server.port,
    method: "POST",
    path: "/v1/admin/pairing-offer",
    body: "{}",
    adminToken: ADMIN_TOKEN,
  });
  assert.equal(offer.statusCode, 201);
  assert.equal(offer.json.brokerID, identity.brokerID);
  assert.equal(
    offer.json.pairingSecret,
    "pairing-secret-value-with-high-entropy",
  );
  assert.deepEqual(calls[0], ["pairing", { requestedByLoopback: true }]);

  const health = await requestJSON({
    certificate,
    port: server.port,
    method: "GET",
    path: "/healthz",
  });
  assert.equal(health.statusCode, 200);
  assert.deepEqual(health.json, { ready: true });
  assert.deepEqual(calls[1], ["application"]);

  const pairings = await requestJSON({
    certificate,
    port: server.port,
    method: "GET",
    path: "/v1/admin/pairings",
    adminToken: ADMIN_TOKEN,
  });
  assert.equal(pairings.statusCode, 200);
  assert.match(pairings.json.pairings[0].pairingReference, /^vcp_/);
  assert.deepEqual(calls[2], [
    "list-pairings",
    { requestedByLoopback: true },
  ]);

  const pairingReference = pairings.json.pairings[0].pairingReference;
  const revoked = await requestJSON({
    certificate,
    port: server.port,
    method: "POST",
    path: "/v1/admin/pairings/revoke",
    body: JSON.stringify({ pairingReference }),
    adminToken: ADMIN_TOKEN,
  });
  assert.equal(revoked.statusCode, 200);
  assert.equal(revoked.json.status, "revoked");
  assert.deepEqual(calls[3], [
    "revoke-pairing",
    { pairingReference, requestedByLoopback: true },
  ]);
});

test("loopback recognition is narrow and does not trust LAN addresses", () => {
  for (const address of ["127.0.0.1", "::1", "::ffff:127.0.0.1"]) {
    assert.equal(isLoopbackAddress(address), true);
  }
  for (const address of [
    "192.168.1.40",
    "10.0.0.4",
    "::ffff:192.168.1.40",
    "",
    undefined,
  ]) {
    assert.equal(isLoopbackAddress(address), false);
  }
  assert.equal(
    isLocalAdminConnection("192.168.1.16", "192.168.1.16"),
    false,
  );
  assert.equal(
    isLocalAdminConnection("192.168.1.44", "192.168.1.16"),
    false,
  );
});

test("LAN mode starts and stops Bonjour only with the bound TLS port", async (t) => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-lan-server-"));
  const identity = await ensureBrokerIdentity({ stateDirectory });
  const events = [];
  const advertiserFactory = (configuration) => ({
    start() {
      events.push(["start", configuration]);
    },
    stop() {
      events.push(["stop"]);
    },
  });
  const server = new BrokerServer({
    application: {
      async handleNodeRequest(_request, response) {
        response.writeHead(404);
        response.end();
      },
    },
    pairingService: { begin() {} },
    identity,
    host: "0.0.0.0",
    port: 0,
    adminToken: ADMIN_TOKEN,
    advertiserFactory,
  });
  await server.start();
  t.after(() => server.stop());

  assert.deepEqual(events[0], [
    "start",
    {
      brokerID: identity.brokerID,
      displayName: "VisionClaw",
      port: server.port,
    },
  ]);
  await server.stop();
  assert.deepEqual(events[1], ["stop"]);
});

test("an explicit LAN bind serves administration only on its loopback listener", async (t) => {
  let host;
  try {
    host = selectLANAddress();
  } catch {
    t.skip("No private LAN address is available.");
    return;
  }
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-lan-admin-"));
  const identity = await ensureBrokerIdentity({ stateDirectory });
  const server = new BrokerServer({
    application: {
      async handleNodeRequest(_request, response) {
        response.writeHead(404, { "content-type": "application/json" });
        response.end('{"error":{"code":"not_found"}}');
      },
    },
    pairingService: {
      begin: () => ({
        version: 1,
        brokerID: identity.brokerID,
        endpoint: `https://${host}:38443`,
        tlsPinSHA256: identity.tlsPinSHA256,
        pairingSecret: "pairing-secret-value-with-high-entropy",
        expiresAt: 1_800_000_120_000,
      }),
    },
    identity,
    host,
    port: 0,
    adminToken: ADMIN_TOKEN,
    advertiserFactory: () => ({
      start() {},
      stop() {},
    }),
  });
  await server.start();
  t.after(() => server.stop());
  const certificate = await readFile(identity.certificatePath);

  const loopback = await requestJSON({
    certificate,
    port: server.port,
    method: "POST",
    path: "/v1/admin/pairing-offer",
    body: "{}",
    adminToken: ADMIN_TOKEN,
  });
  assert.equal(loopback.statusCode, 201);

  const lan = await requestJSON({
    certificate,
    host,
    port: server.port,
    method: "POST",
    path: "/v1/admin/pairing-offer",
    body: "{}",
    adminToken: ADMIN_TOKEN,
  });
  assert.equal(lan.statusCode, 404);
  assert.equal(lan.json.error.code, "not_found");
});

function requestJSON({
  certificate,
  host = "127.0.0.1",
  port,
  method,
  path,
  body,
  adminToken,
}) {
  const headers = {};
  if (adminToken) {
    headers.authorization = `Bearer ${adminToken}`;
  }
  if (body != null) {
    headers["content-length"] = Buffer.byteLength(body);
    headers["content-type"] = "application/json";
  }
  return new Promise((resolve, reject) => {
    const request = https.request({
      host,
      port,
      method,
      path,
      ca: certificate,
      servername: "localhost",
      headers,
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
      response.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        resolve({
          statusCode: response.statusCode,
          json: raw ? JSON.parse(raw) : null,
        });
      });
    });
    request.on("error", reject);
    if (body != null) request.write(body);
    request.end();
  });
}
