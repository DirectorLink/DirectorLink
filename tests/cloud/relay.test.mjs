// The relay (cloud/) end to end: `wrangler dev --local` runs it (worker.mjs), scripts/relay_smoke.mjs
// plays the driver and calls the test endpoints.
//   node --test tests/cloud/relay.test.mjs
// Its .dev.vars set TEST_TOKEN, and REQUEST_TIMEOUT_MS and RECONNECT_WAIT_MS so the 504 case and
// the wait for a reconnecting driver are quick.

import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { appendFileSync } from "node:fs";
import path from "node:path";
import { after, afterEach, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { HandshakeError, callTestEndpoint, connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const TOKEN = `test-${randomHex(16)}`;
const TIMEOUT_MS = 1500; // REQUEST_TIMEOUT_MS for this run (the default is 15000)
const RECONNECT_WAIT_MS = 2000; // RECONNECT_WAIT_MS for this run (the default is 8000)
const TEST = { timeout: 30_000 };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

let relay;
const drivers = [];

before(async () => {
  relay = await startWorker({ devVars: { TEST_TOKEN: TOKEN, REQUEST_TIMEOUT_MS: TIMEOUT_MS, RECONNECT_WAIT_MS } });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await relay?.stop();
});

afterEach(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
});

// --- Helpers ---------------------------------------------------------------------------------------

function newHome() {
  return { home: randomHex(16), secret: randomHex(32) };
}

async function driver(options) {
  const connection = await connectDriver({ url: relay.ws, pingIntervalMs: 0, silenceTimeoutMs: 0, ...options });
  drivers.push(connection);
  return connection;
}

function call(home, apiPath, options = {}) {
  return callTestEndpoint({ url: relay.http, token: TOKEN, home, path: apiPath, ...options });
}

async function status(home) {
  const result = await call(home, "/status");
  assert.equal(result.status, 200, result.text);
  assert.match(result.contentType, /^application\/json/);
  assert.deepEqual(Object.keys(result.json).sort(), ["connected", "last_seen", "since", "version"]);
  return result.json;
}

async function eventually(check, what, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = await check();
    if (value) {
      return value;
    }
    if (Date.now() > deadline) {
      throw new Error(`timed out waiting for ${what}`);
    }
    await sleep(50);
  }
}

function within(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`timed out after ${ms} ms waiting for ${what}`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function assertProblem(result, statusCode, code) {
  assert.equal(result.status, statusCode, result.text);
  assert.match(result.contentType, /^application\/problem\+json/);
  assert.equal(result.json.type, "about:blank");
  assert.equal(result.json.status, statusCode);
  assert.equal(result.json.code, code);
  assert.equal(typeof result.json.title, "string");
  assert.equal(typeof result.json.detail, "string");
}

function assertRefused(statusCode, code) {
  return (error) => {
    assert.ok(error instanceof HandshakeError, String(error));
    assert.equal(error.status, statusCode, error.body);
    assert.match(error.headers["content-type"] ?? "", /^application\/problem\+json/);
    assert.equal(error.problem?.code, code, error.body);
    assert.equal(error.problem?.status, statusCode);
    return true;
  };
}

// The relay's log lines (one JSON object each) of `event` for `home`, oldest first.
function logged(event, home) {
  return relay
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

function isoTime(value) {
  assert.equal(typeof value, "string");
  assert.equal(new Date(value).toISOString(), value);
  return Date.parse(value);
}

// --- Tests ------------------------------------------------------------------------------------------

test("GET /health answers ok without a token", TEST, async () => {
  const response = await fetch(`${relay.http}/health`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /^application\/json/);
  assert.deepEqual(await response.json(), { status: "ok" });
});

test("unknown paths are 404 problems", TEST, async () => {
  for (const url of [`${relay.http}/`, `${relay.http}/v1/lights`, `${relay.http}/relay`, `${relay.http}/test/homes/${randomHex(16)}/lights`]) {
    const response = await fetch(url, { headers: { Authorization: `Bearer ${TOKEN}` } });
    assert.equal(response.status, 404, url);
    assert.match(response.headers.get("content-type"), /^application\/problem\+json/);
    assert.equal((await response.json()).code, "NOT_FOUND");
  }
});

test("malformed connect requests are refused with 400", TEST, async () => {
  const { home, secret } = newHome();
  const plain = await fetch(`${relay.http}/relay/connect`, { headers: { Authorization: `Bearer ${secret}`, "X-DirectorLink-Home": home } });
  assert.equal(plain.status, 400);
  assert.equal((await plain.json()).code, "WEBSOCKET_REQUIRED");

  const cases = [
    [{ "X-DirectorLink-Home": null }, "INVALID_HOME_ID"],
    [{ "X-DirectorLink-Home": home.toUpperCase() }, "INVALID_HOME_ID"],
    [{ "X-DirectorLink-Home": home.slice(1) }, "INVALID_HOME_ID"],
    [{ Authorization: null }, "INVALID_HOME_SECRET"],
    [{ Authorization: `Bearer ${secret.slice(2)}` }, "INVALID_HOME_SECRET"],
    [{ Authorization: `Basic ${secret}` }, "INVALID_HOME_SECRET"],
  ];
  for (const [headers, code] of cases) {
    await assert.rejects(connectDriver({ url: relay.ws, home, secret, headers }), assertRefused(400, code), JSON.stringify(headers));
  }
  // None of that registered the home.
  assert.deepEqual(await status(home), { connected: false, since: null, version: null, last_seen: null });
});

test("the driver connects, says hello and shows as connected", TEST, async () => {
  const { home, secret } = newHome();
  const started = Date.now();
  await driver({ home, secret, version: "0.9.0", helloVersion: "0.9.1-hello" });
  // Connected with the version of X-DirectorLink-Version, then the hello's.
  const current = await eventually(async () => {
    const value = await status(home);
    return value.version === "0.9.1-hello" ? value : null;
  }, "the hello's version in the status");
  assert.equal(current.connected, true);
  const since = isoTime(current.since);
  assert.ok(Math.abs(since - started) < 5000, `since ${current.since}`);
  assert.ok(isoTime(current.last_seen) >= since);
});

test("ping is answered pong without waking the object, and counts as last seen", TEST, async () => {
  const { home, secret } = newHome();
  const connection = await driver({ home, secret, helloVersion: "0.9.0-hello" });
  const before = await eventually(async () => {
    const value = await status(home);
    return value.version === "0.9.0-hello" ? value : null;
  }, "the hello");
  await sleep(1100);
  const pong = once(connection, "pong");
  connection.ping();
  // Only the runtime's auto-response answers "ping": the object's own code ignores it.
  await within(pong, 5000, "pong");
  const later = await status(home);
  assert.equal(later.connected, true);
  assert.ok(isoTime(later.last_seen) > isoTime(before.last_seen), `last_seen ${before.last_seen} -> ${later.last_seen}`);
  assert.equal(later.since, before.since);
});

test("a relayed GET reaches the driver with its exact path and returns its answer", TEST, async () => {
  const { home, secret } = newHome();
  const seen = [];
  await driver({
    home,
    secret,
    onRequest: (request) => {
      seen.push(request);
      return { status: 200, content_type: "application/json; charset=utf-8", body: JSON.stringify({ lights: [], path: request.path }) };
    },
  });
  const result = await call(home, "/v1/lights?x=1");
  assert.equal(result.status, 200, result.text);
  assert.equal(result.contentType, "application/json; charset=utf-8");
  assert.equal(result.headers.get("cache-control"), "no-store");
  assert.equal(result.text, JSON.stringify({ lights: [], path: "/v1/lights?x=1" }));

  assert.equal(seen.length, 1);
  const [request] = seen;
  assert.deepEqual(Object.keys(request), ["type", "id", "method", "path", "body"]);
  assert.equal(request.type, "request");
  assert.match(request.id, UUID);
  assert.equal(request.method, "GET");
  assert.equal(request.path, "/v1/lights?x=1");
  assert.equal(request.body, null);

  // Percent-encoded parts arrive as sent, and every request gets its own id.
  const encoded = await call(home, "/v1/rooms/%D7%A1%D7%9C%D7%95%D7%9F?name=a%20b&room_id=10");
  assert.equal(encoded.status, 200);
  assert.equal(seen[1].path, "/v1/rooms/%D7%A1%D7%9C%D7%95%D7%9F?name=a%20b&room_id=10");
  assert.notEqual(seen[1].id, seen[0].id);
});

test("the driver's status, content type and problem body pass through", TEST, async () => {
  const { home, secret } = newHome();
  const problemBody = JSON.stringify({ type: "about:blank", title: "Not Found", status: 404, code: "NOT_FOUND", detail: "Light 999 does not exist" });
  await driver({
    home,
    secret,
    onRequest: (request) => {
      if (request.path === "/v1/lights/999") {
        return { status: 404, content_type: "application/problem+json", body: problemBody };
      }
      if (request.path === "/v1/empty") {
        return { status: 204, content_type: "text/plain", body: null };
      }
      return { status: 202, content_type: "text/plain; charset=utf-8", body: "accepted" };
    },
  });
  const missing = await call(home, "/v1/lights/999");
  assert.equal(missing.status, 404);
  assert.equal(missing.contentType, "application/problem+json");
  assert.equal(missing.text, problemBody);

  const accepted = await call(home, "/v1/other");
  assert.equal(accepted.status, 202);
  assert.equal(accepted.contentType, "text/plain; charset=utf-8");
  assert.equal(accepted.text, "accepted");

  const empty = await call(home, "/v1/empty");
  assert.equal(empty.status, 204);
  assert.equal(empty.body.length, 0);
});

test("binary answers travel as body_base64 and arrive byte for byte", TEST, async () => {
  const { home, secret } = newHome();
  const bytes = Buffer.concat([Buffer.from(Array.from({ length: 256 }, (_, i) => i)), randomBytes(100_000)]);
  const base64 = bytes.toString("base64");
  // Line-wrapped base64 (MIME: 76 characters and CRLF; OpenSSL: 64 and LF) decodes the same.
  const wrapped = { "/v1/mime": base64.replace(/.{76}/g, "$&\r\n"), "/v1/openssl": base64.replace(/.{64}/g, "$&\n") };
  await driver({
    home,
    secret,
    onRequest: (request) => ({ status: 200, content_type: "image/jpeg", body_base64: wrapped[request.path] ?? base64 }),
  });
  for (const apiPath of ["/v1/cameras/12/snapshot", "/v1/mime", "/v1/openssl"]) {
    const result = await call(home, apiPath);
    assert.equal(result.status, 200, `${apiPath}: ${result.text.slice(0, 200)}`);
    assert.equal(result.contentType, "image/jpeg");
    assert.equal(result.headers.get("cache-control"), "no-store");
    assert.ok(result.body.equals(bytes), `${apiPath}: got ${result.body.length} bytes, expected ${bytes.length}`);
  }
});

test("an answer the driver sends in fragments is reassembled", TEST, async () => {
  const { home, secret } = newHome();
  const body = JSON.stringify({ rooms: [{ id: 10, name: "סלון" }, { id: 11, name: "מטבח" }], note: "x".repeat(300) });
  await driver({
    home,
    secret,
    onRequest: (request, connection) => {
      // 7-byte fragments also split the Hebrew letters' UTF-8 bytes.
      connection.respond(request.id, { status: 200, content_type: "application/json; charset=utf-8", body }, { fragmentSize: 7 });
      return null;
    },
  });
  const result = await call(home, "/v1/rooms");
  assert.equal(result.status, 200, result.text);
  assert.equal(result.text, body);
});

test("the driver's invalid answers become 502 INVALID_RESPONSE", TEST, async () => {
  const { home, secret } = newHome();
  await driver({
    home,
    secret,
    onRequest: (request) => {
      switch (request.path) {
        case "/v1/bad-status":
          return { status: 99, body: "" };
        case "/v1/bad-body":
          return { status: 200, body: { not: "text" } };
        default:
          return { status: 200, content_type: "image/jpeg", body_base64: "not base64!" };
      }
    },
  });
  for (const apiPath of ["/v1/bad-status", "/v1/bad-body", "/v1/bad-base64"]) {
    assertProblem(await call(home, apiPath), 502, "INVALID_RESPONSE");
  }
});

test("a wrong secret for a known home is refused with 401 and the connected driver stays", TEST, async () => {
  const { home, secret } = newHome();
  const first = await driver({ home, secret, onRequest: (request) => ({ status: 200, body: JSON.stringify({ path: request.path }) }) });
  await assert.rejects(connectDriver({ url: relay.ws, home, secret: randomHex(32) }), assertRefused(401, "WRONG_HOME_SECRET"));
  await sleep(200);
  assert.equal(first.isOpen, true);
  assert.equal((await status(home)).connected, true);
  const result = await call(home, "/v1/system");
  assert.equal(result.status, 200);

  // The secret is compared without regard to hex case; any other secret stays refused.
  const again = await driver({ home, secret: secret.toUpperCase() });
  assert.equal(again.isOpen, true);
  await assert.rejects(connectDriver({ url: relay.ws, home, secret: randomHex(32) }), assertRefused(401, "WRONG_HOME_SECRET"));
});

test("a second connection replaces the first, which is closed with 4000 replaced", TEST, async () => {
  const { home, secret } = newHome();
  const seen = { first: [], second: [] };
  const answer = (name) => (request) => {
    seen[name].push(request.path);
    return { status: 200, body: JSON.stringify({ by: name }) };
  };
  const first = await driver({ home, secret, onRequest: answer("first") });
  const firstStatus = await status(home);
  await sleep(50);
  await driver({ home, secret, version: "0.9.0-second", onRequest: answer("second") });

  const closed = await within(first.closed, 5000, "the first connection to be closed");
  assert.deepEqual(closed, { code: 4000, reason: "replaced", by: "server" });

  const result = await call(home, "/v1/system");
  assert.equal(result.status, 200);
  assert.deepEqual(result.json, { by: "second" });
  assert.deepEqual(seen, { first: [], second: ["/v1/system"] });

  // The replaced socket's close must not make the home look offline.
  await sleep(300);
  const current = await status(home);
  assert.equal(current.connected, true);
  assert.equal(current.version, "0.9.0-second");
  assert.ok(isoTime(current.since) >= isoTime(firstStatus.since));
});

test("the test endpoints need the token", TEST, async () => {
  const { home } = newHome();
  for (const apiPath of ["/status", "/v1/lights"]) {
    for (const token of [undefined, "wrong", `${TOKEN}x`, TOKEN.slice(0, -1)]) {
      const result = await callTestEndpoint({ url: relay.http, token, home, path: apiPath });
      assertProblem(result, 401, "UNAUTHORIZED");
      assert.match(result.headers.get("www-authenticate") ?? "", /^Bearer/);
    }
    const basic = await callTestEndpoint({ url: relay.http, home, path: apiPath, headers: { Authorization: `Basic ${TOKEN}` } });
    assertProblem(basic, 401, "UNAUTHORIZED");
  }
});

test("only GET is allowed on the test endpoints", TEST, async () => {
  const { home, secret } = newHome();
  const seen = [];
  await driver({
    home,
    secret,
    onRequest: (request) => {
      seen.push(request);
      return { status: 200, body: "{}" };
    },
  });
  for (const method of ["POST", "PUT", "PATCH", "DELETE"]) {
    for (const apiPath of ["/v1/lights/259", "/status"]) {
      const result = await call(home, apiPath, { method });
      assertProblem(result, 405, "METHOD_NOT_ALLOWED");
      assert.equal(result.headers.get("allow"), "GET");
    }
  }
  assert.equal(seen.length, 0);
});

test("a home without a driver answers 503 HOME_OFFLINE", TEST, async () => {
  const { home } = newHome();
  assertProblem(await call(home, "/v1/lights"), 503, "HOME_OFFLINE");
  assert.deepEqual(await status(home), { connected: false, since: null, version: null, last_seen: null });
  assertProblem(await call("NOT-A-HOME", "/status"), 400, "INVALID_HOME_ID");
  assertProblem(await call(home.toUpperCase(), "/v1/lights"), 400, "INVALID_HOME_ID");
});

test("a driver that answers too late gets the caller a 504, and the late answer is dropped", TEST, async () => {
  const { home, secret } = newHome();
  const late = [];
  await driver({
    home,
    secret,
    onRequest: async (request) => {
      if (request.path === "/v1/slow") {
        await sleep(TIMEOUT_MS + 700);
        late.push(request.id);
      }
      return { status: 200, body: JSON.stringify({ path: request.path }) };
    },
  });
  const started = Date.now();
  const slow = await call(home, "/v1/slow");
  const elapsed = Date.now() - started;
  assertProblem(slow, 504, "HOME_TIMEOUT");
  assert.ok(elapsed >= TIMEOUT_MS - 100 && elapsed < TIMEOUT_MS + 5000, `answered after ${elapsed} ms`);

  await eventually(() => late.length === 1, "the late answer to be sent");
  await sleep(100);
  const fast = await call(home, "/v1/fast");
  assert.equal(fast.status, 200, fast.text);
  assert.deepEqual(fast.json, { path: "/v1/fast" });
});

test("a driver that disconnects while a request waits gets the caller a 502; the home shows offline", TEST, async () => {
  const { home, secret } = newHome();
  const started = Date.now();
  await driver({
    home,
    secret,
    version: "0.9.0",
    onRequest: (request, connection) => {
      connection.close(1001, "going away");
      return null;
    },
  });
  assertProblem(await call(home, "/v1/lights"), 502, "HOME_DISCONNECTED");

  const offline = await eventually(async () => {
    const value = await status(home);
    return value.connected ? null : value;
  }, "the home to show offline");
  assert.equal(offline.version, "0.9.0");
  assert.ok(isoTime(offline.since) >= started - 1000);
  assert.ok(isoTime(offline.last_seen) >= started - 1000);
  assertProblem(await call(home, "/v1/lights"), 503, "HOME_OFFLINE");
});

// The driver's connection is cut without a closing handshake (1006), as on real controllers, and
// the driver connects again within seconds: what is asked meanwhile waits for it.
test("a request made while the driver reconnects waits for it and goes through", TEST, async () => {
  const { home, secret } = newHome();
  const first = await driver({ home, secret, onRequest: () => ({ status: 200, body: JSON.stringify({ by: "first" }) }) });
  first.destroy();
  await eventually(async () => !(await status(home)).connected, "the home to show offline");
  const disconnected = await eventually(() => logged("driver_disconnected", home)[0], "the disconnect in the log");
  assert.match(disconnected.why, /^closed with 1006/);
  assert.equal(typeof disconnected.up_s, "number");
  assert.equal(disconnected.ping_s, null, "this driver never pinged");
  assert.equal(typeof disconnected.message_s, "number");

  const started = Date.now();
  const pending = call(home, "/v1/system");
  await sleep(500);
  await driver({ home, secret, onRequest: () => ({ status: 200, body: JSON.stringify({ by: "second" }) }) });
  const result = await pending;
  const waited = Date.now() - started;
  assert.equal(result.status, 200, result.text);
  assert.deepEqual(result.json, { by: "second" });
  assert.ok(waited >= 500 && waited < RECONNECT_WAIT_MS + 1000, `answered after ${waited} ms`);
  const connected = logged("driver_connected", home);
  assert.equal(connected.length, 2);
  assert.equal(typeof connected[1].down_ms, "number", "how long the home was away");
  assert.equal(connected[0].down_ms, null, "a first connection was never away");
});

test("a driver that does not come back gets the caller a 503 after the wait", TEST, async () => {
  const { home, secret } = newHome();
  const connection = await driver({ home, secret });
  connection.ping();
  await within(once(connection, "pong"), 5000, "pong");
  connection.destroy();
  await eventually(async () => !(await status(home)).connected, "the home to show offline");
  const disconnected = await eventually(() => logged("driver_disconnected", home)[0], "the disconnect in the log");
  assert.equal(typeof disconnected.ping_s, "number", "seconds since its last ping was answered");

  const started = Date.now();
  assertProblem(await call(home, "/v1/lights"), 503, "HOME_OFFLINE");
  const waited = Date.now() - started;
  assert.ok(waited >= RECONNECT_WAIT_MS - 100 && waited < RECONNECT_WAIT_MS + 3000, `answered after ${waited} ms`);
});

// The driver connects again while the relay still holds its old connection, which went dead
// without a close (the relay's close 4000 is never answered): what was sent over it fails at once.
test("requests sent over a connection the driver has replaced fail at once", TEST, async () => {
  const { home, secret } = newHome();
  let reached = null;
  const first = await driver({
    home,
    secret,
    onRequest: (request, connection) => {
      connection.socket.pause();
      reached = request.id;
      return null;
    },
  });
  const started = Date.now();
  const pending = call(home, "/v1/lights");
  await eventually(() => reached, "the request to reach the first connection");
  await driver({ home, secret, onRequest: () => ({ status: 200, body: JSON.stringify({ by: "second" }) }) });
  assertProblem(await pending, 502, "HOME_DISCONNECTED");
  const elapsed = Date.now() - started;
  assert.ok(elapsed < TIMEOUT_MS, `answered after ${elapsed} ms, not at the ${TIMEOUT_MS} ms timeout`);
  const next = await call(home, "/v1/system");
  assert.equal(next.status, 200, next.text);
  assert.deepEqual(next.json, { by: "second" });
  first.destroy();
});

// A deploy restarts every Durable Object and ends its sockets without webSocketClose, so no
// disconnect is recorded; the drivers come back within seconds. wrangler dev does the same when
// the Worker's code changes. Last in this file: it drops every connection.
test("after the relay restarts, a request waits for the driver to come back", { timeout: 90_000 }, async () => {
  const back = newHome();
  const gone = newHome();
  const first = await driver({ ...back, onRequest: () => ({ status: 200, body: JSON.stringify({ by: "first" }) }) });
  const other = await driver({ ...gone });
  await eventually(async () => (await status(gone.home)).connected, "both homes connected");

  appendFileSync(path.join(relay.dir, "src", "index.js"), `\n// reloaded by the tests ${Date.now()}\n`);
  await within(Promise.all([first.closed, other.closed]), 60_000, "the restart to end the connections");
  await eventually(async () => {
    try {
      return (await fetch(`${relay.http}/health`)).ok;
    } catch {
      return false;
    }
  }, "the relay to answer again", 60_000);

  const pending = call(back.home, "/v1/system");
  await sleep(500);
  await driver({ ...back, onRequest: () => ({ status: 200, body: JSON.stringify({ by: "after the restart" }) }) });
  const result = await pending;
  assert.equal(result.status, 200, result.text);
  assert.deepEqual(result.json, { by: "after the restart" });

  // The other home does not come back: one request waits, the next is answered at once.
  const started = Date.now();
  assertProblem(await call(gone.home, "/v1/lights"), 503, "HOME_OFFLINE");
  assert.ok(Date.now() - started >= RECONNECT_WAIT_MS - 100, "the first request waited");
  const again = Date.now();
  assertProblem(await call(gone.home, "/v1/lights"), 503, "HOME_OFFLINE");
  assert.ok(Date.now() - again < 1000, "the next one did not");
  const offline = await status(gone.home);
  assert.equal(offline.connected, false);
  assert.ok(isoTime(offline.since) <= started, `offline since ${offline.since}`);
});
