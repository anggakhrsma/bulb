const std = @import("std");

pub const SleepError = error{
    Aborted,
    Overflow,
};

pub const AbortSignal = struct {
    ptr: ?*anyopaque = null,
    aborted_fn: *const fn (?*anyopaque) bool = neverAborted,

    pub fn aborted(self: AbortSignal) bool {
        return self.aborted_fn(self.ptr);
    }
};

pub const Sleeper = struct {
    ptr: ?*anyopaque = null,
    sleep_fn: *const fn (?*anyopaque, std.Io, u64) anyerror!void = ioSleep,

    pub fn sleepMs(self: Sleeper, io: std.Io, ms: u64, signal: ?AbortSignal) !void {
        if (signal) |abort_signal| {
            if (abort_signal.aborted()) return error.Aborted;
        }

        try self.sleep_fn(self.ptr, io, ms);

        if (signal) |abort_signal| {
            if (abort_signal.aborted()) return error.Aborted;
        }
    }
};

pub fn sleepMs(io: std.Io, ms: u64, signal: ?AbortSignal) !void {
    return (Sleeper{}).sleepMs(io, ms, signal);
}

fn ioSleep(_: ?*anyopaque, io: std.Io, ms: u64) !void {
    const milliseconds = std.math.cast(i64, ms) orelse return error.Overflow;
    return std.Io.sleep(io, std.Io.Duration.fromMilliseconds(milliseconds), .awake);
}

fn neverAborted(_: ?*anyopaque) bool {
    return false;
}

const Flag = struct {
    value: bool = false,

    fn aborted(ptr: ?*anyopaque) bool {
        const self: *Flag = @ptrCast(@alignCast(ptr.?));
        return self.value;
    }
};

const FakeSleeper = struct {
    calls: usize = 0,
    abort_during_sleep: ?*Flag = null,

    fn sleep(ptr: ?*anyopaque, _: std.Io, _: u64) !void {
        const self: *FakeSleeper = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        if (self.abort_during_sleep) |flag| flag.value = true;
    }
};

test "sleep rejects when abort signal is already aborted" {
    var flag: Flag = .{ .value = true };
    var fake: FakeSleeper = .{};
    const sleeper: Sleeper = .{ .ptr = &fake, .sleep_fn = FakeSleeper.sleep };

    try std.testing.expectError(
        error.Aborted,
        sleeper.sleepMs(std.testing.io, 25, .{ .ptr = &flag, .aborted_fn = Flag.aborted }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "sleep reports aborts that occur while sleeping" {
    var flag: Flag = .{};
    var fake: FakeSleeper = .{ .abort_during_sleep = &flag };
    const sleeper: Sleeper = .{ .ptr = &fake, .sleep_fn = FakeSleeper.sleep };

    try std.testing.expectError(
        error.Aborted,
        sleeper.sleepMs(std.testing.io, 25, .{ .ptr = &flag, .aborted_fn = Flag.aborted }),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}

test "sleep allows completion without abort signal" {
    var fake: FakeSleeper = .{};
    const sleeper: Sleeper = .{ .ptr = &fake, .sleep_fn = FakeSleeper.sleep };

    try sleeper.sleepMs(std.testing.io, 0, null);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
}
