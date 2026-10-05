// Users and their devices (1.9.0, ADR-061) in the account service, end to end: the Worker under
// `wrangler dev`, a fake Google, a fake push service and a fake controller (the relay protocol,
// sealing like the driver). The controller hears which of its keys share an account, as an
// opaque tag per account and home, never an account's id or email, and only when its hello says
// `users`; with such a driver, any device of an account approves that account's new device, and the
// push of the request goes to all of the account's devices at the home, not only admins'.
//   node --test tests/cloud/users.test.mjs

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { after, afterEach, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { commitmentOf, keyPair } from "../../app/js/device-join.js";
import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { startFakePush, vapidVars } from "./fake-push.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { invitationKey, lockKey, open, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TEST = { timeout: 60_000 };

let worker;
let google;
let push;
const vapid = vapidVars();
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  push = await startFakePush();
  worker = await startWorker({
    migrate: true,
    devVars: { ...googleVars(google, APP, "https://api.directorlink.test"), ...vapid, PUSH_TEST_URL: push.url, REQUEST_TIMEOUT_MS: 3000 },
  });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
  await worker?.stop();
  await google?.close();
  await push?.close();
});

afterEach(() => {
  assert.deepEqual(push.errors().map((entry) => entry.error), [], "every push was signed and encrypted right");
});

const nowSeconds = () => Math.floor(Date.now() / 1000);

// Each test its own people: the limits count per account.
function person(name) {
  const tag = randomHex(4);
  return { sub: `google-${name}-${tag}`, email: `${name}-${tag}@example.com`, name };
}

// A controller at a new home. `users`: its hello lists `users` (DirectorLink 1.9.0). What the relay
// sends it besides its answers is kept in `seen`.
async function home({ users = true } = {}) {
  const state = { home: randomHex(16), keys: new Map(), admins: new Set(), invitations: new Map(), claimToken: randomHex(24), seen: [] };
  const connection = await connectDriver({ url: worker.ws, home: state.home, pingIntervalMs: 0, silenceTimeoutMs: 0, hello: false });
  drivers.push(connection);
  state.connection = connection;
  connection.sendJson({ type: "hello", home: state.home, version: users ? "1.9.0" : "1.8.0", ping_s: 10, features: users ? ["scene_links", "users"] : ["scene_links"] });
  connection.on("unknown", (text) => answer(state, connection, JSON.parse(text)));
  state.announce = () => connection.sendJson({ type: "keys", ids: [...state.keys.keys()], admins: [...state.admins] });
  state.accounts = () => state.seen.filter((message) => message.type === "accounts");
  return state;
}

function answer(state, connection, message) {
  state.seen.push(message);
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

async function eventually(check, what, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(100);
  }
}

async function e2e(cookie, state, keyId) {
  const request = { id: randomHex(8), ts: nowSeconds(), method: "GET", path: "/v1/system", body: null };
  const envelope = seal(lockKey(state.keys.get(keyId)), { home: state.home, key: keyId }, "req", JSON.stringify(request));
  return call("POST", `/v1/homes/${state.home}/e2e`, { cookie, body: { envelope } });
}

// The owner pairs at home (an admin key), claims the home and uses it once through the account.
async function claimedHome(options = {}) {
  const state = await home(options);
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

// Someone joins with an invitation: their session and key id.
async function joins(state, ownerCookie, who) {
  const invitationId = randomHex(4);
  const secret = randomHex(32);
  state.invitations.set(invitationId, secret);
  const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: ownerCookie, body: { invitation_id: invitationId, email: who.email, expires_at: new Date(Date.now() + 3600_000).toISOString() } });
  assert.equal(registered.status, 201, registered.text);
  const cookie = await signIn(who);
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
  const joined = await call("POST", "/v1/join", { cookie, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) } });
  assert.equal(joined.status, 200, joined.text);
  return { cookie, keyId: JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body).id };
}

const expectedTag = (homeId, userId) => createHash("sha256").update(`DirectorLink account v1|${homeId}|${userId}`).digest("hex").slice(0, 16);
const accountId = async (cookie) => (await call("GET", "/v1/me", { cookie })).json.id;
const lastAccounts = (state) => state.accounts().at(-1)?.keys ?? null;

test("the controller hears which keys share an account, as a tag per account and home", TEST, async () => {
  const { state, owner, cookie, keyId } = await claimedHome();
  const ownerId = await accountId(cookie);
  const tag = expectedTag(state.home, ownerId);
  await eventually(() => lastAccounts(state)?.[keyId], "the owner's key with its account");
  assert.deepEqual(lastAccounts(state), { [keyId]: [tag] }, "a key of no account is not listed");
  const message = state.accounts().at(-1);
  assert.match(message.id, /^[0-9a-f-]{36}$/);
  const text = JSON.stringify(state.accounts());
  assert.ok(!text.includes(ownerId) && !text.includes(owner.email), "never the account's id or email");

  // The owner's iPhone, paired at home, uses the home through the same account: the same tag.
  const phone = randomHex(4);
  state.keys.set(phone, `ak_${randomHex(24)}`);
  state.announce();
  const phoneSession = await signIn(owner);
  assert.equal((await e2e(phoneSession, state, phone)).status, 200);
  await eventually(() => lastAccounts(state)?.[phone], "the phone's key");
  assert.deepEqual(lastAccounts(state), { [keyId]: [tag], [phone]: [tag] });

  // An invited account: a tag of its own, sent once it joined.
  const avi = await joins(state, cookie, person("avi"));
  await eventually(() => lastAccounts(state)?.[avi.keyId], "the invited account's key");
  assert.deepEqual(lastAccounts(state)[avi.keyId], [expectedTag(state.home, await accountId(avi.cookie))]);
  assert.notEqual(lastAccounts(state)[avi.keyId][0], tag);

  // The same account at another home: another tag.
  const other = await home();
  const otherKey = randomHex(4);
  other.keys.set(otherKey, `ak_${randomHex(24)}`);
  other.announce();
  assert.equal((await call("POST", "/v1/homes/claim", { cookie, body: { home_id: other.home, claim_token: other.claimToken } })).status, 200);
  assert.equal((await e2e(cookie, other, otherKey)).status, 200);
  await eventually(() => lastAccounts(other)?.[otherKey], "the other home's key");
  assert.notEqual(lastAccounts(other)[otherKey][0], tag, "a tag cannot tie two homes together");

  // A key revoked at home: its account's tag goes with it at the next list.
  state.keys.delete(phone);
  state.announce();
  await eventually(() => lastAccounts(state) && !lastAccounts(state)[phone], "the revoked key to go");
  // The owner removes Avi from the home: Avi's key has no account any more.
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${await accountId(avi.cookie)}`, { cookie })).status, 204);
  await eventually(() => lastAccounts(state) && !lastAccounts(state)[avi.keyId], "the removed account's tag to go");
});

test("a driver whose hello does not say users is never sent which keys share an account", TEST, async () => {
  const { state, cookie, keyId } = await claimedHome({ users: false });
  assert.equal((await e2e(cookie, state, keyId)).status, 200);
  state.announce();
  await sleep(1000);
  assert.deepEqual(state.accounts(), [], "a 1.8.0 driver would wait for nothing, but it is not sent");
});

async function ask(cookie, state) {
  const pair = await keyPair();
  return call("POST", `/v1/homes/${state.home}/device-requests`, { cookie, body: { label: "Home Screen app on iPhone", commitment: await commitmentOf(pair.publicKey) } });
}

test("any device of an account approves its new device when the driver lets every user add their own", TEST, async () => {
  // A 1.8.0 driver: only an account with an admin key may ask.
  const old = await claimedHome({ users: false });
  const oldMember = await joins(old.state, old.cookie, person("noa"));
  old.state.announce();
  await sleep(300);
  assert.equal((await ask(oldMember.cookie, old.state)).json.code, "NO_APPROVER", "a member's account, with a driver before 1.9.0");

  // A 1.9.0 driver: the member's account may ask, and its other devices hear of it.
  const { state, cookie } = await claimedHome();
  const avi = person("avi");
  const member = await joins(state, cookie, avi);
  state.announce();
  await sleep(300);
  const browser = push.subscribe();
  const subscribed = await call("POST", `/v1/homes/${state.home}/alerts`, { cookie: member.cookie, body: { ...browser.subscription, key_id: member.keyId, device_requests: true } });
  assert.equal(subscribed.status, 201, subscribed.text);
  const newPhone = await signIn(avi);
  const asked = await ask(newPhone, state);
  assert.equal(asked.status, 201, asked.text);
  const [pushed] = await eventually(async () => {
    const found = push.messagesFor(browser).filter((message) => message.kind === "device_request");
    return found.length ? found : null;
  }, "the push at the member's own device");
  assert.equal(pushed.request, asked.json.id);
  // The member's device answers it.
  const approver = await keyPair();
  const answered = await call("POST", `/v1/homes/${state.home}/device-requests/${asked.json.id}/answer`, { cookie: member.cookie, body: { approver_key: approver.publicKey } });
  assert.equal(answered.status, 200, answered.text);
});

test("a join refused for a user who has five devices says so", TEST, async () => {
  const { state, cookie } = await claimedHome();
  const invitationId = randomHex(4);
  const secret = randomHex(32);
  const who = person("kid");
  const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie, body: { invitation_id: invitationId, email: who.email, expires_at: new Date(Date.now() + 3600_000).toISOString() } });
  assert.equal(registered.status, 201);
  // The controller refuses: its user is full.
  state.connection.removeAllListeners("unknown");
  state.connection.on("unknown", (text) => {
    const message = JSON.parse(text);
    if (message.type === "join") state.connection.sendJson({ id: message.id, type: "join_result", ok: false, code: "USER_DEVICE_LIMIT" });
  });
  const kid = await signIn(who);
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
  const joined = await call("POST", "/v1/join", { cookie: kid, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) } });
  assert.equal(joined.status, 409, joined.text);
  assert.equal(joined.json.code, "USER_DEVICE_LIMIT");
});
