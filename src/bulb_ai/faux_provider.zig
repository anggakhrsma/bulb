const std = @import("std");
const types = @import("types.zig");

pub const FauxProvider = struct {
    provider: []const u8 = "faux",
    model: []const u8 = "faux-model",
    responses: std.ArrayList(types.AssistantMessage) = .empty,
    next_response: usize = 0,
    call_count: usize = 0,

    pub fn deinit(self: *FauxProvider, allocator: std.mem.Allocator) void {
        self.responses.deinit(allocator);
    }

    pub fn setResponses(
        self: *FauxProvider,
        allocator: std.mem.Allocator,
        responses: []const types.AssistantMessage,
    ) !void {
        self.responses.clearRetainingCapacity();
        try self.responses.appendSlice(allocator, responses);
        self.next_response = 0;
    }

    pub fn appendResponses(
        self: *FauxProvider,
        allocator: std.mem.Allocator,
        responses: []const types.AssistantMessage,
    ) !void {
        try self.responses.appendSlice(allocator, responses);
    }

    pub fn pendingResponseCount(self: FauxProvider) usize {
        return self.responses.items.len - self.next_response;
    }

    pub fn complete(self: *FauxProvider) types.AssistantMessage {
        self.call_count += 1;
        if (self.next_response >= self.responses.items.len) {
            return .{
                .content = &.{},
                .api = .anthropic_messages,
                .provider = self.provider,
                .model = self.model,
                .stop_reason = .error_response,
                .error_message = "No more faux responses queued",
            };
        }

        var response = self.responses.items[self.next_response];
        self.next_response += 1;
        response.api = .anthropic_messages;
        response.provider = self.provider;
        response.model = self.model;
        return response;
    }
};

pub fn fauxText(text: []const u8) types.AssistantContent {
    return .{ .text = .{ .text = text } };
}

pub fn fauxThinking(thinking: []const u8) types.AssistantContent {
    return .{ .thinking = .{ .thinking = thinking } };
}

pub fn fauxToolCall(id: []const u8, name: []const u8, arguments_json: []const u8) types.AssistantContent {
    return .{
        .tool_call = .{
            .id = id,
            .name = name,
            .arguments_json = arguments_json,
        },
    };
}

pub fn fauxAssistantMessage(
    content: []const types.AssistantContent,
    stop_reason: types.StopReason,
) types.AssistantMessage {
    return .{
        .content = content,
        .api = .anthropic_messages,
        .provider = "faux",
        .model = "faux-model",
        .stop_reason = stop_reason,
    };
}

// Ported subset of packages/ai/test/faux-provider.test.ts.
test "faux provider supports helper blocks for text, thinking, and tool calls" {
    const content = [_]types.AssistantContent{
        fauxThinking("think"),
        fauxToolCall("call-1", "echo", "{\"text\":\"hi\"}"),
        fauxText("done"),
    };
    const message = fauxAssistantMessage(&content, .tool_use);

    try std.testing.expectEqualStrings("think", message.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("echo", message.content[1].tool_call.name);
    try std.testing.expectEqualStrings("done", message.content[2].text.text);
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
}

// Ported subset of packages/ai/test/faux-provider.test.ts.
test "faux provider consumes queued responses in order and errors when exhausted" {
    const allocator = std.testing.allocator;
    var provider: FauxProvider = .{
        .provider = "faux-provider",
        .model = "faux-model",
    };
    defer provider.deinit(allocator);

    const first_content = [_]types.AssistantContent{fauxText("first")};
    const second_content = [_]types.AssistantContent{fauxText("second")};
    const responses = [_]types.AssistantMessage{
        fauxAssistantMessage(&first_content, .stop),
        fauxAssistantMessage(&second_content, .stop),
    };
    try provider.setResponses(allocator, &responses);

    const first = provider.complete();
    const second = provider.complete();
    const exhausted = provider.complete();

    try std.testing.expectEqualStrings("first", first.content[0].text.text);
    try std.testing.expectEqualStrings("second", second.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_response, exhausted.stop_reason);
    try std.testing.expectEqualStrings("No more faux responses queued", exhausted.error_message.?);
    try std.testing.expectEqual(@as(usize, 0), provider.pendingResponseCount());
    try std.testing.expectEqual(@as(usize, 3), provider.call_count);
}

// Ported subset of packages/ai/test/faux-provider.test.ts.
test "faux provider can replace and append queued responses" {
    const allocator = std.testing.allocator;
    var provider: FauxProvider = .{};
    defer provider.deinit(allocator);

    const first_content = [_]types.AssistantContent{fauxText("first")};
    const second_content = [_]types.AssistantContent{fauxText("second")};
    const third_content = [_]types.AssistantContent{fauxText("third")};
    const first = [_]types.AssistantMessage{fauxAssistantMessage(&first_content, .stop)};
    const second = [_]types.AssistantMessage{fauxAssistantMessage(&second_content, .stop)};
    const third = [_]types.AssistantMessage{fauxAssistantMessage(&third_content, .stop)};

    try provider.setResponses(allocator, &first);
    try std.testing.expectEqualStrings("first", provider.complete().content[0].text.text);
    try provider.setResponses(allocator, &second);
    try provider.appendResponses(allocator, &third);

    try std.testing.expectEqual(@as(usize, 2), provider.pendingResponseCount());
    try std.testing.expectEqualStrings("second", provider.complete().content[0].text.text);
    try std.testing.expectEqualStrings("third", provider.complete().content[0].text.text);
}
