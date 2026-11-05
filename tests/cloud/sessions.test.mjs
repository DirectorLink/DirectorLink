// Sign-ins that renew while used (cloud/src/accounts.js, 1.13.2, ADR-089), in Node: the account and
// home routes on D1's SQL (node:sqlite with the Worker's own migrations) and a clock the tests move.
// A session used a day or more after its last renewal lasts 30 days from then, and from then on every
// answer that uses it sends its cookie again (the same token, the time it has left), so a lost answer
// costs nothing; D1 is written at most once a day, also for requests at once, and a write D1 refuses
// is skipped; a session nobody uses for 30 days ends, and an expired one stays expired; Sign out
// everywhere and Delete account still end a renewed one; never past a year from the sign-in. The
// same end to end under `wrangler dev`: tests/cloud/accounts.test.mjs.
//   node --test tests/cloud/sessions.test.mjs

import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";

import { SESSION_MAX_SECONDS, SESSION_SECONDS, handleAccounts } from "../../cloud/src/accounts.js";
import { handleHomes } from "../../cloud/src/homes.js";

const APP = "https://app.directorlink.io";
const API = "https://api.directorlink.io";
const MIGRATIONS = new URL("../../cloud/migrations/", import.meta.url);
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const START = Date.parse("2026-10-04T09:00:00.000Z");

// The clock accounts.js reads (Date.now), moved by the tests.
const realNow = Date.now;
let now = START;
Date.now = () => now;
after(() => {
  Date.now = realNow;
});
const iso = (ms) => new Date(ms).toISOString();

// D1 as the Worker uses it (prepare, bind, first, all, run, batch), on SQLite with the migrations.
// `renewals`: the UPDATEs of a session's end sent, and how many rows they changed. `failRenewals`:
// those UPDATEs throw, as when D1 cannot write; `beforeRenewal()`: runs once just before the next
// one (another request's work at that moment).
function fakeD1() {
  const db = new DatabaseSync(":memory:");
  for (const name of readdirSync(MIGRATIONS).filter((file) => file.endsWith(".sql")).sort()) {
    db.exec(readFileSync(new URL(name, MIGRATIONS), "utf8"));
  }
  const d1 = { db, renewals: { sent: 0, changed: 0 }, failRenewals: false, beforeRenewal: null };
  const execute = (sql, values) => {
    if (/^\s*UPDATE sessions SET expires_at\b/i.test(sql)) {
      const before = d1.beforeRenewal;
      d1.beforeRenewal = null;
      before?.();
      if (d1.failRenewals) throw new Error("D1_ERROR: database is read only");
    }
    const statement = db.prepare(sql);
    if (/^\s*SELECT\b/i.test(sql) || /\bRETURNING\b/i.test(sql)) {
      return { results: statement.all(...values), meta: { changes: 0 } };
    }
    const changes = Number(statement.run(...values).changes);
    if (/^\s*UPDATE sessions SET expires_at\b/i.test(sql)) {
      d1.renewals.sent += 1;
      d1.renewals.changed += changes;
    }
    return { results: [], meta: { changes } };
  };
  const prepared = (sql, values = []) => ({
    sql,
    values,
    bind: (...bound) => prepared(sql, bound),
    // Each answer after a turn of the event loop, as D1's do: requests at once interleave.
    first: async () => {
      await new Promise((resolve) => setImmediate(resolve));
      return execute(sql, values).results[0] ?? null;
    },
    all: async () => {
      await new Promise((resolve) => setImmediate(resolve));
      return execute(sql, values);
    },
    run: async () => {
      await new Promise((resolve) => setImmediate(resolve));
      return execute(sql, values);
    },
  });
  d1.prepare = (sql) => prepared(sql);
  d1.batch = async (statements) => {
    db.exec("BEGIN");
    try {
      const results = statements.map((statement) => execute(statement.sql, statement.values));
      db.exec("COMMIT");
      return results;
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  };
  return d1;
}

const sha256 = (text) => createHash("sha256").update(text).digest("hex");

// A signed-in account with sessions, as finishSignIn writes them: `signIn()` adds a device's session
// signed in at `at` (now), ending `lasts` ms later. Returns { cookie, token, hash }.
function account(d1, id = randomBytes(16).toString("hex")) {
  d1.db.prepare("INSERT INTO users (id, provider, subject, email, name, created_at, last_sign_in_at) VALUES (?, 'google', ?, ?, 'Dana', ?, ?)").run(id, `sub-${id}`, `${id}@example.com`, iso(now), iso(now));
  d1.db.prepare("INSERT INTO identities (provider, subject, user_id, email, created_at, last_sign_in_at) VALUES ('google', ?, ?, ?, ?, ?)").run(`sub-${id}`, id, `${id}@example.com`, iso(now), iso(now));
  return {
    id,
    signIn({ at = now, lasts = SESSION_SECONDS * 1000 } = {}) {
      const token = randomBytes(32).toString("base64url");
      const hash = sha256(token);
      d1.db.prepare("INSERT INTO sessions (token_sha256, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)").run(hash, id, iso(at), iso(at + lasts));
      return { token, hash, cookie: `__Host-dl_session=${token}` };
    },
  };
}

const endOf = (d1, session) => d1.db.prepare("SELECT expires_at FROM sessions WHERE token_sha256 = ?").get(session.hash)?.expires_at ?? null;

// A request from the app's page, with the session cookie, to the Worker's account or home routes.
async function call(env, path, session, method = "GET") {
  const request = new Request(`${API}${path}`, { method, headers: { Cookie: session.cookie, Origin: APP } });
  return (await handleAccounts(request, env)) ?? (await handleHomes(request, env, { waitUntil() {} }));
}

// The session cookie an answer sets, as { value, attributes }, or undefined.
function sessionCookie(response) {
  for (const line of response.headers.getSetCookie()) {
    const [pair, ...attributes] = line.split(";").map((part) => part.trim());
    if (pair.startsWith("__Host-dl_session=")) return { value: pair.slice("__Host-dl_session=".length), attributes: attributes.map((part) => part.toLowerCase()) };
  }
  return undefined;
}

function setup() {
  now = START;
  const DB = fakeD1();
  return { DB, env: { DB, APP_ORIGINS: APP } };
}

test("a fresh sign-in is left as it is for a day: no write, and the cookie its page load set is not sent again", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  for (const later of [MINUTE, 6 * HOUR, DAY - MINUTE]) {
    now = START + later;
    const response = await call(env, "/v1/me", session);
    assert.equal(response.status, 200);
    assert.equal(sessionCookie(response), undefined, `${later / HOUR} h after the sign-in`);
  }
  assert.equal(DB.renewals.sent, 0, "not even a write that changes nothing");
  assert.equal(endOf(DB, session), iso(START + SESSION_SECONDS * 1000));
});

test("a session near its end is renewed on use: 30 days from then, and the answer sends the same cookie again", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  // The owner's case: signed in on 2026-10-04, used 25 days later, 5 days before the end.
  now = START + 25 * DAY;
  const response = await call(env, "/v1/me", session);
  assert.equal(response.status, 200);
  assert.equal(endOf(DB, session), iso(now + SESSION_SECONDS * 1000), "D1: 30 days from this use");
  const cookie = sessionCookie(response);
  assert.equal(cookie?.value, session.token, "the same token: nothing else changes");
  for (const attribute of ["path=/", "secure", "httponly", "samesite=strict", `max-age=${SESSION_SECONDS}`]) {
    assert.ok(cookie.attributes.includes(attribute), `${attribute} in ${cookie.attributes.join("; ")}`);
  }
  // The browser keeps a cookie from a CORS answer only when the answer allows credentials.
  assert.equal(response.headers.get("access-control-allow-origin"), APP);
  assert.equal(response.headers.get("access-control-allow-credentials"), "true");
  // Past the sign-in's 30 days, still signed in.
  now = START + 31 * DAY;
  assert.equal((await call(env, "/v1/me", session)).status, 200);
});

test("the home routes renew it too, and every request to them sends the cookie again once renewed", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  now = START + 2 * DAY;
  const response = await call(env, "/v1/homes", session);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { items: [] });
  assert.equal(sessionCookie(response)?.value, session.token);
  assert.ok(sessionCookie(response).attributes.includes(`max-age=${SESSION_SECONDS}`));
  assert.equal(response.headers.get("access-control-allow-credentials"), "true");
  assert.equal(endOf(DB, session), iso(now + SESSION_SECONDS * 1000));
  // A refusal of the home route renews as well (it used the session).
  now += DAY;
  const refused = await call(env, `/v1/homes/${"ab".repeat(16)}/members`, session);
  assert.equal(refused.status, 403);
  assert.equal(sessionCookie(refused)?.value, session.token);
});

const maxAgeOf = (response) => Number(sessionCookie(response)?.attributes.find((attribute) => attribute.startsWith("max-age="))?.slice(8));

test("renewed at most once a day, also when the app's requests come at once; every answer has the new end", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  now = START + DAY + MINUTE;
  // Starting away from home the app sends a dozen requests together: one write changes the session;
  // the others' writes change nothing, and they read the end it wrote. Every answer sends it.
  const answers = await Promise.all(Array.from({ length: 6 }, (_, index) => call(env, index % 2 ? "/v1/me" : "/v1/homes", session)));
  assert.deepEqual(answers.map((answer) => answer.status), Array(6).fill(200));
  assert.equal(DB.renewals.changed, 1, "one D1 write changed it");
  assert.equal(endOf(DB, session), iso(now + SESSION_SECONDS * 1000));
  for (const answer of answers) {
    assert.equal(sessionCookie(answer)?.value, session.token);
    assert.equal(maxAgeOf(answer), SESSION_SECONDS, "the new end, never the old one");
  }

  // The rest of that day: nothing written, and each answer sends the cookie with the time left.
  const sent = DB.renewals.sent;
  for (const later of [HOUR, 12 * HOUR, DAY - 2 * MINUTE]) {
    now = START + DAY + MINUTE + later;
    const answer = await call(env, "/v1/me", session);
    assert.equal(sessionCookie(answer)?.value, session.token);
    assert.equal(maxAgeOf(answer), SESSION_SECONDS - later / 1000);
  }
  assert.equal(DB.renewals.sent, sent, "no write at all within the day");

  // The next day, once.
  now = START + 2 * DAY + 2 * MINUTE;
  assert.equal(maxAgeOf(await call(env, "/v1/homes", session)), SESSION_SECONDS);
  assert.equal(maxAgeOf(await call(env, "/v1/homes", session)), SESSION_SECONDS);
  assert.equal(DB.renewals.changed, 2);
});

test("an answer that was lost costs nothing: the next one that uses the session carries its cookie", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  // Renewed by a request whose answer never reached the browser (a dropped connection, an error).
  now = START + 3 * DAY;
  await call(env, "/v1/me", session);
  const end = Date.parse(endOf(DB, session));
  // Hours later the browser still holds the old cookie; the next answer sends the new end.
  now += 5 * HOUR;
  const sent = DB.renewals.sent;
  const answer = await call(env, "/v1/homes", session);
  assert.equal(sessionCookie(answer)?.value, session.token);
  assert.equal(maxAgeOf(answer) * 1000, end - now, "the time the session has left");
  assert.equal(DB.renewals.sent, sent, "without writing");
});

test("a renewal D1 cannot write is skipped: the request is answered, the log says so without the token, and the next use renews it", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  now = START + 20 * DAY;
  DB.failRenewals = true;
  const lines = [];
  const consoleLog = console.log;
  console.log = (line) => lines.push(String(line));
  let response;
  let homes;
  try {
    response = await call(env, "/v1/me", session);
    homes = await call(env, "/v1/homes", session);
  } finally {
    console.log = consoleLog;
  }
  assert.equal(response.status, 200, "signed in as before");
  assert.equal(homes.status, 200, "the home routes too");
  assert.equal(sessionCookie(response), undefined, "nothing renewed, nothing to send");
  assert.equal(endOf(DB, session), iso(START + SESSION_SECONDS * 1000));
  const logged = lines.map((line) => JSON.parse(line)).filter((line) => line.event === "session_not_renewed");
  assert.equal(logged.length, 2, lines.join("\n"));
  assert.match(logged[0].error, /read only/);
  for (const secret of [session.token, session.hash, "@example.com"]) {
    assert.ok(!lines.join("\n").includes(secret), "no token, no email");
  }

  // D1 writes again: the next use renews it.
  DB.failRenewals = false;
  now += HOUR;
  assert.equal(maxAgeOf(await call(env, "/v1/me", session)), SESSION_SECONDS);
  assert.equal(endOf(DB, session), iso(now + SESSION_SECONDS * 1000));
});

test("a session ended while a request renewed it: its answer sends no cookie", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  now = START + 4 * DAY;
  // Sign out everywhere on another device, between this request's read and its write.
  DB.beforeRenewal = () => DB.db.prepare("DELETE FROM sessions WHERE token_sha256 = ?").run(session.hash);
  const response = await call(env, "/v1/me", session);
  assert.equal(sessionCookie(response), undefined);
  assert.equal(endOf(DB, session), null);
  assert.equal((await call(env, "/v1/me", session)).status, 401);
});

test("used every few days it never ends; left unused for 30 days it does, and stays ended", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn();
  // Two months, every third day: always signed in, and the cookie's Max-Age is D1's end each time.
  for (let day = 3; day <= 60; day += 3) {
    now = START + day * DAY;
    const response = await call(env, "/v1/me", session);
    assert.equal(response.status, 200, `day ${day}`);
    const maxAge = sessionCookie(response).attributes.find((attribute) => attribute.startsWith("max-age="));
    assert.equal(Number(maxAge.slice(8)) * 1000, Date.parse(endOf(DB, session)) - now, `day ${day}: the cookie ends when D1 does`);
  }
  // A phone left in a drawer: 30 days after its last use it is signed out, as before.
  const end = Date.parse(endOf(DB, session));
  now = end + MINUTE;
  const response = await call(env, "/v1/me", session);
  assert.equal(response.status, 401);
  assert.equal((await response.json()).code, "NOT_SIGNED_IN");
  assert.equal(sessionCookie(response), undefined, "nothing renewed");
  assert.equal(endOf(DB, session), iso(end), "an expired session is not renewed");
  now += DAY;
  assert.equal((await call(env, "/v1/homes", session)).status, 401, "and stays expired");
  assert.equal(endOf(DB, session), iso(end));
});

test("an expired session stays expired, whatever route it is used on", async () => {
  const { DB, env } = setup();
  const session = account(DB).signIn({ at: START - 31 * DAY });
  const sent = DB.renewals.sent;
  for (const path of ["/v1/me", "/v1/homes"]) {
    const response = await call(env, path, session);
    assert.equal(response.status, 401, path);
    assert.equal(sessionCookie(response), undefined, path);
  }
  assert.equal(DB.renewals.sent, sent, "no write");
  assert.equal(endOf(DB, session), iso(START - DAY));
});

test("Sign out everywhere ends a renewed session; Delete account sends only the cookie that clears it", async () => {
  const { DB, env } = setup();
  const dana = account(DB);
  const phone = dana.signIn();
  const laptop = dana.signIn();
  now = START + 10 * DAY;
  assert.ok(sessionCookie(await call(env, "/v1/me", phone)), "the phone's session was renewed");
  // From the laptop, every device of the account is signed out.
  const out = await call(env, "/auth/logout?everywhere=1", laptop, "POST");
  assert.equal(out.status, 204);
  assert.equal(sessionCookie(out)?.value, "", "the laptop's cookie is cleared");
  for (const session of [phone, laptop]) {
    assert.equal((await call(env, "/v1/me", session)).status, 401);
    assert.equal(endOf(DB, session), null, "gone from D1");
  }

  // Deleting the account with a session due for renewal: its answer clears the cookie, and only that.
  const avi = account(DB);
  const tablet = avi.signIn();
  now += 5 * DAY;
  const deleted = await call(env, "/v1/me", tablet, "DELETE");
  assert.equal(deleted.status, 204);
  assert.equal(deleted.headers.getSetCookie().filter((line) => line.startsWith("__Host-dl_session=")).length, 1);
  assert.equal(sessionCookie(deleted).value, "");
  assert.ok(sessionCookie(deleted).attributes.includes("max-age=0"));
  assert.equal((await call(env, "/v1/me", tablet)).status, 401);
});

test("never past a year from the sign-in: the last renewal reaches that day, then a sign-in is needed", async () => {
  const { DB, env } = setup();
  const dana = account(DB);
  const year = SESSION_MAX_SECONDS * 1000;
  // Signed in 350 days ago, used 28 days ago: renewed to the year's end, not 30 days on.
  const session = dana.signIn({ at: START - 350 * DAY, lasts: 352 * DAY });
  const cap = START - 350 * DAY + year;
  const response = await call(env, "/v1/me", session);
  assert.equal(response.status, 200);
  assert.equal(endOf(DB, session), iso(cap));
  assert.ok(sessionCookie(response).attributes.includes(`max-age=${Math.floor((cap - now) / 1000)}`));
  // At the cap nothing more is written, and after it the session has ended.
  const sent = DB.renewals.sent;
  now = cap - HOUR;
  assert.equal(maxAgeOf(await call(env, "/v1/me", session)), HOUR / 1000, "the cookie ends with it");
  assert.equal(DB.renewals.sent, sent);
  now = cap + MINUTE;
  assert.equal((await call(env, "/v1/me", session)).status, 401);

  // Less than a day short of the cap, it is still renewed, to the cap exactly.
  now = START;
  const late = dana.signIn({ at: START - year + 20 * HOUR, lasts: year - 10 * HOUR });
  const lateCap = START + 20 * HOUR;
  assert.equal(endOf(DB, late), iso(START + 10 * HOUR));
  assert.equal(sessionCookie(await call(env, "/v1/me", late))?.value, late.token);
  assert.equal(endOf(DB, late), iso(lateCap));
});
