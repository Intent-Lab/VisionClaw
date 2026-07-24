import assert from "node:assert/strict";
import test from "node:test";

import { AsyncHarnessAdapter } from "../src/async-harness-adapter.mjs";
import { HarnessOperationStore } from "../src/harness-operation-store.mjs";
import { OpenClawAdapter } from "../src/openclaw-adapter.mjs";

class FakeGatewayClient {
  requests = [];
  connectCalls = 0;
  #eventListeners = new Set();
  #connectionListeners = new Set();
  #responses = [];

  async connect() {
    this.connectCalls += 1;
  }

  queueResponse(response) {
    this.#responses.push(response);
  }

  async request(method, params) {
    this.requests.push({ method, params });
    const response = this.#responses.shift();
    if (response instanceof Error) throw response;
    if (typeof response === "function") {
      return response({ method, params });
    }
    return response;
  }

  onEvent(listener) {
    this.#eventListeners.add(listener);
    return () => this.#eventListeners.delete(listener);
  }

  onConnection(listener) {
    this.#connectionListeners.add(listener);
    return () => this.#connectionListeners.delete(listener);
  }

  emitEvent(event) {
    for (const listener of this.#eventListeners) listener(event);
  }

  emitConnection(event) {
    for (const listener of this.#connectionListeners) listener(event);
  }
}

test("invoke uses the fixed agent/session mapping and returns the Gateway ACK", async () => {
  const gateway = new FakeGatewayClient();
  gateway.queueResponse({ runId: "run-1", status: "started" });
  const adapter = new OpenClawAdapter({
    gatewayClient: gateway,
    allowedAgentIDs: ["glasses"],
  });

  const result = await adapter.invoke({
    agentID: "glasses",
    instruction: "Reply with status.",
    clientRequestID: "request-1",
    pairingID: "pairing-sensitive-value",
  });

  assert.deepEqual(result, {
    status: "started",
    runID: "run-1",
    clientRequestID: "request-1",
  });
  assert.equal(gateway.connectCalls, 1);
  assert.equal(gateway.requests.length, 1);
  assert.equal(gateway.requests[0].method, "chat.send");
  assert.deepEqual(
    Object.keys(gateway.requests[0].params).sort(),
    [
      "agentId",
      "deliver",
      "fastAutoOnSeconds",
      "fastMode",
      "idempotencyKey",
      "message",
      "sessionKey",
      "timeoutMs",
    ].sort(),
  );
  assert.equal(gateway.requests[0].params.agentId, "glasses");
  assert.match(
    gateway.requests[0].params.sessionKey,
    /^agent:glasses:visionclaw:[a-f0-9]{16}$/,
  );
  assert.doesNotMatch(
    gateway.requests[0].params.sessionKey,
    /pairing-sensitive-value/,
  );
  assert.equal(gateway.requests[0].params.idempotencyKey, "request-1");
  assert.equal(gateway.requests[0].params.deliver, false);
  assert.equal(gateway.requests[0].params.fastMode, "auto");
  assert.equal(gateway.requests[0].params.fastAutoOnSeconds, 20);
  assert.equal(gateway.requests[0].params.timeoutMs, 600_000);
  assert.match(
    gateway.requests[0].params.message,
    /User request:\nReply with status\.$/,
  );
});

test("adapter rejects an unregistered agent before contacting the Gateway", async () => {
  const gateway = new FakeGatewayClient();
  const adapter = new OpenClawAdapter({
    gatewayClient: gateway,
    allowedAgentIDs: ["glasses"],
  });

  await assert.rejects(
    adapter.invoke({
      agentID: "main",
      instruction: "do something",
      clientRequestID: "request-2",
      pairingID: "pair-1",
    }),
    /not registered|not allowed/i,
  );
  assert.equal(gateway.connectCalls, 0);
  assert.equal(gateway.requests.length, 0);
});

test("chat events are ordered, deduplicated, replace-aware, and redacted", async () => {
  const gateway = new FakeGatewayClient();
  gateway.queueResponse({ runId: "run-stream", status: "started" });
  const adapter = new OpenClawAdapter({
    gatewayClient: gateway,
    allowedAgentIDs: ["glasses"],
  });
  const updates = [];
  adapter.onUpdate((update) => updates.push(update));
  await adapter.invoke({
    agentID: "glasses",
    instruction: "stream",
    clientRequestID: "request-stream",
    pairingID: "pair-stream",
  });

  gateway.emitEvent({
    event: "chat",
    payload: {
      runId: "run-stream",
      seq: 1,
      state: "delta",
      deltaText: "Hello",
    },
  });
  gateway.emitEvent({
    event: "chat",
    payload: {
      runId: "run-stream",
      seq: 1,
      state: "delta",
      deltaText: " duplicate",
    },
  });
  gateway.emitEvent({
    event: "chat",
    payload: {
      runId: "run-stream",
      seq: 2,
      state: "delta",
      deltaText: " world",
    },
  });
  gateway.emitEvent({
    event: "chat",
    payload: {
      runId: "run-stream",
      seq: 3,
      state: "delta",
      replace: true,
      deltaText: "Corrected",
    },
  });
  gateway.emitEvent({
    event: "chat",
    payload: {
      runId: "run-stream",
      seq: 4,
      state: "final",
      message: {
        content: [{
          type: "text",
          text: "Authorization: Bearer secret-token-value final",
        }],
      },
    },
  });

  assert.equal(updates.length, 4);
  assert.deepEqual(
    updates.slice(0, 3).map((update) => update.response),
    ["Hello", "Hello world", "Corrected"],
  );
  assert.equal(updates[2].replace, true);
  assert.equal(updates[3].status, "completed");
  assert.equal(updates[3].sequence, 4);
  assert.doesNotMatch(updates[3].response, /secret-token-value/);
  assert.match(updates[3].response, /<redacted>/);
});

test("aborted and error events become terminal updates without leaking errors", async () => {
  const gateway = new FakeGatewayClient();
  gateway.queueResponse({ runId: "run-abort", status: "started" });
  gateway.queueResponse({ runId: "run-error", status: "started" });
  const adapter = new OpenClawAdapter({
    gatewayClient: gateway,
    allowedAgentIDs: ["glasses"],
  });
  const updates = [];
  adapter.onUpdate((update) => updates.push(update));
  await adapter.invoke({
    agentID: "glasses",
    instruction: "one",
    clientRequestID: "request-abort",
    pairingID: "pair-1",
  });
  await adapter.invoke({
    agentID: "glasses",
    instruction: "two",
    clientRequestID: "request-error",
    pairingID: "pair-1",
  });

  gateway.emitEvent({
    event: "chat",
    payload: { runId: "run-abort", seq: 1, state: "aborted" },
  });
  gateway.emitEvent({
    event: "chat",
    payload: {
      runId: "run-error",
      seq: 1,
      state: "error",
      errorMessage: "API_KEY=do-not-leak",
    },
  });

  assert.equal(updates[0].status, "aborted");
  assert.equal(updates[1].status, "failed");
  assert.doesNotMatch(updates[1].error, /do-not-leak/);
});

test("abort targets only an active run owned by the same pairing", async () => {
  const gateway = new FakeGatewayClient();
  gateway.queueResponse({ runId: "run-owned", status: "started" });
  gateway.queueResponse({ status: "aborted" });
  const adapter = new OpenClawAdapter({
    gatewayClient: gateway,
    allowedAgentIDs: ["glasses"],
  });
  await adapter.invoke({
    agentID: "glasses",
    instruction: "long task",
    clientRequestID: "request-owned",
    pairingID: "pair-owner",
  });

  await assert.rejects(
    adapter.abort({ runID: "run-other", pairingID: "pair-owner" }),
    /not owned|not active/i,
  );
  await assert.rejects(
    adapter.abort({ runID: "run-owned", pairingID: "pair-attacker" }),
    /not owned|not active/i,
  );
  const result = await adapter.abort({
    runID: "run-owned",
    pairingID: "pair-owner",
  });

  assert.deepEqual(result, { status: "aborted", runID: "run-owned" });
  assert.deepEqual(gateway.requests.at(-1), {
    method: "chat.abort",
    params: {
      sessionKey: gateway.requests[0].params.sessionKey,
      agentId: "glasses",
      runId: "run-owned",
    },
  });
});

test("reconnect reconciles active runs with agent.wait and bounded history", async () => {
  const gateway = new FakeGatewayClient();
  gateway.queueResponse({ runId: "run-reconnect", status: "started" });
  gateway.queueResponse({ status: "completed" });
  gateway.queueResponse({
    messages: [
      {
        role: "user",
        idempotencyKey: "run-reconnect:user",
        content: [{ type: "text", text: "recover me" }],
      },
      {
        role: "assistant",
        content: [{ type: "text", text: "Recovered final answer" }],
      },
      {
        role: "user",
        idempotencyKey: "another-run:user",
        content: [{ type: "text", text: "later request" }],
      },
      {
        role: "assistant",
        content: [{ type: "text", text: "Wrong later answer" }],
      },
    ],
  });
  const adapter = new OpenClawAdapter({
    gatewayClient: gateway,
    allowedAgentIDs: ["glasses"],
    historyLimit: 25,
  });
  const updates = [];
  adapter.onUpdate((update) => updates.push(update));
  await adapter.invoke({
    agentID: "glasses",
    instruction: "recover me",
    clientRequestID: "request-reconnect",
    pairingID: "pair-reconnect",
  });

  gateway.emitConnection({ reconnected: true });
  await eventually(() => updates.length === 1);

  assert.deepEqual(gateway.requests.slice(1), [
    {
      method: "agent.wait",
      params: { runId: "run-reconnect", timeoutMs: 0 },
    },
    {
      method: "chat.history",
      params: {
        sessionKey: gateway.requests[0].params.sessionKey,
        agentId: "glasses",
        limit: 25,
      },
    },
  ]);
  assert.equal(updates[0].status, "completed");
  assert.equal(updates[0].response, "Recovered final answer");
});

test("reconnect before the first live event persists the recovered completion", async () => {
  const gateway = new FakeGatewayClient();
  gateway.queueResponse({ runId: "run-early-reconnect", status: "started" });
  gateway.queueResponse({ status: "completed" });
  gateway.queueResponse({
    messages: [{
      role: "assistant",
      runId: "run-early-reconnect",
      content: [{ type: "text", text: "Recovered before any delta" }],
    }],
  });
  const backend = new OpenClawAdapter({
    gatewayClient: gateway,
    allowedAgentIDs: ["glasses"],
  });
  const store = new HarnessOperationStore({ path: ":memory:" });
  const adapter = new AsyncHarnessAdapter({
    backendAdapter: backend,
    operationStore: store,
  });

  try {
    const acknowledgement = await adapter.invoke({
      agentID: "glasses",
      instruction: "recover immediately",
      clientRequestID: "request-early-reconnect",
      pairingID: "pair-early-reconnect",
    });

    gateway.emitConnection({ reconnected: true });
    await eventually(() => adapter.poll({
      operationID: acknowledgement.operationID,
      pairingID: "pair-early-reconnect",
      afterSequence: 0,
    }).status === "completed");

    assert.deepEqual(adapter.poll({
      operationID: acknowledgement.operationID,
      pairingID: "pair-early-reconnect",
      afterSequence: 0,
    }), {
      operationID: acknowledgement.operationID,
      status: "completed",
      sequence: 1,
      response: "Recovered before any delta",
      error: null,
    });
  } finally {
    store.close();
  }
});

async function eventually(predicate, {
  timeoutMilliseconds = 500,
  intervalMilliseconds = 5,
} = {}) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error("Condition was not met before the test timeout.");
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMilliseconds));
  }
}
