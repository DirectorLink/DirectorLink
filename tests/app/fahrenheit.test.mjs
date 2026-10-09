// Temperatures in the home's own scale (1.10.2, ADR-076, GitHub issue #75): no setting; each
// thermostat in its own scale as Control4 reports it (whole °F, 1° steps, what is chosen is what is
// sent), the weather and weather schedules in the project's, values not reported as "—" (never 0°
// or -18°), and thermostats with nothing to set as sensors ("Bathroom · 73° · 30%").
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

// Just enough of a browser for these modules: the elements the views build (with their listeners,
// to press them), storage, history and frames.
class FakeNode {}
class FakeElement extends FakeNode {
  constructor(tag) {
    super();
    this.tagName = tag.toUpperCase();
    this.className = "";
    this.dataset = {};
    this.attributes = {};
    this.children = [];
    this.listeners = {};
    this.style = { setProperty() {} };
  }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }
  addEventListener(type, listener) {
    (this.listeners[type] ||= []).push(listener);
  }
  dispatch(type, init = {}) {
    const event = { type, currentTarget: this, target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...init };
    for (const listener of this.listeners[type] || []) listener(event);
    return event;
  }
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
const backs = [];
globalThis.Node = FakeNode;
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", pathname: "/", search: "", hash: "", replace: (hash) => backs.push(`replace ${hash}`) };
globalThis.document = {
  hidden: false,
  documentElement: {},
  body: { append() {} },
  addEventListener() {},
  removeEventListener() {},
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
globalThis.fetch = async () => {
  throw new TypeError("offline in this test");
};
globalThis.history = { state: { directorlinkInApp: true }, back: () => backs.push("back") };

const Temperature = await import("../../app/js/temperature.js");
const { apiChange, cooledTo, fromCelsius, inOwnScale, inScale, thresholdToCelsius, toCelsius } = Temperature;
const { state, ui } = await import("../../app/js/state.js");
const { setLanguage } = await import("../../app/js/i18n.js");
const { clampTarget, nudgedChange } = await import("../../app/js/controls.js");
const { setpointGap, withSetpoint } = await import("../../app/js/setpoints.js");
const { thermostatCard } = await import("../../app/js/components.js");
const { climateView } = await import("../../app/js/views/climate.js");
const { homeView } = await import("../../app/js/views/home.js");
const { commandCatalog, steppedTemperature, thermostatPlan } = await import("../../app/js/commands.js");
const { parseCommand } = await import("../../app/js/command-parser.js");
const { copyHouse, stepAction } = await import("../../app/js/scenes.js");
const { resetSceneEditor, sceneEditorView } = await import("../../app/js/views/scenes.js");
const { conditionText, whenText } = await import("../../app/js/schedules.js");
const { draftFor, resetScheduleEditor, scheduleBody, scheduleEditorView, schedulesView } = await import("../../app/js/views/schedules.js");

// ---- what a screen holds -----------------------------------------------------------------------

function walk(nodes, visit) {
  for (const node of [nodes].flat(Infinity)) {
    if (!node) continue;
    visit(node);
    walk(node.children || [], visit);
  }
}
function find(nodes, test) {
  let found = null;
  walk(nodes, (node) => {
    if (!found && node instanceof FakeElement && test(node)) found = node;
  });
  return found;
}
const byKey = (nodes, key) => find(nodes, (node) => node.dataset.key === key);
const byClass = (nodes, name) => find(nodes, (node) => typeof node.className === "string" && node.className.split(/\s+/).includes(name));
const allByClass = (nodes, name) => {
  const list = [];
  walk(nodes, (node) => node instanceof FakeElement && typeof node.className === "string" && node.className.split(/\s+/).includes(name) && list.push(node));
  return list;
};
const plain = (text) => text.replace(/[⁦-⁩⁨]/g, "");
const textOf = (nodes) => plain([nodes].flat(Infinity).filter(Boolean).map((node) => node.textContent).join(" | "));
const press = (nodes, key) => {
  const element = byKey(nodes, key);
  assert.ok(element, `${key} is on the screen`);
  element.dispatch("click");
};

// ---- a US home, as a 1.10.2 driver reports it (driver/tests/c4mock.lua Mock.fahrenheitProject) ---

const LIVING = { id: 11, name: "Living Room" };
const KITCHEN = { id: 10, name: "Kitchen" };
// GET /v1/thermostats/33: a minisplit at 74 °F, set to 69 °F.
const MINISPLIT = {
  id: 33, name: "Living Room Minisplit", room: LIVING, online: true,
  current_temperature: 23.3, target_temperature: 20.6, target_temperature_min: 16, target_temperature_max: 32,
  mode: "cool", modes: ["auto", "cool", "heat", "off"], activity: "cooling", fan_speed: "low", fan_speeds: ["low", "medium", "high"],
  setpoints: "single", heat_setpoint: null, cool_setpoint: null, setpoint_deadband: null, last_mode: "cool",
  scale: "F", sensor: false,
  current_temperature_f: 74, target_temperature_f: 69, target_temperature_min_f: 61, target_temperature_max_f: 89,
  heat_setpoint_f: null, cool_setpoint_f: null, setpoint_deadband_f: null,
};
// 34: a Nest, its heat and cool setpoints (68 °F, 71 °F), in Cool.
const NEST = {
  id: 34, name: "Hallway", room: KITCHEN, online: true,
  current_temperature: 22.2, target_temperature: 21.7, target_temperature_min: 5, target_temperature_max: 35,
  mode: "cool", modes: ["off", "heat", "cool", "auto"], activity: null, fan_speed: null, fan_speeds: [],
  setpoints: "dual", heat_setpoint: 20, cool_setpoint: 21.7, setpoint_deadband: 1.7, last_mode: "cool",
  scale: "F", sensor: false,
  current_temperature_f: 72, target_temperature_f: 71, target_temperature_min_f: 41, target_temperature_max_f: 95,
  heat_setpoint_f: 68, cool_setpoint_f: 71, setpoint_deadband_f: 3,
};
// 36: a temperature and humidity reading with nothing to set.
const SENSOR = {
  id: 36, name: "Bathroom", room: LIVING, online: true,
  current_temperature: 22.8, target_temperature: null, target_temperature_min: 16, target_temperature_max: 32,
  mode: null, modes: [], activity: null, fan_speed: null, fan_speeds: [],
  setpoints: "single", heat_setpoint: null, cool_setpoint: null, setpoint_deadband: null, last_mode: null,
  scale: "F", sensor: true, humidity: 30,
  current_temperature_f: 73, target_temperature_f: null, target_temperature_min_f: 61, target_temperature_max_f: 89,
  heat_setpoint_f: null, cool_setpoint_f: null, setpoint_deadband_f: null,
};
// A °C floor zone that reports no room temperature (the owner's, 1.10.2: null, not 0).
const FLOOR = {
  id: 35, name: "Kitchen floor", room: KITCHEN, online: true,
  current_temperature: null, target_temperature: 25, target_temperature_min: 16, target_temperature_max: 32,
  mode: "off", modes: ["off", "heat"], activity: "idle", fan_speed: null, fan_speeds: [],
  setpoints: "single", heat_setpoint: null, cool_setpoint: null, setpoint_deadband: null, last_mode: "heat",
  scale: "C", sensor: false,
};

function connected(thermostats, scale = "F") {
  Object.assign(state, {
    host: "192.0.2.10",
    apiKey: "ak_test",
    transport: "lan",
    status: "connected",
    loaded: true,
    online: true,
    role: "admin",
    access: null,
    rooms: [KITCHEN, LIVING],
    system: { temperature_scale: scale, location: { timezone: "UTC" }, features: { climate_last_mode: true } },
    lights: [],
    thermostats: thermostats.map((item) => inOwnScale(structuredClone(item))),
    fans: [],
    blinds: [],
    cameras: [],
    relays: [],
    doorbells: [],
    refrigerators: [],
    devices: [],
    scenes: [],
    schedules: [],
    schedulesPaused: false,
    schedulesUnsupported: false,
    profile: { id: "p1", version: 1, prefs: { favorites: ["thermostat:33", "thermostat:36", "thermostat:35"] } },
  });
}

// ---- the rules (temperature.js) ----------------------------------------------------------------

test("a °F thermostat is kept in its own scale: its °F values, as Control4 shows them", () => {
  const own = inOwnScale(structuredClone(MINISPLIT));
  assert.equal(own.target_temperature, 69, "not 21°");
  assert.equal(own.current_temperature, 74, "not 23°");
  assert.deepEqual([own.target_temperature_min, own.target_temperature_max], [61, 89]);
  assert.equal(own.scale, "F");
  assert.ok(!Object.keys(own).some((key) => key.endsWith("_f")), "no twins left");
  assert.deepEqual(inOwnScale(own), own, "once only");
  const nest = inOwnScale(structuredClone(NEST));
  assert.deepEqual([nest.heat_setpoint, nest.cool_setpoint, nest.target_temperature, nest.setpoint_deadband], [68, 71, 71, 3]);
  // A °C one stays as it came.
  assert.deepEqual(inOwnScale(structuredClone(FLOOR)), FLOOR);
});

test("from a driver before 1.10.2, what was reported for nothing is nothing: never 0° or -18°", () => {
  const older = inOwnScale({ id: 1, name: "Living Room", mode: "undefined", activity: "undefined", current_temperature: 0, target_temperature: -18, heat_setpoint: null, cool_setpoint: null });
  assert.equal(older.current_temperature, null);
  assert.equal(older.target_temperature, null);
  assert.equal(older.mode, null);
  assert.equal(older.activity, null);
  assert.equal(older.scale, "C");
  const real = inOwnScale({ id: 2, current_temperature: 21.5, target_temperature: 5, mode: "heat" });
  assert.deepEqual([real.current_temperature, real.target_temperature, real.mode], [21.5, 5, "heat"]);
});

test("a °F thermostat's PATCH sends the °F chosen, exactly; a °C one's is as before", () => {
  const own = inOwnScale(structuredClone(MINISPLIT));
  assert.deepEqual(apiChange(own, { target_temperature: 69, mode: "cool" }), { target_temperature_f: 69, mode: "cool" });
  const nest = inOwnScale(structuredClone(NEST));
  assert.deepEqual(apiChange(nest, { heat_setpoint: 66, cool_setpoint: 74 }), { heat_setpoint_f: 66, cool_setpoint_f: 74 });
  assert.deepEqual(apiChange(FLOOR, { target_temperature: 21.5 }), { target_temperature: 21.5 });
});

test("a whole °F kept as °C to 0.1 comes back as that °F, as the controller rounds it", () => {
  for (let fahrenheit = 41; fahrenheit <= 104; fahrenheit += 1) {
    const celsius = toCelsius(fahrenheit, "F");
    assert.equal(Math.round(celsius * 10), celsius * 10, `${fahrenheit} °F: to 0.1`);
    assert.equal(fromCelsius(celsius, "F"), fahrenheit, `${fahrenheit} °F in the app`);
    // driver/src/adapters/thermostat_units.lua toNative: floor(c * 9 / 5 + 32 + 0.5).
    assert.equal(Math.floor((celsius * 9) / 5 + 32 + 0.5), fahrenheit, `${fahrenheit} °F on the controller`);
  }
  assert.equal(toCelsius(69, "F"), 20.6);
  assert.equal(toCelsius(22.5, "C"), 22.5);
});

test("a weather threshold in °F counts from the whole °F shown, the threshold itself included (ADR-074)", () => {
  assert.equal(thresholdToCelsius(81, "F"), 27, "80.5 °F is 26.94 °C, rounded up");
  assert.equal(thresholdToCelsius(77, "F"), 24.8, "76.5 °F is 24.72 °C");
  assert.equal(thresholdToCelsius(82, "F"), 27.5, "81.5 °F is 27.5 °C exactly");
  // The forecast is °C to 0.1 and the weather card shows it in whole °F: for every whole °F the
  // editor offers and every forecast, the rule (forecast >= threshold kept) runs exactly when the
  // weather shown is that °F or more.
  for (let fahrenheit = 59; fahrenheit <= 113; fahrenheit += 1) {
    const kept = thresholdToCelsius(fahrenheit, "F");
    assert.equal(Math.round(kept * 10), kept * 10, `${fahrenheit} °F: °C to 0.1`);
    assert.equal(fromCelsius(kept, "F"), fahrenheit, `${fahrenheit} °F is shown again`);
    for (let tenths = -100; tenths <= 500; tenths += 1) {
      const forecast = tenths / 10;
      assert.equal(forecast >= kept, fromCelsius(forecast, "F") >= fahrenheit, `${fahrenheit} °F at ${forecast} °C (shown ${fromCelsius(forecast, "F")}°)`);
    }
  }
  // A threshold kept in °C stays as it is while its number is not changed.
  assert.equal(thresholdToCelsius(82, "F", 28), 28, "28 °C shows as 82 °F");
  assert.equal(thresholdToCelsius(83, "F", 28), 28.1, "changed: from the °F chosen");
  assert.equal(thresholdToCelsius(23, "C", 28), 23);
  // Ready again 2 °C below: in °F the highest whole °F shown that surely is.
  assert.equal(cooledTo(27, 2, "F"), 76, "25 °C is 77 °F: shown 77 can be 77.2");
  for (const kept of [27, 24.8, 27.5, 30]) {
    const shown = cooledTo(kept, 2, "F");
    for (let tenths = 0; tenths <= 500; tenths += 1) {
      if (fromCelsius(tenths / 10, "F") <= shown) assert.ok(tenths / 10 <= kept - 2, `${kept}: ${tenths / 10} °C shown as ${shown}°`);
    }
  }
  assert.equal(cooledTo(23, 2, "C"), 21);
});

test("in °F the steps and the gap are whole degrees; in °C they stay as they were", () => {
  const own = inOwnScale(structuredClone(MINISPLIT));
  assert.deepEqual(nudgedChange(own, 1), { target_temperature: 70 });
  assert.deepEqual(nudgedChange(own, -1), { target_temperature: 68 });
  assert.equal(clampTarget(own, 72.4), 72);
  assert.equal(clampTarget(own, 95), 89);
  assert.equal(clampTarget({ target_temperature_min: 16, target_temperature_max: 32 }, 22.3), 22.5, "°C: 0.5");
  const nest = inOwnScale(structuredClone(NEST));
  assert.equal(setpointGap(nest), 3, "the Nest's 3 °F");
  assert.deepEqual(nudgedChange({ ...nest, mode: "auto" }, 2, "heat_setpoint"), { heat_setpoint: 70, cool_setpoint: 73 }, "cool stays 3 °F above");
  assert.deepEqual(withSetpoint(nest, "cool_setpoint", 69), { heat_setpoint: 66, cool_setpoint: 69 });
  assert.equal(setpointGap({ setpoint_deadband: 1.7 }), 2, "°C as before");
  // Not reported: the first tap starts from the room, or 72 °F.
  assert.deepEqual(nudgedChange({ ...own, target_temperature: null, current_temperature: null }, 1), { target_temperature: 73 });
  assert.equal(nudgedChange(inOwnScale(structuredClone(SENSOR)), 1), null, "a sensor: nothing to set");
});

test("a scene editor in °F works in whole °F and keeps °C, a thermostat's values converted", () => {
  const celsius = inScale(inOwnScale(structuredClone(NEST)), "C");
  assert.deepEqual([celsius.heat_setpoint, celsius.cool_setpoint, celsius.target_temperature_min, celsius.target_temperature_max], [20, 21.7, 5, 35]);
  const fahrenheit = inScale(FLOOR, "F");
  assert.deepEqual([fahrenheit.target_temperature, fahrenheit.target_temperature_min, fahrenheit.target_temperature_max], [77, 61, 90]);
});

// ---- screens -----------------------------------------------------------------------------------

test("Climate: the minisplit in °F, the sensor as one compact row, a missing reading as —", () => {
  connected([MINISPLIT, NEST, SENSOR, FLOOR]);
  const view = climateView();
  const cards = allByClass(view, "device");
  const card = (name) => cards.find((item) => textOf(item).includes(name));
  const minisplit = card("Living Room Minisplit");
  assert.equal(plain(byClass(minisplit, "stepper-number").textContent), "69°", "not 21°");
  assert.match(textOf(byClass(minisplit, "device-meta")), /now 74°/);
  const nest = card("Hallway");
  assert.equal(plain(byClass(nest, "stepper-number").textContent), "71°", "its cool setpoint, not -18°");
  const sensor = card("Bathroom");
  assert.ok(sensor.className.includes("is-sensor"));
  assert.equal(textOf(byClass(sensor, "device-meta")), "73° · 30%");
  assert.equal(byClass(sensor, "stepper"), null, "no target");
  assert.equal(byClass(sensor, "chip-row"), null, "no mode or fan");
  assert.ok(!/Undefined/.test(textOf(sensor)));
  const floor = card("Kitchen floor");
  assert.match(textOf(byClass(floor, "device-meta")), /now —/, "never 0°");
  assert.ok(!/0°/.test(textOf(byClass(floor, "device-meta"))));
});

test("a thermostat card in Hebrew, Spanish and Italian: the same °F, the sensor's humidity named", async () => {
  connected([MINISPLIT, SENSOR]);
  for (const language of ["he", "es", "it"]) {
    await setLanguage(language);
    try {
      assert.equal(plain(byClass(thermostatCard(state.thermostats[0]), "stepper-number").textContent), "69°", language);
      const sensor = thermostatCard(state.thermostats[1]);
      assert.equal(textOf(byClass(sensor, "device-meta")), "73° · 30%", language);
      const humidity = find(sensor, (node) => node.attributes["aria-label"]?.includes("30"));
      assert.ok(humidity && !/climate\./.test(humidity.attributes["aria-label"]), `${language}: ${humidity?.attributes["aria-label"]}`);
    } finally {
      await setLanguage("en");
    }
  }
});

test("Home: favorites in °F, the sensor's reading, — for a reading not reported; no AC chip for sensors only", () => {
  connected([MINISPLIT, SENSOR, FLOOR]);
  const view = homeView({ openCamera() {}, openFavoritesPicker() {} });
  const tiles = allByClass(view, "fav-tile").map(textOf);
  assert.ok(tiles.some((text) => /Living Room Minisplit.*74°.*Cool 69°/.test(text)), tiles.join(" / "));
  assert.ok(tiles.some((text) => /Bathroom.*73° · 30%/.test(text)), tiles.join(" / "));
  assert.ok(tiles.some((text) => /Kitchen floor.*— · Off/.test(text)), tiles.join(" / "));
  const rooms = allByClass(view, "room-status").map(textOf);
  assert.ok(rooms.some((text) => text.includes("73° · 30%")), rooms.join(" / "));
  connected([SENSOR]);
  assert.equal(byKey(homeView({ openCamera() {}, openFavoritesPicker() {} }), "filter:climate"), null);
});

test("commands in °F mean °F: 72, two degrees warmer, the answers; sensors are never offered", () => {
  connected([MINISPLIT, NEST, SENSOR]);
  const catalog = commandCatalog();
  assert.deepEqual(catalog.devices.filter((device) => device.kind === "thermostat").map((device) => device.id).sort(), [33, 34]);
  const minisplit = catalog.devices.find((device) => device.id === 33);
  assert.deepEqual([minisplit.scale, minisplit.min, minisplit.max], ["F", 61, 89]);
  const set = parseCommand("set the living room minisplit to 72", catalog);
  assert.equal(set.status, "ok", JSON.stringify(set));
  assert.deepEqual(set.action.change, { temperature: 72 });
  assert.deepEqual(parseCommand("set the living room minisplit to 72.4 degrees", catalog).action?.change, { temperature: 72 }, "whole °F");
  assert.equal(parseCommand("set the living room minisplit to 22", catalog).problem, "range", "22 °F is not in its range");
  const warmer = parseCommand("make the living room minisplit 2 degrees warmer", catalog);
  assert.deepEqual(warmer.action?.change, { temperatureBy: 2 });

  const own = state.thermostats.find((item) => item.id === 33);
  assert.deepEqual(steppedTemperature(own, { temperatureBy: 2 }), { temperature: 71 });
  assert.deepEqual(thermostatPlan(own, { temperature: 72 }), { patch: { target_temperature: 72 } });
  assert.deepEqual(apiChange(own, thermostatPlan(own, { temperature: 72 }).patch), { target_temperature_f: 72 });
  const nest = state.thermostats.find((item) => item.id === 34);
  assert.deepEqual(thermostatPlan(nest, { temperature: 70 }).patch, { cool_setpoint: 70, heat_setpoint: 67 }, "the Nest's heat stays 3 °F below");
  assert.match(plain(thermostatPlan(nest, { temperature: 99 }).refused), /41°.*95°/);
  // Not reported: a step has nothing to start from.
  assert.ok(steppedTemperature({ ...own, target_temperature: null }, { temperatureBy: 1 }).refused);
});

// ---- scenes ------------------------------------------------------------------------------------

const KEY = "abcd1234";
function sceneHome(steps) {
  connected([MINISPLIT, NEST, SENSOR]);
  state.scenes = [{ id: KEY, name: "Evening", icon: "moon", show_on_home: false, version: 3, steps: structuredClone(steps) }];
  state.scenesUnsupported = false;
  resetSceneEditor();
  backs.length = 0;
}
const edit = (index) => sceneEditorView(KEY, false, { navigate() {} }, index);

test("a scene's AC action in °F: shown in whole °F, kept as °C that comes back exactly", () => {
  sceneHome([
    { type: "climate", room_id: 11, device_ids: null, set: { mode: "cool", target_temperature: 20.6 } },
    { type: "climate", room_id: 10, device_ids: null, set: { mode: "auto", heat_setpoint: 20, cool_setpoint: 24 } },
  ]);
  assert.equal(plain(stepAction(state.scenes[0].steps[0])), "Cool, 69°", "the list says 69°");
  assert.match(plain(stepAction(state.scenes[0].steps[1])), /Auto, 68°.75°/);
  let nodes = edit(0);
  assert.equal(plain(byClass(nodes, "stepper-number").textContent), "69°");
  assert.ok(!textOf(nodes).includes("Bathroom"), "a sensor is no AC to pick");
  press(nodes, "add-temp-up");
  nodes = edit(0);
  assert.equal(plain(byClass(nodes, "stepper-number").textContent), "70°");
  press(nodes, "add-confirm");
  assert.deepEqual(ui.sceneEditor.steps[0].set, { mode: "cool", target_temperature: 21.1 }, "70 °F as 21.1 °C");
  assert.equal(Math.floor((21.1 * 9) / 5 + 32 + 0.5), 70);

  nodes = edit(1);
  assert.match(textOf(byClass(nodes, "stepper-pair")), /68°.*75°/s);
  press(nodes, "add-heat-up");
  press(nodes, "add-heat-up");
  press(nodes, "add-heat-up");
  press(nodes, "add-heat-up");
  press(nodes, "add-heat-up");
  nodes = edit(1);
  assert.match(textOf(byClass(nodes, "stepper-pair")), /73°.*76°/s, "cool kept the Nest's 3 °F above");
  assert.match(textOf(nodes), /at least 3°/);
  press(nodes, "add-confirm");
  assert.deepEqual(ui.sceneEditor.steps[1].set, { mode: "auto", heat_setpoint: 22.8, cool_setpoint: 24.4 });
});

test("copying the house keeps a °F thermostat's whole °F as °C, and leaves sensors out", () => {
  connected([MINISPLIT, NEST, SENSOR]);
  const { steps } = copyHouse();
  const climate = steps.filter((step) => step.type === "climate");
  assert.deepEqual(climate.map((step) => step.device_ids).flat().sort(), [33, 34]);
  const minisplit = climate.find((step) => step.device_ids.includes(33));
  assert.equal(minisplit.set.target_temperature, 20.6, "69 °F");
  const nest = climate.find((step) => step.device_ids.includes(34));
  assert.equal(nest.set.target_temperature, 21.7, "71 °F");
});

// ---- the weather and schedules -----------------------------------------------------------------

const today = new Date().toISOString().slice(0, 10);
const WEATHER = {
  status: "ok",
  detail: null,
  location: null,
  fetched_at: `${today}T08:00:00Z`,
  source: "forecast",
  forecast_for: `${today}T14:20:30Z`,
  forecast_until: "2099-01-01T08:00:00Z",
  current: { temperature: 28.9, wind_speed: 12, wind_gusts: null, precipitation: 0, raining: false, weather_code: 1 },
  today: { max_temperature: 31.1, min_temperature: 18.3, rain_chance: 10, sunrise: "06:35", sunset: "18:10" },
  attribution: "Weather data by Open-Meteo.com",
};

test("the weather card and schedules are in the project's °F; thresholds kept in °C count from the °F shown", () => {
  connected([MINISPLIT]);
  state.weather = WEATHER;
  state.scenes = [{ id: KEY, name: "Cool down", icon: "climate", show_on_home: false, version: 1, steps: [] }];
  const card = byClass(schedulesView(), "weather-card");
  assert.match(plain(card.textContent), /84°/, "28.9 °C");
  assert.match(plain(card.textContent), /65°.*88°/, "today 18.3-31.1 °C");

  const heat = { trigger: { type: "weather", kind: "heat", above: 27 }, days: [0, 1, 2, 3, 4, 5, 6] };
  assert.equal(plain(whenText(heat)), "When it’s 81° or hotter outside");
  assert.equal(plain(conditionText({ trigger: { type: "time", at: "07:00" }, days: [0, 1, 2, 3, 4, 5, 6], only_if: { hotter_than: 24.8 } })), "Only if it’s 77° or warmer");

  resetScheduleEditor();
  const draft = draftFor("new");
  draft.type = "weather";
  draft.kind = "heat";
  assert.equal(draft.heat, 86, "30 °C");
  let nodes = scheduleEditorView("new");
  assert.match(textOf(nodes), /Runs again only after it has cooled to 81° or less/, "29.8 °C less 2 is 82.04 °F");
  draft.heat = 81;
  assert.equal(scheduleBody(draft).trigger.above, 27);
  draft.heat = 59;
  assert.equal(scheduleBody(draft).trigger.above, 15, "the lowest the controller takes");
  draft.type = "time";
  draft.hot = true;
  assert.equal(draft.hotterThan, 82, "28 °C");
  assert.equal(scheduleBody(draft).only_if.hotter_than, 27.5, "82 °F: from 81.5 °F");
  draft.hotterThan = 77;
  assert.equal(scheduleBody(draft).only_if.hotter_than, 24.8);

  // One saved in °C keeps its °C while its number is not changed.
  state.schedules = [{ id: "s0000001", enabled: true, scene_id: KEY, trigger: { type: "weather", kind: "heat", above: 28, once_a_day: true }, days: [0, 1, 2, 3, 4, 5, 6], only_if: {}, if_no_weather: "run", version: 1 }];
  resetScheduleEditor();
  const kept = draftFor("s0000001");
  assert.equal(kept.heat, 82);
  assert.equal(scheduleBody(kept).trigger.above, 28);
  kept.heat = 83;
  assert.equal(scheduleBody(kept).trigger.above, 28.1);
  resetScheduleEditor();
});

test("a °C home is as before: 0.5 °C, thresholds as chosen", () => {
  connected([FLOOR], "C");
  state.weather = WEATHER;
  assert.match(plain(byClass(schedulesView(), "weather-card").textContent), /28\.9°/);
  resetScheduleEditor();
  const draft = draftFor("new");
  draft.type = "weather";
  draft.kind = "heat";
  assert.equal(draft.heat, 30);
  draft.heat = 23;
  assert.equal(scheduleBody(draft).trigger.above, 23);
  resetScheduleEditor();
});

test("a refrigerator in a °F home shows whole °F, as it is set there", async () => {
  const { zones } = await import("../../app/js/refrigerators.js");
  const fridge = { fridge_temperature: 2.8, fridge_setpoint: 2.8, freezer_temperature: -17.8, freezer_setpoint: -17.8 };
  assert.deepEqual(zones(fridge, "F").map((zone) => [zone.temperature, zone.setpoint]), [[37, 37], [0, 0]]);
  assert.deepEqual(zones(fridge).map((zone) => zone.temperature), [2.8, -17.8], "°C as reported");
});
