// Signed out of the account on a device linked to its home (1.13.2, ADR-089): Home says so with the
// same sign-in as Settings → Account, until hidden for this start of the app, and only then; Settings
// → Account says it too; a connection refused because the account's session ended says "signed out"
// (the text, the chip and the screen), not that the home can't be reached; in Hebrew too.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

// Just enough of a browser for these modules: the elements the views build (with their listeners,
// to press them), storage, frames and the account service.
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
    const event = { type, currentTarget: this, target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
    for (const listener of this.listeners[type] || []) listener(event);
    return event;
  }
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  // Home's command field is kept over redraws and brought up to date in place (views/command.js).
  set textContent(text) {
    this.children = [document.createTextNode(String(text))];
  }
  replaceChildren(...children) {
    this.children = children;
  }
}
const assigned = [];
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.location = {
  hostname: "app.directorlink.io",
  origin: "https://app.directorlink.io",
  href: "https://app.directorlink.io/#/",
  pathname: "/",
  search: "",
  hash: "#/",
  assign: (url) => assigned.push(url),
};
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
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
const stored = new Map([["directorlink.providers", JSON.stringify(["google", "apple"])]]);
const writes = [];
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => {
    writes.push(key);
    stored.set(key, String(value));
  },
  removeItem: (key) => stored.delete(key),
};
// The account service: `answer(url, init)` answers each request; by default nothing is reachable.
let answer = () => {
  throw new TypeError("offline in this test");
};
const asked = [];
globalThis.fetch = async (url, init = {}) => {
  asked.push(`${init.method || "GET"} ${new URL(url).pathname}`);
  return answer(String(url), init);
};
globalThis.history = { state: null, replaceState() {}, back() {} };

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { RemoteError, forgetRemote, saveRemote } = await import("../../app/js/remote.js");
const { connect, errorText, stopPolling } = await import("../../app/js/session.js");
const { homeView } = await import("../../app/js/views/home.js");
const { settingsView } = await import("../../app/js/views/settings.js");
const { connectionChip } = await import("../../app/js/views/common.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

// ---- what a screen holds -----------------------------------------------------------------------

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function find(nodes, test) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node instanceof FakeElement && test(node)) found = node;
  });
  return found;
}
const byKey = (nodes, key) => find(nodes, (node) => node.dataset.key === key);
const byClass = (nodes, name) => find(nodes, (node) => typeof node.className === "string" && node.className.split(/\s+/).includes(name));
const notice = () => byKey(homeView({}), "signed-out-notice");

// ---- the home ----------------------------------------------------------------------------------

const HOME = "0123456789abcdef0123456789abcdef";
const SIGNED_OUT = { status: "signed-out", user: null, notice: null, busy: false };
const SIGNED_IN = { status: "signed-in", user: { email: "dana@example.com", providers: ["google"] }, notice: null, busy: false };

// Connected on the home network with an admin key, linked to the home through the account; signed
// out of the account.
function home() {
  Object.assign(state, {
    host: "192.0.2.10",
    apiKey: "ak_test",
    transport: "lan",
    lanRoute: "http",
    status: "connected",
    loaded: true,
    online: true,
    role: "admin",
    notice: null,
    rooms: [{ id: 10, name: "Kitchen", names: {} }],
    profile: { id: "p1", prefs: { hidden_rooms: [] } },
    system: { bridge: { version: "1.13.2" } },
    account: { ...SIGNED_OUT },
    lastUpdated: new Date(),
  });
  saveRemote({ home: HOME, keyId: "0badc0de" });
  ui.signedOutDismissed = false;
}

test("Home says it while signed out with a linked home, and not otherwise", () => {
  home();
  const shown = notice();
  assert.ok(shown, "signed out, linked: the notice");
  assert.equal(byClass(shown, "banner-signed-out-body").children[0].textContent, en.signedOut.notice);
  assert.match(en.signedOut.notice, /signed out/);
  // The same buttons as Settings → Account: Google's and Apple's (the providers this device knows).
  assert.ok(byKey(shown, "signed-out-sign-in"), "Sign in with Google");
  assert.ok(byKey(shown, "signed-out-sign-in-apple"), "Sign in with Apple");

  // Not in the way: at home everything else on Home is there as usual, the notice comes on top.
  const parts = (screen) => [screen].flat(Infinity).filter(Boolean).map((node) => `${node.tagName}.${node.className ?? ""}.${node.dataset?.key ?? ""}`);
  const signedOut = parts(homeView({}));
  state.account = { ...SIGNED_IN };
  const signedIn = parts(homeView({}));
  assert.deepEqual(
    signedOut.filter((part) => !part.endsWith(".signed-out-notice")),
    signedIn
  );
  assert.equal(signedOut.length, signedIn.length + 1);

  const cases = [
    ["signed in", () => (state.account = { ...SIGNED_IN })],
    ["the account service unreachable", () => (state.account = { status: "unavailable", user: null, notice: null, busy: false })],
    ["still asking the account service", () => (state.account = { status: "loading", user: null, notice: null, busy: false })],
    ["not linked to the home", () => forgetRemote()],
    ["no key (not paired)", () => Object.assign(state, { apiKey: "", status: "setup", loaded: false })],
  ];
  for (const [what, change] of cases) {
    home();
    change();
    assert.equal(notice(), null, what);
  }
});

test("its Sign in starts the same sign-in as Settings → Account, and comes back to Home", () => {
  home();
  assigned.length = 0;
  byKey(notice(), "signed-out-sign-in").dispatch("click");
  byKey(notice(), "signed-out-sign-in-apple").dispatch("click");
  const page = settingsView({ page: "account" });
  byKey(page, "account-sign-in").dispatch("click");
  assert.equal(assigned.length, 3);
  const [google, apple, fromSettings] = assigned.map((url) => new URL(url));
  assert.equal(`${google.origin}${google.pathname}`, "https://api.directorlink.io/auth/google/start");
  assert.equal(`${apple.origin}${apple.pathname}`, "https://api.directorlink.io/auth/apple/start");
  assert.equal(`${fromSettings.origin}${fromSettings.pathname}`, `${google.origin}${google.pathname}`, "the same sign-in");
  assert.equal(google.searchParams.get("link"), null, "a sign-in, not adding a provider");
  assert.equal(google.searchParams.get("return_to"), "https://app.directorlink.io/#/");
  assert.equal(fromSettings.searchParams.get("return_to"), "https://app.directorlink.io/#/settings/account");
});

test("a sign-in that did not work comes back to Home, which says so", () => {
  home();
  state.account = { ...SIGNED_OUT, notice: "cancelled" };
  assert.match(notice().textContent, new RegExp(en.settings.account.notice.cancelled));
  state.account = { ...SIGNED_OUT, notice: "signedOutEverywhere" };
  assert.doesNotMatch(notice().textContent, new RegExp(en.settings.account.notice.signedOutEverywhere), "only a sign-in's outcome");
});

test("hidden, it stays hidden for this start of the app (nothing stored), until the next one", () => {
  home();
  writes.length = 0;
  byKey(notice(), "signed-out-dismiss").dispatch("click");
  assert.equal(ui.signedOutDismissed, true);
  assert.equal(notice(), null);
  assert.deepEqual(writes, [], "kept in memory only: the next start shows it again");
  // Settings → Account still says it.
  assert.ok(byKey(settingsView({ page: "account" }), "account-signed-out"));
});

test("Settings → Account says it above the sign-in buttons; without a linked home, its usual words", () => {
  home();
  let page = settingsView({ page: "account" });
  assert.equal(byKey(page, "account-signed-out")?.textContent, en.signedOut.notice);
  assert.ok(byKey(page, "account-sign-in"));
  forgetRemote();
  page = settingsView({ page: "account" });
  assert.equal(byKey(page, "account-signed-out"), null);
  assert.ok(find(page, (node) => node.textContent === en.settings.account.intro));
});

test("a request refused because the session ended says signed out, not that the home can't be reached", () => {
  const text = errorText(new RemoteError("NOT_SIGNED_IN", "Sign in first", 401));
  assert.equal(text, en.errors.remote.signIn);
  assert.match(text, /signed out/);
  assert.notEqual(text, en.errors.remote.unreachable);
  assert.notEqual(text, en.errors.unreachable);
});

test("away from home with the session ended: the screen, its chip and the account all say signed out", async () => {
  home();
  // Away from home (no address at home), the session ended: every account request is answered 401.
  Object.assign(state, { host: "", transport: "remote", status: "connecting", loaded: false, account: { ...SIGNED_IN } });
  answer = () => new Response(JSON.stringify({ code: "NOT_SIGNED_IN", detail: "Sign in first" }), { status: 401, headers: { "content-type": "application/problem+json" } });
  asked.length = 0;
  const consoleError = console.error;
  console.error = () => {};
  try {
    assert.equal(await connect(), false);
    await new Promise((resolve) => setTimeout(resolve, 10));
  } finally {
    console.error = consoleError;
    stopPolling();
  }
  assert.ok(asked.includes(`POST /v1/homes/${HOME}/e2e`));
  assert.equal(state.status, "unreachable");
  assert.equal(state.notice.signedOut, true);
  assert.equal(state.notice.text, en.errors.remote.signIn);
  // The account was asked again, and said signed out.
  assert.ok(asked.includes("GET /v1/me"));
  assert.equal(state.account.status, "signed-out");

  const screen = homeView({});
  assert.ok(find(screen, (node) => node.className === "empty-title" && node.textContent === en.signedOut.title), "titled signed out");
  assert.equal(find(screen, (node) => node.textContent === en.status.unreachableTitle), null, "not Can't reach your controller");
  assert.ok(byKey(screen, "unreachable-sign-in"), "with the sign-in");
  assert.equal(byKey(screen, "signed-out-notice"), null, "said once, not twice");
  assert.equal(byClass(connectionChip(), "status-text").textContent, en.signedOut.chip);

  // With the last state shown, the banner says it, again only once.
  state.loaded = true;
  const stale = homeView({});
  assert.ok(find(stale, (node) => node.className === "banner banner-error" && node.textContent.includes(en.errors.remote.signIn)));
  assert.equal(byKey(stale, "signed-out-notice"), null);

  // Another failure (the home offline) keeps the usual words.
  state.notice = { kind: "error", text: en.errors.remote.homeOffline, remote: true, signedOut: false };
  state.loaded = false;
  assert.equal(byClass(connectionChip(), "status-text").textContent, en.status.unreachable);
  assert.ok(find(homeView({}), (node) => node.textContent === en.status.unreachableTitle));
  answer = () => {
    throw new TypeError("offline in this test");
  };
});

test("in Hebrew too", async () => {
  await setLanguage("he");
  try {
    home();
    const shown = notice();
    assert.equal(byClass(shown, "banner-signed-out-body").children[0].textContent, he.signedOut.notice);
    assert.match(he.signedOut.notice, /^[א-ת]/, "Hebrew, not the English text");
    assert.equal(byKey(shown, "signed-out-dismiss").attributes["aria-label"], he.signedOut.dismiss);
    assert.equal(errorText(new RemoteError("NOT_SIGNED_IN", "Sign in first", 401)), he.errors.remote.signIn);
    assert.match(he.errors.remote.signIn, /^אינכם מחוברים לחשבון/);
    Object.assign(state, { status: "unreachable", notice: { kind: "error", text: he.errors.remote.signIn, remote: true, signedOut: true } });
    assert.equal(byClass(connectionChip(), "status-text").textContent, he.signedOut.chip);
  } finally {
    await setLanguage("en");
  }
});
