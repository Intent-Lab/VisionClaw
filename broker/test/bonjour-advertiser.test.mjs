import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import { BonjourAdvertiser } from "../src/bonjour-advertiser.mjs";

test("Bonjour advertises only public discovery hints and stops its child", async () => {
  const calls = [];
  const child = new EventEmitter();
  child.killCalls = [];
  child.kill = (signal) => {
    child.killCalls.push(signal);
    return true;
  };
  const spawn = (command, args, options) => {
    calls.push({ command, args, options });
    return child;
  };
  const advertiser = new BonjourAdvertiser({
    spawn,
    brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
    displayName: "Jaack VisionClaw",
    port: 38443,
  });

  advertiser.start();
  advertiser.stop();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].command, "/usr/bin/dns-sd");
  assert.deepEqual(calls[0].args, [
    "-R",
    "Jaack VisionClaw",
    "_visionclaw._tcp",
    "local.",
    "38443",
    "id=broker_abcdefghijklmnopqrstuvwxyz0123456789",
    "v=1",
    "tls=1",
  ]);
  assert.equal(calls[0].options.shell, false);
  assert.deepEqual(child.killCalls, ["SIGTERM"]);
  assert.doesNotMatch(JSON.stringify(calls), /token|secret|pin|credential/i);
});

test("Bonjour rejects unsafe identity, names, and ports", () => {
  for (const input of [
    {
      brokerID: "bad id",
      displayName: "VisionClaw",
      port: 38443,
    },
    {
      brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
      displayName: "VisionClaw\nInjected",
      port: 38443,
    },
    {
      brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
      displayName: "VisionClaw",
      port: 70_000,
    },
  ]) {
    assert.throws(
      () => new BonjourAdvertiser({ ...input, spawn() {} }),
      /invalid/i,
    );
  }
});

test("Bonjour publisher surfaces early process failure without retry storms", async () => {
  const child = new EventEmitter();
  child.kill = () => true;
  const advertiser = new BonjourAdvertiser({
    spawn: () => child,
    brokerID: "broker_abcdefghijklmnopqrstuvwxyz0123456789",
    displayName: "VisionClaw",
    port: 38443,
  });

  const failure = new Promise((resolve) => advertiser.once("error", resolve));
  advertiser.start();
  child.emit("error", new Error("dns-sd unavailable"));

  assert.match((await failure).message, /unavailable/i);
  assert.throws(() => advertiser.start(), /failed|stopped/i);
});
