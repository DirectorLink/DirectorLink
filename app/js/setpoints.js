// Thermostats with separate heat and cool setpoints (`setpoints: "dual"`, the Control4
// thermostat proxy). In auto the thermostat keeps both, at least `setpoint_deadband` apart; in heat
// or cool it works to one of them, which the API also reports as `target_temperature`.
// No imports, so the rules can be tested under Node (tests/app/setpoints.test.mjs).

// How close a reported temperature must be to count as the one sent. In °F projects the
// controller takes whole °F, so a 0.5 °C step can come back up to 0.3 off (22.5 → 73 °F → 22.8).
export const TEMPERATURE_TOLERANCE = 0.4;

export const SETPOINT_FIELDS = ["heat_setpoint", "cool_setpoint"];

// Drivers before 1.1.0 send no `setpoints`: those thermostats have one target temperature.
export const isDual = (thermostat) => thermostat?.setpoints === "dual";

export const sameTemperature = (reported, wanted) => Number.isFinite(reported) && Math.abs(reported - wanted) < TEMPERATURE_TOLERANCE;

const finite = (value) => (Number.isFinite(value) ? value : null);

// The gap the app keeps between heat and cool: the deadband rounded up to the 0.5 steps the app
// sends, and at least 0.5. Rounded up, it is still at least the deadband after the controller rounds
// both setpoints to whole °F (a 1.7 °C deadband is 3 °F; a 2 °C gap is 3.6 °F).
// Without a deadband the controller still wants cool above heat. 0.5 is not enough in a °F
// project (22.5 and 23 are both 73 °F); 1 always is.
export function setpointGap(thermostat) {
  const deadband = Number(thermostat?.setpoint_deadband);
  if (!Number.isFinite(deadband) || deadband <= 0) return 1;
  // The tiny margin keeps 2.0000000001 (float noise) at 2.
  return Math.max(0.5, Math.ceil(deadband * 2 - 1e-9) / 2);
}

// The setpoint the current mode works to: heat or cool; none in auto and off.
export function activeSetpoint(thermostat) {
  if (thermostat?.mode === "heat") return finite(thermostat.heat_setpoint);
  if (thermostat?.mode === "cool") return finite(thermostat.cool_setpoint);
  return null;
}

// The setpoints the card shows: the one of the mode in heat and cool, both (those reported) in
// auto and off.
export function shownSetpoints(thermostat) {
  if (thermostat?.mode === "heat") return ["heat_setpoint"];
  if (thermostat?.mode === "cool") return ["cool_setpoint"];
  return SETPOINT_FIELDS.filter((field) => Number.isFinite(thermostat?.[field]));
}

// Both setpoints after setting `field` to `value`: the other one moves when needed to stay
// setpointGap away (cool up with heat, heat down with cool). Null when `value` is outside the
// thermostat's range or the other one would have to leave it, as the controller would refuse.
export function withSetpoint(thermostat, field, value) {
  const min = Number.isFinite(thermostat.target_temperature_min) ? thermostat.target_temperature_min : 5;
  const max = Number.isFinite(thermostat.target_temperature_max) ? thermostat.target_temperature_max : 35;
  if (!SETPOINT_FIELDS.includes(field) || !Number.isFinite(value) || value < min || value > max) return null;
  const gap = setpointGap(thermostat);
  let heat = finite(thermostat.heat_setpoint);
  let cool = finite(thermostat.cool_setpoint);
  // Reported setpoints are rounded to 0.1, so the comparison allows for float noise.
  const tooClose = () => heat !== null && cool !== null && cool - heat < gap - 1e-9;
  if (field === "heat_setpoint") {
    heat = value;
    if (tooClose()) cool = heat + gap;
  } else {
    cool = value;
    if (tooClose()) heat = cool - gap;
  }
  if ((heat !== null && heat < min) || (cool !== null && cool > max)) return null;
  return { heat_setpoint: heat, cool_setpoint: cool };
}
