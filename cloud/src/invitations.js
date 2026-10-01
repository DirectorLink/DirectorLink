// Invitation rows kept by the cloud (docs/ACCOUNTS.md): the controller's invitation id, for whom,
// until when. An id is registered once, so that nobody can bind an invitation to another email.

// A controller whose clock is behind still accepts an invitation after its expiry here: its row is
// kept this much longer, so that its id cannot be registered again meanwhile.
export const PURGE_GRACE_MS = 24 * 3600 * 1000;

// Statements that forget who an invitation was for, or who made it (account deletion, a new owner).
// Rows the controller may still accept keep their id as a tombstone; used ones go, and so do the
// requests to join with them (ADR-041), which a tombstone could not be accepted for anyway.
export function forgetInvitations(env, where, ...values) {
  return [
    env.DB.prepare(
      `DELETE FROM join_requests WHERE EXISTS (SELECT 1 FROM invitations WHERE invitations.home_id = join_requests.home_id AND invitations.id = join_requests.invitation_id AND (${where}))`
    ).bind(...values),
    env.DB.prepare(`DELETE FROM invitations WHERE accepted_by IS NOT NULL AND (${where})`).bind(...values),
    env.DB.prepare(`UPDATE invitations SET email = '', created_by = '' WHERE accepted_by IS NULL AND (${where})`).bind(...values),
  ];
}

// Daily (cron, wrangler.jsonc → triggers): invitations long past their expiry, tombstones included,
// and the requests to join with them or with invitations already gone.
export async function purgeInvitations(env) {
  const before = new Date(Date.now() - PURGE_GRACE_MS).toISOString();
  const [requests, result] = await env.DB.batch([
    env.DB.prepare(
      "DELETE FROM join_requests WHERE NOT EXISTS (SELECT 1 FROM invitations WHERE invitations.home_id = join_requests.home_id AND invitations.id = join_requests.invitation_id AND invitations.expires_at >= ?)"
    ).bind(before),
    env.DB.prepare("DELETE FROM invitations WHERE expires_at < ?").bind(before),
  ]);
  console.log(JSON.stringify({ event: "invitations_purged", count: result.meta?.changes ?? 0, join_requests: requests.meta?.changes ?? 0 }));
}
