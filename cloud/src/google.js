// Sign in with Google: the OAuth 2.0 authorization-code flow with PKCE, run entirely by this
// Worker (no Google script in the app's pages). Google's endpoints can be replaced through
// environment variables so the tests can run a fake Google (tests/cloud/accounts.test.mjs).

import { base64url } from "./http.js";
import { SignInError, isTrue, verifyJwt } from "./jwt.js";

const GOOGLE = {
  auth: "https://accounts.google.com/o/oauth2/v2/auth",
  token: "https://oauth2.googleapis.com/token",
  jwks: "https://www.googleapis.com/oauth2/v3/certs",
  issuers: ["https://accounts.google.com", "accounts.google.com"],
};

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

export async function authorizationUrl(env, { redirectUri, state, nonce, verifier }) {
  const url = new URL(endpoints(env).auth);
  url.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: "openid email profile",
    state,
    nonce,
    code_challenge: await challengeFor(verifier),
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
    throw new SignInError("PROVIDER_UNREACHABLE", `Could not reach Google: ${error}`);
  }
  const data = await response.json().catch(() => null);
  if (!response.ok || typeof data?.id_token !== "string") {
    throw new SignInError("PROVIDER_REFUSED", `Google did not accept the sign-in (${data?.error ?? response.status})`);
  }
  return data.id_token;
}

// Checks the ID token the way Google documents it (jwt.js), and that the email is verified.
// Returns the person.
export async function verifyIdToken(env, idToken, { nonce, now = Date.now() }) {
  const ends = endpoints(env);
  const claims = await verifyJwt(idToken, { jwksUrl: ends.jwks, issuers: ends.issuers, audience: env.GOOGLE_CLIENT_ID, nonce, now, provider: "Google" });
  if (typeof claims.email !== "string" || !isTrue(claims.email_verified)) {
    throw new SignInError("EMAIL_NOT_VERIFIED", "This Google account has no verified email address");
  }
  return {
    subject: claims.sub,
    email: claims.email.toLowerCase(),
    name: typeof claims.name === "string" && claims.name.trim() ? claims.name.trim().slice(0, 200) : null,
  };
}

// The Google side of accounts.js: how a sign-in starts and comes back.
export const google = {
  name: "google",
  label: "Google",
  configured,
  usesVerifier: true,
  authorizationUrl,
  async finish(env, { code, redirectUri, verifier, nonce }) {
    const idToken = await exchangeCode(env, { code, redirectUri, verifier });
    return verifyIdToken(env, idToken, { nonce });
  },
};
