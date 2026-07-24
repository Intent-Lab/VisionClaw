import { randomBytes } from "node:crypto";
import { chmodSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";

const TERMINAL_STATUSES = new Set(["completed", "aborted", "failed"]);
const ALLOWED_STATUSES = new Set([
  "started",
  "streaming",
  ...TERMINAL_STATUSES,
]);
const RESTART_FAILURE =
  "Eva was interrupted because the glasses broker restarted. Check OpenClaw before trying again.";

export class HarnessOperationStore {
  #database;
  #closed = false;

  constructor({ path }) {
    if (typeof path !== "string" || path.length === 0) {
      throw new Error("A harness operation database path is required.");
    }
    if (path !== ":memory:") {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    }
    this.#database = new DatabaseSync(path);
    this.#database.exec(`
      CREATE TABLE IF NOT EXISTS harness_operations (
        operation_id TEXT PRIMARY KEY,
        pairing_id TEXT NOT NULL,
        client_request_id TEXT NOT NULL,
        run_id TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        response TEXT NOT NULL,
        error TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE(pairing_id, client_request_id)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS harness_operations_owner
        ON harness_operations(pairing_id, operation_id);
    `);
    if (path !== ":memory:") chmodSync(path, 0o600);
  }

  create({
    pairingID,
    clientRequestID,
    runID,
    now = Date.now(),
  }) {
    validateIdentifier(pairingID, "pairing");
    validateIdentifier(clientRequestID, "client request");
    validateIdentifier(runID, "run");
    const existing = this.findByRequest(pairingID, clientRequestID);
    if (existing) {
      if (existing.runID !== runID) {
        throw new Error("Harness operation idempotency conflict.");
      }
      return existing;
    }
    const operationID = randomBytes(24).toString("base64url");
    try {
      this.#database.prepare(`
        INSERT INTO harness_operations (
          operation_id,
          pairing_id,
          client_request_id,
          run_id,
          status,
          sequence,
          response,
          error,
          created_at,
          updated_at
        ) VALUES (?, ?, ?, ?, 'started', 0, '', NULL, ?, ?)
      `).run(
        operationID,
        pairingID,
        clientRequestID,
        runID,
        now,
        now,
      );
    } catch {
      const raced = this.findByRequest(pairingID, clientRequestID);
      if (raced?.runID === runID) return raced;
      throw new Error("Harness operation idempotency conflict.");
    }
    return this.getOwned(operationID, pairingID);
  }

  findByRequest(pairingID, clientRequestID) {
    const row = this.#database.prepare(`
      SELECT * FROM harness_operations
      WHERE pairing_id = ? AND client_request_id = ?
    `).get(pairingID, clientRequestID);
    return row ? fromRow(row) : null;
  }

  getOwned(operationID, pairingID) {
    const row = this.#database.prepare(`
      SELECT * FROM harness_operations
      WHERE operation_id = ? AND pairing_id = ?
    `).get(operationID, pairingID);
    return row ? fromRow(row) : null;
  }

  getByRun(runID) {
    const row = this.#database.prepare(`
      SELECT * FROM harness_operations
      WHERE run_id = ?
    `).get(runID);
    return row ? fromRow(row) : null;
  }

  updateByRun({
    runID,
    status,
    sequence,
    response = "",
    error = null,
    now = Date.now(),
  }) {
    if (
      !ALLOWED_STATUSES.has(status)
      || !Number.isSafeInteger(sequence)
      || sequence < 0
      || typeof response !== "string"
      || response.length > 12_000
      || (error !== null && (typeof error !== "string" || error.length > 1_000))
    ) {
      throw new Error("Harness operation update is invalid.");
    }
    const result = this.#database.prepare(`
      UPDATE harness_operations
      SET
        status = ?,
        sequence = ?,
        response = ?,
        error = ?,
        updated_at = ?
      WHERE run_id = ?
        AND sequence < ?
        AND status NOT IN ('completed', 'aborted', 'failed')
    `).run(
      status,
      sequence,
      response,
      error,
      now,
      runID,
      sequence,
    );
    return result.changes === 1;
  }

  failInterrupted({ now = Date.now() } = {}) {
    if (!Number.isSafeInteger(now) || now < 0) {
      throw new Error("Harness operation recovery timestamp is invalid.");
    }
    const result = this.#database.prepare(`
      UPDATE harness_operations
      SET
        status = 'failed',
        sequence = sequence + 1,
        error = ?,
        updated_at = ?
      WHERE status IN ('started', 'streaming')
    `).run(RESTART_FAILURE, now);
    return result.changes;
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#database.close();
  }
}

function fromRow(row) {
  return Object.freeze({
    operationID: row.operation_id,
    pairingID: row.pairing_id,
    clientRequestID: row.client_request_id,
    runID: row.run_id,
    status: row.status,
    sequence: Number(row.sequence),
    response: row.response,
    error: row.error ?? null,
    createdAt: Number(row.created_at),
    updatedAt: Number(row.updated_at),
  });
}

function validateIdentifier(value, label) {
  if (
    typeof value !== "string"
    || value.length < 1
    || value.length > 256
    || /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new Error(`Harness operation ${label} identifier is invalid.`);
  }
}
