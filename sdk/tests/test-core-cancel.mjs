#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const defaultWasm = resolve(scriptDir, "../../zig-out/bin/fx-core.wasm");
const wasmPath = resolve(process.argv[2] || defaultWasm);

if (!supportsJspi()) {
  console.error("Node JSPI is disabled. Run with: node --experimental-wasm-jspi sdk/scripts/test-core-cancel.mjs");
  process.exit(2);
}

let fetchStartedResolve;
const fetchStarted = new Promise((resolve) => { fetchStartedResolve = resolve; });
let fetchAborted = false;
const stalledFetch = async (_url, init) => {
  let controller;
  const body = new ReadableStream({ start(value) { controller = value; } });
  init.signal.addEventListener("abort", () => {
    fetchAborted = true;
    controller.error(new DOMException("The operation was aborted", "AbortError"));
  }, { once: true });
  fetchStartedResolve();
  return new Response(body, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
};

const timeout = (label, ms = 5000) => new Promise((_, reject) => {
  setTimeout(() => reject(new Error(`timed out waiting for ${label}`)), ms);
});

const agent = await Promise.race([
  createFxAgent({
  backend: "wasm",
    wasm: await readFile(wasmPath),
    fetch: stalledFetch,
    apiKey: "sdk-test-key",
  }),
  timeout("fx-core initialize"),
]);

const controller = new AbortController();
const turn = agent.prompt("wait forever", { signal: controller.signal });
await Promise.race([fetchStarted, timeout("stalled gateway fetch")]);
controller.abort();
const result = await Promise.race([turn.result, timeout("cancelled prompt")]);
if (result.stopReason !== "cancelled") throw new Error(`unexpected stop reason: ${result.stopReason}`);
if (!fetchAborted) throw new Error("AbortSignal did not abort the stalled fetch");

await agent.close();
console.log("core SDK stalled-fetch cancellation passed: AbortSignal stopped fetch and turn.result returned cancelled");
