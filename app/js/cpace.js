// Pairing with CPace (ADR-039, docs/ACCOUNTS.md): this device proves it knows the pairing code
// without sending it, and the new key comes back sealed with a key only it and the controller
// hold. CPace is draft-irtf-cfrg-cpace's CPACE-X25519-SHA512; the controller's side is
// driver/src/auth/cpace_pairing.lua, and tests/vectors/cpace.json checks that both agree. The app
// and the API console pair this way (console/js/cpace.js is a copy, scripts/check_sites.py).
// X25519 is WebCrypto's (deriveBits, with the generator or the other side's share as the "public
// key"); browsers without it use the ladder below. Elligator 2's field math is BigInt.

import { ApiError } from "../api-client.js";
import { cpaceLock, fromBase64, open, toBase64 } from "./lock.js";

const encoder = new TextEncoder();
const EMPTY = new Uint8Array(0);

export const DSI = "CPace255";
// The channel's label (CI), also the lock's (cpaceLock): the second version of pairing's lock.
export const LABEL = "DirectorLink pair v2";
export const NONCE_BYTES = 16;
const S_IN_BYTES = 128; // SHA-512's input block

export const utf8 = (text) => encoder.encode(text);

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

// The data with its length before it (LEB128).
export function prependLen(data) {
  const length = [];
  let rest = data.length;
  do {
    const low = rest % 128;
    rest = Math.floor(rest / 128);
    length.push(rest > 0 ? low + 128 : low);
  } while (rest > 0);
  return concat(Uint8Array.from(length), data);
}

export const lvCat = (...parts) => concat(...parts.map(prependLen));

// ---- GF(2^255 - 19) ----

const P = 2n ** 255n - 19n;
const A = 486662n;
const mod = (value) => ((value % P) + P) % P;

function pow(base, exponent) {
  let result = 1n;
  let square = mod(base);
  for (let rest = exponent; rest > 0n; rest >>= 1n) {
    if (rest & 1n) result = (result * square) % P;
    square = (square * square) % P;
  }
  return result;
}

const invert = (value) => pow(value, P - 2n);

// decodeUCoordinate (RFC 7748): little-endian, bit 255 ignored.
function decodeU(bytes) {
  let value = 0n;
  for (let index = 31; index >= 0; index -= 1) {
    value = (value << 8n) | BigInt(index === 31 ? bytes[index] & 0x7f : bytes[index]);
  }
  return value;
}

function encodeU(value) {
  const out = new Uint8Array(32);
  let rest = mod(value);
  for (let index = 0; index < 32; index += 1) {
    out[index] = Number(rest & 0xffn);
    rest >>= 8n;
  }
  return out;
}

// Elligator 2 for Curve25519 (RFC 9380, section 6.7.1, Z = 2): the u-coordinate of the point the
// field element `u` (32 bytes) maps to.
export function elligator2(u) {
  const r = decodeU(u);
  const x1 = mod(-A * invert(1n + 2n * r * r));
  const gx1 = mod(x1 * (mod(x1 + A) * x1 + 1n));
  return encodeU(pow(gx1, (P - 1n) / 2n) === 1n ? x1 : -x1 - A);
}

// X25519 (RFC 7748, section 5) where WebCrypto has none.
export function x25519Ladder(scalar, u) {
  const k = Uint8Array.from(scalar);
  k[0] &= 248;
  k[31] = (k[31] & 127) | 64;
  const kn = decodeLittleEndian(k);
  const x1 = decodeU(u);
  let [x2, z2, x3, z3, swap] = [1n, 0n, x1, 1n, 0n];
  for (let t = 254n; t >= 0n; t -= 1n) {
    const bit = (kn >> t) & 1n;
    if (swap ^ bit) [x2, x3, z2, z3] = [x3, x2, z3, z2];
    swap = bit;
    const a = mod(x2 + z2);
    const aa = (a * a) % P;
    const b = mod(x2 - z2);
    const bb = (b * b) % P;
    const e = mod(aa - bb);
    const c = mod(x3 + z3);
    const d = mod(x3 - z3);
    const da = (d * a) % P;
    const cb = (c * b) % P;
    x3 = mod((da + cb) * (da + cb));
    z3 = mod(x1 * mod((da - cb) * (da - cb)));
    x2 = (aa * bb) % P;
    z2 = mod(e * (aa + 121665n * e));
  }
  if (swap) [x2, z2] = [x3, z3];
  return encodeU(x2 * invert(z2));
}

function decodeLittleEndian(bytes) {
  let value = 0n;
  for (let index = bytes.length - 1; index >= 0; index -= 1) value = (value << 8n) | BigInt(bytes[index]);
  return value;
}

// ---- X25519 and SHA-512 through WebCrypto ----

let webX25519;

function hasWebX25519() {
  webX25519 ??= crypto.subtle
    .generateKey({ name: "X25519" }, false, ["deriveBits"])
    .then(() => true)
    .catch(() => false);
  return webX25519;
}

// For tests: use the ladder even where WebCrypto has X25519.
export function useLadder(on) {
  webX25519 = on ? Promise.resolve(false) : undefined;
}

// An X25519 private key (PKCS #8) around 32 scalar bytes.
const PKCS8_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20]);

const isZero = (bytes) => bytes.every((byte) => byte === 0);

// A secret scalar, as a function from a u-coordinate to scalar * u: null for a point of low order
// (G.I, the exchange stops). WebCrypto's own key where it has X25519 (never exported); `bytes`
// (tests) sets it.
export async function newScalar(bytes) {
  if (await hasWebX25519()) {
    const privateKey = bytes
      ? await crypto.subtle.importKey("pkcs8", concat(PKCS8_PREFIX, bytes), { name: "X25519" }, false, ["deriveBits"])
      : (await crypto.subtle.generateKey({ name: "X25519" }, false, ["deriveBits"])).privateKey;
    return async (u) => {
      try {
        const point = await crypto.subtle.importKey("raw", u, { name: "X25519" }, false, []);
        const out = new Uint8Array(await crypto.subtle.deriveBits({ name: "X25519", public: point }, privateKey, 256));
        return isZero(out) ? null : out;
      } catch {
        // WebCrypto refuses a zero result itself.
        return null;
      }
    };
  }
  const secret = bytes || crypto.getRandomValues(new Uint8Array(32));
  return async (u) => {
    const out = x25519Ladder(secret, u);
    return isZero(out) ? null : out;
  };
}

export const sha512 = async (data) => new Uint8Array(await crypto.subtle.digest("SHA-512", data));

export async function hmacSha512(key, data) {
  const imported = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", imported, data));
}

// ---- CPace ----

export function generatorString(prs, ci, sid) {
  const zeros = Math.max(0, S_IN_BYTES - 1 - prependLen(prs).length - prependLen(utf8(DSI)).length);
  return lvCat(utf8(DSI), prs, new Uint8Array(zeros), ci, sid);
}

export const generator = async (prs, ci, sid) => elligator2((await sha512(generatorString(prs, ci, sid))).slice(0, 32));

// The initiator (A, the controller) speaks first: transcript_ir.
export const isk = (sid, k, ya, ada, yb, adb) => sha512(concat(lvCat(utf8(`${DSI}_ISK`), sid, k), lvCat(ya, ada), lvCat(yb, adb)));

export const macKey = (sid, key) => sha512(concat(utf8("CPaceMac"), sid, key));

export const tag = (key, share, ad) => hmacSha512(key, lvCat(share, ad));

// CI: the label, the key's name as sent ("" without) and expires_in ("" without), so nothing the
// first request asks for can be changed on the way.
export const channel = (name, expiresIn) => lvCat(utf8(LABEL), utf8(name ?? ""), utf8(expiresIn == null ? "" : String(expiresIn)));

function bytesOf(value, length) {
  try {
    const bytes = typeof value === "string" ? fromBase64(value) : null;
    return bytes?.length === length ? bytes : null;
  } catch {
    return null;
  }
}

function sameBytes(left, right) {
  if (!left || left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

// True for the answer of a controller that cannot pair this way: DirectorLink before 1.3.0 refuses
// the field (or expires_in, which it does not know either), and so does a controller whose lock
// failed its self-test.
export function refusesCpace(error) {
  const field = error?.problem?.errors?.[0]?.field;
  return error?.code === "INVALID_FIELD" && (field === "cpace" || field === "expires_in");
}

const notConfirmed = () =>
  new ApiError("The controller did not prove that it knows the pairing code: pairing stopped.", { code: "PAIRING_NOT_CONFIRMED" });

// Pairs with the code without sending it. `send(body)` posts to /v1/auth/pair and returns the
// answer (or throws ApiError); `expiresIn` asks for a key that expires (the console's, ADR-040).
// Returns the new key (NewApiKey). Throws ApiError CPACE_UNSUPPORTED when the controller cannot
// pair this way (refusesCpace): nothing about the code was sent, and the caller asks before
// pairing the old way. PAIRING_NOT_CONFIRMED: the answers did not come from a controller that
// knows the code. `testing` sets the nonce and the scalar (tests).
export async function pairWithCpace(send, { code, name, expiresIn }, testing = {}) {
  const nonce = testing.nonce || crypto.getRandomValues(new Uint8Array(NONCE_BYTES));
  const first = { name, cpace: { nonce: toBase64(nonce) } };
  if (expiresIn != null) first.expires_in = expiresIn;
  let start;
  try {
    start = await send(first);
  } catch (error) {
    if (refusesCpace(error)) {
      throw new ApiError("This controller cannot pair without sending the code.", { code: "CPACE_UNSUPPORTED", status: error.status, problem: error.problem });
    }
    throw error;
  }
  const session = start?.cpace?.session;
  const theirNonce = bytesOf(start?.cpace?.nonce, NONCE_BYTES);
  const theirShare = bytesOf(start?.cpace?.share, 32);
  if (typeof session !== "string" || !theirNonce || !theirShare) throw notConfirmed();

  const sid = concat(nonce, theirNonce);
  const g = await generator(utf8(code), channel(name, expiresIn), sid);
  const scalar = await newScalar(testing.scalar);
  const share = await scalar(g);
  const k = share && (await scalar(theirShare));
  if (!k) throw notConfirmed();
  const key = await isk(sid, k, theirShare, EMPTY, share, EMPTY);
  const confirmKey = await macKey(sid, key);
  const done = await send({ cpace: { session, share: toBase64(share), confirm: toBase64(await tag(confirmKey, share, EMPTY)) } });
  if (!sameBytes(bytesOf(done?.cpace?.confirm, 64), await tag(confirmKey, theirShare, EMPTY)) || !done?.sealed) throw notConfirmed();
  const plaintext = await open(await cpaceLock(key), done.sealed, "res");
  if (!plaintext) throw notConfirmed();
  return JSON.parse(plaintext);
}
