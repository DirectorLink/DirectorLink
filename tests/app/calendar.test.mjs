// The Jewish calendar in the app (1.2.0, ADR-037): Hebrew numerals and dates, the names of the
// months, holidays and weekly readings in both languages, what schedules say about Shabbat, what the
// schedule editor offers and sends with the calendar on, off and with a driver before 1.2.0, the
// times on Schedules and the line on Home for the calendar API's examples
// (tests/vectors/calendar/api-examples.json), and when the app reads GET /v1/calendar.
//   node --test tests/app/

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test, { after } from "node:test";

// Just enough of a browser for these modules: the elements the views build, storage and frames.
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener() {}
  append(...children) {
    this.children.push(...children);
  }
  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", hash: "" };
globalThis.document = {
  hidden: false,
  documentElement: {},
  addEventListener() {},
  querySelector: () => null,
  getElementById: () => null,
  createElement: (tag) => new FakeElement(tag),
  createElementNS: (_namespace, tag) => new FakeElement(tag),
  createTextNode: (text) => Object.assign(new FakeNode(), { textContent: String(text) }),
};
globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0);
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};

const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { ApiError } = await import("../../app/api-client.js");
const { errorText } = await import("../../app/js/session.js");
const calendar = await import("../../app/js/calendar.js");
const { conditionText, formatOffset, scheduleIcon, statusText, whenText } = await import("../../app/js/schedules.js");
const { draftFor, resetScheduleEditor, scheduleBody, scheduleEditorView, schedulesView } = await import("../../app/js/views/schedules.js");
const { homeView } = await import("../../app/js/views/home.js");
const { resetCalendarSettings, settingsView } = await import("../../app/js/views/settings.js");
const { default: en } = await import("../../app/i18n/en.js");
const { default: he } = await import("../../app/i18n/he.js");

const { hebrewDateText, hebrewNumeral, holidayLabel, holyTimes, homeLine, loadCalendar, keepCalendar, nextChange, noteCalendarOff, parashaName } = calendar;
const EXAMPLES = JSON.parse(readFileSync(new URL("../vectors/calendar/api-examples.json", import.meta.url), "utf8"));
const NAMES = new URL("../vectors/calendar/names.json", import.meta.url);
const ALL_DAYS = [0, 1, 2, 3, 4, 5, 6];

// The design's names (docs: design Appendix A), Hebcal's spelling in both languages, except where
// the owner chose the full Hebrew spelling for four weekly readings.
const MONTHS = [
  ["tishrei", "Tishrei", "תשרי"],
  ["cheshvan", "Cheshvan", "חשוון"],
  ["kislev", "Kislev", "כסלו"],
  ["tevet", "Tevet", "טבת"],
  ["shvat", "Sh’vat", "שבט"],
  ["adar", "Adar", "אדר"],
  ["adar_1", "Adar I", "אדר א׳"],
  ["adar_2", "Adar II", "אדר ב׳"],
  ["nisan", "Nisan", "ניסן"],
  ["iyar", "Iyyar", "אייר"],
  ["sivan", "Sivan", "סיוון"],
  ["tamuz", "Tamuz", "תמוז"],
  ["av", "Av", "אב"],
  ["elul", "Elul", "אלול"],
];
const HOLIDAYS = [
  ["rosh_hashana", "Rosh Hashana", "ראש השנה"],
  ["tzom_gedaliah", "Tzom Gedaliah", "צום גדליה"],
  ["yom_kippur", "Yom Kippur", "יום כיפור"],
  ["sukkot", "Sukkot", "סוכות"],
  ["chol_hamoed_sukkot", "Chol HaMoed Sukkot", "חול המועד סוכות"],
  ["hoshana_rabba", "Hoshana Rabba", "הושענא רבה"],
  ["shmini_atzeret", "Shmini Atzeret", "שמיני עצרת"],
  ["simchat_torah", "Simchat Torah", "שמחת תורה"],
  ["chanukah", "Chanukah", "חנוכה"],
  ["asara_btevet", "Asara B’Tevet", "עשרה בטבת"],
  ["tu_bishvat", "Tu BiShvat", "ט״ו בשבט"],
  ["taanit_esther", "Ta’anit Esther", "תענית אסתר"],
  ["purim", "Purim", "פורים"],
  ["shushan_purim", "Shushan Purim", "שושן פורים"],
  ["pesach", "Pesach", "פסח"],
  ["chol_hamoed_pesach", "Chol HaMoed Pesach", "חול המועד פסח"],
  ["pesach_7", "Seventh day of Pesach", "שביעי של פסח"],
  ["pesach_8", "Eighth day of Pesach", "אחרון של פסח"],
  ["yom_hashoah", "Yom HaShoah", "יום השואה"],
  ["yom_haatzmaut", "Yom HaAtzma’ut", "יום העצמאות"],
  ["yom_hazikaron", "Yom HaZikaron", "יום הזיכרון"],
  ["lag_baomer", "Lag BaOmer", "ל״ג בעומר"],
  ["yom_yerushalayim", "Yom Yerushalayim", "יום ירושלים"],
  ["shavuot", "Shavuot", "שבועות"],
  ["shiva_asar_btamuz", "Tzom Tammuz", "צום י״ז בתמוז"],
  ["tisha_bav", "Tish’a B’Av", "תשעה באב"],
  ["rosh_chodesh", "Rosh Chodesh {month}", "ראש חודש {month}"],
];
const PARASHOT = [
  "Bereshit בראשית", "Noach נח", "Lech-Lecha לך־לך", "Vayera וירא", "Chayei Sara חיי שרה", "Toldot תולדות",
  "Vayetzei ויצא", "Vayishlach וישלח", "Vayeshev וישב", "Miketz מקץ", "Vayigash ויגש", "Vayechi ויחי",
  "Shemot שמות", "Vaera וארא", "Bo בא", "Beshalach בשלח", "Yitro יתרו", "Mishpatim משפטים", "Terumah תרומה",
  "Tetzaveh תצוה", "Ki Tisa כי תשא", "Vayakhel ויקהל", "Pekudei פקודי", "Vayikra ויקרא", "Tzav צו",
  "Shmini שמיני", "Tazria תזריע", "Metzora מצרע", "Achrei Mot אחרי מות", "Kedoshim קדשים", "Emor אמור",
  "Behar בהר", "Bechukotai בחקתי", "Bamidbar במדבר", "Nasso נשא", "Beha’alotcha בהעלתך", "Sh’lach שלח־לך",
  "Korach קורח", "Chukat חוקת", "Balak בלק", "Pinchas פינחס", "Matot מטות", "Masei מסעי", "Devarim דברים",
  "Vaetchanan ואתחנן", "Eikev עקב", "Re’eh ראה", "Shoftim שופטים", "Ki Teitzei כי־תצא", "Ki Tavo כי־תבוא",
  "Nitzavim נצבים", "Vayeilech וילך", "Ha’azinu האזינו", "Vezot Haberakhah וזאת הברכה",
].map((line) => {
  const split = line.search(/[א-ת]/);
  return [line.slice(0, split).trim(), line.slice(split)];
});
// The owner's full spellings, in place of Hebcal's.
const FULL_SPELLING = { 28: ["מצרע", "מצורע"], 30: ["קדשים", "קדושים"], 33: ["בחקתי", "בחוקותי"], 36: ["בהעלתך", "בהעלותך"] };
const COMBINED = [[22, 23], [27, 28], [29, 30], [32, 33], [39, 40], [42, 43], [51, 52]];

// A fixed clock: `new Date()` and Date.now() are `iso` until realTime().
const RealDate = Date;
function atTime(iso) {
  const fixed = RealDate.parse(iso);
  globalThis.Date = class extends RealDate {
    constructor(...args) {
      super(...(args.length ? args : [fixed]));
    }
    static now() {
      return fixed;
    }
  };
}
function realTime() {
  globalThis.Date = RealDate;
}

async function inHebrew(check) {
  await setLanguage("he");
  try {
    await check();
  } finally {
    await setLanguage("en");
  }
}

// The controller's /v1/system: `features` as a 1.2.0 driver has it, or none (before 1.2.0).
function system(features, timezone = "Asia/Jerusalem") {
  state.system = { location: { timezone }, ...(features === undefined ? {} : { features }) };
}
const FEATURES = [
  ["a driver before 1.2.0 (no features)", undefined, false],
  ["the calendar off in Composer", { jewish_calendar: false }, false],
  ["the calendar on", { jewish_calendar: true }, true],
];

// What a screen holds: the data-keys, the text, an element by class.
function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function keysOf(nodes) {
  const keys = [];
  walk(nodes, (node) => node.dataset?.key && keys.push(node.dataset.key));
  return keys;
}
function textOf(nodes) {
  return [nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" | ");
}
function byKey(nodes, key) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node.dataset?.key === key) found = node;
  });
  return found;
}
function byClass(nodes, name) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && typeof node.className === "string" && node.className.split(/\s+/).includes(name)) found = node;
  });
  return found;
}

const SCENES = [
  { id: "0a1b2c3d", name: "Shabbat lights" },
  { id: "1b2c3d4e", name: "After Shabbat" },
  { id: "2c3d4e5f", name: "Boiler" },
  { id: "3d4e5f60", name: "Oven" },
  { id: "4e5f6071", name: "Garden" },
];
// An admin connected to a home with the example schedules (calendar_on).
function connectedAdmin(schedules = EXAMPLES.ScheduleList.calendar_on.value.items) {
  Object.assign(state, { host: "192.0.2.10", apiKey: "ak_test", transport: "lan", status: "connected", loaded: true, role: "admin" });
  state.scenes = SCENES;
  state.schedules = structuredClone(schedules);
  state.schedulesPaused = false;
  state.schedulesUnsupported = false;
  resetScheduleEditor();
}
const exampleSchedule = (id, list = "calendar_on") => structuredClone(EXAMPLES.ScheduleList[list].value.items.find((item) => item.id === id));

after(() => {
  // Nothing planned stays behind (a read a few seconds after the next change).
  noteCalendarOff({ code: "JEWISH_CALENDAR_OFF" });
  realTime();
});

// ---- words -------------------------------------------------------------------------------------

test("Hebrew numerals: ט״ו and ט״ז, a geresh after one letter, gershayim before the last", () => {
  const cases = [
    [1, "א׳"], [9, "ט׳"], [10, "י׳"], [15, "ט״ו"], [16, "ט״ז"], [18, "י״ח"], [21, "כ״א"], [30, "ל׳"],
    [100, "ק׳"], [115, "קט״ו"], [400, "ת׳"], [500, "ת״ק"], [715, "תשט״ו"], [716, "תשט״ז"], [785, "תשפ״ה"],
    [787, "תשפ״ז"], [800, "ת״ת"], [999, "תתקצ״ט"],
  ];
  for (const [number, letters] of cases) assert.equal(hebrewNumeral(number), letters, String(number));
  for (const outside of [0, 1000, 2.5, "x"]) assert.equal(hebrewNumeral(outside), String(outside), "out of range: as it is");
});

test("Hebrew dates in English and in Hebrew, Adar I and II of the leap year 5787 too", async () => {
  const dates = [
    [{ year: 5787, month: "tishrei", day: 18, leap_year: true }, "18 Tishrei 5787", "י״ח בתשרי תשפ״ז"],
    [{ year: 5787, month: "cheshvan", day: 30, leap_year: true }, "30 Cheshvan 5787", "ל׳ בחשוון תשפ״ז"],
    [{ year: 5787, month: "adar_1", day: 1, leap_year: true }, "1 Adar I 5787", "א׳ באדר א׳ תשפ״ז"],
    [{ year: 5787, month: "adar_1", day: 30, leap_year: true }, "30 Adar I 5787", "ל׳ באדר א׳ תשפ״ז"],
    [{ year: 5787, month: "adar_2", day: 14, leap_year: true }, "14 Adar II 5787", "י״ד באדר ב׳ תשפ״ז"],
    [{ year: 5786, month: "adar", day: 15, leap_year: false }, "15 Adar 5786", "ט״ו באדר תשפ״ו"],
    [{ year: 5785, month: "shvat", day: 16, leap_year: false }, "16 Sh’vat 5785", "ט״ז בשבט תשפ״ה"],
    [{ year: 5715, month: "iyar", day: 5, leap_year: false }, "5 Iyyar 5715", "ה׳ באייר תשט״ו"],
  ];
  for (const [date, english] of dates) assert.equal(hebrewDateText(date), english);
  await inHebrew(() => {
    for (const [date, , hebrew] of dates) assert.equal(hebrewDateText(date), hebrew);
  });
});

test("every month, holiday and weekly reading has its name, in both languages", () => {
  for (const [key, english, hebrew] of MONTHS) {
    assert.equal(en.calendar.months[key], english, key);
    assert.equal(he.calendar.months[key], hebrew, key);
  }
  for (const [key, english, hebrew] of HOLIDAYS) {
    assert.equal(en.calendar.holidays[key], english, key);
    assert.equal(he.calendar.holidays[key], hebrew, key);
  }
  assert.equal(PARASHOT.length, 54);
  PARASHOT.forEach(([english, hebcal], index) => {
    const id = index + 1;
    assert.equal(en.calendar.parashot[id], english, `parasha ${id}`);
    assert.equal(he.calendar.parashot[id], FULL_SPELLING[id]?.[1] ?? hebcal, `parasha ${id}`);
  });
  assert.equal(Object.keys(en.calendar.parashot).length, 54);
  assert.equal(Object.keys(he.calendar.parashot).length, 54);
});

test("weekly readings: combined ones joined with - in English and a maqaf in Hebrew", async () => {
  const expected = {
    "22,23": ["Vayakhel-Pekudei", "ויקהל־פקודי"],
    "27,28": ["Tazria-Metzora", "תזריע־מצורע"],
    "29,30": ["Achrei Mot-Kedoshim", "אחרי מות־קדושים"],
    "32,33": ["Behar-Bechukotai", "בהר־בחוקותי"],
    "39,40": ["Chukat-Balak", "חוקת־בלק"],
    "42,43": ["Matot-Masei", "מטות־מסעי"],
    "51,52": ["Nitzavim-Vayeilech", "נצבים־וילך"],
    53: ["Ha’azinu", "האזינו"],
    36: ["Beha’alotcha", "בהעלותך"],
  };
  // The API's name is Hebcal's ASCII spelling (Ha'azinu): the app shows its own.
  const reading = (key) => ({ ids: String(key).split(",").map(Number), name: "Ha'azinu" });
  for (const [key, [english]] of Object.entries(expected)) assert.equal(parashaName(reading(key)), english);
  assert.equal(parashaName({ ids: [55], name: "Newly Named" }), "Newly Named", "an unknown reading: the API's name");
  await inHebrew(() => {
    for (const [key, [, hebrew]] of Object.entries(expected)) assert.equal(parashaName(reading(key)), hebrew);
  });
});

// Every [English, Hebrew] pair names.json holds, whatever its shape: objects with an English and a
// Hebrew string, arrays of two, and Hebrew names keyed by English ones.
const HEBREW_LETTER = /[א-ת]/;
function namePairs(node, pairs = []) {
  if (Array.isArray(node)) {
    if (node.length === 2 && node.every((item) => typeof item === "string") && !HEBREW_LETTER.test(node[0]) && HEBREW_LETTER.test(node[1])) pairs.push(node);
    for (const item of node) namePairs(item, pairs);
  } else if (node && typeof node === "object") {
    const strings = Object.values(node).filter((value) => typeof value === "string");
    const hebrew = strings.filter((value) => HEBREW_LETTER.test(value));
    if (hebrew.length === 1) for (const value of strings.filter((item) => /[A-Za-z]/.test(item) && !HEBREW_LETTER.test(item))) pairs.push([value, hebrew[0]]);
    for (const [key, value] of Object.entries(node)) {
      if (typeof value === "string" && HEBREW_LETTER.test(value) && /[A-Za-z]/.test(key)) pairs.push([key, value]);
      namePairs(value, pairs);
    }
  }
  return pairs;
}

test("weekly readings against Hebcal's names (names.json), the owner's full spellings aside", { skip: !existsSync(NAMES) && "names.json comes with the calendar engine's vectors" }, async () => {
  const plain = (text) => text.replace(/[’`]/g, "'").replace(/^Parashat\s+/i, "").trim();
  const ids = new Map(PARASHOT.map(([english], index) => [plain(english), [index + 1]]));
  for (const pair of COMBINED) ids.set(pair.map((id) => plain(PARASHOT[id - 1][0])).join("-"), pair);
  const full = new Map(Object.values(FULL_SPELLING));
  // Hebcal's Hebrew without its vowel points, each part in the owner's spelling.
  const owner = (text) =>
    text
      .replace(/[֑-ֽֿ-ׇ]/g, "")
      .replace(/^פרשת\s+/, "")
      .trim()
      .split(/\s*[-־]\s*/)
      .map((part) => full.get(part) ?? part)
      .join("־");
  const found = new Map();
  for (const [english, hebrew] of namePairs(JSON.parse(readFileSync(NAMES, "utf8")))) {
    const reading = ids.get(plain(english));
    if (reading) found.set(reading.join(","), { reading, hebrew });
  }
  const singles = [...found.values()].filter(({ reading }) => reading.length === 1);
  assert.ok(singles.length >= 50, `names.json has the weekly readings (found ${singles.length} of 54)`);
  await inHebrew(() => {
    const wrong = [...found.values()].filter(({ reading, hebrew }) => parashaName({ ids: reading }) !== owner(hebrew)).map(({ reading, hebrew }) => `${reading}: ${hebrew} / ${parashaName({ ids: reading })}`);
    assert.deepEqual(wrong, []);
  });
});

test("holiday labels, with the day of a holiday kept on several", async () => {
  const labels = [
    [{ key: "chanukah", day: 3 }, false, "Chanukah, day 3", "חנוכה, יום ג׳"],
    [{ key: "chanukah", day: 8 }, true, "Chanukah, day 8", "חנוכה, יום ח׳"],
    [{ key: "rosh_hashana", day: 2 }, true, "Rosh Hashana, day 2", "ראש השנה, יום ב׳"],
    [{ key: "rosh_chodesh", day: null, month: "cheshvan" }, true, "Rosh Chodesh Cheshvan", "ראש חודש חשוון"],
    [{ key: "rosh_chodesh", day: null, month: "adar_1" }, true, "Rosh Chodesh Adar I", "ראש חודש אדר א׳"],
    [{ key: "chol_hamoed_pesach", day: null }, true, "Chol HaMoed Pesach", "חול המועד פסח"],
    // Kept one day in Israel: its day is not numbered there.
    [{ key: "sukkot", day: 1 }, true, "Sukkot", "סוכות"],
    [{ key: "sukkot", day: 2 }, false, "Sukkot, day 2", "סוכות, יום ב׳"],
    [{ key: "shavuot", day: 1 }, false, "Shavuot, day 1", "שבועות, יום א׳"],
    [{ key: "yom_hamishpacha", day: null, name: "Family Day" }, true, "Family Day", "Family Day"],
  ];
  for (const [holiday, israel, english] of labels) assert.equal(holidayLabel(holiday, israel), english);
  await inHebrew(() => {
    for (const [holiday, israel, , hebrew] of labels) assert.equal(holidayLabel(holiday, israel), hebrew);
  });
});

// ---- schedules ---------------------------------------------------------------------------------

test("what a Shabbat trigger and the Shabbat condition say, in both languages", async () => {
  const shabbat = (event, offset, days = ALL_DAYS) => ({ trigger: { type: "shabbat", event, offset }, days, only_if: {}, during_shabbat: "run" });
  const when = [
    [shabbat("candle_lighting", -30), "30 min before candle lighting", "30 דק׳ לפני הדלקת נרות"],
    [shabbat("candle_lighting", 0), "At candle lighting", "בהדלקת נרות"],
    [shabbat("havdalah", 0), "At havdalah", "בהבדלה"],
    [shabbat("havdalah", 20), "20 min after havdalah", "20 דק׳ אחרי ההבדלה"],
    [shabbat("candle_lighting", -90), "1 h 30 min before candle lighting", "שעה וחצי לפני הדלקת נרות"],
    [shabbat("havdalah", 120), "2 h after havdalah", "שעתיים אחרי ההבדלה"],
    [shabbat("havdalah", -75), "1 h 15 min before havdalah", "שעה ו-15 דק׳ לפני ההבדלה"],
    [shabbat("candle_lighting", 360), "6 h after candle lighting", "6 שעות אחרי הדלקת נרות"],
  ];
  const time = (during, onlyIf = {}) => ({ trigger: { type: "time", at: "06:30" }, days: ALL_DAYS, only_if: onlyIf, during_shabbat: during });
  const condition = [
    [time("run"), "", ""],
    [time("skip"), "Not on Shabbat and holidays", "לא בשבתות ובחגים"],
    [time("only"), "Only on Shabbat and holidays", "רק בשבתות ובחגים"],
    [{ ...time("skip", { not_raining: true }), trigger: { type: "sun", event: "sunset", offset: -15 } }, "Only if it isn’t raining · Not on Shabbat and holidays", "רק אם לא יורד גשם · לא בשבתות ובחגים"],
    [{ trigger: { type: "weather", kind: "rain", once_a_day: true }, days: ALL_DAYS, only_if: {}, during_shabbat: "only" }, "At most once a day · Only on Shabbat and holidays", "לכל היותר פעם ביום · רק בשבתות ובחגים"],
    // A Shabbat trigger set through the API for some weekdays only.
    [shabbat("havdalah", 0, [6]), "Every Saturday", "כל יום שבת"],
    [{ ...shabbat("candle_lighting", -30), only_if: { not_raining: true } }, "Only if it isn’t raining", "רק אם לא יורד גשם"],
    // A driver before 1.2.0 has no during_shabbat.
    [{ trigger: { type: "time", at: "07:00" }, days: ALL_DAYS, only_if: {} }, "", ""],
  ];
  for (const [schedule, english] of when) assert.equal(whenText(schedule), english);
  for (const [schedule, english] of condition) assert.equal(conditionText(schedule), english);
  assert.equal(scheduleIcon(shabbat("havdalah", 0)), "candles");
  assert.deepEqual([15, 45, 60, 150, 210].map(formatOffset), ["15 min", "45 min", "1 h", "2 h 30 min", "3 h 30 min"]);
  await inHebrew(() => {
    for (const [schedule, , hebrew] of when) assert.equal(whenText(schedule), hebrew);
    for (const [schedule, , hebrew] of condition) assert.equal(conditionText(schedule), hebrew);
    assert.deepEqual([15, 45, 60, 150, 210].map(formatOffset), ["15 דק׳", "45 דק׳", "שעה", "שעתיים וחצי", "3 שעות וחצי"]);
  });
});

test("the list says what did not run on Shabbat, what ran late, and what waits for the calendar", async () => {
  state.schedulesPaused = false;
  const status = (list, id) => {
    const example = EXAMPLES.ScheduleList[list];
    system({ jewish_calendar: list !== "calendar_off" }, example.timezone);
    return statusText(exampleSchedule(id, list), new Date(example.now));
  };
  const english = () => ({
    skipped: status("calendar_on", "3c4d5e6f"),
    late: status("calendar_on", "4d5e6f70"),
    offShabbat: status("calendar_off", "1a2b3c4d"),
    offSkip: status("calendar_off", "3c4d5e6f"),
    offOnly: status("calendar_off", "4d5e6f70"),
    noLocation: status("no_location", "1a2b3c4d"),
    switchedOff: status("no_location", "4d5e6f70"),
  });
  const texts = english();
  assert.equal(texts.skipped, "Didn’t run today 06:30: Shabbat or a holiday · Next: tomorrow 06:30");
  assert.match(texts.late, /^Ran today 09:10 \(late, after a restart\) · Next: /);
  assert.equal(texts.offShabbat, "Not running: the Jewish calendar is off in Composer");
  assert.equal(texts.offSkip, "Ran today 06:30 · Runs on Shabbat and holidays too while the Jewish calendar is off in Composer · Next: tomorrow 06:30");
  assert.equal(texts.offOnly, "Not running: the Jewish calendar is off in Composer");
  assert.equal(texts.noLocation, "Not running: set the home’s location in Composer");
  assert.equal(texts.switchedOff, "Off");
  await inHebrew(() => {
    const hebrew = english();
    assert.equal(hebrew.skipped, "לא הופעל היום ב-06:30: שבת או חג · הבא: מחר ב-06:30");
    assert.match(hebrew.late, /^הופעל היום ב-09:10 \(באיחור, אחרי הפעלה מחדש\) · הבא: /);
    assert.equal(hebrew.offShabbat, "לא פועל: הלוח העברי כבוי ב-Composer");
    assert.equal(hebrew.offSkip, "הופעל היום ב-06:30 · פועל גם בשבתות ובחגים, כל עוד הלוח העברי כבוי ב-Composer · הבא: מחר ב-06:30");
    assert.equal(hebrew.noLocation, "לא פועל: יש להגדיר את מיקום הבית ב-Composer");
  });
});

test("the editor sends during_shabbat only with the calendar on, and a Shabbat trigger all seven days", () => {
  for (const [label, features, on] of FEATURES) {
    connectedAdmin();
    system(features);
    const draft = draftFor("new");
    draft.during = "skip";
    const time = scheduleBody(draft);
    assert.deepEqual(time.trigger, { type: "time", at: "07:00" }, label);
    assert.equal(time.during_shabbat, on ? "skip" : undefined, `${label}: a time schedule`);
    assert.equal("during_shabbat" in time, on, label);
    // Made a Shabbat schedule: its days are not shown, and it sends all seven; the time's days wait.
    draft.days = [0, 1, 2, 3, 4];
    draft.type = "shabbat";
    const shabbat = scheduleBody(draft);
    assert.deepEqual(shabbat.trigger, { type: "shabbat", event: "candle_lighting", offset: -30 }, label);
    assert.deepEqual(shabbat.days, ALL_DAYS, label);
    assert.equal(shabbat.during_shabbat, on ? "run" : undefined, `${label}: a Shabbat trigger clears the condition`);
    draft.type = "time";
    assert.deepEqual(scheduleBody(draft).days, [0, 1, 2, 3, 4], "the time's days are back");
  }
  // A Shabbat schedule set for some weekdays through the API keeps them.
  connectedAdmin([{ ...exampleSchedule("2b3c4d5e"), days: [5, 6], trigger: { type: "shabbat", event: "havdalah", offset: 20 } }]);
  system({ jewish_calendar: true });
  const kept = scheduleBody(draftFor("2b3c4d5e"));
  assert.deepEqual(kept.days, [5, 6]);
  assert.deepEqual(kept.trigger, { type: "shabbat", event: "havdalah", offset: 20 });
  // A skip schedule opened for editing keeps its condition.
  connectedAdmin();
  assert.equal(scheduleBody(draftFor("3c4d5e6f")).during_shabbat, "skip");
});

test("the editor offers Shabbat and the Shabbat condition only with the calendar on", async () => {
  for (const [label, features, on] of FEATURES) {
    connectedAdmin();
    system(features);
    state.calendar = on ? EXAMPLES.Calendar.ok.value : null;
    const keys = keysOf(scheduleEditorView("new"));
    assert.equal(keys.includes("schedule-type:shabbat"), on, `${label}: the Shabbat kind`);
    for (const during of ["run", "skip", "only"]) assert.equal(keys.includes(`schedule-during:${during}`), on, `${label}: ${during}`);
    assert.ok(keys.includes("schedule-type:time") && keys.includes("schedule-day:0") && keys.includes("schedule-save"), label);
  }
  // A Shabbat trigger: candle lighting or havdalah with the next times, the offsets, no days.
  connectedAdmin();
  system({ jewish_calendar: true });
  state.calendar = EXAMPLES.Calendar.ok.value;
  draftFor("new").type = "shabbat";
  let view = scheduleEditorView("new");
  let keys = keysOf(view);
  assert.ok(keys.includes("schedule-shabbat-event:candle_lighting") && keys.includes("schedule-shabbat-event:havdalah"));
  assert.deepEqual(keys.filter((key) => key.startsWith("schedule-shabbat-offset:")).map((key) => Number(key.split(":")[1])), [-120, -60, -30, -15, 0, 15, 30, 60, 120]);
  assert.ok(!keys.some((key) => key.startsWith("schedule-day")), "no days for a Shabbat trigger");
  assert.ok(!keys.some((key) => key.startsWith("schedule-during")), "no condition for a Shabbat trigger");
  const text = textOf(view);
  assert.match(text, /Candle lighting \([^)]*18:04\)/);
  assert.match(text, /Havdalah \([^)]*19:05\)/);
  assert.match(text, /3 · Only if \(optional\)/);
  assert.match(text, /30 min before candle lighting · Runs ⁨Shabbat lights⁩/);
  // An offset set through the API is one more chip, pressed.
  connectedAdmin([{ ...exampleSchedule("1a2b3c4d"), trigger: { type: "shabbat", event: "candle_lighting", offset: -45 } }]);
  keys = keysOf(scheduleEditorView("1a2b3c4d"));
  assert.ok(keys.includes("schedule-shabbat-offset:-45"));
  await inHebrew(() => {
    connectedAdmin();
    draftFor("new").type = "shabbat";
    const hebrew = textOf(scheduleEditorView("new"));
    assert.match(hebrew, /הדלקת נרות \([^)]*18:04\)/);
    assert.match(hebrew, /שבת וחג/);
    assert.match(hebrew, /שעתיים לפני/);
  });
});

test("with the calendar off, a Shabbat schedule can only be switched on or off, or deleted", () => {
  for (const [label, features] of FEATURES.slice(0, 2)) {
    connectedAdmin(EXAMPLES.ScheduleList.calendar_off.value.items);
    system(features);
    const view = scheduleEditorView("1a2b3c4d");
    const keys = keysOf(view);
    assert.ok(keys.includes("schedule-enabled") && keys.includes("schedule-delete"), label);
    assert.ok(!keys.includes("schedule-save") && !keys.some((key) => key.startsWith("schedule-type:")), `${label}: nothing else`);
    assert.match(textOf(view), /30 min before candle lighting · Runs ⁨Shabbat lights⁩/);
    assert.match(textOf(view), /The Jewish calendar is off in Composer/);
    // An "only on Shabbat" time schedule is edited as usual, and says what its condition does now.
    const only = scheduleEditorView("4d5e6f70");
    assert.ok(keysOf(only).includes("schedule-save") && !keysOf(only).some((key) => key.startsWith("schedule-during")), label);
    assert.match(textOf(only), /Set to run only on Shabbat and holidays\. While the Jewish calendar is off in Composer, it doesn’t run\./);
    assert.equal(scheduleBody(draftFor("4d5e6f70")).during_shabbat, undefined, "and does not send it");
  }
  // Turned off while a new Shabbat schedule was being made: it becomes a time schedule again.
  connectedAdmin();
  system({ jewish_calendar: true });
  draftFor("new").type = "shabbat";
  system({ jewish_calendar: false });
  scheduleEditorView("new");
  assert.equal(ui.scheduleEditor.type, "time");
});

// ---- Home, Schedules and Settings --------------------------------------------------------------

test("the times on Schedules and the line on Home, from the calendar API's examples", async () => {
  const cases = {
    ok: {
      times: { title: "Shabbat · Shmini Atzeret · Simchat Torah", times: "Candle lighting Fri 18:04 · Havdalah Sat 19:05", later: "", footnote: "20 min before sunset · 42 min after · as in Israel" },
      home: "18 Tishrei 5787 · Chol HaMoed Sukkot · Shabbat Shmini Atzeret",
      hebrew: { title: "שבת · שמיני עצרת · שמחת תורה", times: "הדלקת נרות יום ו׳ 18:04 · הבדלה שבת 19:05", later: "", footnote: "20 דק׳ לפני השקיעה · 42 דק׳ אחריה · כמו בארץ" },
      homeHebrew: "י״ח בתשרי תשפ״ז · חול המועד סוכות · שבת שמיני עצרת",
    },
    three_day_period: {
      times: { title: "Rosh Hashana · Shabbat now", times: "Havdalah tomorrow 19:02", later: "Shabbat: candle lighting today 18:01", footnote: "20 min before sunset · 42 min after · as in Israel" },
      home: "2 Tishrei 5785 · Rosh Hashana, day 2 · Parashat Ha’azinu",
      hebrew: { title: "עכשיו ראש השנה · שבת", times: "הבדלה מחר ב-19:02", later: "שבת: הדלקת נרות היום ב-18:01", footnote: "20 דק׳ לפני השקיעה · 42 דק׳ אחריה · כמו בארץ" },
      homeHebrew: "ב׳ בתשרי תשפ״ה · ראש השנה, יום ב׳ · פרשת האזינו",
    },
    no_location: {
      times: { title: "", times: "Set the home’s location in Composer for Shabbat times", later: "", footnote: "" },
      home: "24 Tishrei 5787 · Parashat Bereshit",
      hebrew: { title: "", times: "להגדרת זמני שבת יש להגדיר את מיקום הבית ב-Composer", later: "", footnote: "" },
      homeHebrew: "כ״ד בתשרי תשפ״ז · פרשת בראשית",
    },
    approximate: {
      times: { title: "Shabbat", times: "No sunset at this latitude: no times", later: "", footnote: "20 min before sunset · 42 min after · as outside Israel" },
      home: "10 Tamuz 5786 · Parashat Chukat-Balak",
      hebrew: { title: "שבת", times: "אין שקיעה בקו רוחב זה: אין זמנים", later: "", footnote: "20 דק׳ לפני השקיעה · 42 דק׳ אחריה · כמו בחו״ל" },
      homeHebrew: "י׳ בתמוז תשפ״ו · פרשת חוקת־בלק",
    },
  };
  const each = (check) => {
    for (const [name, expected] of Object.entries(cases)) {
      const example = EXAMPLES.Calendar[name];
      system({ jewish_calendar: true }, example.timezone);
      check(name, example, expected);
    }
  };
  // Each time is kept on one line ("Fri 18:04" with a no-break space); compared with plain spaces.
  const times = (example) => Object.fromEntries(Object.entries(holyTimes(example.value, new Date(example.now))).map(([key, value]) => [key, value.replace(/ /g, " ")]));
  each((name, example, expected) => {
    assert.deepEqual(times(example), expected.times, name);
    assert.equal(homeLine(example.value), expected.home, name);
  });
  await inHebrew(() =>
    each((name, example, expected) => {
      assert.deepEqual(times(example), expected.hebrew, name);
      assert.equal(homeLine(example.value), expected.homeHebrew, name);
    })
  );
  system({ jewish_calendar: true });
  assert.match(holyTimes(EXAMPLES.Calendar.ok.value, new Date(EXAMPLES.Calendar.ok.now)).times, /^Candle lighting Fri 18:04 · Havdalah Sat 19:05$/);
  assert.equal(holyTimes(EXAMPLES.Calendar.off.value), null);
  assert.equal(homeLine(EXAMPLES.Calendar.off.value), "");
  // On the holiday Shabbat itself its name leads, then the day's other holidays.
  const ok = structuredClone(EXAMPLES.Calendar.ok.value);
  ok.today = { date: "2026-10-03", hebrew: { year: 5787, month: "tishrei", day: 22, leap_year: true }, after_sunset: false, holidays: ok.week.holidays };
  assert.equal(homeLine(ok), "22 Tishrei 5787 · Shabbat Shmini Atzeret · Simchat Torah");
  // On a Shabbat that is the seventh day of Pesach (19 April 2025), in words that read as a name.
  const pesach = structuredClone(EXAMPLES.Calendar.ok.value);
  const seventh = { key: "pesach_7", day: null, month: null, yom_tov: true, name: "Pesach VII" };
  pesach.today = { date: "2025-04-19", hebrew: { year: 5785, month: "nisan", day: 21, leap_year: false }, after_sunset: false, holidays: [seventh], changes_at: "2025-04-19T16:15:00Z" };
  pesach.week = { date: "2025-04-19", parasha: null, holidays: [seventh] };
  assert.equal(homeLine(pesach), "21 Nisan 5785 · Shabbat, Seventh day of Pesach");
  await inHebrew(() => assert.equal(homeLine(pesach), "כ״א בניסן תשפ״ה · שבת שביעי של פסח"));
});

test("Home, Schedules and Settings show the calendar only when it is on", () => {
  for (const [label, features, on] of FEATURES) {
    connectedAdmin();
    Object.assign(state, { rooms: [], lights: [], thermostats: [], blinds: [], cameras: [], relays: [], doorbells: [], devices: [] });
    system(features);
    state.calendar = EXAMPLES.Calendar.ok.value;
    const home = byClass(homeView({}), "calendar-line");
    assert.equal(Boolean(home), on, `${label}: Home`);
    if (on) assert.equal(home.textContent, "18 Tishrei 5787 · Chol HaMoed Sukkot · Shabbat Shmini Atzeret");
    const card = byClass(schedulesView(), "calendar-card");
    assert.equal(Boolean(card), on, `${label}: Schedules`);
    if (on) assert.ok(keysOf(card).includes("calendar-change"), "admins can change how the times are worked out");
    if (on) assert.equal(byKey(card, "calendar-change").attributes.href, "#/settings/calendar", "Change opens Settings → Shabbat and holidays");
    resetCalendarSettings();
    // Settings' list has a row for it, which opens Settings → Shabbat and holidays.
    assert.equal(keysOf(settingsView({})).includes("settings-row:calendar"), on, `${label}: the row on Settings' list`);
    assert.ok(!keysOf(settingsView({})).includes("settings-calendar"), "the card is on its own page");
    const settings = settingsView({ page: "calendar" });
    assert.equal(keysOf(settings).includes("settings-calendar"), on, `${label}: Settings`);
    if (on) {
      const keys = keysOf(settings);
      for (const key of ["calendar-holidays-auto", "calendar-holidays-israel", "calendar-holidays-abroad", "calendar-candles-down", "calendar-candles-up", "calendar-havdalah-down", "calendar-save"]) assert.ok(keys.includes(key), key);
      assert.deepEqual(keys.filter((key) => /^calendar-(candles|havdalah):/.test(key)), ["calendar-candles:18", "calendar-candles:20", "calendar-candles:30", "calendar-candles:40", "calendar-havdalah:42", "calendar-havdalah:50", "calendar-havdalah:72"]);
      assert.match(textOf(settings), /From the home’s location: as in Israel/);
      assert.match(textOf(settings), /Check the times against your community’s calendar\./);
    }
  }
  // Members see the times, but not Change or the settings.
  connectedAdmin();
  state.role = "member";
  system({ jewish_calendar: true });
  state.calendar = EXAMPLES.Calendar.ok.value;
  const card = byClass(schedulesView(), "calendar-card");
  assert.ok(card && !keysOf(card).includes("calendar-change"));
  assert.ok(!keysOf(settingsView({})).includes("settings-row:calendar"));
  const page = settingsView({ page: "calendar" });
  assert.ok(!keysOf(page).includes("settings-calendar"));
  assert.match(textOf(page), /Only an admin can change these settings/, "a link kept from an admin device says why");
  state.calendar = null;
});

// ---- reading the calendar ----------------------------------------------------------------------

// The controller: it does not seal (as before 1.0.0), and answers the calendar with `answer`.
function controller(answer = EXAMPLES.Calendar.ok.value) {
  const asked = [];
  globalThis.fetch = async (url) => {
    const path = new URL(url).pathname;
    asked.push(path);
    const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
    if (path === "/v1/sealed") return reply(404, { code: "NOT_FOUND" });
    if (path === "/v1/calendar") return reply(200, answer);
    return reply(404, { code: "NOT_FOUND" });
  };
  return asked;
}

test("GET /v1/calendar is asked only with the calendar on, then every 10 minutes", async () => {
  connectedAdmin();
  for (const [label, features] of FEATURES.slice(0, 2)) {
    system(features);
    const asked = controller();
    await loadCalendar();
    await keepCalendar();
    assert.deepEqual(asked, [], `${label}: never asked`);
    assert.equal(state.calendar, null, label);
  }
  system({ jewish_calendar: true });
  let asked = controller();
  await keepCalendar();
  assert.deepEqual(asked.filter((path) => path === "/v1/calendar"), ["/v1/calendar"], "read once it is on");
  assert.deepEqual(state.calendar, EXAMPLES.Calendar.ok.value);
  asked = controller();
  await keepCalendar();
  assert.deepEqual(asked, [], "not again within 10 minutes");
  atTime(new RealDate(RealDate.now() + 11 * 60 * 1000).toISOString());
  try {
    await keepCalendar();
    assert.deepEqual(asked, ["/v1/calendar"], "again after 10 minutes");
  } finally {
    realTime();
  }
  // Turned off in Composer (the next /v1/system): forgotten.
  system({ jewish_calendar: false });
  keepCalendar();
  assert.equal(state.calendar, null);
});

test("a JEWISH_CALENDAR_OFF answer turns the calendar off here, and says why", async () => {
  connectedAdmin();
  system({ jewish_calendar: true });
  controller();
  await loadCalendar();
  const off = new ApiError("The Jewish calendar is off: an installer turns it on with DirectorLink's Jewish Calendar property in Composer", { status: 409, code: "JEWISH_CALENDAR_OFF" });
  assert.equal(noteCalendarOff(new ApiError("Conflict", { status: 409, code: "VERSION_CONFLICT" })), false);
  assert.equal(calendar.calendarOn(), true);
  assert.equal(noteCalendarOff(off), true);
  assert.equal(calendar.calendarOn(), false);
  assert.equal(state.calendar, null);
  assert.equal(errorText(off), "The Jewish calendar is off in Composer (DirectorLink’s Jewish Calendar property).");
  await inHebrew(() => assert.equal(errorText(off), "הלוח העברי כבוי ב-Composer (המאפיין Jewish Calendar של DirectorLink)."));
});

test("the calendar is read again 5 seconds after its next change: a period's start or end, or the Hebrew date's", async () => {
  const ok = EXAMPLES.Calendar.ok;
  system({ jewish_calendar: true }, ok.timezone);
  const now = RealDate.parse(ok.now);
  // The Hebrew date changes first, at today.changes_at: the controller's sunset, to the second
  // (18:28:37 in Tel Aviv; the weather's sunset is rounded to the minute).
  assert.equal(nextChange(ok.value, now), RealDate.parse("2026-09-29T15:28:37Z"));
  assert.equal(nextChange(ok.value, RealDate.parse("2026-09-29T16:00:00Z")), RealDate.parse(ok.value.next.starts_at), "after sunset: candle lighting");
  // Inside a period too: the date changes at the second evening's sunset, before havdalah.
  const period = EXAMPLES.Calendar.three_day_period;
  assert.equal(nextChange(period.value, RealDate.parse(period.now)), RealDate.parse(period.value.today.changes_at));
  assert.ok(RealDate.parse(period.value.today.changes_at) < RealDate.parse(period.value.current.ends_at));
  assert.equal(nextChange(period.value, RealDate.parse("2024-10-05T12:00:00Z")), RealDate.parse(period.value.current.ends_at), "havdalah");
  assert.equal(nextChange(period.value, RealDate.parse("2030-01-01T00:00:00Z")), null);
  assert.equal(nextChange(EXAMPLES.Calendar.off.value, now), null);
  // After a read the next one is planned then; a moment more than a day away waits.
  connectedAdmin();
  const planned = [];
  const realSetTimeout = globalThis.setTimeout;
  globalThis.setTimeout = (callback, delay, ...rest) => {
    if (delay > 60000) {
      planned.push({ callback, delay });
      return 0;
    }
    return realSetTimeout(callback, delay, ...rest);
  };
  atTime(ok.now);
  try {
    controller(ok.value);
    await loadCalendar();
    assert.deepEqual(planned.map(({ delay }) => delay), [((4 * 60 + 28) * 60 + 37) * 1000 + 5000]);
    const asked = controller(ok.value);
    planned[0].callback();
    await loadCalendar();
    assert.ok(asked.includes("/v1/calendar"), "read when it is due");
    planned.length = 0;
    const later = structuredClone(ok.value);
    later.today.changes_at = "2026-10-01T12:00:00Z";
    controller(later);
    await loadCalendar();
    assert.deepEqual(planned, [], "the next change is two days away");
  } finally {
    globalThis.setTimeout = realSetTimeout;
    realTime();
    noteCalendarOff({ code: "JEWISH_CALENDAR_OFF" });
  }
});
