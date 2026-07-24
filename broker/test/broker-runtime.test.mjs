import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { createBrokerRuntime } from "../src/broker-runtime.mjs";
import { HarnessOperationStore } from "../src/harness-operation-store.mjs";
import { readRuntimeRecord } from "../src/runtime-record.mjs";
import { SecretValue } from "../src/runtime-state.mjs";

class FakeGatewayClient {
  events;
  agents;

  constructor(events, agents = [{ id: "glasses" }]) {
    this.events = events;
    this.agents = agents;
  }

  async connect() {
    this.events.push("gateway-connect");
  }

  close() {
    this.events.push("gateway-close");
  }

  async request(method) {
    this.events.push(`gateway-${method}`);
    if (method === "agents.list") {
      return { agents: this.agents };
    }
    throw new Error("Unexpected Gateway request.");
  }

  onEvent() {
    return () => {};
  }

  onConnection() {
    return () => {};
  }
}

class FakeCodexClient extends EventEmitter {
  events;
  startError;

  constructor(events, startError = null) {
    super();
    this.events = events;
    this.startError = startError;
  }

  async start() {
    this.events.push("codex-start");
    if (this.startError) throw this.startError;
  }

  close() {
    this.events.push("codex-close");
  }

  async request() {
    throw new Error("Unexpected Codex request.");
  }
}

test("composition starts backends before TLS, writes public state, and shuts down cleanly", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-runtime-"));
  const events = [];
  let serverOptions;
  const runtime = await createBrokerRuntime({
    stateDirectory,
    host: "127.0.0.1",
    port: 38_443,
    gatewayConfigLoader: async () => ({
      url: "ws://127.0.0.1:16743",
      token: new SecretValue("gateway-token-value-for-tests"),
    }),
    gatewayClientFactory: () => new FakeGatewayClient(events),
    codexClientFactory: () => new FakeCodexClient(events),
    serverFactory(options) {
      serverOptions = options;
      return {
        port: 38_443,
        async start() {
          events.push("server-start");
        },
        async stop() {
          events.push("server-stop");
        },
      };
    },
  });

  await runtime.start();
  const record = await readRuntimeRecord({ stateDirectory });
  assert.equal(record.host, "127.0.0.1");
  assert.equal(record.port, 38_443);
  assert.match(serverOptions.adminToken, /^[A-Za-z0-9_-]{43}$/);
  assert.deepEqual(events.slice(0, 4), [
    "gateway-connect",
    "codex-start",
    "gateway-agents.list",
    "server-start",
  ]);
  const offer = serverOptions.pairingService.begin({
    requestedByLoopback: true,
  });
  assert.equal(offer.endpoint, "https://127.0.0.1:38443");
  assert.doesNotMatch(JSON.stringify(record), /gateway-token-value-for-tests/);

  const health = await serverOptions.application.dispatch({
    method: "GET",
    path: "/healthz",
    rawBody: "",
  });
  assert.equal(health.statusCode, 200);
  assert.doesNotMatch(
    JSON.stringify({ record, offer, health }),
    new RegExp(serverOptions.adminToken),
  );

  await runtime.stop();
  assert.deepEqual(events.slice(-3), [
    "server-stop",
    "gateway-close",
    "codex-close",
  ]);
  await assert.rejects(
    readRuntimeRecord({ stateDirectory }),
    /not running/i,
  );
  await assert.rejects(runtime.start(), /stopped|already/i);
});

test("failed backend startup closes initialized components and leaves no runtime record", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-runtime-fail-"));
  const events = [];
  let serverStarted = false;
  const runtime = await createBrokerRuntime({
    stateDirectory,
    host: "127.0.0.1",
    port: 38_443,
    gatewayConfigLoader: async () => ({
      url: "ws://127.0.0.1:16743",
      token: new SecretValue("gateway-token-value-for-tests"),
    }),
    gatewayClientFactory: () => new FakeGatewayClient(events),
    codexClientFactory: () => new FakeCodexClient(
      events,
      new Error("Codex unavailable"),
    ),
    serverFactory() {
      return {
        port: 38_443,
        async start() {
          serverStarted = true;
        },
        async stop() {},
      };
    },
  });

  await assert.rejects(runtime.start(), /Codex unavailable/);
  assert.equal(serverStarted, false);
  assert.ok(events.includes("gateway-close"));
  assert.ok(events.includes("codex-close"));
  await assert.rejects(
    readRuntimeRecord({ stateDirectory }),
    /not running/i,
  );
});

test("missing glasses agent fails closed before the TLS listener starts", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-runtime-agent-"));
  const events = [];
  let serverStarted = false;
  const runtime = await createBrokerRuntime({
    stateDirectory,
    host: "127.0.0.1",
    port: 38_443,
    gatewayConfigLoader: async () => ({
      url: "ws://127.0.0.1:16743",
      token: new SecretValue("gateway-token-value-for-tests"),
    }),
    gatewayClientFactory: () => new FakeGatewayClient(
      events,
      [{ id: "default" }],
    ),
    codexClientFactory: () => new FakeCodexClient(events),
    serverFactory() {
      return {
        port: 38_443,
        async start() {
          serverStarted = true;
        },
        async stop() {},
      };
    },
  });

  await assert.rejects(runtime.start(), /agent glasses/i);
  assert.equal(serverStarted, false);
  assert.ok(events.includes("gateway-close"));
  assert.ok(events.includes("codex-close"));
  await assert.rejects(
    readRuntimeRecord({ stateDirectory }),
    /not running/i,
  );
});

test("startup fails a persisted nonterminal Eva operation after acquiring ownership", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-runtime-restart-"));
  const databasePath = join(stateDirectory, "broker.sqlite3");
  const seedStore = new HarnessOperationStore({ path: databasePath });
  const interrupted = seedStore.create({
    pairingID: "pair-owner",
    clientRequestID: "request-before-restart",
    runID: "run-before-restart",
    now: 100,
  });
  seedStore.updateByRun({
    runID: "run-before-restart",
    status: "streaming",
    sequence: 1,
    response: "Partial response",
    now: 200,
  });
  seedStore.close();

  const events = [];
  let serverOptions;
  const runtime = await createBrokerRuntime({
    stateDirectory,
    host: "127.0.0.1",
    port: 38_443,
    gatewayConfigLoader: async () => ({
      url: "ws://127.0.0.1:16743",
      token: new SecretValue("gateway-token-value-for-tests"),
    }),
    gatewayClientFactory: () => new FakeGatewayClient(events),
    codexClientFactory: () => new FakeCodexClient(events),
    serverFactory(options) {
      serverOptions = options;
      return {
        port: 38_443,
        async start() {},
        async stop() {},
      };
    },
    now: () => 300,
  });

  assert.equal(serverOptions.application.harnessOperations.poll({
    operationID: interrupted.operationID,
    pairingID: "pair-owner",
    afterSequence: 1,
  }).status, "pending");

  await runtime.start();
  assert.deepEqual(serverOptions.application.harnessOperations.poll({
    operationID: interrupted.operationID,
    pairingID: "pair-owner",
    afterSequence: 1,
  }), {
    operationID: interrupted.operationID,
    status: "failed",
    sequence: 2,
    response: "Partial response",
    error:
      "Eva was interrupted because the glasses broker restarted. Check OpenClaw before trying again.",
  });
  await runtime.stop();
});
