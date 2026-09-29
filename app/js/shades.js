// Shades, blinds and shutters: which controls a shade gets, and what the app shows while one moves.
// A shade takes 10 to 70 seconds to get where it was sent, and all the while the controller may
// still report the position it left: the app shows where the shade is going instead, and the
// reported position once it stops. No imports, so the rules can be tested under Node
// (tests/app/shades.test.mjs).

// While a shade moves, the app reads the blinds this often.
export const MOVE_POLL_MS = 2000;
// A move the shade never reports as over ends after this long.
export const MOVE_TIMEOUT_MS = 2 * 60 * 1000;
// A shade that reported its movement before and is still not moving this long after a command did
// not move (it was there already, or the command went nowhere).
export const MOVE_START_MS = 8000;
// How far from the target a reported position may be and still count as there.
export const POSITION_TOLERANCE = 2;
// After Stop the app reads the blinds this long, to show where the shade stopped.
export const STOP_SETTLE_MS = 6000;

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
  return { target, direction: directionTo(finite(blind?.position), target), sentAt: now, sawMoving: false, reportsMotion };
}

// The move after a new report from the shade: the same move (still going), or null when it is
// over: the shade reported a stop after moving, it is at the target, or the time is up. A report
// that it is not moving, before it ever said it moves, is taken as not there yet: the controller
// may not have heard of the command, and some shades never report their movement.
export function followMove(move, blind, now) {
  if (!move || now - move.sentAt >= MOVE_TIMEOUT_MS) return null;
  if (blind?.moving === true) return move.sawMoving ? move : { ...move, sawMoving: true };
  if (blind?.moving === false && (move.sawMoving || (move.reportsMotion && now - move.sentAt >= MOVE_START_MS))) return null;
  if (Number.isFinite(blind?.position) && Math.abs(blind.position - move.target) <= POSITION_TOLERANCE) return null;
  return move;
}

// What a shade's row shows: { moving, direction, target, slider }. While it moves (it says so, or
// a command was just sent) the slider stays on the target; at rest it is the reported position.
export function shadeView(blind, move = null) {
  const position = finite(blind?.position);
  const reportsMoving = blind?.moving === true;
  if (!reportsMoving && !move) {
    return { moving: false, direction: null, target: null, slider: position ?? 0 };
  }
  const target = (reportsMoving ? finite(blind.target_position) : null) ?? (move ? move.target : null);
  const direction = (reportsMoving && blind.direction) || move?.direction || directionTo(position, target);
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
