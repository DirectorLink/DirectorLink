// Signed out of the account on a device linked to its home (1.13.2, ADR-089): Home says so with the
// same sign-in as Settings → Account, until hidden for this start of the app, and only then; Settings
// → Account says it too ("from here" on a device with no way to its home on the home network); a
// connection refused because the account's session ended says "signed out" (the text, the chip and
// the screen), not that the home can't be reached, and a sign-in that did not work says so there
// too, read out; in Hebrew too. Signing out only once the account service ended the session (else
// still signed in, with Retry, and sent again once a request through the account works and first at
// the next start; without its answer /v1/me says), and "still signed in" no longer once it has ended;
// back from Google or Apple a sign-out still to send is dropped; never "signed out" while requests
// through the account work, nor after a sign-in in another tab; a linked device asks at start rather
// than assume; after Delete account nothing asks to sign in, through the account either, and the
// link to the home stays.
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
// The window's listeners (a storage event: another tab of this browser), run by `fire()`.
const windowListeners = {};
globalThis.addEventListener = (type, listener) => (windowListeners[type] ||= []).push(listener);
globalThis.removeEventListener = () => {};
const fire = (type, event) => {
  for (const listener of windowListeners[type] || []) listener({ type, ...event });
};
// The clock, moved on by `aMinuteLater()`: an app that asks again after an answer through the
// account does so at most once a minute.
const realNow = Date.now;
let shift = 0;
Date.now = () => realNow() + shift;
const aMinuteLater = () => (shift += 61_000);
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
const { RemoteError, forgetRemote, listAccountHomes, saveRemote, savedRemote } = await import("../../app/js/remote.js");
const { checkInThroughAccount, connect, errorText, homeRoutes, stopPolling } = await import("../../app/js/session.js");
const { deleteAccount, loadAccount, signOut, startAccount } = await import("../../app/js/account.js");
const { homeView } = await import("../../app/js/views/home.js");
const { settingsView } = await import("../../app/js/views/settings.js");
const { connectionChip } = await import("../../app/js/views/common.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");
const { default: es } = await import("../../app/i18n/es.js");
const { default: it } = await import("../../app/i18n/it.js");

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
    home();
    state.host = "";
    assert.equal(byKey(settingsView({ page: "account" }), "account-signed-out")?.textContent, he.signedOut.noticeHere);
    state.account = { ...SIGNED_IN, notice: "signOutFailed" };
    assert.ok(find(settingsView({ page: "account" }), (node) => node.textContent === he.settings.account.notice.signOutFailed));
    assert.match(he.settings.account.notice.signOutFailed, /^[א-ת]/);
  } finally {
    await setLanguage("en");
  }
});

// ---- signing out, starting, deleting the account ------------------------------------------------

const settle = () => new Promise((resolve) => setTimeout(resolve, 10));
const ME = { id: "u1", email: "dana@example.com", name: "Dana", providers: ["google"], sign_in_providers: ["google", "apple"] };
const FRESH = { status: "unknown", user: null, notice: null, busy: false };
// The account service answers `routes` ("METHOD /path": { status, body } or an Error to throw);
// anything else cannot be reached.
const route = (routes) => (url, init = {}) => {
  const key = `${init.method || "GET"} ${new URL(url).pathname}`;
  const reply = routes[key];
  if (!reply) throw new TypeError(`offline in this test: ${key}`);
  if (reply instanceof Error) throw reply;
  return new Response(reply.body === undefined ? null : JSON.stringify(reply.body), { status: reply.status, headers: { "content-type": "application/json" } });
};
const offline = () => {
  throw new TypeError("offline in this test");
};

test("a sign-out that does not reach the account service keeps the device signed in, says so with Retry, and is sent first at the next start", async () => {
  for (const failure of [new TypeError("Failed to fetch"), { status: 500, body: { code: "INTERNAL_ERROR" } }]) {
    home();
    state.account = { ...SIGNED_IN };
    stored.set("directorlink.account", "1");
    answer = route({ "POST /auth/logout": failure });
    await signOut();
    assert.equal(state.account.status, "signed-in", "the session goes on, so the device is still signed in");
    assert.equal(state.account.notice, "signOutFailed");
    assert.equal(stored.get("directorlink.account"), "1");
    assert.equal(stored.get("directorlink.signOut"), "1", "sent again at the next start");
    assert.equal(notice(), null, "Home does not say signed out");
  }
  const page = settingsView({ page: "account" });
  assert.ok(find(page, (node) => node.textContent === en.settings.account.notice.signOutFailed));
  assert.ok(byKey(page, "account-sign-out"), "Sign out is still there");

  // Retry, as Sign out does: the account service ends it now.
  answer = route({ "POST /auth/logout": { status: 204 } });
  byKey(page, "account-sign-out-retry").dispatch("click");
  await settle();
  assert.equal(state.account.status, "signed-out");
  assert.equal(stored.has("directorlink.signOut"), false);

  // A sign-out still to send goes first at the next start.
  state.account = { ...SIGNED_IN };
  stored.set("directorlink.account", "1");
  answer = route({ "POST /auth/logout": new TypeError("Failed to fetch") });
  await signOut();
  answer = route({ "POST /auth/logout": { status: 204 }, "GET /v1/me": { status: 200, body: ME } });
  asked.length = 0;
  state.account = { ...FRESH };
  startAccount({ linked: true });
  await settle();
  assert.deepEqual(asked, ["POST /auth/logout"]);
  assert.equal(state.account.status, "signed-out");
  assert.equal(stored.has("directorlink.signOut"), false);
  assert.equal(stored.has("directorlink.account"), false);

  // Still not reachable at the next start: as the account service says, with the notice again.
  stored.set("directorlink.signOut", "1");
  answer = route({ "POST /auth/logout": { status: 503, body: { code: "UNAVAILABLE" } }, "GET /v1/me": { status: 200, body: ME } });
  state.account = { ...FRESH };
  startAccount({ linked: true });
  await settle();
  assert.equal(state.account.status, "signed-in");
  assert.equal(state.account.notice, "signOutFailed");
  assert.equal(stored.get("directorlink.signOut"), "1");
  stored.delete("directorlink.signOut");
  answer = offline;
});

test("a sign-out the account service confirms signs out: 204, or 401 when the session had ended", async () => {
  for (const reply of [{ status: 204 }, { status: 401, body: { code: "NOT_SIGNED_IN" } }]) {
    home();
    state.account = { ...SIGNED_IN };
    stored.set("directorlink.account", "1");
    answer = route({ "POST /auth/logout": reply });
    await signOut();
    assert.equal(state.account.status, "signed-out", String(reply.status));
    assert.equal(state.account.notice, null);
    assert.equal(stored.has("directorlink.account"), false);
    assert.equal(stored.has("directorlink.signOut"), false);
  }
  answer = offline;
});

test("while requests through the account work, the app never says signed out, and asks the account again", async () => {
  home();
  // The app thought it signed out (a start that assumed it, a sign-in in another tab), but this
  // device's session works: connected through the account, nothing says signed out.
  Object.assign(state, { transport: "remote", status: "connected" });
  assert.equal(notice(), null);
  assert.equal(byKey(settingsView({ page: "account" }), "account-signed-out"), null);
  state.transport = "lan";
  answer = route({ "GET /v1/homes": { status: 200, body: { items: [] } }, "GET /v1/me": { status: 200, body: ME } });
  asked.length = 0;
  await listAccountHomes();
  await settle();
  assert.deepEqual(asked, ["GET /v1/homes", "GET /v1/me"], "an answer through the account: asked again");
  assert.equal(state.account.status, "signed-in");
  assert.equal(notice(), null);
  answer = offline;
});

test("a sign-in that did not work says so on the screen and the banner that offer it, too", () => {
  home();
  Object.assign(state, {
    status: "unreachable",
    loaded: false,
    transport: "remote",
    notice: { kind: "error", text: en.errors.remote.signIn, remote: true, signedOut: true },
    account: { ...SIGNED_OUT, notice: "failed" },
  });
  assert.equal(byKey(homeView({}), "sign-in-outcome")?.textContent, en.settings.account.notice.failed, "the screen");
  state.loaded = true;
  const screen = homeView({});
  assert.equal(byKey(screen, "sign-in-outcome")?.textContent, en.settings.account.notice.failed, "the banner");
  assert.equal(byKey(screen, "signed-out-notice"), null, "said once");
  state.account = { ...SIGNED_OUT, notice: "unverified" };
  assert.equal(byKey(homeView({}), "sign-in-outcome")?.textContent, en.settings.account.notice.unverified);
  state.account = { ...SIGNED_OUT, notice: "deleted" };
  assert.equal(byKey(homeView({}), "sign-in-outcome"), null, "only a sign-in's outcome");
});

test("after Delete account nothing asks to sign in (it would not bring the home back), at the next start either, until a sign-in", async () => {
  home();
  state.account = { ...SIGNED_IN };
  answer = route({ "DELETE /v1/me": { status: 204 } });
  assert.equal(await deleteAccount(), true);
  assert.equal(state.account.status, "signed-out");
  assert.equal(state.account.notice, "deleted");
  assert.equal(notice(), null);
  assert.equal(byKey(settingsView({ page: "account" }), "account-signed-out"), null);
  assert.ok(byKey(settingsView({ page: "account" }), "account-sign-in"), "signing in stays possible");

  // The next start: still linked, but nothing is asked (no account to ask about).
  answer = route({ "GET /v1/me": { status: 401, body: { code: "NOT_SIGNED_IN" } } });
  asked.length = 0;
  state.account = { ...FRESH };
  startAccount({ linked: true });
  await settle();
  assert.deepEqual(asked, [], "no GET /v1/me");
  assert.equal(state.account.status, "signed-out");
  assert.equal(notice(), null, "the next start");

  // Signed in again: from then on, signed out means the notice again.
  location.href = "https://app.directorlink.io/?signin=ok#/";
  answer = route({ "GET /v1/me": { status: 200, body: ME } });
  try {
    startAccount({ linked: true });
    await settle();
  } finally {
    location.href = "https://app.directorlink.io/#/";
  }
  assert.equal(state.account.status, "signed-in");
  assert.equal(stored.has("directorlink.accountDeleted"), false);
  state.account = { ...SIGNED_OUT };
  assert.ok(notice());
  answer = offline;
});

test("a linked device asks the account at start rather than assume it signed out; back from a sign-in it is remembered at once", async () => {
  home();
  stored.delete("directorlink.account");
  answer = route({ "GET /v1/me": { status: 200, body: ME } });
  asked.length = 0;
  state.account = { ...FRESH };
  startAccount({ linked: true });
  await settle();
  assert.deepEqual(asked, ["GET /v1/me"]);
  assert.equal(state.account.status, "signed-in");
  assert.equal(notice(), null);

  // Not linked and not signed in here: nothing is asked (a device that never signed in asks no server).
  stored.delete("directorlink.account");
  asked.length = 0;
  state.account = { ...FRESH };
  startAccount({ linked: false });
  await settle();
  assert.deepEqual(asked, []);
  assert.equal(state.account.status, "signed-out");

  // Back from a sign-in whose first look gets no answer: remembered, so the next start asks.
  location.href = "https://app.directorlink.io/?signin=ok#/";
  answer = offline;
  try {
    state.account = { ...FRESH };
    startAccount({ linked: false });
    await settle();
  } finally {
    location.href = "https://app.directorlink.io/#/";
  }
  assert.equal(state.account.status, "unavailable");
  assert.equal(stored.get("directorlink.account"), "1");
});

test("without a way to its home on the home network (iPhone or iPad without Direct HTTPS), it says from here", () => {
  home();
  state.host = "";
  assert.deepEqual(homeRoutes(), []);
  assert.equal(byClass(notice(), "banner-signed-out-body").children[0].textContent, en.signedOut.noticeHere);
  assert.equal(byKey(settingsView({ page: "account" }), "account-signed-out")?.textContent, en.signedOut.noticeHere);
  state.host = "192.0.2.10";
  assert.equal(byKey(settingsView({ page: "account" }), "account-signed-out")?.textContent, en.signedOut.notice);
});

// ---- a sign-out the app is not sure of, another tab, after Delete account ------------------------

test("\"You're still signed in\" goes once the app learns the session has ended; a sign-in's outcome stays", async () => {
  home();
  state.account = { ...SIGNED_IN };
  stored.set("directorlink.account", "1");
  // On the iPad in airplane mode: neither the sign-out nor /v1/me gets an answer.
  answer = offline;
  await signOut();
  assert.equal(state.account.status, "signed-in");
  assert.equal(state.account.notice, "signOutFailed");
  // Online again, at home: Sign out everywhere on the iPhone ended the session meanwhile. The daily
  // check-in through the account is refused, and the account, asked again, says so.
  const refused = { status: 401, body: { code: "NOT_SIGNED_IN" } };
  answer = route({ [`POST /v1/homes/${HOME}/e2e`]: refused, "GET /v1/me": refused });
  assert.equal(await checkInThroughAccount(true), false);
  await settle();
  assert.equal(state.account.status, "signed-out");
  assert.equal(state.account.notice, null);
  assert.equal(stored.has("directorlink.signOut"), false);
  const page = settingsView({ page: "account" });
  assert.equal(find(page, (node) => node.textContent === en.settings.account.notice.signOutFailed), null, "not next to You're signed out");
  assert.equal(byKey(page, "account-signed-out")?.textContent, en.signedOut.notice);

  // A sign-in that did not work is still said.
  state.account = { status: "unavailable", user: null, notice: "cancelled", busy: false };
  await loadAccount();
  assert.equal(state.account.status, "signed-out");
  assert.equal(state.account.notice, "cancelled");
  answer = offline;
});

test("Sign out without the account service's word asks /v1/me, as at start: ended (401), signed out; going on (200), still signed in with Retry", async () => {
  home();
  state.account = { ...SIGNED_IN };
  stored.set("directorlink.account", "1");
  // The service ended the session, but the logout's answer was lost on the way back.
  answer = route({ "POST /auth/logout": new TypeError("Failed to fetch"), "GET /v1/me": { status: 401, body: { code: "NOT_SIGNED_IN" } } });
  asked.length = 0;
  await signOut();
  assert.deepEqual(asked, ["POST /auth/logout", "GET /v1/me"]);
  assert.equal(state.account.status, "signed-out");
  assert.equal(state.account.notice, null);
  assert.equal(stored.has("directorlink.signOut"), false);
  assert.equal(stored.has("directorlink.account"), false);

  // An error answer, and the session goes on.
  state.account = { ...SIGNED_IN };
  stored.set("directorlink.account", "1");
  answer = route({ "POST /auth/logout": { status: 500, body: { code: "INTERNAL_ERROR" } }, "GET /v1/me": { status: 200, body: ME } });
  await signOut();
  assert.equal(state.account.status, "signed-in");
  assert.equal(state.account.user?.email, ME.email);
  assert.equal(state.account.notice, "signOutFailed");
  assert.equal(stored.get("directorlink.signOut"), "1");
  assert.ok(byKey(settingsView({ page: "account" }), "account-sign-out-retry"));
  stored.delete("directorlink.signOut");
  answer = offline;
});

test("a sign-out still to send when nothing answers at start: Settings → Account offers its Retry, not the sign-in; an answer through the account sends it, at most once a minute", async () => {
  home();
  stored.set("directorlink.account", "1");
  stored.set("directorlink.signOut", "1");
  answer = offline;
  state.account = { ...FRESH };
  startAccount({ linked: true });
  await settle();
  assert.equal(state.account.status, "unavailable");
  assert.equal(state.account.notice, "signOutFailed");
  const page = settingsView({ page: "account" });
  assert.ok(find(page, (node) => node.textContent === en.settings.account.notice.signOutFailed));
  assert.ok(byKey(page, "account-sign-out-retry"), "the sign-out's Retry");
  for (const key of ["account-sign-in", "account-sign-in-apple", "account-retry"]) {
    assert.equal(byKey(page, key), null, `no ${key}: not as if signed out`);
  }

  // The connection is back: a request through the account is answered, so the sign-out goes now.
  // The service fails it this time; /v1/me says the session goes on.
  aMinuteLater();
  const homes = { status: 200, body: { items: [] } };
  answer = route({ "GET /v1/homes": homes, "POST /auth/logout": { status: 503, body: { code: "UNAVAILABLE" } }, "GET /v1/me": { status: 200, body: ME } });
  asked.length = 0;
  await listAccountHomes();
  await settle();
  assert.deepEqual(asked, ["GET /v1/homes", "POST /auth/logout", "GET /v1/me"]);
  assert.equal(state.account.status, "signed-in");
  assert.equal(state.account.notice, "signOutFailed");
  // Within the minute, more answers send nothing more.
  asked.length = 0;
  await listAccountHomes();
  await listAccountHomes();
  await settle();
  assert.deepEqual(asked, ["GET /v1/homes", "GET /v1/homes"]);
  // A minute later, again: the service ends it.
  aMinuteLater();
  answer = route({ "GET /v1/homes": homes, "POST /auth/logout": { status: 204 } });
  asked.length = 0;
  await listAccountHomes();
  await settle();
  assert.deepEqual(asked, ["GET /v1/homes", "POST /auth/logout"]);
  assert.equal(state.account.status, "signed-out");
  assert.equal(stored.has("directorlink.signOut"), false);
  answer = offline;
});

test("back from Google or Apple, whatever came of it, a sign-out still to send is dropped: the person went on using the account", async () => {
  for (const outcome of ["linked", "cancelled"]) {
    home();
    state.account = { ...SIGNED_IN };
    stored.set("directorlink.account", "1");
    answer = offline;
    await signOut();
    assert.equal(stored.get("directorlink.signOut"), "1");
    // Online again, Add Apple (Settings → Account) rather than Retry, and back with its outcome.
    location.href = `https://app.directorlink.io/?signin=${outcome}#/settings/account`;
    answer = route({ "GET /v1/me": { status: 200, body: ME }, "POST /auth/logout": { status: 204 } });
    asked.length = 0;
    try {
      state.account = { ...FRESH };
      startAccount({ linked: true });
      await settle();
    } finally {
      location.href = "https://app.directorlink.io/#/";
    }
    assert.deepEqual(asked, ["GET /v1/me"], `${outcome}: no sign-out`);
    assert.equal(state.account.status, "signed-in");
    assert.equal(state.account.notice, outcome, "its outcome, as usual");
    assert.equal(stored.has("directorlink.signOut"), false);
  }
  answer = offline;
});

test("a sign-in in another tab of this browser: this one asks too, at home where no request through the account would tell it", async () => {
  home();
  stored.delete("directorlink.account");
  answer = route({ "GET /v1/me": { status: 401, body: { code: "NOT_SIGNED_IN" } } });
  state.account = { ...FRESH };
  startAccount({ linked: true });
  await settle();
  assert.equal(state.account.status, "signed-out");
  assert.ok(notice());

  // Signed in again in the other tab: its mark comes here as a storage event.
  answer = route({ "GET /v1/me": { status: 200, body: ME } });
  asked.length = 0;
  fire("storage", { key: "directorlink.providers", oldValue: null, newValue: JSON.stringify(["google"]) });
  await settle();
  assert.deepEqual(asked, [], "only the signed-in mark");
  stored.set("directorlink.account", "1");
  fire("storage", { key: "directorlink.account", oldValue: null, newValue: "1" });
  await settle();
  assert.deepEqual(asked, ["GET /v1/me"]);
  assert.equal(state.account.status, "signed-in");
  assert.equal(notice(), null);
  answer = offline;
});

test("a sign-in's outcome on Home's notice and on the signed-out screen is read out (role status), as in Settings → Account", () => {
  home();
  state.account = { ...SIGNED_OUT, notice: "cancelled" };
  assert.equal(byKey(notice(), "sign-in-outcome")?.attributes.role, "status", "Home's notice");
  Object.assign(state, {
    status: "unreachable",
    loaded: false,
    transport: "remote",
    notice: { kind: "error", text: en.errors.remote.signIn, remote: true, signedOut: true },
  });
  assert.equal(byKey(homeView({}), "sign-in-outcome")?.attributes.role, "status", "the signed-out screen");
  // The banner over the last state is read out itself: its outcome is not, twice.
  state.loaded = true;
  const banner = find(homeView({}), (node) => node.className === "banner banner-error");
  assert.equal(banner.attributes.role, "status");
  assert.ok(byKey(banner, "sign-in-outcome"));
  assert.equal(byKey(banner, "sign-in-outcome").attributes.role, undefined);
});

test("after Delete account, through the account too, nothing asks to sign in: it says the account was deleted; the link to the home stays", async () => {
  home();
  state.account = { ...SIGNED_IN };
  answer = route({ "DELETE /v1/me": { status: 204 } });
  assert.equal(await deleteAccount(), true);
  // Sealing on the home network takes its key id from the link (iPhone and iPad with Direct HTTPS).
  assert.deepEqual(savedRemote(), { home: HOME, keyId: "0badc0de" }, "directorlink.remote kept");

  // Away from home, every request through the account is refused: the account and its session are gone.
  Object.assign(state, { host: "", transport: "remote", status: "connecting", loaded: false });
  answer = () => new Response(JSON.stringify({ code: "NOT_SIGNED_IN", detail: "Sign in first" }), { status: 401, headers: { "content-type": "application/problem+json" } });
  asked.length = 0;
  const consoleError = console.error;
  console.error = () => {};
  try {
    assert.equal(await connect(), false);
    await settle();
  } finally {
    console.error = consoleError;
    stopPolling();
  }
  assert.ok(asked.includes(`POST /v1/homes/${HOME}/e2e`));
  assert.equal(state.notice.text, en.errors.remote.accountDeleted);
  assert.doesNotMatch(en.errors.remote.accountDeleted, /sign in/i);
  const screen = homeView({});
  assert.ok(find(screen, (node) => node.textContent === en.errors.remote.accountDeleted), "the screen");
  assert.equal(byKey(screen, "unreachable-sign-in"), null);

  // The banner over the last state: the same words, and Retry rather than Sign in.
  state.loaded = true;
  const banner = find(homeView({}), (node) => node.className === "banner banner-error");
  assert.ok(banner.textContent.includes(en.errors.remote.accountDeleted));
  assert.equal(byKey(banner, "stale-sign-in"), null);
  assert.ok(byKey(banner, "stale-retry"));
  // Settings → Controller.
  const controller = settingsView({ page: "controller" });
  assert.ok(find(controller, (node) => node.textContent === en.errors.remote.accountDeleted));
  assert.equal(find(controller, (node) => node.textContent === en.errors.remote.signIn), null);
  // In Hebrew, Spanish and Italian too.
  try {
    for (const [code, dictionary] of Object.entries({ he, es, it })) {
      await setLanguage(code);
      assert.equal(errorText(new RemoteError("NOT_SIGNED_IN", "Sign in first", 401)), dictionary.errors.remote.accountDeleted, code);
      assert.notEqual(dictionary.errors.remote.accountDeleted, en.errors.remote.accountDeleted, `${code}: translated`);
    }
  } finally {
    await setLanguage("en");
  }
  stored.delete("directorlink.accountDeleted");
  assert.equal(errorText(new RemoteError("NOT_SIGNED_IN", "Sign in first", 401)), en.errors.remote.signIn, "signed in again, the usual words");
  answer = offline;
});
