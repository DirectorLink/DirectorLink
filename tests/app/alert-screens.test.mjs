// Settings → Alerts → On TVs (1.13.0, ADR-086; app/js/views/alert-screens.js): the home's screens of
// DirectorLink's notification agreement, read from GET /v1/alerts/screens. An admin sees each one
// with its room (by the app's own room name) and what it shows, in the agreement's order, and the
// language the pop-ups are in; the card is read only and says Composer sets them up. Nothing when the
// home has none, for members (nothing is asked), and with a controller before 1.13.0. Read when the
// page is drawn and again a minute later. In English, Hebrew, Spanish and Italian.
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
    return this.children.map((child) => child.textContent).join("");
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/#/settings/alerts", pathname: "/", search: "", hash: "#/settings/alerts", replace: () => {} };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.history = { state: null, replaceState() {}, back() {} };
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
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);

// The fake controller: a DirectorLink that cannot seal (requests carry the key), with `screens` as
// GET /v1/alerts/screens answers them; every request kept in `asked`.
const controller = { asked: [], screens: null, status: 200 };
const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  controller.asked.push(`${method} ${path}`);
  if (path === "/v1/sealed") return reply(404, { status: 404, code: "NOT_FOUND" });
  if (path === "/v1/alerts/screens" && method === "GET") {
    return controller.status === 200 ? reply(200, controller.screens) : reply(controller.status, { status: controller.status, code: "FORBIDDEN" });
  }
  return reply(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { screensCard, kindsText, loadScreens, SCREEN_KINDS } = await import("../../app/js/views/alert-screens.js");
const { settingsView } = await import("../../app/js/views/settings.js");
const dictionaries = {
  en: (await import("../../app/i18n/en.js")).default,
  he: (await import("../../app/i18n/he.js")).default,
  es: (await import("../../app/i18n/es.js")).default,
  it: (await import("../../app/i18n/it.js")).default,
};

async function settle() {
  for (let index = 0; index < 10; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

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

const SCREENS = {
  items: [
    { id: 302, name: "Kitchen TV", room_id: 10, room: "Kitchen", kinds: ["doorbell", "alarm"] },
    { id: 301, name: "Living Room TV", room_id: 11, room: "Living Room", kinds: ["alarm", "doorbell", "camera", "door", "other"] },
    { id: 306, name: "Quiet TV", room_id: null, room: null, kinds: [] },
  ],
  language: "he",
};

// Connected as `role` to a controller with (or, `older`, without) the screens.
function home({ role = "admin", older = false, screens = SCREENS } = {}) {
  Object.assign(state, {
    host: HOST,
    apiKey: "ak_test",
    transport: "lan",
    status: "connected",
    loaded: true,
    role,
    access: { role, all_rooms: true, rooms: [], cameras: true },
    rooms: [{ id: 10, name: "Kitchen", names: {} }, { id: 11, name: "Living Room", names: { he: "סלון" } }],
    errors: {},
    system: { bridge: { version: older ? "1.12.2" : "1.13.0" }, features: older ? { user_names: true, camera_order: true } : { user_names: true, camera_order: true, alert_screens: true } },
  });
  ui.alertScreens = null;
  Object.assign(controller, { asked: [], screens, status: 200 });
}

const asked = () => controller.asked.filter((line) => line === "GET /v1/alerts/screens").length;

// The card once its list has been read: drawn, the request answered, drawn again.
async function card() {
  screensCard();
  await settle();
  return screensCard();
}

const rows = (view) => findAll(view, (node) => hasClass(node, "alert-screen"));

test("an admin sees each screen with its room and what it shows, read from the controller", async () => {
  await setLanguage("en");
  home();
  const view = await card();
  assert.ok(view, "the card");
  assert.equal(asked(), 1, "one request");
  assert.equal(view.attributes.id, "settings-alert-screens");
  assert.match(view.textContent, /^On TVs/);
  assert.match(view.textContent, /Your installer adds them in Composer/);
  const listed = rows(view).map((row) => row.children.filter(Boolean).map((part) => part.textContent));
  assert.deepEqual(listed, [
    ["Kitchen TV", "Kitchen", "Shows: Doorbell, Alarms"],
    ["Living Room TV", "Living Room", "Shows: Doorbell, Cameras, Doors, Alarms, Other"],
    ["Quiet TV", "Shows nothing"],
  ]);
  assert.deepEqual(rows(view).map((row) => row.dataset.key), ["alert-screen:302", "alert-screen:301", "alert-screen:306"]);
  assert.equal(byKey(view, "alert-screens-language").textContent, "Language: עברית, as the home’s owner chose it in Appearance and language (Auto shows English).");
  // No switch, no button: read only.
  assert.equal(findAll(view, (node) => node.tagName === "BUTTON" || node.attributes.role === "switch").length, 0);

  // Drawn again within a minute: nothing asked; after it, read again.
  screensCard();
  await settle();
  assert.equal(asked(), 1);
  ui.alertScreens.at -= 61000;
  screensCard();
  await settle();
  assert.equal(asked(), 2);
});

test("Settings → Alerts holds the card after this device's, for admins", async () => {
  await setLanguage("en");
  home();
  state.account = { status: "signed-out" };
  await card();
  const page = settingsView({ page: "alerts" });
  const keys = [];
  walk(page, (node) => node.dataset?.key && keys.push(node.dataset.key));
  assert.ok(keys.includes("alert-screens"), "On TVs on the page");
  const cards = findAll(page, (node) => node.tagName === "SECTION").map((node) => node.attributes.id);
  assert.deepEqual(cards.slice(-2), ["settings-alerts", "settings-alert-screens"]);
});

test("nothing without screens, for members, or with an older controller", async () => {
  await setLanguage("en");
  home({ screens: { items: [], language: "en" } });
  assert.equal(await card(), null, "a home without screens");
  assert.equal(asked(), 1);

  home({ role: "member" });
  assert.equal(await card(), null, "a member");
  assert.equal(asked(), 0, "a member asks nothing");

  home({ older: true });
  assert.equal(await card(), null, "DirectorLink before 1.13.0");
  assert.equal(asked(), 0);

  // A refusal or an answer that is no list shows nothing either.
  home();
  controller.status = 403;
  assert.equal(await card(), null);
  home({ screens: { language: "en" } });
  assert.equal(await card(), null);
  await loadScreens();
});

test("what a screen shows is said in the agreement's order, in every language", async () => {
  await setLanguage("en");
  assert.deepEqual(SCREEN_KINDS, ["doorbell", "camera", "door", "alarm", "other"]);
  assert.equal(kindsText(["other", "camera"]), "Shows: Cameras, Other");
  assert.equal(kindsText(["popcorn"]), "Shows nothing");
  assert.equal(kindsText(undefined), "Shows nothing");
  for (const [code, dictionary] of Object.entries(dictionaries)) {
    const words = dictionary.alerts.screens;
    for (const key of ["title", "help", "shows", "nothing", "language"]) {
      assert.equal(typeof words[key], "string", `${code} alerts.screens.${key}`);
      assert.ok(words[key].trim(), `${code} alerts.screens.${key}`);
    }
    assert.match(words.shows, /\{kinds\}/);
    assert.match(words.language, /\{language\}/);
    for (const kind of SCREEN_KINDS) assert.ok(words.kinds[kind], `${code} alerts.screens.kinds.${kind}`);
    assert.match(words.help, /Composer/, `${code}: Composer sets them up`);
  }

  await setLanguage("he");
  home();
  const hebrew = await card();
  assert.equal(hebrew.children[0].textContent, "בטלוויזיות");
  const living = rows(hebrew)[1].children.filter(Boolean).map((part) => part.textContent);
  assert.deepEqual(living, ["Living Room TV", "סלון", "מציגה: פעמון, מצלמות, דלתות, אזעקות, אחר"], "the room by the app's Hebrew name");
  assert.equal(rows(hebrew)[0].children[0].attributes.dir, "auto", "a name in Latin letters reads as it is");

  await setLanguage("es");
  home();
  assert.equal(rows(await card())[0].children.filter(Boolean)[2].textContent, "Muestra: Timbre, Alarmas");
  await setLanguage("it");
  home({ screens: { ...SCREENS, language: "en" } });
  const italian = await card();
  assert.equal(rows(italian)[2].children.filter(Boolean)[1].textContent, "Non mostra nulla");
  assert.match(byKey(italian, "alert-screens-language").textContent, /^Lingua: English,/);
  await setLanguage("en");
});
