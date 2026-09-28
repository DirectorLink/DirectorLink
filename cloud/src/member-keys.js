// Which account uses which of a home's API keys (docs/ACCOUNTS.md), so that revoking a device's key
// at home also ends its account's membership. The cloud learns a key from the key an invitation
// made (join_result) and from each sealed request the home accepted with it (only the key's holder
// can seal one). The controller says which keys still exist (a "keys" message, docs/RELAY.md).

const KEY_ID = /^[0-9a-f]{8}$/;
const MAX_KEYS = 1000;

function iso(ms = Date.now()) {
  return new Date(ms).toISOString();
}

function log(event, fields) {
  console.log(JSON.stringify({ event, ...fields }));
}

export function validKeyId(value) {
  return typeof value === "string" && KEY_ID.test(value);
}

// A statement that records `keyId` as used by `userId` (it moves when another account uses it).
export function recordKey(env, homeId, userId, keyId) {
  return env.DB.prepare(
    "INSERT INTO member_keys (home_id, key_id, user_id, added_at) VALUES (?, ?, ?, ?) ON CONFLICT (home_id, key_id) DO UPDATE SET user_id = excluded.user_id, added_at = excluded.added_at"
  ).bind(homeId, keyId, userId, iso());
}

// After a sealed request the home accepted: records the key when it is new for this account.
export async function noteKeyUsed(env, homeId, userId, keyId) {
  if (!validKeyId(keyId)) {
    return;
  }
  const known = await env.DB.prepare("SELECT user_id FROM member_keys WHERE home_id = ? AND key_id = ?").bind(homeId, keyId).first();
  if (known?.user_id !== userId) {
    await recordKey(env, homeId, userId, keyId).run();
  }
}

// The controller's list of the key ids that exist: forgets the others, and members (never the
// owner) whose last key that was. Returns the accounts that left.
export async function syncKeys(env, homeId, ids) {
  if (!Array.isArray(ids) || ids.length > MAX_KEYS || !ids.every(validKeyId)) {
    log("keys_ignored", { home: homeId, why: "not a list of key ids" });
    return [];
  }
  const { results: gone } = await env.DB.prepare(
    "DELETE FROM member_keys WHERE home_id = ? AND key_id NOT IN (SELECT value FROM json_each(?)) RETURNING user_id, key_id"
  )
    .bind(homeId, JSON.stringify(ids))
    .all();
  const left = [];
  for (const userId of new Set(gone.map((row) => row.user_id))) {
    const { meta } = await env.DB.prepare(
      "DELETE FROM members WHERE home_id = ? AND user_id = ? AND user_id <> (SELECT owner_id FROM homes WHERE id = ?) AND NOT EXISTS (SELECT 1 FROM member_keys WHERE home_id = ? AND user_id = ?)"
    )
      .bind(homeId, userId, homeId, homeId, userId)
      .run();
    if (meta.changes) {
      left.push(userId);
    }
  }
  if (gone.length) {
    log("keys_revoked_at_home", { home: homeId, keys: gone.map((row) => row.key_id), members_left: left });
  }
  return left;
}
