#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, supportsJspi } from "../node.js";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm"]).has(backend)) {
  throw new Error("usage: test-agent-images.mjs [native|wasm]");
}
if (backend === "wasm" && !supportsJspi()) {
  console.error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
  process.exit(2);
}

const encoded = new TextEncoder();
// A real 1x1 PNG, plus a helper that builds a PNG-sniffable payload with an
// exact base64 length for limit probing (the kernel sniffs magic bytes only).
const pngData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
function pngWithEncodedLength(encodedLength) {
  assert.equal(encodedLength % 4, 0);
  const raw = Buffer.alloc((encodedLength / 4) * 3);
  Buffer.from(pngData, "base64").copy(raw);
  return raw.toString("base64");
}
const catalog = {
  object: "list",
  data: [
    { id: "sdk/vision-model", type: "language", tags: ["tool-use", "vision", "file-input"] },
    { id: "sdk/plain-model", type: "language" },
  ],
};

function mockGateway() {
  const state = { catalogFetches: 0, chatBodies: [] };
  const fetch = async (url, init = {}) => {
    const method = String(init.method ?? "GET").toUpperCase();
    if (method === "GET") {
      state.catalogFetches += 1;
      return Response.json(catalog);
    }
    state.chatBodies.push(JSON.parse(new TextDecoder().decode(init.body)));
    return new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(encoded.encode('data: {"type":"text-delta","delta":"ok"}\n\n'));
        controller.enqueue(encoded.encode('data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}\n\n'));
        controller.enqueue(encoded.encode("data: [DONE]\n\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  return { state, fetch };
}

const baseOptions = {
  backend,
  apiKey: "sdk-images-test-key",
  ...(backend === "native"
    ? { nativeAddon: resolve(scriptDir, "../../zig-out/lib/libfx.node") }
    : { wasm: await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm")) }),
};
const createAgent = (gateway, overrides) =>
  createFxAgent({ ...baseOptions, fetch: gateway.fetch, ...overrides });

async function runPrompt(agent, input) {
  const turn = agent.prompt(input);
  for await (const _ of turn) {}
  return turn.result;
}

function fileParts(body) {
  return body.prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "file");
}

// An image block reaches an image-capable model as a v4 file part, alongside
// the text and its placeholder.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const result = await runPrompt(agent, [
    { type: "text", text: "what is in this image?" },
    { type: "image", data: pngData, mimeType: "image/png" },
  ]);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 1);
  const body = gateway.state.chatBodies[0];
  const files = fileParts(body);
  assert.deepEqual(files, [{ type: "file", mediaType: "image/png", data: { type: "data", data: pngData } }]);
  const text = body.prompt
    .filter((message) => message.role === "user" && Array.isArray(message.content))
    .flatMap((message) => message.content)
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n");
  assert.match(text, /what is in this image\?/);
  await agent.close();
}

// A pure-image prompt is valid; the placeholder keeps the turn non-empty.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const result = await runPrompt(agent, [{ type: "image", data: pngData, mimeType: "image/png" }]);
  assert.equal(result.stopReason, "end_turn");
  assert.equal(fileParts(gateway.state.chatBodies[0]).length, 1);
  await agent.close();
}

// A model without advertised image input never receives the request; the turn
// fails with the explicit notice instead of crashing or sending the image.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/plain-model" });
  const turn = agent.prompt([{ type: "image", data: pngData, mimeType: "image/png" }]);
  await assert.rejects(turn.result, /Image prompts are unavailable for the selected model/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// A model missing from the catalog cannot confirm image support: same
// explicit failure, still no image bytes on the wire.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/unlisted-model" });
  const turn = agent.prompt([{ type: "image", data: pngData, mimeType: "image/png" }]);
  await assert.rejects(turn.result, /Image prompts are unavailable for the selected model/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// Checkpoint/restore round-trips prompt images inside the checkpoint bound:
// the restored agent re-sends the same bytes on the next turn.
{
  const gateway = mockGateway();
  const first = await createAgent(gateway, { model: "sdk/vision-model" });
  const initial = await runPrompt(first, [
    { type: "text", text: "remember this image" },
    { type: "image", data: pngData, mimeType: "image/png" },
  ]);
  assert.equal(initial.stopReason, "end_turn");
  const checkpoint = await first.checkpoint();
  await first.close();

  const restored = await createAgent(gateway, { model: "sdk/vision-model", checkpoint });
  const followup = await runPrompt(restored, "describe it again");
  assert.equal(followup.stopReason, "end_turn");
  assert.equal(gateway.state.chatBodies.length, 2);
  const files = fileParts(gateway.state.chatBodies[1]);
  assert.deepEqual(files, [{ type: "file", mediaType: "image/png", data: { type: "data", data: pngData } }]);
  await restored.close();
}

// SDK-side limits reject synchronously with typed errors naming the bound,
// before any runtime or network work.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });

  assert.throws(
    () => agent.prompt([{ type: "image", data: "", mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: pngData }]),
    (error) => error instanceof TypeError && /requires a mimeType/.test(error.message),
  );
  assert.throws(
    () => agent.prompt([{ type: "image", data: 42, mimeType: "image/png" }]),
    (error) => error instanceof TypeError && /requires base64 data/.test(error.message),
  );

  const overSized = pngWithEncodedLength(5 * 1024 * 1024 + 4);
  assert.throws(
    () => agent.prompt([{ type: "image", data: overSized, mimeType: "image/png" }]),
    (error) => error instanceof RangeError && /per-image libfx limit/.test(error.message),
  );

  const nine = Array.from({ length: 9 }, () => ({ type: "image", data: pngData, mimeType: "image/png" }));
  assert.throws(
    () => agent.prompt(nine),
    (error) => error instanceof RangeError && /more than 8 images/.test(error.message),
  );

  const half = pngWithEncodedLength(Math.floor(4.25 * 1024 * 1024));
  assert.throws(
    () => agent.prompt([
      { type: "image", data: half, mimeType: "image/png" },
      { type: "image", data: half, mimeType: "image/png" },
    ]),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );

  // Exactly 8 MiB of image data passes the image budgets but crosses the
  // core's 8 MiB ACP frame limit once the envelope is added, so the SDK
  // rejects the prompt itself instead of emitting a frame the core must drop.
  const quarter = pngWithEncodedLength(4 * 1024 * 1024);
  assert.throws(
    () => agent.prompt([
      { type: "text", text: "boundary" },
      { type: "image", data: quarter, mimeType: "image/png" },
      { type: "image", data: quarter, mimeType: "image/png" },
    ]),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );
  // The same frame bound applies to text-only prompts on both backends.
  assert.throws(
    () => agent.prompt("x".repeat(9 * 1024 * 1024)),
    (error) => error instanceof RangeError && /frame limit/.test(error.message),
  );

  assert.equal(gateway.state.catalogFetches, 0);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

// Kernel-side content validation stays authoritative: non-canonical base64 and
// a sniffed media type that contradicts the declaration fail the turn with a
// typed error rather than reaching the model.
{
  const gateway = mockGateway();
  const agent = await createAgent(gateway, { model: "sdk/vision-model" });
  const badBase64 = agent.prompt([{ type: "image", data: "aGVsbG8", mimeType: "image/png" }]);
  await assert.rejects(badBase64.result, /Invalid image prompt block/);
  const jpegBytes = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]).toString("base64");
  const mismatch = agent.prompt([{ type: "image", data: jpegBytes, mimeType: "image/png" }]);
  await assert.rejects(mismatch.result, /Invalid image prompt block/);
  assert.equal(gateway.state.chatBodies.length, 0);
  await agent.close();
}

console.log(`${backend} agent image prompts passed`);
