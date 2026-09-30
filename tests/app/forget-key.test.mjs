// Settings → Forget key and Pair again send nothing more once the key is revoked (1.2.0): not the
// Jewish calendar's reads (calendar.js), which going back to Home or a planned re-read would start,
// and not the look for the home network while the app goes through the account (session.js), whose
// read without an answer is sent once more. Against a fake controller and a fake account service,
// under fake time; the few browser globals these modules use are faked here.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

const HOST = "controller.invalid";
const KEY = "ak_test";
const HOME = "0123456789abcdef0123456789abcdef";
const KEY_ID = "0a1b2c3d";
const stored = new Map();

globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = { hidden: false, addEventListener: () => {}, documentElement: {}, querySelector: () => null };
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Node", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
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
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-02T12:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

const { deriveLock, open, seal } = await import("../../app/js/lock.js");

// The controller and the account service. `seals`: the controller opens sealed requests on the
// home network (else it answers 404 there, as before 1.0.0, and requests carry the key);
// `lanSilent`: a sealed request at home gets there and no answer comes back. `calls` has every
// request: "GET /v1/lights" to the controller (" (no key)" when it carried none), "account DELETE
// /v1/api-keys/current" through the account (the request inside the envelope).
const net = { calls: [], seals: false, lanSilent: false, revoked: false };

function answer(status, body) {
  return new Response(body === null ? null : JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

// A Shabbat that ends in a minute: the calendar plans a read then.
const calendarAnswer = () => ({
  enabled: true,
  status: "ok",
  settings: { holidays: "auto", israel: true, candle_lighting_minutes: 20, havdalah_minutes: 42, version: 1 },
  today: { date: "2026-10-03", hebrew: { year: 5787, month: "tishrei", day: 22, leap_year: true }, after_sunset: true, holidays: [], changes_at: new Date(Date.now() + 86400000).toISOString() },
  week: { date: "2026-10-03", parasha: null, holidays: [] },
  current: { starts_at: new Date(Date.now() - 3600000).toISOString(), ends_at: new Date(Date.now() + 60000).toISOString(), approximate: false, days: [] },
  next: null,
});

// What the home answers a request, at home or through the account: [status, body].
function home(method, path) {
  if (net.revoked) return [401, { status: 401, code: "UNAUTHORIZED" }];
  if (path === "/v1/api-keys/current" && method === "DELETE") {
    net.revoked = true;
    return [204, null];
  }
  if (path === "/v1/api-keys/current") return [200, { id: KEY_ID, role: "admin" }];
  if (path === "/v1/calendar") return [200, calendarAnswer()];
  return [200, { items: [] }];
}

async function account(path, init) {
  if (!new RegExp(`^/v1/homes/${HOME}/e2e$`).test(path)) return answer(404, { code: "NOT_FOUND" });
  const lock = await deriveLock(KEY);
  const request = JSON.parse(await open(lock, JSON.parse(init.body).envelope, "req"));
  net.calls.push(`account ${request.method} ${request.path}`);
  const [status, body] = home(request.method, request.path);
  const reply = { id: request.id, ts: Math.floor(Date.now() / 1000), status, content_type: "application/json", body: body === null ? "" : JSON.stringify(body) };
  return answer(200, { envelope: await seal(lock, { home: HOME, key: KEY_ID }, "res", JSON.stringify(reply)) });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname === "api.directorlink.io") return account(path, init);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const keyed = Boolean(init.headers?.Authorization);
  net.calls.push(`${method} ${path}${keyed || path === "/v1/sealed" ? "" : " (no key)"}`);
  if (path === "/v1/sealed") {
    if (!net.seals) return answer(404, { status: 404, code: "NOT_FOUND" });
    if (method === "GET") return answer(200, { home: "lan", time: Math.floor(Date.now() / 1000), window_seconds: 120 });
    return new Promise((_resolve, reject) => {
      const stop = () => reject(new DOMException("The operation was aborted.", "AbortError"));
      if (init.signal?.aborted) stop();
      init.signal?.addEventListener("abort", stop);
    });
  }
  if (!keyed) return answer(401, { status: 401, code: "UNAUTHORIZED" });
  const [status, body] = home(method, path);
  return answer(status, body);
};

const { state, notify } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const { saveRemote } = await import("../../app/js/remote.js");
const { keepCalendar, loadCalendar } = await import("../../app/js/calendar.js");

// Lets fetch answers, promise chains, response bodies and WebCrypto settle.
async function settle() {
  for (let index = 0; index < 8; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function advance(ms, step = 50) {
  for (let done = 0; done < ms; done += step) {
    mock.timers.tick(Math.min(step, ms - done));
    await settle();
  }
  await settle();
}

const afterDelete = () => net.calls.slice(net.calls.findIndex((call) => /DELETE \/v1\/api-keys\/current$/.test(call)) + 1);

// Connected with the Jewish calendar on: at home (`transport` "lan") or through the account.
async function connected(transport = "lan") {
  session.forgetKey();
  await advance(100);
  Object.assign(net, { calls: [], seals: false, lanSilent: false, revoked: false });
  Object.assign(state, { host: HOST, apiKey: KEY, role: "admin", status: "connected", loaded: true, notice: null, transport });
  if (transport === "remote") saveRemote({ home: HOME, keyId: KEY_ID });
  state.system = { bridge: { version: "1.2.0" }, features: { jewish_calendar: true } };
  notify();
}

test("after Forget key, going back to Home reads nothing of the calendar", async () => {
  await connected();
  await session.revokeAndForget();
  // Settings goes to #/, where app.js reads the calendar.
  loadCalendar();
  keepCalendar();
  await advance(500);
  assert.deepEqual(afterDelete(), []);
  assert.equal(state.calendar, null);
});

test("after Forget key, the calendar's planned read is not sent, and what it said is gone", async () => {
  await connected();
  await loadCalendar();
  assert.equal(state.calendar?.current?.ends_at !== undefined, true, "read, with the end of Shabbat a minute away");
  await session.revokeAndForget();
  assert.equal(state.calendar, null, "not shown to the next home paired");
  await advance(3 * 60 * 1000, 1000);
  assert.deepEqual(afterDelete(), []);
});

test("away from home, Forget key while the look for the home network waits sends nothing more", async () => {
  await connected("remote");
  net.seals = true;
  session.startPolling();
  // Every sixth refresh looks whether the home network is back; its sealed read gets no answer.
  for (let waited = 0; !net.calls.includes("POST /v1/sealed") && waited < 3 * 60 * 1000; waited += 100) await advance(100);
  assert.ok(net.calls.includes("POST /v1/sealed"), "the home network was tried");
  await session.revokeAndForget();
  assert.ok(net.calls.includes("account DELETE /v1/api-keys/current"), "revoked through the account");
  await advance(5000);
  assert.deepEqual(afterDelete(), []);
  session.stopPolling();
});
