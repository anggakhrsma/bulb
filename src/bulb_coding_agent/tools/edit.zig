const std = @import("std");

const edit_diff = @import("edit_diff.zig");
const file_mutation_queue = @import("file_mutation_queue.zig");
const path_utils = @import("../path_utils.zig");
const render_utils = @import("render_utils.zig");

pub const Edit = edit_diff.Edit;

pub const EditToolInput = struct {
    path: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    edits: []const Edit = &.{},
    old_text: ?[]const u8 = null,
    new_text: ?[]const u8 = null,
};

pub const EditToolDetails = struct {
    diff: []u8,
    patch: []u8,
    first_changed_line: ?usize = null,

    pub fn deinit(self: *EditToolDetails, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
        allocator.free(self.patch);
        self.* = undefined;
    }
};

pub const EditOperations = struct {
    ptr: ?*anyopaque = null,
    read_file_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror![]u8 = defaultReadFile,
    write_file_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8, []const u8) anyerror!void = defaultWriteFile,
    access_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!void = defaultAccess,
    format_access_error_fn: *const fn (?*anyopaque, std.mem.Allocator, anyerror) anyerror![]u8 = edit_diff.defaultFormatAccessError,

    pub fn readFile(self: EditOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
        return self.read_file_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn writeFile(self: EditOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8, content: []const u8) !void {
        return self.write_file_fn(self.ptr, allocator, io, absolute_path, content);
    }

    pub fn access(self: EditOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !void {
        return self.access_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn formatAccessError(self: EditOperations, allocator: std.mem.Allocator, err: anyerror) ![]u8 {
        return self.format_access_error_fn(self.ptr, allocator, err);
    }

    pub fn diffOperations(self: EditOperations) edit_diff.EditDiffOperations {
        return .{
            .ptr = self.ptr,
            .access_fn = self.access_fn,
            .read_file_fn = self.read_file_fn,
            .format_access_error_fn = self.format_access_error_fn,
        };
    }
};

pub const AbortChecker = struct {
    ptr: ?*anyopaque = null,
    check_fn: *const fn (?*anyopaque) anyerror!void = defaultAbortCheck,

    pub fn throwIfAborted(self: AbortChecker) !void {
        return self.check_fn(self.ptr);
    }
};

pub const EditToolOptions = struct {
    operations: EditOperations = .{},
    abort_checker: AbortChecker = .{},
    home_dir: ?[]const u8 = null,
};

pub const EditToolResult = struct {
    content: []render_utils.ToolContentBlock,
    details: ?EditToolDetails = null,

    pub fn deinit(self: *EditToolResult, allocator: std.mem.Allocator) void {
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

pub const EditToolExecution = union(enum) {
    success: EditToolResult,
    failure: []u8,

    pub fn deinit(self: *EditToolExecution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*result| result.deinit(allocator),
            .failure => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: EditToolInput,
    options: EditToolOptions,
) !EditToolResult {
    var execution = try executeWithDiagnosticAlloc(allocator, io, cwd, input, options);
    switch (execution) {
        .success => |result| {
            execution = undefined;
            return result;
        },
        .failure => |message| {
            allocator.free(message);
            return error.EditToolFailed;
        },
    }
}

pub fn executeWithDiagnosticAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: EditToolInput,
    options: EditToolOptions,
) !EditToolExecution {
    const requested_path = input.path orelse input.file_path orelse return .{ .failure = try allocator.dupe(u8, "Edit tool input is invalid. path is required.") };
    const edits = try preparedEditsAlloc(allocator, input);
    defer allocator.free(edits);
    if (edits.len == 0) {
        return .{ .failure = try allocator.dupe(u8, "Edit tool input is invalid. edits must contain at least one replacement.") };
    }

    const absolute_path = try path_utils.resolveToCwdAlloc(allocator, requested_path, cwd, options.home_dir);
    defer allocator.free(absolute_path);

    var guard = try file_mutation_queue.lockFileAlloc(allocator, io, absolute_path);
    defer guard.deinit(io);

    const ops = options.operations;
    const abort_checker = options.abort_checker;
    try abort_checker.throwIfAborted();

    ops.access(allocator, io, absolute_path) catch |err| {
        try abort_checker.throwIfAborted();
        const error_message = try ops.formatAccessError(allocator, err);
        defer allocator.free(error_message);
        return .{ .failure = try std.fmt.allocPrint(allocator, "Could not edit file: {s}. {s}.", .{
            requested_path,
            error_message,
        }) };
    };
    try abort_checker.throwIfAborted();

    const raw_content = ops.readFile(allocator, io, absolute_path) catch |err| {
        try abort_checker.throwIfAborted();
        const error_message = try ops.formatAccessError(allocator, err);
        defer allocator.free(error_message);
        return .{ .failure = try std.fmt.allocPrint(allocator, "Could not edit file: {s}. {s}.", .{
            requested_path,
            error_message,
        }) };
    };
    defer allocator.free(raw_content);
    try abort_checker.throwIfAborted();

    const bom_stripped = edit_diff.stripBom(raw_content);
    const original_ending = edit_diff.detectLineEnding(bom_stripped.text);
    const normalized_content = try edit_diff.normalizeToLFAlloc(allocator, bom_stripped.text);
    defer allocator.free(normalized_content);

    var applied = try edit_diff.applyEditsToNormalizedContentAlloc(allocator, normalized_content, edits, requested_path);
    defer applied.deinit(allocator);
    switch (applied) {
        .failure => |message| return .{ .failure = try allocator.dupe(u8, message) },
        .success => |success| {
            try abort_checker.throwIfAborted();
            const restored = try edit_diff.restoreLineEndingsAlloc(allocator, success.new_content, original_ending);
            defer allocator.free(restored);
            const final_content = try std.mem.concat(allocator, u8, &.{ bom_stripped.bom, restored });
            defer allocator.free(final_content);

            try ops.writeFile(allocator, io, absolute_path, final_content);
            try abort_checker.throwIfAborted();

            var diff_result = try edit_diff.generateDiffStringAlloc(allocator, success.base_content, success.new_content, 4);
            errdefer diff_result.deinit(allocator);
            const patch = try edit_diff.generateUnifiedPatchAlloc(allocator, requested_path, success.base_content, success.new_content, 4);
            errdefer allocator.free(patch);

            const text = try std.fmt.allocPrint(allocator, "Successfully replaced {d} block(s) in {s}.", .{
                edits.len,
                requested_path,
            });
            errdefer allocator.free(text);
            const blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
            errdefer allocator.free(blocks);
            blocks[0] = render_utils.textBlock(text);

            return .{ .success = .{
                .content = blocks,
                .details = .{
                    .diff = diff_result.diff,
                    .patch = patch,
                    .first_changed_line = diff_result.first_changed_line,
                },
            } };
        },
    }
}

pub fn formatEditCallAlloc(
    allocator: std.mem.Allocator,
    args: ?EditToolInput,
    theme: render_utils.RenderTheme,
    cwd: []const u8,
    options: EditToolOptions,
) ![]u8 {
    const input = args orelse EditToolInput{};
    const raw_path = input.file_path orelse input.path;
    const path_display = try render_utils.renderToolPathAlloc(allocator, raw_path, theme, cwd, .{
        .home_dir = options.home_dir,
    });
    defer allocator.free(path_display);
    const title_bold = try theme.boldAlloc(allocator, "edit");
    defer allocator.free(title_bold);
    const title = try theme.fgAlloc(allocator, .tool_title, title_bold);
    defer allocator.free(title);
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ title, path_display });
}

pub fn formatEditResultAlloc(
    allocator: std.mem.Allocator,
    result: EditToolResult,
    theme: render_utils.RenderTheme,
    is_error: bool,
) ![]u8 {
    if (is_error) {
        const output = try render_utils.getTextOutputAlloc(allocator, .{ .content = result.content }, false);
        defer allocator.free(output);
        if (output.len == 0) return allocator.dupe(u8, "");
        const styled = try theme.fgAlloc(allocator, .@"error", output);
        defer allocator.free(styled);
        return std.fmt.allocPrint(allocator, "\n{s}", .{styled});
    }

    if (result.details) |details| {
        if (details.diff.len == 0) return allocator.dupe(u8, "");
        return std.fmt.allocPrint(allocator, "\n{s}", .{details.diff});
    }
    return allocator.dupe(u8, "");
}

pub fn computeEditsDiffAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    edits: []const Edit,
    cwd: []const u8,
    options: EditToolOptions,
) !edit_diff.EditDiffPreview {
    return edit_diff.computeEditsDiffAlloc(allocator, io, path, edits, cwd, options.operations.diffOperations());
}

fn preparedEditsAlloc(allocator: std.mem.Allocator, input: EditToolInput) ![]Edit {
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);
    for (input.edits) |edit| try edits.append(allocator, edit);
    if (input.old_text != null and input.new_text != null) {
        try edits.append(allocator, .{ .old_text = input.old_text.?, .new_text = input.new_text.? });
    }
    return edits.toOwnedSlice(allocator);
}

fn defaultReadFile(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .unlimited);
}

fn defaultWriteFile(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = absolute_path,
        .data = content,
        .flags = .{ .read = true, .truncate = true },
    });
}

fn defaultAccess(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !void {
    try std.Io.Dir.cwd().access(io, absolute_path, .{});
}

fn defaultAbortCheck(_: ?*anyopaque) !void {}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

const StyledTestTheme = struct {
    pub fn fg(_: ?*anyopaque, allocator: std.mem.Allocator, color: render_utils.ThemeColor, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "<{s}>{s}</>", .{ colorName(color), text });
    }

    pub fn bold(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "<bold>{s}</>", .{text});
    }
};

fn colorName(color: render_utils.ThemeColor) []const u8 {
    return switch (color) {
        .accent => "accent",
        .dim => "dim",
        .@"error" => "error",
        .muted => "muted",
        .tool_title => "toolTitle",
        .tool_output => "toolOutput",
        .warning => "warning",
    };
}

fn styledTestTheme() render_utils.RenderTheme {
    return .{ .bold_fn = StyledTestTheme.bold, .fg_fn = StyledTestTheme.fg };
}

test "edit tool replaces text in file and returns Pi details" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "edit-test.txt" });
    defer allocator.free(test_file);
    try tmp.dir.writeFile(io, .{ .sub_path = "edit-test.txt", .data = "Hello, world!" });

    var execution = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = test_file,
        .edits = &.{.{ .old_text = "world", .new_text = "testing" }},
    }, .{});
    defer execution.deinit(allocator);

    const result = execution.success;
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.?, "Successfully replaced") != null);
    try std.testing.expect(result.details != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?.diff, "testing") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?.patch, "--- ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?.patch, "+++ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?.patch, "@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?.patch, "-Hello, world!") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?.patch, "+Hello, testing!") != null);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("Hello, testing!", written);
}

test "edit tool reports missing duplicate empty and overlap diagnostics without partial writes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "edit-test.txt" });
    defer allocator.free(test_file);

    try tmp.dir.writeFile(io, .{ .sub_path = "edit-test.txt", .data = "foo foo foo" });
    var duplicate = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = test_file,
        .edits = &.{.{ .old_text = "foo", .new_text = "bar" }},
    }, .{});
    defer duplicate.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, duplicate.failure, "Found 3 occurrences") != null);

    var empty = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = test_file,
        .edits = &.{},
    }, .{});
    defer empty.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, empty.failure, "edits must contain at least one replacement") != null);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = test_file, .data = "alpha\nbeta\ngamma\n" });
    var partial = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = test_file,
        .edits = &.{
            .{ .old_text = "alpha\n", .new_text = "ALPHA\n" },
            .{ .old_text = "missing\n", .new_text = "MISSING\n" },
        },
    }, .{});
    defer partial.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, partial.failure, "Could not find") != null);
    const unchanged = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", unchanged);
}

test "edit tool replaces multiple disjoint regions and preserves CRLF and BOM" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "edit-multi.txt" });
    defer allocator.free(test_file);
    try tmp.dir.writeFile(io, .{ .sub_path = "edit-multi.txt", .data = "\xEF\xBB\xBFalpha\r\nbeta\r\ngamma\r\ndelta\r\n" });

    var execution = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = test_file,
        .edits = &.{
            .{ .old_text = "alpha\n", .new_text = "ALPHA\n" },
            .{ .old_text = "gamma\n", .new_text = "GAMMA\n" },
        },
    }, .{});
    defer execution.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, execution.success.content[0].text.?, "Successfully replaced 2 block(s)") != null);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("\xEF\xBB\xBFALPHA\r\nbeta\r\nGAMMA\r\ndelta\r\n", written);
}

const CustomAccessState = struct {
    err: anyerror,
    message: ?[]const u8 = null,
};

fn customAccess(ptr: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8) !void {
    const state: *CustomAccessState = @ptrCast(@alignCast(ptr.?));
    return state.err;
}

fn customFormatAccessError(ptr: ?*anyopaque, allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    const state: *CustomAccessState = @ptrCast(@alignCast(ptr.?));
    if (state.message) |message| return allocator.dupe(u8, message);
    return edit_diff.defaultFormatAccessError(null, allocator, err);
}

test "edit tool includes ENOENT EACCES and custom access diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const missing = try std.fs.path.join(allocator, &.{ root, "missing.txt" });
    defer allocator.free(missing);

    var missing_result = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = missing,
        .edits = &.{.{ .old_text = "hello", .new_text = "world" }},
    }, .{});
    defer missing_result.deinit(allocator);
    const expected_missing = try std.fmt.allocPrint(allocator, "Could not edit file: {s}. Error code: ENOENT.", .{missing});
    defer allocator.free(expected_missing);
    try std.testing.expectEqualStrings(expected_missing, missing_result.failure);

    var eacces_state: CustomAccessState = .{ .err = error.AccessDenied };
    var eacces = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = "readonly.txt",
        .edits = &.{.{ .old_text = "hello", .new_text = "world" }},
    }, .{
        .operations = .{
            .ptr = &eacces_state,
            .access_fn = customAccess,
            .format_access_error_fn = customFormatAccessError,
        },
    });
    defer eacces.deinit(allocator);
    try std.testing.expectEqualStrings("Could not edit file: readonly.txt. Error code: EACCES.", eacces.failure);

    var generic_state: CustomAccessState = .{ .err = error.DiskOffline, .message = "Error: disk offline" };
    var generic = try executeWithDiagnosticAlloc(allocator, io, root, .{
        .path = "broken.txt",
        .edits = &.{.{ .old_text = "hello", .new_text = "world" }},
    }, .{
        .operations = .{
            .ptr = &generic_state,
            .access_fn = customAccess,
            .format_access_error_fn = customFormatAccessError,
        },
    });
    defer generic.deinit(allocator);
    try std.testing.expectEqualStrings("Could not edit file: broken.txt. Error: disk offline.", generic.failure);
}

const SlowEditState = struct {
    first_started: std.atomic.Value(bool) = .init(false),
    finish_first: std.atomic.Value(bool) = .init(false),
    first_settled: std.atomic.Value(bool) = .init(false),
    second_started: std.atomic.Value(bool) = .init(false),
    abort_requested: std.atomic.Value(bool) = .init(false),
};

fn slowEditWriteFile(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    absolute_path: []const u8,
    content: []const u8,
) !void {
    const state: *SlowEditState = @ptrCast(@alignCast(ptr.?));
    if (std.mem.eql(u8, content, "ALPHA\nbeta\n")) {
        state.first_started.store(true, .seq_cst);
        while (!state.finish_first.load(.seq_cst)) {
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch @panic("sleep failed");
        }
        try defaultWriteFile(null, allocator, io, absolute_path, content);
        state.first_settled.store(true, .seq_cst);
        return;
    }

    if (std.mem.eql(u8, content, "ALPHA\nBETA\n") or std.mem.eql(u8, content, "alpha\nBETA\n")) {
        state.second_started.store(true, .seq_cst);
        try std.testing.expect(state.first_settled.load(.seq_cst));
    }
    try defaultWriteFile(null, allocator, io, absolute_path, content);
}

fn editAbortCheck(ptr: ?*anyopaque) !void {
    const state: *SlowEditState = @ptrCast(@alignCast(ptr.?));
    if (state.abort_requested.load(.seq_cst)) return error.OperationAborted;
}

const EditThreadContext = struct {
    io: std.Io,
    cwd: []const u8,
    path: []const u8,
    edits: []const Edit,
    state: *SlowEditState,
    use_abort_checker: bool = false,
    err: ?anyerror = null,
};

fn editThread(ctx: *EditThreadContext) void {
    const abort_checker: AbortChecker = if (ctx.use_abort_checker)
        .{ .ptr = ctx.state, .check_fn = editAbortCheck }
    else
        .{};
    var execution = executeWithDiagnosticAlloc(std.testing.allocator, ctx.io, ctx.cwd, .{
        .path = ctx.path,
        .edits = ctx.edits,
    }, .{
        .operations = .{ .ptr = ctx.state, .write_file_fn = slowEditWriteFile },
        .abort_checker = abort_checker,
    }) catch |err| {
        ctx.err = err;
        return;
    };
    execution.deinit(std.testing.allocator);
}

test "edit tool keeps queue locked while aborted edit write is still in flight" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "abort-edit.txt" });
    defer allocator.free(test_file);
    try tmp.dir.writeFile(io, .{ .sub_path = "abort-edit.txt", .data = "alpha\nbeta\n" });

    const first_edits = [_]Edit{.{ .old_text = "alpha", .new_text = "ALPHA" }};
    const second_edits = [_]Edit{.{ .old_text = "beta", .new_text = "BETA" }};
    var state: SlowEditState = .{};
    var first_ctx: EditThreadContext = .{
        .io = io,
        .cwd = root,
        .path = test_file,
        .edits = &first_edits,
        .state = &state,
        .use_abort_checker = true,
    };
    var second_ctx: EditThreadContext = .{
        .io = io,
        .cwd = root,
        .path = test_file,
        .edits = &second_edits,
        .state = &state,
    };

    const first = try std.Thread.spawn(.{}, editThread, .{&first_ctx});
    while (!state.first_started.load(.seq_cst)) {
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    state.abort_requested.store(true, .seq_cst);

    const second = try std.Thread.spawn(.{}, editThread, .{&second_ctx});
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    try std.testing.expect(!state.second_started.load(.seq_cst));

    state.finish_first.store(true, .seq_cst);
    first.join();
    second.join();

    try std.testing.expectEqual(error.OperationAborted, first_ctx.err.?);
    try std.testing.expect(second_ctx.err == null);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("ALPHA\nBETA\n", written);
}

test "edit render call and result expose Pi-style title and diff/error output" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    const call = try formatEditCallAlloc(allocator, .{
        .path = "/Users/alice/project/file.txt",
        .edits = &.{.{ .old_text = "old", .new_text = "new" }},
    }, theme, "/tmp", .{ .home_dir = "/Users/alice" });
    defer allocator.free(call);
    try std.testing.expectEqualStrings("<toolTitle><bold>edit</></> <accent>~/project/file.txt</>", call);

    var blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    blocks[0] = render_utils.textBlock(try allocator.dupe(u8, "edit failed"));
    var error_result: EditToolResult = .{ .content = blocks };
    defer error_result.deinit(allocator);

    const shown = try formatEditResultAlloc(allocator, error_result, theme, true);
    defer allocator.free(shown);
    try std.testing.expectEqualStrings("\n<error>edit failed</>", shown);
}
