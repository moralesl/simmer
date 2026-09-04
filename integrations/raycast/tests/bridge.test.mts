/**
 * The extension's half of the contract, checked against the BUILT binary — the
 * same idea as `Tests/SimmerAcceptanceTests`, from the other side of the pipe.
 * A renamed field or a changed exit code shows up here as a failing assertion
 * rather than as an empty list in Raycast.
 *
 * Hermetic through simmer's own seam: `XDG_STATE_HOME` in a temp dir, every
 * power read faked, `SIMMER_NOTIFY=none`. Nothing here touches the real ledger
 * or the real switch. Honours `SIMMER_BIN`, like the Swift suite does.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyArgs, capArgs, claimArgs, extendArgs, releaseArgs, statusArgs, updateArgs } from "../src/args.ts";
import { applyUpdate, checkUpdate, resolveBinary, run, runText, SimmerRefusal } from "../src/simmer.ts";
import type { SimmerMutation, SimmerStatus } from "../src/simmer.ts";

const bin = resolveBinary();
const root = mkdtempSync(join(tmpdir(), "simmer-raycast-"));
const pmset = join(root, "pmset");
writeFileSync(pmset, "0");

/**
 * `Harness.run`'s environment, spelled the same way. A fresh state directory per
 * call, so one test's claim cannot be the reason the next one passes — a test
 * that reuses the ledger passes for the wrong reason and fails when reordered.
 * Tests that need two calls to share state capture one `seam()` and reuse it.
 */
function seam(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: root,
    TZ: "Europe/Berlin",
    XDG_STATE_HOME: mkdtempSync(join(root, "state-")),
    SIMMER_FAKE_PMSET: pmset,
    SIMMER_FAKE_BATTERY: "80:0",
    SIMMER_FAKE_THERMAL: "0",
    SIMMER_FAKE_LOCKDELAY: "0",
    // The clock, pinned — the Swift harness has always done this and this
    // suite never did, so its results depended on the time of day CI ran.
    // A `cap 22:00` test passed for months and failed at 22:22, because a
    // wall-clock ceiling that has already gone rolls to tomorrow and is
    // refused. 2027-01-15 09:00 Europe/Berlin, the same fixed point
    // `Sim.epoch` uses, so the two suites cannot disagree about "now".
    SIMMER_FAKE_NOW: "1800000000",
    SIMMER_NOTIFY: "none",
    ...extra,
  };
}

// A machine without simmer is a supported state for the extension, not for this
// suite: skipping is honest, inventing a fixture would not be.
const skip = bin === null ? "simmer is not installed on this machine" : false;

test("status --json carries every field the view reads", { skip }, async () => {
  const status = await run<SimmerStatus>(bin!, statusArgs(), seam());
  for (const key of [
    "state",
    "until",
    "left",
    "left_short",
    "reason",
    "min_battery",
    "battery",
    "on_battery",
    "sleep_disabled",
    "since",
    "owner",
    "claim_count",
    "cap",
    "capped",
    "claims",
    "version",
  ]) {
    assert.ok(key in status, `status --json is missing ${key}`);
  }
  assert.equal(status.state, "idle", "a fresh state dir holds nothing");
  assert.ok(Array.isArray(status.claims));
  // 0/1 integers, not booleans — the documented exception in CONTRACTS.md that
  // a `!status.on_battery` check would get wrong the day it became a boolean.
  assert.equal(typeof status.on_battery, "number");
  assert.equal(typeof status.capped, "boolean");
});

test("a claim appears as this surface's own, with the reason", { skip }, async () => {
  const env = seam();
  const claimed = await run<SimmerMutation>(bin!, claimArgs("45m", "plan review"), env);
  assert.equal(claimed.action, "claimed");
  assert.equal(claimed.claim?.owner, "raycast");
  assert.equal(claimed.claim?.reason, "plan review");
  assert.equal(claimed.claim?.human, true, "raycast must carry human authority");

  const status = await run<SimmerStatus>(bin!, statusArgs(), env);
  assert.equal(status.state, "active");
  assert.equal(status.claim_count, 1);
  assert.equal(status.claims[0].owner, "raycast");
});

test("extend moves the deadline forward, never backward", { skip }, async () => {
  const env = seam();
  const claimed = await run<SimmerMutation>(bin!, claimArgs("2h"), env);
  const before = claimed.claim!.until;

  const extended = await run<SimmerMutation>(bin!, extendArgs("15m"), env);
  assert.equal(extended.action, "extended");
  assert.ok(
    extended.claim!.until > before,
    `extend must add to the deadline: ${before} -> ${extended.claim!.until}`,
  );
  assert.equal(
    extended.claim!.until - before,
    900,
    "extend adds to the existing deadline, it does not restart from now",
  );
});

test("a ceiling clips a claim without refusing it", { skip }, async () => {
  const env = seam();
  // A wall-clock ceiling, which only works because the seam pins the clock:
  // `cap 22:00` is refused once 22:00 has gone, since rolling to tomorrow
  // makes it twenty-three hours out — the inverse of what a cap is for. This
  // passed for months and failed at 22:22.
  await run<SimmerMutation>(bin!, capArgs("22:00"), env);
  const status = await run<SimmerStatus>(bin!, statusArgs(), env);
  assert.ok(status.cap > 0, "the ceiling is reported as an epoch");
});

test("a refusal arrives as simmer's own sentence", { skip }, async () => {
  // Below the battery floor: the claim cannot be granted, and the reason is a
  // sentence simmer writes. The extension shows it verbatim.
  const env = seam({ SIMMER_FAKE_BATTERY: "5:1" });
  await assert.rejects(
    () => run<SimmerMutation>(bin!, claimArgs("2h"), env),
    (error: unknown) => {
      assert.ok(error instanceof SimmerRefusal, `expected a refusal, got ${error}`);
      assert.ok(error.message.length > 0, "a refusal must carry simmer's reason");
      return true;
    },
  );
});

test("releasing what was never held is not an error", { skip }, async () => {
  const released = await run<SimmerMutation>(bin!, releaseArgs(), seam());
  assert.equal(released.action, "released");
  assert.deepEqual(released.released, [], "an empty array, never a prose sentence");
});

test("the orphan state the view exists to surface is reported as one", { skip }, async () => {
  // The switch is on and nothing claims it. Faked through SIMMER_FAKE_PMSET
  // rather than `sudo pmset -a disablesleep 1`, so this test can run anywhere
  // and leaves the real machine alone.
  const orphaned = join(root, "pmset-on");
  writeFileSync(orphaned, "1");
  const status = await run<SimmerStatus>(
    bin!,
    statusArgs(),
    seam({ SIMMER_FAKE_PMSET: orphaned }),
  );
  assert.equal(status.state, "orphan");
  assert.equal(status.claim_count, 0, "an orphan is precisely a switch with no claim behind it");
});

test("discovery prefers the configured path, then SIMMER_BIN", { skip }, () => {
  // The order matters on a machine where ~/.local/bin never made it onto PATH,
  // which is the normal case inside a launcher.
  assert.equal(resolveBinary(bin!, {}), bin, "an explicit preference wins");
  assert.equal(resolveBinary(undefined, { SIMMER_BIN: bin! }), bin, "SIMMER_BIN is next");
  assert.equal(
    resolveBinary("/nowhere/simmer", { SIMMER_BIN: bin! }),
    bin,
    "an unusable preference falls through rather than failing",
  );
});

/**
 * The hardcoded install locations, exercised against a FIXTURE home rather than
 * the machine's.
 *
 * The obvious version of this test — assert that dropping SIMMER_BIN still
 * resolves the same binary — passes only where simmer happens to be installed,
 * and asserts the filesystem rather than the function. On CI the binary comes
 * from SIMMER_BIN and none of the usual places exist, so it returned null.
 *
 * `os.homedir()` honours $HOME on POSIX, which is the seam that makes the real
 * property checkable anywhere: `~/.local/bin/simmer` is consulted even with an
 * empty environment. No built binary needed, so this runs on the lint leg too.
 */
test("the usual install locations are consulted, with no PATH and no SIMMER_BIN", () => {
  const fakeHome = mkdtempSync(join(tmpdir(), "simmer-home-"));
  const installed = join(fakeHome, ".local/bin/simmer");
  mkdirSync(join(fakeHome, ".local/bin"), { recursive: true });
  writeFileSync(installed, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

  const realHome = process.env.HOME;
  try {
    process.env.HOME = fakeHome;
    assert.equal(
      resolveBinary(undefined, {}),
      installed,
      "~/.local/bin/simmer is the symlink make install writes",
    );
    assert.equal(
      resolveBinary("/nowhere/simmer", {}),
      installed,
      "an unusable preference falls through to the usual places",
    );
  } finally {
    if (realHome === undefined) delete process.env.HOME;
    else process.env.HOME = realHome;
  }
});

/**
 * The root-search subtitle. Its wording is presentation and may be reworded at
 * any time, so this asserts only what the row has to be able to say: one line,
 * non-empty, and visibly different in the three states a glance has to
 * distinguish. A test that pinned the sentence would fail on a reword that
 * CONTRACTS.md explicitly allows.
 */
test("render raycast gives one line per state, and they differ", { skip }, async () => {
  const idle = await runText(bin!, ["render", "raycast"], seam());

  const held = seam();
  await run<SimmerMutation>(bin!, claimArgs("45m", "plan review"), held);
  const active = await runText(bin!, ["render", "raycast"], held);

  const onWithNoClaim = join(root, "pmset-orphan");
  writeFileSync(onWithNoClaim, "1");
  const orphan = await runText(bin!, ["render", "raycast"], seam({ SIMMER_FAKE_PMSET: onWithNoClaim }));

  for (const [name, line] of [
    ["idle", idle],
    ["active", active],
    ["orphan", orphan],
  ] as const) {
    assert.ok(line.length > 0, `${name} must say something`);
    assert.ok(!line.includes("\n"), `${name} must be ONE line — it is a subtitle`);
  }
  assert.notEqual(idle, active, "a held Mac must not look like a free one");
  assert.notEqual(idle, orphan, "an orphan must not look like a free one");
});

/**
 * `simmer update` is the one command whose non-zero exit is an answer rather
 * than a refusal, so `checkUpdate` must return the body instead of throwing it
 * away. Both halves are asserted here: the answer, and the not-knowing.
 */
test("update --json carries every field the views read", { skip }, async () => {
  const update = await checkUpdate(bin!, false, seam({ SIMMER_FAKE_LATEST: "v9.9.9" }));

  for (const key of [
    "action",
    "verdict",
    "installed",
    "latest",
    "update_available",
    "provenance",
    "update_command",
    "app_version",
    "app_drift",
    "checked_at",
    "cached",
    "error",
    "seamed",
  ] as const) {
    assert.ok(key in update, `update --json lost ${key}`);
  }
  assert.equal(update.verdict, "available");
  assert.equal(update.update_available, true);
  assert.equal(update.latest, "v9.9.9");
  assert.ok(update.update_command.length > 0, "an available update must name its command");
});

test("a check that could not be made is an answer, not a thrown refusal", { skip }, async () => {
  const update = await checkUpdate(bin!, false, seam({ SIMMER_FAKE_LATEST: "error" }));

  assert.equal(update.verdict, "unknown");
  assert.equal(update.update_available, false);
  assert.equal(update.latest, null);
  assert.ok(update.error, "not knowing has to say why");
});

/**
 * The claims view reads the record, never the network — otherwise opening a
 * launcher list would wait on GitHub. The source is primed here with an answer
 * `--cached` is not allowed to look at.
 */
test("the cached read consults no source at all", { skip }, async () => {
  const env = seam({ SIMMER_FAKE_LATEST: "v9.9.9" });
  const cold = await checkUpdate(bin!, true, env);
  assert.equal(cold.verdict, "unknown", "a cached read invented an answer");
  assert.equal(cold.cached, true);

  // Once something has been recorded, the same call answers from it.
  await checkUpdate(bin!, false, env);
  const warm = await checkUpdate(bin!, true, env);
  assert.equal(warm.latest, "v9.9.9");
  assert.equal(warm.cached, true);
});

test("updateArgs asks for JSON, and cached by default", () => {
  assert.deepEqual(updateArgs(), ["update", "--cached", "--json"]);
  assert.deepEqual(updateArgs(false), ["update", "--json"]);
  // Read-only: nothing is claimed, so nothing is owned.
  assert.ok(!updateArgs().includes("--owner"));
});

test("applyArgs asks for JSON and never for a cached answer", () => {
  assert.deepEqual(applyArgs(), ["update", "--apply", "--json"]);
  // simmer refuses --apply with --cached rather than resolving it, so this
  // builder must never be able to produce the pair.
  assert.ok(!applyArgs().includes("--cached"));
});

/**
 * The install action, against the real binary with every step recorded rather
 * than run. Asserts the two things the extension depends on: that a plan comes
 * back as a result rather than a thrown refusal, and that nothing executed is a
 * script piped from the internet.
 */
test("applyUpdate returns the plan it ran", { skip }, async () => {
  const home = mkdtempSync(join(root, "apply-home-"));
  mkdirSync(join(home, ".local/share/simmer/.git"), { recursive: true });
  writeFileSync(join(home, ".local/share/simmer/Makefile"), "all:\n");
  const log = join(home, "apply.log");
  writeFileSync(log, "");

  const done = await applyUpdate(
    bin!,
    seam({
      HOME: home,
      SIMMER_FAKE_LATEST: "v9.9.9",
      SIMMER_FAKE_APPLY: log,
      SIMMER_BIN: join(home, "Applications/Simmer.app/Contents/MacOS/simmer"),
    }),
  );

  assert.equal(done.action, "updated");
  assert.equal(done.applied, true);
  assert.equal(done.steps?.length, 3);

  const ran = readFileSync(log, "utf8");
  assert.ok(!ran.includes("curl"), ran);
  assert.ok(!ran.includes("bash"), ran);
  assert.match(ran, /checkout --quiet v9\.9\.9/);
});

test("a refusal to install arrives as simmer's own sentence", { skip }, async () => {
  // No SIMMER_BIN, so the binary places itself in its own checkout — which
  // simmer refuses to move onto a tag.
  await assert.rejects(
    () => applyUpdate(bin!, seam({ SIMMER_FAKE_LATEST: "v9.9.9" })),
    (error: unknown) =>
      error instanceof SimmerRefusal && /checkout/.test((error as Error).message),
  );
});
