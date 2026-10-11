// The weather at home, GET /v1/weather (docs/SCHEDULES.md): the saved forecast the controller reads
// from Open-Meteo (ADR-071). Scenes → Schedules shows it in a card (views/schedules.js) and Home in
// one line under the command field (1.12.1, ADR-084): "Now 27° · Today 23°–30° · rain 14% · sunset
// 18:13". The phone asks only the controller (at home or through the account, sealed as every
// request): Schedules every 5 minutes while it is open, Home when it opens and every 10 minutes
// while it stays open and in front. Reading it keeps the controller's forecast fresh for an hour.

import { formatTemperature, formatTemperatureRange, t } from "./i18n.js";
import { homeZone, outside } from "./schedules.js";
import { api, keyInUse, whenForgotten } from "./session.js";
import { can, notify, state } from "./state.js";

const RETRY_MS = 3000;
const RETRIES = 5;
// Home reads it again this often while it stays open (the forecast's "now" moves on smoothly
// between its hours), and opening Home reads it unless it was read this recently.
const HOME_REFRESH_MS = 10 * 60 * 1000;
const HOME_OPEN_MS = 60 * 1000;
// From this local time Home shows tomorrow's high and low instead of today's (the owner's choice):
// the two cover the next 24 hours.
const TOMORROW_FROM = "15:00";
// A chance of rain under this is not worth a word on Home.
const RAIN_FROM = 10;

let retryTimer = null;
let readAt = 0;
// The controller refused this key the weather (403), or has none (404, before 0.14.0): nothing is
// asked again until the key is forgotten or the app is opened again.
let refused = false;

const onHome = (hash) => hash === "" || hash === "#" || hash === "#/";
const shownNow = () => window.location.hash.startsWith("#/schedule") || onHome(window.location.hash);

// GET /v1/weather. While the controller is still reading it (just asked, or after a restart:
// "waiting") and Schedules or Home is shown, it is asked again a few seconds later.
export async function loadWeather(retries = RETRIES) {
  window.clearTimeout(retryTimer);
  const key = keyInUse();
  if (!key) return;
  try {
    const answer = await api("/v1/weather");
    // The key was forgotten meanwhile (another home may be paired next): nothing of this one.
    if (keyInUse() !== key) return;
    state.weather = answer && typeof answer === "object" ? answer : null;
    readAt = Date.now();
  } catch (error) {
    if (error?.status === 403 || error?.status === 404) {
      refused = true;
      state.weather = null;
    }
    // Anything else: kept as it was; the screens say nothing new.
  }
  notify();
  if (state.weather?.status === "waiting" && retries > 0 && shownNow()) {
    retryTimer = window.setTimeout(() => loadWeather(retries - 1), RETRY_MS);
  }
}

// Home shows the weather to a key that may read it: every user's since 1.8.0 (a viewer key of an
// older controller may not), unless the controller refused it.
const homeWants = () => Boolean(keyInUse()) && state.loaded && can("member") && !refused;

// Opening Home: the weather now, unless it was read in the last minute.
export function enterHomeWeather() {
  if (homeWants() && (!state.weather || Date.now() - readAt >= HOME_OPEN_MS)) return loadWeather();
  return undefined;
}

// After connecting and with each rooms refresh (every minute while the app is in front), and when
// the app comes back to the front: on Home, read it again once it is 10 minutes old (a minute while
// the controller is still reading it).
export function keepHomeWeather() {
  if (!onHome(window.location.hash) || document.hidden || !homeWants()) return undefined;
  const age = Date.now() - readAt;
  if (!state.weather || age >= HOME_REFRESH_MS || (state.weather.status === "waiting" && age >= HOME_OPEN_MS)) return loadWeather();
  return undefined;
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) keepHomeWeather();
});

whenForgotten(() => {
  window.clearTimeout(retryTimer);
  readAt = 0;
  refused = false;
  if (state.weather !== null) {
    state.weather = null;
    notify();
  }
});

// ---- the line on Home ------------------------------------------------------------------------

// The day number and "HH:MM" of `date` in the home's time zone (the phone's when the controller
// says none).
function localMoment(date, timeZone) {
  let parts;
  try {
    parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(date);
  } catch {
    parts = new Intl.DateTimeFormat("en-US", { year: "numeric", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(date);
  }
  const part = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
  const hour = part.hour === "24" ? "00" : part.hour;
  return { day: Date.UTC(Number(part.year), Number(part.month) - 1, Number(part.day)) / 86400000, clock: `${hour}:${part.minute}` };
}

const isClock = (value) => typeof value === "string" && /^\d\d:\d\d$/.test(value);

// An outside temperature (°C) in whole degrees of the project's scale (ADR-076); + 0 turns -0 into 0.
function whole(celsius) {
  const value = outside(celsius);
  return Number.isFinite(value) ? Math.round(value) + 0 : null;
}

// The sky from a WMO weather code, or null for a code it does not know: clear (0 and 1, mainly
// clear), partly cloudy, cloudy, fog, rain (drizzle and showers too), snow, thunder. Rain in the hour
// now is rain, whatever the code says, as the controller counts it (`raining`, ADR-071).
export function skyOf(code, raining = false) {
  let sky = null;
  if (code === 0 || code === 1) sky = "clear";
  else if (code === 2) sky = "partly";
  else if (code === 3) sky = "cloudy";
  else if (code === 45 || code === 48) sky = "fog";
  else if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) sky = "rain";
  else if ((code >= 71 && code <= 77) || code === 85 || code === 86) sky = "snow";
  else if (code >= 95 && code <= 99) sky = "thunder";
  if (raining && sky !== "snow" && sky !== "thunder") sky = "rain";
  return sky;
}

const SKY_ICONS = { clear: ["sun", "moon"], partly: ["cloudSun", "cloudMoon"], cloudy: ["cloud"], fog: ["fog"], rain: ["rain"], snow: ["snowflake"], thunder: ["thunder"] };

// What Home's line says for `weather` (GET /v1/weather) at `now`, or null when there is no weather:
// { sky, icon, now (the temperature), parts: ["Today 23°–30°", "rain 14%", "sunset 18:13"] }.
// "Today" until 15:00 local, then "Tomorrow"; the chance of rain of that day from 10%; the next sun
// event only: sunrise before it, sunset until it, then tomorrow's sunrise. Read before midnight and
// shown after it, tomorrow is today.
export function homeWeather(weather, now = new Date()) {
  const current = weather?.status === "ok" ? weather.current : null;
  const temperature = whole(current?.temperature);
  if (temperature === null) return null;
  const zone = homeZone();
  const here = localMoment(now, zone);
  const readFor = new Date(weather.forecast_for || "");
  const shift = Number.isNaN(readFor.getTime()) ? 0 : Math.max(0, here.day - localMoment(readFor, zone).day);
  // Read days ago (a phone asleep since): the next read comes first.
  if (shift > 1) return null;
  const [today = {}, tomorrow = {}] = [weather.today, weather.tomorrow].slice(shift).map((day) => day || {});
  const clock = here.clock;

  const range = (day) => {
    const low = whole(day.min_temperature);
    const high = whole(day.max_temperature);
    return low === null || high === null ? null : formatTemperatureRange(low, high);
  };
  // Tomorrow from 15:00, when the controller says it (an older one says today only).
  const later = clock >= TOMORROW_FROM && range(tomorrow) !== null;
  const day = later ? tomorrow : today;
  const parts = [];
  const shown = range(day);
  if (shown) parts.push(t(later ? "home.weather.tomorrow" : "home.weather.today", { range: shown }));
  const chance = Number.isFinite(day.rain_chance) ? Math.round(day.rain_chance) : null;
  if (chance !== null && chance >= RAIN_FROM) parts.push(t("home.weather.rain", { percent: `\u2066${chance}%\u2069` }));
  if (isClock(today.sunrise) && clock < today.sunrise) parts.push(t("home.weather.sunrise", { time: today.sunrise }));
  else if (isClock(today.sunset) && clock < today.sunset) parts.push(t("home.weather.sunset", { time: today.sunset }));
  else if (isClock(tomorrow.sunrise)) parts.push(t("home.weather.sunrise", { time: tomorrow.sunrise }));

  const night = isClock(today.sunrise) && isClock(today.sunset) && (clock < today.sunrise || clock >= today.sunset);
  const sky = skyOf(current.weather_code, current.raining === true);
  const icons = SKY_ICONS[sky] || ["climate"];
  return { sky, icon: night && icons[1] ? icons[1] : icons[0], now: formatTemperature(temperature), parts };
}

// The whole line as text, "Now 27° · Today 23°–30° · rain 14% · sunset 18:13", or "".
export function homeWeatherText(weather = state.weather, now = new Date()) {
  const line = homeWeather(weather, now);
  return line ? [`${t("home.weather.now")} ${line.now}`, ...line.parts].join(" · ") : "";
}
