import { open, showHUD, Toast, showToast } from "@raycast/api";
import { SimmerNotFound, SimmerRefusal } from "./simmer.ts";

const REPO = "https://github.com/moralesl/simmer";

/**
 * One place where every no-view command's failures are shown, so a refusal
 * always reads the same and simmer's own sentence is never paraphrased.
 *
 * A missing binary is not an error state: the same graceful exit the removed
 * shell shims had, because a launcher that throws a red screen on a machine
 * that simply does not have the tool is worse than one that says so.
 */
export async function report(work: () => Promise<void>): Promise<void> {
  try {
    await work();
  } catch (error) {
    if (error instanceof SimmerNotFound) {
      await showToast({
        style: Toast.Style.Failure,
        title: "simmer is not installed",
        message:
          "Set the binary path in the extension preferences, or install it",
        primaryAction: {
          title: "Open the repository",
          onAction: () => {
            open(REPO);
          },
        },
      });
      return;
    }
    if (error instanceof SimmerRefusal) {
      // simmer's own words. It refused for a reason it can state better than
      // this extension can guess — a battery floor, a passed ceiling, a claim
      // that would cross it.
      await showHUD(`🚫 ${error.message}`);
      return;
    }
    throw error;
  }
}
