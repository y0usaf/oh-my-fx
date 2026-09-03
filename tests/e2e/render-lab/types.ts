export type CursorPosition = {
  row: number;
  col: number;
};

export type RenderLabFrame = {
  index: number;
  event: string;
  timestampMs: number;
  width: number;
  height: number;
  binaryPath: string;
  binarySha256: string;
  grid: string[];
  escapes: string;
  scrollback: string;
  cursor: CursorPosition | null;
  traceTail: string[];
  evidence?: RenderLabFrameEvidence;
};

export type RenderLabFrameEvidence = {
  captureSource: string;
  capturePolicy: "event-boundary-settled";
  stable: boolean;
  samples: number;
  durationMs: number;
  gridSha256: string;
  scrollbackSha256: string;
  traceTailSha256: string;
};

export type RenderLabFrameManifest = {
  index: number;
  event: string;
  timestampMs: number;
  width: number;
  height: number;
  gridPath: string;
  jsonPath: string;
};

export type RenderLabFailure = {
  invariant: string;
  frameIndex: number;
  event: string;
  message: string;
};

export type RenderLabTerminalSize = {
  cols: number;
  rows: number;
};

export type RenderLabTimingStats = {
  samples: number;
  p50Ms: number;
  p95Ms: number;
  p99Ms: number;
  minMs: number;
  maxMs: number;
};

export type RenderLabNumericStats = {
  samples: number;
  p50: number;
  p95: number;
  p99: number;
  min: number;
  max: number;
};

export type RenderLabBenchmarkPhase =
  | "plan"
  | "surfaceInit"
  | "paint"
  | "validate"
  | "diff"
  | "combined";

export type RenderLabBenchmarkAllocations = {
  instrumentation: "unavailable";
  reason: string;
  phases: Record<Exclude<RenderLabBenchmarkPhase, "combined">, null>;
  oneTimeSetup: {
    estimatedCellSlots: number;
    estimatedBytes: number;
  };
  hotFrame: {
    recurringRowsByColsAllocationMeasured: boolean;
    note: string;
  };
};

export type RenderLabBenchmarkSizeResult = {
  terminalSize: RenderLabTerminalSize;
  runs: number;
  invalidationReasons: string[];
  changedCells: RenderLabNumericStats;
  diffBytes: RenderLabNumericStats;
  fullRepaintCount: number;
  timings: Record<RenderLabBenchmarkPhase, RenderLabTimingStats>;
  allocations: RenderLabBenchmarkAllocations;
};

export type RenderLabBenchmark = {
  version: 1;
  scenario: string;
  generatedAt: string;
  benchmarkPath: string;
  threshold: {
    terminalSize: RenderLabTerminalSize;
    phase: "combined";
    percentile: "p95Ms";
    maxMs: number;
    passed: boolean;
    actualMs: number | null;
  };
  sizes: RenderLabBenchmarkSizeResult[];
};

export type RenderLabManifest = {
  version: 1;
  scenario: string;
  runId: string;
  startedAt: string;
  completedAt: string | null;
  repoRoot: string;
  artifactDir: string;
  binaryPath: string;
  binarySha256: string;
  traceLogPath: string;
  tapePath: string;
  finalGridPath: string;
  replaySummaryPath: string;
  runtimeEvidencePath: string;
  reportPath: string;
  failurePath: string;
  finalFrameIndex: number | null;
  evidence: {
    oracle: string;
    capturePolicy: string;
    screenshotPolicy: string;
    maxSettleMs: number;
    stableSamples: number;
  };
  markers: {
    shell: string[];
    clearedShell?: string[];
    submitted: string[];
    history?: string[];
  };
  native?: {
    adapter: string;
    appName: string;
    termProgram: string;
    capture: string;
    commandK: boolean;
    notes: string[];
  };
  benchmark?: RenderLabBenchmark;
  frames: RenderLabFrameManifest[];
  failures: RenderLabFailure[];
};

export type AnalyzerResult = {
  failures: RenderLabFailure[];
};
