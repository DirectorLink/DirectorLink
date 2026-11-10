// Schedules → Next 7 days (#/schedules/week; admins; DirectorLink 1.14.0, ADR-090): today and the
// six days after it, as the controller works them out (GET /v1/schedules/week): each day's dawn,
// sunrise, sunset and dusk, the home's holiday, Shabbat and holidays (with the Jewish calendar on),
// and every run of every schedule that day, at its time, or why it does not run (skipped, a holiday,
// switched off, paused in Composer, no sunset). A weather rule is shown on its days without a time;
// a schedule with "only if" runs if the weather allows then. Since 1.14.1 a run kept away from
// Shabbat and holidays (`reason` "shabbat") is left out: listed with its reason it read as a run
// (the owner took "Rooms AC Off 09:00" on a Saturday for one); the day's Shabbat line says when
// holy time begins or ends. The controller lists a weather rule only on days its weather may come.

import { emptyState, skeletonCards } from "../components.js";
import { h } from "../dom.js";
import { currentLanguage, formatClock, t } from "../i18n.js";
import { icon } from "../icons.js";
import { findSchedule, homeZone, loadWeek, membersHaveNoSchedules, sceneNameOf, scheduleIcon, schedulePlanning, whenText } from "../schedules.js";
import { can, state } from "../state.js";
import { isLoading, notReadyState, offlineBanner, pageHeader, staleBanner } from "./common.js";

const REASONS = ["skip", "holiday", "off", "paused", "no_sun"];

// The runs a day lists: all but those kept away from Shabbat and holidays.
function shownRuns(day) {
  const runs = Array.isArray(day.runs) ? day.runs : [];
  return runs.filter((run) => !(run.status === "skipped" && run.reason === "shabbat"));
}

// "Today · Friday 6 November", "Tomorrow · Saturday 7 November", "Sunday 8 November": the
// controller's local dates, so read as such (noon UTC of that date, shown in UTC).
function dayTitle(day, index) {
  const date = new Date(`${day.date}T12:00:00Z`);
  const label = Number.isNaN(date.getTime())
    ? day.date
    : new Intl.DateTimeFormat(currentLanguage(), { weekday: "long", day: "numeric", month: "long", timeZone: "UTC" }).format(date);
  if (index === 0) return t("schedules.week.today", { date: label });
  if (index === 1) return t("schedules.week.tomorrow", { date: label });
  return label;
}

function clockOf(iso) {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? "" : formatClock(date, homeZone());
}

// "Dawn 05:58 · Sunrise 06:24 · Sunset 16:52 · Dusk 17:17", each only when there is one.
function sunLine(day) {
  const sun = day.sun || {};
  return ["dawn", "sunrise", "sunset", "dusk"]
    .filter((event) => typeof sun[event] === "string")
    .map((event) => t(`schedules.week.sun.${event}`, { time: sun[event] }))
    .join(" · ");
}

// Shabbat and holidays that day: from candle lighting, until havdalah, or all day.
function holyLine(day) {
  const holy = day.holy;
  if (!holy || typeof holy !== "object") return null;
  const parts = [];
  if (holy.ends_at) parts.push(t("schedules.week.holyUntil", { time: clockOf(holy.ends_at) }));
  if (holy.starts_at) parts.push(t("schedules.week.holyFrom", { time: clockOf(holy.starts_at) }));
  return parts.length ? parts.join(" · ") : t("schedules.week.holyAllDay");
}

// What a run is that day, in words: nothing for one that runs, "if the weather allows" with "only
// if", "earlier today" once its time has passed, or why it does not run.
function statusText(run) {
  if (run.status === "skipped") return t(`schedules.week.reason.${REASONS.includes(run.reason) ? run.reason : "other"}`);
  if (run.status === "past") return t("schedules.week.past");
  if (run.status === "planned" && run.conditions) return t("schedules.week.ifWeather");
  return "";
}

function runRow(run, admin) {
  const schedule = findSchedule(run.schedule_id);
  const time = run.at ? clockOf(run.at) : run.from && run.to ? t("schedules.between", { from: run.from, to: run.to }) : t("schedules.week.anyTime");
  const scene = schedule ? sceneNameOf(schedule) : t("schedules.sceneGone");
  const status = statusText(run);
  const muted = run.status === "skipped" || run.status === "past";
  const text = h(
    "span",
    { class: "week-run-text" },
    h("span", { class: "week-run-scene" }, scene),
    schedule ? h("span", { class: "week-run-when" }, whenText(schedule)) : null,
    status ? h("span", { class: `week-run-status ${run.status === "skipped" ? "is-skipped" : ""}`.trim() }, status) : null
  );
  const content = [
    h("span", { class: "week-run-time" }, time),
    h("span", { class: `scene-icon schedule-icon schedule-${schedule ? scheduleIcon(schedule) : "clock"}`, "aria-hidden": "true" }, icon(schedule ? scheduleIcon(schedule) : "clock")),
    text,
  ];
  return h(
    "li",
    { class: `week-run ${muted ? "is-muted" : ""}`.trim() },
    admin && schedule ? h("a", { class: "week-run-link", href: `#/schedule/${schedule.id}`, dataset: { key: `week-run:${run.schedule_id}:${run.at || "weather"}` } }, content) : h("div", { class: "week-run-link" }, content)
  );
}

function dayCard(day, index, admin) {
  const runs = shownRuns(day);
  const holy = holyLine(day);
  const sun = sunLine(day);
  return h(
    "section",
    { class: "card week-day", "aria-label": dayTitle(day, index) },
    h("h2", { class: "add-title week-day-title" }, dayTitle(day, index)),
    sun ? h("p", { class: "week-day-sun" }, icon("sun"), sun) : null,
    day.holiday?.name ? h("p", { class: "week-day-holiday" }, icon("holiday"), t("schedules.week.holiday", { name: `⁨${day.holiday.name}⁩` })) : null,
    holy ? h("p", { class: "week-day-holy" }, icon("candles"), holy) : null,
    runs.length ? h("ul", { class: "week-runs" }, runs.map((run) => runRow(run, admin))) : h("p", { class: "muted-note" }, t("schedules.week.nothing"))
  );
}

export function scheduleWeekView() {
  const header = pageHeader({ title: t("schedules.week.title"), back: "#/schedules" });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (membersHaveNoSchedules()) return [header, emptyState("clock", t("schedules.week.title"), t("schedules.adminsOnly"))];
  if (state.system && !schedulePlanning()) return [header, emptyState("calendar", t("schedules.week.title"), t("schedules.week.updateDriver"))];
  const week = state.scheduleWeek;
  if (!week || state.schedules === null) {
    if (state.scheduleWeekError && !isLoading()) {
      return [
        header,
        emptyState(
          "wifiOff",
          t("schedules.week.loadFailed"),
          state.scheduleWeekError,
          h("button", { type: "button", class: "button button-primary", dataset: { key: "week-retry" }, onclick: () => loadWeek() }, icon("refresh"), t("common.retry"))
        ),
      ];
    }
    return [header, h("div", { class: "scene-list", "aria-busy": "true" }, skeletonCards(3)), h("p", { class: "visually-hidden", role: "status" }, t("common.loading"))];
  }
  const admin = can("admin");
  const days = Array.isArray(week.days) ? week.days : [];
  return [
    header,
    offlineBanner(),
    staleBanner(),
    week.paused ? h("p", { class: "notice notice-info", role: "status" }, t("schedules.paused")) : null,
    h("p", { class: "muted-note scene-intro" }, t("schedules.week.help")),
    h("div", { class: "week-list" }, days.map((day, index) => dayCard(day, index, admin))),
  ];
}
