const std = @import("std");

const truncate = @import("truncate.zig");
const types = @import("types.zig");

const Result = types.Result;

pub const ShellChunkCallback = struct {
    ptr: ?*anyopaque = null,
    callback_fn: *const fn (?*anyopaque, []const u8) anyerror!void = noopShellChunkCallback,

    pub fn call(self: ShellChunkCallback, chunk: []const u8) !void {
        try self.callback_fn(self.ptr, chunk);
    }
};

pub const ShellCaptureOptions = struct {
    cwd: ?[]const u8 = null,
    env: []const types.EnvVar = &.{},
    timeout_seconds: ?u64 = null,
    abort_signal: ?*const types.AbortSignal = null,
    on_chunk: ?ShellChunkCallback = null,
};

pub const ShellCaptureResult = struct {
    output: []u8,
    exit_code: ?i32,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]u8 = null,

    pub fn deinit(self: *ShellCaptureResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub fn sanitizeBinaryOutputAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const first = input[index];
        const width = std.unicode.utf8ByteSequenceLength(first) catch {
            index += 1;
            continue;
        };
        if (index + width > input.len) break;
        const slice = input[index .. index + width];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            index += 1;
            continue;
        };
        index += width;

        if (codepoint == 0x09 or codepoint == 0x0a or codepoint == 0x0d) {
            try output.appendSlice(allocator, slice);
            continue;
        }
        if (codepoint <= 0x1f) continue;
        if (codepoint >= 0xfff9 and codepoint <= 0xfffb) continue;
        try output.appendSlice(allocator, slice);
    }

    return output.toOwnedSlice(allocator);
}

pub fn executeShellWithCaptureAlloc(
    allocator: std.mem.Allocator,
    env: types.ExecutionEnv,
    command: []const u8,
    options: ShellCaptureOptions,
) !Result(ShellCaptureResult, types.ExecutionError) {
    var context: CaptureContext = .{
        .allocator = allocator,
        .env = env,
        .options = options,
    };
    defer context.deinit();

    const capture_callback = types.ExecutionChunkCallback{
        .ptr = &context,
        .callback_fn = CaptureContext.onExecutionChunk,
    };

    var exec_result = env.exec(command, .{
        .cwd = options.cwd,
        .env = options.env,
        .timeout_seconds = options.timeout_seconds,
        .abort_signal = options.abort_signal,
        .on_stdout = capture_callback,
        .on_stderr = capture_callback,
    }) catch |exec_error| {
        return .{ .err = executionErrorFromError(exec_error) };
    };
    defer switch (exec_result) {
        .ok => |*value| value.deinit(allocator),
        .err => {},
    };

    const tail_output = try context.joinOutputChunksAlloc();
    defer allocator.free(tail_output);

    var truncation_result = try truncate.truncateTailAlloc(allocator, tail_output, .{});
    defer truncation_result.deinit(allocator);

    if (truncation_result.truncated and context.full_output_path == null and context.capture_error == null) {
        if (try context.ensureFullOutputFile(tail_output)) |capture_error| {
            context.capture_error = capture_error;
        }
    }

    if (context.capture_error) |capture_error| {
        return .{ .err = capture_error };
    }

    const output = if (truncation_result.truncated)
        try allocator.dupe(u8, truncation_result.content)
    else
        try allocator.dupe(u8, tail_output);
    errdefer allocator.free(output);

    const full_output_path = context.full_output_path;
    context.full_output_path = null;
    errdefer if (full_output_path) |path| allocator.free(path);

    switch (exec_result) {
        .err => |execution_error| {
            if (execution_error.code == .aborted or isAborted(options.abort_signal)) {
                return .{ .ok = .{
                    .output = output,
                    .exit_code = null,
                    .cancelled = true,
                    .truncated = truncation_result.truncated,
                    .full_output_path = full_output_path,
                } };
            }
            allocator.free(output);
            if (full_output_path) |path| allocator.free(path);
            return .{ .err = execution_error };
        },
        .ok => |value| {
            const cancelled = isAborted(options.abort_signal);
            return .{ .ok = .{
                .output = output,
                .exit_code = if (cancelled) null else value.exit_code,
                .cancelled = cancelled,
                .truncated = truncation_result.truncated,
                .full_output_path = full_output_path,
            } };
        },
    }
}

const CaptureContext = struct {
    allocator: std.mem.Allocator,
    env: types.ExecutionEnv,
    options: ShellCaptureOptions,
    output_chunks: std.ArrayList([]u8) = .empty,
    output_bytes: usize = 0,
    total_bytes: usize = 0,
    full_output_path: ?[]u8 = null,
    capture_error: ?types.ExecutionError = null,

    fn deinit(self: *CaptureContext) void {
        for (self.output_chunks.items) |chunk| self.allocator.free(chunk);
        self.output_chunks.deinit(self.allocator);
        if (self.full_output_path) |path| self.allocator.free(path);
    }

    fn onExecutionChunk(ptr: ?*anyopaque, chunk: []const u8) !void {
        const self: *CaptureContext = @ptrCast(@alignCast(ptr.?));
        self.onChunk(chunk) catch |err| {
            self.capture_error = executionErrorFromError(err);
        };
    }

    fn onChunk(self: *CaptureContext, chunk: []const u8) !void {
        if (self.capture_error != null) return;

        self.total_bytes += chunk.len;

        const sanitized_raw = try sanitizeBinaryOutputAlloc(self.allocator, chunk);
        defer self.allocator.free(sanitized_raw);

        var sanitized = try removeCarriageReturnsAlloc(self.allocator, sanitized_raw);
        errdefer self.allocator.free(sanitized);

        if (self.total_bytes > truncate.DEFAULT_MAX_BYTES and self.full_output_path == null) {
            const initial = try self.joinOutputChunksWithSuffixAlloc(sanitized);
            defer self.allocator.free(initial);
            if (try self.ensureFullOutputFile(initial)) |capture_error| {
                self.capture_error = capture_error;
                return;
            }
        } else {
            if (try self.appendFullOutput(sanitized)) |capture_error| {
                self.capture_error = capture_error;
                return;
            }
        }

        try self.output_chunks.append(self.allocator, sanitized);
        self.output_bytes += sanitized.len;
        sanitized = &.{};

        const max_output_bytes = truncate.DEFAULT_MAX_BYTES * 2;
        while (self.output_bytes > max_output_bytes and self.output_chunks.items.len > 1) {
            const removed = self.output_chunks.orderedRemove(0);
            self.output_bytes -= removed.len;
            self.allocator.free(removed);
        }

        if (self.options.on_chunk) |callback| {
            const latest = self.output_chunks.items[self.output_chunks.items.len - 1];
            callback.call(latest) catch |err| {
                self.capture_error = executionErrorFromError(err);
            };
        }
    }

    fn appendFullOutput(self: *CaptureContext, text: []const u8) !?types.ExecutionError {
        const path = self.full_output_path orelse return null;
        const append_result = self.env.appendFile(path, text, self.options.abort_signal) catch |err| {
            return executionErrorFromError(err);
        };
        switch (append_result) {
            .ok => {},
            .err => |file_error| return fileErrorToExecutionError(file_error),
        }
        return null;
    }

    fn ensureFullOutputFile(self: *CaptureContext, initial_content: []const u8) !?types.ExecutionError {
        if (self.full_output_path != null) return null;
        const temp_file = self.env.createTempFile(self.allocator, .{
            .prefix = "bash-",
            .suffix = ".log",
            .abort_signal = self.options.abort_signal,
        }) catch |err| {
            return executionErrorFromError(err);
        };
        const path = switch (temp_file) {
            .ok => |value| value,
            .err => |file_error| return fileErrorToExecutionError(file_error),
        };
        errdefer self.allocator.free(path);

        const append_result = self.env.appendFile(path, initial_content, self.options.abort_signal) catch |err| {
            return executionErrorFromError(err);
        };
        switch (append_result) {
            .ok => {},
            .err => |file_error| return fileErrorToExecutionError(file_error),
        }

        self.full_output_path = path;
        return null;
    }

    fn joinOutputChunksAlloc(self: *CaptureContext) ![]u8 {
        var total_len: usize = 0;
        for (self.output_chunks.items) |chunk| total_len += chunk.len;

        const joined = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (self.output_chunks.items) |chunk| {
            @memcpy(joined[offset .. offset + chunk.len], chunk);
            offset += chunk.len;
        }
        return joined;
    }

    fn joinOutputChunksWithSuffixAlloc(self: *CaptureContext, suffix: []const u8) ![]u8 {
        var total_len: usize = suffix.len;
        for (self.output_chunks.items) |chunk| total_len += chunk.len;

        const joined = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (self.output_chunks.items) |chunk| {
            @memcpy(joined[offset .. offset + chunk.len], chunk);
            offset += chunk.len;
        }
        @memcpy(joined[offset .. offset + suffix.len], suffix);
        return joined;
    }
};

fn removeCarriageReturnsAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, text.len);
    errdefer allocator.free(output);
    var write_index: usize = 0;
    for (text) |byte| {
        if (byte == '\r') continue;
        output[write_index] = byte;
        write_index += 1;
    }
    return allocator.realloc(output, write_index);
}

fn isAborted(signal: ?*const types.AbortSignal) bool {
    return if (signal) |value| value.isAborted() else false;
}

fn executionErrorFromError(err: anyerror) types.ExecutionError {
    return .{ .code = .unknown, .message = @errorName(err) };
}

fn fileErrorToExecutionError(file_error: types.FileError) types.ExecutionError {
    return .{ .code = if (file_error.code == .aborted) .aborted else .unknown, .message = file_error.message };
}

fn noopShellChunkCallback(_: ?*anyopaque, _: []const u8) !void {}

const FakeExecutionEnv = struct {
    allocator: std.mem.Allocator,
    stdout_chunks: []const []const u8 = &.{},
    stderr_chunks: []const []const u8 = &.{},
    exec_error: ?types.ExecutionError = null,
    exit_code: i32 = 0,
    full_output: std.ArrayList(u8) = .empty,
    commands: std.ArrayList([]u8) = .empty,
    append_error: ?types.FileError = null,
    temp_error: ?types.FileError = null,

    fn init(allocator: std.mem.Allocator) FakeExecutionEnv {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakeExecutionEnv) void {
        self.full_output.deinit(self.allocator);
        for (self.commands.items) |command| self.allocator.free(command);
        self.commands.deinit(self.allocator);
    }

    fn env(self: *FakeExecutionEnv) types.ExecutionEnv {
        return .{
            .ptr = self,
            .cwd = "/tmp",
            .exec_fn = exec,
            .append_file_fn = appendFile,
            .create_temp_file_fn = createTempFile,
        };
    }

    fn exec(
        ptr: ?*anyopaque,
        command: []const u8,
        options: types.ExecutionEnvExecOptions,
    ) !Result(types.ExecutionEnvExecResult, types.ExecutionError) {
        const self: *FakeExecutionEnv = @ptrCast(@alignCast(ptr.?));
        try self.commands.append(self.allocator, try self.allocator.dupe(u8, command));

        if (options.on_stdout) |callback| {
            for (self.stdout_chunks) |chunk| try callback.call(chunk);
        }
        if (options.on_stderr) |callback| {
            for (self.stderr_chunks) |chunk| try callback.call(chunk);
        }
        if (self.exec_error) |execution_error| return .{ .err = execution_error };
        return .{ .ok = .{ .exit_code = self.exit_code } };
    }

    fn appendFile(
        ptr: ?*anyopaque,
        _: []const u8,
        content: []const u8,
        _: ?*const types.AbortSignal,
    ) !Result(void, types.FileError) {
        const self: *FakeExecutionEnv = @ptrCast(@alignCast(ptr.?));
        if (self.append_error) |file_error| return .{ .err = file_error };
        try self.full_output.appendSlice(self.allocator, content);
        return .{ .ok = {} };
    }

    fn createTempFile(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        options: types.CreateTempFileOptions,
    ) !Result([]u8, types.FileError) {
        const self: *FakeExecutionEnv = @ptrCast(@alignCast(ptr.?));
        if (self.temp_error) |file_error| return .{ .err = file_error };
        const path = try std.fmt.allocPrint(allocator, "/tmp/{s}0{s}", .{ options.prefix, options.suffix });
        return .{ .ok = path };
    }
};

const ChunkRecorder = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    fail: bool = false,

    fn init(allocator: std.mem.Allocator) ChunkRecorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ChunkRecorder) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
    }

    fn callback(self: *ChunkRecorder) ShellChunkCallback {
        return .{ .ptr = self, .callback_fn = onChunk };
    }

    fn onChunk(ptr: ?*anyopaque, chunk: []const u8) !void {
        const self: *ChunkRecorder = @ptrCast(@alignCast(ptr.?));
        if (self.fail) return error.CallbackFailed;
        try self.chunks.append(self.allocator, try self.allocator.dupe(u8, chunk));
    }
};

test "agent shell output sanitizes binary controls like Pi" {
    const allocator = std.testing.allocator;

    const sanitized = try sanitizeBinaryOutputAlloc(allocator, "a\x00b\tc\n\rd\x1fe\u{fff9}f🙂");
    defer allocator.free(sanitized);

    try std.testing.expectEqualStrings("ab\tc\n\rdef🙂", sanitized);
}

test "agent shell capture merges stdout and stderr with sanitized chunks" {
    const allocator = std.testing.allocator;

    const stdout_chunks = [_][]const u8{ "a\rb\x00", "c" };
    const stderr_chunks = [_][]const u8{"\nd"};
    var fake = FakeExecutionEnv.init(allocator);
    defer fake.deinit();
    fake.stdout_chunks = &stdout_chunks;
    fake.stderr_chunks = &stderr_chunks;
    fake.exit_code = 7;

    var recorder = ChunkRecorder.init(allocator);
    defer recorder.deinit();

    var result = try executeShellWithCaptureAlloc(allocator, fake.env(), "printf test", .{
        .on_chunk = recorder.callback(),
    });
    defer switch (result) {
        .ok => |*capture| capture.deinit(allocator),
        .err => {},
    };

    const capture = result.ok;
    try std.testing.expectEqualStrings("abc\nd", capture.output);
    try std.testing.expectEqual(@as(?i32, 7), capture.exit_code);
    try std.testing.expect(!capture.cancelled);
    try std.testing.expect(!capture.truncated);
    try std.testing.expect(capture.full_output_path == null);
    try std.testing.expectEqual(@as(usize, 3), recorder.chunks.items.len);
    try std.testing.expectEqualStrings("ab", recorder.chunks.items[0]);
    try std.testing.expectEqualStrings("c", recorder.chunks.items[1]);
    try std.testing.expectEqualStrings("\nd", recorder.chunks.items[2]);
}

test "agent shell capture spills large output to a full output file" {
    const allocator = std.testing.allocator;

    const large = try repeatedLinesAlloc(allocator, "line\n", 15_000);
    defer allocator.free(large);

    const stdout_chunks = [_][]const u8{large};
    var fake = FakeExecutionEnv.init(allocator);
    defer fake.deinit();
    fake.stdout_chunks = &stdout_chunks;

    var result = try executeShellWithCaptureAlloc(allocator, fake.env(), "yes line | head -n 15000", .{});
    defer switch (result) {
        .ok => |*capture| capture.deinit(allocator),
        .err => {},
    };

    const capture = result.ok;
    try std.testing.expect(capture.truncated);
    try std.testing.expect(capture.full_output_path != null);
    try std.testing.expect(fake.full_output.items.len > capture.output.len);
    try std.testing.expect(countScalar(fake.full_output.items, '\n') > 10_000);
}

test "agent shell capture creates full output file for line-only truncation" {
    const allocator = std.testing.allocator;

    const many_short_lines = try repeatedLinesAlloc(allocator, "x\n", truncate.DEFAULT_MAX_LINES + 10);
    defer allocator.free(many_short_lines);

    const stdout_chunks = [_][]const u8{many_short_lines};
    var fake = FakeExecutionEnv.init(allocator);
    defer fake.deinit();
    fake.stdout_chunks = &stdout_chunks;

    var result = try executeShellWithCaptureAlloc(allocator, fake.env(), "printf lines", .{});
    defer switch (result) {
        .ok => |*capture| capture.deinit(allocator),
        .err => {},
    };

    const capture = result.ok;
    try std.testing.expect(capture.truncated);
    try std.testing.expect(capture.full_output_path != null);
    try std.testing.expectEqualStrings(many_short_lines, fake.full_output.items);
    try std.testing.expect(capture.output.len < fake.full_output.items.len);
}

test "agent shell capture maps aborted execution to cancelled result" {
    const allocator = std.testing.allocator;

    const stdout_chunks = [_][]const u8{"partial"};
    var fake = FakeExecutionEnv.init(allocator);
    defer fake.deinit();
    fake.stdout_chunks = &stdout_chunks;
    fake.exec_error = .{ .code = .aborted, .message = "aborted" };

    var result = try executeShellWithCaptureAlloc(allocator, fake.env(), "sleep 5", .{});
    defer switch (result) {
        .ok => |*capture| capture.deinit(allocator),
        .err => {},
    };

    const capture = result.ok;
    try std.testing.expectEqualStrings("partial", capture.output);
    try std.testing.expect(capture.exit_code == null);
    try std.testing.expect(capture.cancelled);
}

test "agent shell capture propagates non-cancel execution errors" {
    const allocator = std.testing.allocator;

    var fake = FakeExecutionEnv.init(allocator);
    defer fake.deinit();
    fake.exec_error = .{ .code = .spawn_error, .message = "spawn failed" };

    const result = try executeShellWithCaptureAlloc(allocator, fake.env(), "missing", .{});

    try std.testing.expectEqual(types.ExecutionErrorCode.spawn_error, result.err.code);
    try std.testing.expectEqualStrings("spawn failed", result.err.message);
}

test "agent shell capture turns chunk callback failure into execution error" {
    const allocator = std.testing.allocator;

    const stdout_chunks = [_][]const u8{"hello"};
    var fake = FakeExecutionEnv.init(allocator);
    defer fake.deinit();
    fake.stdout_chunks = &stdout_chunks;

    var recorder = ChunkRecorder.init(allocator);
    defer recorder.deinit();
    recorder.fail = true;

    const result = try executeShellWithCaptureAlloc(allocator, fake.env(), "printf hello", .{
        .on_chunk = recorder.callback(),
    });

    try std.testing.expectEqual(types.ExecutionErrorCode.unknown, result.err.code);
    try std.testing.expectEqualStrings("CallbackFailed", result.err.message);
}

fn repeatedLinesAlloc(allocator: std.mem.Allocator, line: []const u8, count: usize) ![]u8 {
    var output = try allocator.alloc(u8, line.len * count);
    var offset: usize = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        @memcpy(output[offset .. offset + line.len], line);
        offset += line.len;
    }
    return output;
}

fn countScalar(input: []const u8, scalar: u8) usize {
    var count: usize = 0;
    for (input) |byte| {
        if (byte == scalar) count += 1;
    }
    return count;
}
