// Favorites of devices removed in Composer (1.8.0, ADR-059, docs/PREFERENCES.md): the controller
// says which of the person's favorites are gone (GET /v1/profile `gone_favorites`); Home shows each
// as "Removed in Composer" with Remove, and never as an empty tile asking for a device that is not
// there. A favorite the app cannot show for another reason (a list a moment old, a device the person
// may not see) is never called removed. Without `gone_favorites` (a 1.7.0 controller) Home is as before.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

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
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child?.textContent ?? "").join("");
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
  },
  configurable: true,
});
globalThis.history = { state: null, replaceState() {} };
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
globalThis.IntersectionObserver = class {
  observe() {}
  unobserve() {}
};

// The controller: PATCH /v1/profile is answered as DirectorLink 1.8.0 does (the gone favorites of
// the new list only).
const patches = [];
globalThis.fetch = async (url, init = {}) => {
  const { pathname } = new URL(url);
  if (pathname === "/v1/sealed") return new Response(JSON.stringify({ code: "NOT_FOUND" }), { status: 404 });
  if (pathname === "/v1/profile" && init.method === "PATCH") {
    const body = JSON.parse(init.body);
    patches.push(body.prefs);
    const favorites = body.prefs.favorites ?? state.profile.prefs.favorites;
    const gone = (state.profile.gone_favorites || []).filter((item) => favorites.includes(item.entry));
    return new Response(JSON.stringify({ ...state.profile, version: state.profile.version + 1, prefs: { ...state.profile.prefs, ...body.prefs }, gone_favorites: gone }), { status: 200, headers: { "content-type": "application/json" } });
  }
  return new Response(JSON.stringify({ items: [] }), { status: 200, headers: { "content-type": "application/json" } });
};

const { state, ui } = await import("../../app/js/state.js");
const { favoriteDevices, goneFavorites } = await import("../../app/js/favorites.js");
const { homeView } = await import("../../app/js/views/home.js");
const { setLanguage } = await import("../../app/js/i18n.js");

function walk(node, visit) {
  if (!node) return;
  if (Array.isArray(node)) {
    for (const item of node) walk(item, visit);
    return;
  }
  visit(node);
  for (const child of node.children || []) walk(child, visit);
}
function byKey(node, key) {
  let found = null;
  walk(node, (item) => {
    if (!found && item.dataset?.key === key) found = item;
  });
  return found;
}
function tiles(view) {
  const found = [];
  walk(view, (item) => {
    if (typeof item.attributes?.class === "string" && /\bfav-tile\b/.test(item.attributes.class)) found.push(item);
    else if (typeof item.className === "string" && /\bfav-tile\b/.test(item.className)) found.push(item);
  });
  return found;
}
const render = () => homeView({ openCamera() {}, openFavoritesPicker() {} });

const CAMERA = { id: 62, name: "Back yard", room: { id: 10, name: "Kitchen" }, snapshot_href: "/v1/cameras/62/snapshot" };
const LIGHT = { id: 20, name: "Kitchen Island", room: { id: 10, name: "Kitchen" }, on: false, dimmable: true, brightness: 0 };

function home(profile) {
  Object.assign(state, {
    apiKey: "ak_test",
    host: "controller.invalid",
    status: "connected",
    loaded: true,
    role: "admin",
    system: { features: {} },
    rooms: [{ id: 10, name: "Kitchen" }],
    lights: [LIGHT],
    cameras: [CAMERA, { id: 60, name: "Driveway", room: { id: 10, name: "Kitchen" }, snapshot_href: "/v1/cameras/60/snapshot" }],
    profile,
  });
}

test("a favorite whose device was removed in Composer shows as removed, with Remove, never as an empty tile", async () => {
  // The controller says camera 60 and an old camera 61 are gone; this app's camera list is a moment
  // old and still has 60. Light 20 is there; light 99 is a device this app does not list (not
  // loaded, or not for this person), and is not called removed.
  home({
    id: "p1",
    version: 4,
    prefs: { favorites: ["camera:60", "light:20", "camera:61", "light:99", "camera:62"] },
    gone_favorites: [
      { entry: "camera:60", since: "2026-10-01T08:00:00Z", name: "Driveway" },
      { entry: "camera:61", since: "2026-10-01T08:00:00Z" },
    ],
  });
  assert.deepEqual(favoriteDevices().map((item) => item.entry), ["light:20", "camera:62"], "the gone camera is no tile of its own, though the list still has it");
  assert.deepEqual(goneFavorites(), [
    { entry: "camera:60", kind: "camera", name: "Driveway" },
    { entry: "camera:61", kind: "camera", name: null },
  ]);
  const view = render();
  const driveway = byKey(view, "camera:60:gone");
  assert.ok(driveway, "a tile for the removed camera");
  assert.match(driveway.textContent, /Driveway.*Removed in Composer.*Remove/);
  assert.match(byKey(view, "camera:61:gone").textContent, /A removed device.*Removed in Composer/);
  assert.equal(byKey(view, "light:99:gone"), null, "not known to be removed: not called so");
  assert.equal(tiles(view).length, 4, "two devices and two removed ones");

  // Remove: gone from the person's favorites (the profile, a moment later), and from Home at once.
  const remove = byKey(view, "camera:60:gone-remove");
  assert.equal(remove.attributes["aria-label"], "Remove Driveway from favorites");
  for (const listener of remove.listeners.click) listener({ type: "click" });
  assert.deepEqual(state.profile.prefs.favorites, ["light:20", "camera:61", "light:99", "camera:62"]);
  assert.equal(byKey(render(), "camera:60:gone"), null);
  // Saved a moment later (profile.js), then the controller's answer is the profile.
  for (let waited = 0; waited < 10_000 && state.profile.gone_favorites.length !== 1; waited += 50) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.deepEqual(patches.at(-1).favorites, ["light:20", "camera:61", "light:99", "camera:62"], "saved to the profile");
  assert.deepEqual(state.profile.gone_favorites.map((item) => item.entry), ["camera:61"]);
});

test("only gone favorites: no empty-favorites invitation, the removed tiles instead", () => {
  home({ id: "p1", version: 1, prefs: { favorites: ["camera:61"] }, gone_favorites: [{ entry: "camera:61", since: "2026-10-01T08:00:00Z", name: "Gate" }] });
  const view = render();
  assert.ok(byKey(view, "camera:61:gone"));
  assert.equal(byKey(view, "favorites-add-empty"), null);
  ui.editFavorites = false;
});

test("a controller before 1.8.0 says nothing: Home as before", () => {
  home({ id: "p1", version: 1, prefs: { favorites: ["camera:60", "camera:61"] } });
  assert.deepEqual(goneFavorites(), []);
  assert.deepEqual(favoriteDevices().map((item) => item.entry), ["camera:60"]);
  assert.equal(byKey(render(), "camera:61:gone"), null);
});

test("in Hebrew", async () => {
  await setLanguage("he");
  home({ id: "p1", version: 1, prefs: { favorites: ["camera:61"] }, gone_favorites: [{ entry: "camera:61", since: "2026-10-01T08:00:00Z" }] });
  assert.match(byKey(render(), "camera:61:gone").textContent, /מכשיר שהוסר.*הוסר ב-Composer.*הסרה/);
  await setLanguage("en");
});
