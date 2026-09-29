// What admins see of the update notice (app/js/views/updates.js): the Updates line in Settings, the
// steps and the notice on Home, and the rooms refresh (app/js/session.js) that notices a driver
// updated in Composer while the app is open.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

// Just enough of a browser for these modules: the elements the views build, storage and frames.
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener() {}
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io" };
globalThis.document = {
  hidden: false,
  documentElement: {},
  addEventListener() {},
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};

const { state } = await import("../../app/js/state.js");
const { formatDate, setLanguage } = await import("../../app/js/i18n.js");
const { refreshRooms, whenConnected } = await import("../../app/js/session.js");
const { checkUpdates, updateBanner, updateFact, updatePanel } = await import("../../app/js/views/updates.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;
const RELEASES = "https://github.com/IsraelCIL/DirectorLink/releases";

// A release as js/updates.js keeps it.
const release = (version) => ({
  version,
  name: `DirectorLink v${version}`,
  publishedAt: "2026-09-30T08:00:00.000Z",
  url: `${RELEASES}/tag/v${version}`,
  download: `${RELEASES}/download/v${version}/DirectorLink.c4z`,
  checksums: `${RELEASES}/download/v${version}/SHA256SUMS.txt`,
});

// An admin key, with a driver of this version (GET /v1/system).
function admin(version) {
  state.role = "admin";
  state.system = { bridge: { version } };
}

// The last check as js/updates.js saves it: GitHub answered with `latest` `answered` ms ago
// (null: never), and the last try was `tried` ms ago. Returns the record.
function lastCheck(latest, answered, tried = answered ?? HOUR) {
  const now = Date.now();
  const check = { checkedAt: now - tried, answeredAt: answered === null ? null : now - answered, release: latest };
  localStorage.setItem("directorlink.update", JSON.stringify(check));
  return check;
}

// A day as the Updates line writes it: on one line.
const day = (time) => formatDate(new Date(time)).replace(/ /g, " ");

test("Settings says Up to date only within 3 days of GitHub's last answer", () => {
  admin("1.1.0");
  lastCheck(release("1.1.0"), 2 * DAY);
  assert.deepEqual(updateFact(), ["Updates", "Up to date"]);
  // GitHub answered 4 days ago, and every try since failed (a rate limit, no connection).
  const old = lastCheck(release("1.1.0"), 4 * DAY, HOUR);
  assert.deepEqual(updateFact(), ["Updates", `Could not check for updates (last checked ${day(old.answeredAt)})`]);
  lastCheck(null, null);
  assert.deepEqual(updateFact(), ["Updates", "Could not check for updates"], "GitHub never answered");
  // A newer release stays offered, however old the answer.
  lastCheck(release("1.2.0"), 30 * DAY, HOUR);
  assert.match(updateFact()[1], /^DirectorLink 1\.2\.0 is available/);
  assert.ok(updatePanel(), "with its steps");
  assert.ok(updateBanner(), "and the notice on Home");
});

test("the Updates line is in Hebrew too", async () => {
  await setLanguage("he");
  try {
    admin("1.1.0");
    const old = lastCheck(release("1.1.0"), 4 * DAY, HOUR);
    const [label, value] = updateFact();
    assert.equal(label, he.updates.label);
    assert.match(value, /^[א-ת]/, "Hebrew, not the English text");
    assert.ok(value.includes(day(old.answeredAt)), value);
    lastCheck(null, null);
    assert.match(updateFact()[1], /^[א-ת]/);
  } finally {
    await setLanguage("en");
  }
});

test("step 1 says to delete the older DirectorLink.c4z first, not to rename the new file", () => {
  // A browser saves "DirectorLink (1).c4z" only when DirectorLink.c4z is already in that folder,
  // so renaming the new file would clash with the older one.
  assert.match(en.updates.steps.download, /delete the older DirectorLink\.c4z/);
  assert.match(en.updates.steps.download, /empty folder/);
  assert.doesNotMatch(en.updates.steps.download, /rename/i);
  assert.match(he.updates.steps.download, /מחקו/);
  assert.match(he.updates.steps.download, /תיקייה ריקה/);
  assert.doesNotMatch(he.updates.steps.download, /שנו את השם/);
});

// Every element in `root` that takes focus.
function focusable(root) {
  if (!(root instanceof FakeElement)) return [];
  const self = root.tagName === "A" || root.tagName === "BUTTON" || root.attributes.tabindex !== undefined ? [root] : [];
  return [...self, ...root.children.flatMap(focusable)];
}

test("the steps and the notice keep focus when the next poll redraws them", () => {
  admin("1.0.0");
  lastCheck(release("1.1.0"), HOUR);
  const panel = updatePanel();
  assert.equal(panel.attributes.id, "settings-update");
  // Following the notice on Home focuses this section; a redraw (app.js restoreUi) puts focus
  // back only on an element with the same data-key.
  assert.equal(panel.dataset.key, "settings-update");
  for (const element of [...focusable(panel), ...focusable(updateBanner())]) {
    assert.ok(element.dataset.key, `${element.tagName} "${element.textContent}" has a data-key`);
  }
});

// The controller as the rooms refresh finds it; its version is what GET /v1/system reports. It
// does not seal (like a driver before 1.0.0): how requests travel does not matter here. Returns
// what was asked, of the controller (paths) and of anyone else (addresses).
function controller({ version, systemStatus = 200 }) {
  const asked = [];
  globalThis.fetch = async (url) => {
    const address = new URL(url);
    asked.push(address.hostname === "192.0.2.10" ? address.pathname : url);
    const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
    switch (address.pathname) {
      case "/v1/sealed":
        return reply(404, { code: "NOT_FOUND" });
      case "/v1/system":
        return systemStatus === 200 ? reply(200, { bridge: { version, status: "ready" } }) : reply(systemStatus, { code: "UNAVAILABLE" });
      case "/v1/rooms":
        return reply(200, { items: [{ id: 1, name: "Kitchen" }] });
      case "/v1/api-keys/current":
        return reply(200, { id: "0badc0de", role: "admin" });
      default:
        return reply(200, { items: [] });
    }
  };
  return asked;
}

state.host = "192.0.2.10";
state.apiKey = "ak_test";
state.transport = "lan";
state.status = "connected";
state.loaded = true;
// As app.js: after each rooms refresh, whether it is time to ask GitHub.
whenConnected(checkUpdates);

test("a driver updated in Composer while the app is open: Up to date at the next rooms refresh", async () => {
  admin("1.0.0");
  lastCheck(release("1.1.0"), HOUR);
  assert.match(updateFact()[1], /^DirectorLink 1\.1\.0 is available/);
  // Update Driver reloads the driver in place: the app keeps polling, it does not reconnect.
  const asked = controller({ version: "1.1.0" });
  await refreshRooms();
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.ok(asked.includes("/v1/system"), "the refresh reads the driver's version again");
  assert.equal(state.system.bridge.version, "1.1.0", "Settings shows the new DirectorLink version");
  assert.deepEqual(updateFact(), ["Updates", "Up to date"]);
  assert.equal(updatePanel(), null);
  assert.equal(updateBanner(), null, "no notice on Home");
  assert.deepEqual(asked.filter((what) => what.startsWith("https:")), [], "GitHub is not asked again");
});

test("a failed GET /v1/system does not stop the rooms refresh", async () => {
  admin("1.0.0");
  state.rooms = [];
  const asked = controller({ version: "1.1.0", systemStatus: 503 });
  await refreshRooms();
  assert.ok(asked.includes("/v1/rooms"));
  assert.deepEqual(state.rooms, [{ id: 1, name: "Kitchen" }], "the rooms are refreshed");
  assert.equal(state.system.bridge.version, "1.0.0", "the version known so far stays");
});
