// Automatic backups in the account (cloud/src/backups.js, ADR-048): a fake controller sends a
// sealed backup over its relay connection in chunks, each answered before the next; the home's
// owner lists and downloads them; the Worker under `wrangler dev`, with a fake Google.
//   node --test tests/cloud/backups.test.mjs

import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { after, afterEach, before, test } from "node:test";

import { KEEP, MAX_HOME_BYTES, toPrune } from "../../cloud/src/backups.js";
import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { invitationKey, open, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TEST = { timeout: 60_000 };
const DANA = { sub: "google-dana-b", email: "dana.b@example.com", name: "Dana" };
const AVI = { sub: "google-avi-b", email: "avi.b@example.com", name: "Avi" };
const NOA = { sub: "google-noa-b", email: "noa.b@example.com", name: "Noa" };

let worker;
let google;
const drivers = [];

before(async () => {
  google = await startFakeGoogle();
  worker = await startWorker({ migrate: true, devVars: { ...googleVars(google, APP, "https://api.directorlink.test"), REQUEST_TIMEOUT_MS: 3000 } });
}, { timeout: STARTUP_MS + 10_000 });

after(async () => {
  await worker?.stop();
  await google?.close();
});

afterEach(async () => {
  await Promise.all(drivers.splice(0).map((connection) => connection.close()));
});

const nowSeconds = () => Math.floor(Date.now() / 1000);

// A controller: answers claims and joins, and collects what the relay sends it.
async function home() {
  const state = { home: randomHex(16), claimToken: randomHex(24), invitations: new Map(), seen: [] };
  const connection = await connectDriver({ url: worker.ws, home: state.home, pingIntervalMs: 0, silenceTimeoutMs: 0 });
  drivers.push(connection);
  state.connection = connection;
  connection.on("unknown", (text) => {
    const message = JSON.parse(text);
    state.seen.push(message);
    const reply = (fields) => connection.sendJson({ id: message.id, ...fields });
    if (message.type === "claim") {
      return reply({ type: "claim_result", ok: message.token === state.claimToken });
    }
    if (message.type === "join") {
      const secret = state.invitations.get(message.invitation);
      const lock = invitationKey(secret);
      const request = JSON.parse(open(lock, message.envelope, "req"));
      const id = randomHex(4);
      const answer = { id: request.id, ts: nowSeconds(), status: 201, content_type: "application/json", body: JSON.stringify({ key: `ak_${randomHex(24)}`, id, role: "admin" }) };
      return reply({ type: "join_result", ok: true, key_id: id, envelope: seal(lock, { home: state.home, key: message.invitation }, "res", JSON.stringify(answer)) });
    }
  });
  return state;
}

async function call(method, path, { cookie, body, origin = APP } = {}) {
  const headers = {};
  if (cookie) headers.Cookie = cookie;
  if (origin) headers.Origin = origin;
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

const signIn = (person) => signInAs(worker.http, google, person, APP);

async function claimedHome() {
  const state = await home();
  const dana = await signIn(DANA);
  const claimed = await call("POST", "/v1/homes/claim", { cookie: dana, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  return { state, dana };
}

// The relay's answer to the controller's message `id`.
async function answerTo(state, id) {
  for (let tries = 0; tries < 200; tries += 1) {
    const found = state.seen.find((message) => message.type === "backup_result" && message.id === id);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`no backup_result for ${id}`);
}

let asked = 0;
async function chunk(state, message) {
  asked += 1;
  const id = `d${asked}`;
  state.connection.sendJson({ type: "backup_chunk", id, ...message });
  return answerTo(state, id);
}

// A sealed backup's text, as the controller makes it (the cloud never opens it).
const sealedText = (bytes) => JSON.stringify({ format: "directorlink-cloud-backup", version: 1, ct: randomBytes(bytes).toString("base64") });

// Sends `text` in chunks of `size` characters, as the driver does; returns the backup's id.
async function upload(state, text, { size = 60000, keyId = "ca1a0c76b8987230" } = {}) {
  const count = Math.ceil(text.length / size);
  let backup = null;
  for (let index = 0; index < count; index += 1) {
    const data = text.slice(index * size, (index + 1) * size);
    const answer = await chunk(state, index === 0 ? { index, count, size: text.length, key_id: keyId, data } : { index, backup, data });
    assert.equal(answer.ok, true, JSON.stringify(answer));
    assert.equal(answer.complete, index === count - 1);
    backup = answer.backup;
  }
  return backup;
}

test("a backup sent in chunks is kept whole, and only the home's owner lists and downloads it", TEST, async () => {
  const { state, dana } = await claimedHome();
  const text = sealedText(150000);
  const id = await upload(state, text);
  assert.match(id, /^[0-9a-f]{32}$/);

  const listed = await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana });
  assert.equal(listed.status, 200, listed.text);
  assert.equal(listed.json.keep, KEEP);
  assert.equal(listed.json.items.length, 1);
  const [item] = listed.json.items;
  assert.deepEqual(Object.keys(item).sort(), ["created_at", "id", "key_id", "size"], "the date, the size and which password; nothing about the home");
  assert.equal(item.size, text.length);
  assert.equal(item.key_id, "ca1a0c76b8987230");
  const downloaded = await call("GET", `/v1/homes/${state.home}/backups/${id}`, { cookie: dana });
  assert.equal(downloaded.status, 200);
  assert.equal(downloaded.json.data, text, "byte for byte");

  // Another member: the cloud does not know roles; only the owner passes until the controller says.
  const avi = await signIn(AVI);
  const invitationId = randomHex(4);
  state.invitations.set(invitationId, randomBytes(32).toString("hex"));
  assert.equal((await call("POST", `/v1/homes/${state.home}/invitations`, { cookie: dana, body: { invitation_id: invitationId, email: AVI.email, expires_at: new Date(Date.now() + 3600_000).toISOString() } })).status, 201);
  const request = { id: randomHex(8), ts: nowSeconds(), method: "POST", path: "/v1/auth/join", body: { name: "Phone" } };
  const envelope = seal(invitationKey(state.invitations.get(invitationId)), { home: state.home, key: invitationId }, "req", JSON.stringify(request));
  assert.equal((await call("POST", "/v1/join", { cookie: avi, body: { home_id: state.home, invitation_id: invitationId, envelope } })).status, 200);
  const member = await call("GET", `/v1/homes/${state.home}/backups`, { cookie: avi });
  assert.equal(member.status, 403);
  assert.equal(member.json.code, "ADMINS_ONLY");
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups/${id}`, { cookie: avi })).status, 403);
  const noa = await signIn(NOA);
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: noa })).json.code, "NOT_A_MEMBER");
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups`)).status, 401);
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups/${randomHex(16)}`, { cookie: dana })).status, 404);

  // Deleting them takes the app's origin.
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/backups`, { cookie: dana, origin: null })).status, 403);
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/backups`, { cookie: avi })).status, 403);
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/backups`, { cookie: dana })).status, 204);
  assert.deepEqual((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).json.items, []);
});

test("chunks are checked: sizes, order, the home's own upload, and a home nobody claimed", TEST, async () => {
  const { state, dana } = await claimedHome();
  const text = sealedText(3000);
  const first = { index: 0, count: 3, size: text.length, key_id: "ca1a0c76b8987230", data: text.slice(0, 1000) };
  const started = await chunk(state, first);
  assert.equal(started.ok, true);
  assert.equal(started.complete, false);
  assert.equal((await chunk(state, { index: 2, backup: started.backup, data: text.slice(2000) })).code, "OUT_OF_ORDER");
  assert.equal((await chunk(state, { index: 1, backup: randomHex(16), data: "x" })).code, "UPLOAD_NOT_FOUND");
  // Another home cannot add to it.
  const other = await home();
  assert.equal((await chunk(other, { index: 1, backup: started.backup, data: text.slice(1000, 2000) })).code, "UPLOAD_NOT_FOUND");
  assert.equal((await chunk(other, first)).code, "NOT_CLAIMED", "a home in no account keeps no backups");
  // More than it said.
  assert.equal((await chunk(state, { index: 1, backup: started.backup, data: `${text.slice(1000)}x` })).code, "SIZE_MISMATCH");
  assert.equal((await chunk(state, { index: 1, backup: started.backup, data: "x" })).code, "UPLOAD_NOT_FOUND", "a broken upload is not kept");
  // Too large, or not what a chunk is.
  assert.equal((await chunk(state, { ...first, size: 3_000_001, count: 50 })).code, "BACKUP_TOO_LARGE");
  assert.equal((await chunk(state, { ...first, data: "x".repeat(65537) })).code, "INVALID_REQUEST");
  assert.equal((await chunk(state, { ...first, count: 65 })).code, "INVALID_REQUEST");
  assert.equal((await chunk(state, { ...first, key_id: "not hex" })).code, "INVALID_REQUEST");
  assert.equal((await chunk(state, { ...first, count: 1 })).code, "SIZE_MISMATCH", "one chunk that is not the whole");
  // A last chunk short of the size: not kept.
  const short = await chunk(state, { ...first, count: 2 });
  assert.equal((await chunk(state, { index: 1, backup: short.backup, data: text.slice(1000, 1500) })).code, "SIZE_MISMATCH");
  assert.deepEqual((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).json.items, [], "nothing incomplete is listed");
  // An upload that never finished is replaced by the next one.
  const unfinished = await chunk(state, first);
  await upload(state, text, { size: 1000 });
  assert.equal((await chunk(state, { index: 1, backup: unfinished.backup, data: text.slice(1000, 2000) })).code, "UPLOAD_NOT_FOUND");
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).json.items.length, 1);
});

test("one backup a day is kept: a newer one the same day replaces it", TEST, async () => {
  const { state, dana } = await claimedHome();
  await upload(state, sealedText(2000), { keyId: "1111111111111111" });
  const newer = await upload(state, sealedText(2500), { keyId: "2222222222222222" });
  const items = (await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).json.items;
  assert.equal(items.length, 1);
  assert.equal(items[0].id, newer);
  assert.equal(items[0].key_id, "2222222222222222", "the one made with the new password");
});

test("a home's backups go with its owner's account", TEST, async () => {
  const { state, dana } = await claimedHome();
  await upload(state, sealedText(2000));
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).json.items.length, 1);
  assert.equal((await call("DELETE", "/v1/me", { cookie: dana })).status, 204);
  // Someone claims the home again at home: nothing of the backups made before is there.
  const noa = await signIn({ sub: "google-noa-c", email: "noa.c@example.com", name: "Noa" });
  assert.equal((await call("POST", "/v1/homes/claim", { cookie: noa, body: { home_id: state.home, claim_token: state.claimToken } })).status, 200);
  assert.deepEqual((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: noa })).json.items, []);
});

test("seven days are kept, and 5 MB in all: the oldest go first, the newest always stays", () => {
  const day = (n) => new Date(Date.UTC(2026, 9, 1 + n, 1, 30)).toISOString();
  const rows = Array.from({ length: 9 }, (_, n) => ({ id: `b${n}`, created_at: day(n), size: 200_000 }));
  assert.deepEqual(toPrune(rows, "b8"), ["b1", "b0"], "the last 7 days");
  assert.deepEqual(toPrune([...rows, { id: "late", created_at: `${day(8).slice(0, 10)}T23:00:00.000Z`, size: 1 }], "late"), ["b8", "b1", "b0"], "one a day, the newest");
  const big = [
    { id: "old", created_at: day(0), size: 2_900_000 },
    { id: "mid", created_at: day(1), size: 1_500_000 },
    { id: "new", created_at: day(2), size: 2_900_000 },
  ];
  assert.deepEqual(toPrune(big, "new"), ["old"], `at most ${MAX_HOME_BYTES} bytes in all`);
  assert.deepEqual(toPrune([{ id: "huge", created_at: day(3), size: 3_000_000 }, ...big], "huge"), ["new", "mid", "old"]);
});
