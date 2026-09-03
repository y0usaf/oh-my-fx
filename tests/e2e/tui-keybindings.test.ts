import { afterEach, describe, expect, test } from "bun:test";
import { HAS_API_KEY } from "../evals/eval-helpers";
import {
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const LIVE_SKIP = !tmuxAvailable() || !HAS_API_KEY;
const TIMEOUT = 30_000;

let session: TmuxSession | null = null;

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
});

describe.skipIf(LIVE_SKIP)("tui: key bindings", () => {
  test(
    "Ctrl+C twice exits the app",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);

      await session.sendKeys("C-c");
      await new Promise((r) => setTimeout(r, 500));
      await session.sendKeys("C-c");

      const exited = await session.waitForSessionEnd(5_000);
      expect(exited).toBe(true);
    },
    TIMEOUT,
  );

  test(
    "Ctrl+C once during idle shows exit hint",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);

      await session.sendKeys("C-c");
      await new Promise((r) => setTimeout(r, 300));

      const pane = await session.capturePane();
      expect(pane.toLowerCase()).toContain("ctrl+c");
    },
    TIMEOUT,
  );

  test(
    "Up arrow recalls previous input after clearing",
    async () => {
      session = await TmuxSession.create();
      await session.waitForComposer(10_000);

      await session.sendKeys("-l 'test-history-recall'");
      await session.sendKeys("Enter");
      await new Promise((r) => setTimeout(r, 2_000));

      await session.sendKeys("Up");
      await new Promise((r) => setTimeout(r, 500));

      const pane = await session.capturePane();
      expect(pane).toContain("test-history-recall");
    },
    TIMEOUT,
  );
});
