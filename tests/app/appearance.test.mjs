// Settings → Appearance and language (1.10.0, ADR-067): one row on Settings' list instead of the
// language, theme and colours at its top; the page with Language, Theme and colours and Text size;
// what it says follows the user; the choices it hands to app.js; the text size kept on this device
// (never in the profile), applied at once and before the first paint (theme-boot.js).
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

// Just enough of a browser for these modules.
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
  dispatch(type) {
    const event = { type, currentTarget: this, target: this, preventDefault() {} };
    for (const listener of this.listeners[type] || []) listener(event);
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
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/#/settings", pathname: "/", search: "", hash: "#/settings" };
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
globalThis.fetch = async () => {
  throw new TypeError("offline in this test");
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);

const { state } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { TEXT_SIZES, applyTheme, setPalette, setTextSize, setTheme, textSizePreference } = await import("../../app/js/theme.js");
const { SETTINGS_PAGES, settingsView } = await import("../../app/js/views/settings.js");

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
function find(nodes, check) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node instanceof FakeElement && check(node)) found = node;
  });
  return found;
}
const byKey = (nodes, key) => find(nodes, (node) => node.dataset.key === key);
const byClass = (nodes, name) => find(nodes, (node) => typeof node.className === "string" && node.className.split(/\s+/).includes(name));
const rows = (list) => keysOf(list).filter((key) => key.startsWith("settings-row:"));
const rowStatus = (list) => byClass(byKey(list, "settings-row:appearance"), "settings-row-status")?.textContent ?? null;
// The page's cards, in order (their ids).
const cards = (page) => (page[2].children || []).filter((node) => node?.tagName === "SECTION").map((card) => card.attributes.id);

function home(profile = { id: "p1", prefs: {} }) {
  Object.assign(state, {
    host: "192.0.2.10",
    apiKey: "ak_test",
    transport: "lan",
    status: "connected",
    loaded: true,
    online: true,
    role: "admin",
    rooms: [{ id: 10, name: "Kitchen", names: {} }],
    profile,
    system: { bridge: { version: "1.10.0" }, features: { users: true } },
    account: { status: "signed-out", user: null, notice: null, busy: false },
    offlineCopy: "ready",
    canInstall: false,
  });
}

function reset() {
  for (const key of ["directorlink.lang", "directorlink.theme", "directorlink.palette", "directorlink.textSize"]) stored.delete(key);
  applyTheme();
}

test("Settings' list has a row for Appearance and language, and no longer the choices themselves", async () => {
  reset();
  home();
  const list = settingsView({});
  assert.deepEqual(rows(list), [
    "settings-row:controller",
    "settings-row:rooms",
    "settings-row:access",
    "settings-row:account",
    "settings-row:alerts",
    "settings-row:appearance",
    "settings-row:app",
    "settings-row:about",
  ]);
  const keys = keysOf(list);
  for (const prefix of ["language-", "theme-", "palette-", "text-size-"]) {
    assert.ok(!keys.some((key) => key.startsWith(prefix)), `no ${prefix}… on the list`);
  }
  const row = byKey(list, "settings-row:appearance");
  assert.equal(row.attributes.href, "#/settings/appearance");
  assert.ok(SETTINGS_PAGES.includes("appearance"));
  assert.equal(byClass(row, "settings-row-title").textContent, "Appearance and language");
  // The line: the language shown, the theme, the colours; the text size only when not the default.
  assert.equal(rowStatus(list), "English · Auto · Graphite");
  setTheme("dark");
  setPalette("ocean");
  setTextSize("larger");
  assert.equal(rowStatus(settingsView({})), "English · Dark · Ocean · Larger text");
  await setLanguage("he");
  try {
    assert.equal(byClass(byKey(settingsView({}), "settings-row:appearance"), "settings-row-title").textContent, "מראה ושפה");
    assert.equal(rowStatus(settingsView({})), "עברית · כהה · אוקיינוס · טקסט גדול יותר");
  } finally {
    await setLanguage("en");
    reset();
  }
  // The disclaimer still ends the list.
  assert.ok(byKey(settingsView({}), "settings-independent"));
});

test("the page: Language, Theme and colours, Text size, and what follows the user", async () => {
  reset();
  home();
  const page = settingsView({ page: "appearance" });
  assert.equal(page[0].tagName, "HEADER");
  assert.ok(byKey(page, "back"), "Back to the list");
  assert.deepEqual(cards(page), ["settings-language", "settings-appearance", "settings-text-size"]);
  const keys = keysOf(page);
  for (const key of ["language-auto", "language-en", "language-he", "language-es", "language-it", "theme-auto", "theme-light", "theme-dark", "palette-graphite", "palette-midnight", "text-size-small", "text-size-default", "text-size-large", "text-size-larger"]) {
    assert.ok(keys.includes(key), key);
  }
  // Each language in its own words and direction.
  const name = (code) => byClass(find(page, (node) => node.tagName === "LABEL" && node.attributes.for === `language-${code}`), "radio-label");
  assert.equal(name("es").textContent, "Español");
  assert.equal(name("es").attributes.lang, "es");
  assert.deepEqual([name("he").textContent, name("he").attributes.lang, name("he").attributes.dir], ["עברית", "he", "rtl"]);
  assert.deepEqual([name("it").textContent, name("it").attributes.lang], ["Italiano", "it"]);
  // Auto says which one it found.
  assert.equal(find(page, (node) => node.tagName === "LABEL" && node.attributes.for === "language-auto").textContent, "AutoEnglish");
  // The choices made (h() sets `checked` as an attribute on these fake elements).
  const checked = (key) => "checked" in byKey(page, key).attributes;
  assert.deepEqual(["language-auto", "theme-auto", "palette-graphite", "text-size-default"].map(checked), [true, true, true, true]);
  assert.deepEqual(["language-en", "text-size-larger"].map(checked), [false, false]);
  // With a profile: what follows the user, and what does not.
  assert.equal(byKey(page, "appearance-follows").textContent, "Your language, theme and colours follow you to all your devices. The text size is for this device only.");
  // Not connected (no profile): kept here.
  home(null);
  assert.match(byKey(settingsView({ page: "appearance" }), "appearance-follows").textContent, /^Kept on this device\./);
  // Each text size is written at the size it gives.
  const sample = find(page, (node) => node.className === "text-size-sample" && node.dataset.size === "larger");
  assert.equal(sample.textContent, "Larger");
});

test("choosing hands the choice to app.js: language, theme and colours to the profile, the text size not", () => {
  reset();
  home();
  const chosen = [];
  const page = settingsView({
    page: "appearance",
    onLanguage: (value) => chosen.push(["language", value]),
    onTheme: (value) => chosen.push(["theme", value]),
    onPalette: (value) => chosen.push(["palette", value]),
    onTextSize: (value) => chosen.push(["textSize", value]),
  });
  for (const key of ["language-it", "theme-light", "palette-forest", "text-size-large"]) byKey(page, key).listeners.change[0]();
  assert.deepEqual(chosen, [["language", "it"], ["theme", "light"], ["palette", "forest"], ["textSize", "large"]]);
  // app.js: the text size is set on this device and the screen redrawn, never saved to the profile;
  // language, theme and colours are.
  const app = readFileSync(new URL("../../app/app.js", import.meta.url), "utf8");
  const handler = app.match(/onTextSize: \(size\) => \{([^}]*)\}/);
  assert.ok(handler, "app.js hands Settings an onTextSize");
  assert.match(handler[1], /setTextSize\(size\)/);
  assert.match(handler[1], /render\(true\)/);
  assert.doesNotMatch(handler[1], /saveProfilePrefs/);
  for (const field of ["language", "theme", "palette"]) assert.match(app, new RegExp(`saveProfilePrefs\\(\\{ ${field} \\}\\)`));
  // The profile's first save (js/profile.js) takes this browser's language, theme and colours, not its text size.
  const profile = readFileSync(new URL("../../app/js/profile.js", import.meta.url), "utf8");
  assert.doesNotMatch(profile, /textSize|text_size/);
});

test("the text size is this device's: kept in localStorage, applied at once, unknown values are the default", () => {
  reset();
  assert.deepEqual(TEXT_SIZES, ["small", "default", "large", "larger"]);
  assert.equal(textSizePreference(), "default");
  assert.equal(root.dataset.textSize, "default");
  setTextSize("large");
  assert.equal(stored.get("directorlink.textSize"), "large");
  assert.equal(root.dataset.textSize, "large", "applied at once, on every screen");
  setTextSize("huge");
  assert.equal(textSizePreference(), "large", "an unknown size changes nothing");
  stored.set("directorlink.textSize", "enormous");
  assert.equal(textSizePreference(), "default");
  applyTheme();
  assert.equal(root.dataset.textSize, "default");
  reset();
});

test("styles.css: the root font size follows the text size, and every font size is in rem", () => {
  const css = readFileSync(new URL("../../app/styles.css", import.meta.url), "utf8");
  assert.match(css, /html \{[^}]*font-size: calc\(100% \* var\(--text-scale\)\);/);
  for (const [size, scale] of [["small", "0.9375"], ["large", "1.125"], ["larger", "1.25"]]) {
    assert.match(css, new RegExp(`:root\\[data-text-size="${size}"\\] \\{ --text-scale: ${scale}; \\}`));
  }
  // Only the samples on the Text size card are in px: they show each size whatever is chosen.
  const pixels = [...css.matchAll(/([^{}]+)\{[^}]*font-size: \d+px/g)].map((match) => match[1].trim());
  assert.ok(pixels.length >= 4);
  for (const selector of pixels) assert.match(selector, /^\.text-size-sample/, selector);
});

// ---- before the first paint ----------------------------------------------------------------------

// Runs theme-boot.js as the browser does, in a page with this storage and these browser languages.
function boot({ saved = {}, languages = ["en-US"], dark = false } = {}) {
  const attributes = {};
  const meta = { attributes: {}, setAttribute(name, value) { this.attributes[name] = value; } };
  const context = {
    document: {
      documentElement: { setAttribute: (name, value) => (attributes[name] = value) },
      querySelector: (selector) => (selector === 'meta[name="theme-color"]' ? meta : null),
    },
    window: { matchMedia: () => ({ matches: dark }) },
    navigator: { languages, language: languages[0] },
    localStorage: { getItem: (key) => (key in saved ? saved[key] : null) },
  };
  vm.runInNewContext(readFileSync(new URL("../../app/theme-boot.js", import.meta.url), "utf8"), context);
  return { attributes, themeColor: meta.attributes.content };
}

test("theme-boot.js: the saved text size, palette, theme and language before the first paint", () => {
  assert.equal(boot().attributes["data-text-size"], "default");
  assert.equal(boot({ saved: { "directorlink.textSize": "larger" } }).attributes["data-text-size"], "larger");
  assert.equal(boot({ saved: { "directorlink.textSize": "small" } }).attributes["data-text-size"], "small");
  assert.equal(boot({ saved: { "directorlink.textSize": "giant" } }).attributes["data-text-size"], "default");
  const dark = boot({ saved: { "directorlink.palette": "plum", "directorlink.theme": "dark" } });
  assert.equal(dark.attributes["data-palette"], "plum");
  assert.equal(dark.attributes["data-theme"], "dark");
  assert.equal(dark.themeColor, "#140f19");
  // The language: saved, else the browser's first one DirectorLink has; English keeps index.html's.
  assert.deepEqual([boot().attributes.lang, boot().attributes.dir], [undefined, undefined]);
  for (const [saved, languages, lang, dir] of [
    ["he", ["en-US"], "he", "rtl"],
    ["es", ["he-IL"], "es", "ltr"],
    ["it", ["en"], "it", "ltr"],
    ["auto", ["es-MX", "en"], "es", "ltr"],
    [null, ["fr-FR", "it-CH", "he"], "it", "ltr"],
    [null, ["iw"], "he", "rtl"],
    ["fr", ["fr-FR", "es"], "es", "ltr"],
  ]) {
    const { attributes } = boot({ saved: saved ? { "directorlink.lang": saved } : {}, languages });
    assert.deepEqual([attributes.lang, attributes.dir], [lang, dir], `${saved} ${languages}`);
  }
  assert.equal(boot({ languages: ["en-GB", "es"] }).attributes.lang, undefined, "English first: English");
});
