import { redactSecrets } from "./security.mjs";

export class AsyncHarnessAdapter {
  #backendAdapter;
  #operationStore;
  #redact;
  #pendingUpdates = new Map();

  constructor({
    backendAdapter,
    operationStore,
    redactor = redactSecrets,
  }) {
    if (
      typeof backendAdapter?.invoke !== "function"
      || typeof backendAdapter?.onUpdate !== "function"
      || typeof backendAdapter?.abort !== "function"
    ) {
      throw new Error("An asynchronous OpenClaw adapter is required.");
    }
    if (
      typeof operationStore?.create !== "function"
      || typeof operationStore?.findByRequest !== "function"
      || typeof operationStore?.getOwned !== "function"
      || typeof operationStore?.getByRun !== "function"
      || typeof operationStore?.updateByRun !== "function"
    ) {
      throw new Error("A persistent harness operation store is required.");
    }
    const redact = typeof redactor === "function"
      ? redactor
      : redactor?.redact?.bind(redactor);
    if (typeof redact !== "function") {
      throw new Error("A broker output redactor is required.");
    }
    this.#backendAdapter = backendAdapter;
    this.#operationStore = operationStore;
    this.#redact = redact;
    backendAdapter.onUpdate((update) => this.#handleUpdate(update));
  }

  async invoke(request) {
    const existing = this.#operationStore.findByRequest(
      request.pairingID,
      request.clientRequestID,
    );
    if (existing) return acknowledgement(existing);

    const backend = await this.#backendAdapter.invoke(request);
    const record = this.#operationStore.create({
      pairingID: request.pairingID,
      clientRequestID: request.clientRequestID,
      runID: backend.runID,
    });
    const pending = this.#pendingUpdates.get(backend.runID);
    if (pending) {
      this.#pendingUpdates.delete(backend.runID);
      this.#applyUpdate(pending);
    }
    return acknowledgement(record);
  }

  poll({
    operationID,
    pairingID,
    afterSequence = 0,
  }) {
    const record = this.#operationStore.getOwned(operationID, pairingID);
    if (!record) {
      throw new Error("Harness operation was not found.");
    }
    if (record.sequence <= afterSequence && !isTerminal(record.status)) {
      return {
        operationID,
        status: "pending",
        sequence: record.sequence,
      };
    }
    return {
      operationID,
      status: record.status,
      sequence: record.sequence,
      response: this.#safeOutput(record.response, 12_000),
      error: record.error == null
        ? null
        : this.#safeOutput(record.error, 1_000),
    };
  }

  async cancel({
    operationID,
    pairingID,
  }) {
    const record = this.#operationStore.getOwned(operationID, pairingID);
    if (!record) {
      throw new Error("Harness operation was not found.");
    }
    if (isTerminal(record.status)) {
      return { operationID, status: record.status };
    }
    await this.#backendAdapter.abort({
      runID: record.runID,
      pairingID,
    });
    this.#operationStore.updateByRun({
      runID: record.runID,
      status: "aborted",
      sequence: record.sequence + 1,
      response: this.#safeOutput(record.response, 12_000),
      error: null,
    });
    return { operationID, status: "aborted" };
  }

  #handleUpdate(update) {
    try {
      if (!this.#applyUpdate(update) && !this.#operationStore.getByRun(update.runID)) {
        const current = this.#pendingUpdates.get(update.runID);
        if (!current || update.sequence > current.sequence) {
          this.#pendingUpdates.set(update.runID, update);
        }
      }
    } catch {
      // A malformed backend event cannot reach the phone or disrupt the broker.
    }
  }

  #applyUpdate(update) {
    return this.#operationStore.updateByRun({
      runID: update.runID,
      status: update.status,
      sequence: update.sequence,
      response: this.#safeOutput(update.response ?? "", 12_000),
      error: update.error == null
        ? null
        : this.#safeOutput(update.error, 1_000),
    });
  }

  #safeOutput(value, maximum) {
    return boundedOutput(
      this.#redact(String(value)),
      maximum,
    );
  }
}

function acknowledgement(record) {
  return Object.freeze({
    status: "started",
    operationID: record.operationID,
    clientRequestID: record.clientRequestID,
    message: "Eva is working on it. I’ll speak the result when it is ready.",
  });
}

function isTerminal(status) {
  return ["completed", "aborted", "failed"].includes(status);
}

function boundedOutput(value, maximum) {
  if (value.length <= maximum) return value;
  const marker = "\n[output truncated]";
  return `${value.slice(0, maximum - marker.length)}${marker}`;
}
