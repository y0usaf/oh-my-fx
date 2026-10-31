import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { REPO_ROOT } from "../lib/tlc";
import { runScenario } from "./driver";
import { scenarios } from "./scenarios";

const [report, checkout] = process.argv.slice(2);
if (!report) throw new Error("usage: fixed-check.ts <report.json> [checkout]");
const worktree = resolve(checkout ?? REPO_ROOT);

const results = [];
let failures = 0;
const twoServers = (provider: "codex" | "grok") => {
  const requests = [{ id: "r1", engine: "e1", url: "provider" as const }, { id: "r2", engine: "e2", url: "provider" as const }];
  const base = { provider, requests, expiring: false, rejecting: false, foreignRefresh: false, checkAccount: true, scopeAll: false, noSingleFlight: false, lock: true };
  return [
    { name: `${provider}-two-servers-near-expiry`, setup: { ...base, expiring: true }, script: async (world: any) => { await Promise.all([world.send("r1"), world.send("r2")]); } },
    { name: `${provider}-two-servers-rejected-together`, setup: { ...base, rejecting: true }, script: async (world: any) => { await Promise.all([world.send("r1"), world.send("r2")]); } },
  ];
};

for (const provider of ["codex", "grok"] as const) {
  for (const scenario of [...scenarios(provider).map((s) => ({ ...s, setup: { ...s.setup, sharedMemory: true } })), ...twoServers(provider)]) {
    const setup = scenario.setup;
    const run = await runScenario(worktree, scenario.name, setup, scenario.script, { accounts: scenario.accounts });
    const redeems = run.events.filter((event) => event.k === "redeem");
    const reused = redeems.filter((event) => event.k === "redeem" && !event.ok).length;
    const foreign = scenario.name === "grok-refresh-for-another-account";
    const answered = Object.values(run.outcomes).every((outcome) => outcome === "status 200");
    const anomalies = run.anomalies.filter((text) => text !== "credentials() ran outside a request");
    const ok = reused === 0 && anomalies.length === 0 && (foreign ? !answered : answered);
    if (!ok) failures += 1;
    results.push({ scenario: scenario.name, ok, redeems: redeems.length, reused, outcomes: run.outcomes, anomalies });
    console.log(`${ok ? "ok  " : "FAIL"} ${scenario.name}: redeems ${redeems.length}, reused ${reused}, ${JSON.stringify(run.outcomes)}`);
  }
}
writeFileSync(report, JSON.stringify({ worktree, results }, null, 2));
console.log(failures ? `${failures} scenario(s) failed` : "every scenario passed");
process.exit(failures ? 1 : 0);
