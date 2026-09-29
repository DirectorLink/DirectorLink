// Shades in the app (app/js/shades.js): which controls a shade gets, and what shows while it moves.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import {
  MOVE_POLL_MS,
  MOVE_START_MS,
  MOVE_TIMEOUT_MS,
  POSITION_HOLD_MS,
  STOP_SETTLE_MS,
  afterMove,
  answered,
  canSetPosition,
  canStop,
  followMove,
  followSettle,
  followsReport,
  movingText,
  sceneBlindChoices,
  scenePosition,
  shadeView,
  startMove,
  startSettle,
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
  assert.deepEqual(move, { target: 53, direction: "opening", from: 35, sentAt: 1000, answeredAt: null, fresh: false, sawMoving: false, reportsMotion: false, held: null });
  assert.equal(answered(move, 1400).answeredAt, 1400);
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
  const move = answered(startMove(terrace, 53, 0), 300);
  const notYet = { ...terrace, moving: false, position: 35 };
  assert.equal(followMove(move, notYet, 1500), move, "moving: false right after the command is not a stop");
  const read = followMove(move, notYet, 2000, 400);
  assert.equal(read.fresh, true);
  assert.equal(followMove(read, notYet, MOVE_START_MS + 1, 7900), read, "nor later, for a shade never seen moving");
  const known = answered(startMove(terrace, 53, 0, true), 300);
  assert.equal(followMove(known, notYet, 1500, 400).fresh, true, "a shade that reports its movement gets time to start");
  assert.equal(followMove(known, notYet, MOVE_START_MS, 7000), null, "then standing still means it did not move");
  assert.ok(followMove(known, notYet, MOVE_START_MS), "but only a read after the command's answer says so");
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
  // Read after the app's command was answered, what it reports wins over the app's idea of the move.
  const move = followMove(answered(startMove(terrace, 80, 0), 500), moving, 2000, 600);
  assert.equal(shadeView(moving, move).target, 20);
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

// Opening to 100, the slider is moved to 50: the command's answer, and a read that was on its way,
// still show the shade opening to 100. They must not move the slider back.
test("a new target wins over reports from before its answer", () => {
  const opening = { ...terrace, moving: true, direction: "opening", target_position: 100, position: 35 };
  let move = startMove(opening, 50, 1000, true);
  assert.deepEqual(shadeView(opening, move), { moving: true, direction: "opening", target: 50, slider: 50 });
  move = answered(move, 1400);
  move = followMove(move, opening, 1500, 900);
  assert.equal(move.sawMoving, false, "a read from before the answer says nothing about this move");
  assert.equal(shadeView(opening, move).slider, 50);
  assert.deepEqual(movingText(shadeView(opening, move)), { key: "blinds.openingTo", percent: 50 });
  // The first read that started after the answer: the shade closes to 50.
  const closing = { ...opening, direction: "closing", target_position: 50 };
  move = followMove(move, closing, 3500, 3000);
  assert.equal(move.fresh, true);
  assert.equal(move.sawMoving, true);
  assert.deepEqual(shadeView(closing, move), { moving: true, direction: "closing", target: 50, slider: 50 });
  // From then on the reports are the shade's, even one that went elsewhere (a keypad).
  assert.equal(shadeView({ ...opening, target_position: 90 }, move).target, 90);
  // A report that shows the command's target can be taken at once.
  const agreeing = followMove(startMove(opening, 100, 0), opening, 500);
  assert.equal(agreeing.sawMoving, true);
  // One passing the new target on its way elsewhere cannot (seen in the browser: 90, then 50).
  const passing = { ...opening, target_position: 90, position: 50 };
  const toFifty = startMove(passing, 50, 0, true);
  assert.equal(followMove(toFifty, passing, 300), toFifty);
  assert.deepEqual(shadeView(passing, toFifty), { moving: true, direction: null, target: 50, slider: 50 });
  // At rest there, it can: nothing is left to do.
  assert.equal(followMove(toFifty, { ...passing, moving: false, direction: null }, 300), null);
});

// Stop while it opens to 100: the Stop's answer, and reads from before it, still say it is opening.
// So may a read after the answer: the controller reports the stop once the shade confirms it.
test("after Stop the shade shows as stopped, then where it reports it stopped", () => {
  const opening = { ...terrace, moving: true, direction: "opening", target_position: 100, position: 35 };
  let settle = startSettle(1000, true);
  assert.deepEqual(shadeView(opening, settle), { moving: false, direction: null, target: null, slider: 35 });
  settle = answered(settle, 1300);
  assert.equal(settle.until, 1300 + STOP_SETTLE_MS, "read for a while after the answer");
  settle = followSettle(settle, opening, 2000, 1200);
  assert.equal(shadeView(opening, settle).moving, false, "a read from before the answer");
  settle = followSettle(settle, opening, 2500, 1400);
  assert.equal(settle.fresh, false, "a read after the answer, before the controller has the stop");
  assert.equal(shadeView(opening, settle).moving, false);
  const stopped = { ...opening, moving: false, direction: null, target_position: 61, position: 61 };
  settle = followSettle(settle, stopped, 3000, 2500);
  assert.deepEqual(shadeView(stopped, settle), { moving: false, direction: null, target: null, slider: 61 });
  assert.equal(shadeView(opening, settle).moving, true, "once it reported the stop, a report that it moves again is believed");
  assert.equal(followSettle(settle, opening, 1300 + STOP_SETTLE_MS, 7000), null, "and the reads end");
  // A shade that does not report its movement: the first read after the answer.
  assert.equal(followSettle(answered(startSettle(1000, true), 1300), older, 2000, 1400).fresh, true);
  // One that never reports the stop shows what it reports once the reads are over.
  assert.equal(followSettle(answered(startSettle(1000, true), 1300), opening, 1300 + STOP_SETTLE_MS, 7000), null);
});

// The owner's KNX shades: the proxy's stop comes first, the actuator's real position about a
// second later.
test("a move that ends is read a few seconds more", () => {
  let move = answered(startMove(terrace, 53, 0), 200);
  move = followMove(move, { ...terrace, moving: true, direction: "opening", target_position: 53 }, 2000, 1000);
  const stale = { ...terrace, moving: false, target_position: 53, position: 35 };
  assert.equal(followMove(move, stale, 22000, 21000), null, "the stop ends the move");
  const settle = afterMove(move, 22000);
  assert.deepEqual(settle, { settle: true, stopped: false, sentAt: 22000, until: 22000 + STOP_SETTLE_MS, answeredAt: null, fresh: true });
  assert.deepEqual(shadeView(stale, settle), shadeView(stale, null), "the reports show as they are");
  assert.equal(followSettle(settle, stale, 24000, 23000), settle);
  assert.equal(followSettle(settle, stale, 22000 + STOP_SETTLE_MS), null);
  assert.equal(afterMove(move, MOVE_TIMEOUT_MS), null, "not after a move that timed out");
});

// A shade whose driver does not report movement (1.0.0), or one that stops short.
test("a position that changed and then stays ends the move", () => {
  const shutter = { id: 53, position: 0, position_reported: true };
  let move = answered(startMove(shutter, 50, 0), 100);
  move = followMove(move, shutter, 2000, 1000);
  assert.ok(move, "still at 0");
  move = followMove(move, { ...shutter, position: 100 }, 4000, 3000);
  assert.ok(move, "opened fully: changed");
  move = followMove(move, { ...shutter, position: 100 }, 4000 + POSITION_HOLD_MS - 1, 5000);
  assert.ok(move, "not yet held long enough");
  assert.equal(followMove(move, { ...shutter, position: 100 }, 4000 + POSITION_HOLD_MS, 7000), null, "held: the move is over");
  assert.deepEqual(shadeView({ ...shutter, position: 100 }, null), { moving: false, direction: null, target: null, slider: 100 });

  // Still changing: not over.
  move = answered(startMove(terrace, 80, 0), 100);
  move = followMove(move, { ...terrace, moving: null, position: 50 }, 2000, 1000);
  move = followMove(move, { ...terrace, moving: null, position: 65 }, 4500, 3500);
  move = followMove(move, { ...terrace, moving: null, position: 65 }, 6000, 5500);
  assert.ok(move, "65 for only 1.5 s");
  assert.equal(followMove(move, { ...terrace, moving: null, position: 77 }, 9000, 8500).held.position, 77);
  // Stopped short of the target (an actuator at 77 for 80): over once it stays.
  assert.equal(followMove(followMove(move, { ...terrace, moving: null, position: 77 }, 9000, 8500), { ...terrace, moving: null, position: 77 }, 13000, 12500), null);
  // A shade that says it moves is followed until it stops, however long its position stays.
  let knx = answered(startMove(terrace, 80, 0), 100);
  for (let now = 2000; now < 60000; now += MOVE_POLL_MS) {
    knx = followMove(knx, { ...terrace, moving: true, direction: "opening", target_position: 80, position: 50 }, now, now - 500);
    assert.ok(knx, `moving at ${now}`);
  }
});

test("a shade that keeps reporting it moves is read quickly only as long as a move takes", () => {
  const moving = { ...terrace, moving: true, direction: "opening", target_position: 80 };
  assert.equal(followsReport(moving, 1000, 1000), true);
  assert.equal(followsReport(moving, 1000, 1000 + MOVE_TIMEOUT_MS - 1), true);
  assert.equal(followsReport(moving, 1000, 1000 + MOVE_TIMEOUT_MS), false, "stuck: the normal refresh reads it");
  assert.equal(followsReport(moving, undefined, 5000), true);
  assert.equal(followsReport(terrace, 1000, 2000), false);
  assert.equal(followsReport({ ...terrace, moving: null }, 1000, 2000), false);
});

test("scenes give a shade that only opens and closes 0 or 100", () => {
  assert.equal(scenePosition(terrace), 35);
  assert.equal(scenePosition({ ...terrace, position: 62.6 }), 63);
  assert.equal(scenePosition({ ...patio, position: 30 }), 0, "stopped at 30: closed");
  assert.equal(scenePosition({ ...patio, position: 70 }), 100);
  assert.equal(scenePosition({ ...patio, position: 50 }), 100);
  assert.equal(scenePosition({ ...patio, position: 0 }), 0);
  assert.equal(scenePosition(older), 40, "drivers before 1.1.0: as reported");
  assert.equal(scenePosition({ ...terrace, position: null }), null);
  assert.deepEqual(sceneBlindChoices([terrace, patio]), ["open", "close", "set"]);
  assert.deepEqual(sceneBlindChoices([patio]), ["open", "close"], "no position for shades that cannot take one");
  assert.deepEqual(sceneBlindChoices([older]), ["open", "close", "set"]);
});
