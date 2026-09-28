// Schedules (docs/SCHEDULES.md): scenes the controller runs at a time, at sunrise or sunset, or
// when the weather turns (views/schedules.js). The controller keeps and runs them; this reads
// them, says each in a sentence, and reads the weather at home (GET /v1/weather) while the
// Schedules screen is open.

import { currentLanguage, formatClock, formatTemperature, t } from "./i18n.js";
import { api, errorText } from "./session.js";
import { notify, state } from "./state.js";

export const ALL_DAYS = [0, 1, 2, 3, 4, 5, 6];
// The Israeli week: Sunday to Thursday, and the weekend.
export const WORK_DAYS = [0, 1, 2, 3, 4];
export const WEEKEND = [5, 6];

// After connecting and every minute. Drivers before 0.14.0 have none.
export async function loadSchedules() {
  try {
    const answer = await api("/v1/schedules");
    state.schedules = Array.isArray(answer?.items) ? answer.items : [];
    state.schedulesPaused = answer?.paused === true;
    state.schedulesUnsupported = false;
    state.schedulesError = null;
  } catch (error) {
    if (error?.status === 404 || error?.status === 405) {
      state.schedules = [];
      state.schedulesUnsupported = true;
    } else if (state.schedules === null) {
      state.schedulesError = errorText(error);
    }
  }
  notify();
}

const WEATHER_RETRY_MS = 3000;
const WEATHER_RETRIES = 5;
let weatherRetry = null;

// While the Schedules screen is open: the controller then keeps the weather fresh. While it is
// still reading it (just asked, or after a restart), ask again a few seconds later.
export async function loadWeather(retries = WEATHER_RETRIES) {
  window.clearTimeout(weatherRetry);
  try {
    state.weather = await api("/v1/weather");
  } catch {
    // Kept as it was; the screen says nothing new.
  }
  notify();
  if (state.weather?.status === "waiting" && retries > 0 && window.location.hash.startsWith("#/schedule")) {
    weatherRetry = window.setTimeout(() => loadWeather(retries - 1), WEATHER_RETRY_MS);
  }
}

export function findSchedule(id) {
  return (state.schedules || []).find((schedule) => schedule.id === id) || null;
}

// ---- words -------------------------------------------------------------------------------

// Weekday names from the browser, in the app's language: day 0 is Sunday.
export function dayName(day, style = "short") {
  // 4 January 2026 was a Sunday.
  return new Intl.DateTimeFormat(currentLanguage(), { weekday: style, timeZone: "UTC" }).format(new Date(Date.UTC(2026, 0, 4 + day)));
}

function sameDays(days, list) {
  return days.length === list.length && list.every((day) => days.includes(day));
}

export function daysText(days) {
  const sorted = [...days].sort((a, b) => a - b);
  if (sameDays(sorted, ALL_DAYS)) return t("schedules.days.every");
  if (sameDays(sorted, WORK_DAYS)) return t("schedules.days.range", { from: dayName(0), to: dayName(4) });
  if (sameDays(sorted, WEEKEND)) return t("schedules.days.range", { from: dayName(5), to: dayName(6) });
  if (sorted.length === 1) return t("schedules.days.one", { day: dayName(sorted[0], "long") });
  return sorted.map((day) => dayName(day)).join(", ");
}

// "Every day at 06:45", "Fri–Sat, 30 min before sunset", "When it’s hotter than 30° outside".
export function whenText(schedule) {
  const trigger = schedule.trigger || {};
  const days = daysText(schedule.days || []);
  if (trigger.type === "time") return t("schedules.when.time", { days, time: trigger.at });
  if (trigger.type === "sun") {
    const offset = trigger.offset || 0;
    if (!offset) return t(`schedules.when.at.${trigger.event}`, { days });
    return t(`schedules.when.${offset < 0 ? "before" : "after"}.${trigger.event}`, { days, minutes: Math.abs(offset) });
  }
  if (trigger.kind === "heat") return t("schedules.when.heat", { above: formatTemperature(trigger.above) });
  if (trigger.kind === "wind") return t("schedules.when.wind", { above: trigger.above });
  return t("schedules.when.rain");
}

// The limits of a weather schedule, or its "only if" conditions.
export function conditionText(schedule) {
  const trigger = schedule.trigger || {};
  if (trigger.type === "weather") {
    const parts = [];
    if ((schedule.days || []).length < 7) parts.push(daysText(schedule.days || []));
    if (trigger.from && trigger.to) parts.push(t("schedules.between", { from: trigger.from, to: trigger.to }));
    if (trigger.once_a_day !== false) parts.push(t("schedules.onceADay"));
    return parts.join(" · ");
  }
  const onlyIf = schedule.only_if || {};
  const parts = [];
  if (onlyIf.not_raining) parts.push(t("schedules.if.notRaining"));
  if (Number.isFinite(onlyIf.hotter_than)) parts.push(t("schedules.if.hotterThan", { value: formatTemperature(onlyIf.hotter_than) }));
  if (Number.isFinite(onlyIf.wind_below)) parts.push(t("schedules.if.windBelow", { value: onlyIf.wind_below }));
  if (onlyIf.rain_expected) parts.push(t("schedules.if.rainExpected"));
  if (!parts.length) return "";
  return t("schedules.if.only", { conditions: parts.join(t("schedules.if.and")) });
}

// The home's time zone (the controller's), as the times schedules are set in; else the phone's.
function homeZone() {
  const zone = state.system?.location?.timezone;
  if (typeof zone !== "string" || !zone) return undefined;
  try {
    new Intl.DateTimeFormat("en", { timeZone: zone });
    return zone;
  } catch {
    return undefined;
  }
}

// The calendar date (as a day number) and weekday of `date` in the home's time zone.
function homeDay(date, timeZone) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "numeric", day: "numeric", weekday: "short" })
      .formatToParts(date)
      .map((part) => [part.type, part.value])
  );
  return {
    number: Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day)) / 86400000,
    weekday: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(parts.weekday),
  };
}

// "today 06:45", "tomorrow 06:45", "Tue 06:45" (or a date, a week or more away) for a controller
// time, in the home's time zone.
export function dayAndTime(iso) {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const timeZone = homeZone();
  const target = homeDay(date, timeZone);
  const days = target.number - homeDay(new Date(), timeZone).number;
  const time = formatClock(date, timeZone);
  if (days === 0) return t("schedules.today", { time });
  if (days === 1) return t("schedules.tomorrow", { time });
  if (days === -1) return t("schedules.yesterday", { time });
  if (Math.abs(days) >= 6) {
    const day = new Intl.DateTimeFormat(currentLanguage(), { timeZone, weekday: "short", day: "numeric", month: "short" }).format(date);
    return `${day} ${time}`;
  }
  return `${dayName(target.weekday)} ${time}`;
}

// What happened the last time, if it was within a day: ran, ran with problems, or did not run.
function lastText(last) {
  if (!last?.at || Date.now() - new Date(last.at).getTime() >= 24 * 3600 * 1000) return "";
  const when = dayAndTime(last.at);
  if (last.skipped_by) return t(`schedules.skipped.${last.skipped_by}`, { when });
  if (last.error) return t("schedules.ranError", { when });
  if (last.failed > 0) return t("schedules.ranFailed", { when, count: last.failed });
  if (last.ran === 0) return t("schedules.ranNothing", { when });
  return t("schedules.ran", { when });
}

// What happened last, and what comes next.
export function statusText(schedule) {
  if (schedule.enabled === false) return t("schedules.off");
  if (state.schedulesPaused) return t("schedules.pausedShort");
  const parts = [lastText(schedule.last_run)];
  if (schedule.next_run) parts.push(t("schedules.next", { when: dayAndTime(schedule.next_run) }));
  else if (!parts[0]) parts.push(weatherNow(schedule.trigger?.kind));
  return parts.filter(Boolean).join(" · ");
}

// "Now 27°", "Now 12 km/h", "Dry now" for a weather schedule's kind.
export function weatherNow(kind) {
  const current = state.weather?.status === "ok" ? state.weather.current : null;
  if (!current) return "";
  if (kind === "heat") return t("schedules.now.temperature", { value: formatTemperature(current.temperature) });
  if (kind === "wind") return Number.isFinite(current.wind_speed) ? t("schedules.now.wind", { value: Math.round(current.wind_speed) }) : "";
  if (kind === "rain") return current.raining ? t("schedules.now.raining") : t("schedules.now.dry");
  return "";
}

export function scheduleIcon(schedule) {
  const trigger = schedule.trigger || {};
  if (trigger.type === "time") return "clock";
  if (trigger.type === "sun") return "sun";
  return { heat: "climate", wind: "wind", rain: "rain" }[trigger.kind] || "clock";
}

export function sceneNameOf(schedule) {
  return (state.scenes || []).find((scene) => scene.id === schedule.scene_id)?.name || t("schedules.sceneGone");
}
