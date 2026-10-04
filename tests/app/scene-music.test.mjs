// Music actions in the scene editor (app/js/views/scenes.js, 1.8.0, ADR-057): with a 1.8.0 driver
// a music action also resumes, sets a volume, or plays a Sonos favorite in a room (picked from the
// household's favorites), at a volume if asked, with other rooms grouped with it; with an older
// driver only Pause and Stop. Changing such an action keeps it exactly as saved until a choice
// changes; the scene list says what it does; a run says why the music was skipped. English and
// Hebrew.
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
  dispatch(type, init = {}) {
    const event = { type, currentTarget: this, target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...init };
    for (const listener of this.listeners[type] || []) listener(event);
    return event;
  }
  focus() {}
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
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Node", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
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
globalThis.history = { state: { directorlinkInApp: true }, back: () => backs.push("back") };

// The controller: the household's Sonos favorites; what was asked is kept.
const asked = [];
globalThis.fetch = async (url) => {
  const address = new URL(url);
  asked.push(address.pathname);
  const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  if (address.pathname === "/v1/sealed") return reply(404, { code: "NOT_FOUND" });
  if (address.pathname.endsWith("/favorites")) {
    return reply(200, {
      items: [
        { id: "10", title: "Example FM 99", description: "TuneIn Station", playable: true },
        { id: "11", title: "Morning Mix", description: "Spotify Playlist", playable: true },
        { id: "1", title: "Discover Sonos Radio", description: "Sonos Radio", playable: false },
      ],
    });
  }
  return reply(404, { code: "NOT_FOUND" });
};

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const scenes = await import("../../app/js/scenes.js");
const { resetSceneEditor, sceneEditorView } = await import("../../app/js/views/scenes.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
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
const plain = (text) => text.replace(/[⁦-⁩]/g, "");
const textOf = (nodes) => plain([nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" | "));
const pressed = (nodes, key) => byKey(nodes, key)?.attributes["aria-pressed"] === "true";
const press = (nodes, key) => {
  const element = byKey(nodes, key);
  assert.ok(element, `${key} is on the screen`);
  element.dispatch("click");
};
const summary = (nodes) => plain(byClass(nodes, "add-summary").textContent);
const settle = async () => {
  for (let i = 0; i < 20; i++) await new Promise((resolve) => setImmediate(resolve));
};

const KEY = "abcd1234";
const ROOMS = [
  { id: 11, name: "Living Room" },
  { id: 12, name: "Kitchen" },
  { id: 13, name: "Bedroom" },
];
const KITCHEN = "RINCON_000E58A0000101400";
const LIVING = "RINCON_000E58A0000201400";
const sonosRoom = (id, name, roomId) => ({ id, name, room_id: roomId, reachable: true, state: "paused", group: { id, coordinator: true, rooms: [{ id, name }] } });
const STATION = { id: "10", title: "Example FM 99", uri: "x-sonosapi-stream:s0000?sid=254&flags=8224&sn=0", meta: "<DIDL-Lite/>" };

let navigated = [];
const actions = { navigate: (hash) => navigated.push(hash) };

// Connected as an admin to a driver of `version` (1.8.0 groups and has the new music actions), the
// editor of a scene with `steps` opened afresh.
function home(steps = [], { groups = true } = {}) {
  Object.assign(state, {
    host: "192.0.2.10",
    apiKey: "ak_test",
    transport: "lan",
    status: "connected",
    loaded: true,
    online: true,
    role: "admin",
    rooms: structuredClone(ROOMS),
    system: { bridge: { version: groups ? "1.8.0" : "1.7.0" }, features: groups ? { sonos: true, sonos_groups: true } : { sonos: true } },
    lights: [],
    thermostats: [],
    fans: [],
    blinds: [],
    relays: [],
    refrigerators: [],
    music: { enabled: true, status: "ok", items: [sonosRoom(KITCHEN, "Kitchen", 12), sonosRoom(LIVING, "Living Room", 11)] },
    scenes: [{ id: KEY, name: "Morning", icon: "sun", show_on_home: false, version: 3, steps: structuredClone(steps) }],
    scenesUnsupported: false,
  });
  resetSceneEditor();
  navigated = [];
  backs.length = 0;
}
const add = () => sceneEditorView(KEY, true, actions);
const edit = (index) => sceneEditorView(KEY, false, actions, index);
const draft = () => ui.sceneEditor;

test("a driver before 1.8.0: music pauses or stops, nothing else", () => {
  home([], { groups: false });
  let nodes = add();
  press(nodes, "add-room:12");
  nodes = add();
  press(nodes, "add-kind:music");
  nodes = add();
  assert.ok(byKey(nodes, "add-music:pause") && byKey(nodes, "add-music:stop"));
  for (const action of ["resume", "volume", "play_favorite"]) assert.equal(byKey(nodes, `add-music:${action}`), null, action);
});

test("Resume and Volume, in a room or the whole home", () => {
  home();
  let nodes = add();
  press(nodes, "add-kind:music");
  nodes = add();
  assert.ok(pressed(nodes, "add-room:home") && pressed(nodes, "add-music:pause"));
  press(nodes, "add-music:resume");
  nodes = add();
  assert.equal(summary(nodes), "Adds: Music (Whole home): Resume");
  assert.match(textOf(nodes), /paused or stopped plays again/);
  press(nodes, "add-music:volume");
  nodes = add();
  const slider = byKey(nodes, "add-music-volume");
  assert.equal(slider.attributes.value, "30");
  slider.value = "18";
  slider.dispatch("change");
  nodes = add();
  assert.equal(summary(nodes), "Adds: Music (Whole home): Volume 18%");
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps, [{ type: "music", room_id: null, device_ids: null, set: { action: "volume", volume: 18 } }]);
});

test("Play a favorite: in a room, from the Sonos favorites, at a volume if asked, with other rooms", async () => {
  home();
  asked.length = 0;
  let nodes = add();
  press(nodes, "add-kind:music");
  nodes = add();
  press(nodes, "add-music:play_favorite");
  nodes = add();
  assert.match(textOf(nodes), /Pick a room above: a favorite plays in a room/);
  assert.ok("disabled" in byKey(nodes, "add-confirm").attributes);
  press(nodes, "add-room:12");
  nodes = add();
  assert.match(textOf(nodes), /Loading/);
  await settle();
  assert.deepEqual(asked.filter((path) => path.endsWith("/favorites")), [`/v1/music/${KITCHEN}/favorites`], "read once");
  nodes = add();
  assert.ok(byKey(nodes, "add-favorite:10") && byKey(nodes, "add-favorite:11"));
  assert.equal(byKey(nodes, "add-favorite:1"), null, "only the Sonos app starts that one");
  assert.equal(summary(nodes), "Pick a favorite");
  press(nodes, "add-favorite:10");
  nodes = add();
  assert.equal(summary(nodes), "Adds: Music (Kitchen): Play Example FM 99");
  byKey(nodes, "add-favorite-volume").dispatch("change", { target: { checked: true } });
  nodes = add();
  const slider = byKey(nodes, "add-music-volume");
  slider.value = "25";
  slider.dispatch("change");
  nodes = add();
  assert.equal(byKey(nodes, "add-with-room:12"), null, "not its own room");
  assert.equal(byKey(nodes, "add-with-room:13"), null, "the bedroom has no Sonos room");
  press(nodes, "add-with-room:11");
  nodes = add();
  assert.equal(summary(nodes), "Adds: Music (Kitchen): Play Example FM 99 at 25% · with Living Room");
  assert.match(textOf(nodes), /grouped first, as in the Sonos app/);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps, [
    { type: "music", room_id: 12, device_ids: null, set: { action: "play_favorite", favorite: { id: "10", title: "Example FM 99" }, volume: 25, with_room_ids: [11] } },
  ]);
  assert.equal(asked.filter((path) => path.endsWith("/favorites")).length, 1, "not read again at each redraw");
});

test("changing a favorite action: filled in, kept exactly as saved until a choice changes", async () => {
  const step = { type: "music", room_id: 12, device_ids: null, set: { action: "play_favorite", favorite: STATION, volume: 35, with_room_ids: [11] } };
  home([step]);
  await settle();
  let nodes = edit(0);
  await settle();
  nodes = edit(0);
  assert.ok(pressed(nodes, "add-room:12") && pressed(nodes, "add-kind:music") && pressed(nodes, "add-music:play_favorite"));
  assert.ok(pressed(nodes, "add-favorite:10"));
  assert.ok("checked" in byKey(nodes, "add-favorite-volume").attributes);
  assert.equal(byKey(nodes, "add-music-volume").attributes.value, "35");
  assert.ok(pressed(nodes, "add-with-room:11"));
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps, [step], "unchanged: with what starts it, as the controller keeps it");
  assert.equal(draft().stepsChanged, false);
  // Another favorite: only its id and name go (the controller keeps what starts it).
  nodes = edit(0);
  press(nodes, "add-favorite:11");
  nodes = edit(0);
  press(nodes, "add-confirm");
  assert.deepEqual(draft().steps[0].set, { action: "play_favorite", favorite: { id: "11", title: "Morning Mix" }, volume: 35, with_room_ids: [11] });
});

test("a favorite no longer in Sonos favorites stays listed, said so", async () => {
  home([{ type: "music", room_id: 12, device_ids: null, set: { action: "play_favorite", favorite: { id: "77", title: "Old FM", uri: "x-sonosapi-stream:gone" } } }]);
  edit(0);
  await settle();
  const nodes = edit(0);
  assert.ok(pressed(nodes, "add-favorite:77"));
  assert.equal(plain(byKey(nodes, "add-favorite:77").textContent), "Old FM (no longer in Sonos favorites)");
});

test("the scene says what its music does, and a run says why it was skipped", () => {
  home();
  const step = (set, roomId = 12) => ({ type: "music", room_id: roomId, device_ids: null, set });
  assert.equal(scenes.stepAction(step({ action: "resume" })), "Resume");
  assert.equal(scenes.stepAction(step({ action: "volume", volume: 20 })), "Volume 20%");
  assert.equal(plain(scenes.stepAction(step({ action: "play_favorite", favorite: STATION }))), "Play Example FM 99");
  assert.equal(plain(scenes.stepAction(step({ action: "play_favorite", favorite: STATION, volume: 30, with_room_ids: [11, 99] }))), "Play Example FM 99 at 30% · with Living Room, A removed room");
  assert.equal(plain(scenes.sceneSummary({ steps: [step({ action: "volume", volume: 20 })] })), "Kitchen music: Volume 20%");
  const run = (code, deviceId = 0) => ({ ran: 0, failed: 0, skipped: 1, problems: [{ step: 1, device_id: deviceId, outcome: "skipped", code, detail: "" }] });
  assert.equal(scenes.resultText(run("FAVORITE_GONE")), "Done — the music was skipped: that Sonos favorite is no longer in your Sonos favorites");
  assert.equal(scenes.resultText(run("FAVORITE_NOT_PLAYABLE")), "Done — the music was skipped: that Sonos favorite can only be started in the Sonos app");
  assert.equal(scenes.resultText(run("FORBIDDEN")), "Done — the music in some rooms was skipped: they aren’t yours to control");
  assert.equal(scenes.resultText(run("FORBIDDEN", 501)), "Done — doors and gates were skipped: they need door access", "a door is still a door");
  // Saving leaves out the rooms no longer in the project.
  const { steps, changed } = scenes.currentSteps([step({ action: "play_favorite", favorite: STATION, with_room_ids: [11, 99] }), step({ action: "play_favorite", favorite: STATION, with_room_ids: [99] })]);
  assert.equal(changed, true);
  assert.deepEqual(steps.map((item) => item.set.with_room_ids), [[11], undefined]);
});

test("in Hebrew", async () => {
  home();
  await setLanguage("he");
  try {
    let nodes = add();
    press(nodes, "add-kind:music");
    nodes = add();
    assert.equal(plain(byKey(nodes, "add-music:play_favorite").textContent), "ניגון מועדף");
    assert.equal(plain(byKey(nodes, "add-music:resume").textContent), "המשך ניגון");
    const step = { type: "music", room_id: 12, device_ids: null, set: { action: "play_favorite", favorite: STATION, volume: 30, with_room_ids: [11] } };
    assert.equal(plain(scenes.stepAction(step)), "ניגון Example FM 99 בעוצמה 30% · עם Living Room");
    assert.equal(scenes.resultText({ ran: 0, failed: 0, skipped: 1, problems: [{ device_id: 0, outcome: "skipped", code: "FAVORITE_GONE" }] }), "בוצע — המוזיקה דולגה: המועדף הזה כבר לא נמצא במועדפים של Sonos");
  } finally {
    await setLanguage("en");
  }
  // Every new English text has its Hebrew one.
  const keys = (node, prefix = "") => Object.entries(node).flatMap(([key, value]) => (value && typeof value === "object" ? keys(value, `${prefix}${key}.`) : [`${prefix}${key}`]));
  const missing = keys(en.scenes).filter((key) => !keys(he.scenes).includes(key));
  assert.deepEqual(missing, []);
});
