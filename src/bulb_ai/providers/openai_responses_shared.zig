const std = @import("std");
const hash = @import("../utils/hash.zig");
const json_parse = @import("../utils/json_parse.zig");
const models = @import("../models.zig");
const sanitize_unicode = @import("../utils/sanitize_unicode.zig");
const transform_messages = @import("transform_messages.zig");
const types = @import("../types.zig");

pub const ConvertResponsesMessagesOptions = struct {
    include_system_prompt: bool = true,
};

pub const ResponsesStrictMode = union(enum) {
    default_false,
    null,
    bool: bool,
};

pub const ConvertResponsesToolsOptions = struct {
    strict: ResponsesStrictMode = .default_false,
};

const ParsedTextSignature = struct {
    id: []const u8,
    phase: ?[]const u8 = null,
};

pub fn convertResponsesMessagesValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ConvertResponsesMessagesOptions,
) !std.json.Value {
    var transformed = try transform_messages.transformMessages(
        allocator,
        context.messages,
        model,
        responsesNormalizeToolCallId,
    );
    defer transformed.deinit();

    var result = std.json.Array.init(allocator);
    errdefer result.deinit();

    if (options.include_system_prompt) {
        if (context.system_prompt) |prompt| {
            var message = objectValue();
            const role = if (model.reasoning) "developer" else "system";
            try putString(allocator, &message, "role", role);
            try putSanitizedString(allocator, &message, "content", prompt);
            try result.append(message);
        }
    }

    var msg_index: usize = 0;
    for (transformed.messages) |message| {
        switch (message) {
            .user => |user| {
                if (try convertResponsesUserMessage(allocator, user)) |converted| {
                    try result.append(converted);
                } else continue;
            },
            .assistant => |assistant| {
                var converted = try convertResponsesAssistantMessage(allocator, model, assistant, msg_index);
                defer converted.deinit(allocator);
                if (converted.items.len == 0) continue;
                for (converted.items) |item| try result.append(item);
            },
            .tool_result => |tool_result| try result.append(try convertResponsesToolResultMessage(
                allocator,
                model,
                tool_result,
            )),
        }
        msg_index += 1;
    }

    return .{ .array = result };
}

pub fn convertResponsesToolsValue(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    options: ConvertResponsesToolsOptions,
) !std.json.Value {
    var result = std.json.Array.init(allocator);
    errdefer result.deinit();

    for (tools) |tool| {
        var value = objectValue();
        try putString(allocator, &value, "type", "function");
        try putString(allocator, &value, "name", tool.name);
        try putString(allocator, &value, "description", tool.description);
        try putValue(allocator, &value, "parameters", try parseOrString(allocator, tool.parameters_json));
        switch (options.strict) {
            .default_false => try putBool(allocator, &value, "strict", false),
            .null => try putNull(allocator, &value, "strict"),
            .bool => |strict| try putBool(allocator, &value, "strict", strict),
        }
        try result.append(value);
    }

    return .{ .array = result };
}

pub fn responsesNormalizeToolCallId(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]u8 {
    if (!isResponsesToolCallProvider(model.provider)) return normalizeIdPart(allocator, id);

    const pipe = std.mem.indexOfScalar(u8, id, '|') orelse return normalizeIdPart(allocator, id);
    const call_id = id[0..pipe];
    const rest = id[pipe + 1 ..];
    const next_pipe = std.mem.indexOfScalar(u8, rest, '|');
    const item_id = if (next_pipe) |index| rest[0..index] else rest;

    const normalized_call_id = try normalizeIdPart(allocator, call_id);
    errdefer allocator.free(normalized_call_id);

    const is_foreign_tool_call = !eql(source.provider, model.provider) or !eql(source.api, model.api);
    var normalized_item_id = if (is_foreign_tool_call)
        try buildForeignResponsesItemId(allocator, item_id)
    else
        try normalizeIdPart(allocator, item_id);
    errdefer allocator.free(normalized_item_id);

    if (!std.mem.startsWith(u8, normalized_item_id, "fc_")) {
        const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{normalized_item_id});
        allocator.free(normalized_item_id);
        normalized_item_id = try normalizeIdPart(allocator, prefixed);
        allocator.free(prefixed);
    }

    return std.fmt.allocPrint(allocator, "{s}|{s}", .{ normalized_call_id, normalized_item_id });
}

pub fn processResponsesEvents(
    allocator: std.mem.Allocator,
    model: types.Model,
    events_json: []const []const u8,
) !ParsedResponsesStream {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parser = ResponsesStreamParser.init(a, allocator, model);
    errdefer parser.events.deinit(allocator);
    try parser.emit(.{ .start = {} });

    for (events_json) |event_json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, event_json, .{});
        defer parsed.deinit();
        try parser.processEvent(parsed.value);
    }

    try parser.finish();
    return .{
        .arena = arena,
        .result = .{
            .allocator = allocator,
            .events = parser.events,
            .message = parser.output,
        },
    };
}

pub const ParsedResponsesStream = struct {
    arena: std.heap.ArenaAllocator,
    result: types.StreamResult,

    pub fn deinit(self: *ParsedResponsesStream) void {
        self.result.deinit();
        self.arena.deinit();
    }
};

const ResponsesStreamParser = struct {
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
    model: types.Model,
    events: std.ArrayList(types.StreamEvent) = .empty,
    output: types.AssistantMessage,
    blocks: std.ArrayList(ResponsesStreamingBlock) = .empty,
    current_index: ?usize = null,
    current_item_type: ResponsesItemType = .none,
    has_completion: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        event_allocator: std.mem.Allocator,
        model: types.Model,
    ) ResponsesStreamParser {
        return .{
            .allocator = allocator,
            .event_allocator = event_allocator,
            .model = model,
            .output = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = .{},
                .stop_reason = .stop,
            },
        };
    }

    fn processEvent(self: *ResponsesStreamParser, event: std.json.Value) !void {
        if (event != .object) return;
        const event_type = getStringField(event, "type") orelse return;

        if (eql(event_type, "response.created")) {
            if (event.object.get("response")) |response| {
                if (getStringField(response, "id")) |id| self.output.response_id = try self.allocator.dupe(u8, id);
            }
        } else if (eql(event_type, "response.output_item.added")) {
            if (event.object.get("item")) |item| try self.addOutputItem(item);
        } else if (eql(event_type, "response.reasoning_summary_text.delta") or eql(event_type, "response.reasoning_text.delta")) {
            if (getStringField(event, "delta")) |delta| try self.appendThinkingDelta(delta);
        } else if (eql(event_type, "response.reasoning_summary_part.done")) {
            try self.appendThinkingDelta("\n\n");
        } else if (eql(event_type, "response.output_text.delta") or eql(event_type, "response.refusal.delta")) {
            if (getStringField(event, "delta")) |delta| try self.appendTextDelta(delta);
        } else if (eql(event_type, "response.function_call_arguments.delta")) {
            if (getStringField(event, "delta")) |delta| try self.appendToolCallDelta(delta);
        } else if (eql(event_type, "response.function_call_arguments.done")) {
            if (getStringField(event, "arguments")) |arguments| try self.finishToolCallArguments(arguments);
        } else if (eql(event_type, "response.output_item.done")) {
            if (event.object.get("item")) |item| try self.doneOutputItem(item);
        } else if (eql(event_type, "response.completed")) {
            self.has_completion = true;
            if (event.object.get("response")) |response| try self.completeResponse(response);
        } else if (eql(event_type, "response.failed")) {
            self.output.stop_reason = .@"error";
            self.output.error_message = try self.allocator.dupe(u8, "OpenAI Responses stream failed");
        } else if (eql(event_type, "error")) {
            self.output.stop_reason = .@"error";
            self.output.error_message = try self.allocator.dupe(u8, getStringField(event, "message") orelse "OpenAI Responses stream error");
        }
    }

    fn addOutputItem(self: *ResponsesStreamParser, item: std.json.Value) !void {
        if (item != .object) return;
        const item_type = getStringField(item, "type") orelse return;
        const index = self.blocks.items.len;
        self.current_index = index;

        if (eql(item_type, "reasoning")) {
            self.current_item_type = .reasoning;
            try self.blocks.append(self.allocator, .{ .thinking = .{} });
            try self.emit(.{ .thinking_start = .{ .content_index = index } });
        } else if (eql(item_type, "message")) {
            self.current_item_type = .message;
            try self.blocks.append(self.allocator, .{ .text = .{} });
            try self.emit(.{ .text_start = .{ .content_index = index } });
        } else if (eql(item_type, "function_call")) {
            self.current_item_type = .function_call;
            const call_id = getStringField(item, "call_id") orelse "";
            const item_id = getStringField(item, "id") orelse "";
            const name = getStringField(item, "name") orelse "";
            const initial_arguments = getStringField(item, "arguments") orelse "";
            var partial_json = std.ArrayList(u8).empty;
            errdefer partial_json.deinit(self.allocator);
            try partial_json.appendSlice(self.allocator, initial_arguments);
            try self.blocks.append(self.allocator, .{ .tool_call = .{
                .id = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ call_id, item_id }),
                .name = try self.allocator.dupe(u8, name),
                .partial_json = partial_json,
            } });
            try self.emit(.{ .toolcall_start = .{ .content_index = index } });
        }
    }

    fn appendThinkingDelta(self: *ResponsesStreamParser, delta: []const u8) !void {
        const index = self.current_index orelse return;
        if (self.current_item_type != .reasoning or self.blocks.items[index] != .thinking) return;
        try self.blocks.items[index].thinking.text.appendSlice(self.allocator, delta);
        try self.emit(.{ .thinking_delta = .{
            .content_index = index,
            .delta = try self.allocator.dupe(u8, delta),
        } });
    }

    fn appendTextDelta(self: *ResponsesStreamParser, delta: []const u8) !void {
        const index = self.current_index orelse return;
        if (self.current_item_type != .message or self.blocks.items[index] != .text) return;
        try self.blocks.items[index].text.text.appendSlice(self.allocator, delta);
        try self.emit(.{ .text_delta = .{
            .content_index = index,
            .delta = try self.allocator.dupe(u8, delta),
        } });
    }

    fn appendToolCallDelta(self: *ResponsesStreamParser, delta: []const u8) !void {
        const index = self.current_index orelse return;
        if (self.current_item_type != .function_call or self.blocks.items[index] != .tool_call) return;
        try self.blocks.items[index].tool_call.partial_json.appendSlice(self.allocator, delta);
        try self.emit(.{ .toolcall_delta = .{
            .content_index = index,
            .delta = try self.allocator.dupe(u8, delta),
        } });
    }

    fn finishToolCallArguments(self: *ResponsesStreamParser, arguments_json: []const u8) !void {
        const index = self.current_index orelse return;
        if (self.current_item_type != .function_call or self.blocks.items[index] != .tool_call) return;

        const block = &self.blocks.items[index].tool_call;
        const previous = block.partial_json.items;
        if (std.mem.startsWith(u8, arguments_json, previous) and arguments_json.len > previous.len) {
            const delta = arguments_json[previous.len..];
            try self.emit(.{ .toolcall_delta = .{
                .content_index = index,
                .delta = try self.allocator.dupe(u8, delta),
            } });
        }
        block.partial_json.clearRetainingCapacity();
        try block.partial_json.appendSlice(self.allocator, arguments_json);
    }

    fn doneOutputItem(self: *ResponsesStreamParser, item: std.json.Value) !void {
        if (item != .object) return;
        const item_type = getStringField(item, "type") orelse return;
        const index = self.current_index orelse return;
        if (eql(item_type, "reasoning") and self.blocks.items[index] == .thinking) {
            const final_text = try self.blocks.items[index].thinking.text.toOwnedSlice(self.allocator);
            self.blocks.items[index].thinking.final_text = final_text;
            self.blocks.items[index].thinking.signature = try std.json.Stringify.valueAlloc(self.allocator, item, .{});
            try self.emit(.{ .thinking_end = .{ .content_index = index, .content = final_text } });
            self.current_index = null;
            self.current_item_type = .none;
        } else if (eql(item_type, "message") and self.blocks.items[index] == .text) {
            const final_text = try outputMessageText(self.allocator, item);
            self.blocks.items[index].text.final_text = final_text;
            self.blocks.items[index].text.signature = try encodeTextSignatureV1(self.allocator, getStringField(item, "id") orelse "", getStringField(item, "phase"));
            try self.emit(.{ .text_end = .{ .content_index = index, .content = final_text } });
            self.current_index = null;
            self.current_item_type = .none;
        } else if (eql(item_type, "function_call")) {
            try self.finalizeToolCall(index, item);
            self.current_index = null;
            self.current_item_type = .none;
        }
    }

    fn finalizeToolCall(self: *ResponsesStreamParser, index: usize, item: std.json.Value) !void {
        if (self.blocks.items[index] != .tool_call) return;
        const block = &self.blocks.items[index].tool_call;
        if (block.partial_json.items.len == 0) {
            if (getStringField(item, "arguments")) |arguments| try block.partial_json.appendSlice(self.allocator, arguments);
        }
        const partial_json = try block.partial_json.toOwnedSlice(self.allocator);
        var parsed_args = try json_parse.parseStreamingJson(self.allocator, partial_json);
        defer parsed_args.deinit();
        const arguments_json = try std.json.Stringify.valueAlloc(self.allocator, parsed_args.value, .{});
        block.final_arguments_json = arguments_json;
        const final_call: types.ToolCall = .{
            .id = block.id,
            .name = block.name,
            .arguments_json = arguments_json,
        };
        try self.emit(.{ .toolcall_end = .{
            .content_index = index,
            .tool_call = final_call,
        } });
    }

    fn completeResponse(self: *ResponsesStreamParser, response: std.json.Value) !void {
        if (getStringField(response, "id")) |id| self.output.response_id = try self.allocator.dupe(u8, id);
        if (response.object.get("usage")) |usage| self.output.usage = parseResponsesUsage(self.model, usage);
        if (getStringField(response, "status")) |status| {
            self.output.stop_reason = mapResponsesStopReason(status);
        }
    }

    fn finish(self: *ResponsesStreamParser) !void {
        var content = std.ArrayList(types.AssistantContent).empty;
        errdefer content.deinit(self.allocator);

        for (self.blocks.items) |block| {
            switch (block) {
                .thinking => |thinking| {
                    const text = thinking.final_text orelse thinking.text.items;
                    if (text.len == 0 and thinking.signature == null) continue;
                    try content.append(self.allocator, .{ .thinking = .{
                        .thinking = if (thinking.final_text != null) text else try self.allocator.dupe(u8, text),
                        .thinking_signature = thinking.signature,
                    } });
                },
                .text => |text| {
                    const value = text.final_text orelse text.text.items;
                    try content.append(self.allocator, .{ .text = .{
                        .text = if (text.final_text != null) value else try self.allocator.dupe(u8, value),
                        .text_signature = text.signature,
                    } });
                },
                .tool_call => |tool_call| {
                    const args = tool_call.final_arguments_json orelse blk: {
                        var parsed_args = try json_parse.parseStreamingJson(self.allocator, tool_call.partial_json.items);
                        defer parsed_args.deinit();
                        break :blk try std.json.Stringify.valueAlloc(self.allocator, parsed_args.value, .{});
                    };
                    try content.append(self.allocator, .{ .tool_call = .{
                        .id = tool_call.id,
                        .name = tool_call.name,
                        .arguments_json = args,
                    } });
                },
            }
        }

        self.output.content = try content.toOwnedSlice(self.allocator);
        if (self.output.content.len > 0 and self.output.stop_reason == .stop and hasToolCall(self.output.content)) {
            self.output.stop_reason = .tool_use;
        }
        if (self.output.stop_reason == .@"error") {
            try self.emit(.{ .@"error" = .{
                .reason = .@"error",
                .message = self.output,
            } });
        } else if (self.has_completion) {
            try self.emit(.{ .done = self.output.stop_reason });
        }
    }

    fn emit(self: *ResponsesStreamParser, event: types.StreamEvent) !void {
        try self.events.append(self.event_allocator, event);
    }
};

const ResponsesItemType = enum {
    none,
    reasoning,
    message,
    function_call,
};

const ResponsesStreamingBlock = union(enum) {
    thinking: ResponsesThinkingState,
    text: ResponsesTextState,
    tool_call: ResponsesToolCallState,
};

const ResponsesThinkingState = struct {
    text: std.ArrayList(u8) = .empty,
    final_text: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

const ResponsesTextState = struct {
    text: std.ArrayList(u8) = .empty,
    final_text: ?[]const u8 = null,
    signature: ?[]const u8 = null,
};

const ResponsesToolCallState = struct {
    id: []const u8,
    name: []const u8,
    partial_json: std.ArrayList(u8) = .empty,
    final_arguments_json: ?[]const u8 = null,
};

fn convertResponsesUserMessage(allocator: std.mem.Allocator, user: types.UserMessage) !?std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();
    for (user.content) |item| {
        switch (item) {
            .text => |text| {
                var part = objectValue();
                try putString(allocator, &part, "type", "input_text");
                try putSanitizedString(allocator, &part, "text", text.text);
                try content.append(part);
            },
            .image => |image| try content.append(try responsesImagePart(allocator, image)),
        }
    }
    if (content.items.len == 0) return null;

    var message = objectValue();
    try putString(allocator, &message, "role", "user");
    try putValue(allocator, &message, "content", .{ .array = content });
    return message;
}

fn convertResponsesAssistantMessage(
    allocator: std.mem.Allocator,
    model: types.Model,
    assistant: types.AssistantMessage,
    msg_index: usize,
) !std.ArrayList(std.json.Value) {
    var output = std.ArrayList(std.json.Value).empty;
    errdefer output.deinit(allocator);

    const is_different_model = !eql(assistant.model, model.id) and eql(assistant.provider, model.provider) and eql(assistant.api, model.api);
    var text_block_index: usize = 0;

    for (assistant.content) |block| switch (block) {
        .thinking => |thinking| {
            if (thinking.thinking_signature) |signature| {
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, signature, .{});
                defer parsed.deinit();
                try output.append(allocator, try cloneJsonValue(allocator, parsed.value));
            }
        },
        .text => |text| {
            try output.append(allocator, try responsesAssistantTextItem(
                allocator,
                text,
                msg_index,
                text_block_index,
            ));
            text_block_index += 1;
        },
        .tool_call => |tool_call| try output.append(allocator, try responsesFunctionCallItem(
            allocator,
            tool_call,
            is_different_model,
        )),
    };

    return output;
}

fn responsesAssistantTextItem(
    allocator: std.mem.Allocator,
    text: types.TextContent,
    msg_index: usize,
    text_block_index: usize,
) !std.json.Value {
    const parsed_signature = try parseTextSignature(allocator, text.text_signature);
    const fallback_message_id = if (text_block_index == 0)
        try std.fmt.allocPrint(allocator, "msg_pi_{d}", .{msg_index})
    else
        try std.fmt.allocPrint(allocator, "msg_pi_{d}_{d}", .{ msg_index, text_block_index });

    const raw_id = if (parsed_signature) |signature| signature.id else fallback_message_id;
    const message_id = if (raw_id.len > 64) blk: {
        const short_hash = try hash.shortHash(allocator, raw_id);
        break :blk try std.fmt.allocPrint(allocator, "msg_{s}", .{short_hash});
    } else try allocator.dupe(u8, raw_id);

    var item = objectValue();
    try putString(allocator, &item, "type", "message");
    try putString(allocator, &item, "role", "assistant");

    var content = std.json.Array.init(allocator);
    errdefer content.deinit();
    var output_text = objectValue();
    try putString(allocator, &output_text, "type", "output_text");
    try putSanitizedString(allocator, &output_text, "text", text.text);
    try putValue(allocator, &output_text, "annotations", .{ .array = std.json.Array.init(allocator) });
    try content.append(output_text);
    try putValue(allocator, &item, "content", .{ .array = content });
    try putString(allocator, &item, "status", "completed");
    try putOwnedString(allocator, &item, "id", message_id);
    if (parsed_signature) |signature| {
        if (signature.phase) |phase| try putString(allocator, &item, "phase", phase);
    }
    return item;
}

fn responsesFunctionCallItem(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    is_different_model: bool,
) !std.json.Value {
    const pipe = std.mem.indexOfScalar(u8, tool_call.id, '|');
    const call_id = if (pipe) |index| tool_call.id[0..index] else tool_call.id;
    const item_id = if (pipe) |index| tool_call.id[index + 1 ..] else null;

    var item = objectValue();
    try putString(allocator, &item, "type", "function_call");
    if (item_id) |id| {
        if (!(is_different_model and std.mem.startsWith(u8, id, "fc_"))) {
            try putString(allocator, &item, "id", id);
        }
    }
    try putString(allocator, &item, "call_id", call_id);
    try putString(allocator, &item, "name", tool_call.name);
    try putString(allocator, &item, "arguments", tool_call.arguments_json);
    return item;
}

fn convertResponsesToolResultMessage(
    allocator: std.mem.Allocator,
    model: types.Model,
    tool_result: types.ToolResultMessage,
) !std.json.Value {
    var text_result = std.ArrayList(u8).empty;
    defer text_result.deinit(allocator);
    var has_images = false;

    for (tool_result.content) |block| switch (block) {
        .text => |text| {
            if (text_result.items.len > 0) try text_result.append(allocator, '\n');
            try text_result.appendSlice(allocator, text.text);
        },
        .image => has_images = true,
    };

    const has_text = text_result.items.len > 0;
    const call_id = splitCallId(tool_result.tool_call_id);
    var message = objectValue();
    try putString(allocator, &message, "type", "function_call_output");
    try putString(allocator, &message, "call_id", call_id);

    if (has_images and modelSupportsInput(model, "image")) {
        var output = std.json.Array.init(allocator);
        errdefer output.deinit();
        if (has_text) {
            var part = objectValue();
            try putString(allocator, &part, "type", "input_text");
            try putSanitizedString(allocator, &part, "text", text_result.items);
            try output.append(part);
        }
        for (tool_result.content) |block| {
            if (block == .image) try output.append(try responsesImagePart(allocator, block.image));
        }
        try putValue(allocator, &message, "output", .{ .array = output });
    } else {
        try putSanitizedString(allocator, &message, "output", if (has_text) text_result.items else "(see attached image)");
    }

    return message;
}

fn responsesImagePart(allocator: std.mem.Allocator, image: types.ImageContent) !std.json.Value {
    var part = objectValue();
    try putString(allocator, &part, "type", "input_image");
    try putString(allocator, &part, "detail", "auto");
    try putOwnedString(
        allocator,
        &part,
        "image_url",
        try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data }),
    );
    return part;
}

fn parseTextSignature(allocator: std.mem.Allocator, signature: ?[]const u8) !?ParsedTextSignature {
    const value = signature orelse return null;
    if (std.mem.startsWith(u8, value, "{")) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch null;
        if (parsed) |*payload| {
            defer payload.deinit();
            if (payload.value == .object) {
                const version = payload.value.object.get("v");
                const id = payload.value.object.get("id");
                if (version != null and id != null and version.? == .integer and version.?.integer == 1 and id.? == .string) {
                    var result: ParsedTextSignature = .{ .id = try allocator.dupe(u8, id.?.string) };
                    if (payload.value.object.get("phase")) |phase| {
                        if (phase == .string and (eql(phase.string, "commentary") or eql(phase.string, "final_answer"))) {
                            result.phase = try allocator.dupe(u8, phase.string);
                        }
                    }
                    return result;
                }
            }
        }
    }
    return .{ .id = try allocator.dupe(u8, value) };
}

fn encodeTextSignatureV1(allocator: std.mem.Allocator, id: []const u8, phase: ?[]const u8) ![]const u8 {
    var value = objectValue();
    try putInteger(allocator, &value, "v", 1);
    try putString(allocator, &value, "id", id);
    if (phase) |value_phase| try putString(allocator, &value, "phase", value_phase);
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn outputMessageText(allocator: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    const content_value = item.object.get("content") orelse return allocator.dupe(u8, "");
    if (content_value != .array) return allocator.dupe(u8, "");

    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    for (content_value.array.items) |part| {
        if (part != .object) continue;
        const part_type = getStringField(part, "type") orelse continue;
        if (eql(part_type, "output_text")) {
            try text.appendSlice(allocator, getStringField(part, "text") orelse "");
        } else if (eql(part_type, "refusal")) {
            try text.appendSlice(allocator, getStringField(part, "refusal") orelse "");
        }
    }
    return text.toOwnedSlice(allocator);
}

fn parseResponsesUsage(model: types.Model, raw_usage: std.json.Value) types.Usage {
    const input_tokens = getUnsignedField(raw_usage, "input_tokens") orelse 0;
    const output_tokens = getUnsignedField(raw_usage, "output_tokens") orelse 0;
    const details = getObjectField(raw_usage, "input_tokens_details");
    const cached_tokens = if (details) |value| getUnsignedField(value, "cached_tokens") orelse 0 else 0;
    const input = if (input_tokens > cached_tokens) input_tokens - cached_tokens else 0;
    var usage: types.Usage = .{
        .input = input,
        .output = output_tokens,
        .cache_read = cached_tokens,
        .cache_write = 0,
        .total_tokens = getUnsignedField(raw_usage, "total_tokens") orelse input_tokens + output_tokens,
    };
    _ = models.calculateCost(model, &usage);
    return usage;
}

fn mapResponsesStopReason(status: []const u8) types.StopReason {
    if (eql(status, "incomplete")) return .length;
    if (eql(status, "failed") or eql(status, "cancelled")) return .@"error";
    return .stop;
}

fn buildForeignResponsesItemId(allocator: std.mem.Allocator, item_id: []const u8) ![]u8 {
    const short_hash = try hash.shortHash(allocator, item_id);
    defer allocator.free(short_hash);
    const normalized = try std.fmt.allocPrint(allocator, "fc_{s}", .{short_hash});
    if (normalized.len <= 64) return normalized;
    defer allocator.free(normalized);
    return allocator.dupe(u8, normalized[0..64]);
}

fn normalizeIdPart(allocator: std.mem.Allocator, part: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (part) |byte| {
        try result.append(allocator, if (isIdByte(byte)) byte else '_');
        if (result.items.len == 64) break;
    }
    while (result.items.len > 0 and result.items[result.items.len - 1] == '_') {
        _ = result.pop();
    }
    return result.toOwnedSlice(allocator);
}

fn isResponsesToolCallProvider(provider: []const u8) bool {
    return eql(provider, "openai") or
        eql(provider, "openai-codex") or
        eql(provider, "opencode") or
        eql(provider, "azure-openai-responses");
}

fn isIdByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn splitCallId(id: []const u8) []const u8 {
    const pipe = std.mem.indexOfScalar(u8, id, '|') orelse return id;
    return id[0..pipe];
}

fn hasToolCall(content: []const types.AssistantContent) bool {
    for (content) |block| {
        if (block == .tool_call) return true;
    }
    return false;
}

fn parseOrString(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return .{ .string = try allocator.dupe(u8, json) };
    defer parsed.deinit();
    return cloneJsonValue(allocator, parsed.value);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer cloned.deinit();
            for (array.items) |item| try cloned.append(try cloneJsonValue(allocator, item));
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = objectValue();
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try putValue(allocator, &cloned, entry.key_ptr.*, try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk cloned;
        },
    };
}

fn objectValue() std.json.Value {
    return .{ .object = .empty };
}

fn putValue(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), value);
}

fn putString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try putOwnedString(allocator, object, key, try allocator.dupe(u8, value));
}

fn putOwnedString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .string = value });
}

fn putSanitizedString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try putOwnedString(allocator, object, key, try sanitize_unicode.sanitizeSurrogates(allocator, value));
}

fn putBool(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: bool) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putNull(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .null);
}

fn putInteger(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: i64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .integer = value });
}

fn getStringField(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return if (nested == .string) nested.string else null;
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return if (nested == .object) nested else null;
}

fn getUnsignedField(value: std.json.Value, field: []const u8) ?u64 {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return switch (nested) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(float) else null,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        else => null,
    };
}

fn modelSupportsInput(model: types.Model, input: []const u8) bool {
    for (model.input) |candidate| {
        if (eql(candidate, input)) return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn expectObjectString(value: std.json.Value, field: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, getStringField(value, field) orelse return error.MissingStringField);
}

const responses_usage: types.Usage = .{};

// Ported from packages/ai/test/openai-responses-message-id.test.ts.
test "OpenAI Responses conversion generates unique fallback message ids for replayed text blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
    const assistant_content = [_]types.AssistantContent{
        .{ .thinking = .{ .thinking = "private reasoning" } },
        .{ .text = .{ .text = "visible answer" } },
    };
    const messages = [_]types.Message{
        .{ .user = .{ .content = &user_content, .timestamp_ms = 1 } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = types.api.anthropic_messages,
            .provider = "anthropic",
            .model = "claude-opus-4-8",
            .usage = responses_usage,
            .stop_reason = .stop,
            .timestamp_ms = 2,
        } },
    };
    const context: types.Context = .{
        .system_prompt = "You are concise.",
        .messages = &messages,
    };

    const input = try convertResponsesMessagesValue(allocator, model, context, .{});
    var message_ids = std.ArrayList([]const u8).empty;
    defer message_ids.deinit(allocator);
    for (input.array.items) |item| {
        if (eql(getStringField(item, "type") orelse "", "message")) {
            try message_ids.append(allocator, getStringField(item, "id") orelse return error.MissingMessageId);
        }
    }

    try std.testing.expectEqual(@as(usize, 2), message_ids.items.len);
    try std.testing.expectEqualStrings("msg_pi_1", message_ids.items[0]);
    try std.testing.expectEqualStrings("msg_pi_1_1", message_ids.items[1]);
}

// Ported from packages/ai/test/openai-responses-foreign-toolcall-id.test.ts.
test "OpenAI Responses conversion hashes foreign Copilot tool item ids into fc hash shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;
    const raw_tool_call_id =
        "call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vifiIM4g3A8XXyOj8q4Bt6SLUG7gqY1E3ELkrkVQNHglRfUmWj84lqxJY+Puieb3VKyX0FB+83TUzn91cDMF/4gzt990IzqVrc+nIb9RRscRD070Du16q1glydVjWR0SBJsE6TbY/esOjFpqplogQqrajm1eI++f3eLi73R6q7hVusY0QbeFySVxABCjhN0lXB04caBe1rzHjYzul6MAXj7uq+0r17VLq+yrtyYhN12wkmFqHeqTyEei6EFPbMy24Nc+IbJlkP0OCg02W+gOnyBFcbi2ctvJFSOhSjt1CqBdqCnnhwUqXjbWiT0wh3DmLScRgTHmGkaI+oAcQQjfic65nxj+TnEkReA==";

    const user_content = [_]types.UserContent{.{ .text = .{ .text = "Use the tool." } }};
    const assistant_content = [_]types.AssistantContent{.{ .tool_call = .{
        .id = raw_tool_call_id,
        .name = "edit",
        .arguments_json = "{\"path\":\"src/styles/app.css\"}",
    } }};
    const tool_content = [_]types.UserContent{.{ .text = .{ .text = "ok" } }};
    const messages = [_]types.Message{
        .{ .user = .{ .content = &user_content, .timestamp_ms = 1 } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = types.api.openai_responses,
            .provider = "github-copilot",
            .model = "gpt-5.5",
            .usage = responses_usage,
            .stop_reason = .tool_use,
            .timestamp_ms = 2,
        } },
        .{ .tool_result = .{
            .tool_call_id = raw_tool_call_id,
            .tool_name = "edit",
            .content = &tool_content,
            .timestamp_ms = 3,
        } },
    };
    const context: types.Context = .{
        .system_prompt = "You are concise.",
        .messages = &messages,
    };

    const input = try convertResponsesMessagesValue(allocator, model, context, .{});
    var function_call: ?std.json.Value = null;
    for (input.array.items) |item| {
        if (eql(getStringField(item, "type") orelse "", "function_call")) {
            function_call = item;
            break;
        }
    }
    const call = function_call orelse return error.MissingFunctionCall;

    const item_id = raw_tool_call_id[(std.mem.indexOfScalar(u8, raw_tool_call_id, '|') orelse return error.MissingPipe) + 1 ..];
    const expected_hash = try hash.shortHash(allocator, item_id);
    const expected_item_id = try std.fmt.allocPrint(allocator, "fc_{s}", .{expected_hash});
    try expectObjectString(call, "id", expected_item_id);
    const actual_item_id = getStringField(call, "id") orelse return error.MissingFunctionCallItemId;
    try std.testing.expect(actual_item_id.len <= 64);
    try std.testing.expect(std.mem.startsWith(u8, actual_item_id, "fc_"));
}

// Ported from packages/ai/test/openai-responses-partial-json-cleanup.test.ts.
test "OpenAI Responses stream removes partial JSON scratch buffer when tool call is done" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("openai", "gpt-5-mini") orelse return error.ModelMissing).*;
    const arguments_json = "{\"path\":\"README.md\",\"content\":\"updated\"}";
    const events = [_][]const u8{
        "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_test\",\"call_id\":\"call_test\",\"name\":\"edit\",\"arguments\":\"\"}}",
        "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"path\\\":\\\"README.md\\\"\"}",
        "{\"type\":\"response.function_call_arguments.delta\",\"delta\":\",\\\"content\\\":\\\"updated\\\"}\"}",
        "{\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\",\\\"content\\\":\\\"updated\\\"}\"}",
        "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_test\",\"call_id\":\"call_test\",\"name\":\"edit\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\",\\\"content\\\":\\\"updated\\\"}\"}}",
        "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\",\"status\":\"completed\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}",
    };

    var parsed = try processResponsesEvents(allocator, model, &events);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.result.message.content.len);
    const tool_call = parsed.result.message.content[0].tool_call;
    try std.testing.expectEqualStrings("call_test|fc_test", tool_call.id);
    try std.testing.expectEqualStrings("edit", tool_call.name);
    try std.testing.expectEqualStrings(arguments_json, tool_call.arguments_json);

    var found_end = false;
    for (parsed.result.events.items) |event| {
        if (event == .toolcall_end) {
            found_end = true;
            try std.testing.expectEqualStrings(arguments_json, event.toolcall_end.tool_call.arguments_json);
        }
    }
    try std.testing.expect(found_end);
}
