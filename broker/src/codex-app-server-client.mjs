import { EventEmitter } from "node:events";
import { spawn } from "node:child_process";
import path from "node:path";
import { homedir } from "node:os";

const DEFAULT_CODEX_BINARY =
  "/Applications/ChatGPT.app/Contents/Resources/codex";

export class CodexAppServerClient extends EventEmitter {
  #binaryPath;
  #processFactory;
  #requestTimeoutMilliseconds;
  #processEnvironment;
  #child = null;
  #startPromise = null;
  #nextRequestID = 1;
  #pending = new Map();
  #stdoutBuffer = "";
  #closed = false;

  constructor({
    binaryPath = DEFAULT_CODEX_BINARY,
    processFactory = defaultProcessFactory,
    processEnvironment = process.env,
    requestTimeoutMilliseconds = 15_000,
  } = {}) {
    super();
    this.#binaryPath = binaryPath;
    this.#processFactory = processFactory;
    this.#processEnvironment = processEnvironment;
    this.#requestTimeoutMilliseconds = requestTimeoutMilliseconds;
  }

  async start() {
    if (this.#closed) {
      throw new Error("Codex app-server client is closed.");
    }
    if (this.#startPromise) {
      return this.#startPromise;
    }
    const environment = safeProcessEnvironment(this.#processEnvironment);
    this.#child = this.#processFactory(
      this.#binaryPath,
      ["app-server", "--stdio"],
      { env: environment },
    );
    this.#attachProcess(this.#child);
    this.#startPromise = (async () => {
      const result = await this.#send("initialize", {
        capabilities: {
          experimentalApi: true,
          optOutNotificationMethods: [
            "item/agentMessage/delta",
            "item/reasoning/textDelta",
            "item/reasoning/summaryTextDelta",
            "item/commandExecution/outputDelta",
          ],
        },
        clientInfo: {
          name: "visionclaw-glasses-broker",
          title: "VisionClaw Glasses Broker",
          version: "0.1.0",
        },
      });
      this.#write({ method: "initialized", params: {} });
      return result;
    })().catch((error) => {
      this.#startPromise = null;
      throw error;
    });
    await this.#startPromise;
  }

  async request(method, params) {
    await this.start();
    return this.#send(method, params);
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#child?.kill();
    this.#rejectPending(new Error("Codex app-server client closed."));
  }

  #attachProcess(child) {
    child.stdout.setEncoding?.("utf8");
    child.stdout.on("data", (chunk) => this.#handleStdout(String(chunk)));
    child.stderr.on("data", (chunk) => {
      this.emit("diagnostic", safeDiagnostic(chunk));
    });
    child.on("error", (error) => this.#handleExit(error));
    child.on("exit", (code, signal) => {
      this.#handleExit(
        new Error(
          `Codex app-server exited (code ${code ?? "unknown"}, signal ${signal ?? "none"}).`,
        ),
      );
    });
  }

  #handleStdout(chunk) {
    this.#stdoutBuffer += chunk;
    for (;;) {
      const newline = this.#stdoutBuffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.#stdoutBuffer.slice(0, newline).trim();
      this.#stdoutBuffer = this.#stdoutBuffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.emit("diagnostic", "Codex app-server emitted malformed JSON.");
        continue;
      }
      this.#handleMessage(message);
    }
  }

  #handleMessage(message) {
    if (message && "id" in message && !message.method) {
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(
          new Error(message.error.message ?? "Codex app-server request failed."),
        );
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (message && "id" in message && message.method) {
      const decline = declineResultFor(message.method);
      if (decline) {
        this.#write({ id: message.id, result: decline });
        this.emit("interaction-declined", { method: message.method });
      } else {
        this.#write({
          id: message.id,
          error: {
            code: -32601,
            message: "Unsupported Codex app-server request.",
          },
        });
      }
      return;
    }
    if (message?.method) {
      this.emit("notification", {
        method: message.method,
        params: message.params,
      });
    }
  }

  #send(method, params) {
    if (!this.#child || this.#closed) {
      return Promise.reject(new Error("Codex app-server is not running."));
    }
    const id = this.#nextRequestID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`Codex app-server request ${method} timed out.`));
      }, this.#requestTimeoutMilliseconds);
      timer.unref?.();
      this.#pending.set(id, { method, resolve, reject, timer });
      this.#write({ id, method, params });
    });
  }

  #write(message) {
    this.#child?.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleExit(error) {
    this.#rejectPending(error);
    this.#child = null;
    this.#startPromise = null;
  }

  #rejectPending(error) {
    for (const pending of this.#pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.#pending.clear();
  }
}

function defaultProcessFactory(binaryPath, args, options) {
  return spawn(binaryPath, args, {
    env: options.env,
    shell: false,
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function safeProcessEnvironment(source) {
  const environment = {};
  for (const key of [
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "PATH",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "TERM",
    "__CF_USER_TEXT_ENCODING",
  ]) {
    if (typeof source[key] === "string") {
      environment[key] = source[key];
    }
  }
  environment.CODEX_HOME = source.CODEX_HOME
    || path.join(environment.HOME || homedir(), ".codex");
  return environment;
}

function declineResultFor(method) {
  switch (method) {
  case "item/commandExecution/requestApproval":
  case "item/fileChange/requestApproval":
    return {
      decision: "decline",
      reason: "Continue in Codex Desktop to approve.",
    };
  case "item/permissions/requestApproval":
    return { permissions: {}, scope: "turn" };
  case "item/tool/requestUserInput":
    return { answers: {} };
  case "mcpServer/elicitation/request":
    return { action: "decline" };
  case "item/tool/call":
    return {
      contentItems: [{
        type: "inputText",
        text: "Unavailable in glasses broker.",
      }],
      success: false,
    };
  default:
    return null;
  }
}

function safeDiagnostic(value) {
  return String(value)
    .replace(/[\r\n]+/g, " ")
    .replace(/[A-Za-z0-9_-]{32,}/g, "<redacted>")
    .slice(0, 500);
}
