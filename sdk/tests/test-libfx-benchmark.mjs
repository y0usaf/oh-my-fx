#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const benchmark = fileURLToPath(new URL("../../benchmarks/libfx/bench-fx.mjs", import.meta.url));
const runtime = process.versions.bun ? "bun" : "node";
const command = process.execPath;

for (const backend of ["native", "wasm"]) {
  const args = [benchmark, "--backend", backend, "--samples", "1", "--json"];
  if (runtime === "node" && backend === "wasm") args.unshift("--experimental-wasm-jspi");
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 20_000,
  });
  assert.equal(result.status, 0, `${runtime} ${backend} benchmark failed:\n${result.stderr}`);
  const report = JSON.parse(result.stdout);
  assert.equal(report.runtime, runtime);
  assert.equal(report.backend, backend);
  assert.equal(report.samples.length, 1);
  const sample = report.samples[0];
  assert.equal(sample.text, "hello");
  assert.ok(sample.spawn_to_first_stdout_ms >= 0);
  assert.ok(sample.prompt_to_fetch_ms >= 0);
  assert.ok(sample.first_body_to_first_text_ms >= 0);
  assert.ok(sample.total_ms >= sample.spawn_to_first_stdout_ms);
}

console.log(`${runtime} libfx benchmark integration passed`);
