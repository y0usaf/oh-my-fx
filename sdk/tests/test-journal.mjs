#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxEngine, createMemoryPersistence, FxFencedError, FxJournalVersionError } from "../node.js";

const sourceBackend = process.argv[2] || "native";
const targetBackend = process.argv[3] || "wasm";
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const addon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const wasm = await readFile(resolve(scriptDir, "../../zig-out/bin/fx-core.wasm"));
const usage = { inputTokens: { total: 1 }, outputTokens: { total: 1 } };

const textOf = (message) => typeof message.content === "string"
  ? message.content
  : message.content.filter((part) => part.type === "text").map((part) => part.text).join("");
const lastUserText = (prompt) => textOf(prompt.filter((message) => message.role === "user").at(-1));
const toolResults = (prompt) => prompt
  .flatMap((message) => Array.isArray(message.content) ? message.content : [])
  .filter((part) => part.type === "tool-result");

const encodeRecord = (events) => new TextEncoder().encode(JSON.stringify({ format: "libfx-journal-v1", events }));
const decodeRecord = (data) => JSON.parse(new TextDecoder().decode(data)).events;
const storedEvents = (store) => store.records.flatMap((record) => decodeRecord(record.data));

function eventJournal(initial = []) {
  const events = initial.map((event) => structuredClone(event));
  return {
    events,
    async append(batch) { events.push(...batch); },
    async load() { return { events: events.slice() }; },
  };
}

function persisted(journal) {
  const headOf = (events) => (events.length ? String(events.at(-1).seq) : null);
  return {
    async load() {
      const { events } = await journal.load();
      return { journal: events.length ? [{ cursor: headOf(events), data: encodeRecord(events) }] : [] };
    },
    async append({ expected, data }) {
      const batch = decodeRecord(data);
      if (journal.events && expected !== headOf(journal.events)) {
        throw new FxFencedError(`expected ${expected}, head ${headOf(journal.events)}`);
      }
      await journal.append(batch);
      return { cursor: String(batch.at(-1).seq) };
    },
  };
}

const bulkySteps = 24;
function framesFor(prompt) {
  const text = lastUserText(prompt);
  if (text === "keep using the tool") {
    const done = toolResults(prompt).length;
    if (done < 3) {
      return [
        { type: "tool-call", toolCallId: `call-keep-${done}`, toolName: "lookup", input: { key: "alpha" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
      ];
    }
    return [
      { type: "text-delta", id: "answer", delta: "kept at it" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
    ];
  }
  if (text === "explain and use the tool") {
    if (toolResults(prompt).length === 0) {
      return [
        { type: "text-delta", id: "note", delta: "Looking it up." },
        { type: "tool-call", toolCallId: "call-1", toolName: "lookup", input: { key: "alpha" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
      ];
    }
    return [
      { type: "text-delta", id: "answer", delta: "found it" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
    ];
  }
  if (text === "gather everything") {
    const done = toolResults(prompt).length;
    if (done < bulkySteps) {
      return [
        { type: "tool-call", toolCallId: `call-bulky-${done}`, toolName: "bulky", input: { part: done } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
      ];
    }
    return [
      { type: "text-delta", id: "answer", delta: "gathered" },
      { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
    ];
  }
  if (text === "use the tool" && toolResults(prompt).length === 0) {
    return [
      { type: "tool-call", toolCallId: "call-1", toolName: "lookup", input: { key: "alpha" } },
      { type: "finish", finishReason: { unified: "tool-calls", raw: "tool-calls" }, usage },
    ];
  }
  const answer = text === "use the tool" ? "tool said beta" : `answer to ${text}`;
  return [
    { type: "text-delta", id: "answer", delta: answer },
    { type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage },
  ];
}

const requests = [];
const sessionHeaders = [];
const server = createServer((request, response) => {
  let body = "";
  request.setEncoding("utf8");
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    if (request.method === "GET") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ object: "list", data: [{ id: "journal/model", type: "language" }] }));
      return;
    }
    const { prompt, toolChoice } = JSON.parse(body);
    Object.defineProperty(prompt, "sessionId", { value: request.headers["x-session-id"] });
    Object.defineProperty(prompt, "toolChoice", { value: toolChoice?.type ?? null });
    requests.push(prompt);
    sessionHeaders.push([request.headers["x-session-id"], request.headers["x-session-affinity"]]);
    if (lastUserText(prompt) === "fail please") {
      response.writeHead(400, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { message: "refused for the test", type: "invalid_request_error" } }));
      return;
    }
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(framesFor(prompt).map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("") + "data: [DONE]\n\n");
  });
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();
const loopbackFetch = (input, init) => {
  const url = new URL(String(input?.url ?? input));
  const method = String(init?.method ?? input?.method ?? "GET").toUpperCase();
  if (url.hostname === "ai-gateway.vercel.sh" && method === "GET") {
    return fetch(`http://127.0.0.1:${port}${url.pathname}${url.search}`, init);
  }
  return fetch(input, init);
};

const lookup = {
  name: "lookup",
  description: "Looks up a key",
  inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"] },
  execute: async ({ key }) => `value of ${key} is beta`,
};
const bulky = {
  name: "bulky",
  description: "Returns a large part",
  inputSchema: { type: "object", properties: { part: { type: "number" } } },
  execute: async ({ part }) => `${part}:${"x".repeat(60_000)}`,
};
const options = (backend, journal, extra = {}) => ({
  backend,
  nativeAddon: addon,
  ...(backend === "wasm" ? { wasm } : {}),
  fetch: loopbackFetch,
  apiKey: "journal-key",
  gatewayChatUrl: `http://127.0.0.1:${port}/chat`,
  model: "journal/model",
  tools: [lookup],
  ...(journal === undefined ? {} : { persistence: persisted(journal) }),
  ...extra,
});

async function run(agent, input) {
  const turn = agent.prompt(input);
  let text = "";
  for await (const update of turn) if (update.type === "text_delta") text += update.delta;
  return { text, result: await turn.result };
}

function assertTurn(events) {
  assert.ok(events.length >= 2, "a turn records progress and a commit");
  assert.ok(events.slice(0, -1).every((event) => event.type === "turn_progress" || event.type === "tool_intent" || event.type === "tool_result"));
  assert.equal(events[0].type, "turn_progress");
  assert.equal(events.at(-1).type, "turn_committed");
  assert.equal(events[0].data.consumed_provider_attempts, 0);
  assert.equal(events[0].data.assistant_source, "");
}

function assertContiguous(events) {
  let turn = 1;
  events.forEach((event, index) => {
    assert.equal(event.v, event.type === "tool_result" || event.base !== undefined ? 2 : 1, JSON.stringify(event).slice(0, 200));
    assert.equal(event.seq, index + 1, `event ${index} has seq ${event.seq}`);
    assert.equal(event.turn, turn, `event ${event.seq} has turn ${event.turn}`);
    if (event.type === "turn_committed") turn += 1;
  });
}

const cases = [];
const test = (name, body) => cases.push({ name, body });

test("a journaled session restores on another backend", async () => {
  const journal = eventJournal();
  const source = await createFxEngine(options(sourceBackend, journal));
  assert.equal((await run(source, "remember plums")).text, "answer to remember plums");
  await source.close();
  assertContiguous(journal.events);
  assertTurn(journal.events);
  assert.equal(journal.events.at(-1).data.kind, "assistant");
  const firstTurnEvents = journal.events.length;

  const target = await createFxEngine(options(targetBackend, journal));
  requests.length = 0;
  assert.equal((await run(target, "what did I say")).text, "answer to what did I say");
  await target.close();
  const said = (role, text) => requests[0].filter((message) => message.role === role && textOf(message).includes(text)).length;
  assert.equal(said("user", "remember plums"), 1, "restored turn appears once");
  assert.equal(said("assistant", "answer to remember plums"), 1, "restored answer appears once");
  assertContiguous(journal.events);
  const ownTurn = journal.events.slice(firstTurnEvents);
  assert.equal(ownTurn.length, firstTurnEvents);
  assertTurn(ownTurn);
});

test("a tool turn records progress before each model request", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  assert.equal((await run(agent, "use the tool")).text, "tool said beta");
  await agent.close();
  assertContiguous(journal.events);
  assertTurn(journal.events);
  const holding = (type) => journal.events.findIndex((event) => event.type === type && /value of alpha is beta/.test(JSON.stringify(event.data)));
  assert.ok(holding("tool_result") >= 0 && holding("turn_progress") > holding("tool_result"), JSON.stringify(journal.events.map((event) => event.type)));

  const restored = await createFxEngine(options(targetBackend, journal));
  requests.length = 0;
  await run(restored, "and now");
  await restored.close();
  assert.equal(toolResults(requests[0]).length, 1, "restored history keeps the tool result");
});

async function intentStoredAtStart(tool) {
  const stored = [];
  let previous = Promise.resolve();
  const journal = {
    append(batch) {
      const delay = new Promise((resolveDelay) => setTimeout(resolveDelay, 30));
      previous = Promise.all([previous, delay]).then(() => { stored.push(...batch); });
      return previous;
    },
    async load() { return { events: stored.slice() }; },
  };
  const seen = [];
  const send = {
    ...tool,
    execute: async (input, { executionId: callId }) => {
      seen.push(stored.some((event) => event.type === "tool_intent" && event.data.some((call) => call.id === callId)));
      return tool.execute(input);
    },
  };
  const agent = await createFxEngine(options(sourceBackend, journal, { tools: [send] }));
  assert.equal((await run(agent, "use the tool")).text, "tool said beta");
  await agent.close();
  assertContiguous(stored);
  assert.equal(seen.length, 1);
  return seen[0];
}

test("a tool call starts only after its intent is stored", async () => {
  assert.equal(await intentStoredAtStart(lookup), true, "the intent was durable when execute started");
});

test("an idempotent writer's call starts only after its intent is stored", async () => {
  assert.equal(await intentStoredAtStart({ ...lookup, idempotent: true, writes: true }), true, "the intent was durable when execute started");
});

test("an idempotent call that does not write starts before its intent is stored", async () => {
  assert.equal(await intentStoredAtStart({ ...lookup, idempotent: true }), false, "execute started while the intent was still on its way");
});

function slowStore() {
  const appends = [];
  let head = null;
  return {
    appends,
    events: () => appends.flatMap((append) => append.events),
    async load() { return {}; },
    async append({ expected, data, barrier }) {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 30));
      if (expected !== head) throw new FxFencedError(`expected ${expected}, head ${head}`);
      appends.push({ events: decodeRecord(data), barrier });
      head = String(appends.length);
      return { cursor: head };
    },
  };
}
const typesOf = (append) => append.events.map((event) => event.type);

test("events that arrive while an append is in flight go out as one record, and only waited-for records are barriers", async () => {
  for (const [tool, waits] of [[{ ...lookup, idempotent: true }, false], [{ ...lookup, idempotent: true, writes: true }, true], [lookup, true]]) {
    const store = slowStore();
    const agent = await createFxEngine(options(sourceBackend, undefined, { tools: [tool], persistence: store }));
    assert.equal((await run(agent, "use the tool")).text, "tool said beta");
    await agent.close();
    assertContiguous(store.events());
    assert.equal(store.appends[0].barrier, true);
    assert.equal(store.appends[0].events[0].type, "turn_progress");
    const shape = JSON.stringify(store.appends.map((append) => ({ barrier: append.barrier, events: typesOf(append) })));
    const intent = store.appends.find((append) => typesOf(append).includes("tool_intent"));
    const flags = JSON.stringify({ idempotent: tool.idempotent, writes: tool.writes });
    if (waits) assert.equal(intent.barrier, true, `the intent of ${flags} is a barrier: ${shape}`);
    else assert.ok(!intent.barrier || typesOf(intent).includes("turn_committed"), `the intent of ${flags} is no barrier: ${shape}`);
    assert.ok(store.appends.length < store.events().length && store.appends.some((append) => append.events.length > 1), shape);
  }
});

test("a progress after the turn's first carries only what is new, and folds back into the whole turn", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  assert.equal((await run(agent, "use the tool")).text, "tool said beta");
  await agent.close();
  const progress = journal.events.filter((event) => event.type === "turn_progress");
  assert.ok(progress.length >= 2, JSON.stringify(journal.events.map((event) => event.type)));
  assert.equal(progress[0].base, undefined, "a turn's first progress carries all of it");
  assert.ok(progress[0].data.user, "with the prompt");
  progress.slice(1).forEach((event, index) => {
    assert.equal(event.base, progress[index].seq, `progress ${event.seq} names the one it extends`);
    assert.equal(event.data.user, undefined, "and leaves out what that one holds");
  });
  const stepped = progress.find((event) => event.steps === 1);
  assert.equal(stepped.data.execution.tool_steps.length, 1, "the progress after the tool carries only its step");
  const survived = journal.events.slice(0, journal.events.indexOf(stepped) + 1);
  const resumed = await createFxEngine(options(targetBackend, eventJournal(survived)));
  requests.length = 0;
  const turn = resumed.resume();
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  await resumed.close();
  assert.ok(userTexts(requests[0]).includes("use the tool"), "the prompt came back from the first progress");
  assert.equal(toolResults(requests[0]).length, 1, "the step came back from the delta");
  assert.ok(JSON.stringify(requests[0]).includes("value of"), "with the tool's result");
});

test("a call that finished before a crash is answered with its result, not as possibly run", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  assert.equal((await run(agent, "use the tool")).text, "tool said beta");
  await agent.close();
  const result = journal.events.find((event) => event.type === "tool_result");
  assert.ok(result, "the finished call was recorded as it finished");
  assert.equal(result.data.status, "success");
  const survived = journal.events.slice(0, journal.events.indexOf(result) + 1);
  const asked = [];
  const resumed = await createFxEngine(options(targetBackend, eventJournal(survived)));
  requests.length = 0;
  const turn = resumed.resume({ onAmbiguous: (call) => { asked.push(call.executionId); } });
  const events = [];
  for await (const event of turn) events.push(event);
  assert.equal((await turn.result).stopReason, "end_turn");
  await resumed.close();
  assert.deepEqual(asked, [], "a call with a recorded result is not ambiguous");
  assert.deepEqual(events.filter((event) => event.type === "tool_end"), [], "nor shown as possibly run");
  const sent = JSON.stringify(requests[0]);
  assert.ok(sent.includes(JSON.stringify(result.data.output).slice(1, -1)), "the model gets the call's own result");
  assert.ok(!sent.includes("may have partly run"));
});

test("a call that a crash cut off is answered as possibly run, and its turn shows that", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  assert.equal((await run(agent, "use the tool")).text, "tool said beta");
  await agent.close();
  const intent = journal.events.find((event) => event.type === "tool_intent");
  const survived = journal.events.slice(0, journal.events.indexOf(intent) + 1);
  const resumed = await createFxEngine(options(targetBackend, eventJournal(survived)));
  requests.length = 0;
  const turn = resumed.resume();
  const events = [];
  for await (const event of turn) events.push(event);
  assert.equal((await turn.result).stopReason, "end_turn");
  await resumed.close();
  const ends = events.filter((event) => event.type === "tool_end");
  assert.equal(ends.length, 1);
  assert.deepEqual({ ...ends[0], content: undefined }, { type: "tool_end", id: intent.data[0].id, name: "lookup", content: undefined, isError: true });
  assert.ok(ends[0].content.includes("may have partly run"));
  assert.ok(JSON.stringify(requests[0]).includes(JSON.stringify(ends[0].content).slice(1, -1)), "the turn shows what the model heard");
  assert.equal(events[0], ends[0], "before anything the resumed turn does");
});

test("a crash before a response's calls are stored asks the model again", async () => {
  const tools = [{ ...lookup, idempotent: true }];
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal, { tools }));
  assert.equal((await run(agent, "use the tool")).text, "tool said beta");
  await agent.close();
  const intent = journal.events.findIndex((event) => event.type === "tool_intent");
  const crashed = eventJournal(journal.events.slice(0, intent));
  assert.equal(crashed.events.at(-1).type, "turn_progress");
  assert.equal(crashed.events.at(-1).data.tool_state, "uncertain");

  const resumed = await createFxEngine(options(targetBackend, crashed, { tools }));
  requests.length = 0;
  const turn = resumed.resume();
  for await (const _ of turn) {}
  const result = await turn.result;
  await resumed.close();
  assert.equal(result.stopReason, "end_turn");
  assert.notEqual(requests[0].toolChoice, "none", "the resumed request may call tools");
  assert.equal(toolResults(requests[0]).length, 0, "no call is answered: none was recorded");
});

test("resume continues a crashed turn and tells the model", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  await run(agent, "first");
  await run(agent, "remember plums");
  await agent.close();
  const crashed = eventJournal(journal.events.slice(0, -1));
  assert.equal(crashed.events.at(-1).type, "turn_progress");

  const events = [];
  const resumed = await createFxEngine(options(targetBackend, crashed, { onEvent: (event) => events.push(event) }));
  const open = events.find((event) => event.type === "journal.open");
  assert.equal(open.resumable, true);
  assert.equal(open.turns, 1);
  requests.length = 0;
  const turn = resumed.resume();
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(resumed.resume(), null, "the turn resumes once");
  await resumed.close();
  const body = JSON.stringify(requests[0]);
  assert.ok(body.includes("Resuming from unexpected session interruption."), "the model is told");
  const said = (text) => requests[0].filter((message) => message.role === "user" && textOf(message) === text).length;
  assert.equal(said("remember plums"), 1, "the interrupted prompt is the turn's own, once");
  const commits = crashed.events.filter((event) => event.type === "turn_committed");
  assert.equal(commits.length, 2);
  assert.equal(commits.at(-1).data.kind, "assistant");
  assert.equal(commits.at(-1).data.user.text, "remember plums");
  assertContiguous(crashed.events);
});

test("a resumed turn answers a call a crash left running instead of running it again", async () => {
  const journal = eventJournal();
  let sends = 0;
  const send = { ...lookup, execute: async (input) => { sends += 1; return lookup.execute(input); } };
  const agent = await createFxEngine(options(sourceBackend, journal, { tools: [send] }));
  await run(agent, "use the tool");
  await agent.close();
  assert.equal(sends, 1);
  const intent = journal.events.findIndex((event) => event.type === "tool_intent");
  assert.ok(intent > 0);
  const crashed = eventJournal(journal.events.slice(0, intent + 1));
  const resumed = await createFxEngine(options(targetBackend, crashed, { tools: [send] }));
  requests.length = 0;
  const turn = resumed.resume();
  const events = [];
  for await (const event of turn) events.push(event);
  assert.equal((await turn.result).stopReason, "end_turn");
  await resumed.close();
  assert.equal(sends, 1, "the call did not run again");
  const results = toolResults(requests[0]);
  assert.equal(results.length, 1, "the running call is answered");
  assert.match(JSON.stringify(results[0]), /may have partly run/);
  const [answered] = events;
  assert.equal(answered?.type, "tool_end");
  assert.equal(answered.id, "call-1");
  assert.equal(answered.name, "lookup");
  assert.equal(answered.isError, true);
  assert.ok(JSON.stringify(results[0]).includes(answered.content), `the event carries the model's answer: ${answered.content}`);
  assert.equal(events.filter((event) => event.id === "call-1").length, 1, "the call ends once, and does not start again");
  assertContiguous(crashed.events);
});

test("a host that knows a running call never ran has the resumed turn run it again", async () => {
  const journal = eventJournal();
  const seen = [];
  const send = { ...lookup, execute: async (input, { executionId: callId }) => { seen.push(callId); return lookup.execute(input); } };
  const agent = await createFxEngine(options(sourceBackend, journal, { tools: [send] }));
  await run(agent, "use the tool");
  await agent.close();
  const intent = journal.events.findIndex((event) => event.type === "tool_intent");
  const crashed = eventJournal(journal.events.slice(0, intent + 1));

  const resumed = await createFxEngine(options(targetBackend, crashed, { tools: [send] }));
  assert.throws(() => resumed.resume({ onAmbiguous: "rerun" }), /onAmbiguous must be a function/);
  const asked = [];
  requests.length = 0;
  const turn = resumed.resume({ onAmbiguous: (call) => { asked.push(call); return "rerun"; } });
  const events = [];
  for await (const event of turn) events.push(event);
  assert.equal((await turn.result).stopReason, "end_turn");
  await resumed.close();
  assert.deepEqual(asked, [{ executionId: "call-1", name: "lookup", input: { key: "alpha" } }]);
  const rerun = events.filter((event) => event.id === "call-1").map((event) => event.type);
  assert.deepEqual(rerun, ["tool_start", "tool_end"], "the rerun shows as a tool call");
  assert.deepEqual(seen, ["call-1", "call-1"], "the call ran again under the id the model gave it");
  const results = toolResults(requests[0]);
  assert.equal(results.length, 1, "the call has one result");
  assert.doesNotMatch(JSON.stringify(results[0]), /may have partly run/);
  assert.match(JSON.stringify(results[0]), /is beta/);
  assertContiguous(crashed.events);
});

test("a resumed turn keeps what the model wrote before the calls a crash left running", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  await run(agent, "explain and use the tool");
  await agent.close();
  const intent = journal.events.findIndex((event) => event.type === "tool_intent");
  assert.ok(intent > 0);
  const resumed = await createFxEngine(options(targetBackend, eventJournal(journal.events.slice(0, intent + 1))));
  requests.length = 0;
  const turn = resumed.resume();
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  await resumed.close();
  const assistant = requests[0].filter((message) => message.role === "assistant").flatMap((message) => message.content);
  assert.deepEqual(assistant.map((part) => part.type), ["text", "tool-call"]);
  assert.equal(assistant[0].text, "Looking it up.");
});

test("a new prompt instead of resume ends the crashed turn as interrupted", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  await run(agent, "use the tool");
  await agent.close();
  const crashed = eventJournal(journal.events.slice(0, -1));
  const resumed = await createFxEngine(options(targetBackend, crashed));
  requests.length = 0;
  await run(resumed, "after the crash");
  assert.equal(resumed.resume(), null, "a new prompt ended the open turn");
  await resumed.close();
  assert.ok(JSON.stringify(requests[0]).includes("use the tool"), "the interrupted turn stays in history");
  const commits = crashed.events.filter((event) => event.type === "turn_committed").map((event) => event.data.kind);
  assert.deepEqual(commits, ["interrupted", "assistant"]);
  assertContiguous(crashed.events);
});

test("each turn appends its own events, not the whole history", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  const sizes = [];
  for (let index = 0; index < 6; index++) {
    const before = journal.events.length;
    await run(agent, `turn ${index}`);
    sizes.push(JSON.stringify(journal.events.slice(before)).length);
  }
  await agent.close();
  assertContiguous(journal.events);
  assert.ok(sizes.at(-1) < sizes[0] * 1.5, `turn bytes grew: ${sizes.join(", ")}`);
});

test("a slow store receives one opaque record at a time, each naming the cursor before it", async () => {
  const store = createMemoryPersistence();
  const calls = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const slow = {
    load: () => store.load(),
    async append(input, ...rest) {
      assert.equal(rest.length, 0, "append receives one argument");
      assert.deepEqual(Object.keys(input).sort(), ["barrier", "data", "expected", "idempotencyKey"]);
      assert.equal(typeof input.barrier, "boolean");
      assert.ok(input.data instanceof Uint8Array);
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      try {
        await sleepMs(15);
        const result = await store.append(input);
        calls.push({ expected: input.expected, key: input.idempotencyKey, cursor: result.cursor });
        return result;
      } finally {
        inFlight -= 1;
      }
    },
  };
  const agent = await createFxEngine(options(sourceBackend, undefined, { persistence: slow }));
  await run(agent, "use the tool");
  await run(agent, "second");
  await agent.close();
  assert.equal(maxInFlight, 1, "each append waits for the cursor before it");
  calls.forEach((call, index) => assert.equal(call.expected, index === 0 ? null : calls[index - 1].cursor));
  assert.equal(new Set(calls.map((call) => call.key)).size, calls.length, "each write has its own key");
  const events = storedEvents(store);
  assert.equal(events.at(-1).type, "turn_committed");
  assertContiguous(events);
});

test("a second agent on the same store fences the first", async () => {
  const store = createMemoryPersistence();
  const first = await createFxEngine(options(sourceBackend, undefined, { persistence: store }));
  await run(first, "from the first");
  const second = await createFxEngine(options(targetBackend, undefined, { persistence: store }));
  await run(second, "from the second");
  await second.close();
  const turn = first.prompt("too late");
  const fenced = (error) => error.code === "FX_JOURNAL_APPEND_FAILED" && error.cause instanceof FxFencedError;
  await assert.rejects((async () => { for await (const _ of turn) {} })(), fenced);
  await assert.rejects(turn.result, fenced);
  await first.close();
  assertContiguous(storedEvents(store));
});

test("a journal that does not fold is refused", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  await run(agent, "one");
  await agent.close();
  const invalid = (pattern) => (error) => pattern.test(error.message) && error.code === "FX_JOURNAL_INVALID";
  const duplicated = eventJournal([...journal.events, journal.events.at(-1)]);
  await assert.rejects(createFxEngine(options(targetBackend, duplicated)), invalid(/libfx journal events are out of order/));
  const newer = eventJournal([{ ...journal.events[0], v: 3 }]);
  await assert.rejects(createFxEngine(options(targetBackend, newer)), /libfx journal was written by a newer fx/);
  const garbled = eventJournal([{ v: 1, seq: 1, turn: 1, type: "turn_committed", data: { kind: "nope" } }]);
  await assert.rejects(createFxEngine(options(targetBackend, garbled)), invalid(/Invalid libfx journal/));
  const huge = eventJournal([{ ...journal.events.at(-1), seq: 1, turn: 1, padding: "x".repeat(4 * 1024 * 1024) }]);
  await assert.rejects(
    createFxEngine(options(targetBackend, huge)),
    (error) => /libfx journal is too large/.test(error.message) && error.code === "FX_JOURNAL_TOO_LARGE",
  );
});

test("a failed append fails the turn and stops the agent", async () => {
  const journal = {
    async append() { throw new Error("disk full"); },
    async load() { return { events: [] }; },
  };
  const agent = await createFxEngine(options(sourceBackend, journal));
  const turn = agent.prompt("doomed");
  const failed = (error) => error.code === "FX_JOURNAL_APPEND_FAILED" && error.cause.message === "disk full";
  await assert.rejects((async () => { for await (const _ of turn) {} })(), failed);
  await assert.rejects(turn.result, failed);
  assert.throws(() => agent.prompt("again"), (error) => error.code === "FX_JOURNAL_APPEND_FAILED");
  await agent.close();
});

test("persistence options are checked before the core starts", async () => {
  await assert.rejects(
    createFxEngine(options(sourceBackend, undefined, { persistence: { load() {} } })),
    /persistence must be an object with load\(\), append\(\) and, optionally, saveCheckpoint\(\)/,
  );
  await assert.rejects(
    createFxEngine(options(sourceBackend, undefined, { persistence: { load() {}, append() {}, saveCheckpoint: 1 } })),
    /persistence must be an object/,
  );
  await assert.rejects(
    createFxEngine(options(sourceBackend, eventJournal(), { checkpoint: new Uint8Array(64) })),
    /persistence cannot be combined with checkpoint/,
  );
  await assert.rejects(createFxEngine(options(sourceBackend, undefined, { checkpointAfterBytes: 10 })), /checkpointAfterBytes needs persistence/);
  await assert.rejects(
    createFxEngine(options(sourceBackend, eventJournal(), { checkpointAfterBytes: -1 })),
    /checkpointAfterBytes must be a non-negative integer/,
  );
  const agent = await createFxEngine(options(sourceBackend, eventJournal()));
  assert.throws(() => agent.prompt("hello", { turnId: "a b" }), /turnId must be 1 to 128/);
  await agent.close();
});

test("a session taken over mid-turn fences the first agent, which stops at once", async () => {
  const journal = eventJournal();
  let toolStarted;
  const started = new Promise((resolveStarted) => { toolStarted = resolveStarted; });
  let releaseTool;
  const released = new Promise((resolveReleased) => { releaseTool = resolveReleased; });
  let laptopRuns = 0;
  const slowLookup = { ...lookup, execute: async () => { laptopRuns += 1; toolStarted(); await released; return "value of alpha is beta"; } };
  sessionHeaders.length = 0;
  const laptop = await createFxEngine(options(sourceBackend, journal, { tools: [slowLookup] }));
  const turn = laptop.prompt("keep using the tool");
  const drained = (async () => { for await (const _ of turn) {} })();
  await started;
  const [laptopSession] = sessionHeaders[0];

  const takeover = await createFxEngine(options(targetBackend, journal));
  const resumed = takeover.resume();
  assert.ok(resumed, "the function finds the laptop's turn open");
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  await takeover.close();
  const eventsAfterTakeover = journal.events.length;
  const laptopRequests = () => sessionHeaders.filter(([id]) => id === laptopSession).length;

  const requestsBeforeRelease = laptopRequests();
  releaseTool();
  const fenced = (error) => error.code === "FX_JOURNAL_APPEND_FAILED" && error.cause instanceof FxFencedError && error.cause.code === "FX_FENCED";
  await assert.rejects(drained, fenced);
  await assert.rejects(turn.result, fenced);
  await laptop.close();
  await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  assert.ok(laptopRequests() <= requestsBeforeRelease + 1, `the laptop started no request once fenced (${laptopRequests()} after ${requestsBeforeRelease})`);
  assert.equal(journal.events.length, eventsAfterTakeover, "the laptop wrote nothing after the fence");
  assert.equal(laptopRuns, 1);
  assertContiguous(journal.events);
  assert.equal(journal.events.at(-1).type, "turn_committed");

  const reopened = await createFxEngine(options(sourceBackend, eventJournal(journal.events)));
  assert.equal(reopened.resume(), null);
  assert.equal((await run(reopened, "what did I say")).text, "answer to what did I say");
  await reopened.close();
});

test("a takeover does not run a running call again and records one outcome for it", async () => {
  const journal = eventJournal();
  let toolStarted;
  const started = new Promise((resolveStarted) => { toolStarted = resolveStarted; });
  let releaseTool;
  const released = new Promise((resolveReleased) => { releaseTool = resolveReleased; });
  const runs = [];
  const sender = (who, wait) => ({
    ...lookup,
    execute: async () => {
      runs.push(who);
      if (wait) { toolStarted(); await released; }
      return `${who} looked up alpha`;
    },
  });
  const laptop = await createFxEngine(options(sourceBackend, journal, { tools: [sender("laptop", true)] }));
  const turn = laptop.prompt("use the tool");
  const drained = (async () => { for await (const _ of turn) {} })();
  await started;
  const takeover = await createFxEngine(options(targetBackend, journal, { tools: [sender("takeover", false)] }));
  const resumed = takeover.resume();
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  await takeover.close();
  releaseTool();
  await assert.rejects(drained, (error) => error.cause instanceof FxFencedError);
  await assert.rejects(turn.result, (error) => error.cause instanceof FxFencedError);
  await laptop.close();

  assert.deepEqual(runs, ["laptop"]);
  const intents = journal.events.filter((event) => event.type === "tool_intent" && event.data.some((call) => call.id === "call-1"));
  assert.equal(intents.length, 1);
  assert.ok(intents[0].seq < journal.events.findLast((event) => event.type === "turn_committed").seq);
  const reopened = await createFxEngine(options(sourceBackend, eventJournal(journal.events), { tools: [sender("reopened", false)] }));
  await run(reopened, "what did I say");
  await reopened.close();
  const ownRequest = requests.find((prompt) => prompt.sessionId === reopened.sessionId);
  const results = toolResults(ownRequest).filter((part) => part.toolCallId === "call-1");
  assert.equal(results.length, 1);
  assert.match(JSON.stringify(results[0]), /may have partly run/);
  assert.doesNotMatch(JSON.stringify(results[0]), /laptop looked up alpha/);
});

async function steeredTurn(journal) {
  let toolStarted;
  const started = new Promise((resolveStarted) => { toolStarted = resolveStarted; });
  let releaseTool;
  const released = new Promise((resolveReleased) => { releaseTool = resolveReleased; });
  const slowLookup = { ...lookup, execute: async () => { toolStarted(); await released; return "value of alpha is beta"; } };
  const agent = await createFxEngine(options(sourceBackend, journal, { tools: [slowLookup] }));
  requests.length = 0;
  const turn = agent.prompt("use the tool");
  const drained = (async () => { for await (const _ of turn) {} })();
  await started;
  return { agent, turn, drained, releaseTool };
}

const placedBy = (events, id) => events.filter((event) => event.type === "turn_progress" && (event.inputs ?? []).includes(id));

test("a steer is stored before the model request that carries it", async () => {
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  const steered = turn.steer("answer in one word");
  assert.match(steered.id, /^in_[0-9a-f-]+$/);
  if (sourceBackend === "native") assert.deepEqual(await steered, { id: steered.id });
  releaseTool();
  await drained;
  assert.equal((await turn.result).stopReason, "end_turn");
  if (sourceBackend !== "native") assert.deepEqual(await steered, { id: steered.id });
  await agent.close();

  const accepted = journal.events.findIndex((event) => event.type === "input_accepted" && event.data.id === steered.id);
  assert.ok(accepted >= 0, "the steer's acceptance is in the journal");
  assert.equal(journal.events[accepted].data.text, "answer in one word");
  const placements = placedBy(journal.events, steered.id);
  assert.equal(placements.length, 1, "one progress places the steer");
  assert.ok(placements[0].seq > journal.events[accepted].seq);
  assert.ok(JSON.stringify(requests.at(-1)).includes("answer in one word"), "the request after the tool carries it");
  assertContiguous(journal.events);
});

test("a steer withdrawn before its boundary never reaches the model", async () => {
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  const kept = turn.steer("keep this one");
  const dropped = turn.steer("forget this one");
  assert.equal(await turn.withdraw(dropped.id), "withdrawn");
  assert.equal(await turn.withdraw(dropped.id), "already_placed");
  releaseTool();
  await drained;
  await turn.result;
  await kept;
  assert.equal(await turn.withdraw(kept.id), "already_placed");
  await agent.close();

  const body = JSON.stringify(requests.at(-1));
  assert.ok(body.includes("keep this one"));
  assert.ok(!body.includes("forget this one"), "the withdrawn steer was never sent");
  assert.equal(placedBy(journal.events, dropped.id).length, 0);
  assert.equal(placedBy(journal.events, kept.id).length, 1);
  if (sourceBackend === "native") {
    assert.ok(journal.events.some((event) => event.type === "input_withdrawn" && event.data.id === dropped.id));
  }
  const reopened = await createFxEngine(options(targetBackend, eventJournal(journal.events)));
  assert.equal(reopened.resume(), null);
  await reopened.close();
});

test("a steer accepted before a crash reaches the model when the turn resumes", async () => {
  if (sourceBackend !== "native") return;
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  const steered = await turn.steer("mention plums");
  const cut = journal.events.findIndex((event) => event.type === "input_accepted" && event.data.id === steered.id);
  const survived = journal.events.slice(0, cut + 1);
  releaseTool();
  await drained;
  await turn.result;
  await agent.close();

  const crashed = eventJournal(survived);
  const resumedAgent = await createFxEngine(options(targetBackend, crashed));
  requests.length = 0;
  const resumed = resumedAgent.resume();
  assert.ok(resumed);
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  await resumedAgent.close();
  const body = JSON.stringify(requests[0]);
  assert.ok(body.includes("Resuming from unexpected session interruption."));
  assert.ok(body.includes("mention plums"), "the pending steer goes with the resume");
  assert.equal(placedBy(crashed.events, steered.id).length, 1, "the resumed turn places it once");
  assertContiguous(crashed.events);
});

const followUpAccepted = (events, id) => events.filter((event) => event.type === "input_accepted" && event.data.id === id && event.data.kind === "follow_up");

test("a follow-up queued during a turn runs after it as its own turn", async () => {
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  const next = agent.followUp("then summarize");
  assert.match(next.id, /^in_[0-9a-f-]+$/);
  if (sourceBackend === "native") {
    assert.deepEqual(await next.accepted, { id: next.id });
    assert.equal(followUpAccepted(journal.events, next.id).length, 1, "stored while the first turn runs");
  }
  releaseTool();
  await drained;
  assert.equal((await turn.result).stopReason, "end_turn");
  const second = await next;
  requests.length = 0;
  for await (const _ of second) {}
  assert.equal((await second.result).stopReason, "end_turn");
  assert.deepEqual(await next.accepted, { id: next.id });
  await agent.close();

  assert.equal(lastUserText(requests[0]), "then summarize");
  assert.equal(followUpAccepted(journal.events, next.id).length, 1);
  assert.equal(placedBy(journal.events, next.id).length, 1, "its own turn places it once");
  assert.equal(journal.events.filter((event) => event.type === "turn_committed").length, 2);
  assertContiguous(journal.events);
});

test("a follow-up the journal holds runs when the session resumes", async () => {
  if (sourceBackend !== "native") return;
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  const next = agent.followUp("then summarize");
  await next.accepted;
  releaseTool();
  await drained;
  await turn.result;
  const firstCommit = journal.events.findIndex((event) => event.type === "turn_committed");
  const survived = journal.events.slice(0, firstCommit + 1);
  await agent.close();
  await next.catch(() => {});

  const crashed = eventJournal(survived);
  const reopened = await createFxEngine(options(targetBackend, crashed));
  requests.length = 0;
  const resumed = reopened.resume();
  assert.ok(resumed, "the held follow-up is the work left");
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  assert.equal(reopened.resume(), null);
  await reopened.close();
  assert.equal(lastUserText(requests[0]), "then summarize");
  assert.equal(placedBy(crashed.events, next.id).length, 1);
  const again = await createFxEngine(options(sourceBackend, eventJournal(crashed.events)));
  assert.equal(again.resume(), null, "nothing is left after the follow-up ran");
  await again.close();
});

test("a held follow-up waits for resume() without holding up the agent's own", async () => {
  if (sourceBackend !== "native") return;
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  const next = agent.followUp("then summarize");
  await next.accepted;
  releaseTool();
  await drained;
  await turn.result;
  const firstCommit = journal.events.findIndex((event) => event.type === "turn_committed");
  const survived = journal.events.slice(0, firstCommit + 1);
  await agent.close();
  await next.catch(() => {});

  const reopened = await createFxEngine(options(targetBackend, eventJournal(survived)));
  requests.length = 0;
  let timer;
  const late = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("the agent's own follow-up never started")), 10_000); });
  const own = await Promise.race([reopened.followUp("my own follow-up"), late]);
  clearTimeout(timer);
  for await (const _ of own) {}
  assert.equal((await own.result).stopReason, "end_turn");
  assert.equal(lastUserText(requests.at(-1)), "my own follow-up");
  const held = reopened.resume();
  assert.ok(held, "the held follow-up still waits for resume()");
  for await (const _ of held) {}
  await held.result;
  assert.equal(lastUserText(requests.at(-1)), "then summarize");
  assert.equal(reopened.resume(), null);
  await reopened.close();
});

test("a follow-up on an idle agent runs at once", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  const queued = agent.followUp("right away");
  const now = await queued;
  for await (const _ of now) {}
  assert.equal((await now.result).stopReason, "end_turn");
  assert.deepEqual(await queued.accepted, { id: queued.id });
  await agent.close();
  assert.equal(followUpAccepted(journal.events, queued.id).length, 1);
  assert.equal(placedBy(journal.events, queued.id).length, 1);
  assert.equal(journal.events.filter((event) => event.type === "turn_committed").length, 1);
  assertContiguous(journal.events);
});

const sleepMs = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
const userTexts = (prompt) => prompt.filter((message) => message.role === "user").map(textOf);

test("a turn left open resumes under the tools the new agent has", async () => {
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  const survived = journal.events.slice();
  releaseTool();
  await drained;
  await turn.result;
  await agent.close();

  const changed = { ...lookup, description: "Looks up a key in another store" };
  const other = await createFxEngine(options(targetBackend, eventJournal(survived), { tools: [changed] }));
  requests.length = 0;
  const resumed = other.resume();
  assert.ok(resumed, "the open turn resumes");
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  await other.close();
  assert.ok(JSON.stringify(requests[0]).includes("Resuming from unexpected session interruption."));
});

test("a journal from a newer libfx is refused", async () => {
  const future = eventJournal([{ v: 3, seq: 1, turn: 1, type: "turn_progress", data: {} }]);
  const newer = (error) => error instanceof FxJournalVersionError && error.code === "FX_JOURNAL_VERSION";
  await assert.rejects(createFxEngine(options(sourceBackend, future)), newer);
  const record = (format) => ({
    async load() { return { journal: [{ cursor: "1", data: new TextEncoder().encode(JSON.stringify({ format, events: [] })) }] }; },
    async append() { throw new Error("not reached"); },
  });
  await assert.rejects(createFxEngine(options(sourceBackend, undefined, { persistence: record("libfx-journal-v2") })), newer);
  await assert.rejects(
    createFxEngine(options(sourceBackend, undefined, { persistence: record("something-else") })),
    (error) => error.code === "FX_JOURNAL_INVALID",
  );
});

test("a checkpoint from a newer libfx is refused with the journal's typed error", async () => {
  const source = await createFxEngine(options(sourceBackend));
  const turn = source.prompt("hello");
  for await (const _ of turn) {}
  await turn.result;
  const saved = await source.checkpoint();
  await source.close();
  const future = saved.slice();
  new DataView(future.buffer, future.byteOffset).setUint16(4, 0x7fff, true);
  await assert.rejects(
    createFxEngine(options(targetBackend, undefined, { checkpoint: future })),
    (error) => error instanceof FxJournalVersionError && error.code === "FX_JOURNAL_VERSION",
  );
  const restored = await createFxEngine(options(targetBackend, undefined, { checkpoint: saved }));
  await restored.close();
});

const fixture = JSON.parse(await readFile(resolve(scriptDir, "fixtures/libfx-journal-v1.json"), "utf8"));

test("a v1 journal from the first journaled libfx still resumes", async () => {
  assert.equal(fixture.format, "libfx-journal-v1");
  const plain = await createFxEngine(options(targetBackend, eventJournal(fixture.plain.events)));
  requests.length = 0;
  const resumed = plain.resume();
  assert.ok(resumed, "the open turn resumes");
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  assert.ok(userTexts(requests[0]).includes("remember plums"));
  assert.ok(JSON.stringify(requests).includes("answer in one word"), "the held steer reached the model");
  const followUp = plain.resume();
  assert.ok(followUp, "the held follow-up runs next");
  for await (const _ of followUp) {}
  await followUp.result;
  assert.equal(lastUserText(requests.at(-1)), "then summarize");
  assert.equal(plain.resume(), null);
  await plain.close();
});

const previousCheckpoint = JSON.parse(await readFile(resolve(scriptDir, "fixtures/libfx-0.0.11-checkpoint.json"), "utf8"));

test("a checkpoint saved by the previous published libfx restores in this one", async () => {
  assert.equal(previousCheckpoint.libfx, "0.0.11");
  const checkpoint = new Uint8Array(Buffer.from(previousCheckpoint.checkpoint, "base64"));
  const agent = await createFxEngine(options(targetBackend, undefined, { checkpoint }));
  requests.length = 0;
  await run(agent, "what did I say");
  await agent.close();
  const users = userTexts(requests[0]);
  for (const text of ["remember plums", "use the tool", "what did I say"]) assert.ok(users.includes(text), `${text} is in the history`);
  assert.ok(JSON.stringify(toolResults(requests[0])).includes("value of alpha is beta"), "the tool result survived");
});

test("each progress event names the model its request goes to", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  await run(agent, "use the tool");
  await agent.close();
  const progress = journal.events.filter((event) => event.type === "turn_progress");
  assert.ok(progress.length >= 2);
  for (const event of progress) assert.equal(event.model, "journal/model", `event ${event.seq}`);
});

test("a turn handed off mid-tool stays open for the next agent", async () => {
  const journal = eventJournal();
  const { agent, turn, drained, releaseTool } = await steeredTurn(journal);
  turn.cancel({ reason: "handoff" });
  releaseTool();
  await drained;
  await turn.result;
  assert.throws(() => agent.prompt("again"), /handed its session off/);
  assert.throws(() => agent.resume(), /handed its session off/);
  await assert.rejects(agent.followUp("later"), /handed its session off/);
  await agent.close();
  const ends = journal.events.filter((event) => event.type === "turn_committed" || event.type === "turn_progress_cleared");
  assert.deepEqual(ends, [], "nothing ended the handed-off turn");

  const next = await createFxEngine(options(targetBackend, eventJournal(journal.events)));
  requests.length = 0;
  const resumed = next.resume();
  assert.ok(resumed, "the next agent resumes the turn");
  for await (const _ of resumed) {}
  assert.equal((await resumed.result).stopReason, "end_turn");
  await next.close();
  assert.ok(JSON.stringify(requests[0]).includes("Resuming from unexpected session interruption"));
});

test("a handoff needs persistence and takes no other reason", async () => {
  const plain = await createFxEngine(options(sourceBackend));
  const turn = plain.prompt("hello");
  assert.throws(() => turn.cancel({ reason: "handoff" }), /needs persistence/);
  assert.throws(() => turn.cancel({ reason: "later" }), /reason must be "handoff"/);
  for await (const _ of turn) {}
  await turn.result;
  await plain.close();
});

test("a long tool turn stores each step once in its progress, and a crash late in it restores", async () => {
  const journal = eventJournal();
  const tools = [lookup, bulky];
  const source = await createFxEngine(options(sourceBackend, journal, { tools }));
  const { text } = await run(source, "gather everything");
  assert.equal(text, "gathered");
  await source.close();
  const crashed = journal.events.slice(0, journal.events.findLastIndex((event) => event.type === "turn_progress") + 1);
  const bytesOf = (events) => new TextEncoder().encode(JSON.stringify(events)).byteLength;
  const stepBytes = bulkySteps * 60_000;
  assert.ok(bytesOf(crashed) < 2.5 * stepBytes, `the turn's events hold ${bytesOf(crashed)} bytes for ${stepBytes} bytes of results`);
  const progress = crashed.filter((event) => event.type === "turn_progress");
  assert.ok(bytesOf(progress) < 1.5 * stepBytes, `its progress holds ${bytesOf(progress)} bytes`);

  const target = await createFxEngine(options(targetBackend, eventJournal(crashed), { tools }));
  const turn = target.resume();
  assert.ok(turn, "the crashed turn is open");
  for await (const _ of turn) {}
  assert.equal((await turn.result).stopReason, "end_turn");
  assert.equal(toolResults(requests.at(-1)).length, bulkySteps, "the resumed request carries every step");
  await target.close();
});

test("a turn that fails ends in the journal and is not resumed", async () => {
  for (const backend of [sourceBackend, targetBackend]) {
    const journal = eventJournal();
    const agent = await createFxEngine(options(backend, journal));
    const failed = await run(agent, "fail please");
    assert.notEqual(failed.result.stopReason, "end_turn");
    await agent.close();
    assert.equal(journal.events.at(-1).type, "turn_progress_cleared", journal.events.map((event) => event.type).join(","));

    const next = await createFxEngine(options(backend, eventJournal(journal.events)));
    assert.equal(next.resume(), null, "a failed turn is not a crashed one");
    assert.equal((await run(next, "hello")).text, "answer to hello");
    await next.close();
  }
});

test("a follow-up cancelled as its turn starts never runs again", async () => {
  for (const backend of [sourceBackend, targetBackend]) {
    const journal = eventJournal();
    const agent = await createFxEngine(options(backend, journal));
    await run(agent, "one");
    const queued = agent.followUp("cancel me");
    const cancelled = await queued;
    cancelled.cancel();
    for await (const _ of cancelled) {}
    await cancelled.result;
    await agent.close();

    const reopened = await createFxEngine(options(backend, eventJournal(journal.events)));
    assert.equal(reopened.resume(), null, "the cancelled follow-up is not run again");
    await reopened.close();
  }
});

test("a cancel during a slow journal's barrier ends the turn as the agent does", async () => {
  for (const backend of [sourceBackend, targetBackend]) {
    const stored = eventJournal();
    let previous = Promise.resolve();
    const journal = {
      load: () => stored.load(),
      append(batch) {
        previous = previous.then(() => sleepMs(300)).then(() => stored.append(batch));
        return previous;
      },
    };
    const agent = await createFxEngine(options(backend, journal));
    const turn = agent.prompt("slow start");
    const drained = (async () => { for await (const _ of turn) {} })();
    await sleepMs(100);
    turn.cancel();
    await drained;
    assert.equal((await turn.result).stopReason, "cancelled");
    requests.length = 0;
    await run(agent, "next");
    const live = userTexts(requests.at(-1)).includes("slow start");
    await agent.close();
    const committed = stored.events.some((event) => event.type === "turn_committed" && event.data.user?.text === "slow start");
    const types = `${backend}: ${stored.events.map((event) => event.type).join(",")}`;
    assert.equal(committed, live, `the journal keeps the cancelled turn exactly when the agent does; ${types}`);
    if (backend === "native") assert.ok(committed, types);

    const reopened = await createFxEngine(options(backend, eventJournal(stored.events)));
    assert.equal(reopened.resume(), null, "a cancelled turn is not resumed");
    requests.length = 0;
    await run(reopened, "again");
    await reopened.close();
    assert.equal(userTexts(requests.at(-1)).includes("slow start"), live, "the restored history matches the live one");
  }
});

test("a resumed turn cancelled during a slow journal's barrier is committed once", async () => {
  for (const backend of [sourceBackend, targetBackend]) {
    const journal = eventJournal();
    const agent = await createFxEngine(options(backend, journal));
    await run(agent, "use the tool");
    await agent.close();
    const crashed = journal.events.slice(0, journal.events.findLastIndex((event) => event.type === "turn_progress") + 1);
    const stored = eventJournal(crashed);
    let previous = Promise.resolve();
    const slow = {
      load: () => stored.load(),
      append(batch) {
        previous = previous.then(() => sleepMs(300)).then(() => stored.append(batch));
        return previous;
      },
    };
    const reopened = await createFxEngine(options(backend, slow));
    const turn = reopened.resume();
    assert.ok(turn);
    const drained = (async () => { for await (const _ of turn) {} })();
    await sleepMs(100);
    turn.cancel();
    await drained;
    await turn.result;
    requests.length = 0;
    await run(reopened, "next");
    await reopened.close();
    const commits = stored.events.filter((event) => event.type === "turn_committed" && event.data.user?.text === "use the tool");
    assert.equal(commits.length, 1, `${backend}: ${stored.events.map((event) => event.type).join(",")}`);
    assert.equal(userTexts(requests.at(-1)).filter((text) => text === "use the tool").length, 1);
  }
});

const pngData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";

test("an image prompt after a crashed image turn gets the next image id", async () => {
  const vision = { modelCatalog: [{ id: "journal/model", type: "language", tags: ["tool-use", "vision", "file-input"] }] };
  const image = { type: "image", data: pngData, mimeType: "image/png" };
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal, vision));
  await run(agent, [{ type: "text", text: "look at this" }, image]);
  await agent.close();
  const firstProgress = journal.events.findIndex((event) => event.type === "turn_progress");
  const reopened = await createFxEngine(options(targetBackend, eventJournal(journal.events.slice(0, firstProgress + 1)), vision));
  requests.length = 0;
  const { result } = await run(reopened, [{ type: "text", text: "and this" }, image]);
  await reopened.close();
  assert.equal(result.stopReason, "end_turn");
  assert.match(lastUserText(requests.at(-1)), /\[Image #2\]$/);
});

test("a journal past the turn limit is refused by name", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  await run(agent, "one");
  await agent.close();
  const commit = journal.events.find((event) => event.type === "turn_committed");
  const turns = Array.from({ length: 1025 }, (_, index) => ({ ...commit, seq: index + 1, turn: index + 1 }));
  await assert.rejects(
    createFxEngine(options(targetBackend, eventJournal(turns))),
    (error) => error.message === "libfx journal holds more than 1024 turns" && error.code === "FX_JOURNAL_TOO_LARGE",
  );
});

test("a host session id reaches the gateway and stays the same across a restore", async () => {
  const journal = eventJournal();
  sessionHeaders.length = 0;
  const source = await createFxEngine(options(sourceBackend, journal, { sessionId: "app-session-1" }));
  await run(source, "remember plums");
  await source.close();
  const target = await createFxEngine(options(targetBackend, eventJournal(journal.events), { sessionId: "app-session-1" }));
  await run(target, "what did I say");
  await target.close();
  assert.ok(sessionHeaders.length >= 2);
  assert.ok(sessionHeaders.every(([id, affinity]) => id === "app-session-1" && affinity === "app-session-1"), JSON.stringify(sessionHeaders));
});

test("a session id must be safe to send as a header", async () => {
  await assert.rejects(createFxEngine(options(sourceBackend, eventJournal(), { sessionId: "a b" })), /sessionId must be 1 to 255/);
  await assert.rejects(createFxEngine(options(sourceBackend, eventJournal(), { sessionId: "a\r\nx-injected: 1" })), /sessionId must be 1 to 255/);
});

test("a checkpoint is saved after a turn, and a restore reads it and only the records after it", async () => {
  const store = createMemoryPersistence();
  const saves = [];
  const onEvent = (event) => { if (event.type.startsWith("checkpoint.")) saves.push(event); };
  const source = await createFxEngine(options(sourceBackend, undefined, { persistence: store, checkpointAfterBytes: 0, onEvent }));
  await run(source, "remember plums");
  const last = source.prompt("use the tool", { turnId: "turn-last" });
  for await (const _ of last) {}
  await last.result;
  await source.close();
  assert.ok(saves.length >= 1 && saves.every((event) => event.type === "checkpoint.save"), JSON.stringify(saves));
  assert.ok(store.checkpoint, "the store holds a checkpoint");
  assert.equal(store.checkpoint.through, store.records.at(-1).cursor, "it covers every record the session wrote");

  const target = await createFxEngine(options(targetBackend, undefined, { persistence: store }));
  requests.length = 0;
  const retried = target.prompt("use the tool", { turnId: "turn-last" });
  assert.equal((await retried.result).stopReason, "end_turn");
  assert.equal(requests.length, 0, "the ended turn did not run again");
  await run(target, "what did I say");
  await target.close();
  const users = userTexts(requests[0]);
  for (const text of ["remember plums", "use the tool", "what did I say"]) assert.ok(users.includes(text), `${text} is in the history`);
  assert.equal(toolResults(requests[0]).length, 1);
  const loaded = await store.load();
  assert.ok(loaded.checkpoint);
  assert.ok(loaded.journal.length > 0 && loaded.journal.length < store.records.length, "a load returns only the records after the checkpoint");
  assertContiguous(storedEvents(store));
});

test("a checkpoint after a turn counts the records still being stored", async () => {
  const store = createMemoryPersistence();
  const slow = {
    load: () => store.load(),
    append: async (input) => { await new Promise((wait) => setTimeout(wait, 20)); return store.append(input); },
    saveCheckpoint: (input) => store.saveCheckpoint(input),
  };
  const saves = [];
  const onEvent = (event) => { if (event.type === "checkpoint.save") saves.push(event); };
  const agent = await createFxEngine(options(sourceBackend, undefined, { persistence: slow, inputsDurable: true, checkpointAfterBytes: 0, onEvent }));
  await run(agent, "remember plums");
  await agent.close();
  assert.equal(saves.length, 1, JSON.stringify(saves));
  assert.equal(store.checkpoint.through, store.records.at(-1).cursor, "it covers every record the turn wrote");
});

test("a failed checkpoint save is reported and the records still restore the session", async () => {
  const store = createMemoryPersistence();
  const failing = { load: () => store.load(), append: (input) => store.append(input), async saveCheckpoint() { throw new Error("bucket full"); } };
  const errors = [];
  const onEvent = (event) => { if (event.type === "checkpoint.error") errors.push(event.message); };
  const agent = await createFxEngine(options(sourceBackend, undefined, { persistence: failing, checkpointAfterBytes: 0, onEvent }));
  await run(agent, "remember plums");
  await agent.close();
  assert.deepEqual(errors, ["bucket full"]);
  const target = await createFxEngine(options(targetBackend, undefined, { persistence: store }));
  requests.length = 0;
  await run(target, "what did I say");
  await target.close();
  assert.ok(userTexts(requests[0]).includes("remember plums"));
});

test("a retried prompt with the same turn id continues its open turn instead of adding the prompt again", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  await run(agent, "first");
  const turn = agent.prompt("remember plums", { turnId: "turn-7" });
  assert.equal(turn.id, "turn-7");
  for await (const _ of turn) {}
  await turn.result;
  await agent.close();
  assert.ok(journal.events.some((event) => event.type === "turn_progress" && event.turnId === "turn-7"), "the turn's first progress records its id");
  const crashed = eventJournal(journal.events.slice(0, -1));
  const retried = await createFxEngine(options(targetBackend, crashed));
  requests.length = 0;
  const again = retried.prompt("remember plums", { turnId: "turn-7" });
  assert.equal(again.id, "turn-7");
  for await (const _ of again) {}
  assert.equal((await again.result).stopReason, "end_turn");
  await retried.close();
  assert.ok(JSON.stringify(requests[0]).includes("Resuming from unexpected session interruption."));
  assert.equal(userTexts(requests[0]).filter((text) => text === "remember plums").length, 1, "the prompt is in the history once");
  assert.deepEqual(crashed.events.filter((event) => event.type === "turn_committed").map((event) => event.data.kind), ["assistant", "assistant"]);
  assertContiguous(crashed.events);
});

test("a retried prompt with the id of a turn that ended does not run it again", async () => {
  const journal = eventJournal();
  const agent = await createFxEngine(options(sourceBackend, journal));
  const turn = agent.prompt("remember plums", { turnId: "turn-8" });
  for await (const _ of turn) {}
  await turn.result;
  requests.length = 0;
  const same = agent.prompt("remember plums", { turnId: "turn-8" });
  assert.equal((await same.result).stopReason, "end_turn");
  await agent.close();

  const restored = await createFxEngine(options(targetBackend, journal));
  const retried = restored.prompt("remember plums", { turnId: "turn-8" });
  assert.equal(retried.id, "turn-8");
  for await (const _ of retried) {}
  assert.equal((await retried.result).stopReason, "end_turn");
  assert.equal(requests.length, 0, "no model request ran for the ended turn");
  const next = restored.prompt("and now", { turnId: "turn-9" });
  for await (const _ of next) {}
  assert.equal((await next.result).stopReason, "end_turn");
  await restored.close();
  assert.equal(requests.length, 1);
  assert.equal(journal.events.filter((event) => event.type === "turn_committed").length, 2);
  assertContiguous(journal.events);
});

test("a tool receives the model's call id as its execution id, and its session's id", async () => {
  const seen = [];
  const recording = {
    ...lookup,
    execute: async (input, context) => {
      seen.push({ keys: Object.keys(context).sort(), executionId: context.executionId, sessionId: context.sessionId, signal: context.signal instanceof AbortSignal });
      return lookup.execute(input);
    },
  };
  const agent = await createFxEngine(options(sourceBackend, eventJournal(), { tools: [recording] }));
  const turn = agent.prompt("use the tool", { turnId: "turn-tools" });
  for await (const _ of turn) {}
  await turn.result;
  const { sessionId } = agent;
  await agent.close();
  assert.deepEqual(seen, [{ keys: ["executionId", "sessionId", "signal"], executionId: "call-1", sessionId, signal: true }]);
});
try {
  for (const { name, body } of cases) {
    await body();
    console.log(`ok - ${name}`);
  }
  console.log(`journal integration passed: ${sourceBackend} -> ${targetBackend}`);
} finally {
  server.closeAllConnections();
  await new Promise((resolveClose) => server.close(resolveClose));
}
