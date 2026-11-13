// The alarm in the app (app/js/alarm.js, app/js/views/alarm.js, ADR-038): its status on Home and in
// Settings → Controller for members and admins once an installer turned on Alarm Status (GET
// /v1/system features.alarm_status), in natural English and Hebrew; otherwise nothing is asked and
// nothing is shown. Since 1.15.0 (ADR-091; app/js/alarm-control.js, app/js/views/alarm-control.js)
// Arm and Disarm for the partitions the controller says this person may arm and disarm: a mode, the
// code typed in a dialog each time and sent in that one request's body only, then the partition read
// again until it shows what the alarm did, and refusals in the app's words, in every language.
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

// Just enough of a browser for these modules: the elements the views build (and the dialog the code
// is typed in, which goes into the page's body), storage and timers.
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.listeners = {};
    this.className = "";
    this.style = { setProperty() {} };
    this.parentNode = null;
    this.value = "";
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener(type, listener) {
    (this.listeners[type] ||= []).push(listener);
  }
  dispatch(type, init = {}) {
    const event = { type, target: this, currentTarget: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {}, ...init };
    for (const listener of this.listeners[type] || []) listener(event);
    return event;
  }
  append(...children) {
    for (const child of children) {
      if (child instanceof FakeElement) child.parentNode = this;
      this.children.push(child);
    }
  }
  remove() {
    if (this.parentNode) this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
    this.parentNode = null;
  }
  focus() {
    document.activeElement = this;
  }
  showModal() {
    this.open = true;
  }
  close() {
    if (!this.open) return;
    this.open = false;
    this.dispatch("close");
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  set textContent(text) {
    this.children = [document.createTextNode(text)];
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", hash: "" };
globalThis.document = {
  hidden: false,
  activeElement: null,
  documentElement: {},
  addEventListener() {},
  querySelector: () => null,
  querySelectorAll: () => [],
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
document.body = new FakeElement("body");
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};
// Whatever the app writes to the console (never an alarm code).
const logged = [];
for (const level of ["log", "info", "warn", "error", "debug"]) {
  console[level] = (...args) => logged.push(args.map((arg) => (arg instanceof Error ? `${arg.message} ${arg.stack}` : typeof arg === "string" ? arg : JSON.stringify(arg))).join(" "));
}

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { forgetKey } = await import("../../app/js/session.js");
const { alarmDetails, alarmSignature, alarmStateText, alarmSummary, armModeLabel, loadAlarm, startAlarm } = await import("../../app/js/alarm.js");
const { FOLLOW_MS, commandTook } = await import("../../app/js/alarm-control.js");
const { alarmFact, alarmSection, tickAlarmDelays } = await import("../../app/js/views/alarm.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");
const { default: es } = await import("../../app/i18n/es.js");
const { default: it } = await import("../../app/i18n/it.js");

// A name as the app isolates it inside a sentence in the other direction.
const iso = (text) => `⁨${text}⁩`;

// The fake home's partitions (driver/tests/c4mock.lua withPartitions) as GET /v1/alarm reports them.
const partition = (fields) => ({
  room: null,
  state: null,
  armed: false,
  armed_mode: null,
  armed_type: null,
  alarm: false,
  alarm_type: null,
  open_zones: 0,
  delay: null,
  trouble: null,
  ...fields,
});
const garage = partition({ id: 81, name: "Garage", room: { id: 10, name: "Kitchen" }, state: "armed", armed: true, armed_mode: "away", armed_type: "Away" });
const house = partition({ id: 80, name: "House", room: { id: 11, name: "Living Room" }, state: "disarmed_not_ready", open_zones: 1 });
const ON = { enabled: true, partitions: [garage, house] };

// The controller: GET /v1/alarm answers `alarm` (an answer, a status for a problem, or "offline"
// for no answer at all). It does not seal (a driver before 1.0.0), so requests carry the key: how
// they travel does not matter here. Returns what the app sent.
function controller(alarm) {
  const sent = [];
  globalThis.fetch = async (url, options = {}) => {
    const address = new URL(url);
    sent.push(`${options.method || "GET"} ${address.pathname}`);
    const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
    if (address.pathname === "/v1/sealed") return reply(404, { code: "NOT_FOUND" });
    if (address.pathname !== "/v1/alarm") return reply(200, { items: [] });
    if (alarm === "offline") throw new TypeError("Failed to fetch");
    if (typeof alarm === "number") return reply(alarm, { code: alarm === 403 ? "SEALED_REQUEST_REQUIRED" : "NOT_FOUND" });
    return reply(200, alarm);
  };
  return sent;
}

// Connected, with this role and Alarm Status as Composer has it.
function home({ role = "admin", alarmStatus = true, features = true } = {}) {
  state.host = "192.0.2.10";
  state.apiKey = "ak_test";
  state.transport = "lan";
  state.status = "connected";
  state.loaded = true;
  state.role = role;
  state.system = features ? { bridge: { version: "1.2.0" }, features: { alarm_status: alarmStatus } } : { bridge: { version: "1.1.1" } };
  state.alarm = null;
}

const asksAlarm = (sent) => sent.some((line) => line.endsWith(" /v1/alarm"));

// What the screen holds.
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
const press = (nodes, key) => {
  const element = byKey(nodes, key);
  assert.ok(element, `${key} is on the screen`);
  element.dispatch("click");
};
// The text without the isolates around names.
const plain = (text) => String(text ?? "").replace(/[⁦-⁩]/g, "");
// Everything the page holds: text, attributes and the values of fields.
function pageText(nodes) {
  const parts = [];
  walk(nodes, (node) => {
    if (node instanceof FakeElement) parts.push(JSON.stringify(node.attributes), JSON.stringify(node.dataset), String(node.value ?? ""));
    else parts.push(String(node.textContent ?? ""));
  });
  return parts.join("\n");
}
const shownDialog = () => document.body.children.find((child) => child.tagName === "DIALOG") || null;
async function settle() {
  for (let index = 0; index < 20; index += 1) await new Promise((resolve) => setImmediate(resolve));
}
async function advance(t, ms, step = 500) {
  for (let done = 0; done < ms; done += step) {
    t.mock.timers.tick(Math.min(step, ms - done));
    await settle();
  }
}

// A partition of a 1.15.0 controller: the modes its driver declares, and whether this person may arm
// and disarm it now.
const MODES = ["Away", "Home", "Night"];
const READY = partition({ id: 80, name: "House", room: { id: 11, name: "Living Room" }, state: "disarmed_ready", modes: MODES, control: { allowed: true, available: true } });
const ARMED = { ...READY, state: "armed", armed: true, armed_mode: "away", armed_type: "Away" };
// A code no other part of these tests has.
const CODE = "908172";

// A 1.15.0 controller: GET /v1/alarm answers `partitions` (after `reportAfter(reads, partitions)`,
// those, once read that many more times: the panel took the command); POST .../arm and .../disarm
// answer 202, or `refuse` ([status, problem, headers]). Every request is kept.
function alarmController(partitions) {
  const fake = { partitions, calls: [], refuse: null, next: null };
  globalThis.fetch = async (url, options = {}) => {
    const address = new URL(url);
    const method = options.method || "GET";
    const body = options.body ? JSON.parse(options.body) : null;
    fake.calls.push({ method, path: address.pathname, search: address.search, body, url: String(url), headers: JSON.stringify(options.headers || {}) });
    const reply = (status, data, headers = {}) => new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json", ...headers } });
    if (address.pathname === "/v1/sealed") return reply(404, { code: "NOT_FOUND" });
    if (method === "GET" && address.pathname === "/v1/alarm") {
      if (fake.next && --fake.next.reads <= 0) {
        fake.partitions = fake.next.partitions;
        fake.next = null;
      }
      return reply(200, { enabled: true, partitions: fake.partitions });
    }
    const command = /^\/v1\/alarm\/(\d+)\/(arm|disarm)$/.exec(address.pathname);
    if (method === "POST" && command) {
      if (fake.refuse) {
        const [status, problem, headers] = fake.refuse;
        return reply(status, { status, ...problem }, headers);
      }
      return reply(202, { partition_id: Number(command[1]), action: command[2], mode: body.mode ?? null });
    }
    return reply(404, { code: "NOT_FOUND" });
  };
  fake.posts = () => fake.calls.filter((call) => call.method === "POST").map(({ path, search, body }) => ({ path, search, body }));
  fake.reads = () => fake.calls.filter((call) => call.method === "GET" && call.path === "/v1/alarm").length;
  fake.reportAfter = (reads, next) => {
    fake.next = { reads, partitions: next };
  };
  return fake;
}

// Connected as an admin to a 1.15.0 controller whose alarm shows `partitions`.
async function armingHome(partitions, role = "admin") {
  forgetKey();
  home({ role });
  state.system.features.alarm_arming = true;
  state.system.features.alarm_control = true;
  document.activeElement = null;
  const fake = alarmController(partitions);
  await loadAlarm();
  return fake;
}

// Types `code` into the open dialog and sends it.
function typeAndSend(code) {
  const dialog = shownDialog();
  assert.ok(dialog?.open, "the dialog is open");
  const input = byKey(dialog, "alarm-code");
  input.value = code;
  input.dispatch("input");
  find(dialog, (node) => node.tagName === "FORM").dispatch("submit");
  return input;
}

test("while Alarm Status is Off nothing is asked and nothing is shown", async () => {
  for (const setup of [{ alarmStatus: false }, { features: false }]) {
    home(setup);
    const sent = controller(ON);
    await loadAlarm();
    assert.equal(asksAlarm(sent), false, "GET /v1/alarm is not even asked");
    assert.equal(alarmSection(), null, "nothing on Home");
    assert.equal(alarmFact(), null, "nothing in Settings");
  }
});

test("viewers never see it, and the app does not ask", async () => {
  for (const role of ["viewer", null]) {
    home({ role });
    const sent = controller(ON);
    await loadAlarm();
    assert.equal(asksAlarm(sent), false, `role ${role}`);
    assert.equal(alarmSection(), null, `role ${role}`);
    state.alarm = ON;
    assert.equal(alarmSection(), null, `role ${role}: not even with the answer at hand`);
    assert.equal(alarmFact(), null);
  }
});

test("members, door keys and admins see each partition in words on Home and in Settings", async () => {
  for (const role of ["member", "doors", "admin"]) {
    home({ role });
    const sent = controller(ON);
    await loadAlarm();
    assert.deepEqual(sent.filter((line) => line.endsWith("/v1/alarm")), ["GET /v1/alarm"], role);
    const section = alarmSection();
    assert.ok(section, role);
    const text = section.textContent;
    for (const words of ["Alarm", "Read only", "Garage", "Kitchen", "Armed away", "House", "Disarmed, not ready", "1 zone open"]) {
      assert.ok(text.includes(words), `${role}: "${words}" in ${text}`);
    }
    const rows = section.children[1].children;
    assert.deepEqual(rows.map((row) => row.className), ["device alarm-partition is-armed", "device alarm-partition is-not-ready"]);
    assert.deepEqual(alarmFact(), ["Alarm", `${iso("Garage")}: Armed away · ${iso("House")}: Disarmed, not ready`]);
  }
  state.alarm = { enabled: true, partitions: [garage] };
  assert.deepEqual(alarmFact(), ["Alarm", "Armed away"], "one partition: just its state");
});

test("every state in natural English", () => {
  const cases = [
    [{ alarm: true, state: "alarm", alarm_type: "Fire" }, "Alarm: fire"],
    [{ alarm: true, state: "alarm", alarm_type: "BURGLARY" }, "Alarm: burglary"],
    [{ alarm: true, alarm_type: "Water Flow" }, `Alarm: ${iso("Water flow")}`],
    [{ alarm: true }, "Alarm!"],
    [{ state: "entry_delay", armed: true, armed_mode: "away" }, "Entry delay"],
    [{ state: "exit_delay" }, "Exit delay"],
    [{ state: "armed", armed: true, armed_mode: "home", armed_type: "Night" }, `Armed home (${iso("Night")})`],
    [{ state: "armed", armed: true, armed_mode: "home", armed_type: "Stay" }, "Armed home"],
    [{ state: "armed", armed: true, armed_mode: "away", armed_type: "away" }, "Armed away"],
    [{ state: "armed", armed: true }, "Armed"],
    [{ state: "disarmed_ready" }, "Disarmed, ready"],
    [{ state: "disarmed_not_ready" }, "Disarmed, not ready"],
    [{ state: "confirmation_required" }, "Confirmation needed"],
    [{ state: "offline" }, "Panel offline"],
    [{ state: "bypass_active" }, iso("Bypass active")],
    [{}, "Unknown"],
  ];
  for (const [fields, expected] of cases) {
    assert.equal(alarmStateText(partition(fields)), expected, JSON.stringify(fields));
  }
  const troubled = partition({ state: "disarmed_not_ready", open_zones: 3, trouble: "AC power lost" });
  assert.deepEqual(alarmDetails(troubled), ["3 zones open", `Trouble: ${iso("AC power lost")}`]);
  assert.deepEqual(alarmDetails(partition({ state: "disarmed_ready" })), [], "nothing more to say");
});

test("an entry or exit delay counts down between reads, whether or not the panel updates it", async () => {
  home();
  const start = 1_000_000;
  const entering = partition({ id: 80, name: "House", state: "entry_delay", armed: true, armed_mode: "away", delay: { type: "entry", remaining: 20, total: 30 } });
  controller({ enabled: true, partitions: [entering] });
  await loadAlarm(start);
  const shown = () => state.alarm.partitions[0];
  assert.deepEqual(alarmDetails(shown(), start), ["20 seconds left"]);
  assert.deepEqual(alarmDetails(shown(), start + 5000), ["15 seconds left"]);
  // The panel reported the time once: the next read still counts from then.
  await loadAlarm(start + 10000);
  assert.deepEqual(alarmDetails(shown(), start + 10000), ["10 seconds left"]);
  // A new report counts from when it came.
  controller({ enabled: true, partitions: [{ ...entering, delay: { type: "entry", remaining: 8, total: 30 } }] });
  await loadAlarm(start + 11000);
  assert.deepEqual(alarmDetails(shown(), start + 12000), ["7 seconds left"]);
  assert.deepEqual(alarmDetails(shown(), start + 11000 + 60000), [], "none once it has run out");
  assert.equal(alarmDetails(partition({ delay: { type: "exit", remaining: 1, total: 30 } }), 0)[0], "1 second left");
});

// Elements of a fake tree whose dataset has `key`.
function findAll(node, key, found = []) {
  if (node && node.dataset && node.dataset[key] !== undefined) found.push(node);
  for (const child of node?.children || []) findAll(child, key, found);
  return found;
}

test("a countdown changes nothing the renderer compares, so a tap during it does not redraw the buttons (1.16.1)", async () => {
  home();
  const start = 2_000_000;
  const leaving = partition({ id: 80, name: "House", state: "exit_delay", delay: { type: "exit", remaining: 180, total: 180 } });
  controller({ enabled: true, partitions: [leaving] });
  await loadAlarm(start);
  const first = JSON.stringify(alarmSignature(start));
  assert.equal(JSON.stringify(alarmSignature(start + 1000)), first, "a second later: the same");
  assert.equal(JSON.stringify(alarmSignature(start + 179000)), first, "near the end: the same");
  assert.notEqual(JSON.stringify(alarmSignature(start + 181000)), first, "once it has run out: redrawn, once");
});

test("the countdown is counted down in place, its row's buttons untouched (1.16.1)", async () => {
  home();
  const start = Date.now();
  const leaving = partition({ id: 80, name: "House", state: "exit_delay", delay: { type: "exit", remaining: 175, total: 180 } });
  controller({ enabled: true, partitions: [leaving] });
  await loadAlarm(start);
  const section = alarmSection(start);
  const [countdown] = findAll(section, "alarmDelay");
  assert.ok(countdown, "the countdown has an element of its own");
  assert.equal(countdown.dataset.alarmDelay, "80");
  assert.equal(countdown.textContent, "175 seconds left");
  const buttons = findAll(section, "key").filter((element) => element.tagName === "BUTTON");
  const realQuery = document.querySelectorAll;
  document.querySelectorAll = (selector) => (selector === "[data-alarm-delay]" ? [countdown] : []);
  try {
    assert.equal(tickAlarmDelays(start + 5000), 1, "still counting");
    assert.equal(countdown.textContent, "170 seconds left");
    assert.deepEqual(findAll(section, "key").filter((element) => element.tagName === "BUTTON"), buttons, "the same buttons");
    assert.equal(tickAlarmDelays(start + 200000), 0, "run out: the timer stops");
    assert.equal(countdown.textContent, "");
  } finally {
    document.querySelectorAll = realQuery;
  }
});

test("in Hebrew", async () => {
  await setLanguage("he");
  try {
    assert.equal(alarmStateText(garage), "דריכה מלאה");
    assert.equal(alarmStateText(partition({ state: "armed", armed: true, armed_mode: "home" })), "דריכה ביתית");
    assert.equal(alarmStateText(house), "מנוטרלת, לא מוכנה לדריכה");
    assert.equal(alarmStateText(partition({ state: "disarmed_ready" })), "מנוטרלת, מוכנה לדריכה");
    assert.equal(alarmStateText(partition({ alarm: true, alarm_type: "Fire" })), "אזעקה: שריפה");
    assert.equal(alarmStateText(partition({ state: "entry_delay" })), "זמן כניסה");
    assert.equal(alarmStateText(partition({ state: "exit_delay" })), "זמן יציאה");
    assert.deepEqual(alarmDetails(house), ["אזור אחד פתוח"]);
    assert.deepEqual(alarmDetails(partition({ open_zones: 2 })), ["שני אזורים פתוחים"]);
    assert.deepEqual(alarmDetails(partition({ open_zones: 5 })), ["5 אזורים פתוחים"]);
    assert.deepEqual(alarmDetails(partition({ delay: { type: "exit", remaining: 1, total: 30 } }), 0), ["נותרה שנייה אחת"]);
    assert.deepEqual(alarmDetails(partition({ trouble: "Low battery" })), [`תקלה: ${iso("Low battery")}`]);
    assert.equal(alarmSummary([garage, house]), `${iso("Garage")}: דריכה מלאה · ${iso("House")}: מנוטרלת, לא מוכנה לדריכה`);
    home();
    state.alarm = ON;
    const text = alarmSection().textContent;
    assert.ok(text.includes("אזעקה") && text.includes("לקריאה בלבד"), text);
  } finally {
    await setLanguage("en");
  }
  // Every English text has its Hebrew one.
  const keys = (node, prefix = "") =>
    Object.entries(node).flatMap(([key, value]) => (value && typeof value === "object" ? keys(value, `${prefix}${key}.`) : [`${prefix}${key}`]));
  const missing = keys(en.alarm).filter((key) => !keys(he.alarm).includes(key) && !/\.(one|other)$/.test(key));
  assert.deepEqual(missing, []);
  for (const key of keys(en.alarm).filter((name) => /\.(one|other)$/.test(name))) {
    assert.ok(keys(he.alarm).includes(key), key);
  }
});

test("a refusal shows nothing; an answer that does not come keeps the last", async () => {
  home();
  controller(ON);
  await loadAlarm();
  assert.ok(alarmSection());
  controller(403); // SEALED_REQUEST_REQUIRED: this request could not be sealed
  await loadAlarm();
  assert.equal(alarmSection(), null);
  controller(ON);
  await loadAlarm();
  controller("offline");
  await loadAlarm();
  assert.ok(alarmSection(), "the controller did not answer: the last status stays (Home says it cannot reach it)");
  controller({ enabled: false, partitions: [] }); // turned off in Composer since
  await loadAlarm();
  assert.equal(alarmSection(), null);
  controller(404); // an older driver
  await loadAlarm();
  assert.equal(alarmSection(), null);
  controller({ enabled: true, partitions: [] });
  await loadAlarm();
  assert.equal(alarmSection(), null, "no partition in use: nothing to show");
});

test("a refused read is not repeated every 10 s, only with the next rooms refresh", async (t) => {
  home();
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const settle = async () => {
    for (let i = 0; i < 20; i++) await new Promise((resolve) => setImmediate(resolve));
  };
  const reads = (sent) => sent.filter((line) => line === "GET /v1/alarm").length;
  let sent = controller(403);
  await startAlarm();
  assert.equal(reads(sent), 1);
  for (let i = 0; i < 3; i++) {
    t.mock.timers.tick(10000);
    await settle();
  }
  assert.equal(reads(sent), 1, "not asked again every 10 s");
  sent = controller(ON);
  await startAlarm(); // the next rooms refresh, a minute later
  assert.equal(reads(sent), 1);
  assert.ok(alarmSection());
  t.mock.timers.tick(10000);
  await settle();
  assert.equal(reads(sent), 2, "then every 10 s again");
  forgetKey();
  t.mock.timers.tick(10000);
  await settle();
  assert.equal(reads(sent), 2, "and not at all once the key is forgotten");
});

test("without control the app only reads the alarm, forgets it with the key, and only alarm-control.js sends it anything", async () => {
  home();
  const sent = controller(ON);
  startAlarm();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(alarmSection());
  assert.equal(byKey(alarmSection(), "alarm:81:disarm"), null, "a controller before 1.15.0 says no control: nothing to press");
  assert.deepEqual([...new Set(sent.filter((line) => line.includes("/v1/alarm")))], ["GET /v1/alarm"]);
  forgetKey();
  assert.equal(state.alarm, null, "nothing of it stays in this browser");
  assert.equal(alarmSection(), null);
  for (const file of ["app/js/alarm.js", "app/js/views/alarm.js"]) {
    const source = readFileSync(new URL(`../../${file}`, import.meta.url), "utf8");
    assert.doesNotMatch(source, /method:/, `${file} sends nothing but GET`);
    assert.doesNotMatch(source, /onclick/, `${file} has nothing to press: views/alarm-control.js has Arm and Disarm`);
  }
  const sender = readFileSync(new URL("../../app/js/alarm-control.js", import.meta.url), "utf8");
  assert.match(sender, /api\(`\/v1\/alarm\/\$\{id\}\/\$\{action\}`, \{ method: "POST", body \}\)/, "one POST, the code in its body");
});

// ---- arming and disarming (1.15.0, ADR-091) ------------------------------------------------------

test("Arm and Disarm only where the controller allows them; a note while its driver can't", async () => {
  await armingHome([READY]);
  const actions = (shown) => {
    state.alarm = { enabled: true, partitions: [shown] };
    return ["arm", "disarm"].filter((action) => byKey(alarmSection(), `alarm:80:${action}`));
  };
  const { modes: _modes, control: _control, ...older } = READY;
  for (const [shown, expected, why] of [
    [{ ...READY, control: { allowed: false, available: true } }, [], "not this person's (a member not given it, or Alarm Control off)"],
    [older, [], "a controller before 1.15.0"],
    [READY, ["arm"], "disarmed"],
    [{ ...READY, state: "disarmed_not_ready", open_zones: 2 }, ["arm"], "not ready: the panel decides"],
    [{ ...READY, modes: [] }, [], "no modes: no Arm"],
    [ARMED, ["disarm"], "armed"],
    [{ ...READY, state: "exit_delay", delay: { type: "exit", remaining: 20, total: 30 } }, ["disarm"], "exit delay"],
    [{ ...ARMED, state: "entry_delay", delay: { type: "entry", remaining: 20, total: 30 } }, ["disarm"], "entry delay"],
    [{ ...ARMED, state: "alarm", alarm: true, alarm_type: "burglary" }, ["disarm"], "in alarm"],
    [{ ...READY, modes: [], state: "alarm", alarm: true }, ["disarm"], "in alarm, without modes"],
    [{ ...READY, state: "offline" }, [], "a state it doesn't know"],
  ]) {
    assert.deepEqual(actions(shown), expected, why);
  }

  // Read only, unless a partition may be armed or disarmed.
  state.alarm = { enabled: true, partitions: [{ ...READY, control: { allowed: false, available: true } }] };
  assert.match(alarmSection().textContent, /Read only/);
  state.alarm = { enabled: true, partitions: [READY] };
  assert.doesNotMatch(alarmSection().textContent, /Read only/);

  // Its driver can't now (the PIMA FORCE driver while its panel only reports): no buttons, and why.
  state.alarm = { enabled: true, partitions: [{ ...READY, control: { allowed: true, available: false } }, { ...ARMED, id: 81, name: "Garage", control: { allowed: true, available: false } }] };
  const section = alarmSection();
  assert.equal(byKey(section, "alarm:80:arm"), null);
  assert.equal(byKey(section, "alarm:81:disarm"), null);
  assert.match(section.textContent, /Can’t be armed or disarmed from DirectorLink right now: its panel only reports to the controller, or isn’t connected\./);

  // Named for screen readers with the partition; the visible word first.
  state.alarm = { enabled: true, partitions: [READY, { ...ARMED, id: 81, name: "Garage" }] };
  const arm = byKey(alarmSection(), "alarm:80:arm");
  assert.equal(arm.attributes["aria-label"], "Arm House");
  assert.equal(plain(arm.textContent), "Arm");
  assert.equal(byKey(alarmSection(), "alarm:81:disarm").attributes["aria-label"], "Disarm Garage");
  assert.equal(shownDialog(), null, "no dialog until one is pressed");
});

test("Arm: a mode, then the code typed in a dialog; exactly { mode, code } goes, and nothing of the code stays", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const fake = await armingHome([READY]);
  const before = fake.calls.length;
  press(alarmSection(), "alarm:80:arm");
  assert.equal(ui.alarmControl[80].stage, "choose");
  let section = alarmSection();
  const group = find(section, (node) => node.attributes.role === "group");
  assert.match(group.textContent, /Arm in which mode\?/);
  assert.deepEqual([0, 1, 2].map((index) => plain(byKey(section, `alarm:80:mode:${index}`).textContent)), ["Away", "Home", "Night"]);
  assert.equal(byKey(section, "alarm:80:mode:1").attributes["aria-label"], "Arm House: Home");
  // Cancel: back to Arm.
  press(section, "alarm:80:cancel");
  assert.equal(ui.alarmControl[80], undefined);
  assert.ok(byKey(alarmSection(), "alarm:80:arm"));

  press(alarmSection(), "alarm:80:arm");
  press(alarmSection(), "alarm:80:mode:1");
  const dialog = shownDialog();
  assert.ok(dialog?.open, "the code is asked in a dialog");
  assert.equal(plain(find(dialog, (node) => node.attributes.id === "alarm-dialog-title").textContent), "Arm House: Home");
  const input = byKey(dialog, "alarm-code");
  assert.equal(document.activeElement, input, "the field has the keyboard");
  // Masked, the number pad, never filled or saved by the browser.
  assert.equal(input.attributes.type, "password");
  assert.equal(input.attributes.inputmode, "numeric");
  assert.equal(input.attributes.autocomplete, "off");
  assert.equal(input.attributes.maxlength, "12");
  assert.equal(find(dialog, (node) => node.tagName === "FORM").attributes.autocomplete, "off");
  assert.equal(find(dialog, (node) => node.tagName === "LABEL").attributes.for, input.attributes.id);
  assert.equal(fake.calls.length, before, "nothing is sent before the code");
  // Digits only, at most 12.
  input.value = "90 81a72";
  input.dispatch("input");
  assert.equal(input.value, CODE);
  input.value = "1234567890123";
  input.dispatch("input");
  assert.equal(input.value, "123456789012");

  typeAndSend(CODE);
  await settle();
  assert.deepEqual(fake.posts(), [{ path: "/v1/alarm/80/arm", search: "", body: { mode: "Home", code: CODE } }], "the mode as its driver names it, and the code: nothing else");
  // Nothing of the code stays: not in the field, the page, the app's state, storage, the console, a URL.
  assert.equal(input.value, "");
  assert.equal(dialog.open, false);
  assert.equal(shownDialog(), null, "the dialog is out of the page");
  assert.ok(!pageText(document.body).includes(CODE));
  assert.ok(!pageText(alarmSection()).includes(CODE));
  assert.ok(!JSON.stringify([state, ui]).includes(CODE));
  assert.ok(![...stored.entries()].flat().some((value) => value.includes(CODE)));
  assert.ok(!logged.some((line) => line.includes(CODE)));
  assert.ok(fake.calls.every((call) => !call.url.includes(CODE) && !call.headers.includes(CODE)));
  // Arming…: nothing to press meanwhile.
  section = alarmSection();
  const status = byKey(section, "alarm:80:status");
  assert.equal(plain(status.textContent), "Arming…");
  assert.equal(status.attributes.role, "status");
  assert.equal(byKey(section, "alarm:80:arm"), null);
  forgetKey();
});

test("a single mode: Arm opens the code at once; Cancel, Escape and a code that isn't 1–12 digits send nothing", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const fake = await armingHome([{ ...READY, modes: ["Away"] }]);
  press(alarmSection(), "alarm:80:arm");
  let dialog = shownDialog();
  assert.equal(plain(find(dialog, (node) => node.attributes.id === "alarm-dialog-title").textContent), "Arm House: Away", "no choice to make");
  // Nothing typed: said, and not sent.
  typeAndSend("");
  await settle();
  assert.equal(dialog.open, true);
  assert.match(find(dialog, (node) => node.attributes.id === "alarm-code-problem").textContent, /Type the alarm code: 1 to 12 digits\./);
  assert.deepEqual(fake.posts(), []);
  // Cancel: closed, and what was typed is gone.
  let input = byKey(dialog, "alarm-code");
  input.value = "4321";
  press(dialog, "alarm-code-cancel");
  assert.equal(input.value, "");
  assert.equal(shownDialog(), null);
  // Escape (the browser closes the dialog): the same.
  press(alarmSection(), "alarm:80:arm");
  dialog = shownDialog();
  input = byKey(dialog, "alarm-code");
  input.value = "4321";
  dialog.close();
  assert.equal(input.value, "");
  assert.equal(shownDialog(), null);
  // A tap on the backdrop: the same.
  press(alarmSection(), "alarm:80:arm");
  dialog = shownDialog();
  dialog.dispatch("click", { target: dialog });
  assert.equal(shownDialog(), null);
  await settle();
  assert.deepEqual(fake.posts(), [], "nothing was sent");
  forgetKey();
});

test("after the 202 the partition is read again until it shows what was asked: arming, then disarming", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const fake = await armingHome([READY]);
  press(alarmSection(), "alarm:80:arm");
  press(alarmSection(), "alarm:80:mode:0");
  // The panel counts down its exit delay by the second read.
  fake.reportAfter(2, [{ ...READY, state: "exit_delay", delay: { type: "exit", remaining: 30, total: 30 } }]);
  typeAndSend(CODE);
  await settle();
  const reads = fake.reads();
  assert.deepEqual(fake.posts().map((post) => post.body), [{ mode: "Away", code: CODE }]);
  await advance(t, 1500);
  assert.equal(fake.reads(), reads, "not read again at once");
  await advance(t, 500);
  assert.equal(fake.reads(), reads + 1, "read again 2 s later");
  assert.match(alarmSection().textContent, /Arming…/, "still disarmed: still arming");
  await advance(t, FOLLOW_MS[1]);
  assert.equal(fake.reads(), reads + 2);
  let section = alarmSection();
  assert.equal(ui.alarmControl[80], undefined, "the exit delay: it took it");
  assert.match(section.textContent, /Exit delay/);
  assert.ok(byKey(section, "alarm:80:disarm"), "Disarm, during the exit delay too");
  assert.equal(byKey(section, "alarm:80:message"), null, "nothing went wrong");
  await advance(t, 20000);
  assert.equal(fake.reads(), reads + 2, "and no more reads of its own");

  // Disarm: only the code goes.
  press(section, "alarm:80:disarm");
  assert.equal(plain(find(shownDialog(), (node) => node.attributes.id === "alarm-dialog-title").textContent), "Disarm House");
  fake.reportAfter(1, [READY]);
  typeAndSend(CODE);
  await settle();
  assert.deepEqual(fake.posts().at(-1), { path: "/v1/alarm/80/disarm", search: "", body: { code: CODE } });
  assert.match(alarmSection().textContent, /Disarming…/);
  await advance(t, 2000);
  section = alarmSection();
  assert.equal(ui.alarmControl[80], undefined);
  assert.ok(byKey(section, "alarm:80:arm"), "disarmed: Arm again");
  assert.match(section.textContent, /Disarmed, ready/);
  assert.ok(!JSON.stringify([state, ui]).includes(CODE));
  forgetKey();
});

test("what counts as done: armed or an exit delay; disarmed, out of alarm and without a delay", () => {
  assert.equal(commandTook("arm", READY), false);
  assert.equal(commandTook("arm", ARMED), true);
  assert.equal(commandTook("arm", { ...READY, state: "exit_delay" }), true);
  assert.equal(commandTook("disarm", ARMED), false);
  assert.equal(commandTook("disarm", { ...READY, state: "alarm", alarm: true }), false);
  assert.equal(commandTook("disarm", { ...READY, state: "entry_delay", delay: { type: "entry", remaining: 5, total: 30 } }), false);
  assert.equal(commandTook("disarm", READY), true);
  assert.equal(commandTook("disarm", { ...READY, state: "disarmed_not_ready", open_zones: 1 }), true);
});

test("when the alarm didn't take it, after 20 s the app says so (check the code, or the keypad)", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const fake = await armingHome([READY]);
  press(alarmSection(), "alarm:80:arm");
  press(alarmSection(), "alarm:80:mode:2");
  typeAndSend(CODE);
  await settle();
  const reads = fake.reads();
  await advance(t, 19500);
  assert.match(alarmSection().textContent, /Arming…/, "still waiting at 19.5 s");
  await advance(t, 500);
  assert.equal(fake.reads(), reads + FOLLOW_MS.length, "read 6 times in 20 s");
  let section = alarmSection();
  const message = byKey(section, "alarm:80:message");
  assert.equal(message.attributes.role, "alert");
  assert.equal(message.textContent, "The alarm didn’t arm. Check the code and that no zone is open, then try again, or use the alarm’s keypad.");
  assert.ok(byKey(section, "alarm:80:arm"), "Arm again");
  // Pressing again: the message has said its piece.
  press(section, "alarm:80:arm");
  assert.equal(byKey(alarmSection(), "alarm:80:message"), null);
  press(alarmSection(), "alarm:80:cancel");

  // A disarm the alarm didn't take.
  state.alarm = { enabled: true, partitions: [ARMED] };
  fake.partitions = [ARMED];
  press(alarmSection(), "alarm:80:disarm");
  typeAndSend(CODE);
  await settle();
  await advance(t, 20000);
  section = alarmSection();
  assert.equal(byKey(section, "alarm:80:message").textContent, "The alarm didn’t disarm. Check the code and try again, or use the alarm’s keypad.");
  // It goes by itself after a minute.
  await advance(t, 60000, 5000);
  assert.equal(byKey(alarmSection(), "alarm:80:message"), null);
  forgetKey();
});

test("refusals in the app's words: too many (and for how long), its driver can't, the switch in Composer, the permission, the controller", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const fake = await armingHome([ARMED]);
  for (const [status, problem, headers, expected, readAgain] of [
    [429, { code: "RATE_LIMITED", retry_after: 170 }, {}, "Too many alarm commands. Try again in 3 minutes."],
    [429, { code: "RATE_LIMITED" }, { "Retry-After": "45" }, "Too many alarm commands. Try again in 1 minute."],
    [429, { code: "RATE_LIMITED" }, {}, "Too many alarm commands. Try again in a few minutes."],
    [409, { code: "ALARM_UNAVAILABLE" }, {}, "Can’t be armed or disarmed from DirectorLink right now: its panel only reports to the controller, or isn’t connected.", true],
    [409, { code: "NO_ARM_MODES" }, {}, "Its alarm declares no modes to arm in: DirectorLink can only disarm it.", true],
    [403, { code: "ALARM_CONTROL_DISABLED" }, {}, "Arming and disarming from DirectorLink is off. An installer turns it on with Alarm Control in Composer (DirectorLink properties).", true],
    [403, { code: "FORBIDDEN", role: "member" }, {}, "You can’t arm or disarm the alarm. An admin can allow it in Settings → Users.", true],
    [403, { code: "SEALED_REQUEST_REQUIRED" }, {}, "Alarm commands travel only sealed, and this one was not. Reload the app and try again."],
    [502, { code: "CONTROLLER_COMMAND_FAILED" }, {}, "The controller couldn’t pass the command to the alarm. Try again, or use the alarm’s keypad."],
    [404, { code: "NOT_FOUND" }, {}, "This part of the alarm is no longer in the project.", true],
  ]) {
    state.role = "admin";
    fake.refuse = [status, problem, headers];
    const reads = fake.reads();
    press(alarmSection(), "alarm:80:disarm");
    typeAndSend(CODE);
    await settle();
    const message = byKey(alarmSection(), "alarm:80:message");
    assert.equal(message?.textContent, expected, `${status} ${problem.code}`);
    assert.equal(ui.alarmControl[80].stage, null, "not waiting for the alarm");
    assert.equal(fake.reads() > reads, Boolean(readAgain), `${problem.code}: the partitions read again when what may be done changed`);
    const after = fake.reads();
    await advance(t, 20000, 5000);
    assert.equal(fake.reads(), after, "no reads of its own after a refusal");
  }
  assert.ok(!logged.some((line) => line.includes(CODE)));
  forgetKey();
});

test("in Hebrew, Spanish and Italian", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const words = {
    he: { arm: "דריכה", disarm: "ניטרול", modes: ["מלאה", "ביתית", "לילה"], title: "דריכת House: ביתית", arming: "דורך…", notArmed: /^האזעקה לא נדרכה\. בדקו את הקוד/ },
    es: { arm: "Armar", disarm: "Desarmar", modes: ["Ausente", "En casa", "Noche"], title: "Armar House: En casa", arming: "Armando…", notArmed: /^La alarma no se armó\./ },
    it: { arm: "Inserisci", disarm: "Disinserisci", modes: ["Totale", "Parziale", "Notte"], title: "Inserisci House: Parziale", arming: "Inserimento…", notArmed: /^L’allarme non si è inserito\./ },
  };
  try {
    for (const [language, expected] of Object.entries(words)) {
      await setLanguage(language);
      const fake = await armingHome([READY, { ...ARMED, id: 81, name: "Garage" }]);
      assert.equal(plain(byKey(alarmSection(), "alarm:80:arm").textContent), expected.arm, language);
      assert.equal(plain(byKey(alarmSection(), "alarm:81:disarm").textContent), expected.disarm, language);
      press(alarmSection(), "alarm:80:arm");
      assert.deepEqual([0, 1, 2].map((index) => plain(byKey(alarmSection(), `alarm:80:mode:${index}`).textContent)), expected.modes, language);
      press(alarmSection(), "alarm:80:mode:1");
      assert.equal(plain(find(shownDialog(), (node) => node.attributes.id === "alarm-dialog-title").textContent), expected.title, language);
      typeAndSend(CODE);
      await settle();
      assert.deepEqual(fake.posts().at(-1).body, { mode: "Home", code: CODE }, `${language}: the driver's own word is sent`);
      assert.equal(plain(byKey(alarmSection(), "alarm:80:status").textContent), expected.arming, language);
      await advance(t, 20000);
      assert.match(byKey(alarmSection(), "alarm:80:message").textContent, expected.notArmed, language);
    }
    // A name in the other direction stays in one piece inside the Hebrew title.
    await setLanguage("he");
    await armingHome([READY]);
    press(alarmSection(), "alarm:80:arm");
    press(alarmSection(), "alarm:80:mode:0");
    assert.equal(find(shownDialog(), (node) => node.attributes.id === "alarm-dialog-title").textContent, `דריכת ${iso("House")}: מלאה`);
    press(shownDialog(), "alarm-code-cancel");
  } finally {
    await setLanguage("en");
    forgetKey();
  }
});

test("every word of the alarm is in all four languages", () => {
  // Plural forms count as one word (Hebrew has more of them).
  const keys = (node, prefix = "") =>
    Object.entries(node).flatMap(([key, value]) => (value && typeof value === "object" && !("other" in value) ? keys(value, `${prefix}${key}.`) : [`${prefix}${key}`]));
  for (const [code, dictionary] of Object.entries({ he, es, it })) {
    assert.deepEqual(keys(dictionary.alarm).sort(), keys(en.alarm).sort(), code);
    assert.deepEqual(keys(dictionary.history.alarm).sort(), keys(en.history.alarm).sort(), code);
    for (const key of ["alarmControl", "alarmControlHelp", "summaryAlarmControl"]) assert.ok(dictionary.perm[key], `${code} perm.${key}`);
    assert.ok(dictionary.history.filters.alarm, `${code} history.filters.alarm`);
  }
});

test("the key forgotten while the code is typed or the alarm is asked: the dialog goes, nothing follows", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let fake = await armingHome([ARMED]);
  press(alarmSection(), "alarm:80:disarm");
  const input = byKey(shownDialog(), "alarm-code");
  input.value = "4321";
  forgetKey();
  assert.equal(shownDialog(), null);
  assert.equal(input.value, "");
  assert.deepEqual(fake.posts(), []);

  fake = await armingHome([ARMED]);
  press(alarmSection(), "alarm:80:disarm");
  typeAndSend(CODE);
  await settle();
  const reads = fake.reads();
  forgetKey();
  assert.deepEqual(ui.alarmControl, {});
  await advance(t, 20000);
  assert.equal(fake.reads(), reads, "not read again for a forgotten key");
});

// ---- without a code (1.16.0, ADR-092) ------------------------------------------------------------

// A partition of a 1.16.0 controller that goes without a code this far (`control.without_code`).
const free = (partition, level) => ({ ...partition, control: { ...partition.control, without_code: level } });
const SHABBAT_MODES = ["Away", "Home", "Shabbat"];

test("arming without a code: the mode, then exactly { mode } goes, with no dialog; Arming… as before", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  for (const level of ["arm", "arm_disarm"]) {
    const fake = await armingHome([free(READY, level)]);
    press(alarmSection(), "alarm:80:arm");
    assert.equal(ui.alarmControl[80].stage, "choose", `${level}: the mode is still chosen`);
    press(alarmSection(), "alarm:80:mode:2");
    assert.equal(shownDialog(), null, `${level}: no code asked`);
    await settle();
    assert.deepEqual(fake.posts(), [{ path: "/v1/alarm/80/arm", search: "", body: { mode: "Night" } }], `${level}: no code in the body`);
    assert.equal(plain(byKey(alarmSection(), "alarm:80:status").textContent), "Arming…");
    // The alarm didn't take it: nothing about a code that was not typed.
    await advance(t, 20000);
    assert.equal(byKey(alarmSection(), "alarm:80:message").textContent, "The alarm didn’t arm. Check that no zone is open, then try again, or use the alarm’s keypad.");
    forgetKey();
  }
  // A single mode: Arm sends at once.
  const fake = await armingHome([free({ ...READY, modes: ["Away"] }, "arm")]);
  fake.reportAfter(1, [free({ ...ARMED, modes: ["Away"] }, "arm")]);
  press(alarmSection(), "alarm:80:arm");
  assert.equal(shownDialog(), null);
  await settle();
  assert.deepEqual(fake.posts().map((post) => post.body), [{ mode: "Away" }]);
  await advance(t, 2000);
  assert.equal(ui.alarmControl[80], undefined, "it took it");
  assert.ok(byKey(alarmSection(), "alarm:80:disarm"));
  forgetKey();
});

test("a code is still typed where the partition does not go without one: none, or a disarm when only arming goes", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  for (const [partition, action, why] of [
    [free(READY, "none"), "arm", "none"],
    [{ ...READY, control: { allowed: true, available: true } }, "arm", "a controller before 1.16.0"],
    [free(ARMED, "arm"), "disarm", "only arming goes without one"],
    [free(ARMED, "none"), "disarm", "none"],
  ]) {
    const fake = await armingHome([partition]);
    press(alarmSection(), `alarm:80:${action}`);
    if (action === "arm") press(alarmSection(), "alarm:80:mode:0");
    assert.ok(byKey(shownDialog(), "alarm-code"), `${why}: the code is asked`);
    typeAndSend(CODE);
    await settle();
    assert.deepEqual(fake.posts().at(-1).body, action === "arm" ? { mode: "Away", code: CODE } : { code: CODE }, why);
    forgetKey();
  }
});

test("disarming without a code: Disarm House? first, then exactly {} goes; Cancel, Escape and the backdrop send nothing", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const fake = await armingHome([free(ARMED, "arm_disarm")]);
  // Cancel, Escape and a tap on the backdrop: nothing sent.
  for (const close of [(dialog) => press(dialog, "alarm-code-cancel"), (dialog) => dialog.close(), (dialog) => dialog.dispatch("click", { target: dialog })]) {
    press(alarmSection(), "alarm:80:disarm");
    const dialog = shownDialog();
    assert.ok(dialog?.open, "a confirmation first");
    close(dialog);
    assert.equal(shownDialog(), null);
  }
  await settle();
  assert.deepEqual(fake.posts(), [], "nothing sent");

  press(alarmSection(), "alarm:80:disarm");
  const dialog = shownDialog();
  assert.equal(plain(find(dialog, (node) => node.attributes.id === "alarm-dialog-title").textContent), "Disarm House?");
  assert.equal(byKey(dialog, "alarm-code"), null, "no code field");
  assert.equal(byKey(dialog, "alarm-confirm-help").textContent, "No code needed: the alarm’s driver uses its own.");
  const send = byKey(dialog, "alarm-confirm-send");
  assert.equal(plain(send.textContent), "Disarm");
  assert.equal(document.activeElement, send, "Disarm has the keyboard");
  fake.reportAfter(1, [free(READY, "arm_disarm")]);
  find(dialog, (node) => node.tagName === "FORM").dispatch("submit");
  assert.equal(shownDialog(), null);
  await settle();
  assert.deepEqual(fake.posts(), [{ path: "/v1/alarm/80/disarm", search: "", body: {} }], "no code: an empty body");
  assert.equal(plain(byKey(alarmSection(), "alarm:80:status").textContent), "Disarming…");
  await advance(t, 2000);
  assert.equal(ui.alarmControl[80], undefined);
  assert.ok(byKey(alarmSection(), "alarm:80:arm"), "disarmed: Arm again");

  // Not taken: nothing about a code.
  state.alarm = { enabled: true, partitions: [free(ARMED, "arm_disarm")] };
  fake.partitions = [free(ARMED, "arm_disarm")];
  press(alarmSection(), "alarm:80:disarm");
  find(shownDialog(), (node) => node.tagName === "FORM").dispatch("submit");
  await settle();
  await advance(t, 20000);
  assert.equal(byKey(alarmSection(), "alarm:80:message").textContent, "The alarm didn’t disarm. Try again, or use the alarm’s keypad.");
  forgetKey();
});

test("CODE_REQUIRED (the setting changed meanwhile): the partitions read again, and the code asked after all", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  for (const [shown, action, sent] of [
    [free(READY, "arm"), "arm", { mode: "Away" }],
    [free(ARMED, "arm_disarm"), "disarm", {}],
  ]) {
    const fake = await armingHome([shown]);
    // An admin chose a code every time since the partitions were read.
    fake.partitions = [free(shown, "none")];
    fake.refuse = [400, { code: "CODE_REQUIRED", title: "This alarm needs a code" }];
    press(alarmSection(), `alarm:80:${action}`);
    if (action === "arm") press(alarmSection(), "alarm:80:mode:0");
    else find(shownDialog(), (node) => node.tagName === "FORM").dispatch("submit");
    const reads = fake.reads();
    await settle();
    assert.deepEqual(fake.posts().map((post) => post.body), [sent], `${action}: sent without a code first`);
    assert.ok(fake.reads() > reads, `${action}: the partitions read again`);
    assert.equal(byKey(alarmSection(), "alarm:80:message"), null, `${action}: no error, the code is asked instead`);
    const dialog = shownDialog();
    assert.ok(byKey(dialog, "alarm-code"), `${action}: the code field`);
    assert.equal(byKey(dialog, "alarm-code-needed").textContent, "The alarm now needs its code for this: the setting changed meanwhile.");
    assert.equal(plain(find(dialog, (node) => node.attributes.id === "alarm-dialog-title").textContent), action === "arm" ? "Arm House: Away" : "Disarm House");
    fake.refuse = null;
    typeAndSend(CODE);
    await settle();
    assert.deepEqual(fake.posts().at(-1).body, { ...sent, code: CODE }, `${action}: then with the code typed`);
    assert.ok(!JSON.stringify([state, ui]).includes(CODE));
    forgetKey();
  }
  // Pressed again after the read, the code is asked at once.
  await armingHome([free(READY, "none")]);
  press(alarmSection(), "alarm:80:arm");
  press(alarmSection(), "alarm:80:mode:0");
  assert.ok(byKey(shownDialog(), "alarm-code"));
  assert.equal(byKey(shownDialog(), "alarm-code-needed"), null, "no note when nothing changed");
  forgetKey();
});

test("Shabbat, the PIMA driver's mode, has a word in every language; what is sent is the driver's own", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const words = { en: "Shabbat", he: "שבת", es: "Shabat", it: "Shabbat" };
  try {
    for (const [language, word] of Object.entries(words)) {
      await setLanguage(language);
      const fake = await armingHome([free({ ...READY, modes: SHABBAT_MODES }, "arm")]);
      press(alarmSection(), "alarm:80:arm");
      assert.equal(plain(byKey(alarmSection(), "alarm:80:mode:2").textContent), word, language);
      press(alarmSection(), "alarm:80:mode:2");
      await settle();
      assert.deepEqual(fake.posts().at(-1).body, { mode: "Shabbat" }, language);
      forgetKey();
    }
  } finally {
    await setLanguage("en");
  }
  assert.equal(armModeLabel("SHABBAT"), "Shabbat");
});

test("without a code in Hebrew, Spanish and Italian: the confirmation, the note and the messages", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const words = {
    he: { title: "לנטרל את House?", disarm: "ניטרול", notDisarmed: "האזעקה לא נוטרלה. נסו שוב, או השתמשו בלוח המקשים של האזעקה." },
    es: { title: "¿Desarmar House?", disarm: "Desarmar", notDisarmed: "La alarma no se desarmó. Vuelve a intentarlo, o usa el teclado de la alarma." },
    it: { title: "Disinserire House?", disarm: "Disinserisci", notDisarmed: "L’allarme non si è disinserito. Riprova, oppure usa la tastiera dell’allarme." },
  };
  try {
    for (const [language, expected] of Object.entries(words)) {
      await setLanguage(language);
      await armingHome([free(ARMED, "arm_disarm")]);
      press(alarmSection(), "alarm:80:disarm");
      const dialog = shownDialog();
      assert.equal(plain(find(dialog, (node) => node.attributes.id === "alarm-dialog-title").textContent), expected.title, language);
      assert.equal(plain(byKey(dialog, "alarm-confirm-send").textContent), expected.disarm, language);
      assert.ok(!byKey(dialog, "alarm-confirm-help").textContent.includes("alarm.control"), language);
      find(dialog, (node) => node.tagName === "FORM").dispatch("submit");
      await settle();
      await advance(t, 20000);
      assert.equal(byKey(alarmSection(), "alarm:80:message").textContent, expected.notDisarmed, language);
      forgetKey();
    }
    // The partition's name stays in one piece inside the Hebrew question.
    await setLanguage("he");
    await armingHome([free(ARMED, "arm_disarm")]);
    press(alarmSection(), "alarm:80:disarm");
    assert.equal(find(shownDialog(), (node) => node.attributes.id === "alarm-dialog-title").textContent, `לנטרל את ${iso("House")}?`);
    press(shownDialog(), "alarm-code-cancel");
  } finally {
    await setLanguage("en");
    forgetKey();
  }
});
