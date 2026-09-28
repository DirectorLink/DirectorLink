// ID tokens (OpenID Connect) from the sign-in providers (google.js, apple.js): an RS256 JWT, checked
// against the provider's published signing keys.

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

async function signingKey(jwksUrl, kid, provider) {
  let jwks;
  try {
    jwks = await (await fetch(jwksUrl)).json();
  } catch (error) {
    throw new SignInError("PROVIDER_UNREACHABLE", `Could not read ${provider}'s signing keys: ${error}`);
  }
  const jwk = Array.isArray(jwks?.keys) ? jwks.keys.find((key) => key.kid === kid) : null;
  if (!jwk) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token is signed with an unknown key");
  }
  return crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
}

// Checks signature (RS256, the provider's current keys), issuer, audience, expiry, issue time and
// the nonce of this sign-in. Returns the claims.
export async function verifyJwt(idToken, { jwksUrl, issuers, audience, nonce, provider, now = Date.now() }) {
  const parts = typeof idToken === "string" ? idToken.split(".") : [];
  const header = parts.length === 3 ? decodeJson(parts[0]) : null;
  const claims = parts.length === 3 ? decodeJson(parts[1]) : null;
  if (!header || !claims || header.alg !== "RS256" || typeof header.kid !== "string") {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token is not a signed JWT");
  }
  const key = await signingKey(jwksUrl, header.kid, provider);
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
  if (!issuers.includes(claims.iss)) {
    throw new SignInError("INVALID_ID_TOKEN", `The ID token was not issued by ${provider}`);
  }
  if (!audience || !audiences.includes(audience)) {
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
  if (typeof claims.sub !== "string" || claims.sub === "" || claims.sub.length > 255) {
    throw new SignInError("INVALID_ID_TOKEN", "The ID token names no account");
  }
  return claims;
}

// Providers write booleans as JSON booleans or as the strings "true"/"false" (Apple).
export function isTrue(value) {
  return value === true || value === "true";
}
