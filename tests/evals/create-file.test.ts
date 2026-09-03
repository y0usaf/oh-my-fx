import { afterEach, describe, expect, test } from "bun:test";
import {
  assertFileContains,
  assertFileExists,
  assertToolUsed,
  cleanupWorkDir,
  createWorkDir,
  type EvalResult,
  runEval,
} from "./eval-helpers";

const TIMEOUT = 120_000;
const CLI_TIMEOUT = 60;

let workDir: string | null = null;

afterEach(() => {
  if (workDir) {
    cleanupWorkDir(workDir);
    workDir = null;
  }
});

describe("eval: create a file", () => {
  test(
    "creates hello.txt with the requested content",
    async () => {
      workDir = createWorkDir();

      const result: EvalResult = await runEval(
        'Create a file called hello.txt that contains exactly "Hello, World!"',
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
        },
      );

      assertFileExists(workDir, "hello.txt");
      assertFileContains(workDir, "hello.txt", "Hello, World!");
      assertToolUsed(result, "write_file");
      expect(result.json.exit_code).toBe(0);
      expect(result.json.steps).toBeGreaterThanOrEqual(1);
    },
    TIMEOUT,
  );
});
