// Browser Use Cloud v4 (https://api.browser-use.com/api/v4): give an agent a
// natural-language goal, it drives a real cloud browser and returns the result.
// Used for the "visit a live site" tasks the CMA's tools cannot do -- product
// pages, store comparisons, availability checks. One shared Browser Use account
// (BROWSER_USE_API_KEY); no per-user login state in this version, so tasks are
// unauthenticated (public browsing), which keeps participant credentials out of
// the picture. A per-user profile for logged-in actions is a later opt-in.

const BASE = "https://api.browser-use.com/api/v4";

export function browseEnabled(): boolean {
  return !!process.env.BROWSER_USE_API_KEY;
}

function buHeaders(): Record<string, string> {
  return {
    "X-Browser-Use-API-Key": process.env.BROWSER_USE_API_KEY as string,
    "Content-Type": "application/json",
  };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export interface BrowseOutcome {
  text: string | null;
  deferred: boolean;
  runId?: string;
  cost?: string;
}

/**
 * Start a run, then poll its status until terminal. If it finishes within
 * maxWaitMs, return the text; otherwise return deferred and keep polling in the
 * background, handing the late result to onLate. maxCostUsd bounds spend per run
 * so a stuck agent cannot run up the bill.
 */
export async function runBrowse(
  task: string,
  maxWaitMs: number,
  onLate: (text: string, meta: { runId: string; cost?: string }) => void,
): Promise<BrowseOutcome> {
  const cap = Number(process.env.BROWSER_USE_MAX_COST_USD ?? 0.75);
  const model = process.env.BROWSER_USE_MODEL; // omit -> Browser Use default (cheapest/fastest)
  const create = await fetch(`${BASE}/runs`, {
    method: "POST",
    headers: buHeaders(),
    body: JSON.stringify({
      task,
      ...(model ? { model } : {}),
      maxCostUsd: cap,
      browserSettings: { proxyCountryCode: "us" },
    }),
  });
  if (!create.ok) {
    throw new Error(`browse create ${create.status}: ${(await create.text()).slice(0, 200)}`);
  }
  const { id } = (await create.json()) as { id: string };

  let timedOut = false;
  const poll = (async (): Promise<{ text: string; cost?: string }> => {
    for (;;) {
      await sleep(3000);
      let status = "";
      try {
        const s = await fetch(`${BASE}/runs/${id}/status`, { headers: buHeaders() });
        if (s.ok) status = ((await s.json()) as { status: string }).status;
      } catch {
        continue; // transient; keep polling
      }
      if (status === "completed" || status === "failed" || status === "cancelled") {
        const full = (await (await fetch(`${BASE}/runs/${id}`, { headers: buHeaders() })).json()) as {
          result?: string | null;
          error?: string | null;
          totalCostUsd?: string;
        };
        if (status === "completed") {
          return { text: full.result || "The browser task finished but returned no text.", cost: full.totalCostUsd };
        }
        return {
          text: `The browser task did not finish (${status}${full.error ? ": " + full.error : ""}).`,
          cost: full.totalCostUsd,
        };
      }
    }
  })();

  const timeout = new Promise<null>((resolve) => {
    const t = setTimeout(() => {
      timedOut = true;
      resolve(null);
    }, maxWaitMs);
    t.unref?.();
  });

  const finished = await Promise.race([poll, timeout]);
  if (finished !== null) {
    return { text: finished.text, deferred: false, runId: id, cost: finished.cost };
  }
  void poll
    .then((o) => {
      if (timedOut && o.text) onLate(o.text, { runId: id, cost: o.cost });
    })
    .catch((err) => console.error("[browse] late poll failed:", err));
  return { text: null, deferred: true, runId: id };
}
