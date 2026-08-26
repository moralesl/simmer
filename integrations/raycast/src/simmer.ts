/**
 * The only bridge to simmer. Everything else in this extension goes through
 * `run()` and the types below.
 *
 * The extension is a fourth renderer over `SimmerCore`, next to the CLI, the
 * app and `simmer render`. It reads the contracted aggregate from
 * `status --json` and never parses `$STATE/claims/*` itself, so it cannot
 * disagree with `Aggregate.compute` about who holds what.
 */
import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** One live claim. Mirrors `Present.claimJSON`. */
export interface SimmerClaim {
  id: string;
  owner: string;
  /** Cap-clipped deadline as an epoch; 0 means no deadline. */
  until: number;
  /** Seconds remaining, or -1 when there is no deadline. */
  left: number;
  reason: string;
  min_battery: number;
  require_ac: boolean;
  since: number;
  human: boolean;
}

/** The whole aggregate. Mirrors `Present.statusJSON`. */
export interface SimmerStatus {
  state: "idle" | "active" | "forever" | "orphan";
  until: number;
  left: number;
  left_short: string;
  reason: string;
  min_battery: number;
  /** null when the battery cannot be read (a desktop, or a failed read). */
  battery: number | null;
  /** 0/1 rather than a boolean — a documented exception in CONTRACTS.md. */
  on_battery: number;
  sleep_disabled: number;
  since: number;
  owner: string;
  claim_count: number;
  /** Epoch of the ceiling; 0 means none. */
  cap: number;
  capped: boolean;
  claims: SimmerClaim[];
  version: string;
}

/** Every mutating command answers with its action, the claim, and the aggregate tail. */
export interface SimmerMutation {
  action: string;
  claim?: SimmerClaim;
  released?: string[];
  clipped_by_cap?: boolean;
  /** `cap <value>` reports how many live claims it shortened. */
  clipped?: number;
  state?: string;
  until?: number;
  claim_count?: number;
  cap?: number;
  capped?: boolean;
  /** When a cap lifts itself, epoch seconds. Only on `cap_set`. */
  expires?: number;
}

/**
 * A refusal simmer chose to make: a battery floor, a passed cap, an owner
 * without the authority. `error` is simmer's own sentence and is shown verbatim
 * — it is the one string this extension does not write itself.
 */
export class SimmerRefusal extends Error {}

/** simmer is not on this machine, or not where the extension can see it. */
export class SimmerNotFound extends Error {
  constructor() {
    super("simmer is not installed");
  }
}

function expandTilde(path: string): string {
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * Raycast runs commands with a minimal PATH, so `command -v simmer` is not
 * enough — the same reason the removed shell shims each carried this list.
 * `~/.local/bin/simmer` is the symlink `make install` writes; the bundle path
 * behind it is what the symlink points at, and it survives a `~/.local/bin`
 * that never made it onto PATH.
 */
export function resolveBinary(
  preferred?: string,
  env: NodeJS.ProcessEnv = process.env,
): string | null {
  const preference = preferred?.trim();
  const candidates = [
    ...(preference ? [expandTilde(preference)] : []),
    ...(env.SIMMER_BIN ? [env.SIMMER_BIN] : []),
    join(homedir(), ".local/bin/simmer"),
    join(homedir(), "Applications/Simmer.app/Contents/MacOS/simmer"),
    "/Applications/Simmer.app/Contents/MacOS/simmer",
    "/usr/local/bin/simmer",
    "/opt/homebrew/bin/simmer",
  ];
  return candidates.find(isExecutable) ?? null;
}

/** `$XDG_STATE_HOME/simmer`, matching `SimmerEnvironment.stateDir`. */
export function stateDir(env: NodeJS.ProcessEnv = process.env): string {
  const xdg = env.XDG_STATE_HOME;
  return join(
    xdg && xdg.length > 0 ? xdg : join(homedir(), ".local/state"),
    "simmer",
  );
}

interface Completed {
  code: number;
  stdout: string;
  stderr: string;
}

function spawn(
  bin: string,
  args: string[],
  env?: NodeJS.ProcessEnv,
): Promise<Completed> {
  return new Promise((resolve) => {
    execFile(
      bin,
      args,
      { timeout: 10_000, encoding: "utf8", env },
      (error, stdout, stderr) => {
        // A refusal is a non-zero exit *with* a JSON body on stdout, so the exit
        // code alone is not enough to build the message from.
        const code =
          error && typeof (error as { code?: unknown }).code === "number"
            ? (error as unknown as { code: number }).code
            : error
              ? 1
              : 0;
        resolve({ code, stdout: stdout ?? "", stderr: stderr ?? "" });
      },
    );
  });
}

/**
 * Run simmer for its human line rather than its JSON — `render raycast`, which
 * is the one-line surface the core draws for exactly this. It is presentation,
 * not contract: CONTRACTS.md reserves the right to reword it, and nothing here
 * parses it. Which is the point — the root-search subtitle should read the way
 * the menu bar reads, and that is a decision the core should keep making.
 */
export async function runText(
  bin: string,
  args: string[],
  env?: NodeJS.ProcessEnv,
): Promise<string> {
  const { code, stdout, stderr } = await spawn(bin, args, env);
  if (code !== 0)
    throw new SimmerRefusal(stderr.trim() || `simmer exited ${code}`);
  return stdout.trim();
}

/**
 * Run simmer and parse its JSON. Non-zero exit carries
 * `{"action":"refused","error":…}`, which becomes a `SimmerRefusal` holding
 * simmer's own sentence — never a message this extension made up.
 */
export async function run<T>(
  bin: string,
  args: string[],
  env?: NodeJS.ProcessEnv,
): Promise<T> {
  const { code, stdout, stderr } = await spawn(bin, args, env);
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    parsed = undefined;
  }

  if (code !== 0) {
    const refusal = parsed as { error?: string } | undefined;
    throw new SimmerRefusal(
      refusal?.error?.trim() || stderr.trim() || `simmer exited ${code}`,
    );
  }
  if (parsed === undefined) {
    throw new SimmerRefusal(
      "simmer returned output this extension could not parse",
    );
  }
  return parsed as T;
}

/**
 * The message for a successful claim or extend. `clipped_by_cap` on a success is
 * not a refusal — the claim was granted, just shorter than asked — so the
 * returned `until` is what gets reported, never the requested duration.
 */
export function grantedMessage(mutation: SimmerMutation): string {
  const until = mutation.claim?.until ?? mutation.until ?? 0;
  if (until === 0) return "no deadline";
  const clock = new Date(until * 1000).toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  return mutation.clipped_by_cap
    ? `until ${clock} — your ceiling`
    : `until ${clock}`;
}
