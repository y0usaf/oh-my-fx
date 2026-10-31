#!/usr/bin/env bun
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent } from "../../../sdk/node.js";
import { local } from "../../../sdk/durable/local.mjs";
import { loadGraph } from "./graph.mjs";
import { testHooks } from "../../../sdk/tests/hooks-fixture.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const graphName = args.find((arg) => ["ideal", "faults"].includes(arg)) ?? "ideal";
const walks = Number(option("walks", 30));
const backend = option("backend", "native");
const durabilityKind = option("durability", "local");
if (!["local", "world"].includes(durabilityKind)) throw new Error("--durability is local or world");
const verbose = args.includes("--verbose");
let seed = Number(option("seed", 1));
const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const { appWorldAt, closeAppWorlds } = durabilityKind === "world" ? await import("../../../sdk/tests/app-world.mjs") : {};
const durableInternals = Symbol.for("libfx.durableInternals");
const stepTimeoutMs = 8000;
const quietMs = 250;
const inputMs = 400;

const textOf = (m) => (m === "p" ? "prompt p" : `steer ${m}`);
const messageIn = (text) => /\b(?:prompt (p)|steer (s\d+))\b/.exec(text)?.slice(1).find(Boolean) ?? null;
const steering = (text) => text.startsWith("<user_steering>");

const sorted = (items) => [...items].sort();
const view = (state) => {
  const turns = state.turns.filter((turn) => turn.state !== "waiting");
  const placed = new Set(turns.flatMap((turn) => turn.ctx));
  return JSON.stringify({
    turns: turns.map((turn) => ({ owner: turn.owner, state: turn.state, ctx: sorted(turn.ctx) })),
    phase: state.phase,
    twice: sorted(state.dup.filter((m) => placed.has(m))),
  });
};
const sameAct = (a, b) => a.name === b.name && a.m === b.m;

const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const encoder = new TextEncoder();
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));
const until = async (check, ms = stepTimeoutMs) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) return false;
    await sleep(5);
  }
  return true;
};

function gatedDeliveries(durability, gate) {
  return {
    ...durability,
    async world() {
      const world = await durability.world();
      return new Proxy(world, {
        get(target, key) {
          const value = Reflect.get(target, key);
          if (key !== "createQueueHandler") return typeof value === "function" ? value.bind(target) : value;
          return (prefix, handler) => value.call(target, prefix, async (...handlerArgs) => {
            await gate.wait();
            const result = await handler(...handlerArgs);
            return result?.timeoutSeconds > 0 ? undefined : result;
          });
        },
      });
    },
  };
}

async function harness() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-steer-model-"));
  const requests = [];
  const open = [];
  const calls = [];
  let toolCalls = 0;
  let sessionId = null;
  let session = null;
  const remove = (list, entry) => {
    const index = list.indexOf(entry);
    if (index >= 0) list.splice(index, 1);
  };
  const gate = {
    held: [],
    open: false,
    wait() { return gate.open ? Promise.resolve() : new Promise((go) => gate.held.push(go)); },
    release() { for (const go of gate.held.splice(0)) go(); },
  };
  const stored = durabilityKind === "world" ? await appWorldAt(dir) : local({ dir });
  const durability = gatedDeliveries(stored, gate);
  const agent = createFxAgent({
    ...(testHooks ? { hooks: testHooks } : {}),
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
      const users = prompt.filter((message) => message.role === "user").map((message) => (typeof message.content === "string"
        ? message.content
        : message.content.filter((part) => part.type === "text").map((part) => part.text).join("")));
      let controller;
      const body = new ReadableStream({ start(stream) { controller = stream; } });
      const entry = {
        users,
        phase: "gen",
        aborted: false,
        send(frames) {
          for (const frame of frames) controller.enqueue(encoder.encode(`data: ${JSON.stringify(frame)}\n\n`));
        },
        end(frames) {
          this.send(frames);
          controller.enqueue(encoder.encode("data: [DONE]\n\n"));
          controller.close();
          remove(open, this);
        },
      };
      requests.push(entry);
      open.push(entry);
      signal?.addEventListener("abort", () => {
        entry.aborted = true;
        remove(open, entry);
        try { controller.error(signal.reason ?? new Error("aborted")); } catch {}
      }, { once: true });
      entry.send([{ type: "text-delta", id: "reply", delta: "w " }]);
      return new Response(body, { headers: { "content-type": "text/event-stream" } });
    },
    tools: [{
      name: "lookup",
      description: "Looks up a key",
      idempotent: true,
      inputSchema: { type: "object", properties: { key: { type: "string" } } },
      execute: (toolInput, { signal }) => new Promise((resolveCall, rejectCall) => {
        const entry = { aborted: false, end: () => { remove(calls, entry); resolveCall(`value of ${toolInput.key}`); } };
        calls.push(entry);
        signal?.addEventListener("abort", () => { entry.aborted = true; remove(calls, entry); rejectCall(signal.reason ?? new Error("aborted")); }, { once: true });
      }),
    }],
    durability,
  });

  async function streamLines() {
    if (!sessionId) return [];
    const reader = agent.session(sessionId).stream(0).getReader();
    const decoder = new TextDecoder();
    const lines = [];
    let buffered = "";
    for (;;) {
      let timer;
      const quiet = new Promise((resolveQuiet) => { timer = setTimeout(() => resolveQuiet({ done: true }), 120); });
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
  }

  async function read() {
    const lines = await streamLines();
    const ownerOf = new Map();
    const ended = new Map();
    for (const line of lines) {
      if (line.type === "turn_start") ownerOf.set(line.messageId, messageIn(line.input ?? ""));
      if (line.type === "turn_end") ended.set(line.messageId, line.stopReason === "cancelled" ? "cancelled" : "end");
    }
    const stateOf = new Map();
    for (const [messageId, owner] of ownerOf) if (owner) stateOf.set(owner, ended.get(messageId) ?? "running");
    const turns = [];
    const counts = new Map();
    for (const text of requests.at(-1)?.users ?? []) {
      const m = messageIn(text);
      if (!m) continue;
      counts.set(m, (counts.get(m) ?? 0) + 1);
      if (stateOf.has(m) && !steering(text) && !turns.some((turn) => turn.owner === m)) turns.push({ owner: m, ctx: new Set([m]) });
      else turns.at(-1)?.ctx.add(m);
    }
    const phase = calls.length > 0 ? "tool" : open.length > 0 ? open.at(-1).phase : "idle";
    return JSON.stringify({
      turns: turns.map((turn) => ({ owner: turn.owner, state: stateOf.get(turn.owner) ?? "running", ctx: sorted(turn.ctx) })),
      phase,
      twice: sorted([...counts].filter(([, count]) => count > 1).map(([m]) => m)),
    });
  }

  async function observe() {
    let seen = await read();
    const started = Date.now();
    for (;;) {
      await sleep(quietMs);
      const again = await read();
      if (again === seen) break;
      seen = again;
      if (Date.now() - started > stepTimeoutMs) break;
    }
    if (verbose) {
      for (const [index, request] of requests.entries()) {
        const sent = request.users.map((text) => `${steering(text) ? "~" : ""}${messageIn(text) ?? "?"}`).join(" ");
        console.log(`    request ${index + 1}: ${sent}${request.aborted ? " (aborted)" : ""}${open.includes(request) ? ` (open, ${request.phase})` : ""}`);
      }
    }
    return seen;
  }

  async function performInput({ name, m }) {
    if (name === "Cancel") {
      await session.cancel();
    } else if (m === "p") {
      session = agent.session();
      const turn = session.prompt(textOf("p"), { messageId: "p" });
      void turn.result.catch(() => {});
      sessionId = (await turn.accepted).sessionId;
      await until(() => gate.held.length > 0);
    } else {
      await session.steer(textOf(m), { messageId: m });
    }
  }

  async function perform({ name, m }) {
    if (name === "Send" || name === "Retry" || name === "Cancel") {
      await performInput({ name, m });
      await sleep(inputMs);
      return;
    }
    if (name === "Start") {
      gate.release();
      await until(() => open.length > 0);
    } else if (name === "ModelText") {
      open.at(-1).end([{ type: "text-delta", id: "reply", delta: "done" }, finish("stop")]);
    } else if (name === "ToolArgs") {
      const request = open.at(-1);
      toolCalls += 1;
      request.toolId = `call-${toolCalls}`;
      request.phase = "args";
      request.send([
        { type: "tool-input-start", id: request.toolId, toolName: "lookup" },
        { type: "tool-input-delta", id: request.toolId, delta: "{\"key\":\"al" },
      ]);
    } else if (name === "ToolCall") {
      const request = open.at(-1);
      request.end([
        { type: "tool-input-delta", id: request.toolId, delta: "pha\"}" },
        { type: "tool-input-end", id: request.toolId },
        { type: "tool-call", toolCallId: request.toolId, toolName: "lookup", input: { key: "alpha" } },
        finish("tool-calls"),
      ]);
      await until(() => calls.length > 0);
    } else if (name === "ToolEnd") {
      calls[0].end();
      await until(() => open.length > 0);
    } else if (name === "Handoff") {
      const before = requests.length;
      agent[durableInternals].stopAtDeadline(sessionId);
      await until(() => {
        gate.release();
        return requests.length > before && open.length > 0;
      });
    } else {
      throw new Error(`no driver step for ${name}`);
    }
  }

  async function close() {
    gate.open = true;
    gate.release();
    for (const entry of [...open]) {
      try { entry.end([{ type: "error", errorText: "walk over" }]); } catch {}
    }
    for (const entry of [...calls]) entry.end();
    await Promise.race([agent.close().catch(() => {}), sleep(3000)]);
    await closeAppWorlds?.();
    await rm(dir, { recursive: true, force: true });
  }

  return { perform, observe, close };
}

const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

const graph = await loadGraph(resolve(here, "../sdk/graphs", `steer-${graphName}.dot`));
const covered = new Set();
const totalEdges = [...graph.next.values()].reduce((sum, targets) => sum + targets.size, 0);
let steps = 0;
const successors = (id) => [...(graph.next.get(id) ?? [])].filter((to) => to !== id);
const actOf = (id) => graph.states.get(id).act;

for (let walk = 1; walk <= walks; walk += 1) {
  const code = await harness();
  const path = [];
  let current = new Set([graph.init]);
  try {
    for (;;) {
      const options = [];
      for (const from of current) {
        for (const to of successors(from)) {
          const act = actOf(to);
          let entry = options.find((item) => sameAct(item.act, act));
          if (!entry) options.push(entry = { act, fresh: false });
          if (!covered.has(`${from}>${to}`)) entry.fresh = true;
        }
      }
      if (options.length === 0) break;
      const fresh = options.filter((entry) => entry.fresh);
      const pool = fresh.length > 0 ? fresh : options;
      const { act } = pool[Math.floor(random() * pool.length)];
      const label = `${act.name}${act.m === "none" ? "" : `(${act.m})`}`;
      if (verbose) console.log(`walk ${walk}: ${label}`);
      await code.perform(act);
      const seen = await code.observe();
      if (verbose) console.log(`  shows ${seen}`);
      path.push(label);
      steps += 1;
      const next = new Set();
      const allowed = new Set();
      for (const from of current) {
        for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
          const shown = view(graph.states.get(to));
          allowed.add(shown);
          if (shown !== seen) continue;
          next.add(to);
          covered.add(`${from}>${to}`);
        }
      }
      if (next.size === 0) {
        console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
        console.error(`  the code shows   ${seen}`);
        for (const shown of allowed) console.error(`  the model allows ${shown}`);
        process.exitCode = 1;
        break;
      }
      current = next;
    }
  } catch (error) {
    console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${error.stack ?? error.message}`);
    process.exitCode = 1;
  } finally {
    await code.close();
  }
  if (process.exitCode) break;
  if (walk % 10 === 0 || walk === walks) console.log(`${walk} walks, ${steps} steps, ${covered.size} of ${totalEdges} edges`);
}
if (!process.exitCode) console.log(`ok steer-${graphName}: ${walks} walks, ${steps} steps matched the model; ${covered.size} of ${totalEdges} edges covered (${backend})`);
process.exit(process.exitCode ?? 0);
