// Alerts on admins' devices (cloud/src/alerts.js, ADR-047) end to end: the Worker under
// `wrangler dev`, a fake Google, a fake controller (the relay protocol, sealing like the driver) and
// a fake push service (fake-push.mjs) that checks each push's VAPID signature and opens its message
// as the browser would. The alert's minutes are 0.1 (6 s) and a connection whose pings go
// unanswered for 2 s counts as away, so the waits are short.
//   node --test tests/cloud/alerts.test.mjs

import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";
import path from "node:path";
import { after, afterEach, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { startFakePush, vapidVars } from "./fake-push.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { invitationKey, lockKey, open, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const OFFLINE_MS = 6000; // OFFLINE_ALERT_MINUTES = 0.1
const SILENCE_MS = 2000; // ALERT_SILENCE_SECONDS = 2
const TEST = { timeout: 60_000 };
const DANA = { sub: "google-dana", email: "dana@example.com", name: "Dana" };
const AVI = { sub: "google-avi", email: "avi@example.com", name: "Avi" };
const NOA = { sub: "google-noa", email: "noa@example.com", name: "Noa" };

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
    devVars: {
      ...googleVars(google, APP, "https://api.directorlink.test"),
      ...vapid,
      PUSH_TEST_URL: push.url,
      OFFLINE_ALERT_MINUTES: 0.1,
      ALERT_SILENCE_SECONDS: 2,
      REQUEST_TIMEOUT_MS: 3000,
    },
  });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
  await worker?.stop();
  await google?.close();
  await push?.close();
});

afterEach(async () => {
  assert.deepEqual(push.errors().map((entry) => entry.error), [], "every push was signed and encrypted right");
});

// --- A fake controller -----------------------------------------------------------------------------

const nowSeconds = () => Math.floor(Date.now() / 1000);

// A controller at a new home: its keys (id -> API key), which are admin keys, its invitations.
// `pings`: it pings every half second, as a driver does (every 10 s); without, it goes silent.
async function home({ pings = true } = {}) {
  const state = { home: randomHex(16), secret: randomHex(32), keys: new Map(), admins: new Set(), invitations: new Map(), claimToken: randomHex(24), pings };
  state.connect = async () => {
    const connection = await connectDriver({ url: worker.ws, home: state.home, secret: state.secret, pingIntervalMs: state.pings ? 500 : 0, silenceTimeoutMs: 0, hello: false });
    drivers.push(connection);
    state.connection = connection;
    // A 1.6.0 driver says how often it pings: the relay takes its socket as stale after 2.5 of them.
    connection.sendJson({ type: "hello", home: state.home, version: "1.6.0", ping_s: 1 });
    connection.on("unknown", (text) => answer(state, connection, JSON.parse(text)));
    return connection;
  };
  // The key ids, and which are admin keys (1.6.0); `admins: false` as a driver before 1.6.0.
  state.announce = ({ admins = true } = {}) =>
    state.connection.sendJson({ type: "keys", ids: [...state.keys.keys()], ...(admins ? { admins: [...state.admins] } : {}) });
  await state.connect();
  return state;
}

function answer(state, connection, message) {
  const reply = (fields) => connection.sendJson({ id: message.id, ...fields });
  if (message.type === "claim") {
    return reply({ type: "claim_result", ok: message.token === state.claimToken, code: message.token === state.claimToken ? undefined : "INVALID_CLAIM" });
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
    const response = { id: request.id, ts: nowSeconds(), status: 201, content_type: "application/json", body: JSON.stringify({ key, id, role: "member" }) };
    return reply({ type: "join_result", ok: true, key_id: id, envelope: seal(invitationKey(secret), { home: state.home, key: message.invitation }, "res", JSON.stringify(response)) });
  }
}

// --- Helpers ---------------------------------------------------------------------------------------

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

const signIn = (person) => signInAs(worker.http, google, person, APP);

async function eventually(check, what, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(100);
  }
}

// A sealed request through the account: the cloud then knows that this account uses this key.
async function e2e(cookie, state, keyId) {
  const request = { id: randomHex(8), ts: nowSeconds(), method: "GET", path: "/v1/system", body: null };
  const envelope = seal(lockKey(state.keys.get(keyId)), { home: state.home, key: keyId }, "req", JSON.stringify(request));
  return call("POST", `/v1/homes/${state.home}/e2e`, { cookie, body: { envelope } });
}

const membersOf = async (state, cookie) => (await call("GET", `/v1/homes/${state.home}/members`, { cookie })).json.items;

// Dana pairs at home (an admin key), claims the home and uses it once through the account.
async function claimedHome(options) {
  const state = await home(options);
  const keyId = randomHex(4);
  state.keys.set(keyId, `ak_${randomHex(24)}`);
  state.admins.add(keyId);
  state.announce();
  const dana = await signIn(DANA);
  const claimed = await call("POST", "/v1/homes/claim", { cookie: dana, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  assert.equal((await e2e(dana, state, keyId)).status, 200);
  await eventually(async () => (await membersOf(state, dana))[0]?.key_ids.includes(keyId), "Dana's key");
  return { state, dana, keyId };
}

// Someone joins with an invitation (a member key); returns their session and key id.
async function joins(state, owner, person) {
  const invitationId = randomHex(4);
  const secret = randomHex(32);
  state.invitations.set(invitationId, secret);
  const registered = await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: owner, body: { invitation_id: invitationId, email: person.email, expires_at: new Date(Date.now() + 3600_000).toISOString() } });
  assert.equal(registered.status, 201, registered.text);
  const cookie = await signIn(person);
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
  const joined = await call("POST", "/v1/join", { cookie, body: { home_id: state.home, invitation_id: invitationId, envelope: seal(invitationKey(secret), { home: state.home, key: invitationId }, "req", JSON.stringify(request)) } });
  assert.equal(joined.status, 200, joined.text);
  const keyId = JSON.parse(JSON.parse(open(invitationKey(secret), joined.json.envelope, "res")).body).id;
  state.announce();
  return { cookie, keyId };
}

function subscribe(state, cookie, browser, options = {}) {
  return call("POST", `/v1/homes/${state.home}/alerts`, { cookie, body: browser.subscription, ...options });
}

async function subscribed(state, cookie, options) {
  const browser = push.subscribe(options);
  const result = await subscribe(state, cookie, browser);
  assert.equal(result.status, 201, result.text);
  return browser;
}

const of = (browser, kind) => push.messagesFor(browser).filter((message) => message.kind === kind);

// --- Tests -----------------------------------------------------------------------------------------

test("an admin's browser is registered for the home's alerts; others are refused", TEST, async () => {
  const { state, dana } = await claimedHome();
  const key = await call("GET", `/v1/homes/${state.home}/alerts`, { cookie: dana });
  assert.equal(key.status, 200, key.text);
  assert.deepEqual(key.json, { public_key: vapid.VAPID_PUBLIC_KEY });

  const browser = push.subscribe();
  assert.equal((await subscribe(state, dana, browser)).status, 201);
  assert.equal((await subscribe(state, dana, browser)).status, 201, "registering again is fine");

  // A member who is not an admin, an account outside the home, no session, another site.
  const avi = await joins(state, dana, AVI);
  const member = await subscribe(state, avi.cookie, push.subscribe());
  assert.equal(member.status, 403);
  assert.equal(member.json.code, "ADMIN_ONLY");
  const noa = await signIn(NOA);
  assert.equal((await subscribe(state, noa, push.subscribe())).json.code, "NOT_A_MEMBER");
  assert.equal((await call("GET", `/v1/homes/${state.home}/alerts`, { cookie: noa })).status, 403);
  assert.equal((await subscribe(state, null, push.subscribe())).status, 401);
  assert.equal((await subscribe(state, dana, push.subscribe(), { origin: "https://evil.example" })).json.code, "ORIGIN_NOT_ALLOWED");

  // Only a push service's address, with the browser's keys.
  for (const bad of [
    { ...browser.subscription, endpoint: "https://example.com/push/1" },
    { ...browser.subscription, keys: { p256dh: browser.subscription.keys.p256dh } },
    { endpoint: browser.subscription.endpoint },
  ]) {
    const refused = await call("POST", `/v1/homes/${state.home}/alerts`, { cookie: dana, body: bad });
    assert.equal(refused.status, 400, JSON.stringify(bad));
    assert.equal(refused.json.code, "INVALID_SUBSCRIPTION");
  }

  // Avi made an admin at home: the controller says so, and he may.
  state.admins.add(avi.keyId);
  state.announce();
  await eventually(async () => (await subscribe(state, avi.cookie, push.subscribe())).status === 201, "Avi as an admin");

  // A driver before 1.6.0 does not say who its admins are: nobody can switch alerts on.
  const old = await claimedHome();
  old.state.announce({ admins: false });
  await sleep(300);
  const unknown = await subscribe(old.state, old.dana, push.subscribe());
  assert.equal(unknown.status, 409);
  assert.equal(unknown.json.code, "ROLES_UNKNOWN");

  const removed = await call("DELETE", `/v1/homes/${state.home}/alerts`, { cookie: dana, body: { endpoint: browser.subscription.endpoint } });
  assert.equal(removed.status, 204, removed.text);
});

test("a schedule that failed reaches the admins' browsers only, with no names, at most three an hour", TEST, async () => {
  const { state, dana } = await claimedHome();
  const danaBrowser = await subscribed(state, dana);
  const avi = await joins(state, dana, AVI);
  state.admins.add(avi.keyId);
  state.announce();
  const aviBrowser = await eventually(async () => {
    const browser = push.subscribe();
    return (await subscribe(state, avi.cookie, browser)).status === 201 ? browser : null;
  }, "Avi's browser");
  // Avi is a member again: his browser stays registered, but gets nothing.
  state.admins.delete(avi.keyId);
  state.announce();
  await sleep(300);

  const at = new Date(Date.now() - 5000).toISOString().replace(/\.\d+Z$/, "Z");
  state.connection.sendJson({ type: "alert", kind: "schedule_failed", at });
  const [message] = await eventually(async () => {
    const found = of(danaBrowser, "schedule_failed");
    return found.length ? found : null;
  }, "the alert at Dana's browser");
  assert.deepEqual(message, { kind: "schedule_failed", home: state.home, at: new Date(at).toISOString() });
  const delivered = push.received.find((entry) => entry.id === danaBrowser.id);
  assert.equal(delivered.headers.urgency, "high");
  assert.equal(delivered.vapid.key, vapid.VAPID_PUBLIC_KEY);
  assert.deepEqual(push.messagesFor(aviBrowser), [], "a member who is not an admin gets nothing");

  // Something else from the controller is not an alert.
  state.connection.sendJson({ type: "alert", kind: "door_opened", at });
  for (let index = 0; index < 4; index += 1) {
    state.connection.sendJson({ type: "alert", kind: "schedule_failed", at });
  }
  await sleep(1500);
  assert.equal(of(danaBrowser, "schedule_failed").length, 3, "three an hour");
  assert.equal(push.messagesFor(danaBrowser).filter((item) => item.kind !== "schedule_failed").length, 0);
});

test("a home away for the alert's minutes alerts once; a short drop never does", TEST, async () => {
  const { state, dana } = await claimedHome();
  const browser = await subscribed(state, dana);

  // Gone for a second, as when the connection is cut and the driver connects again.
  await state.connection.close();
  await sleep(800);
  await state.connect();
  state.announce();
  await sleep(OFFLINE_MS + 3000);
  assert.deepEqual(of(browser, "offline"), [], "a short drop does not alert");

  // Gone for good.
  const away = Date.now();
  await state.connection.close();
  await sleep(OFFLINE_MS - 1500);
  assert.deepEqual(of(browser, "offline"), [], "not before the minutes have passed");
  const [alert] = await eventually(async () => {
    const found = of(browser, "offline");
    return found.length ? found : null;
  }, "the offline alert", 6000);
  assert.equal(alert.home, state.home);
  assert.ok(Math.abs(Date.parse(alert.at) - away) < 1500, `away since ${alert.at}`);
  await sleep(OFFLINE_MS + 1000);
  assert.equal(of(browser, "offline").length, 1, "once for one absence");

  // Back, then away again: another absence, another alert.
  await state.connect();
  await sleep(500);
  await state.connection.close();
  await eventually(async () => of(browser, "offline").length === 2, "the second absence", OFFLINE_MS + 5000);
});

test("a connection whose pings go unanswered counts as away; one that pings does not", TEST, async () => {
  const silent = await claimedHome({ pings: false });
  const silentBrowser = await subscribed(silent.state, silent.dana);
  const pinging = await claimedHome();
  const pingingBrowser = await subscribed(pinging.state, pinging.dana);
  const lastHeard = Date.now();

  const [alert] = await eventually(async () => {
    const found = of(silentBrowser, "offline");
    return found.length ? found : null;
  }, "the silent home's alert", OFFLINE_MS + SILENCE_MS + 8000);
  assert.ok(Date.parse(alert.at) <= lastHeard + 500, `away since it was last heard (${alert.at})`);
  assert.deepEqual(of(pingingBrowser, "offline"), []);
});

test("a browser its push service no longer knows is forgotten", TEST, async () => {
  const { state, dana } = await claimedHome();
  const gone = await subscribed(state, dana, { status: 410 });
  const kept = await subscribed(state, dana);
  state.connection.sendJson({ type: "alert", kind: "schedule_failed", at: new Date().toISOString() });
  await eventually(async () => of(kept, "schedule_failed").length === 1, "the first alert");
  await eventually(async () => push.received.some((entry) => entry.id === gone.id), "the push to the unsubscribed browser");
  await sleep(500);
  state.connection.sendJson({ type: "alert", kind: "schedule_failed", at: new Date().toISOString() });
  await eventually(async () => of(kept, "schedule_failed").length === 2, "the second alert");
  await sleep(500);
  assert.equal(push.received.filter((entry) => entry.id === gone.id).length, 1, "the 410 browser was not asked again");
});

test("leaving the home, being removed and signing out everywhere end a browser's alerts", TEST, async () => {
  const { state, dana } = await claimedHome();
  const danaBrowser = await subscribed(state, dana);
  const avi = await joins(state, dana, AVI);
  state.admins.add(avi.keyId);
  state.announce();
  const aviBrowser = await eventually(async () => {
    const browser = push.subscribe();
    return (await subscribe(state, avi.cookie, browser)).status === 201 ? browser : null;
  }, "Avi's browser");
  const members = await membersOf(state, dana);
  const aviId = members.find((item) => item.email === AVI.email).user_id;
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/members/${aviId}`, { cookie: dana })).status, 204);
  state.connection.sendJson({ type: "alert", kind: "schedule_failed", at: new Date().toISOString() });
  await eventually(async () => of(danaBrowser, "schedule_failed").length === 1, "Dana's alert");
  await sleep(500);
  assert.deepEqual(push.messagesFor(aviBrowser), [], "removed from the home: no alerts");

  // Signing out everywhere (a lost phone) ends every browser's alerts of that account.
  const signOut = await call("POST", "/auth/logout?everywhere=1", { cookie: dana });
  assert.equal(signOut.status, 204, signOut.text);
  state.connection.sendJson({ type: "alert", kind: "schedule_failed", at: new Date().toISOString() });
  await sleep(1500);
  assert.equal(of(danaBrowser, "schedule_failed").length, 1, "signed out everywhere: no more alerts");
});

// A deploy restarts every Durable Object and ends its sockets without webSocketClose; the drivers
// come back within seconds. wrangler dev does the same when the Worker's code changes. Last: it
// drops every connection.
test("after the relay restarts, only a home that stays away alerts, counted from the restart", { timeout: 120_000 }, async () => {
  const back = await claimedHome();
  const backBrowser = await subscribed(back.state, back.dana);
  const gone = await claimedHome();
  const goneBrowser = await subscribed(gone.state, gone.dana);
  await sleep(1500);

  const restarted = Date.now();
  appendFileSync(path.join(worker.dir, "src", "index.js"), `\n// reloaded by the tests ${restarted}\n`);
  await Promise.race([Promise.all([back.state.connection.closed, gone.state.connection.closed]), sleep(60_000)]);
  await eventually(async () => {
    try {
      return (await fetch(`${worker.http}/health`)).ok;
    } catch {
      return false;
    }
  }, "the relay to answer again", 60_000);
  await back.state.connect();
  back.state.announce();

  const [alert] = await eventually(async () => {
    const found = of(goneBrowser, "offline");
    return found.length ? found : null;
  }, "the alert for the home that stayed away", 3 * OFFLINE_MS + 10_000);
  assert.ok(Date.parse(alert.at) >= restarted - 500, `away counted from the restart, not from before it (${alert.at})`);
  await sleep(OFFLINE_MS);
  assert.deepEqual(of(backBrowser, "offline"), [], "the home that came back is not alerted about");
});
