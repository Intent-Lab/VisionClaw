import { createPublicKey } from "node:crypto";

import {
  canonicalJSONString,
  sha256Base64URL,
  verifyDeviceRequestProof,
} from "./security.mjs";

const ROUTES = new Map([
  ["harness:invoke", { method: "POST", path: "/v1/harness/invoke" }],
  ["harness:read", { method: "POST", path: "/v1/harness/poll" }],
  ["harness:cancel", { method: "POST", path: "/v1/harness/cancel" }],
  ["tasks:list", { method: "POST", path: "/v1/codex/list" }],
  ["tasks:read", { method: "POST", path: "/v1/codex/read" }],
  ["tasks:status", { method: "POST", path: "/v1/codex/status" }],
  ["tasks:continue", { method: "POST", path: "/v1/codex/prepare" }],
  ["tasks:continue:commit", { method: "POST", path: "/v1/codex/commit" }],
  ["tasks:operation:status", {
    method: "POST",
    path: "/v1/codex/operation-status",
  }],
  ["tasks:cancel", { method: "POST", path: "/v1/codex/cancel" }],
]);

export class MemoryPairingStore {
  #records = new Map();

  save(record) {
    this.#records.set(record.pairingID, {
      ...record,
      phonePublicKeyDER: Buffer.from(record.phonePublicKeyDER),
      grantedScopes: [...record.grantedScopes],
    });
  }

  get(pairingID) {
    const record = this.#records.get(pairingID);
    return record
      ? {
        ...record,
        phonePublicKeyDER: Buffer.from(record.phonePublicKeyDER),
        grantedScopes: [...record.grantedScopes],
      }
      : null;
  }

  list() {
    return [...this.#records.values()].map((record) => ({
      ...record,
      phonePublicKeyDER: Buffer.from(record.phonePublicKeyDER),
      grantedScopes: [...record.grantedScopes],
    }));
  }

  revoke(pairingID, revokedAt = Date.now()) {
    const record = this.#records.get(pairingID);
    if (!record) return false;
    record.revokedAt = revokedAt;
    return true;
  }
}

export class BrokerAuthorization {
  #pairingStore;
  #capabilityIssuer;
  #replayGuard;
  #now;

  constructor({
    pairingStore,
    capabilityIssuer,
    replayGuard,
    now = Date.now,
  }) {
    this.#pairingStore = pairingStore;
    this.#capabilityIssuer = capabilityIssuer;
    this.#replayGuard = replayGuard;
    this.#now = now;
  }

  issueCapability({
    pairingID,
    body,
    proofRequest,
    proof,
  }) {
    assertExactFields(body, ["bodyHash", "method", "path", "scope"]);
    const pairing = this.#activePairing(pairingID);
    const route = ROUTES.get(body.scope);
    if (!route || route.method !== body.method || route.path !== body.path) {
      throw new Error("Requested capability scope does not match a broker route.");
    }
    if (!pairing.grantedScopes.includes(body.scope)) {
      throw new Error("Requested capability scope was not granted to this device.");
    }
    this.#verifyProof({
      pairing,
      expectedMethod: "POST",
      expectedPath: "/v1/capabilities",
      expectedBodyHash: sha256Base64URL(canonicalJSONString(body)),
      proofRequest,
      proof,
    });
    return this.#capabilityIssuer.issue({
      pairingID,
      phoneKeyThumbprint: pairing.phoneKeyThumbprint,
      scope: body.scope,
      method: body.method,
      path: body.path,
      bodyHash: body.bodyHash,
    });
  }

  authorize({
    pairingID,
    token,
    scope,
    method,
    path,
    rawBody,
    proofRequest,
    proof,
  }) {
    const pairing = this.#activePairing(pairingID);
    const bodyHash = sha256Base64URL(rawBody);
    this.#verifyProof({
      pairing,
      expectedMethod: method,
      expectedPath: path,
      expectedBodyHash: bodyHash,
      proofRequest,
      proof,
    });
    return this.#capabilityIssuer.verifyAndConsume(token, {
      pairingID,
      phoneKeyThumbprint: pairing.phoneKeyThumbprint,
      scope,
      method,
      path,
      bodyHash,
    });
  }

  authorizeSessionStatus({
    pairingID,
    rawBody,
    proofRequest,
    proof,
  }) {
    const pairing = this.#activePairing(pairingID);
    this.#verifyProof({
      pairing,
      expectedMethod: "POST",
      expectedPath: "/v1/session/status",
      expectedBodyHash: sha256Base64URL(rawBody),
      proofRequest,
      proof,
    });
    return Object.freeze({ sub: pairing.pairingID });
  }

  #activePairing(pairingID) {
    const pairing = this.#pairingStore.get(pairingID);
    if (!pairing || pairing.revokedAt) {
      throw new Error("Paired device identity is unknown or revoked.");
    }
    return pairing;
  }

  #verifyProof({
    pairing,
    expectedMethod,
    expectedPath,
    expectedBodyHash,
    proofRequest,
    proof,
  }) {
    if (
      proofRequest.pairingID !== pairing.pairingID
      || proofRequest.method !== expectedMethod
      || proofRequest.path !== expectedPath
      || proofRequest.bodyHash !== expectedBodyHash
    ) {
      throw new Error("Device proof does not match this request.");
    }
    const publicKey = createPublicKey({
      key: pairing.phonePublicKeyDER,
      type: "spki",
      format: "der",
    });
    verifyDeviceRequestProof({
      request: proofRequest,
      proof,
      publicKey,
      replayGuard: this.#replayGuard,
      now: this.#now(),
    });
  }
}

function assertExactFields(value, fields) {
  const actual = Object.keys(value ?? {}).sort();
  const expected = [...fields].sort();
  if (
    actual.length !== expected.length
    || actual.some((field, index) => field !== expected[index])
  ) {
    throw new Error("Capability request has unexpected or missing fields.");
  }
}
