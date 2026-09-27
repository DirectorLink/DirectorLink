// Accounts (cloud/src/accounts.js) end to end: the Worker under `wrangler dev` (worker.mjs) with its
// D1 database, and a fake Google that signs ID tokens with a test key.
//   node --test tests/cloud/accounts.test.mjs

import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { createServer } from "node:http";
import { after, before, test } from "node:test";

import { STARTUP_MS, freePort, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const CLIENT_ID = "test-client";
const CLIENT_SECRET = "test-secret";
const PUBLIC_URL = "https://api.directorlink.test";
const TEST = { timeout: 30_000 };

let worker;
let google;

before(async () => {
  google = await startFakeGoogle();
  worker = await startWorker({
    migrate: true,
    devVars: {
      GOOGLE_CLIENT_ID: CLIENT_ID,
      GOOGLE_CLIENT_SECRET: CLIENT_SECRET,
      GOOGLE_AUTH_URL: `${google.url}/auth`,
      GOOGLE_TOKEN_URL: `${google.url}/token`,
      GOOGLE_JWKS_URL: `${google.url}/certs`,
      GOOGLE_ISSUER: google.url,
      APP_ORIGINS: APP,
      PUBLIC_URL: PUBLIC_URL,
    },
  });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await worker?.stop();
  await google?.close();
});

// --- A fake Google ---------------------------------------------------------------------------------

function base64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function keyPair(kid) {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  return { kid, privateKey, jwk: { ...publicKey.export({ format: "jwk" }), kid, alg: "RS256", use: "sig" } };
}

async function startFakeGoogle() {
  const key = keyPair("google-test-key");
  const stranger = keyPair("google-test-key"); // same kid, other key: a forged signature
  const codes = new Map();
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;

  function idToken(claims, signer = key) {
    const header = base64url(JSON.stringify({ alg: "RS256", kid: signer.kid, typ: "JWT" }));
    const payload = base64url(JSON.stringify(claims));
    const signature = sign("RSA-SHA256", Buffer.from(`${header}.${payload}`), signer.privateKey);
    return `${header}.${payload}.${base64url(signature)}`;
  }

  const server = createServer(async (request, response) => {
    const answer = (status, body) => {
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
    };
    if (request.url === "/certs") {
      return answer(200, { keys: [key.jwk] });
    }
    if (request.url === "/token" && request.method === "POST") {
      let text = "";
      for await (const chunk of request) text += chunk;
      const form = new URLSearchParams(text);
      const grant = codes.get(form.get("code"));
      codes.delete(form.get("code"));
      const challenge = base64url(createHash("sha256").update(form.get("code_verifier") ?? "").digest());
      if (
        !grant ||
        form.get("grant_type") !== "authorization_code" ||
        form.get("client_id") !== CLIENT_ID ||
        form.get("client_secret") !== CLIENT_SECRET ||
        form.get("redirect_uri") !== grant.redirectUri ||
        challenge !== grant.challenge
      ) {
        return answer(400, { error: "invalid_grant" });
      }
      const now = Math.floor(Date.now() / 1000);
      const claims = {
        iss: url,
        aud: CLIENT_ID,
        sub: grant.person.sub,
        email: grant.person.email,
        email_verified: true,
        name: grant.person.name,
        iat: now,
        exp: now + 3600,
        nonce: grant.nonce,
        ...grant.claims,
      };
      return answer(200, { id_token: idToken(claims, grant.forged ? stranger : key), token_type: "Bearer", expires_in: 3599 });
    }
    return answer(404, { error: "not_found" });
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));

  return {
    url,
    // The person approves the request at Google: returns the code Google would redirect with.
    approve(authorizationUrl, { person = PERSON, claims = {}, forged = false } = {}) {
      const params = new URL(authorizationUrl).searchParams;
      const code = base64url(randomBytes(16));
      codes.set(code, { nonce: params.get("nonce"), challenge: params.get("code_challenge"), redirectUri: params.get("redirect_uri"), person, claims, forged });
      return code;
    },
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

const PERSON = { sub: "google-user-1", email: "Dana.Levi@Example.com", name: "Dana Levi" };

// --- Helpers ---------------------------------------------------------------------------------------

function cookiesOf(response) {
  const cookies = {};
  for (const line of response.headers.getSetCookie()) {
    const [pair, ...attributes] = line.split(";").map((part) => part.trim());
    const index = pair.indexOf("=");
    cookies[pair.slice(0, index)] = { value: pair.slice(index + 1), attributes: attributes.map((a) => a.toLowerCase()) };
  }
  return cookies;
}

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

test("/v1/me without a session is 401", TEST, async () => {
  assert.equal((await me(null)).status, 401);
  assert.equal((await me("__Host-dl_session=not-a-session")).status, 401);
});
