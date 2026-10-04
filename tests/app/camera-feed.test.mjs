// Camera pictures at the same time (app/js/camera-feed.js, 1.8.0, ADR-055): several asked for at
// once, each tile showing its picture as soon as it comes, one request per camera and size however
// many tiles show it, and nothing piling up on a slow connection. Against a fake controller (one that
// cannot seal, so pictures are asked for with the key) whose every picture takes `rtt` ms there and
// back, under fake time. The few browser globals the module uses are faked here.
//   node --test tests/app/

import assert from "node:assert/strict";
import test, { mock } from "node:test";

const HOST = "controller.invalid";
const stored = new Map();

globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "#/cameras" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
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

// The tiles on the page: <img data-camera-id data-width> in a <div class="cam">. `shownAt`: when
// each picture was put in.
class FakeImage {
  constructor(id, width, live = false) {
    this.dataset = { cameraId: String(id), width: String(width), ...(live ? { live: "" } : {}) };
    this.tile = { dataset: { state: "loading" } };
    this.isConnected = true;
    this.source = null;
    this.shownAt = [];
  }
  set src(url) {
    this.source = url;
    this.shownAt.push(Date.now());
  }
  get src() {
    return this.source || "";
  }
  getAttribute(name) {
    return name === "src" ? this.source : null;
  }
  removeAttribute(name) {
    if (name === "src") this.source = null;
  }
  closest(selector) {
    return selector === ".cam" ? this.tile : null;
  }
  addEventListener() {}
}

let page = [];
// The selectors camera-feed.js uses.
function select(selector) {
  const id = selector.match(/data-camera-id="(\d+)"/)?.[1];
  const width = selector.match(/data-width="(\d+)"/)?.[1];
  return page.filter((image) => {
    if (!image.isConnected) return false;
    if (id && image.dataset.cameraId !== id) return false;
    if (width && image.dataset.width !== width) return false;
    if (selector.includes(":not([data-live])") && "live" in image.dataset) return false;
    if (/\[data-live\](?!\))/.test(selector.replace(":not([data-live])", "")) && !("live" in image.dataset)) return false;
    return true;
  });
}
globalThis.document = {
  hidden: false,
  addEventListener() {},
  documentElement: {},
  querySelector: (selector) => select(selector)[0] || null,
  querySelectorAll: (selector) => select(selector),
};
const root = { querySelectorAll: (selector) => select(selector), querySelector: (selector) => select(selector)[0] || null };

mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: Date.parse("2026-10-04T18:00:00Z") });

// The controller: every picture takes `rtt` ms there and back. What it was asked: `asked` (key ->
// how many times), and how many pictures were on their way at once (`most`, and per key).
const controller = { rtt: 500, asked: new Map(), onTheirWay: 0, most: 0, perKey: new Map(), mostPerKey: 0, calls: [] };
const later = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

globalThis.fetch = async (url, init = {}) => {
  const address = new URL(url);
  if (address.hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  if (address.pathname === "/v1/sealed") return new Response(JSON.stringify({ status: 404, code: "NOT_FOUND" }), { status: 404, headers: { "Content-Type": "application/json" } });
  const picture = address.pathname.match(/^\/v1\/cameras\/(\d+)\/snapshot$/);
  if (!picture) return new Response(JSON.stringify({ items: [] }), { status: 200, headers: { "Content-Type": "application/json" } });
  const key = `${picture[1]}:${address.searchParams.get("width")}`;
  controller.calls.push({ at: Date.now(), key });
  controller.asked.set(key, (controller.asked.get(key) || 0) + 1);
  controller.onTheirWay += 1;
  controller.most = Math.max(controller.most, controller.onTheirWay);
  controller.perKey.set(key, (controller.perKey.get(key) || 0) + 1);
  controller.mostPerKey = Math.max(controller.mostPerKey, controller.perKey.get(key));
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(resolve, controller.rtt);
      init.signal?.addEventListener("abort", () => {
        clearTimeout(timer);
        reject(new DOMException("The operation was aborted.", "AbortError"));
      });
    });
  } finally {
    controller.onTheirWay -= 1;
    controller.perKey.set(key, controller.perKey.get(key) - 1);
  }
  return new Response(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]), { status: 200, headers: { "Content-Type": "image/jpeg" } });
};

const { state } = await import("../../app/js/state.js");
const feed = await import("../../app/js/camera-feed.js");
// Quiet the line the app writes when a screen has filled.
console.info = () => {};

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

// The 11 cameras of a test: ids from `base` (each test its own, so that no picture of an earlier
// test is shown at once).
let cameras = [];
let base = 100;
const id = (index) => cameras[index].id;

// The Cameras screen, as views/cameras.js draws it: the first camera large (640), the others in the
// grid (320). `extra`: more tiles.
function camerasScreen(extra = []) {
  for (const image of page) image.isConnected = false;
  page = [new FakeImage(cameras[0].id, 640), ...cameras.slice(1).map((camera) => new FakeImage(camera.id, 320)), ...extra];
  return page;
}

// Connected to the fake controller, at home, with 11 cameras of its own.
async function connect({ rtt = 500, atOnce = null } = {}) {
  base += 100;
  cameras = Array.from({ length: 11 }, (_, index) => ({ id: base + index, name: `Camera ${index + 1}`, room: { id: 10, name: "Kitchen" }, snapshot_href: `/v1/cameras/${base + index}/snapshot` }));
  for (const image of page) image.isConnected = false;
  page = [];
  // Whatever an earlier test left on its way comes back first.
  await advance(30000, 500);
  Object.assign(controller, { rtt, asked: new Map(), onTheirWay: 0, most: 0, perKey: new Map(), mostPerKey: 0, calls: [] });
  if (atOnce) localStorage.setItem("directorlink.picturesAtOnce", String(atOnce));
  else localStorage.removeItem("directorlink.picturesAtOnce");
  Object.assign(state, { host: HOST, apiKey: "ak_test", role: "admin", status: "connected", loaded: true, transport: "lan", cameras: cameras.map((camera) => ({ ...camera })), doorbells: [] });
}

// When every tile of the screen had its first picture, from when the first was asked for.
function filledIn(images) {
  const first = Math.min(...controller.calls.map((call) => call.at));
  return Math.max(...images.map((image) => image.shownAt[0])) - first;
}

test("eleven cameras: four pictures at once, each shown as it comes, the screen full in three round trips instead of eleven", async () => {
  await connect({ rtt: 500 });
  const images = camerasScreen();
  feed.attachCameraImages(root);
  await advance(400 + 500);
  assert.equal(controller.most, feed.PICTURES_AT_ONCE, "four on their way at once");
  assert.equal(feed.picturesAtOnce(), 4);
  // The first four are shown as soon as they came, before the others.
  const shown = images.filter((image) => image.source);
  assert.equal(shown.length, 4, "the first four, already");
  await advance(2000);
  assert.ok(images.every((image) => image.source), "every tile has its picture");
  const took = filledIn(images);
  assert.equal(took, 3 * 500, `11 pictures in ${took} ms`);
  assert.equal(controller.most, 4, "never more than four");
  assert.deepEqual([...controller.asked.values()], Array(11).fill(1), "each picture once");
  assert.equal(feed.lastFill.pictures, 11);
});

test("one at a time (as before 1.8.0) the same screen takes eleven round trips", async () => {
  await connect({ rtt: 500, atOnce: 1 });
  const images = camerasScreen();
  feed.attachCameraImages(root);
  await advance(400 + 11 * 500 + 500);
  assert.ok(images.every((image) => image.source));
  assert.equal(controller.most, 1);
  assert.equal(filledIn(images), 11 * 500);
  localStorage.removeItem("directorlink.picturesAtOnce");
});

test("one request per camera and size, however many tiles show it", async () => {
  await connect({ rtt: 500 });
  // The second camera also as a favorite on the page, twice, and once larger.
  const twice = [new FakeImage(id(1), 320), new FakeImage(id(1), 320), new FakeImage(id(1), 640)];
  camerasScreen(twice);
  feed.attachCameraImages(root);
  await advance(400 + 4 * 500);
  assert.equal(controller.asked.get(`${id(1)}:320`), 1);
  assert.equal(controller.asked.get(`${id(1)}:640`), 1, "another size is another picture");
  assert.equal(twice[0].source, twice[1].source, "the same picture in both");
  assert.equal(controller.calls.length, 12);
});

test("a picture that comes after a redraw goes into the tiles drawn since", async () => {
  await connect({ rtt: 800 });
  camerasScreen();
  feed.attachCameraImages(root);
  await advance(400 + 100);
  // The screen is drawn again while the first pictures are on their way (a poll changed something).
  const redrawn = camerasScreen();
  feed.attachCameraImages(root);
  await advance(800);
  assert.equal(redrawn.filter((image) => image.source).length, 4, "the new tiles got them");
  await advance(3000);
  assert.ok(redrawn.every((image) => image.source));
  assert.deepEqual([...controller.asked.values()], Array(11).fill(1), "nothing asked twice for the redraw");
});

test("on a slow connection nothing piles up: a camera whose picture is still on its way is not asked again", async () => {
  // Each picture takes 9 s there and back: longer than the 3 s between rounds.
  await connect({ rtt: 9000 });
  camerasScreen();
  feed.attachCameraImages(root);
  // The full view and live pictures are not open: the grid alone, for a minute.
  await advance(60000, 250);
  assert.equal(controller.mostPerKey, 1, "never two requests for one picture at once");
  assert.ok(controller.most <= feed.PICTURES_AT_ONCE, `at most four at once (${controller.most})`);
  // In a minute, with 4 at once and 9 s each: about 26 pictures; each camera at most its share.
  const most = Math.max(...controller.asked.values());
  assert.ok(most <= 4, `each picture asked for at most 4 times in a minute (${most})`);
  assert.ok(controller.calls.length <= Math.ceil(60000 / 9000) * 4, `${controller.calls.length} requests in a minute`);
});

test("a live picture (the doorbell banner) goes ahead of the grid's that wait", async () => {
  await connect({ rtt: 500 });
  camerasScreen();
  feed.attachCameraImages(root);
  // The grid's round: four on their way, seven waiting. Then the doorbell rings: the banner.
  await advance(400 + 100);
  const live = new FakeImage(id(9), 640, true);
  camerasScreen([live]);
  feed.attachCameraImages(root);
  await advance(2000);
  const first = Math.min(...controller.calls.map((call) => call.at));
  assert.equal(live.shownAt[0] - first, 2 * 500, "next after the first four, not after the seven waiting");
});
