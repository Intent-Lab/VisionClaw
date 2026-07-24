import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { RuntimeLock } from "../src/runtime-lock.mjs";

test("runtime lock permits only one broker and releases cleanly", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-lock-"));
  const first = new RuntimeLock({
    stateDirectory,
    pid: 101,
    isProcessAlive: () => true,
  });
  const second = new RuntimeLock({
    stateDirectory,
    pid: 202,
    isProcessAlive: () => true,
  });

  await first.acquire();
  await assert.rejects(second.acquire(), /already running/i);
  await first.release();
  await second.acquire();
  await second.release();
});

test("runtime lock safely replaces a stale owner", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-lock-stale-"));
  await writeFile(join(stateDirectory, "broker.lock"), "999999", {
    mode: 0o600,
  });
  const lock = new RuntimeLock({
    stateDirectory,
    pid: 303,
    isProcessAlive: () => false,
  });

  await lock.acquire();
  await lock.release();
});
