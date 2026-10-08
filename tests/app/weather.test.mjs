// The weather card on Scenes → Schedules (app/js/views/schedules.js): since 1.10.0 (ADR-071) the
// controller's weather is the hour for now of the forecast it read, and the card says so, "Forecast
// for 14:20, updated today 08:00", in every language; a 1.9.0 driver's measured weather says nothing
// more than before. Since 1.10.1 (ADR-074) a threshold itself counts, and every sentence, label and
// help that shows or chooses one says so ("When it’s 23° or hotter outside").
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

const { state } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { conditionText, whenText } = await import("../../app/js/schedules.js");
const { draftFor, resetScheduleEditor, scheduleEditorView, schedulesView } = await import("../../app/js/views/schedules.js");

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function byClass(nodes, name) {
  return allByClass(nodes, name)[0] || null;
}
function allByClass(nodes, name) {
  const found = [];
  walk(nodes, (node) => {
    if (typeof node.className === "string" && node.className.split(/\s+/).includes(name)) found.push(node);
  });
  return found;
}
function byKey(nodes, key) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node.dataset?.key === key) found = node;
  });
  return found;
}
// Without the isolates around numbers and names.
const plain = (text) => text.replace(/[⁦-⁩]/g, "");

// An admin connected to a controller whose home is in UTC, with no schedules yet.
function connected(weather) {
  Object.assign(state, { host: "192.0.2.10", apiKey: "ak_test", transport: "lan", status: "connected", loaded: true, role: "admin" });
  state.system = { location: { timezone: "UTC" }, features: {} };
  state.scenes = [];
  state.schedules = [];
  state.schedulesPaused = false;
  state.schedulesUnsupported = false;
  state.weather = weather;
}

// Today in UTC, the home's time zone here.
const today = new Date().toISOString().slice(0, 10);
const FORECAST = {
  status: "ok",
  detail: null,
  location: null,
  fetched_at: `${today}T08:00:00Z`,
  source: "forecast",
  forecast_for: `${today}T14:20:30Z`,
  forecast_until: "2099-01-01T08:00:00Z",
  current: { temperature: 23, wind_speed: 12, wind_gusts: null, precipitation: 0, raining: false, weather_code: 1 },
  today: { max_temperature: 26, min_temperature: 18, rain_chance: 10, sunrise: "06:35", sunset: "18:10" },
  attribution: "Weather data by Open-Meteo.com",
};

test("the weather card says it is the forecast, for when and from when, in every language", async () => {
  connected(FORECAST);
  const card = byClass(schedulesView(), "weather-card");
  assert.ok(card);
  assert.equal(byClass(card, "weather-source").textContent, "Forecast for 14:20, updated today 08:00");
  assert.match(card.textContent, /23°/);
  const words = {
    he: "תחזית ל-14:20, עודכנה היום ב-08:00",
    es: "Previsión para las 14:20, actualizada hoy a las 08:00",
  };
  for (const [language, expected] of Object.entries(words)) {
    await setLanguage(language);
    try {
      assert.equal(byClass(schedulesView(), "weather-source").textContent, expected, language);
    } finally {
      await setLanguage("en");
    }
  }
  await setLanguage("it");
  try {
    assert.match(byClass(schedulesView(), "weather-source").textContent, /^Previsione per le 14:20, aggiornata .*08:00$/);
  } finally {
    await setLanguage("en");
  }
  // Read days ago, without the internet since: it says when.
  connected({ ...FORECAST, fetched_at: "2020-01-03T08:00:00Z", detail: "Couldn't resolve host" });
  assert.match(byClass(schedulesView(), "weather-source").textContent, /^Forecast for 14:20, updated .*3.*08:00$/);
});

test("a 1.9.0 driver's weather, and no weather, say nothing of a forecast", () => {
  const measured = { ...FORECAST };
  delete measured.source;
  delete measured.forecast_for;
  delete measured.forecast_until;
  connected(measured);
  const card = byClass(schedulesView(), "weather-card");
  assert.equal(byClass(card, "weather-source"), null);
  assert.match(card.textContent, /23°/);
  connected({ ...FORECAST, status: "unreachable", source: null, forecast_for: null, current: null });
  const none = byClass(schedulesView(), "weather-card");
  assert.equal(byClass(none, "weather-source"), null);
  assert.match(none.textContent, /Can’t reach the weather service/);
});

// ---- thresholds (1.10.1, ADR-074) ---------------------------------------------------------------

// What each language says for a heat rule at 23°, a wind rule at 40 km/h, "only if" 23° and 20 km/h,
// the labels under the editor's numbers (heat, wind; only if: heat, wind), the help on running
// again, and what the threshold's stepper and its − button are called for screen readers.
const THRESHOLDS = {
  en: {
    heat: "When it’s 23° or hotter outside",
    wind: "When the wind is 40 km/h or more",
    onlyIf: "Only if it’s 23° or warmer and the wind is 20 km/h or less",
    labels: ["or hotter", "or more", "or warmer", "or less"],
    again: ["Runs again only after it has cooled to 21° or less.", "Runs again only after the wind has dropped to 30 km/h or less."],
    name: "temperature",
    lower: "Lower temperature",
  },
  he: {
    heat: "כשהטמפרטורה בחוץ 23° ומעלה",
    wind: "כשמהירות הרוח 40 קמ״ש ומעלה",
    onlyIf: "רק אם הטמפרטורה בחוץ 23° ומעלה וגם מהירות הרוח 20 קמ״ש ומטה",
    labels: ["ומעלה", "ומעלה", "ומעלה", "ומטה"],
    again: ["יופעל שוב רק אחרי שהטמפרטורה תרד ל-21° ומטה.", "יופעל שוב רק אחרי שהרוח תחלש ל-30 קמ״ש ומטה."],
    name: "הטמפרטורה",
    lower: "הורדת הטמפרטורה",
  },
  es: {
    heat: "Cuando la temperatura exterior sea de 23° o más",
    wind: "Cuando el viento sea de 40 km/h o más",
    onlyIf: "Solo si hace 23° o más y el viento es de 20 km/h o menos",
    labels: ["o más", "o más", "o más", "o menos"],
    again: ["Vuelve a ejecutarse solo cuando la temperatura haya bajado a 21° o menos.", "Vuelve a ejecutarse solo cuando el viento haya bajado a 30 km/h o menos."],
    name: "la temperatura",
    lower: "Bajar la temperatura",
  },
  it: {
    heat: "Quando la temperatura esterna è di 23° o più",
    wind: "Quando il vento è di 40 km/h o più",
    onlyIf: "Solo se la temperatura esterna è di 23° o più e il vento è di 20 km/h o meno",
    labels: ["o più", "o più", "o più", "o meno"],
    again: ["Viene eseguita di nuovo solo dopo che la temperatura è scesa a 21° o meno.", "Viene eseguita di nuovo solo dopo che il vento è sceso a 30 km/h o meno."],
    name: "temperatura",
    lower: "Diminuisci: temperatura",
  },
};

async function inEach(check) {
  for (const [language, words] of Object.entries(THRESHOLDS)) {
    await setLanguage(language);
    try {
      check(words, language);
    } finally {
      await setLanguage("en");
    }
  }
}

const EVERY_DAY = [0, 1, 2, 3, 4, 5, 6];

test("a schedule's sentence (the list, History) says that the threshold itself counts, in every language", async () => {
  connected(FORECAST);
  await inEach((words, language) => {
    const weather = (kind, above) => ({ trigger: { type: "weather", kind, above, once_a_day: true }, days: EVERY_DAY, only_if: {} });
    assert.equal(plain(whenText(weather("heat", 23))), words.heat, language);
    assert.equal(plain(whenText(weather("wind", 40))), words.wind, language);
    const time = { trigger: { type: "time", at: "07:00" }, days: EVERY_DAY, only_if: { hotter_than: 23, wind_below: 20 } };
    assert.equal(plain(conditionText(time)), words.onlyIf, language);
  });
});

test("the editor says it under the threshold, in its help and its sentence, in every language", async () => {
  connected(FORECAST);
  state.scenes = [{ id: "a1b2c3d4", name: "Cool the house", steps: [] }];
  await inEach((words, language) => {
    resetScheduleEditor();
    const draft = draftFor("new");
    Object.assign(draft, { type: "weather", kind: "heat", heat: 23 });
    let view = scheduleEditorView("new");
    let stepper = byClass(view, "stepper");
    assert.equal(plain(byClass(stepper, "stepper-number").textContent), "23°", language);
    assert.equal(byClass(stepper, "stepper-label").textContent, words.labels[0], language);
    assert.equal(stepper.attributes["aria-label"], words.name, language);
    assert.equal(byKey(view, "schedule-above-down").attributes["aria-label"], words.lower, language);
    assert.equal(plain(byClass(view, "field-help").textContent), words.again[0], language);
    assert.ok(plain(byClass(view, "add-summary").textContent).startsWith(`${words.heat} · `), language);

    Object.assign(draft, { kind: "wind", wind: 40 });
    view = scheduleEditorView("new");
    stepper = byClass(view, "stepper");
    assert.equal(byClass(stepper, "stepper-label").textContent, words.labels[1], language);
    assert.equal(plain(byClass(view, "field-help").textContent), words.again[1], language);
    assert.ok(plain(byClass(view, "add-summary").textContent).startsWith(`${words.wind} · `), language);

    Object.assign(draft, { type: "time", hot: true, hotterThan: 23, calm: true, windBelow: 20 });
    view = scheduleEditorView("new");
    const steppers = allByClass(view, "stepper");
    assert.deepEqual(steppers.map((each) => byClass(each, "stepper-label").textContent), words.labels.slice(2), language);
    assert.deepEqual(steppers.map((each) => plain(byClass(each, "stepper-number").textContent)), ["23°", language === "he" ? "20 קמ״ש" : "20 km/h"], language);
    assert.equal(byKey(view, "schedule-hot-down").attributes["aria-label"], words.lower, language);
    assert.ok(plain(byClass(view, "add-summary").textContent).endsWith(` · ${words.onlyIf}`), language);
  });
  resetScheduleEditor();
});
