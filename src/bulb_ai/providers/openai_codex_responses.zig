const std = @import("std");
const models = @import("../models.zig");
const openai_prompt_cache = @import("openai_prompt_cache.zig");
const openai_responses_shared = @import("openai_responses_shared.zig");
const simple_options = @import("simple_options.zig");
const sse = @import("../utils/sse.zig");
const types = @import("../types.zig");

pub const DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api";
pub const OPENAI_BETA_RESPONSES_WEBSOCKETS = "responses_websockets=2026-02-06";
pub const SESSION_WEBSOCKET_CACHE_TTL_MS: u64 = 5 * 60 * 1000;
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
    on_retry_delay: ?RetryDelayObserver = null,
    retry_sleeper: ?RetrySleeper = null,
    transport: ?OpenAICodexResponsesTransport = null,
    websocket_transport: ?OpenAICodexWebSocketTransport = null,
    websocket_cache_entry: ?*OpenAICodexWebSocketCacheEntry = null,
    websocket_stats: ?*OpenAICodexWebSocketDebugStats = null,
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
pub const RetryDelaySource = enum {
    response,
    transport,
};
pub const RetryDelayInfo = struct {
    attempt: u32,
    delay_ms: u64,
    status: ?u16 = null,
    retry_after_ms: ?u64 = null,
    source: RetryDelaySource,
};
pub const RetryDelayObserver = *const fn (info: RetryDelayInfo, model: types.Model) anyerror!void;
pub const RetrySleeperFn = *const fn (ptr: ?*anyopaque, delay_ms: u64, signal: ?*types.AbortSignal) anyerror!void;
pub const RetrySleeper = struct {
    ptr: ?*anyopaque = null,
    sleep: RetrySleeperFn,

    pub fn wait(self: RetrySleeper, delay_ms: u64, signal: ?*types.AbortSignal) !void {
        return self.sleep(self.ptr, delay_ms, signal);
    }
};
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

pub const OpenAICodexWebSocketFailurePhase = enum {
    before_message_stream_start,
    after_message_stream_start,
};

pub const OpenAICodexWebSocketFailure = struct {
    message: []const u8,
    phase: OpenAICodexWebSocketFailurePhase,
};

pub const OpenAICodexWebSocketResult = union(enum) {
    events_json: []const []const u8,
    failure: OpenAICodexWebSocketFailure,
};

pub const OpenAICodexWebSocketRequest = struct {
    url: []const u8,
    payload_json: []const u8,
    headers: []const types.Header,
    session_id: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    connect_timeout_ms: ?u64 = null,
    cached_context: bool = false,
};

pub const OpenAICodexWebSocketResponse = struct {
    arena: std.heap.ArenaAllocator,
    result: OpenAICodexWebSocketResult,

    pub fn deinit(self: *OpenAICodexWebSocketResponse) void {
        self.arena.deinit();
    }
};

pub const OpenAICodexWebSocketTransportFn = *const fn (
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAICodexWebSocketRequest,
) anyerror!OpenAICodexWebSocketResponse;

pub const OpenAICodexWebSocketTransport = struct {
    ptr: *anyopaque,
    request: OpenAICodexWebSocketTransportFn,

    pub fn send(
        self: OpenAICodexWebSocketTransport,
        allocator: std.mem.Allocator,
        request: OpenAICodexWebSocketRequest,
    ) !OpenAICodexWebSocketResponse {
        return self.request(self.ptr, allocator, request);
    }
};

pub const ClientHeaderMap = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *ClientHeaderMap, allocator: std.mem.Allocator) void {
        var iterator = self.map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
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

pub const OpenAICodexWebSocketDebugStats = struct {
    requests: u64 = 0,
    connections_created: u64 = 0,
    connections_reused: u64 = 0,
    cached_context_requests: u64 = 0,
    store_true_requests: u64 = 0,
    full_context_requests: u64 = 0,
    delta_requests: u64 = 0,
    last_input_items: usize = 0,
    last_delta_input_items: ?usize = null,
    last_previous_response_id: ?[]const u8 = null,
    websocket_failures: u64 = 0,
    sse_fallbacks: u64 = 0,
    websocket_fallback_active: bool = false,
    last_websocket_error: ?[]const u8 = null,
};

pub const CachedWebSocketContinuationState = struct {
    arena: std.heap.ArenaAllocator,
    last_request_body: std.json.Value,
    last_response_id: []const u8,
    last_response_items: std.json.Value,

    pub fn deinit(self: *CachedWebSocketContinuationState) void {
        self.arena.deinit();
    }
};

pub const OpenAICodexWebSocketCacheEntry = struct {
    busy: bool = false,
    continuation: ?CachedWebSocketContinuationState = null,

    pub fn deinit(self: *OpenAICodexWebSocketCacheEntry) void {
        self.clearContinuation();
    }

    pub fn clearContinuation(self: *OpenAICodexWebSocketCacheEntry) void {
        if (self.continuation) |*continuation| continuation.deinit();
        self.continuation = null;
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

const WebSocketStreamAttempt = union(enum) {
    parsed: ParsedStream,
    fallback_to_sse: void,
};

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

    const stream_transport = base_options.transport orelse .auto;
    if (stream_transport != .sse) {
        const websocket_attempt = try streamOpenAICodexResponsesWebSocket(
            allocator,
            model,
            params.value,
            config,
            base_options,
            options,
        );
        switch (websocket_attempt) {
            .parsed => |parsed| return parsed,
            .fallback_to_sse => {},
        }
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
                const delay_ms = retryDelayMs(attempt, null, 0, config.request_options.max_retry_delay_ms);
                try notifyRetryDelay(options, .{
                    .attempt = attempt,
                    .delay_ms = delay_ms,
                    .source = .transport,
                }, model);
                sleepForRetry(options, delay_ms, base_options.signal) catch |sleep_err| {
                    return terminalParsedStream(
                        allocator,
                        model,
                        retrySleepStopReason(sleep_err),
                        retrySleepErrorMessage(sleep_err),
                    );
                };
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
            const retry_after_ms = retryAfterDelayMs(response.headers, currentUnixMillis());
            const delay_ms = retryDelayMs(
                attempt,
                retry_after_ms,
                response.status,
                config.request_options.max_retry_delay_ms,
            );
            try notifyRetryDelay(options, .{
                .attempt = attempt,
                .delay_ms = delay_ms,
                .status = response.status,
                .retry_after_ms = retry_after_ms,
                .source = .response,
            }, model);
            attempt += 1;
            response.deinit();
            sleepForRetry(options, delay_ms, base_options.signal) catch |sleep_err| {
                return terminalParsedStream(
                    allocator,
                    model,
                    retrySleepStopReason(sleep_err),
                    retrySleepErrorMessage(sleep_err),
                );
            };
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

fn streamOpenAICodexResponsesWebSocket(
    allocator: std.mem.Allocator,
    model: types.Model,
    full_body: std.json.Value,
    config: OpenAICodexResponsesClientConfig,
    base_options: types.StreamOptions,
    options: ?OpenAICodexResponsesOptions,
) !WebSocketStreamAttempt {
    const opts = options orelse return .{ .fallback_to_sse = {} };
    const websocket_transport = opts.websocket_transport orelse {
        recordWebSocketFallbackFailure(opts.websocket_stats, "WebSocket transport is not available in this runtime");
        return .{ .fallback_to_sse = {} };
    };

    const stream_transport = base_options.transport orelse .auto;
    const use_cached_context = usesCachedWebSocketContext(stream_transport);
    const request_id = base_options.session_id orelse try createCodexRequestId(allocator);
    defer if (base_options.session_id == null) allocator.free(request_id);

    var websocket_headers = try buildWebSocketHeaderMap(
        allocator,
        model.headers,
        base_options.headers,
        config.account_id,
        config.api_key,
        request_id,
    );
    defer websocket_headers.deinit(allocator);

    var owned_headers = try ownedHeadersFromClientHeaderMap(allocator, &websocket_headers);
    defer owned_headers.deinit();

    const websocket_url = try resolveCodexWebSocketUrl(allocator, config.base_url);
    defer allocator.free(websocket_url);

    var cached_body: ?BuiltCodexParams = null;
    defer if (cached_body) |*body| body.deinit();
    const request_body = if (use_cached_context) blk: {
        if (opts.websocket_cache_entry) |entry| {
            cached_body = try buildCachedWebSocketRequestBody(allocator, entry, full_body);
            break :blk cached_body.?.value;
        }
        break :blk full_body;
    } else full_body;

    if (opts.websocket_stats) |stats| {
        const reused = if (opts.websocket_cache_entry) |entry| entry.continuation != null else false;
        recordWebSocketRequestStats(stats, request_body, reused, use_cached_context);
    }

    var create_payload = try buildWebSocketCreatePayload(allocator, request_body);
    defer create_payload.deinit();
    const payload_json = try create_payload.stringify(allocator);
    defer allocator.free(payload_json);

    var response = websocket_transport.send(allocator, .{
        .url = websocket_url,
        .payload_json = payload_json,
        .headers = owned_headers.headers,
        .session_id = base_options.session_id,
        .timeout_ms = base_options.timeout_ms,
        .connect_timeout_ms = base_options.websocket_connect_timeout_ms,
        .cached_context = use_cached_context,
    }) catch |err| {
        recordWebSocketFallbackFailure(opts.websocket_stats, @errorName(err));
        return .{ .fallback_to_sse = {} };
    };
    defer response.deinit();

    switch (response.result) {
        .failure => |failure| {
            recordWebSocketFailureForPhase(opts.websocket_stats, failure);
            if (failure.phase == .before_message_stream_start) {
                recordWebSocketSseFallbackMaybe(opts.websocket_stats);
                return .{ .fallback_to_sse = {} };
            }
            return .{ .parsed = try terminalParsedStream(allocator, model, .@"error", failure.message) };
        },
        .events_json => |events_json| {
            if (!webSocketEventsHaveCompletion(allocator, events_json)) {
                const message = "WebSocket stream closed before response.completed";
                const phase: OpenAICodexWebSocketFailurePhase = if (events_json.len == 0)
                    .before_message_stream_start
                else
                    .after_message_stream_start;
                const failure: OpenAICodexWebSocketFailure = .{ .message = message, .phase = phase };
                recordWebSocketFailureForPhase(opts.websocket_stats, failure);
                if (phase == .before_message_stream_start) {
                    recordWebSocketSseFallbackMaybe(opts.websocket_stats);
                    return .{ .fallback_to_sse = {} };
                }
                return .{ .parsed = try terminalParsedStream(allocator, model, .@"error", message) };
            }

            var normalized_events = try normalizeCodexWebSocketEvents(allocator, events_json);
            defer normalized_events.deinit();
            var parsed = openai_responses_shared.processResponsesEvents(allocator, model, normalized_events.items.items) catch |err| {
                return .{ .parsed = try terminalParsedStream(allocator, model, .@"error", @errorName(err)) };
            };
            errdefer parsed.deinit();
            try applyWebSocketServiceTier(allocator, &parsed, model, normalized_events.items.items, opts.service_tier);
            if (use_cached_context) {
                if (opts.websocket_cache_entry) |entry| {
                    if (!isAborted(base_options)) {
                        try storeWebSocketContinuation(allocator, entry, model, full_body, parsed.result.message);
                    }
                }
            }
            return .{ .parsed = parsed };
        },
    }
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

fn createCodexRequestId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    return std.fmt.allocPrint(
        allocator,
        "codex_{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15],
        },
    );
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

pub fn retryAfterDelayMs(headers: []const types.Header, now_ms: i64) ?u64 {
    if (findHeader(headers, "retry-after-ms")) |value| {
        if (parseNonNegativeMillis(value, 1)) |millis| return millis;
    }

    const retry_after = findHeader(headers, "retry-after") orelse return null;
    if (parseNonNegativeMillis(retry_after, 1000)) |millis| return millis;
    const date_ms = parseHttpDateMs(retry_after) orelse return null;
    return if (date_ms <= now_ms) 0 else @intCast(date_ms - now_ms);
}

fn notifyRetryDelay(
    options: ?OpenAICodexResponsesOptions,
    info: RetryDelayInfo,
    model: types.Model,
) !void {
    if (options) |opts| {
        if (opts.on_retry_delay) |observer| try observer(info, model);
    }
}

fn sleepForRetry(
    options: ?OpenAICodexResponsesOptions,
    delay_ms: u64,
    signal: ?*types.AbortSignal,
) !void {
    if (options) |opts| {
        if (opts.retry_sleeper) |sleeper| return sleeper.wait(delay_ms, signal);
    }
    return defaultRetrySleep(null, delay_ms, signal);
}

fn defaultRetrySleep(_: ?*anyopaque, delay_ms: u64, signal: ?*types.AbortSignal) !void {
    if (signal) |abort_signal| {
        if (abort_signal.aborted) return error.Aborted;
    }
    if (delay_ms > 0) {
        const io = std.Io.Threaded.global_single_threaded.io();
        const capped_ms = std.math.cast(i64, delay_ms) orelse std.math.maxInt(i64);
        try std.Io.sleep(io, .fromMilliseconds(capped_ms), .awake);
    }
    if (signal) |abort_signal| {
        if (abort_signal.aborted) return error.Aborted;
    }
}

fn currentUnixMillis() i64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn retrySleepStopReason(err: anyerror) types.StopReason {
    return if (err == error.Aborted) .aborted else .@"error";
}

fn retrySleepErrorMessage(err: anyerror) []const u8 {
    return if (err == error.Aborted) "Request was aborted" else @errorName(err);
}

fn recordWebSocketFallbackFailure(stats: ?*OpenAICodexWebSocketDebugStats, message: []const u8) void {
    if (stats) |value| {
        recordWebSocketFailure(value, message);
        recordWebSocketSseFallback(value, true);
    }
}

fn recordWebSocketFailureForPhase(
    stats: ?*OpenAICodexWebSocketDebugStats,
    failure: OpenAICodexWebSocketFailure,
) void {
    if (stats) |value| recordWebSocketFailure(value, failure.message);
}

fn recordWebSocketSseFallbackMaybe(stats: ?*OpenAICodexWebSocketDebugStats) void {
    if (stats) |value| recordWebSocketSseFallback(value, true);
}

const OwnedJsonEventList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *OwnedJsonEventList) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }

    fn appendOwned(self: *OwnedJsonEventList, item: []const u8) !void {
        try self.items.append(self.allocator, item);
    }
};

fn normalizeCodexWebSocketEvents(
    allocator: std.mem.Allocator,
    events_json: []const []const u8,
) !OwnedJsonEventList {
    var result: OwnedJsonEventList = .{ .allocator = allocator };
    errdefer result.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (events_json) |event_json| {
        var parsed = std.json.parseFromSlice(std.json.Value, a, event_json, .{}) catch {
            try result.appendOwned(try allocator.dupe(u8, event_json));
            continue;
        };
        defer parsed.deinit();
        const event_type = getStringField(parsed.value, "type") orelse {
            try result.appendOwned(try allocator.dupe(u8, event_json));
            continue;
        };
        const normalized = if (eql(event_type, "response.done") or eql(event_type, "response.incomplete"))
            try normalizeTerminalEvent(a, parsed.value)
        else
            try cloneJsonValue(a, parsed.value);
        const owned = try std.json.Stringify.valueAlloc(allocator, normalized, .{});
        errdefer allocator.free(owned);
        try result.appendOwned(owned);
        if (isCodexTerminalEvent(event_type)) break;
    }

    return result;
}

fn webSocketEventsHaveCompletion(allocator: std.mem.Allocator, events_json: []const []const u8) bool {
    for (events_json) |event_json| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, event_json, .{}) catch continue;
        defer parsed.deinit();
        const event_type = getStringField(parsed.value, "type") orelse continue;
        if (eql(event_type, "response.completed") or
            eql(event_type, "response.done") or
            eql(event_type, "response.incomplete"))
        {
            return true;
        }
    }
    return false;
}

fn applyWebSocketServiceTier(
    allocator: std.mem.Allocator,
    parsed: *ParsedStream,
    model: types.Model,
    events_json: []const []const u8,
    requested_service_tier: ?[]const u8,
) !void {
    const response_service_tier = try webSocketResponseServiceTier(allocator, events_json);
    defer if (response_service_tier) |tier| allocator.free(tier);
    if (resolveCodexServiceTier(response_service_tier, requested_service_tier)) |tier| {
        applyServiceTierPricing(&parsed.result.message.usage, tier, model);
    }
}

fn webSocketResponseServiceTier(allocator: std.mem.Allocator, events_json: []const []const u8) !?[]const u8 {
    for (events_json) |event_json| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, event_json, .{}) catch continue;
        defer parsed.deinit();
        const event_type = getStringField(parsed.value, "type") orelse continue;
        if (!(eql(event_type, "response.completed") or
            eql(event_type, "response.done") or
            eql(event_type, "response.incomplete"))) continue;
        const response = getObjectField(parsed.value, "response") orelse continue;
        const tier = getStringField(response, "service_tier") orelse continue;
        const owned = try allocator.dupe(u8, tier);
        return owned;
    }
    return null;
}

fn parseNonNegativeMillis(raw: []const u8, multiplier: f64) ?u64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (!std.math.isFinite(parsed)) return null;
    const millis = parsed * multiplier;
    if (millis <= 0) return 0;
    const max = @as(f64, @floatFromInt(std.math.maxInt(u64)));
    return @intFromFloat(@min(@floor(millis), max));
}

fn parseHttpDateMs(raw: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
    var day_token = tokens.next() orelse return null;
    if (std.mem.endsWith(u8, day_token, ",")) {
        day_token = tokens.next() orelse return null;
    }
    const month_token = tokens.next() orelse return null;
    const year_token = tokens.next() orelse return null;
    const time_token = tokens.next() orelse return null;
    const zone_token = tokens.next() orelse return null;
    if (tokens.next() != null) return null;
    if (!std.ascii.eqlIgnoreCase(zone_token, "GMT") and !std.ascii.eqlIgnoreCase(zone_token, "UTC")) return null;

    const day = std.fmt.parseInt(u8, day_token, 10) catch return null;
    const month = monthNumber(month_token) orelse return null;
    const year = std.fmt.parseInt(u16, year_token, 10) catch return null;

    var time_parts = std.mem.splitScalar(u8, time_token, ':');
    const hour = std.fmt.parseInt(u8, time_parts.next() orelse return null, 10) catch return null;
    const minute = std.fmt.parseInt(u8, time_parts.next() orelse return null, 10) catch return null;
    const second = std.fmt.parseInt(u8, time_parts.next() orelse return null, 10) catch return null;
    if (time_parts.next() != null) return null;

    return utcDateTimeToEpochMs(year, month, day, hour, minute, second);
}

fn monthNumber(value: []const u8) ?u8 {
    if (std.ascii.eqlIgnoreCase(value, "Jan")) return 1;
    if (std.ascii.eqlIgnoreCase(value, "Feb")) return 2;
    if (std.ascii.eqlIgnoreCase(value, "Mar")) return 3;
    if (std.ascii.eqlIgnoreCase(value, "Apr")) return 4;
    if (std.ascii.eqlIgnoreCase(value, "May")) return 5;
    if (std.ascii.eqlIgnoreCase(value, "Jun")) return 6;
    if (std.ascii.eqlIgnoreCase(value, "Jul")) return 7;
    if (std.ascii.eqlIgnoreCase(value, "Aug")) return 8;
    if (std.ascii.eqlIgnoreCase(value, "Sep")) return 9;
    if (std.ascii.eqlIgnoreCase(value, "Oct")) return 10;
    if (std.ascii.eqlIgnoreCase(value, "Nov")) return 11;
    if (std.ascii.eqlIgnoreCase(value, "Dec")) return 12;
    return null;
}

fn utcDateTimeToEpochMs(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < 1970 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 60) return null;
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    const days_in_month = std.time.epoch.getDaysInMonth(year, month_enum);
    if (day > days_in_month) return null;

    var days: u64 = 0;
    var current_year: u16 = 1970;
    while (current_year < year) : (current_year += 1) {
        days += std.time.epoch.getDaysInYear(current_year);
    }

    var current_month: u8 = 1;
    while (current_month < month) : (current_month += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(current_month));
    }

    days += day - 1;
    const seconds = days * std.time.epoch.secs_per_day +
        @as(u64, hour) * 3600 +
        @as(u64, minute) * 60 +
        @as(u64, second);
    const millis = std.math.mul(u64, seconds, 1000) catch return null;
    return std.math.cast(i64, millis);
}

pub fn buildWebSocketHeaderMap(
    allocator: std.mem.Allocator,
    model_headers: []const types.Header,
    additional_headers: []const types.Header,
    account_id: []const u8,
    token: []const u8,
    request_id: []const u8,
) !ClientHeaderMap {
    var headers: ClientHeaderMap = .{};
    errdefer headers.deinit(allocator);

    for (model_headers) |header| {
        if (!isWebSocketHeaderRemoved(header.name)) try putClientHeader(allocator, &headers, header.name, header.value);
    }
    for (additional_headers) |header| {
        if (!isWebSocketHeaderRemoved(header.name)) try putClientHeader(allocator, &headers, header.name, header.value);
    }

    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(authorization);
    try putClientHeader(allocator, &headers, "Authorization", authorization);
    try putClientHeader(allocator, &headers, "chatgpt-account-id", account_id);
    try putClientHeader(allocator, &headers, "originator", "bulb");
    try putClientHeader(allocator, &headers, "User-Agent", "bulb (native Zig)");
    try putClientHeader(allocator, &headers, "OpenAI-Beta", OPENAI_BETA_RESPONSES_WEBSOCKETS);
    try putClientHeader(allocator, &headers, "x-client-request-id", request_id);
    try putClientHeader(allocator, &headers, "session-id", request_id);
    return headers;
}

pub fn buildWebSocketCreatePayload(
    allocator: std.mem.Allocator,
    request_body: std.json.Value,
) !BuiltCodexParams {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var payload = try cloneJsonValue(a, request_body);
    try putString(a, &payload, "type", "response.create");
    return .{ .arena = arena, .value = payload };
}

pub fn buildCachedWebSocketRequestBody(
    allocator: std.mem.Allocator,
    entry: *OpenAICodexWebSocketCacheEntry,
    body: std.json.Value,
) !BuiltCodexParams {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const continuation = if (entry.continuation) |*value| value else {
        return .{ .arena = arena, .value = try cloneJsonValue(a, body) };
    };

    const delta = try getCachedWebSocketInputDelta(a, body, continuation.*);
    if (delta == null or continuation.last_response_id.len == 0) {
        entry.clearContinuation();
        return .{ .arena = arena, .value = try cloneJsonValue(a, body) };
    }

    var cached = try cloneJsonValue(a, body);
    try putString(a, &cached, "previous_response_id", continuation.last_response_id);
    try putValue(a, &cached, "input", delta.?);
    return .{ .arena = arena, .value = cached };
}

pub fn storeWebSocketContinuation(
    allocator: std.mem.Allocator,
    entry: *OpenAICodexWebSocketCacheEntry,
    model: types.Model,
    full_body: std.json.Value,
    output: types.AssistantMessage,
) !void {
    entry.clearContinuation();
    const response_id = output.response_id orelse return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const last_request_body = try cloneJsonValue(a, full_body);
    const last_response_id = try a.dupe(u8, response_id);
    const last_response_items = try buildCodexResponseItems(a, model, output);
    entry.continuation = .{
        .arena = arena,
        .last_request_body = last_request_body,
        .last_response_id = last_response_id,
        .last_response_items = last_response_items,
    };
}

pub fn recordWebSocketRequestStats(
    stats: *OpenAICodexWebSocketDebugStats,
    request_body: std.json.Value,
    reused: bool,
    use_cached_context: bool,
) void {
    stats.requests += 1;
    if (reused) {
        stats.connections_reused += 1;
    } else {
        stats.connections_created += 1;
    }
    if (use_cached_context) stats.cached_context_requests += 1;
    if (getBoolField(request_body, "store") orelse false) stats.store_true_requests += 1;

    const input_items = getArrayField(request_body, "input");
    stats.last_input_items = if (input_items) |items| items.len else 0;
    if (getStringField(request_body, "previous_response_id")) |previous_response_id| {
        stats.delta_requests += 1;
        stats.last_delta_input_items = stats.last_input_items;
        stats.last_previous_response_id = previous_response_id;
    } else {
        stats.full_context_requests += 1;
        stats.last_delta_input_items = null;
        stats.last_previous_response_id = null;
    }
}

pub fn recordWebSocketFailure(stats: *OpenAICodexWebSocketDebugStats, message: []const u8) void {
    stats.websocket_failures += 1;
    stats.websocket_fallback_active = true;
    stats.last_websocket_error = message;
}

pub fn recordWebSocketSseFallback(stats: *OpenAICodexWebSocketDebugStats, fallback_active: bool) void {
    stats.sse_fallbacks += 1;
    stats.websocket_fallback_active = fallback_active;
}

pub fn usesCachedWebSocketContext(transport: ?types.Transport) bool {
    return if (transport) |value| value == .websocket_cached or value == .auto else false;
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

    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(authorization);
    try putClientHeader(allocator, &headers, "Authorization", authorization);
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
    return ownedHeadersFromClientHeaderMap(allocator, &config.headers);
}

fn ownedHeadersFromClientHeaderMap(allocator: std.mem.Allocator, headers_map: *const ClientHeaderMap) !OwnedHeaderList {
    var headers = std.ArrayList(types.Header).empty;
    errdefer {
        deinitHeaderItems(allocator, headers.items);
        headers.deinit(allocator);
    }

    var iterator = headers_map.map.iterator();
    while (iterator.next()) |entry| {
        try appendHeader(allocator, &headers, entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .allocator = allocator, .headers = try headers.toOwnedSlice(allocator) };
}

fn putClientHeader(allocator: std.mem.Allocator, headers: *ClientHeaderMap, key: []const u8, value: []const u8) !void {
    var iterator = headers.map.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, key)) {
            allocator.free(entry.value_ptr.*);
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

fn isWebSocketHeaderRemoved(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "content-type") or
        std.ascii.eqlIgnoreCase(name, "OpenAI-Beta");
}

fn buildCodexResponseItems(
    allocator: std.mem.Allocator,
    model: types.Model,
    output: types.AssistantMessage,
) !std.json.Value {
    const messages = [_]types.Message{.{ .assistant = output }};
    const converted = try openai_responses_shared.convertResponsesMessagesValue(
        allocator,
        model,
        .{ .messages = &messages },
        .{ .include_system_prompt = false },
    );
    if (converted != .array) return converted;

    var filtered = std.json.Array.init(allocator);
    errdefer filtered.deinit();
    for (converted.array.items) |item| {
        if (getStringField(item, "type")) |item_type| {
            if (eql(item_type, "function_call_output")) continue;
        }
        try filtered.append(item);
    }
    return .{ .array = filtered };
}

fn getCachedWebSocketInputDelta(
    allocator: std.mem.Allocator,
    body: std.json.Value,
    continuation: CachedWebSocketContinuationState,
) !?std.json.Value {
    if (!try requestBodiesMatchExceptInput(allocator, body, continuation.last_request_body)) return null;

    const current_input = inputItems(body);
    const last_input = inputItems(continuation.last_request_body);
    const response_items = if (continuation.last_response_items == .array)
        continuation.last_response_items.array.items
    else
        &[_]std.json.Value{};
    const baseline_len = last_input.len + response_items.len;
    if (current_input.len < baseline_len) return null;

    var index: usize = 0;
    while (index < baseline_len) : (index += 1) {
        const expected = if (index < last_input.len)
            last_input[index]
        else
            response_items[index - last_input.len];
        if (!try jsonValuesEqual(allocator, current_input[index], expected)) return null;
    }

    var delta = std.json.Array.init(allocator);
    errdefer delta.deinit();
    for (current_input[baseline_len..]) |item| try delta.append(try cloneJsonValue(allocator, item));
    return .{ .array = delta };
}

fn requestBodiesMatchExceptInput(
    allocator: std.mem.Allocator,
    current: std.json.Value,
    previous: std.json.Value,
) !bool {
    const current_without = try requestBodyWithoutInput(allocator, current);
    const previous_without = try requestBodyWithoutInput(allocator, previous);
    return jsonValuesEqual(allocator, current_without, previous_without);
}

fn requestBodyWithoutInput(allocator: std.mem.Allocator, body: std.json.Value) !std.json.Value {
    if (body != .object) return cloneJsonValue(allocator, body);
    var result = objectValue();
    var iterator = body.object.iterator();
    while (iterator.next()) |entry| {
        if (eql(entry.key_ptr.*, "input") or eql(entry.key_ptr.*, "previous_response_id")) continue;
        try putValue(allocator, &result, entry.key_ptr.*, try cloneJsonValue(allocator, entry.value_ptr.*));
    }
    return result;
}

fn inputItems(body: std.json.Value) []const std.json.Value {
    return if (getArrayField(body, "input")) |items| items else &[_]std.json.Value{};
}

fn jsonValuesEqual(allocator: std.mem.Allocator, a: std.json.Value, b: std.json.Value) !bool {
    const left = try stringifyJsonValue(allocator, a);
    defer allocator.free(left);
    const right = try stringifyJsonValue(allocator, b);
    defer allocator.free(right);
    return eql(left, right);
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

    const uri = try std.Uri.parse(request.url);
    var http_request = try client.request(.POST, uri, .{
        .headers = .{ .authorization = .omit, .content_type = .omit },
        .extra_headers = headers,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
    });
    defer http_request.deinit();

    http_request.transfer_encoding = .{ .content_length = request.payload_json.len };
    var body_writer = try http_request.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(request.payload_json);
    try body_writer.end();
    try http_request.connection.?.flush();

    var response = try http_request.receiveHead(&.{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const response_headers = try copyResponseHeaders(a, response.head.bytes);
    const status: u16 = @intFromEnum(response.head.status);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&response_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    const raw_body = try response_writer.toOwnedSlice();
    defer allocator.free(raw_body);
    const body = try a.dupe(u8, raw_body);
    response_writer.deinit();
    return .{ .arena = arena, .status = status, .body = body, .headers = response_headers };
}

fn stdHttpHeaders(allocator: std.mem.Allocator, headers: []const types.Header) ![]std.http.Header {
    const result = try allocator.alloc(std.http.Header, headers.len);
    for (headers, 0..) |header, index| {
        result[index] = .{ .name = header.name, .value = header.value };
    }
    return result;
}

fn copyResponseHeaders(allocator: std.mem.Allocator, head_bytes: []const u8) ![]types.Header {
    var list = std.ArrayList(types.Header).empty;
    errdefer {
        deinitHeaderItems(allocator, list.items);
        list.deinit(allocator);
    }

    var lines = std.mem.splitSequence(u8, head_bytes, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (name.len == 0) continue;
        try appendHeader(allocator, &list, name, value);
    }

    return list.toOwnedSlice(allocator);
}

fn cloneHeaders(allocator: std.mem.Allocator, headers: []const types.Header) ![]types.Header {
    var list = std.ArrayList(types.Header).empty;
    errdefer {
        deinitHeaderItems(allocator, list.items);
        list.deinit(allocator);
    }
    for (headers) |header| try appendHeader(allocator, &list, header.name, header.value);
    return list.toOwnedSlice(allocator);
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

fn getArrayField(value: std.json.Value, field: []const u8) ?[]const std.json.Value {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return if (nested == .array) nested.array.items else null;
}

fn getBoolField(value: std.json.Value, field: []const u8) ?bool {
    if (value != .object) return null;
    const nested = value.object.get(field) orelse return null;
    return if (nested == .bool) nested.bool else null;
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

const codex_done_ws_events = [_][]const u8{
    "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}",
    "{\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
    "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}",
    "{\"type\":\"response.done\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8,\"input_tokens_details\":{\"cached_tokens\":0}}}}",
};

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

const RecordedCodexWebSocketRequest = struct {
    timeout_ms: ?u64,
    connect_timeout_ms: ?u64,
    cached_context: bool,
    url: []u8,
    payload_json: []u8,
    openai_beta: ?[]u8 = null,
    session_id: ?[]u8 = null,
    x_client_request_id: ?[]u8 = null,
    accept: ?[]u8 = null,
    content_type: ?[]u8 = null,

    fn deinit(self: *RecordedCodexWebSocketRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.payload_json);
        if (self.openai_beta) |value| allocator.free(value);
        if (self.session_id) |value| allocator.free(value);
        if (self.x_client_request_id) |value| allocator.free(value);
        if (self.accept) |value| allocator.free(value);
        if (self.content_type) |value| allocator.free(value);
    }
};

const FakeCodexWebSocketOutcome = union(enum) {
    events: []const []const u8,
    failure: OpenAICodexWebSocketFailure,
};

const FakeCodexWebSocketTransport = struct {
    allocator: std.mem.Allocator,
    outcomes: []const FakeCodexWebSocketOutcome,
    records: std.ArrayList(RecordedCodexWebSocketRequest) = .empty,

    fn init(allocator: std.mem.Allocator, outcomes: []const FakeCodexWebSocketOutcome) FakeCodexWebSocketTransport {
        return .{ .allocator = allocator, .outcomes = outcomes };
    }

    fn deinit(self: *FakeCodexWebSocketTransport) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    fn transport(self: *FakeCodexWebSocketTransport) OpenAICodexWebSocketTransport {
        return .{ .ptr = self, .request = fakeCodexWebSocketTransportRequest };
    }

    fn outcomeForRequest(self: *const FakeCodexWebSocketTransport, index: usize) FakeCodexWebSocketOutcome {
        if (self.outcomes.len == 0) return .{ .events = &codex_done_ws_events };
        return self.outcomes[@min(index, self.outcomes.len - 1)];
    }
};

const FakeCodexTransport = struct {
    allocator: std.mem.Allocator,
    statuses: []const u16 = &.{200},
    body: []const u8 = codex_done_sse,
    response_headers: []const types.Header = &.{},
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

fn fakeCodexWebSocketTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OpenAICodexWebSocketRequest,
) anyerror!OpenAICodexWebSocketResponse {
    const state: *FakeCodexWebSocketTransport = @ptrCast(@alignCast(ptr));
    const request_index = state.records.items.len;
    var record: RecordedCodexWebSocketRequest = .{
        .timeout_ms = request.timeout_ms,
        .connect_timeout_ms = request.connect_timeout_ms,
        .cached_context = request.cached_context,
        .url = try state.allocator.dupe(u8, request.url),
        .payload_json = try state.allocator.dupe(u8, request.payload_json),
    };
    if (findHeader(request.headers, "OpenAI-Beta")) |value| record.openai_beta = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "session-id")) |value| record.session_id = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "x-client-request-id")) |value| record.x_client_request_id = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "accept")) |value| record.accept = try state.allocator.dupe(u8, value);
    if (findHeader(request.headers, "content-type")) |value| record.content_type = try state.allocator.dupe(u8, value);
    errdefer record.deinit(state.allocator);
    try state.records.append(state.allocator, record);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const outcome = state.outcomeForRequest(request_index);
    const result: OpenAICodexWebSocketResult = switch (outcome) {
        .events => |events| .{ .events_json = try cloneWebSocketEvents(a, events) },
        .failure => |failure| .{ .failure = .{
            .message = try a.dupe(u8, failure.message),
            .phase = failure.phase,
        } },
    };
    return .{ .arena = arena, .result = result };
}

fn cloneWebSocketEvents(allocator: std.mem.Allocator, events: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, events.len);
    for (events, 0..) |event, index| {
        cloned[index] = try allocator.dupe(u8, event);
    }
    return cloned;
}

const RetrySleepRecorder = struct {
    allocator: std.mem.Allocator,
    delays: std.ArrayList(u64) = .empty,

    fn init(allocator: std.mem.Allocator) RetrySleepRecorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RetrySleepRecorder) void {
        self.delays.deinit(self.allocator);
    }

    fn sleeper(self: *RetrySleepRecorder) RetrySleeper {
        return .{ .ptr = self, .sleep = recordRetrySleep };
    }
};

fn recordRetrySleep(ptr: ?*anyopaque, delay_ms: u64, signal: ?*types.AbortSignal) anyerror!void {
    if (signal) |abort_signal| {
        if (abort_signal.aborted) return error.Aborted;
    }
    const recorder: *RetrySleepRecorder = @ptrCast(@alignCast(ptr.?));
    try recorder.delays.append(recorder.allocator, delay_ms);
}

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
    const a = arena.allocator();
    const body = try a.dupe(u8, state.body);
    const response_headers = try cloneHeaders(a, state.response_headers);
    return .{
        .arena = arena,
        .status = state.statusForAttempt(request.attempt),
        .body = body,
        .headers = response_headers,
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

test "OpenAI Codex Responses builds WebSocket headers with request affinity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const token = try mockToken(allocator);
    const model_headers = [_]types.Header{
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
        .{ .name = "x-model", .value = "one" },
    };
    const additional_headers = [_]types.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-extra", .value = "two" },
    };

    var headers = try buildWebSocketHeaderMap(
        allocator,
        &model_headers,
        &additional_headers,
        "acc_test",
        token,
        "session-auto",
    );
    defer headers.deinit(allocator);

    try std.testing.expectEqualStrings("acc_test", headers.getString("chatgpt-account-id").?);
    try std.testing.expectEqualStrings("bulb", headers.getString("originator").?);
    try std.testing.expectEqualStrings(OPENAI_BETA_RESPONSES_WEBSOCKETS, headers.getString("OpenAI-Beta").?);
    try std.testing.expectEqualStrings("session-auto", headers.getString("session-id").?);
    try std.testing.expectEqualStrings("session-auto", headers.getString("x-client-request-id").?);
    try std.testing.expectEqualStrings("one", headers.getString("x-model").?);
    try std.testing.expectEqualStrings("two", headers.getString("x-extra").?);
    try std.testing.expectEqual(@as(?[]const u8, null), headers.getString("accept"));
    try std.testing.expectEqual(@as(?[]const u8, null), headers.getString("content-type"));
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

test "OpenAI Codex Responses routes auto transport through WebSocket" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    const websocket_outcomes = [_]FakeCodexWebSocketOutcome{.{ .events = &codex_done_ws_events }};
    var websocket = FakeCodexWebSocketTransport.init(allocator, &websocket_outcomes);
    defer websocket.deinit();
    var sse_transport = FakeCodexTransport.init(allocator);
    defer sse_transport.deinit();
    var stats: OpenAICodexWebSocketDebugStats = .{};

    var parsed = try streamOpenAICodexResponses(allocator, model, basicContext(), .{
        .base = .{
            .api_key = token,
            .session_id = "session-auto",
            .transport = .auto,
        },
        .transport = sse_transport.transport(),
        .websocket_transport = websocket.transport(),
        .websocket_stats = &stats,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.stop, parsed.result.message.stop_reason);
    try std.testing.expectEqualStrings("Hello", parsed.result.message.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), websocket.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), sse_transport.records.items.len);
    try std.testing.expectEqualStrings("wss://chatgpt.com/backend-api/codex/responses", websocket.records.items[0].url);
    try std.testing.expectEqualStrings(OPENAI_BETA_RESPONSES_WEBSOCKETS, websocket.records.items[0].openai_beta.?);
    try std.testing.expectEqualStrings("session-auto", websocket.records.items[0].session_id.?);
    try std.testing.expectEqualStrings("session-auto", websocket.records.items[0].x_client_request_id.?);
    try std.testing.expectEqual(@as(?[]u8, null), websocket.records.items[0].accept);
    try std.testing.expectEqual(@as(?[]u8, null), websocket.records.items[0].content_type);
    try std.testing.expect(websocket.records.items[0].cached_context);

    var payload = try std.json.parseFromSlice(std.json.Value, allocator, websocket.records.items[0].payload_json, .{});
    defer payload.deinit();
    try std.testing.expectEqualStrings("response.create", getStringField(payload.value, "type").?);
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
    try std.testing.expectEqual(@as(u64, 1), stats.connections_created);
    try std.testing.expectEqual(@as(u64, 1), stats.cached_context_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.full_context_requests);
}

test "OpenAI Codex Responses falls back to SSE on WebSocket connect timeout" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    const websocket_outcomes = [_]FakeCodexWebSocketOutcome{.{ .failure = .{
        .message = "WebSocket connect timeout after 50ms",
        .phase = .before_message_stream_start,
    } }};
    var websocket = FakeCodexWebSocketTransport.init(allocator, &websocket_outcomes);
    defer websocket.deinit();
    var sse_transport = FakeCodexTransport.init(allocator);
    defer sse_transport.deinit();
    var stats: OpenAICodexWebSocketDebugStats = .{};

    var parsed = try streamOpenAICodexResponses(allocator, model, basicContext(), .{
        .base = .{
            .api_key = token,
            .session_id = "ws-connect-timeout",
            .transport = .auto,
            .timeout_ms = 300_000,
            .websocket_connect_timeout_ms = 50,
        },
        .transport = sse_transport.transport(),
        .websocket_transport = websocket.transport(),
        .websocket_stats = &stats,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.stop, parsed.result.message.stop_reason);
    try std.testing.expectEqualStrings("Hello", parsed.result.message.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), websocket.records.items.len);
    try std.testing.expectEqual(@as(?u64, 300_000), websocket.records.items[0].timeout_ms);
    try std.testing.expectEqual(@as(?u64, 50), websocket.records.items[0].connect_timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), sse_transport.records.items.len);
    try std.testing.expectEqual(@as(u64, 1), stats.websocket_failures);
    try std.testing.expectEqual(@as(u64, 1), stats.sse_fallbacks);
    try std.testing.expect(stats.websocket_fallback_active);
    try std.testing.expectEqualStrings("WebSocket connect timeout after 50ms", stats.last_websocket_error.?);
}

test "OpenAI Codex Responses falls back to SSE when WebSocket idles before first event" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    const websocket_outcomes = [_]FakeCodexWebSocketOutcome{.{ .failure = .{
        .message = "WebSocket idle timeout after 50ms",
        .phase = .before_message_stream_start,
    } }};
    var websocket = FakeCodexWebSocketTransport.init(allocator, &websocket_outcomes);
    defer websocket.deinit();
    var sse_transport = FakeCodexTransport.init(allocator);
    defer sse_transport.deinit();
    var stats: OpenAICodexWebSocketDebugStats = .{};

    var parsed = try streamOpenAICodexResponses(allocator, model, basicContext(), .{
        .base = .{
            .api_key = token,
            .session_id = "ws-idle-before-start",
            .transport = .auto,
            .timeout_ms = 50,
        },
        .transport = sse_transport.transport(),
        .websocket_transport = websocket.transport(),
        .websocket_stats = &stats,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.stop, parsed.result.message.stop_reason);
    try std.testing.expectEqualStrings("Hello", parsed.result.message.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), websocket.records.items.len);
    try std.testing.expectEqual(@as(?u64, 50), websocket.records.items[0].timeout_ms);
    try std.testing.expectEqual(@as(usize, 1), sse_transport.records.items.len);
    try std.testing.expectEqual(@as(u64, 1), stats.websocket_failures);
    try std.testing.expectEqual(@as(u64, 1), stats.sse_fallbacks);
    try std.testing.expect(stats.websocket_fallback_active);
}

test "OpenAI Codex Responses errors when WebSocket idles after stream start" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    const websocket_outcomes = [_]FakeCodexWebSocketOutcome{.{ .failure = .{
        .message = "WebSocket idle timeout after 50ms",
        .phase = .after_message_stream_start,
    } }};
    var websocket = FakeCodexWebSocketTransport.init(allocator, &websocket_outcomes);
    defer websocket.deinit();
    var sse_transport = FakeCodexTransport.init(allocator);
    defer sse_transport.deinit();
    var stats: OpenAICodexWebSocketDebugStats = .{};

    var parsed = try streamOpenAICodexResponses(allocator, model, basicContext(), .{
        .base = .{
            .api_key = token,
            .transport = .auto,
            .timeout_ms = 50,
        },
        .transport = sse_transport.transport(),
        .websocket_transport = websocket.transport(),
        .websocket_stats = &stats,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.@"error", parsed.result.message.stop_reason);
    try std.testing.expectEqualStrings("WebSocket idle timeout after 50ms", parsed.result.message.error_message.?);
    try std.testing.expectEqual(@as(usize, 1), websocket.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), sse_transport.records.items.len);
    try std.testing.expectEqual(@as(u64, 1), stats.websocket_failures);
    try std.testing.expectEqual(@as(u64, 0), stats.sse_fallbacks);
    try std.testing.expect(stats.websocket_fallback_active);
}

test "OpenAI Codex Responses sends only response input deltas in cached WebSocket mode" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    const first_context = basicContext();
    var first_params = try buildParams(allocator, model, first_context, .{
        .base = .{ .api_key = "unused", .session_id = "session-1" },
    });
    defer first_params.deinit();

    const first_response =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8,\"input_tokens_details\":{\"cached_tokens\":0}}}}\n\n";
    var first_parsed = try parseSseResponse(allocator, model, first_response, null);
    defer first_parsed.deinit();

    var cache_entry: OpenAICodexWebSocketCacheEntry = .{};
    defer cache_entry.deinit();
    try storeWebSocketContinuation(
        allocator,
        &cache_entry,
        model,
        first_params.value,
        first_parsed.result.message,
    );

    const second_user_content = [_]types.UserContent{.{ .text = .{ .text = "Now finish" } }};
    const second_messages = [_]types.Message{
        .{ .user = .{ .content = &basic_user_content, .timestamp_ms = 1 } },
        .{ .assistant = first_parsed.result.message },
        .{ .user = .{ .content = &second_user_content, .timestamp_ms = 2 } },
    };
    var second_params = try buildParams(allocator, model, .{
        .system_prompt = "System prompt",
        .messages = &second_messages,
    }, .{
        .base = .{ .api_key = "unused", .session_id = "session-1" },
    });
    defer second_params.deinit();

    var stats: OpenAICodexWebSocketDebugStats = .{};
    recordWebSocketRequestStats(&stats, first_params.value, false, usesCachedWebSocketContext(.websocket_cached));

    var cached = try buildCachedWebSocketRequestBody(allocator, &cache_entry, second_params.value);
    defer cached.deinit();
    recordWebSocketRequestStats(&stats, cached.value, true, usesCachedWebSocketContext(.websocket_cached));

    const input = getArrayField(cached.value, "input") orelse return error.MissingInput;
    try std.testing.expectEqual(@as(usize, 1), input.len);
    try std.testing.expectEqualStrings("resp_1", getStringField(cached.value, "previous_response_id").?);
    try std.testing.expectEqualStrings("user", getStringField(input[0], "role").?);
    const content = getArrayField(input[0], "content") orelse return error.MissingContent;
    try std.testing.expectEqualStrings("input_text", getStringField(content[0], "type").?);
    try std.testing.expectEqualStrings("Now finish", getStringField(content[0], "text").?);

    var create_payload = try buildWebSocketCreatePayload(allocator, cached.value);
    defer create_payload.deinit();
    try std.testing.expectEqualStrings("response.create", getStringField(create_payload.value, "type").?);

    try std.testing.expectEqual(@as(u64, 2), stats.requests);
    try std.testing.expectEqual(@as(u64, 1), stats.connections_created);
    try std.testing.expectEqual(@as(u64, 1), stats.connections_reused);
    try std.testing.expectEqual(@as(u64, 2), stats.cached_context_requests);
    try std.testing.expectEqual(@as(u64, 0), stats.store_true_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.full_context_requests);
    try std.testing.expectEqual(@as(u64, 1), stats.delta_requests);
    try std.testing.expectEqual(@as(?usize, 1), stats.last_delta_input_items);
    try std.testing.expectEqualStrings("resp_1", stats.last_previous_response_id.?);
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

test "OpenAI Codex Responses parses Retry-After headers" {
    const retry_after_ms = [_]types.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "retry-after-ms", .value = "1500" },
    };
    try std.testing.expectEqual(@as(?u64, 1500), retryAfterDelayMs(&retry_after_ms, 0));

    const retry_after_seconds = [_]types.Header{
        .{ .name = "retry-after", .value = "60" },
    };
    try std.testing.expectEqual(@as(?u64, 60_000), retryAfterDelayMs(&retry_after_seconds, 0));

    const now_ms = utcDateTimeToEpochMs(2026, 5, 13, 0, 0, 0).?;
    const retry_after_date = [_]types.Header{
        .{ .name = "retry-after", .value = "Wed, 13 May 2026 00:00:45 GMT" },
    };
    try std.testing.expectEqual(@as(?u64, 45_000), retryAfterDelayMs(&retry_after_date, now_ms));
}

test "OpenAI Codex Responses uses Retry-After headers for SSE retries" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    const cases = [_]struct {
        headers: []const types.Header,
        expected_delay_ms: u64,
    }{
        .{
            .headers = &[_]types.Header{.{ .name = "retry-after-ms", .value = "1500" }},
            .expected_delay_ms = 1500,
        },
        .{
            .headers = &[_]types.Header{.{ .name = "retry-after", .value = "60" }},
            .expected_delay_ms = 60_000,
        },
    };

    for (cases) |case| {
        var transport = FakeCodexTransport.init(allocator);
        defer transport.deinit();
        transport.statuses = &.{ 429, 200 };
        transport.response_headers = case.headers;

        var sleeper = RetrySleepRecorder.init(allocator);
        defer sleeper.deinit();

        var parsed = try streamOpenAICodexResponses(allocator, model, basicContext(), .{
            .base = .{
                .api_key = token,
                .max_retries = 1,
            },
            .transport = transport.transport(),
            .retry_sleeper = sleeper.sleeper(),
        });
        defer parsed.deinit();

        try std.testing.expectEqual(types.StopReason.stop, parsed.result.message.stop_reason);
        try std.testing.expectEqual(@as(usize, 2), transport.records.items.len);
        try std.testing.expectEqual(@as(usize, 1), sleeper.delays.items.len);
        try std.testing.expectEqual(case.expected_delay_ms, sleeper.delays.items[0]);
    }
}

test "OpenAI Codex Responses uses exponential backoff across repeated SSE retries" {
    const allocator = std.testing.allocator;
    const token = try mockToken(allocator);
    defer allocator.free(token);
    const model = (models.getModel("openai-codex", "gpt-5.5") orelse return error.ModelMissing).*;

    var transport = FakeCodexTransport.init(allocator);
    defer transport.deinit();
    transport.statuses = &.{ 429, 429, 429, 200 };

    var sleeper = RetrySleepRecorder.init(allocator);
    defer sleeper.deinit();

    var parsed = try streamOpenAICodexResponses(allocator, model, basicContext(), .{
        .base = .{
            .api_key = token,
            .max_retries = 3,
        },
        .transport = transport.transport(),
        .retry_sleeper = sleeper.sleeper(),
    });
    defer parsed.deinit();

    try std.testing.expectEqual(types.StopReason.stop, parsed.result.message.stop_reason);
    try std.testing.expectEqual(@as(usize, 4), transport.records.items.len);
    try std.testing.expectEqualSlices(u64, &.{ 1000, 2000, 4000 }, sleeper.delays.items);
}

test "OpenAI Codex Responses copies native response headers from raw HTTP head" {
    const allocator = std.testing.allocator;
    const raw_head =
        "HTTP/1.1 429 Too Many Requests\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Retry-After-Ms: 1500\r\n" ++
        "\r\n";

    const headers = try copyResponseHeaders(allocator, raw_head);
    defer {
        deinitHeaderItems(allocator, headers);
        allocator.free(headers);
    }

    try std.testing.expectEqualStrings("application/json", findHeader(headers, "content-type").?);
    try std.testing.expectEqual(@as(?u64, 1500), retryAfterDelayMs(headers, 0));
}
