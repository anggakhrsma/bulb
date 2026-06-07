const std = @import("std");

const ai = @import("bulb_ai");
const tui = @import("bulb_tui");
const auth_storage = @import("../auth_storage.zig");
const config_value = @import("../resolve_config_value.zig");
const keybindings = @import("../keybindings.zig");
const loader = @import("loader.zig");
const messages = @import("../messages.zig");
const model_registry = @import("../model_registry.zig");
const session_manager = @import("../session_manager.zig");
const skills = @import("../skills.zig");
const source_info = @import("../source_info.zig");
const types = @import("types.zig");

const reserved_keybindings_for_extension_conflicts = [_][]const u8{
    "app.interrupt",
    "app.clear",
    "app.exit",
    "app.suspend",
    "app.thinking.cycle",
    "app.model.cycleForward",
    "app.model.cycleBackward",
    "app.model.select",
    "app.tools.expand",
    "app.thinking.toggle",
    "app.editor.external",
    "app.message.followUp",
    "tui.input.submit",
    "tui.select.confirm",
    "tui.select.cancel",
    "tui.input.copy",
    "tui.editor.deleteToLineEnd",
};

const no_op_ui_context: types.ExtensionUIContext = .{};

pub const ExtensionErrorListener = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, types.ExtensionError) void,

    pub fn call(self: ExtensionErrorListener, err: types.ExtensionError) void {
        self.call_fn(self.ptr, err);
    }
};

pub const ResolvedShortcuts = struct {
    allocator: std.mem.Allocator,
    shortcuts: std.array_hash_map.String(types.ExtensionShortcut) = .empty,

    pub fn deinit(self: *ResolvedShortcuts) void {
        var iterator = self.shortcuts.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.shortcuts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn get(self: *ResolvedShortcuts, key: []const u8) ?types.ExtensionShortcut {
        return self.shortcuts.get(key);
    }

    pub fn contains(self: *ResolvedShortcuts, key: []const u8) bool {
        return self.shortcuts.get(key) != null;
    }
};

pub const ResolvedCommands = struct {
    allocator: std.mem.Allocator,
    commands: []types.ResolvedCommand,

    pub fn deinit(self: *ResolvedCommands) void {
        for (self.commands) |command| self.allocator.free(command.invocation_name);
        self.allocator.free(self.commands);
        self.* = undefined;
    }
};

pub const BeforeAgentStartCombinedResult = struct {
    allocator: std.mem.Allocator,
    messages: []messages.CustomMessage = &.{},
    system_prompt: ?[]u8 = null,

    pub fn deinit(self: *BeforeAgentStartCombinedResult) void {
        if (self.system_prompt) |system_prompt| self.allocator.free(system_prompt);
        if (self.messages.len > 0) self.allocator.free(self.messages);
        self.* = .{ .allocator = self.allocator };
    }
};

pub const OwnedUserContentList = struct {
    allocator: std.mem.Allocator,
    items: []ai.UserContent,
    owned_strings: [][]u8 = &.{},

    pub fn deinit(self: *OwnedUserContentList) void {
        for (self.owned_strings) |value| self.allocator.free(value);
        if (self.owned_strings.len > 0) self.allocator.free(self.owned_strings);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const OwnedImageContentList = struct {
    allocator: std.mem.Allocator,
    items: []ai.ImageContent,
    owned_strings: [][]u8 = &.{},

    pub fn deinit(self: *OwnedImageContentList) void {
        for (self.owned_strings) |value| self.allocator.free(value);
        if (self.owned_strings.len > 0) self.allocator.free(self.owned_strings);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub const InputEmitResult = struct {
    allocator: std.mem.Allocator,
    action: types.InputEventResult,
    owned_text: ?[]u8 = null,
    owned_images: ?OwnedImageContentList = null,

    pub fn deinit(self: *InputEmitResult) void {
        if (self.owned_text) |text| self.allocator.free(text);
        if (self.owned_images) |*images| images.deinit();
        self.* = .{ .allocator = self.allocator, .action = .{ .@"continue" = {} } };
    }
};

pub const MessageEndEmitResult = struct {
    arena: std.heap.ArenaAllocator,
    message: types.AgentMessage,

    pub fn deinit(self: *MessageEndEmitResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ToolResultEmitResult = struct {
    allocator: std.mem.Allocator,
    content: ?OwnedUserContentList = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,

    pub fn deinit(self: *ToolResultEmitResult) void {
        if (self.content) |*content| content.deinit();
        self.* = .{ .allocator = self.allocator };
    }
};

pub const DiscoveredExtensionResources = struct {
    allocator: std.mem.Allocator,
    skill_paths: []ExtensionResourcePath = &.{},
    prompt_paths: []ExtensionResourcePath = &.{},
    theme_paths: []ExtensionResourcePath = &.{},

    pub fn deinit(self: *DiscoveredExtensionResources) void {
        deinitResourcePaths(self.allocator, self.skill_paths);
        deinitResourcePaths(self.allocator, self.prompt_paths);
        deinitResourcePaths(self.allocator, self.theme_paths);
        self.* = .{ .allocator = self.allocator };
    }
};

pub const ExtensionResourcePath = struct {
    path: []u8,
    extension_path: []u8,
};

const BuiltinKeybinding = struct {
    keybinding: []const u8,
    restrict_override: bool,
};

pub const ExtensionRunner = struct {
    allocator: std.mem.Allocator,
    extensions: []const types.Extension,
    runtime: *loader.ExtensionRuntimeController,
    ui_context: types.ExtensionUIContext = no_op_ui_context,
    has_bound_ui: bool = false,
    mode: types.ExtensionMode = .print,
    cwd: []const u8,
    session_manager: *session_manager.SessionManager,
    model_registry: *model_registry.ModelRegistry,
    error_listeners: std.ArrayList(ExtensionErrorListener) = .empty,
    context_actions: types.ExtensionContextActions = .{},
    command_actions: types.ExtensionCommandContextActions = .{},
    shortcut_diagnostics: std.ArrayList(skills.ResourceDiagnostic) = .empty,
    command_diagnostics: std.ArrayList(skills.ResourceDiagnostic) = .empty,
    stale_message: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        extensions: []const types.Extension,
        runtime: *loader.ExtensionRuntimeController,
        cwd: []const u8,
        sessions: *session_manager.SessionManager,
        registry: *model_registry.ModelRegistry,
    ) ExtensionRunner {
        return .{
            .allocator = allocator,
            .extensions = extensions,
            .runtime = runtime,
            .cwd = cwd,
            .session_manager = sessions,
            .model_registry = registry,
        };
    }

    pub fn deinit(self: *ExtensionRunner) void {
        self.clearShortcutDiagnostics();
        self.shortcut_diagnostics.deinit(self.allocator);
        self.clearCommandDiagnostics();
        self.command_diagnostics.deinit(self.allocator);
        self.error_listeners.deinit(self.allocator);
        if (self.stale_message) |message| self.allocator.free(message);
        self.* = undefined;
    }

    pub fn bindCore(
        self: *ExtensionRunner,
        actions: types.ExtensionActions,
        context_actions: types.ExtensionContextActions,
        provider_actions: ?loader.ProviderActions,
    ) void {
        self.runtime.bindActions(actions);
        self.context_actions = context_actions;

        const effective_provider_actions: loader.ProviderActions = provider_actions orelse .{
            .register_provider = .{ .ptr = self, .call_fn = registerProviderToModelRegistry },
            .unregister_provider = .{ .ptr = self, .call_fn = unregisterProviderFromModelRegistry },
        };
        self.runtime.bindProviderActionsReporting(effective_provider_actions, .{
            .ptr = self,
            .call_fn = reportProviderRegistrationError,
        });
    }

    pub fn bindCommandContext(self: *ExtensionRunner, actions: ?types.ExtensionCommandContextActions) void {
        self.command_actions = actions orelse .{};
    }

    pub fn setUIContext(self: *ExtensionRunner, ui_context: ?types.ExtensionUIContext, mode: types.ExtensionMode) void {
        if (ui_context) |ctx| {
            self.ui_context = ctx;
            self.has_bound_ui = true;
        } else {
            self.ui_context = no_op_ui_context;
            self.has_bound_ui = false;
        }
        self.mode = mode;
    }

    pub fn getUIContext(self: *ExtensionRunner) *types.ExtensionUIContext {
        return &self.ui_context;
    }

    pub fn hasUI(self: *const ExtensionRunner) bool {
        return self.has_bound_ui;
    }

    pub fn getExtensionPathsAlloc(self: *const ExtensionRunner, allocator: std.mem.Allocator) ![][]const u8 {
        var paths = try allocator.alloc([]const u8, self.extensions.len);
        errdefer allocator.free(paths);
        for (self.extensions, 0..) |extension, index| paths[index] = extension.path;
        return paths;
    }

    pub fn getAllRegisteredToolsAlloc(self: *const ExtensionRunner, allocator: std.mem.Allocator) ![]types.RegisteredTool {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        var result: std.ArrayList(types.RegisteredTool) = .empty;
        errdefer result.deinit(allocator);

        for (self.extensions) |extension| {
            for (extension.tools) |tool| {
                if (seen.contains(tool.definition.name)) continue;
                try seen.put(tool.definition.name, {});
                try result.append(allocator, tool);
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn getToolDefinition(self: *const ExtensionRunner, tool_name: []const u8) ?types.ToolDefinition {
        for (self.extensions) |extension| {
            for (extension.tools) |tool| {
                if (std.mem.eql(u8, tool.definition.name, tool_name)) return tool.definition;
            }
        }
        return null;
    }

    pub fn getFlagsAlloc(self: *const ExtensionRunner, allocator: std.mem.Allocator) ![]types.ExtensionFlag {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        var result: std.ArrayList(types.ExtensionFlag) = .empty;
        errdefer result.deinit(allocator);

        for (self.extensions) |extension| {
            for (extension.flags) |flag| {
                if (seen.contains(flag.name)) continue;
                try seen.put(flag.name, {});
                try result.append(allocator, flag);
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    pub fn setFlagValue(self: *ExtensionRunner, name: []const u8, value: types.FlagValue) !void {
        try self.runtime.setFlagValue(name, value);
    }

    pub fn getFlagValues(self: *const ExtensionRunner) []const types.FlagEntry {
        return self.runtime.flag_values.items;
    }

    pub fn getShortcutsAlloc(
        self: *ExtensionRunner,
        allocator: std.mem.Allocator,
        resolved_keybindings: *const keybindings.KeybindingsConfig,
    ) !ResolvedShortcuts {
        self.clearShortcutDiagnostics();

        var builtin_keybindings = try buildBuiltinKeybindings(allocator, resolved_keybindings);
        defer deinitBuiltinKeybindings(allocator, &builtin_keybindings);

        var resolved: ResolvedShortcuts = .{ .allocator = allocator };
        errdefer resolved.deinit();

        for (self.extensions) |extension| {
            for (extension.shortcuts) |shortcut| {
                const normalized_key = try lowerAlloc(allocator, shortcut.shortcut);
                errdefer allocator.free(normalized_key);

                if (builtin_keybindings.get(normalized_key)) |builtin_keybinding| {
                    if (builtin_keybinding.restrict_override) {
                        try self.addShortcutDiagnosticAlloc(
                            "Extension shortcut '{s}' from {s} conflicts with built-in shortcut. Skipping.",
                            .{ shortcut.shortcut, shortcut.extension_path },
                            shortcut.extension_path,
                        );
                        allocator.free(normalized_key);
                        continue;
                    }
                    try self.addShortcutDiagnosticAlloc(
                        "Extension shortcut conflict: '{s}' is built-in shortcut for {s} and {s}. Using {s}.",
                        .{ shortcut.shortcut, builtin_keybinding.keybinding, shortcut.extension_path, shortcut.extension_path },
                        shortcut.extension_path,
                    );
                }

                if (resolved.shortcuts.fetchOrderedRemove(normalized_key)) |old| {
                    try self.addShortcutDiagnosticAlloc(
                        "Extension shortcut conflict: '{s}' registered by both {s} and {s}. Using {s}.",
                        .{ shortcut.shortcut, old.value.extension_path, shortcut.extension_path, shortcut.extension_path },
                        shortcut.extension_path,
                    );
                    allocator.free(old.key);
                }
                try resolved.shortcuts.put(allocator, normalized_key, shortcut);
            }
        }

        return resolved;
    }

    pub fn getShortcutDiagnostics(self: *const ExtensionRunner) []const skills.ResourceDiagnostic {
        return self.shortcut_diagnostics.items;
    }

    pub fn invalidate(
        self: *ExtensionRunner,
        message: []const u8,
    ) void {
        if (self.stale_message != null) return;
        self.stale_message = self.allocator.dupe(u8, message) catch null;
        self.runtime.invalidate(message);
    }

    pub fn assertActive(self: *const ExtensionRunner) !void {
        if (self.stale_message != null) return error.ExtensionContextStale;
        try self.runtime.assertActive();
    }

    pub fn onError(self: *ExtensionRunner, listener: ExtensionErrorListener) !void {
        try self.error_listeners.append(self.allocator, listener);
    }

    pub fn emitError(self: *ExtensionRunner, err: types.ExtensionError) void {
        for (self.error_listeners.items) |listener| listener.call(err);
    }

    pub fn hasHandlers(self: *const ExtensionRunner, event_name: types.ExtensionEventName) bool {
        for (self.extensions) |extension| {
            if (event_name == .user_bash and extension.user_bash_handlers.len > 0) return true;
            for (extension.handlers) |handler| {
                if (handler.event_name == event_name) return true;
            }
        }
        return false;
    }

    pub fn getMessageRenderer(self: *const ExtensionRunner, custom_type: []const u8) ?types.MessageRenderer {
        for (self.extensions) |extension| {
            for (extension.message_renderers) |registration| {
                if (std.mem.eql(u8, custom_type, registration.custom_type)) return registration.renderer;
            }
        }
        return null;
    }

    pub fn getRegisteredCommandsAlloc(self: *ExtensionRunner, allocator: std.mem.Allocator) !ResolvedCommands {
        self.clearCommandDiagnostics();
        return .{
            .allocator = allocator,
            .commands = try self.resolveRegisteredCommandsAlloc(allocator),
        };
    }

    pub fn getCommandDiagnostics(self: *const ExtensionRunner) []const skills.ResourceDiagnostic {
        return self.command_diagnostics.items;
    }

    pub fn getCommandAlloc(self: *ExtensionRunner, allocator: std.mem.Allocator, name: []const u8) !?types.ResolvedCommand {
        var commands = try self.getRegisteredCommandsAlloc(allocator);
        defer commands.deinit();

        for (commands.commands) |command| {
            if (!std.mem.eql(u8, command.invocation_name, name)) continue;
            return .{
                .command = command.command,
                .invocation_name = try allocator.dupe(u8, command.invocation_name),
            };
        }

        return null;
    }

    pub fn shutdown(self: *ExtensionRunner) void {
        if (self.context_actions.shutdown_fn) |shutdown_fn| shutdown_fn(self.context_actions.ptr);
    }

    pub fn createContext(self: *ExtensionRunner) !types.ExtensionContext {
        try self.assertActive();
        return .{
            .ui = &self.ui_context,
            .mode = self.mode,
            .has_ui = self.hasUI(),
            .cwd = self.cwd,
            .session_manager = self.session_manager,
            .model_registry = self.model_registry,
            .model = if (self.context_actions.get_model_fn) |get_fn| get_fn(self.context_actions.ptr) else null,
            .signal = if (self.context_actions.get_signal_fn) |get_fn| get_fn(self.context_actions.ptr) else null,
            .actions = self.context_actions,
        };
    }

    pub fn createCommandContext(self: *ExtensionRunner) !types.ExtensionCommandContext {
        return .{
            .base = try self.createContext(),
            .command_actions = self.command_actions,
        };
    }

    pub fn emit(self: *ExtensionRunner, event: types.ExtensionEvent) !?std.json.Value {
        var ctx = try self.createContext();
        var result: ?std.json.Value = null;

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != event.name()) continue;
                const handler_result = handler.call(event, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, event.name(), err);
                    continue;
                };
                if (handler_result) |value| {
                    result = value;
                    if (isSessionBeforeEvent(event.name()) and jsonBool(value, "cancel") == true) return result;
                }
            }
        }

        return result;
    }

    pub fn emitContext(self: *ExtensionRunner, context_messages: []types.AgentMessage) ![]types.AgentMessage {
        var ctx = try self.createContext();

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .context) continue;
                _ = handler.call(.{ .context = .{ .messages = context_messages } }, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .context, err);
                    continue;
                };
            }
        }

        return context_messages;
    }

    pub fn emitBeforeProviderRequest(self: *ExtensionRunner, payload: std.json.Value) !std.json.Value {
        var ctx = try self.createContext();
        var current_payload = payload;

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .before_provider_request) continue;
                const handler_result = handler.call(.{
                    .before_provider_request = .{ .payload = current_payload },
                }, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .before_provider_request, err);
                    continue;
                };
                if (handler_result) |value| current_payload = value;
            }
        }

        return current_payload;
    }

    pub fn emitBeforeAgentStartAlloc(
        self: *ExtensionRunner,
        allocator: std.mem.Allocator,
        prompt: []const u8,
        images: []const ai.ImageContent,
        system_prompt: []const u8,
        system_prompt_options: types.BuildSystemPromptOptions,
    ) !?BeforeAgentStartCombinedResult {
        var current_system_prompt = system_prompt;
        var owned_current_system_prompt: ?[]u8 = null;
        defer if (owned_current_system_prompt) |value| allocator.free(value);
        var modified = false;

        const PromptState = struct {
            prompt: []const u8,

            fn get(ptr: ?*anyopaque) []const u8 {
                const state: *@This() = @ptrCast(@alignCast(ptr.?));
                return state.prompt;
            }
        };
        var prompt_state = PromptState{ .prompt = current_system_prompt };

        var ctx = try self.createContext();
        ctx.actions.get_system_prompt_fn = PromptState.get;
        ctx.actions.ptr = &prompt_state;

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .before_agent_start) continue;
                const event = types.ExtensionEvent{ .before_agent_start = .{
                    .prompt = prompt,
                    .images = images,
                    .system_prompt = current_system_prompt,
                    .system_prompt_options = system_prompt_options,
                } };
                const handler_result = handler.call(event, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .before_agent_start, err);
                    continue;
                };
                const value = handler_result orelse continue;
                const next_prompt = jsonString(value, "systemPrompt") orelse jsonString(value, "system_prompt") orelse continue;
                const owned_next = try allocator.dupe(u8, next_prompt);
                if (owned_current_system_prompt) |old| allocator.free(old);
                owned_current_system_prompt = owned_next;
                current_system_prompt = owned_next;
                prompt_state.prompt = current_system_prompt;
                modified = true;
            }
        }

        if (!modified) return null;
        return .{
            .allocator = allocator,
            .system_prompt = try allocator.dupe(u8, current_system_prompt),
        };
    }

    pub fn emitMessageEndAlloc(
        self: *ExtensionRunner,
        allocator: std.mem.Allocator,
        event: types.MessageEndEvent,
    ) !?MessageEndEmitResult {
        var ctx = try self.createContext();
        var current_message = event.message;
        var owned_current: ?MessageEndEmitResult = null;
        errdefer if (owned_current) |*owned| owned.deinit();
        var modified = false;

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .message_end) continue;
                const current_event = types.ExtensionEvent{ .message_end = .{ .message = current_message } };
                const handler_result = handler.call(current_event, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .message_end, err);
                    continue;
                };
                const value = handler_result orelse continue;
                if (value != .object) continue;
                const message_value = value.object.get("message") orelse continue;
                var next_message = parseAgentMessageAlloc(allocator, message_value) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .message_end, err);
                    continue;
                };
                if (!sameAgentMessageRole(next_message.message, current_message)) {
                    next_message.deinit();
                    self.emitError(.{
                        .extension_path = extension.path,
                        .event = "message_end",
                        .@"error" = "message_end handlers must return a message with the same role",
                    });
                    continue;
                }
                if (owned_current) |*owned| owned.deinit();
                owned_current = next_message;
                current_message = owned_current.?.message;
                modified = true;
            }
        }

        if (!modified) return null;
        const result = owned_current.?;
        owned_current = null;
        return result;
    }

    pub fn emitToolResultAlloc(
        self: *ExtensionRunner,
        allocator: std.mem.Allocator,
        event: types.ToolResultEvent,
    ) !?ToolResultEmitResult {
        var ctx = try self.createContext();
        var current_event = event;
        var current_content: ?OwnedUserContentList = null;
        errdefer if (current_content) |*content| content.deinit();
        var details: ?std.json.Value = null;
        var is_error: ?bool = null;
        var modified = false;

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .tool_result) continue;
                const handler_result = handler.call(.{ .tool_result = current_event }, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .tool_result, err);
                    continue;
                };
                const value = handler_result orelse continue;
                if (try applyToolResultPatchAlloc(allocator, value, &current_event, &current_content, &details, &is_error)) {
                    modified = true;
                }
            }
        }

        if (!modified) return null;
        var result = ToolResultEmitResult{
            .allocator = allocator,
            .details = details,
            .is_error = is_error,
        };
        if (current_content) |content| {
            result.content = content;
            current_content = null;
        }
        return result;
    }

    pub fn emitToolCall(self: *ExtensionRunner, event: types.ToolCallEvent) !?types.ToolCallEventResult {
        var ctx = try self.createContext();
        var result: ?types.ToolCallEventResult = null;

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .tool_call) continue;
                const handler_result = try handler.call(.{ .tool_call = event }, &ctx);
                const value = handler_result orelse continue;
                result = .{
                    .block = jsonBool(value, "block") orelse false,
                    .reason = jsonString(value, "reason"),
                };
                if (result.?.block) return result;
            }
        }

        return result;
    }

    pub fn emitUserBash(self: *ExtensionRunner, event: types.UserBashEvent) !?types.UserBashEventResult {
        var ctx = try self.createContext();

        for (self.extensions) |extension| {
            for (extension.user_bash_handlers) |handler| {
                const handler_result = handler.call(event, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .user_bash, err);
                    continue;
                };
                if (handler_result) |result| return result;
            }
        }

        return null;
    }

    pub fn emitInputAlloc(
        self: *ExtensionRunner,
        allocator: std.mem.Allocator,
        text: []const u8,
        images: []const ai.ImageContent,
        source: types.InputSource,
        streaming_behavior: ?types.StreamingBehavior,
    ) !InputEmitResult {
        var ctx = try self.createContext();
        var current_text = text;
        var current_images = images;
        var owned_text: ?[]u8 = null;
        errdefer if (owned_text) |value| allocator.free(value);
        var owned_images: ?OwnedImageContentList = null;
        errdefer if (owned_images) |*value| value.deinit();
        var images_replaced = false;

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .input) continue;
                const event = types.ExtensionEvent{ .input = .{
                    .text = current_text,
                    .images = current_images,
                    .source = source,
                    .streaming_behavior = streaming_behavior,
                } };
                const handler_result = handler.call(event, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .input, err);
                    continue;
                };
                const value = handler_result orelse continue;
                if (value != .object) continue;
                const action = jsonString(value, "action") orelse continue;

                if (std.mem.eql(u8, action, "handled")) {
                    if (owned_text) |owned| allocator.free(owned);
                    owned_text = null;
                    if (owned_images) |*owned| owned.deinit();
                    owned_images = null;
                    return .{ .allocator = allocator, .action = .{ .handled = {} } };
                }
                if (std.mem.eql(u8, action, "continue")) continue;
                if (!std.mem.eql(u8, action, "transform")) continue;

                const next_text = jsonString(value, "text") orelse {
                    try self.emitHandlerErrorAlloc(extension.path, .input, error.ExpectedTransformText);
                    continue;
                };
                const owned_next_text = try allocator.dupe(u8, next_text);
                if (owned_text) |owned| allocator.free(owned);
                owned_text = owned_next_text;
                current_text = owned_next_text;

                if (value.object.get("images")) |images_value| {
                    if (images_value != .null) {
                        const next_images = parseImageContentListAlloc(allocator, images_value) catch |err| {
                            try self.emitHandlerErrorAlloc(extension.path, .input, err);
                            continue;
                        };
                        if (owned_images) |*owned| owned.deinit();
                        owned_images = next_images;
                        current_images = owned_images.?.items;
                        images_replaced = true;
                    }
                }
            }
        }

        if (!std.mem.eql(u8, current_text, text) or images_replaced) {
            const result_owned_text = owned_text;
            owned_text = null;
            const result_owned_images = owned_images;
            owned_images = null;
            return .{
                .allocator = allocator,
                .action = .{ .transform = .{
                    .text = current_text,
                    .images = current_images,
                } },
                .owned_text = result_owned_text,
                .owned_images = result_owned_images,
            };
        }

        if (owned_text) |owned| allocator.free(owned);
        owned_text = null;
        if (owned_images) |*owned| owned.deinit();
        owned_images = null;
        return .{ .allocator = allocator, .action = .{ .@"continue" = {} } };
    }

    pub fn emitResourcesDiscoverAlloc(
        self: *ExtensionRunner,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        reason: types.ResourcesDiscoverReason,
    ) !DiscoveredExtensionResources {
        var ctx = try self.createContext();
        var resources = DiscoveredExtensionResources{ .allocator = allocator };
        errdefer resources.deinit();

        var skill_paths: std.ArrayList(ExtensionResourcePath) = .empty;
        var prompt_paths: std.ArrayList(ExtensionResourcePath) = .empty;
        var theme_paths: std.ArrayList(ExtensionResourcePath) = .empty;
        errdefer {
            deinitResourcePathList(allocator, &skill_paths);
            deinitResourcePathList(allocator, &prompt_paths);
            deinitResourcePathList(allocator, &theme_paths);
        }

        for (self.extensions) |extension| {
            for (extension.handlers) |handler| {
                if (handler.event_name != .resources_discover) continue;
                const handler_result = handler.call(.{
                    .resources_discover = .{ .cwd = cwd, .reason = reason },
                }, &ctx) catch |err| {
                    try self.emitHandlerErrorAlloc(extension.path, .resources_discover, err);
                    continue;
                };
                const value = handler_result orelse continue;
                try appendResourcePathsFromJson(allocator, &skill_paths, extension.path, value, "skillPaths", "skill_paths");
                try appendResourcePathsFromJson(allocator, &prompt_paths, extension.path, value, "promptPaths", "prompt_paths");
                try appendResourcePathsFromJson(allocator, &theme_paths, extension.path, value, "themePaths", "theme_paths");
            }
        }

        resources.skill_paths = try skill_paths.toOwnedSlice(allocator);
        resources.prompt_paths = try prompt_paths.toOwnedSlice(allocator);
        resources.theme_paths = try theme_paths.toOwnedSlice(allocator);
        return resources;
    }

    fn resolveRegisteredCommandsAlloc(self: *ExtensionRunner, allocator: std.mem.Allocator) ![]types.ResolvedCommand {
        var commands: std.ArrayList(types.RegisteredCommand) = .empty;
        defer commands.deinit(allocator);
        var counts = std.StringHashMap(usize).init(allocator);
        defer counts.deinit();

        for (self.extensions) |extension| {
            for (extension.commands) |command| {
                try commands.append(allocator, command);
                const current = counts.get(command.name) orelse 0;
                try counts.put(command.name, current + 1);
            }
        }

        var seen = std.StringHashMap(usize).init(allocator);
        defer seen.deinit();
        var taken = std.StringHashMap(void).init(allocator);
        defer taken.deinit();

        var resolved: std.ArrayList(types.ResolvedCommand) = .empty;
        errdefer {
            for (resolved.items) |command| allocator.free(command.invocation_name);
            resolved.deinit(allocator);
        }

        for (commands.items) |command| {
            const occurrence = (seen.get(command.name) orelse 0) + 1;
            try seen.put(command.name, occurrence);

            var invocation_name = if ((counts.get(command.name) orelse 0) > 1)
                try std.fmt.allocPrint(allocator, "{s}:{d}", .{ command.name, occurrence })
            else
                try allocator.dupe(u8, command.name);
            errdefer allocator.free(invocation_name);

            if (taken.contains(invocation_name)) {
                var suffix = occurrence;
                while (taken.contains(invocation_name)) {
                    allocator.free(invocation_name);
                    suffix += 1;
                    invocation_name = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ command.name, suffix });
                }
            }

            try taken.put(invocation_name, {});
            try resolved.append(allocator, .{ .command = command, .invocation_name = invocation_name });
        }

        return try resolved.toOwnedSlice(allocator);
    }

    fn clearShortcutDiagnostics(self: *ExtensionRunner) void {
        for (self.shortcut_diagnostics.items) |*diagnostic| diagnostic.deinit();
        self.shortcut_diagnostics.clearRetainingCapacity();
    }

    fn clearCommandDiagnostics(self: *ExtensionRunner) void {
        for (self.command_diagnostics.items) |*diagnostic| diagnostic.deinit();
        self.command_diagnostics.clearRetainingCapacity();
    }

    fn addShortcutDiagnosticAlloc(
        self: *ExtensionRunner,
        comptime fmt: []const u8,
        args: anytype,
        extension_path: []const u8,
    ) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(message);
        try self.shortcut_diagnostics.append(
            self.allocator,
            try skills.ResourceDiagnostic.initAlloc(self.allocator, .warning, message, extension_path, null),
        );
    }

    fn emitHandlerErrorAlloc(
        self: *ExtensionRunner,
        extension_path: []const u8,
        event_name: types.ExtensionEventName,
        err: anyerror,
    ) !void {
        const message = try self.allocator.dupe(u8, @errorName(err));
        defer self.allocator.free(message);
        self.emitError(.{
            .extension_path = extension_path,
            .event = event_name.text(),
            .@"error" = message,
        });
    }
};

fn registerProviderToModelRegistry(ptr: ?*anyopaque, name: []const u8, provider_config: types.ProviderConfig) !void {
    const runner: *ExtensionRunner = @ptrCast(@alignCast(ptr.?));
    var converted = try providerConfigInputAlloc(runner.allocator, name, provider_config);
    defer converted.deinit();
    try runner.model_registry.registerProvider(name, converted.input);
}

fn unregisterProviderFromModelRegistry(ptr: ?*anyopaque, name: []const u8) !void {
    const runner: *ExtensionRunner = @ptrCast(@alignCast(ptr.?));
    try runner.model_registry.unregisterProvider(name);
}

fn reportProviderRegistrationError(ptr: ?*anyopaque, name: []const u8, extension_path: []const u8, err: anyerror) void {
    const runner: *ExtensionRunner = @ptrCast(@alignCast(ptr.?));
    const message = providerErrorMessageAlloc(runner.allocator, name, err) catch @errorName(err);
    defer if (message.ptr != @errorName(err).ptr) runner.allocator.free(message);
    runner.emitError(.{
        .extension_path = extension_path,
        .event = "register_provider",
        .@"error" = message,
    });
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
    config: types.ProviderConfig,
) !ConvertedProviderConfigInput {
    const headers = try allocator.alloc(config_value.HeaderInput, config.headers.len);
    errdefer allocator.free(headers);
    for (config.headers, 0..) |header, index| {
        headers[index] = .{ .key = header.name, .value = header.value };
    }

    const models = try allocator.alloc(ai.Model, config.models.len);
    errdefer allocator.free(models);
    for (config.models, 0..) |model, index| {
        models[index] = .{
            .id = model.id,
            .name = model.name,
            .api = model.api orelse config.api orelse "",
            .provider = provider_name,
            .base_url = model.base_url orelse config.base_url orelse "",
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
            .name = config.name,
            .base_url = config.base_url,
            .api_key = config.api_key,
            .api = config.api,
            .headers = headers,
            .auth_header = config.auth_header,
            .oauth = config.oauth,
            .stream_simple = config.stream_simple,
            .models = models,
        },
    };
}

fn providerErrorMessageAlloc(allocator: std.mem.Allocator, name: []const u8, err: anyerror) ![]u8 {
    return switch (err) {
        error.DynamicProviderStreamSimpleApiRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"api\" is required when registering streamSimple.",
            .{name},
        ),
        error.DynamicProviderBaseUrlRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"baseUrl\" is required when registering models.",
            .{name},
        ),
        error.DynamicProviderAuthRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"apiKey\" or \"oauth\" is required when registering models.",
            .{name},
        ),
        error.DynamicProviderApiRequired => try std.fmt.allocPrint(
            allocator,
            "Provider {s}: \"api\" is required when registering models without per-model APIs.",
            .{name},
        ),
        else => try std.fmt.allocPrint(allocator, "Provider {s}: {s}", .{ name, @errorName(err) }),
    };
}

fn buildBuiltinKeybindings(
    allocator: std.mem.Allocator,
    resolved_keybindings: *const keybindings.KeybindingsConfig,
) !std.array_hash_map.String(BuiltinKeybinding) {
    var result: std.array_hash_map.String(BuiltinKeybinding) = .empty;
    errdefer deinitBuiltinKeybindings(allocator, &result);

    var iterator = resolved_keybindings.iterator();
    while (iterator.next()) |entry| {
        const restrict_override = isReservedKeybinding(entry.key_ptr.*);
        for (entry.value_ptr.keys) |key| {
            const normalized_key = try lowerAlloc(allocator, key);
            errdefer allocator.free(normalized_key);
            if (result.get(normalized_key)) |existing| {
                if (existing.restrict_override and !restrict_override) {
                    allocator.free(normalized_key);
                    continue;
                }
                const old = result.fetchOrderedRemove(normalized_key).?;
                allocator.free(old.key);
                allocator.free(normalized_key);
                const replacement_key = try lowerAlloc(allocator, key);
                try result.put(allocator, replacement_key, .{
                    .keybinding = entry.key_ptr.*,
                    .restrict_override = restrict_override,
                });
                continue;
            }
            try result.put(allocator, normalized_key, .{
                .keybinding = entry.key_ptr.*,
                .restrict_override = restrict_override,
            });
        }
    }

    return result;
}

fn deinitBuiltinKeybindings(
    allocator: std.mem.Allocator,
    keybinding_map: *std.array_hash_map.String(BuiltinKeybinding),
) void {
    var iterator = keybinding_map.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    keybinding_map.deinit(allocator);
}

fn isReservedKeybinding(keybinding_name: []const u8) bool {
    for (reserved_keybindings_for_extension_conflicts) |reserved| {
        if (std.mem.eql(u8, keybinding_name, reserved)) return true;
    }
    return false;
}

fn lowerAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const owned = try allocator.alloc(u8, value.len);
    _ = std.ascii.lowerString(owned, value);
    return owned;
}

fn isSessionBeforeEvent(event_name: types.ExtensionEventName) bool {
    return switch (event_name) {
        .session_before_switch,
        .session_before_fork,
        .session_before_compact,
        .session_before_tree,
        => true,
        else => false,
    };
}

fn jsonBool(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |string| string,
        else => null,
    };
}

fn parseAgentMessageAlloc(allocator: std.mem.Allocator, value: std.json.Value) !MessageEndEmitResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const message = try parseAgentMessageValueAlloc(arena_allocator, value);
    return .{
        .arena = arena,
        .message = message,
    };
}

fn parseAgentMessageValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) !types.AgentMessage {
    if (value != .object) return error.ExpectedAgentMessageObject;
    const object = value.object;
    const role = optionalString(object, "role") orelse return error.ExpectedAgentMessageRole;

    if (std.mem.eql(u8, role, "user")) {
        const content_value = object.get("content") orelse return error.ExpectedUserContentArray;
        const content = try parseUserContentListAlloc(allocator, content_value);
        return .{ .user = .{
            .content = content.items,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }

    if (std.mem.eql(u8, role, "assistant")) {
        const content_value = object.get("content") orelse return error.InvalidMessageContent;
        return .{ .assistant = .{
            .content = try parseAssistantContentValueAlloc(allocator, content_value),
            .api = try dupeStringOrEmpty(allocator, optionalString(object, "api")),
            .provider = try dupeStringOrEmpty(allocator, optionalString(object, "provider")),
            .model = try dupeStringOrEmpty(allocator, optionalString(object, "model")),
            .response_model = try dupeOptionalString(allocator, optionalStringAny(object, "responseModel", "response_model")),
            .usage = parseUsage(object.get("usage")),
            .stop_reason = parseStopReason(optionalStringAny(object, "stopReason", "stop_reason")),
            .error_message = try dupeOptionalString(allocator, optionalStringAny(object, "errorMessage", "error_message")),
            .response_id = try dupeOptionalString(allocator, optionalStringAny(object, "responseId", "response_id")),
            .diagnostics = try parseDiagnosticsListAlloc(allocator, object.get("diagnostics")),
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }

    if (std.mem.eql(u8, role, "toolResult") or std.mem.eql(u8, role, "tool_result")) {
        const content_value = object.get("content") orelse return error.ExpectedUserContentArray;
        const content = try parseUserContentListAlloc(allocator, content_value);
        return .{ .tool_result = .{
            .tool_call_id = try dupeStringOrEmpty(allocator, optionalStringAny(object, "toolCallId", "tool_call_id")),
            .tool_name = try dupeStringOrEmpty(allocator, optionalStringAny(object, "toolName", "tool_name")),
            .content = content.items,
            .is_error = optionalBoolAny(object, "isError", "is_error") orelse false,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }

    if (std.mem.eql(u8, role, "bashExecution") or std.mem.eql(u8, role, "bash_execution")) {
        return .{ .bash_execution = .{
            .command = try dupeStringOrEmpty(allocator, optionalString(object, "command")),
            .output = try dupeStringOrEmpty(allocator, optionalString(object, "output")),
            .exit_code = optionalI64Any(object, "exitCode", "exit_code"),
            .cancelled = optionalBool(object, "cancelled") orelse false,
            .truncated = optionalBool(object, "truncated") orelse false,
            .full_output_path = try dupeOptionalString(allocator, optionalStringAny(object, "fullOutputPath", "full_output_path")),
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
            .exclude_from_context = optionalBoolAny(object, "excludeFromContext", "exclude_from_context") orelse false,
        } };
    }

    if (std.mem.eql(u8, role, "custom")) {
        const content_value = object.get("content") orelse return error.InvalidMessageContent;
        return .{ .custom = .{
            .custom_type = try dupeStringOrEmpty(allocator, optionalStringAny(object, "customType", "custom_type")),
            .content = try parseCustomContentAlloc(allocator, content_value),
            .display = optionalBool(object, "display") orelse true,
            .details_json = if (object.get("details")) |details| try jsonValueToStringAlloc(allocator, details) else null,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }

    return error.UnsupportedAgentMessageRole;
}

fn sameAgentMessageRole(left: types.AgentMessage, right: types.AgentMessage) bool {
    return std.meta.activeTag(left) == std.meta.activeTag(right);
}

fn parseCustomContentAlloc(allocator: std.mem.Allocator, value: std.json.Value) !messages.CustomContent {
    return switch (value) {
        .string => |text| .{ .text = try allocator.dupe(u8, text) },
        .array => blk: {
            const content = try parseUserContentListAlloc(allocator, value);
            break :blk .{ .parts = content.items };
        },
        else => error.InvalidMessageContent,
    };
}

fn parseAssistantContentValueAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]ai.AssistantContent {
    return switch (value) {
        .string => |text| blk: {
            const content = try allocator.alloc(ai.AssistantContent, 1);
            content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
            break :blk content;
        },
        .array => blk: {
            const content = try allocator.alloc(ai.AssistantContent, value.array.items.len);
            for (value.array.items, 0..) |item, index| {
                content[index] = try parseAssistantContentPartAlloc(allocator, item);
            }
            break :blk content;
        },
        else => error.InvalidMessageContent,
    };
}

fn parseAssistantContentPartAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !ai.AssistantContent {
    if (value != .object) return error.InvalidMessageContent;
    const object = value.object;
    const content_type = optionalString(object, "type") orelse return error.InvalidMessageContent;
    if (std.mem.eql(u8, content_type, "text")) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, optionalString(object, "text") orelse ""),
            .text_signature = try dupeOptionalString(allocator, optionalStringAny(object, "textSignature", "text_signature")),
        } };
    }
    if (std.mem.eql(u8, content_type, "thinking")) {
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, optionalString(object, "thinking") orelse ""),
            .thinking_signature = try dupeOptionalString(allocator, optionalStringAny(object, "thinkingSignature", "thinking_signature")),
            .redacted = optionalBool(object, "redacted") orelse false,
        } };
    }
    if (std.mem.eql(u8, content_type, "toolCall") or std.mem.eql(u8, content_type, "tool_call")) {
        return .{ .tool_call = .{
            .id = try allocator.dupe(u8, optionalString(object, "id") orelse ""),
            .name = try allocator.dupe(u8, optionalString(object, "name") orelse ""),
            .arguments_json = if (object.get("arguments")) |arguments|
                try jsonValueToStringAlloc(allocator, arguments)
            else
                try allocator.dupe(u8, "{}"),
            .thought_signature = try dupeOptionalString(allocator, optionalStringAny(object, "thoughtSignature", "thought_signature")),
        } };
    }
    return error.InvalidMessageContent;
}

fn parseUsage(value: ?std.json.Value) ai.Usage {
    const usage_value = value orelse return .{};
    if (usage_value != .object) return .{};
    const object = usage_value.object;
    return .{
        .input = optionalU64(object, "input") orelse 0,
        .output = optionalU64(object, "output") orelse 0,
        .cache_read = optionalU64Any(object, "cacheRead", "cache_read") orelse 0,
        .cache_write = optionalU64Any(object, "cacheWrite", "cache_write") orelse 0,
        .total_tokens = optionalU64Any(object, "totalTokens", "total_tokens") orelse 0,
        .cost = parseCost(object.get("cost")),
    };
}

fn parseCost(value: ?std.json.Value) ai.Cost {
    const cost_value = value orelse return .{};
    if (cost_value != .object) return .{};
    const object = cost_value.object;
    return .{
        .input = optionalF64(object, "input") orelse 0,
        .output = optionalF64(object, "output") orelse 0,
        .cache_read = optionalF64Any(object, "cacheRead", "cache_read") orelse 0,
        .cache_write = optionalF64Any(object, "cacheWrite", "cache_write") orelse 0,
        .total = optionalF64(object, "total") orelse 0,
    };
}

fn parseStopReason(value: ?[]const u8) ai.StopReason {
    const reason = value orelse return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "toolUse") or std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, reason, "error")) return .@"error";
    if (std.mem.eql(u8, reason, "aborted")) return .aborted;
    return .stop;
}

fn parseDiagnosticsListAlloc(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) ![]const ai.AssistantMessageDiagnostic {
    const diagnostics_value = value orelse return &.{};
    if (diagnostics_value != .array) return &.{};
    const diagnostics = try allocator.alloc(ai.AssistantMessageDiagnostic, diagnostics_value.array.items.len);
    for (diagnostics_value.array.items, 0..) |item, index| {
        diagnostics[index] = try parseDiagnosticAlloc(allocator, item);
    }
    return diagnostics;
}

fn parseDiagnosticAlloc(allocator: std.mem.Allocator, value: std.json.Value) !ai.AssistantMessageDiagnostic {
    if (value != .object) return error.InvalidDiagnostic;
    const object = value.object;
    return .{
        .type = try dupeStringOrEmpty(allocator, optionalString(object, "type")),
        .timestamp_ms = optionalI64(object, "timestamp") orelse optionalI64Any(object, "timestampMs", "timestamp_ms") orelse 0,
        .@"error" = if (object.get("error")) |error_value| try parseDiagnosticErrorAlloc(allocator, error_value) else null,
        .details_json = if (object.get("details")) |details| try jsonValueToStringAlloc(allocator, details) else null,
    };
}

fn parseDiagnosticErrorAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !ai.DiagnosticErrorInfo {
    if (value != .object) return error.InvalidDiagnosticError;
    const object = value.object;
    return .{
        .name = try dupeOptionalString(allocator, optionalString(object, "name")),
        .message = try dupeStringOrEmpty(allocator, optionalString(object, "message")),
        .stack = try dupeOptionalString(allocator, optionalString(object, "stack")),
        .code = try parseDiagnosticCodeAlloc(allocator, object.get("code")),
    };
}

fn parseDiagnosticCodeAlloc(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
) !?ai.DiagnosticCode {
    const code_value = value orelse return null;
    return switch (code_value) {
        .string => |string| .{ .string = try allocator.dupe(u8, string) },
        .integer => |integer| .{ .number = integer },
        .float => |float| if (std.math.isFinite(float) and @floor(float) == float)
            .{ .number = @intFromFloat(float) }
        else
            null,
        .number_string => |number| if (std.fmt.parseInt(i64, number, 10)) |parsed|
            .{ .number = parsed }
        else |_|
            .{ .string = try allocator.dupe(u8, number) },
        else => null,
    };
}

fn applyToolResultPatchAlloc(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    current_event: *types.ToolResultEvent,
    current_content: *?OwnedUserContentList,
    details: *?std.json.Value,
    is_error: *?bool,
) !bool {
    if (value != .object) return false;
    var modified = false;

    if (value.object.get("content")) |content_value| {
        var next_content = try parseUserContentListAlloc(allocator, content_value);
        errdefer next_content.deinit();
        if (current_content.*) |*old| old.deinit();
        current_content.* = next_content;
        toolResultBasePtr(current_event).content = current_content.*.?.items;
        modified = true;
    }
    if (value.object.get("details")) |details_value| {
        details.* = details_value;
        if (current_event.* == .custom) current_event.custom.details = details_value;
        modified = true;
    }
    if (value.object.get("isError") orelse value.object.get("is_error")) |is_error_value| {
        if (is_error_value == .bool) {
            is_error.* = is_error_value.bool;
            toolResultBasePtr(current_event).is_error = is_error_value.bool;
            modified = true;
        }
    }

    return modified;
}

fn toolResultBasePtr(event: *types.ToolResultEvent) *types.ToolResultEventBase {
    return switch (event.*) {
        inline else => |*payload| &payload.base,
    };
}

fn parseUserContentListAlloc(allocator: std.mem.Allocator, value: std.json.Value) !OwnedUserContentList {
    if (value != .array) return error.ExpectedUserContentArray;
    var content: std.ArrayList(ai.UserContent) = .empty;
    errdefer content.deinit(allocator);
    var owned_strings: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_strings.items) |owned| allocator.free(owned);
        owned_strings.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) return error.ExpectedUserContentObject;
        const content_type = jsonString(item, "type") orelse return error.ExpectedUserContentType;
        if (std.mem.eql(u8, content_type, "text")) {
            const text = jsonString(item, "text") orelse return error.ExpectedTextContent;
            const owned_text = try allocator.dupe(u8, text);
            errdefer allocator.free(owned_text);
            try owned_strings.append(allocator, owned_text);
            try content.append(allocator, .{ .text = .{ .text = owned_text } });
        } else if (std.mem.eql(u8, content_type, "image")) {
            const data = jsonString(item, "data") orelse return error.ExpectedImageData;
            const mime_type = jsonString(item, "mimeType") orelse jsonString(item, "mime_type") orelse return error.ExpectedImageMimeType;
            const owned_data = try allocator.dupe(u8, data);
            errdefer allocator.free(owned_data);
            const owned_mime_type = try allocator.dupe(u8, mime_type);
            errdefer allocator.free(owned_mime_type);
            try owned_strings.append(allocator, owned_data);
            try owned_strings.append(allocator, owned_mime_type);
            try content.append(allocator, .{ .image = .{ .data = owned_data, .mime_type = owned_mime_type } });
        } else {
            return error.UnsupportedUserContentType;
        }
    }

    return .{
        .allocator = allocator,
        .items = try content.toOwnedSlice(allocator),
        .owned_strings = try owned_strings.toOwnedSlice(allocator),
    };
}

fn parseImageContentListAlloc(allocator: std.mem.Allocator, value: std.json.Value) !OwnedImageContentList {
    if (value != .array) return error.ExpectedImageContentArray;
    var images: std.ArrayList(ai.ImageContent) = .empty;
    errdefer images.deinit(allocator);
    var owned_strings: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_strings.items) |owned| allocator.free(owned);
        owned_strings.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) return error.ExpectedImageContentObject;
        const data = jsonString(item, "data") orelse return error.ExpectedImageData;
        const mime_type = jsonString(item, "mimeType") orelse jsonString(item, "mime_type") orelse return error.ExpectedImageMimeType;
        const owned_data = try allocator.dupe(u8, data);
        errdefer allocator.free(owned_data);
        const owned_mime_type = try allocator.dupe(u8, mime_type);
        errdefer allocator.free(owned_mime_type);
        try owned_strings.append(allocator, owned_data);
        try owned_strings.append(allocator, owned_mime_type);
        try images.append(allocator, .{ .data = owned_data, .mime_type = owned_mime_type });
    }

    return .{
        .allocator = allocator,
        .items = try images.toOwnedSlice(allocator),
        .owned_strings = try owned_strings.toOwnedSlice(allocator),
    };
}

fn appendResourcePathsFromJson(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(ExtensionResourcePath),
    extension_path: []const u8,
    value: std.json.Value,
    camel_key: []const u8,
    snake_key: []const u8,
) !void {
    if (value != .object) return;
    const paths_value = value.object.get(camel_key) orelse value.object.get(snake_key) orelse return;
    if (paths_value != .array) return;
    for (paths_value.array.items) |path_value| {
        if (path_value != .string) continue;
        try list.append(allocator, .{
            .path = try allocator.dupe(u8, path_value.string),
            .extension_path = try allocator.dupe(u8, extension_path),
        });
    }
}

fn deinitResourcePaths(allocator: std.mem.Allocator, paths: []ExtensionResourcePath) void {
    for (paths) |path| {
        allocator.free(path.path);
        allocator.free(path.extension_path);
    }
    if (paths.len > 0) allocator.free(paths);
}

fn deinitResourcePathList(allocator: std.mem.Allocator, list: *std.ArrayList(ExtensionResourcePath)) void {
    for (list.items) |path| {
        allocator.free(path.path);
        allocator.free(path.extension_path);
    }
    list.deinit(allocator);
}

fn putJsonString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .string = value });
}

fn putJsonBool(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: bool) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putJsonInt(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: i64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .integer = value });
}

fn putJsonFloat(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: f64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .float = value });
}

fn putJsonValue(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), value);
}

fn jsonValueToStringAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.write(value);
    return output.toOwnedSlice();
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn optionalStringAny(object: std.json.ObjectMap, first: []const u8, second: []const u8) ?[]const u8 {
    return optionalString(object, first) orelse optionalString(object, second);
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn optionalBoolAny(object: std.json.ObjectMap, first: []const u8, second: []const u8) ?bool {
    return optionalBool(object, first) orelse optionalBool(object, second);
}

fn optionalI64(object: std.json.ObjectMap, key: []const u8) ?i64 {
    return valueToI64(object.get(key));
}

fn optionalI64Any(object: std.json.ObjectMap, first: []const u8, second: []const u8) ?i64 {
    return optionalI64(object, first) orelse optionalI64(object, second);
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    return valueToU64(object.get(key));
}

fn optionalU64Any(object: std.json.ObjectMap, first: []const u8, second: []const u8) ?u64 {
    return optionalU64(object, first) orelse optionalU64(object, second);
}

fn optionalF64(object: std.json.ObjectMap, key: []const u8) ?f64 {
    return valueToF64(object.get(key));
}

fn optionalF64Any(object: std.json.ObjectMap, first: []const u8, second: []const u8) ?f64 {
    return optionalF64(object, first) orelse optionalF64(object, second);
}

fn valueToI64(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |integer| integer,
        .float => |float| {
            if (!std.math.isFinite(float) or @floor(float) != float) return null;
            if (float < @as(f64, @floatFromInt(std.math.minInt(i64)))) return null;
            if (float > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return null;
            return @intFromFloat(float);
        },
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

fn valueToU64(value: ?std.json.Value) ?u64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |integer| if (integer >= 0) @as(u64, @intCast(integer)) else null,
        .float => |float| {
            if (!std.math.isFinite(float) or float < 0 or @floor(float) != float) return null;
            if (float > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
            return @intFromFloat(float);
        },
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        else => null,
    };
}

fn valueToF64(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| if (std.math.isFinite(float)) float else null,
        .number_string => |number| std.fmt.parseFloat(f64, number) catch null,
        else => null,
    };
}

fn dupeStringOrEmpty(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    return try allocator.dupe(u8, value orelse "");
}

fn dupeOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |string| try allocator.dupe(u8, string) else null;
}

fn imageArrayJsonAlloc(allocator: std.mem.Allocator, image_items: []const ai.ImageContent) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (image_items) |image| {
        var object = std.json.Value{ .object = .empty };
        try putJsonString(allocator, &object, "type", "image");
        try putJsonString(allocator, &object, "data", image.data);
        try putJsonString(allocator, &object, "mimeType", image.mime_type);
        try array.append(object);
    }
    return .{ .array = array };
}

fn assistantMessageJsonAlloc(allocator: std.mem.Allocator, text: []const u8, cost_total: f64) !std.json.Value {
    var message = std.json.Value{ .object = .empty };
    try putJsonString(allocator, &message, "role", "assistant");
    try putJsonValue(allocator, &message, "content", try assistantTextContentArrayJsonAlloc(allocator, text));
    try putJsonString(allocator, &message, "api", ai.types.api.openai_responses);
    try putJsonString(allocator, &message, "provider", "openai");
    try putJsonString(allocator, &message, "model", "gpt-test");
    try putJsonValue(allocator, &message, "usage", try usageJsonAlloc(allocator, cost_total));
    try putJsonString(allocator, &message, "stopReason", "stop");
    try putJsonInt(allocator, &message, "timestamp", 123);
    return message;
}

fn userMessageJsonAlloc(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var message = std.json.Value{ .object = .empty };
    try putJsonString(allocator, &message, "role", "user");
    try putJsonValue(allocator, &message, "content", try userTextContentArrayJsonAlloc(allocator, text));
    try putJsonInt(allocator, &message, "timestamp", 123);
    return message;
}

fn assistantTextContentArrayJsonAlloc(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    var block = std.json.Value{ .object = .empty };
    try putJsonString(allocator, &block, "type", "text");
    try putJsonString(allocator, &block, "text", text);
    try array.append(block);
    return .{ .array = array };
}

fn userTextContentArrayJsonAlloc(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    var block = std.json.Value{ .object = .empty };
    try putJsonString(allocator, &block, "type", "text");
    try putJsonString(allocator, &block, "text", text);
    try array.append(block);
    return .{ .array = array };
}

fn usageJsonAlloc(allocator: std.mem.Allocator, cost_total: f64) !std.json.Value {
    var usage = std.json.Value{ .object = .empty };
    try putJsonInt(allocator, &usage, "input", 1);
    try putJsonInt(allocator, &usage, "output", 2);
    try putJsonInt(allocator, &usage, "cacheRead", 3);
    try putJsonInt(allocator, &usage, "cacheWrite", 4);
    try putJsonInt(allocator, &usage, "totalTokens", 10);
    var cost = std.json.Value{ .object = .empty };
    try putJsonFloat(allocator, &cost, "input", 0.001);
    try putJsonFloat(allocator, &cost, "output", 0.002);
    try putJsonFloat(allocator, &cost, "cacheRead", 0.003);
    try putJsonFloat(allocator, &cost, "cacheWrite", 0.004);
    try putJsonFloat(allocator, &cost, "total", cost_total);
    try putJsonValue(allocator, &usage, "cost", cost);
    return usage;
}

const RunnerHarness = struct {
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    oauth_registry: *ai.oauth.Registry,
    resolver: *config_value.Resolver,
    storage: *auth_storage.AuthStorage,
    registry: *model_registry.ModelRegistry,
    sessions: *session_manager.SessionManager,
    runtime: *loader.ExtensionRuntimeController,

    fn init(allocator: std.mem.Allocator) !RunnerHarness {
        const env = try allocator.create(std.process.Environ.Map);
        errdefer allocator.destroy(env);
        env.* = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();

        const oauth_registry = try allocator.create(ai.oauth.Registry);
        errdefer allocator.destroy(oauth_registry);
        oauth_registry.* = try ai.oauth.Registry.init(allocator);
        errdefer oauth_registry.deinit();

        const resolver = try allocator.create(config_value.Resolver);
        errdefer allocator.destroy(resolver);
        resolver.* = config_value.Resolver.init(allocator, env);
        errdefer resolver.deinit();

        const storage = try allocator.create(auth_storage.AuthStorage);
        errdefer allocator.destroy(storage);
        storage.* = try auth_storage.AuthStorage.initMemory(allocator, env, oauth_registry, resolver);
        errdefer storage.deinit();

        const registry = try allocator.create(model_registry.ModelRegistry);
        errdefer allocator.destroy(registry);
        registry.* = try model_registry.ModelRegistry.inMemory(allocator, storage);
        errdefer registry.deinit();

        const sessions = try allocator.create(session_manager.SessionManager);
        errdefer allocator.destroy(sessions);
        sessions.* = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
        errdefer sessions.deinit();

        const runtime = try allocator.create(loader.ExtensionRuntimeController);
        errdefer allocator.destroy(runtime);
        runtime.* = loader.createExtensionRuntime(allocator);
        errdefer runtime.deinit();

        return .{
            .allocator = allocator,
            .env = env,
            .oauth_registry = oauth_registry,
            .resolver = resolver,
            .storage = storage,
            .registry = registry,
            .sessions = sessions,
            .runtime = runtime,
        };
    }

    fn deinit(self: *RunnerHarness) void {
        self.runtime.deinit();
        self.allocator.destroy(self.runtime);
        self.sessions.deinit();
        self.allocator.destroy(self.sessions);
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        self.storage.deinit();
        self.allocator.destroy(self.storage);
        self.resolver.deinit();
        self.allocator.destroy(self.resolver);
        self.oauth_registry.deinit();
        self.allocator.destroy(self.oauth_registry);
        self.env.deinit();
        self.allocator.destroy(self.env);
    }
};

const TestCallbacks = struct {
    fn command(ptr: ?*anyopaque, args: []const u8, ctx: *types.ExtensionCommandContext) !void {
        _ = ptr;
        _ = args;
        _ = ctx;
    }

    fn shortcut(ptr: ?*anyopaque, ctx: *types.ExtensionContext) !void {
        _ = ptr;
        _ = ctx;
    }

    fn event(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
        _ = ptr;
        _ = event_value;
        _ = ctx;
        return null;
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

fn testSource(path: []const u8) source_info.SourceInfo {
    return source_info.createSyntheticSourceInfo(path, .{ .source = "test" });
}

fn testExtension(
    path: []const u8,
    tools: []const types.RegisteredTool,
    commands: []const types.RegisteredCommand,
    shortcuts: []const types.ExtensionShortcut,
    flags: []const types.ExtensionFlag,
    renderers: []const types.MessageRendererRegistration,
    handlers: []const types.ExtensionHandler,
) types.Extension {
    return .{
        .path = path,
        .resolved_path = path,
        .source_info = testSource(path),
        .tools = tools,
        .commands = commands,
        .shortcuts = shortcuts,
        .flags = flags,
        .message_renderers = renderers,
        .handlers = handlers,
    };
}

fn testExtensionWithUserBash(path: []const u8, handlers: []const types.UserBashHandler) types.Extension {
    return .{
        .path = path,
        .resolved_path = path,
        .source_info = testSource(path),
        .user_bash_handlers = handlers,
    };
}

test "extension runner keeps first tool flag and renderer registrations" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const first_tools = [_]types.RegisteredTool{.{
        .definition = .{ .name = "shared", .label = "shared", .description = "first", .parameters_json = "{}" },
        .source_info = testSource("/tmp/a.zig"),
    }};
    const second_tools = [_]types.RegisteredTool{.{
        .definition = .{ .name = "shared", .label = "shared", .description = "second", .parameters_json = "{}" },
        .source_info = testSource("/tmp/b.zig"),
    }};
    const first_flags = [_]types.ExtensionFlag{.{
        .name = "shared-flag",
        .description = "first",
        .type = .boolean,
        .default = .{ .boolean = true },
        .extension_path = "/tmp/a.zig",
    }};
    const second_flags = [_]types.ExtensionFlag{.{
        .name = "shared-flag",
        .description = "second",
        .type = .boolean,
        .default = .{ .boolean = false },
        .extension_path = "/tmp/b.zig",
    }};
    const renderers = [_]types.MessageRendererRegistration{.{
        .custom_type = "my-type",
        .renderer = .{ .render_fn = TestCallbacks.renderer },
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/a.zig", &first_tools, &.{}, &.{}, &first_flags, &renderers, &.{}),
        testExtension("/tmp/b.zig", &second_tools, &.{}, &.{}, &second_flags, &.{}, &.{}),
    };

    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    const tools = try runner.getAllRegisteredToolsAlloc(allocator);
    defer allocator.free(tools);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("first", tools[0].definition.description);

    const flags = try runner.getFlagsAlloc(allocator);
    defer allocator.free(flags);
    try std.testing.expectEqual(@as(usize, 1), flags.len);
    try std.testing.expectEqualStrings("first", flags[0].description.?);

    try std.testing.expect(runner.getMessageRenderer("my-type") != null);
    try std.testing.expect(runner.getMessageRenderer("missing") == null);
}

test "extension runner resolves duplicate commands with Pi invocation suffixes" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const commands_a = [_]types.RegisteredCommand{.{
        .name = "shared-cmd",
        .source_info = testSource("/tmp/a.zig"),
        .description = "First command",
        .handler = .{ .handler_fn = TestCallbacks.command },
    }};
    const commands_b = [_]types.RegisteredCommand{.{
        .name = "shared-cmd",
        .source_info = testSource("/tmp/b.zig"),
        .description = "Second command",
        .handler = .{ .handler_fn = TestCallbacks.command },
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/a.zig", &.{}, &commands_a, &.{}, &.{}, &.{}, &.{}),
        testExtension("/tmp/b.zig", &.{}, &commands_b, &.{}, &.{}, &.{}, &.{}),
    };

    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    var commands = try runner.getRegisteredCommandsAlloc(allocator);
    defer commands.deinit();
    try std.testing.expectEqual(@as(usize, 2), commands.commands.len);
    try std.testing.expectEqualStrings("shared-cmd:1", commands.commands[0].invocation_name);
    try std.testing.expectEqualStrings("shared-cmd:2", commands.commands[1].invocation_name);
    try std.testing.expectEqualStrings("First command", commands.commands[0].command.description.?);
    try std.testing.expectEqual(@as(usize, 0), runner.getCommandDiagnostics().len);

    const second = (try runner.getCommandAlloc(allocator, "shared-cmd:2")).?;
    defer allocator.free(second.invocation_name);
    try std.testing.expectEqualStrings("Second command", second.command.description.?);
}

test "extension runner applies shortcut conflict diagnostics and last extension wins" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    var empty: keybindings.KeybindingsConfig = .empty;
    defer tui.keybindings.deinitConfig(allocator, &empty);
    var manager = try keybindings.KeybindingsManager.init(allocator, &empty);
    defer manager.deinit();
    var effective = try manager.getEffectiveConfigAlloc(allocator);
    defer tui.keybindings.deinitConfig(allocator, &effective);

    const shortcuts_a = [_]types.ExtensionShortcut{ .{
        .shortcut = "ctrl+c",
        .description = "reserved",
        .handler = .{ .handler_fn = TestCallbacks.shortcut },
        .extension_path = "/tmp/a.zig",
    }, .{
        .shortcut = "ctrl+shift+x",
        .description = "first",
        .handler = .{ .handler_fn = TestCallbacks.shortcut },
        .extension_path = "/tmp/a.zig",
    } };
    const shortcuts_b = [_]types.ExtensionShortcut{.{
        .shortcut = "ctrl+shift+x",
        .description = "second",
        .handler = .{ .handler_fn = TestCallbacks.shortcut },
        .extension_path = "/tmp/b.zig",
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/a.zig", &.{}, &.{}, &shortcuts_a, &.{}, &.{}, &.{}),
        testExtension("/tmp/b.zig", &.{}, &.{}, &shortcuts_b, &.{}, &.{}, &.{}),
    };

    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    var shortcuts = try runner.getShortcutsAlloc(allocator, &effective);
    defer shortcuts.deinit();

    try std.testing.expect(!shortcuts.contains("ctrl+c"));
    try std.testing.expect(shortcuts.contains("ctrl+shift+x"));
    try std.testing.expectEqualStrings("/tmp/b.zig", shortcuts.get("ctrl+shift+x").?.extension_path);
    try std.testing.expectEqual(@as(usize, 2), runner.getShortcutDiagnostics().len);
    try std.testing.expect(std.mem.indexOf(u8, runner.getShortcutDiagnostics()[0].message, "conflicts with built-in") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner.getShortcutDiagnostics()[1].message, "shortcut conflict") != null);
}

test "extension runner exposes context mode and stale invalidation" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var runner = ExtensionRunner.init(allocator, &.{}, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    const print_ctx = try runner.createContext();
    try std.testing.expectEqual(types.ExtensionMode.print, print_ctx.mode);
    try std.testing.expect(!print_ctx.has_ui);

    runner.setUIContext(.{}, .rpc);
    const rpc_ctx = try runner.createContext();
    try std.testing.expectEqual(types.ExtensionMode.rpc, rpc_ctx.mode);
    try std.testing.expect(rpc_ctx.has_ui);

    runner.invalidate("stale");
    try std.testing.expectError(error.ExtensionContextStale, runner.createContext());
}

test "extension runner emits handler errors without aborting later handlers" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const State = struct {
        errors: usize = 0,
        calls: usize = 0,

        fn failing(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ptr;
            _ = event_value;
            _ = ctx;
            return error.HandlerError;
        }

        fn succeeding(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.calls += 1;
            return null;
        }

        fn onError(ptr: ?*anyopaque, err: types.ExtensionError) void {
            _ = err;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.errors += 1;
        }
    };
    var state = State{};
    const handlers_a = [_]types.ExtensionHandler{.{
        .event_name = .context,
        .handler_fn = State.failing,
    }};
    const handlers_b = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .context,
        .handler_fn = State.succeeding,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/a.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_a),
        testExtension("/tmp/b.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_b),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    try runner.onError(.{ .ptr = &state, .call_fn = State.onError });

    _ = try runner.emitContext(&.{});
    try std.testing.expectEqual(@as(usize, 1), state.errors);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

test "extension runner chains before_agent_start system prompt updates" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const State = struct {
        suffix: []const u8,
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            const next = try std.fmt.allocPrint(state.allocator, "{s}\n{s}", .{ ctx.getSystemPrompt(), state.suffix });
            var object = std.json.Value{ .object = .empty };
            try putJsonString(state.allocator, &object, "systemPrompt", next);
            return object;
        }
    };
    var first = State{ .suffix = "first", .allocator = arena_allocator };
    var second = State{ .suffix = "second", .allocator = arena_allocator };
    const handlers_a = [_]types.ExtensionHandler{.{
        .ptr = &first,
        .event_name = .before_agent_start,
        .handler_fn = State.handler,
    }};
    const handlers_b = [_]types.ExtensionHandler{.{
        .ptr = &second,
        .event_name = .before_agent_start,
        .handler_fn = State.handler,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/a.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_a),
        testExtension("/tmp/b.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_b),
    };

    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    var result = (try runner.emitBeforeAgentStartAlloc(allocator, "hello", &.{}, "base", .{ .cwd = "/tmp" })).?;
    defer result.deinit();
    try std.testing.expectEqualStrings("base\nfirst\nsecond", result.system_prompt.?);
}

test "extension runner chains tool_result content and isError patches" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const State = struct {
        text: ?[]const u8 = null,
        mark_error: ?bool = null,
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            var object = std.json.Value{ .object = .empty };
            if (state.text) |text| {
                var array = std.json.Array.init(state.allocator);
                switch (event_value.tool_result) {
                    inline else => |payload| {
                        for (payload.base.content) |content| {
                            if (content == .text) {
                                var block = std.json.Value{ .object = .empty };
                                try putJsonString(state.allocator, &block, "type", "text");
                                try putJsonString(state.allocator, &block, "text", content.text.text);
                                try array.append(block);
                            }
                        }
                    },
                }
                var block = std.json.Value{ .object = .empty };
                try putJsonString(state.allocator, &block, "type", "text");
                try putJsonString(state.allocator, &block, "text", text);
                try array.append(block);
                try putJsonValue(state.allocator, &object, "content", .{ .array = array });
            }
            if (state.mark_error) |value| try putJsonBool(state.allocator, &object, "isError", value);
            return object;
        }
    };
    var first = State{ .text = "ext1", .allocator = arena_allocator };
    var second = State{ .mark_error = true, .allocator = arena_allocator };
    const handlers_a = [_]types.ExtensionHandler{.{
        .ptr = &first,
        .event_name = .tool_result,
        .handler_fn = State.handler,
    }};
    const handlers_b = [_]types.ExtensionHandler{.{
        .ptr = &second,
        .event_name = .tool_result,
        .handler_fn = State.handler,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/a.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_a),
        testExtension("/tmp/b.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_b),
    };

    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    const input = std.json.Value{ .object = .empty };
    const base_content = [_]ai.UserContent{.{ .text = .{ .text = "base" } }};
    var result = (try runner.emitToolResultAlloc(allocator, .{ .custom = .{
        .base = .{ .tool_call_id = "call-1", .input = input, .content = &base_content },
        .tool_name = "demo",
    } })).?;
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.content.?.items.len);
    try std.testing.expectEqualStrings("base", result.content.?.items[0].text.text);
    try std.testing.expectEqualStrings("ext1", result.content.?.items[1].text.text);
    try std.testing.expectEqual(true, result.is_error.?);
}

test "extension runner user_bash returns the first native handler result" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const State = struct {
        allocator: std.mem.Allocator,
        output: []const u8 = "",
        calls: usize = 0,
        seen_excluded: bool = false,
        seen_command: ?[]u8 = null,
        seen_cwd: ?[]u8 = null,

        fn deinit(self: *@This()) void {
            if (self.seen_command) |command| self.allocator.free(command);
            if (self.seen_cwd) |cwd| self.allocator.free(cwd);
        }

        fn nullHandler(ptr: ?*anyopaque, event: types.UserBashEvent, ctx: *types.ExtensionContext) !?types.UserBashEventResult {
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.calls += 1;
            state.seen_excluded = event.exclude_from_context;
            state.seen_command = try state.allocator.dupe(u8, event.command);
            state.seen_cwd = try state.allocator.dupe(u8, event.cwd);
            return null;
        }

        fn resultHandler(ptr: ?*anyopaque, event: types.UserBashEvent, ctx: *types.ExtensionContext) !?types.UserBashEventResult {
            _ = event;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.calls += 1;
            return .{ .result = .{
                .output = try state.allocator.dupe(u8, state.output),
                .exit_code = 0,
                .cancelled = false,
                .truncated = false,
            } };
        }

        fn lateHandler(ptr: ?*anyopaque, event: types.UserBashEvent, ctx: *types.ExtensionContext) !?types.UserBashEventResult {
            _ = event;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.calls += 1;
            return null;
        }
    };

    var first = State{ .allocator = allocator };
    defer first.deinit();
    var second = State{ .allocator = allocator, .output = "handled by second\n" };
    defer second.deinit();
    var third = State{ .allocator = allocator };
    defer third.deinit();
    const first_handlers = [_]types.UserBashHandler{.{ .ptr = &first, .handler_fn = State.nullHandler }};
    const second_handlers = [_]types.UserBashHandler{.{ .ptr = &second, .handler_fn = State.resultHandler }};
    const third_handlers = [_]types.UserBashHandler{.{ .ptr = &third, .handler_fn = State.lateHandler }};
    const extensions = [_]types.Extension{
        testExtensionWithUserBash("/tmp/first.zig", &first_handlers),
        testExtensionWithUserBash("/tmp/second.zig", &second_handlers),
        testExtensionWithUserBash("/tmp/third.zig", &third_handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    try std.testing.expect(runner.hasHandlers(.user_bash));
    var result = (try runner.emitUserBash(.{
        .command = "echo hi",
        .exclude_from_context = true,
        .cwd = "/work",
    })).?;
    defer if (result.result) |*bash_result| bash_result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expect(first.seen_excluded);
    try std.testing.expectEqualStrings("echo hi", first.seen_command.?);
    try std.testing.expectEqualStrings("/work", first.seen_cwd.?);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    try std.testing.expectEqual(@as(usize, 0), third.calls);
    try std.testing.expectEqualStrings("handled by second\n", result.result.?.output);
}

test "extension runner user_bash reports handler errors and continues" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const State = struct {
        allocator: std.mem.Allocator,
        errors: usize = 0,

        fn failing(ptr: ?*anyopaque, event: types.UserBashEvent, ctx: *types.ExtensionContext) !?types.UserBashEventResult {
            _ = ptr;
            _ = event;
            _ = ctx;
            return error.UserBashBoom;
        }

        fn valid(ptr: ?*anyopaque, event: types.UserBashEvent, ctx: *types.ExtensionContext) !?types.UserBashEventResult {
            _ = event;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            return .{ .result = .{
                .output = try state.allocator.dupe(u8, "after error"),
                .exit_code = 0,
                .cancelled = false,
                .truncated = false,
            } };
        }

        fn onError(ptr: ?*anyopaque, err: types.ExtensionError) void {
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            if (std.mem.eql(u8, err.event, "user_bash") and
                std.mem.eql(u8, err.@"error", "UserBashBoom"))
            {
                state.errors += 1;
            }
        }
    };

    var state = State{ .allocator = allocator };
    const failing_handlers = [_]types.UserBashHandler{.{ .handler_fn = State.failing }};
    const valid_handlers = [_]types.UserBashHandler{.{ .ptr = &state, .handler_fn = State.valid }};
    const extensions = [_]types.Extension{
        testExtensionWithUserBash("/tmp/failing.zig", &failing_handlers),
        testExtensionWithUserBash("/tmp/valid.zig", &valid_handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    try runner.onError(.{ .ptr = &state, .call_fn = State.onError });

    var result = (try runner.emitUserBash(.{
        .command = "pwd",
        .cwd = "/tmp",
    })).?;
    defer if (result.result) |*bash_result| bash_result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), state.errors);
    try std.testing.expectEqualStrings("after error", result.result.?.output);
}

test "extension runner message_end returns null for no handlers undefined and missing message" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "base" } }};
    const message = types.AgentMessage{ .assistant = .{
        .content = &content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
    } };

    var empty_runner = ExtensionRunner.init(allocator, &.{}, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer empty_runner.deinit();
    try std.testing.expect((try empty_runner.emitMessageEndAlloc(allocator, .{ .message = message })) == null);

    const State = struct {
        return_empty: bool = false,
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            if (!state.return_empty) return null;
            return std.json.Value{ .object = .empty };
        }
    };
    var undefined_state = State{ .allocator = arena.allocator() };
    const undefined_handlers = [_]types.ExtensionHandler{.{
        .ptr = &undefined_state,
        .event_name = .message_end,
        .handler_fn = State.handler,
    }};
    const undefined_extensions = [_]types.Extension{
        testExtension("/tmp/message-undefined.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &undefined_handlers),
    };
    var undefined_runner = ExtensionRunner.init(allocator, &undefined_extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer undefined_runner.deinit();
    try std.testing.expect((try undefined_runner.emitMessageEndAlloc(allocator, .{ .message = message })) == null);

    var empty_state = State{ .return_empty = true, .allocator = arena.allocator() };
    const empty_handlers = [_]types.ExtensionHandler{.{
        .ptr = &empty_state,
        .event_name = .message_end,
        .handler_fn = State.handler,
    }};
    const empty_extensions = [_]types.Extension{
        testExtension("/tmp/message-empty.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &empty_handlers),
    };
    var missing_message_runner = ExtensionRunner.init(allocator, &empty_extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer missing_message_runner.deinit();
    try std.testing.expect((try missing_message_runner.emitMessageEndAlloc(allocator, .{ .message = message })) == null);
}

test "extension runner message_end chains assistant replacements and usage cost overrides" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        suffix: []const u8,
        cost_total: f64,
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            const assistant = event_value.message_end.message.assistant;
            const text = assistant.content[0].text.text;
            const next_text = try std.fmt.allocPrint(state.allocator, "{s}{s}", .{ text, state.suffix });
            var object = std.json.Value{ .object = .empty };
            try putJsonValue(
                state.allocator,
                &object,
                "message",
                try assistantMessageJsonAlloc(state.allocator, next_text, state.cost_total),
            );
            return object;
        }
    };
    var first = State{ .suffix = " first", .cost_total = 0.111, .allocator = arena.allocator() };
    var second = State{ .suffix = " second", .cost_total = 0.123, .allocator = arena.allocator() };
    const handlers_a = [_]types.ExtensionHandler{.{
        .ptr = &first,
        .event_name = .message_end,
        .handler_fn = State.handler,
    }};
    const handlers_b = [_]types.ExtensionHandler{.{
        .ptr = &second,
        .event_name = .message_end,
        .handler_fn = State.handler,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/message-a.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_a),
        testExtension("/tmp/message-b.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_b),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "base" } }};
    const message = types.AgentMessage{ .assistant = .{
        .content = &content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
    } };
    var result = (try runner.emitMessageEndAlloc(allocator, .{ .message = message })).?;
    defer result.deinit();
    try std.testing.expectEqualStrings("base first second", result.message.assistant.content[0].text.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.123), result.message.assistant.usage.cost.total, 0.000001);
    try std.testing.expectEqual(@as(u64, 10), result.message.assistant.usage.total_tokens);
}

test "extension runner message_end rejects role changes and continues later handlers" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        errors: usize = 0,
        allocator: std.mem.Allocator,

        fn invalid(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            var object = std.json.Value{ .object = .empty };
            try putJsonValue(state.allocator, &object, "message", try userMessageJsonAlloc(state.allocator, "not assistant"));
            return object;
        }

        fn valid(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            const text = event_value.message_end.message.assistant.content[0].text.text;
            var object = std.json.Value{ .object = .empty };
            try putJsonValue(state.allocator, &object, "message", try assistantMessageJsonAlloc(state.allocator, text, 0.456));
            return object;
        }

        fn onError(ptr: ?*anyopaque, err: types.ExtensionError) void {
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            if (std.mem.eql(u8, err.@"error", "message_end handlers must return a message with the same role")) state.errors += 1;
        }
    };
    var state = State{ .allocator = arena.allocator() };
    const invalid_handlers = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .message_end,
        .handler_fn = State.invalid,
    }};
    const valid_handlers = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .message_end,
        .handler_fn = State.valid,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/message-invalid.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &invalid_handlers),
        testExtension("/tmp/message-valid.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &valid_handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    try runner.onError(.{ .ptr = &state, .call_fn = State.onError });

    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "base" } }};
    const message = types.AgentMessage{ .assistant = .{
        .content = &content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
    } };
    var result = (try runner.emitMessageEndAlloc(allocator, .{ .message = message })).?;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.errors);
    try std.testing.expectEqualStrings("base", result.message.assistant.content[0].text.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.456), result.message.assistant.usage.cost.total, 0.000001);
}

test "extension runner message_end catches handler errors and continues" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        errors: usize = 0,
        allocator: std.mem.Allocator,

        fn failing(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ptr;
            _ = event_value;
            _ = ctx;
            return error.MessageEndBoom;
        }

        fn valid(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            var object = std.json.Value{ .object = .empty };
            try putJsonValue(state.allocator, &object, "message", try assistantMessageJsonAlloc(state.allocator, "after error", 0.789));
            return object;
        }

        fn onError(ptr: ?*anyopaque, err: types.ExtensionError) void {
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            if (std.mem.eql(u8, err.@"error", "MessageEndBoom")) state.errors += 1;
        }
    };
    var state = State{ .allocator = arena.allocator() };
    const failing_handlers = [_]types.ExtensionHandler{.{
        .event_name = .message_end,
        .handler_fn = State.failing,
    }};
    const valid_handlers = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .message_end,
        .handler_fn = State.valid,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/message-failing.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &failing_handlers),
        testExtension("/tmp/message-after-error.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &valid_handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    try runner.onError(.{ .ptr = &state, .call_fn = State.onError });

    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "base" } }};
    const message = types.AgentMessage{ .assistant = .{
        .content = &content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
    } };
    var result = (try runner.emitMessageEndAlloc(allocator, .{ .message = message })).?;
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.errors);
    try std.testing.expectEqualStrings("after error", result.message.assistant.content[0].text.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.789), result.message.assistant.usage.cost.total, 0.000001);
}

test "extension runner flushes queued provider registrations through the model registry" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const provider_models = [_]types.ProviderModelConfig{.{
        .id = "instant-model",
        .name = "Instant Model",
        .api = "openai-completions",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{},
        .context_window = 128_000,
        .max_tokens = 4096,
    }};
    try harness.runtime.registerProvider("instant-provider", .{
        .base_url = "https://provider.test/v1",
        .api_key = "provider-test-key",
        .api = "openai-completions",
        .models = &provider_models,
    }, "/tmp/provider.zig");
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.pending_provider_registrations.items.len);

    var runner = ExtensionRunner.init(allocator, &.{}, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    runner.bindCore(.{}, .{}, null);

    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pending_provider_registrations.items.len);
    try std.testing.expect(harness.registry.find("instant-provider", "instant-model") != null);
    try harness.runtime.unregisterProvider("instant-provider");
    try std.testing.expect(harness.registry.find("instant-provider", "instant-model") == null);
}

test "extension runner reports invalid queued provider registrations" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const State = struct {
        saw_api_required: bool = false,

        fn onError(ptr: ?*anyopaque, err: types.ExtensionError) void {
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.saw_api_required = std.mem.indexOf(u8, err.@"error", "\"api\" is required") != null;
        }
    };
    var state = State{};
    var stream_context: u8 = 0;
    try harness.runtime.registerProvider("broken-provider", .{
        .stream_simple = .{ .context = &stream_context, .stream_fn = missingSimpleStream },
    }, "/tmp/broken.zig");

    var runner = ExtensionRunner.init(allocator, &.{}, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    try runner.onError(.{ .ptr = &state, .call_fn = State.onError });
    runner.bindCore(.{}, .{}, null);

    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pending_provider_registrations.items.len);
    try std.testing.expect(state.saw_api_required);
}

test "extension runner input returns continue for no handlers undefined and explicit continue" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    var empty_runner = ExtensionRunner.init(allocator, &.{}, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer empty_runner.deinit();
    var no_handlers = try empty_runner.emitInputAlloc(allocator, "x", &.{}, .interactive, null);
    defer no_handlers.deinit();
    try std.testing.expectEqual(types.InputEventResult{ .@"continue" = {} }, no_handlers.action);

    const State = struct {
        action: ?[]const u8 = null,
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            const action = state.action orelse return null;
            var object = std.json.Value{ .object = .empty };
            try putJsonString(state.allocator, &object, "action", action);
            return object;
        }
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var undefined_state = State{ .allocator = arena.allocator() };
    const undefined_handlers = [_]types.ExtensionHandler{.{
        .ptr = &undefined_state,
        .event_name = .input,
        .handler_fn = State.handler,
    }};
    const undefined_extensions = [_]types.Extension{
        testExtension("/tmp/undefined.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &undefined_handlers),
    };
    var undefined_runner = ExtensionRunner.init(allocator, &undefined_extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer undefined_runner.deinit();
    var undefined_result = try undefined_runner.emitInputAlloc(allocator, "x", &.{}, .interactive, null);
    defer undefined_result.deinit();
    try std.testing.expectEqual(types.InputEventResult{ .@"continue" = {} }, undefined_result.action);

    var continue_state = State{ .action = "continue", .allocator = arena.allocator() };
    const continue_handlers = [_]types.ExtensionHandler{.{
        .ptr = &continue_state,
        .event_name = .input,
        .handler_fn = State.handler,
    }};
    const continue_extensions = [_]types.Extension{
        testExtension("/tmp/continue.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &continue_handlers),
    };
    var continue_runner = ExtensionRunner.init(allocator, &continue_extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer continue_runner.deinit();
    var continue_result = try continue_runner.emitInputAlloc(allocator, "x", &.{}, .interactive, null);
    defer continue_result.deinit();
    try std.testing.expectEqual(types.InputEventResult{ .@"continue" = {} }, continue_result.action);
}

test "extension runner input transforms text and preserves images when omitted" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            const transformed = try std.fmt.allocPrint(state.allocator, "T:{s}", .{event_value.input.text});
            var object = std.json.Value{ .object = .empty };
            try putJsonString(state.allocator, &object, "action", "transform");
            try putJsonString(state.allocator, &object, "text", transformed);
            return object;
        }
    };
    var state = State{ .allocator = arena.allocator() };
    const handlers = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .input,
        .handler_fn = State.handler,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/input.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    const images = [_]ai.ImageContent{.{ .data = "orig", .mime_type = "image/png" }};

    var result = try runner.emitInputAlloc(allocator, "hi", &images, .interactive, null);
    defer result.deinit();
    try std.testing.expect(result.action == .transform);
    try std.testing.expectEqualStrings("T:hi", result.action.transform.text);
    try std.testing.expectEqual(@as(usize, 1), result.action.transform.images.len);
    try std.testing.expectEqualStrings("orig", result.action.transform.images[0].data);
    try std.testing.expect(result.owned_images == null);
}

test "extension runner input transforms and replaces images when provided" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            const next_images = [_]ai.ImageContent{.{ .data = "new", .mime_type = "image/jpeg" }};
            var object = std.json.Value{ .object = .empty };
            try putJsonString(state.allocator, &object, "action", "transform");
            try putJsonString(state.allocator, &object, "text", "X");
            try putJsonValue(state.allocator, &object, "images", try imageArrayJsonAlloc(state.allocator, &next_images));
            return object;
        }
    };
    var state = State{ .allocator = arena.allocator() };
    const handlers = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .input,
        .handler_fn = State.handler,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/input-images.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    const images = [_]ai.ImageContent{.{ .data = "orig", .mime_type = "image/png" }};

    var result = try runner.emitInputAlloc(allocator, "hi", &images, .interactive, null);
    defer result.deinit();
    try std.testing.expect(result.action == .transform);
    try std.testing.expectEqualStrings("X", result.action.transform.text);
    try std.testing.expectEqual(@as(usize, 1), result.action.transform.images.len);
    try std.testing.expectEqualStrings("new", result.action.transform.images[0].data);
    try std.testing.expectEqualStrings("image/jpeg", result.action.transform.images[0].mime_type);
    try std.testing.expect(result.owned_images != null);
}

test "extension runner input chains transforms across multiple handlers" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        suffix: []const u8,
        allocator: std.mem.Allocator,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            const transformed = try std.fmt.allocPrint(state.allocator, "{s}{s}", .{ event_value.input.text, state.suffix });
            var object = std.json.Value{ .object = .empty };
            try putJsonString(state.allocator, &object, "action", "transform");
            try putJsonString(state.allocator, &object, "text", transformed);
            return object;
        }
    };
    var first = State{ .suffix = "[1]", .allocator = arena.allocator() };
    var second = State{ .suffix = "[2]", .allocator = arena.allocator() };
    const handlers_a = [_]types.ExtensionHandler{.{
        .ptr = &first,
        .event_name = .input,
        .handler_fn = State.handler,
    }};
    const handlers_b = [_]types.ExtensionHandler{.{
        .ptr = &second,
        .event_name = .input,
        .handler_fn = State.handler,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/input-a.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_a),
        testExtension("/tmp/input-b.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_b),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    var result = try runner.emitInputAlloc(allocator, "X", &.{}, .interactive, null);
    defer result.deinit();
    try std.testing.expect(result.action == .transform);
    try std.testing.expectEqualStrings("X[1][2]", result.action.transform.text);
    try std.testing.expectEqual(@as(usize, 0), result.action.transform.images.len);
}

test "extension runner input handled short-circuits subsequent handlers" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const State = struct {
        called: bool = false,
        allocator: std.mem.Allocator,

        fn handled(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            var object = std.json.Value{ .object = .empty };
            try putJsonString(state.allocator, &object, "action", "handled");
            return object;
        }

        fn later(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = event_value;
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.called = true;
            return null;
        }
    };
    var state = State{ .allocator = arena.allocator() };
    const handlers_a = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .input,
        .handler_fn = State.handled,
    }};
    const handlers_b = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .input,
        .handler_fn = State.later,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/input-handled.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_a),
        testExtension("/tmp/input-later.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers_b),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    var result = try runner.emitInputAlloc(allocator, "X", &.{}, .interactive, null);
    defer result.deinit();
    try std.testing.expectEqual(types.InputEventResult{ .handled = {} }, result.action);
    try std.testing.expect(!state.called);
}

test "extension runner input passes source and streaming behavior" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const State = struct {
        source: ?types.InputSource = null,
        streaming_behavior: ?types.StreamingBehavior = null,

        fn handler(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ctx;
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            state.source = event_value.input.source;
            state.streaming_behavior = event_value.input.streaming_behavior;
            return null;
        }
    };
    var state = State{};
    const handlers = [_]types.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .input,
        .handler_fn = State.handler,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/input-source.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();

    inline for (.{ types.InputSource.interactive, types.InputSource.rpc, types.InputSource.extension }) |source| {
        var result = try runner.emitInputAlloc(allocator, "x", &.{}, source, null);
        defer result.deinit();
        try std.testing.expectEqual(source, state.source.?);
        try std.testing.expectEqual(@as(?types.StreamingBehavior, null), state.streaming_behavior);
    }
    var steer = try runner.emitInputAlloc(allocator, "x", &.{}, .interactive, .steer);
    defer steer.deinit();
    try std.testing.expectEqual(types.StreamingBehavior.steer, state.streaming_behavior.?);
    var follow_up = try runner.emitInputAlloc(allocator, "x", &.{}, .interactive, .follow_up);
    defer follow_up.deinit();
    try std.testing.expectEqual(types.StreamingBehavior.follow_up, state.streaming_behavior.?);
}

test "extension runner input catches handler errors and continues" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();

    const State = struct {
        errors: usize = 0,

        fn failing(ptr: ?*anyopaque, event_value: types.ExtensionEvent, ctx: *types.ExtensionContext) !?std.json.Value {
            _ = ptr;
            _ = event_value;
            _ = ctx;
            return error.Boom;
        }

        fn onError(ptr: ?*anyopaque, err: types.ExtensionError) void {
            const state: *@This() = @ptrCast(@alignCast(ptr.?));
            if (std.mem.eql(u8, err.@"error", "Boom")) state.errors += 1;
        }
    };
    var state = State{};
    const handlers = [_]types.ExtensionHandler{.{
        .event_name = .input,
        .handler_fn = State.failing,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/input-error.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    try runner.onError(.{ .ptr = &state, .call_fn = State.onError });

    var result = try runner.emitInputAlloc(allocator, "x", &.{}, .interactive, null);
    defer result.deinit();
    try std.testing.expectEqual(types.InputEventResult{ .@"continue" = {} }, result.action);
    try std.testing.expectEqual(@as(usize, 1), state.errors);
}

test "extension runner hasHandlers recognizes input registrations" {
    const allocator = std.testing.allocator;
    var harness = try RunnerHarness.init(allocator);
    defer harness.deinit();
    var empty_runner = ExtensionRunner.init(allocator, &.{}, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer empty_runner.deinit();
    try std.testing.expect(!empty_runner.hasHandlers(.input));
    try std.testing.expect(!empty_runner.hasHandlers(.message_end));

    const input_handlers = [_]types.ExtensionHandler{.{
        .event_name = .input,
        .handler_fn = TestCallbacks.event,
    }};
    const message_handlers = [_]types.ExtensionHandler{.{
        .event_name = .message_end,
        .handler_fn = TestCallbacks.event,
    }};
    const extensions = [_]types.Extension{
        testExtension("/tmp/input-handler.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &input_handlers),
        testExtension("/tmp/message-handler.zig", &.{}, &.{}, &.{}, &.{}, &.{}, &message_handlers),
    };
    var runner = ExtensionRunner.init(allocator, &extensions, harness.runtime, "/tmp", harness.sessions, harness.registry);
    defer runner.deinit();
    try std.testing.expect(runner.hasHandlers(.input));
    try std.testing.expect(runner.hasHandlers(.message_end));
}

fn missingSimpleStream(
    context: *anyopaque,
    model: ai.Model,
    prompt: ai.Context,
    options: ?ai.SimpleStreamOptions,
) anyerror!ai.StreamResult {
    _ = context;
    _ = model;
    _ = prompt;
    _ = options;
    return error.UnexpectedStream;
}
