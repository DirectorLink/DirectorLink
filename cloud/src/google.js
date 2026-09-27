// Sign in with Google: the OAuth 2.0 authorization-code flow with PKCE, run entirely by this
// Worker (no Google script in the app's pages). Google's endpoints can be replaced through
// environment variables so the tests can run a fake Google (tests/cloud/accounts.test.mjs).

import { base64url, fromBase64url } from "./http.js";

const GOOGLE = {
  auth: "https://accounts.google.com/o/oauth2/v2/auth",
  token: "https://oauth2.googleapis.com/token",
  jwks: "https://www.googleapis.com/oauth2/v3/certs",
  issuers: ["https://accounts.google.com", "accounts.google.com"],
};

// Clocks may differ a little between Google and this Worker.
const CLOCK_SKEW_SECONDS = 300;

export class SignInError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function endpoints(env) {
  return {
    auth: env.GOOGLE_AUTH_URL || GOOGLE.auth,
    token: env.GOOGLE_TOKEN_URL || GOOGLE.token,
    jwks: env.GOOGLE_JWKS_URL || GOOGLE.jwks,
    issuers: env.GOOGLE_ISSUER ? [env.GOOGLE_ISSUER] : GOOGLE.issuers,
  };
}

export function configured(env) {
  return Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET);
}

// The PKCE challenge for a verifier: base64url(SHA-256(verifier)).
export async function challengeFor(verifier) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(new Uint8Array(digest));
}

export function authorizationUrl(env, { redirectUri, state, nonce, challenge }) {
  const url = new URL(endpoints(env).auth);
  url.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "openid email profile",
    state,
    nonce,
    code_challenge: challenge,
    code_challenge_method: "S256",
    prompt: "select_account",
  }).toString();
  return url.toString();
}

// Trades the code from the redirect for Google's ID token.
export async function exchangeCode(env, { code, redirectUri, verifier }) {
  let response;
  try {
    response = await fetch(endpoints(env).token, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({
        code,
        client_id: env.GOOGLE_CLIENT_ID,
        client_secret: env.GOOGLE_CLIENT_SECRET,
        redirect_uri: redirectUri,
        grant_type: "authorization_code",
        code_verifier: verifier,
      }),
    });
  } catch (error) {
    throw new SignInError("GOOGLE_UNREACHABLE", `Could not reach Google: ${error}`);
  }
  const data = await response.json().catch(() => null);
  if (!response.ok || typeof data?.id_token !== "string") {
    throw new SignInError("GOOGLE_REFUSED", `Google did not accept the sign-in (${data?.error ?? response.status})`);
  }
  return data.id_token;
}

function decodeJson(part) {
  try {
    return JSON.parse(new TextDecoder().decode(fromBase64url(part)));
  } catch {
    return null;
  }
}

async function signingKey(env, kid) {
  let jwks;
  try {
    jwks = await (await fetch(endpoints(env).jwks)).json();
  } catch (error) {
    throw new SignInError("GOOGLE_UNREACHABLE", `Could not read Google's signing keys: ${error}`);
  }
  const jwk = Array.isArray(jwks?.keys) ? jwks.keys.find((key) => key.kid === kid) : null;
  if (!jwk) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token is signed with an unknown key");
  }
  return crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
}

// Checks the ID token the way Google documents it: signature (RS256, Google's current keys),
// issuer, audience (our client id), expiry, and the nonce of this sign-in. Returns the person.
export async function verifyIdToken(env, idToken, { nonce, now = Date.now() }) {
  const parts = idToken.split(".");
  const header = parts.length === 3 ? decodeJson(parts[0]) : null;
  const claims = parts.length === 3 ? decodeJson(parts[1]) : null;
  if (!header || !claims || header.alg !== "RS256" || typeof header.kid !== "string") {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token is not a signed JWT");
  }
  const key = await signingKey(env, header.kid);
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  let signature;
  try {
    signature = fromBase64url(parts[2]);
  } catch {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token's signature is not base64url");
  }
  if (!(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed))) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token's signature does not match");
  }

  const seconds = Math.floor(now / 1000);
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!endpoints(env).issuers.includes(claims.iss)) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token was not issued by Google");
  }
  if (!audiences.includes(env.GOOGLE_CLIENT_ID)) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token is for another application");
  }
  if (typeof claims.exp !== "number" || claims.exp + CLOCK_SKEW_SECONDS < seconds) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token has expired");
  }
  if (typeof claims.iat === "number" && claims.iat - CLOCK_SKEW_SECONDS > seconds) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token is from the future");
  }
  if (typeof claims.nonce !== "string" || claims.nonce !== nonce) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token belongs to another sign-in");
  }
  if (typeof claims.sub !== "string" || claims.sub === "") {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token names no account");
  }
  if (typeof claims.email !== "string" || !(claims.email_verified === true || claims.email_verified === "true")) {
    throw new SignInError("EMAIL_NOT_VERIFIED", "This Google account has no verified email address");
  }
  return {
    subject: claims.sub,
    email: claims.email.toLowerCase(),
    name: typeof claims.name === "string" && claims.name.trim() ? claims.name.trim().slice(0, 200) : null,
  };
}
