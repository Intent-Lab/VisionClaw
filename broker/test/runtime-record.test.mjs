import assert from "node:assert/strict";
import { mkdtemp, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  readRuntimeRecord,
  removeRuntimeRecord,
  runtimeRecordIsLive,
  writeRuntimeRecord,
} from "../src/runtime-record.mjs";

test("runtime record is private, bounded, and contains no credential", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-record-"));
  await writeRuntimeRecord({
    stateDirectory,
    value: {
      brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
      host: "192.168.1.16",
      pid: 1234,
      port: 38_443,
      startedAt: 1_800_000_000_000,
    },
  });
  const loaded = await readRuntimeRecord({ stateDirectory });

  assert.deepEqual(loaded, {
    brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
    host: "192.168.1.16",
    pid: 1234,
    port: 38_443,
    startedAt: 1_800_000_000_000,
  });
  assert.equal(
    (await stat(join(stateDirectory, "runtime.json"))).mode & 0o777,
    0o600,
  );
  assert.doesNotMatch(JSON.stringify(loaded), /token|secret|credential/i);
  assert.equal(
    runtimeRecordIsLive(loaded, { isProcessAlive: (pid) => pid === 1234 }),
    true,
  );
  assert.equal(
    runtimeRecordIsLive(loaded, { isProcessAlive: () => false }),
    false,
  );

  await removeRuntimeRecord({ stateDirectory });
  await assert.rejects(
    readRuntimeRecord({ stateDirectory }),
    /not running/i,
  );
});

test("runtime record rejects public hosts and extra fields", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-record-bad-"));
  await assert.rejects(writeRuntimeRecord({
    stateDirectory,
    value: {
      brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
      host: "8.8.8.8",
      pid: 1234,
      port: 38_443,
      startedAt: 1_800_000_000_000,
      token: "must-not-write",
    },
  }), /invalid/i);
});
