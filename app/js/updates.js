// Whether a newer DirectorLink release is out, for admins (docs/DECISIONS.md, ADR-035). The driver
// is still updated in Composer: the app only says when, links that release's DirectorLink.c4z and
// shows the steps (views/updates.js).
//
// The answer comes from GitHub's public releases API, asked by the admin's own device at most every
// 12 hours: GitHub sees that device's IP address, and nothing about the home is sent. The release
// notes are Markdown written on GitHub, so their text is never used here; only the version, the
// date and links into the project's own releases are kept. Storage, fetch and the clock can be
// passed in, so this is unit-tested in Node (tests/app/updates.test.mjs).

export const LATEST_RELEASE_URL = "https://api.github.com/repos/IsraelCIL/DirectorLink/releases/latest";
// About twice a day: GitHub allows 60 requests an hour per address without a token, and the privacy
// page (site/privacy.html) says how often the app asks.
export const CHECK_INTERVAL_MS = 12 * 60 * 60 * 1000;
// "Up to date" is said only this long after GitHub's last answer. After that Settings says the
// check did not work; a newer release already known is still offered.
export const ANSWER_FRESH_MS = 3 * 24 * 60 * 60 * 1000;
export const PACKAGE_NAME = "DirectorLink.c4z";
const CHECKSUMS_NAME = "SHA256SUMS.txt";
// Every link taken from an answer must lead into this project's releases, and nowhere else.
const RELEASES = "https://github.com/IsraelCIL/DirectorLink/releases/";
const TIMEOUT_MS = 10000;
// In this browser only, for this viewer: the last check { checkedAt, answeredAt, release }, and
// the version whose notice on Home was dismissed.
const CHECK_KEY = "directorlink.update";
const DISMISSED_KEY = "directorlink.updateDismissed";

// "1.0.0" -> [1, 0, 0]. "dev" (a development build), "1.0", "1.0.0-beta" or anything else that is
// not MAJOR.MINOR.PATCH -> null: the version is unknown, and no update is offered for it.
export function parseVersion(value) {
  const match = typeof value === "string" ? /^(\d{1,6})\.(\d{1,6})\.(\d{1,6})$/.exec(value) : null;
  return match ? match.slice(1).map(Number) : null;
}

// Below 0 when a is older than b, 0 when the same, above 0 when newer; part by part as numbers
// (1.10.0 is newer than 1.9.0). NaN when either is unknown.
export function compareVersions(a, b) {
  const left = parseVersion(a);
  const right = parseVersion(b);
  if (!left || !right) return Number.NaN;
  const part = left.findIndex((value, index) => value !== right[index]);
  return part < 0 ? 0 : Math.sign(left[part] - right[part]);
}

// The release, when it is newer than the driver's version; null when the driver is as new (or
// newer: a test build), or its version is unknown.
export function newerRelease(driverVersion, release) {
  return release && compareVersions(release.version, driverVersion) > 0 ? release : null;
}

// A link from an answer, as the browser would read it, when it points into the project's releases
// (a "../" or another host cannot pass once the address is resolved).
function releaseLink(value) {
  if (typeof value !== "string") return null;
  try {
    const href = new URL(value).href;
    return href.startsWith(RELEASES) ? href : null;
  } catch {
    return null;
  }
}

// The shape kept and shown, checked again when it is read back from storage.
function usable(release) {
  if (!release || typeof release !== "object" || !parseVersion(release.version)) return null;
  const tag = `v${release.version}`;
  const url = releaseLink(release.url);
  const download = releaseLink(release.download);
  // Exactly this release's package: not another tag's, and not "DirectorLink (1).c4z".
  if (!url || download !== `${RELEASES}download/${tag}/${PACKAGE_NAME}`) return null;
  const published = typeof release.publishedAt === "string" ? Date.parse(release.publishedAt) : Number.NaN;
  return {
    version: release.version,
    // Plain text, used only as a tooltip.
    name: typeof release.name === "string" ? release.name.slice(0, 100) : "",
    publishedAt: Number.isFinite(published) ? new Date(published).toISOString() : null,
    url,
    download,
    checksums: releaseLink(release.checksums),
  };
}

// GitHub's answer for the latest release -> { version, name, publishedAt, url, download, checksums },
// or null when it is not a complete, published DirectorLink release: another shape (an error, a
// 404's message), a tag that is not vX.Y.Z, or no DirectorLink.c4z yet. SHA256SUMS.txt is optional.
// Only an immutable release counts: once published, its tag and files cannot be replaced (GitHub's
// immutable releases, on from 1.1.0; 1.0.0 and older are mutable). With the repository's setting
// off there is no notice, rather than one for files that could change.
export function readRelease(answer) {
  if (!answer || typeof answer !== "object" || answer.draft || answer.prerelease || answer.immutable !== true) return null;
  const match = /^v(\d+\.\d+\.\d+)$/.exec(typeof answer.tag_name === "string" ? answer.tag_name : "");
  if (!match) return null;
  const assets = Array.isArray(answer.assets) ? answer.assets : [];
  const link = (name) => assets.find((asset) => asset?.name === name)?.browser_download_url;
  return usable({
    version: match[1],
    name: answer.name,
    publishedAt: answer.published_at,
    url: answer.html_url,
    download: link(PACKAGE_NAME),
    checksums: link(CHECKSUMS_NAME),
  });
}

// ---- storage (a convenience: blocked storage only means asking again) ------------------------

function browserStorage() {
  try {
    return globalThis.localStorage;
  } catch {
    return null;
  }
}

function load(storage, key) {
  try {
    return storage.getItem(key);
  } catch {
    return null;
  }
}

function save(storage, key, value) {
  try {
    storage.setItem(key, value);
  } catch {
    // Private mode or blocked site data: nothing is remembered.
  }
}

// The last check: { checkedAt, answeredAt, release }, or null. checkedAt is the last try,
// answeredAt the last time GitHub answered with a complete release, and release that answer (both
// null until GitHub has answered once). A record without answeredAt, kept before there was one,
// may hold an answer of any age: it counts as none, so GitHub is asked again.
export function savedCheck(storage = browserStorage()) {
  try {
    const saved = JSON.parse(load(storage, CHECK_KEY) || "null");
    const checkedAt = Number(saved?.checkedAt);
    const answeredAt = saved?.answeredAt === null ? null : Number(saved?.answeredAt);
    if (!Number.isFinite(checkedAt) || (answeredAt !== null && !Number.isFinite(answeredAt))) return null;
    return { checkedAt, answeredAt, release: usable(saved.release) };
  } catch {
    return null;
  }
}

function saveCheck(storage, check) {
  save(storage, CHECK_KEY, JSON.stringify(check));
}

export function dismissedVersion(storage = browserStorage()) {
  const version = load(storage, DISMISSED_KEY);
  return parseVersion(version) ? version : null;
}

// The notice on Home stays hidden for this version; a newer one shows it again.
export function dismissUpdate(version, storage = browserStorage()) {
  if (parseVersion(version)) save(storage, DISMISSED_KEY, version);
}

// ---- asking GitHub ---------------------------------------------------------------------------

// Only admin keys ask, only with a driver of a known version, and only 12 hours after the last
// try. A clock that went back (a saved time in the future) asks again.
export function checkDue({ role, driverVersion, check, now }) {
  if (role !== "admin" || !parseVersion(driverVersion)) return false;
  const at = Number(check?.checkedAt);
  return !Number.isFinite(at) || now - at >= CHECK_INTERVAL_MS || now < at;
}

async function latestRelease(fetchRelease) {
  try {
    const response = await fetchRelease(LATEST_RELEASE_URL, {
      // A simple CORS request (no preflight), without cookies or the page's address.
      headers: { Accept: "application/vnd.github+json" },
      credentials: "omit",
      referrerPolicy: "no-referrer",
      signal: typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function" ? AbortSignal.timeout(TIMEOUT_MS) : undefined,
    });
    return response.ok ? readRelease(await response.json()) : null;
  } catch {
    return null;
  }
}

// GitHub's last answer is less than 3 days old (one dated after this clock's now is of unknown age).
function recentAnswer(check, now) {
  if (!Number.isFinite(check?.answeredAt)) return false;
  const age = now - check.answeredAt;
  return age >= 0 && age < ANSWER_FRESH_MS;
}

let running = null;

// Asks GitHub when it is time (checkDue) and saves the answer. Resolves true when what the screens
// show may have changed. Failures are silent: a 404, a rate limit, an answer that is not a complete
// release or no connection keep the last answer and its time, and the next try is 12 hours later,
// so a device without internet does not ask every minute. The try is saved before asking, so
// another tab does not ask as well.
export function checkForUpdate({
  role,
  driverVersion,
  storage = browserStorage(),
  fetch: fetchRelease = globalThis.fetch,
  now = Date.now(),
  online = globalThis.navigator?.onLine !== false,
} = {}) {
  if (running) return running;
  const before = savedCheck(storage);
  if (!online || typeof fetchRelease !== "function" || !checkDue({ role, driverVersion, check: before, now })) {
    return Promise.resolve(false);
  }
  saveCheck(storage, { checkedAt: now, answeredAt: before?.answeredAt ?? null, release: before?.release ?? null });
  running = latestRelease(fetchRelease)
    .then((release) => {
      // Without an earlier answer, Settings now says that the check did not work.
      if (!release) return !Number.isFinite(before?.answeredAt);
      saveCheck(storage, { checkedAt: now, answeredAt: now, release });
      return !recentAnswer(before, now) || JSON.stringify(release) !== JSON.stringify(before.release);
    })
    .finally(() => {
      running = null;
    });
  return running;
}

// What Settings says, from the last check: { release } when it is newer than the driver, also when
// later checks failed (the notice on Home too); { upToDate: true } while GitHub's last answer is
// less than 3 days old; otherwise { answeredAt } (null: GitHub never answered), the check did not
// work. null for other keys, a driver of unknown version, before the first try, and while GitHub
// is asked for a first answer.
export function updateStatus({ role, driverVersion, check, now = Date.now() }) {
  if (role !== "admin" || !parseVersion(driverVersion) || !check || (running && check.answeredAt === null)) return null;
  const release = newerRelease(driverVersion, check.release);
  if (release) return { release };
  return recentAnswer(check, now) ? { upToDate: true } : { answeredAt: check.answeredAt };
}
