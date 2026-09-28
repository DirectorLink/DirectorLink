// Accounts (docs/ACCOUNTS.md): sign in with Google or Apple, the session, and deleting the account.
//
//   GET    /auth/{google|apple}/start?return_to=<app URL>   → the provider, then back to the app
//   GET    /auth/google/callback                             (Google redirects here)
//   POST   /auth/apple/callback                              (Apple posts its form here)
//   POST   /auth/logout                                      ends this session
//   GET    /v1/me                                            the signed-in account, or 401
//   DELETE /v1/me                                            deletes the account and all its sessions
//
// One account may sign in with both: a sign-in with a new identity joins the account that has the
// same verified email (identities table), so homes and invitations do not depend on the provider.
//
// The session is a random token in the `__Host-dl_session` cookie of api.directorlink.io; D1 keeps
// only its SHA-256. The app calls /v1/me and /auth/logout with `credentials: "include"`; only the
// app's own origins (APP_ORIGINS) get CORS answers, and changes are refused from any other origin.

import { apple } from "./apple.js";
import { google } from "./google.js";
import { json, methodNotAllowed, problem, randomHex, randomToken, readCookie, setCookie, sha256Hex } from "./http.js";
import { forgetInvitations } from "./invitations.js";
import { SignInError } from "./jwt.js";

const PROVIDERS = { google, apple };
const SESSION_COOKIE = "__Host-dl_session";
const SESSION_SECONDS = 30 * 24 * 3600;
const SIGN_IN_SECONDS = 10 * 60;
// The browser keeps the sign-in's state in a cookie until the provider sends it back. Google comes
// back with a redirect (a navigation: Lax is enough); Apple posts a form from its own site, which
// only a SameSite=None cookie survives.
const SIGN_IN_COOKIES = {
  google: { name: "__Host-dl_signin", sameSite: "Lax" },
  apple: { name: "__Host-dl_signin_apple", sameSite: "None" },
};
const MAX_FORM_BYTES = 16 * 1024;

// The provider sends the browser back to exactly the address registered for the client, so it is
// configured rather than taken from the request.
function callbackUrl(env, provider) {
  return new URL(`/auth/${provider}/callback`, env.PUBLIC_URL || "https://api.directorlink.io").toString();
}

export function appOrigins(env) {
  return (env.APP_ORIGINS || "https://app.directorlink.io")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);
}

function iso(ms) {
  return new Date(ms).toISOString();
}

// Where to go back to: an address of the app itself, never anywhere else.
function safeReturn(env, value) {
  const origins = appOrigins(env);
  try {
    const url = new URL(value);
    if (origins.includes(url.origin)) {
      return url.toString();
    }
  } catch {
    // Not a URL.
  }
  return `${origins[0]}/#/settings`;
}

// The app learns the outcome from ?signin=… (it removes it from the address bar). After Apple's
// form (a POST), 303 makes the browser load the app with GET.
function backToApp(returnTo, outcome, headers = [], status = 302) {
  const url = new URL(returnTo);
  url.searchParams.set("signin", outcome);
  const response = new Response(null, { status, headers: { Location: url.toString(), "Cache-Control": "no-store" } });
  for (const [name, value] of headers) {
    response.headers.append(name, value);
  }
  return response;
}

function cors(request, env) {
  const origin = request.headers.get("Origin");
  if (!origin || !appOrigins(env).includes(origin)) {
    return null;
  }
  return { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Credentials": "true", Vary: "Origin" };
}

function withHeaders(response, headers) {
  for (const [name, value] of Object.entries(headers ?? {})) {
    response.headers.set(name, value);
  }
  return response;
}

async function startSignIn(request, env, provider) {
  if (!provider.configured(env)) {
    return problem(503, "SIGN_IN_NOT_CONFIGURED", `${provider.label} sign-in is not set up on this server yet`);
  }
  const url = new URL(request.url);
  const returnTo = safeReturn(env, url.searchParams.get("return_to"));
  const state = randomToken();
  const nonce = randomToken();
  const verifier = provider.usesVerifier ? randomToken(48) : "";
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sign_ins WHERE expires_at < ?").bind(iso(now)),
    env.DB.prepare("INSERT INTO sign_ins (state_sha256, nonce, verifier, return_to, expires_at, provider) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(await sha256Hex(state), nonce, verifier, returnTo, iso(now + SIGN_IN_SECONDS * 1000), provider.name),
  ]);
  const location = await provider.authorizationUrl(env, { redirectUri: callbackUrl(env, provider.name), state, nonce, verifier });
  const cookie = SIGN_IN_COOKIES[provider.name];
  return new Response(null, {
    status: 302,
    headers: {
      Location: location,
      "Cache-Control": "no-store",
      "Set-Cookie": setCookie(cookie.name, state, { maxAge: SIGN_IN_SECONDS, sameSite: cookie.sameSite }),
    },
  });
}

// The callback's parameters: Google's in the query, Apple's in a posted form.
async function callbackParams(request) {
  if (request.method !== "POST") {
    return new URL(request.url).searchParams;
  }
  if (Number(request.headers.get("content-length") ?? 0) > MAX_FORM_BYTES) {
    return new URLSearchParams();
  }
  const text = await request.text();
  return new URLSearchParams(text.length > MAX_FORM_BYTES ? "" : text);
}

// The account for a person the provider vouched for: the one this identity belongs to, else the
// one with the same verified email (a second provider for it), else a new one.
async function accountFor(env, provider, person) {
  const now = iso(Date.now());
  const identity = await env.DB.prepare("SELECT user_id FROM identities WHERE provider = ? AND subject = ?").bind(provider, person.subject).first();
  if (identity) {
    // The account's email follows the identity it was created with; a later provider's does not.
    await env.DB.batch([
      env.DB.prepare("UPDATE identities SET email = ?, last_sign_in_at = ? WHERE provider = ? AND subject = ?").bind(person.email, now, provider, person.subject),
      env.DB.prepare(
        "UPDATE users SET email = CASE WHEN provider = ? AND subject = ? THEN ? ELSE email END, name = COALESCE(?, name), last_sign_in_at = ? WHERE id = ?"
      ).bind(provider, person.subject, person.email, person.name, now, identity.user_id),
    ]);
    return { userId: identity.user_id, created: false, linked: false };
  }
  const same = await env.DB.prepare("SELECT id FROM users WHERE email = ? ORDER BY created_at LIMIT 1").bind(person.email).first();
  if (same) {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO identities (provider, subject, user_id, email, created_at, last_sign_in_at) VALUES (?, ?, ?, ?, ?, ?)")
        .bind(provider, person.subject, same.id, person.email, now, now),
      env.DB.prepare("UPDATE users SET name = COALESCE(name, ?), last_sign_in_at = ? WHERE id = ?").bind(person.name, now, same.id),
    ]);
    return { userId: same.id, created: false, linked: true };
  }
  const userId = randomHex(16);
  await env.DB.batch([
    env.DB.prepare("INSERT INTO users (id, provider, subject, email, name, created_at, last_sign_in_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
      .bind(userId, provider, person.subject, person.email, person.name, now, now),
    env.DB.prepare("INSERT INTO identities (provider, subject, user_id, email, created_at, last_sign_in_at) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(provider, person.subject, userId, person.email, now, now),
  ]);
  return { userId, created: true, linked: false };
}

async function finishSignIn(request, env, provider) {
  const params = await callbackParams(request);
  const state = params.get("state") ?? "";
  const cookie = SIGN_IN_COOKIES[provider.name];
  const clearSignIn = ["Set-Cookie", setCookie(cookie.name, "", { maxAge: 0, sameSite: cookie.sameSite })];
  const status = request.method === "POST" ? 303 : 302;

  // The state must be the one this browser started, with this provider, and each works once.
  const cookieState = readCookie(request, cookie.name);
  const row = state
    ? await env.DB.prepare("DELETE FROM sign_ins WHERE state_sha256 = ? RETURNING nonce, verifier, return_to, expires_at, provider")
        .bind(await sha256Hex(state))
        .first()
    : null;
  const returnTo = safeReturn(env, row?.return_to);
  if (!row || row.provider !== provider.name || !cookieState || cookieState !== state || row.expires_at < iso(Date.now())) {
    return backToApp(returnTo, "expired", [clearSignIn], status);
  }
  const error = params.get("error");
  if (error) {
    const cancelled = error === "access_denied" || error === "user_cancelled_authorize";
    return backToApp(returnTo, cancelled ? "cancelled" : "failed", [clearSignIn], status);
  }
  const code = params.get("code");
  if (!code) {
    return backToApp(returnTo, "failed", [clearSignIn], status);
  }

  let person;
  try {
    person = await provider.finish(env, {
      code,
      redirectUri: callbackUrl(env, provider.name),
      verifier: row.verifier,
      nonce: row.nonce,
      user: params.get("user"),
    });
  } catch (failure) {
    if (failure instanceof SignInError) {
      console.log(JSON.stringify({ event: "sign_in_refused", provider: provider.name, code: failure.code, detail: failure.message }));
      return backToApp(returnTo, failure.code === "EMAIL_NOT_VERIFIED" ? "unverified" : "failed", [clearSignIn], status);
    }
    throw failure;
  }

  const now = Date.now();
  const { userId, created, linked } = await accountFor(env, provider.name, person);
  const token = randomToken();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ? AND expires_at < ?").bind(userId, iso(now)),
    env.DB.prepare("INSERT INTO sessions (token_sha256, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
      .bind(await sha256Hex(token), userId, iso(now), iso(now + SESSION_SECONDS * 1000)),
  ]);
  console.log(JSON.stringify({ event: "signed_in", provider: provider.name, user: userId, new_account: created, linked }));
  return backToApp(returnTo, "ok", [clearSignIn, ["Set-Cookie", setCookie(SESSION_COOKIE, token, { maxAge: SESSION_SECONDS })]], status);
}

// The account of this request's session, or null.
export async function currentUser(request, env) {
  const token = readCookie(request, SESSION_COOKIE);
  if (!token) {
    return null;
  }
  const row = await env.DB.prepare(
    "SELECT users.id, users.email, users.name, users.created_at, sessions.expires_at FROM sessions JOIN users ON users.id = sessions.user_id WHERE sessions.token_sha256 = ?"
  )
    .bind(await sha256Hex(token))
    .first();
  if (!row || row.expires_at < iso(Date.now())) {
    return null;
  }
  return { id: row.id, email: row.email, name: row.name, created_at: row.created_at, token };
}

function notSignedIn() {
  return problem(401, "NOT_SIGNED_IN", "Sign in first", { "WWW-Authenticate": 'Cookie realm="DirectorLink"' });
}

const clearSession = () => setCookie(SESSION_COOKIE, "", { maxAge: 0 });

async function me(request, env, headers) {
  if (request.method === "GET") {
    const user = await currentUser(request, env);
    if (!user) {
      return withHeaders(notSignedIn(), headers);
    }
    const { results } = await env.DB.prepare("SELECT provider FROM identities WHERE user_id = ? ORDER BY created_at").bind(user.id).all();
    return json({ id: user.id, email: user.email, name: user.name, created_at: user.created_at, providers: results.map((row) => row.provider) }, 200, headers);
  }
  if (request.method === "DELETE") {
    const user = await currentUser(request, env);
    if (!user) {
      return withHeaders(notSignedIn(), headers);
    }
    await env.DB.batch([
      env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM invitations WHERE home_id IN (SELECT id FROM homes WHERE owner_id = ?)").bind(user.id),
      env.DB.prepare("DELETE FROM members WHERE home_id IN (SELECT id FROM homes WHERE owner_id = ?)").bind(user.id),
      env.DB.prepare("DELETE FROM homes WHERE owner_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM members WHERE user_id = ?").bind(user.id),
      ...forgetInvitations(env, "accepted_by = ? OR created_by = ? OR email = ?", user.id, user.id, user.email),
      env.DB.prepare("DELETE FROM identities WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM users WHERE id = ?").bind(user.id),
    ]);
    console.log(JSON.stringify({ event: "account_deleted", user: user.id }));
    return new Response(null, { status: 204, headers: { ...headers, "Set-Cookie": clearSession(), "Cache-Control": "no-store" } });
  }
  return withHeaders(methodNotAllowed("GET, DELETE"), headers);
}

async function logout(request, env, headers) {
  if (request.method !== "POST") {
    return withHeaders(methodNotAllowed("POST"), headers);
  }
  const token = readCookie(request, SESSION_COOKIE);
  if (token) {
    await env.DB.prepare("DELETE FROM sessions WHERE token_sha256 = ?").bind(await sha256Hex(token)).run();
  }
  return new Response(null, { status: 204, headers: { ...headers, "Set-Cookie": clearSession(), "Cache-Control": "no-store" } });
}

// Routes this module answers; null for any other path.
export async function handleAccounts(request, env) {
  const path = new URL(request.url).pathname;
  const auth = /^\/auth\/(google|apple)\/(start|callback)$/.exec(path);
  if (auth) {
    const provider = PROVIDERS[auth[1]];
    if (auth[2] === "start") {
      return request.method === "GET" ? startSignIn(request, env, provider) : methodNotAllowed();
    }
    // Google redirects (GET); Apple posts a form.
    const method = provider.name === "apple" ? "POST" : "GET";
    return request.method === method ? finishSignIn(request, env, provider) : methodNotAllowed(method);
  }
  if (path !== "/v1/me" && path !== "/auth/logout") {
    return null;
  }

  const headers = cors(request, env);
  if (request.method === "OPTIONS") {
    if (!headers) {
      return problem(403, "ORIGIN_NOT_ALLOWED", "Only the DirectorLink app may call this");
    }
    return new Response(null, {
      status: 204,
      headers: {
        ...headers,
        "Access-Control-Allow-Methods": path === "/v1/me" ? "GET, DELETE" : "POST",
        "Access-Control-Allow-Headers": "Content-Type",
        "Access-Control-Max-Age": "600",
      },
    });
  }
  // Changes only from the app's own pages: a form or script on another site cannot sign
  // someone out or delete their account.
  if (request.method !== "GET" && !headers) {
    return problem(403, "ORIGIN_NOT_ALLOWED", "Only the DirectorLink app may call this");
  }
  return path === "/v1/me" ? me(request, env, headers) : logout(request, env, headers);
}
