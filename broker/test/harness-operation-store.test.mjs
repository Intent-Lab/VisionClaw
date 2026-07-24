import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { HarnessOperationStore } from "../src/harness-operation-store.mjs";

test("harness operation ownership and idempotency persist across restarts", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-operations-"));
  const path = join(directory, "state.sqlite3");
  const first = new HarnessOperationStore({ path });
  const created = first.create({
    pairingID: "pair-1",
    clientRequestID: "request-1",
    runID: "run-1",
  });
  first.close();

  const second = new HarnessOperationStore({ path });
  assert.deepEqual(
    second.findByRequest("pair-1", "request-1"),
    created,
  );
  assert.equal(second.getOwned(created.operationID, "pair-other"), null);
  assert.equal(
    second.getOwned(created.operationID, "pair-1").runID,
    "run-1",
  );
  assert.throws(() => second.create({
    pairingID: "pair-1",
    clientRequestID: "request-1",
    runID: "run-conflict",
  }), /conflict/i);
  second.close();
});

test("operation updates only move forward", () => {
  const store = new HarnessOperationStore({ path: ":memory:" });
  const created = store.create({
    pairingID: "pair-1",
    clientRequestID: "request-1",
    runID: "run-1",
  });
  store.updateByRun({
    runID: "run-1",
    status: "streaming",
    sequence: 2,
    response: "new",
    error: null,
  });
  store.updateByRun({
    runID: "run-1",
    status: "streaming",
    sequence: 1,
    response: "stale",
    error: null,
  });

  const loaded = store.getOwned(created.operationID, "pair-1");
  assert.equal(loaded.sequence, 2);
  assert.equal(loaded.response, "new");
  store.close();
});

test("startup recovery fails only persisted nonterminal operations", () => {
  const store = new HarnessOperationStore({ path: ":memory:" });
  const interrupted = store.create({
    pairingID: "pair-1",
    clientRequestID: "request-interrupted",
    runID: "run-interrupted",
    now: 100,
  });
  store.updateByRun({
    runID: "run-interrupted",
    status: "streaming",
    sequence: 4,
    response: "partial",
    now: 200,
  });
  const completed = store.create({
    pairingID: "pair-1",
    clientRequestID: "request-completed",
    runID: "run-completed",
    now: 100,
  });
  store.updateByRun({
    runID: "run-completed",
    status: "completed",
    sequence: 2,
    response: "done",
    now: 200,
  });

  assert.equal(store.failInterrupted({ now: 300 }), 1);
  assert.deepEqual(store.getOwned(interrupted.operationID, "pair-1"), {
    ...interrupted,
    status: "failed",
    sequence: 5,
    response: "partial",
    error:
      "Eva was interrupted because the glasses broker restarted. Check OpenClaw before trying again.",
    updatedAt: 300,
  });
  assert.equal(
    store.getOwned(completed.operationID, "pair-1").status,
    "completed",
  );
  assert.equal(store.failInterrupted({ now: 400 }), 0);
  store.close();
});
