#!/usr/bin/env bun
/**
 * Generates src/gateway/provider_catalogs_generated_data.zig: the static
 * per-provider model catalog fallback for every fx ProviderId row.
 *
 * Pipeline (mirrors oh-my-pi packages/ai/scripts/generate-models.ts):
 *   1. Fetch https://models.dev/api.json — primary source for nearly all rows.
 *   2. Merge live vendor listings only where rich metadata matters:
 *      - https://openrouter.ai/api/v1/models over the models.dev `openrouter`
 *        row (live context_length / architecture / supported_parameters win).
 *      - https://integrate.api.nvidia.com/v1/models as an intersection filter
 *        for the NVIDIA NIM row, minus a known-unsupported allowlist.
 *   3. Hardcode ONLY what models.dev lacks, sourced from pi's generator:
 *      ant_ling (3), codex (4), plus small add-if-absent supplement lists.
 *   4. Emit one Zig row per fx ProviderId in enum order, ids sorted
 *      lexicographically for deterministic output.
 *
 * Conservative capability mapping from models.dev entries:
 *   has_tool_use = tool_call === true          (explicit data or false)
 *   has_reasoning = reasoning === true
 *   has_vision / has_file_input = modalities.input image / pdf
 *   context_window / max_tokens = limit.context / limit.output else 0 (=unknown)
 *   Non-text-output models are skipped.
 *
 * Offline fallback: when the network is unreachable, the script reuses the last
 * successful fetch cached in the OS temp dir as fx-provider-models-cache.json
 * (written on every successful run) so output stays deterministic between runs.
 * Pass --api-json <path> to pin a snapshot explicitly. Live vendor listings are
 * best-effort in both modes: failures degrade to the models.dev row instead of
 * failing the run.
 *
 * Exits nonzero if any provider row would end up empty.
 */

import { writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_PATH = join(__dirname, "..", "src", "gateway", "provider_catalogs_generated_data.zig");
const CACHE_PATH = join(tmpdir(), "fx-provider-models-cache.json");
const MODELS_DEV_URL = "https://models.dev/api.json";
const OPENROUTER_MODELS_URL = "https://openrouter.ai/api/v1/models";
const NVIDIA_NIM_MODELS_URL = "https://integrate.api.nvidia.com/v1/models";

/** fx ProviderId variants in declaration order; rows emit in this order. */
const FX_PROVIDERS = [
	"gateway",
	"codex",
	"grok",
	"openrouter",
	"anthropic",
	"openai",
	"xai",
	"deepseek",
	"google",
	"google_vertex",
	"azure_openai",
	"bedrock",
	"github_copilot",
	"nvidia",
	"groq",
	"cerebras",
	"mistral",
	"minimax",
	"minimax_cn",
	"moonshotai",
	"moonshotai_cn",
	"zai",
	"zai_coding_cn",
	"huggingface",
	"fireworks",
	"together",
	"opencode",
	"opencode_go",
	"kimi_coding",
	"ant_ling",
	"cloudflare_workers_ai",
	"cloudflare_ai_gateway",
	"xiaomi",
	"xiaomi_token_plan_cn",
	"xiaomi_token_plan_ams",
	"xiaomi_token_plan_sgp",
];

interface ModelsDevModel {
	id?: string;
	name?: string;
	tool_call?: boolean;
	reasoning?: boolean;
	release_date?: string;
	modalities?: { input?: string[]; output?: string[] };
	limit?: { context?: number; output?: number };
	experimental?: { modes?: Record<string, unknown> };
	status?: string;
}

interface OpenRouterModel {
	id: string;
	context_length?: number;
	architecture?: { input_modalities?: string[]; output_modalities?: string[] };
	supported_parameters?: string[];
}

interface CatalogEntry {
	id: string;
	released: number;
	has_tool_use: boolean;
	has_reasoning: boolean;
	supports_fast_mode: boolean;
	has_vision: boolean;
	has_file_input: boolean;
	context_window: number;
	max_tokens: number;
}

/** Hardcoded arrays for providers models.dev does not list (from pi's generator). */
const ANT_LING_MODELS: CatalogEntry[] = [
	entry("Ling-2.6-flash", { context_window: 262144, max_tokens: 65536 }),
	entry("Ling-2.6-1T", { context_window: 262144, max_tokens: 65536 }),
	entry("Ring-2.6-1T", { context_window: 262144, max_tokens: 65536, has_reasoning: true }),
];

const CODEX_MODELS: CatalogEntry[] = [
	entry("gpt-5.3-codex-spark", { context_window: 128000, max_tokens: 128000, has_reasoning: true }),
	entry("gpt-5.4", { context_window: 272000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
	entry("gpt-5.4-mini", { context_window: 272000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
	entry("gpt-5.5", { context_window: 272000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
];

/** Add-if-absent supplements sourced from pi's generator until upstream settles. */
const SUPPLEMENTS: Record<string, CatalogEntry[]> = {
	anthropic: [
		entry("claude-opus-4-6", { context_window: 1000000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
		entry("claude-opus-4-7", { context_window: 1000000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
		entry("claude-opus-4-8", { context_window: 1000000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
		entry("claude-sonnet-4-6", { context_window: 1000000, max_tokens: 64000, has_reasoning: true, has_vision: true }),
	],
	bedrock: [
		entry("eu.anthropic.claude-opus-4-6-v1", { context_window: 200000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
	],
	google: [
		entry("gemini-3.1-flash-lite-preview", { context_window: 1048576, max_tokens: 65536, has_reasoning: true, has_vision: true }),
	],
	openai: [
		entry("gpt-5-chat-latest", { context_window: 128000, max_tokens: 16384, has_vision: true }),
		entry("gpt-5.1-codex", { context_window: 400000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
		entry("gpt-5.1-codex-max", { context_window: 400000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
		entry("gpt-5.3-codex-spark", { context_window: 128000, max_tokens: 16384, has_reasoning: true }),
		entry("gpt-5.4", { context_window: 272000, max_tokens: 128000, has_reasoning: true, has_vision: true }),
	],
	xai: [
		entry("grok-3", { context_window: 131072, max_tokens: 8192 }),
		entry("grok-3-fast", { context_window: 131072, max_tokens: 8192 }),
		entry("grok-code-fast-1", { context_window: 32768, max_tokens: 8192 }),
	],
	mistral: [
		entry("mistral-medium-3.5", { context_window: 262144, max_tokens: 262144, has_reasoning: true, has_vision: true }),
	],
	openrouter: [
		entry("auto", { context_window: 2000000, max_tokens: 30000, has_reasoning: true, has_vision: true }),
	],
};

const MINIMAX_DIRECT_SUPPORTED_IDS = new Set(["MiniMax-M2.7", "MiniMax-M2.7-highspeed", "MiniMax-M3"]);

/** Live NVIDIA NIM endpoints that must not appear in the generated row. */
const NVIDIA_NIM_UNSUPPORTED_MODELS = new Set([
	"abacusai/dracarys-llama-3.1-70b-instruct",
	"bytedance/seed-oss-36b-instruct",
	"deepseek-ai/deepseek-v4-flash",
	"deepseek-ai/deepseek-v4-pro",
	"google/gemma-2-2b-it",
	"google/gemma-3n-e2b-it",
	"google/gemma-3n-e4b-it",
	"google/gemma-4-31b-it",
	"meta/llama-3.2-1b-instruct",
	"meta/llama-4-maverick-17b-128e-instruct",
	"microsoft/phi-4-mini-instruct",
	"minimaxai/minimax-m2.7",
	"mistralai/mistral-nemotron",
	"nvidia/nemotron-mini-4b-instruct",
	"qwen/qwen3-next-80b-a3b-instruct",
	"qwen/qwen3.5-397b-a17b",
	"sarvamai/sarvam-m",
	"upstage/solar-10.7b-instruct",
]);

function entry(id: string, fields: Partial<CatalogEntry>): CatalogEntry {
	return {
		id,
		released: 0,
		has_tool_use: false,
		has_reasoning: false,
		supports_fast_mode: false,
		has_vision: false,
		has_file_input: false,
		context_window: 0,
		max_tokens: 0,
		...fields,
	};
}

function boundedU32(value: number | undefined): number {
	if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return 0;
	if (value > 0xffffffff) return 0;
	return Math.trunc(value);
}

function releaseEpoch(date: string | undefined): number {
	if (!date) return 0;
	const parsed = Date.parse(`${date}T00:00:00Z`);
	return Number.isNaN(parsed) ? 0 : Math.trunc(parsed / 1000);
}

function textOutput(m: ModelsDevModel): boolean {
	const output = m.modalities?.output;
	return output == null || output.includes("text");
}

function entryFromModelsDev(id: string, m: ModelsDevModel): CatalogEntry | null {
	if (!textOutput(m)) return null;
	const input = m.modalities?.input ?? [];
	return entry(id, {
		released: releaseEpoch(m.release_date),
		has_tool_use: m.tool_call === true,
		has_reasoning: m.reasoning === true,
		supports_fast_mode: m.experimental?.modes?.fast != null,
		has_vision: input.includes("image"),
		has_file_input: input.includes("pdf"),
		context_window: boundedU32(m.limit?.context),
		max_tokens: boundedU32(m.limit?.output),
	});
}

function entryFromOpenRouter(m: OpenRouterModel): CatalogEntry | null {
	const id = typeof m.id === "string" ? m.id : "";
	if (id.length === 0) return null;
	const output = m.architecture?.output_modalities;
	if (output != null && !output.includes("text")) return null;
	const input = m.architecture?.input_modalities ?? [];
	const params = m.supported_parameters ?? [];
	return entry(id, {
		has_tool_use: params.some((p) => p.toLowerCase() === "tools"),
		has_reasoning: params.some((p) => p.toLowerCase() === "reasoning"),
		has_vision: input.some((p) => p.toLowerCase() === "image"),
		context_window: boundedU32(m.context_length),
	});
}

function modelsDevRow(data: Record<string, { models?: Record<string, ModelsDevModel> }>, key: string): CatalogEntry[] {
	const models = data[key]?.models;
	if (models == null) return [];
	const out: CatalogEntry[] = [];
	for (const [id, m] of Object.entries(models)) out.push(entryFromModelsDev(id, m));
	return out.filter((e): e is CatalogEntry => e != null);
}

/** Merges candidates into target by id (first writer wins). */
function mergeById(target: Map<string, CatalogEntry>, candidates: CatalogEntry[], override = false): void {
	for (const candidate of candidates) {
		if (!override && target.has(candidate.id)) continue;
		target.set(candidate.id, candidate);
	}
}

async function fetchJson<T>(url: string): Promise<T | null> {
	try {
		const response = await fetch(url, { signal: AbortSignal.timeout(60_000) });
		if (!response.ok) throw new Error(`HTTP ${response.status}`);
		return (await response.json()) as T;
	} catch (error) {
		console.error(`fetch failed (${url}): ${error instanceof Error ? error.message : error}`);
		return null;
	}
}

async function loadModelsDev(): Promise<Record<string, { models?: Record<string, ModelsDevModel> }>> {
	const pinIndex = process.argv.indexOf("--api-json");
	if (pinIndex >= 0) {
		const path = process.argv[pinIndex + 1];
		if (path == null) throw new Error("--api-json requires a path");
		console.log(`Using pinned models.dev snapshot ${path}`);
		return await Bun.file(path).json();
	}
	const fetched = await fetchJson<Record<string, { models?: Record<string, ModelsDevModel> }>>(MODELS_DEV_URL);
	if (fetched != null) {
		writeFileSync(CACHE_PATH, JSON.stringify(fetched));
		return fetched;
	}
	if (existsSync(CACHE_PATH)) {
		console.log(`Network unavailable; falling back to cached snapshot ${CACHE_PATH}`);
		return await Bun.file(CACHE_PATH).json();
	}
	throw new Error("models.dev unreachable and no cached snapshot exists");
}

function normalizeNvidiaModelId(modelId: string): string {
	return modelId.toLowerCase().replaceAll("_", ".");
}

async function main(): Promise<void> {
	const data = await loadModelsDev();

	// Live OpenRouter listing: richer metadata than models.dev; overlay wins.
	const openRouterLive = await fetchJson<{ data?: OpenRouterModel[] }>(OPENROUTER_MODELS_URL);

	// Live NVIDIA NIM listing: intersection filter over the models.dev nvidia row.
	interface NimListResponse {
		data?: Array<{ id: string }>;
	}
	const nimLive = await fetchJson<NimListResponse>(NVIDIA_NIM_MODELS_URL);
	const nimIds = new Map<string, string>();
	for (const item of nimLive?.data ?? []) {
		nimIds.set(item.id, item.id);
		nimIds.set(normalizeNvidiaModelId(item.id), item.id);
	}

	const rows: Array<[string, Map<string, CatalogEntry>]> = [];
	function row(provider: string): Map<string, CatalogEntry> {
		const map = new Map<string, CatalogEntry>();
		rows.push([provider, map]);
		return map;
	}

	// gateway: Vercel AI Gateway catalog from models.dev.
	mergeById(row("gateway"), modelsDevRow(data, "vercel"));

	// codex: hardcoded; ChatGPT OAuth models are not on models.dev.
	mergeById(row("codex"), CODEX_MODELS);

	// grok: subscription tier shares api.x.ai with xai; take its grok-* chat models.
	const grok = row("grok");
	mergeById(
		grok,
		modelsDevRow(data, "xai").filter((m) => m.id.startsWith("grok-")),
	);

	// openrouter: models.dev base overlaid with the live /models listing.
	const openrouter = row("openrouter");
	mergeById(openrouter, modelsDevRow(data, "openrouter"));
	{
		const live = (openRouterLive?.data ?? []).map(entryFromOpenRouter).filter((e): e is CatalogEntry => e != null);
		mergeById(openrouter, live, true);
	}

	// Straight models.dev rows.
	mergeById(row("anthropic"), modelsDevRow(data, "anthropic"));
	mergeById(row("openai"), modelsDevRow(data, "openai"));
	mergeById(row("xai"), modelsDevRow(data, "xai"));
	mergeById(row("deepseek"), modelsDevRow(data, "deepseek"));
	mergeById(row("google"), modelsDevRow(data, "google"));
	mergeById(row("google_vertex"), modelsDevRow(data, "google-vertex"));
	mergeById(row("github_copilot"), modelsDevRow(data, "github-copilot"));
	mergeById(row("groq"), modelsDevRow(data, "groq"));
	mergeById(row("cerebras"), modelsDevRow(data, "cerebras"));
	mergeById(row("mistral"), modelsDevRow(data, "mistral"));
	mergeById(row("moonshotai"), modelsDevRow(data, "moonshotai"));
	mergeById(row("moonshotai_cn"), modelsDevRow(data, "moonshotai-cn"));
	mergeById(row("huggingface"), modelsDevRow(data, "huggingface"));
	mergeById(row("fireworks"), modelsDevRow(data, "fireworks-ai"));
	mergeById(row("together"), modelsDevRow(data, "togetherai"));
	mergeById(
		row("opencode"),
		modelsDevRow(data, "opencode").filter((m) => m.id !== "gpt-5.3-codex-spark"),
	);
	mergeById(
		row("opencode_go"),
		modelsDevRow(data, "opencode-go").filter((m) => m.id !== "gpt-5.3-codex-spark"),
	);
	mergeById(row("cloudflare_workers_ai"), modelsDevRow(data, "cloudflare-workers-ai"));
	mergeById(row("cloudflare_ai_gateway"), modelsDevRow(data, "cloudflare-ai-gateway"));
	mergeById(row("bedrock"), modelsDevRow(data, "amazon-bedrock"));

	// kimi_coding: normalize versioned aliases onto the canonical id.
	const kimiModels = data["kimi-for-coding"]?.models ?? {};
	const kimiHasCanonical = Object.prototype.hasOwnProperty.call(kimiModels, "kimi-for-coding");
	mergeById(
		row("kimi_coding"),
		modelsDevRow(data, "kimi-for-coding")
			.map((m) => (kimiHasCanonical && (m.id === "k2p5" || m.id === "k2p6") ? entry("kimi-for-coding", { ...m }) : m))
			.filter((m, index, all) => all.findIndex((other) => other.id === m.id) === index),
	);

	// ant_ling: hardcoded; models.dev has no key yet.
	mergeById(row("ant_ling"), ANT_LING_MODELS);

	// nvidia: models.dev intersected with the live NIM listing minus unsupported ids.
	const nvidia = row("nvidia");
	for (const m of modelsDevRow(data, "nvidia")) {
		if (!m.has_tool_use) continue;
		const liveId = nimIds.get(m.id) ?? nimIds.get(normalizeNvidiaModelId(m.id));
		if (liveId == null) continue;
		if (NVIDIA_NIM_UNSUPPORTED_MODELS.has(liveId)) continue;
		nvidia.set(liveId, m);
	}

	// minimax pair: direct-API allowlist.
	for (const [fxProvider, key] of [
		["minimax", "minimax"],
		["minimax_cn", "minimax-cn"],
	] as const) {
		mergeById(
			row(fxProvider),
			modelsDevRow(data, key).filter((m) => MINIMAX_DIRECT_SUPPORTED_IDS.has(m.id)),
		);
	}

	// zai pair: shared coding-plan catalog.
	for (const fxProvider of ["zai", "zai_coding_cn"]) {
		mergeById(row(fxProvider), modelsDevRow(data, "zai-coding-plan"));
	}

	// xiaomi family: shared catalog; token plans exclude the flash variant.
	for (const fxProvider of ["xiaomi", "xiaomi_token_plan_cn", "xiaomi_token_plan_ams", "xiaomi_token_plan_sgp"]) {
		mergeById(
			row(fxProvider),
			modelsDevRow(data, "xiaomi").filter((m) => fxProvider === "xiaomi" || m.id !== "mimo-v2-flash"),
		);
	}

	// Add-if-absent supplements (azure clones inherit them via openai row below).
	for (const [provider, supplement] of Object.entries(SUPPLEMENTS)) {
		const target = rows.find(([name]) => name === provider)?.[1];
		if (target == null) throw new Error(`supplement targets unknown provider ${provider}`);
		mergeById(target, supplement);
	}

	// azure_openai clones the settled openai row.
	mergeById(
		row("azure_openai"),
		[...(rows.find(([name]) => name === "openai")?.[1].values() ?? [])],
	);

	const emptyRows: string[] = [];
	const sorted = new Map<string, CatalogEntry[]>();
	for (const [provider, map] of rows) {
		const entries = [...map.values()].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
		if (entries.length === 0) emptyRows.push(provider);
		sorted.set(provider, entries);
	}

	if (emptyRows.length > 0) {
		console.error(`EMPTY provider rows (refusing to emit): ${emptyRows.join(", ")}`);
		process.exit(1);
	}

	writeFileSync(OUT_PATH, renderZig(sorted));
	console.log(`Wrote ${OUT_PATH}`);
	let total = 0;
	for (const provider of FX_PROVIDERS) {
		const count = sorted.get(provider)?.length ?? 0;
		total += count;
		console.log(`  ${provider}: ${count} models`);
	}
	console.log(`  total: ${total} models`);
}

function zigString(value: string): string {
	let out = '"';
	for (const ch of value) {
		if (ch === "\\") out += "\\\\";
		else if (ch === '"') out += '\\"';
		else if (ch === "\n") out += "\\n";
		else if (ch === "\r") out += "\\r";
		else if (ch === "\t") out += "\\t";
		else out += ch;
	}
	return `${out}"`;
}

function renderZig(rows: Map<string, CatalogEntry[]>): string {
	const lines: string[] = [];
	lines.push("//! Generated by scripts/generate_provider_models.ts. DO NOT EDIT.");
	lines.push("//! Sources: https://models.dev/api.json, live OpenRouter and NVIDIA NIM");
	lines.push("//! listings, plus hardcoded arrays for catalogs models.dev lacks.");
	lines.push("");
	lines.push("/// Static catalog entry mirroring ModelCatalogEntry; `id` aliases");
	lines.push("/// comptime rodata, so runtime copies must dup before handing ownership");
	lines.push("/// to freeModelCatalog.");
	lines.push("pub const Entry = struct {");
	lines.push("    id: []const u8,");
	lines.push("    released: i64 = 0,");
	lines.push("    has_tool_use: bool = false,");
	lines.push("    has_reasoning: bool = false,");
	lines.push("    supports_fast_mode: bool = false,");
	lines.push("    has_vision: bool = false,");
	lines.push("    has_file_input: bool = false,");
	lines.push("    context_window: u32 = 0,");
	lines.push("    max_tokens: u32 = 0,");
	lines.push("};");
	lines.push("");
	lines.push("/// Row names in emit order; provider_catalogs.zig asserts at comptime");
	lines.push("/// that these match @tagName of every fx ProviderId variant.");
	lines.push("pub const provider_names: [36][]const u8 = .{");
	for (const provider of FX_PROVIDERS) lines.push(`    ${zigString(provider)},`);
	lines.push("};");
	lines.push("");
	lines.push("/// Indexed by @intFromEnum(model_provider.ProviderId).");
	lines.push(`pub const entries: [${FX_PROVIDERS.length}][]const Entry = .{`);
	for (const provider of FX_PROVIDERS) {
		const entries = rows.get(provider) ?? [];
		lines.push(`    // ${provider} (${entries.length})`);
		lines.push("    &.{");
		for (const m of entries) {
			const fields = [
				`.id = ${zigString(m.id)}`,
				`.released = ${m.released}`,
				`.has_tool_use = ${m.has_tool_use}`,
				`.has_reasoning = ${m.has_reasoning}`,
				`.supports_fast_mode = ${m.supports_fast_mode}`,
				`.has_vision = ${m.has_vision}`,
				`.has_file_input = ${m.has_file_input}`,
				`.context_window = ${m.context_window}`,
				`.max_tokens = ${m.max_tokens}`,
			];
			lines.push(`        .{ ${fields.join(", ")} },`);
		}
		lines.push("    },");
	}
	lines.push("};");
	return `${lines.join("\n")}\n`;
}

await main();
