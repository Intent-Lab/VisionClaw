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
      // Portrait phone viewport so the live-view canvas fits the phone card
      // (a desktop-width browser rendered into a ~360dp card shows only a
      // cropped slice) and the target site serves its mobile layout.
      browserSettings: {
        proxyCountryCode: "us",
        record: true,
        screenWidth: Number(process.env.BROWSER_USE_SCREEN_W ?? 390),
        screenHeight: Number(process.env.BROWSER_USE_SCREEN_H ?? 844),
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

export interface BrowseOutcome {
  text: string | null;
  deferred: boolean;
  runId: string;
  cost?: string;
  recordingUrl?: string | null;
}

/**
 * Poll an existing run to terminal. If it finishes within maxWaitMs, return the
 * text; otherwise return deferred and keep polling in the background, handing
 * the late result to onLate.
 */
export async function awaitBrowse(
  runId: string,
  maxWaitMs: number,
  onLate: (text: string, meta: { runId: string; cost?: string }) => void,
): Promise<BrowseOutcome> {
  let timedOut = false;
  const poll = (async (): Promise<{ text: string; cost?: string; recordingUrl?: string | null }> => {
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
        const full = (await (await fetch(`${BASE}/runs/${runId}`, { headers: buHeaders() })).json()) as {
          result?: string | null;
          error?: string | null;
          totalCostUsd?: string;
        };
        const text =
          status === "completed"
            ? full.result || "The browser task finished but returned no text."
            : `The browser task did not finish (${status}${full.error ? ": " + full.error : ""}).`;
        return { text, cost: full.totalCostUsd };
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
    return { text: finished.text, deferred: false, runId, cost: finished.cost };
  }
  void poll
    .then((o) => {
      if (timedOut && o.text) onLate(o.text, { runId, cost: o.cost });
    })
    .catch((err) => console.error("[browse] late poll failed:", err));
  return { text: null, deferred: true, runId };
}
