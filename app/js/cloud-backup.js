// Automatic backups to the account (ADR-048, docs/BACKUP.md). An admin sets a backup password here;
// this browser makes an X25519 key pair from it (PBKDF2-SHA-256 with a random salt, as a backup
// file's key is made) and gives the controller only the public key, the salt and the iterations.
// Each day the controller seals its backup to that key (driver/src/cloud/backup_seal.lua) and
// sends it to the account, which keeps the last 7 and cannot open them. To restore one, an admin
// types the password: this browser makes the private key again, opens the backup and hands the
// document to the restore preview, as for a file (app/js/backup.js). The password never leaves
// this browser. tests/vectors/cloud_backup.json is shared with the driver.

import { BackupFileError, DOCUMENT_FORMAT, ITERATIONS } from "./backup.js";
import { newScalar } from "./cpace.js";
import { fromBase64, toBase64 } from "./lock.js";
import { getHomeBackup } from "./remote.js";
import { api } from "./session.js";

export const SEALED_FORMAT = "directorlink-cloud-backup";
export const SEALED_VERSION = 1;
export const CIPHER = "X25519-AES-256-CBC-HMAC-SHA256";
export const KDF = "PBKDF2-SHA-256";
export const LABEL = "DirectorLink cloud backup v1";
// A backup's own iterations are used to open it, within these (so that a damaged one cannot keep
// the browser busy for minutes); the driver takes keys made with 100,000 to 5,000,000.
const MAX_ITERATIONS = 5000000;
const BASE = Uint8Array.from({ length: 32 }, (_, index) => (index === 0 ? 9 : 0));

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const toHex = (bytes) => Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");

// Which backup password a public key is: its first 8 bytes in hex (the account lists each backup
// with it).
export const keyIdOf = (publicKey) => toHex(publicKey.slice(0, 8));

// The backup password's key pair: scalar(u) (WebCrypto's X25519 where it has it) and the public
// key's bytes.
export async function backupKeyPair(password, salt, iterations) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, material, 256));
  const scalar = await newScalar(bits);
  return { scalar, publicKey: await scalar(BASE) };
}

// What PUT /v1/backup/automatic takes for `password`: { public_key, salt, iterations, kdf }, and
// the key's id.
export async function makeBackupKey(password, { iterations = ITERATIONS, salt = crypto.getRandomValues(new Uint8Array(16)) } = {}) {
  const { publicKey } = await backupKeyPair(password, salt, iterations);
  return { body: { public_key: toBase64(publicKey), salt: toBase64(salt), iterations, kdf: KDF }, keyId: keyIdOf(publicKey) };
}

async function hmac(key, text) {
  const imported = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", imported, encoder.encode(text)));
}

function decoded(text, length) {
  try {
    const bytes = fromBase64(text);
    return length === undefined || bytes.length === length ? bytes : null;
  } catch {
    return null;
  }
}

// The sealed backup's text, opened with the backup password: the document. Throws BackupFileError
// (WRONG_PASSWORD also for a changed backup, NOT_A_BACKUP, NEWER_FILE).
export async function openCloudBackup(text, password) {
  let sealed;
  try {
    sealed = JSON.parse(text);
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  if (!sealed || sealed.format !== SEALED_FORMAT) throw new BackupFileError("NOT_A_BACKUP");
  if (Number.isInteger(sealed.version) && sealed.version > SEALED_VERSION) throw new BackupFileError("NEWER_FILE");
  const salt = decoded(sealed.salt, 16);
  const epk = decoded(sealed.epk, 32);
  const iv = decoded(sealed.iv, 16);
  const mac = decoded(sealed.mac, 32);
  const ct = decoded(sealed.ct);
  if (
    sealed.version !== SEALED_VERSION ||
    sealed.cipher !== CIPHER ||
    sealed.kdf !== KDF ||
    !Number.isInteger(sealed.iterations) ||
    sealed.iterations < 1 ||
    sealed.iterations > MAX_ITERATIONS ||
    !/^[0-9a-f]{16}$/.test(sealed.key_id ?? "") ||
    !salt ||
    !epk ||
    !iv ||
    !mac ||
    !ct ||
    ct.length === 0 ||
    ct.length % 16 !== 0
  ) {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  const { scalar, publicKey } = await backupKeyPair(password, salt, sealed.iterations);
  const shared = await scalar(epk);
  if (!shared) throw new BackupFileError("NOT_A_BACKUP");
  const lock = await hmac(shared, `${LABEL}|${sealed.epk}|${toBase64(publicKey)}`);
  const [encKey, macKey] = await Promise.all([hmac(lock, "enc"), hmac(lock, "mac")]);
  const verifier = await crypto.subtle.importKey("raw", macKey, { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const input = `${LABEL}|${sealed.key_id}|${sealed.salt}|${sealed.iterations}|${sealed.epk}|${sealed.iv}|${sealed.ct}`;
  // Nothing is decrypted before the MAC is right: another password gives another key.
  if (!(await crypto.subtle.verify("HMAC", verifier, mac, encoder.encode(input)))) throw new BackupFileError("WRONG_PASSWORD");
  let plaintext;
  try {
    const key = await crypto.subtle.importKey("raw", encKey, { name: "AES-CBC" }, false, ["decrypt"]);
    plaintext = decoder.decode(await crypto.subtle.decrypt({ name: "AES-CBC", iv }, key, ct));
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  let document;
  try {
    document = JSON.parse(plaintext);
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  if (!document || document.format !== DOCUMENT_FORMAT) throw new BackupFileError("NOT_A_BACKUP");
  return document;
}

// ---- With the controller and the account ------------------------------------------------------

// GET /v1/backup/automatic: { enabled, key, time, running, last, remote }.
export const automaticStatus = () => api("/v1/backup/automatic");

// Sets (or changes) the backup password: only its public key goes to the controller.
export async function setBackupPassword(password) {
  const { body } = await makeBackupKey(password);
  return api("/v1/backup/automatic", { method: "PUT", body });
}

export const turnOffAutomatic = () => api("/v1/backup/automatic", { method: "DELETE" });

export const backUpNow = () => api("/v1/backup/automatic/run", { method: "POST" });

// Downloads one of the home's backups and opens it with the password: the document.
export async function openAccountBackup(homeId, backupId, password) {
  const backup = await getHomeBackup(homeId, backupId);
  if (typeof backup?.data !== "string") throw new BackupFileError("NOT_A_BACKUP");
  return openCloudBackup(backup.data, password);
}
