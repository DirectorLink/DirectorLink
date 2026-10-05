// Handing the home to another admin (1.9.0, ADR-064) in the account service, end to end: the Worker
// under `wrangler dev`, a fake Google and a fake controller (the relay protocol). The home's owner
// account moves only when the controller says so, over its own connection (`owner`, naming the new
// owner's account by its tag), to an account that belongs to the home and uses one of its admin
// keys; no session can move it. Then claims, the requests to join with another email, the list of
// accounts, leaving, the secret's replacement and deleting the account follow the new owner, and
// nobody leaves the home.
//   node --test tests/cloud/owner.test.mjs

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { after, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { invitationKey, lockKey, open, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TEST = { timeout: 60_000 };

let worker;
let google;
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  worker = await startWorker({ migrate: true, devVars: { ...googleVars(google, APP, "https://api.directorlink.test"), REQUEST_TIMEOUT_MS: 3000 } });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
  await worker?.stop();
  await google?.close();
});

const nowSeconds = () => Math.floor(Date.now() / 1000);

function person(name) {
  const tag = randomHex(4);
  return { sub: `google-${name}-${tag}`, email: `${name}-${tag}@example.com`, name };
}

// A controller at a new home (DirectorLink 1.9.0), answering claims, sealed requests and joins.
async function home() {
  const state = { home: randomHex(16), keys: new Map(), admins: new Set(), invitations: new Map(), claimToken: randomHex(24) };
  const connection = await connectDriver({ url: worker.ws, home: state.home, pingIntervalMs: 0, silenceTimeoutMs: 0, hello: false });
  drivers.push(connection);
  state.connection = connection;
  connection.sendJson({ type: "hello", home: state.home, version: "1.9.0", ping_s: 10, features: ["scene_links", "alerts_gone", "users"] });
  connection.on("unknown", (text) => answer(state, connection, JSON.parse(text)));
  state.announce = () => connection.sendJson({ type: "keys", ids: [...state.keys.keys()], admins: [...state.admins] });
  return state;
}

function answer(state, connection, message) {
  const reply = (fields) => connection.sendJson({ id: message.id, ...fields });
  if (message.type === "claim") {
    return reply({ type: "claim_result", ok: message.token === state.claimToken });
  }
  if (message.type === "e2e") {
    const apiKey = state.keys.get(message.envelope.key);
    const plaintext = apiKey && open(lockKey(apiKey), message.envelope, "req");
    if (!plaintext) return reply({ type: "e2e", code: "UNKNOWN_KEY" });
    const request = JSON.parse(plaintext);
    const response = { id: request.id, ts: nowSeconds(), status: 200, content_type: "application/json", body: "{}" };
    return reply({ type: "e2e", envelope: seal(lockKey(apiKey), { home: state.home, key: message.envelope.key }, "res", JSON.stringify(response)) });
  }
  if (message.type === "join") {
    const secret = state.invitations.get(message.invitation);
    const plaintext = secret && open(invitationKey(secret), message.envelope, "req");
    if (!plaintext) return reply({ type: "join_result", ok: false, code: "INVITATION_NOT_FOUND" });
    state.invitations.delete(message.invitation);
    const request = JSON.parse(plaintext);
    const id = randomHex(4);
    const key = `ak_${randomHex(24)}`;
    state.keys.set(id, key);
    state.announce();
    const response = { id: request.id, ts: nowSeconds(), status: 201, content_type: "application/json", body: JSON.stringify({ key, id, role: "member" }) };
    return reply({ type: "join_result", ok: true, key_id: id, envelope: seal(invitationKey(secret), { home: state.home, key: message.invitation }, "res", JSON.stringify(response)) });
  }
  return undefined;
}

// The controller tells the account service who owns the home now; its answer, or null when none
// came (a Worker before 1.9.0 ignores the message).
async function tellOwner(state, account) {
  const id = randomHex(8);
  const answered = new Promise((resolve) => {
    const listener = (text) => {
      const message = JSON.parse(text);
      if (message.type === "owner_result" && message.id === id) {
        state.connection.off("unknown", listener);
        resolve(message);
      }
    };
    state.connection.on("unknown", listener);
  });
  state.connection.sendJson({ type: "owner", id, account });
  return Promise.race([answered, sleep(5000).then(() => null)]);
}

async function call(method, apiPath, { cookie, body, origin = APP } = {}) {
  const headers = {};
  if (cookie) headers.Cookie = cookie;
  if (origin) headers.Origin = origin;
  if (body !== undefined) headers["content-type"] = "application/json";
  const response = await fetch(`${worker.http}${apiPath}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // Not JSON.
  }
  return { status: response.status, json, text };
}

const signIn = (who) => signInAs(worker.http, google, who, APP);
const tagOf = (homeId, userId) => createHash("sha256").update(`DirectorLink account v1|${homeId}|${userId}`).digest("hex").slice(0, 16);
const accountId = async (cookie) => (await call("GET", "/v1/me", { cookie })).json.id;

async function e2e(cookie, state, keyId) {
  const request = { id: randomHex(8), ts: nowSeconds(), method: "GET", path: "/v1/system", body: null };
  const envelope = seal(lockKey(state.keys.get(keyId)), { home: state.home, key: keyId }, "req", JSON.stringify(request));
  return call("POST", `/v1/homes/${state.home}/e2e`, { cookie, body: { envelope } });
}

// The owner pairs at home (an admin key), claims the home and uses it once through the account.
async function claimedHome() {
  const state = await home();
  const keyId = randomHex(4);
  state.keys.set(keyId, `ak_${randomHex(24)}`);
  state.admins.add(keyId);
  state.announce();
  const owner = person("dana");
  const cookie = await signIn(owner);
  const claimed = await call("POST", "/v1/homes/claim", { cookie, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  assert.equal((await e2e(cookie, state, keyId)).status, 200);
  return { state, owner, cookie, keyId };
}

// Someone joins with an invitation; `admin`: the controller then lists their key as an admin's.
async function joins(state, ownerCookie, who, { admin = false } = {}) {
  const invitationId = randomHex(4);
  const secret = randomHex(32);
  state.invitations.set(invitationId, secret);
  const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: ownerCookie, body: { invitation_id: invitationId, email: who.email, expires_at: new Date(Date.now() + 3600_000).toISOString() } });
  assert.equal(registered.status, 201, registered.text);
  const cookie = await signIn(who);
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
  const joined = await call("POST", "/v1/join", { cookie, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) } });
  assert.equal(joined.status, 200, joined.text);
  const keyId = JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body).id;
  if (admin) {
    state.admins.add(keyId);
    state.announce();
  }
  return { cookie, keyId, id: await accountId(cookie) };
}

const homeOf = async (cookie, homeId) => (await call("GET", `/v1/homes/${homeId}`, { cookie })).json;
const memberIds = async (cookie, homeId) => (await call("GET", `/v1/homes/${homeId}/members`, { cookie })).json.items.map((item) => item.user_id).sort();

test("the home's owner account moves to another admin's account only when the controller says so", TEST, async () => {
  const { state, cookie: dana } = await claimedHome();
  const danaId = await accountId(dana);
  const avi = await joins(state, dana, person("avi"), { admin: true });
  const noa = await joins(state, dana, person("noa"));
  const everyone = await memberIds(dana, state.home);
  assert.equal(everyone.length, 3);

  // No session moves it: there is no such route, for the owner or anyone else.
  for (const cookie of [dana, avi.cookie]) {
    for (const method of ["POST", "PUT", "PATCH"]) {
      assert.equal((await call(method, `/v1/homes/${state.home}/owner`, { cookie, body: { user_id: avi.id } })).status, 404);
    }
  }
  assert.equal((await homeOf(avi.cookie, state.home)).owner, false);

  // The controller's word, about an account that cannot own it: refused, and nothing moves.
  const none = await tellOwner(state, null);
  assert.ok(none, "the account service answers the controller (a Worker before 1.9.0 would not)");
  assert.equal(none.ok, false);
  assert.equal(none.code, "OWNER_NEEDS_ACCOUNT", "an owner without an account");
  assert.equal((await tellOwner(state, tagOf(state.home, randomHex(16)))).code, "OWNER_NEEDS_ACCOUNT", "an account that is not the home's");
  assert.equal((await tellOwner(state, "not a tag")).code, "INVALID_REQUEST");
  assert.equal((await tellOwner(state, tagOf(state.home, noa.id))).code, "ACCOUNT_NOT_ADMIN", "a member's account");
  assert.equal((await homeOf(dana, state.home)).owner, true);

  // To Avi's account: it moves, and says whose it was.
  const moved = await tellOwner(state, tagOf(state.home, avi.id));
  assert.equal(moved?.ok, true, JSON.stringify(moved));
  assert.equal(moved.previous, tagOf(state.home, danaId));
  assert.deepEqual(await homeOf(avi.cookie, state.home), { home_id: state.home, claimed: true, owner: true, member: true });
  assert.deepEqual(await homeOf(dana, state.home), { home_id: state.home, claimed: true, owner: false, member: true });
  const homes = (await call("GET", "/v1/homes", { cookie: dana })).json.items.find((item) => item.home_id === state.home);
  assert.equal(homes.owner, false);

  // Nobody left: every account is still a member, and each one's key still works.
  assert.deepEqual(await memberIds(avi.cookie, state.home), everyone);
  assert.equal((await e2e(avi.cookie, state, avi.keyId)).status, 200);
  assert.equal((await e2e(noa.cookie, state, noa.keyId)).status, 200);
  const listed = (await call("GET", `/v1/homes/${state.home}/members`, { cookie: avi.cookie })).json.items;
  assert.deepEqual(listed.filter((item) => item.owner).map((item) => item.user_id), [avi.id]);

  // What the owner does follows the new owner: the accounts list, requests to join, removing.
  assert.equal((await call("GET", `/v1/homes/${state.home}/members`, { cookie: dana })).json.code, "OWNER_ONLY");
  assert.equal((await call("GET", `/v1/homes/${state.home}/join-requests`, { cookie: dana })).json.code, "OWNER_ONLY");
  assert.equal((await call("GET", `/v1/homes/${state.home}/join-requests`, { cookie: avi.cookie })).status, 200);
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${noa.id}`, { cookie: dana })).json.code, "OWNER_ONLY");
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${avi.id}`, { cookie: avi.cookie })).json.code, "OWNER_CANNOT_LEAVE");
  assert.equal((await call("POST", `/v1/homes/${state.home}/secret`, { cookie: dana, body: { secret_sha256: "ab".repeat(32) } })).json.code, "OWNER_ONLY");

  // A claim by the new owner's account is no change of hands: nobody is removed.
  const claimed = await call("POST", "/v1/homes/claim", { cookie: avi.cookie, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  assert.equal(claimed.json.transferred, false);
  assert.deepEqual(await memberIds(avi.cookie, state.home), everyone);

  // The old owner deleting their account no longer takes the home with it.
  assert.equal((await call("DELETE", "/v1/me", { cookie: dana })).status, 204);
  assert.deepEqual(await homeOf(avi.cookie, state.home), { home_id: state.home, claimed: true, owner: true, member: true });
  assert.equal((await e2e(noa.cookie, state, noa.keyId)).status, 200);
});

test("the controller moves the owner account back, and a home no account claimed has none to move", TEST, async () => {
  const { state, cookie: dana } = await claimedHome();
  const danaId = await accountId(dana);
  const avi = await joins(state, dana, person("avi"), { admin: true });
  const moved = await tellOwner(state, tagOf(state.home, avi.id));
  assert.equal(moved?.ok, true, JSON.stringify(moved));
  // The controller did not follow (Avi was made a member meanwhile): it says to move it back.
  const back = await tellOwner(state, moved.previous);
  assert.equal(back?.ok, true, JSON.stringify(back));
  assert.equal((await homeOf(dana, state.home)).owner, true);
  assert.equal((await homeOf(avi.cookie, state.home)).owner, false);
  assert.equal(back.previous, tagOf(state.home, avi.id));
  assert.equal(moved.previous, tagOf(state.home, danaId));

  // A home no account claimed: nothing to move, the controller moves alone.
  const unclaimed = await home();
  for (const account of [tagOf(unclaimed.home, avi.id), null]) {
    const answer = await tellOwner(unclaimed, account);
    assert.equal(answer?.ok, false, JSON.stringify(answer));
    assert.equal(answer.code, "NOT_CLAIMED");
  }
});

// The owner review of 1.9.0 (findings 2 and 6): the controller did not follow a move, or heard no
// answer in time, and says so with the request's id (`owner_cancel`): exactly that move is undone,
// to the account it replaced, even one that never used an admin key through the account; an unknown
// id moves nothing; trying again moves it again, and a request for the account that owns the home
// already answers that nothing moved.
test("owner_cancel undoes exactly the move of that request, and trying again finishes it", TEST, async () => {
  // Dana claimed the home and never used a key through her account.
  const state = await home();
  const danaKey = randomHex(4);
  state.keys.set(danaKey, `ak_${randomHex(24)}`);
  state.admins.add(danaKey);
  state.announce();
  const dana = await signIn(person("dana"));
  assert.equal((await call("POST", "/v1/homes/claim", { cookie: dana, body: { home_id: state.home, claim_token: state.claimToken } })).status, 200);
  const avi = await joins(state, dana, person("avi"), { admin: true });
  await sleep(300);

  const id = randomHex(8);
  const answered = new Promise((resolve) => {
    const listener = (text) => {
      const message = JSON.parse(text);
      if (message.type === "owner_result" && message.id === id) {
        state.connection.off("unknown", listener);
        resolve(message);
      }
    };
    state.connection.on("unknown", listener);
  });
  state.connection.sendJson({ type: "owner", id, account: tagOf(state.home, avi.id) });
  const moved = await answered;
  assert.equal(moved.ok, true, JSON.stringify(moved));
  assert.equal(moved.moved, true);
  assert.equal((await homeOf(avi.cookie, state.home)).owner, true);

  // A cancel for another request moves nothing.
  state.connection.sendJson({ type: "owner_cancel", id: randomHex(8) });
  await sleep(500);
  assert.equal((await homeOf(avi.cookie, state.home)).owner, true);
  // The controller gave up on this one: Dana's account owns the home again (no admin key needed).
  state.connection.sendJson({ type: "owner_cancel", id });
  for (let tries = 0; tries < 50 && !(await homeOf(dana, state.home)).owner; tries += 1) await sleep(100);
  assert.equal((await homeOf(dana, state.home)).owner, true);
  assert.equal((await homeOf(avi.cookie, state.home)).owner, false);
  // The same cancel again: nothing more.
  state.connection.sendJson({ type: "owner_cancel", id });
  await sleep(300);
  assert.equal((await homeOf(dana, state.home)).owner, true);

  // Trying again: it moves; asked once more, it says it moved nothing.
  const again = await tellOwner(state, tagOf(state.home, avi.id));
  assert.equal(again?.ok, true, JSON.stringify(again));
  assert.equal(again.moved, true);
  const retried = await tellOwner(state, tagOf(state.home, avi.id));
  assert.equal(retried?.ok, true);
  assert.equal(retried.moved, false, "Avi's account owned it already");
  assert.equal((await homeOf(avi.cookie, state.home)).owner, true);
});
