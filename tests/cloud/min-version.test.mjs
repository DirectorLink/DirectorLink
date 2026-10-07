// The oldest DirectorLink the relay takes (cloud/src/min-version.js, ADR-059): the Worker var
// MIN_DRIVER_VERSION. The comparison in Node; then the Worker under `wrangler dev`, first without a
// minimum (every version connects), then "deployed" again with MIN_DRIVER_VERSION=1.8.0 (added to
// its wrangler.jsonc, which reloads it as a deploy restarts it): drivers
// below it are refused 426 before the home's Durable Object is asked, and a home whose last driver
// is below it is "update required" for the account, not offline.
//   node --test tests/cloud/min-version.test.mjs

import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { after, afterEach, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { belowMinimum, minimumVersion, updateRequired } from "../../cloud/src/min-version.js";
import { HandshakeError, callTestEndpoint, connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { lockKey, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TOKEN = `test-${randomHex(16)}`;
const TEST = { timeout: 60_000 };
const DANA = { sub: "google-dana-min", email: "dana-min@example.com", name: "Dana" };

let worker;
let google;
let vars;
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  vars = { ...googleVars(google, APP, "https://api.directorlink.test"), TEST_TOKEN: TOKEN, REQUEST_TIMEOUT_MS: 3000, RECONNECT_WAIT_MS: 0 };
  worker = await startWorker({ migrate: true, devVars: vars });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
  await worker?.stop();
  await google?.close();
}, { timeout: 60_000 });

afterEach(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
});

// --- Helpers ---------------------------------------------------------------------------------------

async function driver(options) {
  const connection = await connectDriver({ url: worker.ws, pingIntervalMs: 0, silenceTimeoutMs: 0, ...options });
  drivers.push(connection);
  return connection;
}

// The handshake's refusal, or null when the driver connected (it is closed again then).
async function refusalOf(options) {
  try {
    const connection = await driver(options);
    await connection.close();
    return null;
  } catch (error) {
    assert.ok(error instanceof HandshakeError, String(error));
    return error;
  }
}

async function call(method, apiPath, { cookie, body } = {}) {
  const headers = { Origin: APP };
  if (cookie) headers.Cookie = cookie;
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

async function status(home) {
  const result = await callTestEndpoint({ url: worker.http, token: TOKEN, home, path: "/status" });
  assert.equal(result.status, 200, result.text);
  return result.json;
}

function logged(event, home) {
  return worker
    .output()
    .split("\n")
    .flatMap((line) => {
      const start = line.indexOf("{");
      if (start < 0) return [];
      try {
        const value = JSON.parse(line.slice(start));
        return value.event === event && value.home === home ? [value] : [];
      } catch {
        return [];
      }
    });
}

async function eventually(check, what, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() > deadline) assert.fail(`timed out waiting for ${what}`);
    await sleep(200);
  }
}

// A deploy with these vars: they go into the Worker's wrangler.jsonc, which `wrangler dev` reloads
// with its new vars (every Durable Object restarts, as at a deploy).
async function redeploy(extra) {
  const config = path.join(worker.dir, "wrangler.jsonc");
  const text = readFileSync(config, "utf8");
  const added = Object.entries(extra).map(([name, value]) => `${JSON.stringify(name)}: ${JSON.stringify(value)},`).join(" ");
  assert.ok(text.includes('"vars": {'));
  writeFileSync(config, text.replace('"vars": {', `"vars": { ${added}`));
  // The old Worker may answer for a moment: wait until the new one refuses an old driver.
  await eventually(async () => (await refusalOf({ home: randomHex(16), version: "1.0.0" }))?.status === 426, "the Worker with the minimum", 60_000);
}

// --- The comparison --------------------------------------------------------------------------------

test("versions compare by their three numbers; anything else is below a minimum", () => {
  assert.equal(belowMinimum("1.7.0", "1.8.0"), true);
  assert.equal(belowMinimum("1.7.9", "1.8.0"), true);
  assert.equal(belowMinimum("0.9.0-smoke", "1.8.0"), true);
  assert.equal(belowMinimum("1.8.0", "1.8.0"), false);
  assert.equal(belowMinimum("1.8.0-rc.1", "1.8.0"), false, "a pre-release of the minimum is its numbers");
  assert.equal(belowMinimum("1.10.0", "1.8.0"), false, "numbers, not text: 10 > 8");
  assert.equal(belowMinimum("2.0.0", "1.8.0"), false);
  assert.equal(belowMinimum("1.8", "1.8.0"), true, "not three numbers");
  assert.equal(belowMinimum("dev", "1.8.0"), true);
  assert.equal(belowMinimum(null, "1.8.0"), true, "no version header");
  assert.equal(minimumVersion({}), null, "unset: no minimum");
  assert.equal(minimumVersion({ MIN_DRIVER_VERSION: "" }), null);
  assert.equal(minimumVersion({ MIN_DRIVER_VERSION: " 1.8.0 " }), "1.8.0");
  assert.equal(minimumVersion({ MIN_DRIVER_VERSION: "1.8" }), null, "a minimum that is not three numbers is ignored");
  assert.equal(minimumVersion({ MIN_DRIVER_VERSION: "latest" }), null);
  assert.equal(updateRequired({}, "0.1.0"), null);
  assert.equal(updateRequired({ MIN_DRIVER_VERSION: "1.8.0" }, "1.7.0"), "1.8.0");
  assert.equal(updateRequired({ MIN_DRIVER_VERSION: "1.8.0" }, "1.8.2"), null);
});

// --- The Worker ------------------------------------------------------------------------------------

test("without a minimum, then with one: old drivers are refused before the home's object; the account says update required", { timeout: STARTUP_MS + 120_000 }, async () => {
  // No minimum: a 1.7.0 driver connects, as every version always has.
  const old = { home: randomHex(16), secret: randomHex(32), claimToken: randomHex(24) };
  const connection = await driver({ home: old.home, secret: old.secret, version: "1.7.0" });
  const keyId = randomHex(4);
  const apiKey = `ak_${randomHex(24)}`;
  connection.on("unknown", (text) => {
    const message = JSON.parse(text);
    if (message.type === "claim") connection.sendJson({ id: message.id, type: "claim_result", ok: message.token === old.claimToken });
  });
  assert.equal((await status(old.home)).version, "1.7.0");
  const dana = await signInAs(worker.http, google, DANA, APP);
  const claimed = await call("POST", "/v1/homes/claim", { cookie: dana, body: { home_id: old.home, claim_token: old.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  await connection.close();
  await eventually(async () => (await status(old.home)).connected === false, "the old driver gone");
  const before = await status(old.home);
  assert.equal(before.update_required, undefined, "no minimum, no update required");
  const homes = await call("GET", "/v1/homes", { cookie: dana });
  assert.equal(homes.json.items.find((item) => item.home_id === old.home).update_required, undefined);
  assert.equal(logged("driver_refused", old.home).length, 0);

  // A deploy with MIN_DRIVER_VERSION=1.8.0.
  await redeploy({ MIN_DRIVER_VERSION: "1.8.0" });

  // Below it: 426 DRIVER_UPDATE_REQUIRED, with the minimum, a 1.7.0 driver's header too.
  const refused = await refusalOf({ home: old.home, secret: old.secret, version: "1.7.0" });
  assert.ok(refused, "1.7.0 is refused");
  assert.equal(refused.status, 426, refused.body);
  assert.match(refused.headers["content-type"] ?? "", /^application\/problem\+json/);
  assert.equal(refused.problem.code, "DRIVER_UPDATE_REQUIRED");
  assert.equal(refused.problem.status, 426);
  assert.equal(refused.problem.minimum_version, "1.8.0");
  assert.match(refused.problem.detail, /1\.7\.0.*1\.8\.0 or later/);
  // The Worker writes its log line as it answers: wait for it rather than read it at once.
  await eventually(() => logged("driver_refused", old.home).length >= 1, "the refusal in the log");
  for (const version of ["1.7.9", "0.9.0-smoke", "dev", "1.8"]) {
    assert.equal((await refusalOf({ home: old.home, secret: old.secret, version }))?.status, 426, version);
  }
  assert.equal((await refusalOf({ home: old.home, secret: old.secret, headers: { "X-DirectorLink-Version": null } }))?.status, 426, "no version at all");

  // Refused in the Worker: the home's object never saw it. A new home's first secret is trusted
  // by its object (trust on first use); one refused first, then another secret: the other is.
  const fresh = randomHex(16);
  assert.equal((await refusalOf({ home: fresh, secret: randomHex(32), version: "1.7.0" }))?.status, 426);
  assert.equal(logged("home_registered", fresh).length, 0, "the object was not asked");
  assert.equal(await refusalOf({ home: fresh, secret: randomHex(32), version: "1.8.0" }), null, "another secret is the first the object sees");
  assert.equal(logged("home_registered", fresh).length, 1);

  // For the account, the home whose last driver is 1.7.0 is "update DirectorLink", not offline.
  const after = await status(old.home);
  assert.equal(after.connected, false);
  assert.equal(after.update_required, true);
  assert.equal(after.minimum_version, "1.8.0");
  const listed = await call("GET", "/v1/homes", { cookie: dana });
  assert.equal(listed.json.items.find((item) => item.home_id === old.home).update_required, true);
  const request = { id: randomHex(8), ts: Math.floor(Date.now() / 1000), method: "GET", path: "/v1/system", body: null };
  const sealed = await call("POST", `/v1/homes/${old.home}/e2e`, { cookie: dana, body: { envelope: seal(lockKey(apiKey), { home: old.home, key: keyId }, "req", JSON.stringify(request)) } });
  assert.equal(sealed.status, 503, sealed.text);
  assert.equal(sealed.json.code, "HOME_UPDATE_REQUIRED");
  assert.match(sealed.json.detail, /1\.7\.0.*1\.8\.0 or later/);

  // At or above it, it connects; updated, the home is itself again.
  for (const version of ["1.8.0", "1.8.0-rc.1", "1.10.2", "2.0.0"]) {
    assert.equal(await refusalOf({ home: randomHex(16), version }), null, version);
  }
  const updated = await driver({ home: old.home, secret: old.secret, version: "1.8.0" });
  const back = await status(old.home);
  assert.equal(back.connected, true);
  assert.equal(back.version, "1.8.0");
  assert.equal(back.update_required, undefined);
  await updated.close();
  await eventually(async () => (await status(old.home)).connected === false, "the 1.8.0 driver gone");
  const away = await status(old.home);
  assert.equal(away.update_required, undefined, "offline, and not too old");
  const offline = await call("POST", `/v1/homes/${old.home}/e2e`, { cookie: dana, body: { envelope: seal(lockKey(apiKey), { home: old.home, key: keyId }, "req", JSON.stringify({ ...request, id: randomHex(8) })) } });
  assert.equal(offline.json.code, "HOME_OFFLINE");
});
