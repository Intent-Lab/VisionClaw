import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readlinkSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { CodexWorkspaceManager } from "../src/codex-workspace-manager.mjs";

function git(cwd, ...arguments_) {
  return execFileSync("git", ["-C", cwd, ...arguments_], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function initializeRepository(source) {
  mkdirSync(source, { recursive: true });
  git(source, "init");
  git(source, "config", "user.name", "VisionClaw Test");
  git(source, "config", "user.email", "visionclaw@example.invalid");
  git(source, "config", "commit.gpgSign", "false");
}

test("isolated Codex workspaces are detached Git worktrees without source-only changes", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "visionclaw-worktree-"));
  const source = path.join(directory, "source");
  const worktrees = path.join(directory, "isolated");
  try {
    initializeRepository(source);
    writeFileSync(path.join(source, "tracked.txt"), "committed\n");
    git(source, "add", "tracked.txt");
    git(source, "commit", "-m", "initial");

    writeFileSync(path.join(source, "tracked.txt"), "source dirty change\n");
    writeFileSync(path.join(source, "source-only.txt"), "must not inherit\n");

    const manager = new CodexWorkspaceManager({
      rootDirectory: worktrees,
    });
    const plan = await manager.plan({
      actionID: "vca_test-isolation",
      sourceCwd: source,
    });
    await manager.ensure({
      sourceCwd: source,
      ...plan,
    });

    assert.notEqual(path.resolve(plan.workspacePath), path.resolve(source));
    assert.equal(
      readFileSync(path.join(plan.workspacePath, "tracked.txt"), "utf8"),
      "committed\n",
    );
    assert.throws(
      () => readFileSync(path.join(plan.workspacePath, "source-only.txt")),
      /ENOENT/,
    );
    assert.equal(git(plan.workspacePath, "rev-parse", "HEAD"), plan.gitRevision);

    const restartedManager = new CodexWorkspaceManager({
      rootDirectory: worktrees,
    });
    await restartedManager.ensure({
      sourceCwd: source,
      ...plan,
    });
    await restartedManager.verify({
      sourceCwd: source,
      ...plan,
    });
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("isolation never executes repository hooks or checkout filters and never follows tree symlinks", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "visionclaw-hostile-git-"));
  const source = path.join(directory, "source");
  const worktrees = path.join(directory, "isolated");
  const hookMarker = path.join(directory, "hook-escaped");
  const filterMarker = path.join(directory, "filter-escaped");
  const symlinkTarget = path.join(directory, "symlink-target");
  try {
    initializeRepository(source);
    writeFileSync(
      path.join(source, ".gitattributes"),
      "filtered.txt filter=visionclaw-escape\n",
    );
    writeFileSync(path.join(source, "filtered.txt"), "raw committed bytes\n");
    symlinkSync(symlinkTarget, path.join(source, "outside-link"));
    git(source, "add", ".gitattributes", "filtered.txt", "outside-link");
    git(source, "commit", "-m", "hostile checkout configuration");

    const hooks = path.join(directory, "hooks");
    mkdirSync(hooks);
    const postCheckout = path.join(hooks, "post-checkout");
    writeFileSync(
      postCheckout,
      [
        "#!/usr/bin/env node",
        `require("node:fs").writeFileSync(${JSON.stringify(hookMarker)}, "ran");`,
        "",
      ].join("\n"),
    );
    chmodSync(postCheckout, 0o755);
    const smudge = path.join(directory, "smudge");
    writeFileSync(
      smudge,
      [
        "#!/usr/bin/env node",
        "const fs = require(\"node:fs\");",
        `fs.writeFileSync(${JSON.stringify(filterMarker)}, "ran");`,
        "process.stdin.pipe(process.stdout);",
        "",
      ].join("\n"),
    );
    chmodSync(smudge, 0o755);
    git(source, "config", "core.hooksPath", hooks);
    git(source, "config", "filter.visionclaw-escape.smudge", smudge);
    git(
      source,
      "config",
      "filter.visionclaw-escape.process",
      `${smudge} --process`,
    );
    git(source, "config", "filter.visionclaw-escape.required", "true");

    const manager = new CodexWorkspaceManager({
      rootDirectory: worktrees,
    });
    const plan = await manager.plan({
      actionID: "vca_hostile-checkout",
      sourceCwd: source,
    });
    await manager.ensure({ sourceCwd: source, ...plan });

    assert.equal(existsSync(hookMarker), false);
    assert.equal(existsSync(filterMarker), false);
    assert.equal(existsSync(symlinkTarget), false);
    assert.equal(
      readFileSync(path.join(plan.workspacePath, "filtered.txt"), "utf8"),
      "raw committed bytes\n",
    );
    assert.equal(
      readlinkSync(path.join(plan.workspacePath, "outside-link")),
      symlinkTarget,
    );
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

test("a precreated workspace symlink cannot redirect isolation writes", async () => {
  const directory = mkdtempSync(path.join(tmpdir(), "visionclaw-worktree-link-"));
  const source = path.join(directory, "source");
  const worktrees = path.join(directory, "isolated");
  const outside = path.join(directory, "outside");
  try {
    initializeRepository(source);
    writeFileSync(path.join(source, "tracked.txt"), "committed\n");
    git(source, "add", "tracked.txt");
    git(source, "commit", "-m", "initial");
    mkdirSync(outside);

    const manager = new CodexWorkspaceManager({
      rootDirectory: worktrees,
    });
    const plan = await manager.plan({
      actionID: "vca_symlink-redirect",
      sourceCwd: source,
    });
    symlinkSync(outside, plan.workspacePath);

    await assert.rejects(
      manager.ensure({ sourceCwd: source, ...plan }),
      /path changed|isolated|workspace/i,
    );
    assert.deepEqual(
      readFileNames(outside),
      [],
    );
  } finally {
    rmSync(directory, { force: true, recursive: true });
  }
});

function readFileNames(directory) {
  return readdirSync(directory);
}
