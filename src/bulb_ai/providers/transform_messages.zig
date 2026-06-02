const std = @import("std");
const diagnostics = @import("../utils/diagnostics.zig");
const types = @import("../types.zig");

const non_vision_user_image_placeholder = "(image omitted: model does not support images)";
const non_vision_tool_image_placeholder = "(tool image omitted: model does not support images)";

pub const NormalizeToolCallIdFn = *const fn (
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) anyerror![]u8;

pub const TransformedMessages = struct {
    allocator: std.mem.Allocator,
    messages: []types.Message,

    pub fn deinit(self: *TransformedMessages) void {
        for (self.messages) |*message| freeMessage(self.allocator, message);
        self.allocator.free(self.messages);
    }
};

const ToolCallRef = struct {
    id: []const u8,
    name: []const u8,
};

pub fn transformMessages(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    model: types.Model,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
) !TransformedMessages {
    var tool_call_id_map = std.StringHashMap([]u8).init(allocator);
    defer freeStringMap(allocator, &tool_call_id_map);

    const supports_images = modelSupportsInput(model, "image");
    var transformed: std.ArrayList(types.Message) = .empty;
    defer transformed.deinit(allocator);
    errdefer freeMessages(allocator, transformed.items);

    for (messages) |message| {
        const next = switch (message) {
            .user => |user| types.Message{
                .user = if (supports_images)
                    try cloneUserMessage(allocator, user)
                else
                    try cloneUserMessageWithImagePlaceholder(allocator, user, non_vision_user_image_placeholder),
            },
            .tool_result => |tool_result| types.Message{
                .tool_result = try cloneToolResultMessage(
                    allocator,
                    tool_result,
                    tool_call_id_map.get(tool_result.tool_call_id),
                    if (supports_images) null else non_vision_tool_image_placeholder,
                ),
            },
            .assistant => |assistant| types.Message{
                .assistant = try cloneAssistantMessageTransformed(
                    allocator,
                    assistant,
                    model,
                    normalize_tool_call_id,
                    &tool_call_id_map,
                ),
            },
        };
        try transformed.append(allocator, next);
    }

    var result: std.ArrayList(types.Message) = .empty;
    errdefer {
        freeMessages(allocator, result.items);
        result.deinit(allocator);
    }
    var pending_tool_calls: std.ArrayList(ToolCallRef) = .empty;
    defer pending_tool_calls.deinit(allocator);
    var existing_tool_result_ids = std.StringHashMap(void).init(allocator);
    defer existing_tool_result_ids.deinit();

    for (transformed.items) |message| {
        var moved = message;
        switch (moved) {
            .assistant => |assistant| {
                try insertSyntheticToolResults(
                    allocator,
                    &result,
                    &pending_tool_calls,
                    &existing_tool_result_ids,
                );

                if (assistant.stop_reason == .@"error" or assistant.stop_reason == .aborted) {
                    freeMessage(allocator, &moved);
                    continue;
                }

                try collectPendingToolCalls(allocator, &pending_tool_calls, assistant.content);
                try result.append(allocator, moved);
            },
            .tool_result => |tool_result| {
                try existing_tool_result_ids.put(tool_result.tool_call_id, {});
                try result.append(allocator, moved);
            },
            .user => {
                try insertSyntheticToolResults(
                    allocator,
                    &result,
                    &pending_tool_calls,
                    &existing_tool_result_ids,
                );
                try result.append(allocator, moved);
            },
        }
    }

    try insertSyntheticToolResults(allocator, &result, &pending_tool_calls, &existing_tool_result_ids);

    return .{
        .allocator = allocator,
        .messages = try result.toOwnedSlice(allocator),
    };
}

pub fn anthropicNormalizeToolCallId(
    allocator: std.mem.Allocator,
    id: []const u8,
    _model: types.Model,
    _source: types.AssistantMessage,
) ![]u8 {
    _ = _model;
    _ = _source;
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    for (id) |byte| {
        try normalized.append(allocator, if (isProviderToolIdByte(byte)) byte else '_');
        if (normalized.items.len == 64) break;
    }
    return normalized.toOwnedSlice(allocator);
}

pub fn openAICompatNormalizeToolCallId(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    _source: types.AssistantMessage,
) ![]u8 {
    _ = _source;
    if (std.mem.indexOfScalar(u8, id, '|')) |pipe| {
        return sanitizeAndTruncateToolId(allocator, id[0..pipe], 40);
    }
    if (std.mem.eql(u8, model.provider, "openai") and id.len > 40) {
        return allocator.dupe(u8, id[0..40]);
    }
    return allocator.dupe(u8, id);
}

fn sanitizeAndTruncateToolId(allocator: std.mem.Allocator, id: []const u8, max_len: usize) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    for (id) |byte| {
        try normalized.append(allocator, if (isProviderToolIdByte(byte)) byte else '_');
        if (normalized.items.len == max_len) break;
    }
    return normalized.toOwnedSlice(allocator);
}

fn isProviderToolIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn cloneAssistantMessageTransformed(
    allocator: std.mem.Allocator,
    source: types.AssistantMessage,
    model: types.Model,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
    tool_call_id_map: *std.StringHashMap([]u8),
) !types.AssistantMessage {
    const same_model = std.mem.eql(u8, source.provider, model.provider) and
        std.mem.eql(u8, source.api, model.api) and
        std.mem.eql(u8, source.model, model.id);

    var content: std.ArrayList(types.AssistantContent) = .empty;
    errdefer {
        for (content.items) |block| freeAssistantContent(allocator, block);
        content.deinit(allocator);
    }

    for (source.content) |block| {
        switch (block) {
            .thinking => |thinking| {
                if (thinking.redacted) {
                    if (same_model) try content.append(allocator, .{ .thinking = try cloneThinkingContent(allocator, thinking) });
                    continue;
                }

                if (same_model and thinking.thinking_signature != null) {
                    try content.append(allocator, .{ .thinking = try cloneThinkingContent(allocator, thinking) });
                    continue;
                }

                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                if (same_model) {
                    try content.append(allocator, .{ .thinking = try cloneThinkingContent(allocator, thinking) });
                } else {
                    try content.append(allocator, .{ .text = .{
                        .text = try allocator.dupe(u8, thinking.thinking),
                    } });
                }
            },
            .text => |text| {
                try content.append(allocator, .{ .text = if (same_model) try cloneTextContent(allocator, text) else .{
                    .text = try allocator.dupe(u8, text.text),
                } });
            },
            .tool_call => |tool_call| {
                const cloned = try cloneToolCallTransformed(
                    allocator,
                    tool_call,
                    same_model,
                    model,
                    source,
                    normalize_tool_call_id,
                );
                errdefer freeToolCall(allocator, cloned);

                if (!same_model and !std.mem.eql(u8, tool_call.id, cloned.id)) {
                    const original = try allocator.dupe(u8, tool_call.id);
                    errdefer allocator.free(original);
                    const normalized = try allocator.dupe(u8, cloned.id);
                    errdefer allocator.free(normalized);
                    try tool_call_id_map.put(original, normalized);
                }
                try content.append(allocator, .{ .tool_call = cloned });
            },
        }
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .api = source.api,
        .provider = source.provider,
        .model = source.model,
        .usage = source.usage,
        .stop_reason = source.stop_reason,
        .error_message = try cloneOptionalString(allocator, source.error_message),
        .response_id = try cloneOptionalString(allocator, source.response_id),
        .diagnostics = try cloneDiagnostics(allocator, source.diagnostics),
        .timestamp_ms = source.timestamp_ms,
    };
}

fn cloneToolCallTransformed(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    same_model: bool,
    model: types.Model,
    source: types.AssistantMessage,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
) !types.ToolCall {
    const normalized_id = if (!same_model and normalize_tool_call_id != null)
        try normalize_tool_call_id.?(allocator, tool_call.id, model, source)
    else
        try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(normalized_id);

    return .{
        .id = normalized_id,
        .name = try allocator.dupe(u8, tool_call.name),
        .arguments_json = try allocator.dupe(u8, tool_call.arguments_json),
        .thought_signature = if (same_model) try cloneOptionalString(allocator, tool_call.thought_signature) else null,
    };
}

fn cloneUserMessage(allocator: std.mem.Allocator, source: types.UserMessage) !types.UserMessage {
    return .{
        .content = try cloneUserContentSlice(allocator, source.content),
        .timestamp_ms = source.timestamp_ms,
    };
}

fn cloneUserMessageWithImagePlaceholder(
    allocator: std.mem.Allocator,
    source: types.UserMessage,
    placeholder: []const u8,
) !types.UserMessage {
    return .{
        .content = try replaceImagesWithPlaceholder(allocator, source.content, placeholder),
        .timestamp_ms = source.timestamp_ms,
    };
}

fn cloneToolResultMessage(
    allocator: std.mem.Allocator,
    source: types.ToolResultMessage,
    override_tool_call_id: ?[]const u8,
    image_placeholder: ?[]const u8,
) !types.ToolResultMessage {
    return .{
        .tool_call_id = try allocator.dupe(u8, override_tool_call_id orelse source.tool_call_id),
        .tool_name = try allocator.dupe(u8, source.tool_name),
        .content = if (image_placeholder) |placeholder|
            try replaceImagesWithPlaceholder(allocator, source.content, placeholder)
        else
            try cloneUserContentSlice(allocator, source.content),
        .is_error = source.is_error,
        .timestamp_ms = source.timestamp_ms,
    };
}

fn replaceImagesWithPlaceholder(
    allocator: std.mem.Allocator,
    content: []const types.UserContent,
    placeholder: []const u8,
) ![]types.UserContent {
    var result: std.ArrayList(types.UserContent) = .empty;
    errdefer {
        for (result.items) |block| freeUserContent(allocator, block);
        result.deinit(allocator);
    }

    var previous_was_placeholder = false;
    for (content) |block| {
        switch (block) {
            .image => {
                if (!previous_was_placeholder) {
                    try result.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, placeholder) } });
                }
                previous_was_placeholder = true;
            },
            .text => |text| {
                try result.append(allocator, .{ .text = try cloneTextContent(allocator, text) });
                previous_was_placeholder = std.mem.eql(u8, text.text, placeholder);
            },
        }
    }

    return result.toOwnedSlice(allocator);
}

fn collectPendingToolCalls(
    allocator: std.mem.Allocator,
    pending_tool_calls: *std.ArrayList(ToolCallRef),
    content: []const types.AssistantContent,
) !void {
    pending_tool_calls.clearRetainingCapacity();
    for (content) |block| {
        if (block == .tool_call) {
            try pending_tool_calls.append(allocator, .{
                .id = block.tool_call.id,
                .name = block.tool_call.name,
            });
        }
    }
}

fn insertSyntheticToolResults(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(types.Message),
    pending_tool_calls: *std.ArrayList(ToolCallRef),
    existing_tool_result_ids: *std.StringHashMap(void),
) !void {
    if (pending_tool_calls.items.len == 0) return;

    for (pending_tool_calls.items) |tool_call| {
        if (existing_tool_result_ids.get(tool_call.id) != null) continue;
        const content = try allocator.alloc(types.UserContent, 1);
        errdefer allocator.free(content);
        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "No result provided") } };
        errdefer freeUserContent(allocator, content[0]);

        try result.append(allocator, .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, tool_call.id),
            .tool_name = try allocator.dupe(u8, tool_call.name),
            .content = content,
            .is_error = true,
            .timestamp_ms = diagnostics.currentTimestampMs(),
        } });
    }

    pending_tool_calls.clearRetainingCapacity();
    existing_tool_result_ids.clearRetainingCapacity();
}

fn cloneUserContentSlice(allocator: std.mem.Allocator, content: []const types.UserContent) ![]types.UserContent {
    const cloned = try allocator.alloc(types.UserContent, content.len);
    errdefer allocator.free(cloned);
    var index: usize = 0;
    errdefer {
        for (cloned[0..index]) |block| freeUserContent(allocator, block);
    }
    for (content) |block| {
        cloned[index] = switch (block) {
            .text => |text| .{ .text = try cloneTextContent(allocator, text) },
            .image => |image| .{ .image = try cloneImageContent(allocator, image) },
        };
        index += 1;
    }
    return cloned;
}

fn cloneTextContent(allocator: std.mem.Allocator, source: types.TextContent) !types.TextContent {
    return .{
        .text = try allocator.dupe(u8, source.text),
        .text_signature = try cloneOptionalString(allocator, source.text_signature),
    };
}

fn cloneImageContent(allocator: std.mem.Allocator, source: types.ImageContent) !types.ImageContent {
    return .{
        .data = try allocator.dupe(u8, source.data),
        .mime_type = try allocator.dupe(u8, source.mime_type),
    };
}

fn cloneThinkingContent(allocator: std.mem.Allocator, source: types.ThinkingContent) !types.ThinkingContent {
    return .{
        .thinking = try allocator.dupe(u8, source.thinking),
        .thinking_signature = try cloneOptionalString(allocator, source.thinking_signature),
        .redacted = source.redacted,
    };
}

fn cloneDiagnostics(
    allocator: std.mem.Allocator,
    diagnostics_slice: []const types.AssistantMessageDiagnostic,
) ![]const types.AssistantMessageDiagnostic {
    if (diagnostics_slice.len == 0) return &.{};
    const cloned = try allocator.alloc(types.AssistantMessageDiagnostic, diagnostics_slice.len);
    errdefer allocator.free(cloned);
    var index: usize = 0;
    errdefer {
        for (cloned[0..index]) |diagnostic| freeDiagnostic(allocator, diagnostic);
    }
    for (diagnostics_slice) |diagnostic| {
        cloned[index] = try cloneDiagnostic(allocator, diagnostic);
        index += 1;
    }
    return cloned;
}

fn cloneDiagnostic(
    allocator: std.mem.Allocator,
    source: types.AssistantMessageDiagnostic,
) !types.AssistantMessageDiagnostic {
    return .{
        .type = try allocator.dupe(u8, source.type),
        .timestamp_ms = source.timestamp_ms,
        .@"error" = if (source.@"error") |err| try cloneDiagnosticError(allocator, err) else null,
        .details_json = try cloneOptionalString(allocator, source.details_json),
    };
}

fn cloneDiagnosticError(
    allocator: std.mem.Allocator,
    source: types.DiagnosticErrorInfo,
) !types.DiagnosticErrorInfo {
    return .{
        .name = try cloneOptionalString(allocator, source.name),
        .message = try allocator.dupe(u8, source.message),
        .stack = try cloneOptionalString(allocator, source.stack),
        .code = try cloneDiagnosticCode(allocator, source.code),
    };
}

fn cloneDiagnosticCode(
    allocator: std.mem.Allocator,
    source: ?types.DiagnosticCode,
) !?types.DiagnosticCode {
    const code = source orelse return null;
    return switch (code) {
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .number => |value| .{ .number = value },
    };
}

fn cloneOptionalString(allocator: std.mem.Allocator, source: ?[]const u8) !?[]const u8 {
    if (source) |value| return try allocator.dupe(u8, value);
    return null;
}

fn modelSupportsInput(model: types.Model, input: []const u8) bool {
    for (model.input) |candidate| {
        if (std.mem.eql(u8, candidate, input)) return true;
    }
    return false;
}

fn freeMessages(allocator: std.mem.Allocator, messages: []types.Message) void {
    for (messages) |*message| freeMessage(allocator, message);
}

fn freeMessage(allocator: std.mem.Allocator, message: *types.Message) void {
    switch (message.*) {
        .user => |user| {
            for (user.content) |block| freeUserContent(allocator, block);
            allocator.free(user.content);
        },
        .assistant => |assistant| {
            for (assistant.content) |block| freeAssistantContent(allocator, block);
            allocator.free(assistant.content);
            if (assistant.error_message) |value| allocator.free(value);
            if (assistant.response_id) |value| allocator.free(value);
            for (assistant.diagnostics) |diagnostic| freeDiagnostic(allocator, diagnostic);
            if (assistant.diagnostics.len > 0) allocator.free(assistant.diagnostics);
        },
        .tool_result => |tool_result| {
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            for (tool_result.content) |block| freeUserContent(allocator, block);
            allocator.free(tool_result.content);
        },
    }
}

fn freeUserContent(allocator: std.mem.Allocator, content: types.UserContent) void {
    switch (content) {
        .text => |text| freeTextContent(allocator, text),
        .image => |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        },
    }
}

fn freeAssistantContent(allocator: std.mem.Allocator, content: types.AssistantContent) void {
    switch (content) {
        .text => |text| freeTextContent(allocator, text),
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |value| allocator.free(value);
        },
        .tool_call => |tool_call| freeToolCall(allocator, tool_call),
    }
}

fn freeTextContent(allocator: std.mem.Allocator, text: types.TextContent) void {
    allocator.free(text.text);
    if (text.text_signature) |value| allocator.free(value);
}

fn freeToolCall(allocator: std.mem.Allocator, tool_call: types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    allocator.free(tool_call.arguments_json);
    if (tool_call.thought_signature) |value| allocator.free(value);
}

fn freeDiagnostic(allocator: std.mem.Allocator, diagnostic: types.AssistantMessageDiagnostic) void {
    allocator.free(diagnostic.type);
    if (diagnostic.details_json) |value| allocator.free(value);
    if (diagnostic.@"error") |err| {
        if (err.name) |value| allocator.free(value);
        allocator.free(err.message);
        if (err.stack) |value| allocator.free(value);
        if (err.code) |code| switch (code) {
            .string => |value| allocator.free(value),
            .number => {},
        };
    }
}

fn freeStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn makeCopilotClaudeModel(input: []const []const u8) types.Model {
    return .{
        .id = "claude-sonnet-4.6",
        .name = "Claude Sonnet 4.6",
        .api = types.api.anthropic_messages,
        .provider = "github-copilot",
        .base_url = "https://api.individual.githubcopilot.com",
        .reasoning = true,
        .input = input,
        .context_window = 128_000,
        .max_tokens = 16_000,
    };
}

fn makeAssistant(content: []const types.AssistantContent) types.Message {
    return .{ .assistant = .{
        .content = content,
        .api = types.api.openai_responses,
        .provider = "github-copilot",
        .model = "gpt-5",
        .stop_reason = .tool_use,
    } };
}

// Ported from packages/ai/test/transform-messages-copilot-openai-to-anthropic.test.ts.
test "transform messages converts thinking blocks to text when source model differs" {
    const allocator = std.testing.allocator;
    const model = makeCopilotClaudeModel(&.{ "text", "image" });
    const assistant_content = [_]types.AssistantContent{
        .{ .thinking = .{
            .thinking = "Let me think about this...",
            .thinking_signature = "reasoning_content",
        } },
        .{ .text = .{ .text = "Hi there!" } },
    };
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
    const messages = [_]types.Message{
        .{ .user = .{ .content = &user_content } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = types.api.openai_completions,
            .provider = "github-copilot",
            .model = "gpt-4o",
        } },
    };

    var transformed = try transformMessages(allocator, &messages, model, anthropicNormalizeToolCallId);
    defer transformed.deinit();

    const assistant = transformed.messages[1].assistant;
    try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
    try std.testing.expect(assistant.content[0] == .text);
    try std.testing.expectEqualStrings("Let me think about this...", assistant.content[0].text.text);
    try std.testing.expect(assistant.content[1] == .text);
}

// Ported from packages/ai/test/transform-messages-copilot-openai-to-anthropic.test.ts.
test "transform messages removes thoughtSignature from tool calls when migrating between models" {
    const allocator = std.testing.allocator;
    const model = makeCopilotClaudeModel(&.{ "text", "image" });
    const assistant_content = [_]types.AssistantContent{.{ .tool_call = .{
        .id = "call_123",
        .name = "bash",
        .arguments_json = "{\"command\":\"ls\"}",
        .thought_signature = "{\"type\":\"reasoning.encrypted\"}",
    } }};
    const result_content = [_]types.UserContent{.{ .text = .{ .text = "output" } }};
    const messages = [_]types.Message{
        makeAssistant(&assistant_content),
        .{ .tool_result = .{
            .tool_call_id = "call_123",
            .tool_name = "bash",
            .content = &result_content,
        } },
    };

    var transformed = try transformMessages(allocator, &messages, model, anthropicNormalizeToolCallId);
    defer transformed.deinit();

    const tool_call = transformed.messages[0].assistant.content[0].tool_call;
    try std.testing.expectEqual(@as(?[]const u8, null), tool_call.thought_signature);
}

// Ported from packages/ai/test/transform-messages-copilot-openai-to-anthropic.test.ts.
test "transform messages adds synthetic results for trailing orphaned normalized tool calls" {
    const allocator = std.testing.allocator;
    const model = makeCopilotClaudeModel(&.{ "text", "image" });
    const assistant_content = [_]types.AssistantContent{.{ .tool_call = .{
        .id = "call_123|fc_123",
        .name = "read",
        .arguments_json = "{\"path\":\"README.md\"}",
    } }};
    const messages = [_]types.Message{makeAssistant(&assistant_content)};

    var transformed = try transformMessages(allocator, &messages, model, anthropicNormalizeToolCallId);
    defer transformed.deinit();

    try std.testing.expectEqual(@as(usize, 2), transformed.messages.len);
    const synthetic = transformed.messages[1].tool_result;
    try std.testing.expectEqualStrings("call_123_fc_123", synthetic.tool_call_id);
    try std.testing.expectEqualStrings("read", synthetic.tool_name);
    try std.testing.expect(synthetic.is_error);
    try std.testing.expectEqualStrings("No result provided", synthetic.content[0].text.text);
}

// Ported from packages/ai/test/transform-messages-copilot-openai-to-anthropic.test.ts.
test "transform messages adds synthetic results only for still-missing tool results" {
    const allocator = std.testing.allocator;
    const model = makeCopilotClaudeModel(&.{ "text", "image" });
    const assistant_content = [_]types.AssistantContent{
        .{ .tool_call = .{
            .id = "call_1|fc_1",
            .name = "read",
            .arguments_json = "{\"path\":\"README.md\"}",
        } },
        .{ .tool_call = .{
            .id = "call_2|fc_2",
            .name = "bash",
            .arguments_json = "{\"command\":\"pwd\"}",
        } },
    };
    const result_content = [_]types.UserContent{.{ .text = .{ .text = "done" } }};
    const messages = [_]types.Message{
        makeAssistant(&assistant_content),
        .{ .tool_result = .{
            .tool_call_id = "call_1|fc_1",
            .tool_name = "read",
            .content = &result_content,
        } },
    };

    var transformed = try transformMessages(allocator, &messages, model, anthropicNormalizeToolCallId);
    defer transformed.deinit();

    var synthetic_count: usize = 0;
    var synthetic_id: []const u8 = "";
    for (transformed.messages) |message| {
        if (message == .tool_result and message.tool_result.is_error) {
            synthetic_count += 1;
            synthetic_id = message.tool_result.tool_call_id;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), synthetic_count);
    try std.testing.expectEqualStrings("call_2_fc_2", synthetic_id);
}

test "transform messages downgrades unsupported images with collapsed placeholders" {
    const allocator = std.testing.allocator;
    const text_only_model = makeCopilotClaudeModel(&.{"text"});
    const content = [_]types.UserContent{
        .{ .text = .{ .text = "before" } },
        .{ .image = .{ .data = "one", .mime_type = "image/png" } },
        .{ .image = .{ .data = "two", .mime_type = "image/png" } },
        .{ .text = .{ .text = "after" } },
    };
    const messages = [_]types.Message{.{ .user = .{ .content = &content } }};

    var transformed = try transformMessages(allocator, &messages, text_only_model, null);
    defer transformed.deinit();

    const user = transformed.messages[0].user;
    try std.testing.expectEqual(@as(usize, 3), user.content.len);
    try std.testing.expectEqualStrings("before", user.content[0].text.text);
    try std.testing.expectEqualStrings(non_vision_user_image_placeholder, user.content[1].text.text);
    try std.testing.expectEqualStrings("after", user.content[2].text.text);
}

// Ported local invariant from packages/ai/test/tool-call-id-normalization.test.ts.
test "transform messages normalizes exact long OpenAI Responses tool IDs for OpenAI-compatible replay" {
    const allocator = std.testing.allocator;
    const failing_tool_call_id =
        "call_pAYbIr76hXIjncD9UE4eGfnS|t5nnb2qYMFWGSsr13fhCd1CaCu3t3qONEPuOudu4HSVEtA8YJSL6FAZUxvoOoD792VIJWl91g87EdqsCWp9krVsdBysQoDaf9lMCLb8BS4EYi4gQd5kBQBYLlgD71PYwvf+TbMD9J9/5OMD42oxSRj8H+vRf78/l2Xla33LWz4nOgsddBlbvabICRs8GHt5C9PK5keFtzyi3lsyVKNlfduK3iphsZqs4MLv4zyGJnvZo/+QzShyk5xnMSQX/f98+aEoNflEApCdEOXipipgeiNWnpFSHbcwmMkZoJhURNu+JEz3xCh1mrXeYoN5o+trLL3IXJacSsLYXDrYTipZZbJFRPAucgbnjYBC+/ZzJOfkwCs+Gkw7EoZR7ZQgJ8ma+9586n4tT4cI8DEhBSZsWMjrCt8dxKg==";
    const model: types.Model = .{
        .id = "openai/gpt-5.2-codex",
        .name = "GPT-5.2 Codex",
        .api = types.api.openai_completions,
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
    };
    const assistant_content = [_]types.AssistantContent{.{ .tool_call = .{
        .id = failing_tool_call_id,
        .name = "echo",
        .arguments_json = "{\"message\":\"hello\"}",
    } }};
    const result_content = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
    const messages = [_]types.Message{
        .{ .assistant = .{
            .content = &assistant_content,
            .api = types.api.openai_responses,
            .provider = "github-copilot",
            .model = "gpt-5.2-codex",
        } },
        .{ .tool_result = .{
            .tool_call_id = failing_tool_call_id,
            .tool_name = "echo",
            .content = &result_content,
        } },
    };

    var transformed = try transformMessages(allocator, &messages, model, openAICompatNormalizeToolCallId);
    defer transformed.deinit();

    const expected = "call_pAYbIr76hXIjncD9UE4eGfnS";
    try std.testing.expectEqualStrings(expected, transformed.messages[0].assistant.content[0].tool_call.id);
    try std.testing.expectEqualStrings(expected, transformed.messages[1].tool_result.tool_call_id);
}
