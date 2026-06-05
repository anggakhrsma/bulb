const std = @import("std");
const builtin = @import("builtin");

const keybindings = @import("../keybindings.zig");
const path_utils = @import("../path_utils.zig");
const render_utils = @import("render_utils.zig");
const truncate = @import("truncate.zig");

pub const DEFAULT_LIMIT: usize = 500;

pub const LsToolInput = struct {
    path: ?[]const u8 = null,
    limit: ?usize = null,
};

pub const LsStat = struct {
    is_directory: bool,
};

pub const LsOperations = struct {
    ptr: ?*anyopaque = null,
    exists_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!bool = defaultExists,
    stat_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!LsStat = defaultStat,
    readdir_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror![][]u8 = defaultReaddir,

    pub fn exists(self: LsOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !bool {
        return self.exists_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn stat(self: LsOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !LsStat {
        return self.stat_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn readdir(self: LsOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![][]u8 {
        return self.readdir_fn(self.ptr, allocator, io, absolute_path);
    }
};

pub const LsToolOptions = struct {
    operations: LsOperations = .{},
    home_dir: ?[]const u8 = null,
};

pub const LsToolDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    entry_limit_reached: ?usize = null,

    pub fn hasDetails(self: LsToolDetails) bool {
        return self.truncation != null or self.entry_limit_reached != null;
    }

    pub fn deinit(self: *LsToolDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const LsToolResult = struct {
    text: []u8,
    details: ?LsToolDetails = null,

    pub fn deinit(self: *LsToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: LsToolInput,
    options: LsToolOptions,
) !LsToolResult {
    const requested_path = input.path orelse ".";
    const dir_path = try path_utils.resolveToCwdAlloc(allocator, requested_path, cwd, options.home_dir);
    defer allocator.free(dir_path);

    const ops = options.operations;
    if (!try ops.exists(allocator, io, dir_path)) return error.PathNotFound;

    const dir_stat = try ops.stat(allocator, io, dir_path);
    if (!dir_stat.is_directory) return error.NotDirectory;

    const entries = ops.readdir(allocator, io, dir_path) catch return error.CannotReadDirectory;
    defer freeStringSlice(allocator, entries);
    std.mem.sort([]u8, entries, {}, caseInsensitiveLessThan);

    const effective_limit = input.limit orelse DEFAULT_LIMIT;
    var formatted_entries: std.ArrayList([]u8) = .empty;
    defer {
        for (formatted_entries.items) |entry| allocator.free(entry);
        formatted_entries.deinit(allocator);
    }

    var entry_limit_reached = false;
    for (entries) |entry| {
        if (formatted_entries.items.len >= effective_limit) {
            entry_limit_reached = true;
            break;
        }

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry });
        defer allocator.free(full_path);
        const entry_stat = ops.stat(allocator, io, full_path) catch continue;
        const suffix: []const u8 = if (entry_stat.is_directory) "/" else "";
        try formatted_entries.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ entry, suffix }));
    }

    if (formatted_entries.items.len == 0) {
        return .{ .text = try allocator.dupe(u8, "(empty directory)") };
    }

    const raw_output = try joinLinesAlloc(allocator, formatted_entries.items);
    defer allocator.free(raw_output);

    var truncation_result = try truncate.truncateHeadAlloc(allocator, raw_output, .{ .max_lines = std.math.maxInt(usize) });
    var truncation_moved = false;
    defer if (!truncation_moved) truncation_result.deinit(allocator);

    var details: LsToolDetails = .{};
    errdefer details.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, truncation_result.content);

    var notices: std.ArrayList([]u8) = .empty;
    defer {
        for (notices.items) |notice| allocator.free(notice);
        notices.deinit(allocator);
    }

    if (entry_limit_reached) {
        try notices.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{d} entries limit reached. Use limit={d} for more", .{
                effective_limit,
                effective_limit *| 2,
            }),
        );
        details.entry_limit_reached = effective_limit;
    }

    if (truncation_result.truncated) {
        const size = try truncate.formatSizeAlloc(allocator, truncate.DEFAULT_MAX_BYTES);
        defer allocator.free(size);
        try notices.append(allocator, try std.fmt.allocPrint(allocator, "{s} limit reached", .{size}));
        details.truncation = truncation_result;
        truncation_moved = true;
    }

    if (notices.items.len > 0) {
        try output.appendSlice(allocator, "\n\n[");
        for (notices.items, 0..) |notice, index| {
            if (index > 0) try output.appendSlice(allocator, ". ");
            try output.appendSlice(allocator, notice);
        }
        try output.append(allocator, ']');
    }

    return .{
        .text = try output.toOwnedSlice(allocator),
        .details = if (details.hasDetails()) details else null,
    };
}

pub fn formatLsCallAlloc(
    allocator: std.mem.Allocator,
    args: ?LsToolInput,
    theme: render_utils.RenderTheme,
    cwd: []const u8,
    options: LsToolOptions,
) ![]u8 {
    const input = args orelse LsToolInput{};
    const path_display = try render_utils.renderToolPathAlloc(allocator, input.path orelse "", theme, cwd, .{
        .empty_fallback = ".",
        .home_dir = options.home_dir,
    });
    defer allocator.free(path_display);
    const title_bold = try theme.boldAlloc(allocator, "ls");
    defer allocator.free(title_bold);
    const title = try theme.fgAlloc(allocator, .tool_title, title_bold);
    defer allocator.free(title);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.print(allocator, "{s} {s}", .{ title, path_display });
    if (input.limit) |limit| {
        const limit_text = try std.fmt.allocPrint(allocator, " (limit {d})", .{limit});
        defer allocator.free(limit_text);
        const styled_limit = try theme.fgAlloc(allocator, .tool_output, limit_text);
        defer allocator.free(styled_limit);
        try output.appendSlice(allocator, styled_limit);
    }
    return output.toOwnedSlice(allocator);
}

pub fn formatLsResultAlloc(
    allocator: std.mem.Allocator,
    result: LsToolResult,
    options: render_utils.ToolRenderResultOptions,
    theme: render_utils.RenderTheme,
    show_images: bool,
) ![]u8 {
    const blocks = [_]render_utils.ToolContentBlock{render_utils.textBlock(result.text)};
    const text_output = try render_utils.getTextOutputAlloc(allocator, .{ .content = &blocks }, show_images);
    defer allocator.free(text_output);
    const trimmed = std.mem.trim(u8, text_output, " \t\r\n");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    if (trimmed.len > 0) {
        var lines = try splitLinesAlloc(allocator, trimmed);
        defer allocator.free(lines);
        const max_lines = if (options.expanded) lines.len else @min(lines.len, 20);
        try output.append(allocator, '\n');
        for (lines[0..max_lines], 0..) |line, index| {
            if (index > 0) try output.append(allocator, '\n');
            const styled = try theme.fgAlloc(allocator, .tool_output, line);
            defer allocator.free(styled);
            try output.appendSlice(allocator, styled);
        }

        const remaining = lines.len - max_lines;
        if (remaining > 0) {
            const prefix = try std.fmt.allocPrint(allocator, "\n... ({d} more lines,", .{remaining});
            defer allocator.free(prefix);
            const styled_prefix = try theme.fgAlloc(allocator, .muted, prefix);
            defer allocator.free(styled_prefix);
            const hint = try keyHintAlloc(allocator, theme, "app.tools.expand", "to expand");
            defer allocator.free(hint);
            try output.print(allocator, "{s} {s})", .{ styled_prefix, hint });
        }
    }

    if (result.details) |details| {
        if (details.entry_limit_reached != null or (details.truncation != null and details.truncation.?.truncated)) {
            var warnings: std.ArrayList([]u8) = .empty;
            defer {
                for (warnings.items) |warning| allocator.free(warning);
                warnings.deinit(allocator);
            }

            if (details.entry_limit_reached) |limit| {
                try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{d} entries limit", .{limit}));
            }
            if (details.truncation) |truncation_result| {
                if (truncation_result.truncated) {
                    const size = try truncate.formatSizeAlloc(allocator, truncation_result.max_bytes);
                    defer allocator.free(size);
                    try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{s} limit", .{size}));
                }
            }
            const warning_text = try joinWithSeparatorAlloc(allocator, warnings.items, ", ");
            defer allocator.free(warning_text);
            const bracketed = try std.fmt.allocPrint(allocator, "[Truncated: {s}]", .{warning_text});
            defer allocator.free(bracketed);
            const styled = try theme.fgAlloc(allocator, .warning, bracketed);
            defer allocator.free(styled);
            try output.print(allocator, "\n{s}", .{styled});
        }
    }

    return output.toOwnedSlice(allocator);
}

fn defaultExists(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !bool {
    return path_utils.pathExists(io, absolute_path);
}

fn defaultStat(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !LsStat {
    const stat = try std.Io.Dir.cwd().statFile(io, absolute_path, .{ .follow_symlinks = true });
    return .{ .is_directory = stat.kind == .directory };
}

fn defaultReaddir(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![][]u8 {
    var directory = try openDirPath(io, absolute_path, .{ .iterate = true });
    defer directory.close(io);

    var entries: std.ArrayList([]u8) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        try entries.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return entries.toOwnedSlice(allocator);
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn caseInsensitiveLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const min_len = @min(lhs.len, rhs.len);
    var index: usize = 0;
    while (index < min_len) : (index += 1) {
        const left = std.ascii.toLower(lhs[index]);
        const right = std.ascii.toLower(rhs[index]);
        if (left < right) return true;
        if (left > right) return false;
    }
    if (lhs.len != rhs.len) return lhs.len < rhs.len;
    return std.mem.lessThan(u8, lhs, rhs);
}

fn joinLinesAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    return joinWithSeparatorAlloc(allocator, lines, "\n");
}

fn joinWithSeparatorAlloc(allocator: std.mem.Allocator, parts: []const []const u8, separator: []const u8) ![]u8 {
    if (parts.len == 0) return allocator.dupe(u8, "");
    var total_len: usize = separator.len * (parts.len - 1);
    for (parts) |part| total_len += part.len;

    const output = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (parts, 0..) |part, index| {
        if (index > 0) {
            @memcpy(output[offset .. offset + separator.len], separator);
            offset += separator.len;
        }
        @memcpy(output[offset .. offset + part.len], part);
        offset += part.len;
    }
    return output;
}

fn splitLinesAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    if (text.len == 0) return lines.toOwnedSlice(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
        try lines.append(allocator, text[start..newline]);
        start = newline + 1;
    }
    if (start < text.len) try lines.append(allocator, text[start..]);
    return lines.toOwnedSlice(allocator);
}

fn keyHintAlloc(
    allocator: std.mem.Allocator,
    theme: render_utils.RenderTheme,
    keybinding: []const u8,
    description: []const u8,
) ![]u8 {
    const key_text = try keyTextAlloc(allocator, keybinding);
    defer allocator.free(key_text);
    const styled_key = try theme.fgAlloc(allocator, .dim, key_text);
    defer allocator.free(styled_key);
    const description_text = try std.fmt.allocPrint(allocator, " {s}", .{description});
    defer allocator.free(description_text);
    const styled_description = try theme.fgAlloc(allocator, .muted, description_text);
    defer allocator.free(styled_description);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ styled_key, styled_description });
}

fn keyTextAlloc(allocator: std.mem.Allocator, keybinding: []const u8) ![]u8 {
    var empty: keybindings.KeybindingsConfig = .empty;
    defer empty.deinit(allocator);
    var manager = try keybindings.KeybindingsManager.init(allocator, &empty);
    defer manager.deinit();

    const keys = try manager.getKeysAlloc(allocator, keybinding);
    defer freeConstStringSlice(allocator, keys);
    return formatKeysAlloc(allocator, keys);
}

fn formatKeysAlloc(allocator: std.mem.Allocator, keys: []const []const u8) ![]u8 {
    if (keys.len == 0) return allocator.dupe(u8, "");
    const joined = try joinWithSeparatorAlloc(allocator, keys, "/");
    defer allocator.free(joined);
    return formatKeyTextAlloc(allocator, joined);
}

fn formatKeyTextAlloc(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var slash_iter = std.mem.splitScalar(u8, key, '/');
    var first_key = true;
    while (slash_iter.next()) |combo| {
        if (!first_key) try output.append(allocator, '/');
        first_key = false;

        var plus_iter = std.mem.splitScalar(u8, combo, '+');
        var first_part = true;
        while (plus_iter.next()) |part| {
            if (!first_part) try output.append(allocator, '+');
            first_part = false;
            if (builtin.os.tag == .macos and std.ascii.eqlIgnoreCase(part, "alt")) {
                try output.appendSlice(allocator, "option");
            } else {
                try output.appendSlice(allocator, part);
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

fn freeStringSlice(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn freeConstStringSlice(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

const StyledTestTheme = struct {
    pub fn bold(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "<bold>{s}</>", .{text});
    }

    pub fn fg(_: ?*anyopaque, allocator: std.mem.Allocator, color: render_utils.ThemeColor, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "<{s}>{s}</>", .{ colorName(color), text });
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

const LargeDirectoryOperations = struct {
    root_path: []const u8,
    count: usize,

    fn operations(self: *LargeDirectoryOperations) LsOperations {
        return .{
            .ptr = self,
            .exists_fn = exists,
            .stat_fn = stat,
            .readdir_fn = readdir,
        };
    }

    fn exists(_: ?*anyopaque, _: std.mem.Allocator, _: std.Io, _: []const u8) !bool {
        return true;
    }

    fn stat(ptr: ?*anyopaque, _: std.mem.Allocator, _: std.Io, absolute_path: []const u8) !LsStat {
        const self: *LargeDirectoryOperations = @ptrCast(@alignCast(ptr.?));
        return .{ .is_directory = std.mem.eql(u8, absolute_path, self.root_path) };
    }

    fn readdir(ptr: ?*anyopaque, allocator: std.mem.Allocator, _: std.Io, _: []const u8) ![][]u8 {
        const self: *LargeDirectoryOperations = @ptrCast(@alignCast(ptr.?));
        var entries: std.ArrayList([]u8) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry);
            entries.deinit(allocator);
        }

        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            try entries.append(
                allocator,
                try std.fmt.allocPrint(allocator, "entry-{d:0>4}-{s}.txt", .{
                    index,
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
                }),
            );
        }
        return entries.toOwnedSlice(allocator);
    }
};

test "ls execute lists dotfiles directories and sorts case-insensitively" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden-file", .data = "secret" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Beta.txt", .data = "beta" });
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = "alpha" });
    try tmp.dir.createDir(io, ".hidden-dir", .default_dir);

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var result = try executeAlloc(allocator, io, root, .{ .path = root }, .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(".hidden-dir/\n.hidden-file\nalpha.txt\nBeta.txt", result.text);
    try std.testing.expect(result.details == null);
}

test "ls execute reports empty directory and rejects missing or file paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "content" });
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var empty = try executeAlloc(allocator, io, root, .{}, .{});
    defer empty.deinit(allocator);
    try std.testing.expectEqualStrings("file.txt", empty.text);

    const nested = try std.fs.path.join(allocator, &.{ root, "nested" });
    defer allocator.free(nested);
    try tmp.dir.createDir(io, "nested", .default_dir);
    var nested_empty = try executeAlloc(allocator, io, root, .{ .path = nested }, .{});
    defer nested_empty.deinit(allocator);
    try std.testing.expectEqualStrings("(empty directory)", nested_empty.text);

    const missing = try std.fs.path.join(allocator, &.{ root, "missing" });
    defer allocator.free(missing);
    try std.testing.expectError(error.PathNotFound, executeAlloc(allocator, io, root, .{ .path = missing }, .{}));

    const file = try std.fs.path.join(allocator, &.{ root, "file.txt" });
    defer allocator.free(file);
    try std.testing.expectError(error.NotDirectory, executeAlloc(allocator, io, root, .{ .path = file }, .{}));
}

test "ls execute caps entries and emits actionable notice" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "c.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "" });
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var result = try executeAlloc(allocator, io, root, .{ .limit = 2 }, .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        "a.txt\nb.txt\n\n[2 entries limit reached. Use limit=4 for more]",
        result.text,
    );
    try std.testing.expect(result.details != null);
    try std.testing.expectEqual(@as(?usize, 2), result.details.?.entry_limit_reached);
}

test "ls execute records byte truncation details" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var large_ops = LargeDirectoryOperations{ .root_path = "/mock", .count = 700 };

    var result = try executeAlloc(allocator, io, "/mock", .{ .limit = 700 }, .{
        .operations = large_ops.operations(),
    });
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "[50.0KB limit reached]") != null);
    try std.testing.expect(result.details != null);
    try std.testing.expect(result.details.?.truncation != null);
    try std.testing.expect(result.details.?.truncation.?.truncated);
}

test "ls render call uses path rendering and optional limit" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    const text = try formatLsCallAlloc(allocator, .{ .path = "/Users/alice/project", .limit = 20 }, theme, "/tmp", .{
        .home_dir = "/Users/alice",
    });
    defer allocator.free(text);

    try std.testing.expectEqualStrings(
        "<toolTitle><bold>ls</></> <accent>~/project</><toolOutput> (limit 20)</>",
        text,
    );
}

test "ls render result collapses long output and reports truncation warnings" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (index < 22) : (index += 1) {
        if (index > 0) try output.append(allocator, '\n');
        try output.print(allocator, "file-{d}", .{index});
    }

    var result = LsToolResult{
        .text = try output.toOwnedSlice(allocator),
        .details = .{ .entry_limit_reached = 22 },
    };
    defer result.deinit(allocator);

    const rendered = try formatLsResultAlloc(allocator, result, .{}, theme, false);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "<toolOutput>file-0</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "... (2 more lines,") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<dim>ctrl+o</><muted> to expand</>)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<warning>[Truncated: 22 entries limit]</>") != null);
}
