import { execFile as execFileCallback } from "node:child_process";
import { createHash, X509Certificate } from "node:crypto";
import {
  chmod,
  mkdir,
  readFile,
  rename,
  rm,
} from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const INSPECT = Symbol.for("nodejs.util.inspect.custom");

export class SecretValue {
  #value;

  constructor(value) {
    if (typeof value !== "string" || value.length < 16) {
      throw new Error("A non-empty secret value is required.");
    }
    this.#value = value;
    Object.freeze(this);
  }

  reveal() {
    return this.#value;
  }

  toString() {
    return "<redacted>";
  }

  toJSON() {
    return "<redacted>";
  }

  [INSPECT]() {
    return "<redacted>";
  }
}

export async function ensureBrokerIdentity({
  stateDirectory = join(homedir(), ".visionclaw-broker"),
} = {}) {
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
  await chmod(stateDirectory, 0o700);

  const privateKeyPath = join(stateDirectory, "broker-tls-key.pem");
  const certificatePath = join(stateDirectory, "broker-tls-cert.pem");
  let certificate;

  try {
    certificate = await readFile(certificatePath, "utf8");
    await readFile(privateKeyPath, "utf8");
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    await generateIdentity({
      stateDirectory,
      privateKeyPath,
      certificatePath,
    });
    certificate = await readFile(certificatePath, "utf8");
  }

  await chmod(privateKeyPath, 0o600);
  await chmod(certificatePath, 0o644);

  const x509 = new X509Certificate(certificate);
  const publicKeyDER = x509.publicKey.export({ type: "spki", format: "der" });
  const pin = createHash("sha256").update(publicKeyDER).digest();

  return Object.freeze({
    brokerID: `broker_${pin.toString("base64url")}`,
    certificatePath,
    privateKeyPath,
    tlsPinSHA256: pin.toString("hex"),
  });
}

async function generateIdentity({
  stateDirectory,
  privateKeyPath,
  certificatePath,
}) {
  const suffix = `${process.pid}-${Date.now()}`;
  const temporaryKeyPath = join(stateDirectory, `.broker-tls-key-${suffix}.pem`);
  const temporaryCertificatePath = join(
    stateDirectory,
    `.broker-tls-cert-${suffix}.pem`,
  );

  try {
    await execFile("openssl", [
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-sha256",
      "-nodes",
      "-days",
      "3650",
      "-subj",
      "/CN=VisionClaw Broker",
      "-addext",
      "subjectAltName=DNS:visionclaw.local,DNS:localhost,IP:127.0.0.1",
      "-keyout",
      temporaryKeyPath,
      "-out",
      temporaryCertificatePath,
    ], {
      env: { ...process.env },
      maxBuffer: 64 * 1024,
    });
    await chmod(temporaryKeyPath, 0o600);
    await chmod(temporaryCertificatePath, 0o644);
    await rename(temporaryKeyPath, privateKeyPath);
    await rename(temporaryCertificatePath, certificatePath);
  } finally {
    await rm(temporaryKeyPath, { force: true });
    await rm(temporaryCertificatePath, { force: true });
  }
}

export async function loadOpenClawGatewayConfig({
  configPath = join(homedir(), ".openclaw", "openclaw.json"),
  environment = process.env,
} = {}) {
  const raw = await readFile(configPath, "utf8");
  const parsed = JSON.parse(raw);
  const port = Number(parsed?.gateway?.port ?? 16743);
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error("OpenClaw gateway port is invalid.");
  }
  const authMode = parsed?.gateway?.auth?.mode;
  const configuredToken = parsed?.gateway?.auth?.token;
  const token = environment.OPENCLAW_GATEWAY_TOKEN || configuredToken;
  if (authMode !== "token" || typeof token !== "string" || token.length < 16) {
    throw new Error("OpenClaw gateway token authentication is required.");
  }

  return Object.freeze({
    url: `ws://127.0.0.1:${port}`,
    token: new SecretValue(token),
  });
}
