import { coreAnswered, engineInternals, journalMarksWanted, normalizeInstructions, normalizeModelChoice } from "./fx-sdk.js";
import { createCredentialMemory, credentialMemory } from "./subscription.js";

const encoder = new TextEncoder();
const durableCheckpointAfterBytes = 64 * 1024;

/**
 * The fx harness for `createDurableAgentFactory`. `createEngine(options)`
 * returns a `createFxEngine` session, and `defaultApiKey(durability)` the
 * credential when the caller passes none.
 */
export function fxHarness({ createEngine, defaultApiKey = async () => undefined }) {
  return (options) => {
    const { checkpoint, ...engineOptions } = options;
    for (const name of ["env", "persistence", "checkpointAfterBytes", "sessionId", "inputsDurable", "toolContext"]) {
      if (Object.hasOwn(engineOptions, name)) throw new TypeError(`createFxAgent() does not accept ${name}`);
    }
    const idempotent = idempotentTools(engineOptions.tools);
    const credentials = createCredentialMemory();
    return {
      ...(checkpoint === undefined ? {} : { seed: snapshotOf(checkpointBytesOf(checkpoint)) }),
      settings: sessionSettings,
      async open({ sessionId, store, context, settings, durability, ready }) {
        const apiKey = engineOptions.apiKey ?? await defaultApiKey(durability);
        const engine = await createEngine({
          ...withSettings(engineOptions, settings),
          ...(apiKey === undefined ? {} : { apiKey }),
          ...(ready === undefined || engineOptions.tools === undefined ? {} : { tools: claimedTools(engineOptions.tools, ready) }),
          sessionId,
          [credentialMemory]: credentials,
          persistence: { ...store, [journalMarksWanted]: true },
          inputsDurable: true,
          checkpointAfterBytes: durableCheckpointAfterBytes,
          ...(context === undefined || context === null ? {} : { toolContext: context }),
        });
        return fxSession(engine, idempotent);
      },
    };
  };
}

function sessionSettings({ model, instructions } = {}) {
  if (model !== undefined) {
    if (typeof model !== "string" && (model === null || typeof model !== "object" || Array.isArray(model))) {
      throw new TypeError("session model must be a model id or a model object");
    }
    normalizeModelChoice({ model });
  }
  if (instructions !== undefined) normalizeInstructions(instructions);
  if (model === undefined && instructions === undefined) return undefined;
  return JSON.parse(JSON.stringify({ model, instructions }));
}

function withSettings(engineOptions, settings) {
  if (!settings) return engineOptions;
  const { model: _model, effort: _effort, fast: _fast, ultrafast: _ultrafast, ...rest } = engineOptions;
  return {
    ...(settings.model === undefined ? engineOptions : { ...rest, model: settings.model }),
    ...(settings.instructions === undefined ? {} : { instructions: settings.instructions }),
  };
}

const unwrapFence = (error) => (error?.cause?.code === "FX_FENCED" ? error.cause : error);

const exitWaitMs = 1000;

async function turnError(error, exited) {
  const unwrapped = unwrapFence(error);
  if (unwrapped?.code === "FX_FENCED" || unwrapped?.[coreAnswered]) return unwrapped;
  let timer;
  const gone = await Promise.race([
    exited.then(() => true, () => true),
    new Promise((resolve) => { timer = setTimeout(() => resolve(false), exitWaitMs); }),
  ]).finally(() => clearTimeout(timer));
  if (!gone) return unwrapped;
  return Object.assign(new Error(String(unwrapped?.message ?? unwrapped), { cause: unwrapped }), { code: "FX_HARNESS_STOPPED" });
}

function fxTurn(turn, exited) {
  const result = turn.result.catch(async (error) => { throw await turnError(error, exited); });
  void result.catch(() => {});
  return {
    result,
    steer: (text, id) => turn.steer(text, id),
    endForSteer: () => turn[engineInternals]?.endForSteer(),
    cancel: (options) => turn.cancel(options),
    async *[Symbol.asyncIterator]() {
      try {
        for await (const event of turn) yield event;
      } catch (error) {
        throw await turnError(error, exited);
      }
    },
  };
}

function refusedTurn(error) {
  return {
    result: Promise.resolve({ stopReason: "error", usage: {}, error: { name: error?.name ?? "Error", message: String(error?.message ?? error) } }),
    steer: async () => {},
    endForSteer: async () => {},
    cancel() {},
    async *[Symbol.asyncIterator]() {},
  };
}

function fxSession(engine, idempotent) {
  const internals = engine[engineInternals];
  return {
    prompt: (input, options) => {
      try {
        return fxTurn(engine.prompt(input, options), internals.exited);
      } catch (error) {
        if (error instanceof TypeError || error instanceof RangeError) return refusedTurn(error);
        throw error;
      }
    },
    resume: ({ rerun = true, ...options } = {}) => fxTurn(engine.resume({ ...options, onAmbiguous: (call) => (rerun && idempotent.has(call.name) ? "rerun" : undefined) }), internals.exited),
    get openTurn() {
      return internals.openTurn;
    },
    settled: () => internals.settled().catch((error) => { throw unwrapFence(error); }),
    saveCheckpoint: () => internals.checkpoint(),
    exportCheckpoint: () => engine.checkpoint(),
    close: () => engine.close(),
  };
}

function toolEntries(tools) {
  if (Array.isArray(tools)) return tools;
  if (tools && typeof tools === "object") return Object.entries(tools).map(([name, tool]) => ({ ...tool, name: tool?.name ?? name }));
  return [];
}

function claimedTools(tools, ready) {
  const claimed = (tool) => (typeof tool?.execute !== "function" ? tool : {
    ...tool,
    async execute(...args) {
      if (!(await ready)) throw new Error("this worker's claim on the session failed");
      return tool.execute(...args);
    },
  });
  if (Array.isArray(tools)) return tools.map(claimed);
  if (tools && typeof tools === "object") return Object.fromEntries(Object.entries(tools).map(([name, tool]) => [name, claimed(tool)]));
  return tools;
}

function idempotentTools(tools) {
  const names = new Set();
  for (const [index, tool] of toolEntries(tools).entries()) {
    if (!tool || typeof tool !== "object" || tool.providerExecuted === true) continue;
    if (typeof tool.idempotent !== "boolean") {
      const name = typeof tool.name === "string" ? tool.name : index;
      throw new TypeError(`tool ${name} must set idempotent: true if running a call twice is safe, or idempotent: false if it is not`);
    }
    if (tool.idempotent && typeof tool.name === "string") names.add(tool.name);
  }
  return names;
}

function checkpointBytesOf(value) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  throw new TypeError("checkpoint must be bytes");
}

function snapshotOf(checkpoint) {
  const bytes = new Uint8Array(4 + 1 + 8 + 8 + 1 + checkpoint.byteLength);
  bytes.set(encoder.encode("FXSN"), 0);
  bytes[4] = 1;
  const view = new DataView(bytes.buffer);
  view.setBigUint64(5, 1n, true);
  view.setBigUint64(13, 1n, true);
  bytes[21] = 0;
  bytes.set(checkpoint, 22);
  return bytes;
}
