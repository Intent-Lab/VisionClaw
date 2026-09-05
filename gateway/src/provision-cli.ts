import { config } from "./config.js";
import { initStore } from "./store.js";
import { ensureShared, ensureUser } from "./provision.js";

/**
 * One-time provisioning:
 *   npm run provision                 -> shared environment + agent
 *   npm run provision -- <userId>...  -> also pre-provision the named users
 */
async function main() {
  initStore(config.storePath);
  const shared = await ensureShared();
  console.log("[provision] shared resources ready:", shared);

  for (const userId of process.argv.slice(2)) {
    const u = await ensureUser(userId);
    console.log(`[provision] user ${userId} ready:`, u);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
