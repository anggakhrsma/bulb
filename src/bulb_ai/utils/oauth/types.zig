const std = @import("std");
const ai_types = @import("../../types.zig");
const device_code = @import("device_code.zig");

pub const OAuthCredentials = struct {
    allocator: std.mem.Allocator,
    refresh: []u8,
    access: []u8,
    expires: i64,
    extra: std.StringHashMap([]u8),

    pub fn init(
        allocator: std.mem.Allocator,
        refresh: []const u8,
        access: []const u8,
        expires: i64,
    ) !OAuthCredentials {
        const refresh_copy = try allocator.dupe(u8, refresh);
        errdefer allocator.free(refresh_copy);
        const access_copy = try allocator.dupe(u8, access);
        return .{
            .allocator = allocator,
            .refresh = refresh_copy,
            .access = access_copy,
            .expires = expires,
            .extra = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *OAuthCredentials) void {
        self.allocator.free(self.refresh);
        self.allocator.free(self.access);
        var iterator = self.extra.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.extra.deinit();
    }

    pub fn clone(self: OAuthCredentials, allocator: std.mem.Allocator) !OAuthCredentials {
        var copy = try OAuthCredentials.init(allocator, self.refresh, self.access, self.expires);
        errdefer copy.deinit();
        var iterator = self.extra.iterator();
        while (iterator.next()) |entry| {
            try copy.putExtra(entry.key_ptr.*, entry.value_ptr.*);
        }
        return copy;
    }

    pub fn putExtra(self: *OAuthCredentials, key: []const u8, value: []const u8) !void {
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        if (self.extra.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = value_copy;
            return;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.extra.put(key_copy, value_copy);
    }

    pub fn getExtra(self: OAuthCredentials, key: []const u8) ?[]const u8 {
        return self.extra.get(key);
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

pub const OAuthDeviceCodeInfo = struct {
    user_code: []const u8,
    verification_uri: []const u8,
    interval_seconds: ?f64 = null,
    expires_in_seconds: ?u64 = null,
};

pub const DeviceCodeCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthDeviceCodeInfo) anyerror!void,

    pub fn invoke(self: DeviceCodeCallback, info: OAuthDeviceCodeInfo) !void {
        try self.call(self.ptr, info);
    }
};

pub const OAuthAuthInfo = struct {
    url: []const u8,
    instructions: ?[]const u8 = null,
};

pub const AuthCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthAuthInfo) anyerror!void,

    pub fn invoke(self: AuthCallback, info: OAuthAuthInfo) !void {
        try self.call(self.ptr, info);
    }
};

pub const OAuthPrompt = struct {
    message: []const u8,
    placeholder: ?[]const u8 = null,
    allow_empty: bool = false,
};

pub const PromptCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, OAuthPrompt) anyerror![]const u8,

    pub fn invoke(self: PromptCallback, prompt: OAuthPrompt) ![]const u8 {
        return self.call(self.ptr, prompt);
    }
};

pub const ProgressCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque, []const u8) anyerror!void,

    pub fn invoke(self: ProgressCallback, message: []const u8) !void {
        try self.call(self.ptr, message);
    }
};

pub const ManualCodeInputCallback = struct {
    ptr: ?*anyopaque = null,
    call: *const fn (?*anyopaque) anyerror![]const u8,

    pub fn invoke(self: ManualCodeInputCallback) ![]const u8 {
        return self.call(self.ptr);
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

pub const OAuthLoginCallbacks = struct {
    on_auth: ?AuthCallback = null,
    on_device_code: ?DeviceCodeCallback = null,
    on_prompt: ?PromptCallback = null,
    on_progress: ?ProgressCallback = null,
    on_manual_code_input: ?ManualCodeInputCallback = null,
    on_select: ?SelectCallback = null,
    signal: ?*ai_types.AbortSignal = null,
};

pub const LoginFn = *const fn (
    *anyopaque,
    std.mem.Allocator,
    OAuthLoginCallbacks,
) anyerror!OAuthCredentialsResult;

pub const RefreshTokenFn = *const fn (
    *anyopaque,
    std.mem.Allocator,
    OAuthCredentials,
) anyerror!OAuthCredentialsResult;

pub const GetApiKeyFn = *const fn (*anyopaque, OAuthCredentials) []const u8;

pub const ModifiedModels = struct {
    arena: std.heap.ArenaAllocator,
    models: []ai_types.Model,

    pub fn init(allocator: std.mem.Allocator, models: []const ai_types.Model) !ModifiedModels {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const copies = try arena.allocator().dupe(ai_types.Model, models);
        return .{
            .arena = arena,
            .models = copies,
        };
    }

    pub fn deinit(self: *ModifiedModels) void {
        self.arena.deinit();
    }
};

pub const ModifyModelsFn = *const fn (
    *anyopaque,
    std.mem.Allocator,
    []const ai_types.Model,
    OAuthCredentials,
) anyerror!ModifiedModels;

pub const OAuthProviderInterface = struct {
    id: []const u8,
    name: []const u8,
    context: *anyopaque,
    login_fn: LoginFn,
    refresh_token_fn: RefreshTokenFn,
    get_api_key_fn: GetApiKeyFn,
    modify_models_fn: ?ModifyModelsFn = null,
    uses_callback_server: bool = false,

    pub fn login(
        self: OAuthProviderInterface,
        allocator: std.mem.Allocator,
        callbacks: OAuthLoginCallbacks,
    ) !OAuthCredentialsResult {
        return self.login_fn(self.context, allocator, callbacks);
    }

    pub fn refreshToken(
        self: OAuthProviderInterface,
        allocator: std.mem.Allocator,
        credentials: OAuthCredentials,
    ) !OAuthCredentialsResult {
        return self.refresh_token_fn(self.context, allocator, credentials);
    }

    pub fn getApiKey(self: OAuthProviderInterface, credentials: OAuthCredentials) []const u8 {
        return self.get_api_key_fn(self.context, credentials);
    }

    pub fn modifyModels(
        self: OAuthProviderInterface,
        allocator: std.mem.Allocator,
        models: []const ai_types.Model,
        credentials: OAuthCredentials,
    ) !ModifiedModels {
        const modify_models = self.modify_models_fn orelse return ModifiedModels.init(allocator, models);
        return modify_models(self.context, allocator, models, credentials);
    }
};

pub const OAuthProviderInfo = struct {
    id: []const u8,
    name: []const u8,
    available: bool,
};

test "OAuth callback wrappers forward native prompt and progress values" {
    const Recorder = struct {
        prompt: ?OAuthPrompt = null,
        progress: ?[]const u8 = null,
        manual_input: []const u8 = "http://localhost/callback?code=manual",

        fn onPrompt(ptr: ?*anyopaque, prompt: OAuthPrompt) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.prompt = prompt;
            return "answer";
        }

        fn onProgress(ptr: ?*anyopaque, message: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.progress = message;
        }

        fn onManualCodeInput(ptr: ?*anyopaque) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.manual_input;
        }
    };

    var recorder: Recorder = .{};
    const prompt = PromptCallback{ .ptr = &recorder, .call = Recorder.onPrompt };
    try std.testing.expectEqualStrings("answer", try prompt.invoke(.{
        .message = "Question",
        .placeholder = "Placeholder",
        .allow_empty = true,
    }));
    try std.testing.expectEqualStrings("Question", recorder.prompt.?.message);
    try std.testing.expectEqualStrings("Placeholder", recorder.prompt.?.placeholder.?);
    try std.testing.expect(recorder.prompt.?.allow_empty);

    const progress = ProgressCallback{ .ptr = &recorder, .call = Recorder.onProgress };
    try progress.invoke("Working");
    try std.testing.expectEqualStrings("Working", recorder.progress.?);

    const manual_input = ManualCodeInputCallback{ .ptr = &recorder, .call = Recorder.onManualCodeInput };
    try std.testing.expectEqualStrings(recorder.manual_input, try manual_input.invoke());
}

test "OAuth credentials clone open metadata and replace values" {
    var credentials = try OAuthCredentials.init(std.testing.allocator, "refresh", "access", 123);
    defer credentials.deinit();
    try credentials.putExtra("accountId", "account-1");
    try credentials.putExtra("accountId", "account-2");
    try credentials.putExtra("enterpriseUrl", "example.ghe.com");

    var copy = try credentials.clone(std.testing.allocator);
    defer copy.deinit();
    try std.testing.expectEqualStrings("refresh", copy.refresh);
    try std.testing.expectEqualStrings("access", copy.access);
    try std.testing.expectEqual(@as(i64, 123), copy.expires);
    try std.testing.expectEqualStrings("account-2", copy.getExtra("accountId").?);
    try std.testing.expectEqualStrings("example.ghe.com", copy.getExtra("enterpriseUrl").?);
}
