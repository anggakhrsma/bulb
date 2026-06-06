const std = @import("std");
const builtin = @import("builtin");

const bash_executor = @import("../bash_executor.zig");
const render_utils = @import("render_utils.zig");
const output_accumulator = @import("output_accumulator.zig");
const shell = @import("../shell.zig");
const truncate = @import("truncate.zig");

pub const BashOperations = bash_executor.BashOperations;
pub const BashExecOptions = bash_executor.BashExecOptions;
pub const BashExecResult = bash_executor.BashExecResult;
pub const BashDataCallback = bash_executor.BashDataCallback;
pub const AbortChecker = bash_executor.AbortChecker;

pub const BashToolInput = struct {
    command: ?[]const u8 = null,
    timeout: ?u64 = null,
};

pub const BashToolDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    full_output_path: ?[]u8 = null,

    pub fn deinit(self: *BashToolDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const BashToolResult = struct {
    content: []render_utils.ToolContentBlock,
    details: ?BashToolDetails = null,

    pub fn deinit(self: *BashToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |block| {
            if (block.text) |text| allocator.free(text);
            if (block.data) |data| allocator.free(data);
            if (block.mime_type) |mime_type| allocator.free(mime_type);
        }
        allocator.free(self.content);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub const BashToolExecution = union(enum) {
    success: BashToolResult,
    failure: []u8,

    pub fn deinit(self: *BashToolExecution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*result| result.deinit(allocator),
            .failure => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub const BashToolUpdate = struct {
    content: []const render_utils.ToolContentBlock,
    details: ?*const BashToolDetails = null,
};

pub const BashUpdateCallback = struct {
    ptr: ?*anyopaque = null,
    callback_fn: *const fn (?*anyopaque, BashToolUpdate) anyerror!void = defaultUpdateCallback,

    pub fn call(self: BashUpdateCallback, update: BashToolUpdate) !void {
        return self.callback_fn(self.ptr, update);
    }
};

pub const BashSpawnContext = struct {
    command: []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
};

pub const BashSpawnHook = struct {
    ptr: ?*anyopaque = null,
    apply_fn: *const fn (?*anyopaque, BashSpawnContext) anyerror!BashSpawnContext = defaultSpawnHook,

    pub fn apply(self: BashSpawnHook, context: BashSpawnContext) !BashSpawnContext {
        return self.apply_fn(self.ptr, context);
    }
};

pub const BashToolOptions = struct {
    operations: ?BashOperations = null,
    command_prefix: ?[]const u8 = null,
    shell_path: ?[]const u8 = null,
    spawn_hook: ?BashSpawnHook = null,
    abort_checker: AbortChecker = .{},
};

pub const LocalBashOperationsOptions = struct {
    shell_path: ?[]const u8 = null,
};

pub fn createLocalBashOperations(options: LocalBashOperationsOptions) BashOperations {
    const context = LocalBashContext.get(options);
    return .{ .ptr = context, .exec_fn = LocalBashContext.exec };
}

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: BashToolInput,
    options: BashToolOptions,
) !BashToolResult {
    const execution = try executeWithDiagnosticAlloc(allocator, io, cwd, input, options, null);
    switch (execution) {
        .success => |result| return result,
        .failure => |message| {
            allocator.free(message);
            return error.BashToolFailed;
        },
    }
}

pub fn executeWithDiagnosticAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: BashToolInput,
    options: BashToolOptions,
    on_update: ?BashUpdateCallback,
) !BashToolExecution {
    const command = input.command orelse return .{ .failure = try allocator.dupe(u8, "Bash command is required") };
    const resolved_command = if (options.command_prefix) |prefix|
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ prefix, command })
    else
        try allocator.dupe(u8, command);
    defer allocator.free(resolved_command);

    var global_env = std.process.Environ.Map.init(allocator);
    defer global_env.deinit();
    var shell_env = try shell.getShellEnvAlloc(allocator, &global_env);
    defer shell_env.deinit();

    const spawn_context_base: BashSpawnContext = .{
        .command = resolved_command,
        .cwd = cwd,
        .env = &shell_env,
    };
    const spawn_context = if (options.spawn_hook) |hook| try hook.apply(spawn_context_base) else spawn_context_base;
    const operations = options.operations orelse createLocalBashOperations(.{ .shell_path = options.shell_path });

    var output = try output_accumulator.OutputAccumulator.init(allocator, io, .{
        .temp_file_prefix = "bulb-bash",
    });
    defer output.deinit();

    var update_context: BashOutputContext = .{
        .allocator = allocator,
        .output = &output,
        .on_update = on_update,
    };

    if (on_update) |callback| {
        try callback.call(.{ .content = &.{}, .details = null });
    }

    const exec_result = operations.exec(allocator, io, spawn_context.command, spawn_context.cwd, .{
        .on_data = .{ .ptr = &update_context, .callback_fn = BashOutputContext.onData },
        .abort_checker = options.abort_checker,
        .timeout_seconds = input.timeout,
        .env = spawn_context.env,
    }) catch |err| {
        var snapshot = try finishOutput(allocator, &output, &update_context);
        defer snapshot.deinit(allocator);
        var formatted = try formatOutputAlloc(allocator, &snapshot, output.getLastLineBytes(), "");
        defer formatted.deinit(allocator);

        const status = if (err == error.Aborted)
            "Command aborted"
        else if (err == error.BashTimedOut)
            try std.fmt.allocPrint(allocator, "Command timed out after {d} seconds", .{input.timeout orelse 0})
        else
            try diagnosticForExecErrorAlloc(allocator, err, spawn_context.cwd, options.shell_path);
        defer if (err != error.Aborted) allocator.free(status);

        const message = try appendStatusAlloc(allocator, formatted.text, status);
        return .{ .failure = message };
    };

    var snapshot = try finishOutput(allocator, &output, &update_context);
    defer snapshot.deinit(allocator);
    var formatted = try formatOutputAlloc(allocator, &snapshot, output.getLastLineBytes(), "(no output)");
    defer formatted.deinit(allocator);

    if (exec_result.exit_code) |exit_code| {
        if (exit_code != 0) {
            const status = try std.fmt.allocPrint(allocator, "Command exited with code {d}", .{exit_code});
            defer allocator.free(status);
            return .{ .failure = try appendStatusAlloc(allocator, formatted.text, status) };
        }
    }

    return .{ .success = try resultFromFormattedAlloc(allocator, formatted) };
}

pub fn formatBashCallAlloc(
    allocator: std.mem.Allocator,
    args: ?BashToolInput,
    theme: render_utils.RenderTheme,
) ![]u8 {
    const input = args orelse BashToolInput{};
    var invalid_text: ?[]u8 = null;
    defer if (invalid_text) |text| allocator.free(text);
    const command_display = if (input.command) |command| if (command.len > 0) command else "..." else invalid: {
        invalid_text = try render_utils.invalidArgTextAlloc(allocator, theme);
        break :invalid invalid_text.?;
    };

    const title_text = try std.fmt.allocPrint(allocator, "$ {s}", .{command_display});
    defer allocator.free(title_text);

    const bold = try theme.boldAlloc(allocator, title_text);
    defer allocator.free(bold);
    const title = try theme.fgAlloc(allocator, .tool_title, bold);
    defer allocator.free(title);

    if (input.timeout) |timeout| {
        const suffix = try std.fmt.allocPrint(allocator, " (timeout {d}s)", .{timeout});
        defer allocator.free(suffix);
        const muted = try theme.fgAlloc(allocator, .muted, suffix);
        defer allocator.free(muted);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ title, muted });
    }
    return allocator.dupe(u8, title);
}

pub fn formatBashResultAlloc(
    allocator: std.mem.Allocator,
    result: BashToolResult,
    theme: render_utils.RenderTheme,
    is_error: bool,
) ![]u8 {
    const output = try render_utils.getTextOutputAlloc(allocator, .{ .content = result.content }, false);
    defer allocator.free(output);
    const trimmed = std.mem.trim(u8, output, " \n\t\r");
    if (trimmed.len == 0) return allocator.dupe(u8, "");

    const styled = try theme.fgAlloc(allocator, if (is_error) .@"error" else .tool_output, trimmed);
    defer allocator.free(styled);
    return std.fmt.allocPrint(allocator, "\n{s}", .{styled});
}

const BashOutputContext = struct {
    allocator: std.mem.Allocator,
    output: *output_accumulator.OutputAccumulator,
    on_update: ?BashUpdateCallback,
    dirty: bool = false,
    chunks_since_update: usize = 0,

    const update_chunk_interval = 256;

    fn onData(ptr: ?*anyopaque, data: []const u8) !void {
        const self: *BashOutputContext = @ptrCast(@alignCast(ptr.?));
        try self.output.append(data);
        self.dirty = true;
        self.chunks_since_update += 1;
        if (self.chunks_since_update >= update_chunk_interval) {
            try self.emitOutputUpdate();
        }
    }

    fn emitOutputUpdate(self: *BashOutputContext) !void {
        const callback = self.on_update orelse return;
        if (!self.dirty) return;
        self.dirty = false;
        self.chunks_since_update = 0;

        var snapshot = try self.output.snapshot(true);
        defer snapshot.deinit(self.allocator);
        var formatted = try formatOutputAlloc(self.allocator, &snapshot, self.output.getLastLineBytes(), "");
        defer formatted.deinit(self.allocator);
        var result = try resultFromFormattedAlloc(self.allocator, formatted);
        defer result.deinit(self.allocator);
        try callback.call(.{ .content = result.content, .details = if (result.details) |*details| details else null });
    }
};

fn finishOutput(
    allocator: std.mem.Allocator,
    output: *output_accumulator.OutputAccumulator,
    context: *BashOutputContext,
) !output_accumulator.OutputSnapshot {
    try output.finish();
    try context.emitOutputUpdate();
    const snapshot = try output.snapshot(true);
    output.closeTempFile();
    _ = allocator;
    return snapshot;
}

const FormattedOutput = struct {
    text: []u8,
    details: ?BashToolDetails = null,

    fn deinit(self: *FormattedOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

fn formatOutputAlloc(
    allocator: std.mem.Allocator,
    snapshot: *const output_accumulator.OutputSnapshot,
    last_line_bytes: usize,
    empty_text: []const u8,
) !FormattedOutput {
    var text = if (snapshot.content().len > 0)
        try allocator.dupe(u8, snapshot.content())
    else
        try allocator.dupe(u8, empty_text);
    errdefer allocator.free(text);

    var details: ?BashToolDetails = null;
    if (snapshot.truncation.truncated) {
        const truncation_copy = try cloneTruncationResultAlloc(allocator, snapshot.truncation);
        errdefer {
            var mutable = truncation_copy;
            mutable.deinit(allocator);
        }
        const full_output_path = if (snapshot.full_output_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (full_output_path) |path| allocator.free(path);
        details = .{ .truncation = truncation_copy, .full_output_path = full_output_path };

        const start_line = snapshot.truncation.total_lines - snapshot.truncation.output_lines + 1;
        const end_line = snapshot.truncation.total_lines;
        const footer = if (snapshot.truncation.last_line_partial) footer: {
            const shown_size = try truncate.formatSizeAlloc(allocator, snapshot.truncation.output_bytes);
            defer allocator.free(shown_size);
            const last_line_size = try truncate.formatSizeAlloc(allocator, last_line_bytes);
            defer allocator.free(last_line_size);
            break :footer try std.fmt.allocPrint(
                allocator,
                "\n\n[Showing last {s} of line {d} (line is {s}). Full output: {s}]",
                .{ shown_size, end_line, last_line_size, snapshot.full_output_path orelse "" },
            );
        } else if (snapshot.truncation.truncated_by == .lines) footer: {
            break :footer try std.fmt.allocPrint(
                allocator,
                "\n\n[Showing lines {d}-{d} of {d}. Full output: {s}]",
                .{ start_line, end_line, snapshot.truncation.total_lines, snapshot.full_output_path orelse "" },
            );
        } else footer: {
            const max_size = try truncate.formatSizeAlloc(allocator, truncate.DEFAULT_MAX_BYTES);
            defer allocator.free(max_size);
            break :footer try std.fmt.allocPrint(
                allocator,
                "\n\n[Showing lines {d}-{d} of {d} ({s} limit). Full output: {s}]",
                .{ start_line, end_line, snapshot.truncation.total_lines, max_size, snapshot.full_output_path orelse "" },
            );
        };
        defer allocator.free(footer);

        const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ text, footer });
        allocator.free(text);
        text = combined;
    }

    return .{ .text = text, .details = details };
}

fn resultFromFormattedAlloc(allocator: std.mem.Allocator, formatted: FormattedOutput) !BashToolResult {
    const blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = render_utils.textBlock(try allocator.dupe(u8, formatted.text));
    errdefer allocator.free(blocks[0].text.?);

    return .{
        .content = blocks,
        .details = if (formatted.details) |details| try cloneDetailsAlloc(allocator, details) else null,
    };
}

fn cloneDetailsAlloc(allocator: std.mem.Allocator, details: BashToolDetails) !BashToolDetails {
    return .{
        .truncation = if (details.truncation) |truncation_result| try cloneTruncationResultAlloc(allocator, truncation_result) else null,
        .full_output_path = if (details.full_output_path) |path| try allocator.dupe(u8, path) else null,
    };
}

fn cloneTruncationResultAlloc(
    allocator: std.mem.Allocator,
    source: truncate.TruncationResult,
) !truncate.TruncationResult {
    return .{
        .content = try allocator.dupe(u8, source.content),
        .truncated = source.truncated,
        .truncated_by = source.truncated_by,
        .total_lines = source.total_lines,
        .total_bytes = source.total_bytes,
        .output_lines = source.output_lines,
        .output_bytes = source.output_bytes,
        .last_line_partial = source.last_line_partial,
        .first_line_exceeds_limit = source.first_line_exceeds_limit,
        .max_lines = source.max_lines,
        .max_bytes = source.max_bytes,
    };
}

fn appendStatusAlloc(allocator: std.mem.Allocator, text: []const u8, status: []const u8) ![]u8 {
    if (text.len == 0) return allocator.dupe(u8, status);
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ text, status });
}

fn diagnosticForExecErrorAlloc(
    allocator: std.mem.Allocator,
    err: anyerror,
    cwd: []const u8,
    shell_path: ?[]const u8,
) ![]u8 {
    return switch (err) {
        error.WorkingDirectoryMissing => std.fmt.allocPrint(
            allocator,
            "Working directory does not exist: {s}\nCannot execute bash commands.",
            .{cwd},
        ),
        error.CustomShellPathNotFound => std.fmt.allocPrint(
            allocator,
            "Custom shell path not found: {s}",
            .{shell_path orelse ""},
        ),
        error.FileNotFound => allocator.dupe(u8, "ENOENT"),
        else => std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
    };
}

const LocalBashContext = struct {
    shell_path: ?[]const u8 = null,

    fn get(options: LocalBashOperationsOptions) *LocalBashContext {
        if (options.shell_path) |path| {
            return LocalBashContextRegistry.get(path);
        }
        return &default_local_bash_context;
    }

    fn exec(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        command: []const u8,
        cwd: []const u8,
        options: BashExecOptions,
    ) !BashExecResult {
        const self: *const LocalBashContext = @ptrCast(@alignCast(ptr.?));
        if (!pathExists(io, cwd)) return error.WorkingDirectoryMissing;
        try options.abort_checker.throwIfAborted();

        var env_storage: ?std.process.Environ.Map = null;
        defer if (env_storage) |*env| env.deinit();
        const env = options.env orelse env: {
            var global_env = std.process.Environ.Map.init(allocator);
            defer global_env.deinit();
            env_storage = try shell.getShellEnvAlloc(allocator, &global_env);
            break :env &env_storage.?;
        };

        var shell_config = try shell.getShellConfigAlloc(allocator, io, env, self.shell_path);
        defer shell_config.deinit(allocator);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, shell_config.shell);
        for (shell_config.args) |arg| try argv.append(allocator, arg);
        try argv.append(allocator, command);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = cwd },
            .environ_map = env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
            .create_no_window = true,
        });
        var child_running = true;
        defer if (child_running) child.kill(io);

        const pid: ?shell.ProcessId = childPid(child);
        if (pid) |actual_pid| try detached_tracker.trackDetachedChildPid(actual_pid);
        defer if (pid) |actual_pid| detached_tracker.untrackDetachedChildPid(actual_pid);

        var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();

        const timeout = timeoutFromSeconds(options.timeout_seconds).toDeadline(io);
        while (true) {
            multi_reader.fill(1024, timeout) catch |err| switch (err) {
                error.EndOfStream => break,
                error.Timeout => {
                    if (pid) |actual_pid| shell.killProcessTree(allocator, io, actual_pid);
                    child.kill(io);
                    child_running = false;
                    return error.BashTimedOut;
                },
                else => |fill_err| return fill_err,
            };
            try drainReader(multi_reader.reader(0), options.on_data);
            try drainReader(multi_reader.reader(1), options.on_data);
            try options.abort_checker.throwIfAborted();
        }

        try drainReader(multi_reader.reader(0), options.on_data);
        try drainReader(multi_reader.reader(1), options.on_data);
        try multi_reader.checkAnyError();

        const term = try child.wait(io);
        child_running = false;
        return .{ .exit_code = exitCodeFromTerm(term) };
    }
};

var default_local_bash_context: LocalBashContext = .{};
var detached_tracker = shell.DetachedChildTracker.init(std.heap.smp_allocator, std.Io.Threaded.global_single_threaded.io());

const LocalBashContextRegistry = struct {
    var contexts: std.ArrayList(*LocalBashContext) = .empty;

    fn get(shell_path: []const u8) *LocalBashContext {
        const context = std.heap.smp_allocator.create(LocalBashContext) catch unreachable;
        context.* = .{ .shell_path = std.heap.smp_allocator.dupe(u8, shell_path) catch unreachable };
        contexts.append(std.heap.smp_allocator, context) catch unreachable;
        return context;
    }
};

fn timeoutFromSeconds(timeout_seconds: ?u64) std.Io.Timeout {
    const seconds = timeout_seconds orelse return .none;
    if (seconds == 0) return .none;
    const clamped = @min(seconds, @as(u64, @intCast(std.math.maxInt(i64))));
    return .{ .duration = .{
        .raw = .fromSeconds(@intCast(clamped)),
        .clock = .awake,
    } };
}

fn drainReader(reader: *std.Io.Reader, callback: BashDataCallback) !void {
    const buffered = reader.buffered();
    if (buffered.len == 0) return;
    try callback.call(buffered);
    reader.toss(buffered.len);
}

fn exitCodeFromTerm(term: std.process.Child.Term) ?i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        else => null,
    };
}

fn childPid(child: std.process.Child) ?shell.ProcessId {
    if (builtin.os.tag == .windows) return null;
    const id = child.id orelse return null;
    return @intCast(id);
}

fn pathExists(io: std.Io, file_path: []const u8) bool {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch return false;
    return true;
}

fn defaultUpdateCallback(_: ?*anyopaque, _: BashToolUpdate) !void {}
fn defaultSpawnHook(_: ?*anyopaque, context: BashSpawnContext) !BashSpawnContext {
    return context;
}

fn textOutputAlloc(allocator: std.mem.Allocator, result: BashToolResult) ![]u8 {
    return render_utils.getTextOutputAlloc(allocator, .{ .content = result.content }, false);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

const FakeBashOperations = struct {
    chunks: []const []const u8 = &.{},
    exit_code: ?i32 = 0,
    err: ?anyerror = null,
    command_seen: ?[]const u8 = null,
    cwd_seen: ?[]const u8 = null,
    env_seen: ?*const std.process.Environ.Map = null,

    fn deinit(self: *FakeBashOperations, allocator: std.mem.Allocator) void {
        if (self.command_seen) |command| allocator.free(@constCast(command));
        if (self.cwd_seen) |cwd| allocator.free(@constCast(cwd));
        self.command_seen = null;
        self.cwd_seen = null;
    }

    fn exec(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        command: []const u8,
        cwd: []const u8,
        options: BashExecOptions,
    ) !BashExecResult {
        const self: *FakeBashOperations = @ptrCast(@alignCast(ptr.?));
        self.command_seen = try allocator.dupe(u8, command);
        self.cwd_seen = try allocator.dupe(u8, cwd);
        self.env_seen = options.env;
        for (self.chunks) |chunk| try options.on_data.call(chunk);
        if (self.err) |err| return err;
        return .{ .exit_code = self.exit_code };
    }
};

test "bash tool executes simple operation and returns Pi text payload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fake: FakeBashOperations = .{ .chunks = &.{"test output\n"} };
    defer fake.deinit(allocator);

    var execution = try executeWithDiagnosticAlloc(allocator, io, "/tmp", .{ .command = "echo 'test output'" }, .{
        .operations = .{ .ptr = &fake, .exec_fn = FakeBashOperations.exec },
    }, null);
    defer execution.deinit(allocator);

    try std.testing.expectEqualStrings("echo 'test output'", fake.command_seen.?);
    const result = &execution.success;
    const output = try textOutputAlloc(allocator, result.*);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "test output") != null);
    try std.testing.expect(result.details == null);
}

test "bash tool handles command errors and appends exit status" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fake: FakeBashOperations = .{ .chunks = &.{"nope\n"}, .exit_code = 1 };
    defer fake.deinit(allocator);

    var execution = try executeWithDiagnosticAlloc(allocator, io, "/tmp", .{ .command = "exit 1" }, .{
        .operations = .{ .ptr = &fake, .exec_fn = FakeBashOperations.exec },
    }, null);
    defer execution.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, execution.failure, "nope") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.failure, "Command exited with code 1") != null);
}

test "bash tool formats timeout and abort errors with full output path when truncated" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_]struct {
        err: anyerror,
        expected: []const u8,
    }{
        .{ .err = error.BashTimedOut, .expected = "Command timed out after 5 seconds" },
        .{ .err = error.Aborted, .expected = "Command aborted" },
    }) |case| {
        var generated: std.ArrayList(u8) = .empty;
        defer generated.deinit(allocator);
        for (1..3001) |index| try generated.print(allocator, "{d}\n", .{index});
        var fake: FakeBashOperations = .{ .chunks = &.{generated.items}, .err = case.err };
        defer fake.deinit(allocator);

        var execution = try executeWithDiagnosticAlloc(allocator, io, "/tmp", .{
            .command = "chatty-fail",
            .timeout = 5,
        }, .{
            .operations = .{ .ptr = &fake, .exec_fn = FakeBashOperations.exec },
        }, null);
        defer execution.deinit(allocator);

        try std.testing.expect(std.mem.indexOf(u8, execution.failure, case.expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, execution.failure, "[Showing lines ") != null);
        try std.testing.expect(std.mem.indexOf(u8, execution.failure, "Full output: ") != null);
        try std.testing.expect(std.mem.indexOf(u8, execution.failure, "Full output: undefined") == null);
        deleteFullOutputPathFromText(io, execution.failure);
    }
}

test "bash tool prepends command prefix and coalesces chatty updates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var chunks: std.ArrayList([]const u8) = .empty;
    defer chunks.deinit(allocator);
    for (0..5000) |index| {
        try chunks.append(allocator, try std.fmt.allocPrint(allocator, "line {d}\n", .{index}));
    }
    defer for (chunks.items) |chunk| allocator.free(@constCast(chunk));

    var fake: FakeBashOperations = .{ .chunks = chunks.items };
    defer fake.deinit(allocator);
    var updates: UpdateCounter = .{};

    var execution = try executeWithDiagnosticAlloc(allocator, io, "/tmp", .{ .command = "chatty" }, .{
        .operations = .{ .ptr = &fake, .exec_fn = FakeBashOperations.exec },
        .command_prefix = "export TEST_VAR=hello",
    }, .{ .ptr = &updates, .callback_fn = UpdateCounter.onUpdate });
    defer execution.deinit(allocator);

    try std.testing.expectEqualStrings("export TEST_VAR=hello\nchatty", fake.command_seen.?);
    try std.testing.expect(updates.count < 25);
    const output = try textOutputAlloc(allocator, execution.success);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "line 4999") != null);
    if (execution.success.details) |details| {
        if (details.full_output_path) |path| std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

test "bash tool truncates tail without counting trailing newline as extra line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var generated: std.ArrayList(u8) = .empty;
    defer generated.deinit(allocator);
    for (1..4001) |index| try generated.print(allocator, "line-{d:0>4}\n", .{index});
    var fake: FakeBashOperations = .{ .chunks = &.{generated.items} };
    defer fake.deinit(allocator);

    var execution = try executeWithDiagnosticAlloc(allocator, io, "/tmp", .{ .command = "many-lines" }, .{
        .operations = .{ .ptr = &fake, .exec_fn = FakeBashOperations.exec },
    }, null);
    defer execution.deinit(allocator);

    const result = &execution.success;
    try std.testing.expect(result.details != null);
    try std.testing.expectEqual(@as(usize, 4000), result.details.?.truncation.?.total_lines);
    try std.testing.expectEqual(@as(usize, 2000), result.details.?.truncation.?.output_lines);
    const output = try textOutputAlloc(allocator, result.*);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "line-2001") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "line-4000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "4001") == null);
    if (result.details.?.full_output_path) |path| std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "bash tool decodes UTF-8 characters split across chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const euro = "€\n";
    var fake: FakeBashOperations = .{ .chunks = &.{ euro[0..1], euro[1..] } };
    defer fake.deinit(allocator);

    var execution = try executeWithDiagnosticAlloc(allocator, io, "/tmp", .{ .command = "split-utf8" }, .{
        .operations = .{ .ptr = &fake, .exec_fn = FakeBashOperations.exec },
    }, null);
    defer execution.deinit(allocator);

    const output = try textOutputAlloc(allocator, execution.success);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("€\n", output);
}

test "local bash operations execute through configured environment" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("TEST_LOCAL_BASH_OPS", "from-local-ops");

    var chunks: std.ArrayList(u8) = .empty;
    defer chunks.deinit(allocator);
    var ops = createLocalBashOperations(.{});
    const result = try ops.exec(allocator, io, "echo $TEST_LOCAL_BASH_OPS", root, .{
        .on_data = .{ .ptr = &chunks, .callback_fn = collectChunk },
        .env = &env,
    });

    try std.testing.expectEqual(@as(?i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("from-local-ops\n", chunks.items);
}

test "local bash operations report missing cwd and custom shell path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var ops = createLocalBashOperations(.{});
    try std.testing.expectError(error.WorkingDirectoryMissing, ops.exec(allocator, io, "echo test", "/missing/bulb/cwd", .{
        .on_data = .{},
    }));

    var custom = createLocalBashOperations(.{ .shell_path = "/custom/bash" });
    try std.testing.expectError(error.CustomShellPathNotFound, custom.exec(allocator, io, "echo test", "/tmp", .{
        .on_data = .{},
    }));
}

const UpdateCounter = struct {
    count: usize = 0,

    fn onUpdate(ptr: ?*anyopaque, _: BashToolUpdate) !void {
        const self: *UpdateCounter = @ptrCast(@alignCast(ptr.?));
        self.count += 1;
    }
};

fn collectChunk(ptr: ?*anyopaque, data: []const u8) !void {
    const chunks: *std.ArrayList(u8) = @ptrCast(@alignCast(ptr.?));
    try chunks.appendSlice(std.testing.allocator, data);
}

fn deleteFullOutputPathFromText(io: std.Io, text: []const u8) void {
    const marker = "Full output: ";
    const start = std.mem.indexOf(u8, text, marker) orelse return;
    const path_start = start + marker.len;
    const tail = text[path_start..];
    const path_end = std.mem.indexOfAny(u8, tail, "]\n") orelse tail.len;
    if (path_end == 0) return;
    std.Io.Dir.cwd().deleteFile(io, tail[0..path_end]) catch {};
}
