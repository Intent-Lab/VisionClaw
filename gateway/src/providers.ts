/**
 * Inference provider registry.
 *
 * The gateway drives its managed-agent sessions through the single
 * `@anthropic-ai/sdk` client in cma.ts. Any provider that exposes an
 * Anthropic-compatible endpoint can be reached through that same client by
 * pointing its `baseURL` at the provider's gateway, so adding one here is a
 * table entry rather than a second SDK. Selection is env-driven (see config.ts)
 * and defaults to the native Anthropic API, which keeps the existing behaviour.
 */

export interface ProviderRegion {
  /** Region id used in PROVIDER_REGION. */
  region: string;
  /** Anthropic-compatible base URL for this region. */
  anthropicBaseURL: string;
}

export interface InferenceProvider {
  /** Stable id used in INFERENCE_PROVIDER. */
  id: string;
  /** Human-readable name. */
  name: string;
  /** Model id used when AGENT_MODEL is unset. */
  defaultModel: string;
  /** Environment variable that carries this provider's API key. */
  apiKeyEnv: string;
  /**
   * Anthropic-compatible base URLs by region. The native Anthropic API needs no
   * override, so its list is empty and the SDK default is used.
   */
  regions: ProviderRegion[];
  /** Region chosen when PROVIDER_REGION is unset. */
  defaultRegion?: string;
}

export const PROVIDERS: Record<string, InferenceProvider> = {
  anthropic: {
    id: "anthropic",
    name: "Anthropic",
    defaultModel: "claude-opus-5",
    apiKeyEnv: "ANTHROPIC_API_KEY",
    regions: [],
  },
  minimax: {
    id: "minimax",
    name: "MiniMax",
    defaultModel: "MiniMax-M3",
    apiKeyEnv: "MINIMAX_API_KEY",
    regions: [
      { region: "global_en", anthropicBaseURL: "https://api.minimax.io/anthropic" },
      { region: "cn_zh", anthropicBaseURL: "https://api.minimaxi.com/anthropic" },
    ],
    defaultRegion: "global_en",
  },
};

/** Resolve a provider by id, falling back to Anthropic for unknown ids. */
export function resolveProvider(id: string | undefined): InferenceProvider {
  const key = (id ?? "anthropic").toLowerCase();
  const provider = PROVIDERS[key];
  if (!provider) {
    console.warn(`[providers] unknown INFERENCE_PROVIDER "${id}", falling back to anthropic`);
    return PROVIDERS.anthropic;
  }
  return provider;
}

/**
 * Anthropic-compatible base URL for the provider/region, or undefined when the
 * SDK default should be used (native Anthropic API).
 */
export function resolveBaseURL(provider: InferenceProvider, region: string | undefined): string | undefined {
  if (provider.regions.length === 0) return undefined;
  const wanted = region ?? provider.defaultRegion;
  const match = provider.regions.find((r) => r.region === wanted);
  if (!match) {
    console.warn(
      `[providers] unknown PROVIDER_REGION "${region}" for ${provider.name}, ` +
        `using "${provider.regions[0].region}"`,
    );
    return provider.regions[0].anthropicBaseURL;
  }
  return match.anthropicBaseURL;
}
