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
// MAX_HOME_BYTES in all: the oldest go first, and the newest always stays.

import { json, problem, randomHex } from "./http.js";

export const KEEP = 7;
// Each chunk's text, one backup's and a home's in all, in characters (the sealed text is ASCII).
export const MAX_CHUNK_BYTES = 65536;
export const MAX_BACKUP_BYTES = 3000000;
export const MAX_CHUNKS = 64;
export const MAX_HOME_BYTES = 5000000;
// An upload that never finished (the connection was lost) goes after this long.
const UPLOAD_MS = 3600 * 1000;

const BACKUP_ID = /^[0-9a-f]{32}$/;
const KEY_ID = /^[0-9a-f]{16}$/;

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

// What stays once `newest` is complete: one a day (the newest), KEEP at most, MAX_HOME_BYTES in
// all. Returns the ids to delete.
export function toPrune(rows, newestId) {
  const sorted = [...rows].sort((a, b) => (a.id === newestId ? -1 : b.id === newestId ? 1 : b.created_at.localeCompare(a.created_at)));
  const days = new Set();
  const gone = [];
  let kept = 0;
  let bytes = 0;
  let full = false;
  for (const row of sorted) {
    const day = row.created_at.slice(0, 10);
    // Once one does not fit, every older one goes too.
    full ||= row.id !== newestId && (kept >= KEEP || bytes + row.size > MAX_HOME_BYTES);
    if (full || (row.id !== newestId && days.has(day))) {
      gone.push(row.id);
      continue;
    }
    days.add(day);
    kept += 1;
    bytes += row.size;
  }
  return gone;
}

// One chunk from the home's connection: { index: 0, count, size, key_id, data } starts a backup,
// { backup, index, data } carries on. Returns what the controller is answered: { ok: true, backup,
// complete } or { ok: false, code }.
export async function receiveBackupChunk(env, homeId, data) {
  const index = data?.index;
  const text = data?.data;
  if (typeof text !== "string" || text.length < 1 || text.length > MAX_CHUNK_BYTES || !isWhole(index, 0, MAX_CHUNKS - 1)) {
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
    if (!(await env.DB.prepare("SELECT 1 AS found FROM homes WHERE id = ?").bind(homeId).first())) {
      return { ok: false, code: "NOT_CLAIMED" };
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

// A backup is in: the ones it replaces go.
async function completed(env, homeId, id, size) {
  const { results } = await env.DB.prepare("SELECT id, size, created_at FROM backups WHERE home_id = ? AND complete = 1").bind(homeId).all();
  const gone = toPrune(results, id);
  if (gone.length) await env.DB.batch(deletingIds(env, gone));
  log("backup_stored", { home: homeId, backup: id, size, kept: results.length - gone.length, deleted: gone.length });
}

// Who may list, download and delete a home's backups: its admins. The cloud does not know roles
// (they are the controller's keys), so the home's owner (who claimed it at home with an admin key)
// passes, and the members who use a key the controller announced as an admin's.
// TODO(1.6.0 integrator): the alerts work (ADR-047) adds `admins` (the admin key ids) to the
// driver's {type:"keys"} message, and the home's Durable Object keeps it (alerts.js,
// "alerts_admins"). Have adminKeyIds below return that list (from the home's object) as a Set;
// alerts.js's isAdmin makes the same member_keys check. Until then it answers null and only the
// owner passes. This is the only place that decides.
export async function mayUseBackups(env, homeId, userId) {
  const row = await env.DB.prepare("SELECT homes.owner_id AS owner_id FROM members JOIN homes ON homes.id = members.home_id WHERE members.home_id = ? AND members.user_id = ?")
    .bind(homeId, userId)
    .first();
  if (!row) {
    return problem(403, "NOT_A_MEMBER", "This account does not belong to that home");
  }
  if (row.owner_id === userId) {
    return null;
  }
  const admins = await adminKeyIds(env, homeId);
  if (admins) {
    const { results } = await env.DB.prepare("SELECT key_id FROM member_keys WHERE home_id = ? AND user_id = ?").bind(homeId, userId).all();
    if (results.some((key) => admins.has(key.key_id))) {
      return null;
    }
  }
  return problem(403, "ADMINS_ONLY", "Only the home's admins see its backups");
}

// The key ids the controller announced as admins' (a Set), or null while it says no roles.
async function adminKeyIds(_env, _homeId) {
  return null;
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
