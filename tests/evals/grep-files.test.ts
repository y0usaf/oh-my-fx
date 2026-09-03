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

describe("eval: grep files", () => {
  test(
    "finds which file contains a specific string",
    async () => {
      workDir = createWorkDir();
      const result = await runEval(
        'Which file contains the string "SECRET_TOKEN_42"? Reply with just the filename.',
        {
          cwd: workDir,
          timeoutSec: 60,
          setup: async (dir) => {
            mkdirSync(join(dir, "src"), { recursive: true });
            writeFileSync(join(dir, "src", "config.ts"), 'export const API_URL = "https://example.com";\n');
            writeFileSync(join(dir, "src", "auth.ts"), 'export const token = "SECRET_TOKEN_42";\n');
            writeFileSync(join(dir, "src", "utils.ts"), 'export function helper() { return 1; }\n');
            writeFileSync(join(dir, "README.md"), "# My Project\n");
          },
        },
      );
      const output = result.json.output.toLowerCase();
      expect(output).toContain("auth");
      expect(result.json.exit_code).toBe(0);
      assertToolUsed(result, "grep_files");
    },
    TIMEOUT,
  );
});
