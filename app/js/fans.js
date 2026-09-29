// Fans (the Control4 fan proxy, DirectorLink 1.2.0 and newer): on, off and a speed from 1 (low) to
// 4 (high). The API reports `on`, `speed` (null while the fan is off, or when the controller reports
// no speed) and `speeds`, the ones PATCH takes. Off is {"on": false}; a speed turns the fan on.
// No imports, so the rules can be tested under Node (tests/app/fans.test.mjs).

// The speeds' names, lowest first (fans.speeds.* in the dictionaries), for the fan proxy's 1 to 4.
export const SPEED_NAMES = ["low", "medium", "mediumHigh", "high"];

// The speeds this fan takes, lowest first: the ones it reports, else the fan proxy's four.
export function fanSpeeds(fan) {
  if (!Array.isArray(fan?.speeds)) return [1, 2, 3, 4];
  return fan.speeds.filter((speed) => Number.isInteger(speed) && speed >= 1).sort((a, b) => a - b);
}

// The speed control's value: 0 while off, the speed while on, null while on at a speed not reported.
export function fanLevel(fan) {
  if (!fan?.on) return 0;
  return Number.isInteger(fan.speed) ? fan.speed : null;
}

// What choosing a level (0 off, else a speed) asks the controller for.
export function levelChange(level) {
  return level === 0 ? { on: false } : { speed: level };
}

// The fan reports what `change` asked for: on at that speed, or on or off.
export function fanChangeConfirmed(fan, change) {
  if ("speed" in change) return fan?.on === true && fan.speed === change.speed;
  return fan?.on === change.on;
}

// The fan as the screen shows it while `change` is on its way. Turned on, it keeps the speed it
// reported: the fan picks its own (its preset speed, or the last one).
export function optimisticFan(fan, change) {
  if ("speed" in change) return { ...fan, on: true, speed: change.speed };
  return { ...fan, on: change.on, speed: change.on ? fan.speed : null };
}

// What a scene step keeps of a fan as it is now ("Copy the house"): off, its speed, or just on
// when it reports no speed it takes.
export function sceneSet(fan) {
  if (!fan?.on) return { on: false };
  return Number.isInteger(fan.speed) && fanSpeeds(fan).includes(fan.speed) ? { speed: fan.speed } : { on: true };
}
