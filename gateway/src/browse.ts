// Browser Use Cloud v4 (https://api.browser-use.com/api/v4): give an agent a
// natural-language goal, it drives a real cloud browser and returns the result.
// Used for the "visit a live site" tasks the CMA's tools cannot do.
//
// Split into start + await so the voice worker can show a live-view card the
// instant the browser is up (only the worker holds the LiveKit room, so the
// card push must go through it), then keep waiting for the result on a second
// call. One shared Browser Use account (BROWSER_USE_API_KEY); unauthenticated
// (no per-user login state stored) in this version.

const BASE = "https://api.browser-use.com/api/v4";
const TERMINAL = new Set(["completed", "failed", "cancelled"]);

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

export interface BrowseStart {
  runId: string;
  liveUrl: string | null;
}

/**
 * Create a run and return as soon as the browser's live-view URL is available
 * (a few seconds), so the caller can show it while the task runs. record:true
 * means a replay mp4 is retrievable afterward. maxCostUsd bounds spend.
 */
export async function startBrowse(task: string): Promise<BrowseStart> {
  const cap = Number(process.env.BROWSER_USE_MAX_COST_USD ?? 0.75);
  const model = process.env.BROWSER_USE_MODEL; // omit -> Browser Use default (cheapest/fastest)
  const create = await fetch(`${BASE}/runs`, {
    method: "POST",
    headers: buHeaders(),
    body: JSON.stringify({
      task,
      ...(model ? { model } : {}),
      maxCostUsd: cap,
      // Landscape desktop viewport. The live-view card is wider than it is tall,
      // so a portrait remote screen gets letterboxed with big empty side bars.
      // A normal horizontal desktop size fills the card's width (small but full)
      // and shows the regular desktop site, which reads far more naturally.
      browserSettings: {
        proxyCountryCode: "us",
        record: true,
        screenWidth: Number(process.env.BROWSER_USE_SCREEN_W ?? 1280),
        screenHeight: Number(process.env.BROWSER_USE_SCREEN_H ?? 800),
      },
    }),
  });
  if (!create.ok) {
    throw new Error(`browse create ${create.status}: ${(await create.text()).slice(0, 200)}`);
  }
  const created = (await create.json()) as { id: string };
  const runId = created.id;

  // The embeddable live-view URL for an agent run lives in the RUN EVENT STREAM
  // (browser.ready / browser.attached -> data.live_view_url), not on the run or
  // the /browsers objects. It appears ~1.5s in; poll a short window for it, then
  // give up and run without a live card.
  let liveUrl: string | null = null;
  for (let i = 0; i < 8 && !liveUrl; i++) {
    await sleep(1500);
    try {
      const ev = await fetch(`${BASE}/runs/${runId}/events`, { headers: buHeaders() });
      if (!ev.ok) continue;
      const { events } = (await ev.json()) as {
        events?: Array<{ type?: string; data?: { live_view_url?: string | null } }>;
      };
      for (const e of events ?? []) {
        if ((e.type === "browser.ready" || e.type === "browser.attached") && e.data?.live_view_url) {
          liveUrl = e.data.live_view_url;
          break;
        }
      }
    } catch {
      // transient; keep trying within the window
    }
  }
  return { runId, liveUrl };
}

/** A readable record of what the computer-use agent actually did, for the trace. */
export interface BrowseDetail {
  status: string;
  model?: string;
  result?: string | null;
  error?: string | null;
  steps: string[]; // ordered agent narration + browser actions
  stepCount: number; // number of browser actions taken
  inputTokens?: number;
  outputTokens?: number;
  durationS?: number;
}

export interface BrowseOutcome {
  text: string | null;
  deferred: boolean;
  runId: string;
  cost?: string;
  recordingUrl?: string | null;
  detail?: BrowseDetail;
}

/**
 * Pull the run summary plus a compact, readable step list (the agent's plan
 * narration and the browser actions it took), so the trace shows what the
 * computer-use agent did -- not just that a task ran.
 */
export async function fetchRunDetail(runId: string): Promise<BrowseDetail> {
  const run = (await (await fetch(`${BASE}/runs/${runId}`, { headers: buHeaders() })).json()) as {
    status?: string;
    result?: string | null;
    error?: string | null;
    model?: string;
    totalInputTokens?: number;
    totalOutputTokens?: number;
    createdAt?: string;
    updatedAt?: string;
  };
  const steps: string[] = [];
  let stepCount = 0;
  try {
    const ev = await fetch(`${BASE}/runs/${runId}/events`, { headers: buHeaders() });
    if (ev.ok) {
      const { events } = (await ev.json()) as {
        events?: Array<{ type?: string; data?: { part?: { type?: string; text?: string; tool?: string } } }>;
      };
      for (const e of events ?? []) {
        if (e.type !== "core.event") continue;
        const part = e.data?.part;
        if (!part) continue;
        if (part.type === "text" && part.text?.trim()) {
          steps.push(`plan: ${part.text.trim().slice(0, 110)}`);
        } else if (part.type === "tool" && part.tool) {
          stepCount += 1;
          steps.push(`action: ${part.tool}`);
        }
        // Keep the array well under the trace's 2000-char/field cap so it stays
        // a real array, not a truncated string.
        if (steps.length >= 15) break;
      }
    }
  } catch {
    // events are best-effort; the result + summary still stand
  }
  let durationS: number | undefined;
  if (run.createdAt && run.updatedAt) {
    const d = (Date.parse(run.updatedAt) - Date.parse(run.createdAt)) / 1000;
    if (Number.isFinite(d) && d >= 0) durationS = Math.round(d);
  }
  return {
    status: run.status ?? "unknown",
    model: run.model,
    result: run.result,
    error: run.error,
    steps,
    stepCount,
    inputTokens: run.totalInputTokens,
    outputTokens: run.totalOutputTokens,
    durationS,
  };
}

/**
 * Poll an existing run to terminal. If it finishes within maxWaitMs, return the
 * text; otherwise return deferred and keep polling in the background, handing
 * the late result to onLate.
 */
export async function awaitBrowse(
  runId: string,
  maxWaitMs: number,
  onLate: (text: string, meta: { runId: string; cost?: string; detail?: BrowseDetail }) => void,
): Promise<BrowseOutcome> {
  let timedOut = false;
  const poll = (async (): Promise<{ text: string; cost?: string; detail: BrowseDetail }> => {
    for (;;) {
      await sleep(3000);
      let status = "";
      try {
        const s = await fetch(`${BASE}/runs/${runId}/status`, { headers: buHeaders() });
        if (s.ok) status = ((await s.json()) as { status: string }).status;
      } catch {
        continue;
      }
      if (TERMINAL.has(status)) {
        const detail = await fetchRunDetail(runId);
        const cost = (await (await fetch(`${BASE}/runs/${runId}`, { headers: buHeaders() })).json())
          .totalCostUsd as string | undefined;
        const text =
          status === "completed"
            ? detail.result || "The browser task finished but returned no text."
            : `The browser task did not finish (${status}${detail.error ? ": " + detail.error : ""}).`;
        return { text, cost, detail };
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
    return { text: finished.text, deferred: false, runId, cost: finished.cost, detail: finished.detail };
  }
  void poll
    .then((o) => {
      if (timedOut && o.text) onLate(o.text, { runId, cost: o.cost, detail: o.detail });
    })
    .catch((err) => console.error("[browse] late poll failed:", err));
  return { text: null, deferred: true, runId };
}
