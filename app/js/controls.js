// Device commands. Every control updates the screen at once (optimistic), sends the PATCH
// (answered 202 with the last reported state), then re-reads the device until the controller
// confirms it. A failed command reverts the change and shows a short error on the device.
// Blinds follow their move instead, which takes far longer (see the blinds section).

import { t } from "./i18n.js";
import { api, errorText, handleUnauthorized, noteForbidden } from "./session.js";
import { activeSetpoint, isDual, sameTemperature, withSetpoint } from "./setpoints.js";
import { MOVE_POLL_MS, STOP_SETTLE_MS, followMove, startMove } from "./shades.js";
import { KINDS, can, clearError, deviceKey, findDevice, notify, replaceDevice, setError, state, subscribe, ui } from "./state.js";

const CONFIRM_MS = 5000;
const sleep = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));

function setPending(key, on) {
  if (on) {
    state.pending = { ...state.pending, [key]: (state.pending[key] || 0) + 1 };
  } else {
    const count = (state.pending[key] || 1) - 1;
    const { [key]: _removed, ...rest } = state.pending;
    state.pending = count > 0 ? { ...rest, [key]: count } : rest;
  }
}

function lightChangeConfirmed(light, change) {
  if ("brightness" in change) {
    return Number.isFinite(light.brightness) && Math.abs(light.brightness - change.brightness) <= 3;
  }
  return light.on === change.on;
}

const TEMPERATURE_FIELDS = ["target_temperature", "heat_setpoint", "cool_setpoint"];

function thermostatChangeConfirmed(thermostat, change) {
  return Object.entries(change).every(([field, value]) =>
    TEMPERATURE_FIELDS.includes(field) ? sameTemperature(thermostat[field], value) : thermostat[field] === value
  );
}

const CONFIRMERS = {
  light: lightChangeConfirmed,
  thermostat: thermostatChangeConfirmed,
};

// Re-reads the device until it reports the change (or 5 s pass). Returns the last state read.
async function waitForConfirmation(kind, id, change) {
  const deadline = Date.now() + CONFIRM_MS;
  let last = null;
  while (Date.now() < deadline) {
    await sleep(600);
    last = await api(`${KINDS[kind].path}/${id}`);
    if (CONFIRMERS[kind](last, change)) {
      return { device: last, confirmed: true };
    }
  }
  return { device: last, confirmed: false };
}

// Lights keep the name the tests look for.
export function waitForLightConfirmation(lightId, change) {
  return waitForConfirmation("light", lightId, change);
}

function optimistic(kind, device, change) {
  if (kind === "light") {
    if ("brightness" in change) {
      return { ...device, brightness: change.brightness, on: change.brightness > 0 };
    }
    return { ...device, on: change.on, brightness: change.on ? device.brightness : device.dimmable ? 0 : null };
  }
  const next = { ...device, ...change };
  // With heat and cool setpoints, the target is the setpoint of the mode (a new mode, or new setpoints).
  if (kind === "thermostat" && isDual(next)) next.target_temperature = activeSetpoint(next);
  return next;
}

// before: the device as it was before the first of a series of quick changes (e.g. + + +).
export async function sendChange(kind, id, change, { before } = {}) {
  const key = deviceKey(kind, id);
  const current = findDevice(kind, id);
  if (!current || !can("member")) return;
  const original = before || current;
  const needsConfirmation = !(kind === "light" && "brightness" in change && !current.brightness_reported);

  if (kind === "light" && "brightness" in change) {
    state.sentBrightness = { ...state.sentBrightness, [id]: change.brightness };
  }
  replaceDevice(kind, optimistic(kind, current, change));
  clearError(key);
  setPending(key, true);
  notify();

  try {
    const answer = await api(`${KINDS[kind].path}/${id}`, { method: "PATCH", body: change });
    if (needsConfirmation) {
      const { device, confirmed } = await waitForConfirmation(kind, id, change);
      if (device && confirmed) {
        replaceDevice(kind, device);
      } else if (!confirmed) {
        // Sent, but not reported back yet: keep what was sent and say so.
        setError(key, t("errors.notConfirmed"));
      }
    } else if (answer && typeof answer === "object" && answer.id === id) {
      replaceDevice(kind, { ...answer, brightness: change.brightness, on: change.brightness > 0 });
    }
  } catch (error) {
    if (error?.status === 401) {
      handleUnauthorized(error);
      return;
    }
    noteForbidden(error);
    const now = findDevice(kind, id);
    if (now) {
      const reverted = { ...now };
      for (const field of Object.keys(optimistic(kind, original, change))) {
        reverted[field] = original[field];
      }
      replaceDevice(kind, reverted);
    }
    if (kind === "light" && "brightness" in change) {
      const { [id]: _removed, ...rest } = state.sentBrightness;
      state.sentBrightness = rest;
    }
    setError(key, errorText(error) || t("errors.commandFailed"));
  } finally {
    setPending(key, false);
    notify();
  }
}

export function setLight(light, change) {
  return sendChange("light", light.id, change);
}

// Target temperature − / +: the screen follows every tap; the command goes out once the
// taps stop, so five quick taps send one PATCH.
const nudges = new Map();

// What one tap on − / + changes: { field: value }, plus the other setpoint when a heat or cool
// setpoint pushes it to keep the thermostat's gap; null when the tap changes nothing (at a limit).
// `shown`: the thermostat with the values the taps so far have reached.
export function nudgedChange(shown, delta, field = "target_temperature") {
  const from = shown[field];
  const base = Number.isFinite(from)
    ? from
    : Number.isFinite(shown.current_temperature)
      ? Math.round(shown.current_temperature)
      : 22;
  const value = clampTarget(shown, base + delta);
  if (value === from) return null;
  if (field === "target_temperature") return { target_temperature: value };
  const both = withSetpoint(shown, field, value);
  if (!both) return null;
  const change = { [field]: value };
  const other = field === "heat_setpoint" ? "cool_setpoint" : "heat_setpoint";
  if (Number.isFinite(both[other]) && both[other] !== shown[other]) change[other] = both[other];
  return change;
}

// field: "target_temperature", or "heat_setpoint" / "cool_setpoint" on a thermostat with both.
export function nudgeTarget(thermostat, delta, field = "target_temperature") {
  const id = thermostat.id;
  const current = findDevice("thermostat", id);
  if (!current || !can("member")) return;
  let entry = nudges.get(id);
  const first = !entry;
  if (first) {
    entry = { before: { ...current }, timer: null, change: {} };
  }
  // During a series of taps, from the values they have reached: a confirmation of another change
  // (fan, mode) may have put the controller's older values back on screen meanwhile.
  const change = nudgedChange({ ...current, ...entry.change }, delta, field);
  if (!change) {
    return;
  }
  entry.change = { ...entry.change, ...change };
  replaceDevice("thermostat", optimistic("thermostat", current, entry.change));
  if (first) {
    setPending(deviceKey("thermostat", id), true);
  }
  notify();
  window.clearTimeout(entry.timer);
  entry.timer = window.setTimeout(async () => {
    nudges.delete(id);
    const latest = findDevice("thermostat", id);
    setPending(deviceKey("thermostat", id), false);
    if (latest) {
      // One PATCH with everything the taps changed, e.g. { heat_setpoint, cool_setpoint } after a push.
      await sendChange("thermostat", id, entry.change, { before: entry.before });
    }
  }, 700);
  nudges.set(id, entry);
}

export function clampTarget(thermostat, value) {
  const min = Number.isFinite(thermostat.target_temperature_min) ? thermostat.target_temperature_min : 10;
  const max = Number.isFinite(thermostat.target_temperature_max) ? thermostat.target_temperature_max : 32;
  return Math.min(max, Math.max(min, Math.round(value * 2) / 2));
}

export function setThermostat(thermostat, change) {
  return sendChange("thermostat", thermostat.id, change);
}

// ---- blinds -------------------------------------------------------------------------------------
// A shade takes 10 to 70 seconds to get where it was sent, and the controller may report the
// position it left until it stops. After a command the app shows where the shade goes (shades.js),
// reads the blinds every 2 s while one moves (also one someone else set moving), and shows the
// reported position once it has stopped.

const moves = new Map(); // blind id -> the move the app expects (shades.js startMove)
const reportsMotion = new Set(); // blinds seen reporting moving: their stops can be believed
const settling = new Map(); // blind id -> until when to keep reading after Stop
const lastCommand = new Map(); // blind id -> number of the last command sent to it
let movePoll = null;

export function blindMove(id) {
  return moves.get(Number(id)) || null;
}

// A move starting or ending changes the screen without new data from the controller: ui.tick
// makes the next render draw it.
function setMove(id, move) {
  const had = moves.has(id);
  if (move) moves.set(id, move);
  else moves.delete(id);
  if (move || had) ui.tick += 1;
}

// Every read of the blinds takes each move along (or ends it).
function followBlinds(now = Date.now()) {
  for (const blind of state.blinds) {
    if (blind.moving === true) reportsMotion.add(blind.id);
    const move = moves.get(blind.id);
    if (!move) continue;
    const next = followMove(move, blind, now);
    if (next !== move) setMove(blind.id, next);
  }
  for (const [id, until] of settling) {
    if (until <= now) settling.delete(id);
  }
}

function blindsMoving() {
  return moves.size > 0 || settling.size > 0 || state.blinds.some((blind) => blind.moving === true);
}

function scheduleMovePoll() {
  if (movePoll || !state.apiKey || state.status !== "connected" || document.hidden || !blindsMoving()) return;
  movePoll = window.setTimeout(async () => {
    try {
      const list = await api(KINDS.blind.path);
      if (Array.isArray(list?.items)) state.blinds = list.items;
    } catch (error) {
      if (error?.status === 401) handleUnauthorized(error);
      // Otherwise the next read, or the refresh every 10 s, catches up.
    } finally {
      movePoll = null;
      followBlinds();
      notify();
      scheduleMovePoll();
    }
  }, MOVE_POLL_MS);
}

// Reads made elsewhere (the refresh every 10 s, a page coming back into view) count too: a shade
// someone else set moving is then read every 2 s until it stops.
subscribe(() => {
  followBlinds();
  scheduleMovePoll();
});

function blindErrorText(error) {
  if (error?.code === "POSITION_NOT_SUPPORTED") return t("blinds.positionNotSupported");
  if (error?.code === "STOP_NOT_SUPPORTED") return t("blinds.stopNotSupported");
  return errorText(error) || t("errors.commandFailed");
}

// The command's answer is the shade as last reported, from before it heard of the command.
function useAnswer(id, answer) {
  if (answer && typeof answer === "object" && answer.id === id) replaceDevice("blind", answer);
}

// Sends a command to blind `id`. When it fails, `undo` puts the move back as it was, unless a newer
// command to the same blind was sent meanwhile.
async function blindCommand(id, path, options, undo) {
  const key = deviceKey("blind", id);
  const number = (lastCommand.get(id) || 0) + 1;
  lastCommand.set(id, number);
  try {
    useAnswer(id, await api(path, options));
  } catch (error) {
    if (lastCommand.get(id) === number) undo();
    if (error?.status === 401) {
      handleUnauthorized(error);
      return;
    }
    noteForbidden(error);
    setError(key, blindErrorText(error));
    // The shade's setup changed since the app read it: read it again for the right controls.
    if (error?.status === 409) {
      api(`${KINDS.blind.path}/${id}`).then(
        (fresh) => {
          useAnswer(id, fresh);
          notify();
        },
        () => {}
      );
    }
  } finally {
    notify();
    scheduleMovePoll();
  }
}

export function setBlind(blind, position) {
  const current = findDevice("blind", blind.id);
  if (!current || !can("member")) return Promise.resolve();
  const id = current.id;
  const previous = moves.get(id) || null;
  setMove(id, startMove(current, position, Date.now(), reportsMotion.has(id)));
  settling.delete(id);
  clearError(deviceKey("blind", id));
  notify();
  return blindCommand(id, `${KINDS.blind.path}/${id}`, { method: "PATCH", body: { position } }, () => setMove(id, previous));
}

// It stops where it is: the app shows what the shade reports, and reads it for a few seconds.
export function stopBlind(blind) {
  if (!can("member")) return Promise.resolve();
  const id = blind.id;
  const move = moves.get(id) || null;
  setMove(id, null);
  settling.set(id, Date.now() + STOP_SETTLE_MS);
  clearError(deviceKey("blind", id));
  notify();
  return blindCommand(id, `${KINDS.blind.path}/${id}/stop`, { method: "POST" }, () => {
    settling.delete(id);
    setMove(id, move);
  });
}

// Room "All off": lights off and air conditioning off.
export function allOff(group) {
  const commands = [];
  for (const light of group.lights) {
    if (light.on) commands.push(setLight(light, { on: false }));
  }
  for (const thermostat of group.thermostats) {
    if (thermostat.mode && thermostat.mode !== "off" && thermostat.modes.includes("off")) {
      commands.push(setThermostat(thermostat, { mode: "off" }));
    }
  }
  return Promise.all(commands);
}

// Doors and gates, and the gate at a doorbell: the Open button asks for a second tap within a
// few seconds, then sends the command and shows "Opening…" / "Sent". Relays pulse
// (POST /v1/relays/{id}/pulse); doorbells press their button (POST /v1/doorbells/{id}/open).
const stageTimers = new Map();

function setStage(map, id, stage, clearAfter) {
  const timerKey = `${map}:${id}`;
  window.clearTimeout(stageTimers.get(timerKey));
  if (stage) {
    ui[map] = { ...ui[map], [id]: stage };
  } else {
    const { [id]: _removed, ...rest } = ui[map];
    ui[map] = rest;
  }
  if (clearAfter) {
    stageTimers.set(timerKey, window.setTimeout(() => setStage(map, id, null), clearAfter));
  }
  notify();
}

async function pressOpen({ map, kind, id, path, onDone }) {
  const stage = ui[map][id];
  if (stage === "sending" || !can("doors")) {
    return;
  }
  if (stage !== "confirm") {
    clearError(deviceKey(kind, id));
    setStage(map, id, "confirm", 5000);
    return;
  }
  setStage(map, id, "sending");
  try {
    const result = await api(path, { method: "POST" });
    if (onDone) onDone(result);
    setStage(map, id, "sent", 3000);
  } catch (error) {
    if (error?.status === 401) {
      handleUnauthorized(error);
      return;
    }
    setStage(map, id, null);
    noteForbidden(error);
    setError(deviceKey(kind, id), errorText(error));
  }
}

export function cancelRelay(relay) {
  setStage("relayStage", relay.id, null);
}

export function pressRelay(relay) {
  return pressOpen({ map: "relayStage", kind: "relay", id: relay.id, path: `/v1/relays/${relay.id}/pulse` });
}

export function cancelDoorbell(doorbell) {
  setStage("doorbellStage", doorbell.id, null);
}

// The 202 answer is the doorbell as last reported.
export function pressDoorbell(doorbell) {
  return pressOpen({
    map: "doorbellStage",
    kind: "doorbell",
    id: doorbell.id,
    path: `/v1/doorbells/${doorbell.id}/open`,
    onDone: (updated) => {
      if (updated && typeof updated === "object" && updated.id === doorbell.id) replaceDevice("doorbell", updated);
    },
  });
}
