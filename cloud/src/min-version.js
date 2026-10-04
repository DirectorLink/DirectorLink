// The oldest DirectorLink the relay takes (ADR-059, docs/RELAY.md). If a flaw is found in the remote
// protocol, the Worker var MIN_DRIVER_VERSION ("1.8.0") turns away the drivers without the fix
// until they are updated; unset (or empty), every version connects. Nothing at home changes: the
// app on the home network does not go through here.
//
// - The Worker (index.js) checks a driver's X-DirectorLink-Version before its home's Durable
//   Object is asked, so an old driver trying again every minute costs one Worker request:
//   426 DRIVER_UPDATE_REQUIRED, with `minimum_version`. Drivers from 1.8.0 understand it (they
//   say "Update DirectorLink" in Composer and try again hourly); older ones take it as any other
//   refusal and keep trying with their backoff.
// - The home's object (home-relay.js) still has the version of the driver's last connection: a
//   home whose last driver is below the minimum is answered 503 HOME_UPDATE_REQUIRED rather than
//   HOME_OFFLINE, and its status says `update_required`, so the app says to update DirectorLink.
//
// Versions compare by their first three numbers (MAJOR.MINOR.PATCH; "1.8.0-rc.1" is 1.8.0). A
// version that has none ("dev", a missing header) is below any minimum. A minimum that is not
// three numbers is ignored (logged), so a typo cannot cut every home off.

const VERSION = /^(\d{1,6})\.(\d{1,6})\.(\d{1,6})(?![0-9])/;

function numbers(value) {
  const match = VERSION.exec(typeof value === "string" ? value.trim() : "");
  return match ? match.slice(1, 4).map(Number) : null;
}

let reported = null;

// The minimum as "MAJOR.MINOR.PATCH", or null when there is none.
export function minimumVersion(env) {
  const text = typeof env.MIN_DRIVER_VERSION === "string" ? env.MIN_DRIVER_VERSION.trim() : "";
  if (!text) return null;
  const parts = numbers(text);
  if (!parts || parts.join(".") !== text) {
    if (reported !== text) {
      reported = text;
      console.error(JSON.stringify({ event: "min_driver_version_invalid", value: text.slice(0, 40) }));
    }
    return null;
  }
  return text;
}

// Whether `version` (a driver's) is below `minimum`; one that is not a version is.
export function belowMinimum(version, minimum) {
  const wanted = numbers(minimum);
  if (!wanted) return false;
  const have = numbers(version);
  if (!have) return true;
  for (let index = 0; index < 3; index += 1) {
    if (have[index] !== wanted[index]) return have[index] < wanted[index];
  }
  return false;
}

// The minimum `version` is below, or null when it may connect.
export function updateRequired(env, version) {
  const minimum = minimumVersion(env);
  return minimum && belowMinimum(version, minimum) ? minimum : null;
}

// The Worker's refusal of a driver below the minimum (RFC 9457, as http.js problem()).
export function refusal(version, minimum) {
  const shown = typeof version === "string" && /^[\x21-\x7e]{1,64}$/.test(version.trim()) ? version.trim() : "this version";
  const body = {
    type: "about:blank",
    title: "Upgrade Required",
    status: 426,
    detail: `DirectorLink ${shown} can no longer connect to remote access: update DirectorLink to ${minimum} or later`,
    code: "DRIVER_UPDATE_REQUIRED",
    minimum_version: minimum,
  };
  return new Response(JSON.stringify(body), { status: 426, headers: { "content-type": "application/problem+json", "cache-control": "no-store" } });
}
