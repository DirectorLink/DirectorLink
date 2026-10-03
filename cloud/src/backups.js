// Automatic backups (docs/BACKUP.md, ADR-048). Each day the controller seals a backup to the backup
// password's public key and sends it over its relay connection in chunks ({type:"backup_chunk"},
// each answered {type:"backup_result"} before the next is sent; home-relay.js). The cloud checks
// the sizes, keeps the ciphertext in D1 (migration 0007) and cannot open it: an admin downloads one
// and types the password in the app.
//
//   GET    /v1/homes/{home_id}/backups          the home's backups: id, date, size, key_id
//   GET    /v1/homes/{home_id}/backups/{id}     one, with its sealed text
//   DELETE /v1/homes/{home_id}/backups          deletes them all
//
// One a day per home (UTC; a newer one the same day replaces it), the last KEEP, at most
// MAX_HOME_BYTES in all: the oldest go first, and the newest always stays. The homes of one owner
// hold at most MAX_ACCOUNT_BYTES together: beyond it the oldest go first, across those homes, and
// each home's newest stays. A home starts at most STARTS_PER_DAY backups a UTC day, besides its
// nightly one.

import { homeObject } from "./alerts.js";
import { json, problem, randomHex } from "./http.js";

export const KEEP = 7;
// Each chunk's text, one backup's, a home's in all and an owner's in all, in bytes: a chunk is
// printable ASCII only (the sealed backup is JSON around base64), so a character is a byte.
export const MAX_CHUNK_BYTES = 65536;
export const MAX_BACKUP_BYTES = 3000000;
export const MAX_CHUNKS = 64;
export const MAX_HOME_BYTES = 5000000;
export const MAX_ACCOUNT_BYTES = 25000000;
// Backups a home may start in a UTC day (Back up now, a nightly one tried again); the first that
// says it is the nightly one (`why: "daily"`) is let through besides, so Back up now never uses up
// the night's.
export const STARTS_PER_DAY = 4;
// An upload that never finished (the connection was lost) goes after this long.
const UPLOAD_MS = 3600 * 1000;

const BACKUP_ID = /^[0-9a-f]{32}$/;
const KEY_ID = /^[0-9a-f]{16}$/;
const PRINTABLE = /^[\x20-\x7e]+$/;

function iso(ms = Date.now()) {
  return new Date(ms).toISOString();
}

function log(event, fields) {
  console.log(JSON.stringify({ event, ...fields }));
}

const isWhole = (value, min, max) => Number.isInteger(value) && value >= min && value <= max;

// Statements that delete the backups `where` picks, with their chunks.
function deleting(env, where, ...values) {
  return [
    env.DB.prepare(`DELETE FROM backup_chunks WHERE backup_id IN (SELECT id FROM backups WHERE ${where})`).bind(...values),
    env.DB.prepare(`DELETE FROM backups WHERE ${where}`).bind(...values),
  ];
}

// Those of a few ids.
function deletingIds(env, ids) {
  return ids.length ? deleting(env, `id IN (${ids.map(() => "?").join(", ")})`, ...ids) : [];
}

// What stays of a home's backups once `newest` is complete: one a day (the newest), KEEP at most,
// MAX_HOME_BYTES in all. Returns the ids to delete.
export function toPrune(rows, newestId) {
  const sorted = [...rows].sort((a, b) => (a.id === newestId ? -1 : b.id === newestId ? 1 : b.created_at.localeCompare(a.created_at)));
  const days = new Set();
  const gone = [];
  let kept = 0;
  let bytes = 0;
  let full = false;
  for (const row of sorted) {
    const day = row.created_at.slice(0, 10);
    // A newer one of the same day replaces it: it counts for nothing.
    if (row.id !== newestId && days.has(day)) {
      gone.push(row.id);
      continue;
    }
    // Once one does not fit, every older one goes too.
    full ||= row.id !== newestId && (kept >= KEEP || bytes + row.size > MAX_HOME_BYTES);
    if (full) {
      gone.push(row.id);
      continue;
    }
    days.add(day);
    kept += 1;
    bytes += row.size;
  }
  return gone;
}

// What else goes so that one owner's homes hold MAX_ACCOUNT_BYTES at most. `rows`: the backups of
// all their homes ({ id, home_id, size, complete, created_at }, uploads under way included), less
// what each home's own rule (toPrune) takes. The oldest complete ones go first, whichever home they
// are of; never a home's newest (`newestId` is its home's), nor an upload under way. Returns the
// ids to delete.
export function toPruneAccount(rows, newestId) {
  let bytes = rows.reduce((sum, row) => sum + row.size, 0);
  const complete = rows.filter((row) => row.complete === 1);
  const newest = new Map();
  for (const row of complete) {
    const best = newest.get(row.home_id);
    if (!best || row.id === newestId || (best.id !== newestId && row.created_at > best.created_at)) {
      newest.set(row.home_id, row);
    }
  }
  const older = complete.filter((row) => newest.get(row.home_id) !== row).sort((a, b) => a.created_at.localeCompare(b.created_at));
  const gone = [];
  for (const row of older) {
    if (bytes <= MAX_ACCOUNT_BYTES) break;
    gone.push(row.id);
    bytes -= row.size;
  }
  return gone;
}

// Whether a new backup of `size` bytes for `homeId` fits its owner's MAX_ACCOUNT_BYTES with what
// must stay: the newest backup of each of the owner's other homes, and their uploads under way (the
// home's own older ones can go once the new one is in: toPruneAccount).
async function fitsAccount(env, ownerId, homeId, size) {
  const row = await env.DB.prepare(
    "SELECT COALESCE(SUM(size), 0) AS bytes FROM backups AS b WHERE b.home_id IN (SELECT id FROM homes WHERE owner_id = ?1) AND b.home_id <> ?2 " +
      "AND (b.complete = 0 OR b.id = (SELECT n.id FROM backups AS n WHERE n.home_id = b.home_id AND n.complete = 1 ORDER BY n.created_at DESC, n.id DESC LIMIT 1))"
  )
    .bind(ownerId, homeId)
    .first();
  return (row?.bytes ?? 0) + size <= MAX_ACCOUNT_BYTES;
}

// Whether the home may start another backup today (UTC), counted in the home's Durable Object
// storage. Nothing else runs between its two storage operations, so two first chunks cannot both
// take the last start.
async function mayStart(storage, why) {
  const day = iso().slice(0, 10);
  const stored = await storage.get("backup_starts");
  const today = stored?.day === day ? stored : { day, count: 0, daily: false };
  if (why === "daily" && !today.daily) {
    today.daily = true;
  } else if (today.count >= STARTS_PER_DAY) {
    return false;
  } else {
    today.count += 1;
  }
  await storage.put("backup_starts", today);
  return true;
}

// One chunk from the home's connection: { index: 0, count, size, key_id, data[, why] } starts a
// backup (why: "daily" for the nightly one), { backup, index, data } carries on. `storage`: the
// home's Durable Object storage (the day's starts). Returns what the controller is answered:
// { ok: true, backup, complete } or { ok: false, code }.
export async function receiveBackupChunk(env, homeId, data, storage) {
  const index = data?.index;
  const text = data?.data;
  if (typeof text !== "string" || text.length < 1 || text.length > MAX_CHUNK_BYTES || !PRINTABLE.test(text) || !isWhole(index, 0, MAX_CHUNKS - 1)) {
    return { ok: false, code: "INVALID_REQUEST" };
  }
  if (index === 0) {
    const { count, size } = data;
    if (!isWhole(count, 1, MAX_CHUNKS) || !isWhole(size, 1, MAX_BACKUP_BYTES) || !KEY_ID.test(data.key_id ?? "")) {
      return { ok: false, code: size > MAX_BACKUP_BYTES ? "BACKUP_TOO_LARGE" : "INVALID_REQUEST" };
    }
    if (size > count * MAX_CHUNK_BYTES || text.length > size || (count === 1 && text.length !== size)) {
      return { ok: false, code: "SIZE_MISMATCH" };
    }
    // Only for a home an account has claimed: nobody could read it otherwise.
    const home = await env.DB.prepare("SELECT owner_id FROM homes WHERE id = ?").bind(homeId).first();
    if (!home) {
      return { ok: false, code: "NOT_CLAIMED" };
    }
    if (!(await fitsAccount(env, home.owner_id, homeId, size))) {
      log("backup_refused", { home: homeId, size, why: "the owner's homes hold the most they may" });
      return { ok: false, code: "ACCOUNT_BACKUPS_FULL" };
    }
    if (!(await mayStart(storage, data.why))) {
      log("backup_refused", { home: homeId, size, why: "started too often today" });
      return { ok: false, code: "BACKUP_LIMIT" };
    }
    const id = randomHex(16);
    const complete = count === 1 ? 1 : 0;
    await env.DB.batch([
      // An upload of this home that never finished goes.
      ...deleting(env, "home_id = ? AND complete = 0", homeId),
      env.DB.prepare("INSERT INTO backups (id, home_id, key_id, size, chunks, complete, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)").bind(id, homeId, data.key_id, size, count, complete, iso()),
      env.DB.prepare("INSERT INTO backup_chunks (backup_id, idx, data) VALUES (?, 0, ?)").bind(id, text),
    ]);
    if (complete) await completed(env, homeId, id, size);
    return { ok: true, backup: id, complete: Boolean(complete) };
  }
  if (!BACKUP_ID.test(data.backup ?? "")) {
    return { ok: false, code: "INVALID_REQUEST" };
  }
  const upload = await env.DB.prepare(
    "SELECT backups.size AS size, backups.chunks AS chunks, COUNT(backup_chunks.idx) AS received, COALESCE(SUM(LENGTH(backup_chunks.data)), 0) AS bytes " +
      "FROM backups LEFT JOIN backup_chunks ON backup_chunks.backup_id = backups.id WHERE backups.id = ? AND backups.home_id = ? AND backups.complete = 0 GROUP BY backups.id"
  )
    .bind(data.backup, homeId)
    .first();
  if (!upload) {
    return { ok: false, code: "UPLOAD_NOT_FOUND" };
  }
  if (index !== upload.received || index >= upload.chunks) {
    return { ok: false, code: "OUT_OF_ORDER" };
  }
  const bytes = upload.bytes + text.length;
  const last = index === upload.chunks - 1;
  if (bytes > upload.size || (last && bytes !== upload.size)) {
    // A backup whose chunks do not add up is not kept.
    await env.DB.batch(deletingIds(env, [data.backup]));
    return { ok: false, code: "SIZE_MISMATCH" };
  }
  await env.DB.batch([
    env.DB.prepare("INSERT INTO backup_chunks (backup_id, idx, data) VALUES (?, ?, ?)").bind(data.backup, index, text),
    ...(last ? [env.DB.prepare("UPDATE backups SET complete = 1, created_at = ? WHERE id = ?").bind(iso(), data.backup)] : []),
  ]);
  if (last) await completed(env, homeId, data.backup, bytes);
  return { ok: true, backup: data.backup, complete: last };
}

// A backup is in: the ones it replaces go, of the home (toPrune), then of its owner (toPruneAccount).
async function completed(env, homeId, id, size) {
  const { results } = await env.DB.prepare(
    "SELECT id, home_id, size, complete, created_at FROM backups WHERE home_id IN (SELECT id FROM homes WHERE owner_id = (SELECT owner_id FROM homes WHERE id = ?))"
  )
    .bind(homeId)
    .all();
  const own = results.filter((row) => row.home_id === homeId && row.complete === 1);
  const gone = toPrune(own, id);
  const others = toPruneAccount(
    results.filter((row) => !gone.includes(row.id)),
    id
  );
  if (gone.length || others.length) await env.DB.batch(deletingIds(env, [...gone, ...others]));
  log("backup_stored", { home: homeId, backup: id, size, kept: own.length - gone.length, deleted: gone.length, deleted_for_account: others.length });
}

// Who may list, download and delete a home's backups: its admins. The cloud does not know roles
// (they are the controller's keys): the accounts that use a key the controller announced as an
// admin's pass, the owner too only then, as for alerts. The driver's {type:"keys"} message lists
// them (`admins`, ADR-047) and the home's object keeps the list (alerts.js). A controller before
// 1.6.0 names none: then only the owner passes (who claimed the home at home with an admin key).
// This is the only place that decides.
export async function mayUseBackups(env, homeId, userId) {
  const row = await env.DB.prepare("SELECT homes.owner_id AS owner_id FROM members JOIN homes ON homes.id = members.home_id WHERE members.home_id = ? AND members.user_id = ?")
    .bind(homeId, userId)
    .first();
  if (!row) {
    return problem(403, "NOT_A_MEMBER", "This account does not belong to that home");
  }
  const admins = await adminKeyIds(env, homeId);
  if (admins === null) {
    return row.owner_id === userId ? null : problem(403, "ADMINS_ONLY", "Only the home's admins see its backups");
  }
  const { results } = await env.DB.prepare("SELECT key_id FROM member_keys WHERE home_id = ? AND user_id = ?").bind(homeId, userId).all();
  if (results.some((key) => admins.has(key.key_id))) {
    return null;
  }
  return problem(403, "ADMINS_ONLY", "Only the home's admins see its backups");
}

// The key ids the controller announced as admins' (a Set), or null when it never said (before
// 1.6.0). When the home's object cannot be asked, nobody passes: the error goes on (500).
async function adminKeyIds(env, homeId) {
  try {
    const answer = await homeObject(env, homeId, { op: "admins" });
    return Array.isArray(answer?.admins) ? new Set(answer.admins) : null;
  } catch (error) {
    log("backup_roles_unknown", { home: homeId, error: String(error?.message ?? error) });
    throw error;
  }
}

async function listBackups(env, user, homeId) {
  const refused = await mayUseBackups(env, homeId, user.id);
  if (refused) return refused;
  const { results } = await env.DB.prepare("SELECT id, created_at, size, key_id FROM backups WHERE home_id = ? AND complete = 1 ORDER BY created_at DESC")
    .bind(homeId)
    .all();
  return json({ items: results, keep: KEEP, max_bytes: MAX_HOME_BYTES });
}

async function getBackup(env, user, homeId, backupId) {
  const refused = await mayUseBackups(env, homeId, user.id);
  if (refused) return refused;
  const backup = await env.DB.prepare("SELECT id, created_at, size, key_id, chunks FROM backups WHERE id = ? AND home_id = ? AND complete = 1").bind(backupId, homeId).first();
  if (!backup) {
    return problem(404, "NOT_FOUND", "No such backup: it may have been replaced by a newer one");
  }
  const { results } = await env.DB.prepare("SELECT data FROM backup_chunks WHERE backup_id = ? ORDER BY idx").bind(backupId).all();
  const data = results.map((row) => row.data).join("");
  if (results.length !== backup.chunks || data.length !== backup.size) {
    return problem(500, "BACKUP_DAMAGED", "This backup is not whole; use another one");
  }
  log("backup_downloaded", { home: homeId, user: user.id, backup: backupId });
  return json({ id: backup.id, created_at: backup.created_at, size: backup.size, key_id: backup.key_id, data });
}

async function deleteBackups(env, user, homeId) {
  const refused = await mayUseBackups(env, homeId, user.id);
  if (refused) return refused;
  const [, { meta }] = await env.DB.batch(deleting(env, "home_id = ?", homeId));
  log("backups_deleted", { home: homeId, user: user.id, count: meta?.changes ?? 0 });
  return new Response(null, { status: 204 });
}

// For homes.js's route table (session, CORS and origin checks there).
export const BACKUP_ROUTES = [
  [/^\/v1\/homes\/([0-9a-f]{32})\/backups$/, { GET: (r, env, user, m) => listBackups(env, user, m[1]), DELETE: (r, env, user, m) => deleteBackups(env, user, m[1]) }],
  [/^\/v1\/homes\/([0-9a-f]{32})\/backups\/([0-9a-f]{32})$/, { GET: (r, env, user, m) => getBackup(env, user, m[1], m[2]) }],
];

// Daily (cron): uploads that never finished.
export async function purgeBackupUploads(env) {
  const [, { meta }] = await env.DB.batch(deleting(env, "complete = 0 AND created_at < ?", iso(Date.now() - UPLOAD_MS)));
  console.log(JSON.stringify({ event: "backup_uploads_purged", count: meta?.changes ?? 0 }));
}
