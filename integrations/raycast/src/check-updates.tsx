import { Action, ActionPanel, Detail, Icon, open } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { useMemo } from "react";
import { preferredPath } from "./preference.ts";
import { checkUpdate, resolveBinary, SimmerUpdate } from "./simmer.ts";

const REPO = "https://github.com/moralesl/simmer";

/**
 * The one command in this extension that deliberately asks GitHub something.
 *
 * Everything else — the claims view's row, the menu bar, `simmer doctor` —
 * reads the record the app keeps warm, so this is the only place a person
 * waits. It reports and hands over the command; it never installs anything,
 * because an update replaces a running app and the binary the guard's
 * LaunchAgent points at, and it can be asked for while a claim is live.
 */
export default function Command() {
  const bin = useMemo(() => resolveBinary(preferredPath()), []);
  const { data, isLoading, error, revalidate } = usePromise(
    async (path: string | null) => {
      if (!path) return null;
      return checkUpdate(path, false);
    },
    [bin],
  );

  const markdown = () => {
    if (!bin) return "# simmer is not installed\n\nOr it is somewhere this extension cannot see. Raycast runs with a minimal PATH — set the binary path in the extension preferences.";
    if (error) return `# Could not check\n\n${error.message}`;
    if (isLoading || !data) return "Asking github.com which release is newest…";
    return body(data);
  };

  return (
    <Detail
      isLoading={isLoading}
      markdown={markdown()}
      metadata={
        data ? (
          <Detail.Metadata>
            <Detail.Metadata.Label title="Installed" text={data.installed} />
            <Detail.Metadata.Label
              title="Newest release"
              text={data.latest ?? "unknown"}
            />
            <Detail.Metadata.Label title="Installed by" text={data.provenance} />
            {data.app_version !== null && (
              <Detail.Metadata.Label title="Simmer.app" text={data.app_version} />
            )}
          </Detail.Metadata>
        ) : undefined
      }
      actions={
        <ActionPanel>
          {data && (data.update_available || data.app_drift) && (
            <Action.CopyToClipboard
              title="Copy the Update Command"
              icon={Icon.Clipboard}
              content={data.update_command}
            />
          )}
          <Action
            title="Check Again"
            icon={Icon.ArrowClockwise}
            onAction={revalidate}
          />
          <Action
            title="Open the Releases Page"
            icon={Icon.Globe}
            onAction={() => open(`${REPO}/releases`)}
          />
        </ActionPanel>
      }
    />
  );
}

/**
 * simmer's own verdict, rendered. The wording is this extension's — the CLI's
 * sentences are for a terminal — but every fact in it is a field, so the two
 * cannot disagree about what is true.
 */
function body(update: SimmerUpdate): string {
  const drift = update.app_drift
    ? `\n\n> **Simmer.app is ${update.app_version}, but the CLI is ${update.installed}.**\n> The bundle was not replaced — half an install. Fix it with the command above.`
    : "";
  switch (update.verdict) {
    case "available":
      return `# simmer ${update.latest} is out\n\nYou have ${update.installed}, ${describe(update)}.\n\n\`\`\`\n${update.update_command}\n\`\`\`\n\nsimmer never installs it for you — copy the command and run it when it suits.${drift}`;
    case "current":
      return `# Up to date\n\nsimmer ${update.installed} is the newest release, ${describe(update)}.${drift}`;
    case "ahead":
      return `# Ahead of the newest release\n\nsimmer ${update.installed} is newer than ${update.latest}, the newest published release. Nothing to do.${drift}`;
    case "unknown":
      return `# Could not tell\n\n${update.error ?? "no reason given"}\n\nYou have simmer ${update.installed}.`;
  }
}

function describe(update: SimmerUpdate): string {
  switch (update.provenance) {
    case "homebrew":
      return "installed by Homebrew";
    case "bundle":
      return "installed as Simmer.app";
    case "checkout":
      return "running from a source checkout";
    case "unknown":
      return "installed outside the usual places";
  }
}
