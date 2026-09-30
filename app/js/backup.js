// Backups (ADR-042, docs/BACKUP.md): everything DirectorLink keeps on the controller, saved as a
// file locked with a password, and restored from one. The file is made and opened here, in this
// browser (WebCrypto): PBKDF2-SHA-256 with 600,000 iterations and a random salt makes the key,
// AES-256-GCM with a random IV locks the document, and its header (the key's salt and iterations,
// the home and the date) is authenticated with it. The password and the opened document go nowhere
// but the sealed requests to this controller (GET /v1/backup, POST /v1/restore/parts and
// POST /v1/restore); without the password nobody can open the file, DirectorLink included.

import { fromBase64, toBase64 } from "./lock.js";
import { api } from "./session.js";

export const FILE_FORMAT = "directorlink-backup-file";
export const FILE_VERSION = 1;
export const DOCUMENT_FORMAT = "directorlink-backup";
export const ITERATIONS = 600000;
export const MIN_PASSWORD = 10;
export const FILE_EXTENSION = ".dlbackup";
// A header may ask for fewer or more iterations (a file of a later version); within these only,
// so that a damaged header cannot keep the browser busy for minutes.
const MIN_ITERATIONS = 100000;
const MAX_ITERATIONS = 5000000;
// Each part of the document sent back is at most this many bytes as JSON: sealed, a request stays
// under the 64 KiB the controller takes on the home network (the driver takes parts up to 48 KiB).
export const PART_BYTES = 30000;
const TIMEOUT_MS = 60000;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Why a file could not be opened: NOT_A_BACKUP, NEWER_FILE, or WRONG_PASSWORD (which is also what a
// changed or damaged file gives: AES-GCM cannot tell them apart).
export class BackupFileError extends Error {
  constructor(code) {
    super(`The backup file could not be opened (${code})`);
    this.name = "BackupFileError";
    this.code = code;
  }
}

// "weak", "fair" or "strong": a hint while the password is typed, never a rule beyond its length.
export function passwordStrength(password) {
  const text = String(password || "");
  if (text.length < MIN_PASSWORD) return "weak";
  const kinds = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter((pattern) => pattern.test(text)).length;
  const words = text.trim().split(/[\s\-_.]+/).filter((word) => word.length >= 3).length;
  if (text.length >= 16 && (kinds >= 2 || words >= 3)) return "strong";
  if (new Set(text).size <= 3) return "weak";
  return kinds >= 3 || text.length >= 14 ? "strong" : "fair";
}

async function deriveKey(password, salt, iterations) {
  const material = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations },
    material,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
}

// The file's text for `document` (GET /v1/backup), locked with `password`.
export async function encryptBackup(document, password, { iterations = ITERATIONS } = {}) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const header = JSON.stringify({
    cipher: "AES-256-GCM",
    kdf: "PBKDF2-SHA-256",
    iterations,
    salt: toBase64(salt),
    iv: toBase64(iv),
    home: typeof document?.home?.name === "string" ? document.home.name : null,
    created_at: document?.created_at ?? null,
    driver_version: document?.driver_version ?? null,
  });
  const key = await deriveKey(password, salt, iterations);
  const data = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: encoder.encode(header) }, key, encoder.encode(JSON.stringify(document)))
  );
  return JSON.stringify({ format: FILE_FORMAT, version: FILE_VERSION, header, data: toBase64(data) }) + "\n";
}

// What the file says of itself before it is opened (not yet authenticated): { home, created_at,
// driver_version, iterations, salt, iv }. Throws BackupFileError.
export function readHeader(text) {
  let file;
  try {
    file = JSON.parse(text);
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  if (!file || file.format !== FILE_FORMAT || typeof file.header !== "string" || typeof file.data !== "string") {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  if (!Number.isInteger(file.version) || file.version > FILE_VERSION) {
    throw new BackupFileError(Number.isInteger(file.version) ? "NEWER_FILE" : "NOT_A_BACKUP");
  }
  let header;
  try {
    header = JSON.parse(file.header);
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  let salt, iv;
  try {
    salt = fromBase64(header.salt);
    iv = fromBase64(header.iv);
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  if (header.cipher !== "AES-256-GCM" || header.kdf !== "PBKDF2-SHA-256" || salt.length !== 16 || iv.length !== 12) {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  if (!Number.isInteger(header.iterations) || header.iterations < MIN_ITERATIONS || header.iterations > MAX_ITERATIONS) {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  return { ...header, salt, iv, text: file.header, data: file.data };
}

// Opens the file's text with `password`: the document, checked to be what the header says.
export async function decryptBackup(text, password) {
  const header = readHeader(text);
  let data;
  try {
    data = fromBase64(header.data);
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  const key = await deriveKey(password, header.salt, header.iterations);
  let plaintext;
  try {
    plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: header.iv, additionalData: encoder.encode(header.text) }, key, data);
  } catch {
    throw new BackupFileError("WRONG_PASSWORD");
  }
  let document;
  try {
    document = JSON.parse(decoder.decode(plaintext));
  } catch {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  if (!document || document.format !== DOCUMENT_FORMAT || (document.created_at ?? null) !== header.created_at) {
    throw new BackupFileError("NOT_A_BACKUP");
  }
  return { document, header: { home: header.home, created_at: header.created_at, driver_version: header.driver_version } };
}

// "DirectorLink backup Home 2026-10-01.dlbackup": the home's name and the day (this device's).
export function backupFileName(document, now = new Date()) {
  const home = String(document?.home?.name || "")
    .replace(/[\u0000-\u001f\u007f<>:"/\\|?*]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 60);
  const pad = (value) => String(value).padStart(2, "0");
  const day = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
  return `DirectorLink backup ${home ? `${home} ` : ""}${day}${FILE_EXTENSION}`;
}

const byteLength = (text) => encoder.encode(text).length;

// The document's JSON in parts, each at most `maxBytes` as a JSON string (with its escapes), never
// cutting a character in two.
export function splitParts(text, maxBytes = PART_BYTES) {
  const parts = [];
  let start = 0;
  while (start < text.length) {
    let size = Math.min(text.length - start, maxBytes);
    let end = start + size;
    while (size > 1 && byteLength(JSON.stringify(text.slice(start, end))) > maxBytes) {
      size = Math.max(1, Math.floor(size * 0.8));
      end = start + size;
    }
    // A pair of UTF-16 halves (an emoji) stays together.
    const code = text.charCodeAt(end - 1);
    if (end < text.length && code >= 0xd800 && code <= 0xdbff && end - start > 1) end -= 1;
    parts.push(text.slice(start, end));
    start = end;
  }
  return parts;
}

// ---- With the controller ------------------------------------------------------------------------

// The file to save now: { text, fileName, document }.
export async function makeBackup(password) {
  const document = await api("/v1/backup", { timeoutMs: TIMEOUT_MS });
  if (document?.format !== DOCUMENT_FORMAT) throw new BackupFileError("NOT_A_BACKUP");
  return { text: await encryptBackup(document, password), fileName: backupFileName(document), document };
}

// Sends the document to the controller in parts; returns the upload's id.
export async function sendBackup(document) {
  const parts = splitParts(JSON.stringify(document));
  let upload;
  for (let index = 0; index < parts.length; index += 1) {
    const body = { index, count: parts.length, text: parts[index] };
    if (upload) body.upload = upload;
    upload = (await api("/v1/restore/parts", { method: "POST", body, timeoutMs: TIMEOUT_MS }))?.upload;
  }
  return upload;
}

// What restoring `document` would do, without changing anything: { upload, preview }.
export async function checkBackup(document) {
  const upload = await sendBackup(document);
  const answer = await api("/v1/restore", { method: "POST", body: { upload }, timeoutMs: TIMEOUT_MS });
  return { upload, preview: answer?.restore };
}

// Replaces everything with the checked document. An upload the controller no longer has (10
// minutes went by, or another admin sent one) is sent again first.
export async function restoreBackup(document, upload) {
  const replace = (id) => api("/v1/restore", { method: "POST", body: { upload: id, dry_run: false }, timeoutMs: TIMEOUT_MS });
  try {
    return await replace(upload);
  } catch (error) {
    if (error?.code !== "UPLOAD_NOT_FOUND") throw error;
    return replace(await sendBackup(document));
  }
}
