// The weather on Home (1.12.1, ADR-084; app/js/weather.js, app/js/views/home.js): one line under the
// command field, "Now 27° · Today 23°–30° · rain 14% · sunset 18:13", from GET /v1/weather. Whole
// degrees in the project's scale; "Today" until 15:00 at home, then "Tomorrow"; the chance of rain
// of that day from 10%; the next sun event only; the sky's icon from the WMO code. Hidden without
// weather and for a key that can't read it. Read when Home opens and every 10 minutes while it
// stays open, at home and through the account alike (the requests are the app's usual ones).
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
  // Home's command field is kept over redraws and brought up to date in place (views/command.js).
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

const { state } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { forgetKey } = await import("../../app/js/session.js");
const { enterHomeWeather, homeWeather, homeWeatherText, keepHomeWeather, loadWeather, skyOf } = await import("../../app/js/weather.js");
const { homeView } = await import("../../app/js/views/home.js");

// The clock, fixed at a moment (Date and Date.now), and back.
const RealDate = Date;
function atTime(moment) {
  const fixed = typeof moment === "number" ? moment : RealDate.parse(moment);
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
after(realTime);

// A Sunday in Tel Aviv (UTC+3 until 25 October 2026): "08:00" is 05:00 UTC.
const local = (time, day = "2026-10-11") => `${day}T${time}:00+03:00`;
const at = (time, day) => new RealDate(local(time, day));

// GET /v1/weather as a 1.12.1 controller answers it, read at `read` (local time that day).
function weather({ read = "08:00", temperature = 26.6, code = 1, raining = false, today = {}, tomorrow = {}, ...rest } = {}) {
  return {
    status: "ok",
    detail: null,
    location: null,
    fetched_at: "2026-10-11T03:00:00Z",
    source: "forecast",
    forecast_for: new RealDate(local(read)).toISOString(),
    forecast_until: "2026-10-16T03:00:00Z",
    current: { temperature, wind_speed: 12, wind_gusts: null, precipitation: raining ? 0.4 : 0, raining, weather_code: code },
    today: { max_temperature: 30.4, min_temperature: 22.6, rain_chance: 14, sunrise: "06:31", sunset: "18:13", ...today },
    tomorrow: { max_temperature: 28.2, min_temperature: 21.4, rain_chance: 40, sunrise: "06:32", sunset: "18:12", ...tomorrow },
    attribution: "Weather data by Open-Meteo.com",
    ...rest,
  };
}

// Without the isolates around numbers.
const plain = (text) => text.replace(/[⁦-⁩]/g, "");
// The line's text at a local time that day (the weather read then, unless it says otherwise).
const line = (time, answer = weather({ read: time }), day) => plain(homeWeatherText(answer, at(time, day)));

// A member or an admin connected to a °C home in Tel Aviv (`scale` "F": a °F project).
function connected({ scale = "C", member = false } = {}) {
  Object.assign(state, { host: "192.0.2.10", apiKey: "ak_test", transport: "lan", status: "connected", loaded: true, role: member ? "member" : "admin" });
  state.access = member ? { role: "member", rooms: [], kinds: [], cameras: [], doors: false, alarm: false } : { role: "admin" };
  state.system = { location: { timezone: "Asia/Jerusalem" }, temperature_scale: scale, features: {} };
  Object.assign(state, { rooms: [], lights: [], thermostats: [], fans: [], blinds: [], cameras: [], relays: [], doorbells: [], refrigerators: [], devices: [], scenes: [] });
  location.hash = "";
}

async function inLanguage(language, check) {
  await setLanguage(language);
  try {
    await check();
  } finally {
    await setLanguage("en");
  }
}

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
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

// ---- what the line says ----------------------------------------------------------------------

test("in the morning: now, today's low and high, the chance of rain and the sunset, in whole degrees", () => {
  connected();
  assert.equal(line("08:00"), "Now 27° · Today 23°–30° · rain 14% · sunset 18:13");
  assert.equal(line("14:59"), "Now 27° · Today 23°–30° · rain 14% · sunset 18:13", "today until 15:00");
  // Before sunrise, the sunrise is next.
  assert.equal(line("05:30"), "Now 27° · Today 23°–30° · rain 14% · sunrise 06:31");
  assert.equal(line("06:31"), "Now 27° · Today 23°–30° · rain 14% · sunset 18:13", "from sunrise, the sunset");
  // Rounded to whole degrees, never "-0°".
  assert.equal(line("08:00", weather({ temperature: 23.5 })), "Now 24° · Today 23°–30° · rain 14% · sunset 18:13");
  assert.equal(line("08:00", weather({ temperature: -0.4, today: { min_temperature: -3.6, max_temperature: 4.4 } })), "Now 0° · Today -4°–4° · rain 14% · sunset 18:13");
});

test("from 15:00, tomorrow's low, high and chance of rain; after sunset, tomorrow's sunrise", () => {
  connected();
  assert.equal(line("15:00"), "Now 27° · Tomorrow 21°–28° · rain 40% · sunset 18:13");
  assert.equal(line("18:12"), "Now 27° · Tomorrow 21°–28° · rain 40% · sunset 18:13");
  assert.equal(line("18:13"), "Now 27° · Tomorrow 21°–28° · rain 40% · sunrise 06:32", "the sun has set: tomorrow's sunrise");
  assert.equal(line("23:59"), "Now 27° · Tomorrow 21°–28° · rain 40% · sunrise 06:32");
  // Just after midnight it is today again, with a new answer.
  assert.equal(line("00:10", weather({ read: "00:10" })), "Now 27° · Today 23°–30° · rain 14% · sunrise 06:31");
});

test("read before midnight and shown after it, tomorrow is today", () => {
  connected();
  const lateRead = weather({ read: "23:55" });
  assert.equal(line("00:05", lateRead, "2026-10-12"), "Now 27° · Today 21°–28° · rain 40% · sunrise 06:32");
  // Read days ago (a phone asleep since): nothing until it is read again.
  assert.equal(homeWeather(lateRead, at("09:00", "2026-10-13")), null);
});

test("the chance of rain from 10%, of the day shown", () => {
  connected();
  assert.equal(line("08:00", weather({ today: { rain_chance: 9 } })), "Now 27° · Today 23°–30° · sunset 18:13", "9%: not a word");
  assert.equal(line("08:00", weather({ today: { rain_chance: 10 } })), "Now 27° · Today 23°–30° · rain 10% · sunset 18:13", "10%: said");
  assert.equal(line("08:00", weather({ today: { rain_chance: 0 } })), "Now 27° · Today 23°–30° · sunset 18:13");
  assert.equal(line("08:00", weather({ today: { rain_chance: null } })), "Now 27° · Today 23°–30° · sunset 18:13");
  // After 15:00 tomorrow's chance, whatever today's.
  assert.equal(line("16:00", weather({ read: "16:00", today: { rain_chance: 80 }, tomorrow: { rain_chance: 5 } })), "Now 27° · Tomorrow 21°–28° · sunset 18:13");
  assert.equal(line("08:00", weather({ today: { rain_chance: 5 }, tomorrow: { rain_chance: 90 } })), "Now 27° · Today 23°–30° · sunset 18:13");
});

test("a °F project: whole °F, as the weather card shows them", () => {
  connected({ scale: "F" });
  // 26.6 °C is 79.9 °F, 22.6 °C 72.7 °F, 30.4 °C 86.7 °F.
  assert.equal(line("08:00"), "Now 80° · Today 73°–87° · rain 14% · sunset 18:13");
  assert.equal(line("16:00"), "Now 80° · Tomorrow 71°–83° · rain 40% · sunset 18:13");
  connected();
});

test("an older controller, without tomorrow: today's after 15:00, and no sunrise after sunset", () => {
  connected();
  const older = weather({ read: "16:00" });
  delete older.tomorrow;
  assert.equal(line("16:00", older), "Now 27° · Today 23°–30° · rain 14% · sunset 18:13");
  assert.equal(line("20:00", { ...older, forecast_for: at("20:00").toISOString() }), "Now 27° · Today 23°–30° · rain 14%");
  // Tomorrow's forecast not reached (its sun still there).
  const shortForecast = weather({ read: "16:00", tomorrow: { max_temperature: null, min_temperature: null, rain_chance: null } });
  assert.equal(line("16:00", shortForecast), "Now 27° · Today 23°–30° · rain 14% · sunset 18:13");
  assert.equal(line("19:00", { ...shortForecast, forecast_for: at("19:00").toISOString() }), "Now 27° · Today 23°–30° · rain 14% · sunrise 06:32");
  // Before 1.10.0 no forecast_for: read today.
  const measured = weather();
  delete measured.forecast_for;
  assert.equal(line("08:00", measured), "Now 27° · Today 23°–30° · rain 14% · sunset 18:13");
});

test("no weather, no line", () => {
  connected();
  for (const [label, answer] of [
    ["not read", null],
    ["no location", { ...weather(), status: "no_location", current: null, source: null, forecast_for: null }],
    ["no forecast", { ...weather(), status: "unreachable", current: null, source: null, forecast_for: null }],
    ["being read", { ...weather(), status: "waiting", current: null, source: null, forecast_for: null }],
    ["no temperature", weather({ temperature: null })],
  ]) {
    assert.equal(homeWeather(answer, at("08:00")), null, label);
    assert.equal(homeWeatherText(answer, at("08:00")), "", label);
  }
});

test("the sky's icon from the WMO code, by day and by night; rain now is rain", () => {
  const cases = [
    [0, "clear"],
    [1, "clear"],
    [2, "partly"],
    [3, "cloudy"],
    [45, "fog"],
    [48, "fog"],
    [51, "rain"],
    [57, "rain"],
    [61, "rain"],
    [67, "rain"],
    [80, "rain"],
    [82, "rain"],
    [71, "snow"],
    [77, "snow"],
    [85, "snow"],
    [86, "snow"],
    [95, "thunder"],
    [99, "thunder"],
    [null, null],
    [42, null],
  ];
  for (const [code, sky] of cases) assert.equal(skyOf(code), sky, `code ${code}`);
  assert.equal(skyOf(1, true), "rain", "the controller says it rains (ADR-071): rain");
  assert.equal(skyOf(3, true), "rain");
  assert.equal(skyOf(73, true), "snow");
  assert.equal(skyOf(95, true), "thunder");
  connected();
  const icons = (code, time, raining = false) => homeWeather(weather({ read: time, code, raining }), at(time)).icon;
  assert.equal(icons(0, "12:00"), "sun");
  assert.equal(icons(0, "22:00"), "moon");
  assert.equal(icons(0, "05:00"), "moon", "before sunrise");
  assert.equal(icons(2, "12:00"), "cloudSun");
  assert.equal(icons(2, "22:00"), "cloudMoon");
  assert.equal(icons(3, "22:00"), "cloud");
  assert.equal(icons(45, "12:00"), "fog");
  assert.equal(icons(61, "12:00"), "rain");
  assert.equal(icons(1, "12:00", true), "rain");
  assert.equal(icons(75, "12:00"), "snowflake");
  assert.equal(icons(96, "12:00"), "thunder");
  assert.equal(icons(null, "12:00"), "climate", "no code: a thermometer");
  // Every icon the line may show is drawn.
  const drawn = readFileSync(new URL("../../app/js/icons.js", import.meta.url), "utf8");
  for (const name of ["sun", "moon", "cloudSun", "cloudMoon", "cloud", "fog", "rain", "snowflake", "thunder", "climate"]) {
    assert.match(drawn, new RegExp(`\\n  ${name}:`), name);
  }
});

test("in Hebrew, Spanish and Italian; numbers and degrees isolated so Hebrew reads them right", async () => {
  connected();
  await inLanguage("he", () => {
    assert.equal(line("08:00"), "עכשיו 27° · היום 23°–30° · גשם 14% · שקיעה 18:13");
    assert.equal(line("16:00"), "עכשיו 27° · מחר 21°–28° · גשם 40% · שקיעה 18:13");
    assert.equal(line("20:00"), "עכשיו 27° · מחר 21°–28° · גשם 40% · זריחה 06:32");
    const raw = homeWeatherText(weather(), at("08:00"));
    for (const isolated of ["⁦27°⁩", "⁦23°–30°⁩", "⁦14%⁩"]) assert.ok(raw.includes(isolated), isolated);
    assert.equal(homeWeather(weather(), at("08:00")).sky, "clear");
  });
  await inLanguage("es", () => {
    assert.equal(line("08:00"), "Ahora 27° · Hoy 23°–30° · lluvia 14% · puesta de sol 18:13");
    assert.equal(line("20:00"), "Ahora 27° · Mañana 21°–28° · lluvia 40% · amanecer 06:32");
  });
  await inLanguage("it", () => {
    assert.equal(line("08:00"), "Ora 27° · Oggi 23°–30° · pioggia 14% · tramonto 18:13");
    assert.equal(line("20:00"), "Ora 27° · Domani 21°–28° · pioggia 40% · alba 06:32");
  });
});

// ---- on Home -----------------------------------------------------------------------------------

// The line on Home, its text with plain spaces.
const homeLine = () => byKey(homeView({}), "home-weather");
const spoken = (node) => plain(node.textContent).replace(/ /g, " ");

test("Home shows it right under the command field, for members as for admins", () => {
  atTime(local("08:00"));
  try {
    for (const member of [false, true]) {
      connected({ member });
      state.weather = weather();
      const screen = [homeView({})].flat(Infinity).filter(Boolean);
      const index = screen.findIndex((node) => node.dataset?.key === "home-weather");
      assert.ok(index > 0, member ? "member" : "admin");
      assert.equal(screen[index - 1].className, "command", "under the command field");
      assert.equal(spoken(screen[index]), "Clear, Now 27° · Today 23°–30° · rain 14% · sunset 18:13", "the sky read out first");
      // "Now" can go on the narrowest phones (styles.css), the data stays.
      assert.equal(byClass(screen[index], "weather-line-now").textContent, "Now ");
      assert.equal(homeWeatherText(), "Now ⁦27°⁩ · Today ⁦23°–30°⁩ · rain ⁦14%⁩ · sunset 18:13");
    }
    const css = readFileSync(new URL("../../app/styles.css", import.meta.url), "utf8");
    assert.match(css, /@media \(max-width: 359\.98px\) \{\s*\.weather-line-now \{\s*display: none;/);
    assert.match(css, /\.weather-line-part \{\s*white-space: nowrap;/, "each part stays on one line");
    // No weather: no line.
    state.weather = { ...weather(), status: "no_location", current: null };
    assert.equal(homeLine(), null);
    state.weather = null;
    assert.equal(homeLine(), null);
  } finally {
    realTime();
  }
});

// ---- when it is read ---------------------------------------------------------------------------

// The controller (not sealing, as before 1.0.0): the weather with `status` and `answer`.
function controller(status = 200, answer = weather()) {
  const asked = [];
  globalThis.fetch = async (url) => {
    const path = new URL(url).pathname;
    asked.push(path);
    const reply = (code, body) => new Response(JSON.stringify(body), { status: code, headers: { "Content-Type": "application/json" } });
    if (path === "/v1/sealed") return reply(404, { code: "NOT_FOUND" });
    if (path === "/v1/weather") return reply(status, status === 200 ? answer : { code: "FORBIDDEN", title: "Forbidden" });
    return reply(404, { code: "NOT_FOUND" });
  };
  return () => asked.filter((path) => path === "/v1/weather").length;
}

test("read when Home opens and every 10 minutes while it stays open, not elsewhere", async () => {
  const start = RealDate.parse(local("08:00"));
  atTime(start);
  try {
    connected({ member: true });
    state.weather = null;
    let asked = controller();
    await enterHomeWeather();
    assert.equal(asked(), 1, "opening Home reads it");
    assert.equal(spoken(homeLine()), "Clear, Now 27° · Today 23°–30° · rain 14% · sunset 18:13");
    asked = controller();
    await enterHomeWeather();
    await keepHomeWeather();
    assert.equal(asked(), 0, "not again within a minute, nor with the next rooms refresh");
    atTime(start + 9 * 60 * 1000);
    await keepHomeWeather();
    assert.equal(asked(), 0, "not within 10 minutes");
    atTime(start + 10 * 60 * 1000);
    location.hash = "#/scenes";
    await keepHomeWeather();
    assert.equal(asked(), 0, "not on another screen");
    location.hash = "#/";
    document.hidden = true;
    await keepHomeWeather();
    assert.equal(asked(), 0, "not in the background");
    document.hidden = false;
    await keepHomeWeather();
    assert.equal(asked(), 1, "on Home after 10 minutes");
    // Opening Home again after a minute reads it again.
    atTime(start + 11 * 60 * 1000 + 1);
    await enterHomeWeather();
    assert.equal(asked(), 2);
    // Still being read by the controller (a restart): asked again a minute later.
    controller(200, { ...weather(), status: "waiting", current: null });
    atTime(start + 13 * 60 * 1000);
    await enterHomeWeather();
    assert.equal(homeLine(), null, "nothing while it is being read");
    asked = controller();
    atTime(start + 14 * 60 * 1000 + 1);
    await keepHomeWeather();
    assert.equal(asked(), 1);
    assert.ok(homeLine());
  } finally {
    realTime();
  }
});

test("a key that can't read the weather sees no line and asks no more", async () => {
  const start = RealDate.parse(local("08:00", "2026-10-14"));
  atTime(start);
  try {
    // A viewer of a controller before 1.8.0: never asked.
    connected();
    state.access = null;
    state.role = "viewer";
    state.weather = null;
    let asked = controller();
    await enterHomeWeather();
    await keepHomeWeather();
    assert.equal(asked(), 0, "a viewer is never asked");
    assert.equal(homeLine(), null);
    // A controller that refuses it (403): hidden, and not asked again.
    connected({ member: true });
    state.weather = weather();
    asked = controller(403);
    atTime(start + 60 * 60 * 1000);
    await loadWeather();
    assert.equal(asked(), 1);
    assert.equal(state.weather, null);
    assert.equal(homeLine(), null);
    atTime(start + 2 * 60 * 60 * 1000);
    await enterHomeWeather();
    await keepHomeWeather();
    assert.equal(asked(), 1, "refused: not asked again");
    // Forgetting the key forgets the weather too, and the next key may ask.
    asked = controller(200, { ...weather(), forecast_for: new RealDate(start + 2 * 60 * 60 * 1000).toISOString() });
    forgetKey();
    assert.equal(state.weather, null);
    connected({ member: true });
    await enterHomeWeather();
    assert.equal(asked(), 1, "a new key asks");
    assert.ok(homeLine());
  } finally {
    realTime();
  }
});
