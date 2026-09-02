const std = @import("std");

/// Incrementally estimates raw model or request text without making the result
/// depend on transport chunk boundaries.
pub const StreamingEstimator = struct {
    settled_tokens: u64 = 0,
    span_bytes: u64 = 0,

    pub fn consume(self: *StreamingEstimator, text: []const u8) void {
        for (text) |byte| {
            if (std.ascii.isWhitespace(byte)) {
                self.finishSpan();
            } else {
                self.span_bytes +|= 1;
            }
        }
    }

    pub fn estimate(self: StreamingEstimator) u64 {
        return self.settled_tokens +| estimateSpan(self.span_bytes);
    }

    fn finishSpan(self: *StreamingEstimator) void {
        self.settled_tokens +|= estimateSpan(self.span_bytes);
        self.span_bytes = 0;
    }

    fn estimateSpan(span_bytes: u64) u64 {
        return span_bytes / 4 + @intFromBool(span_bytes % 4 != 0);
    }
};
