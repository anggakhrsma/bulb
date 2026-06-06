const std = @import("std");
const builtin = @import("builtin");

const keybindings = @import("../keybindings.zig");
const mime = @import("../mime.zig");
const path_utils = @import("../path_utils.zig");
const render_utils = @import("render_utils.zig");
const truncate = @import("truncate.zig");

pub const ReadToolInput = struct {
    path: ?[]const u8 = null,
    offset: ?usize = null,
    limit: ?usize = null,
};

pub const ReadOperations = struct {
    ptr: ?*anyopaque = null,
    read_file_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror![]u8 = defaultReadFile,
    access_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!void = defaultAccess,
    detect_image_mime_type_fn: ?*const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!?[]const u8 = defaultDetectImageMimeType,

    pub fn readFile(self: ReadOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
        return self.read_file_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn access(self: ReadOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !void {
        return self.access_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn detectImageMimeType(self: ReadOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !?[]const u8 {
        const detect_fn = self.detect_image_mime_type_fn orelse return null;
        return detect_fn(self.ptr, allocator, io, absolute_path);
    }
};

pub const ReadToolOptions = struct {
    auto_resize_images: bool = true,
    operations: ReadOperations = .{},
    home_dir: ?[]const u8 = null,
    model_supports_images: ?bool = null,
};

pub const ReadToolDetails = struct {
    truncation: ?truncate.TruncationResult = null,

    pub fn hasDetails(self: ReadToolDetails) bool {
        return self.truncation != null;
    }

    pub fn deinit(self: *ReadToolDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const ReadToolResult = struct {
    content: []render_utils.ToolContentBlock,
    details: ?ReadToolDetails = null,

    pub fn deinit(self: *ReadToolResult, allocator: std.mem.Allocator) void {
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

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: ReadToolInput,
    options: ReadToolOptions,
) !ReadToolResult {
    const requested_path = input.path orelse return error.InvalidPath;
    const absolute_path = try path_utils.resolveReadPathAlloc(allocator, io, requested_path, cwd, options.home_dir);
    defer allocator.free(absolute_path);

    const ops = options.operations;
    try ops.access(allocator, io, absolute_path);

    const mime_type = try ops.detectImageMimeType(allocator, io, absolute_path);
    if (mime_type) |image_mime_type| {
        const buffer = try ops.readFile(allocator, io, absolute_path);
        defer allocator.free(buffer);
        return readImageAlloc(allocator, buffer, image_mime_type, options);
    }

    const buffer = try ops.readFile(allocator, io, absolute_path);
    defer allocator.free(buffer);
    return readTextAlloc(allocator, requested_path, buffer, input.offset, input.limit);
}

pub fn formatReadCallAlloc(
    allocator: std.mem.Allocator,
    args: ?ReadToolInput,
    theme: render_utils.RenderTheme,
    cwd: []const u8,
    options: ReadToolOptions,
) ![]u8 {
    const input = args orelse ReadToolInput{};
    const path_display = try render_utils.renderToolPathAlloc(allocator, input.path, theme, cwd, .{
        .home_dir = options.home_dir,
    });
    defer allocator.free(path_display);
    const title_bold = try theme.boldAlloc(allocator, "read");
    defer allocator.free(title_bold);
    const title = try theme.fgAlloc(allocator, .tool_title, title_bold);
    defer allocator.free(title);
    const line_range = try formatReadLineRangeAlloc(allocator, input, theme);
    defer allocator.free(line_range);

    return std.fmt.allocPrint(allocator, "{s} {s}{s}", .{ title, path_display, line_range });
}

pub fn formatReadResultAlloc(
    allocator: std.mem.Allocator,
    args: ?ReadToolInput,
    result: ReadToolResult,
    options: render_utils.ToolRenderResultOptions,
    theme: render_utils.RenderTheme,
    show_images: bool,
    is_error: bool,
) ![]u8 {
    if (!options.expanded and !is_error) return allocator.dupe(u8, "");

    const rendered_text = try render_utils.getTextOutputAlloc(allocator, .{ .content = result.content }, show_images);
    defer allocator.free(rendered_text);
    const normalized = try render_utils.replaceTabsAlloc(allocator, rendered_text);
    defer allocator.free(normalized);

    const lines = try splitDisplayLinesAlloc(allocator, normalized);
    defer allocator.free(lines);
    const trimmed_len = trimTrailingEmptyLineCount(lines);
    const display_lines = lines[0..trimmed_len];
    const max_lines = if (options.expanded) display_lines.len else @min(display_lines.len, 10);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    if (max_lines > 0) {
        try output.append(allocator, '\n');
        for (display_lines[0..max_lines], 0..) |line, index| {
            if (index > 0) try output.append(allocator, '\n');
            const styled = try theme.fgAlloc(allocator, .tool_output, line);
            defer allocator.free(styled);
            try output.appendSlice(allocator, styled);
        }
    }

    const remaining = display_lines.len - max_lines;
    if (remaining > 0) {
        const prefix = try std.fmt.allocPrint(allocator, "\n... ({d} more lines,", .{remaining});
        defer allocator.free(prefix);
        const styled_prefix = try theme.fgAlloc(allocator, .muted, prefix);
        defer allocator.free(styled_prefix);
        const hint = try keyHintAlloc(allocator, theme, "app.tools.expand", "to expand");
        defer allocator.free(hint);
        try output.print(allocator, "{s} {s})", .{ styled_prefix, hint });
    }

    _ = args;
    if (result.details) |details| {
        if (details.truncation) |truncation_result| {
            if (truncation_result.truncated) {
                const warning_text = try formatReadTruncationWarningAlloc(allocator, truncation_result);
                defer allocator.free(warning_text);
                const styled = try theme.fgAlloc(allocator, .warning, warning_text);
                defer allocator.free(styled);
                try output.print(allocator, "\n{s}", .{styled});
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

fn readImageAlloc(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    image_mime_type: []const u8,
    options: ReadToolOptions,
) !ReadToolResult {
    const encoded_len = std.base64.standard.Encoder.calcSize(buffer.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, buffer);

    const owned_mime = try allocator.dupe(u8, image_mime_type);
    errdefer allocator.free(owned_mime);

    const note = try imageNoteAlloc(allocator, image_mime_type, options);
    errdefer allocator.free(note);

    const blocks = try allocator.alloc(render_utils.ToolContentBlock, 2);
    errdefer allocator.free(blocks);
    blocks[0] = render_utils.textBlock(note);
    blocks[1] = render_utils.imageBlock(encoded, owned_mime);

    return .{ .content = blocks };
}

fn imageNoteAlloc(allocator: std.mem.Allocator, image_mime_type: []const u8, options: ReadToolOptions) ![]u8 {
    _ = options.auto_resize_images;
    const non_vision_note = if (options.model_supports_images) |supports_images|
        if (supports_images) null else "[Current model does not support images. The image will be omitted from this request.]"
    else
        null;

    if (non_vision_note) |note| {
        return std.fmt.allocPrint(allocator, "Read image file [{s}]\n{s}", .{ image_mime_type, note });
    }
    return std.fmt.allocPrint(allocator, "Read image file [{s}]", .{image_mime_type});
}

fn readTextAlloc(
    allocator: std.mem.Allocator,
    requested_path: []const u8,
    buffer: []const u8,
    offset: ?usize,
    limit: ?usize,
) !ReadToolResult {
    const text = try allocator.dupe(u8, buffer);
    defer allocator.free(text);

    const all_lines = try splitLinesJsAlloc(allocator, text);
    defer allocator.free(all_lines);
    const total_file_lines = all_lines.len;

    const start_line = if (offset) |value| if (value > 0) value - 1 else 0 else 0;
    const start_line_display = start_line + 1;
    if (start_line >= all_lines.len) {
        return error.OffsetBeyondEndOfFile;
    }

    var user_limited_lines: ?usize = null;
    const selected = if (limit) |line_limit| blk: {
        const end_line = @min(start_line + line_limit, all_lines.len);
        user_limited_lines = end_line - start_line;
        break :blk try joinLinesAlloc(allocator, all_lines[start_line..end_line]);
    } else try joinLinesAlloc(allocator, all_lines[start_line..]);
    defer allocator.free(selected);

    var truncation_result = try truncate.truncateHeadAlloc(allocator, selected, .{});
    var truncation_moved = false;
    defer if (!truncation_moved) truncation_result.deinit(allocator);

    var details: ReadToolDetails = .{};
    errdefer details.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    if (truncation_result.first_line_exceeds_limit) {
        const first_line_size = try truncate.formatSizeAlloc(allocator, all_lines[start_line].len);
        defer allocator.free(first_line_size);
        const max_size = try truncate.formatSizeAlloc(allocator, truncate.DEFAULT_MAX_BYTES);
        defer allocator.free(max_size);
        try output.print(
            allocator,
            "[Line {d} is {s}, exceeds {s} limit. Use bash: sed -n '{d}p' {s} | head -c {d}]",
            .{
                start_line_display,
                first_line_size,
                max_size,
                start_line_display,
                requested_path,
                truncate.DEFAULT_MAX_BYTES,
            },
        );
        details.truncation = truncation_result;
        truncation_moved = true;
    } else if (truncation_result.truncated) {
        const end_line_display = start_line_display + truncation_result.output_lines - 1;
        const next_offset = end_line_display + 1;
        try output.appendSlice(allocator, truncation_result.content);
        if (truncation_result.truncated_by == .lines) {
            try output.print(
                allocator,
                "\n\n[Showing lines {d}-{d} of {d}. Use offset={d} to continue.]",
                .{ start_line_display, end_line_display, total_file_lines, next_offset },
            );
        } else {
            const max_size = try truncate.formatSizeAlloc(allocator, truncate.DEFAULT_MAX_BYTES);
            defer allocator.free(max_size);
            try output.print(
                allocator,
                "\n\n[Showing lines {d}-{d} of {d} ({s} limit). Use offset={d} to continue.]",
                .{ start_line_display, end_line_display, total_file_lines, max_size, next_offset },
            );
        }
        details.truncation = truncation_result;
        truncation_moved = true;
    } else if (user_limited_lines) |limited_lines| {
        if (start_line + limited_lines < all_lines.len) {
            const remaining = all_lines.len - (start_line + limited_lines);
            const next_offset = start_line + limited_lines + 1;
            try output.print(
                allocator,
                "{s}\n\n[{d} more lines in file. Use offset={d} to continue.]",
                .{ truncation_result.content, remaining, next_offset },
            );
        } else {
            try output.appendSlice(allocator, truncation_result.content);
        }
    } else {
        try output.appendSlice(allocator, truncation_result.content);
    }

    const output_text = try output.toOwnedSlice(allocator);
    errdefer allocator.free(output_text);

    const blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = render_utils.textBlock(output_text);

    return .{
        .content = blocks,
        .details = if (details.hasDetails()) details else null,
    };
}

fn formatReadLineRangeAlloc(
    allocator: std.mem.Allocator,
    input: ReadToolInput,
    theme: render_utils.RenderTheme,
) ![]u8 {
    if (input.offset == null and input.limit == null) return allocator.dupe(u8, "");
    const start_line = input.offset orelse 1;
    const range = if (input.limit) |limit|
        try std.fmt.allocPrint(allocator, ":{d}-{d}", .{ start_line, start_line + limit -| 1 })
    else
        try std.fmt.allocPrint(allocator, ":{d}", .{start_line});
    defer allocator.free(range);
    return theme.fgAlloc(allocator, .warning, range);
}

fn formatReadTruncationWarningAlloc(allocator: std.mem.Allocator, truncation_result: truncate.TruncationResult) ![]u8 {
    if (truncation_result.first_line_exceeds_limit) {
        const size = try truncate.formatSizeAlloc(allocator, truncation_result.max_bytes);
        defer allocator.free(size);
        return std.fmt.allocPrint(allocator, "[First line exceeds {s} limit]", .{size});
    }
    if (truncation_result.truncated_by == .lines) {
        return std.fmt.allocPrint(
            allocator,
            "[Truncated: showing {d} of {d} lines ({d} line limit)]",
            .{ truncation_result.output_lines, truncation_result.total_lines, truncation_result.max_lines },
        );
    }
    const size = try truncate.formatSizeAlloc(allocator, truncation_result.max_bytes);
    defer allocator.free(size);
    return std.fmt.allocPrint(
        allocator,
        "[Truncated: {d} lines shown ({s} limit)]",
        .{ truncation_result.output_lines, size },
    );
}

fn defaultReadFile(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .unlimited);
}

fn defaultAccess(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !void {
    return std.Io.Dir.cwd().access(io, absolute_path, .{});
}

fn defaultDetectImageMimeType(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !?[]const u8 {
    return mime.detectSupportedImageMimeTypeFromFile(io, absolute_path);
}

fn splitLinesJsAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
        try lines.append(allocator, text[start..newline]);
        start = newline + 1;
    }
    try lines.append(allocator, text[start..]);
    return lines.toOwnedSlice(allocator);
}

fn splitDisplayLinesAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
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

fn trimTrailingEmptyLineCount(lines: []const []const u8) usize {
    var end = lines.len;
    while (end > 0 and lines[end - 1].len == 0) {
        end -= 1;
    }
    return end;
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

fn getTextOutputAlloc(allocator: std.mem.Allocator, result: ReadToolResult) ![]u8 {
    return render_utils.getTextOutputAlloc(allocator, .{ .content = result.content }, false);
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

test "read file contents that fit within limits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const content = "Hello, world!\nLine 2\nLine 3";
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = content });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "test.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{ .path = test_file }, .{});
    defer result.deinit(allocator);
    const output = try getTextOutputAlloc(allocator, result);
    defer allocator.free(output);

    try std.testing.expectEqualStrings(content, output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Use offset=") == null);
    try std.testing.expect(result.details == null);
}

test "read handles non-existent files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "nonexistent.txt" });
    defer allocator.free(test_file);

    try std.testing.expectError(error.FileNotFound, executeAlloc(allocator, io, root, .{ .path = test_file }, .{}));
}

test "read truncates files exceeding line limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var index: usize = 0;
    while (index < 2500) : (index += 1) {
        if (index > 0) try content.append(allocator, '\n');
        try content.print(allocator, "Line {d}", .{index + 1});
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = content.items });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "large.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{ .path = test_file }, .{});
    defer result.deinit(allocator);
    const output = try getTextOutputAlloc(allocator, result);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Line 2000") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Line 2001") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[Showing lines 1-2000 of 2500. Use offset=2001 to continue.]") != null);
}

test "read truncates when byte limit exceeded" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var index: usize = 0;
    while (index < 500) : (index += 1) {
        if (index > 0) try content.append(allocator, '\n');
        try content.print(allocator, "Line {d}: ", .{index + 1});
        var filler: usize = 0;
        while (filler < 200) : (filler += 1) try content.append(allocator, 'x');
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "large-bytes.txt", .data = content.items });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "large-bytes.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{ .path = test_file }, .{});
    defer result.deinit(allocator);
    const output = try getTextOutputAlloc(allocator, result);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Line 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "of 500 (50.0KB limit). Use offset=") != null);
}

test "read handles offset and limit parameters" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var index: usize = 0;
    while (index < 100) : (index += 1) {
        if (index > 0) try content.append(allocator, '\n');
        try content.print(allocator, "Line {d}", .{index + 1});
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "offset-limit-test.txt", .data = content.items });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "offset-limit-test.txt" });
    defer allocator.free(test_file);

    var offset_result = try executeAlloc(allocator, io, root, .{ .path = test_file, .offset = 51 }, .{});
    defer offset_result.deinit(allocator);
    const offset_output = try getTextOutputAlloc(allocator, offset_result);
    defer allocator.free(offset_output);
    try std.testing.expect(std.mem.indexOf(u8, offset_output, "Line 50") == null);
    try std.testing.expect(std.mem.indexOf(u8, offset_output, "Line 51") != null);
    try std.testing.expect(std.mem.indexOf(u8, offset_output, "Line 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, offset_output, "Use offset=") == null);

    var limit_result = try executeAlloc(allocator, io, root, .{ .path = test_file, .limit = 10 }, .{});
    defer limit_result.deinit(allocator);
    const limit_output = try getTextOutputAlloc(allocator, limit_result);
    defer allocator.free(limit_output);
    try std.testing.expect(std.mem.indexOf(u8, limit_output, "Line 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, limit_output, "Line 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, limit_output, "Line 11") == null);
    try std.testing.expect(std.mem.indexOf(u8, limit_output, "[90 more lines in file. Use offset=11 to continue.]") != null);

    var both_result = try executeAlloc(allocator, io, root, .{ .path = test_file, .offset = 41, .limit = 20 }, .{});
    defer both_result.deinit(allocator);
    const both_output = try getTextOutputAlloc(allocator, both_result);
    defer allocator.free(both_output);
    try std.testing.expect(std.mem.indexOf(u8, both_output, "Line 40") == null);
    try std.testing.expect(std.mem.indexOf(u8, both_output, "Line 41") != null);
    try std.testing.expect(std.mem.indexOf(u8, both_output, "Line 60") != null);
    try std.testing.expect(std.mem.indexOf(u8, both_output, "Line 61") == null);
    try std.testing.expect(std.mem.indexOf(u8, both_output, "[40 more lines in file. Use offset=61 to continue.]") != null);
}

test "read rejects offset beyond file length" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "short.txt", .data = "Line 1\nLine 2\nLine 3" });
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "short.txt" });
    defer allocator.free(test_file);

    try std.testing.expectError(
        error.OffsetBeyondEndOfFile,
        executeAlloc(allocator, io, root, .{ .path = test_file, .offset = 100 }, .{}),
    );
}

test "read includes truncation details when truncated" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);
    var index: usize = 0;
    while (index < 2500) : (index += 1) {
        if (index > 0) try content.append(allocator, '\n');
        try content.print(allocator, "Line {d}", .{index + 1});
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "large-file.txt", .data = content.items });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "large-file.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{ .path = test_file }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.details != null);
    try std.testing.expect(result.details.?.truncation != null);
    try std.testing.expect(result.details.?.truncation.?.truncated);
    try std.testing.expectEqual(truncate.TruncationKind.lines, result.details.?.truncation.?.truncated_by.?);
    try std.testing.expectEqual(@as(usize, 2500), result.details.?.truncation.?.total_lines);
    try std.testing.expectEqual(@as(usize, 2000), result.details.?.truncation.?.output_lines);
}

test "read detects image MIME type from file magic and treats extension-only images as text" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
        0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9c, 0x63, 0x60, 0x60, 0xf8, 0x0f,
        0x00, 0x01, 0x04, 0x01, 0x00, 0x5f, 0xe5, 0xc3,
        0x4b, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
        0x44, 0xae, 0x42, 0x60, 0x82,
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "image.txt", .data = &png });
    try tmp.dir.writeFile(io, .{ .sub_path = "not-an-image.png", .data = "definitely not a png" });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const image_file = try std.fs.path.join(allocator, &.{ root, "image.txt" });
    defer allocator.free(image_file);
    const text_file = try std.fs.path.join(allocator, &.{ root, "not-an-image.png" });
    defer allocator.free(text_file);

    var image_result = try executeAlloc(allocator, io, root, .{ .path = image_file }, .{});
    defer image_result.deinit(allocator);
    const image_output = try getTextOutputAlloc(allocator, image_result);
    defer allocator.free(image_output);
    try std.testing.expect(std.mem.indexOf(u8, image_output, "Read image file [image/png]") != null);
    try std.testing.expectEqual(@as(usize, 2), image_result.content.len);
    try std.testing.expectEqual(render_utils.ToolContentKind.image, image_result.content[1].type);
    try std.testing.expectEqualStrings("image/png", image_result.content[1].mime_type.?);
    try std.testing.expect(image_result.content[1].data.?.len > 0);

    var text_result = try executeAlloc(allocator, io, root, .{ .path = text_file }, .{});
    defer text_result.deinit(allocator);
    const text_output = try getTextOutputAlloc(allocator, text_result);
    defer allocator.free(text_output);
    try std.testing.expect(std.mem.indexOf(u8, text_output, "definitely not a png") != null);
    try std.testing.expectEqual(@as(usize, 1), text_result.content.len);
}

test "read render call and result follow Pi collapsed and expanded behavior" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    const rendered_call = try formatReadCallAlloc(allocator, .{
        .path = "/Users/alice/project/src/main.zig",
        .offset = 5,
        .limit = 3,
    }, theme, "/Users/alice/project", .{ .home_dir = "/Users/alice" });
    defer allocator.free(rendered_call);
    try std.testing.expectEqualStrings(
        "<toolTitle><bold>read</></> <accent>~/project/src/main.zig</><warning>:5-7</>",
        rendered_call,
    );

    var blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    blocks[0] = render_utils.textBlock(try allocator.dupe(u8, "one\ntwo\nthree\nfour"));
    var result = ReadToolResult{ .content = blocks };
    defer result.deinit(allocator);

    const collapsed = try formatReadResultAlloc(allocator, .{ .path = "file.txt" }, result, .{}, theme, false, false);
    defer allocator.free(collapsed);
    try std.testing.expectEqualStrings("", collapsed);

    const expanded = try formatReadResultAlloc(allocator, .{ .path = "file.txt" }, result, .{ .expanded = true }, theme, false, false);
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("\n<toolOutput>one</>\n<toolOutput>two</>\n<toolOutput>three</>\n<toolOutput>four</>", expanded);
}
