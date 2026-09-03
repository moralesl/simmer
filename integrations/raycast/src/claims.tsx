import {
  Action,
  ActionPanel,
  Alert,
  Color,
  Icon,
  Keyboard,
  LaunchType,
  List,
  Toast,
  confirmAlert,
  launchCommand,
  open,
  showToast,
  Clipboard,
} from "@raycast/api";
import { useExec, usePromise } from "@raycast/utils";
import { preferredPath } from "./preference.ts";
import { useEffect, useMemo, useState } from "react";
import { watch } from "node:fs";
import { join } from "node:path";
import {
  capArgs,
  claimArgs,
  extendArgs,
  releaseArgs,
  statusArgs,
} from "./args.ts";
import {
  deadlineLabel,
  hhmm,
  isDurationQuery,
  isWallClock,
  powerLabel,
  shortLeft,
} from "./format.ts";
import {
  SimmerClaim,
  SimmerMutation,
  SimmerStatus,
  checkUpdate,
  grantedMessage,
  resolveBinary,
  run,
  stateDir,
} from "./simmer.ts";

const REPO = "https://github.com/moralesl/simmer";

/** `Owners.glyph` — one table, so a claim wears the same face here as in the menu bar. */
function ownerGlyph(owner: string): string {
  if (owner === "run" || owner.startsWith("run:")) return "⚙️";
  if (owner.startsWith("agent:")) return "🤖";
  switch (owner) {
    case "menubar":
      return "🖥️";
    case "terminal":
      return "⌨️";
    case "raycast":
      return "🚀";
    case "script":
      return "📜";
    default:
      return "🤖";
  }
}

const PRESETS = ["30m", "1h", "2h", "4h"];

export default function Command() {
  const bin = useMemo(() => resolveBinary(preferredPath()), []);
  const [searchText, setSearchText] = useState("");

  const { data, isLoading, revalidate } = useExec(bin ?? "", statusArgs(), {
    execute: bin !== null,
    parseOutput: ({ stdout }) => JSON.parse(stdout) as SimmerStatus,
    keepPreviousData: true,
  });

  // The cached answer only — `--cached` makes no network request, so opening
  // this view never waits on GitHub. The app refreshes the record once a day
  // and the "Check for Updates" command is where someone asks for a fresh look.
  // A failed read is nothing to report here: no row, no toast.
  const { data: update } = usePromise(
    async (path: string | null) =>
      path ? checkUpdate(path, true).catch(() => null) : null,
    [bin],
  );

  // The countdown ticks locally. Re-running `status --json` every second would
  // spawn a process — and one `pmset` read inside it — per second, for a number
  // this side can compute from `until` on its own.
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const tick = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(tick);
  }, []);

  // The same two paths `LedgerWatcher` arms, with the same 150 ms debounce, so a
  // claim taken in the menu bar or by an agent shows up here without polling.
  useEffect(() => {
    if (!bin) return;
    const state = stateDir();
    let timer: NodeJS.Timeout | undefined;
    const bump = () => {
      if (timer) clearTimeout(timer);
      timer = setTimeout(revalidate, 150);
    };
    const watchers = [join(state, "claims"), join(state, "cap")].flatMap(
      (path) => {
        try {
          return [watch(path, bump)];
        } catch {
          // `cap` only exists once a ceiling has been set. Its absence is normal,
          // and the claims directory watch is what carries the common case.
          return [];
        }
      },
    );
    return () => {
      if (timer) clearTimeout(timer);
      watchers.forEach((w) => w.close());
    };
  }, [bin, revalidate]);

  if (!bin) {
    return (
      <List>
        <List.EmptyView
          icon={Icon.Plug}
          title="simmer is not installed"
          description="Or it is somewhere this extension cannot see. Raycast runs with a minimal PATH — set the binary path in the extension preferences."
          actions={
            <ActionPanel>
              <Action
                title="Open the Repository"
                icon={Icon.Globe}
                onAction={() => open(REPO)}
              />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  const perform = async (
    args: string[],
    describe: (m: SimmerMutation) => string,
  ) => {
    try {
      const mutation = await run<SimmerMutation>(bin, args);
      await showToast({
        style: Toast.Style.Success,
        title: describe(mutation),
      });
    } catch (error) {
      // simmer's own refusal sentence, not a paraphrase of it.
      await showToast({
        style: Toast.Style.Failure,
        title: "simmer refused",
        message: error instanceof Error ? error.message : String(error),
      });
    }
    revalidate();
  };

  const status = data;
  const mine = status?.claims.find((claim) => claim.owner === "raycast");
  const typed = searchText.trim();
  const typedIsDuration = isDurationQuery(typed);

  const claimAction = (duration: string, reason?: string) => (
    <Action
      title={`Simmer for ${duration}`}
      icon={Icon.Clock}
      onAction={() =>
        perform(
          claimArgs(duration, reason),
          (m) => `Simmering ${grantedMessage(m)}`,
        )
      }
    />
  );

  const sharedActions = (
    <>
      <Action
        title="Add 15 Minutes"
        icon={Icon.Plus}
        shortcut={{ modifiers: ["cmd"], key: "1" }}
        onAction={() =>
          perform(extendArgs("15m"), (m) => `Simmering ${grantedMessage(m)}`)
        }
      />
      <Action
        title="Add 30 Minutes"
        icon={Icon.Plus}
        shortcut={{ modifiers: ["cmd"], key: "2" }}
        onAction={() =>
          perform(extendArgs("30m"), (m) => `Simmering ${grantedMessage(m)}`)
        }
      />
      <Action
        title="Add an Hour"
        icon={Icon.Plus}
        shortcut={{ modifiers: ["cmd"], key: "3" }}
        onAction={() =>
          perform(extendArgs("1h"), (m) => `Simmering ${grantedMessage(m)}`)
        }
      />
      <Action
        title="Release Mine"
        icon={Icon.Moon}
        style={Action.Style.Destructive}
        shortcut={Keyboard.Shortcut.Common.Remove}
        onAction={() =>
          perform(releaseArgs(), (m) =>
            (m.released ?? []).length === 0
              ? "Raycast held nothing"
              : "Released",
          )
        }
      />
      <Action
        title="Release Everything"
        icon={Icon.XMarkCircle}
        style={Action.Style.Destructive}
        onAction={async () => {
          const ok = await confirmAlert({
            title: "Release every claim?",
            message:
              "This ends other people's and other agents' claims too, not only Raycast's. Whatever they were waiting for loses the lid.",
            primaryAction: {
              title: "Release everything",
              style: Alert.ActionStyle.Destructive,
            },
          });
          if (ok)
            await perform(
              releaseArgs(true),
              (m) => `Released ${(m.released ?? []).length}`,
            );
        }}
      />
    </>
  );

  const capActions = (
    <ActionPanel.Submenu title="Nothing Past…" icon={Icon.Stop}>
      {["22:00", "23:00", "00:00", "01:00"].map((time) => (
        <Action
          key={time}
          title={time}
          onAction={() => perform(capArgs(time), () => `Nothing past ${time}`)}
        />
      ))}
      <Action
        title="Lift the Ceiling"
        onAction={() => perform(capArgs("off"), () => "Ceiling lifted")}
      />
    </ActionPanel.Submenu>
  );

  const utilityActions = (
    <>
      {capActions}
      <Action
        title="Copy Status JSON"
        icon={Icon.Clipboard}
        onAction={async () => {
          await Clipboard.copy(JSON.stringify(status, null, 2));
          await showToast({ style: Toast.Style.Success, title: "Copied" });
        }}
      />
      <Action
        title="Refresh"
        icon={Icon.ArrowClockwise}
        onAction={revalidate}
      />
    </>
  );

  return (
    <List
      isLoading={isLoading}
      filtering
      onSearchTextChange={setSearchText}
      searchBarPlaceholder="45m · 2h · 23:00 — or search the claims"
    >
      {status?.state === "orphan" && (
        <List.Section title="Nothing is holding this open">
          <List.Item
            icon={{ source: Icon.Warning, tintColor: Color.Red }}
            title="Sleep is disabled with nothing claiming it"
            subtitle="An orphan: the lid will not sleep and no deadline will hand it back"
            actions={
              <ActionPanel>
                <Action
                  title="Release It"
                  icon={Icon.Moon}
                  onAction={() => perform(releaseArgs(true), () => "Released")}
                />
                {utilityActions}
              </ActionPanel>
            }
          />
        </List.Section>
      )}

      {update && (update.update_available || update.app_drift) && (
        <List.Section title="Update">
          <List.Item
            icon={{
              source: update.app_drift ? Icon.Warning : Icon.Download,
              tintColor: update.app_drift ? Color.Orange : Color.Blue,
            }}
            title={
              update.app_drift
                ? `Simmer.app is ${update.app_version} · the CLI is ${update.installed}`
                : `simmer ${update.latest} is out`
            }
            subtitle={
              update.app_drift
                ? "half an install — the bundle was not replaced"
                : `you have ${update.installed}`
            }
            accessories={[{ text: update.update_command }]}
            actions={
              <ActionPanel>
                {/* Copied, never run: an update replaces a running app and the
                    binary the guard points at, and a claim may be live. */}
                <Action.CopyToClipboard
                  title="Copy the Update Command"
                  content={update.update_command}
                />
                <Action
                  title="Check Again"
                  icon={Icon.ArrowClockwise}
                  onAction={() =>
                    launchCommand({
                      name: "check-updates",
                      type: LaunchType.UserInitiated,
                    })
                  }
                />
                {utilityActions}
              </ActionPanel>
            }
          />
        </List.Section>
      )}

      {status && status.state !== "idle" && status.state !== "orphan" && (
        <List.Section title="Awake">
          <List.Item
            icon="☕"
            title={
              status.until > 0
                ? `${shortLeft(status.until - now)} left · until ${hhmm(status.until)}`
                : "No deadline"
            }
            subtitle={status.reason || "no reason given"}
            accessories={[
              { text: powerLabel(status.battery, status.on_battery) },
              { text: `floor ${status.min_battery}%` },
            ]}
            actions={
              <ActionPanel>
                {sharedActions}
                {utilityActions}
              </ActionPanel>
            }
          />
          {status.sleep_disabled === 0 && (
            <List.Item
              icon={{ source: Icon.Warning, tintColor: Color.Orange }}
              title="The switch is not actually set"
              subtitle="Claims are held but disablesleep is off — the lid will still sleep. Run simmer doctor."
              actions={
                <ActionPanel>
                  <Action.CopyToClipboard
                    title="Copy the Doctor Command"
                    content="simmer doctor"
                  />
                  {utilityActions}
                </ActionPanel>
              }
            />
          )}
        </List.Section>
      )}

      {status && status.claims.length > 0 && (
        <List.Section
          title={`${status.claim_count} ${status.claim_count === 1 ? "claim" : "claims"}`}
        >
          {status.claims.map((claim: SimmerClaim) => (
            <List.Item
              key={claim.id}
              icon={ownerGlyph(claim.owner)}
              title={claim.owner}
              subtitle={claim.reason || undefined}
              accessories={[
                ...(claim.require_ac ? [{ tag: "AC only" }] : []),
                { text: deadlineLabel(claim.until, now) },
              ]}
              actions={
                <ActionPanel>
                  {claim.owner === "raycast" ? (
                    sharedActions
                  ) : (
                    <>
                      <Action.CopyToClipboard
                        title="Copy the Owner"
                        content={claim.owner}
                      />
                      {/* No per-claim release for someone else's claim: simmer
                          releases by owner, and `--all` is the only verb that
                          reaches another owner. Offering "release this one"
                          here would have to lie about what it does. */}
                    </>
                  )}
                  {utilityActions}
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      )}

      <List.Section title={mine ? "Change it" : "Hold it open"}>
        {typedIsDuration && (
          <List.Item
            icon={Icon.Clock}
            title={
              mine
                ? isWallClock(typed)
                  ? `Move your deadline to ${typed}`
                  : `Add ${typed.replace(/^\+/, "")} to your deadline`
                : `Simmer for ${typed}`
            }
            subtitle={
              mine && !isWallClock(typed)
                ? "counted from your current deadline"
                : undefined
            }
            actions={
              <ActionPanel>
                <Action
                  title="Do It"
                  icon={Icon.Clock}
                  onAction={() =>
                    // A typed duration on an existing claim EXTENDS. A bare
                    // duration would set the deadline from now and could take
                    // away time already held (AGENTS.md).
                    perform(
                      mine && !isWallClock(typed)
                        ? extendArgs(typed)
                        : claimArgs(typed, "Raycast"),
                      (m) => `Simmering ${grantedMessage(m)}`,
                    )
                  }
                />
                {utilityActions}
              </ActionPanel>
            }
          />
        )}
        {PRESETS.map((preset) => (
          <List.Item
            key={preset}
            icon={Icon.Clock}
            title={mine ? `Add ${preset}` : `Simmer for ${preset}`}
            actions={
              <ActionPanel>
                {mine ? (
                  <Action
                    title={`Add ${preset}`}
                    icon={Icon.Plus}
                    onAction={() =>
                      perform(
                        extendArgs(preset),
                        (m) => `Simmering ${grantedMessage(m)}`,
                      )
                    }
                  />
                ) : (
                  claimAction(preset, "Raycast")
                )}
                {utilityActions}
              </ActionPanel>
            }
          />
        ))}
        <List.Item
          icon={Icon.Hourglass}
          title="Forever"
          subtitle="no deadline — the battery floor is the only thing that ends it"
          actions={
            <ActionPanel>
              {claimAction("forever", "Raycast")}
              {utilityActions}
            </ActionPanel>
          }
        />
      </List.Section>

      {status !== undefined && status.cap > 0 && (
        <List.Section title="Ceiling">
          <List.Item
            icon="🖐"
            title={`Nothing past ${hhmm(status.cap)}`}
            subtitle={
              status.capped ? "a live claim is clipped by it" : undefined
            }
            actions={
              <ActionPanel>
                <Action
                  title="Lift the Ceiling"
                  icon={Icon.Stop}
                  onAction={() =>
                    perform(capArgs("off"), () => "Ceiling lifted")
                  }
                />
                {utilityActions}
              </ActionPanel>
            }
          />
        </List.Section>
      )}
    </List>
  );
}
