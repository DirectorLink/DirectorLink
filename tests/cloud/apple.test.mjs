// Sign in with Apple (cloud/src/apple.js, accounts.js) end to end: the Worker under `wrangler dev`
// with a fake Apple that checks the Worker's ES256 client secret and signs ID tokens with a test
// key, and a fake Google for accounts that use both.
//   node --test tests/cloud/apple.test.mjs

import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { APPLE_PERSON, SERVICES_ID, appleVars, postBack, postNotification, signInWithApple, startFakeApple } from "./fake-apple.mjs";
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

test("signing out before Apple answers cancels adding it", TEST, async () => {
  const cookie = await signInAs(worker.http, google, { sub: "google-shared-pc", email: "shared.pc@example.com", name: "Shared" }, APP);
  const start = await fetch(`${worker.http}/auth/apple/start?link=1&return_to=${encodeURIComponent(`${APP}/#/settings`)}`, { redirect: "manual", headers: { Cookie: cookie } });
  const location = start.headers.get("location");
  const signIn = `__Host-dl_signin_apple=${cookiesOf(start)["__Host-dl_signin_apple"].value}`;
  assert.equal((await fetch(`${worker.http}/auth/logout`, { method: "POST", headers: { Cookie: cookie, Origin: APP } })).status, 204);
  const code = apple.approve(location, { person: { sub: "001.someone-else", email: "someone.else@example.com" } });
  const back = await postBack(worker.http, { state: new URL(location).searchParams.get("state"), code }, signIn);
  assert.equal(outcome(back), "expired", "the session that asked is gone");
  const later = await signInWithApple(worker.http, apple, { sub: "001.someone-else", email: "someone.else@example.com" }, APP);
  assert.deepEqual((await me(later.cookie)).json.providers, ["apple"], "that Apple ID was not added to the shared account");
});

test("an account stops signing in with one provider, but keeps the last", TEST, async () => {
  const cookie = await signInAs(worker.http, google, { sub: "google-unlink", email: "unlink@example.com", name: "Unlink" }, APP);
  const person = { sub: "001.unlink", email: "unlink.apple@example.com" };
  assert.equal(outcome((await signInWithApple(worker.http, apple, person, APP, { link: cookie })).response), "linked");
  const remove = (provider, origin = APP) => fetch(`${worker.http}/v1/me/identities/${provider}`, { method: "DELETE", headers: { Cookie: cookie, Origin: origin } });
  assert.equal((await remove("apple", "https://attacker.example")).status, 403, "only the app's pages");
  assert.equal((await remove("apple")).status, 204);
  assert.deepEqual((await me(cookie)).json.providers, ["google"]);
  assert.equal((await remove("apple")).status, 404);
  const last = await remove("google");
  assert.equal(last.status, 409);
  assert.equal((await last.json()).code, "LAST_SIGN_IN");
  const viaApple = await signInWithApple(worker.http, apple, person, APP);
  assert.notEqual((await me(viaApple.cookie)).json.id, (await me(cookie)).json.id, "that Apple ID is its own account again");
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

// --- Apple's server-to-server notifications (ADR-041) ------------------------------------------------

test("the app learns that Apple sign-in is set up, before and after signing in", TEST, async () => {
  const response = await fetch(`${worker.http}/auth/providers`, { headers: { Origin: APP } });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).providers, ["google", "apple"]);
  assert.equal(response.headers.get("access-control-allow-origin"), APP);
  const signedIn = await signInWithApple(worker.http, apple, { ...APPLE_PERSON, sub: "001.providers", email: "providers@example.com" }, APP);
  assert.deepEqual((await me(signedIn.cookie)).json.sign_in_providers, ["google", "apple"]);
});

test("only notifications Apple signed for DirectorLink's App ID count", TEST, async () => {
  const person = { ...APPLE_PERSON, sub: "001.notice.checked", email: "checked@example.com" };
  const { cookie } = await signInWithApple(worker.http, apple, person, APP);
  const revoked = { type: "consent-revoked", sub: person.sub };
  for (const [what, payload] of [
    ["another key", apple.notification(revoked, { forged: true })],
    ["an unknown key id", apple.notification(revoked, { kid: "not-apples" })],
    ["the Services ID (an ID token's audience)", apple.notification(revoked, { claims: { aud: SERVICES_ID } })],
    ["another issuer", apple.notification(revoked, { claims: { iss: "https://appleid.example" } })],
    ["expired", apple.notification(revoked, { claims: { exp: Math.floor(Date.now() / 1000) - 3600 } })],
    ["no event", apple.notification({ sub: person.sub })],
    ["an unknown event", apple.notification({ type: "password-changed", sub: person.sub })],
    ["no account", apple.notification({ type: "consent-revoked" })],
    ["not a JWT", "not.a.jwt"],
  ]) {
    const response = await postNotification(worker.http, payload);
    assert.equal(response.status, 400, what);
    assert.equal((await response.json()).code, "INVALID_NOTIFICATION", what);
  }
  assert.equal((await postNotification(worker.http, null, { body: "{}" })).status, 400, "no payload");
  assert.equal((await postNotification(worker.http, null, { body: JSON.stringify({ payload: "x".repeat(20 * 1024) }) })).status, 400, "more than 16 KiB");
  assert.equal((await fetch(`${worker.http}/auth/apple/notifications`)).status, 405);
  assert.equal((await me(cookie)).status, 200, "none of them changed anything");
});

test("Apple's consent-revoked removes that Apple sign-in; an account left without one is signed out everywhere", TEST, async () => {
  const person = { ...APPLE_PERSON, sub: "001.notice.revoked", email: "revoked@example.com" };
  const first = await signInWithApple(worker.http, apple, person, APP);
  const second = await signInWithApple(worker.http, apple, person, APP, { withUser: false });
  const account = (await me(first.cookie)).json;
  const response = await postNotification(worker.http, apple.notification({ type: "consent-revoked", sub: person.sub }));
  assert.equal(response.status, 200);
  assert.equal((await me(first.cookie)).status, 401, "signed out");
  assert.equal((await me(second.cookie)).status, 401, "on every device");
  assert.equal((await postNotification(worker.http, apple.notification({ type: "consent-revoked", sub: person.sub }))).status, 200, "the same notice twice");

  // The account itself stays (with its homes, homes.test.mjs): the same Apple ID gets it back.
  const again = await signInWithApple(worker.http, apple, person, APP, { withUser: false });
  const back = (await me(again.cookie)).json;
  assert.equal(back.id, account.id);
  assert.deepEqual(back.providers, ["apple"]);
  assert.equal(back.name, "Noam Cohen");
});

test("Apple's account-delete leaves an account that also signs in with Google signed in with Google", TEST, async () => {
  const cookie = await signInAs(worker.http, google, { sub: "google-both-notice", email: "both.notice@example.com", name: "Both" }, APP);
  const person = { sub: "001.notice.both", email: "both.apple@example.com" };
  assert.equal(outcome((await signInWithApple(worker.http, apple, person, APP, { link: cookie })).response), "linked");
  // Apple writes `events` as a string; an object is read as well.
  const response = await postNotification(worker.http, apple.notification({ type: "account-delete", sub: person.sub }, { eventsObject: true }));
  assert.equal(response.status, 200);
  const after = await me(cookie);
  assert.equal(after.status, 200, "its sessions stay");
  assert.deepEqual(after.json.providers, ["google"]);
  assert.equal((await postNotification(worker.http, apple.notification({ type: "account-delete", sub: "001.never-seen" }))).status, 200, "an Apple ID with no account");
});

test("a notice from before the person last signed in with that Apple ID changes nothing", TEST, async () => {
  const person = { ...APPLE_PERSON, sub: "001.notice.stale", email: "stale@example.com" };
  const { cookie } = await signInWithApple(worker.http, apple, person, APP);
  const hourAgo = Math.floor(Date.now() / 1000) - 3600;
  assert.equal((await postNotification(worker.http, apple.notification({ type: "consent-revoked", sub: person.sub, event_time: hourAgo }))).status, 200);
  assert.equal((await me(cookie)).status, 200, "a late or replayed notice: the person signed in again since");
  // Apple's time in milliseconds counts too.
  assert.equal((await postNotification(worker.http, apple.notification({ type: "consent-revoked", sub: person.sub, event_time: Date.now() }))).status, 200);
  assert.equal((await me(cookie)).status, 401);
});

test("Hide My Email forwarding turned off or on: the stored address follows Apple's", TEST, async () => {
  const person = { sub: "001.notice.relay", email: "k2m9x@privaterelay.appleid.com", private: true };
  const { cookie } = await signInWithApple(worker.http, apple, person, APP);
  const disabled = apple.notification({ type: "email-disabled", sub: person.sub, email: "K7Q4Z@privaterelay.appleid.com", is_private_email: "true" });
  assert.equal((await postNotification(worker.http, disabled)).status, 200);
  const account = await me(cookie);
  assert.equal(account.status, 200, "still signed in");
  assert.equal(account.json.email, "k7q4z@privaterelay.appleid.com");
  assert.equal((await postNotification(worker.http, apple.notification({ type: "email-enabled", sub: person.sub }))).status, 200);
  assert.equal((await me(cookie)).json.email, "k7q4z@privaterelay.appleid.com", "no address given: kept");
});
