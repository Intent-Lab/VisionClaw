import { randomBytes } from "node:crypto";
import { chmodSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";

import { SecretValue } from "./runtime-state.mjs";

export const LOCAL_ADMIN_SECRET_NAME = "local-admin-authentication";

export class SecurityStateStore {
  #database;
  #closed = false;

  constructor({ path }) {
    if (typeof path !== "string" || path.length === 0) {
      throw new Error("A security state database path is required.");
    }
    if (path !== ":memory:") {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    }
    this.#database = new DatabaseSync(path);
    this.#database.exec(`
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS paired_devices (
        pairing_id TEXT PRIMARY KEY,
        broker_id TEXT NOT NULL,
        phone_key_thumbprint TEXT NOT NULL,
        phone_public_key_der BLOB NOT NULL,
        device_name TEXT NOT NULL,
        paired_at INTEGER NOT NULL,
        granted_scopes_json TEXT NOT NULL,
        revoked_at INTEGER
      ) STRICT;
      CREATE TABLE IF NOT EXISTS replay_keys (
        replay_key TEXT PRIMARY KEY,
        expires_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS replay_keys_expiry
        ON replay_keys(expires_at);
      CREATE TABLE IF NOT EXISTS broker_secrets (
        name TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT;
    `);
    if (path !== ":memory:") {
      chmodSync(path, 0o600);
    }
  }

  save(record) {
    assertPairingRecord(record);
    this.#database.prepare(`
      INSERT INTO paired_devices (
        pairing_id,
        broker_id,
        phone_key_thumbprint,
        phone_public_key_der,
        device_name,
        paired_at,
        granted_scopes_json,
        revoked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(pairing_id) DO UPDATE SET
        broker_id = excluded.broker_id,
        phone_key_thumbprint = excluded.phone_key_thumbprint,
        phone_public_key_der = excluded.phone_public_key_der,
        device_name = excluded.device_name,
        paired_at = excluded.paired_at,
        granted_scopes_json = excluded.granted_scopes_json,
        revoked_at = excluded.revoked_at
    `).run(
      record.pairingID,
      record.brokerID,
      record.phoneKeyThumbprint,
      Buffer.from(record.phonePublicKeyDER),
      record.deviceName,
      record.pairedAt,
      JSON.stringify([...new Set(record.grantedScopes)].sort()),
      record.revokedAt ?? null,
    );
  }

  get(pairingID) {
    const row = this.#database.prepare(`
      SELECT
        pairing_id,
        broker_id,
        phone_key_thumbprint,
        phone_public_key_der,
        device_name,
        paired_at,
        granted_scopes_json,
        revoked_at
      FROM paired_devices
      WHERE pairing_id = ?
    `).get(pairingID);
    return row ? pairingFromRow(row) : null;
  }

  list() {
    const rows = this.#database.prepare(`
      SELECT
        pairing_id,
        broker_id,
        phone_key_thumbprint,
        phone_public_key_der,
        device_name,
        paired_at,
        granted_scopes_json,
        revoked_at
      FROM paired_devices
      ORDER BY paired_at DESC, pairing_id ASC
    `).all();
    return rows.map(pairingFromRow);
  }

  revoke(pairingID, revokedAt = Date.now()) {
    const result = this.#database.prepare(`
      UPDATE paired_devices
      SET revoked_at = ?
      WHERE pairing_id = ?
    `).run(revokedAt, pairingID);
    return result.changes === 1;
  }

  consume(key, expiresAt, now = Date.now()) {
    if (
      typeof key !== "string"
      || key.length < 1
      || key.length > 512
      || !Number.isSafeInteger(expiresAt)
      || !Number.isSafeInteger(now)
      || expiresAt <= now
    ) {
      throw new Error("Replay key or expiry is invalid.");
    }
    this.#database.exec("BEGIN IMMEDIATE");
    try {
      this.#database.prepare(
        "DELETE FROM replay_keys WHERE expires_at <= ?",
      ).run(now);
      const existing = this.#database.prepare(
        "SELECT 1 FROM replay_keys WHERE replay_key = ?",
      ).get(key);
      if (existing) {
        throw new Error("Request replay was rejected.");
      }
      this.#database.prepare(
        "INSERT INTO replay_keys (replay_key, expires_at) VALUES (?, ?)",
      ).run(key, expiresAt);
      this.#database.exec("COMMIT");
    } catch (error) {
      this.#database.exec("ROLLBACK");
      if (/replay/i.test(error?.message ?? "")) throw error;
      throw new Error("Request replay was rejected.");
    }
  }

  getOrCreateSecret(name, byteLength = 32) {
    if (
      !/^[a-z][a-z0-9_-]{2,63}$/.test(String(name))
      || !Number.isSafeInteger(byteLength)
      || byteLength < 16
      || byteLength > 128
    ) {
      throw new Error("Broker secret name or size is invalid.");
    }
    const candidate = randomBytes(byteLength).toString("base64url");
    this.#database.prepare(`
      INSERT OR IGNORE INTO broker_secrets (name, value)
      VALUES (?, ?)
    `).run(name, candidate);
    const row = this.#database.prepare(
      "SELECT value FROM broker_secrets WHERE name = ?",
    ).get(name);
    return new SecretValue(row.value);
  }

  getSecret(name) {
    if (!/^[a-z][a-z0-9_-]{2,63}$/.test(String(name))) {
      throw new Error("Broker secret name is invalid.");
    }
    const row = this.#database.prepare(
      "SELECT value FROM broker_secrets WHERE name = ?",
    ).get(name);
    return row ? new SecretValue(row.value) : null;
  }

  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#database.close();
  }
}

function pairingFromRow(row) {
  return {
    pairingID: row.pairing_id,
    brokerID: row.broker_id,
    phoneKeyThumbprint: row.phone_key_thumbprint,
    phonePublicKeyDER: Buffer.from(row.phone_public_key_der),
    deviceName: row.device_name,
    pairedAt: Number(row.paired_at),
    grantedScopes: JSON.parse(row.granted_scopes_json),
    revokedAt: row.revoked_at == null ? null : Number(row.revoked_at),
  };
}

function assertPairingRecord(record) {
  const requiredStrings = [
    "pairingID",
    "brokerID",
    "phoneKeyThumbprint",
    "deviceName",
  ];
  if (
    !record
    || requiredStrings.some(
      (field) => typeof record[field] !== "string" || record[field].length === 0,
    )
    || !Number.isSafeInteger(record.pairedAt)
    || !Array.isArray(record.grantedScopes)
    || !record.grantedScopes.every((scope) => typeof scope === "string")
    || !Buffer.isBuffer(record.phonePublicKeyDER)
  ) {
    throw new Error("Paired device record is invalid.");
  }
}
