// Connection to the controller: address, API key, role, and every request the console makes.

import {
  API_PORT,
  ApiError,
  apiImage,
  apiRequest,
  clearApiKey,
  normalizeHost,
  saveApiKey,
  saveHost,
  savedApiKey,
  savedHost,
} from "../api-client.js";

export const CLIENT_NAME = "DirectorLink Console";
export const ROLES = ["viewer", "member", "doors", "admin"];

export const state = {
  host: savedHost(),
  apiKey: savedApiKey(),
  // setup | waiting | connecting | connected | unreachable
  status: "setup",
  role: null,
  key: null, // GET /v1/api-keys/current (no secret)
  system: null,
  spec: null,
  notice: null, // { kind, text } shown on the connection screen
  access: null, // a waiting access request: { id, host, expiresAt }
};

const listeners = new Set();

export function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function notify() {
  for (const listener of listeners) listener(state);
}

function roleRank(role) {
  const index = ROLES.indexOf(role);
  return index < 0 ? -1 : index;
}

// True when the current key's role is at least `role`.
export function can(role) {
  if (!role) return true;
  return roleRank(state.role) >= roleRank(role);
}

export function baseUrl(host = state.host) {
  return `http://${host}:${API_PORT}`;
}

// Messages for failures that never reached the API (no HTTP status).
export function networkMessage(error, host = state.host) {
  const where = `http://${host || "<controller>"}:${API_PORT}`;
  if (error?.name === "AbortError") {
    return `The controller did not answer in time (${where}). Check that this computer is on the home network and that port ${API_PORT} is reachable.`;
  }
  return `Could not reach DirectorLink at ${where}. Check the address, that this computer is on the home network and that port ${API_PORT} is reachable, and allow Local Network Access when the browser asks.`;
}

export function problemText(result) {
  const problem = result?.data && typeof result.data === "object" ? result.data : null;
  if (problem?.code === "LAST_ADMIN") {
    return "This is the only admin key, so it must stay admin. Make another key admin first.";
  }
  // 403 FORBIDDEN's detail names this key's role and the one needed.
  return problem?.detail || problem?.title || `DirectorLink answered HTTP ${result?.status}.`;
}

// A key that stops working (revoked, or DirectorLink was re-added): forget it and start over.
export function handleUnauthorized(message) {
  forgetLocally();
  state.notice = {
    kind: "error",
    text: message || "The controller no longer accepts this API key (it was revoked, or DirectorLink was reinstalled). Connect again.",
  };
  notify();
  if (!window.location.hash.startsWith("#/connect")) {
    window.location.hash = "#/connect";
  }
}

export function forgetLocally() {
  clearApiKey();
  state.apiKey = "";
  state.role = null;
  state.key = null;
  state.system = null;
  state.status = "setup";
}

// Sends a request with the saved key. Returns apiRequest's result for any HTTP status and throws
// ApiError (with a readable message) only when the controller could not be reached.
// A 401 on a request that carried the key logs the console out.
export async function send(path, { method = "GET", body, auth = true, timeoutMs } = {}) {
  const apiKey = auth ? state.apiKey : undefined;
  let result;
  try {
    result = await apiRequest(state.host, path, { method, body, apiKey, timeoutMs });
  } catch (error) {
    markUnreachable();
    throw new ApiError(networkMessage(error), { code: error?.name === "AbortError" ? "TIMEOUT" : "UNREACHABLE" });
  }
  if (state.status === "unreachable") {
    state.status = "connected";
    notify();
  }
  if (result.status === 401 && apiKey) {
    handleUnauthorized();
  }
  return result;
}

// Like send(), but throws ApiError for any non-2xx answer; returns the data.
export async function call(path, options) {
  const result = await send(path, options);
  if (!result.ok) {
    const problem = result.data && typeof result.data === "object" ? result.data : null;
    throw new ApiError(problemText(result), { status: result.status, code: problem?.code, problem });
  }
  return result.data;
}

export async function image(path, { auth = true } = {}) {
  try {
    return await apiImage(state.host, path, { apiKey: auth ? state.apiKey : undefined });
  } catch (error) {
    if (error instanceof ApiError) {
      if (error.status === 401 && auth) handleUnauthorized();
      throw error;
    }
    markUnreachable();
    throw new ApiError(networkMessage(error), { code: "UNREACHABLE" });
  }
}

function markUnreachable() {
  if (state.status === "connected") {
    state.status = "unreachable";
    notify();
  }
}

export function useHost(value) {
  const host = normalizeHost(value);
  if (!host) {
    throw new ApiError("Enter the controller's IP address or local hostname, without a port (for example 192.168.1.50).", {
      code: "INVALID_HOST",
    });
  }
  if (host !== state.host && state.apiKey) {
    // A key belongs to one controller.
    forgetLocally();
  }
  state.host = host;
  saveHost(host);
  return host;
}

export function useKey(key) {
  const value = String(key || "").trim();
  if (!value) {
    throw new ApiError("Paste an API key first.", { code: "INVALID_KEY" });
  }
  state.apiKey = value;
  saveApiKey(value);
}

// Loads the key's role, the system information and the API description.
export async function connect() {
  if (!state.host || !state.apiKey) {
    state.status = "setup";
    notify();
    return false;
  }
  state.status = "connecting";
  notify();
  try {
    const current = await send("/v1/api-keys/current");
    if (current.status === 401) return false;
    if (current.ok) {
      state.key = current.data;
      state.role = current.data?.role || "admin";
    } else if (current.status === 404 || current.status === 405) {
      // Drivers before API key roles: every key could do everything.
      state.key = null;
      state.role = "admin";
    } else {
      throw new ApiError(problemText(current), { status: current.status });
    }
    state.system = await call("/v1/system");
    state.spec = await loadSpec();
    state.status = "connected";
    state.notice = null;
    notify();
    return true;
  } catch (error) {
    if (!state.apiKey) return false;
    state.status = error?.status ? "connected" : "unreachable";
    state.notice = { kind: "error", text: error.message };
    notify();
    return false;
  }
}

export async function loadSpec() {
  const result = await send("/v1/openapi.json", { auth: false, timeoutMs: 15000 });
  if (!result.ok || !result.data || typeof result.data !== "object") {
    return null;
  }
  return result.data;
}

const sleep = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));

// Request admin access: approved with the DirectorLink Access button in the Control4 app.
// Each request has a run number, so a cancelled one that is still waiting for its next poll
// never touches a newer request.
let accessRun = 0;
let statusBeforeAccess = "setup";

function endAccess(run, notice) {
  if (run !== accessRun) return;
  accessRun += 1;
  state.access = null;
  if (state.status === "waiting") {
    state.status = state.apiKey ? statusBeforeAccess : "setup";
  }
  if (notice) state.notice = notice;
  notify();
}

export async function requestAdminAccess(hostValue) {
  state.notice = null;
  const run = ++accessRun;
  const current = () => run === accessRun;
  try {
    const host = useHost(hostValue);
    statusBeforeAccess = state.apiKey ? state.status : "setup";
    state.status = "waiting";
    state.access = { id: null, host, expiresAt: null };
    notify();
    const request = await call("/v1/auth/requests", {
      method: "POST",
      auth: false,
      body: { name: CLIENT_NAME, role: "admin" },
    });
    if (!current()) {
      // Cancelled while the request was being sent.
      await apiRequest(host, `/v1/auth/requests/${request.id}`, { method: "DELETE" }).catch(() => {});
      return false;
    }
    state.access = { ...state.access, id: request.id, expiresAt: request.expires_at };
    notify();
    for (;;) {
      await sleep(2000);
      if (!current()) return false;
      const result = await send(`/v1/auth/requests/${request.id}`, { auth: false });
      if (!current()) return false;
      if (result.status === 404) {
        throw new ApiError("The request ran out (or was cancelled) before DirectorLink Access was pressed. Request admin access again.", {
          code: "REQUEST_EXPIRED",
        });
      }
      if (!result.ok) {
        throw new ApiError(problemText(result), { status: result.status });
      }
      if (result.data?.status === "approved" && result.data.api_key?.key) {
        useKey(result.data.api_key.key);
        endAccess(run);
        state.status = "connecting";
        return connect();
      }
      // Expiry is the bridge's call (its clock may differ from this computer's): it answers 404.
      state.access = { ...state.access, expiresAt: result.data?.expires_at };
      notify();
    }
  } catch (error) {
    const text =
      error?.code === "REQUEST_PENDING"
        ? "Another device is already waiting for approval. Wait for it to finish (up to 2 minutes) and try again."
        : error.message;
    endAccess(run, { kind: "error", text });
    return false;
  }
}

export async function cancelAccess() {
  const access = state.access;
  if (!access) return;
  endAccess(accessRun, { kind: "info", text: "Access request cancelled." });
  if (access.id) {
    try {
      await apiRequest(access.host, `/v1/auth/requests/${access.id}`, { method: "DELETE" });
    } catch {
      // Already expired or approved: nothing to undo.
    }
  }
}

// The 8-digit pairing code from the DirectorLink properties in Composer (always an admin key).
export async function pairWithCode(hostValue, code) {
  const pairingCode = String(code || "").trim();
  state.notice = null;
  if (!/^\d{8}$/.test(pairingCode)) {
    state.notice = { kind: "error", text: "Enter the 8-digit pairing code shown in Composer." };
    notify();
    return false;
  }
  try {
    useHost(hostValue);
    state.status = "connecting";
    notify();
    const created = await call("/v1/auth/pair", {
      method: "POST",
      auth: false,
      body: { pairing_code: pairingCode, name: CLIENT_NAME },
    });
    if (!created?.key) {
      throw new ApiError("DirectorLink paired, but no API key came back.");
    }
    useKey(created.key);
    return connect();
  } catch (error) {
    state.status = state.apiKey ? "connected" : "setup";
    state.notice = {
      kind: "error",
      text: error?.code === "PAIRING_RATE_LIMITED" ? "Too many wrong codes. Wait a minute and try again." : error.message,
    };
    notify();
    return false;
  }
}

export async function connectWithKey(hostValue, key) {
  state.notice = null;
  try {
    useHost(hostValue);
    useKey(key);
  } catch (error) {
    state.notice = { kind: "error", text: error.message };
    notify();
    return false;
  }
  const ok = await connect();
  if (!ok && !state.apiKey) {
    state.notice = {
      kind: "error",
      text: "The controller rejected this API key. Check that it was copied completely and has not been revoked.",
    };
    notify();
  }
  return ok;
}

// Revokes the key on the controller (when it can be reached), then forgets it here.
export async function forgetKey() {
  let text = "The API key was revoked and removed from this browser.";
  if (state.host && state.apiKey) {
    try {
      const result = await apiRequest(state.host, "/v1/api-keys/current", {
        method: "DELETE",
        apiKey: state.apiKey,
        timeoutMs: 4000,
      });
      if (!result.ok && result.status !== 401) {
        text = `Removed from this browser. The controller answered HTTP ${result.status}; revoke the key in Composer or from another admin key if it still exists.`;
      }
    } catch {
      text = "Removed from this browser, but the controller could not be reached to revoke the key. Revoke it later from the Keys tab of another admin key.";
    }
  }
  forgetLocally();
  state.notice = { kind: "info", text };
  notify();
}
