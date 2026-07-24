import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { BrokerServer } from "../src/broker-server.mjs";
import { LocalAdminClient } from "../src/local-admin-client.mjs";
import { ensureBrokerIdentity } from "../src/runtime-state.mjs";

const ADMIN_TOKEN = "A".repeat(43);

test("local admin client verifies the broker certificate for pair and status", async (t) => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-admin-"));
  const identity = await ensureBrokerIdentity({ stateDirectory });
  const offer = {
    version: 1,
    brokerID: identity.brokerID,
    endpoint: "https://visionclaw.local:38443",
    tlsPinSHA256: identity.tlsPinSHA256,
    pairingSecret: "pairing-secret-value-with-high-entropy-123456",
    expiresAt: 1_800_000_120_000,
  };
  const healthAuthorizations = [];
  const server = new BrokerServer({
    application: {
      async handleNodeRequest(request, response) {
        healthAuthorizations.push(request.headers.authorization);
        response.writeHead(200, { "content-type": "application/json" });
        response.end('{"ready":true,"version":"0.1.0"}');
      },
    },
    pairingService: {
      begin: () => offer,
      listPairings: () => ({
        pairings: [{
          pairingReference: `vcp_${"a".repeat(43)}`,
          deviceName: "Jaack iPhone",
          pairedAt: 1_800_000_000_000,
          revokedAt: null,
          status: "active",
        }],
      }),
      revokePairing: ({ pairingReference }) => ({
        pairingReference,
        deviceName: "Jaack iPhone",
        pairedAt: 1_800_000_000_000,
        revokedAt: 1_800_000_010_000,
        status: "revoked",
      }),
    },
    identity,
    host: "127.0.0.1",
    port: 0,
    adminToken: ADMIN_TOKEN,
  });
  await server.start();
  t.after(() => server.stop());
  const client = new LocalAdminClient({
    certificatePath: identity.certificatePath,
    port: server.port,
    adminToken: ADMIN_TOKEN,
  });

  assert.deepEqual(await client.pairingOffer(), offer);
  assert.deepEqual(await client.status(), {
    ready: true,
    version: "0.1.0",
  });
  const listed = await client.pairings();
  assert.match(listed.pairings[0].pairingReference, /^vcp_/);
  const revoked = await client.revokePairing(
    listed.pairings[0].pairingReference,
  );
  assert.equal(revoked.status, "revoked");
  assert.equal(
    revoked.pairingReference,
    listed.pairings[0].pairingReference,
  );

  const missingCredential = new LocalAdminClient({
    certificatePath: identity.certificatePath,
    port: server.port,
  });
  await assert.rejects(
    missingCredential.pairingOffer(),
    /admin credential is required/i,
  );
  assert.deepEqual(await missingCredential.status(), {
    ready: true,
    version: "0.1.0",
  });
  assert.deepEqual(healthAuthorizations, [undefined, undefined]);

  const wrongCredential = new LocalAdminClient({
    certificatePath: identity.certificatePath,
    port: server.port,
    adminToken: "B".repeat(43),
  });
  await assert.rejects(
    wrongCredential.pairingOffer(),
    /status 404/i,
  );
});

test("local admin client does not accept a different self-signed broker", async (t) => {
  const trustedDirectory = await mkdtemp(join(tmpdir(), "visionclaw-trusted-"));
  const serverDirectory = await mkdtemp(join(tmpdir(), "visionclaw-untrusted-"));
  const trusted = await ensureBrokerIdentity({ stateDirectory: trustedDirectory });
  const untrusted = await ensureBrokerIdentity({ stateDirectory: serverDirectory });
  const server = new BrokerServer({
    application: {
      async handleNodeRequest(_request, response) {
        response.writeHead(200, { "content-type": "application/json" });
        response.end('{"ready":true,"version":"0.1.0"}');
      },
    },
    pairingService: { begin() {} },
    identity: untrusted,
    host: "127.0.0.1",
    port: 0,
    adminToken: ADMIN_TOKEN,
  });
  await server.start();
  t.after(() => server.stop());
  const client = new LocalAdminClient({
    certificatePath: trusted.certificatePath,
    port: server.port,
  });

  await assert.rejects(client.status(), /certificate|self-signed|verify/i);
});

test("local admin client refuses non-loopback hosts", async () => {
  assert.throws(
    () => new LocalAdminClient({
      certificatePath: "/tmp/not-read.pem",
      host: "192.168.1.20",
      port: 38_443,
    }),
    /admin host/i,
  );
});
