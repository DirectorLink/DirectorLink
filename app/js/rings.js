// Time rules for doorbell rings and "3 minutes ago", with no browser dependencies
// (tests/app/doorbell-rings.test.mjs runs them in Node).

// A ring counts as "someone is at the door" for this long.
export const RING_WINDOW_MS = 2 * 60 * 1000;
// How far ahead of this browser the controller's clock may run and still be believed.
export const CLOCK_AHEAD_MS = 2 * 60 * 1000;

// lastRingAt: the doorbell's last_ring_at (the controller's clock). noticedAt: when this page
// first saw that value change (this browser's clock), or null when it was already there when
// the page loaded. A ring is recent when its own time is within the window, or when this page
// noticed it within the window — so a controller clock that runs behind (or far ahead) still
// shows a ring that just happened while the page was open.
export function ringIsRecent(lastRingAt, { now = Date.now(), noticedAt = null } = {}) {
  if (!lastRingAt) return false;
  if (Number.isFinite(noticedAt) && now >= noticedAt && now - noticedAt < RING_WINDOW_MS) return true;
  const at = Date.parse(lastRingAt);
  if (!Number.isFinite(at)) return false;
  const age = now - at;
  return age < RING_WINDOW_MS && age > -CLOCK_AHEAD_MS;
}

// Value and unit for Intl.RelativeTimeFormat. Times in the future (a controller clock ahead of
// this one) read as "now".
export function relativeParts(atMs, now = Date.now()) {
  const seconds = Math.max(0, Math.round((now - atMs) / 1000));
  if (seconds < 45) return { value: 0, unit: "second" };
  const minutes = Math.round(seconds / 60);
  if (minutes < 45) return { value: -minutes, unit: "minute" };
  const hours = Math.round(minutes / 60);
  if (hours < 22) return { value: -hours, unit: "hour" };
  return { value: -Math.max(1, Math.round(hours / 24)), unit: "day" };
}
