// The update notice (app/js/updates.js): which release counts as newer, when GitHub is asked (admin
// keys only, with a known driver version, at most every 12 hours), answers that never replace the
// last one (a 404, a malformed answer, a release without DirectorLink.c4z), only immutable releases
// offered, and "Up to date" only while GitHub's last answer is recent.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import {
  ANSWER_FRESH_MS,
  CHECK_INTERVAL_MS,
  LATEST_RELEASE_URL,
  MANUAL_INTERVAL_MS,
  checkForUpdate,
  compareVersions,
  dismissUpdate,
  dismissedVersion,
  manualCheckWait,
  newerRelease,
  parseVersion,
  readRelease,
  savedCheck,
  updateStatus,
} from "../../app/js/updates.js";

const RELEASES = "https://github.com/DirectorLink/DirectorLink/releases";
const NOW = Date.parse("2026-10-01T12:00:00Z");
const HOUR = 3600 * 1000;

// GitHub's answer for a release, with the fields api.github.com sends that DirectorLink reads, and
// a body that must never reach the page.
function answer(version, { assets = ["DirectorLink.c4z", "openapi.json", "SHA256SUMS.txt"], ...fields } = {}) {
  const tag = `v${version}`;
  return {
    tag_name: tag,
    name: `DirectorLink ${tag}`,
    draft: false,
    prerelease: false,
    immutable: true,
    published_at: "2026-09-30T08:00:00Z",
    html_url: `${RELEASES}/tag/${tag}`,
    body: '# DirectorLink\n\n<img src="x" onerror="alert(1)">',
    assets: assets.map((name) => ({ name, browser_download_url: `${RELEASES}/download/${tag}/${name}`, size: 1000 })),
    ...fields,
  };
}

function memoryStorage() {
  const items = new Map();
  return {
    items,
    getItem: (key) => (items.has(key) ? items.get(key) : null),
    setItem: (key, value) => items.set(key, String(value)),
    removeItem: (key) => items.delete(key),
  };
}

// fetch standing in for api.github.com: answers `status` with `body`, and records each request.
function github(status, body) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
  };
  return { fetch, calls };
}

const admin = (options) => ({ role: "admin", driverVersion: "1.0.0", now: NOW, online: true, ...options });

test("versions compare part by part, as numbers", () => {
  assert.deepEqual(parseVersion("1.0.0"), [1, 0, 0]);
  assert.ok(compareVersions("1.10.0", "1.9.0") > 0, "1.10.0 is newer than 1.9.0");
  assert.ok(compareVersions("1.0.10", "1.0.9") > 0);
  assert.ok(compareVersions("2.0.0", "1.99.99") > 0);
  assert.ok(compareVersions("1.0.0", "1.1.0") < 0);
  assert.equal(compareVersions("1.1.0", "1.1.0"), 0);
  // A development build, or anything that is not MAJOR.MINOR.PATCH, is unknown.
  for (const unknown of ["dev", "1.0", "1.0.0-beta", "v1.0.0", " 1.0.0", "1.0.0.1", "", null, undefined, 100]) {
    assert.equal(parseVersion(unknown), null, String(unknown));
    assert.ok(Number.isNaN(compareVersions(unknown, "1.0.0")), String(unknown));
  }
});

test("a release is offered only when it is newer than a driver of a known version", () => {
  const release = readRelease(answer("1.1.0"));
  assert.equal(newerRelease("1.0.0", release), release);
  assert.equal(newerRelease("1.0.9", release), release);
  assert.equal(newerRelease("1.1.0", release), null, "up to date");
  assert.equal(newerRelease("1.2.0", release), null, "a newer test build");
  assert.equal(newerRelease("dev", release), null, "a development build");
  assert.equal(newerRelease(undefined, release), null, "no version yet");
  assert.equal(newerRelease("1.0.0", null), null, "no release known");
});

test("GitHub's answer is read into the version, the date and links into the project's releases", () => {
  assert.deepEqual(readRelease(answer("1.2.0")), {
    version: "1.2.0",
    name: "DirectorLink v1.2.0",
    publishedAt: "2026-09-30T08:00:00.000Z",
    url: `${RELEASES}/tag/v1.2.0`,
    download: `${RELEASES}/download/v1.2.0/DirectorLink.c4z`,
    checksums: `${RELEASES}/download/v1.2.0/SHA256SUMS.txt`,
    locked: true,
  });
  // The release notes' text is never kept.
  assert.equal(JSON.stringify(readRelease(answer("1.2.0"))).includes("onerror"), false);
  // No date, or an unreadable one, is left out; the release stays.
  assert.equal(readRelease(answer("1.2.0", { published_at: null })).publishedAt, null);
  assert.equal(readRelease(answer("1.2.0", { published_at: "soon" })).publishedAt, null);
  assert.equal(readRelease(answer("1.2.0", { name: 42 })).name, "");
});

test("a release without DirectorLink.c4z is not offered; one without SHA256SUMS.txt is", () => {
  assert.equal(readRelease(answer("1.2.0", { assets: ["openapi.json", "SHA256SUMS.txt"] })), null);
  assert.equal(readRelease(answer("1.2.0", { assets: [] })), null);
  const noAssets = answer("1.2.0");
  delete noAssets.assets;
  assert.equal(readRelease(noAssets), null);
  assert.equal(readRelease(answer("1.2.0", { assets: ["DirectorLink (1).c4z"] })), null);
  // The package of another release, or from elsewhere, is not this release's.
  const otherTag = answer("1.2.0");
  otherTag.assets[0].browser_download_url = `${RELEASES}/download/v1.1.0/DirectorLink.c4z`;
  assert.equal(readRelease(otherTag), null);
  const elsewhere = answer("1.2.0");
  elsewhere.assets[0].browser_download_url = "https://example.com/DirectorLink.c4z";
  assert.equal(readRelease(elsewhere), null);
  const release = readRelease(answer("1.2.0", { assets: ["DirectorLink.c4z"] }));
  assert.equal(release.download, `${RELEASES}/download/v1.2.0/DirectorLink.c4z`);
  assert.equal(release.checksums, null);
});

test("malformed answers, drafts and links out of the project's releases are refused", () => {
  for (const [what, value] of [
    ["nothing", null],
    ["a 404's answer", { message: "Not Found", documentation_url: "https://docs.github.com/rest" }],
    ["a rate limit's answer", { message: "API rate limit exceeded" }],
    ["a list", [answer("1.2.0")]],
    ["text", "v1.2.0"],
    ["a tag without v", answer("1.2.0", { tag_name: "1.2.0" })],
    ["another tag", answer("1.2.0", { tag_name: "latest" })],
    ["a pre-release tag", answer("1.2.0", { tag_name: "v1.2.0-beta.1" })],
    ["a draft", answer("1.2.0", { draft: true })],
    ["a pre-release", answer("1.2.0", { prerelease: true })],
    ["release notes elsewhere", answer("1.2.0", { html_url: "https://example.com/DirectorLink/DirectorLink/releases/tag/v1.2.0" })],
    ["a script link", answer("1.2.0", { html_url: "javascript:alert(1)" })],
    ["a link out of the releases", answer("1.2.0", { html_url: `${RELEASES}/../../../other/releases/tag/v1.2.0` })],
    ["another user on github.com", answer("1.2.0", { html_url: "https://github.com@example.com/DirectorLink/DirectorLink/releases/tag/v1.2.0" })],
  ]) {
    assert.equal(readRelease(value), null, what);
  }
});

test("only an immutable release is offered: its files cannot be replaced once published", () => {
  assert.equal(readRelease(answer("1.2.0")).locked, true);
  assert.equal(newerRelease("1.0.0", readRelease(answer("1.2.0"))).version, "1.2.0");
  // Releases up to 1.0.0 were published mutable; so would be one published with the setting off.
  const unknown = answer("1.2.0");
  delete unknown.immutable;
  for (const [what, mutable] of [["mutable", answer("1.2.0", { immutable: false })], ["only true itself", answer("1.2.0", { immutable: "true" })], ["not said", unknown]]) {
    const release = readRelease(mutable);
    assert.equal(release.locked, false, what);
    assert.equal(newerRelease("1.0.0", release), null, `${what}: never offered`);
    // Newer but not offered: Settings says the check did not work, never Up to date.
    assert.deepEqual(updateStatus({ role: "admin", driverVersion: "1.0.0", check: { checkedAt: NOW, answeredAt: NOW, release }, now: NOW }), { answeredAt: NOW }, what);
  }
  // A saved release is read back as immutable only when it said so.
  const storage = memoryStorage();
  const { locked, ...unmarked } = readRelease(answer("1.2.0"));
  storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW, answeredAt: NOW, release: unmarked }));
  assert.equal(savedCheck(storage).release.locked, false);
});

test("a mutable latest release that is not newer still says Up to date", async () => {
  // Today's latest release, 1.0.0, was published mutable: an admin on 1.0.0 is up to date.
  const storage = memoryStorage();
  const { fetch } = github(200, answer("1.0.0", { immutable: false }));
  assert.equal(await checkForUpdate(admin({ storage, fetch })), true);
  assert.deepEqual(updateStatus({ role: "admin", driverVersion: "1.0.0", check: savedCheck(storage), now: NOW }), { upToDate: true });
  assert.deepEqual(updateStatus({ role: "admin", driverVersion: "1.1.0", check: savedCheck(storage), now: NOW }), { upToDate: true }, "a newer driver");
});

test("only admin keys ask GitHub, and only with a driver of a known version", async () => {
  for (const options of [{ role: "member" }, { role: "doors" }, { role: "viewer" }, { role: null }, { driverVersion: "dev" }, { driverVersion: undefined }]) {
    const storage = memoryStorage();
    const { fetch, calls } = github(200, answer("1.1.0"));
    assert.equal(await checkForUpdate(admin({ ...options, storage, fetch })), false, JSON.stringify(options));
    assert.equal(calls.length, 0, `no request for ${JSON.stringify(options)}`);
    assert.equal(savedCheck(storage), null);
  }
  const storage = memoryStorage();
  const { fetch, calls } = github(200, answer("1.1.0"));
  assert.equal(await checkForUpdate(admin({ storage, fetch })), true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, LATEST_RELEASE_URL);
  assert.equal(calls[0].init.credentials, "omit", "no cookies");
  assert.equal(calls[0].init.referrerPolicy, "no-referrer");
  // Only headers that keep it a simple CORS request (no preflight).
  assert.deepEqual(Object.keys(calls[0].init.headers), ["Accept"]);
  assert.deepEqual(savedCheck(storage), { checkedAt: NOW, answeredAt: NOW, release: readRelease(answer("1.1.0")) });
});

test("GitHub is asked at most every 12 hours", async () => {
  const storage = memoryStorage();
  const { fetch, calls } = github(200, answer("1.1.0"));
  await checkForUpdate(admin({ storage, fetch }));
  assert.equal(await checkForUpdate(admin({ storage, fetch, now: NOW + 11 * HOUR })), false);
  assert.equal(await checkForUpdate(admin({ storage, fetch, now: NOW + CHECK_INTERVAL_MS - 1 })), false);
  assert.equal(calls.length, 1, "the saved answer is used for 12 hours");
  // The same answer again: asked, but nothing to redraw.
  assert.equal(await checkForUpdate(admin({ storage, fetch, now: NOW + CHECK_INTERVAL_MS })), false);
  assert.equal(calls.length, 2, "asked again after 12 hours");
  assert.equal(savedCheck(storage).checkedAt, NOW + CHECK_INTERVAL_MS);
  // A clock that went back does not wait until it catches up.
  await checkForUpdate(admin({ storage, fetch, now: NOW }));
  assert.equal(calls.length, 3);
  // Two checks at once send one request.
  const later = NOW + 2 * CHECK_INTERVAL_MS;
  await Promise.all([checkForUpdate(admin({ storage, fetch, now: later })), checkForUpdate(admin({ storage, fetch, now: later }))]);
  assert.equal(calls.length, 4);
});

test("a 404, a rate limit, a malformed answer or no connection keep the last answer for 12 hours", async () => {
  const known = readRelease(answer("1.1.0"));
  const failures = [
    ["404", github(404, { message: "Not Found" }).fetch],
    ["rate limit", github(403, { message: "API rate limit exceeded" }).fetch],
    ["not JSON", github(200, "<html>unicorn</html>").fetch],
    ["not a release", github(200, { message: "hello" }).fetch],
    ["no DirectorLink.c4z yet", github(200, answer("1.2.0", { assets: ["openapi.json"] })).fetch],
    ["no connection", async () => { throw new TypeError("Failed to fetch"); }],
  ];
  for (const [what, fetch] of failures) {
    const storage = memoryStorage();
    storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW - 13 * HOUR, answeredAt: NOW - 13 * HOUR, release: known }));
    assert.equal(await checkForUpdate(admin({ storage, fetch })), false, what);
    // The time of GitHub's last answer is kept, not the time of this try.
    assert.deepEqual(savedCheck(storage), { checkedAt: NOW, answeredAt: NOW - 13 * HOUR, release: known }, `${what}: the last answer stays`);
    // The next try is 12 hours later, not at the next refresh.
    const { fetch: again, calls } = github(200, answer("1.2.0"));
    await checkForUpdate(admin({ storage, fetch: again, now: NOW + HOUR }));
    assert.equal(calls.length, 0, `${what}: no new request within 12 hours`);
  }
  // Without an earlier answer, a failure is what Settings shows now.
  const storage = memoryStorage();
  assert.equal(await checkForUpdate(admin({ storage, fetch: github(404, { message: "Not Found" }).fetch })), true);
  assert.deepEqual(savedCheck(storage), { checkedAt: NOW, answeredAt: null, release: null });
});

test("Up to date is said only within 3 days of GitHub's last answer; a newer release stays offered", () => {
  const release = readRelease(answer("1.1.0"));
  // Answered at NOW, and every try since failed.
  const check = { checkedAt: NOW + 6 * CHECK_INTERVAL_MS, answeredAt: NOW, release };
  const status = (driverVersion, now) => updateStatus({ role: "admin", driverVersion, check, now });
  assert.deepEqual(status("1.1.0", NOW), { upToDate: true });
  assert.deepEqual(status("1.1.0", NOW + ANSWER_FRESH_MS - 1), { upToDate: true });
  assert.deepEqual(status("1.1.0", NOW + ANSWER_FRESH_MS), { answeredAt: NOW }, "then: could not check, last answered at NOW");
  assert.deepEqual(status("1.2.0", NOW + ANSWER_FRESH_MS), { answeredAt: NOW }, "a newer test build is not up to date either");
  // A newer release is offered however old the answer is.
  assert.deepEqual(status("1.0.0", NOW + 30 * 24 * HOUR), { release });
  // A clock that went back does not make an answer recent.
  assert.deepEqual(status("1.1.0", NOW - HOUR), { answeredAt: NOW });
  // GitHub never answered.
  assert.deepEqual(updateStatus({ role: "admin", driverVersion: "1.1.0", check: { checkedAt: NOW, answeredAt: null, release: null }, now: NOW }), { answeredAt: null });
  // Nothing at all for other keys, a development build, or before the first try.
  for (const [role, driverVersion, saved] of [["member", "1.0.0", check], ["admin", "dev", check], ["admin", undefined, check], ["admin", "1.0.0", null]]) {
    assert.equal(updateStatus({ role, driverVersion, check: saved, now: NOW }), null, `${role} ${driverVersion} ${saved}`);
  }
});

test("while the first check runs nothing is said; when it fails, Settings says so", async () => {
  const storage = memoryStorage();
  let reply;
  const fetch = () => new Promise((resolve) => {
    reply = resolve;
  });
  const status = () => updateStatus({ role: "admin", driverVersion: "1.0.0", check: savedCheck(storage), now: NOW });
  const pending = checkForUpdate(admin({ storage, fetch }));
  try {
    assert.equal(status(), null, "not 'could not check' while asking");
  } finally {
    // Answered in any case: a check left running would hold every later one.
    reply(new Response(JSON.stringify({ message: "API rate limit exceeded" }), { status: 403 }));
  }
  assert.equal(await pending, true);
  assert.deepEqual(status(), { answeredAt: null });
});

test("an answer after failed checks brings Up to date back", async () => {
  const storage = memoryStorage();
  const known = readRelease(answer("1.1.0"));
  storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW - 13 * HOUR, answeredAt: NOW - 4 * 24 * HOUR, release: known }));
  const status = () => updateStatus({ role: "admin", driverVersion: "1.1.0", check: savedCheck(storage), now: NOW });
  assert.deepEqual(status(), { answeredAt: NOW - 4 * 24 * HOUR });
  // The same release as before, but Settings changes: resolves true, so the screen is redrawn.
  assert.equal(await checkForUpdate(admin({ storage, fetch: github(200, answer("1.1.0")).fetch })), true);
  assert.deepEqual(status(), { upToDate: true });
});

test("offline, nothing is asked and the 12 hours do not start", async () => {
  const storage = memoryStorage();
  const { fetch, calls } = github(200, answer("1.1.0"));
  assert.equal(await checkForUpdate(admin({ storage, fetch, online: false })), false);
  assert.equal(calls.length, 0);
  assert.equal(savedCheck(storage), null);
  await checkForUpdate(admin({ storage, fetch }));
  assert.equal(calls.length, 1, "asked once back online");
});

test("a saved answer is checked again when it is read", () => {
  const storage = memoryStorage();
  const release = readRelease(answer("1.1.0"));
  storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW, answeredAt: NOW, release: { ...release, download: "javascript:alert(1)" } }));
  assert.deepEqual(savedCheck(storage), { checkedAt: NOW, answeredAt: NOW, release: null });
  storage.setItem("directorlink.update", "{not json");
  assert.equal(savedCheck(storage), null);
  storage.setItem("directorlink.update", JSON.stringify({ answeredAt: NOW, release }));
  assert.equal(savedCheck(storage), null, "no time: asked again");
  storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW, answeredAt: "yesterday", release }));
  assert.equal(savedCheck(storage), null, "no time of the answer: asked again");
  // Kept before the time of the answer was: its answer may be of any age, so it is asked again.
  storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW, release }));
  assert.equal(savedCheck(storage), null, "an older record: asked again");
});

test("the notice dismissed on Home is remembered per version", () => {
  const storage = memoryStorage();
  assert.equal(dismissedVersion(storage), null);
  dismissUpdate("1.1.0", storage);
  assert.equal(dismissedVersion(storage), "1.1.0");
  dismissUpdate("dev", storage);
  assert.equal(dismissedVersion(storage), "1.1.0", "only a version is saved");
});

test("blocked storage is not an error", async () => {
  const blocked = {
    getItem() {
      throw new DOMException("blocked", "SecurityError");
    },
    setItem() {
      throw new DOMException("blocked", "SecurityError");
    },
  };
  const { fetch } = github(200, answer("1.1.0"));
  assert.equal(await checkForUpdate(admin({ storage: blocked, fetch })), true);
  // Kept in this tab instead (below).
  assert.deepEqual(savedCheck(blocked), { checkedAt: NOW, answeredAt: NOW, release: readRelease(answer("1.1.0")) });
  assert.doesNotThrow(() => dismissUpdate("1.1.0", blocked));
  assert.equal(dismissedVersion(blocked), null);
  assert.equal(savedCheck(null), null);
});

test("with site data blocked, Check now's minute and the 12 hours still hold in this tab", async () => {
  const blocked = {
    getItem() {
      throw new DOMException("blocked", "SecurityError");
    },
    setItem() {
      throw new DOMException("blocked", "SecurityError");
    },
  };
  // No localStorage at all (reading it throws): browserStorage() gives null.
  for (const storage of [blocked, null]) {
    const { fetch, calls } = github(200, answer("1.1.0"));
    for (let press = 0; press < 5; press++) await checkForUpdate(admin({ storage, fetch, now: NOW + press * 1000, force: true }));
    assert.equal(calls.length, 1, "Check now pressed 5 times in 5 s: asked once");
    assert.equal(manualCheckWait({ check: savedCheck(storage), now: NOW + 5000 }), MANUAL_INTERVAL_MS - 5000);
    // The rooms refresh, once a minute, asks again only after 12 hours.
    for (let minute = 1; minute <= 5; minute++) await checkForUpdate(admin({ storage, fetch, now: NOW + minute * 60000 }));
    assert.equal(calls.length, 1, "not at every rooms refresh");
    await checkForUpdate(admin({ storage, fetch, now: NOW + CHECK_INTERVAL_MS }));
    assert.equal(calls.length, 2);
  }
  // A record in the storage (another tab's) is the one used.
  const storage = memoryStorage();
  await checkForUpdate(admin({ storage, fetch: github(200, answer("1.1.0")).fetch }));
  storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW + HOUR, answeredAt: NOW + HOUR, release: readRelease(answer("1.2.0")) }));
  assert.equal(savedCheck(storage).checkedAt, NOW + HOUR);
});

test("Check now asks at once, but never twice within a minute; the 12 hours start again from it", async () => {
  const storage = memoryStorage();
  const { fetch, calls } = github(200, answer("1.1.0"));
  assert.equal(await checkForUpdate(admin({ storage, fetch })), true);
  assert.equal(calls.length, 1);
  // An hour later the schedule does not ask; Check now does.
  assert.equal(await checkForUpdate(admin({ storage, fetch, now: NOW + HOUR })), false);
  assert.equal(calls.length, 1, "without Check now the 12 hours still hold");
  await checkForUpdate(admin({ storage, fetch, now: NOW + HOUR, force: true }));
  assert.equal(calls.length, 2, "Check now asks at once");
  // Pressed again 30 seconds later: it waits.
  assert.equal(manualCheckWait({ check: savedCheck(storage), now: NOW + HOUR + 30000 }), MANUAL_INTERVAL_MS - 30000);
  assert.equal(await checkForUpdate(admin({ storage, fetch, now: NOW + HOUR + 30000, force: true })), false);
  assert.equal(calls.length, 2, "not twice within a minute");
  // A minute after the last try it may ask again, and the 12 hours count from that try.
  const later = NOW + HOUR + MANUAL_INTERVAL_MS;
  assert.equal(manualCheckWait({ check: savedCheck(storage), now: later }), 0);
  await checkForUpdate(admin({ storage, fetch, now: later, force: true }));
  assert.equal(calls.length, 3);
  assert.equal(savedCheck(storage).checkedAt, later);
  assert.equal(await checkForUpdate(admin({ storage, fetch, now: later + CHECK_INTERVAL_MS - 1 })), false);
  assert.equal(calls.length, 3);
});

test("Check now is only for admin keys, with a driver of a known version", async () => {
  const { fetch, calls } = github(200, answer("1.1.0"));
  for (const options of [{ role: "member" }, { role: "viewer" }, { driverVersion: "dev" }, { driverVersion: undefined }]) {
    assert.equal(await checkForUpdate(admin({ storage: memoryStorage(), fetch, force: true, ...options })), false, JSON.stringify(options));
  }
  assert.equal(calls.length, 0);
  // Never checked, or a clock that went back: Check now may ask.
  assert.equal(manualCheckWait({ check: null, now: NOW }), 0);
  assert.equal(manualCheckWait({ check: { checkedAt: NOW + HOUR }, now: NOW }), 0);
});
