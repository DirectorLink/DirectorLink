// Say or type a command on iPhone (1.9.0, ADR-063): Safari has speech recognition, the Home Screen
// app lists it too but WebKit does not listen there, so the app shows no microphone and its field
// says to use the keyboard's own microphone (dictation types into the field). A browser that
// refuses its speech service hides the microphone from then on.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

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
  removeAttribute(name) {
    delete this.attributes[name];
  }
  append(...children) {
    this.children.push(...children);
  }
  replaceChildren(...children) {
    this.children = children;
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  set textContent(text) {
    this.children = [Object.assign(new FakeNode(), { textContent: String(text) })];
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
let homeScreen = true;
window.matchMedia = (query) => ({ matches: query === "(display-mode: standalone)" && homeScreen, addEventListener() {}, removeEventListener() {} });
globalThis.document = {
  hidden: false,
  body: new FakeElement("body"),
  documentElement: {},
  addEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1", maxTouchPoints: 5, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
Object.defineProperty(globalThis, "localStorage", { value: { getItem: () => null, setItem() {}, removeItem() {}, clear() {} }, configurable: true });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);
const started = [];
globalThis.webkitSpeechRecognition = class {
  start() {
    started.push(this);
  }
};

const { state, notify } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { homeView } = await import("../../app/js/views/home.js");

function byKey(nodes, key) {
  let found = null;
  const walk = (list) => {
    for (const node of [list].flat(Infinity)) {
      if (!node || found) continue;
      if (node.dataset?.key === key) found = node;
      walk(node.children || []);
    }
  };
  walk(nodes);
  return found;
}
const home = () => homeView({ openCamera() {}, openFavoritesPicker() {} });

test("the Home Screen app on iPhone: no microphone; the keyboard's own microphone instead", async () => {
  await setLanguage("en");
  Object.assign(state, { host: "controller.invalid", apiKey: "ak_test", role: "member", status: "connected", loaded: true, rooms: [{ id: 1, name: "Kitchen" }], lights: [], thermostats: [], scenes: [] });
  notify();
  homeScreen = true;
  assert.equal(byKey(home(), "command-mic:home"), null);
  assert.equal(byKey(home(), "command-input:home").attributes.placeholder, "Type or dictate a command");
  await setLanguage("he");
  assert.equal(byKey(home(), "command-input:home").attributes.placeholder, "הקלידו או הכתיבו פקודה");
  await setLanguage("en");
});

test("Safari on iPhone: the microphone; refused by the speech service, it goes", async () => {
  homeScreen = false;
  const mic = byKey(home(), "command-mic:home");
  assert.ok(mic, "Safari listens");
  assert.equal(mic.attributes["aria-label"], "Speak a command");
  for (const listener of mic.listeners.click) listener({ stopPropagation() {} });
  assert.equal(started.length, 1);
  // Siri and Dictation are off: the service is not allowed.
  started[0].onerror({ error: "service-not-allowed" });
  started[0].onend();
  assert.equal(byKey(home(), "command-mic:home"), null, "no microphone from then on");
  assert.equal(byKey(home(), "command-input:home").attributes.placeholder, "Type or dictate a command");
});
