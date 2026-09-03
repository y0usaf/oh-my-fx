#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../node.js";
import { createMcpAdapter } from "../mcp.js";

const transport = process.argv[2] || "stdio";
const backend = process.argv[3] || (transport === "stdio" ? "native" : "wasm");
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
let mcpClosed = false;

function rpcClient(send, close) {
  let nextId = 1;
  const pending = new Map();
  const receive = (message) => {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error.message));
    else waiter.resolve(message.result);
  };
  const request = (method, params = {}) => new Promise((resolveRequest, reject) => {
    const id = nextId++;
    pending.set(id, { resolve: resolveRequest, reject });
    send({ jsonrpc: "2.0", id, method, params }, receive).catch((error) => {
      pending.delete(id);
      reject(error);
    });
  });
  return {
    initialize: () => request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "libfx-test", version: "1" } }),
    listTools: () => request("tools/list"),
    callTool: (params) => request("tools/call", params),
    readResource: (params) => request("resources/read", params),
    getPrompt: (params) => request("prompts/get", params),
    async close() { await close(); mcpClosed = true; },
    receive,
  };
}

let mcpServer;
let mcpClient;
if (transport === "stdio") {
  const child = spawn(process.execPath, [resolve(scriptDir, "fixtures/mcp-stdio-server.mjs")], { stdio: ["pipe", "pipe", "inherit"] });
  let client;
  client = rpcClient(async (message) => { child.stdin.write(`${JSON.stringify(message)}\n`); }, async () => {
    child.stdin.end();
    await new Promise((resolveExit) => child.once("exit", resolveExit));
  });
  createInterface({ input: child.stdout }).on("line", (line) => client.receive(JSON.parse(line)));
  mcpClient = client;
} else {
  const dispatch = ({ id, method, params }) => {
    if (method === "initialize") return { jsonrpc: "2.0", id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {}, resources: {}, prompts: {} }, serverInfo: { name: "http-fixture", version: "1" } } };
    if (method === "tools/list") return { jsonrpc: "2.0", id, result: { tools: [{ name: "echo", description: "Echo a value", inputSchema: { type: "object", properties: { value: { type: "string" } }, required: ["value"] } }] } };
    if (method === "tools/call") return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: `mcp:${params.arguments.value}` }] } };
    if (method === "resources/read") return { jsonrpc: "2.0", id, result: { contents: [{ uri: params.uri, text: "resource context" }] } };
    if (method === "prompts/get") return { jsonrpc: "2.0", id, result: { messages: [{ role: "user", content: [{ type: "text", text: "prompt context" }] }] } };
    return { jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } };
  };
  mcpServer = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(dispatch(JSON.parse(Buffer.concat(chunks).toString("utf8")))));
  });
  await new Promise((resolveListen) => mcpServer.listen(0, "127.0.0.1", resolveListen));
  const endpoint = `http://127.0.0.1:${mcpServer.address().port}/mcp`;
  mcpClient = rpcClient(async (message, receive) => {
    const response = await fetch(endpoint, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(message) });
    receive(await response.json());
  }, async () => {
    mcpServer.closeAllConnections();
    await new Promise((resolveClose) => mcpServer.close(resolveClose));
  });
}

await mcpClient.initialize();
const adapter = await createMcpAdapter(mcpClient, {
  prefix: "mcp_",
  resources: ["memory://fixture"],
  prompts: ["fixture"],
});
assert.ok(adapter.instructions.includes("resource context"));
assert.ok(adapter.instructions.includes("prompt context"));

let gatewayRequests = 0;
const gateway = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "mcp/model", type: "language", tags: ["tool-use"] }] }));
      return;
    }
    gatewayRequests += 1;
    response.writeHead(200, { "content-type": "text/event-stream" });
    if (gatewayRequests === 1) {
      assert.ok(body.includes("resource context") && body.includes("prompt context"));
      assert.ok(JSON.parse(body).tools.some((tool) => tool.name === "mcp_echo"));
      response.end('data: {"type":"tool-call","toolCallId":"mcp_1","toolName":"mcp_echo","input":{"value":"hello"}}\n\ndata: {"type":"finish","finishReason":{"unified":"tool-calls","raw":"tool-calls"}}\n\ndata: [DONE]\n\n');
      return;
    }
    assert.ok(body.includes("mcp:hello"));
    response.end('data: {"type":"text-delta","delta":"done"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n');
  });
});
await new Promise((resolveListen) => gateway.listen(0, "127.0.0.1", resolveListen));

let agent;
try {
  agent = await createFxAgent({
    backend,
    nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node"),
    ...(backend === "wasm" ? { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) } : {}),
    tools: adapter.tools,
    instructions: adapter.instructions,
    fetch,
    apiKey: "mcp-key",
    gatewayChatUrl: `http://127.0.0.1:${gateway.address().port}/chat`,
    model: "mcp/model",
  });
  const turn = agent.prompt("use MCP");
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  assert.equal(text, "done");
  assert.equal((await turn.result).stopReason, "end_turn");
  await agent.close();
  agent = null;
  await adapter.close();
  assert.equal(mcpClosed, true);
  console.log(`${transport}/${backend} MCP adapter integration passed`);
} finally {
  await agent?.close().catch(() => {});
  await adapter.close().catch(() => {});
  gateway.closeAllConnections();
  await new Promise((resolveClose) => gateway.close(resolveClose));
}
