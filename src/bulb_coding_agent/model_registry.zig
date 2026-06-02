const std = @import("std");
const ai = @import("bulb_ai");
const auth_storage = @import("auth_storage.zig");
const config_value = @import("resolve_config_value.zig");

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
    headers: []const config_value.HeaderInput = &.{},
    auth_header: bool = false,
    models: []const ai.Model = &.{},
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

pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    auth_storage: *auth_storage.AuthStorage,
    models: std.ArrayList(ai.Model) = .empty,
    provider_request_configs: std.StringHashMap(ProviderRequestConfig),
    model_request_headers: std.StringHashMap([]config_value.HeaderInput),
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
        self.clearLoaded();
        self.models.deinit(self.allocator);
        if (self.models_json_path) |path| self.allocator.free(path);
        if (self.load_error) |message| self.allocator.free(message);
        self.provider_request_configs.deinit();
        self.model_request_headers.deinit();
    }

    pub fn refresh(self: *ModelRegistry) !void {
        self.clearLoaded();
        if (self.load_error) |message| {
            self.allocator.free(message);
            self.load_error = null;
        }
        try self.loadModels();
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
        var base_url_overrides = std.StringHashMap([]u8).init(self.allocator);
        defer deinitStringMap(self.allocator, &base_url_overrides);

        var custom_models: std.ArrayList(ai.Model) = .empty;
        defer {
            deinitModelItems(self.allocator, custom_models.items);
            custom_models.deinit(self.allocator);
        }

        if (self.models_json_path) |path| {
            self.loadCustomModels(path, &base_url_overrides, &custom_models) catch |err| {
                deinitModelItems(self.allocator, custom_models.items);
                custom_models.clearRetainingCapacity();
                self.clearRequestConfigMaps();
                try self.setLoadError(@errorName(err));
            };
        }

        try self.loadBuiltInModels(&base_url_overrides);
        try self.mergeCustomModels(custom_models.items);
    }

    fn loadBuiltInModels(
        self: *ModelRegistry,
        base_url_overrides: *const std.StringHashMap([]u8),
    ) !void {
        for (ai.models.allModels()) |model| {
            const override_base_url = base_url_overrides.get(model.provider);
            try self.models.append(self.allocator, try cloneModel(
                self.allocator,
                model,
                override_base_url,
            ));
        }
    }

    fn loadCustomModels(
        self: *ModelRegistry,
        path: []const u8,
        base_url_overrides: *std.StringHashMap([]u8),
        custom_models: *std.ArrayList(ai.Model),
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(max_models_json_bytes)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => |read_error| return read_error,
        };
        defer self.allocator.free(content);

        const stripped = try stripJsonCommentsAlloc(self.allocator, content);
        defer self.allocator.free(stripped);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stripped, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidModelsJson;
        const root = parsed.value.object;
        const providers_value = root.get("providers") orelse return error.InvalidModelsJson;
        if (providers_value != .object) return error.InvalidModelsJson;

        var providers = providers_value.object.iterator();
        while (providers.next()) |entry| {
            if (entry.value_ptr.* != .object) return error.InvalidModelsJson;
            try self.loadProviderConfig(
                entry.key_ptr.*,
                entry.value_ptr.object,
                base_url_overrides,
                custom_models,
            );
        }
    }

    fn loadProviderConfig(
        self: *ModelRegistry,
        provider_name: []const u8,
        object: std.json.ObjectMap,
        base_url_overrides: *std.StringHashMap([]u8),
        custom_models: *std.ArrayList(ai.Model),
    ) !void {
        const base_url = try optionalString(object, "baseUrl");
        const api_key = try optionalString(object, "apiKey");
        const api_name = try optionalString(object, "api");
        const auth_header = try optionalBool(object, "authHeader") orelse false;
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

        if (base_url) |value| try putOwnedString(self.allocator, base_url_overrides, provider_name, value);

        const models_value = object.get("models") orelse return;
        if (models_value != .array) return error.InvalidModelsJson;
        if (!isBuiltInProvider(provider_name) and base_url == null) return error.InvalidModelsJson;
        if (!isBuiltInProvider(provider_name) and api_key == null) return error.InvalidModelsJson;

        for (models_value.array.items) |model_value| {
            if (model_value != .object) return error.InvalidModelsJson;
            var model = try self.parseModelDefinition(provider_name, object, model_value.object, api_name, base_url);
            errdefer deinitModel(self.allocator, &model);
            try custom_models.append(self.allocator, model);
        }
    }

    fn parseModelDefinition(
        self: *ModelRegistry,
        provider_name: []const u8,
        provider_object: std.json.ObjectMap,
        object: std.json.ObjectMap,
        provider_api: ?[]const u8,
        provider_base_url: ?[]const u8,
    ) !ai.Model {
        _ = provider_object;
        const id = try requiredString(object, "id");
        const name = try optionalString(object, "name") orelse id;
        const api_name = (try optionalString(object, "api")) orelse provider_api orelse builtInDefaultApi(provider_name) orelse return error.InvalidModelsJson;
        const base_url = (try optionalString(object, "baseUrl")) orelse provider_base_url orelse builtInDefaultBaseUrl(provider_name) orelse return error.InvalidModelsJson;
        const model_headers = try parseHeadersObjectAlloc(self.allocator, object.get("headers"));
        var model_headers_owned = true;
        errdefer if (model_headers_owned) deinitHeaderInputs(self.allocator, model_headers);

        var model = ai.Model{
            .id = try self.allocator.dupe(u8, id),
            .name = try self.allocator.dupe(u8, name),
            .api = try self.allocator.dupe(u8, api_name),
            .provider = try self.allocator.dupe(u8, provider_name),
            .base_url = try self.allocator.dupe(u8, base_url),
            .reasoning = try optionalBool(object, "reasoning") orelse false,
            .input = try parseInputAlloc(self.allocator, object.get("input")),
            .cost = try parseCost(object.get("cost")),
            .context_window = try optionalU64(object, "contextWindow") orelse 128_000,
            .max_tokens = try optionalU64(object, "maxTokens") orelse 16_384,
            .headers = &.{},
            .compat = .{},
        };
        errdefer deinitModel(self.allocator, &model);

        model_headers_owned = false;
        try self.storeModelHeaders(provider_name, id, model_headers);
        return model;
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

    fn setLoadError(self: *ModelRegistry, message: []const u8) !void {
        if (self.load_error) |previous| self.allocator.free(previous);
        self.load_error = try self.allocator.dupe(u8, message);
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
    return .{
        .id = try allocator.dupe(u8, model.id),
        .name = try allocator.dupe(u8, model.name),
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .base_url = try allocator.dupe(u8, override_base_url orelse model.base_url),
        .reasoning = model.reasoning,
        .thinking_level_map = model.thinking_level_map,
        .input = try cloneStringSlice(allocator, model.input),
        .cost = model.cost,
        .context_window = model.context_window,
        .max_tokens = model.max_tokens,
        .headers = try cloneAiHeaders(allocator, model.headers),
        .compat = model.compat,
    };
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
    deinitStringSlice(allocator, model.input);
    deinitAiHeaders(allocator, model.headers);
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

fn parseInputAlloc(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]const []const u8 {
    const value = maybe_value orelse return cloneStringSlice(allocator, &.{"text"});
    if (value != .array) return error.InvalidModelsJson;
    if (value.array.items.len == 0) return error.InvalidModelsJson;

    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    errdefer deinitStringSlice(allocator, result.items);
    for (value.array.items) |entry| {
        if (entry != .string) return error.InvalidModelsJson;
        try result.append(allocator, try allocator.dupe(u8, entry.string));
    }
    return try result.toOwnedSlice(allocator);
}

fn parseCost(maybe_value: ?std.json.Value) !ai.ModelCost {
    const value = maybe_value orelse return .{};
    if (value != .object) return error.InvalidModelsJson;
    return .{
        .input = try optionalF64(value.object, "input") orelse 0,
        .output = try optionalF64(value.object, "output") orelse 0,
        .cache_read = try optionalF64(value.object, "cacheRead") orelse 0,
        .cache_write = try optionalF64(value.object, "cacheWrite") orelse 0,
    };
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
        else => error.InvalidModelsJson,
    };
}

fn optionalF64(object: std.json.ObjectMap, key: []const u8) !?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => error.InvalidModelsJson,
    };
}

fn stripJsonCommentsAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    var in_string = false;
    var escaped = false;

    while (index < input.len) {
        const character = input[index];
        if (in_string) {
            try output.append(allocator, character);
            if (escaped) {
                escaped = false;
            } else if (character == '\\') {
                escaped = true;
            } else if (character == '"') {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if (character == '"') {
            in_string = true;
            try output.append(allocator, character);
            index += 1;
            continue;
        }

        if (character == '/' and index + 1 < input.len) {
            const next = input[index + 1];
            if (next == '/') {
                index += 2;
                while (index < input.len and input[index] != '\n') : (index += 1) {}
                if (index < input.len) try output.append(allocator, input[index]);
                index += 1;
                continue;
            }
            if (next == '*') {
                index += 2;
                while (index + 1 < input.len and !(input[index] == '*' and input[index + 1] == '/')) {
                    if (input[index] == '\n') try output.append(allocator, '\n');
                    index += 1;
                }
                index = @min(index + 2, input.len);
                continue;
            }
        }

        try output.append(allocator, character);
        index += 1;
    }

    return try output.toOwnedSlice(allocator);
}

fn modelRequestKeyAlloc(allocator: std.mem.Allocator, provider: []const u8, model_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ provider, model_id });
}

fn putOwnedString(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]u8),
    key_value: []const u8,
    value: []const u8,
) !void {
    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);
    if (map.getPtr(key_value)) |existing| {
        allocator.free(existing.*);
        existing.* = value_copy;
        return;
    }
    const key_copy = try allocator.dupe(u8, key_value);
    errdefer allocator.free(key_copy);
    try map.put(key_copy, value_copy);
}

fn deinitStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
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
