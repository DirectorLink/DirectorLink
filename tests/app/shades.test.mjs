// Shades in the app (app/js/shades.js): which controls a shade gets, and what shows while it moves.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import {
  MOVE_POLL_MS,
  MOVE_START_MS,
  MOVE_TIMEOUT_MS,
  canSetPosition,
  canStop,
  followMove,
  movingText,
  shadeView,
  startMove,
} from "../../app/js/shades.js";

// The fake Director's shades (driver/tests/c4mock.lua withShades), as a 1.1.0 driver reports them.
const terrace = { id: 52, position: 35, capabilities: { position: true, stop: true }, moving: false, direction: null, target_position: 35 };
const patio = { id: 53, position: 0, capabilities: { position: false, stop: false }, moving: false, direction: null, target_position: 0 };
// A blind from a driver before 1.1.0: no capabilities, nothing about movement.
const older = { id: 50, position: 40, position_reported: true };

test("the slider and Stop only where the shade can use them", () => {
  assert.equal(canSetPosition(terrace), true);
  assert.equal(canStop(terrace), true);
  assert.equal(canSetPosition(patio), false, "a shade that only opens and closes fully");
  assert.equal(canStop(patio), false);
  assert.equal(canSetPosition(older), true, "drivers before 1.1.0 keep both");
  assert.equal(canStop(older), true);
  assert.equal(canSetPosition(null), true);
});

test("a command starts a move towards its target", () => {
  const move = startMove(terrace, 53, 1000);
  assert.deepEqual(move, { target: 53, direction: "opening", sentAt: 1000, sawMoving: false, reportsMotion: false });
  assert.equal(startMove(terrace, 20, 0).direction, "closing");
  assert.equal(startMove({ ...terrace, position: null }, 100, 0).direction, "opening", "from an unknown position, fully open is opening");
  assert.equal(startMove({ ...terrace, position: null }, 0, 0).direction, "closing");
  assert.equal(startMove({ ...terrace, position: null }, 53, 0).direction, null, "otherwise the way is not known");
  assert.equal(startMove(terrace, 53, 0, true).reportsMotion, true);
});

test("while a shade moves the slider stays on the target and never snaps back", () => {
  // 70 s from 35 to 53, polled every 2 s: the controller keeps reporting 35 for most of it.
  let move = startMove(terrace, 53, 0);
  for (let now = MOVE_POLL_MS; now < 70000; now += MOVE_POLL_MS) {
    const report = { ...terrace, moving: now > 1000, direction: "opening", target_position: 53, position: now < 60000 ? 35 : 50 };
    move = followMove(move, report, now);
    assert.ok(move, `still moving at ${now} ms`);
    const view = shadeView(report, move);
    assert.equal(view.slider, 53, `the slider stays on the target at ${now} ms`);
    assert.deepEqual(movingText(view), { key: "blinds.openingTo", percent: 53 });
  }
  // It stops, where it was sent: the reported position shows.
  const stopped = { ...terrace, moving: false, direction: null, target_position: 53, position: 53 };
  move = followMove(move, stopped, 70000);
  assert.equal(move, null, "a stop after moving ends the move");
  assert.deepEqual(shadeView(stopped, move), { moving: false, direction: null, target: null, slider: 53 });
});

test("the shade stopping somewhere else shows where it stopped", () => {
  let move = followMove(startMove(terrace, 80, 0), { ...terrace, moving: true, direction: "opening", target_position: 80 }, 2000);
  const stoppedEarly = { ...terrace, moving: false, position: 61, target_position: 80 };
  move = followMove(move, stoppedEarly, 4000);
  assert.equal(move, null);
  assert.equal(shadeView(stoppedEarly, move).slider, 61);
});

test("before the controller reports the move, the move is kept", () => {
  const move = startMove(terrace, 53, 0);
  const notYet = { ...terrace, moving: false, position: 35 };
  assert.equal(followMove(move, notYet, 1500), move, "moving: false right after the command is not a stop");
  assert.equal(followMove(move, notYet, MOVE_START_MS + 1), move, "nor later, for a shade never seen moving");
  const known = startMove(terrace, 53, 0, true);
  assert.equal(followMove(known, notYet, 1500), known, "a shade that reports its movement gets time to start");
  assert.equal(followMove(known, notYet, MOVE_START_MS), null, "then standing still means it did not move");
});

test("older drivers: the move ends when the shade reports the target, or after two minutes", () => {
  let move = startMove(older, 90, 0);
  move = followMove(move, older, 2000);
  assert.ok(move, "still at 40");
  assert.deepEqual(movingText(shadeView(older, move)), { key: "blinds.openingTo", percent: 90 });
  assert.equal(followMove(move, { ...older, position: 89 }, 20000), null, "at the target (within 2)");
  assert.ok(followMove(move, older, MOVE_TIMEOUT_MS - 1));
  assert.equal(followMove(move, older, MOVE_TIMEOUT_MS), null, "given up after two minutes");
  assert.deepEqual(shadeView(older, null), { moving: false, direction: null, target: null, slider: 40 });
});

test("a shade moved by someone else shows its own report", () => {
  const moving = { ...terrace, moving: true, direction: "closing", target_position: 20, position: 30 };
  const view = shadeView(moving, null);
  assert.deepEqual(view, { moving: true, direction: "closing", target: 20, slider: 20 });
  assert.deepEqual(movingText(view), { key: "blinds.closingTo", percent: 20 });
  // What it reports wins over the app's own idea of the move.
  assert.equal(shadeView(moving, startMove(terrace, 80, 0)).target, 20);
  // Moving without a target or a direction: towards the target if there is one.
  assert.equal(shadeView({ ...terrace, moving: true, direction: null, target_position: 90, position: 30 }).direction, "opening");
  assert.deepEqual(movingText(shadeView({ ...terrace, moving: true, direction: null, target_position: null, position: 30 })), { key: "blinds.moving" });
});

test("the words: fully open or closed need no percent, and an unknown target none", () => {
  assert.deepEqual(movingText({ direction: "opening", target: 100 }), { key: "blinds.opening" });
  assert.deepEqual(movingText({ direction: "closing", target: 0 }), { key: "blinds.closing" });
  assert.deepEqual(movingText({ direction: "closing", target: 20 }), { key: "blinds.closingTo", percent: 20 });
  assert.deepEqual(movingText({ direction: "opening", target: null }), { key: "blinds.opening" });
  assert.deepEqual(movingText({ direction: null, target: 53 }), { key: "blinds.movingTo", percent: 53 });
  assert.deepEqual(movingText({ direction: null, target: null }), { key: "blinds.moving" });
});

test("a shade that only opens and closes shows its movement too", () => {
  const move = startMove(patio, 100, 0);
  const view = shadeView({ ...patio, moving: true, direction: "opening", target_position: 100 }, move);
  assert.deepEqual(movingText(view), { key: "blinds.opening" });
  assert.equal(shadeView({ ...patio, position: null }, null).slider, 0, "position unknown: the (hidden) slider rests at 0");
});
