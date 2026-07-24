import { readFile } from "node:fs/promises";
import https from "node:https";

import { canonicalJSONString } from "./security.mjs";

const MAX_RESPONSE_BYTES = 64 * 1024;

export class LocalAdminClient {
  #certificatePath;
  #host;
  #port;
  #adminToken;
  #timeoutMilliseconds;

  constructor({
    certificatePath,
    host = "127.0.0.1",
    port,
    adminToken = null,
    timeoutMilliseconds = 5_000,
  }) {
    if (typeof certificatePath !== "string" || certificatePath.length === 0) {
      throw new Error("Broker certificate path is required.");
    }
    if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
      throw new Error("Broker port is invalid.");
    }
    if (host !== "127.0.0.1" && host !== "::1") {
      throw new Error("Broker admin host is invalid.");
    }
    if (
      adminToken !== null
      && (
        typeof adminToken !== "string"
        || !/^[A-Za-z0-9_-]{43}$/.test(adminToken)
      )
    ) {
      throw new Error("Broker admin credential is invalid.");
    }
    this.#certificatePath = certificatePath;
    this.#host = host;
    this.#port = port;
    this.#adminToken = adminToken;
    this.#timeoutMilliseconds = timeoutMilliseconds;
  }

  pairingOffer() {
    return this.#request({
      method: "POST",
      path: "/v1/admin/pairing-offer",
      body: "{}",
      allowedStatuses: new Set([201]),
      authenticate: true,
    });
  }

  pairings() {
    return this.#request({
      method: "GET",
      path: "/v1/admin/pairings",
      body: null,
      allowedStatuses: new Set([200]),
      authenticate: true,
    });
  }

  revokePairing(pairingReference) {
    if (!/^vcp_[A-Za-z0-9_-]{43}$/.test(String(pairingReference))) {
      throw new Error("Pairing reference is invalid.");
    }
    return this.#request({
      method: "POST",
      path: "/v1/admin/pairings/revoke",
      body: canonicalJSONString({ pairingReference }),
      allowedStatuses: new Set([200]),
      authenticate: true,
    });
  }

  status() {
    return this.#request({
      method: "GET",
      path: "/healthz",
      body: null,
      allowedStatuses: new Set([200, 503]),
    });
  }

  async #request({
    method,
    path,
    body,
    allowedStatuses,
    authenticate = false,
  }) {
    if (authenticate && this.#adminToken === null) {
      throw new Error("Broker admin credential is required.");
    }
    const certificate = await readFile(this.#certificatePath);
    const headers = {};
    if (authenticate) {
      headers.authorization = `Bearer ${this.#adminToken}`;
    }
    if (body != null) {
      headers["content-length"] = String(Buffer.byteLength(body));
      headers["content-type"] = "application/json";
    }
    return new Promise((resolve, reject) => {
      const request = https.request({
        host: this.#host,
        port: this.#port,
        method,
        path,
        ca: certificate,
        servername: "localhost",
        headers,
      }, (response) => {
        const chunks = [];
        let length = 0;
        response.on("data", (chunk) => {
          length += chunk.length;
          if (length > MAX_RESPONSE_BYTES) {
            request.destroy(new Error("Broker response exceeded the safety limit."));
            return;
          }
          chunks.push(Buffer.from(chunk));
        });
        response.on("end", () => {
          if (!allowedStatuses.has(response.statusCode)) {
            reject(new Error(
              `Broker request failed with status ${response.statusCode ?? "unknown"}.`,
            ));
            return;
          }
          if (
            !String(response.headers["content-type"] ?? "")
              .toLowerCase()
              .startsWith("application/json")
          ) {
            reject(new Error("Broker returned an invalid response."));
            return;
          }
          try {
            resolve(JSON.parse(Buffer.concat(chunks, length).toString("utf8")));
          } catch {
            reject(new Error("Broker returned an invalid response."));
          }
        });
      });
      request.setTimeout(this.#timeoutMilliseconds, () => {
        request.destroy(new Error("Broker request timed out."));
      });
      request.on("error", reject);
      if (body != null) request.write(body);
      request.end();
    });
  }
}
