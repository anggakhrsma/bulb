const std = @import("std");
const types = @import("../../types.zig");

pub const cancel_message = "Login cancelled";
pub const timeout_message = "Device flow timed out";
pub const slow_down_timeout_message =
    "Device flow timed out after one or more slow_down responses. This is often caused by clock drift in WSL or VM environments. Please sync or restart the VM clock and try again.";

const minimum_interval_ms: u64 = 1000;
const default_poll_interval_seconds: f64 = 5;
const slow_down_interval_increment_ms: u64 = 5000;

pub const FlowFailure = struct {
    allocator: std.mem.Allocator,
    message: []u8,

    pub fn deinit(self: *FlowFailure) void {
        self.allocator.free(self.message);
    }
};

pub fn FlowResult(comptime T: type) type {
    return union(enum) {
        complete: T,
        failed: FlowFailure,

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .failed => |*failure_value| failure_value.deinit(),
                .complete => {},
            }
        }
    };
}

pub fn PollResult(comptime T: type) type {
    return union(enum) {
        pending,
        slow_down,
        failed: []const u8,
        failed_owned: []u8,
        complete: T,
    };
}

pub fn Poller(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        poll: *const fn (*anyopaque, std.mem.Allocator) anyerror!PollResult(T),

        pub fn run(self: @This(), allocator: std.mem.Allocator) !PollResult(T) {
            return self.poll(self.ptr, allocator);
        }
    };
}

pub const Clock = struct {
    ptr: ?*anyopaque = null,
    now_ms: *const fn (?*anyopaque) i64 = systemNowMs,

    pub fn now(self: Clock) i64 {
        return self.now_ms(self.ptr);
    }
};

pub const Sleeper = struct {
    ptr: ?*anyopaque = null,
    sleep_ms: *const fn (?*anyopaque, u64, ?*types.AbortSignal) anyerror!void = systemSleepMs,

    pub fn sleep(self: Sleeper, millis: u64, signal: ?*types.AbortSignal) !void {
        try self.sleep_ms(self.ptr, millis, signal);
    }
};

pub fn PollOptions(comptime T: type) type {
    return struct {
        interval_seconds: ?f64 = null,
        expires_in_seconds: ?u64 = null,
        poller: Poller(T),
        signal: ?*types.AbortSignal = null,
        clock: Clock = .{},
        sleeper: Sleeper = .{},
    };
}

pub fn pollOAuthDeviceCodeFlow(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: PollOptions(T),
) !FlowResult(T) {
    const start_ms = options.clock.now();
    const deadline_ms = if (options.expires_in_seconds) |seconds|
        start_ms + saturatedMillisFromSeconds(seconds)
    else
        std.math.maxInt(i64);

    var interval_ms = pollIntervalMillis(options.interval_seconds);
    var slow_down_responses: u64 = 0;

    while (options.clock.now() < deadline_ms) {
        if (isAborted(options.signal)) {
            return .{ .failed = try failure(allocator, cancel_message) };
        }

        switch (try options.poller.run(allocator)) {
            .complete => |value| return .{ .complete = value },
            .failed => |message| return .{ .failed = try failure(allocator, message) },
            .failed_owned => |message| {
                defer allocator.free(message);
                return .{ .failed = try failure(allocator, message) };
            },
            .slow_down => {
                slow_down_responses += 1;
                interval_ms = @max(minimum_interval_ms, saturatingAdd(interval_ms, slow_down_interval_increment_ms));
            },
            .pending => {},
        }

        const now_ms = options.clock.now();
        if (now_ms >= deadline_ms) break;
        const remaining_ms: u64 = @intCast(deadline_ms - now_ms);
        const sleep_for = @min(interval_ms, remaining_ms);

        options.sleeper.sleep(sleep_for, options.signal) catch |err| {
            if (isAborted(options.signal)) {
                return .{ .failed = try failure(allocator, cancel_message) };
            }
            return err;
        };
    }

    return .{ .failed = try failure(
        allocator,
        if (slow_down_responses > 0) slow_down_timeout_message else timeout_message,
    ) };
}

pub fn failure(allocator: std.mem.Allocator, message: []const u8) !FlowFailure {
    return .{ .allocator = allocator, .message = try allocator.dupe(u8, message) };
}

fn pollIntervalMillis(interval_seconds: ?f64) u64 {
    const seconds = interval_seconds orelse default_poll_interval_seconds;
    if (!std.math.isFinite(seconds) or seconds < 0) return minimum_interval_ms;
    const millis_float = @floor(seconds * 1000);
    if (millis_float <= @as(f64, @floatFromInt(minimum_interval_ms))) return minimum_interval_ms;
    if (millis_float >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return std.math.maxInt(u64);
    return @intFromFloat(millis_float);
}

fn saturatedMillisFromSeconds(seconds: u64) i64 {
    const max_seconds: u64 = @intCast(@divFloor(std.math.maxInt(i64), 1000));
    if (seconds >= max_seconds) return std.math.maxInt(i64);
    return @intCast(seconds * 1000);
}

fn saturatingAdd(left: u64, right: u64) u64 {
    const result = @addWithOverflow(left, right);
    return if (result[1] != 0) std.math.maxInt(u64) else result[0];
}

fn isAborted(signal: ?*types.AbortSignal) bool {
    return if (signal) |abort_signal| abort_signal.isAborted() else false;
}

fn systemNowMs(_: ?*anyopaque) i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn systemSleepMs(_: ?*anyopaque, millis: u64, signal: ?*types.AbortSignal) !void {
    if (isAborted(signal)) return error.Aborted;
    if (millis > 0) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const capped_ms = std.math.cast(i64, millis) orelse std.math.maxInt(i64);
        try std.Io.sleep(io, .fromMilliseconds(capped_ms), .awake);
    }
    if (isAborted(signal)) return error.Aborted;
}

const FakeClock = struct {
    now_value: i64,

    fn now(ptr: ?*anyopaque) i64 {
        const self: *FakeClock = @ptrCast(@alignCast(ptr.?));
        return self.now_value;
    }
};

const FakeSleep = struct {
    allocator: std.mem.Allocator,
    clock: *FakeClock,
    delays: std.ArrayList(u64) = .empty,

    fn deinit(self: *FakeSleep) void {
        self.delays.deinit(self.allocator);
    }

    fn sleep(ptr: ?*anyopaque, millis: u64, signal: ?*types.AbortSignal) !void {
        if (isAborted(signal)) return error.Aborted;
        const self: *FakeSleep = @ptrCast(@alignCast(ptr.?));
        try self.delays.append(self.allocator, millis);
        self.clock.now_value += @intCast(millis);
        if (isAborted(signal)) return error.Aborted;
    }
};

const ImmediatePoll = struct {
    allocator: std.mem.Allocator,
    clock: *FakeClock,
    poll_times: std.ArrayList(i64) = .empty,

    fn deinit(self: *ImmediatePoll) void {
        self.poll_times.deinit(self.allocator);
    }

    fn poll(ptr: *anyopaque, _: std.mem.Allocator) anyerror!PollResult([]const u8) {
        const self: *ImmediatePoll = @ptrCast(@alignCast(ptr));
        try self.poll_times.append(self.allocator, self.clock.now_value);
        if (self.poll_times.items.len == 1) return .pending;
        return .{ .complete = "token" };
    }
};

test "OAuth device-code polling polls immediately and returns completed value" {
    const allocator = std.testing.allocator;
    var clock: FakeClock = .{ .now_value = 1_741_478_400_000 };
    var sleeper: FakeSleep = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();
    var poller_state: ImmediatePoll = .{ .allocator = allocator, .clock = &clock };
    defer poller_state.deinit();

    var result = try pollOAuthDeviceCodeFlow([]const u8, allocator, .{
        .interval_seconds = 2,
        .expires_in_seconds = 30,
        .poller = .{ .ptr = &poller_state, .poll = ImmediatePoll.poll },
        .clock = .{ .ptr = &clock, .now_ms = FakeClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = FakeSleep.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("token", result.complete);
    try std.testing.expectEqual(@as(usize, 2), poller_state.poll_times.items.len);
    try std.testing.expectEqual(@as(i64, 1_741_478_400_000), poller_state.poll_times.items[0]);
    try std.testing.expectEqual(@as(i64, 1_741_478_402_000), poller_state.poll_times.items[1]);
    try std.testing.expectEqual(@as(usize, 1), sleeper.delays.items.len);
    try std.testing.expectEqual(@as(u64, 2000), sleeper.delays.items[0]);
}

const PendingPoll = struct {
    fn poll(_: *anyopaque, _: std.mem.Allocator) anyerror!PollResult([]const u8) {
        return .pending;
    }
};

test "OAuth device-code polling cancels an in-flight wait" {
    const allocator = std.testing.allocator;
    var signal: types.AbortSignal = .{};
    signal.abort();
    var state: u8 = 0;
    var result = try pollOAuthDeviceCodeFlow([]const u8, allocator, .{
        .interval_seconds = 5,
        .expires_in_seconds = 30,
        .poller = .{ .ptr = &state, .poll = PendingPoll.poll },
        .signal = &signal,
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(cancel_message, result.failed.message);
}

const SlowDownPoll = struct {
    count: usize = 0,

    fn poll(ptr: *anyopaque, _: std.mem.Allocator) anyerror!PollResult([]const u8) {
        const self: *SlowDownPoll = @ptrCast(@alignCast(ptr));
        self.count += 1;
        return .slow_down;
    }
};

test "OAuth device-code polling applies slow_down timeout message" {
    const allocator = std.testing.allocator;
    var clock: FakeClock = .{ .now_value = 0 };
    var sleeper: FakeSleep = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();
    var poller_state: SlowDownPoll = .{};

    var result = try pollOAuthDeviceCodeFlow([]const u8, allocator, .{
        .interval_seconds = 1,
        .expires_in_seconds = 1,
        .poller = .{ .ptr = &poller_state, .poll = SlowDownPoll.poll },
        .clock = .{ .ptr = &clock, .now_ms = FakeClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = FakeSleep.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(slow_down_timeout_message, result.failed.message);
}
