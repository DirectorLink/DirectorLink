// The DirectorLink account (docs/ACCOUNTS.md): signing in with Google or Apple through
// api.directorlink.io. The session is a cookie of api.directorlink.io that this page cannot read;
// the app only asks who is signed in. A device that never signed in contacts the account server
// only once someone chooses to sign in: using the app on the home network stays between this
// device and the controller. A device signed in here, or linked to its home through the account,
// asks at each start (1.13.2, ADR-089).

import { notify, state } from "./state.js";

export const ACCOUNTS_API = /^(localhost|127\.0\.0\.1)$/.test(window.location.hostname) ? "http://localhost:8787" : "https://api.directorlink.io";

// Set after a sign-in on this device, so the app knows to ask for the account on the next start.
const SIGNED_IN_KEY = "directorlink.account";
// A sign-out that did not reach the account service (1.13.2): its session goes on, so the app stays
// signed in and sends the sign-out again first at the next start.
const SIGN_OUT_KEY = "directorlink.signOut";
// This device deleted its account (1.13.2): signing in again cannot bring back remote access to its
// home, so nothing asks for it (views/common.js) until the next sign-in.
const DELETED_KEY = "directorlink.accountDeleted";
// The sign-ins the account server has set up, as it last said (a JSON list).
const PROVIDERS_KEY = "directorlink.providers";
const TIMEOUT_MS = 8000;

function flag(key, on) {
  try {
    if (on) localStorage.setItem(key, "1");
    else localStorage.removeItem(key);
  } catch {
    // Blocked storage: the account is asked for when Settings opens.
  }
}

function flagged(key) {
  try {
    return localStorage.getItem(key) === "1";
  } catch {
    return false;
  }
}

function remember(on) {
  flag(SIGNED_IN_KEY, on);
  if (on) flag(DELETED_KEY, false);
}

function remembered() {
  return flagged(SIGNED_IN_KEY);
}

// Whether this device deleted its account (and has not signed in since).
export function accountDeleted() {
  return flagged(DELETED_KEY);
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
      // The session has ended: a sign-out still to send has nothing left to end, and "You're still
      // signed in" no longer holds (a sign-in's outcome stays).
      flag(SIGN_OUT_KEY, false);
      remember(false);
      set({ status: "signed-out", notice: state.account.notice === "signOutFailed" ? null : state.account.notice });
    } else {
      set({ status: "unavailable", notice: state.account.notice });
    }
  } catch {
    set({ status: "unavailable", notice: state.account.notice });
  }
}

// On start: the outcome of a sign-in that just came back (?signin=…), then the account. A sign-out
// that did not reach the account service is sent again first. A device signed in here, or linked to
// its home through the account (`linked`), asks who is signed in rather than assume it is signed
// out; any other device asks nothing (it never signed in, or signed out), nor does one that deleted
// its account (signing in again would not bring its home back).
export function startAccount({ linked = false } = {}) {
  watchOtherTabs();
  const url = new URL(window.location.href);
  const outcome = url.searchParams.get("signin");
  if (outcome) {
    url.searchParams.delete("signin");
    window.history.replaceState(window.history.state, "", url.pathname + url.search + url.hash);
    state.account = { ...state.account, notice: outcome === "ok" ? null : outcome };
    // Back from Google or Apple, a sign-in or a sign-in method added to the account, whatever came
    // of it: after a sign-out that did not reach the account service the person went on using the
    // account, so it is not sent again.
    flag(SIGN_OUT_KEY, false);
  }
  if (outcome === "ok") {
    // A new session, remembered at once: a first look that fails does not make it look signed out.
    remember(true);
    loadAccount();
  } else if (flagged(SIGN_OUT_KEY)) {
    finishSignOut();
  } else if (remembered() || (linked && !accountDeleted())) {
    loadAccount();
  } else {
    set({ status: "signed-out", notice: state.account.notice });
  }
}

// A request through the account was answered (remote.js): the session works. When the app thinks
// it is signed out (a start that assumed it), it asks again: it never says "signed out" while the
// account works. A sign-out that did not reach the account service is sent again now that the
// service answers: the person asked for it. At most once a minute, and not while a sign-out is on
// its way.
let recheckedAt = -Infinity;
export function sessionWorks() {
  const signingOut = flagged(SIGN_OUT_KEY);
  if ((!signingOut && state.account.status !== "signed-out") || state.account.busy || Date.now() - recheckedAt < 60_000) return;
  recheckedAt = Date.now();
  if (signingOut) signOut();
  else loadAccount();
}

// A sign-in in another tab or window of this browser, which shares its cookies and storage (two
// tabs on a computer, the installed app and a Chrome tab on Android): its signed-in mark comes here
// as a storage event, and this one asks too, so it does not go on saying signed out (at home no
// request through the account would tell it).
let watching = false;
function watchOtherTabs() {
  if (watching) return;
  watching = true;
  window.addEventListener("storage", (event) => {
    if (event.key !== SIGNED_IN_KEY || event.newValue !== "1" || state.account.busy) return;
    if (state.account.status === "signed-out" || state.account.status === "unavailable") loadAccount();
  });
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

// Ends this device's session at the account service: true once it has (204), or had already
// ended (401); false when the service could not be reached or answered anything else.
async function endSession() {
  try {
    const response = await call("/auth/logout", "POST");
    return response.status === 204 || response.status === 401;
  } catch {
    return false;
  }
}

// Signed out, once the account service has ended the session: forgotten on this device.
function signedOut(notice = null) {
  flag(SIGN_OUT_KEY, false);
  remember(false);
  set({ status: "signed-out", notice });
}

// The session a sign-out did not end goes on (until a year after its sign-in, ADR-089): the app
// stays signed in and says so (Settings → Account, with Retry); the sign-out is sent again once a
// request through the account works (sessionWorks), and first at the next start.
function signOutFailed() {
  flag(SIGN_OUT_KEY, true);
  set({ ...state.account, busy: false, notice: "signOutFailed" });
}

// A sign-out the account service did not confirm (no answer, or another one) may have ended the
// session all the same, its answer lost or cut off by the timeout: /v1/me says. Signed out on its
// 401; otherwise still signed in, with the notice. `before`: the account as the app had it, kept
// when /v1/me does not answer either (at start nothing was known: "unavailable").
async function signOutUnconfirmed(before = null) {
  await loadAccount();
  if (state.account.status === "signed-out") {
    signedOut();
    return;
  }
  if (state.account.status === "unavailable" && before?.status === "signed-in") set(before);
  signOutFailed();
}

// At start, a sign-out asked for before (startAccount): signed out once the account service ends
// the session; otherwise as it says, with the notice.
async function finishSignOut() {
  set({ ...state.account, status: "loading", busy: true });
  if (await endSession()) signedOut();
  else await signOutUnconfirmed();
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
      signedOut("signedOutEverywhere");
    } else if (response?.status === 401) {
      signedOut("signOutEverywhereExpired");
    } else {
      set({ ...state.account, busy: false, notice: "signOutEverywhereFailed" });
    }
    return;
  }
  // Only once the account service has ended the session: otherwise it would go on while this
  // device says it is signed out. Without its word, /v1/me says, as at start.
  const before = state.account;
  if (await endSession()) signedOut();
  else await signOutUnconfirmed(before);
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
      flag(SIGN_OUT_KEY, false);
      remember(false);
      // Its homes and memberships went with it: signing in again would not reach the home.
      if (response.status === 204) flag(DELETED_KEY, true);
      set({ status: "signed-out", notice: "deleted" });
      return true;
    }
  } catch {
    // Reported below.
  }
  set({ ...state.account, busy: false, notice: "deleteFailed" });
  return false;
}
