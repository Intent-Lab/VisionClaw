import "dotenv/config";
import { InferenceProvider, resolveBaseURL, resolveProvider } from "./providers.js";

export interface GatewayConfig {
  port: number;
  storePath: string;
  /** token -> userId. Parsed from GATEWAY_TOKENS="tokenA:alice,tokenB:bob". */
  tokens: Map<string, string>;
  /** Selected inference provider (see providers.ts). */
  provider: InferenceProvider;
  /**
   * Anthropic-compatible base URL for the provider/region, or undefined to use
   * the SDK default (native Anthropic API).
   */
  providerBaseURL?: string;
  /** Environment variable that carries the selected provider's API key. */
  providerApiKeyEnv: string;
  agentModel: string;
  agentEffort: "low" | "medium" | "high";
  /** How long a /v1/chat/completions call waits before converting to a background task. */
  quickAnswerTimeoutMs: number;
  /**
   * Return an acknowledgement immediately instead of racing the agent against a
   * deadline. A voice turn wants a reply in the assistant's own voice within a
   * beat, not the right answer eight seconds later -- and once the request never
   * carries the result, there is no deadline left to pick and no inline-vs-
   * deferred branch to land on the wrong side of.
   */
  spawnMode: boolean;
}

function parseTokens(raw: string | undefined): Map<string, string> {
  const map = new Map<string, string>();
  if (!raw) return map;
  for (const pair of raw.split(",")) {
    const [token, userId] = pair.split(":").map((s) => s.trim());
    if (token && userId) map.set(token, userId);
  }
  return map;
}

const provider = resolveProvider(process.env.INFERENCE_PROVIDER);

export const config: GatewayConfig = {
  port: Number(process.env.PORT ?? 8788),
  storePath: process.env.STORE_PATH ?? "./data/gateway-store.json",
  tokens: parseTokens(process.env.GATEWAY_TOKENS),
  provider,
  providerBaseURL: resolveBaseURL(provider, process.env.PROVIDER_REGION),
  providerApiKeyEnv: provider.apiKeyEnv,
  agentModel: process.env.AGENT_MODEL ?? provider.defaultModel,
  agentEffort: (process.env.AGENT_EFFORT as GatewayConfig["agentEffort"]) ?? "medium",
  quickAnswerTimeoutMs: Number(process.env.QUICK_ANSWER_TIMEOUT_MS ?? 30_000),
  spawnMode: process.env.SPAWN_MODE !== "false",
};

if (config.tokens.size === 0) {
  console.warn(
    "[config] GATEWAY_TOKENS is empty - no client will be able to authenticate. " +
      'Set GATEWAY_TOKENS="sometoken:someUserId" in .env',
  );
}

if (!process.env[config.providerApiKeyEnv]) {
  console.warn(
    `[config] ${config.providerApiKeyEnv} is empty - the ${config.provider.name} ` +
      "inference provider will reject requests. Set it in .env",
  );
}
