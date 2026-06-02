const std = @import("std");
const anthropic = @import("anthropic.zig");
const ai_types = @import("../../types.zig");
const device_code = @import("device_code.zig");
const github_copilot = @import("github_copilot.zig");
const openai_codex = @import("openai_codex.zig");
const oauth_types = @import("types.zig");

pub const OAuthCredentials = oauth_types.OAuthCredentials;
pub const OAuthCredentialsResult = oauth_types.OAuthCredentialsResult;
pub const OAuthLoginCallbacks = oauth_types.OAuthLoginCallbacks;
pub const OAuthProviderInfo = oauth_types.OAuthProviderInfo;
pub const OAuthProviderInterface = oauth_types.OAuthProviderInterface;

pub const enterprise_url_key = "enterpriseUrl";
pub const account_id_key = "accountId";

var anthropic_context: u8 = 0;
var github_copilot_context: u8 = 0;
var openai_codex_context: u8 = 0;

pub const anthropic_oauth_provider: OAuthProviderInterface = .{
    .id = anthropic.AnthropicOAuthProvider.id,
    .name = anthropic.AnthropicOAuthProvider.name,
    .context = &anthropic_context,
    .login_fn = loginAnthropic,
    .refresh_token_fn = refreshAnthropic,
    .get_api_key_fn = getAccessToken,
    .uses_callback_server = true,
};

pub const github_copilot_oauth_provider: OAuthProviderInterface = .{
    .id = github_copilot.GitHubCopilotOAuthProvider.id,
    .name = github_copilot.GitHubCopilotOAuthProvider.name,
    .context = &github_copilot_context,
    .login_fn = loginGitHubCopilot,
    .refresh_token_fn = refreshGitHubCopilot,
    .get_api_key_fn = getAccessToken,
    .modify_models_fn = modifyGitHubCopilotModels,
};

pub const openai_codex_oauth_provider: OAuthProviderInterface = .{
    .id = openai_codex.OpenAICodexOAuthProvider.id,
    .name = openai_codex.OpenAICodexOAuthProvider.name,
    .context = &openai_codex_context,
    .login_fn = loginOpenAICodex,
    .refresh_token_fn = refreshOpenAICodex,
    .get_api_key_fn = getAccessToken,
    .uses_callback_server = true,
};

pub const built_in_oauth_providers = [_]OAuthProviderInterface{
    anthropic_oauth_provider,
    github_copilot_oauth_provider,
    openai_codex_oauth_provider,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayList(OAuthProviderInterface) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Registry {
        var registry: Registry = .{ .allocator = allocator };
        errdefer registry.deinit();
        try registry.resetOAuthProviders();
        return registry;
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit(self.allocator);
    }

    pub fn getOAuthProvider(self: Registry, id: []const u8) ?OAuthProviderInterface {
        for (self.providers.items) |provider| {
            if (std.mem.eql(u8, provider.id, id)) return provider;
        }
        return null;
    }

    pub fn registerOAuthProvider(self: *Registry, provider: OAuthProviderInterface) !void {
        for (self.providers.items) |*existing| {
            if (std.mem.eql(u8, existing.id, provider.id)) {
                existing.* = provider;
                return;
            }
        }
        try self.providers.append(self.allocator, provider);
    }

    pub fn unregisterOAuthProvider(self: *Registry, id: []const u8) !void {
        const built_in = getBuiltInOAuthProvider(id);
        for (self.providers.items, 0..) |provider, index| {
            if (!std.mem.eql(u8, provider.id, id)) continue;
            if (built_in) |replacement| {
                self.providers.items[index] = replacement;
            } else {
                _ = self.providers.orderedRemove(index);
            }
            return;
        }
        if (built_in) |provider| try self.providers.append(self.allocator, provider);
    }

    pub fn resetOAuthProviders(self: *Registry) !void {
        self.providers.clearRetainingCapacity();
        try self.providers.appendSlice(self.allocator, &built_in_oauth_providers);
    }

    pub fn getOAuthProviders(self: Registry) []const OAuthProviderInterface {
        return self.providers.items;
    }

    pub fn getOAuthProviderInfoList(self: Registry, allocator: std.mem.Allocator) ![]OAuthProviderInfo {
        const providers = try allocator.alloc(OAuthProviderInfo, self.providers.items.len);
        for (self.providers.items, providers) |provider, *info| {
            info.* = .{
                .id = provider.id,
                .name = provider.name,
                .available = true,
            };
        }
        return providers;
    }

    pub fn refreshOAuthToken(
        self: Registry,
        allocator: std.mem.Allocator,
        provider_id: []const u8,
        credentials: OAuthCredentials,
    ) !OAuthCredentialsResult {
        const provider = self.getOAuthProvider(provider_id) orelse return error.UnknownOAuthProvider;
        return provider.refreshToken(allocator, credentials);
    }

    pub fn getOAuthApiKey(
        self: Registry,
        allocator: std.mem.Allocator,
        provider_id: []const u8,
        credentials: *const std.StringHashMap(OAuthCredentials),
        clock: device_code.Clock,
    ) !OAuthApiKeyResult {
        const provider = self.getOAuthProvider(provider_id) orelse return error.UnknownOAuthProvider;
        const stored = credentials.get(provider_id) orelse return .missing;

        if (clock.now() < stored.expires) {
            return resolvedApiKey(allocator, provider, try stored.clone(allocator));
        }

        var refreshed = try provider.refreshToken(allocator, stored);
        switch (refreshed) {
            .credentials => |new_credentials| return resolvedApiKey(allocator, provider, new_credentials),
            .failed => {
                refreshed.deinit();
                const message = try std.fmt.allocPrint(allocator, "Failed to refresh OAuth token for {s}", .{provider_id});
                defer allocator.free(message);
                return .{ .failed = try device_code.failure(allocator, message) };
            },
        }
    }
};

pub const OAuthApiKey = struct {
    credentials: OAuthCredentials,
    api_key: []u8,

    pub fn deinit(self: *OAuthApiKey) void {
        const allocator = self.credentials.allocator;
        allocator.free(self.api_key);
        self.credentials.deinit();
    }
};

pub const OAuthApiKeyResult = union(enum) {
    missing,
    resolved: OAuthApiKey,
    failed: device_code.FlowFailure,

    pub fn deinit(self: *OAuthApiKeyResult) void {
        switch (self.*) {
            .missing => {},
            .resolved => |*resolved| resolved.deinit(),
            .failed => |*failure_value| failure_value.deinit(),
        }
    }
};

fn getBuiltInOAuthProvider(id: []const u8) ?OAuthProviderInterface {
    for (built_in_oauth_providers) |provider| {
        if (std.mem.eql(u8, provider.id, id)) return provider;
    }
    return null;
}

fn resolvedApiKey(
    allocator: std.mem.Allocator,
    provider: OAuthProviderInterface,
    credentials: OAuthCredentials,
) !OAuthApiKeyResult {
    var owned_credentials = credentials;
    errdefer owned_credentials.deinit();
    return .{ .resolved = .{
        .credentials = owned_credentials,
        .api_key = try allocator.dupe(u8, provider.getApiKey(owned_credentials)),
    } };
}

fn loginAnthropic(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    callbacks: OAuthLoginCallbacks,
) !OAuthCredentialsResult {
    return fromAnthropicResult(allocator, try anthropic.loginAnthropic(allocator, .{
        .on_auth = callbacks.on_auth,
        .on_prompt = callbacks.on_prompt,
        .on_progress = callbacks.on_progress,
        .on_manual_code_input = callbacks.on_manual_code_input,
    }));
}

fn refreshAnthropic(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    credentials: OAuthCredentials,
) !OAuthCredentialsResult {
    return fromAnthropicResult(allocator, try anthropic.refreshAnthropicToken(
        allocator,
        credentials.refresh,
        null,
        .{},
    ));
}

fn fromAnthropicResult(
    allocator: std.mem.Allocator,
    result: anthropic.OAuthCredentialsResult,
) !OAuthCredentialsResult {
    var owned = result;
    defer owned.deinit();
    return switch (owned) {
        .credentials => |credentials| .{ .credentials = try OAuthCredentials.init(
            allocator,
            credentials.refresh,
            credentials.access,
            credentials.expires,
        ) },
        .failed => |failure_value| .{ .failed = try device_code.failure(allocator, failure_value.message) },
    };
}

fn loginGitHubCopilot(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    callbacks: OAuthLoginCallbacks,
) !OAuthCredentialsResult {
    const on_prompt = callbacks.on_prompt orelse
        return .{ .failed = try device_code.failure(allocator, device_code.cancel_message) };
    return fromGitHubCopilotResult(allocator, try github_copilot.loginGitHubCopilot(allocator, .{
        .on_prompt = on_prompt,
        .on_device_code = callbacks.on_device_code,
        .on_progress = callbacks.on_progress,
        .signal = callbacks.signal,
    }));
}

fn refreshGitHubCopilot(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    credentials: OAuthCredentials,
) !OAuthCredentialsResult {
    return fromGitHubCopilotResult(allocator, try github_copilot.refreshGitHubCopilotToken(
        allocator,
        credentials.refresh,
        credentials.getExtra(enterprise_url_key),
        null,
    ));
}

fn fromGitHubCopilotResult(
    allocator: std.mem.Allocator,
    result: github_copilot.OAuthCredentialsResult,
) !OAuthCredentialsResult {
    var owned = result;
    defer owned.deinit();
    return switch (owned) {
        .credentials => |credentials| blk: {
            var shared = try OAuthCredentials.init(allocator, credentials.refresh, credentials.access, credentials.expires);
            errdefer shared.deinit();
            if (credentials.enterprise_url) |enterprise_url| try shared.putExtra(enterprise_url_key, enterprise_url);
            break :blk .{ .credentials = shared };
        },
        .failed => |failure_value| .{ .failed = try device_code.failure(allocator, failure_value.message) },
    };
}

fn modifyGitHubCopilotModels(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    models: []const ai_types.Model,
    credentials: OAuthCredentials,
) !oauth_types.ModifiedModels {
    var modified = try oauth_types.ModifiedModels.init(allocator, models);
    errdefer modified.deinit();
    const enterprise_domain = if (credentials.getExtra(enterprise_url_key)) |enterprise_url|
        try github_copilot.normalizeDomain(allocator, enterprise_url)
    else
        null;
    defer if (enterprise_domain) |domain| allocator.free(domain);
    const base_url = try github_copilot.getGitHubCopilotBaseUrl(
        modified.arena.allocator(),
        credentials.access,
        enterprise_domain,
    );
    for (modified.models) |*model| {
        if (std.mem.eql(u8, model.provider, github_copilot.GitHubCopilotOAuthProvider.id)) {
            model.base_url = base_url;
        }
    }
    return modified;
}

fn loginOpenAICodex(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    callbacks: OAuthLoginCallbacks,
) !OAuthCredentialsResult {
    return fromOpenAICodexResult(allocator, try openai_codex.openai_codex_oauth_provider.login(allocator, .{
        .on_auth = callbacks.on_auth,
        .on_prompt = callbacks.on_prompt,
        .on_select = callbacks.on_select,
        .on_device_code = callbacks.on_device_code,
        .signal = callbacks.signal,
    }));
}

fn refreshOpenAICodex(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    credentials: OAuthCredentials,
) !OAuthCredentialsResult {
    return fromOpenAICodexResult(allocator, try openai_codex.refreshOpenAICodexToken(
        allocator,
        credentials.refresh,
        null,
        .{},
    ));
}

fn fromOpenAICodexResult(
    allocator: std.mem.Allocator,
    result: openai_codex.OAuthCredentialsResult,
) !OAuthCredentialsResult {
    var owned = result;
    defer owned.deinit();
    return switch (owned) {
        .credentials => |credentials| blk: {
            var shared = try OAuthCredentials.init(allocator, credentials.refresh, credentials.access, credentials.expires);
            errdefer shared.deinit();
            try shared.putExtra(account_id_key, credentials.account_id);
            break :blk .{ .credentials = shared };
        },
        .failed => |failure_value| .{ .failed = try device_code.failure(allocator, failure_value.message) },
    };
}

fn getAccessToken(_: *anyopaque, credentials: OAuthCredentials) []const u8 {
    return credentials.access;
}

const TestProvider = struct {
    refreshes: usize = 0,
    fail_refresh: bool = false,

    fn provider(self: *TestProvider, id: []const u8, name: []const u8) OAuthProviderInterface {
        return .{
            .id = id,
            .name = name,
            .context = self,
            .login_fn = login,
            .refresh_token_fn = refresh,
            .get_api_key_fn = apiKey,
        };
    }

    fn login(_: *anyopaque, allocator: std.mem.Allocator, _: OAuthLoginCallbacks) !OAuthCredentialsResult {
        return .{ .credentials = try OAuthCredentials.init(allocator, "login-refresh", "login-access", 123) };
    }

    fn refresh(ptr: *anyopaque, allocator: std.mem.Allocator, _: OAuthCredentials) !OAuthCredentialsResult {
        const self: *TestProvider = @ptrCast(@alignCast(ptr));
        self.refreshes += 1;
        if (self.fail_refresh) return .{ .failed = try device_code.failure(allocator, "provider refresh failed") };
        var credentials = try OAuthCredentials.init(allocator, "new-refresh", "new-access", 999);
        errdefer credentials.deinit();
        try credentials.putExtra("custom", "metadata");
        return .{ .credentials = credentials };
    }

    fn apiKey(_: *anyopaque, credentials: OAuthCredentials) []const u8 {
        return credentials.access;
    }
};

const TestClock = struct {
    now_value: i64,

    fn now(ptr: ?*anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ptr.?));
        return self.now_value;
    }
};

test "OAuth registry starts with built-ins in upstream order" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();

    const providers = registry.getOAuthProviders();
    try std.testing.expectEqual(@as(usize, 3), providers.len);
    try std.testing.expectEqualStrings("anthropic", providers[0].id);
    try std.testing.expectEqualStrings("github-copilot", providers[1].id);
    try std.testing.expectEqualStrings("openai-codex", providers[2].id);
    try std.testing.expect(providers[0].uses_callback_server);
    try std.testing.expect(!providers[1].uses_callback_server);
    try std.testing.expect(providers[2].uses_callback_server);

    const infos = try registry.getOAuthProviderInfoList(std.testing.allocator);
    defer std.testing.allocator.free(infos);
    try std.testing.expectEqualStrings("Anthropic (Claude Pro/Max)", infos[0].name);
    try std.testing.expect(infos[0].available);
}

test "OAuth unregister restores built-ins and removes custom providers" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();
    var custom: TestProvider = .{};

    try registry.registerOAuthProvider(custom.provider("anthropic", "Custom Anthropic OAuth"));
    try registry.registerOAuthProvider(custom.provider("custom", "Custom"));
    try std.testing.expectEqualStrings("Custom Anthropic OAuth", registry.getOAuthProvider("anthropic").?.name);
    try std.testing.expect(registry.getOAuthProvider("custom") != null);

    try registry.unregisterOAuthProvider("anthropic");
    try registry.unregisterOAuthProvider("custom");
    try std.testing.expectEqualStrings("Anthropic (Claude Pro/Max)", registry.getOAuthProvider("anthropic").?.name);
    try std.testing.expect(registry.getOAuthProvider("custom") == null);

    try registry.registerOAuthProvider(custom.provider("anthropic", "Custom Again"));
    try registry.resetOAuthProviders();
    try std.testing.expectEqualStrings("Anthropic (Claude Pro/Max)", registry.getOAuthProvider("anthropic").?.name);
}

test "OAuth API key lookup clones current credentials and refreshes expired credentials" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();
    var custom: TestProvider = .{};
    try registry.registerOAuthProvider(custom.provider("custom", "Custom"));

    var credentials = std.StringHashMap(OAuthCredentials).init(std.testing.allocator);
    defer credentials.deinit();
    var stored = try OAuthCredentials.init(std.testing.allocator, "refresh", "access", 200);
    defer stored.deinit();
    try stored.putExtra("old", "metadata");
    try credentials.put("custom", stored);

    var clock: TestClock = .{ .now_value = 100 };
    var current = try registry.getOAuthApiKey(
        std.testing.allocator,
        "custom",
        &credentials,
        .{ .ptr = &clock, .now_ms = TestClock.now },
    );
    defer current.deinit();
    try std.testing.expectEqualStrings("access", current.resolved.api_key);
    try std.testing.expectEqualStrings("metadata", current.resolved.credentials.getExtra("old").?);
    try std.testing.expectEqual(@as(usize, 0), custom.refreshes);

    clock.now_value = 200;
    var refreshed = try registry.getOAuthApiKey(
        std.testing.allocator,
        "custom",
        &credentials,
        .{ .ptr = &clock, .now_ms = TestClock.now },
    );
    defer refreshed.deinit();
    try std.testing.expectEqualStrings("new-access", refreshed.resolved.api_key);
    try std.testing.expectEqualStrings("metadata", refreshed.resolved.credentials.getExtra("custom").?);
    try std.testing.expectEqual(@as(usize, 1), custom.refreshes);
}

test "OAuth API key lookup returns missing and wraps refresh failures" {
    var registry = try Registry.init(std.testing.allocator);
    defer registry.deinit();
    var custom: TestProvider = .{ .fail_refresh = true };
    try registry.registerOAuthProvider(custom.provider("custom", "Custom"));

    var credentials = std.StringHashMap(OAuthCredentials).init(std.testing.allocator);
    defer credentials.deinit();
    var clock: TestClock = .{ .now_value = 100 };

    var missing = try registry.getOAuthApiKey(
        std.testing.allocator,
        "custom",
        &credentials,
        .{ .ptr = &clock, .now_ms = TestClock.now },
    );
    defer missing.deinit();
    try std.testing.expect(missing == .missing);

    var stored = try OAuthCredentials.init(std.testing.allocator, "refresh", "access", 100);
    defer stored.deinit();
    try credentials.put("custom", stored);
    var failed = try registry.getOAuthApiKey(
        std.testing.allocator,
        "custom",
        &credentials,
        .{ .ptr = &clock, .now_ms = TestClock.now },
    );
    defer failed.deinit();
    try std.testing.expectEqualStrings("Failed to refresh OAuth token for custom", failed.failed.message);
}

test "OAuth built-in adapters preserve provider-specific metadata" {
    const copilot_credentials = github_copilot.OAuthCredentials{
        .allocator = std.testing.allocator,
        .refresh = try std.testing.allocator.dupe(u8, "refresh"),
        .access = try std.testing.allocator.dupe(u8, "access"),
        .expires = 123,
        .enterprise_url = try std.testing.allocator.dupe(u8, "example.ghe.com"),
    };
    var copilot = try fromGitHubCopilotResult(std.testing.allocator, .{ .credentials = copilot_credentials });
    defer copilot.deinit();
    try std.testing.expectEqualStrings("example.ghe.com", copilot.credentials.getExtra(enterprise_url_key).?);

    const codex_credentials = openai_codex.OAuthCredentials{
        .allocator = std.testing.allocator,
        .refresh = try std.testing.allocator.dupe(u8, "refresh"),
        .access = try std.testing.allocator.dupe(u8, "access"),
        .expires = 123,
        .account_id = try std.testing.allocator.dupe(u8, "account-1"),
    };
    var codex = try fromOpenAICodexResult(std.testing.allocator, .{ .credentials = codex_credentials });
    defer codex.deinit();
    try std.testing.expectEqualStrings("account-1", codex.credentials.getExtra(account_id_key).?);
}

test "OAuth Copilot provider modifies Copilot model base URLs only" {
    var credentials = try OAuthCredentials.init(
        std.testing.allocator,
        "refresh",
        "tid=test;exp=9999999999;proxy-ep=proxy.business.githubcopilot.com;",
        123,
    );
    defer credentials.deinit();
    try credentials.putExtra(enterprise_url_key, "https://company.ghe.com/path");
    const source = [_]ai_types.Model{
        .{
            .id = "copilot-model",
            .name = "Copilot",
            .api = "openai-completions",
            .provider = "github-copilot",
            .base_url = "https://old.example",
        },
        .{
            .id = "other-model",
            .name = "Other",
            .api = "openai-completions",
            .provider = "other",
            .base_url = "https://other.example",
        },
    };

    var modified = try github_copilot_oauth_provider.modifyModels(std.testing.allocator, &source, credentials);
    defer modified.deinit();
    try std.testing.expectEqualStrings("https://api.business.githubcopilot.com", modified.models[0].base_url);
    try std.testing.expectEqualStrings("https://other.example", modified.models[1].base_url);
}
