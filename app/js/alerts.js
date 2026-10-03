// Alerts on this device (ADR-047): notifications from DirectorLink's servers (Web Push) when the
// home has been offline for 10 minutes or a schedule had a problem, for the home's admins signed in
// to an account. Switched on and off only from Settings → Controller, which is also the only place
// that asks for permission. An alert carries only its kind, the home id and a time; the service
// worker (sw.js) shows it with the words kept here for it, in this device's language, and tapping it
// opens Settings → Controller → History.

import { ACCOUNTS_API } from "./account.js";
import { currentLanguage, languageInfo, t } from "./i18n.js";
import { IS_IOS } from "./platform.js";
import { savedRemote } from "./remote.js";
import { checkInThroughAccount, whenForgotten } from "./session.js";
import { notify, state, subscribe } from "./state.js";

const ALERTS_KEY = "directorlink.alerts"; // { home, endpoint }: this browser gets that home's alerts
// Where the service worker finds the words (sw.js uses the same names).
export const TEXTS_CACHE = "directorlink-alerts";
export const TEXTS_PATH = "/alert-texts.json";
const TIMEOUT_MS = 10000;

// What Settings shows: busy while switching; message: { kind, key } once done (the text is
// alerts.settings.<key>, in the language shown).
export const alertsUi = { busy: false, message: null };
// The registration was made again since the page opened (refreshAlerts), or just now.
let refreshed = false;

function remembered() {
  try {
    const value = JSON.parse(localStorage.getItem(ALERTS_KEY) || "null");
    return value && /^[0-9a-f]{32}$/.test(value.home) && typeof value.endpoint === "string" ? value : null;
  } catch {
    return null;
  }
}

function remember(value) {
  try {
    if (value) localStorage.setItem(ALERTS_KEY, JSON.stringify({ home: value.home, endpoint: value.endpoint }));
    else localStorage.removeItem(ALERTS_KEY);
  } catch {
    // Blocked storage: the switch shows off next time; the alerts still come.
  }
}

// Opened from the Home Screen (or installed on a computer or Android).
function installed() {
  try {
    if (window.matchMedia("(display-mode: standalone)").matches) return true;
  } catch {
    // No media queries here.
  }
  return navigator.standalone === true;
}

// "ok"; "denied" (notifications are blocked for the site); on iPhone and iPad "homeScreen" (only the
// app added to the Home Screen gets them, iOS 16.4 or later) or "iosVersion" (added, but an older
// iOS); else "unsupported".
export function alertsSupport() {
  const push = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window && window.isSecureContext;
  if (!push) {
    if (!IS_IOS) return "unsupported";
    return installed() ? "iosVersion" : "homeScreen";
  }
  return Notification.permission === "denied" ? "denied" : "ok";
}

// Whether this browser gets the alerts of the home this device is linked to.
export function alertsOn() {
  const saved = remembered();
  return Boolean(saved && saved.home === savedRemote()?.home && alertsSupport() === "ok" && Notification.permission === "granted");
}

// What Settings → Controller shows of it, for app.js's redraws.
export function alertsSignature() {
  return [alertsOn(), alertsSupport(), alertsUi.busy, alertsUi.message];
}

// The words the service worker shows, in this device's language. {time} is filled in there.
export function alertTexts() {
  const home = t("alerts.yourHome");
  return {
    lang: currentLanguage(),
    dir: languageInfo().dir,
    title: t("alerts.title"),
    offline: t("alerts.offline", { home }),
    schedule_failed: t("alerts.scheduleFailed", { home }),
    other: t("alerts.other", { home }),
  };
}

async function saveTexts() {
  try {
    const cache = await caches.open(TEXTS_CACHE);
    await cache.put(TEXTS_PATH, new Response(JSON.stringify(alertTexts()), { headers: { "content-type": "application/json" } }));
  } catch {
    // The service worker then uses English.
  }
}

function withTimeout(promise) {
  let timer;
  const late = new Promise((_, reject) => {
    timer = window.setTimeout(() => reject(new Error("timeout")), TIMEOUT_MS);
  });
  return Promise.race([promise, late]).finally(() => window.clearTimeout(timer));
}

// GET, POST or DELETE /v1/homes/{home}/alerts at the account service: { status, data }.
async function cloud(method, home, body) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(`${ACCOUNTS_API}/v1/homes/${home}/alerts`, {
      method,
      credentials: "include",
      cache: "no-store",
      headers: body === undefined ? {} : { "content-type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
    return { status: response.status, data: await response.json().catch(() => null) };
  } finally {
    window.clearTimeout(timer);
  }
}

function keyBytes(text) {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4));
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function sameKey(buffer, bytes) {
  const current = buffer ? new Uint8Array(buffer) : null;
  return Boolean(current && current.length === bytes.length && current.every((value, index) => value === bytes[index]));
}

// This browser's push subscription for `publicKey` (the account service's VAPID key): the one it
// has, or a new one (also when the service's key was replaced).
async function browserSubscription(registration, publicKey) {
  const bytes = keyBytes(publicKey);
  let subscription = await registration.pushManager.getSubscription();
  if (subscription && !sameKey(subscription.options?.applicationServerKey, bytes)) {
    await subscription.unsubscribe().catch(() => {});
    subscription = null;
  }
  return subscription || registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: bytes });
}

function register(home, subscription) {
  const { endpoint, keys } = subscription.toJSON();
  return cloud("POST", home, { endpoint, keys });
}

function refusal(result) {
  switch (result?.data?.code) {
    case "ADMIN_ONLY":
      return "adminOnly";
    case "ROLES_UNKNOWN":
      return "needsUpdate";
    case "ALERTS_NOT_CONFIGURED":
      return "notAvailable";
    case "NOT_SIGNED_IN":
      return "signIn";
    case "NOT_A_MEMBER":
      return "notLinked";
    default:
      return "failed";
  }
}

function finish(kind, key) {
  alertsUi.busy = false;
  alertsUi.message = key ? { kind, key } : null;
  notify();
}

// The switch, turned on: permission (asked only here), this browser's subscription, registered
// with the account service for the home this device is linked to.
export async function turnAlertsOn() {
  const remote = savedRemote();
  if (alertsUi.busy || !remote || alertsSupport() !== "ok") return;
  alertsUi.busy = true;
  alertsUi.message = null;
  notify();
  try {
    const permission = Notification.permission === "granted" ? "granted" : await Notification.requestPermission();
    if (permission !== "granted") {
      finish("error", "blocked");
      return;
    }
    const key = await cloud("GET", remote.home);
    if (key.status !== 200 || typeof key.data?.public_key !== "string") {
      finish("error", refusal(key));
      return;
    }
    const registration = await withTimeout(navigator.serviceWorker.ready);
    const subscription = await browserSubscription(registration, key.data.public_key);
    let result = await register(remote.home, subscription);
    if (result.status === 403 && result.data?.code === "ADMIN_ONLY") {
      // The account service learns which key this device uses from a request sealed through the
      // account; it may not have had one yet.
      await checkInThroughAccount(true);
      result = await register(remote.home, subscription);
    }
    if (result.status !== 201) {
      await subscription.unsubscribe().catch(() => {});
      finish("error", refusal(result));
      return;
    }
    remember({ home: remote.home, endpoint: subscription.endpoint });
    await saveTexts();
    refreshed = true;
    finish("success", "turnedOn");
  } catch {
    finish("error", "failed");
  }
}

// The switch, turned off; also when this device signs out, forgets its key or is linked to another
// home (`quiet`: nothing to say). The account service forgets this browser, and the browser drops
// its subscription, so nothing arrives even if the first could not be reached.
export async function turnAlertsOff({ quiet = false } = {}) {
  const saved = remembered();
  if (quiet ? !saved : alertsUi.busy) return;
  if (!quiet) {
    alertsUi.busy = true;
    alertsUi.message = null;
    notify();
  }
  try {
    const registration = "serviceWorker" in navigator ? await navigator.serviceWorker.getRegistration() : null;
    const subscription = await registration?.pushManager?.getSubscription();
    const endpoint = subscription?.endpoint || saved?.endpoint;
    if (saved && endpoint) await cloud("DELETE", saved.home, { endpoint }).catch(() => null);
    await subscription?.unsubscribe();
  } catch {
    // Unsubscribed or not, the switch is off: the account service drops a browser its push
    // service no longer knows.
  }
  remember(null);
  if (quiet) notify();
  else finish("info", "turnedOff");
}

// Once per start, signed in: the registration is made again (the browser may have a new
// subscription, the account service a new key), or ended when this device may no longer have it.
async function refreshAlerts() {
  const saved = remembered();
  if (!saved) return;
  if (saved.home !== savedRemote()?.home || alertsSupport() !== "ok" || Notification.permission !== "granted") {
    await turnAlertsOff({ quiet: true });
    return;
  }
  try {
    const key = await cloud("GET", saved.home);
    if (key.status === 403) {
      await turnAlertsOff({ quiet: true });
      return;
    }
    if (key.status !== 200 || typeof key.data?.public_key !== "string") return; // asked again next time
    const registration = await withTimeout(navigator.serviceWorker.ready);
    let subscription;
    try {
      subscription = await browserSubscription(registration, key.data.public_key);
    } catch {
      // The browser dropped it and will not make another without a tap: the switch shows off.
      remember(null);
      notify();
      return;
    }
    const result = await register(saved.home, subscription);
    if (result.status === 201) {
      if (subscription.endpoint !== saved.endpoint) {
        await cloud("DELETE", saved.home, { endpoint: saved.endpoint }).catch(() => null);
        remember({ home: saved.home, endpoint: subscription.endpoint });
      }
      await saveTexts();
    } else if (result.status === 403 || result.status === 409) {
      await subscription.unsubscribe().catch(() => {});
      remember(null);
      alertsUi.message = { kind: "info", key: refusal(result) };
    }
  } catch {
    // Offline, or the push service is: next time.
  }
  notify();
}

// The words follow the app's language; the registration is renewed once signed in.
let textsLanguage = null;
subscribe(() => {
  if (!remembered()) return;
  if (textsLanguage !== currentLanguage()) {
    textsLanguage = currentLanguage();
    saveTexts();
  }
  if (!refreshed && state.account.status === "signed-in") {
    refreshed = true;
    refreshAlerts();
  }
});

// A forgotten key ends this device's alerts (it may belong to someone else next).
whenForgotten(() => turnAlertsOff({ quiet: true }));
