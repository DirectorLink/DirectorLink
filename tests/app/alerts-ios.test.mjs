// Alerts on iPhone and iPad (ADR-047, app/js/views/alerts.js): Safari gets Web Push only in the app
// added to the Home Screen, from iOS 16.4. In a Safari tab the card says how to add it; added on an
// older iOS, which version it needs. Its own process: the app reads whether it runs on iOS once.
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
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener() {}
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}

const stored = new Map();
let standalone = false;
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.matchMedia = (query) => ({ matches: query === "(display-mode: standalone)" && standalone, addEventListener() {} });
window.isSecureContext = true;
globalThis.document = {
  hidden: false,
  documentElement: {},
  addEventListener() {},
  querySelector: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
Object.defineProperty(globalThis, "localStorage", {
  value: { getItem: (key) => (stored.has(key) ? stored.get(key) : null), setItem: (key, value) => stored.set(key, String(value)), removeItem: (key) => stored.delete(key) },
  configurable: true,
});
// Safari on an iPhone: no PushManager and no Notification in a tab.
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", maxTouchPoints: 5, languages: ["en"], language: "en", onLine: true, serviceWorker: {} },
  configurable: true,
});
globalThis.fetch = async () => {
  throw new TypeError("offline in this test");
};

const { state } = await import("../../app/js/state.js");
const { saveRemote } = await import("../../app/js/remote.js");
const { alertsPanel } = await import("../../app/js/views/alerts.js");

function byKey(node, key) {
  if (!node) return null;
  if (node.dataset?.key === key) return node;
  for (const child of node.children || []) {
    const found = byKey(child, key);
    if (found) return found;
  }
  return null;
}

test("on iPhone and iPad the card says to add the app to the Home Screen, or which iOS it needs", () => {
  Object.assign(state, { apiKey: "ak_test", role: "admin", status: "connected", account: { status: "signed-in", user: { id: "u1" } } });
  saveRemote({ home: "0123456789abcdef0123456789abcdef", keyId: "0a1b2c3d" });

  const tab = alertsPanel();
  assert.equal(byKey(tab, "alerts-switch").attributes["aria-disabled"], "true", "the switch cannot be used in a Safari tab");
  assert.equal(byKey(tab, "alerts-hint").textContent, "On iPhone and iPad, alerts work only in the app on the Home Screen (iOS 16.4 or later): tap Share, then Add to Home Screen, open DirectorLink from there and switch them on.");

  standalone = true;
  const added = alertsPanel();
  assert.equal(byKey(added, "alerts-hint").textContent, "Alerts need iOS 16.4 or later on this device.");

  // iOS 16.4 and later, from the Home Screen: push is there, and so is the switch.
  window.PushManager = function PushManager() {};
  globalThis.Notification = { permission: "default", requestPermission: async () => "granted" };
  const ready = alertsPanel();
  assert.equal(byKey(ready, "alerts-hint"), null);
  assert.equal(byKey(ready, "alerts-switch").attributes["aria-disabled"], undefined);
});
