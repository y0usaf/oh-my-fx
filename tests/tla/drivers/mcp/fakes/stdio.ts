
import { appendFileSync, existsSync, readFileSync, writeFileSync, writeSync } from "node:fs";

export interface Rule {
  /** JSON-RPC method to match. "*" matches any method. */
  method: string;
  /** Match only requests whose 2026 `_meta` protocol version is this; null matches none sent. */
  version?: string | null;
  /** Match only requests with this `cursor` param; null matches none sent. */
  cursor?: string | null;
  /** Match only tools/call requests for this tool (U12). */
  tool?: string;
  /** How many times the rule applies. Defaults to unlimited. */
  times?: number;
  /** Lines to write before the reply, for example notifications. */
  before?: unknown[];
  /** Reply: a result, an error, a raw line (for malformed output), or nothing. */
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
  raw?: string;
  noReply?: boolean;
  /** Wait before replying, in milliseconds. */
  delayMs?: number;
  /** Lines to write to stderr before the reply, `stderrRepeat` times (default 1). */
  stderr?: string[];
  stderrRepeat?: number;
  /** Write one stdout line of this many "x" bytes before the reply (an oversized line). */
  rawBytes?: number;
  /** After replying: "exit" closes cleanly with code 0, "crash" exits with code 1. */
  then?: "exit" | "crash";
}

const withId = <T>(value: T, id: unknown): T => JSON.parse(JSON.stringify(value).replaceAll('"$id"', JSON.stringify(id ?? null)));

interface Message {
  jsonrpc?: string;
  id?: string | number | null;
  method?: string;
  params?: unknown;
}

function main(): void {
  const args = process.argv.slice(2);
  const get = (flag: string) => {
    const index = args.indexOf(flag);
    return index >= 0 ? args[index + 1] : undefined;
  };
  const scriptPath = get("--script");
  if (!scriptPath) {
    process.stderr.write("usage: fakes/stdio.ts --script <rules.json> [--log <file>]\n");
    process.exit(2);
  }
  const exitAtStart = get("--exit-at-start");
  if (exitAtStart !== undefined) process.exit(Number(exitAtStart));
  const exitAfter = get("--exit-after");
  if (exitAfter !== undefined) setTimeout(() => process.exit(1), Number(exitAfter));
  const once = get("--once");
  const ends = once === undefined || !existsSync(once);
  const linger = args.includes("--linger");
  if (args.includes("--ignore-term")) process.on("SIGTERM", () => {});
  const rules = JSON.parse(readFileSync(scriptPath, "utf8")) as Rule[];
  const used = rules.map(() => 0);
  const logPath = get("--log");
  const log = (dir: "in" | "out", line: string) => {
    if (logPath) appendFileSync(logPath, JSON.stringify({ dir, t: Date.now(), line }) + "\n");
  };
  const send = (line: string) => {
    log("out", line);
    writeSync(1, line + "\n");
  };

  const banner = get("--banner");
  if (banner !== undefined) send(banner);

  let pending = "";
  const startDelay = Number(get("--start-delay") ?? 0);
  let queue: Promise<void> = startDelay > 0 ? Bun.sleep(startDelay) : Promise.resolve();

  const handle = async (line: string) => {
    log("in", line);
    let message: Message;
    try {
      message = JSON.parse(line) as Message;
    } catch {
      send(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }));
      return;
    }
    const isRequest = message.id !== undefined && message.id !== null && typeof message.method === "string";
    const params = message.params as { _meta?: Record<string, unknown>; cursor?: string; name?: string } | undefined;
    const version = params?._meta?.["io.modelcontextprotocol/protocolVersion"] ?? null;
    const cursor = params?.cursor ?? null;
    const index = rules.findIndex(
      (r, i) =>
        (r.method === "*" || r.method === message.method) &&
        (r.version === undefined || r.version === version) &&
        (r.cursor === undefined || r.cursor === cursor) &&
        (r.tool === undefined || r.tool === params?.name) &&
        (r.times === undefined || used[i] < r.times),
    );
    if (index < 0) {
      if (isRequest) send(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Method not found" } }));
      return;
    }
    used[index] += 1;
    const rule = rules[index];
    if (rule.delayMs) await Bun.sleep(rule.delayMs);
    for (let n = 0; n < (rule.stderrRepeat ?? 1); n++) {
      for (const line of rule.stderr ?? []) writeSync(2, line + "\n");
    }
    if (rule.rawBytes) send("x".repeat(rule.rawBytes));
    for (const extra of rule.before ?? []) send(JSON.stringify(withId(extra, message.id)));
    if (rule.raw !== undefined) send(rule.raw);
    else if (rule.error) send(JSON.stringify({ jsonrpc: "2.0", id: message.id ?? null, error: rule.error }));
    else if (!rule.noReply && (isRequest || rule.result !== undefined)) {
      send(JSON.stringify({ jsonrpc: "2.0", id: message.id ?? null, result: withId(rule.result ?? {}, message.id) }));
    }
    if (rule.then !== undefined && ends && once !== undefined) writeFileSync(once, "");
    if (rule.then === "exit" && ends) process.exit(0);
    if (rule.then === "crash" && ends) process.exit(1);
  };

  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk: string) => {
    pending += chunk;
    let newline: number;
    while ((newline = pending.indexOf("\n")) >= 0) {
      const line = pending.slice(0, newline).replace(/\r$/, "");
      pending = pending.slice(newline + 1);
      if (line.length > 0) queue = queue.then(() => handle(line));
    }
  });
  process.stdin.on("end", () => {
    if (linger) setInterval(() => {}, 1000);
    else queue.then(() => process.exit(0));
  });
}

if (import.meta.main) main();
