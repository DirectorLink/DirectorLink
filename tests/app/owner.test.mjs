// Handing the home to another admin (1.9.0, ADR-064; app/js/views/access.js): in Settings → Users
// the owner, and only the owner, has "Make Dana the owner" on another admin's row, asked first with
// what changes; a member has none (made an admin first); the controller's refusals in the app's
// words; English and Hebrew, users never people. Against a fake controller, with just enough of a
// browser.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

// ---- just enough of a browser ------------------------------------------------------------------
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
  getContext() {
    return { fillRect() {}, fillStyle: "" };
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/#/access", pathname: "/", search: "", hash: "#/access", replace() {} };
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.history = { state: null, back() {} };
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: new FakeElement("body"),
  addEventListener() {},
  removeEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (Windows NT 10.0)", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
const stored = new Map();
Object.defineProperty(globalThis, "localStorage", {
  value: { getItem: (key) => (stored.has(key) ? stored.get(key) : null), setItem: (key, value) => stored.set(key, String(value)), removeItem: (key) => stored.delete(key) },
  configurable: true,
});
const confirmed = [];
let answerConfirm = true;
window.confirm = (text) => {
  confirmed.push(text);
  return answerConfirm;
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
globalThis.setTimeout = ((original) => (callback, delay, ...rest) => {
  const timer = original(callback, delay, ...rest);
  timer?.unref?.();
  return timer;
})(globalThis.setTimeout);

// ---- the fake controller --------------------------------------------------------------------------
const HOST = "controller.invalid";
const MEMBER = { role: "member", owner: false, all_rooms: true, rooms: [], kinds: { light: true, climate: true, fan: true, blind: true, music: true, refrigerator: true }, cameras: true, doors: false, alarm: true, scenes: [] };
const ADMIN = { ...MEMBER, role: "admin", doors: true };
const controller = { calls: [], users: null, refuse: null };

function answer(status, body) {
  return new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { "Content-Type": status >= 400 ? "application/problem+json" : "application/json" } });
}

const device = (id, name, extra = {}) => ({ id, name, created_at: "2026-10-01T08:00:00Z", last_used_at: "2026-10-05T07:00:00Z", expires_at: null, current: false, accounts: 1, removable: true, ...extra });

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const body = init.body ? JSON.parse(init.body) : null;
  controller.calls.push({ method, path, body });
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (controller.refuse && controller.refuse.method === method && controller.refuse.path === path) {
    const { status, problem } = controller.refuse;
    controller.refuse = null;
    return answer(status, problem);
  }
  if (method === "GET" && path === "/v1/users") return answer(200, controller.users);
  if (method === "POST" && path === "/v1/users/owner") {
    const to = controller.users.items.find((user) => user.id === body.profile_id);
    return answer(200, { owner: { id: to.id, name: to.name }, previous: { id: "aaaa0001", name: "Dana" }, account_service: "moved" });
  }
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { accessView, resetAccess } = await import("../../app/js/views/access.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

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
function byKey(nodes, key) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node.dataset?.key === key) found = node;
  });
  return found;
}
const textOf = (nodes) => [nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" | ");
async function press(nodes, key) {
  const element = byKey(nodes, key);
  assert.ok(element, `${key} is on the screen: ${textOf(nodes).slice(0, 600)}`);
  await Promise.all((element.listeners.click || []).map((listener) => listener({ preventDefault() {}, target: element, currentTarget: element })));
  await settle();
}
const calls = (method, path) => controller.calls.filter((call) => call.method === method && call.path === path);

// Dana owns the home; Avi is an admin, Noa a member. `you`: whose device this is.
function homeUsers(you = "aaaa0001") {
  return {
    device_limit: 5,
    accounts_known: true,
    items: [
      { id: "aaaa0001", name: "Dana", created_at: "2026-09-01T08:00:00Z", access: { ...ADMIN, owner: true }, accounts: 1, devices: [device("0a1b2c3d", "Chrome on Windows")] },
      { id: "aaaa0002", name: "Avi", created_at: "2026-09-02T08:00:00Z", access: { ...ADMIN }, accounts: 1, devices: [device("0a1b2c3e", "Safari on iPhone")] },
      { id: "bbbb0003", name: "Noa", created_at: "2026-09-03T08:00:00Z", access: { ...MEMBER }, accounts: 0, devices: [device("0a1b2c3f", "Chrome on Android", { accounts: 0 })] },
    ].map((user) => ({ ...user, you: user.id === you })),
    suggestions: [],
  };
}

function connect({ you = "aaaa0001" } = {}) {
  const users = homeUsers(you);
  const mine = users.items.find((user) => user.you);
  controller.calls = [];
  controller.users = users;
  controller.refuse = null;
  confirmed.length = 0;
  answerConfirm = true;
  resetAccess();
  Object.assign(state, {
    host: HOST,
    apiKey: "ak_test",
    status: "connected",
    transport: "lan",
    loaded: true,
    online: true,
    role: mine.access.role,
    access: mine.access,
    rooms: [],
    profile: { id: you, prefs: { hidden_rooms: [] } },
    scenes: [],
    system: { bridge: { version: "1.9.0" }, features: { people_permissions: true, users: true } },
    account: { status: "signed-out", user: null, notice: null, busy: false },
  });
}

async function open() {
  accessView({});
  await settle();
  return accessView({});
}

test("the owner makes another admin the owner, asked first with what changes", async () => {
  connect();
  setLanguage("en");
  const view = await open();
  assert.equal(textOf(byKey(view, "users-make-owner-aaaa0002")), "Make Avi the owner");
  assert.equal(byKey(view, "users-make-owner-bbbb0003"), null, "a member is made an admin first");
  assert.equal(byKey(view, "users-make-owner-aaaa0001"), null, "not themself");
  assert.match(textOf(byKey(view, "users-owner-help-aaaa0001")), /another admin the owner \(a member is made an admin first\); you then stay an admin/);
  // Asked first: nothing is sent when the owner says no.
  answerConfirm = false;
  await press(view, "users-make-owner-aaaa0002");
  assert.equal(calls("POST", "/v1/users/owner").length, 0);
  answerConfirm = true;
  await press(accessView({}), "users-make-owner-aaaa0002");
  const question = confirmed.at(-1);
  assert.match(question, /^Make Avi the home’s owner\?/);
  assert.match(question, /only Avi changes their own access and devices, links the home to an account again/);
  assert.match(question, /their Google or Apple account becomes the home’s account/);
  assert.match(question, /You stay an admin, which Avi can change\. Nobody is removed\./);
  assert.deepEqual(calls("POST", "/v1/users/owner")[0].body, { profile_id: "aaaa0002" });
  assert.match(textOf(accessView({})), /Avi is the home’s owner now\. You are an admin\./);
  assert.ok(calls("GET", "/v1/users").length >= 2, "the users are read again");
});

test("another admin and a member have no such button", async () => {
  connect({ you: "aaaa0002" });
  setLanguage("en");
  let view = await open();
  for (const id of ["aaaa0001", "aaaa0002", "bbbb0003"]) {
    assert.equal(byKey(view, `users-make-owner-${id}`), null, id);
  }
  assert.equal(byKey(view, "users-owner-help-aaaa0002"), null);
  connect({ you: "bbbb0003" });
  controller.users.items = controller.users.items.filter((user) => user.you);
  view = await open();
  assert.equal(byKey(view, "users-make-owner-bbbb0003"), null);
});

test("the controller's refusals, in the app's words", async () => {
  connect();
  setLanguage("en");
  const refusals = [
    [409, { code: "OWNER_NEEDS_ACCOUNT", user: { id: "aaaa0002", name: "Avi" } }, /Avi needs to sign in to DirectorLink on one of their devices first/],
    [409, { code: "NOT_AN_ADMIN", user: { id: "aaaa0002", name: "Avi" } }, /Make Avi an admin first: only an admin can be the owner/],
    [403, { code: "OWNER_ONLY" }, /Only the home’s owner can make someone else the owner/],
    [503, { code: "REMOTE_OFFLINE", detail: "The controller is not connected to DirectorLink's servers right now, so nothing was changed; try again in a minute" }, /not connected to DirectorLink's servers right now/],
  ];
  for (const [status, problem, words] of refusals) {
    controller.refuse = { method: "POST", path: "/v1/users/owner", status, problem: { type: "about:blank", title: "Refused", status, detail: "refused", ...problem } };
    await press(await open(), "users-make-owner-aaaa0002");
    assert.match(textOf(accessView({})), words, problem.code);
  }
});

test("the words are there in English and Hebrew, about users, never people", async () => {
  const keys = (value) => Object.keys(value).sort();
  assert.deepEqual(keys(he.users.owner), keys(en.users.owner));
  assert.ok(en.history.access.owner_changed && he.history.access.owner_changed);
  const words = Object.values(en.users.owner).join(" ") + en.history.access.owner_changed;
  assert.doesNotMatch(words, /\bpeople\b|\bperson\b/i);
  assert.doesNotMatch(Object.values(he.users.owner).join(" "), /אנשים|אדם/);
  connect();
  await setLanguage("he");
  try {
    const view = await open();
    assert.equal(textOf(byKey(view, "users-make-owner-aaaa0002")), "להפוך את Avi לבעל הבית");
    await press(view, "users-make-owner-aaaa0002");
    assert.match(confirmed.at(-1), /^להפוך את Avi לבעל הבית\?/);
  } finally {
    await setLanguage("en");
  }
});
