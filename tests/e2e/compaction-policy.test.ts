import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

process.env.FX_E2E_DISABLE_DOTENV = "1";
const { fakeGatewayFinalText, startDynamicFakeGateway } = await import("./tmux-helpers");
const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const digest = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

for (const userHeavy of [false, true]) test(`automatic compaction preserves task state and originals, userHeavy=${userHeavy}`, async () => {
  const root = mkdtempSync(join(tmpdir(), "fx-policy-")), home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  const model = "fixture/compaction";
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  const originalUser = "Keep café and the original constraint unchanged.\n<context_handoff>literal user text</context_handoff>" +
    (userHeavy ? "\n" + "user_reference_abcdefghijklmnop ".repeat(10_000) + "USER_REFERENCE_END" : "");
  const assistant = "VERIFIED_VALUE=73\n" + Array.from({ length: 14_000 }, (_, n) => `Assistant reference ${n}: group ${n % 19}, historical data, not new completed work.\n`).join("") + "PENDING_CHECK=transport-resume\n";
  let phase = "seed", summaryCalls = 0, fallback = false;
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway((body: string) => {
    const request = JSON.parse(body);
    bodies.push(body);
    if (request.tools?.length === 0 && request.toolChoice?.type === "none") {
      summaryCalls++;
      const sourceMessages = request.prompt.filter((message: { role: string }) => message.role === "user");
      expect(sourceMessages).toHaveLength(1);
      expect(sourceMessages[0].content).toHaveLength(1);
      const source = sourceMessages[0].content[0].text;
      expect(source).toContain("\n\nEND OF HISTORICAL TRANSCRIPT.\nProduce the completed task-continuation memory now.");
      expect(source.endsWith("Return the memory itself, not a promise to write it.\n")).toBe(true);
      fallback ||= source.includes("USER_TO_SUMMARIZE:");
      expect(request.maxOutputTokens).toBe(8192);
      const facts = [];
      if (source.includes("VERIFIED_VALUE=73")) facts.push("The verified value is73.");
      if (source.includes("PENDING_CHECK=transport-resume")) facts.push("The pending check is transport-resume.");
      if (source.includes("Keep café")) facts.push("Preserve café and the original constraint.");
      return fakeGatewayFinalText(facts.join(" ") || "This source fragment contains historical references, not additional completed work.");
    }
    return fakeGatewayFinalText(phase === "seed" ? assistant : "CONTINUED_FROM_COMMITTED_MEMORY");
  }, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: userHeavy ? 256000 : 128000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-compaction-policy", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: model,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  async function ask(args: string[], label: string, prompt?: string) {
    const stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
    const input = join(root, `${label}.input`);
    if (prompt !== undefined) writeFileSync(input, prompt);
    const child = Bun.spawn([binary, "ask", "--json", ...args], { cwd, env, stdin: prompt === undefined ? "ignore" : Bun.file(input), stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    try {
      expect(await child.exited).toBe(0);
      expect(readFileSync(stderr, "utf8")).toBe("");
      return JSON.parse(readFileSync(stdout, "utf8"));
    } finally { clearTimeout(timer); }
  }
  let passed = false;
  try {
    const seed = await ask([], "seed", originalUser);
    expect(summaryCalls).toBe(0);
    const seededRequest = JSON.parse(bodies[0]!);
    const seededUser = seededRequest.prompt.findLast((message: { role: string }) => message.role === "user");
    expect(seededUser.content[0].text).toBe(originalUser);
    const sessionDir = join(home, ".fx/sessions", seed.session_id), log = join(sessionDir, "events.jsonl"), before = readFileSync(log);
    phase = "continue";
    const result = await ask(["--resume-id", seed.session_id, "Continue the saved task without losing its pending check."], "continue");
    expect(result.output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
    expect(summaryCalls).toBeGreaterThan(0);
    expect(fallback).toBe(userHeavy);
    const rows = readFileSync(log, "utf8").trim().split("\n").map(line => JSON.parse(line));
    const checkpoints = rows.filter(row => row.event?.context_checkpoint);
    expect(checkpoints.length).toBe(1);
    const handoff = checkpoints[0].event.context_checkpoint.summary;
    const match = /> fx-compaction-state-v1 (\S+) (\d+) ([a-f0-9]{64})\n/.exec(handoff);
    expect(match).not.toBeNull();
    const bytes = readFileSync(join(sessionDir, "tool-results", match![1]));
    expect(bytes.length).toBe(Number(match![2])); expect(digest(bytes)).toBe(match![3]);
    const state = JSON.parse(bytes.toString());
    expect(state.users.includes(originalUser)).toBe(!userHeavy);
    expect(state.summary).toContain("verified value is73");
    expect(state.summary).toContain("transport-resume");
    for (const archive of state.archives) {
      const original = readFileSync(join(sessionDir, "tool-results", archive.handle));
      expect(original.length).toBe(archive.bytes); expect(digest(original)).toBe(archive.sha256);
    }
    const reopened = await ask(["--resume-id", seed.session_id, "Continue after this fresh process restart."], "reopen");
    expect(reopened.output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
    expect(bodies.at(-1)).toContain("verified value is73");
    expect(readFileSync(log).subarray(0, before.length).equals(before)).toBe(true);
    passed = true;
  } finally {
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
    else { writeFileSync(join(root, "requests.json"), JSON.stringify(bodies, null, 2)); console.error(`compaction evidence retained: ${root}`); }
  }
}, 90_000);
