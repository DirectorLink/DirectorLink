// Accounts (cloud/src/accounts.js) end to end: the Worker under `wrangler dev` (worker.mjs) with its
// D1 database, and a fake Google that signs ID tokens with a test key. Sessions that renew while
// used (1.13.2, ADR-089) here once, with D1 changed and read as the integrator reads production's;
// every case in tests/cloud/sessions.test.mjs.
//   node --test tests/cloud/accounts.test.mjs

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { after, before, test } from "node:test";

import { CLIENT_ID, PERSON, cookiesOf, googleVars, startFakeGoogle } from "./fake-google.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const PUBLIC_URL = "https://api.directorlink.test";
const TEST = { timeout: 30_000 };

let worker;
let google;

before(async () => {
  google = await startFakeGoogle();
  worker = await startWorker({
    migrate: true,
    // wrangler.jsonc has Apple's public ids, but no key here: Apple sign-in is off. Its
    // notifications are off too without the App ID.
    devVars: { ...googleVars(google, APP, PUBLIC_URL), APPLE_APP_ID: "" },
  });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await worker?.stop();
  await google?.close();
});

// --- Helpers ---------------------------------------------------------------------------------------

function get(path, { cookie, origin, method = "GET" } = {}) {
  const headers = {};
  if (cookie) headers.Cookie = cookie;
  if (origin) headers.Origin = origin;
  return fetch(`${worker.http}${path}`, { method, headers, redirect: "manual" });
}

async function start(returnTo = `${APP}/#/settings`) {
  const response = await get(`/auth/google/start?return_to=${encodeURIComponent(returnTo)}`);
  assert.equal(response.status, 302);
  const signIn = cookiesOf(response)["__Host-dl_signin"];
  assert.ok(signIn?.value, "the sign-in cookie is set");
  return { location: response.headers.get("location"), signInCookie: `__Host-dl_signin=${signIn.value}`, signIn };
}

async function callback(started, query) {
  return get(`/auth/google/callback?${new URLSearchParams(query)}`, { cookie: started.signInCookie });
}

// A whole sign-in. Returns the redirect back to the app and the session cookie.
async function signIn(options = {}) {
  const started = await start(options.returnTo);
  const code = google.approve(started.location, options);
  const state = new URL(started.location).searchParams.get("state");
  const response = await callback(started, { code, state });
  assert.equal(response.status, 302);
  const back = new URL(response.headers.get("location"));
  const session = cookiesOf(response)["__Host-dl_session"];
  return { back, session, cookie: session?.value ? `__Host-dl_session=${session.value}` : null };
}

async function me(cookie) {
  const response = await get("/v1/me", { cookie, origin: APP });
  return { status: response.status, headers: response.headers, json: await response.json().catch(() => null) };
}

// The Worker's D1, as the integrator reads production's (cloud/README.md), --local for --remote.
function d1(sql) {
  const run = spawnSync(`npx --yes wrangler@4.143.0 d1 execute directorlink --local --json --command "${sql}"`, {
    cwd: worker.dir,
    shell: true,
    windowsHide: true,
    encoding: "utf8",
    env: { ...process.env, WRANGLER_SEND_METRICS: "false", NO_COLOR: "1", FORCE_COLOR: "0", CI: "1" },
    timeout: STARTUP_MS,
  });
  assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}`);
  return JSON.parse(run.stdout)[0].results;
}

const DAY_MS = 24 * 3600 * 1000;

// --- Tests -----------------------------------------------------------------------------------------

test("starting a sign-in sends the browser to Google with PKCE, a state and a nonce", TEST, async () => {
  const started = await start();
  const url = new URL(started.location);
  assert.equal(`${url.origin}${url.pathname}`, `${google.url}/auth`);
  const params = url.searchParams;
  assert.equal(params.get("client_id"), CLIENT_ID);
  assert.equal(params.get("redirect_uri"), `${PUBLIC_URL}/auth/google/callback`, "the registered address, not the request's");
  assert.equal(params.get("response_type"), "code");
  assert.equal(params.get("scope"), "openid email profile");
  assert.equal(params.get("code_challenge_method"), "S256");
  assert.match(params.get("code_challenge"), /^[A-Za-z0-9_-]{43}$/);
  assert.match(params.get("state"), /^[A-Za-z0-9_-]{43}$/);
  assert.match(params.get("nonce"), /^[A-Za-z0-9_-]{43}$/);
  assert.equal(started.signIn.value, params.get("state"), "the cookie holds this sign-in's state");
  for (const attribute of ["path=/", "secure", "httponly", "samesite=lax", "max-age=600"]) {
    assert.ok(started.signIn.attributes.includes(attribute), `sign-in cookie: ${attribute}`);
  }
});

test("a sign-in creates the account and a session; /v1/me shows it", TEST, async () => {
  const result = await signIn({ person: { sub: "google-user-me", email: "Noa@Example.com", name: "Noa" } });
  assert.equal(result.back.origin, APP);
  assert.equal(result.back.searchParams.get("signin"), "ok");
  assert.equal(result.back.hash, "#/settings");
  for (const attribute of ["path=/", "secure", "httponly", "samesite=strict", "max-age=2592000"]) {
    assert.ok(result.session.attributes.includes(attribute), `session cookie: ${attribute}`);
  }
  const account = await me(result.cookie);
  assert.equal(account.status, 200);
  assert.match(account.json.id, /^[0-9a-f]{32}$/);
  assert.equal(account.json.email, "noa@example.com", "stored in lowercase");
  assert.deepEqual(account.json.providers, ["google"]);
  assert.equal(account.json.name, "Noa");
  assert.ok(!Number.isNaN(Date.parse(account.json.created_at)));
  assert.equal(account.headers.get("access-control-allow-origin"), APP);
  assert.equal(account.headers.get("access-control-allow-credentials"), "true");
});

test("signing in again keeps the same account and takes the new name", TEST, async () => {
  const first = await me((await signIn({ person: { sub: "google-user-again", email: "a@example.com", name: "Avi" } })).cookie);
  const second = await me((await signIn({ person: { sub: "google-user-again", email: "a@example.com", name: "Avi Cohen" } })).cookie);
  assert.equal(second.json.id, first.json.id);
  assert.equal(second.json.name, "Avi Cohen");
});

test("the callback only accepts the state this browser started, once", TEST, async () => {
  const started = await start();
  const state = new URL(started.location).searchParams.get("state");
  const code = google.approve(started.location);

  const otherBrowser = await get(`/auth/google/callback?${new URLSearchParams({ code, state })}`, { cookie: "__Host-dl_signin=someone-else" });
  assert.equal(new URL(otherBrowser.headers.get("location")).searchParams.get("signin"), "expired");
  assert.equal(cookiesOf(otherBrowser)["__Host-dl_session"], undefined);

  // That attempt used the state up, even for the right browser.
  const again = await callback(started, { code, state });
  assert.equal(new URL(again.headers.get("location")).searchParams.get("signin"), "expired");
  assert.equal(cookiesOf(again)["__Host-dl_session"], undefined);
});

test("cancelling at Google comes back as cancelled, without a session", TEST, async () => {
  const started = await start();
  const state = new URL(started.location).searchParams.get("state");
  const response = await callback(started, { error: "access_denied", state });
  assert.equal(new URL(response.headers.get("location")).searchParams.get("signin"), "cancelled");
  assert.equal(cookiesOf(response)["__Host-dl_session"], undefined);
  assert.equal(cookiesOf(response)["__Host-dl_signin"].value, "", "the sign-in cookie is cleared");
});

test("ID tokens are checked: signature, audience, issuer, expiry, nonce and a verified email", TEST, async () => {
  const now = Math.floor(Date.now() / 1000);
  const cases = [
    [{ forged: true }, "failed", "a forged signature"],
    [{ claims: { aud: "another-app" } }, "failed", "another audience"],
    [{ claims: { iss: "https://accounts.example.com" } }, "failed", "another issuer"],
    [{ claims: { exp: now - 3600 } }, "failed", "an expired token"],
    [{ claims: { nonce: "another-sign-in" } }, "failed", "another sign-in's nonce"],
    [{ claims: { email_verified: false } }, "unverified", "an unverified email"],
  ];
  for (const [options, outcome, what] of cases) {
    const result = await signIn(options);
    assert.equal(result.back.searchParams.get("signin"), outcome, what);
    assert.equal(result.session, undefined, `${what}: no session`);
  }
});

test("the way back is always the app: another site in return_to is ignored", TEST, async () => {
  const result = await signIn({ returnTo: "https://evil.example/steal" });
  assert.equal(result.back.origin, APP);
  assert.equal(result.back.hash, "#/settings");
  assert.equal(result.back.searchParams.get("signin"), "ok");
});

test("signing out ends the session", TEST, async () => {
  const { cookie } = await signIn({ person: { sub: "google-user-out", email: "out@example.com", name: "Out" } });
  assert.equal((await me(cookie)).status, 200);
  const response = await get("/auth/logout", { method: "POST", cookie, origin: APP });
  assert.equal(response.status, 204);
  assert.equal(cookiesOf(response)["__Host-dl_session"].value, "", "the cookie is cleared");
  const after = await me(cookie);
  assert.equal(after.status, 401);
  assert.equal(after.json.code, "NOT_SIGNED_IN");
  assert.equal(after.headers.get("access-control-allow-origin"), APP, "the app can read the 401");
});

test("only the app's own pages may sign out or delete an account", TEST, async () => {
  const { cookie } = await signIn({ person: { sub: "google-user-origin", email: "o@example.com", name: "O" } });
  for (const [path, method] of [["/auth/logout", "POST"], ["/v1/me", "DELETE"]]) {
    const foreign = await get(path, { method, cookie, origin: "https://evil.example" });
    assert.equal(foreign.status, 403, `${method} ${path} from another site`);
    assert.equal((await foreign.json()).code, "ORIGIN_NOT_ALLOWED");
    const bare = await get(path, { method, cookie });
    assert.equal(bare.status, 403, `${method} ${path} without an Origin`);
  }
  assert.equal((await me(cookie)).status, 200, "still signed in");

  const preflight = await fetch(`${worker.http}/v1/me`, {
    method: "OPTIONS",
    headers: { Origin: APP, "Access-Control-Request-Method": "DELETE" },
  });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-origin"), APP);
  assert.equal(preflight.headers.get("access-control-allow-credentials"), "true");
  assert.match(preflight.headers.get("access-control-allow-methods"), /DELETE/);
  const foreignPreflight = await fetch(`${worker.http}/v1/me`, { method: "OPTIONS", headers: { Origin: "https://evil.example" } });
  assert.equal(foreignPreflight.status, 403);
});

test("deleting the account removes it and every session", TEST, async () => {
  const person = { sub: "google-user-delete", email: "delete@example.com", name: "Delete" };
  const one = await signIn({ person });
  const two = await signIn({ person });
  const before = await me(one.cookie);
  const response = await get("/v1/me", { method: "DELETE", cookie: one.cookie, origin: APP });
  assert.equal(response.status, 204);
  assert.equal(cookiesOf(response)["__Host-dl_session"].value, "");
  assert.equal((await me(one.cookie)).status, 401);
  assert.equal((await me(two.cookie)).status, 401, "the other device's session is gone too");
  const fresh = await me((await signIn({ person })).cookie);
  assert.notEqual(fresh.json.id, before.json.id, "signing in again starts a new account");
});

test("a session used near its end is renewed: 30 days from then, its cookie sent again, once a day; an expired one is not", { timeout: 180_000 }, async () => {
  const signedIn = await signIn({ person: { sub: "google-user-renew", email: "renew@example.com", name: "Renew" } });
  const hash = createHash("sha256").update(signedIn.session.value).digest("hex");
  const endInD1 = () => Date.parse(d1(`SELECT expires_at FROM sessions WHERE token_sha256 = '${hash}'`)[0].expires_at);
  // As if signed in 25 days ago: 5 days left.
  d1(`UPDATE sessions SET expires_at = '${new Date(Date.now() + 5 * DAY_MS).toISOString()}' WHERE token_sha256 = '${hash}'`);
  const before = Date.now();
  const renewed = await me(signedIn.cookie);
  const after = Date.now();
  assert.equal(renewed.status, 200);
  const cookie = cookiesOf({ headers: renewed.headers })["__Host-dl_session"];
  assert.equal(cookie?.value, signedIn.session.value, "the same token, sent again");
  for (const attribute of ["path=/", "secure", "httponly", "samesite=strict", "max-age=2592000"]) {
    assert.ok(cookie.attributes.includes(attribute), `renewed cookie: ${attribute}`);
  }
  assert.equal(renewed.headers.get("access-control-allow-credentials"), "true", "so the browser keeps it");
  const end = endInD1();
  assert.ok(end >= before + 30 * DAY_MS - 1000 && end <= after + 30 * DAY_MS, `D1: 30 days from now, not ${new Date(end).toISOString()}`);

  // Again the same day: nothing changes.
  const again = await me(signedIn.cookie);
  assert.equal(again.status, 200);
  assert.equal(cookiesOf({ headers: again.headers })["__Host-dl_session"], undefined);
  assert.equal(endInD1(), end);

  // The home routes renew it as well.
  d1(`UPDATE sessions SET expires_at = '${new Date(Date.now() + 2 * DAY_MS).toISOString()}' WHERE token_sha256 = '${hash}'`);
  const homes = await get("/v1/homes", { cookie: signedIn.cookie, origin: APP });
  assert.equal(homes.status, 200);
  assert.equal(cookiesOf(homes)["__Host-dl_session"]?.value, signedIn.session.value);
  assert.equal(homes.headers.get("access-control-allow-credentials"), "true");
  assert.ok(endInD1() > Date.now() + 29 * DAY_MS);

  // An expired session stays expired.
  const ended = new Date(Date.now() - 60_000).toISOString();
  d1(`UPDATE sessions SET expires_at = '${ended}' WHERE token_sha256 = '${hash}'`);
  const expired = await me(signedIn.cookie);
  assert.equal(expired.status, 401);
  assert.equal(cookiesOf({ headers: expired.headers })["__Host-dl_session"], undefined);
  assert.equal(endInD1(), Date.parse(ended));
});

test("/v1/me without a session is 401", TEST, async () => {
  assert.equal((await me(null)).status, 401);
  assert.equal((await me("__Host-dl_session=not-a-session")).status, 401);
});

test("Sign in with Apple answers 503 until it is set up", TEST, async () => {
  const response = await get(`/auth/apple/start?return_to=${encodeURIComponent(`${APP}/#/settings`)}`);
  assert.equal(response.status, 503);
  assert.equal((await response.json()).code, "SIGN_IN_NOT_CONFIGURED");
});

test("the app is told only the sign-ins that are set up, so Apple's button stays hidden without its key", TEST, async () => {
  const response = await get("/auth/providers", { origin: APP });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { providers: ["google"] });
  assert.equal(response.headers.get("access-control-allow-origin"), APP);
  assert.equal(response.headers.get("access-control-allow-credentials"), null, "no cookie is needed or sent");
  assert.equal((await get("/auth/providers", { origin: "https://attacker.example" })).headers.get("access-control-allow-origin"), null);
  const { cookie } = await signIn({ person: { ...PERSON, sub: "google-providers", email: "providers@example.com" } });
  assert.deepEqual((await me(cookie)).json.sign_in_providers, ["google"], "and in /v1/me");
});

test("Apple's notifications answer 503 until the App ID is set", TEST, async () => {
  const response = await fetch(`${worker.http}/auth/apple/notifications`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ payload: "x.y.z" }) });
  assert.equal(response.status, 503);
  assert.equal((await response.json()).code, "NOTIFICATIONS_NOT_CONFIGURED");
});
