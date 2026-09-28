// A fake Google for the cloud tests: an OAuth token endpoint and signing keys, with ID tokens
// signed by a test key. Also the steps of a sign-in through the Worker.

import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { createServer } from "node:http";

import { freePort } from "./worker.mjs";

export const CLIENT_ID = "test-client";
export const CLIENT_SECRET = "test-secret";

function base64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function keyPair(kid) {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
  return { kid, privateKey, jwk: { ...publicKey.export({ format: "jwk" }), kid, alg: "RS256", use: "sig" } };
}

export async function startFakeGoogle() {
  const key = keyPair("google-test-key");
  const stranger = keyPair("google-test-key"); // same kid, other key: a forged signature
  const codes = new Map();
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;

  function idToken(claims, signer = key) {
    const header = base64url(JSON.stringify({ alg: "RS256", kid: signer.kid, typ: "JWT" }));
    const payload = base64url(JSON.stringify(claims));
    const signature = sign("RSA-SHA256", Buffer.from(`${header}.${payload}`), signer.privateKey);
    return `${header}.${payload}.${base64url(signature)}`;
  }

  const server = createServer(async (request, response) => {
    const answer = (status, body) => {
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
    };
    if (request.url === "/certs") {
      return answer(200, { keys: [key.jwk] });
    }
    if (request.url === "/token" && request.method === "POST") {
      let text = "";
      for await (const chunk of request) text += chunk;
      const form = new URLSearchParams(text);
      const grant = codes.get(form.get("code"));
      codes.delete(form.get("code"));
      const challenge = base64url(createHash("sha256").update(form.get("code_verifier") ?? "").digest());
      if (
        !grant ||
        form.get("grant_type") !== "authorization_code" ||
        form.get("client_id") !== CLIENT_ID ||
        form.get("client_secret") !== CLIENT_SECRET ||
        form.get("redirect_uri") !== grant.redirectUri ||
        challenge !== grant.challenge
      ) {
        return answer(400, { error: "invalid_grant" });
      }
      const now = Math.floor(Date.now() / 1000);
      const claims = {
        iss: url,
        aud: CLIENT_ID,
        sub: grant.person.sub,
        email: grant.person.email,
        email_verified: true,
        name: grant.person.name,
        iat: now,
        exp: now + 3600,
        nonce: grant.nonce,
        ...grant.claims,
      };
      return answer(200, { id_token: idToken(claims, grant.forged ? stranger : key), token_type: "Bearer", expires_in: 3599 });
    }
    return answer(404, { error: "not_found" });
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));

  return {
    url,
    // The person approves the request at Google: returns the code Google would redirect with.
    approve(authorizationUrl, { person = PERSON, claims = {}, forged = false } = {}) {
      const params = new URL(authorizationUrl).searchParams;
      const code = base64url(randomBytes(16));
      codes.set(code, { nonce: params.get("nonce"), challenge: params.get("code_challenge"), redirectUri: params.get("redirect_uri"), person, claims, forged });
      return code;
    },
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

export const PERSON = { sub: "google-user-1", email: "Dana.Levi@Example.com", name: "Dana Levi" };


// The Worker's .dev.vars for this fake Google.
export function googleVars(google, app, publicUrl) {
  return {
    GOOGLE_CLIENT_ID: CLIENT_ID,
    GOOGLE_CLIENT_SECRET: CLIENT_SECRET,
    GOOGLE_AUTH_URL: `${google.url}/auth`,
    GOOGLE_TOKEN_URL: `${google.url}/token`,
    GOOGLE_JWKS_URL: `${google.url}/certs`,
    GOOGLE_ISSUER: google.url,
    APP_ORIGINS: app,
    PUBLIC_URL: publicUrl,
  };
}

export function cookiesOf(response) {
  const cookies = {};
  for (const line of response.headers.getSetCookie()) {
    const [pair, ...attributes] = line.split(";").map((part) => part.trim());
    const index = pair.indexOf("=");
    cookies[pair.slice(0, index)] = { value: pair.slice(index + 1), attributes: attributes.map((a) => a.toLowerCase()) };
  }
  return cookies;
}

// A whole sign-in as `person`; returns the session cookie header value.
export async function signInAs(workerUrl, google, person, app) {
  const start = await fetch(`${workerUrl}/auth/google/start?return_to=${encodeURIComponent(`${app}/#/settings`)}`, { redirect: "manual" });
  const location = start.headers.get("location");
  const signIn = cookiesOf(start)["__Host-dl_signin"].value;
  const code = google.approve(location, { person });
  const state = new URL(location).searchParams.get("state");
  const back = await fetch(`${workerUrl}/auth/google/callback?${new URLSearchParams({ code, state })}`, {
    redirect: "manual",
    headers: { Cookie: `__Host-dl_signin=${signIn}` },
  });
  const session = cookiesOf(back)["__Host-dl_session"];
  if (!session?.value) {
    throw new Error(`sign-in as ${person.email} failed: ${back.headers.get("location")}`);
  }
  return `__Host-dl_session=${session.value}`;
}
