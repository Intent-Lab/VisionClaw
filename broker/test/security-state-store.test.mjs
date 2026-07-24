import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { BrokerAuthorization } from "../src/broker-authorization.mjs";
import {
  CapabilityIssuer,
  canonicalJSONString,
  createDeviceRequestProof,
  publicKeyThumbprint,
  sha256Base64URL,
} from "../src/security.mjs";
import { SecurityStateStore } from "../src/security-state-store.mjs";

function pairing(overrides = {}) {
  return {
    pairingID: "pair-1",
    brokerID: "broker-1",
    phoneKeyThumbprint: "thumbprint",
    phonePublicKeyDER: Buffer.from("phone-public-key"),
    deviceName: "iPhone",
    pairedAt: 1_000,
    grantedScopes: ["harness:invoke", "tasks:list"],
    revokedAt: null,
    ...overrides,
  };
}

test("pairing identities persist and revocation is durable", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-security-store-"));
  const path = join(directory, "state.sqlite3");
  const first = new SecurityStateStore({ path });
  first.save(pairing());
  first.close();

  const second = new SecurityStateStore({ path });
  const loaded = second.get("pair-1");
  assert.equal(loaded.deviceName, "iPhone");
  assert.deepEqual(loaded.grantedScopes, ["harness:invoke", "tasks:list"]);
  assert.deepEqual(loaded.phonePublicKeyDER, Buffer.from("phone-public-key"));
  assert.equal(second.revoke("pair-1", 2_000), true);
  second.close();

  const third = new SecurityStateStore({ path });
  assert.equal(third.get("pair-1").revokedAt, 2_000);
  third.close();
});

test("request and capability replays remain rejected across broker restarts", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-replay-store-"));
  const path = join(directory, "state.sqlite3");
  const first = new SecurityStateStore({ path });
  first.consume("device-proof:pair-1:nonce-1", 2_000, 1_000);
  first.close();

  const second = new SecurityStateStore({ path });
  assert.throws(
    () => second.consume("device-proof:pair-1:nonce-1", 2_000, 1_001),
    /replay/i,
  );
  second.consume("device-proof:pair-1:nonce-1", 3_000, 2_001);
  second.close();
});

test("broker signing secrets are stable and never serialize in plaintext", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-secret-store-"));
  const path = join(directory, "state.sqlite3");
  const first = new SecurityStateStore({ path });
  assert.equal(first.getSecret("capability-signing"), null);
  const initial = first.getOrCreateSecret("capability-signing", 32);
  assert.equal(
    first.getSecret("capability-signing").reveal(),
    initial.reveal(),
  );
  first.close();

  const second = new SecurityStateStore({ path });
  const reloaded = second.getOrCreateSecret("capability-signing", 32);
  assert.equal(initial.reveal().length, 43);
  assert.equal(initial.reveal(), reloaded.reveal());
  assert.equal(
    second.getSecret("capability-signing").reveal(),
    initial.reveal(),
  );
  assert.equal(JSON.stringify({ initial }), "{\"initial\":\"<redacted>\"}");
  assert.doesNotMatch(String(initial), new RegExp(initial.reveal()));
  second.close();
});

test("capability consumption remains one-shot after an issuer restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-capability-store-"));
  const path = join(directory, "state.sqlite3");
  const signingKey = Buffer.alloc(32, 9);
  const now = () => 1_800_000_000_000;
  const expected = {
    pairingID: "pair-1",
    phoneKeyThumbprint: "phone-thumbprint",
    scope: "harness:invoke",
    method: "POST",
    path: "/v1/harness/invoke",
    bodyHash: "body-hash",
  };
  const firstStore = new SecurityStateStore({ path });
  const firstIssuer = new CapabilityIssuer({
    issuer: "visionclaw-broker:broker-1",
    audience: "visionclaw-ios",
    signingKey,
    consumptionStore: firstStore,
    now,
  });
  const token = firstIssuer.issue(expected);
  firstIssuer.verifyAndConsume(token, expected);
  firstStore.close();

  const secondStore = new SecurityStateStore({ path });
  const secondIssuer = new CapabilityIssuer({
    issuer: "visionclaw-broker:broker-1",
    audience: "visionclaw-ios",
    signingKey,
    consumptionStore: secondStore,
    now,
  });
  assert.throws(
    () => secondIssuer.verifyAndConsume(token, expected),
    /replay/i,
  );
  secondStore.close();
});

test("revoked pairing authorization fails immediately and after store restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-revoke-store-"));
  const path = join(directory, "state.sqlite3");
  const now = () => 1_800_000_000_000;
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const publicKeyDER = publicKey.export({ type: "spki", format: "der" });
  const first = new SecurityStateStore({ path });
  first.save(pairing({
    phoneKeyThumbprint: publicKeyThumbprint(publicKeyDER),
    phonePublicKeyDER: publicKeyDER,
  }));

  const makeAuthorization = (store) => new BrokerAuthorization({
    pairingStore: store,
    capabilityIssuer: new CapabilityIssuer({
      issuer: "visionclaw-broker:broker-1",
      audience: "visionclaw-ios",
      signingKey: Buffer.alloc(32, 4),
      consumptionStore: store,
      now,
    }),
    replayGuard: store,
    now,
  });
  const body = {
    bodyHash: sha256Base64URL("{}"),
    method: "POST",
    path: "/v1/harness/invoke",
    scope: "harness:invoke",
  };
  const requestFor = (nonce) => ({
    pairingID: "pair-1",
    method: "POST",
    path: "/v1/capabilities",
    timestamp: now(),
    nonce,
    bodyHash: sha256Base64URL(canonicalJSONString(body)),
  });

  assert.equal(first.revoke("pair-1", now()), true);
  const immediateRequest = requestFor("revoked-now");
  assert.throws(
    () => makeAuthorization(first).issueCapability({
      pairingID: "pair-1",
      body,
      proofRequest: immediateRequest,
      proof: createDeviceRequestProof(immediateRequest, privateKey),
    }),
    /unknown|revoked/i,
  );
  first.close();

  const restarted = new SecurityStateStore({ path });
  const restartedRequest = requestFor("revoked-after-restart");
  assert.throws(
    () => makeAuthorization(restarted).issueCapability({
      pairingID: "pair-1",
      body,
      proofRequest: restartedRequest,
      proof: createDeviceRequestProof(restartedRequest, privateKey),
    }),
    /unknown|revoked/i,
  );
  restarted.close();
});
