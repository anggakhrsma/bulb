const std = @import("std");
const cache_retention = @import("cache_retention.zig");
const models = @import("../models.zig");
const openai_prompt_cache = @import("openai_prompt_cache.zig");
const openai_responses_shared = @import("openai_responses_shared.zig");
const sse = @import("../utils/sse.zig");
const types = @import("../types.zig");

pub const ReasoningSummary = enum {
    auto,
    detailed,
    concise,

    fn jsonName(self: ReasoningSummary) []const u8 {
        return switch (self) {
            .auto => "auto",
            .detailed => "detailed",
            .concise => "concise",
        };
    }
};

pub const OpenAIResponsesOptions = struct {
    base: types.StreamOptions = .{},
    reasoning_effort: ?types.ThinkingLevel = null,
    reasoning_summary: ?ReasoningSummary = null,
    service_tier: ?[]const u8 = null,
    on_payload: ?PayloadObserver = null,
    on_response: ?ResponseObserver = null,
    transport: ?OpenAIResponsesTransport = null,
};

pub const OpenAIResponsesRequestOptions = struct {
    timeout_ms: ?u64 = null,
    max_retries: u32 = 0,
};

pub const OpenAIResponsesHttpRequest = struct {
    url: []const u8,
    payload_json: []const u8,
    headers: []const types.Header,
    timeout_ms: ?u64 = null,
    attempt: u32 = 0,
    max_retries: u32 = 0,
};

pub const OpenAIResponsesHttpResponse = struct {
    arena: std.heap.ArenaAllocator,
    status: u16,
    body: []const u8,
    headers: []const types.Header = &.{},

    pub fn deinit(self: *OpenAIResponsesHttpResponse) void {
        self.arena.deinit();
    }
};

pub const OpenAIResponsesResponseInfo = struct {
    status: u16,
    headers: []const types.Header = &.{},
};

pub const PayloadObserver = *const fn (payload: *std.json.Value, model: types.Model) anyerror!void;
pub const ResponseObserver = *const fn (response: OpenAIResponsesResponseInfo, model: types.Model) anyerror!void;
pub const OpenAIResponsesTransportFn = *const fn (
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAIResponsesHttpRequest,
) anyerror!OpenAIResponsesHttpResponse;

pub const OpenAIResponsesTransport = struct {
    ptr: *anyopaque,
    request: OpenAIResponsesTransportFn,

    pub fn send(
        self: OpenAIResponsesTransport,
        allocator: std.mem.Allocator,
        request: OpenAIResponsesHttpRequest,
    ) !OpenAIResponsesHttpResponse {
        return self.request(self.ptr, allocator, request);
    }
};

pub const ClientHeaderMap = struct {
    map: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ClientHeaderMap {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *ClientHeaderMap, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    pub fn getString(self: *const ClientHeaderMap, key: []const u8) ?[]const u8 {
        return (self.map.get(key) orelse return null) orelse null;
    }
};

pub const OpenAIResponsesClientConfig = struct {
    arena: std.heap.ArenaAllocator,
    api_key: []const u8,
    base_url: []const u8,
    request_url: []const u8,
    dangerously_allow_browser: bool = true,
    headers: ClientHeaderMap,
    request_options: OpenAIResponsesRequestOptions,

    pub fn deinit(self: *OpenAIResponsesClientConfig) void {
        self.headers.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

pub const ResolvedOpenAIResponsesCompat = struct {
    send_session_id_header: bool,
    supports_long_cache_retention: bool,
};

pub const BuiltResponsesParams = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,

    pub fn deinit(self: *BuiltResponsesParams) void {
        self.arena.deinit();
    }

    pub fn stringify(self: *const BuiltResponsesParams, allocator: std.mem.Allocator) ![]u8 {
        return stringifyJsonValue(allocator, self.value);
    }
};

pub const ParsedStream = openai_responses_shared.ParsedResponsesStream;

pub fn streamOpenAIResponses(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?OpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) !ParsedStream {
    var params = try buildParams(allocator, model, context, options, env);
    defer params.deinit();

    if (options) |opts| {
        if (opts.on_payload) |observer| try observer(&params.value, model);
    }

    const payload_json = try stringifyJsonValue(allocator, params.value);
    defer allocator.free(payload_json);

    var config = try buildClientConfig(allocator, model, context, options, env);
    defer config.deinit();

    var request_headers = try buildHttpHeaders(allocator, config);
    defer request_headers.deinit();

    var std_transport_state: StdOpenAIResponsesTransport = .{};
    const default_transport: OpenAIResponsesTransport = .{
        .ptr = &std_transport_state,
        .request = stdOpenAIResponsesTransportRequest,
    };
    const transport = if (options) |opts| opts.transport orelse default_transport else default_transport;
    const base_options = if (options) |opts| opts.base else types.StreamOptions{};

    if (isAborted(base_options)) {
        return terminalParsedStream(allocator, model, .aborted, "Request was aborted");
    }

    var attempt: u32 = 0;
    while (true) {
        var response = transport.send(allocator, .{
            .url = config.request_url,
            .payload_json = payload_json,
            .headers = request_headers.headers,
            .timeout_ms = config.request_options.timeout_ms,
            .attempt = attempt,
            .max_retries = config.request_options.max_retries,
        }) catch |err| {
            if (attempt < config.request_options.max_retries and isRetryableTransportError(err)) {
                attempt += 1;
                continue;
            }
            return terminalParsedStream(allocator, model, .@"error", @errorName(err));
        };

        if (options) |opts| {
            if (opts.on_response) |observer| {
                observer(.{ .status = response.status, .headers = response.headers }, model) catch |err| {
                    response.deinit();
                    return err;
                };
            }
        }

        if (isRetryableStatus(response.status) and attempt < config.request_options.max_retries) {
            attempt += 1;
            response.deinit();
            continue;
        }

        if (!isSuccessStatus(response.status)) {
            const message = try httpErrorMessage(allocator, response.status, response.body);
            defer allocator.free(message);
            response.deinit();
            return terminalParsedStream(allocator, model, .@"error", message);
        }

        const parsed = parseSseResponse(allocator, model, response.body, if (options) |opts| opts.service_tier else null) catch |err| {
            response.deinit();
            return err;
        };
        response.deinit();
        return parsed;
    }
}

pub fn parseSseResponse(
    allocator: std.mem.Allocator,
    model: types.Model,
    body: []const u8,
    service_tier: ?[]const u8,
) !ParsedStream {
    var decoded = try sse.decodeAll(allocator, body);
    defer decoded.deinit();

    var events_json = std.ArrayList([]const u8).empty;
    defer events_json.deinit(allocator);
    for (decoded.events) |event| {
        if (std.mem.eql(u8, std.mem.trim(u8, event.data, " \t\r\n"), "[DONE]")) continue;
        if (event.data.len == 0) continue;
        try events_json.append(allocator, event.data);
    }

    var parsed = try openai_responses_shared.processResponsesEvents(allocator, model, events_json.items);
    if (service_tier) |tier| applyServiceTierPricing(&parsed.result.message.usage, tier, model);
    return parsed;
}

pub fn buildParams(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?OpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) !BuiltResponsesParams {
    const requested_retention = if (options) |opts| opts.base.cache_retention else types.CacheRetention.short;
    const cache_retention_override: ?types.CacheRetention = if (requested_retention == .short) null else requested_retention;
    const retention = cache_retention.resolveCacheRetention(env, cache_retention_override);
    const compat = getCompat(model);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var root = objectValue();
    try putString(a, &root, "model", model.id);
    try putValue(a, &root, "input", try openai_responses_shared.convertResponsesMessagesValue(
        a,
        model,
        context,
        .{ .include_system_prompt = true },
    ));
    try putBool(a, &root, "stream", true);

    if (try openai_prompt_cache.responsesPromptCacheKey(a, if (options) |opts| opts.base.session_id else null, retention)) |key| {
        try putOwnedString(a, &root, "prompt_cache_key", key);
    }
    if (openai_prompt_cache.promptCacheRetention(modelWithLongRetention(model, compat), retention)) |prompt_retention| {
        try putString(a, &root, "prompt_cache_retention", prompt_retention);
    }
    try putBool(a, &root, "store", false);

    if (options) |opts| {
        if (opts.base.max_tokens) |max_tokens| try putInteger(a, &root, "max_output_tokens", max_tokens);
        if (opts.base.temperature) |temperature| try putFloat(a, &root, "temperature", temperature);
        if (opts.service_tier) |service_tier| try putString(a, &root, "service_tier", service_tier);
    }

    if (context.tools.len > 0) {
        try putValue(a, &root, "tools", try openai_responses_shared.convertResponsesToolsValue(a, context.tools, .{}));
    }

    try applyReasoningOptions(a, &root, model, options);

    return .{
        .arena = arena,
        .value = root,
    };
}

pub fn getCompat(model: types.Model) ResolvedOpenAIResponsesCompat {
    return .{
        .send_session_id_header = model.compat.send_session_id_header orelse true,
        .supports_long_cache_retention = model.compat.supports_long_cache_retention orelse true,
    };
}

pub fn buildClientConfig(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?OpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) !OpenAIResponsesClientConfig {
    const base_options = if (options) |opts| opts.base else types.StreamOptions{};
    const api_key = base_options.api_key orelse return error.NoApiKey;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const resolved_base_url = if (isCloudflareProvider(model.provider))
        try resolveCloudflareBaseUrl(a, model, env)
    else
        try a.dupe(u8, model.base_url);

    const headers = try buildClientHeaderMap(a, model, context, api_key, options);
    errdefer {
        var mutable_headers = headers;
        mutable_headers.deinit(a);
    }

    const request_url = try responsesUrl(a, resolved_base_url);

    return .{
        .arena = arena,
        .api_key = try a.dupe(u8, api_key),
        .base_url = resolved_base_url,
        .request_url = request_url,
        .headers = headers,
        .request_options = .{
            .timeout_ms = base_options.timeout_ms,
            .max_retries = base_options.max_retries orelse 0,
        },
    };
}

const OwnedHeaderList = struct {
    allocator: std.mem.Allocator,
    headers: []types.Header,

    fn deinit(self: *OwnedHeaderList) void {
        for (self.headers) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.allocator.free(self.headers);
    }
};

fn buildHttpHeaders(allocator: std.mem.Allocator, config: OpenAIResponsesClientConfig) !OwnedHeaderList {
    var headers = std.ArrayList(types.Header).empty;
    errdefer {
        deinitHeaderItems(allocator, headers.items);
        headers.deinit(allocator);
    }

    try appendHeader(allocator, &headers, "Content-Type", config.headers.getString("Content-Type") orelse "application/json");
    try appendHeader(allocator, &headers, "Accept", config.headers.getString("Accept") orelse "text/event-stream");

    if (config.headers.map.get("Authorization")) |authorization| {
        if (authorization) |value| try appendHeader(allocator, &headers, "Authorization", value);
    } else {
        const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{config.api_key});
        defer allocator.free(bearer);
        try appendHeader(allocator, &headers, "Authorization", bearer);
    }

    var iterator = config.headers.map.iterator();
    while (iterator.next()) |entry| {
        const value = entry.value_ptr.* orelse continue;
        if (eql(entry.key_ptr.*, "Authorization")) continue;
        if (eql(entry.key_ptr.*, "Content-Type")) continue;
        if (eql(entry.key_ptr.*, "Accept")) continue;
        try appendHeader(allocator, &headers, entry.key_ptr.*, value);
    }

    return .{
        .allocator = allocator,
        .headers = try headers.toOwnedSlice(allocator),
    };
}

fn buildClientHeaderMap(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    api_key: []const u8,
    options: ?OpenAIResponsesOptions,
) !ClientHeaderMap {
    const compat = getCompat(model);
    var headers = ClientHeaderMap.init(allocator);
    errdefer headers.deinit(allocator);

    for (model.headers) |header| try putClientHeader(allocator, &headers, header.name, header.value);

    if (eql(model.provider, "github-copilot")) {
        try putClientHeader(allocator, &headers, "X-Initiator", inferCopilotInitiator(context.messages));
        try putClientHeader(allocator, &headers, "Openai-Intent", "conversation-edits");
        if (hasCopilotVisionInput(context.messages)) {
            try putClientHeader(allocator, &headers, "Copilot-Vision-Request", "true");
        }
    }

    const retention = if (options) |opts| opts.base.cache_retention else types.CacheRetention.short;
    const session_id = if (retention == .none) null else if (options) |opts| opts.base.session_id else null;
    if (session_id) |id| {
        if (compat.send_session_id_header) try putClientHeader(allocator, &headers, "session_id", id);
        try putClientHeader(allocator, &headers, "x-client-request-id", id);
    }

    if (options) |opts| {
        for (opts.base.headers) |header| try putClientHeader(allocator, &headers, header.name, header.value);
    }

    if (eql(model.provider, "cloudflare-ai-gateway")) {
        if (headers.map.get("Authorization") == null) try putClientNullHeader(allocator, &headers, "Authorization");
        try putClientHeader(allocator, &headers, "cf-aig-authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}));
    }

    return headers;
}

fn putClientHeader(
    allocator: std.mem.Allocator,
    headers: *ClientHeaderMap,
    key: []const u8,
    value: []const u8,
) !void {
    try headers.map.put(allocator, try allocator.dupe(u8, key), try allocator.dupe(u8, value));
}

fn putClientNullHeader(
    allocator: std.mem.Allocator,
    headers: *ClientHeaderMap,
    key: []const u8,
) !void {
    try headers.map.put(allocator, try allocator.dupe(u8, key), null);
}

fn appendHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(types.Header),
    name: []const u8,
    value: []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try headers.append(allocator, .{
        .name = owned_name,
        .value = owned_value,
    });
}

fn deinitHeaderItems(allocator: std.mem.Allocator, headers: []types.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

fn terminalParsedStream(
    allocator: std.mem.Allocator,
    model: types.Model,
    reason: types.StopReason,
    message: []const u8,
) !ParsedStream {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var events = std.ArrayList(types.StreamEvent).empty;
    errdefer events.deinit(allocator);
    const output: types.AssistantMessage = .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = reason,
        .error_message = try a.dupe(u8, message),
    };
    try events.append(allocator, .{ .@"error" = .{
        .reason = reason,
        .message = output,
    } });

    return .{
        .arena = arena,
        .result = .{
            .allocator = allocator,
            .events = events,
            .message = output,
        },
    };
}

fn httpErrorMessage(allocator: std.mem.Allocator, status: u16, body: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return std.fmt.allocPrint(allocator, "HTTP {d}", .{status});
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, trimmed });
}

fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

fn isRetryableStatus(status: u16) bool {
    return status == 408 or status == 409 or status == 429 or status >= 500;
}

fn isRetryableTransportError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory => false,
        else => true,
    };
}

const StdOpenAIResponsesTransport = struct {};

fn stdOpenAIResponsesTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAIResponsesHttpRequest,
) anyerror!OpenAIResponsesHttpResponse {
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
        .body = body,
    };
}

fn stdHttpHeaders(allocator: std.mem.Allocator, headers: []const types.Header) ![]std.http.Header {
    var result = try allocator.alloc(std.http.Header, headers.len);
    errdefer allocator.free(result);
    for (headers, 0..) |header, index| {
        result[index] = .{
            .name = header.name,
            .value = header.value,
        };
    }
    return result;
}

fn applyReasoningOptions(
    allocator: std.mem.Allocator,
    params: *std.json.Value,
    model: types.Model,
    options: ?OpenAIResponsesOptions,
) !void {
    if (!model.reasoning) return;

    const explicit_effort = if (options) |opts| opts.reasoning_effort else null;
    const explicit_summary = if (options) |opts| opts.reasoning_summary else null;
    if (explicit_effort != null or explicit_summary != null) {
        const effort = if (explicit_effort) |level| thinkingLevelValue(model, level) else "medium";
        var reasoning = objectValue();
        try putString(allocator, &reasoning, "effort", effort);
        try putString(allocator, &reasoning, "summary", if (explicit_summary) |summary| summary.jsonName() else "auto");
        try putValue(allocator, params, "reasoning", reasoning);

        var include = std.json.Array.init(allocator);
        errdefer include.deinit();
        try include.append(.{ .string = try allocator.dupe(u8, "reasoning.encrypted_content") });
        try putValue(allocator, params, "include", .{ .array = include });
        return;
    }

    if (eql(model.provider, "github-copilot")) return;

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

fn applyServiceTierPricing(usage: *types.Usage, service_tier: []const u8, model: types.Model) void {
    const multiplier = serviceTierCostMultiplier(model, service_tier);
    if (multiplier == 1) return;
    usage.cost.input *= multiplier;
    usage.cost.output *= multiplier;
    usage.cost.cache_read *= multiplier;
    usage.cost.cache_write *= multiplier;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

fn serviceTierCostMultiplier(model: types.Model, service_tier: []const u8) f64 {
    if (eql(service_tier, "flex")) return 0.5;
    if (eql(service_tier, "priority")) return if (eql(model.id, "gpt-5.5")) 2.5 else 2.0;
    return 1.0;
}

fn modelWithLongRetention(model: types.Model, compat: ResolvedOpenAIResponsesCompat) types.Model {
    var copy = model;
    copy.compat.supports_long_cache_retention = compat.supports_long_cache_retention;
    return copy;
}

fn responsesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/responses", .{trimmed});
}

fn isCloudflareProvider(provider: []const u8) bool {
    return eql(provider, "cloudflare-workers-ai") or eql(provider, "cloudflare-ai-gateway");
}

fn resolveCloudflareBaseUrl(
    allocator: std.mem.Allocator,
    model: types.Model,
    env: ?*const std.process.Environ.Map,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, model.base_url, '{') == null) return allocator.dupe(u8, model.base_url);

    const environ = env orelse return error.MissingCloudflareEnvironment;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var index: usize = 0;
    while (index < model.base_url.len) {
        if (model.base_url[index] != '{') {
            try result.append(allocator, model.base_url[index]);
            index += 1;
            continue;
        }

        const close_offset = std.mem.indexOfScalar(u8, model.base_url[index + 1 ..], '}') orelse {
            try result.append(allocator, model.base_url[index]);
            index += 1;
            continue;
        };
        const end = index + 1 + close_offset;
        const name = model.base_url[index + 1 .. end];
        if (!isEnvPlaceholderName(name)) {
            try result.appendSlice(allocator, model.base_url[index .. end + 1]);
            index = end + 1;
            continue;
        }

        const replacement = environ.get(name) orelse return error.MissingCloudflareEnvironment;
        try result.appendSlice(allocator, replacement);
        index = end + 1;
    }

    return result.toOwnedSlice(allocator);
}

fn isEnvPlaceholderName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isEnvPlaceholderStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isEnvPlaceholderChar(byte)) return false;
    }
    return true;
}

fn isEnvPlaceholderStart(byte: u8) bool {
    return byte == '_' or (byte >= 'A' and byte <= 'Z');
}

fn isEnvPlaceholderChar(byte: u8) bool {
    return isEnvPlaceholderStart(byte) or (byte >= '0' and byte <= '9');
}

fn inferCopilotInitiator(messages: []const types.Message) []const u8 {
    if (messages.len == 0) return "user";
    return if (std.meta.activeTag(messages[messages.len - 1]) == .user) "user" else "agent";
}

fn hasCopilotVisionInput(messages: []const types.Message) bool {
    for (messages) |message| switch (message) {
        .user => |user| {
            for (user.content) |content| {
                if (content == .image) return true;
            }
        },
        .tool_result => |tool_result| {
            for (tool_result.content) |content| {
                if (content == .image) return true;
            }
        },
        .assistant => {},
    };
    return false;
}

fn isAborted(options: types.StreamOptions) bool {
    return if (options.signal) |signal| signal.aborted else false;
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
    try putOwnedString(allocator, object, key, try allocator.dupe(u8, value));
}

fn putOwnedString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .string = value });
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

fn findHeader(headers: []const types.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const openai_responses_done_sse =
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-test\",\"status\":\"completed\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}\n\n" ++
    "data: [DONE]\n\n";

const RecordedOpenAIResponsesRequest = struct {
    attempt: u32,
    max_retries: u32,
    timeout_ms: ?u64,
    url: []u8,
    payload_json: []u8,
    authorization: ?[]u8 = null,
    cf_aig_authorization: ?[]u8 = null,
    session_id: ?[]u8 = null,
    x_client_request_id: ?[]u8 = null,

    fn deinit(self: *RecordedOpenAIResponsesRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.payload_json);
        if (self.authorization) |value| allocator.free(value);
        if (self.cf_aig_authorization) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
        if (self.x_client_request_id) |value| allocator.free(value);
    }
};

const FakeOpenAIResponsesTransport = struct {
    allocator: std.mem.Allocator,
    statuses: []const u16 = &.{200},
    body: []const u8 = openai_responses_done_sse,
    records: std.ArrayList(RecordedOpenAIResponsesRequest) = .empty,

    fn init(allocator: std.mem.Allocator) FakeOpenAIResponsesTransport {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakeOpenAIResponsesTransport) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    fn transport(self: *FakeOpenAIResponsesTransport) OpenAIResponsesTransport {
        return .{
            .ptr = self,
            .request = fakeOpenAIResponsesTransportRequest,
        };
    }

    fn statusForAttempt(self: *const FakeOpenAIResponsesTransport, attempt: u32) u16 {
        if (self.statuses.len == 0) return 200;
        const index: usize = @min(attempt, self.statuses.len - 1);
        return self.statuses[index];
    }
};

fn fakeOpenAIResponsesTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAIResponsesHttpRequest,
) anyerror!OpenAIResponsesHttpResponse {
    const state: *FakeOpenAIResponsesTransport = @ptrCast(@alignCast(ptr));
    var record: RecordedOpenAIResponsesRequest = .{
        .attempt = request.attempt,
        .max_retries = request.max_retries,
        .timeout_ms = request.timeout_ms,
        .url = try state.allocator.dupe(u8, request.url),
        .payload_json = try state.allocator.dupe(u8, request.payload_json),
    };
    if (findHeader(request.headers, "Authorization")) |authorization| {
        record.authorization = try state.allocator.dupe(u8, authorization);
    }
    if (findHeader(request.headers, "cf-aig-authorization")) |value| {
        record.cf_aig_authorization = try state.allocator.dupe(u8, value);
    }
    if (findHeader(request.headers, "session_id")) |value| {
        record.session_id = try state.allocator.dupe(u8, value);
    }
    if (findHeader(request.headers, "x-client-request-id")) |value| {
        record.x_client_request_id = try state.allocator.dupe(u8, value);
    }
    errdefer record.deinit(state.allocator);
    try state.records.append(state.allocator, record);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const body = try arena.allocator().dupe(u8, state.body);
    return .{
        .arena = arena,
        .status = state.statusForAttempt(request.attempt),
        .body = body,
    };
}

fn runFakeOpenAIResponsesStream(
    transport: *FakeOpenAIResponsesTransport,
    model: types.Model,
    context: types.Context,
    options: OpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) !ParsedStream {
    var stream_options = options;
    stream_options.transport = transport.transport();
    return streamOpenAIResponses(std.testing.allocator, model, context, stream_options, env);
}

const basic_user_content = [_]types.UserContent{.{ .text = .{ .text = "hi" } }};
const basic_messages = [_]types.Message{.{ .user = .{ .content = &basic_user_content, .timestamp_ms = 1 } }};

fn basicContext() types.Context {
    return .{
        .system_prompt = "sys",
        .messages = &basic_messages,
    };
}

fn expectNoReasoning(params: std.json.Value) !void {
    try std.testing.expect(params.object.get("reasoning") == null);
}

fn expectReasoningEffort(params: std.json.Value, expected: []const u8) !void {
    const reasoning = getObjectField(params, "reasoning") orelse return error.MissingReasoning;
    try std.testing.expectEqualStrings(expected, getStringField(reasoning, "effort") orelse return error.MissingEffort);
}

// Ported from packages/ai/test/openai-responses-copilot-provider.test.ts.
test "OpenAI Responses omits reasoning for GitHub Copilot when no reasoning is requested" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("github-copilot", "gpt-5-mini") orelse return error.ModelMissing).*;
    var params = try buildParams(allocator, model, basicContext(), .{ .base = .{ .api_key = "test-key" } }, null);
    defer params.deinit();
    try expectNoReasoning(params.value);
}

// Ported from packages/ai/test/openai-responses-copilot-provider.test.ts.
test "OpenAI Responses sends none reasoning effort when off is supported by OpenAI models" {
    const allocator = std.testing.allocator;
    const model_ids = [_][]const u8{ "gpt-5.1", "gpt-5.2", "gpt-5.3-codex", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.5" };
    for (model_ids) |model_id| {
        const model = (models.getModel("openai", model_id) orelse return error.ModelMissing).*;
        var params = try buildParams(allocator, model, basicContext(), .{ .base = .{ .api_key = "test-key" } }, null);
        defer params.deinit();
        try expectReasoningEffort(params.value, "none");
    }
}

// Ported from packages/ai/test/openai-responses-copilot-provider.test.ts.
test "OpenAI Responses omits reasoning when off is unsupported by OpenAI models" {
    const allocator = std.testing.allocator;
    const model_ids = [_][]const u8{ "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5-pro", "gpt-5.2-pro", "gpt-5.4-pro", "gpt-5.5-pro" };
    for (model_ids) |model_id| {
        const model = (models.getModel("openai", model_id) orelse return error.ModelMissing).*;
        var params = try buildParams(allocator, model, basicContext(), .{ .base = .{ .api_key = "test-key" } }, null);
        defer params.deinit();
        try expectNoReasoning(params.value);
    }
}

// Ported from packages/ai/test/openai-responses-copilot-provider.test.ts.
test "OpenAI Responses cache-affinity headers follow session retention and overrides" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("openai", "gpt-5.4") orelse return error.ModelMissing).*;

    var official_transport = FakeOpenAIResponsesTransport.init(allocator);
    defer official_transport.deinit();
    var official = try runFakeOpenAIResponsesStream(&official_transport, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-123" },
    }, null);
    defer official.deinit();
    try std.testing.expectEqual(@as(usize, 1), official_transport.records.items.len);
    try std.testing.expectEqualStrings("session-123", official_transport.records.items[0].session_id.?);
    try std.testing.expectEqualStrings("session-123", official_transport.records.items[0].x_client_request_id.?);

    var proxy_model = model;
    proxy_model.provider = "opencode";
    proxy_model.base_url = "https://proxy.example.com/v1";
    var proxy_transport = FakeOpenAIResponsesTransport.init(allocator);
    defer proxy_transport.deinit();
    var proxy = try runFakeOpenAIResponsesStream(&proxy_transport, proxy_model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-123" },
    }, null);
    defer proxy.deinit();
    try std.testing.expectEqualStrings("session-123", proxy_transport.records.items[0].session_id.?);
    try std.testing.expectEqualStrings("session-123", proxy_transport.records.items[0].x_client_request_id.?);

    proxy_model.compat.send_session_id_header = false;
    var no_session_header_transport = FakeOpenAIResponsesTransport.init(allocator);
    defer no_session_header_transport.deinit();
    var no_session_header = try runFakeOpenAIResponsesStream(&no_session_header_transport, proxy_model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-123" },
    }, null);
    defer no_session_header.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), no_session_header_transport.records.items[0].session_id);
    try std.testing.expectEqualStrings("session-123", no_session_header_transport.records.items[0].x_client_request_id.?);

    const override_headers = [_]types.Header{
        .{ .name = "session_id", .value = "override-session" },
        .{ .name = "x-client-request-id", .value = "override-request" },
    };
    var override_transport = FakeOpenAIResponsesTransport.init(allocator);
    defer override_transport.deinit();
    var override = try runFakeOpenAIResponsesStream(&override_transport, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-123", .headers = &override_headers },
    }, null);
    defer override.deinit();
    try std.testing.expectEqualStrings("override-session", override_transport.records.items[0].session_id.?);
    try std.testing.expectEqualStrings("override-request", override_transport.records.items[0].x_client_request_id.?);

    var none_transport = FakeOpenAIResponsesTransport.init(allocator);
    defer none_transport.deinit();
    var none = try runFakeOpenAIResponsesStream(&none_transport, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-123", .cache_retention = .none },
    }, null);
    defer none.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), none_transport.records.items[0].session_id);
    try std.testing.expectEqual(@as(?[]u8, null), none_transport.records.items[0].x_client_request_id);
}

// Ported from packages/ai/test/openai-responses-copilot-provider.test.ts.
test "OpenAI Responses clamps prompt cache key and applies service tier pricing" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("openai", "gpt-5.4") orelse return error.ModelMissing).*;

    var params = try buildParams(allocator, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" },
    }, null);
    defer params.deinit();
    try std.testing.expectEqual(@as(usize, 64), (getStringField(params.value, "prompt_cache_key") orelse return error.MissingPromptCacheKey).len);

    const response = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":1000000,\"total_tokens\":2000000,\"input_tokens_details\":{\"cached_tokens\":0}}}}\n\n";
    var parsed = try parseSseResponse(allocator, model, response, "priority");
    defer parsed.deinit();
    try std.testing.expectApproxEqAbs(model.cost.input * 2.0, parsed.result.message.usage.cost.input, 0.000001);
    try std.testing.expectApproxEqAbs(model.cost.output * 2.0, parsed.result.message.usage.cost.output, 0.000001);
    try std.testing.expectApproxEqAbs((model.cost.input + model.cost.output) * 2.0, parsed.result.message.usage.cost.total, 0.000001);

    const gpt55 = (models.getModel("openai", "gpt-5.5") orelse return error.ModelMissing).*;
    var parsed_gpt55 = try parseSseResponse(allocator, gpt55, response, "priority");
    defer parsed_gpt55.deinit();
    try std.testing.expectApproxEqAbs(gpt55.cost.input * 2.5, parsed_gpt55.result.message.usage.cost.input, 0.000001);
}

// Ported from packages/ai/test/cache-retention.test.ts (OpenAI Responses branch).
test "OpenAI Responses payload uses BULB cache retention and compatibility" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("BULB_CACHE_RETENTION", "long");

    var model = (models.getModel("openai", "gpt-4o-mini") orelse return error.ModelMissing).*;
    var env_params = try buildParams(allocator, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-env" },
    }, &env);
    defer env_params.deinit();
    try std.testing.expectEqualStrings("session-env", getStringField(env_params.value, "prompt_cache_key") orelse return error.MissingPromptCacheKey);
    try std.testing.expectEqualStrings("24h", getStringField(env_params.value, "prompt_cache_retention") orelse return error.MissingPromptCacheRetention);

    var none_params = try buildParams(allocator, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-none", .cache_retention = .none },
    }, &env);
    defer none_params.deinit();
    try std.testing.expect(none_params.value.object.get("prompt_cache_key") == null);
    try std.testing.expect(none_params.value.object.get("prompt_cache_retention") == null);

    model.base_url = "https://my-proxy.example.com/v1";
    var proxy_params = try buildParams(allocator, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-proxy" },
    }, &env);
    defer proxy_params.deinit();
    try std.testing.expectEqualStrings("24h", getStringField(proxy_params.value, "prompt_cache_retention") orelse return error.MissingPromptCacheRetention);

    model.compat.supports_long_cache_retention = false;
    var unsupported_params = try buildParams(allocator, model, basicContext(), .{
        .base = .{ .api_key = "test-key", .session_id = "session-compat-false", .cache_retention = .long },
    }, null);
    defer unsupported_params.deinit();
    try std.testing.expect(unsupported_params.value.object.get("prompt_cache_retention") == null);
}
