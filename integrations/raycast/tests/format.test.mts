import { test } from "node:test";
import assert from "node:assert/strict";
import {
  deadlineLabel,
  hasDeadline,
  isDurationQuery,
  isWallClock,
  powerLabel,
  shortLeft,
} from "../src/format.ts";

test("shortLeft matches Durations.short", () => {
  assert.equal(shortLeft(4800), "1h20");
  assert.equal(shortLeft(2520), "42m");
  assert.equal(shortLeft(3600), "1h00");
  assert.equal(shortLeft(59), "0m");
  assert.equal(shortLeft(-10), "0m", "a deadline that has passed must not go negative");
});

/**
 * The three spellings of "no deadline" — `until: 0` on the aggregate, `left: -1`
 * on a claim, `left_short: "∞"`. Epoch 0 formats perfectly well as a time, so a
 * caller that checks only `left` renders "until 01:00" for an open-ended claim.
 */
test("no deadline is recognised from until, not from left", () => {
  assert.equal(hasDeadline(0), false);
  assert.equal(deadlineLabel(0, 1787666163), "no deadline");
  assert.ok(deadlineLabel(1787670000, 1787666163).startsWith("until "));
});

test("the countdown is computed from the passed-in now", () => {
  const now = 1787666163;
  assert.match(deadlineLabel(now + 2520, now), /· 42m left$/);
});

test("duration queries accept what simmer's own parser accepts", () => {
  for (const good of ["45m", "2h", "90", "1h30", "45min", "30s", "+15m", "23:00", "9:05", "1d12h"]) {
    assert.ok(isDurationQuery(good), good);
  }
  for (const bad of ["forever", "plan review", "", "h", "later", "23:0"]) {
    assert.ok(!isDurationQuery(bad), bad);
  }
});

test("only a wall clock routes to --until", () => {
  assert.ok(isWallClock("23:00"));
  assert.ok(isWallClock("9:05"));
  assert.ok(!isWallClock("2h"));
  assert.ok(!isWallClock("forever"));
});

test("an unreadable battery is a question mark, not a zero", () => {
  assert.equal(powerLabel(87, 1), "87% batt");
  assert.equal(powerLabel(100, 0), "100% AC");
  assert.equal(powerLabel(null, 0), "?% AC");
});
