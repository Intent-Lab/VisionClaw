import assert from "node:assert/strict";
import test from "node:test";

import { AsyncHarnessAdapter } from "../src/async-harness-adapter.mjs";
import { HarnessOperationStore } from "../src/harness-operation-store.mjs";
import { SecretRedactor } from "../src/security.mjs";

class FakeOpenClawAdapter {
  invocations = [];
  aborts = [];
  #listeners = new Set();

  async invoke(request) {
    this.invocations.push(request);
    return {
      status: "started",
      runID: `run-${this.invocations.length}`,
      clientRequestID: request.clientRequestID,
    };
  }

  onUpdate(listener) {
    this.#listeners.add(listener);
    return () => this.#listeners.delete(listener);
  }

  async abort(request) {
    this.aborts.push(request);
    return { status: "aborted", runID: request.runID };
  }

  emit(update) {
    for (const listener of this.#listeners) listener(update);
  }
}

function fixture({ exactSecrets = [] } = {}) {
  const backend = new FakeOpenClawAdapter();
  const store = new HarnessOperationStore({ path: ":memory:" });
  const adapter = new AsyncHarnessAdapter({
    backendAdapter: backend,
    operationStore: store,
    redactor: new SecretRedactor({ exactValues: exactSecrets }),
  });
  return { adapter, backend, store };
}

test("glasses receive an immediate opaque acknowledgement, never a raw run ID", async () => {
  const { adapter, backend } = fixture();
  const result = await adapter.invoke({
    agentID: "glasses",
    instruction: "List my agents",
    clientRequestID: "request-1",
    pairingID: "pair-1",
  });

  assert.equal(result.status, "started");
  assert.equal(result.clientRequestID, "request-1");
  assert.match(result.operationID, /^[A-Za-z0-9_-]{32,}$/);
  assert.match(result.message, /working/i);
  assert.doesNotMatch(JSON.stringify(result), /run-1/);
  assert.equal(backend.invocations.length, 1);
});

test("updates are pairing-bound, ordered, and pollable without backend identifiers", async () => {
  const { adapter, backend } = fixture();
  const started = await adapter.invoke({
    agentID: "glasses",
    instruction: "Status",
    clientRequestID: "request-2",
    pairingID: "pair-owner",
  });
  backend.emit({
    runID: "run-1",
    clientRequestID: "request-2",
    status: "streaming",
    sequence: 1,
    response: "Working",
  });
  backend.emit({
    runID: "run-1",
    clientRequestID: "request-2",
    status: "completed",
    sequence: 2,
    response: "Four agents are available.",
  });

  const result = adapter.poll({
    operationID: started.operationID,
    pairingID: "pair-owner",
    afterSequence: 0,
  });
  assert.deepEqual(result, {
    operationID: started.operationID,
    status: "completed",
    sequence: 2,
    response: "Four agents are available.",
    error: null,
  });
  assert.throws(() => adapter.poll({
    operationID: started.operationID,
    pairingID: "pair-attacker",
    afterSequence: 0,
  }), /not found/i);
  assert.doesNotMatch(JSON.stringify(result), /run-1|pair-owner/);
});

test("duplicate invoke is idempotent and cancellation targets the owned backend run", async () => {
  const { adapter, backend } = fixture();
  const request = {
    agentID: "glasses",
    instruction: "Long task",
    clientRequestID: "request-3",
    pairingID: "pair-owner",
  };
  const first = await adapter.invoke(request);
  const duplicate = await adapter.invoke(request);

  assert.deepEqual(duplicate, first);
  assert.equal(backend.invocations.length, 1);
  await assert.rejects(
    adapter.cancel({
      operationID: first.operationID,
      pairingID: "pair-attacker",
    }),
    /not found/i,
  );
  const cancelled = await adapter.cancel({
    operationID: first.operationID,
    pairingID: "pair-owner",
  });
  assert.deepEqual(cancelled, {
    operationID: first.operationID,
    status: "aborted",
  });
  assert.deepEqual(backend.aborts, [{
    runID: "run-1",
    pairingID: "pair-owner",
  }]);
});

test("no-change polling returns a bounded pending status", async () => {
  const { adapter } = fixture();
  const started = await adapter.invoke({
    agentID: "glasses",
    instruction: "Wait",
    clientRequestID: "request-4",
    pairingID: "pair-1",
  });

  assert.deepEqual(adapter.poll({
    operationID: started.operationID,
    pairingID: "pair-1",
    afterSequence: 0,
  }), {
    operationID: started.operationID,
    status: "pending",
    sequence: 0,
  });
});

test("backend output is scrubbed immediately before persistence and response", async () => {
  const exactSecret = "locally-loaded-token-that-has-no-label";
  const { adapter, backend, store } = fixture({
    exactSecrets: [exactSecret],
  });
  const started = await adapter.invoke({
    agentID: "glasses",
    instruction: "Never echo credentials",
    clientRequestID: "request-secret",
    pairingID: "pair-1",
  });
  backend.emit({
    runID: "run-1",
    clientRequestID: "request-secret",
    status: "completed",
    sequence: 1,
    response: JSON.stringify({
      result: exactSecret,
      nested: { gatewayToken: "quoted-output-secret" },
    }),
    error: "OPENAI_API_KEY=\"quoted-error-secret\"",
  });

  const persisted = store.getByRun("run-1");
  const response = adapter.poll({
    operationID: started.operationID,
    pairingID: "pair-1",
  });
  for (const value of [JSON.stringify(persisted), JSON.stringify(response)]) {
    assert.doesNotMatch(
      value,
      /locally-loaded-token|quoted-output-secret|quoted-error-secret/,
    );
    assert.match(value, /<redacted>/);
  }
});
