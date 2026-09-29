// The alarm's status in the app (app/js/alarm.js, app/js/views/alarm.js, ADR-038): read-only, on
// Home and in Settings → Controller for members and admins once an installer turned on Alarm Status
// (GET /v1/system features.alarm_status), in natural English and Hebrew. Otherwise nothing is asked
// and nothing is shown, and nothing but GET /v1/alarm is ever sent.
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

// Just enough of a browser for these modules: the elements the views build, storage and timers.
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.className = "";
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener() {}
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", hash: "" };
globalThis.document = {
  hidden: false,
  documentElement: {},
  addEventListener() {},
  querySelector: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};

const { state } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { forgetKey } = await import("../../app/js/session.js");
const { alarmDetails, alarmStateText, alarmSummary, loadAlarm, startAlarm } = await import("../../app/js/alarm.js");
const { alarmFact, alarmSection } = await import("../../app/js/views/alarm.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

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

test("the app only ever reads the alarm, and forgets it with the key", async () => {
  home();
  const sent = controller(ON);
  startAlarm();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(alarmSection());
  assert.deepEqual([...new Set(sent.filter((line) => line.includes("/v1/alarm")))], ["GET /v1/alarm"]);
  forgetKey();
  assert.equal(state.alarm, null, "nothing of it stays in this browser");
  assert.equal(alarmSection(), null);
  for (const file of ["app/js/alarm.js", "app/js/views/alarm.js"]) {
    const source = readFileSync(new URL(`../../${file}`, import.meta.url), "utf8");
    assert.doesNotMatch(source, /method:/, `${file} sends nothing but GET`);
    assert.doesNotMatch(source, /onclick|button/, `${file} has nothing to press`);
  }
});
