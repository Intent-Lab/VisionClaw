import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import { ConfirmationStore } from "../src/confirmation-store.mjs";

const fixedNow = () => 1_800_000_000_000;
const isolatedWorkspacePath = "/Users/jaack/.visionclaw-broker/codex-worktrees/isolation-1";
const isolatedWorkspaceRevision = "a".repeat(40);
const sourceRevision = Object.freeze({
  id: "019f-source-thread",
  updatedAt: 1_799_999_999,
  status: "idle",
  cwd: "/Users/jaack/project",
  name: "Build the broker",
});

function temporaryDatabase() {
  const directory = mkdtempSync(path.join(tmpdir(), "visionclaw-codex-"));
  return {
    filename: path.join(directory, "broker.sqlite"),
    cleanup: () => rmSync(directory, { force: true, recursive: true }),
  };
}

function makeWorkspaceReady(store, actionID) {
  store.recordWorkspacePlan(actionID, {
    workspacePath: isolatedWorkspacePath,
    gitRevision: isolatedWorkspaceRevision,
  });
  store.markWorkspaceReady(actionID);
}

test("runtime construction requires an explicit SQLite persistence target", () => {
  assert.throws(() => new ConfirmationStore(), /database|persistence/i);
});

test("existing broker databases migrate durable isolated-workspace fields", () => {
  const database = temporaryDatabase();
  try {
    const initial = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    initial.close();
    const legacy = new DatabaseSync(database.filename);
    legacy.exec(`
      ALTER TABLE codex_actions DROP COLUMN isolated_workspace_path;
      ALTER TABLE codex_actions DROP COLUMN isolated_workspace_revision;
      ALTER TABLE codex_actions DROP COLUMN failure_code;
    `);
    legacy.close();

    const migrated = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    const taskReference = migrated.registerTask({
      pairingID: "pair-1",
      sourceRevision,
    });
    const prepared = migrated.prepare({
      pairingID: "pair-1",
      taskReference,
      sourceRevision,
      instruction: "Use the migrated workspace fields.",
      clientRequestID: "request-migrated-workspace",
    });
    migrated.commit({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: prepared.clientRequestID,
    });
    migrated.recordWorkspacePlan(prepared.actionID, {
      workspacePath: isolatedWorkspacePath,
      gitRevision: isolatedWorkspaceRevision,
    });
    assert.equal(
      migrated.inspectAction(prepared.actionID).isolatedWorkspacePath,
      isolatedWorkspacePath,
    );
    migrated.close();
  } finally {
    database.cleanup();
  }
});

test("task references are opaque, HMAC-authenticated, device-bound, and persistent", () => {
  const database = temporaryDatabase();
  try {
    const first = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    const taskReference = first.registerTask({
      pairingID: "pair-1",
      sourceRevision,
    });
    assert.match(taskReference, /^vct1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    assert.doesNotMatch(taskReference, /019f-source-thread/);
    assert.equal(
      first.resolveTask({ pairingID: "pair-1", taskReference }).id,
      sourceRevision.id,
    );
    assert.throws(
      () => first.resolveTask({ pairingID: "pair-2", taskReference }),
      /not found|invalid/i,
    );
    first.close();

    const reopened = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    assert.deepEqual(
      reopened.resolveTask({ pairingID: "pair-1", taskReference }),
      sourceRevision,
    );
    reopened.close();
  } finally {
    database.cleanup();
  }
});

test("prepared continuation persists the exact source revision and instruction hash", () => {
  const store = new ConfirmationStore({ databasePath: ":memory:", now: fixedNow });
  const taskReference = store.registerTask({
    pairingID: "pair-1",
    sourceRevision,
  });
  const prepared = store.prepare({
    pairingID: "pair-1",
    taskReference,
    sourceRevision,
    instruction: "Continue the implementation and run tests.",
    clientRequestID: "request-1",
    ttlMilliseconds: 60_000,
  });

  assert.equal(prepared.taskReference, taskReference);
  assert.match(prepared.actionID, /^[A-Za-z0-9_-]{20,}$/);
  assert.match(prepared.confirmationNonce, /^[A-Za-z0-9_-]{20,}$/);
  assert.match(prepared.actionID, /^[A-Za-z0-9]/);
  assert.match(prepared.confirmationNonce, /^[A-Za-z0-9]/);
  assert.doesNotMatch(JSON.stringify(prepared), /Continue the implementation/);

  const persisted = store.inspectAction(prepared.actionID);
  assert.deepEqual(persisted.sourceRevision, sourceRevision);
  assert.equal(persisted.pairingID, "pair-1");
  assert.equal(persisted.clientRequestID, "request-1");
  assert.match(persisted.instructionHash, /^[a-f0-9]{64}$/);

  assert.throws(
    () => store.commit({
      pairingID: "pair-2",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: "request-1",
    }),
    /device|pairing/i,
  );
  store.close();
});

test("fork progress and the final receipt survive a broker restart", () => {
  const database = temporaryDatabase();
  try {
    const first = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    const taskReference = first.registerTask({
      pairingID: "pair-1",
      sourceRevision,
    });
    const prepared = first.prepare({
      pairingID: "pair-1",
      taskReference,
      sourceRevision,
      instruction: "Continue once.",
      clientRequestID: "request-2",
    });
    const committed = first.commit({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: "request-2",
    });
    assert.equal(committed.stage, "isolate-workspace");
    makeWorkspaceReady(first, prepared.actionID);
    first.markForkDispatching(prepared.actionID);
    first.recordFork(prepared.actionID, {
      forkThreadID: "019f-fork-thread",
      forkTaskReference: first.registerTask({
        pairingID: "pair-1",
        sourceRevision: {
          ...sourceRevision,
          id: "019f-fork-thread",
          status: "active",
          cwd: isolatedWorkspacePath,
        },
      }),
    });
    first.markTurnStarting(prepared.actionID);
    first.close();

    const reopened = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    const recovered = reopened.commit({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: "request-2",
    });
    assert.equal(recovered.stage, "reconcile-turn");
    assert.equal(recovered.forkThreadID, "019f-fork-thread");
    assert.equal(recovered.isolatedWorkspacePath, isolatedWorkspacePath);
    assert.equal(
      recovered.isolatedWorkspaceRevision,
      isolatedWorkspaceRevision,
    );

    const receipt = {
      forkedTaskReference: recovered.forkTaskReference,
      turnReference: "turn-1",
      status: "inProgress",
      acceptedAt: fixedNow(),
    };
    reopened.recordReceipt(prepared.actionID, receipt);
    assert.deepEqual(
      reopened.commit({
        pairingID: "pair-1",
        actionID: prepared.actionID,
        confirmationNonce: prepared.confirmationNonce,
        clientRequestID: "request-2",
      }),
      { duplicate: true, receipt },
    );
    reopened.close();
  } finally {
    database.cleanup();
  }
});

test("an unknown fork-dispatch outcome becomes an explicit recovery state", () => {
  const database = temporaryDatabase();
  try {
    const first = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    const taskReference = first.registerTask({
      pairingID: "pair-1",
      sourceRevision,
    });
    const prepared = first.prepare({
      pairingID: "pair-1",
      taskReference,
      sourceRevision,
      instruction: "Dispatch one fork.",
      clientRequestID: "request-fork-crash",
    });
    first.commit({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: "request-fork-crash",
    });
    makeWorkspaceReady(first, prepared.actionID);
    first.markForkDispatching(prepared.actionID);
    first.close();

    const reopened = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    const recovered = reopened.commit({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: "request-fork-crash",
    });
    assert.equal(recovered.stage, "fork-recovery-required");
    assert.equal(
      reopened.inspectAction(prepared.actionID).state,
      "fork-recovery-required",
    );
    reopened.close();
  } finally {
    database.cleanup();
  }
});

test("prepare replay returns the same bound confirmation after restart", () => {
  const database = temporaryDatabase();
  try {
    const first = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    const taskReference = first.registerTask({
      pairingID: "pair-1",
      sourceRevision,
    });
    const arguments_ = {
      pairingID: "pair-1",
      taskReference,
      sourceRevision,
      instruction: "Continue exactly once.",
      clientRequestID: "request-replayed-prepare",
    };
    const prepared = first.prepare(arguments_);
    first.close();

    const reopened = new ConfirmationStore({
      databasePath: database.filename,
      now: fixedNow,
    });
    assert.deepEqual(reopened.prepare(arguments_), prepared);
    assert.throws(
      () => reopened.prepare({
        ...arguments_,
        instruction: "A different instruction.",
      }),
      /already used|does not match/i,
    );
    reopened.close();
  } finally {
    database.cleanup();
  }
});

test("expired and cancelled prepared actions cannot be committed", () => {
  const store = new ConfirmationStore({ databasePath: ":memory:", now: fixedNow });
  const taskReference = store.registerTask({
    pairingID: "pair-1",
    sourceRevision,
  });
  const expiring = store.prepare({
    pairingID: "pair-1",
    taskReference,
    sourceRevision,
    instruction: "Do A",
    clientRequestID: "request-a",
    ttlMilliseconds: 1,
  });
  assert.throws(
    () => store.commit({
      pairingID: "pair-1",
      actionID: expiring.actionID,
      confirmationNonce: expiring.confirmationNonce,
      clientRequestID: "request-a",
      now: fixedNow() + 2,
    }),
    /expired/i,
  );
  assert.equal(store.inspectAction(expiring.actionID).state, "expired");

  const cancelled = store.prepare({
    pairingID: "pair-1",
    taskReference,
    sourceRevision,
    instruction: "Do B",
    clientRequestID: "request-b",
  });
  assert.deepEqual(
    store.requestCancel({
      pairingID: "pair-1",
      actionID: cancelled.actionID,
      clientRequestID: "request-b",
    }),
    { cancelled: true, needsInterrupt: false },
  );
  assert.throws(
    () => store.commit({
      pairingID: "pair-1",
      actionID: cancelled.actionID,
      confirmationNonce: cancelled.confirmationNonce,
      clientRequestID: "request-b",
    }),
    /cancelled/i,
  );
  store.close();
});
