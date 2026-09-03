#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const piRoot = process.env.LIBFX_BENCH_PI_ROOT;
if (!piRoot) {
  console.log("pi benchmark integration skipped: LIBFX_BENCH_PI_ROOT is not set");
  process.exit(0);
}

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const benchmark = fileURLToPath(new URL("../../benchmarks/libfx/bench-pi.mjs", import.meta.url));
const result = spawnSync(process.execPath, [benchmark, "--samples", "1", "--json"], {
  cwd: repoRoot,
  encoding: "utf8",
  timeout: 20_000,
  env: { ...process.env, LIBFX_BENCH_PI_ROOT: piRoot },
});
assert.equal(result.status, 0, `pi benchmark failed:\n${result.stderr}`);
const report = JSON.parse(result.stdout);
assert.equal(report.target, "pi");
assert.equal(report.samples.length, 1);
assert.equal(report.samples[0].text, "hello");
assert.ok(report.samples[0].spawn_to_first_stdout_ms >= 0);
assert.ok(report.samples[0].prompt_to_fetch_ms >= 0);
assert.ok(report.samples[0].first_body_to_first_text_ms >= 0);

console.log("pi benchmark integration passed");
