// The Jewish calendar (ADR-037, docs/SCHEDULES.md): Shabbat and holiday times, the Hebrew date and
// the week's reading, which the controller works out from the home's location (GET /v1/calendar).
// All of it is shown only while the installer has DirectorLink's Jewish Calendar property On in
// Composer (features.jewish_calendar in GET /v1/system). A driver before 1.2.0 has no features: the
// app then shows none of it, never asks /v1/calendar and never sends during_shabbat. The API
// carries only keys and numbers; the names are the dictionaries' (calendar.months, .holidays and
// .parashot in i18n/*.js).

import { t } from "./i18n.js";
import { dayAndTime } from "./schedules.js";
import { api, keyInUse, whenForgotten } from "./session.js";
import { notify, state } from "./state.js";

// Read again this often while the app is in front (with the rooms refresh, once a minute), and a
// few seconds after each moment it changes: a holy period beginning or ending, and the Hebrew date
// changing (the answer's today.changes_at: sunset, or midnight). A moment further off than a day
// waits for a later read.
const REFRESH_MS = 10 * 60 * 1000;
const AFTER_CHANGE_MS = 5000;
const LONGEST_WAIT_MS = 24 * 3600 * 1000;

export const calendarOn = () => state.system?.features?.jewish_calendar === true;
// Only with the key in use: once it is forgotten, or being forgotten (Settings → Forget key or
// Pair again), nothing more is read (session.js).
const wanted = () => calendarOn() && Boolean(keyInUse());

let loadedAt = 0;
let loading = null;
let readAgain = false;
let changeTimer = null;

// GET /v1/calendar, when the calendar is on. One read at a time: asked for during a read (which
// may have left before a change, such as new settings), it reads once more after it.
export function loadCalendar() {
  if (!wanted()) {
    forgetCalendar();
    return Promise.resolve();
  }
  if (loading) {
    readAgain = true;
    return loading;
  }
  loading = (async () => {
    do {
      readAgain = false;
      await readCalendar();
    } while (readAgain && wanted());
  })().finally(() => {
    loading = null;
  });
  return loading;
}

async function readCalendar() {
  try {
    const answer = await api("/v1/calendar");
    // Turned off meanwhile (JEWISH_CALENDAR_OFF, or the next /v1/system), or the key forgotten:
    // nothing to show.
    if (!wanted()) {
      forgetCalendar();
      return;
    }
    state.calendar = answer && typeof answer === "object" ? answer : null;
    loadedAt = Date.now();
  } catch {
    // Kept as it was; the next rooms refresh tries again.
    if (!wanted()) return;
  }
  planNextRead();
  notify();
}

// After connecting and with each rooms refresh (app.js): read the calendar once it is on, and every
// 10 minutes; forget it once it is off.
export function keepCalendar() {
  if (!wanted()) {
    forgetCalendar();
    return undefined;
  }
  if (!state.calendar || Date.now() - loadedAt >= REFRESH_MS) return loadCalendar();
  return undefined;
}

function forgetCalendar() {
  window.clearTimeout(changeTimer);
  changeTimer = null;
  loadedAt = 0;
  readAgain = false;
  if (state.calendar !== null) {
    state.calendar = null;
    notify();
  }
}

// A forgotten key: what this home's calendar said goes with it (another home may be paired next).
whenForgotten(forgetCalendar);

// A 409 JEWISH_CALENDAR_OFF: the installer turned the calendar off since /v1/system was read. It is
// off here too until the next read of /v1/system says otherwise; errors.calendarOff says why
// (session.js). True when that was the answer.
export function noteCalendarOff(error) {
  if (error?.code !== "JEWISH_CALENDAR_OFF") return false;
  if (state.system) state.system = { ...state.system, features: { ...state.system.features, jewish_calendar: false } };
  forgetCalendar();
  notify();
  return true;
}

// The next moment (ms) the calendar's answer changes: the current period's end, the next one's
// start or end, or the Hebrew date turning (today.changes_at: the controller's exact sunset, or
// midnight). null when no moment is known.
export function nextChange(calendar, now = Date.now()) {
  if (!calendar?.enabled) return null;
  const moments = [calendar.current?.ends_at, calendar.next?.starts_at, calendar.next?.ends_at, calendar.today?.changes_at].map((iso) => Date.parse(iso || ""));
  const future = moments.filter((at) => Number.isFinite(at) && at > now);
  return future.length ? Math.min(...future) : null;
}

function planNextRead() {
  window.clearTimeout(changeTimer);
  changeTimer = null;
  const at = nextChange(state.calendar);
  if (at === null) return;
  const wait = at - Date.now() + AFTER_CHANGE_MS;
  if (wait > LONGEST_WAIT_MS) return;
  changeTimer = window.setTimeout(() => {
    changeTimer = null;
    // In the background: read when the app is in front again (the next rooms refresh).
    if (document.hidden) loadedAt = 0;
    else loadCalendar();
  }, wait);
}

// Schedules → Change (admins): Settings → Shabbat and holidays then focuses the calendar's card.
let revealSettings = false;

export function showCalendarSettings() {
  revealSettings = true;
}

export function takeCalendarReveal() {
  const reveal = revealSettings;
  revealSettings = false;
  return reveal;
}

// ---- words -----------------------------------------------------------------------------------

// "Fri 18:04" kept on one line when the text around it wraps.
export const onOneLine = (text) => String(text).replace(/ /g, " ");
const when = (iso, now) => onOneLine(dayAndTime(iso, now));

const ONES = ["", "א", "ב", "ג", "ד", "ה", "ו", "ז", "ח", "ט"];
const TENS = ["", "י", "כ", "ל", "מ", "נ", "ס", "ע", "פ", "צ"];
const HUNDREDS = ["", "ק", "ר", "ש", "ת"];

// 1 to 999 in Hebrew letters: א׳, י״ח, ט״ו and ט״ז (not יה and יו), תשפ״ז, ת״ת. One letter takes a
// geresh (׳), more letters take gershayim (״) before the last.
export function hebrewNumeral(value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1 || number > 999) return String(value);
  let letters = "";
  for (let hundreds = Math.floor(number / 100); hundreds > 0; hundreds -= Math.min(hundreds, 4)) {
    letters += HUNDREDS[Math.min(hundreds, 4)];
  }
  const rest = number % 100;
  letters += rest === 15 ? "טו" : rest === 16 ? "טז" : TENS[Math.floor(rest / 10)] + ONES[rest % 10];
  return letters.length === 1 ? `${letters}׳` : `${letters.slice(0, -1)}״${letters.slice(-1)}`;
}

// Days and years of Hebrew dates are written in Hebrew letters in Hebrew (calendar.numerals).
const inLetters = () => t("calendar.numerals") === "hebrew";
const dayNumber = (day) => (inLetters() ? hebrewNumeral(day) : String(day));

// A name from the dictionaries, or `fallback` for a key this app does not know (a newer driver).
function named(key, fallback, params) {
  const text = t(key, params);
  return text === key ? fallback : text;
}

export function monthName(month) {
  return named(`calendar.months.${month}`, String(month ?? ""));
}

// "18 Tishrei 5787", "י״ח בתשרי תשפ״ז" (the year without its thousands).
export function hebrewDateText(date) {
  if (!date) return "";
  return t("calendar.date", {
    day: dayNumber(date.day),
    month: monthName(date.month),
    year: inLetters() ? hebrewNumeral(date.year % 1000) : String(date.year),
  });
}

// "Chol HaMoed Sukkot", "Rosh Chodesh Cheshvan"; the API's English name for an unknown key.
export function holidayName(holiday) {
  return named(`calendar.holidays.${holiday?.key}`, holiday?.name || "", { month: holiday?.month ? monthName(holiday.month) : "" }).trim();
}

// Kept one day in Israel and two abroad: in Israel their only day is not numbered.
const ONE_DAY_IN_ISRAEL = new Set(["sukkot", "pesach", "shavuot"]);

// With the day of a holiday kept on several: "Chanukah, day 3", "חנוכה, יום ג׳".
export function holidayLabel(holiday, israel = state.calendar?.settings?.israel === true) {
  const name = holidayName(holiday);
  if (!Number.isInteger(holiday?.day) || (israel && ONE_DAY_IN_ISRAEL.has(holiday.key))) return name;
  return t("calendar.day", { name, day: dayNumber(holiday.day) });
}

// "Vayakhel-Pekudei", "ויקהל־פקודי": a combined reading is its two names joined (calendar.join).
export function parashaName(parasha) {
  const ids = Array.isArray(parasha?.ids) ? parasha.ids : [];
  const names = ids.map((id) => named(`calendar.parashot.${id}`, null));
  if (!names.length || names.includes(null)) return parasha?.name || "";
  return names.join(t("calendar.join"));
}

// When a holiday reading replaces the week's parasha, that Shabbat is named after its holiday: the
// first of its holy days, else the first.
function shabbatHoliday(holidays) {
  const list = Array.isArray(holidays) ? holidays : [];
  return list.find((holiday) => holiday.yom_tov) || list[0] || null;
}

// Home: "18 Tishrei 5787 · Chol HaMoed Sukkot · Shabbat Shmini Atzeret", "24 Tishrei 5787 ·
// Parashat Bereshit". After sunset the API's day is already the next one. "" when there is none.
export function homeLine(calendar = state.calendar) {
  const today = calendar?.enabled ? calendar.today : null;
  if (!today?.hebrew) return "";
  const israel = calendar.settings?.israel === true;
  const week = calendar.week;
  const holidays = Array.isArray(today.holidays) ? today.holidays : [];
  const holiday = week && !week.parasha ? shabbatHoliday(week.holidays) : null;
  const reading = week?.parasha
    ? t("calendar.parashat", { name: parashaName(week.parasha) })
    : holiday
      ? named(`calendar.shabbatNames.${holiday.key}`, t("calendar.shabbatOf", { name: holidayName(holiday) }))
      : "";
  const parts = [hebrewDateText(today.hebrew)];
  if (holiday && week.date === today.date) {
    // Today is that Shabbat: its name first, then the day's other holidays.
    parts.push(reading, ...holidays.filter((item) => item.key !== holiday.key).map((item) => holidayLabel(item, israel)));
  } else {
    parts.push(...holidays.map((item) => holidayLabel(item, israel)), reading);
  }
  return parts.filter(Boolean).join(" · ");
}

// A holy period's names, in the order of its days and once each: "Shabbat" for a Saturday, then the
// day's holy holidays ("Shabbat · Shmini Atzeret · Simchat Torah").
function periodNames(period) {
  const names = [];
  for (const day of period.days || []) {
    if (day.shabbat) names.push(t("calendar.shabbat"));
    for (const holiday of day.holidays || []) {
      if (holiday.yom_tov) names.push(holidayName(holiday));
    }
  }
  return [...new Set(names.filter(Boolean))].join(" · ") || t("calendar.shabbat");
}

function dayLabel(day, israel) {
  if (day.shabbat) return t("calendar.shabbat");
  const holidays = day.holidays || [];
  const holiday = holidays.find((item) => item.yom_tov) || holidays[0];
  return holiday ? holidayLabel(holiday, israel) : "";
}

// Schedules, for everyone: the next Shabbat or holiday, or the one now, with its candle lighting
// and havdalah in the home's time zone; inside a period, the candle lightings still to come in it.
// { title, times, later, footnote }, or null when there is nothing to show.
export function holyTimes(calendar = state.calendar, now = new Date()) {
  if (!calendar?.enabled) return null;
  if (calendar.status === "no_location") return { title: "", times: t("calendar.times.noLocation"), later: "", footnote: "" };
  const inside = Boolean(calendar.current);
  const period = calendar.current || calendar.next;
  if (!period) return null;
  const settings = calendar.settings;
  const israel = settings?.israel === true;
  const names = periodNames(period);
  const times = [];
  if (!inside && period.starts_at) times.push(t("calendar.times.candles", { when: when(period.starts_at, now) }));
  if (period.ends_at) times.push(t("calendar.times.havdalah", { when: when(period.ends_at, now) }));
  if (period.approximate && (!period.ends_at || (!inside && !period.starts_at))) times.push(t("calendar.times.noSunset"));
  const later = inside
    ? (period.days || [])
        .slice(1)
        .filter((day) => Date.parse(day.candle_lighting || "") > now.getTime())
        .map((day) => t("calendar.times.later", { name: dayLabel(day, israel), when: when(day.candle_lighting, now) }))
    : [];
  return {
    title: inside ? t("calendar.times.now", { name: names }) : names,
    times: times.join(" · "),
    later: later.join(" · "),
    footnote: settings
      ? t("calendar.times.footnote", {
          candles: settings.candle_lighting_minutes,
          havdalah: settings.havdalah_minutes,
          where: t(israel ? "calendar.times.israel" : "calendar.times.abroad"),
        })
      : "",
  };
}

// The next candle lighting and havdalah, for the schedule editor: during a period, its havdalah.
export function upcomingTimes(calendar = state.calendar) {
  if (!calendar?.enabled) return { candle_lighting: null, havdalah: null };
  return { candle_lighting: calendar.next?.starts_at || null, havdalah: (calendar.current || calendar.next)?.ends_at || null };
}
