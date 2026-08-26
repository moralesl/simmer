/**
 * Every argv this extension can build, in one pure file, so the rules below are
 * tests rather than review comments.
 *
 * Two of them are load-bearing:
 *
 *   1. "More time" builds `extend`, never `claim`. A bare duration *sets* the
 *      deadline from now, so `claim 15m` on a claim with 40 minutes left would
 *      cost the caller 25 minutes it already held. AGENTS.md states it as a rule
 *      for every surface; `tests/args.test.ts` is where it is enforced.
 *   2. Every invocation carries `--json`. simmer refuses `--json` on the verbs
 *      that cannot honour it rather than ignoring it, so a missing flag here
 *      would mean parsing human prose that is free to be reworded.
 */

/**
 * `raycast` is a human owner name in `SimmerEnvironment.isHumanOwnerName`, which
 * is what grants this surface human authority (`release --all`, moving the cap)
 * and the 🚀 glyph. It must never be spelled anything else, and an agent must
 * never borrow it — see AGENTS.md.
 */
export const OWNER = "raycast";

const JSON_FLAG = "--json";
const OWNED = ["--owner", OWNER];

/** Read-only: no owner, because nothing is being claimed. */
export function statusArgs(): string[] {
  return ["status", JSON_FLAG];
}

/**
 * `23:00` routes to `--until`; anything else is a duration or `forever`.
 * The same branch the removed `simmer-for.sh` carried.
 */
export function claimArgs(duration: string, reason?: string): string[] {
  const value = duration.trim();
  const args = value.includes(":")
    ? ["claim", "--until", value]
    : ["claim", value];
  const why = reason?.trim();
  if (why) args.push("-r", why);
  return [...args, ...OWNED, JSON_FLAG];
}

/** Adds to your own deadline. Never `claim` — see rule 1 above. */
export function extendArgs(duration: string): string[] {
  const value = duration.trim().replace(/^\+/, "");
  return ["extend", `+${value}`, ...OWNED, JSON_FLAG];
}

/** `all` is humans only, and `raycast` is a human — but it ends everyone's
 * claim, so the caller puts it behind a confirmation. */
export function releaseArgs(all = false): string[] {
  return all
    ? ["release", "--all", ...OWNED, JSON_FLAG]
    : ["release", ...OWNED, JSON_FLAG];
}

/** A wall-clock ceiling, or `off` to lift it. */
export function capArgs(value: string): string[] {
  return ["cap", value.trim(), ...OWNED, JSON_FLAG];
}

/** Bare report, so the view can show who set the ceiling. */
export function capReportArgs(): string[] {
  return ["cap", JSON_FLAG];
}
