const std = @import("std");
const ai = @import("bulb_ai");

const json_parse = ai.json_parse;
const sse = ai.sse;

pub const ProxyError = error{
    InvalidProxyEvent,
    UnexpectedProxyContent,
};

pub const ProxyHttpRequest = struct {
    url: []const u8,
    payload_json: []const u8,
    headers: []const ai.Header,
    timeout_ms: ?u64 = null,
};

pub const ProxyHttpResponse = struct {
    arena: std.heap.ArenaAllocator,
    status: u16,
    status_text: []const u8,
    body: []const u8,

    pub fn deinit(self: *ProxyHttpResponse) void {
        self.arena.deinit();
    }
};

pub const ProxyTransportFn = *const fn (
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: ProxyHttpRequest,
) anyerror!ProxyHttpResponse;

pub const ProxyTransport = struct {
    ptr: *anyopaque,
    request: ProxyTransportFn,

    pub fn send(
        self: ProxyTransport,
        allocator: std.mem.Allocator,
        request: ProxyHttpRequest,
    ) !ProxyHttpResponse {
        return self.request(self.ptr, allocator, request);
    }
};

pub const ProxyStreamOptions = struct {
    base: ai.StreamOptions = .{},
    auth_token: []const u8,
    proxy_url: []const u8,
    reasoning: ?ai.ThinkingLevel = null,
    thinking_budgets: ?ai.ThinkingBudgets = null,
    transport: ?ProxyTransport = null,
};

pub fn streamProxy(
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    options: ProxyStreamOptions,
) !ai.StreamResult {
    if (isAborted(options.base)) {
        return terminalResultAlloc(allocator, model, .aborted, "Request was aborted");
    }

    const payload_json = try buildProxyPayloadJson(allocator, model, context, options);
    defer allocator.free(payload_json);

    const request_url = try proxyStreamUrl(allocator, options.proxy_url);
    defer allocator.free(request_url);

    const request_headers = [_]ai.Header{
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{options.auth_token}) },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "text/event-stream" },
    };
    defer allocator.free(@constCast(request_headers[0].value));

    var std_transport_state: StdProxyTransport = .{};
    const default_transport: ProxyTransport = .{
        .ptr = &std_transport_state,
        .request = stdProxyTransportRequest,
    };
    const transport = options.transport orelse default_transport;

    var response = transport.send(allocator, .{
        .url = request_url,
        .payload_json = payload_json,
        .headers = &request_headers,
        .timeout_ms = options.base.timeout_ms,
    }) catch |err| {
        return terminalResultAlloc(allocator, model, if (isAborted(options.base)) .aborted else .@"error", @errorName(err));
    };
    defer response.deinit();

    if (isAborted(options.base)) {
        return terminalResultAlloc(allocator, model, .aborted, "Request was aborted");
    }

    if (!isSuccessStatus(response.status)) {
        const message = try proxyErrorMessage(allocator, response);
        defer allocator.free(message);
        return terminalResultAlloc(allocator, model, .@"error", message);
    }

    return parseProxySseResponseWithOptions(allocator, model, response.body, options.base);
}

pub fn buildProxyPayloadJson(
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    options: ProxyStreamOptions,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var payload = objectValue();
    try putValue(a, &payload, "model", try modelValue(a, model));
    try putValue(a, &payload, "context", try contextValue(a, context));
    try putValue(a, &payload, "options", try optionsValue(a, options));
    return stringifyJsonValue(allocator, payload);
}

pub fn parseProxySseResponse(
    allocator: std.mem.Allocator,
    model: ai.Model,
    body: []const u8,
) !ai.StreamResult {
    return parseProxySseResponseWithOptions(allocator, model, body, .{});
}

fn parseProxySseResponseWithOptions(
    allocator: std.mem.Allocator,
    model: ai.Model,
    body: []const u8,
    options: ai.StreamOptions,
) !ai.StreamResult {
    var decoded = try sse.decodeAll(allocator, body);
    defer decoded.deinit();

    var builder = ProxyPartialBuilder.init(allocator, model);
    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = builder.message(),
    };
    errdefer result.deinit();

    for (decoded.events) |event| {
        const data = std.mem.trim(u8, event.data, " \t\r\n");
        if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();
        try processProxyEvent(allocator, parsed.value, &builder, &result.events, options);
    }

    result.message = builder.message();
    return result;
}

pub fn proxyStreamUrl(allocator: std.mem.Allocator, proxy_url: []const u8) ![]u8 {
    const trimmed = trimRightBytes(proxy_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/api/stream", .{trimmed});
}

const ProxyPartialBuilder = struct {
    allocator: std.mem.Allocator,
    model: ai.Model,
    content: std.ArrayList(ai.AssistantContent) = .empty,
    tool_partial_json: std.ArrayList([]u8) = .empty,
    usage: ai.Usage = .{},
    stop_reason: ai.StopReason = .stop,
    error_message: ?[]const u8 = null,
    timestamp_ms: i64,

    fn init(allocator: std.mem.Allocator, model: ai.Model) ProxyPartialBuilder {
        return .{
            .allocator = allocator,
            .model = model,
            .timestamp_ms = currentTimestampMs(),
        };
    }

    fn message(self: *ProxyPartialBuilder) ai.AssistantMessage {
        return .{
            .content = self.content.items,
            .api = self.model.api,
            .provider = self.model.provider,
            .model = self.model.id,
            .usage = self.usage,
            .stop_reason = self.stop_reason,
            .error_message = self.error_message,
            .timestamp_ms = self.timestamp_ms,
        };
    }

    fn ensureSlot(self: *ProxyPartialBuilder, index: usize) !void {
        while (self.content.items.len <= index) {
            try self.content.append(self.allocator, .{ .text = .{ .text = "" } });
        }
        while (self.tool_partial_json.items.len <= index) {
            try self.tool_partial_json.append(self.allocator, "");
        }
    }

    fn setText(self: *ProxyPartialBuilder, index: usize, text: []const u8, signature: ?[]const u8) !void {
        try self.ensureSlot(index);
        self.content.items[index] = .{ .text = .{
            .text = try self.allocator.dupe(u8, text),
            .text_signature = if (signature) |value| try self.allocator.dupe(u8, value) else null,
        } };
    }

    fn appendText(self: *ProxyPartialBuilder, index: usize, delta: []const u8) !void {
        try self.ensureSlot(index);
        const current = switch (self.content.items[index]) {
            .text => |text| text.text,
            else => return error.UnexpectedProxyContent,
        };
        try self.setText(index, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current, delta }), null);
    }

    fn setThinking(self: *ProxyPartialBuilder, index: usize, thinking: []const u8, signature: ?[]const u8) !void {
        try self.ensureSlot(index);
        self.content.items[index] = .{ .thinking = .{
            .thinking = try self.allocator.dupe(u8, thinking),
            .thinking_signature = if (signature) |value| try self.allocator.dupe(u8, value) else null,
            .redacted = false,
        } };
    }

    fn appendThinking(self: *ProxyPartialBuilder, index: usize, delta: []const u8) !void {
        try self.ensureSlot(index);
        const current = switch (self.content.items[index]) {
            .thinking => |thinking| thinking.thinking,
            else => return error.UnexpectedProxyContent,
        };
        try self.setThinking(index, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current, delta }), null);
    }

    fn setToolCall(self: *ProxyPartialBuilder, index: usize, id: []const u8, name: []const u8, arguments_json: []const u8) !void {
        try self.ensureSlot(index);
        self.content.items[index] = .{ .tool_call = .{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .arguments_json = try self.allocator.dupe(u8, arguments_json),
        } };
    }

    fn appendToolCallDelta(self: *ProxyPartialBuilder, index: usize, delta: []const u8) !void {
        try self.ensureSlot(index);
        const current = switch (self.content.items[index]) {
            .tool_call => |tool_call| tool_call,
            else => return error.UnexpectedProxyContent,
        };
        const next_partial = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.tool_partial_json.items[index], delta });
        self.tool_partial_json.items[index] = next_partial;
        const arguments_json = try parsedStreamingJsonString(self.allocator, next_partial);
        try self.setToolCall(index, current.id, current.name, arguments_json);
    }

    fn finishToolCall(self: *ProxyPartialBuilder, index: usize) !ai.ToolCall {
        try self.ensureSlot(index);
        const current = switch (self.content.items[index]) {
            .tool_call => |tool_call| tool_call,
            else => return error.UnexpectedProxyContent,
        };
        const arguments_json = try parsedStreamingJsonString(self.allocator, self.tool_partial_json.items[index]);
        try self.setToolCall(index, current.id, current.name, arguments_json);
        return self.content.items[index].tool_call;
    }
};

fn processProxyEvent(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    builder: *ProxyPartialBuilder,
    events: *std.ArrayList(ai.StreamEvent),
    options: ai.StreamOptions,
) !void {
    const event_type = getStringField(value, "type") orelse return error.InvalidProxyEvent;

    if (eql(event_type, "start")) {
        try emit(allocator, builder, events, options, .{ .start = {} });
        return;
    }

    if (eql(event_type, "text_start")) {
        const index = try requiredIndex(value);
        try builder.setText(index, "", null);
        try emit(allocator, builder, events, options, .{ .text_start = .{ .content_index = index } });
        return;
    }
    if (eql(event_type, "text_delta")) {
        const index = try requiredIndex(value);
        const delta = getStringField(value, "delta") orelse return error.InvalidProxyEvent;
        try builder.appendText(index, delta);
        try emit(allocator, builder, events, options, .{ .text_delta = .{ .content_index = index, .delta = try allocator.dupe(u8, delta) } });
        return;
    }
    if (eql(event_type, "text_end")) {
        const index = try requiredIndex(value);
        const current = switch (builder.content.items[index]) {
            .text => |text| text.text,
            else => return error.UnexpectedProxyContent,
        };
        try builder.setText(index, current, getStringField(value, "contentSignature"));
        const text = builder.content.items[index].text.text;
        try emit(allocator, builder, events, options, .{ .text_end = .{ .content_index = index, .content = text } });
        return;
    }

    if (eql(event_type, "thinking_start")) {
        const index = try requiredIndex(value);
        try builder.setThinking(index, "", null);
        try emit(allocator, builder, events, options, .{ .thinking_start = .{ .content_index = index } });
        return;
    }
    if (eql(event_type, "thinking_delta")) {
        const index = try requiredIndex(value);
        const delta = getStringField(value, "delta") orelse return error.InvalidProxyEvent;
        try builder.appendThinking(index, delta);
        try emit(allocator, builder, events, options, .{ .thinking_delta = .{ .content_index = index, .delta = try allocator.dupe(u8, delta) } });
        return;
    }
    if (eql(event_type, "thinking_end")) {
        const index = try requiredIndex(value);
        const current = switch (builder.content.items[index]) {
            .thinking => |thinking| thinking.thinking,
            else => return error.UnexpectedProxyContent,
        };
        try builder.setThinking(index, current, getStringField(value, "contentSignature"));
        const thinking = builder.content.items[index].thinking.thinking;
        try emit(allocator, builder, events, options, .{ .thinking_end = .{ .content_index = index, .content = thinking } });
        return;
    }

    if (eql(event_type, "toolcall_start")) {
        const index = try requiredIndex(value);
        const id = getStringField(value, "id") orelse return error.InvalidProxyEvent;
        const name = getStringField(value, "toolName") orelse return error.InvalidProxyEvent;
        try builder.setToolCall(index, id, name, "{}");
        try emit(allocator, builder, events, options, .{ .toolcall_start = .{ .content_index = index } });
        return;
    }
    if (eql(event_type, "toolcall_delta")) {
        const index = try requiredIndex(value);
        const delta = getStringField(value, "delta") orelse return error.InvalidProxyEvent;
        try builder.appendToolCallDelta(index, delta);
        try emit(allocator, builder, events, options, .{ .toolcall_delta = .{ .content_index = index, .delta = try allocator.dupe(u8, delta) } });
        return;
    }
    if (eql(event_type, "toolcall_end")) {
        const index = try requiredIndex(value);
        const tool_call = builder.finishToolCall(index) catch |err| switch (err) {
            error.UnexpectedProxyContent => return,
            else => return err,
        };
        try emit(allocator, builder, events, options, .{ .toolcall_end = .{ .content_index = index, .tool_call = tool_call } });
        return;
    }

    if (eql(event_type, "done")) {
        builder.stop_reason = parseStopReason(getStringField(value, "reason") orelse "stop") orelse return error.InvalidProxyEvent;
        if (getObjectField(value, "usage")) |usage| builder.usage = parseUsage(usage);
        try emit(allocator, builder, events, options, .{ .done = builder.stop_reason });
        return;
    }

    if (eql(event_type, "error")) {
        builder.stop_reason = parseStopReason(getStringField(value, "reason") orelse "error") orelse .@"error";
        if (getStringField(value, "errorMessage")) |message| builder.error_message = try allocator.dupe(u8, message);
        if (getObjectField(value, "usage")) |usage| builder.usage = parseUsage(usage);
        try emit(allocator, builder, events, options, .{ .@"error" = .{ .reason = builder.stop_reason, .message = builder.message() } });
        return;
    }
}

fn emit(
    allocator: std.mem.Allocator,
    builder: *ProxyPartialBuilder,
    events: *std.ArrayList(ai.StreamEvent),
    options: ai.StreamOptions,
    event: ai.StreamEvent,
) !void {
    try events.append(allocator, event);
    _ = builder;
    if (options.signal) |signal| {
        if (options.on_event) |observer| observer(signal, event);
    }
}

fn modelValue(allocator: std.mem.Allocator, model: ai.Model) !std.json.Value {
    var object = objectValue();
    try putString(allocator, &object, "id", model.id);
    try putString(allocator, &object, "name", model.name);
    try putString(allocator, &object, "api", model.api);
    try putString(allocator, &object, "provider", model.provider);
    try putString(allocator, &object, "baseUrl", model.base_url);
    try putBool(allocator, &object, "reasoning", model.reasoning);
    try putValue(allocator, &object, "thinkingLevelMap", try thinkingLevelMapValue(allocator, model.thinking_level_map));
    try putValue(allocator, &object, "input", try stringArrayValue(allocator, model.input));
    try putValue(allocator, &object, "cost", try modelCostValue(allocator, model.cost));
    try putInteger(allocator, &object, "contextWindow", model.context_window);
    try putInteger(allocator, &object, "maxTokens", model.max_tokens);
    if (model.headers.len > 0) try putValue(allocator, &object, "headers", try headersObjectValue(allocator, model.headers));
    if (compatHasValues(model.compat)) try putValue(allocator, &object, "compat", try compatValue(allocator, model.compat));
    return object;
}

fn contextValue(allocator: std.mem.Allocator, context: ai.Context) !std.json.Value {
    var object = objectValue();
    if (context.system_prompt) |prompt| try putString(allocator, &object, "systemPrompt", prompt);

    var messages = std.json.Array.init(allocator);
    for (context.messages) |message| try messages.append(try messageValue(allocator, message));
    try putValue(allocator, &object, "messages", .{ .array = messages });

    if (context.tools.len > 0) {
        var tools = std.json.Array.init(allocator);
        for (context.tools) |tool| try tools.append(try toolValue(allocator, tool));
        try putValue(allocator, &object, "tools", .{ .array = tools });
    }
    return object;
}

fn optionsValue(allocator: std.mem.Allocator, options: ProxyStreamOptions) !std.json.Value {
    var object = objectValue();
    const base = options.base;
    if (base.temperature) |temperature| try putFloat(allocator, &object, "temperature", temperature);
    if (base.max_tokens) |max_tokens| try putInteger(allocator, &object, "maxTokens", max_tokens);
    if (options.reasoning) |reasoning| try putString(allocator, &object, "reasoning", thinkingLevelName(reasoning));
    try putString(allocator, &object, "cacheRetention", cacheRetentionName(base.cache_retention));
    if (base.session_id) |session_id| try putString(allocator, &object, "sessionId", session_id);
    if (base.transport) |transport| try putString(allocator, &object, "transport", transportName(transport));
    if (base.headers.len > 0) try putValue(allocator, &object, "headers", try headersObjectValue(allocator, base.headers));
    if (base.metadata_json) |metadata_json| try putValue(allocator, &object, "metadata", try jsonValueOrString(allocator, metadata_json));
    if (options.thinking_budgets) |budgets| try putValue(allocator, &object, "thinkingBudgets", try thinkingBudgetsValue(allocator, budgets));
    if (base.max_retry_delay_ms) |max_retry_delay_ms| try putInteger(allocator, &object, "maxRetryDelayMs", max_retry_delay_ms);
    return object;
}

fn messageValue(allocator: std.mem.Allocator, message: ai.Message) !std.json.Value {
    return switch (message) {
        .user => |user| try userMessageValue(allocator, user),
        .assistant => |assistant| try assistantMessageValue(allocator, assistant),
        .tool_result => |tool_result| try toolResultMessageValue(allocator, tool_result),
    };
}

fn userMessageValue(allocator: std.mem.Allocator, message: ai.UserMessage) !std.json.Value {
    var object = objectValue();
    try putString(allocator, &object, "role", "user");
    try putValue(allocator, &object, "content", try userContentArrayValue(allocator, message.content));
    try putInteger(allocator, &object, "timestamp", @intCast(@max(0, message.timestamp_ms)));
    return object;
}

fn assistantMessageValue(allocator: std.mem.Allocator, message: ai.AssistantMessage) !std.json.Value {
    var object = objectValue();
    try putString(allocator, &object, "role", "assistant");
    try putValue(allocator, &object, "content", try assistantContentArrayValue(allocator, message.content));
    try putString(allocator, &object, "api", message.api);
    try putString(allocator, &object, "provider", message.provider);
    try putString(allocator, &object, "model", message.model);
    if (message.response_model) |value| try putString(allocator, &object, "responseModel", value);
    if (message.response_id) |value| try putString(allocator, &object, "responseId", value);
    try putValue(allocator, &object, "usage", try usageValue(allocator, message.usage));
    try putString(allocator, &object, "stopReason", stopReasonName(message.stop_reason));
    if (message.error_message) |value| try putString(allocator, &object, "errorMessage", value);
    try putInteger(allocator, &object, "timestamp", @intCast(@max(0, message.timestamp_ms)));
    return object;
}

fn toolResultMessageValue(allocator: std.mem.Allocator, message: ai.ToolResultMessage) !std.json.Value {
    var object = objectValue();
    try putString(allocator, &object, "role", "toolResult");
    try putString(allocator, &object, "toolCallId", message.tool_call_id);
    try putString(allocator, &object, "toolName", message.tool_name);
    try putValue(allocator, &object, "content", try userContentArrayValue(allocator, message.content));
    try putBool(allocator, &object, "isError", message.is_error);
    try putInteger(allocator, &object, "timestamp", @intCast(@max(0, message.timestamp_ms)));
    return object;
}

fn userContentArrayValue(allocator: std.mem.Allocator, content: []const ai.UserContent) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (content) |item| {
        var object = objectValue();
        switch (item) {
            .text => |text| {
                try putString(allocator, &object, "type", "text");
                try putString(allocator, &object, "text", text.text);
                if (text.text_signature) |value| try putString(allocator, &object, "textSignature", value);
            },
            .image => |image| {
                try putString(allocator, &object, "type", "image");
                try putString(allocator, &object, "data", image.data);
                try putString(allocator, &object, "mimeType", image.mime_type);
            },
        }
        try array.append(object);
    }
    return .{ .array = array };
}

fn assistantContentArrayValue(allocator: std.mem.Allocator, content: []const ai.AssistantContent) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (content) |item| {
        var object = objectValue();
        switch (item) {
            .text => |text| {
                try putString(allocator, &object, "type", "text");
                try putString(allocator, &object, "text", text.text);
                if (text.text_signature) |value| try putString(allocator, &object, "textSignature", value);
            },
            .thinking => |thinking| {
                try putString(allocator, &object, "type", "thinking");
                try putString(allocator, &object, "thinking", thinking.thinking);
                if (thinking.thinking_signature) |value| try putString(allocator, &object, "thinkingSignature", value);
                if (thinking.redacted) try putBool(allocator, &object, "redacted", true);
            },
            .tool_call => |tool_call| {
                try putString(allocator, &object, "type", "toolCall");
                try putString(allocator, &object, "id", tool_call.id);
                try putString(allocator, &object, "name", tool_call.name);
                try putValue(allocator, &object, "arguments", jsonObjectValueOrEmpty(allocator, tool_call.arguments_json));
                if (tool_call.thought_signature) |value| try putString(allocator, &object, "thoughtSignature", value);
            },
        }
        try array.append(object);
    }
    return .{ .array = array };
}

fn toolValue(allocator: std.mem.Allocator, tool: ai.Tool) !std.json.Value {
    var object = objectValue();
    try putString(allocator, &object, "name", tool.name);
    try putString(allocator, &object, "description", tool.description);
    try putValue(allocator, &object, "parameters", jsonObjectValueOrEmpty(allocator, tool.parameters_json));
    return object;
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = try allocator.dupe(u8, value) });
    return .{ .array = array };
}

fn modelCostValue(allocator: std.mem.Allocator, cost: ai.ModelCost) !std.json.Value {
    var object = objectValue();
    try putFloat(allocator, &object, "input", cost.input);
    try putFloat(allocator, &object, "output", cost.output);
    try putFloat(allocator, &object, "cacheRead", cost.cache_read);
    try putFloat(allocator, &object, "cacheWrite", cost.cache_write);
    return object;
}

fn usageValue(allocator: std.mem.Allocator, usage: ai.Usage) !std.json.Value {
    var object = objectValue();
    try putInteger(allocator, &object, "input", usage.input);
    try putInteger(allocator, &object, "output", usage.output);
    try putInteger(allocator, &object, "cacheRead", usage.cache_read);
    try putInteger(allocator, &object, "cacheWrite", usage.cache_write);
    try putInteger(allocator, &object, "totalTokens", usage.total_tokens);
    var cost = objectValue();
    try putFloat(allocator, &cost, "input", usage.cost.input);
    try putFloat(allocator, &cost, "output", usage.cost.output);
    try putFloat(allocator, &cost, "cacheRead", usage.cost.cache_read);
    try putFloat(allocator, &cost, "cacheWrite", usage.cost.cache_write);
    try putFloat(allocator, &cost, "total", usage.cost.total);
    try putValue(allocator, &object, "cost", cost);
    return object;
}

fn thinkingLevelMapValue(allocator: std.mem.Allocator, map: ai.ThinkingLevelMap) !std.json.Value {
    var object = objectValue();
    try putThinkingLevelOverride(allocator, &object, "off", map.off);
    try putThinkingLevelOverride(allocator, &object, "minimal", map.minimal);
    try putThinkingLevelOverride(allocator, &object, "low", map.low);
    try putThinkingLevelOverride(allocator, &object, "medium", map.medium);
    try putThinkingLevelOverride(allocator, &object, "high", map.high);
    try putThinkingLevelOverride(allocator, &object, "xhigh", map.xhigh);
    return object;
}

fn putThinkingLevelOverride(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: ai.ThinkingLevelOverride) !void {
    switch (value) {
        .unset => {},
        .unsupported => try putValue(allocator, object, key, .null),
        .mapped => |mapped| try putString(allocator, object, key, mapped),
    }
}

fn thinkingBudgetsValue(allocator: std.mem.Allocator, budgets: ai.ThinkingBudgets) !std.json.Value {
    var object = objectValue();
    if (budgets.minimal) |value| try putInteger(allocator, &object, "minimal", value);
    if (budgets.low) |value| try putInteger(allocator, &object, "low", value);
    if (budgets.medium) |value| try putInteger(allocator, &object, "medium", value);
    if (budgets.high) |value| try putInteger(allocator, &object, "high", value);
    return object;
}

fn headersObjectValue(allocator: std.mem.Allocator, headers: []const ai.Header) !std.json.Value {
    var object = objectValue();
    for (headers) |header| try putString(allocator, &object, header.name, header.value);
    return object;
}

fn compatValue(allocator: std.mem.Allocator, compat: ai.ModelCompat) !std.json.Value {
    var object = objectValue();
    if (compat.supports_store) |value| try putBool(allocator, &object, "supportsStore", value);
    if (compat.supports_developer_role) |value| try putBool(allocator, &object, "supportsDeveloperRole", value);
    if (compat.supports_reasoning_effort) |value| try putBool(allocator, &object, "supportsReasoningEffort", value);
    if (compat.supports_usage_in_streaming) |value| try putBool(allocator, &object, "supportsUsageInStreaming", value);
    if (compat.max_tokens_field) |value| try putString(allocator, &object, "maxTokensField", maxTokensFieldName(value));
    if (compat.requires_tool_result_name) |value| try putBool(allocator, &object, "requiresToolResultName", value);
    if (compat.requires_assistant_after_tool_result) |value| try putBool(allocator, &object, "requiresAssistantAfterToolResult", value);
    if (compat.requires_thinking_as_text) |value| try putBool(allocator, &object, "requiresThinkingAsText", value);
    if (compat.requires_reasoning_content_on_assistant_messages) |value| try putBool(allocator, &object, "requiresReasoningContentOnAssistantMessages", value);
    if (compat.thinking_format) |value| try putString(allocator, &object, "thinkingFormat", thinkingFormatName(value));
    if (compat.cache_control_format) |value| try putString(allocator, &object, "cacheControlFormat", value);
    if (compat.open_router_routing_json) |value| try putValue(allocator, &object, "openRouterRouting", try jsonValueOrString(allocator, value));
    if (compat.vercel_gateway_routing_json) |value| try putValue(allocator, &object, "vercelGatewayRouting", try jsonValueOrString(allocator, value));
    if (compat.zai_tool_stream) |value| try putBool(allocator, &object, "zaiToolStream", value);
    if (compat.supports_strict_mode) |value| try putBool(allocator, &object, "supportsStrictMode", value);
    if (compat.send_session_affinity_headers) |value| try putBool(allocator, &object, "sendSessionAffinityHeaders", value);
    if (compat.send_session_id_header) |value| try putBool(allocator, &object, "sendSessionIdHeader", value);
    if (compat.supports_long_cache_retention) |value| try putBool(allocator, &object, "supportsLongCacheRetention", value);
    if (compat.supports_eager_tool_input_streaming) |value| try putBool(allocator, &object, "supportsEagerToolInputStreaming", value);
    if (compat.supports_cache_control_on_tools) |value| try putBool(allocator, &object, "supportsCacheControlOnTools", value);
    if (compat.supports_temperature) |value| try putBool(allocator, &object, "supportsTemperature", value);
    if (compat.force_adaptive_thinking) |value| try putBool(allocator, &object, "forceAdaptiveThinking", value);
    if (compat.allow_empty_signature) |value| try putBool(allocator, &object, "allowEmptySignature", value);
    return object;
}

fn compatHasValues(compat: ai.ModelCompat) bool {
    return compat.supports_store != null or
        compat.supports_developer_role != null or
        compat.supports_reasoning_effort != null or
        compat.supports_usage_in_streaming != null or
        compat.max_tokens_field != null or
        compat.requires_tool_result_name != null or
        compat.requires_assistant_after_tool_result != null or
        compat.requires_thinking_as_text != null or
        compat.requires_reasoning_content_on_assistant_messages != null or
        compat.thinking_format != null or
        compat.cache_control_format != null or
        compat.open_router_routing_json != null or
        compat.vercel_gateway_routing_json != null or
        compat.zai_tool_stream != null or
        compat.supports_strict_mode != null or
        compat.send_session_affinity_headers != null or
        compat.send_session_id_header != null or
        compat.supports_long_cache_retention != null or
        compat.supports_eager_tool_input_streaming != null or
        compat.supports_cache_control_on_tools != null or
        compat.supports_temperature != null or
        compat.force_adaptive_thinking != null or
        compat.allow_empty_signature != null;
}

fn parsedStreamingJsonString(allocator: std.mem.Allocator, partial_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = try json_parse.parseStreamingJson(arena.allocator(), partial_json);
    _ = &parsed;
    return stringifyJsonValue(allocator, parsed.value);
}

fn jsonObjectValueOrEmpty(allocator: std.mem.Allocator, raw_json: []const u8) std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return objectValue();
    if (parsed.value == .object) return parsed.value;
    return objectValue();
}

fn jsonValueOrString(allocator: std.mem.Allocator, raw_json: []const u8) !std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return .{ .string = try allocator.dupe(u8, raw_json) };
    return parsed.value;
}

fn parseUsage(value: std.json.Value) ai.Usage {
    var usage: ai.Usage = .{
        .input = getUnsignedField(value, "input") orelse 0,
        .output = getUnsignedField(value, "output") orelse 0,
        .cache_read = getUnsignedField(value, "cacheRead") orelse 0,
        .cache_write = getUnsignedField(value, "cacheWrite") orelse 0,
        .total_tokens = getUnsignedField(value, "totalTokens") orelse 0,
    };
    if (getObjectField(value, "cost")) |cost| {
        usage.cost = .{
            .input = getFloatField(cost, "input") orelse 0,
            .output = getFloatField(cost, "output") orelse 0,
            .cache_read = getFloatField(cost, "cacheRead") orelse 0,
            .cache_write = getFloatField(cost, "cacheWrite") orelse 0,
            .total = getFloatField(cost, "total") orelse 0,
        };
    }
    return usage;
}

fn terminalResultAlloc(
    allocator: std.mem.Allocator,
    model: ai.Model,
    reason: ai.StopReason,
    message: []const u8,
) !ai.StreamResult {
    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = .{
            .content = &.{},
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = reason,
            .error_message = try allocator.dupe(u8, message),
            .timestamp_ms = currentTimestampMs(),
        },
    };
    errdefer result.deinit();
    try result.events.append(allocator, .{ .@"error" = .{
        .reason = reason,
        .message = result.message,
    } });
    return result;
}

fn proxyErrorMessage(allocator: std.mem.Allocator, response: ProxyHttpResponse) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        return std.fmt.allocPrint(allocator, "Proxy error: {d} {s}", .{ response.status, response.status_text });
    };
    defer parsed.deinit();
    if (getStringField(parsed.value, "error")) |message| {
        return std.fmt.allocPrint(allocator, "Proxy error: {s}", .{message});
    }
    return std.fmt.allocPrint(allocator, "Proxy error: {d} {s}", .{ response.status, response.status_text });
}

const StdProxyTransport = struct {};

fn stdProxyTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: ProxyHttpRequest,
) anyerror!ProxyHttpResponse {
    _ = ptr;

    var client = std.http.Client{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const headers = try stdHttpHeaders(allocator, request.headers);
    defer allocator.free(headers);

    const result = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = .POST,
        .payload = request.payload_json,
        .headers = .{
            .authorization = .omit,
            .content_type = .omit,
        },
        .extra_headers = headers,
        .response_writer = &response_writer.writer,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const raw_body = try response_writer.toOwnedSlice();
    defer allocator.free(raw_body);
    const body = try arena.allocator().dupe(u8, raw_body);
    response_writer.deinit();

    return .{
        .arena = arena,
        .status = @intFromEnum(result.status),
        .status_text = @tagName(result.status),
        .body = body,
    };
}

fn stdHttpHeaders(allocator: std.mem.Allocator, headers: []const ai.Header) ![]std.http.Header {
    const result = try allocator.alloc(std.http.Header, headers.len);
    errdefer allocator.free(result);
    for (headers, 0..) |header, index| {
        result[index] = .{ .name = header.name, .value = header.value };
    }
    return result;
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stream: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };
    try stream.write(value);
    return out.toOwnedSlice();
}

fn objectValue() std.json.Value {
    return .{ .object = .empty };
}

fn putValue(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), value);
}

fn putString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putBool(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: bool) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putInteger(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: u64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .integer = std.math.cast(i64, value) orelse std.math.maxInt(i64) });
}

fn putFloat(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: f64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .float = value });
}

fn requiredIndex(value: std.json.Value) !usize {
    return getUnsignedField(value, "contentIndex") orelse error.InvalidProxyEvent;
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
    return unsignedFromValue(nested);
}

fn getFloatField(value: std.json.Value, field: []const u8) ?f64 {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return switch (nested) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn unsignedFromValue(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and float <= @as(f64, @floatFromInt(std.math.maxInt(u64)))) @intFromFloat(float) else null,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        else => null,
    };
}

fn parseStopReason(value: []const u8) ?ai.StopReason {
    if (eql(value, "stop")) return .stop;
    if (eql(value, "length")) return .length;
    if (eql(value, "toolUse") or eql(value, "tool_use")) return .tool_use;
    if (eql(value, "error")) return .@"error";
    if (eql(value, "aborted")) return .aborted;
    return null;
}

fn stopReasonName(value: ai.StopReason) []const u8 {
    return switch (value) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .@"error" => "error",
        .aborted => "aborted",
    };
}

fn cacheRetentionName(value: ai.CacheRetention) []const u8 {
    return switch (value) {
        .none => "none",
        .short => "short",
        .long => "long",
    };
}

fn transportName(value: ai.Transport) []const u8 {
    return switch (value) {
        .sse => "sse",
        .websocket => "websocket",
        .websocket_cached => "websocket-cached",
        .auto => "auto",
    };
}

fn thinkingLevelName(value: ai.ThinkingLevel) []const u8 {
    return switch (value) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn maxTokensFieldName(value: ai.MaxTokensField) []const u8 {
    return switch (value) {
        .max_completion_tokens => "max_completion_tokens",
        .max_tokens => "max_tokens",
    };
}

fn thinkingFormatName(value: ai.ThinkingFormat) []const u8 {
    return switch (value) {
        .openai => "openai",
        .openrouter => "openrouter",
        .deepseek => "deepseek",
        .together => "together",
        .zai => "zai",
        .qwen => "qwen",
        .qwen_chat_template => "qwen-chat-template",
        .string_thinking => "string-thinking",
    };
}

fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

fn isAborted(options: ai.StreamOptions) bool {
    return if (options.signal) |signal| signal.aborted else false;
}

fn currentTimestampMs() i64 {
    return ai.diagnostics.currentTimestampMs();
}

fn trimRightBytes(input: []const u8, values: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values, input[end - 1]) != null) {
        end -= 1;
    }
    return input[0..end];
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

const test_model: ai.Model = .{
    .id = "proxy-model",
    .name = "Proxy Model",
    .api = ai.types.api.openai_responses,
    .provider = "openai",
    .base_url = "https://api.example.test/v1",
};

test "agent proxy parses Pi proxy SSE events into a native stream result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const body =
        "data: {\"type\":\"start\"}\n\n" ++
        "data: {\"type\":\"thinking_start\",\"contentIndex\":0}\n\n" ++
        "data: {\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"plan\"}\n\n" ++
        "data: {\"type\":\"thinking_end\",\"contentIndex\":0,\"contentSignature\":\"sig\"}\n\n" ++
        "data: {\"type\":\"text_start\",\"contentIndex\":1}\n\n" ++
        "data: {\"type\":\"text_delta\",\"contentIndex\":1,\"delta\":\"hel\"}\n\n" ++
        "data: {\"type\":\"text_delta\",\"contentIndex\":1,\"delta\":\"lo\"}\n\n" ++
        "data: {\"type\":\"text_end\",\"contentIndex\":1,\"contentSignature\":\"text-sig\"}\n\n" ++
        "data: {\"type\":\"toolcall_start\",\"contentIndex\":2,\"id\":\"tool-1\",\"toolName\":\"read\"}\n\n" ++
        "data: {\"type\":\"toolcall_delta\",\"contentIndex\":2,\"delta\":\"{\\\"path\\\":\\\"/tmp\"}\n\n" ++
        "data: {\"type\":\"toolcall_end\",\"contentIndex\":2}\n\n" ++
        "data: {\"type\":\"done\",\"reason\":\"toolUse\",\"usage\":{\"input\":3,\"output\":5,\"cacheRead\":7,\"cacheWrite\":11,\"totalTokens\":26,\"cost\":{\"input\":0.1,\"output\":0.2,\"cacheRead\":0.3,\"cacheWrite\":0.4,\"total\":1.0}}}\n\n";

    var result = try parseProxySseResponse(allocator, test_model, body);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 12), result.events.items.len);
    try std.testing.expectEqual(ai.StopReason.tool_use, result.message.stop_reason);
    try std.testing.expectEqual(@as(u64, 26), result.message.usage.total_tokens);
    try std.testing.expectEqual(@as(usize, 3), result.message.content.len);
    try std.testing.expectEqualStrings("plan", result.message.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("sig", result.message.content[0].thinking.thinking_signature.?);
    try std.testing.expectEqualStrings("hello", result.message.content[1].text.text);
    try std.testing.expectEqualStrings("text-sig", result.message.content[1].text.text_signature.?);
    try std.testing.expectEqualStrings("tool-1", result.message.content[2].tool_call.id);
    try std.testing.expectEqualStrings("read", result.message.content[2].tool_call.name);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", result.message.content[2].tool_call.arguments_json);
    try std.testing.expectEqual(std.meta.Tag(ai.StreamEvent).toolcall_delta, std.meta.activeTag(result.events.items[9]));
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", result.events.items[10].toolcall_end.tool_call.arguments_json);
}

const RecordingTransport = struct {
    url: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    body: ?[]const u8 = null,
    response_body: []const u8 =
        "data: {\"type\":\"start\"}\n\n" ++
        "data: {\"type\":\"done\",\"reason\":\"stop\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}}}\n\n",

    fn transport(self: *RecordingTransport) ProxyTransport {
        return .{ .ptr = self, .request = request };
    }

    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, http_request: ProxyHttpRequest) !ProxyHttpResponse {
        const self: *RecordingTransport = @ptrCast(@alignCast(ptr));
        self.url = try allocator.dupe(u8, http_request.url);
        self.body = try allocator.dupe(u8, http_request.payload_json);
        for (http_request.headers) |header| {
            if (eql(header.name, "Authorization")) self.authorization = try allocator.dupe(u8, header.value);
            if (eql(header.name, "Content-Type")) self.content_type = try allocator.dupe(u8, header.value);
            if (eql(header.name, "Accept")) self.accept = try allocator.dupe(u8, header.value);
        }
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        return .{
            .arena = arena,
            .status = 200,
            .status_text = "OK",
            .body = try arena.allocator().dupe(u8, self.response_body),
        };
    }
};

test "agent proxy posts Pi-compatible request body through injectable transport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = [_]ai.UserContent{.{ .text = .{ .text = "hello" } }};
    const messages = [_]ai.Message{.{ .user = .{ .content = &text, .timestamp_ms = 1000 } }};
    const tools = [_]ai.Tool{.{ .name = "read", .description = "Read file", .parameters_json = "{\"type\":\"object\"}" }};
    const headers = [_]ai.Header{.{ .name = "X-Test", .value = "yes" }};
    var transport = RecordingTransport{};

    var result = try streamProxy(allocator, test_model, .{
        .system_prompt = "system",
        .messages = &messages,
        .tools = &tools,
    }, .{
        .auth_token = "token",
        .proxy_url = "https://proxy.example/",
        .reasoning = .medium,
        .base = .{
            .temperature = 0.5,
            .max_tokens = 123,
            .api_key = "local-secret",
            .session_id = "session-1",
            .headers = &headers,
            .metadata_json = "{\"trace\":\"abc\"}",
            .transport = .sse,
            .max_retry_delay_ms = 42,
        },
        .transport = transport.transport(),
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("https://proxy.example/api/stream", transport.url.?);
    try std.testing.expectEqualStrings("Bearer token", transport.authorization.?);
    try std.testing.expectEqualStrings("application/json", transport.content_type.?);
    try std.testing.expectEqualStrings("text/event-stream", transport.accept.?);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, transport.body.?, .{});
    _ = &parsed;
    const options = parsed.value.object.get("options").?.object;
    try std.testing.expect(options.get("apiKey") == null);
    try std.testing.expectEqualStrings("medium", options.get("reasoning").?.string);
    try std.testing.expectEqual(@as(i64, 123), options.get("maxTokens").?.integer);
    try std.testing.expectEqualStrings("session-1", options.get("sessionId").?.string);
    try std.testing.expectEqualStrings("yes", options.get("headers").?.object.get("X-Test").?.string);
    try std.testing.expectEqualStrings("abc", options.get("metadata").?.object.get("trace").?.string);

    const context = parsed.value.object.get("context").?.object;
    try std.testing.expectEqualStrings("system", context.get("systemPrompt").?.string);
    try std.testing.expectEqualStrings("user", context.get("messages").?.array.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("read", context.get("tools").?.array.items[0].object.get("name").?.string);

    const model = parsed.value.object.get("model").?.object;
    try std.testing.expectEqualStrings("https://api.example.test/v1", model.get("baseUrl").?.string);
}
