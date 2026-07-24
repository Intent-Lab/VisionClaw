import assert from "node:assert/strict";
import test from "node:test";

import {
  formatPairingURI,
  parseCLIOptions,
} from "../src/cli-options.mjs";
import { canonicalJSONString } from "../src/security.mjs";

test("CLI defaults to loopback and requires an explicit LAN switch", () => {
  assert.deepEqual(parseCLIOptions(["start"]), {
    command: "start",
    host: "127.0.0.1",
    port: 38_443,
  });
  assert.deepEqual(parseCLIOptions(["start", "--lan", "--port", "39001"]), {
    command: "start",
    host: "0.0.0.0",
    port: 39_001,
  });
  assert.deepEqual(parseCLIOptions(["pair", "--port=39001"]), {
    command: "pair",
    port: 39_001,
  });
  assert.deepEqual(parseCLIOptions(["status"]), {
    command: "status",
    port: 38_443,
  });
  assert.deepEqual(parseCLIOptions(["pairings", "--port=39001"]), {
    command: "pairings",
    port: 39_001,
  });
  assert.deepEqual(parseCLIOptions([
    "revoke",
    "vcp_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
  ]), {
    command: "revoke",
    pairingReference: "vcp_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
    port: 38_443,
  });
});

test("CLI rejects unknown commands, flags, and unsafe ports", () => {
  for (const argv of [
    [],
    ["shell"],
    ["start", "--public"],
    ["start", "--port", "0"],
    ["start", "--port", "70000"],
    ["pair", "--lan"],
    ["revoke"],
    ["revoke", "raw-pairing-id"],
    ["revoke", "vcp_" + "a".repeat(43), "extra"],
  ]) {
    assert.throws(() => parseCLIOptions(argv), /usage|unknown|port|flag/i);
  }
});

test("pairing URI round-trips only the explicit public offer", () => {
  const offer = {
    version: 1,
    brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
    endpoint: "https://visionclaw.local:38443",
    tlsPinSHA256: "a".repeat(64),
    pairingSecret: "pairing-secret-value-with-high-entropy-123456",
    expiresAt: 1_800_000_120_000,
  };
  const uri = formatPairingURI(offer);
  const parsed = new URL(uri);
  const payload = Buffer.from(
    parsed.searchParams.get("payload"),
    "base64url",
  ).toString("utf8");

  assert.equal(parsed.protocol, "visionclaw:");
  assert.equal(parsed.hostname, "pair");
  assert.equal(payload, canonicalJSONString(offer));
  assert.doesNotMatch(uri, /gateway|openclaw|owner|credential/i);
});
