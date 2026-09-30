// Sign in with Apple: the authorization-code flow, run entirely by this Worker. Apple posts its
// answer back as a form (the only way it sends the name and email scopes), and this Worker proves
// itself to Apple with a short-lived client secret: a JWT signed (ES256) with the Sign in with
// Apple key. Apple's endpoints can be replaced through environment variables so the tests can run
// a fake Apple (tests/cloud/apple.test.mjs).
//
// Settings: APPLE_SERVICES_ID (the client id), APPLE_TEAM_ID, APPLE_KEY_ID (vars); APPLE_PRIVATE_KEY
// (secret: the .p8 file, PKCS #8 PEM). APPLE_APP_ID: the primary App ID, which Apple's
// notifications about its accounts are addressed to (apple-notifications.js).

import { base64url } from "./http.js";
import { SignInError, isTrue, verifyJwt, verifySignedJwt } from "./jwt.js";

const APPLE = {
  auth: "https://appleid.apple.com/auth/authorize",
  token: "https://appleid.apple.com/auth/token",
  jwks: "https://appleid.apple.com/auth/keys",
  issuer: "https://appleid.apple.com",
};

const CLIENT_SECRET_SECONDS = 300;

function endpoints(env) {
  return {
    auth: env.APPLE_AUTH_URL || APPLE.auth,
    token: env.APPLE_TOKEN_URL || APPLE.token,
    jwks: env.APPLE_JWKS_URL || APPLE.jwks,
    issuer: env.APPLE_ISSUER || APPLE.issuer,
  };
}

export function configured(env) {
  return Boolean(env.APPLE_SERVICES_ID && env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY);
}

export function authorizationUrl(env, { redirectUri, state, nonce }) {
  const url = new URL(endpoints(env).auth);
  url.search = new URLSearchParams({
    client_id: env.APPLE_SERVICES_ID,
    redirect_uri: redirectUri,
    response_type: "code",
    response_mode: "form_post",
    scope: "name email",
    state,
    nonce,
  })
    .toString()
    // Apple asks for %20 between scopes, not the "+" of form encoding (values hold no other spaces;
    // a "+" in a value is already %2B).
    .replace(/\+/g, "%20");
  return url.toString();
}

// The .p8 key as DER bytes. A secret keeps its line breaks; a .dev.vars line may have "\n" instead.
function pkcs8(pem) {
  const body = String(pem)
    .replace(/\\n/g, "\n")
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function encodeJson(value) {
  return base64url(new TextEncoder().encode(JSON.stringify(value)));
}

// The client secret Apple asks for instead of a fixed one (valid for 5 minutes here).
export async function clientSecret(env, now = Date.now()) {
  let key;
  try {
    key = await crypto.subtle.importKey("pkcs8", pkcs8(env.APPLE_PRIVATE_KEY), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  } catch (error) {
    throw new SignInError("PROVIDER_MISCONFIGURED", `APPLE_PRIVATE_KEY is not a P-256 PKCS #8 key: ${error}`);
  }
  const issuedAt = Math.floor(now / 1000);
  const unsigned = `${encodeJson({ alg: "ES256", kid: env.APPLE_KEY_ID, typ: "JWT" })}.${encodeJson({
    iss: env.APPLE_TEAM_ID,
    iat: issuedAt,
    exp: issuedAt + CLIENT_SECRET_SECONDS,
    aud: endpoints(env).issuer,
    sub: env.APPLE_SERVICES_ID,
  })}`;
  // WebCrypto signs ECDSA as r ‖ s, which is what JWS (ES256) wants.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${base64url(new Uint8Array(signature))}`;
}

// Trades the code from Apple's form for Apple's ID token.
export async function exchangeCode(env, { code, redirectUri }) {
  const secret = await clientSecret(env);
  let response;
  try {
    response = await fetch(endpoints(env).token, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({
        client_id: env.APPLE_SERVICES_ID,
        client_secret: secret,
        code,
        grant_type: "authorization_code",
        redirect_uri: redirectUri,
      }),
    });
  } catch (error) {
    throw new SignInError("PROVIDER_UNREACHABLE", `Could not reach Apple: ${error}`);
  }
  const data = await response.json().catch(() => null);
  if (!response.ok || typeof data?.id_token !== "string") {
    throw new SignInError("PROVIDER_REFUSED", `Apple did not accept the sign-in (${data?.error ?? response.status})`);
  }
  return data.id_token;
}

// The name Apple posts with the first sign-in only ({"name":{"firstName","lastName"}}). It is not
// signed, so it is used as a display name and nothing else.
export function nameFromForm(user) {
  try {
    const name = JSON.parse(user || "null")?.name;
    const text = [name?.firstName, name?.lastName].filter((part) => typeof part === "string" && part.trim()).map((part) => part.trim()).join(" ");
    return text ? text.slice(0, 200) : null;
  } catch {
    return null;
  }
}

// Checks Apple's ID token (jwt.js). Returns the person; `email` is null when Apple gave no verified
// address (it may leave it out for a returning Apple ID, e.g. after Hide My Email forwarding was
// turned off: the account is found by its sub, and a new one needs an email); `private` is an
// address of Apple's Hide My Email relay.
export async function verifyIdToken(env, idToken, { nonce, now = Date.now() }) {
  const ends = endpoints(env);
  const claims = await verifyJwt(idToken, { jwksUrl: ends.jwks, issuers: [ends.issuer], audience: env.APPLE_SERVICES_ID, nonce, now, provider: "Apple" });
  const verified = typeof claims.email === "string" && claims.email.includes("@") && claims.email.length <= 254 && isTrue(claims.email_verified);
  return { subject: claims.sub, email: verified ? claims.email.toLowerCase() : null, name: null, private: isTrue(claims.is_private_email) };
}

// The events Apple sends to POST /auth/apple/notifications (apple-notifications.js). Apple's
// documentation now names the last one "account-deleted"; older documents say "account-delete",
// which is taken as the same.
const EVENT_TYPES = new Set(["email-disabled", "email-enabled", "consent-revoked", "account-deleted", "account-delete"]);

// Checks one of Apple's server-to-server notifications: the `payload` of its POST, a JWT signed
// with Apple's keys (those of its ID tokens), issued by Apple, for DirectorLink's primary App ID.
// Apple addresses these to the App ID its Services ID is grouped with, not to the Services ID, so an
// ID token posted here (for the Services ID) is refused. Returns { type, subject, email, private,
// time } (`time`: when it happened, in milliseconds).
export async function verifyNotification(env, payload, now = Date.now()) {
  const ends = endpoints(env);
  const claims = await verifySignedJwt(payload, { jwksUrl: ends.jwks, issuers: [ends.issuer], audience: env.APPLE_APP_ID, provider: "Apple", now });
  // `events` is a JSON object written as a string.
  let events = claims.events;
  if (typeof events === "string") {
    try {
      events = JSON.parse(events);
    } catch {
      events = null;
    }
  }
  if (!events || typeof events !== "object" || !EVENT_TYPES.has(events.type) || typeof events.sub !== "string" || events.sub === "" || events.sub.length > 255) {
    throw new SignInError("INVALID_NOTIFICATION", "The notification names no known event and account");
  }
  // Seconds in Apple's documentation; milliseconds have been seen too.
  const at = Number(events.event_time);
  const time = Number.isFinite(at) && at > 0 ? (at < 1e12 ? at * 1000 : at) : typeof claims.iat === "number" ? claims.iat * 1000 : now;
  const email = typeof events.email === "string" && events.email.includes("@") && events.email.length <= 254 ? events.email.toLowerCase() : null;
  return { type: events.type === "account-delete" ? "account-deleted" : events.type, subject: events.sub, email, private: isTrue(events.is_private_email), time };
}

// The Apple side of accounts.js: how a sign-in starts and comes back.
export const apple = {
  name: "apple",
  label: "Apple",
  configured,
  usesVerifier: false,
  authorizationUrl: async (env, options) => authorizationUrl(env, options),
  async finish(env, { code, redirectUri, nonce, user }) {
    const idToken = await exchangeCode(env, { code, redirectUri });
    const person = await verifyIdToken(env, idToken, { nonce });
    return { ...person, name: nameFromForm(user) };
  },
};
