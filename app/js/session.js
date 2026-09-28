// Connection to the controller: first-time access, reconnecting with the saved key, loading
// and refreshing device state. Requests go over the home network (api-client.js), or sealed
// through the account (remote.js) when the home network cannot be reached and on iPhone and iPad.

import { loadAccount } from "./account.js";
import {
  ApiError,
  apiCall,
  apiImage,
  apiRequest,
  clearApiKey,
  normalizeHost,
  normalizePairingCode,
  saveApiKey,
  saveHost,
  savedApiKey,
  savedHost,
} from "../api-client.js";
import { notificationsOn, notifyRings, trackRings } from "./doorbells.js";
import { IS_IOS } from "./platform.js";
import { RemoteError, forgetRemote, remoteCall, remoteImage, savedRemote } from "./remote.js";
import { t } from "./i18n.js";
import { KINDS, notify, state } from "./state.js";

const POLL_MS = 10000;
// A refresh that fails is retried soon; only this many failures in a row mean "unreachable".
// One slow answer (a phone waking up, Wi-Fi busy with camera pictures) is not a disconnect.
const RETRY_MS = 2000;
const FAILURES_BEFORE_UNREACHABLE = 2;
let pollTimer = null;
// Run after connecting and with each rooms refresh (app.js: the profile).
const connectedHooks = [];

export function whenConnected(hook) {
  connectedHooks.push(hook);
}

function runConnectedHooks() {
  for (const hook of connectedHooks) {
    Promise.resolve()
      .then(hook)
      .catch((error) => console.warn("DirectorLink: after connecting", error));
  }
}
let failedRefreshes = 0;
let connectRun = 0;

// This device can reach its home: over the home network, or through the account.
export function reachable() {
  return Boolean(state.apiKey && ((state.host && !IS_IOS) || savedRemote()));
}

function useTransport(transport) {
  if (state.transport !== transport) {
    state.transport = transport;
    notify();
  }
}

// A request that got no answer on the home network goes through the account from then on, when
// this device has it; HTTP answers from the home are final.
function viaRemote(error) {
  return !error?.status && !(error instanceof RemoteError) && savedRemote() && state.apiKey;
}

export async function api(path, options = {}) {
  if (state.transport === "remote") {
    return remoteCall(state.apiKey, path, options);
  }
  try {
    return await apiCall(state.host, path, { apiKey: state.apiKey, ...options });
  } catch (error) {
    if (!viaRemote(error)) throw error;
    useTransport("remote");
    // Only reads are sent again: a command may have reached the home before its answer was lost,
    // and must not run twice. Pressing again sends it through the account.
    if ((options.method || "GET") !== "GET") throw error;
    return remoteCall(state.apiKey, path, options);
  }
}

// A camera picture, over whichever connection is in use.
export async function image(path) {
  if (state.transport === "remote") {
    return remoteImage(state.apiKey, path);
  }
  try {
    return await apiImage(state.host, path, { apiKey: state.apiKey });
  } catch (error) {
    if (!viaRemote(error)) throw error;
    useTransport("remote");
    return remoteImage(state.apiKey, path);
  }
}

const CHECK_IN_KEY = "directorlink.checkIn"; // { home, at }: this device's last sealed request
const CHECK_IN_MS = 24 * 3600 * 1000;

// A device linked to its home through the account sends one sealed request a day, even when it
// only uses the home network: the account service learns which key this account uses, so that
// revoking it at home also ends the membership (docs/ACCOUNTS.md). `force`: right away (linking).
export async function checkInThroughAccount(force = false) {
  const remote = savedRemote();
  if (!remote || !state.apiKey || state.account.status !== "signed-in") return;
  let last = null;
  try {
    last = JSON.parse(localStorage.getItem(CHECK_IN_KEY) || "null");
  } catch {
    last = null;
  }
  if (!force && last?.home === remote.home && Date.now() - Number(last.at) < CHECK_IN_MS) return;
  try {
    await remoteCall(state.apiKey, "/v1/api-keys/current");
    localStorage.setItem(CHECK_IN_KEY, JSON.stringify({ home: remote.home, at: Date.now() }));
  } catch {
    // Tried again at the next check.
  }
}

// Away from home, look once a minute whether the home network is back; it is faster. Only this
// home's controller, answering this key, counts: another network may have a device at the same
// address. Whatever it answers, the key is kept.
async function tryHomeNetwork() {
  const remote = savedRemote();
  if (state.transport !== "remote" || IS_IOS || !state.host || !remote) return;
  try {
    const result = await apiRequest(state.host, "/v1/remote", { apiKey: state.apiKey, timeoutMs: 2500 });
    if (result.ok && result.data?.home_id === remote.home) useTransport("lan");
  } catch {
    // Still away.
  }
}

// The new key's name, e.g. "Chrome on Windows" or "Safari on iPhone" (the API console lists it).
export function clientName() {
  const agent = navigator.userAgent || "";
  const brands = (navigator.userAgentData?.brands || []).map((item) => item.brand);
  const browser =
    brands.find((brand) => /Edge|Opera|Samsung/i.test(brand))?.replace(/^Microsoft /, "") ||
    (/Edg\//.test(agent) ? "Edge" : null) ||
    (/OPR\//.test(agent) ? "Opera" : null) ||
    (/SamsungBrowser\//.test(agent) ? "Samsung Internet" : null) ||
    (/Firefox\/|FxiOS\//.test(agent) ? "Firefox" : null) ||
    (/Chrome\/|CriOS\//.test(agent) ? "Chrome" : null) ||
    (/Safari\//.test(agent) ? "Safari" : null) ||
    "Browser";
  const platform = navigator.userAgentData?.platform || "";
  const system =
    (/iPhone/.test(agent) && "iPhone") ||
    ((/iPad/.test(agent) || (/Macintosh/.test(agent) && navigator.maxTouchPoints > 1)) && "iPad") ||
    ((/Android/.test(agent) || platform === "Android") && "Android") ||
    ((/Windows/.test(agent) || platform === "Windows") && "Windows") ||
    ((/CrOS/.test(agent) || platform === "Chrome OS") && "ChromeOS") ||
    ((/Mac OS X|Macintosh/.test(agent) || platform === "macOS") && "Mac") ||
    ((/Linux/.test(agent) || platform === "Linux") && "Linux") ||
    "";
  return (system ? `${browser} on ${system}` : `${browser} (DirectorLink app)`).slice(0, 64);
}

export function restoreSaved() {
  state.host = savedHost();
  state.apiKey = savedApiKey();
  state.transport = (IS_IOS || !state.host) && savedRemote() ? "remote" : "lan";
  state.status = reachable() ? "connecting" : "setup";
}

// Validates and stores the controller address. A different controller needs a new key; a device
// that joined with an invitation (no address yet) keeps its key for its home's address.
export function useHost(value) {
  const host = normalizeHost(value);
  if (!host) {
    throw new ApiError(t("connect.invalidHost"), { code: "INVALID_HOST" });
  }
  if (state.host && host !== state.host && state.apiKey) {
    forgetKey();
  }
  if (host !== state.host) {
    state.remoteInfo = null;
  }
  saveHost(host);
  state.host = host;
  return host;
}

export function forgetKey() {
  clearApiKey();
  forgetRemote();
  state.transport = "lan";
  state.remoteInfo = null;
  stopPolling();
  state.apiKey = "";
  state.role = null;
  state.status = "setup";
  state.loaded = false;
}

// Pairing failures (POST /v1/auth/pair) as RFC 9457 problem codes.
function pairingError(error, pairing) {
  switch (error?.code) {
    case "INVALID_FIELD":
    case "INVALID_REQUEST":
      return pairing ? t("connect.errors.invalidCode") : null;
    case "PAIRING_CODE_INVALID": {
      const left = Number(error.problem?.attempts_remaining);
      return Number.isFinite(left) && left > 0 ? t("connect.errors.wrongCode", { count: left }) : t("connect.errors.wrongCodeNoCount");
    }
    case "PAIRING_NOT_ACTIVE":
      return t("connect.errors.notActive");
    case "PAIRING_CODE_EXPIRED":
      return t("connect.errors.expired");
    case "PAIRING_RATE_LIMITED": {
      // Exact only when the driver says how long (problem body, or an exposed Retry-After).
      const seconds = Number(error.problem?.retry_after) || error.retryAfter;
      return seconds ? t("connect.errors.rateLimited", { seconds, count: seconds }) : t("connect.errors.rateLimitedMinute");
    }
    case "KEY_LIMIT_REACHED":
      return t("connect.errors.keyLimit");
    case "PAIRING_UNAVAILABLE":
      return t("connect.errors.unavailable");
    default:
      return null;
  }
}

// Problems of the account connection (remote.js), which never mean the key is invalid.
function remoteErrorText(error) {
  switch (error.code) {
    case "UNREACHABLE":
    case "TIMEOUT":
      return t("errors.remote.unreachable");
    case "NOT_SIGNED_IN":
      return t("errors.remote.signIn");
    case "HOME_OFFLINE":
    case "HOME_TIMEOUT":
    case "HOME_DISCONNECTED":
      return t("errors.remote.homeOffline");
    case "NOT_A_MEMBER":
      return t("errors.remote.notMember");
    case "UNKNOWN_KEY":
      return t("errors.remote.unknownKey");
    case "LOCK_UNAVAILABLE":
      return t("errors.remote.lock");
    case "STALE":
      return t("errors.remote.clock");
    case "INVALID_CLAIM":
      return t("errors.remote.invalidClaim");
    case "KEY_LIMIT_REACHED":
      return t("connect.errors.keyLimit");
    case "INVITATION_LIMIT_REACHED":
      return t("errors.invitationLimit");
    default:
      // The cloud's own text is not shown: it is in English only, and not the app's to trust.
      return t("errors.remote.failed", { code: String(error.code || "UNKNOWN").slice(0, 40) });
  }
}

// `pairing`: the error of POST /v1/auth/pair, where a refused field is the code.
function describeError(error, pairing = false) {
  if (error instanceof RemoteError) {
    return remoteErrorText(error);
  }
  if (error?.status === 401) {
    return t("errors.keyRevoked");
  }
  const pairingText = pairingError(error, pairing);
  if (pairingText) {
    return pairingText;
  }
  // 403 FORBIDDEN: this key's role is too low; DOOR_CONTROL_DISABLED: the Composer switch is off.
  if (error?.code === "DOOR_CONTROL_DISABLED") {
    return t("errors.doorsDisabled");
  }
  if (error?.code === "FORBIDDEN") {
    return t("errors.forbidden", { role: roleLabel(error.problem?.role || state.role) });
  }
  if (error?.code === "INVALID_HOST") {
    return error.message;
  }
  if (error?.code === "INVITATION_LIMIT_REACHED") {
    return t("errors.invitationLimit");
  }
  if (error?.name === "AbortError") {
    return t("errors.timeout");
  }
  if (error instanceof ApiError && error.status) {
    return error.message;
  }
  return t("errors.unreachable");
}

export function errorText(error) {
  return describeError(error);
}

// A connection problem to show. Problems of the account connection say why (signed out, home
// offline, …); an ended session is looked up again, so the app offers to sign in.
function connectionNotice(error) {
  const remote = error instanceof RemoteError;
  if (remote && error.code === "NOT_SIGNED_IN" && state.account.status === "signed-in") {
    loadAccount();
  }
  return { kind: "error", text: describeError(error), remote };
}

function forgetRevokedKey() {
  forgetKey();
  state.notice = { kind: "error", text: t("errors.keyRevoked") };
  notify();
}

// Any request answered 401: the key was revoked or DirectorLink was re-added. Start over. A 401 on
// the home network, for a device linked to its home through the account, is checked with the home
// first: another controller at the same address (another network) must not wipe this home's key.
let checkingKey = null;
export function handleUnauthorized(error) {
  if (error?.sealed || !savedRemote() || !state.apiKey) {
    forgetRevokedKey();
    return Promise.resolve();
  }
  if (!checkingKey) {
    checkingKey = (async () => {
      try {
        await remoteCall(state.apiKey, "/v1/api-keys/current");
        // The key works at home: the controller that refused it is another one.
        useTransport("remote");
        connect();
      } catch (failure) {
        if (failure?.status === 401 || failure?.code === "UNKNOWN_KEY") {
          forgetRevokedKey();
        }
        // Otherwise the home cannot be asked now: the key is kept.
      } finally {
        checkingKey = null;
      }
    })();
  }
  return checkingKey;
}

// Resources newer drivers add (doors and gates, doorbells): an older driver answers 404, so
// show none.
// Other failures give `fallback` (for doorbells: the last list, so a hiccup keeps the banner).
async function optionalList(path, fallback = []) {
  try {
    return (await api(path))?.items || [];
  } catch (error) {
    if (error?.status === 401) throw error;
    return error?.status === 404 || error?.status === 405 ? [] : fallback;
  }
}

export function roleLabel(role) {
  const key = `roles.${role || "admin"}`;
  const label = t(key);
  return label === key ? String(role) : label;
}

// Drivers before API key roles have no /v1/api-keys/current: their keys can do everything.
async function loadRole() {
  try {
    const key = await api("/v1/api-keys/current");
    return typeof key?.role === "string" ? key.role : "admin";
  } catch (error) {
    if (error?.status === 404 || error?.status === 405) return "admin";
    throw error;
  }
}

// A 403 FORBIDDEN names the key's current role (it may have been changed in Composer).
export function noteForbidden(error) {
  const role = error?.code === "FORBIDDEN" ? error.problem?.role : null;
  if (typeof role === "string" && role !== state.role) {
    state.role = role;
    notify();
  }
}

async function loadAll() {
  const [system, rooms, lights, thermostats, blinds, cameras, devices, relays, doorbells, role] = await Promise.all([
    api("/v1/system"),
    api("/v1/rooms"),
    api("/v1/lights"),
    api("/v1/thermostats"),
    api("/v1/blinds"),
    api("/v1/cameras"),
    api("/v1/devices").catch(() => ({ items: [] })),
    optionalList("/v1/relays"),
    optionalList("/v1/doorbells"),
    loadRole(),
  ]);
  state.system = system;
  state.rooms = rooms?.items || [];
  state.lights = lights?.items || [];
  state.thermostats = thermostats?.items || [];
  state.blinds = blinds?.items || [];
  state.cameras = cameras?.items || [];
  state.devices = devices?.items || [];
  state.relays = relays;
  useDoorbells(doorbells);
  state.role = role;
  state.lastUpdated = new Date();
  state.loaded = true;
}

// Every doorbell list goes through here: new rings are noticed (banner, notification).
function useDoorbells(doorbells) {
  state.doorbells = doorbells;
  notifyRings(trackRings(doorbells));
}

// Doorbells only: what a page in the background still polls when doorbell notifications are on.
export async function refreshDoorbells() {
  if (!reachable()) return false;
  try {
    useDoorbells(await optionalList("/v1/doorbells", state.doorbells));
    notify();
    return true;
  } catch (error) {
    if (error?.status === 401) handleUnauthorized(error);
    return false;
  }
}

// Connects with the saved key. Used on start (automatic reconnect) and by Retry.
export async function connect() {
  if (!reachable()) {
    state.status = "setup";
    notify();
    return false;
  }
  const run = ++connectRun;
  state.status = "connecting";
  notify();
  try {
    await loadAll();
    if (run !== connectRun) return false;
    state.status = "connected";
    state.notice = null;
    startPolling();
    runConnectedHooks();
    return true;
  } catch (error) {
    if (run !== connectRun) return false;
    if (error?.status === 401) {
      handleUnauthorized(error);
      return false;
    }
    console.error("DirectorLink connection failed", error);
    state.notice = connectionNotice(error);
    // The next attempt tries the home network first again.
    if (state.transport === "remote" && !IS_IOS && state.host) {
      state.transport = "lan";
    }
    state.status = "unreachable";
    scheduleRetry();
    return false;
  } finally {
    notify();
  }
}

// The only way to get a first key: the pairing code created in Composer (DirectorLink →
// Actions → New Pairing Code). It lasts 15 minutes, works once and gives an admin key.
export async function pairWithCode(hostValue, pairingCode) {
  const code = normalizePairingCode(pairingCode);
  if (!code) {
    state.notice = { kind: "error", text: t("connect.errors.invalidCode") };
    notify();
    return false;
  }
  try {
    const host = useHost(hostValue);
    state.status = "connecting";
    state.notice = null;
    notify();
    const created = await apiCall(host, "/v1/auth/pair", {
      method: "POST",
      body: { pairing_code: code, name: clientName() },
    });
    if (!created?.key) {
      throw new ApiError(t("errors.noKey"), { code: "PAIRING_NO_KEY" });
    }
    saveApiKey(created.key);
    state.apiKey = created.key;
    // Remote access belonged to the previous key: link the home again for this one.
    forgetRemote();
    state.transport = "lan";
    state.remoteInfo = null;
    return connect();
  } catch (error) {
    state.status = "setup";
    state.notice = { kind: "error", text: describeError(error, true) };
    notify();
    return false;
  }
}

// Device state, every 10 s while the page is visible. Devices with a command in flight keep
// their optimistic state until the command is confirmed.
export async function refreshDevices() {
  if (!reachable()) return false;
  try {
    const kinds = ["light", "thermostat", "blind"];
    const [doorbells, ...results] = await Promise.all([
      optionalList("/v1/doorbells", state.doorbells),
      ...kinds.map((kind) => api(KINDS[kind].path)),
    ]);
    useDoorbells(doorbells);
    kinds.forEach((kind, index) => {
      const listName = KINDS[kind].list;
      const fresh = results[index]?.items || [];
      state[listName] = fresh.map((device) => {
        const pending = state.pending[`${kind}:${device.id}`];
        return pending ? state[listName].find((item) => item.id === device.id) || device : device;
      });
    });
    state.lastUpdated = new Date();
    failedRefreshes = 0;
    if (state.status !== "connected") {
      state.status = "connected";
      state.notice = null;
    }
  } catch (error) {
    if (error?.status === 401) {
      handleUnauthorized(error);
      return false;
    }
    failedRefreshes += 1;
    state.lastError = { at: new Date(), text: describeError(error) };
    console.warn(`DirectorLink refresh failed (${failedRefreshes} in a row)`, error);
    if (failedRefreshes < FAILURES_BEFORE_UNREACHABLE) {
      return false;
    }
    state.status = "unreachable";
    state.notice = connectionNotice(error);
  }
  notify();
  return failedRefreshes === 0;
}

// Rooms and cameras change rarely (renames, new devices); refreshed now and then.
export async function refreshRooms() {
  try {
    const [rooms, cameras, relays, role] = await Promise.all([
      api("/v1/rooms"),
      api("/v1/cameras"),
      optionalList("/v1/relays"),
      loadRole().catch(() => state.role),
    ]);
    state.rooms = rooms?.items || state.rooms;
    state.cameras = cameras?.items || state.cameras;
    state.relays = relays;
    state.role = role;
    notify();
    runConnectedHooks();
  } catch {
    // The next device refresh reports connection problems.
  }
}

let pollCount = 0;

function schedulePoll(delay = POLL_MS) {
  window.clearTimeout(pollTimer);
  pollTimer = window.setTimeout(poll, delay);
}

async function poll() {
  pollTimer = null;
  if (!state.apiKey) return;
  // In the background only doorbells are polled, and only for their notifications.
  if (document.hidden && state.loaded && notificationsOn()) {
    await refreshDoorbells();
  }
  if (!document.hidden) {
    if (!state.loaded) {
      await connect();
      return;
    }
    const ok = await refreshDevices();
    pollCount += 1;
    if (pollCount % 6 === 0) await tryHomeNetwork();
    if (ok && pollCount % 6 === 1) checkInThroughAccount();
    if (ok && pollCount % 6 === 0 && state.status === "connected") {
      await refreshRooms();
    }
    // After a failure, try again soon instead of waiting a whole interval.
    if (!ok && state.apiKey) {
      schedulePoll(RETRY_MS);
      return;
    }
  }
  if (state.apiKey) schedulePoll();
}

export function startPolling() {
  schedulePoll();
}

export function stopPolling() {
  window.clearTimeout(pollTimer);
  pollTimer = null;
}

function scheduleRetry() {
  if (state.apiKey) schedulePoll(POLL_MS);
}

// Back on the page: refresh at once instead of waiting for the next tick.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && state.apiKey && (state.status === "connected" || state.status === "unreachable")) {
    if (state.loaded) {
      refreshDevices().then(() => state.apiKey && schedulePoll());
    } else {
      connect();
    }
  }
});

// Settings → Controller → Forget key: revokes this browser's key on the controller when it can
// be reached (so the key stops working everywhere), then removes it from this browser.
export async function revokeAndForget() {
  if (reachable()) {
    try {
      // Any key may revoke itself (drivers with API key roles). Without an answer on the home
      // network it is revoked through the account (revoking twice changes nothing).
      await api("/v1/api-keys/current", { method: "DELETE", timeoutMs: 4000 }).catch((error) => {
        if (error?.status || error instanceof RemoteError || !savedRemote()) throw error;
        return remoteCall(state.apiKey, "/v1/api-keys/current", { method: "DELETE" });
      });
    } catch (error) {
      if (error?.status === 404 || error?.status === 405) {
        // Older driver: find this key in the list and revoke it (every key was admin there).
        try {
          const keys = await api("/v1/api-keys", { timeoutMs: 4000 });
          const mine = keys?.items?.find((item) => item.current);
          if (mine) {
            await api(`/v1/api-keys/${mine.id}`, { method: "DELETE", timeoutMs: 4000 });
          }
        } catch {
          // Unreachable or not allowed: forgetting it here is still what was asked.
        }
      }
      // Otherwise unreachable or already revoked: forget it here anyway.
    }
  }
  forgetKey();
  notify();
}

// Room names per language (PATCH /v1/rooms/{id}). Older drivers answer 404/405.
export async function saveRoomNames(roomId, names) {
  const room = await api(`/v1/rooms/${roomId}`, { method: "PATCH", body: { names } });
  state.rooms = state.rooms.map((item) =>
    item.id === Number(roomId) ? { ...item, ...(room && typeof room === "object" ? room : {}), names: room?.names || Object.fromEntries(Object.entries(names).filter(([, value]) => value)) } : item
  );
  notify();
  return room;
}
