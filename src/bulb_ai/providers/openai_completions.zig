const std = @import("std");
const cache_retention = @import("cache_retention.zig");
const json_parse = @import("../utils/json_parse.zig");
const models = @import("../models.zig");
const openai_prompt_cache = @import("openai_prompt_cache.zig");
const sanitize_unicode = @import("../utils/sanitize_unicode.zig");
const transform_messages = @import("transform_messages.zig");
const types = @import("../types.zig");

pub const ToolChoice = union(enum) {
    auto,
    none,
    required,
    function_name: []const u8,
};

pub const OpenAICompletionsOptions = struct {
    base: types.StreamOptions = .{},
    tool_choice: ?ToolChoice = null,
    reasoning_effort: ?types.ThinkingLevel = null,
};

pub const ResolvedOpenAICompletionsCompat = struct {
    supports_store: bool,
    supports_developer_role: bool,
    supports_reasoning_effort: bool,
    supports_usage_in_streaming: bool,
    max_tokens_field: types.MaxTokensField,
    requires_tool_result_name: bool,
    requires_assistant_after_tool_result: bool,
    requires_thinking_as_text: bool,
    requires_reasoning_content_on_assistant_messages: bool,
    thinking_format: types.ThinkingFormat,
    zai_tool_stream: bool,
    supports_strict_mode: bool,
    cache_control_format: ?[]const u8,
    send_session_affinity_headers: bool,
    supports_long_cache_retention: bool,
};

pub const BuiltParams = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,

    pub fn deinit(self: *BuiltParams) void {
        self.arena.deinit();
    }

    pub fn stringify(self: *const BuiltParams, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self.value, .{});
    }
};

pub const ParsedStream = struct {
    arena: std.heap.ArenaAllocator,
    result: types.StreamResult,

    pub fn deinit(self: *ParsedStream) void {
        self.result.deinit();
        self.arena.deinit();
    }
};

pub const StopReasonMapping = struct {
    stop_reason: types.StopReason,
    error_message: ?[]const u8 = null,
};

pub fn parseStreamChunks(
    allocator: std.mem.Allocator,
    model: types.Model,
    chunks_json: []const ?[]const u8,
    options: types.StreamOptions,
) !ParsedStream {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parser = StreamParser.init(a, allocator, model, options);
    errdefer parser.events.deinit(allocator);
    try parser.emit(.{ .start = {} });

    for (chunks_json) |chunk_json| {
        if (isAborted(options)) break;
        const json = chunk_json orelse continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer parsed.deinit();
        try parser.processChunk(parsed.value);
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

pub fn parseChunkUsage(model: types.Model, raw_usage: std.json.Value) types.Usage {
    const prompt_tokens = getUnsignedField(raw_usage, "prompt_tokens") orelse 0;
    const completion_tokens = getUnsignedField(raw_usage, "completion_tokens") orelse 0;
    const prompt_details = getObjectField(raw_usage, "prompt_tokens_details");
    const cache_read_tokens = if (prompt_details) |details|
        getUnsignedField(details, "cached_tokens") orelse (getUnsignedField(raw_usage, "prompt_cache_hit_tokens") orelse 0)
    else
        getUnsignedField(raw_usage, "prompt_cache_hit_tokens") orelse 0;
    const cache_write_tokens = if (prompt_details) |details| getUnsignedField(details, "cache_write_tokens") orelse 0 else 0;
    const non_output_prompt_tokens = cache_read_tokens +| cache_write_tokens;
    const input_tokens = if (prompt_tokens > non_output_prompt_tokens) prompt_tokens - non_output_prompt_tokens else 0;

    var usage: types.Usage = .{
        .input = input_tokens,
        .output = completion_tokens,
        .cache_read = cache_read_tokens,
        .cache_write = cache_write_tokens,
    };
    usage.calculateTotalTokens();
    _ = models.calculateCost(model, &usage);
    return usage;
}

pub fn mapStopReason(allocator: std.mem.Allocator, reason: []const u8) !StopReasonMapping {
    if (eql(reason, "stop") or eql(reason, "end")) return .{ .stop_reason = .stop };
    if (eql(reason, "length")) return .{ .stop_reason = .length };
    if (eql(reason, "function_call") or eql(reason, "tool_calls")) return .{ .stop_reason = .tool_use };
    if (eql(reason, "content_filter")) {
        return .{ .stop_reason = .@"error", .error_message = "Provider finish_reason: content_filter" };
    }
    if (eql(reason, "network_error")) {
        return .{ .stop_reason = .@"error", .error_message = "Provider finish_reason: network_error" };
    }
    return .{
        .stop_reason = .@"error",
        .error_message = try std.fmt.allocPrint(allocator, "Provider finish_reason: {s}", .{reason}),
    };
}

const StreamParser = struct {
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
    model: types.Model,
    options: types.StreamOptions,
    events: std.ArrayList(types.StreamEvent) = .empty,
    output: types.AssistantMessage,
    blocks: std.ArrayList(StreamingBlock) = .empty,
    text_index: ?usize = null,
    thinking_index: ?usize = null,
    has_finish_reason: bool = false,
    finalized: bool = false,
    tool_blocks_by_index: std.AutoHashMap(usize, usize),
    tool_blocks_by_id: std.StringHashMap(usize),

    fn init(
        allocator: std.mem.Allocator,
        event_allocator: std.mem.Allocator,
        model: types.Model,
        options: types.StreamOptions,
    ) StreamParser {
        return .{
            .allocator = allocator,
            .event_allocator = event_allocator,
            .model = model,
            .options = options,
            .output = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = .{},
                .stop_reason = .stop,
            },
            .tool_blocks_by_index = std.AutoHashMap(usize, usize).init(allocator),
            .tool_blocks_by_id = std.StringHashMap(usize).init(allocator),
        };
    }

    fn processChunk(self: *StreamParser, chunk: std.json.Value) !void {
        if (chunk != .object) return;

        if (self.output.response_id == null) {
            if (getStringField(chunk, "id")) |id| {
                if (id.len > 0) self.output.response_id = try self.allocator.dupe(u8, id);
            }
        }
        if (self.output.response_model == null) {
            if (getStringField(chunk, "model")) |response_model| {
                if (response_model.len > 0 and !eql(response_model, self.model.id)) {
                    self.output.response_model = try self.allocator.dupe(u8, response_model);
                }
            }
        }
        if (chunk.object.get("usage")) |usage| {
            self.output.usage = parseChunkUsage(self.model, usage);
        }

        const choices = chunk.object.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (choice != .object) return;

        if (chunk.object.get("usage") == null) {
            if (choice.object.get("usage")) |usage| {
                self.output.usage = parseChunkUsage(self.model, usage);
            }
        }

        if (getStringField(choice, "finish_reason")) |reason| {
            const mapped = try mapStopReason(self.allocator, reason);
            self.output.stop_reason = mapped.stop_reason;
            if (mapped.error_message) |message| {
                self.output.error_message = if (std.mem.startsWith(u8, message, "Provider finish_reason:"))
                    message
                else
                    try self.allocator.dupe(u8, message);
            }
            self.has_finish_reason = true;
        }

        if (choice.object.get("delta")) |delta| {
            try self.processDelta(delta);
        }
    }

    fn processDelta(self: *StreamParser, delta: std.json.Value) !void {
        if (delta != .object) return;

        if (getStringField(delta, "content")) |content| {
            if (content.len > 0) try self.appendTextDelta(content);
        }

        const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
        for (reasoning_fields) |field| {
            const value = getStringField(delta, field) orelse continue;
            if (value.len == 0) continue;
            const signature = if (eql(self.model.provider, "opencode-go") and eql(field, "reasoning")) "reasoning_content" else field;
            try self.appendThinkingDelta(signature, value);
            break;
        }

        if (delta.object.get("tool_calls")) |tool_calls| {
            if (tool_calls == .array) {
                for (tool_calls.array.items) |tool_call| {
                    try self.processToolCallDelta(tool_call);
                }
            }
        }

        if (delta.object.get("reasoning_details")) |details| {
            try self.processReasoningDetails(details);
        }
    }

    fn appendTextDelta(self: *StreamParser, delta: []const u8) !void {
        const index = try self.ensureTextBlock();
        try self.blocks.items[index].text.text.appendSlice(self.allocator, delta);
        try self.emit(.{ .text_delta = .{
            .content_index = index,
            .delta = try self.allocator.dupe(u8, delta),
        } });
    }

    fn appendThinkingDelta(self: *StreamParser, signature: []const u8, delta: []const u8) !void {
        const index = try self.ensureThinkingBlock(signature);
        try self.blocks.items[index].thinking.thinking.appendSlice(self.allocator, delta);
        try self.emit(.{ .thinking_delta = .{
            .content_index = index,
            .delta = try self.allocator.dupe(u8, delta),
        } });
    }

    fn processToolCallDelta(self: *StreamParser, tool_call: std.json.Value) !void {
        if (tool_call != .object) return;
        const index = try self.ensureToolCallBlock(tool_call);
        const args_delta = getNestedStringField(tool_call, "function", "arguments") orelse "";
        if (args_delta.len > 0) {
            try self.blocks.items[index].tool_call.partial_args.appendSlice(self.allocator, args_delta);
        }
        try self.emit(.{ .toolcall_delta = .{
            .content_index = index,
            .delta = try self.allocator.dupe(u8, args_delta),
        } });
    }

    fn processReasoningDetails(self: *StreamParser, details: std.json.Value) !void {
        if (details != .array) return;
        for (details.array.items) |detail| {
            if (detail != .object) continue;
            const detail_type = getStringField(detail, "type") orelse continue;
            if (!eql(detail_type, "reasoning.encrypted")) continue;
            const id = getStringField(detail, "id") orelse continue;
            const data = getStringField(detail, "data") orelse continue;
            if (id.len == 0 or data.len == 0) continue;

            const block_index = self.tool_blocks_by_id.get(id) orelse self.findToolBlockById(id) orelse continue;
            const signature = try std.json.Stringify.valueAlloc(self.allocator, detail, .{});
            self.blocks.items[block_index].tool_call.thought_signature = signature;
        }
    }

    fn ensureTextBlock(self: *StreamParser) !usize {
        if (self.text_index) |index| return index;
        const index = self.blocks.items.len;
        try self.blocks.append(self.allocator, .{ .text = .{} });
        self.text_index = index;
        try self.emit(.{ .text_start = .{ .content_index = index } });
        return index;
    }

    fn ensureThinkingBlock(self: *StreamParser, signature: []const u8) !usize {
        if (self.thinking_index) |index| return index;
        const index = self.blocks.items.len;
        try self.blocks.append(self.allocator, .{
            .thinking = .{
                .thinking_signature = try self.allocator.dupe(u8, signature),
            },
        });
        self.thinking_index = index;
        try self.emit(.{ .thinking_start = .{ .content_index = index } });
        return index;
    }

    fn ensureToolCallBlock(self: *StreamParser, tool_call: std.json.Value) !usize {
        const stream_index = getUnsignedField(tool_call, "index");
        if (stream_index) |raw_index| {
            const index = std.math.cast(usize, raw_index) orelse return error.StreamIndexTooLarge;
            if (self.tool_blocks_by_index.get(index)) |block_index| {
                try self.refreshToolCallBlock(block_index, tool_call, index);
                return block_index;
            }
        }

        const id = getStringField(tool_call, "id");
        if (id) |value| {
            if (self.tool_blocks_by_id.get(value)) |block_index| {
                if (stream_index) |raw_index| {
                    const index = std.math.cast(usize, raw_index) orelse return error.StreamIndexTooLarge;
                    try self.refreshToolCallBlock(block_index, tool_call, index);
                } else {
                    try self.refreshToolCallBlock(block_index, tool_call, null);
                }
                return block_index;
            }
        }

        const index = self.blocks.items.len;
        const initial_id = try self.allocator.dupe(u8, id orelse "");
        const function_name = getNestedStringField(tool_call, "function", "name") orelse "";
        const initial_name = try self.allocator.dupe(u8, function_name);
        const block_stream_index = if (stream_index) |raw_index| std.math.cast(usize, raw_index) orelse return error.StreamIndexTooLarge else null;

        try self.blocks.append(self.allocator, .{
            .tool_call = .{
                .id = initial_id,
                .name = initial_name,
                .stream_index = block_stream_index,
            },
        });
        if (block_stream_index) |index_key| try self.tool_blocks_by_index.put(index_key, index);
        if (id) |value| {
            if (value.len > 0) try self.tool_blocks_by_id.put(try self.allocator.dupe(u8, value), index);
        }
        try self.emit(.{ .toolcall_start = .{ .content_index = index } });
        return index;
    }

    fn refreshToolCallBlock(self: *StreamParser, block_index: usize, tool_call: std.json.Value, stream_index: ?usize) !void {
        const block = &self.blocks.items[block_index].tool_call;
        if (stream_index) |index| {
            if (block.stream_index == null) block.stream_index = index;
            try self.tool_blocks_by_index.put(index, block_index);
        }
        if (getStringField(tool_call, "id")) |id| {
            if (id.len > 0) {
                const id_key = try self.allocator.dupe(u8, id);
                if (block.id.len == 0) block.id = id_key;
                try self.tool_blocks_by_id.put(id_key, block_index);
            }
        }
        if (getNestedStringField(tool_call, "function", "name")) |name| {
            if (name.len > 0 and block.name.len == 0) {
                block.name = try self.allocator.dupe(u8, name);
            }
        }
    }

    fn findToolBlockById(self: *const StreamParser, id: []const u8) ?usize {
        for (self.blocks.items, 0..) |block, index| {
            if (block == .tool_call and eql(block.tool_call.id, id)) return index;
        }
        return null;
    }

    fn finish(self: *StreamParser) !void {
        try self.finalizeBlocks();
        if (isAborted(self.options)) {
            try self.emitTerminal(.aborted, "Request was aborted");
            return;
        }
        if (self.output.stop_reason == .aborted) {
            try self.emitTerminal(.aborted, "Request was aborted");
            return;
        }
        if (self.output.stop_reason == .@"error") {
            try self.emitTerminal(.@"error", self.output.error_message orelse "Provider returned an error stop reason");
            return;
        }
        if (!self.has_finish_reason) {
            try self.emitTerminal(.@"error", "Stream ended without finish_reason");
            return;
        }

        try self.emit(.{ .done = self.output.stop_reason });
    }

    fn finalizeBlocks(self: *StreamParser) !void {
        if (self.finalized) return;
        self.finalized = true;

        var content = std.ArrayList(types.AssistantContent).empty;
        for (self.blocks.items, 0..) |*block, index| {
            switch (block.*) {
                .text => |*text| {
                    const final_text = try text.text.toOwnedSlice(self.allocator);
                    try content.append(self.allocator, .{ .text = .{ .text = final_text } });
                    try self.emit(.{ .text_end = .{
                        .content_index = index,
                        .content = final_text,
                    } });
                },
                .thinking => |*thinking| {
                    const final_thinking = try thinking.thinking.toOwnedSlice(self.allocator);
                    try content.append(self.allocator, .{ .thinking = .{
                        .thinking = final_thinking,
                        .thinking_signature = thinking.thinking_signature,
                    } });
                    try self.emit(.{ .thinking_end = .{
                        .content_index = index,
                        .content = final_thinking,
                    } });
                },
                .tool_call => |*tool_call| {
                    const partial_args = try tool_call.partial_args.toOwnedSlice(self.allocator);
                    var parsed_args = try json_parse.parseStreamingJson(self.allocator, partial_args);
                    defer parsed_args.deinit();
                    const arguments_json = try std.json.Stringify.valueAlloc(self.allocator, parsed_args.value, .{});
                    tool_call.arguments_json = arguments_json;
                    const final_call: types.ToolCall = .{
                        .id = tool_call.id,
                        .name = tool_call.name,
                        .arguments_json = arguments_json,
                        .thought_signature = tool_call.thought_signature,
                    };
                    try content.append(self.allocator, .{ .tool_call = final_call });
                    try self.emit(.{ .toolcall_end = .{
                        .content_index = index,
                        .tool_call = final_call,
                    } });
                },
            }
        }
        self.output.content = try content.toOwnedSlice(self.allocator);
    }

    fn emitTerminal(self: *StreamParser, reason: types.StopReason, message: []const u8) !void {
        self.output.stop_reason = reason;
        self.output.error_message = try self.allocator.dupe(u8, message);
        try self.emit(.{ .@"error" = .{
            .reason = reason,
            .message = self.output,
        } });
    }

    fn emit(self: *StreamParser, event: types.StreamEvent) !void {
        try self.events.append(self.event_allocator, event);
        if (self.options.signal) |signal| {
            if (self.options.on_event) |observer| observer(signal, event);
        }
    }
};

const StreamingBlock = union(enum) {
    text: TextState,
    thinking: ThinkingState,
    tool_call: ToolCallState,
};

const TextState = struct {
    text: std.ArrayList(u8) = .empty,
};

const ThinkingState = struct {
    thinking: std.ArrayList(u8) = .empty,
    thinking_signature: []const u8,
};

const ToolCallState = struct {
    id: []const u8,
    name: []const u8,
    partial_args: std.ArrayList(u8) = .empty,
    arguments_json: []const u8 = "{}",
    thought_signature: ?[]const u8 = null,
    stream_index: ?usize = null,
};

pub fn buildParams(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?OpenAICompletionsOptions,
    compat_override: ?ResolvedOpenAICompletionsCompat,
    env: ?*const std.process.Environ.Map,
) !BuiltParams {
    const compat = compat_override orelse getCompat(model);
    const requested_retention = if (options) |opts| opts.base.cache_retention else types.CacheRetention.short;
    const cache_retention_override: ?types.CacheRetention = if (requested_retention == .short) null else requested_retention;
    const retention = cache_retention.resolveCacheRetention(env, cache_retention_override);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var root = objectValue();
    try putString(a, &root, "model", model.id);
    try putValue(a, &root, "messages", try convertMessagesValue(a, model, context, compat));
    try putBool(a, &root, "stream", true);

    if (try openai_prompt_cache.completionsPromptCacheKey(a, model, if (options) |opts| opts.base.session_id else null, retention)) |key| {
        try putOwnedString(a, &root, "prompt_cache_key", key);
    }
    if (openai_prompt_cache.promptCacheRetention(modelWithLongRetention(model, compat), retention)) |prompt_retention| {
        try putString(a, &root, "prompt_cache_retention", prompt_retention);
    }

    if (compat.supports_usage_in_streaming) {
        var stream_options = objectValue();
        try putBool(a, &stream_options, "include_usage", true);
        try putValue(a, &root, "stream_options", stream_options);
    }

    if (compat.supports_store) {
        try putBool(a, &root, "store", false);
    }

    if (options) |opts| {
        if (opts.base.max_tokens) |max_tokens| {
            switch (compat.max_tokens_field) {
                .max_tokens => try putInteger(a, &root, "max_tokens", max_tokens),
                .max_completion_tokens => try putInteger(a, &root, "max_completion_tokens", max_tokens),
            }
        }
        if (opts.base.temperature) |temperature| {
            try putFloat(a, &root, "temperature", temperature);
        }
        if (opts.tool_choice) |tool_choice| {
            try putValue(a, &root, "tool_choice", try toolChoiceValue(a, tool_choice));
        }
    }

    const has_tools = context.tools.len > 0;
    if (has_tools) {
        try putValue(a, &root, "tools", try convertToolsValue(a, context.tools, compat));
        if (compat.zai_tool_stream) try putBool(a, &root, "tool_stream", true);
    } else if (hasToolHistory(context.messages)) {
        try putValue(a, &root, "tools", emptyArray(a));
    }

    if (try getCompatCacheControl(a, compat, retention)) |cache_control_value| {
        try applyAnthropicCacheControl(a, &root, cache_control_value);
    }

    const reasoning_effort = if (options) |opts| opts.reasoning_effort else null;
    try applyThinkingOptions(a, &root, model, compat, reasoning_effort);

    return .{
        .arena = arena,
        .value = root,
    };
}

pub fn convertMessagesValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    compat: ResolvedOpenAICompletionsCompat,
) !std.json.Value {
    var transformed = try transform_messages.transformMessages(
        allocator,
        context.messages,
        model,
        transform_messages.openAICompatNormalizeToolCallId,
    );
    defer transformed.deinit();

    var result = std.json.Array.init(allocator);
    errdefer result.deinit();

    if (context.system_prompt) |prompt| {
        var message = objectValue();
        const role = if (model.reasoning and compat.supports_developer_role) "developer" else "system";
        try putString(allocator, &message, "role", role);
        try putSanitizedString(allocator, &message, "content", prompt);
        try result.append(.{ .object = message.object });
    }

    var last_role: LastRole = .none;
    var i: usize = 0;
    while (i < transformed.messages.len) : (i += 1) {
        const message = transformed.messages[i];
        switch (message) {
            .user => |user| {
                if (compat.requires_assistant_after_tool_result and last_role == .tool_result) {
                    try appendAssistantBridge(allocator, &result);
                }
                if (try convertUserMessage(allocator, user)) |converted| {
                    try result.append(converted);
                }
                last_role = .user;
            },
            .assistant => |assistant| {
                if (try convertAssistantMessage(allocator, model, compat, assistant)) |converted| {
                    try result.append(converted);
                    last_role = .assistant;
                }
            },
            .tool_result => {
                var image_blocks = std.json.Array.init(allocator);
                errdefer image_blocks.deinit();

                var j = i;
                while (j < transformed.messages.len) : (j += 1) {
                    if (transformed.messages[j] != .tool_result) break;
                    const tool_result = transformed.messages[j].tool_result;
                    try result.append(try convertToolResultMessage(allocator, tool_result, compat, modelSupportsInput(model, "image"), &image_blocks));
                }
                i = j - 1;

                if (image_blocks.items.len > 0) {
                    if (compat.requires_assistant_after_tool_result) {
                        try appendAssistantBridge(allocator, &result);
                    }
                    var content = std.json.Array.init(allocator);
                    errdefer content.deinit();
                    var text = objectValue();
                    try putString(allocator, &text, "type", "text");
                    try putString(allocator, &text, "text", "Attached image(s) from tool result:");
                    try content.append(.{ .object = text.object });
                    for (image_blocks.items) |block| try content.append(block);

                    var user_message = objectValue();
                    try putString(allocator, &user_message, "role", "user");
                    try putValue(allocator, &user_message, "content", .{ .array = content });
                    try result.append(.{ .object = user_message.object });
                    last_role = .user;
                } else {
                    image_blocks.deinit();
                    last_role = .tool_result;
                }
            },
        }
    }

    return .{ .array = result };
}

pub fn convertToolsValue(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    compat: ResolvedOpenAICompletionsCompat,
) !std.json.Value {
    var result = std.json.Array.init(allocator);
    errdefer result.deinit();
    for (tools) |tool| {
        var tool_value = objectValue();
        try putString(allocator, &tool_value, "type", "function");

        var function = objectValue();
        try putString(allocator, &function, "name", tool.name);
        try putString(allocator, &function, "description", tool.description);
        try putValue(allocator, &function, "parameters", try parseOrString(allocator, tool.parameters_json));
        if (compat.supports_strict_mode) try putBool(allocator, &function, "strict", false);
        try putValue(allocator, &tool_value, "function", function);
        try result.append(.{ .object = tool_value.object });
    }
    return .{ .array = result };
}

pub fn detectCompat(model: types.Model) ResolvedOpenAICompletionsCompat {
    const provider = model.provider;
    const base_url = model.base_url;

    const is_zai = eql(provider, "zai") or contains(base_url, "api.z.ai");
    const is_together = eql(provider, "together") or contains(base_url, "api.together.ai") or contains(base_url, "api.together.xyz");
    const is_moonshot = eql(provider, "moonshotai") or eql(provider, "moonshotai-cn") or contains(base_url, "api.moonshot.");
    const is_openrouter = eql(provider, "openrouter") or contains(base_url, "openrouter.ai");
    const is_cloudflare_workers_ai = eql(provider, "cloudflare-workers-ai") or contains(base_url, "api.cloudflare.com");
    const is_cloudflare_ai_gateway = eql(provider, "cloudflare-ai-gateway") or contains(base_url, "gateway.ai.cloudflare.com");
    const is_deepseek = eql(provider, "deepseek") or contains(base_url, "deepseek.com");
    const is_grok = eql(provider, "xai") or contains(base_url, "api.x.ai");

    const is_non_standard = eql(provider, "cerebras") or
        contains(base_url, "cerebras.ai") or
        is_grok or
        is_together or
        contains(base_url, "chutes.ai") or
        is_deepseek or
        is_zai or
        is_moonshot or
        eql(provider, "opencode") or
        contains(base_url, "opencode.ai") or
        is_cloudflare_workers_ai or
        is_cloudflare_ai_gateway;

    const use_max_tokens = contains(base_url, "chutes.ai") or is_moonshot or is_cloudflare_ai_gateway or is_together;
    return .{
        .supports_store = !is_non_standard,
        .supports_developer_role = !is_non_standard and !is_openrouter,
        .supports_reasoning_effort = !is_grok and !is_zai and !is_moonshot and !is_together and !is_cloudflare_ai_gateway,
        .supports_usage_in_streaming = true,
        .max_tokens_field = if (use_max_tokens) .max_tokens else .max_completion_tokens,
        .requires_tool_result_name = false,
        .requires_assistant_after_tool_result = false,
        .requires_thinking_as_text = false,
        .requires_reasoning_content_on_assistant_messages = is_deepseek,
        .thinking_format = if (is_deepseek)
            .deepseek
        else if (is_zai)
            .zai
        else if (is_together)
            .together
        else if (is_openrouter)
            .openrouter
        else
            .openai,
        .zai_tool_stream = false,
        .supports_strict_mode = !is_moonshot and !is_together and !is_cloudflare_ai_gateway,
        .cache_control_format = if (eql(provider, "openrouter") and std.mem.startsWith(u8, model.id, "anthropic/")) "anthropic" else null,
        .send_session_affinity_headers = false,
        .supports_long_cache_retention = !(is_together or is_cloudflare_workers_ai or is_cloudflare_ai_gateway),
    };
}

pub fn getCompat(model: types.Model) ResolvedOpenAICompletionsCompat {
    const detected = detectCompat(model);
    const compat = model.compat;
    return .{
        .supports_store = compat.supports_store orelse detected.supports_store,
        .supports_developer_role = compat.supports_developer_role orelse detected.supports_developer_role,
        .supports_reasoning_effort = compat.supports_reasoning_effort orelse detected.supports_reasoning_effort,
        .supports_usage_in_streaming = compat.supports_usage_in_streaming orelse detected.supports_usage_in_streaming,
        .max_tokens_field = compat.max_tokens_field orelse detected.max_tokens_field,
        .requires_tool_result_name = compat.requires_tool_result_name orelse detected.requires_tool_result_name,
        .requires_assistant_after_tool_result = compat.requires_assistant_after_tool_result orelse detected.requires_assistant_after_tool_result,
        .requires_thinking_as_text = compat.requires_thinking_as_text orelse detected.requires_thinking_as_text,
        .requires_reasoning_content_on_assistant_messages = compat.requires_reasoning_content_on_assistant_messages orelse detected.requires_reasoning_content_on_assistant_messages,
        .thinking_format = compat.thinking_format orelse detected.thinking_format,
        .zai_tool_stream = compat.zai_tool_stream orelse detected.zai_tool_stream,
        .supports_strict_mode = compat.supports_strict_mode orelse detected.supports_strict_mode,
        .cache_control_format = detected.cache_control_format,
        .send_session_affinity_headers = compat.send_session_affinity_headers orelse detected.send_session_affinity_headers,
        .supports_long_cache_retention = compat.supports_long_cache_retention orelse detected.supports_long_cache_retention,
    };
}

pub fn clientHeaders(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?OpenAICompletionsOptions,
    compat_override: ?ResolvedOpenAICompletionsCompat,
) !std.StringHashMap([]const u8) {
    const compat = compat_override orelse getCompat(model);
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();

    for (model.headers) |header| try headers.put(header.name, header.value);

    const retention = if (options) |opts| opts.base.cache_retention else types.CacheRetention.short;
    const session_id = if (retention == .none) null else if (options) |opts| opts.base.session_id else null;
    if (session_id) |id| {
        if (compat.send_session_affinity_headers) {
            try headers.put("session_id", id);
            try headers.put("x-client-request-id", id);
            try headers.put("x-session-affinity", id);
        }
    }

    if (options) |opts| {
        for (opts.base.headers) |header| try headers.put(header.name, header.value);
    }
    return headers;
}

const LastRole = enum {
    none,
    user,
    assistant,
    tool_result,
};

fn convertUserMessage(allocator: std.mem.Allocator, user: types.UserMessage) !?std.json.Value {
    if (user.content.len == 0) return null;
    if (user.content.len == 1 and user.content[0] == .text) {
        var message = objectValue();
        try putString(allocator, &message, "role", "user");
        try putSanitizedString(allocator, &message, "content", user.content[0].text.text);
        return .{ .object = message.object };
    }

    var content = std.json.Array.init(allocator);
    errdefer content.deinit();
    for (user.content) |item| {
        try content.append(try userContentPart(allocator, item));
    }
    if (content.items.len == 0) return null;

    var message = objectValue();
    try putString(allocator, &message, "role", "user");
    try putValue(allocator, &message, "content", .{ .array = content });
    return .{ .object = message.object };
}

fn convertAssistantMessage(
    allocator: std.mem.Allocator,
    model: types.Model,
    compat: ResolvedOpenAICompletionsCompat,
    assistant: types.AssistantMessage,
) !?std.json.Value {
    var message = objectValue();
    try putString(allocator, &message, "role", "assistant");

    var text_parts = std.json.Array.init(allocator);
    errdefer text_parts.deinit();
    var assistant_text = std.ArrayList(u8).empty;
    defer assistant_text.deinit(allocator);
    var thinking_blocks = std.ArrayList(types.ThinkingContent).empty;
    defer thinking_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    for (assistant.content) |block| switch (block) {
        .text => |text| {
            if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
            var part = objectValue();
            try putString(allocator, &part, "type", "text");
            const sanitized = try sanitize_unicode.sanitizeSurrogates(allocator, text.text);
            try putOwnedString(allocator, &part, "text", sanitized);
            try text_parts.append(.{ .object = part.object });
            try assistant_text.appendSlice(allocator, sanitized);
        },
        .thinking => |thinking| {
            if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len > 0) {
                try thinking_blocks.append(allocator, thinking);
            }
        },
        .tool_call => |tool_call| try tool_calls.append(allocator, tool_call),
    };

    if (thinking_blocks.items.len > 0) {
        if (compat.requires_thinking_as_text) {
            var content = std.json.Array.init(allocator);
            errdefer content.deinit();
            var index: usize = 0;
            while (index < thinking_blocks.items.len) : (index += 1) {
                if (index > 0) {
                    var separator = objectValue();
                    try putString(allocator, &separator, "type", "text");
                    try putString(allocator, &separator, "text", "\n\n");
                    try content.append(.{ .object = separator.object });
                }
                var part = objectValue();
                try putString(allocator, &part, "type", "text");
                try putSanitizedString(allocator, &part, "text", thinking_blocks.items[index].thinking);
                try content.append(.{ .object = part.object });
            }
            for (text_parts.items) |part| try content.append(part);
            try putValue(allocator, &message, "content", .{ .array = content });
        } else {
            if (assistant_text.items.len > 0) {
                try putOwnedString(allocator, &message, "content", try allocator.dupe(u8, assistant_text.items));
            } else {
                try putNull(allocator, &message, "content");
            }
            var signature = thinking_blocks.items[0].thinking_signature;
            if (eql(model.provider, "opencode-go") and signature != null and eql(signature.?, "reasoning")) {
                signature = "reasoning_content";
            }
            if (signature) |field| {
                if (field.len > 0) {
                    var joined = std.ArrayList(u8).empty;
                    errdefer joined.deinit(allocator);
                    for (thinking_blocks.items, 0..) |thinking, index| {
                        if (index > 0) try joined.append(allocator, '\n');
                        try joined.appendSlice(allocator, thinking.thinking);
                    }
                    try putOwnedString(allocator, &message, field, try joined.toOwnedSlice(allocator));
                }
            }
        }
    } else if (assistant_text.items.len > 0) {
        try putOwnedString(allocator, &message, "content", try allocator.dupe(u8, assistant_text.items));
    } else {
        if (compat.requires_assistant_after_tool_result) {
            try putString(allocator, &message, "content", "");
        } else {
            try putNull(allocator, &message, "content");
        }
    }

    if (tool_calls.items.len > 0) {
        var tool_call_values = std.json.Array.init(allocator);
        errdefer tool_call_values.deinit();
        var reasoning_details = std.json.Array.init(allocator);
        errdefer reasoning_details.deinit();
        for (tool_calls.items) |tool_call| {
            var call = objectValue();
            try putString(allocator, &call, "id", tool_call.id);
            try putString(allocator, &call, "type", "function");

            var function = objectValue();
            try putString(allocator, &function, "name", tool_call.name);
            try putString(allocator, &function, "arguments", tool_call.arguments_json);
            try putValue(allocator, &call, "function", function);
            try tool_call_values.append(.{ .object = call.object });

            if (tool_call.thought_signature) |signature| {
                if (std.json.parseFromSlice(std.json.Value, allocator, signature, .{})) |parsed| {
                    defer parsed.deinit();
                    try reasoning_details.append(try cloneJsonValue(allocator, parsed.value));
                } else |_| {}
            }
        }
        try putValue(allocator, &message, "tool_calls", .{ .array = tool_call_values });
        if (reasoning_details.items.len > 0) {
            try putValue(allocator, &message, "reasoning_details", .{ .array = reasoning_details });
        } else {
            reasoning_details.deinit();
        }
    }

    if (compat.requires_reasoning_content_on_assistant_messages and model.reasoning and message.object.get("reasoning_content") == null) {
        try putString(allocator, &message, "reasoning_content", "");
    }

    const content = message.object.get("content");
    const has_content = if (content) |value| switch (value) {
        .string => |text| text.len > 0,
        .array => |array| array.items.len > 0,
        .null => false,
        else => true,
    } else false;
    if (!has_content and message.object.get("tool_calls") == null) return null;
    return .{ .object = message.object };
}

fn convertToolResultMessage(
    allocator: std.mem.Allocator,
    tool_result: types.ToolResultMessage,
    compat: ResolvedOpenAICompletionsCompat,
    supports_images: bool,
    image_blocks: *std.json.Array,
) !std.json.Value {
    var text_result = std.ArrayList(u8).empty;
    defer text_result.deinit(allocator);
    for (tool_result.content) |block| switch (block) {
        .text => |text| {
            if (text_result.items.len > 0) try text_result.append(allocator, '\n');
            try text_result.appendSlice(allocator, text.text);
        },
        .image => |image| {
            if (supports_images) try image_blocks.append(try imageContentPart(allocator, image));
        },
    };

    var message = objectValue();
    try putString(allocator, &message, "role", "tool");
    if (text_result.items.len > 0) {
        try putSanitizedString(allocator, &message, "content", text_result.items);
    } else {
        try putString(allocator, &message, "content", "(see attached image)");
    }
    try putString(allocator, &message, "tool_call_id", tool_result.tool_call_id);
    if (compat.requires_tool_result_name and tool_result.tool_name.len > 0) {
        try putString(allocator, &message, "name", tool_result.tool_name);
    }
    return .{ .object = message.object };
}

fn appendAssistantBridge(allocator: std.mem.Allocator, result: *std.json.Array) !void {
    var message = objectValue();
    try putString(allocator, &message, "role", "assistant");
    try putString(allocator, &message, "content", "I have processed the tool results.");
    try result.append(.{ .object = message.object });
}

fn userContentPart(allocator: std.mem.Allocator, item: types.UserContent) !std.json.Value {
    return switch (item) {
        .text => |text| blk: {
            var part = objectValue();
            try putString(allocator, &part, "type", "text");
            try putSanitizedString(allocator, &part, "text", text.text);
            break :blk .{ .object = part.object };
        },
        .image => |image| imageContentPart(allocator, image),
    };
}

fn imageContentPart(allocator: std.mem.Allocator, image: types.ImageContent) !std.json.Value {
    var part = objectValue();
    try putString(allocator, &part, "type", "image_url");
    var image_url = objectValue();
    const url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ image.mime_type, image.data });
    try putOwnedString(allocator, &image_url, "url", url);
    try putValue(allocator, &part, "image_url", image_url);
    return .{ .object = part.object };
}

fn hasToolHistory(messages: []const types.Message) bool {
    for (messages) |message| switch (message) {
        .tool_result => return true,
        .assistant => |assistant| {
            for (assistant.content) |content| {
                if (content == .tool_call) return true;
            }
        },
        .user => {},
    };
    return false;
}

fn getCompatCacheControl(allocator: std.mem.Allocator, compat: ResolvedOpenAICompletionsCompat, retention: types.CacheRetention) !?std.json.Value {
    if (compat.cache_control_format == null or !eql(compat.cache_control_format.?, "anthropic") or retention == .none) return null;
    var cache_control = objectValue();
    try putString(allocator, &cache_control, "type", "ephemeral");
    if (retention == .long and compat.supports_long_cache_retention) {
        try putString(allocator, &cache_control, "ttl", "1h");
    }
    return cache_control;
}

fn applyAnthropicCacheControl(
    allocator: std.mem.Allocator,
    params: *std.json.Value,
    cache_control_value: std.json.Value,
) !void {
    const messages = params.object.getPtr("messages") orelse return;
    try addCacheControlToSystemPrompt(allocator, messages, cache_control_value);

    if (params.object.getPtr("tools")) |tools| {
        if (tools.* == .array and tools.array.items.len > 0) {
            try putValue(allocator, &tools.array.items[tools.array.items.len - 1], "cache_control", try cloneJsonValue(allocator, cache_control_value));
        }
    }

    try addCacheControlToLastConversationMessage(allocator, messages, cache_control_value);
}

fn addCacheControlToSystemPrompt(
    allocator: std.mem.Allocator,
    messages: *std.json.Value,
    cache_control_value: std.json.Value,
) !void {
    if (messages.* != .array) return;
    for (messages.array.items) |*message| {
        if (message.* != .object) continue;
        const role = getStringField(message.*, "role") orelse continue;
        if (eql(role, "system") or eql(role, "developer")) {
            _ = try addCacheControlToTextContent(allocator, message, cache_control_value);
            return;
        }
    }
}

fn addCacheControlToLastConversationMessage(
    allocator: std.mem.Allocator,
    messages: *std.json.Value,
    cache_control_value: std.json.Value,
) !void {
    if (messages.* != .array) return;
    var index = messages.array.items.len;
    while (index > 0) {
        index -= 1;
        const message = &messages.array.items[index];
        if (message.* != .object) continue;
        const role = getStringField(message.*, "role") orelse continue;
        if (eql(role, "user") or eql(role, "assistant")) {
            if (try addCacheControlToTextContent(allocator, message, cache_control_value)) return;
        }
    }
}

fn addCacheControlToTextContent(
    allocator: std.mem.Allocator,
    message: *std.json.Value,
    cache_control_value: std.json.Value,
) !bool {
    const content = message.object.getPtr("content") orelse return false;
    switch (content.*) {
        .string => |text| {
            if (text.len == 0) return false;
            var content_array = std.json.Array.init(allocator);
            errdefer content_array.deinit();
            var part = objectValue();
            try putString(allocator, &part, "type", "text");
            try putString(allocator, &part, "text", text);
            try putValue(allocator, &part, "cache_control", try cloneJsonValue(allocator, cache_control_value));
            try content_array.append(.{ .object = part.object });
            content.* = .{ .array = content_array };
            return true;
        },
        .array => |*array| {
            var index = array.items.len;
            while (index > 0) {
                index -= 1;
                const part = &array.items[index];
                if (part.* != .object) continue;
                const part_type = getStringField(part.*, "type") orelse continue;
                if (eql(part_type, "text")) {
                    try putValue(allocator, part, "cache_control", try cloneJsonValue(allocator, cache_control_value));
                    return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

fn applyThinkingOptions(
    allocator: std.mem.Allocator,
    params: *std.json.Value,
    model: types.Model,
    compat: ResolvedOpenAICompletionsCompat,
    reasoning_effort: ?types.ThinkingLevel,
) !void {
    if (!model.reasoning) return;
    const mapped_effort = if (reasoning_effort) |level| thinkingLevelValue(model, level) else null;

    switch (compat.thinking_format) {
        .zai, .qwen => try putBool(allocator, params, "enable_thinking", mapped_effort != null),
        .qwen_chat_template => {
            var kwargs = objectValue();
            try putBool(allocator, &kwargs, "enable_thinking", mapped_effort != null);
            try putBool(allocator, &kwargs, "preserve_thinking", true);
            try putValue(allocator, params, "chat_template_kwargs", kwargs);
        },
        .deepseek => {
            var thinking = objectValue();
            try putString(allocator, &thinking, "type", if (mapped_effort != null) "enabled" else "disabled");
            try putValue(allocator, params, "thinking", thinking);
            if (mapped_effort) |effort| {
                if (compat.supports_reasoning_effort) try putString(allocator, params, "reasoning_effort", effort);
            }
        },
        .openrouter => {
            if (mapped_effort) |effort| {
                var reasoning = objectValue();
                try putString(allocator, &reasoning, "effort", effort);
                try putValue(allocator, params, "reasoning", reasoning);
            } else {
                switch (model.thinking_level_map.off) {
                    .unsupported => {},
                    .mapped => |effort| {
                        var reasoning = objectValue();
                        try putString(allocator, &reasoning, "effort", effort);
                        try putValue(allocator, params, "reasoning", reasoning);
                    },
                    .unset => {
                        var reasoning = objectValue();
                        try putString(allocator, &reasoning, "effort", "none");
                        try putValue(allocator, params, "reasoning", reasoning);
                    },
                }
            }
        },
        .together => {
            var reasoning = objectValue();
            try putBool(allocator, &reasoning, "enabled", mapped_effort != null);
            try putValue(allocator, params, "reasoning", reasoning);
            if (mapped_effort) |effort| {
                if (compat.supports_reasoning_effort) try putString(allocator, params, "reasoning_effort", effort);
            }
        },
        .string_thinking => {
            if (mapped_effort) |effort| {
                try putString(allocator, params, "thinking", effort);
            } else switch (model.thinking_level_map.off) {
                .unsupported => {},
                .mapped => |effort| try putString(allocator, params, "thinking", effort),
                .unset => try putString(allocator, params, "thinking", "none"),
            }
        },
        .openai => {
            if (mapped_effort) |effort| {
                if (compat.supports_reasoning_effort) try putString(allocator, params, "reasoning_effort", effort);
            } else if (compat.supports_reasoning_effort) switch (model.thinking_level_map.off) {
                .mapped => |effort| try putString(allocator, params, "reasoning_effort", effort),
                else => {},
            };
        },
    }
}

fn thinkingLevelValue(model: types.Model, level: types.ThinkingLevel) []const u8 {
    return switch (model.thinking_level_map.get(level)) {
        .mapped => |value| value,
        else => thinkingLevelName(level),
    };
}

fn thinkingLevelName(level: types.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn toolChoiceValue(allocator: std.mem.Allocator, choice: ToolChoice) !std.json.Value {
    return switch (choice) {
        .auto => .{ .string = "auto" },
        .none => .{ .string = "none" },
        .required => .{ .string = "required" },
        .function_name => |name| blk: {
            var root = objectValue();
            try putString(allocator, &root, "type", "function");
            var function = objectValue();
            try putString(allocator, &function, "name", name);
            try putValue(allocator, &root, "function", function);
            break :blk root;
        },
    };
}

fn modelWithLongRetention(model: types.Model, compat: ResolvedOpenAICompletionsCompat) types.Model {
    var copy = model;
    copy.compat.supports_long_cache_retention = compat.supports_long_cache_retention;
    return copy;
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

fn emptyArray(allocator: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(allocator) };
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

fn putInteger(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: u64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .integer = std.math.cast(i64, value) orelse std.math.maxInt(i64) });
}

fn putFloat(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: f64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .float = value });
}

fn getStringField(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return if (nested == .string) nested.string else null;
}

fn getNestedStringField(value: std.json.Value, object_field: []const u8, string_field: []const u8) ?[]const u8 {
    const nested = getObjectField(value, object_field) orelse return null;
    return getStringField(nested, string_field);
}

fn getObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return if (nested == .object) nested else null;
}

fn getUnsignedField(value: std.json.Value, field: []const u8) ?u64 {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return unsignedFromValue(nested);
}

fn unsignedFromValue(value: std.json.Value) ?u64 {
    return switch (value) {
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

fn isAborted(options: types.StreamOptions) bool {
    return if (options.signal) |signal| signal.aborted else false;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn expectJsonEqual(actual: std.json.Value, expected_json: []const u8) !void {
    const allocator = std.testing.allocator;
    var expected = try std.json.parseFromSlice(std.json.Value, allocator, expected_json, .{});
    defer expected.deinit();
    const expected_string = try std.json.Stringify.valueAlloc(allocator, expected.value, .{});
    defer allocator.free(expected_string);
    const actual_string = try std.json.Stringify.valueAlloc(allocator, actual, .{});
    defer allocator.free(actual_string);
    try std.testing.expectEqualStrings(expected_string, actual_string);
}

const full_compat: ResolvedOpenAICompletionsCompat = .{
    .supports_store = true,
    .supports_developer_role = true,
    .supports_reasoning_effort = true,
    .supports_usage_in_streaming = true,
    .max_tokens_field = .max_completion_tokens,
    .requires_tool_result_name = false,
    .requires_assistant_after_tool_result = false,
    .requires_thinking_as_text = false,
    .requires_reasoning_content_on_assistant_messages = false,
    .thinking_format = .openai,
    .zai_tool_stream = false,
    .supports_strict_mode = true,
    .cache_control_format = "anthropic",
    .send_session_affinity_headers = false,
    .supports_long_cache_retention = true,
};

fn emptyUsage() types.Usage {
    return .{};
}

// Ported from packages/ai/test/openai-completions-tool-result-images.test.ts.
test "OpenAI completions batches tool-result images after consecutive tool results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const base = (models.getModel("openai", "gpt-4o-mini") orelse return error.ModelMissing).*;
    var model = base;
    model.api = types.api.openai_completions;
    model.input = &.{ "text", "image" };

    const user_content = [_]types.UserContent{.{ .text = .{ .text = "Read the images" } }};
    const assistant_content = [_]types.AssistantContent{
        .{ .tool_call = .{ .id = "tool-1", .name = "read", .arguments_json = "{\"path\":\"img-1.png\"}" } },
        .{ .tool_call = .{ .id = "tool-2", .name = "read", .arguments_json = "{\"path\":\"img-2.png\"}" } },
    };
    const tool_content = [_]types.UserContent{
        .{ .text = .{ .text = "Read image file [image/png]" } },
        .{ .image = .{ .data = "ZmFrZQ==", .mime_type = "image/png" } },
    };
    const messages = [_]types.Message{
        .{ .user = .{ .content = &user_content } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = emptyUsage(),
            .stop_reason = .tool_use,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tool-1",
            .tool_name = "read",
            .content = &tool_content,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tool-2",
            .tool_name = "read",
            .content = &tool_content,
        } },
    };
    const context: types.Context = .{ .messages = &messages };

    const converted = try convertMessagesValue(allocator, model, context, full_compat);

    try std.testing.expectEqual(@as(usize, 5), converted.array.items.len);
    try std.testing.expectEqualStrings("user", getStringField(converted.array.items[0], "role").?);
    try std.testing.expectEqualStrings("assistant", getStringField(converted.array.items[1], "role").?);
    try std.testing.expectEqualStrings("tool", getStringField(converted.array.items[2], "role").?);
    try std.testing.expectEqualStrings("tool", getStringField(converted.array.items[3], "role").?);
    try std.testing.expectEqualStrings("user", getStringField(converted.array.items[4], "role").?);
    const image_message = converted.array.items[4].object.get("content").?.array;
    var image_parts: usize = 0;
    for (image_message.items) |part| {
        if (std.mem.eql(u8, getStringField(part, "type") orelse "", "image_url")) image_parts += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), image_parts);
}

// Ported from packages/ai/test/openai-completions-empty-tools.test.ts.
test "OpenAI completions omits empty tools but keeps tools array for tool history" {
    const allocator = std.testing.allocator;
    var model = (models.getModel("openai", "gpt-4o-mini") orelse return error.ModelMissing).*;
    model.api = types.api.openai_completions;
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hi" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const context: types.Context = .{ .messages = &messages, .tools = &.{} };

    var params = try buildParams(allocator, model, context, null, full_compat, null);
    defer params.deinit();
    try std.testing.expect(params.value.object.get("tools") == null);
    try std.testing.expect(params.value.object.get("max_tokens") == null);
    try std.testing.expect(params.value.object.get("max_completion_tokens") == null);

    const assistant_content = [_]types.AssistantContent{.{ .tool_call = .{ .id = "t1", .name = "noop" } }};
    const tool_content = [_]types.UserContent{.{ .text = .{ .text = "done" } }};
    const history = [_]types.Message{
        .{ .user = .{ .content = &user_content } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = emptyUsage(),
            .stop_reason = .tool_use,
        } },
        .{ .tool_result = .{ .tool_call_id = "t1", .tool_name = "noop", .content = &tool_content } },
    };
    var with_history = try buildParams(allocator, model, .{ .messages = &history, .tools = &.{} }, null, full_compat, null);
    defer with_history.deinit();
    try std.testing.expectEqual(@as(usize, 0), with_history.value.object.get("tools").?.array.items.len);
}

// Ported from packages/ai/test/openai-completions-empty-tools.test.ts.
test "OpenAI completions sends explicit max tokens with provider field preference" {
    const allocator = std.testing.allocator;
    var model = (models.getModel("openai", "gpt-4o-mini") orelse return error.ModelMissing).*;
    model.api = types.api.openai_completions;
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hi" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const context: types.Context = .{ .messages = &messages };

    var params = try buildParams(allocator, model, context, .{ .base = .{ .max_tokens = 1234 } }, full_compat, null);
    defer params.deinit();
    try std.testing.expect(params.value.object.get("max_tokens") == null);
    try std.testing.expectEqual(@as(i64, 1234), params.value.object.get("max_completion_tokens").?.integer);

    var max_tokens_compat = full_compat;
    max_tokens_compat.max_tokens_field = .max_tokens;
    var proxy_params = try buildParams(allocator, model, context, .{ .base = .{ .max_tokens = 99 } }, max_tokens_compat, null);
    defer proxy_params.deinit();
    try std.testing.expectEqual(@as(i64, 99), proxy_params.value.object.get("max_tokens").?.integer);
    try std.testing.expect(proxy_params.value.object.get("max_completion_tokens") == null);
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts.
test "OpenAI completions forwards tool choice and strict tool compatibility" {
    const allocator = std.testing.allocator;
    var model = (models.getModel("openai", "gpt-4o-mini") orelse return error.ModelMissing).*;
    model.api = types.api.openai_completions;
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "Call ping with ok=true" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const tools = [_]types.Tool{.{ .name = "ping", .description = "Ping tool", .parameters_json = "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}}}" }};
    const context: types.Context = .{ .messages = &messages, .tools = &tools };

    var params = try buildParams(allocator, model, context, .{ .tool_choice = .required }, full_compat, null);
    defer params.deinit();
    try std.testing.expectEqualStrings("required", params.value.object.get("tool_choice").?.string);
    try std.testing.expectEqual(@as(usize, 1), params.value.object.get("tools").?.array.items.len);
    const tool_fn = params.value.object.get("tools").?.array.items[0].object.get("function").?.object;
    try std.testing.expectEqual(false, tool_fn.get("strict").?.bool);

    var no_strict = full_compat;
    no_strict.supports_strict_mode = false;
    var no_strict_params = try buildParams(allocator, model, context, null, no_strict, null);
    defer no_strict_params.deinit();
    const no_strict_fn = no_strict_params.value.object.get("tools").?.array.items[0].object.get("function").?.object;
    try std.testing.expect(no_strict_fn.get("strict") == null);
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts.
test "OpenAI completions maps reasoning effort and z.ai tool stream compat" {
    const allocator = std.testing.allocator;
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "Hi" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const tools = [_]types.Tool{.{ .name = "ping", .description = "Ping tool", .parameters_json = "{\"type\":\"object\"}" }};

    const groq_qwen = (models.getModel("groq", "qwen/qwen3-32b") orelse return error.ModelMissing).*;
    var qwen_params = try buildParams(allocator, groq_qwen, .{ .messages = &messages }, .{ .reasoning_effort = models.clampThinkingLevel(groq_qwen, .medium) }, null, null);
    defer qwen_params.deinit();
    try std.testing.expectEqualStrings("default", qwen_params.value.object.get("reasoning_effort").?.string);

    const groq_gpt_oss = (models.getModel("groq", "openai/gpt-oss-20b") orelse return error.ModelMissing).*;
    var gpt_params = try buildParams(allocator, groq_gpt_oss, .{ .messages = &messages }, .{ .reasoning_effort = .medium }, null, null);
    defer gpt_params.deinit();
    try std.testing.expectEqualStrings("medium", gpt_params.value.object.get("reasoning_effort").?.string);

    const zai_supported = (models.getModel("zai", "glm-5.1") orelse return error.ModelMissing).*;
    var zai_params = try buildParams(allocator, zai_supported, .{ .messages = &messages, .tools = &tools }, null, null, null);
    defer zai_params.deinit();
    try std.testing.expectEqual(true, zai_params.value.object.get("tool_stream").?.bool);

    const zai_unsupported = (models.getModel("zai", "glm-4.5-air") orelse return error.ModelMissing).*;
    var no_stream = try buildParams(allocator, zai_unsupported, .{ .messages = &messages, .tools = &tools }, null, null, null);
    defer no_stream.deinit();
    try std.testing.expect(no_stream.value.object.get("tool_stream") == null);
}

// Ported from packages/ai/test/openai-completions-cache-control-format.test.ts.
test "OpenAI completions applies Anthropic-style cache markers" {
    const allocator = std.testing.allocator;
    var model = (models.getModel("openrouter", "anthropic/claude-sonnet-4") orelse return error.ModelMissing).*;
    model.api = types.api.openai_completions;
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "Hello" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const tools = [_]types.Tool{.{ .name = "read", .description = "Read a file", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}" }};
    const context: types.Context = .{ .system_prompt = "System prompt", .messages = &messages, .tools = &tools };

    var params = try buildParams(allocator, model, context, null, null, null);
    defer params.deinit();

    const instruction = params.value.object.get("messages").?.array.items[0];
    try std.testing.expectEqualStrings("system", getStringField(instruction, "role").?);
    try std.testing.expectEqualStrings("ephemeral", instruction.object.get("content").?.array.items[0].object.get("cache_control").?.object.get("type").?.string);

    const tool = params.value.object.get("tools").?.array.items[0];
    try std.testing.expectEqualStrings("ephemeral", tool.object.get("cache_control").?.object.get("type").?.string);

    const last = params.value.object.get("messages").?.array.items[1];
    try std.testing.expectEqualStrings("ephemeral", last.object.get("content").?.array.items[0].object.get("cache_control").?.object.get("type").?.string);

    var none_params = try buildParams(allocator, model, context, .{ .base = .{ .cache_retention = .none } }, null, null);
    defer none_params.deinit();
    try std.testing.expect(none_params.value.object.get("messages").?.array.items[0].object.get("content").? == .string);
    try std.testing.expect(none_params.value.object.get("tools").?.array.items[0].object.get("cache_control") == null);
}

// Ported from packages/ai/test/openai-completions-prompt-cache.test.ts.
test "OpenAI completions prompt cache fields and session affinity headers" {
    const allocator = std.testing.allocator;
    var model = (models.getModel("openai", "gpt-4o-mini") orelse return error.ModelMissing).*;
    model.api = types.api.openai_completions;
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hi" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const context: types.Context = .{ .system_prompt = "sys", .messages = &messages };

    var direct = try buildParams(allocator, model, context, .{ .base = .{ .session_id = "session-123" } }, null, null);
    defer direct.deinit();
    try std.testing.expectEqualStrings("session-123", direct.value.object.get("prompt_cache_key").?.string);
    try std.testing.expect(direct.value.object.get("prompt_cache_retention") == null);

    var long = try buildParams(allocator, model, context, .{ .base = .{ .cache_retention = .long, .session_id = "session-456" } }, null, null);
    defer long.deinit();
    try std.testing.expectEqualStrings("24h", long.value.object.get("prompt_cache_retention").?.string);

    var none = try buildParams(allocator, model, context, .{ .base = .{ .cache_retention = .none, .session_id = "session-789" } }, null, null);
    defer none.deinit();
    try std.testing.expect(none.value.object.get("prompt_cache_key") == null);
    try std.testing.expect(none.value.object.get("prompt_cache_retention") == null);

    var proxy = model;
    proxy.base_url = "https://proxy.example.com/v1";
    proxy.compat.supports_long_cache_retention = false;
    var proxy_params = try buildParams(allocator, proxy, context, .{ .base = .{ .cache_retention = .long, .session_id = "session-proxy" } }, null, null);
    defer proxy_params.deinit();
    try std.testing.expect(proxy_params.value.object.get("prompt_cache_key") == null);

    var affinity_model = proxy;
    affinity_model.compat.send_session_affinity_headers = true;
    affinity_model.compat.supports_long_cache_retention = true;
    const override_headers = [_]types.Header{.{ .name = "session_id", .value = "override-session" }};
    var headers = try clientHeaders(allocator, affinity_model, .{ .base = .{
        .session_id = "session-affinity",
        .headers = &override_headers,
    } }, null);
    defer headers.deinit();
    try std.testing.expectEqualStrings("override-session", headers.get("session_id").?);
    try std.testing.expectEqualStrings("session-affinity", headers.get("x-client-request-id").?);
    try std.testing.expectEqualStrings("session-affinity", headers.get("x-session-affinity").?);
}

// Ported from packages/ai/test/openai-completions-thinking-as-text.test.ts.
test "OpenAI completions serializes thinking replay as assistant text parts when required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var compat = full_compat;
    compat.cache_control_format = null;
    compat.requires_thinking_as_text = true;

    const model: types.Model = .{
        .id = "repro-model",
        .name = "Repro Model",
        .api = types.api.openai_completions,
        .provider = "repro-provider",
        .base_url = "http://127.0.0.1:1",
        .reasoning = true,
        .input = &.{"text"},
    };
    const user_one = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
    const assistant_content = [_]types.AssistantContent{
        .{ .thinking = .{ .thinking = "internal reasoning" } },
        .{ .text = .{ .text = "visible answer" } },
    };
    const user_two = [_]types.UserContent{.{ .text = .{ .text = "continue" } }};
    const messages = [_]types.Message{
        .{ .user = .{ .content = &user_one } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = types.api.openai_completions,
            .provider = "repro-provider",
            .model = "repro-model",
            .usage = emptyUsage(),
        } },
        .{ .user = .{ .content = &user_two } },
    };

    const converted = try convertMessagesValue(allocator, model, .{ .messages = &messages }, compat);
    const assistant = converted.array.items[1];
    try expectJsonEqual(assistant,
        \\{"role":"assistant","content":[{"type":"text","text":"internal reasoning"},{"type":"text","text":"visible answer"}]}
    );
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts.
test "OpenAI completions stream parser ignores null chunks and maps usage" {
    const model = openAICompletionsTestModel();
    const chunks = [_]?[]const u8{
        null,
        \\{"id":"chatcmpl-test","choices":[{"delta":{"content":"OK"},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-test","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}
        ,
    };

    var parsed = try parseStreamChunks(std.testing.allocator, model, &chunks, .{});
    defer parsed.deinit();

    const message = parsed.result.message;
    try std.testing.expectEqual(types.StopReason.stop, message.stop_reason);
    try std.testing.expect(message.error_message == null);
    try std.testing.expectEqualStrings("chatcmpl-test", message.response_id.?);
    try std.testing.expectEqual(@as(u64, 4), message.usage.total_tokens);
    try std.testing.expectEqual(@as(usize, 1), message.content.len);
    try std.testing.expectEqualStrings("OK", message.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .text_start));
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .text_delta));
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .text_end));
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .done));
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts.
test "OpenAI completions stream parser surfaces provider finish errors and truncated streams" {
    const model = openAICompletionsTestModel();
    const network_error_chunks = [_]?[]const u8{
        \\{"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}
        ,
        \\{"choices":[{"delta":{},"finish_reason":"network_error"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}
        ,
    };

    var network_error = try parseStreamChunks(std.testing.allocator, model, &network_error_chunks, .{});
    defer network_error.deinit();
    try std.testing.expectEqual(types.StopReason.@"error", network_error.result.message.stop_reason);
    try std.testing.expectEqualStrings("Provider finish_reason: network_error", network_error.result.message.error_message.?);
    try std.testing.expectEqualStrings("partial", network_error.result.message.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), countEvents(network_error.result.events.items, .@"error"));

    const truncated_chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-truncated","choices":[{"delta":{"content":"partial answer"},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-truncated","choices":[{"delta":{"content":"partial answer"},"finish_reason":null}]}
        ,
    };
    var truncated = try parseStreamChunks(std.testing.allocator, model, &truncated_chunks, .{});
    defer truncated.deinit();
    try std.testing.expectEqual(types.StopReason.@"error", truncated.result.message.stop_reason);
    try std.testing.expectEqualStrings("Stream ended without finish_reason", truncated.result.message.error_message.?);
    try std.testing.expectEqualStrings("partial answerpartial answer", truncated.result.message.content[0].text.text);
}

// Ported from packages/ai/test/openai-completions-response-model.test.ts.
test "OpenAI completions stream parser exposes routed response model" {
    const model: types.Model = .{
        .id = "openrouter/auto",
        .name = "OpenRouter Auto",
        .api = types.api.openai_completions,
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .reasoning = false,
        .input = &.{"text"},
        .context_window = 200_000,
        .max_tokens = 8192,
    };
    const chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-1","model":"anthropic/claude-opus-4.8","choices":[{"index":0,"delta":{"content":"hi"}}]}
        ,
        \\{"id":"chatcmpl-1","model":"anthropic/claude-opus-4.8","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}
        ,
    };

    var parsed = try parseStreamChunks(std.testing.allocator, model, &chunks, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("openrouter/auto", parsed.result.message.model);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.8", parsed.result.message.response_model.?);
    try std.testing.expectEqualStrings("openrouter", parsed.result.message.provider);
    try std.testing.expectEqual(types.StopReason.stop, parsed.result.message.stop_reason);
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts and
// packages/ai/test/openrouter-cache-write-repro.test.ts.
test "OpenAI completions stream parser preserves cache write usage" {
    const model = openAICompletionsTestModel();
    const chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-cache-write","choices":[{"delta":{"content":"OK"},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-cache-write","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":50,"cache_write_tokens":30},"completion_tokens_details":{"reasoning_tokens":0}}}
        ,
    };

    var parsed = try parseStreamChunks(std.testing.allocator, model, &chunks, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u64, 20), parsed.result.message.usage.input);
    try std.testing.expectEqual(@as(u64, 5), parsed.result.message.usage.output);
    try std.testing.expectEqual(@as(u64, 50), parsed.result.message.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 30), parsed.result.message.usage.cache_write);
    try std.testing.expectEqual(@as(u64, 105), parsed.result.message.usage.total_tokens);
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts.
test "OpenAI completions stream parser coalesces mutating tool-call ids by stable index" {
    const model = openAICompletionsTestModel();
    const chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-kimi-bad-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"functions.read:0","type":"function","function":{"name":"read","arguments":""}}]},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-kimi-bad-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"chatcmpl-tool-a","type":"function","function":{"name":null,"arguments":"{\"path\":\"README"}}]},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-kimi-bad-stream","choices":[{"delta":{"tool_calls":[{"index":0,"id":"chatcmpl-tool-b","type":"function","function":{"name":null,"arguments":".md\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}
        ,
    };

    var parsed = try parseStreamChunks(std.testing.allocator, model, &chunks, .{});
    defer parsed.deinit();

    const message = parsed.result.message;
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), message.content.len);
    const tool_call = message.content[0].tool_call;
    try std.testing.expectEqualStrings("functions.read:0", tool_call.id);
    try std.testing.expectEqualStrings("read", tool_call.name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", tool_call.arguments_json);
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .toolcall_start));
    try std.testing.expectEqual(@as(usize, 3), countEvents(parsed.result.events.items, .toolcall_delta));
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .toolcall_end));
    for (parsed.result.events.items) |event| {
        switch (event) {
            .toolcall_start => |item| try std.testing.expectEqual(@as(usize, 0), item.content_index),
            .toolcall_delta => |item| try std.testing.expectEqual(@as(usize, 0), item.content_index),
            .toolcall_end => |item| try std.testing.expectEqual(@as(usize, 0), item.content_index),
            else => {},
        }
    }
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts.
test "OpenAI completions stream parser accumulates mixed text reasoning and parallel tools" {
    const model = openAICompletionsTestModel();
    const chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-mixed-deltas","choices":[{"delta":{"content":"answer 1","reasoning_content":"think 1","tool_calls":[{"index":0,"id":"tc_read_initial","type":"function","function":{"name":"read","arguments":"{\"path\":\"README"}},{"index":1,"id":"tc_grep_initial","type":"function","function":{"name":"grep","arguments":"{\"pattern\":\"TODO"}},{"id":"tc_list_no_index","type":"function","function":{"name":"list","arguments":"{\"path\":\"packages"}},{"id":"tc_write_no_index","type":"function","function":{"name":"write","arguments":"{\"path\":\"out"}}]},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-mixed-deltas","choices":[{"delta":{"content":" answer 2","tool_calls":[{"index":1,"id":"tc_grep_changed","type":"function","function":{"arguments":"\",\"path\":\"src"}},{"id":"tc_write_no_index","type":"function","function":{"arguments":".txt\",\"content\":\"ok\"}"}},{"id":"tc_list_no_index","type":"function","function":{"arguments":"/ai\"}"}}]},"finish_reason":null}]}
        ,
        \\{"id":"chatcmpl-mixed-deltas","choices":[{"delta":{"content":"\n","reasoning_content":" think 2","tool_calls":[{"index":0,"id":"tc_read_changed","type":"function","function":{"arguments":".md\"}"}},{"index":1,"type":"function","function":{"arguments":"\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":8,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":2}}}
        ,
    };

    var parsed = try parseStreamChunks(std.testing.allocator, model, &chunks, .{});
    defer parsed.deinit();

    const message = parsed.result.message;
    try std.testing.expectEqual(types.StopReason.tool_use, message.stop_reason);
    try std.testing.expectEqual(@as(usize, 6), message.content.len);
    try std.testing.expectEqualStrings("answer 1 answer 2\n", message.content[0].text.text);
    try std.testing.expectEqualStrings("think 1 think 2", message.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("reasoning_content", message.content[1].thinking.thinking_signature.?);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", message.content[2].tool_call.arguments_json);
    try std.testing.expectEqualStrings("{\"pattern\":\"TODO\",\"path\":\"src\"}", message.content[3].tool_call.arguments_json);
    try std.testing.expectEqualStrings("{\"path\":\"packages/ai\"}", message.content[4].tool_call.arguments_json);
    try std.testing.expectEqualStrings("{\"path\":\"out.txt\",\"content\":\"ok\"}", message.content[5].tool_call.arguments_json);
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .text_start));
    try std.testing.expectEqual(@as(usize, 3), countEvents(parsed.result.events.items, .text_delta));
    try std.testing.expectEqual(@as(usize, 1), countEvents(parsed.result.events.items, .thinking_start));
    try std.testing.expectEqual(@as(usize, 2), countEvents(parsed.result.events.items, .thinking_delta));
    try std.testing.expectEqual(@as(usize, 4), countEvents(parsed.result.events.items, .toolcall_start));
    try std.testing.expectEqual(@as(usize, 9), countEvents(parsed.result.events.items, .toolcall_delta));
    try std.testing.expectEqual(@as(usize, 4), countEvents(parsed.result.events.items, .toolcall_end));
}

// Ported from packages/ai/test/openai-completions-tool-choice.test.ts.
test "OpenAI completions stream parser records reasoning signatures" {
    var opencode = (models.getModel("opencode-go", "kimi-k2.6") orelse return error.ModelMissing).*;
    opencode.api = types.api.openai_completions;
    const opencode_chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-opencode-go-reasoning","choices":[{"delta":{"reasoning":"think"},"finish_reason":"stop"}]}
        ,
    };
    var opencode_parsed = try parseStreamChunks(std.testing.allocator, opencode, &opencode_chunks, .{});
    defer opencode_parsed.deinit();
    try std.testing.expectEqualStrings("think", opencode_parsed.result.message.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("reasoning_content", opencode_parsed.result.message.content[0].thinking.thinking_signature.?);

    const openai = openAICompletionsTestModel();
    const openai_chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-reasoning","choices":[{"delta":{"reasoning":"think"},"finish_reason":"stop"}]}
        ,
    };
    var openai_parsed = try parseStreamChunks(std.testing.allocator, openai, &openai_chunks, .{});
    defer openai_parsed.deinit();
    try std.testing.expectEqualStrings("reasoning", openai_parsed.result.message.content[0].thinking.thinking_signature.?);
}

test "OpenAI completions stream parser attaches encrypted reasoning details to matching tool calls" {
    const model = openAICompletionsTestModel();
    const chunks = [_]?[]const u8{
        \\{"id":"chatcmpl-reasoning-details","choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read","arguments":"{\"path\":\"README.md\"}"}}],"reasoning_details":[{"type":"reasoning.encrypted","id":"call_1","data":"sealed"}]},"finish_reason":"tool_calls"}]}
        ,
    };

    var parsed = try parseStreamChunks(std.testing.allocator, model, &chunks, .{});
    defer parsed.deinit();

    const signature = parsed.result.message.content[0].tool_call.thought_signature.?;
    var signature_json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, signature, .{});
    defer signature_json.deinit();
    try std.testing.expectEqualStrings("reasoning.encrypted", signature_json.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", signature_json.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("sealed", signature_json.value.object.get("data").?.string);
}

fn openAICompletionsTestModel() types.Model {
    var model = (models.getModel("openai", "gpt-4o-mini") orelse unreachable).*;
    model.api = types.api.openai_completions;
    return model;
}

fn countEvents(events: []const types.StreamEvent, comptime tag: std.meta.Tag(types.StreamEvent)) usize {
    var count: usize = 0;
    for (events) |event| {
        if (std.meta.activeTag(event) == tag) count += 1;
    }
    return count;
}
