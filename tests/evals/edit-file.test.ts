import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertFileContains,
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

describe("eval: edit file", () => {
  test(
    "edits an existing config file correctly",
    async () => {
      workDir = createWorkDir();

      const result: EvalResult = await runEval(
        'In config.json, change the "port" value from 3000 to 8080 and set "debug" to true.',
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
          setup: async (dir: string) => {
            writeFileSync(
              join(dir, "config.json"),
              JSON.stringify(
                {
                  name: "my-app",
                  port: 3000,
                  debug: false,
                  logLevel: "info",
                },
                null,
                2,
              ),
            );
          },
        },
      );

      const content = JSON.parse(
        readFileSync(join(workDir, "config.json"), "utf-8"),
      );
      expect(content.port).toBe(8080);
      expect(content.debug).toBe(true);
      expect(content.name).toBe("my-app");
      expect(content.logLevel).toBe("info");
      expect(result.json.exit_code).toBe(0);
      assertToolUsed(result, "edit_file");
    },
    TIMEOUT,
  );
});
