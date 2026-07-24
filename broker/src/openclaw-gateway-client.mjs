import { randomUUID } from "node:crypto";

const PROTOCOL_VERSION = 4;
const DEFAULT_URL = "ws://127.0.0.1:16743";

export class OpenClawGatewayClient {
  #url;
  #authProvider;
  #webSocketFactory;
  #requestTimeoutMilliseconds;
  #reconnectDelayMilliseconds;
  #logger;
  #socket;
  #connectPromise;
  #resolveConnect;
  #rejectConnect;
  #pending = new Map();
  #eventListeners = new Set();
  #connectionListeners = new Set();
  #reconnectTimer;
  #manualClose = false;
  #connected = false;
  #everConnected = false;
  #handshakeStarted = false;
  #socketGeneration = 0;
  #suppressReconnectGeneration;

  constructor({
    url = DEFAULT_URL,
    authProvider,
    webSocketFactory = (endpoint) => new WebSocket(endpoint),
    requestTimeoutMilliseconds = 10_000,
    reconnectDelayMilliseconds = 500,
    logger = () => {},
  }) {
    assertGatewayURL(url);
    if (typeof authProvider !== "function") {
      throw new Error("An OpenClaw Gateway authentication provider is required.");
    }
    if (typeof webSocketFactory !== "function") {
      throw new Error("An OpenClaw WebSocket factory is required.");
    }
    this.#url = url;
    this.#authProvider = authProvider;
    this.#webSocketFactory = webSocketFactory;
    this.#requestTimeoutMilliseconds = requestTimeoutMilliseconds;
    this.#reconnectDelayMilliseconds = reconnectDelayMilliseconds;
    this.#logger = logger;
  }

  connect() {
    if (this.#connected) return Promise.resolve();
    if (this.#connectPromise) return this.#connectPromise;
    this.#manualClose = false;
    this.#connectPromise = new Promise((resolve, reject) => {
      this.#resolveConnect = resolve;
      this.#rejectConnect = reject;
    });
    this.#openSocket();
    return this.#connectPromise;
  }

  async request(method, params) {
    if (typeof method !== "string" || method.length === 0) {
      throw new Error("A Gateway method is required.");
    }
    await this.connect();
    return this.#sendRequest(method, params);
  }

  onEvent(listener) {
    if (typeof listener !== "function") {
      throw new Error("A Gateway event listener is required.");
    }
    this.#eventListeners.add(listener);
    return () => this.#eventListeners.delete(listener);
  }

  onConnection(listener) {
    if (typeof listener !== "function") {
      throw new Error("A Gateway connection listener is required.");
    }
    this.#connectionListeners.add(listener);
    return () => this.#connectionListeners.delete(listener);
  }

  close() {
    this.#manualClose = true;
    this.#connected = false;
    clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = undefined;
    this.#rejectOutstanding(new Error("OpenClaw Gateway connection closed."));
    const rejectConnect = this.#rejectConnect;
    this.#clearConnectPromise();
    rejectConnect?.(new Error("OpenClaw Gateway connection closed."));
    const socket = this.#socket;
    this.#socket = undefined;
    if (socket && socket.readyState < 2) socket.close(1000, "broker shutdown");
  }

  #openSocket() {
    const generation = ++this.#socketGeneration;
    this.#handshakeStarted = false;
    let socket;
    try {
      socket = this.#webSocketFactory(this.#url);
    } catch {
      this.#failHandshake(
        generation,
        new Error("OpenClaw Gateway connection could not be opened."),
      );
      return;
    }
    this.#socket = socket;
    socket.addEventListener("message", (event) => {
      void this.#handleMessage(generation, event.data);
    });
    socket.addEventListener("close", () => {
      this.#handleClose(generation);
    });
    socket.addEventListener("error", () => {
      this.#safeLog("Gateway socket error.");
    });
  }

  async #handleMessage(generation, rawData) {
    if (generation !== this.#socketGeneration) return;
    let message;
    try {
      message = JSON.parse(await messageText(rawData));
    } catch {
      this.#safeLog("Gateway sent an invalid frame.");
      return;
    }
    if (
      message?.type === "event"
      && message.event === "connect.challenge"
      && !this.#connected
    ) {
      await this.#authenticate(generation, message.payload);
      return;
    }
    if (message?.type === "res" && typeof message.id === "string") {
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.ok === true) {
        pending.resolve(message.payload);
      } else {
        const error = new Error(
          `OpenClaw Gateway ${pending.method} request failed.`,
        );
        if (typeof message.error?.code === "string") {
          error.code = message.error.code;
        }
        pending.reject(error);
      }
      return;
    }
    if (message?.type === "event" && typeof message.event === "string") {
      for (const listener of this.#eventListeners) {
        try {
          listener({
            event: message.event,
            payload: message.payload,
            seq: message.seq,
          });
        } catch {
          this.#safeLog("Gateway event listener failed.");
        }
      }
    }
  }

  async #authenticate(generation, payload) {
    if (this.#handshakeStarted || generation !== this.#socketGeneration) return;
    this.#handshakeStarted = true;
    const nonce = payload?.nonce;
    if (typeof nonce !== "string" || nonce.length === 0) {
      this.#failHandshake(
        generation,
        new Error("OpenClaw Gateway authentication challenge was invalid."),
      );
      return;
    }
    let supplied;
    try {
      supplied = await this.#authProvider({ nonce, url: this.#url });
    } catch {
      this.#failHandshake(
        generation,
        new Error("OpenClaw Gateway authentication failed."),
      );
      return;
    }
    if (generation !== this.#socketGeneration) return;
    const auth = supplied?.auth
      ?? (typeof supplied?.token === "string" ? { token: supplied.token } : null);
    if (!auth || typeof auth !== "object" || Array.isArray(auth)) {
      this.#failHandshake(
        generation,
        new Error("OpenClaw Gateway authentication failed."),
      );
      return;
    }
    const params = {
      minProtocol: PROTOCOL_VERSION,
      maxProtocol: PROTOCOL_VERSION,
      client: {
        id: "gateway-client",
        displayName: "VisionClaw Glasses Broker",
        version: "0.1.0",
        platform: process.platform,
        mode: "backend",
      },
      caps: [],
      auth,
      role: "operator",
      scopes: ["operator.write"],
    };
    if (supplied?.device && typeof supplied.device === "object") {
      params.device = supplied.device;
    }
    try {
      await this.#sendRequest("connect", params);
    } catch {
      this.#failHandshake(
        generation,
        new Error("OpenClaw Gateway authentication failed."),
      );
      return;
    }
    if (generation !== this.#socketGeneration) return;
    this.#connected = true;
    const reconnected = this.#everConnected;
    this.#everConnected = true;
    const resolveConnect = this.#resolveConnect;
    this.#resolveConnect = undefined;
    this.#rejectConnect = undefined;
    resolveConnect?.();
    for (const listener of this.#connectionListeners) {
      try {
        listener({ reconnected });
      } catch {
        this.#safeLog("Gateway connection listener failed.");
      }
    }
  }

  #sendRequest(method, params) {
    const socket = this.#socket;
    if (!socket || socket.readyState !== 1) {
      return Promise.reject(
        new Error(`OpenClaw Gateway ${method} request could not be sent.`),
      );
    }
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`OpenClaw Gateway ${method} request timed out.`));
      }, this.#requestTimeoutMilliseconds);
      timer.unref?.();
      this.#pending.set(id, { method, resolve, reject, timer });
      try {
        socket.send(JSON.stringify({
          type: "req",
          id,
          method,
          params,
        }));
      } catch {
        clearTimeout(timer);
        this.#pending.delete(id);
        reject(new Error(`OpenClaw Gateway ${method} request could not be sent.`));
      }
    });
  }

  #handleClose(generation) {
    if (generation !== this.#socketGeneration) return;
    this.#connected = false;
    this.#socket = undefined;
    this.#rejectOutstanding(new Error("OpenClaw Gateway connection was lost."));
    const rejectConnect = this.#rejectConnect;
    this.#clearConnectPromise();
    rejectConnect?.(new Error("OpenClaw Gateway connection was lost."));
    if (
      !this.#manualClose
      && this.#suppressReconnectGeneration !== generation
    ) {
      this.#scheduleReconnect();
    }
  }

  #failHandshake(generation, error) {
    if (generation !== this.#socketGeneration) return;
    this.#suppressReconnectGeneration = generation;
    const rejectConnect = this.#rejectConnect;
    this.#clearConnectPromise();
    rejectConnect?.(error);
    this.#rejectOutstanding(error);
    const socket = this.#socket;
    this.#socket = undefined;
    if (socket && socket.readyState < 2) socket.close(1000, "authentication failed");
  }

  #scheduleReconnect() {
    clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = setTimeout(() => {
      this.#reconnectTimer = undefined;
      if (this.#manualClose) return;
      this.connect().catch(() => {
        if (!this.#manualClose) this.#scheduleReconnect();
      });
    }, this.#reconnectDelayMilliseconds);
    this.#reconnectTimer.unref?.();
  }

  #rejectOutstanding(error) {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
  }

  #clearConnectPromise() {
    this.#connectPromise = undefined;
    this.#resolveConnect = undefined;
    this.#rejectConnect = undefined;
  }

  #safeLog(message) {
    try {
      this.#logger({ component: "openclaw-gateway", message });
    } catch {
      // Logging must never affect the broker connection.
    }
  }
}

function assertGatewayURL(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new Error("OpenClaw Gateway URL is invalid.");
  }
  const loopback = new Set(["127.0.0.1", "localhost", "[::1]"]);
  if (
    url.protocol !== "wss:"
    && !(url.protocol === "ws:" && loopback.has(url.hostname))
  ) {
    throw new Error("OpenClaw Gateway requires TLS unless it is on loopback.");
  }
}

async function messageText(value) {
  if (typeof value === "string") return value;
  if (Buffer.isBuffer(value)) return value.toString("utf8");
  if (value instanceof ArrayBuffer) {
    return Buffer.from(value).toString("utf8");
  }
  if (typeof value?.text === "function") return value.text();
  throw new Error("Unsupported Gateway frame.");
}
