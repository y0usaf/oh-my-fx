import { parentPort, workerData } from "node:worker_threads";
import { sharedSet } from "./shared-set.mjs";

const { w, liveBuffer, announcedBuffer, tool, toolFlags, runsAhead, durabilityKind, leaseMs, streamQuietMs, backend, addon, wasm, hooks } = workerData;
globalThis[Symbol.for("libfx.liveHolders")] = sharedSet(liveBuffer);
const announced = sharedSet(announcedBuffer);

const { createFxAgent } = await import("../../../sdk/node.js");
const { local } = await import("../../../sdk/durable/local.mjs");
const { holdWrites } = await import("../../../sdk/tests/hold-writes.mjs");
const { testHooks } = hooks ? await import("../../../sdk/tests/hooks-fixture.mjs") : {};
const hooksSeen = { events: 0, errors: [] };
const observedHooks = testHooks && {
  onEvent(event) {
    hooksSeen.events += 1;
    testHooks.onEvent(event);
  },
  onError(error) {
    hooksSeen.errors.push(String(error?.stack ?? error));
    testHooks.onError(error);
  },
};
const leasedWorld = durabilityKind === "leased" ? await (async () => {
  const { createWorld } = await import(new URL("../../../sdk/durable/node_modules/@workflow/world-local/dist/index.js", import.meta.url).href);
  const { world } = await import("../../../sdk/durable/world.mjs");
  return (dir) => world(() => createWorld({ dataDir: dir, recoverActiveRuns: false }), { name: "leased", pollMs: 250, leaseMs });
})() : null;
const { vercelStorage } = durabilityKind === "vercel" ? await import("../../../sdk/tests/vercel-storage.mjs") : {};
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("../../../sdk/tests/app-world.mjs") : {};
const { queueWorldAt, closeQueueWorlds } = durabilityKind === "queue" ? await import("../../../sdk/tests/queue-world.mjs") : {};
const durableInternals = Symbol.for("libfx.durableInternals");

const sse = (frames) => new Response(
  [...frames, "[DONE]"].map((frame) => `data: ${typeof frame === "string" ? frame : JSON.stringify(frame)}\n\n`).join(""),
  { headers: { "content-type": "text/event-stream" } },
);
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));

const intentCallIds = (entry) => {
  try {
    const { events } = JSON.parse(Buffer.from(entry.data, "base64").toString("utf8"));
    return events.filter((event) => event?.type === "tool_intent").flatMap((event) => event.data.map((call) => call.id));
  } catch {
    return [];
  }
};

function withoutBackstops(durability) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      return new Proxy(world, {
        get(target, key) {
          const value = Reflect.get(target, key);
          if (key !== "createQueueHandler") return typeof value === "function" ? value.bind(target) : value;
          return (prefix, handler) => value.call(target, prefix, async (...args) => {
            const result = await handler(...args);
            return result?.timeoutSeconds > 0 ? undefined : result;
          });
        },
      });
    },
  };
}

let walk = null;
let ids = 0;
const post = (state, message) => parentPort.postMessage({ ...message, walk: state.id });

const methods = {
  async open({ id, dir }) {
    const requests = new Map();
    const calls = new Map();
    const claims = new Set();
    const renewals = new Set();
    const state = { id, requests, calls, frozen: false, renewals };
    const queueWorld = durabilityKind === "queue" ? await queueWorldAt(dir, { queueLeases: true, maxDurationMs: 600_000 }) : null;
    const stored = leasedWorld ? leasedWorld(dir) : durabilityKind === "world" ? await appWorldAt(dir) : durabilityKind === "vercel" ? vercelStorage({ dir }) : queueWorld ? queueWorld.durability : local({ dir });
    const postHeld = () => {
      if (walk === state) post(state, { type: "held", held: state.writes.held.map((entry) => ({ k: entry.k, holder: entry.holder ?? null, renewal: renewals.has(entry) })) });
    };
    const [durability, writes] = holdWrites(withoutBackstops(stored), (entry) => {
      queueMicrotask(postHeld);
      if (entry.k === "record") {
        if (!runsAhead) return false;
        return intentCallIds(entry).filter((callId) => announced.claim(callId)).length > 0;
      }
      if (entry.k !== "lease") return false;
      if (!claims.has(entry.holder)) {
        claims.add(entry.holder);
        return true;
      }
      if (!state.frozen) return false;
      renewals.add(entry);
      return true;
    });
    state.writes = writes;
    state.broker = queueWorld?.broker ?? null;
    state.postHeld = postHeld;
    state.agent = createFxAgent({
      ...(observedHooks ? { hooks: observedHooks } : {}),
      backend,
      nativeAddon: addon,
      ...(wasm ? { wasm } : {}),
      apiKey: "model-key",
      model: "model/test",
      async fetch(input, init) {
        const request = input instanceof Request ? input : new Request(input, init);
        if (request.method === "GET") return Response.json({ object: "list", data: [{ id: "model/test", type: "language" }] });
        const prompt = JSON.parse(await request.text()).prompt;
        const signal = init?.signal ?? request.signal;
        return new Promise((resolveResponse, rejectResponse) => {
          const requestId = (ids += 1);
          requests.set(requestId, (frames) => resolveResponse(sse(frames)));
          post(state, { type: "request", id: requestId, kind: toolResults(prompt).length > 0 ? "model2" : "model1" });
          signal?.addEventListener("abort", () => {
            if (requests.delete(requestId)) post(state, { type: "request-gone", id: requestId });
            rejectResponse(signal.reason ?? new Error("aborted"));
          }, { once: true });
        });
      },
      tools: [{
        name: tool,
        description: { send: "Sends an invoice", write: "Saves a key", lookup: "Looks up a key" }[tool],
        ...toolFlags,
        inputSchema: { type: "object", properties: { key: { type: "string" } } },
        execute: (input, { signal, executionId }) => new Promise((resolveCall, rejectCall) => {
          const callId = (ids += 1);
          calls.set(callId, () => resolveCall(`value of ${input.key}`));
          post(state, { type: "call", id: callId, executionId });
          signal?.addEventListener("abort", () => {
            if (calls.delete(callId)) post(state, { type: "call-gone", id: callId });
            rejectCall(signal.reason ?? new Error("aborted"));
          }, { once: true });
        }),
      }],
      durability,
      onEvent: (event) => {
        if (event.type === "session.fenced" || !/^(acp|transport)\./.test(event.type)) {
          post(state, { type: "event", event: event.type, error: event.error ? JSON.stringify(event.error) : null });
        }
      },
    });
    walk = state;
  },
  answer({ id, frames }) {
    const resolveRequest = walk?.requests.get(id);
    walk?.requests.delete(id);
    resolveRequest?.(frames);
  },
  end({ id }) {
    const resolveCall = walk?.calls.get(id);
    walk?.calls.delete(id);
    resolveCall?.();
  },
  async prompt({ text, messageId }) {
    const turn = walk.agent.session().prompt(text, { messageId });
    void turn.result.catch(() => {});
    return (await turn.accepted).sessionId;
  },
  resume({ sessionId }) {
    void walk.agent.session(sessionId).resume().result.catch(() => {});
  },
  async leaseHolder({ sessionId }) {
    return (await walk.agent[durableInternals].lastLease(sessionId))?.holder ?? null;
  },
  liveWorkers: () => walk.agent[durableInternals].liveWorkers(),
  leaseStands: ({ sessionId }) => walk.agent[durableInternals].leaseStands(sessionId),
  stopAtDeadline({ sessionId }) {
    walk.agent[durableInternals].stopAtDeadline(sessionId);
  },
  async releaseHeld({ settle = true } = {}) {
    const settled = walk.writes.releaseHeld();
    walk.postHeld();
    if (!settle) return;
    await settled;
    walk.postHeld();
  },
  async claim() {
    const holder = walk.writes.held.filter((entry) => entry.k === "lease").at(-1)?.holder ?? null;
    const before = [...globalThis[Symbol.for("libfx.liveHolders")]];
    await methods.releaseHeld();
    return { holder, before };
  },
  freeze() {
    walk.frozen = true;
  },
  async wake({ leased }) {
    walk.frozen = false;
    if (!leased || walk.renewals.size === 0) return false;
    walk.renewals.clear();
    await methods.releaseHeld();
    return true;
  },
  lapsed({ sessionId }) {
    return walk.broker.held((input) => input.sessionId === sessionId).filter((message) => message.attempt > 0).at(-1) ?? null;
  },
  adopt({ message }) {
    walk.broker.adopt(message);
  },
  async stream({ sessionId, cursor = 0 }) {
    const reader = walk.agent.session(sessionId).stream(cursor).getReader();
    const decoder = new TextDecoder();
    const lines = [];
    let buffered = "";
    for (;;) {
      let timer;
      const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), streamQuietMs); });
      const { value, done } = await Promise.race([reader.read(), quiet]);
      clearTimeout(timer);
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
        lines.push(JSON.parse(buffered.slice(0, index)));
        buffered = buffered.slice(index + 1);
      }
    }
    await reader.cancel().catch(() => {});
    return lines;
  },
  async close() {
    const state = walk;
    if (!state) return;
    walk = null;
    state.writes.release();
    for (const resolveRequest of state.requests.values()) resolveRequest([{ type: "error", errorText: "walk over" }]);
    for (const resolveCall of state.calls.values()) resolveCall();
    state.requests.clear();
    state.calls.clear();
    await Promise.race([state.agent.close().catch(() => {}), sleep(3000)]);
    await closeAppWorlds?.();
    await closeQueueWorlds?.();
  },
  hooksSeen: () => hooksSeen,
};

parentPort.on("message", async ({ id, method, args }) => {
  try {
    parentPort.postMessage({ type: "result", id, value: await methods[method](args ?? {}) });
  } catch (error) {
    parentPort.postMessage({ type: "result", id, error: { message: `${w}.${method}: ${String(error?.stack ?? error)}`, code: error?.code } });
  }
});
