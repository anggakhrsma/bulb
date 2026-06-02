const std = @import("std");

pub const raw_stdout_retry_delay_ms: u64 = 10;
pub const RAW_STDOUT_RETRY_DELAY_MS: u64 = raw_stdout_retry_delay_ms;

pub const Sink = struct {
    ptr: ?*anyopaque = null,
    write_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    flush_fn: *const fn (?*anyopaque) anyerror!void = noopFlush,

    pub fn write(self: Sink, text: []const u8) !void {
        try self.write_fn(self.ptr, text);
    }

    pub fn flush(self: Sink) !void {
        try self.flush_fn(self.ptr);
    }
};

pub const Sleeper = struct {
    ptr: ?*anyopaque = null,
    sleep_fn: *const fn (?*anyopaque, u64) anyerror!void = systemSleepMs,

    pub fn sleep(self: Sleeper, delay_ms: u64) !void {
        try self.sleep_fn(self.ptr, delay_ms);
    }
};

pub const OutputGuardOptions = struct {
    retry_delay_ms: u64 = raw_stdout_retry_delay_ms,
    sleeper: Sleeper = .{},
};

pub const OutputGuard = struct {
    raw_stdout: Sink,
    raw_stderr: Sink,
    stdout_taken_over: bool = false,
    options: OutputGuardOptions = .{},

    pub fn init(raw_stdout: Sink, raw_stderr: Sink, options: OutputGuardOptions) OutputGuard {
        return .{
            .raw_stdout = raw_stdout,
            .raw_stderr = raw_stderr,
            .options = options,
        };
    }

    pub fn takeOverStdout(self: *OutputGuard) void {
        if (self.stdout_taken_over) return;
        self.stdout_taken_over = true;
    }

    pub fn restoreStdout(self: *OutputGuard) void {
        if (!self.stdout_taken_over) return;
        self.stdout_taken_over = false;
    }

    pub fn isStdoutTakenOver(self: OutputGuard) bool {
        return self.stdout_taken_over;
    }

    pub fn stdoutSink(self: OutputGuard) Sink {
        return if (self.stdout_taken_over) self.raw_stderr else self.raw_stdout;
    }

    pub fn stderrSink(self: OutputGuard) Sink {
        return self.raw_stderr;
    }

    pub fn writeStdout(self: *OutputGuard, text: []const u8) !void {
        try self.stdoutSink().write(text);
    }

    pub fn writeStderr(self: *OutputGuard, text: []const u8) !void {
        try self.raw_stderr.write(text);
    }

    pub fn writeRawStdout(self: *OutputGuard, text: []const u8) !void {
        if (text.len == 0) return;
        try self.writeRawStdoutChunk(text);
    }

    pub fn waitForRawStdoutBackpressure(self: *OutputGuard) !void {
        _ = self;
    }

    pub fn flushRawStdout(self: *OutputGuard) !void {
        try self.waitForRawStdoutBackpressure();
        try self.writeRawStdoutChunk("");
        try self.raw_stdout.flush();
    }

    fn writeRawStdoutChunk(self: *OutputGuard, text: []const u8) !void {
        while (true) {
            self.raw_stdout.write(text) catch |err| {
                if (!isRetryableRawStdoutError(err)) return err;
                try self.options.sleeper.sleep(self.options.retry_delay_ms);
                continue;
            };
            return;
        }
    }
};

pub fn sinkFromWriter(writer: *std.Io.Writer) Sink {
    return .{
        .ptr = writer,
        .write_fn = writerSinkWrite,
        .flush_fn = writerSinkFlush,
    };
}

pub fn isRetryableRawStdoutError(err: anyerror) bool {
    return err == error.NoBufferSpace or err == error.SystemResources or err == error.WouldBlock;
}

fn writerSinkWrite(ptr: ?*anyopaque, text: []const u8) anyerror!void {
    const writer: *std.Io.Writer = @ptrCast(@alignCast(ptr.?));
    try writer.writeAll(text);
}

fn writerSinkFlush(ptr: ?*anyopaque) anyerror!void {
    const writer: *std.Io.Writer = @ptrCast(@alignCast(ptr.?));
    try writer.flush();
}

fn noopFlush(_: ?*anyopaque) anyerror!void {}

fn systemSleepMs(_: ?*anyopaque, delay_ms: u64) anyerror!void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const duration_ms = std.math.cast(i64, delay_ms) orelse std.math.maxInt(i64);
    try std.Io.sleep(io, .fromMilliseconds(duration_ms), .awake);
}

const RecordingSink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    write_count: usize = 0,
    flush_count: usize = 0,
    retry_failures_remaining: usize = 0,
    fail_with_write_failed: bool = false,

    fn init(allocator: std.mem.Allocator) RecordingSink {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RecordingSink) void {
        self.bytes.deinit(self.allocator);
    }

    fn sink(self: *RecordingSink) Sink {
        return .{
            .ptr = self,
            .write_fn = write,
            .flush_fn = flush,
        };
    }

    fn write(ptr: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr.?));
        self.write_count += 1;
        if (self.retry_failures_remaining > 0) {
            self.retry_failures_remaining -= 1;
            return error.WouldBlock;
        }
        if (self.fail_with_write_failed) return error.WriteFailed;
        try self.bytes.appendSlice(self.allocator, text);
    }

    fn flush(ptr: ?*anyopaque) anyerror!void {
        const self: *RecordingSink = @ptrCast(@alignCast(ptr.?));
        self.flush_count += 1;
    }
};

const TestSleeper = struct {
    calls: usize = 0,
    last_delay_ms: u64 = 0,

    fn sleeper(self: *TestSleeper) Sleeper {
        return .{
            .ptr = self,
            .sleep_fn = sleep,
        };
    }

    fn sleep(ptr: ?*anyopaque, delay_ms: u64) anyerror!void {
        const self: *TestSleeper = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        self.last_delay_ms = delay_ms;
    }
};

test "stdout takeover routes guarded stdout to stderr while preserving raw stdout" {
    const allocator = std.testing.allocator;
    var stdout = RecordingSink.init(allocator);
    defer stdout.deinit();
    var stderr = RecordingSink.init(allocator);
    defer stderr.deinit();

    var guard = OutputGuard.init(stdout.sink(), stderr.sink(), .{});
    try guard.writeStdout("before ");
    guard.takeOverStdout();
    try std.testing.expect(guard.isStdoutTakenOver());
    try guard.writeStdout("guarded ");
    try guard.writeRawStdout("raw ");
    try guard.writeStderr("err ");
    guard.restoreStdout();
    try std.testing.expect(!guard.isStdoutTakenOver());
    try guard.writeStdout("after");

    try std.testing.expectEqualStrings("before raw after", stdout.bytes.items);
    try std.testing.expectEqualStrings("guarded err ", stderr.bytes.items);
}

test "takeover and restore are idempotent" {
    const allocator = std.testing.allocator;
    var stdout = RecordingSink.init(allocator);
    defer stdout.deinit();
    var stderr = RecordingSink.init(allocator);
    defer stderr.deinit();

    var guard = OutputGuard.init(stdout.sink(), stderr.sink(), .{});
    guard.takeOverStdout();
    guard.takeOverStdout();
    try guard.writeStdout("one");
    guard.restoreStdout();
    guard.restoreStdout();
    try guard.writeStdout("two");

    try std.testing.expectEqualStrings("two", stdout.bytes.items);
    try std.testing.expectEqualStrings("one", stderr.bytes.items);
}

test "raw stdout retries retryable backpressure errors" {
    const allocator = std.testing.allocator;
    var stdout = RecordingSink.init(allocator);
    defer stdout.deinit();
    stdout.retry_failures_remaining = 2;
    var stderr = RecordingSink.init(allocator);
    defer stderr.deinit();
    var sleeper = TestSleeper{};

    var guard = OutputGuard.init(stdout.sink(), stderr.sink(), .{
        .retry_delay_ms = 7,
        .sleeper = sleeper.sleeper(),
    });
    try guard.writeRawStdout("raw");

    try std.testing.expectEqual(@as(usize, 3), stdout.write_count);
    try std.testing.expectEqual(@as(usize, 2), sleeper.calls);
    try std.testing.expectEqual(@as(u64, 7), sleeper.last_delay_ms);
    try std.testing.expectEqualStrings("raw", stdout.bytes.items);
}

test "raw stdout skips empty writes but flush writes an empty chunk" {
    const allocator = std.testing.allocator;
    var stdout = RecordingSink.init(allocator);
    defer stdout.deinit();
    var stderr = RecordingSink.init(allocator);
    defer stderr.deinit();

    var guard = OutputGuard.init(stdout.sink(), stderr.sink(), .{});
    try guard.writeRawStdout("");
    try std.testing.expectEqual(@as(usize, 0), stdout.write_count);
    try guard.flushRawStdout();

    try std.testing.expectEqual(@as(usize, 1), stdout.write_count);
    try std.testing.expectEqual(@as(usize, 1), stdout.flush_count);
    try std.testing.expectEqualStrings("", stdout.bytes.items);
}

test "raw stdout propagates non retryable write errors" {
    const allocator = std.testing.allocator;
    var stdout = RecordingSink.init(allocator);
    defer stdout.deinit();
    stdout.fail_with_write_failed = true;
    var stderr = RecordingSink.init(allocator);
    defer stderr.deinit();
    var sleeper = TestSleeper{};

    var guard = OutputGuard.init(stdout.sink(), stderr.sink(), .{
        .sleeper = sleeper.sleeper(),
    });

    try std.testing.expectError(error.WriteFailed, guard.writeRawStdout("raw"));
    try std.testing.expectEqual(@as(usize, 0), sleeper.calls);
}
