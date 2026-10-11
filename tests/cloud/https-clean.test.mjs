// Direct HTTPS's housekeeping in the Worker (1.13.0, ADR-082 as changed then), end to end under
// `wrangler dev` with a fake Google, a fake ACME server, a fake Cloudflare API and fake controllers.
// The ACME account's URL, for dlhome.cc's CAA record: kept in D1 and said once in the log, learned at
// an order's first step or looked up by the hourly trigger while D1 has none, and read back as the
// integrator reads production's (`wrangler d1 execute`). The daily cleanup of names nobody uses: a
// home gone from D1 loses its name for good; a controller that said off, or has not said it serves
// its name for 30 days, loses the A record and keeps the name; one connected and serving it keeps
// it; at most HTTPS_CLEAN_MAX names a run.
//   node --test tests/cloud/https-clean.test.mjs

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { after, before, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";

import { AcmeClient } from "../../cloud/src/acme.js";
import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { startFakeAcme } from "./fake-acme.mjs";
import { DNS_TOKEN, ZONE_ID, startFakeCloudflare } from "./fake-cloudflare.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";
import { accountKeyLine, keyPair, makeRequest, pem } from "./x509-build.mjs";

const APP = "http://localhost:8080";
const TEST = { timeout: 120_000 };
const DAILY = "17 3 * * *";
const HOURLY = "47 * * * *";
// Each Worker its own ACME account.
const MONTH_KEY = accountKeyLine();
const NOW_KEY = accountKeyLine();

// `month`: production's limits (30 days, 50 names a run). `now`: HTTPS_UNUSED_DAYS 0 (a name its
// controller is not serving right now is unused) and 2 names a run.
let month;
let now;
let google;
let acme;
let cloudflare;
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  cloudflare = await startFakeCloudflare();
  acme = await startFakeAcme({ dns: cloudflare });
  const vars = (key) => ({
    ...googleVars(google, APP, "https://api.directorlink.test"),
    REQUEST_TIMEOUT_MS: 3000,
    // The hourly trigger counts GitHub's downloads too: nowhere to go here.
    GITHUB_API_URL: "http://127.0.0.1:1",
    DLHOME_DNS_TOKEN: DNS_TOKEN,
    DLHOME_ZONE_ID: ZONE_ID,
    DLHOME_DNS_API: cloudflare.api,
    ACME_DIRECTORY: acme.directory,
    ACME_ACCOUNT_KEY: key,
    HTTPS_DNS_WAIT_MS: 50,
    HTTPS_POLL_MS: 50,
    HTTPS_RETRY_MS: "50,50,50,50",
  });
  [month, now] = await Promise.all([
    startWorker({ migrate: true, scheduled: true, devVars: vars(MONTH_KEY) }),
    startWorker({ migrate: true, scheduled: true, devVars: { ...vars(NOW_KEY), HTTPS_UNUSED_DAYS: 0, HTTPS_CLEAN_MAX: 2 } }),
  ]);
}, { timeout: 2 * STARTUP_MS + 10_000 });

after(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
  await month?.stop();
  await now?.stop();
  await acme?.close();
  await cloudflare?.close();
  await google?.close();
});

function newName() {
  const letters = "abcdefghijklmnopqrstuvwxyz234567";
  return `${Array.from({ length: 20 }, () => letters[Math.floor(Math.random() * 32)]).join("")}.dlhome.cc`;
}

// The first message from the relay (since `from`, an index into received) that `match` takes.
async function waitFor(state, match, { from = 0, ms = 10_000 } = {}) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const found = state.received.slice(from).find(match);
    if (found) return found;
    await sleep(20);
  }
  throw new Error(`no such message within ${ms} ms; got ${JSON.stringify(state.received.map((item) => item.type))}`);
}

// A controller (DirectorLink 1.13.0) at a home: it answers claims, pings every 2 s so that the relay
// keeps hearing it, and keeps every message the relay sent.
async function controller(target, state = { home: randomHex(16), secret: randomHex(32), claimToken: randomHex(24) }) {
  const connection = await connectDriver({ url: target.ws, home: state.home, secret: state.secret, pingIntervalMs: 2000, silenceTimeoutMs: 0, hello: false });
  drivers.push(connection);
  state.connection = connection;
  state.received = [];
  connection.on("unknown", (text) => {
    const message = JSON.parse(text);
    state.received.push(message);
    if (message.type === "claim") {
      connection.sendJson({ type: "claim_result", id: message.id, ok: message.token === state.claimToken });
    }
  });
  connection.sendJson({ type: "hello", home: state.home, version: "1.13.0", ping_s: 5, features: ["scene_links", "alerts_gone", "users", "resend", "alert_acks"], instance: randomHex(16) });
  await waitFor(state, (message) => message.type === "relay_features");
  return state;
}

async function call(target, method, apiPath, { cookie, body } = {}) {
  const headers = { Origin: APP };
  if (cookie) headers.Cookie = cookie;
  if (body !== undefined) headers["content-type"] = "application/json";
  const response = await fetch(`${target.http}${apiPath}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await response.text();
  return { status: response.status, json: text ? JSON.parse(text) : null, text };
}

async function claimedController(target) {
  const state = await controller(target);
  const tag = randomHex(4);
  state.cookie = await signInAs(target.http, google, { sub: `google-${tag}`, email: `dana-${tag}@example.com`, name: "Dana" }, APP);
  const claimed = await call(target, "POST", "/v1/homes/claim", { cookie: state.cookie, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  return state;
}

// Sends `message` (with a new id) and waits for its answer of `type`.
async function ask(state, message, type) {
  const id = randomHex(8);
  const from = state.received.length;
  state.connection.sendJson({ ...message, id });
  return waitFor(state, (item) => item.type === type && item.id === id, { from });
}

async function askCertificate(state, name, keys, ip = "192.168.1.201") {
  return ask(state, { type: "https_certificate", name, ip, csr: pem(makeRequest(name, keys), "CERTIFICATE REQUEST") }, "https_certificate_result");
}

// A claimed home whose controller got its certificate: the name's A record at its address.
async function withCertificate(target, ip = "192.168.1.201") {
  const state = await claimedController(target);
  const name = newName();
  const keys = keyPair();
  const pending = await askCertificate(state, name, keys, ip);
  assert.equal(pending.status, "pending", JSON.stringify(pending));
  const issued = await waitFor(state, (item) => item.type === "https_certificate_result" && item.id === pending.id && item.status !== "pending", { ms: 20_000 });
  assert.equal(issued.status, "issued", JSON.stringify(issued));
  assert.equal(cloudflare.find(name, "A").length, 1);
  return { state, name, keys };
}

// The controller goes away (its driver removed, the controller off): the relay sees the close.
async function away(state) {
  await state.connection.close();
  await sleep(1000);
}

// The same home's controller connecting again (a new connection, not yet saying anything).
async function back(target, state) {
  return controller(target, { home: state.home, secret: state.secret, claimToken: state.claimToken });
}

async function eventually(check, what, target) {
  for (let tries = 0; tries < 150; tries += 1) {
    if (check()) return;
    await sleep(100);
  }
  assert.fail(`${what}:\n${target.output()}`);
}

// The Worker's log lines of `event` since the line that names `mark` (output() keeps the last 200
// lines, so lines are found after a mark rather than counted).
function logged(target, event, mark) {
  const lines = target.output().split("\n");
  const from = mark ? lines.findIndex((line) => line.includes(mark)) : -1;
  return lines
    .slice(from + 1)
    .filter((line) => line.includes(`"event":"${event}"`))
    .map((line) => JSON.parse(line.slice(line.indexOf("{"))));
}

// A mark in the Worker's log: wrangler logs the request for its own path.
async function mark(target) {
  const path = `/https-clean-mark-${randomHex(6)}`;
  await (await fetch(`${target.http}${path}`)).body?.cancel();
  await eventually(() => target.output().includes(path), `the mark ${path} in the log`, target);
  return path;
}

// Runs `cron` and, with `event`, waits for its log line, whose fields it returns.
async function trigger(target, cron, event) {
  const since = await mark(target);
  assert.equal((await fetch(`${target.http}/__scheduled?cron=${encodeURIComponent(cron)}`)).status, 200);
  if (!event) return { since };
  await eventually(() => logged(target, event, since).length > 0, `${event} after ${cron}`, target);
  return { since, fields: logged(target, event, since).at(-1) };
}

// The Worker's D1, read as the integrator reads production's (cloud/README.md), --local for --remote.
function d1(target, sql) {
  const run = spawnSync(`npx --yes wrangler@4.143.0 d1 execute directorlink --local --json --command "${sql}"`, {
    cwd: target.dir,
    shell: true,
    windowsHide: true,
    encoding: "utf8",
    env: { ...process.env, WRANGLER_SEND_METRICS: "false", NO_COLOR: "1", FORCE_COLOR: "0", CI: "1" },
    timeout: STARTUP_MS,
  });
  assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}`);
  return JSON.parse(run.stdout)[0].results;
}

// ---- the ACME account's URL ------------------------------------------------------------------------

test("the ACME account's URL: learned at the first order, said once, kept in D1, never looked up again", TEST, async () => {
  // Before any order the key has no account: the hourly look finds none, says nothing, registers nothing.
  const lookups = acme.log.lookups;
  const accounts = acme.log.accounts;
  const before = await trigger(month, HOURLY);
  await eventually(() => acme.log.lookups > lookups, "the hourly look at Let's Encrypt", month);
  await sleep(500);
  assert.equal(logged(month, "acme_account", before.since).length, 0);
  assert.equal(acme.log.accounts, accounts, "no account registered by looking");

  // The first order registers it: said once, with its URL.
  const since = await mark(month);
  await withCertificate(month);
  const said = logged(month, "acme_account", since);
  assert.equal(said.length, 1, month.output());
  assert.match(said[0].account, /^http:\/\/127\.0\.0\.1:\d+\/acct\/\d+$/);
  assert.equal(said[0].directory, acme.directory);
  // Another home's order: the same account, not said again.
  await withCertificate(month);
  assert.equal(logged(month, "acme_account", since).length, 1);

  // Kept: the hourly look reads D1 and asks Let's Encrypt nothing.
  const kept = acme.log.lookups;
  await trigger(month, HOURLY, "stats_counted");
  await sleep(1000);
  assert.equal(acme.log.lookups, kept);
  assert.equal(logged(month, "acme_account", since).length, 1);

  // What the integrator reads for the CAA record.
  const rows = d1(month, "SELECT directory, url FROM acme_accounts");
  assert.deepEqual(rows, [{ directory: acme.directory, url: said[0].account }]);
});

test("an account registered before 1.13.0 (D1 without it) is found by the hourly look, without an order", TEST, async () => {
  // As production's: its account registered by a 1.12.x Worker's order, which D1 never kept.
  const earlier = new AcmeClient({ directoryUrl: acme.directory, accountKey: NOW_KEY.replace(/\\n/g, "\n") });
  const url = await earlier.account();
  const orders = acme.log.orders;
  const { fields } = await trigger(now, HOURLY, "acme_account");
  assert.deepEqual(fields, { event: "acme_account", account: url, directory: acme.directory });
  assert.equal(acme.log.orders, orders, "no order");
  // Once.
  const lookups = acme.log.lookups;
  const again = await trigger(now, HOURLY, "stats_counted");
  await sleep(1000);
  assert.equal(acme.log.lookups, lookups);
  assert.equal(logged(now, "acme_account", again.since).length, 0);
});

// ---- names nobody uses -----------------------------------------------------------------------------

test("a home gone from D1 (its owner's account deleted) loses its name for good", TEST, async () => {
  const { state, name, keys } = await withCertificate(month);
  assert.equal((await call(month, "DELETE", "/v1/me", { cookie: state.cookie })).status, 204);
  const { fields } = await trigger(month, DAILY, "https_names_cleaned");
  assert.ok(fields.names_deleted >= 1, JSON.stringify(fields));
  assert.equal(cloudflare.find(name).length, 0, "no A record");
  // Its object forgot the name too: the controller, still connected, is not claimed any more.
  assert.equal((await ask(state, { type: "https", name, ip: "192.168.1.201" }, "https_result")).code, "NOT_CLAIMED");
  assert.equal((await askCertificate(state, name, keys)).code, "NOT_CLAIMED");
  assert.equal(cloudflare.find(name).length, 0);
  // And D1: another home may have that name now.
  const other = await claimedController(month);
  assert.equal((await askCertificate(other, name, keyPair())).status, "pending");
  // The log has counts, never a name.
  assert.ok(!month.output().split("\n").some((line) => line.includes("https_names_cleaned") && line.includes("dlhome.cc")));
});

test("a home away less than 30 days keeps its A record; one that said off loses it, and keeps its name", TEST, async () => {
  const awayHome = await withCertificate(month);
  await away(awayHome.state);
  // Off while Cloudflare fails: answered DNS_FAILED, the A record still there.
  const offHome = await withCertificate(month, "192.168.1.30");
  cloudflare.state.failNext = 50;
  const off = await ask(offHome.state, { type: "https", name: null }, "https_result");
  cloudflare.state.failNext = 0;
  assert.equal(off.code, "DNS_FAILED");
  assert.equal(cloudflare.find(offHome.name, "A").length, 1);

  const { fields } = await trigger(month, DAILY, "https_names_cleaned");
  assert.ok(fields.records_deleted >= 1, JSON.stringify(fields));
  assert.equal(cloudflare.find(awayHome.name, "A").length, 1, "away for a day only");
  assert.equal(cloudflare.find(offHome.name, "A").length, 0, "it said off");
  // On again: the same name, its certificate given again without an order, the A record back.
  const orders = acme.log.orders;
  const again = await askCertificate(offHome.state, offHome.name, offHome.keys, "192.168.1.30");
  assert.equal(again.status, "issued", JSON.stringify(again));
  assert.equal(acme.log.orders, orders);
  assert.equal(cloudflare.find(offHome.name, "A")[0].content, "192.168.1.30");
});

test("at most HTTPS_CLEAN_MAX names a run; the rest the next day", TEST, async () => {
  const homes = [];
  for (let index = 0; index < 3; index += 1) {
    homes.push(await withCertificate(now));
  }
  for (const home of homes) await away(home.state);
  const first = await trigger(now, DAILY, "https_names_cleaned");
  assert.deepEqual(first.fields, { event: "https_names_cleaned", names_deleted: 0, records_deleted: 2, kept: 0, failed: 0, left: 1 });
  assert.equal(homes.filter((home) => cloudflare.find(home.name, "A").length === 0).length, 2);
  const second = await trigger(now, DAILY, "https_names_cleaned");
  assert.deepEqual(second.fields, { event: "https_names_cleaned", names_deleted: 0, records_deleted: 1, kept: 0, failed: 0, left: 0 });
  assert.equal(homes.filter((home) => cloudflare.find(home.name, "A").length === 0).length, 3);
  // Nothing left to look at: their records are gone, their names stay.
  const third = await trigger(now, DAILY, "https_names_cleaned");
  assert.deepEqual(third.fields, { event: "https_names_cleaned", names_deleted: 0, records_deleted: 0, kept: 0, failed: 0, left: 0 });
});

test("a controller serving its name keeps the A record; one away, or connected without saying so, loses it and gets it back", TEST, async () => {
  // Connected, and it said so on this connection (its certificate request).
  const serving = await withCertificate(now);
  // Away.
  const gone = await withCertificate(now, "192.168.1.40");
  await away(gone.state);
  // Connected again, but not saying it serves the name (a DirectorLink before 1.12.0 after a downgrade).
  const silent = await withCertificate(now, "192.168.1.50");
  await away(silent.state);
  const silentBack = await back(now, silent.state);

  const { fields } = await trigger(now, DAILY, "https_names_cleaned");
  assert.deepEqual(fields, { event: "https_names_cleaned", names_deleted: 0, records_deleted: 2, kept: 1, failed: 0, left: 0 });
  assert.equal(cloudflare.find(serving.name, "A").length, 1, "serving");
  assert.equal(cloudflare.find(gone.name, "A").length, 0, "away");
  assert.equal(cloudflare.find(silent.name, "A").length, 0, "not said on this connection");

  // Back, saying its address: the A record again, under the same name.
  const returned = await back(now, gone.state);
  assert.equal((await ask(returned, { type: "https", name: gone.name, ip: "192.168.1.41" }, "https_result")).ok, true);
  assert.equal(cloudflare.find(gone.name, "A")[0].content, "192.168.1.41");
  assert.equal((await ask(silentBack, { type: "https", name: silent.name, ip: "192.168.1.50" }, "https_result")).ok, true);
  assert.equal(cloudflare.find(silent.name, "A")[0].content, "192.168.1.50");
  // Serving now (with HTTPS_UNUSED_DAYS 0 each is looked at every day): all three kept.
  const next = await trigger(now, DAILY, "https_names_cleaned");
  assert.deepEqual(next.fields, { event: "https_names_cleaned", names_deleted: 0, records_deleted: 0, kept: 3, failed: 0, left: 0 });
  assert.equal(cloudflare.find(gone.name, "A").length, 1);
});
