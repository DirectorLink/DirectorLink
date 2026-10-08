// Doors and gates of Control4's Relay Door, Gate and Garage Door Controllers in the app (DirectorLink
// 1.10.0, ADR-069): a door's line and its favorite say what it is (Door, Gate, Garage door; "Door or
// gate" for a relay of its own and for every relay of a driver before 1.10.0) and, when the
// controller has a contact, open or closed, in English, Hebrew, Spanish and Italian; the two taps
// open it as any door (POST /v1/relays/{id}/pulse), and a controller that holds its relay is
// explained in the app's words. A controller's button shown as the KNX relay it drives, and a
// DoorBird's button, are no "other device" in their room (1.10.1: `part_of` in /v1/devices).
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

const HOST = "controller.invalid";
const KEY = "ak_test";
const stored = new Map();

class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.className = "";
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
  dispatch(type, init = {}) {
    const event = { type, currentTarget: this, target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}, ...init };
    for (const listener of this.listeners[type] || []) listener(event);
    if (type === "click" && typeof this.onclick === "function") this.onclick(event);
    return event;
  }
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "", replace: () => {} };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: { append() {} },
  addEventListener() {},
  removeEventListener() {},
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
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
    clear: () => stored.clear(),
  },
  configurable: true,
});
globalThis.history = { state: { directorlinkInApp: true }, back: () => {} };
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-06T15:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// The fake controller: a DirectorLink that cannot seal (so requests carry the key). `refuse`: the
// problem a pulse gets instead of 202.
const controller = { calls: [], refuse: null };

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  controller.calls.push({ method, path });
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (!init.headers?.Authorization) return answer(401, { status: 401, code: "UNAUTHORIZED" });
  const pulse = path.match(/^\/v1\/relays\/(\d+)\/pulse$/);
  if (pulse && method === "POST") {
    if (controller.refuse) return answer(409, { status: 409, ...controller.refuse });
    return answer(202, gates.find((item) => item.id === Number(pulse[1])));
  }
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "admin" });
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { state, ui, notify } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const { relayIsOpen, relayLabel } = await import("../../app/js/model.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { relayRow } = await import("../../app/js/components.js");

async function settle() {
  for (let index = 0; index < 8; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function advance(ms, step = 100) {
  for (let done = 0; done < ms; done += step) {
    mock.timers.tick(Math.min(step, ms - done));
    await settle();
  }
  await settle();
}

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function find(nodes, check) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node instanceof FakeElement && check(node)) found = node;
  });
  return found;
}
const byKey = (nodes, key) => find(nodes, (node) => node.dataset.key === key);
const byClass = (nodes, name) => find(nodes, (node) => typeof node.className === "string" && node.className.split(/\s+/).includes(name));
const plain = (text) => String(text ?? "").replace(/[⁦-⁩]/g, "");

const living = { id: 11, name: "Living Room" };
const kitchen = { id: 10, name: "Kitchen" };
// As DirectorLink 1.10.0 lists them (driver/tests/c4mock.lua withRelayControllers), and a relay of a
// driver before 1.10.0.
const gates = [
  { id: 71, name: "Main Gate", room: living, state: null, state_reported: false, kind: "gate", door_state: "closed" },
  { id: 72, name: "Garage Door", room: kitchen, state: null, state_reported: false, kind: "garage_door", door_state: null },
  { id: 75, name: "Back Door Relay", room: kitchen, state: "open", state_reported: true, kind: "door", door_state: "partly_open" },
  { id: 70, name: "Main Door", room: kitchen, state: null, state_reported: true, kind: "relay", door_state: null },
];
const older = { id: 70, name: "Main Door", room: kitchen, state: null, state_reported: true };

async function connect(access = null) {
  session.forgetKey();
  await advance(100);
  controller.calls = [];
  controller.refuse = null;
  Object.assign(state, {
    host: HOST,
    apiKey: KEY,
    role: "admin",
    access,
    status: "connected",
    loaded: true,
    rooms: [kitchen, living],
    lights: [],
    thermostats: [],
    fans: [],
    blinds: [],
    cameras: [],
    relays: gates.map((item) => ({ ...item })),
    doorbells: [],
    refrigerators: [],
    devices: [],
    errors: {},
    system: { bridge: { version: "1.10.0" }, inventory: { relays: 4 }, features: {} },
  });
  ui.relayStage = {};
  notify();
  await advance(100);
}

test("a door's line says what it is and, with a contact, open or closed, in every language", async () => {
  await setLanguage("en");
  assert.equal(relayLabel(gates[0]), "Gate · Closed");
  assert.equal(relayLabel(gates[1]), "Garage door", "no contact: no state");
  assert.equal(relayLabel(gates[2]), "Door · Partly open");
  assert.equal(relayLabel(gates[3]), "Door or gate", "a relay of its own");
  assert.equal(relayLabel(older), "Door or gate", "a driver before 1.10.0");
  assert.equal(relayLabel({ kind: "sliding_window", door_state: "open" }), "Door or gate", "a kind this app does not know");
  assert.equal(relayIsOpen(gates[2]), true);
  assert.equal(relayIsOpen(gates[0]), false);
  assert.equal(relayIsOpen(older), false);

  await setLanguage("he");
  assert.equal(relayLabel(gates[0]), "שער · סגור");
  assert.equal(relayLabel(gates[2]), "דלת · פתוחה חלקית");
  assert.equal(relayLabel(gates[1]), "דלת מוסך");
  await setLanguage("es");
  assert.equal(relayLabel(gates[0]), "Portón · Cerrado");
  assert.equal(relayLabel({ ...gates[1], door_state: "open" }), "Puerta de garaje · Abierta");
  await setLanguage("it");
  assert.equal(relayLabel(gates[0]), "Cancello · Chiuso");
  assert.equal(relayLabel(gates[2]), "Porta · Aperta in parte");
  await setLanguage("en");
});

test("its row shows it, and the two taps open it as any door", async () => {
  await setLanguage("en");
  await connect();
  let row = relayRow(state.relays[0]);
  assert.equal(plain(byClass(row, "device-meta").textContent), "Gate · Closed");
  assert.ok(!row.className.includes("is-open"));
  assert.ok(relayRow(state.relays[2]).className.split(" ").includes("is-open"), "a door partly open stands out");

  byKey(row, "relay:71:open").dispatch("click");
  await settle();
  assert.equal(ui.relayStage[71], "confirm", "the first tap asks for a second");
  assert.equal(controller.calls.filter((call) => call.method === "POST").length, 0);
  row = relayRow(state.relays[0]);
  byKey(row, "relay:71:open").dispatch("click");
  await advance(200);
  assert.deepEqual(controller.calls.filter((call) => call.method === "POST").map((call) => call.path), ["/v1/relays/71/pulse"]);
  assert.equal(ui.relayStage[71], "sent");
});

test("a controller that would hold its relay says why, and a member without doors sees the state", async () => {
  await setLanguage("en");
  await connect();
  controller.refuse = { code: "HOLD_NOT_ALLOWED", detail: "This controller holds its relay" };
  byKey(relayRow(state.relays[0]), "relay:71:open").dispatch("click");
  await settle();
  byKey(relayRow(state.relays[0]), "relay:71:open").dispatch("click");
  await advance(200);
  assert.match(state.errors["relay:71"].text, /Relay Configuration to Pulse/);

  await connect({ role: "member", doors: false });
  const row = relayRow(state.relays[0]);
  assert.equal(plain(byClass(row, "device-meta").textContent), "Gate · Closed · Opening needs door access");
  assert.equal(byKey(row, "relay:71:open"), null, "no Open");
});

test("a controller's gate is opened by its name in a command, in every language (a door action, which waits for its second tap)", async () => {
  const { commandCatalog } = await import("../../app/js/commands.js");
  const { parseCommand } = await import("../../app/js/command-parser.js");
  await setLanguage("en");
  await connect();
  for (const [language, name, text] of [
    ["en", "Main Gate", "open the main gate"],
    ["he", "שער חניה", "פתחו את שער החניה"],
    ["es", "Portón principal", "abre el portón principal"],
    ["it", "Cancello principale", "apri il cancello principale"],
  ]) {
    // The KNX relay 70 "Main Door" is left out: "main gate" would be either (door and gate are one
    // kind of device to the parser, ADR-063, which never guesses).
    state.relays = gates.filter((item) => item.id !== 70).map((item) => (item.id === 71 ? { ...item, name } : { ...item }));
    const catalog = commandCatalog();
    assert.ok(catalog.devices.some((device) => device.kind === "relay" && device.id === 71 && device.canOpen), "in the catalog as a door");
    const result = parseCommand(text, catalog, { language });
    assert.equal(result.status, "ok", `${text}: ${JSON.stringify(result)}`);
    assert.equal(result.action.type, "door", text);
    assert.deepEqual(result.action.device, { kind: "relay", id: 71 }, text);
  }
  await setLanguage("en");
});

// As DirectorLink 1.10.1 lists them in /v1/devices (driver/tests/c4mock.lua: withRelayControllers,
// the DoorBird, the camera of no driver, the alarm's partition), all in the Kitchen.
const kitchenDevices = [
  { id: 73, name: "Back Door", type: "other", room: kitchen, supported: false, href: null, part_of: 75 },
  { id: 75, name: "Back Door Relay", type: "relay", room: kitchen, supported: true, href: "/v1/relays/75", part_of: null },
  { id: 91, name: "DoorBird", type: "other", room: kitchen, supported: false, href: null, part_of: 93 },
  { id: 40, name: "Front Door", type: "other", room: kitchen, supported: false, href: null, part_of: null },
  { id: 93, name: "Front Gate", type: "doorbell", room: kitchen, supported: true, href: "/v1/doorbells/93", part_of: null },
  { id: 81, name: "Garage", type: "other", room: kitchen, supported: false, href: null, part_of: null },
  { id: 90, name: "Gate Intercom", type: "other", room: kitchen, supported: false, href: null, part_of: 93 },
];
const frontGate = { id: 93, name: "Front Gate", room: kitchen, camera: null, can_open: true, connected: null, events: [], last_ring_at: null, last_opened_at: null, last_motion_at: null, last_access_at: null };

function othersIn(nodes) {
  const section = byClass(nodes, "others");
  if (!section) return null;
  return {
    title: plain(section.children[0].textContent),
    names: byClass(section, "others-list").children.map((item) => plain(item.textContent)),
  };
}

test("a door controller's button and a DoorBird's button are no other device in their room, in every language", async () => {
  const { roomView } = await import("../../app/js/views/room.js");
  const { t } = await import("../../app/js/i18n.js");
  for (const language of ["en", "he", "es", "it"]) {
    await setLanguage(language);
    await connect();
    state.devices = kitchenDevices.map((item) => ({ ...item }));
    state.doorbells = [{ ...frontGate }];
    state.alarm = null;
    let room = roomView(kitchen.id, { openCamera() {} });
    assert.ok(byKey(room, "relay:75:open"), `${language}: the door, once, under its relay`);
    // The alarm is not shown (Alarm Status Off): its partition is a device the app cannot control.
    assert.deepEqual(othersIn(room), { title: t("rooms.otherDevices", { count: 2 }), names: ["Front Door", "Garage"] }, language);

    // With the alarm on Home, its partition is not one either.
    state.alarm = { enabled: true, partitions: [{ id: 81, name: "Garage", room: kitchen }] };
    room = roomView(kitchen.id, { openCamera() {} });
    assert.deepEqual(othersIn(room), { title: t("rooms.otherDevices", { count: 1 }), names: ["Front Door"] }, language);
  }
  await setLanguage("en");
  state.alarm = null;

  // Part of a device this app does not show (not read, or not the user's): a device of its own.
  state.doorbells = [];
  assert.deepEqual(othersIn(roomView(kitchen.id, { openCamera() {} })).names, ["DoorBird", "Front Door", "Garage", "Gate Intercom"]);
  // A driver before 1.10.1 says no part_of: as before, every device it cannot control.
  state.doorbells = [{ ...frontGate }];
  state.devices = kitchenDevices.map(({ part_of: _partOf, ...item }) => item);
  assert.deepEqual(othersIn(roomView(kitchen.id, { openCamera() {} })), {
    title: "5 other devices",
    names: ["Back Door", "DoorBird", "Front Door", "Garage", "Gate Intercom"],
  });
});
