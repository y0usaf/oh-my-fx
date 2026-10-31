import { expect, test } from "bun:test";
import { join } from "node:path";
import { artifacts } from "../lib/context";
import { fixture, merge, save, serverEvents, stdioServer, waitFor, writeProfile, writeProject, type Fixture } from "./driver";
import { serverRecords, Shell } from "./shell";
import { checkTrace } from "./trace";

const NEXT_MCP = process.env.FX_TLA_NEXT_MCP === "1";


function alive(pid: number) { try { process.kill(pid, 0); return true; } catch { return false; } }
const started = (f: Fixture, name: string) => serverEvents(f).filter((e) => e.name === name && e.ev === "start");
const listed = (f: Fixture, name: string) => serverEvents(f).filter((e) => e.name === name && e.ev === "listed");

async function finish(shell: Shell, constants: Record<string, unknown>) {
  const events = serverEvents(shell.f);
  const quitAt = shell.records.find((r) => r.event === "quit")?.at ?? null;
  const records = merge(shell.records.filter((r) => r.event !== "release"), serverRecords(events, quitAt));
  for (const release of shell.records.filter((r) => r.event === "release")) {
    const pid = release.data?.beforeExitOf;
    const at = records.findIndex((r) => r.event === "stop" && r.note?.startsWith(`pid ${pid} `));
    if (at < 0) throw new Error(`harness: no exit of pid ${pid} to place the release before`);
    records.splice(at, 0, { event: "release", at: records[at]!.at, note: release.note });
  }
  const verdict = await checkTrace({ module: "HostLifecycle", records, constants: constants as never, dir: join(shell.f.base, "trace") });
  save(join(shell.f.base, "verdict.json"), verdict);
  return { verdict, events };
}

function setup(name: string, profile: string[], project: string[], slow: string[] = []) {
  const f = fixture(artifacts, name);
  writeProfile(f, Object.fromEntries(profile.map((n) => [n, stdioServer(f, n, slow.includes(n) ? { FIXTURE_INIT_DELAY_MS: "6000" } : {})])));
  if (project.length) writeProject(f, Object.fromEntries(project.map((n) => [n, stdioServer(f, n)])));
  return f;
}

test("first frame starts the profile servers, the project server waits unspawned, and quitting SIGTERMs all without waiting (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-first-frame", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    const line = await shell.status({ k: "attn", who: "p", why: "waiting" });
    expect(line).toEqual({ k: "attn", who: "p", why: "waiting", r: 0, e: 0 });
    const pids = [...started(shell.f, "a"), ...started(shell.f, "b")].map((e) => e.pid);
    const quitMs = await shell.quit();
    await waitFor("every server gone", () => pids.every((pid) => !alive(pid)), 5_000);
    const { verdict, events } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxHosts: 1, ObsMaxLeases: 1 });
    expect(started(shell.f, "p")).toEqual([]);
    expect(events.filter((e) => e.ev === "sigterm").map((e) => e.name).sort()).toEqual(["a", "b"]);
    expect(quitMs).toBeLessThan(1_000);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 120_000);

test("approve reloads: the project server starts and the unchanged servers come back (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-approve", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    await shell.status({ k: "attn", who: "p", why: "waiting" });
    await shell.type("/mcp approve p", { event: "reload", data: { server: "p", change: "approved" } });
    await shell.tui.waitForText("Approved p", 10_000);
    await waitFor("p, a and b listed again", () => listed(shell.f, "p").length && listed(shell.f, "a").length === 2 && listed(shell.f, "b").length === 2, 20_000);
    expect(await shell.status({ k: "count", r: 3, e: 3 })).toEqual({ k: "count", who: "", why: "", r: 3, e: 3 });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict, events } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxHosts: 2, ObsMaxLeases: 1 });
    expect(events.filter((e) => e.ev === "eof").map((e) => e.name).sort()).toEqual(["a", "b"]);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);

test("reject and remove reload: the project server never starts and the removed one stops for good (trace ACCEPTED)", async () => {
  const shell = new Shell(setup("hl-reject-remove", ["a", "b"], ["p"]));
  try {
    await shell.start();
    await waitFor("a and b listed", () => listed(shell.f, "a").length && listed(shell.f, "b").length, 20_000);
    await shell.status({ k: "attn", who: "p", why: "waiting" });
    await shell.type("/mcp reject p", { event: "reload", data: { server: "p", change: "rejected" } });
    await shell.tui.waitForText("Rejected p", 10_000);
    await waitFor("a and b listed again", () => listed(shell.f, "a").length === 2 && listed(shell.f, "b").length === 2, 20_000);
    expect(await shell.status({ k: "count", r: 2, e: 2 })).toEqual({ k: "count", who: "", why: "", r: 2, e: 2 });
    await shell.type("/mcp remove b", { event: "reload", data: { server: "b", change: "removed" } });
    await shell.tui.waitForText("Removed b", 10_000);
    await waitFor("a listed a third time", () => listed(shell.f, "a").length === 3, 20_000);
    expect(await shell.status({ k: "count", r: 1, e: 1 })).toEqual({ k: "count", who: "", why: "", r: 1, e: 1 });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["a", "b", "p"], ObsProject: ["p"], ObsReachable: ["a", "b", "p"], ObsNeedsAuth: [], ObsMaxHosts: 3, ObsMaxLeases: 1 });
    expect(started(shell.f, "p")).toEqual([]);
    expect(started(shell.f, "b").length).toBe(2);
    expect(verdict.verdict).toBe("ACCEPTED");
  } finally { await shell.stop(); }
}, 150_000);

test.skipIf(!NEXT_MCP)("finding: a reload while `/mcp show` holds the old host runs two owners and two processes of one server (trace VIOLATES AtMostOneOwner, OneProcessPerServer)", async () => {
  const shell = new Shell(setup("hl-two-owners", ["s"], ["p"], ["s"]));
  try {
    await shell.start();
    await waitFor("s started", () => started(shell.f, "s").length === 1, 20_000);
    await shell.type("/mcp show s", { event: "lease" });
    await Bun.sleep(500);
    await shell.type("/mcp approve p", { event: "reload", data: { server: "p", change: "approved" } });
    await shell.tui.waitForText("Approved p", 10_000);
    const both = await waitFor("a second s while the first runs", () => {
      const s = started(shell.f, "s");
      return s.length === 2 && s.every((e) => alive(e.pid)) ? s : null;
    }, 10_000);
    save(join(shell.f.base, "two-processes.json"), { at: Date.now(), pids: both.map((e) => e.pid), alive: both.map((e) => alive(e.pid)) });
    await shell.tui.waitForText("status     ready", 20_000);
    const seen = Date.now();
    const eof = await waitFor("the first s stopped", () => serverEvents(shell.f).find((e) => e.name === "s" && e.ev === "eof" && e.pid === both[0]!.pid), 10_000);
    shell.records.push({ event: "release", at: seen, note: `seen ${seen}, first s eof ${eof.t}; placed before pid ${eof.pid}'s exit`, data: { beforeExitOf: eof.pid } });
    await waitFor("p and the second s listed", () => listed(shell.f, "p").length && listed(shell.f, "s").length === 2, 20_000);
    await shell.status({ k: "count", r: 2, e: 2 });
    await shell.quit();
    await Bun.sleep(500);
    const { verdict } = await finish(shell, { ObsServers: ["s", "p"], ObsProject: ["p"], ObsReachable: ["s", "p"], ObsNeedsAuth: [], ObsMaxHosts: 2, ObsMaxLeases: 1 });
    expect(both.length).toBe(2);
    expect(verdict.verdict).toBe("VIOLATES");
    expect(verdict.broken).toEqual(expect.arrayContaining(["AtMostOneOwner", "OneProcessPerServer"]));
  } finally { await shell.stop(); }
}, 150_000);
