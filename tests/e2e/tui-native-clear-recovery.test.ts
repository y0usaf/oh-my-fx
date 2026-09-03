import { afterEach, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import { composerContains, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const tmuxTest = test.skipIf(!tmuxAvailable());
const PASTE_START = ["1b", "5b", "32", "30", "30", "7e"] as const;
const PASTE_END = ["1b", "5b", "32", "30", "31", "7e"] as const;
let session: TmuxSession | null = null;
const temp_dirs: string[] = [];

afterEach(async () => {
  await session?.kill();
  session = null;
  for (const dir of temp_dirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

async function waitForTrace(path: string, text: string, timeout_ms = 5_000): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < timeout_ms) {
    if (existsSync(path) && readFileSync(path, "utf8").includes(text)) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`Timed out waiting for trace ${JSON.stringify(text)}`);
}

function clearPaneTerminal(active: TmuxSession): void {
  const tty = execFileSync(
    "tmux",
    ["display-message", "-t", active.name, "-p", "#{pane_tty}"],
    { encoding: "utf-8" },
  ).trim();
  writeFileSync(tty, "\x1b[3J\x1b[2J\x1b[H");
}

function textHex(text: string): string[] {
  return Array.from(new TextEncoder().encode(text), (byte) =>
    byte.toString(16).padStart(2, "0")
  );
}

tmuxTest("direct native-clear recovery resets the view and replays the held draft", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");
  const old_marker = "PRE_NATIVE_CLEAR_MARKER_8213";

  session = await TmuxSession.create({
    cmd: `sh -c "printf '${old_marker}\\n'; exec '${FX_BIN}'"`,
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear,frame_schedule",
    },
  });
  await session.waitForComposer(10_000);

  clearPaneTerminal(session);
  await session.sendLiteral("abc");
  await waitForTrace(trace_path, "native_clear_probe requested");

  await session.waitForPane((pane) => composerContains(pane, "abc"), 10_000);
  const history = await session.captureFullScrollback();
  expect(history).not.toContain(old_marker);
  expect(history).toContain("𝒇x v");
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);

tmuxTest("direct healthy screens retain an ordinary burst without resetting", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-match-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");
  const old_marker = "PRE_NATIVE_MATCH_MARKER_4051";

  session = await TmuxSession.create({
    cmd: `sh -c "printf '${old_marker}\\n'; exec '${FX_BIN}'"`,
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear",
    },
  });
  await session.waitForComposer(10_000);

  await session.sendLiteral("abc");
  await waitForTrace(trace_path, "native_clear_probe match");
  await session.waitForPane((pane) => composerContains(pane, "abc"), 10_000);

  const history = await session.captureFullScrollback();
  expect(history).toContain(old_marker);
  expect(readFileSync(trace_path, "utf8")).not.toContain("native_clear_recovery_requested");
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);

tmuxTest("native-clear replay settles a complete paste before the next key", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-paste-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");

  session = await TmuxSession.create({
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_THEME: undefined,
      TMUX: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear,input",
    },
  });
  await session.waitForComposer(10_000);

  session.sendLiteralImmediate("a");
  await waitForTrace(trace_path, "native_clear_probe requested");
  await session.sendHexBytes([
    ...PASTE_START,
    ...textHex("x"),
    ...PASTE_END,
  ]);
  await waitForTrace(trace_path, "paste end owner=composer bytes=1");

  await session.sendLiteralText("Z");
  await session.waitForPane((pane) => composerContains(pane, "axZ"), 10_000);
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);

tmuxTest("tmux leaves native-clear probing disabled and preserves ordinary input", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fx-native-clear-tmux-"));
  temp_dirs.push(dir);
  const trace_path = join(dir, "trace.log");
  const stderr_path = join(dir, "stderr.log");

  session = await TmuxSession.create({
    width: 100,
    height: 30,
    stderrPath: stderr_path,
    env: {
      AI_GATEWAY_API_KEY: undefined,
      VERCEL_OIDC_TOKEN: undefined,
      FX_TRACE_LOG: trace_path,
      FX_TRACE_SCOPES: "native_clear",
    },
  });
  await session.waitForComposer(10_000);
  await session.sendLiteral("a");
  await session.waitForPane((pane) => composerContains(pane, "a"), 10_000);

  const trace = existsSync(trace_path) ? readFileSync(trace_path, "utf8") : "";
  expect(trace).not.toContain("native_clear_probe requested");
  expect(readFileSync(stderr_path, "utf8")).toBe("");
}, 30_000);
