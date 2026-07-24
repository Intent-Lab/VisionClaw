import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  ensureBrokerIdentity,
  loadOpenClawGatewayConfig,
  SecretValue,
} from "../src/runtime-state.mjs";

test("broker identity is stable, private on disk, and exposes only its public pin", async () => {
  const stateDirectory = await mkdtemp(join(tmpdir(), "visionclaw-broker-"));

  const first = await ensureBrokerIdentity({ stateDirectory });
  const second = await ensureBrokerIdentity({ stateDirectory });

  assert.equal(first.brokerID, second.brokerID);
  assert.equal(first.tlsPinSHA256, second.tlsPinSHA256);
  assert.match(first.brokerID, /^broker_[A-Za-z0-9_-]{32,}$/);
  assert.match(first.tlsPinSHA256, /^[a-f0-9]{64}$/);
  assert.equal((await stat(first.privateKeyPath)).mode & 0o777, 0o600);
  assert.equal((await stat(first.certificatePath)).mode & 0o777, 0o644);
  assert.doesNotMatch(JSON.stringify(first), /PRIVATE KEY/);
});

test("OpenClaw gateway configuration stays loopback and its token is redacted", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-openclaw-"));
  const configPath = join(directory, "openclaw.json");
  await writeFile(configPath, JSON.stringify({
    gateway: {
      auth: { mode: "token", token: "owner-token-that-must-never-leave-the-mac" },
      bind: "lan",
      port: 16743,
    },
  }));

  const config = await loadOpenClawGatewayConfig({ configPath });

  assert.equal(config.url, "ws://127.0.0.1:16743");
  assert.equal(config.token.reveal(), "owner-token-that-must-never-leave-the-mac");
  assert.equal(String(config.token), "<redacted>");
  assert.equal(JSON.stringify(config), "{\"url\":\"ws://127.0.0.1:16743\",\"token\":\"<redacted>\"}");
});

test("gateway config rejects missing auth and unsafe ports without leaking values", async () => {
  const directory = await mkdtemp(join(tmpdir(), "visionclaw-openclaw-invalid-"));
  const configPath = join(directory, "openclaw.json");
  await writeFile(configPath, JSON.stringify({
    gateway: { auth: { mode: "none" }, port: 99999 },
  }));

  await assert.rejects(
    loadOpenClawGatewayConfig({ configPath }),
    /token authentication|port/i,
  );

  const secret = new SecretValue("do-not-print-me-ever");
  assert.equal(JSON.stringify({ secret }), "{\"secret\":\"<redacted>\"}");
  assert.doesNotMatch(await readFile(configPath, "utf8"), /do-not-print-me/);
});
