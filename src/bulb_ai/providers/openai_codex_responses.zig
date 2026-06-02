const std = @import("std");
const models = @import("../models.zig");
const openai_prompt_cache = @import("openai_prompt_cache.zig");
const openai_responses_shared = @import("openai_responses_shared.zig");
const simple_options = @import("simple_options.zig");
const sse = @import("../utils/sse.zig");
const types = @import("../types.zig");

pub const DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api";
const DEFAULT_MAX_RETRIES: u32 = 0;
const BASE_DELAY_MS: u64 = 1000;
const DEFAULT_MAX_RETRY_DELAY_MS: u64 = 60_000;

pub const ReasoningSummary = enum {
    auto,
    concise,
    detailed,
    off,
    on,

    fn jsonName(self: ReasoningSummary) []const u8 {
        return @tagName(self);
    }
};

pub const TextVerbosity = enum {
    low,
    medium,
    high,
};

pub const OpenAICodexResponsesOptions = struct {
    base: types.StreamOptions = .{},
    reasoning_effort: ?types.ThinkingLevel = null,
    reasoning_summary: ?ReasoningSummary = null,
    service_tier: ?[]const u8 = null,
    text_verbosity: TextVerbosity = .low,
    on_payload: ?PayloadObserver = null,
    on_response: ?ResponseObserver = null,
    transport: ?OpenAICodexResponsesTransport = null,
};

pub const OpenAICodexResponsesRequestOptions = struct {
    timeout_ms: ?u64 = null,
    max_retries: u32 = DEFAULT_MAX_RETRIES,
    max_retry_delay_ms: u64 = DEFAULT_MAX_RETRY_DELAY_MS,
};

pub const OpenAICodexResponsesHttpRequest = struct {
    url: []const u8,
    payload_json: []const u8,
    headers: []const types.Header,
    timeout_ms: ?u64 = null,
    attempt: u32 = 0,
    max_retries: u32 = DEFAULT_MAX_RETRIES,
    max_retry_delay_ms: u64 = DEFAULT_MAX_RETRY_DELAY_MS,
};

pub const OpenAICodexResponsesHttpResponse = struct {
    arena: std.heap.ArenaAllocator,
    status: u16,
    body: []const u8,
    headers: []const types.Header = &.{},

    pub fn deinit(self: *OpenAICodexResponsesHttpResponse) void {
        self.arena.deinit();
    }
};

pub const OpenAICodexResponsesResponseInfo = struct {
    status: u16,
    headers: []const types.Header = &.{},
};

pub const PayloadObserver = *const fn (payload: *std.json.Value, model: types.Model) anyerror!void;
pub const ResponseObserver = *const fn (response: OpenAICodexResponsesResponseInfo, model: types.Model) anyerror!void;
pub const OpenAICodexResponsesTransportFn = *const fn (
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAICodexResponsesHttpRequest,
) anyerror!OpenAICodexResponsesHttpResponse;

pub const OpenAICodexResponsesTransport = struct {
    ptr: *anyopaque,
    request: OpenAICodexResponsesTransportFn,

    pub fn send(
        self: OpenAICodexResponsesTransport,
        allocator: std.mem.Allocator,
        request: OpenAICodexResponsesHttpRequest,
    ) !OpenAICodexResponsesHttpResponse {
        return self.request(self.ptr, allocator, request);
    }
};

pub const ClientHeaderMap = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *ClientHeaderMap, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }

    pub fn getString(self: *const ClientHeaderMap, key: []const u8) ?[]const u8 {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) return entry.value_ptr.*;
        }
        return null;
    }
};

pub const OpenAICodexResponsesClientConfig = struct {
    arena: std.heap.ArenaAllocator,
    api_key: []const u8,
    account_id: []const u8,
    base_url: []const u8,
    request_url: []const u8,
    headers: ClientHeaderMap,
    request_options: OpenAICodexResponsesRequestOptions,

    pub fn deinit(self: *OpenAICodexResponsesClientConfig) void {
        self.headers.deinit(self.arena.allocator());
        self.arena.deinit();
    }
};

pub const BuiltCodexParams = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,

    pub fn deinit(self: *BuiltCodexParams) void {
        self.arena.deinit();
    }

    pub fn stringify(self: *const BuiltCodexParams, allocator: std.mem.Allocator) ![]u8 {
        return stringifyJsonValue(allocator, self.value);
    }
};

pub const ParsedStream = openai_responses_shared.ParsedResponsesStream;

pub fn streamOpenAICodexResponses(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?OpenAICodexResponsesOptions,
) !ParsedStream {
    var params = try buildParams(allocator, model, context, options);
    defer params.deinit();

    if (options) |opts| {
        if (opts.on_payload) |observer| try observer(&params.value, model);
    }

    const payload_json = try stringifyJsonValue(allocator, params.value);
    defer allocator.free(payload_json);

    var config = try buildClientConfig(allocator, model, options);
    defer config.deinit();

    var request_headers = try buildHttpHeaders(allocator, config);
    defer request_headers.deinit();

    var std_transport_state: StdOpenAICodexResponsesTransport = .{};
    const default_transport: OpenAICodexResponsesTransport = .{
        .ptr = &std_transport_state,
        .request = stdOpenAICodexResponsesTransportRequest,
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
            .max_retry_delay_ms = config.request_options.max_retry_delay_ms,
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

        if (isRetryableResponse(response.status, response.body) and attempt < config.request_options.max_retries) {
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

        const parsed = parseSseResponse(
            allocator,
            model,
            response.body,
            if (options) |opts| opts.service_tier else null,
        ) catch |err| {
            response.deinit();
            return err;
        };
        response.deinit();
        return parsed;
    }
}

pub fn streamSimpleOpenAICodexResponses(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?simple_options.SimpleStreamOptions,
    transport: ?OpenAICodexResponsesTransport,
) !ParsedStream {
    const codex_options = try buildSimpleOpenAICodexResponsesOptions(model, options);
    var with_transport = codex_options;
    with_transport.transport = transport;
    return streamOpenAICodexResponses(allocator, model, context, with_transport);
}

pub fn buildSimpleOpenAICodexResponsesOptions(
    model: types.Model,
    options: ?simple_options.SimpleStreamOptions,
) !OpenAICodexResponsesOptions {
    const api_key = if (options) |opts| opts.base.api_key else null;
    if (api_key == null) return error.NoApiKey;

    const reasoning = if (options) |opts| opts.reasoning else null;
    const clamped = if (reasoning) |level| models.clampThinkingLevel(model, level) else null;
    return .{
        .base = simple_options.buildBaseOptions(model, options, api_key),
        .reasoning_effort = if (clamped == .off) null else clamped,
    };
}

pub fn parseSseResponse(
    allocator: std.mem.Allocator,
    model: types.Model,
    body: []const u8,
    requested_service_tier: ?[]const u8,
) !ParsedStream {
    var decoded = try sse.decodeAll(allocator, body);
    defer decoded.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var events_json = std.ArrayList([]const u8).empty;
    defer events_json.deinit(allocator);
    var response_service_tier: ?[]const u8 = null;

    for (decoded.events) |event| {
        if (std.mem.eql(u8, std.mem.trim(u8, event.data, " \t\r\n"), "[DONE]")) break;
        if (event.data.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, a, event.data, .{}) catch
            return error.InvalidCodexSseJson;
        defer parsed.deinit();
        const event_type = getStringField(parsed.value, "type") orelse continue;

        if (eql(event_type, "response.completed") or
            eql(event_type, "response.done") or
            eql(event_type, "response.incomplete"))
        {
            if (getObjectField(parsed.value, "response")) |response| {
                response_service_tier = getStringField(response, "service_tier");
            }
        }

        const normalized = if (eql(event_type, "response.done") or eql(event_type, "response.incomplete"))
            try normalizeTerminalEvent(a, parsed.value)
        else
            try cloneJsonValue(a, parsed.value);
        try events_json.append(allocator, try std.json.Stringify.valueAlloc(a, normalized, .{}));

        if (isCodexTerminalEvent(event_type)) break;
    }

    var result = try openai_responses_shared.processResponsesEvents(allocator, model, events_json.items);
    if (resolveCodexServiceTier(response_service_tier, requested_service_tier)) |tier| {
        applyServiceTierPricing(&result.result.message.usage, tier, model);
    }
    return result;
}

pub fn buildParams(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?OpenAICodexResponsesOptions,
) !BuiltCodexParams {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var root = objectValue();
    try putString(a, &root, "model", model.id);
    try putBool(a, &root, "store", false);
    try putBool(a, &root, "stream", true);
    try putString(a, &root, "instructions", context.system_prompt orelse "You are a helpful assistant.");
    try putValue(a, &root, "input", try openai_responses_shared.convertResponsesMessagesValue(
        a,
        model,
        context,
        .{ .include_system_prompt = false },
    ));

    var text = objectValue();
    try putString(a, &text, "verbosity", @tagName(if (options) |opts| opts.text_verbosity else TextVerbosity.low));
    try putValue(a, &root, "text", text);

    var include = std.json.Array.init(a);
    try include.append(.{ .string = try a.dupe(u8, "reasoning.encrypted_content") });
    try putValue(a, &root, "include", .{ .array = include });

    const session_id = if (options) |opts| opts.base.session_id else null;
    if (try openai_prompt_cache.clampOpenAIPromptCacheKey(a, session_id)) |key| {
        try putOwnedString(a, &root, "prompt_cache_key", key);
    }
    try putString(a, &root, "tool_choice", "auto");
    try putBool(a, &root, "parallel_tool_calls", true);

    if (options) |opts| {
        if (opts.base.temperature) |temperature| try putFloat(a, &root, "temperature", temperature);
        if (opts.service_tier) |service_tier| try putString(a, &root, "service_tier", service_tier);
    }

    if (context.tools.len > 0) {
        try putValue(a, &root, "tools", try openai_responses_shared.convertResponsesToolsValue(
            a,
            context.tools,
            .{ .strict = .null },
        ));
    }

    try applyReasoningOptions(a, &root, model, options);
    return .{ .arena = arena, .value = root };
}

pub fn buildClientConfig(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?OpenAICodexResponsesOptions,
) !OpenAICodexResponsesClientConfig {
    const base_options = if (options) |opts| opts.base else types.StreamOptions{};
    const api_key = base_options.api_key orelse return error.NoApiKey;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const account_id = try extractAccountId(a, api_key);
    const resolved_base_url = try a.dupe(u8, if (std.mem.trim(u8, model.base_url, " \t\r\n").len == 0)
        DEFAULT_CODEX_BASE_URL
    else
        model.base_url);
    const request_url = try resolveCodexUrl(a, resolved_base_url);
    const headers = try buildSseHeaderMap(a, model.headers, base_options.headers, account_id, api_key, base_options.session_id);

    return .{
        .arena = arena,
        .api_key = try a.dupe(u8, api_key),
        .account_id = account_id,
        .base_url = resolved_base_url,
        .request_url = request_url,
        .headers = headers,
        .request_options = .{
            .timeout_ms = base_options.timeout_ms,
            .max_retries = base_options.max_retries orelse DEFAULT_MAX_RETRIES,
            .max_retry_delay_ms = base_options.max_retry_delay_ms orelse DEFAULT_MAX_RETRY_DELAY_MS,
        },
    };
}

pub fn resolveCodexUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const raw = if (std.mem.trim(u8, base_url, " \t\r\n").len == 0) DEFAULT_CODEX_BASE_URL else base_url;
    const normalized = std.mem.trimEnd(u8, raw, "/");
    if (std.mem.endsWith(u8, normalized, "/codex/responses")) return allocator.dupe(u8, normalized);
    if (std.mem.endsWith(u8, normalized, "/codex")) return std.fmt.allocPrint(allocator, "{s}/responses", .{normalized});
    return std.fmt.allocPrint(allocator, "{s}/codex/responses", .{normalized});
}

pub fn resolveCodexWebSocketUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const url = try resolveCodexUrl(allocator, base_url);
    defer allocator.free(url);
    if (std.mem.startsWith(u8, url, "https://")) return std.fmt.allocPrint(allocator, "wss://{s}", .{url["https://".len..]});
    if (std.mem.startsWith(u8, url, "http://")) return std.fmt.allocPrint(allocator, "ws://{s}", .{url["http://".len..]});
    return allocator.dupe(u8, url);
}

pub fn extractAccountId(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidCodexToken;
    const payload = parts.next() orelse return error.InvalidCodexToken;
    _ = parts.next() orelse return error.InvalidCodexToken;
    if (parts.next() != null) return error.InvalidCodexToken;

    const is_url_safe = std.mem.indexOfAny(u8, payload, "-_") != null;
    const is_padded = std.mem.endsWith(u8, payload, "=");
    const decoder = if (is_url_safe)
        if (is_padded) std.base64.url_safe.Decoder else std.base64.url_safe_no_pad.Decoder
    else if (is_padded)
        std.base64.standard.Decoder
    else
        std.base64.standard_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload) catch return error.InvalidCodexToken;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    decoder.decode(decoded, payload) catch return error.InvalidCodexToken;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return error.InvalidCodexToken;
    defer parsed.deinit();
    const auth = getObjectField(parsed.value, "https://api.openai.com/auth") orelse return error.InvalidCodexToken;
    const account_id = getStringField(auth, "chatgpt_account_id") orelse return error.InvalidCodexToken;
    return allocator.dupe(u8, account_id);
}

pub fn retryDelayMs(
    attempt: u32,
    retry_after_ms: ?u64,
    status: u16,
    max_retry_delay_ms: u64,
) u64 {
    const shift: u6 = @intCast(@min(attempt, 31));
    const exponential = BASE_DELAY_MS << shift;
    const requested = retry_after_ms orelse exponential;
    if (status != 429 or max_retry_delay_ms == 0) return requested;
    return @min(requested, max_retry_delay_ms);
}

fn buildSseHeaderMap(
    allocator: std.mem.Allocator,
    model_headers: []const types.Header,
    additional_headers: []const types.Header,
    account_id: []const u8,
    token: []const u8,
    session_id: ?[]const u8,
) !ClientHeaderMap {
    var headers: ClientHeaderMap = .{};
    errdefer headers.deinit(allocator);

    for (model_headers) |header| try putClientHeader(allocator, &headers, header.name, header.value);
    for (additional_headers) |header| try putClientHeader(allocator, &headers, header.name, header.value);

    try putClientHeader(allocator, &headers, "Authorization", try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}));
    try putClientHeader(allocator, &headers, "chatgpt-account-id", account_id);
    try putClientHeader(allocator, &headers, "originator", "bulb");
    try putClientHeader(allocator, &headers, "User-Agent", "bulb (native Zig)");
    try putClientHeader(allocator, &headers, "OpenAI-Beta", "responses=experimental");
    try putClientHeader(allocator, &headers, "Accept", "text/event-stream");
    try putClientHeader(allocator, &headers, "Content-Type", "application/json");

    if (session_id) |id| {
        try putClientHeader(allocator, &headers, "session-id", id);
        try putClientHeader(allocator, &headers, "x-client-request-id", id);
    }
    return headers;
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

fn buildHttpHeaders(allocator: std.mem.Allocator, config: OpenAICodexResponsesClientConfig) !OwnedHeaderList {
    var headers = std.ArrayList(types.Header).empty;
    errdefer {
        deinitHeaderItems(allocator, headers.items);
        headers.deinit(allocator);
    }

    var iterator = config.headers.map.iterator();
    while (iterator.next()) |entry| {
        try appendHeader(allocator, &headers, entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .allocator = allocator, .headers = try headers.toOwnedSlice(allocator) };
}

fn putClientHeader(allocator: std.mem.Allocator, headers: *ClientHeaderMap, key: []const u8, value: []const u8) !void {
    var iterator = headers.map.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) {
            entry.value_ptr.* = try allocator.dupe(u8, value);
            return;
        }
    }
    try headers.map.put(allocator, try allocator.dupe(u8, key), try allocator.dupe(u8, value));
}

fn appendHeader(allocator: std.mem.Allocator, headers: *std.ArrayList(types.Header), name: []const u8, value: []const u8) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try headers.append(allocator, .{ .name = owned_name, .value = owned_value });
}

fn deinitHeaderItems(allocator: std.mem.Allocator, headers: []types.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

fn normalizeTerminalEvent(allocator: std.mem.Allocator, event: std.json.Value) !std.json.Value {
    var normalized = try cloneJsonValue(allocator, event);
    try normalized.object.put(allocator, try allocator.dupe(u8, "type"), .{
        .string = try allocator.dupe(u8, "response.completed"),
    });
    return normalized;
}

fn isCodexTerminalEvent(event_type: []const u8) bool {
    return eql(event_type, "response.done") or
        eql(event_type, "response.completed") or
        eql(event_type, "response.incomplete") or
        eql(event_type, "response.failed") or
        eql(event_type, "error");
}

fn applyReasoningOptions(
    allocator: std.mem.Allocator,
    params: *std.json.Value,
    model: types.Model,
    options: ?OpenAICodexResponsesOptions,
) !void {
    const effort = if (options) |opts| opts.reasoning_effort else null;
    if (effort == null) return;

    const level = effort.?;
    var reasoning = objectValue();
    try putString(allocator, &reasoning, "effort", thinkingLevelValue(model, level));
    try putString(allocator, &reasoning, "summary", if (options.?.reasoning_summary) |summary| summary.jsonName() else "auto");
    try putValue(allocator, params, "reasoning", reasoning);
}

fn thinkingLevelValue(model: types.Model, level: types.ThinkingLevel) []const u8 {
    return switch (model.thinking_level_map.get(level)) {
        .mapped => |value| value,
        else => switch (level) {
            .off => "none",
            else => @tagName(level),
        },
    };
}

fn resolveCodexServiceTier(response_tier: ?[]const u8, request_tier: ?[]const u8) ?[]const u8 {
    if (response_tier) |tier| {
        if (eql(tier, "default")) {
            if (request_tier) |requested| {
                if (eql(requested, "flex") or eql(requested, "priority")) return requested;
            }
        }
        return tier;
    }
    return request_tier;
}

fn applyServiceTierPricing(usage: *types.Usage, service_tier: []const u8, model: types.Model) void {
    const multiplier = serviceTierCostMultiplier(model, service_tier);
    if (multiplier == 1) return;
    usage.cost.input *= multiplier;
    usage.cost.output *= multiplier;
    usage.cost.cache_read *= multiplier;
    usage.cost.cache_write *= multiplier;
    usage.cost.calculateTotal();
}

fn serviceTierCostMultiplier(model: types.Model, service_tier: []const u8) f64 {
    if (eql(service_tier, "flex")) return 0.5;
    if (eql(service_tier, "priority")) return if (eql(model.id, "gpt-5.5")) 2.5 else 2;
    return 1;
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
    try events.append(allocator, .{ .@"error" = .{ .reason = reason, .message = output } });
    return .{
        .arena = arena,
        .result = .{ .allocator = allocator, .events = events, .message = output },
    };
}

fn httpErrorMessage(allocator: std.mem.Allocator, status: u16, body: []const u8) ![]const u8 {
    if (status == 429) return allocator.dupe(u8, "You have hit your ChatGPT usage limit.");
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return std.fmt.allocPrint(allocator, "HTTP {d}", .{status});
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, trimmed });
}

fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

fn isRetryableResponse(status: u16, body: []const u8) bool {
    if (status == 429 and isTerminalRateLimitError(body)) return false;
    if (status == 429 or status == 500 or status == 502 or status == 503 or status == 504) return true;
    return containsIgnoreCase(body, "rate limit") or
        containsIgnoreCase(body, "rate-limit") or
        containsIgnoreCase(body, "overloaded") or
        containsIgnoreCase(body, "service unavailable") or
        containsIgnoreCase(body, "upstream connect") or
        containsIgnoreCase(body, "connection refused");
}

fn isTerminalRateLimitError(body: []const u8) bool {
    return containsIgnoreCase(body, "GoUsageLimitError") or
        containsIgnoreCase(body, "FreeUsageLimitError") or
        containsIgnoreCase(body, "Monthly usage limit reached") or
        containsIgnoreCase(body, "available balance") or
        containsIgnoreCase(body, "insufficient_quota") or
        containsIgnoreCase(body, "out of budget") or
        containsIgnoreCase(body, "quota exceeded") or
        containsIgnoreCase(body, "billing");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn isRetryableTransportError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory => false,
        else => true,
    };
}

fn isAborted(options: types.StreamOptions) bool {
    return if (options.signal) |signal| signal.aborted else false;
}

const StdOpenAICodexResponsesTransport = struct {};

fn stdOpenAICodexResponsesTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAICodexResponsesHttpRequest,
) anyerror!OpenAICodexResponsesHttpResponse {
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
        .headers = .{ .authorization = .omit, .content_type = .omit },
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
    return .{ .arena = arena, .status = @intFromEnum(result.status), .body = body };
}

fn stdHttpHeaders(allocator: std.mem.Allocator, headers: []const types.Header) ![]std.http.Header {
    const result = try allocator.alloc(std.http.Header, headers.len);
    for (headers, 0..) |header, index| {
        result[index] = .{ .name = header.name, .value = header.value };
    }
    return result;
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stream.write(value);
    return out.toOwnedSlice();
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

fn putBool(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: bool) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
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

const codex_done_sse =
    "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
    "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}\n\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8,\"input_tokens_details\":{\"cached_tokens\":0}}}}\n\n";

const RecordedCodexRequest = struct {
    attempt: u32,
    max_retries: u32,
    timeout_ms: ?u64,
    url: []u8,
    payload_json: []u8,
    authorization: ?[]u8 = null,
    account_id: ?[]u8 = null,
    originator: ?[]u8 = null,
    session_id: ?[]u8 = null,
    x_client_request_id: ?[]u8 = null,

    fn deinit(self: *RecordedCodexRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.payload_json);
        if (self.authorization) |value| allocator.free(value);
        if (self.account_id) |value| allocator.free(value);
        if (self.originator) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
        if (self.x_client_request_id) |value| allocator.free(value);
    }
};

const FakeCodexTransport = struct {
    allocator: std.mem.Allocator,
    statuses: []const u16 = &.{200},
    body: []const u8 = codex_done_sse,
    records: std.ArrayList(RecordedCodexRequest) = .empty,

    fn init(allocator: std.mem.Allocator) FakeCodexTransport {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakeCodexTransport) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    fn transport(self: *FakeCodexTransport) OpenAICodexResponsesTransport {
        return .{ .ptr = self, .request = fakeCodexTransportRequest };
    }

    fn statusForAttempt(self: *const FakeCodexTransport, attempt: u32) u16 {
        if (self.statuses.len == 0) return 200;
        return self.statuses[@min(attempt, self.statuses.len - 1)];
    }
};

fn fakeCodexTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAICodexResponsesHttpRequest,
) anyerror!OpenAICodexResponsesHttpResponse {
    const state: *FakeCodexTransport = @ptrCast(@alignCast(ptr));
    var record: RecordedCodexRequest = .{
        .attempt = request.attempt,
        .max_retries = request.max_retries,
        .timeout_ms = request.timeout_ms,
        .url = try state.allocator.dupe(u8, request.url),
        .payload_json = try state.allocator.dupe(u8, request.payload_json),
    };
    if (findHeader(request.headers, "Authorization")) |value| record.authorization = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "chatgpt-account-id")) |value| record.account_id = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "originator")) |value| record.originator = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "session-id")) |value| record.session_id = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "x-client-request-id")) |value| record.x_client_request_id = try state.allocator.dupe(u8, value);
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

fn mockToken(allocator: std.mem.Allocator) ![]u8 {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acc_test\"}}";
    const encoded_len = std.base64.standard_no_pad.Encoder.calcSize(payload.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "aaa.{s}.bbb", .{encoded});
}

const basic_user_content = [_]types.UserContent{.{ .text = .{ .text = "Say hello" } }};
const basic_messages = [_]types.Message{.{ .user = .{ .content = &basic_user_content, .timestamp_ms = 1 } }};
const basic_tools = [_]types.Tool{.{
    .name = "read",
    .description = "Read a file",
    .parameters_json = "{\"type\":\"object\"}",
}};

fn basicContext() types.Context {
    return .{ .system_prompt = "System prompt", .messages = &basic_messages };
}

test "OpenAI Codex Responses builds subscription payload contract" {
    const allocator = std.testing.allocator;
    var params = try buildParams(allocator, .{
        .id = "gpt-5.5",
        .name = "GPT-5.5",
        .api = types.api.openai_codex_responses,
        .provider = "openai-codex",
        .base_url = DEFAULT_CODEX_BASE_URL,
        .reasoning = true,
        .thinking_level_map = .{ .minimal = .{ .mapped = "low" } },
    }, .{
        .system_prompt = "System prompt",
        .messages = &basic_messages,
        .tools = &basic_tools,
    }, .{
        .base = .{
            .api_key = "unused",
            .session_id = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            .temperature = 0.25,
        },
        .reasoning_effort = .minimal,
        .service_tier = "priority",
        .text_verbosity = .high,
    });
    defer params.deinit();

    try std.testing.expectEqualStrings("gpt-5.5", getStringField(params.value, "model").?);
    try std.testing.expectEqualStrings("System prompt", getStringField(params.value, "instructions").?);
    try std.testing.expectEqualStrings("auto", getStringField(params.value, "tool_choice").?);
    try std.testing.expectEqual(@as(usize, 64), getStringField(params.value, "prompt_cache_key").?.len);
    try std.testing.expectEqualStrings("priority", getStringField(params.value, "service_tier").?);
    try std.testing.expectEqualStrings("high", getStringField(getObjectField(params.value, "text").?, "verbosity").?);
    try std.testing.expectEqualStrings("low", getStringField(getObjectField(params.value, "reasoning").?, "effort").?);
    try std.testing.expectEqualStrings("auto", getStringField(getObjectField(params.value, "reasoning").?, "summary").?);
    try std.testing.expect(params.value.object.get("parallel_tool_calls").?.bool);
    try std.testing.expect(!params.value.object.get("store").?.bool);
    try std.testing.expect(params.value.object.get("stream").?.bool);
    try std.testing.expectEqual(@as(usize, 1), params.value.object.get("input").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), params.value.object.get("tools").?.array.items.len);
    try std.testing.expect(params.value.object.get("tools").?.array.items[0].object.get("strict").? == .null);
}

test "OpenAI Codex Responses resolves URLs and extracts account ID" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const account_id = try extractAccountId(allocator, token);
    defer allocator.free(account_id);
    try std.testing.expectEqualStrings("acc_test", account_id);
    try std.testing.expectError(error.InvalidCodexToken, extractAccountId(allocator, "not-a-jwt"));

    const root = try resolveCodexUrl(allocator, DEFAULT_CODEX_BASE_URL);
    defer allocator.free(root);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", root);
    const codex = try resolveCodexUrl(allocator, "https://proxy.example/codex/");
    defer allocator.free(codex);
    try std.testing.expectEqualStrings("https://proxy.example/codex/responses", codex);
    const complete = try resolveCodexUrl(allocator, "https://proxy.example/codex/responses/");
    defer allocator.free(complete);
    try std.testing.expectEqualStrings("https://proxy.example/codex/responses", complete);
    const websocket = try resolveCodexWebSocketUrl(allocator, DEFAULT_CODEX_BASE_URL);
    defer allocator.free(websocket);
    try std.testing.expectEqualStrings("wss://chatgpt.com/backend-api/codex/responses", websocket);
}

test "OpenAI Codex Responses sends Bulb subscription headers and session affinity" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;
    var config = try buildClientConfig(allocator, model, .{ .base = .{
        .api_key = token,
        .session_id = "session-123",
        .timeout_ms = 99,
        .max_retries = 2,
    } });
    defer config.deinit();

    try std.testing.expectEqualStrings("acc_test", config.account_id);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", config.request_url);
    try std.testing.expectEqualStrings("Bearer ", config.headers.getString("Authorization").?[0.."Bearer ".len]);
    try std.testing.expectEqualStrings("acc_test", config.headers.getString("chatgpt-account-id").?);
    try std.testing.expectEqualStrings("bulb", config.headers.getString("originator").?);
    try std.testing.expectEqualStrings("responses=experimental", config.headers.getString("OpenAI-Beta").?);
    try std.testing.expectEqualStrings("session-123", config.headers.getString("session-id").?);
    try std.testing.expectEqualStrings("session-123", config.headers.getString("x-client-request-id").?);
    try std.testing.expectEqual(@as(?u64, 99), config.request_options.timeout_ms);
    try std.testing.expectEqual(@as(u32, 2), config.request_options.max_retries);
}

test "OpenAI Codex Responses maps terminal events and service tiers" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;
    const response =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"content\":[]}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}\n\n" ++
        "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"service_tier\":\"default\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":1000000,\"total_tokens\":2000000,\"input_tokens_details\":{\"cached_tokens\":0}}}}\n\n" ++
        "data: {broken trailing event}\n\n";
    var parsed = try parseSseResponse(allocator, model, response, "priority");
    defer parsed.deinit();
    try std.testing.expectEqual(types.StopReason.length, parsed.result.message.stop_reason);
    try std.testing.expectEqualStrings("Hello", parsed.result.message.content[0].text.text);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), parsed.result.message.usage.cost.input, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 75), parsed.result.message.usage.cost.output, 0.000001);
}

test "OpenAI Codex Responses streams SSE through retrying native transport contract" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    var transport = FakeCodexTransport.init(allocator);
    defer transport.deinit();
    transport.statuses = &.{ 429, 200 };

    var parsed = try streamOpenAICodexResponses(allocator, model, basicContext(), .{
        .base = .{
            .api_key = token,
            .session_id = "session-123",
            .timeout_ms = 1234,
            .max_retries = 1,
        },
        .transport = transport.transport(),
    });
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.stop, parsed.result.message.stop_reason);
    try std.testing.expectEqualStrings("Hello", parsed.result.message.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 2), transport.records.items.len);
    try std.testing.expectEqual(@as(u32, 0), transport.records.items[0].attempt);
    try std.testing.expectEqual(@as(u32, 1), transport.records.items[1].attempt);
    try std.testing.expectEqualStrings("acc_test", transport.records.items[0].account_id.?);
    try std.testing.expectEqualStrings("bulb", transport.records.items[0].originator.?);
    try std.testing.expectEqualStrings("session-123", transport.records.items[0].session_id.?);
}

test "OpenAI Codex Responses simple options preserve supported xhigh and omit off" {
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;
    const xhigh = try buildSimpleOpenAICodexResponsesOptions(model, .{
        .base = .{ .api_key = "test-token" },
        .reasoning = .xhigh,
    });
    try std.testing.expectEqual(types.ThinkingLevel.xhigh, xhigh.reasoning_effort.?);

    const off = try buildSimpleOpenAICodexResponsesOptions(model, .{
        .base = .{ .api_key = "test-token" },
        .reasoning = .off,
    });
    try std.testing.expectEqual(@as(?types.ThinkingLevel, null), off.reasoning_effort);
}

test "OpenAI Codex Responses retry policy caps rate limit hints" {
    try std.testing.expectEqual(@as(u64, 1000), retryDelayMs(0, null, 429, DEFAULT_MAX_RETRY_DELAY_MS));
    try std.testing.expectEqual(@as(u64, 2000), retryDelayMs(1, null, 429, DEFAULT_MAX_RETRY_DELAY_MS));
    try std.testing.expectEqual(@as(u64, 60_000), retryDelayMs(0, 120_000, 429, DEFAULT_MAX_RETRY_DELAY_MS));
    try std.testing.expectEqual(@as(u64, 120_000), retryDelayMs(0, 120_000, 503, DEFAULT_MAX_RETRY_DELAY_MS));
    try std.testing.expect(!isRetryableResponse(429, "Monthly usage limit reached"));
    try std.testing.expect(isRetryableResponse(429, "rate limited"));
}
