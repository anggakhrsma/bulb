const std = @import("std");
const ai = @import("bulb_ai");
const auth_storage = @import("auth_storage.zig");
const config_value = @import("resolve_config_value.zig");
const json_util = @import("json.zig");

const max_models_json_bytes = 4 * 1024 * 1024;

pub const RequestAuth = struct {
    api_key: ?[]u8 = null,
    headers: []ai.Header = &.{},

    pub fn deinit(self: *RequestAuth, allocator: std.mem.Allocator) void {
        if (self.api_key) |api_key| allocator.free(api_key);
        deinitAiHeaders(allocator, self.headers);
        self.* = .{};
    }

    pub fn getHeader(self: RequestAuth, name: []const u8) ?[]const u8 {
        var index = self.headers.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.headers[index].name, name)) return self.headers[index].value;
        }
        return null;
    }
};

pub const ResolvedRequestAuth = union(enum) {
    ok: RequestAuth,
    failure: []u8,

    pub fn deinit(self: *ResolvedRequestAuth, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*request_auth| request_auth.deinit(allocator),
            .failure => |message| allocator.free(message),
        }
        self.* = .{ .ok = .{} };
    }
};

pub const ProviderAuthStatus = struct {
    configured: bool,
    source: ?auth_storage.AuthSource = null,
    label: ?[]u8 = null,

    pub fn deinit(self: *ProviderAuthStatus, allocator: std.mem.Allocator) void {
        if (self.label) |label| allocator.free(label);
        self.* = .{ .configured = false };
    }
};

pub const ProviderConfigInput = struct {
    name: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    api: ?ai.Api = null,
    headers: ?[]const config_value.HeaderInput = null,
    auth_header: ?bool = null,
    oauth: ?ai.oauth.OAuthProviderInterface = null,
    stream_simple: ?ai.api_registry.SimpleStream = null,
    models: ?[]const ai.Model = null,
};

const ProviderRequestConfig = struct {
    api_key: ?[]u8 = null,
    headers: []config_value.HeaderInput = &.{},
    auth_header: bool = false,

    fn deinit(self: *ProviderRequestConfig, allocator: std.mem.Allocator) void {
        if (self.api_key) |api_key| allocator.free(api_key);
        deinitHeaderInputs(allocator, self.headers);
        self.* = .{};
    }
};

const OwnedProviderConfig = struct {
    source_id: ?[]u8 = null,
    name: ?[]u8 = null,
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,
    api: ?[]u8 = null,
    headers: []config_value.HeaderInput = &.{},
    auth_header: ?bool = null,
    oauth: ?ai.oauth.OAuthProviderInterface = null,
    stream_simple: ?ai.api_registry.SimpleStream = null,
    models: []ai.Model = &.{},

    fn cloneMerged(
        allocator: std.mem.Allocator,
        provider_name: []const u8,
        existing: ?OwnedProviderConfig,
        input: ProviderConfigInput,
    ) !OwnedProviderConfig {
        var result = if (existing) |config|
            try config.clone(allocator)
        else
            OwnedProviderConfig{};
        errdefer result.deinit(allocator);
        if (result.source_id == null) {
            result.source_id = try std.fmt.allocPrint(allocator, "provider:{s}", .{provider_name});
        }

        if (input.name) |value| try replaceOptionalOwnedString(allocator, &result.name, value);
        if (input.base_url) |value| try replaceOptionalOwnedString(allocator, &result.base_url, value);
        if (input.api_key) |value| {
            const migrated = try cloneDynamicConfigValueAlloc(allocator, value);
            if (result.api_key) |previous| allocator.free(previous);
            result.api_key = migrated;
        }
        if (input.api) |value| try replaceOptionalOwnedString(allocator, &result.api, value);
        if (input.headers) |headers| {
            const cloned = try cloneDynamicHeaderInputs(allocator, headers);
            deinitHeaderInputs(allocator, result.headers);
            result.headers = cloned;
        }
        if (input.auth_header) |value| result.auth_header = value;
        if (input.oauth) |oauth| {
            const cloned = try cloneOAuthProvider(allocator, provider_name, oauth);
            if (result.oauth) |previous| deinitOAuthProvider(allocator, previous);
            result.oauth = cloned;
        }
        if (input.stream_simple) |stream_simple| result.stream_simple = stream_simple;
        if (input.models) |models| {
            const cloned = try cloneModelsForProvider(allocator, provider_name, models);
            deinitModelItems(allocator, result.models);
            if (result.models.len > 0) allocator.free(result.models);
            result.models = cloned;
        }
        return result;
    }

    fn clone(self: OwnedProviderConfig, allocator: std.mem.Allocator) !OwnedProviderConfig {
        var result = OwnedProviderConfig{};
        errdefer result.deinit(allocator);
        result.source_id = if (self.source_id) |value| try allocator.dupe(u8, value) else null;
        result.name = if (self.name) |value| try allocator.dupe(u8, value) else null;
        result.base_url = if (self.base_url) |value| try allocator.dupe(u8, value) else null;
        result.api_key = if (self.api_key) |value| try allocator.dupe(u8, value) else null;
        result.api = if (self.api) |value| try allocator.dupe(u8, value) else null;
        result.headers = try cloneHeaderInputs(allocator, self.headers);
        result.auth_header = self.auth_header;
        result.oauth = if (self.oauth) |oauth| try cloneOAuthProvider(allocator, oauth.id, oauth) else null;
        result.stream_simple = self.stream_simple;
        result.models = try cloneModels(allocator, self.models);
        return result;
    }

    fn deinit(self: *OwnedProviderConfig, allocator: std.mem.Allocator) void {
        if (self.source_id) |value| allocator.free(value);
        if (self.name) |value| allocator.free(value);
        if (self.base_url) |value| allocator.free(value);
        if (self.api_key) |value| allocator.free(value);
        if (self.api) |value| allocator.free(value);
        deinitHeaderInputs(allocator, self.headers);
        if (self.oauth) |oauth| deinitOAuthProvider(allocator, oauth);
        deinitModelItems(allocator, self.models);
        if (self.models.len > 0) allocator.free(self.models);
        self.* = .{};
    }
};

const ProviderOverride = struct {
    base_url: ?[]u8 = null,
    compat: ai.ModelCompat = .{},

    fn deinit(self: *ProviderOverride, allocator: std.mem.Allocator) void {
        if (self.base_url) |base_url| allocator.free(base_url);
        deinitModelCompat(allocator, &self.compat);
        self.* = .{};
    }
};

const PartialModelCost = struct {
    input: ?f64 = null,
    output: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
};

const ModelOverride = struct {
    name: ?[]u8 = null,
    reasoning: ?bool = null,
    thinking_level_map: ?ai.ThinkingLevelMap = null,
    input: ?[]const []const u8 = null,
    cost: ?PartialModelCost = null,
    context_window: ?u64 = null,
    max_tokens: ?u64 = null,
    compat: ai.ModelCompat = .{},

    fn deinit(self: *ModelOverride, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.thinking_level_map) |*map| deinitThinkingLevelMap(allocator, map);
        if (self.input) |input| deinitStringSlice(allocator, input);
        deinitModelCompat(allocator, &self.compat);
        self.* = .{};
    }
};

pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    auth_storage: *auth_storage.AuthStorage,
    models: std.ArrayList(ai.Model) = .empty,
    provider_request_configs: std.StringHashMap(ProviderRequestConfig),
    model_request_headers: std.StringHashMap([]config_value.HeaderInput),
    registered_providers: std.StringHashMap(OwnedProviderConfig),
    api_registry: ai.api_registry.Registry,
    models_json_path: ?[]u8 = null,
    load_error: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        storage: *auth_storage.AuthStorage,
        models_json_path: ?[]const u8,
    ) !ModelRegistry {
        var registry = ModelRegistry{
            .allocator = allocator,
            .auth_storage = storage,
            .provider_request_configs = std.StringHashMap(ProviderRequestConfig).init(allocator),
            .model_request_headers = std.StringHashMap([]config_value.HeaderInput).init(allocator),
            .registered_providers = std.StringHashMap(OwnedProviderConfig).init(allocator),
            .api_registry = ai.api_registry.Registry.init(allocator),
            .models_json_path = if (models_json_path) |path| try allocator.dupe(u8, path) else null,
        };
        errdefer registry.deinit();
        try registry.loadModels();
        return registry;
    }

    pub fn inMemory(
        allocator: std.mem.Allocator,
        storage: *auth_storage.AuthStorage,
    ) !ModelRegistry {
        return init(allocator, storage, null);
    }

    pub fn deinit(self: *ModelRegistry) void {
        self.auth_storage.oauth_registry.resetOAuthProviders() catch {};
        self.api_registry.deinit();
        self.clearLoaded();
        deinitRegisteredProviders(self.allocator, &self.registered_providers);
        self.models.deinit(self.allocator);
        if (self.models_json_path) |path| self.allocator.free(path);
        if (self.load_error) |message| self.allocator.free(message);
        self.provider_request_configs.deinit();
        self.model_request_headers.deinit();
    }

    pub fn refresh(self: *ModelRegistry) !void {
        try self.auth_storage.oauth_registry.resetOAuthProviders();
        self.clearRegisteredApiProviders();
        self.clearLoaded();
        if (self.load_error) |message| {
            self.allocator.free(message);
            self.load_error = null;
        }
        try self.loadModels();
        try self.applyRegisteredProviders();
    }

    pub fn getError(self: *const ModelRegistry) ?[]const u8 {
        return self.load_error;
    }

    pub fn getAll(self: *const ModelRegistry) []const ai.Model {
        return self.models.items;
    }

    pub fn find(self: *const ModelRegistry, provider: []const u8, model_id: []const u8) ?*const ai.Model {
        for (self.models.items) |*model| {
            if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) return model;
        }
        return null;
    }

    pub fn getProviderDisplayName(self: *const ModelRegistry, provider: []const u8) []const u8 {
        if (self.registered_providers.get(provider)) |config| {
            if (config.name) |name| return name;
            if (config.oauth) |oauth| return oauth.name;
        }
        for (self.auth_storage.getOAuthProviders()) |oauth| {
            if (std.mem.eql(u8, oauth.id, provider)) return oauth.name;
        }
        return builtInProviderDisplayName(provider) orelse provider;
    }

    pub fn registerProvider(self: *ModelRegistry, provider_name: []const u8, input: ProviderConfigInput) !void {
        try validateDynamicProviderConfig(provider_name, input);
        var merged = try OwnedProviderConfig.cloneMerged(
            self.allocator,
            provider_name,
            self.registered_providers.get(provider_name),
            input,
        );
        var merged_owned = true;
        errdefer if (merged_owned) merged.deinit(self.allocator);

        // OAuth entries borrow strings from the owned config, so drop registry
        // references before replacing a previously registered provider.
        try self.auth_storage.oauth_registry.resetOAuthProviders();
        if (self.registered_providers.getPtr(provider_name)) |existing| {
            self.api_registry.unregisterSource(existing.source_id.?);
            existing.deinit(self.allocator);
            existing.* = merged;
            merged_owned = false;
        } else {
            const key = try self.allocator.dupe(u8, provider_name);
            errdefer self.allocator.free(key);
            try self.registered_providers.put(key, merged);
            merged_owned = false;
        }
        try self.refresh();
    }

    pub fn unregisterProvider(self: *ModelRegistry, provider_name: []const u8) !void {
        if (!self.registered_providers.contains(provider_name)) return;
        try self.auth_storage.oauth_registry.resetOAuthProviders();
        self.api_registry.unregisterSource(self.registered_providers.get(provider_name).?.source_id.?);
        if (self.registered_providers.fetchRemove(provider_name)) |removed| {
            self.allocator.free(removed.key);
            var config = removed.value;
            config.deinit(self.allocator);
        }
        try self.refresh();
    }

    pub fn getAvailableAlloc(
        self: *ModelRegistry,
        allocator: std.mem.Allocator,
    ) ![]*const ai.Model {
        var available: std.ArrayList(*const ai.Model) = .empty;
        defer available.deinit(allocator);
        for (self.models.items) |*model| {
            if (try self.hasConfiguredAuth(model)) try available.append(allocator, model);
        }
        return try available.toOwnedSlice(allocator);
    }

    pub fn hasConfiguredAuth(self: *ModelRegistry, model: *const ai.Model) !bool {
        if (self.auth_storage.hasAuth(model.provider)) return true;
        const provider_config = self.provider_request_configs.get(model.provider) orelse return false;
        const api_key = provider_config.api_key orelse return false;
        return config_value.isConfigValueConfigured(self.allocator, self.auth_storage.env, api_key);
    }

    pub fn getApiKeyForProviderAlloc(
        self: *ModelRegistry,
        allocator: std.mem.Allocator,
        provider: []const u8,
    ) !?[]u8 {
        if (try self.auth_storage.getApiKeyAlloc(allocator, provider, .{ .include_fallback = false })) |api_key| {
            return api_key;
        }

        const provider_api_key = if (self.provider_request_configs.get(provider)) |provider_config|
            provider_config.api_key
        else
            null;
        return if (provider_api_key) |api_key|
            self.auth_storage.config_resolver.resolveConfigValueUncachedAlloc(allocator, api_key)
        else
            null;
    }

    pub fn getApiKeyAndHeadersAlloc(
        self: *ModelRegistry,
        allocator: std.mem.Allocator,
        model: *const ai.Model,
    ) !ResolvedRequestAuth {
        var api_key = try self.auth_storage.getApiKeyAlloc(allocator, model.provider, .{ .include_fallback = false });
        errdefer if (api_key) |value| allocator.free(value);

        const provider_config = self.provider_request_configs.get(model.provider);
        if (api_key == null) {
            if (provider_config) |config| {
                if (config.api_key) |configured_api_key| {
                    const description = try formatProviderApiKeyDescription(allocator, model.provider);
                    defer allocator.free(description);
                    const resolved = try self.auth_storage.config_resolver.resolveConfigValueOrThrowAlloc(
                        allocator,
                        configured_api_key,
                        description,
                    );
                    switch (resolved) {
                        .value => |value| {
                            api_key = value;
                        },
                        .failure => |message| {
                            return .{ .failure = message };
                        },
                    }
                }
            }
        }

        var headers: std.ArrayList(ai.Header) = .empty;
        defer headers.deinit(allocator);
        errdefer deinitAiHeaderItems(allocator, headers.items);

        try appendAiHeaders(allocator, &headers, model.headers);

        var provider_headers = if (provider_config) |config| provider_headers: {
            const description = try formatProviderDescription(allocator, model.provider);
            defer allocator.free(description);
            break :provider_headers try self.auth_storage.config_resolver.resolveHeadersOrThrowAlloc(
                allocator,
                config.headers,
                description,
            );
        } else config_value.RequiredHeaders{ .headers = null };
        defer provider_headers.deinit(allocator);
        switch (provider_headers) {
            .headers => |maybe_headers| if (maybe_headers) |resolved| try appendResolvedHeaders(allocator, &headers, resolved.entries),
            .failure => |message| {
                if (api_key) |value| {
                    allocator.free(value);
                    api_key = null;
                }
                deinitAiHeaderItems(allocator, headers.items);
                headers.clearRetainingCapacity();
                return .{ .failure = try allocator.dupe(u8, message) };
            },
        }

        const model_headers_key = try modelRequestKeyAlloc(allocator, model.provider, model.id);
        defer allocator.free(model_headers_key);
        const configured_model_headers = self.model_request_headers.get(model_headers_key);
        const model_description = try formatModelDescription(allocator, model.provider, model.id);
        defer allocator.free(model_description);
        var model_headers = try self.auth_storage.config_resolver.resolveHeadersOrThrowAlloc(
            allocator,
            configured_model_headers,
            model_description,
        );
        defer model_headers.deinit(allocator);
        switch (model_headers) {
            .headers => |maybe_headers| if (maybe_headers) |resolved| try appendResolvedHeaders(allocator, &headers, resolved.entries),
            .failure => |message| {
                if (api_key) |value| {
                    allocator.free(value);
                    api_key = null;
                }
                deinitAiHeaderItems(allocator, headers.items);
                headers.clearRetainingCapacity();
                return .{ .failure = try allocator.dupe(u8, message) };
            },
        }

        if (provider_config) |config| {
            if (config.auth_header) {
                const value = api_key orelse {
                    deinitAiHeaderItems(allocator, headers.items);
                    headers.clearRetainingCapacity();
                    return .{ .failure = try std.fmt.allocPrint(
                        allocator,
                        "No API key found for \"{s}\"",
                        .{model.provider},
                    ) };
                };
                try appendHeader(allocator, &headers, "Authorization", try std.fmt.allocPrint(
                    allocator,
                    "Bearer {s}",
                    .{value},
                ));
            }
        }

        return .{ .ok = .{
            .api_key = api_key,
            .headers = try headers.toOwnedSlice(allocator),
        } };
    }

    pub fn getProviderAuthStatusAlloc(
        self: *ModelRegistry,
        allocator: std.mem.Allocator,
        provider: []const u8,
    ) !ProviderAuthStatus {
        const storage_status = try self.auth_storage.getAuthStatus(provider);
        if (storage_status.source != null) {
            return .{
                .configured = storage_status.configured,
                .source = storage_status.source,
                .label = if (storage_status.label) |label| try allocator.dupe(u8, label) else null,
            };
        }

        const provider_api_key = if (self.provider_request_configs.get(provider)) |provider_config|
            provider_config.api_key
        else
            null;
        const api_key = provider_api_key orelse return .{ .configured = storage_status.configured };

        if (config_value.isCommandConfigValue(api_key)) {
            return .{ .configured = true, .source = .models_json_command };
        }

        const env_var_names = try config_value.getConfigValueEnvVarNames(allocator, api_key);
        defer allocator.free(env_var_names);
        if (env_var_names.len > 0) {
            if (try config_value.isConfigValueConfigured(allocator, self.auth_storage.env, api_key)) {
                return .{
                    .configured = true,
                    .source = .environment,
                    .label = try joinEnvVarNamesAlloc(allocator, env_var_names),
                };
            }
            return .{ .configured = false };
        }

        return .{ .configured = true, .source = .models_json_key };
    }

    fn loadModels(self: *ModelRegistry) !void {
        var provider_overrides = std.StringHashMap(ProviderOverride).init(self.allocator);
        defer deinitProviderOverrides(self.allocator, &provider_overrides);

        var model_overrides = std.StringHashMap(ModelOverride).init(self.allocator);
        defer deinitModelOverrides(self.allocator, &model_overrides);

        var custom_models: std.ArrayList(ai.Model) = .empty;
        defer {
            deinitModelItems(self.allocator, custom_models.items);
            custom_models.deinit(self.allocator);
        }

        if (self.models_json_path) |path| {
            self.loadCustomModels(path, &provider_overrides, &model_overrides, &custom_models) catch |err| {
                deinitModelItems(self.allocator, custom_models.items);
                custom_models.clearRetainingCapacity();
                self.clearRequestConfigMaps();
                if (self.load_error == null) try self.setLoadError(@errorName(err));
            };
        }

        try self.loadBuiltInModels(&provider_overrides, &model_overrides);
        try self.mergeCustomModels(custom_models.items);
        try self.applyOAuthModelModifiers();
    }

    fn applyRegisteredProviders(self: *ModelRegistry) !void {
        var iterator = self.registered_providers.iterator();
        while (iterator.next()) |entry| {
            try self.applyRegisteredProvider(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn applyRegisteredProvider(
        self: *ModelRegistry,
        provider_name: []const u8,
        config: OwnedProviderConfig,
    ) !void {
        if (config.oauth) |oauth| try self.auth_storage.oauth_registry.registerOAuthProvider(oauth);
        if (config.stream_simple) |stream_simple| {
            try self.api_registry.register(.{
                .api = config.api.?,
                .context = stream_simple.context,
                .stream_simple_fn = stream_simple.stream_fn,
                .source_id = config.source_id.?,
            });
        }

        var request_config = ProviderRequestConfig{};
        errdefer request_config.deinit(self.allocator);
        request_config.api_key = if (config.api_key) |value| try self.allocator.dupe(u8, value) else null;
        request_config.headers = try cloneHeaderInputs(self.allocator, config.headers);
        request_config.auth_header = config.auth_header orelse false;
        const owned_request_config = request_config;
        request_config = .{};
        try self.storeProviderRequestConfig(provider_name, owned_request_config);

        if (config.models.len > 0) {
            self.removeModelsForProvider(provider_name);
            for (config.models) |model| {
                var cloned = try cloneDynamicModel(self.allocator, provider_name, config, model);
                errdefer deinitModel(self.allocator, &cloned);
                try self.models.append(self.allocator, cloned);
            }
            if (config.oauth) |oauth| try self.applyOAuthModelModifier(oauth);
        } else if (config.base_url) |base_url| {
            for (self.models.items) |*model| {
                if (std.mem.eql(u8, model.provider, provider_name)) {
                    try replaceOwnedString(self.allocator, &model.base_url, base_url);
                }
            }
        }
    }

    fn applyOAuthModelModifiers(self: *ModelRegistry) !void {
        for (self.auth_storage.getOAuthProviders()) |oauth| {
            try self.applyOAuthModelModifier(oauth);
        }
    }

    fn applyOAuthModelModifier(
        self: *ModelRegistry,
        oauth: ai.oauth.OAuthProviderInterface,
    ) !void {
        if (oauth.modify_models_fn == null) return;
        const credential = self.auth_storage.get(oauth.id) orelse return;
        const credentials = switch (credential.*) {
            .api_key => return,
            .oauth => |value| value,
        };

        var modified = try oauth.modifyModels(self.allocator, self.models.items, credentials);
        defer modified.deinit();
        try self.replaceModels(modified.models);
    }

    fn replaceModels(self: *ModelRegistry, models: []const ai.Model) !void {
        var replacement: std.ArrayList(ai.Model) = .empty;
        errdefer {
            deinitModelItems(self.allocator, replacement.items);
            replacement.deinit(self.allocator);
        }
        try replacement.ensureTotalCapacity(self.allocator, models.len);
        for (models) |model| {
            replacement.appendAssumeCapacity(try cloneModel(self.allocator, model, null));
        }

        const previous = self.models;
        self.models = replacement;
        replacement = previous;
        deinitModelItems(self.allocator, replacement.items);
        replacement.deinit(self.allocator);
    }

    fn removeModelsForProvider(self: *ModelRegistry, provider_name: []const u8) void {
        var index = self.models.items.len;
        while (index > 0) {
            index -= 1;
            if (!std.mem.eql(u8, self.models.items[index].provider, provider_name)) continue;
            var removed = self.models.orderedRemove(index);
            deinitModel(self.allocator, &removed);
        }
    }

    fn loadBuiltInModels(
        self: *ModelRegistry,
        provider_overrides: *const std.StringHashMap(ProviderOverride),
        model_overrides: *const std.StringHashMap(ModelOverride),
    ) !void {
        for (ai.models.allModels()) |model| {
            const provider_override = provider_overrides.get(model.provider);
            var cloned = try cloneModel(
                self.allocator,
                model,
                if (provider_override) |override| override.base_url else null,
            );
            errdefer deinitModel(self.allocator, &cloned);

            if (provider_override) |override| {
                try mergeModelCompat(self.allocator, &cloned.compat, override.compat);
            }

            const override_key = try modelRequestKeyAlloc(self.allocator, model.provider, model.id);
            defer self.allocator.free(override_key);
            if (model_overrides.get(override_key)) |override| {
                try applyModelOverride(self.allocator, &cloned, override);
            }

            try self.models.append(self.allocator, cloned);
        }
    }

    fn loadCustomModels(
        self: *ModelRegistry,
        path: []const u8,
        provider_overrides: *std.StringHashMap(ProviderOverride),
        model_overrides: *std.StringHashMap(ModelOverride),
        custom_models: *std.ArrayList(ai.Model),
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(max_models_json_bytes)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |read_error| return self.failModelsJsonLoad(path, @errorName(read_error)),
        };
        defer self.allocator.free(content);

        const stripped = try json_util.stripJsonCommentsAlloc(self.allocator, content);
        defer self.allocator.free(stripped);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, stripped, .{}) catch |err| {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "Failed to parse models.json: {s}\n\nFile: {s}",
                .{ @errorName(err), path },
            );
            defer self.allocator.free(message);
            try self.setLoadError(message);
            return error.ModelsJsonLoadReported;
        };
        defer parsed.deinit();

        try self.validateModelsJsonSchema(path, parsed.value);
        const root = parsed.value.object;
        const providers_value = root.get("providers").?;

        var providers = providers_value.object.iterator();
        while (providers.next()) |entry| {
            try self.loadProviderConfig(
                path,
                entry.key_ptr.*,
                entry.value_ptr.object,
                provider_overrides,
                model_overrides,
                custom_models,
            );
        }
    }

    fn loadProviderConfig(
        self: *ModelRegistry,
        models_json_path: []const u8,
        provider_name: []const u8,
        object: std.json.ObjectMap,
        provider_overrides: *std.StringHashMap(ProviderOverride),
        model_overrides: *std.StringHashMap(ModelOverride),
        custom_models: *std.ArrayList(ai.Model),
    ) !void {
        const base_url = try optionalString(object, "baseUrl");
        const api_key = try optionalString(object, "apiKey");
        const api_name = try optionalString(object, "api");
        const auth_header = try optionalBool(object, "authHeader") orelse false;
        const provider_compat = try parseCompatObjectAlloc(self.allocator, object.get("compat"));
        var provider_compat_owned = true;
        errdefer if (provider_compat_owned) {
            var compat = provider_compat;
            deinitModelCompat(self.allocator, &compat);
        };
        const provider_headers = try parseHeadersObjectAlloc(self.allocator, object.get("headers"));
        var provider_headers_owned = true;
        errdefer if (provider_headers_owned) deinitHeaderInputs(self.allocator, provider_headers);
        var request_config = ProviderRequestConfig{
            .api_key = if (api_key) |value| try self.allocator.dupe(u8, value) else null,
            .headers = provider_headers,
            .auth_header = auth_header,
        };
        provider_headers_owned = false;
        var request_config_owned = true;
        errdefer if (request_config_owned) request_config.deinit(self.allocator);
        request_config_owned = false;
        try self.storeProviderRequestConfig(provider_name, request_config);

        if (base_url != null or object.get("compat") != null) {
            const override_base_url = if (base_url) |value| try self.allocator.dupe(u8, value) else null;
            const override = ProviderOverride{
                .base_url = override_base_url,
                .compat = provider_compat,
            };
            provider_compat_owned = false;
            try storeProviderOverride(
                self.allocator,
                provider_overrides,
                provider_name,
                override,
            );
        } else {
            var compat = provider_compat;
            deinitModelCompat(self.allocator, &compat);
            provider_compat_owned = false;
        }

        if (object.get("modelOverrides")) |model_overrides_value| {
            try self.loadModelOverrides(provider_name, model_overrides_value, model_overrides);
        }

        const has_model_overrides = if (object.get("modelOverrides")) |overrides|
            overrides.object.count() > 0
        else
            false;
        const models_value = object.get("models") orelse {
            if (base_url == null and
                object.get("headers") == null and
                object.get("compat") == null and
                !has_model_overrides)
            {
                const detail = try std.fmt.allocPrint(
                    self.allocator,
                    "Provider {s}: must specify \"baseUrl\", \"headers\", \"compat\", \"modelOverrides\", or \"models\".",
                    .{provider_name},
                );
                defer self.allocator.free(detail);
                return self.failModelsJsonLoad(models_json_path, detail);
            }
            return;
        };
        if (models_value.array.items.len == 0) {
            if (base_url == null and object.get("headers") == null and object.get("compat") == null and !has_model_overrides) {
                const detail = try std.fmt.allocPrint(
                    self.allocator,
                    "Provider {s}: must specify \"baseUrl\", \"headers\", \"compat\", \"modelOverrides\", or \"models\".",
                    .{provider_name},
                );
                defer self.allocator.free(detail);
                return self.failModelsJsonLoad(models_json_path, detail);
            }
            return;
        }
        if (!isBuiltInProvider(provider_name) and base_url == null) {
            const detail = try std.fmt.allocPrint(
                self.allocator,
                "Provider {s}: \"baseUrl\" is required when defining custom models.",
                .{provider_name},
            );
            defer self.allocator.free(detail);
            try self.failModelsJsonLoad(models_json_path, detail);
            unreachable;
        }
        if (!isBuiltInProvider(provider_name) and api_key == null) {
            const detail = try std.fmt.allocPrint(
                self.allocator,
                "Provider {s}: \"apiKey\" is required when defining custom models.",
                .{provider_name},
            );
            defer self.allocator.free(detail);
            try self.failModelsJsonLoad(models_json_path, detail);
            unreachable;
        }

        for (models_value.array.items) |model_value| {
            var model = try self.parseModelDefinition(models_json_path, provider_name, object, model_value.object, api_name, base_url);
            errdefer deinitModel(self.allocator, &model);
            try custom_models.append(self.allocator, model);
        }
    }

    fn parseModelDefinition(
        self: *ModelRegistry,
        models_json_path: []const u8,
        provider_name: []const u8,
        provider_object: std.json.ObjectMap,
        object: std.json.ObjectMap,
        provider_api: ?[]const u8,
        provider_base_url: ?[]const u8,
    ) !ai.Model {
        const id = try requiredString(object, "id");
        const name = try optionalString(object, "name") orelse id;
        const api_name = (try optionalString(object, "api")) orelse provider_api orelse builtInDefaultApi(provider_name) orelse {
            const detail = try std.fmt.allocPrint(
                self.allocator,
                "Provider {s}, model {s}: no \"api\" specified. Set at provider or model level.",
                .{ provider_name, id },
            );
            defer self.allocator.free(detail);
            try self.failModelsJsonLoad(models_json_path, detail);
            unreachable;
        };
        const base_url = (try optionalString(object, "baseUrl")) orelse provider_base_url orelse builtInDefaultBaseUrl(provider_name) orelse return error.InvalidModelsJson;
        const model_headers = try parseHeadersObjectAlloc(self.allocator, object.get("headers"));
        var model_headers_owned = true;
        errdefer if (model_headers_owned) deinitHeaderInputs(self.allocator, model_headers);

        var compat = try parseCompatObjectAlloc(self.allocator, provider_object.get("compat"));
        var compat_owned = true;
        errdefer if (compat_owned) deinitModelCompat(self.allocator, &compat);
        var model_compat = try parseCompatObjectAlloc(self.allocator, object.get("compat"));
        defer deinitModelCompat(self.allocator, &model_compat);
        try mergeModelCompat(self.allocator, &compat, model_compat);

        const context_window = optionalPositiveU64(object, "contextWindow") catch {
            const detail = try std.fmt.allocPrint(
                self.allocator,
                "Provider {s}, model {s}: invalid contextWindow",
                .{ provider_name, id },
            );
            defer self.allocator.free(detail);
            try self.failModelsJsonLoad(models_json_path, detail);
            unreachable;
        };
        const max_tokens = optionalPositiveU64(object, "maxTokens") catch {
            const detail = try std.fmt.allocPrint(
                self.allocator,
                "Provider {s}, model {s}: invalid maxTokens",
                .{ provider_name, id },
            );
            defer self.allocator.free(detail);
            try self.failModelsJsonLoad(models_json_path, detail);
            unreachable;
        };

        var model = ai.Model{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .api = try self.allocator.dupe(u8, api_name),
            .provider = try self.allocator.dupe(u8, provider_name),
            .base_url = try self.allocator.dupe(u8, base_url),
            .reasoning = try optionalBool(object, "reasoning") orelse false,
            .thinking_level_map = try parseThinkingLevelMapAlloc(self.allocator, object.get("thinkingLevelMap")),
            .input = try parseInputAlloc(self.allocator, object.get("input")),
            .cost = try parseCost(object.get("cost")),
            .context_window = context_window orelse 128_000,
            .max_tokens = max_tokens orelse 16_384,
            .headers = &.{},
            .compat = compat,
        };
        compat_owned = false;
        errdefer deinitModel(self.allocator, &model);

        model_headers_owned = false;
        try self.storeModelHeaders(provider_name, id, model_headers);
        return model;
    }

    fn loadModelOverrides(
        self: *ModelRegistry,
        provider_name: []const u8,
        value: std.json.Value,
        model_overrides: *std.StringHashMap(ModelOverride),
    ) !void {
        if (value != .object) return error.InvalidModelsJson;
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .object) return error.InvalidModelsJson;
            var model_override = try self.parseModelOverrideDefinition(
                provider_name,
                entry.key_ptr.*,
                entry.value_ptr.object,
            );
            errdefer model_override.deinit(self.allocator);
            try storeModelOverride(
                self.allocator,
                model_overrides,
                provider_name,
                entry.key_ptr.*,
                model_override,
            );
        }
    }

    fn parseModelOverrideDefinition(
        self: *ModelRegistry,
        provider_name: []const u8,
        model_id: []const u8,
        object: std.json.ObjectMap,
    ) !ModelOverride {
        var override = ModelOverride{
            .name = if (try optionalString(object, "name")) |value| try self.allocator.dupe(u8, value) else null,
            .reasoning = try optionalBool(object, "reasoning"),
            .thinking_level_map = if (object.get("thinkingLevelMap")) |value| try parseThinkingLevelMapAlloc(self.allocator, value) else null,
            .input = if (object.get("input")) |value| try parseInputAlloc(self.allocator, value) else null,
            .cost = try parsePartialCost(object.get("cost")),
            .context_window = try optionalU64(object, "contextWindow"),
            .max_tokens = try optionalU64(object, "maxTokens"),
            .compat = try parseCompatObjectAlloc(self.allocator, object.get("compat")),
        };
        errdefer override.deinit(self.allocator);

        const headers = try parseHeadersObjectAlloc(self.allocator, object.get("headers"));
        try self.storeModelHeaders(provider_name, model_id, headers);
        return override;
    }

    fn mergeCustomModels(self: *ModelRegistry, custom_models: []ai.Model) !void {
        for (custom_models) |*custom_model| {
            if (self.findMutable(custom_model.provider, custom_model.id)) |existing| {
                deinitModel(self.allocator, existing);
                existing.* = custom_model.*;
                custom_model.* = emptyModel();
            } else {
                try self.models.append(self.allocator, custom_model.*);
                custom_model.* = emptyModel();
            }
        }
    }

    fn findMutable(self: *ModelRegistry, provider: []const u8, model_id: []const u8) ?*ai.Model {
        for (self.models.items) |*model| {
            if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) return model;
        }
        return null;
    }

    fn storeProviderRequestConfig(
        self: *ModelRegistry,
        provider_name: []const u8,
        config: ProviderRequestConfig,
    ) !void {
        if (config.api_key == null and config.headers.len == 0 and !config.auth_header) {
            var mutable = config;
            mutable.deinit(self.allocator);
            return;
        }

        var owned_config = config;
        errdefer owned_config.deinit(self.allocator);
        if (self.provider_request_configs.getPtr(provider_name)) |existing| {
            existing.deinit(self.allocator);
            existing.* = owned_config;
            return;
        }

        const key = try self.allocator.dupe(u8, provider_name);
        errdefer self.allocator.free(key);
        try self.provider_request_configs.put(key, owned_config);
    }

    fn storeModelHeaders(
        self: *ModelRegistry,
        provider_name: []const u8,
        model_id: []const u8,
        headers: []config_value.HeaderInput,
    ) !void {
        if (headers.len == 0) {
            deinitHeaderInputs(self.allocator, headers);
            return;
        }

        const owned_headers = headers;
        errdefer deinitHeaderInputs(self.allocator, owned_headers);
        const key = try modelRequestKeyAlloc(self.allocator, provider_name, model_id);
        errdefer self.allocator.free(key);
        if (self.model_request_headers.getPtr(key)) |existing| {
            deinitHeaderInputs(self.allocator, existing.*);
            existing.* = owned_headers;
            self.allocator.free(key);
            return;
        }
        try self.model_request_headers.put(key, owned_headers);
    }

    fn clearLoaded(self: *ModelRegistry) void {
        deinitModelItems(self.allocator, self.models.items);
        self.models.clearRetainingCapacity();
        self.clearRequestConfigMaps();
    }

    fn clearRegisteredApiProviders(self: *ModelRegistry) void {
        var iterator = self.registered_providers.valueIterator();
        while (iterator.next()) |config| self.api_registry.unregisterSource(config.source_id.?);
    }

    fn clearRequestConfigMaps(self: *ModelRegistry) void {
        var provider_iterator = self.provider_request_configs.iterator();
        while (provider_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.provider_request_configs.clearRetainingCapacity();

        var model_iterator = self.model_request_headers.iterator();
        while (model_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            deinitHeaderInputs(self.allocator, entry.value_ptr.*);
        }
        self.model_request_headers.clearRetainingCapacity();
    }

    fn validateModelsJsonSchema(self: *ModelRegistry, path: []const u8, value: std.json.Value) !void {
        var issues: std.ArrayList(u8) = .empty;
        defer issues.deinit(self.allocator);

        if (value != .object) {
            try self.appendModelsJsonSchemaIssue(&issues, "root", "Expected object");
            return self.failModelsJsonSchemaIssues(path, issues.items);
        }

        const providers = value.object.get("providers") orelse {
            try self.appendModelsJsonSchemaIssue(&issues, "providers", "Expected required property");
            return self.failModelsJsonSchemaIssues(path, issues.items);
        };
        if (providers != .object) {
            try self.appendModelsJsonSchemaIssue(&issues, "providers", "Expected object");
            return self.failModelsJsonSchemaIssues(path, issues.items);
        }

        var iterator = providers.object.iterator();
        while (iterator.next()) |entry| {
            const provider_path = try std.fmt.allocPrint(self.allocator, "providers.{s}", .{entry.key_ptr.*});
            defer self.allocator.free(provider_path);
            if (entry.value_ptr.* != .object) {
                try self.appendModelsJsonSchemaIssue(&issues, provider_path, "Expected object");
                continue;
            }
            try self.validateProviderConfigSchema(&issues, provider_path, entry.value_ptr.object);
        }

        if (issues.items.len > 0) return self.failModelsJsonSchemaIssues(path, issues.items);
    }

    fn validateProviderConfigSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        provider_path: []const u8,
        object: std.json.ObjectMap,
    ) !void {
        const string_fields = [_][]const u8{ "name", "baseUrl", "apiKey", "api" };
        for (string_fields) |field| try self.validateOptionalNonEmptyStringSchema(issues, provider_path, object, field);
        try self.validateOptionalBoolSchema(issues, provider_path, object, "authHeader");
        try self.validateHeadersSchema(issues, provider_path, object.get("headers"), "headers");
        try self.validateCompatSchema(issues, provider_path, object.get("compat"));

        if (object.get("models")) |models| {
            const models_path = try schemaPathAlloc(self.allocator, provider_path, "models");
            defer self.allocator.free(models_path);
            if (models != .array) {
                try self.appendModelsJsonSchemaIssue(issues, models_path, "Expected array");
            } else {
                for (models.array.items, 0..) |model, index| {
                    const model_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ models_path, index });
                    defer self.allocator.free(model_path);
                    if (model != .object) {
                        try self.appendModelsJsonSchemaIssue(issues, model_path, "Expected object");
                        continue;
                    }
                    try self.validateModelDefinitionSchema(issues, model_path, model.object);
                }
            }
        }

        if (object.get("modelOverrides")) |overrides| {
            const overrides_path = try schemaPathAlloc(self.allocator, provider_path, "modelOverrides");
            defer self.allocator.free(overrides_path);
            if (overrides != .object) {
                try self.appendModelsJsonSchemaIssue(issues, overrides_path, "Expected object");
            } else {
                var iterator = overrides.object.iterator();
                while (iterator.next()) |entry| {
                    const override_path = try schemaPathAlloc(self.allocator, overrides_path, entry.key_ptr.*);
                    defer self.allocator.free(override_path);
                    if (entry.value_ptr.* != .object) {
                        try self.appendModelsJsonSchemaIssue(issues, override_path, "Expected object");
                        continue;
                    }
                    try self.validateModelOverrideSchema(issues, override_path, entry.value_ptr.object);
                }
            }
        }
    }

    fn validateModelDefinitionSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        model_path: []const u8,
        object: std.json.ObjectMap,
    ) !void {
        if (object.get("id")) |id| {
            const field_path = try schemaPathAlloc(self.allocator, model_path, "id");
            defer self.allocator.free(field_path);
            if (id != .string) {
                try self.appendModelsJsonSchemaIssue(issues, field_path, "Expected string");
            } else if (id.string.len == 0) {
                try self.appendModelsJsonSchemaIssue(issues, field_path, "Expected string length greater than or equal to 1");
            }
        } else {
            const field_path = try schemaPathAlloc(self.allocator, model_path, "id");
            defer self.allocator.free(field_path);
            try self.appendModelsJsonSchemaIssue(issues, field_path, "Expected required property");
        }

        const string_fields = [_][]const u8{ "name", "api", "baseUrl" };
        for (string_fields) |field| try self.validateOptionalNonEmptyStringSchema(issues, model_path, object, field);
        try self.validateOptionalBoolSchema(issues, model_path, object, "reasoning");
        try self.validateInputSchema(issues, model_path, object.get("input"));
        try self.validateCostSchema(issues, model_path, object.get("cost"), true);
        try self.validateOptionalNumberSchema(issues, model_path, object, "contextWindow");
        try self.validateOptionalNumberSchema(issues, model_path, object, "maxTokens");
        try self.validateHeadersSchema(issues, model_path, object.get("headers"), "headers");
        try self.validateThinkingLevelMapSchema(issues, model_path, object.get("thinkingLevelMap"));
        try self.validateCompatSchema(issues, model_path, object.get("compat"));
    }

    fn validateModelOverrideSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        model_path: []const u8,
        object: std.json.ObjectMap,
    ) !void {
        try self.validateOptionalNonEmptyStringSchema(issues, model_path, object, "name");
        try self.validateOptionalBoolSchema(issues, model_path, object, "reasoning");
        try self.validateInputSchema(issues, model_path, object.get("input"));
        try self.validateCostSchema(issues, model_path, object.get("cost"), false);
        try self.validateOptionalNumberSchema(issues, model_path, object, "contextWindow");
        try self.validateOptionalNumberSchema(issues, model_path, object, "maxTokens");
        try self.validateHeadersSchema(issues, model_path, object.get("headers"), "headers");
        try self.validateThinkingLevelMapSchema(issues, model_path, object.get("thinkingLevelMap"));
        try self.validateCompatSchema(issues, model_path, object.get("compat"));
    }

    fn validateOptionalNonEmptyStringSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        object: std.json.ObjectMap,
        field: []const u8,
    ) !void {
        const value = object.get(field) orelse return;
        const field_path = try schemaPathAlloc(self.allocator, base_path, field);
        defer self.allocator.free(field_path);
        if (value != .string) return self.appendModelsJsonSchemaIssue(issues, field_path, "Expected string");
        if (value.string.len == 0) {
            return self.appendModelsJsonSchemaIssue(issues, field_path, "Expected string length greater than or equal to 1");
        }
    }

    fn validateOptionalBoolSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        object: std.json.ObjectMap,
        field: []const u8,
    ) !void {
        const value = object.get(field) orelse return;
        if (value == .bool) return;
        const field_path = try schemaPathAlloc(self.allocator, base_path, field);
        defer self.allocator.free(field_path);
        return self.appendModelsJsonSchemaIssue(issues, field_path, "Expected boolean");
    }

    fn validateOptionalNumberSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        object: std.json.ObjectMap,
        field: []const u8,
    ) !void {
        const value = object.get(field) orelse return;
        if (isJsonNumber(value)) return;
        const field_path = try schemaPathAlloc(self.allocator, base_path, field);
        defer self.allocator.free(field_path);
        return self.appendModelsJsonSchemaIssue(issues, field_path, "Expected number");
    }

    fn validateHeadersSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        maybe_value: ?std.json.Value,
        field: []const u8,
    ) !void {
        const value = maybe_value orelse return;
        const field_path = try schemaPathAlloc(self.allocator, base_path, field);
        defer self.allocator.free(field_path);
        if (value != .object) return self.appendModelsJsonSchemaIssue(issues, field_path, "Expected object");
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* == .string) continue;
            const header_path = try schemaPathAlloc(self.allocator, field_path, entry.key_ptr.*);
            defer self.allocator.free(header_path);
            try self.appendModelsJsonSchemaIssue(issues, header_path, "Expected string");
        }
    }

    fn validateInputSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        maybe_value: ?std.json.Value,
    ) !void {
        const value = maybe_value orelse return;
        const input_path = try schemaPathAlloc(self.allocator, base_path, "input");
        defer self.allocator.free(input_path);
        if (value != .array) return self.appendModelsJsonSchemaIssue(issues, input_path, "Expected array");
        for (value.array.items, 0..) |entry, index| {
            const item_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ input_path, index });
            defer self.allocator.free(item_path);
            if (entry != .string or
                (!std.mem.eql(u8, entry.string, "text") and !std.mem.eql(u8, entry.string, "image")))
            {
                try self.appendModelsJsonSchemaIssue(issues, item_path, "Expected 'text' or 'image'");
            }
        }
    }

    fn validateCostSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        maybe_value: ?std.json.Value,
        require_all_fields: bool,
    ) !void {
        const value = maybe_value orelse return;
        const cost_path = try schemaPathAlloc(self.allocator, base_path, "cost");
        defer self.allocator.free(cost_path);
        if (value != .object) return self.appendModelsJsonSchemaIssue(issues, cost_path, "Expected object");

        const fields = [_][]const u8{ "input", "output", "cacheRead", "cacheWrite" };
        for (fields) |field| {
            const maybe_cost = value.object.get(field);
            if (maybe_cost == null and !require_all_fields) continue;
            const field_path = try schemaPathAlloc(self.allocator, cost_path, field);
            defer self.allocator.free(field_path);
            const cost = maybe_cost orelse {
                try self.appendModelsJsonSchemaIssue(issues, field_path, "Expected required property");
                continue;
            };
            if (!isJsonNumber(cost)) try self.appendModelsJsonSchemaIssue(issues, field_path, "Expected number");
        }
    }

    fn validateThinkingLevelMapSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        maybe_value: ?std.json.Value,
    ) !void {
        const value = maybe_value orelse return;
        const map_path = try schemaPathAlloc(self.allocator, base_path, "thinkingLevelMap");
        defer self.allocator.free(map_path);
        if (value != .object) return self.appendModelsJsonSchemaIssue(issues, map_path, "Expected object");
        const fields = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh" };
        for (fields) |field| {
            const override = value.object.get(field) orelse continue;
            if (override == .string or override == .null) continue;
            const field_path = try schemaPathAlloc(self.allocator, map_path, field);
            defer self.allocator.free(field_path);
            try self.appendModelsJsonSchemaIssue(issues, field_path, "Expected string or null");
        }
    }

    fn validateCompatSchema(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        base_path: []const u8,
        maybe_value: ?std.json.Value,
    ) !void {
        const value = maybe_value orelse return;
        const compat_path = try schemaPathAlloc(self.allocator, base_path, "compat");
        defer self.allocator.free(compat_path);
        var compat = parseCompatObjectAlloc(self.allocator, value) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try self.appendModelsJsonSchemaIssue(issues, compat_path, "Expected valid compatibility object");
                return;
            },
        };
        deinitModelCompat(self.allocator, &compat);
    }

    fn setLoadError(self: *ModelRegistry, message: []const u8) !void {
        if (self.load_error) |previous| self.allocator.free(previous);
        self.load_error = try self.allocator.dupe(u8, message);
    }

    fn failModelsJsonLoad(self: *ModelRegistry, path: []const u8, detail: []const u8) !void {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "Failed to load models.json: {s}\n\nFile: {s}",
            .{ detail, path },
        );
        defer self.allocator.free(message);
        try self.setLoadError(message);
        return error.ModelsJsonLoadReported;
    }

    fn appendModelsJsonSchemaIssue(
        self: *ModelRegistry,
        issues: *std.ArrayList(u8),
        schema_path: []const u8,
        detail: []const u8,
    ) !void {
        if (issues.items.len > 0) try issues.append(self.allocator, '\n');
        const issue = try std.fmt.allocPrint(self.allocator, "  - {s}: {s}", .{ schema_path, detail });
        defer self.allocator.free(issue);
        try issues.appendSlice(self.allocator, issue);
    }

    fn failModelsJsonSchemaIssues(
        self: *ModelRegistry,
        path: []const u8,
        issues: []const u8,
    ) !void {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "Invalid models.json schema:\n{s}\n\nFile: {s}",
            .{ issues, path },
        );
        defer self.allocator.free(message);
        try self.setLoadError(message);
        return error.ModelsJsonLoadReported;
    }
};

fn formatProviderApiKeyDescription(allocator: std.mem.Allocator, provider: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "API key for provider \"{s}\"", .{provider});
}

fn formatProviderDescription(allocator: std.mem.Allocator, provider: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "provider \"{s}\"", .{provider});
}

fn formatModelDescription(allocator: std.mem.Allocator, provider: []const u8, model_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "model \"{s}/{s}\"", .{ provider, model_id });
}

fn cloneModel(
    allocator: std.mem.Allocator,
    model: ai.Model,
    override_base_url: ?[]const u8,
) !ai.Model {
    var cloned = emptyModel();
    errdefer deinitModel(allocator, &cloned);
    cloned.id = try allocator.dupe(u8, model.id);
    cloned.name = try allocator.dupe(u8, model.name);
    cloned.api = try allocator.dupe(u8, model.api);
    cloned.provider = try allocator.dupe(u8, model.provider);
    cloned.base_url = try allocator.dupe(u8, override_base_url orelse model.base_url);
    cloned.reasoning = model.reasoning;
    cloned.thinking_level_map = try cloneThinkingLevelMap(allocator, model.thinking_level_map);
    cloned.input = try cloneStringSlice(allocator, model.input);
    cloned.cost = model.cost;
    cloned.context_window = model.context_window;
    cloned.max_tokens = model.max_tokens;
    cloned.headers = try cloneAiHeaders(allocator, model.headers);
    cloned.compat = try cloneModelCompat(allocator, model.compat);
    return cloned;
}

fn deinitModelItems(allocator: std.mem.Allocator, models: []ai.Model) void {
    for (models) |*model| deinitModel(allocator, model);
}

fn deinitModel(allocator: std.mem.Allocator, model: *ai.Model) void {
    if (model.id.len == 0 and model.name.len == 0 and model.api.len == 0 and
        model.provider.len == 0 and model.base_url.len == 0)
    {
        model.* = emptyModel();
        return;
    }
    if (model.id.len > 0) allocator.free(model.id);
    if (model.name.len > 0) allocator.free(model.name);
    if (model.api.len > 0) allocator.free(model.api);
    if (model.provider.len > 0) allocator.free(model.provider);
    if (model.base_url.len > 0) allocator.free(model.base_url);
    deinitThinkingLevelMap(allocator, &model.thinking_level_map);
    deinitStringSlice(allocator, model.input);
    deinitAiHeaders(allocator, model.headers);
    deinitModelCompat(allocator, &model.compat);
    model.* = emptyModel();
}

fn emptyModel() ai.Model {
    return .{
        .id = "",
        .name = "",
        .api = "",
        .provider = "",
        .base_url = "",
        .input = &.{},
        .headers = &.{},
    };
}

fn applyModelOverride(
    allocator: std.mem.Allocator,
    model: *ai.Model,
    override: ModelOverride,
) !void {
    if (override.name) |name| try replaceOwnedString(allocator, &model.name, name);
    if (override.reasoning) |reasoning| model.reasoning = reasoning;
    if (override.thinking_level_map) |thinking_level_map| {
        try mergeThinkingLevelMap(allocator, &model.thinking_level_map, thinking_level_map);
    }
    if (override.input) |input| {
        const cloned = try cloneStringSlice(allocator, input);
        deinitStringSlice(allocator, model.input);
        model.input = cloned;
    }
    if (override.cost) |cost| {
        if (cost.input) |value| model.cost.input = value;
        if (cost.output) |value| model.cost.output = value;
        if (cost.cache_read) |value| model.cost.cache_read = value;
        if (cost.cache_write) |value| model.cost.cache_write = value;
    }
    if (override.context_window) |context_window| model.context_window = context_window;
    if (override.max_tokens) |max_tokens| model.max_tokens = max_tokens;
    try mergeModelCompat(allocator, &model.compat, override.compat);
}

fn replaceOwnedString(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = copy;
}

fn replaceOptionalOwnedString(allocator: std.mem.Allocator, target: *?[]u8, value: []const u8) !void {
    const copy = try allocator.dupe(u8, value);
    if (target.*) |previous| allocator.free(previous);
    target.* = copy;
}

fn cloneDynamicConfigValueAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (!config_value.isLegacyEnvVarNameConfigValue(value)) return try allocator.dupe(u8, value);
    return try std.fmt.allocPrint(allocator, "${s}", .{value});
}

fn cloneOAuthProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    oauth: ai.oauth.OAuthProviderInterface,
) !ai.oauth.OAuthProviderInterface {
    const id = try allocator.dupe(u8, provider_name);
    errdefer allocator.free(id);
    return .{
        .id = id,
        .name = try allocator.dupe(u8, oauth.name),
        .context = oauth.context,
        .login_fn = oauth.login_fn,
        .refresh_token_fn = oauth.refresh_token_fn,
        .get_api_key_fn = oauth.get_api_key_fn,
        .modify_models_fn = oauth.modify_models_fn,
        .uses_callback_server = oauth.uses_callback_server,
    };
}

fn deinitOAuthProvider(allocator: std.mem.Allocator, oauth: ai.oauth.OAuthProviderInterface) void {
    allocator.free(oauth.id);
    allocator.free(oauth.name);
}

fn cloneModels(allocator: std.mem.Allocator, models: []const ai.Model) ![]ai.Model {
    if (models.len == 0) return &.{};
    const cloned = try allocator.alloc(ai.Model, models.len);
    var initialized: usize = 0;
    errdefer {
        deinitModelItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (models, 0..) |model, index| {
        cloned[index] = try cloneModel(allocator, model, null);
        initialized += 1;
    }
    return cloned;
}

fn cloneModelsForProvider(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    models: []const ai.Model,
) ![]ai.Model {
    if (models.len == 0) return &.{};
    const cloned = try allocator.alloc(ai.Model, models.len);
    var initialized: usize = 0;
    errdefer {
        deinitModelItems(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (models, 0..) |model, index| {
        var adjusted = model;
        adjusted.provider = provider_name;
        cloned[index] = try cloneModel(allocator, adjusted, null);
        initialized += 1;
    }
    return cloned;
}

fn cloneDynamicModel(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    config: OwnedProviderConfig,
    model: ai.Model,
) !ai.Model {
    var adjusted = model;
    adjusted.provider = provider_name;
    if (adjusted.api.len == 0) adjusted.api = config.api.?;
    if (adjusted.base_url.len == 0) adjusted.base_url = config.base_url.?;
    return try cloneModel(allocator, adjusted, null);
}

fn validateDynamicProviderConfig(_: []const u8, input: ProviderConfigInput) !void {
    if (input.stream_simple != null and input.api == null) return error.DynamicProviderStreamSimpleApiRequired;
    const models = input.models orelse return;
    if (models.len == 0) return;
    if (input.base_url == null) return error.DynamicProviderBaseUrlRequired;
    if (input.api_key == null and input.oauth == null) return error.DynamicProviderAuthRequired;
    for (models) |model| {
        if (model.api.len == 0 and input.api == null) return error.DynamicProviderApiRequired;
    }
}

fn cloneThinkingLevelMap(
    allocator: std.mem.Allocator,
    map: ai.ThinkingLevelMap,
) !ai.ThinkingLevelMap {
    return .{
        .off = try cloneThinkingLevelOverride(allocator, map.off),
        .minimal = try cloneThinkingLevelOverride(allocator, map.minimal),
        .low = try cloneThinkingLevelOverride(allocator, map.low),
        .medium = try cloneThinkingLevelOverride(allocator, map.medium),
        .high = try cloneThinkingLevelOverride(allocator, map.high),
        .xhigh = try cloneThinkingLevelOverride(allocator, map.xhigh),
    };
}

fn cloneThinkingLevelOverride(
    allocator: std.mem.Allocator,
    value: ai.ThinkingLevelOverride,
) !ai.ThinkingLevelOverride {
    return switch (value) {
        .unset => .unset,
        .unsupported => .unsupported,
        .mapped => |mapped| .{ .mapped = try allocator.dupe(u8, mapped) },
    };
}

fn deinitThinkingLevelMap(allocator: std.mem.Allocator, map: *ai.ThinkingLevelMap) void {
    deinitThinkingLevelOverride(allocator, &map.off);
    deinitThinkingLevelOverride(allocator, &map.minimal);
    deinitThinkingLevelOverride(allocator, &map.low);
    deinitThinkingLevelOverride(allocator, &map.medium);
    deinitThinkingLevelOverride(allocator, &map.high);
    deinitThinkingLevelOverride(allocator, &map.xhigh);
    map.* = .{};
}

fn deinitThinkingLevelOverride(
    allocator: std.mem.Allocator,
    value: *ai.ThinkingLevelOverride,
) void {
    switch (value.*) {
        .mapped => |mapped| allocator.free(mapped),
        .unset, .unsupported => {},
    }
    value.* = .unset;
}

fn mergeThinkingLevelMap(
    allocator: std.mem.Allocator,
    target: *ai.ThinkingLevelMap,
    override: ai.ThinkingLevelMap,
) !void {
    try mergeThinkingLevelOverride(allocator, &target.off, override.off);
    try mergeThinkingLevelOverride(allocator, &target.minimal, override.minimal);
    try mergeThinkingLevelOverride(allocator, &target.low, override.low);
    try mergeThinkingLevelOverride(allocator, &target.medium, override.medium);
    try mergeThinkingLevelOverride(allocator, &target.high, override.high);
    try mergeThinkingLevelOverride(allocator, &target.xhigh, override.xhigh);
}

fn mergeThinkingLevelOverride(
    allocator: std.mem.Allocator,
    target: *ai.ThinkingLevelOverride,
    override: ai.ThinkingLevelOverride,
) !void {
    switch (override) {
        .unset => return,
        .unsupported => {
            deinitThinkingLevelOverride(allocator, target);
            target.* = .unsupported;
        },
        .mapped => |mapped| {
            const copy = try allocator.dupe(u8, mapped);
            deinitThinkingLevelOverride(allocator, target);
            target.* = .{ .mapped = copy };
        },
    }
}

fn cloneModelCompat(
    allocator: std.mem.Allocator,
    compat: ai.ModelCompat,
) !ai.ModelCompat {
    var result = compat;
    result.cache_control_format = null;
    result.open_router_routing_json = null;
    result.vercel_gateway_routing_json = null;
    errdefer deinitModelCompat(allocator, &result);

    if (compat.cache_control_format) |format| {
        result.cache_control_format = try allocator.dupe(u8, format);
    }
    if (compat.open_router_routing_json) |routing| {
        result.open_router_routing_json = try allocator.dupe(u8, routing);
    }
    if (compat.vercel_gateway_routing_json) |routing| {
        result.vercel_gateway_routing_json = try allocator.dupe(u8, routing);
    }
    return result;
}

fn deinitModelCompat(allocator: std.mem.Allocator, compat: *ai.ModelCompat) void {
    if (compat.cache_control_format) |format| allocator.free(format);
    if (compat.open_router_routing_json) |routing| allocator.free(routing);
    if (compat.vercel_gateway_routing_json) |routing| allocator.free(routing);
    compat.* = .{};
}

fn mergeModelCompat(
    allocator: std.mem.Allocator,
    target: *ai.ModelCompat,
    override: ai.ModelCompat,
) !void {
    if (override.supports_store) |value| target.supports_store = value;
    if (override.supports_developer_role) |value| target.supports_developer_role = value;
    if (override.supports_reasoning_effort) |value| target.supports_reasoning_effort = value;
    if (override.supports_usage_in_streaming) |value| target.supports_usage_in_streaming = value;
    if (override.max_tokens_field) |value| target.max_tokens_field = value;
    if (override.requires_tool_result_name) |value| target.requires_tool_result_name = value;
    if (override.requires_assistant_after_tool_result) |value| target.requires_assistant_after_tool_result = value;
    if (override.requires_thinking_as_text) |value| target.requires_thinking_as_text = value;
    if (override.requires_reasoning_content_on_assistant_messages) |value| target.requires_reasoning_content_on_assistant_messages = value;
    if (override.thinking_format) |value| target.thinking_format = value;
    if (override.cache_control_format) |format| {
        const copy = try allocator.dupe(u8, format);
        if (target.cache_control_format) |existing| allocator.free(existing);
        target.cache_control_format = copy;
    }
    if (override.open_router_routing_json) |routing| {
        try mergeJsonObjectStringField(allocator, &target.open_router_routing_json, routing);
    }
    if (override.vercel_gateway_routing_json) |routing| {
        try mergeJsonObjectStringField(allocator, &target.vercel_gateway_routing_json, routing);
    }
    if (override.zai_tool_stream) |value| target.zai_tool_stream = value;
    if (override.supports_strict_mode) |value| target.supports_strict_mode = value;
    if (override.send_session_affinity_headers) |value| target.send_session_affinity_headers = value;
    if (override.send_session_id_header) |value| target.send_session_id_header = value;
    if (override.supports_long_cache_retention) |value| target.supports_long_cache_retention = value;
    if (override.supports_eager_tool_input_streaming) |value| target.supports_eager_tool_input_streaming = value;
    if (override.supports_cache_control_on_tools) |value| target.supports_cache_control_on_tools = value;
    if (override.supports_temperature) |value| target.supports_temperature = value;
    if (override.force_adaptive_thinking) |value| target.force_adaptive_thinking = value;
    if (override.allow_empty_signature) |value| target.allow_empty_signature = value;
}

fn mergeJsonObjectStringField(
    allocator: std.mem.Allocator,
    target: *?[]const u8,
    override_json: []const u8,
) !void {
    const existing = target.* orelse {
        target.* = try allocator.dupe(u8, override_json);
        return;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var base = try std.json.parseFromSlice(std.json.Value, a, existing, .{});
    defer base.deinit();
    var override = try std.json.parseFromSlice(std.json.Value, a, override_json, .{});
    defer override.deinit();
    if (base.value != .object or override.value != .object) return error.InvalidModelsJson;

    var merged = std.json.Value{ .object = .empty };
    var base_iterator = base.value.object.iterator();
    while (base_iterator.next()) |entry| {
        try merged.object.put(a, try a.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
    }
    var override_iterator = override.value.object.iterator();
    while (override_iterator.next()) |entry| {
        try merged.object.put(a, try a.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
    }

    const merged_json = try std.json.Stringify.valueAlloc(allocator, merged, .{});
    allocator.free(existing);
    target.* = merged_json;
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const copy = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(copy);
    for (values, 0..) |value, index| {
        copy[index] = try allocator.dupe(u8, value);
        errdefer allocator.free(copy[index]);
    }
    return copy;
}

fn deinitStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

fn cloneAiHeaders(allocator: std.mem.Allocator, headers: []const ai.Header) ![]ai.Header {
    if (headers.len == 0) return &.{};
    var result = try allocator.alloc(ai.Header, headers.len);
    errdefer allocator.free(result);
    for (headers, 0..) |header, index| {
        result[index] = .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        };
        errdefer {
            allocator.free(result[index].name);
            allocator.free(result[index].value);
        }
    }
    return result;
}

fn deinitAiHeaders(allocator: std.mem.Allocator, headers: []const ai.Header) void {
    deinitAiHeaderItems(allocator, headers);
    if (headers.len > 0) allocator.free(headers);
}

fn deinitAiHeaderItems(allocator: std.mem.Allocator, headers: []const ai.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

fn appendAiHeaders(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(ai.Header),
    input: []const ai.Header,
) !void {
    for (input) |header| {
        try appendHeader(allocator, headers, header.name, try allocator.dupe(u8, header.value));
    }
}

fn appendResolvedHeaders(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(ai.Header),
    input: []const config_value.ResolvedHeader,
) !void {
    for (input) |header| {
        try appendHeader(allocator, headers, header.key, try allocator.dupe(u8, header.value));
    }
}

fn appendHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(ai.Header),
    name: []const u8,
    value: []u8,
) !void {
    errdefer allocator.free(value);
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    try headers.append(allocator, .{ .name = name_copy, .value = value });
}

fn parseHeadersObjectAlloc(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
) ![]config_value.HeaderInput {
    const value = maybe_value orelse return &.{};
    if (value != .object) return error.InvalidModelsJson;
    if (value.object.count() == 0) return &.{};

    var result: std.ArrayList(config_value.HeaderInput) = .empty;
    defer result.deinit(allocator);
    errdefer deinitHeaderInputs(allocator, result.items);

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.InvalidModelsJson;
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const header_value = try allocator.dupe(u8, entry.value_ptr.string);
        errdefer allocator.free(header_value);
        try result.append(allocator, .{ .key = key, .value = header_value });
    }

    return try result.toOwnedSlice(allocator);
}

fn deinitHeaderInputs(allocator: std.mem.Allocator, headers: []config_value.HeaderInput) void {
    for (headers) |header| {
        allocator.free(header.key);
        allocator.free(header.value);
    }
    if (headers.len > 0) allocator.free(headers);
}

fn cloneHeaderInputs(
    allocator: std.mem.Allocator,
    headers: []const config_value.HeaderInput,
) ![]config_value.HeaderInput {
    if (headers.len == 0) return &.{};
    const cloned = try allocator.alloc(config_value.HeaderInput, headers.len);
    var initialized: usize = 0;
    errdefer {
        deinitHeaderInputs(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (headers, 0..) |header, index| {
        const key = try allocator.dupe(u8, header.key);
        errdefer allocator.free(key);
        cloned[index] = .{
            .key = key,
            .value = try allocator.dupe(u8, header.value),
        };
        initialized += 1;
    }
    return cloned;
}

fn cloneDynamicHeaderInputs(
    allocator: std.mem.Allocator,
    headers: []const config_value.HeaderInput,
) ![]config_value.HeaderInput {
    if (headers.len == 0) return &.{};
    const cloned = try allocator.alloc(config_value.HeaderInput, headers.len);
    var initialized: usize = 0;
    errdefer {
        deinitHeaderInputs(allocator, cloned[0..initialized]);
        allocator.free(cloned);
    }
    for (headers, 0..) |header, index| {
        const key = try allocator.dupe(u8, header.key);
        errdefer allocator.free(key);
        cloned[index] = .{
            .key = key,
            .value = try cloneDynamicConfigValueAlloc(allocator, header.value),
        };
        initialized += 1;
    }
    return cloned;
}

fn parseInputAlloc(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]const []const u8 {
    const value = maybe_value orelse return cloneStringSlice(allocator, &.{"text"});
    if (value != .array) return error.InvalidModelsJson;

    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    errdefer deinitStringSlice(allocator, result.items);
    for (value.array.items) |entry| {
        if (entry != .string) return error.InvalidModelsJson;
        if (!std.mem.eql(u8, entry.string, "text") and !std.mem.eql(u8, entry.string, "image")) {
            return error.InvalidModelsJson;
        }
        try result.append(allocator, try allocator.dupe(u8, entry.string));
    }
    return try result.toOwnedSlice(allocator);
}

fn parseCost(maybe_value: ?std.json.Value) !ai.ModelCost {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.InvalidModelsJson;
    return .{
        .input = try requiredF64(value.object, "input"),
        .output = try requiredF64(value.object, "output"),
        .cache_read = try requiredF64(value.object, "cacheRead"),
        .cache_write = try requiredF64(value.object, "cacheWrite"),
    };
}

fn parsePartialCost(maybe_value: ?std.json.Value) !?PartialModelCost {
    const value = maybe_value orelse return null;
    if (value != .object) return error.InvalidModelsJson;
    return .{
        .input = try optionalF64(value.object, "input"),
        .output = try optionalF64(value.object, "output"),
        .cache_read = try optionalF64(value.object, "cacheRead"),
        .cache_write = try optionalF64(value.object, "cacheWrite"),
    };
}

fn parseThinkingLevelMapAlloc(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
) !ai.ThinkingLevelMap {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.InvalidModelsJson;
    var result = ai.ThinkingLevelMap{};
    errdefer deinitThinkingLevelMap(allocator, &result);
    result.off = try parseThinkingLevelOverrideAlloc(allocator, value.object.get("off"));
    result.minimal = try parseThinkingLevelOverrideAlloc(allocator, value.object.get("minimal"));
    result.low = try parseThinkingLevelOverrideAlloc(allocator, value.object.get("low"));
    result.medium = try parseThinkingLevelOverrideAlloc(allocator, value.object.get("medium"));
    result.high = try parseThinkingLevelOverrideAlloc(allocator, value.object.get("high"));
    result.xhigh = try parseThinkingLevelOverrideAlloc(allocator, value.object.get("xhigh"));
    return result;
}

fn parseThinkingLevelOverrideAlloc(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
) !ai.ThinkingLevelOverride {
    const value = maybe_value orelse return .unset;
    return switch (value) {
        .null => .unsupported,
        .string => |mapped| .{ .mapped = try allocator.dupe(u8, mapped) },
        else => error.InvalidModelsJson,
    };
}

fn parseCompatObjectAlloc(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
) !ai.ModelCompat {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.InvalidModelsJson;
    const object = value.object;

    var compat = ai.ModelCompat{
        .supports_store = try optionalBool(object, "supportsStore"),
        .supports_developer_role = try optionalBool(object, "supportsDeveloperRole"),
        .supports_reasoning_effort = try optionalBool(object, "supportsReasoningEffort"),
        .supports_usage_in_streaming = try optionalBool(object, "supportsUsageInStreaming"),
        .max_tokens_field = try parseMaxTokensField(object.get("maxTokensField")),
        .requires_tool_result_name = try optionalBool(object, "requiresToolResultName"),
        .requires_assistant_after_tool_result = try optionalBool(object, "requiresAssistantAfterToolResult"),
        .requires_thinking_as_text = try optionalBool(object, "requiresThinkingAsText"),
        .requires_reasoning_content_on_assistant_messages = try optionalBool(object, "requiresReasoningContentOnAssistantMessages"),
        .thinking_format = try parseThinkingFormat(object.get("thinkingFormat")),
        .zai_tool_stream = try optionalBool(object, "zaiToolStream"),
        .supports_strict_mode = try optionalBool(object, "supportsStrictMode"),
        .send_session_affinity_headers = try optionalBool(object, "sendSessionAffinityHeaders"),
        .send_session_id_header = try optionalBool(object, "sendSessionIdHeader"),
        .supports_long_cache_retention = try optionalBool(object, "supportsLongCacheRetention"),
        .supports_eager_tool_input_streaming = try optionalBool(object, "supportsEagerToolInputStreaming"),
        .supports_cache_control_on_tools = try optionalBool(object, "supportsCacheControlOnTools"),
        .supports_temperature = try optionalBool(object, "supportsTemperature"),
        .force_adaptive_thinking = try optionalBool(object, "forceAdaptiveThinking"),
        .allow_empty_signature = try optionalBool(object, "allowEmptySignature"),
    };
    errdefer deinitModelCompat(allocator, &compat);

    if (try optionalString(object, "cacheControlFormat")) |format| {
        if (!std.mem.eql(u8, format, "anthropic")) return error.InvalidModelsJson;
        compat.cache_control_format = try allocator.dupe(u8, format);
    }
    compat.open_router_routing_json = try parseOpenRouterRoutingJsonAlloc(allocator, object.get("openRouterRouting"));
    compat.vercel_gateway_routing_json = try parseVercelGatewayRoutingJsonAlloc(allocator, object.get("vercelGatewayRouting"));

    return compat;
}

fn parseOpenRouterRoutingJsonAlloc(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
) !?[]u8 {
    const value = maybe_value orelse return null;
    if (value != .object) return error.InvalidModelsJson;
    try validateOpenRouterRouting(value.object);
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn parseVercelGatewayRoutingJsonAlloc(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
) !?[]u8 {
    const value = maybe_value orelse return null;
    if (value != .object) return error.InvalidModelsJson;
    try validateOptionalStringArray(value.object, "only");
    try validateOptionalStringArray(value.object, "order");
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn validateOpenRouterRouting(object: std.json.ObjectMap) !void {
    try validateOptionalBool(object, "allow_fallbacks");
    try validateOptionalBool(object, "require_parameters");
    try validateOptionalBool(object, "zdr");
    try validateOptionalBool(object, "enforce_distillable_text");
    try validateOptionalStringArray(object, "order");
    try validateOptionalStringArray(object, "only");
    try validateOptionalStringArray(object, "ignore");
    try validateOptionalStringArray(object, "quantizations");

    if (object.get("data_collection")) |value| {
        if (value != .string) return error.InvalidModelsJson;
        if (!std.mem.eql(u8, value.string, "deny") and !std.mem.eql(u8, value.string, "allow")) {
            return error.InvalidModelsJson;
        }
    }

    if (object.get("sort")) |value| {
        switch (value) {
            .string => {},
            .object => |sort| {
                if (sort.get("by")) |by| if (by != .string) return error.InvalidModelsJson;
                if (sort.get("partition")) |partition| switch (partition) {
                    .string, .null => {},
                    else => return error.InvalidModelsJson,
                };
            },
            else => return error.InvalidModelsJson,
        }
    }

    if (object.get("max_price")) |value| {
        if (value != .object) return error.InvalidModelsJson;
        const fields = [_][]const u8{ "prompt", "completion", "image", "audio", "request" };
        for (fields) |field| {
            if (value.object.get(field)) |price| {
                if (!isJsonNumber(price) and price != .string) return error.InvalidModelsJson;
            }
        }
    }

    try validateOptionalOpenRouterPercentile(object, "preferred_min_throughput");
    try validateOptionalOpenRouterPercentile(object, "preferred_max_latency");
}

fn validateOptionalBool(object: std.json.ObjectMap, key: []const u8) !void {
    if (object.get(key)) |value| {
        if (value != .bool) return error.InvalidModelsJson;
    }
}

fn validateOptionalStringArray(object: std.json.ObjectMap, key: []const u8) !void {
    if (object.get(key)) |value| {
        if (value != .array) return error.InvalidModelsJson;
        for (value.array.items) |item| {
            if (item != .string) return error.InvalidModelsJson;
        }
    }
}

fn validateOptionalOpenRouterPercentile(object: std.json.ObjectMap, key: []const u8) !void {
    const value = object.get(key) orelse return;
    if (isJsonNumber(value)) return;
    if (value != .object) return error.InvalidModelsJson;
    const fields = [_][]const u8{ "p50", "p75", "p90", "p99" };
    for (fields) |field| {
        if (value.object.get(field)) |cutoff| {
            if (!isJsonNumber(cutoff)) return error.InvalidModelsJson;
        }
    }
}

fn isJsonNumber(value: std.json.Value) bool {
    return switch (value) {
        .integer, .float, .number_string => true,
        else => false,
    };
}

fn parseMaxTokensField(maybe_value: ?std.json.Value) !?ai.MaxTokensField {
    const value = maybe_value orelse return null;
    if (value != .string) return error.InvalidModelsJson;
    if (std.mem.eql(u8, value.string, "max_completion_tokens")) return .max_completion_tokens;
    if (std.mem.eql(u8, value.string, "max_tokens")) return .max_tokens;
    return error.InvalidModelsJson;
}

fn parseThinkingFormat(maybe_value: ?std.json.Value) !?ai.ThinkingFormat {
    const value = maybe_value orelse return null;
    if (value != .string) return error.InvalidModelsJson;
    if (std.mem.eql(u8, value.string, "openai")) return .openai;
    if (std.mem.eql(u8, value.string, "openrouter")) return .openrouter;
    if (std.mem.eql(u8, value.string, "deepseek")) return .deepseek;
    if (std.mem.eql(u8, value.string, "together")) return .together;
    if (std.mem.eql(u8, value.string, "zai")) return .zai;
    if (std.mem.eql(u8, value.string, "qwen")) return .qwen;
    if (std.mem.eql(u8, value.string, "qwen-chat-template")) return .qwen_chat_template;
    if (std.mem.eql(u8, value.string, "string-thinking")) return .string_thinking;
    return error.InvalidModelsJson;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else error.InvalidModelsJson;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try optionalString(object, key)) orelse return error.InvalidModelsJson;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else error.InvalidModelsJson;
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidModelsJson,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else error.InvalidModelsJson,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch error.InvalidModelsJson,
        else => error.InvalidModelsJson,
    };
}

fn optionalPositiveU64(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = try optionalU64(object, key) orelse return null;
    return if (value > 0) value else error.InvalidModelsJson;
}

fn optionalF64(object: std.json.ObjectMap, key: []const u8) !?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch error.InvalidModelsJson,
        else => error.InvalidModelsJson,
    };
}

fn requiredF64(object: std.json.ObjectMap, key: []const u8) !f64 {
    return (try optionalF64(object, key)) orelse return error.InvalidModelsJson;
}

fn schemaPathAlloc(allocator: std.mem.Allocator, base: []const u8, field: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, field });
}

fn modelRequestKeyAlloc(allocator: std.mem.Allocator, provider: []const u8, model_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ provider, model_id });
}

fn storeProviderOverride(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(ProviderOverride),
    provider: []const u8,
    override: ProviderOverride,
) !void {
    var owned = override;
    errdefer owned.deinit(allocator);

    if (map.getPtr(provider)) |existing| {
        existing.deinit(allocator);
        existing.* = owned;
        return;
    }

    const key = try allocator.dupe(u8, provider);
    errdefer allocator.free(key);
    try map.put(key, owned);
}

fn storeModelOverride(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(ModelOverride),
    provider: []const u8,
    model_id: []const u8,
    override: ModelOverride,
) !void {
    var owned = override;
    errdefer owned.deinit(allocator);

    const key = try modelRequestKeyAlloc(allocator, provider, model_id);
    errdefer allocator.free(key);
    if (map.getPtr(key)) |existing| {
        existing.deinit(allocator);
        existing.* = owned;
        allocator.free(key);
        return;
    }

    try map.put(key, owned);
}

fn deinitProviderOverrides(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(ProviderOverride),
) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn deinitRegisteredProviders(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(OwnedProviderConfig),
) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn deinitModelOverrides(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(ModelOverride),
) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn isBuiltInProvider(provider: []const u8) bool {
    for (ai.models.getProviders()) |candidate| {
        if (std.mem.eql(u8, candidate, provider)) return true;
    }
    return false;
}

fn builtInDefaultApi(provider: []const u8) ?[]const u8 {
    var models = ai.models.getModels(provider);
    return if (models.next()) |model| model.api else null;
}

fn builtInDefaultBaseUrl(provider: []const u8) ?[]const u8 {
    var models = ai.models.getModels(provider);
    return if (models.next()) |model| model.base_url else null;
}

fn builtInProviderDisplayName(provider: []const u8) ?[]const u8 {
    const display_names = [_]struct { id: []const u8, name: []const u8 }{
        .{ .id = "anthropic", .name = "Anthropic" },
        .{ .id = "amazon-bedrock", .name = "Amazon Bedrock" },
        .{ .id = "azure-openai-responses", .name = "Azure OpenAI Responses" },
        .{ .id = "cerebras", .name = "Cerebras" },
        .{ .id = "cloudflare-ai-gateway", .name = "Cloudflare AI Gateway" },
        .{ .id = "cloudflare-workers-ai", .name = "Cloudflare Workers AI" },
        .{ .id = "deepseek", .name = "DeepSeek" },
        .{ .id = "fireworks", .name = "Fireworks" },
        .{ .id = "google", .name = "Google Gemini" },
        .{ .id = "google-vertex", .name = "Google Vertex AI" },
        .{ .id = "groq", .name = "Groq" },
        .{ .id = "huggingface", .name = "Hugging Face" },
        .{ .id = "kimi-coding", .name = "Kimi For Coding" },
        .{ .id = "mistral", .name = "Mistral" },
        .{ .id = "minimax", .name = "MiniMax" },
        .{ .id = "minimax-cn", .name = "MiniMax (China)" },
        .{ .id = "moonshotai", .name = "Moonshot AI" },
        .{ .id = "moonshotai-cn", .name = "Moonshot AI (China)" },
        .{ .id = "opencode", .name = "OpenCode Zen" },
        .{ .id = "opencode-go", .name = "OpenCode Go" },
        .{ .id = "openai", .name = "OpenAI" },
        .{ .id = "openrouter", .name = "OpenRouter" },
        .{ .id = "together", .name = "Together AI" },
        .{ .id = "vercel-ai-gateway", .name = "Vercel AI Gateway" },
        .{ .id = "xai", .name = "xAI" },
        .{ .id = "zai", .name = "ZAI" },
        .{ .id = "xiaomi", .name = "Xiaomi MiMo" },
        .{ .id = "xiaomi-token-plan-cn", .name = "Xiaomi MiMo Token Plan (China)" },
        .{ .id = "xiaomi-token-plan-ams", .name = "Xiaomi MiMo Token Plan (Amsterdam)" },
        .{ .id = "xiaomi-token-plan-sgp", .name = "Xiaomi MiMo Token Plan (Singapore)" },
    };
    for (display_names) |entry| {
        if (std.mem.eql(u8, entry.id, provider)) return entry.name;
    }
    return null;
}

fn joinEnvVarNamesAlloc(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (names, 0..) |name, index| {
        if (index > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, name);
    }
    return try output.toOwnedSlice(allocator);
}

const TestCommandRunner = struct {
    calls: usize = 0,

    fn run(ptr: ?*anyopaque, allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
        const self: *TestCommandRunner = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        if (std.mem.eql(u8, command, "fail")) return null;
        return try allocator.dupe(u8, command);
    }
};

fn makeTestRegistry(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    runner: *TestCommandRunner,
    models_json_path: []const u8,
) !struct {
    allocator: std.mem.Allocator,
    oauth_registry: *ai.oauth.Registry,
    resolver: *config_value.Resolver,
    storage: *auth_storage.AuthStorage,
    registry: ModelRegistry,

    fn deinit(self: *@This()) void {
        self.registry.deinit();
        self.storage.deinit();
        self.allocator.destroy(self.storage);
        self.resolver.deinit();
        self.allocator.destroy(self.resolver);
        self.oauth_registry.deinit();
        self.allocator.destroy(self.oauth_registry);
    }
} {
    const oauth_registry = try allocator.create(ai.oauth.Registry);
    errdefer allocator.destroy(oauth_registry);
    oauth_registry.* = try ai.oauth.Registry.init(allocator);
    errdefer oauth_registry.deinit();

    const resolver = try allocator.create(config_value.Resolver);
    errdefer allocator.destroy(resolver);
    resolver.* = config_value.Resolver.init(allocator, env);
    errdefer resolver.deinit();
    resolver.runner = .{ .ptr = runner, .run_fn = TestCommandRunner.run };

    const storage = try allocator.create(auth_storage.AuthStorage);
    errdefer allocator.destroy(storage);
    storage.* = try auth_storage.AuthStorage.initMemory(allocator, env, oauth_registry, resolver);
    errdefer storage.deinit();

    var registry = try ModelRegistry.init(allocator, storage, models_json_path);
    errdefer registry.deinit();
    return .{
        .allocator = allocator,
        .oauth_registry = oauth_registry,
        .resolver = resolver,
        .storage = storage,
        .registry = registry,
    };
}

fn writeApiKeyModelsJson(
    allocator: std.mem.Allocator,
    tmp_dir: anytype,
    api_key: []const u8,
    extra_provider_fields: []const u8,
) !void {
    const escaped = try jsonStringAlloc(allocator, api_key);
    defer allocator.free(escaped);
    const content = try std.fmt.allocPrint(
        allocator,
        \\{{"providers":{{"custom-provider":{{"baseUrl":"https://example.com/v1","apiKey":{s},"api":"anthropic-messages"{s},"models":[{{"id":"test-model","name":"Test Model","reasoning":false,"input":["text"],"cost":{{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}},"contextWindow":100000,"maxTokens":8000}}]}}}}}}
    ,
        .{ escaped, extra_provider_fields },
    );
    defer allocator.free(content);
    try tmp_dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
}

fn jsonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try json.write(value);
    return output.toOwnedSlice();
}

fn expectJsonStringArray(json: []const u8, field: []const u8, expected: []const []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ExpectedJsonObject;
    const value = parsed.value.object.get(field) orelse return error.MissingJsonField;
    if (value != .array) return error.ExpectedJsonArray;
    try std.testing.expectEqual(expected.len, value.array.items.len);
    for (expected, 0..) |expected_item, index| {
        try std.testing.expectEqualStrings(expected_item, value.array.items[index].string);
    }
}

fn expectJsonBool(json: []const u8, field: []const u8, expected: bool) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ExpectedJsonObject;
    const value = parsed.value.object.get(field) orelse return error.MissingJsonField;
    if (value != .bool) return error.ExpectedJsonBool;
    try std.testing.expectEqual(expected, value.bool);
}

// Ported from packages/coding-agent/src/core/model-registry.ts models.json
// schema and additional validation behavior.
test "model registry reports models.json validation failures and preserves built-ins" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    const Case = struct {
        content: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{
            .content = "{\"providers\":",
            .expected = "Failed to parse models.json:",
        },
        .{
            .content = "{}",
            .expected = "Invalid models.json schema:\n  - providers: Expected required property",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"apiKey\":\"\"}}}",
            .expected = "providers.demo.apiKey: Expected string length greater than or equal to 1",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"baseUrl\":\"https://example.com\",\"apiKey\":\"key\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"model\",\"input\":[\"audio\"]}]}}}",
            .expected = "providers.demo.models.0.input.0: Expected 'text' or 'image'",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"baseUrl\":\"https://example.com\",\"apiKey\":\"key\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"model\",\"cost\":{\"input\":0}}]}}}",
            .expected = "providers.demo.models.0.cost.output: Expected required property",
        },
        .{
            .content = "{\"providers\":{\"demo\":{}}}",
            .expected = "Provider demo: must specify \"baseUrl\", \"headers\", \"compat\", \"modelOverrides\", or \"models\".",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"modelOverrides\":{}}}}",
            .expected = "Provider demo: must specify \"baseUrl\", \"headers\", \"compat\", \"modelOverrides\", or \"models\".",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"models\":[{\"id\":\"model\",\"api\":\"openai-completions\"}]}}}",
            .expected = "Provider demo: \"baseUrl\" is required when defining custom models.",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"baseUrl\":\"https://example.com\",\"models\":[{\"id\":\"model\",\"api\":\"openai-completions\"}]}}}",
            .expected = "Provider demo: \"apiKey\" is required when defining custom models.",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"baseUrl\":\"https://example.com\",\"apiKey\":\"key\",\"models\":[{\"id\":\"model\"}]}}}",
            .expected = "Provider demo, model model: no \"api\" specified. Set at provider or model level.",
        },
        .{
            .content = "{\"providers\":{\"demo\":{\"baseUrl\":\"https://example.com\",\"apiKey\":\"key\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"model\",\"maxTokens\":0}]}}}",
            .expected = "Provider demo, model model: invalid maxTokens",
        },
    };

    for (cases) |case| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = case.content });
        var env = std.process.Environ.Map.init(allocator);
        defer env.deinit();
        var runner: TestCommandRunner = .{};
        var harness = try makeTestRegistry(allocator, &env, &runner, path);
        defer harness.deinit();

        const load_error = harness.registry.getError() orelse return error.ExpectedModelsJsonLoadError;
        try std.testing.expect(std.mem.indexOf(u8, load_error, case.expected) != null);
        try std.testing.expect(harness.registry.find("openrouter", "anthropic/claude-sonnet-4") != null);
    }
}

test "model registry accepts schema-valid empty custom model input arrays" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    const content =
        \\{"providers":{"demo":{"baseUrl":"https://example.com","apiKey":"key","api":"openai-completions","models":[{"id":"model","input":[]}]}}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), harness.registry.getError());
    const model = harness.registry.find("demo", "model") orelse return error.ModelMissing;
    try std.testing.expectEqual(@as(usize, 0), model.input.len);
}

test "model registry aggregates models.json schema validation failures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    const content =
        \\{"providers":{"demo":{"apiKey":"","authHeader":"true","models":[{"name":5,"input":["audio",false],"cost":{"input":"free"}}],"modelOverrides":{"demo-model":{"reasoning":"yes","headers":{"X-Test":1},"thinkingLevelMap":{"high":false}}}},"not-object":false}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const load_error = harness.registry.getError() orelse return error.ExpectedModelsJsonLoadError;
    try std.testing.expect(std.mem.indexOf(u8, load_error, "Invalid models.json schema:\n  - providers.demo.apiKey: Expected string length greater than or equal to 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_error, "providers.demo.authHeader: Expected boolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_error, "providers.demo.models.0.id: Expected required property") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_error, "providers.demo.models.0.input.0: Expected 'text' or 'image'") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_error, "providers.demo.models.0.cost.output: Expected required property") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_error, "providers.demo.modelOverrides.demo-model.headers.X-Test: Expected string") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_error, "providers.not-object: Expected object") != null);
    try std.testing.expect(harness.registry.find("openrouter", "anthropic/claude-sonnet-4") != null);
}

// Ported from packages/coding-agent/test/model-registry.test.ts API key resolution cases.
test "model registry resolves models.json apiKey commands on every provider lookup" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try writeApiKeyModelsJson(allocator, tmp.dir, "!key-value", "");
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const model = harness.registry.find("custom-provider", "test-model") orelse return error.ModelMissing;
    try std.testing.expect(try harness.registry.hasConfiguredAuth(model));

    for (0..3) |_| {
        const key = (try harness.registry.getApiKeyForProviderAlloc(allocator, "custom-provider")).?;
        defer allocator.free(key);
        try std.testing.expectEqualStrings("key-value", key);
    }
    try std.testing.expectEqual(@as(usize, 3), runner.calls);
}

test "model registry resolves models.json apiKey environment references without caching" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try env.put("TEST_API_KEY_CACHE_TEST_98765", "first-value");
    try writeApiKeyModelsJson(allocator, tmp.dir, "$TEST_API_KEY_CACHE_TEST_98765", "");
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();

    var key = (try harness.registry.getApiKeyForProviderAlloc(allocator, "custom-provider")).?;
    try std.testing.expectEqualStrings("first-value", key);
    allocator.free(key);

    try env.put("TEST_API_KEY_CACHE_TEST_98765", "second-value");
    key = (try harness.registry.getApiKeyForProviderAlloc(allocator, "custom-provider")).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("second-value", key);
    try std.testing.expectEqual(@as(usize, 0), runner.calls);
}

test "model registry reports provider auth status for models.json apiKey forms" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};

    try env.put("TEST_API_KEY_STATUS_PART_A_98765", "left");
    try env.put("TEST_API_KEY_STATUS_PART_B_98765", "right");
    try writeApiKeyModelsJson(
        allocator,
        tmp.dir,
        "${TEST_API_KEY_STATUS_PART_A_98765}_${TEST_API_KEY_STATUS_PART_B_98765}",
        "",
    );
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    var status = try harness.registry.getProviderAuthStatusAlloc(allocator, "custom-provider");
    try std.testing.expect(status.configured);
    try std.testing.expectEqual(auth_storage.AuthSource.environment, status.source.?);
    try std.testing.expectEqualStrings(
        "TEST_API_KEY_STATUS_PART_A_98765, TEST_API_KEY_STATUS_PART_B_98765",
        status.label.?,
    );
    status.deinit(allocator);

    try writeApiKeyModelsJson(allocator, tmp.dir, "literal-api-key", "");
    try harness.registry.refresh();
    status = try harness.registry.getProviderAuthStatusAlloc(allocator, "custom-provider");
    try std.testing.expect(status.configured);
    try std.testing.expectEqual(auth_storage.AuthSource.models_json_key, status.source.?);
    try std.testing.expectEqual(null, status.label);
    status.deinit(allocator);

    try writeApiKeyModelsJson(allocator, tmp.dir, "!key-value", "");
    try harness.registry.refresh();
    status = try harness.registry.getProviderAuthStatusAlloc(allocator, "custom-provider");
    defer status.deinit(allocator);
    try std.testing.expect(status.configured);
    try std.testing.expectEqual(auth_storage.AuthSource.models_json_command, status.source.?);
    try std.testing.expectEqual(@as(usize, 0), runner.calls);
}

test "model registry keeps missing explicit env apiKey unavailable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try writeApiKeyModelsJson(allocator, tmp.dir, "$TEST_API_KEY_MISSING_TEST_98765", "");
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    var status = try harness.registry.getProviderAuthStatusAlloc(allocator, "custom-provider");
    defer status.deinit(allocator);
    try std.testing.expect(!status.configured);
    try std.testing.expectEqual(null, status.source);

    const available = try harness.registry.getAvailableAlloc(allocator);
    defer allocator.free(available);
    for (available) |model| {
        try std.testing.expect(!std.mem.eql(u8, model.provider, "custom-provider"));
    }
}

test "model registry resolves provider model headers and authHeader per request" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    const content =
        \\{"providers":{"custom-provider":{"baseUrl":"https://example.com/v1","apiKey":"!request-token","api":"anthropic-messages","authHeader":true,"headers":{"X-Provider":"provider-value"},"models":[{"id":"test-model","name":"Test Model","headers":{"X-Model":"model-value"},"reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":100000,"maxTokens":8000}]}}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const model = harness.registry.find("custom-provider", "test-model") orelse return error.ModelMissing;

    for (0..2) |_| {
        var request_auth = try harness.registry.getApiKeyAndHeadersAlloc(allocator, model);
        defer request_auth.deinit(allocator);
        switch (request_auth) {
            .ok => |auth| {
                try std.testing.expectEqualStrings("request-token", auth.api_key.?);
                try std.testing.expectEqualStrings("provider-value", auth.getHeader("X-Provider").?);
                try std.testing.expectEqualStrings("model-value", auth.getHeader("X-Model").?);
                try std.testing.expectEqualStrings("Bearer request-token", auth.getHeader("Authorization").?);
            },
            .failure => return error.UnexpectedFailure,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), runner.calls);
}

// Ported from packages/coding-agent/test/model-registry.test.ts modelOverrides cases.
test "model registry applies built-in model overrides and refresh restores them" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    const content =
        \\{"providers":{"openrouter":{"baseUrl":"https://my-proxy.example.com/v1","modelOverrides":{"anthropic/claude-sonnet-4":{"name":"Proxied Sonnet","reasoning":false,"input":["text"],"cost":{"input":99},"contextWindow":1234,"maxTokens":4321,"headers":{"X-Custom-Model-Header":"value"}}}}}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();

    const sonnet = harness.registry.find("openrouter", "anthropic/claude-sonnet-4") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("https://my-proxy.example.com/v1", sonnet.base_url);
    try std.testing.expectEqualStrings("Proxied Sonnet", sonnet.name);
    try std.testing.expect(!sonnet.reasoning);
    try std.testing.expectEqual(@as(usize, 1), sonnet.input.len);
    try std.testing.expectEqualStrings("text", sonnet.input[0]);
    try std.testing.expectEqual(@as(f64, 99), sonnet.cost.input);
    try std.testing.expect(sonnet.cost.output > 0);
    try std.testing.expectEqual(@as(u64, 1234), sonnet.context_window);
    try std.testing.expectEqual(@as(u64, 4321), sonnet.max_tokens);

    var request_auth = try harness.registry.getApiKeyAndHeadersAlloc(allocator, sonnet);
    defer request_auth.deinit(allocator);
    switch (request_auth) {
        .ok => |auth| try std.testing.expectEqualStrings("value", auth.getHeader("X-Custom-Model-Header").?),
        .failure => return error.UnexpectedFailure,
    }

    const opus = harness.registry.find("openrouter", "anthropic/claude-opus-4") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("https://my-proxy.example.com/v1", opus.base_url);
    try std.testing.expect(!std.mem.eql(u8, "Proxied Sonnet", opus.name));

    const updated_content =
        \\{"providers":{"openrouter":{"modelOverrides":{"anthropic/claude-sonnet-4":{"name":"Second Name"}}}}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = updated_content });
    try harness.registry.refresh();
    const updated = harness.registry.find("openrouter", "anthropic/claude-sonnet-4") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("Second Name", updated.name);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    try harness.registry.refresh();
    const restored = harness.registry.find("openrouter", "anthropic/claude-sonnet-4") orelse return error.ModelMissing;
    try std.testing.expect(!std.mem.eql(u8, "Second Name", restored.name));
}

test "model registry parses custom model thinking map and merged compat" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    const content =
        \\{"providers":{"demo":{"baseUrl":"https://example.com/v1","apiKey":"DEMO_KEY","api":"openai-completions","compat":{"supportsUsageInStreaming":false,"maxTokensField":"max_tokens"},"models":[{"id":"demo-model","reasoning":true,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"contextWindow":1000,"maxTokens":100,"thinkingLevelMap":{"minimal":null,"high":"max"},"compat":{"supportsUsageInStreaming":true,"maxTokensField":"max_completion_tokens","supportsStrictMode":false,"cacheControlFormat":"anthropic"}}]}}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), harness.registry.getError());

    const model = harness.registry.find("demo", "demo-model") orelse return error.ModelMissing;
    switch (model.thinking_level_map.minimal) {
        .unsupported => {},
        else => return error.ExpectedUnsupportedThinkingLevel,
    }
    switch (model.thinking_level_map.high) {
        .mapped => |value| try std.testing.expectEqualStrings("max", value),
        else => return error.ExpectedMappedThinkingLevel,
    }
    try std.testing.expectEqual(@as(?bool, true), model.compat.supports_usage_in_streaming);
    try std.testing.expectEqual(@as(?ai.MaxTokensField, .max_completion_tokens), model.compat.max_tokens_field);
    try std.testing.expectEqual(@as(?bool, false), model.compat.supports_strict_mode);
    try std.testing.expectEqualStrings("anthropic", model.compat.cache_control_format.?);
}

// Ported from packages/coding-agent/test/model-registry.test.ts modelOverrides
// compat.openRouterRouting cases.
test "model registry parses and deep merges OpenRouter routing compat" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    const content =
        \\{"providers":{"openrouter":{"compat":{"openRouterRouting":{"only":["anthropic"],"allow_fallbacks":false}},"modelOverrides":{"anthropic/claude-sonnet-4":{"compat":{"openRouterRouting":{"order":["amazon-bedrock"]}}},"anthropic/claude-opus-4":{"compat":{"openRouterRouting":{"only":["amazon-bedrock"]}}}}}}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();

    const sonnet = harness.registry.find("openrouter", "anthropic/claude-sonnet-4") orelse return error.ModelMissing;
    const sonnet_routing = sonnet.compat.open_router_routing_json orelse return error.MissingRoutingCompat;
    try expectJsonStringArray(sonnet_routing, "only", &.{"anthropic"});
    try expectJsonStringArray(sonnet_routing, "order", &.{"amazon-bedrock"});
    try expectJsonBool(sonnet_routing, "allow_fallbacks", false);

    const opus = harness.registry.find("openrouter", "anthropic/claude-opus-4") orelse return error.ModelMissing;
    const opus_routing = opus.compat.open_router_routing_json orelse return error.MissingRoutingCompat;
    try expectJsonStringArray(opus_routing, "only", &.{"amazon-bedrock"});
}

test "model registry applies provider compat overrides to built-in models" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    const content =
        \\{"providers":{"openrouter":{"compat":{"supportsUsageInStreaming":false,"supportsStrictMode":false}}}}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = content });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const sonnet = harness.registry.find("openrouter", "anthropic/claude-sonnet-4") orelse return error.ModelMissing;
    try std.testing.expectEqual(@as(?bool, false), sonnet.compat.supports_usage_in_streaming);
    try std.testing.expectEqual(@as(?bool, false), sonnet.compat.supports_strict_mode);
}

fn dynamicTestModel(id: []const u8) ai.Model {
    return .{
        .id = id,
        .name = id,
        .api = "",
        .provider = "",
        .base_url = "",
        .input = &.{"text"},
    };
}

const DynamicTestOAuth = struct {
    fn provider(context: *u8, name: []const u8) ai.oauth.OAuthProviderInterface {
        return .{
            .id = "ignored",
            .name = name,
            .context = context,
            .login_fn = login,
            .refresh_token_fn = refreshToken,
            .get_api_key_fn = getApiKey,
        };
    }

    fn login(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: ai.oauth.OAuthLoginCallbacks,
    ) !ai.oauth.OAuthCredentialsResult {
        return error.TestOAuthLoginNotUsed;
    }

    fn refreshToken(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: ai.oauth.OAuthCredentials,
    ) !ai.oauth.OAuthCredentialsResult {
        return error.TestOAuthRefreshNotUsed;
    }

    fn getApiKey(_: *anyopaque, credentials: ai.oauth.OAuthCredentials) []const u8 {
        return credentials.access;
    }

    fn modifyingProvider(context: *ModifierContext, name: []const u8) ai.oauth.OAuthProviderInterface {
        var result = provider(undefined, name);
        result.context = context;
        result.modify_models_fn = modifyModels;
        return result;
    }

    const ModifierContext = struct {
        provider: []const u8,
        base_url: []const u8,
        calls: usize = 0,
    };

    fn modifyModels(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        models: []const ai.Model,
        _: ai.oauth.OAuthCredentials,
    ) !ai.oauth_types.ModifiedModels {
        const context: *ModifierContext = @ptrCast(@alignCast(ptr));
        context.calls += 1;
        var modified = try ai.oauth_types.ModifiedModels.init(allocator, models);
        errdefer modified.deinit();
        for (modified.models) |*model| {
            if (std.mem.eql(u8, model.provider, context.provider)) {
                model.base_url = try modified.arena.allocator().dupe(u8, context.base_url);
            }
        }
        return modified;
    }
};

const DynamicTestSimpleStream = struct {
    const Context = struct {
        provider: []const u8,
        fail: bool = false,
        calls: usize = 0,
    };

    fn interface(context: *Context) ai.api_registry.SimpleStream {
        return .{
            .context = context,
            .stream_fn = stream,
        };
    }

    fn stream(
        ptr: *anyopaque,
        model: ai.Model,
        _: ai.Context,
        _: ?ai.SimpleStreamOptions,
    ) !ai.StreamResult {
        const context: *Context = @ptrCast(@alignCast(ptr));
        context.calls += 1;
        if (context.fail) return error.DynamicSimpleStreamOverride;
        return .{
            .allocator = std.testing.allocator,
            .message = .{
                .content = &.{},
                .api = model.api,
                .provider = context.provider,
                .model = model.id,
            },
        };
    }
};

// Ported from packages/coding-agent/test/model-registry.test.ts dynamic provider
// lifecycle and override persistence cases.
test "model registry replays dynamic provider models headers and base URL overrides across refresh" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const models = [_]ai.Model{
        dynamicTestModel("custom-a"),
        dynamicTestModel("custom-b"),
    };
    try harness.registry.registerProvider("custom-provider", .{
        .base_url = "https://custom.test/v1",
        .api_key = "test-key",
        .api = "openai-completions",
        .models = &models,
    });
    try harness.registry.refresh();

    try std.testing.expectEqual(@as(usize, 2), countModelsForProvider(&harness.registry, "custom-provider"));
    try std.testing.expectEqualStrings(
        "https://custom.test/v1",
        harness.registry.find("custom-provider", "custom-a").?.base_url,
    );

    const headers = [_]config_value.HeaderInput{.{ .key = "x-proxy", .value = "enabled" }};
    try harness.registry.registerProvider("custom-provider", .{
        .base_url = "https://proxy.test/custom",
        .headers = &headers,
    });
    try harness.registry.refresh();

    const model = harness.registry.find("custom-provider", "custom-a") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("https://proxy.test/custom", model.base_url);
    var request_auth = try harness.registry.getApiKeyAndHeadersAlloc(allocator, model);
    defer request_auth.deinit(allocator);
    switch (request_auth) {
        .ok => |auth| try std.testing.expectEqualStrings("enabled", auth.getHeader("x-proxy").?),
        .failure => return error.UnexpectedFailure,
    }

    try harness.registry.unregisterProvider("custom-provider");
    try std.testing.expectEqual(@as(usize, 0), countModelsForProvider(&harness.registry, "custom-provider"));
}

test "model registry restores built-in models after unregistering a dynamic base URL override" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const original = harness.registry.find("anthropic", "claude-sonnet-4-5") orelse return error.ModelMissing;
    const original_base_url = try allocator.dupe(u8, original.base_url);
    defer allocator.free(original_base_url);

    try harness.registry.registerProvider("anthropic", .{ .base_url = "https://proxy.test/anthropic" });
    try harness.registry.refresh();
    const overridden = harness.registry.find("anthropic", "claude-sonnet-4-5") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("https://proxy.test/anthropic", overridden.base_url);

    try harness.registry.unregisterProvider("anthropic");
    const restored = harness.registry.find("anthropic", "claude-sonnet-4-5") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings(original_base_url, restored.base_url);
}

test "model registry replaces built-in dynamic provider models and overlays base URL across refresh" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const models = [_]ai.Model{dynamicTestModel("custom-claude")};
    try harness.registry.registerProvider("anthropic", .{
        .base_url = "https://custom.test/anthropic",
        .api_key = "test-key",
        .api = "anthropic-messages",
        .models = &models,
    });
    try harness.registry.refresh();

    try std.testing.expectEqual(@as(usize, 1), countModelsForProvider(&harness.registry, "anthropic"));
    try std.testing.expectEqualStrings(
        "https://custom.test/anthropic",
        harness.registry.find("anthropic", "custom-claude").?.base_url,
    );

    try harness.registry.registerProvider("anthropic", .{ .base_url = "https://proxy.test/anthropic" });
    try harness.registry.refresh();

    try std.testing.expectEqual(@as(usize, 1), countModelsForProvider(&harness.registry, "anthropic"));
    try std.testing.expectEqualStrings(
        "https://proxy.test/anthropic",
        harness.registry.find("anthropic", "custom-claude").?.base_url,
    );
}

test "model registry keeps dynamic provider models during header-only refresh overlays" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const models = [_]ai.Model{
        dynamicTestModel("custom-a"),
        dynamicTestModel("custom-b"),
    };
    try harness.registry.registerProvider("custom-provider", .{
        .base_url = "https://custom.test/v1",
        .api_key = "test-key",
        .api = "openai-completions",
        .models = &models,
    });
    const headers = [_]config_value.HeaderInput{.{ .key = "x-proxy", .value = "enabled" }};
    try harness.registry.registerProvider("custom-provider", .{ .headers = &headers });
    try harness.registry.refresh();

    try std.testing.expectEqual(@as(usize, 2), countModelsForProvider(&harness.registry, "custom-provider"));
    const model = harness.registry.find("custom-provider", "custom-a") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("https://custom.test/v1", model.base_url);
    var request_auth = try harness.registry.getApiKeyAndHeadersAlloc(allocator, model);
    defer request_auth.deinit(allocator);
    switch (request_auth) {
        .ok => |auth| try std.testing.expectEqualStrings("enabled", auth.getHeader("x-proxy").?),
        .failure => return error.UnexpectedFailure,
    }
}

test "model registry preserves models when a dynamic provider replacement fails validation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    const valid_models = [_]ai.Model{dynamicTestModel("demo-model")};
    try harness.registry.registerProvider("demo-provider", .{
        .base_url = "https://provider.test/v1",
        .api_key = "test-key",
        .api = "openai-completions",
        .models = &valid_models,
    });

    const broken_models = [_]ai.Model{dynamicTestModel("broken-model")};
    try std.testing.expectError(error.DynamicProviderApiRequired, harness.registry.registerProvider("demo-provider", .{
        .base_url = "https://provider.test/v2",
        .api_key = "test-key",
        .models = &broken_models,
    }));
    try std.testing.expect(harness.registry.find("demo-provider", "demo-model") != null);
    try harness.registry.refresh();
    try std.testing.expect(harness.registry.find("demo-provider", "demo-model") != null);
}

test "model registry rejects stream simple registration without an API before persisting it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    var context = DynamicTestSimpleStream.Context{ .provider = "broken" };
    try std.testing.expectError(
        error.DynamicProviderStreamSimpleApiRequired,
        harness.registry.registerProvider("broken-provider", .{
            .stream_simple = DynamicTestSimpleStream.interface(&context),
        }),
    );
    try harness.registry.refresh();
}

test "model registry unregister restores API stream handler after dynamic simple override" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    var builtin = DynamicTestSimpleStream.Context{ .provider = "builtin" };
    try harness.registry.api_registry.register(.{
        .api = ai.types.api.openai_completions,
        .context = &builtin,
        .stream_simple_fn = DynamicTestSimpleStream.stream,
    });
    var dynamic = DynamicTestSimpleStream.Context{ .provider = "dynamic", .fail = true };
    try harness.registry.registerProvider("stream-override-provider", .{
        .api = ai.types.api.openai_completions,
        .stream_simple = DynamicTestSimpleStream.interface(&dynamic),
    });
    const model: ai.Model = .{
        .id = "test",
        .name = "Test",
        .api = ai.types.api.openai_completions,
        .provider = "openai",
        .base_url = "http://localhost",
    };
    try std.testing.expectError(
        error.DynamicSimpleStreamOverride,
        harness.registry.api_registry.streamSimple(model, .{ .messages = &.{} }, null),
    );
    try harness.registry.refresh();
    try std.testing.expectError(
        error.DynamicSimpleStreamOverride,
        harness.registry.api_registry.streamSimple(model, .{ .messages = &.{} }, null),
    );

    try harness.registry.unregisterProvider("stream-override-provider");
    var restored = try harness.registry.api_registry.streamSimple(model, .{ .messages = &.{} }, null);
    defer restored.deinit();
    try std.testing.expectEqualStrings("builtin", restored.message.provider);
    try std.testing.expectEqual(@as(usize, 1), builtin.calls);
}

test "model registry resolves dynamic display names OAuth restoration and legacy uppercase config values" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try env.put("CUSTOM_DYNAMIC_KEY", "legacy-env-key");
    try env.put("CUSTOM_DYNAMIC_HEADER", "legacy-header");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    try std.testing.expectEqualStrings("OpenAI", harness.registry.getProviderDisplayName("openai"));
    try std.testing.expectEqualStrings("GitHub Copilot", harness.registry.getProviderDisplayName("github-copilot"));
    try std.testing.expectEqualStrings("unknown-provider", harness.registry.getProviderDisplayName("unknown-provider"));

    const models = [_]ai.Model{dynamicTestModel("demo-model")};
    const headers = [_]config_value.HeaderInput{.{ .key = "x-legacy", .value = "CUSTOM_DYNAMIC_HEADER" }};
    try harness.registry.registerProvider("named-provider", .{
        .name = "Named Provider",
        .base_url = "https://provider.test/v1",
        .api_key = "CUSTOM_DYNAMIC_KEY",
        .api = "openai-completions",
        .headers = &headers,
        .models = &models,
    });
    try std.testing.expectEqualStrings("Named Provider", harness.registry.getProviderDisplayName("named-provider"));
    const key = (try harness.registry.getApiKeyForProviderAlloc(allocator, "named-provider")).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("legacy-env-key", key);
    const named_model = harness.registry.find("named-provider", "demo-model") orelse return error.ModelMissing;
    var request_auth = try harness.registry.getApiKeyAndHeadersAlloc(allocator, named_model);
    defer request_auth.deinit(allocator);
    switch (request_auth) {
        .ok => |auth| try std.testing.expectEqualStrings("legacy-header", auth.getHeader("x-legacy").?),
        .failure => return error.UnexpectedFailure,
    }

    var oauth_context: u8 = 0;
    try harness.registry.registerProvider("anthropic", .{
        .oauth = DynamicTestOAuth.provider(&oauth_context, "Custom Anthropic OAuth"),
    });
    try std.testing.expectEqualStrings("Custom Anthropic OAuth", harness.registry.getProviderDisplayName("anthropic"));
    try std.testing.expectEqualStrings(
        "Custom Anthropic OAuth",
        harness.oauth_registry.getOAuthProvider("anthropic").?.name,
    );
    try harness.registry.unregisterProvider("anthropic");
    try std.testing.expectEqualStrings(
        "Anthropic (Claude Pro/Max)",
        harness.oauth_registry.getOAuthProvider("anthropic").?.name,
    );
}

test "model registry applies stored OAuth model modifiers during refresh" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    try std.testing.expect(countModelsForProvider(&harness.registry, "github-copilot") > 0);

    var credentials = try ai.oauth.OAuthCredentials.init(
        allocator,
        "refresh",
        "tid=test;exp=9999999999;proxy-ep=proxy.business.githubcopilot.com;",
        123,
    );
    defer credentials.deinit();
    try credentials.putExtra(ai.oauth.enterprise_url_key, "https://company.ghe.com/path");
    try harness.storage.setOAuth("github-copilot", credentials);
    try harness.registry.refresh();

    for (harness.registry.getAll()) |model| {
        if (std.mem.eql(u8, model.provider, "github-copilot")) {
            try std.testing.expectEqualStrings("https://api.business.githubcopilot.com", model.base_url);
        }
    }
}

test "model registry applies dynamic OAuth model modifiers after replacement and refresh" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: TestCommandRunner = .{};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{\"providers\":{}}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try makeTestRegistry(allocator, &env, &runner, path);
    defer harness.deinit();
    var credentials = try ai.oauth.OAuthCredentials.init(allocator, "refresh", "access", 123);
    defer credentials.deinit();
    try harness.storage.setOAuth("oauth-provider", credentials);

    var context = DynamicTestOAuth.ModifierContext{
        .provider = "oauth-provider",
        .base_url = "https://oauth.test/modified",
    };
    const models = [_]ai.Model{dynamicTestModel("oauth-model")};
    try harness.registry.registerProvider("oauth-provider", .{
        .base_url = "https://oauth.test/original",
        .api = "openai-completions",
        .oauth = DynamicTestOAuth.modifyingProvider(&context, "OAuth Provider"),
        .models = &models,
    });
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqualStrings(
        "https://oauth.test/modified",
        harness.registry.find("oauth-provider", "oauth-model").?.base_url,
    );

    try harness.registry.refresh();
    try std.testing.expectEqual(@as(usize, 2), context.calls);
    try std.testing.expectEqualStrings(
        "https://oauth.test/modified",
        harness.registry.find("oauth-provider", "oauth-model").?.base_url,
    );
}

fn countModelsForProvider(registry: *const ModelRegistry, provider: []const u8) usize {
    var count: usize = 0;
    for (registry.getAll()) |model| {
        if (std.mem.eql(u8, model.provider, provider)) count += 1;
    }
    return count;
}
