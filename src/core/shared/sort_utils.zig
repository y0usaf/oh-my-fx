const std = @import("std");

// Share one stable sort across element types to avoid duplicating generic code.
// Uses insertion-sorted runs and in-place SymMerge (Kim and Kutzner, 2004):
// O(n log n) comparisons and O(n log^2 n) swaps.

/// Drop-in replacement for std.mem.sort: stable, in place, same signature.
pub fn sort(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    if (@sizeOf(T) == 0) return;
    if (items.len < 2) return;
    const Ctx = @TypeOf(context);
    const thunks = struct {
        fn less(user_ctx: *const anyopaque, lhs: *const anyopaque, rhs: *const anyopaque) bool {
            const lhs_elem: *const T = @ptrCast(@alignCast(lhs));
            const rhs_elem: *const T = @ptrCast(@alignCast(rhs));
            if (comptime @sizeOf(Ctx) == 0) {
                return lessThanFn(zeroBitValue(Ctx), lhs_elem.*, rhs_elem.*);
            }
            const ctx: *const Ctx = @ptrCast(@alignCast(user_ctx));
            return lessThanFn(ctx.*, lhs_elem.*, rhs_elem.*);
        }
    };
    // Zero-bit contexts have no address to smuggle through anyopaque; the
    // thunk reconstructs the value instead.
    const view = ErasedView{
        .base = @ptrCast(items.ptr),
        .elem_size = @sizeOf(T),
        .user_ctx = if (comptime @sizeOf(Ctx) == 0) @ptrCast(&zero_bit_sentinel) else @ptrCast(&context),
        .less = thunks.less,
    };
    sortView(items.len, &view);
}

const zero_bit_sentinel: u8 = 0;

fn zeroBitValue(comptime Ctx: type) Ctx {
    comptime std.debug.assert(@sizeOf(Ctx) == 0);
    if (Ctx == void) return;
    return std.mem.zeroes(Ctx);
}

const ErasedView = struct {
    base: [*]u8,
    elem_size: usize,
    user_ctx: *const anyopaque,
    less: *const fn (user_ctx: *const anyopaque, lhs: *const anyopaque, rhs: *const anyopaque) bool,

    fn lessThan(view: *const ErasedView, a: usize, b: usize) bool {
        return view.less(
            view.user_ctx,
            @ptrCast(view.base + a * view.elem_size),
            @ptrCast(view.base + b * view.elem_size),
        );
    }

    fn swap(view: *const ErasedView, a: usize, b: usize) void {
        const lhs = view.base + a * view.elem_size;
        const rhs = view.base + b * view.elem_size;
        for (0..view.elem_size) |i| {
            const tmp = lhs[i];
            lhs[i] = rhs[i];
            rhs[i] = tmp;
        }
    }
};

const run_length = 20;

fn sortView(len: usize, view: *const ErasedView) void {
    var lo: usize = 0;
    while (lo < len) : (lo += run_length) {
        insertionSortRange(view, lo, @min(lo + run_length, len));
    }
    var width: usize = run_length;
    while (width < len) : (width *= 2) {
        var start: usize = 0;
        while (start + width < len) : (start += 2 * width) {
            symMerge(view, start, start + width, @min(start + 2 * width, len));
        }
    }
}

fn insertionSortRange(view: *const ErasedView, a: usize, b: usize) void {
    if (b - a < 2) return;
    var i = a + 1;
    while (i < b) : (i += 1) {
        var j = i;
        while (j > a and view.lessThan(j, j - 1)) : (j -= 1) {
            view.swap(j, j - 1);
        }
    }
}

// Merges the sorted ranges [a, m) and [m, b) in place, keeping equal
// elements in their original relative order.
fn symMerge(view: *const ErasedView, a: usize, m: usize, b: usize) void {
    std.debug.assert(a < m and m < b);
    if (m - a == 1) {
        // Insert the single left element into the right range.
        var lo = m;
        var hi = b;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (view.lessThan(mid, a)) lo = mid + 1 else hi = mid;
        }
        var i = a;
        while (i + 1 < lo) : (i += 1) view.swap(i, i + 1);
        return;
    }
    if (b - m == 1) {
        // Insert the single right element into the left range.
        var lo = a;
        var hi = m;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (view.lessThan(m, mid)) hi = mid else lo = mid + 1;
        }
        var i = m;
        while (i > lo) : (i -= 1) view.swap(i, i - 1);
        return;
    }
    const mid = a + (b - a) / 2;
    const n = mid + m;
    var start: usize = undefined;
    var r: usize = undefined;
    if (m > mid) {
        start = n - b;
        r = mid;
    } else {
        start = a;
        r = m;
    }
    const p = n - 1;
    while (start < r) {
        const c = start + (r - start) / 2;
        if (!view.lessThan(p - c, c)) start = c + 1 else r = c;
    }
    const end = n - start;
    if (start < m and m < end) rotate(view, start, m, end);
    if (a < start and start < mid) symMerge(view, a, start, mid);
    if (mid < end and end < b) symMerge(view, mid, end, b);
}

// Rotates [a, b) so that the block starting at m becomes the front,
// using only pairwise swaps (gcd block-exchange).
fn rotate(view: *const ErasedView, a: usize, m: usize, b: usize) void {
    var i = m - a;
    var j = b - m;
    while (i != j) {
        if (i > j) {
            swapRange(view, m - i, m, j);
            i -= j;
        } else {
            swapRange(view, m - i, m + j - i, i);
            j -= i;
        }
    }
    swapRange(view, m - i, m, i);
}

fn swapRange(view: *const ErasedView, a: usize, b: usize, n: usize) void {
    for (0..n) |i| view.swap(a + i, b + i);
}

const testing = std.testing;

const TestElem = struct { key: u16, seq: u16 };

fn testElemKeyLess(_: void, lhs: TestElem, rhs: TestElem) bool {
    return lhs.key < rhs.key;
}

// A stable sort's output is uniquely determined by its input, so comparing
// against std.mem.sort element-for-element is an exact oracle.
fn expectMatchesStd(alloc: std.mem.Allocator, items: []const TestElem) !void {
    const expected = try alloc.dupe(TestElem, items);
    defer alloc.free(expected);
    const actual = try alloc.dupe(TestElem, items);
    defer alloc.free(actual);
    std.mem.sort(TestElem, expected, {}, testElemKeyLess);
    sort(TestElem, actual, {}, testElemKeyLess);
    try testing.expectEqualSlices(TestElem, expected, actual);
}

test "matches std.mem.sort across sizes, seeds, and key densities" {
    const alloc = testing.allocator;
    const sizes = [_]usize{ 0, 1, 2, 3, 5, 19, 20, 21, 40, 41, 100, 257, 1000 };
    const key_ranges = [_]u16{ 1, 2, 3, 16, 251, 65535 };
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (sizes) |n| {
        for (key_ranges) |range| {
            const items = try alloc.alloc(TestElem, n);
            defer alloc.free(items);
            for (items, 0..) |*item, i| {
                item.* = .{ .key = random.uintLessThan(u16, range), .seq = @intCast(i % 65535) };
            }
            try expectMatchesStd(alloc, items);
        }
    }
}

test "matches std.mem.sort on adversarial patterns" {
    const alloc = testing.allocator;
    const n: usize = 337;
    const items = try alloc.alloc(TestElem, n);
    defer alloc.free(items);

    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i), .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(n - 1 - i), .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i % 7), .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| item.* = .{ .key = 42, .seq = @intCast(i) };
    try expectMatchesStd(alloc, items);

    for (items, 0..) |*item, i| {
        const key: u16 = if (i < n / 2) @intCast(i) else @intCast(n - i);
        item.* = .{ .key = key, .seq = @intCast(i) };
    }
    try expectMatchesStd(alloc, items);
}

fn permuteAndCheck(alloc: std.mem.Allocator, items: []TestElem, k: usize) !void {
    if (k <= 1) {
        try expectMatchesStd(alloc, items);
        return;
    }
    for (0..k) |i| {
        try permuteAndCheck(alloc, items, k - 1);
        if (k % 2 == 0) {
            std.mem.swap(TestElem, &items[i], &items[k - 1]);
        } else {
            std.mem.swap(TestElem, &items[0], &items[k - 1]);
        }
    }
}

test "every permutation of duplicate-heavy small inputs matches std.mem.sort" {
    const alloc = testing.allocator;
    var n: usize = 1;
    while (n <= 6) : (n += 1) {
        const items = try alloc.alloc(TestElem, n);
        defer alloc.free(items);
        for (items, 0..) |*item, i| item.* = .{ .key = @intCast(i % 3), .seq = @intCast(i) };
        try permuteAndCheck(alloc, items, n);
    }
}

test "runtime context reaches the comparator" {
    const alloc = testing.allocator;
    const Pivot = struct { value: i32 };
    const distanceLess = struct {
        fn less(ctx: Pivot, lhs: i32, rhs: i32) bool {
            return @abs(lhs - ctx.value) < @abs(rhs - ctx.value);
        }
    }.less;
    var prng = std.Random.DefaultPrng.init(0xf00);
    const random = prng.random();
    const expected = try alloc.alloc(i32, 500);
    defer alloc.free(expected);
    for (expected) |*value| value.* = random.intRangeAtMost(i32, -1000, 1000);
    const actual = try alloc.dupe(i32, expected);
    defer alloc.free(actual);
    const pivot = Pivot{ .value = 37 };
    std.mem.sort(i32, expected, pivot, distanceLess);
    sort(i32, actual, pivot, distanceLess);
    try testing.expectEqualSlices(i32, expected, actual);
}

test "odd-sized elements sort correctly" {
    const alloc = testing.allocator;
    const lexLess = struct {
        fn less(_: void, lhs: [7]u8, rhs: [7]u8) bool {
            return std.mem.order(u8, &lhs, &rhs) == .lt;
        }
    }.less;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const expected = try alloc.alloc([7]u8, 300);
    defer alloc.free(expected);
    for (expected) |*elem| {
        random.bytes(elem);
        elem[0] %= 3;
    }
    const actual = try alloc.dupe([7]u8, expected);
    defer alloc.free(actual);
    std.mem.sort([7]u8, expected, {}, lexLess);
    sort([7]u8, actual, {}, lexLess);
    try testing.expectEqualSlices([7]u8, expected, actual);
}

test "slice elements sort by content with duplicates" {
    const alloc = testing.allocator;
    const strLess = struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less;
    const source = [_][]const u8{ "delta", "alpha", "charlie", "alpha", "bravo", "", "charlie", "alpha" };
    const expected = try alloc.dupe([]const u8, &source);
    defer alloc.free(expected);
    const actual = try alloc.dupe([]const u8, &source);
    defer alloc.free(actual);
    std.mem.sort([]const u8, expected, {}, strLess);
    sort([]const u8, actual, {}, strLess);
    try testing.expectEqualSlices([]const u8, expected, actual);
}
