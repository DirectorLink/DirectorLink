// Connection to the controller: first-time access, reconnecting with the saved key, loading
// and refreshing device state.

import {
  ApiError,
  apiCall,
  clearApiKey,
  normalizeHost,
  saveApiKey,
  saveHost,
  savedApiKey,
  savedHost,
} from "../api-client.js";
import { t } from "./i18n.js";
import { KINDS, notify, state } from "./state.js";

const POLL_MS = 10000;
// A refresh that fails is retried soon; only this many failures in a row mean "unreachable".
// One slow answer (a phone waking up, Wi-Fi busy with camera pictures) is not a disconnect.
const RETRY_MS = 2000;
const FAILURES_BEFORE_UNREACHABLE = 2;
let pollTimer = null;
let failedRefreshes = 0;
let connectRun = 0;

export function api(path, options = {}) {
  return apiCall(state.host, path, { apiKey: state.apiKey, ...options });
}

function clientName() {
  const platform = navigator.userAgentData?.platform || navigator.platform || "browser";
  return `C4Bridge web app (${platform})`.slice(0, 64);
}

export function restoreSaved() {
  state.host = savedHost();
  state.apiKey = savedApiKey();
  state.status = state.host && state.apiKey ? "connecting" : "setup";
}

// Validates and stores the controller address. A different controller needs a new key.
export function useHost(value) {
  const host = normalizeHost(value);
  if (!host) {
    throw new ApiError(t("connect.invalidHost"), { code: "INVALID_HOST" });
  }
  if (host !== state.host && state.apiKey) {
    forgetKey();
  }
  saveHost(host);
  state.host = host;
  return host;
}

export function forgetKey() {
  clearApiKey();
  stopPolling();
  state.apiKey = "";
  state.role = null;
  state.status = "setup";
  state.loaded = false;
}

function describeError(error) {
  if (error?.status === 401) {
    return t("errors.keyRevoked");
  }
  if (error?.code === "REQUEST_PENDING") {
    return t("errors.requestPending");
  }
  if (error?.code === "PAIRING_RATE_LIMITED") {
    return t("errors.pairingRateLimited");
  }
  // 403 FORBIDDEN: this key's role is too low; DOOR_CONTROL_DISABLED: the Composer switch is off.
  if (error?.code === "DOOR_CONTROL_DISABLED") {
    return t("errors.doorsDisabled");
  }
  if (error?.code === "FORBIDDEN") {
    return t("errors.forbidden", { role: roleLabel(error.problem?.role || state.role) });
  }
  if (error?.code === "INVALID_PAIRING_CODE" || error?.code === "PAIRING_FAILED" || error?.status === 403) {
    return error.message || t("errors.pairingRejected");
  }
  if (error instanceof ApiError && error.code && /^(PAIRING|REQUEST|INVALID)/.test(error.code)) {
    return error.message;
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

// Any request answered 401: the key was revoked or C4Bridge was re-added. Start over.
export function handleUnauthorized() {
  forgetKey();
  state.notice = { kind: "error", text: t("errors.keyRevoked") };
  notify();
}

// Resources newer drivers add (doors and gates): an older driver answers 404, so show none.
async function optionalList(path) {
  try {
    return (await api(path))?.items || [];
  } catch (error) {
    if (error?.status === 401) throw error;
    return [];
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
  const [system, rooms, lights, thermostats, blinds, cameras, devices, relays, role] = await Promise.all([
    api("/v1/system"),
    api("/v1/rooms"),
    api("/v1/lights"),
    api("/v1/thermostats"),
    api("/v1/blinds"),
    api("/v1/cameras"),
    api("/v1/devices").catch(() => ({ items: [] })),
    optionalList("/v1/relays"),
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
  state.role = role;
  state.lastUpdated = new Date();
  state.loaded = true;
}

// Connects with the saved key. Used on start (automatic reconnect) and by Retry.
export async function connect() {
  if (!state.host || !state.apiKey) {
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
    return true;
  } catch (error) {
    if (run !== connectRun) return false;
    if (error?.status === 401) {
      handleUnauthorized();
      return false;
    }
    console.error("C4Bridge connection failed", error);
    state.status = "unreachable";
    state.notice = { kind: "error", text: describeError(error) };
    scheduleRetry();
    return false;
  } finally {
    notify();
  }
}

// Asks for a key and waits until C4Bridge Access is pressed in the Control4 app (2 minutes).
export async function requestAccess(hostValue) {
  state.notice = null;
  try {
    const host = useHost(hostValue);
    state.status = "waiting";
    notify();
    const request = await apiCall(host, "/v1/auth/requests", {
      method: "POST",
      body: { name: clientName() },
    });
    state.access = { id: request.id, host, expiresAt: request.expires_at, cancelled: false };
    notify();
    while (state.access && !state.access.cancelled) {
      await sleep(2000);
      if (!state.access || state.access.cancelled) break;
      let current;
      try {
        current = await apiCall(host, `/v1/auth/requests/${request.id}`);
      } catch (error) {
        if (error.status === 404) {
          throw new ApiError(t("errors.requestExpired"), { code: "REQUEST_EXPIRED" });
        }
        throw error;
      }
      if (current.status === "approved" && current.api_key?.key) {
        saveApiKey(current.api_key.key);
        state.apiKey = current.api_key.key;
        state.access = null;
        return connect();
      }
      state.access = { ...state.access, expiresAt: current.expires_at };
    }
    state.notice = { kind: "info", text: t("connect.cancelled") };
    return false;
  } catch (error) {
    state.notice = { kind: "error", text: describeError(error) };
    return false;
  } finally {
    state.access = null;
    if (state.status === "waiting") {
      state.status = "setup";
    }
    notify();
  }
}

export async function cancelAccess() {
  const access = state.access;
  if (!access) {
    return;
  }
  access.cancelled = true;
  state.access = null;
  notify();
  try {
    await apiCall(access.host, `/v1/auth/requests/${access.id}`, { method: "DELETE" });
  } catch {
    // Already expired or approved; nothing to undo.
  }
}

// Fallback: the 8-digit pairing code shown in Composer.
export async function pairWithCode(hostValue, pairingCode) {
  const code = String(pairingCode || "").trim();
  if (!/^\d{8}$/.test(code)) {
    state.notice = { kind: "error", text: t("connect.codeInvalid") };
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
    return connect();
  } catch (error) {
    state.status = "setup";
    state.notice = { kind: "error", text: describeError(error) };
    notify();
    return false;
  }
}

const sleep = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));

// Device state, every 10 s while the page is visible. Devices with a command in flight keep
// their optimistic state until the command is confirmed.
export async function refreshDevices() {
  if (!state.apiKey || !state.host) return false;
  try {
    const kinds = ["light", "thermostat", "blind"];
    const results = await Promise.all(kinds.map((kind) => api(KINDS[kind].path)));
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
      handleUnauthorized();
      return false;
    }
    failedRefreshes += 1;
    state.lastError = { at: new Date(), text: describeError(error) };
    console.warn(`C4Bridge refresh failed (${failedRefreshes} in a row)`, error);
    if (failedRefreshes < FAILURES_BEFORE_UNREACHABLE) {
      return false;
    }
    state.status = "unreachable";
    state.notice = { kind: "error", text: describeError(error) };
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
  if (!document.hidden) {
    if (!state.loaded) {
      await connect();
      return;
    }
    const ok = await refreshDevices();
    pollCount += 1;
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
  if (state.host && state.apiKey) {
    try {
      // Any key may revoke itself (drivers with API key roles).
      await api("/v1/api-keys/current", { method: "DELETE", timeoutMs: 4000 });
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
