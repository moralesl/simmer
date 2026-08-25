import { test } from "node:test";
import assert from "node:assert/strict";
import { capArgs, claimArgs, extendArgs, OWNER, releaseArgs, statusArgs } from "../src/args.ts";

/**
 * The rule this file exists for. AGENTS.md: "no surface may cost a caller awake
 * time it already holds" — a bare duration SETS the deadline from now, so a
 * "+15m" button that built `claim 15m` would silently shorten a claim with 40
 * minutes left. It is the mistake a GUI is most likely to make, so it is a test.
 */
test("more time extends, and can never claim", () => {
  for (const input of ["15m", "+15m", " 30m ", "1h"]) {
    const args = extendArgs(input);
    assert.equal(args[0], "extend", `${input} must extend`);
    assert.ok(!args.includes("claim"), `${input} must not claim`);
  }
});

test("extend normalises the leading plus rather than doubling it", () => {
  assert.deepEqual(extendArgs("15m"), ["extend", "+15m", "--owner", OWNER, "--json"]);
  assert.deepEqual(extendArgs("+15m"), ["extend", "+15m", "--owner", OWNER, "--json"]);
});

test("a wall clock claims with --until, a duration claims bare", () => {
  assert.deepEqual(claimArgs("23:00"), ["claim", "--until", "23:00", "--owner", OWNER, "--json"]);
  assert.deepEqual(claimArgs("2h"), ["claim", "2h", "--owner", OWNER, "--json"]);
  assert.deepEqual(claimArgs("forever"), ["claim", "forever", "--owner", OWNER, "--json"]);
});

test("a reason is passed through, and an empty one is not passed at all", () => {
  assert.deepEqual(claimArgs("2h", "plan review"), [
    "claim",
    "2h",
    "-r",
    "plan review",
    "--owner",
    OWNER,
    "--json",
  ]);
  assert.ok(!claimArgs("2h", "   ").includes("-r"));
  assert.ok(!claimArgs("2h", undefined).includes("-r"));
});

test("release is mine by default and everyone only when asked", () => {
  assert.deepEqual(releaseArgs(), ["release", "--owner", OWNER, "--json"]);
  assert.ok(releaseArgs(true).includes("--all"));
  assert.ok(!releaseArgs().includes("--all"));
});

test("the cap can be set and lifted", () => {
  assert.deepEqual(capArgs("23:00"), ["cap", "23:00", "--owner", OWNER, "--json"]);
  assert.deepEqual(capArgs("off"), ["cap", "off", "--owner", OWNER, "--json"]);
});

/**
 * simmer refuses `--json` on the verbs that cannot honour it rather than
 * ignoring it, so a builder that forgot the flag would leave the caller parsing
 * human prose — which CONTRACTS.md reserves the right to reword at any time.
 */
test("every builder asks for JSON", () => {
  for (const args of [
    statusArgs(),
    claimArgs("2h"),
    extendArgs("15m"),
    releaseArgs(),
    releaseArgs(true),
    capArgs("23:00"),
  ]) {
    assert.ok(args.includes("--json"), args.join(" "));
  }
});

/** Every mutating builder names this surface. An unnamed claim would default to
 * `terminal` and become indistinguishable from something typed by hand. */
test("every mutation is owned by raycast, and status is not", () => {
  for (const args of [claimArgs("2h"), extendArgs("15m"), releaseArgs(), capArgs("23:00")]) {
    assert.deepEqual(
      args.slice(args.indexOf("--owner"), args.indexOf("--owner") + 2),
      ["--owner", "raycast"],
      args.join(" "),
    );
  }
  assert.ok(!statusArgs().includes("--owner"));
});
