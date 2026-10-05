// Say or type a command (1.9.0, ADR-063): the field on Home (app/js/views/command.js with
// js/commands.js). Who gets it; what it shows it understood before it acts, and the result; the
// requests it sends (the same as a tap's); the question when two match, and the option chosen;
// "I didn't understand" with examples by the user's own names, and nothing sent; doors and gates
// only with their own second tap; Turn off all with its confirm; a scene; the controller refusing;
// the words in Hebrew; the microphone where the browser has speech recognition. Against a fake
// controller under fake time, with just enough of a browser.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

// ---- just enough of a browser ----------------------------------------------------------------
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
  removeAttribute(name) {
    delete this.attributes[name];
  }
  append(...children) {
    this.children.push(...children);
  }
  replaceChildren(...children) {
    this.children = children;
  }
  focus() {
    document.activeElement = this;
  }
  blur() {
    if (document.activeElement === this) document.activeElement = null;
  }
  contains(node) {
    return node === this || this.children.some((child) => child instanceof FakeElement && child.contains(node));
  }
  querySelectorAll(selector) {
    // Only what the app asks of its dialog: "[data-key]".
    const found = [];
    const visit = (node) => {
      for (const child of node.children || []) {
        if (child instanceof FakeElement && selector === "[data-key]" && child.dataset.key) found.push(child);
        visit(child);
      }
    };
    visit(this);
    return found;
  }
  // A <dialog>.
  showModal() {
    this.open = true;
  }
  close() {
    if (!this.open) return;
    this.open = false;
    for (const listener of this.listeners.close || []) listener({ target: this });
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  set textContent(text) {
    this.children = [Object.assign(new FakeNode(), { textContent: String(text) })];
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
const body = new FakeElement("body");
globalThis.document = {
  hidden: false,
  body,
  documentElement: {},
  addEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (Windows NT 10.0) Chrome/140", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
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
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-05T08:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// A browser's speech recognition (Chrome's webkitSpeechRecognition): what the app set and started.
// As the Web Speech API says: stop() ends with what it heard so far as the final result, abort()
// with none (and an "aborted" error).
const heard = [];
class FakeRecognition {
  constructor() {
    heard.push(this);
    this.started = false;
    this.interim = "";
  }
  start() {
    this.started = true;
  }
  stop() {
    if (this.interim) {
      const result = [{ transcript: this.interim }];
      result.isFinal = true;
      this.onresult?.({ results: [result] });
    }
    this.onend?.();
  }
  abort() {
    this.aborted = true;
    this.onerror?.({ error: "aborted" });
    this.onend?.();
  }
  // Words heard so far, not final yet.
  hear(transcript) {
    this.interim = transcript;
    const result = [{ transcript }];
    result.isFinal = false;
    this.onresult?.({ results: [result] });
  }
  // The service heard `alternatives` (the likeliest first), finally.
  say(...alternatives) {
    const result = alternatives.map((transcript) => ({ transcript }));
    result.isFinal = true;
    this.onresult?.({ results: [result] });
    this.onend?.();
  }
}
globalThis.webkitSpeechRecognition = FakeRecognition;

// ---- the fake controller ---------------------------------------------------------------------
const HOST = "controller.invalid";
const KEY = "ak_test";
const controller = { lights: [], thermostats: [], blinds: [], relays: [], calls: [], patch: null, rtt: 0 };

function answer(status, json) {
  return new Response(JSON.stringify(json), { status, headers: { "Content-Type": "application/json" } });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const sent = init.body ? JSON.parse(init.body) : null;
  controller.calls.push({ method, path, body: sent });
  if (controller.rtt) await new Promise((resolve) => setTimeout(resolve, controller.rtt));
  return handle(method, path, sent);
};

function handle(method, path, sent) {
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "member" });
  if (method === "POST" && path === "/v1/off") {
    const list = { lights: "lights", climate: "thermostats", blinds: "blinds" }[sent.type];
    const change = { lights: { on: false }, climate: { mode: "off" }, blinds: { position: 0 } }[sent.type];
    controller[list] = controller[list].map((device) => (sent.device_ids.includes(device.id) ? { ...device, ...change } : device));
    return answer(202, { ran: sent.device_ids.length, skipped: 0, failed: 0, problems: [] });
  }
  if (method === "POST" && /^\/v1\/relays\/\d+\/pulse$/.test(path)) return answer(202, { id: Number(path.split("/")[3]) });
  if (method === "POST" && /^\/v1\/scenes\/[0-9a-f]{8}\/run$/.test(path)) return answer(202, { ran: 3, skipped: 0, failed: 0, problems: [] });
  const one = path.match(/^\/v1\/(lights|thermostats|blinds)\/(\d+)$/);
  if (one && method === "PATCH") {
    const [, list, id] = one;
    const custom = controller.patch?.(list, Number(id), sent);
    if (custom) return answer(custom.status, custom.body);
    const device = controller[list].find((item) => item.id === Number(id));
    controller[list] = controller[list].map((item) => (item.id === Number(id) ? { ...item, ...sent, ...(list === "lights" && "brightness" in sent ? { on: sent.brightness > 0 } : {}) } : item));
    return answer(202, device);
  }
  if (one && method === "GET") return answer(200, controller[one[1]].find((item) => item.id === Number(one[2])));
  const all = path.match(/^\/v1\/(lights|thermostats|blinds|relays)$/);
  if (all && method === "GET") return answer(200, { items: controller[all[1]].map((device) => ({ ...device })) });
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
}

const { state, ui, notify } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { clearCommand } = await import("../../app/js/commands.js");
const { homeView } = await import("../../app/js/views/home.js");
const { climateView } = await import("../../app/js/views/climate.js");

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

// ---- the home ----------------------------------------------------------------------------------
const ROOMS = [
  { id: 10, name: "Kitchen", names: { he: "מטבח" } },
  { id: 11, name: "Living Room", names: { he: "סלון" } },
  { id: 12, name: "Porch" },
];
const room = (id) => ({ id, name: ROOMS.find((item) => item.id === id).name });
const light = (id, name, roomId, on) => ({ id, name, room: room(roomId), on, dimmable: true, brightness: on ? 80 : 0, brightness_reported: true });
const LIGHTS = [light(20, "Island", 10, true), light(21, "Spots", 10, true), light(22, "Spots", 11, false), light(23, "Desk Lamp", 11, true)];
const THERMOSTATS = [
  { id: 30, name: "Living Room AC", room: room(11), mode: "cool", modes: ["off", "heat", "cool"], fan_speed: null, fan_speeds: [], current_temperature: 25, target_temperature: 24, target_temperature_min: 16, target_temperature_max: 30 },
];
const RELAYS = [{ id: 50, name: "Main Gate", room: room(12), state: null, state_reported: false }];
const SCENES = [
  { id: "aa000001", name: "Good night", icon: "moon", steps: [{ type: "lights", room_id: null, set: { on: false } }] },
  { id: "aa000002", name: "Leave home", icon: "leave", steps: [{ type: "relays", device_ids: [50], set: {} }] },
];
const copies = (list) => list.map((device) => ({ ...device }));

async function connect({ role = "member", access = null } = {}) {
  session.forgetKey();
  clearCommand();
  await advance(20000, 500);
  Object.assign(controller, { calls: [], patch: null, rtt: 0 });
  controller.lights = copies(LIGHTS);
  controller.thermostats = copies(THERMOSTATS);
  controller.relays = copies(RELAYS);
  Object.assign(state, {
    host: HOST, apiKey: KEY, role, access, status: "connected", loaded: true, notice: null, errors: {}, pending: {},
    rooms: ROOMS, lights: copies(LIGHTS), thermostats: copies(THERMOSTATS), blinds: [], fans: [], cameras: [], relays: copies(RELAYS), doorbells: [], devices: [],
    scenes: SCENES, profile: null, system: { features: {} },
  });
  ui.relayStage = {};
  ui.sceneRuns = {};
  ui.offRuns = {};
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
const shown = () => byClass(home(), "command-output")?.textContent ?? null;

function fire(element, type, event = {}) {
  for (const listener of element.listeners[type] || []) listener({ preventDefault() {}, stopPropagation() {}, ...event });
}

// Types `text` into Home's field and sends it (Enter).
async function say(text) {
  const nodes = home();
  const input = byKey(nodes, "command-input:home");
  assert.ok(input, "Home has the field");
  input.value = text;
  fire(input, "input", { target: input });
  fire(byClass(nodes, "command-form"), "submit");
  await settle();
}

async function click(key) {
  const element = byKey(home(), key);
  assert.ok(element, `no ${key}`);
  assert.equal(element.attributes.disabled, undefined, `${key} is disabled`);
  fire(element, "click");
  await settle();
}

const sent = (method, pattern) => controller.calls.filter((call) => call.method === method && pattern.test(call.path));

// ---- tests -------------------------------------------------------------------------------------

test("Home has the field for those who control the home; other screens a way to it from the header", async () => {
  await setLanguage("en");
  await connect();
  const input = byKey(home(), "command-input:home");
  assert.equal(input.attributes.placeholder, "Say or type a command");
  assert.equal(input.attributes.enterkeyhint, "go");
  assert.ok(byKey(home(), "command-go:home"), "with Go");
  assert.equal(byKey(home(), "command-open"), null, "not in Home's header");
  assert.ok(byKey(climateView({}), "command-open"), "in another screen's header");
  await connect({ role: "viewer" });
  assert.equal(byKey(home(), "command-input:home"), null, "a viewer controls nothing");
  assert.equal(byKey(climateView({}), "command-open"), null);
});

test("it shows what it understood, sends the same requests as a tap, then the result", async () => {
  await connect();
  await say("kitchen lights off");
  assert.equal(shown(), "⁨Kitchen⁩: lights offWorking…", "what it understood, at once");
  await advance(1500);
  const patches = sent("PATCH", /^\/v1\/lights\//);
  assert.deepEqual(patches.map((call) => [call.path, call.body]), [
    ["/v1/lights/20", { on: false }],
    ["/v1/lights/21", { on: false }],
  ]);
  assert.equal(shown(), "⁨Kitchen⁩: lights offDone");
  assert.equal(byKey(home(), "command-input:home").value, "", "the field empties for the next one");
  assert.equal(state.lights.find((item) => item.id === 20).on, false);
  await advance(8000);
  assert.equal(shown(), null, "the result goes after a while");

  await say("living room AC to 23");
  await advance(1500);
  assert.deepEqual(sent("PATCH", /^\/v1\/thermostats\//).map((call) => call.body), [{ target_temperature: 23 }]);
  assert.equal(shown(), "⁨Living Room AC⁩: ⁦23°⁩Done");
});

test("nothing to change says so, and sends nothing", async () => {
  await connect();
  await say("living room spots off");
  await advance(100);
  assert.equal(sent("PATCH", /./).length, 0);
  assert.equal(shown(), "⁨Spots⁩: offNothing to change.", "the living room's Spots, already off");
});

test("two that match ask which one; the option chosen is done", async () => {
  await connect();
  await say("spots on");
  assert.match(shown(), /^Which one\?/);
  assert.ok(shown().includes("⁨⁨Spots⁩ · ⁨Kitchen⁩⁩: on"), shown());
  assert.equal(sent("PATCH", /./).length, 0, "nothing is done until one is chosen");
  await click("command-option:home:1");
  await advance(1500);
  assert.deepEqual(sent("PATCH", /./).map((call) => [call.path, call.body]), [["/v1/lights/22", { on: true }]]);
  assert.equal(byKey(home(), "command-input:home").value, "", "the words asked about go once one is chosen");
});

test("Home's field stays the same element over redraws, with its words: a keyboard's composition or dictation is not cut", async () => {
  await connect();
  const before = home();
  const input = byKey(before, "command-input:home");
  const section = byClass(before, "command");
  assert.equal(input.attributes.maxlength, "201", "a command is 200 letters at most");
  input.focus();
  input.value = "turn on the kit";
  fire(input, "input", { target: input });
  // A device changes and Home is drawn again; then an answer shows under the field.
  state.lights = state.lights.map((item) => (item.id === 22 ? { ...item, on: true } : item));
  notify();
  const after = home();
  assert.equal(byKey(after, "command-input:home"), input, "the same field");
  assert.equal(byKey(after, "command-mic:home"), byKey(before, "command-mic:home"), "and microphone");
  assert.equal(byClass(after, "command"), section, "in the same place");
  assert.equal(input.value, "turn on the kit");
  await say("frobnicate the kitchen");
  assert.equal(byKey(home(), "command-input:home"), input);
  assert.ok(shown().startsWith("I didn’t understand"));
  input.blur();
});

test("a redraw of the screen leaves in the page what stays the same element (dom.js replaceKeeping)", async () => {
  const { replaceKeeping } = await import("../../app/js/dom.js");
  // A parent that records what was taken out of it.
  const removed = [];
  const parent = {
    childNodes: [],
    get firstChild() {
      return this.childNodes[0] || null;
    },
    removeChild(node) {
      removed.push(node.name);
      this.childNodes = this.childNodes.filter((child) => child !== node);
      node.parentNode = null;
    },
    insertBefore(node, next) {
      if (node.parentNode === this) this.removeChild(node);
      const index = next ? this.childNodes.indexOf(next) : this.childNodes.length;
      this.childNodes.splice(index, 0, node);
      node.parentNode = this;
    },
  };
  const node = (name) => {
    const made = Object.assign(new FakeNode(), { name, parentNode: null });
    Object.defineProperty(made, "nextSibling", { get: () => (made.parentNode ? made.parentNode.childNodes[made.parentNode.childNodes.indexOf(made) + 1] || null : null) });
    return made;
  };
  const [header, field, rooms] = [node("header"), node("field"), node("rooms")];
  replaceKeeping(parent, [header, field, rooms]);
  removed.length = 0;
  const [header2, banner, rooms2] = [node("header2"), node("banner"), node("rooms2")];
  replaceKeeping(parent, [header2, banner, field, rooms2]);
  assert.deepEqual(parent.childNodes.map((child) => child.name), ["header2", "banner", "field", "rooms2"]);
  assert.deepEqual(removed, ["header", "rooms"], "the field never left");
});

test("closing the dialog or leaving Home while listening aborts: nothing heard is done", async () => {
  await connect();
  heard.length = 0;
  const { openCommandDialog, commandRouteChanged } = await import("../../app/js/views/command.js");
  openCommandDialog();
  const dialog = body.children.find((child) => child.tagName === "DIALOG");
  assert.ok(dialog?.open, "the dialog is open");
  const typed = byKey(dialog, "command-input:dialog");
  typed.value = "living";
  fire(typed, "input", { target: typed });
  fire(byKey(dialog, "command-mic:dialog"), "click");
  assert.equal(heard.length, 1);
  // "Kitchen off…", and the dialog is closed mid-sentence.
  heard[0].hear("kitchen off");
  assert.equal(typed.value, "kitchen off", "what it hears is in the field");
  dialog.close();
  await advance(1500);
  assert.equal(heard[0].aborted, true, "aborted, not stopped");
  assert.equal(sent("PATCH", /./).length + sent("POST", /./).length, 0, "nothing heard was done");
  assert.equal(shown(), null, "and nothing is shown");
  assert.equal(typed.value, "living", "the field as it was before it listened");
  assert.equal(byKey(home(), "command-input:home").value, "living");
  typed.value = "";
  fire(typed, "input", { target: typed });

  // Home's microphone, and the user goes to another screen.
  await click("command-mic:home");
  assert.equal(heard.length, 2);
  heard[1].hear("kitchen off");
  commandRouteChanged({ name: "home" });
  assert.equal(heard[1].aborted, undefined, "still on Home: still listening");
  commandRouteChanged({ name: "climate", tab: "climate" });
  await advance(1500);
  assert.equal(heard[1].aborted, true);
  assert.equal(sent("PATCH", /./).length + sent("POST", /./).length, 0);
  // The Stop button still sends what it heard.
  await click("command-mic:home");
  heard[2].hear("kitchen lights off");
  await click("command-mic:home");
  await advance(1500);
  assert.deepEqual(sent("PATCH", /./).map((call) => call.path), ["/v1/lights/20", "/v1/lights/21"]);
});

test("while the dialog is open, it says what it understood from a live region of its own", async () => {
  await connect();
  const { openCommandDialog } = await import("../../app/js/views/command.js");
  openCommandDialog();
  const dialog = body.children.find((child) => child.tagName === "DIALOG");
  const live = byClass(dialog, "visually-hidden") && [dialog].flatMap(function all(node) { return [node, ...(node.children || []).flatMap(all)]; }).find((node) => node.attributes?.role === "status");
  assert.ok(live, "the dialog has its own status region");
  const input = byKey(dialog, "command-input:dialog");
  input.value = "kitchen lights off";
  fire(input, "input", { target: input });
  fire(byClass(dialog, "command-form"), "submit");
  await settle();
  assert.equal(live.textContent, "⁨Kitchen⁩: lights off", "said inside the dialog");
  await advance(1500);
  assert.equal(live.textContent, "Done");
  dialog.close();
  // Closed: the page's own live region again.
  const page = body.children.find((child) => child.tagName === "P" && child.attributes.role === "status");
  await say("living room AC off");
  assert.equal(page.textContent, "⁨Living Room AC⁩: off");
  assert.equal(live.textContent, "Done", "not in the closed dialog");
  await advance(1500);
});

test("the likeliest words that say not to, or name a time, decide: a less likely guess never does it", async () => {
  await connect();
  heard.length = 0;
  await click("command-mic:home");
  heard[0].say("don't turn off the kitchen lights", "turn off the kitchen lights");
  await click("command-mic:home");
  heard[1].say("turn off the kitchen lights tomorrow", "turn off the kitchen lights");
  await click("command-mic:home");
  heard[2].say("turn off the kitchen lights at 7", "turn off the kitchen lights");
  await settle();
  assert.match(shown(), /^I didn’t understand/);
  await setLanguage("he");
  try {
    await click("command-mic:home");
    heard[3].say("אל תכבו את האורות במטבח", "תכבו את האורות במטבח");
    await click("command-mic:home");
    heard[4].say("חם לי בסלון", "חם בסלון");
    await settle();
    assert.match(shown(), /^לא הבנתי/);
  } finally {
    await setLanguage("en");
  }
  await advance(1500);
  assert.equal(sent("PATCH", /./).length + sent("POST", /./).length, 0);
});

test("a change that heat and cool setpoints cannot take says why, and sends nothing", async () => {
  await connect();
  const office = { id: 31, name: "Office AC", room: room(12), mode: "heat", modes: ["off", "heat", "cool", "auto"], setpoints: "dual", heat_setpoint: 20, cool_setpoint: 24, setpoint_deadband: 1, target_temperature_min: 5, target_temperature_max: 35, fan_speed: null, fan_speeds: [] };
  state.thermostats = [...state.thermostats, office];
  controller.thermostats = [...controller.thermostats, { ...office }];
  notify();
  await say("office AC to 35");
  await advance(1500);
  assert.equal(sent("PATCH", /./).length, 0);
  assert.match(shown(), /^⁨Office AC⁩: ⁦35°⁩.*can’t be set to ⁦35°⁩: its heat and cool setpoints stay ⁦1°⁩ apart, from ⁦5°⁩ to ⁦35°⁩\.$/);
  const { thermostatPlan } = await import("../../app/js/commands.js");
  assert.ok(thermostatPlan({ ...office, mode: "auto" }, { temperature: 22 }).refused, "auto, with no setpoint said");
  assert.deepEqual(thermostatPlan(office, { temperature: 22 }), { patch: { heat_setpoint: 22 } });
});

test("not understood: says so with examples by the user's own names, sends nothing, keeps the words", async () => {
  await connect();
  await say("frobnicate the kitchen");
  assert.equal(shown(), "I didn’t understand “⁨frobnicate⁩”.Try:Kitchen lights offLiving Room AC to 23Run Good night");
  assert.equal(sent("PATCH", /./).length + sent("POST", /./).length, 0);
  assert.equal(byKey(home(), "command-input:home").value, "frobnicate the kitchen", "the words stay, to correct");
  await click("command-example:home:1");
  assert.equal(byKey(home(), "command-input:home").value, "Living Room AC to 23", "an example goes into the field, not sent");
  assert.equal(sent("PATCH", /./).length, 0);
  await click("command-dismiss:home");
  assert.equal(shown(), null);
});

test("a door or gate opens only with its own second tap, and only for door access", async () => {
  await connect({ role: "doors" });
  await say("open the main gate");
  assert.equal(sent("POST", /pulse$/).length, 0, "the words alone never open it");
  assert.ok(shown().startsWith("⁨Main Gate⁩: open"), shown());
  assert.equal(byKey(home(), "relay:50:open").textContent, "Tap again to open");
  // Saying it again is not the second tap.
  await say("open the main gate");
  assert.equal(sent("POST", /pulse$/).length, 0);
  await click("relay:50:open");
  await advance(100);
  assert.deepEqual(sent("POST", /pulse$/).map((call) => call.path), ["/v1/relays/50/pulse"]);

  await connect({ role: "member" });
  await say("open the main gate");
  assert.equal(shown(), "Opening doors and gates needs door access.");
  assert.equal(sent("POST", /pulse$/).length, 0);
});

test("turn off everything asks for its confirm, then is Home's Turn off all", async () => {
  await connect();
  await say("turn off everything");
  assert.equal(shown(), "Turn off everything3 lights on, 1 AC onTurn offCancel");
  assert.equal(sent("POST", /^\/v1\/off$/).length, 0);
  await click("command-confirm:home");
  await advance(2000);
  assert.deepEqual(sent("POST", /^\/v1\/off$/).map((call) => call.body), [
    { type: "lights", device_ids: [20, 21, 23] },
    { type: "climate", device_ids: [30] },
  ]);
  assert.equal(shown(), "Turn off everythingDone");

  await connect();
  await say("turn off everything");
  await advance(10100);
  assert.equal(shown(), null, "the confirm waits 10 seconds");
  assert.equal(sent("POST", /^\/v1\/off$/).length, 0);
});

test("a scene runs; one that opens doors waits for the tap on its Run button", async () => {
  await connect({ role: "doors" });
  await say("run good night");
  await advance(100);
  assert.deepEqual(sent("POST", /\/run$/).map((call) => call.path), ["/v1/scenes/aa000001/run"]);
  assert.equal(shown(), "Run ⁨Good night⁩Done");
  // Said twice while it runs: it runs once.
  controller.rtt = 1000;
  await say("run good night");
  await say("good night");
  assert.equal(shown(), "Run ⁨Good night⁩Working…", "the run on its way");
  await advance(1500);
  controller.rtt = 0;
  assert.equal(sent("POST", /aa000001\/run$/).length, 2, "once more, not twice");
  assert.equal(shown(), "Run ⁨Good night⁩Done");
  // Run from Home's button, then said while it runs: its result.
  controller.rtt = 1000;
  const { runScene } = await import("../../app/js/scenes.js");
  runScene(SCENES[0]);
  await settle();
  await say("good night");
  assert.equal(shown(), "Run ⁨Good night⁩Working…");
  await advance(1500);
  controller.rtt = 0;
  assert.equal(shown(), "Run ⁨Good night⁩Done");
  assert.equal(sent("POST", /aa000001\/run$/).length, 3);

  await say("run leave home");
  assert.equal(sent("POST", /aa000002\/run$/).length, 0, "not run by the words");
  assert.equal(byKey(home(), "command-scene:home").textContent, "Tap again to run");
  await say("run leave home");
  assert.equal(sent("POST", /aa000002\/run$/).length, 0, "nor by saying it again");
  await click("command-scene:home");
  await advance(100);
  assert.deepEqual(sent("POST", /aa000002\/run$/).map((call) => call.path), ["/v1/scenes/aa000002/run"]);
});

test("a thermostat's request: its setpoint with heat and cool setpoints, the other kept apart", async () => {
  const { thermostatChange } = await import("../../app/js/commands.js");
  const dual = { id: 31, setpoints: "dual", mode: "auto", modes: ["off", "heat", "cool", "auto"], heat_setpoint: 20, cool_setpoint: 24, setpoint_deadband: 2, target_temperature_min: 10, target_temperature_max: 32 };
  assert.deepEqual(thermostatChange(dual, { mode: "auto", setpoint: "heat", temperature: 21 }), { mode: "auto", heat_setpoint: 21 });
  assert.deepEqual(thermostatChange(dual, { setpoint: "heat", temperature: 23 }), { heat_setpoint: 23, cool_setpoint: 25 });
  assert.deepEqual(thermostatChange({ ...dual, mode: "cool" }, { temperature: 23 }), { cool_setpoint: 23 });
  assert.deepEqual(thermostatChange({ ...dual, mode: "off" }, { mode: "heat", temperature: 21 }), { mode: "heat", heat_setpoint: 21 });
  assert.equal(thermostatChange({ ...dual, mode: "off" }, { mode: "off" }), null, "already off");
  assert.deepEqual(thermostatChange({ id: 30, mode: "cool" }, { temperature: 22.5 }), { target_temperature: 22.5 });
});

test("the controller refusing shows why", async () => {
  await connect();
  controller.patch = () => ({ status: 403, body: { status: 403, code: "FORBIDDEN", detail: "Not allowed" } });
  await say("living room AC off");
  await advance(1500);
  assert.match(shown(), /^⁨Living Room AC⁩: offDidn’t work: /);
  assert.equal(state.thermostats[0].mode, "cool", "put back as it was");
});

test("in Hebrew, right to left", async () => {
  await setLanguage("he");
  try {
    await connect();
    assert.equal(byKey(home(), "command-input:home").attributes.placeholder, "אמרו או הקלידו פקודה");
    await say("כבו את האורות במטבח");
    assert.equal(shown(), "⁨מטבח⁩: כיבוי האורותמבצע…");
    await advance(1500);
    assert.equal(shown(), "⁨מטבח⁩: כיבוי האורותבוצע");
    await say("משהו אחר");
    assert.equal(shown(), "לא הבנתי „⁨משהו אחר⁩”.נסו:כבו את האורות במטבחמזגן בסלון 23הפעילו Good night");
  } finally {
    await setLanguage("en");
  }
});

test("the microphone where the browser has speech recognition: it listens, then does what it heard", async () => {
  await connect();
  heard.length = 0;
  await click("command-mic:home");
  assert.equal(heard.length, 1);
  assert.equal(heard[0].lang, "en-US");
  assert.equal(heard[0].interimResults, true);
  assert.equal(heard[0].started, true);
  assert.ok(shown().includes("Listening…"));
  assert.ok(shown().includes("DirectorLink sends it nowhere"), "says where the sound goes");
  assert.ok(shown().includes("Chrome’s sends the sound to Google, Edge’s to Microsoft, Safari’s to Apple"), shown());
  assert.equal(byKey(home(), "command-mic:home").attributes["aria-pressed"], "true");
  // The likeliest is not understood; the next guess is.
  heard[0].say("kitten lights of", "kitchen lights off");
  await advance(1500);
  assert.deepEqual(sent("PATCH", /./).map((call) => call.path), ["/v1/lights/20", "/v1/lights/21"]);
  // The likeliest asks which one: a less likely guess never settles it.
  await click("command-mic:home");
  heard[1].say("spots on", "kitchen spots on");
  await settle();
  assert.match(shown(), /^Which one\?/);
  assert.equal(sent("PATCH", /./).length, 2, "nothing more was sent");
  heard.splice(1, 1);

  await setLanguage("he");
  try {
    await click("command-mic:home");
    assert.equal(heard[1].lang, "he-IL");
    heard[1].onerror({ error: "not-allowed" });
    heard[1].onend();
    await settle();
    assert.equal(shown(), "המיקרופון חסום לאפליקציה הזו. אפשרו אותו בהגדרות הדפדפן, או הקלידו.");
  } finally {
    await setLanguage("en");
  }
});
