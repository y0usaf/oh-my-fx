import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const packageRoot = import.meta.dirname;
const repoRoot = resolve(packageRoot, "../..");
const manifestPath = resolve(packageRoot, "corpus.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
  revision: string;
};
const suiteRoot = resolve(
  process.argv[2] ?? process.env.JSON_SCHEMA_TEST_SUITE ?? "",
);
if (!process.argv[2] && !process.env.JSON_SCHEMA_TEST_SUITE) {
  throw new Error(
    "pass the JSON-Schema-Test-Suite checkout path or set JSON_SCHEMA_TEST_SUITE",
  );
}

const revisionProcess = Bun.spawn(["git", "-C", suiteRoot, "rev-parse", "HEAD"], {
  stdout: "pipe",
  stderr: "inherit",
});
const revision = (await new Response(revisionProcess.stdout).text()).trim();
if ((await revisionProcess.exited) !== 0) process.exit(1);
if (revision !== manifest.revision) {
  throw new Error(
    `expected JSON-Schema-Test-Suite ${manifest.revision}, found ${revision}`,
  );
}

const runner = Bun.spawn(
  [
    "zig",
    "build",
    "run-json-schema-corpus",
    "--",
    suiteRoot,
    manifestPath,
  ],
  {
    cwd: repoRoot,
    stdout: "inherit",
    stderr: "inherit",
  },
);
process.exit(await runner.exited);
