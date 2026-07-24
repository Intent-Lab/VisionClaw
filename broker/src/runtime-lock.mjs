import {
  chmod,
  mkdir,
  open,
  readFile,
  rm,
} from "node:fs/promises";
import { join } from "node:path";

export class RuntimeLock {
  #stateDirectory;
  #path;
  #pid;
  #isProcessAlive;
  #handle = null;

  constructor({
    stateDirectory,
    pid = process.pid,
    isProcessAlive = defaultIsProcessAlive,
  }) {
    this.#stateDirectory = stateDirectory;
    this.#path = join(stateDirectory, "broker.lock");
    this.#pid = pid;
    this.#isProcessAlive = isProcessAlive;
  }

  async acquire() {
    if (this.#handle) return;
    await mkdir(this.#stateDirectory, { recursive: true, mode: 0o700 });
    await chmod(this.#stateDirectory, 0o700);

    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const handle = await open(this.#path, "wx", 0o600);
        await handle.writeFile(String(this.#pid));
        await handle.sync();
        this.#handle = handle;
        return;
      } catch (error) {
        if (error?.code !== "EEXIST") throw error;
        const owner = await readOwner(this.#path);
        if (owner && this.#isProcessAlive(owner)) {
          throw new Error("VisionClaw broker is already running.");
        }
        await rm(this.#path, { force: true });
      }
    }
    throw new Error("VisionClaw broker lock could not be acquired.");
  }

  async release() {
    const handle = this.#handle;
    this.#handle = null;
    if (!handle) return;
    await handle.close();
    const owner = await readOwner(this.#path);
    if (owner === this.#pid) {
      await rm(this.#path, { force: true });
    }
  }
}

async function readOwner(path) {
  try {
    const value = Number((await readFile(path, "utf8")).trim());
    return Number.isSafeInteger(value) && value > 0 ? value : null;
  } catch {
    return null;
  }
}

function defaultIsProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}
