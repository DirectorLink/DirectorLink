// Arming and disarming the alarm from the app (DirectorLink 1.15.0, docs/DECISIONS.md ADR-091): for
// admins and the members an admin gave it to (Settings → Users), while an installer has Alarm Status
// and Alarm Control on in Composer. Each partition of GET /v1/alarm says whether this person may now
// (`control.allowed`), whether its driver can (`control.available`: the DirectorLink · PIMA FORCE
// driver says no while its panel only reports) and the modes it arms in (`modes`).
//
// The person types the alarm's code for every command (views/alarm-control.js). It goes into that one
// request's body (POST /v1/alarm/{id}/arm with { mode, code }, /disarm with { code }), sealed like
// every request of the app, at home and away, and nowhere else: never in a URL, `state` or `ui`,
// storage, the console or the page once sent. The panel checks it: a 202 says only that the command
// went, so the partition is read again (2 to 20 s after), and when it did not change as asked the app
// says the alarm didn't take it. Nothing here runs by itself: only a person's press and their code.

import { alarmStateText, alarmTone, loadAlarm } from "./alarm.js";
import { announce } from "./dom.js";
import { t } from "./i18n.js";
import { api, errorText, handleUnauthorized, keyGeneration, noteForbidden, whenForgotten } from "./session.js";
import { notify, state, ui } from "./state.js";

// What the controller takes: 1 to 12 digits, typed for this command.
export const CODE_PATTERN = /^[0-9]{1,12}$/;
export const CODE_MAX = 12;
// After a 202, GET /v1/alarm is read again 2, 4, 7, 10, 14 and 20 s later, until the partition shows
// what was asked.
export const FOLLOW_MS = [2000, 2000, 3000, 3000, 4000, 6000];
// What went wrong stays under the partition this long, or until one of its buttons is pressed.
export const MESSAGE_MS = 60000;
// Refusals after which the partitions are read again: what may be done changed meanwhile.
const READ_AGAIN = new Set(["ALARM_UNAVAILABLE", "NO_ARM_MODES", "ALARM_CONTROL_DISABLED", "FORBIDDEN"]);

const sleep = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));
const isolate = (text) => `⁨${text}⁩`;

// Each command's number: a newer one on the same partition, or a forgotten key, ends an older one's
// reads. Partition id -> the number of its last command.
let commands = 0;
const latest = new Map();
const messageTimers = new Map();
// The element (data-key) to give the keyboard to once the partition is drawn again.
let focusWanted = null;

export function alarmPartition(id) {
  return (state.alarm?.partitions || []).find((partition) => partition.id === id) || null;
}

// This person may arm and disarm it (Alarm Status and Alarm Control on, an admin or a member given it).
export function controlAllowed(partition) {
  return partition?.control?.allowed === true;
}

// …and its driver can now.
export function controlAvailable(partition) {
  return controlAllowed(partition) && partition.control.available !== false;
}

// The modes it arms in, as its driver declares them (none: it is only disarmed from DirectorLink).
export function armModes(partition) {
  return Array.isArray(partition?.modes) ? partition.modes.filter((mode) => typeof mode === "string" && mode.trim() !== "") : [];
}

// What can be asked of it in the state it is in: Arm (in `modes`) while it is disarmed, Disarm while
// it is armed, counts down a delay or is in alarm. Nothing in a state the app does not know.
export function alarmActions(partition) {
  const tone = alarmTone(partition);
  if (tone === "ready" || tone === "not-ready") return { modes: armModes(partition), disarm: false };
  if (tone === "armed" || tone === "delay" || tone === "alarm") return { modes: [], disarm: true };
  return { modes: [], disarm: false };
}

// The alarm did what was asked: armed (or counts down its exit delay), or disarmed, out of alarm and
// with no delay.
export function commandTook(action, partition) {
  if (!partition) return false;
  if (action === "arm") return partition.armed === true || partition.state === "armed" || partition.state === "exit_delay";
  return partition.armed !== true && partition.alarm !== true && !partition.delay && !["armed", "alarm", "entry_delay", "exit_delay"].includes(partition.state);
}

export const statusKey = (id) => `alarm:${id}:status`;

export function controlOf(id) {
  return ui.alarmControl?.[id] || null;
}

function setControl(id, value) {
  const { [id]: _previous, ...rest } = ui.alarmControl || {};
  ui.alarmControl = value ? { ...rest, [id]: value } : rest;
  notify();
}

// The view gives the keyboard to `key` when it draws it next (once).
export function wantFocus(key) {
  focusWanted = key;
}
export function takeFocus(key) {
  if (focusWanted !== key) return false;
  focusWanted = null;
  return true;
}

function statusFocused(id) {
  return document.activeElement?.dataset?.key === statusKey(id);
}

// Arm with more than one mode: the modes to choose from, under the partition.
export function chooseMode(id) {
  window.clearTimeout(messageTimers.get(id));
  setControl(id, { stage: "choose" });
}

export function cancelChoice(id) {
  setControl(id, null);
}

// A button of the partition was pressed: what went wrong before is no longer news.
export function clearMessage(id) {
  const current = controlOf(id);
  if (!current?.message) return;
  window.clearTimeout(messageTimers.get(id));
  const { message: _message, ...rest } = current;
  setControl(id, rest.stage ? rest : null);
}

function fail(id, text, action) {
  if (statusFocused(id)) wantFocus(`alarm:${id}:${action}`);
  const message = { kind: "error", text };
  setControl(id, { stage: null, message });
  window.clearTimeout(messageTimers.get(id));
  messageTimers.set(
    id,
    window.setTimeout(() => {
      if (controlOf(id)?.message === message) setControl(id, null);
    }, MESSAGE_MS)
  );
}

// A refusal in the app's words: too many commands (and for how long), its driver cannot now, the
// switch in Composer, this person's permission, the controller could not pass it on.
export function alarmCommandError(error) {
  switch (error?.code) {
    case "RATE_LIMITED": {
      const seconds = Number(error.problem?.retry_after) || Number(error.retryAfter) || 0;
      return seconds > 0 ? t("alarm.control.errors.rateLimited", { count: Math.max(1, Math.ceil(seconds / 60)) }) : t("alarm.control.errors.rateLimitedLater");
    }
    case "ALARM_UNAVAILABLE":
      return t("alarm.control.unavailable");
    case "NO_ARM_MODES":
      return t("alarm.control.errors.noModes");
    case "ALARM_CONTROL_DISABLED":
      return t("alarm.control.errors.disabled");
    case "FORBIDDEN":
      return t("alarm.control.errors.forbidden");
    case "SEALED_REQUEST_REQUIRED":
      return t("alarm.control.errors.sealed");
    case "CONTROLLER_COMMAND_FAILED":
      return t("alarm.control.errors.failed");
    case "INVALID_FIELD":
    case "INVALID_REQUEST":
      return t("alarm.control.errors.invalid");
    default:
      if (error?.status === 404) return t("alarm.control.errors.gone");
      if (error?.status === 502) return t("alarm.control.errors.failed");
      return errorText(error);
  }
}

// Sends what the person asked, with the code they typed for it (views/alarm-control.js), then reads the
// partition until it shows the alarm took it, or 20 s pass. Returns whether the controller sent it.
export async function sendAlarmCommand({ id, action, mode = null, code }) {
  const partition = alarmPartition(id);
  // Its state may have changed while the code was typed: the alarm sorts that out. Only a partition it
  // may still be sent, in a mode its driver declares, with a code of digits, goes.
  const fits = action === "arm" ? armModes(partition).includes(mode) : action === "disarm";
  if (!controlAvailable(partition) || !fits || !CODE_PATTERN.test(String(code ?? ""))) {
    setControl(id, null);
    return false;
  }
  const command = ++commands;
  latest.set(id, command);
  const since = keyGeneration();
  window.clearTimeout(messageTimers.get(id));
  setControl(id, { stage: "sending", action, mode });
  const body = action === "arm" ? { mode, code } : { code };
  const current = () => since === keyGeneration() && latest.get(id) === command;
  try {
    await api(`/v1/alarm/${id}/${action}`, { method: "POST", body });
  } catch (error) {
    if (!current()) return false;
    if (error?.status === 401) {
      setControl(id, null);
      handleUnauthorized(error);
      return false;
    }
    noteForbidden(error);
    fail(id, alarmCommandError(error), action);
    if (READ_AGAIN.has(error?.code) || error?.status === 404) loadAlarm();
    return false;
  } finally {
    // The code went with the request, and stays nowhere: not in its body either.
    delete body.code;
  }
  if (!current()) return false;
  setControl(id, { stage: "pending", action, mode });
  follow(id, action, current);
  return true;
}

// Reads the partitions again until this one shows what was asked; after 20 s, says it did not.
async function follow(id, action, current) {
  for (const wait of FOLLOW_MS) {
    await sleep(wait);
    if (!current()) return;
    await loadAlarm();
    if (!current()) return;
    const partition = alarmPartition(id);
    if (!partition) {
      // No longer shown (Alarm Status turned off, say): nothing more to tell.
      setControl(id, null);
      return;
    }
    if (commandTook(action, partition)) {
      if (statusFocused(id)) wantFocus(`alarm:${id}:${action === "arm" ? "disarm" : "arm"}`);
      setControl(id, null);
      announce(t("alarm.summaryItem", { name: isolate(partition.name), state: alarmStateText(partition) }));
      return;
    }
  }
  fail(id, t(action === "arm" ? "alarm.control.notArmed" : "alarm.control.notDisarmed"), action);
}

// This device's key forgotten: no command follows on, and nothing of one stays.
whenForgotten(() => {
  latest.clear();
  for (const timer of messageTimers.values()) window.clearTimeout(timer);
  messageTimers.clear();
  focusWanted = null;
  ui.alarmControl = {};
});
