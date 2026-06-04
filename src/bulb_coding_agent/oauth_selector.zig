const std = @import("std");
const ai = @import("bulb_ai");
const tui = @import("bulb_tui");
const auth_storage = @import("auth_storage.zig");
const provider_display_names = @import("provider_display_names.zig");

pub const AuthType = enum {
    oauth,
    api_key,

    fn label(self: AuthType) []const u8 {
        return switch (self) {
            .oauth => "oauth",
            .api_key => "api_key",
        };
    }
};

pub const AuthSelectorProvider = struct {
    id: []const u8,
    name: []const u8,
    auth_type: AuthType,
};

pub const StatusResolver = struct {
    ptr: ?*anyopaque = null,
    resolve_fn: *const fn (?*anyopaque, []const u8) anyerror!auth_storage.AuthStatus,

    pub fn resolve(self: StatusResolver, provider_id: []const u8) !auth_storage.AuthStatus {
        return self.resolve_fn(self.ptr, provider_id);
    }
};

pub const SelectCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: SelectCallback, provider_id: []const u8) void {
        self.call_fn(self.ptr, provider_id);
    }
};

pub const CancelCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) void,

    pub fn call(self: CancelCallback) void {
        self.call_fn(self.ptr);
    }
};

pub const Mode = enum {
    login,
    logout,
};

const OwnedProvider = struct {
    id: []u8,
    name: []u8,
    auth_type: AuthType,

    fn clone(allocator: std.mem.Allocator, provider: AuthSelectorProvider) !OwnedProvider {
        return .{
            .id = try allocator.dupe(u8, provider.id),
            .name = try allocator.dupe(u8, provider.name),
            .auth_type = provider.auth_type,
        };
    }

    fn deinit(self: *OwnedProvider, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }

    fn view(self: *const OwnedProvider) AuthSelectorProvider {
        return .{
            .id = self.id,
            .name = self.name,
            .auth_type = self.auth_type,
        };
    }
};

pub const OAuthSelector = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    auth_storage: *const auth_storage.AuthStorage,
    providers: []OwnedProvider,
    filtered_indices: std.ArrayList(usize) = .empty,
    selected_index: usize = 0,
    search: tui.Input,
    status_resolver: ?StatusResolver = null,
    on_select: ?SelectCallback = null,
    on_cancel: ?CancelCallback = null,
    focused: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: Mode,
        storage: *const auth_storage.AuthStorage,
        providers: []const AuthSelectorProvider,
        options: struct {
            status_resolver: ?StatusResolver = null,
            on_select: ?SelectCallback = null,
            on_cancel: ?CancelCallback = null,
        },
    ) !OAuthSelector {
        var owned = try allocator.alloc(OwnedProvider, providers.len);
        errdefer allocator.free(owned);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |*provider| provider.deinit(allocator);
        }
        for (providers, 0..) |provider, index| {
            owned[index] = try OwnedProvider.clone(allocator, provider);
            initialized += 1;
        }

        var selector: OAuthSelector = .{
            .allocator = allocator,
            .mode = mode,
            .auth_storage = storage,
            .providers = owned,
            .search = try tui.Input.init(allocator),
            .status_resolver = options.status_resolver,
            .on_select = options.on_select,
            .on_cancel = options.on_cancel,
        };
        errdefer selector.search.deinit();
        try selector.filterProviders("");
        return selector;
    }

    pub fn deinit(self: *OAuthSelector) void {
        for (self.providers) |*provider| provider.deinit(self.allocator);
        self.allocator.free(self.providers);
        self.filtered_indices.deinit(self.allocator);
        self.search.deinit();
    }

    pub fn setFocused(self: *OAuthSelector, focused: bool) void {
        self.focused = focused;
        self.search.focused = focused;
    }

    pub fn render(self: *OAuthSelector, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        var lines: std.ArrayList([]u8) = .empty;
        errdefer freeLines(allocator, lines.items);

        try lines.append(allocator, try allocator.dupe(u8, "─"));
        try lines.append(allocator, try allocator.dupe(u8, ""));
        try lines.append(allocator, try truncateLine(allocator, self.title(), width));
        try lines.append(allocator, try allocator.dupe(u8, ""));

        const input_lines = try self.search.render(allocator, width);
        lines.appendSlice(allocator, input_lines) catch |err| {
            freeLines(allocator, input_lines);
            return err;
        };
        allocator.free(input_lines);
        try lines.append(allocator, try allocator.dupe(u8, ""));

        try self.appendListLines(allocator, &lines, width);
        try lines.append(allocator, try allocator.dupe(u8, ""));
        try lines.append(allocator, try allocator.dupe(u8, "─"));

        return lines.toOwnedSlice(allocator);
    }

    pub fn handleInput(self: *OAuthSelector, allocator: std.mem.Allocator, data: []const u8) !void {
        const kb = try tui.getKeybindings(allocator);
        if (kb.matches(data, "tui.select.up")) {
            if (self.filtered_indices.items.len == 0) return;
            self.selected_index = if (self.selected_index == 0) 0 else self.selected_index - 1;
            return;
        }
        if (kb.matches(data, "tui.select.down")) {
            if (self.filtered_indices.items.len == 0) return;
            self.selected_index = @min(self.filtered_indices.items.len - 1, self.selected_index + 1);
            return;
        }
        if (kb.matches(data, "tui.select.confirm")) {
            if (self.selectedProvider()) |provider| {
                if (self.on_select) |callback| callback.call(provider.id);
            }
            return;
        }
        if (kb.matches(data, "tui.select.cancel")) {
            if (self.on_cancel) |callback| callback.call();
            return;
        }

        try self.search.handleInput(allocator, data);
        try self.filterProviders(self.search.getValue());
    }

    fn title(self: *const OAuthSelector) []const u8 {
        return switch (self.mode) {
            .login => "Select provider to configure:",
            .logout => "Select provider to logout:",
        };
    }

    fn filterProviders(self: *OAuthSelector, query: []const u8) !void {
        self.filtered_indices.clearRetainingCapacity();
        if (std.mem.trim(u8, query, " \t\r\n").len == 0) {
            for (self.providers, 0..) |_, index| try self.filtered_indices.append(self.allocator, index);
            self.selected_index = clampSelected(self.selected_index, self.filtered_indices.items.len);
            return;
        }

        var scored: std.ArrayList(ScoredProviderIndex) = .empty;
        defer scored.deinit(self.allocator);

        var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
        var token_list: std.ArrayList([]const u8) = .empty;
        defer token_list.deinit(self.allocator);
        while (tokens.next()) |token| try token_list.append(self.allocator, token);

        for (self.providers, 0..) |provider, index| {
            const haystack = try std.mem.concat(self.allocator, u8, &.{
                provider.name,
                " ",
                provider.id,
                " ",
                provider.auth_type.label(),
            });
            defer self.allocator.free(haystack);

            var total_score: f64 = 0;
            var all_match = true;
            for (token_list.items) |token| {
                const matched = try tui.fuzzyMatch(self.allocator, token, haystack);
                if (!matched.matches) {
                    all_match = false;
                    break;
                }
                total_score += matched.score;
            }
            if (all_match) try scored.append(self.allocator, .{ .index = index, .score = total_score });
        }

        std.mem.sort(ScoredProviderIndex, scored.items, {}, ScoredProviderIndex.lessThan);
        for (scored.items) |entry| try self.filtered_indices.append(self.allocator, entry.index);
        self.selected_index = clampSelected(self.selected_index, self.filtered_indices.items.len);
    }

    fn appendListLines(
        self: *OAuthSelector,
        allocator: std.mem.Allocator,
        lines: *std.ArrayList([]u8),
        width: usize,
    ) !void {
        if (self.filtered_indices.items.len == 0) {
            const message = if (self.providers.len == 0)
                switch (self.mode) {
                    .login => "  No providers available",
                    .logout => "  No providers logged in. Use /login first.",
                }
            else
                "  No matching providers";
            try lines.append(allocator, try truncateLine(allocator, message, width));
            return;
        }

        const max_visible: usize = 8;
        const half_visible = max_visible / 2;
        const max_start = self.filtered_indices.items.len -| max_visible;
        const centered_start = if (self.selected_index > half_visible) self.selected_index - half_visible else 0;
        const start = @min(centered_start, max_start);
        const end = @min(start + max_visible, self.filtered_indices.items.len);

        var display_index = start;
        while (display_index < end) : (display_index += 1) {
            const provider = self.providers[self.filtered_indices.items[display_index]].view();
            const selected = display_index == self.selected_index;
            const status = try self.formatStatusIndicator(allocator, provider);
            defer allocator.free(status);
            const prefix = if (selected) "→ " else "  ";
            const line = try std.mem.concat(allocator, u8, &.{ prefix, provider.name, status });
            defer allocator.free(line);
            try lines.append(allocator, try truncateLine(allocator, line, width));
        }

        if (start > 0 or end < self.filtered_indices.items.len) {
            const scroll = try std.fmt.allocPrint(allocator, "  ({d}/{d})", .{ self.selected_index + 1, self.filtered_indices.items.len });
            defer allocator.free(scroll);
            try lines.append(allocator, try truncateLine(allocator, scroll, width));
        }
    }

    fn formatStatusIndicator(self: *OAuthSelector, allocator: std.mem.Allocator, provider: AuthSelectorProvider) ![]u8 {
        if (self.auth_storage.get(provider.id)) |credential| {
            const same_type = switch (credential.*) {
                .api_key => provider.auth_type == .api_key,
                .oauth => provider.auth_type == .oauth,
            };
            if (same_type) return allocator.dupe(u8, " ✓ configured");
            const label = switch (credential.*) {
                .oauth => "subscription configured",
                .api_key => "API key configured",
            };
            return std.fmt.allocPrint(allocator, " • {s}", .{label});
        }

        if (provider.auth_type != .api_key) return allocator.dupe(u8, " • unconfigured");

        const status = if (self.status_resolver) |resolver|
            try resolver.resolve(provider.id)
        else
            try self.auth_storage.getAuthStatus(provider.id);

        return switch (status.source orelse return allocator.dupe(u8, " • unconfigured")) {
            .environment => std.fmt.allocPrint(allocator, " ✓ env: {s}", .{status.label orelse "API key"}),
            .runtime => allocator.dupe(u8, " ✓ runtime API key"),
            .fallback => allocator.dupe(u8, " ✓ custom API key"),
            .models_json_key => allocator.dupe(u8, " ✓ key in models.json"),
            .models_json_command => allocator.dupe(u8, " ✓ command in models.json"),
            .stored => allocator.dupe(u8, " ✓ configured"),
        };
    }

    fn selectedProvider(self: *const OAuthSelector) ?AuthSelectorProvider {
        if (self.selected_index >= self.filtered_indices.items.len) return null;
        return self.providers[self.filtered_indices.items[self.selected_index]].view();
    }
};

const ScoredProviderIndex = struct {
    index: usize,
    score: f64,

    fn lessThan(_: void, lhs: ScoredProviderIndex, rhs: ScoredProviderIndex) bool {
        if (lhs.score < rhs.score) return true;
        if (lhs.score > rhs.score) return false;
        return lhs.index < rhs.index;
    }
};

pub fn isApiKeyLoginProvider(
    provider_id: []const u8,
    oauth_provider_ids: []const []const u8,
    built_in_provider_ids: []const []const u8,
) bool {
    if (provider_display_names.has(provider_id)) return true;
    if (containsString(built_in_provider_ids, provider_id)) return false;
    return !containsString(oauth_provider_ids, provider_id);
}

pub fn isApiKeyLoginProviderFromModels(provider_id: []const u8, oauth_provider_ids: []const []const u8) bool {
    return isApiKeyLoginProvider(provider_id, oauth_provider_ids, ai.models.getProviders());
}

fn clampSelected(selected: usize, count: usize) usize {
    if (count == 0) return 0;
    return @min(selected, count - 1);
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn truncateLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    return tui.truncateToWidth(allocator, text, width, "...", false);
}

fn freeLines(allocator: std.mem.Allocator, lines: []const []u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

const TestHarness = struct {
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    resolver: *@import("resolve_config_value.zig").Resolver,
    oauth_registry: *ai.oauth.Registry,
    storage: auth_storage.AuthStorage,

    fn init(allocator: std.mem.Allocator) !TestHarness {
        const env = try allocator.create(std.process.Environ.Map);
        errdefer allocator.destroy(env);
        env.* = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();

        const resolver = try allocator.create(@import("resolve_config_value.zig").Resolver);
        errdefer allocator.destroy(resolver);
        resolver.* = @import("resolve_config_value.zig").Resolver.init(allocator, env);
        errdefer resolver.deinit();

        const oauth_registry = try allocator.create(ai.oauth.Registry);
        errdefer allocator.destroy(oauth_registry);
        oauth_registry.* = try ai.oauth.Registry.init(allocator);
        errdefer oauth_registry.deinit();

        var storage = try auth_storage.AuthStorage.initMemory(allocator, env, oauth_registry, resolver);
        errdefer storage.deinit();
        return .{
            .allocator = allocator,
            .env = env,
            .resolver = resolver,
            .oauth_registry = oauth_registry,
            .storage = storage,
        };
    }

    fn deinit(self: *TestHarness) void {
        self.storage.deinit();
        self.oauth_registry.deinit();
        self.allocator.destroy(self.oauth_registry);
        self.resolver.deinit();
        self.allocator.destroy(self.resolver);
        self.env.deinit();
        self.allocator.destroy(self.env);
    }
};

fn renderPlain(allocator: std.mem.Allocator, selector: *OAuthSelector) ![]u8 {
    const lines = try selector.render(allocator, 120);
    defer freeLines(allocator, lines);
    const joined = try std.mem.join(allocator, "\n", lines);
    defer allocator.free(joined);
    return @import("ansi.zig").stripAnsiAlloc(allocator, joined);
}

test "OAuth selector keeps built-in API key providers separate from OAuth-only providers" {
    const oauth_provider_ids = [_][]const u8{ "anthropic", "github-copilot", "custom-oauth" };
    const built_in_provider_ids = [_][]const u8{ "anthropic", "github-copilot", "amazon-bedrock", "openai" };

    try std.testing.expect(isApiKeyLoginProvider("anthropic", &oauth_provider_ids, &built_in_provider_ids));
    try std.testing.expectEqualStrings("Anthropic", provider_display_names.get("anthropic").?);
    try std.testing.expect(isApiKeyLoginProvider("openai", &oauth_provider_ids, &built_in_provider_ids));
    try std.testing.expect(!isApiKeyLoginProvider("github-copilot", &oauth_provider_ids, &built_in_provider_ids));
    try std.testing.expect(isApiKeyLoginProvider("amazon-bedrock", &oauth_provider_ids, &built_in_provider_ids));
    try std.testing.expect(!isApiKeyLoginProvider("custom-oauth", &oauth_provider_ids, &built_in_provider_ids));
    try std.testing.expect(isApiKeyLoginProvider("custom-api", &oauth_provider_ids, &built_in_provider_ids));
}

test "OAuth selector shows stored OAuth auth distinctly in API key selector" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var credentials = try ai.oauth.OAuthCredentials.init(allocator, "refresh-token", "access-token", 60_000);
    defer credentials.deinit();
    try harness.storage.setOAuth("anthropic", credentials);

    const providers = [_]AuthSelectorProvider{.{
        .id = "anthropic",
        .name = "Anthropic",
        .auth_type = .api_key,
    }};
    var selector = try OAuthSelector.init(allocator, .login, &harness.storage, &providers, .{});
    defer selector.deinit();

    const output = try renderPlain(allocator, &selector);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "Anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "subscription configured") != null);
}

test "OAuth selector shows environment API key auth as configured" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    try harness.env.put("OPENAI_API_KEY", "test-openai-key");

    const providers = [_]AuthSelectorProvider{.{
        .id = "openai",
        .name = "OpenAI",
        .auth_type = .api_key,
    }};
    var selector = try OAuthSelector.init(allocator, .login, &harness.storage, &providers, .{});
    defer selector.deinit();

    const output = try renderPlain(allocator, &selector);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "OpenAI") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓ env: OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unconfigured") == null);
}

const StaticStatusContext = struct {
    status: auth_storage.AuthStatus,

    fn resolve(ptr: ?*anyopaque, _: []const u8) !auth_storage.AuthStatus {
        const self: *StaticStatusContext = @ptrCast(@alignCast(ptr.?));
        return self.status;
    }

    fn resolver(self: *StaticStatusContext) StatusResolver {
        return .{ .ptr = self, .resolve_fn = resolve };
    }
};

test "OAuth selector shows custom provider environment API key auth from status resolver" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var status_context = StaticStatusContext{ .status = .{ .configured = true, .source = .environment, .label = "OLLAMA_API_KEY" } };

    const providers = [_]AuthSelectorProvider{.{
        .id = "ollama",
        .name = "ollama",
        .auth_type = .api_key,
    }};
    var selector = try OAuthSelector.init(allocator, .login, &harness.storage, &providers, .{
        .status_resolver = status_context.resolver(),
    });
    defer selector.deinit();

    const output = try renderPlain(allocator, &selector);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "ollama") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓ env: OLLAMA_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unconfigured") == null);
}

test "OAuth selector shows models.json API key auth as configured" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var status_context = StaticStatusContext{ .status = .{ .configured = true, .source = .models_json_key } };

    const providers = [_]AuthSelectorProvider{.{
        .id = "local-proxy",
        .name = "local-proxy",
        .auth_type = .api_key,
    }};
    var selector = try OAuthSelector.init(allocator, .login, &harness.storage, &providers, .{
        .status_resolver = status_context.resolver(),
    });
    defer selector.deinit();

    const output = try renderPlain(allocator, &selector);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "local-proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓ key in models.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unconfigured") == null);
}

test "OAuth selector shows models.json command auth as configured" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var status_context = StaticStatusContext{ .status = .{ .configured = true, .source = .models_json_command } };

    const providers = [_]AuthSelectorProvider{.{
        .id = "op-proxy",
        .name = "op-proxy",
        .auth_type = .api_key,
    }};
    var selector = try OAuthSelector.init(allocator, .login, &harness.storage, &providers, .{
        .status_resolver = status_context.resolver(),
    });
    defer selector.deinit();

    const output = try renderPlain(allocator, &selector);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "op-proxy") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓ command in models.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unconfigured") == null);
}
