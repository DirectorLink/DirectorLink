// Homes (cloud/src/homes.js) end to end: the Worker under `wrangler dev`, a fake Google, and a fake
// controller that seals and opens with the lock (lock.mjs) like the driver does.
//   node --test tests/cloud/homes.test.mjs

import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { after, afterEach, before, test } from "node:test";

import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { appleVars, signInWithApple, startFakeApple } from "./fake-apple.mjs";
import { cookiesOf, googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { invitationKey, lockKey, open, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TEST = { timeout: 30_000 };
const DANA = { sub: "google-dana", email: "dana@example.com", name: "Dana" };
const AVI = { sub: "google-avi", email: "avi@example.com", name: "Avi" };
const NOA = { sub: "google-noa", email: "noa@example.com", name: "Noa" };

let worker;
let google;
let apple;
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  apple = await startFakeApple();
  worker = await startWorker({ migrate: true, devVars: { ...googleVars(google, APP, "https://api.directorlink.test"), ...appleVars(apple), REQUEST_TIMEOUT_MS: 3000 } });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await worker?.stop();
  await google?.close();
  await apple?.close();
});

afterEach(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
});

// --- A fake controller -----------------------------------------------------------------------------

const nowSeconds = () => Math.floor(Date.now() / 1000);

// A controller at a new home: keys (id -> API key) it knows, invitations (id -> secret) it made,
// and the current claim token.
async function home() {
  const state = { home: randomHex(16), keys: new Map(), invitations: new Map(), claimToken: randomHex(24), seen: [] };
  const connection = await connectDriver({ url: worker.ws, home: state.home, pingIntervalMs: 0, silenceTimeoutMs: 0 });
  drivers.push(connection);
  connection.on("unknown", (text) => {
    const message = JSON.parse(text);
    state.seen.push(message);
    const reply = (fields) => connection.sendJson({ id: message.id, ...fields });
    if (message.type === "claim") {
      return reply({ type: "claim_result", ok: message.token === state.claimToken, code: message.token === state.claimToken ? undefined : "INVALID_CLAIM" });
    }
    if (message.type === "e2e") {
      const apiKey = state.keys.get(message.envelope.key);
      if (!apiKey) {
        return reply({ type: "e2e", code: "UNKNOWN_KEY" });
      }
      const lock = lockKey(apiKey);
      const plaintext = open(lock, message.envelope, "req");
      if (!plaintext) {
        return reply({ type: "e2e", code: "BAD_MAC" });
      }
      const request = JSON.parse(plaintext);
      const answer = { id: request.id, ts: nowSeconds(), status: 200, content_type: "application/json; charset=utf-8", body: JSON.stringify({ path: request.path, method: request.method, key: message.envelope.key }) };
      return reply({ type: "e2e", envelope: seal(lock, { home: state.home, key: message.envelope.key }, "res", JSON.stringify(answer)) });
    }
    if (message.type === "join") {
      const secret = state.invitations.get(message.invitation);
      if (!secret) {
        return reply({ type: "join_result", ok: false, code: "INVITATION_NOT_FOUND" });
      }
      const lock = invitationKey(secret);
      const plaintext = open(lock, message.envelope, "req");
      if (!plaintext) {
        return reply({ type: "join_result", ok: false, code: "BAD_MAC" });
      }
      const request = JSON.parse(plaintext);
      state.invitations.delete(message.invitation);
      const id = randomHex(4);
      const key = `ak_${randomHex(24)}`;
      state.keys.set(id, key);
      const answer = { id: request.id, ts: nowSeconds(), status: 201, content_type: "application/json", body: JSON.stringify({ key, id, role: "member", name: request.body.name }) };
      return reply({ type: "join_result", ok: true, key_id: id, envelope: seal(lock, { home: state.home, key: message.invitation }, "res", JSON.stringify(answer)) });
    }
  });
  return state;
}

// --- Helpers ---------------------------------------------------------------------------------------

async function call(method, path, { cookie, body, origin = APP } = {}) {
  const headers = {};
  if (cookie) headers.Cookie = cookie;
  if (origin) headers.Origin = origin;
  if (body !== undefined) headers["content-type"] = "application/json";
  const response = await fetch(`${worker.http}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // Not JSON.
  }
  return { status: response.status, json, text, headers: response.headers };
}

const signIn = (person) => signInAs(worker.http, google, person, APP);

function sealedRequest(state, apiKey, keyId, request) {
  const plaintext = JSON.stringify({ id: randomHex(8), ts: nowSeconds(), body: null, ...request });
  return { lock: lockKey(apiKey), envelope: seal(lockKey(apiKey), { home: state.home, key: keyId }, "req", plaintext) };
}

async function e2e(cookie, state, apiKey, keyId, request = { method: "GET", path: "/v1/system" }) {
  const { lock, envelope } = sealedRequest(state, apiKey, keyId, request);
  const result = await call("POST", `/v1/homes/${state.home}/e2e`, { cookie, body: { envelope } });
  if (result.status === 200) {
    result.answer = JSON.parse(open(lock, result.json.envelope, "res"));
  }
  return result;
}

// Dana pairs at home (a key the controller knows) and claims the home.
async function claimedHome() {
  const state = await home();
  const keyId = randomHex(4);
  const apiKey = `ak_${randomHex(24)}`;
  state.keys.set(keyId, apiKey);
  const dana = await signIn(DANA);
  const claimed = await call("POST", "/v1/homes/claim", { cookie: dana, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  return { state, dana, keyId, apiKey };
}

// --- Tests -----------------------------------------------------------------------------------------

test("a home is claimed with the controller's token and shows in the account's homes", TEST, async () => {
  const state = await home();
  const dana = await signIn(DANA);
  const claimed = await call("POST", "/v1/homes/claim", { cookie: dana, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  assert.deepEqual(claimed.json, { home_id: state.home, owner: true, transferred: false });
  assert.equal(state.seen.at(-1).type, "claim", "the controller was asked");
  const homes = await call("GET", "/v1/homes", { cookie: dana });
  const mine = homes.json.items.find((item) => item.home_id === state.home);
  assert.equal(mine.owner, true);
  assert.equal(mine.connected, true);
  assert.equal(homes.headers.get("access-control-allow-origin"), APP);
});

test("a wrong claim token, or a home that is offline, claims nothing", TEST, async () => {
  const state = await home();
  const avi = await signIn(AVI);
  const wrong = await call("POST", "/v1/homes/claim", { cookie: avi, body: { home_id: state.home, claim_token: randomHex(24) } });
  assert.equal(wrong.status, 403);
  assert.equal(wrong.json.code, "INVALID_CLAIM");
  const offline = await call("POST", "/v1/homes/claim", { cookie: avi, body: { home_id: randomHex(16), claim_token: randomHex(24) } });
  assert.equal(offline.status, 503);
  assert.equal(offline.json.code, "HOME_OFFLINE");
  const bad = await call("POST", "/v1/homes/claim", { cookie: avi, body: { home_id: "nothex", claim_token: "x" } });
  assert.equal(bad.status, 400);
  assert.ok(!(await call("GET", "/v1/homes", { cookie: avi })).json.items.some((item) => item.home_id === state.home));
});

test("sealed requests reach the home and come back sealed, for members only", TEST, async () => {
  const { state, dana, keyId, apiKey } = await claimedHome();
  const answered = await e2e(dana, state, apiKey, keyId, { method: "PATCH", path: "/v1/lights/22", body: { on: true } });
  assert.equal(answered.status, 200, answered.text);
  assert.equal(answered.answer.status, 200);
  assert.deepEqual(JSON.parse(answered.answer.body), { path: "/v1/lights/22", method: "PATCH", key: keyId });
  assert.doesNotMatch(answered.text, /lights/, "the cloud's answer holds only the sealed envelope");
  const relayed = state.seen.at(-1);
  assert.equal(relayed.type, "e2e");
  assert.doesNotMatch(JSON.stringify(relayed), /lights|PATCH/, "what the relay passed on is sealed");

  const avi = await signIn(AVI);
  const stranger = await e2e(avi, state, apiKey, keyId);
  assert.equal(stranger.status, 403);
  assert.equal(stranger.json.code, "NOT_A_MEMBER");
  assert.equal((await e2e(null, state, apiKey, keyId)).status, 401);

  const unknownKey = await e2e(dana, state, `ak_${randomHex(24)}`, randomHex(4));
  assert.equal(unknownKey.status, 403);
  assert.equal(unknownKey.json.code, "UNKNOWN_KEY");
  const { envelope } = sealedRequest(state, apiKey, keyId, { method: "GET", path: "/v1/system" });
  const otherHome = await call("POST", `/v1/homes/${state.home}/e2e`, { cookie: dana, body: { envelope: { ...envelope, home: randomHex(16) } } });
  assert.equal(otherHome.status, 400);
  assert.equal(otherHome.json.code, "INVALID_ENVELOPE");
});

test("an invitation is registered by a member and accepted once, by the invited email", TEST, async () => {
  const { state, dana } = await claimedHome();
  const invitationId = randomHex(4);
  const secret = randomBytes(32).toString("hex");
  state.invitations.set(invitationId, secret);
  const expires = new Date(Date.now() + 3600_000).toISOString();
  const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: invitationId, email: "Avi@Example.com", expires_at: expires } });
  assert.equal(registered.status, 201, registered.text);
  assert.equal(registered.json.email, "avi@example.com");

  const joinBody = () => {
    const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Safari on iPhone" } };
    return { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) };
  };
  const noa = await signIn(NOA);
  const wrongPerson = await call("POST", "/v1/join", { cookie: noa, body: joinBody() });
  assert.equal(wrongPerson.status, 403);
  assert.equal(wrongPerson.json.code, "EMAIL_MISMATCH");

  const avi = await signIn(AVI);
  const joined = await call("POST", "/v1/join", { cookie: avi, body: joinBody() });
  assert.equal(joined.status, 200, joined.text);
  const answer = JSON.parse(open(invitationKey(secret), joined.json.envelope, "res"));
  assert.equal(answer.status, 201);
  const newKey = JSON.parse(answer.body);
  assert.match(newKey.key, /^ak_/);
  assert.doesNotMatch(joined.text, /ak_/, "the new key travels sealed");
  assert.equal(joined.json.member, true, "the app learns that the account now belongs to the home");

  const works = await e2e(avi, state, newKey.key, newKey.id);
  assert.equal(works.status, 200, "Avi is a member now, with his own key");
  const homes = await call("GET", "/v1/homes", { cookie: avi });
  assert.deepEqual(homes.json.items.map((item) => [item.home_id, item.owner]), [[state.home, false]]);
  const again = await call("POST", "/v1/join", { cookie: avi, body: joinBody() });
  assert.equal(again.status, 404, "an invitation works once");
  assert.equal(again.json.code, "INVITATION_NOT_FOUND");

  const outsider = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: noa, body: { invitation_id: randomHex(4), email: "x@example.com", expires_at: expires } });
  assert.equal(outsider.status, 403, "only members register invitations");
  const tooLong = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: randomHex(4), email: "x@example.com", expires_at: new Date(Date.now() + 30 * 86400_000).toISOString() } });
  assert.equal(tooLong.status, 400);
});

test("the owner sees and removes members; members may leave, the owner may not", TEST, async () => {
  const { state, dana } = await claimedHome();
  const invitationId = randomHex(4);
  const secret = randomBytes(32).toString("hex");
  state.invitations.set(invitationId, secret);
  await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: invitationId, email: AVI.email, expires_at: new Date(Date.now() + 3600_000).toISOString() } });
  const avi = await signIn(AVI);
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Avi's phone" } };
  const joined = await call("POST", "/v1/join", { cookie: avi, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) } });
  assert.equal(joined.status, 200, joined.text);

  const members = await call("GET", `/v1/homes/${state.home}/members`, { cookie: dana });
  assert.deepEqual(members.json.items.map((m) => [m.email, m.owner]), [["dana@example.com", true], ["avi@example.com", false]]);
  assert.equal((await call("GET", `/v1/homes/${state.home}/members`, { cookie: avi })).json.code, "OWNER_ONLY");
  const aviId = members.json.items[1].user_id;
  const danaId = members.json.items[0].user_id;
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${danaId}`, { cookie: avi })).json.code, "OWNER_ONLY");
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${danaId}`, { cookie: dana })).json.code, "OWNER_CANNOT_LEAVE");
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${aviId}`, { cookie: dana })).status, 204);
  const newKey = JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body);
  assert.equal((await e2e(avi, state, newKey.key, newKey.id)).json.code, "NOT_A_MEMBER", "removed");
});

test("a later claim moves the home to the new account and leaves the old members out", TEST, async () => {
  const { state, dana, keyId, apiKey } = await claimedHome();
  const noa = await signIn(NOA);
  state.claimToken = randomHex(24);
  const moved = await call("POST", "/v1/homes/claim", { cookie: noa, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(moved.status, 200, moved.text);
  assert.equal(moved.json.transferred, true);
  assert.equal((await e2e(dana, state, apiKey, keyId)).json.code, "NOT_A_MEMBER");
  assert.ok(!(await call("GET", "/v1/homes", { cookie: dana })).json.items.some((item) => item.home_id === state.home));
});

test("deleting the owner's account removes the home", TEST, async () => {
  const state = await home();
  const person = { sub: "google-owner-delete", email: "owner@example.com", name: "Owner" };
  const owner = await signIn(person);
  await call("POST", "/v1/homes/claim", { cookie: owner, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal((await call("DELETE", "/v1/me", { cookie: owner })).status, 204);
  const again = await signIn(person);
  assert.deepEqual((await call("GET", "/v1/homes", { cookie: again })).json.items, []);
});

test("an invitation's email cannot be changed once registered, even by another member", TEST, async () => {
  const { state, dana } = await claimedHome();
  const invitationId = randomHex(4);
  const expires = new Date(Date.now() + 3600_000).toISOString();
  const first = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: invitationId, email: AVI.email, expires_at: expires } });
  assert.equal(first.status, 201);
  const again = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: invitationId, email: NOA.email, expires_at: expires } });
  assert.equal(again.status, 409);
  assert.equal(again.json.code, "INVITATION_EXISTS");
  // A controller clock a few minutes fast still gives a valid 7-day invitation.
  const fast = new Date(Date.now() + 7 * 86400_000 + 5 * 60_000).toISOString();
  assert.equal((await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: randomHex(4), email: AVI.email, expires_at: fast } })).status, 201);
});

test("the app learns whether a home is claimed, and by whom, before linking it", TEST, async () => {
  const { state, dana } = await claimedHome();
  assert.deepEqual((await call("GET", `/v1/homes/${state.home}`, { cookie: dana })).json, { home_id: state.home, claimed: true, owner: true, member: true });
  const avi = await signIn(AVI);
  assert.deepEqual((await call("GET", `/v1/homes/${state.home}`, { cookie: avi })).json, { home_id: state.home, claimed: true, owner: false, member: false });
  const other = randomHex(16);
  assert.deepEqual((await call("GET", `/v1/homes/${other}`, { cookie: avi })).json, { home_id: other, claimed: false, owner: false, member: false });
});

test("only the envelope's own fields reach the home, and oversized requests are refused", TEST, async () => {
  const { state, dana, keyId, apiKey } = await claimedHome();
  const { envelope } = sealedRequest(state, apiKey, keyId, { method: "GET", path: "/v1/system" });
  const answered = await call("POST", `/v1/homes/${state.home}/e2e`, { cookie: dana, body: { envelope: { ...envelope, note: "extra" }, other: 1 } });
  assert.equal(answered.status, 200, answered.text);
  assert.deepEqual(Object.keys(state.seen.at(-1).envelope).sort(), ["ct", "home", "iv", "key", "mac", "v"]);
  const huge = await call("POST", `/v1/homes/${state.home}/e2e`, { cookie: dana, body: { envelope: { ...envelope, ct: "A".repeat(200 * 1024) } } });
  assert.equal(huge.status, 400);
});

test("an invitation stays bound when its email's account, its creator or its home's owner goes", TEST, async () => {
  const { state, dana } = await claimedHome();
  const expires = new Date(Date.now() + 3600_000).toISOString();
  const register = (cookie, invitationId, email) => call("POST", `/v1/homes/${state.home}/invitations`, { cookie, body: { invitation_id: invitationId, email, expires_at: expires } });
  const joinAs = (cookie, invitationId, secret) => {
    const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
    return call("POST", "/v1/join", { cookie, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) } });
  };

  // The invited person deletes their account: the invitation's id stays taken.
  const ori = { sub: "google-ori", email: "ori@example.com", name: "Ori" };
  const forOri = randomHex(4);
  const secret = randomBytes(32).toString("hex");
  state.invitations.set(forOri, secret);
  assert.equal((await register(dana, forOri, ori.email)).status, 201);
  assert.equal((await call("DELETE", "/v1/me", { cookie: await signIn(ori) })).status, 204);
  const moved = await register(dana, forOri, NOA.email);
  assert.equal(moved.status, 409, "nobody can bind it to another email afterwards");
  assert.equal(moved.json.code, "INVITATION_EXISTS");
  assert.equal((await joinAs(await signIn(NOA), forOri, secret)).json.code, "INVITATION_NOT_FOUND");
  assert.equal((await joinAs(await signIn(ori), forOri, secret)).json.code, "INVITATION_NOT_FOUND", "not even for the email it was for");
  assert.ok(state.invitations.has(forOri), "the home never saw a join");

  // A new owner: the old invitations cannot be registered again either.
  const old = randomHex(4);
  assert.equal((await register(dana, old, AVI.email)).status, 201);
  const noa = await signIn(NOA);
  state.claimToken = randomHex(24);
  assert.equal((await call("POST", "/v1/homes/claim", { cookie: noa, body: { home_id: state.home, claim_token: state.claimToken } })).json.transferred, true);
  assert.equal((await register(noa, old, NOA.email)).status, 409);
});

test("a member may have 20 invitations waiting for a home", TEST, async () => {
  const { state, dana } = await claimedHome();
  const expires = new Date(Date.now() + 3600_000).toISOString();
  for (let index = 0; index < 20; index += 1) {
    const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: randomHex(4), email: `guest${index}@example.com`, expires_at: expires } });
    assert.equal(registered.status, 201, registered.text);
  }
  const more = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: randomHex(4), email: "one-more@example.com", expires_at: expires } });
  assert.equal(more.status, 429);
  assert.equal(more.json.code, "INVITATION_LIMIT_REACHED");
});

// Accepting an invitation for the home of `state` as the account of `cookie`.
function joinWith(state, cookie, invitationId, secret) {
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
  return call("POST", "/v1/join", { cookie, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) } });
}

async function invite(state, dana, email) {
  const invitationId = randomHex(4);
  const secret = randomBytes(32).toString("hex");
  state.invitations.set(invitationId, secret);
  const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: invitationId, email, expires_at: new Date(Date.now() + 3600_000).toISOString() } });
  assert.equal(registered.status, 201, registered.text);
  return { invitationId, secret };
}

test("an invitation is accepted with the email of any of the account's sign-ins", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, "real.address@example.com");
  // An account made with Apple's Hide My Email, which then adds Google with the real address.
  const hidden = await signInWithApple(worker.http, apple, { sub: "001.hidden.joiner", email: "q9z@privaterelay.appleid.com", private: true }, APP);
  assert.equal((await joinWith(state, hidden.cookie, invitationId, secret)).json.code, "EMAIL_MISMATCH");
  const start = await fetch(`${worker.http}/auth/google/start?link=1&return_to=${encodeURIComponent(`${APP}/#/settings`)}`, { redirect: "manual", headers: { Cookie: hidden.cookie } });
  const location = start.headers.get("location");
  const code = google.approve(location, { person: { sub: "google-real-address", email: "real.address@example.com", name: "Real" } });
  const back = await fetch(`${worker.http}/auth/google/callback?${new URLSearchParams({ code, state: new URL(location).searchParams.get("state") })}`, {
    redirect: "manual",
    headers: { Cookie: `__Host-dl_signin=${cookiesOf(start)["__Host-dl_signin"].value}` },
  });
  assert.equal(new URL(back.headers.get("location")).searchParams.get("signin"), "linked");
  const joined = await joinWith(state, hidden.cookie, invitationId, secret);
  assert.equal(joined.status, 200, joined.text);
  assert.equal(joined.json.member, true);
});

test("deleting one of two accounts with the same email keeps that email's invitations", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, "twin@example.com");
  const viaGoogle = await signInAs(worker.http, google, { sub: "google-twin", email: "twin@example.com", name: "Twin" }, APP);
  const viaApple = await signInWithApple(worker.http, apple, { sub: "001.twin", email: "twin@example.com" }, APP);
  assert.equal((await call("DELETE", "/v1/me", { cookie: viaApple.cookie })).status, 204);
  const joined = await joinWith(state, viaGoogle, invitationId, secret);
  assert.equal(joined.status, 200, "the Google account can still accept it");
});

test("changes need the app's origin, and the app gets CORS answers", TEST, async () => {
  const state = await home();
  const dana = await signIn(DANA);
  const foreign = await call("POST", "/v1/homes/claim", { cookie: dana, origin: "https://evil.example", body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(foreign.status, 403);
  assert.equal(foreign.json.code, "ORIGIN_NOT_ALLOWED");
  const preflight = await fetch(`${worker.http}/v1/homes/${state.home}/e2e`, { method: "OPTIONS", headers: { Origin: APP, "Access-Control-Request-Method": "POST" } });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get("access-control-allow-credentials"), "true");
  assert.equal((await call("GET", "/v1/homes", {})).status, 401, "not signed in");
});
