// Shades in the running app (app/js/controls.js with session.js), against a fake controller under
// fake time: what the app reads while shades move, and what the rows show. The few browser globals
// these modules use are faked here, and fetch answers only for the fake controller.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

const HOST = "controller.invalid";
const KEY = "ak_test";
const stored = new Map();

globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
// What the app does when the page goes into the background or comes back (showPage).
const pageListeners = [];
globalThis.document = {
  hidden: false,
  addEventListener: (type, listener) => type === "visibilitychange" && pageListeners.push(listener),
  documentElement: {},
  querySelector: () => null,
};
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Node", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
    clear: () => stored.clear(),
  },
  configurable: true,
});
mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-01T08:00:00Z") });
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 16);

// The fake controller: a DirectorLink that cannot seal (so requests carry the key), with these
// blinds. `patch` may answer instead of the default (202 with the blind as it was). `rtt`: how long
// a request takes there and back; the controller handles it halfway. `revokes`: DELETE
// /v1/api-keys/current revokes the key, and every request after it is answered 401. `stopLag`:
// how long after answering a Stop the shade reports that it stopped (the proxy hears it from the
// actuator), where it was. `down`: nothing answers. `silent`: requests get there, and no answer
// comes back (they end when the app gives up on them). `slow`: how much longer the answers to these
// paths take. Light 22 is a lamp that never reports it is on.
const controller = { blinds: [], devices: [], calls: [], patch: null, rtt: 0, revokes: false, revoked: false, stopLag: null, down: false, silent: false, slow: {} };

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

const later = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST || controller.down) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  const keyed = Boolean(init.headers?.Authorization);
  controller.calls.push({ at: Date.now(), method, path, keyed });
  if (controller.silent) {
    return new Promise((_resolve, reject) => {
      const stop = () => reject(new DOMException("The operation was aborted.", "AbortError"));
      if (init.signal?.aborted) stop();
      init.signal?.addEventListener("abort", stop);
    });
  }
  if (controller.rtt) await later(controller.rtt / 2);
  const response = handle(method, path, keyed, init.body);
  if (controller.rtt) await later(controller.rtt / 2);
  if (controller.slow[path]) await later(controller.slow[path]);
  return response;
};

// What the controller answers, when the request gets there.
function handle(method, path, keyed, body) {
  if (path === "/v1/sealed") return answer(404, { status: 404, code: "NOT_FOUND" });
  if (!keyed || controller.revoked) return answer(401, { status: 401, code: "UNAUTHORIZED", detail: "Missing or invalid API key" });
  const copy = (blind) => ({ ...blind });
  if (path === "/v1/blinds" && method === "GET") return answer(200, { items: controller.blinds.map(copy) });
  const one = path.match(/^\/v1\/blinds\/(\d+)(\/stop)?$/);
  if (one) {
    const blind = controller.blinds.find((item) => item.id === Number(one[1]));
    if (!blind) return answer(404, { status: 404, code: "NOT_FOUND", detail: "Blind not found" });
    const custom = method === "PATCH" && controller.patch?.(blind, JSON.parse(body));
    if (custom) return answer(custom.status, custom.body);
    if (one[2] && Number.isFinite(controller.stopLag)) {
      // As the proxy reports it: stopped, with Target Level where the shade is.
      setTimeout(() => {
        const stopped = (item) => (item.id === blind.id ? { ...item, moving: false, direction: null, target_position: item.position } : item);
        controller.blinds = controller.blinds.map(stopped);
      }, controller.stopLag);
    }
    return answer(method === "GET" ? 200 : 202, copy(blind));
  }
  if (path === "/v1/devices") return answer(200, { items: controller.devices });
  if (path === "/v1/api-keys/current" && method === "DELETE" && controller.revokes) {
    controller.revoked = true;
    return new Response(null, { status: 204 });
  }
  if (path === "/v1/api-keys/current") return answer(200, { id: "0a1b2c3d", role: "admin" });
  if (path === "/v1/rooms/order" && method === "PUT") {
    // As DirectorLink 1.0.0 answered it in a sealed request.
    return answer(400, { status: 400, code: "BAD_REQUEST", detail: "Remote requests are GET, POST, PATCH or DELETE on /v1/..." });
  }
  if (path === "/v1/lights/22") return answer(method === "GET" ? 200 : 202, { id: 22, name: "Lamp", on: false, dimmable: false, brightness: null });
  if (method === "GET") return answer(200, { items: [] });
  return answer(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
}

const { state, notify } = await import("../../app/js/state.js");
const controls = await import("../../app/js/controls.js");
const session = await import("../../app/js/session.js");
const { blindStateLabel } = await import("../../app/js/model.js");
const { MOVE_POLL_MS, shadeView } = await import("../../app/js/shades.js");
const { copyHouse, loadScenes } = await import("../../app/js/scenes.js");
const { roomOrderErrorText } = await import("../../app/js/views/settings.js");
const { setLanguage, t } = await import("../../app/js/i18n.js");
const { ApiError } = await import("../../app/api-client.js");
// As app.js does: the scenes are read once connected, and with the rooms.
session.whenConnected(loadScenes);

// Lets fetch answers, promise chains and response bodies settle.
async function settle() {
  for (let index = 0; index < 8; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

// Moves the fake clock on by `ms`, in steps, running everything that comes due.
async function advance(ms, step = 50) {
  for (let done = 0; done < ms; done += step) {
    mock.timers.tick(Math.min(step, ms - done));
    await settle();
  }
  await settle();
}

const shade = (fields = {}) => ({
  id: 52,
  name: "Terrace Shade",
  room: { id: 11, name: "Living Room" },
  position: 35,
  position_reported: true,
  capabilities: { position: true, stop: true },
  moving: false,
  direction: null,
  target_position: 35,
  ...fields,
});

// Connected to the fake controller with these blinds, as after loading the home.
async function connect(blinds) {
  session.forgetKey();
  // Requests still on their way get their answers first.
  await advance(100 + controller.rtt);
  Object.assign(controller, { calls: [], patch: null, rtt: 0, revokes: false, revoked: false, stopLag: null, down: false, silent: false, slow: {} });
  controller.blinds = blinds.map((blind) => ({ ...blind }));
  document.hidden = false;
  state.host = HOST;
  state.apiKey = KEY;
  state.role = "admin";
  state.status = "connected";
  state.loaded = true;
  state.notice = null;
  state.blinds = blinds.map((blind) => ({ ...blind }));
  notify();
  await advance(100);
}

const blindReads = (since) => controller.calls.filter((call) => call.at >= since && call.method === "GET" && call.path === "/v1/blinds").length;

// The page goes into the background, or comes back into view.
function showPage(visible) {
  document.hidden = !visible;
  for (const listener of pageListeners) listener();
}

// What the row of blind `id` says, and where its slider is.
function shown(id) {
  const blind = state.blinds.find((item) => item.id === id);
  const move = controls.blindMove(id);
  return `${blindStateLabel(blind, move)} | ${shadeView(blind, move).slider}`;
}

test("a shade that left the list while it moved is not read for any longer", async () => {
  await connect([shade({ moving: null }), shade({ id: 60, position: 0, target_position: 0, moving: null })]);
  controls.setBlind(state.blinds[0], 53);
  await advance(3000);
  // Removed in Composer (Refresh Project), or no longer supported.
  controller.blinds = controller.blinds.filter((blind) => blind.id !== 52);
  const from = Date.now();
  await advance(60000, 200);
  assert.ok(blindReads(from) <= 2, `${blindReads(from)} reads in the minute after`);
  assert.equal(controls.blindMove(52), null);
});

test("a shade that keeps reporting it moves is read every 2 s for two minutes at most", async () => {
  await connect([shade({ moving: true, direction: "opening", target_position: 80 })]);
  const from = Date.now();
  await advance(10 * 60 * 1000, 500);
  const reads = blindReads(from);
  assert.ok(reads >= 55 && reads <= 62, `${reads} reads in 10 minutes`);
  assert.equal(blindReads(from + 3 * 60 * 1000), 0, "none after three minutes");
  assert.equal(shown(52), "Opening… to 80% | 80", "it still shows what the controller says");
});

// Seen moving, then out of sight for minutes (the page in the background, or the controller out of
// reach): the shade stopped meanwhile, and someone moves it again from a keypad as the app looks
// again. That is a new move, read every 2 s, not the old one past its two minutes.
test("a shade moving again after a while out of sight is read every 2 s", async () => {
  await connect([shade({ moving: true, direction: "opening", target_position: 100 })]);
  session.startPolling();
  await advance(4000);
  showPage(false);
  await advance(5 * 60 * 1000, 1000);
  controller.blinds = [shade({ moving: true, direction: "closing", target_position: 0 })];
  let from = Date.now();
  showPage(true);
  await advance(20000, 250);
  assert.ok(blindReads(from) >= 8, `${blindReads(from)} reads in the 20 s after the page came back`);

  controller.blinds = [shade({ moving: true, direction: "opening", target_position: 100 })];
  await advance(4000);
  const failures = mock.method(console, "warn", () => {});
  controller.down = true;
  await advance(3 * 60 * 1000, 1000);
  assert.equal(state.status, "unreachable");
  controller.blinds = [shade({ moving: true, direction: "closing", target_position: 0 })];
  controller.down = false;
  from = Date.now();
  await advance(20000, 250);
  session.stopPolling();
  failures.mock.restore();
  assert.equal(state.status, "connected");
  assert.ok(blindReads(from) >= 8, `${blindReads(from)} reads in the 20 s after the controller came back`);
});

test("forgetting the key while a shade moves sends nothing without it", async () => {
  await connect([shade({ moving: null })]);
  controls.setBlind(state.blinds[0], 53);
  await advance(3000);
  await session.revokeAndForget();
  await advance(5000);
  const unkeyed = controller.calls.filter((call) => !call.keyed && call.path !== "/v1/sealed").map((call) => `${call.method} ${call.path}`);
  assert.deepEqual(unkeyed, []);
  assert.equal(state.notice, null, "no \"key no longer works\"");
  assert.equal(controls.blindMove(52), null);
});

// Forget key revokes the key on the controller, which answers 401 from then on. Pressed while the app
// reads (the 2 s reads of a moving shade, the refresh every 10 s), wherever the reads fall and
// however long the answers take: nothing is sent after the DELETE, and nothing says the key no
// longer works.
test("forgetting the key while a shade moves never says it no longer works", async () => {
  const said = [];
  const sent = [];
  for (const [rtt, every] of [[150, 50], [400, 100], [3000, 1000]]) {
    for (let phase = 0; phase < MOVE_POLL_MS + rtt; phase += every) {
      await connect([shade({ moving: true, direction: "opening", target_position: 100 })]);
      Object.assign(controller, { rtt, revokes: true });
      session.startPolling();
      await advance(1000 + phase, 10);
      const forgotten = session.revokeAndForget();
      await advance(2 * rtt + 3000, 10);
      await forgotten;
      assert.equal(state.apiKey, "");
      if (state.notice) said.push(`${rtt} ms, phase ${phase}: ${state.notice.text}`);
      const after = controller.calls.slice(controller.calls.findIndex((call) => call.method === "DELETE") + 1);
      if (after.length) sent.push(`${rtt} ms, phase ${phase}: ${after.map((call) => `${call.method} ${call.path}`).join(", ")}`);
    }
  }
  session.stopPolling();
  assert.deepEqual(said, []);
  assert.deepEqual(sent, [], "nothing is read once the key is being revoked");
  assert.equal(controls.blindMove(52), null);
});

const reads = (path) => controller.calls.filter((call) => call.method === "GET" && call.path === path).length;

// Moves the fake clock on until `done()`, for `ms` at most.
async function until(done, ms) {
  for (let waited = 0; !done() && waited < ms; waited += 10) await advance(10, 10);
  assert.ok(done(), `not within ${ms} ms`);
}

// Forget access key in Settings: what it shows once the key is forgotten (views/settings.js), and
// what the app should still show a while later. Pair again ends the same way, with its own text.
function forgetInSettings() {
  return session.revokeAndForget().then(() => {
    state.notice = { kind: "info", text: t("settings.controller.forgotten") };
    notify();
  });
}
const FORGOTTEN = "setup: The access key was removed from this device.";
const ended = () => `${state.status}${state.apiKey ? " with a key" : ""}: ${state.notice?.text}`;

// What was sent after the DELETE of Forget key.
function sentAfterDelete() {
  const index = controller.calls.findIndex((call) => call.method === "DELETE");
  if (index < 0) return ["(no DELETE)"];
  return controller.calls.slice(index + 1).map((call) => `${call.method} ${call.path}${call.keyed ? "" : " (no key)"}`);
}

// Every sixth refresh also reads the rooms, the cameras and the devices, and runs what follows a
// connect (the scenes). Forget key pressed while such a refresh is on its way, its answers coming
// before the DELETE's or after it: they change nothing, and nothing more is sent (1.1.1 went on to
// read the rooms and the scenes with the key being revoked, or with none, and could end connected).
test("forgetting the key during the refresh that also reads the rooms sends nothing more", async () => {
  const problems = [];
  for (const slow of [0, 1500]) {
    for (const wait of [10, 250, 450]) {
      await connect([shade()]);
      Object.assign(controller, { rtt: 400, revokes: true, slow: { "/v1/lights": slow } });
      session.startPolling();
      // Once a refresh has read the rooms, the sixth refresh after it reads them again.
      await until(() => reads("/v1/rooms") > 0, 100000);
      const refreshes = reads("/v1/lights");
      await until(() => reads("/v1/lights") === refreshes + 6, 100000);
      await advance(wait, 10);
      const forgotten = forgetInSettings();
      await advance(3000, 10);
      await forgotten;
      await advance(30000, 100);
      const sent = sentAfterDelete();
      if (sent.length || ended() !== FORGOTTEN) problems.push(`answers ${slow} ms slower, ${wait} ms in: sent ${sent.join(", ") || "nothing"}; ${ended()}`);
    }
  }
  session.stopPolling();
  assert.deepEqual(problems, []);
});

// The controller stopped answering (Wi-Fi gone, the controller restarting): each refresh waits 8 s
// for its reads, sends them once more, and after two failed refreshes the app says it cannot reach
// the controller. Forget key waits 4 s for the DELETE and forgets the key anyway. The reads that were
// on their way give up later: none is sent again, and the app stays on the pairing screen (1.1.1 sent
// them again with the key being revoked, and could end on "Can't reach your controller").
test("forgetting the key while the controller does not answer ends on the pairing screen", async () => {
  const problems = [];
  const warnings = mock.method(console, "warn", () => {});
  for (let phase = 0; phase < 40000; phase += 2000) {
    await connect([shade()]);
    // Connected a while: the app knows how this controller seals (here: it cannot).
    const first = session.api("/v1/blinds");
    await advance(100, 10);
    await first;
    session.startPolling();
    controller.silent = true;
    await advance(10000 + phase, 100);
    const before = state.status;
    const forgetAt = Date.now();
    let took = null;
    const forgotten = forgetInSettings().then(() => {
      took = Date.now() - forgetAt;
    });
    await advance(40000, 100);
    await forgotten;
    const sent = sentAfterDelete();
    if (sent.length || took !== 4000 || ended() !== FORGOTTEN) {
      problems.push(`${phase} ms in (${before}): forgotten after ${took} ms; sent ${sent.join(", ") || "nothing"}; ${ended()}`);
    }
  }
  warnings.mock.restore();
  assert.deepEqual(problems, []);
});

// Forget key pressed while the app connects (as it starts, or Retry), whether the controller then
// answers or not: the connect ends without changing anything, and nothing more is sent (1.1.1 ended
// connected without a key and read the scenes without one, or said it could not reach the controller).
// Nor does Retry, pressed while Forget key waits for the DELETE, read anything.
test("forgetting the key while the app connects sends nothing more", async () => {
  const problems = [];
  const failures = mock.method(console, "error", () => {});
  for (const silent of [false, true]) {
    for (const wait of [100, 300, 500, 700]) {
      await connect([shade()]);
      Object.assign(controller, { rtt: 400, revokes: true });
      Object.assign(state, { loaded: false, scenes: null, scenesError: null });
      const connecting = session.connect();
      await advance(wait, 10);
      controller.silent = silent;
      const forgotten = forgetInSettings();
      await advance(40000, 50);
      await Promise.all([connecting, forgotten]);
      const sent = sentAfterDelete();
      if (sent.length || ended() !== FORGOTTEN || state.loaded || state.scenesError) {
        problems.push(`${silent ? "no answers" : "answers"}, ${wait} ms in: sent ${sent.join(", ") || "nothing"}; ${ended()}; loaded ${state.loaded}; scenes: ${state.scenesError}`);
      }
    }
  }

  await connect([shade()]);
  const first = session.api("/v1/blinds");
  await advance(100, 10);
  await first;
  Object.assign(state, { loaded: false, status: "unreachable" });
  controller.silent = true;
  const forgotten = forgetInSettings();
  await advance(1000, 10);
  const retried = session.connect();
  await advance(40000, 50);
  await Promise.all([retried, forgotten]);
  const sent = sentAfterDelete();
  if (sent.length || ended() !== FORGOTTEN) problems.push(`Retry while forgetting: sent ${sent.join(", ") || "nothing"}; ${ended()}`);
  failures.mock.restore();
  assert.deepEqual(problems, []);
});

// A light switched just before Forget key: the app reads it every 600 ms until it reports the change,
// for 5 s at most. Forget key pressed while the command is on its way, or while the app waits for the
// light: nothing more is read, and nothing changes (1.1.1 went on reading it with the key being
// revoked, then without one).
test("forgetting the key right after switching a light sends nothing more", async () => {
  const problems = [];
  for (const wait of [50, 300, 900, 3000]) {
    await connect([]);
    const lamp = { id: 22, name: "Lamp", room: { id: 11, name: "Living Room" }, on: false, dimmable: false, brightness: null };
    state.lights = [lamp];
    // Connected a while: the app knows how this controller seals (here: it cannot).
    const first = session.api("/v1/lights");
    await advance(100, 10);
    await first;
    Object.assign(controller, { rtt: 200, revokes: true });
    const switched = controls.setLight(lamp, { on: true });
    await advance(wait, 10);
    const forgotten = forgetInSettings();
    await advance(10000, 50);
    await Promise.all([switched, forgotten]);
    const sent = sentAfterDelete();
    if (sent.length || ended() !== FORGOTTEN || state.errors["light:22"] || state.pending["light:22"]) {
      problems.push(`${wait} ms in: sent ${sent.join(", ") || "nothing"}; ${ended()}; error ${state.errors["light:22"]?.text}; pending ${state.pending["light:22"]}`);
    }
  }
  state.lights = [];
  assert.deepEqual(problems, []);
});

test("a new target while the shade moves keeps the slider on it", async () => {
  await connect([shade({ moving: true, direction: "opening", target_position: 100 })]);
  await advance(500);
  controls.setBlind(state.blinds[0], 50);
  const timeline = [];
  for (let index = 0; index < 12; index += 1) {
    await advance(250);
    timeline.push(shown(52));
    // The controller has the new target a second later.
    if (index === 3) controller.blinds = [shade({ moving: true, direction: "closing", target_position: 50, position: 35 })];
  }
  assert.ok(timeline.every((line) => line.endsWith("| 50")), timeline.join(" / "));
  assert.ok(!timeline.includes("Opening… | 100"), `never opening to 100: ${timeline.join(" / ")}`);
  assert.equal(timeline.at(-1), "Closing… to 50% | 50");
});

test("after Stop the shade shows as stopped, then where it stopped", async () => {
  await connect([shade({ moving: true, direction: "opening", target_position: 100 })]);
  await advance(500);
  controls.stopBlind(state.blinds[0]);
  const timeline = [];
  for (let index = 0; index < 20; index += 1) {
    await advance(250);
    timeline.push(shown(52));
    if (index === 1) controller.blinds = [shade({ target_position: 100 })];
    if (index === 5) controller.blinds = [shade({ target_position: 61, position: 61 })];
  }
  assert.ok(!timeline.some((line) => line.startsWith("Opening…")), timeline.join(" / "));
  assert.equal(timeline[0], "35% open | 35");
  assert.equal(timeline.at(-1), "61% open | 61");
});

// The owner's KNX shades report the stop when the actuator confirms it, 110 to 180 ms after the
// Stop's answer (Director 3.4.3): a read that gets there in between still says the shade opens.
// Wherever the 2 s reads fall, the row does not go back to "Opening…".
test("after Stop the shade does not show as opening again before it reports the stop", async () => {
  const relapses = [];
  for (let phase = 0; phase < MOVE_POLL_MS + 20; phase += 20) {
    await connect([shade({ moving: true, direction: "opening", target_position: 100 })]);
    Object.assign(controller, { rtt: 20, stopLag: 150 });
    await advance(1000 + phase, 10);
    controls.stopBlind(state.blinds[0]);
    const timeline = [];
    for (let index = 0; index < 250; index += 1) {
      await advance(10, 10);
      timeline.push(shown(52));
    }
    if (timeline.some((line) => line.startsWith("Opening…"))) relapses.push(`phase ${phase}: ${[...new Set(timeline)].join(" / ")}`);
    assert.equal(timeline.at(-1), "35% open | 35");
  }
  assert.deepEqual(relapses, []);
});

// The owner's KNX shades: the proxy's stop first, the actuator's real position a second later.
test("after a move stops, the position the shade reports next is read", async () => {
  await connect([shade()]);
  controls.setBlind(state.blinds[0], 53);
  await advance(2100);
  controller.blinds = [shade({ moving: true, direction: "opening", target_position: 53 })];
  await advance(20000);
  controller.blinds = [shade({ target_position: 53 })];
  await advance(2100);
  const at = Date.now();
  controller.blinds = [shade({ target_position: 53, position: 53 })];
  await advance(4000);
  assert.ok(blindReads(at) >= 1, "read again");
  assert.equal(shown(52), "53% open | 53");
  await advance(4000);
  const later = Date.now();
  await advance(20000);
  assert.equal(blindReads(later), 0, "and then no longer");
});

// With DirectorLink 1.0.0 (no capabilities, no movement), a shade that only opens fully.
test("a shade whose position changed and then stays is not shown moving for two minutes", async () => {
  const older = { id: 52, name: "Terrace Shade", room: { id: 11, name: "Living Room" }, position: 0, position_reported: true };
  await connect([older]);
  controls.setBlind(state.blinds[0], 50);
  await advance(3000);
  assert.equal(shown(52), "Opening… to 50% | 50");
  controller.blinds = [{ ...older, position: 100 }];
  await advance(10000);
  assert.equal(shown(52), "Open | 100");
  await advance(6000);
  const from = Date.now();
  await advance(30000);
  assert.equal(blindReads(from), 0, "the move is over");
});

test("Copy the house gives shades that only open and close 0 or 100", async () => {
  await connect([
    shade(),
    shade({ id: 53, position: 30, capabilities: { position: false, stop: false } }),
    shade({ id: 54, position: 80, capabilities: { position: false, stop: false } }),
    shade({ id: 55, position: null }),
  ]);
  const blinds = copyHouse().steps.filter((step) => step.type === "blinds");
  assert.deepEqual(
    blinds.map((step) => [step.set.position, step.device_ids]),
    [
      [35, [52]],
      [0, [53]],
      [100, [54]],
    ]
  );
});

test("room order on DirectorLink 1.0.0 says to update it, in English and Hebrew", async () => {
  await connect([]);
  const refused = await session.api("/v1/rooms/order", { method: "PUT", body: { room_ids: [11, 10] } }).catch((error) => error);
  assert.equal(refused.status, 400);
  assert.equal(refused.code, "BAD_REQUEST");
  assert.equal(roomOrderErrorText(refused), t("settings.rooms.updateDriverOrder"));
  assert.doesNotMatch(roomOrderErrorText(refused), /Remote requests/);
  assert.equal(roomOrderErrorText(new ApiError("Not found", { status: 404, code: "NOT_FOUND" })), t("settings.rooms.updateDriverOrder"));
  const invalid = new ApiError("room_ids: room 10 does not exist", { status: 400, code: "INVALID_FIELD" });
  assert.equal(roomOrderErrorText(invalid), "room_ids: room 10 does not exist", "other refusals say what they say");
  await setLanguage("he");
  assert.match(roomOrderErrorText(refused), /DirectorLink/);
  assert.doesNotMatch(roomOrderErrorText(refused), /Remote requests/);
  await setLanguage("en");
});

test("the devices a room has but the app cannot control follow Composer within a minute", async () => {
  await connect([]);
  state.devices = [{ id: 40, name: "Front Door", room_id: 10, supported: false }];
  controller.devices = [{ id: 41, name: "Pool Pump", room_id: 10, supported: false }];
  session.startPolling();
  await advance(70000, 500);
  session.stopPolling();
  assert.deepEqual(state.devices, controller.devices);
});
