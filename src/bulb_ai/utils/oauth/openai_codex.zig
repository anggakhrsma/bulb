const std = @import("std");
const openai_codex_responses = @import("../../providers/openai_codex_responses.zig");
const types = @import("../../types.zig");
const device_code = @import("device_code.zig");

pub const callback_host_env = "BULB_OAUTH_CALLBACK_HOST";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const auth_base_url = "https://auth.openai.com";
pub const authorize_url = auth_base_url ++ "/oauth/authorize";
pub const token_url = auth_base_url ++ "/oauth/token";
pub const redirect_uri = "http://localhost:1455/auth/callback";
pub const device_user_code_url = auth_base_url ++ "/api/accounts/deviceauth/usercode";
pub const device_token_url = auth_base_url ++ "/api/accounts/deviceauth/token";
pub const device_verification_uri = auth_base_url ++ "/codex/device";
pub const device_redirect_uri = auth_base_url ++ "/deviceauth/callback";
pub const device_code_timeout_seconds: u64 = 15 * 60;
pub const browser_login_method = "browser";
pub const device_code_login_method = "device_code";
pub const scope = "openid profile email offline_access";

pub const OAuthCredentials = struct {
    allocator: std.mem.Allocator,
    access: []u8,
    refresh: []u8,
    expires: i64,
    account_id: []u8,

    pub fn deinit(self: *OAuthCredentials) void {
        self.allocator.free(self.access);
        self.allocator.free(self.refresh);
        self.allocator.free(self.account_id);
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

pub const OAuthHttpMethod = enum {
    post,

    fn stdMethod(self: OAuthHttpMethod) std.http.Method {
        return switch (self) {
            .post => .POST,
        };
    }
};

pub const OAuthHttpRequest = struct {
    method: OAuthHttpMethod,
    url: []const u8,
    headers: []const types.Header = &.{},
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

pub const OAuthHttpTransportFn = *const fn (
    *anyopaque,
    std.mem.Allocator,
    OAuthHttpRequest,
) anyerror!OAuthHttpResponse;

pub const OAuthHttpTransport = struct {
    ptr: *anyopaque,
    request: OAuthHttpTransportFn,

    pub fn send(
        self: OAuthHttpTransport,
        allocator: std.mem.Allocator,
        request: OAuthHttpRequest,
    ) !OAuthHttpResponse {
        return self.request(self.ptr, allocator, request);
    }
};

pub const OAuthDeviceCodeInfo = struct {
    user_code: []const u8,
    verification_uri: []const u8,
    interval_seconds: f64,
    expires_in_seconds: u64,
};

pub const DeviceCodeCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthDeviceCodeInfo) anyerror!void,

    pub fn invoke(self: DeviceCodeCallback, info: OAuthDeviceCodeInfo) !void {
        try self.call(self.ptr, info);
    }
};

pub const OAuthSelectOption = struct {
    id: []const u8,
    label: []const u8,
};

pub const OAuthSelectPrompt = struct {
    message: []const u8,
    options: []const OAuthSelectOption,
};

pub const SelectCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthSelectPrompt) anyerror!?[]const u8,

    pub fn invoke(self: SelectCallback, prompt: OAuthSelectPrompt) !?[]const u8 {
        return self.call(self.ptr, prompt);
    }
};

pub const OpenAICodexDeviceCodeLoginOptions = struct {
    transport: ?OAuthHttpTransport = null,
    on_device_code: ?DeviceCodeCallback = null,
    signal: ?*types.AbortSignal = null,
    clock: device_code.Clock = .{},
    sleeper: device_code.Sleeper = .{},
};

pub const OpenAICodexLoginCallbacks = struct {
    transport: ?OAuthHttpTransport = null,
    on_select: ?SelectCallback = null,
    on_device_code: ?DeviceCodeCallback = null,
    signal: ?*types.AbortSignal = null,
    clock: device_code.Clock = .{},
    sleeper: device_code.Sleeper = .{},
};

pub const AuthorizationInput = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

pub const AuthorizationFlow = struct {
    arena: std.heap.ArenaAllocator,
    verifier: []const u8,
    state: []const u8,
    url: []const u8,

    pub fn deinit(self: *AuthorizationFlow) void {
        self.arena.deinit();
    }
};

pub const OpenAICodexOAuthProvider = struct {
    pub const id = "openai-codex";
    pub const name = "ChatGPT Plus/Pro (Codex Subscription)";
    pub const uses_callback_server = true;

    pub fn login(
        _: OpenAICodexOAuthProvider,
        allocator: std.mem.Allocator,
        callbacks: OpenAICodexLoginCallbacks,
    ) !OAuthCredentialsResult {
        const on_select = callbacks.on_select orelse
            return .{ .failed = try failure(allocator, device_code.cancel_message) };
        const login_method = try on_select.invoke(openaiCodexLoginPrompt()) orelse
            return .{ .failed = try failure(allocator, device_code.cancel_message) };

        if (std.mem.eql(u8, login_method, device_code_login_method)) {
            return loginOpenAICodexDeviceCode(allocator, .{
                .transport = callbacks.transport,
                .on_device_code = callbacks.on_device_code,
                .signal = callbacks.signal,
                .clock = callbacks.clock,
                .sleeper = callbacks.sleeper,
            });
        }

        if (!std.mem.eql(u8, login_method, browser_login_method)) {
            return .{ .failed = try failureFmt(
                allocator,
                "Unknown OpenAI Codex login method: {s}",
                .{login_method},
            ) };
        }

        return .{ .failed = try failure(
            allocator,
            "OpenAI Codex browser login callback server is not yet ported in native Zig",
        ) };
    }

    pub fn refreshToken(
        _: OpenAICodexOAuthProvider,
        allocator: std.mem.Allocator,
        credentials: OAuthCredentials,
        transport: ?OAuthHttpTransport,
        clock: device_code.Clock,
    ) !OAuthCredentialsResult {
        return refreshOpenAICodexToken(allocator, credentials.refresh, transport, clock);
    }

    pub fn getApiKey(_: OpenAICodexOAuthProvider, credentials: OAuthCredentials) []const u8 {
        return credentials.access;
    }
};

pub const openai_codex_oauth_provider: OpenAICodexOAuthProvider = .{};

const openai_codex_login_options = [_]OAuthSelectOption{
    .{ .id = browser_login_method, .label = "Browser login (default)" },
    .{ .id = device_code_login_method, .label = "Device code login (headless)" },
};

pub fn openaiCodexLoginPrompt() OAuthSelectPrompt {
    return .{
        .message = "Select OpenAI Codex login method:",
        .options = &openai_codex_login_options,
    };
}

pub fn loginOpenAICodexDeviceCode(
    allocator: std.mem.Allocator,
    options: OpenAICodexDeviceCodeLoginOptions,
) !OAuthCredentialsResult {
    var std_transport: StdOAuthHttpTransport = .{};
    const default_transport: OAuthHttpTransport = .{ .ptr = &std_transport, .request = stdOAuthHttpRequest };
    const transport = options.transport orelse default_transport;

    var device_result = try startOpenAICodexDeviceAuth(allocator, transport, options.signal);
    switch (device_result) {
        .failed => |failure_value| return .{ .failed = failure_value },
        .device => |*device| {
            defer device.deinit();
            if (options.on_device_code) |callback| {
                try callback.invoke(.{
                    .user_code = device.user_code,
                    .verification_uri = device_verification_uri,
                    .interval_seconds = device.interval_seconds,
                    .expires_in_seconds = device_code_timeout_seconds,
                });
            }

            const code_result = try pollOpenAICodexDeviceAuth(allocator, device.*, transport, options);
            switch (code_result) {
                .failed => |failure_value| return .{ .failed = failure_value },
                .complete => |success_value| {
                    var success = success_value;
                    defer success.deinit();
                    return exchangeAuthorizationCodeForCredentials(
                        allocator,
                        success.authorization_code,
                        success.code_verifier,
                        device_redirect_uri,
                        transport,
                        options.signal,
                        options.clock,
                    );
                },
            }
        },
    }
}

pub fn refreshOpenAICodexToken(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
    maybe_transport: ?OAuthHttpTransport,
    clock: device_code.Clock,
) !OAuthCredentialsResult {
    var std_transport: StdOAuthHttpTransport = .{};
    const default_transport: OAuthHttpTransport = .{ .ptr = &std_transport, .request = stdOAuthHttpRequest };
    const transport = maybe_transport orelse default_transport;
    const body = try buildForm(allocator, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "client_id", .value = client_id },
    });
    defer allocator.free(body);

    var response = try sendJsonOrForm(allocator, transport, token_url, "application/x-www-form-urlencoded", body);
    defer response.deinit();
    return readTokenCredentials(allocator, response, "refresh", clock.now());
}

pub fn createAuthorizationFlow(
    allocator: std.mem.Allocator,
    originator: []const u8,
) !AuthorizationFlow {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const verifier = try generateVerifier(a);
    const challenge = try generateChallenge(a, verifier);
    const state = try createState(a);
    const query = try buildForm(a, &.{
        .{ .name = "response_type", .value = "code" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "scope", .value = scope },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "state", .value = state },
        .{ .name = "id_token_add_organizations", .value = "true" },
        .{ .name = "codex_cli_simplified_flow", .value = "true" },
        .{ .name = "originator", .value = originator },
    });
    const url = try std.fmt.allocPrint(a, "{s}?{s}", .{ authorize_url, query });
    return .{ .arena = arena, .verifier = verifier, .state = state, .url = url };
}

pub fn parseAuthorizationInput(input: []const u8) AuthorizationInput {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return .{};

    if (std.mem.indexOf(u8, value, "://") != null) {
        if (std.Uri.parse(value)) |uri| {
            if (uri.query) |query| {
                return parseQuery(switch (query) {
                    .raw => |raw| raw,
                    .percent_encoded => |percent_encoded| percent_encoded,
                });
            }
            return .{};
        } else |_| {}
    }

    if (std.mem.indexOfScalar(u8, value, '#')) |index| {
        return .{ .code = value[0..index], .state = value[index + 1 ..] };
    }

    if (std.mem.indexOf(u8, value, "code=") != null) return parseQuery(value);
    return .{ .code = value };
}

fn exchangeAuthorizationCodeForCredentials(
    allocator: std.mem.Allocator,
    code: []const u8,
    verifier: []const u8,
    redirect: []const u8,
    transport: OAuthHttpTransport,
    signal: ?*types.AbortSignal,
    clock: device_code.Clock,
) !OAuthCredentialsResult {
    if (isAborted(signal)) return .{ .failed = try failure(allocator, device_code.cancel_message) };
    const body = try buildForm(allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "code", .value = code },
        .{ .name = "code_verifier", .value = verifier },
        .{ .name = "redirect_uri", .value = redirect },
    });
    defer allocator.free(body);

    var response = try sendJsonOrForm(allocator, transport, token_url, "application/x-www-form-urlencoded", body);
    defer response.deinit();
    return readTokenCredentials(allocator, response, "exchange", clock.now());
}

const DeviceAuthInfo = struct {
    allocator: std.mem.Allocator,
    device_auth_id: []u8,
    user_code: []u8,
    interval_seconds: f64,

    fn deinit(self: *DeviceAuthInfo) void {
        self.allocator.free(self.device_auth_id);
        self.allocator.free(self.user_code);
    }
};

const DeviceAuthResult = union(enum) {
    device: DeviceAuthInfo,
    failed: device_code.FlowFailure,
};

fn startOpenAICodexDeviceAuth(
    allocator: std.mem.Allocator,
    transport: OAuthHttpTransport,
    signal: ?*types.AbortSignal,
) !DeviceAuthResult {
    if (isAborted(signal)) return .{ .failed = try failure(allocator, device_code.cancel_message) };
    var response = try sendJsonOrForm(
        allocator,
        transport,
        device_user_code_url,
        "application/json",
        "{\"client_id\":\"" ++ client_id ++ "\"}",
    );
    defer response.deinit();

    if (response.status == 404) {
        return .{ .failed = try failure(
            allocator,
            "OpenAI Codex device code login is not enabled for this server. Use browser login or verify the server URL.",
        ) };
    }

    if (!isSuccessStatus(response.status)) {
        return .{ .failed = try failureFmt(
            allocator,
            "OpenAI Codex device code request failed with status {d}{s}{s}",
            .{
                response.status,
                if (response.body.len > 0) ": " else "",
                response.body,
            },
        ) };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        return .{ .failed = try failureFmt(
            allocator,
            "Invalid OpenAI Codex device code response: {s}",
            .{response.body},
        ) };
    };
    defer parsed.deinit();
    const object = parsed.value.object;
    const device_auth_id_value = object.get("device_auth_id") orelse return .{ .failed = try invalidDeviceCodeResponse(allocator, response.body) };
    const user_code_value = object.get("user_code") orelse return .{ .failed = try invalidDeviceCodeResponse(allocator, response.body) };
    const interval_value = object.get("interval") orelse return .{ .failed = try invalidDeviceCodeResponse(allocator, response.body) };
    if (device_auth_id_value != .string or user_code_value != .string) {
        return .{ .failed = try invalidDeviceCodeResponse(allocator, response.body) };
    }
    const interval = parseIntervalSeconds(interval_value) orelse
        return .{ .failed = try invalidDeviceCodeResponse(allocator, response.body) };

    const device_auth_id = try allocator.dupe(u8, device_auth_id_value.string);
    errdefer allocator.free(device_auth_id);
    const user_code = try allocator.dupe(u8, user_code_value.string);
    return .{ .device = .{
        .allocator = allocator,
        .device_auth_id = device_auth_id,
        .user_code = user_code,
        .interval_seconds = interval,
    } };
}

fn invalidDeviceCodeResponse(allocator: std.mem.Allocator, body: []const u8) !device_code.FlowFailure {
    return failureFmt(allocator, "Invalid OpenAI Codex device code response: {s}", .{body});
}

const DeviceTokenSuccess = struct {
    allocator: std.mem.Allocator,
    authorization_code: []u8,
    code_verifier: []u8,

    fn deinit(self: *DeviceTokenSuccess) void {
        self.allocator.free(self.authorization_code);
        self.allocator.free(self.code_verifier);
    }
};

const DevicePollState = struct {
    device: DeviceAuthInfo,
    transport: OAuthHttpTransport,
    signal: ?*types.AbortSignal,
};

fn pollOpenAICodexDeviceAuth(
    allocator: std.mem.Allocator,
    device: DeviceAuthInfo,
    transport: OAuthHttpTransport,
    options: OpenAICodexDeviceCodeLoginOptions,
) !device_code.FlowResult(DeviceTokenSuccess) {
    var state: DevicePollState = .{
        .device = device,
        .transport = transport,
        .signal = options.signal,
    };
    return device_code.pollOAuthDeviceCodeFlow(DeviceTokenSuccess, allocator, .{
        .interval_seconds = device.interval_seconds,
        .expires_in_seconds = device_code_timeout_seconds,
        .poller = .{ .ptr = &state, .poll = pollDeviceAuthToken },
        .signal = options.signal,
        .clock = options.clock,
        .sleeper = options.sleeper,
    });
}

fn pollDeviceAuthToken(
    ptr: *anyopaque,
    allocator: std.mem.Allocator,
) anyerror!device_code.PollResult(DeviceTokenSuccess) {
    const state: *DevicePollState = @ptrCast(@alignCast(ptr));
    if (isAborted(state.signal)) return .{ .failed = device_code.cancel_message };
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}",
        .{ state.device.device_auth_id, state.device.user_code },
    );
    defer allocator.free(body);

    var response = try sendJsonOrForm(allocator, state.transport, device_token_url, "application/json", body);
    defer response.deinit();

    if (isSuccessStatus(response.status)) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
            return .{ .failed_owned = try std.fmt.allocPrint(
                allocator,
                "Invalid OpenAI Codex device auth token response: {s}",
                .{response.body},
            ) };
        };
        defer parsed.deinit();
        const object = parsed.value.object;
        const code = object.get("authorization_code") orelse return .{ .failed_owned = try std.fmt.allocPrint(
            allocator,
            "Invalid OpenAI Codex device auth token response: {s}",
            .{response.body},
        ) };
        const verifier = object.get("code_verifier") orelse return .{ .failed_owned = try std.fmt.allocPrint(
            allocator,
            "Invalid OpenAI Codex device auth token response: {s}",
            .{response.body},
        ) };
        if (code != .string or verifier != .string) {
            return .{ .failed_owned = try std.fmt.allocPrint(
                allocator,
                "Invalid OpenAI Codex device auth token response: {s}",
                .{response.body},
            ) };
        }
        const authorization_code = try allocator.dupe(u8, code.string);
        errdefer allocator.free(authorization_code);
        const code_verifier = try allocator.dupe(u8, verifier.string);
        return .{ .complete = .{
            .allocator = allocator,
            .authorization_code = authorization_code,
            .code_verifier = code_verifier,
        } };
    }

    if (response.status == 403 or response.status == 404) return .pending;

    switch (deviceErrorPollStatus(response.body)) {
        .pending => return .pending,
        .slow_down => return .slow_down,
        .none => {},
    }

    return .{ .failed_owned = try std.fmt.allocPrint(
        allocator,
        "OpenAI Codex device auth failed with status {d}{s}{s}",
        .{
            response.status,
            if (response.body.len > 0) ": " else "",
            response.body,
        },
    ) };
}

const OAuthToken = struct {
    allocator: std.mem.Allocator,
    access: []u8,
    refresh: []u8,
    expires: i64,

    fn deinit(self: *OAuthToken) void {
        self.allocator.free(self.access);
        self.allocator.free(self.refresh);
    }
};

fn readTokenCredentials(
    allocator: std.mem.Allocator,
    response: OAuthHttpResponse,
    operation: []const u8,
    now_ms: i64,
) !OAuthCredentialsResult {
    var token_result = try readTokenResponse(allocator, response, operation, now_ms);
    switch (token_result) {
        .failed => |failure_value| return .{ .failed = failure_value },
        .token => |*token| {
            defer token.deinit();
            return credentialsFromToken(allocator, token.*);
        },
    }
}

const TokenResult = union(enum) {
    token: OAuthToken,
    failed: device_code.FlowFailure,
};

fn readTokenResponse(
    allocator: std.mem.Allocator,
    response: OAuthHttpResponse,
    operation: []const u8,
    now_ms: i64,
) !TokenResult {
    if (!isSuccessStatus(response.status)) {
        const status_text = if (response.body.len > 0) response.body else response.status_text;
        return .{ .failed = try failureFmt(
            allocator,
            "OpenAI Codex token {s} failed ({d}): {s}",
            .{ operation, response.status, status_text },
        ) };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        return .{ .failed = try failureFmt(
            allocator,
            "OpenAI Codex token {s} response missing fields: {s}",
            .{ operation, response.body },
        ) };
    };
    defer parsed.deinit();
    const object = parsed.value.object;
    const access = object.get("access_token") orelse return .{ .failed = try missingTokenFields(allocator, operation, response.body) };
    const refresh = object.get("refresh_token") orelse return .{ .failed = try missingTokenFields(allocator, operation, response.body) };
    const expires = object.get("expires_in") orelse return .{ .failed = try missingTokenFields(allocator, operation, response.body) };
    if (access != .string or refresh != .string) return .{ .failed = try missingTokenFields(allocator, operation, response.body) };
    const expires_seconds = jsonNumberToF64(expires) orelse return .{ .failed = try missingTokenFields(allocator, operation, response.body) };

    const access_copy = try allocator.dupe(u8, access.string);
    errdefer allocator.free(access_copy);
    const refresh_copy = try allocator.dupe(u8, refresh.string);
    return .{ .token = .{
        .allocator = allocator,
        .access = access_copy,
        .refresh = refresh_copy,
        .expires = now_ms + @as(i64, @intFromFloat(@floor(expires_seconds * 1000))),
    } };
}

fn missingTokenFields(
    allocator: std.mem.Allocator,
    operation: []const u8,
    body: []const u8,
) !device_code.FlowFailure {
    return failureFmt(
        allocator,
        "OpenAI Codex token {s} response missing fields: {s}",
        .{ operation, body },
    );
}

fn credentialsFromToken(allocator: std.mem.Allocator, token: OAuthToken) !OAuthCredentialsResult {
    const account_id = openai_codex_responses.extractAccountId(allocator, token.access) catch {
        return .{ .failed = try failure(allocator, "Failed to extract accountId from token") };
    };
    defer allocator.free(account_id);

    const access = try allocator.dupe(u8, token.access);
    errdefer allocator.free(access);
    const refresh = try allocator.dupe(u8, token.refresh);
    errdefer allocator.free(refresh);
    const account = try allocator.dupe(u8, account_id);
    return .{ .credentials = .{
        .allocator = allocator,
        .access = access,
        .refresh = refresh,
        .expires = token.expires,
        .account_id = account,
    } };
}

fn sendJsonOrForm(
    allocator: std.mem.Allocator,
    transport: OAuthHttpTransport,
    url: []const u8,
    content_type: []const u8,
    body: []const u8,
) !OAuthHttpResponse {
    const request_headers = [_]types.Header{.{ .name = "Content-Type", .value = content_type }};
    return transport.send(allocator, .{
        .method = .post,
        .url = url,
        .headers = &request_headers,
        .body = body,
    });
}

fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

fn isAborted(signal: ?*types.AbortSignal) bool {
    return if (signal) |abort_signal| abort_signal.isAborted() else false;
}

fn parseIntervalSeconds(value: std.json.Value) ?f64 {
    const seconds = switch (value) {
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        .float => |float| float,
        .string => |string| std.fmt.parseFloat(f64, std.mem.trim(u8, string, " \t\r\n")) catch return null,
        else => return null,
    };
    if (!std.math.isFinite(seconds) or seconds < 0) return null;
    return seconds;
}

fn jsonNumberToF64(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

const DeviceErrorPollStatus = enum {
    none,
    pending,
    slow_down,
};

fn deviceErrorPollStatus(body: []const u8) DeviceErrorPollStatus {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.smp_allocator, body, .{}) catch return .none;
    defer parsed.deinit();
    const error_value = parsed.value.object.get("error") orelse return .none;
    const code = switch (error_value) {
        .string => |string| string,
        .object => |object| blk: {
            const code_value = object.get("code") orelse return .none;
            break :blk if (code_value == .string) code_value.string else return .none;
        },
        else => return .none,
    };
    if (std.mem.eql(u8, code, "deviceauth_authorization_pending")) return .pending;
    if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
    return .none;
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

fn parseQuery(query: []const u8) AuthorizationInput {
    var result: AuthorizationInput = .{};
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "code")) result.code = value;
        if (std.mem.eql(u8, key, "state")) result.state = value;
    }
    return result;
}

fn createState(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    return hexEncode(allocator, &bytes);
}

fn generateVerifier(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [32]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    return base64UrlNoPad(allocator, &bytes);
}

fn generateChallenge(allocator: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return base64UrlNoPad(allocator, &digest);
}

fn base64UrlNoPad(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
    return encoded;
}

fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        encoded[index * 2] = digits[byte >> 4];
        encoded[index * 2 + 1] = digits[byte & 0x0f];
    }
    return encoded;
}

fn failure(allocator: std.mem.Allocator, message: []const u8) !device_code.FlowFailure {
    return device_code.failure(allocator, message);
}

fn failureFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !device_code.FlowFailure {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    return failure(allocator, message);
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
        .payload = request.body,
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

fn stdHttpHeaders(allocator: std.mem.Allocator, headers: []const types.Header) ![]std.http.Header {
    const result = try allocator.alloc(std.http.Header, headers.len);
    for (headers, 0..) |header, index| {
        result[index] = .{ .name = header.name, .value = header.value };
    }
    return result;
}

const RecordedOAuthRequest = struct {
    url: []u8,
    content_type: ?[]u8 = null,
    body: []u8,

    fn deinit(self: *RecordedOAuthRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.content_type) |content_type| allocator.free(content_type);
        allocator.free(self.body);
    }
};

const FakeOAuthResponse = struct {
    status: u16 = 200,
    body: []const u8,
    status_text: []const u8 = "",
};

const FakeOAuthTransport = struct {
    allocator: std.mem.Allocator,
    responses: []const FakeOAuthResponse,
    repeat_last: bool = false,
    index: usize = 0,
    records: std.ArrayList(RecordedOAuthRequest) = .empty,

    fn init(allocator: std.mem.Allocator, responses: []const FakeOAuthResponse) FakeOAuthTransport {
        return .{ .allocator = allocator, .responses = responses };
    }

    fn deinit(self: *FakeOAuthTransport) void {
        for (self.records.items) |*record| record.deinit(self.allocator);
        self.records.deinit(self.allocator);
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
        const content_type = findHeader(request_value.headers, "Content-Type");
        try self.records.append(self.allocator, .{
            .url = try self.allocator.dupe(u8, request_value.url),
            .content_type = if (content_type) |value| try self.allocator.dupe(u8, value) else null,
            .body = try self.allocator.dupe(u8, request_value.body),
        });
        const spec = if (self.index < self.responses.len) blk: {
            const next = self.responses[self.index];
            self.index += 1;
            break :blk next;
        } else if (self.repeat_last and self.responses.len > 0)
            self.responses[self.responses.len - 1]
        else
            return error.UnexpectedRequest;

        const status_text = try allocator.dupe(u8, spec.status_text);
        errdefer allocator.free(status_text);
        const body = try allocator.dupe(u8, spec.body);
        return .{
            .allocator = allocator,
            .status = spec.status,
            .status_text = status_text,
            .body = body,
        };
    }
};

fn findHeader(headers: []const types.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

const TestDeviceInfoRecorder = struct {
    allocator: std.mem.Allocator,
    infos: std.ArrayList(OAuthDeviceCodeInfo) = .empty,

    fn deinit(self: *TestDeviceInfoRecorder) void {
        for (self.infos.items) |info| {
            self.allocator.free(info.user_code);
            self.allocator.free(info.verification_uri);
        }
        self.infos.deinit(self.allocator);
    }

    fn call(ptr: ?*anyopaque, info: OAuthDeviceCodeInfo) anyerror!void {
        const self: *TestDeviceInfoRecorder = @ptrCast(@alignCast(ptr.?));
        try self.infos.append(self.allocator, .{
            .user_code = try self.allocator.dupe(u8, info.user_code),
            .verification_uri = try self.allocator.dupe(u8, info.verification_uri),
            .interval_seconds = info.interval_seconds,
            .expires_in_seconds = info.expires_in_seconds,
        });
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
    abort_after_sleep: ?*types.AbortSignal = null,
    delays: std.ArrayList(u64) = .empty,

    fn deinit(self: *TestSleeper) void {
        self.delays.deinit(self.allocator);
    }

    fn sleep(ptr: ?*anyopaque, millis: u64, signal: ?*types.AbortSignal) !void {
        const self: *TestSleeper = @ptrCast(@alignCast(ptr.?));
        if (signal) |abort_signal| {
            if (abort_signal.isAborted()) return error.Aborted;
        }
        try self.delays.append(self.allocator, millis);
        self.clock.now_value += @intCast(millis);
        if (self.abort_after_sleep) |abort_signal| {
            abort_signal.abort();
            return error.Aborted;
        }
    }
};

fn createAccessToken(allocator: std.mem.Allocator, account_id: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\"}}}}",
        .{account_id},
    );
    defer allocator.free(payload);
    const encoded_len = std.base64.standard_no_pad.Encoder.calcSize(payload.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "header.{s}.signature", .{encoded});
}

test "OpenAI Codex OAuth logs in with the device code flow" {
    const allocator = std.testing.allocator;
    const access_token = try createAccessToken(allocator, "account-123");
    defer allocator.free(access_token);
    const token_body = try std.fmt.allocPrint(
        allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh-token\",\"expires_in\":3600}}",
        .{access_token},
    );
    defer allocator.free(token_body);
    const responses = [_]FakeOAuthResponse{
        .{ .body = "{\"device_auth_id\":\"device-auth-id\",\"user_code\":\"ABCD-1234\",\"interval\":\"5\"}" },
        .{ .status = 403, .body = "{\"error\":{\"message\":\"Device authorization is pending. Please try again.\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":\"deviceauth_authorization_pending\"}}" },
        .{ .body = "{\"authorization_code\":\"oauth-code\",\"code_challenge\":\"device-code-challenge\",\"code_verifier\":\"device-code-verifier\"}" },
        .{ .body = token_body },
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();
    var clock: TestClock = .{ .now_value = 1_779_235_200_000 };
    var sleeper: TestSleeper = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();
    var infos: TestDeviceInfoRecorder = .{ .allocator = allocator };
    defer infos.deinit();

    var result = try loginOpenAICodexDeviceCode(allocator, .{
        .transport = transport.transport(),
        .on_device_code = .{ .ptr = &infos, .call = TestDeviceInfoRecorder.call },
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = TestSleeper.sleep },
    });
    defer result.deinit();

    const credentials = result.credentials;
    try std.testing.expectEqualStrings(access_token, credentials.access);
    try std.testing.expectEqualStrings("refresh-token", credentials.refresh);
    try std.testing.expectEqualStrings("account-123", credentials.account_id);
    try std.testing.expectEqual(@as(i64, 1_779_238_805_000), credentials.expires);
    try std.testing.expectEqual(@as(usize, 1), infos.infos.items.len);
    try std.testing.expectEqualStrings("ABCD-1234", infos.infos.items[0].user_code);
    try std.testing.expectEqualStrings(device_verification_uri, infos.infos.items[0].verification_uri);
    try std.testing.expectEqual(@as(f64, 5), infos.infos.items[0].interval_seconds);
    try std.testing.expectEqual(@as(u64, 900), infos.infos.items[0].expires_in_seconds);
    try std.testing.expectEqual(@as(usize, 1), sleeper.delays.items.len);
    try std.testing.expectEqual(@as(u64, 5000), sleeper.delays.items[0]);

    try std.testing.expectEqual(@as(usize, 4), transport.records.items.len);
    try std.testing.expectEqualStrings(device_user_code_url, transport.records.items[0].url);
    try std.testing.expectEqualStrings("application/json", transport.records.items[0].content_type.?);
    try std.testing.expectEqualStrings("{\"client_id\":\"app_EMoamEEZ73f0CkXaXp7hrann\"}", transport.records.items[0].body);
    try std.testing.expectEqualStrings(device_token_url, transport.records.items[1].url);
    try std.testing.expectEqualStrings("{\"device_auth_id\":\"device-auth-id\",\"user_code\":\"ABCD-1234\"}", transport.records.items[1].body);
    try std.testing.expectEqualStrings(token_url, transport.records.items[3].url);
    try std.testing.expectEqualStrings("application/x-www-form-urlencoded", transport.records.items[3].content_type.?);
    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code=oauth-code&code_verifier=device-code-verifier&redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback",
        transport.records.items[3].body,
    );
}

const TestSelectRecorder = struct {
    prompts: std.ArrayList(OAuthSelectPrompt) = .empty,
    selected: ?[]const u8 = null,

    fn deinit(self: *TestSelectRecorder, allocator: std.mem.Allocator) void {
        self.prompts.deinit(allocator);
    }

    fn call(ptr: ?*anyopaque, prompt: OAuthSelectPrompt) anyerror!?[]const u8 {
        const self: *TestSelectRecorder = @ptrCast(@alignCast(ptr.?));
        try self.prompts.append(std.testing.allocator, prompt);
        return self.selected;
    }
};

test "OpenAI Codex OAuth provider offers browser first and uses selected device code flow" {
    const allocator = std.testing.allocator;
    const access_token = try createAccessToken(allocator, "account-456");
    defer allocator.free(access_token);
    const token_body = try std.fmt.allocPrint(
        allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh-token\",\"expires_in\":3600}}",
        .{access_token},
    );
    defer allocator.free(token_body);
    const responses = [_]FakeOAuthResponse{
        .{ .body = "{\"device_auth_id\":\"device-auth-id\",\"user_code\":\"WXYZ-7890\",\"interval\":\"5\"}" },
        .{ .body = "{\"authorization_code\":\"oauth-code\",\"code_challenge\":\"device-code-challenge\",\"code_verifier\":\"device-code-verifier\"}" },
        .{ .body = token_body },
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();
    var clock: TestClock = .{ .now_value = 0 };
    var infos: TestDeviceInfoRecorder = .{ .allocator = allocator };
    defer infos.deinit();
    var select: TestSelectRecorder = .{ .selected = device_code_login_method };
    defer select.deinit(allocator);

    var result = try openai_codex_oauth_provider.login(allocator, .{
        .transport = transport.transport(),
        .on_select = .{ .ptr = &select, .call = TestSelectRecorder.call },
        .on_device_code = .{ .ptr = &infos, .call = TestDeviceInfoRecorder.call },
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &clock, .sleep_ms = noopSleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(access_token, result.credentials.access);
    try std.testing.expectEqualStrings("account-456", result.credentials.account_id);
    try std.testing.expectEqual(@as(usize, 1), select.prompts.items.len);
    try std.testing.expectEqualStrings("Select OpenAI Codex login method:", select.prompts.items[0].message);
    try std.testing.expectEqual(@as(usize, 2), select.prompts.items[0].options.len);
    try std.testing.expectEqualStrings(browser_login_method, select.prompts.items[0].options[0].id);
    try std.testing.expectEqualStrings("Browser login (default)", select.prompts.items[0].options[0].label);
    try std.testing.expectEqualStrings(device_code_login_method, select.prompts.items[0].options[1].id);
    try std.testing.expectEqualStrings("Device code login (headless)", select.prompts.items[0].options[1].label);
    try std.testing.expectEqual(@as(usize, 1), infos.infos.items.len);
    try std.testing.expectEqualStrings("WXYZ-7890", infos.infos.items[0].user_code);
}

fn noopSleep(_: ?*anyopaque, _: u64, _: ?*types.AbortSignal) anyerror!void {}

test "OpenAI Codex OAuth provider cancels when login method selection is cancelled" {
    const allocator = std.testing.allocator;
    var select: TestSelectRecorder = .{ .selected = null };
    defer select.deinit(allocator);

    var result = try openai_codex_oauth_provider.login(allocator, .{
        .on_select = .{ .ptr = &select, .call = TestSelectRecorder.call },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(device_code.cancel_message, result.failed.message);
}

test "OpenAI Codex OAuth cancels device code flow while waiting" {
    const allocator = std.testing.allocator;
    const responses = [_]FakeOAuthResponse{
        .{ .body = "{\"device_auth_id\":\"device-auth-id\",\"user_code\":\"ABCD-1234\",\"interval\":\"5\"}" },
        .{ .status = 403, .body = "{\"error\":{\"code\":\"deviceauth_authorization_pending\"}}" },
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();
    var signal: types.AbortSignal = .{};
    var clock: TestClock = .{ .now_value = 0 };
    var sleeper: TestSleeper = .{ .allocator = allocator, .clock = &clock, .abort_after_sleep = &signal };
    defer sleeper.deinit();

    var result = try loginOpenAICodexDeviceCode(allocator, .{
        .transport = transport.transport(),
        .signal = &signal,
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = TestSleeper.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(device_code.cancel_message, result.failed.message);
}

test "OpenAI Codex OAuth times out device code flow after fifteen minutes" {
    const allocator = std.testing.allocator;
    const responses = [_]FakeOAuthResponse{
        .{ .body = "{\"device_auth_id\":\"device-auth-id\",\"user_code\":\"ABCD-1234\",\"interval\":\"60\"}" },
        .{ .status = 403, .body = "{\"error\":{\"code\":\"deviceauth_authorization_pending\"}}" },
        .{ .status = 403, .body = "{\"error\":{\"code\":\"deviceauth_authorization_pending\"}}" },
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    transport.repeat_last = true;
    defer transport.deinit();
    var clock: TestClock = .{ .now_value = 0 };
    var sleeper: TestSleeper = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();

    var result = try loginOpenAICodexDeviceCode(allocator, .{
        .transport = transport.transport(),
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = TestSleeper.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(device_code.timeout_message, result.failed.message);
    try std.testing.expectEqual(@as(usize, 15), sleeper.delays.items.len);
    try std.testing.expectEqual(@as(u64, 60_000), sleeper.delays.items[0]);
    try std.testing.expectEqual(@as(i64, 900_000), clock.now_value);
}

test "OpenAI Codex OAuth treats device auth 403 and 404 responses as pending" {
    const allocator = std.testing.allocator;
    const access_token = try createAccessToken(allocator, "account-403-404");
    defer allocator.free(access_token);
    const token_body = try std.fmt.allocPrint(
        allocator,
        "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh-token\",\"expires_in\":3600}}",
        .{access_token},
    );
    defer allocator.free(token_body);
    const responses = [_]FakeOAuthResponse{
        .{ .body = "{\"device_auth_id\":\"device-auth-id\",\"user_code\":\"ABCD-1234\",\"interval\":\"1\"}" },
        .{ .status = 403, .body = "{\"error\":\"access_denied\",\"error_description\":\"denied\"}" },
        .{ .status = 404, .body = "not ready" },
        .{ .body = "{\"authorization_code\":\"oauth-code\",\"code_challenge\":\"device-code-challenge\",\"code_verifier\":\"device-code-verifier\"}" },
        .{ .body = token_body },
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();
    var clock: TestClock = .{ .now_value = 0 };
    var sleeper: TestSleeper = .{ .allocator = allocator, .clock = &clock };
    defer sleeper.deinit();

    var result = try loginOpenAICodexDeviceCode(allocator, .{
        .transport = transport.transport(),
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
        .sleeper = .{ .ptr = &sleeper, .sleep_ms = TestSleeper.sleep },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("account-403-404", result.credentials.account_id);
    try std.testing.expectEqual(@as(usize, 5), transport.records.items.len);
}

test "OpenAI Codex OAuth includes response body in device auth poll failures" {
    const allocator = std.testing.allocator;
    const responses = [_]FakeOAuthResponse{
        .{ .body = "{\"device_auth_id\":\"device-auth-id\",\"user_code\":\"ABCD-1234\",\"interval\":\"5\"}" },
        .{ .status = 500, .body = "{\"error\":\"server_error\",\"error_description\":\"try again later\"}" },
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();

    var result = try loginOpenAICodexDeviceCode(allocator, .{ .transport = transport.transport() });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "OpenAI Codex device auth failed with status 500: {\"error\":\"server_error\",\"error_description\":\"try again later\"}",
        result.failed.message,
    );
}

test "OpenAI Codex OAuth refresh reports token failures without stderr side effects" {
    const allocator = std.testing.allocator;
    const responses = [_]FakeOAuthResponse{.{
        .status = 401,
        .status_text = "Unauthorized",
        .body = "{\"error\":{\"message\":\"Could not validate your token. Please try signing in again.\",\"type\":\"invalid_request_error\"}}",
    }};
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();
    var clock: TestClock = .{ .now_value = 0 };

    var result = try refreshOpenAICodexToken(
        allocator,
        "invalid-refresh-token",
        transport.transport(),
        .{ .ptr = &clock, .now_ms = TestClock.now },
    );
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(u8, result.failed.message, "OpenAI Codex token refresh failed (401)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.failed.message, "Could not validate your token") != null);
    try std.testing.expectEqualStrings(token_url, transport.records.items[0].url);
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&refresh_token=invalid-refresh-token&client_id=app_EMoamEEZ73f0CkXaXp7hrann",
        transport.records.items[0].body,
    );
}

test "OpenAI Codex OAuth parses authorization input and builds Bulb originator URLs" {
    const allocator = std.testing.allocator;
    const from_url = parseAuthorizationInput("http://localhost:1455/auth/callback?code=abc&state=state-1");
    try std.testing.expectEqualStrings("abc", from_url.code.?);
    try std.testing.expectEqualStrings("state-1", from_url.state.?);
    const from_hash = parseAuthorizationInput("abc#state-2");
    try std.testing.expectEqualStrings("abc", from_hash.code.?);
    try std.testing.expectEqualStrings("state-2", from_hash.state.?);
    const from_code = parseAuthorizationInput("oauth-code");
    try std.testing.expectEqualStrings("oauth-code", from_code.code.?);

    var flow = try createAuthorizationFlow(allocator, "bulb");
    defer flow.deinit();
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "originator=bulb") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "codex_cli_simplified_flow=true") != null);
    try std.testing.expectEqual(@as(usize, 32), flow.state.len);
}
