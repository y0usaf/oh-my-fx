// Model-backed judge for whether generated files satisfy an eval spec.
import { expect } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { EVAL_MODEL, runEval } from "./eval-helpers";

export interface Requirement {
  requirement: string;
  implemented: boolean;
  evidence: string;
}

export interface JudgeResult {
  requirements: Requirement[];
  adherenceScore: number;
  missingRequirements: string[];
  verdict: "pass" | "fail";
  reasoning: string;
}

const SKIP_DIRS = new Set([
  "node_modules",
  ".git",
  "dist",
  ".next",
  ".turbo",
  "coverage",
  ".cache",
  "zig-cache",
  "zig-out",
]);

const SKIP_FILES = new Set([
  "package-lock.json",
  "pnpm-lock.yaml",
  "yarn.lock",
  "bun.lockb",
  "bun.lock",
]);

const INCLUDE_EXTENSIONS = new Set([
  ".ts",
  ".tsx",
  ".js",
  ".jsx",
  ".mjs",
  ".json",
  ".css",
  ".html",
  ".zig",
  ".py",
  ".go",
  ".rs",
]);

const MAX_TOTAL_CHARS = 150_000;

interface CollectedFile {
  path: string;
  content: string;
}

function collectFiles(dir: string, base?: string): CollectedFile[] {
  const root = base ?? dir;
  const files: CollectedFile[] = [];

  let entries: string[];
  try {
    entries = readdirSync(dir);
  } catch {
    return files;
  }

  for (const entry of entries) {
    if (SKIP_DIRS.has(entry)) continue;
    if (SKIP_FILES.has(entry)) continue;
    const full = join(dir, entry);

    let stat: ReturnType<typeof statSync> | undefined;
    try {
      stat = statSync(full);
    } catch {
      continue;
    }

    if (stat.isDirectory()) {
      files.push(...collectFiles(full, root));
    } else if (stat.isFile()) {
      const ext = entry.slice(entry.lastIndexOf("."));
      if (!INCLUDE_EXTENSIONS.has(ext)) continue;
      try {
        const content = readFileSync(full, "utf-8");
        files.push({ path: relative(root, full), content });
      } catch {}
    }
  }

  return files;
}

function buildFileContext(workDir: string): string {
  const files = collectFiles(workDir);
  files.sort((a, b) => a.path.localeCompare(b.path));

  let totalChars = 0;
  const parts: string[] = [];

  for (const file of files) {
    const entry = `--- ${file.path} ---\n${file.content}\n`;
    if (totalChars + entry.length > MAX_TOTAL_CHARS) {
      parts.push(
        `\n[... truncated — ${files.length - parts.length} more files not shown ...]\n`,
      );
      break;
    }
    parts.push(entry);
    totalChars += entry.length;
  }

  return parts.join("\n");
}

export interface JudgeOptions {
  judgeModel?: string;
  minScore?: number;
}

export async function judgeSpecAdherence(
  spec: string,
  workDir: string,
  opts: JudgeOptions = {},
): Promise<JudgeResult> {
  const fileContext = buildFileContext(workDir);

  const prompt = `You are a strict technical reviewer. Evaluate whether a codebase implements a given specification.

## Specification

${spec}

## Generated Source Code

${fileContext}

## Instructions

1. Extract every distinct requirement from the specification.
2. For each, check whether the source code implements it.
3. Provide evidence (file path + brief reason) for each.
4. Give an overall adherence score from 1-10.
5. List any missing requirements.
6. Return verdict: "pass" if score >= 7, "fail" otherwise.

Respond ONLY with valid JSON matching this schema:
{
  "requirements": [{"requirement": "...", "implemented": true/false, "evidence": "..."}],
  "adherenceScore": 1-10,
  "missingRequirements": ["..."],
  "verdict": "pass" or "fail",
  "reasoning": "..."
}`;

  const result = await runEval(prompt, {
    model: opts.judgeModel ?? EVAL_MODEL,
    timeoutSec: 120,
  });

  const output = result.json.output.trim();
  const jsonMatch = output.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    throw new Error(`Judge did not return valid JSON:\n${output.slice(0, 1000)}`);
  }

  return JSON.parse(jsonMatch[0]) as JudgeResult;
}

export async function assertSpecAdherence(
  spec: string,
  workDir: string,
  opts: JudgeOptions = {},
): Promise<JudgeResult> {
  const { minScore = 7 } = opts;

  console.log("\n--- judge: spec adherence ---");
  console.log("  calling judge model...");

  const result = await judgeSpecAdherence(spec, workDir, opts);

  console.log(`  adherence score: ${result.adherenceScore}/10`);
  console.log(`  verdict: ${result.verdict}`);
  console.log(`  requirements checked: ${result.requirements.length}`);

  const implemented = result.requirements.filter((r) => r.implemented).length;
  const notImplemented = result.requirements.filter(
    (r) => !r.implemented,
  ).length;
  console.log(
    `  implemented: ${implemented}, not implemented: ${notImplemented}`,
  );

  if (result.missingRequirements.length > 0) {
    console.log("  missing:");
    for (const m of result.missingRequirements) {
      console.log(`    - ${m}`);
    }
  }

  console.log(`  reasoning: ${result.reasoning}`);
  console.log("--- end judge ---\n");

  expect(result.adherenceScore).toBeGreaterThanOrEqual(minScore);
  expect(result.verdict).toBe("pass");

  return result;
}
