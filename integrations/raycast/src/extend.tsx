import { LaunchProps, showHUD } from "@raycast/api";
import { extendArgs } from "./args.ts";
import { grantedMessage, run, SimmerMutation } from "./simmer.ts";
import { binary } from "./preference.ts";
import { report } from "./report.ts";

interface Arguments {
  duration?: string;
}

export default async function Command(
  props: LaunchProps<{ arguments: Arguments }>,
) {
  const requested = props.arguments.duration?.trim();
  await report(async () => {
    const mutation = await run<SimmerMutation>(
      binary(),
      extendArgs(requested || "15m"),
    );
    await showHUD(`☕ Simmering ${grantedMessage(mutation)}`);
  });
}
