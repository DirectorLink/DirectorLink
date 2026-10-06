// The app's languages (1.10.0, ADR-067): English, Hebrew, Spanish and Italian. Every dictionary has
// exactly en.js's keys, with the same {placeholders} and plural forms; Spanish and Italian count,
// write numbers, dates and times in their own way (Intl); the main screens render in each with no
// key left showing; alerts get their words; the microphone listens in the app's language.
//   node --test tests/app/

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import test from "node:test";

// Just enough of a browser for the views.
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
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  set textContent(text) {
    this.children = [document.createTextNode(String(text))];
  }
  replaceChildren(...children) {
    this.children = children;
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "" };
const root = { dataset: {} };
globalThis.document = {
  hidden: false,
  documentElement: root,
  body: { append() {} },
  addEventListener() {},
  removeEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => "" });
Object.defineProperty(globalThis, "navigator", { value: { userAgent: "Node", maxTouchPoints: 0, languages: ["en-US"], language: "en-US", onLine: true }, configurable: true });
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};
// Nothing here reaches a controller or a server.
globalThis.fetch = async () => {
  throw new TypeError("offline in this test");
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
globalThis.history = { state: null, back() {}, replaceState() {} };
// The browser's speech recognition: the language each one was set to listen in.
const listened = [];
globalThis.webkitSpeechRecognition = class {
  constructor() {
    listened.push(this);
  }
  start() {}
  abort() {
    this.onend?.();
  }
  stop() {
    this.onend?.();
  }
};

const i18n = await import("../../app/js/i18n.js");
const { LANGUAGES, formatDate, formatNumber, formatRelative, formatTemperature, languageInfo, resolveLanguage, setLanguage, t } = i18n;
const { state, ui } = await import("../../app/js/state.js");
const { homeView } = await import("../../app/js/views/home.js");
const { roomView } = await import("../../app/js/views/room.js");
const { climateView } = await import("../../app/js/views/climate.js");
const { camerasView } = await import("../../app/js/views/cameras.js");
const { scenesView } = await import("../../app/js/views/scenes.js");
const { SETTINGS_PAGES, settingsView } = await import("../../app/js/views/settings.js");
const { alertTexts } = await import("../../app/js/alerts.js");

const dictionaries = {};
for (const { code } of LANGUAGES) dictionaries[code] = (await import(`../../app/i18n/${code}.js`)).default;

// ---- the dictionaries ---------------------------------------------------------------------------

const FORMS = new Set(["zero", "one", "two", "few", "many", "other"]);
const isPlural = (value) => value && typeof value === "object" && Object.keys(value).length > 0 && Object.keys(value).every((form) => FORMS.has(form));
function strings(dictionary, prefix = "", out = new Map()) {
  for (const [key, value] of Object.entries(dictionary)) {
    const path = prefix ? `${prefix}.${key}` : key;
    if (value && typeof value === "object" && !isPlural(value)) strings(value, path, out);
    else out.set(path, value);
  }
  return out;
}
const placeholders = (value) => [...new Set((isPlural(value) ? Object.values(value) : [value]).flatMap((text) => String(text).match(/\{\w+\}/g) || []))].sort();
// commands.js gives a room as {room} and as {inRoom} (Hebrew's "בסלון"): a language uses either.
const CHOICES = { "command.example.lights": { "{room}": "{inRoom}" }, "command.example.climate": { "{room}": "{inRoom}" } };

test("four languages, each with its file, its direction and the microphone's language", () => {
  assert.deepEqual(
    LANGUAGES.map(({ code, label, dir, speech }) => [code, label, dir, speech]),
    [
      ["en", "English", "ltr", "en-US"],
      ["he", "עברית", "rtl", "he-IL"],
      ["es", "Español", "ltr", "es-ES"],
      ["it", "Italiano", "ltr", "it-IT"],
    ]
  );
  for (const { code } of LANGUAGES) assert.ok(existsSync(new URL(`../../app/i18n/${code}.js`, import.meta.url)), code);
  // Auto picks the browser's first language the app has.
  assert.equal(resolveLanguage("auto"), "en");
  navigator.languages = ["fr-FR", "es-419", "en"];
  assert.equal(resolveLanguage("auto"), "es");
  navigator.languages = ["it-CH"];
  assert.equal(resolveLanguage("auto"), "it");
  navigator.languages = ["en-US"];
});

test("every dictionary has exactly en.js's keys, with the same placeholders and plural forms", () => {
  const english = strings(dictionaries.en);
  assert.ok(english.size > 1900, `${english.size} strings`);
  for (const [code, dictionary] of Object.entries(dictionaries)) {
    if (code === "en") continue;
    const translated = strings(dictionary);
    assert.deepEqual([...english.keys()].filter((key) => !translated.has(key)), [], `${code}: missing`);
    assert.deepEqual([...translated.keys()].filter((key) => !english.has(key)), [], `${code}: extra`);
    for (const [key, source] of english) {
      const value = translated.get(key);
      assert.equal(isPlural(value), isPlural(source), `${code} ${key}: plural forms as in English`);
      if (isPlural(value)) {
        assert.ok("other" in value, `${code} ${key}: an "other" form`);
        if ("zero" in source) assert.ok("zero" in value, `${code} ${key}: a "zero" form`);
      } else {
        assert.equal(typeof value, typeof source, `${code} ${key}`);
      }
      const wanted = placeholders(source);
      const found = placeholders(value);
      const swapped = wanted.map((name) => CHOICES[key]?.[name] ?? name).sort();
      assert.ok(String(found) === String(wanted) || String(found) === String(swapped), `${code} ${key}: ${found} instead of ${wanted}`);
      // Never left in English by mistake: a sentence of three words or more is the language's own.
      if (code !== "he" && typeof source === "string" && /^[A-Z][a-z]+ [a-z]+ [a-z]+/.test(source)) {
        assert.notEqual(value, source, `${code} ${key} is still English`);
      }
    }
  }
});

test("the disclaimer, word for word in each language", () => {
  assert.equal(dictionaries.en.settings.about.independent, "DirectorLink is an independent project, not affiliated with Control4 or Snap One.");
  assert.equal(dictionaries.es.settings.about.independent, "DirectorLink es un proyecto independiente, sin afiliación con Control4 ni Snap One.");
  assert.equal(dictionaries.it.settings.about.independent, "DirectorLink è un progetto indipendente, non affiliato a Control4 né a Snap One.");
  assert.match(dictionaries.he.settings.about.independent, /^DirectorLink .*Control4.*Snap One/);
});

test("Spanish and Italian count, and write numbers, temperatures, dates and times their own way", async () => {
  const at = Date.parse("2026-10-05T12:00:00Z");
  try {
    for (const [code, one, many, ago] of [
      ["es", "1 luz encendida", "3 luces encendidas", /^hace 3 minutos$/],
      ["it", "1 luce accesa", "3 luci accese", /^3 minuti fa$/],
    ]) {
      assert.equal(await setLanguage(code), code);
      assert.equal(root.lang, code);
      assert.equal(root.dir, "ltr");
      assert.equal(t("home.lightsOn", { count: 1 }), one);
      assert.equal(t("home.lightsOn", { count: 3 }), many);
      // Numbers, temperatures and dates by Intl, in the language.
      assert.equal(formatNumber(1234.5), new Intl.NumberFormat(code).format(1234.5));
      assert.match(formatNumber(0.5), /^0,5$/);
      assert.equal(formatTemperature(21.5), "⁦21,5°⁩");
      assert.equal(formatDate(new Date(at)), new Intl.DateTimeFormat(code, { dateStyle: "medium" }).format(new Date(at)));
      assert.match(formatRelative(at - 3 * 60000, at), ago);
      assert.equal(languageInfo().speech, `${code}-${code.toUpperCase()}`);
    }
  } finally {
    await setLanguage("en");
  }
});

test("alerts: the service worker's words and their language are the app's", async () => {
  try {
    for (const [code, title, body] of [
      ["es", "Hay alguien en la puerta", "{name} sonó a las {time}."],
      ["it", "C’è qualcuno alla porta", "{name} ha suonato alle {time}."],
    ]) {
      await setLanguage(code);
      const texts = alertTexts();
      assert.equal(texts.lang, code);
      assert.equal(texts.dir, "ltr");
      assert.equal(texts.doorbell_title, title);
      assert.equal(texts.doorbell, body);
      for (const [name, text] of Object.entries(texts)) assert.ok(typeof text === "string" && !/^[a-z]+\.[a-zA-Z.]+$/.test(text), `${code} ${name}: ${text}`);
    }
  } finally {
    await setLanguage("en");
  }
});

// ---- the main screens --------------------------------------------------------------------------

const ROOMS = [
  { id: 10, name: "Kitchen", names: {} },
  { id: 11, name: "Living Room", names: {} },
];
const room = (id) => ({ id, name: ROOMS.find((item) => item.id === id).name });
function home() {
  Object.assign(state, {
    host: "192.0.2.10",
    apiKey: "ak_test",
    transport: "lan",
    status: "connected",
    loaded: true,
    online: true,
    role: "admin",
    access: null,
    errors: {},
    pending: {},
    rooms: structuredClone(ROOMS),
    lights: [
      { id: 20, name: "Island", room: room(10), on: true, dimmable: true, brightness: 70, brightness_reported: true },
      { id: 21, name: "Spots", room: room(11), on: false, dimmable: false, brightness: null, brightness_reported: false },
    ],
    thermostats: [
      { id: 30, name: "AC", room: room(11), mode: "cool", modes: ["off", "heat", "cool"], fan_speed: null, fan_speeds: [], current_temperature: 25, target_temperature: 23, target_temperature_min: 16, target_temperature_max: 30 },
    ],
    blinds: [{ id: 50, name: "Shutter", room: room(11), position: 40, position_reported: true, capabilities: { position: true, stop: true }, moving: false, direction: null, target_position: 40 }],
    fans: [],
    cameras: [{ id: 60, name: "Gate", room: room(10), snapshot_href: "/v1/cameras/60/snapshot" }],
    relays: [],
    doorbells: [],
    refrigerators: [],
    devices: [],
    scenes: [{ id: "0a1b2c3d", name: "Good night", steps: [], icon: "moon" }],
    profile: { id: "p1", prefs: { hidden_rooms: [], favorites: ["light:20"] } },
    system: { bridge: { version: "1.10.0" }, features: { users: true, backup: true } },
    account: { status: "signed-out", user: null, notice: null, busy: false },
    offlineCopy: "ready",
    canInstall: false,
    lastUpdated: new Date(),
  });
  ui.filter = null;
}

function texts(nodes) {
  const found = [];
  const visit = (node) => {
    if (!node) return;
    if (Array.isArray(node)) return node.forEach(visit);
    if (!(node instanceof FakeElement)) {
      if (node.textContent?.trim()) found.push(node.textContent.trim());
      return;
    }
    for (const name of ["aria-label", "title", "placeholder", "alt"]) if (node.attributes[name]) found.push(node.attributes[name]);
    node.children.forEach(visit);
  };
  visit(nodes);
  return found;
}

const actions = { openCamera() {}, openFavoritesPicker() {}, navigate() {} };
const SCREENS = {
  home: () => homeView(actions),
  room: () => roomView(11, actions),
  climate: () => climateView(actions),
  cameras: () => camerasView(actions),
  scenes: () => scenesView(actions),
  settings: () => settingsView({}),
  ...Object.fromEntries(SETTINGS_PAGES.map((page) => [`settings/${page}`, () => settingsView({ page, navigate() {} })])),
};
// A dictionary key shown as such: what t() gives for a key it does not know.
const KEY = new RegExp(`^(${Object.keys(dictionaries.en).join("|")})\\.[\\w.]+$`);

test("the main screens render in Spanish and Italian, with no key left showing", async () => {
  home();
  const english = {};
  for (const [name, screen] of Object.entries(SCREENS)) english[name] = texts(screen());
  try {
    for (const [code, words] of [
      ["es", { home: "Habitaciones", room: "Luces", climate: "Clima", cameras: "Cámaras", scenes: "Escenas", settings: "Ajustes", "settings/appearance": "Apariencia e idioma", "settings/about": "DirectorLink es un proyecto independiente" }],
      ["it", { home: "Stanze", room: "Luci", climate: "Clima", cameras: "Telecamere", scenes: "Scene", settings: "Impostazioni", "settings/appearance": "Aspetto e lingua", "settings/about": "DirectorLink è un progetto indipendente" }],
    ]) {
      await setLanguage(code);
      for (const [name, screen] of Object.entries(SCREENS)) {
        const shown = texts(screen());
        assert.ok(shown.length > 3, `${code} ${name} shows something`);
        assert.deepEqual(shown.filter((text) => KEY.test(text)), [], `${code} ${name}: keys shown`);
        assert.notDeepEqual(shown, english[name], `${code} ${name} is not in English`);
        if (words[name]) assert.ok(shown.some((text) => text.includes(words[name])), `${code} ${name}: “${words[name]}” in ${shown.join(" | ")}`);
      }
    }
  } finally {
    await setLanguage("en");
  }
});

test("Say or type a command: shown in every language, and the microphone listens in the app's", async () => {
  home();
  const find = (nodes, key) => {
    let found = null;
    const visit = (node) => {
      if (found || !node) return;
      if (Array.isArray(node)) return node.forEach(visit);
      if (node.dataset?.key === key) found = node;
      (node.children || []).forEach(visit);
    };
    visit(nodes);
    return found;
  };
  try {
    for (const [code, speech, placeholder] of [
      ["en", "en-US", "Say or type a command"],
      ["he", "he-IL", "אמרו או הקלידו פקודה"],
      ["es", "es-ES", "Di o escribe un comando"],
      ["it", "it-IT", "Pronuncia o scrivi un comando"],
    ]) {
      await setLanguage(code);
      const screen = homeView(actions);
      assert.ok(texts(screen).includes(placeholder), `${code}: the field, in its words`);
      assert.ok(find(climateView(actions), "command-open"), `${code}: the header's button`);
      const mic = find(screen, "command-mic:home");
      assert.ok(mic, `${code}: the microphone`);
      mic.listeners.click[0]({ preventDefault() {}, currentTarget: mic, target: mic });
      assert.equal(listened.at(-1).lang, speech);
      listened.at(-1).abort();
    }
  } finally {
    await setLanguage("en");
  }
});
