// Home's "Turn off all" (1.3.0; app/js/turn-off.js with views/home.js): the button a filtered list
// shows and its words with the count, in English and Hebrew; the second tap, its 5 seconds and
// Cancel; who sees it; which devices it names; the one request it sends (POST /v1/off), and each
// device's own with a driver before 1.3.0; and what it says when some did not turn off. Against a
// fake controller under fake time, with just enough of a browser.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

// ---- just enough of a browser: the elements the views build, storage, frames -----------------
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.listeners = {};
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener(type, listener) {
    (this.listeners[type] ||= []).push(listener);
  }
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  // Home's command field is kept over redraws and brought up to date in place (views/command.js).
  set textContent(text) {
    this.children = [document.createTextNode(String(text))];
  }
  replaceChildren(...children) {
    this.children = children;
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = {
  hidden: false,
  documentElement: {},
  addEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Node", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
const stored = new Map();
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

// ---- the fake controller ---------------------------------------------------------------------
// A DirectorLink that cannot seal (so requests carry the key), with these lights, thermostats and
// blinds. `off(body)` may answer POST /v1/off instead of the default (202, and they are off);
// `noOff`: a driver before 1.3.0, which has no such route; `patch(list, id, body)` may answer a
// device's PATCH instead; `rtt`: how long each answer takes.
const HOST = "controller.invalid";
const KEY = "ak_test";
const controller = { lights: [], thermostats: [], blinds: [], calls: [], off: null, noOff: false, patch: null, rtt: 0 };
const OFF = { lights: ["lights", { on: false }], climate: ["thermostats", { mode: "off" }], blinds: ["blinds", { position: 0 }] };

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

const later = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const body = init.body ? JSON.parse(init.body) : null;
  controller.calls.push({ at: Date.now(), method, path, body });
  if (controller.rtt) await later(controller.rtt);
  return handle(method, path, body);
};

function handle(method, path, body) {
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "member" });
  if (method === "POST" && path === "/v1/off") {
    if (controller.noOff) return answer(404, { status: 404, code: "NOT_FOUND", detail: "No route for POST /v1/off" });
    const custom = controller.off?.(body);
    if (custom) return answer(custom.status, custom.body);
    const [list, change] = OFF[body.type];
    controller[list] = controller[list].map((device) => (body.device_ids.includes(device.id) ? { ...device, ...change } : device));
    return answer(202, { ran: body.device_ids.length, skipped: 0, failed: 0, problems: [] });
  }
  const one = path.match(/^\/v1\/(lights|thermostats|blinds)\/(\d+)$/);
  if (one && method === "PATCH") {
    const [, list, id] = one;
    const custom = controller.patch?.(list, Number(id), body);
    if (custom) return answer(custom.status, custom.body);
    const device = controller[list].find((item) => item.id === Number(id));
    controller[list] = controller[list].map((item) => (item.id === Number(id) ? { ...item, ...body } : item));
    return answer(202, device);
  }
  const all = path.match(/^\/v1\/(lights|thermostats|blinds)$/);
  if (all && method === "GET") return answer(200, { items: controller[all[1]].map((device) => ({ ...device })) });
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
}

const { state, ui, notify } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const controls = await import("../../app/js/controls.js");
const { blindStateLabel } = await import("../../app/js/model.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const turnOff = await import("../../app/js/turn-off.js");
const { homeView } = await import("../../app/js/views/home.js");

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

// ---- the home ----------------------------------------------------------------------------------
const ROOMS = [
  { id: 10, name: "Kitchen" },
  { id: 11, name: "Living Room" },
  { id: 12, name: "Kids" },
];
const room = (id) => ({ id, name: ROOMS.find((item) => item.id === id).name });
const light = (id, name, roomId, on, fields = {}) => ({ id, name, room: room(roomId), on, dimmable: true, brightness: on ? 80 : 0, brightness_reported: true, ...fields });
const thermostat = (id, name, roomId, mode, modes = ["off", "heat", "cool"]) => ({
  id, name, room: room(roomId), mode, modes, fan_speed: null, fan_speeds: [], current_temperature: 25, target_temperature: 24, target_temperature_min: 10, target_temperature_max: 32,
});
const blind = (id, name, roomId, position) => ({
  id, name, room: room(roomId), position, position_reported: true, capabilities: { position: true, stop: true }, moving: false, direction: null, target_position: position,
});
const LIGHTS = [
  light(20, "Kitchen Island", 10, true),
  light(21, "Hall Light", 11, false, { dimmable: false, brightness: null }),
  light(22, "Desk Lamp", 11, true),
  light(23, "Night Light", 12, true),
];
const THERMOSTATS = [
  thermostat(30, "Parents", 11, "cool"),
  thermostat(31, "Study", 10, "off"),
  thermostat(32, "Bathroom floor", 11, "heat", ["off", "heat"]),
  // On, and it has no Off mode: nothing can switch it off from here.
  thermostat(33, "Garage", 10, "cool", ["heat", "cool"]),
];
const BLINDS = [blind(50, "Window Blind", 11, 40), blind(51, "Kitchen Blind", 10, 0), blind(52, "Terrace Shade", 11, 100)];
const copies = (list) => list.map((device) => ({ ...device }));

// Connected to the fake controller with this home, as after loading it, on Home.
async function connect({ role = "member", hidden = [], lights = LIGHTS, thermostats = THERMOSTATS, blinds = BLINDS } = {}) {
  session.forgetKey();
  turnOff.resetTurnOff();
  // Requests and timers of the test before end first.
  await advance(20000, 500);
  Object.assign(controller, { calls: [], off: null, noOff: false, patch: null, rtt: 0 });
  controller.lights = copies(lights);
  controller.thermostats = copies(thermostats);
  controller.blinds = copies(blinds);
  Object.assign(state, {
    host: HOST, apiKey: KEY, role, status: "connected", loaded: true, notice: null, errors: {}, pending: {},
    rooms: ROOMS, lights: copies(lights), thermostats: copies(thermostats), blinds: copies(blinds),
    fans: [], cameras: [], relays: [], doorbells: [], devices: [], scenes: [],
    profile: hidden.length ? { prefs: { hidden_rooms: hidden } } : null,
  });
  ui.filter = null;
  notify();
  await advance(100);
}

// ---- reading the screen ------------------------------------------------------------------------
const home = () => homeView({ openCamera() {}, openFavoritesPicker() {} });

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function byKey(nodes, key) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node.dataset?.key === key) found = node;
  });
  return found;
}
function byClass(nodes, name) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && typeof node.className === "string" && node.className.split(/\s+/).includes(name)) found = node;
  });
  return found;
}
const keys = () => {
  const list = [];
  walk(home(), (node) => node.dataset?.key && list.push(node.dataset.key));
  return list;
};
const text = (nodes) => [nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" | ");
// The words on the Turn off all button, or null when there is none.
const button = () => byKey(home(), "turn-off")?.textContent ?? null;
const note = () => byClass(home(), "turn-off-note")?.textContent ?? null;
const shownState = () => byClass(home(), "turn-off-state")?.textContent ?? null;

async function click(key) {
  const element = byKey(home(), key);
  assert.ok(element, `no ${key} on Home: ${keys().join(", ")}`);
  assert.equal(element.attributes.disabled, undefined, `${key} is disabled`);
  for (const listener of element.listeners.click || []) listener({ stopPropagation() {}, preventDefault() {} });
  await settle();
}

const offRequests = () => controller.calls.filter((call) => call.method === "POST" && call.path === "/v1/off");
const patches = () => controller.calls.filter((call) => call.method === "PATCH");
const lightOn = (id) => state.lights.find((item) => item.id === id).on;

test("only a filtered list has the button, with how many are on or open", async () => {
  await setLanguage("en");
  await connect();
  assert.equal(button(), null, "not with every room shown");
  assert.ok(!keys().some((key) => key.startsWith("turn-off")), "never on the chips");
  assert.equal(byKey(home(), "filter:lights").textContent, "3 lights on", "the chip says what it said");

  await click("filter:lights");
  assert.equal(button(), "Turn off all 3");
  assert.ok(text(home()).includes("Rooms with lights on"));
  assert.ok(keys().includes("filter-clear"), "next to Show all");
  await click("filter:climate");
  assert.equal(byKey(home(), "filter:climate").textContent, "3 AC on");
  assert.equal(button(), "Turn off all 2", "AC and floor heating that are on; not the Garage, which has no Off");
  await click("filter:blinds");
  assert.equal(button(), "Close all 2", "the open blinds, not the closed one");
  await click("filter-clear");
  assert.equal(ui.filter, null);
  assert.equal(button(), null);

  await connect({ lights: [LIGHTS[0], LIGHTS[1]], thermostats: [THERMOSTATS[0], THERMOSTATS[1]], blinds: [BLINDS[0], BLINDS[1]] });
  const one = {};
  for (const filter of ["lights", "climate", "blinds"]) {
    await click(`filter:${filter}`);
    one[filter] = button();
  }
  assert.deepEqual(one, { lights: "Turn off the light", climate: "Turn off the AC", blinds: "Close the blind" });
  assert.equal(offRequests().length, 0, "nothing is sent by looking");
});

test("the words in Hebrew, right to left", async () => {
  await setLanguage("he");
  try {
    await connect();
    await click("filter:lights");
    assert.equal(button(), "כיבוי כל ה-3");
    await click("turn-off");
    assert.equal(button(), "הקישו שוב לכיבוי 3");
    assert.equal(byKey(home(), "turn-off-cancel").textContent, "ביטול");
    await click("filter:blinds");
    assert.equal(button(), "סגירת שני התריסים", "a filter change drops the second tap");
    await click("turn-off");
    assert.equal(button(), "הקישו שוב לסגירת שניהם");
    await connect({ lights: [LIGHTS[0], LIGHTS[1]] });
    await click("filter:lights");
    assert.equal(button(), "כיבוי התאורה");
    controller.off = () => ({ status: 202, body: { ran: 0, skipped: 0, failed: 1, problems: [{ step: 1, device_id: 20, outcome: "failed", code: "CONTROL4_COMMAND_FAILED", detail: "offline" }] } });
    await click("turn-off");
    await click("turn-off");
    await advance(100);
    assert.equal(note(), "תאורה אחת לא כבתה:Kitchen Island · Kitchen");
  } finally {
    await setLanguage("en");
  }
});

test("the first tap asks for a second within 5 seconds; Cancel and the time running out send nothing", async () => {
  await connect();
  await click("filter:lights");
  await click("turn-off");
  assert.equal(button(), "Tap again to turn off 3");
  assert.ok(byKey(home(), "turn-off").className.includes("is-confirm"));
  assert.ok(keys().includes("turn-off-cancel"), "with Cancel");
  assert.ok(!keys().includes("filter-clear"), "in place of Show all");
  await advance(4900);
  assert.equal(button(), "Tap again to turn off 3", "still waiting at 4.9 s");
  await advance(200);
  assert.equal(button(), "Turn off all 3", "gone after 5 s");
  assert.ok(keys().includes("filter-clear"));

  await click("turn-off");
  await click("turn-off-cancel");
  assert.equal(button(), "Turn off all 3");
  await click("turn-off");
  await advance(3000);
  await click("turn-off");
  await advance(100);
  assert.equal(offRequests().length, 1, "only the second tap within the 5 seconds sends");
  assert.equal(patches().length, 0);
  assert.equal(offRequests()[0].at, Date.now() - 100, "sent at the second tap");
});

test("the second tap turns them off in one request; the button goes and the filter stays", async () => {
  await connect();
  controller.rtt = 300;
  await click("filter:lights");
  await click("turn-off");
  await click("turn-off");
  assert.equal(button(), "Turning off…");
  assert.equal(byKey(home(), "turn-off").attributes.disabled, "", "no third tap while it runs");
  await advance(450);
  assert.equal(button(), "Turning off…", "until the answer comes");
  assert.equal(offRequests().length, 1);
  assert.deepEqual(offRequests()[0].body, { type: "lights", device_ids: [20, 22, 23] });
  assert.equal(patches().length, 0, "not one request per light");

  await advance(300);
  assert.equal(shownState(), "Done");
  assert.equal(button(), null, "nothing is on any more");
  assert.deepEqual([20, 22, 23].map(lightOn), [false, false, false], "shown off at once");
  assert.equal(byKey(home(), "filter:lights").textContent, "All lights off", "the chip's count follows");
  assert.equal(ui.filter, "lights", "the filter stays");
  assert.ok(text(home()).includes("Rooms with lights on") && text(home()).includes("No rooms match right now."));

  const answeredAt = Date.now();
  await advance(2500);
  assert.ok(controller.calls.some((call) => call.method === "GET" && call.path === "/v1/lights" && call.at > answeredAt), "the lights are read again");
  assert.deepEqual([20, 22, 23].map(lightOn), [false, false, false], "as the controller reports them");
  await advance(2000);
  assert.equal(shownState(), null, "Done goes after a few seconds");
  assert.equal(button(), null);
  assert.ok(keys().includes("filter-clear"));
});

test("AC goes to Off and blinds close: only the ones on or open", async () => {
  await connect();
  await click("filter:climate");
  await click("turn-off");
  await click("turn-off");
  await advance(100);
  assert.deepEqual(offRequests()[0].body, { type: "climate", device_ids: [30, 32] }, "not the Garage without Off, not the Study that is off");
  assert.deepEqual(state.thermostats.map((item) => item.mode), ["off", "off", "off", "cool"]);
  assert.equal(button(), null, "the Garage cannot be switched off from here: no button for it");

  // The blinds take a while: they show as closing, and the button does not come back meanwhile.
  controller.off = () => ({ status: 202, body: { ran: 2, skipped: 0, failed: 0, problems: [] } });
  await click("filter:blinds");
  await click("turn-off");
  await click("turn-off");
  assert.equal(blindStateLabel(state.blinds[0], controls.blindMove(50)), "Closing…", "at once");
  await advance(100);
  assert.deepEqual(offRequests()[1].body, { type: "blinds", device_ids: [50, 52] });
  assert.equal(blindStateLabel(state.blinds[2], controls.blindMove(52)), "Closing…");
  assert.ok(keys().includes("room:11"), "the living room is still in the list while its blinds close");
  await advance(5000);
  assert.equal(button(), null, "nothing left to close");
});

test("rooms this person hides are left alone", async () => {
  await connect({ hidden: [12] });
  await click("filter:lights");
  assert.equal(button(), "Turn off all 2");
  await click("turn-off");
  await click("turn-off");
  await advance(100);
  assert.deepEqual(offRequests()[0].body.device_ids, [20, 22], "not the Night Light in the Kids room");
  assert.equal(lightOn(23), true);
});

test("viewers do not see it and cannot run it; members, doors and admins do", async () => {
  await connect({ role: "viewer" });
  for (const filter of ["lights", "climate", "blinds"]) {
    await click(`filter:${filter}`);
    assert.equal(button(), null, filter);
    assert.ok(keys().includes("filter-clear"), "the filter still works");
    await turnOff.pressTurnOff(filter);
    await turnOff.pressTurnOff(filter);
  }
  await advance(100);
  assert.equal(offRequests().length + patches().length, 0, "nothing is sent");

  for (const role of ["doors", "admin"]) {
    await connect({ role });
    await click("filter:lights");
    assert.equal(button(), "Turn off all 3", role);
  }
});

test("the devices that did not turn off are named with their room; the others are off", async () => {
  await connect();
  controller.off = (body) => ({
    status: 202,
    body: { ran: 2, skipped: 0, failed: 1, problems: [{ step: 1, device_id: 22, outcome: "failed", code: "CONTROL4_COMMAND_FAILED", detail: "Director rejected the light command" }] },
  });
  await click("filter:lights");
  await click("turn-off");
  await click("turn-off");
  await advance(100);
  assert.equal(note(), "1 light didn’t turn off:Desk Lamp · Living Room");
  assert.equal(byClass(home(), "turn-off-note").attributes.role, "alert");
  assert.deepEqual([20, 22, 23].map(lightOn), [false, true, false], "the rest are off");
  assert.equal(button(), "Turn off the light", "and it can be tried again");
  await advance(15100);
  assert.equal(note(), null, "the note goes after a while");

  // Many that did not: the first ones by name, the rest counted.
  const many = Array.from({ length: 11 }, (_unused, index) => light(100 + index, `Spot ${index + 1}`, 11, true));
  await connect({ lights: many });
  controller.off = (body) => ({
    status: 202,
    body: { ran: 1, skipped: 0, failed: 10, problems: body.device_ids.slice(0, 10).map((id) => ({ step: 1, device_id: id, outcome: "failed", code: "CONTROL4_COMMAND_FAILED", detail: "x" })) },
  });
  await click("filter:lights");
  await click("turn-off");
  await click("turn-off");
  await advance(100);
  const failed = note();
  assert.ok(failed.startsWith("10 lights didn’t turn off:"), failed);
  assert.ok(failed.includes("Spot 8 · Living Room") && !failed.includes("Spot 9 ·"), failed);
  assert.ok(failed.endsWith("+2 more"), failed);
});

test("a request that fails changes nothing and says why", async () => {
  await connect();
  controller.off = () => ({ status: 503, body: { status: 503, code: "UNAVAILABLE", detail: "Director is busy" } });
  await click("filter:blinds");
  await click("turn-off");
  await click("turn-off");
  await advance(100);
  assert.ok(note()?.startsWith("Couldn’t close them:"), note());
  assert.equal(controls.blindMove(50), null, "the blinds do not show as closing");
  assert.equal(button(), "Close all 2", "it can be tried again");
  assert.deepEqual(state.blinds.map((item) => item.position), [40, 0, 100]);
});

test("a driver before 1.3.0 gets each device's own command, all at once", async () => {
  await connect();
  controller.noOff = true;
  controller.rtt = 200;
  controller.patch = (list, id) => (id === 22 ? { status: 409, body: { status: 409, code: "DEVICE_OFFLINE", detail: "Offline" } } : null);
  await click("filter:lights");
  await click("turn-off");
  await click("turn-off");
  await advance(700);
  assert.equal(offRequests().length, 1, "asked once");
  const sent = patches();
  assert.deepEqual(sent.map((call) => `${call.path} ${JSON.stringify(call.body)}`), ['/v1/lights/20 {"on":false}', '/v1/lights/22 {"on":false}', '/v1/lights/23 {"on":false}']);
  assert.equal(new Set(sent.map((call) => call.at)).size, 1, "together, not one after another");
  await advance(300);
  assert.equal(note(), "1 light didn’t turn off:Desk Lamp · Living Room");
  assert.deepEqual([20, 22, 23].map(lightOn), [false, true, false]);

  await connect();
  controller.noOff = true;
  await click("filter:climate");
  await click("turn-off");
  await click("turn-off");
  await advance(100);
  assert.deepEqual(patches().map((call) => `${call.path} ${JSON.stringify(call.body)}`), ['/v1/thermostats/30 {"mode":"off"}', '/v1/thermostats/32 {"mode":"off"}']);
  await click("filter:blinds");
  await click("turn-off");
  await click("turn-off");
  await advance(100);
  assert.deepEqual(patches().slice(2).map((call) => `${call.path} ${JSON.stringify(call.body)}`), ['/v1/blinds/50 {"position":0}', '/v1/blinds/52 {"position":0}']);
  assert.equal(shownState(), "Done");
});

// ---- 1.10.0 (ADR-066): lights named for heating ----------------------------------------------------

// Heaters wired as lights (KNX boilers, floor heating, towel warmers), kept on or off by Composer
// programming: Turn off all and a room's All off leave them as they are, and say so.
const heater = (id, name, roomId, on = true) => light(id, name, roomId, on, { dimmable: false, brightness: null });
const heatersNote = () => byClass(home(), "turn-off-heaters")?.textContent ?? null;

test("Turn off all leaves lights named for heating as they are, and says so with its second tap and its result", async () => {
  await setLanguage("en");
  await connect({ lights: [...LIGHTS, heater(24, "Towel warmer", 11), heater(25, "דוד הורים", 12)] });
  ui.filter = "lights";
  notify();
  assert.equal(button(), "Turn off all 3", "the heaters are not counted");
  assert.equal(heatersNote(), null, "said with the second tap");
  await click("turn-off");
  assert.equal(button(), "Tap again to turn off 3");
  assert.equal(heatersNote(), "Turn off all leaves the heaters ⁨Towel warmer⁩, ⁨דוד הורים⁩ as they are.");
  await click("turn-off");
  await advance(100);
  assert.deepEqual(offRequests().map((call) => call.body), [{ type: "lights", device_ids: [20, 22, 23] }]);
  assert.equal(lightOn(24), true);
  assert.equal(lightOn(25), true);
  assert.equal(shownState(), "Done");
  assert.equal(heatersNote(), "Turn off all leaves the heaters ⁨Towel warmer⁩, ⁨דוד הורים⁩ as they are.");

  await setLanguage("he");
  try {
    await connect({ lights: [...LIGHTS, heater(25, "דוד הורים", 12)] });
    ui.filter = "lights";
    notify();
    await click("turn-off");
    assert.equal(heatersNote(), "הכיבוי משאיר את גוף החימום „⁨דוד הורים⁩” כמו שהוא.");
  } finally {
    await setLanguage("en");
  }

  // Only a heater on: nothing to turn off, and it says why.
  await connect({ lights: [light(20, "Kitchen Island", 10, false), heater(24, "Towel warmer", 11)] });
  ui.filter = "lights";
  notify();
  assert.equal(button(), null);
  assert.equal(heatersNote(), "Turn off all leaves the heater “⁨Towel warmer⁩” as it is.");
  assert.deepEqual(turnOff.offTargets("lights"), []);
  assert.deepEqual(turnOff.keptHeaters("lights").map((device) => device.id), [24]);
  assert.deepEqual(turnOff.keptHeaters("climate"), []);
});

test("a room's All off leaves lights named for heating as they are, and says so", async () => {
  await setLanguage("en");
  const { roomView } = await import("../../app/js/views/room.js");
  const view = () => roomView(11, { openCamera() {} });
  await connect({ lights: [...LIGHTS, heater(24, "Towel warmer", 11)] });
  assert.equal(byClass(view(), "all-off-heaters")?.textContent, "All off leaves the heater “⁨Towel warmer⁩” as it is.");
  const allOff = byKey(view(), "all-off");
  assert.equal(allOff.attributes.disabled, undefined);
  for (const listener of allOff.listeners.click || []) listener({ stopPropagation() {}, preventDefault() {} });
  await advance(1500);
  assert.deepEqual(patches().map((call) => [call.path, call.body]), [
    ["/v1/lights/22", { on: false }],
    ["/v1/thermostats/30", { mode: "off" }],
    ["/v1/thermostats/32", { mode: "off" }],
  ]);
  assert.equal(lightOn(24), true, "the heater is left on");
  // Its own switch still turns it off.
  controls.setLight(state.lights.find((item) => item.id === 24), { on: false });
  await advance(1500);
  assert.deepEqual(patches().slice(3).map((call) => [call.path, call.body]), [["/v1/lights/24", { on: false }]]);

  // Only a heater on, and no AC: All off has nothing to do.
  await connect({ lights: [heater(24, "דוד הורים", 11)], thermostats: [] });
  assert.equal(byKey(view(), "all-off").attributes.disabled, "");
  await setLanguage("he");
  try {
    assert.equal(byClass(view(), "all-off-heaters")?.textContent, "כיבוי הכול משאיר את גוף החימום „⁨דוד הורים⁩” כמו שהוא.");
  } finally {
    await setLanguage("en");
  }
  // Without a heater on, nothing is said.
  await connect();
  assert.equal(byClass(view(), "all-off-heaters"), null);
});
