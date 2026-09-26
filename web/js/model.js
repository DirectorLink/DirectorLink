// Derived data: room names in the chosen language, devices grouped by room, what is "on".

import { currentLanguage, t } from "./i18n.js";
import { state } from "./state.js";

// Devices without a room are collected under this id.
export const NO_ROOM = 0;

export function roomById(id) {
  return state.rooms.find((room) => room.id === Number(id)) || null;
}

// names: { en: "Living room", he: "סלון" } from Settings → Rooms; falls back to the Control4 name.
export function roomName(roomOrRef) {
  if (!roomOrRef) {
    return t("rooms.noRoom");
  }
  const room = roomById(roomOrRef.id) || roomOrRef;
  const localized = room.names && typeof room.names === "object" ? room.names[currentLanguage()] : "";
  return localized || room.name || t("rooms.unnamed", { id: room.id });
}

export function deviceRoomId(device) {
  return device?.room?.id ?? NO_ROOM;
}

export function lightIsOn(light) {
  return Boolean(light.on);
}

export function climateIsOn(thermostat) {
  return Boolean(thermostat.mode) && thermostat.mode !== "off";
}

export function blindIsOpen(blind) {
  return Number.isFinite(blind.position) && blind.position > 0;
}

export function devicesInRoom(roomId) {
  const id = Number(roomId);
  const pick = (list) => list.filter((device) => deviceRoomId(device) === id);
  return {
    lights: pick(state.lights),
    thermostats: pick(state.thermostats),
    blinds: pick(state.blinds),
    cameras: pick(state.cameras),
    relays: pick(state.relays),
    // Devices this app cannot control.
    others: state.devices.filter((device) => !device.supported && deviceRoomId(device) === id),
  };
}

function controllableCount(group) {
  return (
    group.lights.length + group.thermostats.length + group.blinds.length + group.cameras.length + group.relays.length
  );
}

// Rooms that have something to control, in Control4 order, plus "No room" when needed.
export function visibleRooms() {
  const rooms = state.rooms
    .map((room) => ({ room, group: devicesInRoom(room.id) }))
    .filter((entry) => controllableCount(entry.group) > 0);
  const known = new Set(state.rooms.map((room) => room.id));
  const orphan = (device) => !known.has(deviceRoomId(device));
  const orphans = {
    lights: state.lights.filter(orphan),
    thermostats: state.thermostats.filter(orphan),
    blinds: state.blinds.filter(orphan),
    cameras: state.cameras.filter(orphan),
    relays: state.relays.filter(orphan),
    others: [],
  };
  if (controllableCount(orphans) > 0) {
    rooms.push({ room: { id: NO_ROOM, name: t("rooms.noRoom") }, group: orphans });
  }
  return rooms;
}

export function roomGroup(roomId) {
  const id = Number(roomId);
  if (id === NO_ROOM) {
    return visibleRooms().find((entry) => entry.room.id === NO_ROOM)?.group || devicesInRoom(NO_ROOM);
  }
  return devicesInRoom(id);
}

export function summaryCounts() {
  return {
    lightsOn: state.lights.filter(lightIsOn).length,
    climateOn: state.thermostats.filter(climateIsOn).length,
    blindsOpen: state.blinds.filter(blindIsOpen).length,
  };
}

export function matchesFilter(group, filter) {
  if (filter === "lights") return group.lights.some(lightIsOn);
  if (filter === "climate") return group.thermostats.some(climateIsOn);
  if (filter === "blinds") return group.blinds.some(blindIsOpen);
  return true;
}

// A translated label, or the value itself when the controller reports something unexpected.
export function labelOr(key, value) {
  const label = t(key);
  return label === key ? String(value).charAt(0).toUpperCase() + String(value).slice(1) : label;
}

export function modeLabel(mode) {
  return mode ? labelOr(`climate.modes.${mode}`, mode) : t("climate.modeUnknown");
}

export function fanLabel(speed) {
  return labelOr(`climate.fans.${speed}`, speed);
}

export function blindStateLabel(blind) {
  if (!Number.isFinite(blind.position)) {
    return t("blinds.unknown");
  }
  if (blind.position === 0) return t("blinds.closed");
  if (blind.position === 100) return t("blinds.open");
  return t("blinds.percentOpen", { percent: blind.position });
}

// Brightness to show: reported level, or what was last sent to a light that does not report it.
export function shownBrightness(light) {
  const sent = state.sentBrightness[light.id];
  if (!light.brightness_reported && Number.isFinite(sent)) {
    return sent;
  }
  if (Number.isFinite(light.brightness)) {
    return light.brightness;
  }
  return light.on ? 100 : 0;
}
