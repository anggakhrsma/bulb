const std = @import("std");
const models = @import("../../models.zig");
const ai_types = @import("../../types.zig");
const device_code = @import("device_code.zig");
const oauth_types = @import("types.zig");

pub const client_id = "Iv1.b507a08c87ecfe98";
pub const default_domain = "github.com";
pub const default_base_url = "https://api.individual.githubcopilot.com";
pub const enterprise_prompt_message = "GitHub Enterprise URL/domain (blank for github.com)";

const copilot_headers = [_]ai_types.Header{
    .{ .name = "User-Agent", .value = "GitHubCopilotChat/0.35.0" },
    .{ .name = "Editor-Version", .value = "vscode/1.107.0" },
    .{ .name = "Editor-Plugin-Version", .value = "copilot-chat/0.35.0" },
    .{ .name = "Copilot-Integration-Id", .value = "vscode-chat" },
};

pub const OAuthHttpMethod = enum {
    get,
    post,

    fn stdMethod(self: OAuthHttpMethod) std.http.Method {
        return switch (self) {
            .get => .GET,
            .post => .POST,
        };
    }
};

pub const OAuthHttpRequest = struct {
    method: OAuthHttpMethod,
    url: []const u8,
    headers: []const ai_types.Header = &.{},
    body: []const u8 = "",
};

pub const OAuthHttpResponse = struct {
    allocator: std.mem.Allocator,
    status: u16,
    status_text: []u8,
    body: []u8,

    pub fn deinit(self: *OAuthHttpResponse) void {
        self.allocator.free(self.status_text);
        self.allocator.free(self.body);
    }
};

pub const OAuthHttpTransport = struct {
    ptr: *anyopaque,
    request: *const fn (*anyopaque, std.mem.Allocator, OAuthHttpRequest) anyerror!OAuthHttpResponse,

    pub fn send(
        self: OAuthHttpTransport,
        allocator: std.mem.Allocator,
        request: OAuthHttpRequest,
    ) !OAuthHttpResponse {
        return self.request(self.ptr, allocator, request);
    }
};

pub const OAuthCredentials = struct {
    allocator: std.mem.Allocator,
    refresh: []u8,
    access: []u8,
    expires: i64,
    enterprise_url: ?[]u8 = null,

    pub fn deinit(self: *OAuthCredentials) void {
        self.allocator.free(self.refresh);
        self.allocator.free(self.access);
        if (self.enterprise_url) |enterprise_url| self.allocator.free(enterprise_url);
    }
};

pub const OAuthCredentialsResult = union(enum) {
    credentials: OAuthCredentials,
    failed: device_code.FlowFailure,

    pub fn deinit(self: *OAuthCredentialsResult) void {
        switch (self.*) {
            .credentials => |*credentials| credentials.deinit(),
            .failed => |*failure_value| failure_value.deinit(),
        }
    }
};

pub const ModelProgressCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, []const u8, bool) anyerror!void,

    pub fn invoke(self: ModelProgressCallback, model_id: []const u8, success: bool) !void {
        try self.call(self.ptr, model_id, success);
    }
};

pub const LoginOptions = struct {
    transport: ?OAuthHttpTransport = null,
    on_prompt: oauth_types.PromptCallback,
    on_device_code: ?oauth_types.DeviceCodeCallback = null,
    on_progress: ?oauth_types.ProgressCallback = null,
    on_model_progress: ?ModelProgressCallback = null,
    signal: ?*ai_types.AbortSignal = null,
    clock: device_code.Clock = .{},
    sleeper: device_code.Sleeper = .{},
};

pub const GitHubCopilotOAuthProvider = struct {
    pub const id = "github-copilot";
    pub const name = "GitHub Copilot";

    pub fn login(
        _: GitHubCopilotOAuthProvider,
        allocator: std.mem.Allocator,
        options: LoginOptions,
    ) !OAuthCredentialsResult {
        return loginGitHubCopilot(allocator, options);
    }

    pub fn refreshToken(
        _: GitHubCopilotOAuthProvider,
        allocator: std.mem.Allocator,
        credentials: OAuthCredentials,
        transport: ?OAuthHttpTransport,
    ) !OAuthCredentialsResult {
        return refreshGitHubCopilotToken(allocator, credentials.refresh, credentials.enterprise_url, transport);
    }

    pub fn getApiKey(_: GitHubCopilotOAuthProvider, credentials: OAuthCredentials) []const u8 {
        return credentials.access;
    }

    pub fn modelBaseUrl(
        _: GitHubCopilotOAuthProvider,
        allocator: std.mem.Allocator,
        credentials: OAuthCredentials,
    ) ![]u8 {
        return getGitHubCopilotBaseUrl(allocator, credentials.access, credentials.enterprise_url);
    }
};

pub const github_copilot_oauth_provider: GitHubCopilotOAuthProvider = .{};

pub fn loginGitHubCopilot(
    allocator: std.mem.Allocator,
    options: LoginOptions,
) !OAuthCredentialsResult {
    var std_transport: StdOAuthHttpTransport = .{};
    const default_transport: OAuthHttpTransport = .{ .ptr = &std_transport, .request = stdOAuthHttpRequest };
    const transport = options.transport orelse default_transport;

    const input = try options.on_prompt.invoke(.{
        .message = enterprise_prompt_message,
        .placeholder = "company.ghe.com",
        .allow_empty = true,
    });
    if (isAborted(options.signal)) return .{ .failed = try failure(allocator, device_code.cancel_message) };

    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const enterprise_domain = try normalizeDomain(allocator, input);
    defer if (enterprise_domain) |domain| allocator.free(domain);
    if (trimmed.len > 0 and enterprise_domain == null) {
        return .{ .failed = try failure(allocator, "Invalid GitHub Enterprise URL/domain") };
    }
    const domain = enterprise_domain orelse default_domain;

    var device_result = try startDeviceFlow(allocator, domain, transport);
    switch (device_result) {
        .failed => |failure_value| return .{ .failed = failure_value },
        .device => |*device| {
            defer device.deinit();
            if (options.on_device_code) |callback| {
                try callback.invoke(.{
                    .user_code = device.user_code,
                    .verification_uri = device.verification_uri,
                    .interval_seconds = device.interval_seconds,
                    .expires_in_seconds = device.expires_in_seconds,
                });
            }

            const access_result = try pollForGitHubAccessToken(allocator, domain, device.*, transport, options);
            switch (access_result) {
                .failed => |failure_value| return .{ .failed = failure_value },
                .complete => |access_token| {
                    defer allocator.free(access_token);
                    const credentials_result = try refreshGitHubCopilotToken(
                        allocator,
                        access_token,
                        enterprise_domain,
                        transport,
                    );
                    switch (credentials_result) {
                        .failed => |failure_value| return .{ .failed = failure_value },
                        .credentials => |credentials| {
                            errdefer {
                                var owned = credentials;
                                owned.deinit();
                            }
                            if (options.on_progress) |callback| try callback.invoke("Enabling models...");
                            try enableAllGitHubCopilotModels(
                                allocator,
                                credentials.access,
                                enterprise_domain,
                                transport,
                                options.on_model_progress,
                            );
                            return .{ .credentials = credentials };
                        },
                    }
                },
            }
        },
    }
}

pub fn refreshGitHubCopilotToken(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
    enterprise_domain: ?[]const u8,
    maybe_transport: ?OAuthHttpTransport,
) !OAuthCredentialsResult {
    var std_transport: StdOAuthHttpTransport = .{};
    const default_transport: OAuthHttpTransport = .{ .ptr = &std_transport, .request = stdOAuthHttpRequest };
    const transport = maybe_transport orelse default_transport;
    var urls = try GitHubUrls.init(allocator, enterprise_domain orelse default_domain);
    defer urls.deinit();
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{refresh_token});
    defer allocator.free(authorization);
    const request_headers = [_]ai_types.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = authorization },
    } ++ copilot_headers;

    var response = try transport.send(allocator, .{
        .method = .get,
        .url = urls.copilot_token_url,
        .headers = &request_headers,
    });
    defer response.deinit();
    if (!isSuccessStatus(response.status)) return .{ .failed = try responseFailure(allocator, response) };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        return .{ .failed = try failure(allocator, "Invalid Copilot token response") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failed = try failure(allocator, "Invalid Copilot token response") };
    const token = parsed.value.object.get("token") orelse
        return .{ .failed = try failure(allocator, "Invalid Copilot token response fields") };
    const expires_at = parsed.value.object.get("expires_at") orelse
        return .{ .failed = try failure(allocator, "Invalid Copilot token response fields") };
    if (token != .string) return .{ .failed = try failure(allocator, "Invalid Copilot token response fields") };
    const expires_at_seconds = jsonNumberToI64(expires_at) orelse
        return .{ .failed = try failure(allocator, "Invalid Copilot token response fields") };

    const refresh = try allocator.dupe(u8, refresh_token);
    errdefer allocator.free(refresh);
    const access = try allocator.dupe(u8, token.string);
    errdefer allocator.free(access);
    const enterprise_url = if (enterprise_domain) |domain| try allocator.dupe(u8, domain) else null;
    return .{ .credentials = .{
        .allocator = allocator,
        .refresh = refresh,
        .access = access,
        .expires = saturatingSubtract(saturatingMultiply(expires_at_seconds, 1000), 5 * 60 * 1000),
        .enterprise_url = enterprise_url,
    } };
}

pub fn normalizeDomain(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    const url = if (std.mem.indexOf(u8, trimmed, "://") == null)
        try std.fmt.allocPrint(allocator, "https://{s}", .{trimmed})
    else
        try allocator.dupe(u8, trimmed);
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch return null;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return null;
    if (host.bytes.len == 0) return null;
    const normalized = try allocator.dupe(u8, host.bytes);
    for (normalized) |*byte| byte.* = std.ascii.toLower(byte.*);
    return normalized;
}

pub fn getGitHubCopilotBaseUrl(
    allocator: std.mem.Allocator,
    token: ?[]const u8,
    enterprise_domain: ?[]const u8,
) ![]u8 {
    if (token) |value| {
        if (try getBaseUrlFromToken(allocator, value)) |base_url| return base_url;
    }
    if (enterprise_domain) |domain| return std.fmt.allocPrint(allocator, "https://copilot-api.{s}", .{domain});
    return allocator.dupe(u8, default_base_url);
}

pub fn enableAllGitHubCopilotModels(
    allocator: std.mem.Allocator,
    token: []const u8,
    enterprise_domain: ?[]const u8,
    transport: OAuthHttpTransport,
    on_progress: ?ModelProgressCallback,
) !void {
    var iterator = models.getModels("github-copilot");
    while (iterator.next()) |model| {
        const success = enableGitHubCopilotModel(
            allocator,
            token,
            model.id,
            enterprise_domain,
            transport,
        ) catch false;
        if (on_progress) |callback| try callback.invoke(model.id, success);
    }
}

fn enableGitHubCopilotModel(
    allocator: std.mem.Allocator,
    token: []const u8,
    model_id: []const u8,
    enterprise_domain: ?[]const u8,
    transport: OAuthHttpTransport,
) !bool {
    const base_url = try getGitHubCopilotBaseUrl(allocator, token, enterprise_domain);
    defer allocator.free(base_url);
    const url = try std.fmt.allocPrint(allocator, "{s}/models/{s}/policy", .{ base_url, model_id });
    defer allocator.free(url);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(authorization);
    const request_headers = [_]ai_types.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = authorization },
    } ++ copilot_headers ++ [_]ai_types.Header{
        .{ .name = "openai-intent", .value = "chat-policy" },
        .{ .name = "x-interaction-type", .value = "chat-policy" },
    };
    var response = try transport.send(allocator, .{
        .method = .post,
        .url = url,
        .headers = &request_headers,
        .body = "{\"state\":\"enabled\"}",
    });
    defer response.deinit();
    return isSuccessStatus(response.status);
}

const DeviceCodeInfo = struct {
    allocator: std.mem.Allocator,
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    interval_seconds: ?f64,
    expires_in_seconds: u64,

    fn deinit(self: *DeviceCodeInfo) void {
        self.allocator.free(self.device_code);
        self.allocator.free(self.user_code);
        self.allocator.free(self.verification_uri);
    }
};

const DeviceCodeResult = union(enum) {
    device: DeviceCodeInfo,
    failed: device_code.FlowFailure,
};

fn startDeviceFlow(
    allocator: std.mem.Allocator,
    domain: []const u8,
    transport: OAuthHttpTransport,
) !DeviceCodeResult {
    var urls = try GitHubUrls.init(allocator, domain);
    defer urls.deinit();
    const body = try buildForm(allocator, &.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "scope", .value = "read:user" },
    });
    defer allocator.free(body);
    const request_headers = [_]ai_types.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "User-Agent", .value = "GitHubCopilotChat/0.35.0" },
    };
    var response = try transport.send(allocator, .{
        .method = .post,
        .url = urls.device_code_url,
        .headers = &request_headers,
        .body = body,
    });
    defer response.deinit();
    if (!isSuccessStatus(response.status)) return .{ .failed = try responseFailure(allocator, response) };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        return .{ .failed = try failure(allocator, "Invalid device code response") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failed = try failure(allocator, "Invalid device code response") };
    const object = parsed.value.object;
    const device = object.get("device_code") orelse
        return .{ .failed = try failure(allocator, "Invalid device code response fields") };
    const user = object.get("user_code") orelse
        return .{ .failed = try failure(allocator, "Invalid device code response fields") };
    const verification = object.get("verification_uri") orelse
        return .{ .failed = try failure(allocator, "Invalid device code response fields") };
    const expires = object.get("expires_in") orelse
        return .{ .failed = try failure(allocator, "Invalid device code response fields") };
    if (device != .string or user != .string or verification != .string) {
        return .{ .failed = try failure(allocator, "Invalid device code response fields") };
    }
    const interval = if (object.get("interval")) |value|
        jsonNumberToF64(value) orelse return .{ .failed = try failure(allocator, "Invalid device code response fields") }
    else
        null;
    const expires_seconds = jsonNumberToU64(expires) orelse
        return .{ .failed = try failure(allocator, "Invalid device code response fields") };

    const device_copy = try allocator.dupe(u8, device.string);
    errdefer allocator.free(device_copy);
    const user_copy = try allocator.dupe(u8, user.string);
    errdefer allocator.free(user_copy);
    const verification_copy = try allocator.dupe(u8, verification.string);
    return .{ .device = .{
        .allocator = allocator,
        .device_code = device_copy,
        .user_code = user_copy,
        .verification_uri = verification_copy,
        .interval_seconds = interval,
        .expires_in_seconds = expires_seconds,
    } };
}

const AccessTokenPollState = struct {
    domain: []const u8,
    device: DeviceCodeInfo,
    transport: OAuthHttpTransport,
};

fn pollForGitHubAccessToken(
    allocator: std.mem.Allocator,
    domain: []const u8,
    device: DeviceCodeInfo,
    transport: OAuthHttpTransport,
    options: LoginOptions,
) !device_code.FlowResult([]u8) {
    var state: AccessTokenPollState = .{
        .domain = domain,
        .device = device,
        .transport = transport,
    };
    return device_code.pollOAuthDeviceCodeFlow([]u8, allocator, .{
        .interval_seconds = device.interval_seconds,
        .expires_in_seconds = device.expires_in_seconds,
        .poller = .{ .ptr = &state, .poll = pollAccessToken },
        .signal = options.signal,
        .clock = options.clock,
        .sleeper = options.sleeper,
    });
}

fn pollAccessToken(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!device_code.PollResult([]u8) {
    const state: *AccessTokenPollState = @ptrCast(@alignCast(ptr));
    var urls = try GitHubUrls.init(allocator, state.domain);
    defer urls.deinit();
    const body = try buildForm(allocator, &.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "device_code", .value = state.device.device_code },
        .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
    });
    defer allocator.free(body);
    const request_headers = [_]ai_types.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "User-Agent", .value = "GitHubCopilotChat/0.35.0" },
    };
    var response = try state.transport.send(allocator, .{
        .method = .post,
        .url = urls.access_token_url,
        .headers = &request_headers,
        .body = body,
    });
    defer response.deinit();
    if (!isSuccessStatus(response.status)) return .{ .failed_owned = try responseFailureMessage(allocator, response) };

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        return .{ .failed = "Invalid device token response" };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failed = "Invalid device token response" };
    const object = parsed.value.object;
    if (object.get("access_token")) |access_token| {
        if (access_token == .string) return .{ .complete = try allocator.dupe(u8, access_token.string) };
    }
    if (object.get("error")) |error_value| {
        if (error_value == .string) {
            if (std.mem.eql(u8, error_value.string, "authorization_pending")) return .pending;
            if (std.mem.eql(u8, error_value.string, "slow_down")) return .slow_down;
            const description = if (object.get("error_description")) |description_value|
                if (description_value == .string) description_value.string else ""
            else
                "";
            return .{ .failed_owned = if (description.len > 0)
                try std.fmt.allocPrint(allocator, "Device flow failed: {s}: {s}", .{ error_value.string, description })
            else
                try std.fmt.allocPrint(allocator, "Device flow failed: {s}", .{error_value.string}) };
        }
    }
    return .{ .failed = "Invalid device token response" };
}

const GitHubUrls = struct {
    allocator: std.mem.Allocator,
    device_code_url: []u8,
    access_token_url: []u8,
    copilot_token_url: []u8,

    fn init(allocator: std.mem.Allocator, domain: []const u8) !GitHubUrls {
        const device = try std.fmt.allocPrint(allocator, "https://{s}/login/device/code", .{domain});
        errdefer allocator.free(device);
        const access = try std.fmt.allocPrint(allocator, "https://{s}/login/oauth/access_token", .{domain});
        errdefer allocator.free(access);
        return .{
            .allocator = allocator,
            .device_code_url = device,
            .access_token_url = access,
            .copilot_token_url = try std.fmt.allocPrint(allocator, "https://api.{s}/copilot_internal/v2/token", .{domain}),
        };
    }

    fn deinit(self: *GitHubUrls) void {
        self.allocator.free(self.device_code_url);
        self.allocator.free(self.access_token_url);
        self.allocator.free(self.copilot_token_url);
    }
};

fn getBaseUrlFromToken(allocator: std.mem.Allocator, token: []const u8) !?[]u8 {
    const marker = "proxy-ep=";
    const marker_index = std.mem.indexOf(u8, token, marker) orelse return null;
    const host_start = marker_index + marker.len;
    const remaining = token[host_start..];
    const host_end = std.mem.indexOfScalar(u8, remaining, ';') orelse remaining.len;
    const host = remaining[0..host_end];
    if (host.len == 0) return null;
    const api_host = if (std.mem.startsWith(u8, host, "proxy.")) host["proxy.".len..] else host;
    return @as(?[]u8, try std.fmt.allocPrint(allocator, "https://{s}{s}", .{
        if (std.mem.startsWith(u8, host, "proxy.")) "api." else "",
        api_host,
    }));
}

const FormField = struct {
    name: []const u8,
    value: []const u8,
};

fn buildForm(allocator: std.mem.Allocator, fields: []const FormField) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (fields, 0..) |field, index| {
        if (index > 0) try out.append(allocator, '&');
        try appendFormComponent(allocator, &out, field.name);
        try out.append(allocator, '=');
        try appendFormComponent(allocator, &out, field.value);
    }
    return out.toOwnedSlice(allocator);
}

fn appendFormComponent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '*') {
            try out.append(allocator, byte);
        } else if (byte == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[byte >> 4]);
            try out.append(allocator, hex[byte & 0x0f]);
        }
    }
}

fn responseFailure(allocator: std.mem.Allocator, response: OAuthHttpResponse) !device_code.FlowFailure {
    const message = try responseFailureMessage(allocator, response);
    defer allocator.free(message);
    return failure(allocator, message);
}

fn responseFailureMessage(allocator: std.mem.Allocator, response: OAuthHttpResponse) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d} {s}: {s}", .{ response.status, response.status_text, response.body });
}

fn failure(allocator: std.mem.Allocator, message: []const u8) !device_code.FlowFailure {
    return device_code.failure(allocator, message);
}

fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

fn isAborted(signal: ?*ai_types.AbortSignal) bool {
    return if (signal) |abort_signal| abort_signal.isAborted() else false;
}

fn jsonNumberToF64(value: std.json.Value) ?f64 {
    const result = switch (value) {
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        .float => |float| float,
        else => return null,
    };
    if (!std.math.isFinite(result) or result < 0) return null;
    return result;
}

fn jsonNumberToU64(value: std.json.Value) ?u64 {
    const result = jsonNumberToF64(value) orelse return null;
    if (result != @floor(result) or result > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
    return @intFromFloat(result);
}

fn jsonNumberToI64(value: std.json.Value) ?i64 {
    const result = jsonNumberToF64(value) orelse return null;
    if (result != @floor(result) or result > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    return @intFromFloat(result);
}

fn saturatingMultiply(value: i64, factor: i64) i64 {
    const result = @mulWithOverflow(value, factor);
    return if (result[1] != 0) std.math.maxInt(i64) else result[0];
}

fn saturatingSubtract(value: i64, amount: i64) i64 {
    const result = @subWithOverflow(value, amount);
    return if (result[1] != 0) std.math.minInt(i64) else result[0];
}

const StdOAuthHttpTransport = struct {};

fn stdOAuthHttpRequest(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
    request: OAuthHttpRequest,
) anyerror!OAuthHttpResponse {
    _ = ptr;
    var client = std.http.Client{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();
    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();
    const extra_headers = try stdHttpHeaders(allocator, request.headers);
    defer allocator.free(extra_headers);
    const result = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = request.method.stdMethod(),
        .payload = if (request.body.len > 0) request.body else null,
        .headers = .{
            .authorization = .omit,
            .content_type = .omit,
        },
        .extra_headers = extra_headers,
        .response_writer = &response_writer.writer,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
    });
    const body = try response_writer.toOwnedSlice();
    errdefer allocator.free(body);
    const status_text = try allocator.dupe(u8, @tagName(result.status));
    response_writer.deinit();
    return .{
        .allocator = allocator,
        .status = @intFromEnum(result.status),
        .status_text = status_text,
        .body = body,
    };
}

fn stdHttpHeaders(allocator: std.mem.Allocator, headers: []const ai_types.Header) ![]std.http.Header {
    const result = try allocator.alloc(std.http.Header, headers.len);
    for (headers, 0..) |header, index| result[index] = .{ .name = header.name, .value = header.value };
    return result;
}

fn findHeader(headers: []const ai_types.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn countCopilotModels() usize {
    return models.getModels("github-copilot").count();
}

const RecordedRequest = struct {
    allocator: std.mem.Allocator,
    method: OAuthHttpMethod,
    url: []u8,
    body: []u8,
    authorization: ?[]u8 = null,

    fn deinit(self: *RecordedRequest) void {
        self.allocator.free(self.url);
        self.allocator.free(self.body);
        if (self.authorization) |authorization| self.allocator.free(authorization);
    }
};

const FakeOAuthTransport = struct {
    allocator: std.mem.Allocator,
    device_body: []const u8 =
        "{\"device_code\":\"device-code\",\"user_code\":\"ABCD-EFGH\",\"verification_uri\":\"https://github.com/login/device\",\"interval\":1,\"expires_in\":900}",
    access_bodies: []const []const u8,
    token_body: []const u8 =
        "{\"token\":\"tid=test;exp=9999999999;proxy-ep=proxy.individual.githubcopilot.com;\",\"expires_at\":9999999999}",
    access_index: usize = 0,
    records: std.ArrayList(RecordedRequest) = .empty,
    clock: ?*TestClock = null,
    access_poll_times: std.ArrayList(i64) = .empty,

    fn init(allocator: std.mem.Allocator, access_bodies: []const []const u8) FakeOAuthTransport {
        return .{ .allocator = allocator, .access_bodies = access_bodies };
    }

    fn deinit(self: *FakeOAuthTransport) void {
        for (self.records.items) |*record| record.deinit();
        self.records.deinit(self.allocator);
        self.access_poll_times.deinit(self.allocator);
    }

    fn transport(self: *FakeOAuthTransport) OAuthHttpTransport {
        return .{ .ptr = self, .request = request };
    }

    fn request(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request_value: OAuthHttpRequest,
    ) anyerror!OAuthHttpResponse {
        const self: *FakeOAuthTransport = @ptrCast(@alignCast(ptr));
        const authorization = findHeader(request_value.headers, "Authorization");
        try self.records.append(self.allocator, .{
            .allocator = self.allocator,
            .method = request_value.method,
            .url = try self.allocator.dupe(u8, request_value.url),
            .body = try self.allocator.dupe(u8, request_value.body),
            .authorization = if (authorization) |value| try self.allocator.dupe(u8, value) else null,
        });
        const body = if (std.mem.endsWith(u8, request_value.url, "/login/device/code"))
            self.device_body
        else if (std.mem.endsWith(u8, request_value.url, "/login/oauth/access_token")) blk: {
            if (self.clock) |clock| try self.access_poll_times.append(self.allocator, clock.now_value);
            if (self.access_index >= self.access_bodies.len) return error.UnexpectedAccessTokenPoll;
            const result = self.access_bodies[self.access_index];
            self.access_index += 1;
            break :blk result;
        } else if (std.mem.indexOf(u8, request_value.url, "/copilot_internal/v2/token") != null)
            self.token_body
        else if (std.mem.indexOf(u8, request_value.url, "/models/") != null and
            std.mem.endsWith(u8, request_value.url, "/policy"))
            ""
        else
            return error.UnexpectedRequest;
        return .{
            .allocator = allocator,
            .status = 200,
            .status_text = try allocator.dupe(u8, "OK"),
            .body = try allocator.dupe(u8, body),
        };
    }
};

const TestClock = struct {
    now_value: i64,

    fn now(ptr: ?*anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ptr.?));
        return self.now_value;
    }
};

const TestSleeper = struct {
    allocator: std.mem.Allocator,
    clock: *TestClock,
    delays: std.ArrayList(u64) = .empty,

    fn deinit(self: *TestSleeper) void {
        self.delays.deinit(self.allocator);
    }

    fn sleep(ptr: ?*anyopaque, millis: u64, _: ?*ai_types.AbortSignal) !void {
        const self: *TestSleeper = @ptrCast(@alignCast(ptr.?));
        try self.delays.append(self.allocator, millis);
        self.clock.now_value += @intCast(millis);
    }
};

const PromptRecorder = struct {
    prompt: ?oauth_types.OAuthPrompt = null,
    response: []const u8 = "",

    fn call(ptr: ?*anyopaque, prompt: oauth_types.OAuthPrompt) anyerror![]const u8 {
        const self: *PromptRecorder = @ptrCast(@alignCast(ptr.?));
        self.prompt = prompt;
        return self.response;
    }
};

const DeviceCodeRecorder = struct {
    allocator: std.mem.Allocator,
    info: ?oauth_types.OAuthDeviceCodeInfo = null,

    fn deinit(self: *DeviceCodeRecorder) void {
        if (self.info) |info| {
            self.allocator.free(info.user_code);
            self.allocator.free(info.verification_uri);
        }
    }

    fn call(ptr: ?*anyopaque, info: oauth_types.OAuthDeviceCodeInfo) anyerror!void {
        const self: *DeviceCodeRecorder = @ptrCast(@alignCast(ptr.?));
        const user_code = try self.allocator.dupe(u8, info.user_code);
        errdefer self.allocator.free(user_code);
        const verification_uri = try self.allocator.dupe(u8, info.verification_uri);
        self.info = .{
            .user_code = user_code,
            .verification_uri = verification_uri,
            .interval_seconds = info.interval_seconds,
            .expires_in_seconds = info.expires_in_seconds,
        };
    }
};

const ProgressRecorder = struct {
    messages: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    fn deinit(self: *ProgressRecorder) void {
        self.messages.deinit(self.allocator);
    }

    fn call(ptr: ?*anyopaque, message: []const u8) anyerror!void {
        const self: *ProgressRecorder = @ptrCast(@alignCast(ptr.?));
        try self.messages.append(self.allocator, message);
    }
};

test "GitHub Copilot OAuth reports device-code details through onDeviceCode" {
    const allocator = std.testing.allocator;
    const access_bodies = [_][]const u8{"{\"access_token\":\"ghu_refresh_token\"}"};
    var transport = FakeOAuthTransport.init(allocator, &access_bodies);
    defer transport.deinit();
    var clock: TestClock = .{ .now_value = 1_773_014_400_000 };
    var sleeper: TestSleeper = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();
    var prompt: PromptRecorder = .{};
    var device: DeviceCodeRecorder = .{ .allocator = allocator };
    defer device.deinit();
    var progress: ProgressRecorder = .{ .allocator = allocator };
    defer progress.deinit();

    var result = try loginGitHubCopilot(allocator, .{
        .transport = transport.transport(),
        .on_prompt = .{ .ptr = &prompt, .call = PromptRecorder.call },
        .on_device_code = .{ .ptr = &device, .call = DeviceCodeRecorder.call },
        .on_progress = .{ .ptr = &progress, .call = ProgressRecorder.call },
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = TestSleeper.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("ghu_refresh_token", result.credentials.refresh);
    try std.testing.expectEqualStrings("tid=test;exp=9999999999;proxy-ep=proxy.individual.githubcopilot.com;", result.credentials.access);
    try std.testing.expectEqual(@as(i64, 9_999_999_699_000), result.credentials.expires);
    try std.testing.expectEqualStrings(enterprise_prompt_message, prompt.prompt.?.message);
    try std.testing.expect(prompt.prompt.?.allow_empty);
    try std.testing.expectEqualStrings("ABCD-EFGH", device.info.?.user_code);
    try std.testing.expectEqualStrings("https://github.com/login/device", device.info.?.verification_uri);
    try std.testing.expectEqual(@as(?f64, 1), device.info.?.interval_seconds);
    try std.testing.expectEqual(@as(?u64, 900), device.info.?.expires_in_seconds);
    try std.testing.expectEqual(@as(usize, 1), progress.messages.items.len);
    try std.testing.expectEqualStrings("Enabling models...", progress.messages.items[0]);
    try std.testing.expectEqual(@as(usize, countCopilotModels() + 3), transport.records.items.len);
    try std.testing.expectEqualStrings("client_id=Iv1.b507a08c87ecfe98&scope=read%3Auser", transport.records.items[0].body);
}

test "GitHub Copilot OAuth polls immediately and increases interval after slow_down" {
    const allocator = std.testing.allocator;
    const access_bodies = [_][]const u8{
        "{\"error\":\"authorization_pending\",\"error_description\":\"pending\"}",
        "{\"error\":\"slow_down\",\"error_description\":\"slow down\"}",
        "{\"access_token\":\"ghu_refresh_token\"}",
    };
    var transport = FakeOAuthTransport.init(allocator, &access_bodies);
    defer transport.deinit();
    transport.device_body =
        "{\"device_code\":\"device-code\",\"user_code\":\"ABCD-EFGH\",\"verification_uri\":\"https://github.com/login/device\",\"interval\":5,\"expires_in\":900}";
    var clock: TestClock = .{ .now_value = 1_773_014_400_000 };
    transport.clock = &clock;
    var sleeper: TestSleeper = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();
    var prompt: PromptRecorder = .{};

    var result = try loginGitHubCopilot(allocator, .{
        .transport = transport.transport(),
        .on_prompt = .{ .ptr = &prompt, .call = PromptRecorder.call },
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = TestSleeper.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualSlices(i64, &.{
        1_773_014_400_000,
        1_773_014_405_000,
        1_773_014_415_000,
    }, transport.access_poll_times.items);
    try std.testing.expectEqualSlices(u64, &.{ 5000, 10_000 }, sleeper.delays.items);
    try std.testing.expect(std.mem.indexOf(u8, transport.records.items[0].body, "scope=read%3Auser") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.records.items[1].body, "device_code=device-code") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.records.items[1].body, "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") != null);
}

test "GitHub Copilot OAuth times out after repeated slow_down responses" {
    const allocator = std.testing.allocator;
    const access_bodies = [_][]const u8{
        "{\"error\":\"slow_down\",\"error_description\":\"slow down\"}",
        "{\"error\":\"slow_down\",\"error_description\":\"still too fast\"}",
        "{\"error\":\"authorization_pending\",\"error_description\":\"pending\"}",
    };
    var transport = FakeOAuthTransport.init(allocator, &access_bodies);
    defer transport.deinit();
    transport.device_body =
        "{\"device_code\":\"device-code\",\"user_code\":\"ABCD-EFGH\",\"verification_uri\":\"https://github.com/login/device\",\"interval\":5,\"expires_in\":25}";
    var clock: TestClock = .{ .now_value = 1_773_014_400_000 };
    transport.clock = &clock;
    var sleeper: TestSleeper = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();
    var prompt: PromptRecorder = .{};

    var result = try loginGitHubCopilot(allocator, .{
        .transport = transport.transport(),
        .on_prompt = .{ .ptr = &prompt, .call = PromptRecorder.call },
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = TestSleeper.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(device_code.slow_down_timeout_message, result.failed.message);
    try std.testing.expectEqualSlices(i64, &.{
        1_773_014_400_000,
        1_773_014_410_000,
    }, transport.access_poll_times.items);
    try std.testing.expectEqualSlices(u64, &.{ 10_000, 15_000 }, sleeper.delays.items);
}

test "GitHub Copilot OAuth normalizes domains and resolves token base URLs" {
    const allocator = std.testing.allocator;
    const bare = (try normalizeDomain(allocator, "  Company.GHE.com  ")).?;
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("company.ghe.com", bare);
    const url = (try normalizeDomain(allocator, "https://Company.GHE.com:8443/path")).?;
    defer allocator.free(url);
    try std.testing.expectEqualStrings("company.ghe.com", url);
    try std.testing.expectEqual(@as(?[]u8, null), try normalizeDomain(allocator, " "));

    const token_base = try getGitHubCopilotBaseUrl(
        allocator,
        "tid=test;proxy-ep=proxy.business.githubcopilot.com;exp=123",
        null,
    );
    defer allocator.free(token_base);
    try std.testing.expectEqualStrings("https://api.business.githubcopilot.com", token_base);
    const enterprise_base = try getGitHubCopilotBaseUrl(allocator, null, "company.ghe.com");
    defer allocator.free(enterprise_base);
    try std.testing.expectEqualStrings("https://copilot-api.company.ghe.com", enterprise_base);
}
