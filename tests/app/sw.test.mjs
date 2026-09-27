// Tests app/sw.js offline behaviour with a fake network that serves the app like Cloudflare
// (/index.html -> /, and app/_redirects: /console.html and /console -> console.directorlink.io)
// and a fake Cache Storage.
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const SOURCE = readFileSync(new URL("../../app/sw.js", import.meta.url), "utf8");
const ORIGIN = "https://app.directorlink.io";

const FILES = {
  "/": "<html>dashboard</html>",
  "/styles.css": "body{}",
  "/app.js": "app",
  "/api-client.js": "client",
  "/theme-boot.js": "boot",
  "/i18n/en.js": "en",
  "/i18n/he.js": "he",
  "/manifest.webmanifest": "{}",
  "/icons/icon.svg": "<svg/>",
  "/icons/icon-192.png": "png",
  "/icons/icon-512.png": "png",
};
// The app's ES modules (app/js/**) are precached too.
for (const [, path] of SOURCE.matchAll(/"(\/js\/[^"]+\.js)"/g)) FILES[path] = `module ${path}`;
const REDIRECTS = { "/index.html": "/" };
// app/_redirects: the API console moved to its own site.
const EXTERNAL = { "/console.html": "https://console.directorlink.io", "/console": "https://console.directorlink.io" };

// Node's Response cannot be constructed as "basic" or "redirected"; set them the way a browser
// would, and keep them on clones (browsers preserve them through clone()).
function withProps(response, props) {
  const clone = response.clone.bind(response);
  for (const [name, value] of Object.entries(props)) {
    Object.defineProperty(response, name, { value });
  }
  Object.defineProperty(response, "clone", { value: () => withProps(clone(), props) });
  return response;
}

// Serves FILES; follows redirects unless the request is a navigation (redirect: manual).
function makeNetwork() {
  const network = { online: true, hang: false, version: "", requests: [] };
  network.fetch = async (input) => {
    const url = new URL(typeof input === "string" ? input : input.url, ORIGIN);
    const navigate = typeof input === "object" && input.mode === "navigate";
    network.requests.push(url.pathname);
    if (network.hang) return new Promise(() => {});
    if (!network.online) throw new TypeError("Failed to fetch");
    let path = url.pathname;
    let redirected = false;
    if (EXTERNAL[path]) {
      if (navigate) {
        return { type: "opaqueredirect", ok: false, status: 0, redirected: false, clone() { return this; } };
      }
      // A plain fetch follows the redirect to the other site (a CORS response, never "basic").
      return withProps(new Response("console site", { status: 200 }), { type: "cors", url: EXTERNAL[path], redirected: true });
    }
    if (REDIRECTS[path]) {
      if (navigate) {
        return { type: "opaqueredirect", ok: false, status: 0, redirected: false, clone() { return this; } };
      }
      path = REDIRECTS[path];
      redirected = true;
    }
    if (!(path in FILES)) {
      return withProps(new Response("not found", { status: 404 }), { type: "basic", url: ORIGIN + path });
    }
    return withProps(new Response(FILES[path] + network.version, { status: 200 }), {
      type: "basic",
      url: ORIGIN + path,
      redirected,
    });
  };
  return network;
}

function keyOf(request, options = {}) {
  const url = new URL(typeof request === "string" ? request : request.url, ORIGIN);
  return options.ignoreSearch ? url.pathname : url.pathname + url.search;
}

class FakeCache {
  entries = new Map();
  async put(request, response) {
    this.entries.set(keyOf(request), { response, body: await response.clone().text() });
  }
  async match(request, options) {
    const entry = this.entries.get(keyOf(request, options));
    return entry ? withProps(new Response(entry.body, { status: entry.response.status }), { redirected: entry.response.redirected }) : undefined;
  }
}

class FakeCacheStorage {
  stores = new Map();
  async open(name) {
    if (!this.stores.has(name)) this.stores.set(name, new FakeCache());
    return this.stores.get(name);
  }
  async keys() {
    return [...this.stores.keys()];
  }
  async delete(name) {
    return this.stores.delete(name);
  }
}

async function startWorker({ oldCaches = [], windows = [], opened = [] } = {}) {
  const listeners = {};
  const network = makeNetwork();
  const storage = new FakeCacheStorage();
  for (const name of oldCaches) await storage.open(name);
  const self = {
    location: { origin: ORIGIN },
    addEventListener: (type, listener) => (listeners[type] = listener),
    skipWaiting: async () => {},
    clients: {
      claim: async () => {},
      matchAll: async () => windows,
      openWindow: async (url) => {
        opened.push(url);
      },
    },
  };
  const fastTimers = (callback, milliseconds) => setTimeout(callback, Math.min(milliseconds, 20));
  vm.runInNewContext(SOURCE, {
    self,
    caches: storage,
    fetch: network.fetch,
    Response,
    URL,
    setTimeout: fastTimers,
    clearTimeout,
  });

  const lifecycle = async (type) => {
    let pending;
    listeners[type]({ waitUntil: (promise) => (pending = promise) });
    await pending;
  };
  await lifecycle("install");
  await lifecycle("activate");

  const request = async (path, { mode = "navigate", method = "GET", origin = ORIGIN } = {}) => {
    const background = [];
    let responded = null;
    listeners.fetch({
      request: { url: origin + path, method, mode },
      respondWith: (promise) => (responded = promise),
      waitUntil: (promise) => background.push(promise),
    });
    if (!responded) return null;
    const response = await responded;
    await Promise.all(background);
    return response;
  };
  const notificationClick = async (data) => {
    let pending;
    let closed = false;
    listeners.notificationclick({ notification: { data, close: () => (closed = true) }, waitUntil: (promise) => (pending = promise) });
    await pending;
    return closed;
  };
  return { network, storage, request, notificationClick };
}

async function textOf(response) {
  return response && response.type !== "opaqueredirect" ? await response.text() : null;
}

test("install saves every page under each path, without redirects", async () => {
  const { storage } = await startWorker();
  const cache = await storage.open((await storage.keys())[0]);
  for (const [path, body] of [["/", "dashboard"], ["/index.html", "dashboard"]]) {
    const saved = await cache.match(path);
    assert.ok(saved, `${path} is cached`);
    assert.equal(saved.redirected, false, `${path} is stored without the redirect flag`);
    assert.match(await saved.text(), new RegExp(body));
  }
  for (const asset of ["/styles.css", "/app.js", "/api-client.js", "/theme-boot.js", "/js/views/home.js", "/js/doorbells.js", "/js/rings.js", "/i18n/he.js", "/icons/icon-512.png"]) {
    assert.ok(await cache.match(asset), `${asset} is cached`);
  }
  // The API console moved to its own site (console.directorlink.io).
  for (const gone of ["/console", "/console.html", "/console.js", "/console.css"]) {
    assert.equal(await cache.match(gone), undefined, `${gone} is no longer cached`);
  }
});

test("activate removes caches from older versions", async () => {
  const { storage } = await startWorker({ oldCaches: ["directorlink-shell-v16", "directorlink-shell-v17"] });
  assert.deepEqual(await storage.keys(), ["directorlink-shell-v18"]);
});

test("online page loads come from the network and refresh the saved copy", async () => {
  const { network, request } = await startWorker();
  network.version = " v2";
  assert.equal(await textOf(await request("/")), "<html>dashboard</html> v2");
  network.online = false;
  assert.equal(await textOf(await request("/")), "<html>dashboard</html> v2", "the refreshed copy is used offline");
});

test("offline page loads are served from the saved copy", async () => {
  const { network, request } = await startWorker();
  network.online = false;
  assert.equal(await textOf(await request("/index.html")), "<html>dashboard</html>");
  assert.equal(await textOf(await request("/?from=home-screen")), "<html>dashboard</html>");
  assert.equal(await textOf(await request("/unknown-page")), "<html>dashboard</html>", "unknown pages fall back to the dashboard");
});

test("a slow network falls back to the saved copy", async () => {
  const { network, request } = await startWorker();
  network.hang = true;
  assert.equal(await textOf(await request("/")), "<html>dashboard</html>");
  assert.equal(await textOf(await request("/app.js", { mode: "cors" })), "app");
});

test("online redirects are left for the browser to follow", async () => {
  const { request } = await startWorker();
  const response = await request("/index.html");
  assert.equal(response.type, "opaqueredirect");
});

test("the old console address follows the redirect to console.directorlink.io and is never cached", async () => {
  const { network, storage, request } = await startWorker();
  for (const path of ["/console.html", "/console"]) {
    assert.equal((await request(path)).type, "opaqueredirect", `${path} is left to the browser's redirect`);
  }
  const cache = await storage.open((await storage.keys())[0]);
  for (const path of ["/console.html", "/console"]) {
    assert.equal(await cache.match(path), undefined, `${path} is not cached`);
  }
  network.online = false;
  assert.equal(await textOf(await request("/console.html")), "<html>dashboard</html>", "offline, the old address opens the app");
});

test("offline assets come from the cache; unknown ones fail cleanly", async () => {
  const { network, request } = await startWorker();
  network.online = false;
  assert.equal(await textOf(await request("/styles.css", { mode: "no-cors" })), "body{}");
  assert.equal((await request("/missing.js", { mode: "cors" })).type, "error");
});

test("controller requests and non-GET requests are never intercepted", async () => {
  const { request } = await startWorker();
  assert.equal(await request("/v1/lights", { mode: "cors", origin: "http://192.168.1.201:41999" }), null);
  assert.equal(await request("/v1/lights", { mode: "cors", method: "PATCH" }), null);
});

test("a doorbell notification click brings the open app to Home, or opens it", async () => {
  const focused = [];
  const messages = [];
  const opened = [];
  const windows = [
    { url: "https://elsewhere.example/", focus: async () => focused.push("elsewhere"), postMessage: () => {} },
    { url: `${ORIGIN}/#/settings`, focus: async () => focused.push("app"), postMessage: (message) => messages.push(message) },
  ];
  const { notificationClick } = await startWorker({ windows, opened });
  assert.equal(await notificationClick({ url: "/#/" }), true, "the notification is closed");
  assert.deepEqual(focused, ["app"]);
  // The message comes from the worker's realm: copy it before comparing.
  assert.deepEqual(messages.map((message) => ({ ...message })), [{ type: "directorlink-open", url: `${ORIGIN}/#/` }]);
  windows.length = 0;
  await notificationClick({ url: "/#/" });
  assert.deepEqual(opened, [`${ORIGIN}/#/`], "with no window left, the app is opened");
});
