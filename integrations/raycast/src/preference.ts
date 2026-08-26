import { getPreferenceValues } from "@raycast/api";
import { resolveBinary, SimmerNotFound } from "./simmer.ts";

/** The configured path, if the user set one. Kept here so `simmer.ts` needs no
 * Raycast API and can therefore be exercised against the real binary in tests. */
export function preferredPath(): string | undefined {
  return getPreferenceValues<{ simmerPath?: string }>().simmerPath;
}

/** The binary, or a `SimmerNotFound` for `report()` to turn into a calm toast. */
export function binary(): string {
  const bin = resolveBinary(preferredPath());
  if (!bin) throw new SimmerNotFound();
  return bin;
}
