const std = @import("std");

const ai = @import("bulb_ai");
const event_bus_mod = @import("../event_bus.zig");
const messages = @import("../messages.zig");
const paths = @import("../paths.zig");
const source_info = @import("../source_info.zig");
const types = @import("types.zig");

const default_stale_message =
    "This extension ctx is stale after session replacement or reload. Do not use a captured Bulb ctx after session replacement or reload.";

pub const ExtensionRuntimeController = struct {
    allocator: std.mem.Allocator,
    actions: types.ExtensionActions = .{},
    provider_actions: ProviderActions = .{},
    flag_values: std.ArrayList(types.FlagEntry) = .empty,
    pending_provider_registrations: std.ArrayList(types.PendingProviderRegistration) = .empty,
    stale_message: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) ExtensionRuntimeController {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExtensionRuntimeController) void {
        for (self.flag_values.items) |*entry| deinitFlagEntry(self.allocator, entry);
        self.flag_values.deinit(self.allocator);
        for (self.pending_provider_registrations.items) |*registration| deinitPendingProviderRegistration(self.allocator, registration);
        self.pending_provider_registrations.deinit(self.allocator);
        if (self.stale_message) |message| self.allocator.free(message);
        self.* = undefined;
    }

    pub fn asRuntime(self: *ExtensionRuntimeController) types.ExtensionRuntime {
        return .{
            .state = .{
                .flag_values = self.flag_values.items,
                .pending_provider_registrations = self.pending_provider_registrations.items,
                .ptr = self,
                .assert_active_fn = assertActiveBridge,
                .invalidate_fn = invalidateBridge,
                .register_provider = .{ .ptr = self, .call_fn = registerProviderBridge },
                .unregister_provider = .{ .ptr = self, .call_fn = unregisterProviderBridge },
            },
            .actions = self.actions,
        };
    }

    pub fn assertActive(self: *ExtensionRuntimeController) !void {
        if (self.stale_message != null) return error.ExtensionContextStale;
    }

    pub fn invalidate(self: *ExtensionRuntimeController, message: ?[]const u8) void {
        if (self.stale_message != null) return;
        self.stale_message = self.allocator.dupe(u8, message orelse default_stale_message) catch null;
    }

    pub fn staleMessage(self: *const ExtensionRuntimeController) ?[]const u8 {
        return self.stale_message;
    }

    pub fn bindActions(self: *ExtensionRuntimeController, actions: types.ExtensionActions) void {
        self.actions = actions;
    }

    pub fn bindProviderActions(self: *ExtensionRuntimeController, provider_actions: ProviderActions) !void {
        self.provider_actions = provider_actions;
        while (self.pending_provider_registrations.items.len > 0) {
            const registration = &self.pending_provider_registrations.items[0];
            try self.registerProvider(registration.name, registration.config, registration.extension_path);
            deinitPendingProviderRegistration(self.allocator, registration);
            _ = self.pending_provider_registrations.orderedRemove(0);
        }
    }

    pub fn bindProviderActionsReporting(
        self: *ExtensionRuntimeController,
        provider_actions: ProviderActions,
        error_handler: ProviderRegistrationErrorHandler,
    ) void {
        self.provider_actions = provider_actions;
        while (self.pending_provider_registrations.items.len > 0) {
            const registration = &self.pending_provider_registrations.items[0];
            self.registerProvider(registration.name, registration.config, registration.extension_path) catch |err| {
                error_handler.call(registration.name, registration.extension_path, err);
            };
            deinitPendingProviderRegistration(self.allocator, registration);
            _ = self.pending_provider_registrations.orderedRemove(0);
        }
    }

    pub fn registerProvider(
        self: *ExtensionRuntimeController,
        name: []const u8,
        config: types.ProviderConfig,
        extension_path: []const u8,
    ) !void {
        try self.assertActive();
        if (self.provider_actions.register_provider) |handler| {
            return handler.call(name, config);
        }
        try self.pending_provider_registrations.append(
            self.allocator,
            try pendingProviderRegistrationAlloc(self.allocator, name, config, extension_path),
        );
    }

    pub fn unregisterProvider(self: *ExtensionRuntimeController, name: []const u8) !void {
        try self.assertActive();
        if (self.provider_actions.unregister_provider) |handler| {
            return handler.call(name);
        }
        var index: usize = 0;
        while (index < self.pending_provider_registrations.items.len) {
            if (std.mem.eql(u8, self.pending_provider_registrations.items[index].name, name)) {
                deinitPendingProviderRegistration(self.allocator, &self.pending_provider_registrations.items[index]);
                _ = self.pending_provider_registrations.orderedRemove(index);
                continue;
            }
            index += 1;
        }
    }

    fn refreshTools(self: *ExtensionRuntimeController) !void {
        try self.assertActive();
        if (self.actions.refresh_tools) |handler| try handler.call();
    }

    pub fn getFlag(self: *const ExtensionRuntimeController, name: []const u8) ?types.FlagValue {
        for (self.flag_values.items) |entry| {
            if (std.mem.eql(u8, name, entry.name)) return entry.value;
        }
        return null;
    }

    pub fn setDefaultFlag(self: *ExtensionRuntimeController, name: []const u8, value: types.FlagValue) !void {
        if (self.getFlag(name) != null) return;
        try self.flag_values.append(self.allocator, try flagEntryAlloc(self.allocator, name, value));
    }

    pub fn setFlagValue(self: *ExtensionRuntimeController, name: []const u8, value: types.FlagValue) !void {
        for (self.flag_values.items) |*entry| {
            if (!std.mem.eql(u8, name, entry.name)) continue;
            switch (entry.value) {
                .boolean => {},
                .string => |string| self.allocator.free(string),
            }
            entry.value = try cloneFlagValueAlloc(self.allocator, value);
            return;
        }
        try self.flag_values.append(self.allocator, try flagEntryAlloc(self.allocator, name, value));
    }
};

pub const ProviderActions = struct {
    register_provider: ?types.RegisterProviderHandler = null,
    unregister_provider: ?types.UnregisterProviderHandler = null,
};

pub const ProviderRegistrationErrorHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8, []const u8, anyerror) void,

    pub fn call(self: ProviderRegistrationErrorHandler, name: []const u8, extension_path: []const u8, err: anyerror) void {
        self.call_fn(self.ptr, name, extension_path, err);
    }
};

pub fn createExtensionRuntime(allocator: std.mem.Allocator) ExtensionRuntimeController {
    return ExtensionRuntimeController.init(allocator);
}

pub const LoadedNativeExtension = struct {
    arena: std.heap.ArenaAllocator,
    extension: types.Extension,

    pub fn deinit(self: *LoadedNativeExtension) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ExtensionBuilder = struct {
    arena: std.heap.ArenaAllocator,
    runtime: *ExtensionRuntimeController,
    event_bus: types.EventBus,
    extension_path: []const u8,
    resolved_path: []const u8,
    cwd: []const u8,
    extension_source_info: types.SourceInfo,
    handlers: std.ArrayList(types.ExtensionHandler) = .empty,
    tools: std.ArrayList(types.RegisteredTool) = .empty,
    message_renderers: std.ArrayList(types.MessageRendererRegistration) = .empty,
    commands: std.ArrayList(types.RegisteredCommand) = .empty,
    flags: std.ArrayList(types.ExtensionFlag) = .empty,
    shortcuts: std.ArrayList(types.ExtensionShortcut) = .empty,
    finished: bool = false,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        extension_path: []const u8,
        resolved_path: []const u8,
        cwd: []const u8,
        runtime: *ExtensionRuntimeController,
        event_bus: types.EventBus,
    ) !ExtensionBuilder {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const owned_extension_path = try arena_allocator.dupe(u8, extension_path);
        const owned_resolved_path = try arena_allocator.dupe(u8, resolved_path);
        const owned_cwd = try arena_allocator.dupe(u8, cwd);
        const info = try createExtensionSourceInfoAlloc(arena_allocator, owned_extension_path, owned_resolved_path);

        return .{
            .arena = arena,
            .runtime = runtime,
            .event_bus = event_bus,
            .extension_path = owned_extension_path,
            .resolved_path = owned_resolved_path,
            .cwd = owned_cwd,
            .extension_source_info = info,
        };
    }

    pub fn deinit(self: *ExtensionBuilder) void {
        if (!self.finished) self.arena.deinit();
        self.* = undefined;
    }

    pub fn api(self: *ExtensionBuilder) types.ExtensionAPI {
        return .{
            .ptr = self,
            .on_fn = apiOn,
            .register_tool_fn = apiRegisterTool,
            .register_command_fn = apiRegisterCommand,
            .register_shortcut_fn = apiRegisterShortcut,
            .register_flag_fn = apiRegisterFlag,
            .get_flag_fn = apiGetFlag,
            .register_message_renderer_fn = apiRegisterMessageRenderer,
            .send_message_fn = .{ .ptr = self, .call_fn = apiSendMessage },
            .send_user_message_fn = .{ .ptr = self, .call_fn = apiSendUserMessage },
            .append_entry_fn = .{ .ptr = self, .call_fn = apiAppendEntry },
            .set_session_name_fn = .{ .ptr = self, .call_fn = apiSetSessionName },
            .get_session_name_fn = .{ .ptr = self, .call_fn = apiGetSessionName },
            .set_label_fn = .{ .ptr = self, .call_fn = apiSetLabel },
            .exec_fn = .{ .ptr = self, .call_fn = apiExec },
            .get_active_tools_fn = .{ .ptr = self, .call_fn = apiGetActiveTools },
            .get_all_tools_fn = .{ .ptr = self, .call_fn = apiGetAllTools },
            .set_active_tools_fn = .{ .ptr = self, .call_fn = apiSetActiveTools },
            .get_commands_fn = .{ .ptr = self, .call_fn = apiGetCommands },
            .set_model_fn = .{ .ptr = self, .call_fn = apiSetModel },
            .get_thinking_level_fn = .{ .ptr = self, .call_fn = apiGetThinkingLevel },
            .set_thinking_level_fn = .{ .ptr = self, .call_fn = apiSetThinkingLevel },
            .register_provider_fn = .{ .ptr = self, .call_fn = apiRegisterProvider },
            .unregister_provider_fn = .{ .ptr = self, .call_fn = apiUnregisterProvider },
            .events = &self.event_bus,
        };
    }

    pub fn finish(self: *ExtensionBuilder) !LoadedNativeExtension {
        const allocator = self.arena.allocator();
        const extension = types.Extension{
            .path = self.extension_path,
            .resolved_path = self.resolved_path,
            .source_info = self.extension_source_info,
            .handlers = try self.handlers.toOwnedSlice(allocator),
            .tools = try self.tools.toOwnedSlice(allocator),
            .message_renderers = try self.message_renderers.toOwnedSlice(allocator),
            .commands = try self.commands.toOwnedSlice(allocator),
            .flags = try self.flags.toOwnedSlice(allocator),
            .shortcuts = try self.shortcuts.toOwnedSlice(allocator),
        };
        self.finished = true;
        return .{
            .arena = self.arena,
            .extension = extension,
        };
    }

    fn hasFlag(self: *const ExtensionBuilder, name: []const u8) bool {
        for (self.flags.items) |flag| {
            if (std.mem.eql(u8, name, flag.name)) return true;
        }
        return false;
    }
};

pub fn loadExtensionFromFactoryAlloc(
    allocator: std.mem.Allocator,
    factory: types.ExtensionFactory,
    cwd: []const u8,
    event_bus: ?types.EventBus,
    runtime: *ExtensionRuntimeController,
    extension_path: []const u8,
) !LoadedNativeExtension {
    const resolved_cwd = try paths.resolvePathAlloc(allocator, cwd, ".", .{});
    defer allocator.free(resolved_cwd);

    const resolved_extension_path = if (isSyntheticExtensionPath(extension_path))
        try allocator.dupe(u8, extension_path)
    else
        try paths.resolvePathAlloc(allocator, extension_path, resolved_cwd, .{ .normalize_unicode_spaces = true });
    defer allocator.free(resolved_extension_path);

    var builder = try ExtensionBuilder.initAlloc(
        allocator,
        extension_path,
        resolved_extension_path,
        resolved_cwd,
        runtime,
        event_bus orelse .{},
    );
    defer builder.deinit();

    const api_value = builder.api();
    try factory.init(&api_value);
    return builder.finish();
}

pub const LoadExtensionsResult = struct {
    allocator: std.mem.Allocator,
    extensions: []LoadedNativeExtension,
    errors: []types.LoadExtensionError,
    runtime: ExtensionRuntimeController,

    pub fn deinit(self: *LoadExtensionsResult) void {
        for (self.extensions) |*extension| extension.deinit();
        self.allocator.free(self.extensions);
        for (self.errors) |*extension_error| {
            self.allocator.free(extension_error.path);
            self.allocator.free(extension_error.@"error");
        }
        self.allocator.free(self.errors);
        self.runtime.deinit();
        self.* = undefined;
    }
};

pub fn loadExtensionsAlloc(
    allocator: std.mem.Allocator,
    extension_paths: []const []const u8,
    cwd: []const u8,
    event_bus: ?types.EventBus,
) !LoadExtensionsResult {
    var runtime = createExtensionRuntime(allocator);
    errdefer runtime.deinit();

    var extensions: std.ArrayList(LoadedNativeExtension) = .empty;
    errdefer {
        for (extensions.items) |*extension| extension.deinit();
        extensions.deinit(allocator);
    }
    var errors: std.ArrayList(types.LoadExtensionError) = .empty;
    errdefer deinitLoadExtensionErrorList(allocator, &errors);

    const resolved_cwd = try paths.resolvePathAlloc(allocator, cwd, ".", .{});
    defer allocator.free(resolved_cwd);

    for (extension_paths) |extension_path| {
        const resolved_extension_path = paths.resolvePathAlloc(
            allocator,
            extension_path,
            resolved_cwd,
            .{ .normalize_unicode_spaces = true },
        ) catch |err| {
            try errors.append(allocator, try loadExtensionErrorAlloc(allocator, extension_path, @errorName(err)));
            continue;
        };
        defer allocator.free(resolved_extension_path);

        _ = event_bus;
        try errors.append(allocator, try loadExtensionErrorAlloc(
            allocator,
            resolved_extension_path,
            "Native source and prebuilt extension loading is implemented in the Bulb ABI loader chunk; inline factories are available now.",
        ));
    }

    return .{
        .allocator = allocator,
        .extensions = try extensions.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
        .runtime = runtime,
    };
}

fn apiOn(ptr: ?*anyopaque, event_name: types.ExtensionEventName, handler: types.ExtensionHandler) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    var registered = handler;
    registered.event_name = event_name;
    try builder.handlers.append(builder.arena.allocator(), registered);
}

fn apiRegisterTool(ptr: ?*anyopaque, tool: types.ToolDefinition) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    try builder.tools.append(builder.arena.allocator(), .{
        .definition = tool,
        .source_info = builder.extension_source_info,
    });
    try builder.runtime.refreshTools();
}

fn apiRegisterCommand(ptr: ?*anyopaque, name: []const u8, options: types.RegisterCommandOptions) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const allocator = builder.arena.allocator();
    try builder.commands.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .source_info = builder.extension_source_info,
        .description = if (options.description) |description| try allocator.dupe(u8, description) else null,
        .get_argument_completions = options.get_argument_completions,
        .handler = options.handler,
    });
}

fn apiRegisterShortcut(ptr: ?*anyopaque, shortcut: types.KeyId, options: types.RegisterShortcutOptions) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const allocator = builder.arena.allocator();
    try builder.shortcuts.append(allocator, .{
        .shortcut = shortcut,
        .description = if (options.description) |description| try allocator.dupe(u8, description) else null,
        .handler = options.handler,
        .extension_path = builder.extension_path,
    });
}

fn apiRegisterFlag(ptr: ?*anyopaque, name: []const u8, options: types.RegisterFlagOptions) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const allocator = builder.arena.allocator();
    const owned_name = try allocator.dupe(u8, name);
    const default = if (options.default) |value| try cloneFlagValueAlloc(allocator, value) else null;
    try builder.flags.append(allocator, .{
        .name = owned_name,
        .description = if (options.description) |description| try allocator.dupe(u8, description) else null,
        .type = options.type,
        .default = default,
        .extension_path = builder.extension_path,
    });
    if (default) |value| try builder.runtime.setDefaultFlag(owned_name, value);
}

fn apiGetFlag(ptr: ?*anyopaque, name: []const u8) ?types.FlagValue {
    const builder = builderFromPtr(ptr);
    builder.runtime.assertActive() catch return null;
    if (!builder.hasFlag(name)) return null;
    return builder.runtime.getFlag(name);
}

fn apiRegisterMessageRenderer(ptr: ?*anyopaque, custom_type: []const u8, renderer: types.MessageRenderer) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const allocator = builder.arena.allocator();
    try builder.message_renderers.append(allocator, .{
        .custom_type = try allocator.dupe(u8, custom_type),
        .renderer = renderer,
    });
}

fn apiSendMessage(ptr: ?*anyopaque, message: messages.CustomMessage, options: ?types.SendMessageOptions) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.send_message orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(message, options);
}

fn apiSendUserMessage(ptr: ?*anyopaque, content: types.SendUserMessageContent, options: ?types.SendUserMessageOptions) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.send_user_message orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(content, options);
}

fn apiAppendEntry(ptr: ?*anyopaque, custom_type: []const u8, data: ?std.json.Value) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.append_entry orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(custom_type, data);
}

fn apiSetSessionName(ptr: ?*anyopaque, name: []const u8) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.set_session_name orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(name);
}

fn apiGetSessionName(ptr: ?*anyopaque) ?[]const u8 {
    const builder = builderFromPtr(ptr);
    builder.runtime.assertActive() catch return null;
    const handler = builder.runtime.actions.get_session_name orelse return null;
    return handler.call();
}

fn apiSetLabel(ptr: ?*anyopaque, entry_id: []const u8, label: ?[]const u8) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.set_label orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(entry_id, label);
}

fn apiExec(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    options: ?types.ExecOptions,
) !types.ExecResult {
    _ = allocator;
    _ = command;
    _ = args;
    _ = options;
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    return error.ExtensionExecUnavailable;
}

fn apiGetActiveTools(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]const []const u8 {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.get_active_tools orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(allocator);
}

fn apiGetAllTools(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]types.ToolInfo {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.get_all_tools orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(allocator);
}

fn apiSetActiveTools(ptr: ?*anyopaque, tool_names: []const []const u8) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.set_active_tools orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(tool_names);
}

fn apiGetCommands(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]types.SlashCommandInfo {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.get_commands orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(allocator);
}

fn apiSetModel(ptr: ?*anyopaque, model: ai.Model) !bool {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.set_model orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(model);
}

fn apiGetThinkingLevel(ptr: ?*anyopaque) ai.ThinkingLevel {
    const builder = builderFromPtr(ptr);
    builder.runtime.assertActive() catch return .off;
    const handler = builder.runtime.actions.get_thinking_level orelse return .off;
    return handler.call();
}

fn apiSetThinkingLevel(ptr: ?*anyopaque, level: ai.ThinkingLevel) !void {
    const builder = builderFromPtr(ptr);
    try builder.runtime.assertActive();
    const handler = builder.runtime.actions.set_thinking_level orelse return error.ExtensionRuntimeNotInitialized;
    return handler.call(level);
}

fn apiRegisterProvider(ptr: ?*anyopaque, name: []const u8, config: types.ProviderConfig) !void {
    const builder = builderFromPtr(ptr);
    return builder.runtime.registerProvider(name, config, builder.extension_path);
}

fn apiUnregisterProvider(ptr: ?*anyopaque, name: []const u8) !void {
    const builder = builderFromPtr(ptr);
    return builder.runtime.unregisterProvider(name);
}

fn builderFromPtr(ptr: ?*anyopaque) *ExtensionBuilder {
    return @ptrCast(@alignCast(ptr.?));
}

fn assertActiveBridge(ptr: ?*anyopaque) !void {
    const runtime: *ExtensionRuntimeController = @ptrCast(@alignCast(ptr.?));
    return runtime.assertActive();
}

fn invalidateBridge(ptr: ?*anyopaque, message: ?[]const u8) void {
    const runtime: *ExtensionRuntimeController = @ptrCast(@alignCast(ptr.?));
    runtime.invalidate(message);
}

fn registerProviderBridge(ptr: ?*anyopaque, name: []const u8, config: types.ProviderConfig) !void {
    const runtime: *ExtensionRuntimeController = @ptrCast(@alignCast(ptr.?));
    return runtime.registerProvider(name, config, "<runtime>");
}

fn unregisterProviderBridge(ptr: ?*anyopaque, name: []const u8) !void {
    const runtime: *ExtensionRuntimeController = @ptrCast(@alignCast(ptr.?));
    return runtime.unregisterProvider(name);
}

fn createExtensionSourceInfoAlloc(
    allocator: std.mem.Allocator,
    extension_path: []const u8,
    resolved_path: []const u8,
) !types.SourceInfo {
    if (isSyntheticExtensionPath(extension_path)) {
        return source_info.createSyntheticSourceInfo(extension_path, .{
            .source = syntheticSourceName(extension_path),
            .scope = .temporary,
            .origin = .top_level,
        });
    }

    return source_info.createSyntheticSourceInfo(extension_path, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = if (std.fs.path.dirname(resolved_path)) |base_dir| try allocator.dupe(u8, base_dir) else null,
    });
}

fn isSyntheticExtensionPath(extension_path: []const u8) bool {
    return extension_path.len >= 2 and extension_path[0] == '<' and extension_path[extension_path.len - 1] == '>';
}

fn syntheticSourceName(extension_path: []const u8) []const u8 {
    if (!isSyntheticExtensionPath(extension_path)) return "local";
    const inner = extension_path[1 .. extension_path.len - 1];
    const colon_index = std.mem.indexOfScalar(u8, inner, ':') orelse inner.len;
    if (colon_index == 0) return "temporary";
    return inner[0..colon_index];
}

fn cloneFlagValueAlloc(allocator: std.mem.Allocator, value: types.FlagValue) !types.FlagValue {
    return switch (value) {
        .boolean => |boolean| .{ .boolean = boolean },
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
    };
}

fn flagEntryAlloc(allocator: std.mem.Allocator, name: []const u8, value: types.FlagValue) !types.FlagEntry {
    return .{
        .name = try allocator.dupe(u8, name),
        .value = try cloneFlagValueAlloc(allocator, value),
    };
}

fn deinitFlagEntry(allocator: std.mem.Allocator, entry: *types.FlagEntry) void {
    allocator.free(entry.name);
    switch (entry.value) {
        .boolean => {},
        .string => |value| allocator.free(value),
    }
    entry.* = undefined;
}

fn pendingProviderRegistrationAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    config: types.ProviderConfig,
    extension_path: []const u8,
) !types.PendingProviderRegistration {
    return .{
        .name = try allocator.dupe(u8, name),
        .config = config,
        .extension_path = try allocator.dupe(u8, extension_path),
    };
}

fn deinitPendingProviderRegistration(
    allocator: std.mem.Allocator,
    registration: *types.PendingProviderRegistration,
) void {
    allocator.free(registration.name);
    allocator.free(registration.extension_path);
    registration.* = undefined;
}

fn loadExtensionErrorAlloc(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !types.LoadExtensionError {
    return .{
        .path = try allocator.dupe(u8, path),
        .@"error" = try allocator.dupe(u8, message),
    };
}

fn deinitLoadExtensionErrorList(allocator: std.mem.Allocator, errors: *std.ArrayList(types.LoadExtensionError)) void {
    for (errors.items) |*extension_error| {
        allocator.free(extension_error.path);
        allocator.free(extension_error.@"error");
    }
    errors.deinit(allocator);
}

test "extension builder registers handlers tools commands flags renderers and shortcuts" {
    const allocator = std.testing.allocator;
    var runtime = createExtensionRuntime(allocator);
    defer runtime.deinit();
    var bus_controller = event_bus_mod.EventBusController.init(allocator);
    defer bus_controller.deinit();

    var builder = try ExtensionBuilder.initAlloc(
        allocator,
        "<inline:test>",
        "<inline:test>",
        "/tmp",
        &runtime,
        bus_controller.asEventBus(),
    );
    defer builder.deinit();
    const api_value = builder.api();

    const Callbacks = struct {
        fn eventHandler(ptr: ?*anyopaque, event: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ptr;
            _ = event;
            _ = ctx;
            return null;
        }

        fn command(ptr: ?*anyopaque, args: []const u8, ctx: *types.ExtensionCommandContext) !void {
            _ = ptr;
            _ = args;
            _ = ctx;
        }

        fn shortcut(ptr: ?*anyopaque, ctx: *types.ExtensionContext) !void {
            _ = ptr;
            _ = ctx;
        }

        fn renderer(
            ptr: ?*anyopaque,
            message: messages.CustomMessage,
            options: types.MessageRenderOptions,
            active_theme: types.Theme,
        ) !?types.Component {
            _ = ptr;
            _ = message;
            _ = options;
            _ = active_theme;
            return null;
        }
    };

    try api_value.on_fn.?(
        api_value.ptr,
        .session_start,
        .{ .event_name = .context, .handler_fn = Callbacks.eventHandler },
    );
    try api_value.register_tool_fn.?(api_value.ptr, types.ToolDefinition{
        .name = "oracle",
        .label = "oracle",
        .description = "answers",
        .parameters_json = "{\"type\":\"object\"}",
    });
    try api_value.register_command_fn.?(api_value.ptr, "oracle", .{
        .description = "ask oracle",
        .handler = .{ .handler_fn = Callbacks.command },
    });
    try api_value.register_shortcut_fn.?(api_value.ptr, "ctrl+o", .{
        .description = "oracle",
        .handler = .{ .handler_fn = Callbacks.shortcut },
    });
    try api_value.register_flag_fn.?(api_value.ptr, "oracle.enabled", .{
        .description = "toggle oracle",
        .type = .boolean,
        .default = .{ .boolean = true },
    });
    try api_value.register_message_renderer_fn.?(api_value.ptr, "oracle", .{ .render_fn = Callbacks.renderer });

    var loaded = try builder.finish();
    defer loaded.deinit();
    try std.testing.expectEqualStrings("<inline:test>", loaded.extension.path);
    try std.testing.expectEqualStrings("inline", loaded.extension.source_info.source);
    try std.testing.expectEqual(types.ExtensionEventName.session_start, loaded.extension.handlers[0].event_name);
    try std.testing.expectEqualStrings("oracle", loaded.extension.tools[0].definition.name);
    try std.testing.expectEqualStrings("ask oracle", loaded.extension.commands[0].description.?);
    try std.testing.expectEqualStrings("ctrl+o", loaded.extension.shortcuts[0].shortcut);
    try std.testing.expectEqualStrings("oracle.enabled", loaded.extension.flags[0].name);
    try std.testing.expectEqualStrings("oracle", loaded.extension.message_renderers[0].custom_type);
    try std.testing.expectEqual(types.FlagValue{ .boolean = true }, runtime.getFlag("oracle.enabled").?);
}

test "extension runtime queues providers and rejects stale contexts" {
    const allocator = std.testing.allocator;
    var runtime = createExtensionRuntime(allocator);
    defer runtime.deinit();
    var builder = try ExtensionBuilder.initAlloc(allocator, "/tmp/ext.zig", "/tmp/ext.zig", "/tmp", &runtime, .{});
    defer builder.deinit();
    const api_value = builder.api();

    try api_value.register_provider_fn.?.call("custom", .{ .name = "Custom" });
    try std.testing.expectEqual(@as(usize, 1), runtime.pending_provider_registrations.items.len);
    try std.testing.expectEqualStrings("custom", runtime.pending_provider_registrations.items[0].name);
    try std.testing.expectEqualStrings("/tmp/ext.zig", runtime.pending_provider_registrations.items[0].extension_path);

    runtime.invalidate("gone");
    try std.testing.expectError(
        error.ExtensionContextStale,
        api_value.register_provider_fn.?.call("custom2", .{}),
    );
    try std.testing.expectEqualStrings("gone", runtime.staleMessage().?);
}

test "load extension from inline factory uses resolved cwd and event bus" {
    const allocator = std.testing.allocator;
    var runtime = createExtensionRuntime(allocator);
    defer runtime.deinit();
    var bus_controller = event_bus_mod.EventBusController.init(allocator);
    defer bus_controller.deinit();

    const Factory = struct {
        fn init(ptr: ?*anyopaque, api: *const types.ExtensionAPI) !void {
            _ = ptr;
            try api.register_flag_fn.?(api.ptr, "loaded", .{
                .type = .string,
                .default = .{ .string = "yes" },
            });
            try api.events.?.emit_fn.?(api.events.?.ptr, "loaded", .{ .bool = true });
        }
    };

    var called = false;
    const Handler = struct {
        fn call(ptr: ?*anyopaque, channel: []const u8, data: std.json.Value) !void {
            _ = channel;
            try std.testing.expect(data.bool);
            const value: *bool = @ptrCast(@alignCast(ptr.?));
            value.* = true;
        }
    };
    const subscription = try bus_controller.on("loaded", .{ .ptr = &called, .handler_fn = Handler.call });
    defer subscription.unsubscribe();

    var loaded = try loadExtensionFromFactoryAlloc(
        allocator,
        .{ .init_fn = Factory.init },
        ".",
        bus_controller.asEventBus(),
        &runtime,
        "<inline:factory>",
    );
    defer loaded.deinit();

    try std.testing.expect(called);
    try std.testing.expectEqualStrings("<inline:factory>", loaded.extension.resolved_path);
    try std.testing.expectEqualStrings("loaded", loaded.extension.flags[0].name);
    switch (runtime.getFlag("loaded").?) {
        .string => |value| try std.testing.expectEqualStrings("yes", value),
        else => return error.TestExpectedStringFlag,
    }
}
