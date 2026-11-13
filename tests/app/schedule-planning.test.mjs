// Planning schedules in the app (1.14.0, ADR-090): a schedule's next run skipped from the list, dawn
// and dusk, earliest and latest times, run late, the home's holidays (Schedules → Holidays, and
// "On your holidays" in the editor), and Schedules → Next 7 days; all only with a controller that
// says `features.schedule_planning`, and in every language.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

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
  set textContent(text) {
    this.children = [document.createTextNode(String(text))];
  }
  replaceChildren(...children) {
    this.children = children;
  }
}
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/#/schedules", hash: "#/schedules" };
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
const { conditionText, statusText, whenText } = await import("../../app/js/schedules.js");
const { draftFor, resetScheduleEditor, scheduleBody, scheduleEditorView, schedulesView } = await import("../../app/js/views/schedules.js");
const { scheduleWeekView } = await import("../../app/js/views/schedule-week.js");
const { holidayDates, holidaysView, resetHolidays } = await import("../../app/js/views/holidays.js");

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function allByClass(nodes, name) {
  const found = [];
  walk(nodes, (node) => {
    if (typeof node.className === "string" && node.className.split(/\s+/).includes(name)) found.push(node);
  });
  return found;
}
function byClass(nodes, name) {
  return allByClass(nodes, name)[0] || null;
}
function byKey(nodes, key) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node.dataset?.key === key) found = node;
  });
  return found;
}
function text(nodes) {
  return [nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" ");
}
// Without the isolates around numbers and names.
const plain = (value) => value.replace(/[⁦-⁩]/g, "");

const today = new Date().toISOString().slice(0, 10);
const SCENE = { id: "aaaaaaaa", name: "Evening", steps: [] };
const WEATHER = {
  status: "ok",
  current: { temperature: 23, wind_speed: 12, raining: false },
  today: { sunrise: "06:24", sunset: "16:52", dawn: "05:58", dusk: "17:17" },
  tomorrow: { sunrise: "06:25", sunset: "16:51", dawn: "05:59", dusk: "17:16" },
};

function schedule(changes = {}) {
  return {
    id: "1234abcd",
    enabled: true,
    scene_id: SCENE.id,
    trigger: { type: "time", at: "06:45" },
    days: [0, 1, 2, 3, 4, 5, 6],
    only_if: {},
    if_no_weather: "run",
    during_shabbat: "run",
    on_holidays: "run",
    run_late: false,
    calendar_status: null,
    next_run: `${today}T23:45:00Z`,
    skip: null,
    last_run: null,
    version: 1,
    ...changes,
  };
}

// An admin connected to a controller in UTC; `planning`: a 1.14.0 controller.
function connected({ planning = true, schedules = [schedule()] } = {}) {
  Object.assign(state, { host: "192.0.2.10", apiKey: "ak_test", transport: "lan", status: "connected", loaded: true, role: "admin" });
  state.system = { location: { timezone: "UTC" }, features: planning ? { schedule_planning: true } : {} };
  state.scenes = [SCENE];
  state.schedules = schedules;
  state.schedulesPaused = false;
  state.schedulesUnsupported = false;
  state.weather = WEATHER;
  state.calendar = null;
  state.holidays = null;
  state.scheduleWeek = null;
  ui.schedulesMessage = null;
  resetScheduleEditor();
}

async function inEvery(fn) {
  for (const language of ["en", "he", "es", "it"]) {
    await setLanguage(language);
    try {
      await fn(language);
    } finally {
      await setLanguage("en");
    }
  }
}

// ---- sentences --------------------------------------------------------------------------------

test("dawn, dusk and the earliest and latest times are said in every language", async () => {
  connected();
  const sun = (trigger) => whenText(schedule({ trigger: { type: "sun", offset: 0, ...trigger } }));
  assert.equal(sun({ event: "dawn" }), "Every day at dawn");
  assert.equal(sun({ event: "dusk", offset: 30 }), "Every day, 30 min after dusk");
  assert.equal(sun({ event: "sunset", earliest: "17:30" }), "Every day at sunset, not before 17:30");
  assert.equal(sun({ event: "sunrise", offset: -30, latest: "07:00" }), "Every day, 30 min before sunrise, not after 07:00");
  assert.equal(sun({ event: "dusk", earliest: "18:00", latest: "22:00" }), "Every day at dusk, between 18:00 and 22:00");
  const expected = {
    he: ["כל יום בדמדומי ערב", "כל יום בשקיעה, לא לפני 17:30"],
    es: ["Todos los días al anochecer", "Todos los días a la puesta de sol, no antes de las 17:30"],
    it: ["Ogni giorno all’imbrunire", "Ogni giorno al tramonto, non prima delle 17:30"],
  };
  await inEvery((language) => {
    if (language === "en") return;
    assert.equal(sun({ event: "dusk" }), expected[language][0], language);
    assert.equal(sun({ event: "sunset", earliest: "17:30" }), expected[language][1], language);
  });
});

test("the home's holidays and run late are said with the schedule's conditions", async () => {
  connected();
  assert.equal(conditionText(schedule({ on_holidays: "skip" })), "Not on your holidays");
  assert.equal(conditionText(schedule({ on_holidays: "only", run_late: true })), "Only on your holidays · Runs late if it was missed");
  assert.equal(conditionText(schedule({ only_if: { not_raining: true }, on_holidays: "skip" })), "Only if it isn’t raining · Not on your holidays");
  assert.equal(conditionText(schedule()), "", "nothing for the defaults");
  await inEvery((language) => {
    assert.ok(!conditionText(schedule({ on_holidays: "skip", run_late: true })).includes("schedules."), language);
  });
});

test("a skipped run is said, and so is the run it skipped", async () => {
  connected();
  const skipping = statusText(schedule({ skip: { at: `${today}T23:45:00Z` }, next_run: "2099-01-01T06:45:00Z" }));
  assert.match(skipping, /^Skipping today 23:45 · Next: /);
  assert.equal(statusText(schedule({ trigger: { type: "weather", kind: "heat", above: 30 }, next_run: null, skip: { at: null } })), "Skipping its next run");
  const now = new Date();
  const skipped = statusText(schedule({ last_run: { at: now.toISOString(), skipped_by: "skip" }, next_run: null }), now);
  assert.match(skipped, /^Didn’t run today \d\d:\d\d: skipped$/);
  const holiday = statusText(schedule({ last_run: { at: now.toISOString(), skipped_by: "holiday" }, next_run: null }), now);
  assert.match(holiday, /: a holiday$/);
  const unknown = statusText(schedule({ last_run: { at: now.toISOString(), skipped_by: "something_new" }, next_run: null }), now);
  assert.match(unknown, /^Didn’t run today \d\d:\d\d$/, "a reason from a newer driver");
});

// ---- the list ----------------------------------------------------------------------------------

test("the list offers to skip the next run, the next 7 days and the holidays, with a 1.14.0 controller only", () => {
  connected();
  let view = schedulesView();
  assert.equal(byKey(view, "schedule-skip:1234abcd").textContent, "Skip next run");
  assert.ok(byKey(view, "schedules-week"));
  assert.ok(byKey(view, "schedules-holidays"));
  connected({ schedules: [schedule({ skip: { at: `${today}T23:45:00Z` } })] });
  assert.equal(byKey(schedulesView(), "schedule-skip:1234abcd").textContent, "Don’t skip");
  connected({ schedules: [schedule({ enabled: false })] });
  assert.equal(byKey(schedulesView(), "schedule-skip:1234abcd"), null, "nothing to skip when off");
  connected({ schedules: [schedule({ next_run: null })] });
  assert.equal(byKey(schedulesView(), "schedule-skip:1234abcd"), null, "nor without a next run");
  connected({ planning: false });
  view = schedulesView();
  assert.equal(byKey(view, "schedule-skip:1234abcd"), null);
  assert.equal(byKey(view, "schedules-week"), null);
  assert.equal(byKey(view, "schedules-holidays"), null);
});

// ---- the editor --------------------------------------------------------------------------------

test("the editor offers dawn and dusk, limits, run late and the holidays, and sends them", () => {
  connected({ schedules: [schedule({ trigger: { type: "sun", event: "dusk", offset: 0, earliest: "18:00" }, on_holidays: "skip", run_late: true })] });
  state.holidays = { items: [{ name: "Trip", from: "2027-02-01", to: "2027-02-07", yearly: false }], version: 1 };
  const view = scheduleEditorView("1234abcd");
  for (const event of ["dawn", "sunrise", "sunset", "dusk"]) assert.ok(byKey(view, `schedule-event:${event}`), event);
  assert.equal(byKey(view, "schedule-event:dawn").textContent, "Dawn (05:58)");
  assert.equal(byKey(view, "schedule-earliest").attributes?.["aria-checked"] ?? byKey(view, "schedule-earliest")["aria-checked"], "true");
  assert.ok(byKey(view, "schedule-earliest-time"));
  assert.ok(byKey(view, "schedule-run-late"));
  assert.ok(byKey(view, "schedule-holidays:only"));
  assert.match(text(view), /You have 1 holiday\./);
  const draft = draftFor("1234abcd");
  assert.deepEqual(scheduleBody(draft).trigger, { type: "sun", event: "dusk", offset: 0, earliest: "18:00" });
  assert.equal(scheduleBody(draft).on_holidays, "skip");
  assert.equal(scheduleBody(draft).run_late, true);
  draft.hasLatest = true;
  draft.latest = "21:00";
  assert.equal(scheduleBody(draft).trigger.latest, "21:00");
  draft.type = "weather";
  assert.equal(scheduleBody(draft).run_late, false, "a weather rule never runs late");
  assert.equal(scheduleBody(draft).trigger.earliest, undefined);
});

// The owner's request (1.16.0): "On your holidays" means nothing while the home has no holidays, so
// it is not shown then (nor before they are read), unless the schedule was saved with Not on or Only
// on holidays, which can then be changed back. Shown when they could not be read, as before.
test("the editor shows On your holidays only once the home has holidays, or when the schedule uses it", async () => {
  const holidaysShown = (view) => Boolean(byKey(view, "schedule-holidays:skip")) && text(view).includes("On your holidays");
  for (const [holidays, error, why] of [
    [{ items: [], version: 0 }, null, "no holidays"],
    [null, null, "not read yet"],
  ]) {
    for (const key of ["1234abcd", "new"]) {
      connected();
      state.holidays = holidays;
      state.holidaysError = error;
      const view = scheduleEditorView(key);
      assert.equal(holidaysShown(view), false, `${why}, ${key}`);
      assert.doesNotMatch(text(view), /holiday/i, `${why}, ${key}: no word of it`);
      assert.equal(scheduleBody(draftFor(key)).on_holidays, "run", `${why}, ${key}: Run as usual is still sent`);
    }
  }
  // The home has one: shown, as before.
  connected();
  state.holidays = { items: [{ name: "Trip", from: "2027-02-01", to: "2027-02-07", yearly: false }], version: 1 };
  assert.equal(holidaysShown(scheduleEditorView("1234abcd")), true);
  assert.equal(holidaysShown(scheduleEditorView("new")), true);
  // They could not be read: shown, saying what they are.
  connected();
  state.holidaysError = "The controller didn’t answer.";
  let view = scheduleEditorView("new");
  assert.equal(holidaysShown(view), true);
  assert.match(text(view), /Your holidays are days you choose, such as school breaks or a trip\./);
  state.holidaysError = null;

  // Saved as Not on holidays while the home has none (they were deleted since): still shown, and
  // still shown once changed back to Run as usual in this editor.
  for (const choice of ["skip", "only"]) {
    connected({ schedules: [schedule({ on_holidays: choice })] });
    state.holidays = { items: [], version: 2 };
    view = scheduleEditorView("1234abcd");
    assert.equal(holidaysShown(view), true, choice);
    assert.equal(byKey(view, `schedule-holidays:${choice}`).attributes["aria-pressed"], "true");
    assert.match(text(view), /You haven’t added any holidays yet\./);
    const draft = draftFor("1234abcd");
    draft.holidays = "run";
    assert.equal(holidaysShown(scheduleEditorView("1234abcd")), true, `${choice}: changed back, still there`);
    assert.equal(scheduleBody(draft).on_holidays, "run");
  }
  // In every language: nothing of it without holidays; its title once the schedule uses it.
  const titles = { en: "On your holidays", he: "בימי החופש שלכם", es: "En tus días libres", it: "Nei tuoi giorni liberi" };
  await inEvery(async (language) => {
    connected();
    state.holidays = { items: [], version: 0 };
    let shown = scheduleEditorView("1234abcd");
    assert.equal(byKey(shown, "schedule-holidays:skip"), null, language);
    assert.ok(!text(shown).includes(titles[language]), language);
    connected({ schedules: [schedule({ on_holidays: "only" })] });
    state.holidays = { items: [], version: 0 };
    shown = scheduleEditorView("1234abcd");
    assert.ok(byKey(shown, "schedule-holidays:only"), language);
    assert.ok(text(shown).includes(titles[language]), `${language}: ${titles[language]}`);
  });
});

test("an older controller gets none of the new fields, and only sunrise and sunset", () => {
  connected({ planning: false, schedules: [schedule({ trigger: { type: "sun", event: "sunset", offset: 0 } })] });
  const view = scheduleEditorView("1234abcd");
  assert.equal(byKey(view, "schedule-event:dawn"), null);
  assert.equal(byKey(view, "schedule-earliest"), null);
  assert.equal(byKey(view, "schedule-run-late"), null);
  assert.equal(byKey(view, "schedule-holidays:skip"), null);
  const body = scheduleBody(draftFor("1234abcd"));
  assert.equal("on_holidays" in body, false);
  assert.equal("run_late" in body, false);
});

// ---- Next 7 days -------------------------------------------------------------------------------

const WEEK = {
  paused: false,
  days: [
    {
      date: "2026-11-06",
      weekday: 5,
      sun: { dawn: "05:58", sunrise: "06:24", sunset: "16:52", dusk: "17:17" },
      holiday: null,
      holy: { starts_at: "2026-11-06T14:17:00Z", ends_at: null },
      runs: [
        { schedule_id: "1234abcd", scene_id: SCENE.id, at: "2026-11-06T06:45:00Z", status: "past", reason: null, conditions: false, from: null, to: null },
        { schedule_id: "1234abcd", scene_id: SCENE.id, at: "2026-11-06T20:00:00Z", status: "skipped", reason: "skip", conditions: false, from: null, to: null },
      ],
    },
    {
      date: "2026-11-07",
      weekday: 6,
      sun: { dawn: "05:59", sunrise: "06:25", sunset: null, dusk: null },
      holiday: { name: "Trip" },
      holy: { starts_at: null, ends_at: "2026-11-07T15:20:00Z" },
      runs: [
        { schedule_id: "1234abcd", scene_id: SCENE.id, at: "2026-11-07T06:45:00Z", status: "skipped", reason: "holiday", conditions: false, from: null, to: null },
        { schedule_id: "1234abcd", scene_id: SCENE.id, at: "2026-11-07T08:00:00Z", status: "planned", reason: null, conditions: true, from: null, to: null },
        { schedule_id: "1234abcd", scene_id: SCENE.id, at: null, status: "weather", reason: null, conditions: false, from: "08:00", to: "18:00" },
        { schedule_id: "1234abcd", scene_id: SCENE.id, at: "2026-11-07T09:00:00Z", status: "skipped", reason: "a_reason_from_a_newer_driver", conditions: false, from: null, to: null },
      ],
    },
    { date: "2026-11-08", weekday: 0, sun: {}, holiday: null, holy: null, runs: [] },
  ],
};

test("Next 7 days shows each day's sun, holiday, Shabbat and runs, and why not", async () => {
  connected();
  state.scheduleWeek = WEEK;
  const view = scheduleWeekView();
  const days = allByClass(view, "week-day");
  assert.equal(days.length, 3);
  assert.match(byClass(days[0], "week-day-title").textContent, /^Today · Friday,? 6 November$|^Today · Friday, November 6$/);
  assert.equal(byClass(days[0], "week-day-sun").textContent, "Dawn 05:58 · Sunrise 06:24 · Sunset 16:52 · Dusk 17:17");
  assert.equal(byClass(days[0], "week-day-holy").textContent, "Shabbat and holidays from 14:17");
  assert.equal(byClass(days[1], "week-day-sun").textContent, "Dawn 05:59 · Sunrise 06:25", "only what there is");
  assert.equal(plain(byClass(days[1], "week-day-holiday").textContent), "Holiday: Trip");
  assert.equal(byClass(days[1], "week-day-holy").textContent, "Shabbat and holidays until 15:20");
  const statuses = allByClass(days[0], "week-run-status").map((node) => node.textContent);
  assert.deepEqual(statuses, ["Earlier today", "Skipped"]);
  const tomorrow = allByClass(days[1], "week-run");
  assert.equal(byClass(tomorrow[0], "week-run-status").textContent, "Not on holidays");
  assert.equal(byClass(tomorrow[1], "week-run-status").textContent, "If the weather allows");
  assert.equal(byClass(tomorrow[2], "week-run-time").textContent, "08:00–18:00", "a weather rule's hours");
  assert.equal(byClass(tomorrow[3], "week-run-status").textContent, "Doesn’t run");
  assert.match(text(days[2]), /Nothing runs this day\./);
  assert.ok(byKey(view, "week-run:1234abcd:2026-11-06T06:45:00Z"), "an admin opens the schedule");
  await inEvery((language) => {
    assert.ok(!text(scheduleWeekView()).includes("schedules."), `${language}: every word translated`);
  });
});

// The owner's Saturday: "Rooms AC Off" at 09:00, set not to run on Shabbat, was listed with its
// reason and read as a run. Runs kept away from Shabbat and holidays are left out; the day's
// Shabbat line says when holy time ends.
test("Next 7 days leaves out runs kept away from Shabbat and holidays", () => {
  connected();
  const run = { schedule_id: "1234abcd", scene_id: SCENE.id, conditions: false, from: null, to: null };
  state.scheduleWeek = {
    paused: false,
    days: [
      {
        date: "2026-11-07",
        weekday: 6,
        sun: {},
        holiday: null,
        holy: { starts_at: null, ends_at: "2026-11-07T15:28:00Z" },
        runs: [
          { ...run, at: "2026-11-07T07:00:00Z", status: "skipped", reason: "shabbat" },
          { ...run, at: "2026-11-07T09:00:00Z", status: "past", reason: null },
          { ...run, at: null, status: "skipped", reason: "shabbat", from: "08:30", to: "23:00" },
        ],
      },
      {
        date: "2026-11-08",
        weekday: 0,
        sun: {},
        holiday: null,
        holy: { starts_at: null, ends_at: null },
        runs: [{ ...run, at: "2026-11-08T07:00:00Z", status: "skipped", reason: "shabbat" }],
      },
    ],
  };
  const days = allByClass(scheduleWeekView(), "week-day");
  const saturday = allByClass(days[0], "week-run");
  assert.equal(saturday.length, 1, "only the run that ran");
  assert.equal(byClass(saturday[0], "week-run-status").textContent, "Earlier today");
  assert.equal(byClass(days[0], "week-day-holy").textContent, "Shabbat and holidays until 15:28");
  assert.equal(allByClass(days[1], "week-run").length, 0);
  assert.match(text(days[1]), /Nothing runs this day\./, "a holiday whose only run keeps away from it");
});

test("Next 7 days asks an older controller to be updated, and says when it is paused", () => {
  connected({ planning: false });
  assert.match(text(scheduleWeekView()), /DirectorLink 1\.14\.0 or newer/);
  connected();
  state.scheduleWeek = { ...WEEK, paused: true };
  assert.match(text(scheduleWeekView()), /Paused by the installer in Composer/);
});

// ---- Holidays ----------------------------------------------------------------------------------

test("Holidays lists the home's days and adds one", async () => {
  connected();
  resetHolidays();
  state.holidays = {
    version: 3,
    items: [
      { name: "Trip", from: "2027-02-01", to: "2027-02-07", yearly: false },
      { name: "Independence Day", from: "2026-04-22", to: "2026-04-22", yearly: true },
      { name: "Christmas", from: "2026-12-25", to: "2026-12-25", yearly: false },
    ],
  };
  const view = holidaysView();
  const rows = allByClass(view, "holiday-row");
  assert.equal(rows.length, 3);
  assert.equal(byClass(rows[0], "scene-name").textContent, "Trip");
  assert.equal(holidayDates(state.holidays.items[0]), "Feb 1, 2027 – Feb 7, 2027");
  assert.equal(holidayDates(state.holidays.items[1]), "Every year: Apr 22");
  assert.equal(holidayDates(state.holidays.items[2]), "Dec 25, 2026");
  assert.ok(byKey(view, "holiday-delete:0"));
  assert.ok(byKey(view, "holiday-name"));
  assert.ok(byKey(view, "holiday-from"));
  assert.ok(byKey(view, "holiday-to"));
  assert.ok(byKey(view, "holiday-yearly"));
  assert.notEqual(byKey(view, "holiday-add").disabled, true);
  await inEvery((language) => {
    assert.ok(!text(holidaysView()).includes("holidays."), `${language}: every word translated`);
  });
  await setLanguage("he");
  try {
    assert.equal(holidayDates(state.holidays.items[1]).startsWith("כל שנה: "), true);
  } finally {
    await setLanguage("en");
  }
  // Empty: says so, and still offers to add one.
  state.holidays = { version: 0, items: [] };
  const empty = holidaysView();
  assert.match(text(empty), /No holidays yet/);
  assert.ok(byKey(empty, "holiday-add"));
});
