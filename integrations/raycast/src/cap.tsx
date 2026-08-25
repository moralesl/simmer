import { LaunchProps, showHUD } from "@raycast/api";
import { capArgs } from "./args.ts";
import { run, SimmerMutation } from "./simmer.ts";
import { binary } from "./preference.ts";
import { report } from "./report.ts";
import { hhmm } from "./format.ts";

interface Arguments {
  until: string;
}

export default async function Command(
  props: LaunchProps<{ arguments: Arguments }>,
) {
  const value = props.arguments.until;
  await report(async () => {
    const mutation = await run<SimmerMutation>(binary(), capArgs(value));
    if (mutation.action === "cap_lifted") {
      await showHUD("🖐 Ceiling lifted");
      return;
    }
    const cap = mutation.cap ?? 0;
    const clipped = typeof mutation.clipped === "number" ? mutation.clipped : 0;
    const tail =
      clipped > 0
        ? ` — ${clipped} ${clipped === 1 ? "claim" : "claims"} shortened`
        : "";
    await showHUD(`🖐 Nothing past ${cap > 0 ? hhmm(cap) : value}${tail}`);
  });
}
