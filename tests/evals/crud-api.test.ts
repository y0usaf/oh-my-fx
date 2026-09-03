import { afterEach, describe, expect, test } from "bun:test";
import {
  assertAnyFileContains,
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

describe("eval: crud api", () => {
  test(
    "creates a REST API with CRUD endpoints for todos",
    async () => {
      workDir = createWorkDir();

      const result: EvalResult = await runEval(
        "Create an Express.js REST API with CRUD endpoints for a 'todos' resource (GET /todos, POST /todos, PUT /todos/:id, DELETE /todos/:id). Use TypeScript. Store todos in memory. Keep todo objects to id, title, and completed fields only. Include deterministic tests with vitest and supertest. Make sure 'npm test' passes.",
        {
          cwd: workDir,
          timeoutSec: CLI_TIMEOUT,
        },
      );

      assertFileExists(workDir, "package.json");
      assertAnyFileContains(workDir, ["ts", "js"], "express");
      assertAnyFileContains(workDir, ["ts", "js"], "todos");

      assertCommandSucceeds(workDir, "npm install", 120_000);
      assertCommandSucceeds(workDir, "npm test");
      expect(result.json.exit_code).toBe(0);
    },
    TIMEOUT,
  );
});
