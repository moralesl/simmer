import {
  LaunchType,
  environment,
  launchCommand,
  updateCommandMetadata,
} from "@raycast/api";
import { runText } from "./simmer.ts";
import { binary } from "./preference.ts";

/**
 * The countdown in the root search itself — the thing a launcher is actually
 * for, and the one part of the old `simmer-status.sh` inline script command
 * worth keeping. `interval` in the manifest wakes this every minute;
 * `updateCommandMetadata` writes the line under the command's title, so typing
 * "simmer" shows the state without opening anything.
 *
 * The line comes from `simmer render raycast`, the one-line surface the core
 * already draws. Deliberately not rebuilt from `status --json` here: the menu
 * bar, this row and any third-party script command should read the same, and
 * that is only true if one place decides the wording.
 *
 * Background refresh is best-effort — Raycast may skip a tick on a busy or
 * sleeping machine — so this is a glance, not a clock. It says "42m left", never
 * a ticking second count, for exactly that reason.
 */
export default async function Command() {
  let subtitle: string;
  try {
    subtitle = await runText(binary(), ["render", "raycast"]);
  } catch {
    // A missing or refusing binary must not leave a stale countdown in the root
    // search claiming the Mac is held awake when nothing holds it.
    subtitle = "simmer is not available";
  }
  await updateCommandMetadata({ subtitle });

  // Pressing return on the row opens the list; a no-view command that did
  // nothing visible would read as broken.
  if (environment.launchType !== LaunchType.Background) {
    await launchCommand({ name: "claims", type: LaunchType.UserInitiated });
  }
}
