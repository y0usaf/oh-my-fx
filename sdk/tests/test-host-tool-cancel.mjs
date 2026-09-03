#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";

const backend = process.argv[2] || "native";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
let modelRequests = 0;
const server = createServer((request, response) => {
  request.resume();
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end('{"object":"list","data":[]}');
      return;
    }
    modelRequests += 1;
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end('data: {"type":"tool-call","toolCallId":"cancel_1","toolName":"wait","input":{}}\n\ndata: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));

let toolStartedResolve;
const toolStarted = new Promise((resolveStarted) => { toolStartedResolve = resolveStarted; });
let toolSignalAborted = false;
const events = [];
const agent = await createFxAgent({
  backend,
  nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
  ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
  fetch,
  traceWasi: process.env.LIBFX_TRACE_WASM === "1",
  onEvent(event) { events.push(event); },
  tools: [{
    name: "wait",
    description: "Wait until cancelled",
    inputSchema: { type: "object", properties: {} },
    execute(_input, { signal }) {
      toolStartedResolve();
      return new Promise((_, reject) => signal.addEventListener("abort", () => {
        toolSignalAborted = true;
        reject(new DOMException("aborted", "AbortError"));
      }, { once: true }));
    },
  }],
  apiKey: "cancel-key",
  gatewayChatUrl: `http://127.0.0.1:${server.address().port}/chat`,
  model: "cancel/model",
});

try {
  const controller = new AbortController();
  const turn = agent.prompt("wait", { signal: controller.signal });
  await toolStarted;
  controller.abort();
  const result = await Promise.race([
    turn.result,
    new Promise((_, reject) => setTimeout(() => reject(new Error(
      `cancel timed out signal=${toolSignalAborted} events=${JSON.stringify(events.slice(-8))}`,
    )), 5000)),
  ]);
  assert.equal(result.stopReason, "cancelled");
  assert.equal(toolSignalAborted, true);
  assert.equal(modelRequests, 1);
  await agent.close();
  console.log(`${backend} host tool cancellation passed`);
} finally {
  await agent.close().catch(() => {});
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
