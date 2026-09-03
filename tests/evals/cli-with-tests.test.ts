import { afterEach, describe, expect, test } from "bun:test";
import {
  assertAnyFileExists,
  assertCommandSucceeds,
  assertFileExists,
  cleanupWorkDir,
  createWorkDir,
  type EvalResult,
  runEval,
} from "./eval-helpers";

const TIMEOUT = 600_000;
const CLI_TIMEOUT = 300;

let workDir: string | null = null;

afterEach(() => {
  if (workDir) {
    cleanupWorkDir(workDir);
    workDir = null;
  }
});

describe("eval: cli with tests", () => {
  test(
    "creates a node CLI tool with passing tests",
    async () => {
      workDir = createWorkDir();

      const result: EvalResult = await runEval(
        "Create a Node.js CLI tool called 'wordcount' that reads a file and prints the number of words, lines, and characters. Include a test suite using vitest. Make sure 'npm test' passes.",
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
        },
      );

      assertFileExists(workDir, "package.json");
      assertAnyFileExists(workDir, [
        "src/index.ts",
        "src/index.js",
        "index.ts",
        "index.js",
        "src/wordcount.ts",
        "src/wordcount.js",
        "src/cli.ts",
        "src/cli.js",
        "bin/wordcount.js",
        "bin/wordcount.ts",
        "lib/wordcount.ts",
        "lib/wordcount.js",
        "wordcount.ts",
        "wordcount.js",
      ]);

      assertCommandSucceeds(workDir, "npm install", 120_000);
      assertCommandSucceeds(workDir, "npm test");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
