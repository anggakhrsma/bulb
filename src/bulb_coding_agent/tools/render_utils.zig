const std = @import("std");

const ai = @import("bulb_ai");
const tui = @import("bulb_tui");
const ansi = @import("../ansi.zig");
const paths = @import("../paths.zig");
const shell = @import("../shell.zig");

pub const ThemeColor = enum {
    accent,
    dim,
    @"error",
    muted,
    tool_title,
    tool_output,
    warning,
};

pub const RenderTheme = struct {
    ptr: ?*anyopaque = null,
    bold_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8 = defaultBoldAlloc,
    fg_fn: *const fn (?*anyopaque, std.mem.Allocator, ThemeColor, []const u8) anyerror![]u8 = defaultFgAlloc,

    pub fn boldAlloc(self: RenderTheme, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.bold_fn(self.ptr, allocator, text);
    }

    pub fn fgAlloc(self: RenderTheme, allocator: std.mem.Allocator, color: ThemeColor, text: []const u8) ![]u8 {
        return self.fg_fn(self.ptr, allocator, color, text);
    }
};

pub const ToolRenderResultOptions = struct {
    expanded: bool = false,
};

pub const RenderToolPathOptions = struct {
    empty_fallback: ?[]const u8 = null,
    home_dir: ?[]const u8 = null,
};

pub const ToolContentKind = enum {
    text,
    image,
    other,
};

pub const ToolContentBlock = struct {
    type: ToolContentKind,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
};

pub const ToolRenderResultLike = struct {
    content: []const ToolContentBlock,
};

pub fn textBlock(text: []const u8) ToolContentBlock {
    return .{ .type = .text, .text = text };
}

pub fn imageBlock(data: ?[]const u8, mime_type: ?[]const u8) ToolContentBlock {
    return .{ .type = .image, .data = data, .mime_type = mime_type };
}

pub fn shortenPathAlloc(allocator: std.mem.Allocator, maybe_path: ?[]const u8, home_dir: ?[]const u8) ![]u8 {
    const path = maybe_path orelse return allocator.dupe(u8, "");
    if (home_dir) |home| {
        if (home.len > 0 and std.mem.startsWith(u8, path, home)) {
            return std.fmt.allocPrint(allocator, "~{s}", .{path[home.len..]});
        }
    }
    return allocator.dupe(u8, path);
}

pub fn linkPathAlloc(
    allocator: std.mem.Allocator,
    styled_text: []const u8,
    raw_path: []const u8,
    cwd: []const u8,
) ![]u8 {
    if (!tui.getCapabilities().hyperlinks) return allocator.dupe(u8, styled_text);

    const absolute_path = try paths.resolvePathAlloc(allocator, raw_path, cwd, .{});
    defer allocator.free(absolute_path);
    const url = try fileUrlFromPathAlloc(allocator, absolute_path);
    defer allocator.free(url);
    return tui.hyperlink(allocator, styled_text, url);
}

pub fn stringOrEmpty(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return "";
    return switch (actual) {
        .string => |string| string,
        .null => "",
        else => null,
    };
}

pub fn replaceTabsAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return allocator.dupe(u8, text);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (text) |byte| {
        if (byte == '\t') {
            try output.appendSlice(allocator, "   ");
        } else {
            try output.append(allocator, byte);
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn normalizeDisplayTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return allocator.dupe(u8, text);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (text) |byte| {
        if (byte != '\r') try output.append(allocator, byte);
    }
    return output.toOwnedSlice(allocator);
}

pub fn getTextOutputAlloc(
    allocator: std.mem.Allocator,
    maybe_result: ?ToolRenderResultLike,
    show_images: bool,
) ![]u8 {
    const result = maybe_result orelse return allocator.dupe(u8, "");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var text_blocks: usize = 0;
    var image_blocks: usize = 0;

    for (result.content) |content| {
        switch (content.type) {
            .text => {
                const stripped = try ansi.stripAnsiAlloc(allocator, content.text orelse "");
                defer allocator.free(stripped);
                const sanitized = try shell.sanitizeBinaryOutputAlloc(allocator, stripped);
                defer allocator.free(sanitized);
                const normalized = try normalizeDisplayTextAlloc(allocator, sanitized);
                defer allocator.free(normalized);

                if (text_blocks > 0) try output.append(allocator, '\n');
                try output.appendSlice(allocator, normalized);
                text_blocks += 1;
            },
            .image => image_blocks += 1,
            .other => {},
        }
    }

    const caps = tui.getCapabilities();
    if (image_blocks > 0 and (caps.images == null or !show_images)) {
        var emitted_images: usize = 0;
        for (result.content) |content| {
            if (content.type != .image) continue;
            const mime_type = content.mime_type orelse "image/unknown";
            const dimensions = if (content.data != null and content.mime_type != null)
                tui.getImageDimensions(allocator, content.data.?, content.mime_type.?)
            else
                null;
            const fallback = try tui.imageFallback(allocator, mime_type, dimensions, null);
            defer allocator.free(fallback);

            if (text_blocks > 0 or emitted_images > 0) try output.append(allocator, '\n');
            try output.appendSlice(allocator, fallback);
            emitted_images += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

pub fn invalidArgTextAlloc(allocator: std.mem.Allocator, theme: RenderTheme) ![]u8 {
    return theme.fgAlloc(allocator, .@"error", "[invalid arg]");
}

pub fn renderToolPathAlloc(
    allocator: std.mem.Allocator,
    raw_path: ?[]const u8,
    theme: RenderTheme,
    cwd: []const u8,
    options: RenderToolPathOptions,
) ![]u8 {
    if (raw_path == null) return invalidArgTextAlloc(allocator, theme);

    const value = if (raw_path.?.len > 0) raw_path.? else options.empty_fallback;
    if (value == null or value.?.len == 0) return theme.fgAlloc(allocator, .tool_output, "...");

    const shortened = try shortenPathAlloc(allocator, value.?, options.home_dir);
    defer allocator.free(shortened);
    const styled = try theme.fgAlloc(allocator, .accent, shortened);
    defer allocator.free(styled);
    return linkPathAlloc(allocator, styled, value.?, cwd);
}

pub fn textBlockFromAi(content: ai.TextContent) ToolContentBlock {
    return textBlock(content.text);
}

pub fn imageBlockFromAi(content: ai.ImageContent) ToolContentBlock {
    return imageBlock(content.data, content.mime_type);
}

pub fn fileUrlFromPathAlloc(allocator: std.mem.Allocator, absolute_path: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator, "file://");
    if (needsLeadingSlashForFileUrl(absolute_path)) try output.append(allocator, '/');

    for (absolute_path) |byte| {
        const normalized = if (byte == '\\') '/' else byte;
        if (isFileUrlPathByte(normalized)) {
            try output.append(allocator, normalized);
        } else {
            try output.print(allocator, "%{X:0>2}", .{normalized});
        }
    }

    return output.toOwnedSlice(allocator);
}

fn defaultFgAlloc(_: ?*anyopaque, allocator: std.mem.Allocator, _: ThemeColor, text: []const u8) ![]u8 {
    return allocator.dupe(u8, text);
}

fn defaultBoldAlloc(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return allocator.dupe(u8, text);
}

fn needsLeadingSlashForFileUrl(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path[0] == '/' or path[0] == '\\') return false;
    return true;
}

fn isFileUrlPathByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or
        byte == '-' or
        byte == '_' or
        byte == '.' or
        byte == '~' or
        byte == '/' or
        byte == ':';
}

const StyledTestTheme = struct {
    pub fn fg(_: ?*anyopaque, allocator: std.mem.Allocator, color: ThemeColor, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "<{s}>{s}</>", .{ colorName(color), text });
    }
};

fn colorName(color: ThemeColor) []const u8 {
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

fn styledTestTheme() RenderTheme {
    return .{ .fg_fn = StyledTestTheme.fg };
}

test "shortenPath mirrors Pi home-prefix handling" {
    const allocator = std.testing.allocator;

    const home = try shortenPathAlloc(allocator, "/Users/alice/project/file.txt", "/Users/alice");
    defer allocator.free(home);
    try std.testing.expectEqualStrings("~/project/file.txt", home);

    const exact_home = try shortenPathAlloc(allocator, "/Users/alice", "/Users/alice");
    defer allocator.free(exact_home);
    try std.testing.expectEqualStrings("~", exact_home);

    const null_path = try shortenPathAlloc(allocator, null, "/Users/alice");
    defer allocator.free(null_path);
    try std.testing.expectEqualStrings("", null_path);
}

test "stringOrEmpty ports TypeScript string/null argument helper" {
    try std.testing.expectEqualStrings("file.txt", stringOrEmpty(.{ .string = "file.txt" }).?);
    try std.testing.expectEqualStrings("", stringOrEmpty(null).?);
    try std.testing.expectEqualStrings("", stringOrEmpty(.null).?);
    try std.testing.expect(stringOrEmpty(.{ .integer = 42 }) == null);
}

test "replaceTabs and normalizeDisplayText match render helpers" {
    const allocator = std.testing.allocator;

    const tabs = try replaceTabsAlloc(allocator, "a\tb\t");
    defer allocator.free(tabs);
    try std.testing.expectEqualStrings("a   b   ", tabs);

    const normalized = try normalizeDisplayTextAlloc(allocator, "a\rb\r\nc");
    defer allocator.free(normalized);
    try std.testing.expectEqualStrings("ab\nc", normalized);
}

test "fileUrlFromPath percent-encodes pathToFileURL-sensitive bytes" {
    const allocator = std.testing.allocator;

    const url = try fileUrlFromPathAlloc(allocator, "/tmp/a file#1?.txt");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("file:///tmp/a%20file%231%3F.txt", url);
}

test "linkPath respects terminal hyperlink capabilities" {
    const allocator = std.testing.allocator;
    tui.setCapabilities(.{ .images = null, .true_color = true, .hyperlinks = false });
    defer tui.resetCapabilitiesCache();

    const plain = try linkPathAlloc(allocator, "shown", "a file.txt", "/tmp");
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("shown", plain);

    tui.setCapabilities(.{ .images = null, .true_color = true, .hyperlinks = true });
    const linked = try linkPathAlloc(allocator, "shown", "a file.txt", "/tmp");
    defer allocator.free(linked);
    try std.testing.expect(std.mem.startsWith(u8, linked, "\x1b]8;;file:///tmp/a%20file.txt\x1b\\shown"));
}

test "getTextOutput strips ANSI sanitizes controls normalizes CR and appends image fallbacks" {
    const allocator = std.testing.allocator;
    tui.setCapabilities(.{ .images = null, .true_color = true, .hyperlinks = false });
    defer tui.resetCapabilitiesCache();

    const blocks = [_]ToolContentBlock{
        textBlock("\x1b[31mhello\r\x1b[0m\x00"),
        textBlock("world"),
        imageBlock(null, "image/png"),
    };
    const output = try getTextOutputAlloc(allocator, .{ .content = &blocks }, true);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("hello\nworld\n[Image: [image/png]]", output);
}

test "getTextOutput hides fallback when terminal images are available and showImages is true" {
    const allocator = std.testing.allocator;
    tui.setCapabilities(.{ .images = .kitty, .true_color = true, .hyperlinks = true });
    defer tui.resetCapabilitiesCache();

    const blocks = [_]ToolContentBlock{
        textBlock("text"),
        imageBlock(null, "image/png"),
    };
    const output = try getTextOutputAlloc(allocator, .{ .content = &blocks }, true);
    defer allocator.free(output);

    try std.testing.expectEqualStrings("text", output);
}

test "renderToolPath styles invalid empty and linked path displays" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();
    tui.setCapabilities(.{ .images = null, .true_color = true, .hyperlinks = false });
    defer tui.resetCapabilitiesCache();

    const invalid = try renderToolPathAlloc(allocator, null, theme, "/tmp", .{});
    defer allocator.free(invalid);
    try std.testing.expectEqualStrings("<error>[invalid arg]</>", invalid);

    const empty = try renderToolPathAlloc(allocator, "", theme, "/tmp", .{});
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("<toolOutput>...</>", empty);

    const fallback = try renderToolPathAlloc(allocator, "", theme, "/tmp", .{ .empty_fallback = "." });
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("<accent>.</>", fallback);

    const home_path = try renderToolPathAlloc(allocator, "/Users/alice/file.txt", theme, "/tmp", .{ .home_dir = "/Users/alice" });
    defer allocator.free(home_path);
    try std.testing.expectEqualStrings("<accent>~/file.txt</>", home_path);
}
