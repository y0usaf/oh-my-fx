import { afterEach, describe, expect, test } from "bun:test";
import { execSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertCommandSucceeds,
  assertFileContains,
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

describe("eval: fix a known defect", () => {
  test(
    "finds and fixes the incorrect divide function, tests pass",
    async () => {
      workDir = createWorkDir();

      const result: EvalResult = await runEval(
        "There's a bug in this project. The divide function returns wrong results. Find and fix it. Make sure the tests pass.",
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
          setup: async (dir: string) => {
            writeFileSync(
              join(dir, "package.json"),
              JSON.stringify(
                {
                  name: "math-lib",
                  version: "1.0.0",
                  type: "module",
                  scripts: { test: "vitest run" },
                  devDependencies: { vitest: "latest", typescript: "latest" },
                },
                null,
                2,
              ),
            );

            writeFileSync(
              join(dir, "tsconfig.json"),
              JSON.stringify(
                {
                  compilerOptions: {
                    target: "ES2022",
                    module: "ESNext",
                    moduleResolution: "bundler",
                    strict: true,
                    outDir: "dist",
                  },
                  include: ["src"],
                },
                null,
                2,
              ),
            );

            mkdirSync(join(dir, "src"), { recursive: true });

            writeFileSync(
              join(dir, "src", "math.ts"),
              [
                "export function add(a: number, b: number): number {",
                "  return a + b;",
                "}",
                "",
                "export function subtract(a: number, b: number): number {",
                "  return a - b;",
                "}",
                "",
                "export function multiply(a: number, b: number): number {",
                "  return a * b;",
                "}",
                "",
                "export function divide(a: number, b: number): number {",
                "  return a * b;",
                "}",
                "",
              ].join("\n"),
            );

            writeFileSync(
              join(dir, "src", "math.test.ts"),
              [
                "import { describe, expect, test } from 'vitest';",
                "import { add, subtract, multiply, divide } from './math';",
                "",
                "describe('math', () => {",
                "  test('add', () => {",
                "    expect(add(2, 3)).toBe(5);",
                "  });",
                "",
                "  test('subtract', () => {",
                "    expect(subtract(5, 3)).toBe(2);",
                "  });",
                "",
                "  test('multiply', () => {",
                "    expect(multiply(4, 3)).toBe(12);",
                "  });",
                "",
                "  test('divide', () => {",
                "    expect(divide(10, 2)).toBe(5);",
                "  });",
                "",
                "  test('divide by 1', () => {",
                "    expect(divide(7, 1)).toBe(7);",
                "  });",
                "});",
                "",
              ].join("\n"),
            );

            execSync("npm install", { cwd: dir, stdio: "pipe" });
          },
        },
      );

      assertFileContains(workDir, "src/math.ts", /divide[\s\S]*?a\s*\/\s*b/);
      assertCommandSucceeds(workDir, "npm test");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
