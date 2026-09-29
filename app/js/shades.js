// Shades, blinds and shutters: which controls a shade gets, and what the app shows while one moves.
// A shade takes 10 to 70 seconds to get where it was sent, and all the while the controller may
// still report the position it left: the app shows where the shade is going instead, and the
// reported position once it stops. The answer to a command, and a read already on its way, show
// the shade as it was before the command: until a read that started after the answer (or one that
// shows the command's target), what the app sent wins over what they report. No imports, so the
// rules can be tested under Node (tests/app/shades.test.mjs).

// While a shade moves, the app reads the blinds this often.
export const MOVE_POLL_MS = 2000;
// A move the shade never reports as over ends after this long. A shade that reports moving for
// longer (stuck) is read at the normal refresh again.
export const MOVE_TIMEOUT_MS = 2 * 60 * 1000;
// A shade that reported its movement before and is still not moving this long after a command did
// not move (it was there already, or the command went nowhere).
export const MOVE_START_MS = 8000;
// How far from the target a reported position may be and still count as there.
export const POSITION_TOLERANCE = 2;
// A position that changed after the command and then stays the same this long (about two reads)
// ends the move: the shade stopped somewhere else (a keypad, an actuator that stops at 47 for 50),
// or it only opens and closes fully and its driver (before 1.1.0) does not say so.
export const POSITION_HOLD_MS = 2 * MOVE_POLL_MS;
// After Stop, and after a move ends, the app reads the blinds this long, to show where the shade
// stopped: a KNX actuator reports its real position about a second after the stop.
export const STOP_SETTLE_MS = 6000;
// A read of the blinds this long after the one before (the page was in the background, or the
// controller out of reach): a shade that reported moving then may have stopped and started again
// meanwhile, so its time moving starts over. Longer than the refresh every 10 s, which is all that
// reads a shade that reports moving for longer than a move takes.
export const REPORT_GAP_MS = 30000;

// Drivers before 1.1.0 send no capabilities: their shades keep the slider and Stop.
export const canSetPosition = (blind) => blind?.capabilities?.position !== false;
export const canStop = (blind) => blind?.capabilities?.stop !== false;

const finite = (value) => (Number.isFinite(value) ? value : null);

// Which way a shade at `from` goes to reach `target`; null when that cannot be told.
function directionTo(from, target) {
  if (!Number.isFinite(target)) return null;
  if (Number.isFinite(from)) return target > from ? "opening" : target < from ? "closing" : null;
  return target === 100 ? "opening" : target === 0 ? "closing" : null;
}

// The move the app expects after sending `target` to `blind` (as last reported), until the shade
// reports otherwise. `reportsMotion`: this shade has reported moving before, so a report that it
// stands still can be believed once it had time to start.
export function startMove(blind, target, now, reportsMotion = false) {
  const from = finite(blind?.position);
  return { target, direction: directionTo(from, target), from, sentAt: now, answeredAt: null, fresh: false, sawMoving: false, reportsMotion, held: null };
}

// The reads after Stop (`stopped`), or after a move ended: STOP_SETTLE_MS more, for where the shade
// stopped. After Stop, a report that the shade moves is from before it, until a read that started
// after the Stop's answer has it stopped: the controller reports the stop once the shade confirms
// it, on the owner's KNX shades 110 to 180 ms after the answer.
export function startSettle(now, stopped = false) {
  return { settle: true, stopped, sentAt: now, until: now + STOP_SETTLE_MS, answeredAt: null, fresh: !stopped };
}

// The command's answer came (a move's or a Stop's): reads that start from now show what it did.
// The reads after Stop go on for STOP_SETTLE_MS from its answer.
export function answered(command, now) {
  if (!command) return null;
  return command.settle ? { ...command, answeredAt: now, until: now + STOP_SETTLE_MS } : { ...command, answeredAt: now };
}

// A read that started at `readAt` shows what the command did.
function readAfter(command, readAt) {
  return command.answeredAt !== null && Number.isFinite(readAt) && readAt >= command.answeredAt;
}

// A report that shows the command's target, or the shade there already (and not on its way
// elsewhere), may be taken however old.
function agrees(move, blind) {
  if (finite(blind?.target_position) === move.target) return true;
  const position = finite(blind?.position);
  return blind?.moving !== true && position !== null && Math.abs(position - move.target) <= POSITION_TOLERANCE;
}

// The move after a new report from the shade (`readAt`: when that read started, when known): the
// same move (still going), or null when it is over: the shade reported a stop after moving, it is at
// the target, its position changed and then stayed for POSITION_HOLD_MS, or the time is up. A report
// that it is not moving, before it ever said it moves, is taken as not there yet: the controller may
// not have heard of the command, and some shades never report their movement. A report from before
// the command's answer says nothing about the move, unless it agrees with it.
export function followMove(move, blind, now, readAt = null) {
  if (!move || now - move.sentAt >= MOVE_TIMEOUT_MS) return null;
  const next = !move.fresh && readAfter(move, readAt) ? { ...move, fresh: true } : move;
  if (!next.fresh && !agrees(next, blind)) return next;
  if (blind?.moving === true) return next.sawMoving ? next : { ...next, sawMoving: true };
  if (blind?.moving === false && (next.sawMoving || (next.reportsMotion && now - next.sentAt >= MOVE_START_MS))) return null;
  const position = finite(blind?.position);
  if (position === null) return next;
  if (Math.abs(position - next.target) <= POSITION_TOLERANCE) return null;
  if (position === next.from) return next.held ? { ...next, held: null } : next;
  if (next.held?.position !== position) return { ...next, held: { position, since: now } };
  return now - next.held.since >= POSITION_HOLD_MS ? null : next;
}

// The reads after Stop or a move, after a new report from the shade (`readAt` as for followMove):
// null once they are over. After Stop, from the first read after its answer that has the shade
// stopped, the reports show as they are (it may be moved again).
export function followSettle(settle, blind, now, readAt = null) {
  if (!settle || now >= settle.until) return null;
  const shows = readAfter(settle, readAt) && !(settle.stopped && blind?.moving === true);
  return !settle.fresh && shows ? { ...settle, fresh: true } : settle;
}

// What comes after a move that ended: a few more reads, for the position the shade reports after
// its stop (none after a move that timed out).
export function afterMove(move, now) {
  return move && now - move.sentAt < MOVE_TIMEOUT_MS ? startSettle(now) : null;
}

// A shade that reports moving is read every MOVE_POLL_MS, but not for longer than a move takes:
// `since`, when it was first seen moving without a break.
export function followsReport(blind, since, now) {
  return blind?.moving === true && !(Number.isFinite(since) && now - since >= MOVE_TIMEOUT_MS);
}

// What a shade's row shows: { moving, direction, target, slider }. While it moves (it says so, or
// a command was just sent) the slider stays on the target; at rest it is the reported position.
// `move`: the app's command (startMove), or the reads after Stop (startSettle), during which the
// shade shows as stopped until a read after the Stop's answer has it stopped.
export function shadeView(blind, move = null) {
  const position = finite(blind?.position);
  const rest = { moving: false, direction: null, target: null, slider: position ?? 0 };
  if (move?.settle) {
    if (!move.fresh) return rest;
    move = null;
  }
  const reportsMoving = blind?.moving === true;
  if (!reportsMoving && !move) return rest;
  const reported = reportsMoving && (!move || move.fresh || agrees(move, blind));
  const target = (reported ? finite(blind.target_position) : null) ?? (move ? move.target : null);
  const direction = (reported && blind.direction) || move?.direction || directionTo(position, target);
  return { moving: true, direction: direction || null, target, slider: target ?? position ?? 0 };
}

// The words for a moving shade, as a translation key and its percent: "Opening… to 53%", or just
// "Opening…" when it opens fully or where it goes is not known.
export function movingText(view) {
  const verb = view.direction === "opening" ? "opening" : view.direction === "closing" ? "closing" : "moving";
  const fully = (verb === "opening" && view.target === 100) || (verb === "closing" && view.target === 0);
  if (!Number.isFinite(view.target) || fully) return { key: `blinds.${verb}` };
  return { key: `blinds.${verb}To`, percent: view.target };
}

// Scenes: the position Copy the house gives a shade (null when not known). One that only opens and
// closes fully takes 0 or 100: stopped halfway (from a keypad), it goes to the nearer one.
export function scenePosition(blind) {
  if (!Number.isFinite(blind?.position)) return null;
  const position = Math.max(0, Math.min(100, Math.round(blind.position)));
  return canSetPosition(blind) ? position : position >= 50 ? 100 : 0;
}

// What a scene action can do with these shades: open and close, and a position when one of them
// can go to one.
export function sceneBlindChoices(blinds) {
  return (blinds || []).some(canSetPosition) ? ["open", "close", "set"] : ["open", "close"];
}
