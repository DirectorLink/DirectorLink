// The pairing screen (app/js/views/connect.js, 1.3.0): the warning that the code would travel
// unprotected belongs to the controller it was about, says why (an older DirectorLink, or a lock
// that failed its self-test), goes with Cancel, and goes when another address is typed or found;
// and its buttons are named apart in every language. Rendered into a small fake DOM.
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test, { mock } from "node:test";

import { fakeController } from "./fake-controller.mjs";

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
  // The value of a field: as set (typed), or its attribute.
  get value() {
    return this.typed ?? this.attributes.value ?? "";
  }
  set value(text) {
    this.typed = String(text);
  }
  addEventListener(type, listener) {
    this.listeners[type] = listener;
  }
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  all(match) {
    const found = match(this) ? [this] : [];
    for (const child of this.children) if (child instanceof FakeElement) found.push(...child.all(match));
    return found;
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "#/" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: {},
  activeElement: null,
  addEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: {
    userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    userAgentData: { brands: [{ brand: "Chromium", version: "141" }] },
    maxTouchPoints: 0,
    languages: ["en"],
    language: "en",
    onLine: true,
  },
  configurable: true,
});
const stored = new Map();
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
  },
  configurable: true,
});
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);
const logError = console.error;
console.error = (message, ...rest) => {
  if (message !== "DirectorLink connection failed") logError(message, ...rest);
};

const OLD = "192.168.1.10";
const NEW = "192.168.1.11";
let controller = fakeController({ version: "1.2.0" });
globalThis.fetch = (url, init) => {
  const host = new URL(url).hostname;
  if (host !== OLD && host !== NEW) return Promise.reject(new TypeError(`blocked: ${url}`));
  return controller.fetch(url, init);
};

const { state, ui } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const { setLanguage, t } = await import("../../app/js/i18n.js");
const { connectScreen } = await import("../../app/js/views/connect.js");
const { addressChanged } = await import("../../app/js/views/find.js");

const byKey = (root, key) => root.all((element) => element.dataset.key === key)[0];
const byId = (root, id) => root.all((element) => element.attributes.id === id)[0];
const screen = () => connectScreen();

async function warnedAbout(host, options = { version: "1.2.0" }) {
  session.forgetKey();
  controller = fakeController(options);
  Object.assign(state, { notice: null, pairingUnprotected: null, status: "setup" });
  ui.drafts = { host };
  await session.pairWithCode(host, "1234 5678");
}

test("the redraw notices the warning (Cancel only clears it)", () => {
  // app.js redraws only when its signature changes: everything the pairing screen reads from the
  // state is in it, apart from what only its buttons read and the typed drafts.
  const app = readFileSync(new URL("../../app/app.js", import.meta.url), "utf8");
  const signature = app.slice(app.indexOf("function signature()"), app.indexOf("function screen()"));
  const read = new Set();
  for (const path of ["../../app/js/views/connect.js", "../../app/js/views/find.js"]) {
    const text = readFileSync(new URL(path, import.meta.url), "utf8");
    for (const [, field] of text.matchAll(/(?<![\w./])state\.(?!js\b)(\w+)/g)) read.add(field);
  }
  for (const field of ["apiKey", "host"]) read.delete(field);
  assert.ok(read.has("pairingUnprotected"));
  for (const field of read) assert.ok(signature.includes(`state.${field}`), `app.js's signature() must include state.${field}`);
});

test("the warning shows for the controller it is about, and Pair anyway pairs that one", async () => {
  await setLanguage("en");
  await warnedAbout(OLD);
  let view = screen();
  const warning = byId(view, "pairing-unprotected");
  assert.ok(warning, "shown");
  assert.match(warning.textContent, /older DirectorLink/);

  // Another address in the field (before a redraw): Pair anyway still pairs the one it was about.
  const pairAnyway = byKey(view, "pair-anyway");
  ui.drafts.host = NEW;
  byId(view, "pairing-code").value = "1234 5678";
  await pairAnyway.listeners.click();
  assert.equal(controller.hosts.at(-1), OLD);
  assert.equal(controller.requests.at(-1).pairing_code, "12345678");

  await warnedAbout(OLD);
  ui.drafts.host = NEW;
  assert.equal(byId(screen(), "pairing-unprotected"), undefined, "not shown for another address");
});

test("Cancel, typing another address, or finding another controller clears the warning", async () => {
  await warnedAbout(OLD);
  byKey(screen(), "pair-cancel").listeners.click();
  assert.equal(state.pairingUnprotected, null);
  assert.equal(byId(screen(), "pairing-unprotected"), undefined);

  await warnedAbout(OLD);
  const field = byId(screen(), "controller-host");
  field.value = `${OLD}1`;
  field.listeners.input();
  assert.equal(state.pairingUnprotected, null, "typed");

  await warnedAbout(OLD);
  state.notice = { kind: "error", text: "Could not reach DirectorLink" };
  addressChanged(OLD);
  assert.ok(state.pairingUnprotected, "the same controller found again keeps it");
  assert.equal(state.notice, null, "an older error goes");
  addressChanged(NEW);
  assert.equal(state.pairingUnprotected, null, "found another");
});

test("a 1.3.0 controller whose lock failed is told apart: nothing to update", async () => {
  for (const language of ["en", "he"]) {
    await setLanguage(language);
    await warnedAbout(OLD, { lock: false });
    const text = byId(screen(), "pairing-unprotected").textContent;
    assert.equal(text.includes(t("connect.unprotected.lock")), true, language);
    assert.notEqual(t("connect.unprotected.lock"), t("connect.unprotected.older"));
  }
  await setLanguage("en");
  assert.match(t("connect.unprotected.lock"), /nothing to update/);
  assert.doesNotMatch(t("connect.unprotected.lock"), /Update DirectorLink/);
});

test("the pairing screen's buttons have names of their own, in every language", async () => {
  for (const language of ["en", "he"]) {
    await setLanguage(language);
    await warnedAbout(OLD);
    state.account = { status: "signed-out", user: null, notice: null };
    const names = screen()
      .all((element) => element.tagName === "BUTTON")
      .map((button) => button.textContent.trim());
    assert.ok(names.length >= 5, names.join(" | "));
    assert.equal(new Set(names).size, names.length, `${language}: ${names.join(" | ")}`);
  }
  await setLanguage("he");
  assert.notEqual(t("connect.pair"), t("connect.signInShort"));
  assert.notEqual(t("connect.title").split(" ")[0], t("connect.signInShort"), "connecting to the home is not signing in");
  await setLanguage("en");
});
