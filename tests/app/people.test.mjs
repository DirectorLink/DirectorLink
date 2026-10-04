// Admins and members (1.8.0, ADR-054; app/js/views/permissions.js, views/access.js and the parts
// of Settings that use them): People and devices shows each person with their role and what a
// member may do, and changes it; Invite someone chooses the same; Settings → Rooms hides a room
// from members; a member's app shows no schedules and uses what the controller lists for them; a
// controller before 1.8.0 keeps the four roles per device. Against a fake controller, with just
// enough of a browser.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

// ---- just enough of a browser ------------------------------------------------------------------
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.className = "";
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
  getContext() {
    return { fillRect() {}, fillStyle: "" };
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/#/access", pathname: "/", search: "", hash: "#/access", replace() {} };
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.history = { state: null, back() {} };
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: new FakeElement("body"),
  addEventListener() {},
  removeEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Mozilla/5.0 (Windows NT 10.0)", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
const stored = new Map();
Object.defineProperty(globalThis, "localStorage", {
  value: { getItem: (key) => (stored.has(key) ? stored.get(key) : null), setItem: (key, value) => stored.set(key, String(value)), removeItem: (key) => stored.delete(key) },
  configurable: true,
});
const confirmed = [];
window.confirm = (text) => {
  confirmed.push(text);
  return true;
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
globalThis.setTimeout = ((original) => (callback, delay, ...rest) => {
  const timer = original(callback, delay, ...rest);
  timer?.unref?.();
  return timer;
})(globalThis.setTimeout);

// ---- the fake controller --------------------------------------------------------------------------
const HOST = "controller.invalid";
const NIGHT = "a1b2c3d4";
const MEMBER_ACCESS = {
  role: "member",
  owner: false,
  all_rooms: false,
  rooms: [11],
  kinds: { light: true, climate: false, fan: true, blind: true, music: true, refrigerator: true },
  cameras: true,
  doors: false,
  alarm: true,
  scenes: [],
};
const controller = { calls: [], profiles: [], keys: [], rooms: [] };

function answer(status, body) {
  return new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { "Content-Type": status >= 400 ? "application/problem+json" : "application/json" } });
}

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const body = init.body ? JSON.parse(init.body) : null;
  controller.calls.push({ method, path, body });
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (method === "GET" && path === "/v1/api-keys") return answer(200, { items: controller.keys });
  if (method === "GET" && path === "/v1/profiles") return answer(200, { items: controller.profiles });
  if (method === "GET" && path === "/v1/invitations") return answer(200, { items: [] });
  const access = /^\/v1\/profiles\/([0-9a-f]{8})\/access$/.exec(path);
  if (access && method === "PATCH") {
    const profile = controller.profiles.find((item) => item.id === access[1]);
    if (profile.access.owner) return answer(403, { status: 403, code: "OWNER_PROTECTED", detail: "no" });
    profile.access = { ...profile.access, ...body };
    return answer(200, profile.access);
  }
  const room = /^\/v1\/rooms\/(\d+)$/.exec(path);
  if (room && method === "PATCH") {
    const found = controller.rooms.find((item) => item.id === Number(room[1]));
    found.hidden_from_members = body.hidden_from_members;
    return answer(200, found);
  }
  if (method === "POST" && path === "/v1/invitations") {
    return answer(201, { id: "1c2d3e4f", role: body.role, access: body.access, secret: "5e".repeat(32), home_id: "ab".repeat(16), expires_at: "2026-10-11T08:00:00Z", registered: true, email: body.email });
  }
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { can, canSeeAlarm, state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const permissions = await import("../../app/js/views/permissions.js");
const { accessView, resetAccess } = await import("../../app/js/views/access.js");
const { settingsView } = await import("../../app/js/views/settings.js");
const { scenesNav, schedulesView } = await import("../../app/js/views/schedules.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

async function settle() {
  for (let index = 0; index < 10; index += 1) await new Promise((resolve) => setImmediate(resolve));
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
const textOf = (nodes) => [nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" | ");
async function press(nodes, key, event = {}) {
  const element = byKey(nodes, key);
  assert.ok(element, `${key} is on the screen: ${textOf(nodes).slice(0, 400)}`);
  for (const type of ["click", "change"]) {
    await Promise.all((element.listeners[type] || []).map((listener) => listener({ preventDefault() {}, target: element, currentTarget: element, ...event })));
  }
  await settle();
}
const calls = (method, path) => controller.calls.filter((call) => call.method === method && call.path === path);

const ROOMS = [
  { id: 10, name: "Kitchen", names: {}, hidden_from_members: false },
  { id: 11, name: "Living room", names: {}, hidden_from_members: false },
];

// Connected as an admin (or `access`) to a 1.8.0 controller (or an older one: `old`).
function connect({ access = { ...permissions.newMemberAccess(), role: "admin", owner: true }, old = false } = {}) {
  controller.calls = [];
  controller.rooms = structuredClone(ROOMS);
  controller.keys = [
    { id: "0a1b2c3d", name: "Owner laptop", role: "admin", current: true, profile_id: "aaaa0001", created_at: "2026-10-01T08:00:00Z" },
    { id: "0a1b2c3e", name: "Kid's phone", role: "member", current: false, profile_id: "bbbb0002", created_at: "2026-10-01T08:00:00Z" },
  ];
  controller.profiles = [
    { id: "aaaa0001", name: "Dana", key_ids: ["0a1b2c3d"], prefs: {}, access: { ...permissions.newMemberAccess(), role: "admin", owner: true } },
    { id: "bbbb0002", name: "Noa", key_ids: ["0a1b2c3e"], prefs: {}, access: structuredClone(MEMBER_ACCESS) },
  ];
  confirmed.length = 0;
  resetAccess();
  ui.inviteForm = false;
  ui.inviteAccess = null;
  Object.assign(state, {
    host: HOST,
    apiKey: "ak_test",
    status: "connected",
    transport: "lan",
    loaded: true,
    online: true,
    role: access?.role === "admin" ? "admin" : access?.doors ? "doors" : "member",
    access: old ? null : access,
    rooms: structuredClone(ROOMS),
    profile: { id: "aaaa0001", prefs: { hidden_rooms: [] } },
    scenes: [{ id: NIGHT, name: "Good night", icon: "moon", steps: [] }],
    system: { bridge: { version: old ? "1.7.0" : "1.8.0" }, features: old ? { alert_choices: true } : { alert_choices: true, people_permissions: true } },
    account: { status: "signed-out", user: null, notice: null, busy: false },
  });
}

test("a member's access, as the editor keeps it and the controller takes it", () => {
  connect();
  const fresh = permissions.newMemberAccess();
  assert.deepEqual(fresh, { role: "member", all_rooms: true, rooms: [], kinds: { light: true, climate: true, fan: true, blind: true, music: true, refrigerator: true }, cameras: true, doors: false, alarm: true, scenes: [] });
  const draft = permissions.copyAccess({ ...MEMBER_ACCESS, rooms: [11, 99], scenes: [NIGHT, "deadbeef"] });
  draft.rooms.push(10);
  assert.deepEqual(MEMBER_ACCESS.rooms, [11], "a copy: the person's access is untouched");
  assert.deepEqual(permissions.accessBody(draft), {
    role: "member",
    all_rooms: false,
    rooms: [11, 10],
    kinds: MEMBER_ACCESS.kinds,
    cameras: true,
    doors: false,
    alarm: true,
    scenes: [NIGHT],
  }, "only rooms and scenes the home still has");
  assert.deepEqual(permissions.accessBody({ ...draft, role: "admin" }), { role: "admin" }, "an admin is an admin");
  setLanguage("en");
  assert.equal(permissions.accessSummary(MEMBER_ACCESS), "1 room · lights, fans, blinds, music, refrigerators · cameras · no scenes");
  assert.equal(permissions.accessSummary({ ...fresh, doors: true, scenes: [NIGHT] }), "All rooms · every device · cameras · doors and gates · 1 scene");
  assert.equal(permissions.accessSummary({ role: "admin" }), "Everything");
});

test("can() follows the person: admins, members, doors and the alarm", () => {
  connect({ access: { ...MEMBER_ACCESS } });
  assert.equal(can("admin"), false);
  assert.equal(can("member"), true, "a member uses what the controller lists for them");
  assert.equal(can("viewer"), true);
  assert.equal(can("doors"), false);
  assert.equal(canSeeAlarm(), true);
  state.access = { ...MEMBER_ACCESS, doors: true, alarm: false, rooms: [] };
  assert.equal(can("doors"), true);
  assert.equal(can("member"), true, "with no rooms too: the lists are empty");
  assert.equal(canSeeAlarm(), false);
  state.access = { role: "admin" };
  assert.equal(can("admin"), true);
  assert.equal(can("doors"), true);
  // A controller before 1.8.0: the key's role, as before.
  state.access = null;
  state.role = "viewer";
  assert.equal(can("member"), false);
  assert.equal(canSeeAlarm(), false);
  state.role = "doors";
  assert.equal(can("doors"), true);
});

test("People and devices: each person with their role; a member's access changed for all their devices", async () => {
  connect();
  setLanguage("en");
  accessView({});
  await settle();
  let view = accessView({});
  const owner = byKey(view, "access-profile-aaaa0001");
  assert.match(textOf(owner), /Dana.*Owner.*You/);
  assert.equal(byKey(view, "access-edit-aaaa0001"), null, "the owner is always an admin: nothing to change");
  assert.match(textOf(byKey(view, "access-profile-role-bbbb0002")), /^Member · 1 room · lights, fans, blinds, music, refrigerators · cameras · no scenes$/);
  assert.equal(byKey(view, "access-role-0a1b2c3e"), null, "a device has no role of its own");
  assert.match(textOf(view), /Accounts|People/);

  await press(view, "access-edit-bbbb0002");
  view = accessView({});
  const editor = byKey(view, "access-editor-bbbb0002");
  assert.ok(editor, "the editor opens under the person");
  for (const key of ["perm-bbbb0002-role:admin", "perm-bbbb0002-role:member", "perm-bbbb0002-all-rooms", "perm-bbbb0002-room-10", "perm-bbbb0002-room-11", "perm-bbbb0002-kind-light", "perm-bbbb0002-kind-climate", "perm-bbbb0002-cameras", "perm-bbbb0002-doors", "perm-bbbb0002-alarm", `perm-bbbb0002-scene-${NIGHT}`]) {
    assert.ok(byKey(editor, key), key);
  }
  assert.ok("checked" in byKey(editor, "perm-bbbb0002-room-11").attributes, "the living room is theirs");
  assert.ok(!("checked" in byKey(editor, "perm-bbbb0002-room-10").attributes));
  // The kitchen too, doors and gates, and the scene; then Save.
  byKey(editor, "perm-bbbb0002-room-10").listeners.change[0]({ target: { checked: true } });
  await press(editor, "perm-bbbb0002-doors");
  byKey(editor, `perm-bbbb0002-scene-${NIGHT}`).listeners.change[0]({ target: { checked: true } });
  byKey(editor, "perm-bbbb0002-kind-climate").listeners.change[0]({ target: { checked: true } });
  await press(accessView({}), "access-save-bbbb0002");
  const saved = calls("PATCH", "/v1/profiles/bbbb0002/access");
  assert.equal(saved.length, 1);
  assert.deepEqual(saved[0].body, {
    role: "member",
    all_rooms: false,
    rooms: [11, 10],
    kinds: { light: true, climate: true, fan: true, blind: true, music: true, refrigerator: true },
    cameras: true,
    doors: true,
    alarm: true,
    scenes: [NIGHT],
  });
  assert.equal(confirmed.length, 0, "a member's own choices need no question");
  view = accessView({});
  assert.equal(byKey(view, "access-editor-bbbb0002"), null, "closed once saved");
  assert.match(textOf(view), /Saved\. Noa’s devices follow at once\./);

  // Made an admin: asked first.
  await press(view, "access-edit-bbbb0002");
  await press(accessView({}), "perm-bbbb0002-role:admin");
  assert.equal(byKey(accessView({}), "perm-bbbb0002-cameras"), null, "an admin has everything: no choices");
  await press(accessView({}), "access-save-bbbb0002");
  assert.match(confirmed[0], /Make Noa an admin\?/);
  assert.deepEqual(calls("PATCH", "/v1/profiles/bbbb0002/access")[1].body, { role: "admin" });
});

test("the controller's refusal about the owner is said in the app's words, in Hebrew too", async () => {
  connect();
  controller.profiles[0].access.owner = false;
  controller.profiles[1].access = { ...permissions.newMemberAccess(), role: "admin", owner: true };
  setLanguage("he");
  accessView({});
  await settle();
  await press(accessView({}), "access-edit-aaaa0001");
  // The fake refuses Dana: as the owner's.
  controller.profiles[0].access.owner = true;
  await press(accessView({}), "access-save-aaaa0001");
  assert.match(textOf(accessView({})), new RegExp(he.access.ownerProtected));
  setLanguage("en");
});

test("Invite someone: an admin, or a member and what they may do", async () => {
  connect();
  setLanguage("en");
  ui.inviteForm = true;
  stored.set("directorlink.remote", JSON.stringify({ home: "ab".repeat(16), keyId: "0a1b2c3d" }));
  state.account = { status: "signed-in", user: { email: "dana@example.com", providers: ["google"] }, notice: null, busy: false };
  const page = settingsView({ page: "account" });
  const form = byKey(page, "invite-access");
  assert.ok(form, "the person's choices are in the form");
  assert.equal(byKey(page, "invite-role"), null, "no four roles with 1.8.0");
  assert.ok(byKey(form, "invite-role:member"));
  assert.ok(byKey(form, "invite-kind-music"));
  assert.ok(byKey(form, "invite-doors"));
  // A member without music, and with the Good night scene.
  ui.drafts["invite-email"] = "noa@example.com";
  byKey(form, "invite-kind-music").listeners.change[0]({ target: { checked: false } });
  byKey(form, `invite-scene-${NIGHT}`).listeners.change[0]({ target: { checked: true } });
  const submit = byKey(page, "invite-create");
  const formElement = (() => {
    let found = null;
    walk(page, (node) => {
      if (!found && node.tagName === "FORM") found = node;
    });
    return found;
  })();
  assert.ok(submit && formElement);
  await Promise.all(formElement.listeners.submit.map((listener) => listener({ preventDefault() {} })));
  await settle();
  const sent = calls("POST", "/v1/invitations");
  assert.equal(sent.length, 1);
  assert.equal(sent[0].body.role, "member");
  assert.equal(sent[0].body.email, "noa@example.com");
  assert.equal(sent[0].body.access.kinds.music, false);
  assert.deepEqual(sent[0].body.access.scenes, [NIGHT]);
  assert.equal(sent[0].body.access.all_rooms, true);
  assert.equal(ui.inviteAccess, null, "a new invitation starts afresh");
  ui.homeInvitation = null;
  // An older controller keeps its four roles.
  connect({ old: true });
  ui.inviteForm = true;
  stored.set("directorlink.remote", JSON.stringify({ home: "ab".repeat(16), keyId: "0a1b2c3d" }));
  state.account = { status: "signed-in", user: { email: "dana@example.com", providers: ["google"] }, notice: null, busy: false };
  const older = settingsView({ page: "account" });
  assert.ok(byKey(older, "invite-role"));
  assert.equal(byKey(older, "invite-access"), null);
  stored.delete("directorlink.remote");
  ui.inviteForm = false;
});

test("Settings → Rooms: an admin hides a room from members", async () => {
  connect();
  setLanguage("en");
  let page = settingsView({ page: "rooms" });
  assert.match(textOf(page), /Hide from members keeps a room/);
  await press(page, "room-members:10");
  assert.deepEqual(calls("PATCH", "/v1/rooms/10")[0].body, { hidden_from_members: true });
  assert.equal(state.rooms[0].hidden_from_members, true);
  page = settingsView({ page: "rooms" });
  assert.equal(textOf(byKey(page, "room-members-hidden:10")), "Hidden from members");
  assert.equal(byKey(page, "room-members:10").attributes["aria-pressed"], "true");
  // Not for members, nor with an older controller.
  connect({ access: { ...MEMBER_ACCESS } });
  assert.equal(byKey(settingsView({ page: "rooms" }), "room-members:10"), null);
  connect({ old: true });
  assert.equal(byKey(settingsView({ page: "rooms" }), "room-members:10"), null);
});

test("a member's app shows no schedules; an admin's does, and an older controller's members still do", () => {
  connect({ access: { ...MEMBER_ACCESS } });
  setLanguage("en");
  assert.equal(scenesNav("scenes"), null, "Scenes alone");
  const view = schedulesView();
  assert.match(textOf(view), /Schedules are set by the home’s admins\./);
  assert.equal(calls("GET", "/v1/schedules").length, 0, "nothing asked for");
  connect();
  assert.ok(scenesNav("scenes"));
  connect({ access: null, old: true });
  state.role = "member";
  assert.ok(scenesNav("scenes"));
});

test("every new word is there in English and Hebrew", () => {
  const keys = (object, prefix = "") => Object.entries(object).flatMap(([key, value]) => (value && typeof value === "object" && !("other" in value) ? keys(value, `${prefix}${key}.`) : [`${prefix}${key}`]));
  const english = keys(en.perm);
  assert.deepEqual(keys(he.perm).sort(), english.sort());
  for (const key of ["persons", "personsHelp", "accounts", "you", "edit", "save", "personSaved", "makeAdminConfirm", "makeMemberConfirm", "ownerProtected", "ownerStaysAdmin", "lastAdminPerson", "moveConfirmAccess"]) {
    assert.ok(en.access[key] && he.access[key], key);
  }
  for (const key of ["hiddenFromMembers", "hideFromMembers", "showToMembers", "membersHelp"]) assert.ok(en.settings.rooms[key] && he.settings.rooms[key], key);
  assert.ok(en.schedules.adminsOnly && he.schedules.adminsOnly);
  for (const key of ["permissions_changed", "room_hidden", "room_shown"]) assert.ok(en.history.access[key] && he.history.access[key], key);
});
