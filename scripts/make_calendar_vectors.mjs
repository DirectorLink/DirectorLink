#!/usr/bin/env node
// Writes the reference data of the Jewish calendar's tests (docs/CALENDAR.md, ADR-037) from
// Hebcal.com: tests/vectors/calendar/hebcal-*.json and names.json. Run by hand, not in CI (Node 22,
// no dependencies), from anywhere:
//
//   node scripts/make_calendar_vectors.mjs
//
// Privacy: it asks only https://www.hebcal.com, and only for the fixed public places below, by
// GeoNames id. It takes no arguments and no coordinates, so no home's location can ever be sent.
// Every request says b=20&m=42 (candle lighting 20 minutes before sunset, havdalah 42 after) and
// i=on or i=off (Israel or abroad), and it waits 300 ms between requests.
//
// Hebcal's data is under CC BY 4.0: the script reads Hebcal's API terms first and stops if they no
// longer say so; each file records the attribution, the queries and the date (see also NOTICE).

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "tests", "vectors", "calendar");
const HOST = "https://www.hebcal.com";
const TERMS = `${HOST}/home/195/jewish-calendar-rest-api`;
const LICENSE_TEXT = "Creative Commons Attribution 4.0";
const ATTRIBUTION = "Hebcal.com, CC BY 4.0";
const LICENSE = "https://creativecommons.org/licenses/by/4.0/";
const PAUSE_MS = 300;
const TIMES = "b=20&m=42";

// Public places by GeoNames id (Hebcal answers with its own record of each: name, coordinates,
// time zone). Tromso is 3133895; 3133880 is Trondheim, which has sunsets all year.
const CITIES = [
  { file: "tel-aviv", geonameid: 293397, israel: true, why: "Israel" },
  { file: "new-york", geonameid: 5128581, israel: false, why: "abroad, with US daylight saving time" },
  { file: "buenos-aires", geonameid: 3435910, israel: false, why: "the southern hemisphere" },
  { file: "reykjavik", geonameid: 3413829, israel: false, why: "sunsets after midnight in June" },
  { file: "tromso", geonameid: 3133895, israel: false, why: "the midnight sun and the polar night" },
];

const YEARS = [5760, 5820]; // holidays and weekly readings, both locales: every year type
const MONTH_YEARS = [5660, 5960]; // the first day of every month
const CIVIL_YEARS = [2024, 2035]; // candle lighting and havdalah
const SUN_YEAR = 2026; // sunrise and sunset, day by day
// The zmanim API answers at most 180 days at a time.
const SUN_RANGES = [["01-01", "04-30"], ["05-01", "08-31"], ["09-01", "12-31"]];

const fetched = new Date().toISOString().slice(0, 10);
const credit = { attribution: ATTRIBUTION, license: LICENSE, terms: TERMS, fetched };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let lastRequest = 0;
let requests = 0;

// Every query the script sends goes through here.
function checkQuery(url) {
  const parsed = new URL(url);
  if (parsed.origin !== HOST) {
    throw new Error(`only ${HOST} is asked, not ${url}`);
  }
  const params = parsed.searchParams;
  for (const name of params.keys()) {
    if (/^(lat|latitude|lon|long|longitude|zip|city|tzid|geo)$/i.test(name)) {
      throw new Error(`no location but a fixed geonameid is ever sent (${name} in ${url})`);
    }
  }
  const id = params.get("geonameid");
  if (id !== null && !CITIES.some((city) => String(city.geonameid) === id)) {
    throw new Error(`geonameid ${id} is not one of the fixed places`);
  }
  if (params.get("b") !== "20" || params.get("m") !== "42" || !["on", "off"].includes(params.get("i"))) {
    throw new Error(`every query says b=20&m=42 and i=on|off: ${url}`);
  }
}

async function get(url, kind = "json") {
  if (kind === "json") {
    checkQuery(url);
  } else if (url !== TERMS) {
    throw new Error(`unexpected page ${url}`);
  }
  for (let attempt = 1; ; attempt++) {
    const wait = lastRequest + PAUSE_MS - Date.now();
    if (wait > 0) {
      await sleep(wait);
    }
    lastRequest = Date.now();
    requests++;
    let problem;
    try {
      const response = await fetch(url, { headers: { "User-Agent": "DirectorLink calendar test data (github.directorlink.io)" } });
      if (response.ok) {
        return kind === "json" ? await response.json() : await response.text();
      }
      problem = `HTTP ${response.status}`;
      if (response.status < 500 && response.status !== 429) {
        attempt = Infinity;
      }
    } catch (error) {
      problem = error.message;
    }
    if (attempt >= 4) {
      throw new Error(`${problem} for ${url}`);
    }
    await sleep(3000 * attempt);
  }
}

function query(path, params) {
  return `${HOST}/${path}?${params}&${TIMES}`;
}

const hebcal = (params) => query("hebcal", `v=1&cfg=json&${params}`);

// Hebcal's ASCII spelling (title_orig when Hebcal prints the title with curly quotes).
const titleOf = (item) => item.title_orig ?? item.title;

// JSON with the first two levels one entry per line, the rest compact.
function format(value, depth = 0) {
  const inner = (child) => format(child, depth + 1);
  if (depth < 2 && Array.isArray(value)) {
    return value.length ? `[\n${value.map(inner).join(",\n")}\n]` : "[]";
  }
  if (depth < 2 && value && typeof value === "object") {
    const entries = Object.entries(value).map(([key, child]) => `${JSON.stringify(key)}: ${inner(child)}`);
    return `{\n${entries.join(",\n")}\n}`;
  }
  return JSON.stringify(value);
}

function write(name, value) {
  const text = format(value) + "\n";
  writeFileSync(join(OUT, name), text);
  console.log(`${name}: ${(text.length / 1024).toFixed(0)} KB`);
  return text.length;
}

const range = ([first, last]) => Array.from({ length: last - first + 1 }, (_, index) => first + index);
const dayNumber = (date) => Date.parse(`${date}T00:00:00Z`) / 86400000;
const weekday = (date) => new Date(`${date}T00:00:00Z`).getUTCDay();

function location(record) {
  const { title, geonameid, latitude, longitude, tzid, cc } = record;
  return { title, geonameid, latitude, longitude, tzid, cc };
}

async function checkTerms() {
  const page = await get(TERMS, "text");
  if (!page.includes(LICENSE_TEXT)) {
    throw new Error(`${TERMS} no longer says "${LICENSE_TEXT}": read Hebcal's terms and update ATTRIBUTION`);
  }
  console.log(`Hebcal's terms: ${LICENSE_TEXT} (${ATTRIBUTION})`);
}

// Holidays, Rosh Chodesh and weekly readings per Hebrew year, in Israel and abroad.
async function years(names) {
  const params = "yt=H&year={year}&maj=on&min=on&mod=on&mf=on&nx=on&s=on&ss=off&c=off&leyning=off&i={i}";
  const result = {};
  const types = new Set();
  for (const year of range(YEARS)) {
    const locales = {};
    for (const [locale, i] of [["israel", "on"], ["abroad", "off"]]) {
      const data = await get(hebcal(params.replace("{year}", year).replace("{i}", i)));
      locales[locale] = data.items
        .filter((item) => ["holiday", "roshchodesh", "parashat"].includes(item.category))
        .map((item) => {
          const title = titleOf(item);
          if (item.category === "parashat") {
            names.parashot[title.replace(/^Parashat /, "")] = item.hebrew.replace(/^פרשת /, "");
          } else if (/^Rosh Hashana \d+$/.test(title)) {
            names.holidays["Rosh Hashana"] = item.hebrew.replace(/ \d+$/, "");
          } else {
            names.holidays[title] = item.hebrew;
          }
          return item.yomtov ? [item.date, title, true] : [item.date, title];
        });
    }
    const key = (event) => JSON.stringify(event);
    const abroad = new Set(locales.abroad.map(key));
    const israel = new Set(locales.israel.map(key));
    result[year] = {
      both: locales.israel.filter((event) => abroad.has(key(event))),
      israel: locales.israel.filter((event) => !abroad.has(key(event))),
      abroad: locales.abroad.filter((event) => !israel.has(key(event))),
    };
    // The year's type: the weekday of Rosh Hashana and the year's length.
    const all = locales.abroad;
    const newYear = all.find(([, title]) => title === `Rosh Hashana ${year}`);
    const erevs = all.filter(([, title]) => title === "Erev Rosh Hashana");
    if (!newYear || !erevs.length) {
      throw new Error(`no Rosh Hashana in ${year}`);
    }
    const length = dayNumber(erevs[erevs.length - 1][0]) + 1 - dayNumber(newYear[0]);
    types.add(`${weekday(newYear[0])}/${length}`);
    process.stdout.write(`\ryears: ${year}`);
  }
  console.log("");
  if (types.size !== 14) {
    throw new Error(`the years ${YEARS.join("-")} have ${types.size} of the 14 year types: ${[...types].sort().join(" ")}`);
  }
  console.log(`year types: all 14 (${[...types].sort().join(" ")})`);
  return write("hebcal-years.json", {
    about:
      `Hebcal's holidays, Rosh Chodesh and weekly readings for the Hebrew years ${YEARS.join("-")}, in Israel (i=on) and abroad (i=off), for driver/tests/test_holidays.lua and test_parasha.lua. ` +
      "Each event is [civil date, title] in Hebcal's ASCII spelling (its title_orig), with a third item true on a Yom Tov. " +
      "Events that are the same in Israel and abroad are under both, the others under israel or abroad. All 14 year types occur.",
    ...credit,
    url: hebcal(params),
    years: result,
  });
}

// The first day of every month but Tishrei: the last day of its Rosh Chodesh.
async function months() {
  const params = "yt=H&year={year}&nx=on&maj=off&min=off&mod=off&mf=off&s=off&ss=off&c=off&leyning=off&i=off";
  const result = {};
  for (const year of range(MONTH_YEARS)) {
    const data = await get(hebcal(params.replace("{year}", year)));
    const starts = {};
    for (const item of data.items) {
      if (item.category === "roshchodesh") {
        starts[titleOf(item).replace(/^Rosh Chodesh /, "")] = item.date;
      }
    }
    const count = Object.keys(starts).length;
    if (count !== 11 && count !== 12) {
      throw new Error(`${year} has ${count} months with a Rosh Chodesh`);
    }
    result[year] = starts;
    process.stdout.write(`\rmonths: ${year}`);
  }
  console.log("");
  return write("hebcal-months.json", {
    about:
      `The first day of every Hebrew month but Tishrei, ${MONTH_YEARS.join("-")}, as Hebcal names the month: the last day of its Rosh Chodesh (nx=on only), for driver/tests/test_hebrew_date.lua. ` +
      "1 Tishrei is Rosh Hashana, in hebcal-years.json.",
    ...credit,
    url: hebcal(params),
    years: result,
  });
}

// Candle lighting and havdalah in one place, year by year.
async function times(city) {
  const i = city.israel ? "on" : "off";
  const urls = range(CIVIL_YEARS).map((year) =>
    hebcal(`year=${year}&c=on&maj=on&min=off&mod=off&mf=off&nx=off&s=off&ss=off&leyning=off&geonameid=${city.geonameid}&i=${i}`),
  );
  const events = [];
  let place;
  for (const url of urls) {
    const data = await get(url);
    place = location(data.location);
    for (const item of data.items) {
      if (item.category === "candles" || item.category === "havdalah") {
        events.push([item.date, item.category]);
      }
    }
  }
  if (place.geonameid !== city.geonameid) {
    throw new Error(`Hebcal answered for ${JSON.stringify(place)}, not ${city.geonameid}`);
  }
  return write(`hebcal-times-${city.file}.json`, {
    about:
      `Hebcal's candle lighting (20 minutes before sunset) and havdalah (42 minutes after) in ${place.title} (${city.why}), ${CIVIL_YEARS.join("-")}, ${city.israel ? "in Israel" : "abroad"}: [local time, "candles" or "havdalah"], for driver/tests/test_holy_times.lua.`,
    ...credit,
    location: place,
    israel: city.israel,
    urls,
    events,
  });
}

// Sunrise and sunset day by day, to the second.
async function sun(city) {
  const i = city.israel ? "on" : "off";
  const urls = SUN_RANGES.map(([start, end]) => query("zmanim", `cfg=json&geonameid=${city.geonameid}&start=${SUN_YEAR}-${start}&end=${SUN_YEAR}-${end}&sec=1&i=${i}`));
  const days = [];
  let place;
  for (const url of urls) {
    const data = await get(url);
    place = location(data.location);
    const { sunrise, sunset } = data.times;
    const dates = Object.keys(sunrise).sort();
    const { start, end } = data.date;
    if (dates[0] !== start || dates[dates.length - 1] !== end || dates.length !== dayNumber(end) - dayNumber(start) + 1) {
      throw new Error(`${url} did not answer every day`);
    }
    for (const date of dates) {
      days.push([date, sunrise[date] ?? null, sunset[date] ?? null]);
    }
  }
  if (place.geonameid !== city.geonameid) {
    throw new Error(`Hebcal answered for ${JSON.stringify(place)}, not ${city.geonameid}`);
  }
  return write(`hebcal-sun-${city.file}.json`, {
    about:
      `Hebcal's sunrise and sunset (sea level, to the second) in ${place.title} (${city.why}) every day of ${SUN_YEAR}: [date, sunrise, sunset] in local time, null when the sun does not rise or set, for driver/tests/test_sun.lua.`,
    ...credit,
    location: place,
    urls,
    days,
  });
}

async function main() {
  mkdirSync(OUT, { recursive: true });
  await checkTerms();
  const names = { parashot: {}, holidays: {} };
  let total = 0;
  total += await years(names);
  const sorted = (object) => Object.fromEntries(Object.entries(object).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
  total += write("names.json", {
    about:
      "Hebcal's English titles (ASCII spelling) and Hebrew names of the weekly readings and the holidays in hebcal-years.json, for the app's tests: " +
      "parashot by name without 'Parashat ' (combined readings too), holidays by title (Rosh Hashana without its year).",
    ...credit,
    source: "the queries of hebcal-years.json",
    parashot: sorted(names.parashot),
    holidays: sorted(names.holidays),
  });
  total += await months();
  for (const city of CITIES) {
    total += await times(city);
    total += await sun(city);
  }
  console.log(`${requests} requests; ${(total / 1024).toFixed(0)} KB written to ${OUT}`);
}

main().catch((error) => {
  console.error(`ERROR: ${error.message}`);
  process.exit(1);
});
