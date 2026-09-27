// DirectorLink Console: hash router, header, and start-up. Tabs live in js/.
//
// API calls (see api/openapi.yaml): "/v1/openapi.json", "/v1/system", "/v1/health",
// "/v1/api-keys/current", "/v1/api-keys", "/v1/auth/pair", "/v1/logs?", "/v1/logs/settings".

import { renderConnection } from "./js/connection.js";
import { byId } from "./js/dom.js";
import { renderExplorer } from "./js/explorer.js";
import { hideLogs, resetLogs, showLogs } from "./js/logs.js";
import { connect, state, subscribe } from "./js/session.js";
import { renderSystem } from "./js/system.js";
import { resetKeys, showKeys } from "./js/keys.js";

const TABS = ["api", "logs", "system", "keys", "connect"];
const TAB_STORAGE_KEY = "directorlink.console.tab";

const statusChip = byId("status-chip");
const statusText = byId("status-text");
const headerHost = byId("header-host");
const tabs = byId("tabs");
const main = byId("main");
const views = Object.fromEntries(TABS.map((tab) => [tab, byId(`view-${tab}`)]));

function readStored(key) {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function parseRoute() {
  const [tab, ...rest] = window.location.hash.replace(/^#\/?/, "").split("/");
  if (!TABS.includes(tab)) return null;
  return { tab, id: rest.length ? decodeURIComponent(rest.join("/")) : null };
}

// Without a key only the connection screen is useful.
function effectiveRoute() {
  const route = parseRoute();
  if (!state.apiKey) return { tab: "connect", id: null };
  return route || { tab: "api", id: null };
}

const STATUS = {
  setup: ["Not connected", "idle"],
  connecting: ["Connecting…", "busy"],
  connected: ["Connected", "ok"],
  unreachable: ["Can't reach the controller", "error"],
};

function renderHeader() {
  const [label, kind] = STATUS[state.status] || STATUS.setup;
  statusText.textContent = state.status === "connected" && state.role ? `${label} · ${state.role}` : label;
  statusChip.className = `status-chip status-${kind}`;
  headerHost.textContent = state.host ? `${state.host}:41999` : "No controller";
  for (const link of tabs.querySelectorAll("[data-tab]")) {
    const tab = link.dataset.tab;
    link.hidden = tab !== "connect" && !state.apiKey;
  }
}

let current = null;
let sessionSignature = "";

function render({ routeChanged = false } = {}) {
  renderHeader();
  const route = effectiveRoute();
  const signature = [state.host, state.apiKey ? "key" : "", state.role, state.status === "connected"].join("|");
  const sessionChanged = signature !== sessionSignature;
  if (sessionChanged && (sessionSignature.split("|")[0] !== state.host || !state.apiKey)) {
    resetLogs();
    resetKeys();
  }
  sessionSignature = signature;

  const tabChanged = route.tab !== current?.tab;
  if (tabChanged && current?.tab === "logs") hideLogs();
  if (tabChanged && current?.tab === "keys") resetKeys();
  current = route;

  for (const [tab, element] of Object.entries(views)) element.hidden = tab !== route.tab;
  for (const link of tabs.querySelectorAll("[data-tab]")) {
    if (link.dataset.tab === route.tab) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
  if (route.tab !== "connect") {
    try {
      window.localStorage.setItem(TAB_STORAGE_KEY, route.tab);
    } catch {
      // Private mode: nothing to remember.
    }
  }

  // Connection and API render on every change; the others only when the tab or the session changes.
  renderConnection();
  if (route.tab === "api") renderExplorer(route.id);
  if (route.tab === "system") renderSystem();
  if (route.tab === "logs" && (tabChanged || sessionChanged)) showLogs();
  if (route.tab === "keys" && (tabChanged || sessionChanged)) showKeys();

  if (routeChanged && tabChanged) {
    main.focus({ preventScroll: true });
  }
}

window.addEventListener("hashchange", () => render({ routeChanged: true }));
subscribe(() => render());

// Start: the last tab, and reconnect with the saved key.
if (!parseRoute()) {
  const last = readStored(TAB_STORAGE_KEY);
  if (state.apiKey && TABS.includes(last)) {
    window.history.replaceState(null, "", `#/${last}`);
  }
}
render();
if (state.apiKey) connect();
