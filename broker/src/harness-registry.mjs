const MAX_INSTRUCTION_CHARACTERS = 4_000;

export function createDefaultHarnessRegistry({ evaAgentID = "glasses" } = {}) {
  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/i.test(evaAgentID)) {
    throw new Error("Eva agent ID is invalid.");
  }
  return new Map([
    ["eva", Object.freeze({
      id: "eva",
      adapter: "openclaw",
      agentID: evaAgentID,
    })],
  ]);
}

export class HarnessRouter {
  #registry;
  #openClawAdapter;

  constructor({ registry, openClawAdapter }) {
    this.#registry = registry;
    this.#openClawAdapter = openClawAdapter;
  }

  async invoke(request) {
    assertExactFields(
      request,
      ["harnessID", "instruction", "clientRequestID", "pairingID"],
    );
    if (typeof request.harnessID !== "string") {
      throw new Error("Harness ID is required.");
    }
    const harness = this.#registry.get(request.harnessID);
    if (!harness) {
      throw new Error(`Unknown harness ${request.harnessID}; no action was taken.`);
    }
    const instruction = request.instruction?.trim();
    if (!instruction) {
      throw new Error("Harness instruction is required.");
    }
    if (instruction.length > MAX_INSTRUCTION_CHARACTERS) {
      throw new Error("Harness instruction is too long.");
    }
    if (harness.adapter !== "openclaw") {
      throw new Error("Harness adapter is not allowed.");
    }
    return this.#openClawAdapter.invoke({
      agentID: harness.agentID,
      instruction,
      clientRequestID: request.clientRequestID,
      pairingID: request.pairingID,
    });
  }
}

function assertExactFields(value, allowedFields) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("A typed harness request is required.");
  }
  const allowed = new Set(allowedFields);
  for (const field of Object.keys(value)) {
    if (!allowed.has(field)) {
      throw new Error(`Unexpected field ${field}; no action was taken.`);
    }
  }
  for (const field of allowedFields) {
    if (!(field in value)) {
      throw new Error(`Missing field ${field}; no action was taken.`);
    }
  }
}
