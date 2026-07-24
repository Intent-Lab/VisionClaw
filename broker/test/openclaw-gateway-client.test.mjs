import assert from "node:assert/strict";
import test from "node:test";

import { OpenClawGatewayClient } from "../src/openclaw-gateway-client.mjs";

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;

  readyState = FakeWebSocket.CONNECTING;
  sent = [];
  #listeners = new Map();

  addEventListener(type, listener) {
    const listeners = this.#listeners.get(type) ?? new Set();
    listeners.add(listener);
    this.#listeners.set(type, listeners);
  }

  send(data) {
    if (this.readyState !== FakeWebSocket.OPEN) {
      throw new Error("Socket is not open.");
    }
    this.sent.push(JSON.parse(data));
  }

  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.#emit("open", {});
  }

  serverMessage(message) {
    this.#emit("message", { data: JSON.stringify(message) });
  }

  serverClose(code = 1006) {
    this.readyState = FakeWebSocket.CLOSED;
    this.#emit("close", { code });
  }

  close(code = 1000) {
    this.readyState = FakeWebSocket.CLOSED;
    this.#emit("close", { code });
  }

  #emit(type, event) {
    for (const listener of this.#listeners.get(type) ?? []) listener(event);
  }
}

test("Gateway client completes protocol v4 challenge authentication and reuses the socket", async () => {
  const sockets = [];
  const authCalls = [];
  const logEntries = [];
  const client = new OpenClawGatewayClient({
    url: "ws://127.0.0.1:16743",
    authProvider: async ({ nonce }) => {
      authCalls.push(nonce);
      return { auth: { token: "super-secret-token" } };
    },
    webSocketFactory: (url) => {
      assert.equal(url, "ws://127.0.0.1:16743");
      const socket = new FakeWebSocket();
      sockets.push(socket);
      return socket;
    },
    logger: (entry) => logEntries.push(entry),
  });

  const connecting = client.connect();
  sockets[0].open();
  sockets[0].serverMessage({
    type: "event",
    event: "connect.challenge",
    payload: { nonce: "challenge-1" },
  });
  await eventually(() => sockets[0].sent.length === 1);
  const connectRequest = sockets[0].sent[0];
  assert.equal(connectRequest.type, "req");
  assert.equal(connectRequest.method, "connect");
  assert.equal(connectRequest.params.minProtocol, 4);
  assert.equal(connectRequest.params.maxProtocol, 4);
  assert.equal(connectRequest.params.client.id, "gateway-client");
  assert.equal(
    connectRequest.params.client.displayName,
    "VisionClaw Glasses Broker",
  );
  assert.equal(connectRequest.params.client.mode, "backend");
  assert.deepEqual(connectRequest.params.auth, { token: "super-secret-token" });
  assert.deepEqual(authCalls, ["challenge-1"]);
  sockets[0].serverMessage({
    type: "res",
    id: connectRequest.id,
    ok: true,
    payload: { protocol: 4 },
  });
  await connecting;

  const request = client.request("chat.send", { message: "hello" });
  assert.equal(sockets.length, 1);
  await eventually(() => sockets[0].sent.length === 2);
  const chatRequest = sockets[0].sent[1];
  sockets[0].serverMessage({
    type: "res",
    id: chatRequest.id,
    ok: true,
    payload: { runId: "run-1", status: "started" },
  });
  assert.deepEqual(await request, { runId: "run-1", status: "started" });
  assert.doesNotMatch(JSON.stringify(logEntries), /super-secret-token/);
});

test("Gateway client forwards events and automatically reconnects after an unexpected close", async () => {
  const sockets = [];
  const connections = [];
  const events = [];
  const client = new OpenClawGatewayClient({
    authProvider: async () => ({ auth: { token: "secret" } }),
    webSocketFactory: () => {
      const socket = new FakeWebSocket();
      sockets.push(socket);
      return socket;
    },
    reconnectDelayMilliseconds: 0,
  });
  client.onConnection((event) => connections.push(event));
  client.onEvent((event) => events.push(event));

  const firstConnection = client.connect();
  await completeHandshake(sockets[0], "first");
  await firstConnection;
  sockets[0].serverMessage({
    type: "event",
    event: "chat",
    payload: { runId: "run-1", seq: 1, state: "delta", deltaText: "Hi" },
  });
  await eventually(() => events.length === 1);

  sockets[0].serverClose();
  await eventually(() => sockets.length === 2);
  await completeHandshake(sockets[1], "second");
  await eventually(() => connections.length === 2);

  assert.deepEqual(connections, [
    { reconnected: false },
    { reconnected: true },
  ]);
});

test("Gateway errors and auth failures never echo credentials", async () => {
  const sockets = [];
  const client = new OpenClawGatewayClient({
    authProvider: async () => {
      throw new Error("token=do-not-echo");
    },
    webSocketFactory: () => {
      const socket = new FakeWebSocket();
      sockets.push(socket);
      return socket;
    },
  });
  const connecting = client.connect();
  sockets[0].open();
  sockets[0].serverMessage({
    type: "event",
    event: "connect.challenge",
    payload: { nonce: "challenge" },
  });
  await assert.rejects(connecting, (error) => {
    assert.doesNotMatch(error.message, /do-not-echo/);
    assert.match(error.message, /authenticat/i);
    return true;
  });
  client.close();
});

async function completeHandshake(socket, nonce) {
  socket.open();
  socket.serverMessage({
    type: "event",
    event: "connect.challenge",
    payload: { nonce },
  });
  await eventually(() => {
    return socket.sent.some((message) => message.method === "connect");
  });
  const request = socket.sent.find((message) => message.method === "connect");
  socket.serverMessage({
    type: "res",
    id: request.id,
    ok: true,
    payload: { protocol: 4 },
  });
}

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
