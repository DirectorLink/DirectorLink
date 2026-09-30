// Waiting for the home's owner on the join page (app/js/views/join.js, ADR-041): it asks every few
// seconds; when the account's session ends meanwhile it stops and offers to sign in again, and
// while the account server cannot be reached it asks less and less often. Rendered into a small
// fake DOM, with time under the test's control.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

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
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "#/join" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: {},
  addEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (Windows NT 10.0) Chrome/141.0", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
const storage = () => {
  const stored = new Map();
  return {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
  };
};
Object.defineProperty(globalThis, "localStorage", { value: storage(), configurable: true });
Object.defineProperty(globalThis, "sessionStorage", { value: storage(), configurable: true });
mock.timers.enable({ apis: ["setTimeout", "setInterval"] });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

const HOME = "0123456789abcdef0123456789abcdef";
const INVITATION = "89abcdef";
const SECRET = "ab".repeat(32);

// The account server: what GET /v1/join/… and GET /v1/me answer, and how often they were asked.
let server = { join: () => [200, { status: "pending", code: "042917" }], me: () => [200, { email: "guest@example.com" }] };
const asked = { join: 0, me: 0 };
globalThis.fetch = async (url) => {
  const { pathname } = new URL(url);
  const route = pathname.startsWith("/v1/join/") ? "join" : pathname === "/v1/me" ? "me" : null;
  if (!route) throw new TypeError(`blocked: ${url}`);
  asked[route] += 1;
  const reply = server[route]();
  if (reply === "offline") throw new TypeError("Failed to fetch");
  const [status, body] = reply;
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
};

const { state, ui } = await import("../../app/js/state.js");
const { joinView, storeInvitation } = await import("../../app/js/views/join.js");

// Lets the page's requests and what follows them run.
async function settle() {
  for (let index = 0; index < 20; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function waitFor(ms) {
  mock.timers.tick(ms);
  await settle();
}

function waiting() {
  storeInvitation(`${HOME}.${INVITATION}.${SECRET}`);
  state.account = { status: "signed-in", user: { email: "guest@example.com" }, notice: null, busy: false };
  ui.joinWait = { status: "pending", code: "042917", for: `${HOME}.${INVITATION}` };
  asked.join = 0;
  asked.me = 0;
  joinView({ navigate: () => {} });
}

test("when the account's session ends while it waits, the page stops asking and offers to sign in", async () => {
  waiting();
  server = { join: () => [401, { code: "NOT_SIGNED_IN", detail: "Sign in first" }], me: () => [401, { code: "NOT_SIGNED_IN" }] };
  await waitFor(5000);
  assert.equal(asked.join, 1);
  assert.equal(state.account.status, "signed-out", "the page shows the sign-in buttons");
  await waitFor(60000);
  assert.equal(asked.join, 1, "and asks nothing more");
});

test("while the account server cannot be reached, it asks less and less often", async () => {
  waiting();
  server = { join: () => "offline", me: () => [200, { email: "guest@example.com" }] };
  await waitFor(5000);
  assert.equal(asked.join, 1);
  await waitFor(5000);
  assert.equal(asked.join, 1, "not again after 5 seconds");
  await waitFor(5000);
  assert.equal(asked.join, 2, "but after 10");
  await waitFor(20000);
  assert.equal(asked.join, 3, "then after 20");
  // Back: every few seconds again.
  server.join = () => [200, { status: "pending", code: "042917" }];
  await waitFor(40000);
  assert.equal(asked.join, 4);
  await waitFor(5000);
  assert.equal(asked.join, 5);
  assert.equal(state.account.status, "signed-in");
  window.location.hash = "#/";
  await waitFor(5000);
});
