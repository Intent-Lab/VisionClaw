import assert from "node:assert/strict";
import test from "node:test";

import {
  HarnessRouter,
  createDefaultHarnessRegistry,
} from "../src/harness-registry.mjs";

test("Eva resolves to the broker-owned glasses agent", async () => {
  const calls = [];
  const router = new HarnessRouter({
    registry: createDefaultHarnessRegistry({ evaAgentID: "glasses" }),
    openClawAdapter: {
      invoke: async (request) => {
        calls.push(request);
        return { status: "completed", response: "There are 14 agents." };
      },
    },
  });

  const result = await router.invoke({
    harnessID: "eva",
    instruction: "Which agents are configured?",
    clientRequestID: "request-1",
    pairingID: "pair-1",
  });
  assert.equal(result.status, "completed");
  assert.deepEqual(calls, [{
    agentID: "glasses",
    instruction: "Which agents are configured?",
    clientRequestID: "request-1",
    pairingID: "pair-1",
  }]);
});

test("client-controlled route targets and extra fields are rejected", async () => {
  let calls = 0;
  const router = new HarnessRouter({
    registry: createDefaultHarnessRegistry({ evaAgentID: "glasses" }),
    openClawAdapter: {
      invoke: async () => {
        calls += 1;
        return { status: "completed", response: "unexpected" };
      },
    },
  });

  await assert.rejects(
    router.invoke({
      harnessID: "eva",
      routeTarget: "../../shell",
      instruction: "run this",
      clientRequestID: "request-2",
      pairingID: "pair-1",
    }),
    /unexpected field|routeTarget/i,
  );
  assert.equal(calls, 0);
});

test("unknown harness, execute forwarding, and oversized instructions fail closed", async () => {
  let calls = 0;
  const router = new HarnessRouter({
    registry: createDefaultHarnessRegistry({ evaAgentID: "glasses" }),
    openClawAdapter: {
      invoke: async () => {
        calls += 1;
        return { status: "completed", response: "unexpected" };
      },
    },
  });

  await assert.rejects(
    router.invoke({
      harnessID: "shell",
      instruction: "whoami",
      clientRequestID: "request-3",
      pairingID: "pair-1",
    }),
    /unknown harness/i,
  );
  await assert.rejects(
    router.invoke({
      harnessID: "execute",
      instruction: "whoami",
      clientRequestID: "request-4",
      pairingID: "pair-1",
    }),
    /unknown harness|not allowed/i,
  );
  await assert.rejects(
    router.invoke({
      harnessID: "eva",
      instruction: "x".repeat(4_001),
      clientRequestID: "request-5",
      pairingID: "pair-1",
    }),
    /too long/i,
  );
  assert.equal(calls, 0);
});
