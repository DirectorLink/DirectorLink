// A home that connects again too often is paused (ADR-093), end to end: `wrangler dev --local` runs
// the relay (worker.mjs) with its limits made small in .dev.vars, scripts/relay_smoke.mjs plays the
// driver.
//   node --test tests/cloud/throttle.test.mjs
// RELAY_THROTTLE_CONNECTS accepted connections within RELAY_THROTTLE_WINDOW_MS pause the home for
// RELAY_THROTTLE_MS, twice as long the next time; another home is not touched.

import assert from "node:assert/strict";
import { after, afterEach, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { HandshakeError, connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const CONNECTS = 3; // RELAY_THROTTLE_CONNECTS for this run (the default is 30)
const PAUSE_MS = 3000; // RELAY_THROTTLE_MS (the default is 30 minutes)
const TEST = { timeout: 60_000 };

let relay;
const drivers = [];

before(async () => {
  relay = await startWorker({
    devVars: { TEST_TOKEN: `test-${randomHex(16)}`, RELAY_THROTTLE_CONNECTS: CONNECTS, RELAY_THROTTLE_WINDOW_MS: 60_000, RELAY_THROTTLE_MS: PAUSE_MS },
  });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await relay?.stop();
});

afterEach(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
});

function newHome() {
  return { home: randomHex(16), secret: randomHex(32) };
}

async function driver(options) {
  const connection = await connectDriver({ url: relay.ws, pingIntervalMs: 0, silenceTimeoutMs: 0, ...options });
  drivers.push(connection);
  return connection;
}

// Connects and closes `count` times, as a driver that keeps connecting again.
async function reconnect(home, count) {
  for (let i = 0; i < count; i += 1) {
    const connection = await driver(home);
    await sleep(50);
    await connection.close();
  }
}

// The refusal of a paused home: 429 RECONNECTING_TOO_OFTEN with a Retry-After of at most `maxSeconds`.
async function refused(home, maxSeconds) {
  const error = await connectDriver({ url: relay.ws, pingIntervalMs: 0, silenceTimeoutMs: 0, ...home }).then(
    (connection) => {
      drivers.push(connection);
      return null;
    },
    (failure) => failure
  );
  assert.ok(error instanceof HandshakeError, `refused, not connected: ${error}`);
  assert.equal(error.status, 429);
  assert.equal(error.problem?.code, "RECONNECTING_TOO_OFTEN");
  const after = Number(error.headers["retry-after"]);
  assert.ok(Number.isInteger(after) && after >= 1 && after <= maxSeconds, `Retry-After ${error.headers["retry-after"]}`);
  return after;
}

test("a home that connects again too often is paused, then takes connections again", TEST, async () => {
  const home = newHome();
  // The connections up to the limit are taken, the last too: it may be the one that works.
  await reconnect(home, CONNECTS);
  // The next is refused, from the object and then from the cache, for the pause.
  await refused(home, PAUSE_MS / 1000);
  await refused(home, PAUSE_MS / 1000);
  // Another home connects as always.
  const other = newHome();
  await reconnect(other, 1);
  // Once the pause is over, the home connects again.
  await sleep(PAUSE_MS + 500);
  const back = await driver(home);
  assert.ok(back, "connected again after the pause");
});

test("paused again soon, it waits twice as long", TEST, async () => {
  const home = newHome();
  await reconnect(home, CONNECTS);
  await refused(home, PAUSE_MS / 1000);
  await sleep(PAUSE_MS + 500);
  // Its count started over with the pause: the same number again pauses it, for longer.
  await reconnect(home, CONNECTS);
  const after = await refused(home, (2 * PAUSE_MS) / 1000);
  assert.ok(after > PAUSE_MS / 1000, `the second pause is longer: Retry-After ${after}`);
});

test("a wrong secret is still refused as such, not counted", TEST, async () => {
  const home = newHome();
  await reconnect(home, 1);
  for (let i = 0; i < CONNECTS + 1; i += 1) {
    const error = await connectDriver({ url: relay.ws, home: home.home, secret: randomHex(32) }).catch((failure) => failure);
    assert.ok(error instanceof HandshakeError);
    assert.equal(error.status, 401);
  }
  // Only its own connections count: the home is not paused.
  await reconnect(home, 1);
});
