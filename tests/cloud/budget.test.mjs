// Every request through the relay ends within 18 s of reaching the home's object (1.10.1, ADR-073,
// cloud/src/home-relay.js REQUEST_BUDGET_MS, docs/RELAY.md): waiting for the driver to come back,
// sending, sending again and the answer together, so that the relay's own 504 HOME_TIMEOUT reaches
// the app before its 20 s (app/js/remote.js) run out, and the app says the home did not answer
// rather than that DirectorLink's servers could not be reached. Up to 1.10.0 a request that first
// waited 8 s for the driver then waited 15 s for its answer: 23 s. Pinned with REQUEST_TIMEOUT_MS
// above the budget (30 s) and the production RECONNECT_WAIT_MS (8 s). The Worker under
// `wrangler dev`, a fake Google and a fake controller that takes requests and never answers.
//   node --test tests/cloud/budget.test.mjs

import assert from "node:assert/strict";
import { after, afterEach, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { callTestEndpoint, connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { lockKey, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TOKEN = "budget-test-token";
const BUDGET_MS = 18000; // REQUEST_BUDGET_MS
const APP_TIMEOUT_MS = 20000; // app/js/remote.js TIMEOUT_MS
const TIMEOUT_MS = 30000; // REQUEST_TIMEOUT_MS for this run: above the budget
const RECONNECT_WAIT_MS = 8000; // as in production
const DANA = { sub: "google-dana-budget", email: "dana-budget@example.com", name: "Dana" };
const FEATURES = ["scene_links", "alerts_gone", "users", "resend", "alert_acks"];

let worker;
let google;
let dana;
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  worker = await startWorker({
    migrate: true,
    devVars: { ...googleVars(google, APP, "https://api.directorlink.test"), TEST_TOKEN: TOKEN, REQUEST_TIMEOUT_MS: TIMEOUT_MS, RECONNECT_WAIT_MS },
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

const nowSeconds = () => Math.floor(Date.now() / 1000);

async function call(method, apiPath, { body } = {}) {
  const headers = { Origin: APP, Cookie: dana };
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

async function eventually(check, what, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(25);
  }
}

// A home claimed by Dana, with one key. Its driver's connections answer claims and nothing else:
// `got` is every e2e, link and request they were sent.
async function claimedHome() {
  const state = { home: randomHex(16), secret: randomHex(32), instance: randomHex(16), keyId: randomHex(4), apiKey: `ak_${randomHex(24)}`, claimToken: randomHex(24), got: [] };
  state.connect = async () => {
    const connection = await connectDriver({ url: worker.ws, home: state.home, secret: state.secret, pingIntervalMs: 0, silenceTimeoutMs: 0, hello: false });
    drivers.push(connection);
    connection.on("unknown", (text) => {
      const message = JSON.parse(text);
      if (message.type === "claim") {
        connection.sendJson({ type: "claim_result", id: message.id, ok: message.token === state.claimToken });
      } else if (["e2e", "link"].includes(message.type)) {
        state.got.push(message);
      }
    });
    connection.on("request", (message) => state.got.push(message));
    connection.sendJson({ type: "hello", home: state.home, version: "1.10.1", ping_s: 5, features: FEATURES, instance: state.instance });
    await sleep(100);
    state.connection = connection;
    return connection;
  };
  await state.connect();
  const claimed = await call("POST", "/v1/homes/claim", { body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  return state;
}

// Dana's app sends a sealed request through the account; resolves with the answer and how long it took.
async function press(state) {
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/scenes/off/run", body: null };
  const envelope = seal(lockKey(state.apiKey), { home: state.home, key: state.keyId }, "req", JSON.stringify(request));
  const started = Date.now();
  const result = await call("POST", `/v1/homes/${state.home}/e2e`, { body: { envelope } });
  return { ...result, ms: Date.now() - started };
}

function assertWithinBudget(result, what) {
  assert.equal(result.status, 504, `${what}: ${result.text}`);
  assert.equal(result.json.code, "HOME_TIMEOUT", what);
  assert.ok(result.ms >= BUDGET_MS - 500, `${what}: the whole budget, ${result.ms} ms`);
  assert.ok(result.ms < BUDGET_MS + 1500 && result.ms < APP_TIMEOUT_MS, `${what}: answered at ${result.ms} ms, before the app gives up at ${APP_TIMEOUT_MS} ms`);
  assert.match(result.json.detail, /^The home did not answer within 1[89] s$/, what);
}

// Run together, so that the file takes the budget once.
test("every request ends within 18 s of reaching the relay, before the app's 20 s", { timeout: 60_000 }, async () => {
  const [plain, waited, linkRun, testRequest] = await Promise.all([
    // The driver takes it and never answers: 18 s, not REQUEST_TIMEOUT_MS's 30 s.
    (async () => {
      const state = await claimedHome();
      const result = await press(state);
      assert.equal(state.got.length, 1, "it went to the home");
      return result;
    })(),
    // The driver had just lost its connection: the request waits for it (7 s here), goes on its
    // next connection and gets what is left of the 18 s (up to 1.10.0: 7 s and then 15 s more).
    (async () => {
      const state = await claimedHome();
      state.connection.destroy();
      await sleep(300);
      const pending = press(state);
      await sleep(RECONNECT_WAIT_MS - 1000);
      await state.connect();
      const result = await pending;
      assert.equal(state.got.length, 1, "it went to the driver's next connection");
      return result;
    })(),
    // A scene link's run from a phone's automation: the same budget.
    (async () => {
      const state = await claimedHome();
      const started = Date.now();
      const response = await fetch(`${worker.http}/run/${state.home}.${randomHex(4)}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ secret: randomHex(20) }) });
      const text = await response.text();
      return { status: response.status, json: JSON.parse(text), text, ms: Date.now() - started };
    })(),
    // Version 0's test endpoint: the same budget.
    (async () => {
      const state = await claimedHome();
      const started = Date.now();
      const result = await callTestEndpoint({ url: worker.http, token: TOKEN, home: state.home, path: "/v1/system" });
      return { status: result.status, json: result.json, text: result.text, ms: Date.now() - started };
    })(),
  ]);
  assertWithinBudget(plain, "a request the home never answers");
  assertWithinBudget(waited, "a request that waited for the driver to come back");
  assertWithinBudget(linkRun, "a scene link's run");
  assertWithinBudget(testRequest, "a test request");
});

// A request sent again after a lost connection (ADR-072) keeps to the same budget: it was sent again
// within 10 s of reaching the relay and waits 8 s at most for its answer, never past the 18 s.
test("a request sent again keeps to the same budget", { timeout: 60_000 }, async () => {
  const state = await claimedHome();
  const pending = press(state);
  await eventually(() => state.got.length === 1, "the request to reach the first connection");
  await sleep(1500);
  state.connection.destroy();
  await sleep(200);
  await state.connect();
  const result = await pending;
  assert.equal(state.got.length, 2, "sent again");
  assert.equal(state.got[1].resent, 1);
  assert.equal(result.status, 504, result.text);
  assert.ok(result.ms < BUDGET_MS + 1500, `answered at ${result.ms} ms`);
});
