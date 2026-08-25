import { showHUD } from "@raycast/api";
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
    await showHUD(
      others > 0
        ? `⏾ Released — ${others} other ${others === 1 ? "claim" : "claims"} still holding`
        : "⏾ Released — sleep allowed again",
    );
  });
}
