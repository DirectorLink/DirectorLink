// A request already sent when the driver's connection ends is sent again on its next connection
// (1.10.0, ADR-072, cloud/src/home-relay.js, docs/RELAY.md "While the driver reconnects"): the same
// frame, with the same id, once the driver's hello lists `resend` and names the same instance;
// at most twice; within the wait for the driver. A driver without the feature, one that restarted,
// or one that does not come back in time: 502 HOME_DISCONNECTED, as before. The Worker under
// `wrangler dev`, a fake Google and a fake controller that connects again as the driver does.
//   node --test tests/cloud/resend.test.mjs

import assert from "node:assert/strict";
import { after, afterEach, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { lockKey, open, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TEST = { timeout: 30_000 };
const DANA = { sub: "google-dana-resend", email: "dana-resend@example.com", name: "Dana" };
// REQUEST_TIMEOUT_MS for this run: above the 8 s a resend waits (RESEND_TIMEOUT_MS), which keeps a
// resent request within the app's 20 s (production waits 15 s for a request); and above the 10 s
// within which a request may go again (RESEND_WITHIN_MS), so that it is the bound.
const TIMEOUT_MS = 12000;
const RESEND_TIMEOUT_MS = 8000;
const RESEND_WITHIN_MS = 10000;
const RECONNECT_WAIT_MS = 2000; // RECONNECT_WAIT_MS for this run
const FEATURES = ["scene_links", "alerts_gone", "users", "resend"];

let worker;
let google;
let dana;
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  worker = await startWorker({
    migrate: true,
    devVars: { ...googleVars(google, APP, "https://api.directorlink.test"), REQUEST_TIMEOUT_MS: TIMEOUT_MS, RECONNECT_WAIT_MS },
  });
  dana = await signInAs(worker.http, google, DANA, APP);
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await worker?.stop();
  await google?.close();
});

afterEach(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close().catch(() => {})));
});

// --- A fake controller that connects again --------------------------------------------------------

const nowSeconds = () => Math.floor(Date.now() / 1000);

// A home with one key (Dana's), claimed by Dana. Each connection of its driver is made by
// `connect(behave, options)`: `behave(message, connection)` sees what the relay sends it.
async function claimedHome() {
  const state = { home: randomHex(16), secret: randomHex(32), instance: randomHex(16), keyId: randomHex(4), apiKey: `ak_${randomHex(24)}`, claimToken: randomHex(24), seen: [] };
  state.connect = (behave, options) => connect(state, behave, options);
  await state.connect((message, connection) => {
    if (message.type === "claim") {
      connection.sendJson({ type: "claim_result", id: message.id, ok: message.token === state.claimToken });
    }
  });
  const claimed = await call("POST", "/v1/homes/claim", { body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  return state;
}

// One connection of the driver. options: features (its hello's), instance (null for none), hello
// (false: the hello waits for connection.hello()).
async function connect(state, behave, { features = FEATURES, instance = state.instance, hello = true } = {}) {
  const connection = await connectDriver({ url: worker.ws, home: state.home, secret: state.secret, pingIntervalMs: 0, silenceTimeoutMs: 0, hello: false });
  drivers.push(connection);
  const number = state.seen.length ? Math.max(...state.seen.map((item) => item.connection)) + 1 : 1;
  connection.on("unknown", (text) => {
    const message = JSON.parse(text);
    if (message.type === "accounts" || message.type === "alerts_gone") return;
    state.seen.push({ connection: number, message });
    behave?.(message, connection);
  });
  connection.hello = () => connection.sendJson({ type: "hello", home: state.home, version: "1.10.0", ping_s: 5, features, ...(instance ? { instance } : {}) });
  if (hello) {
    connection.hello();
    // The hello is handled before what follows on this socket; give the relay a moment for it.
    await sleep(100);
  }
  return connection;
}

// The controller's sealed answer to a sealed request.
function answer(state, message, body = "done") {
  const lock = lockKey(state.apiKey);
  const request = JSON.parse(open(lock, message.envelope, "req"));
  const plaintext = JSON.stringify({ id: request.id, ts: nowSeconds(), status: 200, content_type: "text/plain", body });
  return { type: "e2e", id: message.id, envelope: seal(lock, { home: state.home, key: state.keyId }, "res", plaintext) };
}

async function call(method, path, { cookie = dana, body } = {}) {
  const headers = { Origin: APP };
  if (cookie) headers.Cookie = cookie;
  if (body !== undefined) headers["content-type"] = "application/json";
  const response = await fetch(`${worker.http}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await response.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    // Not JSON.
  }
  return { status: response.status, json, text };
}

// Dana's app sends a sealed request through the account (POST /v1/homes/{home}/e2e); returns the
// call's promise and the opened answer once it is there.
function press(state, path = "/v1/scenes/off/run") {
  const lock = lockKey(state.apiKey);
  const plaintext = JSON.stringify({ id: randomHex(8), ts: nowSeconds(), method: "POST", path, body: null });
  const envelope = seal(lock, { home: state.home, key: state.keyId }, "req", plaintext);
  return call("POST", `/v1/homes/${state.home}/e2e`, { body: { envelope } }).then((result) => {
    if (result.status === 200) result.answer = JSON.parse(open(lock, result.json.envelope, "res"));
    return result;
  });
}

async function eventually(check, what, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(25);
  }
}

// What the connections of the driver got of `type`: [{ connection, message }].
const got = (state, type = "e2e") => state.seen.filter((item) => item.message.type === type);

function logged(event, home) {
  return worker
    .output()
    .split("\n")
    .map((line) => {
      try {
        return JSON.parse(line.slice(line.indexOf("{")));
      } catch {
        return null;
      }
    })
    .filter((entry) => entry?.event === event && entry.home === home);
}

function assertDisconnected(result) {
  assert.equal(result.status, 502, result.text);
  assert.equal(result.json.code, "HOME_DISCONNECTED");
}

// --- Tests ------------------------------------------------------------------------------------------

// The 21:01 case: Turn off all AC sent into a connection that had just died without a close.
test("a request in flight when the driver's connection dies is sent again after its next hello and answered once", TEST, async () => {
  const state = await claimedHome();
  const first = await state.connect(() => {}); // the frame goes into a dead connection: no answer
  const pending = press(state);
  await eventually(() => got(state).length === 1, "the request to reach the first connection");
  first.destroy(); // cut without a close (1006)
  await sleep(200);
  await state.connect((message, connection) => connection.sendJson(answer(state, message, "turned off")));
  const result = await pending;
  assert.equal(result.status, 200, result.text);
  assert.equal(result.answer.status, 200);
  assert.equal(result.answer.body, "turned off");

  const [sent, resent, ...more] = got(state);
  assert.deepEqual(more, [], "sent twice in all");
  assert.equal(resent.connection, sent.connection + 1, "again on the next connection");
  assert.equal(resent.message.id, sent.message.id, "the same id");
  assert.deepEqual(resent.message.envelope, sent.message.envelope, "the same sealed request");
  assert.equal(sent.message.resent, undefined);
  assert.equal(resent.message.resent, 1);
  const [line] = logged("request_resent", state.home);
  assert.equal(line.count, 1);
  assert.equal(line.resent, 1);
  assert.equal(typeof line.after_ms, "number");
  assert.doesNotMatch(JSON.stringify(line), /envelope|scenes/, "never a body");
});

// The driver connects again while the relay still holds the old socket (it never saw it end).
test("a request in flight on a connection the driver replaced is sent again on the new one", TEST, async () => {
  const state = await claimedHome();
  const first = await state.connect((message, connection) => connection.socket.pause());
  const pending = press(state);
  await eventually(() => got(state).length === 1, "the request to reach the first connection");
  const started = Date.now();
  await state.connect((message, connection) => connection.sendJson(answer(state, message)));
  const result = await pending;
  assert.equal(result.status, 200, result.text);
  assert.ok(Date.now() - started < TIMEOUT_MS, "answered by the new connection, not at a timeout");
  assert.deepEqual(got(state).map((item) => [item.connection, item.message.resent ?? 0]), [[2, 0], [3, 1]]);
  first.destroy();
});

test("a scene link's run in flight is sent again and runs once", TEST, async () => {
  const state = await claimedHome();
  const link = { id: randomHex(4), secret: randomHex(20) };
  const first = await state.connect(() => {});
  const pending = fetch(`${worker.http}/run/${state.home}.${link.id}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ secret: link.secret }) });
  await eventually(() => got(state, "link").length === 1, "the run to reach the first connection");
  first.destroy();
  await sleep(200);
  await state.connect((message, connection) => {
    if (message.type === "link") connection.sendJson({ type: "link_result", id: message.id, ok: true, result: "ran" });
  });
  const response = await pending;
  assert.equal(response.status, 200);
  assert.equal((await response.json()).result, "ran");
  const runs = got(state, "link");
  assert.equal(runs.length, 2);
  assert.equal(runs[1].message.id, runs[0].message.id);
  assert.equal(runs[1].message.secret, runs[0].message.secret);
  assert.equal(runs[1].message.resent, 1);
});

test("a driver without the feature still gets 502 HOME_DISCONNECTED, and is never sent it again", TEST, async () => {
  const state = await claimedHome();
  const old = ["scene_links", "alerts_gone", "users"]; // DirectorLink 1.9.0
  const first = await state.connect((message, connection) => connection.socket.pause(), { features: old });
  const pending = press(state);
  await eventually(() => got(state).length === 1, "the request to reach the first connection");
  const started = Date.now();
  await state.connect((message, connection) => connection.sendJson(answer(state, message)), { features: old });
  assertDisconnected(await pending);
  assert.ok(Date.now() - started < RECONNECT_WAIT_MS, "at once, as before");
  await sleep(300);
  assert.equal(got(state).length, 1, "not sent again");
  first.destroy();
});

test("a driver that restarted meanwhile (another instance) is never sent it again", TEST, async () => {
  const state = await claimedHome();
  const first = await state.connect(() => {});
  const pending = press(state);
  await eventually(() => got(state).length === 1, "the request to reach the first connection");
  first.destroy();
  await sleep(200);
  await state.connect((message, connection) => connection.sendJson(answer(state, message)), { instance: randomHex(16) });
  const result = await pending;
  assertDisconnected(result);
  assert.match(result.json.detail, /restarted/);
  await sleep(300);
  assert.equal(got(state).length, 1, "not sent again");
});

test("no hello in time: 502 HOME_DISCONNECTED after the wait", TEST, async () => {
  const state = await claimedHome();
  const first = await state.connect(() => {});
  const pending = press(state);
  await eventually(() => got(state).length === 1, "the request to reach the first connection");
  const started = Date.now();
  first.destroy();
  assertDisconnected(await pending);
  const waited = Date.now() - started;
  assert.ok(waited >= RECONNECT_WAIT_MS - 300 && waited < RECONNECT_WAIT_MS + 2000, `answered after ${waited} ms`);
  // The driver back later is not sent it.
  await state.connect(() => {});
  await sleep(300);
  assert.equal(got(state).length, 1);
});

test("a request is sent again at most twice", TEST, async () => {
  const state = await claimedHome();
  let connection = await state.connect(() => {});
  const pending = press(state);
  // Each connection dies before it answers.
  for (let sends = 1; sends <= 3; sends += 1) {
    await eventually(() => got(state).length === sends, `send ${sends}`);
    connection.destroy();
    if (sends < 3) {
      await sleep(150);
      connection = await state.connect(() => {});
    }
  }
  const result = await pending;
  assertDisconnected(result);
  assert.deepEqual(got(state).map((item) => item.message.resent ?? 0), [0, 1, 2]);
  await state.connect(() => {});
  await sleep(300);
  assert.equal(got(state).length, 3, "not a fourth time");
});

test("a request sent again gets a fresh wait, and a driver that no longer has its answer gets 502", TEST, async () => {
  const state = await claimedHome();
  let first = await state.connect(() => {});
  const silent = press(state);
  await eventually(() => got(state).length === 1, "the request to reach the first connection");
  first.destroy();
  await sleep(150);
  const resentAt = Date.now();
  await state.connect(() => {}); // takes it again, and says nothing
  const timedOut = await silent;
  assert.equal(timedOut.status, 504, timedOut.text);
  assert.equal(timedOut.json.code, "HOME_TIMEOUT");
  // 8 s, not the request's own 12 s: sent within 10 s and answered within 8, a resent request ends
  // within 18 s of reaching the relay, under the app's 20 s.
  const waited = Date.now() - resentAt;
  assert.ok(waited >= RESEND_TIMEOUT_MS - 300 && waited < RESEND_TIMEOUT_MS + 2000, `timed out ${waited} ms after the resend`);

  // It ran, but its answer was too large to keep (a picture): as before 1.10.0, 502.
  first = await state.connect(() => {});
  const lost = press(state, "/v1/cameras/60/snapshot");
  await eventually(() => got(state).length === 3, "the next request");
  first.destroy();
  await sleep(150);
  await state.connect((message, connection) => connection.sendJson({ type: "e2e", id: message.id, ok: false, code: "ANSWER_NOT_KEPT" }));
  const result = await lost;
  assertDisconnected(result);
  // The driver also says so for a request it may have run and forgotten (more than 512 in 30 s).
  assert.match(result.json.detail, /^The home may have carried it out, but its answer was lost/);
});

// A request that reached the relay just as the driver's new connection opened goes on it before its
// hello has come. If that connection is cut too (the route flipping again), the hello that came
// meanwhile says the driver takes `resend`: the request goes again on the next connection.
test("a request sent on a new connection before its hello goes again when that one is cut too", TEST, async () => {
  const state = await claimedHome();
  const second = await state.connect(() => {}, { hello: false });
  const pending = press(state);
  await eventually(() => got(state).length === 1, "the request to reach the new connection");
  second.hello();
  await sleep(150);
  second.destroy();
  await sleep(150);
  await state.connect((message, connection) => connection.sendJson(answer(state, message)));
  const result = await pending;
  assert.equal(result.status, 200, result.text);
  assert.deepEqual(got(state).map((item) => [item.connection, item.message.resent ?? 0]), [[2, 0], [3, 1]]);
});

// Sent again only within 10 s of reaching the relay (RESEND_WITHIN_MS): a request whose connection
// is found gone 8 s after it came goes again; one found gone after 10.5 s fails at once, as before.
test("a request goes again only within 10 s of reaching the relay", { timeout: 40_000 }, async () => {
  const run = async (lostAfterMs) => {
    const state = await claimedHome();
    await state.connect((message, connection) => connection.socket.pause());
    const started = Date.now();
    const pending = press(state);
    await eventually(() => got(state).length === 1, "the request to reach the connection");
    await sleep(Math.max(0, started + lostAfterMs - Date.now()));
    const replacedAt = Date.now();
    await state.connect((message, connection) => connection.sendJson(answer(state, message)));
    const result = await pending;
    return { result, sends: got(state).map((item) => item.message.resent ?? 0), afterMs: Date.now() - replacedAt };
  };
  const [inTime, late] = await Promise.all([run(RESEND_WITHIN_MS - 2000), run(RESEND_WITHIN_MS + 500)]);
  assert.equal(inTime.result.status, 200, inTime.result.text);
  assert.deepEqual(inTime.sends, [0, 1]);
  assertDisconnected(late.result);
  assert.deepEqual(late.sends, [0], "not sent again");
  assert.ok(late.afterMs < RECONNECT_WAIT_MS, `at once: ${late.afterMs} ms`);
});
