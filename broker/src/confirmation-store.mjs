import {
  createHash,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import path from "node:path";

import {
  SQLiteBrokerStore,
  validateSourceRevision,
} from "./sqlite-store.mjs";

export class ConfirmationStore {
  #store;
  #now;

  constructor({
    databasePath,
    database,
    handleSecret,
    now = Date.now,
  } = {}) {
    if (!database && !databasePath) {
      throw new Error(
        "An explicit SQLite database path is required for Codex persistence.",
      );
    }
    this.#store = new SQLiteBrokerStore({
      databasePath,
      database,
      handleSecret,
    });
    this.#now = now;
  }

  close() {
    this.#store.close();
  }

  registerTask({ pairingID, sourceRevision }) {
    return this.#store.registerTask({ pairingID, sourceRevision });
  }

  resolveTask({ pairingID, taskReference }) {
    return this.#store.resolveTask({ pairingID, taskReference });
  }

  prepare({
    pairingID,
    taskReference,
    sourceRevision,
    instruction,
    clientRequestID,
    ttlMilliseconds = 60_000,
  }) {
    const cleanInstruction = String(instruction ?? "").trim();
    const requestID = requireValue(clientRequestID, "request ID");
    const pairing = requireValue(pairingID, "paired device");
    if (!cleanInstruction) {
      throw new Error("Prepared continuation instruction is missing.");
    }
    if (cleanInstruction.length > 4_000) {
      throw new Error("Codex continuation instruction is too long.");
    }
    if (
      !Number.isSafeInteger(ttlMilliseconds)
      || ttlMilliseconds < 1
      || ttlMilliseconds > 5 * 60_000
    ) {
      throw new Error("Prepared continuation lifetime is invalid.");
    }
    const revision = validateSourceRevision(sourceRevision);
    const resolved = this.resolveTask({
      pairingID: pairing,
      taskReference,
    });
    if (!sameRevision(revision, resolved)) {
      throw new Error("Codex task changed before it could be prepared.");
    }

    const instructionHash = sha256(cleanInstruction);
    const revisionJSON = JSON.stringify(revision);
    return this.#store.transaction(() => {
      const existing = this.#store.get(
        `SELECT *
           FROM codex_actions
          WHERE pairing_id = ? AND client_request_id = ?`,
        pairing,
        requestID,
      );
      if (existing) {
        if (
          existing.task_reference !== taskReference
          || existing.source_revision_json !== revisionJSON
          || existing.instruction_hash !== instructionHash
          || existing.instruction !== cleanInstruction
        ) {
          throw new Error(
            "Prepared action request ID was already used and does not match.",
          );
        }
        const confirmationNonce = this.#store.deriveConfirmationNonce({
          pairingID: pairing,
          actionID: existing.action_id,
          clientRequestID: requestID,
        });
        if (
          existing.confirmation_nonce_hash
          !== hashNonce(existing.action_id, confirmationNonce)
        ) {
          throw new Error("Persisted confirmation binding is invalid.");
        }
        return preparedResponse(existing, confirmationNonce);
      }

      const actionID = `vca_${randomBytes(18).toString("base64url")}`;
      const confirmationNonce = this.#store.deriveConfirmationNonce({
        pairingID: pairing,
        actionID,
        clientRequestID: requestID,
      });
      const now = this.#now();
      const expiresAt = now + ttlMilliseconds;
      this.#store.run(
        `INSERT INTO codex_actions (
           action_id, pairing_id, task_reference, source_thread_id,
           source_revision_json, instruction, instruction_hash,
           client_request_id, confirmation_nonce_hash, expires_at,
           state, created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        actionID,
        pairing,
        taskReference,
        revision.id,
        revisionJSON,
        cleanInstruction,
        instructionHash,
        requestID,
        hashNonce(actionID, confirmationNonce),
        expiresAt,
        "prepared",
        now,
        now,
      );
      return {
        actionID,
        confirmationNonce,
        taskReference,
        clientRequestID: requestID,
        expiresAt,
      };
    });
  }

  commit({
    pairingID,
    actionID,
    confirmationNonce,
    clientRequestID,
    now = this.#now(),
  }) {
    const result = this.#store.transaction(() => {
      const action = this.#requireAuthorizedAction({
        pairingID,
        actionID,
        confirmationNonce,
        clientRequestID,
      });
      if (action.state === "completed") {
        return {
          duplicate: true,
          receipt: parseReceipt(action.receipt_json),
        };
      }
      if (action.state === "cancelled") {
        throw new Error("Prepared action was cancelled.");
      }
      if (action.state === "stale") {
        throw new Error("Codex task changed; prepare the action again.");
      }
      if (action.state === "expired") {
        throw new Error("Prepared action expired.");
      }
      if (action.state === "failed") {
        throw new Error(failureMessage(action.failure_code));
      }
      if (
        action.expires_at <= now
        && ["prepared", "validating"].includes(action.state)
      ) {
        this.#store.run(
          `UPDATE codex_actions
              SET state = 'expired', updated_at = ?
            WHERE action_id = ?`,
          now,
          action.action_id,
        );
        return { failure: "expired" };
      }
      if (action.state === "prepared") {
        this.#store.run(
          `UPDATE codex_actions
              SET state = 'validating', updated_at = ?
            WHERE action_id = ? AND state = 'prepared'`,
          now,
          action.action_id,
        );
        return actionResult(action, "isolate-workspace");
      }
      if (action.state === "validating") {
        return actionResult(action, "isolate-workspace");
      }
      if (action.state === "workspace-provisioning") {
        return actionResult(action, "ensure-workspace");
      }
      if (action.state === "workspace-ready") {
        return actionResult(action, "fork");
      }
      if (["committing", "fork-dispatching"].includes(action.state)) {
        this.#store.run(
          `UPDATE codex_actions
              SET state = 'fork-recovery-required', updated_at = ?
            WHERE action_id = ?`,
          now,
          action.action_id,
        );
        return actionResult(
          this.#require(action.action_id),
          "fork-recovery-required",
        );
      }
      if (action.state === "fork-recovery-required") {
        return actionResult(action, "fork-recovery-required");
      }
      if (action.state === "forked") {
        return actionResult(action, "start-turn");
      }
      if (
        action.state === "turn-starting"
        || action.state === "turn-recovery-required"
      ) {
        return actionResult(action, "reconcile-turn");
      }
      throw new Error(`Prepared action is ${action.state}.`);
    });
    if (result?.failure === "expired") {
      throw new Error("Prepared action expired.");
    }
    return result;
  }

  recordWorkspacePlan(actionID, { workspacePath, gitRevision }) {
    const action = this.#require(actionID);
    const isolatedPath = validateWorkspacePath(workspacePath);
    const revision = validateGitRevision(gitRevision);
    if (action.isolated_workspace_path) {
      if (
        action.isolated_workspace_path !== isolatedPath
        || action.isolated_workspace_revision !== revision
      ) {
        throw new Error(
          "Prepared action is already bound to another isolated workspace.",
        );
      }
      if (!["workspace-provisioning", "workspace-ready"].includes(action.state)) {
        throw new Error("Prepared action cannot reprovision its workspace.");
      }
      return actionResult(
        action,
        action.state === "workspace-ready" ? "fork" : "ensure-workspace",
      );
    }
    if (action.state !== "validating") {
      throw new Error("Codex workspace is not ready to be planned.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'workspace-provisioning',
              isolated_workspace_path = ?,
              isolated_workspace_revision = ?,
              updated_at = ?
        WHERE action_id = ? AND state = 'validating'`,
      isolatedPath,
      revision,
      this.#now(),
      action.action_id,
    );
    return actionResult(this.#require(actionID), "ensure-workspace");
  }

  markWorkspaceReady(actionID) {
    const action = this.#require(actionID);
    if (action.state === "workspace-ready") {
      return actionResult(action, "fork");
    }
    if (
      action.state !== "workspace-provisioning"
      || !action.isolated_workspace_path
      || !action.isolated_workspace_revision
    ) {
      throw new Error("An isolated Codex workspace must be durable first.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'workspace-ready', updated_at = ?
        WHERE action_id = ? AND state = 'workspace-provisioning'`,
      this.#now(),
      action.action_id,
    );
    return actionResult(this.#require(actionID), "fork");
  }

  markForkDispatching(actionID) {
    const action = this.#require(actionID);
    if (action.state === "fork-dispatching") {
      return actionResult(action, "fork-recovery-required");
    }
    if (
      action.state !== "workspace-ready"
      || !action.isolated_workspace_path
      || !action.isolated_workspace_revision
    ) {
      throw new Error("Codex fork is not ready to dispatch.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'fork-dispatching', updated_at = ?
        WHERE action_id = ? AND state = 'workspace-ready'`,
      this.#now(),
      action.action_id,
    );
    return actionResult(this.#require(actionID), "fork-dispatching");
  }

  recordFork(actionID, { forkThreadID, forkTaskReference }) {
    const action = this.#require(actionID);
    const threadID = requireValue(forkThreadID, "forked Codex task");
    const taskReference = requireValue(
      forkTaskReference,
      "forked task reference",
    );
    if (action.fork_thread_id) {
      if (
        action.fork_thread_id !== threadID
        || action.fork_task_reference !== taskReference
      ) {
        throw new Error("Prepared action is already bound to another fork.");
      }
      return actionResult(action, action.state === "turn-starting"
        ? "reconcile-turn"
        : "start-turn");
    }
    if (
      action.state !== "fork-dispatching"
      || !action.isolated_workspace_path
      || !action.isolated_workspace_revision
    ) {
      throw new Error("Only a dispatched action can record a fork.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'forked',
              fork_thread_id = ?,
              fork_task_reference = ?,
              updated_at = ?
        WHERE action_id = ? AND state = 'fork-dispatching'`,
      threadID,
      taskReference,
      this.#now(),
      action.action_id,
    );
    return actionResult(this.#require(actionID), "start-turn");
  }

  markTurnStarting(actionID) {
    const action = this.#require(actionID);
    if (action.state === "turn-starting") return actionResult(action, "reconcile-turn");
    if (
      action.state !== "forked"
      || !action.fork_thread_id
      || !action.isolated_workspace_path
      || !action.isolated_workspace_revision
    ) {
      throw new Error("A durable fork is required before starting a turn.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'turn-starting', updated_at = ?
        WHERE action_id = ? AND state = 'forked'`,
      this.#now(),
      action.action_id,
    );
    return actionResult(this.#require(actionID), "reconcile-turn");
  }

  markTurnRecoveryRequired(actionID) {
    const action = this.#require(actionID);
    if (action.state === "turn-recovery-required") return;
    if (action.state !== "turn-starting") {
      throw new Error("Codex turn is not awaiting recovery.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'turn-recovery-required', updated_at = ?
        WHERE action_id = ? AND state = 'turn-starting'`,
      this.#now(),
      action.action_id,
    );
  }

  recordReceipt(actionID, receipt) {
    const action = this.#require(actionID);
    if (![
      "forked",
      "turn-starting",
      "turn-recovery-required",
      "completed",
    ].includes(action.state)) {
      throw new Error("Only a forked action can receive a receipt.");
    }
    const safeReceipt = validateReceipt(receipt, action);
    if (action.state === "completed") {
      const existing = parseReceipt(action.receipt_json);
      if (JSON.stringify(existing) !== JSON.stringify(safeReceipt)) {
        throw new Error("Prepared action already has another receipt.");
      }
      return existing;
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'completed',
              turn_id = ?,
              turn_status = ?,
              receipt_json = ?,
              accepted_at = ?,
              updated_at = ?
        WHERE action_id = ?`,
      safeReceipt.turnReference,
      safeReceipt.status,
      JSON.stringify(safeReceipt),
      safeReceipt.acceptedAt,
      this.#now(),
      action.action_id,
    );
    return Object.freeze(safeReceipt);
  }

  requestCancel({ pairingID, actionID, clientRequestID }) {
    return this.#store.transaction(() => {
      const action = this.#requireIdentity({
        pairingID,
        actionID,
        clientRequestID,
      });
      if (action.state === "cancelled") {
        return { cancelled: true, needsInterrupt: false };
      }
      if ([
        "prepared",
        "validating",
        "workspace-provisioning",
        "workspace-ready",
        "forked",
        "stale",
        "expired",
      ].includes(action.state)) {
        this.#store.run(
          `UPDATE codex_actions
              SET state = 'cancelled', updated_at = ?
            WHERE action_id = ?`,
          this.#now(),
          action.action_id,
        );
        return { cancelled: true, needsInterrupt: false };
      }
      if (
        ["turn-starting", "turn-recovery-required"].includes(action.state)
        && !action.turn_id
      ) {
        return {
          cancelled: false,
          needsInterrupt: false,
          needsReconciliation: true,
          forkThreadID: action.fork_thread_id,
          clientRequestID: action.client_request_id,
        };
      }
      if (action.fork_thread_id && action.turn_id) {
        if (isTerminalTurnStatus(action.turn_status)) {
          return { cancelled: false, needsInterrupt: false };
        }
        return {
          cancelled: false,
          needsInterrupt: true,
          forkThreadID: action.fork_thread_id,
          turnID: action.turn_id,
        };
      }
      if ([
        "committing",
        "fork-dispatching",
        "fork-recovery-required",
      ].includes(action.state)) {
        return {
          cancelled: false,
          needsInterrupt: false,
          recoveryRequired: true,
        };
      }
      return { cancelled: false, needsInterrupt: false };
    });
  }

  recordInterrupted(actionID) {
    const action = this.#require(actionID);
    const existing = action.receipt_json
      ? parseReceipt(action.receipt_json)
      : null;
    const receipt = existing
      ? { ...existing, status: "cancelled" }
      : null;
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'cancelled',
              turn_status = 'cancelled',
              receipt_json = ?,
              updated_at = ?
        WHERE action_id = ?`,
      receipt ? JSON.stringify(receipt) : null,
      this.#now(),
      action.action_id,
    );
  }

  recordRecoveredTurn(actionID, { turnID, status }) {
    const action = this.#require(actionID);
    if (
      !action.fork_thread_id
      || !["turn-starting", "turn-recovery-required"].includes(action.state)
    ) {
      throw new Error("Recovered turn does not belong to a pending fork.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET turn_id = ?, turn_status = ?, updated_at = ?
        WHERE action_id = ?`,
      requireValue(turnID, "Codex turn"),
      requireValue(status, "Codex turn status"),
      this.#now(),
      action.action_id,
    );
  }

  markCancelledWithoutTurn(actionID) {
    const action = this.#require(actionID);
    if (action.turn_id) {
      throw new Error("Active Codex turn must be interrupted.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'cancelled', updated_at = ?
        WHERE action_id = ?`,
      this.#now(),
      action.action_id,
    );
  }

  markStale(actionID) {
    const action = this.#require(actionID);
    if (![
      "prepared",
      "validating",
      "workspace-provisioning",
      "workspace-ready",
    ].includes(action.state)) return;
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'stale', updated_at = ?
        WHERE action_id = ?`,
      this.#now(),
      action.action_id,
    );
  }

  markFailed(actionID, failureCode) {
    const action = this.#require(actionID);
    const code = validateFailureCode(failureCode);
    if (action.state === "failed") {
      if (action.failure_code !== code) {
        throw new Error("Prepared action already failed for another reason.");
      }
      return;
    }
    if ([
      "completed",
      "cancelled",
      "turn-starting",
      "turn-recovery-required",
    ].includes(action.state)) {
      throw new Error("Prepared action cannot be marked as failed.");
    }
    this.#store.run(
      `UPDATE codex_actions
          SET state = 'failed', failure_code = ?, updated_at = ?
        WHERE action_id = ?`,
      code,
      this.#now(),
      action.action_id,
    );
  }

  updateTurnStatus({ turnID, status }) {
    const cleanTurnID = requireValue(turnID, "Codex turn");
    const cleanStatus = requireValue(status, "Codex turn status");
    const rows = this.#store.all(
      `SELECT action_id, receipt_json
         FROM codex_actions
        WHERE turn_id = ?`,
      cleanTurnID,
    );
    for (const row of rows) {
      const receipt = parseReceipt(row.receipt_json);
      const updated = { ...receipt, status: cleanStatus };
      this.#store.run(
        `UPDATE codex_actions
            SET turn_status = ?, receipt_json = ?, updated_at = ?
          WHERE action_id = ?`,
        cleanStatus,
        JSON.stringify(updated),
        this.#now(),
        row.action_id,
      );
    }
    return rows.length;
  }

  operationStatus({ pairingID, actionID, clientRequestID }) {
    const action = this.#requireIdentity({
      pairingID,
      actionID,
      clientRequestID,
    });
    return {
      state: action.state,
      failureCode: action.failure_code ?? null,
      receipt: action.receipt_json ? parseReceipt(action.receipt_json) : null,
    };
  }

  inspectAction(actionID) {
    return publicAction(this.#require(actionID));
  }

  #requireAuthorizedAction({
    pairingID,
    actionID,
    confirmationNonce,
    clientRequestID,
  }) {
    const action = this.#requireIdentity({
      pairingID,
      actionID,
      clientRequestID,
    });
    const expected = Buffer.from(action.confirmation_nonce_hash, "hex");
    const actual = Buffer.from(
      hashNonce(action.action_id, String(confirmationNonce ?? "")),
      "hex",
    );
    if (
      expected.length !== actual.length
      || !timingSafeEqual(expected, actual)
    ) {
      throw new Error("Prepared action confirmation nonce does not match.");
    }
    return action;
  }

  #requireIdentity({ pairingID, actionID, clientRequestID }) {
    const action = this.#require(actionID);
    if (action.pairing_id !== pairingID) {
      throw new Error("Prepared action belongs to another paired device.");
    }
    if (action.client_request_id !== clientRequestID) {
      throw new Error("Prepared action request ID does not match.");
    }
    return action;
  }

  #require(actionID) {
    const action = this.#store.get(
      "SELECT * FROM codex_actions WHERE action_id = ?",
      String(actionID ?? ""),
    );
    if (!action) {
      throw new Error("Prepared action was not found.");
    }
    return action;
  }
}

function actionResult(action, stage) {
  validatePersistedAction(action);
  return {
    stage,
    actionID: action.action_id,
    pairingID: action.pairing_id,
    taskReference: action.task_reference,
    sourceRevision: validateSourceRevision(
      JSON.parse(action.source_revision_json),
    ),
    instruction: action.instruction,
    instructionHash: action.instruction_hash,
    clientRequestID: action.client_request_id,
    forkThreadID: action.fork_thread_id ?? null,
    forkTaskReference: action.fork_task_reference ?? null,
    isolatedWorkspacePath: action.isolated_workspace_path ?? null,
    isolatedWorkspaceRevision: action.isolated_workspace_revision ?? null,
  };
}

function publicAction(action) {
  validatePersistedAction(action);
  return {
    actionID: action.action_id,
    pairingID: action.pairing_id,
    taskReference: action.task_reference,
    sourceRevision: validateSourceRevision(
      JSON.parse(action.source_revision_json),
    ),
    instructionHash: action.instruction_hash,
    clientRequestID: action.client_request_id,
    state: action.state,
    failureCode: action.failure_code ?? null,
    forkThreadID: action.fork_thread_id ?? null,
    forkTaskReference: action.fork_task_reference ?? null,
    isolatedWorkspacePath: action.isolated_workspace_path ?? null,
    isolatedWorkspaceRevision: action.isolated_workspace_revision ?? null,
    turnID: action.turn_id ?? null,
    turnStatus: action.turn_status ?? null,
    receipt: action.receipt_json ? parseReceipt(action.receipt_json) : null,
  };
}

function validateReceipt(receipt, action) {
  if (!receipt || typeof receipt !== "object") {
    throw new Error("Codex receipt is missing.");
  }
  if (receipt.forkedTaskReference !== action.fork_task_reference) {
    throw new Error("Codex receipt belongs to another fork.");
  }
  const acceptedAt = Number(receipt.acceptedAt);
  if (!Number.isSafeInteger(acceptedAt) || acceptedAt < 0) {
    throw new Error("Codex receipt timestamp is invalid.");
  }
  return {
    forkedTaskReference: requireValue(
      receipt.forkedTaskReference,
      "forked task reference",
    ),
    turnReference: requireValue(receipt.turnReference, "Codex turn"),
    status: requireValue(receipt.status, "Codex turn status"),
    acceptedAt,
  };
}

function preparedResponse(action, confirmationNonce) {
  return {
    actionID: action.action_id,
    confirmationNonce,
    taskReference: action.task_reference,
    clientRequestID: action.client_request_id,
    expiresAt: action.expires_at,
  };
}

function parseReceipt(value) {
  if (!value) throw new Error("Committed Codex receipt is missing.");
  return Object.freeze(JSON.parse(value));
}

function hashNonce(actionID, nonce) {
  return sha256(`visionclaw-confirmation\0${actionID}\0${nonce}`);
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function sameRevision(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function validatePersistedAction(action) {
  if (sha256(action.instruction) !== action.instruction_hash) {
    throw new Error("Persisted Codex instruction binding is invalid.");
  }
  const revision = validateSourceRevision(
    JSON.parse(action.source_revision_json),
  );
  if (revision.id !== action.source_thread_id) {
    throw new Error("Persisted Codex source binding is invalid.");
  }
  if (
    Boolean(action.isolated_workspace_path)
    !== Boolean(action.isolated_workspace_revision)
  ) {
    throw new Error("Persisted Codex workspace binding is invalid.");
  }
  if (action.isolated_workspace_path) {
    validateWorkspacePath(action.isolated_workspace_path);
    validateGitRevision(action.isolated_workspace_revision);
  }
  if (action.failure_code) validateFailureCode(action.failure_code);
}

function isTerminalTurnStatus(status) {
  return [
    "cancelled",
    "canceled",
    "completed",
    "failed",
    "interrupted",
  ].includes(String(status ?? "").toLowerCase());
}

function requireValue(value, label) {
  const clean = String(value ?? "").trim();
  if (!clean || clean.length > 2_000) {
    throw new Error(`${label} is invalid.`);
  }
  return clean;
}

function validateWorkspacePath(value) {
  const clean = String(value ?? "").trim();
  if (
    !path.isAbsolute(clean)
    || clean.length > 4_096
    || path.normalize(clean) !== clean
  ) {
    throw new Error("Codex isolated workspace path is invalid.");
  }
  return clean;
}

function validateGitRevision(value) {
  const revision = String(value ?? "").toLowerCase();
  if (!/^[0-9a-f]{40,64}$/.test(revision)) {
    throw new Error("Codex isolated workspace revision is invalid.");
  }
  return revision;
}

function validateFailureCode(value) {
  const code = String(value ?? "");
  if (![
    "source-active",
    "source-active-before-dispatch",
    "source-changed-before-dispatch",
    "workspace-isolation-failed",
    "workspace-validation-failed",
  ].includes(code)) {
    throw new Error("Codex failure code is invalid.");
  }
  return code;
}

function failureMessage(code) {
  switch (code) {
  case "source-active":
  case "source-active-before-dispatch":
    return "The source Codex task is active; wait until it is idle and prepare again.";
  case "source-changed-before-dispatch":
    return "The source Codex task changed; prepare the action again.";
  case "workspace-isolation-failed":
  case "workspace-validation-failed":
    return "Could not create a safe isolated Codex workspace; no task was started.";
  default:
    return "The Codex continuation failed closed; prepare the action again.";
  }
}
