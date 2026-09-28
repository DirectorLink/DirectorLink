// Scenes (docs/SCENES.md): the home's one-tap actions, kept on the controller. Everyone sees them,
// members run them, admins make and change them (views/scenes.js). A step sets devices of one
// type: the ones it names, or all of them in a room or the whole home.

import { formatTemperature, t } from "./i18n.js";
import { deviceRoomId, fanLabel, modeLabel, roomById, roomName, shownBrightness } from "./model.js";
import { api, errorText, noteForbidden, refreshDevices } from "./session.js";
import { notify, state, ui } from "./state.js";

export const SCENE_ICONS = ["bulb", "moon", "sun", "leave", "movie", "climate", "blinds", "home"];
export const STEP_TYPES = ["lights", "climate", "blinds", "relays"];
export const STEP_ICONS = { lights: "bulb", climate: "climate", blinds: "blinds", relays: "door" };
const LISTS = { lights: "lights", climate: "thermostats", blinds: "blinds", relays: "relays" };
const RESULT_MS = 4000;

export function devicesOfType(type) {
  return state[LISTS[type]] || [];
}

// After connecting and every minute: the home's scenes. Drivers before 0.13.0 have none.
export async function loadScenes() {
  try {
    const answer = await api("/v1/scenes");
    state.scenes = Array.isArray(answer?.items) ? answer.items : [];
    state.scenesUnsupported = false;
  } catch (error) {
    if (error?.status === 404 || error?.status === 405) {
      state.scenes = [];
      state.scenesUnsupported = true;
    }
    // Otherwise the last list stays; the device refresh reports connection problems.
  }
  notify();
}

export function findScene(id) {
  return (state.scenes || []).find((scene) => scene.id === id) || null;
}

// ---- describing steps ----------------------------------------------------------------------

// The devices a step works on now: the ones it names that still exist, or all in its room.
export function stepDevices(step) {
  const list = devicesOfType(step.type);
  if (Array.isArray(step.device_ids)) {
    return step.device_ids.map((id) => list.find((device) => device.id === id)).filter(Boolean);
  }
  return list.filter((device) => step.room_id == null || deviceRoomId(device) === step.room_id);
}

export function stepWhat(step) {
  if (!Array.isArray(step.device_ids)) return t(`scenes.all.${step.type}`);
  if (step.device_ids.length === 1) {
    const device = devicesOfType(step.type).find((item) => item.id === step.device_ids[0]);
    if (device) return device.name;
  }
  return t(`scenes.count.${step.type}`, { count: step.device_ids.length });
}

export function stepWhere(step) {
  if (step.room_id != null) {
    const room = roomById(step.room_id);
    return room ? roomName(room) : t("scenes.roomGone");
  }
  if (!Array.isArray(step.device_ids)) return t("scenes.wholeHome");
  const rooms = new Set(stepDevices(step).map(deviceRoomId));
  if (rooms.size === 1) {
    const room = roomById([...rooms][0]);
    return room ? roomName(room) : "";
  }
  return t("scenes.severalRooms");
}

export function stepAction(step) {
  const set = step.set || {};
  if (step.type === "lights") {
    if (set.on === false || set.brightness === 0) return t("scenes.do.off");
    if (Number.isFinite(set.brightness)) return t("scenes.do.dimTo", { percent: set.brightness });
    return t("scenes.do.on");
  }
  if (step.type === "climate") {
    if (set.mode === "off") return t("scenes.do.off");
    return [
      set.mode ? modeLabel(set.mode) : null,
      Number.isFinite(set.target_temperature) ? formatTemperature(set.target_temperature) : null,
      set.fan_speed ? t("scenes.do.fan", { speed: fanLabel(set.fan_speed) }) : null,
    ]
      .filter(Boolean)
      .join(", ");
  }
  if (step.type === "blinds") {
    if (set.position >= 100) return t("scenes.do.open");
    if (set.position <= 0) return t("scenes.do.close");
    return t("scenes.do.position", { percent: set.position });
  }
  return set.state === "open" ? t("scenes.do.open") : t("scenes.do.close");
}

// "All lights: Off · Parents: Cool, 24° · +2 more"
export function sceneSummary(scene) {
  const steps = scene.steps || [];
  if (!steps.length) return t("scenes.noSteps");
  const parts = steps.slice(0, 3).map((step) => {
    const what = step.room_id != null && !Array.isArray(step.device_ids) ? t(`scenes.inRoom.${step.type}`, { room: stepWhere(step) }) : stepWhat(step);
    return `${what}: ${stepAction(step)}`;
  });
  if (steps.length > 3) parts.push(t("scenes.more", { count: steps.length - 3 }));
  return parts.join(" · ");
}

// ---- running -------------------------------------------------------------------------------

// What a run did, in one line (the controller says why devices were skipped).
export function resultText(result) {
  if (result.failed > 0) return t("scenes.result.failed", { count: result.failed });
  if (result.skipped > 0) {
    const codes = new Set((result.problems || []).map((problem) => problem.code));
    if (codes.size === 1 && codes.has("FORBIDDEN")) return t("scenes.result.doors");
    if (codes.size === 1 && codes.has("DOOR_CONTROL_DISABLED")) return t("scenes.result.doorControl");
    return t("scenes.result.skipped", { count: result.skipped });
  }
  return t("scenes.result.done");
}

function setRun(id, value) {
  ui.sceneRuns = { ...ui.sceneRuns, [id]: value };
  notify();
}

// Runs a saved scene; the button shows what happened for a few seconds, then the devices'
// new state is read.
export async function runScene(scene) {
  if (ui.sceneRuns[scene.id]?.stage === "running") return;
  setRun(scene.id, { stage: "running" });
  let outcome;
  try {
    const result = await api(`/v1/scenes/${scene.id}/run`, { method: "POST" });
    outcome = { stage: result.failed > 0 || result.skipped > 0 ? "partial" : "done", text: resultText(result) };
  } catch (error) {
    noteForbidden(error);
    outcome = { stage: "error", text: t("scenes.result.error", { error: errorText(error) }) };
  }
  const stamp = Date.now();
  setRun(scene.id, { ...outcome, stamp });
  window.setTimeout(() => refreshDevices(), 1500);
  window.setTimeout(() => {
    if (ui.sceneRuns[scene.id]?.stamp === stamp) {
      const { [scene.id]: _done, ...rest } = ui.sceneRuns;
      ui.sceneRuns = rest;
      notify();
    }
  }, RESULT_MS);
}

// ---- copying the house ---------------------------------------------------------------------

// Steps that put every light, AC and blind back the way they are now. Devices set alike share a
// step; doors and gates are left out.
export function copyHouse() {
  const groups = new Map();
  const add = (type, set, id) => {
    const key = `${type}:${JSON.stringify(set)}`;
    if (!groups.has(key)) groups.set(key, { type, room_id: null, device_ids: [], set });
    groups.get(key).device_ids.push(id);
  };
  for (const light of state.lights) {
    if (!light.on) add("lights", { on: false }, light.id);
    else if (light.dimmable && Number.isFinite(shownBrightness(light))) add("lights", { brightness: Math.round(shownBrightness(light)) }, light.id);
    else add("lights", { on: true }, light.id);
  }
  const steps = [...groups.values()];
  for (const thermostat of state.thermostats) {
    const set = {};
    const modes = thermostat.modes || [];
    if (thermostat.mode && modes.includes(thermostat.mode)) set.mode = thermostat.mode;
    if (set.mode !== "off") {
      if (Number.isFinite(thermostat.target_temperature)) set.target_temperature = thermostat.target_temperature;
      if (thermostat.fan_speed && (thermostat.fan_speeds || []).includes(thermostat.fan_speed)) set.fan_speed = thermostat.fan_speed;
    }
    if (Object.keys(set).length) steps.push({ type: "climate", room_id: null, device_ids: [thermostat.id], set });
  }
  groups.clear();
  for (const blind of state.blinds) {
    if (Number.isFinite(blind.position)) add("blinds", { position: Math.round(blind.position) }, blind.id);
  }
  steps.push(...groups.values());
  return steps.slice(0, 40);
}
