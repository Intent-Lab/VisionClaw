import assert from "node:assert/strict";
import {
  generateKeyPairSync,
  sign as signBytes,
} from "node:crypto";
import test from "node:test";

import {
  CapabilityIssuer,
  PairingManager,
  ReplayGuard,
  SecretRedactor,
  canonicalJSONString,
  createDeviceRequestProof,
  parseCanonicalJSON,
  publicKeyThumbprint,
  redactSecrets,
  sha256Base64URL,
  verifyDeviceRequestProof,
} from "../src/security.mjs";

const fixedNow = () => 1_800_000_000_000;

function deviceIdentity() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  return {
    privateKey,
    publicKey,
    publicKeyDER: publicKey.export({ type: "spki", format: "der" }),
  };
}

test("canonical JSON is stable and rejects non-canonical or duplicate-key bodies", () => {
  assert.equal(
    canonicalJSONString({ z: 1, a: { c: true, b: "two" } }),
    '{"a":{"b":"two","c":true},"z":1}',
  );
  assert.deepEqual(
    parseCanonicalJSON('{"a":{"b":"two","c":true},"z":1}'),
    { a: { b: "two", c: true }, z: 1 },
  );
  assert.throws(
    () => parseCanonicalJSON('{"z":1,"a":2}'),
    /canonical/i,
  );
  assert.throws(
    () => parseCanonicalJSON('{"a":1,"a":2}'),
    /canonical/i,
  );
});

test("pairing secret is high entropy, expires, and is single use", () => {
  const manager = new PairingManager({
    brokerID: "broker-1",
    endpoint: "https://192.168.1.20:19431",
    tlsPinSHA256: "a".repeat(64),
    now: fixedNow,
  });
  const offer = manager.begin({ ttlMilliseconds: 120_000 });
  assert.match(offer.pairingSecret, /^[A-Za-z0-9_-]{40,}$/);
  assert.equal(offer.expiresAt, fixedNow() + 120_000);
  assert.throws(
    () => manager.begin({ ttlMilliseconds: 120_000 }),
    /already active/i,
  );

  const phone = deviceIdentity();
  const record = manager.consume({
    pairingSecret: offer.pairingSecret,
    phonePublicKeyDER: phone.publicKeyDER,
    deviceName: "Jaack iPhone",
  });
  assert.equal(record.brokerID, "broker-1");
  assert.equal(
    record.phoneKeyThumbprint,
    publicKeyThumbprint(phone.publicKeyDER),
  );
  assert.throws(
    () => manager.consume({
      pairingSecret: offer.pairingSecret,
      phonePublicKeyDER: phone.publicKeyDER,
    }),
    /used|invalid/i,
  );

  const expired = manager.begin({ ttlMilliseconds: 10_000 });
  assert.throws(
    () => manager.consume({
      pairingSecret: expired.pairingSecret,
      phonePublicKeyDER: phone.publicKeyDER,
      now: fixedNow() + 10_001,
    }),
    /expired/i,
  );
});

test("pairing accepts only P-256 phone signing keys", () => {
  const manager = new PairingManager({
    brokerID: "broker-1",
    endpoint: "https://192.168.1.20:19431",
    tlsPinSHA256: "a".repeat(64),
    now: fixedNow,
  });
  const offer = manager.begin({ ttlMilliseconds: 120_000 });
  const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const p384 = generateKeyPairSync("ec", { namedCurve: "secp384r1" });

  for (const publicKey of [rsa.publicKey, p384.publicKey]) {
    assert.throws(
      () => manager.consume({
        pairingSecret: offer.pairingSecret,
        phonePublicKeyDER: publicKey.export({ type: "spki", format: "der" }),
      }),
      /P-256/i,
    );
  }

  const phone = deviceIdentity();
  assert.doesNotThrow(() => manager.consume({
    pairingSecret: offer.pairingSecret,
    phonePublicKeyDER: phone.publicKeyDER,
  }));
});

test("device proof binds method, path, canonical body, pairing, and nonce", () => {
  const phone = deviceIdentity();
  const body = { harnessID: "eva", instruction: "list my agents" };
  const request = {
    pairingID: "pair-1",
    method: "POST",
    path: "/v1/harness/invoke",
    timestamp: fixedNow(),
    nonce: "nonce-1",
    bodyHash: sha256Base64URL(canonicalJSONString(body)),
  };
  const proof = createDeviceRequestProof(request, phone.privateKey);
  const replayGuard = new ReplayGuard({ now: fixedNow });

  assert.doesNotThrow(() => verifyDeviceRequestProof({
    request,
    proof,
    publicKey: phone.publicKey,
    replayGuard,
    now: fixedNow(),
  }));
  assert.throws(
    () => verifyDeviceRequestProof({
      request,
      proof,
      publicKey: phone.publicKey,
      replayGuard,
      now: fixedNow(),
    }),
    /replay/i,
  );

  const wrongBody = { ...request, bodyHash: sha256Base64URL("{}") };
  assert.throws(
    () => verifyDeviceRequestProof({
      request: wrongBody,
      proof,
      publicKey: phone.publicKey,
      replayGuard: new ReplayGuard({ now: fixedNow }),
      now: fixedNow(),
    }),
    /signature/i,
  );
});

test("capability is short lived, proof-bound, scoped, audience-bound, and one shot", () => {
  const phone = deviceIdentity();
  const issuer = new CapabilityIssuer({
    issuer: "visionclaw-broker:broker-1",
    audience: "visionclaw-ios",
    signingKey: Buffer.alloc(32, 7),
    now: fixedNow,
  });
  const bodyHash = sha256Base64URL('{"instruction":"status"}');
  const token = issuer.issue({
    pairingID: "pair-1",
    phoneKeyThumbprint: publicKeyThumbprint(phone.publicKeyDER),
    scope: "harness:invoke",
    method: "POST",
    path: "/v1/harness/invoke",
    bodyHash,
    ttlMilliseconds: 20_000,
  });
  const expected = {
    pairingID: "pair-1",
    phoneKeyThumbprint: publicKeyThumbprint(phone.publicKeyDER),
    scope: "harness:invoke",
    method: "POST",
    path: "/v1/harness/invoke",
    bodyHash,
  };

  const claims = issuer.verifyAndConsume(token, expected);
  assert.equal(claims.aud, "visionclaw-ios");
  assert.equal(claims.scope, "harness:invoke");
  assert.throws(
    () => issuer.verifyAndConsume(token, expected),
    /replay|consumed/i,
  );

  const wrongScopeToken = issuer.issue({
    ...expected,
    scope: "tasks:list",
    ttlMilliseconds: 20_000,
  });
  assert.throws(
    () => issuer.verifyAndConsume(wrongScopeToken, expected),
    /scope/i,
  );
});

test("secret-like values are redacted from broker output", () => {
  const raw = [
    "Authorization: Bearer abcdefghijklmnopqrstuvwxyz",
    "OPENAI_API_KEY=sk-1234567890abcdefghijklmnop",
    "gatewayToken: super-secret-value",
  ].join("\n");
  const safe = redactSecrets(raw);
  assert.doesNotMatch(safe, /abcdefghijklmnopqrstuvwxyz/);
  assert.doesNotMatch(safe, /sk-123456/);
  assert.doesNotMatch(safe, /super-secret-value/);
  assert.match(safe, /<redacted>/);
});

test("quoted and nested JSON plus exact local credentials are redacted", () => {
  const gatewayCredential = "locally-loaded-gateway-credential-123456";
  const redactor = new SecretRedactor({
    exactValues: [gatewayCredential],
  });
  const raw = JSON.stringify({
    gatewayToken: "quoted-secret-value",
    nested: {
      authorization: "Bearer nested-bearer-value",
      credentials: {
        value: "deeply-nested-unlabeled-secret",
      },
      payload: JSON.stringify({
        OPENAI_API_KEY: "nested-json-secret-value",
      }),
    },
    unlabeled: gatewayCredential,
    safe: "keep me",
  });

  const safe = redactor.redact(raw);
  assert.doesNotMatch(
    safe,
    /quoted-secret|nested-bearer|nested-json-secret|deeply-nested|locally-loaded-gateway/,
  );
  assert.match(safe, /<redacted>/);
  const decoded = JSON.parse(safe);
  assert.equal(decoded.safe, "keep me");
  assert.equal(decoded.gatewayToken, "<redacted>");
  assert.equal(decoded.nested.authorization, "Bearer <redacted>");
  assert.equal(decoded.nested.credentials, "<redacted>");
  assert.equal(
    JSON.parse(decoded.nested.payload).OPENAI_API_KEY,
    "<redacted>",
  );
});

test("proof signatures use P-256 and do not accept another device key", () => {
  const phone = deviceIdentity();
  const attacker = deviceIdentity();
  const payload = {
    pairingID: "pair-1",
    method: "POST",
    path: "/v1/capabilities",
    timestamp: fixedNow(),
    nonce: "nonce-a",
    bodyHash: sha256Base64URL("{}"),
  };
  const canonical = Buffer.from(canonicalJSONString(payload));
  const attackerProof = signBytes("sha256", canonical, attacker.privateKey)
    .toString("base64url");
  assert.throws(
    () => verifyDeviceRequestProof({
      request: payload,
      proof: attackerProof,
      publicKey: phone.publicKey,
      replayGuard: new ReplayGuard({ now: fixedNow }),
      now: fixedNow(),
    }),
    /signature/i,
  );
});
