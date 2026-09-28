// Device commands. Every control updates the screen at once (optimistic), sends the PATCH
// (answered 202 with the last reported state), then re-reads the device until the controller
// confirms it. A failed command reverts the change and shows a short error on the device.

import { t } from "./i18n.js";
import { api, errorText, handleUnauthorized, noteForbidden } from "./session.js";
import { KINDS, can, clearError, deviceKey, findDevice, notify, replaceDevice, setError, state, ui } from "./state.js";

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

function thermostatChangeConfirmed(thermostat, change) {
  return Object.entries(change).every(([field, value]) =>
    field === "target_temperature"
      ? Number.isFinite(thermostat.target_temperature) && Math.abs(thermostat.target_temperature - value) < 0.3
      : thermostat[field] === value
  );
}

function blindChangeConfirmed(blind, change) {
  return Number.isFinite(blind.position) && Math.abs(blind.position - change.position) <= 3;
}

const CONFIRMERS = {
  light: lightChangeConfirmed,
  thermostat: thermostatChangeConfirmed,
  blind: blindChangeConfirmed,
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
  return { ...device, ...change };
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
      if (device && (confirmed || kind === "blind")) {
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

export function nudgeTarget(thermostat, delta) {
  const id = thermostat.id;
  const current = findDevice("thermostat", id);
  if (!current || !can("member")) return;
  let entry = nudges.get(id);
  const first = !entry;
  if (first) {
    entry = { before: { ...current }, timer: null };
  }
  const base = Number.isFinite(current.target_temperature)
    ? current.target_temperature
    : Number.isFinite(current.current_temperature)
      ? Math.round(current.current_temperature)
      : 22;
  const target = clampTarget(current, base + delta);
  if (target === current.target_temperature) {
    return;
  }
  replaceDevice("thermostat", { ...current, target_temperature: target });
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
      await sendChange("thermostat", id, { target_temperature: latest.target_temperature }, { before: entry.before });
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

export function setBlind(blind, position) {
  return sendChange("blind", blind.id, { position });
}

export async function stopBlind(blind) {
  if (!can("member")) return;
  const key = deviceKey("blind", blind.id);
  clearError(key);
  try {
    await api(`/v1/blinds/${blind.id}/stop`, { method: "POST" });
    await sleep(600);
    replaceDevice("blind", await api(`/v1/blinds/${blind.id}`));
  } catch (error) {
    if (error?.status === 401) {
      handleUnauthorized(error);
      return;
    }
    noteForbidden(error);
    setError(key, errorText(error));
  }
  notify();
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
