// Offline shell for the DirectorLink app.
// Same-origin GET requests are network-first with a short timeout and fall back to the cache,
// so the app still opens when the internet is down but the home LAN (and the controller) is up.
// Requests to the controller are cross-origin and are never intercepted.
// It also opens the app when a doorbell notification is clicked, and shows alerts (push).

const CACHE_NAME = "directorlink-shell-v38";
const NETWORK_TIMEOUT_MS = 3000;

// Each page is stored under every path that serves it: Cloudflare redirects /index.html -> /,
// while a plain static server does not. (The API console is its own site, console.directorlink.io.)
const PAGES = [{ source: "/", paths: ["/", "/index.html"] }];

const ASSETS = [
  "/styles.css",
  "/theme-boot.js",
  "/app.js",
  "/api-client.js",
  "/js/account.js",
  "/js/alerts.js",
  "/js/views/alerts.js",
  "/js/alarm.js",
  "/js/music.js",
  "/js/views/music.js",
  "/js/backup.js",
  "/js/lock.js",
  "/js/cpace.js",
  "/js/platform.js",
  "/js/qr.js",
  "/js/remote.js",
  "/js/reorder.js",
  "/js/vendor/qrcodegen.js",
  "/js/views/join.js",
  "/js/views/access.js",
  "/js/views/scenes.js",
  "/js/scenes.js",
  "/js/views/schedules.js",
  "/js/schedules.js",
  "/js/calendar.js",
  "/js/profile.js",
  "/js/camera-feed.js",
  "/js/components.js",
  "/js/controls.js",
  "/js/dom.js",
  "/js/doorbells.js",
  "/js/fans.js",
  "/js/favorites.js",
  "/js/find.js",
  "/js/i18n.js",
  "/js/icons.js",
  "/js/model.js",
  "/js/pwa.js",
  "/js/rings.js",
  "/js/session.js",
  "/js/setpoints.js",
  "/js/shades.js",
  "/js/state.js",
  "/js/theme.js",
  "/js/turn-off.js",
  "/js/updates.js",
  "/js/version.js",
  "/js/views/alarm.js",
  "/js/views/backup.js",
  "/js/views/cameras.js",
  "/js/views/climate.js",
  "/js/views/common.js",
  "/js/views/connect.js",
  "/js/views/find.js",
  "/js/views/home.js",
  "/js/views/room.js",
  "/js/views/settings.js",
  "/js/views/updates.js",
  // Languages. One added later is saved on first use even if it is not listed here.
  "/i18n/en.js",
  "/i18n/he.js",
  "/manifest.webmanifest",
  "/icons/icon.svg",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
];

// Browsers refuse redirected responses for page loads, so store a plain copy instead.
async function storable(response) {
  if (!response.redirected) {
    return response;
  }
  return new Response(await response.blob(), {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
}

async function fetchForCache(path) {
  const response = await fetch(path, { cache: "reload" });
  if (!response.ok) {
    throw new Error(`Could not cache ${path}: HTTP ${response.status}`);
  }
  return storable(response);
}

async function precache() {
  const cache = await caches.open(CACHE_NAME);
  await Promise.all([
    ...PAGES.map(async (page) => {
      const response = await fetchForCache(page.source);
      await Promise.all(page.paths.map((path) => cache.put(path, response.clone())));
    }),
    ...ASSETS.map(async (path) => cache.put(path, await fetchForCache(path))),
  ]);
}

function withTimeout(promise, milliseconds) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("network timeout")), milliseconds);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      }
    );
  });
}

async function remember(key, response) {
  if (response.ok && response.type === "basic") {
    const cache = await caches.open(CACHE_NAME);
    await cache.put(key, await storable(response));
  }
}

// Saving to the cache runs in the background so it never delays the response.
async function handlePage(event) {
  const request = event.request;
  const path = new URL(request.url).pathname;
  try {
    // A navigation fetch returns redirects unfollowed; the browser follows them itself.
    const response = await withTimeout(fetch(request), NETWORK_TIMEOUT_MS);
    if (!response.redirected) {
      event.waitUntil(remember(path, response.clone()));
    }
    return response;
  } catch {
    const cache = await caches.open(CACHE_NAME);
    return (
      (await cache.match(path, { ignoreSearch: true })) ||
      (await cache.match("/")) ||
      Response.error()
    );
  }
}

async function handleAsset(event) {
  const request = event.request;
  try {
    const response = await withTimeout(fetch(request), NETWORK_TIMEOUT_MS);
    event.waitUntil(remember(request, response.clone()));
    return response;
  } catch {
    const cache = await caches.open(CACHE_NAME);
    return (await cache.match(request, { ignoreSearch: true })) || Response.error();
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil(precache().then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME && key !== ALERT_TEXTS_CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

// Alerts (ADR-047): a push from api.directorlink.io says only what happened, at which home and when,
// { kind: "offline" | "schedule_failed", home, at }, encrypted for this browser. The words are the
// app's, in its language (js/alerts.js keeps them here); English when there are none. Every push
// shows a notification, which opens the home's history.
const ALERT_TEXTS_CACHE = "directorlink-alerts";
const ALERT_TEXTS_PATH = "/alert-texts.json";
const ALERT_TEXTS = {
  lang: "en",
  dir: "ltr",
  title: "DirectorLink",
  offline: "Your home – DirectorLink has not reached it since {time}. Check the home’s internet connection and the controller.",
  schedule_failed: "Your home – a schedule had a problem at {time}. Open the app to see what happened.",
  other: "Your home – something needs your attention. Open the app to see what happened.",
};

async function alertTexts() {
  try {
    const saved = await (await caches.open(ALERT_TEXTS_CACHE)).match(ALERT_TEXTS_PATH);
    const texts = saved ? await saved.json() : null;
    if (texts && typeof texts === "object") return { ...ALERT_TEXTS, ...texts };
  } catch {
    // English, then.
  }
  return ALERT_TEXTS;
}

// The alert's time on this device's clock, 24-hour.
function alertTime(at, lang) {
  const date = new Date(at);
  if (!Number.isFinite(date.getTime())) return "";
  try {
    return new Intl.DateTimeFormat(lang, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(date);
  } catch {
    return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }
}

async function showAlert(data) {
  let alert = null;
  try {
    alert = data ? data.json() : null;
  } catch {
    alert = null;
  }
  const texts = await alertTexts();
  const kind = alert?.kind === "offline" || alert?.kind === "schedule_failed" ? alert.kind : "other";
  const home = /^[0-9a-f]{32}$/.test(alert?.home ?? "") ? alert.home : "";
  await self.registration.showNotification(texts.title, {
    body: String(texts[kind]).replace("{time}", kind === "other" ? "" : alertTime(alert.at, texts.lang)),
    tag: `alert-${kind}-${home}`,
    renotify: true,
    lang: texts.lang,
    dir: texts.dir,
    icon: "/icons/icon-192.png",
    data: { url: "/#/settings/history" },
  });
}

self.addEventListener("push", (event) => {
  event.waitUntil(showAlert(event.data));
});

// A doorbell notification (shown while the app is open): bring the app to the front on Home,
// or open it when no window is left. An alert's: the home's history.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || "/#/", self.location.origin).href;
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      const client = windows.find((item) => new URL(item.url).origin === self.location.origin);
      if (client) {
        client.postMessage({ type: "directorlink-open", url });
        return client.focus();
      }
      return self.clients.openWindow(url);
    })
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const requestUrl = new URL(request.url);

  // Never intercept controller/LAN requests. The service worker only owns directorlink.io assets.
  if (requestUrl.origin !== self.location.origin || request.method !== "GET") {
    return;
  }

  event.respondWith(request.mode === "navigate" ? handlePage(event) : handleAsset(event));
});
