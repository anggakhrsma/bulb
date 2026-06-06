const std = @import("std");

const ansi = @import("ansi.zig");
const shell = @import("shell.zig");
const output_accumulator = @import("tools/output_accumulator.zig");
const truncate = @import("tools/truncate.zig");

pub const AbortChecker = struct {
    ptr: ?*anyopaque = null,
    check_fn: *const fn (?*anyopaque) anyerror!void = defaultAbortCheck,
    is_aborted_fn: *const fn (?*anyopaque) bool = defaultIsAborted,

    pub fn throwIfAborted(self: AbortChecker) !void {
        return self.check_fn(self.ptr);
    }

    pub fn isAborted(self: AbortChecker) bool {
        return self.is_aborted_fn(self.ptr);
    }
};

pub const BashDataCallback = struct {
    ptr: ?*anyopaque = null,
    callback_fn: *const fn (?*anyopaque, []const u8) anyerror!void = defaultDataCallback,

    pub fn call(self: BashDataCallback, data: []const u8) !void {
        return self.callback_fn(self.ptr, data);
    }
};

pub const BashExecOptions = struct {
    on_data: BashDataCallback,
    abort_checker: AbortChecker = .{},
    timeout_seconds: ?u64 = null,
    env: ?*const std.process.Environ.Map = null,
};

pub const BashExecResult = struct {
    exit_code: ?i32,
};

pub const BashOperations = struct {
    ptr: ?*anyopaque = null,
    exec_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        std.Io,
        []const u8,
        []const u8,
        BashExecOptions,
    ) anyerror!BashExecResult,

    pub fn exec(
        self: BashOperations,
        allocator: std.mem.Allocator,
        io: std.Io,
        command: []const u8,
        cwd: []const u8,
        options: BashExecOptions,
    ) !BashExecResult {
        return self.exec_fn(self.ptr, allocator, io, command, cwd, options);
    }
};

pub const BashExecutorOptions = struct {
    on_chunk: ?BashDataCallback = null,
    abort_checker: AbortChecker = .{},
};

pub const BashResult = struct {
    output: []u8,
    exit_code: ?i32,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]u8 = null,

    pub fn deinit(self: *BashResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub fn executeBashWithOperationsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    cwd: []const u8,
    operations: BashOperations,
    options: BashExecutorOptions,
) !BashResult {
    var accumulator = try output_accumulator.OutputAccumulator.init(allocator, io, .{
        .max_lines = truncate.DEFAULT_MAX_LINES,
        .max_bytes = truncate.DEFAULT_MAX_BYTES,
        .temp_file_prefix = "bulb-bash",
    });
    defer accumulator.deinit();

    var context: ExecutorDataContext = .{
        .allocator = allocator,
        .io = io,
        .accumulator = &accumulator,
        .on_chunk = options.on_chunk,
    };

    const exec_result = operations.exec(allocator, io, command, cwd, .{
        .on_data = .{ .ptr = &context, .callback_fn = ExecutorDataContext.onData },
        .abort_checker = options.abort_checker,
    }) catch |err| {
        if (options.abort_checker.isAborted() or err == error.Aborted) {
            return finishCancelledResult(allocator, &accumulator);
        }
        return err;
    };

    try accumulator.finish();
    var snapshot = try accumulator.snapshot(true);
    defer snapshot.deinit(allocator);
    accumulator.closeTempFile();

    return .{
        .output = try allocator.dupe(u8, snapshot.content()),
        .exit_code = exec_result.exit_code,
        .cancelled = false,
        .truncated = snapshot.truncation.truncated,
        .full_output_path = if (snapshot.full_output_path) |path| try allocator.dupe(u8, path) else null,
    };
}

fn finishCancelledResult(
    allocator: std.mem.Allocator,
    accumulator: *output_accumulator.OutputAccumulator,
) !BashResult {
    try accumulator.finish();
    var snapshot = try accumulator.snapshot(true);
    defer snapshot.deinit(allocator);
    accumulator.closeTempFile();

    return .{
        .output = try allocator.dupe(u8, snapshot.content()),
        .exit_code = null,
        .cancelled = true,
        .truncated = snapshot.truncation.truncated,
        .full_output_path = if (snapshot.full_output_path) |path| try allocator.dupe(u8, path) else null,
    };
}

const ExecutorDataContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    accumulator: *output_accumulator.OutputAccumulator,
    on_chunk: ?BashDataCallback,

    fn onData(ptr: ?*anyopaque, data: []const u8) !void {
        const self: *ExecutorDataContext = @ptrCast(@alignCast(ptr.?));
        const stripped = try ansi.stripAnsiAlloc(self.allocator, data);
        defer self.allocator.free(stripped);
        const sanitized = try shell.sanitizeBinaryOutputAlloc(self.allocator, stripped);
        defer self.allocator.free(sanitized);
        const normalized = try removeCarriageReturnsAlloc(self.allocator, sanitized);
        defer self.allocator.free(normalized);

        try self.accumulator.append(normalized);
        if (self.on_chunk) |callback| try callback.call(normalized);
    }
};

fn removeCarriageReturnsAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return allocator.dupe(u8, text);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (text) |byte| {
        if (byte != '\r') try output.append(allocator, byte);
    }
    return output.toOwnedSlice(allocator);
}

fn defaultAbortCheck(_: ?*anyopaque) !void {}
fn defaultIsAborted(_: ?*anyopaque) bool {
    return false;
}
fn defaultDataCallback(_: ?*anyopaque, _: []const u8) !void {}

const FakeOperations = struct {
    data: []const []const u8,
    exit_code: ?i32 = 0,
    abort: bool = false,

    fn exec(
        ptr: ?*anyopaque,
        _: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
        _: []const u8,
        options: BashExecOptions,
    ) !BashExecResult {
        const self: *FakeOperations = @ptrCast(@alignCast(ptr.?));
        for (self.data) |chunk| try options.on_data.call(chunk);
        if (self.abort) return error.Aborted;
        return .{ .exit_code = self.exit_code };
    }
};

const ChunkCollector = struct {
    chunks: std.ArrayList(u8) = .empty,

    fn onChunk(ptr: ?*anyopaque, data: []const u8) !void {
        const self: *ChunkCollector = @ptrCast(@alignCast(ptr.?));
        try self.chunks.appendSlice(std.testing.allocator, data);
    }
};

test "executeBashWithOperations sanitizes output and streams chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const chunks = [_][]const u8{"\x1b[31mred\x1b[0m\r\n"};
    var fake: FakeOperations = .{ .data = &chunks };
    var collector: ChunkCollector = .{};
    defer collector.chunks.deinit(allocator);

    var result = try executeBashWithOperationsAlloc(
        allocator,
        io,
        "printf red",
        "/tmp",
        .{ .ptr = &fake, .exec_fn = FakeOperations.exec },
        .{ .on_chunk = .{ .ptr = &collector, .callback_fn = ChunkCollector.onChunk } },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(?i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("red\n", result.output);
    try std.testing.expectEqualStrings("red\n", collector.chunks.items);
}

test "executeBashWithOperations persists full output when line truncation wins" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var generated: std.ArrayList(u8) = .empty;
    defer generated.deinit(allocator);
    for (1..3001) |index| {
        try generated.print(allocator, "{d}\n", .{index});
    }
    const chunks = [_][]const u8{generated.items};
    var fake: FakeOperations = .{ .data = &chunks };

    var result = try executeBashWithOperationsAlloc(
        allocator,
        io,
        "seq 3000",
        "/tmp",
        .{ .ptr = &fake, .exec_fn = FakeOperations.exec },
        .{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.truncated);
    try std.testing.expect(result.full_output_path != null);
    defer std.Io.Dir.cwd().deleteFile(io, result.full_output_path.?) catch {};
    try std.testing.expect(std.mem.indexOf(u8, result.output, "2001\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "3000") != null);
}
