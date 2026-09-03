import { afterEach, describe, expect, test } from "bun:test";
import {
  assertTerminalExecMatches,
  cleanupWorkDir,
  createWorkDir,
  runEval,
} from "./eval-helpers";

const TIMEOUT = 120_000;
let workDir: string | null = null;

afterEach(() => {
  if (workDir) { cleanupWorkDir(workDir); workDir = null; }
});

describe("eval: terminal exec", () => {
  test(
    "runs echo and reports the output",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        'Run the command `echo HELLO_FROM_FX` and tell me exactly what it printed.',
        {
          cwd: workDir,
          timeoutSec: 60,
        },
      );
      assertTerminalExecMatches(result, /^echo HELLO_FROM_FX$/);
      expect(result.json.output).toContain("HELLO_FROM_FX");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
