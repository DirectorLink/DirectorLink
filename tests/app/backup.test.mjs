// Backups (1.4.0, ADR-042; app/js/backup.js with views/backup.js): the file, locked in the browser
// with a password (PBKDF2-SHA-256, AES-256-GCM, its header authenticated), opened again, refused
// with a wrong password or once changed; the document sent back in parts that fit a sealed request;
// and Settings → Controller → Backup: who sees it, the two passwords, the download, the file and
// its password, the check, what the preview says, Replace everything only once confirmed, and the
// result. Against a fake controller under fake time, with just enough of a browser.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

// ---- just enough of a browser ----------------------------------------------------------------
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.listeners = {};
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener(type, listener) {
    (this.listeners[type] ||= []).push(listener);
  }
  append(...children) {
    this.children.push(...children);
  }
  remove() {
    this.removed = true;
  }
  click() {
    saved.push({ href: this.attributes.href, name: this.attributes.download });
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  set textContent(value) {
    this.children = [Object.assign(new FakeNode(), { textContent: String(value) })];
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: new FakeElement("body"),
  addEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Node", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
const stored = new Map();
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
    clear: () => stored.clear(),
  },
  configurable: true,
});
// What the app saved (the file's link, name and contents) and what it asked to confirm.
const saved = [];
const blobs = new Map();
URL.createObjectURL = (blob) => {
  const url = `blob:test/${blobs.size + 1}`;
  blobs.set(url, blob);
  return url;
};
URL.revokeObjectURL = (url) => blobs.delete(url);
let confirmAnswer = true;
const confirmed = [];
window.confirm = (text) => {
  confirmed.push(text);
  return confirmAnswer;
};
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-01T08:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// ---- the fake controller -----------------------------------------------------------------------
// A DirectorLink that cannot seal here (so requests carry the key, as with a driver before 1.0.0),
// holding `document` for GET /v1/backup. `restore(body)` may answer POST /v1/restore instead.
const HOST = "controller.invalid";
const KEY = "ak_test_backup_key";
const PREVIEW = {
  backup: { created_at: "2026-09-30T20:00:00Z", driver_version: "1.4.0", format_version: 1, home: "Home" },
  origin: { another_home: false, reasons: [], home_now: "Home", controller: "same" },
  counts: { keys: 3, profiles: 2, scenes: 12, schedules: 5, room_names: 4, room_order: 6 },
  left_out: { scenes: 0, steps: 1, schedules: 0, profiles: 0 },
  keys: {
    action: "restore",
    count: 3,
    in_backup: 2,
    items: [
      { id: "0a1b2c3d", name: "Owner phone", role: "admin", expires_at: null },
      { id: "1b2c3d4e", name: "Dana phone", role: "member", expires_at: null },
    ],
    replaced: null,
    yours: "added",
    conflict: false,
    expired: 0,
    left_out: 0,
    over_limit: false,
    limit: 20,
  },
  remote: { action: "restore", home_id: "b".repeat(32), current_home_id: "a".repeat(32), remote_access: true, old_controller: false },
  references: {
    by_id: 40,
    by_name: [{ kind: "light", name: "Kitchen Island", room: "Kitchen", from: 20, to: 120 }],
    renamed: [{ kind: "climate", id: 30, name: "Parents", now: "Parents AC" }],
    unmatched: [{ kind: "light", id: 21, name: "Hall Light", room: "Living Room", used_in: [{ section: "scenes", name: "Good night" }, { section: "profiles", name: "Dana" }] }],
    unmatched_count: 1,
  },
  composer: [
    { name: "Door Control", backup: "Enabled", current: "Disabled" },
    { name: "Relay Hold", backup: "Not allowed", current: "Not allowed" },
  ],
};
// `old`: a DirectorLink before 1.4.0, which has no settings and no backups (404).
const controller = { calls: [], document: null, restore: null, parts: [], old: false };
const SETTINGS = { settings: [{ key: "schedules", property: "Schedules", value: "on", composer_value: "On", choices: ["on", "paused"], changeable: true, set_in: "app_and_composer" }], status: {}, actions: [] };

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const body = init.body ? JSON.parse(init.body) : null;
  controller.calls.push({ method, path, body, raw: init.body || "" });
  return handle(method, path, body);
};

function handle(method, path, body) {
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "admin" });
  if (controller.old && (path === "/v1/settings" || path === "/v1/backup" || path.startsWith("/v1/restore"))) {
    return answer(404, { status: 404, code: "NOT_FOUND", detail: `No API route for ${path}` });
  }
  if (method === "GET" && path === "/v1/settings") return answer(200, SETTINGS);
  if (method === "GET" && path === "/v1/backup") return answer(200, controller.document);
  if (method === "POST" && path === "/v1/restore/parts") {
    if (body.index === 0) controller.parts = [];
    controller.parts.push(body.text);
    return answer(200, { upload: `up${controller.calls.length}`.padEnd(16, "0").slice(0, 16), received: controller.parts.length, count: body.count, complete: controller.parts.length === body.count });
  }
  if (method === "POST" && path === "/v1/restore") {
    const custom = controller.restore?.(body);
    if (custom) return answer(custom.status, custom.body);
    if (body.dry_run === false) return answer(200, { dry_run: false, restore: PREVIEW, restored_at: "2026-10-01T08:00:05Z" });
    return answer(200, { dry_run: true, restore: PREVIEW });
  }
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
}

const { state, ui, notify } = await import("../../app/js/state.js");
const session = await import("../../app/js/session.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const remote = await import("../../app/js/remote.js");
const backup = await import("../../app/js/backup.js");
const { backupPanel } = await import("../../app/js/views/backup.js");

async function settle() {
  for (let index = 0; index < 8; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function advance(ms, step = 50) {
  for (let done = 0; done < ms; done += step) {
    mock.timers.tick(Math.min(step, ms - done));
    await settle();
  }
  await settle();
}

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function byKey(nodes, key) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node.dataset?.key === key) found = node;
  });
  return found;
}
const text = (node) => (node ? node.textContent : "");
const panelText = () => text(backupPanel());

// Runs an element's listeners as the browser would, and waits for what they started.
async function fire(key, type, event = {}) {
  const element = byKey(backupPanel(), key);
  assert.ok(element, `no ${key} in the panel: ${panelText().slice(0, 200)}`);
  assert.equal(element.attributes.disabled, undefined, `${key} is disabled`);
  await Promise.all((element.listeners[type] || []).map((listener) => listener({ preventDefault() {}, stopPropagation() {}, ...event })));
  await settle();
}
const click = (key) => fire(key, "click");
const typeInto = (key, value) => fire(key, "input", { target: { value } });
// Submits the form a button is in (the panel is drawn again: the form is the button's parent).
async function submit(buttonKey) {
  let form = null;
  walk(backupPanel(), (node) => {
    if (!form && node.tagName === "FORM" && byKey(node, buttonKey)) form = node;
  });
  assert.ok(form, `no form with ${buttonKey}`);
  await Promise.all((form.listeners.submit || []).map((listener) => listener({ preventDefault() {} })));
  await settle();
}
const message = () => text(byKey(backupPanel(), "backup-message"));

const DOCUMENT = {
  format: "directorlink-backup",
  format_version: 1,
  driver_version: "1.4.0",
  created_at: "2026-09-30T20:00:00Z",
  home: { name: "Home" },
  composer: { "Door Control": "Enabled" },
  references: { rooms: { 10: { name: "מטבח" } }, devices: {} },
  sections: {
    keys: { version: 4, keys: [{ id: "0a1b2c3d", name: "Owner phone", role: "admin", alg: "sha256", hash: "ab".repeat(32), lock: "cd".repeat(32) }] },
    scenes: { version: 1, scenes: [{ id: "e43d14b1", name: "Good night 🌙 לילה טוב", steps: [] }] },
  },
};

// Connected to the fake controller as an admin, on Settings (which reads DirectorLink's settings:
// the Backup panel shows once the controller is known to have it).
async function connect(role = "admin", { old = false } = {}) {
  session.forgetKey();
  await advance(20000, 500);
  Object.assign(controller, { calls: [], document: structuredClone(DOCUMENT), restore: null, parts: [], old });
  saved.length = 0;
  confirmed.length = 0;
  confirmAnswer = true;
  Object.assign(state, { host: HOST, apiKey: KEY, role, status: "connected", loaded: true, notice: null, errors: {}, pending: {}, rooms: [], lights: [], thermostats: [], blinds: [], fans: [], cameras: [], relays: [], doorbells: [], devices: [], scenes: [] });
  ui.backup = { stage: null };
  notify();
  backupPanel();
  await advance(100);
}

const requests = (method, path) => controller.calls.filter((call) => call.method === method && call.path === path);

// ---- the file ------------------------------------------------------------------------------------

test("a backup file opens with its password, and only with it", async () => {
  const file = await backup.encryptBackup(DOCUMENT, "correct horse battery");
  const outer = JSON.parse(file);
  assert.equal(outer.format, "directorlink-backup-file");
  assert.equal(outer.version, 1);
  const header = JSON.parse(outer.header);
  assert.deepEqual(
    { version: header.version, cipher: header.cipher, kdf: header.kdf, iterations: header.iterations, home: header.home, created_at: header.created_at },
    { version: 1, cipher: "AES-256-GCM", kdf: "PBKDF2-SHA-256", iterations: 600000, home: "Home", created_at: "2026-09-30T20:00:00Z" },
    "the file's version is in the header the password authenticates"
  );
  assert.equal(Buffer.from(header.salt, "base64").length, 16, "a 16-byte salt");
  assert.equal(Buffer.from(header.iv, "base64").length, 12, "a 12-byte IV");
  for (const secret of ["ab".repeat(32), "Good night", "Owner phone"]) assert.ok(!file.includes(secret), `nothing readable: ${secret}`);
  const again = JSON.parse(await backup.encryptBackup(DOCUMENT, "correct horse battery"));
  assert.notEqual(JSON.parse(again.header).salt, header.salt, "a new salt every time");
  assert.notEqual(again.data, outer.data);

  const opened = await backup.decryptBackup(file, "correct horse battery");
  assert.deepEqual(opened.document, DOCUMENT, "Hebrew and an emoji included");
  assert.deepEqual(opened.header, { home: "Home", created_at: "2026-09-30T20:00:00Z", driver_version: "1.4.0" });
  await assert.rejects(backup.decryptBackup(file, "correct horse batterY"), { code: "WRONG_PASSWORD" });
  await assert.rejects(backup.decryptBackup(file, ""), { code: "WRONG_PASSWORD" });
});

test("a file that was changed or is not a backup is refused", async () => {
  const file = await backup.encryptBackup(DOCUMENT, "correct horse battery", { iterations: 100000 });
  const outer = JSON.parse(file);
  const header = JSON.parse(outer.header);
  const variant = (changeOuter, changeHeader) => {
    const copy = structuredClone(outer);
    if (changeHeader) {
      const changed = { ...header };
      changeHeader(changed);
      copy.header = JSON.stringify(changed);
    }
    if (changeOuter) changeOuter(copy);
    return JSON.stringify(copy);
  };
  // The header is authenticated: another home or date in it and the file does not open.
  await assert.rejects(backup.decryptBackup(variant(null, (h) => (h.home = "Other home")), "correct horse battery"), { code: "WRONG_PASSWORD" });
  await assert.rejects(backup.decryptBackup(variant(null, (h) => (h.created_at = "2027-01-01T00:00:00Z")), "correct horse battery"), { code: "WRONG_PASSWORD" });
  // So is every byte of the data.
  const data = Buffer.from(outer.data, "base64");
  data[data.length - 20] ^= 1;
  await assert.rejects(backup.decryptBackup(variant((copy) => (copy.data = data.toString("base64"))), "correct horse battery"), { code: "WRONG_PASSWORD" });
  // A header that would keep the browser busy for minutes, or is not one of ours, is not tried.
  await assert.rejects(backup.decryptBackup(variant(null, (h) => (h.iterations = 1e9)), "correct horse battery"), { code: "NOT_A_BACKUP" });
  await assert.rejects(backup.decryptBackup(variant(null, (h) => (h.cipher = "AES-128-CBC")), "correct horse battery"), { code: "NOT_A_BACKUP" });
  await assert.rejects(backup.decryptBackup(variant((copy) => (copy.version = 2)), "correct horse battery"), { code: "NEWER_FILE" });
  // Only version 1, outside and inside: 0, a negative one, text, or none in the header do not open.
  for (const version of [0, -5, "1", null]) {
    await assert.rejects(backup.decryptBackup(variant((copy) => (copy.version = version)), "correct horse battery"), { code: "NOT_A_BACKUP" }, String(version));
  }
  await assert.rejects(backup.decryptBackup(variant(null, (h) => delete h.version), "correct horse battery"), { code: "NOT_A_BACKUP" });
  await assert.rejects(backup.decryptBackup(variant(null, (h) => (h.version = 0)), "correct horse battery"), { code: "NOT_A_BACKUP" });
  await assert.rejects(backup.decryptBackup("hello", "x"), { code: "NOT_A_BACKUP" });
  await assert.rejects(backup.decryptBackup(file.slice(0, 100), "x"), { code: "NOT_A_BACKUP" });
  await assert.rejects(backup.decryptBackup(JSON.stringify({ format: "something" }), "x"), { code: "NOT_A_BACKUP" });
  assert.equal(backup.readHeader(file).home, "Home", "what the file says of itself, before its password");
});

test("the password's strength hint, and the file's name", () => {
  assert.equal(backup.passwordStrength("short"), "weak");
  // Common passwords, a word with digits and symbols, sequences, keyboard rows and repeats.
  for (const password of ["aaaaaaaaaaaa", "abcdefghij", "Abcdefgh12", "Password1!", "Password123", "P@ssw0rd2024!", "Shalom2024!", "Elephant2024!", "12345678901234", "qwertyuiopasdf", "abcdefghijklmnop", "1234567890", "iloveyou12", "abcabcabcabc"]) {
    assert.equal(backup.passwordStrength(password), "weak", password);
  }
  assert.equal(backup.passwordStrength("maple7Tiger"), "fair");
  assert.equal(backup.passwordStrength("correct horse battery staple"), "strong");
  assert.equal(backup.passwordStrength("lemon tree 42 bike"), "strong");
  assert.equal(backup.passwordStrength("Tz8#kq!Lm2@vR9"), "strong");
  assert.equal(backup.MIN_PASSWORD, 10);
  assert.equal(backup.backupFileName(DOCUMENT, new Date(2026, 9, 1)), "DirectorLink backup Home 2026-10-01.dlbackup");
  assert.equal(backup.backupFileName({ home: { name: 'Villa: "A/B"?' } }, new Date(2026, 0, 9)), "DirectorLink backup Villa A B 2026-01-09.dlbackup");
  assert.equal(backup.backupFileName({ home: { name: null } }, new Date(2026, 0, 9)), "DirectorLink backup 2026-01-09.dlbackup");
});

test("the document goes back in parts that each fit a sealed request, never cutting a character", () => {
  const scenes = [];
  for (let index = 0; index < 400; index += 1) scenes.push({ id: index.toString(16).padStart(8, "0"), name: `סצנה ${index} "night" 🌙`, steps: [{ type: "lights", device_ids: [20, 21, 22], set: { on: false } }] });
  const text = JSON.stringify({ ...DOCUMENT, sections: { ...DOCUMENT.sections, scenes: { version: 1, scenes } } });
  const parts = backup.splitParts(text);
  assert.ok(parts.length > 2);
  assert.equal(parts.join(""), text);
  for (const part of parts) {
    assert.ok(new TextEncoder().encode(JSON.stringify(part)).length <= backup.PART_BYTES, "each at most 30000 bytes as JSON");
    const last = part.charCodeAt(part.length - 1);
    assert.ok(!(last >= 0xd800 && last <= 0xdbff), "an emoji is never cut in two");
  }
  assert.deepEqual(backup.splitParts("short"), ["short"]);
});

// ---- Settings → Controller → Backup ----------------------------------------------------------------

test("only admins see the backup, once connected", async () => {
  await setLanguage("en");
  await connect("member");
  assert.equal(backupPanel(), null);
  await connect("admin");
  state.loaded = false;
  assert.equal(backupPanel(), null);
  state.loaded = true;
  assert.ok(byKey(backupPanel(), "backup-download") && byKey(backupPanel(), "backup-restore"));
  assert.ok(panelText().includes("locked with a password"));
});

test("a download asks for a password twice, and saves the file locked with it", async () => {
  await connect();
  await click("backup-download");
  assert.ok(panelText().includes("Without it the file cannot be opened"), "says so before anything else");
  await typeInto("backup-password", "short");
  await submit("backup-download-submit");
  assert.equal(message(), "Use at least 10 characters.");
  await typeInto("backup-password", "correct horse battery staple");
  await typeInto("backup-confirm", "correct horse battery stapler");
  await submit("backup-download-submit");
  assert.equal(message(), "The two passwords are not the same.");
  assert.equal(requests("GET", "/v1/backup").length, 0, "nothing is asked for until both agree");
  // Drawn again with the message: the passwords are the inputs' values, never their attributes.
  for (const key of ["backup-password", "backup-confirm"]) {
    const input = byKey(backupPanel(), key);
    assert.equal(input.attributes.value, undefined, `${key}: nothing in the page's HTML`);
    assert.match(input.value, /^correct horse battery staple/);
  }

  await typeInto("backup-confirm", "correct horse battery staple");
  await submit("backup-download-submit");
  assert.equal(requests("GET", "/v1/backup").length, 1);
  assert.equal(saved.length, 1);
  assert.equal(saved[0].name, "DirectorLink backup Home 2026-10-01.dlbackup");
  const file = await blobs.get(saved[0].href).text();
  const opened = await backup.decryptBackup(file, "correct horse battery staple");
  assert.deepEqual(opened.document, DOCUMENT);
  assert.ok(message().includes("Saved as “DirectorLink backup Home 2026-10-01.dlbackup”"));
  assert.ok(byKey(backupPanel(), "backup-download"), "the panel is closed again");
  for (const call of controller.calls) assert.ok(!call.raw.includes("correct horse"), "the password never leaves the browser");
});

async function chooseFile(content, name = "DirectorLink backup Home 2026-09-30.dlbackup") {
  await fire("backup-file", "change", { target: { files: [{ name, text: async () => content }] } });
}

test("a restore opens the file here, has the controller check it, and replaces nothing until confirmed", async () => {
  await connect();
  const file = await backup.encryptBackup(DOCUMENT, "correct horse battery staple");
  await click("backup-restore");
  await chooseFile("not a backup", "notes.txt");
  assert.equal(message(), "This is not a DirectorLink backup file, or it is damaged.");
  await chooseFile(file);
  assert.ok(text(byKey(backupPanel(), "backup-file-says")).includes("backup of Home"));
  await typeInto("backup-open-password", "wrong password!");
  await submit("backup-open-submit");
  assert.equal(message(), "Wrong password, or the file was changed.");
  assert.equal(requests("POST", "/v1/restore/parts").length, 0, "nothing is sent for a file that did not open");

  await typeInto("backup-open-password", "correct horse battery staple");
  await submit("backup-open-submit");
  assert.equal(controller.parts.join(""), JSON.stringify(DOCUMENT), "the opened document goes to the controller, in parts");
  const checks = requests("POST", "/v1/restore");
  assert.equal(checks.length, 1);
  assert.equal(checks[0].body.dry_run, undefined, "checked (the default), not restored");
  for (const call of controller.calls) assert.ok(!call.raw.includes("correct horse"), "the password never leaves the browser");

  const preview = panelText();
  for (const words of ["Backup of Home", "DirectorLink 1.4.0", "Scenes12", "Schedules5", "Devices with access3", "This device keeps its access (it was paired after the backup was made).",
    "Keys that come back", "Owner phone — Admin", "Dana phone — Member",
    "Remote access: the home goes back to the backup’s link", "Kitchen Island (Kitchen)", "Thermostat Parents → Parents AC", "Hall Light (Living Room) — scene “Good night”, Dana’s favorites",
    "1 scene step has nothing left to act on", "DirectorLink settings, not restored", "Door Control", "backup: Enabled · now: Disabled",
    "set the schedules, the Jewish calendar and the log level again under DirectorLink settings"]) {
    assert.ok(preview.includes(words), `the preview says: ${words}\n${preview}`);
  }
  assert.ok(!preview.includes("the installer sets them again"), "three of them are set in the app now");
  assert.ok(!byKey(backupPanel(), "backup-another-home"), "this home's own backup");

  confirmAnswer = false;
  await click("backup-replace");
  assert.equal(confirmed.length, 1);
  assert.equal(confirmed[0], "Replace everything DirectorLink keeps on this controller with the backup of “Home”?", "it names the home");
  assert.equal(requests("POST", "/v1/restore").length, 1, "not confirmed: nothing replaced");
  confirmAnswer = true;
  remote.saveRemote({ home: "a".repeat(32), keyId: "0a1b2c3d" });
  await click("backup-replace");
  const replace = requests("POST", "/v1/restore")[1];
  assert.deepEqual(replace.body, { upload: checks[0].body.upload, dry_run: false });
  assert.ok(byKey(backupPanel(), "backup-done"));
  assert.ok(panelText().includes("Restored: everything is as in the backup of Home"));
  assert.equal(remote.savedRemote().home, "b".repeat(32), "a linked device goes to the backup's home through the account");
  assert.ok(panelText().includes("reaches the home through the backup’s link"));
  await advance(500);
  assert.ok(requests("GET", "/v1/system").length > 0, "everything is read again");
  await click("backup-done-ok");
  assert.ok(byKey(backupPanel(), "backup-restore"));
  remote.forgetRemote();
});

test("an upload the controller no longer has is sent again; its refusals are explained", async () => {
  await connect();
  const file = await backup.encryptBackup(DOCUMENT, "correct horse battery staple", { iterations: 100000 });
  await click("backup-restore");
  await chooseFile(file);
  await typeInto("backup-open-password", "correct horse battery staple");
  controller.restore = (body) => (body.dry_run === undefined ? { status: 409, body: { status: 409, code: "BACKUP_TOO_NEW", detail: "newer" } } : null);
  await submit("backup-open-submit");
  assert.equal(message(), "This backup was made by a newer DirectorLink than this controller has. Update DirectorLink in Composer first.");
  controller.restore = (body) => (body.dry_run === undefined ? { status: 422, body: { status: 422, code: "BACKUP_INVALID" } } : null);
  await submit("backup-open-submit");
  assert.equal(message(), "The controller found this backup not valid. Nothing was changed.");

  controller.restore = null;
  await submit("backup-open-submit");
  let first = true;
  controller.restore = (body) => {
    if (body.dry_run === false && first) {
      first = false;
      return { status: 404, body: { status: 404, code: "UPLOAD_NOT_FOUND" } };
    }
    return null;
  };
  const partsBefore = requests("POST", "/v1/restore/parts").length;
  await click("backup-replace");
  assert.ok(requests("POST", "/v1/restore/parts").length > partsBefore, "sent again");
  assert.ok(byKey(backupPanel(), "backup-done"));

  await click("backup-done-ok");
  await click("backup-restore");
  await chooseFile(file);
  await typeInto("backup-open-password", "correct horse battery staple");
  await submit("backup-open-submit");
  controller.restore = (body) => (body.dry_run === false ? { status: 500, body: { status: 500, code: "RESTORE_FAILED", store: "scenes" } } : null);
  await click("backup-replace");
  assert.equal(message(), "The controller could not save everything, so nothing was changed. Try again.");
  assert.ok(byKey(backupPanel(), "backup-replace"), "the preview stays, to try again");
});

test("in Hebrew", async () => {
  await setLanguage("he");
  try {
    await connect();
    assert.ok(panelText().includes("הורדת גיבוי"));
    await click("backup-download");
    await typeInto("backup-password", "short");
    await submit("backup-download-submit");
    assert.equal(message(), "צריך לפחות 10 תווים.");
    await click("backup-cancel");
    await click("backup-restore");
    const file = await backup.encryptBackup(DOCUMENT, "correct horse battery staple", { iterations: 100000 });
    await chooseFile(file);
    await typeInto("backup-open-password", "correct horse battery staple");
    await submit("backup-open-submit");
    const preview = panelText();
    for (const words of ["מה יש בגיבוי", "סצנות12", "המכשיר הזה שומר על הגישה שלו", "מפתחות שחוזרים", "Owner phone — מנהל", "הסצנה „Good night”", "הגדרות DirectorLink, לא משוחזרות", "החלפת הכול"]) {
      assert.ok(preview.includes(words), `the preview says: ${words}\n${preview}`);
    }
  } finally {
    await setLanguage("en");
  }
});

test("forgetting this device's key forgets an opened backup too", async () => {
  await connect();
  await click("backup-restore");
  await chooseFile(await backup.encryptBackup(DOCUMENT, "correct horse battery staple", { iterations: 100000 }));
  await typeInto("backup-open-password", "correct horse battery staple");
  await submit("backup-open-submit");
  assert.ok(byKey(backupPanel(), "backup-replace"));
  session.forgetKey();
  assert.deepEqual(ui.backup, { stage: null });
  Object.assign(state, { apiKey: KEY, loaded: true, role: "admin" });
  // Another home may be paired next: what it has is read again first.
  assert.equal(backupPanel(), null);
  await advance(100);
  assert.ok(byKey(backupPanel(), "backup-restore"), "back to the start: nothing of it is left to restore");
});

// ---- After the 1.4.0 review ---------------------------------------------------------------------

// Opens a backup up to its preview; `preview` is what the controller's check answers.
async function toPreview(preview = PREVIEW) {
  controller.restore = (body) => (body.dry_run === undefined ? { status: 200, body: { dry_run: true, restore: preview } } : null);
  await click("backup-restore");
  await chooseFile(await backup.encryptBackup(DOCUMENT, "correct horse battery staple", { iterations: 100000 }));
  await typeInto("backup-open-password", "correct horse battery staple");
  await submit("backup-open-submit");
  assert.ok(byKey(backupPanel(), "backup-replace"), message());
  controller.restore = null;
}

test("the chosen file stays chosen across redraws, and a file too large is not read", async () => {
  await connect();
  await click("backup-restore");
  const input = byKey(backupPanel(), "backup-file");
  await chooseFile(await backup.encryptBackup(DOCUMENT, "correct horse battery staple", { iterations: 100000 }));
  assert.equal(byKey(backupPanel(), "backup-file"), input, "the same input, still holding the file");
  await typeInto("backup-open-password", "x");
  assert.equal(byKey(backupPanel(), "backup-file"), input);
  let read = false;
  await fire("backup-file", "change", { target: { files: [{ name: "holiday.mp4", size: 300 * 1024 * 1024, text: async () => ((read = true), "") }] } });
  assert.equal(read, false, "not read into memory");
  assert.equal(message(), "This file is too large to be a DirectorLink backup.");
  await click("backup-cancel");
  await click("backup-restore");
  assert.notEqual(byKey(backupPanel(), "backup-file"), input, "a new restore starts with no file");
});

test("the keys that come back are listed, and this device can take its old key's place", async () => {
  await connect();
  await toPreview();
  const select = byKey(backupPanel(), "backup-this-device");
  assert.ok(select, "offered while the backup's keys come back");
  assert.ok(panelText().includes("None of these (a new device)"));
  assert.ok(panelText().includes("Owner phone (Admin)"));
  await fire("backup-this-device", "change", { target: { value: "0a1b2c3d" } });
  controller.restore = (body) =>
    body.dry_run === false
      ? { status: 200, body: { dry_run: false, restore: { ...PREVIEW, keys: { ...PREVIEW.keys, items: PREVIEW.keys.items.slice(1), replaced: { id: "0a1b2c3d", name: "Owner phone", role: "admin" } } }, restored_at: "2026-10-01T08:00:05Z" } }
      : null;
  await click("backup-replace");
  const replace = requests("POST", "/v1/restore").at(-1);
  assert.equal(replace.body.replaces_key, "0a1b2c3d");
  assert.equal(replace.body.move_remote, undefined);
  assert.ok(panelText().includes("This device took the place of “Owner phone”, with its favorites and its role."));

  // A key that would leave no admin is refused by the controller, and said so.
  await click("backup-done-ok");
  await toPreview();
  await fire("backup-this-device", "change", { target: { value: "1b2c3d4e" } });
  controller.restore = (body) => (body.dry_run === false ? { status: 409, body: { status: 409, code: "LAST_ADMIN" } } : null);
  await click("backup-replace");
  assert.equal(message(), "That key is not an admin’s, and no admin would be left. Choose another key, or none.");
});

test("with other devices paired, the keys are kept as they are, and what is left out is said", async () => {
  await connect();
  await toPreview({ ...PREVIEW, keys: { ...PREVIEW.keys, action: "kept", yours: "kept", items: [], left_out: 2 } });
  const text = panelText();
  assert.ok(text.includes("Keys: kept as they are now."), text);
  assert.ok(text.includes("2 keys in the backup could not be used and are left out."));
  assert.ok(text.includes("Devices keep their access as it is now."));
  assert.ok(!text.includes("Devices whose keys are in the backup keep working"));
  assert.equal(byKey(backupPanel(), "backup-this-device"), null);
});

test("another home's backup is named first, and its remote access moves only when ticked", async () => {
  await connect();
  const other = {
    ...PREVIEW,
    backup: { ...PREVIEW.backup, home: "Cohen family" },
    origin: { another_home: true, reasons: ["home_id", "name", "references"], home_now: "Home", controller: "other" },
    remote: { ...PREVIEW.remote, action: "kept" },
  };
  await toPreview(other);
  const warning = text(byKey(backupPanel(), "backup-another-home"));
  for (const words of ["This backup looks like it is of another home: “Cohen family”.", "It is linked to another home in the account.", "Its home is called “Cohen family”, this one “Home”.", "Most of its rooms and devices are not in this project.", "Restore it only if this controller is that home’s."]) {
    assert.ok(warning.includes(words), `${words}\n${warning}`);
  }
  assert.ok(panelText().includes("Remote access: this controller stays linked as it is now; the backup’s link stays out."));
  assert.ok(panelText().includes("Move remote access to this controller. The controller this backup was made on must be off, or reset first"));
  await click("backup-replace");
  assert.equal(confirmed.at(-1), "This backup looks like it is of another home. Replace everything DirectorLink keeps on this controller with the backup of “Cohen family”?");
  assert.equal(requests("POST", "/v1/restore").at(-1).body.move_remote, undefined, "not ticked: not asked for");

  await click("backup-done-ok");
  await toPreview(other);
  await fire("backup-move-remote", "change", { target: { checked: true } });
  controller.restore = (body) =>
    body.dry_run === false ? { status: 200, body: { dry_run: false, restore: { ...other, remote: { ...PREVIEW.remote, old_controller: true } }, restored_at: "2026-10-01T08:00:05Z" } } : null;
  await click("backup-replace");
  assert.equal(requests("POST", "/v1/restore").at(-1).body.move_remote, true);
  assert.ok(text(byKey(backupPanel(), "backup-result-old-controller")).includes("turn Remote Access off on the controller this backup was made on"));
});

test("a DirectorLink before 1.4.0 shows no Backup, and a route it lacks says to update", async () => {
  await connect("admin", { old: true });
  assert.equal(backupPanel(), null, "hidden, as DirectorLink settings are");
  assert.equal(requests("GET", "/v1/backup").length, 0);
  // Known to have settings, but no backup route (a 404 from the controller): explained, not raw.
  await connect();
  controller.old = true;
  await click("backup-download");
  await typeInto("backup-password", "correct horse battery staple");
  await typeInto("backup-confirm", "correct horse battery staple");
  await submit("backup-download-submit");
  assert.equal(message(), "Backups need DirectorLink 1.4.0 or newer on the controller. Update DirectorLink in Composer.");
  controller.old = false;
});
