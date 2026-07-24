import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";

import { renderTerminalQRCode } from "../src/terminal-qr.mjs";

test("QR renderer sends the pairing URI over stdin, never process arguments", async () => {
  const calls = [];
  const spawn = (command, args, options) => {
    const child = new EventEmitter();
    child.stdin = new PassThrough();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    let input = "";
    child.stdin.on("data", (chunk) => {
      input += chunk.toString("utf8");
    });
    child.stdin.on("finish", () => {
      child.stdout.end("QR BLOCKS");
      child.emit("close", 0);
      calls.push({ command, args, options, input });
    });
    return child;
  };
  const uri = "visionclaw://pair?payload=secret-pairing-payload";

  const rendered = await renderTerminalQRCode(uri, { spawn });

  assert.equal(rendered, "QR BLOCKS");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, "/opt/homebrew/bin/qrencode");
  assert.deepEqual(calls[0].args, ["-t", "UTF8", "-r", "-"]);
  assert.equal(calls[0].options.shell, false);
  assert.equal(calls[0].input, uri);
  assert.doesNotMatch(JSON.stringify(calls[0].args), /secret-pairing-payload/);
});

test("QR renderer bounds input and returns a safe error", async () => {
  await assert.rejects(
    renderTerminalQRCode("x".repeat(20_000), { spawn() {} }),
    /invalid|long/i,
  );
});
