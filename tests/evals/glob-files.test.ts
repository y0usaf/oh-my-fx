import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertToolUsed,
  cleanupWorkDir,
  createWorkDir,
  runEval,
} from "./eval-helpers";

const TIMEOUT = 120_000;
let workDir: string | null = null;

afterEach(() => {
  if (workDir) { cleanupWorkDir(workDir); workDir = null; }
});

describe("eval: glob files", () => {
  test(
    "lists only .json files in the project",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        "List all .json files in this project. Reply with just the filenames, one per line.",
        {
          cwd: workDir,
          timeoutSec: 60,
          setup: async (dir) => {
            mkdirSync(join(dir, "src"), { recursive: true });
            writeFileSync(join(dir, "package.json"), '{"name":"test"}\n');
            writeFileSync(join(dir, "tsconfig.json"), '{"compilerOptions":{}}\n');
            writeFileSync(join(dir, "src", "index.ts"), 'console.log("hi");\n');
            writeFileSync(join(dir, "README.md"), "# test\n");
          },
        },
      );
      const output = result.json.output.toLowerCase();
      expect(output).toContain("package.json");
      expect(output).toContain("tsconfig.json");
      expect(result.json.exit_code).toBe(0);
      assertToolUsed(result, "glob_files");
    },
    TIMEOUT,
  );
});
