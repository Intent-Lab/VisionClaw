import { timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import https from "node:https";

import { BonjourAdvertiser } from "./bonjour-advertiser.mjs";
import { isPrivateIPv4 } from "./network-endpoint.mjs";
import {
  canonicalJSONString,
  parseCanonicalJSON,
} from "./security.mjs";

const ADMIN_PAIRING_OFFER_PATH = "/v1/admin/pairing-offer";
const ADMIN_PAIRINGS_PATH = "/v1/admin/pairings";
const ADMIN_REVOKE_PAIRING_PATH = "/v1/admin/pairings/revoke";
const ADMIN_PATHS = new Set([
  ADMIN_PAIRING_OFFER_PATH,
  ADMIN_PAIRINGS_PATH,
  ADMIN_REVOKE_PAIRING_PATH,
]);
const MAX_ADMIN_BODY_BYTES = 1_024;

export class BrokerServer {
  #application;
  #pairingService;
  #identity;
  #host;
  #requestedPort;
  #displayName;
  #adminToken;
  #advertiserFactory;
  #server = null;
  #adminServer = null;
  #advertiser = null;
  #state = "idle";
  port = null;

  constructor({
    application,
    pairingService,
    identity,
    host = "127.0.0.1",
    port = 38_443,
    displayName = "VisionClaw",
    adminToken,
    advertiserFactory = (configuration) => new BonjourAdvertiser(configuration),
  }) {
    if (typeof application?.handleNodeRequest !== "function") {
      throw new Error("Broker application handler is required.");
    }
    if (typeof pairingService?.begin !== "function") {
      throw new Error("Broker pairing service is required.");
    }
    if (
      !identity?.brokerID
      || !identity?.certificatePath
      || !identity?.privateKeyPath
    ) {
      throw new Error("Broker TLS identity is required.");
    }
    if (
      !["127.0.0.1", "::1", "0.0.0.0", "::"].includes(host)
      && !isPrivateIPv4(host)
    ) {
      throw new Error("Broker host must be loopback or an explicit LAN bind.");
    }
    if (!Number.isSafeInteger(port) || port < 0 || port > 65_535) {
      throw new Error("Broker port is invalid.");
    }
    if (
      typeof adminToken !== "string"
      || !/^[A-Za-z0-9_-]{43}$/.test(adminToken)
    ) {
      throw new Error("Broker admin credential is invalid.");
    }
    this.#application = application;
    this.#pairingService = pairingService;
    this.#identity = identity;
    this.#host = host;
    this.#requestedPort = port;
    this.#displayName = displayName;
    this.#adminToken = adminToken;
    this.#advertiserFactory = advertiserFactory;
  }

  async start() {
    if (this.#state !== "idle") {
      throw new Error(`Broker server is ${this.#state}.`);
    }
    this.#state = "starting";
    try {
      const [key, cert] = await Promise.all([
        readFile(this.#identity.privateKeyPath),
        readFile(this.#identity.certificatePath),
      ]);
      const server = createHTTPSServer({
        key,
        cert,
        handler: (request, response) => {
          void this.#handleRequest(request, response);
        },
      });
      this.#server = server;

      await listen(server, this.#requestedPort, this.#host);
      const address = server.address();
      if (!address || typeof address === "string") {
        throw new Error("Broker server did not expose a TCP port.");
      }
      this.port = address.port;
      if (isPrivateIPv4(this.#host)) {
        const adminServer = createHTTPSServer({
          key,
          cert,
          handler: (request, response) => {
            void this.#handleRequest(request, response);
          },
        });
        this.#adminServer = adminServer;
        await listen(adminServer, this.port, "127.0.0.1");
      }
      this.#state = "running";

      if (!isLoopbackBind(this.#host)) {
        this.#advertiser = this.#advertiserFactory({
          brokerID: this.#identity.brokerID,
          displayName: this.#displayName,
          port: this.port,
        });
        this.#advertiser.start();
      }
    } catch (error) {
      this.#state = "failed";
      await this.#closeServer();
      throw error;
    }
  }

  async stop() {
    if (this.#state === "stopped") return;
    this.#state = "stopped";
    this.#advertiser?.stop();
    this.#advertiser = null;
    await this.#closeServer();
  }

  async #closeServer() {
    const server = this.#server;
    const adminServer = this.#adminServer;
    this.#server = null;
    this.#adminServer = null;
    this.port = null;
    await Promise.all([
      closeServer(server),
      closeServer(adminServer),
    ]);
  }

  async #handleRequest(request, response) {
    if (!ADMIN_PATHS.has(request.url)) {
      await this.#application.handleNodeRequest(request, response);
      return;
    }

    try {
      if (!isLocalAdminConnection(
          request.socket?.remoteAddress,
          request.socket?.localAddress,
        )
        || !hasValidAdminAuthorization(request, this.#adminToken)) {
        request.resume();
        sendNotFound(response);
        return;
      }

      if (request.url === ADMIN_PAIRINGS_PATH) {
        if (
          request.method !== "GET"
          || request.headers["content-length"]
          || request.headers["transfer-encoding"]
        ) {
          request.resume();
          sendNotFound(response);
          return;
        }
        sendJSON(
          response,
          200,
          this.#pairingService.listPairings({
            requestedByLoopback: true,
          }),
        );
        return;
      }

      if (
        request.method !== "POST"
        || request.headers?.["content-type"] !== "application/json"
      ) {
        request.resume();
        sendNotFound(response);
        return;
      }
      const body = await readBoundedBody(request);
      if (request.url === ADMIN_PAIRING_OFFER_PATH) {
        if (body !== "{}") {
          sendInvalidRequest(response);
          return;
        }
        const offer = this.#pairingService.begin({
          requestedByLoopback: true,
        });
        sendJSON(response, 201, offer);
        return;
      }

      let parsed;
      try {
        parsed = parseCanonicalJSON(body);
      } catch {
        sendInvalidRequest(response);
        return;
      }
      if (
        !parsed
        || typeof parsed !== "object"
        || Array.isArray(parsed)
        || Object.keys(parsed).join("\0") !== "pairingReference"
        || !/^vcp_[A-Za-z0-9_-]{43}$/.test(parsed.pairingReference)
      ) {
        sendInvalidRequest(response);
        return;
      }
      const revoked = this.#pairingService.revokePairing({
        requestedByLoopback: true,
        pairingReference: parsed.pairingReference,
      });
      sendJSON(response, 200, revoked);
    } catch (error) {
      const notFound = /not found/i.test(error?.message ?? "");
      sendJSON(response, notFound ? 404 : 500, {
        error: {
          code: notFound ? "not_found" : "internal_error",
          message: notFound
            ? "The pairing reference was not found."
            : "The broker could not complete the request.",
        },
      });
    }
  }
}

export function isLoopbackAddress(address) {
  return (
    address === "127.0.0.1"
    || address === "::1"
    || address === "::ffff:127.0.0.1"
  );
}

export function isLocalAdminConnection(remoteAddress) {
  return isLoopbackAddress(remoteAddress);
}

function hasValidAdminAuthorization(request, expectedToken) {
  const rawHeaders = Array.isArray(request.rawHeaders)
    ? request.rawHeaders
    : [];
  let authorizationHeaders = 0;
  for (let index = 0; index < rawHeaders.length; index += 2) {
    if (String(rawHeaders[index]).toLowerCase() === "authorization") {
      authorizationHeaders += 1;
    }
  }
  const authorization = request.headers?.authorization;
  if (
    authorizationHeaders !== 1
    || typeof authorization !== "string"
    || !authorization.startsWith("Bearer ")
  ) {
    return false;
  }
  const supplied = Buffer.from(authorization.slice("Bearer ".length), "utf8");
  const expected = Buffer.from(expectedToken, "utf8");
  return (
    supplied.length === expected.length
    && timingSafeEqual(supplied, expected)
  );
}

function isLoopbackBind(host) {
  return host === "127.0.0.1" || host === "::1";
}

async function readBoundedBody(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    const bytes = Buffer.from(chunk);
    length += bytes.length;
    if (length > MAX_ADMIN_BODY_BYTES) {
      request.resume();
      throw new Error("Admin request is too large.");
    }
    chunks.push(bytes);
  }
  return Buffer.concat(chunks, length).toString("utf8");
}

function sendJSON(response, statusCode, value) {
  const body = canonicalJSONString(value);
  response.writeHead(statusCode, {
    "cache-control": "no-store",
    "content-length": String(Buffer.byteLength(body)),
    "content-type": "application/json; charset=utf-8",
    "x-content-type-options": "nosniff",
  });
  response.end(body);
}

function sendNotFound(response) {
  sendJSON(response, 404, {
    error: {
      code: "not_found",
      message: "The requested endpoint does not exist.",
    },
  });
}

function sendInvalidRequest(response) {
  sendJSON(response, 400, {
    error: {
      code: "invalid_request",
      message: "The request is invalid.",
    },
  });
}

function createHTTPSServer({ key, cert, handler }) {
  const server = https.createServer({
    key,
    cert,
    minVersion: "TLSv1.3",
  }, handler);
  server.maxHeadersCount = 48;
  server.headersTimeout = 10_000;
  server.requestTimeout = 30_000;
  server.keepAliveTimeout = 5_000;
  return server;
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port, host);
  });
}

function closeServer(server) {
  if (!server?.listening) return Promise.resolve();
  return new Promise((resolve) => server.close(resolve));
}
