// Automatic backups in the account (cloud/src/backups.js, ADR-048): a fake controller sends a
// sealed backup over its relay connection in chunks, each answered before the next; the home's
// owner lists and downloads them; the Worker under `wrangler dev`, with a fake Google.
//   node --test tests/cloud/backups.test.mjs

import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { after, afterEach, before, test } from "node:test";

import { KEEP, MAX_ACCOUNT_BYTES, MAX_BACKUP_BYTES, MAX_HOME_BYTES, STARTS_PER_DAY, toPrune, toPruneAccount } from "../../cloud/src/backups.js";
import { connectDriver, randomHex } from "../../scripts/relay_smoke.mjs";
import { googleVars, signInAs, startFakeGoogle } from "./fake-google.mjs";
import { invitationKey, lockKey, open, seal } from "./lock.mjs";
import { STARTUP_MS, startWorker } from "./worker.mjs";

const APP = "http://localhost:8080";
const TEST = { timeout: 60_000 };
const DANA = { sub: "google-dana-b", email: "dana.b@example.com", name: "Dana" };
const AVI = { sub: "google-avi-b", email: "avi.b@example.com", name: "Avi" };
const NOA = { sub: "google-noa-b", email: "noa.b@example.com", name: "Noa" };
const OREN = { sub: "google-oren-b", email: "oren.b@example.com", name: "Oren" };

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

// A controller: answers claims, joins and sealed requests (with its keys: id -> API key), and
// collects what the relay sends it.
async function home() {
  const state = { home: randomHex(16), claimToken: randomHex(24), invitations: new Map(), keys: new Map(), seen: [] };
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
    if (message.type === "e2e") {
      const apiKey = state.keys.get(message.envelope.key);
      const answer = { id: JSON.parse(open(lockKey(apiKey), message.envelope, "req")).id, ts: nowSeconds(), status: 200, content_type: "application/json", body: "{}" };
      return reply({ type: "e2e", envelope: seal(lockKey(apiKey), { home: state.home, key: message.envelope.key }, "res", JSON.stringify(answer)) });
    }
    if (message.type === "join") {
      const secret = state.invitations.get(message.invitation);
      const lock = invitationKey(secret);
      const request = JSON.parse(open(lock, message.envelope, "req"));
      const id = randomHex(4);
      state.joinedKey = id;
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

async function claimedHome(person = DANA) {
  const state = await home();
  const dana = await signIn(person);
  const claimed = await call("POST", "/v1/homes/claim", { cookie: dana, body: { home_id: state.home, claim_token: state.claimToken } });
  assert.equal(claimed.status, 200, claimed.text);
  return { state, dana };
}

// A key of the home (`id`) that this account uses: a request sealed with it through the account
// tells the cloud so (member_keys).
async function usesKey(state, cookie, id) {
  state.keys.set(id, `ak_${randomHex(24)}`);
  const request = { id: randomHex(8), ts: nowSeconds(), method: "GET", path: "/v1/system", body: null };
  const envelope = seal(lockKey(state.keys.get(id)), { home: state.home, key: id }, "req", JSON.stringify(request));
  const answer = await call("POST", `/v1/homes/${state.home}/e2e`, { cookie, body: { envelope } });
  assert.equal(answer.status, 200, answer.text);
}

// The controller's key ids, and which are admins' (`admins` undefined: a driver before 1.6.0).
async function announce(state, ids, admins) {
  state.connection.sendJson({ type: "keys", ids, ...(admins ? { admins } : {}) });
  await new Promise((resolve) => setTimeout(resolve, 300));
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

test("a backup sent in chunks is kept whole, and only the home's admins list and download it", TEST, async () => {
  const { state, dana } = await claimedHome();
  await usesKey(state, dana, "0000aaaa");
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

  // Another member: the cloud does not know roles; only the owner passes until the controller says
  // which keys are admins' (its {type:"keys"} message, ADR-047). 0000aaaa is the owner's.
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
  // The controller names its keys, Avi's not an admin's: still refused. Then it is: Avi passes.
  state.connection.sendJson({ type: "keys", ids: [state.joinedKey, "0000aaaa"], admins: ["0000aaaa"] });
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: avi })).json.code, "ADMINS_ONLY");
  state.connection.sendJson({ type: "keys", ids: [state.joinedKey, "0000aaaa"], admins: [state.joinedKey] });
  await new Promise((resolve) => setTimeout(resolve, 300));
  const admin = await call("GET", `/v1/homes/${state.home}/backups`, { cookie: avi });
  assert.equal(admin.status, 200, admin.text);
  assert.equal(admin.json.items.length, 1, "an admin of the home sees its backups");
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups/${id}`, { cookie: avi })).json.data, text);
  state.connection.sendJson({ type: "keys", ids: [state.joinedKey, "0000aaaa"], admins: ["0000aaaa"] });
  await new Promise((resolve) => setTimeout(resolve, 300));
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
  // Only printable ASCII (the sealed text is JSON around base64): a character is then a byte.
  for (const data of ["\u4e2d".repeat(1000), `${"a".repeat(999)}\n`, `${"a".repeat(999)}\u00e9`]) {
    assert.equal((await chunk(state, { index: 1, backup: started.backup, data })).code, "INVALID_REQUEST", JSON.stringify(data.slice(-2)));
    assert.equal((await chunk(state, { ...first, data })).code, "INVALID_REQUEST");
  }
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

test(`a home starts at most ${STARTS_PER_DAY} backups a day, and its nightly one besides`, TEST, async () => {
  const { state, dana } = await claimedHome();
  const one = (why) => {
    const text = sealedText(1500);
    return chunk(state, { index: 0, count: 1, size: text.length, key_id: "ca1a0c76b8987230", data: text, ...(why ? { why } : {}) });
  };
  // Back up now, pressed again and again.
  for (let start = 0; start < STARTS_PER_DAY; start += 1) {
    assert.equal((await one(start % 2 ? "now" : undefined)).ok, true);
  }
  const refused = await one("now");
  assert.deepEqual([refused.ok, refused.code], [false, "BACKUP_LIMIT"]);
  assert.equal((await one()).code, "BACKUP_LIMIT");
  // The nightly backup still goes, once.
  const nightly = await one("daily");
  assert.equal(nightly.ok, true, JSON.stringify(nightly));
  assert.equal((await one("daily")).code, "BACKUP_LIMIT", "a second nightly one counts as the others");
  const items = (await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).json.items;
  assert.deepEqual(items.map((item) => item.id), [nightly.backup], "the refused ones changed nothing");

  // Each home counts its own.
  const other = await claimedHome();
  assert.equal((await chunk(other.state, { index: 0, count: 1, size: 10, key_id: "ca1a0c76b8987230", data: "0123456789" })).ok, true);
});

test("one owner's homes hold at most 25 MB of backups together", { timeout: 180_000 }, async () => {
  // Eight homes of one account with a backup of the largest size each: 24 MB.
  const homes = [];
  for (let n = 0; n < 8; n += 1) {
    const { state, dana: cookie } = await claimedHome(OREN);
    await upload(state, "A".repeat(MAX_BACKUP_BYTES), { size: 65536 });
    homes.push({ state, cookie });
  }
  const ninth = await claimedHome(OREN);
  const big = "B".repeat(MAX_BACKUP_BYTES);
  const refused = await chunk(ninth.state, { index: 0, count: Math.ceil(big.length / 65536), size: big.length, key_id: "ca1a0c76b8987230", data: big.slice(0, 65536) });
  assert.deepEqual([refused.ok, refused.code], [false, "ACCOUNT_BACKUPS_FULL"]);
  // What still fits goes; another owner's home is not concerned.
  await upload(ninth.state, "C".repeat(MAX_ACCOUNT_BYTES - 8 * MAX_BACKUP_BYTES), { size: 65536 });
  const listed = await call("GET", `/v1/homes/${ninth.state.home}/backups`, { cookie: ninth.dana });
  assert.equal(listed.json.items.length, 1);
  const elsewhere = await claimedHome(NOA);
  await upload(elsewhere.state, "D".repeat(MAX_BACKUP_BYTES), { size: 65536 });
  // A home's own next backup replaces its last one: it fits.
  await upload(homes[0].state, "E".repeat(MAX_BACKUP_BYTES), { size: 65536 });
});

test("the owner sees the backups while one of their keys is an admin's; with a controller before 1.6.0, always", TEST, async () => {
  const { state, dana } = await claimedHome();
  await usesKey(state, dana, "0000d0d0");
  const id = await upload(state, sealedText(2000));
  const sees = async () => (await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).status;
  // No roles announced (before 1.6.0): the owner, who claimed the home at home with an admin key.
  assert.equal(await sees(), 200);
  await announce(state, ["0000d0d0", "0000beef"]);
  assert.equal(await sees(), 200, "a controller before 1.6.0 lists no admins");
  await announce(state, ["0000d0d0", "0000beef"], ["0000d0d0"]);
  assert.equal(await sees(), 200, "the owner's key is an admin's");
  // Made a member at home: the owner is refused, as for alerts.
  await announce(state, ["0000d0d0", "0000beef"], ["0000beef"]);
  const refused = await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana });
  assert.deepEqual([refused.status, refused.json.code], [403, "ADMINS_ONLY"]);
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups/${id}`, { cookie: dana })).status, 403, "nor downloads one");
  assert.equal((await call("DELETE", `/v1/homes/${state.home}/backups`, { cookie: dana })).status, 403, "nor deletes them");
  await announce(state, ["0000d0d0", "0000beef"], ["0000d0d0", "0000beef"]);
  assert.equal((await call("GET", `/v1/homes/${state.home}/backups`, { cookie: dana })).json.items.length, 1, "an admin again: nothing was deleted");
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
  // The nightly backup and a Back up now the same day, 2.6 MB each: only the one replaced goes,
  // and it does not count towards the 5 MB (the 6 days before stay).
  const week = Array.from({ length: 6 }, (_, n) => ({ id: `d${n}`, created_at: day(n), size: 300_000 }));
  const today = (hour, id) => ({ id, created_at: new Date(Date.UTC(2026, 9, 7, hour, 30)).toISOString(), size: 2_600_000 });
  assert.deepEqual(toPrune([...week, today(1, "nightly"), today(12, "now")], "now"), ["nightly"]);
});

test("an owner's homes keep 25 MB in all: the oldest go first, never a home's newest nor an upload under way", () => {
  const at = (n) => new Date(Date.UTC(2026, 9, 1 + n, 1, 30)).toISOString();
  const row = (id, home, n, size, complete = 1) => ({ id, home_id: home, created_at: at(n), size, complete });
  const rows = [
    row("a0", "A", 0, 2_000_000),
    row("a1", "A", 1, 3_000_000),
    row("a2", "A", 2, 3_000_000),
    row("b0", "B", 0, 3_000_000),
    row("b3", "B", 3, 3_000_000),
    row("c1", "C", 1, 3_000_000),
    row("c4", "C", 4, 3_000_000),
    row("d5", "D", 5, 3_000_000, 0), // an upload under way
    row("new", "A", 6, 3_000_000),
  ];
  // 26 MB: the oldest goes (b0 is as old as a0, and goes after it).
  assert.deepEqual(toPruneAccount(rows, "new"), ["a0"]);
  // Larger: older ones go, oldest first, until it fits.
  const more = [...rows, row("e6", "E", 6, 3_000_000), row("f6", "F", 6, 3_000_000), row("g6", "G", 6, 3_000_000)];
  assert.deepEqual(toPruneAccount(more, "new"), ["a0", "b0", "a1", "c1"]);
  // Only the newest of each home (and the upload) left: nothing more goes, even above it.
  const newest = ["A", "B", "C", "E", "F", "G", "H", "I", "J"].map((home, n) => row(`${home}x`, home, n, 3_000_000));
  assert.deepEqual(toPruneAccount(newest, "Ix"), []);
  assert.ok(MAX_ACCOUNT_BYTES === 25_000_000);
});
