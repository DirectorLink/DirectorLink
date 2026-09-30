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
  Object.assign(state, { notice: null, pairingUnprotected: null });
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
  assert.deepEqual(state.pairingUnprotected, { host: HOST, reason: "older" });
  assert.ok(!sentTheCode(controller.requests), "nothing about the code was sent");
  assert.equal(await session.pairWithCode(HOST, "1234 5678", { anyway: true }), true);
  const [withExpiry, without] = controller.requests.slice(-2);
  assert.equal(withExpiry.expires_in, 86400, "asked for a day first");
  assert.equal(without.pairing_code, "12345678");
  assert.ok(!("expires_in" in without), "then as DirectorLink 1.2.0 understands it");
  assert.equal(state.pairingUnprotected, null);
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

test("the warning belongs to the controller it was about; another address clears it", async () => {
  fresh({ version: "1.2.0" });
  await session.pairWithCode(HOST, "1234 5678");
  assert.deepEqual(session.unprotectedFor(` ${HOST} `), { host: HOST, reason: "older" }, "shown while the field holds that controller");
  assert.equal(session.unprotectedFor("192.168.1.11"), null, "not for another one");
  session.addressChanged(HOST);
  assert.ok(state.pairingUnprotected, "the same address keeps it");
  session.addressChanged("192.168.1.11");
  assert.equal(state.pairingUnprotected, null, "another address clears it");
});

test("a 1.3.0 controller whose lock failed is not called older", async () => {
  fresh({ lock: false });
  assert.equal(await session.pairWithCode(HOST, "1234 5678"), false);
  assert.deepEqual(state.pairingUnprotected, { host: HOST, reason: "lock" });
  assert.ok(!sentTheCode(controller.requests));
});

test("a key refused after its expiry is called expired, even once the controller removed it", async () => {
  const realNow = Date.now;
  try {
    fresh();
    await session.pairWithCode(HOST, "1234 5678");
    const expiresAt = Date.parse(state.key.expires_at);
    // The app, polling the controller, made it remove the key: now it is just unknown.
    controller.removeKeys();
    Date.now = () => expiresAt + 3600 * 1000;
    await session.connect();
    assert.equal(state.apiKey, "");
    assert.equal(state.notice.text, session.EXPIRED_TEXT);

    // Refused before its time: revoked, as before.
    Date.now = realNow;
    fresh();
    await session.pairWithCode(HOST, "1234 5678");
    controller.removeKeys();
    await session.connect();
    assert.equal(state.apiKey, "");
    assert.match(state.notice.text, /no longer accepts this API key/);
  } finally {
    Date.now = realNow;
  }
});

test("a key that lasts weeks is asked about every few hours, not all the time", async () => {
  fresh();
  const paired = await controller.fetch(`http://${HOST}:41999/v1/auth/pair`, {
    method: "POST",
    body: JSON.stringify({ pairing_code: "12345678", name: "Script", expires_in: 30 * 86400 }),
  });
  const { key } = await paired.json();
  const delays = [];
  const setTimer = window.setTimeout;
  window.setTimeout = (callback, ms) => {
    delays.push(ms);
    return setTimer(callback, ms);
  };
  try {
    assert.equal(await session.connectWithKey(HOST, key), true);
  } finally {
    window.setTimeout = setTimer;
  }
  const longest = Math.max(...delays);
  assert.ok(longest <= 6 * 3600 * 1000, `waits at most 6 hours, not ${longest} ms (a timer overflows after 2^31 - 1 ms)`);
  assert.ok(longest >= 3600 * 1000, "but does not ask all the time");
});

test("the time left, as the Connection screen shows it", () => {
  const now = Date.parse("2026-10-01T12:00:00Z");
  assert.equal(session.timeLeft(null, now), "Never");
  assert.equal(session.timeLeft("2026-10-01T11:59:00Z", now), "Expired");
  assert.match(session.timeLeft("2026-10-01T12:30:00Z", now), /^30 min left \(Oct 1, /);
  assert.match(session.timeLeft("2026-10-02T11:05:00Z", now), /^23 h 5 min left \(Oct 2, /);
});
