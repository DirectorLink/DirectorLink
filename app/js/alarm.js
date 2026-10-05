// The home's alarm, read-only (docs/DECISIONS.md, ADR-038): whether each partition is armed, in
// alarm, has open zones, counts down an entry or exit delay, or reports trouble. Only when an
// installer turned on Alarm Status in Composer (GET /v1/system: features.alarm_status), and only for
// members and admins; the controller then answers only sealed requests, which is how the app sends
// every request. Nothing here, or anywhere in the app, arms or disarms (views/alarm.js shows it).

import { t } from "./i18n.js";
import { api, keyInUse, whenForgotten } from "./session.js";
import { can, canSeeAlarm, notify, state } from "./state.js";

export const ALARM_POLL_MS = 10000;
// The partition's own word for how it is armed, when it only repeats the mode.
const MODE_WORDS = { away: ["away"], home: ["home", "stay"] };
// Kinds of alarm with a word of their own; others are shown as the panel writes them.
const ALARM_TYPES = {
  fire: "fire",
  smoke: "fire",
  burglary: "burglary",
  intrusion: "burglary",
  panic: "panic",
  medical: "medical",
  police: "police",
  emergency: "emergency",
  duress: "duress",
  co: "carbonMonoxide",
  "carbon monoxide": "carbonMonoxide",
  water: "water",
  flood: "water",
  gas: "gas",
  tamper: "tamper",
};

let timer = null;
// The controller refused the last read (a request it could not open sealed, say): asked again only
// with the next rooms refresh, a minute later, not every 10 s.
let refused = false;
// Partition id -> { remaining, at }: when its delay was last seen to change, so that a panel that
// reports the remaining time only once still counts down between reads.
let delaysSeen = {};

// The installer turned it on, and this key may see it.
export function alarmAvailable() {
  return state.system?.features?.alarm_status === true && Boolean(state.role) && can("member") && canSeeAlarm();
}

// What Home and Settings show: the partitions, or null (nothing at all).
export function alarmPartitions() {
  return alarmAvailable() && state.alarm?.enabled === true && state.alarm.partitions.length ? state.alarm.partitions : null;
}

function keepDelays(partitions, now) {
  const seen = {};
  for (const partition of partitions) {
    const remaining = partition.delay?.remaining;
    if (!Number.isFinite(remaining)) continue;
    const before = delaysSeen[partition.id];
    seen[partition.id] = before && before.remaining === remaining ? before : { remaining, at: now };
  }
  delaysSeen = seen;
}

// After connecting, with each rooms refresh and every 10 s. A 403 (the request could not be
// sealed, or the key's role changed), an older driver's 404 or a 401 shows nothing; without an
// answer the last status stays, and Home says the controller cannot be reached.
export async function loadAlarm(now = Date.now()) {
  if (!alarmAvailable()) {
    if (state.alarm) {
      state.alarm = null;
      notify();
    }
    return;
  }
  try {
    const answer = await api("/v1/alarm");
    const partitions = answer?.enabled === true && Array.isArray(answer.partitions) ? answer.partitions : [];
    keepDelays(partitions, now);
    state.alarm = { enabled: answer?.enabled === true, partitions };
    refused = false;
  } catch (error) {
    if (error?.status) {
      state.alarm = null;
      refused = true;
    }
  }
  notify();
}

function poll() {
  timer = null;
  if (!keyInUse() || !alarmAvailable() || refused) return;
  if (!document.hidden && state.status === "connected") loadAlarm();
  timer = window.setTimeout(poll, ALARM_POLL_MS);
}

// app.js: after connecting and with each rooms refresh. Reads now, then every 10 s while it is on.
export async function startAlarm() {
  refused = false;
  await loadAlarm();
  if (timer === null && alarmAvailable() && !refused) timer = window.setTimeout(poll, ALARM_POLL_MS);
}

whenForgotten(() => {
  window.clearTimeout(timer);
  timer = null;
  refused = false;
  delaysSeen = {};
  state.alarm = null;
});

// ---- words ---------------------------------------------------------------------------------

// A name inside a sentence in the other direction (a Control4 name in Hebrew, or the reverse).
function isolate(text) {
  return `⁨${text}⁩`;
}

// A word the panel wrote that the app has none for: "BYPASS_ACTIVE" -> "Bypass active".
function panelWord(value) {
  const text = String(value).replace(/_/g, " ").trim().toLowerCase();
  return isolate(text.charAt(0).toUpperCase() + text.slice(1));
}

export function alarmTypeLabel(value) {
  const kind = ALARM_TYPES[String(value || "").trim().toLowerCase()];
  return kind ? t(`alarm.types.${kind}`) : panelWord(value);
}

// "alarm" (red), "delay" (entry or exit), "armed", "ready", "not-ready" or "unknown": the colour
// of the row, and what it says first.
export function alarmTone(partition) {
  const current = partition.state;
  if (partition.alarm || current === "alarm") return "alarm";
  if (current === "entry_delay" || current === "exit_delay") return "delay";
  if (partition.armed || current === "armed") return "armed";
  if (current === "disarmed_ready") return "ready";
  if (current === "disarmed_not_ready" || current === "confirmation_required") return "not-ready";
  return "unknown";
}

// "Armed away", "Disarmed · ready", "Alarm: fire", "Entry delay"… in the app's language.
export function alarmStateText(partition) {
  const current = partition.state;
  switch (alarmTone(partition)) {
    case "alarm":
      return partition.alarm_type ? t("alarm.state.alarmOf", { type: alarmTypeLabel(partition.alarm_type) }) : t("alarm.state.alarm");
    case "delay":
      return t(current === "entry_delay" ? "alarm.state.entryDelay" : "alarm.state.exitDelay");
    case "armed": {
      const mode = partition.armed_mode === "away" ? "armedAway" : partition.armed_mode === "home" ? "armedHome" : "armed";
      const own = String(partition.armed_type || "").trim();
      const repeats = own === "" || (MODE_WORDS[partition.armed_mode] || []).includes(own.toLowerCase());
      return repeats ? t(`alarm.state.${mode}`) : t("alarm.state.armedAs", { state: t(`alarm.state.${mode}`), type: isolate(own) });
    }
    case "ready":
      return t("alarm.state.ready");
    case "not-ready":
      return t(current === "confirmation_required" ? "alarm.state.confirm" : "alarm.state.notReady");
    default:
      if (current === "offline") return t("alarm.state.offline");
      return current ? panelWord(current) : t("alarm.state.unknown");
  }
}

// Seconds left of an entry or exit delay: the panel's last report, counted down since it came.
export function delaySecondsLeft(partition, now = Date.now()) {
  const remaining = partition.delay?.remaining;
  if (!Number.isFinite(remaining)) return null;
  const seen = delaysSeen[partition.id];
  const passed = seen && seen.remaining === remaining ? Math.floor(Math.max(0, now - seen.at) / 1000) : 0;
  return Math.max(0, remaining - passed);
}

// What else to say: open zones, the time a delay has left, trouble.
export function alarmDetails(partition, now = Date.now()) {
  const details = [];
  const left = delaySecondsLeft(partition, now);
  if (partition.delay && left !== null && left > 0) details.push(t("alarm.delayLeft", { count: left }));
  if (Number.isFinite(partition.open_zones) && partition.open_zones > 0) details.push(t("alarm.openZones", { count: partition.open_zones }));
  if (partition.trouble) details.push(t("alarm.trouble", { text: isolate(partition.trouble) }));
  return details;
}

// Settings → Controller: one line for the whole alarm.
export function alarmSummary(partitions) {
  if (partitions.length === 1) return alarmStateText(partitions[0]);
  return partitions.map((partition) => t("alarm.summaryItem", { name: isolate(partition.name), state: alarmStateText(partition) })).join(" · ");
}

// For the renderer's signature (app.js): what is shown, and the seconds a delay has left.
export function alarmSignature(now = Date.now()) {
  const partitions = alarmPartitions();
  return partitions ? [partitions, partitions.map((partition) => delaySecondsLeft(partition, now))] : null;
}
