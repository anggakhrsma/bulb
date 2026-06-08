const std = @import("std");

const ai = @import("bulb_ai");
const auth_storage = @import("auth_storage.zig");
const config = @import("config.zig");
const config_value = @import("resolve_config_value.zig");
const extensions = @import("extensions/root.zig");
const model_registry = @import("model_registry.zig");
const paths = @import("paths.zig");
const resource_loader = @import("resource_loader.zig");
const settings_manager = @import("settings_manager.zig");
const source_info = @import("source_info.zig");

pub const AgentSessionRuntimeDiagnosticType = enum {
    info,
    warning,
    @"error",
};

pub const AgentSessionRuntimeDiagnostic = struct {
    type: AgentSessionRuntimeDiagnosticType,
    message: []u8,
};

pub const ExtensionFlagInput = struct {
    name: []const u8,
    value: extensions.types.FlagValue,
};

pub const CreateAgentSessionServicesOptions = struct {
    cwd: []const u8,
    agent_dir: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    auth_storage: ?*auth_storage.AuthStorage = null,
    settings_manager: ?*settings_manager.SettingsManager = null,
    model_registry: ?*model_registry.ModelRegistry = null,
    resource_loader_options: ResourceLoaderOptions = .{},
    extension_flag_values: []const ExtensionFlagInput = &.{},
    extension_runtime: ?*extensions.loader.ExtensionRuntimeController = null,
    extension_snapshot: []const extensions.Extension = &.{},
};

pub const ResourceLoaderOptions = struct {
    additional_extension_paths: []const []const u8 = &.{},
    additional_skill_paths: []const []const u8 = &.{},
    additional_prompt_template_paths: []const []const u8 = &.{},
    additional_theme_paths: []const []const u8 = &.{},
    no_extensions: bool = false,
    no_skills: bool = false,
    no_prompt_templates: bool = false,
    no_themes: bool = false,
    no_context_files: bool = false,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const []const u8 = null,

    fn toResourceLoaderOptions(
        self: ResourceLoaderOptions,
        cwd: []const u8,
        agent_dir: []const u8,
        manager: *settings_manager.SettingsManager,
    ) resource_loader.DefaultResourceLoaderOptions {
        return .{
            .cwd = cwd,
            .agent_dir = agent_dir,
            .settings_manager = manager,
            .additional_extension_paths = self.additional_extension_paths,
            .additional_skill_paths = self.additional_skill_paths,
            .additional_prompt_template_paths = self.additional_prompt_template_paths,
            .additional_theme_paths = self.additional_theme_paths,
            .no_extensions = self.no_extensions,
            .no_skills = self.no_skills,
            .no_prompt_templates = self.no_prompt_templates,
            .no_themes = self.no_themes,
            .no_context_files = self.no_context_files,
            .system_prompt = self.system_prompt,
            .append_system_prompt = self.append_system_prompt,
        };
    }
};

pub const AgentSessionServices = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
    agent_dir: []u8,
    env: *const std.process.Environ.Map,
    auth_storage: *auth_storage.AuthStorage,
    settings_manager: *settings_manager.SettingsManager,
    model_registry: *model_registry.ModelRegistry,
    resource_loader: resource_loader.DefaultResourceLoader,
    diagnostics: []AgentSessionRuntimeDiagnostic,
    owned_env: ?*std.process.Environ.Map = null,
    owned_oauth_registry: ?*ai.oauth.Registry = null,
    owned_config_resolver: ?*config_value.Resolver = null,
    owns_auth_storage: bool = false,
    owns_settings_manager: bool = false,
    owns_model_registry: bool = false,

    pub fn deinit(self: *AgentSessionServices) void {
        self.resource_loader.deinit();
        deinitDiagnostics(self.allocator, self.diagnostics);
        if (self.owns_model_registry) {
            self.model_registry.deinit();
            self.allocator.destroy(self.model_registry);
        }
        if (self.owns_settings_manager) {
            self.settings_manager.deinit();
            self.allocator.destroy(self.settings_manager);
        }
        if (self.owns_auth_storage) {
            self.auth_storage.deinit();
            self.allocator.destroy(self.auth_storage);
        }
        if (self.owned_config_resolver) |resolver| {
            resolver.deinit();
            self.allocator.destroy(resolver);
        }
        if (self.owned_oauth_registry) |registry| {
            registry.deinit();
            self.allocator.destroy(registry);
        }
        if (self.owned_env) |env| {
            env.deinit();
            self.allocator.destroy(env);
        }
        self.allocator.free(self.cwd);
        self.allocator.free(self.agent_dir);
        self.* = undefined;
    }
};

pub fn createAgentSessionServicesAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: CreateAgentSessionServicesOptions,
) !AgentSessionServices {
    const env = try resolveEnvironment(allocator, options.env);
    errdefer if (env.owned) |owned_env| {
        owned_env.deinit();
        allocator.destroy(owned_env);
    };

    const resolved_cwd = try paths.resolvePathAlloc(allocator, options.cwd, ".", .{});
    errdefer allocator.free(resolved_cwd);

    const resolved_agent_dir = try resolveAgentDirAlloc(allocator, options.agent_dir, env.ptr);
    errdefer allocator.free(resolved_agent_dir);

    const oauth_registry = try resolveOAuthRegistry(allocator, options.auth_storage);
    errdefer if (oauth_registry.owned) |owned_registry| {
        owned_registry.deinit();
        allocator.destroy(owned_registry);
    };

    const resolver = try resolveConfigResolver(allocator, options.auth_storage, env.ptr);
    errdefer if (resolver.owned) |owned_resolver| {
        owned_resolver.deinit();
        allocator.destroy(owned_resolver);
    };

    const auth = try resolveAuthStorage(allocator, options.auth_storage, env.ptr, oauth_registry.ptr, resolver.ptr);
    errdefer if (auth.owned) |owned_auth| {
        owned_auth.deinit();
        allocator.destroy(owned_auth);
    };

    const settings = try resolveSettingsManager(allocator, io, options.settings_manager, resolved_cwd, resolved_agent_dir);
    errdefer if (settings.owned) |owned_settings| {
        owned_settings.deinit();
        allocator.destroy(owned_settings);
    };

    const registry = try resolveModelRegistry(allocator, options.model_registry, auth.ptr, resolved_agent_dir);
    errdefer if (registry.owned) |owned_registry| {
        owned_registry.deinit();
        allocator.destroy(owned_registry);
    };

    var loader = try resource_loader.DefaultResourceLoader.initAlloc(
        allocator,
        io,
        options.resource_loader_options.toResourceLoaderOptions(resolved_cwd, resolved_agent_dir, settings.ptr),
    );
    errdefer loader.deinit();

    try loader.reload();

    var diagnostics: std.ArrayList(AgentSessionRuntimeDiagnostic) = .empty;
    errdefer {
        deinitDiagnosticMessages(allocator, diagnostics.items);
        diagnostics.deinit(allocator);
    }

    if (options.extension_runtime) |runtime| {
        try applyPendingProviderRegistrations(allocator, registry.ptr, runtime, &diagnostics);
        try applyExtensionFlagValues(allocator, runtime, options.extension_snapshot, options.extension_flag_values, &diagnostics);
    } else if (options.extension_flag_values.len > 0) {
        try appendUnknownFlagDiagnostics(allocator, options.extension_flag_values, &diagnostics);
    }

    return .{
        .allocator = allocator,
        .io = io,
        .cwd = resolved_cwd,
        .agent_dir = resolved_agent_dir,
        .env = env.ptr,
        .auth_storage = auth.ptr,
        .settings_manager = settings.ptr,
        .model_registry = registry.ptr,
        .resource_loader = loader,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .owned_env = env.owned,
        .owned_oauth_registry = oauth_registry.owned,
        .owned_config_resolver = resolver.owned,
        .owns_auth_storage = auth.owned != null,
        .owns_settings_manager = settings.owned != null,
        .owns_model_registry = registry.owned != null,
    };
}

const EnvironmentRef = struct {
    ptr: *const std.process.Environ.Map,
    owned: ?*std.process.Environ.Map = null,
};

fn resolveEnvironment(allocator: std.mem.Allocator, injected: ?*const std.process.Environ.Map) !EnvironmentRef {
    if (injected) |env| return .{ .ptr = env };
    const owned = try allocator.create(std.process.Environ.Map);
    errdefer allocator.destroy(owned);
    owned.* = std.process.Environ.Map.init(allocator);
    return .{ .ptr = owned, .owned = owned };
}

fn resolveAgentDirAlloc(
    allocator: std.mem.Allocator,
    configured: ?[]const u8,
    env: *const std.process.Environ.Map,
) ![]u8 {
    const raw = if (configured) |agent_dir|
        try allocator.dupe(u8, agent_dir)
    else
        try config.agentDirAlloc(allocator, env);
    defer allocator.free(raw);
    return paths.resolvePathAlloc(allocator, raw, ".", .{});
}

const OAuthRegistryRef = struct {
    ptr: *ai.oauth.Registry,
    owned: ?*ai.oauth.Registry = null,
};

fn resolveOAuthRegistry(
    allocator: std.mem.Allocator,
    injected_auth: ?*auth_storage.AuthStorage,
) !OAuthRegistryRef {
    if (injected_auth) |auth| return .{ .ptr = auth.oauth_registry };
    const registry = try allocator.create(ai.oauth.Registry);
    errdefer allocator.destroy(registry);
    registry.* = try ai.oauth.Registry.init(allocator);
    return .{ .ptr = registry, .owned = registry };
}

const ConfigResolverRef = struct {
    ptr: *config_value.Resolver,
    owned: ?*config_value.Resolver = null,
};

fn resolveConfigResolver(
    allocator: std.mem.Allocator,
    injected_auth: ?*auth_storage.AuthStorage,
    env: *const std.process.Environ.Map,
) !ConfigResolverRef {
    if (injected_auth) |auth| return .{ .ptr = auth.config_resolver };
    const resolver = try allocator.create(config_value.Resolver);
    errdefer allocator.destroy(resolver);
    resolver.* = config_value.Resolver.init(allocator, env);
    return .{ .ptr = resolver, .owned = resolver };
}

const AuthStorageRef = struct {
    ptr: *auth_storage.AuthStorage,
    owned: ?*auth_storage.AuthStorage = null,
};

fn resolveAuthStorage(
    allocator: std.mem.Allocator,
    injected: ?*auth_storage.AuthStorage,
    env: *const std.process.Environ.Map,
    oauth_registry: *ai.oauth.Registry,
    resolver: *config_value.Resolver,
) !AuthStorageRef {
    if (injected) |auth| return .{ .ptr = auth };
    const auth = try allocator.create(auth_storage.AuthStorage);
    errdefer allocator.destroy(auth);
    auth.* = try auth_storage.AuthStorage.initMemory(allocator, env, oauth_registry, resolver);
    return .{ .ptr = auth, .owned = auth };
}

const SettingsManagerRef = struct {
    ptr: *settings_manager.SettingsManager,
    owned: ?*settings_manager.SettingsManager = null,
};

fn resolveSettingsManager(
    allocator: std.mem.Allocator,
    io: std.Io,
    injected: ?*settings_manager.SettingsManager,
    cwd: []const u8,
    agent_dir: []const u8,
) !SettingsManagerRef {
    if (injected) |manager| return .{ .ptr = manager };
    const manager = try allocator.create(settings_manager.SettingsManager);
    errdefer allocator.destroy(manager);
    manager.* = try settings_manager.SettingsManager.create(allocator, io, cwd, agent_dir);
    return .{ .ptr = manager, .owned = manager };
}

const ModelRegistryRef = struct {
    ptr: *model_registry.ModelRegistry,
    owned: ?*model_registry.ModelRegistry = null,
};

fn resolveModelRegistry(
    allocator: std.mem.Allocator,
    injected: ?*model_registry.ModelRegistry,
    auth: *auth_storage.AuthStorage,
    agent_dir: []const u8,
) !ModelRegistryRef {
    if (injected) |registry| return .{ .ptr = registry };
    const models_json_path = try std.fs.path.join(allocator, &.{ agent_dir, "models.json" });
    defer allocator.free(models_json_path);
    const registry = try allocator.create(model_registry.ModelRegistry);
    errdefer allocator.destroy(registry);
    registry.* = try model_registry.ModelRegistry.init(allocator, auth, models_json_path);
    return .{ .ptr = registry, .owned = registry };
}

fn applyPendingProviderRegistrations(
    allocator: std.mem.Allocator,
    registry: *model_registry.ModelRegistry,
    runtime: *extensions.loader.ExtensionRuntimeController,
    diagnostics: *std.ArrayList(AgentSessionRuntimeDiagnostic),
) !void {
    while (runtime.pending_provider_registrations.items.len > 0) {
        const registration = &runtime.pending_provider_registrations.items[0];
        var converted = providerConfigInputAlloc(allocator, registration.name, registration.config) catch |err| {
            try appendProviderDiagnostic(allocator, diagnostics, registration.name, registration.extension_path, err);
            deinitPendingProviderRegistration(allocator, registration);
            _ = runtime.pending_provider_registrations.orderedRemove(0);
            continue;
        };
        defer converted.deinit();
        registry.registerProvider(registration.name, converted.input) catch |err| {
            try appendProviderDiagnostic(allocator, diagnostics, registration.name, registration.extension_path, err);
        };
        deinitPendingProviderRegistration(allocator, registration);
        _ = runtime.pending_provider_registrations.orderedRemove(0);
    }
}

fn deinitPendingProviderRegistration(
    allocator: std.mem.Allocator,
    registration: *extensions.types.PendingProviderRegistration,
) void {
    allocator.free(registration.name);
    allocator.free(registration.extension_path);
    registration.* = undefined;
}

const ConvertedProviderConfigInput = struct {
    allocator: std.mem.Allocator,
    headers: []config_value.HeaderInput = &.{},
    models: []ai.Model = &.{},
    input: model_registry.ProviderConfigInput,

    fn deinit(self: *ConvertedProviderConfigInput) void {
        if (self.headers.len > 0) self.allocator.free(self.headers);
        if (self.models.len > 0) self.allocator.free(self.models);
        self.* = undefined;
    }
};

fn providerConfigInputAlloc(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    provider_config: extensions.ProviderConfig,
) !ConvertedProviderConfigInput {
    const headers = try allocator.alloc(config_value.HeaderInput, provider_config.headers.len);
    errdefer allocator.free(headers);
    for (provider_config.headers, 0..) |header, index| {
        headers[index] = .{ .key = header.name, .value = header.value };
    }

    const models = try allocator.alloc(ai.Model, provider_config.models.len);
    errdefer allocator.free(models);
    for (provider_config.models, 0..) |model, index| {
        models[index] = .{
            .id = model.id,
            .name = model.name,
            .api = model.api orelse provider_config.api orelse "",
            .provider = provider_name,
            .base_url = model.base_url orelse provider_config.base_url orelse "",
            .reasoning = model.reasoning,
            .thinking_level_map = model.thinking_level_map orelse .{},
            .input = model.input,
            .cost = model.cost,
            .context_window = model.context_window,
            .max_tokens = model.max_tokens,
            .headers = model.headers,
            .compat = model.compat orelse .{},
        };
    }

    return .{
        .allocator = allocator,
        .headers = headers,
        .models = models,
        .input = .{
            .name = provider_config.name,
            .base_url = provider_config.base_url,
            .api_key = provider_config.api_key,
            .api = provider_config.api,
            .headers = headers,
            .auth_header = provider_config.auth_header,
            .oauth = provider_config.oauth,
            .stream_simple = provider_config.stream_simple,
            .models = models,
        },
    };
}

fn appendProviderDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(AgentSessionRuntimeDiagnostic),
    provider_name: []const u8,
    extension_path: []const u8,
    err: anyerror,
) !void {
    const message = try providerErrorMessageAlloc(allocator, provider_name, err);
    defer allocator.free(message);
    try appendDiagnostic(
        allocator,
        diagnostics,
        .@"error",
        try std.fmt.allocPrint(allocator, "Extension \"{s}\" error: {s}", .{ extension_path, message }),
    );
}

fn providerErrorMessageAlloc(allocator: std.mem.Allocator, provider_name: []const u8, err: anyerror) ![]u8 {
    return switch (err) {
        error.DynamicProviderStreamSimpleApiRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"api\" is required when registering streamSimple.",
            .{provider_name},
        ),
        error.DynamicProviderBaseUrlRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"baseUrl\" is required when registering models.",
            .{provider_name},
        ),
        error.DynamicProviderAuthRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"apiKey\" or \"oauth\" is required when registering models.",
            .{provider_name},
        ),
        error.DynamicProviderApiRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"api\" is required when registering models without per-model APIs.",
            .{provider_name},
        ),
        else => try std.fmt.allocPrint(allocator, "Provider {s}: {s}", .{ provider_name, @errorName(err) }),
    };
}

fn applyExtensionFlagValues(
    allocator: std.mem.Allocator,
    runtime: *extensions.loader.ExtensionRuntimeController,
    extension_snapshot: []const extensions.Extension,
    flag_values: []const ExtensionFlagInput,
    diagnostics: *std.ArrayList(AgentSessionRuntimeDiagnostic),
) !void {
    for (flag_values) |input| {
        const flag = findExtensionFlag(extension_snapshot, input.name) orelse {
            try appendUnknownFlagDiagnostic(allocator, input.name, diagnostics);
            continue;
        };
        switch (flag.type) {
            .boolean => try runtime.setFlagValue(input.name, .{ .boolean = true }),
            .string => switch (input.value) {
                .string => |value| try runtime.setFlagValue(input.name, .{ .string = value }),
                .boolean => try appendDiagnostic(
                    allocator,
                    diagnostics,
                    .@"error",
                    try std.fmt.allocPrint(allocator, "Extension flag \"--{s}\" requires a value", .{input.name}),
                ),
            },
        }
    }
}

fn findExtensionFlag(extension_snapshot: []const extensions.Extension, name: []const u8) ?extensions.ExtensionFlag {
    for (extension_snapshot) |extension| {
        for (extension.flags) |flag| {
            if (std.mem.eql(u8, flag.name, name)) return flag;
        }
    }
    return null;
}

fn appendUnknownFlagDiagnostics(
    allocator: std.mem.Allocator,
    flag_values: []const ExtensionFlagInput,
    diagnostics: *std.ArrayList(AgentSessionRuntimeDiagnostic),
) !void {
    for (flag_values) |input| try appendUnknownFlagDiagnostic(allocator, input.name, diagnostics);
}

fn appendUnknownFlagDiagnostic(
    allocator: std.mem.Allocator,
    name: []const u8,
    diagnostics: *std.ArrayList(AgentSessionRuntimeDiagnostic),
) !void {
    try appendDiagnostic(
        allocator,
        diagnostics,
        .@"error",
        try std.fmt.allocPrint(allocator, "Unknown option: --{s}", .{name}),
    );
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(AgentSessionRuntimeDiagnostic),
    diagnostic_type: AgentSessionRuntimeDiagnosticType,
    owned_message: []u8,
) !void {
    errdefer allocator.free(owned_message);
    try diagnostics.append(allocator, .{
        .type = diagnostic_type,
        .message = owned_message,
    });
}

fn deinitDiagnostics(allocator: std.mem.Allocator, diagnostics: []AgentSessionRuntimeDiagnostic) void {
    deinitDiagnosticMessages(allocator, diagnostics);
    allocator.free(diagnostics);
}

fn deinitDiagnosticMessages(allocator: std.mem.Allocator, diagnostics: []AgentSessionRuntimeDiagnostic) void {
    for (diagnostics) |diagnostic| allocator.free(diagnostic.message);
}

fn expectDiagnostic(
    diagnostics: []const AgentSessionRuntimeDiagnostic,
    diagnostic_type: AgentSessionRuntimeDiagnosticType,
    message: []const u8,
) !void {
    for (diagnostics) |diagnostic| {
        if (diagnostic.type == diagnostic_type and std.mem.eql(u8, diagnostic.message, message)) return;
    }
    return error.ExpectedDiagnosticMissing;
}

fn testEnv(allocator: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    errdefer env.deinit();
    try env.put("HOME", home);
    return env;
}

fn testExtension(path: []const u8, flags: []const extensions.ExtensionFlag) extensions.Extension {
    return .{
        .path = path,
        .resolved_path = path,
        .source_info = source_info.createSyntheticSourceInfo(path, .{ .source = "test" }),
        .flags = flags,
    };
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "createAgentSessionServices owns cwd-bound services and resolves Bulb agent dir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);

    var env = try testEnv(allocator, cwd);
    defer env.deinit();
    const agent_dir = try std.fs.path.join(allocator, &.{ cwd, "agent-home" });
    defer allocator.free(agent_dir);
    try env.put(config.agent_dir_env, agent_dir);

    var services = try createAgentSessionServicesAlloc(allocator, io, .{
        .cwd = cwd,
        .env = &env,
        .resource_loader_options = .{
            .no_extensions = true,
            .no_skills = true,
            .no_prompt_templates = true,
            .no_themes = true,
            .no_context_files = true,
        },
    });
    defer services.deinit();

    try std.testing.expectEqualStrings(cwd, services.cwd);
    try std.testing.expectEqualStrings(agent_dir, services.agent_dir);
    try std.testing.expectEqualStrings(cwd, services.settings_manager.cwd);
    try std.testing.expectEqualStrings(agent_dir, services.settings_manager.agent_dir);
    try std.testing.expect(services.owns_auth_storage);
    try std.testing.expect(services.owns_settings_manager);
    try std.testing.expect(services.owns_model_registry);
    try std.testing.expectEqual(@as(usize, 0), services.diagnostics.len);
}

test "createAgentSessionServices applies extension flag values and reports unknown flags" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);
    var env = try testEnv(allocator, cwd);
    defer env.deinit();

    var runtime = extensions.createExtensionRuntime(allocator);
    defer runtime.deinit();

    const flags = [_]extensions.ExtensionFlag{
        .{
            .name = "trace",
            .description = "Enable tracing",
            .type = .boolean,
            .extension_path = "/tmp/extension.zig",
        },
        .{
            .name = "label",
            .description = "Set label",
            .type = .string,
            .extension_path = "/tmp/extension.zig",
        },
    };
    const extension_snapshot = [_]extensions.Extension{testExtension("/tmp/extension.zig", &flags)};
    const input_flags = [_]ExtensionFlagInput{
        .{ .name = "trace", .value = .{ .boolean = true } },
        .{ .name = "label", .value = .{ .string = "nightly" } },
        .{ .name = "missing", .value = .{ .boolean = true } },
    };

    var services = try createAgentSessionServicesAlloc(allocator, io, .{
        .cwd = cwd,
        .agent_dir = cwd,
        .env = &env,
        .resource_loader_options = .{
            .no_extensions = true,
            .no_skills = true,
            .no_prompt_templates = true,
            .no_themes = true,
            .no_context_files = true,
        },
        .extension_runtime = &runtime,
        .extension_snapshot = &extension_snapshot,
        .extension_flag_values = &input_flags,
    });
    defer services.deinit();

    try std.testing.expectEqual(true, runtime.getFlag("trace").?.boolean);
    try std.testing.expectEqualStrings("nightly", runtime.getFlag("label").?.string);
    try expectDiagnostic(services.diagnostics, .@"error", "Unknown option: --missing");
}

test "createAgentSessionServices flushes queued extension provider registrations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);
    var env = try testEnv(allocator, cwd);
    defer env.deinit();

    var runtime = extensions.createExtensionRuntime(allocator);
    defer runtime.deinit();

    const provider_models = [_]extensions.ProviderModelConfig{.{
        .id = "instant-model",
        .name = "Instant Model",
        .api = "openai-completions",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{},
        .context_window = 128_000,
        .max_tokens = 4096,
    }};
    try runtime.registerProvider("instant-provider", .{
        .base_url = "https://provider.test/v1",
        .api_key = "provider-test-key",
        .api = "openai-completions",
        .models = &provider_models,
    }, "/tmp/provider.zig");
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_provider_registrations.items.len);

    var services = try createAgentSessionServicesAlloc(allocator, io, .{
        .cwd = cwd,
        .agent_dir = cwd,
        .env = &env,
        .resource_loader_options = .{
            .no_extensions = true,
            .no_skills = true,
            .no_prompt_templates = true,
            .no_themes = true,
            .no_context_files = true,
        },
        .extension_runtime = &runtime,
    });
    defer services.deinit();

    try std.testing.expectEqual(@as(usize, 0), runtime.pending_provider_registrations.items.len);
    try std.testing.expect(services.model_registry.find("instant-provider", "instant-model") != null);
    try std.testing.expectEqual(@as(usize, 0), services.diagnostics.len);
}

test "createAgentSessionServices reports missing string flag values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);
    var env = try testEnv(allocator, cwd);
    defer env.deinit();

    var runtime = extensions.createExtensionRuntime(allocator);
    defer runtime.deinit();

    const flags = [_]extensions.ExtensionFlag{.{
        .name = "label",
        .type = .string,
        .extension_path = "/tmp/extension.zig",
    }};
    const extension_snapshot = [_]extensions.Extension{testExtension("/tmp/extension.zig", &flags)};
    const input_flags = [_]ExtensionFlagInput{.{ .name = "label", .value = .{ .boolean = true } }};

    var services = try createAgentSessionServicesAlloc(allocator, io, .{
        .cwd = cwd,
        .agent_dir = cwd,
        .env = &env,
        .resource_loader_options = .{
            .no_extensions = true,
            .no_skills = true,
            .no_prompt_templates = true,
            .no_themes = true,
            .no_context_files = true,
        },
        .extension_runtime = &runtime,
        .extension_snapshot = &extension_snapshot,
        .extension_flag_values = &input_flags,
    });
    defer services.deinit();

    try std.testing.expectEqual(@as(?extensions.types.FlagValue, null), runtime.getFlag("label"));
    try expectDiagnostic(services.diagnostics, .@"error", "Extension flag \"--label\" requires a value");
}
