import { access, readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  createFxAgent as createWasmAgent,
  createFxTerminal as createWasmTerminal,
  encodeXtermKeyEvent,
  fxSdkApiVersion,
  supportsJspi,
  xtermAdapter,
} from "./fx-sdk.js";

export { encodeXtermKeyEvent, fxSdkApiVersion, supportsJspi, xtermAdapter };
export const libfxApiVersion = 2;

const fetchOperationStale = 0;
const fetchOperationApplied = 1;
const fetchOperationBackpressure = 2;

const require = createRequire(import.meta.url);
const defaultCoreWasm = new URL("./fx-core.wasm", import.meta.url);
const defaultTermWasm = new URL("./fx-term.wasm", import.meta.url);
const defaultNativeCandidates = [
  "./libfx.node",
  `./libfx.${process.platform}-${process.arch}.node`,
];
let nativeBackendPromise;
const wasmFilePromises = new Map();

function jspiFallbackError(surface, nativeError) {
  const nativeDetail = nativeError ? ` Native loading failed: ${nativeError.message}.` : " No compatible native addon was found.";
  const error = new Error(
    `libfx could not start the ${surface} backend.${nativeDetail} ` +
    "The WebAssembly fallback requires JavaScript Promise Integration (JSPI). " +
    "Run Node with --experimental-wasm-jspi or install a libfx package containing a compatible native addon.",
  );
  error.code = "LIBFX_JSPI_REQUIRED";
  error.cause = nativeError;
  return error;
}

async function loadNativeCandidate(candidate) {
  if (candidate == null) return null;
  if (candidate instanceof URL) {
    if (candidate.protocol === "file:" && candidate.pathname.endsWith(".node")) {
      return require(fileURLToPath(candidate));
    }
    const imported = await import(candidate.href);
    return imported.default ?? imported;
  }
  if (typeof candidate === "object") return candidate.default ?? candidate;
  if (typeof candidate !== "string") {
    throw new TypeError("nativeAddon must be a module, path, URL, false, or undefined");
  }
  if (candidate.endsWith(".node")) return require(isAbsolute(candidate) ? candidate : resolve(candidate));
  const imported = await import(candidate.startsWith("file:") ? candidate : pathToFileURL(candidate).href);
  return imported.default ?? imported;
}

function validateNativeBackend(backend) {
  if (!backend) return null;
  const hasLowLevelCore = typeof backend.createCore === "function";
  if ((hasLowLevelCore && backend.libfxApiVersion !== libfxApiVersion) ||
    (!hasLowLevelCore && backend.libfxApiVersion !== undefined && backend.libfxApiVersion !== libfxApiVersion)) {
    const actualVersion = backend.libfxApiVersion ?? "missing";
    throw new Error(`native addon API version ${actualVersion} is incompatible with libfx API version ${libfxApiVersion}`);
  }
  if (typeof backend.createCore !== "function" && typeof backend.createFxTerminal !== "function") {
    throw new Error("native addon must export createCore() or createFxTerminal()");
  }
  return backend;
}

async function discoverNativeBackend() {
  for (const relativePath of defaultNativeCandidates) {
    const url = new URL(relativePath, import.meta.url);
    try {
      await access(fileURLToPath(url));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      return { backend: null, error };
    }
    try {
      return { backend: validateNativeBackend(await loadNativeCandidate(url)), error: null };
    } catch (error) {
      return { backend: null, error };
    }
  }
  return { backend: null, error: null };
}

async function resolveNativeBackend(nativeAddon) {
  if (nativeAddon === false) return { backend: null, error: null };
  if (nativeAddon !== undefined) {
    try {
      return { backend: validateNativeBackend(await loadNativeCandidate(nativeAddon)), error: null };
    } catch (error) {
      return { backend: null, error };
    }
  }
  nativeBackendPromise ??= discoverNativeBackend();
  return nativeBackendPromise;
}

function wasmBytes(input) {
  let path;
  if (input instanceof URL && input.protocol === "file:") path = fileURLToPath(input);
  else if (typeof input === "string" && !URL.canParse(input)) path = resolve(input);
  else return input;
  const cached = wasmFilePromises.get(path);
  if (cached) return cached;
  const pending = readFile(path);
  wasmFilePromises.set(path, pending);
  pending.catch(() => {
    if (wasmFilePromises.get(path) === pending) wasmFilePromises.delete(path);
  });
  return pending;
}

function createNativeCoreRuntime(addon, options) {
  const { apiKey, model, gatewayChatUrl } = options;
  const core = addon.createCore({
    apiKey,
    home: options.home ?? homedir(),
    workspaceRoot: options.workspaceRoot ?? process.cwd(),
    ...(model === undefined ? {} : { model }),
    ...(gatewayChatUrl === undefined ? {} : { gatewayChatUrl }),
  });
  let exitedResolve;
  let lineHandler = null;
  let lineBuffer = "";
  let settled = false;
  let fetchState = null;
  const exited = new Promise((resolve) => { exitedResolve = resolve; });
  const abortHostEffects = () => {
    fetchState?.controller.abort();
    try { addon.abortCoreFetch(core); } catch {}
  };
  const finish = (code) => {
    if (settled) return;
    settled = true;
    clearInterval(timer);
    abortHostEffects();
    try { addon.destroyCore(core); } catch {}
    exitedResolve(code);
  };
  const pumpFetch = async (request) => {
    const controller = new AbortController();
    const state = { handle: request.handle, controller };
    fetchState = state;
    try {
      const response = await (options.fetch ?? globalThis.fetch)(request.url, {
        method: request.method,
        headers: new Headers(JSON.parse(request.headers).map(({ name, value }) => [name, value])),
        body: request.body?.length ? Buffer.from(request.body, "base64") : undefined,
        signal: controller.signal,
      });
      const started = addon.startCoreFetchResponse(core, state.handle, response.status);
      if (started === fetchOperationStale) return;
      if (started !== fetchOperationApplied) throw new Error(`invalid native fetch start result ${started}`);
      if (response.body) {
        for await (const chunk of response.body) {
          const buffer = Buffer.from(chunk);
          let offset = 0;
          while (offset < buffer.length) {
            const end = Math.min(offset + 64 * 1024, buffer.length);
            const pushed = addon.pushCoreFetchResponse(core, state.handle, buffer.subarray(offset, end));
            if (pushed === fetchOperationApplied) {
              offset = end;
              continue;
            }
            if (pushed === fetchOperationStale) return;
            if (pushed !== fetchOperationBackpressure) throw new Error(`invalid native fetch push result ${pushed}`);
            await new Promise((resolve) => setTimeout(resolve, 2));
          }
        }
      }
      const finished = addon.finishCoreFetch(core, state.handle);
      if (finished !== fetchOperationApplied && finished !== fetchOperationStale) {
        throw new Error(`invalid native fetch finish result ${finished}`);
      }
    } catch (error) {
      if (error?.name !== "AbortError" || !controller.signal.aborted) {
        try {
          if (addon.coreFetchActive(core, state.handle)) addon.failCoreFetch(core, state.handle);
        } catch {}
      }
    } finally {
      if (fetchState === state) fetchState = null;
    }
  };
  const timer = setInterval(() => {
    try {
      if (fetchState) {
        if (!fetchState.controller.signal.aborted && !addon.coreFetchActive(core, fetchState.handle)) {
          fetchState.controller.abort();
        }
      } else {
        const fetchRequest = addon.takeCoreFetch(core);
        if (fetchRequest) void pumpFetch(JSON.parse(fetchRequest.toString("utf8")));
      }
      const chunk = addon.drainCore(core);
      if (chunk.length && lineHandler) {
        lineBuffer += chunk.toString("utf8");
        for (;;) {
          const newline = lineBuffer.indexOf("\n");
          if (newline < 0) break;
          const line = lineBuffer.slice(0, newline);
          lineBuffer = lineBuffer.slice(newline + 1);
          if (line) void Promise.resolve(lineHandler(JSON.parse(line))).catch(() => finish(1));
        }
      }
      if (addon.coreExited(core)) finish(addon.coreExitCode(core));
    } catch {
      finish(1);
    }
  }, 2);

  return {
    exited,
    write(data) { addon.writeCore(core, Buffer.from(data)); },
    closeStdin() { addon.closeCore(core); },
    abortHostEffects,
    abort() { abortHostEffects(); addon.closeCore(core); },
    setLineHandler(handler) { lineHandler = handler; },
  };
}

function createNativeAgent(addon, options) {
  return createWasmAgent({
    ...options,
    runtimeFactory(runtimeOptions) {
      return createNativeCoreRuntime(addon, runtimeOptions);
    },
  });
}

async function createWithFallback(surface, nativeMethod, wasmFactory, defaultWasm, options) {
  const { nativeAddon, backend = "auto", ...runtimeOptions } = options ?? {};
  if (!new Set(["auto", "native", "wasm"]).has(backend)) {
    throw new TypeError('backend must be "auto", "native", or "wasm"');
  }

  let nativeError;
  let nativeAttempted = false;
  if (backend !== "wasm") {
    const native = await resolveNativeBackend(nativeAddon);
    nativeError = native.error;
    if (typeof native.backend?.[nativeMethod] === "function") {
      nativeAttempted = true;
      try {
        if (surface === "agent") return await createNativeAgent(native.backend, runtimeOptions);
        return await native.backend[nativeMethod](runtimeOptions);
      } catch (error) {
        nativeError = error;
        if (backend === "native") throw error;
      }
    }
    if (backend === "native") {
      const error = nativeError ?? new Error(`native addon does not provide ${nativeMethod}()`);
      error.code ??= "LIBFX_NATIVE_UNAVAILABLE";
      throw error;
    }
  }

  if (!supportsJspi()) {
    if (nativeAttempted) throw nativeError;
    throw jspiFallbackError(surface, nativeError);
  }
  return wasmFactory({
    ...runtimeOptions,
    wasm: await wasmBytes(runtimeOptions.wasm ?? defaultWasm),
  });
}

export async function createFxAgent(options = {}) {
  if (options != null && Object.hasOwn(Object(options), "env")) {
    throw new TypeError("createFxAgent() does not accept env; pass apiKey and model directly");
  }
  return createWithFallback(
    "agent",
    "createCore",
    createWasmAgent,
    defaultCoreWasm,
    options,
  );
}

export function createFxTerminal(options = {}) {
  return createWithFallback("terminal", "createFxTerminal", createWasmTerminal, defaultTermWasm, options);
}
