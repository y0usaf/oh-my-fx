
class FencedError extends Error {
  constructor(message) {
    super(message);
    this.name = "FencedError";
    this.code = "FX_FENCED";
  }
}

const durabilityTag = Symbol.for("libfx.durability");
const encoder = new TextEncoder();
const decoder = new TextDecoder();

const idPattern = /^[A-Za-z0-9._-]{1,128}$/;
const validId = (id) => typeof id === "string" && idPattern.test(id);
const idRule = "1 to 128 letters, digits, '.', '_' or '-'";
const newId = (prefix) => `${prefix}_${crypto.randomUUID().replaceAll("-", "")}`;

const defaultReserveMs = 30_000;
const defaultLeaseMs = 15_000;

const queueHeld = (backend, deadline) => !backend.livenessKnown && backend.queueLeases === true && deadline !== null;
const heldToDeadline = (backend, deadline) => backend.livenessKnown || queueHeld(backend, deadline);

function leaseEnd(backend, deadline) {
  if (heldToDeadline(backend, deadline)) return deadline;
  const renewed = Date.now() + backend.leaseMs;
  return deadline === null ? renewed : Math.min(renewed, deadline);
}
const recentIdsKept = 256;
const maxBackstopSeconds = 300;

const toBase64 = (bytes) => {
  let text = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    text += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(text);
};
const fromBase64 = (text) => Uint8Array.from(atob(text), (char) => char.charCodeAt(0));

/**
 * The durability that keeps sessions in this process only. Agents given the
 * same `memory()` share its sessions, as servers share a database. With
 * `maxDurationMs`, each delivery runs as if its function stopped after that
 * long, stopping `reserveMs` before, as on Vercel.
 */
export function memory({ maxDurationMs, reserveMs } = {}) {
  checkDurations("memory", { maxDurationMs, reserveMs });
  let backend = null;
  return { [durabilityTag]: true, name: "memory", create: () => (backend ??= createMemoryBackend({ maxDurationMs, reserveMs })) };
}

function checkDurations(name, { maxDurationMs, reserveMs }) {
  for (const [key, value] of Object.entries({ maxDurationMs, reserveMs })) {
    if (value !== undefined && !(Number.isSafeInteger(value) && value >= 0)) throw new TypeError(`${name}() ${key} must be a non-negative integer`);
  }
}

function isDurability(value) {
  return Boolean(value && typeof value === "object" && value[durabilityTag] === true &&
    (typeof value.create === "function" || typeof value.world === "function"));
}

async function createBackend(durability) {
  if (typeof durability.create === "function") return durability.create();
  checkDurations(durability.name, durability);
  return createWorldBackend(await durability.world(), durability);
}

const liveHolders = (globalThis[Symbol.for("libfx.liveHolders")] ??= new Set());

const maxHarnessStops = 3;
const maxCancelStops = 2;
const maxCutoffs = 3;

const noCutoffs = { cutoffs: 0, cutStep: null, step: null, named: false };
function afterRecord(cut, marks) {
  let next = cut;
  for (const mark of marks ?? []) {
    if (typeof mark.start === "string") next = noCutoffs;
    else if (typeof mark.step === "string") next = { ...next, step: mark.step, named: true };
  }
  return next.named ? next : { ...next, cutoffs: 0 };
}
function afterCutoff(cut) {
  const same = !cut.named || cut.step === cut.cutStep;
  return { ...cut, cutoffs: same ? cut.cutoffs + 1 : 1, cutStep: cut.step };
}

/**
 * Folds a session's log into what a worker acts on. `entries` are
 * `{ cursor, entry }` in log order from the latest checkpoint's `through`;
 * cursors are increasing integer strings. `now` and `alive(lease)` decide
 * whether a lease stands; `alive` returns true, false, or null for unknown.
 */
export function foldSessionLog(entries, { now = 0, alive = () => null } = {}) {
  let checkpoint = null;
  for (const item of entries) if (item.entry?.k === "checkpoint") checkpoint = item;
  const base = checkpoint?.entry ?? null;
  let head = base ? base.through ?? null : null;
  let lease = base?.lease ?? null;
  let epoch = base?.lease?.epoch ?? 0;
  const consumed = new Set(base?.recent ?? []);
  const recent = [...(base?.recent ?? [])];
  const baseSteers = new Set(base?.recentSteers ?? []);
  const kindsKnown = base === null || Array.isArray(base?.recentSteers);
  const held = new Set(base?.held ?? []);
  for (const id of held) consumed.add(id);
  const seenInputs = new Set();
  const inputs = [];
  const records = [];
  let openTurn = typeof base?.openTurn?.id === "string" ? { id: base.openTurn.id, at: Number(base.openTurn.at) || 0, from: Number(base.openTurn.from ?? base.openTurn.at) || 0, context: base.openTurn.context ?? null, settings: base.openTurn.settings ?? null } : null;
  let lastTurnId = base?.lastTurnId ?? null;
  let agent = typeof base?.agent === "string" ? base.agent : base && base.through != null ? defaultAgentName : null;
  let yielded = base?.yielded === true;
  const contexts = new Map();
  const settingsOf = new Map();
  for (const input of base?.pending ?? []) {
    if (input.context !== undefined) contexts.set(input.messageId, input.context);
    if (input.settings !== undefined) settingsOf.set(input.messageId, input.settings);
  }
  const stops = new Map();
  const failed = new Map();
  let cut = noCutoffs;
  let maxCursor = 0;
  const consume = (id) => {
    if (consumed.has(id)) return;
    consumed.add(id);
    recent.push(id);
  };
  const handBack = (id) => {
    if (!consumed.delete(id)) return;
    const index = recent.lastIndexOf(id);
    if (index >= 0) recent.splice(index, 1);
  };
  for (const input of base?.pending ?? []) {
    if (seenInputs.has(input.key)) continue;
    seenInputs.add(input.key);
    inputs.push(input);
  }
  for (const { cursor, entry } of entries) {
    const position = Number(cursor);
    if (position > maxCursor) maxCursor = position;
    switch (entry?.k) {
      case "input":
        agent ??= typeof entry.agent === "string" ? entry.agent : defaultAgentName;
        if (seenInputs.has(entry.key)) break;
        seenInputs.add(entry.key);
        inputs.push({ ...entry, cursor: position });
        if (entry.context !== undefined) contexts.set(entry.messageId, entry.context);
        if (entry.settings !== undefined) settingsOf.set(entry.messageId, entry.settings);
        break;
      case "lease":
      case "release":
      case "record": {
        if ((entry.a ?? null) !== head) break;
        head = cursor;
        if (entry.k === "lease") {
          lease = { holder: entry.holder, epoch: entry.epoch, expiresAt: entry.expiresAt ?? null, pid: entry.pid, host: entry.host, delivery: entry.delivery, cursor };
          if (Number.isSafeInteger(entry.epoch) && entry.epoch > epoch) epoch = entry.epoch;
        } else if (entry.k === "release") {
          if (lease?.holder === entry.holder) lease = null;
          if (typeof entry.cutoff === "string" && entry.cutoff === openTurn?.id) cut = afterCutoff(cut);
        } else {
          cut = afterRecord(cut, entry.marks);
          records.push({ cursor, data: entry.data });
          for (const mark of entry.marks ?? []) {
            if (typeof mark.start === "string") {
              const opener = inputs.find((input) => input.messageId === mark.start);
              openTurn = { id: mark.start, at: position, from: opener?.cursor ?? position, context: contexts.get(mark.start) ?? null, settings: settingsOf.get(mark.start) ?? null };
              consume(mark.start);
              yielded = false;
            } else if (mark.end === true) {
              if (openTurn) lastTurnId = openTurn.id;
              openTurn = null;
              yielded = false;
              held.clear();
            } else if (mark.yield === true) {
              yielded = true;
            } else if (typeof mark.accepted === "string") {
              consume(mark.accepted);
              held.add(mark.accepted);
            } else if (typeof mark.placed === "string") {
              held.delete(mark.placed);
            } else if (typeof mark.withdrawn === "string") {
              held.delete(mark.withdrawn);
              handBack(mark.withdrawn);
            }
          }
        }
        break;
      }
      case "failed":
        failed.set(entry.messageId, entry.error ?? { name: "Error", message: "the turn failed" });
        consume(entry.messageId);
        break;
      case "ended":
        consume(entry.messageId);
        break;
      case "stopped":
        stops.set(entry.messageId, (stops.get(entry.messageId) ?? 0) + 1);
        break;
      default:
        break;
    }
  }
  const cancelTargets = new Set();
  for (const input of inputs) {
    if (input.type === "cancel" && typeof input.target === "string") cancelTargets.add(input.target);
  }
  const openFailed = openTurn !== null && failed.has(openTurn.id);
  const pending = [];
  const steers = [];
  const openOwner = openTurn !== null && !openFailed ? { joiners: steers, ends: false } : null;
  let cancelOpen = false;
  let owner = null;
  for (const input of inputs) {
    if (openOwner !== null && owner === null && input.cursor > openTurn.from) owner = openOwner;
    if (consumed.has(input.messageId)) continue;
    const forOpenTurn = openTurn !== null && input.cursor > openTurn.at;
    if (input.type === "prompt") {
      const entry = { ...input, ...(cancelTargets.has(input.messageId) ? { cancelled: true } : {}), joiners: [], ends: false };
      pending.push(entry);
      if (owner === null || owner !== openOwner) owner = entry;
    } else if (input.type === "steer") {
      if (owner !== null && joinable(input.input)) owner.joiners.push(input);
      else {
        if (owner !== null) owner.ends = true;
        owner = { ...input, type: "prompt", joiners: [], ends: false };
        pending.push(owner);
      }
    } else if (input.type === "cancel") {
      if (typeof input.target === "string") {
        if (openTurn?.id === input.target) cancelOpen = true;
      } else if (forOpenTurn) cancelOpen = true;
    }
  }
  for (const input of inputs) {
    if (consumed.has(input.messageId)) continue;
    if (input.type === "resume") {
      consume(input.messageId);
      continue;
    }
    if (input.type !== "cancel") continue;
    const live = typeof input.target === "string"
      ? !consumed.has(input.target) || openTurn?.id === input.target
      : openTurn !== null && input.cursor > openTurn.at;
    if (!live) consume(input.messageId);
  }
  const openStops = openTurn === null ? 0 : stops.get(openTurn.id) ?? 0;
  const halted = openStops >= maxHarnessStops + maxCancelStops;
  const stuck = openStops >= maxHarnessStops && !halted;
  const kinds = new Map(inputs.map((input) => [input.messageId, input.type]));
  const kindOf = (id) => kinds.get(id) ?? (baseSteers.has(id) ? "steer" : kindsKnown ? "prompt" : null);
  return {
    unconsumed: inputs.filter((input) => !consumed.has(input.messageId)),
    held: inputs.filter((input) => held.has(input.messageId)),
    heldIds: [...held],
    endOpen: openOwner?.ends === true,
    head,
    lease: leaseStands(lease, now, alive) ? lease : null,
    lastLease: lease,
    lastEpoch: epoch,
    checkpoint: base ? { through: base.through ?? null, data: base.data } : null,
    records,
    openTurn,
    cut: openTurn === null ? noCutoffs : cut,
    cutoffs: openTurn === null ? 0 : cut.cutoffs,
    openFailed,
    lastTurnId,
    agent,
    yielded,
    pending,
    steers,
    cancelOpen,
    recent: recent.slice(-recentIdsKept),
    recentSteers: recent.slice(-recentIdsKept).filter((id) => kindOf(id) === "steer"),
    consumedKind: (id) => (consumed.has(id) ? kindOf(id) : null),
    consumed,
    failed,
    stops,
    inputKeys: seenInputs,
    maxCursor,
    stuck,
    halted,
    hasWork: (openTurn !== null && !openFailed) || pending.length > 0,
  };
}

function leaseStands(lease, now, alive) {
  if (!lease) return false;
  const living = alive(lease);
  if (living === false) return false;
  if (lease.expiresAt !== null && lease.expiresAt !== undefined && now >= lease.expiresAt) return false;
  return true;
}

function deliveryOf(meta) {
  const messageId = meta?.messageId;
  const attempt = meta?.attempt;
  return typeof messageId === "string" && messageId.length > 0 && Number.isSafeInteger(attempt) && attempt > 0
    ? { messageId, attempt }
    : null;
}

function redelivers(delivery, lease) {
  const held = lease?.delivery;
  return Boolean(delivery && held && held.messageId === delivery.messageId &&
    Number.isSafeInteger(held.attempt) && delivery.attempt >= held.attempt);
}

function createMemoryBackend({ maxDurationMs, reserveMs } = {}) {
  const sessions = new Map();
  const holders = liveHolders;
  const handlers = new Map();
  const timers = new Set();
  const sessionFor = (id) => {
    let session = sessions.get(id);
    if (!session) {
      session = { entries: [], head: null, ui: [], uiWaiters: new Set(), watchers: new Set() };
      sessions.set(id, session);
    }
    return session;
  };
  const later = (fn, ms) => {
    const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms);
    timers.add(timer);
  };
  const deliver = (message, attempt, messageId = newId("qmsg")) => {
    if (handlers.size === 0) return later(() => deliver(message, attempt, messageId), 10);
    const group = handlers.get(agentOf(message));
    if (!group) {
      if (attempt < 48) later(() => deliver(message, attempt + 1, messageId), 1000);
      return;
    }
    const handler = group.members[group.turn++ % group.members.length];
    Promise.resolve()
      .then(() => handler(message, { messageId, attempt }))
      .then((result) => {
        if (Number.isFinite(result?.timeoutSeconds)) later(() => deliver(message, attempt + 1, messageId), result.timeoutSeconds * 1000);
      }, () => {
        if (attempt < 48) later(() => deliver(message, attempt + 1, messageId), 1000);
      });
  };
  return {
    name: "memory",
    livenessKnown: true,
    runInRequest: false,
    queueDurable: false,
    pollMs: null,
    reserveMs: reserveMs ?? defaultReserveMs,
    maxDurationMs: maxDurationMs ?? null,
    newSessionId: () => newId("ses"),
    validSessionId: validId,
    deadline: () => null,
    holderInfo: () => ({}),
    alive: (lease) => holders.has(lease.holder),
    holding(holder, held) {
      if (held) holders.add(holder);
      else holders.delete(holder);
    },
    async session(id) {
      const session = sessionFor(id);
      return {
        async read() {
          let from = 0;
          for (let index = session.entries.length - 1; index >= 0; index -= 1) {
            const entry = session.entries[index].entry;
            if (entry.k === "checkpoint") {
              from = entry.through === null ? 0 : Number(entry.through);
              break;
            }
          }
          return session.entries.slice(from);
        },
        async readSince(cursor) {
          return session.entries.slice(Number(cursor));
        },
        async append(entry) {
          const chained = entry.k === "lease" || entry.k === "release" || entry.k === "record";
          if (chained && (entry.a ?? null) !== session.head) {
            const landed = session.entries.find((item) => item.entry.key !== undefined && item.entry.key === entry.key && item.entry.k === entry.k);
            if (landed) return landed.cursor;
            throw new FencedError(`another worker continued session ${id}`);
          }
          const cursor = String(session.entries.length + 1);
          session.entries.push({ cursor, entry: structuredClone(entry) });
          if (chained) session.head = cursor;
          for (const watcher of session.watchers) watcher();
          return cursor;
        },
        watch(fn) {
          session.watchers.add(fn);
          return () => session.watchers.delete(fn);
        },
        ui: {
          async write(lines) {
            session.ui.push(...lines);
            for (const waiter of session.uiWaiters) waiter();
          },
          async length() {
            return session.ui.length;
          },
          read(from) {
            let index = from;
            let wake = null;
            const notify = () => wake?.();
            return new ReadableStream({
              start() { session.uiWaiters.add(notify); },
              async pull(controller) {
                while (index >= session.ui.length) await new Promise((resolve) => { wake = resolve; });
                wake = null;
                controller.enqueue(encoder.encode(`${session.ui[index++]}\n`));
              },
              cancel() { session.uiWaiters.delete(notify); notify(); },
            });
          },
        },
      };
    },
    queue: {
      async send(message, { delaySeconds = 0 } = {}) {
        later(() => deliver(message, 1), delaySeconds * 1000);
      },
    },
    listen(fn, name = defaultAgentName) {
      const group = joinGroup(handlers, name, fn);
      return () => {
        leaveGroup(handlers, name, group, fn);
        if (handlers.size > 0) return;
        for (const timer of timers) clearTimeout(timer);
        timers.clear();
      };
    },
  };
}

const logStep = "fx.log";
const uiStreamOf = (runId) => `${runId.replace(/^wrun_/, "strm_")}_user_bGliZngtdWk`;
const queuePrefix = "__libfx_wkf_workflow_";
const defaultAgentName = "default";
const agentNameRule = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const agentOf = (message) => (typeof message?.agent === "string" ? message.agent : defaultAgentName);
const queueName = `${queuePrefix}session`;
const eventIdPattern = /^[a-z]+_(\d{26})$/;

function ulid(now = Date.now()) {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let time = "";
  for (let rest = now, index = 0; index < 10; index += 1, rest = Math.floor(rest / 32)) time = alphabet[rest % 32] + time;
  let random = "";
  for (const byte of crypto.getRandomValues(new Uint8Array(16))) random += alphabet[byte % 32];
  return time + random;
}

function chainedKind(k) {
  return k === "lease" || k === "release" || k === "record";
}

const inBandAtRunCreation = 1;

function inBandSuperseded(error) {
  return error?.name === "InBandSupersededError" || error?.code === "in-band-superseded" || error?.status === 412;
}

function slotOf(event) {
  const match = eventIdPattern.exec(String(event?.eventId ?? ""));
  if (!match) throw new Error(`the World returned event id ${JSON.stringify(event?.eventId ?? null)}, which holds no slot`);
  return Number(match[1]);
}

function logEntryOf(event) {
  if (event?.eventType !== "step_created" || event.eventData?.stepName !== logStep) return null;
  const input = event.eventData.input;
  if (!(input instanceof Uint8Array)) return null;
  try { return JSON.parse(decoder.decode(input)); } catch { return null; }
}

const missingRun = (error) => error?.status === 404 || /not found|does not exist|ENOENT/i.test(String(error?.message ?? ""));
const streamReadRetries = 5;
const missingStreamPollMs = 50;
const missingStreamFastMs = 2000;

const firstPageEvents = 10;
const laterPageEvents = 100;

const listenersOf = new WeakMap();

function joinGroup(groups, name, member) {
  let group = groups.get(name);
  if (!group) groups.set(name, group = { members: [], turn: 0 });
  group.members.push(member);
  return group;
}

function leaveGroup(groups, name, group, member) {
  const index = group.members.indexOf(member);
  if (index >= 0) group.members.splice(index, 1);
  if (group.members.length === 0 && groups.get(name) === group) groups.delete(name);
}

function noAgentNamed(name) {
  return Object.assign(new Error(`no libfx agent named ${JSON.stringify(name)} runs in this process; the queue delivers this again`), { code: "FX_NO_AGENT", agent: name });
}

const agentsByName = (globalThis[Symbol.for("libfx.durableAgents")] ??= new Map());

const openMember = (member) => member.open().catch(() => null);

async function agentNamed(name, matches) {
  const group = agentsByName.get(name);
  if (!group) return null;
  const { members } = group;
  const first = group.turn++;
  for (let index = 0; index < members.length; index += 1) {
    const member = members[(first + index) % members.length];
    if (!matches(await member.durability())) continue;
    const created = await openMember(member);
    if (typeof created?.deliverHere === "function") return created;
  }
  return null;
}

const agentSharing = (name, durability) => agentNamed(name, (other) => other === durability);

const worldStore = (durability) => durability?.store ?? durability?.name;

const storeOf = (durability) => (typeof durability?.create === "function" ? durability : `world:${worldStore(durability)}`);

const agentOnStore = (name, store) => agentNamed(name, (other) => typeof other.world === "function" && other.create === undefined && worldStore(other) === store);

/**
 * The request handler a deployment mounts for queue deliveries, for every
 * durable agent in the process: each delivery goes to the agent its message
 * names, on the store it names. One route and one queue trigger serve any
 * number of agents.
 */
export function wakeHandler() {
  return async (request) => {
    for (const group of agentsByName.values()) {
      for (const member of group.members) {
        const created = await openMember(member);
        if (created?.viaRoute === true) return created.queueHandler(request);
      }
    }
    return new Response("no libfx agent in this process takes queue deliveries from a route", { status: 503 });
  };
}

const nameInUse = (name) => Object.assign(
  new Error(`an agent named ${JSON.stringify(name)} with another configuration already runs on this store in this process; give each configuration its own name, or each store its own \`store\``),
  { code: "FX_AGENT_NAME_IN_USE", agent: name },
);

function definitionOf(options) {
  const { onEvent: _onEvent, ...definition } = options;
  return definition;
}
function sameDefinition(a, b, depth = 0) {
  if (Object.is(a, b)) return true;
  if (depth > 32 || a === null || b === null || typeof a !== "object" || typeof b !== "object") return false;
  if (ArrayBuffer.isView(a) || ArrayBuffer.isView(b)) {
    if (!ArrayBuffer.isView(a) || !ArrayBuffer.isView(b) || a.byteLength !== b.byteLength) return false;
    const left = new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
    const right = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
    for (let index = 0; index < left.length; index += 1) if (left[index] !== right[index]) return false;
    return true;
  }
  const plain = (value) => Array.isArray(value) || Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null;
  if (!plain(a) || !plain(b) || Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => Object.hasOwn(b, key) && sameDefinition(a[key], b[key], depth + 1));
}

const sameStore = (a, b) => a.store === b.store || (a.defaults !== null && a.defaults === b.defaults);
function claimName(name, member) {
  for (const other of agentsByName.get(name)?.members ?? []) {
    if (other !== member && sameStore(other, member) && !sameDefinition(other.definition, member.definition)) throw nameInUse(name);
  }
}

function createWorldBackend(world, durability) {
  const { name, reserveMs, pollMs, leaseMs, alive, holderInfo, livenessKnown = false, queueLeases = false, runInRequest = queueLeases, waitUntil, queueDurable = false, maxDurationMs, owned = true } = durability;
  const spec = world.specVersion === undefined ? {} : { specVersion: world.specVersion };
  const created = new Set();
  const creating = new Map();
  const watchers = new Map();
  const changed = (runId) => { for (const watcher of watchers.get(runId) ?? []) watcher(); };
  let handler = null;
  const route = typeof world.registerHandler !== "function";
  const listEvents = (runId, cursor, limit) => world.events.list({
    runId,
    pagination: { sortOrder: "desc", limit, ...(cursor ? { cursor } : {}) },
    resolveData: "all",
  });
  const deliverTo = async (handle, message, meta) => {
    const input = message?.input;
    if (!input || typeof input !== "object") return undefined;
    if (!handle) {
      if (owned) return undefined;
      throw new Error("no libfx agent is listening; the queue delivers this again");
    }
    const result = await handle(input, meta);
    if (result?.redeliver === true) throw new Error("libfx asks the queue to deliver this message again");
    return Number.isFinite(result?.timeoutSeconds) ? { timeoutSeconds: result.timeoutSeconds } : undefined;
  };
  const store = worldStore(durability);
  const queueHandler = world.createQueueHandler(queuePrefix, async (message, meta) => {
    const named = agentOf(message?.input);
    const agent = await agentOnStore(named, typeof message?.input?.store === "string" ? message.input.store : store);
    if (!agent) throw noAgentNamed(named);
    return agent.deliverHere(message, meta);
  });
  const backend = {
    name,
    store,
    livenessKnown,
    queueLeases,
    runInRequest: queueLeases && runInRequest,
    waitUntil: waitUntil ?? null,
    queueDurable,
    pollMs: pollMs ?? 1000,
    reserveMs: reserveMs ?? defaultReserveMs,
    leaseMs: leaseMs ?? defaultLeaseMs,
    maxDurationMs: maxDurationMs ?? null,
    world,
    newSessionId: () => `wrun_${typeof world.createRunId === "function" ? world.createRunId({}) : ulid()}`,
    validSessionId: (id) => typeof id === "string" && /^wrun_[0-9A-Za-z]{10,64}$/.test(id),
    deadline: () => null,
    holderInfo: holderInfo ?? (() => ({})),
    alive(lease, delivery = null) {
      if (liveHolders.has(lease.holder)) return true;
      const mine = holderInfo?.() ?? {};
      if (mine.pid !== undefined && lease.pid === mine.pid && lease.host === mine.host) return false;
      if (redelivers(delivery, lease)) return false;
      return alive ? alive(lease) : null;
    },
    holding(holder, held) {
      if (held) liveHolders.add(holder);
      else liveHolders.delete(holder);
    },
    async start() {
      if (owned) await world.start?.();
      if (typeof world.getRuntimeDeadline === "function") {
        backend.deadline = () => backend.runtimeDeadline ?? null;
      }
    },
    async refreshDeadline() {
      if (typeof world.getRuntimeDeadline !== "function") return;
      try {
        const deadline = await world.getRuntimeDeadline();
        backend.runtimeDeadline = deadline instanceof Date ? deadline.getTime() : null;
      } catch {
        backend.runtimeDeadline = null;
      }
    },
    async session(runId) {
      let known = 0;
      const inBandAt = new Map();
      let inBand = world.capabilities?.inBandFence === true;
      const noteInBand = (cursor, count) => {
        inBandAt.delete(cursor);
        inBandAt.set(cursor, count);
        if (inBandAt.size > 16) inBandAt.delete(inBandAt.keys().next().value);
      };
      const noteSnapshot = (snapshot, cursor) => {
        if (!inBand || cursor === undefined || inBandAt.has(cursor) || !Number.isSafeInteger(snapshot?.seqInBand)) return;
        if (cursor !== "null" && !(Number(cursor) <= snapshot.seq)) return;
        noteInBand(cursor, snapshot.seqInBand);
      };
      const ensureRun = () => {
        if (created.has(runId)) return Promise.resolve();
        let pending = creating.get(runId);
        if (!pending) {
          pending = createRun().finally(() => creating.delete(runId));
          creating.set(runId, pending);
        }
        return pending;
      };
      const createRun = async () => {
        try {
          const deploymentId = typeof world.getDeploymentId === "function" ? await world.getDeploymentId() : "libfx";
          await world.events.create(runId, {
            eventType: "run_created",
            ...spec,
            eventData: { deploymentId, workflowName: "libfx/session", input: encoder.encode("{}") },
          });
        } catch (error) {
          if (!/exist|conflict|409|already/i.test(String(error?.message ?? "")) && error?.status !== 409) throw error;
        }
        try {
          await world.events.create(runId, { eventType: "run_started", ...spec });
        } catch (error) {
          if (!/exist|conflict|409|already|started|status/i.test(String(error?.message ?? "")) && error?.status !== 409) throw error;
        }
        created.add(runId);
      };
      const newestFirst = async (stopBelow, stopAtCheckpoint) => {
        const events = [];
        let through = null;
        let snapshot;
        let newestChained;
        const done = (head) => {
          noteSnapshot(snapshot, newestChained ?? head);
          return { events, through };
        };
        for (let cursor, limit = firstPageEvents; ; limit = laterPageEvents) {
          let page;
          try {
            page = await listEvents(runId, cursor, limit);
          } catch (error) {
            if (!missingRun(error)) throw error;
            if (stopBelow === 0) noteSnapshot({ seq: 0, seqInBand: inBandAtRunCreation }, "null");
            return { events, through };
          }
          snapshot ??= page.snapshot;
          for (const event of page.data) {
            const slot = slotOf(event);
            if (slot > known) known = slot;
            if (slot <= stopBelow) return done(undefined);
            if (through !== null && slot <= through) return done(through === 0 ? "null" : String(through));
            const entry = logEntryOf(event);
            if (!entry) continue;
            created.add(runId);
            if (newestChained === undefined && chainedKind(entry.k)) newestChained = String(slot);
            events.push({ cursor: String(slot), entry });
            if (stopAtCheckpoint && through === null && entry.k === "checkpoint") {
              through = entry.through === null || entry.through === undefined ? 0 : Number(entry.through);
            }
          }
          if (!page.hasMore) return done(stopBelow > 0 ? undefined : through ? String(through) : "null");
          cursor = page.cursor;
        }
      };
      return {
        async read() {
          const { events } = await newestFirst(0, true);
          return events.reverse();
        },
        async readSince(cursor) {
          const { events } = await newestFirst(Number(cursor), false);
          return events.reverse();
        },
        async append(entry) {
          await ensureRun();
          const chained = chainedKind(entry.k);
          const after = chained ? (entry.a === null || entry.a === undefined ? 0 : Number(entry.a)) : known;
          const continues = entry.a === null || entry.a === undefined ? "null" : String(entry.a);
          let expected = chained && inBand ? inBandAt.get(continues) : undefined;
          const event = {
            eventType: "step_created",
            correlationId: `step_${ulid()}`,
            eventData: { stepName: logStep, input: encoder.encode(JSON.stringify(entry)) },
          };
          let result;
          for (let recounted = false; ;) {
            try {
              result = await world.events.create(runId, event, expected === undefined ? { eventCount: after } : { eventCount: after, inBand: true, expectedSeqInBand: expected });
              break;
            } catch (error) {
              if (expected === undefined) throw error;
              if (inBandSuperseded(error)) {
                inBandAt.delete(continues);
                if (!recounted && Number.isSafeInteger(error?.seqInBand)) {
                  const { events: since } = await newestFirst(after, false);
                  const rivals = since.filter(({ entry: other }) => chainedKind(other.k) && (other.a ?? null) === (entry.a ?? null));
                  const ours = rivals.find(({ entry: other }) => other.key !== undefined && other.key === entry.key && other.k === entry.k);
                  if (ours) return ours.cursor;
                  if (rivals.length === 0) {
                    recounted = true;
                    expected = error.seqInBand;
                    continue;
                  }
                }
                throw new FencedError(`another worker continued session ${runId}`);
              }
              if (!(error?.status >= 400 && error?.status < 500) || error?.status === 409) throw error;
              inBand = false;
              expected = undefined;
            }
          }
          const slot = slotOf(result.event);
          if (slot > known) known = slot;
          if (expected !== undefined && result.allocated !== undefined) noteInBand(String(slot), expected + result.allocated);
          changed(runId);
          if (!chained || slot === after + 1) return String(slot);
          const reported = Array.isArray(result.events) ? result.events : (await newestFirst(after, false)).events.map((item) => ({ eventId: `evnt_${String(item.cursor).padStart(26, "0")}`, ...item }));
          for (const event of reported) {
            const other = event.entry ?? logEntryOf(event);
            const otherSlot = event.entry ? Number(event.cursor) : slotOf(event);
            if (!other || otherSlot <= after || otherSlot >= slot) continue;
            const otherChained = chainedKind(other.k);
            if (!otherChained || (other.a ?? null) !== (entry.a ?? null)) continue;
            if (other.key !== undefined && other.key === entry.key && other.k === entry.k) return String(otherSlot);
            throw new FencedError(`another worker continued session ${runId}`);
          }
          return String(slot);
        },
        watch(fn) {
          let set = watchers.get(runId);
          if (!set) watchers.set(runId, set = new Set());
          set.add(fn);
          return () => set.delete(fn);
        },
        ui: {
          async write(lines) {
            await ensureRun();
            const chunks = lines.map((line) => `${line}\n`);
            if (typeof world.streams.writeMulti === "function" && chunks.length > 1) await world.streams.writeMulti(runId, uiStreamOf(runId), chunks);
            else for (const chunk of chunks) await world.streams.write(runId, uiStreamOf(runId), chunk);
          },
          async length() {
            try {
              const info = await world.streams.getInfo(runId, uiStreamOf(runId));
              return Math.max(0, Number(info?.tailIndex ?? -1) + 1);
            } catch {
              return 0;
            }
          },
          read(from) {
            let reader = null;
            let cancelled = false;
            const opened = Date.now();
            return new ReadableStream({
              async pull(controller) {
                for (let delay = missingStreamPollMs, failures = 0; !reader;) {
                  if (cancelled) return;
                  try {
                    reader = (await world.streams.get(runId, uiStreamOf(runId), from)).getReader();
                  } catch (error) {
                    const missing = missingRun(error);
                    if (!missing && ++failures > streamReadRetries) {
                      controller.error(error);
                      return;
                    }
                    await new Promise((resolve) => setTimeout(resolve, delay));
                    delay = missing && Date.now() - opened < missingStreamFastMs ? missingStreamPollMs : Math.min(delay * 2, 1000);
                  }
                }
                const { value, done } = await reader.read();
                if (done) controller.close();
                else controller.enqueue(typeof value === "string" ? encoder.encode(value) : value);
              },
              cancel() {
                cancelled = true;
                void reader?.cancel().catch(() => {});
              },
            });
          },
        },
      };
    },
    queue: {
      async send(message, { delaySeconds = 0, idempotencyKey } = {}) {
        const sent = await world.queue(queueName, { runId: message.sessionId, requestId: message.messageId, input: message }, {
          ...(idempotencyKey ? { idempotencyKey } : {}),
          ...(delaySeconds > 0 ? { delaySeconds } : {}),
        });
        return typeof sent?.messageId === "string" && sent.messageId.length > 0 ? { messageId: sent.messageId } : {};
      },
    },
    queueHandler,
    durability,
    viaRoute: route,
    deliverHere: (message, meta) => deliverTo(handler, message, meta),
    listen(fn, name = defaultAgentName) {
      handler = fn;
      if (route) return () => { if (handler === fn) handler = null; };
      let listeners = listenersOf.get(world);
      if (!listeners) {
        listeners = new Map();
        listenersOf.set(world, listeners);
        world.registerHandler(queuePrefix, world.createQueueHandler(queuePrefix, async (message, meta) => {
          const named = agentOf(message?.input);
          const group = listeners.get(named);
          if (group) return deliverTo(group.members[group.turn++ % group.members.length], message, meta);
          const agent = await agentSharing(named, durability);
          if (agent) return agent.deliverHere(message, meta);
          if (listeners.size === 0) return deliverTo(null, message, meta);
          throw noAgentNamed(named);
        }));
      }
      const group = joinGroup(listeners, name, fn);
      return () => {
        if (handler === fn) handler = null;
        leaveGroup(listeners, name, group, fn);
      };
    },
    async close() {
      if (!owned) return;
      try {
        await world.close?.();
      } catch {}
    },
  };
  return backend;
}


function uiWriter(log, onError, epoch) {
  let queued = [];
  let writing = null;
  const send = () => {
    const lines = queued;
    queued = [];
    writing = log.ui.write(lines).catch(onError).then(() => {
      writing = null;
      if (queued.length > 0) send();
    });
  };
  return {
    push(event) {
      queued.push(JSON.stringify(epoch === undefined ? event : { ...event, epoch }));
      if (!writing) send();
    },
    async settle() {
      while (writing) await writing;
    },
  };
}

const runOf = (input) => ({ context: input?.context ?? null, settings: input?.settings ?? null });

const errorSummary = (error) => ({ name: error?.name ?? "Error", message: String(error?.message ?? error), ...(error?.code ? { code: error.code } : {}) });
const isFenced = (error) => error?.code === "FX_FENCED";

const messageTypes = new Set(["prompt", "steer", "cancel", "resume"]);

function queuedMessage(message, store) {
  return {
    type: message.type,
    messageId: message.messageId,
    sessionId: message.sessionId,
    agent: typeof message.agent === "string" ? message.agent : defaultAgentName,
    ...(typeof store === "string" ? { store } : {}),
  };
}

function deliveredMessage(backend, delivered) {
  if (!delivered || typeof delivered !== "object" || !messageTypes.has(delivered.type)) return null;
  if (!validId(delivered.messageId) || !backend.validSessionId(delivered.sessionId)) return null;
  if (delivered.agent !== undefined && typeof delivered.agent !== "string") return null;
  return queuedMessage(delivered);
}

const knownMessage = (state, message) => state.inputKeys.has(`${message.type}:${message.messageId}`) || state.consumed.has(message.messageId);

const maxInputBytes = 8 * 1024 * 1024;
const jsonBytes = (value) => (value === undefined ? 0 : encoder.encode(JSON.stringify(value)).byteLength);
const jsonSnapshot = (value) => {
  const text = JSON.stringify(value);
  return text === undefined ? undefined : JSON.parse(text);
};
const inputTooLarge = (bytes) => Object.assign(
  new RangeError(`a durable input with its context and settings is ${bytes} bytes; the most is ${maxInputBytes}`),
  { code: "FX_INPUT_TOO_LARGE", bytes, limit: maxInputBytes },
);

function messageEntries(state, message) {
  const entries = [];
  const named = typeof message.agent === "string" ? { agent: message.agent } : {};
  if (message.seed && state.checkpoint === null && state.records.length === 0) {
    entries.push({ k: "checkpoint", through: null, data: message.seed, ...named });
  }
  const key = `${message.type}:${message.messageId}`;
  const known = state.inputKeys.has(key) || state.consumed.has(message.messageId) || idInUse(state, message);
  if (messageTypes.has(message.type) && !known) {
    entries.push({
      k: "input",
      key,
      type: message.type,
      messageId: message.messageId,
      ...named,
      ...(message.input === undefined ? {} : { input: message.input }),
      ...(typeof message.target === "string" ? { target: message.target } : {}),
      ...((message.type === "prompt" || message.type === "steer") && message.context !== undefined ? { context: message.context } : {}),
      ...((message.type === "prompt" || message.type === "steer") && message.settings !== undefined ? { settings: message.settings } : {}),
    });
  }
  return entries;
}

const joinable = (input) => typeof input === "string" || (Array.isArray(input) && input.every((block) => block?.type === "text"));

function idInUse(state, message) {
  const other = message.type === "prompt" ? "steer" : message.type === "steer" ? "prompt" : null;
  if (other === null) return false;
  return state.inputKeys.has(`${other}:${message.messageId}`) || state.consumedKind?.(message.messageId) === other;
}

const messageIdInUse = (message) => Object.assign(
  new TypeError(`messageId ${JSON.stringify(message.messageId)} already names a ${message.type === "prompt" ? "steer" : "prompt"} in this session`),
  { code: "FX_MESSAGE_ID_IN_USE" },
);

async function recordMessage(log, state, message) {
  if (idInUse(state, message)) throw messageIdInUse(message);
  const entries = messageEntries(state, message);
  for (const entry of entries) await log.append(entry);
  return entries.length;
}

/**
 * The session as a worker can start it before its claim lands: the log it
 * read, with this message's input in it, when that leaves no open turn and
 * a prompt to run. The turn's first model request then needs nothing the
 * claim writes. Null when the worker must claim first: an open turn
 * continues only from the log as its claim finds it, and a restored agent's
 * first checkpoint lands before anything reads it. `fold` folds entries the
 * way the worker does. Pure.
 */
export function earlyStart(entries, state, message, fold) {
  const writes = messageEntries(state, message);
  if (writes.some((entry) => entry.k !== "input")) return null;
  const next = writes.length === 0 ? state : fold([...entries, ...writes.map((entry) => ({ cursor: String(state.maxCursor), entry }))]);
  if (next.openTurn !== null || next.halted || next.pending.length === 0) return null;
  return { writes, state: next };
}

function gatedLog(log, ready, claimError) {
  return {
    ...log,
    async append(entry) {
      if (!(await ready)) throw claimError();
      return log.append(entry);
    },
    ui: {
      ...log.ui,
      async write(lines) {
        if (await ready) await log.ui.write(lines);
      },
    },
  };
}

const hardStopMs = 2000;

const durableInternals = Symbol.for("libfx.durableInternals");

const runningBackstopSeconds = 2;

const deliveryDeadline = (backend) => backend.deadline() ?? (backend.maxDurationMs === null ? null : Date.now() + backend.maxDurationMs);

const inlineBackstopMarginSeconds = 5;

class SessionWorker {
  constructor(agent, backend, sessionId) {
    this.agent = agent;
    this.backend = backend;
    this.sessionId = sessionId;
    this.running = false;
    this.deliveries = 0;
    this.holder = null;
  }

  fold(entries, delivery = null) {
    return foldSessionLog(entries, { now: Date.now(), alive: (lease) => this.backend.alive(lease, delivery) });
  }

  async consume(message, delivery = null) {
    const log = await this.backend.session(this.sessionId);
    let entries = await log.read();
    let state = this.fold(entries, delivery);
    if (!knownMessage(state, message)) {
      this.agent.emit("session.refused", { sessionId: this.sessionId, messageId: message.messageId, reason: "unknown message" });
      return undefined;
    }
    await this.backend.refreshDeadline?.();
    const deadline = this.backend.deadline() ?? (this.backend.maxDurationMs === null ? null : Date.now() + this.backend.maxDurationMs);
    const owner = state.agent ?? agentOf(message);
    if (owner !== this.agent.name) {
      await this.backend.queue.send(queuedMessage({ ...message, agent: owner }, this.backend.store), {
        idempotencyKey: `${message.sessionId}:${message.type}:${message.messageId}:to:${owner}`,
      });
      this.agent.emit("session.forwarded", { sessionId: this.sessionId, agent: owner });
      return undefined;
    }
    for (let claims = 0; claims < 8; claims += 1) {
      const early = this.running || state.lease ? null : earlyStart(entries, state, message, (items) => this.fold(items, delivery));
      let outcome;
      if (early) {
        outcome = await this.claim(log, state, deadline, early, delivery);
      } else {
        if (this.running) return { timeoutSeconds: runningBackstopSeconds };
        if (!state.hasWork) {
          if (message.type === "resume") await this.answerIdle(log, message);
          return undefined;
        }
        if (state.lease) {
          const left = state.lease.expiresAt ? Math.ceil((state.lease.expiresAt - Date.now()) / 1000) + 1 : 5;
          return { timeoutSeconds: Math.max(1, Math.min(maxBackstopSeconds, left)) };
        }
        outcome = await this.claim(log, state, deadline, null, delivery);
      }
      if (outcome === "yielded") return { timeoutSeconds: 0 };
      if (outcome === "failed") return queueHeld(this.backend, deadline) ? { redeliver: true } : { timeoutSeconds: 1 };
      if (outcome === "fenced") {
        this.agent.emit("session.fenced", { sessionId: this.sessionId, epoch: state.lastEpoch + 1 });
        return undefined;
      }
      entries = await log.read();
      state = this.fold(entries, delivery);
    }
    return { timeoutSeconds: 1 };
  }

  async claim(log, state, deadline, early, delivery = null) {
    this.running = true;
    this.holder = newId("wkr");
    const lease = {
      k: "lease",
      a: state.head,
      holder: this.holder,
      epoch: state.lastEpoch + 1,
      expiresAt: leaseEnd(this.backend, deadline),
      ...this.backend.holderInfo(),
      ...(delivery ? { delivery } : {}),
    };
    this.backend.holding(this.holder, true);
    try {
      const writes = [log.append(lease), ...(early?.writes ?? []).map((entry) => log.append(entry))];
      const claimed = Promise.allSettled(writes).then(async ([leased, ...rest]) => {
        const head = leased.status === "fulfilled" ? leased.value : null;
        const error = leased.status === "rejected" ? leased.reason : rest.find((item) => item.status === "rejected")?.reason ?? null;
        if (error || !early) return { head, error };
        try {
          const now = this.fold(await log.read());
          return { head, error: now.lastLease?.holder === this.holder ? null : new FencedError(`another worker continued session ${this.sessionId}`) };
        } catch (readError) {
          return { head, error: readError };
        }
      });
      let outcome;
      try {
        outcome = await this.run(log, claimed, lease, deadline, early?.state ?? null);
      } catch (error) {
        if ((await claimed).error === null) throw error;
      }
      const settled = await claimed;
      if (settled.error === null) return outcome;
      if (isFenced(settled.error)) return "refused";
      this.agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(settled.error) });
      if (settled.head !== null) await log.append({ k: "release", a: settled.head, holder: this.holder }).catch(() => {});
      return "failed";
    } finally {
      this.backend.holding(this.holder, false);
      this.running = false;
    }
  }

  async answerIdle(log, message) {
    const ui = uiWriter(log, (error) => this.agent.emit("ui.error", { sessionId: this.sessionId, error: error?.name ?? "Error" }));
    ui.push({ type: "idle", requestId: message.messageId });
    await ui.settle();
  }

  async run(raw, claimed, lease, deadline, early) {
    const agent = this.agent;
    let head = null;
    let failed = null;
    let claimFailed = false;
    let released = false;
    const ready = claimed.then((claim) => {
      head = claim.head;
      if (claim.error === null) return true;
      failed = claim.error;
      claimFailed = true;
      return false;
    });
    const log = gatedLog(raw, ready, () => failed);
    let chain = ready;
    const started = new Set();
    let cut = early?.cut ?? noCutoffs;
    const chained = (entry) => {
      if (entry.k === "record") cut = afterRecord(cut, entry.marks);
      const appended = chain.then(async () => {
        if (failed) throw failed;
        try {
          head = await log.append({ ...entry, a: head });
          for (const mark of entry.marks ?? []) if (typeof mark.start === "string") started.add(mark.start);
          return head;
        } catch (error) {
          failed = error;
          throw error;
        }
      });
      chain = appended.catch(() => {});
      return appended;
    };
    const release = async (cutoff = null) => {
      await chain;
      if (failed || released) return;
      released = true;
      await chained({ k: "release", holder: this.holder, ...(cutoff ? { cutoff } : {}) }).catch(() => {});
    };
    const broken = () => {
      if (isFenced(failed)) return "fenced";
      if (!claimFailed) agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(failed) });
      return "failed";
    };
    let state = early;
    if (!state) {
      if (!(await ready)) return broken();
      state = this.fold(await log.read());
      if (state.lastLease?.holder !== this.holder) return "fenced";
      cut = state.cut;
    }
    const ui = uiWriter(log, (error) => agent.emit("ui.error", { sessionId: this.sessionId, error: error?.name ?? "Error" }), lease.epoch);
    let leaseExpiresAt = lease.expiresAt;
    const store = {
      load: async () => ({
        ...(state.checkpoint?.data ? { checkpoint: { through: state.checkpoint.through ?? "0", data: fromBase64(state.checkpoint.data) } } : {}),
        journal: state.records.map((record) => ({ cursor: record.cursor, data: fromBase64(record.data) })),
        head: head ?? state.head,
      }),
      append: ({ idempotencyKey, data, marks }) => chained({ k: "record", key: idempotencyKey, data: toBase64(data), marks }).then((cursor) => ({ cursor })),
      saveCheckpoint: async ({ through, data }) => {
        const now = this.fold(await log.read());
        const kept = [...now.unconsumed, ...now.held].filter((input) => input.cursor <= Number(through)).sort((a, b) => a.cursor - b.cursor);
        await log.append({
          k: "checkpoint",
          through,
          data: toBase64(data),
          pending: kept,
          ...(now.heldIds.length > 0 ? { held: now.heldIds } : {}),
          recent: now.recent,
          recentSteers: now.recentSteers,
          lastTurnId: now.lastTurnId,
          ...(now.agent === null ? {} : { agent: now.agent }),
          ...(now.openTurn ? { openTurn: now.openTurn, yielded: now.yielded } : {}),
          lease: { holder: this.holder, epoch: lease.epoch, expiresAt: leaseExpiresAt, pid: lease.pid, host: lease.host, ...(lease.delivery ? { delivery: lease.delivery } : {}) },
        });
      },
    };
    let turnNow = null;
    let renew = null;
    if (!heldToDeadline(this.backend, deadline)) {
      renew = setInterval(() => {
        if (released || failed || this.stopping) return;
        leaseExpiresAt = leaseEnd(this.backend, deadline);
        void chained({ k: "lease", holder: this.holder, epoch: lease.epoch, expiresAt: leaseExpiresAt, ...this.backend.holderInfo(), ...(lease.delivery ? { delivery: lease.delivery } : {}) })
          .catch((error) => { if (isFenced(error)) turnNow?.cancel({ reason: "handoff" }); });
      }, Math.max(1, Math.floor(this.backend.leaseMs / 3)));
    }
    const stopMargin = deadline === null ? 0 : Math.min(hardStopMs, Math.floor(this.backend.reserveMs / 2));
    this.stopping = false;
    this.stopNow = () => {
      if (this.stopping) return;
      this.stopping = true;
      agent.emit("session.deadline", { sessionId: this.sessionId, epoch: lease.epoch, cutoffs: afterCutoff(cut).cutoffs });
      turnNow?.cancel({ reason: "handoff" });
    };
    void ready.then((landed) => { if (!landed) turnNow?.cancel({ reason: "handoff" }); });
    const hardStop = stopMargin > 0 && deadline - stopMargin > Date.now()
      ? setTimeout(this.stopNow, deadline - stopMargin - Date.now())
      : null;
    let harness = null;
    let harnessRun = runOf(null);
    this.settled = () => (harness ? harness.settled() : Promise.resolve());
    const unusable = (error) => {
      agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(error) });
      return "failed";
    };
    try {
      if (state.halted) {
        const id = state.openTurn.id;
        if (!state.failed.has(id)) {
          const error = { name: "Error", message: "the engine stopped each time it continued this turn, even to cancel it" };
          await log.append({ k: "failed", messageId: id, error });
          ui.push({ type: "turn_end", messageId: id, stopReason: "error", usage: {}, error });
        }
        for (const waiting of state.pending) {
          await log.append({ k: "ended", messageId: waiting.messageId });
          ui.push({ type: "turn_end", messageId: waiting.messageId, stopReason: "error", usage: {}, error: { name: "Error", message: "the session's open turn cannot continue" } });
        }
        await ui.settle();
        return "done";
      }
      try {
        harnessRun = runOf(state.openTurn ?? state.pending[0]);
        harness = await agent.openHarness(this.sessionId, store, harnessRun, ready);
      } catch (error) {
        const waiting = state.openTurn && !state.openFailed ? state.openTurn.id : state.pending[0]?.messageId;
        if (waiting) {
          const summary = errorSummary(error);
          await log.append({ k: "failed", messageId: waiting, error: summary });
          ui.push({ type: "turn_end", messageId: waiting, stopReason: "error", usage: {}, error: summary });
        }
        agent.emit("session.error", { sessionId: this.sessionId, error: errorSummary(error) });
        return "done";
      }
      const yieldAt = deadline === null ? undefined : Math.max(1, deadline - this.backend.reserveMs);
      for (;;) {
        if (failed) return broken();
        if (this.stopping) {
          await harness.close();
          harness = null;
          await release();
          return failed ? broken() : "yielded";
        }
        const open = harness.openTurn;
        let turn = null;
        let messageId = null;
        let fresh = false;
        let spent = false;
        if (open?.id) {
          messageId = open.id;
          ui.push({ type: "turn_resume", messageId, sessionId: this.sessionId });
          await ui.settle();
          spent = state.openTurn?.id === messageId && state.cutoffs >= maxCutoffs;
          try {
            turn = harness.resume({ yieldAt, ...(spent ? { rerun: false } : {}) });
          } catch (error) {
            await log.append({ k: "stopped", messageId });
            return unusable(error);
          }
        }
        if (!turn) {
          const next = state.pending[0];
          if (!next) break;
          messageId = next.messageId;
          if ((state.stops.get(messageId) ?? 0) >= maxHarnessStops) {
            await log.append({ k: "ended", messageId });
            ui.push({ type: "turn_end", messageId, stopReason: "error", usage: {}, error: { name: "Error", message: `the engine stopped each of the ${maxHarnessStops} times it started this turn` } });
            await ui.settle();
            state = this.fold(await log.read());
            continue;
          }
          if (next.cancelled) {
            await log.append({ k: "ended", messageId });
            ui.push({ type: "turn_end", messageId, stopReason: "cancelled", usage: {} });
            await ui.settle();
            state = this.fold(await log.read());
            continue;
          }
          const wanted = runOf(next);
          if (JSON.stringify(wanted) !== JSON.stringify(harnessRun)) {
            await harness.close();
            harness = null;
            harness = await agent.openHarness(this.sessionId, store, wanted, ready);
            harnessRun = wanted;
          }
          try {
            turn = harness.prompt(next.input ?? "", { turnId: messageId, yieldAt });
          } catch (error) {
            await log.append({ k: "stopped", messageId });
            return unusable(error);
          }
          ui.push({ type: "turn_start", messageId, sessionId: this.sessionId, ...(typeof next.input === "string" ? { input: next.input } : {}) });
          fresh = true;
        }
        turnNow = turn;
        if (this.stopping || claimFailed) turn.cancel({ reason: "handoff" });
        else if (spent && !(open.calls?.length > 0)) turn.cancel();
        const joining = fresh ? { ...state, steers: state.pending[0]?.joiners ?? [], endOpen: state.pending[0]?.ends === true } : state;
        const outcome = await this.drive(log, harness, turn, messageId, joining, ui);
        turnNow = null;
        if (outcome === "fenced") return "fenced";
        if (outcome === "yielded") {
          await harness.saveCheckpoint();
          await harness.close();
          harness = null;
          await release(this.stopping ? messageId : null);
          return failed ? broken() : "yielded";
        }
        if (outcome.stopped) {
          await harness.close().catch(() => {});
          harness = null;
          await chain;
          if (failed) return broken();
          state = this.fold(await log.read());
          if (state.openTurn?.id !== messageId && state.consumed.has(messageId)) {
            ui.push({ type: "turn_end", messageId, stopReason: "unknown", usage: {} });
            await ui.settle();
          } else {
            await log.append({ k: "stopped", messageId });
          }
          return unusable(outcome.stopped);
        }
        const { result } = outcome;
        if (fresh && !failed && !started.has(messageId)) {
          state = this.fold(await log.read());
          if (!state.consumed.has(messageId)) await log.append({ k: "ended", messageId });
        }
        ui.push({ type: "turn_end", messageId, stopReason: result.stopReason, usage: result.usage ?? {}, ...(result.error ? { error: result.error } : {}) });
        await ui.settle();
        state = this.fold(await log.read());
        if (!fresh && !failed && harness.openTurn?.id === messageId) {
          agent.emit("session.error", { sessionId: this.sessionId, error: { name: "Error", message: `turn ${messageId} ended but stayed open` } });
          break;
        }
        if (state.lastLease?.holder !== this.holder && !failed) return "fenced";
      }
      if (failed) {
        await harness.close();
        harness = null;
        return broken();
      }
      await release();
      agent.track(harness.close().catch(() => {}));
      harness = null;
      return failed ? broken() : "done";
    } finally {
      if (hardStop) clearTimeout(hardStop);
      this.stopNow = null;
      this.settled = null;
      if (renew) clearInterval(renew);
      if (harness) await harness.close().catch(() => {});
      await ui.settle().catch(() => {});
      if (!failed && !released) await release().catch(() => {});
      else if (failed && !isFenced(failed) && !released) {
        released = true;
        await log.append({ k: "release", a: head, holder: this.holder }).catch(() => {});
      }
    }
  }

  async drive(log, harness, turn, messageId, state, ui) {
    const applied = new Set(state.inputKeys);
    let since = String(state.maxCursor);
    let polling = false;
    let again = false;
    let stopped = false;
    let ending = false;
    const endTurn = () => {
      if (ending) return;
      ending = true;
      void Promise.resolve().then(() => turn.endForSteer?.()).catch(() => {});
    };
    const steerTurn = (steer) => {
      if (steer.messageId === messageId) return;
      if (!joinable(steer.input)) endTurn();
      else if (!ending) void turn.steer(steer.input, steer.messageId).catch(() => {});
    };
    const apply = async () => {
      if (stopped) return;
      if (polling) { again = true; return; }
      polling = true;
      try {
        do {
          again = false;
          const entries = await log.readSince(since);
          for (const { cursor, entry } of entries) {
            if (Number(cursor) > Number(since)) since = cursor;
            if (entry?.k !== "input" || applied.has(entry.key)) continue;
            applied.add(entry.key);
            if (entry.type === "steer") steerTurn(entry);
            else if (entry.type === "cancel" && (entry.target === undefined || entry.target === messageId)) turn.cancel();
          }
        } while (again && !stopped);
      } catch {} finally {
        polling = false;
      }
    };
    for (const steer of state.steers) {
      applied.add(steer.key);
      steerTurn(steer);
    }
    if (state.endOpen) endTurn();
    if (state.cancelOpen || (state.stuck && state.openTurn?.id === messageId)) turn.cancel();
    const unwatch = log.watch?.(() => { void apply(); });
    const timer = this.backend.pollMs ? setInterval(() => { void apply(); }, this.backend.pollMs) : null;
    void apply();
    let result;
    try {
      for await (const event of turn) ui.push({ ...event, messageId });
      result = await turn.result;
    } catch (error) {
      if (isFenced(error)) return "fenced";
      if (error?.code === "FX_HARNESS_STOPPED") return { stopped: error };
      result = { stopReason: "error", error: errorSummary(error) };
    } finally {
      stopped = true;
      unwatch?.();
      if (timer) clearInterval(timer);
    }
    try {
      await harness.settled();
    } catch (error) {
      if (isFenced(error)) return "fenced";
      throw error;
    }
    if (result.stopReason === "yielded" || (this.stopping && result.stopReason === "cancelled")) {
      ui.push({ type: "turn_yield", messageId });
      await ui.settle();
      return "yielded";
    }
    return { result };
  }
}

const internalEvent = new Set(["turn_start", "turn_resume", "turn_yield", "turn_end", "idle"]);

function uiRanker(high = 0) {
  return (event) => {
    if (!Number.isSafeInteger(event?.epoch)) return true;
    if (event.epoch < high) return false;
    high = event.epoch;
    return true;
  };
}

async function uiRankerAt(log, count) {
  const shows = uiRanker();
  if (count === 0) return shows;
  const reader = log.ui.read(0).getReader();
  let buffered = "";
  let seen = 0;
  try {
    while (seen < count) {
      const { value, done } = await reader.read();
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0 && seen < count; index = buffered.indexOf("\n")) {
        const line = buffered.slice(0, index);
        buffered = buffered.slice(index + 1);
        seen += 1;
        try { shows(JSON.parse(line)); } catch {}
      }
    }
  } finally {
    void reader.cancel().catch(() => {});
  }
  return shows;
}

async function retryOutcome(log, state, messageId, from, { sent }) {
  const waiting = state.inputKeys.has(`prompt:${messageId}`) && !state.consumed.has(messageId);
  if ((state.openTurn?.id === messageId && !state.failed.has(messageId)) || waiting) return { follow: true };
  if (!state.consumed.has(messageId)) return { fresh: true };
  const ended = await turnEndIn(log, messageId, from);
  if (ended) return { settled: { ...ended, repeated: true } };
  const error = state.failed.get(messageId);
  if (error) return { settled: { messageId, stopReason: "error", error, ...(sent ? {} : { repeated: true }) } };
  return { unsure: true };
}

async function turnEndIn(log, messageId, count) {
  if (count === 0) return null;
  const shows = uiRanker();
  const reader = log.ui.read(0).getReader();
  let buffered = "";
  let seen = 0;
  let found = null;
  try {
    while (seen < count) {
      const { value, done } = await reader.read();
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      for (let index = buffered.indexOf("\n"); index >= 0 && seen < count; index = buffered.indexOf("\n")) {
        const line = buffered.slice(0, index);
        buffered = buffered.slice(index + 1);
        seen += 1;
        let event;
        try { event = JSON.parse(line); } catch { continue; }
        if (shows(event) && event.type === "turn_end" && event.messageId === messageId) found = event;
      }
    }
  } finally {
    void reader.cancel().catch(() => {});
  }
  if (!found) return null;
  const { type: _type, ...rest } = found;
  return rest;
}

const retryEndWaitMs = 30_000;

function turnView({ messageId, resumeRequest = null, start }) {
  let repeated = false;
  const events = [];
  const waiters = [];
  let done = false;
  let failure = null;
  let id = resumeRequest ? null : messageId;
  let settle;
  const result = new Promise((resolve, reject) => { settle = { resolve, reject }; });
  void result.catch(() => {});
  const wake = () => { for (const waiter of waiters.splice(0)) waiter(); };
  const finish = (value, error) => {
    if (done) return;
    done = true;
    if (error) {
      failure = error;
      settle.reject(error);
    } else settle.resolve(repeated ? { ...value, repeated: true } : value);
    wake();
  };
  const started = start();
  void started.catch(() => {});
  let following = false;
  const follow = () => {
    if (following) return;
    following = true;
    void read();
  };
  const read = async () => {
    try {
      const { log, from, settled, attaching, endWithinMs, unsure } = await started;
      repeated = settled?.repeated === true || (endWithinMs !== undefined && !unsure);
      if (settled) {
        const { messageId: _id, ...rest } = settled;
        events.push({ type: "turn_end", messageId, ...rest });
        return finish(settled);
      }
      const shows = attaching ? await uiRankerAt(log, from) : uiRanker();
      const reader = log.ui.read(from).getReader();
      let gaveUp = null;
      if (endWithinMs !== undefined) {
        gaveUp = setTimeout(() => {
          void reader.cancel().catch(() => {});
          finish({ messageId, stopReason: "unknown", usage: {} });
        }, endWithinMs);
      }
      let buffered = "";
      let cursor = from;
      for (;;) {
        const { value, done: ended } = await reader.read();
        if (ended) break;
        buffered += decoder.decode(value, { stream: true });
        for (let index = buffered.indexOf("\n"); index >= 0; index = buffered.indexOf("\n")) {
          const line = buffered.slice(0, index);
          buffered = buffered.slice(index + 1);
          cursor += 1;
          let event;
          try { event = JSON.parse(line); } catch { continue; }
          if (!shows(event)) continue;
          if (id === null) {
            if (event.type === "idle" && event.requestId === resumeRequest) {
              void reader.cancel().catch(() => {});
              return finish({ stopReason: "idle", usage: {} });
            }
            if (event.type !== "turn_resume" && event.type !== "turn_start") continue;
            id = event.messageId;
          }
          if (event.messageId !== id) continue;
          events.push({ ...event, cursor });
          wake();
          if (event.type === "turn_end") {
            if (gaveUp) clearTimeout(gaveUp);
            void reader.cancel().catch(() => {});
            const { type: _type, messageId: _id, ...rest } = event;
            return finish({ messageId: id, ...rest });
          }
        }
      }
      if (gaveUp) clearTimeout(gaveUp);
      finish(null, new Error("the session stream ended before the turn did"));
    } catch (error) {
      finish(null, error);
    }
  };
  async function* iterate(raw) {
    for (let index = 0; ; index += 1) {
      while (index >= events.length) {
        if (done) {
          if (failure) throw failure;
          return;
        }
        await new Promise((resolve) => waiters.push(resolve));
      }
      const event = events[index];
      if (raw) yield event;
      else if (!internalEvent.has(event.type)) {
        const { messageId: _id, cursor: _cursor, ...rest } = event;
        yield rest;
      }
    }
  }
  return {
    get messageId() { return id; },
    get result() {
      follow();
      return result;
    },
    [Symbol.asyncIterator]() {
      follow();
      return iterate(false);
    },
    get readable() {
      follow();
      const iterator = iterate(true);
      return new ReadableStream({
        async pull(controller) {
          try {
            const { value, done: ended } = await iterator.next();
            if (ended) controller.close();
            else controller.enqueue(encoder.encode(`${JSON.stringify(value)}\n`));
          } catch (error) {
            controller.error(error);
          }
        },
        cancel() { void iterator.return?.(); },
      });
    },
  };
}

/**
 * Builds a durable agent over a harness: the agent loop that runs a turn.
 * The core owns the session's log, its lease, the queue, deadlines and the
 * UI stream; the harness owns turns and what its records mean.
 *
 * `harness(options)` receives the caller's options without `durability` and
 * returns:
 *
 * - `open({ sessionId, store, context, settings, durability, ready })`: the
 *   harness session for one worker, for turns with that `context` and those
 *   `settings`. `store` is where it keeps the session: `load()` resolves
 *   `{ checkpoint?, journal, head }`, `append({ idempotencyKey, data, marks })`
 *   stores one opaque record durably and resolves `{ cursor }`, and
 *   `saveCheckpoint({ through, data })` stores what the records through
 *   `through` add up to. Each record's `marks` tell the core where turns
 *   start (`{ start: turnId }`), yield (`{ yield: true }`) and end
 *   (`{ end: true }`), which inputs a turn took (`{ accepted: id }`), when
 *   its model request first carries one (`{ placed: id }`), and which it
 *   ended without placing (`{ withdrawn: id }`), which wait for a turn again.
 *   A write another worker's write fenced out rejects with a `FX_FENCED`
 *   code. `ready`, when given, resolves true once the worker's claim on the
 *   session lands and false when it failed: the core may start a turn
 *   before then, and the harness runs no tool until it resolves true. The
 *   core holds the store's writes and the turn's UI lines meanwhile.
 * - `seed` (optional): the bytes of a checkpoint a new session starts from.
 * - `settings(sessionOptions)` (optional): what an `agent.session()` call
 *   sets over the agent's options for the turns it starts, as JSON the core
 *   stores with each prompt and passes to `open()`, or undefined for none.
 *   It throws a TypeError for options it refuses.
 *
 * A harness session has `prompt(input, { turnId, yieldAt })` and
 * `resume({ yieldAt, rerun })`, each returning a turn, where `rerun: false`
 * runs no call left running again; `openTurn`, the turn its records left
 * open as `{ id, calls? }`, with the calls it left running, or null;
 * `settled()`, which resolves once
 * every record it started is stored; `saveCheckpoint()`;
 * `exportCheckpoint()`, the conversation as bytes; and `close()`. A turn is
 * an async iterable of the events its viewers see, with `result` resolving
 * `{ stopReason, usage? }`, `steer(text, id)`, and `cancel(options)`, where
 * `{ reason: "handoff" }` stops it at once and stores nothing more, so the
 * next worker continues it. A turn may have `endForSteer()`, which ends it
 * at its next safe point, at once while its model streams a reply, for a
 * steer that cannot join it; without it, such a steer waits for the turn to
 * end. Either way the steer runs as the next turn. A turn stops before a
 * model request once `yieldAt` has passed, with the stop reason `yielded`.
 *
 * An input the harness refuses is a turn that ends with an error.
 * `prompt()` and `resume()` throw only when the harness cannot run a turn,
 * and a turn whose harness stopped under it rejects with a
 * `FX_HARNESS_STOPPED` code; either way the same message runs the session
 * again with a new harness. After 3 stops a turn is resumed and cancelled at
 * once, or ends with an error when it never started; when its harness stops
 * twice more, even to cancel it, the session runs no more turns.
 *
 * `defaultDurability()` picks the durability when the caller names none, and
 * `defaultShared` says it hands every such agent the same one, as Node's
 * does, so that agents created without a durability share a store. `name` is
 * the factory's name in errors, and `label` the agent's.
 */
export function createDurableAgentFactory({ harness, defaultDurability, defaultShared = false, name = "createAgent", label = "agent" }) {
  return function createDurableAgent(options = {}) {
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError(`${name}() options must be an object`);
    }
    const { durability, name: agentName = defaultAgentName, ...harnessOptions } = options;
    if (durability !== undefined && !isDurability(durability)) {
      throw new TypeError("durability must come from memory(), local(), vercel() or world()");
    }
    if (typeof agentName !== "string" || !agentNameRule.test(agentName)) {
      throw new TypeError(`${name}() name must be 1 to 64 letters, digits, ".", "_" or "-", starting with a letter or digit`);
    }
    const plugged = harness(harnessOptions);
    const seed = plugged.seed === undefined ? undefined : toBase64(plugged.seed);
    const emit = (type, detail = {}) => {
      try { options.onEvent?.({ type, timestamp: performance.now(), ...detail }); } catch {}
    };
    const agent = {
      name: agentName,
      emit,
      track(work) {
        active.add(work);
        void work.finally(() => active.delete(work));
      },
      openHarness: (sessionId, store, run, ready) => plugged.open({
        sessionId,
        store,
        context: run?.context ?? null,
        ...(run?.settings == null ? {} : { settings: run.settings }),
        durability: chosenDurability,
        ...(ready ? { ready } : {}),
      }),
    };
    let backendPromise = null;
    let durabilityPromise = null;
    let chosenDurability = null;
    let unlisten = null;
    let closed = false;
    const workers = new Map();
    const active = new Set();
    const backend = () => {
      if (closed) return Promise.reject(new Error(`${label} is closed`));
      backendPromise ??= (async () => {
        const chosen = await durabilityOf();
        if (member.store !== storeOf(chosen)) {
          member.store = storeOf(chosen);
          try {
            claimName(agentName, member);
          } catch (error) {
            leaveGroup(agentsByName, agentName, registered, member);
            throw error;
          }
        }
        chosenDurability = chosen;
        const created = await createBackend(chosen);
        await created.start?.();
        unlisten = created.listen((delivered, meta) => {
          const message = deliveredMessage(created, delivered);
          if (!message) {
            emit("session.refused", { reason: "malformed message" });
            return undefined;
          }
          return receive(created, message, deliveryOf(meta));
        }, agentName);
        return created;
      })();
      return backendPromise;
    };
    const durabilityOf = () => (durabilityPromise ??= durability ? Promise.resolve(durability) : defaultDurability());
    const unresolved = defaultShared ? defaultDurability : Symbol("default store");
    const member = { open: backend, durability: durabilityOf, definition: definitionOf(harnessOptions), store: durability ? storeOf(durability) : unresolved, defaults: durability ? null : unresolved };
    claimName(agentName, member);
    const registered = joinGroup(agentsByName, agentName, member);
    const receive = (created, message, delivery, { inRequest = false } = {}) => {
      let worker = workers.get(message.sessionId);
      if (!worker) {
        worker = new SessionWorker(agent, created, message.sessionId);
        workers.set(message.sessionId, worker);
      }
      worker.deliveries += 1;
      let work = worker.consume(message, delivery);
      if (inRequest) {
        work = work.then(async (result) => {
          if (Number.isFinite(result?.timeoutSeconds)) {
            await created.queue.send(message, {
              idempotencyKey: `${message.sessionId}:${message.type}:${message.messageId}:${newId("again")}`,
              ...(result.timeoutSeconds > 0 ? { delaySeconds: result.timeoutSeconds } : {}),
            });
          }
          return result;
        });
      }
      active.add(work);
      void work.catch((error) => {
        emit("session.error", { sessionId: message.sessionId, error: errorSummary(error) });
      }).finally(() => {
        active.delete(work);
        worker.deliveries -= 1;
        if (worker.deliveries === 0 && !worker.running && workers.get(message.sessionId) === worker) workers.delete(message.sessionId);
      });
      return work;
    };

    const openSession = (requestedId, sessionOptions = {}) => {
      if (requestedId !== undefined && !validId(requestedId)) throw new TypeError(`session id must be ${idRule}`);
      let context;
      try { context = jsonSnapshot(sessionOptions?.context); } catch { throw new TypeError("session context must be JSON"); }
      const settings = jsonSnapshot(plugged.settings?.(sessionOptions ?? {}));
      const carried = jsonBytes(context) + jsonBytes(settings);
      const admit = (input) => {
        const bytes = jsonBytes(input) + carried;
        if (bytes > maxInputBytes) throw inputTooLarge(bytes);
      };
      let id = requestedId ?? null;
      let seeded = seed === undefined || requestedId !== undefined;
      const resolved = backend().then((created) => {
        id ??= created.newSessionId();
        if (!created.validSessionId(id)) throw new TypeError(`${created.name} durability cannot hold session id ${JSON.stringify(id)}`);
        return { created, id };
      });
      void resolved.catch(() => {});
      const send = async (message, { inRequest = false } = {}) => {
        const { created, id: sessionId } = await resolved;
        const extra = {
          ...(seeded ? {} : { seed }),
          ...(context === undefined ? {} : { context }),
          ...(settings === undefined ? {} : { settings }),
        };
        const full = { ...message, ...extra, agent: agentName, sessionId };
        const log = await created.session(sessionId);
        await recordMessage(log, foldSessionLog(await log.read()), full);
        const queued = queuedMessage(full, created.store);
        const idempotencyKey = `${sessionId}:${message.type}:${message.messageId}`;
        if (inRequest && created.runInRequest) {
          await created.refreshDeadline?.();
          const deadline = deliveryDeadline(created);
          if (deadline !== null) {
            const delaySeconds = Math.ceil(Math.max(0, deadline - Date.now()) / 1000) + inlineBackstopMarginSeconds;
            const { messageId: backstop } = await created.queue.send(queued, { idempotencyKey, delaySeconds }) ?? {};
            seeded = true;
            const delivery = backstop ? { messageId: backstop, attempt: 0 } : null;
            const work = receive(created, queued, delivery, { inRequest: true }).then(() => {}, () => {});
            created.waitUntil?.(work);
            return;
          }
        }
        await created.queue.send(queued, { idempotencyKey });
        seeded = true;
      };
      const startTurn = (type, messageId, input, retried = false, aborted = false) => {
        let accept;
        const accepted = new Promise((resolve, reject) => { accept = { resolve, reject }; });
        void accepted.catch(() => {});
        const view = turnView({
          messageId,
          resumeRequest: type === "resume" ? messageId : null,
          start: async () => {
            try {
              const { created, id: sessionId } = await resolved;
              const log = await created.session(sessionId);
              let attaching = type === "resume";
              let from = null;
              if (retried && !aborted) {
                from = await log.ui.length();
                const [state] = await Promise.all([
                  log.read().then(foldSessionLog),
                  send({ type, messageId, ...(input === undefined ? {} : { input }) }, { inRequest: type === "prompt" }).then(() => accept.resolve({ messageId, sessionId })),
                ]);
                const outcome = await retryOutcome(log, state, messageId, from, { sent: true });
                if (outcome.settled) return { settled: outcome.settled };
                if (outcome.unsure) return { log, from, attaching: true, endWithinMs: retryEndWaitMs, unsure: true };
                return { log, from, attaching: outcome.follow === true };
              }
              if (retried) {
                from = await log.ui.length();
                const outcome = await retryOutcome(log, foldSessionLog(await log.read()), messageId, from, { sent: false });
                if (outcome.follow) attaching = true;
                else if (!outcome.fresh) {
                  accept.resolve({ messageId, sessionId });
                  if (outcome.settled) return { settled: outcome.settled };
                  return { log, from, attaching: true, endWithinMs: retryEndWaitMs };
                }
              }
              if (aborted && !attaching) {
                accept.resolve({ messageId, sessionId });
                return { settled: { messageId, stopReason: "cancelled", usage: {} } };
              }
              from ??= await log.ui.length();
              await send({ type, messageId, ...(input === undefined ? {} : { input }) }, { inRequest: type === "prompt" });
              accept.resolve({ messageId, sessionId });
              return { log, from, attaching };
            } catch (error) {
              accept.reject(error);
              throw error;
            }
          },
        });
        return Object.assign(view, { accepted });
      };
      const session = {
        get id() { return id; },
        /**
         * Queues `input` as the session's next turn and returns a view of it.
         * With `messageId`, a retried call is the same turn: it continues a
         * turn still running and answers one that ended, without running it
         * again.
         */
        prompt(input, promptOptions = {}) {
          if (closed) throw new Error(`${label} is closed`);
          const messageId = promptOptions.messageId ?? newId("msg");
          if (!validId(messageId)) throw new TypeError(`messageId must be ${idRule}`);
          if (typeof input !== "string" && !Array.isArray(input)) throw new TypeError("prompt input must be a string or an array of content blocks");
          if (Array.isArray(input) && input.some((block) => block?.type === "image" && block.data !== undefined && typeof block.data !== "string")) {
            throw new TypeError("a durable prompt carries image data as a base64 string");
          }
          admit(input);
          const signal = promptOptions.signal;
          if (signal !== undefined && typeof signal?.addEventListener !== "function") throw new TypeError("prompt signal must be an AbortSignal");
          const turn = startTurn("prompt", messageId, input, promptOptions.messageId !== undefined, signal?.aborted === true);
          if (signal !== undefined && !signal.aborted) {
            const stop = () => { void send({ type: "cancel", messageId: newId("cnl"), target: messageId }).catch(() => {}); };
            signal.addEventListener("abort", stop, { once: true });
            void turn.result.finally(() => signal.removeEventListener("abort", stop)).catch(() => {});
          }
          return turn;
        },
        /** Continues the turn a stopped worker left open, if any. */
        resume() {
          if (closed) throw new Error(`${label} is closed`);
          return startTurn("resume", newId("res"));
        },
        /**
         * The session's events after `cursor`, as NDJSON, from any server.
         * A cursor is one a line carried, and a line shows only when no line
         * before it outranks it, so the epoch of the line a cursor names is
         * the rank every line after it is held to: the read starts there, not
         * at the stream's start, and lines rank the same however a reader
         * reconnects. After a line with no epoch it reads from the start.
         */
        stream(cursor = 0) {
          if (!Number.isSafeInteger(cursor) || cursor < 0) throw new TypeError("stream cursor must be a non-negative integer");
          let reader = null;
          let buffered = "";
          let next = 0;
          let shows = uiRanker();
          const open = async (ui) => {
            if (cursor === 0) return ui.read(0).getReader();
            const at = ui.read(cursor - 1).getReader();
            let first = "";
            for (;;) {
              const index = first.indexOf("\n");
              if (index >= 0) {
                let epoch = null;
                try { epoch = JSON.parse(first.slice(0, index))?.epoch; } catch {}
                if (!Number.isSafeInteger(epoch)) break;
                shows = uiRanker(epoch);
                buffered = first.slice(index + 1);
                next = cursor;
                return at;
              }
              const { value, done } = await at.read();
              if (done) return at;
              first += decoder.decode(value, { stream: true });
            }
            void at.cancel().catch(() => {});
            return ui.read(0).getReader();
          };
          return new ReadableStream({
            async pull(controller) {
              if (!reader) {
                const { created, id: sessionId } = await resolved;
                reader = await open((await created.session(sessionId)).ui);
              }
              for (;;) {
                const index = buffered.indexOf("\n");
                if (index >= 0) {
                  const line = buffered.slice(0, index);
                  buffered = buffered.slice(index + 1);
                  next += 1;
                  let event;
                  try { event = JSON.parse(line); } catch { continue; }
                  if (!shows(event) || next <= cursor) continue;
                  controller.enqueue(encoder.encode(`${JSON.stringify({ ...event, cursor: next })}\n`));
                  return;
                }
                const { value, done } = await reader.read();
                if (done) {
                  controller.close();
                  return;
                }
                buffered += decoder.decode(value, { stream: true });
              }
            },
            cancel() { void reader?.cancel().catch(() => {}); },
          });
        },
        /**
         * Guidance for the running turn, or the next turn when none runs: it
         * cuts a streaming reply short, waits for a running tool, and joins a
         * turn waiting to start. A steer with images or resources cannot
         * join a turn: the running one ends at its next safe point and the
         * steer runs next. With `messageId`, a retried call adds nothing;
         * one id names one input of the session, prompt or steer: reusing a
         * prompt's id throws `FX_MESSAGE_ID_IN_USE`, or, where the queue
         * outlives the process and the sender reads no log, the worker drops
         * the steer and emits a `session.error` with that code. Resolves once
         * the steer is stored, with its id, which the stream's events for it
         * carry.
         */
        async steer(input, steerOptions = {}) {
          if (typeof input === "string" ? input.length === 0 : !Array.isArray(input) || input.length === 0) {
            throw new TypeError("steer input must be a non-empty string or array of content blocks");
          }
          if (Array.isArray(input) && input.some((block) => block?.type === "image" && block.data !== undefined && typeof block.data !== "string")) {
            throw new TypeError("a durable steer carries image data as a base64 string");
          }
          if (steerOptions === null || typeof steerOptions !== "object") throw new TypeError("steer options must be an object");
          const messageId = steerOptions.messageId ?? newId("str");
          if (!validId(messageId)) throw new TypeError(`messageId must be ${idRule}`);
          admit(input);
          await send({ type: "steer", messageId, input });
          return { messageId };
        },
        /** Cancels the running turn; dropping a turn's view does not. */
        async cancel() {
          await send({ type: "cancel", messageId: newId("cnl") });
        },
        /** The session's state as opaque bytes, read without changing it. */
        async checkpoint() {
          const { created, id: sessionId } = await resolved;
          const log = await created.session(sessionId);
          const state = foldSessionLog(await log.read());
          const readOnly = {
            load: async () => ({
              ...(state.checkpoint?.data ? { checkpoint: { through: state.checkpoint.through ?? "0", data: fromBase64(state.checkpoint.data) } } : {}),
              journal: state.records.map((record) => ({ cursor: record.cursor, data: fromBase64(record.data) })),
              head: state.head,
            }),
            append: async () => { throw new Error("a checkpoint reads the session without changing it"); },
          };
          const harness = await agent.openHarness(sessionId, readOnly, null);
          try {
            return await harness.exportCheckpoint();
          } finally {
            await harness.close().catch(() => {});
          }
        },
      };
      return session;
    };

    let defaultSession = null;
    const durableAgent = {
      [durableInternals]: {
        stopAtDeadline: (sessionId) => workers.get(sessionId)?.stopNow?.(),
        settled: async (sessionId) => { await workers.get(sessionId)?.settled?.(); },
        deliver: async (delivered, delivery) => {
          const created = await backend();
          const message = deliveredMessage(created, delivered);
          return message ? receive(created, message, delivery) : undefined;
        },
        liveWorkers: () => workers.size,
        openLog: async (sessionId) => (await backend()).session(sessionId),
        lastLease: async (sessionId) => {
          const log = await (await backend()).session(sessionId);
          return foldSessionLog(await log.read()).lastLease;
        },
        leaseStands: async (sessionId) => {
          const held = await backend();
          const log = await held.session(sessionId);
          return foldSessionLog(await log.read(), { now: Date.now(), alive: (lease) => held.alive(lease) }).lease !== null;
        },
      },
      /** Opens session `id`, or a new one; no I/O until it is used. */
      session(id, sessionOptions) {
        if (closed) throw new Error(`${label} is closed`);
        return openSession(id, sessionOptions);
      },
      /** An id for a new session, before its first prompt. */
      async newSessionId() {
        return (await backend()).newSessionId();
      },
      /** The agent's name: its sessions' turns run only on agents with this name. */
      get name() {
        return agentName;
      },
      /** The agent's own session, for code that holds one conversation. */
      get sessionId() {
        return defaultSession?.id ?? null;
      },
      prompt(input, promptOptions) {
        defaultSession ??= openSession(undefined);
        return defaultSession.prompt(input, promptOptions);
      },
      checkpoint() {
        defaultSession ??= openSession(undefined);
        return defaultSession.checkpoint();
      },
      /**
       * The request handler a deployment mounts for queue deliveries, until
       * its World can deliver to this process itself.
       */
      wakeHandler() {
        return async (request) => {
          const created = await backend();
          if (typeof created.queueHandler !== "function") return new Response("this durability delivers in process", { status: 404 });
          return created.queueHandler(request);
        };
      },
      /** Waits for the work this process is running, then lets go. */
      async close() {
        if (closed) return;
        closed = true;
        leaveGroup(agentsByName, agentName, registered, member);
        while (active.size > 0) await Promise.allSettled([...active]);
        if (backendPromise) {
          const created = await backendPromise.catch(() => null);
          unlisten?.();
          await created?.close?.();
        }
      },
    };
    return durableAgent;
  };
}
