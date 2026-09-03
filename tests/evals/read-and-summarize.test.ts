import { afterEach, describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import {
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

describe("eval: read and summarize", () => {
  test(
    "reads a file and produces a relevant summary",
    async () => {
      workDir = createWorkDir();

      const result: EvalResult = await runEval(
        "Read the file notes.txt and give me a one-sentence summary of what it says.",
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
          setup: async (dir: string) => {
            writeFileSync(
              join(dir, "notes.txt"),
              [
                "Project Alpha Status Report",
                "Date: 2026-01-15",
                "",
                "The migration to PostgreSQL is 80% complete.",
                "We switched from MySQL due to better JSON support.",
                "The team expects to finish by end of February.",
                "Performance benchmarks show a 3x improvement in query speed.",
                "The only remaining blocker is the legacy auth module.",
              ].join("\n"),
            );
          },
        },
      );

      assertToolUsed(result, "read_file");

      const output = result.json.output.toLowerCase();
      const mentionsProject =
        output.includes("postgresql") ||
        output.includes("migration") ||
        output.includes("database") ||
        output.includes("project alpha");
      expect(mentionsProject).toBe(true);
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
