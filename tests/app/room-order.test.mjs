// Moving rooms in Settings → Rooms: the list rules (app/js/reorder.js), and the save
// (app/js/views/settings.js saveRoomOrder): the new order shows at once, each move is one
// PUT /v1/rooms/order, moves made while one is on its way go together in the next, and a refusal
// puts back the order the controller has.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import { dropIndex, edgeScroll, keyTarget, moveItem, sameOrder, shiftOf, slotOffset } from "../../app/js/reorder.js";

const ids = (list) => list.map((item) => item.id);
const rooms = (...list) => list.map((id) => ({ id, name: `Room ${id}` }));

// ---- the list rules ---------------------------------------------------------------------------

test("a room moves to its new place and the others keep their order", () => {
  const list = rooms(10, 11, 12, 13, 14);
  assert.deepEqual(ids(moveItem(list, 1, 3)), [10, 12, 13, 11, 14]);
  assert.deepEqual(ids(moveItem(list, 3, 0)), [13, 10, 11, 12, 14]);
  assert.deepEqual(ids(moveItem(list, 0, 4)), [11, 12, 13, 14, 10]);
  assert.deepEqual(ids(moveItem(list, 2, 2)), [10, 11, 12, 13, 14]);
  assert.deepEqual(ids(moveItem(list, 4, 99)), [10, 11, 12, 13, 14], "past the end: the last place");
  assert.deepEqual(ids(moveItem(list, 1, -5)), [11, 10, 12, 13, 14], "before the start: the first place");
  assert.deepEqual(ids(moveItem(list, 7, 0)), ids(list), "no such room: nothing moves");
  assert.deepEqual(ids(list), [10, 11, 12, 13, 14], "the list itself stays as it was");
});

test("nothing to save when every room is where it was", () => {
  const list = rooms(10, 11, 12);
  assert.equal(sameOrder(list, moveItem(list, 1, 1)), true, "dropped where it was");
  assert.equal(sameOrder(list, rooms(10, 11, 12)), true, "the same rooms, read again");
  assert.equal(sameOrder(list, moveItem(list, 0, 1)), false);
  assert.equal(sameOrder(list, rooms(10, 11)), false, "one room fewer");
  assert.equal(sameOrder(["a", "b"], ["a", "b"], (item) => item), true, "by any key");
});

test("the arrow keys move a room one place, Home and End to the ends, and stop there", () => {
  assert.equal(keyTarget(2, "ArrowUp", 18), 1);
  assert.equal(keyTarget(2, "ArrowDown", 18), 3);
  assert.equal(keyTarget(0, "ArrowUp", 18), 0, "already first");
  assert.equal(keyTarget(17, "ArrowDown", 18), 17, "already last");
  assert.equal(keyTarget(9, "Home", 18), 0);
  assert.equal(keyTarget(9, "End", 18), 17);
  for (const key of ["ArrowLeft", "ArrowRight", "PageDown", " ", "Enter", "Escape", "a", "toString", "constructor"]) {
    assert.equal(keyTarget(9, key, 18), null, key);
  }
  // Picked up at position 3, then Down, Down, Down, Up: dropped at position 5.
  let to = 2;
  for (const key of ["ArrowDown", "ArrowDown", "ArrowDown", "ArrowUp"]) to = keyTarget(to, key, 6);
  assert.deepEqual(ids(moveItem(rooms(10, 11, 12, 13, 14, 15), 2, to)), [10, 11, 13, 14, 12, 15]);
});

// Rows as Settings draws them: 52 px, and one taller (a room hidden for this person has a second line).
const heights = [52, 52, 70, 52, 52];
const tops = heights.map((_, index) => heights.slice(0, index).reduce((sum, height) => sum + height, 0));
const middles = tops.map((top, index) => top + heights[index] / 2);

test("a dragged room takes the place of each room it is half over", () => {
  // The second room (52 to 104 px) dragged by `offset` pixels.
  const landing = (offset) => dropIndex(middles, 1, tops[1] + offset, tops[1] + heights[1] + offset);
  assert.equal(landing(0), 1, "not moved");
  assert.equal(landing(35), 1, "its bottom not yet past the middle of the taller room below (139 px)");
  assert.equal(landing(36), 2);
  assert.equal(landing(96), 2);
  assert.equal(landing(97), 3);
  assert.equal(landing(149), 4);
  assert.equal(landing(-26), 1, "its top at the middle of the first room: not past it");
  assert.equal(landing(-27), 0);
});

test("held at either end of the list, a room reaches the first or the last place", () => {
  // In Settings the first row has no top border: 52 px, the others 53. A dragged room stops at the
  // ends of the list; there it must still take the end place, whatever its height and theirs.
  const rows = [52, 53, 53, 53, 70, 53];
  const top = rows.map((_, index) => rows.slice(0, index).reduce((sum, height) => sum + height, 0));
  const middle = top.map((value, index) => value + rows[index] / 2);
  const end = top.at(-1) + rows.at(-1);
  for (let from = 0; from < rows.length; from += 1) {
    assert.equal(dropIndex(middle, from, 0, rows[from]), 0, `row ${from} at the top`);
    assert.equal(dropIndex(middle, from, end - rows[from], end), rows.length - 1, `row ${from} at the bottom`);
  }
});

test("the rooms in between make room, and the dragged room lands in the gap", () => {
  // For every move: where the others are shifted to, and where the moving room lands, are exactly
  // where the list in its new order has them, whatever their heights.
  for (let from = 0; from < heights.length; from += 1) {
    for (let to = 0; to < heights.length; to += 1) {
      const order = moveItem(heights.map((height, id) => ({ id, height })), from, to);
      const placed = new Map(order.map((item, place) => [item.id, order.slice(0, place).reduce((sum, other) => sum + other.height, 0)]));
      heights.forEach((_, index) => {
        const shown = index === from ? tops[from] + slotOffset(heights, from, to) : tops[index] + shiftOf(index, from, to) * heights[from];
        assert.equal(shown, placed.get(index), `from ${from} to ${to}: row ${index}`);
      });
    }
  }
  assert.equal(slotOffset(heights, 2, 2), 0);
  assert.equal(shiftOf(3, 1, 1), 0, "nothing moves while the room is where it was");
});

test("near the top or the bottom of the screen the page scrolls, faster closer to the edge", () => {
  // A phone 640 px high, its tab bar from 570 px.
  assert.equal(edgeScroll(300, 0, 570), 0, "in the middle");
  assert.equal(edgeScroll(56, 0, 570), 0, "just outside the edge");
  assert.equal(edgeScroll(514, 0, 570), 0);
  assert.ok(edgeScroll(40, 0, 570) < 0, "up");
  assert.ok(edgeScroll(530, 0, 570) > 0, "down");
  assert.ok(edgeScroll(5, 0, 570) < edgeScroll(40, 0, 570), "faster closer to the top");
  assert.ok(edgeScroll(565, 0, 570) > edgeScroll(530, 0, 570), "faster closer to the tab bar");
  assert.equal(edgeScroll(0, 0, 570), -16);
  assert.equal(edgeScroll(-30, 0, 570), -16, "at most 16 px a frame, above the screen too");
  assert.equal(edgeScroll(600, 0, 570), 16, "over the tab bar");
});

// ---- the save ---------------------------------------------------------------------------------

// Just enough of a browser for app/js/views/settings.js and what it imports.
const stored = new Map();
globalThis.window = globalThis;
window.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", pathname: "/", search: "", hash: "" };
window.addEventListener = () => {};
window.removeEventListener = () => {};
window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} });
globalThis.document = { hidden: false, addEventListener() {}, documentElement: {}, querySelector: () => null };
Object.defineProperty(globalThis, "navigator", {
  value: { userAgent: "Node", maxTouchPoints: 0, languages: ["en"], language: "en", onLine: true },
  configurable: true,
});
Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key) => (stored.has(key) ? stored.get(key) : null),
    setItem: (key, value) => stored.set(key, String(value)),
    removeItem: (key) => stored.delete(key),
  },
  configurable: true,
});
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);

// The fake controller: a DirectorLink that cannot seal (so requests carry the key). It answers
// PUT /v1/rooms/order with `answer(roomIds)`, by default the rooms in that order, and holds its
// answers while `gate` is shut.
const HOST = "controller.invalid";
const controller = { puts: [], answer: null, gate: null };

const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const saved = (roomIds) => reply(200, { items: roomIds.map((id) => ({ id, name: `Room ${id}` })) });

globalThis.fetch = async (url, init = {}) => {
  const { hostname, pathname: path } = new URL(url);
  if (hostname !== HOST) throw new TypeError(`blocked: ${url}`);
  const method = init.method || "GET";
  if (path === "/v1/sealed") return reply(404, { status: 404, code: "NOT_FOUND" });
  if (path === "/v1/rooms/order" && method === "PUT") {
    const roomIds = JSON.parse(init.body).room_ids;
    controller.puts.push(roomIds);
    await controller.gate;
    return (controller.answer || saved)(roomIds);
  }
  return reply(404, { status: 404, code: "NOT_FOUND", detail: `no ${method} ${path}` });
};

const { state, ui } = await import("../../app/js/state.js");
const { saveRoomOrder } = await import("../../app/js/views/settings.js");
const { t } = await import("../../app/js/i18n.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

// Lets fetch answers and promise chains settle.
async function settle() {
  for (let index = 0; index < 10; index += 1) await new Promise((resolve) => setImmediate(resolve));
}

// Connected as an admin, with these rooms in the home's order.
function home(...list) {
  Object.assign(state, { host: HOST, apiKey: "ak_test", transport: "lan", status: "connected", loaded: true, role: "admin", rooms: rooms(...list) });
  ui.roomOrderMessage = null;
  Object.assign(controller, { puts: [], answer: null, gate: null });
}

// Shuts the controller's answers; the function returned opens them again.
function hold() {
  let open;
  controller.gate = new Promise((resolve) => (open = resolve));
  return () => {
    controller.gate = null;
    open();
  };
}

test("a move shows at once and goes to the controller in one PUT", async () => {
  home(10, 11, 12, 13);
  const release = hold();
  const saving = saveRoomOrder(moveItem(state.rooms, 3, 0));
  assert.deepEqual(ids(state.rooms), [13, 10, 11, 12], "shown while it is saved");
  await settle();
  assert.deepEqual(controller.puts, [[13, 10, 11, 12]]);
  release();
  await saving;
  assert.deepEqual(controller.puts, [[13, 10, 11, 12]], "one request");
  assert.deepEqual(ids(state.rooms), [13, 10, 11, 12]);
  assert.equal(ui.roomOrderMessage, null);
});

test("moves made while one is on its way go together in the next PUT", async () => {
  home(10, 11, 12, 13);
  const release = hold();
  const saving = saveRoomOrder(moveItem(state.rooms, 0, 3));
  await settle();
  saveRoomOrder(moveItem(state.rooms, 0, 1));
  saveRoomOrder(moveItem(state.rooms, 2, 0));
  await settle();
  assert.equal(controller.puts.length, 1, "one on its way");
  assert.deepEqual(ids(state.rooms), [13, 12, 11, 10], "each move shows at once");
  release();
  await saving;
  assert.deepEqual(controller.puts, [[11, 12, 13, 10], [13, 12, 11, 10]], "then one more, with the order as it is now");
  assert.deepEqual(ids(state.rooms), [13, 12, 11, 10]);
});

test("a refused move puts the order back, and DirectorLink 1.0.0 says to update it", async () => {
  home(10, 11, 12);
  // As DirectorLink 1.0.0 answered PUT in a sealed request.
  controller.answer = () => reply(400, { status: 400, code: "BAD_REQUEST", detail: "Remote requests are GET, POST, PATCH or DELETE on /v1/..." });
  await saveRoomOrder(moveItem(state.rooms, 2, 0));
  assert.deepEqual(controller.puts, [[12, 10, 11]]);
  assert.deepEqual(ids(state.rooms), [10, 11, 12], "back as it was");
  assert.deepEqual(ui.roomOrderMessage, { kind: "error", text: t("settings.rooms.updateDriverOrder") });
});

test("when the second of two moves is refused, the first stays: the controller has it", async () => {
  home(10, 11, 12);
  const release = hold();
  const saving = saveRoomOrder(moveItem(state.rooms, 0, 2));
  await settle();
  controller.answer = (roomIds) => (roomIds[0] === 12 ? reply(400, { status: 400, code: "INVALID_FIELD", detail: "room_ids: room 12 does not exist" }) : saved(roomIds));
  saveRoomOrder(moveItem(state.rooms, 1, 0));
  release();
  await saving;
  assert.deepEqual(controller.puts, [[11, 12, 10], [12, 11, 10]]);
  assert.deepEqual(ids(state.rooms), [11, 12, 10]);
  assert.deepEqual(ui.roomOrderMessage, { kind: "error", text: "room_ids: room 12 does not exist" });
  // The next move clears the message.
  await saveRoomOrder(moveItem(state.rooms, 2, 0));
  assert.equal(ui.roomOrderMessage, null);
});

test("the text for moving rooms is in English and Hebrew, with the same placeholders", () => {
  const holes = (text) => [...text.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();
  for (const key of ["orderHelpAdmin", "move", "moveKeys", "moveUp", "moveDown", "lifted", "position", "dropped", "cancelled"]) {
    const english = en.settings.rooms[key];
    const hebrew = he.settings.rooms[key];
    assert.equal(typeof english, "string", `en ${key}`);
    assert.match(hebrew, /[א-ת]/, `he ${key}`);
    assert.deepEqual(holes(hebrew), holes(english), key);
  }
  assert.equal(t("settings.rooms.position", { name: "Kitchen", position: 3, count: 18 }), "Kitchen: position 3 of 18");
});
