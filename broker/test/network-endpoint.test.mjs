import assert from "node:assert/strict";
import test from "node:test";

import {
  selectBrokerEndpoint,
  selectLANAddress,
} from "../src/network-endpoint.mjs";

test("loopback mode never advertises a LAN endpoint", () => {
  assert.equal(selectBrokerEndpoint({
    host: "127.0.0.1",
    port: 38_443,
    interfaces: {
      en0: [{ address: "192.168.1.4", family: "IPv4", internal: false }],
    },
  }), "https://127.0.0.1:38443");
});

test("LAN mode prefers the Wi-Fi IPv4 address and ignores internal/link-local entries", () => {
  const interfaces = {
    bridge0: [{ address: "10.0.0.9", family: "IPv4", internal: false }],
    en0: [
      { address: "fe80::1", family: "IPv6", internal: false },
      { address: "192.168.1.44", family: "IPv4", internal: false },
    ],
    lo0: [{ address: "127.0.0.1", family: "IPv4", internal: true }],
  };
  assert.equal(selectLANAddress({
    interfaces,
  }), "192.168.1.44");
  assert.equal(selectBrokerEndpoint({
    host: "0.0.0.0",
    port: 38_443,
    interfaces,
  }), "https://192.168.1.44:38443");
});

test("LAN mode fails closed when no usable private address exists", () => {
  assert.throws(() => selectBrokerEndpoint({
    host: "0.0.0.0",
    port: 38_443,
    interfaces: {
      lo0: [{ address: "127.0.0.1", family: "IPv4", internal: true }],
      en0: [{ address: "169.254.1.2", family: "IPv4", internal: false }],
    },
  }), /LAN address/i);
});
