import { afterEach, describe, expect, test } from "bun:test";
import {
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

describe("eval: date awareness", () => {
  test(
    "agent responds with the correct current date",
    async () => {
      workDir = createWorkDir();

      const now = new Date();
      const year = String(now.getFullYear());
      const monthLong = now.toLocaleString("en-US", { month: "long" });
      const monthShort = now.toLocaleString("en-US", { month: "short" });
      const monthNum = String(now.getMonth() + 1);
      const monthPadded = monthNum.padStart(2, "0");
      const day = String(now.getDate());

      const result: EvalResult = await runEval(
        "What is today's date? Respond with just the date.",
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
        },
      );

      const output = result.json.output.toLowerCase();

      expect(output).toContain(year);

      const hasMonth =
        output.includes(monthLong.toLowerCase()) ||
        output.includes(monthShort.toLowerCase()) ||
        output.includes(`/${monthPadded}/`) ||
        output.includes(`/${monthNum}/`) ||
        output.includes(`-${monthPadded}-`) ||
        output.includes(`-${monthNum}-`);
      expect(hasMonth).toBe(true);

      expect(output).toContain(day);
      expect(result.json.exit_code).toBe(0);

      console.log(`\n  expected: ${monthLong} ${day}, ${year}`);
      console.log(`  output: ${result.json.output.trim()}`);
    },
    TIMEOUT,
  );
});
