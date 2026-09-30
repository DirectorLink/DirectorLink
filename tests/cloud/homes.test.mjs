// Homes (cloud/src/homes.js) end to end: the Worker under `wrangler dev`, a fake Google, and a fake
// controller that seals and opens with the lock (lock.mjs) like the driver does.
//   node --test tests/cloud/homes.test.mjs

import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { after, afterEach, before, test } from "node:test";

import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { appleVars, postNotification, signInWithApple, startFakeApple } from "./fake-apple.mjs";
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
  // holdJoin: a function whose promise the controller waits for before it answers a join.
  const state = { home: randomHex(16), keys: new Map(), invitations: new Map(), claimToken: randomHex(24), seen: [], holdJoin: null };
  const connection = await connectDriver({ url: worker.ws, home: state.home, pingIntervalMs: 0, silenceTimeoutMs: 0 });
  drivers.push(connection);
  state.connection = connection;
  connection.on("unknown", async (text) => {
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
      state.beforeAnswer?.(request, message.envelope.key);
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
      if (state.holdJoin) await state.holdJoin();
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

// The controller's own answer to something it asked the relay (`type`, with `id`).
async function answerTo(state, type, id) {
  for (let tries = 0; tries < 100; tries += 1) {
    const found = state.seen.find((message) => message.type === type && message.id === id);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`no ${type} for ${id}`);
}

test("the controller registers its own invitations; members who are not the owner cannot", TEST, async () => {
  const { state, dana } = await claimedHome();
  const avi = await signIn(AVI);
  const aviInvitation = await invite(state, dana, AVI.email);
  assert.equal((await joinWith(state, avi, aviInvitation.invitationId, aviInvitation.secret)).status, 200, "Avi is a member");

  const expires = new Date(Date.now() + 3600_000).toISOString();
  const byMember = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: avi, body: { invitation_id: randomHex(4), email: NOA.email, expires_at: expires } });
  assert.equal(byMember.status, 403);
  assert.equal(byMember.json.code, "OWNER_ONLY", "the cloud does not know members' roles: only the home decides");

  // The controller registers an invitation an admin made.
  const invitationId = randomHex(4);
  const secret = randomBytes(32).toString("hex");
  state.invitations.set(invitationId, secret);
  state.connection.sendJson({ type: "invitation", id: "d1", invitation_id: invitationId, email: " Noa@Example.com ", expires_at: expires });
  const registered = await answerTo(state, "invitation_result", "d1");
  assert.equal(registered.ok, true, JSON.stringify(registered));
  state.connection.sendJson({ type: "invitation", id: "d2", invitation_id: invitationId, email: "other@example.com", expires_at: expires });
  assert.equal((await answerTo(state, "invitation_result", "d2")).code, "INVITATION_EXISTS", "an id is bound to its email once");
  state.connection.sendJson({ type: "invitation", id: "d3", invitation_id: "nothex", email: "x@example.com", expires_at: expires });
  assert.equal((await answerTo(state, "invitation_result", "d3")).code, "INVALID_REQUEST");

  const noa = await signIn(NOA);
  assert.equal((await joinWith(state, noa, invitationId, secret)).status, 200, "Noa joins with it");

  // One the controller gave up on (no answer in time) is forgotten when it says so.
  const dropped = randomHex(4);
  state.invitations.set(dropped, randomBytes(32).toString("hex"));
  state.connection.sendJson({ type: "invitation", id: "d4", invitation_id: dropped, email: "late@example.com", expires_at: expires });
  assert.equal((await answerTo(state, "invitation_result", "d4")).ok, true);
  state.connection.sendJson({ type: "invitation_cancel", invitation_id: dropped });
  await new Promise((resolve) => setTimeout(resolve, 300));
  const late = await signIn({ sub: "google-late", email: "late@example.com", name: "Late" });
  assert.equal((await joinWith(state, late, dropped, state.invitations.get(dropped))).status, 404, "the cancelled invitation is gone");

  // At most 20 waiting from the controller.
  let limited = null;
  for (let index = 0; index < 21 && !limited; index += 1) {
    const id = `m${index}`;
    state.connection.sendJson({ type: "invitation", id, invitation_id: randomHex(4), email: `guest${index}@example.com`, expires_at: expires });
    const answer = await answerTo(state, "invitation_result", id);
    if (!answer.ok) limited = answer.code;
  }
  assert.equal(limited, "INVITATION_LIMIT_REACHED");
  // The controller says which are still waiting there: the others (revoked there) are forgotten.
  const fresh = randomHex(4);
  state.connection.sendJson({ type: "invitation", id: "p1", invitation_id: fresh, email: "fresh@example.com", expires_at: expires, pending: [fresh] });
  assert.equal((await answerTo(state, "invitation_result", "p1")).ok, true, "room again once the revoked ones are forgotten");

  // A home nobody claimed cannot register any.
  const lone = await home();
  lone.connection.sendJson({ type: "invitation", id: "u1", invitation_id: randomHex(4), email: "x@example.com", expires_at: expires });
  assert.equal((await answerTo(lone, "invitation_result", "u1")).code, "NOT_CLAIMED");
});

test("only the home's owner replaces its secret; the controller cannot over its connection", TEST, async () => {
  const { state, dana } = await claimedHome();
  const avi = await signIn(AVI);
  const aviInvitation = await invite(state, dana, AVI.email);
  assert.equal((await joinWith(state, avi, aviInvitation.invitationId, aviInvitation.secret)).status, 200);
  const oldSecret = state.connection.secret;
  const newSecret = randomHex(32);
  const hash = createHash("sha256").update(newSecret).digest("hex");

  // Whoever holds the current secret (a copy of the controller's data) cannot replace it.
  state.connection.sendJson({ type: "rotate_secret", id: "r1", secret_sha256: createHash("sha256").update(randomHex(32)).digest("hex") });
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal(state.seen.some((message) => message.type === "rotate_result"), false, "not answered: the relay does not do that any more");
  const stillOld = await connectDriver({ url: worker.ws, home: state.home, secret: oldSecret, pingIntervalMs: 0, silenceTimeoutMs: 0 });
  drivers.push(stillOld);

  const byMember = await call("POST", `/v1/homes/${state.home}/secret`, { cookie: avi, body: { secret_sha256: hash } });
  assert.equal(byMember.status, 403);
  assert.equal(byMember.json.code, "OWNER_ONLY");
  assert.equal((await call("POST", `/v1/homes/${state.home}/secret`, { cookie: dana, body: { secret_sha256: hash }, origin: null })).status, 403, "only from the app's own origins");
  assert.equal((await call("POST", `/v1/homes/${state.home}/secret`, { cookie: dana, body: { secret_sha256: "short" } })).status, 400);

  const approved = await call("POST", `/v1/homes/${state.home}/secret`, { cookie: dana, body: { secret_sha256: hash } });
  assert.equal(approved.status, 204, approved.text);
  await assert.rejects(connectDriver({ url: worker.ws, home: state.home, secret: oldSecret, pingIntervalMs: 0, silenceTimeoutMs: 0 }), "the old secret is refused");
  const again = await connectDriver({ url: worker.ws, home: state.home, secret: newSecret, pingIntervalMs: 0, silenceTimeoutMs: 0 });
  drivers.push(again);
});

test("signing out everywhere ends every session of the account", TEST, async () => {
  const phone = await signIn(DANA);
  const computer = await signIn(DANA);
  assert.equal((await call("GET", "/v1/me", { cookie: phone })).status, 200);
  assert.equal((await call("POST", "/auth/logout?everywhere=1", { cookie: computer })).status, 204);
  assert.equal((await call("GET", "/v1/me", { cookie: phone })).status, 401, "the other device is signed out too");
  assert.equal((await call("GET", "/v1/me", { cookie: computer })).status, 401);
  const again = await call("POST", "/auth/logout?everywhere=1", { cookie: computer });
  assert.equal(again.status, 401, "with no live session nothing was ended, and it says so");
  assert.equal(again.json.code, "NOT_SIGNED_IN");
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

// Accepting an invitation for the home of `state` as the account of `cookie`. `extra`: more fields
// (ask_owner).
function joinWith(state, cookie, invitationId, secret, extra = {}) {
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
  return call("POST", "/v1/join", { cookie, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)), ...extra } });
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

// Waits until `check()` is true (the relay handles the driver's messages on its own time).
async function eventually(check, what) {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.fail(`timed out waiting for ${what}`);
}

const membersOf = async (state, cookie) => (await call("GET", `/v1/homes/${state.home}/members`, { cookie })).json.items;

test("the cloud learns each member's keys; a member whose keys are all revoked at home leaves", TEST, async () => {
  const { state, dana, keyId, apiKey } = await claimedHome();
  assert.equal((await e2e(dana, state, apiKey, keyId)).status, 200);
  await eventually(async () => (await membersOf(state, dana))[0]?.key_ids.includes(keyId), "the owner's key from a sealed request");

  const { invitationId, secret } = await invite(state, dana, AVI.email);
  const avi = await signIn(AVI);
  const joined = await joinWith(state, avi, invitationId, secret);
  assert.equal(joined.status, 200, joined.text);
  const aviKey = JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body);
  const aviMember = (await membersOf(state, dana)).find((m) => m.email === AVI.email);
  assert.deepEqual(aviMember.key_ids, [aviKey.id], "the key the invitation made");

  // A refused request records nothing: only the key's holder can seal one the home accepts.
  const unknown = await e2e(avi, state, `ak_${randomHex(24)}`, randomHex(4));
  assert.equal(unknown.json.code, "UNKNOWN_KEY");
  assert.deepEqual((await membersOf(state, dana)).find((m) => m.email === AVI.email).key_ids, [aviKey.id]);

  // Nonsense from the controller changes nothing.
  state.connection.sendJson({ type: "keys", ids: "all" });
  state.connection.sendJson({ type: "keys", ids: ["not-a-key"] });
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal((await membersOf(state, dana)).length, 2);

  // The admin revokes Avi's key at home: the controller's next list lacks it.
  state.keys.delete(aviKey.id);
  state.connection.sendJson({ type: "keys", ids: [...state.keys.keys()] });
  await eventually(async () => (await membersOf(state, dana)).length === 1, "Avi leaving");
  assert.equal((await e2e(avi, state, aviKey.key, aviKey.id)).json.code, "NOT_A_MEMBER");

  // The owner stays the owner, even with no keys left.
  state.connection.sendJson({ type: "keys", ids: [] });
  await eventually(async () => (await membersOf(state, dana))[0]?.key_ids.length === 0, "the owner's key going");
  assert.deepEqual((await membersOf(state, dana)).map((m) => [m.email, m.owner]), [[DANA.email, true]]);
});

test("a key revoked by the request that used it is not recorded again", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, AVI.email);
  const avi = await signIn(AVI);
  const joined = await joinWith(state, avi, invitationId, secret);
  const aviKey = JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body);
  // Avi forgets his key through the account: the driver revokes it, announces the keys without
  // it, and only then sends the sealed answer.
  state.beforeAnswer = (request, keyId) => {
    if (request.method === "DELETE") {
      state.keys.delete(keyId);
      state.connection.sendJson({ type: "keys", ids: [...state.keys.keys()] });
    }
  };
  const forgot = await e2e(avi, state, aviKey.key, aviKey.id, { method: "DELETE", path: "/v1/api-keys/current" });
  assert.equal(forgot.status, 200);
  state.beforeAnswer = null;
  await eventually(async () => (await membersOf(state, dana)).length === 1, "Avi leaving with his last key");
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.deepEqual((await membersOf(state, dana)).map((m) => m.email), [DANA.email], "and not coming back by the answer");
});

test("a shared device's key belongs to each account that used it", TEST, async () => {
  const { state, dana } = await claimedHome();
  const first = await invite(state, dana, AVI.email);
  const avi = await signIn(AVI);
  const aviKey = JSON.parse(JSON.parse(open(invitationKey(first.secret), (await joinWith(state, avi, first.invitationId, first.secret)).json.envelope, "res")).body);
  const second = await invite(state, dana, NOA.email);
  const noa = await signIn(NOA);
  const noaKey = JSON.parse(JSON.parse(open(invitationKey(second.secret), (await joinWith(state, noa, second.invitationId, second.secret)).json.envelope, "res")).body);
  // Noa signs in on Avi's tablet and uses its key.
  assert.equal((await e2e(noa, state, aviKey.key, aviKey.id)).status, 200);
  await eventually(async () => (await membersOf(state, dana)).find((m) => m.email === NOA.email)?.key_ids.length === 2, "the tablet's key for Noa too");
  assert.deepEqual((await membersOf(state, dana)).find((m) => m.email === AVI.email).key_ids, [aviKey.id], "and still for Avi");
  // The tablet is lost: its key is revoked. Avi has no other key and leaves; Noa keeps hers.
  state.keys.delete(aviKey.id);
  state.connection.sendJson({ type: "keys", ids: [...state.keys.keys()] });
  await eventually(async () => !(await membersOf(state, dana)).some((m) => m.email === AVI.email), "Avi leaving");
  assert.deepEqual((await membersOf(state, dana)).find((m) => m.email === NOA.email).key_ids, [noaKey.id]);
});

test("removing a member forgets their keys too", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, NOA.email);
  const noa = await signIn(NOA);
  assert.equal((await joinWith(state, noa, invitationId, secret)).status, 200);
  const noaMember = (await membersOf(state, dana)).find((m) => m.email === NOA.email);
  assert.equal(noaMember.key_ids.length, 1);
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${noaMember.user_id}`, { cookie: dana })).status, 204);
  // Invited again later, Noa starts with only the new key.
  const again = await invite(state, dana, NOA.email);
  assert.equal((await joinWith(state, noa, again.invitationId, again.secret)).status, 200);
  assert.equal((await membersOf(state, dana)).find((m) => m.email === NOA.email).key_ids.length, 1);
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

// --- Another email, approved by the home's owner (ADR-041) ------------------------------------------

const requestsOf = async (state, cookie) => (await call("GET", `/v1/homes/${state.home}/join-requests`, { cookie })).json.items;
const decide = (state, cookie, id, decision) => call("POST", `/v1/homes/${state.home}/join-requests/${id}`, { cookie, body: { decision } });
const myRequest = (state, cookie, invitationId) => call("GET", `/v1/join/${state.home}/${invitationId}`, { cookie });

test("an invitation accepted with another email waits for the owner's approval, then works once", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, AVI.email);
  // Avi signs in with Apple and hides his email.
  const hidden = (await signInWithApple(worker.http, apple, { sub: `001.hidden.${randomHex(4)}`, email: `${randomHex(4)}@privaterelay.appleid.com`, private: true, firstName: "Avi", lastName: "Cohen" }, APP)).cookie;
  const joins = () => state.seen.filter((message) => message.type === "join").length;
  const before = joins();

  const asked = await joinWith(state, hidden, invitationId, secret, { ask_owner: true });
  assert.equal(asked.status, 202, asked.text);
  assert.equal(asked.json.status, "pending");
  assert.match(asked.json.code, /^\d{6}$/, "a code to read out to the owner");
  const waiting = await myRequest(state, hidden, invitationId);
  assert.deepEqual([waiting.status, waiting.json.status, waiting.json.code], [200, "pending", asked.json.code]);
  const again = await joinWith(state, hidden, invitationId, secret, { ask_owner: true });
  assert.deepEqual([again.status, again.json.code], [202, asked.json.code], "one request per account, still waiting");
  assert.equal(joins(), before, "the home is not asked before the owner approves");

  // What the owner sees, and nobody else.
  const [request, ...more] = await requestsOf(state, dana);
  assert.deepEqual(more, []);
  assert.equal(request.name, "Avi Cohen");
  assert.equal(request.email, null);
  assert.equal(request.email_hidden, true);
  assert.deepEqual(request.providers, ["apple"]);
  assert.equal(request.code, asked.json.code);
  assert.equal(request.status, "pending");
  assert.deepEqual([request.invitation.id, request.invitation.email], [invitationId, AVI.email]);
  assert.ok(Date.parse(request.requested_at) && Date.parse(request.account_created_at));
  const noa = await signIn(NOA);
  for (const cookie of [noa, hidden]) {
    assert.equal((await call("GET", `/v1/homes/${state.home}/join-requests`, { cookie })).json.code, "OWNER_ONLY");
    assert.equal((await decide(state, cookie, request.id, "approve")).json.code, "OWNER_ONLY");
  }
  assert.equal((await decide(state, dana, request.id, "maybe")).status, 400);
  assert.equal((await call("POST", `/v1/homes/${state.home}/join-requests/${request.id}`, { cookie: dana, origin: "https://evil.example", body: { decision: "approve" } })).json.code, "ORIGIN_NOT_ALLOWED");

  const approved = await decide(state, dana, request.id, "approve");
  assert.equal(approved.status, 200, approved.text);
  assert.equal(approved.json.status, "approved");
  assert.equal((await myRequest(state, hidden, invitationId)).json.status, "approved");
  // The app seals a new request with the invitation's secret, which the home checks as always.
  const joined = await joinWith(state, hidden, invitationId, secret);
  assert.equal(joined.status, 200, joined.text);
  assert.equal(joined.json.member, true);
  assert.equal(joins(), before + 1);
  assert.doesNotMatch(joined.text, /ak_/, "the new key travels sealed");
  const newKey = JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body);
  assert.equal((await e2e(hidden, state, newKey.key, newKey.id)).status, 200, "a member, with its own key");
  const members = await membersOf(state, dana);
  assert.ok(members.some((m) => m.name === "Avi Cohen" && m.key_ids.includes(newKey.id)), "its key is recorded for it");

  // Used once: gone for everyone, its request too.
  assert.equal((await myRequest(state, hidden, invitationId)).json.code, "INVITATION_NOT_FOUND");
  assert.deepEqual(await requestsOf(state, dana), []);
  assert.equal((await joinWith(state, await signIn(AVI), invitationId, secret)).json.code, "INVITATION_NOT_FOUND");
});

test("a refusal stays; a request can be withdrawn; an app that does not ask gets EMAIL_MISMATCH", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, AVI.email);
  const noa = await signIn(NOA);
  assert.equal((await joinWith(state, noa, invitationId, secret)).json.code, "EMAIL_MISMATCH", "apps before 1.3.0 do not ask");
  assert.equal((await myRequest(state, noa, invitationId)).json.code, "NOT_FOUND");

  assert.equal((await joinWith(state, noa, invitationId, secret, { ask_owner: true })).status, 202);
  assert.equal((await call("DELETE", `/v1/join/${state.home}/${invitationId}`, { cookie: noa, origin: "https://evil.example" })).json.code, "ORIGIN_NOT_ALLOWED");
  assert.equal((await call("DELETE", `/v1/join/${state.home}/${invitationId}`, { cookie: noa })).status, 204, "withdrawn");
  assert.equal((await myRequest(state, noa, invitationId)).json.code, "NOT_FOUND");
  assert.deepEqual(await requestsOf(state, dana), []);

  assert.equal((await joinWith(state, noa, invitationId, secret, { ask_owner: true })).status, 202, "asked again");
  const [request] = await requestsOf(state, dana);
  assert.equal((await decide(state, dana, request.id, "refuse")).json.status, "refused");
  const refused = await joinWith(state, noa, invitationId, secret, { ask_owner: true });
  assert.deepEqual([refused.status, refused.json.code], [403, "REFUSED_BY_OWNER"]);
  assert.equal((await myRequest(state, noa, invitationId)).json.status, "refused");
  assert.equal((await call("DELETE", `/v1/join/${state.home}/${invitationId}`, { cookie: noa })).status, 404, "a refusal cannot be withdrawn to ask again");
  assert.deepEqual(await requestsOf(state, dana), [], "the owner's list shows only open requests");
  assert.equal((await joinWith(state, await signIn(AVI), invitationId, secret)).status, 200, "the invited person is not affected");
});

test("an approval lets the account try the invitation; the home still checks its secret", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, AVI.email);
  const noa = await signIn(NOA);
  const guessed = randomBytes(32).toString("hex");
  assert.equal((await joinWith(state, noa, invitationId, guessed, { ask_owner: true })).status, 202);
  const [request] = await requestsOf(state, dana);
  assert.equal((await decide(state, dana, request.id, "approve")).status, 200);
  const wrong = await joinWith(state, noa, invitationId, guessed);
  assert.deepEqual([wrong.status, wrong.json.code], [400, "BAD_MAC"]);
  assert.equal((await call("GET", `/v1/homes/${state.home}`, { cookie: noa })).json.member, false);
  assert.equal((await joinWith(state, await signIn(AVI), invitationId, secret)).status, 200, "the invitation still works for the person it was for");
});

test("requests end with their invitation, and an invitation takes five", TEST, async () => {
  const { state, dana } = await claimedHome();
  const short = randomHex(4);
  const shortSecret = randomBytes(32).toString("hex");
  state.invitations.set(short, shortSecret);
  const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: short, email: AVI.email, expires_at: new Date(Date.now() + 2500).toISOString() } });
  assert.equal(registered.status, 201, registered.text);
  const noa = await signIn(NOA);
  assert.equal((await joinWith(state, noa, short, shortSecret, { ask_owner: true })).status, 202);
  const [request] = await requestsOf(state, dana);
  await new Promise((resolve) => setTimeout(resolve, 3000));
  assert.equal((await myRequest(state, noa, short)).json.status, "expired", "the app can say the invitation ran out");
  assert.equal((await decide(state, dana, request.id, "approve")).status, 404, "too late to approve");
  assert.deepEqual(await requestsOf(state, dana), []);
  assert.equal((await joinWith(state, noa, short, shortSecret)).json.code, "INVITATION_NOT_FOUND");

  const { invitationId, secret } = await invite(state, dana, AVI.email);
  const asker = (index) => signIn({ sub: `google-asker-${randomHex(4)}`, email: `asker${index}@example.com`, name: `Asker ${index}` });
  for (let index = 0; index < 5; index += 1) {
    assert.equal((await joinWith(state, await asker(index), invitationId, secret, { ask_owner: true })).status, 202);
  }
  const sixth = await joinWith(state, await asker(5), invitationId, secret, { ask_owner: true });
  assert.deepEqual([sixth.status, sixth.json.code], [429, "JOIN_REQUEST_LIMIT_REACHED"]);
});

const asker = (label) => signIn({ sub: `google-${label}-${randomHex(4)}`, email: `${label}.${randomHex(3)}@example.com`, name: label });

test("refused requests do not fill an invitation's five", TEST, async () => {
  const { state, dana } = await claimedHome();

  // Five strangers with the link, all refused: the invited person can still ask.
  const { invitationId, secret } = await invite(state, dana, AVI.email);
  for (let index = 0; index < 5; index += 1) {
    assert.equal((await joinWith(state, await asker(`stranger${index}`), invitationId, secret, { ask_owner: true })).status, 202);
  }
  for (const request of await requestsOf(state, dana)) assert.equal((await decide(state, dana, request.id, "refuse")).status, 200);
  const hidden = (await signInWithApple(worker.http, apple, { sub: `001.limit.${randomHex(4)}`, email: `${randomHex(4)}@privaterelay.appleid.com`, private: true }, APP)).cookie;
  const asked = await joinWith(state, hidden, invitationId, secret, { ask_owner: true });
  assert.equal(asked.status, 202, asked.text);
});

test("requests waiting on invitations that expired do not fill the home's twenty", { timeout: 60_000 }, async () => {
  const other = await claimedHome();
  const askers = [];
  for (let index = 0; index < 22; index += 1) askers.push(await asker(`waiting${index}`));
  const fresh = await invite(other.state, other.dana, "fresh@example.com");
  const started = Date.now();
  const short = [];
  for (let index = 0; index < 4; index += 1) {
    const id = randomHex(4);
    const shortSecret = randomBytes(32).toString("hex");
    other.state.invitations.set(id, shortSecret);
    const registered = await call("POST", `/v1/homes/${other.state.home}/invitations`, {
      cookie: other.dana,
      body: { invitation_id: id, email: `short${index}@example.com`, expires_at: new Date(started + 8000).toISOString() },
    });
    assert.equal(registered.status, 201, registered.text);
    short.push({ id, shortSecret });
  }
  for (const [number, { id, shortSecret }] of short.entries()) {
    for (let index = 0; index < 5; index += 1) {
      assert.equal((await joinWith(other.state, askers[number * 5 + index], id, shortSecret, { ask_owner: true })).status, 202);
    }
  }
  assert.equal((await joinWith(other.state, askers[20], fresh.invitationId, fresh.secret, { ask_owner: true })).json.code, "JOIN_REQUEST_LIMIT_REACHED", "twenty waiting");
  assert.ok(Date.now() - started < 8000, "all of them asked before the invitations ran out");
  await new Promise((resolve) => setTimeout(resolve, Math.max(0, started + 8500 - Date.now())));
  assert.deepEqual(await requestsOf(other.state, other.dana), []);
  assert.equal((await joinWith(other.state, askers[21], fresh.invitationId, fresh.secret, { ask_owner: true })).status, 202, "none of them waits any more");
});

test("an account the owner refuses while the home makes its key never gets the key", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, AVI.email);
  const noa = await signIn(NOA);
  assert.equal((await joinWith(state, noa, invitationId, secret, { ask_owner: true })).status, 202);
  const [request] = await requestsOf(state, dana);
  assert.equal((await decide(state, dana, request.id, "approve")).status, 200);
  let release;
  state.holdJoin = () => new Promise((resolve) => (release = resolve));
  const joining = joinWith(state, noa, invitationId, secret);
  while (!release) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal((await decide(state, dana, request.id, "refuse")).json.status, "refused");
  state.holdJoin = null;
  release();
  const joined = await joining;
  assert.deepEqual([joined.status, joined.json.code], [403, "REFUSED_BY_OWNER"]);
  assert.equal(joined.json.envelope, undefined, "the key made at home is not handed out");
  assert.doesNotMatch(joined.text, /"envelope"/);
  assert.equal((await call("GET", `/v1/homes/${state.home}`, { cookie: noa })).json.member, false);
});

test("a request goes when the account asking goes, and a new owner starts without any", TEST, async () => {
  const { state, dana } = await claimedHome();
  const { invitationId, secret } = await invite(state, dana, AVI.email);
  const ori = await signIn({ sub: `google-ori-${randomHex(4)}`, email: "ori.asks@example.com", name: "Ori" });
  assert.equal((await joinWith(state, ori, invitationId, secret, { ask_owner: true })).status, 202);
  assert.equal((await requestsOf(state, dana)).length, 1);
  assert.equal((await call("DELETE", "/v1/me", { cookie: ori })).status, 204);
  assert.deepEqual(await requestsOf(state, dana), []);

  const noa = await signIn(NOA);
  assert.equal((await joinWith(state, noa, invitationId, secret, { ask_owner: true })).status, 202);
  const newOwner = await signIn({ sub: `google-new-owner-${randomHex(4)}`, email: "new.owner@example.com", name: "New owner" });
  state.claimToken = randomHex(24);
  assert.equal((await call("POST", "/v1/homes/claim", { cookie: newOwner, body: { home_id: state.home, claim_token: state.claimToken } })).json.transferred, true);
  assert.deepEqual(await requestsOf(state, newOwner), []);
  assert.equal((await myRequest(state, noa, invitationId)).json.code, "INVITATION_NOT_FOUND");
});

test("Apple's notices never take a home or a membership", TEST, async () => {
  const state = await home();
  const person = { sub: `001.owner.${randomHex(4)}`, email: "apple.owner@example.com", firstName: "Apple", lastName: "Owner" };
  const owner = (await signInWithApple(worker.http, apple, person, APP)).cookie;
  assert.equal((await call("POST", "/v1/homes/claim", { cookie: owner, body: { home_id: state.home, claim_token: state.claimToken } })).status, 200);
  const { invitationId, secret } = await invite(state, owner, AVI.email);
  const avi = await signIn(AVI);
  const joined = await joinWith(state, avi, invitationId, secret);
  assert.equal(joined.status, 200, joined.text);
  const aviKey = JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body);

  // The owner, who signs in only with Apple, stops using it for DirectorLink.
  assert.equal((await postNotification(worker.http, apple.notification({ type: "consent-revoked", sub: person.sub }))).status, 200);
  assert.equal((await call("GET", "/v1/homes", { cookie: owner })).status, 401, "signed out everywhere");
  assert.equal((await e2e(avi, state, aviKey.key, aviKey.id)).status, 200, "the family keeps its access");
  // The same Apple ID signs in again: the same account, still the owner.
  const back = (await signInWithApple(worker.http, apple, person, APP, { withUser: false })).cookie;
  assert.deepEqual((await call("GET", "/v1/homes", { cookie: back })).json.items.map((item) => [item.home_id, item.owner]), [[state.home, true]]);
  assert.deepEqual((await membersOf(state, back)).map((m) => m.email).sort(), ["apple.owner@example.com", AVI.email]);

  // Deleting the Apple Account: nobody can sign in to it any more, the home and its members stay.
  assert.equal((await postNotification(worker.http, apple.notification({ type: "account-delete", sub: person.sub }))).status, 200);
  assert.equal((await call("GET", "/v1/homes", { cookie: back })).status, 401);
  assert.equal((await e2e(avi, state, aviKey.key, aviKey.id)).status, 200);
  assert.ok((await call("GET", "/v1/homes", { cookie: avi })).json.items.some((item) => item.home_id === state.home && !item.owner));
});

test("after Apple's account-deleted an owner's account stays for its home, without the person", TEST, async () => {
  const state = await home();
  const person = { sub: `001.gone.${randomHex(4)}`, email: "gone.owner@example.com", firstName: "Gone", lastName: "Owner" };
  const owner = (await signInWithApple(worker.http, apple, person, APP)).cookie;
  assert.equal((await call("POST", "/v1/homes/claim", { cookie: owner, body: { home_id: state.home, claim_token: state.claimToken } })).status, 200);
  const { invitationId, secret } = await invite(state, owner, AVI.email);
  const avi = await signIn(AVI);
  const aviKey = JSON.parse(JSON.parse(open(invitationKey(secret), (await joinWith(state, avi, invitationId, secret)).json.envelope, "res")).body);
  // The same person is also a member of Dana's home.
  const { state: danas, dana } = await claimedHome();
  const invited = await invite(danas, dana, person.email);
  assert.equal((await joinWith(danas, owner, invited.invitationId, invited.secret)).status, 200);
  assert.ok((await membersOf(danas, dana)).some((m) => m.email === person.email));

  assert.equal((await postNotification(worker.http, apple.notification({ type: "account-deleted", sub: person.sub }))).status, 200);
  assert.equal((await e2e(avi, state, aviKey.key, aviKey.id)).status, 200, "the family keeps its access");
  const others = await membersOf(danas, dana);
  assert.ok(!others.some((m) => m.email === person.email || m.name === "Gone Owner"), "not in other homes any more");
  // (Were the same Apple ID ever to sign in again, it would find the account: nameless, only its home.)
  const back = (await signInWithApple(worker.http, apple, person, APP, { withUser: false })).cookie;
  assert.equal((await call("GET", "/v1/me", { cookie: back })).json.name, null, "the name is gone");
  assert.deepEqual((await call("GET", "/v1/homes", { cookie: back })).json.items.map((item) => [item.home_id, item.owner]), [[state.home, true]]);
});
