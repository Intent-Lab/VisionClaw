import { randomUUID } from "node:crypto";
import { TextDecoder } from "node:util";

import {
  canonicalJSONString,
  parseCanonicalJSON,
  sha256Base64URL,
} from "./security.mjs";

export const MAX_REQUEST_BODY_BYTES = 64 * 1024;

const JSON_CONTENT_TYPE = /^application\/json(?:\s*;\s*charset=utf-8)?$/i;
const SAFE_IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$/;
const SAFE_NONCE = /^[A-Za-z0-9_-]{7,256}$/;
const SAFE_PROOF = /^[A-Za-z0-9_-]{16,2048}$/;
const SAFE_TOKEN = /^[A-Za-z0-9._~-]{16,8192}$/;
const SAFE_REQUEST_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/;
const SHA256_BASE64URL = /^[A-Za-z0-9_-]{43}$/;
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: true });

const ROUTES = new Map([
  ["/v1/harness/invoke", {
    scope: "harness:invoke",
    validate: validateHarnessInvocation,
    invoke: async (app, body, pairingID) => app.harnessRouter.invoke({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/harness/poll", {
    scope: "harness:read",
    validate: validateHarnessPoll,
    invoke: async (app, body, pairingID) => app.harnessOperations.poll({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/harness/cancel", {
    scope: "harness:cancel",
    validate: validateHarnessCancel,
    invoke: async (app, body, pairingID) => app.harnessOperations.cancel({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/codex/list", {
    scope: "tasks:list",
    validate: validateCodexList,
    invoke: async (app, body, pairingID) => app.codexAdapter.list({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/codex/read", {
    scope: "tasks:read",
    validate: validateCodexTaskReference,
    invoke: async (app, body, pairingID) => app.codexAdapter.read({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/codex/status", {
    scope: "tasks:status",
    validate: validateCodexTaskReference,
    invoke: async (app, body, pairingID) => app.codexAdapter.status({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/codex/prepare", {
    scope: "tasks:continue",
    validate: validateCodexPrepare,
    invoke: async (app, body, pairingID) => app.codexAdapter.prepareContinue({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/codex/commit", {
    scope: "tasks:continue:commit",
    validate: validateCodexCommit,
    invoke: async (app, body, pairingID) => app.codexAdapter.commitContinue({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/codex/operation-status", {
    scope: "tasks:operation:status",
    validate: validateCodexOperationStatus,
    invoke: async (app, body, pairingID) => app.codexAdapter.operationStatus({
      ...body,
      pairingID,
    }),
  }],
  ["/v1/codex/cancel", {
    scope: "tasks:cancel",
    validate: validateCodexCancel,
    invoke: async (app, body, pairingID) => app.cancelCodex({
      ...body,
      pairingID,
    }),
  }],
]);

export function createBrokerApplication(options) {
  return new BrokerApplication(options);
}

export class BrokerApplication {
  authorization;
  codexAdapter;
  harnessOperations;
  harnessRouter;
  pairingService;
  #brokerID;
  #readiness;
  #version;

  constructor({
    authorization,
    codexAdapter,
    harnessOperations,
    harnessRouter,
    pairingService,
    readiness = () => true,
    brokerID,
    version,
  }) {
    requireMethod(authorization, "issueCapability");
    requireMethod(authorization, "authorize");
    requireMethod(authorization, "authorizeSessionStatus");
    requireMethod(pairingService, "complete");
    requireMethod(harnessRouter, "invoke");
    requireMethod(harnessOperations, "poll");
    requireMethod(harnessOperations, "cancel");
    for (const method of [
      "list",
      "read",
      "status",
      "prepareContinue",
      "commitContinue",
      "operationStatus",
    ]) {
      requireMethod(codexAdapter, method);
    }
    if (
      typeof codexAdapter?.cancel !== "function"
      && typeof codexAdapter?.cancelPrepared !== "function"
    ) {
      throw new TypeError("Codex adapter must implement cancel or cancelPrepared.");
    }
    if (typeof readiness !== "function") {
      throw new TypeError("Broker readiness must be a function.");
    }
    if (typeof brokerID !== "string" || !SAFE_IDENTIFIER.test(brokerID)) {
      throw new TypeError("Broker identity is invalid.");
    }
    if (
      typeof version !== "string"
      || !/^[A-Za-z0-9][A-Za-z0-9.+_-]{0,31}$/.test(version)
    ) {
      throw new TypeError("Broker version is invalid.");
    }

    this.authorization = authorization;
    this.codexAdapter = codexAdapter;
    this.harnessOperations = harnessOperations;
    this.harnessRouter = harnessRouter;
    this.pairingService = pairingService;
    this.#brokerID = brokerID;
    this.#readiness = readiness;
    this.#version = version;
  }

  async dispatch({
    method,
    path,
    headers = {},
    rawBody = "",
  }) {
    const requestID = requestIDFromHeaders(headers);

    try {
      const normalizedHeaders = normalizeHeaders(headers);
      const requestMethod = String(method ?? "").toUpperCase();
      const requestPath = String(path ?? "");

      if (requestPath === "/healthz") {
        if (requestMethod !== "GET") {
          throw httpError(
            405,
            "method_not_allowed",
            "This endpoint does not allow that method.",
            { allow: "GET" },
          );
        }
        if (bodyByteLength(rawBody) !== 0) {
          throw httpError(400, "invalid_request", "The request is invalid.");
        }
        let ready = false;
        try {
          ready = (await this.#readiness()) === true;
        } catch {
          ready = false;
        }
        return jsonResponse({
          statusCode: ready ? 200 : 503,
          value: { ready, version: this.#version },
          requestID,
        });
      }

      const route = ROUTES.get(requestPath);
      const isSpecialPostRoute = (
        requestPath === "/v1/pairing/complete"
        || requestPath === "/v1/capabilities"
        || requestPath === "/v1/session/status"
      );
      if (!route && !isSpecialPostRoute) {
        throw httpError(404, "not_found", "The requested endpoint does not exist.");
      }
      if (requestMethod !== "POST") {
        throw httpError(
          405,
          "method_not_allowed",
          "This endpoint does not allow that method.",
          { allow: "POST" },
        );
      }
      requireUnencodedCanonicalJSON(normalizedHeaders);
      const rawJSON = decodeRequestBody(rawBody);
      const body = parseBody(rawJSON);

      if (requestPath === "/v1/pairing/complete") {
        const pairingRequest = validatePairingCompletion(body);
        let result;
        try {
          result = await this.pairingService.complete(pairingRequest);
        } catch {
          throw httpError(
            400,
            "pairing_failed",
            "Pairing could not be completed.",
          );
        }
        return jsonResponse({
          statusCode: 201,
          value: safePairingResult(result),
          requestID,
        });
      }

      const proof = proofFromHeaders({
        headers: normalizedHeaders,
        method: requestMethod,
        path: requestPath,
        rawBody: rawJSON,
      });

      if (requestPath === "/v1/session/status") {
        assertExactFields(body, []);
        try {
          await this.authorization.authorizeSessionStatus({
            pairingID: proof.pairingID,
            rawBody: rawJSON,
            proofRequest: proof.proofRequest,
            proof: proof.proof,
          });
        } catch {
          throw unauthorized();
        }
        let ready = false;
        try {
          ready = (await this.#readiness()) === true;
        } catch {
          ready = false;
        }
        if (!ready) {
          throw httpError(
            503,
            "service_unavailable",
            "The broker is not ready.",
          );
        }
        return jsonResponse({
          statusCode: 200,
          value: {
            brokerID: this.#brokerID,
            ready: true,
            version: this.#version,
          },
          requestID,
        });
      }

      if (requestPath === "/v1/capabilities") {
        validateCapabilityRequest(body);
        let capability;
        try {
          capability = await this.authorization.issueCapability({
            pairingID: proof.pairingID,
            body,
            proofRequest: proof.proofRequest,
            proof: proof.proof,
          });
        } catch {
          throw unauthorized();
        }
        if (typeof capability !== "string" || !SAFE_TOKEN.test(capability)) {
          throw httpError(
            500,
            "internal_error",
            "The broker could not complete the request.",
          );
        }
        return jsonResponse({
          statusCode: 201,
          value: { capability },
          requestID,
        });
      }

      route.validate(body);
      const token = bearerToken(normalizedHeaders);
      try {
        await this.authorization.authorize({
          pairingID: proof.pairingID,
          token,
          scope: route.scope,
          method: requestMethod,
          path: requestPath,
          rawBody: rawJSON,
          proofRequest: proof.proofRequest,
          proof: proof.proof,
        });
      } catch {
        throw unauthorized();
      }

      let result;
      try {
        result = await route.invoke(this, body, proof.pairingID);
      } catch {
        throw httpError(
          502,
          "operation_failed",
          "The requested operation could not be completed.",
        );
      }
      return jsonResponse({
        statusCode: 200,
        value: result,
        requestID,
      });
    } catch (error) {
      return errorResponse(error, requestID);
    }
  }

  async cancelCodex(request) {
    if (typeof this.codexAdapter.cancel === "function") {
      return this.codexAdapter.cancel(request);
    }
    return this.codexAdapter.cancelPrepared(request);
  }

  async handleNodeRequest(request, response) {
    const requestID = requestIDFromHeaders(request.headers ?? {});
    let result;
    try {
      const rawBody = await readIncomingBody(request);
      result = await this.dispatch({
        method: request.method,
        path: request.url,
        headers: request.headers,
        rawBody,
      });
    } catch (error) {
      result = errorResponse(error, requestID);
    }
    response.writeHead(result.statusCode, result.headers);
    response.end(result.body);
  }
}

function requireMethod(target, method) {
  if (typeof target?.[method] !== "function") {
    throw new TypeError(`Broker dependency must implement ${method}.`);
  }
}

function validatePairingCompletion(value) {
  assertExactFields(value, [
    "deviceName",
    "pairingSecret",
    "phonePublicKeyDER",
  ]);
  const deviceName = requireBoundedText(value.deviceName, 1, 80);
  const pairingSecret = requireMatchingString(
    value.pairingSecret,
    /^[A-Za-z0-9_-]{24,256}$/,
  );
  const encodedKey = requireMatchingString(
    value.phonePublicKeyDER,
    /^[A-Za-z0-9_-]{8,4096}$/,
  );
  const phonePublicKeyDER = Buffer.from(encodedKey, "base64url");
  if (
    phonePublicKeyDER.length === 0
    || phonePublicKeyDER.toString("base64url") !== encodedKey
  ) {
    throw invalidRequest();
  }
  return { deviceName, pairingSecret, phonePublicKeyDER };
}

function safePairingResult(value) {
  try {
    return validatePairingResult(value);
  } catch {
    throw internalError();
  }
}

function validatePairingResult(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("Invalid pairing result.");
  }
  const pairingID = requireMatchingString(value.pairingID, SAFE_IDENTIFIER);
  const brokerID = requireMatchingString(value.brokerID, SAFE_IDENTIFIER);
  if (
    !Array.isArray(value.grantedScopes)
    || value.grantedScopes.length > 32
    || value.grantedScopes.some(
      (scope) => typeof scope !== "string" || !/^[a-z][a-z0-9:-]{1,63}$/.test(scope),
    )
  ) {
    throw new TypeError("Invalid granted scopes.");
  }
  const pairedAt = Number(value.pairedAt);
  if (!Number.isSafeInteger(pairedAt) || pairedAt <= 0) {
    throw new TypeError("Invalid pairing timestamp.");
  }
  return {
    pairingID,
    brokerID,
    grantedScopes: [...value.grantedScopes],
    pairedAt,
  };
}

function validateCapabilityRequest(value) {
  assertExactFields(value, ["bodyHash", "method", "path", "scope"]);
  requireMatchingString(value.bodyHash, SHA256_BASE64URL);
  if (value.method !== "POST") throw invalidRequest();
  if (!ROUTES.has(value.path)) throw invalidRequest();
  if (ROUTES.get(value.path).scope !== value.scope) throw invalidRequest();
}

function validateHarnessInvocation(value) {
  assertExactFields(value, [
    "clientRequestID",
    "harnessID",
    "instruction",
  ]);
  requireIdentifier(value.clientRequestID);
  requireIdentifier(value.harnessID);
  requireBoundedText(value.instruction, 1, 4_000);
}

function validateHarnessPoll(value) {
  assertExactFields(value, ["afterSequence", "operationID"]);
  requireIdentifier(value.operationID);
  if (
    !Number.isSafeInteger(value.afterSequence)
    || value.afterSequence < 0
    || value.afterSequence > 1_000_000_000
  ) {
    throw invalidRequest();
  }
}

function validateHarnessCancel(value) {
  assertExactFields(value, ["clientRequestID", "operationID"]);
  requireIdentifier(value.clientRequestID);
  requireIdentifier(value.operationID);
}

function validateCodexList(value) {
  assertExactFields(value, [], ["limit"]);
  if (
    "limit" in value
    && (!Number.isSafeInteger(value.limit) || value.limit < 1 || value.limit > 20)
  ) {
    throw invalidRequest();
  }
}

function validateCodexTaskReference(value) {
  assertExactFields(value, ["taskReference"]);
  requireIdentifier(value.taskReference);
}

function validateCodexPrepare(value) {
  assertExactFields(value, [
    "clientRequestID",
    "instruction",
    "taskReference",
  ]);
  requireIdentifier(value.clientRequestID);
  requireBoundedText(value.instruction, 1, 4_000);
  requireIdentifier(value.taskReference);
}

function validateCodexCommit(value) {
  assertExactFields(value, [
    "actionID",
    "clientRequestID",
    "confirmationNonce",
  ]);
  requireIdentifier(value.actionID);
  requireIdentifier(value.clientRequestID);
  requireIdentifier(value.confirmationNonce);
}

function validateCodexCancel(value) {
  assertExactFields(value, ["actionID", "clientRequestID"]);
  requireIdentifier(value.actionID);
  requireIdentifier(value.clientRequestID);
}

function validateCodexOperationStatus(value) {
  assertExactFields(value, ["actionID", "clientRequestID"]);
  requireIdentifier(value.actionID);
  requireIdentifier(value.clientRequestID);
}

function assertExactFields(value, required, optional = []) {
  if (!isPlainObject(value)) throw invalidRequest();
  const allowed = new Set([...required, ...optional]);
  if (Object.keys(value).some((field) => !allowed.has(field))) {
    throw invalidRequest();
  }
  if (required.some((field) => !(field in value))) {
    throw invalidRequest();
  }
}

function isPlainObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function requireIdentifier(value) {
  return requireMatchingString(value, SAFE_IDENTIFIER);
}

function requireMatchingString(value, pattern) {
  if (typeof value !== "string" || !pattern.test(value)) {
    throw invalidRequest();
  }
  return value;
}

function requireBoundedText(value, minimum, maximum) {
  if (
    typeof value !== "string"
    || value.length < minimum
    || value.length > maximum
    || value !== value.trim()
    || /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/u.test(value)
  ) {
    throw invalidRequest();
  }
  return value;
}

function normalizeHeaders(headers) {
  const normalized = new Map();
  for (const [rawName, rawValue] of Object.entries(headers ?? {})) {
    const name = rawName.toLowerCase();
    if (normalized.has(name)) throw invalidRequest();
    if (Array.isArray(rawValue)) {
      if (rawValue.length !== 1) throw invalidRequest();
      normalized.set(name, String(rawValue[0]));
    } else if (rawValue !== undefined) {
      normalized.set(name, String(rawValue));
    }
  }
  return normalized;
}

function requestIDFromHeaders(headers) {
  let supplied;
  for (const [name, value] of Object.entries(headers ?? {})) {
    if (name.toLowerCase() === "x-request-id" && typeof value === "string") {
      supplied = value;
      break;
    }
  }
  return SAFE_REQUEST_ID.test(supplied ?? "") ? supplied : randomUUID();
}

function requireUnencodedCanonicalJSON(headers) {
  const contentType = headers.get("content-type");
  if (!contentType || !JSON_CONTENT_TYPE.test(contentType)) {
    throw httpError(
      415,
      "unsupported_media_type",
      "The request must use canonical application/json.",
    );
  }
  const contentEncoding = headers.get("content-encoding");
  if (contentEncoding && contentEncoding.toLowerCase() !== "identity") {
    throw httpError(
      415,
      "unsupported_media_type",
      "Encoded request bodies are not accepted.",
    );
  }
}

function decodeRequestBody(rawBody) {
  const bytes = bodyBytes(rawBody);
  if (bytes.length > MAX_REQUEST_BODY_BYTES) {
    throw httpError(
      413,
      "payload_too_large",
      "The request body exceeds the broker limit.",
    );
  }
  try {
    return UTF8_DECODER.decode(bytes);
  } catch {
    throw invalidRequest();
  }
}

function bodyBytes(rawBody) {
  if (Buffer.isBuffer(rawBody) || rawBody instanceof Uint8Array) {
    return Buffer.from(rawBody);
  }
  if (typeof rawBody === "string") {
    return Buffer.from(rawBody, "utf8");
  }
  throw invalidRequest();
}

function bodyByteLength(rawBody) {
  return bodyBytes(rawBody).length;
}

function parseBody(rawJSON) {
  try {
    return parseCanonicalJSON(rawJSON);
  } catch {
    throw invalidRequest();
  }
}

function proofFromHeaders({
  headers,
  method,
  path,
  rawBody,
}) {
  const pairingID = requireHeader(headers, "x-visionclaw-pairing-id");
  const nonce = requireHeader(headers, "x-visionclaw-proof-nonce");
  const timestampValue = requireHeader(
    headers,
    "x-visionclaw-proof-timestamp",
  );
  const proof = requireHeader(headers, "x-visionclaw-device-proof");
  if (
    !SAFE_IDENTIFIER.test(pairingID)
    || !SAFE_NONCE.test(nonce)
    || !/^[0-9]{10,16}$/.test(timestampValue)
    || !SAFE_PROOF.test(proof)
  ) {
    throw unauthorized();
  }
  const timestamp = Number(timestampValue);
  if (!Number.isSafeInteger(timestamp)) throw unauthorized();
  return {
    pairingID,
    proof,
    proofRequest: {
      pairingID,
      bodyHash: sha256Base64URL(rawBody),
      method,
      nonce,
      path,
      timestamp,
    },
  };
}

function bearerToken(headers) {
  const value = requireHeader(headers, "authorization");
  const match = /^Bearer ([A-Za-z0-9._~-]{16,8192})$/.exec(value);
  if (!match || !SAFE_TOKEN.test(match[1])) throw unauthorized();
  return match[1];
}

function requireHeader(headers, name) {
  const value = headers.get(name);
  if (typeof value !== "string" || value.length === 0) {
    throw unauthorized();
  }
  return value;
}

function unauthorized() {
  return httpError(
    401,
    "unauthorized",
    "Device authorization failed.",
  );
}

function invalidRequest() {
  return httpError(400, "invalid_request", "The request is invalid.");
}

function internalError() {
  return httpError(
    500,
    "internal_error",
    "The broker could not complete the request.",
  );
}

function httpError(statusCode, code, safeMessage, responseHeaders = {}) {
  const error = new Error(safeMessage);
  error.statusCode = statusCode;
  error.code = code;
  error.safeMessage = safeMessage;
  error.responseHeaders = responseHeaders;
  return error;
}

function errorResponse(error, requestID) {
  const isSafe = (
    Number.isSafeInteger(error?.statusCode)
    && typeof error?.code === "string"
    && typeof error?.safeMessage === "string"
  );
  return jsonResponse({
    statusCode: isSafe ? error.statusCode : 500,
    value: {
      error: {
        code: isSafe ? error.code : "internal_error",
        message: isSafe
          ? error.safeMessage
          : "The broker could not complete the request.",
      },
      requestID,
    },
    requestID,
    additionalHeaders: isSafe ? error.responseHeaders : {},
  });
}

function jsonResponse({
  statusCode,
  value,
  requestID,
  additionalHeaders = {},
}) {
  let body;
  try {
    body = canonicalJSONString(value);
  } catch {
    if (statusCode >= 400) {
      body = canonicalJSONString({
        error: {
          code: "internal_error",
          message: "The broker could not complete the request.",
        },
        requestID,
      });
      statusCode = 500;
    } else {
      throw httpError(
        500,
        "internal_error",
        "The broker could not complete the request.",
      );
    }
  }
  return {
    statusCode,
    headers: {
      "cache-control": "no-store",
      "content-length": String(Buffer.byteLength(body)),
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
      "x-request-id": requestID,
      ...additionalHeaders,
    },
    body,
  };
}

async function readIncomingBody(request) {
  const declaredLength = Number(request.headers?.["content-length"]);
  if (
    Number.isFinite(declaredLength)
    && declaredLength > MAX_REQUEST_BODY_BYTES
  ) {
    request.resume?.();
    throw httpError(
      413,
      "payload_too_large",
      "The request body exceeds the broker limit.",
    );
  }

  const chunks = [];
  let byteLength = 0;
  for await (const chunk of request) {
    const bytes = Buffer.from(chunk);
    byteLength += bytes.length;
    if (byteLength > MAX_REQUEST_BODY_BYTES) {
      request.resume?.();
      throw httpError(
        413,
        "payload_too_large",
        "The request body exceeds the broker limit.",
      );
    }
    chunks.push(bytes);
  }
  return Buffer.concat(chunks, byteLength);
}
