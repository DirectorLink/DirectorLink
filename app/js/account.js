// The DirectorLink account (docs/ACCOUNTS.md): signing in with Google through api.directorlink.io.
// The session is a cookie of api.directorlink.io that this page cannot read; the app only asks
// who is signed in. A device that never signed in never contacts the account server: using the
// app on the home network stays between this device and the controller.

import { notify, state } from "./state.js";

export const ACCOUNTS_API = /^(localhost|127\.0\.0\.1)$/.test(window.location.hostname) ? "http://localhost:8787" : "https://api.directorlink.io";

// Set after a sign-in on this device, so the app knows to ask for the account on the next start.
const SIGNED_IN_KEY = "directorlink.account";
const TIMEOUT_MS = 8000;

function remember(on) {
  try {
    if (on) localStorage.setItem(SIGNED_IN_KEY, "1");
    else localStorage.removeItem(SIGNED_IN_KEY);
  } catch {
    // Blocked storage: the account is asked for when Settings opens.
  }
}

function remembered() {
  try {
    return localStorage.getItem(SIGNED_IN_KEY) === "1";
  } catch {
    return false;
  }
}

async function call(path, method = "GET") {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    return await fetch(`${ACCOUNTS_API}${path}`, { method, credentials: "include", cache: "no-store", signal: controller.signal });
  } finally {
    window.clearTimeout(timer);
  }
}

function set(account) {
  state.account = { user: null, notice: null, busy: false, ...account };
  notify();
}

// Who is signed in: "signed-in" (with user), "signed-out", or "unavailable" (server unreachable).
export async function loadAccount() {
  set({ ...state.account, status: state.account.status === "unknown" ? "loading" : state.account.status });
  try {
    const response = await call("/v1/me");
    if (response.status === 200) {
      remember(true);
      set({ status: "signed-in", user: await response.json(), notice: state.account.notice });
    } else if (response.status === 401) {
      remember(false);
      set({ status: "signed-out", notice: state.account.notice });
    } else {
      set({ status: "unavailable" });
    }
  } catch {
    set({ status: "unavailable" });
  }
}

// On start: the outcome of a sign-in that just came back (?signin=…), then the account if this
// device has one.
export function startAccount() {
  const url = new URL(window.location.href);
  const outcome = url.searchParams.get("signin");
  if (outcome) {
    url.searchParams.delete("signin");
    window.history.replaceState(window.history.state, "", url.pathname + url.search + url.hash);
    state.account = { ...state.account, notice: outcome === "ok" ? null : outcome };
  }
  if (outcome === "ok" || remembered()) {
    loadAccount();
  } else {
    set({ status: "signed-out", notice: state.account.notice });
  }
}

// The sign-in providers the app offers; each must be set up on api.directorlink.io
// (cloud/README.md). Apple is added once its keys are there.
export const SIGN_IN_PROVIDERS = ["google"];

// `hash`: the screen to come back to (Settings, or Home when signing in from the connect screen).
// `link`: add this provider to the signed-in account instead (Settings → Account).
export function signIn(hash = "#/settings", provider = "google", { link = false } = {}) {
  const back = `${window.location.origin}/${hash}`;
  window.location.assign(`${ACCOUNTS_API}/auth/${provider}/start?return_to=${encodeURIComponent(back)}${link ? "&link=1" : ""}`);
}

export async function signOut() {
  set({ ...state.account, busy: true });
  try {
    await call("/auth/logout", "POST");
  } catch {
    // The session ends on the server when it can be reached; here it is forgotten either way.
  }
  remember(false);
  set({ status: "signed-out" });
}

export async function deleteAccount() {
  set({ ...state.account, busy: true });
  try {
    const response = await call("/v1/me", "DELETE");
    if (response.status === 204 || response.status === 401) {
      remember(false);
      set({ status: "signed-out", notice: "deleted" });
      return true;
    }
  } catch {
    // Reported below.
  }
  set({ ...state.account, busy: false, notice: "deleteFailed" });
  return false;
}
