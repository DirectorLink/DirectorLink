// Home's "Turn off all" (1.3.0). In the rooms a summary chip filters (lights on, AC on, blinds
// open), one button turns off those lights or AC, or closes those blinds: the ones on or open in
// the rooms the list shows at that moment (rooms this person hides are left alone). A second tap
// within 5 seconds runs it, like the Open button of doors; there is no undo. One request does it
// all (POST /v1/off, members and above), as quick through the account as at home; drivers before
// 1.3.0 get each device's own command, all at once.

import { blindMove, optimistic, sendingBlinds, setStage } from "./controls.js";
import { t } from "./i18n.js";
import { blindIsOpen, climateIsOn, lightIsOn, matchesFilter, visibleRooms } from "./model.js";
import { api, errorText, handleUnauthorized, keyGeneration, noteForbidden, refreshDevices } from "./session.js";
import { shadeView } from "./shades.js";
import { KINDS, can, findDevice, replaceDevice, ui } from "./state.js";

export const OFF_FILTERS = ["lights", "climate", "blinds"];
const CONFIRM_MS = 5000; // the second tap, as for doors and gates (controls.js)
const DONE_MS = 4000; // "Done", as after a scene
const FAILED_MS = 15000; // what did not turn off: long enough to read the names
const REFRESH_MS = 1500; // then the devices are read again, as after a scene
export const MAX_NAMED = 8; // devices named in "… didn't turn off: …"; more are counted

// Per filter: the room group's list, the kind of device, and what each one gets.
const TYPES = {
  lights: { group: "lights", kind: "light", change: { on: false } },
  climate: { group: "thermostats", kind: "thermostat", change: { mode: "off" } },
  blinds: { group: "blinds", kind: "blind", change: { position: 0 } },
};

// A thermostat that is on and can be switched off (one without an Off mode is left as it is).
function canTurnOff(thermostat) {
  return climateIsOn(thermostat) && (thermostat.modes || []).includes("off");
}

// A blind that is open and not already on its way to closed.
function canClose(blind) {
  if (!blindIsOpen(blind)) return false;
  const view = shadeView(blind, blindMove(blind.id));
  return !(view.moving && view.target === 0);
}

const TO_TURN_OFF = { lights: lightIsOn, climate: canTurnOff, blinds: canClose };

// The devices the button acts on now: on or open, in the rooms the filtered list shows.
export function offTargets(filter) {
  const type = TYPES[filter];
  if (!type) return [];
  return visibleRooms()
    .filter(({ group }) => matchesFilter(group, filter))
    .flatMap(({ group }) => group[type.group].filter(TO_TURN_OFF[filter]));
}

// First tap: asks for a second one within 5 seconds. Second tap: turns them off.
export function pressTurnOff(filter) {
  if (!TYPES[filter] || !can("member")) return Promise.resolve();
  const stage = ui.offRuns[filter]?.stage;
  if (stage === "running") return Promise.resolve();
  if (stage !== "confirm") {
    if (offTargets(filter).length) setStage("offRuns", filter, { stage: "confirm" }, CONFIRM_MS);
    return Promise.resolve();
  }
  return turnOff(filter);
}

export function cancelTurnOff(filter) {
  if (ui.offRuns[filter]?.stage === "confirm") setStage("offRuns", filter, null);
}

// Another filter, or none: a second tap waiting, or a result shown, goes (a run on its way stays).
export function resetTurnOff() {
  for (const filter of Object.keys(ui.offRuns)) {
    if (ui.offRuns[filter]?.stage !== "running") setStage("offRuns", filter, null);
  }
}

// Sends the command: one request, or each device's own with a driver before 1.3.0 (404). Returns
// the devices that did not turn off: their ids, and how many (a long list names only some).
async function sendOff(filter, targets) {
  try {
    const result = await api("/v1/off", { method: "POST", body: { type: filter, device_ids: targets.map((device) => device.id) } });
    const problems = (result?.problems || []).filter((problem) => problem.outcome === "failed" || problem.outcome === "skipped");
    const ids = new Set(problems.map((problem) => problem.device_id));
    return { ids, count: Math.max(ids.size, (Number(result?.failed) || 0) + (Number(result?.skipped) || 0)) };
  } catch (error) {
    if (error?.status !== 404 && error?.status !== 405) throw error;
  }
  const { kind, change } = TYPES[filter];
  const answers = await Promise.allSettled(targets.map((device) => api(`${KINDS[kind].path}/${device.id}`, { method: "PATCH", body: change })));
  const refusals = answers.filter((answer) => answer.status === "rejected").map((answer) => answer.reason);
  const unauthorized = refusals.find((error) => error?.status === 401);
  if (unauthorized) throw unauthorized;
  // None went: say why, as for one request.
  if (refusals.length === targets.length) throw refusals[0];
  const ids = new Set(targets.filter((_device, index) => answers[index].status === "rejected").map((device) => device.id));
  return { ids, count: ids.size };
}

// Runs it at once: the second tap, or a command's own confirm (commands.js, ADR-063). What it did
// is in ui.offRuns[filter] afterwards.
export async function turnOffNow(filter) {
  if (!TYPES[filter] || !can("member") || ui.offRuns[filter]?.stage === "running") return;
  await turnOff(filter);
}

async function turnOff(filter) {
  const type = TYPES[filter];
  const targets = offTargets(filter);
  if (!targets.length) {
    setStage("offRuns", filter, null);
    return;
  }
  setStage("offRuns", filter, { stage: "running" });
  // Blinds show "Closing…" at once, and are read every 2 s until they stop (controls.js).
  const blindsAnswered = filter === "blinds" ? sendingBlinds(targets, 0) : null;
  const since = keyGeneration();
  let refused;
  try {
    refused = await sendOff(filter, targets);
  } catch (error) {
    blindsAnswered?.(new Set(targets.map((device) => device.id)));
    if (since !== keyGeneration() || error?.status === 401) {
      setStage("offRuns", filter, null);
      if (since === keyGeneration()) handleUnauthorized(error);
      return;
    }
    noteForbidden(error);
    setStage("offRuns", filter, { stage: "error", text: t(`home.off.error.${filter}`, { error: errorText(error) }) }, FAILED_MS);
    return;
  }
  if (since !== keyGeneration()) {
    setStage("offRuns", filter, null);
    return;
  }
  blindsAnswered?.(refused.ids);
  // Lights and AC show off at once; the read that follows shows what the controller reports.
  if (type.kind !== "blind") {
    for (const device of targets) {
      const current = findDevice(type.kind, device.id);
      if (current && !refused.ids.has(device.id)) replaceDevice(type.kind, optimistic(type.kind, current, type.change));
    }
  }
  window.setTimeout(() => refreshDevices(), REFRESH_MS);
  if (!refused.count) {
    setStage("offRuns", filter, { stage: "done" }, DONE_MS);
    return;
  }
  const failed = targets.filter((device) => refused.ids.has(device.id));
  const named = failed.slice(0, MAX_NAMED).map((device) => ({ id: device.id, name: device.name, room: device.room || null }));
  setStage("offRuns", filter, { stage: "partial", count: refused.count, failed: named, more: refused.count - named.length }, FAILED_MS);
}
