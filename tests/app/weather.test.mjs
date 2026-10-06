// The weather card on Scenes → Schedules (app/js/views/schedules.js): since 1.10.0 (ADR-071) the
// controller's weather is the hour for now of the forecast it read, and the card says so, "Forecast
// for 14:20, updated today 08:00", in every language; a 1.9.0 driver's measured weather says nothing
// more than before.
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
const { schedulesView } = await import("../../app/js/views/schedules.js");

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function byClass(nodes, name) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && typeof node.className === "string" && node.className.split(/\s+/).includes(name)) found = node;
  });
  return found;
}

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
