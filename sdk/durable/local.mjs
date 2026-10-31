import { hostname } from "node:os";
import { resolve } from "node:path";
import { createWorld } from "@workflow/world-local";
import { world } from "./world.mjs";

const host = hostname();

/**
 * `dir` is where the sessions live. Workers on this machine hold a session
 * while their process runs, so a crashed worker's session frees at once.
 * With `maxDurationMs`, each delivery runs as if its function stopped after
 * that long, stopping `reserveMs` before, as on Vercel.
 */
export function local({ dir, maxDurationMs, reserveMs } = {}) {
  if (dir !== undefined && (typeof dir !== "string" || dir.length === 0)) throw new TypeError("local() dir must be a path");
  return world(() => createWorld({ ...(dir === undefined ? {} : { dataDir: dir }), recoverActiveRuns: false }), {
    name: "local",
    store: `local:${dir === undefined ? "" : resolve(dir)}`,
    livenessKnown: true,
    queueDurable: false,
    pollMs: 250,
    maxDurationMs,
    reserveMs,
    holderInfo: () => ({ pid: process.pid, host }),
    alive(lease) {
      if (lease.host !== host || !Number.isSafeInteger(lease.pid)) return null;
      try {
        process.kill(lease.pid, 0);
        return true;
      } catch (error) {
        return error?.code === "EPERM";
      }
    },
  });
}
