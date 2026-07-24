import {
  createHash,
  createHmac,
  createPublicKey,
  randomBytes,
  sign,
  timingSafeEqual,
  verify,
} from "node:crypto";

const DEFAULT_PROOF_SKEW_MILLISECONDS = 30_000;

export function canonicalJSONString(value) {
  return JSON.stringify(canonicalValue(value));
}

function canonicalValue(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new TypeError("Canonical JSON does not allow non-finite numbers.");
    }
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(canonicalValue);
  }
  if (typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) {
      const member = value[key];
      if (member === undefined) {
        throw new TypeError("Canonical JSON does not allow undefined values.");
      }
      result[key] = canonicalValue(member);
    }
    return result;
  }
  throw new TypeError(`Canonical JSON does not allow ${typeof value}.`);
}

export function parseCanonicalJSON(raw) {
  if (typeof raw !== "string" || raw.length === 0) {
    throw new TypeError("A canonical JSON body is required.");
  }
  const parsed = JSON.parse(raw);
  if (canonicalJSONString(parsed) !== raw) {
    throw new Error("Request body must be canonical JSON with unique sorted keys.");
  }
  return parsed;
}

export function sha256Base64URL(value) {
  return createHash("sha256").update(value).digest("base64url");
}

export function publicKeyThumbprint(publicKeyDER) {
  return sha256Base64URL(Buffer.from(publicKeyDER));
}

export function createDeviceRequestProof(request, privateKey) {
  return sign(
    "sha256",
    Buffer.from(canonicalJSONString(request)),
    privateKey,
  ).toString("base64url");
}

export function verifyDeviceRequestProof({
  request,
  proof,
  publicKey,
  replayGuard,
  now = Date.now(),
  maxClockSkewMilliseconds = DEFAULT_PROOF_SKEW_MILLISECONDS,
}) {
  const timestamp = Number(request?.timestamp);
  if (!Number.isSafeInteger(timestamp)) {
    throw new Error("Device proof timestamp is invalid.");
  }
  if (Math.abs(now - timestamp) > maxClockSkewMilliseconds) {
    throw new Error("Device proof timestamp is outside the allowed clock window.");
  }
  if (typeof request?.nonce !== "string" || request.nonce.length < 7) {
    throw new Error("Device proof nonce is invalid.");
  }
  const signature = Buffer.from(String(proof), "base64url");
  const valid = verify(
    "sha256",
    Buffer.from(canonicalJSONString(request)),
    publicKey,
    signature,
  );
  if (!valid) {
    throw new Error("Device proof signature is invalid.");
  }
  replayGuard.consume(
    `${request.pairingID}:${request.nonce}`,
    timestamp + maxClockSkewMilliseconds,
    now,
  );
}

export class ReplayGuard {
  #seen = new Map();
  #now;

  constructor({ now = Date.now } = {}) {
    this.#now = now;
  }

  consume(key, expiresAt, now = this.#now()) {
    this.prune(now);
    if (this.#seen.has(key)) {
      throw new Error("Request replay was rejected.");
    }
    this.#seen.set(key, expiresAt);
  }

  prune(now = this.#now()) {
    for (const [key, expiry] of this.#seen) {
      if (expiry <= now) {
        this.#seen.delete(key);
      }
    }
  }
}

export class PairingManager {
  #brokerID;
  #endpoint;
  #tlsPinSHA256;
  #now;
  #offers = new Map();

  constructor({
    brokerID,
    endpoint,
    tlsPinSHA256,
    now = Date.now,
  }) {
    if (!brokerID || !endpoint || !/^[a-f0-9]{64}$/i.test(tlsPinSHA256)) {
      throw new Error("Broker identity, endpoint, and a SHA-256 TLS pin are required.");
    }
    this.#brokerID = brokerID;
    this.#endpoint = endpoint;
    this.#tlsPinSHA256 = tlsPinSHA256.toLowerCase();
    this.#now = now;
  }

  begin({ ttlMilliseconds = 120_000 } = {}) {
    if (!Number.isSafeInteger(ttlMilliseconds) || ttlMilliseconds < 10_000) {
      throw new Error("Pairing TTL must be at least ten seconds.");
    }
    const now = this.#now();
    for (const [secret, offer] of this.#offers) {
      if (offer.used || offer.expiresAt <= now) {
        this.#offers.delete(secret);
        continue;
      }
      throw new Error("A pairing offer is already active.");
    }
    const pairingSecret = randomBytes(32).toString("base64url");
    const expiresAt = now + ttlMilliseconds;
    const offer = {
      version: 1,
      brokerID: this.#brokerID,
      endpoint: this.#endpoint,
      tlsPinSHA256: this.#tlsPinSHA256,
      pairingSecret,
      expiresAt,
    };
    this.#offers.set(pairingSecret, { ...offer, used: false });
    return offer;
  }

  consume({
    pairingSecret,
    phonePublicKeyDER,
    deviceName = "iPhone",
    now = this.#now(),
  }) {
    const offer = this.#offers.get(pairingSecret);
    if (!offer || offer.used) {
      throw new Error("Pairing secret is invalid or was already used.");
    }
    if (offer.expiresAt <= now) {
      this.#offers.delete(pairingSecret);
      throw new Error("Pairing secret expired.");
    }
    const publicKeyDER = Buffer.from(phonePublicKeyDER);
    const phonePublicKey = createPublicKey({
      key: publicKeyDER,
      type: "spki",
      format: "der",
    });
    if (
      phonePublicKey.asymmetricKeyType !== "ec"
      || phonePublicKey.asymmetricKeyDetails?.namedCurve !== "prime256v1"
    ) {
      throw new Error("Phone signing key must use P-256.");
    }
    offer.used = true;
    return {
      pairingID: randomBytes(18).toString("base64url"),
      brokerID: this.#brokerID,
      phoneKeyThumbprint: publicKeyThumbprint(publicKeyDER),
      phonePublicKeyDER: publicKeyDER,
      deviceName: String(deviceName).slice(0, 80),
      pairedAt: now,
    };
  }
}

export class CapabilityIssuer {
  #issuer;
  #audience;
  #signingKey;
  #now;
  #consumptionStore;

  constructor({
    issuer,
    audience,
    signingKey,
    consumptionStore = new ReplayGuard(),
    now = Date.now,
  }) {
    if (!issuer || !audience || Buffer.byteLength(signingKey) < 32) {
      throw new Error("Capability issuer requires identity, audience, and a 256-bit key.");
    }
    this.#issuer = issuer;
    this.#audience = audience;
    this.#signingKey = Buffer.from(signingKey);
    this.#consumptionStore = consumptionStore;
    this.#now = now;
  }

  issue({
    pairingID,
    phoneKeyThumbprint,
    scope,
    method,
    path,
    bodyHash,
    ttlMilliseconds = 30_000,
  }) {
    if (!pairingID || !phoneKeyThumbprint || !scope || !method || !path || !bodyHash) {
      throw new Error("Capability claims are incomplete.");
    }
    const now = this.#now();
    const payload = {
      aud: this.#audience,
      bodyHash,
      cnf: { jkt: phoneKeyThumbprint },
      exp: now + ttlMilliseconds,
      iat: now,
      iss: this.#issuer,
      jti: randomBytes(18).toString("base64url"),
      method: method.toUpperCase(),
      nbf: now,
      path,
      scope,
      sub: pairingID,
    };
    const header = { alg: "HS256", typ: "VCAP" };
    const encodedHeader = Buffer.from(canonicalJSONString(header)).toString("base64url");
    const encodedPayload = Buffer.from(canonicalJSONString(payload)).toString("base64url");
    const input = `${encodedHeader}.${encodedPayload}`;
    const signature = createHmac("sha256", this.#signingKey)
      .update(input)
      .digest("base64url");
    return `${input}.${signature}`;
  }

  verifyAndConsume(token, expected, now = this.#now()) {
    const pieces = String(token).split(".");
    if (pieces.length !== 3) {
      throw new Error("Capability format is invalid.");
    }
    const [encodedHeader, encodedPayload, suppliedSignature] = pieces;
    const input = `${encodedHeader}.${encodedPayload}`;
    const expectedSignature = createHmac("sha256", this.#signingKey)
      .update(input)
      .digest();
    const supplied = Buffer.from(suppliedSignature, "base64url");
    if (
      supplied.length !== expectedSignature.length
      || !timingSafeEqual(supplied, expectedSignature)
    ) {
      throw new Error("Capability signature is invalid.");
    }
    const header = JSON.parse(Buffer.from(encodedHeader, "base64url"));
    const claims = JSON.parse(Buffer.from(encodedPayload, "base64url"));
    if (header.alg !== "HS256" || header.typ !== "VCAP") {
      throw new Error("Capability type is invalid.");
    }
    if (claims.iss !== this.#issuer || claims.aud !== this.#audience) {
      throw new Error("Capability issuer or audience is invalid.");
    }
    if (claims.nbf > now || claims.exp <= now) {
      throw new Error("Capability is not currently valid.");
    }
    const comparisons = [
      ["pairing", claims.sub, expected.pairingID],
      ["phone key", claims.cnf?.jkt, expected.phoneKeyThumbprint],
      ["scope", claims.scope, expected.scope],
      ["method", claims.method, expected.method.toUpperCase()],
      ["path", claims.path, expected.path],
      ["body hash", claims.bodyHash, expected.bodyHash],
    ];
    for (const [label, actual, wanted] of comparisons) {
      if (actual !== wanted) {
        throw new Error(`Capability ${label} does not match the request.`);
      }
    }
    this.#consumptionStore.consume(
      `capability:${claims.jti}`,
      claims.exp,
      now,
    );
    return claims;
  }
}

const SENSITIVE_FIELD_NAME = /^(?:authorization|.*(?:token|secret|password|api_?key|credential|private_?key).*)$/i;
const SENSITIVE_ASSIGNMENT = /((?:["']?)[A-Z0-9_.-]*(?:TOKEN|SECRET|PASSWORD|API_?KEY|CREDENTIAL|PRIVATE_?KEY)[A-Z0-9_.-]*(?:["']?)\s*[:=]\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;}\]]+)/gi;
const BEARER_VALUE = /(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}/gi;
const MAX_NESTED_JSON_DEPTH = 8;

export class SecretRedactor {
  #exactValues;

  constructor({ exactValues = [] } = {}) {
    if (!Array.isArray(exactValues)) {
      throw new Error("Exact secret values must be an array.");
    }
    this.#exactValues = [...new Set(exactValues.map((value) => {
      if (typeof value !== "string" || value.length < 8) {
        throw new Error("Exact secret values must contain at least eight characters.");
      }
      return value;
    }))].sort((left, right) => right.length - left.length);
  }

  redact(value) {
    return redactText(String(value), this.#exactValues, 0);
  }
}

const defaultSecretRedactor = new SecretRedactor();

export function redactSecrets(value) {
  return defaultSecretRedactor.redact(value);
}

function redactText(value, exactValues, depth) {
  let text = value;
  for (const secret of exactValues) {
    text = text.replaceAll(secret, "<redacted>");
  }

  if (
    depth < MAX_NESTED_JSON_DEPTH
    && (text.startsWith("{") || text.startsWith("["))
  ) {
    try {
      const parsed = JSON.parse(text);
      return JSON.stringify(redactJSONValue(parsed, exactValues, depth + 1));
    } catch {
      // Model output is often prose containing JSON; scrub it as text below.
    }
  }

  return text
    .replace(BEARER_VALUE, "$1<redacted>")
    .replace(/\bsk-[A-Za-z0-9_-]{12,}\b/g, "<redacted>")
    .replace(SENSITIVE_ASSIGNMENT, (match, prefix, assignedValue) => {
      const quote = assignedValue[0];
      if (quote === "\"" || quote === "'") {
        return `${prefix}${quote}<redacted>${quote}`;
      }
      return `${prefix}<redacted>`;
    });
}

function redactJSONValue(value, exactValues, depth, fieldName = "") {
  if (fieldName && SENSITIVE_FIELD_NAME.test(fieldName)) {
    return typeof value === "string" && /^Bearer\s+/i.test(value)
      ? "Bearer <redacted>"
      : "<redacted>";
  }
  if (Array.isArray(value)) {
    return value.map(
      (member) => redactJSONValue(member, exactValues, depth),
    );
  }
  if (value && typeof value === "object") {
    const result = {};
    for (const [key, member] of Object.entries(value)) {
      result[key] = redactJSONValue(member, exactValues, depth, key);
    }
    return result;
  }
  if (typeof value !== "string") return value;
  return redactText(value, exactValues, depth);
}
