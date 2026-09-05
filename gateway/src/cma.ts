import Anthropic from "@anthropic-ai/sdk";

/** One client for the whole gateway. Reads ANTHROPIC_API_KEY from the environment. */
export const anthropic = new Anthropic();
