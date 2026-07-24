import { spawn as spawnProcess } from "node:child_process";
import { EventEmitter } from "node:events";

const BROKER_ID_PATTERN = /^broker_[A-Za-z0-9_-]{32,128}$/;

export class BonjourAdvertiser extends EventEmitter {
  #spawn;
  #brokerID;
  #displayName;
  #port;
  #child = null;
  #state = "idle";

  constructor({
    spawn = spawnProcess,
    brokerID,
    displayName = "VisionClaw",
    port,
  }) {
    super();
    if (!BROKER_ID_PATTERN.test(String(brokerID))) {
      throw new Error("Bonjour broker identity is invalid.");
    }
    if (
      typeof displayName !== "string"
      || displayName.length < 1
      || displayName.length > 63
      || /[\0\r\n]/.test(displayName)
    ) {
      throw new Error("Bonjour display name is invalid.");
    }
    if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
      throw new Error("Bonjour port is invalid.");
    }
    this.#spawn = spawn;
    this.#brokerID = brokerID;
    this.#displayName = displayName;
    this.#port = port;
  }

  start() {
    if (this.#state !== "idle") {
      throw new Error(`Bonjour advertiser is ${this.#state}.`);
    }
    this.#state = "running";
    const child = this.#spawn("/usr/bin/dns-sd", [
      "-R",
      this.#displayName,
      "_visionclaw._tcp",
      "local.",
      String(this.#port),
      `id=${this.#brokerID}`,
      "v=1",
      "tls=1",
    ], {
      shell: false,
      stdio: "ignore",
    });
    this.#child = child;
    child.once("error", (error) => {
      this.#state = "failed";
      this.#child = null;
      this.emit("error", new Error(
        `Bonjour publisher failed: ${error?.message ?? "unknown error"}`,
      ));
    });
    child.once("exit", (code, signal) => {
      if (this.#state !== "running") return;
      this.#state = "failed";
      this.#child = null;
      this.emit("error", new Error(
        `Bonjour publisher stopped unexpectedly (${signal ?? code ?? "unknown"}).`,
      ));
    });
  }

  stop() {
    if (this.#state !== "running") {
      this.#state = "stopped";
      return;
    }
    const child = this.#child;
    this.#child = null;
    this.#state = "stopped";
    child?.kill("SIGTERM");
  }
}
