// Offline shell for the C4Bridge web app.
// Same-origin GET requests are network-first with a short timeout and fall back to the cache,
// so the app still opens when the internet is down but the home LAN (and the controller) is up.
// Requests to the controller are cross-origin and are never intercepted.

const CACHE_NAME = "c4bridge-shell-v9";
const NETWORK_TIMEOUT_MS = 3000;

// Each page is stored under every path that serves it: Cloudflare redirects
// /index.html -> / and /console.html -> /console, while a plain static server does not.
const PAGES = [
  { source: "/", paths: ["/", "/index.html"] },
  { source: "/console.html", paths: ["/console.html", "/console"] },
];

const ASSETS = [
  "/styles.css",
  "/app.js",
  "/console.js",
  "/api-client.js",
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
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const requestUrl = new URL(request.url);

  // Never intercept controller/LAN requests. The service worker only owns c4bridge.io assets.
  if (requestUrl.origin !== self.location.origin || request.method !== "GET") {
    return;
  }

  event.respondWith(request.mode === "navigate" ? handlePage(event) : handleAsset(event));
});
