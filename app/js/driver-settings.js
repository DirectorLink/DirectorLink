// DirectorLink's settings in the app (1.4.0, ADR-043; views/driver-settings.js): admins see every
// DirectorLink property in Composer, change Schedules, Jewish Calendar and Log Level as Composer
// does (PATCH /v1/settings: Composer shows the change), run Refresh Project and read what Print
// Schedules and Scenes prints. The others are set in Composer only: the controller refuses them for
// every key. A DirectorLink before 1.4.0 answers 404, and the section is not shown.

import { loadCalendar } from "./calendar.js";
import { t } from "./i18n.js";
import { loadSchedules } from "./schedules.js";
import { api, errorText, noteForbidden, refreshDevices, refreshRooms, whenForgotten } from "./session.js";
import { can, notify, state, ui } from "./state.js";

// Read when Settings is opened, after each change, and every minute while it stays open, so that a
// change made in Composer shows here too.
export const READ_AGAIN_MS = 60 * 1000;

// Turning the Jewish calendar off and pausing schedules ask first, saying what they stop.
export const CONFIRM = {
  jewish_calendar: { off: "driverSettings.confirm.calendarOff" },
  schedules: { paused: "driverSettings.confirm.schedulesPaused" },
};

// ui.driverSettings: { document (GET /v1/settings), loadedAt, unsupported, error, busy (the key
// being changed, or "refresh"), message, printout ({ loading } | { lines, printedAt } | { error }) }.
let reading = null;

export function driverSettings() {
  ui.driverSettings ??= { document: null, loadedAt: 0 };
  return ui.driverSettings;
}

// Entering Settings (app.js): read again, keeping what was read for this home meanwhile.
export function resetDriverSettings() {
  const current = driverSettings();
  ui.driverSettings = { document: current.document, unsupported: current.unsupported, loadedAt: 0 };
}

// A forgotten key: another home may be paired next.
whenForgotten(() => {
  reading = null;
  ui.driverSettings = { document: null, loadedAt: 0 };
});

export function findSetting(document, key) {
  return (Array.isArray(document?.settings) ? document.settings : []).find((setting) => setting.key === key) || null;
}

export function loadDriverSettings() {
  if (reading) return reading;
  const current = driverSettings();
  reading = (async () => {
    try {
      const document = await api("/v1/settings");
      if (ui.driverSettings !== current) return;
      current.document = document && Array.isArray(document.settings) ? document : null;
      current.unsupported = false;
      current.error = null;
    } catch (error) {
      if (ui.driverSettings !== current) return;
      noteForbidden(error);
      if (error?.status === 404 || error?.status === 405) {
        current.unsupported = true;
      } else if (error?.code === "FORBIDDEN") {
        current.document = null;
      } else {
        current.error = errorText(error);
      }
    } finally {
      current.loadedAt = Date.now();
      reading = null;
      notify();
    }
  })();
  return reading;
}

// From the panel, as it is drawn: read once Settings is open, then every minute.
export function keepDriverSettings(now = Date.now()) {
  const current = driverSettings();
  if (!state.loaded || !can("admin") || reading || current.busy) return;
  if (!current.loadedAt || now - current.loadedAt >= READ_AGAIN_MS) loadDriverSettings();
}

const MESSAGE_MS = 6000;
let messages = 0;

// A message under the settings; one that says it worked goes after a while.
function say(current, kind, text) {
  messages += 1;
  const stamp = messages;
  current.message = { kind, text, stamp };
  if (kind !== "success") return;
  window.setTimeout(() => {
    if (current.message?.stamp === stamp) {
      current.message = null;
      notify();
    }
  }, MESSAGE_MS);
}

function settingsError(error) {
  if (error?.code === "SET_IN_COMPOSER") return t("driverSettings.errors.setInComposer");
  if (error?.code === "PROJECT_REFRESH_FAILED") return t("driverSettings.refresh.failed");
  if (error?.status === 404 || error?.status === 405) return t("driverSettings.errors.updateDriver");
  return errorText(error);
}

// What else shows the setting: the calendar's screens and what schedules say.
function afterChange(key, value) {
  if (key === "jewish_calendar") {
    if (state.system) state.system = { ...state.system, features: { ...state.system.features, jewish_calendar: value === "on" } };
    loadCalendar();
    loadSchedules();
  } else if (key === "schedules") {
    state.schedulesPaused = value === "paused";
    loadSchedules();
  }
}

// One setting the app may change. Returns whether it changed.
export async function changeSetting(key, value) {
  const current = driverSettings();
  if (current.busy) return false;
  const question = CONFIRM[key]?.[value];
  if (question && !window.confirm(t(question))) return false;
  current.busy = key;
  current.message = null;
  notify();
  try {
    const document = await api("/v1/settings", { method: "PATCH", body: { [key]: value } });
    if (ui.driverSettings !== current) return false;
    if (document && Array.isArray(document.settings)) current.document = document;
    current.loadedAt = Date.now();
    say(current, "success", t("driverSettings.saved"));
    afterChange(key, value);
    return true;
  } catch (error) {
    if (ui.driverSettings !== current) return false;
    noteForbidden(error);
    say(current, "error", settingsError(error));
    // What the controller has now (changed in Composer meanwhile, or a DirectorLink that was
    // replaced by an older one).
    current.loadedAt = 0;
    return false;
  } finally {
    current.busy = null;
    notify();
  }
}

// Refresh Project, as in Composer.
export async function refreshProject() {
  const current = driverSettings();
  if (current.busy) return false;
  current.busy = "refresh";
  say(current, "info", t("driverSettings.refresh.working"));
  notify();
  try {
    const answer = await api("/v1/project/refresh", { method: "POST" });
    if (ui.driverSettings !== current) return false;
    const inventory = answer?.inventory || {};
    say(current, "success", t("driverSettings.refresh.done", { rooms: inventory.rooms ?? 0, devices: inventory.devices ?? 0 }));
    current.loadedAt = 0;
    refreshRooms();
    refreshDevices();
    return true;
  } catch (error) {
    if (ui.driverSettings !== current) return false;
    noteForbidden(error);
    say(current, "error", settingsError(error));
    return false;
  } finally {
    current.busy = null;
    notify();
  }
}

// What Print Schedules and Scenes prints, read when asked for.
export async function openPrintout() {
  const current = driverSettings();
  current.printout = { loading: true };
  notify();
  try {
    const answer = await api("/v1/settings/printout");
    if (ui.driverSettings !== current) return;
    current.printout = { lines: Array.isArray(answer?.lines) ? answer.lines.map(String) : [], printedAt: answer?.printed_at || null };
  } catch (error) {
    if (ui.driverSettings !== current) return;
    noteForbidden(error);
    current.printout = { error: settingsError(error) };
  }
  notify();
}

export function closePrintout() {
  driverSettings().printout = null;
  notify();
}

// The printout's lines in groups, by their indent: a heading (none), its items (two spaces: a
// schedule, or a scene's name) and an item's steps (four: a scene's).
export function printoutGroups(lines) {
  const groups = [];
  for (const raw of lines || []) {
    const line = String(raw);
    const text = line.trim();
    if (!text) continue;
    const indent = line.length - line.trimStart().length;
    const group = groups.at(-1);
    const item = group?.items.at(-1);
    if (indent >= 4 && item) item.steps.push(text);
    else if (indent >= 2 && group) group.items.push({ text, steps: [] });
    else groups.push({ title: text, items: [] });
  }
  return groups;
}
