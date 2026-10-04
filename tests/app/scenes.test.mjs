// Copy the house as it is now (app/js/scenes.js copyHouse): the temperatures it copies are ones a
// scene step takes, so the scene can be saved and tried.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io", href: "https://app.directorlink.io/", hash: "" };
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};
globalThis.document = { documentElement: {}, querySelector: () => null, hidden: true, hasFocus: () => false, addEventListener: () => {} };

const { SCENE_MAX_TEMPERATURE, SCENE_MIN_TEMPERATURE, copyHouse } = await import("../../app/js/scenes.js");
const { state } = await import("../../app/js/state.js");

// The fake Director's thermostats (driver/tests/c4mock.lua demoProject) as the driver reports them,
// with a heat setpoint set on the thermostat itself to 40 °F (4.4 °C), below what DirectorLink sets.
const study = {
  id: 31,
  setpoints: "dual",
  mode: "auto",
  modes: ["off", "heat", "cool", "auto"],
  heat_setpoint: 4.4,
  cool_setpoint: 24.4,
  setpoint_deadband: 1.7,
  target_temperature: null,
  target_temperature_min: 5,
  target_temperature_max: 35,
  fan_speed: "auto",
  fan_speeds: ["auto", "on"],
};
const floor = { id: 32, setpoints: "single", mode: "heat", modes: ["off", "heat"], target_temperature: 4, target_temperature_min: 5, target_temperature_max: 32, fan_speeds: [] };
const parents = { id: 30, setpoints: "single", mode: "cool", modes: ["off", "heat", "cool"], target_temperature: 22, target_temperature_min: 16, target_temperature_max: 32, fan_speed: "low", fan_speeds: ["low", "medium", "high"] };

function copy(...thermostats) {
  state.lights = [];
  state.blinds = [];
  state.thermostats = thermostats;
  return copyHouse().steps.map((step) => ({ ids: step.device_ids, set: step.set }));
}

function temperatures(steps) {
  return steps.flatMap(({ set }) => [set.target_temperature, set.heat_setpoint, set.cool_setpoint].filter((value) => value !== undefined));
}

test("a setpoint below what a scene takes is copied at the lowest it takes", () => {
  assert.deepEqual(copy(study), [{ ids: [31], set: { mode: "auto", heat_setpoint: 5, cool_setpoint: 24.4, fan_speed: "auto" } }]);
  assert.deepEqual(copy({ ...study, mode: "heat", target_temperature: 4.4 }), [{ ids: [31], set: { mode: "heat", target_temperature: 5, fan_speed: "auto" } }]);
  assert.deepEqual(copy(floor), [{ ids: [32], set: { mode: "heat", target_temperature: 5 } }], "floor heating parked at 4 °C");
});

test("every copied temperature is one the scene step takes, within the thermostat's range", () => {
  const older = { ...parents, id: 33, mode: "heat", target_temperature: -18 };
  const hot = { ...study, id: 34, heat_setpoint: 30, cool_setpoint: 41 };
  const steps = copy(study, floor, parents, older, hot);
  for (const value of temperatures(steps)) {
    assert.ok(value >= SCENE_MIN_TEMPERATURE && value <= SCENE_MAX_TEMPERATURE, `${value} is outside ${SCENE_MIN_TEMPERATURE}-${SCENE_MAX_TEMPERATURE}`);
  }
  assert.deepEqual(steps.find(({ ids }) => ids.includes(30)).set, { mode: "cool", target_temperature: 22, fan_speed: "low" }, "a value in range stays as it is");
  assert.equal(steps.find(({ ids }) => ids.includes(33)).set.target_temperature, 16, "a 1.0.0 driver's -18° floor zone gets its lowest, 16°");
  assert.deepEqual(steps.find(({ ids }) => ids.includes(34)).set, { mode: "auto", heat_setpoint: 30, cool_setpoint: 35, fan_speed: "auto" });
});

test("cool stays above heat once both are kept in range, or neither is copied", () => {
  assert.deepEqual(copy({ ...study, heat_setpoint: 36, cool_setpoint: 38 }), [{ ids: [31], set: { mode: "auto", fan_speed: "auto" } }]);
  assert.deepEqual(copy({ ...study, heat_setpoint: 3, cool_setpoint: 4.5 }), [{ ids: [31], set: { mode: "auto", fan_speed: "auto" } }]);
  assert.deepEqual(copy({ ...study, heat_setpoint: 3, cool_setpoint: 5.5 }), [{ ids: [31], set: { mode: "auto", heat_setpoint: 5, cool_setpoint: 5.5, fan_speed: "auto" } }]);
});

// A member's scene (1.8.0, ADR-054): the controller leaves out the rooms and devices they don't
// see and says the step works `elsewhere`; the card names none of those, and never calls a room that
// exists "A removed room".
test("a member's scene names only their rooms and devices: the rest is elsewhere", async () => {
  const { sceneSummary, stepWhat, stepWhere } = await import("../../app/js/scenes.js");
  const { setLanguage } = await import("../../app/js/i18n.js");
  await setLanguage("en");
  state.rooms = [{ id: 11, name: "Living room", names: {} }];
  state.lights = [{ id: 21, name: "Ceiling", room: { id: 11 } }];
  const kitchen = { type: "lights", room_id: null, device_ids: null, set: { on: false }, elsewhere: true };
  const both = { type: "lights", room_id: null, device_ids: [21], set: { on: false }, elsewhere: true };
  assert.equal(stepWhat(kitchen), "Lights elsewhere");
  assert.equal(stepWhere(kitchen), "Other rooms");
  assert.equal(stepWhat(both), "\u2068Ceiling\u2069 and more elsewhere");
  assert.equal(stepWhere(both), "\u2068Living room\u2069 and other rooms");
  const summary = sceneSummary({ steps: [kitchen, both] });
  assert.equal(summary, "\u2068Lights elsewhere\u2069: Off \u00b7 \u2068\u2068Ceiling\u2069 and more elsewhere\u2069: Off");
  assert.doesNotMatch(summary, /removed room/);
  // Without `elsewhere` (an admin's scene), a room the app doesn't know is one that was removed.
  assert.equal(stepWhere({ type: "lights", room_id: 10, device_ids: null, set: {} }), "A removed room");
  assert.equal(stepWhat({ type: "lights", room_id: null, device_ids: null, set: {} }), "All lights");
  await setLanguage("he");
  assert.equal(stepWhere(kitchen), "חדרים אחרים");
  await setLanguage("en");
});
