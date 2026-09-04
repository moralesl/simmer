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
import { applyArgs, updateArgs } from "./args.ts";

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

/** `simmer update --json`. Mirrors `UpdateCommand.json`. */
export interface SimmerUpdate {
  /** `checked` for a plain check; `updated` or `refused` under `--apply`. */
  action: "checked" | "updated" | "refused";
  verdict: "current" | "available" | "ahead" | "unknown";
  installed: string;
  /** The release tag as published (`v0.3.0`), null when the check could not answer. */
  latest: string | null;
  update_available: boolean;
  /** How this copy was installed, which decides `update_command`. */
  provenance: "homebrew" | "bundle" | "checkout" | "unknown";
  update_command: string;
  app_version: string | null;
  /** Simmer.app and the CLI are different versions — half an install. */
  app_drift: boolean;
  checked_at: number;
  cached: boolean;
  error: string | null;
  seamed: boolean;
  /** `--apply` only: something was installed. */
  applied?: boolean;
  /** `--apply` only: the commands it ran, in order. */
  steps?: string[];
  /** `--apply` only: why it could not be done. */
  apply_error?: string | null;
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
  /** When the ceiling lifts itself, epoch seconds; 0 when there is no cap. */
  cap_expires?: number;
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
  timeout = 10_000,
): Promise<Completed> {
  return new Promise((resolve) => {
    execFile(
      bin,
      args,
      { timeout, encoding: "utf8", env },
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
 * Is there a newer simmer.
 *
 * The one command whose non-zero exit is not a refusal: `simmer update` exits 1
 * when it could not TELL, and prints the same object either way with
 * `verdict: "unknown"` and the reason in `error`. Routing it through `run()`
 * would turn "cannot reach GitHub" into a thrown refusal and throw the body
 * away with it, so the exit code is read as the answer it is.
 */
export async function checkUpdate(
  bin: string,
  cached = true,
  env?: NodeJS.ProcessEnv,
): Promise<SimmerUpdate> {
  const { code, stdout, stderr } = await spawn(bin, updateArgs(cached), env);
  let parsed: SimmerUpdate | undefined;
  try {
    parsed = JSON.parse(stdout) as SimmerUpdate;
  } catch {
    parsed = undefined;
  }
  if (parsed?.action === "checked") return parsed;
  // Anything else IS a refusal — an unknown flag, a binary too old to have the
  // verb at all — and simmer's own sentence is the one to show.
  throw new SimmerRefusal(
    (parsed as { error?: string } | undefined)?.error?.trim() ||
      stderr.trim() ||
      `simmer exited ${code}`,
  );
}

/**
 * Install the update, rather than printing its command.
 *
 * Takes as long as a build — a minute or two — so a caller has to say
 * something to the person waiting. It runs the same command `simmer update`
 * would have printed, needs no password, and never pipes a script from the
 * internet into a shell (CONTRACTS.md § Surface guarantees).
 *
 * A refusal here is a real refusal — someone's own checkout, or no checkout to
 * build from — and carries simmer's own sentence.
 */
export async function applyUpdate(
  bin: string,
  env?: NodeJS.ProcessEnv,
): Promise<SimmerUpdate> {
  // Longer than `spawn`'s default 10s: this compiles. The CLI has no timeout
  // of its own, so the ceiling here is the only one.
  const { code, stdout, stderr } = await spawn(bin, applyArgs(), env, 15 * 60_000);
  let parsed: SimmerUpdate | undefined;
  try {
    parsed = JSON.parse(stdout) as SimmerUpdate;
  } catch {
    parsed = undefined;
  }
  if (parsed?.action === "updated" || parsed?.action === "checked") return parsed;
  throw new SimmerRefusal(
    parsed?.apply_error?.trim() ||
      parsed?.error?.trim() ||
      stderr.trim() ||
      `simmer exited ${code}`,
  );
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
