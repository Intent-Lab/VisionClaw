import Anthropic from "@anthropic-ai/sdk";
import { config } from "./config.js";

/**
 * One client for the whole gateway.
 *
 * Defaults to the native Anthropic API, reading ANTHROPIC_API_KEY from the
 * environment. When an Anthropic-compatible provider is selected (see
 * providers.ts), its base URL and API key are passed through so the same SDK
 * reaches that provider's endpoint.
 */
const providerApiKey = process.env[config.providerApiKeyEnv];
export const anthropic = new Anthropic({
  ...(config.providerBaseURL ? { baseURL: config.providerBaseURL } : {}),
  ...(providerApiKey ? { apiKey: providerApiKey } : {}),
});
