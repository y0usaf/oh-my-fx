import { afterEach, describe, expect, test } from "bun:test";
import { HAS_API_KEY } from "../evals/eval-helpers";
import { TmuxSession, tmuxAvailable } from "./tmux-helpers";

const SKIP = !tmuxAvailable() || !HAS_API_KEY;
const TIMEOUT = 120_000;

let session: TmuxSession | null = null;

afterEach(async () => {
  if (session) { await session.kill(); session = null; }
});

describe.skipIf(SKIP)("tui: agent prompt", () => {
  test(
    "agent responds to a simple question",
    async () => {
      session = await TmuxSession.create({
        env: {
          AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
          VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
        },
      });
      await session.waitForComposer(10_000);

      await session.sendText("What is 2+2? Reply with just the number.");

      const pane = await session.waitForText("4", 60_000);
      expect(pane).toContain("4");
    },
    TIMEOUT,
  );
});
