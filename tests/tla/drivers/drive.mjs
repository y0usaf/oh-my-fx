#!/usr/bin/env bun
import { strict as assert } from "node:assert";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Worker } from "node:worker_threads";
import { loadGraph } from "./graph.mjs";
import { sharedSet, sharedSetBuffer } from "./shared-set.mjs";

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const graphName = args.find((arg) => ["send", "lookup", "write", "cutoff", "leased", "queue"].includes(arg)) ?? "send";
const tool = graphName === "cutoff" ? "lookup" : graphName === "leased" || graphName === "queue" ? "send" : graphName;
const toolFlags = { lookup: { idempotent: true }, write: { idempotent: true, writes: true }, send: { idempotent: false } }[tool];
const runsAhead = tool === "lookup";
const walks = Number(option("walks", 40));
const backend = option("backend", "native");
const leased = graphName === "leased";
const durabilityKind = option("durability", leased ? "leased" : graphName === "queue" ? "queue" : "local");
if (!["local", "world", "vercel", "leased", "queue"].includes(durabilityKind)) throw new Error("--durability is local, world or vercel");
if (leased !== (durabilityKind === "leased")) throw new Error("the leased graph runs on its own World, and only it does");
if ((graphName === "queue") !== (durabilityKind === "queue")) throw new Error("the queue graph runs on its own World, and only it does");
const leaseMs = 1000;
const remote = durabilityKind === "vercel";
const settleMs = remote ? 1500 : 60;
const streamQuietMs = remote ? 2500 : 120;
const stepTimeoutMs = remote ? 30_000 : 5000;
const queued = durabilityKind === "queue";
const hooks = args.includes("--hooks") || process.env.LIBFX_TEST_HOOKS === "1";
const verbose = args.includes("--verbose");
let seed = Number(option("seed", 1));
const here = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(here, "../../../zig-out/lib/libfx.node");
const wasm = backend === "wasm" ? await readFile(resolve(here, "../../../zig-out/bin/fx-core.wasm")) : undefined;
const Workers = ["A", "B"];

const shownEpochs = (lines) => {
  let high = 0;
  const shown = [];
  for (const line of lines) {
    if (line.e < high) continue;
    high = line.e;
    shown.push(line.e);
  }
  return shown;
};
const view = (state) => JSON.stringify({
  pc: state.pc, frozen: state.frozen, runs: state.runs, ids: state.ids, ui: shownEpochs(state.ui), ...(leased ? { live: state.live ?? state.lease.live } : {}),
});
const sameAct = (a, b) => a.name === b.name && a.w === b.w;

const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };
const finish = (reason) => ({ type: "finish", finishReason: { unified: reason, raw: reason }, usage });
const modeledLines = new Set(["turn_start", "turn_resume", "tool_start", "tool_end", "text_delta", "turn_yield", "turn_end"]);
const until = async (check, ms = stepTimeoutMs) => {
  const started = Date.now();
  while (!(await check())) {
    if (Date.now() - started > ms) return false;
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
  }
  return true;
};
const sleep = (ms) => new Promise((resolveWait) => setTimeout(resolveWait, ms));

const liveBuffer = sharedSetBuffer();
const announcedBuffer = sharedSetBuffer();
const liveHolders = sharedSet(liveBuffer);
const announced = sharedSet(announcedBuffer);

let walkId = 0;
let report = null;
let callCount = 0;
const pending = new Map();
const servers = {};
for (const w of Workers) {
  const server = new Worker(new URL("./session-process.mjs", import.meta.url), {
    workerData: { w, liveBuffer, announcedBuffer, tool, toolFlags, runsAhead, durabilityKind, leaseMs, streamQuietMs, backend, addon, wasm, hooks },
    ...(hooks ? { argv: ["--hooks"] } : {}),
  });
  server.on("message", (message) => {
    if (message.type !== "result") {
      if (message.walk === walkId) report?.(w, message);
      return;
    }
    const call = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) call?.reject(Object.assign(new Error(message.error.message), { code: message.error.code }));
    else call?.resolve(message.value);
  });
  server.on("error", (error) => {
    console.error(`FAIL server ${w}: ${error?.stack ?? error}`);
    process.exit(1);
  });
  servers[w] = server;
}
const call = (w, method, args = {}) => new Promise((resolveCall, rejectCall) => {
  callCount += 1;
  pending.set(callCount, { resolve: resolveCall, reject: rejectCall });
  servers[w].postMessage({ id: callCount, method, args });
});
const tell = (w, method, args) => {
  call(w, method, args).catch((error) => console.error(`server ${w}: ${error.message}`));
};

async function harness() {
  const dir = await mkdtemp(join(tmpdir(), "libfx-model-"));
  walkId += 1;
  liveHolders.clear();
  announced.clear();
  const requests = [];
  const calls = [];
  const fenced = { A: 0, B: 0 };
  const holders = { A: [], B: [] };
  const claimed = { A: null, B: null };
  const frozen = { A: false, B: false };
  const held = { A: [], B: [] };
  const lapsed = { A: null, B: null };
  let runs = 0;
  const executions = new Set();
  let modelCalls = 0;
  const events = [];
  let sessionId = null;
  const remove = (list, entry) => {
    const index = list.indexOf(entry);
    if (index >= 0) list.splice(index, 1);
  };
  report = (w, message) => {
    if (message.type === "held") held[w] = message.held;
    else if (message.type === "request") requests.push({ w, id: message.id, kind: message.kind });
    else if (message.type === "request-gone") remove(requests, requests.find((entry) => entry.w === w && entry.id === message.id));
    else if (message.type === "call") {
      runs += 1;
      executions.add(message.executionId);
      calls.push({ w, id: message.id });
    } else if (message.type === "call-gone") remove(calls, calls.find((entry) => entry.w === w && entry.id === message.id));
    else if (message.type === "event") {
      if (message.event === "session.fenced") fenced[w] += 1;
      if (!/^(acp|transport)\./.test(message.event)) events.push(`${w}:${message.event}${message.error ? `:${message.error}` : ""}`);
    }
  };
  for (const w of Workers) await call(w, "open", { id: walkId, dir });
  const answer = (entry, frames) => {
    remove(requests, entry);
    tell(entry.w, "answer", { id: entry.id, frames });
  };
  const end = (entry) => {
    remove(calls, entry);
    tell(entry.w, "end", { id: entry.id });
  };
  const leaseHolder = (w) => call(w, "leaseHolder", { sessionId });
  const liveWorkers = (w) => call(w, "liveWorkers");

  const streamLines = (cursor = 0) => (sessionId ? call("A", "stream", { sessionId, cursor }) : []);

  const position = (w, lines) => {
    if (held[w].some((entry) => entry.k === "lease" && !entry.renewal)) return "early";
    if (claimed[w] === null) return "none";
    if (fenced[w] > claimed[w].fenced) return "stopped";
    if (lines.some((line) => line.type === "turn_end" && line.epoch === claimed[w].epoch)) return "done";
    const request = requests.find((entry) => entry.w === w);
    if (request) return request.kind;
    if (calls.some((entry) => entry.w === w)) return held[w].some((entry) => entry.k === "record") ? "ahead" : "tool";
    return "busy";
  };
  const waiting = (w) => requests.some((entry) => entry.w === w) || calls.some((entry) => entry.w === w);
  const newHolders = (before) => [...liveHolders].filter((holder) => !before.has(holder));

  async function observe() {
    let lines = await streamLines();
    for (let reads = 0; reads < 5; reads += 1) {
      const again = await streamLines();
      if (JSON.stringify(again) === JSON.stringify(lines)) break;
      lines = again;
    }
    if (lines.length > 0) {
      const cursor = lines[Math.floor(random() * lines.length)].cursor;
      const again = await streamLines(cursor);
      const expected = lines.filter((line) => line.cursor > cursor);
      if (JSON.stringify(again) !== JSON.stringify(expected)) {
        const brief = (items) => items.map((line) => `${line.type}:e${line.epoch ?? 0}@${line.cursor}`).join(" ");
        const now = await streamLines();
        assert.fail([
          `reconnecting from cursor ${cursor} shows different lines`,
          `  first read: ${brief(lines)}`,
          `  reconnect:  ${brief(again)}`,
          `  read again: ${brief(now)}`,
          `  waiting: requests ${JSON.stringify(requests.map((entry) => `${entry.w}:${entry.kind}`))}, calls ${JSON.stringify(calls.map((entry) => entry.w))}, runs ${runs}, fenced ${JSON.stringify(fenced)}`,
        ].join("\n"));
      }
    }
    return {
      pc: Object.fromEntries(Workers.map((w) => [w, position(w, lines)])),
      frozen: { ...frozen },
      runs,
      ids: executions.size,
      ui: lines.filter((line) => modeledLines.has(line.type)).map((line) => line.epoch ?? 0),
      ...(leased ? { live: sessionId ? await call("A", "leaseStands", { sessionId }) : false } : {}),
    };
  }

  async function perform({ name, w }, expectedEpoch) {
    const stopped = () => claimed[w] !== null && fenced[w] > claimed[w].fenced;
    if (name === "Start") {
      const before = new Set(liveHolders);
      const head = sessionId ? await leaseHolder(w) : null;
      const handedOn = Workers.find((v) => v !== w && lapsed[v] && holders[v].includes(head));
      if (!sessionId) {
        sessionId = await call(w, "prompt", { text: `use ${tool}`, messageId: "turn-1" });
      } else if (handedOn) {
        await call(w, "adopt", { message: lapsed[handedOn] });
        lapsed[handedOn] = null;
      } else {
        await call(w, "resume", { sessionId });
      }
      await until(() => held[w].length > 0);
      holders[w] = newHolders(before);
    } else if (name === "Claim") {
      const landed = await call(w, "claim");
      assert.ok(landed.holder, `${w} has a claim to land`);
      const before = new Set(landed.before);
      const holds = async () => (await leaseHolder(w)) === landed.holder;
      await until(async () => (await holds()) || held[w].length > 0 || (await liveWorkers(w)) === 0);
      if (await holds()) {
        claimed[w] = { fenced: fenced[w], epoch: expectedEpoch };
        await until(() => waiting(w) || stopped());
      } else {
        await until(async () => held[w].length > 0 || (await liveWorkers(w)) === 0);
        holders[w] = newHolders(before);
        claimed[w] = null;
      }
    } else if (name === "Model1" || name === "Model2") {
      const request = requests.find((entry) => entry.w === w);
      assert.ok(request, `${w} has a model request to answer`);
      answer(request, name === "Model1"
        ? [{ type: "tool-call", toolCallId: `call-${(modelCalls += 1)}`, toolName: tool, input: { key: "alpha" } }, finish("tool-calls")]
        : [{ type: "text-delta", id: "answer", delta: "done" }, finish("stop")]);
      if (name === "Model1") await until(() => calls.some((entry) => entry.w === w) || stopped());
      else await until(async () => stopped() || (await streamLines()).some((line) => line.type === "turn_end" && line.epoch === claimed[w].epoch));
    } else if (name === "Intent") {
      await call(w, "releaseHeld");
      const head = await leaseHolder(w);
      if (!holders[w].includes(head)) await until(() => stopped());
    } else if (name === "ToolEnd") {
      const entry = calls.find((item) => item.w === w);
      assert.ok(entry, `${w} has a tool call to end`);
      end(entry);
      await until(() => requests.some((item) => item.w === w && item.kind === "model2") || stopped());
    } else if (name === "Freeze") {
      frozen[w] = true;
      await call(w, "freeze");
      for (const holder of holders[w]) liveHolders.delete(holder);
      if (leased) await sleep(leaseMs + 400);
      if (queued && holders[w].includes(await leaseHolder(w))) {
        lapsed[w] = await call(w, "lapsed", { sessionId });
      }
    } else if (name === "Wake") {
      frozen[w] = false;
      if (await call(w, "wake", { leased })) {
        const head = await leaseHolder(w);
        if (claimed[w] && !holders[w].includes(head)) await until(() => stopped());
      }
    } else if (name === "Deadline") {
      const before = new Set(liveHolders);
      const fencedBefore = fenced[w];
      await call(w, "stopAtDeadline", { sessionId });
      const reclaimed = () => [...liveHolders].some((holder) => !before.has(holder));
      const ended = async () => (await streamLines()).some((line) => line.type === "turn_end" && line.epoch === expectedEpoch);
      let took = false;
      await until(async () => {
        if (held[w].length > 0) await call(w, "releaseHeld", { settle: false });
        if (reclaimed()) took = true;
        if (held[w].length > 0) return false;
        if (took && waiting(w)) return true;
        if (await ended()) return (took = true);
        return fenced[w] > fencedBefore;
      });
      if (took) {
        claimed[w] = { fenced: fenced[w], epoch: expectedEpoch };
        holders[w] = [...liveHolders].filter((holder) => !before.has(holder));
      }
    }
    await sleep(settleMs);
  }

  async function close() {
    await Promise.all(Workers.map((w) => call(w, "close").catch(() => {})));
    report = null;
    await rm(dir, { recursive: true, force: true });
  }

  async function describe() {
    const lines = await streamLines();
    return [
      `  stream: ${lines.map((line) => `${line.type}:e${line.epoch ?? 0}${line.toolCallId ? `:${line.toolCallId}` : ""}`).join(" ")}`,
      ...lines.filter((line) => line.type === "turn_end").map((line) => `  ${JSON.stringify(line).slice(0, 400)}`),
      `  waiting: requests ${JSON.stringify(requests.map((entry) => `${entry.w}:${entry.kind}`))}, calls ${JSON.stringify(calls.map((entry) => entry.w))}, held ${JSON.stringify(Object.fromEntries(Workers.map((w) => [w, held[w].map((entry) => entry.k)])))}, fenced ${JSON.stringify(fenced)}`,
      `  events: ${events.slice(-30).join(" ")}`,
    ].join("\n");
  }

  return { perform, observe, close, describe };
}

const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};

const graph = await loadGraph(resolve(here, "../sdk/graphs", `${graphName}.dot`));
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
          if (act.name === "Announce") continue;
          if (act.name === "Deadline" && graph.states.get(to).pc[act.w] === "none") continue;
          let option = options.find((item) => sameAct(item.act, act));
          if (!option) options.push(option = { act, fresh: false });
          if (!covered.has(`${from}>${to}`)) option.fresh = true;
        }
      }
      if (options.length === 0) break;
      const fresh = options.filter((option) => option.fresh);
      const pool = fresh.length > 0 ? fresh : options;
      const { act } = pool[Math.floor(random() * pool.length)];
      const expectedEpoch = act.name === "Claim" || act.name === "Deadline"
        ? Math.max(...[...current].flatMap((from) => successors(from).filter((to) => sameAct(actOf(to), act)).map((to) => graph.states.get(to).epoch[act.w])))
        : undefined;
      if (verbose) console.log(`walk ${walk}: ${act.name}(${act.w})`);
      await code.perform(act, expectedEpoch);
      path.push(`${act.name}(${act.w})`);
      steps += 1;
      const allowed = new Set();
      const reached = new Map();
      for (const from of current) {
        for (const to of successors(from).filter((id) => sameAct(actOf(id), act))) {
          const ends = graph.states.get(to).pc[act.w] === "announce"
            ? successors(to).filter((id) => sameAct(actOf(id), { name: "Announce", w: act.w })).map((id) => [to, id])
            : [[null, to]];
          for (const [middle, end] of ends) {
            const shown = view(graph.states.get(end));
            allowed.add(shown);
            if (!reached.has(shown)) reached.set(shown, []);
            reached.get(shown).push({ from, middle, end });
          }
        }
      }
      let seen = JSON.stringify(await code.observe());
      for (let look = 0; !reached.has(seen) && look < 10; look += 1) {
        await sleep(100);
        seen = JSON.stringify(await code.observe());
      }
      if (verbose) console.log(`  shows ${seen}`);
      const next = new Set();
      for (const { from, middle, end } of reached.get(seen) ?? []) {
        next.add(end);
        covered.add(`${from}>${middle ?? end}`);
        if (middle) covered.add(`${middle}>${end}`);
      }
      if (next.size === 0) {
        console.error(`FAIL walk ${walk} after ${path.join(" ")}`);
        console.error(`  the code shows   ${seen}`);
        for (const view of allowed) console.error(`  the model allows ${view}`);
        console.error(await code.describe());
        process.exitCode = 1;
        break;
      }
      current = next;
    }
  } catch (error) {
    console.error(`FAIL walk ${walk} after ${path.join(" ")}: ${error.message}`);
    process.exitCode = 1;
  } finally {
    await code.close();
  }
  if (process.exitCode) break;
  if (walk % 25 === 0 || walk === walks) console.log(`${walk} walks, ${steps} steps, ${covered.size} of ${totalEdges} edges`);
}
if (hooks && !process.exitCode) {
  const seen = await Promise.all(Workers.map((w) => call(w, "hooksSeen")));
  const errors = seen.flatMap((counts) => counts.errors);
  if (errors.length > 0 || seen.every((counts) => counts.events === 0)) {
    console.error(`FAIL hooks: ${errors.length > 0 ? errors.join("\n") : "hooks-enabled conformance run observed no events"}`);
    process.exitCode = 1;
  }
}
if (!process.exitCode) console.log(`ok ${graphName}: ${walks} walks, ${steps} steps matched the model; ${covered.size} of ${totalEdges} edges covered (${backend})`);
process.exit(process.exitCode ?? 0);
