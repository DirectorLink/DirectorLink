// A fake push service for the alerts tests (ADR-047): it takes Web Push requests as FCM, Mozilla
// or Apple do, checks their VAPID signature (RFC 8292) with the key they name, and opens their
// encrypted message (RFC 8291) with the browser's private key, as the browser would. Each
// subscription is a fake browser with its own keys.

import { createECDH, createHmac, createDecipheriv, createPublicKey, randomBytes, verify } from "node:crypto";
import { createServer } from "node:http";

import { freePort } from "./worker.mjs";

const b64 = (bytes) => Buffer.from(bytes).toString("base64url");
const hmac = (key, data) => createHmac("sha256", key).update(data).digest();

// The VAPID key pair for the Worker's .dev.vars, as scripts/vapid_key.mjs makes it.
export function vapidVars() {
  const ecdh = createECDH("prime256v1");
  ecdh.generateKeys();
  const publicKey = ecdh.getPublicKey();
  const jwk = { kty: "EC", crv: "P-256", d: b64(ecdh.getPrivateKey()), x: b64(publicKey.subarray(1, 33)), y: b64(publicKey.subarray(33)) };
  return { VAPID_PUBLIC_KEY: b64(publicKey), VAPID_PRIVATE_KEY: JSON.stringify(jwk) };
}

// RFC 8291 from the browser's side: the message in an aes128gcm body, or null.
export function decrypt(body, browser) {
  const salt = body.subarray(0, 16);
  const idLength = body[20];
  const asPublic = body.subarray(21, 21 + idLength);
  const ciphertext = body.subarray(21 + idLength);
  const ecdhSecret = browser.ecdh.computeSecret(asPublic);
  const prkKey = hmac(browser.auth, ecdhSecret);
  const ikm = hmac(prkKey, Buffer.concat([Buffer.from("WebPush: info\0"), browser.publicKey, asPublic, Buffer.from([1])]));
  const prk = hmac(salt, ikm);
  const cek = hmac(prk, Buffer.from("Content-Encoding: aes128gcm\0\x01")).subarray(0, 16);
  const nonce = hmac(prk, Buffer.from("Content-Encoding: nonce\0\x01")).subarray(0, 12);
  const decipher = createDecipheriv("aes-128-gcm", cek, nonce);
  decipher.setAuthTag(ciphertext.subarray(ciphertext.length - 16));
  const record = Buffer.concat([decipher.update(ciphertext.subarray(0, ciphertext.length - 16)), decipher.final()]);
  // RFC 8188: the message, the delimiter 2 (the last record's), then any number of zeros.
  let end = record.length - 1;
  while (end >= 0 && record[end] === 0) end -= 1;
  if (end < 0 || record[end] !== 2) return null;
  return record.subarray(0, end).toString("utf8");
}

// RFC 8292: the Authorization header's JWT, checked against its own key `k`. Returns its claims
// and the key, or throws.
function checkVapid(header, origin) {
  const match = /^vapid t=([^,\s]+),\s*k=([A-Za-z0-9_-]+)$/.exec(header ?? "");
  if (!match) throw new Error(`not a VAPID header: ${header}`);
  const [head, claims, signature] = match[1].split(".");
  const key = Buffer.from(match[2], "base64url");
  const jwk = { kty: "EC", crv: "P-256", x: b64(key.subarray(1, 33)), y: b64(key.subarray(33)) };
  const ok = verify("sha256", Buffer.from(`${head}.${claims}`), { key: createPublicKey({ key: jwk, format: "jwk" }), dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"));
  if (!ok) throw new Error("bad VAPID signature");
  const parsed = JSON.parse(Buffer.from(claims, "base64url").toString("utf8"));
  if (JSON.parse(Buffer.from(head, "base64url").toString("utf8")).alg !== "ES256") throw new Error("not ES256");
  if (parsed.aud !== origin) throw new Error(`aud ${parsed.aud}, not ${origin}`);
  if (!(parsed.exp > Date.now() / 1000 && parsed.exp <= Date.now() / 1000 + 24 * 3600)) throw new Error(`exp ${parsed.exp}`);
  if (!parsed.sub) throw new Error("no sub");
  return { claims: parsed, key: match[2] };
}

export async function startFakePush() {
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  const browsers = new Map(); // id -> browser
  // Every request: { id, message (parsed), headers, vapid, error, status, body (its bytes) }.
  const received = [];

  const server = createServer((request, response) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const id = request.url.replace(/^\/push\//, "");
      const browser = browsers.get(id);
      const entry = { id, headers: request.headers, message: null, error: null, body: Buffer.concat(chunks) };
      try {
        if (request.method !== "POST" || !browser) throw new Error(`unknown subscription ${request.url}`);
        entry.vapid = checkVapid(request.headers.authorization, url);
        if (request.headers["content-encoding"] !== "aes128gcm") throw new Error("not aes128gcm");
        if (!(Number(request.headers.ttl) > 0)) throw new Error("no TTL");
        const text = decrypt(entry.body, browser);
        entry.message = JSON.parse(text);
      } catch (error) {
        entry.error = error.message;
      }
      // A browser that fails: its first `fails` pushes are answered `failStatus` (the service busy).
      let status = browser?.status ?? 201;
      if (!entry.error && browser.fails > 0) {
        browser.fails -= 1;
        status = browser.failStatus;
      }
      entry.status = entry.error ? 400 : status;
      received.push(entry);
      response.writeHead(entry.status, browser?.location ? { Location: browser.location } : {});
      response.end();
    });
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));

  // A new browser's push subscription, as PushSubscription.toJSON() gives it. `status`: what the
  // service answers for it (410: the browser unsubscribed; 307 with `location`: a redirect), after
  // answering its first `fails` pushes `failStatus`.
  function subscribe({ status = 201, fails = 0, failStatus = 503, location = null } = {}) {
    const ecdh = createECDH("prime256v1");
    ecdh.generateKeys();
    const id = randomBytes(12).toString("hex");
    const browser = { id, ecdh, publicKey: ecdh.getPublicKey(), auth: randomBytes(16), status, fails, failStatus, location };
    browsers.set(id, browser);
    browser.subscription = { endpoint: `${url}/push/${id}`, keys: { p256dh: b64(browser.publicKey), auth: b64(browser.auth) } };
    return browser;
  }

  // What reached `browser` (its opened messages, that the service accepted), and what failed anywhere.
  const messagesFor = (browser) => received.filter((entry) => entry.id === browser.id && entry.message && entry.status < 300).map((entry) => entry.message);
  const errors = () => received.filter((entry) => entry.error);

  return { url, received, subscribe, messagesFor, errors, close: () => new Promise((resolve) => server.close(resolve)) };
}
