import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";

import {
  BrokerAuthorization,
  MemoryPairingStore,
} from "../src/broker-authorization.mjs";
import {
  CapabilityIssuer,
  ReplayGuard,
  canonicalJSONString,
  createDeviceRequestProof,
  publicKeyThumbprint,
  sha256Base64URL,
} from "../src/security.mjs";

const fixedNow = () => 1_800_000_000_000;

function phoneIdentity() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const publicKeyDER = publicKey.export({ type: "spki", format: "der" });
  return { privateKey, publicKey, publicKeyDER };
}

function fixture() {
  const phone = phoneIdentity();
  const pairings = new MemoryPairingStore();
  pairings.save({
    pairingID: "pair-1",
    brokerID: "broker-1",
    phoneKeyThumbprint: publicKeyThumbprint(phone.publicKeyDER),
    phonePublicKeyDER: phone.publicKeyDER,
    grantedScopes: ["harness:invoke", "tasks:list"],
    revokedAt: null,
  });
  const capabilities = new CapabilityIssuer({
    issuer: "visionclaw-broker:broker-1",
    audience: "visionclaw-ios",
    signingKey: Buffer.alloc(32, 8),
    now: fixedNow,
  });
  const authorization = new BrokerAuthorization({
    pairingStore: pairings,
    capabilityIssuer: capabilities,
    replayGuard: new ReplayGuard({ now: fixedNow }),
    now: fixedNow,
  });
  return { authorization, capabilities, phone };
}

test("paired device proof may mint only a granted, route-bound capability", () => {
  const { authorization, phone } = fixture();
  const requestedBody = canonicalJSONString({
    clientRequestID: "request-1",
    harnessID: "eva",
    instruction: "list agents",
  });
  const capabilityBody = {
    bodyHash: sha256Base64URL(requestedBody),
    method: "POST",
    path: "/v1/harness/invoke",
    scope: "harness:invoke",
  };
  const proofRequest = {
    pairingID: "pair-1",
    method: "POST",
    path: "/v1/capabilities",
    timestamp: fixedNow(),
    nonce: "capability-nonce-1",
    bodyHash: sha256Base64URL(canonicalJSONString(capabilityBody)),
  };
  const token = authorization.issueCapability({
    pairingID: "pair-1",
    body: capabilityBody,
    proofRequest,
    proof: createDeviceRequestProof(proofRequest, phone.privateKey),
  });
  assert.match(token, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);

  assert.throws(
    () => authorization.issueCapability({
      pairingID: "pair-1",
      body: { ...capabilityBody, scope: "tasks:continue" },
      proofRequest: {
        ...proofRequest,
        nonce: "capability-nonce-2",
        bodyHash: sha256Base64URL(canonicalJSONString({
          ...capabilityBody,
          scope: "tasks:continue",
        })),
      },
      proof: createDeviceRequestProof({
        ...proofRequest,
        nonce: "capability-nonce-2",
        bodyHash: sha256Base64URL(canonicalJSONString({
          ...capabilityBody,
          scope: "tasks:continue",
        })),
      }, phone.privateKey),
    }),
    /scope/i,
  );
});

test("authorization rejects modified body and exact request replay", () => {
  const { authorization, capabilities, phone } = fixture();
  const rawBody = canonicalJSONString({
    clientRequestID: "request-1",
    harnessID: "eva",
    instruction: "list agents",
  });
  const bodyHash = sha256Base64URL(rawBody);
  const token = capabilities.issue({
    pairingID: "pair-1",
    phoneKeyThumbprint: publicKeyThumbprint(phone.publicKeyDER),
    scope: "harness:invoke",
    method: "POST",
    path: "/v1/harness/invoke",
    bodyHash,
  });
  const proofRequest = {
    pairingID: "pair-1",
    method: "POST",
    path: "/v1/harness/invoke",
    timestamp: fixedNow(),
    nonce: "request-nonce-1",
    bodyHash,
  };
  const proof = createDeviceRequestProof(proofRequest, phone.privateKey);
  assert.doesNotThrow(() => authorization.authorize({
    pairingID: "pair-1",
    token,
    scope: "harness:invoke",
    method: "POST",
    path: "/v1/harness/invoke",
    rawBody,
    proofRequest,
    proof,
  }));
  assert.throws(
    () => authorization.authorize({
      pairingID: "pair-1",
      token,
      scope: "harness:invoke",
      method: "POST",
      path: "/v1/harness/invoke",
      rawBody,
      proofRequest,
      proof,
    }),
    /replay|consumed/i,
  );
});
