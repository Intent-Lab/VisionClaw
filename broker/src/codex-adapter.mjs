import path from "node:path";

import { redactSecrets } from "./security.mjs";
import { validateSourceRevision } from "./sqlite-store.mjs";

export class CodexTaskAdapter {
  #client;
  #confirmations;
  #workspaceManager;
  #redact;
  #now;
  #inFlightCommits = new Map();
  #pendingTurnStatuses = new Map();

  constructor({
    client,
    confirmationStore,
    workspaceManager,
    now = Date.now,
    redactor = redactSecrets,
  }) {
    if (!client || !confirmationStore || !workspaceManager) {
      throw new Error(
        "Codex client, confirmation store, and workspace manager are required.",
      );
    }
    this.#client = client;
    this.#confirmations = confirmationStore;
    this.#workspaceManager = workspaceManager;
    this.#now = now;
    const redact = typeof redactor === "function"
      ? redactor
      : redactor?.redact?.bind(redactor);
    if (typeof redact !== "function") {
      throw new Error("A broker output redactor is required.");
    }
    this.#redact = redact;
    this.#client.on?.("notification", ({ method, params }) => {
      if (!["turn/started", "turn/completed"].includes(method)) return;
      const turn = params?.turn ?? params;
      if (!turn?.id) return;
      const updated = this.#confirmations.updateTurnStatus({
        turnID: turn.id,
        status: normalizeStatus(turn.status),
      });
      if (updated === 0) {
        this.#pendingTurnStatuses.set(
          turn.id,
          normalizeStatus(turn.status),
        );
        if (this.#pendingTurnStatuses.size > 128) {
          this.#pendingTurnStatuses.delete(
            this.#pendingTurnStatuses.keys().next().value,
          );
        }
      }
    });
  }

  async list({ pairingID, limit = 10 } = {}) {
    requirePairingID(pairingID);
    const safeLimit = Math.min(Math.max(Number(limit) || 10, 1), 20);
    const result = await this.#client.request("thread/list", {
      archived: false,
      limit: safeLimit,
      modelProviders: [],
      sortDirection: "desc",
      sortKey: "recency_at",
      sourceKinds: ["cli", "vscode"],
    });
    return {
      tasks: (result.data ?? []).map((thread) => {
        const revision = sourceRevisionFromThread(thread);
        const taskReference = this.#confirmations.registerTask({
          pairingID,
          sourceRevision: revision,
        });
        return safeTaskSummary(thread, taskReference, this.#redact);
      }),
    };
  }

  async read({ pairingID, taskReference }) {
    requirePairingID(pairingID);
    const storedRevision = this.#confirmations.resolveTask({
      pairingID,
      taskReference,
    });
    const result = await this.#client.request("thread/read", {
      includeTurns: false,
      threadId: storedRevision.id,
    });
    const thread = result.thread;
    if (!thread || thread.id !== storedRevision.id) {
      throw new Error("Codex task was not found.");
    }
    const revision = sourceRevisionFromThread(thread);
    const stableReference = this.#confirmations.registerTask({
      pairingID,
      sourceRevision: revision,
    });
    return safeTaskSummary(thread, stableReference, this.#redact);
  }

  async status({ pairingID, taskReference }) {
    return this.read({ pairingID, taskReference });
  }

  async prepareContinue({
    pairingID,
    taskReference,
    instruction,
    clientRequestID,
  }) {
    requirePairingID(pairingID);
    const storedRevision = this.#confirmations.resolveTask({
      pairingID,
      taskReference,
    });
    const result = await this.#client.request("thread/read", {
      includeTurns: false,
      threadId: storedRevision.id,
    });
    if (!result.thread || result.thread.id !== storedRevision.id) {
      throw new Error("Codex task was not found.");
    }
    const sourceRevision = sourceRevisionFromThread(result.thread);
    requireIdleSource(sourceRevision);
    const stableReference = this.#confirmations.registerTask({
      pairingID,
      sourceRevision,
    });
    const prepared = this.#confirmations.prepare({
      pairingID,
      taskReference: stableReference,
      sourceRevision,
      instruction,
      clientRequestID,
    });
    const summary = safeTaskSummary(
      result.thread,
      stableReference,
      this.#redact,
    );
    return {
      ...prepared,
      taskTitle: summary.title,
      workspace: summary.workspace,
    };
  }

  commitContinue(arguments_) {
    const actionID = String(arguments_?.actionID ?? "");
    const existing = this.#inFlightCommits.get(actionID);
    if (existing) return existing;
    const operation = this.#performCommit(arguments_)
      .finally(() => {
        if (this.#inFlightCommits.get(actionID) === operation) {
          this.#inFlightCommits.delete(actionID);
        }
      });
    this.#inFlightCommits.set(actionID, operation);
    return operation;
  }

  async cancelContinue({ pairingID, actionID, clientRequestID }) {
    const inFlight = this.#inFlightCommits.get(String(actionID ?? ""));
    if (inFlight) {
      try {
        await inFlight;
      } catch {
        // Reconcile the durable state below even when turn/start failed.
      }
    }
    const cancellation = this.#confirmations.requestCancel({
      pairingID,
      actionID,
      clientRequestID,
    });
    if (cancellation.needsReconciliation) {
      const recovered = await this.#findTurnByClientRequest({
        forkThreadID: cancellation.forkThreadID,
        clientRequestID: cancellation.clientRequestID,
        attempts: 3,
      });
      if (!recovered) {
        this.#confirmations.markTurnRecoveryRequired(actionID);
        return { cancelled: false, status: "reconciliationRequired" };
      }
      this.#confirmations.recordRecoveredTurn(actionID, {
        turnID: recovered.id,
        status: normalizeStatus(recovered.status),
      });
      await this.#client.request("turn/interrupt", {
        threadId: cancellation.forkThreadID,
        turnId: recovered.id,
      });
      this.#confirmations.recordInterrupted(actionID);
      return { cancelled: true, status: "cancelled" };
    }
    if (cancellation.recoveryRequired) {
      return { cancelled: false, status: "reconciliationRequired" };
    }
    if (cancellation.needsInterrupt) {
      await this.#client.request("turn/interrupt", {
        threadId: cancellation.forkThreadID,
        turnId: cancellation.turnID,
      });
      this.#confirmations.recordInterrupted(actionID);
      return { cancelled: true, status: "cancelled" };
    }
    return {
      cancelled: cancellation.cancelled,
      status: cancellation.cancelled ? "cancelled" : "unchanged",
    };
  }

  cancelPrepared(arguments_) {
    return this.cancelContinue(arguments_);
  }

  operationStatus({ pairingID, actionID, clientRequestID }) {
    return this.#confirmations.operationStatus({
      pairingID,
      actionID,
      clientRequestID,
    });
  }

  async #performCommit({
    pairingID,
    actionID,
    confirmationNonce,
    clientRequestID,
  }) {
    let action = this.#confirmations.commit({
      pairingID,
      actionID,
      confirmationNonce,
      clientRequestID,
    });
    if (action.duplicate) return action.receipt;
    if (action.stage === "fork-recovery-required") {
      throw new Error(
        "Codex fork outcome requires reconciliation; no second fork was sent.",
      );
    }

    if (action.stage === "isolate-workspace") {
      await this.#recheckSource(action, {
        activeFailureCode: "source-active",
        staleBeforeFork: true,
      });
      try {
        const workspace = await this.#workspaceManager.plan({
          actionID: action.actionID,
          sourceCwd: action.sourceRevision.cwd,
        });
        if (
          path.resolve(workspace.workspacePath)
          === path.resolve(action.sourceRevision.cwd)
        ) {
          throw new Error("Isolated workspace matches the source workspace.");
        }
        action = this.#confirmations.recordWorkspacePlan(
          action.actionID,
          workspace,
        );
      } catch {
        this.#markFailed(action.actionID, "workspace-isolation-failed");
        throw new Error(
          "Could not create a safe isolated Codex workspace; no task was started.",
        );
      }
    }

    if (action.stage === "ensure-workspace") {
      try {
        await this.#workspaceManager.ensure(workspaceArguments(action));
        action = this.#confirmations.markWorkspaceReady(action.actionID);
      } catch {
        this.#markFailed(action.actionID, "workspace-isolation-failed");
        throw new Error(
          "Could not create a safe isolated Codex workspace; no task was started.",
        );
      }
    }

    if (action.stage === "fork") {
      await this.#verifyWorkspace(action);
      await this.#recheckSource(action, {
        activeFailureCode: "source-active",
        staleBeforeFork: true,
      });
      this.#confirmations.markForkDispatching(actionID);
      const fork = await this.#client.request("thread/fork", {
        threadId: action.sourceRevision.id,
        threadSource: "user",
      });
      const forkedThreadID = String(fork.thread?.id ?? "");
      if (!forkedThreadID || forkedThreadID === action.sourceRevision.id) {
        throw new Error("Codex did not create a distinct forked task.");
      }
      const forkRevision = sourceRevisionFromFork(
        fork.thread,
        action.sourceRevision,
        this.#now(),
        action.isolatedWorkspacePath,
      );
      const forkTaskReference = this.#confirmations.registerTask({
        pairingID,
        sourceRevision: forkRevision,
      });
      action = this.#confirmations.recordFork(actionID, {
        forkThreadID: forkedThreadID,
        forkTaskReference,
      });
    }

    if (action.stage === "start-turn") {
      if (!action.isolatedWorkspacePath || !action.isolatedWorkspaceRevision) {
        this.#markFailed(action.actionID, "workspace-validation-failed");
        throw new Error(
          "Could not validate the isolated Codex workspace; no task was started.",
        );
      }
      await this.#verifyWorkspace(action);
      await this.#recheckSource(action, {
        activeFailureCode: "source-active-before-dispatch",
        changedFailureCode: "source-changed-before-dispatch",
      });
      action = this.#confirmations.markTurnStarting(actionID);
      action = { ...action, stage: "send-turn" };
    }

    if (action.stage === "reconcile-turn") {
      const recovered = await this.#findTurnByClientRequest({
        forkThreadID: action.forkThreadID,
        clientRequestID: action.clientRequestID,
        attempts: 3,
      });
      if (recovered) {
        return this.#recordReceipt(action, recovered);
      }
      this.#confirmations.markTurnRecoveryRequired(actionID);
      throw new Error(
        "Codex turn outcome is still reconciling; no second turn was sent.",
      );
    }

    const turn = await this.#client.request("turn/start", {
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      clientUserMessageId: action.clientRequestID,
      cwd: action.isolatedWorkspacePath,
      input: [{
        type: "text",
        text: action.instruction,
        text_elements: [],
      }],
      personality: "none",
      sandboxPolicy: {
        type: "workspaceWrite",
        writableRoots: [action.isolatedWorkspacePath],
        networkAccess: false,
        excludeSlashTmp: false,
        excludeTmpdirEnvVar: false,
      },
      threadId: action.forkThreadID,
    });
    if (!turn.turn?.id) {
      throw new Error("Codex did not return a turn receipt.");
    }
    return this.#recordReceipt(action, turn.turn);
  }

  async #recheckSource(
    action,
    {
      activeFailureCode,
      changedFailureCode = null,
      staleBeforeFork = false,
    },
  ) {
    let currentRevision;
    try {
      const currentResult = await this.#client.request("thread/read", {
        includeTurns: false,
        threadId: action.sourceRevision.id,
      });
      currentRevision = sourceRevisionFromThread(currentResult.thread);
    } catch {
      if (staleBeforeFork) {
        this.#confirmations.markStale(action.actionID);
      } else if (changedFailureCode) {
        this.#markFailed(action.actionID, changedFailureCode);
      }
      throw new Error("Codex task changed; prepare the action again.");
    }
    try {
      requireIdleSource(currentRevision);
    } catch {
      this.#markFailed(action.actionID, activeFailureCode);
      throw new Error(
        "The source Codex task is active or not idle; wait for it to finish and prepare again.",
      );
    }
    if (!sameRevision(action.sourceRevision, currentRevision)) {
      if (staleBeforeFork) {
        this.#confirmations.markStale(action.actionID);
      } else if (changedFailureCode) {
        this.#markFailed(action.actionID, changedFailureCode);
      }
      throw new Error("Codex task changed; prepare the action again.");
    }
    return currentRevision;
  }

  async #verifyWorkspace(action) {
    try {
      await this.#workspaceManager.verify(workspaceArguments(action));
    } catch {
      this.#markFailed(action.actionID, "workspace-validation-failed");
      throw new Error(
        "Could not validate the isolated Codex workspace; no task was started.",
      );
    }
  }

  #markFailed(actionID, failureCode) {
    this.#confirmations.markFailed(actionID, failureCode);
  }

  async #findTurnByClientRequest({
    forkThreadID,
    clientRequestID,
    attempts = 1,
  }) {
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      const result = await this.#client.request("thread/read", {
        includeTurns: true,
        threadId: forkThreadID,
      });
      for (const turn of result.thread?.turns ?? []) {
        const matched = (turn.items ?? []).some(
          (item) => item.type === "userMessage"
            && item.clientId === clientRequestID,
        );
        if (matched) return turn;
      }
      if (attempt + 1 < attempts) {
        await delay(50);
      }
    }
    return null;
  }

  #recordReceipt(action, turn) {
    const receipt = {
      forkedTaskReference: action.forkTaskReference,
      turnReference: turn.id,
      status: normalizeStatus(turn.status ?? "started"),
      acceptedAt: this.#now(),
    };
    let stored = this.#confirmations.recordReceipt(action.actionID, receipt);
    const pendingStatus = this.#pendingTurnStatuses.get(turn.id);
    if (pendingStatus) {
      this.#pendingTurnStatuses.delete(turn.id);
      this.#confirmations.updateTurnStatus({
        turnID: turn.id,
        status: pendingStatus,
      });
      stored = this.#confirmations.operationStatus({
        pairingID: action.pairingID,
        actionID: action.actionID,
        clientRequestID: action.clientRequestID,
      }).receipt;
    }
    return stored;
  }
}

function sourceRevisionFromThread(thread) {
  if (!thread || typeof thread !== "object") {
    throw new Error("Codex task was not found.");
  }
  return validateSourceRevision({
    id: thread.id,
    updatedAt: thread.updatedAt,
    status: normalizeStatus(thread.status),
    cwd: thread.cwd,
    name: thread.name ?? "Untitled Codex task",
  });
}

function sourceRevisionFromFork(
  thread,
  sourceRevision,
  now,
  isolatedWorkspacePath,
) {
  return validateSourceRevision({
    id: thread?.id,
    updatedAt: Number.isSafeInteger(thread?.updatedAt)
      ? thread.updatedAt
      : Math.floor(now / 1_000),
    status: normalizeStatus(thread?.status ?? "idle"),
    cwd: isolatedWorkspacePath,
    name: thread?.name ?? sourceRevision.name,
  });
}

function safeTaskSummary(thread, taskReference, redact) {
  const rawID = String(thread.id ?? "");
  const title = boundedText(thread.name ?? "", 160)
    || "Untitled Codex task";
  const workspace = thread.cwd
    ? boundedText(path.basename(thread.cwd), 160)
    : "";
  return {
    taskReference,
    title: redact(redactRawID(
      title,
      rawID,
    )),
    status: normalizeStatus(thread.status),
    updatedAt: thread.updatedAt ?? null,
    workspace: workspace
      ? redact(redactRawID(workspace, rawID))
      : null,
    preview: redact(
      redactRawID(boundedText(thread.preview ?? "", 600), rawID),
    ),
  };
}

function normalizeStatus(status) {
  if (typeof status === "string") return status;
  if (status && typeof status.type === "string") return status.type;
  return "unknown";
}

function requireIdleSource(sourceRevision) {
  const status = String(sourceRevision?.status ?? "")
    .replace(/[^A-Za-z]/g, "")
    .toLowerCase();
  if (status !== "idle") {
    throw new Error(
      "The source Codex task is active or not idle; wait for it to finish.",
    );
  }
}

function sameRevision(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function boundedText(value, maximum) {
  const text = String(value).replace(/\s+/g, " ").trim();
  return text.length <= maximum
    ? text
    : `${text.slice(0, maximum - 1)}…`;
}

function redactRawID(value, rawID) {
  return rawID ? value.replaceAll(rawID, "<task>") : value;
}

function requirePairingID(pairingID) {
  if (
    typeof pairingID !== "string"
    || !/^[A-Za-z0-9][A-Za-z0-9._:-]{2,255}$/.test(pairingID)
  ) {
    throw new Error("A paired device is required.");
  }
}

function workspaceArguments(action) {
  if (
    !action?.isolatedWorkspacePath
    || !action?.isolatedWorkspaceRevision
  ) {
    throw new Error("Codex isolated workspace binding is missing.");
  }
  return {
    sourceCwd: action.sourceRevision.cwd,
    workspacePath: action.isolatedWorkspacePath,
    gitRevision: action.isolatedWorkspaceRevision,
  };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
