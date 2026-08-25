/**
 * Pure formatting. No Raycast API, no child processes, no clock of its own —
 * every function takes what it needs, so `tests/format.test.ts` can pin it.
 *
 * Where a rule already exists in SimmerCore, it is ported rather than invented,
 * and the Swift original is named. Two surfaces that format the same field
 * differently is the drift this comment exists to prevent.
 */

/** `Durations.short` — "1h20" · "42m". Used for every countdown. */
export function shortLeft(seconds: number): string {
  const s = Math.max(seconds, 0);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}h${String(m).padStart(2, "0")}` : `${m}m`;
}

/** `Formats.hhmm` — the local wall clock of an epoch, "17:00". */
export function hhmm(epoch: number): string {
  return new Date(epoch * 1000).toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/**
 * The three spellings of "no deadline" all land here: `until === 0` on the
 * aggregate, `left === -1` on a claim, and `left_short === "∞"`. A caller that
 * checks only one of them shows "until 01:00" for an open-ended claim, because
 * epoch 0 formats perfectly well.
 */
export function hasDeadline(until: number): boolean {
  return until > 0;
}

/** "until 17:00 · 42m left" · "no deadline". `now` is passed in, never read. */
export function deadlineLabel(until: number, now: number): string {
  if (!hasDeadline(until)) return "no deadline";
  return `until ${hhmm(until)} · ${shortLeft(until - now)} left`;
}

/**
 * Does typed search text look like a duration or a wall-clock time?
 *
 * Ported verbatim from `RenderCommand.renderAlfred` so both launcher surfaces
 * accept exactly the same things — including the deliberately loose tail
 * (`[a-z0-9]*`), which is what lets `1h30`, `45min` and `2h15` through to
 * simmer's own parser rather than second-guessing it here.
 */
const DURATION_QUERY = /^\+?[0-9]+[hms]?[a-z0-9]*$/;
const WALL_CLOCK_QUERY = /^[0-9]{1,2}:[0-9]{2}$/;

export function isDurationQuery(query: string): boolean {
  const q = query.trim();
  return DURATION_QUERY.test(q) || WALL_CLOCK_QUERY.test(q);
}

/** A wall-clock argument needs `--until`; everything else is a duration. */
export function isWallClock(value: string): boolean {
  return WALL_CLOCK_QUERY.test(value.trim());
}

/** "87% AC" · "87% batt" · "?% AC" — `battery` is null when it cannot be read. */
export function powerLabel(battery: number | null, onBattery: number): string {
  const percent = battery === null ? "?" : String(battery);
  return `${percent}% ${onBattery === 1 ? "batt" : "AC"}`;
}
