import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { CodexTaskAdapter } from "../src/codex-adapter.mjs";
import { ConfirmationStore } from "../src/confirmation-store.mjs";
import { SecretRedactor } from "../src/security.mjs";

const fixedNow = () => 1_800_000_000_000;
const isolatedWorkspacePath = "/Users/jaack/.visionclaw-broker/codex-worktrees/isolation-1";

function sourceThread(overrides = {}) {
  return {
    id: "source-task",
    name: "Build the broker",
    status: { type: "idle" },
    updatedAt: 1_799_999_999,
    cwd: "/Users/jaack/project",
    preview: "Latest safe summary",
    turns: [],
    ...overrides,
  };
}

function fakeClient({ onRequest } = {}) {
  const calls = [];
  const state = { source: sourceThread() };
  const client = Object.assign(new EventEmitter(), {
    calls,
    state,
    async request(method, params) {
      calls.push({ method, params });
      if (onRequest) {
        const override = await onRequest({
          method,
          params,
          calls,
          state,
          client,
        });
        if (override !== undefined) return override;
      }
      switch (method) {
      case "thread/list":
        return { data: [state.source] };
      case "thread/read":
        if (params.threadId === "source-task") {
          return { thread: state.source };
        }
        if (params.threadId === "forked-task") {
          return {
            thread: sourceThread({
              id: "forked-task",
              status: { type: "active" },
              turns: [],
            }),
          };
        }
        throw new Error("thread not found");
      case "thread/fork":
        return {
          thread: sourceThread({
            id: "forked-task",
            status: { type: "idle" },
          }),
        };
      case "turn/start":
        return { turn: { id: "turn-1", status: "inProgress" } };
      case "turn/interrupt":
        return {};
      default:
        throw new Error(`unexpected method ${method}`);
      }
    },
  });
  return client;
}

function fakeWorkspaceManager({
  planResult = {
    workspacePath: isolatedWorkspacePath,
    gitRevision: "a".repeat(40),
  },
  planError = null,
} = {}) {
  const calls = [];
  return {
    calls,
    async plan(arguments_) {
      calls.push({ method: "plan", arguments: arguments_ });
      if (planError) throw planError;
      return planResult;
    },
    async ensure(arguments_) {
      calls.push({ method: "ensure", arguments: arguments_ });
      return arguments_;
    },
    async verify(arguments_) {
      calls.push({ method: "verify", arguments: arguments_ });
      return arguments_;
    },
  };
}

function setup(
  client = fakeClient(),
  {
    workspaceManager = fakeWorkspaceManager(),
    databasePath = ":memory:",
    exactSecrets = [],
  } = {},
) {
  const confirmationStore = new ConfirmationStore({
    databasePath,
    now: fixedNow,
  });
  const adapter = new CodexTaskAdapter({
    client,
    confirmationStore,
    workspaceManager,
    now: fixedNow,
    redactor: new SecretRedactor({ exactValues: exactSecrets }),
  });
  return { adapter, client, confirmationStore, workspaceManager };
}

function makeWorkspaceReady(store, actionID) {
  store.recordWorkspacePlan(actionID, {
    workspacePath: isolatedWorkspacePath,
    gitRevision: "a".repeat(40),
  });
  store.markWorkspaceReady(actionID);
}

test("list and read expose only device-bound opaque task references", async () => {
  const { adapter, client, confirmationStore } = setup();
  const list = await adapter.list({ pairingID: "pair-1", limit: 5 });
  assert.equal(list.tasks.length, 1);
  assert.match(list.tasks[0].taskReference, /^vct1\./);
  assert.doesNotMatch(JSON.stringify(list), /source-task/);
  assert.deepEqual(
    client.calls[0],
    {
      method: "thread/list",
      params: {
        archived: false,
        limit: 5,
        modelProviders: [],
        sortDirection: "desc",
        sortKey: "recency_at",
        sourceKinds: ["cli", "vscode"],
      },
    },
  );

  const read = await adapter.read({
    pairingID: "pair-1",
    taskReference: list.tasks[0].taskReference,
  });
  assert.equal(read.taskReference, list.tasks[0].taskReference);
  assert.equal(read.title, "Build the broker");
  assert.doesNotMatch(JSON.stringify(read), /source-task/);
  await assert.rejects(
    adapter.read({
      pairingID: "pair-2",
      taskReference: list.tasks[0].taskReference,
    }),
    /not found|invalid/i,
  );
  confirmationStore.close();
});

test("task title, preview, and workspace receive a final exact-value scrub", async () => {
  const exactSecret = "locally-loaded-codex-visible-secret";
  const client = fakeClient();
  client.state.source = sourceThread({
    name: `Investigate ${exactSecret}`,
    cwd: `/Users/jaack/${exactSecret}`,
    preview: JSON.stringify({
      authorization: "Bearer task-preview-secret",
      result: exactSecret,
    }),
  });
  const { adapter, confirmationStore } = setup(client, {
    exactSecrets: [exactSecret],
  });

  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  assert.doesNotMatch(
    JSON.stringify(task),
    /locally-loaded-codex-visible-secret|task-preview-secret/,
  );
  assert.match(task.title, /<redacted>/);
  assert.equal(task.workspace, "<redacted>");
  assert.match(task.preview, /<redacted>/);
  confirmationStore.close();
});

test("prepared confirmation binds safely scrubbed task title and workspace", async () => {
  const exactSecret = "locally-loaded-codex-visible-secret";
  const client = fakeClient();
  client.state.source = sourceThread({
    name: `Continue source-task for ${exactSecret}`,
    cwd: `/Users/jaack/${exactSecret}`,
  });
  const { adapter, confirmationStore } = setup(client, {
    exactSecrets: [exactSecret],
  });
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;

  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Continue the exact task shown to the user.",
    clientRequestID: "request-prepared-display",
  });

  assert.equal(prepared.taskReference, task.taskReference);
  assert.match(prepared.taskTitle, /<task>/);
  assert.match(prepared.taskTitle, /<redacted>/);
  assert.equal(prepared.workspace, "<redacted>");
  assert.doesNotMatch(
    JSON.stringify(prepared),
    /source-task|locally-loaded-codex-visible-secret/,
  );
  confirmationStore.close();
});

test("confirmed continuation rechecks the revision, forks minimally, then starts in an isolated workspace", async () => {
  const { adapter, client, confirmationStore, workspaceManager } = setup();
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Continue safely and run tests.",
    clientRequestID: "request-1",
  });
  assert.equal(prepared.taskTitle, "Build the broker");
  assert.equal(prepared.workspace, "project");
  const receipt = await adapter.commitContinue({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-1",
  });

  assert.match(receipt.forkedTaskReference, /^vct1\./);
  assert.doesNotMatch(JSON.stringify(receipt), /forked-task/);
  assert.equal(receipt.turnReference, "turn-1");
  const forkCall = client.calls.find((call) => call.method === "thread/fork");
  assert.deepEqual(forkCall.params, {
    threadId: "source-task",
    threadSource: "user",
  });
  const turnCall = client.calls.find((call) => call.method === "turn/start");
  assert.deepEqual(turnCall.params, {
    approvalPolicy: "on-request",
    approvalsReviewer: "user",
    clientUserMessageId: "request-1",
    cwd: isolatedWorkspacePath,
    input: [{
      type: "text",
      text: "Continue safely and run tests.",
      text_elements: [],
    }],
    personality: "none",
    sandboxPolicy: {
      type: "workspaceWrite",
      writableRoots: [isolatedWorkspacePath],
      networkAccess: false,
      excludeSlashTmp: false,
      excludeTmpdirEnvVar: false,
    },
    threadId: "forked-task",
  });
  assert.notEqual(turnCall.params.cwd, sourceThread().cwd);
  assert.doesNotMatch(
    JSON.stringify(turnCall.params.sandboxPolicy),
    /\/Users\/jaack\/project/,
  );
  assert.equal(
    workspaceManager.calls.filter((call) => call.method === "plan").length,
    1,
  );
  assert.equal(
    workspaceManager.calls.filter((call) => call.method === "ensure").length,
    1,
  );
  assert.equal(
    workspaceManager.calls.filter((call) => call.method === "verify").length,
    2,
  );
  const turnStartIndex = client.calls.findIndex(
    (call) => call.method === "turn/start",
  );
  assert.deepEqual(client.calls[turnStartIndex - 1], {
    method: "thread/read",
    params: {
      includeTurns: false,
      threadId: "source-task",
    },
  });
  assert.equal(
    client.calls.filter(
      (call) => call.method === "thread/read" && call.params.includeTurns,
    ).length,
    0,
  );
  confirmationStore.close();
});

test("active or in-progress source tasks are rejected before isolation or mutation", async () => {
  const activeStatuses = [
    { type: "active" },
    { type: "inProgress" },
    "running",
  ];
  for (const [index, activeStatus] of activeStatuses.entries()) {
    const client = fakeClient();
    const workspaceManager = fakeWorkspaceManager();
    const { adapter, confirmationStore } = setup(client, { workspaceManager });
    const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
    const prepared = await adapter.prepareContinue({
      pairingID: "pair-1",
      taskReference: task.taskReference,
      instruction: "Do not race the source task.",
      clientRequestID: `request-active-${index}`,
    });
    client.state.source = sourceThread({ status: activeStatus });

    await assert.rejects(
      adapter.commitContinue({
        pairingID: "pair-1",
        actionID: prepared.actionID,
        confirmationNonce: prepared.confirmationNonce,
        clientRequestID: prepared.clientRequestID,
      }),
      /active|progress|idle/i,
    );
    assert.equal(workspaceManager.calls.length, 0);
    assert.equal(
      client.calls.filter((call) => call.method === "thread/fork").length,
      0,
    );
    assert.equal(
      confirmationStore.inspectAction(prepared.actionID).failureCode,
      "source-active",
    );
    confirmationStore.close();
  }
});

test("an already-active source cannot even prepare a continuation", async () => {
  const client = fakeClient();
  client.state.source = sourceThread({ status: { type: "active" } });
  const workspaceManager = fakeWorkspaceManager();
  const { adapter, confirmationStore } = setup(client, { workspaceManager });
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;

  await assert.rejects(
    adapter.prepareContinue({
      pairingID: "pair-1",
      taskReference: task.taskReference,
      instruction: "Do not prepare over active work.",
      clientRequestID: "request-active-prepare",
    }),
    /active|not idle|finish/i,
  );
  assert.equal(workspaceManager.calls.length, 0);
  assert.equal(
    client.calls.filter(
      (call) => ["thread/fork", "turn/start"].includes(call.method),
    ).length,
    0,
  );
  confirmationStore.close();
});

test("source status and revision are rechecked after forking immediately before turn dispatch", async () => {
  const client = fakeClient({
    async onRequest({ method, state }) {
      if (method === "thread/fork") {
        state.source = sourceThread({
          status: { type: "active" },
          updatedAt: 1_800_000_001,
        });
      }
      return undefined;
    },
  });
  const { adapter, confirmationStore } = setup(client);
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Only dispatch if the source remains idle.",
    clientRequestID: "request-raced-source",
  });

  await assert.rejects(
    adapter.commitContinue({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: prepared.clientRequestID,
    }),
    /active|progress|idle/i,
  );
  assert.equal(
    client.calls.filter((call) => call.method === "turn/start").length,
    0,
  );
  assert.equal(
    confirmationStore.inspectAction(prepared.actionID).failureCode,
    "source-active-before-dispatch",
  );
  confirmationStore.close();
});

test("workspace isolation failure is terminal, explicit, and sends no Codex mutation", async () => {
  const workspaceManager = fakeWorkspaceManager({
    planError: new Error("git metadata unavailable"),
  });
  const { adapter, client, confirmationStore } = setup(
    fakeClient(),
    { workspaceManager },
  );
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Fail closed.",
    clientRequestID: "request-workspace-failure",
  });

  await assert.rejects(
    adapter.commitContinue({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: prepared.clientRequestID,
    }),
    /isolated.*workspace|no task was started/i,
  );
  assert.equal(
    confirmationStore.inspectAction(prepared.actionID).failureCode,
    "workspace-isolation-failed",
  );
  assert.deepEqual(
    adapter.operationStatus({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      clientRequestID: prepared.clientRequestID,
    }),
    {
      state: "failed",
      failureCode: "workspace-isolation-failed",
      receipt: null,
    },
  );
  assert.equal(
    client.calls.filter(
      (call) => ["thread/fork", "turn/start"].includes(call.method),
    ).length,
    0,
  );
  confirmationStore.close();
});

test("source changes after preparation are rejected before forking", async () => {
  const { adapter, client, confirmationStore } = setup();
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Continue only if unchanged.",
    clientRequestID: "request-stale",
  });
  client.state.source = sourceThread({ updatedAt: 1_800_000_001 });

  await assert.rejects(
    adapter.commitContinue({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: "request-stale",
    }),
    /changed|prepare again/i,
  );
  assert.equal(
    client.calls.filter((call) => call.method === "thread/fork").length,
    0,
  );
  confirmationStore.close();
});

test("duplicate confirmation shares one in-flight operation and one receipt", async () => {
  let releaseFork;
  const forkGate = new Promise((resolve) => { releaseFork = resolve; });
  const client = fakeClient({
    async onRequest({ method }) {
      if (method === "thread/fork") {
        await forkGate;
      }
      return undefined;
    },
  });
  const { adapter, confirmationStore } = setup(client);
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Continue once.",
    clientRequestID: "request-2",
  });
  const arguments_ = {
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-2",
  };
  const firstPromise = adapter.commitContinue(arguments_);
  const secondPromise = adapter.commitContinue(arguments_);
  releaseFork();
  const [first, second] = await Promise.all([firstPromise, secondPromise]);

  assert.deepEqual(second, first);
  assert.equal(
    client.calls.filter((call) => call.method === "thread/fork").length,
    1,
  );
  assert.equal(
    client.calls.filter((call) => call.method === "turn/start").length,
    1,
  );
  confirmationStore.close();
});

test("a stored fork is reconciled after a crash without forking or starting twice", async () => {
  const client = fakeClient({
    async onRequest({ method, params }) {
      if (method === "thread/read" && params.threadId === "forked-task") {
        return {
          thread: sourceThread({
            id: "forked-task",
            status: { type: "active" },
            turns: [{
              id: "turn-recovered",
              status: "inProgress",
              items: [{
                id: "message-1",
                type: "userMessage",
                clientId: "request-recovery",
                content: [],
              }],
            }],
          }),
        };
      }
      return undefined;
    },
  });
  const { adapter, confirmationStore } = setup(client);
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Recover this operation.",
    clientRequestID: "request-recovery",
  });
  const action = confirmationStore.commit({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-recovery",
  });
  assert.equal(action.stage, "isolate-workspace");
  makeWorkspaceReady(confirmationStore, prepared.actionID);
  confirmationStore.markForkDispatching(prepared.actionID);
  const forkReference = confirmationStore.registerTask({
    pairingID: "pair-1",
    sourceRevision: {
      id: "forked-task",
      name: "Build the broker",
      status: "active",
      updatedAt: 1_800_000_000,
      cwd: isolatedWorkspacePath,
    },
  });
  confirmationStore.recordFork(prepared.actionID, {
    forkThreadID: "forked-task",
    forkTaskReference: forkReference,
  });
  confirmationStore.markTurnStarting(prepared.actionID);

  const receipt = await adapter.commitContinue({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-recovery",
  });
  assert.equal(receipt.turnReference, "turn-recovered");
  assert.equal(
    client.calls.filter((call) => call.method === "thread/fork").length,
    0,
  );
  assert.equal(
    client.calls.filter((call) => call.method === "turn/start").length,
    0,
  );
  confirmationStore.close();
});

test("a persisted workspace plan is reused after restart without returning to the source workspace", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "visionclaw-adapter-restart-"));
  const databasePath = path.join(directory, "broker.sqlite3");
  try {
    const firstStore = new ConfirmationStore({
      databasePath,
      now: fixedNow,
    });
    const sourceRevision = {
      id: "source-task",
      name: "Build the broker",
      status: "idle",
      updatedAt: 1_799_999_999,
      cwd: "/Users/jaack/project",
    };
    const taskReference = firstStore.registerTask({
      pairingID: "pair-1",
      sourceRevision,
    });
    const prepared = firstStore.prepare({
      pairingID: "pair-1",
      taskReference,
      sourceRevision,
      instruction: "Resume from the persisted isolated workspace.",
      clientRequestID: "request-workspace-restart",
    });
    firstStore.commit({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: prepared.clientRequestID,
    });
    firstStore.recordWorkspacePlan(prepared.actionID, {
      workspacePath: isolatedWorkspacePath,
      gitRevision: "a".repeat(40),
    });
    firstStore.close();

    const workspaceManager = fakeWorkspaceManager();
    const { adapter, client, confirmationStore } = setup(
      fakeClient(),
      { workspaceManager, databasePath },
    );
    const receipt = await adapter.commitContinue({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: prepared.clientRequestID,
    });

    assert.equal(receipt.turnReference, "turn-1");
    assert.equal(
      workspaceManager.calls.filter((call) => call.method === "plan").length,
      0,
    );
    assert.deepEqual(
      workspaceManager.calls.find((call) => call.method === "ensure")?.arguments,
      {
        sourceCwd: "/Users/jaack/project",
        workspacePath: isolatedWorkspacePath,
        gitRevision: "a".repeat(40),
      },
    );
    const turnCall = client.calls.find((call) => call.method === "turn/start");
    assert.equal(turnCall.params.cwd, isolatedWorkspacePath);
    assert.deepEqual(
      turnCall.params.sandboxPolicy.writableRoots,
      [isolatedWorkspacePath],
    );
    confirmationStore.close();
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("ambiguous turn recovery never sends a second mutating turn", async () => {
  let recoveredTurnVisible = false;
  const client = fakeClient({
    async onRequest({ method, params }) {
      if (method === "thread/read" && params.threadId === "forked-task") {
        return {
          thread: sourceThread({
            id: "forked-task",
            status: { type: "active" },
            turns: recoveredTurnVisible
              ? [{
                id: "turn-eventually-visible",
                status: "inProgress",
                items: [{
                  id: "message-eventually-visible",
                  type: "userMessage",
                  clientId: "request-ambiguous-turn",
                  content: [],
                }],
              }]
              : [],
          }),
        };
      }
      return undefined;
    },
  });
  const { adapter, confirmationStore } = setup(client);
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Never duplicate this turn.",
    clientRequestID: "request-ambiguous-turn",
  });
  confirmationStore.commit({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-ambiguous-turn",
  });
  makeWorkspaceReady(confirmationStore, prepared.actionID);
  confirmationStore.markForkDispatching(prepared.actionID);
  const forkReference = confirmationStore.registerTask({
    pairingID: "pair-1",
    sourceRevision: {
      id: "forked-task",
      name: "Build the broker",
      status: "active",
      updatedAt: 1_800_000_000,
      cwd: isolatedWorkspacePath,
    },
  });
  confirmationStore.recordFork(prepared.actionID, {
    forkThreadID: "forked-task",
    forkTaskReference: forkReference,
  });
  confirmationStore.markTurnStarting(prepared.actionID);

  await assert.rejects(
    adapter.commitContinue({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      confirmationNonce: prepared.confirmationNonce,
      clientRequestID: "request-ambiguous-turn",
    }),
    /reconcil/i,
  );
  assert.equal(
    client.calls.filter((call) => call.method === "turn/start").length,
    0,
  );
  assert.equal(
    confirmationStore.inspectAction(prepared.actionID).state,
    "turn-recovery-required",
  );

  recoveredTurnVisible = true;
  const receipt = await adapter.commitContinue({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-ambiguous-turn",
  });
  assert.equal(receipt.turnReference, "turn-eventually-visible");
  assert.equal(
    client.calls.filter((call) => call.method === "turn/start").length,
    0,
  );
  confirmationStore.close();
});

test("cancel interrupts the active turn on the owned fork", async () => {
  const { adapter, client, confirmationStore } = setup();
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Start then stop.",
    clientRequestID: "request-cancel",
  });
  await adapter.commitContinue({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-cancel",
  });

  const cancelled = await adapter.cancelContinue({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    clientRequestID: "request-cancel",
  });
  assert.deepEqual(cancelled, { cancelled: true, status: "cancelled" });
  assert.deepEqual(
    client.calls.find((call) => call.method === "turn/interrupt")?.params,
    { threadId: "forked-task", turnId: "turn-1" },
  );
  confirmationStore.close();
});

test("cancel waits for an in-flight turn acknowledgement before interrupting it", async () => {
  let announceTurnStart;
  let releaseTurnStart;
  const turnStarted = new Promise((resolve) => { announceTurnStart = resolve; });
  const turnGate = new Promise((resolve) => { releaseTurnStart = resolve; });
  const client = fakeClient({
    async onRequest({ method }) {
      if (method === "turn/start") {
        announceTurnStart();
        await turnGate;
      }
      return undefined;
    },
  });
  const { adapter, confirmationStore } = setup(client);
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Start while cancellation arrives.",
    clientRequestID: "request-cancel-race",
  });
  const arguments_ = {
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-cancel-race",
  };
  const commit = adapter.commitContinue(arguments_);
  await turnStarted;
  const cancellation = adapter.cancelContinue({
    pairingID: arguments_.pairingID,
    actionID: arguments_.actionID,
    clientRequestID: arguments_.clientRequestID,
  });
  releaseTurnStart();
  await commit;
  assert.deepEqual(
    await cancellation,
    { cancelled: true, status: "cancelled" },
  );
  assert.equal(
    client.calls.filter((call) => call.method === "turn/interrupt").length,
    1,
  );
  confirmationStore.close();
});

test("turn notifications update the persisted receipt without delaying commit", async () => {
  const client = fakeClient({
    async onRequest({ method, client: emitter }) {
      if (method === "turn/start") {
        emitter.emit("notification", {
          method: "turn/completed",
          params: {
            turn: { id: "turn-1", status: "completed" },
          },
        });
      }
      return undefined;
    },
  });
  const { adapter, confirmationStore } = setup(client);
  const [task] = (await adapter.list({ pairingID: "pair-1" })).tasks;
  const prepared = await adapter.prepareContinue({
    pairingID: "pair-1",
    taskReference: task.taskReference,
    instruction: "Finish quickly.",
    clientRequestID: "request-notification",
  });
  const receipt = await adapter.commitContinue({
    pairingID: "pair-1",
    actionID: prepared.actionID,
    confirmationNonce: prepared.confirmationNonce,
    clientRequestID: "request-notification",
  });
  assert.equal(receipt.status, "completed");
  assert.equal(
    adapter.operationStatus({
      pairingID: "pair-1",
      actionID: prepared.actionID,
      clientRequestID: "request-notification",
    }).receipt.status,
    "completed",
  );
  confirmationStore.close();
});
