import { createHash } from "node:crypto";

const DEFAULT_SCOPES = Object.freeze([
  "harness:invoke",
  "harness:read",
  "harness:cancel",
  "tasks:list",
  "tasks:read",
  "tasks:status",
  "tasks:continue",
  "tasks:continue:commit",
  "tasks:operation:status",
  "tasks:cancel",
]);

export class PairingService {
  #pairingManager;
  #pairingStore;
  #grantedScopes;
  #now;

  constructor({
    pairingManager,
    pairingStore,
    grantedScopes = DEFAULT_SCOPES,
    now = Date.now,
  }) {
    if (
      !pairingManager
      || typeof pairingStore?.save !== "function"
      || typeof pairingStore?.list !== "function"
      || typeof pairingStore?.revoke !== "function"
      || typeof now !== "function"
    ) {
      throw new Error("Pairing manager and store are required.");
    }
    this.#pairingManager = pairingManager;
    this.#pairingStore = pairingStore;
    this.#grantedScopes = [...new Set(grantedScopes)];
    this.#now = now;
  }

  begin({ requestedByLoopback } = {}) {
    if (requestedByLoopback !== true) {
      throw new Error("Pairing offers may only be created from loopback.");
    }
    return this.#pairingManager.begin();
  }

  complete(request) {
    assertExactFields(request, [
      "pairingSecret",
      "phonePublicKeyDER",
      "deviceName",
    ]);
    if (
      !Buffer.isBuffer(request.phonePublicKeyDER)
      && typeof request.phonePublicKeyDER !== "string"
    ) {
      throw new Error("Phone public key encoding is invalid.");
    }
    const phonePublicKeyDER = Buffer.isBuffer(request.phonePublicKeyDER)
      ? Buffer.from(request.phonePublicKeyDER)
      : decodePublicKey(request.phonePublicKeyDER);
    if (phonePublicKeyDER.length < 64 || phonePublicKeyDER.length > 4_096) {
      throw new Error("Phone public key encoding is invalid.");
    }

    const pairing = this.#pairingManager.consume({
      pairingSecret: request.pairingSecret,
      phonePublicKeyDER,
      deviceName: request.deviceName,
    });
    const record = {
      ...pairing,
      grantedScopes: [...this.#grantedScopes],
      revokedAt: null,
    };
    this.#pairingStore.save(record);

    return Object.freeze({
      brokerID: record.brokerID,
      deviceName: record.deviceName,
      grantedScopes: [...record.grantedScopes],
      pairedAt: record.pairedAt,
      pairingID: record.pairingID,
      phoneKeyThumbprint: record.phoneKeyThumbprint,
    });
  }

  listPairings({ requestedByLoopback } = {}) {
    requireLoopbackAdministration(requestedByLoopback);
    const pairings = this.#pairingStore.list()
      .map(administrativeSummary)
      .sort(
        (left, right) => right.pairedAt - left.pairedAt
          || left.pairingReference.localeCompare(right.pairingReference),
      );
    return Object.freeze({ pairings });
  }

  revokePairing({
    requestedByLoopback,
    pairingReference,
  } = {}) {
    requireLoopbackAdministration(requestedByLoopback);
    if (!/^vcp_[A-Za-z0-9_-]{43}$/.test(String(pairingReference))) {
      throw new Error("Pairing reference is invalid.");
    }
    const record = this.#pairingStore.list().find(
      (candidate) => referenceFor(candidate.pairingID) === pairingReference,
    );
    if (!record) {
      throw new Error("Pairing reference was not found.");
    }
    if (record.revokedAt != null) {
      return administrativeSummary(record);
    }
    const revokedAt = this.#now();
    if (
      !Number.isSafeInteger(revokedAt)
      || revokedAt <= 0
      || !this.#pairingStore.revoke(record.pairingID, revokedAt)
    ) {
      throw new Error("Pairing could not be revoked.");
    }
    return administrativeSummary({ ...record, revokedAt });
  }
}

function administrativeSummary(record) {
  if (
    !record
    || typeof record.pairingID !== "string"
    || !Number.isSafeInteger(record.pairedAt)
    || (
      record.revokedAt != null
      && !Number.isSafeInteger(record.revokedAt)
    )
  ) {
    throw new Error("Stored pairing record is invalid.");
  }
  const revokedAt = record.revokedAt ?? null;
  return Object.freeze({
    pairingReference: referenceFor(record.pairingID),
    deviceName: safeDeviceName(record.deviceName),
    pairedAt: record.pairedAt,
    revokedAt,
    status: revokedAt == null ? "active" : "revoked",
  });
}

function referenceFor(pairingID) {
  return `vcp_${createHash("sha256")
    .update(`visionclaw-pairing-reference\0${pairingID}`)
    .digest("base64url")}`;
}

function safeDeviceName(value) {
  const safe = String(value ?? "iPhone")
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80);
  return safe || "iPhone";
}

function requireLoopbackAdministration(requestedByLoopback) {
  if (requestedByLoopback !== true) {
    throw new Error("Pairing administration is available only from loopback.");
  }
}

function decodePublicKey(encoded) {
  if (
    encoded.length > 5_464
    || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(encoded)
  ) {
    throw new Error("Phone public key encoding is invalid.");
  }
  const usesBase64URL = /[-_]/.test(encoded);
  const phonePublicKeyDER = Buffer.from(
    encoded,
    usesBase64URL ? "base64url" : "base64",
  );
  const canonical = phonePublicKeyDER.toString(
    usesBase64URL ? "base64url" : "base64",
  );
  if (canonical.replace(/=+$/, "") !== encoded.replace(/=+$/, "")) {
    throw new Error("Phone public key encoding is invalid.");
  }
  return phonePublicKeyDER;
}

function assertExactFields(value, fields) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("A typed pairing request is required.");
  }
  const actual = Object.keys(value).sort();
  const expected = [...fields].sort();
  if (
    actual.length !== expected.length
    || actual.some((field, index) => field !== expected[index])
  ) {
    throw new Error("Pairing request has unexpected or missing fields.");
  }
}
