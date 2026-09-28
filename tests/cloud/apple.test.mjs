// Sign in with Apple (cloud/src/apple.js, accounts.js) end to end: the Worker under `wrangler dev`
// with a fake Apple that checks the Worker's ES256 client secret and signs ID tokens with a test
// key, and a fake Google for accounts that use both.
//   node --test tests/cloud/apple.test.mjs

import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { APPLE_PERSON, SERVICES_ID, appleVars, postBack, signInWithApple, startFakeApple } from "./fake-apple.mjs";
import { cookiesOf, googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const PUBLIC_URL = "https://api.directorlink.test";
const TEST = { timeout: 30_000 };

let worker;
let apple;
let google;

before(async () => {
  apple = await startFakeApple();
  google = await startFakeGoogle();
  worker = await startWorker({ migrate: true, devVars: { ...googleVars(google, APP, PUBLIC_URL), ...appleVars(apple) } });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await worker?.stop();
  await apple?.close();
  await google?.close();
});

async function me(cookie) {
  const response = await fetch(`${worker.http}/v1/me`, { headers: { Cookie: cookie, Origin: APP } });
  return { status: response.status, json: await response.json().catch(() => null) };
}

function outcome(response) {
  return new URL(response.headers.get("location")).searchParams.get("signin");
}

async function started() {
  const response = await fetch(`${worker.http}/auth/apple/start?return_to=${encodeURIComponent(`${APP}/#/settings`)}`, { redirect: "manual" });
  const location = response.headers.get("location");
  return { response, location, state: new URL(location).searchParams.get("state"), cookie: `__Host-dl_signin_apple=${cookiesOf(response)["__Host-dl_signin_apple"].value}` };
}

test("starting a sign-in sends the browser to Apple for a posted answer with name and email", TEST, async () => {
  const { response, location } = await started();
  assert.equal(response.status, 302);
  const url = new URL(location);
  assert.equal(`${url.origin}${url.pathname}`, `${apple.url}/auth/authorize`);
  const params = url.searchParams;
  assert.equal(params.get("client_id"), SERVICES_ID);
  assert.equal(params.get("redirect_uri"), `${PUBLIC_URL}/auth/apple/callback`);
  assert.equal(params.get("response_type"), "code");
  assert.equal(params.get("response_mode"), "form_post");
  assert.equal(params.get("scope"), "name email");
  assert.match(params.get("state"), /^[\w-]{20,}$/);
  assert.match(params.get("nonce"), /^[\w-]{20,}$/);
  const cookie = cookiesOf(response)["__Host-dl_signin_apple"];
  assert.equal(cookie.value, params.get("state"));
  for (const attribute of ["secure", "httponly", "path=/", "samesite=none"]) {
    assert.ok(cookie.attributes.includes(attribute), `${attribute}: Apple's form is a POST from appleid.apple.com`);
  }
});

test("a sign-in with Apple makes an account, with the name Apple posted the first time", TEST, async () => {
  const person = { ...APPLE_PERSON, sub: "001.first", email: "Noam.First@Example.com" };
  const first = await signInWithApple(worker.http, apple, person, APP);
  assert.equal(first.response.status, 303, "after Apple's POST the app loads with GET");
  assert.equal(outcome(first.response), "ok");
  assert.equal(new URL(first.response.headers.get("location")).hash, "#/settings");
  const account = await me(first.cookie);
  assert.equal(account.status, 200);
  assert.equal(account.json.email, "noam.first@example.com");
  assert.equal(account.json.name, "Noam Cohen");
  assert.deepEqual(account.json.providers, ["apple"]);
  assert.ok(apple.secrets.length > 0, "the Worker proved itself with a client secret Apple accepted");

  const again = await signInWithApple(worker.http, apple, person, APP, { withUser: false });
  const later = await me(again.cookie);
  assert.equal(later.json.id, account.json.id, "the same Apple ID is the same account");
  assert.equal(later.json.name, "Noam Cohen", "Apple sends the name only once; it is kept");
});

test("Apple and Google with the same email are one account; Hide My Email is another", TEST, async () => {
  const email = "both@example.com";
  const viaGoogle = await signInAs(worker.http, google, { sub: "google-both", email, name: "Both Google" }, APP);
  const googleAccount = await me(viaGoogle);
  const viaApple = await signInWithApple(worker.http, apple, { sub: "001.both", email: "Both@Example.com", firstName: "Both", lastName: "Apple" }, APP);
  const appleAccount = await me(viaApple.cookie);
  assert.equal(appleAccount.json.id, googleAccount.json.id, "a second provider joins the account with that verified email");
  assert.deepEqual(appleAccount.json.providers, ["google", "apple"]);
  assert.equal(appleAccount.json.name, "Both Google", "the account keeps its name");

  const hidden = await signInWithApple(worker.http, apple, { sub: "001.hidden", email: "x7k2abc@privaterelay.appleid.com", private: true }, APP);
  const hiddenAccount = await me(hidden.cookie);
  assert.notEqual(hiddenAccount.json.id, googleAccount.json.id);
  assert.equal(hiddenAccount.json.email, "x7k2abc@privaterelay.appleid.com");
  assert.equal(hiddenAccount.json.name, null);
});

test("Apple's answer counts only for the sign-in this browser started, at Apple's own callback", TEST, async () => {
  const noCookie = await started();
  assert.equal(outcome(await postBack(worker.http, { state: noCookie.state, code: apple.approve(noCookie.location) })), "expired");

  const googleStart = await fetch(`${worker.http}/auth/google/start?return_to=${encodeURIComponent(`${APP}/#/settings`)}`, { redirect: "manual" });
  const googleState = new URL(googleStart.headers.get("location")).searchParams.get("state");
  assert.equal(outcome(await postBack(worker.http, { state: googleState, code: "x" }, `__Host-dl_signin_apple=${googleState}`)), "expired", "a Google sign-in's state does not work here");

  const once = await started();
  const code = apple.approve(once.location);
  assert.equal(outcome(await postBack(worker.http, { state: once.state, code }, once.cookie)), "ok");
  assert.equal(outcome(await postBack(worker.http, { state: once.state, code }, once.cookie)), "expired", "each state works once");

  const cancelled = await started();
  assert.equal(outcome(await postBack(worker.http, { state: cancelled.state, error: "user_cancelled_authorize" }, cancelled.cookie)), "cancelled");

  const get = await fetch(`${worker.http}/auth/apple/callback?state=x&code=y`, { redirect: "manual" });
  assert.equal(get.status, 405);
});

test("forged, foreign and unverified ID tokens are refused", TEST, async () => {
  for (const [options, expected] of [
    [{ forged: true }, "failed"],
    [{ claims: { nonce: "another-sign-in" } }, "failed"],
    [{ claims: { aud: "another.app" } }, "failed"],
    [{ claims: { iss: "https://appleid.example" } }, "failed"],
    [{ claims: { exp: Math.floor(Date.now() / 1000) - 3600 } }, "failed"],
    [{ claims: { email_verified: "false" } }, "unverified"],
    [{ claims: { email: undefined } }, "unverified"],
  ]) {
    const attempt = await signInWithApple(worker.http, apple, { ...APPLE_PERSON, sub: `001.refused.${expected}` }, APP, options);
    assert.equal(outcome(attempt.response), expected, JSON.stringify(options));
    assert.equal(attempt.cookie, null, "no session");
  }
});

test("deleting the account deletes its Apple sign-in too", TEST, async () => {
  const person = { ...APPLE_PERSON, sub: "001.delete", email: "delete.me@example.com" };
  const first = await signInWithApple(worker.http, apple, person, APP);
  const before = await me(first.cookie);
  const deleted = await fetch(`${worker.http}/v1/me`, { method: "DELETE", headers: { Cookie: first.cookie, Origin: APP } });
  assert.equal(deleted.status, 204);
  const again = await signInWithApple(worker.http, apple, person, APP);
  const after = await me(again.cookie);
  assert.notEqual(after.json.id, before.json.id, "a new account");
});
