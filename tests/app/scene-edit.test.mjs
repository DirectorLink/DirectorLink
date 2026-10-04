// Changing an action of a scene in place (app/js/views/scenes.js, 1.6.0): every action in the
// editor has an Edit button (and its text opens the same screen), #/scene/<id>/edit/<index> is Add
// an action filled in from it, Save puts the changed action where it was, Cancel changes nothing.
// Devices gone from the project are listed until unticked, actions split at 100 devices are changed
// together, a scene keeps at most 40 actions, and the editor focuses the action again afterwards.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

// Just enough of a browser for these modules: the elements the views build (with their listeners,
// to press them), storage, history and frames.
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
  // Runs the listeners of `type` with a minimal event.
  dispatch(type, init = {}) {
    const event = { type, currentTarget: this, target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...init };
    for (const listener of this.listeners[type] || []) listener(event);
    return event;
  }
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}
const backs = [];
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "", replace: (hash) => backs.push(`replace ${hash}`) };
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
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};
globalThis.fetch = async () => {
  throw new TypeError("offline in this test");
};
// Inside the app: leaving a screen goes back through the history.
globalThis.history = { state: { directorlinkInApp: true }, back: () => backs.push("back") };

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { MAX_STEPS } = await import("../../app/js/scenes.js");
const { resetSceneEditor, sceneEditorView, sceneReturnKey } = await import("../../app/js/views/scenes.js");

// ---- what a screen holds -----------------------------------------------------------------------

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function keysOf(nodes) {
  const keys = [];
  walk(nodes, (node) => node.dataset?.key && keys.push(node.dataset.key));
  return keys;
}
function find(nodes, test) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node instanceof FakeElement && test(node)) found = node;
  });
  return found;
}
const byKey = (nodes, key) => find(nodes, (node) => node.dataset.key === key);
const byClass = (nodes, name) => find(nodes, (node) => typeof node.className === "string" && node.className.split(/\s+/).includes(name));
const allByClass = (nodes, name) => {
  const list = [];
  walk(nodes, (node) => node instanceof FakeElement && typeof node.className === "string" && node.className.split(/\s+/).includes(name) && list.push(node));
  return list;
};
// Text as read, without the marks that keep names in their own direction.
const plain = (text) => text.replace(/[⁦-⁩]/g, "");
const textOf = (nodes) => plain([nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" | "));
const pressed = (nodes, key) => byKey(nodes, key)?.attributes["aria-pressed"] === "true";
const checked = (nodes, id) => "checked" in (byKey(nodes, `pick:${id}`)?.attributes || {});
const disabled = (nodes, key) => "disabled" in (byKey(nodes, key)?.attributes || {});
const press = (nodes, key) => {
  const element = byKey(nodes, key);
  assert.ok(element, `${key} is on the screen`);
  element.dispatch("click");
};
const untick = (nodes, id) => byKey(nodes, `pick:${id}`).dispatch("change", { target: { checked: false } });
const tick = (nodes, id) => byKey(nodes, `pick:${id}`).dispatch("change", { target: { checked: true } });
const summary = (nodes) => plain(byClass(nodes, "add-summary").textContent);
const title = (nodes) => plain(byClass(nodes, "page-title").textContent);

// ---- the home ----------------------------------------------------------------------------------

const KEY = "abcd1234";
const ROOMS = [
  { id: 11, name: "Living Room" },
  { id: 12, name: "Kitchen" },
  { id: 13, name: "Bedroom" },
];
const at = (id) => ({ id, name: ROOMS.find((room) => room.id === id).name });
const LIGHTS = [
  { id: 101, name: "Ceiling", room: at(11), dimmable: true, on: false },
  { id: 102, name: "Reading lamp", room: at(11), dimmable: true, on: true, brightness: 60 },
  { id: 103, name: "Wall light", room: at(11), dimmable: false, on: false },
  { id: 104, name: "Counter", room: at(12), dimmable: true, on: false },
  { id: 105, name: "Pendant", room: at(12), dimmable: false, on: false },
];
const THERMOSTATS = [
  { id: 201, name: "Living AC", room: at(11), setpoints: "dual", mode: "cool", modes: ["off", "heat", "cool", "auto"], setpoint_deadband: 2, heat_setpoint: 20, cool_setpoint: 25, target_temperature_min: 16, target_temperature_max: 30, fan_speeds: ["auto", "low", "high"] },
  { id: 202, name: "Bedroom AC", room: at(13), setpoints: "single", mode: "off", modes: ["off", "heat", "cool"], target_temperature: 24, target_temperature_min: 16, target_temperature_max: 30, fan_speeds: ["low", "medium", "high"] },
];
const FANS = [
  { id: 301, name: "Ceiling fan", room: at(13), on: false, speeds: [1, 2, 3] },
  { id: 302, name: "Floor fan", room: at(13), on: false, speeds: [1, 2, 3] },
];
const BLINDS = [
  { id: 401, name: "Big window", room: at(11), position: 100 },
  { id: 402, name: "Side window", room: at(11), position: 0, capabilities: { position: false } },
];
const RELAYS = [
  { id: 501, name: "Back door", room: at(12) },
  { id: 502, name: "Side gate", room: at(12) },
];
// 110 more lights in the Bedroom, for actions of more than 100 devices.
const MANY = Array.from({ length: 110 }, (_, index) => ({ id: 1000 + index, name: `Strip ${index + 1}`, room: at(13), dimmable: true, on: false }));

// The scene: one action of each kind (in the Living Room unless said).
const STEPS = [
  { type: "lights", room_id: 11, device_ids: [101, 102], set: { brightness: 40 } },
  { type: "climate", room_id: 11, device_ids: null, set: { mode: "auto", heat_setpoint: 20, cool_setpoint: 25, fan_speed: "low" } },
  { type: "climate", room_id: 13, device_ids: null, set: { mode: "cool", target_temperature: 23 } },
  { type: "fans", room_id: 13, device_ids: [301], set: { speed: 3 } },
  { type: "blinds", room_id: 11, device_ids: null, set: { position: 30 } },
  { type: "relays", room_id: 12, device_ids: [501], set: { action: "pulse" } },
  { type: "music", room_id: null, device_ids: null, set: { action: "stop" } },
  { type: "lights", room_id: null, device_ids: null, set: { on: false } },
];

let navigated = [];
const actions = { navigate: (hash) => navigated.push(hash) };

// Connected as an admin, the editor of a scene with `steps` opened afresh.
function home(steps = STEPS, { lights = LIGHTS } = {}) {
  Object.assign(state, {
    host: "192.0.2.10",
    apiKey: "ak_test",
    status: "connected",
    loaded: true,
    online: true,
    role: "admin",
    rooms: structuredClone(ROOMS),
    system: { bridge: { version: "1.5.0" }, features: { sonos: true } },
    lights: structuredClone(lights),
    thermostats: structuredClone(THERMOSTATS),
    fans: structuredClone(FANS),
    blinds: structuredClone(BLINDS),
    relays: structuredClone(RELAYS),
    music: { enabled: true, status: "ok", items: [{ id: "RINCON_KITCHEN", name: "Kitchen", room_id: 12 }] },
    scenes: [{ id: KEY, name: "Evening", icon: "moon", show_on_home: false, version: 3, steps: structuredClone(steps) }],
    scenesUnsupported: false,
  });
  resetSceneEditor();
  navigated = [];
  backs.length = 0;
  return editor();
}
const editor = () => sceneEditorView(KEY, false, actions);
const edit = (index) => sceneEditorView(KEY, false, actions, index);
const draft = () => ui.sceneEditor;

// ---- the editor --------------------------------------------------------------------------------

test("every action has an Edit button named after it, and tapping its text opens the same screen", () => {
  const nodes = home();
  const keys = keysOf(nodes);
  for (let index = 0; index < STEPS.length; index += 1) {
    const tools = keys.filter((key) => key.endsWith(`:${index}`) && key.startsWith("step-"));
    assert.deepEqual(tools, [`step-up:${index}`, `step-down:${index}`, `step-edit:${index}`, `step-remove:${index}`], "up, down, edit, remove");
  }
  const button = byKey(nodes, "step-edit:0");
  assert.equal(button.tagName, "BUTTON");
  assert.equal(button.attributes["aria-label"], "Edit 2 lights", "named like Move and Remove");
  assert.equal(byKey(nodes, "step-edit:3").attributes["aria-label"], "Edit Ceiling fan");
  press(nodes, "step-edit:3");
  assert.deepEqual(navigated, [`#/scene/${KEY}/edit/3`]);
  const rows = allByClass(nodes, "step-row");
  byClass(rows[5], "step-text").dispatch("click");
  byClass(rows[6], "step-action").dispatch("click");
  assert.deepEqual(navigated, [`#/scene/${KEY}/edit/3`, `#/scene/${KEY}/edit/5`, `#/scene/${KEY}/edit/6`]);
  assert.equal(byClass(rows[0], "step-text").attributes.tabindex, undefined, "the text is not a second stop for keyboards");
});

// ---- filled in from the action -----------------------------------------------------------------

test("the screen is filled in from the action: kind, place, devices and setting", () => {
  home();
  let nodes = edit(0);
  assert.equal(title(nodes), "Edit action");
  assert.ok(pressed(nodes, "add-room:11") && !pressed(nodes, "add-room:home"), "Living Room");
  assert.ok(pressed(nodes, "add-kind:lights"));
  assert.ok(checked(nodes, 101) && checked(nodes, 102) && !checked(nodes, 103), "the two lights it names, ticked");
  assert.match(textOf(nodes), /2 of 3 picked/);
  assert.ok(pressed(nodes, "add-light:dim"));
  assert.equal(byKey(nodes, "add-brightness").attributes.value, "40");
  assert.equal(summary(nodes), "Changes it to: 2 lights (Living Room): 40%");
  assert.equal(plain(byKey(nodes, "add-confirm").textContent), "Save action");

  nodes = edit(1);
  assert.ok(pressed(nodes, "add-kind:climate") && pressed(nodes, "add-room:11"));
  assert.equal(byKey(nodes, "add-choose")?.tagName, undefined, "one AC there: no choosing");
  assert.ok(pressed(nodes, "add-mode:auto"));
  assert.deepEqual([draft().adding.heat, draft().adding.cool], [20, 25]);
  assert.match(textOf(byClass(nodes, "stepper-pair")), /20.*25/s);
  assert.ok(pressed(nodes, "add-fan:low"));
  assert.match(summary(nodes), /Living Room\): Auto, 20°.25°, fan Low$/);

  nodes = edit(2);
  assert.ok(pressed(nodes, "add-room:13") && pressed(nodes, "add-mode:cool"));
  assert.equal(plain(byClass(nodes, "stepper-number").textContent), "23°");
  assert.ok(pressed(nodes, "add-fan:keep"));

  nodes = edit(3);
  assert.ok(pressed(nodes, "add-kind:fans") && pressed(nodes, "add-fan-do:speed") && pressed(nodes, "add-fan-speed:3"));
  assert.ok(checked(nodes, 301) && !checked(nodes, 302));

  nodes = edit(4);
  assert.ok(pressed(nodes, "add-kind:blinds") && pressed(nodes, "add-blind:set"));
  assert.equal(byKey(nodes, "add-position").attributes.value, "30");

  nodes = edit(5);
  assert.ok(pressed(nodes, "add-room:12") && pressed(nodes, "add-kind:relays"));
  assert.ok(checked(nodes, 501) && !checked(nodes, 502));
  assert.match(textOf(nodes), /short press/);
  // 1.8.0 (ADR-054): a person's run opens them, DirectorLink's own runs never.
  assert.match(textOf(nodes), /It opens them when a person runs the scene .*never from a schedule or a link/);

  nodes = edit(6);
  assert.ok(pressed(nodes, "add-room:home") && pressed(nodes, "add-kind:music") && pressed(nodes, "add-music:stop"));

  nodes = edit(7);
  assert.ok(pressed(nodes, "add-room:home") && pressed(nodes, "add-kind:lights") && pressed(nodes, "add-light:off"));
  assert.ok(byKey(nodes, "add-choose"), "all lights of the home, with Choose");
  assert.equal(summary(nodes), "Changes it to: All lights (Whole home): Off");
});

test("an action that is not in the scene says so", () => {
  home();
  const nodes = edit(8);
  assert.match(textOf(nodes), /This action is no longer in the scene/);
  assert.equal(byKey(nodes, "add-confirm"), null);
});

// ---- saving and cancelling ---------------------------------------------------------------------

test("Save puts the changed action in its place and the editor focuses it; the scene is saved as before", () => {
  home();
  let nodes = edit(0);
  untick(nodes, 102);
  nodes = edit(0);
  press(nodes, "add-light:on");
  nodes = edit(0);
  assert.equal(summary(nodes), "Changes it to: Ceiling (Living Room): On");
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0], { type: "lights", room_id: 11, device_ids: [101], set: { on: true } });
  assert.deepEqual(draft().steps.slice(1), STEPS.slice(1), "the other actions as they were, in order");
  assert.ok(draft().dirty && draft().stepsChanged);
  assert.deepEqual(backs, ["back"], "back to the editor");
  assert.equal(sceneReturnKey({ name: "scene", id: KEY, adding: false, editing: 0 }, { name: "scene", id: KEY, adding: false, editing: null }), "step-edit:0");
  assert.equal(draft().returnFocus, null, "only once");

  // Another place and kind start afresh; back at its own, with what it named.
  nodes = edit(3);
  press(nodes, "add-room:home");
  nodes = edit(3);
  assert.ok(!byKey(nodes, "pick:301"), "the whole home: all fans");
  press(nodes, "add-room:13");
  nodes = edit(3);
  assert.ok(checked(nodes, 301) && !checked(nodes, 302));
  press(nodes, "add-use-all");
  nodes = edit(3);
  press(nodes, "add-choose");
  nodes = edit(3);
  assert.ok(checked(nodes, 301) && !checked(nodes, 302), "Choose again: what it named");
  press(nodes, "add-fan-speed:1");
  nodes = edit(3);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[3], { type: "fans", room_id: 13, device_ids: [301], set: { speed: 1 } });
  assert.equal(draft().steps.length, STEPS.length);
});

test("Cancel and Back change nothing, and the editor focuses the action again", () => {
  home();
  let nodes = edit(3);
  press(nodes, "add-fan-speed:1");
  untick(nodes, 301);
  nodes = edit(3);
  assert.ok(disabled(nodes, "add-confirm"), "nothing picked");
  press(nodes, "add-cancel");
  assert.deepEqual(draft().steps, STEPS);
  assert.equal(draft().dirty, false);
  assert.equal(sceneReturnKey({ name: "scene", id: KEY, adding: false, editing: 3 }, { name: "scene", id: KEY, adding: false, editing: null }), "step-edit:3");
  editor();
  nodes = edit(3);
  assert.ok(pressed(nodes, "add-fan-speed:3") && checked(nodes, 301), "opened again: as saved");

  // Saved without a change: the scene has nothing to save.
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps, STEPS);
  assert.equal(draft().dirty, false);
  assert.equal(sceneReturnKey({ name: "scene", id: KEY, adding: false, editing: 3 }, { name: "scene", id: KEY, adding: false, editing: null }), "step-edit:3");

  // Adding goes back to Add an action; other screens to their title.
  assert.equal(sceneReturnKey({ name: "scene", id: KEY, adding: true, editing: null }, { name: "scene", id: KEY, adding: false, editing: null }), "scene-add");
  assert.equal(sceneReturnKey({ name: "scenes" }, { name: "scene", id: KEY, adding: false, editing: null }), null);
  assert.equal(sceneReturnKey({ name: "scene", id: KEY, adding: false, editing: null }, { name: "scene", id: KEY, adding: false, editing: 2 }), null);
});

test("a setting stays as it was saved until one of its choices is changed", () => {
  // Copied from the house: an AC with no mode the app offers, and a thermostat's both setpoints.
  home([
    { type: "climate", room_id: null, device_ids: [201, 202], set: { target_temperature: 22 } },
    { type: "climate", room_id: 11, device_ids: [201], set: { mode: "auto", heat_setpoint: 21, cool_setpoint: 22 } },
  ]);
  let nodes = edit(0);
  untick(nodes, 201);
  nodes = edit(0);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0], { type: "climate", room_id: null, device_ids: [202], set: { target_temperature: 22 } }, "devices changed, setting kept");
  nodes = edit(0);
  press(nodes, "add-mode:heat");
  nodes = edit(0);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0].set, { mode: "heat", target_temperature: 22 }, "a mode picked: the setting the choices show");

  nodes = edit(1);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[1].set, { mode: "auto", heat_setpoint: 21, cool_setpoint: 22 }, "setpoints closer than this AC's 2° kept as saved");
  nodes = edit(1);
  press(nodes, "add-cool-up");
  nodes = edit(1);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[1].set, { mode: "auto", heat_setpoint: 21, cool_setpoint: 24 }, "changed: kept apart");
});

// ---- devices no longer in the project ----------------------------------------------------------

test("devices gone from the project are listed, ticked, and leave the action only when unticked", () => {
  home([
    { type: "lights", room_id: 11, device_ids: [101, 999], set: { on: true } },
    { type: "lights", room_id: 12, device_ids: [101, 104], set: { on: false } },
  ]);
  let nodes = edit(0);
  const gone = byKey(nodes, "pick:999");
  assert.ok(gone && checked(nodes, 999));
  const item = find(nodes, (node) => node.tagName === "LI" && node.children.includes(gone));
  assert.match(item.className, /is-gone/);
  assert.equal(textOf(item), "Removed deviceNo longer in the project · ID 999");
  assert.match(textOf(nodes), /2 of 4 picked/);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0].device_ids, [101, 999], "kept: not dropped silently");
  nodes = edit(0);
  untick(nodes, 999);
  nodes = edit(0);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0], { type: "lights", room_id: 11, device_ids: [101], set: { on: true } });

  // A light moved to another room in Composer: listed with its room, and kept.
  const before = draft().steps;
  nodes = edit(1);
  assert.ok(checked(nodes, 101) && checked(nodes, 104) && !checked(nodes, 105));
  const moved = find(nodes, (node) => node.tagName === "LI" && node.children.includes(byKey(nodes, "pick:101")));
  assert.match(textOf(moved), /Living Room/);
  press(nodes, "add-confirm");
  assert.equal(draft().steps, before, "nothing changed");
  assert.deepEqual(draft().steps[1].device_ids, [101, 104]);
});

test("an action whose devices are all gone can still be changed or removed", () => {
  home([
    { type: "fans", room_id: 11, device_ids: [998, 999], set: { speed: 2 } },
    { type: "lights", room_id: 77, device_ids: null, set: { on: false } },
    { type: "lights", room_id: 11, device_ids: null, set: { on: true } },
  ]);
  let nodes = edit(0);
  assert.ok(pressed(nodes, "add-kind:fans"), "its kind, though the Living Room has no fans now");
  assert.ok(checked(nodes, 998) && checked(nodes, 999));
  assert.match(textOf(nodes), /This action has no devices now/);
  assert.equal(byKey(nodes, "add-use-all"), null, "nothing here to use all of");
  assert.match(summary(nodes), /2 fans \(Living Room\)/);
  assert.ok(!disabled(nodes, "add-confirm"));
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0], { type: "fans", room_id: 11, device_ids: [998, 999], set: { speed: 2 } });
  nodes = edit(0);
  untick(nodes, 998);
  untick(nodes, 999);
  nodes = edit(0);
  assert.ok(disabled(nodes, "add-confirm"));
  assert.equal(summary(nodes), "Pick at least one device");

  // A room gone from the project: shown, and another place can be chosen.
  nodes = edit(1);
  assert.ok(pressed(nodes, "add-room:77"));
  assert.equal(plain(byKey(nodes, "add-room:77").textContent), "A removed room");
  assert.match(textOf(nodes), /This room is no longer in the project/);
  assert.ok(pressed(nodes, "add-kind:lights"));
  assert.equal(summary(nodes), "Changes it to: All lights (A removed room): Off");
  press(nodes, "add-room:12");
  nodes = edit(1);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[1], { type: "lights", room_id: 12, device_ids: null, set: { on: false } });

  // Removing it from the editor.
  nodes = editor();
  press(nodes, "step-remove:0");
  assert.deepEqual(draft().steps.map((step) => step.type), ["lights", "lights"]);
});

// ---- actions split at 100 devices ----------------------------------------------------------------

const ids = (from, count) => Array.from({ length: count }, (_, index) => from + index);

test("actions split from one choice of more than 100 devices are changed together", () => {
  const climate = { type: "climate", room_id: 13, device_ids: null, set: { mode: "off" } };
  home(
    [
      climate,
      { type: "lights", room_id: 13, device_ids: ids(1000, 100), set: { brightness: 30 } },
      { type: "lights", room_id: 13, device_ids: ids(1100, 5), set: { brightness: 30 } },
      { type: "lights", room_id: 13, device_ids: [1105], set: { brightness: 30 } },
    ],
    { lights: [...LIGHTS, ...MANY] }
  );
  let nodes = edit(2);
  assert.match(textOf(nodes), /The scene keeps this as 2 actions in a row/);
  assert.match(textOf(nodes), /105 of 110 picked/);
  assert.equal(draft().adding.editing.start, 1);
  for (let index = 0; index < 10; index += 1) untick(nodes, 1000 + index);
  nodes = edit(2);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps.map((step) => step.device_ids?.length ?? null), [null, 95, 1], "one action in place of both");
  assert.deepEqual(draft().steps[1].device_ids, [...ids(1010, 90), ...ids(1100, 5)]);
  assert.equal(sceneReturnKey({ name: "scene", id: KEY, adding: false, editing: 2 }, { name: "scene", id: KEY, adding: false, editing: null }), "step-edit:1", "the first of them");

  // More than 100 again: two in its place, in order.
  nodes = edit(1);
  assert.match(textOf(nodes), /95 of 110 picked/);
  for (let index = 0; index < 10; index += 1) tick(nodes, 1000 + index);
  tick(nodes, 1106);
  nodes = edit(1);
  assert.match(textOf(nodes), /Kept as 2 actions/);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps.map((step) => step.device_ids?.length ?? null), [null, 100, 6, 1]);
  assert.deepEqual(draft().steps[3], { type: "lights", room_id: 13, device_ids: [1105], set: { brightness: 30 } }, "the next action as it was");

  // An action of fewer than 100 devices is not part of the one before it.
  edit(3);
  assert.equal(draft().adding.editing.count, 1);
});

test("the parts are found whatever order the controller sends a setting's fields in", () => {
  const units = Array.from({ length: 101 }, (_, index) => ({ ...THERMOSTATS[1], id: 2000 + index, name: `Unit ${index + 1}` }));
  home([
    { type: "climate", room_id: 13, device_ids: ids(2000, 100), set: { mode: "cool", target_temperature: 22 } },
    { type: "climate", room_id: 13, device_ids: [2100], set: { target_temperature: 22, mode: "cool" } },
  ]);
  state.thermostats = [...THERMOSTATS, ...units];
  const nodes = edit(0);
  assert.deepEqual([draft().adding.editing.start, draft().adding.editing.count], [0, 2]);
  assert.match(textOf(nodes), /101 of 102 picked/);
  press(nodes, "add-confirm");
  assert.equal(draft().dirty, false, "the same two actions");
});

test("a changed action keeps the scene within 40 actions", () => {
  const filler = { type: "lights", room_id: 11, device_ids: null, set: { on: true } };
  home([{ type: "lights", room_id: 13, device_ids: ids(1000, 100), set: { on: false } }, ...Array.from({ length: MAX_STEPS - 1 }, () => structuredClone(filler))], { lights: [...LIGHTS, ...MANY] });
  assert.ok(disabled(editor(), "scene-add"), "a full scene");
  let nodes = edit(0);
  tick(nodes, 1100);
  nodes = edit(0);
  assert.ok(disabled(nodes, "add-confirm"), "101 devices are 2 actions: 41");
  assert.equal(summary(nodes), "A scene has at most 40 actions.");
  untick(nodes, 1000);
  nodes = edit(0);
  assert.ok(!disabled(nodes, "add-confirm"));
  press(nodes, "add-confirm");
  assert.equal(draft().steps.length, MAX_STEPS);
  assert.deepEqual(draft().steps[0].device_ids, [...ids(1001, 99), 1100]);

  // A run of two stays within 40 as two.
  home([{ type: "lights", room_id: 13, device_ids: ids(1000, 100), set: { on: false } }, { type: "lights", room_id: 13, device_ids: ids(1100, 5), set: { on: false } }, ...Array.from({ length: MAX_STEPS - 2 }, () => structuredClone(filler))], { lights: [...LIGHTS, ...MANY] });
  nodes = edit(1);
  press(nodes, "add-light:on");
  nodes = edit(1);
  assert.ok(!disabled(nodes, "add-confirm"));
  press(nodes, "add-confirm");
  assert.equal(draft().steps.length, MAX_STEPS);
  assert.deepEqual([draft().steps[0].set, draft().steps[1].set, draft().steps[0].device_ids.length, draft().steps[1].device_ids.length], [{ on: true }, { on: true }, 100, 5]);
});

// ---- naming every device of its kind -------------------------------------------------------------

const add = () => sceneEditorView(KEY, true, actions);

// Opens action `index`, checks it names its devices, and saves it without a change.
function saveUnchanged(index, steps) {
  const nodes = edit(index);
  assert.doesNotMatch(summary(nodes), /: All /, "named, not all");
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps, steps);
  assert.equal(draft().dirty, false);
}

test("a door action naming the only door there is, saved unchanged, still opens only that door", () => {
  // The other door was removed in Composer since.
  const door = [{ type: "relays", room_id: null, device_ids: [501], set: { action: "pulse" } }];
  home(door);
  state.relays = [structuredClone(RELAYS[0])];
  saveUnchanged(0, door);
});

test("all the shades closed, copied from the house, stay these shades when saved unchanged or changed", () => {
  const shades = [{ type: "blinds", room_id: null, device_ids: [401, 402], set: { position: 0 } }];
  home(shades);
  saveUnchanged(0, shades);
  // Another setting: the same shades, still by name.
  let nodes = edit(0);
  press(nodes, "add-blind:open");
  nodes = edit(0);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0], { type: "blinds", room_id: null, device_ids: [401, 402], set: { position: 100 } });
});

test("22 ACs off at night, copied from the house, stay as they were when saved unchanged", () => {
  const night = [{ type: "climate", room_id: null, device_ids: ids(2000, 22), set: { mode: "off" } }];
  home(night);
  state.thermostats = Array.from({ length: 22 }, (_, index) => ({ ...THERMOSTATS[1], id: 2000 + index, name: `AC ${index + 1}` }));
  assert.match(textOf(edit(0)), /22 of 22 picked/);
  saveUnchanged(0, night);
});

test("every light of a room by name: kept while picked as it was; Use all is all of them", () => {
  const room = [{ type: "lights", room_id: 11, device_ids: [101, 102, 103], set: { on: false } }];
  home(room);
  saveUnchanged(0, room);
  // Unticked and ticked again: as it was.
  let nodes = edit(0);
  untick(nodes, 103);
  tick(nodes, 103);
  nodes = edit(0);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps, room);
  // "Use all" is the choice of all of them, those added later too.
  nodes = edit(0);
  press(nodes, "add-use-all");
  nodes = edit(0);
  assert.equal(summary(nodes), "Changes it to: All lights (Living Room): Off");
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0], { type: "lights", room_id: 11, device_ids: null, set: { on: false } });
});

test("a split run naming every light, saved unchanged, stays exactly as it was", () => {
  // 130 lights in the home, copied all off: kept as 100 + 30.
  const more = Array.from({ length: 15 }, (_, index) => ({ id: 3000 + index, name: `Garden ${index + 1}`, room: at(12), dimmable: false, on: false }));
  const lights = [...LIGHTS, ...MANY, ...more];
  const all = lights.map((light) => light.id);
  const run = [
    { type: "lights", room_id: null, device_ids: all.slice(0, 100), set: { on: false } },
    { type: "lights", room_id: null, device_ids: all.slice(100), set: { on: false } },
  ];
  home(run, { lights });
  for (const index of [0, 1]) {
    const nodes = edit(index);
    assert.match(textOf(nodes), /130 of 130 picked/);
    assert.match(textOf(nodes), /The scene keeps this as 2 actions in a row/);
    press(nodes, "add-confirm");
    assert.deepEqual(draft().steps, run);
    assert.equal(draft().dirty, false);
  }
  // Another setting: still the same 100 + 30.
  let nodes = edit(1);
  press(nodes, "add-light:on");
  nodes = edit(1);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps.map((step) => [step.device_ids, step.set]), [
    [all.slice(0, 100), { on: true }],
    [all.slice(100), { on: true }],
  ]);
  // One unticked: 100 + 29.
  nodes = edit(0);
  untick(nodes, 3014);
  nodes = edit(0);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps.map((step) => step.device_ids.length), [100, 29]);
});

test("doors and gates open only the ones picked, unless all of them is the choice", () => {
  home();
  // The Kitchen's other door ticked: both, by name.
  let nodes = edit(5);
  tick(nodes, 502);
  nodes = edit(5);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[5], { type: "relays", room_id: 12, device_ids: [501, 502], set: { action: "pulse" } });
  // Added with Choose, every door ticked: by name too.
  nodes = add();
  press(nodes, "add-room:12");
  nodes = add();
  press(nodes, "add-kind:relays");
  nodes = add();
  press(nodes, "add-choose");
  nodes = add();
  tick(nodes, 501);
  tick(nodes, 502);
  nodes = add();
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps.at(-1), { type: "relays", room_id: 12, device_ids: [501, 502], set: { action: "pulse" } });
  // "Use all": all of them.
  nodes = edit(5);
  press(nodes, "add-use-all");
  nodes = edit(5);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[5], { type: "relays", room_id: 12, device_ids: null, set: { action: "pulse" } });
});

// ---- Hebrew ------------------------------------------------------------------------------------

test("in Hebrew", async () => {
  await setLanguage("he");
  try {
    home([{ type: "lights", room_id: 11, device_ids: [101, 999], set: { on: true } }]);
    const row = editor();
    assert.equal(byKey(row, "step-edit:0").attributes["aria-label"], "עריכת 2 אורות");
    const nodes = edit(0);
    assert.equal(title(nodes), "עריכת פעולה");
    assert.equal(plain(byKey(nodes, "add-confirm").textContent), "שמירת הפעולה");
    assert.match(textOf(nodes), /מכשיר שהוסר/);
    assert.match(summary(nodes), /^הפעולה תהיה: /);
  } finally {
    await setLanguage("en");
  }
});
