// Pairing in the app (session.js, 1.3.0, ADR-039): the code is never sent to a controller that
// pairs with CPace; one that cannot (DirectorLink before 1.3.0) gets nothing until the person
// chose Pair anyway after the warning. And People and devices shows when a key expires (ADR-040).
// Against a fake controller (fake-controller.mjs); the few browser globals are faked here.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

import { fakeController } from "./fake-controller.mjs";

const HOST = "192.168.1.10";
const stored = new Map();

globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = { hidden: false, addEventListener: () => {}, documentElement: {}, querySelector: () => null };
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (Windows NT 10.0) Chrome/140.0", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
    clear: () => stored.clear(),
  },
  configurable: true,
});

// The app's retries and refreshes wait for timers that never run here.
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// After pairing the app connects, which the fake controller does not answer: that is not tested here.
const logError = console.error;
console.error = (message, ...rest) => {
  if (message !== "DirectorLink connection failed") logError(message, ...rest);
};

let controller = fakeController();
globalThis.fetch = (url, init) => {
  if (new URL(url).hostname !== HOST) return Promise.reject(new TypeError(`blocked: ${url}`));
  return controller.fetch(url, init);
};

const { state } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const { setLanguage } = await import("../../app/js/i18n.js");

function fresh(options) {
  session.forgetKey();
  controller = fakeController(options);
  Object.assign(state, { notice: null, pairingUnprotected: false });
}

const sentTheCode = (requests) => requests.some((body) => "pairing_code" in body || JSON.stringify(body).includes("12345678"));

test("with DirectorLink 1.3.0 the code is never sent, and the key comes back sealed", async () => {
  fresh();
  await session.pairWithCode(HOST, "1234 5678");
  assert.equal(controller.requests.length, 2, "the two CPace requests");
  assert.ok(!sentTheCode(controller.requests), "no request carries the code");
  assert.ok(controller.requests[0].cpace.nonce && controller.requests[0].name, "the first request: a nonce and the name");
  assert.ok(state.apiKey.startsWith("ak_"), "the key was opened and saved");
  assert.equal(localStorage.getItem("directorlink.apiKey"), state.apiKey);
  assert.equal(state.pairingUnprotected, false);
});

test("a wrong code is explained as before", async () => {
  fresh({ code: "11112222" });
  assert.equal(await session.pairWithCode(HOST, "1234 5678"), false);
  assert.equal(state.apiKey, "");
  assert.match(state.notice.text, /isn’t right/);
  assert.ok(!sentTheCode(controller.requests));
});

test("an older DirectorLink gets no code: a warning first, and only Pair anyway sends it", async () => {
  fresh({ version: "1.2.0" });
  assert.equal(await session.pairWithCode(HOST, "1234 5678"), false);
  assert.equal(state.pairingUnprotected, true, "the connect screen warns");
  assert.equal(state.status, "setup");
  assert.equal(state.apiKey, "");
  assert.equal(controller.requests.length, 1);
  assert.ok(!sentTheCode(controller.requests), "nothing about the code was sent");

  // Connect again without choosing: still nothing.
  await session.pairWithCode(HOST, "1234 5678");
  assert.ok(!sentTheCode(controller.requests));

  await session.pairWithCode(HOST, "1234 5678", { anyway: true });
  assert.equal(state.pairingUnprotected, false);
  assert.ok(sentTheCode(controller.requests), "Pair anyway sends the code, the old way");
  assert.equal(controller.requests.at(-1).pairing_code, "12345678");
  assert.ok(state.apiKey.startsWith("ak_"));
});

test("People and devices says when a key expires", async () => {
  await setLanguage("en");
  const { expiry } = await import("../../app/js/views/access.js");
  const now = Date.parse("2026-10-01T12:00:00Z");
  assert.equal(expiry({ expires_at: null }, now), null, "keys without an expiry say nothing");
  assert.equal(expiry({ expires_at: "2026-10-02T11:00:00Z" }, now), "expires in 23 hours");
  assert.equal(expiry({ expires_at: "2026-10-01T12:30:00Z" }, now), "expires in 30 minutes");
  assert.equal(expiry({ expires_at: "2026-10-01T11:00:00Z" }, now), "expired");
  await setLanguage("he");
  assert.equal(expiry({ expires_at: "2026-10-02T11:00:00Z" }, now), "התוקף יפוג בעוד 23 שעות");
  await setLanguage("en");
});
