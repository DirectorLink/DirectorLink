// Fans in the app (DirectorLink 1.2.0): the rules of app/js/fans.js, a command from the fan row
// (controls.js with session.js) against a fake controller under fake time — shown at once, sent,
// confirmed by reading the fan again, put back when refused — and where fans appear: rooms, scene
// steps, Copy the house, the texts in English and Hebrew.
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
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-01T08:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// The fake controller: a DirectorLink that cannot seal (so requests carry the key), with these
// fans. A PATCH is reported `lag` ms later, as the proxy hears it from the fan (never when
// `reports` is false); `refuse` answers PATCH with that status instead. `hasFans`: /v1/fans exists.
const controller = { fans: [], calls: [], lag: 300, reports: true, refuse: null, hasFans: true };

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  controller.calls.push({ at: Date.now(), method, path, body: init.body ? JSON.parse(init.body) : null });
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (!init.headers?.Authorization) return answer(401, { status: 401, code: "UNAUTHORIZED" });
  if (path.startsWith("/v1/fans") && !controller.hasFans) return answer(404, { status: 404, code: "NOT_FOUND", detail: "No route" });
  if (path === "/v1/fans" && method === "GET") return answer(200, { items: controller.fans.map((fan) => ({ ...fan })) });
  const one = path.match(/^\/v1\/fans\/(\d+)$/);
  if (one) {
    const fan = controller.fans.find((item) => item.id === Number(one[1]));
    if (!fan) return answer(404, { status: 404, code: "NOT_FOUND", detail: "Fan not found" });
    if (method === "GET") return answer(200, { ...fan });
    if (controller.refuse) return answer(controller.refuse, { status: controller.refuse, code: "CONTROLLER_COMMAND_FAILED", detail: "Director rejected the fan command" });
    const change = JSON.parse(init.body);
    const before = { ...fan };
    if (controller.reports) {
      setTimeout(() => {
        const reported = "speed" in change ? { on: true, speed: change.speed } : { on: change.on, speed: change.on ? fan.speed || 3 : null };
        controller.fans = controller.fans.map((item) => (item.id === fan.id ? { ...item, ...reported } : item));
      }, controller.lag);
    }
    return answer(202, before);
  }
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "admin" });
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { SPEED_NAMES, fanChangeConfirmed, fanLevel, fanSpeeds, levelChange, optimisticFan, sceneSet } = await import("../../app/js/fans.js");
const { state, notify } = await import("../../app/js/state.js");
const controls = await import("../../app/js/controls.js");
const session = await import("../../app/js/session.js");
const { fanSpeedLabel, fanStateLabel, roomGroup, visibleRooms } = await import("../../app/js/model.js");
const { STEP_TYPES, copyHouse, currentSteps, stepAction, stepWhat } = await import("../../app/js/scenes.js");
const { setLanguage, t } = await import("../../app/js/i18n.js");

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

// The fake Director's fans (driver/tests/c4mock.lua withFans) as the driver reports them.
const ceiling = { id: 41, name: "Ceiling Fan", room: { id: 11, name: "Living Room" }, on: true, speed: 2, speeds: [1, 2, 3, 4] };
const patio = { id: 42, name: "Patio Fan", room: { id: 10, name: "Kitchen" }, on: false, speed: null, speeds: [1, 2, 3, 4] };

async function connect(fans, role = "admin") {
  session.forgetKey();
  await advance(100);
  Object.assign(controller, { calls: [], lag: 300, reports: true, refuse: null, hasFans: true });
  controller.fans = fans.map((fan) => ({ ...fan }));
  state.host = HOST;
  state.apiKey = KEY;
  state.role = role;
  state.status = "connected";
  state.loaded = true;
  state.fans = fans.map((fan) => ({ ...fan }));
  state.errors = {};
  notify();
  await advance(100);
}

const patches = () => controller.calls.filter((call) => call.method === "PATCH");
const fanNow = (id) => state.fans.find((fan) => fan.id === id);

test("a level is off, a speed, or unknown while on at a speed not reported", () => {
  assert.equal(fanLevel(patio), 0);
  assert.equal(fanLevel(ceiling), 2);
  assert.equal(fanLevel({ ...ceiling, speed: null }), null);
  assert.deepEqual(levelChange(0), { on: false }, "off is on: false, never speed 0");
  assert.deepEqual(levelChange(3), { speed: 3 });
  assert.deepEqual(fanSpeeds(ceiling), [1, 2, 3, 4]);
  assert.deepEqual(fanSpeeds({ speeds: [3, 1, 2] }), [1, 2, 3], "lowest first");
  assert.deepEqual(fanSpeeds({}), [1, 2, 3, 4], "the fan proxy's four when none are reported");
  assert.equal(SPEED_NAMES.length, 4);
});

test("a change counts as done once the fan reports it", () => {
  assert.equal(fanChangeConfirmed({ on: true, speed: 3 }, { speed: 3 }), true);
  assert.equal(fanChangeConfirmed({ on: true, speed: 2 }, { speed: 3 }), false);
  assert.equal(fanChangeConfirmed({ on: false, speed: null }, { speed: 3 }), false);
  assert.equal(fanChangeConfirmed({ on: false, speed: null }, { on: false }), true);
  assert.equal(fanChangeConfirmed({ on: true, speed: null }, { on: true }), true, "on at the speed it chose");
  assert.deepEqual(optimisticFan(patio, { speed: 4 }), { ...patio, on: true, speed: 4 });
  assert.deepEqual(optimisticFan(ceiling, { on: false }), { ...ceiling, on: false, speed: null });
  assert.deepEqual(optimisticFan(patio, { on: true }), { ...patio, on: true, speed: null }, "the fan picks its own speed");
});

test("a speed shows at once, is sent, and is confirmed by reading the fan again", async () => {
  await connect([ceiling, patio]);
  const sending = controls.setFan(fanNow(42), levelChange(3));
  assert.deepEqual({ on: fanNow(42).on, speed: fanNow(42).speed }, { on: true, speed: 3 }, "shown before the controller answers");
  assert.equal(state.pending["fan:42"], 1);
  await settle();
  assert.deepEqual(patches().map((call) => [call.path, call.body]), [["/v1/fans/42", { speed: 3 }]]);
  // The 202 carries the fan as last reported (off): the screen keeps what was asked for.
  await advance(100);
  assert.equal(fanNow(42).speed, 3);
  await advance(2000);
  await sending;
  assert.equal(state.pending["fan:42"], undefined);
  assert.deepEqual({ on: fanNow(42).on, speed: fanNow(42).speed }, { on: true, speed: 3 });
  assert.ok(controller.calls.some((call) => call.method === "GET" && call.path === "/v1/fans/42"), "read again");
  assert.equal(state.errors["fan:42"], undefined);

  // Off from the switch, and on again at the speed the fan picks.
  const off = controls.setFan(fanNow(41), { on: false });
  assert.deepEqual({ on: fanNow(41).on, speed: fanNow(41).speed }, { on: false, speed: null });
  await advance(2000);
  await off;
  assert.deepEqual(patches().at(-1).body, { on: false });
  const on = controls.setFan(fanNow(41), { on: true });
  await advance(2000);
  await on;
  assert.equal(fanNow(41).on, true);
  assert.equal(fanNow(41).speed, 3, "the speed it came on at, as reported");
});

test("a refused command puts the fan back and says why", async () => {
  await connect([ceiling]);
  controller.refuse = 502;
  const sending = controls.setFan(fanNow(41), levelChange(4));
  assert.equal(fanNow(41).speed, 4, "shown at once");
  await advance(500);
  await sending;
  assert.deepEqual({ on: fanNow(41).on, speed: fanNow(41).speed }, { on: true, speed: 2 }, "as it was");
  assert.match(state.errors["fan:41"].text, /Director rejected the fan command/);
});

test("a fan that never reports the change keeps it on screen and says so", async () => {
  await connect([patio]);
  controller.reports = false;
  const sending = controls.setFan(fanNow(42), levelChange(1));
  await advance(6000);
  await sending;
  assert.equal(fanNow(42).speed, 1);
  assert.equal(state.errors["fan:42"].text, t("errors.notConfirmed"));
});

test("view-only keys send nothing", async () => {
  await connect([ceiling], "viewer");
  await controls.setFan(fanNow(41), { on: false });
  await advance(1000);
  assert.equal(patches().length, 0);
  assert.equal(fanNow(41).on, true);
});

test("All off turns the room's fans off too", async () => {
  await connect([ceiling, { ...patio, room: { id: 11, name: "Living Room" }, on: true, speed: 4 }]);
  state.lights = [];
  state.thermostats = [];
  const done = controls.allOff(roomGroup(11));
  await advance(2000);
  await done;
  assert.deepEqual(patches().map((call) => [call.path, call.body]).sort(), [["/v1/fans/41", { on: false }], ["/v1/fans/42", { on: false }]]);
});

test("the 10 s refresh reads fans only in a home that has some", async () => {
  await connect([]);
  state.system = { inventory: { fans: 0 } };
  await session.refreshDevices();
  assert.equal(controller.calls.filter((call) => call.path === "/v1/fans").length, 0, "no fans: not asked");
  // A fan added in Composer: the inventory (read every minute) counts it.
  controller.fans = [{ ...ceiling }];
  state.system = { inventory: { fans: 1 } };
  await session.refreshDevices();
  assert.equal(controller.calls.filter((call) => call.path === "/v1/fans").length, 1);
  assert.deepEqual(state.fans.map((fan) => fan.id), [41]);
  // A driver before 1.2.0 has no /v1/fans and no count: nothing is asked, nothing fails.
  await connect([]);
  controller.hasFans = false;
  state.system = { inventory: { lights: 3 } };
  assert.equal(await session.refreshDevices(), true);
  assert.equal(controller.calls.filter((call) => call.path === "/v1/fans").length, 0);
  assert.deepEqual(state.fans, []);
});

test("connecting reads the fans, and a driver before 1.2.0 has none", async () => {
  await connect([]);
  controller.fans = [{ ...ceiling }, { ...patio }];
  state.loaded = false;
  assert.equal(await session.connect(), true);
  session.stopPolling();
  assert.deepEqual(state.fans.map((fan) => fan.id), [41, 42]);
  await connect([ceiling]);
  controller.hasFans = false;
  state.loaded = false;
  assert.equal(await session.connect(), true, "a 404 on /v1/fans is no fans, not a failure");
  session.stopPolling();
  assert.deepEqual(state.fans, []);
});

test("a room with only a fan is listed, and its fans are in its group", async () => {
  await connect([ceiling]);
  state.rooms = [{ id: 11, name: "Living Room", names: {} }, { id: 10, name: "Kitchen", names: {} }];
  state.lights = [];
  state.thermostats = [];
  state.blinds = [];
  state.cameras = [];
  state.relays = [];
  state.doorbells = [];
  state.devices = [];
  assert.deepEqual(visibleRooms().map((entry) => entry.room.id), [11]);
  assert.deepEqual(roomGroup(11).fans.map((fan) => fan.id), [41]);
});

test("scene steps and Copy the house take fans", async () => {
  await connect([ceiling, patio, { ...ceiling, id: 43, name: "Attic Fan", speed: null }]);
  state.lights = [];
  state.thermostats = [];
  state.blinds = [];
  assert.ok(STEP_TYPES.includes("fans"));
  assert.deepEqual(sceneSet(ceiling), { speed: 2 });
  assert.deepEqual(sceneSet(patio), { on: false });
  assert.deepEqual(sceneSet({ ...ceiling, speed: null }), { on: true }, "on, at the speed it chooses");
  const { steps, left } = copyHouse();
  assert.equal(left, 0);
  assert.deepEqual(
    steps.map((step) => [step.type, step.device_ids, step.set]),
    [
      ["fans", [41], { speed: 2 }],
      ["fans", [42], { on: false }],
      ["fans", [43], { on: true }],
    ]
  );
  assert.equal(stepAction({ type: "fans", set: { speed: 3 } }), "Medium High speed");
  assert.equal(stepAction({ type: "fans", set: { on: false } }), "Off");
  assert.equal(stepAction({ type: "fans", set: { on: true } }), "On");
  assert.equal(stepWhat({ type: "fans", room_id: null, device_ids: null }), "All fans");
  assert.equal(stepWhat({ type: "fans", room_id: 11, device_ids: [41] }), "Ceiling Fan");
  const kept = currentSteps([{ type: "fans", room_id: null, device_ids: [41, 99], set: { on: true } }]);
  assert.deepEqual(kept.steps[0].device_ids, [41], "a fan gone from the project is taken out");
  assert.equal(kept.changed, true);
});

test("fans are named in English and Hebrew", async () => {
  assert.equal(fanStateLabel(ceiling), "On · Medium");
  assert.equal(fanStateLabel(patio), "Off");
  assert.equal(fanStateLabel({ ...ceiling, speed: null }), "On");
  assert.deepEqual([1, 2, 3, 4].map(fanSpeedLabel), ["Low", "Medium", "Medium High", "High"]);
  assert.equal(fanSpeedLabel(6), "Speed 6", "a speed the app has no name for");
  assert.equal(t("rooms.fansOnOf", { on: 1, count: 3 }), "1 of 3 fans on");
  await setLanguage("he");
  try {
    assert.equal(fanStateLabel(ceiling), "פועל · מהירות בינונית");
    assert.equal(fanStateLabel(patio), "כבוי");
    assert.deepEqual([1, 2, 3, 4].map(fanSpeedLabel), ["נמוכה", "בינונית", "בינונית־גבוהה", "גבוהה"]);
    assert.equal(stepAction({ type: "fans", set: { speed: 4 } }), "מהירות גבוהה");
    assert.equal(t("sections.fans"), "מאווררים");
    assert.equal(t("rooms.fansOff", { count: 1 }), "המאוורר כבוי");
  } finally {
    await setLanguage("en");
  }
});
