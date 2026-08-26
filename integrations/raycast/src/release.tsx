import { showHUD } from "@raycast/api";
import { hhmm } from "./format.ts";
import { releaseArgs } from "./args.ts";
import { run, SimmerMutation } from "./simmer.ts";
import { binary } from "./preference.ts";
import { report } from "./report.ts";

export default async function Command() {
  await report(async () => {
    const mutation = await run<SimmerMutation>(binary(), releaseArgs());
    // `released` is [] when this surface held nothing — a fact worth showing,
    // because "Simmer Down" doing nothing visible otherwise reads as a failure.
    const released = mutation.released ?? [];
    if (released.length === 0) {
      await showHUD("⏾ Raycast was not holding anything awake");
      return;
    }
    const others = mutation.claim_count ?? 0;
    const head =
      others > 0
        ? `⏾ Released — ${others} other ${others === 1 ? "claim" : "claims"} still holding`
        : "⏾ Released — sleep allowed again";
    // A release ends claims and never the ceiling. This surface builds its own
    // sentence from JSON instead of echoing simmer's, so the note it would
    // otherwise have inherited has to be said here as well.
    const cap = mutation.cap ?? 0;
    const tail = cap > 0 ? ` · ⛔ ${hhmm(cap)} ceiling stays` : "";
    await showHUD(`${head}${tail}`);
  });
}
