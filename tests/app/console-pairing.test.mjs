// Pairing in the API console (console/js/session.js, 1.3.0): the code is never sent (CPace,
// ADR-039) unless Pair anyway was chosen for an older DirectorLink, and the console's own key
// lasts a day (ADR-040): at its end the controller refuses it with KEY_EXPIRED and the console
// goes back to pairing. Against a fake controller (fake-controller.mjs).
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

import { fakeController } from "./fake-controller.mjs";

const HOST = "192.168.1.10";
const stored = new Map();

globalThis.window = globalThis;
window.location = { hostname: "console.directorlink.io", origin: "https://console.directorlink.io", pathname: "/", search: "", hash: "#/api" };
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
    clear: () => stored.clear(),
  },
  configurable: true,
});
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });

let controller = fakeController();
globalThis.fetch = (url, init) => {
  if (new URL(url).hostname !== HOST) return Promise.reject(new TypeError(`blocked: ${url}`));
  return controller.fetch(url, init);
};

const session = await import("../../console/js/session.js");
const { state } = session;

function fresh(options) {
  session.forgetLocally();
  controller = fakeController(options);
  Object.assign(state, { notice: null, pairingUnprotected: false });
}

const sentTheCode = (requests) => requests.some((body) => "pairing_code" in body || JSON.stringify(body).includes("12345678"));

test("the console pairs without sending the code, for a key that lasts a day", async () => {
  fresh();
  assert.equal(await session.pairWithCode(HOST, "1234 5678"), true);
  assert.ok(!sentTheCode(controller.requests));
  assert.equal(controller.requests[0].expires_in, 86400);
  assert.equal(controller.requests[0].name, "DirectorLink Console");
  assert.ok(state.apiKey.startsWith("ak_"));
  assert.ok(state.key.expires_at, "the key it got expires");
  assert.match(session.timeLeft(state.key.expires_at), /^2[34] h \d+ min left \(/);
});

test("an older DirectorLink gets the code only after Pair anyway, without expires_in", async () => {
  fresh({ version: "1.2.0" });
  assert.equal(await session.pairWithCode(HOST, "1234 5678"), false);
  assert.equal(state.pairingUnprotected, true);
  assert.ok(!sentTheCode(controller.requests), "nothing about the code was sent");
  assert.equal(await session.pairWithCode(HOST, "1234 5678", { anyway: true }), true);
  const [withExpiry, without] = controller.requests.slice(-2);
  assert.equal(withExpiry.expires_in, 86400, "asked for a day first");
  assert.equal(without.pairing_code, "12345678");
  assert.ok(!("expires_in" in without), "then as DirectorLink 1.2.0 understands it");
  assert.equal(state.pairingUnprotected, false);
});

test("an expired key sends the console back to pairing, and says why", async () => {
  fresh();
  await session.pairWithCode(HOST, "1234 5678");
  controller.expireKeys();
  await session.connect();
  assert.equal(state.apiKey, "", "the key is forgotten");
  assert.equal(state.notice.text, session.EXPIRED_TEXT);
  assert.equal(state.notice.text, "Your console key expired. Get a new pairing code in Composer (DirectorLink → Actions → New Pairing Code).");
  assert.equal(window.location.hash, "#/connect");
});

test("at the end of the day the console asks the controller by itself", async () => {
  fresh();
  const realNow = Date.now;
  try {
    await session.pairWithCode(HOST, "1234 5678");
    controller.expireKeys();
    const expiresAt = Date.parse(state.key.expires_at);
    Date.now = () => expiresAt + 1000;
    mock.timers.tick(86400 * 1000 + 1000);
    for (let index = 0; index < 20 && state.apiKey; index += 1) await new Promise((resolve) => setImmediate(resolve));
    assert.equal(state.apiKey, "");
    assert.equal(state.notice.text, session.EXPIRED_TEXT);
  } finally {
    Date.now = realNow;
  }
});

test("the time left, as the Connection screen shows it", () => {
  const now = Date.parse("2026-10-01T12:00:00Z");
  assert.equal(session.timeLeft(null, now), "Never");
  assert.equal(session.timeLeft("2026-10-01T11:59:00Z", now), "Expired");
  assert.match(session.timeLeft("2026-10-01T12:30:00Z", now), /^30 min left \(Oct 1, /);
  assert.match(session.timeLeft("2026-10-02T11:05:00Z", now), /^23 h 5 min left \(Oct 2, /);
});
