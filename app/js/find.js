// Find my controller, on the pairing screen (views/find.js). A web page cannot learn this device's
// address, and browsers cannot look for devices by name (mDNS, SSDP), so the app asks
// GET /v1/health, which needs no key, at the addresses homes use most. Nothing else is sent: no
// key, no pairing code. No browser dependencies (fetch, the permission and the timers are passed
// in), unit-tested in tests/app/find-controller.test.mjs.

import { API_PORT, addressSpace, normalizeHost } from "../api-client.js";
import { isIOS } from "./platform.js";

// The networks home routers hand out, most common first (10.0.0.x: Bezeq's routers in Israel).
export const RANGES = ["192.168.1", "192.168.0", "10.0.0", "10.0.1", "192.168.2", "192.168.10", "192.168.50", "10.1.1", "172.16.0"];

// Where routers usually are (x.138: Bezeq). Whichever answers, even to refuse, shows that its
// network is this one, so that network is looked through first.
const ROUTER_HOSTS = [1, 254, 138];

export const PROBE_TIMEOUT_MS = 1200;
export const ROUTER_TIMEOUT_MS = 2000;
export const CONCURRENCY = 64;
// The whole search, from the first request to the answer.
export const SCAN_BUDGET_MS = 30000;
// Time to answer the browser's question about the local network, before the search starts.
export const PERMISSION_WAIT_MS = 30000;
const PERMISSION_POLL_MS = 500;

// What the screen looks through; trying it with the dev server (README) points it at this computer.
export const scanSettings = { ranges: RANGES, port: API_PORT };

const TIMERS = {
  now: () => Date.now(),
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (timer) => clearTimeout(timer),
};

// Pairing at home works in Chromium browsers, on computers and Android (Local Network Access). Not
// on iPhone and iPad (platform.js), nor in Firefox or Safari, which block the plain-HTTP call.
export function findSupported(nav = globalThis.navigator) {
  if (!nav || isIOS(nav)) return false;
  const brands = nav.userAgentData?.brands;
  if (Array.isArray(brands)) return brands.some((item) => /Chromium/.test(item?.brand));
  return /\bChrom(e|ium)\/\d/.test(nav.userAgent || "");
}

// "192.168.1" for 192.168.1.50; null for a name or anything but an IPv4 address.
export function networkOf(host) {
  const parts = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host || "");
  if (!parts || parts.slice(1).some((part) => Number(part) > 255)) return null;
  return parts.slice(1, 4).map(Number).join(".");
}

// A DirectorLink's health answer: `product` since 1.3.0; before, its own set of fields.
export function recognise(data) {
  if (!data || typeof data !== "object") return null;
  const older =
    data.product === undefined &&
    typeof data.version === "string" &&
    data.api_version === "1" &&
    ["starting", "ok", "error"].includes(data.status) &&
    "detail" in data;
  if (data.product !== "directorlink" && !older) return null;
  return { version: typeof data.version === "string" ? data.version.slice(0, 32) : "" };
}

// Where to look, in order: the address this browser used before, its network, then the others.
export function scanPlan(previous, ranges = RANGES) {
  const host = normalizeHost(previous);
  return { previous: host, ranges: [...new Set([networkOf(host), ...ranges].filter(Boolean))] };
}

// One GET /v1/health, sent as api-client.js sends requests (annotated with the address space),
// without a key and never repeated. Resolves to { answered, controller }: answered is false when
// nothing came back in time, true when something at the address answered, even to refuse.
export async function probe(host, { fetch, port = API_PORT, timeoutMs = PROBE_TIMEOUT_MS, timers = TIMERS, signal } = {}) {
  const controller = new AbortController();
  let late = false;
  const timer = timers.setTimeout(() => {
    late = true;
    controller.abort();
  }, timeoutMs);
  const stop = () => controller.abort();
  signal?.addEventListener("abort", stop);
  try {
    const response = await fetch(`http://${host}:${port}/v1/health`, {
      cache: "no-store",
      signal: controller.signal,
      targetAddressSpace: addressSpace(host),
    });
    const data = response.ok ? await response.json().catch(() => null) : null;
    const found = recognise(data);
    return { answered: true, controller: found ? { host, ...found } : null };
  } catch {
    return { answered: !late && !signal?.aborted, controller: null };
  } finally {
    timers.clearTimeout(timer);
    signal?.removeEventListener("abort", stop);
  }
}

// Chromium's Local Network Access permission ("local-network", split from "local-network-access");
// null where the browser has none to ask about.
export async function localNetworkPermission(permissions) {
  for (const name of ["local-network", "local-network-access"]) {
    try {
      return await permissions.query({ name });
    } catch {
      // Not a permission this browser knows.
    }
  }
  return null;
}

// Resolves once the person answered the browser's question, or on stop.
function answered(permission, timers, signal) {
  return new Promise((resolve) => {
    let timer = null;
    const check = () => {
      timers.clearTimeout(timer);
      if (permission.state !== "prompt" || signal.aborted) {
        permission.removeEventListener?.("change", check);
        signal.removeEventListener("abort", check);
        resolve();
      } else {
        timer = timers.setTimeout(check, PERMISSION_POLL_MS);
      }
    };
    permission.addEventListener?.("change", check);
    signal.addEventListener("abort", check);
    check();
  });
}

// Looks for DirectorLink. Resolves to { outcome, controllers }: outcome is "found", "none",
// "blocked" (the browser may not reach the local network) or "cancelled" (signal); controllers
// are [{ host, version }] in the order they were asked. onProgress gets { stage: "asking" } while
// the browser asks for the permission, { stage: "network" } while the routers are asked, then
// { stage: "range", range: "192.168.1" } for each network looked through. Once one is found, its
// network is finished and the search ends there.
export async function findControllers({
  previous = "",
  ranges = RANGES,
  port = API_PORT,
  fetch = (...args) => globalThis.fetch(...args),
  permissions = globalThis.navigator?.permissions,
  timers = TIMERS,
  signal,
  onProgress = () => {},
} = {}) {
  const plan = scanPlan(previous, ranges);
  const found = new Map();
  const tried = new Set();
  let asked = 0;
  const result = (outcome) => ({
    outcome,
    controllers: [...found.values()].sort((a, b) => a.order - b.order).map(({ host, version }) => ({ host, version })),
  });
  const ask = async (host, timeoutMs) => {
    const order = asked++;
    tried.add(host);
    const answer = await probe(host, { fetch, port, timeoutMs, timers, signal });
    if (answer.controller && !found.has(host)) found.set(host, { ...answer.controller, order });
    return answer;
  };

  // The address used before, and the routers.
  const first = [...new Set([plan.previous, ...plan.ranges.flatMap((range) => ROUTER_HOSTS.map((last) => `${range}.${last}`))].filter(Boolean))];

  // Chromium asks the person first, and every request waits for their answer: the first ones
  // are sent once, to be asked again when they can go out. One that ends by itself shows that
  // this browser asks nothing.
  const permission = permissions ? await localNetworkPermission(permissions) : null;
  if (permission?.state === "denied") return result("blocked");
  if (permission?.state === "prompt") {
    onProgress({ stage: "asking" });
    const wait = new AbortController();
    const stop = () => wait.abort();
    signal?.addEventListener("abort", stop);
    const waiting = first.map((host) => probe(host, { fetch, port, timeoutMs: PERMISSION_WAIT_MS, timers, signal: wait.signal }));
    const reached = new Promise((resolve) => waiting.forEach((item) => item.then((answer) => answer.answered && resolve())));
    await Promise.race([answered(permission, timers, wait.signal), reached, Promise.all(waiting)]);
    wait.abort();
    signal?.removeEventListener("abort", stop);
    if (signal?.aborted) return result("cancelled");
    if (permission.state === "denied") return result("blocked");
  }

  const started = timers.now();
  // A request is started only if it can end within the budget.
  const stopped = (timeoutMs) => signal?.aborted || timers.now() - started + timeoutMs > SCAN_BUDGET_MS;
  const all = async (hosts, timeoutMs, done = () => {}) => {
    let next = 0;
    const lane = async () => {
      while (next < hosts.length && !stopped(timeoutMs)) {
        const host = hosts[next++];
        done(host, await ask(host, timeoutMs));
      }
    };
    await Promise.all(Array.from({ length: Math.min(CONCURRENCY, hosts.length) }, lane));
  };

  // The networks that answer come first.
  onProgress({ stage: "network" });
  const live = new Set();
  await all(first, ROUTER_TIMEOUT_MS, (host, answer) => {
    if (answer.answered && networkOf(host)) live.add(networkOf(host));
  });

  const swept = new Set();
  const sweep = async (range) => {
    swept.add(range);
    onProgress({ stage: "range", range });
    const hosts = [];
    for (let last = 1; last <= 254; last++) {
      if (!tried.has(`${range}.${last}`)) hosts.push(`${range}.${last}`);
    }
    await all(hosts, PROBE_TIMEOUT_MS);
  };
  const order = [...plan.ranges.filter((range) => live.has(range)), ...plan.ranges.filter((range) => !live.has(range))];
  for (const range of order) {
    if (found.size || stopped(PROBE_TIMEOUT_MS)) break;
    await sweep(range);
  }
  // Found by the first requests: finish its network before offering it.
  for (const range of new Set([...found.values()].map((item) => networkOf(item.host)))) {
    if (range && !swept.has(range) && !stopped(PROBE_TIMEOUT_MS)) await sweep(range);
  }

  if (signal?.aborted) return result("cancelled");
  // Refused while the requests were already failing (the browser may tell them first).
  if (!found.size && permission?.state === "denied") return result("blocked");
  return result(found.size ? "found" : "none");
}
