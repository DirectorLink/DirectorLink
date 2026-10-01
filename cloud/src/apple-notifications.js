// Apple's server-to-server notifications about Sign in with Apple accounts (ADR-041): Apple posts
// {"payload": "<JWT>"} to POST /auth/apple/notifications, the endpoint registered on the primary App
// ID (io.directorlink.app). The JWT is checked like an ID token (apple.js verifyNotification).
//
//   consent-revoked   the person stopped using Sign in with Apple for DirectorLink
//   account-deleted   the person deleted their Apple Account (older documents: account-delete)
//                     → that Apple sign-in is removed; an account left without any sign-in is
//                       signed out everywhere. After consent-revoked it is kept for the same Apple
//                       ID to come back (for UNUSED_DAYS, accounts.js); after account-deleted it
//                       keeps nothing of the person: deleted without a home, emptied with one
//                       (accounts.js forgetAccountWithoutSignIn). A home, its members and keys are
//                       never touched.
//   email-disabled    the person turned Hide My Email forwarding off, or on again: the stored
//   email-enabled     address follows the one Apple gives, if any (nothing else is stored about it)
//
// Each is safe to receive twice, and one that happened before the person last signed in with that
// Apple ID (a late or replayed one) changes nothing. Anyone can post here: the body is read up to
// 16 KiB, Apple's signing keys are cached (jwt.js), and each notification is a few D1 batches.

import { forgetAccountWithoutSignIn } from "./accounts.js";
import { verifyNotification } from "./apple.js";
import { json, methodNotAllowed, problem, readText } from "./http.js";
import { SignInError } from "./jwt.js";

const MAX_BODY_BYTES = 16 * 1024;

function log(event, fields) {
  console.log(JSON.stringify({ event, ...fields }));
}

// Signed in with this Apple ID again after the event: what it said is not news any more (the
// person consented again, or Apple gave the address it has now). Apple gives the time in whole
// seconds.
const stale = (identity, event) => event.time + 1000 <= Date.parse(identity.last_sign_in_at);

// Removes the Apple sign-in; returns the outcome for the log.
async function removeAppleIdentity(env, identity, event) {
  if (stale(identity, event)) {
    return "stale";
  }
  const { results } = await env.DB.prepare("SELECT provider, subject FROM identities WHERE user_id = ? ORDER BY created_at").bind(identity.user_id).all();
  const kept = results.find((row) => !(row.provider === "apple" && row.subject === event.subject));
  if (kept) {
    // As when the person removes it in Settings: the account's email then follows the one it keeps.
    await env.DB.batch([
      env.DB.prepare("DELETE FROM identities WHERE provider = 'apple' AND subject = ?").bind(event.subject),
      env.DB.prepare("UPDATE users SET provider = ?, subject = ? WHERE id = ? AND provider = 'apple' AND subject = ?").bind(kept.provider, kept.subject, identity.user_id, event.subject),
    ]);
    return "identity_removed";
  }
  // Its only sign-in: every session ends, and nobody can sign in to it. After consent-revoked the
  // account keeps its homes and memberships (an owner's family keeps its access), and still records
  // the Apple ID it began with, so the same Apple ID signing in again later gets it back
  // (accounts.js accountFor). An Apple Account that was deleted never comes back: the account then
  // keeps nothing of the person.
  await env.DB.batch([
    env.DB.prepare("DELETE FROM identities WHERE provider = 'apple' AND subject = ?").bind(event.subject),
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(identity.user_id),
  ]);
  if (event.type === "account-deleted") {
    return forgetAccountWithoutSignIn(env, identity.user_id);
  }
  return "signed_out_everywhere";
}

// Hide My Email forwarding changed: only the address is stored, and only if Apple sent one.
async function updateEmail(env, identity, event) {
  if (stale(identity, event)) {
    return "stale";
  }
  if (!event.email) {
    return "unchanged";
  }
  await env.DB.batch([
    env.DB.prepare("UPDATE identities SET email = ? WHERE provider = 'apple' AND subject = ?").bind(event.email, event.subject),
    // The account's email follows the identity it began with, as at sign-in.
    env.DB.prepare("UPDATE users SET email = ? WHERE id = ? AND provider = 'apple' AND subject = ?").bind(event.email, identity.user_id, event.subject),
  ]);
  return "email_updated";
}

export async function handleAppleNotification(request, env) {
  if (request.method !== "POST") {
    return methodNotAllowed("POST");
  }
  if (!env.APPLE_APP_ID) {
    return problem(503, "NOTIFICATIONS_NOT_CONFIGURED", "Apple's notifications are not set up on this server (APPLE_APP_ID)");
  }
  const text = await readText(request, MAX_BODY_BYTES);
  let payload = null;
  try {
    payload = JSON.parse(text ?? "")?.payload;
  } catch {
    payload = null;
  }
  if (typeof payload !== "string") {
    return problem(400, "INVALID_REQUEST", "Send {\"payload\": \"<JWT>\"} as Apple does");
  }
  let event;
  try {
    event = await verifyNotification(env, payload);
  } catch (error) {
    if (!(error instanceof SignInError)) {
      throw error;
    }
    // The audience it named, if any: Apple's public id of an app, never a person's.
    log("apple_notification_refused", { code: error.code, detail: error.message, aud: error.audience ?? null });
    return problem(error.code === "PROVIDER_UNREACHABLE" ? 503 : 400, error.code === "PROVIDER_UNREACHABLE" ? "PROVIDER_UNREACHABLE" : "INVALID_NOTIFICATION", error.message);
  }
  const identity = await env.DB.prepare("SELECT user_id, last_sign_in_at FROM identities WHERE provider = 'apple' AND subject = ?").bind(event.subject).first();
  let outcome = "unknown_account";
  if (identity) {
    outcome = event.type === "email-disabled" || event.type === "email-enabled" ? await updateEmail(env, identity, event) : await removeAppleIdentity(env, identity, event);
  }
  // Our account id only: never Apple's id for the person or the address.
  log("apple_notification", { type: event.type, user: identity?.user_id ?? null, outcome });
  return json({ ok: true });
}
