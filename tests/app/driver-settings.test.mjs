// DirectorLink's settings in the app (1.4.0, ADR-043; app/js/driver-settings.js with
// views/driver-settings.js): Settings → Controller → DirectorLink settings, for admins only; the
// Jewish calendar, schedules and the log level changed as in Composer, turning the calendar off and
// pausing schedules confirmed first; the settings made in Composer only, read-only; the statuses,
// Refresh project and the schedules and scenes as Composer prints them; read again so that a change
// in Composer shows; and nothing at all with a DirectorLink before 1.4.0. Against a fake controller
// under fake time, with just enough of a browser.
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
  append(...children) {
    this.children.push(...children);
  }
  remove() {}
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  set textContent(value) {
    this.children = [Object.assign(new FakeNode(), { textContent: String(value) })];
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "#/settings" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: new FakeElement("body"),
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
// What the app asked to confirm, and the answer it gets.
let confirmAnswer = true;
const confirmed = [];
window.confirm = (text) => {
  confirmed.push(text);
  return confirmAnswer;
};
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-01T08:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// ---- the fake controller -----------------------------------------------------------------------
// A DirectorLink 1.4.0 that cannot seal here (so requests carry the key, as with a driver before
// 1.0.0). It keeps its settings as the driver does: the ones set in Composer only are refused.
const HOST = "controller.invalid";
const KEY = "ak_test_settings_key";
const SETTINGS = [
  ["door_control", "Door Control", [["disabled", "Disabled"], ["enabled", "Enabled"]], false],
  ["relay_hold", "Relay Hold", [["not_allowed", "Not allowed"], ["allowed", "Allowed"]], false],
  ["alarm_status", "Alarm Status", [["off", "Off"], ["on", "On"]], false],
  ["remote_access", "Remote Access", [["off", "Off"], ["on", "On"]], false],
  ["schedules", "Schedules", [["on", "On"], ["paused", "Paused"]], true],
  ["jewish_calendar", "Jewish Calendar", [["off", "Off"], ["on", "On"]], true],
  ["log_level", "Log Level", [["debug", "Debug"], ["info", "Info"], ["warn", "Warning"], ["error", "Error"]], true],
];
const STATUS = {
  status: "Ready",
  version: "1.4.0",
  api_status: "Online - port 41999",
  pairing_status: "Used at 08:00 - run New Pairing Code to pair another device",
  api_keys: "3",
  remote_status: "Off",
  schedule_status: "2 on · next tomorrow 06:45 Morning",
  last_automation: null,
  calendar_status: "Israel (from the location) · candles 20 min before sunset",
  inventory: "2 rooms, 14 devices, 3 lights, 1 thermostats, 0 fans, 2 blinds, 3 cameras, 1 relays, 1 doorbells",
};
const PRINTOUT = [
  "DirectorLink schedules: 1 (controller time 2026-10-01 11:00)",
  "Jewish calendar: Israel (from the location)",
  "  [on] Sun-Thu 06:45 -> Morning · only if not raining · next tomorrow 06:45 · id 0a1b2c3d",
  "DirectorLink scenes: 1",
  "  Morning (id 4e5f6a7b, on Home):",
  "    1. Kitchen Island (20) -> 60%",
  "    2. all blinds in Living Room (11) -> 100% open",
  "Scenes and schedules are made in the DirectorLink app, not in Composer programming.",
];

const controller = { calls: [], values: {}, settings: "1.4.0", answer: null };

function documentNow() {
  return {
    settings: SETTINGS.map(([key, property, choices, changeable]) => {
      const value = controller.values[key];
      return {
        key,
        property,
        value,
        composer_value: choices.find(([api]) => api === value)[1],
        choices: choices.map(([api]) => api),
        changeable,
        set_in: changeable ? "app_and_composer" : "composer",
      };
    }),
    status: { ...STATUS },
    actions: [
      { key: "new_pairing_code", action: "New Pairing Code", in_app: false },
      { key: "revoke_api_keys", action: "Revoke All API Keys", in_app: false },
      { key: "print_automation", action: "Print Schedules and Scenes", in_app: true },
      { key: "refresh_project", action: "Refresh Project", in_app: true },
      { key: "reset_remote_identity", action: "Reset Remote Identity", in_app: false },
    ],
  };
}

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const body = init.body ? JSON.parse(init.body) : null;
  controller.calls.push({ method, path, body });
  return handle(method, path, body);
};

function handle(method, path, body) {
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  const custom = controller.answer?.(method, path, body);
  if (custom) return answer(custom.status, custom.body);
  const older = controller.settings !== "1.4.0" && (path.startsWith("/v1/settings") || path === "/v1/project/refresh");
  if (older) return answer(controller.settings, { status: controller.settings, code: controller.settings === 404 ? "NOT_FOUND" : "METHOD_NOT_ALLOWED" });
  if (method === "GET" && path === "/v1/settings") return answer(200, documentNow());
  if (method === "PATCH" && path === "/v1/settings") {
    for (const key of Object.keys(body)) {
      const setting = SETTINGS.find(([name]) => name === key);
      if (setting && !setting[3]) return answer(403, { status: 403, code: "SET_IN_COMPOSER", detail: `${setting[1]} is set in Composer only` });
    }
    Object.assign(controller.values, body);
    return answer(200, documentNow());
  }
  if (method === "GET" && path === "/v1/settings/printout") return answer(200, { printed_at: "2026-10-01T08:00:00Z", lines: PRINTOUT });
  if (method === "POST" && path === "/v1/project/refresh") {
    return answer(200, { refreshed_at: "2026-10-01T08:00:00Z", inventory: { rooms: 3, devices: 15 }, changes: { added: 1, removed: 0, moved: 0, renamed: 0, rooms_added: 1, rooms_removed: 0, rooms_renamed: 0 } });
  }
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "admin" });
  if (method === "GET" && path === "/v1/schedules") return answer(200, { items: [], paused: controller.values.schedules === "paused" });
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
}

const { state, ui, notify } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const settings = await import("../../app/js/driver-settings.js");
const { driverSettingsPanel } = await import("../../app/js/views/driver-settings.js");

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
const text = (node) => (node ? node.textContent : "");
// Drawn as app.js draws it: the panel reads what it needs as it is drawn.
async function panel() {
  driverSettingsPanel();
  await settle();
  return driverSettingsPanel();
}
const panelText = async () => text(await panel());

async function fire(key, type, event = {}) {
  const element = byKey(await panel(), key);
  assert.ok(element, `no ${key} in the panel: ${(await panelText()).slice(0, 300)}`);
  assert.equal(element.attributes.disabled, undefined, `${key} is disabled`);
  await Promise.all((element.listeners[type] || []).map((listener) => listener({ preventDefault() {}, stopPropagation() {}, ...event })));
  await settle();
}
const click = (key) => fire(key, "click");
const message = async () => text(byKey(await panel(), "driver-settings-message"));
const requests = (method, path) => controller.calls.filter((call) => call.method === method && call.path === path);

// Connected to the fake controller with `role`, on Settings.
async function connect(role = "admin", values = {}) {
  session.forgetKey();
  await advance(20000, 500);
  Object.assign(controller, {
    calls: [],
    settings: "1.4.0",
    answer: null,
    values: { door_control: "enabled", relay_hold: "not_allowed", alarm_status: "on", remote_access: "off", schedules: "on", jewish_calendar: "on", log_level: "info", ...values },
  });
  confirmed.length = 0;
  confirmAnswer = true;
  Object.assign(state, {
    host: HOST, apiKey: KEY, role, status: "connected", loaded: true, notice: null, errors: {}, pending: {},
    rooms: [], lights: [], thermostats: [], blinds: [], fans: [], cameras: [], relays: [], doorbells: [], devices: [], scenes: [],
    system: { bridge: { version: "1.4.0" }, features: { jewish_calendar: values.jewish_calendar !== "off", alarm_status: true } },
    schedulesPaused: values.schedules === "paused",
  });
  settings.resetDriverSettings();
  notify();
  await advance(100);
}

// ---- who sees it ---------------------------------------------------------------------------------

test("only admins see DirectorLink settings, once connected", async () => {
  await setLanguage("en");
  for (const role of ["viewer", "member", "doors"]) {
    await connect(role);
    assert.equal(await panel(), null, role);
    assert.equal(requests("GET", "/v1/settings").length, 0, `${role}: nothing is asked for`);
  }
  await connect("admin");
  state.loaded = false;
  assert.equal(await panel(), null, "not before the controller answered");
  state.loaded = true;
  const shown = await panelText();
  assert.equal(requests("GET", "/v1/settings").length, 1);
  for (const words of ["DirectorLink settings", "Jewish calendar", "Shabbat and holiday times", "Schedules", "no DirectorLink schedule runs", "Log level", "Refresh project", "Set in Composer", "Status"]) {
    assert.ok(shown.includes(words), `the panel says: ${words}\n${shown}`);
  }
});

test("a DirectorLink before 1.4.0 (404 or 405) shows no section; another failure offers Retry", async () => {
  for (const status of [404, 405]) {
    await connect();
    controller.settings = status;
    settings.resetDriverSettings();
    assert.equal(await panel(), null, `${status}: hidden`);
    await advance(61000, 1000);
    assert.equal(await panel(), null, `${status}: still hidden`);
  }
  await connect();
  controller.answer = (method, path) => (path === "/v1/settings" ? { status: 503, body: { status: 503, code: "UNAVAILABLE", detail: "busy" } } : null);
  settings.resetDriverSettings();
  assert.ok(byKey(await panel(), "driver-settings-error"), "says it could not read them");
  controller.answer = null;
  await click("driver-settings-retry");
  assert.ok(byKey(await panel(), "driver-setting-jewish_calendar"), "and shows them once read");
});

// ---- the settings an admin changes --------------------------------------------------------------

test("turning the Jewish calendar off asks first, saying what stops; on asks nothing", async () => {
  await connect();
  const toggle = byKey(await panel(), "driver-setting-jewish_calendar");
  assert.equal(toggle.attributes["aria-checked"], "true");
  confirmAnswer = false;
  await click("driver-setting-jewish_calendar");
  assert.equal(confirmed.length, 1);
  assert.ok(confirmed[0].includes("Shabbat and holiday schedules stop"), confirmed[0]);
  assert.equal(requests("PATCH", "/v1/settings").length, 0, "declined: nothing is sent");

  confirmAnswer = true;
  await click("driver-setting-jewish_calendar");
  assert.deepEqual(requests("PATCH", "/v1/settings").at(-1).body, { jewish_calendar: "off" });
  assert.equal(byKey(await panel(), "driver-setting-jewish_calendar").attributes["aria-checked"], "false");
  assert.equal(state.system.features.jewish_calendar, false, "the calendar's screens go with it");
  assert.equal(await message(), "Saved. Composer shows it too.");
  assert.ok(requests("GET", "/v1/schedules").length > 0, "what schedules say is read again");

  await click("driver-setting-jewish_calendar");
  assert.equal(confirmed.length, 2, "turning it on asks nothing");
  assert.deepEqual(requests("PATCH", "/v1/settings").at(-1).body, { jewish_calendar: "on" });
  assert.equal(state.system.features.jewish_calendar, true);
  await advance(7000, 500);
  assert.equal(await message(), "", "the message goes after a while");
});

// A keyboard or screen-reader user keeps their place: while a change is on its way the controls
// say they are busy but are not disabled (a disabled control loses the focus), and a press
// meanwhile sends nothing.
test("a switch keeps the focus while its change is on its way, and a second press is ignored", async () => {
  await connect();
  let release;
  const held = new Promise((resolve) => (release = resolve));
  const fetchBefore = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    if ((init.method || "GET") === "PATCH") await held;
    return fetchBefore(url, init);
  };
  const press = (element) => Promise.all(element.listeners.click.map((listener) => listener({ preventDefault() {}, stopPropagation() {} })));
  try {
    const pressing = press(byKey(await panel(), "driver-setting-jewish_calendar"));
    await settle();
    const busy = driverSettingsPanel();
    for (const key of ["driver-setting-jewish_calendar", "driver-setting-schedules", "driver-setting-log_level", "driver-refresh"]) {
      assert.equal(byKey(busy, key).attributes.disabled, undefined, `${key}: not disabled`);
      assert.equal(byKey(busy, key).attributes["aria-disabled"], "true", `${key}: says it is busy`);
    }
    await press(byKey(busy, "driver-setting-schedules"));
    release();
    await pressing;
    await settle();
  } finally {
    globalThis.fetch = fetchBefore;
  }
  assert.deepEqual(requests("PATCH", "/v1/settings").map((call) => call.body), [{ jewish_calendar: "off" }], "the press while busy sent nothing");
  assert.equal(byKey(await panel(), "driver-setting-jewish_calendar").attributes["aria-disabled"], undefined);
});

test("pausing schedules asks first; resuming asks nothing", async () => {
  await connect();
  confirmAnswer = false;
  await click("driver-setting-schedules");
  assert.ok(confirmed[0].includes("Pause every schedule?"), confirmed[0]);
  assert.ok(confirmed[0].includes("(except a time due in the last 5 minutes)"), "what was due in the last 5 minutes runs on resume");
  assert.equal(requests("PATCH", "/v1/settings").length, 0);
  confirmAnswer = true;
  await click("driver-setting-schedules");
  assert.deepEqual(requests("PATCH", "/v1/settings").at(-1).body, { schedules: "paused" });
  assert.equal(state.schedulesPaused, true, "Schedules says so at once");
  assert.equal(byKey(await panel(), "driver-setting-schedules").attributes["aria-checked"], "false");
  await click("driver-setting-schedules");
  assert.equal(confirmed.length, 2);
  assert.deepEqual(requests("PATCH", "/v1/settings").at(-1).body, { schedules: "on" });
  assert.equal(state.schedulesPaused, false);
});

test("the log level is picked from Composer's four, without a question", async () => {
  await connect();
  const picker = byKey(await panel(), "driver-setting-log_level");
  assert.equal(picker.tagName, "SELECT");
  assert.deepEqual(picker.children.map((option) => option.attributes.value), ["debug", "info", "warn", "error"]);
  assert.equal(picker.children.find((option) => "selected" in option.attributes).attributes.value, "info");
  await fire("driver-setting-log_level", "change", { target: { value: "debug" } });
  assert.equal(confirmed.length, 0);
  assert.deepEqual(requests("PATCH", "/v1/settings").at(-1).body, { log_level: "debug" });
  const now = byKey(await panel(), "driver-setting-log_level");
  assert.equal(now.children.find((option) => "selected" in option.attributes).attributes.value, "debug");
});

test("a refused change says why, and the settings are read again", async () => {
  await connect();
  controller.answer = (method, path) => (method === "PATCH" && path === "/v1/settings" ? { status: 403, body: { status: 403, code: "SET_IN_COMPOSER", detail: "set in Composer" } } : null);
  const before = requests("GET", "/v1/settings").length;
  await fire("driver-setting-log_level", "change", { target: { value: "error" } });
  assert.equal(await message(), "That setting is set in Composer only.");
  assert.ok(requests("GET", "/v1/settings").length > before, "read again");
  // Changed in Composer meanwhile: shown as the controller has it.
  controller.answer = null;
  controller.values.log_level = "warn";
  settings.resetDriverSettings();
  const picker = byKey(await panel(), "driver-setting-log_level");
  assert.equal(picker.children.find((option) => "selected" in option.attributes).attributes.value, "warn");
});

// ---- read only -----------------------------------------------------------------------------------

test("the settings made in Composer only are shown with their value, and nothing changes them", async () => {
  await connect();
  const composer = byKey(await panel(), "driver-composer");
  assert.ok(composer);
  for (const [key, words] of [
    ["door_control", "Door controlEnabledSet in Composer (Door Control)"],
    ["relay_hold", "Holding relays closedNot allowedSet in Composer (Relay Hold)"],
    ["alarm_status", "Alarm statusOnSet in Composer (Alarm Status)"],
    ["remote_access", "Remote accessOffSet in Composer (Remote Access)"],
  ]) {
    assert.equal(text(byKey(composer, `driver-composer:${key}`)), words);
  }
  walk(composer, (node) => {
    assert.ok(!["BUTTON", "INPUT", "SELECT"].includes(node.tagName), "nothing to press or set");
    assert.deepEqual(Object.keys(node.listeners || {}), [], "nothing listens");
  });
  assert.ok(text(composer).includes("New Pairing Code, Revoke All API Keys and Reset Remote Identity are run in Composer only."));
  for (const key of ["door_control", "relay_hold", "alarm_status", "remote_access"]) {
    assert.equal(byKey(await panel(), `driver-setting-${key}`), null, `no switch for ${key}`);
  }
});

test("the statuses as Composer shows them, in English", async () => {
  await connect();
  const status = byKey(await panel(), "driver-status");
  assert.equal(text(byKey(status, "driver-status:inventory")), `Inventory${STATUS.inventory}`);
  assert.equal(text(byKey(status, "driver-status:schedule_status")), `Schedules${STATUS.schedule_status}`);
  assert.equal(text(byKey(status, "driver-status:api_status")), "APIOnline - port 41999");
  assert.equal(byKey(status, "driver-status:last_automation"), null, "nothing ran yet: no row");
  assert.equal(byKey(status, "driver-status:inventory").children[1].attributes.lang, "en");
});

test("Hebrew: the section speaks Hebrew, the statuses stay as Composer shows them", async () => {
  await connect();
  await setLanguage("he");
  const shown = await panelText();
  for (const words of ["הגדרות DirectorLink", "לוח עברי", "תזמונים", "רמת יומן", "נקבע ב-Composer (Door Control)", STATUS.inventory]) {
    assert.ok(shown.includes(words), `the panel says: ${words}`);
  }
  confirmAnswer = false;
  await click("driver-setting-schedules");
  assert.ok(confirmed[0].startsWith("להשהות את כל התזמונים?"));
  await setLanguage("en");
});

// ---- Composer's actions ---------------------------------------------------------------------------

test("Refresh project reads the project again and says what it found", async () => {
  await connect();
  await click("driver-refresh");
  assert.equal(requests("POST", "/v1/project/refresh").length, 1);
  assert.equal(await message(), "Project read again: 3 rooms, 15 devices.");
  assert.ok(requests("GET", "/v1/rooms").length > 0, "rooms and devices are read again");
  controller.answer = (method, path) =>
    path === "/v1/project/refresh" ? { status: 503, body: { status: 503, code: "PROJECT_REFRESH_FAILED", detail: "busy" } } : null;
  await click("driver-refresh");
  assert.ok((await message()).startsWith("The controller could not list the project"));
});

test("the schedules and scenes as Composer prints them, as a readable page", async () => {
  await connect();
  await click("driver-printout-open");
  assert.equal(requests("GET", "/v1/settings/printout").length, 1);
  const printout = byKey(await panel(), "driver-printout-text");
  assert.equal(printout.attributes.lang, "en");
  assert.equal(printout.attributes.dir, "ltr");
  const shown = text(printout);
  for (const words of ["DirectorLink schedules: 1", "[on] Sun-Thu 06:45 -> Morning", "only if not raining · next tomorrow 06:45", "Morning (id 4e5f6a7b, on Home):", "1. Kitchen Island (20) -> 60%"]) {
    assert.ok(shown.includes(words), `the printout says: ${words}\n${shown}`);
  }
  await click("driver-printout-close");
  assert.equal(byKey(await panel(), "driver-printout"), null);
  assert.ok(byKey(await panel(), "driver-printout-open"));
});

test("the printout's lines go in groups by their indent", () => {
  assert.deepEqual(settings.printoutGroups(PRINTOUT), [
    { title: PRINTOUT[0], items: [] },
    { title: PRINTOUT[1], items: [{ text: PRINTOUT[2].trim(), steps: [] }] },
    { title: PRINTOUT[3], items: [{ text: "Morning (id 4e5f6a7b, on Home):", steps: ["1. Kitchen Island (20) -> 60%", "2. all blinds in Living Room (11) -> 100% open"] }] },
    { title: PRINTOUT[7], items: [] },
  ]);
  assert.deepEqual(settings.printoutGroups(["  orphan", "", "    step"]), [{ title: "orphan", items: [{ text: "step", steps: [] }] }]);
});

// ---- Composer and the app -------------------------------------------------------------------------

test("a change made in Composer shows: read again when Settings opens and every minute", async () => {
  await connect();
  assert.equal(byKey(await panel(), "driver-setting-schedules").attributes["aria-checked"], "true");
  controller.values.schedules = "paused";
  controller.values.door_control = "disabled";
  await advance(30000, 1000);
  await panel();
  assert.equal(requests("GET", "/v1/settings").length, 1, "not yet");
  await advance(31000, 1000);
  const now = await panel();
  assert.equal(requests("GET", "/v1/settings").length, 2, "read again after a minute");
  assert.equal(byKey(now, "driver-setting-schedules").attributes["aria-checked"], "false");
  assert.ok(text(byKey(now, "driver-composer:door_control")).includes("Disabled"));
  settings.resetDriverSettings();
  await panel();
  assert.equal(requests("GET", "/v1/settings").length, 3, "and when Settings is opened");
});

test("a forgotten key forgets this home's settings", async () => {
  await connect();
  assert.ok(await panel());
  session.forgetKey();
  assert.equal(ui.driverSettings.document, null);
});
