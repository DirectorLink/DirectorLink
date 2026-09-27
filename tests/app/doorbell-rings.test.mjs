// When a doorbell ring counts as "someone is at the door", and the relative times shown for
// doorbell events (app/js/rings.js).
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import { CLOCK_AHEAD_MS, RING_WINDOW_MS, relativeParts, ringIsRecent } from "../../app/js/rings.js";

const NOW = Date.parse("2026-09-27T12:00:00Z");
const ago = (ms) => new Date(NOW - ms).toISOString();

test("a ring within the last 2 minutes is recent", () => {
  assert.equal(ringIsRecent(ago(0), { now: NOW }), true);
  assert.equal(ringIsRecent(ago(RING_WINDOW_MS - 1000), { now: NOW }), true);
  assert.equal(ringIsRecent(ago(RING_WINDOW_MS + 1000), { now: NOW }), false);
});

test("no ring, or an unreadable time, is never recent", () => {
  assert.equal(ringIsRecent(null, { now: NOW }), false);
  assert.equal(ringIsRecent("", { now: NOW }), false);
  assert.equal(ringIsRecent("yesterday", { now: NOW }), false);
});

test("a controller clock a little ahead is tolerated, far ahead is not", () => {
  assert.equal(ringIsRecent(ago(-60 * 1000), { now: NOW }), true);
  assert.equal(ringIsRecent(ago(-(CLOCK_AHEAD_MS + 1000)), { now: NOW }), false);
});

test("a ring this page noticed is recent for 2 minutes, whatever the controller's clock says", () => {
  const behind = ago(20 * 60 * 1000); // the controller's clock runs 20 minutes behind
  assert.equal(ringIsRecent(behind, { now: NOW }), false);
  assert.equal(ringIsRecent(behind, { now: NOW, noticedAt: NOW - 30 * 1000 }), true);
  assert.equal(ringIsRecent(behind, { now: NOW, noticedAt: NOW - RING_WINDOW_MS - 1000 }), false);
  const ahead = ago(-30 * 60 * 1000);
  assert.equal(ringIsRecent(ahead, { now: NOW, noticedAt: NOW - 5000 }), true);
});

test("relative times: now, minutes, hours, days; the future reads as now", () => {
  assert.deepEqual(relativeParts(NOW - 10 * 1000, NOW), { value: 0, unit: "second" });
  assert.deepEqual(relativeParts(NOW + 90 * 1000, NOW), { value: 0, unit: "second" });
  assert.deepEqual(relativeParts(NOW - 3 * 60 * 1000, NOW), { value: -3, unit: "minute" });
  assert.deepEqual(relativeParts(NOW - 60 * 60 * 1000, NOW), { value: -1, unit: "hour" });
  assert.deepEqual(relativeParts(NOW - 5 * 60 * 60 * 1000, NOW), { value: -5, unit: "hour" });
  assert.deepEqual(relativeParts(NOW - 3 * 24 * 60 * 60 * 1000, NOW), { value: -3, unit: "day" });
});
