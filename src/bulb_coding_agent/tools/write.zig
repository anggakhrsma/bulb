const std = @import("std");

const file_mutation_queue = @import("file_mutation_queue.zig");
const keybindings = @import("../keybindings.zig");
const path_utils = @import("../path_utils.zig");
const render_utils = @import("render_utils.zig");

pub const WriteToolInput = struct {
    path: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub const WriteOperations = struct {
    ptr: ?*anyopaque = null,
    write_file_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8, []const u8) anyerror!void = defaultWriteFile,
    mkdir_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!void = defaultMkdir,

    pub fn writeFile(
        self: WriteOperations,
        allocator: std.mem.Allocator,
        io: std.Io,
        absolute_path: []const u8,
        content: []const u8,
    ) !void {
        return self.write_file_fn(self.ptr, allocator, io, absolute_path, content);
    }

    pub fn mkdir(
        self: WriteOperations,
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: []const u8,
    ) !void {
        return self.mkdir_fn(self.ptr, allocator, io, dir);
    }
};

pub const AbortChecker = struct {
    ptr: ?*anyopaque = null,
    check_fn: *const fn (?*anyopaque) anyerror!void = defaultAbortCheck,

    pub fn throwIfAborted(self: AbortChecker) !void {
        return self.check_fn(self.ptr);
    }
};

pub const WriteToolOptions = struct {
    operations: WriteOperations = .{},
    abort_checker: AbortChecker = .{},
    home_dir: ?[]const u8 = null,
};

pub const WriteToolResult = struct {
    content: []render_utils.ToolContentBlock,

    pub fn deinit(self: *WriteToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |block| {
            if (block.text) |text| allocator.free(text);
            if (block.data) |data| allocator.free(data);
            if (block.mime_type) |mime_type| allocator.free(mime_type);
        }
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: WriteToolInput,
    options: WriteToolOptions,
) !WriteToolResult {
    const requested_path = input.path orelse input.file_path orelse return error.InvalidPath;
    const content = input.content orelse return error.InvalidContent;
    const absolute_path = try path_utils.resolveToCwdAlloc(allocator, requested_path, cwd, options.home_dir);
    defer allocator.free(absolute_path);
    const parent_dir = std.fs.path.dirname(absolute_path) orelse return error.InvalidPath;

    var guard = try file_mutation_queue.lockFileAlloc(allocator, io, absolute_path);
    defer guard.deinit(io);

    const ops = options.operations;
    const abort_checker = options.abort_checker;
    try abort_checker.throwIfAborted();
    try ops.mkdir(allocator, io, parent_dir);
    try abort_checker.throwIfAborted();
    try ops.writeFile(allocator, io, absolute_path, content);
    try abort_checker.throwIfAborted();

    const text = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ content.len, requested_path });
    errdefer allocator.free(text);
    const blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = render_utils.textBlock(text);
    return .{ .content = blocks };
}

pub fn formatWriteCallAlloc(
    allocator: std.mem.Allocator,
    args: ?WriteToolInput,
    options: render_utils.ToolRenderResultOptions,
    theme: render_utils.RenderTheme,
    cwd: []const u8,
    tool_options: WriteToolOptions,
) ![]u8 {
    const input = args orelse WriteToolInput{};
    const raw_path = input.file_path orelse input.path;
    const path_display = try render_utils.renderToolPathAlloc(allocator, raw_path, theme, cwd, .{
        .home_dir = tool_options.home_dir,
    });
    defer allocator.free(path_display);
    const title_bold = try theme.boldAlloc(allocator, "write");
    defer allocator.free(title_bold);
    const title = try theme.fgAlloc(allocator, .tool_title, title_bold);
    defer allocator.free(title);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.print(allocator, "{s} {s}", .{ title, path_display });

    const file_content = input.content orelse "";
    if (file_content.len > 0) {
        const normalized = try render_utils.normalizeDisplayTextAlloc(allocator, file_content);
        defer allocator.free(normalized);
        const tabbed = try render_utils.replaceTabsAlloc(allocator, normalized);
        defer allocator.free(tabbed);
        const split_lines = try splitLinesAlloc(allocator, tabbed);
        defer allocator.free(split_lines);
        const trimmed_len = trimTrailingEmptyLineCount(split_lines);
        const lines = split_lines[0..trimmed_len];
        const max_lines = if (options.expanded) lines.len else @min(lines.len, 10);

        if (max_lines > 0) {
            try output.appendSlice(allocator, "\n\n");
            for (lines[0..max_lines], 0..) |line, index| {
                if (index > 0) try output.append(allocator, '\n');
                const styled = try theme.fgAlloc(allocator, .tool_output, line);
                defer allocator.free(styled);
                try output.appendSlice(allocator, styled);
            }
        }

        const remaining = lines.len - max_lines;
        if (remaining > 0) {
            const prefix = try std.fmt.allocPrint(allocator, "\n... ({d} more lines, {d} total,", .{ remaining, lines.len });
            defer allocator.free(prefix);
            const styled_prefix = try theme.fgAlloc(allocator, .muted, prefix);
            defer allocator.free(styled_prefix);
            const hint = try keyHintAlloc(allocator, theme, "app.tools.expand", "to expand");
            defer allocator.free(hint);
            try output.print(allocator, "{s} {s})", .{ styled_prefix, hint });
        }
    }

    return output.toOwnedSlice(allocator);
}

pub fn formatWriteResultAlloc(
    allocator: std.mem.Allocator,
    result: WriteToolResult,
    theme: render_utils.RenderTheme,
    is_error: bool,
) ![]u8 {
    if (!is_error) return allocator.dupe(u8, "");
    const output = try render_utils.getTextOutputAlloc(allocator, .{ .content = result.content }, false);
    defer allocator.free(output);
    if (output.len == 0) return allocator.dupe(u8, "");
    const styled = try theme.fgAlloc(allocator, .@"error", output);
    defer allocator.free(styled);
    return std.fmt.allocPrint(allocator, "\n{s}", .{styled});
}

fn defaultWriteFile(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    io: std.Io,
    absolute_path: []const u8,
    content: []const u8,
) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = absolute_path,
        .data = content,
        .flags = .{ .read = true, .truncate = true },
    });
}

fn defaultMkdir(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, dir);
}

fn defaultAbortCheck(_: ?*anyopaque) !void {}

fn splitLinesAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    if (text.len == 0) return lines.toOwnedSlice(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
        try lines.append(allocator, text[start..newline]);
        start = newline + 1;
    }
    if (start < text.len) {
        try lines.append(allocator, text[start..]);
    } else if (text.len > 0 and text[text.len - 1] == '\n') {
        try lines.append(allocator, "");
    }
    return lines.toOwnedSlice(allocator);
}

fn trimTrailingEmptyLineCount(lines: []const []const u8) usize {
    var end = lines.len;
    while (end > 0 and lines[end - 1].len == 0) {
        end -= 1;
    }
    return end;
}

fn keyHintAlloc(
    allocator: std.mem.Allocator,
    theme: render_utils.RenderTheme,
    action_id: []const u8,
    label: []const u8,
) ![]u8 {
    const key_text = try keyTextAlloc(allocator, action_id);
    defer allocator.free(key_text);
    const styled_key = try theme.fgAlloc(allocator, .dim, key_text);
    defer allocator.free(styled_key);
    const spaced_label = try std.fmt.allocPrint(allocator, " {s}", .{label});
    defer allocator.free(spaced_label);
    const styled_label = try theme.fgAlloc(allocator, .muted, spaced_label);
    defer allocator.free(styled_label);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ styled_key, styled_label });
}

fn keyTextAlloc(allocator: std.mem.Allocator, keybinding: []const u8) ![]u8 {
    var empty: keybindings.KeybindingsConfig = .empty;
    defer empty.deinit(allocator);
    var manager = try keybindings.KeybindingsManager.init(allocator, &empty);
    defer manager.deinit();

    const keys = try manager.getKeysAlloc(allocator, keybinding);
    defer freeConstStringSlice(allocator, keys);
    return joinWithSeparatorAlloc(allocator, keys, "/");
}

fn joinWithSeparatorAlloc(allocator: std.mem.Allocator, parts: []const []const u8, separator: []const u8) ![]u8 {
    if (parts.len == 0) return allocator.dupe(u8, "");
    var total_len: usize = separator.len * (parts.len - 1);
    for (parts) |part| total_len += part.len;

    const output = try allocator.alloc(u8, total_len);
    var index: usize = 0;
    for (parts, 0..) |part, part_index| {
        if (part_index > 0) {
            @memcpy(output[index .. index + separator.len], separator);
            index += separator.len;
        }
        @memcpy(output[index .. index + part.len], part);
        index += part.len;
    }
    return output;
}

fn freeConstStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(@constCast(value));
    allocator.free(values);
}

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

test "write tool writes file contents and returns Pi success text" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "write-test.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{ .path = test_file, .content = "Test content" }, .{});
    defer result.deinit(allocator);

    const text = result.content[0].text.?;
    try std.testing.expect(std.mem.indexOf(u8, text, "Successfully wrote") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, test_file) != null);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("Test content", written);
}

test "write tool creates parent directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "nested", "dir", "test.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{ .path = test_file, .content = "Nested content" }, .{});
    defer result.deinit(allocator);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("Nested content", written);
}

const SlowWriteState = struct {
    first_started: std.atomic.Value(bool) = .init(false),
    finish_first: std.atomic.Value(bool) = .init(false),
    first_settled: std.atomic.Value(bool) = .init(false),
    second_started: std.atomic.Value(bool) = .init(false),
    abort_requested: std.atomic.Value(bool) = .init(false),
};

fn slowWriteFile(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    absolute_path: []const u8,
    content: []const u8,
) !void {
    const state: *SlowWriteState = @ptrCast(@alignCast(ptr.?));
    if (std.mem.eql(u8, content, "first\n")) {
        state.first_started.store(true, .seq_cst);
        while (!state.finish_first.load(.seq_cst)) {
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch @panic("sleep failed");
        }
        try defaultWriteFile(null, allocator, io, absolute_path, content);
        state.first_settled.store(true, .seq_cst);
        return;
    }

    if (std.mem.eql(u8, content, "second\n")) {
        state.second_started.store(true, .seq_cst);
        try std.testing.expect(state.first_settled.load(.seq_cst));
    }
    try defaultWriteFile(null, allocator, io, absolute_path, content);
}

fn abortCheck(ptr: ?*anyopaque) !void {
    const state: *SlowWriteState = @ptrCast(@alignCast(ptr.?));
    if (state.abort_requested.load(.seq_cst)) return error.OperationAborted;
}

const WriteThreadContext = struct {
    io: std.Io,
    cwd: []const u8,
    path: []const u8,
    content: []const u8,
    state: *SlowWriteState,
    use_abort_checker: bool = false,
    err: ?anyerror = null,
};

fn writeThread(ctx: *WriteThreadContext) void {
    const abort_checker: AbortChecker = if (ctx.use_abort_checker)
        .{ .ptr = ctx.state, .check_fn = abortCheck }
    else
        .{};
    var result = executeAlloc(std.testing.allocator, ctx.io, ctx.cwd, .{
        .path = ctx.path,
        .content = ctx.content,
    }, .{
        .operations = .{ .ptr = ctx.state, .write_file_fn = slowWriteFile },
        .abort_checker = abort_checker,
    }) catch |err| {
        ctx.err = err;
        return;
    };
    result.deinit(std.testing.allocator);
}

test "write tool keeps queue locked while aborted write is still in flight" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "abort-write.txt" });
    defer allocator.free(test_file);

    var state: SlowWriteState = .{};
    var first_ctx: WriteThreadContext = .{
        .io = io,
        .cwd = root,
        .path = test_file,
        .content = "first\n",
        .state = &state,
        .use_abort_checker = true,
    };
    var second_ctx: WriteThreadContext = .{
        .io = io,
        .cwd = root,
        .path = test_file,
        .content = "second\n",
        .state = &state,
    };

    const first = try std.Thread.spawn(.{}, writeThread, .{&first_ctx});
    while (!state.first_started.load(.seq_cst)) {
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    state.abort_requested.store(true, .seq_cst);

    const second = try std.Thread.spawn(.{}, writeThread, .{&second_ctx});
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    try std.testing.expect(!state.second_started.load(.seq_cst));

    state.finish_first.store(true, .seq_cst);
    first.join();
    second.join();

    try std.testing.expectEqual(error.OperationAborted, first_ctx.err.?);
    try std.testing.expect(second_ctx.err == null);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, test_file, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("second\n", written);
}

test "write render call previews content and collapses long output" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    const rendered = try formatWriteCallAlloc(allocator, .{
        .path = "/Users/alice/project/file.txt",
        .content = "one\ntwo\tthree\n",
    }, .{}, theme, "/tmp", .{ .home_dir = "/Users/alice" });
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("<toolTitle><bold>write</></> <accent>~/project/file.txt</>\n\n<toolOutput>one</>\n<toolOutput>two   three</>", rendered);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    for (0..12) |index| {
        if (index > 0) try content.append(allocator, '\n');
        try content.print(allocator, "line {d}", .{index + 1});
    }
    const collapsed = try formatWriteCallAlloc(allocator, .{
        .path = "long.txt",
        .content = content.items,
    }, .{}, theme, "/tmp", .{});
    defer allocator.free(collapsed);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "<toolOutput>line 10</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "<toolOutput>line 11</>") == null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "... (2 more lines, 12 total,") != null);
}

test "write render result is hidden unless the tool errors" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    var blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    blocks[0] = render_utils.textBlock(try allocator.dupe(u8, "write failed"));
    var result: WriteToolResult = .{ .content = blocks };
    defer result.deinit(allocator);

    const hidden = try formatWriteResultAlloc(allocator, result, theme, false);
    defer allocator.free(hidden);
    try std.testing.expectEqualStrings("", hidden);

    const shown = try formatWriteResultAlloc(allocator, result, theme, true);
    defer allocator.free(shown);
    try std.testing.expectEqualStrings("\n<error>write failed</>", shown);
}
