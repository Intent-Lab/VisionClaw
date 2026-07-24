import {
  execFile as execFileCallback,
  spawn as spawnCallback,
} from "node:child_process";
import { createHash } from "node:crypto";
import {
  chmod,
  mkdir,
  readFile,
  realpath,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const GIT_REVISION_PATTERN = /^[0-9a-f]{40,64}$/;
const MAX_BLOB_BYTES = 64 * 1024 * 1024;
const MAX_ENTRY_COUNT = 100_000;
const MAX_TOTAL_BLOB_BYTES = 512 * 1024 * 1024;
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: true });

export class CodexWorkspaceManager {
  #rootDirectory;
  #execFile;
  #gitExecutable;
  #spawn;

  constructor({
    rootDirectory,
    execFileImpl = execFile,
    gitExecutable = "/usr/bin/git",
    spawnImpl = spawnCallback,
  } = {}) {
    if (!path.isAbsolute(String(rootDirectory ?? ""))) {
      throw new Error("Codex isolated-worktree root must be an absolute path.");
    }
    if (!path.isAbsolute(String(gitExecutable ?? ""))) {
      throw new Error("Codex Git executable must be an absolute path.");
    }
    this.#rootDirectory = path.resolve(rootDirectory);
    this.#execFile = execFileImpl;
    this.#gitExecutable = path.resolve(gitExecutable);
    this.#spawn = spawnImpl;
  }

  async plan({ actionID, sourceCwd }) {
    const cleanActionID = validateActionID(actionID);
    const root = await this.#ensureRoot();
    const source = await this.#sourceRepository(sourceCwd);
    const workspacePath = path.join(
      root,
      `worktree-${createHash("sha256")
        .update(cleanActionID)
        .digest("hex")
        .slice(0, 32)}`,
    );
    validateWorkspaceLocation({
      repositoryRoot: source.repositoryRoot,
      rootDirectory: root,
      sourceCwd: source.sourceCwd,
      workspacePath,
    });
    return Object.freeze({
      workspacePath,
      gitRevision: source.gitRevision,
    });
  }

  async ensure({ sourceCwd, workspacePath, gitRevision }) {
    const expected = await this.#expectedWorkspace({
      sourceCwd,
      workspacePath,
      gitRevision,
    });
    if (await exists(expected.workspacePath)) {
      return this.verify(expected);
    }
    try {
      await this.#git(expected.repositoryRoot, [
        "worktree",
        "add",
        "--detach",
        "--no-checkout",
        expected.workspacePath,
        expected.gitRevision,
      ]);
      await this.#git(expected.workspacePath, [
        "read-tree",
        "--reset",
        expected.gitRevision,
      ]);
      await this.#materializeTree(expected);
      await writeFile(
        completionMarkerPath(expected.workspacePath),
        `${expected.gitRevision}\n`,
        {
          encoding: "utf8",
          flag: "wx",
          mode: 0o600,
        },
      );
    } catch {
      throw new Error(
        "Could not create the isolated Codex Git worktree.",
      );
    }
    return this.verify(expected);
  }

  async verify({ sourceCwd, workspacePath, gitRevision }) {
    const expected = await this.#expectedWorkspace({
      sourceCwd,
      workspacePath,
      gitRevision,
    });
    let canonicalWorkspace;
    try {
      canonicalWorkspace = await realpath(expected.workspacePath);
    } catch {
      throw new Error("The isolated Codex workspace is unavailable.");
    }
    if (canonicalWorkspace !== expected.workspacePath) {
      throw new Error("The isolated Codex workspace path changed.");
    }
    validateWorkspaceLocation({
      repositoryRoot: expected.repositoryRoot,
      rootDirectory: expected.rootDirectory,
      sourceCwd: expected.sourceCwd,
      workspacePath: canonicalWorkspace,
    });

    const workspaceRoot = await this.#canonicalGitPath(
      canonicalWorkspace,
      ["rev-parse", "--show-toplevel"],
    );
    if (workspaceRoot !== canonicalWorkspace) {
      throw new Error("The isolated Codex workspace is not a Git worktree.");
    }
    const workspaceRevision = await this.#git(canonicalWorkspace, [
      "rev-parse",
      "--verify",
      "HEAD",
    ]);
    if (workspaceRevision !== expected.gitRevision) {
      throw new Error("The isolated Codex workspace revision changed.");
    }
    const sourceCommonDirectory = await this.#canonicalGitPath(
      expected.repositoryRoot,
      ["rev-parse", "--git-common-dir"],
    );
    const workspaceCommonDirectory = await this.#canonicalGitPath(
      canonicalWorkspace,
      ["rev-parse", "--git-common-dir"],
    );
    if (sourceCommonDirectory !== workspaceCommonDirectory) {
      throw new Error(
        "The isolated Codex workspace belongs to another repository.",
      );
    }
    let marker;
    try {
      marker = await readFile(
        completionMarkerPath(canonicalWorkspace),
        "utf8",
      );
    } catch {
      throw new Error("The isolated Codex workspace is incomplete.");
    }
    if (marker !== `${expected.gitRevision}\n`) {
      throw new Error("The isolated Codex workspace marker is invalid.");
    }
    return Object.freeze({
      workspacePath: canonicalWorkspace,
      gitRevision: expected.gitRevision,
    });
  }

  async #expectedWorkspace({ sourceCwd, workspacePath, gitRevision }) {
    const root = await this.#ensureRoot();
    const source = await this.#sourceRepository(sourceCwd);
    const revision = validateGitRevision(gitRevision);
    if (source.gitRevision !== revision) {
      throw new Error("The source Git revision changed.");
    }
    const target = path.resolve(String(workspacePath ?? ""));
    validateWorkspaceLocation({
      repositoryRoot: source.repositoryRoot,
      rootDirectory: root,
      sourceCwd: source.sourceCwd,
      workspacePath: target,
    });
    return {
      ...source,
      rootDirectory: root,
      workspacePath: target,
      gitRevision: revision,
    };
  }

  async #sourceRepository(sourceCwd) {
    if (!path.isAbsolute(String(sourceCwd ?? ""))) {
      throw new Error("Codex source workspace must be an absolute path.");
    }
    let source;
    try {
      source = await realpath(path.resolve(sourceCwd));
      const metadata = await stat(source);
      if (!metadata.isDirectory()) throw new Error("not a directory");
    } catch {
      throw new Error("Codex source workspace is unavailable.");
    }
    let repositoryRoot;
    let gitRevision;
    try {
      repositoryRoot = await this.#canonicalGitPath(
        source,
        ["rev-parse", "--show-toplevel"],
      );
      gitRevision = validateGitRevision(
        await this.#git(source, ["rev-parse", "--verify", "HEAD"]),
      );
    } catch {
      throw new Error(
        "Codex continuation requires a committed Git source workspace.",
      );
    }
    if (!isSameOrDescendant(repositoryRoot, source)) {
      throw new Error("Codex source workspace is outside its Git repository.");
    }
    return {
      sourceCwd: source,
      repositoryRoot,
      gitRevision,
    };
  }

  async #ensureRoot() {
    await mkdir(this.#rootDirectory, { recursive: true, mode: 0o700 });
    await chmod(this.#rootDirectory, 0o700);
    const root = await realpath(this.#rootDirectory);
    const disabledHooks = path.join(root, ".disabled-hooks");
    await mkdir(disabledHooks, { recursive: true, mode: 0o700 });
    await chmod(disabledHooks, 0o700);
    return root;
  }

  async #canonicalGitPath(cwd, arguments_) {
    const result = await this.#git(cwd, arguments_);
    const absolute = path.isAbsolute(result)
      ? result
      : path.resolve(cwd, result);
    return realpath(absolute);
  }

  async #git(cwd, arguments_) {
    const result = await this.#execFile(
      this.#gitExecutable,
      this.#gitArguments(cwd, arguments_),
      {
        encoding: "utf8",
        env: safeGitEnvironment(),
        maxBuffer: 1024 * 1024,
        timeout: 15_000,
      },
    );
    return String(result.stdout ?? "").trim();
  }

  async #gitBuffer(cwd, arguments_) {
    const result = await this.#execFile(
      this.#gitExecutable,
      this.#gitArguments(cwd, arguments_),
      {
        encoding: "buffer",
        env: safeGitEnvironment(),
        maxBuffer: 32 * 1024 * 1024,
        timeout: 30_000,
      },
    );
    return Buffer.from(result.stdout ?? Buffer.alloc(0));
  }

  #gitArguments(cwd, arguments_) {
    return [
      "-c",
      `core.hooksPath=${path.join(this.#rootDirectory, ".disabled-hooks")}`,
      "-c",
      "core.fsmonitor=false",
      "-c",
      "core.untrackedCache=false",
      "-C",
      cwd,
      ...arguments_,
    ];
  }

  async #materializeTree(expected) {
    const treeOutput = await this.#gitBuffer(
      expected.repositoryRoot,
      [
        "ls-tree",
        "-r",
        "-z",
        "--full-tree",
        expected.gitRevision,
      ],
    );
    const entries = parseTreeEntries(treeOutput);
    for (const entry of entries) {
      if (entry.type !== "commit") continue;
      await mkdir(
        safeMaterializationPath(expected.workspacePath, entry.path),
        { recursive: true, mode: 0o755 },
      );
    }
    const blobs = entries.filter((entry) => entry.type === "blob");
    if (blobs.length === 0) return;

    const child = this.#spawn(
      this.#gitExecutable,
      this.#gitArguments(expected.repositoryRoot, ["cat-file", "--batch"]),
      {
        env: safeGitEnvironment(),
        stdio: ["pipe", "pipe", "pipe"],
      },
    );
    const exit = waitForChild(child);
    const reader = new StreamBufferReader(child.stdout);
    child.stdin.on("error", () => {
      // The bounded child exit result below remains the authoritative failure.
    });
    child.stdin.end(blobs.map((entry) => `${entry.objectID}\n`).join(""));
    let totalBlobBytes = 0;
    try {
      for (const entry of blobs) {
        const header = await reader.readLine();
        const match = /^([0-9a-f]{40,64}) blob ([0-9]+)$/.exec(header);
        const length = Number(match?.[2]);
        if (
          !match
          || match[1] !== entry.objectID
          || !Number.isSafeInteger(length)
          || length < 0
          || length > MAX_BLOB_BYTES
          || totalBlobBytes + length > MAX_TOTAL_BLOB_BYTES
        ) {
          throw new Error("Git returned an invalid blob header.");
        }
        totalBlobBytes += length;
        const content = await reader.readExactly(length);
        if ((await reader.readExactly(1))[0] !== 0x0a) {
          throw new Error("Git returned an invalid blob terminator.");
        }
        await materializeEntry({
          entry,
          content,
          workspacePath: expected.workspacePath,
        });
      }
      const result = await exit;
      if (result.code !== 0 || result.signal) {
        throw new Error("Git object materialization failed.");
      }
    } catch (error) {
      child.kill("SIGKILL");
      await exit.catch(() => {});
      throw error;
    }
  }
}

class StreamBufferReader {
  #iterator;
  #chunks = [];
  #available = 0;
  #ended = false;

  constructor(stream) {
    this.#iterator = stream[Symbol.asyncIterator]();
  }

  async readLine() {
    const parts = [];
    let length = 0;
    for (;;) {
      while (this.#available === 0) await this.#readMore();
      const first = this.#chunks[0];
      const newline = first.indexOf(0x0a);
      if (newline >= 0) {
        parts.push(first.subarray(0, newline));
        this.#chunks[0] = first.subarray(newline + 1);
        this.#available -= newline + 1;
        if (this.#chunks[0].length === 0) this.#chunks.shift();
        return Buffer.concat(parts, length + newline).toString("ascii");
      }
      parts.push(first);
      length += first.length;
      this.#available -= first.length;
      this.#chunks.shift();
      if (length > 1_024) throw new Error("Git blob header is too long.");
    }
  }

  async readExactly(length) {
    if (!Number.isSafeInteger(length) || length < 0) {
      throw new Error("Git blob length is invalid.");
    }
    while (this.#available < length) await this.#readMore();
    const value = Buffer.allocUnsafe(length);
    let written = 0;
    while (written < length) {
      const first = this.#chunks[0];
      const consumed = Math.min(first.length, length - written);
      first.copy(value, written, 0, consumed);
      written += consumed;
      this.#available -= consumed;
      if (consumed === first.length) {
        this.#chunks.shift();
      } else {
        this.#chunks[0] = first.subarray(consumed);
      }
    }
    return value;
  }

  async #readMore() {
    if (this.#ended) throw new Error("Git object stream ended early.");
    const next = await this.#iterator.next();
    if (next.done) {
      this.#ended = true;
      throw new Error("Git object stream ended early.");
    }
    const chunk = Buffer.from(next.value);
    this.#chunks.push(chunk);
    this.#available += chunk.length;
  }
}

function parseTreeEntries(output) {
  const entries = [];
  let start = 0;
  while (start < output.length) {
    const end = output.indexOf(0, start);
    if (end < 0) throw new Error("Git tree output is not NUL terminated.");
    const record = output.subarray(start, end);
    start = end + 1;
    if (record.length === 0) continue;
    const separator = record.indexOf(0x09);
    if (separator < 0) throw new Error("Git tree entry is invalid.");
    const header = record.subarray(0, separator).toString("ascii");
    const match = /^(100644|100755|120000|160000) (blob|commit) ([0-9a-f]{40,64})$/
      .exec(header);
    if (!match) throw new Error("Git tree entry metadata is invalid.");
    if (
      (match[1] === "160000" && match[2] !== "commit")
      || (match[1] !== "160000" && match[2] !== "blob")
    ) {
      throw new Error("Git tree entry type is invalid.");
    }
    let entryPath;
    try {
      entryPath = UTF8_DECODER.decode(record.subarray(separator + 1));
    } catch {
      throw new Error("Git tree path is not valid UTF-8.");
    }
    validateTreePath(entryPath);
    entries.push({
      mode: match[1],
      type: match[2],
      objectID: match[3],
      path: entryPath,
    });
    if (entries.length > MAX_ENTRY_COUNT) {
      throw new Error("Git tree contains too many entries.");
    }
  }
  return entries;
}

async function materializeEntry({ entry, content, workspacePath }) {
  const target = safeMaterializationPath(workspacePath, entry.path);
  await mkdir(path.dirname(target), { recursive: true, mode: 0o755 });
  if (entry.mode === "120000") {
    if (content.includes(0)) {
      throw new Error("Git symlink target is invalid.");
    }
    await symlink(content, target);
    return;
  }
  await writeFile(target, content, {
    flag: "wx",
    mode: entry.mode === "100755" ? 0o755 : 0o644,
  });
}

function safeMaterializationPath(workspacePath, entryPath) {
  validateTreePath(entryPath);
  const target = path.resolve(workspacePath, ...entryPath.split("/"));
  if (
    target === workspacePath
    || !isSameOrDescendant(workspacePath, target)
  ) {
    throw new Error("Git tree path escapes the isolated workspace.");
  }
  return target;
}

function validateTreePath(value) {
  if (
    !value
    || value.length > 8_192
    || value.startsWith("/")
    || value.split("/").some((component) => (
      !component
      || component === "."
      || component === ".."
      || component.toLowerCase() === ".git"
    ))
  ) {
    throw new Error("Git tree path is unsafe.");
  }
}

function completionMarkerPath(workspacePath) {
  return `${workspacePath}.ready`;
}

function waitForChild(child) {
  let stderrLength = 0;
  child.stderr.on("data", (chunk) => {
    stderrLength += chunk.length;
    if (stderrLength > 64 * 1024) child.kill("SIGKILL");
  });
  return new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
}

function safeGitEnvironment() {
  const environment = { ...process.env };
  for (const key of Object.keys(environment)) {
    if (key.startsWith("GIT_") || key.startsWith("GCM_")) {
      delete environment[key];
    }
  }
  environment.GIT_CONFIG_NOSYSTEM = "1";
  environment.GIT_CONFIG_GLOBAL = "/dev/null";
  environment.GIT_TERMINAL_PROMPT = "0";
  environment.GCM_INTERACTIVE = "never";
  environment.LC_ALL = "C";
  return environment;
}

function validateWorkspaceLocation({
  repositoryRoot,
  rootDirectory,
  sourceCwd,
  workspacePath,
}) {
  const relative = path.relative(rootDirectory, workspacePath);
  if (
    !relative
    || path.isAbsolute(relative)
    || relative === ".."
    || relative.startsWith(`..${path.sep}`)
    || relative.includes(path.sep)
  ) {
    throw new Error("Codex isolated workspace path is outside its private root.");
  }
  if (
    workspacePath === sourceCwd
    || workspacePath === repositoryRoot
    || isSameOrDescendant(repositoryRoot, workspacePath)
  ) {
    throw new Error(
      "Codex isolated workspace must be distinct from the source workspace.",
    );
  }
}

function validateActionID(value) {
  const actionID = String(value ?? "");
  if (!/^[A-Za-z0-9_-]{3,200}$/.test(actionID)) {
    throw new Error("Codex action identifier is invalid.");
  }
  return actionID;
}

function validateGitRevision(value) {
  const revision = String(value ?? "").toLowerCase();
  if (!GIT_REVISION_PATTERN.test(revision)) {
    throw new Error("Codex Git revision is invalid.");
  }
  return revision;
}

function isSameOrDescendant(parent, candidate) {
  const relative = path.relative(parent, candidate);
  return !relative
    || (!path.isAbsolute(relative)
      && relative !== ".."
      && !relative.startsWith(`..${path.sep}`));
}

async function exists(target) {
  try {
    await stat(target);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}
