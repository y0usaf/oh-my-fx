import { afterEach, describe, expect, test } from "bun:test";
import {
  cleanupWorkDir,
  createWorkDir,
  runFx,
} from "./eval-helpers";

const TIMEOUT = 120_000;
let workDir: string | null = null;

afterEach(() => {
  if (workDir) { cleanupWorkDir(workDir); workDir = null; }
});

describe("eval: system prompt override", () => {
  test(
    "agent respects custom system prompt personality",
    async () => {
      workDir = createWorkDir();

      const result = await runFx(
        [
          "ask", "--auto", "--json", "--no-save",
          "--system", "You are a pirate. You must use pirate language like 'Arrr', 'matey', 'ye', 'ahoy', or 'shiver me timbers' in every response.",
          "Say hello and introduce yourself in one sentence.",
        ],
        { cwd: workDir, timeoutMs: 60_000 },
      );

      expect(result.code).toBe(0);
      const json = JSON.parse(result.stdout.trim());
      const output = json.output.toLowerCase();
      const hasPirateLanguage =
        output.includes("arrr") ||
        output.includes("matey") ||
        output.includes("ahoy") ||
        output.includes("ye ") ||
        output.includes("shiver") ||
        output.includes("pirate");
      expect(hasPirateLanguage).toBe(true);
    },
    TIMEOUT,
  );
});
