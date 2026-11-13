// Settings → Alarm (DirectorLink 1.16.0, docs/DECISIONS.md ADR-092): how far admins let the alarm be
// armed and disarmed from DirectorLink without its code: "none" (a code every time, as it ships),
// "arm", or "arm_disarm". The controller keeps it (GET and PUT /v1/alarm/settings, admins only) and
// goes no further than the alarm's own driver allows (its Composer property); each partition's
// `control.without_code` in GET /v1/alarm is the lower of the two, which js/alarm-control.js follows.
// Only for admins of a controller that has it (features.alarm_without_code) while an installer has
// Alarm Control on. Views: views/settings.js.

import { loadAlarm } from "./alarm.js";
import { t } from "./i18n.js";
import { api, errorText, noteForbidden, whenForgotten } from "./session.js";
import { can, notify, state, ui } from "./state.js";

export const WITHOUT_CODE_LEVELS = ["none", "arm", "arm_disarm"];
const SAVED_MESSAGE_MS = 6000;

// How far a level goes: none 0, arm 1, arm_disarm 2 (anything else counts as none).
export function levelRank(level) {
  return Math.max(0, WITHOUT_CODE_LEVELS.indexOf(level));
}

export function alarmSettingsSupported() {
  const features = state.system?.features;
  return Boolean(state.role) && can("admin") && features?.alarm_without_code === true && features?.alarm_control === true;
}

// What Settings shows: { level: the controller's (null until read), draft: the one chosen, busy,
// error: why it could not be read, message: { kind, text, stamp } once saved or refused }.
function current() {
  if (!ui.alarmSettings) ui.alarmSettings = { level: null, draft: null, busy: false, error: null, message: null };
  return ui.alarmSettings;
}

// Entering Settings → Alarm (app.js): nothing chosen yet, and the setting read again.
export function resetAlarmSettings() {
  const settings = current();
  settings.draft = null;
  settings.message = null;
  settings.error = null;
}

// Settings' list and Settings → Alarm, as they open: the controller's setting.
export async function loadAlarmSettings() {
  if (!alarmSettingsSupported()) return;
  const settings = current();
  try {
    const answer = await api("/v1/alarm/settings");
    settings.level = WITHOUT_CODE_LEVELS.includes(answer?.without_code) ? answer.without_code : "none";
    settings.error = null;
  } catch (error) {
    noteForbidden(error);
    if (settings.level === null) settings.error = errorText(error);
  }
  notify();
}

export function chooseAlarmLevel(level) {
  if (!WITHOUT_CODE_LEVELS.includes(level)) return;
  const settings = current();
  settings.draft = level;
  settings.message = null;
  notify();
}

// Saves the level chosen; then the partitions are read again, so that Home (and the note under the
// choice) follow what the alarm's driver allows of it.
export async function saveAlarmSettings() {
  const settings = current();
  const level = settings.draft;
  if (!WITHOUT_CODE_LEVELS.includes(level) || settings.busy) return;
  settings.busy = true;
  settings.message = null;
  notify();
  try {
    const answer = await api("/v1/alarm/settings", { method: "PUT", body: { without_code: level } });
    settings.level = WITHOUT_CODE_LEVELS.includes(answer?.without_code) ? answer.without_code : level;
    settings.draft = null;
    const stamp = Date.now();
    settings.message = { kind: "success", text: t("alarm.settings.saved"), stamp };
    window.setTimeout(() => {
      if (ui.alarmSettings?.message?.stamp === stamp) {
        ui.alarmSettings.message = null;
        notify();
      }
    }, SAVED_MESSAGE_MS);
    await loadAlarm();
  } catch (error) {
    noteForbidden(error);
    settings.message = { kind: "error", text: errorText(error), stamp: Date.now() };
  }
  settings.busy = false;
  notify();
}

whenForgotten(() => {
  ui.alarmSettings = null;
});
