// Say or type a command (1.9.0, ADR-063): what the app does with what js/command-parser.js
// understood. The parser gets only what the controller lists for this user (state.js): their rooms,
// the devices they control, the scenes they may run, their Sonos rooms, and the doors and gates in
// their rooms (to open only with door access). Every action is the same call a tap makes
// (controls.js, music.js, scenes.js, turn-off.js), so the controller decides as for any tap; doors
// and gates, Turn off all and scenes that open doors keep their second tap. The words never leave
// this device. views/command.js shows the field and what this module says.

import { parseCommand } from "./command-parser.js";
import { announce } from "./dom.js";
import { allOff, setBlind, setFan, setLight, setStage, setThermostat, stopBlind } from "./controls.js";
import { currentLanguage, formatTemperature, t } from "./i18n.js";
import { climateIsOn, fanIsOn, lightIsOn, modeLabel, roomById, roomGroup, roomName } from "./model.js";
import { findMusic, musicAvailable, musicCommand, musicKey, musicRooms, setMusicLevels } from "./music.js";
import { findScene, isolate, runScene, sceneOpensDoors } from "./scenes.js";
import { isDual, withSetpoint } from "./setpoints.js";
import { canSetPosition } from "./shades.js";
import { can, deviceKey, findDevice, notify, state, ui } from "./state.js";
import { offTargets, turnOffNow } from "./turn-off.js";

// A result stays this long ("Kitchen: lights off · Done"); a question or a problem until the next
// command. Turn off all's confirm waits this long for its tap.
const RESULT_MS = 8000;
const CONFIRM_MS = 10000;

// What the command area shows: null, or { stage, said, text, options, question, action, stamp }.
// stage: running · done · partial · error · ask · confirm (Turn off all) · door · scene (one that
// opens doors) · problem · unknown · message (from the microphone).
let current = null;
let stamps = 0;

export function commandState() {
  return current;
}

// What a screen reader says of it (views/command.js shows it).
function spoken(shown) {
  if (shown.stage === "ask") return [shown.text, ...shown.labels].join(" ");
  const hint = shown.stage === "door" ? t("relays.confirmHint") : shown.stage === "scene" ? t("scenes.confirmDoors") : "";
  return [shown.said, shown.text, hint].filter(Boolean).join(". ");
}

function show(next) {
  stamps += 1;
  current = next ? { ...next, stamp: stamps } : null;
  if (current && current.stage !== "message") announce(spoken(current));
  notify();
  return current;
}

// After a run: the result, unless another command came meanwhile; a result goes after a while.
function settle(stamp, outcome) {
  if (current?.stamp !== stamp) return;
  current = { ...current, ...outcome };
  announce(outcome.text);
  notify();
  if (outcome.stage === "done") {
    window.setTimeout(() => {
      if (current?.stamp === stamp && current.stage === "done") show(null);
    }, RESULT_MS);
  }
}

export function clearCommand() {
  show(null);
}

// A line from the microphone: Listening…, or why it did not work.
export function commandMessage(text, kind = "info") {
  const shown = show({ stage: "message", text, kind });
  announce(text);
  return shown;
}

// ---- what the parser may name ---------------------------------------------------------------

// The user's own names, from what the controller lists for them.
export function commandCatalog() {
  const control = can("member");
  const rooms = state.rooms.map((room) => ({ id: room.id, names: [room.name, room.names?.en, room.names?.he].filter(Boolean) }));
  const devices = [];
  const add = (kind, list, fields) => {
    for (const device of list || []) devices.push({ kind, id: device.id, name: device.name, room: device.room?.id ?? null, ...fields(device) });
  };
  if (control) {
    add("light", state.lights, (light) => ({ dimmable: light.dimmable !== false, on: Boolean(light.on) }));
    add("thermostat", state.thermostats, (thermostat) => ({
      modes: thermostat.modes || [],
      mode: thermostat.mode || null,
      dual: isDual(thermostat),
      min: thermostat.target_temperature_min,
      max: thermostat.target_temperature_max,
    }));
    add("blind", state.blinds, (blind) => ({ position: canSetPosition(blind) }));
    add("fan", state.fans, (fan) => ({ on: Boolean(fan.on) }));
    // A Sonos room is in the room it is shown in.
    if (musicAvailable()) add("music", musicRooms(), (item) => ({ room: item.room_id ?? null }));
  }
  // Doors and gates in their rooms; opening them needs door access (the parser says so).
  add("relay", state.relays, () => ({ canOpen: can("doors") }));
  add("doorbell", (state.doorbells || []).filter((doorbell) => doorbell.can_open), () => ({ canOpen: can("doors") }));
  const scenes = control ? (state.scenes || []).map((scene) => ({ id: scene.id, name: scene.name })) : [];
  return { rooms, devices, scenes };
}

// ---- words -----------------------------------------------------------------------------------

const LISTS = { light: "lights", thermostat: "thermostats", blind: "blinds", fan: "fans", relay: "relays", doorbell: "doorbells" };

function deviceOf(ref) {
  if (!ref) return null;
  if (ref.kind === "music") return findMusic(ref.id);
  return (state[LISTS[ref.kind]] || []).find((device) => device.id === ref.id) || null;
}

function deviceName(ref) {
  return deviceOf(ref)?.name || "";
}

function placeOf(device) {
  const roomId = device?.room_id ?? device?.room?.id;
  return roomId != null && roomById(roomId) ? roomName(roomById(roomId)) : "";
}

// "in the kitchen" in English, "במטבח" (or "ב-Kitchen") in Hebrew, for the examples.
function inRoom(name) {
  if (currentLanguage() === "he") return /^[א-ת]/.test(name) ? `ב${name}` : `ב-${isolate(name)}`;
  return name;
}

// What an action does, after "{what}: ": "lights off", "AC 23°", "open".
function doing(action) {
  const named = Boolean(action.device);
  const change = action.change || {};
  if (action.type === "lights") {
    const key = named ? "light" : "lights";
    if (change.on === false) return t(`command.do.${key}.off`);
    if (Number.isFinite(change.brightness)) return t(`command.do.${key}.level`, { percent: change.brightness });
    return t(`command.do.${key}.on`);
  }
  if (action.type === "climate") {
    const key = named ? "thermostat" : "climate";
    const temperature = Number.isFinite(change.temperature) ? formatTemperature(change.temperature) : null;
    if (change.mode === "off") return t(`command.do.${key}.off`);
    if (change.setpoint) return t(`command.do.${key}.${change.setpoint}Setpoint`, { temperature });
    if (change.mode && temperature) return t(`command.do.${key}.modeTemperature`, { mode: modeLabel(change.mode), temperature });
    if (change.mode) return t(`command.do.${key}.mode`, { mode: modeLabel(change.mode) });
    return t(`command.do.${key}.temperature`, { temperature });
  }
  if (action.type === "blinds") {
    const key = named ? "blind" : "blinds";
    if (change.stop) return t(`command.do.${key}.stop`);
    if (change.position === 100) return t(`command.do.${key}.open`);
    if (change.position === 0) return t(`command.do.${key}.close`);
    return t(`command.do.${key}.position`, { percent: change.position });
  }
  if (action.type === "fans") return t(`command.do.${named ? "fan" : "fans"}.${change.on ? "on" : "off"}`);
  if (action.type === "music") {
    if (Number.isFinite(change.volume)) return t("command.do.music.volume", { percent: change.volume });
    return t(`command.do.music.${change.action}`);
  }
  if (action.type === "roomOff") return t("command.do.roomOff");
  if (action.type === "door") return t("command.do.door");
  return "";
}

// What the user sees it understood: "Kitchen: lights off", "Porch light: on", "Run Good night",
// "Turn off everything". `withRoom`: a device's room too, to tell apart the options of a question.
export function describe(action, { withRoom = false } = {}) {
  if (action.type === "scene") return t("command.runScene", { name: isolate(findScene(action.id)?.name || "") });
  if (action.type === "offAll") return t(`command.off.${action.filters.length > 1 ? "everything" : action.filters[0]}`);
  let what = "";
  if (action.device) {
    const device = deviceOf(action.device);
    what = deviceName(action.device);
    const place = withRoom ? placeOf(device) : "";
    if (place && place !== what) what = t("command.inPlace", { name: isolate(what), room: isolate(place) });
  } else if (action.room != null) {
    what = roomById(action.room) ? roomName(roomById(action.room)) : "";
  }
  return t("command.said", { what: isolate(what), action: doing(action) });
}

// Examples by this user's own names: a room with lights, a room with AC, a scene.
export function commandExamples() {
  const roomWith = (list) => {
    const id = (list || []).map((device) => device.room?.id).find((roomId) => roomId != null && roomById(roomId));
    return id != null ? roomName(roomById(id)) : null;
  };
  const lights = can("member") ? roomWith(state.lights) : null;
  const climate = can("member") ? roomWith(state.thermostats) : null;
  const scene = can("member") ? (state.scenes || [])[0]?.name : null;
  return [
    lights ? t("command.example.lights", { room: lights, inRoom: inRoom(lights) }) : t("command.example.lightsDefault"),
    climate ? t("command.example.climate", { room: climate, inRoom: inRoom(climate) }) : t("command.example.climateDefault"),
    scene ? t("command.example.scene", { name: scene }) : t("command.example.sceneDefault"),
  ];
}

// The words for what the parser could not do.
function problemText(result) {
  const named = result.device ? deviceName(result.device) : "";
  const room = result.room != null && roomById(result.room) ? roomName(roomById(result.room)) : "";
  const examples = commandExamples();
  switch (result.problem) {
    case "needRoom":
      return t("command.problem.needRoom", { example: examples[result.kind === "climate" ? 1 : 0] });
    case "needWhat":
      return t("command.problem.needWhat", { example: examples[result.kind === "climate" ? 1 : 0] });
    case "needLevel":
      return t(`command.problem.needLevel.${result.kind === "music" ? "music" : "light"}`);
    case "none":
      return room ? t(`command.problem.none.${result.kind}`, { room: isolate(room) }) : t(`command.problem.noneHome.${result.kind}`);
    case "range":
      if (result.unit === "percent") return t("command.problem.rangePercent");
      return t("command.problem.range", { name: isolate(named), min: formatTemperature(result.min), max: formatTemperature(result.max) });
    case "cannotDim":
      return named ? t("command.problem.cannotDim", { name: isolate(named) }) : t("command.problem.cannotDimRoom", { room: isolate(room) });
    case "noPosition":
      return named ? t("command.problem.noPosition", { name: isolate(named) }) : t("command.problem.noPositionRoom", { room: isolate(room) });
    case "noMode":
      return result.mode ? t("command.problem.noMode", { name: isolate(named || room), mode: modeLabel(result.mode) }) : t("command.problem.noModes", { name: isolate(named || room) });
    case "alreadyOn":
      return named ? t("command.problem.alreadyOn", { name: isolate(named) }) : t("command.problem.alreadyOnRoom", { room: isolate(room) });
    case "noDoors":
      return t("command.problem.noDoors");
    case "oneAtATime":
      return t("command.problem.oneAtATime");
    default:
      return t("command.problem.tooMany");
  }
}

// ---- running ---------------------------------------------------------------------------------

// What a series of device commands did, from the errors they left (controls.js shows each on its
// device too).
function outcome(keys, started) {
  const errors = keys.map((key) => state.errors[key]).filter((error) => error && error.stamp >= started);
  if (!errors.length) return { stage: "done", text: t("command.result.done") };
  const failed = errors.filter((error) => error.text !== t("errors.notConfirmed"));
  if (!failed.length) return { stage: "partial", text: t("command.result.notConfirmed") };
  if (failed.length === keys.length) return { stage: "error", text: t("command.result.failed", { error: failed[0].text }) };
  return { stage: "partial", text: t("command.result.someFailed", { count: failed.length, total: keys.length, error: failed[0].text }) };
}

const NOTHING = () => ({ stage: "done", text: t("command.result.nothing") });

// A thermostat's PATCH for a change the parser made: a target temperature, or with heat and cool
// setpoints the one of its mode (or the one named), the other kept apart (setpoints.js); null when
// there is nothing to send.
export function thermostatChange(thermostat, change) {
  if (change.mode === "off" && !climateIsOn(thermostat)) return null;
  const patch = {};
  if (change.mode) patch.mode = change.mode;
  if (Number.isFinite(change.temperature)) {
    if (isDual(thermostat)) {
      const mode = change.mode || thermostat.mode;
      const field = change.setpoint ? `${change.setpoint}_setpoint` : mode === "heat" ? "heat_setpoint" : mode === "cool" ? "cool_setpoint" : null;
      const both = field ? withSetpoint(thermostat, field, change.temperature) : null;
      if (!both) return null;
      patch[field] = both[field];
      const other = field === "heat_setpoint" ? "cool_setpoint" : "heat_setpoint";
      if (Number.isFinite(both[other]) && both[other] !== thermostat[other]) patch[other] = both[other];
    } else {
      patch.target_temperature = change.temperature;
    }
  }
  return Object.keys(patch).length ? patch : null;
}

async function changeEach(kind, ids, plan) {
  const started = Date.now();
  const keys = [];
  const sent = [];
  for (const id of ids) {
    const device = findDevice(kind, id);
    const send = device ? plan(device) : null;
    if (!send) continue;
    keys.push(deviceKey(kind, id));
    sent.push(send());
  }
  if (!sent.length) return NOTHING();
  await Promise.all(sent);
  return outcome(keys, started);
}

async function runMusic(action) {
  const items = action.ids.map((id) => findMusic(id)).filter(Boolean);
  if (!items.length) return NOTHING();
  const started = Date.now();
  let sent = items;
  if (!Number.isFinite(action.change.volume)) {
    // Play, pause and next act on a room's group: once a group.
    const groups = new Set();
    sent = items.filter((item) => {
      const group = item.group?.id || item.id;
      if (groups.has(group)) return false;
      groups.add(group);
      return true;
    });
  }
  await Promise.all(sent.map((item) => (Number.isFinite(action.change.volume) ? setMusicLevels(item, { volume: action.change.volume }) : musicCommand(item, action.change.action))));
  return outcome(sent.map(musicKey), started);
}

async function runRoomOff(roomId) {
  const group = roomGroup(roomId);
  const keys = [
    ...group.lights.filter(lightIsOn).map((light) => deviceKey("light", light.id)),
    ...(group.fans || []).filter(fanIsOn).map((fan) => deviceKey("fan", fan.id)),
    ...group.thermostats.filter((thermostat) => climateIsOn(thermostat) && (thermostat.modes || []).includes("off")).map((thermostat) => deviceKey("thermostat", thermostat.id)),
  ];
  if (!keys.length) return NOTHING();
  const started = Date.now();
  await allOff(group);
  return outcome(keys, started);
}

// Runs an action the user asked for (the parser's, or an option they chose).
async function perform(action) {
  switch (action.type) {
    case "lights":
      return changeEach("light", action.ids, (light) => {
        if ("on" in action.change && Boolean(light.on) === action.change.on) return null;
        return () => setLight(light, action.change);
      });
    case "climate":
      return changeEach("thermostat", action.ids, (thermostat) => {
        const patch = thermostatChange(thermostat, action.change);
        return patch ? () => setThermostat(thermostat, patch) : null;
      });
    case "blinds":
      return changeEach("blind", action.ids, (blind) => (action.change.stop ? () => stopBlind(blind) : () => setBlind(blind, action.change.position)));
    case "fans":
      return changeEach("fan", action.ids, (fan) => (Boolean(fan.on) === action.change.on ? null : () => setFan(fan, action.change)));
    case "music":
      return runMusic(action);
    case "roomOff":
      return runRoomOff(action.room);
    default:
      return { stage: "error", text: t("command.result.failed", { error: "" }) };
  }
}

// Shows what it understood, then does it (or asks for the second tap), then shows the result.
export function act(action) {
  const said = describe(action);
  if (action.type === "door") {
    // The command is the first tap: the door's own button asks for the second, as everywhere.
    const map = action.device.kind === "relay" ? "relayStage" : "doorbellStage";
    const stage = ui[map][action.device.id];
    if (stage !== "confirm" && stage !== "sending") setStage(map, action.device.id, "confirm", 5000);
    return show({ stage: "door", said, action });
  }
  if (action.type === "scene") {
    const scene = findScene(action.id);
    if (!scene) return show({ stage: "error", said, text: t("command.result.failed", { error: "" }) });
    const run = ui.sceneRuns[scene.id];
    if (sceneOpensDoors(scene) && (can("doors") || state.access)) {
      // Its first tap (runScene asks for a second); never a second one from the words alone.
      if (run?.stage !== "confirm" && run?.stage !== "running") runScene(scene);
      return show({ stage: "scene", said, action });
    }
    const shown = show({ stage: "running", said, action });
    runScene(scene).then(() => {
      const result = ui.sceneRuns[scene.id];
      settle(shown.stamp, result ? { stage: result.stage === "done" ? "done" : result.stage === "partial" ? "partial" : "error", text: result.text } : NOTHING());
    });
    return shown;
  }
  if (action.type === "offAll") {
    const counts = action.filters.map((filter) => [filter, offTargets(filter).length]).filter(([, count]) => count > 0);
    if (!counts.length) return show({ stage: "done", said, text: t(action.filters.includes("blinds") ? "command.off.nothingOpen" : "command.off.nothing") });
    const text = counts.map(([filter, count]) => t(`command.off.count.${filter}`, { count })).join(", ");
    const shown = show({ stage: "confirm", said, text, action });
    window.setTimeout(() => {
      if (current?.stamp === shown.stamp && current.stage === "confirm") show(null);
    }, CONFIRM_MS);
    return shown;
  }
  const shown = show({ stage: "running", said, action });
  perform(action).then(
    (result) => settle(shown.stamp, result),
    () => settle(shown.stamp, { stage: "error", text: t("command.result.failed", { error: "" }) })
  );
  return shown;
}

// Turn off all's second tap, from the command's confirm.
export async function confirmCommand() {
  if (current?.stage !== "confirm") return;
  const { stamp, action } = current;
  current = { ...current, stage: "running" };
  notify();
  await Promise.all(action.filters.map((filter) => turnOffNow(filter)));
  const runs = action.filters.map((filter) => [filter, ui.offRuns[filter]]).filter(([, run]) => run);
  const failed = runs.find(([, run]) => run.stage === "error" || run.stage === "partial");
  if (!failed) return settle(stamp, { stage: "done", text: t("command.result.done") });
  const [filter, run] = failed;
  settle(stamp, { stage: "partial", text: run.stage === "error" ? run.text : t(`home.off.failed.${filter}`, { count: run.count }).replace(/:$/, ".") });
}

// One of a question's options, chosen.
export function chooseOption(index) {
  const option = current?.stage === "ask" ? current.options[index] : null;
  if (option) act(option);
}

// The words typed or heard (with the speech service's other guesses, the likeliest first):
// understood, asked about, or not understood. Returns what it shows.
export function submitCommand(text, alternatives = []) {
  const said = [text, ...alternatives].map((item) => String(item || "").trim()).filter(Boolean);
  if (!said.length) return show(null);
  if (!can("member")) return show({ stage: "problem", text: t("command.problem.viewOnly") });
  const catalog = commandCatalog();
  const results = said.map((item) => parseCommand(item, catalog));
  const result = results.find((item) => item.status === "ok") || results.find((item) => item.status === "ask") || results[0];
  if (result.status === "ok") return act(result.action);
  if (result.status === "ask") {
    const withRoom = result.question === "which" || result.question === "partial";
    return show({
      stage: "ask",
      question: result.question,
      text: t(`command.ask.${result.question}`),
      options: result.options,
      labels: result.options.map((option) => describe(option, { withRoom })),
    });
  }
  if (result.status === "problem") return show({ stage: "problem", text: problemText(result) });
  const words = result.words.length ? t("command.unknown", { words: isolate(result.words.join(" ")) }) : t("command.unknownAny");
  return show({ stage: "unknown", text: words, examples: commandExamples() });
}
