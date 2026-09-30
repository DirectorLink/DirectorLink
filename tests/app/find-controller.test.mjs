// Find my controller on the pairing screen (app/js/find.js, app/js/views/find.js): where it looks
// and in which order, how many requests at a time, how long it waits for each and for all of them,
// Cancel, what it sends (only GET /v1/health), the browser's question about the local network,
// one, several or no controllers found, and the browsers it is offered in.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

// Just enough of a browser for the pairing screen's modules.
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.listeners = {};
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener(type, listener) {
    this.listeners[type] = listener;
  }
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
  // Every element below this one (itself included) that `match` accepts.
  all(match) {
    const found = match(this) ? [this] : [];
    for (const child of this.children) if (child instanceof FakeElement) found.push(...child.all(match));
    return found;
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: {},
  activeElement: null,
  addEventListener() {},
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};

// Browsers as they present themselves.
const CHROME_WINDOWS = {
  userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
  userAgentData: { brands: [{ brand: "Chromium", version: "141" }, { brand: "Google Chrome", version: "141" }, { brand: "Not?A_Brand", version: "8" }] },
  maxTouchPoints: 0,
};
const EDGE = {
  userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
  userAgentData: { brands: [{ brand: "Microsoft Edge", version: "141" }, { brand: "Not?A_Brand", version: "8" }, { brand: "Chromium", version: "141" }] },
  maxTouchPoints: 0,
};
const CHROME_ANDROID = {
  userAgent: "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36",
  userAgentData: { brands: [{ brand: "Chromium", version: "141" }, { brand: "Google Chrome", version: "141" }], mobile: true },
  maxTouchPoints: 5,
};
// Chromium before client hints, or where the page is not a secure context.
const OLD_CHROME = { userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4324.96 Safari/537.36", maxTouchPoints: 0 };
const IPHONE_SAFARI = {
  userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1",
  maxTouchPoints: 5,
};
const IPHONE_CHROME = {
  userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0.7390.41 Mobile/15E148 Safari/604.1",
  maxTouchPoints: 5,
};
// iPadOS asks for the desktop site as a Mac, but with a touch screen.
const IPAD = { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15", maxTouchPoints: 5 };
const SAFARI_MAC = { ...IPAD, maxTouchPoints: 0 };
// An app's own browser on iPhone that names Chrome: still WebKit.
const IPHONE_IN_APP = {
  userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile/15E148 Safari/604.1",
  maxTouchPoints: 5,
};
const FIREFOX = { userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:143.0) Gecko/20100101 Firefox/143.0", maxTouchPoints: 0 };

Object.defineProperty(globalThis, "navigator", { value: CHROME_WINDOWS, configurable: true, writable: true });

const find = await import("../../app/js/find.js");
const { CONCURRENCY, PROBE_TIMEOUT_MS, RANGES, ROUTER_TIMEOUT_MS, SCAN_BUDGET_MS, findControllers, findSupported, networkOf, recognise, scanPlan, scanSettings } = find;
const { notify, state, ui } = await import("../../app/js/state.js");
const { cancelFind, findController, startFind } = await import("../../app/js/views/find.js");

// Time that moves only when every request and timer waiting for the present moment has run.
function virtualClock() {
  let now = 0;
  let sequence = 0;
  let timers = [];
  return {
    now: () => now,
    setTimeout(callback, ms) {
      const timer = { at: now + Math.max(0, ms || 0), sequence: sequence++, callback };
      timers.push(timer);
      return timer;
    },
    clearTimeout(timer) {
      timers = timers.filter((item) => item !== timer);
    },
    // Runs time forward until `promise` settles; returns what it resolved to.
    async run(promise) {
      let outcome = null;
      promise.then(
        (value) => (outcome = { value }),
        (error) => (outcome = { error })
      );
      for (;;) {
        await new Promise((resolve) => setImmediate(resolve));
        if (outcome) {
          if (outcome.error) throw outcome.error;
          return outcome.value;
        }
        if (!timers.length) throw new Error("the search waits for nothing");
        timers.sort((a, b) => a.at - b.at || a.sequence - b.sequence);
        const next = timers.shift();
        now = next.at;
        next.callback();
      }
    },
  };
}

const answer = (body, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
const DIRECTORLINK = (version = "1.3.0") => ({ kind: "answer", body: { product: "directorlink", status: "ok", version, api_version: "1", detail: null } });
// A driver before 1.3.0: its health answer has no product.
const OLDER_DIRECTORLINK = (version = "1.2.0") => ({ kind: "answer", body: { status: "ok", version, api_version: "1", detail: null } });

// The home network: host -> "refuse" (something is there, the port is closed), or
// { kind: "answer", body, status, after }. Every other address never answers.
// While the browser asks about the local network (hold), requests wait for the answer (release);
// once refused, every request fails.
function homeNetwork(clock, hosts = {}) {
  const calls = [];
  let inFlight = 0;
  let maxInFlight = 0;
  let held = null;
  let refused = false; // the browser was refused the local network: every request fails
  const fetch = (url, init) => {
    const call = { url, init, host: new URL(url).hostname, at: clock.now(), endedAt: null, aborted: false };
    calls.push(call);
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    return new Promise((resolve, reject) => {
      const end = (settle) => {
        if (call.endedAt !== null) return;
        call.endedAt = clock.now();
        inFlight -= 1;
        settle();
      };
      init.signal.addEventListener("abort", () => {
        call.aborted = true;
        end(() => reject(new DOMException("The operation was aborted.", "AbortError")));
      });
      const start = (allowed = true) => {
        if (!allowed) return clock.setTimeout(() => end(() => reject(new TypeError("Failed to fetch"))), 5);
        const behaviour = hosts[call.host];
        if (!behaviour) return;
        const after = behaviour === "refuse" ? 5 : (behaviour.after ?? 20);
        clock.setTimeout(
          () => end(() => (behaviour === "refuse" ? reject(new TypeError("Failed to fetch")) : resolve(answer(behaviour.body, behaviour.status)))),
          after
        );
      };
      if (held) held.push(start);
      else start(!refused);
    });
  };
  return {
    fetch,
    calls,
    hold() {
      held = [];
    },
    release(allowed) {
      const waiting = held || [];
      held = null;
      refused = !allowed;
      for (const start of waiting) start(allowed);
    },
    get inFlight() {
      return inFlight;
    },
    get maxInFlight() {
      return maxInFlight;
    },
    asked: (predicate) => calls.filter((call) => predicate(call.host)).map((call) => call.host),
  };
}

// Runs a search on the virtual clock; `options(clock, network)` adds to what findControllers is
// given. Returns the result, the network, the progress and when it ended.
async function run(hosts = {}, options = () => ({})) {
  const clock = virtualClock();
  const network = homeNetwork(clock, hosts);
  const progress = [];
  const result = await clock.run(
    findControllers({ fetch: network.fetch, permissions: null, timers: clock, onProgress: (item) => progress.push({ ...item, at: clock.now() }), ...options(clock, network) })
  );
  return { result, network, progress, endedAt: clock.now() };
}

const inNetwork = (range) => (host) => networkOf(host) === range;
const every = (range) => Array.from({ length: 254 }, (_, index) => `${range}.${index + 1}`);

test("where it looks: the address used before, its network, then the networks homes use most", () => {
  assert.deepEqual(RANGES.slice(0, 3), ["192.168.1", "192.168.0", "10.0.0"]);
  for (const range of ["10.0.1", "192.168.2", "192.168.10", "192.168.50", "10.1.1", "172.16.0"]) assert.ok(RANGES.includes(range), range);
  assert.deepEqual(scanPlan(""), { previous: null, ranges: RANGES });
  assert.deepEqual(scanPlan("10.0.0.23"), { previous: "10.0.0.23", ranges: ["10.0.0", "192.168.1", "192.168.0", ...RANGES.slice(3)] });
  assert.deepEqual(scanPlan("192.168.7.9").ranges, ["192.168.7", ...RANGES]);
  assert.deepEqual(scanPlan("director.local"), { previous: "director.local", ranges: RANGES });
  assert.equal(networkOf("192.168.1.201"), "192.168.1");
  for (const host of ["director.local", "192.168.1", "192.168.1.300", "", null]) assert.equal(networkOf(host), null, String(host));
});

test("asks the address used before first, then the routers, then each network in order", async () => {
  const { network, progress } = await run({}, () => ({ previous: "192.168.7.9" }));
  assert.equal(network.calls[0].host, "192.168.7.9");
  assert.deepEqual(network.calls.slice(1, 4).map((call) => call.host), ["192.168.7.1", "192.168.7.254", "192.168.7.138"]);
  const ranges = progress.filter((item) => item.stage === "range").map((item) => item.range);
  assert.ok(ranges.length >= 5, `looked through ${ranges.length} networks`);
  assert.deepEqual(ranges, ["192.168.7", ...RANGES].slice(0, ranges.length));
  // Each network is looked through from .1 to .254, and no address twice.
  assert.deepEqual(network.asked(inNetwork("192.168.1")).sort(), every("192.168.1").sort());
  assert.equal(new Set(network.calls.map((call) => call.host)).size, network.calls.length);
});

test("a network whose router answers is looked through first (Bezeq: 10.0.0.138)", async () => {
  const { result, network, progress } = await run({ "10.0.0.138": "refuse", "10.0.0.37": DIRECTORLINK() });
  assert.deepEqual(result, { outcome: "found", controllers: [{ host: "10.0.0.37", version: "1.3.0" }] });
  assert.deepEqual(progress.map((item) => item.stage + (item.range ? ` ${item.range}` : "")), ["network", "range 10.0.0"]);
  // Of the other networks, only the routers were asked.
  const others = network.asked((host) => networkOf(host) !== "10.0.0");
  assert.equal(others.length, (RANGES.length - 1) * 3);
});

test("found: that network is finished, then the search ends and offers it", async () => {
  const { result, network, progress, endedAt } = await run({ "192.168.1.201": DIRECTORLINK("1.3.0") });
  assert.equal(result.outcome, "found");
  assert.deepEqual(result.controllers, [{ host: "192.168.1.201", version: "1.3.0" }]);
  assert.deepEqual(network.asked(inNetwork("192.168.1")).sort(), every("192.168.1").sort(), "the whole network was asked");
  assert.deepEqual(network.asked(inNetwork("192.168.0")).sort(), ["192.168.0.1", "192.168.0.138", "192.168.0.254"], "no other network was looked through");
  assert.deepEqual(progress.filter((item) => item.stage === "range").map((item) => item.range), ["192.168.1"]);
  assert.ok(endedAt <= ROUTER_TIMEOUT_MS + Math.ceil(254 / CONCURRENCY) * PROBE_TIMEOUT_MS, `ended after ${endedAt} ms`);
});

test("found at the address used before: its network is still finished before it is offered", async () => {
  const { result, network } = await run({ "10.0.0.23": DIRECTORLINK(), "10.0.0.60": OLDER_DIRECTORLINK("1.2.0") }, () => ({ previous: "10.0.0.23" }));
  assert.equal(network.calls[0].host, "10.0.0.23");
  assert.deepEqual(result.controllers, [
    { host: "10.0.0.23", version: "1.3.0" },
    { host: "10.0.0.60", version: "1.2.0" },
  ]);
  assert.equal(network.asked(inNetwork("192.168.1")).length, 3, "only the routers of other networks");
});

test("several found are all offered, with their versions; other devices are not", async () => {
  const { result } = await run({
    "192.168.1.1": "refuse",
    "192.168.1.20": DIRECTORLINK("1.3.0"),
    "192.168.1.201": OLDER_DIRECTORLINK("1.1.1"),
    "192.168.1.30": { kind: "answer", body: { status: "ok" } },
    "192.168.1.31": { kind: "answer", body: { product: "something-else", status: "ok", version: "2", api_version: "1", detail: null } },
    "192.168.1.32": { kind: "answer", body: null, status: 404 },
    "192.168.1.33": { kind: "answer", body: "<html>" },
  });
  assert.deepEqual(result, {
    outcome: "found",
    controllers: [
      { host: "192.168.1.20", version: "1.3.0" },
      { host: "192.168.1.201", version: "1.1.1" },
    ],
  });
});

test("recognises DirectorLink by its health answer", () => {
  assert.deepEqual(recognise({ product: "directorlink", status: "starting", version: "1.3.0", api_version: "1", detail: null }), { version: "1.3.0" });
  assert.deepEqual(recognise({ status: "error", version: "0.9.2", api_version: "1", detail: "discovery failed" }), { version: "0.9.2" });
  for (const other of [null, "ok", {}, { status: "ok" }, { status: "up", version: "1", api_version: "1", detail: null }, { product: "router", status: "ok", version: "1", api_version: "1", detail: null }]) {
    assert.equal(recognise(other), null, JSON.stringify(other));
  }
});

test("at most 64 requests at a time, and each sends nothing but GET /v1/health", async () => {
  const { network } = await run({ "192.168.1.77": DIRECTORLINK() }, () => ({ previous: "192.168.1.9" }));
  assert.equal(CONCURRENCY, 64);
  assert.equal(network.maxInFlight, CONCURRENCY);
  assert.equal(network.inFlight, 0, "nothing is left waiting");
  for (const call of network.calls) {
    assert.match(call.url, /^http:\/\/\d+\.\d+\.\d+\.\d+:41999\/v1\/health$/);
    assert.deepEqual(Object.keys(call.init).sort(), ["cache", "signal", "targetAddressSpace"], "no method, headers or body: a plain GET");
    assert.equal(call.init.cache, "no-store");
    assert.equal(call.init.targetAddressSpace, "local");
  }
});

test("a silent address is given up after 1.2 s (a router after 2 s)", async () => {
  const { network } = await run({ "192.168.1.77": DIRECTORLINK() });
  assert.equal(PROBE_TIMEOUT_MS, 1200);
  const silent = network.calls.filter((call) => call.aborted);
  assert.ok(silent.length > 250);
  for (const call of silent) {
    const router = /\.(1|254|138)$/.test(call.host);
    assert.equal(call.endedAt - call.at, router ? ROUTER_TIMEOUT_MS : PROBE_TIMEOUT_MS, call.host);
  }
});

test("nothing found: the whole search ends within 30 seconds, having looked through the common networks", async () => {
  const { result, network, endedAt } = await run({});
  assert.deepEqual(result, { outcome: "none", controllers: [] });
  assert.equal(SCAN_BUDGET_MS, 30000);
  assert.ok(endedAt <= SCAN_BUDGET_MS, `ended after ${endedAt} ms`);
  for (const range of ["192.168.1", "192.168.0", "10.0.0", "10.0.1", "192.168.2"]) {
    assert.equal(network.asked(inNetwork(range)).length, 254, range);
  }
  assert.equal(network.inFlight, 0);
});

test("Cancel stops the search at once: what was asked is dropped, nothing more is sent", async () => {
  const cancel = new AbortController();
  const { result, network, endedAt } = await run({}, (clock) => {
    clock.setTimeout(() => cancel.abort(), 3000);
    return { signal: cancel.signal };
  });
  assert.equal(result.outcome, "cancelled");
  assert.equal(endedAt, 3000);
  assert.equal(network.inFlight, 0);
  assert.ok(network.calls.every((call) => call.at <= 3000));
  assert.ok(network.calls.filter((call) => call.at === 3000 && !call.aborted).length === 0);
});

// The Local Network Access permission, as Chromium reports it. While it is asked, the network
// holds every request; the answer lets them go, or fails them.
function permission(state, known = ["local-network"]) {
  const status = new EventTarget();
  status.state = state;
  return {
    permissions: {
      query: async ({ name }) => {
        if (!known.includes(name)) throw new TypeError(`${name} is not a valid permission name`);
        return status;
      },
    },
    // requestsFirst: the waiting requests hear the answer before the permission says it.
    ask(clock, network, at, value, { requestsFirst = false } = {}) {
      network.hold();
      clock.setTimeout(() => {
        if (requestsFirst) network.release(value === "granted");
        clock.setTimeout(() => {
          status.state = value;
          status.dispatchEvent(new Event("change"));
          network.release(value === "granted");
        }, requestsFirst ? 50 : 0);
      }, at);
    },
  };
}

// The first requests: the routers of every network, 3 each.
const FIRST = RANGES.length * 3;

test("while the browser asks about the local network, the first requests wait, once each; the search starts once allowed", async () => {
  const asking = permission("prompt", ["local-network-access"]);
  const { result, network, progress } = await run({ "192.168.1.201": DIRECTORLINK() }, (clock, home) => {
    asking.ask(clock, home, 8000, "granted");
    return { permissions: asking.permissions };
  });
  assert.equal(progress[0].stage, "asking");
  assert.equal(progress[1].at, 8000, "the search starts when allowed");
  const waited = network.calls.filter((call) => call.at < 8000);
  assert.equal(waited.length, FIRST);
  assert.equal(new Set(waited.map((call) => call.host)).size, FIRST);
  assert.ok(waited.every((call) => call.aborted && call.endedAt === 8000), "dropped once answered, and asked again");
  assert.equal(result.outcome, "found");
});

test("a browser that says it would ask, but asks nothing, is not waited for", async () => {
  const quiet = permission("prompt");
  const { result, progress } = await run({ "192.168.1.1": "refuse", "192.168.1.201": DIRECTORLINK() }, () => ({ permissions: quiet.permissions }));
  assert.deepEqual(progress.slice(0, 2).map((item) => item.stage), ["asking", "network"]);
  assert.ok(progress[1].at < 100, `waited ${progress[1].at} ms`);
  assert.equal(result.outcome, "found");
});

test("the browser may not reach the local network: blocked, with nothing sent but the first requests", async () => {
  const denied = permission("denied");
  const before = await run({ "192.168.1.201": DIRECTORLINK() }, () => ({ permissions: denied.permissions }));
  assert.deepEqual(before.result, { outcome: "blocked", controllers: [] });
  assert.equal(before.network.calls.length, 0);

  const asking = permission("prompt");
  const refused = await run({ "192.168.1.201": DIRECTORLINK() }, (clock, home) => {
    asking.ask(clock, home, 4000, "denied");
    return { permissions: asking.permissions };
  });
  assert.equal(refused.result.outcome, "blocked");
  assert.equal(refused.network.calls.length, FIRST);

  const late = permission("prompt");
  const told = await run({ "192.168.1.201": DIRECTORLINK() }, (clock, home) => {
    late.ask(clock, home, 4000, "denied", { requestsFirst: true });
    return { permissions: late.permissions };
  });
  assert.equal(told.result.outcome, "blocked", "not \"none\": the browser refused");

  const granted = permission("granted");
  assert.equal((await run({ "192.168.1.201": DIRECTORLINK() }, () => ({ permissions: granted.permissions }))).result.outcome, "found");
});

test("offered in Chromium on computers and Android, never on iPhone or iPad, nor in Firefox or Safari", () => {
  for (const [name, browser] of Object.entries({ CHROME_WINDOWS, EDGE, CHROME_ANDROID, OLD_CHROME })) assert.equal(findSupported(browser), true, name);
  for (const [name, browser] of Object.entries({ IPHONE_SAFARI, IPHONE_CHROME, IPHONE_IN_APP, IPAD, SAFARI_MAC, FIREFOX })) assert.equal(findSupported(browser), false, name);
});

// The pairing screen's part, as views/find.js draws it.
const text = (element) => (element ? element.textContent : "");
const button = (part) => part.all((element) => element.dataset.key === "find-controller")[0];

// Runs the screen's search against `hosts` (every other address refuses, so it ends at once).
async function searchOnScreen(hosts, { typed } = {}) {
  const calls = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    const behaviour = hosts[new URL(url).hostname];
    if (!behaviour) throw new TypeError("Failed to fetch");
    return answer(behaviour.body);
  };
  try {
    const started = startFind();
    if (typed !== undefined) ui.drafts.host = typed;
    await started;
  } finally {
    globalThis.fetch = realFetch;
  }
  return calls;
}

test("the screen: one found goes into the address field; the code is still typed by the person", async () => {
  scanSettings.ranges = ["10.9.8"];
  state.host = "";
  ui.drafts = {};
  ui.find = null;
  assert.equal(text(button(findController())), "Find my controller");
  const calls = await searchOnScreen({ "10.9.8.44": DIRECTORLINK("1.3.0") });
  assert.equal(ui.drafts.host, "10.9.8.44");
  assert.equal(ui.drafts.pairingCode, undefined);
  assert.equal(state.apiKey, "", "nothing was paired");
  assert.equal(text(findController().all((element) => element.attributes.id === "find-result")[0]), "Found DirectorLink 1.3.0 at 10.9.8.44. Now enter the pairing code.");
  assert.ok(calls.every((call) => call.url.endsWith("/v1/health") && !call.init.headers && !call.init.body));
});

test("the screen: once paired, what was found is forgotten", async () => {
  ui.drafts = {};
  ui.find = null;
  await searchOnScreen({ "10.9.8.44": DIRECTORLINK() });
  assert.equal(ui.find.stage, "found");
  state.apiKey = "a key"; // Connect with the code worked
  notify();
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(ui.find, null);
  state.apiKey = "";
});

test("the screen: several are listed to pick from; picking fills the field", async () => {
  ui.drafts = {};
  ui.find = null;
  await searchOnScreen({ "10.9.8.44": DIRECTORLINK("1.3.0"), "10.9.8.45": OLDER_DIRECTORLINK("1.2.0") });
  assert.equal(ui.drafts.host, undefined, "nothing is filled in before a pick");
  const part = findController();
  assert.match(text(part), /Found 2 controllers\. Choose yours:/);
  const choices = part.all((element) => element.dataset.key?.startsWith("find-use-"));
  assert.deepEqual(choices.map(text), ["10.9.8.44DirectorLink 1.3.0", "10.9.8.45DirectorLink 1.2.0"]);
  choices[1].listeners.click();
  assert.equal(ui.drafts.host, "10.9.8.45");
  const chosen = findController().all((element) => element.dataset.key?.startsWith("find-use-"));
  assert.deepEqual(chosen.map((element) => element.attributes["aria-pressed"]), ["false", "true"]);
});

test("the screen: the address used before, found again, is the one marked in the list", async () => {
  state.host = "10.9.8.45"; // what the field shows until something is typed
  ui.drafts = {};
  ui.find = null;
  const calls = await searchOnScreen({ "10.9.8.44": DIRECTORLINK("1.3.0"), "10.9.8.45": DIRECTORLINK("1.3.0") });
  assert.equal(new URL(calls[0].url).hostname, "10.9.8.45", "asked first");
  const choices = findController().all((element) => element.dataset.key?.startsWith("find-use-"));
  assert.deepEqual(choices.map((element) => [element.dataset.key, element.attributes["aria-pressed"]]), [
    ["find-use-10.9.8.45", "true"],
    ["find-use-10.9.8.44", "false"],
  ]);
  state.host = "";
});

test("the screen: an address typed while it looked is not replaced", async () => {
  ui.drafts = {};
  ui.find = null;
  await searchOnScreen({ "10.9.8.44": DIRECTORLINK() }, { typed: "192.168.1.201" });
  assert.equal(ui.drafts.host, "192.168.1.201");
  assert.match(text(findController()), /Found 1 controller\. Choose yours:/);
});

test("the screen: none found says to type the address; Cancel goes back to the button", async () => {
  ui.drafts = {};
  ui.find = null;
  await searchOnScreen({});
  assert.equal(ui.find.stage, "none");
  assert.match(text(findController()), /No controller found on this network\. Type the controller’s address\. Your installer can tell you, or find it in Composer\./);

  ui.find = { stage: "range", range: "192.168.1" };
  const looking = findController();
  assert.equal(text(button(looking)), "Cancel");
  assert.match(text(looking), /Looking in 192\.168\.1\.x…/);
  cancelFind();
  assert.equal(ui.find, null);
  assert.equal(text(button(findController())), "Find my controller");
});

test("the screen: no Find my controller on iPhone and iPad", () => {
  ui.find = null;
  for (const browser of [IPHONE_SAFARI, IPHONE_CHROME, IPHONE_IN_APP, IPAD]) {
    globalThis.navigator = browser;
    assert.equal(findController(), null, browser.userAgent);
  }
  globalThis.navigator = CHROME_ANDROID;
  assert.ok(findController());
  globalThis.navigator = CHROME_WINDOWS;
});
