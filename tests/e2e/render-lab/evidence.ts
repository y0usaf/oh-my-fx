import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { RenderLabFrame, RenderLabManifest } from "./types";

export const STABLE_SAMPLES = 3;
export const MAX_SETTLE_MS = 1_200;
const SAMPLE_INTERVAL_MS = 120;

export type StableProbe = {
  stable: boolean;
  samples: number;
  durationMs: number;
};

export function runtimeEvidenceDefaults(): RenderLabManifest["evidence"] {
  return {
    oracle: "byte replay plus terminal-owned text/grid capture",
    capturePolicy: "capture only at scenario event boundaries, after bounded visible-state settling",
    screenshotPolicy: "screenshots are optional human evidence, never the pass/fail oracle",
    maxSettleMs: MAX_SETTLE_MS,
    stableSamples: STABLE_SAMPLES,
  };
}

export async function waitForStableProbe(probe: () => string): Promise<StableProbe> {
  const started = Date.now();
  let samples = 0;
  let stableRun = 0;
  let previousHash: string | null = null;

  while (Date.now() - started <= MAX_SETTLE_MS) {
    const hash = sha256Text(probe());
    samples += 1;
    if (hash === previousHash) {
      stableRun += 1;
    } else {
      stableRun = 1;
      previousHash = hash;
    }
    if (stableRun >= STABLE_SAMPLES) {
      return {
        stable: true,
        samples,
        durationMs: Date.now() - started,
      };
    }
    await sleep(SAMPLE_INTERVAL_MS);
  }

  return {
    stable: false,
    samples,
    durationMs: Date.now() - started,
  };
}

export function attachFrameEvidence(
  frame: RenderLabFrame,
  captureSource: string,
  probe: StableProbe,
): RenderLabFrame {
  return {
    ...frame,
    evidence: {
      captureSource,
      capturePolicy: "event-boundary-settled",
      stable: probe.stable,
      samples: probe.samples,
      durationMs: probe.durationMs,
      gridSha256: sha256Text(frame.grid.join("\n")),
      scrollbackSha256: sha256Text(frame.scrollback),
      traceTailSha256: sha256Text(frame.traceTail.join("\n")),
    },
  };
}

export function writeRuntimeEvidence(manifest: RenderLabManifest): void {
  const runtimeEvidencePath = manifest.runtimeEvidencePath ?? join(manifest.artifactDir, "runtime-evidence.json");
  const frames = manifest.frames.map((frame) => {
    const data = JSON.parse(readFileSync(join(manifest.artifactDir, frame.jsonPath), "utf8")) as RenderLabFrame;
    return {
      index: data.index,
      event: data.event,
      width: data.width,
      height: data.height,
      evidence: data.evidence ?? null,
    };
  });
  writeFileSync(
    runtimeEvidencePath,
    `${JSON.stringify(
      {
        version: 1,
        scenario: manifest.scenario,
        runId: manifest.runId,
        oracle: manifest.evidence,
        frames,
      },
      null,
      2,
    )}\n`,
  );
}

export function sha256Text(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
