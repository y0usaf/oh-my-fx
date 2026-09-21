import { afterEach, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { FX_BIN, HAS_API_KEY } from "../evals/eval-helpers";
import { hasEmptyComposer, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const SKIP = !tmuxAvailable() || !HAS_API_KEY;
const SKIP_TMUX = !tmuxAvailable();
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
});

describe.skipIf(SKIP)("tui: startup and exit", () => {
  test(
    "fx launches and shows prompt",
    async () => {
      session = await TmuxSession.create();
      const pane = await session.waitForComposer(10_000);
      expect(hasEmptyComposer(pane)).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "/help opens the command catalog",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);
      await session.sendText("/help");
      const pane = await session.waitForText("Commands 34", 5_000);
      expect(pane).toContain("[All]");
      expect(pane).toContain("tab category");
      expect(pane).toContain("enter open");
      expect(pane).toContain("Run /help for commands");
    },
    TIMEOUT,
  );

  test(
    "/quit exits cleanly",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);
      await session.sendText("/quit");
      const exited = await session.waitForSessionEnd(5_000);
      expect(exited).toBe(true);
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: fresh-session commands", () => {
  test(
    "statusline hides the workspace identity by default",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-statusline-default-")));
      const home = join(root, "home");
      const workspace = join(root, "workspace-default-hidden");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      mkdirSync(join(workspace, ".git"), { recursive: true });
      writeFileSync(join(workspace, ".git", "HEAD"), "ref: refs/heads/default-hidden-branch\n");
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        const pane = await session.waitForComposer(10_000);
        expect(pane).not.toContain("workspace-default-hidden");
        expect(pane).not.toContain("default-hidden-branch");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "/help keeps command descriptions close after a wide-to-narrow resize",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-help-columns-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
          width: 160,
          height: 40,
        });

        await session.waitForComposer(10_000);
        await session.sendText("/help");
        const wide = await session.waitForPane(
          (pane) => pane.includes("/help") && pane.includes("show available slash commands"),
          5_000,
        );
        const wideHelp = wide.split("\n").find(
          (line) => line.includes("/help") && line.includes("show available slash commands"),
        );
        expect(wideHelp).toBeDefined();
        const wideDescriptionColumn = wideHelp!.indexOf("show available slash commands");
        expect(wideDescriptionColumn).toBe(18);

        await session.resizeWindow(60, 40);
        const narrow = await session.waitForPane(
          (pane) => pane.split("\n").some(
            (line) => line.includes("/help") && line.includes("show available"),
          ),
          5_000,
        );
        const narrowHelp = narrow.split("\n").find(
          (line) => line.includes("/help") && line.includes("show available"),
        );
        expect(narrowHelp).toBeDefined();
        expect(narrowHelp!.indexOf("show available")).toBe(wideDescriptionColumn);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "statusline refreshes the working directory and Git branch",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-statusline-")));
      const home = join(root, "home");
      const repository = join(root, "repository");
      const workspace = join(repository, "packages", "status-root");
      const headPath = join(repository, ".git", "HEAD");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(join(repository, ".git"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(headPath, "ref: refs/heads/initial-branch\n");
      writeFileSync(
        join(home, ".fx", "settings.json"),
        `${JSON.stringify({ statusLine: { workspace: true }, fast_mode: false })}\n`,
      );
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: workspace,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("initial-branch"),
          10_000,
        );

        writeFileSync(headPath, "ref: refs/heads/refreshed-branch\n");
        await session.resizeWindow(101, 30);
        await session.waitForPane(
          (pane) => pane.includes("status-root") && pane.includes("refreshed-branch"),
          5_000,
        );

        writeFileSync(headPath, "0123456789abcdef0123456789abcdef01234567\n");
        await session.resizeWindow(100, 30);
        await session.waitForText("detached:0123456789ab", 5_000);

        await session.resizeWindow(50, 30);
        const narrow = await session.waitForPane(
          (pane) => pane.includes("s-root") && pane.includes("detached:"),
          5_000,
        );
        expect(narrow).not.toContain("initial-branch");
        expect(session.isAlive()).toBe(true);

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "restore the launch header without retaining prior output",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-fresh-session-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(home, { recursive: true });
      writeFileSync(stderrPath, "");

      const version = execFileSync(FX_BIN, ["--version"], { encoding: "utf8" }).trim();
      const banner = `𝒇x v${version} · Run /help for commands`;

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
          stderrPath,
          width: 120,
          height: 40,
        });

        const initial = await session.waitForText(banner, 10_000);
        expect(initial.split(banner)).toHaveLength(2);

        for (const command of ["/clear", "/reset", "/new"]) {
          await session.sendText("/status");
          await session.waitForText("model=", 5_000);
          await session.sendText(command);
          const pane = await session.waitForPane(
            (value) =>
              value.includes(banner) &&
              !value.includes("model=") &&
              hasEmptyComposer(value),
            5_000,
          );
          expect(pane.split(banner)).toHaveLength(2);
          expect(session.isAlive()).toBe(true);
        }

        await session.sendText("/clear");
        const repeated = await session.waitForPane(
          (value) => value.includes(banner) && hasEmptyComposer(value),
          5_000,
        );
        expect(repeated.split(banner)).toHaveLength(2);
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: MCP startup", () => {
  test(
    "unresponsive MCP discovery does not block startup or shutdown",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-mcp-startup-")));
      const home = join(root, "home");
      mkdirSync(join(home, ".fx"), { recursive: true });

      let discoveryRequests = 0;
      const server = Bun.serve({
        hostname: "127.0.0.1",
        port: 0,
        async fetch(request) {
          const body = await request.text();
          if (body.includes('"method":"initialize"')) discoveryRequests += 1;
          return await new Promise<Response>(() => {});
        },
      });
      writeFileSync(
        join(home, ".fx", "mcp.json"),
        JSON.stringify({
          mcp: {
            pending: {
              type: "http",
              url: `http://127.0.0.1:${server.port}`,
              enabled: true,
            },
          },
        }),
      );

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            FX_AUTO_UPGRADE: "0",
          },
        });
        const pane = await session.waitForComposer(5_000);
        expect(hasEmptyComposer(pane)).toBe(true);
        const startupDeadline = Date.now() + 5_000;
        while (discoveryRequests < 1 && Date.now() < startupDeadline) {
          await Bun.sleep(25);
        }
        expect(discoveryRequests).toBe(1);

        await session.sendText("/mcp");
        const summary = await session.waitForText("MCP 1", 5_000);
        expect(summary).toContain("pending");
        expect(summary).toContain("Connecting");
        await session.sendKeys("Escape");
        await session.waitForPane((pane) => !pane.includes("[Servers]"), 5_000);
        await session.sendText("/mcp list");
        const status = await session.waitForText("state=connecting", 5_000);
        expect(status).toContain("pending source=profile scope=profile policy=optional");

        await session.sendText("/quit");
        expect(await session.waitForSessionEnd(5_000)).toBe(true);
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        server.stop(true);
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP_TMUX)("tui: credential onboarding", () => {
  test(
    "/setup opens the inline provider picker columns",
    async () => {
      const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-direct-setup-")));
      session = await TmuxSession.create({
        env: {
          AI_GATEWAY_API_KEY: undefined,
          VERCEL_OIDC_TOKEN: undefined,
          HOME: home,
          FX_AUTO_UPGRADE: "0",
          FX_DISABLE_KEYCHAIN: "1",
          FX_SKIP_ONBOARDING: "0",
        },
      });

      await session.waitForComposer(TIMEOUT);
      await session.sendText("/setup");
      const picker = await session.waitForPane(
        (pane) =>
          pane.includes("/provider") &&
          pane.includes("vercel") &&
          pane.includes("codex") &&
          pane.includes("grok"),
        TIMEOUT,
      );
      expect(picker).not.toContain("Connections");
      expect(picker).not.toContain("Credential source");

      await session.sendKeys("Enter");
      await session.waitForPane(
        (pane) => pane.includes("oauth") && pane.includes("api-key"),
        TIMEOUT,
      );

      // No key exists anywhere in this environment, so the api-key leaf skips
      // the which-key column and opens the paste field directly.
      await session.sendKeys("Down");
      await session.sendKeys("Enter");
      await session.waitForText("Paste or type a key", TIMEOUT);

      await session.sendKeys("Escape");
      await session.waitForComposer(TIMEOUT);
    },
    TIMEOUT,
  );

  test(
    "startup shows credential onboarding on the first frame and Escape remains session-only",
    async () => {
      const home = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-login-onboarding-")));
      const env = {
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        HOME: home,
        USER: "fx-e2e-login-onboarding",
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_NO_OPEN_BROWSER: "1",
        FX_SKIP_ONBOARDING: "0",
      };

      session = await TmuxSession.create({ env });

      const initial = await session.waitForText("Welcome to fx", TIMEOUT);
      expect(initial).toContain("Sign in with Vercel");
      expect(initial).toContain("Add an API key");
      expect(initial).toContain("esc to set up later");
      expect(initial).not.toContain("Change team");
      expect(initial).not.toContain("Switch credential");
      expect(initial).not.toContain("Skip for now");

      await session.sendKeys("Escape");
      const skipped = await session.waitForPane(
        (pane) => !pane.includes("Welcome to fx") && !pane.includes("Sign in with Vercel"),
        TIMEOUT,
      );
      expect(skipped).not.toContain("Add an API key");

      await session.kill();
      session = await TmuxSession.create({ env });
      const restarted = await session.waitForText("Welcome to fx", TIMEOUT);
      expect(restarted).toContain("Sign in with Vercel");
      expect(restarted).toContain("Add an API key");
    },
    60_000,
  );
});

describe.skipIf(SKIP_TMUX)("tui: custom themes", () => {
  async function startThemedSession(
    root: string,
    themeFiles: Record<string, unknown>,
    options: { fxTheme?: string; settingsTheme?: string; colorFgBg: string },
  ): Promise<{ pane: string; escapes: string; stderrPath: string }> {
    const home = join(root, "home");
    const stderrPath = join(root, "stderr.log");
    mkdirSync(join(home, ".fx", "themes"), { recursive: true });
    for (const [file, contents] of Object.entries(themeFiles)) {
      writeFileSync(join(home, ".fx", "themes", file), JSON.stringify(contents));
    }
    if (options.settingsTheme) {
      writeFileSync(
        join(home, ".fx", "settings.json"),
        JSON.stringify({ theme: options.settingsTheme }),
      );
    }
    writeFileSync(stderrPath, "");

    session = await TmuxSession.create({
      cwd: root,
      env: {
        HOME: home,
        AI_GATEWAY_API_KEY: undefined,
        VERCEL_OIDC_TOKEN: undefined,
        FX_AUTO_UPGRADE: "0",
        FX_DISABLE_KEYCHAIN: "1",
        FX_SKIP_ONBOARDING: "1",
        FX_THEME: options.fxTheme,
        COLORFGBG: options.colorFgBg,
        COLORTERM: undefined,
        TERM_PROGRAM: "Apple_Terminal",
      },
      stderrPath,
      width: 100,
      height: 30,
    });
    const pane = await session.waitForComposer(10_000);
    const escapes = await session.capturePaneEscapes();
    return { pane, escapes, stderrPath };
  }

  test(
    "FX_THEME loads a VS Code theme file from ~/.fx/themes",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-")));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx", "themes"), { recursive: true });
      writeFileSync(
        join(home, ".fx", "themes", "e2e-accent.json"),
        JSON.stringify({
          name: "E2E Accent",
          colors: { "editor.foreground": "#FF0000" },
        }),
      );
      writeFileSync(stderrPath, "");

      try {
        session = await TmuxSession.create({
          cwd: root,
          env: {
            HOME: home,
            AI_GATEWAY_API_KEY: undefined,
            VERCEL_OIDC_TOKEN: undefined,
            FX_AUTO_UPGRADE: "0",
            FX_DISABLE_KEYCHAIN: "1",
            FX_SKIP_ONBOARDING: "1",
            FX_THEME: "e2e-accent",
            COLORFGBG: "15;0",
            COLORTERM: undefined,
            TERM_PROGRAM: "Apple_Terminal",
          },
          stderrPath,
          width: 100,
          height: 30,
        });

        const pane = await session.waitForComposer(10_000);
        expect(pane).toContain("Run /help for commands");
        const escapes = await session.capturePaneEscapes();
        // editor.foreground #FF0000 quantizes to xterm-256 color 196 without
        // truecolor (Apple_Terminal), and themes the hint text at startup.
        expect(escapes).toContain("38;5;196");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "pinned theme swaps to its sibling variant on a mismatched terminal",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-swap-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
            "e2e-pair-light.json": { name: "Pair Light", type: "light", colors: { hint: "#00FF00" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal
        );
        expect(pane).toContain("Run /help for commands");
        // The light sibling's hint (#00FF00 -> xterm-256 46) applies, not the
        // pinned dark theme's (#0000FF -> 21).
        expect(escapes).toContain("38;5;46");
        expect(escapes).not.toContain("38;5;21");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "pinned theme falls back to the builtin variant when no sibling exists",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-fallback-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal, no e2e-pair-light.json on disk
        );
        expect(pane).toContain("Run /help for commands");
        // Builtin fx-light hint, not the mismatched dark theme's blue.
        expect(escapes).toContain("38;5;235");
        expect(escapes).not.toContain("38;5;21");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "a sibling whose declared variant also mismatches falls back to builtin",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-misdeclared-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-pair-dark.json": { name: "Pair Dark", type: "dark", colors: { hint: "#0000FF" } },
            // Misdeclared: named -light but says dark, with a green marker.
            "e2e-pair-light.json": { name: "Pair Light", type: "dark", colors: { hint: "#00FF00" } },
          },
          { fxTheme: "e2e-pair-dark", colorFgBg: "0;15" }, // light terminal
        );
        expect(pane).toContain("Run /help for commands");
        expect(escapes).toContain("38;5;235");
        expect(escapes).not.toContain("38;5;46");
        expect(escapes).not.toContain("38;5;21");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "settings.json theme applies without FX_THEME",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-settings-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-accent.json": { name: "E2E Accent", type: "dark", colors: { hint: "#FF0000" } },
          },
          { settingsTheme: "e2e-accent", colorFgBg: "15;0" }, // dark terminal, no FX_THEME
        );
        expect(pane).toContain("Run /help for commands");
        // The configured theme's hint (#FF0000 -> xterm-256 196) applies.
        expect(escapes).toContain("38;5;196");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "FX_THEME wins over the settings.json theme",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-precedence-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {
            "e2e-accent.json": { name: "E2E Accent", type: "dark", colors: { hint: "#FF0000" } },
          },
          { settingsTheme: "e2e-accent", fxTheme: "dark", colorFgBg: "15;0" },
        );
        expect(pane).toContain("Run /help for commands");
        // Builtin fx-dark hint (255), not the configured theme's red.
        expect(escapes).toContain("38;5;255");
        expect(escapes).not.toContain("38;5;196");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );

  test(
    "settings-pinned variant ignores live terminal mode flips",
    async () => {
      const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-e2e-theme-pin-")));
      try {
        const { pane, escapes, stderrPath } = await startThemedSession(
          root,
          {},
          { settingsTheme: "dark", colorFgBg: "15;0" }, // dark terminal, pinned dark
        );
        expect(pane).toContain("Run /help for commands");
        expect(escapes).toContain("38;5;255"); // fx-dark hint
        expect(escapes).not.toContain("38;5;235"); // fx-light hint

        // The terminal reports a light-mode change mid-session (DEC 997);
        // a pinned variant must not follow it.
        session!.sendKeysImmediate(["-H", "1b", "5b", "3f", "39", "39", "37", "3b", "32", "6e"]);
        await new Promise((resolve) => setTimeout(resolve, 1500));

        const after = await session!.capturePaneEscapes();
        expect(after).toContain("38;5;255");
        expect(after).not.toContain("38;5;235");
        expect(readFileSync(stderrPath, "utf8")).toBe("");
      } finally {
        if (session) {
          await session.kill();
          session = null;
        }
        rmSync(root, { recursive: true, force: true });
      }
    },
    TIMEOUT,
  );
});
