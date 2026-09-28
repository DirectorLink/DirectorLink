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
  assert.ok(location.includes("scope=name%20email"), "Apple asks for %20 between scopes, not +");
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

test("accounts are never joined by email: another provider or a reused address makes a new account", TEST, async () => {
  const email = "reused@example.com";
  const first = await me(await signInAs(worker.http, google, { sub: "google-reused-1", email, name: "First" }, APP));
  const later = await me(await signInAs(worker.http, google, { sub: "google-reused-2", email, name: "Later" }, APP));
  assert.notEqual(later.json.id, first.json.id, "a new Google account with the same address is someone else");
  const viaApple = await signInWithApple(worker.http, apple, { sub: "001.reused", email: "Reused@Example.com", firstName: "Apple", lastName: "Person" }, APP);
  const appleAccount = await me(viaApple.cookie);
  assert.notEqual(appleAccount.json.id, first.json.id, "Apple with that address is its own account until it is added");
  assert.deepEqual(appleAccount.json.providers, ["apple"]);
  assert.equal(appleAccount.json.email, email, "and can still accept invitations for that address");

  const hidden = await signInWithApple(worker.http, apple, { sub: "001.hidden", email: "x7k2abc@privaterelay.appleid.com", private: true }, APP);
  assert.equal((await me(hidden.cookie)).json.email, "x7k2abc@privaterelay.appleid.com");
});

test("a signed-in account adds Apple, and both then sign in to it", TEST, async () => {
  const cookie = await signInAs(worker.http, google, { sub: "google-linker", email: "linker@example.com", name: "Linker" }, APP);
  const account = await me(cookie);
  const person = { sub: "001.linker", email: "linker.apple@example.com", firstName: "L", lastName: "A" };
  const linked = await signInWithApple(worker.http, apple, person, APP, { link: cookie });
  assert.equal(outcome(linked.response), "linked");
  assert.equal(linked.cookie, null, "the account keeps its session");
  const after = await me(cookie);
  assert.deepEqual(after.json.providers, ["google", "apple"]);
  assert.equal(after.json.email, "linker@example.com", "the account's email stays Google's");
  assert.equal(after.json.name, "Linker");
  const viaApple = await signInWithApple(worker.http, apple, person, APP, { withUser: false });
  assert.equal((await me(viaApple.cookie)).json.id, account.json.id, "Apple now signs in to the same account");

  const again = await signInWithApple(worker.http, apple, person, APP, { link: cookie });
  assert.equal(outcome(again.response), "linked", "adding it twice changes nothing");
  const second = await signInWithApple(worker.http, apple, { sub: "001.linker.2", email: "other@example.com" }, APP, { link: cookie });
  assert.equal(outcome(second.response), "duplicate", "one Apple ID per account");

  const other = await signInAs(worker.http, google, { sub: "google-other-linker", email: "other.linker@example.com", name: "Other" }, APP);
  const taken = await signInWithApple(worker.http, apple, person, APP, { link: other });
  assert.equal(outcome(taken.response), "taken", "an Apple ID that belongs to another account");
  assert.deepEqual((await me(other)).json.providers, ["google"]);

  const noSession = await fetch(`${worker.http}/auth/apple/start?link=1&return_to=${encodeURIComponent(`${APP}/#/settings`)}`, { redirect: "manual" });
  assert.equal(new URL(noSession.headers.get("location")).searchParams.get("signin"), "expired", "adding needs the session: from another site nothing is linked");
});

test("a returning Apple ID is found by its id even when Apple leaves out the email", TEST, async () => {
  const person = { ...APPLE_PERSON, sub: "001.no-email-later", email: "later@example.com" };
  const first = await signInWithApple(worker.http, apple, person, APP);
  const account = await me(first.cookie);
  const later = await signInWithApple(worker.http, apple, person, APP, { withUser: false, claims: { email: undefined, email_verified: undefined } });
  assert.equal(outcome(later.response), "ok");
  const again = await me(later.cookie);
  assert.equal(again.json.id, account.json.id);
  assert.equal(again.json.email, "later@example.com", "the email it had is kept");
});

test("a callback body larger than 16 KiB is not read, even without Content-Length", TEST, async () => {
  const big = "state=x&code=" + "a".repeat(64 * 1024);
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode(big));
      controller.close();
    },
  });
  const response = await fetch(`${worker.http}/auth/apple/callback`, {
    method: "POST",
    redirect: "manual",
    duplex: "half",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: stream,
  });
  assert.equal(response.status, 303);
  assert.equal(outcome(response), "expired");
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
