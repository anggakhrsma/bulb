const std = @import("std");
const ai = @import("bulb_ai");
const tui = @import("bulb_tui");

pub const OSC133_ZONE_START = "\x1b]133;A\x07";
pub const OSC133_ZONE_END = "\x1b]133;B\x07";
pub const OSC133_ZONE_FINAL = "\x1b]133;C\x07";

pub const AssistantMessageComponent = struct {
    allocator: std.mem.Allocator,
    hide_thinking_block: bool = false,
    hidden_thinking_label: []u8,
    last_message: ?ai.AssistantMessage = null,

    pub fn init(
        allocator: std.mem.Allocator,
        message: ?ai.AssistantMessage,
        hide_thinking_block: bool,
        hidden_thinking_label: []const u8,
    ) !AssistantMessageComponent {
        return .{
            .allocator = allocator,
            .hide_thinking_block = hide_thinking_block,
            .hidden_thinking_label = try allocator.dupe(u8, hidden_thinking_label),
            .last_message = message,
        };
    }

    pub fn deinit(self: *AssistantMessageComponent) void {
        self.allocator.free(self.hidden_thinking_label);
        self.* = undefined;
    }

    pub fn invalidate(_: *AssistantMessageComponent) void {}

    pub fn setHideThinkingBlock(self: *AssistantMessageComponent, hide: bool) void {
        self.hide_thinking_block = hide;
    }

    pub fn setHiddenThinkingLabel(self: *AssistantMessageComponent, label: []const u8) !void {
        const next = try self.allocator.dupe(u8, label);
        self.allocator.free(self.hidden_thinking_label);
        self.hidden_thinking_label = next;
    }

    pub fn updateContent(self: *AssistantMessageComponent, message: ai.AssistantMessage) void {
        self.last_message = message;
    }

    pub fn render(self: *AssistantMessageComponent, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        const message = self.last_message orelse return allocator.alloc([]u8, 0);
        return renderAssistantMessageAlloc(allocator, message, .{
            .width = width,
            .hide_thinking_block = self.hide_thinking_block,
            .hidden_thinking_label = self.hidden_thinking_label,
        });
    }
};

pub const RenderAssistantMessageOptions = struct {
    width: usize,
    hide_thinking_block: bool = false,
    hidden_thinking_label: []const u8 = "Thinking...",
    markdown_theme: tui.MarkdownTheme = .{},
};

pub fn renderAssistantMessageAlloc(
    allocator: std.mem.Allocator,
    message: ai.AssistantMessage,
    options: RenderAssistantMessageOptions,
) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer tui.freeRenderedLines(allocator, lines.items);

    const visible_content = hasVisibleContent(message);
    if (visible_content) try appendSpacer(allocator, &lines);

    for (message.content, 0..) |content, index| {
        switch (content) {
            .text => |text| {
                const trimmed = std.mem.trim(u8, text.text, " \t\r\n");
                if (trimmed.len == 0) continue;
                var markdown = try tui.Markdown.init(allocator, trimmed, 1, 0, options.markdown_theme, null, .{});
                defer markdown.deinit();
                try appendRenderedComponent(allocator, &lines, &markdown, options.width);
            },
            .thinking => |thinking| {
                const trimmed = std.mem.trim(u8, thinking.thinking, " \t\r\n");
                if (trimmed.len == 0) continue;

                if (options.hide_thinking_block) {
                    var text = try tui.Text.init(allocator, options.hidden_thinking_label, 1, 0, null);
                    defer text.deinit();
                    try appendRenderedComponent(allocator, &lines, &text, options.width);
                } else {
                    var markdown = try tui.Markdown.init(allocator, trimmed, 1, 0, options.markdown_theme, .{ .italic = true }, .{});
                    defer markdown.deinit();
                    try appendRenderedComponent(allocator, &lines, &markdown, options.width);
                }

                if (hasVisibleContentAfter(message.content, index + 1)) {
                    try appendSpacer(allocator, &lines);
                }
            },
            .tool_call => {},
        }
    }

    const has_tools = hasToolCalls(message);
    if (!has_tools) {
        switch (message.stop_reason) {
            .aborted => {
                try appendSpacer(allocator, &lines);
                const abort_message = if (message.error_message) |error_message|
                    if (!std.mem.eql(u8, error_message, "Request was aborted")) error_message else "Operation aborted"
                else
                    "Operation aborted";
                var text = try tui.Text.init(allocator, abort_message, 1, 0, null);
                defer text.deinit();
                try appendRenderedComponent(allocator, &lines, &text, options.width);
            },
            .@"error" => {
                try appendSpacer(allocator, &lines);
                const error_message = message.error_message orelse "Unknown error";
                const formatted = try std.fmt.allocPrint(allocator, "Error: {s}", .{error_message});
                defer allocator.free(formatted);
                var text = try tui.Text.init(allocator, formatted, 1, 0, null);
                defer text.deinit();
                try appendRenderedComponent(allocator, &lines, &text, options.width);
            },
            else => {},
        }
    }

    if (!has_tools and lines.items.len > 0) {
        try addOsc133ZoneMarkers(allocator, lines.items);
    }

    return lines.toOwnedSlice(allocator);
}

fn hasVisibleContent(message: ai.AssistantMessage) bool {
    return hasVisibleContentAfter(message.content, 0);
}

fn hasVisibleContentAfter(content: []const ai.AssistantContent, start: usize) bool {
    var index = start;
    while (index < content.len) : (index += 1) {
        switch (content[index]) {
            .text => |text| if (std.mem.trim(u8, text.text, " \t\r\n").len > 0) return true,
            .thinking => |thinking| if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len > 0) return true,
            .tool_call => {},
        }
    }
    return false;
}

fn hasToolCalls(message: ai.AssistantMessage) bool {
    for (message.content) |content| {
        if (content == .tool_call) return true;
    }
    return false;
}

fn appendSpacer(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8)) !void {
    try lines.append(allocator, try allocator.dupe(u8, ""));
}

fn appendRenderedComponent(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]u8),
    component: anytype,
    width: usize,
) !void {
    const rendered = try component.render(allocator, width);
    defer allocator.free(rendered);
    for (rendered) |line| try lines.append(allocator, line);
}

fn addOsc133ZoneMarkers(allocator: std.mem.Allocator, lines: [][]u8) !void {
    lines[0] = try prefixLine(allocator, OSC133_ZONE_START, lines[0]);
    const last_index = lines.len - 1;
    const final_prefix = OSC133_ZONE_END ++ OSC133_ZONE_FINAL;
    lines[last_index] = try prefixLine(allocator, final_prefix, lines[last_index]);
}

fn prefixLine(allocator: std.mem.Allocator, prefix: []const u8, line: []u8) ![]u8 {
    const next = try std.mem.concat(allocator, u8, &.{ prefix, line });
    allocator.free(line);
    return next;
}

fn createAssistantMessage(content: []const ai.AssistantContent) ai.AssistantMessage {
    return .{
        .content = content,
        .api = "openai-responses",
        .provider = "openai",
        .model = "gpt-4o-mini",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp_ms = 1,
    };
}

test "AssistantMessageComponent adds OSC 133 zone markers to assistant messages without tool calls" {
    const allocator = std.testing.allocator;
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello" } }};
    const message = createAssistantMessage(&content);

    var component = try AssistantMessageComponent.init(allocator, message, false, "Thinking...");
    defer component.deinit();

    const lines = try component.render(allocator, 40);
    defer tui.freeRenderedLines(allocator, lines);

    try std.testing.expect(lines.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], OSC133_ZONE_START) != null);
    try std.testing.expect(std.mem.startsWith(u8, lines[lines.len - 1], OSC133_ZONE_END ++ OSC133_ZONE_FINAL));
}

test "AssistantMessageComponent does not add OSC 133 zone markers when assistant message contains tool calls" {
    const allocator = std.testing.allocator;
    const content = [_]ai.AssistantContent{
        .{ .text = .{ .text = "calling tool" } },
        .{ .tool_call = .{ .id = "tool-1", .name = "read", .arguments_json = "{\"path\":\"file.txt\"}" } },
    };
    const message = createAssistantMessage(&content);

    var component = try AssistantMessageComponent.init(allocator, message, false, "Thinking...");
    defer component.deinit();

    const lines = try component.render(allocator, 60);
    defer tui.freeRenderedLines(allocator, lines);

    for (lines) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, OSC133_ZONE_START) == null);
        try std.testing.expect(std.mem.indexOf(u8, line, OSC133_ZONE_END) == null);
        try std.testing.expect(std.mem.indexOf(u8, line, OSC133_ZONE_FINAL) == null);
    }
}
