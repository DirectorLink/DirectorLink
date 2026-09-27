// The end-to-end lock in the browser (docs/ACCOUNTS.md), the same as the driver's
// (driver/src/cloud/lock.lua): AES-256-CBC, then an HMAC-SHA256 over the ciphertext
// (encrypt-then-MAC). The keys are derived from the device's API key, or from an invitation's
// secret. tests/vectors/lock.json checks that the app, the driver and the cloud tests agree.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export const DEVICE_LABEL = "DirectorLink e2e v1";
export const INVITATION_LABEL = "DirectorLink invite v1";

export function toBase64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function fromBase64(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function toHex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function hmac(rawKey, data) {
  const key = await crypto.subtle.importKey("raw", rawKey, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(data)));
}

// The lock of a secret: the two keys, which never leave WebCrypto, and the lock key's hex (tests).
export async function deriveLock(secret, label = DEVICE_LABEL) {
  const lock = await hmac(encoder.encode(secret), label);
  const [enc, mac] = await Promise.all([hmac(lock, "enc"), hmac(lock, "mac")]);
  return {
    lockHex: toHex(lock),
    enc: await crypto.subtle.importKey("raw", enc, { name: "AES-CBC" }, false, ["encrypt", "decrypt"]),
    mac: await crypto.subtle.importKey("raw", mac, { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]),
  };
}

export const invitationLock = (secret) => deriveLock(secret, INVITATION_LABEL);

const macInput = (envelope, dir) => `v1|${envelope.home}|${envelope.key}|${dir}|${envelope.iv}|${envelope.ct}`;

// Seals `plaintext` for `home` and `key` (a key id or an invitation id); dir is "req" or "res".
export async function seal(lock, { home, key }, dir, plaintext, iv = crypto.getRandomValues(new Uint8Array(16))) {
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-CBC", iv }, lock.enc, encoder.encode(plaintext)));
  const envelope = { v: 1, home, key, iv: toBase64(iv), ct: toBase64(ct) };
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", lock.mac, encoder.encode(macInput(envelope, dir))));
  envelope.mac = toBase64(mac);
  return envelope;
}

// The plaintext, or null when the envelope was not sealed with this lock in this direction.
// The MAC is checked before anything is decrypted.
export async function open(lock, envelope, dir) {
  try {
    const verified = await crypto.subtle.verify("HMAC", lock.mac, fromBase64(envelope.mac), encoder.encode(macInput(envelope, dir)));
    if (!verified) {
      return null;
    }
    const plaintext = await crypto.subtle.decrypt({ name: "AES-CBC", iv: fromBase64(envelope.iv) }, lock.enc, fromBase64(envelope.ct));
    return decoder.decode(plaintext);
  } catch {
    return null;
  }
}
