import { createHash } from "node:crypto";

import { redactSecrets } from "./security.mjs";

const DEFAULT_GUARDRAIL = [
  "This request came from the paired VisionClaw glasses broker.",
  "Never reveal credentials, tokens, private keys, environment variable values,",
  "raw configuration secrets, or private filesystem paths.",
  "Do not claim an external action succeeded without a concrete result.",
  "If an action requires approval, say that it must be approved in OpenClaw.",
].join(" ");

const ACTIVE_STATES = new Set(["started", "streaming"]);
const COMPLETED_WAIT_STATES = new Set(["complete", "completed", "done", "ok"]);
const ABORTED_WAIT_STATES = new Set(["abort", "aborted", "cancelled", "canceled"]);
const FAILED_WAIT_STATES = new Set(["error", "failed"]);

export class OpenClawAdapter {
  #gatewayClient;
  #allowedAgentIDs;
  #maximumResponseCharacters;
  #historyLimit;
  #redact;
  #runs = new Map();
  #updateListeners = new Set();
  #reconciling = false;

  constructor({
    gatewayClient,
    allowedAgentIDs,
    maximumResponseCharacters = 12_000,
    historyLimit = 50,
    redactor = redactSecrets,
  }) {
    if (
      !gatewayClient
      || typeof gatewayClient.connect !== "function"
      || typeof gatewayClient.request !== "function"
      || typeof gatewayClient.onEvent !== "function"
      || typeof gatewayClient.onConnection !== "function"
    ) {
      throw new Error("An OpenClaw Gateway client is required.");
    }
    if (!Array.isArray(allowedAgentIDs) || allowedAgentIDs.length === 0) {
      throw new Error("At least one OpenClaw agent must be registered.");
    }
    if (!Number.isSafeInteger(historyLimit) || historyLimit < 1 || historyLimit > 100) {
      throw new Error("OpenClaw history limit must be between 1 and 100.");
    }
    const redact = typeof redactor === "function"
      ? redactor
      : redactor?.redact?.bind(redactor);
    if (typeof redact !== "function") {
      throw new Error("A broker output redactor is required.");
    }
    this.#gatewayClient = gatewayClient;
    this.#allowedAgentIDs = new Set(allowedAgentIDs);
    this.#maximumResponseCharacters = maximumResponseCharacters;
    this.#historyLimit = historyLimit;
    this.#redact = redact;
    gatewayClient.onEvent((event) => this.#handleGatewayEvent(event));
    gatewayClient.onConnection(({ reconnected }) => {
      if (reconnected) void this.#reconcileActiveRuns();
    });
  }

  async invoke({
    agentID,
    instruction,
    clientRequestID,
    pairingID,
  }) {
    if (!this.#allowedAgentIDs.has(agentID)) {
      throw new Error(`OpenClaw agent ${agentID} is not registered for VisionClaw.`);
    }
    const cleanInstruction = String(instruction ?? "").trim();
    if (!cleanInstruction || cleanInstruction.length > 4_000) {
      throw new Error("OpenClaw instruction is missing or too long.");
    }
    assertOpaqueIdentifier(clientRequestID, "client request");
    assertOpaqueIdentifier(pairingID, "pairing");
    const pairingDigest = digest(pairingID);
    const sessionKey = `agent:${agentID}:visionclaw:${pairingDigest.slice(0, 16)}`;
    const message = `${DEFAULT_GUARDRAIL}\n\nUser request:\n${cleanInstruction}`;
    await this.#gatewayClient.connect();
    const acknowledgement = await this.#gatewayClient.request("chat.send", {
      sessionKey,
      agentId: agentID,
      message,
      idempotencyKey: clientRequestID,
      deliver: false,
      fastMode: "auto",
      fastAutoOnSeconds: 20,
      timeoutMs: 600_000,
    });
    if (
      acknowledgement?.status !== "started"
      || typeof acknowledgement.runId !== "string"
      || acknowledgement.runId.length === 0
    ) {
      throw new Error("OpenClaw did not acknowledge the request.");
    }
    const existing = this.#runs.get(acknowledgement.runId);
    if (
      existing
      && (
        existing.clientRequestID !== clientRequestID
        || existing.pairingDigest !== pairingDigest
      )
    ) {
      throw new Error("OpenClaw returned a conflicting run identifier.");
    }
    this.#runs.set(acknowledgement.runId, {
      runID: acknowledgement.runId,
      agentID,
      sessionKey,
      pairingDigest,
      clientRequestID,
      status: "started",
      lastSequence: -1,
      response: "",
    });
    return {
      status: "started",
      runID: acknowledgement.runId,
      clientRequestID,
    };
  }

  onUpdate(listener) {
    if (typeof listener !== "function") {
      throw new Error("An OpenClaw update listener is required.");
    }
    this.#updateListeners.add(listener);
    return () => this.#updateListeners.delete(listener);
  }

  async abort({ runID, pairingID }) {
    assertOpaqueIdentifier(runID, "run");
    assertOpaqueIdentifier(pairingID, "pairing");
    const run = this.#runs.get(runID);
    if (
      !run
      || !ACTIVE_STATES.has(run.status)
      || run.pairingDigest !== digest(pairingID)
    ) {
      throw new Error("OpenClaw run is not active or is not owned by this pairing.");
    }
    await this.#gatewayClient.request("chat.abort", {
      sessionKey: run.sessionKey,
      agentId: run.agentID,
      runId: run.runID,
    });
    run.status = "aborted";
    this.#emitUpdate(run, {
      status: "aborted",
      sequence: run.lastSequence,
      response: run.response,
    });
    return { status: "aborted", runID };
  }

  #handleGatewayEvent(event) {
    if (event?.event !== "chat") return;
    const payload = event.payload;
    const run = this.#runs.get(payload?.runId);
    if (!run || !ACTIVE_STATES.has(run.status)) return;
    if (payload.sessionKey && payload.sessionKey !== run.sessionKey) return;
    if (payload.agentId && payload.agentId !== run.agentID) return;
    if (
      !Number.isSafeInteger(payload.seq)
      || payload.seq < 0
      || payload.seq <= run.lastSequence
    ) {
      return;
    }
    run.lastSequence = payload.seq;
    if (payload.state === "delta") {
      const delta = typeof payload.deltaText === "string" ? payload.deltaText : "";
      run.response = this.#boundedResponse(
        payload.replace === true ? delta : `${run.response}${delta}`,
      );
      run.status = "streaming";
      this.#emitUpdate(run, {
        status: "streaming",
        sequence: payload.seq,
        replace: payload.replace === true,
        response: run.response,
      });
      return;
    }
    if (payload.state === "final") {
      const finalText = visibleMessageText(payload.message);
      if (finalText) run.response = this.#boundedResponse(finalText);
      run.status = "completed";
      this.#emitUpdate(run, {
        status: "completed",
        sequence: payload.seq,
        response: run.response,
      });
      return;
    }
    if (payload.state === "aborted") {
      run.status = "aborted";
      this.#emitUpdate(run, {
        status: "aborted",
        sequence: payload.seq,
        response: run.response,
      });
      return;
    }
    if (payload.state === "error") {
      run.status = "failed";
      this.#emitUpdate(run, {
        status: "failed",
        sequence: payload.seq,
        response: run.response,
        error: "OpenClaw request failed.",
      });
    }
  }

  async #reconcileActiveRuns() {
    if (this.#reconciling) return;
    this.#reconciling = true;
    try {
      const activeRuns = [...this.#runs.values()]
        .filter((run) => ACTIVE_STATES.has(run.status));
      for (const run of activeRuns) {
        await this.#reconcileRun(run);
      }
    } finally {
      this.#reconciling = false;
    }
  }

  async #reconcileRun(run) {
    let waitStatus = "unknown";
    try {
      const waited = await this.#gatewayClient.request("agent.wait", {
        runId: run.runID,
        timeoutMs: 0,
      });
      waitStatus = String(waited?.status ?? waited?.state ?? "unknown").toLowerCase();
    } catch {
      waitStatus = "unknown";
    }
    if (ABORTED_WAIT_STATES.has(waitStatus)) {
      run.status = "aborted";
      this.#emitUpdate(run, {
        status: "aborted",
        sequence: nextSyntheticSequence(run),
        response: run.response,
      });
      return;
    }
    if (FAILED_WAIT_STATES.has(waitStatus)) {
      run.status = "failed";
      this.#emitUpdate(run, {
        status: "failed",
        sequence: nextSyntheticSequence(run),
        response: run.response,
        error: "OpenClaw request failed.",
      });
      return;
    }
    if (!COMPLETED_WAIT_STATES.has(waitStatus) && waitStatus !== "unknown") {
      return;
    }
    let history;
    try {
      history = await this.#gatewayClient.request("chat.history", {
        sessionKey: run.sessionKey,
        agentId: run.agentID,
        limit: this.#historyLimit,
      });
    } catch {
      return;
    }
    const recovered = lastAssistantResponse(history, run.runID);
    if (recovered) run.response = this.#boundedResponse(recovered);
    if (!run.response) {
      if (waitStatus === "unknown") return;
      run.status = "failed";
      this.#emitUpdate(run, {
        status: "failed",
        sequence: nextSyntheticSequence(run),
        response: "",
        error: "OpenClaw completed, but its response could not be recovered.",
      });
      return;
    }
    run.status = "completed";
    this.#emitUpdate(run, {
      status: "completed",
      sequence: nextSyntheticSequence(run),
      response: run.response,
      recovered: true,
    });
  }

  #emitUpdate(run, fields) {
    const update = Object.freeze({
      runID: run.runID,
      clientRequestID: run.clientRequestID,
      ...fields,
    });
    for (const listener of this.#updateListeners) {
      try {
        listener(update);
      } catch {
        // A phone transport listener cannot disrupt Gateway processing.
      }
    }
  }

  #boundedResponse(value) {
    return bounded(
      this.#redact(String(value)),
      this.#maximumResponseCharacters,
    );
  }
}

function digest(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

function nextSyntheticSequence(run) {
  return Math.max(1, run.lastSequence + 1);
}

function assertOpaqueIdentifier(value, label) {
  if (
    typeof value !== "string"
    || value.length < 1
    || value.length > 256
    || /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new Error(`OpenClaw ${label} identifier is invalid.`);
  }
}

function visibleMessageText(message) {
  if (typeof message === "string") return message.trim();
  if (!message || typeof message !== "object") return "";
  if (typeof message.text === "string") return message.text.trim();
  if (!Array.isArray(message.content)) return "";
  return message.content
    .filter((item) => item?.type === "text" && typeof item.text === "string")
    .map((item) => item.text)
    .join("\n")
    .trim();
}

function lastAssistantResponse(history, runID) {
  const messages = Array.isArray(history?.messages)
    ? history.messages
    : Array.isArray(history?.result?.messages)
      ? history.result.messages
      : [];
  const assistantMessages = messages.filter(
    (message) => message?.role === "assistant",
  );
  const exactRunMessages = assistantMessages.filter(
    (message) => message.runId === runID || message.runID === runID,
  );
  for (let index = exactRunMessages.length - 1; index >= 0; index -= 1) {
    const text = visibleMessageText(exactRunMessages[index]);
    if (text) return text;
  }
  const expectedUserIdempotencyKey = `${runID}:user`;
  let userIndex = -1;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    const idempotencyKey = message?.idempotencyKey
      ?? message?.__openclaw?.idempotencyKey;
    if (
      message?.role === "user"
      && idempotencyKey === expectedUserIdempotencyKey
    ) {
      userIndex = index;
      break;
    }
  }
  if (userIndex < 0) return "";
  let recovered = "";
  for (let index = userIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    if (message?.role === "user") break;
    if (message?.role !== "assistant") continue;
    const text = visibleMessageText(message);
    if (text) recovered = text;
  }
  return recovered;
}

function bounded(value, maximum) {
  if (value.length <= maximum) return value;
  const marker = "\n[response truncated]";
  return `${value.slice(0, Math.max(0, maximum - marker.length))}${marker}`;
}
