// The end-to-end lock (docs/ACCOUNTS.md) in Node, for the cloud tests: plays the app and the
// controller. Checked against tests/vectors/lock.json, like the driver's and the app's.

import { createCipheriv, createDecipheriv, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

const hmac = (key, data) => createHmac("sha256", key).update(data).digest();

export function lockKey(secret, label = "DirectorLink e2e v1") {
  return hmac(Buffer.from(secret, "utf8"), label);
}

export const invitationKey = (secret) => lockKey(secret, "DirectorLink invite v1");

function subkeys(lock) {
  return { enc: hmac(lock, "enc"), mac: hmac(lock, "mac") };
}

const macInput = (e, dir) => `v1|${e.home}|${e.key}|${dir}|${e.iv}|${e.ct}`;

export function seal(lock, { home, key }, dir, plaintext, iv = randomBytes(16)) {
  const { enc, mac } = subkeys(lock);
  const cipher = createCipheriv("aes-256-cbc", enc, iv);
  const ct = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]).toString("base64");
  const envelope = { v: 1, home, key, iv: iv.toString("base64"), ct };
  envelope.mac = hmac(mac, macInput(envelope, dir)).toString("base64");
  return envelope;
}

// The plaintext, or null when the envelope was not sealed with this lock key in this direction.
export function open(lock, envelope, dir) {
  const { enc, mac } = subkeys(lock);
  const expected = hmac(mac, macInput(envelope, dir));
  const given = Buffer.from(envelope.mac ?? "", "base64");
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) {
    return null;
  }
  try {
    const decipher = createDecipheriv("aes-256-cbc", enc, Buffer.from(envelope.iv, "base64"));
    return Buffer.concat([decipher.update(Buffer.from(envelope.ct, "base64")), decipher.final()]).toString("utf8");
  } catch {
    return null;
  }
}
