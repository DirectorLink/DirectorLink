// A device whose browser lost its alerts (1.9.0, ADR-062; app/js/alerts.js, sw.js): the browser
// dropped its push subscription and will not make another without a tap (found at start, or after
// the service worker's pushsubscriptionchange), the permission was taken back in the browser's
// settings, or the account service refused the registration. The switch shows off, the account
// service forgets the browser, and the controller is told that this device's alerts are off: now,
// or once it can be (its system read, the home in reach), so that an ask-to-open link never counts
// this device as asked. Its own process: the registration is made again once per start. Against a
// fake account service, a fake home behind it (sealed requests) and a fake browser push manager.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import { deriveLock, open, seal } from "../../app/js/lock.js";

const HOME = "0123456789abcdef0123456789abcdef";
const KEY_ID = "0a1b2c3d";
const PUBLIC_KEY = Buffer.concat([Buffer.from([4]), Buffer.alloc(64, 7)]).toString("base64url");

// ---- just enough of a browser ------------------------------------------------------------------

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
}

const stored = new Map();
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/#/", pathname: "/", search: "", hash: "#/" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {} });
window.isSecureContext = true;
window.PushManager = function PushManager() {};
globalThis.history = { state: null, replaceState() {} };
globalThis.document = {
  hidden: false,
  documentElement: {},
  addEventListener() {},
  removeEventListener() {},
  querySelector: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
  },
  configurable: true,
});

// The browser: its permission, its subscription, and whether it makes a new one without a tap
// (`subscribes`: Safari on iPhone does not).
const browser = { permission: "granted", subscription: null, subscribes: true, made: 0, unsubscribed: [] };
globalThis.Notification = {
  get permission() {
    return browser.permission;
  },
  requestPermission: async () => browser.permission,
};
function subscription() {
  browser.made += 1;
  const endpoint = `https://web.push.apple.com/device-${browser.made}`;
  const made = {
    endpoint,
    options: { userVisibleOnly: true, applicationServerKey: Uint8Array.from(Buffer.from(PUBLIC_KEY, "base64url")).buffer },
    toJSON: () => ({ endpoint, expirationTime: null, keys: { p256dh: `p256dh-${browser.made}`, auth: `auth-${browser.made}` } }),
    unsubscribe: async () => {
      browser.unsubscribed.push(endpoint);
      if (browser.subscription === made) browser.subscription = null;
      return true;
    },
  };
  return made;
}
const registration = {
  pushManager: {
    getSubscription: async () => browser.subscription,
    subscribe: async () => {
      if (!browser.subscribes) throw new DOMException("A user gesture is needed", "NotAllowedError");
      browser.subscription = subscription();
      return browser.subscription;
    },
  },
};
// The service worker's messages to the app (sw.js posts directorlink-push-changed).
const workerListeners = [];
Object.defineProperty(globalThis, "navigator", {
  value: {
    userAgent: "Mozilla/5.0 (Windows NT 10.0) Chrome/140",
    maxTouchPoints: 0,
    languages: ["en"],
    language: "en",
    onLine: true,
    serviceWorker: {
      ready: Promise.resolve(registration),
      getRegistration: async () => registration,
      addEventListener: (type, listener) => type === "message" && workerListeners.push(listener),
    },
  },
  configurable: true,
});
const fromWorker = (data) => workerListeners.forEach((listener) => listener({ data }));

const cacheStorage = new Map();
globalThis.caches = {
  open: async (name) => {
    if (!cacheStorage.has(name)) cacheStorage.set(name, new Map());
    const entries = cacheStorage.get(name);
    return {
      put: async (path, response) => entries.set(path, await response.text()),
      match: async (path) => (entries.has(path) ? new Response(entries.get(path)) : undefined),
      delete: async (path) => entries.delete(path),
    };
  },
};
const savedAlertKey = () => JSON.parse(cacheStorage.get("directorlink-alerts")?.get("/alert-key.json") ?? "null");

// The home behind the account service, while `online`: this key's alert choices, as the controller
// keeps them.
const home = { online: true, requests: [], choices: { on: true, kinds: { doorbell: true } } };
async function homeAnswer(body) {
  const lock = await deriveLock(state.apiKey);
  const envelope = JSON.parse(body).envelope;
  const request = JSON.parse(await open(lock, envelope, "req"));
  home.requests.push({ method: request.method, path: request.path, body: request.body });
  let answer = { id: envelope.key };
  if (request.path === "/v1/alerts/choices") {
    if (request.method === "PUT" && typeof request.body.on === "boolean") home.choices.on = request.body.on;
    answer = structuredClone(home.choices);
  }
  const sealed = { id: request.id, ts: Math.floor(Date.now() / 1000), status: 200, content_type: "application/json", body: JSON.stringify(answer) };
  return { envelope: await seal(lock, { home: HOME, key: envelope.key }, "res", JSON.stringify(sealed)) };
}
const told = () => home.requests.filter((request) => request.method === "PUT" && request.path === "/v1/alerts/choices").map((request) => request.body);

// The account service: every call, and what POST /alerts answers next.
const cloud = { calls: [], posts: [] };
globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname } = new URL(url);
  if (hostname !== "api.directorlink.io") throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  cloud.calls.push({ method, path: pathname, body: init.body ? JSON.parse(init.body) : null });
  const reply = (status, body) => new Response(body === null ? null : JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
  if (pathname === `/v1/homes/${HOME}/alerts`) {
    if (method === "GET") return reply(200, { public_key: PUBLIC_KEY });
    if (method === "POST") return reply(...(cloud.posts.shift() ?? [201, { alerts: true }]));
    if (method === "DELETE") return reply(204, null);
  }
  if (pathname === `/v1/homes/${HOME}/e2e`) return home.online ? reply(200, await homeAnswer(init.body)) : reply(503, { code: "HOME_OFFLINE" });
  return reply(404, { code: "NOT_FOUND" });
};
const deleted = () => cloud.calls.filter((call) => call.method === "DELETE" && call.path === `/v1/homes/${HOME}/alerts`).map((call) => call.body.endpoint);

const { state, notify } = await import("../../app/js/state.js");
const { saveRemote } = await import("../../app/js/remote.js");
const { alertsOn, turnAlertsOn } = await import("../../app/js/alerts.js");

const LOST = "directorlink.alerts.lost";
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// Until `check` holds (a fixed wait is too short on a busy machine), at most 5 s.
async function until(check, what) {
  for (let waited = 0; waited < 5000; waited += 20) {
    if (check()) return;
    await wait(20);
  }
  assert.fail(`timed out waiting for ${what}`);
}

// A member's device linked to the home through the account, signed in; its controller's system
// read (DirectorLink 1.7.0 or later) unless `system` is false.
function device({ system = true } = {}) {
  Object.assign(state, {
    apiKey: "ak_test",
    role: "member",
    status: "connected",
    transport: "remote",
    system: system ? { features: { alert_choices: true } } : null,
    account: { status: "signed-in", user: { id: "u1" }, notice: null, busy: false },
  });
  saveRemote({ home: HOME, keyId: KEY_ID });
}

// This browser has alerts on for the home, and so does the controller.
async function alertsAreOn() {
  device();
  browser.subscribes = true;
  browser.permission = "granted";
  await turnAlertsOn();
  assert.equal(alertsOn(), true);
  assert.equal(home.choices.on, true);
  home.requests.length = 0;
  cloud.calls.length = 0;
}

// ---- tests (in order: the first start registers again once) ------------------------------------

test("at start, a browser that dropped its subscription shows alerts off and tells the controller once its system is read", async () => {
  // As the last start left it: alerts on, here and on the controller.
  browser.subscription = null;
  browser.subscribes = false;
  localStorage.setItem("directorlink.alerts", JSON.stringify({ home: HOME, endpoint: "https://web.push.apple.com/device-old", keyId: KEY_ID }));
  // Signed in to the account before the controller's system is read (the app's start).
  device({ system: false });
  notify();
  await until(() => !alertsOn() && deleted().length === 1, "the switch off");
  assert.deepEqual(deleted(), ["https://web.push.apple.com/device-old"], "the account service forgets the browser");
  assert.equal(savedAlertKey(), null, "the alert key goes");
  assert.deepEqual(told(), [], "the controller is not told before its system is read");
  assert.deepEqual(JSON.parse(localStorage.getItem(LOST)), { home: HOME, keyId: KEY_ID }, "it is still to be told");

  // The system is read: the controller is told, once.
  state.system = { features: { alert_choices: true } };
  notify();
  await until(() => told().length === 1, "the controller told");
  assert.deepEqual(told(), [{ on: false }]);
  assert.equal(home.choices.on, false);
  assert.equal(localStorage.getItem(LOST), null);
  notify();
  await wait(50);
  assert.equal(told().length, 1, "said once");
});

test("after the service worker's pushsubscriptionchange, an open app tells the controller when no subscription can be made", async () => {
  await alertsAreOn();
  // The browser dropped it (sw.js posts this from pushsubscriptionchange); Safari makes no new one.
  browser.subscription = null;
  browser.subscribes = false;
  fromWorker({ type: "directorlink-push-changed" });
  await until(() => told().length === 1, "the controller told");
  assert.deepEqual(told(), [{ on: false }]);
  assert.equal(alertsOn(), false);
  assert.equal(deleted().length, 1);
  assert.equal(localStorage.getItem(LOST), null, "told: nothing left to tell");
});

test("after pushsubscriptionchange, a browser that makes a new subscription by itself registers it and stays on", async () => {
  await alertsAreOn();
  const old = browser.subscription.endpoint;
  browser.subscription = null;
  fromWorker({ type: "directorlink-push-changed" });
  await until(() => cloud.calls.some((call) => call.method === "POST"), "the new registration");
  await until(() => deleted().length === 1, "the old one unregistered");
  assert.deepEqual(deleted(), [old]);
  assert.equal(alertsOn(), true);
  assert.deepEqual(told(), [], "nothing to tell: alerts are still on");
  fromWorker({ type: "something-else" });
  await wait(50);
  assert.equal(cloud.calls.filter((call) => call.method === "POST").length, 1, "only its own message counts");
});

test("alerts turned off in the browser's settings: the controller is told at the next look", async () => {
  await alertsAreOn();
  browser.permission = "denied";
  fromWorker({ type: "directorlink-push-changed" });
  await until(() => told().length === 1, "the controller told");
  assert.deepEqual(told(), [{ on: false }]);
  assert.equal(alertsOn(), false);
  assert.equal(localStorage.getItem(LOST), null);
  browser.permission = "granted";
});

test("a refused registration tells the controller too", async () => {
  await alertsAreOn();
  cloud.posts.push([403, { code: "NOT_A_MEMBER" }]);
  fromWorker({ type: "directorlink-push-changed" });
  await until(() => told().length === 1, "the controller told");
  assert.deepEqual(told(), [{ on: false }]);
  assert.equal(alertsOn(), false);
  assert.equal(browser.subscription, null, "the subscription is dropped");
});

test("a controller out of reach is told a minute later; alerts switched on again meanwhile end it", async () => {
  await alertsAreOn();
  home.online = false;
  browser.subscription = null;
  browser.subscribes = false;
  fromWorker({ type: "directorlink-push-changed" });
  await until(() => !alertsOn() && localStorage.getItem(LOST) !== null, "the note");
  assert.deepEqual(told(), [], "the home could not be reached");
  home.online = true;
  notify();
  await wait(50);
  assert.deepEqual(told(), [], "not before a minute");
  const realNow = Date.now;
  Date.now = () => realNow() + 61_000;
  try {
    notify();
    await until(() => told().length === 1, "the controller told");
    assert.deepEqual(told(), [{ on: false }]);
    assert.equal(localStorage.getItem(LOST), null);

    // Again out of reach, and then alerts switched on again: nothing off is told any more.
    home.requests.length = 0;
    browser.subscribes = true;
    await turnAlertsOn();
    home.requests.length = 0;
    home.online = false;
    browser.subscription = null;
    browser.subscribes = false;
    fromWorker({ type: "directorlink-push-changed" });
    await until(() => localStorage.getItem(LOST) !== null, "the note");
    home.online = true;
    browser.subscribes = true;
    await turnAlertsOn();
    assert.equal(localStorage.getItem(LOST), null, "switched on: the note goes");
    Date.now = () => realNow() + 200_000;
    notify();
    await wait(100);
    assert.deepEqual(told(), [{ on: true }], "only on, as the switch says");
  } finally {
    Date.now = realNow;
  }
});
