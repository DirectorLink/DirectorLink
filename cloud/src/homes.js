// Homes and remote access for accounts (docs/ACCOUNTS.md): claiming a home, its members, invitations,
// and passing sealed requests to it. The cloud decides who may talk to which home and routes the
// envelopes; what is inside them it cannot read.
//
//   POST   /v1/homes/claim                          { home_id, claim_token }: the account owns the home
//   GET    /v1/homes                                the account's homes
//   GET    /v1/homes/{home_id}                      whether it is claimed, and by this account
//   POST   /v1/homes/{home_id}/e2e                  { envelope }: a sealed request, answered sealed
//   POST   /v1/homes/{home_id}/invitations          { invitation_id, email, expires_at }
//   GET    /v1/homes/{home_id}/members              who belongs to the home, with their key ids (the owner only)
//   DELETE /v1/homes/{home_id}/members/{user_id}    the owner removes someone; anyone may leave
//   POST   /v1/join                                 { home_id, invitation_id, envelope }: accept an invitation
//
// All need the session cookie; they answer CORS with credentials only for the app's origins, and
// refuse changes from any other origin.

import { appOrigins, currentUser } from "./accounts.js";
import { json, problem, readText } from "./http.js";
import { PURGE_GRACE_MS, forgetInvitations } from "./invitations.js";
import { noteKeyUsed, validKeyId } from "./member-keys.js";

const HOME_ID = /^[0-9a-f]{32}$/;
const SHORT_ID = /^[0-9a-f]{8}$/;
const USER_ID = /^[0-9a-f]{32}$/;
const CLAIM_TOKEN = /^[0-9a-f]{48}$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// The driver refuses sealed requests over 64 KiB (Remote.MAX_REQUEST_BYTES), i.e. 128 KiB of base64.
const MAX_REQUEST_CT = 128 * 1024;
const MAX_BODY_BYTES = MAX_REQUEST_CT + 4096;
const MAX_INVITATION_MS = 7 * 24 * 3600 * 1000;
// Controllers' clocks may run a little fast (the lock allows 2 minutes).
const INVITATION_SKEW_MS = 10 * 60 * 1000;
// Pending invitations one account may have registered for one home (the controller allows 20).
const MAX_PENDING_PER_MEMBER = 20;

// The driver's codes (driver/src/cloud/remote.lua) as HTTP answers.
const CODES = {
  UNKNOWN_KEY: [403, "This device's key is not known to the home; it may have been revoked"],
  BAD_MAC: [400, "The home could not verify the sealed request"],
  BAD_ENVELOPE: [400, "The sealed request is malformed"],
  BAD_REQUEST: [400, "The sealed request is not a valid request"],
  STALE: [400, "The request's time is too far from the home's clock"],
  REPLAYED: [409, "This request was already received"],
  TOO_LARGE: [413, "The request is too large"],
  LOCK_UNAVAILABLE: [503, "The home cannot seal remote requests (its lock self-test failed)"],
  INVITATION_NOT_FOUND: [404, "The invitation was used, revoked or has expired"],
  INVALID_CLAIM: [403, "The claim token is wrong or has expired; get a new one at home"],
  KEY_LIMIT_REACHED: [409, "The home already has as many API keys as it allows"],
  INTERNAL: [502, "The home failed to answer"],
};

function iso(ms = Date.now()) {
  return new Date(ms).toISOString();
}

function log(event, fields) {
  console.log(JSON.stringify({ event, ...fields }));
}

function driverProblem(code) {
  const [status, detail] = CODES[code] ?? [502, `The home refused the request (${code})`];
  return problem(status, CODES[code] ? code : "HOME_REFUSED", detail);
}

async function body(request) {
  try {
    const text = await readText(request, MAX_BODY_BYTES);
    if (text === null) {
      return null;
    }
    const value = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

// Only the envelope's own fields go on to the home.
function cleanEnvelope(envelope) {
  return { v: 1, home: envelope.home, key: envelope.key, iv: envelope.iv, ct: envelope.ct, mac: envelope.mac };
}

function validEnvelope(envelope, homeId, key) {
  return (
    envelope &&
    typeof envelope === "object" &&
    envelope.v === 1 &&
    envelope.home === homeId &&
    typeof envelope.key === "string" &&
    SHORT_ID.test(envelope.key) &&
    (key === undefined || envelope.key === key) &&
    typeof envelope.iv === "string" &&
    envelope.iv.length === 24 &&
    BASE64.test(envelope.iv) &&
    typeof envelope.ct === "string" &&
    envelope.ct.length > 0 &&
    envelope.ct.length <= MAX_REQUEST_CT &&
    BASE64.test(envelope.ct) &&
    typeof envelope.mac === "string" &&
    envelope.mac.length === 44 &&
    BASE64.test(envelope.mac)
  );
}

// Sends an e2e, join or claim message to the home's relay object and returns its reply (or a
// problem Response: offline, timeout, disconnected).
async function relay(env, homeId, message) {
  const stub = env.HOME_RELAY.get(env.HOME_RELAY.idFromName(homeId));
  const response = await stub.fetch("https://home-relay/message", {
    method: "POST",
    headers: { "X-DirectorLink-Home": homeId, "content-type": "application/json" },
    body: JSON.stringify(message),
  });
  if (!response.ok) {
    // A fetched Response's headers are read-only; the copy can take the CORS headers.
    return { response: new Response(response.body, response) };
  }
  return { reply: await response.json() };
}

async function homeStatus(env, homeId) {
  const stub = env.HOME_RELAY.get(env.HOME_RELAY.idFromName(homeId));
  const response = await stub.fetch("https://home-relay/status", { headers: { "X-DirectorLink-Home": homeId } });
  return response.ok ? response.json() : { connected: false };
}

async function member(env, homeId, userId) {
  return env.DB.prepare(
    "SELECT homes.owner_id AS owner_id, members.added_at AS added_at FROM members JOIN homes ON homes.id = members.home_id WHERE members.home_id = ? AND members.user_id = ?"
  )
    .bind(homeId, userId)
    .first();
}

async function claim(request, env, user) {
  const input = await body(request);
  if (!input || !HOME_ID.test(input.home_id ?? "") || !CLAIM_TOKEN.test(input.claim_token ?? "")) {
    return problem(400, "INVALID_REQUEST", "Send { home_id: 32 hex characters, claim_token: 48 hex characters } from your controller");
  }
  const homeId = input.home_id;
  const { reply, response } = await relay(env, homeId, { type: "claim", token: input.claim_token });
  if (response) {
    return response;
  }
  if (reply.ok !== true) {
    log("claim_refused", { home: homeId, user: user.id });
    return driverProblem(reply.code ?? "INVALID_CLAIM");
  }
  const now = iso();
  const existing = await env.DB.prepare("SELECT owner_id FROM homes WHERE id = ?").bind(homeId).first();
  const transferred = Boolean(existing && existing.owner_id !== user.id);
  const statements = [];
  if (!existing) {
    statements.push(env.DB.prepare("INSERT INTO homes (id, owner_id, claimed_at) VALUES (?, ?, ?)").bind(homeId, user.id, now));
  } else if (transferred) {
    // Whoever holds an admin key at home controls the home: the new owner starts with no one else.
    statements.push(
      env.DB.prepare("UPDATE homes SET owner_id = ?, claimed_at = ? WHERE id = ?").bind(user.id, now, homeId),
      env.DB.prepare("DELETE FROM members WHERE home_id = ? AND user_id != ?").bind(homeId, user.id),
      env.DB.prepare("DELETE FROM member_keys WHERE home_id = ? AND user_id != ?").bind(homeId, user.id),
      ...forgetInvitations(env, "home_id = ?", homeId)
    );
  }
  statements.push(env.DB.prepare("INSERT OR IGNORE INTO members (home_id, user_id, added_at) VALUES (?, ?, ?)").bind(homeId, user.id, now));
  await env.DB.batch(statements);
  log("home_claimed", { home: homeId, user: user.id, transferred });
  return json({ home_id: homeId, owner: true, transferred });
}

// Whether a home is claimed, and whether by this account: the app asks before offering to link
// it, so that nobody takes a home from its owner without being told.
async function homeInfo(env, user, homeId) {
  const home = await env.DB.prepare("SELECT owner_id FROM homes WHERE id = ?").bind(homeId).first();
  const joined = home ? await member(env, homeId, user.id) : null;
  return json({ home_id: homeId, claimed: Boolean(home), owner: Boolean(home && home.owner_id === user.id), member: Boolean(joined) });
}

async function listHomes(env, user) {
  const { results } = await env.DB.prepare(
    "SELECT homes.id AS id, homes.owner_id AS owner_id, members.added_at AS added_at FROM members JOIN homes ON homes.id = members.home_id WHERE members.user_id = ? ORDER BY members.added_at"
  )
    .bind(user.id)
    .all();
  const items = [];
  for (const row of results) {
    const status = await homeStatus(env, row.id);
    items.push({ home_id: row.id, owner: row.owner_id === user.id, added_at: row.added_at, connected: Boolean(status.connected) });
  }
  return json({ items });
}

async function e2e(request, env, user, homeId) {
  if (!(await member(env, homeId, user.id))) {
    return problem(403, "NOT_A_MEMBER", "This account does not belong to that home");
  }
  const input = await body(request);
  if (!input || !validEnvelope(input.envelope, homeId)) {
    return problem(400, "INVALID_ENVELOPE", "Send { envelope } sealed for this home (docs/ACCOUNTS.md)");
  }
  const { reply, response } = await relay(env, homeId, { type: "e2e", envelope: cleanEnvelope(input.envelope) });
  if (response) {
    return response;
  }
  if (!reply.envelope) {
    log("e2e_refused", { home: homeId, user: user.id, code: reply.code ?? null });
    return driverProblem(reply.code ?? "INTERNAL");
  }
  // The home accepted a request sealed with this key: this account holds it.
  await noteKeyUsed(env, homeId, user.id, input.envelope.key).catch((error) => log("key_note_failed", { home: homeId, error: String(error?.message ?? error) }));
  return json({ envelope: reply.envelope });
}

async function registerInvitation(request, env, user, homeId) {
  if (!(await member(env, homeId, user.id))) {
    return problem(403, "NOT_A_MEMBER", "This account does not belong to that home");
  }
  const input = await body(request);
  const email = typeof input?.email === "string" ? input.email.trim().toLowerCase() : "";
  const expires = Date.parse(input?.expires_at ?? "");
  if (!input || !SHORT_ID.test(input.invitation_id ?? "") || !EMAIL.test(email) || email.length > 254 || !Number.isFinite(expires)) {
    return problem(400, "INVALID_REQUEST", "Send { invitation_id: 8 hex characters, email, expires_at } for an invitation from your controller");
  }
  if (expires <= Date.now() || expires > Date.now() + MAX_INVITATION_MS + INVITATION_SKEW_MS) {
    return problem(400, "INVALID_REQUEST", "expires_at must be in the next 7 days");
  }
  // An invitation is bound to its email once: nobody, not even another member of the home, can
  // move it to another address. Each member has at most 20 pending here.
  const now = iso();
  const [, inserted] = await env.DB.batch([
    env.DB.prepare("DELETE FROM invitations WHERE home_id = ? AND (expires_at < ? OR accepted_by IS NOT NULL)").bind(homeId, iso(Date.now() - PURGE_GRACE_MS)),
    env.DB.prepare(
      "INSERT INTO invitations (home_id, id, email, expires_at, created_by) SELECT ?, ?, ?, ?, ? " +
        "WHERE (SELECT COUNT(*) FROM invitations WHERE home_id = ? AND created_by = ? AND accepted_by IS NULL AND expires_at > ?) < ? " +
        "ON CONFLICT (home_id, id) DO NOTHING"
    ).bind(homeId, input.invitation_id, email, iso(expires), user.id, homeId, user.id, now, MAX_PENDING_PER_MEMBER),
  ]);
  if (!inserted.meta.changes) {
    const exists = await env.DB.prepare("SELECT 1 AS found FROM invitations WHERE home_id = ? AND id = ?").bind(homeId, input.invitation_id).first();
    return exists
      ? problem(409, "INVITATION_EXISTS", "This invitation is already registered")
      : problem(429, "INVITATION_LIMIT_REACHED", `At most ${MAX_PENDING_PER_MEMBER} invitations may wait at a time; revoke some first`);
  }
  log("invitation_registered", { home: homeId, user: user.id, invitation: input.invitation_id });
  return json({ invitation_id: input.invitation_id, email, expires_at: iso(expires) }, 201);
}

async function join(request, env, user) {
  const input = await body(request);
  const homeId = input?.home_id;
  if (!input || !HOME_ID.test(homeId ?? "") || !SHORT_ID.test(input.invitation_id ?? "") || !validEnvelope(input.envelope, homeId, input.invitation_id)) {
    return problem(400, "INVALID_REQUEST", "Send { home_id, invitation_id, envelope } from the invitation link");
  }
  const invitation = await env.DB.prepare("SELECT email, expires_at, accepted_by FROM invitations WHERE home_id = ? AND id = ?")
    .bind(homeId, input.invitation_id)
    .first();
  if (!invitation || !invitation.email || invitation.accepted_by || invitation.expires_at < iso()) {
    return problem(404, "INVITATION_NOT_FOUND", "The invitation was used, revoked or has expired; ask for a new one");
  }
  // The account's email, or the email of one of its sign-ins (a Google address added to an account
  // made with Apple's Hide My Email, for instance).
  const mine =
    invitation.email === user.email ||
    Boolean(await env.DB.prepare("SELECT 1 AS found FROM identities WHERE user_id = ? AND email = ?").bind(user.id, invitation.email).first());
  if (!mine) {
    log("join_email_mismatch", { home: homeId, user: user.id, invitation: input.invitation_id });
    return problem(403, "EMAIL_MISMATCH", "This invitation is for another email address; sign in with that account, or ask for an invitation for this one");
  }
  const { reply, response } = await relay(env, homeId, { type: "join", invitation: input.invitation_id, envelope: cleanEnvelope(input.envelope) });
  if (response) {
    return response;
  }
  if (reply.ok !== true || !reply.envelope) {
    log("join_refused", { home: homeId, user: user.id, code: reply.code ?? null });
    return driverProblem(reply.code ?? "INTERNAL");
  }
  // The controller has made the key; membership follows only while the invitation is still
  // pending here (a change of owner meanwhile tombstones it), and the used invitation goes. The
  // sealed answer goes back either way, with whether this account is now a member.
  const now = iso();
  const pending = "EXISTS (SELECT 1 FROM invitations WHERE home_id = ? AND id = ? AND email = ? AND accepted_by IS NULL)";
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      await env.DB.batch([
        env.DB.prepare(`INSERT OR IGNORE INTO members (home_id, user_id, added_at) SELECT ?, ?, ? WHERE ${pending}`).bind(
          homeId,
          user.id,
          now,
          homeId,
          input.invitation_id,
          invitation.email
        ),
        // The new key is this account's (revoking it at home ends the membership).
        ...(validKeyId(reply.key_id)
          ? [
              env.DB.prepare(
                `INSERT INTO member_keys (home_id, key_id, user_id, added_at) SELECT ?, ?, ?, ? WHERE ${pending} ON CONFLICT (home_id, key_id) DO UPDATE SET user_id = excluded.user_id`
              ).bind(homeId, reply.key_id, user.id, now, homeId, input.invitation_id, invitation.email),
            ]
          : []),
        env.DB.prepare("DELETE FROM invitations WHERE home_id = ? AND id = ? AND email = ? AND accepted_by IS NULL").bind(homeId, input.invitation_id, invitation.email),
      ]);
      break;
    } catch (error) {
      log("join_record_failed", { home: homeId, user: user.id, attempt, error: String(error?.message ?? error) });
    }
  }
  const joined = Boolean(await member(env, homeId, user.id).catch(() => null));
  log("invitation_accepted", { home: homeId, user: user.id, invitation: input.invitation_id, member: joined });
  return json({ home_id: homeId, envelope: reply.envelope, member: joined });
}

async function listMembers(env, user, homeId) {
  const row = await member(env, homeId, user.id);
  if (!row || row.owner_id !== user.id) {
    return problem(403, "OWNER_ONLY", "Only the home's owner sees its members");
  }
  const [{ results }, { results: keys }] = await env.DB.batch([
    env.DB.prepare(
      "SELECT users.id AS id, users.email AS email, users.name AS name, members.added_at AS added_at FROM members JOIN users ON users.id = members.user_id WHERE members.home_id = ? ORDER BY members.added_at"
    ).bind(homeId),
    env.DB.prepare("SELECT user_id, key_id FROM member_keys WHERE home_id = ? ORDER BY added_at").bind(homeId),
  ]);
  return json({
    items: results.map((r) => ({
      user_id: r.id,
      email: r.email,
      name: r.name,
      owner: r.id === user.id,
      added_at: r.added_at,
      key_ids: keys.filter((key) => key.user_id === r.id).map((key) => key.key_id),
    })),
  });
}

async function removeMember(env, user, homeId, userId) {
  const row = await member(env, homeId, user.id);
  if (!row) {
    return problem(403, "NOT_A_MEMBER", "This account does not belong to that home");
  }
  const self = userId === user.id;
  if (!self && row.owner_id !== user.id) {
    return problem(403, "OWNER_ONLY", "Only the home's owner removes others");
  }
  if (self && row.owner_id === user.id) {
    return problem(409, "OWNER_CANNOT_LEAVE", "The owner stays; another account can claim the home at home instead");
  }
  const [{ meta }] = await env.DB.batch([
    env.DB.prepare("DELETE FROM members WHERE home_id = ? AND user_id = ?").bind(homeId, userId),
    env.DB.prepare("DELETE FROM member_keys WHERE home_id = ? AND user_id = ?").bind(homeId, userId),
  ]);
  if (!meta.changes) {
    return problem(404, "NOT_FOUND", "That account does not belong to the home");
  }
  log("member_removed", { home: homeId, user: user.id, removed: userId });
  return new Response(null, { status: 204 });
}

const ROUTES = [
  [/^\/v1\/homes\/claim$/, { POST: (r, env, user) => claim(r, env, user) }],
  [/^\/v1\/homes$/, { GET: (r, env, user) => listHomes(env, user) }],
  [/^\/v1\/homes\/([0-9a-f]{32})$/, { GET: (r, env, user, m) => homeInfo(env, user, m[1]) }],
  [/^\/v1\/homes\/([0-9a-f]{32})\/e2e$/, { POST: (r, env, user, m) => e2e(r, env, user, m[1]) }],
  [/^\/v1\/homes\/([0-9a-f]{32})\/invitations$/, { POST: (r, env, user, m) => registerInvitation(r, env, user, m[1]) }],
  [/^\/v1\/homes\/([0-9a-f]{32})\/members$/, { GET: (r, env, user, m) => listMembers(env, user, m[1]) }],
  [/^\/v1\/homes\/([0-9a-f]{32})\/members\/([0-9a-f]{32})$/, { DELETE: (r, env, user, m) => removeMember(env, user, m[1], m[2]) }],
  [/^\/v1\/join$/, { POST: (r, env, user) => join(r, env, user) }],
];

function cors(request, env) {
  const origin = request.headers.get("Origin");
  if (!origin || !appOrigins(env).includes(origin)) {
    return null;
  }
  return { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Credentials": "true", Vary: "Origin" };
}

// Answers the routes above; null for any other path.
export async function handleHomes(request, env) {
  const path = new URL(request.url).pathname;
  let route = null;
  let match = null;
  for (const [pattern, methods] of ROUTES) {
    match = pattern.exec(path);
    if (match) {
      route = methods;
      break;
    }
  }
  if (!route) {
    return path.startsWith("/v1/homes") ? problem(404, "NOT_FOUND", `${path} is not a DirectorLink endpoint`) : null;
  }
  const headers = cors(request, env);
  const withCors = (response) => {
    for (const [name, value] of Object.entries(headers ?? {})) {
      response.headers.set(name, value);
    }
    return response;
  };
  if (request.method === "OPTIONS") {
    if (!headers) {
      return problem(403, "ORIGIN_NOT_ALLOWED", "Only the DirectorLink app may call this");
    }
    return new Response(null, {
      status: 204,
      headers: { ...headers, "Access-Control-Allow-Methods": Object.keys(route).join(", "), "Access-Control-Allow-Headers": "Content-Type", "Access-Control-Max-Age": "600" },
    });
  }
  const handler = route[request.method];
  if (!handler) {
    return withCors(problem(405, "METHOD_NOT_ALLOWED", `Only ${Object.keys(route).join(", ")} is allowed here`, { Allow: Object.keys(route).join(", ") }));
  }
  if (request.method !== "GET" && !headers) {
    return problem(403, "ORIGIN_NOT_ALLOWED", "Only the DirectorLink app may call this");
  }
  const user = await currentUser(request, env);
  if (!user) {
    return withCors(problem(401, "NOT_SIGNED_IN", "Sign in first"));
  }
  return withCors(await handler(request, env, user, match));
}
