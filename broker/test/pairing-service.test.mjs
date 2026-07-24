import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";

import { PairingService } from "../src/pairing-service.mjs";
import { PairingManager } from "../src/security.mjs";

class TestPairingStore {
  records = new Map();

  save(record) {
    this.records.set(record.pairingID, structuredClone(record));
  }

  get(pairingID) {
    return this.records.get(pairingID) ?? null;
  }

  list() {
    return [...this.records.values()].map((record) => structuredClone(record));
  }

  revoke(pairingID, revokedAt) {
    const record = this.records.get(pairingID);
    if (!record) return false;
    record.revokedAt = revokedAt;
    return true;
  }
}

function makeService(now = () => 1_000_000) {
  const store = new TestPairingStore();
  const manager = new PairingManager({
    brokerID: "broker_test",
    endpoint: "https://visionclaw.local:38443",
    tlsPinSHA256: "a".repeat(64),
    now,
  });
  return {
    store,
    service: new PairingService({
      pairingManager: manager,
      pairingStore: store,
      grantedScopes: [
        "harness:invoke",
        "tasks:list",
        "tasks:read",
        "tasks:status",
        "tasks:continue",
        "tasks:continue:commit",
        "tasks:cancel",
      ],
      now,
    }),
  };
}

test("pairing is explicit, single-use, and returns no broker credential", () => {
  const { service, store } = makeService();
  const offer = service.begin({ requestedByLoopback: true });
  const phoneKeys = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const phonePublicKeyDER = phoneKeys.publicKey.export({
    type: "spki",
    format: "der",
  });

  const result = service.complete({
    pairingSecret: offer.pairingSecret,
    phonePublicKeyDER,
    deviceName: "Jaack's iPhone",
  });

  assert.equal(store.records.size, 1);
  assert.equal(result.brokerID, "broker_test");
  assert.equal(result.deviceName, "Jaack's iPhone");
  assert.deepEqual(result.grantedScopes, [
    "harness:invoke",
    "tasks:list",
    "tasks:read",
    "tasks:status",
    "tasks:continue",
    "tasks:continue:commit",
    "tasks:cancel",
  ]);
  assert.doesNotMatch(JSON.stringify(result), /token|secret|private/i);
  assert.throws(() => service.complete({
    pairingSecret: offer.pairingSecret,
    phonePublicKeyDER: phonePublicKeyDER.toString("base64"),
    deviceName: "Replay",
  }), /used|invalid/i);
});

test("only a loopback admin may create a pairing offer", () => {
  const { service } = makeService();

  assert.throws(
    () => service.begin({ requestedByLoopback: false }),
    /loopback/i,
  );
});

test("loopback administration lists only safe references and revokes idempotently", () => {
  const { service, store } = makeService();
  store.save({
    pairingID: "raw-pairing-identifier",
    brokerID: "broker_test",
    phoneKeyThumbprint: "private-phone-thumbprint",
    phonePublicKeyDER: Buffer.from("private-phone-public-key"),
    deviceName: "Jaack\u001b[2J iPhone",
    pairedAt: 999_000,
    grantedScopes: ["harness:invoke"],
    revokedAt: null,
  });

  const listed = service.listPairings({ requestedByLoopback: true });
  assert.equal(listed.pairings.length, 1);
  const summary = listed.pairings[0];
  assert.match(summary.pairingReference, /^vcp_[A-Za-z0-9_-]{43}$/);
  assert.equal(summary.deviceName, "Jaack iPhone");
  assert.equal(summary.status, "active");
  assert.equal(summary.revokedAt, null);
  assert.doesNotMatch(
    JSON.stringify(listed),
    /raw-pairing-identifier|private-phone|harness:invoke/,
  );

  const revoked = service.revokePairing({
    requestedByLoopback: true,
    pairingReference: summary.pairingReference,
  });
  assert.equal(revoked.status, "revoked");
  assert.equal(revoked.revokedAt, 1_000_000);
  assert.deepEqual(
    service.revokePairing({
      requestedByLoopback: true,
      pairingReference: summary.pairingReference,
    }),
    revoked,
  );
  assert.equal(store.get("raw-pairing-identifier").revokedAt, 1_000_000);

  assert.throws(
    () => service.listPairings({ requestedByLoopback: false }),
    /loopback/i,
  );
  assert.throws(
    () => service.revokePairing({
      requestedByLoopback: false,
      pairingReference: summary.pairingReference,
    }),
    /loopback/i,
  );
});

test("pairing rejects malformed phone keys and unexpected fields", () => {
  const { service } = makeService();
  const offer = service.begin({ requestedByLoopback: true });

  assert.throws(() => service.complete({
    pairingSecret: offer.pairingSecret,
    phonePublicKeyDER: Buffer.from("not-a-key").toString("base64"),
    deviceName: "iPhone",
  }), /key|asn1|decode/i);
  assert.throws(() => service.complete({
    pairingSecret: offer.pairingSecret,
    phonePublicKeyDER: Buffer.from("not-a-key").toString("base64"),
    deviceName: "iPhone",
    grantedScopes: ["anything"],
  }), /unexpected/i);
});
