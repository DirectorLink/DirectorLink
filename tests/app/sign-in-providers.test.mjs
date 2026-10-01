// Which sign-in buttons the app shows (app/js/account.js): only those the account server says it
// has set up, so Apple's button never shows while its key is missing there; and a device on which
// nobody chose to sign in never asks.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/#/settings", pathname: "/", search: "", hash: "#/settings" };
globalThis.requestAnimationFrame = () => 0;
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};
const calls = [];
let answers = {};
globalThis.fetch = async (url, init = {}) => {
  const path = new URL(url).pathname;
  calls.push({ path, credentials: init.credentials });
  const [status, body] = answers[path] ?? [404, { code: "NOT_FOUND" }];
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
};

const { SIGN_IN_PROVIDERS, loadAccount, loadProviders, providersStatus, refreshProviders, signInProviders } = await import("../../app/js/account.js");

test("the app can offer Google and Apple", () => {
  assert.deepEqual(SIGN_IN_PROVIDERS, ["google", "apple"]);
});

test("nothing is asked until someone chooses to sign in; then only the sign-ins set up are shown", async () => {
  assert.equal(signInProviders(), null, "not known yet: one Sign in button");
  refreshProviders();
  assert.deepEqual(calls, [], "a device nobody signed in on does not ask");

  answers = { "/auth/providers": [200, { providers: ["google"] }] };
  await loadProviders();
  assert.deepEqual(calls, [{ path: "/auth/providers", credentials: "omit" }], "no cookie is sent");
  assert.deepEqual(signInProviders(), ["google"], "Apple's key is not set: no Apple button");
  assert.equal(providersStatus(), "idle");
  assert.equal(stored.get("directorlink.providers"), '["google"]', "remembered for the next start");

  answers = { "/auth/providers": [200, { providers: ["apple", "google", "facebook"] }] };
  await loadProviders();
  assert.deepEqual(signInProviders(), ["google", "apple"], "the app's order, and only those it knows");
});

test("an unreachable account server is said, and what was known stays", async () => {
  answers = { "/auth/providers": [503, { code: "INTERNAL_ERROR" }] };
  await loadProviders();
  assert.equal(providersStatus(), "failed");
  assert.deepEqual(signInProviders(), ["google", "apple"]);
});

test("a signed-in account learns them from /v1/me; an older server means Google only", async () => {
  answers = { "/v1/me": [200, { id: "u", email: "a@example.com", providers: ["google"], sign_in_providers: ["google"] }] };
  await loadAccount();
  assert.deepEqual(signInProviders(), ["google"], "Apple sign-in was switched off again");
  answers = { "/v1/me": [200, { id: "u", email: "a@example.com", providers: ["google"], sign_in_providers: ["google", "apple"] }] };
  await loadAccount();
  assert.deepEqual(signInProviders(), ["google", "apple"]);
  answers = { "/v1/me": [200, { id: "u", email: "a@example.com", providers: ["google"] }] };
  await loadAccount();
  assert.deepEqual(signInProviders(), ["google"]);
});
