// A fake Apple for the cloud tests: Sign in with Apple's token endpoint, which checks the Worker's
// ES256 client secret the way Apple does, and signing keys for its ID tokens. Also the steps of a
// sign-in through the Worker (Apple posts its answer back as a form).

import { generateKeyPairSync, randomBytes, sign, verify } from "node:crypto";
import { createServer } from "node:http";

import { cookiesOf } from "./fake-google.mjs";
import { freePort } from "./worker.mjs";

export const SERVICES_ID = "io.directorlink.test";
export const TEAM_ID = "TEAMID1234";
export const KEY_ID = "KEYID56789";

function base64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function decode(part) {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
}

export async function startFakeApple() {
  // The Sign in with Apple key (.p8): the Worker signs with it, Apple checks with its public half.
  const clientKey = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const privatePem = clientKey.privateKey.export({ format: "pem", type: "pkcs8" });
  const signingKey = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const kid = "apple-test-key";
  const jwk = { ...signingKey.publicKey.export({ format: "jwk" }), kid, alg: "RS256", use: "sig" };
  const stranger = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const codes = new Map();
  const secrets = [];
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;

  function idToken(claims, key = signingKey.privateKey) {
    const header = base64url(JSON.stringify({ alg: "RS256", kid, typ: "JWT" }));
    const payload = base64url(JSON.stringify(claims));
    return `${header}.${payload}.${base64url(sign("RSA-SHA256", Buffer.from(`${header}.${payload}`), key))}`;
  }

  // Apple's checks of the client secret: ES256 with our key, kid, issuer (team), subject (services
  // id), audience (Apple) and a short life.
  function clientSecretProblem(secret) {
    const parts = String(secret).split(".");
    if (parts.length !== 3) return "not a JWT";
    const header = decode(parts[0]);
    const claims = decode(parts[1]);
    const ok = verify("sha256", Buffer.from(`${parts[0]}.${parts[1]}`), { key: clientKey.publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(parts[2], "base64url"));
    const now = Math.floor(Date.now() / 1000);
    if (!ok) return "bad signature";
    if (header.alg !== "ES256" || header.kid !== KEY_ID) return "bad header";
    if (claims.iss !== TEAM_ID || claims.sub !== SERVICES_ID || claims.aud !== url) return "bad claims";
    if (!(claims.iat <= now + 5 && claims.exp > now && claims.exp - claims.iat <= 15777000)) return "bad times";
    return null;
  }

  const server = createServer(async (request, response) => {
    const answer = (status, body) => {
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
    };
    if (request.url === "/auth/keys") {
      return answer(200, { keys: [jwk] });
    }
    if (request.url === "/auth/token" && request.method === "POST") {
      let text = "";
      for await (const chunk of request) text += chunk;
      const form = new URLSearchParams(text);
      secrets.push(form.get("client_secret"));
      const problem = clientSecretProblem(form.get("client_secret"));
      if (problem) {
        return answer(400, { error: "invalid_client", detail: problem });
      }
      const grant = codes.get(form.get("code"));
      codes.delete(form.get("code"));
      if (!grant || form.get("grant_type") !== "authorization_code" || form.get("client_id") !== SERVICES_ID || form.get("redirect_uri") !== grant.redirectUri) {
        return answer(400, { error: "invalid_grant" });
      }
      const now = Math.floor(Date.now() / 1000);
      const claims = {
        iss: url,
        aud: SERVICES_ID,
        sub: grant.person.sub,
        email: grant.person.email,
        email_verified: "true",
        is_private_email: grant.person.private ? "true" : "false",
        iat: now,
        exp: now + 600,
        nonce: grant.nonce,
        nonce_supported: true,
        auth_time: now,
        ...grant.claims,
      };
      return answer(200, { access_token: "a", token_type: "Bearer", expires_in: 3600, refresh_token: "r", id_token: idToken(claims, grant.forged ? stranger.privateKey : undefined) });
    }
    return answer(404, { error: "not_found" });
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));

  return {
    url,
    privatePem,
    secrets,
    // The person approves the request at Apple: returns the code Apple would post back.
    approve(authorizationUrl, { person = APPLE_PERSON, claims = {}, forged = false } = {}) {
      const params = new URL(authorizationUrl).searchParams;
      const code = base64url(randomBytes(16));
      codes.set(code, { nonce: params.get("nonce"), redirectUri: params.get("redirect_uri"), person, claims, forged });
      return code;
    },
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

export const APPLE_PERSON = { sub: "001234.apple-user.0001", email: "Noam@Example.com", firstName: "Noam", lastName: "Cohen" };

// The Worker's .dev.vars for this fake Apple (a .dev.vars line cannot hold the PEM's line breaks).
export function appleVars(fake) {
  return {
    APPLE_SERVICES_ID: SERVICES_ID,
    APPLE_TEAM_ID: TEAM_ID,
    APPLE_KEY_ID: KEY_ID,
    APPLE_PRIVATE_KEY: fake.privatePem.trim().replace(/\r?\n/g, "\\n"),
    APPLE_AUTH_URL: `${fake.url}/auth/authorize`,
    APPLE_TOKEN_URL: `${fake.url}/auth/token`,
    APPLE_JWKS_URL: `${fake.url}/auth/keys`,
    APPLE_ISSUER: fake.url,
  };
}

// Apple's form back to the Worker, as the browser posts it.
export function postBack(workerUrl, fields, cookie) {
  return fetch(`${workerUrl}/auth/apple/callback`, {
    method: "POST",
    redirect: "manual",
    headers: { "content-type": "application/x-www-form-urlencoded", origin: "https://appleid.apple.com", ...(cookie ? { Cookie: cookie } : {}) },
    body: new URLSearchParams(fields).toString(),
  });
}

// A whole sign-in with Apple as `person`; returns { response, cookie } (the session cookie header).
export async function signInWithApple(workerUrl, fake, person = APPLE_PERSON, app = "http://localhost:8080", options = {}) {
  const start = await fetch(`${workerUrl}/auth/apple/start?return_to=${encodeURIComponent(`${app}/#/settings`)}`, { redirect: "manual" });
  const location = start.headers.get("location");
  const signIn = cookiesOf(start)["__Host-dl_signin_apple"]?.value;
  const code = fake.approve(location, { person, ...options });
  const state = new URL(location).searchParams.get("state");
  const user = person.firstName ? JSON.stringify({ name: { firstName: person.firstName, lastName: person.lastName }, email: person.email }) : undefined;
  const response = await postBack(workerUrl, { state, code, ...(user && options.withUser !== false ? { user } : {}) }, `__Host-dl_signin_apple=${signIn}`);
  const session = cookiesOf(response)["__Host-dl_session"];
  return { response, location, cookie: session?.value ? `__Host-dl_session=${session.value}` : null };
}
