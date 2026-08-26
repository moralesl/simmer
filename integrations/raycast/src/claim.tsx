import { LaunchProps, showHUD } from "@raycast/api";
import { claimArgs } from "./args.ts";
import { grantedMessage, run, SimmerMutation } from "./simmer.ts";
import { binary } from "./preference.ts";
import { report } from "./report.ts";

interface Arguments {
  duration: string;
  reason: string;
}

export default async function Command(
  props: LaunchProps<{ arguments: Arguments }>,
) {
  const { duration, reason } = props.arguments;
  await report(async () => {
    const mutation = await run<SimmerMutation>(
      binary(),
      claimArgs(duration, reason),
    );
    await showHUD(`☕ Simmering ${grantedMessage(mutation)}`);
  });
}
