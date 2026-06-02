const std = @import("std");
const api_registry = @import("api_registry.zig");
const types = @import("types.zig");

const default_api = "faux";
const default_provider = "faux";
const default_model_id = "faux-1";
const default_model_name = "Faux Model";
const default_base_url = "http://localhost:0";
const default_min_token_size = 3;
const default_max_token_size = 5;

pub const ModelDefinition = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    reasoning: bool = false,
    input: []const []const u8 = &types.default_model_input,
    cost: types.ModelCost = .{},
    context_window: u64 = 128_000,
    max_tokens: u64 = 16_384,
};

pub const Options = struct {
    api: []const u8 = default_api,
    provider: []const u8 = default_provider,
    models: []const ModelDefinition = &.{},
    min_token_size: usize = default_min_token_size,
    max_token_size: usize = default_max_token_size,
};

pub const State = struct {
    call_count: usize = 0,
};

pub const ResponseFactory = *const fn (
    context: types.Context,
    options: types.StreamOptions,
    state: State,
    model: types.Model,
) anyerror!types.AssistantMessage;

pub const ResponseStep = union(enum) {
    message: types.AssistantMessage,
    factory: ResponseFactory,
};

pub const FauxProvider = struct {
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    models: std.ArrayList(types.Model) = .empty,
    responses: std.ArrayList(ResponseStep) = .empty,
    next_response: usize = 0,
    state: State = .{},
    prompt_cache: std.StringHashMap([]u8),
    min_token_size: usize,
    max_token_size: usize,
    active: bool = true,
    registry: ?*api_registry.Registry = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) !FauxProvider {
        var result: FauxProvider = .{
            .allocator = allocator,
            .api = options.api,
            .provider = options.provider,
            .prompt_cache = .init(allocator),
            .min_token_size = @max(1, @min(options.min_token_size, options.max_token_size)),
            .max_token_size = @max(1, options.max_token_size),
        };
        errdefer result.deinit();

        if (options.models.len == 0) {
            try result.models.append(allocator, modelFromDefinition(options.api, options.provider, .{
                .id = default_model_id,
                .name = default_model_name,
            }));
        } else {
            for (options.models) |definition| {
                try result.models.append(allocator, modelFromDefinition(options.api, options.provider, definition));
            }
        }

        return result;
    }

    pub fn deinit(self: *FauxProvider) void {
        var keys = self.prompt_cache.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        var values = self.prompt_cache.valueIterator();
        while (values.next()) |value| self.allocator.free(value.*);
        self.prompt_cache.deinit();
        self.responses.deinit(self.allocator);
        self.models.deinit(self.allocator);
    }

    pub fn getModel(self: *const FauxProvider, model_id: ?[]const u8) ?*const types.Model {
        if (model_id == null) return &self.models.items[0];
        for (self.models.items) |*model| {
            if (std.mem.eql(u8, model.id, model_id.?)) return model;
        }
        return null;
    }

    pub fn setResponses(self: *FauxProvider, responses: []const ResponseStep) !void {
        self.responses.clearRetainingCapacity();
        try self.responses.appendSlice(self.allocator, responses);
        self.next_response = 0;
    }

    pub fn appendResponses(self: *FauxProvider, responses: []const ResponseStep) !void {
        try self.responses.appendSlice(self.allocator, responses);
    }

    pub fn pendingResponseCount(self: FauxProvider) usize {
        return self.responses.items.len - self.next_response;
    }

    pub fn unregister(self: *FauxProvider) void {
        if (self.registry) |registry| registry.unregister(self.api);
        self.registry = null;
        self.active = false;
    }

    pub fn register(self: *FauxProvider, registry: *api_registry.Registry) !void {
        self.active = true;
        self.registry = registry;
        try registry.register(.{
            .api = self.api,
            .context = self,
            .complete_fn = completeAdapter,
            .stream_fn = streamAdapter,
        });
    }

    pub fn complete(
        self: *FauxProvider,
        model: types.Model,
        context: types.Context,
        options: types.StreamOptions,
    ) !types.AssistantMessage {
        if (!self.active) return error.ProviderUnregistered;

        const step = self.nextResponse();
        var message = if (step) |response|
            self.resolveResponse(response, context, options, model)
        else
            emptyErrorMessage("No more faux responses queued");

        message.api = self.api;
        message.provider = self.provider;
        message.model = model.id;
        message.usage = try self.estimateUsage(message, context, options);
        return message;
    }

    pub fn stream(
        self: *FauxProvider,
        model: types.Model,
        context: types.Context,
        options: types.StreamOptions,
    ) !types.StreamResult {
        const message = try self.complete(model, context, options);
        var result: types.StreamResult = .{
            .allocator = self.allocator,
            .message = message,
        };
        errdefer result.deinit();

        if (isAborted(options)) {
            try emitAborted(&result, options, message);
            return result;
        }
        try emit(&result, options, .{ .start = {} });

        for (message.content, 0..) |block, index| {
            if (isAborted(options)) {
                try emitAborted(&result, options, message);
                return result;
            }

            switch (block) {
                .thinking => |thinking| {
                    try emit(&result, options, .{ .thinking_start = .{ .content_index = index } });
                    if (try emitTextDeltas(&result, options, .thinking_delta, index, thinking.thinking, self.min_token_size)) {
                        return result;
                    }
                    try emit(&result, options, .{
                        .thinking_end = .{
                            .content_index = index,
                            .content = thinking.thinking,
                        },
                    });
                },
                .text => |text| {
                    try emit(&result, options, .{ .text_start = .{ .content_index = index } });
                    if (try emitTextDeltas(&result, options, .text_delta, index, text.text, self.min_token_size)) {
                        return result;
                    }
                    try emit(&result, options, .{
                        .text_end = .{
                            .content_index = index,
                            .content = text.text,
                        },
                    });
                },
                .tool_call => |tool_call| {
                    try emit(&result, options, .{ .toolcall_start = .{ .content_index = index } });
                    if (try emitTextDeltas(
                        &result,
                        options,
                        .toolcall_delta,
                        index,
                        tool_call.arguments_json,
                        self.min_token_size,
                    )) {
                        return result;
                    }
                    try emit(&result, options, .{
                        .toolcall_end = .{
                            .content_index = index,
                            .tool_call = tool_call,
                        },
                    });
                },
            }
        }

        if (message.stop_reason == .@"error" or message.stop_reason == .aborted) {
            try emit(&result, options, .{
                .@"error" = .{
                    .reason = message.stop_reason,
                    .message = message,
                },
            });
        } else {
            try emit(&result, options, .{ .done = message.stop_reason });
        }
        return result;
    }

    fn nextResponse(self: *FauxProvider) ?ResponseStep {
        self.state.call_count += 1;
        if (self.next_response >= self.responses.items.len) return null;
        defer self.next_response += 1;
        return self.responses.items[self.next_response];
    }

    fn resolveResponse(
        self: *FauxProvider,
        step: ResponseStep,
        context: types.Context,
        options: types.StreamOptions,
        model: types.Model,
    ) types.AssistantMessage {
        return switch (step) {
            .message => |message| message,
            .factory => |factory| factory(context, options, self.state, model) catch |err| emptyErrorMessage(@errorName(err)),
        };
    }

    fn estimateUsage(
        self: *FauxProvider,
        message: types.AssistantMessage,
        context: types.Context,
        options: types.StreamOptions,
    ) !types.Usage {
        const prompt_text = try serializeContext(self.allocator, context);
        defer self.allocator.free(prompt_text);

        const prompt_tokens = estimateTokens(prompt_text);
        const output_tokens = estimateAssistantTokens(message.content);
        var usage: types.Usage = .{
            .input = prompt_tokens,
            .output = output_tokens,
        };

        if (options.session_id) |session_id| {
            if (options.cache_retention != .none) {
                if (self.prompt_cache.get(session_id)) |previous_prompt| {
                    const cached_chars = commonPrefixLength(previous_prompt, prompt_text);
                    usage.cache_read = estimateTokens(previous_prompt[0..cached_chars]);
                    usage.cache_write = estimateTokens(prompt_text[cached_chars..]);
                    usage.input -|= usage.cache_read;
                } else {
                    usage.cache_write = prompt_tokens;
                }
                try self.cachePrompt(session_id, prompt_text);
            }
        }

        usage.calculateTotalTokens();
        return usage;
    }

    fn cachePrompt(self: *FauxProvider, session_id: []const u8, prompt_text: []const u8) !void {
        const new_prompt = try self.allocator.dupe(u8, prompt_text);
        errdefer self.allocator.free(new_prompt);

        if (self.prompt_cache.getPtr(session_id)) |existing| {
            self.allocator.free(existing.*);
            existing.* = new_prompt;
            return;
        }

        const key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(key);
        try self.prompt_cache.put(key, new_prompt);
    }
};

fn modelFromDefinition(api_name: []const u8, provider: []const u8, definition: ModelDefinition) types.Model {
    return .{
        .id = definition.id,
        .name = definition.name orelse definition.id,
        .api = api_name,
        .provider = provider,
        .base_url = default_base_url,
        .input = definition.input,
        .cost = definition.cost,
        .context_window = definition.context_window,
        .max_tokens = definition.max_tokens,
        .reasoning = definition.reasoning,
    };
}

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
        .api = default_api,
        .provider = default_provider,
        .model = default_model_id,
        .stop_reason = stop_reason,
    };
}

fn emptyErrorMessage(message: []const u8) types.AssistantMessage {
    return .{
        .content = &.{},
        .api = default_api,
        .provider = default_provider,
        .model = default_model_id,
        .stop_reason = .@"error",
        .error_message = message,
    };
}

fn estimateTokens(text: []const u8) u64 {
    return @intCast((text.len + 3) / 4);
}

fn estimateAssistantTokens(content: []const types.AssistantContent) u64 {
    var bytes: usize = 0;
    for (content, 0..) |block, index| {
        if (index > 0) bytes += 1;
        bytes += switch (block) {
            .text => |text| text.text.len,
            .thinking => |thinking| thinking.thinking.len,
            .tool_call => |tool_call| tool_call.name.len + 1 + tool_call.arguments_json.len,
        };
    }
    return @intCast((bytes + 3) / 4);
}

fn serializeContext(allocator: std.mem.Allocator, context: types.Context) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    if (context.system_prompt) |system_prompt| {
        try result.appendSlice(allocator, "system:");
        try result.appendSlice(allocator, system_prompt);
    }

    for (context.messages) |message| {
        if (result.items.len > 0) try result.appendSlice(allocator, "\n\n");
        switch (message) {
            .user => |user| {
                try result.appendSlice(allocator, "user:");
                try appendUserContent(allocator, &result, user.content);
            },
            .assistant => |assistant| {
                try result.appendSlice(allocator, "assistant:");
                try appendAssistantContent(allocator, &result, assistant.content);
            },
            .tool_result => |tool_result| {
                try result.appendSlice(allocator, "toolResult:");
                try result.appendSlice(allocator, tool_result.tool_name);
                if (tool_result.content.len > 0) try result.append(allocator, '\n');
                try appendUserContent(allocator, &result, tool_result.content);
            },
        }
    }

    if (context.tools.len > 0) {
        if (result.items.len > 0) try result.appendSlice(allocator, "\n\n");
        try result.appendSlice(allocator, "tools:[");
        for (context.tools, 0..) |tool, index| {
            if (index > 0) try result.append(allocator, ',');
            try result.appendSlice(allocator, tool.parameters_json);
        }
        try result.append(allocator, ']');
    }

    return result.toOwnedSlice(allocator);
}

fn appendUserContent(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    content: []const types.UserContent,
) !void {
    for (content, 0..) |block, index| {
        if (index > 0) try result.append(allocator, '\n');
        switch (block) {
            .text => |text| try result.appendSlice(allocator, text.text),
            .image => |image| try result.print(allocator, "[image:{s}:{d}]", .{ image.mime_type, image.data.len }),
        }
    }
}

fn appendAssistantContent(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    content: []const types.AssistantContent,
) !void {
    for (content, 0..) |block, index| {
        if (index > 0) try result.append(allocator, '\n');
        switch (block) {
            .text => |text| try result.appendSlice(allocator, text.text),
            .thinking => |thinking| try result.appendSlice(allocator, thinking.thinking),
            .tool_call => |tool_call| try result.print(allocator, "{s}:{s}", .{ tool_call.name, tool_call.arguments_json }),
        }
    }
}

fn commonPrefixLength(a: []const u8, b: []const u8) usize {
    const length = @min(a.len, b.len);
    var index: usize = 0;
    while (index < length and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn isAborted(options: types.StreamOptions) bool {
    return if (options.signal) |signal| signal.aborted else false;
}

fn emit(result: *types.StreamResult, options: types.StreamOptions, event: types.StreamEvent) !void {
    try result.events.append(result.allocator, event);
    if (options.signal) |signal| {
        if (options.on_event) |observer| observer(signal, event);
    }
}

fn emitAborted(
    result: *types.StreamResult,
    options: types.StreamOptions,
    original: types.AssistantMessage,
) !void {
    var aborted = original;
    aborted.stop_reason = .aborted;
    aborted.error_message = "Request was aborted";
    result.message = aborted;
    try emit(result, options, .{
        .@"error" = .{
            .reason = .aborted,
            .message = aborted,
        },
    });
}

fn emitTextDeltas(
    result: *types.StreamResult,
    options: types.StreamOptions,
    comptime event_tag: std.meta.Tag(types.StreamEvent),
    content_index: usize,
    text: []const u8,
    token_size: usize,
) !bool {
    const chunk_size = @max(1, token_size * 4);
    var index: usize = 0;
    while (index < text.len) : (index += chunk_size) {
        if (isAborted(options)) {
            try emitAborted(result, options, result.message);
            return true;
        }
        const end = @min(text.len, index + chunk_size);
        const delta: types.ContentDelta = .{
            .content_index = content_index,
            .delta = text[index..end],
        };
        try emit(result, options, @unionInit(types.StreamEvent, @tagName(event_tag), delta));
    }
    if (isAborted(options)) {
        try emitAborted(result, options, result.message);
        return true;
    }
    return false;
}

fn completeAdapter(
    context: *anyopaque,
    model: types.Model,
    prompt: types.Context,
    options: types.StreamOptions,
) !types.AssistantMessage {
    const provider: *FauxProvider = @ptrCast(@alignCast(context));
    return provider.complete(model, prompt, options);
}

fn streamAdapter(
    context: *anyopaque,
    model: types.Model,
    prompt: types.Context,
    options: types.StreamOptions,
) !types.StreamResult {
    const provider: *FauxProvider = @ptrCast(@alignCast(context));
    return provider.stream(model, prompt, options);
}

fn eventTags(
    allocator: std.mem.Allocator,
    events: []const types.StreamEvent,
) ![]std.meta.Tag(types.StreamEvent) {
    const result = try allocator.alloc(std.meta.Tag(types.StreamEvent), events.len);
    for (events, 0..) |event, index| result[index] = std.meta.activeTag(event);
    return result;
}

fn messageStep(message: types.AssistantMessage) ResponseStep {
    return .{ .message = message };
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider registers a custom provider and estimates usage" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const content = [_]types.AssistantContent{fauxText("hello world")};
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(&content, .stop))};
    try provider.setResponses(&responses);

    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hi there" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const response = try provider.complete(provider.getModel(null).?.*, .{
        .system_prompt = "Be concise.",
        .messages = &messages,
    }, .{});

    try std.testing.expect(response.usage.input > 0);
    try std.testing.expect(response.usage.output > 0);
    try std.testing.expectEqual(response.usage.input + response.usage.output, response.usage.total_tokens);
    try std.testing.expectEqual(@as(usize, 1), provider.state.call_count);
}

// Ported from packages/ai/test/faux-provider.test.ts.
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

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider supports multiple models and rewrites returned metadata" {
    const allocator = std.testing.allocator;
    const definitions = [_]ModelDefinition{
        .{ .id = "faux-fast", .name = "Faux Fast" },
        .{ .id = "faux-thinker", .name = "Faux Thinker", .reasoning = true },
    };
    var provider = try FauxProvider.init(allocator, .{
        .api = "faux:test",
        .provider = "faux-provider",
        .models = &definitions,
    });
    defer provider.deinit();

    const content = [_]types.AssistantContent{fauxText("hello")};
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(&content, .stop))};
    try provider.setResponses(&responses);

    try std.testing.expectEqualStrings("faux-fast", provider.getModel(null).?.id);
    try std.testing.expect(!provider.getModel("faux-fast").?.reasoning);
    try std.testing.expect(provider.getModel("faux-thinker").?.reasoning);

    const response = try provider.complete(provider.getModel("faux-thinker").?.*, .{ .messages = &.{} }, .{});
    try std.testing.expectEqualStrings("faux:test", response.api);
    try std.testing.expectEqualStrings("faux-provider", response.provider);
    try std.testing.expectEqualStrings("faux-thinker", response.model);
}

const fast_factory_content = [_]types.AssistantContent{fauxText("faux-fast:false")};
const thinker_factory_content = [_]types.AssistantContent{fauxText("faux-thinker:true")};

fn modelAwareFactory(
    _: types.Context,
    _: types.StreamOptions,
    _: State,
    model: types.Model,
) !types.AssistantMessage {
    if (std.mem.eql(u8, model.id, "faux-thinker")) {
        return fauxAssistantMessage(&thinker_factory_content, .stop);
    }
    return fauxAssistantMessage(&fast_factory_content, .stop);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider factories receive the requested model" {
    const allocator = std.testing.allocator;
    const definitions = [_]ModelDefinition{
        .{ .id = "faux-fast" },
        .{ .id = "faux-thinker", .reasoning = true },
    };
    var provider = try FauxProvider.init(allocator, .{ .models = &definitions });
    defer provider.deinit();
    const responses = [_]ResponseStep{
        .{ .factory = modelAwareFactory },
        .{ .factory = modelAwareFactory },
    };
    try provider.setResponses(&responses);

    const fast = try provider.complete(provider.getModel("faux-fast").?.*, .{ .messages = &.{} }, .{});
    const thinker = try provider.complete(provider.getModel("faux-thinker").?.*, .{ .messages = &.{} }, .{});
    try std.testing.expectEqualStrings("faux-fast:false", fast.content[0].text.text);
    try std.testing.expectEqualStrings("faux-thinker:true", thinker.content[0].text.text);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider consumes queued responses and supports append" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const first_content = [_]types.AssistantContent{fauxText("first")};
    const second_content = [_]types.AssistantContent{fauxText("second")};
    const third_content = [_]types.AssistantContent{fauxText("third")};
    const first = [_]ResponseStep{messageStep(fauxAssistantMessage(&first_content, .stop))};
    const later = [_]ResponseStep{
        messageStep(fauxAssistantMessage(&second_content, .stop)),
        messageStep(fauxAssistantMessage(&third_content, .stop)),
    };
    try provider.setResponses(&first);
    try provider.appendResponses(&later);

    try std.testing.expectEqualStrings("first", (try provider.complete(provider.getModel(null).?.*, .{ .messages = &.{} }, .{})).content[0].text.text);
    try std.testing.expectEqualStrings("second", (try provider.complete(provider.getModel(null).?.*, .{ .messages = &.{} }, .{})).content[0].text.text);
    try std.testing.expectEqualStrings("third", (try provider.complete(provider.getModel(null).?.*, .{ .messages = &.{} }, .{})).content[0].text.text);
    const exhausted = try provider.complete(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    try std.testing.expectEqual(types.StopReason.@"error", exhausted.stop_reason);
    try std.testing.expectEqualStrings("No more faux responses queued", exhausted.error_message.?);
    try std.testing.expectEqual(@as(usize, 0), provider.pendingResponseCount());
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider can replace responses after queue consumption" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const first_content = [_]types.AssistantContent{fauxText("first")};
    const second_content = [_]types.AssistantContent{fauxText("second")};
    const first = [_]ResponseStep{messageStep(fauxAssistantMessage(&first_content, .stop))};
    const second = [_]ResponseStep{messageStep(fauxAssistantMessage(&second_content, .stop))};

    try provider.setResponses(&first);
    _ = try provider.complete(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    try std.testing.expectEqual(@as(usize, 0), provider.pendingResponseCount());
    try provider.setResponses(&second);
    try std.testing.expectEqual(@as(usize, 1), provider.pendingResponseCount());
    try std.testing.expectEqualStrings("second", (try provider.complete(provider.getModel(null).?.*, .{ .messages = &.{} }, .{})).content[0].text.text);
}

fn throwingFactory(
    _: types.Context,
    _: types.StreamOptions,
    _: State,
    _: types.Model,
) !types.AssistantMessage {
    return error.Boom;
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider converts response factory failures into assistant errors" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();
    const responses = [_]ResponseStep{.{ .factory = throwingFactory }};
    try provider.setResponses(&responses);

    const response = try provider.complete(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    try std.testing.expectEqual(types.StopReason.@"error", response.stop_reason);
    try std.testing.expectEqualStrings("Boom", response.error_message.?);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider estimates serialized context and simulates prompt caching" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const first_content = [_]types.AssistantContent{fauxText("first")};
    const second_content = [_]types.AssistantContent{fauxText("second")};
    const responses = [_]ResponseStep{
        messageStep(fauxAssistantMessage(&first_content, .stop)),
        messageStep(fauxAssistantMessage(&second_content, .stop)),
    };
    try provider.setResponses(&responses);

    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
    var messages = [_]types.Message{
        .{ .user = .{ .content = &user_content } },
        .{ .user = .{ .content = &user_content } },
    };
    const first = try provider.complete(provider.getModel(null).?.*, .{
        .system_prompt = "Be concise.",
        .messages = messages[0..1],
    }, .{
        .session_id = "session-1",
    });
    const second = try provider.complete(provider.getModel(null).?.*, .{
        .system_prompt = "Be concise.",
        .messages = messages[0..2],
    }, .{
        .session_id = "session-1",
    });

    try std.testing.expectEqual(@as(u64, 0), first.usage.cache_read);
    try std.testing.expect(first.usage.cache_write > 0);
    try std.testing.expect(second.usage.cache_read > 0);
    try std.testing.expect(second.usage.cache_write > 0);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider estimates prompt and output tokens from serialized context" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const output_content = [_]types.AssistantContent{fauxText("done")};
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(&output_content, .stop))};
    try provider.setResponses(&responses);

    const user_content = [_]types.UserContent{
        .{ .text = .{ .text = "hello" } },
        .{ .image = .{ .mime_type = "image/png", .data = "abcd" } },
    };
    const prior_content = [_]types.AssistantContent{fauxText("prior")};
    const tool_content = [_]types.UserContent{.{ .text = .{ .text = "tool out" } }};
    const messages = [_]types.Message{
        .{ .user = .{ .content = &user_content } },
        .{ .assistant = fauxAssistantMessage(&prior_content, .stop) },
        .{ .tool_result = .{
            .tool_call_id = "tool-1",
            .tool_name = "echo",
            .content = &tool_content,
        } },
    };
    const tools = [_]types.Tool{.{
        .name = "echo",
        .description = "Echo back text",
        .parameters_json = "{\"name\":\"echo\",\"description\":\"Echo back text\",\"parameters\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}}",
    }};
    const prompt_text = "system:sys\n\nuser:hello\n[image:image/png:4]\n\nassistant:prior\n\ntoolResult:echo\ntool out\n\ntools:[{\"name\":\"echo\",\"description\":\"Echo back text\",\"parameters\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}}]";
    const response = try provider.complete(provider.getModel(null).?.*, .{
        .system_prompt = "sys",
        .messages = &messages,
        .tools = &tools,
    }, .{});

    try std.testing.expectEqual(estimateTokens(prompt_text), response.usage.input);
    try std.testing.expectEqual(estimateTokens("done"), response.usage.output);
    try std.testing.expectEqual(response.usage.input + response.usage.output, response.usage.total_tokens);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider does not share cache across sessions or requests without session ID" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const content = [_]types.AssistantContent{fauxText("done")};
    const responses = [_]ResponseStep{
        messageStep(fauxAssistantMessage(&content, .stop)),
        messageStep(fauxAssistantMessage(&content, .stop)),
        messageStep(fauxAssistantMessage(&content, .stop)),
    };
    try provider.setResponses(&responses);
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const context: types.Context = .{ .messages = &messages };

    const first = try provider.complete(provider.getModel(null).?.*, context, .{ .session_id = "session-1" });
    const second = try provider.complete(provider.getModel(null).?.*, context, .{ .session_id = "session-2" });
    const third = try provider.complete(provider.getModel(null).?.*, context, .{});
    try std.testing.expect(first.usage.cache_write > 0);
    try std.testing.expectEqual(@as(u64, 0), second.usage.cache_read);
    try std.testing.expect(second.usage.cache_write > 0);
    try std.testing.expectEqual(@as(u64, 0), third.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 0), third.usage.cache_write);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider disables caching when retention is none" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const content = [_]types.AssistantContent{fauxText("done")};
    const responses = [_]ResponseStep{
        messageStep(fauxAssistantMessage(&content, .stop)),
        messageStep(fauxAssistantMessage(&content, .stop)),
    };
    try provider.setResponses(&responses);
    const user_content = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
    const messages = [_]types.Message{.{ .user = .{ .content = &user_content } }};
    const context: types.Context = .{ .messages = &messages };
    _ = try provider.complete(provider.getModel(null).?.*, context, .{
        .session_id = "session-1",
        .cache_retention = .none,
    });
    const second = try provider.complete(provider.getModel(null).?.*, context, .{
        .session_id = "session-1",
        .cache_retention = .none,
    });

    try std.testing.expectEqual(@as(u64, 0), second.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 0), second.usage.cache_write);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider streams thinking text and partial tool call deltas" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{
        .min_token_size = 1,
        .max_token_size = 1,
    });
    defer provider.deinit();

    const content = [_]types.AssistantContent{
        fauxThinking("thinking text"),
        fauxText("answer text"),
        fauxToolCall("tool-1", "echo", "{\"text\":\"hi\",\"count\":12}"),
    };
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(&content, .tool_use))};
    try provider.setResponses(&responses);

    var result = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    defer result.deinit();
    var delta_json: std.ArrayList(u8) = .empty;
    defer delta_json.deinit(allocator);
    var tool_delta_count: usize = 0;
    for (result.events.items) |event| {
        switch (event) {
            .toolcall_delta => |delta| {
                try delta_json.appendSlice(allocator, delta.delta);
                tool_delta_count += 1;
            },
            else => {},
        }
    }

    try std.testing.expect(tool_delta_count > 1);
    try std.testing.expectEqualStrings("{\"text\":\"hi\",\"count\":12}", delta_json.items);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider streams exact event order for fixed-size chunks" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{
        .min_token_size = 1,
        .max_token_size = 1,
    });
    defer provider.deinit();

    const content = [_]types.AssistantContent{
        fauxThinking("go"),
        fauxText("ok"),
        fauxToolCall("tool-1", "echo", "{}"),
    };
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(&content, .tool_use))};
    try provider.setResponses(&responses);

    var result = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    defer result.deinit();
    const tags = try eventTags(allocator, result.events.items);
    defer allocator.free(tags);
    const expected = [_]std.meta.Tag(types.StreamEvent){
        .start,
        .thinking_start,
        .thinking_delta,
        .thinking_end,
        .text_start,
        .text_delta,
        .text_end,
        .toolcall_start,
        .toolcall_delta,
        .toolcall_end,
        .done,
    };
    try std.testing.expectEqualSlices(std.meta.Tag(types.StreamEvent), &expected, tags);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider streams multiple tool calls in one message" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const content = [_]types.AssistantContent{
        fauxToolCall("tool-1", "echo", "{\"text\":\"one\"}"),
        fauxToolCall("tool-2", "echo", "{\"text\":\"two\"}"),
    };
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(&content, .tool_use))};
    try provider.setResponses(&responses);
    var result = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    defer result.deinit();

    var starts: usize = 0;
    var ends: usize = 0;
    for (result.events.items) |event| switch (event) {
        .toolcall_start => starts += 1,
        .toolcall_end => ends += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), starts);
    try std.testing.expectEqual(@as(usize, 2), ends);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider streams explicit assistant error as terminal error" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const content = [_]types.AssistantContent{fauxText("partial")};
    var response = fauxAssistantMessage(&content, .@"error");
    response.error_message = "upstream failed";
    const responses = [_]ResponseStep{messageStep(response)};
    try provider.setResponses(&responses);

    var result = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    defer result.deinit();
    try std.testing.expectEqual(std.meta.Tag(types.StreamEvent).@"error", std.meta.activeTag(result.events.getLast()));
    try std.testing.expectEqualStrings("upstream failed", result.message.error_message.?);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider streams explicit assistant aborted message as terminal error" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();

    const content = [_]types.AssistantContent{fauxText("partial")};
    var response = fauxAssistantMessage(&content, .aborted);
    response.error_message = "Request was aborted";
    const responses = [_]ResponseStep{messageStep(response)};
    try provider.setResponses(&responses);

    var result = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{});
    defer result.deinit();
    try std.testing.expectEqual(std.meta.Tag(types.StreamEvent).@"error", std.meta.activeTag(result.events.getLast()));
    try std.testing.expectEqual(types.StopReason.aborted, result.message.stop_reason);
}

fn abortAfterFirstDelta(signal: *types.AbortSignal, event: types.StreamEvent) void {
    switch (event) {
        .text_delta, .thinking_delta, .toolcall_delta => signal.abort(),
        else => {},
    }
}

fn runMidStreamAbortTest(content: []const types.AssistantContent, expected_delta: std.meta.Tag(types.StreamEvent), forbidden_end: std.meta.Tag(types.StreamEvent)) !void {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{
        .min_token_size = 1,
        .max_token_size = 1,
    });
    defer provider.deinit();
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(content, .tool_use))};
    try provider.setResponses(&responses);

    var signal: types.AbortSignal = .{};
    var result = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{
        .signal = &signal,
        .on_event = abortAfterFirstDelta,
    });
    defer result.deinit();
    const tags = try eventTags(allocator, result.events.items);
    defer allocator.free(tags);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(types.StreamEvent), tags, expected_delta) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(types.StreamEvent), tags, .@"error") != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(types.StreamEvent), tags, forbidden_end) == null);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider supports aborting mid-thinking and mid-tool-call streams" {
    const thinking = [_]types.AssistantContent{fauxThinking("abcdefghijklmnopqrstuvwxyz")};
    const tool_call = [_]types.AssistantContent{fauxToolCall("tool-1", "echo", "{\"text\":\"abcdefghijklmnopqrstuvwxyz\",\"count\":123456789}")};
    try runMidStreamAbortTest(&thinking, .thinking_delta, .thinking_end);
    try runMidStreamAbortTest(&tool_call, .toolcall_delta, .toolcall_end);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider supports aborting before and during streams" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{
        .min_token_size = 1,
        .max_token_size = 1,
    });
    defer provider.deinit();

    const content = [_]types.AssistantContent{fauxText("abcdefghijklmnopqrstuvwxyz")};
    const responses = [_]ResponseStep{
        messageStep(fauxAssistantMessage(&content, .stop)),
        messageStep(fauxAssistantMessage(&content, .stop)),
    };
    try provider.setResponses(&responses);

    var before: types.AbortSignal = .{ .aborted = true };
    var aborted_before = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{
        .signal = &before,
    });
    defer aborted_before.deinit();
    try std.testing.expectEqual(@as(usize, 1), aborted_before.events.items.len);
    try std.testing.expectEqual(std.meta.Tag(types.StreamEvent).@"error", std.meta.activeTag(aborted_before.events.items[0]));

    var during: types.AbortSignal = .{};
    var aborted_during = try provider.stream(provider.getModel(null).?.*, .{ .messages = &.{} }, .{
        .signal = &during,
        .on_event = abortAfterFirstDelta,
    });
    defer aborted_during.deinit();
    const tags = try eventTags(allocator, aborted_during.events.items);
    defer allocator.free(tags);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(types.StreamEvent), tags, .text_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(types.StreamEvent), tags, .text_delta) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(types.StreamEvent), tags, .@"error") != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(types.StreamEvent), tags, .text_end) == null);
}

// Ported from packages/ai/test/faux-provider.test.ts.
test "faux provider registers and unregisters generic API dispatch" {
    const allocator = std.testing.allocator;
    var provider = try FauxProvider.init(allocator, .{});
    defer provider.deinit();
    var registry = api_registry.Registry.init(allocator);
    defer registry.deinit();

    const content = [_]types.AssistantContent{fauxText("hello")};
    const responses = [_]ResponseStep{messageStep(fauxAssistantMessage(&content, .stop))};
    try provider.setResponses(&responses);
    try provider.register(&registry);

    const model = provider.getModel(null).?.*;
    try std.testing.expectEqualStrings("hello", (try registry.complete(model, .{ .messages = &.{} }, .{})).content[0].text.text);

    try provider.appendResponses(&responses);
    var stream_result = try registry.stream(model, .{ .messages = &.{} }, .{});
    defer stream_result.deinit();
    try std.testing.expectEqual(std.meta.Tag(types.StreamEvent).done, std.meta.activeTag(stream_result.events.getLast()));

    provider.unregister();

    try std.testing.expectError(
        error.ApiProviderNotRegistered,
        registry.complete(model, .{ .messages = &.{} }, .{}),
    );
}
