import { expect, test } from "bun:test";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { runModels } from "./model";
import { save } from "./driver";
import { checkTrace, type TraceRecord } from "./trace";

test("TLC: every model's smoke and stress pass, every planted bug is caught, stated-property findings and repair witnesses hold", async () => {
  const results = await runModels(join(artifacts, "tlc"));
  save(join(artifacts, "gate-summary.json"), results.map(({ module, label, kind, verdict, expected, distinct, exit }) => ({ module, label, kind, verdict, expected, distinct, exit })));
  expect(results.filter((r) => r.verdict === "FAIL").map((r) => r.label)).toEqual([]);
  const count = (kind: string, verdict: string) => results.filter((r) => r.kind === kind && r.verdict === verdict).length;
  expect(count("smoke", "PASS")).toBe(5);
  expect(count("stress", "PASS")).toBe(5);
  expect(count("mutant", "CAUGHT")).toBe(results.filter((r) => r.kind === "mutant").length);
  expect(count("finding", "FINDING")).toBe(2);
  expect(count("repair", "PASS")).toBe(1);
}, 1_800_000);

const controls: { name: string; module: string; constants: Record<string, never> | Record<string, unknown>; good: TraceRecord[]; bad: TraceRecord[]; badAt: number }[] = [
  {
    name: "credentials", module: "Credentials",
    constants: { ObsNames: ["web"], ObsFaults: ["unreadable"], ObsInitKinds: ["absent"], ObsInitEntries: [], ObsInitImported: [false], ObsInitMarked: [false], ObsInitV1: ["web"] },
    good: [
      { event: "observe", data: { kind: "absent", entries: [], imported: false, marked: false, v1: ["web"] } },
      { event: "run", data: { cmd: "get", server: "" } },
      { event: "observe", data: { kind: "ok", entries: ["web"], imported: true, marked: true, v1: ["web"] } },
    ],
    bad: [
      { event: "observe", data: { kind: "absent", entries: [], imported: false, marked: false, v1: ["web"] } },
      { event: "run", data: { cmd: "get", server: "" } },
      { event: "observe", data: { kind: "ok", entries: ["web"], imported: false, marked: true, v1: ["web"] } },
    ],
    badAt: 2,
  },
  {
    name: "host lifecycle", module: "HostLifecycle",
    constants: { ObsServers: ["a", "p"], ObsProject: ["p"], ObsReachable: ["a", "p"], ObsNeedsAuth: [], ObsMaxHosts: 1, ObsMaxLeases: 1 },
    good: [
      { event: "spawn", data: { server: "a" } },
      { event: "ready", data: { server: "a" } },
      { event: "status", data: { k: "attn", who: "p", why: "waiting", r: 0, e: 0 } },
      { event: "quit" },
      { event: "term", data: { server: "a" } },
    ],
    bad: [
      { event: "spawn", data: { server: "a" } },
      { event: "spawn", data: { server: "p" } },
    ],
    badAt: 1,
  },
  {
    name: "sign-in", module: "SignIn",
    constants: { ObsMaxLogins: 1, ObsMaxHosts: 1, ObsMaxLeases: 0, ObsBridge: false },
    good: [
      { event: "login" }, { event: "authorize", data: { login: 1 } }, { event: "probe", data: { login: 1, result: "open" } },
      { event: "callback", data: { login: 1, state: 1, kind: "get" } }, { event: "redeem", data: { login: 1 } },
      { event: "signed_in", data: { login: 1 } }, { event: "probe", data: { login: 1, result: "closed" } },
    ],
    bad: [
      { event: "login" }, { event: "authorize", data: { login: 1 } },
      { event: "callback", data: { login: 1, state: 0, kind: "get" } }, { event: "redeem", data: { login: 1 } },
    ],
    badAt: 3,
  },
  {
    name: "elicitation routing (2026)", module: "ElicitationRouting",
    constants: { ObsVersions: ["2026"], ObsMaxQ: 2, ObsSlots: 2, ObsGuard: false },
    good: [
      { event: "ask", data: { q: 1 } }, { event: "shown", data: { q: 1 } }, { event: "answer", data: { q: 1 } },
      { event: "delivered", data: { target: 1, from: 1 } }, { event: "call_end" },
    ],
    bad: [
      { event: "ask", data: { q: 1 } }, { event: "shown", data: { q: 1 } }, { event: "ask", data: { q: 2 } },
      { event: "answer", data: { q: 1 } }, { event: "delivered", data: { target: 2, from: 1 } },
    ],
    badAt: 4,
  },
];

for (const c of controls) {
  test(`bridge control (${c.name}): the known-good trace is ACCEPTED and the known-bad one REJECTED at record ${c.badAt}`, async () => {
    const dir = join(artifacts, "bridge", c.module);
    const good = await checkTrace({ module: c.module, records: c.good, constants: c.constants as never, dir: join(dir, "good") });
    const bad = await checkTrace({ module: c.module, records: c.bad, constants: c.constants as never, dir: join(dir, "bad") });
    expect(good.verdict).toBe("ACCEPTED");
    expect(bad.verdict).toBe("REJECTED");
    expect(bad.firstBad?.index).toBe(c.badAt);
  }, 300_000);
}

test("bridge control: an empty trace is INCONCLUSIVE, never a pass", async () => {
  const v = await checkTrace({ module: "SignIn", records: [], constants: { ObsMaxLogins: 1, ObsMaxHosts: 1, ObsMaxLeases: 0, ObsBridge: false }, dir: join(artifacts, "bridge", "empty") });
  expect(v.verdict).toBe("INCONCLUSIVE");
});
