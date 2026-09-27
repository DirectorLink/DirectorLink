// Accounts (docs/ACCOUNTS.md): sign in with Google, the session, and deleting the account.
//
//   GET    /auth/google/start?return_to=<app URL>   → Google, then back to the app
//   GET    /auth/google/callback                     (Google redirects here)
//   POST   /auth/logout                              ends this session
//   GET    /v1/me                                    the signed-in account, or 401
//   DELETE /v1/me                                    deletes the account and all its sessions
//
// The session is a random token in the `__Host-dl_session` cookie of api.directorlink.io; D1 keeps
// only its SHA-256. The app calls /v1/me and /auth/logout with `credentials: "include"`; only the
// app's own origins (APP_ORIGINS) get CORS answers, and changes are refused from any other origin.

import { SignInError, authorizationUrl, challengeFor, configured, exchangeCode, verifyIdToken } from "./google.js";
import { json, methodNotAllowed, problem, randomHex, randomToken, readCookie, setCookie, sha256Hex } from "./http.js";

const SESSION_COOKIE = "__Host-dl_session";
const SIGN_IN_COOKIE = "__Host-dl_signin";
const SESSION_SECONDS = 30 * 24 * 3600;
const SIGN_IN_SECONDS = 10 * 60;
const CALLBACK_PATH = "/auth/google/callback";

// Google sends the browser back to exactly the address registered for the client, so it is
// configured rather than taken from the request.
function callbackUrl(env) {
  return new URL(CALLBACK_PATH, env.PUBLIC_URL || "https://api.directorlink.io").toString();
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

// The app learns the outcome from ?signin=… (it removes it from the address bar).
function backToApp(returnTo, outcome, headers = []) {
  const url = new URL(returnTo);
  url.searchParams.set("signin", outcome);
  const response = new Response(null, { status: 302, headers: { Location: url.toString(), "Cache-Control": "no-store" } });
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

async function startSignIn(request, env) {
  if (!configured(env)) {
    return problem(503, "SIGN_IN_NOT_CONFIGURED", "Google sign-in is not set up on this server yet");
  }
  const url = new URL(request.url);
  const returnTo = safeReturn(env, url.searchParams.get("return_to"));
  const state = randomToken();
  const nonce = randomToken();
  const verifier = randomToken(48);
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sign_ins WHERE expires_at < ?").bind(iso(now)),
    env.DB.prepare("INSERT INTO sign_ins (state_sha256, nonce, verifier, return_to, expires_at) VALUES (?, ?, ?, ?, ?)")
      .bind(await sha256Hex(state), nonce, verifier, returnTo, iso(now + SIGN_IN_SECONDS * 1000)),
  ]);
  const location = authorizationUrl(env, {
    redirectUri: callbackUrl(env),
    state,
    nonce,
    challenge: await challengeFor(verifier),
  });
  // Lax: the cookie has to come back on Google's redirect, which is a navigation from another site.
  return new Response(null, {
    status: 302,
    headers: {
      Location: location,
      "Cache-Control": "no-store",
      "Set-Cookie": setCookie(SIGN_IN_COOKIE, state, { maxAge: SIGN_IN_SECONDS, sameSite: "Lax" }),
    },
  });
}

async function finishSignIn(request, env) {
  const url = new URL(request.url);
  const state = url.searchParams.get("state") ?? "";
  const clearSignIn = ["Set-Cookie", setCookie(SIGN_IN_COOKIE, "", { maxAge: 0, sameSite: "Lax" })];

  // The state must be the one this browser started, and each works once.
  const cookieState = readCookie(request, SIGN_IN_COOKIE);
  const row = state
    ? await env.DB.prepare("DELETE FROM sign_ins WHERE state_sha256 = ? RETURNING nonce, verifier, return_to, expires_at")
        .bind(await sha256Hex(state))
        .first()
    : null;
  const returnTo = safeReturn(env, row?.return_to);
  if (!row || !cookieState || cookieState !== state || row.expires_at < iso(Date.now())) {
    return backToApp(returnTo, "expired", [clearSignIn]);
  }
  const error = url.searchParams.get("error");
  if (error) {
    return backToApp(returnTo, error === "access_denied" ? "cancelled" : "failed", [clearSignIn]);
  }
  const code = url.searchParams.get("code");
  if (!code) {
    return backToApp(returnTo, "failed", [clearSignIn]);
  }

  let person;
  try {
    const idToken = await exchangeCode(env, {
      code,
      redirectUri: callbackUrl(env),
      verifier: row.verifier,
    });
    person = await verifyIdToken(env, idToken, { nonce: row.nonce });
  } catch (failure) {
    if (failure instanceof SignInError) {
      console.log(JSON.stringify({ event: "sign_in_refused", code: failure.code, detail: failure.message }));
      return backToApp(returnTo, failure.code === "EMAIL_NOT_VERIFIED" ? "unverified" : "failed", [clearSignIn]);
    }
    throw failure;
  }

  const now = Date.now();
  const existing = await env.DB.prepare("SELECT id FROM users WHERE provider = 'google' AND subject = ?").bind(person.subject).first();
  const userId = existing?.id ?? randomHex(16);
  const token = randomToken();
  await env.DB.batch([
    existing
      ? env.DB.prepare("UPDATE users SET email = ?, name = ?, last_sign_in_at = ? WHERE id = ?").bind(person.email, person.name, iso(now), userId)
      : env.DB.prepare("INSERT INTO users (id, provider, subject, email, name, created_at, last_sign_in_at) VALUES (?, 'google', ?, ?, ?, ?, ?)")
          .bind(userId, person.subject, person.email, person.name, iso(now), iso(now)),
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ? AND expires_at < ?").bind(userId, iso(now)),
    env.DB.prepare("INSERT INTO sessions (token_sha256, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
      .bind(await sha256Hex(token), userId, iso(now), iso(now + SESSION_SECONDS * 1000)),
  ]);
  console.log(JSON.stringify({ event: "signed_in", user: userId, new_account: !existing }));
  return backToApp(returnTo, "ok", [clearSignIn, ["Set-Cookie", setCookie(SESSION_COOKIE, token, { maxAge: SESSION_SECONDS })]]);
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
    return json({ id: user.id, email: user.email, name: user.name, created_at: user.created_at }, 200, headers);
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
  if (path === "/auth/google/start") {
    return request.method === "GET" ? startSignIn(request, env) : methodNotAllowed();
  }
  if (path === CALLBACK_PATH) {
    return request.method === "GET" ? finishSignIn(request, env) : methodNotAllowed();
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
