// Heat and cool setpoints in the app (app/js/setpoints.js): the gap the app keeps, the push when one
// setpoint comes too close to the other, the limits, and what counts as confirmed.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import {
  TEMPERATURE_TOLERANCE,
  activeSetpoint,
  isDual,
  sameTemperature,
  setpointGap,
  shownSetpoints,
  withSetpoint,
} from "../../app/js/setpoints.js";

// The fake Director's thermostat 31 (driver/tests/c4mock.lua withDualThermostat, °F): heat 68 °F,
// cool 76 °F, deadband 3 °F, as the driver reports them in °C.
const study = {
  id: 31,
  setpoints: "dual",
  mode: "auto",
  heat_setpoint: 20,
  cool_setpoint: 24.4,
  setpoint_deadband: 1.7,
  target_temperature: null,
  target_temperature_min: 5,
  target_temperature_max: 35,
};
// A Thermostat V2 zone: one target temperature, and null setpoints.
const zone = { id: 30, setpoints: "single", mode: "cool", heat_setpoint: null, cool_setpoint: null, setpoint_deadband: null, target_temperature: 22 };

test("only thermostats that report setpoints: dual have two setpoints", () => {
  assert.equal(isDual(study), true);
  assert.equal(isDual(zone), false);
  // Drivers before 1.1.0 send no setpoints key.
  assert.equal(isDual({ id: 30, target_temperature: 22 }), false);
  assert.equal(isDual(null), false);
});

test("the gap is the deadband rounded up to 0.5, and at least 0.5", () => {
  assert.equal(setpointGap({ setpoint_deadband: 1.7 }), 2, "3 °F");
  assert.equal(setpointGap({ setpoint_deadband: 2.2 }), 2.5, "4 °F");
  assert.equal(setpointGap({ setpoint_deadband: 1.5 }), 1.5);
  assert.equal(setpointGap({ setpoint_deadband: 2 }), 2, "°C deadband on the grid already");
  assert.equal(setpointGap({ setpoint_deadband: 0.1 * 20 }), 2, "float noise does not add a step");
  assert.equal(setpointGap({ setpoint_deadband: 0.2 }), 0.5);
  assert.equal(setpointGap({ setpoint_deadband: null }), 0.5, "not reported");
  assert.equal(setpointGap({}), 0.5);
});

test("the gap still holds after the controller rounds both setpoints to whole °F", () => {
  const fahrenheit = (celsius) => Math.floor((celsius * 9) / 5 + 32 + 0.5);
  for (const deadbandF of [1, 2, 3, 4, 5]) {
    const gap = setpointGap({ setpoint_deadband: Math.round(((deadbandF * 5) / 9) * 10) / 10 });
    for (let heat = 5; heat + gap <= 35; heat += 0.5) {
      assert.ok(fahrenheit(heat + gap) - fahrenheit(heat) >= deadbandF, `${deadbandF} °F deadband, heat ${heat}`);
    }
  }
});

test("the active setpoint follows the mode", () => {
  assert.equal(activeSetpoint({ ...study, mode: "heat" }), 20);
  assert.equal(activeSetpoint({ ...study, mode: "cool" }), 24.4);
  assert.equal(activeSetpoint(study), null, "auto");
  assert.equal(activeSetpoint({ ...study, mode: "off" }), null);
  assert.equal(activeSetpoint({ ...study, mode: "heat", heat_setpoint: null }), null);
});

test("the card shows the setpoint of heat or cool, and both in auto and off", () => {
  assert.deepEqual(shownSetpoints({ ...study, mode: "heat" }), ["heat_setpoint"]);
  assert.deepEqual(shownSetpoints({ ...study, mode: "cool" }), ["cool_setpoint"]);
  assert.deepEqual(shownSetpoints(study), ["heat_setpoint", "cool_setpoint"]);
  assert.deepEqual(shownSetpoints({ ...study, mode: "off" }), ["heat_setpoint", "cool_setpoint"]);
  // A thermostat that reports only one of them shows that one.
  assert.deepEqual(shownSetpoints({ ...study, heat_setpoint: null }), ["cool_setpoint"]);
  assert.deepEqual(shownSetpoints({ ...study, mode: null }), ["heat_setpoint", "cool_setpoint"]);
});

test("a setpoint with room to spare changes alone", () => {
  assert.deepEqual(withSetpoint(study, "heat_setpoint", 21), { heat_setpoint: 21, cool_setpoint: 24.4 });
  assert.deepEqual(withSetpoint(study, "cool_setpoint", 25), { heat_setpoint: 20, cool_setpoint: 25 });
  assert.deepEqual(withSetpoint(study, "heat_setpoint", 22), { heat_setpoint: 22, cool_setpoint: 24.4 }, "2.4 apart is enough");
});

test("heat pushes cool up, and cool pushes heat down, to keep the gap", () => {
  assert.deepEqual(withSetpoint(study, "heat_setpoint", 23.5), { heat_setpoint: 23.5, cool_setpoint: 25.5 });
  assert.deepEqual(withSetpoint(study, "cool_setpoint", 21), { heat_setpoint: 19, cool_setpoint: 21 });
  // Exactly the gap apart is enough (no float trouble on the 0.5 grid).
  assert.deepEqual(withSetpoint({ ...study, cool_setpoint: 24 }, "heat_setpoint", 22), { heat_setpoint: 22, cool_setpoint: 24 });
  // A lower heat setpoint never pulls cool down with it.
  assert.deepEqual(withSetpoint(study, "heat_setpoint", 18), { heat_setpoint: 18, cool_setpoint: 24.4 });
});

test("a setpoint outside the range, or a push that would leave it, is refused", () => {
  assert.equal(withSetpoint(study, "heat_setpoint", 4.5), null, "below the minimum");
  assert.equal(withSetpoint(study, "cool_setpoint", 35.5), null, "above the maximum");
  assert.equal(withSetpoint(study, "cool_setpoint", 6), null, "heat would have to go to 4");
  assert.deepEqual(withSetpoint(study, "cool_setpoint", 7), { heat_setpoint: 5, cool_setpoint: 7 }, "heat goes exactly to the minimum");
  assert.equal(withSetpoint({ ...study, cool_setpoint: 35 }, "heat_setpoint", 33.5), null, "cool would have to go to 35.5");
  assert.deepEqual(withSetpoint({ ...study, cool_setpoint: 35 }, "heat_setpoint", 33), { heat_setpoint: 33, cool_setpoint: 35 });
  assert.equal(withSetpoint(study, "target_temperature", 22), null, "only heat_setpoint and cool_setpoint");
  assert.equal(withSetpoint(study, "heat_setpoint", Number.NaN), null);
});

test("a thermostat that reports one setpoint changes it without a push", () => {
  assert.deepEqual(withSetpoint({ ...study, heat_setpoint: null }, "cool_setpoint", 21), { heat_setpoint: null, cool_setpoint: 21 });
  assert.deepEqual(withSetpoint({ ...study, cool_setpoint: null }, "heat_setpoint", 30), { heat_setpoint: 30, cool_setpoint: null });
});

test("a reported temperature within 0.4 of the one sent counts as confirmed", () => {
  assert.equal(TEMPERATURE_TOLERANCE, 0.4);
  // 22.5 °C is sent as 73 °F and comes back as 22.8.
  assert.equal(sameTemperature(22.8, 22.5), true);
  assert.equal(sameTemperature(23, 22.5), false);
  assert.equal(sameTemperature(22.5, 22.5), true);
  assert.equal(sameTemperature(null, 22.5), false);
  assert.equal(sameTemperature(undefined, 22.5), false);
});
