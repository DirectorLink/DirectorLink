// The home's camera order in the app (1.12.1): an admin's Order on the Cameras tab opens every
// camera (doorbell cameras too) with its room; a camera moves with the arrows, with the keyboard or
// dragged by its handle (app/js/sortable.js, as Settings → Rooms' rooms do); Save sends the order in
// one PUT /v1/cameras/order and the tab shows it, Cancel sends nothing; a refusal keeps the list
// with why. Members, and controllers before 1.12.1, get no Order. The Cameras tab and a room follow
// the order the controller lists, a room's doorbells at their cameras' places; in English, Hebrew,
// Spanish and Italian.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

const HOST = "controller.invalid";
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
    this.parentElement = null;
    this.style = { transform: "", setProperty() {} };
    this.classList = {
      add: (...names) => (this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...names])].join(" ")),
      remove: (...names) => (this.className = this.className.split(/\s+/).filter((item) => item && !names.includes(item)).join(" ")),
      contains: (name) => this.className.split(/\s+/).includes(name),
    };
    this.isConnected = true;
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
    return event;
  }
  append(...children) {
    for (const child of children) {
      if (child instanceof FakeElement) child.parentElement = this;
      this.children.push(child);
    }
  }
  closest(selector) {
    const wanted = selector.replace(/^\./, "");
    for (let node = this; node; node = node.parentElement) {
      if (node.classList.contains(wanted)) return node;
    }
    return null;
  }
  // Rows 52 px high, one under the other, the list's top at 100 px.
  get offsetTop() {
    return this.parentElement ? this.parentElement.children.indexOf(this) * 52 : 0;
  }
  get offsetHeight() {
    return 52;
  }
  getBoundingClientRect() {
    return { top: 100, bottom: 100 + this.children.length * 52, left: 0, right: 390 };
  }
  setPointerCapture() {}
  focus() {}
  set textContent(text) {
    this.children = [Object.assign(new FakeNode(), { textContent: String(text) })];
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
window.innerHeight = 800;
window.scrollBy = () => {};
window.scrollTo = () => {};
const documentListeners = {};
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: { append() {} },
  addEventListener: (type, listener) => (documentListeners[type] ||= new Set()).add(listener),
  removeEventListener: (type, listener) => documentListeners[type]?.delete(listener),
  querySelector: () => null,
  querySelectorAll: () => [],
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
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);
// What is read out goes after 10 s (sortable.js): that timer does not keep the tests waiting.
const realSetTimeout = setTimeout;
globalThis.setTimeout = (callback, ms, ...rest) => {
  const timer = realSetTimeout(callback, ms, ...rest);
  if (ms >= 1000) timer.unref?.();
  return timer;
};
globalThis.cancelAnimationFrame = (handle) => clearTimeout(handle);

// The fake controller: a DirectorLink that cannot seal (requests carry the key). It answers
// PUT /v1/cameras/order with the cameras in that order, then the others, or with `refuse`.
const controller = { puts: [], refuse: null };
const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  if (path === "/v1/sealed") return reply(404, { status: 404, code: "NOT_FOUND" });
  if (path === "/v1/cameras/order" && method === "PUT") {
    const ids = JSON.parse(init.body).camera_ids;
    controller.puts.push(ids);
    if (controller.refuse) return reply(controller.refuse.status, controller.refuse);
    const listed = ids.map((id) => CAMERAS.find((camera) => camera.id === id));
    return reply(200, { items: [...listed, ...CAMERAS.filter((camera) => !ids.includes(camera.id))] });
  }
  return reply(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage, t } = await import("../../app/js/i18n.js");
const { camerasView, orderedCameras } = await import("../../app/js/views/cameras.js");
const { roomView } = await import("../../app/js/views/room.js");
const { orderStatus } = await import("../../app/js/sortable.js");
const dictionaries = {
  en: (await import("../../app/i18n/en.js")).default,
  he: (await import("../../app/i18n/he.js")).default,
  es: (await import("../../app/i18n/es.js")).default,
  it: (await import("../../app/i18n/it.js")).default,
};

async function settle() {
  for (let index = 0; index < 10; index += 1) await new Promise((resolve) => setImmediate(resolve));
}
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function findAll(nodes, check) {
  const found = [];
  walk(nodes, (node) => node instanceof FakeElement && check(node) && found.push(node));
  return found;
}
const byKey = (nodes, key) => findAll(nodes, (node) => node.dataset.key === key)[0] || null;
const hasClass = (node, name) => typeof node.className === "string" && node.className.split(/\s+/).includes(name);
const plain = (text) => String(text ?? "").replace(/[⁦-⁩]/g, "");

const kitchen = { id: 10, name: "Kitchen" };
const living = { id: 11, name: "Living Room" };
const camera = (id, name, room) => ({ id, name, room, snapshot_href: `/v1/cameras/${id}/snapshot` });
// As DirectorLink lists them before an order is set: by name. 68 is a doorbell camera (ADR-065), 92
// the DoorBird 93's camera.
const CAMERAS = [
  camera(60, "Driveway", kitchen),
  camera(68, "Entrance", kitchen),
  camera(61, "Gate", living),
  camera(92, "Gate Camera", kitchen),
  camera(67, "Porch", living),
];
const DOORBELLS = [
  { id: 68, name: "Entrance", room: kitchen, camera: { id: 68, snapshot_href: "/v1/cameras/68/snapshot" }, can_open: false, events: [], doors: [] },
  { id: 93, name: "Front Gate", room: kitchen, camera: { id: 92, snapshot_href: "/v1/cameras/92/snapshot" }, can_open: false, events: [], doors: [] },
];

// Connected as `role` to a controller with (or, `older`, without) the camera order.
function home({ role = "admin", older = false, cameras = CAMERAS } = {}) {
  Object.assign(state, {
    host: HOST,
    apiKey: "ak_test",
    transport: "lan",
    status: "connected",
    loaded: true,
    role,
    access: { role, all_rooms: true, rooms: [], cameras: true },
    rooms: [kitchen, living],
    lights: [],
    thermostats: [],
    fans: [],
    blinds: [],
    cameras: cameras.map((item) => ({ ...item })),
    relays: [],
    doorbells: DOORBELLS.map((item) => ({ ...item })),
    refrigerators: [],
    devices: [],
    errors: {},
    system: { bridge: { version: older ? "1.12.0" : "1.12.1" }, features: older ? { user_names: true } : { user_names: true, camera_order: true } },
  });
  Object.assign(ui, { cameraOrder: null, featuredCamera: null, reordering: false });
  Object.assign(controller, { puts: [], refuse: null });
}

const screen = () => camerasView({ openCamera: () => {} });
const rowIds = (view) => findAll(view, (node) => hasClass(node, "room-order-row")).map((row) => Number(row.dataset.key.split(":")[1]));
const tileIds = (view) => findAll(view, (node) => hasClass(node, "camera-open")).map((tile) => Number(tile.dataset.key.split(":")[1]));
const ids = (list) => list.map((item) => item.id);

test("Order is an admin's, on a controller that keeps a camera order, with more than one camera", async () => {
  await setLanguage("en");
  home();
  const button = byKey(screen(), "camera-order");
  assert.ok(button, "an admin's Order");
  assert.equal(plain(button.textContent), "Order");
  home({ role: "member" });
  assert.equal(byKey(screen(), "camera-order"), null, "a member sees the order, no button");
  assert.deepEqual(tileIds(screen()), [60, 68, 61, 92, 67], "the cameras as the controller lists them");
  home({ older: true });
  assert.equal(byKey(screen(), "camera-order"), null, "DirectorLink before 1.12.1 has no camera order");
  home({ cameras: [CAMERAS[0]] });
  assert.equal(byKey(screen(), "camera-order"), null, "one camera has nothing to order");
  // A member with a list left open (a role changed meanwhile) gets the cameras, not the list.
  home({ role: "member" });
  ui.cameraOrder = { ids: [67, 60], busy: false, message: null };
  assert.equal(findAll(screen(), (node) => hasClass(node, "camera-order-list")).length, 0);
});

test("the list has every camera with its room; the arrows move one, and Save sends the order once", async () => {
  await setLanguage("en");
  home();
  byKey(screen(), "camera-order").dispatch("click");
  let view = screen();
  assert.deepEqual(rowIds(view), [60, 68, 61, 92, 67], "in today's order");
  const rooms = findAll(view, (node) => hasClass(node, "camera-order-room")).map((node) => plain(node.textContent));
  assert.deepEqual(rooms, ["Kitchen", "Kitchen", "Living Room", "Kitchen", "Living Room"]);
  assert.equal(plain(byKey(view, "camera-order").textContent), "Camera order", "the list's title takes the focus from Order");
  assert.equal(byKey(view, "camera-up:60").attributes["aria-disabled"], "true", "the first one cannot go up");
  assert.equal(byKey(view, "camera-down:67").attributes["aria-disabled"], "true", "nor the last one down");
  assert.equal(byKey(view, "camera-up:67").attributes["aria-label"], "Move Porch up");

  byKey(view, "camera-up:67").dispatch("click");
  byKey(screen(), "camera-up:67").dispatch("click");
  byKey(screen(), "camera-down:60").dispatch("click");
  view = screen();
  assert.deepEqual(rowIds(view), [68, 60, 67, 61, 92]);
  assert.deepEqual(controller.puts, [], "nothing is sent before Save");
  assert.deepEqual(tileIds(view), [], "the pictures wait");

  byKey(view, "camera-order-save").dispatch("click");
  assert.equal(ui.cameraOrder.busy, true);
  assert.equal(byKey(screen(), "camera-order-save").attributes.disabled, "", "Save waits for the controller");
  await settle();
  assert.deepEqual(controller.puts, [[68, 60, 67, 61, 92]], "one PUT /v1/cameras/order with every camera");
  assert.equal(ui.cameraOrder, null, "the list closes");
  assert.deepEqual(ids(state.cameras), [68, 60, 67, 61, 92], "as the controller answered");
  view = screen();
  assert.deepEqual(tileIds(view), [68, 60, 67, 61, 92], "the Cameras tab in the new order");
  assert.ok(byKey(view, "camera:68:open:large"), "the first one is the large picture");
});

test("a picture picked as the large one gives way to the new first one after Save", async () => {
  await setLanguage("en");
  home();
  ui.featuredCamera = 61;
  assert.ok(byKey(screen(), "camera:61:open:large"));
  byKey(screen(), "camera-order").dispatch("click");
  byKey(screen(), "camera-up:67").dispatch("click");
  byKey(screen(), "camera-order-save").dispatch("click");
  await settle();
  assert.equal(ui.featuredCamera, null);
  assert.ok(byKey(screen(), "camera:60:open:large"));
});

test("Cancel sends nothing and puts the cameras back as they were", async () => {
  await setLanguage("en");
  home();
  byKey(screen(), "camera-order").dispatch("click");
  byKey(screen(), "camera-up:92").dispatch("click");
  assert.deepEqual(rowIds(screen()), [60, 68, 92, 61, 67]);
  byKey(screen(), "camera-order-cancel").dispatch("click");
  await settle();
  assert.equal(ui.cameraOrder, null);
  assert.deepEqual(controller.puts, []);
  assert.deepEqual(tileIds(screen()), [60, 68, 61, 92, 67]);
});

test("a refused Save keeps the list as it was set, with why; an older DirectorLink says to update it", async () => {
  await setLanguage("en");
  home();
  byKey(screen(), "camera-order").dispatch("click");
  byKey(screen(), "camera-up:67").dispatch("click");
  controller.refuse = { status: 400, code: "INVALID_FIELD", detail: "Unknown camera: 67" };
  byKey(screen(), "camera-order-save").dispatch("click");
  await settle();
  assert.deepEqual(ui.cameraOrder.ids, [60, 68, 61, 67, 92], "still open, as set");
  assert.equal(ui.cameraOrder.busy, false);
  let alert = findAll(screen(), (node) => node.attributes.role === "alert")[0];
  assert.equal(plain(alert.textContent), "Unknown camera: 67");
  assert.deepEqual(ids(state.cameras), [60, 68, 61, 92, 67], "the cameras as before");
  controller.refuse = { status: 404, code: "NOT_FOUND", detail: "No route" };
  byKey(screen(), "camera-order-save").dispatch("click");
  await settle();
  alert = findAll(screen(), (node) => node.attributes.role === "alert")[0];
  assert.equal(plain(alert.textContent), t("cameras.order.updateDriver"));
  // A move clears it.
  byKey(screen(), "camera-up:92").dispatch("click");
  assert.equal(ui.cameraOrder.message, null);
});

test("a camera added while the list is open goes to the end; one removed is passed over", () => {
  const added = camera(70, "Back Yard", living);
  assert.deepEqual(ids(orderedCameras([67, 60, 61], [...CAMERAS, added])), [67, 60, 61, 68, 92, 70]);
  assert.deepEqual(ids(orderedCameras([67, 99, 60], CAMERAS)), [67, 60, 68, 61, 92]);
  assert.deepEqual(ids(orderedCameras([], CAMERAS)), [60, 68, 61, 92, 67]);
});

test("the keyboard moves a camera by its handle, and says where it is", async () => {
  await setLanguage("en");
  home();
  byKey(screen(), "camera-order").dispatch("click");
  const view = screen();
  const handle = byKey(view, "camera-move:61");
  assert.equal(handle.attributes["aria-label"], "Move Gate");
  assert.equal(handle.attributes["aria-describedby"], "camera-order-keys");
  assert.equal(plain(findAll(view, (node) => node.attributes.id === "camera-order-keys")[0].textContent), t("cameras.order.moveKeys"));
  const key = (name) => handle.dispatch("keydown", { key: name, repeat: false });
  key(" ");
  assert.equal(ui.reordering, true, "redraws wait while it moves");
  assert.equal(plain(orderStatus().textContent), "Moving Gate: position 3 of 5.");
  key("ArrowUp");
  key("ArrowUp");
  assert.equal(plain(orderStatus().textContent), "Gate: position 1 of 5");
  key("ArrowDown");
  key(" ");
  assert.equal(plain(orderStatus().textContent), "Gate is now at position 2 of 5.");
  await settle();
  assert.equal(ui.reordering, false);
  assert.deepEqual(ui.cameraOrder.ids, [60, 61, 68, 92, 67], "Gate up one place");
  assert.deepEqual(controller.puts, [], "Save sends it");
});

test("a camera dragged by its handle takes the place it is let go at", async () => {
  await setLanguage("en");
  home();
  byKey(screen(), "camera-order").dispatch("click");
  const handle = byKey(screen(), "camera-move:67");
  // Porch, the fifth row (308 to 360 px on screen), held at 334 px and let go over the second row.
  const pointer = { pointerId: 1, isPrimary: true, button: 0, pointerType: "mouse" };
  handle.dispatch("pointerdown", { ...pointer, clientY: 334 });
  assert.equal(ui.reordering, true);
  for (const y of [300, 260, 220, 180]) handle.dispatch("pointermove", { ...pointer, clientY: y });
  handle.dispatch("pointerup", { ...pointer, clientY: 180 });
  await wait(250);
  assert.equal(ui.reordering, false, "it glided into its place");
  assert.deepEqual(ui.cameraOrder.ids, [60, 67, 68, 61, 92]);
  // A touch held too briefly scrolls: nothing moves.
  const touch = { pointerId: 2, isPrimary: true, button: 0, pointerType: "touch" };
  byKey(screen(), "camera-move:60").dispatch("pointerdown", { ...touch, clientX: 370, clientY: 126 });
  byKey(screen(), "camera-move:60").dispatch("pointermove", { ...touch, clientX: 370, clientY: 200 });
  await wait(300);
  assert.equal(ui.reordering, false);
  assert.deepEqual(ui.cameraOrder.ids, [60, 67, 68, 61, 92]);
});

test("a room shows its cameras in the home's order, and its doorbells at their cameras' places", async () => {
  await setLanguage("en");
  home();
  const doorbellNames = (view) => findAll(view, (node) => hasClass(node, "device-name")).map((node) => plain(node.textContent));
  const cameraNames = (view) => findAll(view, (node) => hasClass(node, "camera-name")).map((node) => plain(node.textContent));
  let view = roomView(10, { openCamera: () => {} });
  assert.deepEqual(doorbellNames(view), ["Entrance", "Front Gate"], "by name before an order is set");
  state.cameras = [CAMERAS[3], CAMERAS[4], CAMERAS[1], CAMERAS[0], CAMERAS[2]].map((item) => ({ ...item }));
  view = roomView(10, { openCamera: () => {} });
  assert.deepEqual(doorbellNames(view), ["Front Gate", "Entrance"], "the DoorBird at its camera Gate Camera's place, before Entrance");
  assert.deepEqual(cameraNames(view), ["Driveway"], "a doorbell's camera shows in its doorbell, not twice");
  // Before 1.12.1 the doorbells stay as the controller lists them.
  state.system = { features: {} };
  view = roomView(10, { openCamera: () => {} });
  assert.deepEqual(doorbellNames(view), ["Entrance", "Front Gate"]);
  // A doorbell whose picture this user does not see keeps its place after the others.
  state.system = { features: { camera_order: true } };
  state.doorbells = [{ ...DOORBELLS[0], camera: null }, DOORBELLS[1]];
  view = roomView(10, { openCamera: () => {} });
  assert.deepEqual(doorbellNames(view), ["Front Gate", "Entrance"]);
});

test("Hebrew: Order and the list in Hebrew, with the cameras' names as Control4 has them", async () => {
  await setLanguage("he");
  home();
  assert.equal(plain(byKey(screen(), "camera-order").textContent), "סידור");
  byKey(screen(), "camera-order").dispatch("click");
  const view = screen();
  assert.equal(plain(byKey(view, "camera-order").textContent), "סדר המצלמות");
  assert.equal(plain(byKey(view, "camera-order-save").textContent), "שמירה");
  assert.equal(plain(byKey(view, "camera-order-cancel").textContent), "ביטול");
  assert.equal(plain(byKey(view, "camera-up:68").attributes["aria-label"]), "הזזת Entrance למעלה");
  const names = findAll(view, (node) => hasClass(node, "room-order-name"));
  assert.ok(names.every((node) => node.children.every((child) => child.attributes.dir === "auto")), "names keep their own direction");
  assert.equal(t("cameras.order.position", { name: "Porch", position: 2, count: 5 }).replace(/[⁦-⁩]/g, ""), "Porch: מקום 2 מתוך 5");
  await setLanguage("en");
});

test("the words are in all four languages, with the same placeholders", () => {
  const holes = (text) => [...text.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();
  const keys = Object.keys(dictionaries.en.cameras.order);
  assert.deepEqual(keys.sort(), ["button", "cancelled", "dropped", "help", "lifted", "move", "moveDown", "moveKeys", "moveUp", "position", "title", "updateDriver"].sort());
  for (const [language, dictionary] of Object.entries(dictionaries)) {
    for (const key of keys) {
      const text = dictionary.cameras.order[key];
      assert.equal(typeof text, "string", `${language} ${key}`);
      assert.deepEqual(holes(text), holes(dictionaries.en.cameras.order[key]), `${language} ${key}`);
      if (language === "he") assert.match(text, /[א-ת]/, `he ${key}`);
    }
    assert.equal(typeof dictionary.backup.preview.cameraOrder, "string", `${language} backup.preview.cameraOrder`);
    assert.equal(typeof dictionary.backup.where.cameraOrder, "string", `${language} backup.where.cameraOrder`);
  }
});
