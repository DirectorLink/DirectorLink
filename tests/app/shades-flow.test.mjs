// Shades in the running app (app/js/controls.js with session.js), against a fake controller under
// fake time: what the app reads while shades move, and what the rows show. The few browser globals
// these modules use are faked here, and fetch answers only for the fake controller.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

const HOST = "controller.invalid";
const KEY = "ak_test";
const stored = new Map();

globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = { hidden: false, addEventListener() {}, documentElement: {}, querySelector: () => null };
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
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-01T08:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// The fake controller: a DirectorLink that cannot seal (so requests carry the key), with these
// blinds. `patch` and `stop` may answer instead of the default (202 with the blind as it was).
const controller = { blinds: [], devices: [], calls: [], patch: null };

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const keyed = Boolean(init.headers?.Authorization);
  controller.calls.push({ at: Date.now(), method, path, keyed });
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (!keyed) return answer(401, { status: 401, code: "UNAUTHORIZED", detail: "Missing or invalid API key" });
  const copy = (blind) => ({ ...blind });
  if (path === "/v1/blinds" && method === "GET") return answer(200, { items: controller.blinds.map(copy) });
  const one = path.match(/^\/v1\/blinds\/(\d+)(\/stop)?$/);
  if (one) {
    const blind = controller.blinds.find((item) => item.id === Number(one[1]));
    if (!blind) return answer(404, { status: 404, code: "NOT_FOUND", detail: "Blind not found" });
    const custom = method === "PATCH" && controller.patch?.(blind, JSON.parse(init.body));
    return custom ? answer(custom.status, custom.body) : answer(method === "GET" ? 200 : 202, copy(blind));
  }
  if (path === "/v1/devices") return answer(200, { items: controller.devices });
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "admin" });
  if (path === "/v1/rooms/order" && method === "PUT") {
    // As DirectorLink 1.0.0 answered it in a sealed request.
    return answer(400, { status: 400, code: "BAD_REQUEST", detail: "Remote requests are GET, POST, PATCH or DELETE on /v1/..." });
  }
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { state, notify } = await import("../../app/js/state.js");
const controls = await import("../../app/js/controls.js");
const session = await import("../../app/js/session.js");
const { blindStateLabel } = await import("../../app/js/model.js");
const { shadeView } = await import("../../app/js/shades.js");
const { copyHouse } = await import("../../app/js/scenes.js");
const { roomOrderErrorText } = await import("../../app/js/views/settings.js");
const { setLanguage, t } = await import("../../app/js/i18n.js");
const { ApiError } = await import("../../app/api-client.js");

// Lets fetch answers, promise chains and response bodies settle.
async function settle() {
  for (let index = 0; index < 8; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

// Moves the fake clock on by `ms`, in steps, running everything that comes due.
async function advance(ms, step = 50) {
  for (let done = 0; done < ms; done += step) {
    mock.timers.tick(Math.min(step, ms - done));
    await settle();
  }
  await settle();
}

const shade = (fields = {}) => ({
  id: 52,
  name: "Terrace Shade",
  room: { id: 11, name: "Living Room" },
  position: 35,
  position_reported: true,
  capabilities: { position: true, stop: true },
  moving: false,
  direction: null,
  target_position: 35,
  ...fields,
});

// Connected to the fake controller with these blinds, as after loading the home.
async function connect(blinds) {
  session.forgetKey();
  await advance(100);
  controller.blinds = blinds.map((blind) => ({ ...blind }));
  controller.calls = [];
  controller.patch = null;
  state.host = HOST;
  state.apiKey = KEY;
  state.role = "admin";
  state.status = "connected";
  state.loaded = true;
  state.notice = null;
  state.blinds = blinds.map((blind) => ({ ...blind }));
  notify();
  await advance(100);
}

const blindReads = (since) => controller.calls.filter((call) => call.at >= since && call.method === "GET" && call.path === "/v1/blinds").length;

// What the row of blind `id` says, and where its slider is.
function shown(id) {
  const blind = state.blinds.find((item) => item.id === id);
  const move = controls.blindMove(id);
  return `${blindStateLabel(blind, move)} | ${shadeView(blind, move).slider}`;
}

test("a shade that left the list while it moved is not read for any longer", async () => {
  await connect([shade({ moving: null }), shade({ id: 60, position: 0, target_position: 0, moving: null })]);
  controls.setBlind(state.blinds[0], 53);
  await advance(3000);
  // Removed in Composer (Refresh Project), or no longer supported.
  controller.blinds = controller.blinds.filter((blind) => blind.id !== 52);
  const from = Date.now();
  await advance(60000, 200);
  assert.ok(blindReads(from) <= 2, `${blindReads(from)} reads in the minute after`);
  assert.equal(controls.blindMove(52), null);
});

test("a shade that keeps reporting it moves is read every 2 s for two minutes at most", async () => {
  await connect([shade({ moving: true, direction: "opening", target_position: 80 })]);
  const from = Date.now();
  await advance(10 * 60 * 1000, 500);
  const reads = blindReads(from);
  assert.ok(reads >= 55 && reads <= 62, `${reads} reads in 10 minutes`);
  assert.equal(blindReads(from + 3 * 60 * 1000), 0, "none after three minutes");
  assert.equal(shown(52), "Opening… to 80% | 80", "it still shows what the controller says");
});

test("forgetting the key while a shade moves sends nothing without it", async () => {
  await connect([shade({ moving: null })]);
  controls.setBlind(state.blinds[0], 53);
  await advance(3000);
  await session.revokeAndForget();
  await advance(5000);
  const unkeyed = controller.calls.filter((call) => !call.keyed && call.path !== "/v1/sealed").map((call) => `${call.method} ${call.path}`);
  assert.deepEqual(unkeyed, []);
  assert.equal(state.notice, null, "no \"key no longer works\"");
  assert.equal(controls.blindMove(52), null);
});

test("a new target while the shade moves keeps the slider on it", async () => {
  await connect([shade({ moving: true, direction: "opening", target_position: 100 })]);
  await advance(500);
  controls.setBlind(state.blinds[0], 50);
  const timeline = [];
  for (let index = 0; index < 12; index += 1) {
    await advance(250);
    timeline.push(shown(52));
    // The controller has the new target a second later.
    if (index === 3) controller.blinds = [shade({ moving: true, direction: "closing", target_position: 50, position: 35 })];
  }
  assert.ok(timeline.every((line) => line.endsWith("| 50")), timeline.join(" / "));
  assert.ok(!timeline.includes("Opening… | 100"), `never opening to 100: ${timeline.join(" / ")}`);
  assert.equal(timeline.at(-1), "Closing… to 50% | 50");
});

test("after Stop the shade shows as stopped, then where it stopped", async () => {
  await connect([shade({ moving: true, direction: "opening", target_position: 100 })]);
  await advance(500);
  controls.stopBlind(state.blinds[0]);
  const timeline = [];
  for (let index = 0; index < 20; index += 1) {
    await advance(250);
    timeline.push(shown(52));
    if (index === 1) controller.blinds = [shade({ target_position: 100 })];
    if (index === 5) controller.blinds = [shade({ target_position: 61, position: 61 })];
  }
  assert.ok(!timeline.some((line) => line.startsWith("Opening…")), timeline.join(" / "));
  assert.equal(timeline[0], "35% open | 35");
  assert.equal(timeline.at(-1), "61% open | 61");
});

// The owner's KNX shades: the proxy's stop first, the actuator's real position a second later.
test("after a move stops, the position the shade reports next is read", async () => {
  await connect([shade()]);
  controls.setBlind(state.blinds[0], 53);
  await advance(2100);
  controller.blinds = [shade({ moving: true, direction: "opening", target_position: 53 })];
  await advance(20000);
  controller.blinds = [shade({ target_position: 53 })];
  await advance(2100);
  const at = Date.now();
  controller.blinds = [shade({ target_position: 53, position: 53 })];
  await advance(4000);
  assert.ok(blindReads(at) >= 1, "read again");
  assert.equal(shown(52), "53% open | 53");
  await advance(4000);
  const later = Date.now();
  await advance(20000);
  assert.equal(blindReads(later), 0, "and then no longer");
});

// With DirectorLink 1.0.0 (no capabilities, no movement), a shade that only opens fully.
test("a shade whose position changed and then stays is not shown moving for two minutes", async () => {
  const older = { id: 52, name: "Terrace Shade", room: { id: 11, name: "Living Room" }, position: 0, position_reported: true };
  await connect([older]);
  controls.setBlind(state.blinds[0], 50);
  await advance(3000);
  assert.equal(shown(52), "Opening… to 50% | 50");
  controller.blinds = [{ ...older, position: 100 }];
  await advance(10000);
  assert.equal(shown(52), "Open | 100");
  await advance(6000);
  const from = Date.now();
  await advance(30000);
  assert.equal(blindReads(from), 0, "the move is over");
});

test("Copy the house gives shades that only open and close 0 or 100", async () => {
  await connect([
    shade(),
    shade({ id: 53, position: 30, capabilities: { position: false, stop: false } }),
    shade({ id: 54, position: 80, capabilities: { position: false, stop: false } }),
    shade({ id: 55, position: null }),
  ]);
  const blinds = copyHouse().steps.filter((step) => step.type === "blinds");
  assert.deepEqual(
    blinds.map((step) => [step.set.position, step.device_ids]),
    [
      [35, [52]],
      [0, [53]],
      [100, [54]],
    ]
  );
});

test("room order on DirectorLink 1.0.0 says to update it, in English and Hebrew", async () => {
  await connect([]);
  const refused = await session.api("/v1/rooms/order", { method: "PUT", body: { room_ids: [11, 10] } }).catch((error) => error);
  assert.equal(refused.status, 400);
  assert.equal(refused.code, "BAD_REQUEST");
  assert.equal(roomOrderErrorText(refused), t("settings.rooms.updateDriverOrder"));
  assert.doesNotMatch(roomOrderErrorText(refused), /Remote requests/);
  assert.equal(roomOrderErrorText(new ApiError("Not found", { status: 404, code: "NOT_FOUND" })), t("settings.rooms.updateDriverOrder"));
  const invalid = new ApiError("room_ids: room 10 does not exist", { status: 400, code: "INVALID_FIELD" });
  assert.equal(roomOrderErrorText(invalid), "room_ids: room 10 does not exist", "other refusals say what they say");
  await setLanguage("he");
  assert.match(roomOrderErrorText(refused), /DirectorLink/);
  assert.doesNotMatch(roomOrderErrorText(refused), /Remote requests/);
  await setLanguage("en");
});

test("the devices a room has but the app cannot control follow Composer within a minute", async () => {
  await connect([]);
  state.devices = [{ id: 40, name: "Front Door", room_id: 10, supported: false }];
  controller.devices = [{ id: 41, name: "Pool Pump", room_id: 10, supported: false }];
  session.startPolling();
  await advance(70000, 500);
  session.stopPolling();
  assert.deepEqual(state.devices, controller.devices);
});
