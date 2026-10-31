import { join } from "node:path";
import { TLA_ROOT, runTlc as runShared } from "../../lib/tlc";

export { sha256File, sha256Text, tlcToolchain, utcStamp, writeJson } from "../../lib/tlc";
export type { TlcRun } from "../../lib/tlc";

export const SPEC_DIR = join(TLA_ROOT, "acp");

export function runTlc(dir: string, module: string, cfg: string, specs: string[]) {
  return runShared(dir, module, cfg, specs, SPEC_DIR);
}
