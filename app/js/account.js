// The DirectorLink account (docs/ACCOUNTS.md): signing in with Google or Apple through
// api.directorlink.io. The session is a cookie of api.directorlink.io that this page cannot read;
// the app only asks who is signed in. A device that never signed in contacts the account server
// only once someone chooses to sign in: using the app on the home network stays between this
// device and the controller.

import { notify, state } from "./state.js";

export const ACCOUNTS_API = /^(localhost|127\.0\.0\.1)$/.test(window.location.hostname) ? "http://localhost:8787" : "https://api.directorlink.io";

// Set after a sign-in on this device, so the app knows to ask for the account on the next start.
const SIGNED_IN_KEY = "directorlink.account";
// The sign-ins the account server has set up, as it last said (a JSON list).
const PROVIDERS_KEY = "directorlink.providers";
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
      const user = await response.json();
      // Servers before 1.3.0 do not say; they had only Google.
      learnProviders(Array.isArray(user?.sign_in_providers) ? user.sign_in_providers : ["google"]);
      set({ status: "signed-in", user, notice: state.account.notice });
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

// The sign-in providers the app can offer. Each shows only while api.directorlink.io says it is set
// up (cloud/README.md), so a sign-in whose key is missing there never shows a button that fails.
export const SIGN_IN_PROVIDERS = ["google", "apple"];

let providers = storedProviders(); // what the account server said, or null: not asked yet
let providersState = "idle"; // idle · loading · failed
let providersRefreshed = false;

function storedProviders() {
  try {
    const value = JSON.parse(localStorage.getItem(PROVIDERS_KEY) || "null");
    return Array.isArray(value) ? value.filter((provider) => SIGN_IN_PROVIDERS.includes(provider)) : null;
  } catch {
    return null;
  }
}

function learnProviders(list) {
  providers = SIGN_IN_PROVIDERS.filter((provider) => list.includes(provider));
  providersRefreshed = true;
  try {
    localStorage.setItem(PROVIDERS_KEY, JSON.stringify(providers));
  } catch {
    // Blocked storage: asked again next time.
  }
}

// The sign-in buttons to show, in order; null until the account server has said which it has set
// up.
export function signInProviders() {
  return providers;
}

// "loading" while the account server is asked, "failed" when it could not be reached, else "idle".
export function providersStatus() {
  return providersState;
}

// Asks the account server which sign-ins it has set up (no cookie is sent). Called when someone
// chooses to sign in; a device that has asked before gets fresh answers once per start.
export async function loadProviders() {
  if (providersState === "loading") return;
  providersState = "loading";
  providersRefreshed = true;
  notify();
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(`${ACCOUNTS_API}/auth/providers`, { credentials: "omit", cache: "no-store", signal: controller.signal });
    const data = response.ok ? await response.json() : null;
    if (!Array.isArray(data?.providers)) throw new Error(`HTTP ${response.status}`);
    learnProviders(data.providers);
    providersState = "idle";
  } catch {
    providersState = "failed";
  } finally {
    window.clearTimeout(timer);
  }
  notify();
}

// While sign-in buttons are shown from what the server said before, it is asked again once.
export function refreshProviders() {
  if (providers && !providersRefreshed) loadProviders();
}

// `hash`: the screen to come back to (Settings → Account, or Home when signing in from the connect
// screen). `link`: add this provider to the signed-in account instead (Settings → Account).
export function signIn(hash = "#/settings/account", provider = "google", { link = false } = {}) {
  const back = `${window.location.origin}/${hash}`;
  window.location.assign(`${ACCOUNTS_API}/auth/${provider}/start?return_to=${encodeURIComponent(back)}${link ? "&link=1" : ""}`);
}

// `everywhere`: every device signed in to this account is signed out (a lost phone).
export async function signOut({ everywhere = false } = {}) {
  set({ ...state.account, busy: true });
  if (everywhere) {
    // It must be known to have worked: someone signing out a lost phone relies on it.
    let response = null;
    try {
      response = await call("/auth/logout?everywhere=1", "POST");
    } catch {
      response = null;
    }
    if (response?.status === 204) {
      remember(false);
      set({ status: "signed-out", notice: "signedOutEverywhere" });
    } else if (response?.status === 401) {
      remember(false);
      set({ status: "signed-out", notice: "signOutEverywhereExpired" });
    } else {
      set({ ...state.account, busy: false, notice: "signOutEverywhereFailed" });
    }
    return;
  }
  try {
    await call("/auth/logout", "POST");
  } catch {
    // The session ends on the server when it can be reached; here it is forgotten either way.
  }
  remember(false);
  set({ status: "signed-out" });
}

// Stops signing in with `provider` (the account keeps at least one).
export async function removeProvider(provider) {
  set({ ...state.account, busy: true });
  try {
    const response = await call(`/v1/me/identities/${provider}`, "DELETE");
    if (response.status === 204) {
      await loadAccount();
      set({ ...state.account, busy: false, notice: "removed" });
      return true;
    }
  } catch {
    // Reported below.
  }
  set({ ...state.account, busy: false, notice: "removeFailed" });
  return false;
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
