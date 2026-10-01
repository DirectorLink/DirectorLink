// The providers' signing keys in cloud/src/jwt.js (ADR-041): kept for an hour, asked for again for
// an unknown key id at most once a minute, one read at a time for everyone waiting, and kept when
// a read fails. Runs the Worker's own module in Node, with the provider's answers and the clock
// under the test's control (no Worker needed).
//   node --test tests/cloud/jwt.test.mjs

import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";

import { verifySignedJwt } from "../../cloud/src/jwt.js";

const ISSUER = "https://appleid.apple.com";
const AUDIENCE = "io.directorlink.app";
const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
const JWK = { ...pair.publicKey.export({ format: "jwk" }), kid: "good", alg: "RS256", use: "sig" };

let clock = Date.parse("2026-10-01T00:00:00Z");
Date.now = () => clock;

// The provider's key address: how it answers, and how often it was asked.
let answer = "keys";
let fetches = 0;
globalThis.fetch = async () => {
  fetches += 1;
  await new Promise((resolve) => setTimeout(resolve, 20));
  switch (answer) {
    case "down":
      throw new TypeError("network error");
    case "html":
      return new Response("<html>503</html>", { status: 503, headers: { "content-type": "text/html" } });
    case "json-error":
      return new Response(JSON.stringify({ error: "server_error" }), { status: 503, headers: { "content-type": "application/json" } });
    case "no-keys":
      return new Response(JSON.stringify({ keys: [] }), { headers: { "content-type": "application/json" } });
    default:
      return new Response(JSON.stringify({ keys: [JWK] }), { headers: { "content-type": "application/json" } });
  }
};

function token(kid) {
  const header = b64(JSON.stringify({ alg: "RS256", kid }));
  const payload = b64(JSON.stringify({ iss: ISSUER, aud: AUDIENCE, iat: Math.floor(clock / 1000) }));
  return `${header}.${payload}.${b64(sign("RSA-SHA256", Buffer.from(`${header}.${payload}`), pair.privateKey))}`;
}

let urls = 0;
const keysAt = () => `https://keys-${(urls += 1)}.example/auth/keys`;
const check = (url, kid) =>
  verifySignedJwt(token(kid), { jwksUrl: url, issuers: [ISSUER], audience: AUDIENCE, provider: "Apple", now: clock }).then(
    () => "ok",
    (error) => error.code
  );
const reset = () => {
  answer = "keys";
  fetches = 0;
};

test("tokens that arrive together share one read of the keys", async () => {
  reset();
  const url = keysAt();
  assert.deepEqual(new Set(await Promise.all(Array.from({ length: 10 }, () => check(url, "good")))), new Set(["ok"]));
  assert.equal(fetches, 1, "a cold start");
  clock += 61_000;
  fetches = 0;
  const made = await Promise.all(Array.from({ length: 50 }, (_, index) => check(url, `made-up-${index}`)));
  assert.equal(fetches, 1, "50 made-up key ids a minute later: one read");
  assert.deepEqual(new Set(made), new Set(["INVALID_ID_TOKEN"]));
  await Promise.all(Array.from({ length: 50 }, (_, index) => check(url, `again-${index}`)));
  assert.equal(fetches, 1, "and none more within the minute");
  assert.equal(await check(url, "good"), "ok");
});

for (const failure of ["down", "html", "json-error", "no-keys"]) {
  test(`a failed read (${failure}) keeps the keys, and counts as the minute's try`, async () => {
    reset();
    const url = keysAt();
    assert.equal(await check(url, "good"), "ok");
    clock += 61_000;
    answer = failure;
    fetches = 0;
    for (let index = 0; index < 20; index += 1) assert.equal(await check(url, `made-up-${index}`), "INVALID_ID_TOKEN");
    assert.equal(fetches, 1, "one try, not one per post");
    assert.equal(await check(url, "good"), "ok", "real tokens still check against the keys it had");
    // After an hour the keys are old, but a provider that cannot answer does not take them away.
    clock += 3600_000;
    fetches = 0;
    assert.equal(await check(url, "good"), "ok");
    assert.equal(fetches, 1);
    answer = "keys";
    assert.equal(await check(url, "good"), "ok", "within the minute: the kept keys");
    assert.equal(fetches, 1);
  });
}

test("with no keys yet and the provider down, it asks once a minute and says the provider is unreachable", async () => {
  reset();
  const url = keysAt();
  answer = "down";
  for (let index = 0; index < 10; index += 1) assert.equal(await check(url, "whatever"), "PROVIDER_UNREACHABLE");
  assert.equal(fetches, 1);
  clock += 61_000;
  answer = "keys";
  assert.equal(await check(url, "good"), "ok");
  assert.equal(fetches, 2);
});
