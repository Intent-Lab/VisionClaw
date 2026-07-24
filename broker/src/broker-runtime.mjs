import { join } from "node:path";
import { homedir } from "node:os";

import { AsyncHarnessAdapter } from "./async-harness-adapter.mjs";
import { BrokerAuthorization } from "./broker-authorization.mjs";
import { createBrokerApplication } from "./broker-app.mjs";
import { BrokerServer } from "./broker-server.mjs";
import { CodexTaskAdapter } from "./codex-adapter.mjs";
import { CodexAppServerClient } from "./codex-app-server-client.mjs";
import { CodexWorkspaceManager } from "./codex-workspace-manager.mjs";
import { ConfirmationStore } from "./confirmation-store.mjs";
import {
  createDefaultHarnessRegistry,
  HarnessRouter,
} from "./harness-registry.mjs";
import { HarnessOperationStore } from "./harness-operation-store.mjs";
import { selectLANAddress } from "./network-endpoint.mjs";
import { OpenClawAdapter } from "./openclaw-adapter.mjs";
import { OpenClawGatewayClient } from "./openclaw-gateway-client.mjs";
import { PairingService } from "./pairing-service.mjs";
import {
  removeRuntimeRecord,
  writeRuntimeRecord,
} from "./runtime-record.mjs";
import { RuntimeLock } from "./runtime-lock.mjs";
import {
  ensureBrokerIdentity,
  loadOpenClawGatewayConfig,
} from "./runtime-state.mjs";
import {
  CapabilityIssuer,
  PairingManager,
  SecretRedactor,
} from "./security.mjs";
import {
  LOCAL_ADMIN_SECRET_NAME,
  SecurityStateStore,
} from "./security-state-store.mjs";

const BROKER_VERSION = "0.1.0";

export async function createBrokerRuntime({
  stateDirectory = join(homedir(), ".visionclaw-broker"),
  host = "127.0.0.1",
  port = 38_443,
  gatewayConfigLoader = loadOpenClawGatewayConfig,
  gatewayClientFactory = defaultGatewayClientFactory,
  codexClientFactory = () => new CodexAppServerClient(),
  serverFactory = (options) => new BrokerServer(options),
  now = Date.now,
} = {}) {
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error("Broker runtime port is invalid.");
  }
  const bindHost = ["0.0.0.0", "::"].includes(host)
    ? selectLANAddress()
    : host;
  const endpoint = `https://${bindHost}:${port}`;
  const identity = await ensureBrokerIdentity({ stateDirectory });
  const databasePath = join(stateDirectory, "broker.sqlite3");
  const securityState = new SecurityStateStore({ path: databasePath });
  const operations = new HarnessOperationStore({ path: databasePath });
  const confirmations = new ConfirmationStore({ databasePath });

  try {
    const gatewayConfiguration = await gatewayConfigLoader();
    const gatewayClient = gatewayClientFactory(gatewayConfiguration);
    const codexClient = codexClientFactory();
    const signingSecret = securityState.getOrCreateSecret(
      "capability-signing",
      32,
    );
    const adminSecret = securityState.getOrCreateSecret(
      LOCAL_ADMIN_SECRET_NAME,
      32,
    );
    const outboundRedactor = new SecretRedactor({
      exactValues: [
        gatewayConfiguration.token.reveal(),
        signingSecret.reveal(),
        adminSecret.reveal(),
      ],
    });
    const openClawBackend = new OpenClawAdapter({
      gatewayClient,
      allowedAgentIDs: ["glasses"],
      redactor: outboundRedactor,
    });
    const asyncHarness = new AsyncHarnessAdapter({
      backendAdapter: openClawBackend,
      operationStore: operations,
      redactor: outboundRedactor,
    });
    const harnessRouter = new HarnessRouter({
      registry: createDefaultHarnessRegistry({ evaAgentID: "glasses" }),
      openClawAdapter: asyncHarness,
    });
    const codexAdapter = new CodexTaskAdapter({
      client: codexClient,
      confirmationStore: confirmations,
      workspaceManager: new CodexWorkspaceManager({
        rootDirectory: join(stateDirectory, "codex-worktrees"),
      }),
      now,
      redactor: outboundRedactor,
    });
    const capabilityIssuer = new CapabilityIssuer({
      issuer: `visionclaw-broker:${identity.brokerID}`,
      audience: "visionclaw-ios",
      signingKey: Buffer.from(signingSecret.reveal(), "base64url"),
      consumptionStore: securityState,
      now,
    });
    const authorization = new BrokerAuthorization({
      pairingStore: securityState,
      capabilityIssuer,
      replayGuard: securityState,
      now,
    });
    const pairingManager = new PairingManager({
      brokerID: identity.brokerID,
      endpoint,
      tlsPinSHA256: identity.tlsPinSHA256,
      now,
    });
    const pairingService = new PairingService({
      pairingManager,
      pairingStore: securityState,
      now,
    });
    const readiness = { value: false };
    const application = createBrokerApplication({
      authorization,
      codexAdapter,
      harnessOperations: asyncHarness,
      harnessRouter,
      pairingService,
      readiness: () => readiness.value,
      brokerID: identity.brokerID,
      version: BROKER_VERSION,
    });
    const server = serverFactory({
      application,
      pairingService,
      identity,
      host: bindHost,
      port,
      adminToken: adminSecret.reveal(),
    });
    const runtimeLock = new RuntimeLock({ stateDirectory });

    return new BrokerRuntime({
      stateDirectory,
      identity,
      host: bindHost,
      server,
      gatewayClient,
      codexClient,
      stores: [confirmations, operations, securityState],
      harnessOperationStore: operations,
      runtimeLock,
      readiness,
      now,
    });
  } catch (error) {
    confirmations.close();
    operations.close();
    securityState.close();
    throw error;
  }
}

export class BrokerRuntime {
  #stateDirectory;
  #identity;
  #host;
  #server;
  #gatewayClient;
  #codexClient;
  #stores;
  #harnessOperationStore;
  #runtimeLock;
  #readiness;
  #now;
  #state = "idle";

  constructor({
    stateDirectory,
    identity,
    host,
    server,
    gatewayClient,
    codexClient,
    stores,
    harnessOperationStore,
    runtimeLock,
    readiness,
    now = Date.now,
  }) {
    this.#stateDirectory = stateDirectory;
    this.#identity = identity;
    this.#host = host;
    this.#server = server;
    this.#gatewayClient = gatewayClient;
    this.#codexClient = codexClient;
    this.#stores = stores;
    this.#harnessOperationStore = harnessOperationStore;
    this.#runtimeLock = runtimeLock;
    this.#readiness = readiness;
    this.#now = now;
  }

  async start() {
    if (this.#state !== "idle") {
      throw new Error(`Broker runtime is already ${this.#state}.`);
    }
    this.#state = "starting";
    try {
      await this.#runtimeLock.acquire();
      this.#harnessOperationStore.failInterrupted({ now: this.#now() });
      await Promise.all([
        this.#gatewayClient.connect(),
        this.#codexClient.start(),
      ]);
      await requireOpenClawAgent(this.#gatewayClient, "glasses");
      await this.#server.start();
      await writeRuntimeRecord({
        stateDirectory: this.#stateDirectory,
        value: {
          brokerID: this.#identity.brokerID,
          host: this.#host,
          pid: process.pid,
          port: this.#server.port,
          startedAt: this.#now(),
        },
      });
      this.#readiness.value = true;
      this.#state = "running";
    } catch (error) {
      try {
        await this.#shutdown();
      } catch {
        // Preserve the startup failure; cleanup errors are secondary.
      }
      throw error;
    }
  }

  async stop() {
    if (this.#state === "stopped") return;
    await this.#shutdown();
  }

  async #shutdown() {
    this.#readiness.value = false;
    this.#state = "stopped";
    let firstError = null;
    const attempt = async (operation) => {
      try {
        await operation();
      } catch (error) {
        firstError ??= error;
      }
    };
    await attempt(() => this.#server.stop());
    await attempt(() => this.#gatewayClient.close());
    await attempt(() => this.#codexClient.close());
    for (const store of this.#stores) {
      await attempt(() => store.close());
    }
    await attempt(
      () => removeRuntimeRecord({ stateDirectory: this.#stateDirectory }),
    );
    await attempt(() => this.#runtimeLock.release());
    if (firstError) throw firstError;
  }
}

async function requireOpenClawAgent(gatewayClient, agentID) {
  const result = await gatewayClient.request("agents.list", {});
  const agents = Array.isArray(result)
    ? result
    : Array.isArray(result?.agents)
      ? result.agents
      : Array.isArray(result?.data)
        ? result.data
        : [];
  if (!agents.some((agent) => agent?.id === agentID)) {
    throw new Error(
      `Required OpenClaw agent ${agentID} is not configured.`,
    );
  }
}

function defaultGatewayClientFactory(configuration) {
  return new OpenClawGatewayClient({
    url: configuration.url,
    authProvider: async () => ({
      auth: { token: configuration.token.reveal() },
    }),
  });
}
