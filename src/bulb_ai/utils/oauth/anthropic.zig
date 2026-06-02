const std = @import("std");
const ai_types = @import("../../types.zig");
const device_code = @import("device_code.zig");
const oauth_page = @import("oauth_page.zig");
const oauth_types = @import("types.zig");

pub const callback_host_env = "BULB_OAUTH_CALLBACK_HOST";
pub const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const authorize_url = "https://claude.ai/oauth/authorize";
pub const token_url = "https://platform.claude.com/v1/oauth/token";
pub const default_callback_host = "127.0.0.1";
pub const callback_port: u16 = 53692;
pub const callback_path = "/callback";
pub const redirect_uri = "http://localhost:53692/callback";
pub const scopes =
    "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

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

    pub fn deinit(self: *OAuthCredentials) void {
        self.allocator.free(self.refresh);
        self.allocator.free(self.access);
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

pub const LoginOptions = struct {
    transport: ?OAuthHttpTransport = null,
    callback_server_factory: OAuthCallbackServerFactory = .{},
    env: ?*const std.process.Environ.Map = null,
    on_auth: ?oauth_types.AuthCallback = null,
    on_prompt: ?oauth_types.PromptCallback = null,
    on_progress: ?oauth_types.ProgressCallback = null,
    on_manual_code_input: ?oauth_types.ManualCodeInputCallback = null,
    clock: device_code.Clock = .{},
};

pub const AnthropicOAuthProvider = struct {
    pub const id = "anthropic";
    pub const name = "Anthropic (Claude Pro/Max)";
    pub const uses_callback_server = true;

    pub fn login(
        _: AnthropicOAuthProvider,
        allocator: std.mem.Allocator,
        options: LoginOptions,
    ) !OAuthCredentialsResult {
        return loginAnthropic(allocator, options);
    }

    pub fn refreshToken(
        _: AnthropicOAuthProvider,
        allocator: std.mem.Allocator,
        credentials: OAuthCredentials,
        transport: ?OAuthHttpTransport,
        clock: device_code.Clock,
    ) !OAuthCredentialsResult {
        return refreshAnthropicToken(allocator, credentials.refresh, transport, clock);
    }

    pub fn getApiKey(_: AnthropicOAuthProvider, credentials: OAuthCredentials) []const u8 {
        return credentials.access;
    }
};

pub const anthropic_oauth_provider: AnthropicOAuthProvider = .{};

pub const AuthorizationInput = struct {
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

const OwnedAuthorizationInput = struct {
    allocator: std.mem.Allocator,
    code: ?[]u8 = null,
    state: ?[]u8 = null,

    fn deinit(self: *OwnedAuthorizationInput) void {
        if (self.code) |code| self.allocator.free(code);
        if (self.state) |state| self.allocator.free(state);
    }
};

pub const AuthorizationFlow = struct {
    arena: std.heap.ArenaAllocator,
    verifier: []const u8,
    url: []const u8,

    pub fn deinit(self: *AuthorizationFlow) void {
        self.arena.deinit();
    }
};

pub fn loginAnthropic(
    allocator: std.mem.Allocator,
    options: LoginOptions,
) !OAuthCredentialsResult {
    var flow = try createAuthorizationFlow(allocator);
    defer flow.deinit();

    var server = try options.callback_server_factory.startServer(allocator, flow.verifier, options.env);
    defer server.closeServer();

    if (options.on_auth) |callback| {
        try callback.invoke(.{
            .url = flow.url,
            .instructions = "Complete login in your browser. If the browser is on another machine, paste the final redirect URL here.",
        });
    }

    var authorization: ?CallbackCode = null;
    defer if (authorization) |*value| value.deinit();

    if (options.on_manual_code_input) |callback| {
        const input = try callback.invoke();
        if (std.mem.trim(u8, input, " \t\r\n").len > 0) {
            authorization = authorizationFromInput(allocator, input, flow.verifier) catch |err| switch (err) {
                error.OAuthStateMismatch => return .{ .failed = try failure(allocator, "OAuth state mismatch") },
                else => return err,
            };
        } else {
            authorization = try server.waitForCode(allocator);
        }
    } else {
        authorization = try server.waitForCode(allocator);
    }

    if (authorization == null) {
        if (options.on_prompt) |callback| {
            const input = try callback.invoke(.{
                .message = "Paste the authorization code or full redirect URL:",
                .placeholder = redirect_uri,
            });
            authorization = authorizationFromInput(allocator, input, flow.verifier) catch |err| switch (err) {
                error.OAuthStateMismatch => return .{ .failed = try failure(allocator, "OAuth state mismatch") },
                else => return err,
            };
        }
    }

    const selected = authorization orelse
        return .{ .failed = try failure(allocator, "Missing authorization code") };
    if (options.on_progress) |callback| {
        try callback.invoke("Exchanging authorization code for tokens...");
    }
    return exchangeAuthorizationCode(
        allocator,
        selected.code,
        selected.state,
        flow.verifier,
        redirect_uri,
        options.transport,
        options.clock,
    );
}

pub fn refreshAnthropicToken(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
    maybe_transport: ?OAuthHttpTransport,
    clock: device_code.Clock,
) !OAuthCredentialsResult {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = refresh_token,
    }, .{});
    defer allocator.free(body);

    var std_transport: StdOAuthHttpTransport = .{};
    const default_transport: OAuthHttpTransport = .{ .ptr = &std_transport, .request = stdOAuthHttpRequest };
    var response = try postJson(allocator, maybe_transport orelse default_transport, token_url, body);
    defer response.deinit();
    return readTokenCredentials(allocator, response, "Anthropic token refresh", clock.now());
}

fn exchangeAuthorizationCode(
    allocator: std.mem.Allocator,
    code: []const u8,
    state: []const u8,
    verifier: []const u8,
    redirect: []const u8,
    maybe_transport: ?OAuthHttpTransport,
    clock: device_code.Clock,
) !OAuthCredentialsResult {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .code = code,
        .state = state,
        .redirect_uri = redirect,
        .code_verifier = verifier,
    }, .{});
    defer allocator.free(body);

    var std_transport: StdOAuthHttpTransport = .{};
    const default_transport: OAuthHttpTransport = .{ .ptr = &std_transport, .request = stdOAuthHttpRequest };
    var response = try postJson(allocator, maybe_transport orelse default_transport, token_url, body);
    defer response.deinit();
    return readTokenCredentials(allocator, response, "Token exchange", clock.now());
}

fn postJson(
    allocator: std.mem.Allocator,
    transport: OAuthHttpTransport,
    url: []const u8,
    body: []const u8,
) !OAuthHttpResponse {
    const request_headers = [_]ai_types.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    };
    return transport.send(allocator, .{
        .method = .post,
        .url = url,
        .headers = &request_headers,
        .body = body,
    });
}

fn readTokenCredentials(
    allocator: std.mem.Allocator,
    response: OAuthHttpResponse,
    operation: []const u8,
    now_ms: i64,
) !OAuthCredentialsResult {
    if (!isSuccessStatus(response.status)) {
        return .{ .failed = try failureFmt(
            allocator,
            "{s} request failed. url={s}; status={d}; body={s}",
            .{ operation, token_url, response.status, response.body },
        ) };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch {
        return .{ .failed = try failureFmt(
            allocator,
            "{s} returned invalid JSON. url={s}; body={s}",
            .{ operation, token_url, response.body },
        ) };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failed = try invalidTokenFields(allocator, operation, response.body) };
    const object = parsed.value.object;
    const access = object.get("access_token") orelse return .{ .failed = try invalidTokenFields(allocator, operation, response.body) };
    const refresh = object.get("refresh_token") orelse return .{ .failed = try invalidTokenFields(allocator, operation, response.body) };
    const expires = object.get("expires_in") orelse return .{ .failed = try invalidTokenFields(allocator, operation, response.body) };
    if (access != .string or refresh != .string) {
        return .{ .failed = try invalidTokenFields(allocator, operation, response.body) };
    }
    const expires_seconds = jsonNumberToI64(expires) orelse
        return .{ .failed = try invalidTokenFields(allocator, operation, response.body) };

    const refresh_copy = try allocator.dupe(u8, refresh.string);
    errdefer allocator.free(refresh_copy);
    const access_copy = try allocator.dupe(u8, access.string);
    return .{ .credentials = .{
        .allocator = allocator,
        .refresh = refresh_copy,
        .access = access_copy,
        .expires = expirationTime(now_ms, expires_seconds),
    } };
}

fn invalidTokenFields(
    allocator: std.mem.Allocator,
    operation: []const u8,
    body: []const u8,
) !device_code.FlowFailure {
    return failureFmt(allocator, "{s} response missing fields: {s}", .{ operation, body });
}

fn expirationTime(now_ms: i64, expires_seconds: i64) i64 {
    return saturatingSubtract(saturatingAdd(now_ms, saturatingMultiply(expires_seconds, 1000)), 5 * 60 * 1000);
}

pub fn createAuthorizationFlow(allocator: std.mem.Allocator) !AuthorizationFlow {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const verifier = try generateVerifier(a);
    const challenge = try generateChallenge(a, verifier);
    const query = try buildForm(a, &.{
        .{ .name = "code", .value = "true" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "response_type", .value = "code" },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "scope", .value = scopes },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "state", .value = verifier },
    });
    const url = try std.fmt.allocPrint(a, "{s}?{s}", .{ authorize_url, query });
    return .{
        .arena = arena,
        .verifier = verifier,
        .url = url,
    };
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

fn authorizationFromInput(
    allocator: std.mem.Allocator,
    input: []const u8,
    expected_state: []const u8,
) !?CallbackCode {
    var parsed = try ownAuthorizationInput(allocator, parseAuthorizationInput(input));
    defer parsed.deinit();
    if (parsed.state) |state| {
        if (!std.mem.eql(u8, state, expected_state)) {
            return error.OAuthStateMismatch;
        }
    }
    const code = parsed.code orelse return null;
    return try CallbackCode.init(allocator, code, parsed.state orelse expected_state);
}

fn ownAuthorizationInput(
    allocator: std.mem.Allocator,
    parsed: AuthorizationInput,
) !OwnedAuthorizationInput {
    const code = if (parsed.code) |value| try decodeQueryComponent(allocator, value) else null;
    errdefer if (code) |value| allocator.free(value);
    const state = if (parsed.state) |value| try decodeQueryComponent(allocator, value) else null;
    return .{ .allocator = allocator, .code = code, .state = state };
}

const CallbackCode = struct {
    allocator: std.mem.Allocator,
    code: []u8,
    state: []u8,

    fn init(allocator: std.mem.Allocator, code: []const u8, state: []const u8) !CallbackCode {
        const code_copy = try allocator.dupe(u8, code);
        errdefer allocator.free(code_copy);
        return .{
            .allocator = allocator,
            .code = code_copy,
            .state = try allocator.dupe(u8, state),
        };
    }

    fn deinit(self: *CallbackCode) void {
        self.allocator.free(self.code);
        self.allocator.free(self.state);
    }
};

pub const OAuthCallbackServer = struct {
    ptr: *anyopaque,
    wait_for_code: *const fn (*anyopaque, std.mem.Allocator) anyerror!?CallbackCode,
    close: *const fn (*anyopaque) void,

    pub fn waitForCode(self: OAuthCallbackServer, allocator: std.mem.Allocator) !?CallbackCode {
        return self.wait_for_code(self.ptr, allocator);
    }

    pub fn closeServer(self: *OAuthCallbackServer) void {
        self.close(self.ptr);
        self.* = undefined;
    }
};

pub const OAuthCallbackServerFactory = struct {
    ptr: ?*anyopaque = null,
    start: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const u8,
        ?*const std.process.Environ.Map,
    ) anyerror!OAuthCallbackServer = startLocalOAuthCallbackServer,

    pub fn startServer(
        self: OAuthCallbackServerFactory,
        allocator: std.mem.Allocator,
        state: []const u8,
        env: ?*const std.process.Environ.Map,
    ) !OAuthCallbackServer {
        return self.start(self.ptr, allocator, state, env);
    }
};

pub const OAuthCallbackResponse = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    html: []u8,
    code: ?CallbackCode = null,

    pub fn deinit(self: *OAuthCallbackResponse) void {
        self.allocator.free(self.html);
        if (self.code) |*code| code.deinit();
    }

    fn takeCode(self: *OAuthCallbackResponse) ?CallbackCode {
        const code = self.code;
        self.code = null;
        return code;
    }
};

pub fn handleAnthropicCallbackTarget(
    allocator: std.mem.Allocator,
    target: []const u8,
    expected_state: []const u8,
) !OAuthCallbackResponse {
    const query_start = std.mem.indexOfScalar(u8, target, '?');
    const path = if (query_start) |index| target[0..index] else target;
    if (!std.mem.eql(u8, path, callback_path)) {
        return callbackError(allocator, .not_found, "Callback route not found.", null);
    }

    const query = if (query_start) |index| target[index + 1 ..] else "";
    if (queryValue(query, "error")) |encoded_error| {
        const oauth_error = try decodeQueryComponent(allocator, encoded_error);
        defer allocator.free(oauth_error);
        const details = try std.fmt.allocPrint(allocator, "Error: {s}", .{oauth_error});
        defer allocator.free(details);
        return callbackError(allocator, .bad_request, "Anthropic authentication did not complete.", details);
    }

    var parsed = try ownAuthorizationInput(allocator, parseQuery(query));
    defer parsed.deinit();
    const code = parsed.code orelse
        return callbackError(allocator, .bad_request, "Missing code or state parameter.", null);
    const state = parsed.state orelse
        return callbackError(allocator, .bad_request, "Missing code or state parameter.", null);
    if (!std.mem.eql(u8, state, expected_state)) {
        return callbackError(allocator, .bad_request, "State mismatch.", null);
    }
    return .{
        .allocator = allocator,
        .status = .ok,
        .html = try oauth_page.oauthSuccessHtml(
            allocator,
            "Anthropic authentication completed. You can close this window.",
        ),
        .code = try CallbackCode.init(allocator, code, state),
    };
}

fn callbackError(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    message: []const u8,
    details: ?[]const u8,
) !OAuthCallbackResponse {
    return .{
        .allocator = allocator,
        .status = status,
        .html = try oauth_page.oauthErrorHtml(allocator, message, details),
    };
}

const LocalOAuthCallbackServer = struct {
    allocator: std.mem.Allocator,
    listener: ?std.Io.net.Server,
    state: []u8,

    fn start(
        allocator: std.mem.Allocator,
        state: []const u8,
        env: ?*const std.process.Environ.Map,
    ) !*LocalOAuthCallbackServer {
        const self = try allocator.create(LocalOAuthCallbackServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .listener = null,
            .state = try allocator.dupe(u8, state),
        };
        errdefer allocator.free(self.state);

        const io = std.Io.Threaded.global_single_threaded.io();
        const address = std.Io.net.IpAddress.resolve(io, callbackHost(env), callback_port) catch return self;
        self.listener = address.listen(io, .{ .reuse_address = true }) catch return self;
        return self;
    }

    fn waitForCode(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?CallbackCode {
        const self: *LocalOAuthCallbackServer = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        const listener = if (self.listener) |*value| value else return null;
        while (true) {
            const stream = listener.accept(io) catch return null;
            if (try self.handleConnection(allocator, stream)) |code| return code;
        }
    }

    fn handleConnection(
        self: *LocalOAuthCallbackServer,
        allocator: std.mem.Allocator,
        stream: std.Io.net.Stream,
    ) !?CallbackCode {
        const io = std.Io.Threaded.global_single_threaded.io();
        var connection = stream;
        defer connection.close(io);
        var send_buffer: [4096]u8 = undefined;
        var recv_buffer: [4096]u8 = undefined;
        var connection_reader = connection.reader(io, &recv_buffer);
        var connection_writer = connection.writer(io, &send_buffer);
        var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
        var request = server.receiveHead() catch return null;

        var response = try handleAnthropicCallbackTarget(allocator, request.head.target, self.state);
        defer response.deinit();
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
        };
        try request.respond(response.html, .{
            .status = response.status,
            .keep_alive = false,
            .extra_headers = &headers,
        });
        return response.takeCode();
    }

    fn close(ptr: *anyopaque) void {
        const self: *LocalOAuthCallbackServer = @ptrCast(@alignCast(ptr));
        const io = std.Io.Threaded.global_single_threaded.io();
        if (self.listener) |*listener| listener.deinit(io);
        self.allocator.free(self.state);
        self.allocator.destroy(self);
    }

    fn callbackServer(self: *LocalOAuthCallbackServer) OAuthCallbackServer {
        return .{
            .ptr = self,
            .wait_for_code = waitForCode,
            .close = close,
        };
    }
};

pub fn callbackHost(env: ?*const std.process.Environ.Map) []const u8 {
    if (env) |environ| return environ.get(callback_host_env) orelse default_callback_host;
    return default_callback_host;
}

fn startLocalOAuthCallbackServer(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    state: []const u8,
    env: ?*const std.process.Environ.Map,
) !OAuthCallbackServer {
    const server = try LocalOAuthCallbackServer.start(allocator, state, env);
    return server.callbackServer();
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
    return .{
        .code = queryValue(query, "code"),
        .state = queryValue(query, "state"),
    };
}

fn queryValue(query: []const u8, expected_key: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], expected_key)) return pair[eq + 1 ..];
    }
    return null;
}

fn decodeQueryComponent(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const working = try allocator.dupe(u8, encoded);
    defer allocator.free(working);
    for (working) |*byte| {
        if (byte.* == '+') byte.* = ' ';
    }
    return allocator.dupe(u8, std.Uri.percentDecodeInPlace(working));
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

fn isSuccessStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

fn jsonNumberToI64(value: std.json.Value) ?i64 {
    const number = switch (value) {
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        .float => |float| float,
        else => return null,
    };
    if (!std.math.isFinite(number) or number < 0 or number != @floor(number)) return null;
    if (number > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
    return @intFromFloat(number);
}

fn saturatingAdd(left: i64, right: i64) i64 {
    const result = @addWithOverflow(left, right);
    return if (result[1] != 0) std.math.maxInt(i64) else result[0];
}

fn saturatingMultiply(left: i64, right: i64) i64 {
    const result = @mulWithOverflow(left, right);
    return if (result[1] != 0) std.math.maxInt(i64) else result[0];
}

fn saturatingSubtract(left: i64, right: i64) i64 {
    const result = @subWithOverflow(left, right);
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

const RecordedRequest = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    content_type: ?[]u8 = null,
    accept: ?[]u8 = null,
    body: []u8,

    fn deinit(self: *RecordedRequest) void {
        self.allocator.free(self.url);
        if (self.content_type) |content_type| self.allocator.free(content_type);
        if (self.accept) |accept| self.allocator.free(accept);
        self.allocator.free(self.body);
    }
};

const FakeOAuthTransport = struct {
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    records: std.ArrayList(RecordedRequest) = .empty,
    index: usize = 0,

    fn init(allocator: std.mem.Allocator, responses: []const []const u8) FakeOAuthTransport {
        return .{ .allocator = allocator, .responses = responses };
    }

    fn deinit(self: *FakeOAuthTransport) void {
        for (self.records.items) |*record| record.deinit();
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
        if (self.index >= self.responses.len) return error.UnexpectedRequest;
        try self.records.append(self.allocator, .{
            .allocator = self.allocator,
            .url = try self.allocator.dupe(u8, request_value.url),
            .content_type = if (findHeader(request_value.headers, "Content-Type")) |value| try self.allocator.dupe(u8, value) else null,
            .accept = if (findHeader(request_value.headers, "Accept")) |value| try self.allocator.dupe(u8, value) else null,
            .body = try self.allocator.dupe(u8, request_value.body),
        });
        const body = self.responses[self.index];
        self.index += 1;
        return .{
            .allocator = allocator,
            .status = 200,
            .status_text = try allocator.dupe(u8, "OK"),
            .body = try allocator.dupe(u8, body),
        };
    }
};

const FakeOAuthCallbackServerFactory = struct {
    allocator: std.mem.Allocator,
    code: ?[]const u8 = null,
    state: ?[]const u8 = null,
    starts: usize = 0,
    waits: usize = 0,
    closes: usize = 0,

    fn factory(self: *FakeOAuthCallbackServerFactory) OAuthCallbackServerFactory {
        return .{ .ptr = self, .start = start };
    }

    fn start(
        ptr: ?*anyopaque,
        _: std.mem.Allocator,
        expected_state: []const u8,
        _: ?*const std.process.Environ.Map,
    ) anyerror!OAuthCallbackServer {
        const self: *FakeOAuthCallbackServerFactory = @ptrCast(@alignCast(ptr.?));
        self.starts += 1;
        if (self.state == null) self.state = expected_state;
        return .{
            .ptr = self,
            .wait_for_code = waitForCode,
            .close = close,
        };
    }

    fn waitForCode(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?CallbackCode {
        const self: *FakeOAuthCallbackServerFactory = @ptrCast(@alignCast(ptr));
        self.waits += 1;
        if (self.code) |code| return try CallbackCode.init(allocator, code, self.state.?);
        return null;
    }

    fn close(ptr: *anyopaque) void {
        const self: *FakeOAuthCallbackServerFactory = @ptrCast(@alignCast(ptr));
        self.closes += 1;
    }
};

const TestClock = struct {
    now_value: i64,

    fn now(ptr: ?*anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ptr.?));
        return self.now_value;
    }
};

const TestAuthRecorder = struct {
    allocator: std.mem.Allocator,
    url: ?[]u8 = null,

    fn deinit(self: *TestAuthRecorder) void {
        if (self.url) |url| self.allocator.free(url);
    }

    fn call(ptr: ?*anyopaque, info: oauth_types.OAuthAuthInfo) anyerror!void {
        const self: *TestAuthRecorder = @ptrCast(@alignCast(ptr.?));
        self.url = try self.allocator.dupe(u8, info.url);
    }
};

const TestManualInput = struct {
    allocator: std.mem.Allocator,
    auth: *TestAuthRecorder,
    input: ?[]u8 = null,

    fn deinit(self: *TestManualInput) void {
        if (self.input) |input| self.allocator.free(input);
    }

    fn call(ptr: ?*anyopaque) anyerror![]const u8 {
        const self: *TestManualInput = @ptrCast(@alignCast(ptr.?));
        const state = queryValue(self.auth.url.?, "state").?;
        self.input = try std.fmt.allocPrint(self.allocator, "{s}?code=manual-code&state={s}", .{ redirect_uri, state });
        return self.input.?;
    }
};

fn expectJsonString(body: []const u8, field: []const u8, expected: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(expected, parsed.value.object.get(field).?.string);
}

// Ported from packages/ai/test/anthropic-oauth.test.ts.
test "Anthropic OAuth keeps localhost redirect URI for manual callback login" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{
        "{\"access_token\":\"access-token\",\"refresh_token\":\"refresh-token\",\"expires_in\":3600}",
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();
    var server: FakeOAuthCallbackServerFactory = .{ .allocator = allocator };
    var auth: TestAuthRecorder = .{ .allocator = allocator };
    defer auth.deinit();
    var manual: TestManualInput = .{ .allocator = allocator, .auth = &auth };
    defer manual.deinit();
    var clock: TestClock = .{ .now_value = 1_000_000 };

    var result = try loginAnthropic(allocator, .{
        .transport = transport.transport(),
        .callback_server_factory = server.factory(),
        .on_auth = .{ .ptr = &auth, .call = TestAuthRecorder.call },
        .on_manual_code_input = .{ .ptr = &manual, .call = TestManualInput.call },
        .clock = .{ .ptr = &clock, .now_ms = TestClock.now },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("access-token", result.credentials.access);
    try std.testing.expectEqualStrings("refresh-token", result.credentials.refresh);
    try std.testing.expectEqual(@as(i64, 4_300_000), result.credentials.expires);
    try std.testing.expectEqual(@as(usize, 1), server.starts);
    try std.testing.expectEqual(@as(usize, 0), server.waits);
    try std.testing.expectEqual(@as(usize, 1), server.closes);
    try std.testing.expectEqual(@as(usize, 1), transport.records.items.len);
    try std.testing.expectEqualStrings(token_url, transport.records.items[0].url);
    try std.testing.expectEqualStrings("application/json", transport.records.items[0].content_type.?);
    try std.testing.expectEqualStrings("application/json", transport.records.items[0].accept.?);
    try expectJsonString(transport.records.items[0].body, "grant_type", "authorization_code");
    try expectJsonString(transport.records.items[0].body, "code", "manual-code");
    try expectJsonString(transport.records.items[0].body, "redirect_uri", redirect_uri);
}

// Ported from packages/ai/test/anthropic-oauth.test.ts.
test "Anthropic OAuth omits scope from refresh token requests" {
    const allocator = std.testing.allocator;
    const responses = [_][]const u8{
        "{\"access_token\":\"new-access-token\",\"refresh_token\":\"new-refresh-token\",\"expires_in\":3600}",
    };
    var transport = FakeOAuthTransport.init(allocator, &responses);
    defer transport.deinit();
    var clock: TestClock = .{ .now_value = 1_000_000 };

    var result = try refreshAnthropicToken(
        allocator,
        "refresh-token",
        transport.transport(),
        .{ .ptr = &clock, .now_ms = TestClock.now },
    );
    defer result.deinit();

    try std.testing.expectEqualStrings("new-access-token", result.credentials.access);
    try std.testing.expectEqualStrings("new-refresh-token", result.credentials.refresh);
    try expectJsonString(transport.records.items[0].body, "grant_type", "refresh_token");
    try expectJsonString(transport.records.items[0].body, "client_id", client_id);
    try expectJsonString(transport.records.items[0].body, "refresh_token", "refresh-token");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, transport.records.items[0].body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("scope") == null);
}

test "Anthropic OAuth callback route validates browser responses" {
    const allocator = std.testing.allocator;
    var missing_route = try handleAnthropicCallbackTarget(allocator, "/missing", "expected-state");
    defer missing_route.deinit();
    try std.testing.expectEqual(std.http.Status.not_found, missing_route.status);

    var oauth_error = try handleAnthropicCallbackTarget(allocator, "/callback?error=access_denied", "expected-state");
    defer oauth_error.deinit();
    try std.testing.expectEqual(std.http.Status.bad_request, oauth_error.status);
    try std.testing.expect(std.mem.indexOf(u8, oauth_error.html, "Error: access_denied") != null);

    var wrong_state = try handleAnthropicCallbackTarget(
        allocator,
        "/callback?code=oauth-code&state=wrong-state",
        "expected-state",
    );
    defer wrong_state.deinit();
    try std.testing.expectEqual(std.http.Status.bad_request, wrong_state.status);

    var success = try handleAnthropicCallbackTarget(
        allocator,
        "/callback?code=oauth%2Bcode&state=expected%2Dstate",
        "expected-state",
    );
    defer success.deinit();
    try std.testing.expectEqual(std.http.Status.ok, success.status);
    try std.testing.expectEqualStrings("oauth+code", success.code.?.code);
    try std.testing.expectEqualStrings("expected-state", success.code.?.state);
}

test "Anthropic OAuth callback host honors Bulb environment override" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings(default_callback_host, callbackHost(null));

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(callback_host_env, "0.0.0.0");
    try std.testing.expectEqualStrings("0.0.0.0", callbackHost(&env));
}

test "Anthropic OAuth parser accepts redirect URLs fragments queries and codes" {
    const from_url = parseAuthorizationInput("http://localhost:53692/callback?code=abc&state=state-1");
    try std.testing.expectEqualStrings("abc", from_url.code.?);
    try std.testing.expectEqualStrings("state-1", from_url.state.?);
    const from_hash = parseAuthorizationInput("abc#state-2");
    try std.testing.expectEqualStrings("abc", from_hash.code.?);
    try std.testing.expectEqualStrings("state-2", from_hash.state.?);
    const from_query = parseAuthorizationInput("code=abc&state=state-3");
    try std.testing.expectEqualStrings("abc", from_query.code.?);
    try std.testing.expectEqualStrings("state-3", from_query.state.?);
    const from_code = parseAuthorizationInput("oauth-code");
    try std.testing.expectEqualStrings("oauth-code", from_code.code.?);
}

test "Anthropic OAuth rejects pasted state mismatch" {
    try std.testing.expectError(
        error.OAuthStateMismatch,
        authorizationFromInput(std.testing.allocator, "oauth-code#wrong-state", "expected-state"),
    );
}

test "Anthropic OAuth authorization URL carries PKCE and frozen redirect contract" {
    const allocator = std.testing.allocator;
    var flow = try createAuthorizationFlow(allocator);
    defer flow.deinit();

    try std.testing.expect(std.mem.startsWith(u8, flow.url, authorize_url ++ "?"));
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "redirect_uri=http%3A%2F%2Flocalhost%3A53692%2Fcallback") != null);
    try std.testing.expect(std.mem.indexOf(u8, flow.url, "code_challenge_method=S256") != null);
    try std.testing.expectEqual(@as(usize, 43), flow.verifier.len);
}
