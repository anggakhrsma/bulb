const std = @import("std");
const types = @import("../types.zig");

pub const CombinedAbortSignal = struct {
    signals: []const ?*const types.AbortSignal,

    pub fn isAborted(self: CombinedAbortSignal) bool {
        for (self.signals) |maybe_signal| {
            if (maybe_signal) |signal| {
                if (signal.isAborted()) return true;
            }
        }
        return false;
    }

    pub fn cleanup(_: CombinedAbortSignal) void {}
};

pub fn combineAbortSignals(signals: []const ?*const types.AbortSignal) CombinedAbortSignal {
    return .{ .signals = signals };
}

test "combined abort signal observes active inputs" {
    var first: types.AbortSignal = .{};
    var second: types.AbortSignal = .{};
    const combined = combineAbortSignals(&.{ &first, null, &second });

    try std.testing.expect(!combined.isAborted());
    second.abort();
    try std.testing.expect(combined.isAborted());
    combined.cleanup();
}

test "combined abort signal supports empty and pre-aborted inputs" {
    const empty = combineAbortSignals(&.{});
    try std.testing.expect(!empty.isAborted());

    var signal: types.AbortSignal = .{};
    signal.abortWithReason("timed out");
    const combined = combineAbortSignals(&.{&signal});
    try std.testing.expect(combined.isAborted());
    try std.testing.expectEqualStrings("timed out", signal.reason.?);
}
