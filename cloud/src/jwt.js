// ID tokens (OpenID Connect) from the sign-in providers (google.js, apple.js), and Apple's
// notifications about its accounts: an RS256 JWT, checked against the provider's published signing
// keys.

import { fromBase64url } from "./http.js";

// Clocks may differ a little between the provider and this Worker.
const CLOCK_SKEW_SECONDS = 300;

export class SignInError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

export function decodeJson(part) {
  try {
    return JSON.parse(new TextDecoder().decode(fromBase64url(part)));
  } catch {
    return null;
  }
}

// Each provider's signing keys are kept for an hour, and asked for again early only when a token
// names a key not among them, at most once a minute: made-up tokens posted to this Worker (Apple's
// notifications are open to anyone) cannot make it ask the provider again and again.
const KEYS_KEEP_MS = 3600 * 1000;
const KEYS_RETRY_MS = 60 * 1000;
const signingKeys = new Map(); // JWKS URL -> { keys, at }

async function readKeys(jwksUrl, provider, kept) {
  try {
    const jwks = await (await fetch(jwksUrl)).json();
    const entry = { keys: Array.isArray(jwks?.keys) ? jwks.keys : [], at: Date.now() };
    signingKeys.set(jwksUrl, entry);
    return entry;
  } catch (error) {
    if (kept) {
      return kept;
    }
    throw new SignInError("PROVIDER_UNREACHABLE", `Could not read ${provider}'s signing keys: ${error}`);
  }
}

async function signingKey(jwksUrl, kid, provider) {
  let entry = signingKeys.get(jwksUrl);
  const age = entry ? Date.now() - entry.at : Infinity;
  if (age > KEYS_KEEP_MS || (age > KEYS_RETRY_MS && !entry.keys.some((key) => key.kid === kid))) {
    entry = await readKeys(jwksUrl, provider, entry);
  }
  const jwk = entry.keys.find((key) => key.kid === kid);
  if (!jwk) {
    throw new SignInError("INVALID_ID_TOKEN", "The token is signed with an unknown key");
  }
  return crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
}

// Checks a JWT the provider signed: signature (RS256, the provider's current keys), issuer,
// audience, and, when it has them, expiry and issue time. Returns the claims. Apple's
// notifications (apple.js) are checked with this alone.
export async function verifySignedJwt(token, { jwksUrl, issuers, audience, provider, now = Date.now() }) {
  const parts = typeof token === "string" ? token.split(".") : [];
  const header = parts.length === 3 ? decodeJson(parts[0]) : null;
  const claims = parts.length === 3 ? decodeJson(parts[1]) : null;
  if (!header || !claims || typeof claims !== "object" || header.alg !== "RS256" || typeof header.kid !== "string") {
    throw new SignInError("INVALID_ID_TOKEN", "The token is not a signed JWT");
  }
  const key = await signingKey(jwksUrl, header.kid, provider);
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  let signature;
  try {
    signature = fromBase64url(parts[2]);
  } catch {
    throw new SignInError("INVALID_ID_TOKEN", "The token's signature is not base64url");
  }
  if (!(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed))) {
    throw new SignInError("INVALID_ID_TOKEN", "The token's signature does not match");
  }

  const seconds = Math.floor(now / 1000);
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!issuers.includes(claims.iss)) {
    throw new SignInError("INVALID_ID_TOKEN", `The token was not issued by ${provider}`);
  }
  if (!audience || !audiences.includes(audience)) {
    throw new SignInError("INVALID_ID_TOKEN", "The token is for another application");
  }
  if (claims.exp !== undefined && (typeof claims.exp !== "number" || claims.exp + CLOCK_SKEW_SECONDS < seconds)) {
    throw new SignInError("INVALID_ID_TOKEN", "The token has expired");
  }
  if (typeof claims.iat === "number" && claims.iat - CLOCK_SKEW_SECONDS > seconds) {
    throw new SignInError("INVALID_ID_TOKEN", "The token is from the future");
  }
  return claims;
}

// An ID token: a signed JWT (above) that has an expiry, the nonce of this sign-in and the person.
// Returns the claims.
export async function verifyJwt(idToken, { jwksUrl, issuers, audience, nonce, provider, now = Date.now() }) {
  const claims = await verifySignedJwt(idToken, { jwksUrl, issuers, audience, provider, now });
  if (typeof claims.exp !== "number") {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token has no expiry");
  }
  if (typeof claims.nonce !== "string" || claims.nonce !== nonce) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token belongs to another sign-in");
  }
  if (typeof claims.sub !== "string" || claims.sub === "" || claims.sub.length > 255) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token names no account");
  }
  return claims;
}

// Providers write booleans as JSON booleans or as the strings "true"/"false" (Apple).
export function isTrue(value) {
  return value === true || value === "true";
}
