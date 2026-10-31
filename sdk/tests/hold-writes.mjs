const decoder = new TextDecoder();

export function holdWrites(durability, held, { landFirst = false, unreported = false } = {}) {
  const waiting = [];
  const arrivals = [];
  let open = false;
  const released = new Set();
  const pause = async (entry) => {
    if (open || !held(entry)) return () => {};
    const key = JSON.stringify(entry);
    if (released.has(key)) return () => {};
    let done;
    const finished = new Promise((resolve) => { done = resolve; });
    await new Promise((go) => {
      waiting.push({ entry, go: () => { released.add(key); go(); }, finished });
      arrivals.shift()?.();
    });
    return done;
  };
  const after = async (entry, write) => {
    if (landFirst) {
      const landed = await write();
      (await pause(entry))();
      return landed;
    }
    const done = await pause(entry);
    try {
      return await write();
    } catch (error) {
      if (unreported && error?.code === "FX_FENCED" && held(entry)) return entry.a;
      throw error;
    } finally {
      done();
    }
  };
  const writes = {
    get held() { return waiting.map((item) => item.entry); },
    next() {
      if (waiting.length > 0) return Promise.resolve();
      return new Promise((arrived) => arrivals.push(arrived));
    },
    releaseHeld() {
      const items = waiting.splice(0);
      for (const item of items) item.go();
      return Promise.all(items.map((item) => item.finished));
    },
    release() {
      open = true;
      return writes.releaseHeld();
    },
  };
  if (typeof durability.create === "function") {
    const create = durability.create;
    const wrapped = new WeakMap();
    return [{
      ...durability,
      create() {
        const backend = create();
        if (!wrapped.has(backend)) {
          wrapped.set(backend, {
            ...backend,
            async session(id) {
              const log = await backend.session(id);
              return { ...log, append: (entry) => after(entry, () => log.append(entry)) };
            },
          });
        }
        return wrapped.get(backend);
      },
    }, writes];
  }
  const entryOf = (event) => {
    if (event?.eventType !== "step_created" || event.eventData?.stepName !== "fx.log") return null;
    try { return JSON.parse(decoder.decode(event.eventData.input)); } catch { return null; }
  };
  const bound = (target, key) => {
    const value = Reflect.get(target, key);
    return typeof value === "function" ? value.bind(target) : value;
  };
  return [{
    ...durability,
    async world() {
      const world = await durability.world();
      const events = new Proxy(world.events, {
        get(target, key) {
          if (key !== "create") return bound(target, key);
          return async (runId, event, params) => {
            const entry = entryOf(event);
            return entry ? after(entry, () => target.create(runId, event, params)) : target.create(runId, event, params);
          };
        },
      });
      return new Proxy(world, { get: (target, key) => (key === "events" ? events : bound(target, key)) });
    },
  }, writes];
}
