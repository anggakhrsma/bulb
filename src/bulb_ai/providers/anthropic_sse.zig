const std = @import("std");
const json_parse = @import("../utils/json_parse.zig");
const diagnostics = @import("../utils/diagnostics.zig");
const models = @import("../models.zig");
const sse = @import("../utils/sse.zig");
const types = @import("../types.zig");

pub const ParseError = error{
    AnthropicStreamEndedBeforeMessageStop,
    InvalidAnthropicSseJson,
    MissingAnthropicContentBlock,
    OutOfMemory,
    WriteFailed,
};

pub const ParsedAssistantMessage = struct {
    allocator: std.mem.Allocator,
    message: types.AssistantMessage,

    pub fn deinit(self: *ParsedAssistantMessage) void {
        if (self.message.response_id) |response_id| self.allocator.free(response_id);
        if (self.message.error_message) |error_message| self.allocator.free(error_message);
        for (self.message.content) |block| {
            switch (block) {
                .text => |text| self.allocator.free(text.text),
                .thinking => |thinking| self.allocator.free(thinking.thinking),
                .tool_call => |tool_call| {
                    self.allocator.free(tool_call.id);
                    self.allocator.free(tool_call.name);
                    self.allocator.free(tool_call.arguments_json);
                },
            }
        }
        self.allocator.free(self.message.content);
    }
};

const BlockKind = enum {
    text,
    thinking,
    tool_call,
};

const BlockState = struct {
    index: usize,
    kind: BlockKind,
    text: std.ArrayList(u8) = .empty,
    id: []u8 = &.{},
    name: []u8 = &.{},
    initial_input_json: ?[]u8 = null,
    partial_json: std.ArrayList(u8) = .empty,

    fn deinit(self: *BlockState, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.partial_json.deinit(allocator);
        if (self.id.len > 0) allocator.free(self.id);
        if (self.name.len > 0) allocator.free(self.name);
        if (self.initial_input_json) |json| allocator.free(json);
    }
};

const anthropic_message_events = [_][]const u8{
    "message_start",
    "message_delta",
    "message_stop",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
};

pub fn parseAssistantMessageFromSse(
    allocator: std.mem.Allocator,
    model: types.Model,
    body: []const u8,
) ParseError!ParsedAssistantMessage {
    var decoded = try sse.decodeAll(allocator, body);
    defer decoded.deinit();

    var output: types.AssistantMessage = .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .timestamp_ms = diagnostics.currentTimestampMs(),
    };
    errdefer {
        if (output.response_id) |response_id| allocator.free(response_id);
    }

    var blocks: std.ArrayList(BlockState) = .empty;
    defer {
        for (blocks.items) |*block| block.deinit(allocator);
        blocks.deinit(allocator);
    }

    var saw_message_start = false;
    var saw_message_stop = false;

    for (decoded.events) |event| {
        const event_name = event.event orelse "";
        if (std.mem.eql(u8, event_name, "error")) return error.InvalidAnthropicSseJson;
        if (!isAnthropicMessageEvent(event_name)) continue;

        var parsed = json_parse.parseJsonWithRepair(allocator, event.data) catch return error.InvalidAnthropicSseJson;
        defer parsed.deinit();

        const event_type = getString(&parsed.value, "type") orelse event_name;
        if (std.mem.eql(u8, event_type, "message_start")) {
            saw_message_start = true;
            if (getObjectField(&parsed.value, "message")) |message| {
                if (getString(message, "id")) |response_id| {
                    if (output.response_id) |old| allocator.free(old);
                    output.response_id = try allocator.dupe(u8, response_id);
                }
                if (getObjectField(message, "usage")) |usage| {
                    updateUsage(&output.usage, usage);
                    _ = models.calculateCost(model, &output.usage);
                }
            }
        } else if (std.mem.eql(u8, event_type, "content_block_start")) {
            try startContentBlock(allocator, &blocks, &parsed.value);
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            try applyContentBlockDelta(allocator, &blocks, &parsed.value);
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            if (getObjectField(&parsed.value, "delta")) |delta| {
                if (getString(delta, "stop_reason")) |reason| output.stop_reason = mapStopReason(reason);
            }
            if (getObjectField(&parsed.value, "usage")) |usage| {
                updateUsage(&output.usage, usage);
                _ = models.calculateCost(model, &output.usage);
            }
        } else if (std.mem.eql(u8, event_type, "message_stop")) {
            saw_message_stop = true;
        }
    }

    if (saw_message_start and !saw_message_stop) return error.AnthropicStreamEndedBeforeMessageStop;

    output.content = try finalizeContent(allocator, blocks.items);
    errdefer freeContent(allocator, output.content);

    return .{
        .allocator = allocator,
        .message = output,
    };
}

fn startContentBlock(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(BlockState),
    value: *const std.json.Value,
) !void {
    const index = try requiredIndex(value);
    const content_block = getObjectField(value, "content_block") orelse return error.MissingAnthropicContentBlock;
    const block_type = getString(content_block, "type") orelse return error.MissingAnthropicContentBlock;

    if (std.mem.eql(u8, block_type, "text")) {
        var block: BlockState = .{ .index = index, .kind = .text };
        if (getString(content_block, "text")) |text| try block.text.appendSlice(allocator, text);
        try blocks.append(allocator, block);
    } else if (std.mem.eql(u8, block_type, "thinking")) {
        var block: BlockState = .{ .index = index, .kind = .thinking };
        if (getString(content_block, "thinking")) |thinking| try block.text.appendSlice(allocator, thinking);
        try blocks.append(allocator, block);
    } else if (std.mem.eql(u8, block_type, "redacted_thinking")) {
        var block: BlockState = .{ .index = index, .kind = .thinking };
        try block.text.appendSlice(allocator, "[Reasoning redacted]");
        try blocks.append(allocator, block);
    } else if (std.mem.eql(u8, block_type, "tool_use")) {
        var block: BlockState = .{
            .index = index,
            .kind = .tool_call,
            .id = try allocator.dupe(u8, getString(content_block, "id") orelse ""),
            .name = try allocator.dupe(u8, getString(content_block, "name") orelse ""),
        };
        errdefer block.deinit(allocator);

        if (getObjectField(content_block, "input")) |input| {
            block.initial_input_json = try stringifyJsonAlloc(allocator, input.*);
        } else {
            block.initial_input_json = try allocator.dupe(u8, "{}");
        }
        try blocks.append(allocator, block);
    }
}

fn applyContentBlockDelta(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(BlockState),
    value: *const std.json.Value,
) !void {
    const index = try requiredIndex(value);
    const delta = getObjectField(value, "delta") orelse return;
    const delta_type = getString(delta, "type") orelse return;
    const block = findBlock(blocks.items, index) orelse return;

    if (std.mem.eql(u8, delta_type, "text_delta")) {
        if (block.kind == .text) try block.text.appendSlice(allocator, getString(delta, "text") orelse "");
    } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
        if (block.kind == .thinking) try block.text.appendSlice(allocator, getString(delta, "thinking") orelse "");
    } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
        if (block.kind == .tool_call) {
            try block.partial_json.appendSlice(allocator, getString(delta, "partial_json") orelse "");
        }
    }
}

fn finalizeContent(allocator: std.mem.Allocator, blocks: []BlockState) ParseError![]types.AssistantContent {
    const content = try allocator.alloc(types.AssistantContent, blocks.len);
    errdefer allocator.free(content);

    for (blocks, 0..) |block, index| {
        switch (block.kind) {
            .text => {
                content[index] = .{ .text = .{ .text = try allocator.dupe(u8, block.text.items) } };
            },
            .thinking => {
                content[index] = .{ .thinking = .{ .thinking = try allocator.dupe(u8, block.text.items) } };
            },
            .tool_call => {
                const arguments_json = try finalizeToolArguments(allocator, block);
                content[index] = .{
                    .tool_call = .{
                        .id = try allocator.dupe(u8, block.id),
                        .name = try allocator.dupe(u8, block.name),
                        .arguments_json = arguments_json,
                    },
                };
            },
        }
    }
    return content;
}

fn finalizeToolArguments(allocator: std.mem.Allocator, block: BlockState) ParseError![]u8 {
    if (block.partial_json.items.len == 0) {
        return allocator.dupe(u8, block.initial_input_json orelse "{}");
    }

    var parsed = json_parse.parseStreamingJson(allocator, block.partial_json.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAnthropicSseJson,
    };
    defer parsed.deinit();
    return stringifyJsonAlloc(allocator, parsed.value);
}

fn freeContent(allocator: std.mem.Allocator, content: []const types.AssistantContent) void {
    for (content) |block| {
        switch (block) {
            .text => |text| allocator.free(text.text),
            .thinking => |thinking| allocator.free(thinking.thinking),
            .tool_call => |tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.name);
                allocator.free(tool_call.arguments_json);
            },
        }
    }
    allocator.free(content);
}

fn findBlock(blocks: []BlockState, index: usize) ?*BlockState {
    for (blocks) |*block| {
        if (block.index == index) return block;
    }
    return null;
}

fn isAnthropicMessageEvent(event_name: []const u8) bool {
    for (anthropic_message_events) |known| {
        if (std.mem.eql(u8, known, event_name)) return true;
    }
    return false;
}

fn mapStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, reason, "error")) return .@"error";
    return .stop;
}

fn updateUsage(usage: *types.Usage, value: *const std.json.Value) void {
    if (getUnsigned(value, "input_tokens")) |tokens| usage.input = tokens;
    if (getUnsigned(value, "output_tokens")) |tokens| usage.output = tokens;
    if (getUnsigned(value, "cache_read_input_tokens")) |tokens| usage.cache_read = tokens;
    if (getUnsigned(value, "cache_creation_input_tokens")) |tokens| usage.cache_write = tokens;
    usage.calculateTotalTokens();
}

fn getObjectField(value: *const std.json.Value, field: []const u8) ?*const std.json.Value {
    return switch (value.*) {
        .object => |object| object.getPtr(field),
        else => null,
    };
}

fn getString(value: *const std.json.Value, field: []const u8) ?[]const u8 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value.*) {
        .string => |string| string,
        else => null,
    };
}

fn getUnsigned(value: *const std.json.Value, field: []const u8) ?u64 {
    const field_value = getObjectField(value, field) orelse return null;
    return switch (field_value.*) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0) @intFromFloat(float) else null,
        else => null,
    };
}

fn requiredIndex(value: *const std.json.Value) !usize {
    const field_value = getObjectField(value, "index") orelse return error.MissingAnthropicContentBlock;
    return switch (field_value.*) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.MissingAnthropicContentBlock,
        else => error.MissingAnthropicContentBlock,
    };
}

fn stringifyJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stream: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };
    stream.write(value) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
    };
    return out.toOwnedSlice() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "Anthropic SSE parser repairs malformed SSE JSON and streamed tool JSON" {
    const allocator = std.testing.allocator;
    const model = models.getModel("anthropic", "claude-haiku-4-5").?.*;
    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"usage\":{\"input_tokens\":12,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_test\",\"name\":\"edit\",\"input\":{}}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"A\\H\\\",\\\"text\\\":\\\"col1\tcol2\\\"}\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":5,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n";

    var parsed = try parseAssistantMessageFromSse(allocator, model, body);
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.tool_use, parsed.message.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), parsed.message.content.len);
    const tool_call = parsed.message.content[0].tool_call;
    try std.testing.expectEqualStrings("toolu_test", tool_call.id);
    try std.testing.expectEqualStrings("edit", tool_call.name);

    var args = try json_parse.parseJsonWithRepair(allocator, tool_call.arguments_json);
    defer args.deinit();
    try std.testing.expectEqualStrings("A\\H", args.value.object.get("path").?.string);
    try std.testing.expectEqualStrings("col1\tcol2", args.value.object.get("text").?.string);
}

test "Anthropic SSE parser ignores unknown events after message_stop" {
    const allocator = std.testing.allocator;
    const model = models.getModel("anthropic", "claude-haiku-4-5").?.*;
    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"usage\":{\"input_tokens\":12,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n" ++
        "\n" ++
        "event: content_block_start\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n" ++
        "\n" ++
        "event: content_block_stop\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "\n" ++
        "event: message_delta\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":5,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}\n" ++
        "\n" ++
        "event: message_stop\n" ++
        "data: {\"type\":\"message_stop\"}\n" ++
        "\n" ++
        "event: done\n" ++
        "data: [DONE]\n" ++
        "\n" ++
        "event: proxy.stats\n" ++
        "data: not json\n";

    var parsed = try parseAssistantMessageFromSse(allocator, model, body);
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.stop, parsed.message.stop_reason);
    try std.testing.expect(parsed.message.error_message == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.message.content.len);
    try std.testing.expectEqualStrings("Hello", parsed.message.content[0].text.text);
}

test "Anthropic SSE parser rejects streams that end before message_stop" {
    const allocator = std.testing.allocator;
    const model = models.getModel("anthropic", "claude-haiku-4-5").?.*;
    const body =
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n";

    try std.testing.expectError(
        error.AnthropicStreamEndedBeforeMessageStop,
        parseAssistantMessageFromSse(allocator, model, body),
    );
}
