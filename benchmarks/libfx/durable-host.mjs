import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { durableCatalog, durableModel, durableTools, framesFor } from "./durable.mjs";

export const repoRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));

const encoder = new TextEncoder();

export function scriptedFetch({ stepsFor, onRequest = () => {} }) {
  return async (input, init = {}) => {
    const method = String(init.method ?? input?.method ?? "GET").toUpperCase();
    if (method === "GET") return Response.json(durableCatalog);
    const raw = typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    const body = JSON.parse(raw);
    const frames = framesFor(stepsFor(body.prompt), body.prompt);
    onRequest({ body, frames });
    return new Response(new ReadableStream({
      start(controller) {
        for (const frame of frames) controller.enqueue(encoder.encode(`data: ${JSON.stringify(frame)}\n\n`));
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
}

export function sleep(ms, signal) {
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolveSleep, reject) => {
    const timer = setTimeout(resolveSleep, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(signal.reason ?? new Error("aborted"));
    }, { once: true });
  });
}

let wasmBytes = null;

export async function agentOptions({ backend, fetch, tools = [], checkpoint, persistence, sessionId }) {
  if (backend === "wasm") wasmBytes ??= await readFile(resolve(repoRoot, "zig-out/bin/fx-core.wasm"));
  return {
    backend,
    nativeAddon: resolve(repoRoot, "zig-out/lib/libfx.node"),
    ...(backend === "wasm" ? { wasm: wasmBytes } : {}),
    ...(checkpoint ? { checkpoint } : {}),
    ...(persistence ? { persistence } : {}),
    ...(sessionId ? { sessionId } : {}),
    fetch,
    apiKey: "durable-harness-key",
    gatewayChatUrl: "http://127.0.0.1:9/chat",
    model: durableModel,
    tools,
  };
}

export function hostTools(run) {
  return Object.entries(durableTools).map(([name, policy]) => ({
    name,
    description: `Durable harness tool ${name}.`,
    inputSchema: { type: "object", additionalProperties: true },
    ...policy,
    execute: (input, context) => run(name, input, context),
  }));
}

export function parseArgs(argv, defaults) {
  const options = { ...defaults };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    if (!(key in defaults)) throw new Error(`unknown option --${key}`);
    if (typeof defaults[key] === "boolean") options[key] = true;
    else options[key] = argv[++index];
  }
  return options;
}

export const listOption = (value) => String(value).split(",").map((item) => item.trim()).filter(Boolean);
