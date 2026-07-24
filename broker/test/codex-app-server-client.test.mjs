import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";
import test from "node:test";

import { CodexAppServerClient } from "../src/codex-app-server-client.mjs";

function fakeAppServer() {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = () => child.emit("exit", 0, null);
  const received = [];
  child.stdin = new Writable({
    write(chunk, _encoding, callback) {
      for (const line of chunk.toString().trim().split("\n")) {
        if (!line) continue;
        const message = JSON.parse(line);
        received.push(message);
        if (message.method === "initialize") {
          child.stdout.write(`${JSON.stringify({
            id: message.id,
            result: { userAgent: "codex-test" },
          })}\n`);
        } else if (message.method === "thread/list") {
          child.stdout.write(`${JSON.stringify({
            id: message.id,
            result: { data: [{ id: "thread-1" }] },
          })}\n`);
        }
      }
      callback();
    },
  });
  return { child, received };
}

test("client initializes, sends initialized, then handles requests", async () => {
  const fake = fakeAppServer();
  let spawnOptions;
  const client = new CodexAppServerClient({
    binaryPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
    processFactory: (_binary, _arguments, options) => {
      spawnOptions = options;
      return fake.child;
    },
    processEnvironment: {
      HOME: "/Users/test",
      PATH: "/usr/bin:/bin",
      OPENAI_API_KEY: "must-not-leak",
      CODEX_API_KEY: "must-not-leak",
      OPENCLAW_GATEWAY_TOKEN: "must-not-leak",
      VISIONCLAW_PAIRING_SECRET: "must-not-leak",
      UNRELATED_BROKER_SECRET: "must-not-leak",
    },
    requestTimeoutMilliseconds: 1_000,
  });
  const result = await client.request("thread/list", { limit: 3 });

  assert.deepEqual(result, { data: [{ id: "thread-1" }] });
  assert.equal(fake.received[0].method, "initialize");
  assert.equal(
    fake.received[0].params.clientInfo.name,
    "visionclaw-glasses-broker",
  );
  assert.deepEqual(fake.received[1], { method: "initialized", params: {} });
  assert.equal(fake.received[2].method, "thread/list");
  assert.equal(spawnOptions.env.CODEX_HOME, "/Users/test/.codex");
  assert.equal(spawnOptions.env.PATH, "/usr/bin:/bin");
  assert.equal("OPENAI_API_KEY" in spawnOptions.env, false);
  assert.equal("CODEX_API_KEY" in spawnOptions.env, false);
  assert.equal("OPENCLAW_GATEWAY_TOKEN" in spawnOptions.env, false);
  assert.equal("VISIONCLAW_PAIRING_SECRET" in spawnOptions.env, false);
  assert.equal("UNRELATED_BROKER_SECRET" in spawnOptions.env, false);
  client.close();
});

test("client safely declines every interactive app-server request", async () => {
  const fake = fakeAppServer();
  const client = new CodexAppServerClient({
    processFactory: () => fake.child,
    requestTimeoutMilliseconds: 1_000,
  });
  await client.start();
  const requests = [
    ["item/commandExecution/requestApproval", {
      decision: "decline",
      reason: "Continue in Codex Desktop to approve.",
    }],
    ["item/fileChange/requestApproval", {
      decision: "decline",
      reason: "Continue in Codex Desktop to approve.",
    }],
    ["item/permissions/requestApproval", {
      permissions: {},
      scope: "turn",
    }],
    ["item/tool/requestUserInput", { answers: {} }],
    ["mcpServer/elicitation/request", { action: "decline" }],
    ["item/tool/call", {
      contentItems: [{
        type: "inputText",
        text: "Unavailable in glasses broker.",
      }],
      success: false,
    }],
  ];

  for (const [index, [method]] of requests.entries()) {
    fake.child.stdout.write(`${JSON.stringify({
      id: 100 + index,
      method,
      params: {},
    })}\n`);
  }
  await new Promise((resolve) => setImmediate(resolve));

  for (const [index, [, expected]] of requests.entries()) {
    const response = fake.received.find((message) => message.id === 100 + index);
    assert.deepEqual(response, { id: 100 + index, result: expected });
  }
  client.close();
});

test("unknown server requests fail closed and process exit rejects pending calls", async () => {
  const fake = fakeAppServer();
  const client = new CodexAppServerClient({
    processFactory: () => fake.child,
    requestTimeoutMilliseconds: 1_000,
  });
  await client.start();
  fake.child.stdout.write("not-json\n");
  fake.child.stdout.write(`${JSON.stringify({
    id: 99,
    method: "unknown/request",
    params: {},
  })}\n`);
  await new Promise((resolve) => setImmediate(resolve));
  const refusal = fake.received.find((message) => message.id === 99);
  assert.equal(refusal.error.code, -32601);

  const pending = client.request("thread/read", { threadId: "thread-1" });
  await new Promise((resolve) => setImmediate(resolve));
  fake.child.emit("exit", 1, null);
  await assert.rejects(pending, /exited|closed/i);
});
