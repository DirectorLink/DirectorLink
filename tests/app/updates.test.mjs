// The update notice (app/js/updates.js): which release counts as newer, when GitHub is asked (admin
// keys only, with a known driver version, at most every 12 hours), and answers that never replace
// the last one: a 404, a malformed answer, a release without DirectorLink.c4z.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import {
  CHECK_INTERVAL_MS,
  LATEST_RELEASE_URL,
  checkForUpdate,
  compareVersions,
  dismissUpdate,
  dismissedVersion,
  newerRelease,
  parseVersion,
  readRelease,
  savedCheck,
} from "../../app/js/updates.js";

const RELEASES = "https://github.com/IsraelCIL/DirectorLink/releases";
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
    ["release notes elsewhere", answer("1.2.0", { html_url: "https://example.com/IsraelCIL/DirectorLink/releases/tag/v1.2.0" })],
    ["a script link", answer("1.2.0", { html_url: "javascript:alert(1)" })],
    ["a link out of the releases", answer("1.2.0", { html_url: `${RELEASES}/../../../other/releases/tag/v1.2.0` })],
    ["another user on github.com", answer("1.2.0", { html_url: "https://github.com@example.com/IsraelCIL/DirectorLink/releases/tag/v1.2.0" })],
  ]) {
    assert.equal(readRelease(value), null, what);
  }
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
  assert.deepEqual(savedCheck(storage), { checkedAt: NOW, release: readRelease(answer("1.1.0")) });
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
    storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW - 13 * HOUR, release: known }));
    assert.equal(await checkForUpdate(admin({ storage, fetch })), false, what);
    assert.deepEqual(savedCheck(storage), { checkedAt: NOW, release: known }, `${what}: the last answer stays`);
    // The next try is 12 hours later, not at the next refresh.
    const { fetch: again, calls } = github(200, answer("1.2.0"));
    await checkForUpdate(admin({ storage, fetch: again, now: NOW + HOUR }));
    assert.equal(calls.length, 0, `${what}: no new request within 12 hours`);
  }
  // Without an earlier answer, a failure leaves nothing to show.
  const storage = memoryStorage();
  await checkForUpdate(admin({ storage, fetch: github(404, { message: "Not Found" }).fetch }));
  assert.deepEqual(savedCheck(storage), { checkedAt: NOW, release: null });
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
  storage.setItem("directorlink.update", JSON.stringify({ checkedAt: NOW, release: { ...release, download: "javascript:alert(1)" } }));
  assert.deepEqual(savedCheck(storage), { checkedAt: NOW, release: null });
  storage.setItem("directorlink.update", "{not json");
  assert.equal(savedCheck(storage), null);
  storage.setItem("directorlink.update", JSON.stringify({ release }));
  assert.equal(savedCheck(storage), null, "no time: asked again");
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
  assert.equal(savedCheck(blocked), null);
  assert.doesNotThrow(() => dismissUpdate("1.1.0", blocked));
  assert.equal(dismissedVersion(blocked), null);
  assert.equal(savedCheck(null), null);
});
