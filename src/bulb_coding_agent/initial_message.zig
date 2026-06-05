const std = @import("std");
const ai = @import("bulb_ai");

pub const Args = struct {
    messages: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        self.messages.deinit(allocator);
        self.* = .{};
    }
};

pub const InitialMessageInput = struct {
    parsed: *Args,
    file_text: ?[]const u8 = null,
    file_images: []const ai.ImageContent = &.{},
    stdin_content: ?[]const u8 = null,
};

pub const InitialMessageResult = struct {
    initial_message: ?[]u8 = null,
    initial_images: ?[]const ai.ImageContent = null,

    pub fn deinit(self: *InitialMessageResult, allocator: std.mem.Allocator) void {
        if (self.initial_message) |message| allocator.free(message);
        self.* = .{};
    }
};

/// Combine stdin content, @file text, and the first CLI message into a single
/// initial prompt for non-interactive mode.
pub fn buildInitialMessageAlloc(
    allocator: std.mem.Allocator,
    input: InitialMessageInput,
) !InitialMessageResult {
    var message: std.ArrayList(u8) = .empty;
    errdefer message.deinit(allocator);

    if (input.stdin_content) |stdin_content| {
        try message.appendSlice(allocator, stdin_content);
    }
    if (input.file_text) |file_text| {
        if (file_text.len > 0) try message.appendSlice(allocator, file_text);
    }

    if (input.parsed.messages.items.len > 0) {
        try message.appendSlice(allocator, input.parsed.messages.items[0]);
        _ = input.parsed.messages.orderedRemove(0);
    }

    return .{
        .initial_message = if (message.items.len > 0) try message.toOwnedSlice(allocator) else null,
        .initial_images = if (input.file_images.len > 0) input.file_images else null,
    };
}

fn createArgs(messages: []const []const u8) !Args {
    var args: Args = .{};
    errdefer args.deinit(std.testing.allocator);
    try args.messages.appendSlice(std.testing.allocator, messages);
    return args;
}

fn expectMessages(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_message, actual_message| {
        try std.testing.expectEqualStrings(expected_message, actual_message);
    }
}

// Ported from packages/coding-agent/test/initial-message.test.ts.
test "buildInitialMessage merges piped stdin with the first CLI message into one prompt" {
    var parsed = try createArgs(&.{"Summarize the text given"});
    defer parsed.deinit(std.testing.allocator);

    var result = try buildInitialMessageAlloc(std.testing.allocator, .{
        .parsed = &parsed,
        .stdin_content = "README contents\n",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.initial_message != null);
    try std.testing.expectEqualStrings("README contents\nSummarize the text given", result.initial_message.?);
    try expectMessages(parsed.messages.items, &.{});
}

test "buildInitialMessage uses stdin as the initial prompt when no CLI message is present" {
    var parsed = try createArgs(&.{});
    defer parsed.deinit(std.testing.allocator);

    var result = try buildInitialMessageAlloc(std.testing.allocator, .{
        .parsed = &parsed,
        .stdin_content = "README contents",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.initial_message != null);
    try std.testing.expectEqualStrings("README contents", result.initial_message.?);
    try expectMessages(parsed.messages.items, &.{});
}

test "buildInitialMessage combines stdin file text and first CLI message in one prompt" {
    var parsed = try createArgs(&.{ "Explain it", "Second message" });
    defer parsed.deinit(std.testing.allocator);

    var result = try buildInitialMessageAlloc(std.testing.allocator, .{
        .parsed = &parsed,
        .stdin_content = "stdin\n",
        .file_text = "file\n",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.initial_message != null);
    try std.testing.expectEqualStrings("stdin\nfile\nExplain it", result.initial_message.?);
    try expectMessages(parsed.messages.items, &.{"Second message"});
}
