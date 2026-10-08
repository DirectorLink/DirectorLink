// Temperatures in the scale the home uses (1.10.2, ADR-076). There is no setting for it: each
// thermostat is shown in its own scale, as Control4 reports it (`scale`, and on a °F one its `*_f`
// values), and what no one thermostat says (the weather, weather schedules, "only if") in the
// project's (`temperature_scale` in GET /v1/system). Older drivers say neither: °C, as before.
//
// The app keeps each thermostat in its own scale (inOwnScale, where the lists come in): every
// screen, step and command then works in the degrees it shows, whole °F with 1° steps in °F, 0.5 °C
// in °C. What goes back to the controller is converted at the edge: a thermostat's PATCH names its
// `*_f` fields (apiChange); scenes keep °C to 0.1, from which the controller gets the whole °F
// chosen again exactly (toCelsius); schedules keep °C to 0.1 that counts at the whole °F shown
// (thresholdToCelsius).
// No imports, so the rules can be tested under Node (tests/app/fahrenheit.test.mjs).

// The temperature fields of a thermostat, each with its °F twin `<field>_f`.
export const TEMPERATURE_FIELDS = [
  "current_temperature",
  "target_temperature",
  "target_temperature_min",
  "target_temperature_max",
  "heat_setpoint",
  "cool_setpoint",
  "setpoint_deadband",
];

// The ones a PATCH sends.
const SENT_FIELDS = ["target_temperature", "heat_setpoint", "cool_setpoint"];

const finite = (value) => (Number.isFinite(value) ? value : null);

// "F" or "C": the thermostat's scale (a driver before 1.10.2 says none: °C).
export const scaleOf = (thermostat) => (thermostat?.scale === "F" ? "F" : "C");

// A thermostat proxy that only reads a temperature (and humidity), with nothing to set.
export const isSensor = (thermostat) => thermostat?.sensor === true;

// The project's scale, from GET /v1/system (`system`), for what no one thermostat says.
export const projectScale = (system) => (system?.temperature_scale === "F" ? "F" : "C");

// A value rounded to what the app sets in `scale`: whole °F, or 0.5 °C.
export function roundIn(value, scale) {
  return scale === "F" ? Math.round(value) : Math.round(value * 2) / 2;
}

// The range a thermostat's target is kept in when it says none: 10-32 °C (5-35 °C with heat and
// cool setpoints), the same in whole °F.
export function defaultRange(scale, dual) {
  if (scale === "F") return dual ? [41, 95] : [50, 90];
  return dual ? [5, 35] : [10, 32];
}

// The usual target when a thermostat reports none: 22 °C or 72 °F.
export const usualTarget = (scale) => (scale === "F" ? 72 : 22);

// °C to `scale`: the same in °C, whole °F in °F (a setpoint, a threshold or the weather shown;
// + 0 turns -0 into 0, which would show as "-0°").
export function fromCelsius(celsius, scale) {
  if (!Number.isFinite(celsius)) return null;
  return scale === "F" ? Math.round((celsius * 9) / 5 + 32) + 0 : celsius;
}

// A temperature in `scale` as °C to 0.1, as scenes keep it. A whole °F comes back as that °F
// exactly (0.1 °C is 0.18 °F): 69 °F is 20.6 °C, which is 69.08 °F.
export function toCelsius(value, scale) {
  if (!Number.isFinite(value)) return null;
  return scale === "F" ? Math.round(((value - 32) * 5) / 9 * 10) / 10 : value;
}

// A weather threshold in `scale` as the °C a schedule keeps. In °F the weather is shown in whole °F,
// so "81° or hotter" counts from the moment it shows 81°: from 80.5 °F (26.94 °C), kept rounded up
// to 0.1 (27.0). The forecast is °C to 0.1, so the rule then runs exactly when the weather shown is
// that °F or more, the threshold itself included (ADR-074): at 27.0 °C (80.6 °F, shown as 81°), never
// at 26.9 °C (80.4 °F, shown as 80°). It is shown as 81 again. `kept`: the °C the schedule has, kept
// as it is while it still shows as `value` (nothing changes when its number was not changed).
export function thresholdToCelsius(value, scale, kept) {
  if (!Number.isFinite(value)) return null;
  if (scale !== "F") return value;
  if (Number.isFinite(kept) && fromCelsius(kept, "F") === value) return kept;
  return Math.ceil(((value - 0.5 - 32) * 5) / 9 * 10 - 1e-9) / 10;
}

// "Ready again once it has cooled to X or less", a threshold kept in °C less `below` °C, in `scale`:
// in °F the highest whole °F shown (to 0.5 below) that is surely at or under it, so the words hold.
export function cooledTo(celsius, below, scale) {
  if (!Number.isFinite(celsius)) return null;
  return scale === "F" ? Math.floor(((celsius - below) * 9) / 5 + 32 - 0.5 + 1e-9) : celsius - below;
}

// A thermostat as the app keeps it: in its own scale. A °F one's temperature fields are its `*_f`
// values (the twins left out); a °C one stays as it came. From a driver before 1.10.2 (no
// `scale`), what it reported for nothing is nothing: a room at exactly 0 °C, a target of -18 °C
// (0 °F converted), an "Undefined" mode. Takes one already in its own scale unchanged.
export function inOwnScale(thermostat) {
  if (!thermostat || typeof thermostat !== "object") return thermostat;
  if (thermostat.scale === "F") {
    if (!TEMPERATURE_FIELDS.some((field) => `${field}_f` in thermostat)) return thermostat;
    const own = { ...thermostat };
    for (const field of TEMPERATURE_FIELDS) {
      const twin = `${field}_f`;
      if (twin in own) {
        own[field] = finite(own[twin]);
        delete own[twin];
      } else if (Number.isFinite(own[field])) {
        own[field] = field === "setpoint_deadband" ? Math.round((own[field] * 9) / 5) : fromCelsius(own[field], "F");
      }
    }
    return own;
  }
  if ("scale" in thermostat) return thermostat;
  const older = { ...thermostat };
  if (older.current_temperature === 0) older.current_temperature = null;
  for (const field of ["target_temperature", "heat_setpoint", "cool_setpoint"]) {
    if (Number.isFinite(older[field]) && older[field] < -17) older[field] = null;
  }
  if (older.mode === "undefined") older.mode = null;
  if (older.activity === "undefined") older.activity = null;
  older.scale = "C";
  return older;
}

// The PATCH body for `change` (in the thermostat's scale): a °F thermostat's temperatures go as
// their `*_f` fields, which it gets exactly (only a 1.10.2 driver says `scale: "F"`).
export function apiChange(thermostat, change) {
  if (scaleOf(thermostat) !== "F") return change;
  const body = {};
  for (const [field, value] of Object.entries(change)) {
    body[SENT_FIELDS.includes(field) ? `${field}_f` : field] = value;
  }
  return body;
}

// A thermostat's values in another scale (the scene editor's, when it differs): the range, the
// setpoints and the deadband converted.
export function inScale(thermostat, scale) {
  const from = scaleOf(thermostat);
  if (from === scale) return thermostat;
  const converted = { ...thermostat, scale };
  for (const field of TEMPERATURE_FIELDS) {
    const value = thermostat[field];
    if (!Number.isFinite(value)) continue;
    if (field === "setpoint_deadband") converted[field] = scale === "F" ? Math.ceil((value * 9) / 5) : Math.ceil(((value * 5) / 9) * 2) / 2;
    else converted[field] = scale === "F" ? fromCelsius(value, "F") : toCelsius(value, "F");
  }
  return converted;
}
