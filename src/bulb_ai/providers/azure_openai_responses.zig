const std = @import("std");
const models = @import("../models.zig");
const openai_prompt_cache = @import("openai_prompt_cache.zig");
const openai_responses_shared = @import("openai_responses_shared.zig");
const simple_options = @import("simple_options.zig");
const sse = @import("../utils/sse.zig");
const types = @import("../types.zig");

const DEFAULT_AZURE_API_VERSION = "v1";

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

pub const AzureOpenAIResponsesOptions = struct {
    base: types.StreamOptions = .{},
    reasoning_effort: ?types.ThinkingLevel = null,
    reasoning_summary: ?ReasoningSummary = null,
    azure_api_version: ?[]const u8 = null,
    azure_resource_name: ?[]const u8 = null,
    azure_base_url: ?[]const u8 = null,
    azure_deployment_name: ?[]const u8 = null,
    on_payload: ?PayloadObserver = null,
    on_response: ?ResponseObserver = null,
    transport: ?AzureOpenAIResponsesTransport = null,
};

pub const AzureOpenAIResponsesRequestOptions = struct {
    timeout_ms: ?u64 = null,
    max_retries: u32 = 0,
};

pub const AzureOpenAIResponsesHttpRequest = struct {
    url: []const u8,
    payload_json: []const u8,
    headers: []const types.Header,
    timeout_ms: ?u64 = null,
    attempt: u32 = 0,
    max_retries: u32 = 0,
};

pub const AzureOpenAIResponsesHttpResponse = struct {
    arena: std.heap.ArenaAllocator,
    status: u16,
    body: []const u8,
    headers: []const types.Header = &.{},

    pub fn deinit(self: *AzureOpenAIResponsesHttpResponse) void {
        self.arena.deinit();
    }
};

pub const AzureOpenAIResponsesResponseInfo = struct {
    status: u16,
    headers: []const types.Header = &.{},
};

pub const PayloadObserver = *const fn (payload: *std.json.Value, model: types.Model) anyerror!void;
pub const ResponseObserver = *const fn (response: AzureOpenAIResponsesResponseInfo, model: types.Model) anyerror!void;
pub const AzureOpenAIResponsesTransportFn = *const fn (
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: AzureOpenAIResponsesHttpRequest,
) anyerror!AzureOpenAIResponsesHttpResponse;

pub const AzureOpenAIResponsesTransport = struct {
    ptr: *anyopaque,
    request: AzureOpenAIResponsesTransportFn,

    pub fn send(
        self: AzureOpenAIResponsesTransport,
        allocator: std.mem.Allocator,
        request: AzureOpenAIResponsesHttpRequest,
    ) !AzureOpenAIResponsesHttpResponse {
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
        return self.map.get(key);
    }
};

pub const AzureOpenAIResponsesClientConfig = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_version: []const u8,
    base_url: []const u8,
    request_url: []const u8,
    dangerously_allow_browser: bool = true,
    headers: ClientHeaderMap,
    request_options: AzureOpenAIResponsesRequestOptions,

    pub fn deinit(self: *AzureOpenAIResponsesClientConfig) void {
        self.headers.deinit(self.allocator);
        self.allocator.free(self.api_key);
        self.allocator.free(self.api_version);
        self.allocator.free(self.base_url);
        self.allocator.free(self.request_url);
    }
};

pub const BuiltAzureResponsesParams = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,

    pub fn deinit(self: *BuiltAzureResponsesParams) void {
        self.arena.deinit();
    }

    pub fn stringify(self: *const BuiltAzureResponsesParams, allocator: std.mem.Allocator) ![]u8 {
        return stringifyJsonValue(allocator, self.value);
    }
};

pub const ResolvedAzureConfig = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_version: []const u8,

    pub fn deinit(self: *ResolvedAzureConfig) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_version);
    }
};

pub const ParsedStream = openai_responses_shared.ParsedResponsesStream;

pub fn streamAzureOpenAIResponses(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?AzureOpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) !ParsedStream {
    const deployment_name = try resolveDeploymentName(allocator, model, options, env);
    defer allocator.free(deployment_name);

    var params = try buildParams(allocator, model, context, options, deployment_name);
    defer params.deinit();

    if (options) |opts| {
        if (opts.on_payload) |observer| try observer(&params.value, model);
    }

    const payload_json = try stringifyJsonValue(allocator, params.value);
    defer allocator.free(payload_json);

    var config = try buildClientConfig(allocator, model, options, env);
    defer config.deinit();

    var request_headers = try buildHttpHeaders(allocator, config);
    defer request_headers.deinit();

    var std_transport_state: StdAzureOpenAIResponsesTransport = .{};
    const default_transport: AzureOpenAIResponsesTransport = .{
        .ptr = &std_transport_state,
        .request = stdAzureOpenAIResponsesTransportRequest,
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

        const parsed = parseSseResponse(allocator, model, response.body) catch |err| {
            response.deinit();
            return err;
        };
        response.deinit();
        return parsed;
    }
}

pub fn streamSimpleAzureOpenAIResponses(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?simple_options.SimpleStreamOptions,
    env: ?*const std.process.Environ.Map,
) !ParsedStream {
    return streamAzureOpenAIResponses(
        allocator,
        model,
        context,
        try buildSimpleAzureOpenAIResponsesOptions(model, options),
        env,
    );
}

pub fn buildSimpleAzureOpenAIResponsesOptions(
    model: types.Model,
    options: ?simple_options.SimpleStreamOptions,
) !AzureOpenAIResponsesOptions {
    const api_key = if (options) |opts| opts.base.api_key else null;
    if (api_key == null) return error.NoApiKey;

    const base = simple_options.buildBaseOptions(model, options, api_key);
    const clamped_reasoning = if (options) |opts| if (opts.reasoning) |reasoning|
        models.clampThinkingLevel(model, reasoning)
    else
        null else null;
    const reasoning_effort = if (clamped_reasoning) |reasoning| if (reasoning == .off) null else reasoning else null;

    return .{
        .base = base,
        .reasoning_effort = reasoning_effort,
    };
}

pub fn parseSseResponse(
    allocator: std.mem.Allocator,
    model: types.Model,
    body: []const u8,
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

    return openai_responses_shared.processResponsesEvents(allocator, model, events_json.items);
}

pub fn buildParams(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?AzureOpenAIResponsesOptions,
    deployment_name: []const u8,
) !BuiltAzureResponsesParams {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var root = objectValue();
    try putString(a, &root, "model", deployment_name);
    try putValue(a, &root, "input", try openai_responses_shared.convertResponsesMessagesValue(
        a,
        model,
        context,
        .{ .include_system_prompt = true },
    ));
    try putBool(a, &root, "stream", true);

    if (try openai_prompt_cache.responsesPromptCacheKey(a, if (options) |opts| opts.base.session_id else null, .short)) |key| {
        try putOwnedString(a, &root, "prompt_cache_key", key);
    }

    if (options) |opts| {
        if (opts.base.max_tokens) |max_tokens| try putInteger(a, &root, "max_output_tokens", max_tokens);
        if (opts.base.temperature) |temperature| try putFloat(a, &root, "temperature", temperature);
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

pub fn buildClientConfig(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?AzureOpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) !AzureOpenAIResponsesClientConfig {
    const base_options = if (options) |opts| opts.base else types.StreamOptions{};
    const api_key = base_options.api_key orelse return error.NoApiKey;

    var config = try resolveAzureConfig(allocator, model, options, env);
    defer config.deinit();

    const headers = try buildClientHeaderMap(allocator, model, options);
    errdefer {
        var mutable_headers = headers;
        mutable_headers.deinit(allocator);
    }

    const api_key_copy = try allocator.dupe(u8, api_key);
    errdefer allocator.free(api_key_copy);
    const api_version_copy = try allocator.dupe(u8, config.api_version);
    errdefer allocator.free(api_version_copy);
    const base_url = try allocator.dupe(u8, config.base_url);
    errdefer allocator.free(base_url);
    const request_url = try azureResponsesUrl(allocator, base_url, config.api_version);
    errdefer allocator.free(request_url);

    return .{
        .allocator = allocator,
        .api_key = api_key_copy,
        .api_version = api_version_copy,
        .base_url = base_url,
        .request_url = request_url,
        .headers = headers,
        .request_options = .{
            .timeout_ms = base_options.timeout_ms,
            .max_retries = base_options.max_retries orelse 0,
        },
    };
}

pub fn resolveDeploymentName(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?AzureOpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) ![]u8 {
    if (options) |opts| {
        if (opts.azure_deployment_name) |name| return allocator.dupe(u8, name);
    }
    if (env) |environ| {
        if (environ.get("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")) |map_value| {
            if (try deploymentNameFromMap(allocator, map_value, model.id)) |mapped| return mapped;
        }
    }
    return allocator.dupe(u8, model.id);
}

pub fn deploymentNameFromMap(
    allocator: std.mem.Allocator,
    value: []const u8,
    model_id: []const u8,
) !?[]u8 {
    var iterator = std.mem.splitScalar(u8, value, ',');
    while (iterator.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const left = std.mem.trim(u8, trimmed[0..equals], " \t\r\n");
        const right = std.mem.trim(u8, trimmed[equals + 1 ..], " \t\r\n");
        if (left.len == 0 or right.len == 0) continue;
        if (eql(left, model_id)) return try allocator.dupe(u8, right);
    }
    return null;
}

pub fn resolveAzureConfig(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?AzureOpenAIResponsesOptions,
    env: ?*const std.process.Environ.Map,
) !ResolvedAzureConfig {
    const env_api_version = if (env) |environ| environ.get("AZURE_OPENAI_API_VERSION") else null;
    const env_base_url = if (env) |environ| environ.get("AZURE_OPENAI_BASE_URL") else null;
    const env_resource_name = if (env) |environ| environ.get("AZURE_OPENAI_RESOURCE_NAME") else null;

    const api_version = if (options) |opts| opts.azure_api_version orelse env_api_version orelse DEFAULT_AZURE_API_VERSION else env_api_version orelse DEFAULT_AZURE_API_VERSION;
    const option_base_url = if (options) |opts| opts.azure_base_url else null;
    const option_resource_name = if (options) |opts| opts.azure_resource_name else null;

    const trimmed_option_base = trimOptional(option_base_url);
    const trimmed_env_base = trimOptional(env_base_url);
    const resource_name = option_resource_name orelse env_resource_name;

    var raw_base_url: ?[]const u8 = trimmed_option_base orelse trimmed_env_base;
    var generated_base_url: ?[]u8 = null;
    defer if (generated_base_url) |generated| allocator.free(generated);
    if (raw_base_url == null) {
        if (resource_name) |name| {
            generated_base_url = try buildDefaultBaseUrl(allocator, name);
            raw_base_url = generated_base_url.?;
        }
    }
    if (raw_base_url == null and model.base_url.len > 0) raw_base_url = model.base_url;
    const base_url = raw_base_url orelse return error.MissingAzureOpenAIBaseUrl;

    const normalized_base_url = try normalizeAzureBaseUrl(allocator, base_url);
    errdefer allocator.free(normalized_base_url);
    const api_version_copy = try allocator.dupe(u8, api_version);
    errdefer allocator.free(api_version_copy);

    return .{
        .allocator = allocator,
        .base_url = normalized_base_url,
        .api_version = api_version_copy,
    };
}

pub fn normalizeAzureBaseUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base_url, " \t\r\n/");
    const uri = std.Uri.parse(trimmed) catch return error.InvalidAzureOpenAIBaseUrl;
    const host = uri.host orelse return error.InvalidAzureOpenAIBaseUrl;
    if (uri.scheme.len == 0) return error.InvalidAzureOpenAIBaseUrl;

    const path = try uriPath(allocator, uri);
    defer allocator.free(path);

    const host_text = componentSlice(host);
    const is_azure_host = std.mem.endsWith(u8, host_text, ".openai.azure.com") or
        std.mem.endsWith(u8, host_text, ".cognitiveservices.azure.com");
    const normalized_path = std.mem.trimEnd(u8, path, "/");
    const force_openai_v1 = is_azure_host and
        (normalized_path.len == 0 or eql(normalized_path, "/") or eql(normalized_path, "/openai"));
    const output_path = if (force_openai_v1) "/openai/v1" else path;
    const include_query = !force_openai_v1;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, uri.scheme);
    try out.appendSlice(allocator, "://");
    try out.appendSlice(allocator, host_text);
    if (uri.port) |port| {
        const formatted_port = try std.fmt.allocPrint(allocator, ":{d}", .{port});
        defer allocator.free(formatted_port);
        try out.appendSlice(allocator, formatted_port);
    }
    if (output_path.len > 0 and output_path[0] != '/') try out.append(allocator, '/');
    try out.appendSlice(allocator, std.mem.trimEnd(u8, output_path, "/"));
    if (include_query) {
        if (uri.query) |query| {
            try out.append(allocator, '?');
            try out.appendSlice(allocator, componentSlice(query));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn buildDefaultBaseUrl(allocator: std.mem.Allocator, resource_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{resource_name});
}

fn azureResponsesUrl(allocator: std.mem.Allocator, base_url: []const u8, api_version: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (std.mem.indexOfScalar(u8, trimmed, '?')) |query_index| {
        const path = std.mem.trimEnd(u8, trimmed[0..query_index], "/");
        const query = trimmed[query_index + 1 ..];
        if (queryHasApiVersion(query)) {
            return std.fmt.allocPrint(allocator, "{s}/responses?{s}", .{ path, query });
        }
        const separator: []const u8 = if (query.len == 0) "" else "&";
        return std.fmt.allocPrint(allocator, "{s}/responses?{s}{s}api-version={s}", .{ path, query, separator, api_version });
    }
    return std.fmt.allocPrint(allocator, "{s}/responses?api-version={s}", .{ trimmed, api_version });
}

fn queryHasApiVersion(query: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, query, '&');
    while (iterator.next()) |part| {
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        if (std.ascii.eqlIgnoreCase(part[0..equals], "api-version")) return true;
    }
    return false;
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

fn buildHttpHeaders(allocator: std.mem.Allocator, config: AzureOpenAIResponsesClientConfig) !OwnedHeaderList {
    var headers = std.ArrayList(types.Header).empty;
    errdefer {
        deinitHeaderItems(allocator, headers.items);
        headers.deinit(allocator);
    }

    try appendHeader(allocator, &headers, "Content-Type", config.headers.getString("Content-Type") orelse "application/json");
    try appendHeader(allocator, &headers, "Accept", config.headers.getString("Accept") orelse "text/event-stream");
    if (config.headers.getString("Authorization")) |authorization| {
        try appendHeader(allocator, &headers, "Authorization", authorization);
    } else {
        const authorization = try bearerHeader(allocator, config.api_key);
        defer allocator.free(authorization);
        try appendHeader(allocator, &headers, "Authorization", authorization);
    }

    var iterator = config.headers.map.iterator();
    while (iterator.next()) |entry| {
        if (eql(entry.key_ptr.*, "Authorization")) continue;
        if (eql(entry.key_ptr.*, "Content-Type")) continue;
        if (eql(entry.key_ptr.*, "Accept")) continue;
        try appendHeader(allocator, &headers, entry.key_ptr.*, entry.value_ptr.*);
    }

    return .{
        .allocator = allocator,
        .headers = try headers.toOwnedSlice(allocator),
    };
}

fn bearerHeader(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
}

fn buildClientHeaderMap(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?AzureOpenAIResponsesOptions,
) !ClientHeaderMap {
    var headers: ClientHeaderMap = .{};
    errdefer headers.deinit(allocator);

    for (model.headers) |header| try putClientHeader(allocator, &headers, header.name, header.value);

    if (options) |opts| {
        for (opts.base.headers) |header| try putClientHeader(allocator, &headers, header.name, header.value);
    }

    return headers;
}

fn putClientHeader(
    allocator: std.mem.Allocator,
    headers: *ClientHeaderMap,
    key: []const u8,
    value: []const u8,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    if (try headers.map.fetchPut(allocator, owned_key, owned_value)) |old| {
        allocator.free(old.key);
        allocator.free(old.value);
    }
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

const StdAzureOpenAIResponsesTransport = struct {};

fn stdAzureOpenAIResponsesTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: AzureOpenAIResponsesHttpRequest,
) anyerror!AzureOpenAIResponsesHttpResponse {
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
    options: ?AzureOpenAIResponsesOptions,
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

fn trimOptional(value: ?[]const u8) ?[]const u8 {
    const unwrapped = value orelse return null;
    const trimmed = std.mem.trim(u8, unwrapped, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn uriPath(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    return allocator.dupe(u8, componentSlice(uri.path));
}

fn componentSlice(component: std.Uri.Component) []const u8 {
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| encoded,
    };
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

const azure_responses_done_sse =
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp-test\",\"status\":\"completed\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":0}}}\n\n" ++
    "data: [DONE]\n\n";

const RecordedAzureOpenAIResponsesRequest = struct {
    attempt: u32,
    max_retries: u32,
    timeout_ms: ?u64,
    url: []u8,
    payload_json: []u8,
    authorization: ?[]u8 = null,
    x_custom: ?[]u8 = null,

    fn deinit(self: *RecordedAzureOpenAIResponsesRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.payload_json);
        if (self.authorization) |value| allocator.free(value);
        if (self.x_custom) |value| allocator.free(value);
    }
};

const FakeAzureOpenAIResponsesTransport = struct {
    allocator: std.mem.Allocator,
    statuses: []const u16 = &.{200},
    body: []const u8 = azure_responses_done_sse,
    records: std.ArrayList(RecordedAzureOpenAIResponsesRequest) = .empty,

    fn init(allocator: std.mem.Allocator) FakeAzureOpenAIResponsesTransport {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakeAzureOpenAIResponsesTransport) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
    }

    fn transport(self: *FakeAzureOpenAIResponsesTransport) AzureOpenAIResponsesTransport {
        return .{
            .ptr = self,
            .request = fakeAzureOpenAIResponsesTransportRequest,
        };
    }

    fn statusForAttempt(self: *const FakeAzureOpenAIResponsesTransport, attempt: u32) u16 {
        if (self.statuses.len == 0) return 200;
        const index: usize = @min(attempt, self.statuses.len - 1);
        return self.statuses[index];
    }
};

fn fakeAzureOpenAIResponsesTransportRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: AzureOpenAIResponsesHttpRequest,
) anyerror!AzureOpenAIResponsesHttpResponse {
    const state: *FakeAzureOpenAIResponsesTransport = @ptrCast(@alignCast(ptr));
    var record: RecordedAzureOpenAIResponsesRequest = .{
        .attempt = request.attempt,
        .max_retries = request.max_retries,
        .timeout_ms = request.timeout_ms,
        .url = try state.allocator.dupe(u8, request.url),
        .payload_json = try state.allocator.dupe(u8, request.payload_json),
    };
    if (findHeader(request.headers, "Authorization")) |authorization| {
        record.authorization = try state.allocator.dupe(u8, authorization);
    }
    if (findHeader(request.headers, "x-custom")) |value| {
        record.x_custom = try state.allocator.dupe(u8, value);
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

const basic_user_content = [_]types.UserContent{.{ .text = .{ .text = "hello" } }};
const basic_messages = [_]types.Message{.{ .user = .{ .content = &basic_user_content, .timestamp_ms = 1 } }};

fn basicContext() types.Context {
    return .{ .messages = &basic_messages };
}

// Ported from packages/ai/test/azure-openai-base-url.test.ts.
test "Azure OpenAI Responses normalizes Azure and proxy base URLs" {
    const allocator = std.testing.allocator;

    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = "https://marc-quicktests-resource.cognitiveservices.azure.com",
            .expected = "https://marc-quicktests-resource.cognitiveservices.azure.com/openai/v1",
        },
        .{
            .input = "https://my-resource.openai.azure.com",
            .expected = "https://my-resource.openai.azure.com/openai/v1",
        },
        .{
            .input = "https://my-resource.cognitiveservices.azure.com/openai",
            .expected = "https://my-resource.cognitiveservices.azure.com/openai/v1",
        },
        .{
            .input = "https://my-resource.cognitiveservices.azure.com/openai/v1",
            .expected = "https://my-resource.cognitiveservices.azure.com/openai/v1",
        },
        .{
            .input = "https://my-proxy.example.com/v1",
            .expected = "https://my-proxy.example.com/v1",
        },
        .{
            .input = "https://my-resource.openai.azure.com/openai?api-version=2024-12-01",
            .expected = "https://my-resource.openai.azure.com/openai/v1",
        },
        .{
            .input = "https://my-proxy.example.com/v1?custom=true",
            .expected = "https://my-proxy.example.com/v1?custom=true",
        },
    };

    for (cases) |case| {
        const normalized = try normalizeAzureBaseUrl(allocator, case.input);
        defer allocator.free(normalized);
        try std.testing.expectEqualStrings(case.expected, normalized);
    }
}

// Ported from packages/ai/test/azure-openai-base-url.test.ts.
test "Azure OpenAI Responses rejects invalid base URLs" {
    try std.testing.expectError(error.InvalidAzureOpenAIBaseUrl, normalizeAzureBaseUrl(std.testing.allocator, "not-a-url"));
}

// Ported from packages/ai/test/azure-openai-base-url.test.ts and packages/ai/test/azure-utils.ts.
test "Azure OpenAI Responses resolves default URL, API version, and deployment map from environment" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("AZURE_OPENAI_RESOURCE_NAME", "my-resource");
    try env.put("AZURE_OPENAI_API_VERSION", "2024-12-01-preview");
    try env.put("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", " gpt-4o-mini = mini-prod ,ignored,bad=, gpt-5 = five-prod ");

    const model = (models.getModel("azure-openai-responses", "gpt-4o-mini") orelse return error.ModelMissing).*;

    var config = try resolveAzureConfig(allocator, model, null, &env);
    defer config.deinit();
    try std.testing.expectEqualStrings("https://my-resource.openai.azure.com/openai/v1", config.base_url);
    try std.testing.expectEqualStrings("2024-12-01-preview", config.api_version);

    const deployment = try resolveDeploymentName(allocator, model, null, &env);
    defer allocator.free(deployment);
    try std.testing.expectEqualStrings("mini-prod", deployment);
}

// Ported from packages/ai/test/azure-openai-base-url.test.ts.
test "Azure OpenAI Responses request uses deployment, cache key clamp, headers, and retry options" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("azure-openai-responses", "gpt-4o-mini") orelse return error.ModelMissing).*;
    const header_overrides = [_]types.Header{.{ .name = "x-custom", .value = "yes" }};

    var transport = FakeAzureOpenAIResponsesTransport.init(allocator);
    defer transport.deinit();

    var stream = try streamAzureOpenAIResponses(allocator, model, basicContext(), .{
        .base = .{
            .api_key = "test-api-key",
            .session_id = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            .headers = &header_overrides,
            .timeout_ms = 1234,
            .max_retries = 2,
        },
        .azure_base_url = "https://my-resource.openai.azure.com",
        .azure_deployment_name = "deployment-mini",
        .transport = transport.transport(),
    }, null);
    defer stream.deinit();

    try std.testing.expectEqual(@as(usize, 1), transport.records.items.len);
    const record = transport.records.items[0];
    try std.testing.expectEqualStrings("https://my-resource.openai.azure.com/openai/v1/responses?api-version=v1", record.url);
    try std.testing.expectEqualStrings("Bearer test-api-key", record.authorization.?);
    try std.testing.expectEqualStrings("yes", record.x_custom.?);
    try std.testing.expectEqual(@as(?u64, 1234), record.timeout_ms);
    try std.testing.expectEqual(@as(u32, 2), record.max_retries);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, record.payload_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("deployment-mini", getStringField(parsed.value, "model") orelse return error.MissingModel);
    try std.testing.expectEqual(@as(usize, 64), (getStringField(parsed.value, "prompt_cache_key") orelse return error.MissingPromptCacheKey).len);

    var query_transport = FakeAzureOpenAIResponsesTransport.init(allocator);
    defer query_transport.deinit();
    var query_stream = try streamAzureOpenAIResponses(allocator, model, basicContext(), .{
        .base = .{ .api_key = "test-api-key" },
        .azure_base_url = "https://my-proxy.example.com/v1?custom=true",
        .azure_api_version = "2025-01-01",
        .transport = query_transport.transport(),
    }, null);
    defer query_stream.deinit();
    try std.testing.expectEqualStrings(
        "https://my-proxy.example.com/v1/responses?custom=true&api-version=2025-01-01",
        query_transport.records.items[0].url,
    );
}

// Ported from packages/ai/src/providers/azure-openai-responses.ts.
test "Azure OpenAI Responses builds simple reasoning facade and reasoning payloads" {
    const allocator = std.testing.allocator;
    const model = (models.getModel("azure-openai-responses", "gpt-5.4") orelse return error.ModelMissing).*;

    var explicit = try buildParams(allocator, model, basicContext(), .{
        .base = .{ .api_key = "test-api-key", .max_tokens = 1000, .temperature = 0.2 },
        .reasoning_effort = .high,
        .reasoning_summary = .concise,
    }, "deployment");
    defer explicit.deinit();
    const reasoning = getObjectField(explicit.value, "reasoning") orelse return error.MissingReasoning;
    try std.testing.expectEqualStrings("high", getStringField(reasoning, "effort") orelse return error.MissingEffort);
    try std.testing.expectEqualStrings("concise", getStringField(reasoning, "summary") orelse return error.MissingSummary);
    try std.testing.expect(explicit.value.object.get("include") != null);
    try std.testing.expectEqualStrings("deployment", getStringField(explicit.value, "model") orelse return error.MissingModel);

    const simple = try buildSimpleAzureOpenAIResponsesOptions(model, .{
        .base = .{ .api_key = "test-api-key" },
        .reasoning = .xhigh,
    });
    try std.testing.expectEqual(types.ThinkingLevel.xhigh, simple.reasoning_effort.?);
}
