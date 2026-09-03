//! Background workspace file index for the @-mention picker.
//!
//! Each generation owns immutable parallel buffers. The loader publishes complete
//! prefixes with release stores; readers acquire `ready_count` before scanning.
//! Replacement generations remain private until the main thread adopts them.
//! Search uses pre-lowercased paths and a per-path ASCII bitmap to reject
//! impossible subsequence matches before scoring.

const std = @import("std");
const file_picker_path = @import("../input/file_picker_path.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const display_width = @import("../shared/display_width.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const unicode_simple_fold = @import("unicode_simple_fold.zig");
const pathing = @import("pathing.zig");
const workspace_access = @import("workspace_access.zig");
const workspace_files = @import("workspace_files.zig");

const Allocator = std.mem.Allocator;

pub const max_indexed_files: usize = 100_000;
pub const max_path_len: u32 = 2048;

pub const CandidateKind = enum(u8) {
    file,
    directory,
};

pub const Candidate = struct {
    path: []const u8,
    kind: CandidateKind,
};

pub const MatchSpan = struct {
    byte_start: u16,
    byte_end: u16,
};

pub const SearchResult = struct {
    path: []const u8,
    kind: CandidateKind,
    matched_spans: []const MatchSpan,
};

pub const SearchError = error{ NoSpaceLeft, InvalidIndexData };

pub const State = enum(u8) {
    idle = 0,
    loading = 1,
    ready = 2,
    failed = 3,
};

const GenerationState = enum(u8) {
    loading,
    ready,
    failed,
    canceled,
};

const LoaderFailureStage = enum {
    discovery,
    storage,
};

const LoaderFailure = struct {
    stage: LoaderFailureStage,
    err: anyerror,
};

const LoaderOutcome = union(enum) {
    ready,
    failed: LoaderFailure,
    canceled,

    fn terminalState(self: LoaderOutcome) GenerationState {
        return switch (self) {
            .ready => .ready,
            .failed => .failed,
            .canceled => .canceled,
        };
    }
};

const Generation = struct {
    id: usize,
    paths_buf: []u8 = &.{},
    lower_buf: []u8 = &.{},
    offsets: []u32 = &.{},
    basename_starts: []u32 = &.{},
    kinds: []CandidateKind = &.{},
    /// One `u32` per path; bit `n` is set iff the lower-cased path contains
    /// the letter `'a' + n`. Used as an O(1) reject: a query mask can only
    /// match if `(path_mask & query_mask) == query_mask`, since every letter
    /// in the query must appear somewhere in the path for a subsequence match.
    char_masks: []u32 = &.{},
    /// Presence bitmap for lowered bytes 0x20..0x3f (space, punctuation,
    /// digits). Companion to `char_masks`: lets the search reject entries
    /// missing a non-letter query byte without scanning. Bits only exist
    /// for 0x20..0x3f, so an uncovered byte imposes no constraint.
    punct_masks: []u32 = &.{},
    /// The loader publishes an immutable prefix with release stores after
    /// every parallel-buffer entry is complete. Search pairs this with an
    /// acquire load before reading that prefix.
    ready_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// A release store publishes the terminal outcome after all generation
    /// writes. The main thread performs an acquire load before deciding
    /// whether joining and adoption are permitted.
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(GenerationState.loading)),

    fn create(alloc: Allocator, id: usize) !*Generation {
        const generation = try alloc.create(Generation);
        generation.* = .{ .id = id };
        return generation;
    }

    fn destroy(self: *Generation, alloc: Allocator) void {
        self.freeBuffers(alloc);
        alloc.destroy(self);
    }

    fn currentState(self: *const Generation) GenerationState {
        return @enumFromInt(self.state.load(.acquire));
    }

    fn finish(self: *Generation, state: GenerationState) void {
        self.state.store(@intFromEnum(state), .release);
    }

    fn count(self: *const Generation) usize {
        return self.ready_count.load(.acquire);
    }

    fn pathAt(self: *const Generation, index: usize) []const u8 {
        const start = self.offsets[index];
        const end = self.offsets[index + 1];
        return self.paths_buf[start..end];
    }

    fn kindAt(self: *const Generation, index: usize) CandidateKind {
        return self.kinds[index];
    }

    fn lowerPathAt(self: *const Generation, index: u32) []const u8 {
        const start = self.offsets[index];
        const end = self.offsets[index + 1];
        return self.lower_buf[start..end];
    }

    /// Allocates this generation's complete storage before publishing any
    /// entry. Cancellation retains the published prefix until the main thread
    /// discards the generation after its loader reaches a terminal state.
    fn fillProgressive(
        self: *Generation,
        alloc: Allocator,
        source: CandidateSource,
        stop_requested: ?*std.atomic.Value(bool),
    ) !void {
        if (isStopRequested(stop_requested)) return error.Canceled;

        const totals = countAndSize(source);

        try self.allocateBuffers(alloc, totals);
        if (totals.n == 0) return;

        self.offsets[0] = 0;

        var iterator = source.iterator();
        var candidate_index: u32 = 0;
        var buffer_position: u32 = 0;
        while (iterator.next()) |candidate| {
            if (isStopRequested(stop_requested)) return error.Canceled;
            if (candidate_index >= totals.n) break;
            const accepted = acceptedCandidate(candidate) orelse continue;
            const path = accepted.path;

            const start = buffer_position;
            const len: u32 = @intCast(path.len);
            @memcpy(self.paths_buf[start .. start + len], path);

            var mask: u32 = 0;
            var punct_mask: u32 = 0;
            var contains_non_ascii = false;
            for (path, 0..) |byte, byte_index| {
                const lower = asciiToLower(byte);
                self.lower_buf[start + @as(u32, @intCast(byte_index))] = lower;
                if (byte >= 0x80) contains_non_ascii = true;
                if (lower >= 'a' and lower <= 'z') {
                    mask |= @as(u32, 1) << @intCast(lower - 'a');
                }
                if (lower >= 0x20 and lower <= 0x3f) {
                    punct_mask |= @as(u32, 1) << @intCast(lower - 0x20);
                }
            }

            const slash = std.mem.findScalarLast(u8, path, '/');
            self.basename_starts[candidate_index] = if (slash) |index|
                start + @as(u32, @intCast(index + 1))
            else
                start;
            if (contains_non_ascii) mask |= non_ascii_mask;
            self.char_masks[candidate_index] = mask;
            self.punct_masks[candidate_index] = punct_mask;
            self.kinds[candidate_index] = accepted.kind;
            buffer_position += len;
            self.offsets[candidate_index + 1] = buffer_position;

            self.ready_count.store(candidate_index + 1, .release);
            candidate_index += 1;
        }

        if (isStopRequested(stop_requested)) return error.Canceled;
    }

    /// Transfers complete parallel-buffer ownership only after every
    /// allocation succeeds. Later population failure leaves cleanup with the
    /// generation rather than the allocation errdefers in this scope.
    fn allocateBuffers(self: *Generation, alloc: Allocator, totals: RawTotals) !void {
        const paths_buf = try alloc.alloc(u8, totals.bytes);
        errdefer alloc.free(paths_buf);
        const lower_buf = try alloc.alloc(u8, totals.bytes);
        errdefer alloc.free(lower_buf);
        const offsets = try alloc.alloc(u32, totals.n + 1);
        errdefer alloc.free(offsets);
        const basename_starts = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(basename_starts);
        const char_masks = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(char_masks);
        const punct_masks = try alloc.alloc(u32, totals.n);
        errdefer alloc.free(punct_masks);
        const kinds = try alloc.alloc(CandidateKind, totals.n);
        errdefer alloc.free(kinds);

        self.paths_buf = paths_buf;
        self.lower_buf = lower_buf;
        self.offsets = offsets;
        self.basename_starts = basename_starts;
        self.char_masks = char_masks;
        self.punct_masks = punct_masks;
        self.kinds = kinds;
    }

    fn freeBuffers(self: *Generation, alloc: Allocator) void {
        if (self.paths_buf.len > 0) alloc.free(self.paths_buf);
        if (self.lower_buf.len > 0) alloc.free(self.lower_buf);
        if (self.offsets.len > 0) alloc.free(self.offsets);
        if (self.basename_starts.len > 0) alloc.free(self.basename_starts);
        if (self.char_masks.len > 0) alloc.free(self.char_masks);
        if (self.punct_masks.len > 0) alloc.free(self.punct_masks);
        if (self.kinds.len > 0) alloc.free(self.kinds);
        self.paths_buf = &.{};
        self.lower_buf = &.{};
        self.offsets = &.{};
        self.basename_starts = &.{};
        self.char_masks = &.{};
        self.punct_masks = &.{};
        self.kinds = &.{};
        self.ready_count.store(0, .release);
    }
};

pub const FileIndex = struct {
    /// The main thread is the sole owner allowed to replace or reclaim these
    /// generation pointers. The loader writes only `loading_generation`.
    active_generation: ?*Generation = null,
    loading_generation: ?*Generation = null,
    /// Owned roots for the current generation. The primary root is first;
    /// active additional roots follow in configured order.
    roots: [][]u8 = &.{},
    /// Owned replacement roots for one coalesced refresh while loading.
    pending_roots: ?[][]u8 = null,

    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    generation: usize = 0,
    initial_failed: bool = false,

    pub fn requestStop(self: *FileIndex) void {
        self.stop_requested.store(true, .seq_cst);
        debug_trace.logf("core", "file index shutdown requested generation={d} loader={s} active={} loading={} queued={}", .{
            self.generation,
            if (self.thread == null) "none" else "owned",
            self.active_generation != null,
            self.loading_generation != null,
            self.pending_roots != null,
        });
    }

    pub fn deinit(self: *FileIndex, alloc: Allocator) void {
        self.requestStop();
        if (self.thread) |handle| {
            handle.join();
            self.thread = null;
            debug_trace.logf("core", "file index shutdown joined generation={d}", .{self.generation});
        }
        if (self.loading_generation) |generation| {
            debug_trace.logf("core", "file index generation discarded generation={d} state={s}", .{ generation.id, @tagName(generation.currentState()) });
            generation.destroy(alloc);
        }
        self.loading_generation = null;
        if (self.active_generation) |generation| {
            debug_trace.logf("core", "file index shutdown reclaiming generation={d}", .{generation.id});
            generation.destroy(alloc);
        }
        self.active_generation = null;
        freeRoots(alloc, self.roots);
        self.roots = &.{};
        if (self.pending_roots) |roots| freeRoots(alloc, roots);
        self.pending_roots = null;
        debug_trace.logf("core", "file index shutdown complete generation={d}", .{self.generation});
    }

    pub fn currentState(self: *const FileIndex) State {
        if (self.active_generation != null) return .ready;
        const loading = self.loading_generation orelse return if (self.initial_failed) .failed else .idle;
        return switch (loading.currentState()) {
            .loading => .loading,
            .ready => .ready,
            .failed, .canceled => .failed,
        };
    }

    /// Number of path entries currently searchable. During load this grows
    /// as the loader thread publishes more entries; once the build finishes
    /// it holds steady at the final count.
    pub fn count(self: *const FileIndex) usize {
        const generation = self.searchableGeneration() orelse return 0;
        return generation.count();
    }

    /// Kick off one background generation from an immutable access scope.
    pub fn ensureScope(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope) void {
        if (self.currentState() != .idle) return;
        if (scope.primary_directory.len == 0) return;

        self.roots = activeRootsAlloc(alloc, scope) catch return;
        _ = self.startLoad(alloc);
    }

    fn startLoad(self: *FileIndex, alloc: Allocator) bool {
        if (self.roots.len == 0 or
            self.thread != null or
            self.loading_generation != null or
            self.stop_requested.load(.seq_cst)) return false;

        const generation_id = self.generation + 1;
        const loading = Generation.create(alloc, generation_id) catch |err| {
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation allocation failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        self.loading_generation = loading;
        self.generation = generation_id;
        self.initial_failed = false;
        self.thread = std.Thread.spawn(.{}, loaderThreadMain, .{
            loading,
            alloc,
            self.roots,
            &self.stop_requested,
        }) catch |err| {
            self.loading_generation = null;
            loading.destroy(alloc);
            if (self.active_generation == null) self.initial_failed = true;
            debug_trace.logf("core", "file index generation spawn failed generation={d} err={s}", .{ generation_id, @errorName(err) });
            return false;
        };
        debug_trace.logf("core", "file index generation started generation={d} caller_thread={d}", .{ generation_id, std.Thread.getCurrentId() });
        return true;
    }

    /// Reaps one terminal loader without waiting for incomplete work. Returns
    /// whether candidate or initial-status facts changed and need rendering.
    pub fn joinThreadIfDone(self: *FileIndex, alloc: Allocator) bool {
        const handle = self.thread orelse return false;
        const loading = self.loading_generation orelse return false;
        const terminal_state = loading.currentState();
        if (terminal_state == .loading) return false;

        handle.join();
        self.thread = null;
        debug_trace.logf("core", "file index generation joined generation={d} state={s}", .{ loading.id, @tagName(terminal_state) });

        var visible_changed = false;
        switch (terminal_state) {
            .loading => unreachable,
            .ready => {
                const previous = self.active_generation;
                self.active_generation = loading;
                self.loading_generation = null;
                self.initial_failed = false;
                debug_trace.logf("core", "file index generation adopted generation={d} count={d}", .{ loading.id, loading.count() });
                if (previous) |generation| generation.destroy(alloc);
                visible_changed = true;
            },
            .failed, .canceled => {
                self.loading_generation = null;
                if (self.active_generation == null and terminal_state == .failed) {
                    self.initial_failed = true;
                    visible_changed = true;
                }
                debug_trace.logf("core", "file index generation discarded generation={d} state={s}", .{ loading.id, @tagName(terminal_state) });
                loading.destroy(alloc);
            },
        }

        if (!self.stop_requested.load(.seq_cst)) {
            if (self.pending_roots) |roots| {
                self.pending_roots = null;
                freeRoots(alloc, self.roots);
                self.roots = roots;
                _ = self.startLoad(alloc);
            }
        }
        return visible_changed;
    }

    /// Requests one replacement generation. A current loader retains its
    /// immutable scope and coalesces only the latest owned replacement scope.
    pub fn refresh(self: *FileIndex, alloc: Allocator) void {
        const roots = cloneRoots(alloc, self.pending_roots orelse self.roots) catch |err| {
            debug_trace.logf("core", "file index refresh snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots);
    }

    /// Refreshes from the latest active scope. A loading generation keeps its
    /// immutable roots and receives one owned, coalesced replacement snapshot.
    pub fn refreshScope(self: *FileIndex, alloc: Allocator, scope: workspace_access.AccessScope) void {
        const roots = activeRootsAlloc(alloc, scope) catch |err| {
            debug_trace.logf("core", "file index scope snapshot failed generation={d} err={s}", .{ self.generation, @errorName(err) });
            return;
        };
        self.refreshOwnedRoots(alloc, roots);
    }

    fn refreshOwnedRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8) void {
        if (self.stop_requested.load(.seq_cst)) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded during shutdown generation={d}", .{self.generation});
            return;
        }
        if (self.thread != null) {
            self.replacePendingRoots(alloc, roots);
            return;
        }

        if (self.loading_generation != null) {
            freeRoots(alloc, roots);
            debug_trace.logf("core", "file index refresh discarded with unowned loading generation={d}", .{self.generation});
            return;
        }
        freeRoots(alloc, self.roots);
        self.roots = roots;
        const started = self.startLoad(alloc);
        if (!started) debug_trace.logf("core", "file index refresh not started generation={d}", .{self.generation});
    }

    fn replacePendingRoots(self: *FileIndex, alloc: Allocator, roots: [][]u8) void {
        if (self.pending_roots) |pending| {
            if (rootsEqual(pending, roots)) {
                freeRoots(alloc, roots);
                debug_trace.logf("core", "file index refresh coalesced generation={d} identical=true", .{self.generation});
                return;
            }
            freeRoots(alloc, pending);
            debug_trace.logf("core", "file index pending refresh superseded generation={d}", .{self.generation});
        }
        self.pending_roots = roots;
        debug_trace.logf("core", "file index refresh coalesced generation={d} identical=false", .{self.generation});
    }

    pub fn isCurrentCandidateKind(self: *const FileIndex, path: []const u8, expected_kind: CandidateKind) bool {
        const current_roots = self.pending_roots orelse self.roots;
        if (!text_utils.isTerminalSafe(path) or current_roots.len == 0) return false;
        const root_path, const relative = if (std.fs.path.isAbsolute(path)) resolved: {
            for (current_roots) |root| {
                if (!pathing.pathInside(root, path)) continue;
                const rel = pathing.workspaceRelativePath(std.heap.c_allocator, root, path) catch return false;
                break :resolved .{ root, rel };
            }
            return false;
        } else .{ current_roots[0], path };
        defer if (std.fs.path.isAbsolute(path)) std.heap.c_allocator.free(relative);
        var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root_path, .{}) catch return false;
        defer root.close(io_mod.getIo());
        const stat = root.statFile(io_mod.getIo(), relative, .{ .follow_symlinks = false }) catch return false;
        return candidateKindMatchesStat(expected_kind, stat.kind);
    }

    /// Builds a ready index synchronously from NUL- or newline-delimited paths.
    pub fn buildFromRaw(self: *FileIndex, alloc: Allocator, raw_list: []const u8) !void {
        try self.buildFromSource(alloc, .{ .file_raw = raw_list });
    }

    /// Build synchronously from typed candidates. Candidate paths are
    /// borrowed for this call and copied into the index. Repeated path-kind
    /// identities are retained once in their first input position.
    pub fn buildFromCandidates(self: *FileIndex, alloc: Allocator, candidates: []const Candidate) !void {
        const indices = try candidateIndicesAlloc(alloc, candidates);
        defer if (indices.len > 0) alloc.free(indices);
        try self.buildFromSource(alloc, .{ .typed = .{
            .candidates = candidates,
            .indices = indices,
        } });
    }

    /// Writes typed, ranked results into caller-owned output. Path bytes
    /// borrow this index generation; result records and `matched_spans` borrow
    /// the caller's buffers. Callers must disregard output after an error.
    pub fn searchTyped(
        self: *const FileIndex,
        query: []const u8,
        out: []SearchResult,
        match_spans: []MatchSpan,
    ) SearchError!usize {
        if (out.len == 0) return 0;
        const generation = self.searchableGeneration() orelse return 0;
        const total = generation.count();
        if (total == 0 or query.len > max_path_len) return 0;

        if (query.len == 0) {
            const result_count = @min(total, out.len);
            for (out[0..result_count], 0..) |*result, index| {
                result.* = .{
                    .path = generation.pathAt(index),
                    .kind = generation.kindAt(index),
                    .matched_spans = match_spans[0..0],
                };
            }
            return result_count;
        }

        var query_scratch: QueryScratch = undefined;
        const prepared = prepareQuery(query, &query_scratch) orelse return 0;
        var indices: [max_search_results]u32 = undefined;
        const result_count = rankTopN(generation, prepared, indices[0..@min(out.len, max_search_results)]);

        var path_scratch: FoldedPathScratch = undefined;
        var matched_offsets: [max_path_len]u16 = undefined;
        var span_scratch: [max_path_len]MatchSpan = undefined;
        var spans_used: usize = 0;
        for (indices[0..result_count], 0..) |index, result_index| {
            const path = generation.pathAt(index);
            const base_start = generation.basename_starts[index] - generation.offsets[index];
            const span_count = reconstructMatchSpans(
                path,
                base_start,
                prepared.folded,
                &path_scratch,
                &matched_offsets,
                &span_scratch,
            ) orelse return error.InvalidIndexData;
            if (span_count > match_spans.len -| spans_used) return error.NoSpaceLeft;
            @memcpy(match_spans[spans_used..][0..span_count], span_scratch[0..span_count]);
            out[result_index] = .{
                .path = path,
                .kind = generation.kindAt(index),
                .matched_spans = match_spans[spans_used..][0..span_count],
            };
            spans_used += span_count;
        }
        return result_count;
    }

    fn searchableGeneration(self: *const FileIndex) ?*const Generation {
        if (self.active_generation) |active| return active;
        const loading = self.loading_generation orelse return null;
        return switch (loading.currentState()) {
            .loading, .ready => loading,
            .failed, .canceled => null,
        };
    }

    fn pathAt(self: *const FileIndex, i: usize) []const u8 {
        return self.searchableGeneration().?.pathAt(i);
    }

    fn kindAt(self: *const FileIndex, i: usize) CandidateKind {
        return self.searchableGeneration().?.kindAt(i);
    }

    fn lowerPathAt(self: *const FileIndex, i: u32) []const u8 {
        return self.searchableGeneration().?.lowerPathAt(i);
    }

    fn buildFromSource(self: *FileIndex, alloc: Allocator, source: CandidateSource) !void {
        if (self.thread != null or self.loading_generation != null) return error.LoadInProgress;
        const generation_id = self.generation + 1;
        const generation = try Generation.create(alloc, generation_id);
        errdefer generation.destroy(alloc);
        try generation.fillProgressive(alloc, source, null);
        generation.finish(.ready);

        const previous = self.active_generation;
        self.active_generation = generation;
        self.generation = generation_id;
        self.initial_failed = false;
        if (previous) |active| active.destroy(alloc);
    }
};

const TypedCandidateSource = struct {
    candidates: []const Candidate,
    indices: ?[]const usize,
};

const CandidateSource = union(enum) {
    file_raw: []const u8,
    typed: TypedCandidateSource,

    fn iterator(self: CandidateSource) CandidateIterator {
        return switch (self) {
            .file_raw => |raw_list| .{ .file_raw = .{
                .separator = rawPathSeparator(raw_list),
                .iterator = std.mem.splitScalar(u8, raw_list, rawPathSeparator(raw_list)),
            } },
            .typed => |typed| .{ .typed = .{
                .candidates = typed.candidates,
                .indices = typed.indices,
            } },
        };
    }
};

const RawFileCandidateIterator = struct {
    separator: u8,
    iterator: std.mem.SplitIterator(u8, .scalar),

    fn next(self: *RawFileCandidateIterator) ?Candidate {
        while (self.iterator.next()) |raw| {
            const path = acceptedRawPath(self.separator, raw) orelse continue;
            return .{ .path = path, .kind = .file };
        }
        return null;
    }
};

const TypedCandidateIterator = struct {
    candidates: []const Candidate,
    indices: ?[]const usize,
    position: usize = 0,

    fn next(self: *TypedCandidateIterator) ?Candidate {
        const candidate_index = if (self.indices) |indices| index: {
            if (self.position >= indices.len) return null;
            break :index indices[self.position];
        } else index: {
            if (self.position >= self.candidates.len) return null;
            break :index self.position;
        };
        const candidate = self.candidates[candidate_index];
        self.position += 1;
        return candidate;
    }
};

const CandidateIterator = union(enum) {
    file_raw: RawFileCandidateIterator,
    typed: TypedCandidateIterator,

    fn next(self: *CandidateIterator) ?Candidate {
        return switch (self.*) {
            .file_raw => |*iterator| iterator.next(),
            .typed => |*iterator| iterator.next(),
        };
    }
};

fn candidateIndicesAlloc(alloc: Allocator, candidates: []const Candidate) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    errdefer indices.deinit(alloc);
    var seen: std.StringHashMapUnmanaged(u2) = .empty;
    defer seen.deinit(alloc);

    for (candidates, 0..) |candidate, index| {
        if (acceptedCandidate(candidate) == null) continue;
        if (indices.items.len >= max_indexed_files) break;

        const kind_mask: u2 = switch (candidate.kind) {
            .file => 0b01,
            .directory => 0b10,
        };
        const entry = try seen.getOrPut(alloc, candidate.path);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        if ((entry.value_ptr.* & kind_mask) != 0) continue;
        entry.value_ptr.* |= kind_mask;
        try indices.append(alloc, index);
    }

    return indices.toOwnedSlice(alloc);
}

fn candidateKindMatchesStat(expected: CandidateKind, actual: std.Io.File.Kind) bool {
    return switch (expected) {
        .file => actual == .file or actual == .sym_link,
        .directory => actual == .directory,
    };
}

fn loaderThreadMain(
    generation: *Generation,
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
) void {
    debug_trace.logf("core", "file index loader entered generation={d} worker_thread={d}", .{ generation.id, std.Thread.getCurrentId() });
    const outcome = loadGeneration(generation, alloc, roots, stop_requested);
    publishLoaderOutcomeAfterCleanup(generation, outcome);
}

fn loadGeneration(
    generation: *Generation,
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
) LoaderOutcome {
    if (isStopRequested(stop_requested)) return .canceled;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const candidates = discoverScopeCandidates(arena, roots, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .discovery, .err = err } };
    };

    generation.fillProgressive(alloc, .{ .typed = .{
        .candidates = candidates,
        .indices = null,
    } }, stop_requested) catch |err| {
        if (err == error.Canceled or isStopRequested(stop_requested)) return .canceled;
        return .{ .failed = .{ .stage = .storage, .err = err } };
    };
    if (isStopRequested(stop_requested)) return .canceled;
    return .ready;
}

/// Publishes the loader's terminal outcome only after its caller has released
/// every worker-owned temporary. The release store is deliberately the final
/// action so an acquire observer may join without waiting for worker cleanup.
fn publishLoaderOutcomeAfterCleanup(generation: *Generation, outcome: LoaderOutcome) void {
    switch (outcome) {
        .ready => debug_trace.logf("core", "file index generation ready generation={d} count={d} worker_cleanup=complete", .{ generation.id, generation.count() }),
        .failed => |failure| debug_trace.logf("core", "file index generation failed generation={d} stage={s} err={s} worker_cleanup=complete", .{ generation.id, @tagName(failure.stage), @errorName(failure.err) }),
        .canceled => debug_trace.logf("core", "file index generation canceled generation={d} worker_cleanup=complete", .{generation.id}),
    }
    generation.finish(outcome.terminalState());
}

fn activeRootsAlloc(alloc: Allocator, scope: workspace_access.AccessScope) ![][]u8 {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| alloc.free(root);
        roots.deinit(alloc);
    }

    try roots.append(alloc, try alloc.dupe(u8, scope.primary_directory));
    for (scope.additional_directories) |entry| {
        if (!entry.active) continue;
        var duplicate = false;
        for (roots.items) |root| {
            if (std.mem.eql(u8, root, entry.path)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try roots.append(alloc, try alloc.dupe(u8, entry.path));
    }
    return roots.toOwnedSlice(alloc);
}

fn cloneRoots(alloc: Allocator, source: []const []const u8) ![][]u8 {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| alloc.free(root);
        roots.deinit(alloc);
    }
    for (source) |root| try roots.append(alloc, try alloc.dupe(u8, root));
    return roots.toOwnedSlice(alloc);
}

fn freeRoots(alloc: Allocator, roots: []const []u8) void {
    for (roots) |root| alloc.free(root);
    if (roots.len > 0) alloc.free(roots);
}

fn rootsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn discoverScopeCandidates(
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
) ![]const Candidate {
    return discoverScopeCandidatesWithFallback(alloc, roots, stop_requested, false);
}

fn discoverScopeCandidatesWithFallback(
    alloc: Allocator,
    roots: []const []const u8,
    stop_requested: *std.atomic.Value(bool),
    force_fallback: bool,
) ![]const Candidate {
    if (isStopRequested(stop_requested)) return error.Canceled;

    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(alloc);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var kept: usize = 0;
    var succeeded: usize = 0;

    for (roots, 0..) |root_path, root_index| {
        if (isStopRequested(stop_requested)) return error.Canceled;
        if (kept >= max_indexed_files) break;
        const remaining = max_indexed_files - kept;

        const discovered = workspace_files.discoverCancellable(
            alloc,
            root_path,
            .{
                .candidate_cap = remaining,
                .force_fallback = force_fallback,
                .include_hidden = true,
                .include_untracked = true,
                .sort_paths = true,
                .git_worktree_is_authoritative = true,
            },
            stop_requested,
        ) catch |err| {
            if (err == error.Canceled or isStopRequested(stop_requested)) return error.Canceled;
            debug_trace.logf("core", "file index root discovery omitted root={d} err={s}", .{ root_index, @errorName(err) });
            continue;
        };
        succeeded += 1;

        const discovered_directories: []const []const u8 = directories: {
            const result = workspace_files.discoverDirectoriesCancellable(
                alloc,
                root_path,
                .{
                    .candidate_cap = remaining,
                    .force_fallback = force_fallback,
                    .include_hidden = true,
                    .sort_paths = true,
                    .git_worktree_is_authoritative = true,
                },
                stop_requested,
            ) catch |err| {
                if (err == error.Canceled or isStopRequested(stop_requested)) return error.Canceled;
                debug_trace.logf("core", "file index root directory discovery omitted root={d} err={s}", .{ root_index, @errorName(err) });
                break :directories &.{};
            };
            break :directories result.directories;
        };

        var root = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root_path, .{}) catch |err| {
            debug_trace.logf("core", "file index root admission omitted root={d} err={s}", .{ root_index, @errorName(err) });
            succeeded -= 1;
            continue;
        };
        defer root.close(io_mod.getIo());

        var file_cursor: usize = 0;
        var directory_cursor: usize = 0;
        while (nextSortedDiscoveredCandidate(
            discovered.files,
            discovered_directories,
            &file_cursor,
            &directory_cursor,
        )) |candidate| {
            if (isStopRequested(stop_requested)) return error.Canceled;
            if (kept >= max_indexed_files) break;
            if (workspace_files.pathContainsIgnoredDir(&.{".git"}, candidate.path)) continue;
            if (!text_utils.isTerminalSafe(candidate.path)) {
                debug_trace.logf("core", "file index omitted unsafe candidate bytes={d} kind={s}", .{ candidate.path.len, @tagName(candidate.kind) });
                continue;
            }
            if (candidate.kind == .file) {
                const stat = root.statFile(io_mod.getIo(), candidate.path, .{ .follow_symlinks = false }) catch |err| {
                    debug_trace.logf("core", "file index omitted missing candidate bytes={d} err={s}", .{ candidate.path.len, @errorName(err) });
                    continue;
                };
                if (stat.kind != .file and stat.kind != .sym_link) continue;
            }

            if (try appendDiscoveredCandidate(
                alloc,
                &candidates,
                &seen,
                root_path,
                root_index,
                candidate.path,
                candidate.kind,
            )) kept += 1;
        }
    }

    if (succeeded == 0 and roots.len > 0) return error.FileNotFound;
    return candidates.toOwnedSlice(alloc);
}

fn nextSortedDiscoveredCandidate(
    files: []const []const u8,
    directories: []const []const u8,
    file_cursor: *usize,
    directory_cursor: *usize,
) ?Candidate {
    if (file_cursor.* >= files.len and directory_cursor.* >= directories.len) return null;
    if (directory_cursor.* >= directories.len or
        (file_cursor.* < files.len and std.mem.order(u8, files[file_cursor.*], directories[directory_cursor.*]) != .gt))
    {
        defer file_cursor.* += 1;
        return .{ .path = files[file_cursor.*], .kind = .file };
    }
    defer directory_cursor.* += 1;
    return .{ .path = directories[directory_cursor.*], .kind = .directory };
}

fn appendDiscoveredCandidate(
    alloc: Allocator,
    candidates: *std.ArrayList(Candidate),
    seen: *std.StringHashMapUnmanaged(void),
    root_path: []const u8,
    root_index: usize,
    relative: []const u8,
    kind: CandidateKind,
) !bool {
    const absolute = try std.fs.path.resolve(alloc, &.{ root_path, relative });
    if (!pathing.pathInside(root_path, absolute)) return false;

    const display = if (root_index == 0) relative else absolute;
    if (acceptedCandidate(.{ .path = display, .kind = kind }) == null) return false;

    const seen_entry = try seen.getOrPut(alloc, absolute);
    if (seen_entry.found_existing) return false;
    try candidates.append(alloc, .{ .path = display, .kind = kind });
    return true;
}

fn isStopRequested(stop_requested: ?*std.atomic.Value(bool)) bool {
    return if (stop_requested) |flag| flag.load(.seq_cst) else false;
}

const RawTotals = struct {
    /// Number of entries in `raw_list` that pass the filters and fit under
    /// `max_indexed_files`.
    n: u32,
    /// Sum of byte lengths of every kept path. The loader pre-allocates
    /// `paths_buf` and `lower_buf` to exactly this size.
    bytes: u32,
};

fn rawPathSeparator(raw_list: []const u8) u8 {
    return if (std.mem.findScalar(u8, raw_list, 0) != null) 0 else '\n';
}

fn acceptedRawPath(sep: u8, raw: []const u8) ?[]const u8 {
    const path = if (sep == '\n') std.mem.trimEnd(u8, raw, "\r") else raw;
    if (path.len == 0) return null;
    if (path.len > max_path_len) return null;
    if (!text_utils.isTerminalSafe(path)) return null;
    return path;
}

fn acceptedCandidate(candidate: Candidate) ?Candidate {
    if (candidate.path.len == 0) return null;
    if (candidate.path.len > max_path_len) return null;
    if (!text_utils.isTerminalSafe(candidate.path)) return null;
    if (!file_picker_path.isRepresentable(candidate.path)) return null;
    if (candidate.kind == .directory and std.fs.path.isSep(candidate.path[candidate.path.len - 1])) return null;
    return candidate;
}

/// Applies fill-pass filters to size generation buffers before publication.
fn countAndSize(source: CandidateSource) RawTotals {
    var n: u32 = 0;
    var bytes: u32 = 0;

    var iter = source.iterator();
    while (iter.next()) |candidate| {
        const accepted = acceptedCandidate(candidate) orelse continue;
        if (n >= max_indexed_files) break;

        n += 1;
        bytes += @intCast(accepted.path.len);
    }

    return .{ .n = n, .bytes = bytes };
}

/// Returns an a-z presence bitmap. Non-ASCII input cannot cause false rejection.
fn alphaMask(bytes: []const u8) u32 {
    var m: u32 = 0;
    for (bytes) |b| {
        const lower = asciiToLower(b);
        if (lower >= 'a' and lower <= 'z') {
            m |= @as(u32, 1) << @intCast(lower - 'a');
        }
    }
    return m;
}

/// Returns a presence bitmap for bytes 0x20..0x3f (space through '?':
/// whitespace, most punctuation, digits). Bytes outside that range
/// contribute no bits, so the mask can only under-constrain a query,
/// never falsely reject one.
fn punctMask(bytes: []const u8) u32 {
    var m: u32 = 0;
    for (bytes) |b| {
        const lower = asciiToLower(b);
        if (lower >= 0x20 and lower <= 0x3f) {
            m |= @as(u32, 1) << @intCast(lower - 0x20);
        }
    }
    return m;
}

const non_ascii_mask: u32 = @as(u32, 1) << 31;
const max_search_results: usize = 64;

fn asciiToLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn foldUtf8Into(bytes: []const u8, out: []u21) ?[]const u21 {
    var byte_index: usize = 0;
    var scalar_index: usize = 0;
    while (byte_index < bytes.len) {
        if (scalar_index >= out.len) return null;
        const sequence_len = std.unicode.utf8ByteSequenceLength(bytes[byte_index]) catch return null;
        const end = byte_index + sequence_len;
        if (end > bytes.len) return null;
        const codepoint = std.unicode.utf8Decode(bytes[byte_index..end]) catch return null;
        out[scalar_index] = unicode_simple_fold.fold(codepoint);
        scalar_index += 1;
        byte_index = end;
    }
    return out[0..scalar_index];
}

const QueryScratch = struct {
    folded: [max_path_len]u21,
    ascii: [max_path_len]u8,
};

const PreparedQuery = struct {
    folded: []const u21,
    ascii: ?[]const u8,
};

fn prepareQuery(query: []const u8, scratch: *QueryScratch) ?PreparedQuery {
    const folded = foldUtf8Into(query, &scratch.folded) orelse return null;
    for (folded, 0..) |scalar, index| {
        if (scalar > 0x7f) return .{ .folded = folded, .ascii = null };
        scratch.ascii[index] = @intCast(scalar);
    }
    return .{ .folded = folded, .ascii = scratch.ascii[0..folded.len] };
}

const FoldedPathScratch = struct {
    scalars: [max_path_len]u21,
    byte_offsets: [max_path_len + 1]u16,
};

const DecodedFoldedPath = struct {
    scalar_count: usize,
    basename_scalar_start: usize,
};

fn decodeFoldedPath(
    path: []const u8,
    basename_byte_start: usize,
    scratch: *FoldedPathScratch,
) ?DecodedFoldedPath {
    var byte_index: usize = 0;
    var scalar_index: usize = 0;
    var basename_scalar_start: ?usize = null;
    while (byte_index < path.len) {
        if (byte_index == basename_byte_start) basename_scalar_start = scalar_index;
        const sequence_len = std.unicode.utf8ByteSequenceLength(path[byte_index]) catch return null;
        const end = byte_index + sequence_len;
        if (end > path.len or scalar_index >= scratch.scalars.len) return null;
        const codepoint = std.unicode.utf8Decode(path[byte_index..end]) catch return null;
        scratch.byte_offsets[scalar_index] = std.math.cast(u16, byte_index) orelse return null;
        scratch.scalars[scalar_index] = unicode_simple_fold.fold(codepoint);
        scalar_index += 1;
        byte_index = end;
    }
    if (byte_index == basename_byte_start) basename_scalar_start = scalar_index;
    scratch.byte_offsets[scalar_index] = std.math.cast(u16, path.len) orelse return null;
    return .{
        .scalar_count = scalar_index,
        .basename_scalar_start = basename_scalar_start orelse return null,
    };
}

const MatchScore = struct {
    exact_fit: bool,
    basename_fit: bool,
    boundary_matches: usize,
    prefix: bool,
    first_position: usize,
    longest_run: usize,
    consecutive_matches: usize,
    gaps: usize,
};

const SubsequenceFacts = struct {
    boundary_matches: usize = 0,
    prefix: bool = false,
    first_position: usize = 0,
    longest_run: usize = 0,
    consecutive_matches: usize = 0,
    gaps: usize = 0,
};

const RankedCandidate = struct {
    score: MatchScore,
    index: u32,
};

fn rankTopN(generation: *const Generation, query: PreparedQuery, out: []u32) usize {
    const top_cap = @min(out.len, max_search_results);
    if (top_cap == 0) return 0;

    var ranked: [max_search_results]RankedCandidate = undefined;
    var filled: usize = 0;
    var worst_slot: usize = 0;

    const query_ascii = query.ascii;
    const query_mask = if (query_ascii) |ascii| alphaMask(ascii) else 0;
    const query_punct_mask = if (query_ascii) |ascii| punctMask(ascii) else 0;
    var scalar_scratch: FoldedPathScratch = undefined;

    const total = generation.count();
    var candidate_index: u32 = 0;
    while (candidate_index < total) : (candidate_index += 1) {
        const path_mask = generation.char_masks[candidate_index];
        const base_start = generation.basename_starts[candidate_index] - generation.offsets[candidate_index];
        const score = if ((path_mask & non_ascii_mask) == 0) ascii_path: {
            const ascii = query_ascii orelse continue;
            if ((path_mask & query_mask) != query_mask) continue;
            if (query_punct_mask != 0) {
                if ((generation.punct_masks[candidate_index] & query_punct_mask) != query_punct_mask) continue;
            }
            break :ascii_path scoreAsciiMatch(
                generation.pathAt(candidate_index),
                generation.lowerPathAt(candidate_index),
                base_start,
                ascii,
            );
        } else scoreFoldedMatch(generation.pathAt(candidate_index), base_start, query.folded, &scalar_scratch);
        const match_score = score orelse continue;
        const candidate: RankedCandidate = .{ .score = match_score, .index = candidate_index };

        if (filled < top_cap) {
            ranked[filled] = candidate;
            filled += 1;
            if (filled == top_cap) worst_slot = findWorstSlot(generation, ranked[0..filled]);
        } else if (rankedCandidateBetter(generation, candidate, ranked[worst_slot])) {
            ranked[worst_slot] = candidate;
            worst_slot = findWorstSlot(generation, ranked[0..filled]);
        }
    }

    sortRanked(generation, ranked[0..filled]);
    for (ranked[0..filled], 0..) |candidate, result_index| out[result_index] = candidate.index;
    return filled;
}

fn scoreAsciiMatch(
    path: []const u8,
    path_lower: []const u8,
    basename_start: u32,
    query: []const u8,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_start;
    const basename = path_lower[base_start..];
    const exact_fit = std.mem.eql(u8, path_lower, query) or std.mem.eql(u8, basename, query);

    if (scoreAsciiRange(path, path_lower, base_start, query)) |facts| {
        return matchScore(exact_fit, true, facts);
    }
    const facts = scoreAsciiRange(path, path_lower, 0, query) orelse return null;
    return matchScore(exact_fit, false, facts);
}

noinline fn scoreAsciiRange(
    path: []const u8,
    path_lower: []const u8,
    range_start: usize,
    query: []const u8,
) ?SubsequenceFacts {
    if (query.len > path_lower.len - range_start) return null;

    var facts: SubsequenceFacts = .{};
    var query_index: usize = 0;
    var previous_position: usize = 0;
    var run_length: usize = 0;
    var position = range_start;
    if (query.len != 0) {
        if (std.mem.indexOfScalarPos(u8, path_lower, range_start, query[0])) |first_hit| {
            position = first_hit;
        } else return null;
    }
    while (position < path_lower.len and query_index < query.len) : (position += 1) {
        if (path_lower[position] != query[query_index]) {
            position = std.mem.indexOfScalarPos(u8, path_lower, position + 1, query[query_index]) orelse return null;
        }

        if (query_index == 0) {
            facts.first_position = position - range_start;
            facts.prefix = position == range_start;
            run_length = 1;
        } else if (position == previous_position + 1) {
            facts.consecutive_matches += 1;
            run_length += 1;
        } else {
            facts.gaps += position - previous_position - 1;
            run_length = 1;
        }
        facts.longest_run = @max(facts.longest_run, run_length);
        facts.boundary_matches += @intFromBool(isMatchBoundary(path, position));
        previous_position = position;
        query_index += 1;
    }
    return if (query_index == query.len) facts else null;
}

noinline fn scoreFoldedMatch(
    path: []const u8,
    basename_byte_start: u32,
    query: []const u21,
    scratch: *FoldedPathScratch,
) ?MatchScore {
    if (query.len == 0 or path.len == 0) return null;
    const base_start: usize = basename_byte_start;
    const decoded = decodeFoldedPath(path, base_start, scratch) orelse return null;
    const scalars = scratch.scalars[0..decoded.scalar_count];
    const basename_scalars = scalars[decoded.basename_scalar_start..];
    const exact_fit = std.mem.eql(u21, scalars, query) or std.mem.eql(u21, basename_scalars, query);

    if (scoreFoldedRange(path, scalars, scratch.byte_offsets[0 .. decoded.scalar_count + 1], decoded.basename_scalar_start, query)) |facts| {
        return matchScore(exact_fit, true, facts);
    }
    const facts = scoreFoldedRange(path, scalars, scratch.byte_offsets[0 .. decoded.scalar_count + 1], 0, query) orelse return null;
    return matchScore(exact_fit, false, facts);
}

fn scoreFoldedRange(
    path: []const u8,
    scalars: []const u21,
    byte_offsets: []const u16,
    range_start: usize,
    query: []const u21,
) ?SubsequenceFacts {
    if (query.len > scalars.len - range_start) return null;

    var facts: SubsequenceFacts = .{};
    var query_index: usize = 0;
    var previous_position: usize = 0;
    var run_length: usize = 0;
    var position = range_start;
    while (position < scalars.len and query_index < query.len) : (position += 1) {
        if (scalars[position] != query[query_index]) continue;

        if (query_index == 0) {
            facts.first_position = position - range_start;
            facts.prefix = position == range_start;
            run_length = 1;
        } else if (position == previous_position + 1) {
            facts.consecutive_matches += 1;
            run_length += 1;
        } else {
            facts.gaps += position - previous_position - 1;
            run_length = 1;
        }
        facts.longest_run = @max(facts.longest_run, run_length);
        facts.boundary_matches += @intFromBool(isMatchBoundary(path, byte_offsets[position]));
        previous_position = position;
        query_index += 1;
    }
    return if (query_index == query.len) facts else null;
}

fn matchScore(exact_fit: bool, basename_fit: bool, facts: SubsequenceFacts) MatchScore {
    return .{
        .exact_fit = exact_fit,
        .basename_fit = basename_fit,
        .boundary_matches = facts.boundary_matches,
        .prefix = facts.prefix,
        .first_position = facts.first_position,
        .longest_run = facts.longest_run,
        .consecutive_matches = facts.consecutive_matches,
        .gaps = facts.gaps,
    };
}

fn isMatchBoundary(path: []const u8, byte_index: usize) bool {
    if (byte_index == 0) return true;
    const previous = path[byte_index - 1];
    if (std.fs.path.isSep(previous) or previous == '-' or previous == '_' or previous == '.' or previous == ' ') return true;
    if (byte_index >= path.len) return false;
    const current = path[byte_index];
    return previous >= 'a' and previous <= 'z' and current >= 'A' and current <= 'Z';
}

fn scoreBetter(left: MatchScore, right: MatchScore) bool {
    if (left.exact_fit != right.exact_fit) return left.exact_fit;
    if (left.basename_fit != right.basename_fit) return left.basename_fit;
    if (left.boundary_matches != right.boundary_matches) return left.boundary_matches > right.boundary_matches;
    if (left.prefix != right.prefix) return left.prefix;
    if (left.first_position != right.first_position) return left.first_position < right.first_position;
    if (left.longest_run != right.longest_run) return left.longest_run > right.longest_run;
    if (left.consecutive_matches != right.consecutive_matches) return left.consecutive_matches > right.consecutive_matches;
    if (left.gaps != right.gaps) return left.gaps < right.gaps;
    return false;
}

fn rankedCandidateBetter(generation: *const Generation, left: RankedCandidate, right: RankedCandidate) bool {
    if (scoreBetter(left.score, right.score)) return true;
    if (scoreBetter(right.score, left.score)) return false;
    const left_path = generation.pathAt(left.index);
    const right_path = generation.pathAt(right.index);
    if (left_path.len != right_path.len) return left_path.len < right_path.len;
    return std.mem.order(u8, left_path, right_path) == .lt;
}

fn findWorstSlot(generation: *const Generation, ranked: []const RankedCandidate) usize {
    var worst_slot: usize = 0;
    for (ranked[1..], 1..) |candidate, candidate_index| {
        if (rankedCandidateBetter(generation, ranked[worst_slot], candidate)) worst_slot = candidate_index;
    }
    return worst_slot;
}

fn sortRanked(generation: *const Generation, ranked: []RankedCandidate) void {
    var candidate_index: usize = 1;
    while (candidate_index < ranked.len) : (candidate_index += 1) {
        const candidate = ranked[candidate_index];
        var insertion_index = candidate_index;
        while (insertion_index > 0 and rankedCandidateBetter(generation, candidate, ranked[insertion_index - 1])) : (insertion_index -= 1) {
            ranked[insertion_index] = ranked[insertion_index - 1];
        }
        ranked[insertion_index] = candidate;
    }
}

fn reconstructMatchSpans(
    path: []const u8,
    basename_byte_start: u32,
    query: []const u21,
    path_scratch: *FoldedPathScratch,
    matched_offsets: *[max_path_len]u16,
    span_scratch: *[max_path_len]MatchSpan,
) ?usize {
    const decoded = decodeFoldedPath(path, basename_byte_start, path_scratch) orelse return null;
    const scalars = path_scratch.scalars[0..decoded.scalar_count];
    const byte_offsets = path_scratch.byte_offsets[0 .. decoded.scalar_count + 1];
    const matched_count = collectMatchOffsets(
        scalars,
        byte_offsets,
        decoded.basename_scalar_start,
        query,
        matched_offsets,
    ) orelse collectMatchOffsets(scalars, byte_offsets, 0, query, matched_offsets) orelse return null;
    return spansFromMatchedOffsets(path, matched_offsets[0..matched_count], span_scratch);
}

fn collectMatchOffsets(
    scalars: []const u21,
    byte_offsets: []const u16,
    range_start: usize,
    query: []const u21,
    out: *[max_path_len]u16,
) ?usize {
    if (query.len > scalars.len - range_start) return null;
    var query_index: usize = 0;
    var position = range_start;
    while (position < scalars.len and query_index < query.len) : (position += 1) {
        if (scalars[position] != query[query_index]) continue;
        out[query_index] = byte_offsets[position];
        query_index += 1;
    }
    return if (query_index == query.len) query_index else null;
}

fn spansFromMatchedOffsets(
    path: []const u8,
    matched_offsets: []const u16,
    out: *[max_path_len]MatchSpan,
) ?usize {
    var matched_index: usize = 0;
    var span_count: usize = 0;
    var cursor: usize = 0;
    while (cursor < path.len and matched_index < matched_offsets.len) {
        const cluster_start = cursor;
        const first = display_width.displayUnitAt(path, cursor);
        if (first.byte_len == 0) return null;
        cursor += first.byte_len;
        while (cursor < path.len) {
            const continuation = display_width.displayUnitAt(path, cursor);
            if (continuation.byte_len == 0) return null;
            if (continuation.cell_width != 0) break;
            cursor += continuation.byte_len;
        }
        const cluster_end = cursor;

        var cluster_matched = false;
        while (matched_index < matched_offsets.len and matched_offsets[matched_index] < cluster_end) {
            if (matched_offsets[matched_index] < cluster_start) return null;
            cluster_matched = true;
            matched_index += 1;
        }
        if (!cluster_matched) continue;

        if (span_count > 0 and out[span_count - 1].byte_end == cluster_start) {
            out[span_count - 1].byte_end = std.math.cast(u16, cluster_end) orelse return null;
            continue;
        }
        out[span_count] = .{
            .byte_start = std.math.cast(u16, cluster_start) orelse return null,
            .byte_end = std.math.cast(u16, cluster_end) orelse return null,
        };
        span_count += 1;
    }
    if (matched_index != matched_offsets.len) return null;
    return span_count;
}

fn expectValidSearchSpans(result: SearchResult) !void {
    var previous_end: usize = 0;
    for (result.matched_spans) |span| {
        try std.testing.expect(span.byte_start < span.byte_end);
        try std.testing.expect(span.byte_start >= previous_end);
        try std.testing.expect(span.byte_end <= result.path.len);
        try std.testing.expect(std.unicode.utf8ValidateSlice(result.path[span.byte_start..span.byte_end]));
        previous_end = span.byte_end;
    }
}

fn TestSearchBuffer(comptime capacity: usize) type {
    return struct {
        results: [capacity]SearchResult = undefined,
        spans: [capacity * max_path_len]MatchSpan = undefined,

        fn run(self: *@This(), index: *const FileIndex, query: []const u8) SearchError![]const SearchResult {
            const count = try index.searchTyped(query, &self.results, &self.spans);
            return self.results[0..count];
        }
    };
}

fn expectFirstSearchPath(raw: []const u8, query: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, raw);

    var search: TestSearchBuffer(8) = .{};
    const results = try search.run(&index, query);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqualStrings(expected, results[0].path);
}

fn containsCandidate(candidates: []const Candidate, path: []const u8, kind: CandidateKind) bool {
    for (candidates) |candidate| {
        if (candidate.kind == kind and std.mem.eql(u8, candidate.path, path)) return true;
    }
    return false;
}

fn runGitForFileIndexTest(alloc: Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        .signal, .stopped, .unknown => return error.TestUnexpectedResult,
    }
}

const TestLoaderGate = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cleanup_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cleanup_release: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    cleanup_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    publish_count: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    outcome: GenerationState,
};

fn testLoaderThread(generation: *Generation, gate: *TestLoaderGate) void {
    gate.started.store(true, .release);
    while (!gate.release.load(.acquire)) std.atomic.spinLoopHint();
    gate.cleanup_started.store(true, .release);
    while (!gate.cleanup_release.load(.acquire)) std.atomic.spinLoopHint();
    gate.cleanup_finished.store(true, .release);
    _ = gate.publish_count.fetchAdd(1, .seq_cst);
    const outcome: LoaderOutcome = switch (gate.outcome) {
        .loading => unreachable,
        .ready => .ready,
        .failed => .{ .failed = .{ .stage = .storage, .err = error.TestLoaderFailure } },
        .canceled => .canceled,
    };
    publishLoaderOutcomeAfterCleanup(generation, outcome);
}

fn waitForTestFlag(flag: *const std.atomic.Value(bool)) !void {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (!flag.load(.acquire)) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
}

fn waitForGenerationState(generation: *const Generation, expected: GenerationState) !void {
    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    while (generation.currentState() != expected) {
        if (started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds() > 5000) {
            return error.TestUnexpectedResult;
        }
        sleepBlocking(1);
    }
}

const TestReapAttempt = struct {
    index: *FileIndex,
    alloc: Allocator,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    visible_changed: bool = false,
};

fn testReapThread(attempt: *TestReapAttempt) void {
    attempt.started.store(true, .release);
    attempt.visible_changed = attempt.index.joinThreadIfDone(attempt.alloc);
    attempt.finished.store(true, .release);
}

fn expectReapReturnsDuringCleanup(index: *FileIndex, alloc: Allocator, gate: *TestLoaderGate) !void {
    var attempt: TestReapAttempt = .{ .index = index, .alloc = alloc };
    const thread = try std.Thread.spawn(.{}, testReapThread, .{&attempt});
    waitForTestFlag(&attempt.started) catch |err| {
        gate.cleanup_release.store(true, .release);
        thread.join();
        return err;
    };
    waitForTestFlag(&attempt.finished) catch |err| {
        gate.cleanup_release.store(true, .release);
        thread.join();
        return err;
    };
    thread.join();
    try std.testing.expect(!attempt.visible_changed);
    try std.testing.expect(!gate.cleanup_release.load(.acquire));
}

fn installTestLoader(
    index: *FileIndex,
    alloc: Allocator,
    raw_list: []const u8,
    gate: *TestLoaderGate,
) !*Generation {
    const generation_id = index.generation + 1;
    const generation = try Generation.create(alloc, generation_id);
    errdefer generation.destroy(alloc);
    try generation.fillProgressive(alloc, .{ .file_raw = raw_list }, null);

    index.loading_generation = generation;
    index.generation = generation_id;
    index.thread = std.Thread.spawn(.{}, testLoaderThread, .{ generation, gate }) catch |err| {
        index.loading_generation = null;
        return err;
    };
    waitForTestFlag(&gate.started) catch |err| {
        gate.release.store(true, .release);
        index.thread.?.join();
        index.thread = null;
        index.loading_generation = null;
        return err;
    };
    return generation;
}

fn checkBuildFromRawAllocationFailures(alloc: Allocator) !void {
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromRaw(alloc, "one.txt\x00two.txt\x00");
}

fn checkBuildFromCandidatesAllocationFailures(alloc: Allocator) !void {
    const candidates = [_]Candidate{
        .{ .path = "src", .kind = .directory },
        .{ .path = "src/main.zig", .kind = .file },
        .{ .path = "src", .kind = .directory },
    };
    var index = FileIndex{};
    defer index.deinit(alloc);
    try index.buildFromCandidates(alloc, &candidates);
}

fn fuzzRawListAndQuery(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&bytes));
    const split = len / 2;

    var index = FileIndex{};
    defer index.deinit(std.testing.allocator);
    try index.buildFromRaw(std.testing.allocator, bytes[0..split]);

    var typed_results: [8]SearchResult = undefined;
    var span_storage: [8 * max_path_len]MatchSpan = undefined;
    const typed_count = try index.searchTyped(bytes[split..len], &typed_results, &span_storage);
    for (typed_results[0..typed_count]) |typed| {
        try std.testing.expect(typed.path.len <= max_path_len);
        try std.testing.expect(text_utils.isTerminalSafe(typed.path));
        try std.testing.expectEqual(CandidateKind.file, typed.kind);
        try expectValidSearchSpans(typed);
    }
}

fn sleepBlocking(milliseconds: u64) void {
    var sleep_io_backend: std.Io.Threaded = .init_single_threaded;
    sleep_io_backend.io().sleep(.fromMilliseconds(@intCast(milliseconds)), .real) catch {};
}
