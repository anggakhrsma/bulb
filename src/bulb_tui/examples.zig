const std = @import("std");
const tui = @import("bulb_tui");

pub const default_select_list_theme = tui.SelectListTheme{
    .selected_prefix = .{ .apply_fn = ansiBlue },
    .selected_text = .{ .apply_fn = ansiBold },
    .description = .{ .apply_fn = ansiDim },
    .scroll_info = .{ .apply_fn = ansiDim },
    .no_match = .{ .apply_fn = ansiDim },
};

pub const default_markdown_theme = tui.MarkdownTheme{
    .heading = .{ .apply_fn = ansiBoldCyan },
    .link = .{ .apply_fn = ansiBlue },
    .link_url = .{ .apply_fn = ansiDim },
    .code = .{ .apply_fn = ansiYellow },
    .code_block = .{ .apply_fn = ansiGreen },
    .code_block_border = .{ .apply_fn = ansiDim },
    .quote = .{ .apply_fn = ansiItalic },
    .quote_border = .{ .apply_fn = ansiDim },
    .hr = .{ .apply_fn = ansiDim },
    .list_bullet = .{ .apply_fn = ansiCyan },
    .bold = .{ .apply_fn = ansiBold },
    .italic = .{ .apply_fn = ansiItalic },
    .strikethrough = .{ .apply_fn = ansiStrikethrough },
    .underline = .{ .apply_fn = ansiUnderline },
};

pub const default_editor_theme = tui.EditorTheme{
    .border_color = .{ .apply_fn = ansiDim },
    .select_list = default_select_list_theme,
};

pub const SIMPLE_CHAT_WELCOME =
    "Welcome to Simple Chat!\n\n" ++
    "Type your messages below. Type '/' for commands. Press Ctrl+C to exit.";

pub const SIMPLE_CHAT_RESPONSES = [_][]const u8{
    "That's interesting! Tell me more.",
    "I see what you mean.",
    "Fascinating perspective!",
    "Could you elaborate on that?",
    "That makes sense to me.",
    "I hadn't thought of it that way.",
    "Great point!",
    "Thanks for sharing that.",
};

const SIMPLE_CHAT_SLASH_COMMANDS = [_]tui.SlashCommand{
    .{ .name = "delete", .description = "Delete the last message" },
    .{ .name = "clear", .description = "Clear all messages" },
};

pub fn simpleChatSlashCommands() []const tui.SlashCommand {
    return SIMPLE_CHAT_SLASH_COMMANDS[0..];
}

pub fn simpleChatResponse(index: usize) []const u8 {
    return SIMPLE_CHAT_RESPONSES[index % SIMPLE_CHAT_RESPONSES.len];
}

pub fn renderSimpleChatInitialFrame(allocator: std.mem.Allocator, width: usize, cwd: []const u8) ![][]u8 {
    var welcome = try tui.Text.init(allocator, SIMPLE_CHAT_WELCOME, 1, 1, null);
    defer welcome.deinit();
    var editor = try tui.Editor.init(allocator, .{});
    defer editor.deinit();
    var provider = try tui.CombinedAutocompleteProvider.init(allocator, simpleChatSlashCommands(), cwd, null);
    defer provider.deinit();
    editor.setAutocompleteProvider(provider.provider());
    editor.focused = true;

    const welcome_lines = try welcome.render(allocator, width);
    errdefer tui.freeRenderedLines(allocator, welcome_lines);
    const editor_lines = try editor.render(allocator, width);
    errdefer tui.freeRenderedLines(allocator, editor_lines);

    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |line| allocator.free(line);
        result.deinit(allocator);
    }
    for (welcome_lines) |line| try result.append(allocator, line);
    for (editor_lines) |line| try result.append(allocator, line);
    allocator.free(welcome_lines);
    allocator.free(editor_lines);
    return result.toOwnedSlice(allocator);
}

pub const ImageTestSummary = struct {
    dimensions: ?tui.ImageDimensions,
    capabilities: tui.TerminalCapabilities,
};

pub fn inspectImageForDemo(allocator: std.mem.Allocator, base64_data: []const u8, mime_type: []const u8) ImageTestSummary {
    return .{
        .dimensions = tui.getImageDimensions(allocator, base64_data, mime_type),
        .capabilities = tui.getCapabilities(),
    };
}

pub fn loadImageFileForDemo(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
}

pub fn renderImageTestFrame(
    allocator: std.mem.Allocator,
    base64_data: []const u8,
    mime_type: []const u8,
    dimensions: ?tui.ImageDimensions,
    width: usize,
) ![][]u8 {
    var title = try tui.Text.init(allocator, "Image Rendering Test", 1, 1, null);
    defer title.deinit();
    var top_spacer = tui.Spacer.init(1);
    var image = try tui.Image.init(
        allocator,
        base64_data,
        mime_type,
        .{ .fallback_color = .{ .apply_fn = ansiYellow } },
        .{ .max_width_cells = 60 },
        dimensions,
    );
    defer image.deinit();
    var bottom_spacer = tui.Spacer.init(1);
    var footer = try tui.Text.init(allocator, "Press Ctrl+C to exit", 1, 0, null);
    defer footer.deinit();

    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |line| allocator.free(line);
        result.deinit(allocator);
    }
    try appendRenderedComponent(allocator, &result, &title, width);
    try appendRenderedComponent(allocator, &result, &top_spacer, width);
    try appendRenderedComponent(allocator, &result, &image, width);
    try appendRenderedComponent(allocator, &result, &bottom_spacer, width);
    try appendRenderedComponent(allocator, &result, &footer, width);
    return result.toOwnedSlice(allocator);
}

pub const KeyLogger = struct {
    allocator: std.mem.Allocator,
    log: std.ArrayList([]u8) = .empty,
    max_lines: usize = 20,
    exited: bool = false,

    pub fn init(allocator: std.mem.Allocator) KeyLogger {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KeyLogger) void {
        for (self.log.items) |line| self.allocator.free(line);
        self.log.deinit(self.allocator);
    }

    pub fn handleInput(self: *KeyLogger, _: std.mem.Allocator, data: []const u8) !void {
        if (tui.matchesKey(data, "ctrl+c")) {
            self.exited = true;
            return;
        }

        const hex = try hexLower(self.allocator, data);
        defer self.allocator.free(hex);
        const chars = try charCodes(self.allocator, data);
        defer self.allocator.free(chars);
        const repr = try reprInput(self.allocator, data);
        defer self.allocator.free(repr);
        const padded_hex = try padEnd(self.allocator, hex, 20);
        defer self.allocator.free(padded_hex);
        const padded_chars = try padEnd(self.allocator, chars, 15);
        defer self.allocator.free(padded_chars);
        const line = try std.fmt.allocPrint(
            self.allocator,
            "Hex: {s} | Chars: [{s}] | Repr: \"{s}\"",
            .{ padded_hex, padded_chars, repr },
        );

        try self.log.append(self.allocator, line);
        if (self.log.items.len > self.max_lines) {
            const dropped = self.log.orderedRemove(0);
            self.allocator.free(dropped);
        }
    }

    pub fn invalidate(_: *KeyLogger) void {}

    pub fn render(self: *KeyLogger, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        try lines.append(allocator, try repeatedByte(allocator, '=', width));
        try lines.append(allocator, try padEnd(allocator, "Key Code Tester - Press keys to see their codes (Ctrl+C to exit)", width));
        try lines.append(allocator, try repeatedByte(allocator, '=', width));
        try lines.append(allocator, try allocator.dupe(u8, ""));
        for (self.log.items) |entry| try lines.append(allocator, try padEnd(allocator, entry, width));

        const remaining = 25 -| lines.items.len;
        var index: usize = 0;
        while (index < remaining) : (index += 1) {
            try lines.append(allocator, try repeatedByte(allocator, ' ', width));
        }

        try lines.append(allocator, try repeatedByte(allocator, '=', width));
        try lines.append(allocator, try padEnd(allocator, "Test these:", width));
        try lines.append(allocator, try padEnd(allocator, "  - Shift + Enter (should show: \\x1b[13;2u with Kitty protocol)", width));
        try lines.append(allocator, try padEnd(allocator, "  - Alt/Option + Enter", width));
        try lines.append(allocator, try padEnd(allocator, "  - Option/Alt + Backspace", width));
        try lines.append(allocator, try padEnd(allocator, "  - Cmd/Ctrl + Backspace", width));
        try lines.append(allocator, try padEnd(allocator, "  - Regular Backspace", width));
        try lines.append(allocator, try repeatedByte(allocator, '=', width));
        return lines.toOwnedSlice(allocator);
    }
};

fn appendRenderedComponent(
    allocator: std.mem.Allocator,
    result: *std.ArrayList([]u8),
    component: anytype,
    width: usize,
) !void {
    const rendered = try component.render(allocator, width);
    errdefer tui.freeRenderedLines(allocator, rendered);
    for (rendered) |line| try result.append(allocator, line);
    allocator.free(rendered);
}

fn ansiBlue(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[34m{s}\x1b[39m", .{text});
}

fn ansiBold(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[1m{s}\x1b[22m", .{text});
}

fn ansiDim(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[2m{s}\x1b[22m", .{text});
}

fn ansiYellow(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[33m{s}\x1b[39m", .{text});
}

fn ansiGreen(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[32m{s}\x1b[39m", .{text});
}

fn ansiCyan(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[36m{s}\x1b[39m", .{text});
}

fn ansiBoldCyan(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[1m\x1b[36m{s}\x1b[39m\x1b[22m", .{text});
}

fn ansiItalic(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[3m{s}\x1b[23m", .{text});
}

fn ansiStrikethrough(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[9m{s}\x1b[29m", .{text});
}

fn ansiUnderline(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[4m{s}\x1b[24m", .{text});
}

fn repeatedByte(allocator: std.mem.Allocator, byte: u8, count: usize) ![]u8 {
    const result = try allocator.alloc(u8, count);
    @memset(result, byte);
    return result;
}

fn padEnd(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    const visible = tui.visibleWidth(text);
    if (visible >= width) return allocator.dupe(u8, text);
    var result = try allocator.alloc(u8, text.len + (width - visible));
    @memcpy(result[0..text.len], text);
    @memset(result[text.len..], ' ');
    return result;
}

fn hexLower(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const digits = "0123456789abcdef";
    const result = try allocator.alloc(u8, data.len * 2);
    for (data, 0..) |byte, index| {
        result[index * 2] = digits[byte >> 4];
        result[index * 2 + 1] = digits[byte & 0x0f];
    }
    return result;
}

fn charCodes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (data, 0..) |byte, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.print(allocator, "{d}", .{byte});
    }
    return out.toOwnedSlice(allocator);
}

fn reprInput(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (data) |byte| {
        switch (byte) {
            0x1b => try out.appendSlice(allocator, "\\x1b"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x7f => try out.appendSlice(allocator, "\\x7f"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f => try out.print(allocator, "\\x{x:0>2}", .{byte}),
            else => try out.append(allocator, byte),
        }
    }
    return out.toOwnedSlice(allocator);
}

test "default TUI test themes apply chalk-compatible ANSI wrappers" {
    const allocator = std.testing.allocator;
    const selected = try default_select_list_theme.selected_prefix.apply(allocator, ">");
    defer allocator.free(selected);
    try std.testing.expectEqualStrings("\x1b[34m>\x1b[39m", selected);

    const heading = try default_markdown_theme.heading.apply(allocator, "Title");
    defer allocator.free(heading);
    try std.testing.expect(std.mem.indexOf(u8, heading, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, heading, "\x1b[36m") != null);
}

test "simple chat demo renders the welcome frame and slash commands" {
    const allocator = std.testing.allocator;
    var provider = try tui.CombinedAutocompleteProvider.init(allocator, simpleChatSlashCommands(), ".", null);
    defer provider.deinit();
    var lines_input = [_][]const u8{"/"};
    const suggestions = (try provider.provider().getSuggestions(allocator, lines_input[0..], 0, 1, .{})).?;
    defer suggestions.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), suggestions.items.len);
    try std.testing.expectEqualStrings("delete", suggestions.items[0].value);
    try std.testing.expectEqualStrings("clear", suggestions.items[1].value);
    try std.testing.expectEqualStrings("That's interesting! Tell me more.", simpleChatResponse(0));
    try std.testing.expectEqualStrings("I see what you mean.", simpleChatResponse(9));

    const rendered = try renderSimpleChatInitialFrame(allocator, 72, ".");
    defer tui.freeRenderedLines(allocator, rendered);
    const joined = try std.mem.join(allocator, "\n", rendered);
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Welcome to Simple Chat!") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Type your messages below.") != null);
}

test "image demo inspects dimensions and renders a fallback frame" {
    const allocator = std.testing.allocator;
    const one_by_one_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=";
    const previous_caps = tui.getCapabilities();
    tui.setCapabilities(.{ .images = null, .true_color = true, .hyperlinks = false });
    defer tui.setCapabilities(previous_caps);

    const summary = inspectImageForDemo(allocator, one_by_one_png, "image/png");
    try std.testing.expectEqual(@as(usize, 1), summary.dimensions.?.width_px);
    try std.testing.expectEqual(@as(usize, 1), summary.dimensions.?.height_px);
    try std.testing.expect(summary.capabilities.images == null);

    const rendered = try renderImageTestFrame(allocator, one_by_one_png, "image/png", summary.dimensions, 80);
    defer tui.freeRenderedLines(allocator, rendered);
    const joined = try std.mem.join(allocator, "\n", rendered);
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Image Rendering Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "[Image: [image/png] 1x1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Press Ctrl+C to exit") != null);
}

test "key logger formats input and exits on Ctrl-C" {
    const allocator = std.testing.allocator;
    var logger = KeyLogger.init(allocator);
    defer logger.deinit();
    try logger.handleInput(allocator, "\x1b[13;2u");
    try logger.handleInput(allocator, "\t");
    try logger.handleInput(allocator, "a");
    try std.testing.expectEqual(@as(usize, 3), logger.log.items.len);
    try std.testing.expect(std.mem.indexOf(u8, logger.log.items[0], "Hex: 1b5b31333b3275") != null);
    try std.testing.expect(std.mem.indexOf(u8, logger.log.items[0], "Repr: \"\\x1b[13;2u\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, logger.log.items[1], "Repr: \"\\t\"") != null);

    const rendered = try logger.render(allocator, 72);
    defer tui.freeRenderedLines(allocator, rendered);
    try std.testing.expectEqualStrings("========================================================================", rendered[0]);
    try std.testing.expect(std.mem.indexOf(u8, rendered[1], "Key Code Tester") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[rendered.len - 2], "Regular Backspace") != null);

    try logger.handleInput(allocator, "\x03");
    try std.testing.expect(logger.exited);
}
