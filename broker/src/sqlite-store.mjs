import {
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import {
  chmodSync,
  mkdirSync,
} from "node:fs";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const TASK_REFERENCE_PREFIX = "vct1";

export class SQLiteBrokerStore {
  #database;
  #handleSecret;
  #ownsDatabase;

  constructor({
    databasePath,
    database,
    handleSecret,
  } = {}) {
    if (database) {
      this.#database = database;
      this.#ownsDatabase = false;
    } else {
      if (!databasePath) {
        throw new Error("An explicit SQLite database path is required.");
      }
      if (databasePath !== ":memory:") {
        mkdirSync(path.dirname(path.resolve(databasePath)), {
          mode: 0o700,
          recursive: true,
        });
      }
      this.#database = new DatabaseSync(databasePath);
      this.#ownsDatabase = true;
      if (databasePath !== ":memory:") {
        chmodSync(databasePath, 0o600);
      }
    }
    this.#configure();
    this.#migrate();
    this.#handleSecret = this.#loadOrCreateHandleSecret(handleSecret);
  }

  close() {
    if (!this.#ownsDatabase) return;
    this.#database.close();
    this.#ownsDatabase = false;
  }

  run(sql, ...parameters) {
    return this.#database.prepare(sql).run(...parameters);
  }

  get(sql, ...parameters) {
    return this.#database.prepare(sql).get(...parameters);
  }

  all(sql, ...parameters) {
    return this.#database.prepare(sql).all(...parameters);
  }

  transaction(callback) {
    this.#database.exec("BEGIN IMMEDIATE");
    try {
      const value = callback();
      this.#database.exec("COMMIT");
      return value;
    } catch (error) {
      this.#database.exec("ROLLBACK");
      throw error;
    }
  }

  registerTask({ pairingID, sourceRevision }) {
    const pairing = requireIdentifier(pairingID, "paired device");
    const revision = validateSourceRevision(sourceRevision);
    return this.transaction(() => {
      const existing = this.get(
        `SELECT handle_id
           FROM codex_task_handles
          WHERE pairing_id = ? AND thread_id = ?`,
        pairing,
        revision.id,
      );
      if (existing) {
        this.run(
          `UPDATE codex_task_handles
              SET revision_json = ?, updated_at = ?
            WHERE handle_id = ?`,
          JSON.stringify(revision),
          Date.now(),
          existing.handle_id,
        );
        return this.#encodeTaskReference(pairing, existing.handle_id);
      }

      for (let attempt = 0; attempt < 4; attempt += 1) {
        const handleID = randomBytes(18).toString("base64url");
        try {
          this.run(
            `INSERT INTO codex_task_handles (
               handle_id, pairing_id, thread_id, revision_json,
               created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?)`,
            handleID,
            pairing,
            revision.id,
            JSON.stringify(revision),
            Date.now(),
            Date.now(),
          );
          return this.#encodeTaskReference(pairing, handleID);
        } catch (error) {
          if (!String(error?.message).includes("UNIQUE")) throw error;
        }
      }
      throw new Error("Could not create an opaque Codex task reference.");
    });
  }

  resolveTask({ pairingID, taskReference }) {
    const pairing = requireIdentifier(pairingID, "paired device");
    const handleID = this.#decodeTaskReference(pairing, taskReference);
    const row = this.get(
      `SELECT thread_id, revision_json
         FROM codex_task_handles
        WHERE handle_id = ? AND pairing_id = ?`,
      handleID,
      pairing,
    );
    if (!row) {
      throw new Error("Codex task reference was not found or is invalid.");
    }
    const revision = validateSourceRevision(JSON.parse(row.revision_json));
    if (revision.id !== row.thread_id) {
      throw new Error("Stored Codex task reference is invalid.");
    }
    return revision;
  }

  deriveConfirmationNonce({ pairingID, actionID, clientRequestID }) {
    const digest = createHmac("sha256", this.#handleSecret)
      .update(
        [
          "visionclaw-confirmation-nonce-v1",
          requireIdentifier(pairingID, "paired device"),
          requireOpaqueSegment(actionID, "prepared action"),
          requireIdentifier(clientRequestID, "request"),
        ].join("\0"),
      )
      .digest("base64url");
    return `vcn_${digest}`;
  }

  #configure() {
    this.#database.exec("PRAGMA foreign_keys = ON");
    this.#database.exec("PRAGMA busy_timeout = 5000");
    this.#database.exec("PRAGMA journal_mode = WAL");
    this.#database.exec("PRAGMA synchronous = FULL");
  }

  #migrate() {
    this.#database.exec(`
      CREATE TABLE IF NOT EXISTS broker_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT;

      CREATE TABLE IF NOT EXISTS codex_task_handles (
        handle_id TEXT PRIMARY KEY,
        pairing_id TEXT NOT NULL,
        thread_id TEXT NOT NULL,
        revision_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (pairing_id, thread_id)
      ) STRICT;

      CREATE TABLE IF NOT EXISTS codex_actions (
        action_id TEXT PRIMARY KEY,
        pairing_id TEXT NOT NULL,
        task_reference TEXT NOT NULL,
        source_thread_id TEXT NOT NULL,
        source_revision_json TEXT NOT NULL,
        instruction TEXT NOT NULL,
        instruction_hash TEXT NOT NULL,
        client_request_id TEXT NOT NULL,
        confirmation_nonce_hash TEXT NOT NULL,
        expires_at INTEGER NOT NULL,
        state TEXT NOT NULL,
        isolated_workspace_path TEXT,
        isolated_workspace_revision TEXT,
        failure_code TEXT,
        fork_thread_id TEXT,
        fork_task_reference TEXT,
        turn_id TEXT,
        turn_status TEXT,
        receipt_json TEXT,
        accepted_at INTEGER,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (pairing_id, client_request_id)
      ) STRICT;

      CREATE INDEX IF NOT EXISTS codex_actions_turn_id
        ON codex_actions (turn_id);
    `);
    this.#ensureCodexActionColumn("isolated_workspace_path", "TEXT");
    this.#ensureCodexActionColumn("isolated_workspace_revision", "TEXT");
    this.#ensureCodexActionColumn("failure_code", "TEXT");
  }

  #ensureCodexActionColumn(name, declaration) {
    const columns = this.#database
      .prepare("PRAGMA table_info(codex_actions)")
      .all();
    if (columns.some((column) => column.name === name)) return;
    this.#database.exec(
      `ALTER TABLE codex_actions ADD COLUMN ${name} ${declaration}`,
    );
  }

  #loadOrCreateHandleSecret(requestedSecret) {
    const existing = this.get(
      "SELECT value FROM broker_metadata WHERE key = ?",
      "codex_task_handle_secret",
    );
    const provided = normalizeSecret(requestedSecret);
    if (existing) {
      const stored = Buffer.from(existing.value, "base64url");
      if (provided && !constantTimeEqual(stored, provided)) {
        throw new Error("Codex task-reference secret does not match this store.");
      }
      return stored;
    }
    const secret = provided ?? randomBytes(32);
    this.run(
      "INSERT INTO broker_metadata (key, value) VALUES (?, ?)",
      "codex_task_handle_secret",
      secret.toString("base64url"),
    );
    return secret;
  }

  #encodeTaskReference(pairingID, handleID) {
    const signature = createHmac("sha256", this.#handleSecret)
      .update(`${TASK_REFERENCE_PREFIX}\0${pairingID}\0${handleID}`)
      .digest("base64url");
    return `${TASK_REFERENCE_PREFIX}.${handleID}.${signature}`;
  }

  #decodeTaskReference(pairingID, taskReference) {
    const match = /^vct1\.([A-Za-z0-9_-]{20,})\.([A-Za-z0-9_-]{40,})$/
      .exec(String(taskReference ?? ""));
    if (!match) {
      throw new Error("Codex task reference was not found or is invalid.");
    }
    const [, handleID, signature] = match;
    const expected = createHmac("sha256", this.#handleSecret)
      .update(`${TASK_REFERENCE_PREFIX}\0${pairingID}\0${handleID}`)
      .digest();
    let actual;
    try {
      actual = Buffer.from(signature, "base64url");
    } catch {
      throw new Error("Codex task reference was not found or is invalid.");
    }
    if (!constantTimeEqual(expected, actual)) {
      throw new Error("Codex task reference was not found or is invalid.");
    }
    return handleID;
  }
}

export function validateSourceRevision(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Codex source revision is missing.");
  }
  const id = requireIdentifier(value.id, "Codex task");
  const cwd = String(value.cwd ?? "");
  if (!path.isAbsolute(cwd)) {
    throw new Error("Codex task workspace must be an absolute path.");
  }
  const updatedAt = Number(value.updatedAt);
  if (!Number.isSafeInteger(updatedAt) || updatedAt < 0) {
    throw new Error("Codex task revision timestamp is invalid.");
  }
  const name = boundedText(value.name ?? "Untitled Codex task", 160);
  const status = boundedText(value.status ?? "unknown", 80);
  return Object.freeze({ id, updatedAt, status, cwd, name });
}

function normalizeSecret(value) {
  if (value === undefined || value === null) return null;
  const secret = Buffer.isBuffer(value)
    ? Buffer.from(value)
    : Buffer.from(String(value), "utf8");
  if (secret.length < 32) {
    throw new Error("Codex task-reference secret must be at least 32 bytes.");
  }
  return secret;
}

function constantTimeEqual(left, right) {
  return left.length === right.length && timingSafeEqual(left, right);
}

function requireIdentifier(value, label) {
  const identifier = String(value ?? "");
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{2,255}$/.test(identifier)) {
    throw new Error(`${label} identifier is invalid.`);
  }
  return identifier;
}

function requireOpaqueSegment(value, label) {
  const identifier = String(value ?? "");
  if (!/^[A-Za-z0-9_-]{20,255}$/.test(identifier)) {
    throw new Error(`${label} identifier is invalid.`);
  }
  return identifier;
}

function boundedText(value, maximum) {
  const text = String(value).replace(/\s+/g, " ").trim();
  if (!text) return "unknown";
  return text.length <= maximum
    ? text
    : `${text.slice(0, maximum - 1)}…`;
}
