// A home whose DirectorLink is older than the account service takes (1.8.0, ADR-059): through the
// account, the app says to update DirectorLink, not that the home is offline. On the home network
// nothing changes. Against a fake account service.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

const HOME = "0123456789abcdef0123456789abcdef";
const stored = new Map();

class FakeNode {}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.history = { state: null, replaceState() {} };
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
console.warn = () => {}; // the app's own note of each failed refresh
globalThis.document = {
  hidden: false,
  documentElement: {},
  addEventListener() {},
  removeEventListener() {},
  querySelector: () => null,
  createElement: () => ({ dataset: {}, style: {}, setAttribute() {}, append() {}, addEventListener() {} }),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
  },
  configurable: true,
});
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (Windows NT 10.0) Chrome/140", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});

// The account service: what a sealed request through it is answered.
const cloud = { answer: null, calls: 0 };
globalThis.fetch = async (url) => {
  const { hostname, pathname } = new URL(url);
  if (hostname !== "api.directorlink.io") throw new TypeError(`blocked: ${url}`);
  cloud.calls += 1;
  if (pathname === `/v1/homes/${HOME}/e2e`) {
    const [status, body] = cloud.answer;
    return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/problem+json" } });
  }
  return new Response(JSON.stringify({ code: "NOT_FOUND" }), { status: 404 });
};

const { state } = await import("../../app/js/state.js");
const { RemoteError, saveRemote } = await import("../../app/js/remote.js");
const session = await import("../../app/js/session.js");
const { setLanguage } = await import("../../app/js/i18n.js");

function linkedThroughTheAccount() {
  saveRemote({ home: HOME, keyId: "0a1b2c3d" });
  Object.assign(state, { apiKey: "ak_test", host: null, transport: "remote", status: "connected", notice: null, account: { status: "signed-in", user: { id: "u1" } } });
}

async function refreshUntilNotice() {
  for (let index = 0; index < 5 && state.status === "connected"; index += 1) await session.refreshDevices();
  return state.notice;
}

test("through the account, a home too old for remote access says to update DirectorLink, not offline", async () => {
  linkedThroughTheAccount();
  cloud.answer = [503, { type: "about:blank", status: 503, code: "HOME_UPDATE_REQUIRED", detail: "The home runs DirectorLink 1.7.0, which can no longer connect to remote access" }];
  const notice = await refreshUntilNotice();
  assert.equal(state.status, "unreachable");
  assert.equal(notice.remote, true);
  assert.equal(notice.text, "Update DirectorLink: the version on your controller can no longer connect to remote access. Update it in Composer; at home the app works as before.");
  assert.equal(session.errorText(new RemoteError("HOME_UPDATE_REQUIRED", "…", 503)), notice.text);

  // An offline home still says offline.
  linkedThroughTheAccount();
  cloud.answer = [503, { type: "about:blank", status: 503, code: "HOME_OFFLINE", detail: "The home is not connected to the relay" }];
  assert.match((await refreshUntilNotice()).text, /^Your home is not connected to DirectorLink right now/);
});

test("in Hebrew too", async () => {
  await setLanguage("he");
  assert.match(session.errorText(new RemoteError("HOME_UPDATE_REQUIRED", "…", 503)), /^עדכנו את DirectorLink/);
  await setLanguage("en");
});
