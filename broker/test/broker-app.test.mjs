import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { Readable } from "node:stream";
import test from "node:test";

import {
  BrokerAuthorization,
  MemoryPairingStore,
} from "../src/broker-authorization.mjs";
import {
  MAX_REQUEST_BODY_BYTES,
  createBrokerApplication,
} from "../src/broker-app.mjs";
import {
  CapabilityIssuer,
  ReplayGuard,
  canonicalJSONString,
  createDeviceRequestProof,
  publicKeyThumbprint,
  sha256Base64URL,
} from "../src/security.mjs";

const BASE_HEADERS = Object.freeze({
  "content-type": "application/json",
  "x-visionclaw-device-proof": "MEUCIQDFakeDeviceProofValueForControllerTests",
  "x-visionclaw-pairing-id": "pairing-1",
  "x-visionclaw-proof-nonce": "nonce-123456",
  "x-visionclaw-proof-timestamp": "1800000000000",
});

function fixture(overrides = {}) {
  const events = [];
  const authorization = overrides.authorization ?? {
    issueCapability(request) {
      events.push(["authorize-capability", request]);
      return "header.payload.signature";
    },
    authorize(request) {
      events.push(["authorize-route", request]);
      return { scope: request.scope, sub: request.pairingID };
    },
    authorizeSessionStatus(request) {
      events.push(["authorize-session-status", request]);
      return { sub: request.pairingID };
    },
  };
  const pairingService = overrides.pairingService ?? {
    async complete(request) {
      events.push(["pair", request]);
      return {
        pairingID: "pairing-1",
        brokerID: "broker-1",
        grantedScopes: ["harness:invoke", "tasks:list"],
        pairedAt: 1_800_000_000_000,
        pairingSecret: "must-not-be-returned",
      };
    },
  };
  const harnessRouter = overrides.harnessRouter ?? {
    async invoke(request) {
      events.push(["harness", request]);
      return {
        clientRequestID: request.clientRequestID,
        response: "There are fourteen agents.",
        status: "completed",
      };
    },
  };
  const harnessOperations = overrides.harnessOperations ?? {
    poll(request) {
      events.push(["harness-poll", request]);
      return {
        operationID: request.operationID,
        sequence: 1,
        status: "completed",
        response: "Done",
        error: null,
      };
    },
    async cancel(request) {
      events.push(["harness-cancel", request]);
      return { operationID: request.operationID, status: "aborted" };
    },
  };
  const codexAdapter = overrides.codexAdapter ?? {
    async list(request) {
      events.push(["codex-list", request]);
      return { tasks: [] };
    },
    async read(request) {
      events.push(["codex-read", request]);
      return { status: "idle", taskReference: request.taskReference };
    },
    async status(request) {
      events.push(["codex-status", request]);
      return { status: "idle", taskReference: request.taskReference };
    },
    async prepareContinue(request) {
      events.push(["codex-prepare", request]);
      return { actionID: "action-1", confirmationNonce: "confirm-1" };
    },
    async commitContinue(request) {
      events.push(["codex-commit", request]);
      return { forkedTaskReference: "fork-1", status: "started" };
    },
    operationStatus(request) {
      events.push(["codex-operation-status", request]);
      return { state: "completed", receipt: { status: "completed" } };
    },
    async cancelPrepared(request) {
      events.push(["codex-cancel", request]);
      return { cancelled: true };
    },
  };
  const app = createBrokerApplication({
    authorization,
    codexAdapter,
    harnessOperations,
    harnessRouter,
    pairingService,
    readiness: overrides.readiness ?? (() => true),
    brokerID: "broker-1",
    version: "0.1.0-test",
  });
  return { app, events };
}

function protectedHeaders(overrides = {}) {
  return {
    ...BASE_HEADERS,
    authorization: "Bearer header.payload.signature",
    ...overrides,
  };
}

async function dispatchJSON(app, {
  method = "POST",
  path,
  value,
  rawBody,
  headers = protectedHeaders(),
}) {
  const response = await app.dispatch({
    method,
    path,
    headers,
    rawBody: rawBody ?? canonicalJSONString(value),
  });
  return {
    ...response,
    json: JSON.parse(response.body),
  };
}

test("health exposes only readiness and version", async () => {
  const { app } = fixture();
  const response = await dispatchJSON(app, {
    method: "GET",
    path: "/healthz",
    rawBody: "",
    headers: {},
  });

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json, {
    ready: true,
    version: "0.1.0-test",
  });
  assert.deepEqual(Object.keys(response.json).sort(), ["ready", "version"]);
});

test("session status uses device proof without a capability and exposes only public status", async () => {
  const now = () => 1_800_000_000_000;
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const attacker = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const publicKeyDER = publicKey.export({ type: "spki", format: "der" });
  const pairings = new MemoryPairingStore();
  pairings.save({
    pairingID: "pairing-1",
    brokerID: "broker-1",
    phoneKeyThumbprint: publicKeyThumbprint(publicKeyDER),
    phonePublicKeyDER: publicKeyDER,
    deviceName: "Jaack iPhone",
    pairedAt: now(),
    grantedScopes: ["harness:invoke"],
    revokedAt: null,
  });
  const authorization = new BrokerAuthorization({
    pairingStore: pairings,
    capabilityIssuer: new CapabilityIssuer({
      issuer: "visionclaw-broker:broker-1",
      audience: "visionclaw-ios",
      signingKey: Buffer.alloc(32, 3),
      now,
    }),
    replayGuard: new ReplayGuard({ now }),
    now,
  });
  const { app } = fixture({ authorization });
  const rawBody = "{}";
  const requestFor = (pairingID, nonce) => ({
    pairingID,
    bodyHash: sha256Base64URL(rawBody),
    method: "POST",
    nonce,
    path: "/v1/session/status",
    timestamp: now(),
  });
  const headersFor = (request, signingKey) => ({
    "content-type": "application/json",
    "x-visionclaw-device-proof": createDeviceRequestProof(
      request,
      signingKey,
    ),
    "x-visionclaw-pairing-id": request.pairingID,
    "x-visionclaw-proof-nonce": request.nonce,
    "x-visionclaw-proof-timestamp": String(request.timestamp),
  });

  const validRequest = requestFor("pairing-1", "status-valid-1");
  const valid = await dispatchJSON(app, {
    path: "/v1/session/status",
    rawBody,
    headers: headersFor(validRequest, privateKey),
  });
  assert.equal(valid.statusCode, 200);
  assert.deepEqual(valid.json, {
    brokerID: "broker-1",
    ready: true,
    version: "0.1.0-test",
  });
  assert.deepEqual(
    Object.keys(valid.json).sort(),
    ["brokerID", "ready", "version"],
  );
  assert.doesNotMatch(
    valid.body,
    /pairing-1|private-thumbprint|device-proof|capability|token|secret/i,
  );

  const extraField = await dispatchJSON(app, {
    path: "/v1/session/status",
    value: { includeSecrets: true },
    headers: headersFor(
      requestFor("pairing-1", "status-extra-field"),
      privateKey,
    ),
  });
  assert.equal(extraField.statusCode, 400);

  const wrongPairingRequest = requestFor("pairing-2", "status-wrong-pair");
  const wrongPairing = await dispatchJSON(app, {
    path: "/v1/session/status",
    rawBody,
    headers: headersFor(wrongPairingRequest, privateKey),
  });
  assert.equal(wrongPairing.statusCode, 401);

  const wrongProofRequest = requestFor("pairing-1", "status-wrong-proof");
  const wrongProof = await dispatchJSON(app, {
    path: "/v1/session/status",
    rawBody,
    headers: headersFor(wrongProofRequest, attacker.privateKey),
  });
  assert.equal(wrongProof.statusCode, 401);

  pairings.revoke("pairing-1", now());
  const revokedRequest = requestFor("pairing-1", "status-revoked-1");
  const revoked = await dispatchJSON(app, {
    path: "/v1/session/status",
    rawBody,
    headers: headersFor(revokedRequest, privateKey),
  });
  assert.equal(revoked.statusCode, 401);
  for (const response of [wrongPairing, wrongProof, revoked]) {
    assert.deepEqual(response.json.error, {
      code: "unauthorized",
      message: "Device authorization failed.",
    });
    assert.doesNotMatch(
      response.body,
      /pairing-[12]|private-thumbprint|proof|token|secret/i,
    );
  }
});

test("pairing completion accepts only the typed canonical payload and projects a safe response", async () => {
  const { app, events } = fixture();
  const publicKeyDER = Buffer.from("fake-spki-der").toString("base64url");
  const response = await dispatchJSON(app, {
    path: "/v1/pairing/complete",
    headers: { "content-type": "application/json" },
    value: {
      deviceName: "Jaack iPhone",
      pairingSecret: "pairing-secret-value-1234567890",
      phonePublicKeyDER: publicKeyDER,
    },
  });

  assert.equal(response.statusCode, 201);
  assert.deepEqual(response.json, {
    brokerID: "broker-1",
    grantedScopes: ["harness:invoke", "tasks:list"],
    pairedAt: 1_800_000_000_000,
    pairingID: "pairing-1",
  });
  assert.deepEqual(events, [[
    "pair",
    {
      deviceName: "Jaack iPhone",
      pairingSecret: "pairing-secret-value-1234567890",
      phonePublicKeyDER: Buffer.from("fake-spki-der"),
    },
  ]]);

  const rejected = await dispatchJSON(app, {
    path: "/v1/pairing/complete",
    headers: { "content-type": "application/json" },
    value: {
      deviceName: "Jaack iPhone",
      pairingSecret: "pairing-secret-value-1234567890",
      phonePublicKeyDER: publicKeyDER,
      routeTarget: "shell",
    },
  });
  assert.equal(rejected.statusCode, 400);
  assert.equal(events.length, 1);
});

test("malformed pairing-service output is treated as an internal failure", async () => {
  const { app } = fixture({
    pairingService: {
      async complete() {
        return {
          pairingID: "invalid id containing a secret-value",
          brokerID: "broker-1",
          grantedScopes: [],
          pairedAt: 1_800_000_000_000,
        };
      },
    },
  });
  const response = await dispatchJSON(app, {
    path: "/v1/pairing/complete",
    headers: { "content-type": "application/json" },
    value: {
      deviceName: "Jaack iPhone",
      pairingSecret: "pairing-secret-value-1234567890",
      phonePublicKeyDER: Buffer.from("fake-spki-der").toString("base64url"),
    },
  });

  assert.equal(response.statusCode, 500);
  assert.doesNotMatch(response.body, /secret-value|invalid id/i);
});

test("canonical JSON and the 64 KiB limit are enforced before services run", async () => {
  const { app, events } = fixture();
  const nonCanonical = await dispatchJSON(app, {
    path: "/v1/harness/invoke",
    rawBody: "{\"instruction\":\"hello\",\"harnessID\":\"eva\",\"clientRequestID\":\"r-1\"}",
  });
  assert.equal(nonCanonical.statusCode, 400);

  const oversized = await dispatchJSON(app, {
    path: "/v1/harness/invoke",
    rawBody: " ".repeat(MAX_REQUEST_BODY_BYTES + 1),
  });
  assert.equal(oversized.statusCode, 413);
  assert.deepEqual(events, []);
});

test("capability issuance verifies the device proof and returns only the token", async () => {
  const { app, events } = fixture();
  const body = {
    bodyHash: sha256Base64URL("{}"),
    method: "POST",
    path: "/v1/codex/list",
    scope: "tasks:list",
  };
  const rawBody = canonicalJSONString(body);
  const response = await dispatchJSON(app, {
    path: "/v1/capabilities",
    rawBody,
    headers: BASE_HEADERS,
  });

  assert.equal(response.statusCode, 201);
  assert.deepEqual(response.json, {
    capability: "header.payload.signature",
  });
  assert.equal(events[0][0], "authorize-capability");
  assert.deepEqual(events[0][1], {
    pairingID: "pairing-1",
    body,
    proof: BASE_HEADERS["x-visionclaw-device-proof"],
    proofRequest: {
      pairingID: "pairing-1",
      bodyHash: sha256Base64URL(rawBody),
      method: "POST",
      nonce: "nonce-123456",
      path: "/v1/capabilities",
      timestamp: 1_800_000_000_000,
    },
  });
});

test("every protected route authorizes capability and proof before calling an adapter", async () => {
  const cases = [
    {
      path: "/v1/harness/invoke",
      scope: "harness:invoke",
      event: "harness",
      value: {
        clientRequestID: "request-1",
        harnessID: "eva",
        instruction: "List agents",
      },
      adapterRequest: {
        clientRequestID: "request-1",
        harnessID: "eva",
        instruction: "List agents",
        pairingID: "pairing-1",
      },
    },
    {
      path: "/v1/harness/poll",
      scope: "harness:read",
      event: "harness-poll",
      value: {
        afterSequence: 0,
        operationID: "operation-1",
      },
      adapterRequest: {
        afterSequence: 0,
        operationID: "operation-1",
        pairingID: "pairing-1",
      },
    },
    {
      path: "/v1/harness/cancel",
      scope: "harness:cancel",
      event: "harness-cancel",
      value: {
        clientRequestID: "request-cancel-1",
        operationID: "operation-1",
      },
      adapterRequest: {
        clientRequestID: "request-cancel-1",
        operationID: "operation-1",
        pairingID: "pairing-1",
      },
    },
    {
      path: "/v1/codex/list",
      scope: "tasks:list",
      event: "codex-list",
      value: { limit: 10 },
      adapterRequest: { limit: 10, pairingID: "pairing-1" },
    },
    {
      path: "/v1/codex/read",
      scope: "tasks:read",
      event: "codex-read",
      value: { taskReference: "task-1" },
      adapterRequest: {
        pairingID: "pairing-1",
        taskReference: "task-1",
      },
    },
    {
      path: "/v1/codex/status",
      scope: "tasks:status",
      event: "codex-status",
      value: { taskReference: "task-1" },
      adapterRequest: {
        pairingID: "pairing-1",
        taskReference: "task-1",
      },
    },
    {
      path: "/v1/codex/prepare",
      scope: "tasks:continue",
      event: "codex-prepare",
      value: {
        clientRequestID: "request-2",
        instruction: "Continue the task",
        taskReference: "task-1",
      },
      adapterRequest: {
        clientRequestID: "request-2",
        instruction: "Continue the task",
        pairingID: "pairing-1",
        taskReference: "task-1",
      },
    },
    {
      path: "/v1/codex/commit",
      scope: "tasks:continue:commit",
      event: "codex-commit",
      value: {
        actionID: "action-1",
        clientRequestID: "request-3",
        confirmationNonce: "confirm-1",
      },
      adapterRequest: {
        actionID: "action-1",
        clientRequestID: "request-3",
        confirmationNonce: "confirm-1",
        pairingID: "pairing-1",
      },
    },
    {
      path: "/v1/codex/operation-status",
      scope: "tasks:operation:status",
      event: "codex-operation-status",
      value: {
        actionID: "action-1",
        clientRequestID: "request-3",
      },
      adapterRequest: {
        actionID: "action-1",
        clientRequestID: "request-3",
        pairingID: "pairing-1",
      },
    },
    {
      path: "/v1/codex/cancel",
      scope: "tasks:cancel",
      event: "codex-cancel",
      value: {
        actionID: "action-1",
        clientRequestID: "request-4",
      },
      adapterRequest: {
        actionID: "action-1",
        clientRequestID: "request-4",
        pairingID: "pairing-1",
      },
    },
  ];

  for (const item of cases) {
    const { app, events } = fixture();
    const rawBody = canonicalJSONString(item.value);
    const response = await dispatchJSON(app, {
      path: item.path,
      rawBody,
    });
    assert.ok(response.statusCode >= 200 && response.statusCode < 300);
    assert.equal(events.length, 2);
    assert.equal(events[0][0], "authorize-route");
    assert.equal(events[0][1].scope, item.scope);
    assert.equal(events[0][1].rawBody, rawBody);
    assert.equal(events[1][0], item.event);
    assert.deepEqual(events[1][1], item.adapterRequest);
  }
});

test("missing authorization and unknown execute/raw routes fail before adapters", async () => {
  const { app, events } = fixture();
  const missingAuthorization = await dispatchJSON(app, {
    path: "/v1/harness/invoke",
    headers: BASE_HEADERS,
    value: {
      clientRequestID: "request-1",
      harnessID: "eva",
      instruction: "List agents",
    },
  });
  assert.equal(missingAuthorization.statusCode, 401);

  for (const path of ["/v1/execute", "/v1/raw", "/v1/shell", "/v1/url"]) {
    const response = await dispatchJSON(app, {
      path,
      value: {},
    });
    assert.equal(response.statusCode, 404);
  }
  assert.deepEqual(events, []);
});

test("asynchronous authorization must finish successfully before an adapter runs", async () => {
  let adapterCalls = 0;
  const { app } = fixture({
    authorization: {
      async issueCapability() {
        return "header.payload.signature";
      },
      async authorizeSessionStatus() {
        throw new Error("not used");
      },
      async authorize() {
        await Promise.resolve();
        throw new Error("deviceToken=must-not-leak");
      },
    },
    harnessRouter: {
      async invoke() {
        adapterCalls += 1;
        return { status: "completed" };
      },
    },
  });
  const response = await dispatchJSON(app, {
    path: "/v1/harness/invoke",
    value: {
      clientRequestID: "request-1",
      harnessID: "eva",
      instruction: "List agents",
    },
  });

  assert.equal(response.statusCode, 401);
  assert.equal(adapterCalls, 0);
  assert.doesNotMatch(response.body, /must-not-leak|deviceToken/i);
});

test("unexpected fields and invalid primitive types fail closed", async () => {
  const { app, events } = fixture();
  const extra = await dispatchJSON(app, {
    path: "/v1/codex/read",
    value: {
      routeTarget: "other-host",
      taskReference: "task-1",
    },
  });
  assert.equal(extra.statusCode, 400);

  const wrongType = await dispatchJSON(app, {
    path: "/v1/codex/list",
    value: { limit: "20" },
  });
  assert.equal(wrongType.statusCode, 400);
  assert.deepEqual(events, []);
});

test("dependency failures produce sanitized errors with a safe request ID", async () => {
  const { app } = fixture({
    harnessRouter: {
      async invoke() {
        throw new Error(
          "gatewayToken=super-secret-value authorization: Bearer abc.def.ghi",
        );
      },
    },
  });
  const response = await dispatchJSON(app, {
    path: "/v1/harness/invoke",
    headers: protectedHeaders({
      "x-request-id": "request-safe-1",
    }),
    value: {
      clientRequestID: "request-1",
      harnessID: "eva",
      instruction: "List agents",
    },
  });

  assert.equal(response.statusCode, 502);
  assert.equal(response.json.requestID, "request-safe-1");
  assert.equal(response.headers["x-request-id"], "request-safe-1");
  assert.doesNotMatch(response.body, /super-secret|abc\.def|gatewayToken/i);
  assert.deepEqual(response.json.error, {
    code: "operation_failed",
    message: "The requested operation could not be completed.",
  });
});

test("the Node HTTP handler reads a request and writes the bounded controller response", async () => {
  const { app } = fixture();
  const request = Readable.from([]);
  request.method = "GET";
  request.url = "/healthz";
  request.headers = {};
  const response = new FakeServerResponse();

  await app.handleNodeRequest(request, response);

  assert.equal(response.statusCode, 200);
  assert.equal(response.headers["content-type"], "application/json; charset=utf-8");
  assert.deepEqual(JSON.parse(response.body), {
    ready: true,
    version: "0.1.0-test",
  });
});

class FakeServerResponse {
  headers = {};
  statusCode = null;
  body = "";

  writeHead(statusCode, headers) {
    this.statusCode = statusCode;
    this.headers = { ...headers };
  }

  end(body = "") {
    this.body += body;
  }
}
