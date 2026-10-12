// The language the app shows, told to the controller (1.13.0, ADR-086; app/js/profile.js): on its
// profile sync the app reports `shown_language`, the language it renders in (its own choice, or with
// Auto the device's), so that the home's screens speak the owner's language. Only to a controller
// whose profile has the field (an older one would refuse it), only when it says another, and once a
// start for each language, so that two devices of one user do not take turns every minute. The
// choice itself (`language`) is untouched.
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
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener() {}
  append(...children) {
    this.children.push(...children);
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
  querySelectorAll: () => [],
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
// A Hebrew phone.
const device = { languages: ["he-IL", "en-US"] };
Object.defineProperty(globalThis, "navigator", {
  value: {
    userAgent: "Node",
    maxTouchPoints: 0,
    get languages() {
      return device.languages;
    },
    get language() {
      return device.languages[0];
    },
    onLine: true,
  },
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
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);

// The fake controller: a DirectorLink that cannot seal (requests carry the key), with this user's
// profile; `older`: a controller before 1.13.0, whose profile has no shown_language and which refuses
// it. Every PATCH's prefs are kept in `patches`.
const controller = { profile: null, older: false, patches: [] };
const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  if (path === "/v1/sealed") return reply(404, { status: 404, code: "NOT_FOUND" });
  if (path === "/v1/profile" && method === "GET") return reply(200, controller.profile);
  if (path === "/v1/profile" && method === "PATCH") {
    const prefs = JSON.parse(init.body).prefs || {};
    controller.patches.push(prefs);
    if (controller.older && Object.hasOwn(prefs, "shown_language")) {
      return reply(400, { status: 400, code: "INVALID_FIELD", detail: "Unknown preference: shown_language" });
    }
    const chosen = Object.keys(prefs).some((field) => field !== "shown_language");
    controller.profile = { ...controller.profile, version: controller.profile.version + (chosen ? 1 : 0), prefs: { ...controller.profile.prefs, ...prefs } };
    return reply(200, controller.profile);
  }
  return reply(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { state } = await import("../../app/js/state.js");
const { currentLanguage, setLanguage } = await import("../../app/js/i18n.js");
const { syncProfile } = await import("../../app/js/profile.js");

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// The profile's changes go out 600 ms after they are made (profile.js).
const saved = () => wait(700);

// Connected to a controller (or, `older`, one before 1.13.0) whose profile chose `language` and was
// last told `shown`.
async function home({ language = "auto", shown = null, older = false, languages = ["he-IL", "en-US"], profile = "p1" } = {}) {
  device.languages = languages;
  await setLanguage(language);
  const prefs = { language, theme: null, palette: null, favorites: [], hidden_rooms: [] };
  if (!older) prefs.shown_language = shown;
  Object.assign(controller, { profile: { id: profile, name: "Dana", version: 3, prefs }, older, patches: [] });
  Object.assign(state, { host: HOST, apiKey: "ak_test", transport: "lan", status: "connected", loaded: true, role: "admin", profile: null });
}

test("with Auto on a Hebrew phone, the app tells the controller it shows Hebrew, once", async () => {
  await home();
  assert.equal(currentLanguage(), "he", "Auto shows the device's language");
  await syncProfile();
  await saved();
  assert.deepEqual(controller.patches, [{ shown_language: "he" }], "only what it shows: the choice stays Auto");
  assert.equal(controller.profile.prefs.language, "auto");
  assert.equal(controller.profile.version, 3, "no new version on the controller");
  // The next minute's sync: the controller has it, nothing more is sent.
  await syncProfile();
  await saved();
  assert.equal(controller.patches.length, 1);
});

test("a language the user chose is what the app shows, and is told", async () => {
  await home({ language: "es", shown: "he" });
  assert.equal(currentLanguage(), "es");
  await syncProfile();
  await saved();
  assert.deepEqual(controller.patches, [{ shown_language: "es" }]);
});

test("nothing is told when the controller already has it, nor to a controller before 1.13.0", async () => {
  await home({ shown: "he", profile: "p2" });
  await syncProfile();
  await saved();
  assert.deepEqual(controller.patches, [], "the controller already says Hebrew");

  await home({ older: true, profile: "p3" });
  await syncProfile();
  await saved();
  await syncProfile();
  await saved();
  assert.deepEqual(controller.patches, [], "an older controller would refuse the field: never sent");
  assert.equal(Object.hasOwn(state.profile.prefs, "shown_language"), false);
});

test("two devices of one user that show different languages do not take turns every minute", async () => {
  // This device (an English laptop) told English; then another device of the user told Hebrew.
  await home({ languages: ["en-US"], profile: "p4" });
  await syncProfile();
  await saved();
  assert.deepEqual(controller.patches, [{ shown_language: "en" }]);
  controller.profile.prefs.shown_language = "he";
  await syncProfile();
  await saved();
  await syncProfile();
  await saved();
  assert.equal(controller.patches.length, 1, "told once in this start, not again every minute");
  // Its own language changes: told again.
  device.languages = ["it-IT"];
  await setLanguage("auto");
  await syncProfile();
  await saved();
  assert.deepEqual(controller.patches.at(-1), { shown_language: "it" });
});
