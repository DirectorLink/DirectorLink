// Connection to the controller: address, API key, role, and every request the console makes.

import {
  API_PORT,
  ApiError,
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

export const CLIENT_NAME = "DirectorLink Console";
export const ROLES = ["viewer", "member", "doors", "admin"];

export const state = {
  host: savedHost(),
  apiKey: savedApiKey(),
  // setup | connecting | connected | unreachable
  status: "setup",
  role: null,
  key: null, // GET /v1/api-keys/current (no secret)
  system: null,
  spec: null,
  notice: null, // { kind, text } shown on the connection screen
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
    text:
      message ||
      "The controller no longer accepts this API key (it was revoked, or DirectorLink was reinstalled). Pair again with a new code from Composer, or paste another key.",
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
    throw new ApiError(problemText(result), { status: result.status, code: problem?.code, problem, retryAfter: result.retryAfter });
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

// What each problem from POST /v1/auth/pair means for the person pairing.
export function pairingProblemText(error) {
  const problem = error?.problem || {};
  switch (error?.code) {
    case "INVALID_FIELD":
    case "INVALID_REQUEST":
      return "Enter the 8-digit pairing code, for example 1234 5678.";
    case "PAIRING_CODE_INVALID": {
      const left = Number(problem.attempts_remaining);
      return Number.isFinite(left) && left > 0
        ? `That code isn't right. ${left} more ${left === 1 ? "try" : "tries"} before pairing locks for a minute.`
        : "That code isn't right. Check it in Composer and try again.";
    }
    case "PAIRING_NOT_ACTIVE":
      return "No pairing code is active. In Composer, run New Pairing Code on DirectorLink — or ask your installer. Codes last 15 minutes and work once.";
    case "PAIRING_CODE_EXPIRED":
      return "That code has expired. In Composer, run New Pairing Code on DirectorLink and try the new one.";
    case "PAIRING_RATE_LIMITED": {
      // Exact only when the driver says how long (problem body, or an exposed Retry-After).
      const seconds = Number(problem.retry_after) || error.retryAfter;
      return seconds
        ? `Too many wrong codes. Wait ${seconds} ${seconds === 1 ? "second" : "seconds"} and try again.`
        : "Too many wrong codes. Pairing is locked for a minute — wait, then try again.";
    }
    case "KEY_LIMIT_REACHED":
      return "DirectorLink already has as many API keys as it can hold. Revoke one you no longer use (Keys tab, with another admin key), then pair again.";
    case "PAIRING_UNAVAILABLE":
      return "Pairing isn't available right now — DirectorLink may still be starting. Try again in a minute.";
    default:
      return error?.message || "Pairing failed.";
  }
}

// The pairing code created in Composer (DirectorLink → Actions → New Pairing Code): 15 minutes,
// works once, always gives an admin key.
export async function pairWithCode(hostValue, code) {
  state.notice = null;
  // The address first (the field above), so it is kept even when the code is mistyped.
  try {
    useHost(hostValue);
  } catch (error) {
    state.notice = { kind: "error", text: error.message };
    notify();
    return false;
  }
  const pairingCode = normalizePairingCode(code);
  if (!pairingCode) {
    state.notice = { kind: "error", text: "Enter the 8-digit pairing code, for example 1234 5678." };
    notify();
    return false;
  }
  const previousStatus = state.apiKey ? state.status : "setup";
  try {
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
    state.status = state.apiKey ? previousStatus : "setup";
    state.notice = { kind: "error", text: error?.status || error?.code ? pairingProblemText(error) : error.message };
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
