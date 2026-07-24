import { networkInterfaces } from "node:os";

export function selectBrokerEndpoint({
  host,
  port,
  interfaces = networkInterfaces(),
}) {
  if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) {
    throw new Error("Broker port is invalid.");
  }
  if (host === "127.0.0.1" || host === "::1") {
    return `https://127.0.0.1:${port}`;
  }
  if (host !== "0.0.0.0" && host !== "::") {
    throw new Error("Broker bind address is invalid.");
  }
  const address = selectLANAddress({ interfaces });
  return `https://${address}:${port}`;
}

export function selectLANAddress({
  interfaces = networkInterfaces(),
} = {}) {
  const candidates = [];
  for (const [name, records] of Object.entries(interfaces)) {
    for (const record of records ?? []) {
      const isIPv4 = record.family === "IPv4" || record.family === 4;
      if (
        isIPv4
        && record.internal !== true
        && isPrivateIPv4(record.address)
      ) {
        candidates.push({
          address: record.address,
          priority: interfacePriority(name),
          name,
        });
      }
    }
  }
  candidates.sort((lhs, rhs) => {
    return lhs.priority - rhs.priority
      || lhs.name.localeCompare(rhs.name)
      || lhs.address.localeCompare(rhs.address);
  });
  const selected = candidates[0];
  if (!selected) {
    throw new Error("No usable private LAN address is available.");
  }
  return selected.address;
}

function interfacePriority(name) {
  if (name === "en0") return 0;
  if (name === "en1") return 1;
  if (name.startsWith("en")) return 2;
  if (name.startsWith("bridge")) return 3;
  return 4;
}

export function isPrivateIPv4(address) {
  const pieces = String(address).split(".").map(Number);
  if (
    pieces.length !== 4
    || pieces.some(
      (piece) => !Number.isSafeInteger(piece) || piece < 0 || piece > 255,
    )
  ) {
    return false;
  }
  const [first, second] = pieces;
  return (
    first === 10
    || (first === 172 && second >= 16 && second <= 31)
    || (first === 192 && second === 168)
  );
}
