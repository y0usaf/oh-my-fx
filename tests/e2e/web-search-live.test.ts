import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HAS_API_KEY, runFx } from "../evals/eval-helpers";

const TIMEOUT = 180_000;
const OUTER_MODEL = "anthropic/claude-sonnet-4.6";
const BACKENDS = [
  "ai_gateway_exa_search",
  "ai_gateway_parallel_search",
] as const;

function createIsolatedRoot() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "fx-web-search-live-")));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      model: OUTER_MODEL,
      permission: { web_search: { "*": "allow" } },
    }),
  );
  return { root, home, workspace: realpathSync(workspace) };
}

function linkedSourceUrl(output: string) {
  const linked = /\u001b]8;[^;]*;https?:\/\//.test(output) ||
    /\[[^\]]+\]\(https?:\/\/[^)]+\)/.test(output);
  const source = output.match(/https?:\/\/[^\s)\u001b\u0007]+/)?.[0];
  return { linked, source };
}

describe.skipIf(!HAS_API_KEY)("live web_search private backends", () => {
  for (const backend of BACKENDS) {
    test(
      `${backend} returns a linked cited source with request diagnostics`,
      async () => {
        const root = createIsolatedRoot();
        const traceLog = join(root.root, "trace.log");
        try {
          const result = await runFx(
            [
              "ask",
              "--auto",
              "--json",
              "--no-save",
              "--timeout",
              String(TIMEOUT),
              "Use web_search exactly once for the latest Zig release information, then answer from the search results only. Do not call web_fetch or any other tool. In your final answer, cite at least one source as a Markdown link in the exact form [source title](https://source-url).",
            ],
            {
              cwd: root.workspace,
              env: {
                HOME: root.home,
                FX_AUTO_UPGRADE: "0",
                FX_TRACE_LOG: traceLog,
                FX_TRACE_SCOPES: "agent,gateway,stream,web_search",
                FX_WEB_SEARCH_BACKEND: backend,
              },
              timeoutMs: TIMEOUT,
            },
          );

          if (result.code !== 0) {
            throw new Error(
              `fx exited with code ${result.code}\nstdout: ${result.stdout.slice(-4000)}\nstderr: ${result.stderr.slice(0, 8000)}`,
            );
          }
          const json = JSON.parse(result.stdout.trim()) as {
            output: string;
            model: string;
            tool_calls: Array<{
              name: string;
              status: string;
              web_search?: { searches: number; duration_ms: number };
            }>;
          };
          const trace = existsSync(traceLog) ? readFileSync(traceLog, "utf8") : "";
          const sawProviderSearchCall = trace.includes("tool_call_count=1");
          const sawAcceptedFinish = trace.includes("finish_reason=tool-calls") ||
            trace.includes("finish_reason=stop");
          if (!sawProviderSearchCall || !sawAcceptedFinish || trace.includes("provider_tool_calls_rejected")) {
            throw new Error(
              `web_search did not succeed\nstdout: ${result.stdout.slice(-4000)}\nstderr: ${result.stderr.slice(0, 8000)}\ntrace: ${trace.slice(-12000)}`,
            );
          }
          expect(json.model).toBe(OUTER_MODEL);
          expect(json.model).not.toContain("perplexity");
          expect(json.model).not.toContain("parallel");
          expect(json.tool_calls).toHaveLength(0);
          expect(json.tool_calls.some((call) => call.name === "exa_search")).toBe(false);
          expect(json.tool_calls.some((call) => call.name === "perplexity_search")).toBe(false);
          expect(json.tool_calls.some((call) => call.name === "parallel_search")).toBe(false);
          expect(json.tool_calls.some((call) => call.name === "web_fetch")).toBe(false);

          const citation = linkedSourceUrl(json.output);
          expect(citation.source).toBeDefined();
          if (!citation.linked) {
            throw new Error(`final answer source is not linked: ${json.output}`);
          }

          console.log(
            `[live-web-search] backend=${backend} outer_model=${json.model} gateway_tool_calls=1 source_url=${citation.source} linked_citation=${citation.linked}`,
          );
        } finally {
          rmSync(root.root, { recursive: true, force: true });
        }
      },
      TIMEOUT,
    );
  }
});
