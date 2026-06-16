const std = @import("std");

const ai = @import("bulb_ai");
const agent_session_runtime = @import("agent_session_runtime.zig");
const bash_executor = @import("bash_executor.zig");
const bash_tool = @import("tools/bash.zig");
const compaction_mod = @import("compaction.zig");
const extensions = @import("extensions/root.zig");
const model_registry = @import("model_registry.zig");
const rpc_runtime_host = @import("rpc_runtime_host.zig");
const rpc_types = @import("rpc_types.zig");
const session_events = @import("session_events.zig");
const session_manager = @import("session_manager.zig");
const session_stats = @import("session_stats.zig");

const stdin_buffer_bytes = 64 * 1024;
const max_rpc_jsonl_line_bytes = 16 * 1024 * 1024;
const default_session_id = "rpc-session";

pub const RpcModeOptions = struct {
    io: ?std.Io = null,
    model_registry: ?*model_registry.ModelRegistry = null,
    session_manager: ?*session_manager.SessionManager = null,
    session_runtime: ?*agent_session_runtime.AgentSessionRuntime = null,
    session_replay: ?*session_events.AgentSessionReplay = null,
    bash_operations: ?bash_executor.BashOperations = null,
    initial_model: ?*const ai.Model = null,
    static_models: []const ai.Model = &.{},
    thinking_level: ai.ThinkingLevel = .medium,
    session_id: []const u8 = default_session_id,
};

pub const RpcMode = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    model_registry: ?*model_registry.ModelRegistry,
    session_manager: ?*session_manager.SessionManager,
    session_runtime: ?*agent_session_runtime.AgentSessionRuntime,
    session_replay: ?*session_events.AgentSessionReplay,
    bash_operations: ?bash_executor.BashOperations,
    static_models: []const ai.Model,
    state: rpc_types.RpcSessionState,
    auto_retry_enabled: bool = true,
    session_name_storage: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, options: RpcModeOptions) RpcMode {
        return .{
            .allocator = allocator,
            .io = options.io orelse std.Io.Threaded.global_single_threaded.io(),
            .model_registry = options.model_registry,
            .session_manager = options.session_manager orelse if (options.session_runtime) |runtime| runtime.session.getSessionManager() else null,
            .session_runtime = options.session_runtime,
            .session_replay = options.session_replay,
            .bash_operations = options.bash_operations,
            .static_models = options.static_models,
            .state = .{
                .model = options.initial_model,
                .thinking_level = options.thinking_level,
                .session_file = if (options.session_manager) |manager| manager.getSessionFile() else if (options.session_runtime) |runtime| runtime.session.getSessionManager().getSessionFile() else null,
                .session_id = if (options.session_manager) |manager| manager.getSessionId() else if (options.session_runtime) |runtime| runtime.session.getSessionManager().getSessionId() else options.session_id,
            },
        };
    }

    pub fn deinit(self: *RpcMode) void {
        if (self.session_name_storage) |name| self.allocator.free(name);
        self.* = undefined;
    }

    pub fn run(self: *RpcMode, stdout: *std.Io.Writer) !void {
        var stdin_buffer: [stdin_buffer_bytes]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(self.io, &stdin_buffer);

        while (true) {
            const line = self.readStdinLineAlloc(&stdin_reader) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |read_err| return read_err,
            };
            defer self.allocator.free(line);

            const response = try self.handleLineAlloc(line);
            if (response) |line_response| {
                defer self.allocator.free(line_response);
                try stdout.writeAll(line_response);
                try stdout.flush();
            }
        }
    }

    pub fn handleLineAlloc(self: *RpcMode, line: []const u8) !?[]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch |err| {
            const message = try std.fmt.allocPrint(self.allocator, "Failed to parse command: {s}", .{@errorName(err)});
            defer self.allocator.free(message);
            return try rpc_types.errorLineAlloc(
                self.allocator,
                null,
                "parse",
                message,
            );
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return try rpc_types.errorLineAlloc(self.allocator, null, "unknown", "RPC command must be a JSON object");
        }

        const object = parsed.value.object;
        const command_type = optionalString(object, "type") orelse {
            return try rpc_types.errorLineAlloc(self.allocator, optionalString(object, "id"), "unknown", "RPC command missing type");
        };

        if (std.mem.eql(u8, command_type, "extension_ui_response")) return null;

        const id = optionalString(object, "id");
        return try self.handleCommandAlloc(id, command_type, object);
    }

    fn handleCommandAlloc(
        self: *RpcMode,
        id: ?[]const u8,
        command_type: []const u8,
        object: std.json.ObjectMap,
    ) ![]u8 {
        if (std.mem.eql(u8, command_type, "get_state")) {
            try self.refreshSessionState();
            const data = try rpc_types.stateDataJsonAlloc(self.allocator, self.state);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_state", data);
        }

        if (std.mem.eql(u8, command_type, "get_available_models")) {
            const data = try self.availableModelsDataJsonAlloc();
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_available_models", data);
        }

        if (std.mem.eql(u8, command_type, "set_model")) {
            const provider = optionalString(object, "provider") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_model", "set_model requires provider");
            };
            const model_id = optionalString(object, "modelId") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_model", "set_model requires modelId");
            };
            const model = try self.findAvailableModel(provider, model_id) orelse {
                const message = try std.fmt.allocPrint(self.allocator, "Model not found: {s}/{s}", .{ provider, model_id });
                defer self.allocator.free(message);
                return rpc_types.errorLineAlloc(self.allocator, id, "set_model", message);
            };
            self.state.model = model;
            if (self.session_manager) |manager| {
                _ = manager.appendModelChange(self.io, model.provider, model.id) catch |err| {
                    return self.commandErrorLineAlloc(id, "set_model", err);
                };
            }
            const data = try rpc_types.modelDataJsonAlloc(self.allocator, model.*);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "set_model", data);
        }

        if (std.mem.eql(u8, command_type, "cycle_model")) {
            const model = try self.cycleModel();
            if (model) |selected| {
                if (self.session_manager) |manager| {
                    _ = manager.appendModelChange(self.io, selected.provider, selected.id) catch |err| {
                        return self.commandErrorLineAlloc(id, "cycle_model", err);
                    };
                }
            }
            const data = try rpc_types.cycleModelDataJsonAlloc(self.allocator, model, self.state.thinking_level);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "cycle_model", data);
        }

        if (std.mem.eql(u8, command_type, "set_thinking_level")) {
            const level_name = optionalString(object, "level") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_thinking_level", "set_thinking_level requires level");
            };
            self.state.thinking_level = rpc_types.parseThinkingLevel(level_name) orelse {
                const message = try std.fmt.allocPrint(self.allocator, "Invalid thinking level: {s}", .{level_name});
                defer self.allocator.free(message);
                return rpc_types.errorLineAlloc(self.allocator, id, "set_thinking_level", message);
            };
            if (self.session_manager) |manager| {
                _ = manager.appendThinkingLevelChange(
                    self.io,
                    rpc_types.thinkingLevelName(self.state.thinking_level),
                ) catch |err| return self.commandErrorLineAlloc(id, "set_thinking_level", err);
            }
            return rpc_types.successLineAlloc(self.allocator, id, "set_thinking_level", null);
        }

        if (std.mem.eql(u8, command_type, "cycle_thinking_level")) {
            self.state.thinking_level = nextThinkingLevel(self.state.thinking_level);
            if (self.session_manager) |manager| {
                _ = manager.appendThinkingLevelChange(
                    self.io,
                    rpc_types.thinkingLevelName(self.state.thinking_level),
                ) catch |err| return self.commandErrorLineAlloc(id, "cycle_thinking_level", err);
            }
            const data = try rpc_types.levelDataJsonAlloc(self.allocator, self.state.thinking_level);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "cycle_thinking_level", data);
        }

        if (std.mem.eql(u8, command_type, "set_steering_mode")) {
            const mode_name = optionalString(object, "mode") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_steering_mode", "set_steering_mode requires mode");
            };
            self.state.steering_mode = rpc_types.parseQueueMode(mode_name) orelse {
                const message = try std.fmt.allocPrint(self.allocator, "Invalid steering mode: {s}", .{mode_name});
                defer self.allocator.free(message);
                return rpc_types.errorLineAlloc(self.allocator, id, "set_steering_mode", message);
            };
            if (self.session_replay) |replay| replay.setSteeringMode(sessionQueueMode(self.state.steering_mode));
            return rpc_types.successLineAlloc(self.allocator, id, "set_steering_mode", null);
        }

        if (std.mem.eql(u8, command_type, "set_follow_up_mode")) {
            const mode_name = optionalString(object, "mode") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_follow_up_mode", "set_follow_up_mode requires mode");
            };
            self.state.follow_up_mode = rpc_types.parseQueueMode(mode_name) orelse {
                const message = try std.fmt.allocPrint(self.allocator, "Invalid follow-up mode: {s}", .{mode_name});
                defer self.allocator.free(message);
                return rpc_types.errorLineAlloc(self.allocator, id, "set_follow_up_mode", message);
            };
            if (self.session_replay) |replay| replay.setFollowUpMode(sessionQueueMode(self.state.follow_up_mode));
            return rpc_types.successLineAlloc(self.allocator, id, "set_follow_up_mode", null);
        }

        if (std.mem.eql(u8, command_type, "set_auto_compaction")) {
            self.state.auto_compaction_enabled = optionalBool(object, "enabled") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_auto_compaction", "set_auto_compaction requires enabled");
            };
            if (self.session_replay) |replay| {
                if (replay.auto_compaction) |*config| {
                    config.settings.enabled = self.state.auto_compaction_enabled;
                }
            }
            return rpc_types.successLineAlloc(self.allocator, id, "set_auto_compaction", null);
        }

        if (std.mem.eql(u8, command_type, "set_auto_retry")) {
            self.auto_retry_enabled = optionalBool(object, "enabled") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_auto_retry", "set_auto_retry requires enabled");
            };
            return rpc_types.successLineAlloc(self.allocator, id, "set_auto_retry", null);
        }

        if (std.mem.eql(u8, command_type, "abort_retry")) {
            if (self.session_replay) |replay| {
                var collector = ReplayEventCollector.init(self.allocator);
                defer collector.deinit();
                const subscription = try replay.bridge.subscribeWithHandle(collector.listener());
                defer _ = replay.bridge.unsubscribe(subscription);
                _ = replay.abortRetry();
                const response = try rpc_types.successLineAlloc(self.allocator, id, command_type, null);
                defer self.allocator.free(response);
                try collector.appendLine(response);
                return collector.toOwnedSlice();
            }
            return rpc_types.successLineAlloc(self.allocator, id, command_type, null);
        }

        if (std.mem.eql(u8, command_type, "abort") or
            std.mem.eql(u8, command_type, "abort_bash"))
        {
            return rpc_types.successLineAlloc(self.allocator, id, command_type, null);
        }

        if (std.mem.eql(u8, command_type, "get_session_stats")) {
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "get_session_stats");
            var context = manager.buildSessionContextAlloc(self.allocator) catch |err|
                return self.commandErrorLineAlloc(id, "get_session_stats", err);
            defer context.deinit();
            const stats = session_stats.getSessionStatsAlloc(self.allocator, .{
                .session_manager = manager,
                .messages = context.messages,
                .model = if (self.state.model) |model| model.* else null,
            }) catch |err| return self.commandErrorLineAlloc(id, "get_session_stats", err);
            const data = try rpc_types.sessionStatsDataJsonAlloc(self.allocator, stats);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_session_stats", data);
        }

        if (std.mem.eql(u8, command_type, "get_messages")) {
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "get_messages");
            var context = manager.buildSessionContextAlloc(self.allocator) catch |err|
                return self.commandErrorLineAlloc(id, "get_messages", err);
            defer context.deinit();
            const data = try rpc_types.messagesDataJsonAlloc(self.allocator, context.messages);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_messages", data);
        }

        if (std.mem.eql(u8, command_type, "get_fork_messages")) {
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "get_fork_messages");
            const fork_messages = self.forkMessagesAlloc(manager) catch |err|
                return self.commandErrorLineAlloc(id, "get_fork_messages", err);
            defer deinitForkMessages(self.allocator, fork_messages);
            const data = try rpc_types.forkMessagesDataJsonAlloc(self.allocator, fork_messages);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_fork_messages", data);
        }

        if (std.mem.eql(u8, command_type, "get_last_assistant_text")) {
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "get_last_assistant_text");
            const text = self.lastAssistantTextAlloc(manager) catch |err|
                return self.commandErrorLineAlloc(id, "get_last_assistant_text", err);
            defer if (text) |value| self.allocator.free(value);
            const data = try rpc_types.lastAssistantTextDataJsonAlloc(self.allocator, text);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_last_assistant_text", data);
        }

        if (std.mem.eql(u8, command_type, "set_session_name")) {
            const raw_name = optionalString(object, "name") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_session_name", "set_session_name requires name");
            };
            const name = std.mem.trim(u8, raw_name, " \t\r\n");
            if (name.len == 0) return rpc_types.errorLineAlloc(self.allocator, id, "set_session_name", "Session name cannot be empty");
            if (self.session_manager) |manager| {
                _ = manager.appendSessionInfo(self.io, name) catch |err| {
                    return self.commandErrorLineAlloc(id, "set_session_name", err);
                };
                try self.refreshSessionState();
            } else {
                const copy = try self.allocator.dupe(u8, name);
                if (self.session_name_storage) |previous| self.allocator.free(previous);
                self.session_name_storage = copy;
                self.state.session_name = copy;
            }
            return rpc_types.successLineAlloc(self.allocator, id, "set_session_name", null);
        }

        if (std.mem.eql(u8, command_type, "get_commands")) {
            const data = try self.commandsDataJsonAlloc();
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_commands", data);
        }

        if (std.mem.eql(u8, command_type, "new_session")) {
            if (self.session_runtime) |runtime| {
                var result = runtime.newSession(.{
                    .parent_session = optionalString(object, "parentSession"),
                }) catch |err| return self.commandErrorLineAlloc(id, "new_session", err);
                defer result.deinit(self.allocator);
                try self.refreshSessionState();
                const data = try rpc_types.cancelledDataJsonAlloc(self.allocator, result.cancelled);
                defer self.allocator.free(data);
                return rpc_types.successLineAlloc(self.allocator, id, "new_session", data);
            }
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "new_session");
            _ = manager.newSession(self.io, .{
                .parent_session = optionalString(object, "parentSession"),
            }) catch |err| return self.commandErrorLineAlloc(id, "new_session", err);
            try self.refreshSessionState();
            const data = try rpc_types.cancelledDataJsonAlloc(self.allocator, false);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "new_session", data);
        }

        if (std.mem.eql(u8, command_type, "switch_session")) {
            const session_path = optionalString(object, "sessionPath") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "switch_session", "switch_session requires sessionPath");
            };
            if (self.session_runtime) |runtime| {
                var result = runtime.switchSession(session_path, .{}) catch |err|
                    return self.commandErrorLineAlloc(id, "switch_session", err);
                defer result.deinit(self.allocator);
                try self.refreshSessionState();
                const data = try rpc_types.cancelledDataJsonAlloc(self.allocator, result.cancelled);
                defer self.allocator.free(data);
                return rpc_types.successLineAlloc(self.allocator, id, "switch_session", data);
            }
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "switch_session");
            const next = session_manager.SessionManager.open(self.allocator, self.io, session_path, .{}) catch |err|
                return self.commandErrorLineAlloc(id, "switch_session", err);
            manager.deinit();
            manager.* = next;
            try self.refreshSessionState();
            const data = try rpc_types.cancelledDataJsonAlloc(self.allocator, false);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "switch_session", data);
        }

        if (std.mem.eql(u8, command_type, "fork")) {
            const entry_id = optionalString(object, "entryId") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "fork", "fork requires entryId");
            };
            if (self.session_runtime) |runtime| {
                var result = runtime.fork(entry_id, null) catch |err|
                    return self.commandErrorLineAlloc(id, "fork", err);
                defer result.deinit(self.allocator);
                try self.refreshSessionState();
                const data = try rpc_types.forkDataJsonAlloc(self.allocator, result.selected_text orelse "", result.cancelled);
                defer self.allocator.free(data);
                return rpc_types.successLineAlloc(self.allocator, id, "fork", data);
            }
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "fork");
            const selected_text = self.forkBefore(manager, entry_id) catch |err|
                return self.commandErrorLineAlloc(id, "fork", err);
            defer self.allocator.free(selected_text);
            try self.refreshSessionState();
            const data = try rpc_types.forkDataJsonAlloc(self.allocator, selected_text, false);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "fork", data);
        }

        if (std.mem.eql(u8, command_type, "clone")) {
            const manager = self.session_manager orelse
                return self.sessionRuntimeRequiredLineAlloc(id, "clone");
            const leaf_id = manager.getLeafId() orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "clone", "Cannot clone session: no current entry selected");
            };
            if (self.session_runtime) |runtime| {
                var result = runtime.fork(leaf_id, .{ .position = .at }) catch |err|
                    return self.commandErrorLineAlloc(id, "clone", err);
                defer result.deinit(self.allocator);
                try self.refreshSessionState();
                const data = try rpc_types.cancelledDataJsonAlloc(self.allocator, result.cancelled);
                defer self.allocator.free(data);
                return rpc_types.successLineAlloc(self.allocator, id, "clone", data);
            }
            _ = manager.createBranchedSession(self.io, leaf_id) catch |err|
                return self.commandErrorLineAlloc(id, "clone", err);
            try self.refreshSessionState();
            const data = try rpc_types.cancelledDataJsonAlloc(self.allocator, false);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "clone", data);
        }

        if (std.mem.eql(u8, command_type, "prompt")) {
            return self.promptWithReplayLineAlloc(id, object);
        }

        if (std.mem.eql(u8, command_type, "steer")) {
            return self.queueWithReplayLineAlloc(id, "steer", object, .steer);
        }

        if (std.mem.eql(u8, command_type, "follow_up")) {
            return self.queueWithReplayLineAlloc(id, "follow_up", object, .follow_up);
        }

        if (std.mem.eql(u8, command_type, "bash")) {
            return self.bashLineAlloc(id, object);
        }

        if (std.mem.eql(u8, command_type, "compact")) {
            return self.compactWithReplayLineAlloc(id, object);
        }

        if (std.mem.eql(u8, command_type, "export_html")) {
            return self.sessionRuntimeRequiredLineAlloc(id, command_type);
        }

        const message = try std.fmt.allocPrint(self.allocator, "Unknown command: {s}", .{command_type});
        defer self.allocator.free(message);
        return rpc_types.errorLineAlloc(self.allocator, null, command_type, message);
    }

    fn promptWithReplayLineAlloc(
        self: *RpcMode,
        id: ?[]const u8,
        object: std.json.ObjectMap,
    ) ![]u8 {
        const replay = self.session_replay orelse
            return self.sessionRuntimeRequiredLineAlloc(id, "prompt");
        const message = optionalString(object, "message") orelse {
            return rpc_types.errorLineAlloc(self.allocator, id, "prompt", "prompt requires message");
        };
        if (jsonArrayLen(object, "images") > 0) {
            return rpc_types.errorLineAlloc(self.allocator, id, "prompt", "prompt images require live AgentSession runtime integration");
        }

        var collector = ReplayEventCollector.init(self.allocator);
        defer collector.deinit();
        const subscription = try replay.bridge.subscribeWithHandle(collector.listener());
        defer _ = replay.bridge.unsubscribe(subscription);

        const response = try rpc_types.successLineAlloc(self.allocator, id, "prompt", null);
        defer self.allocator.free(response);
        try collector.appendLine(response);

        replay.prompt(self.io, message, self.timestampMs()) catch |err| {
            collector.clear();
            return self.commandErrorLineAlloc(id, "prompt", err);
        };
        try self.refreshSessionState();
        return collector.toOwnedSlice();
    }

    fn queueWithReplayLineAlloc(
        self: *RpcMode,
        id: ?[]const u8,
        command: []const u8,
        object: std.json.ObjectMap,
        delivery: session_events.CustomMessageDelivery,
    ) ![]u8 {
        const replay = self.session_replay orelse
            return self.sessionRuntimeRequiredLineAlloc(id, command);
        const message = optionalString(object, "message") orelse {
            const error_message = try std.fmt.allocPrint(self.allocator, "{s} requires message", .{command});
            defer self.allocator.free(error_message);
            return rpc_types.errorLineAlloc(self.allocator, id, command, error_message);
        };
        if (jsonArrayLen(object, "images") > 0) {
            const error_message = try std.fmt.allocPrint(
                self.allocator,
                "{s} images require live AgentSession runtime integration",
                .{command},
            );
            defer self.allocator.free(error_message);
            return rpc_types.errorLineAlloc(self.allocator, id, command, error_message);
        }

        var collector = ReplayEventCollector.init(self.allocator);
        defer collector.deinit();
        const subscription = try replay.bridge.subscribeWithHandle(collector.listener());
        defer _ = replay.bridge.unsubscribe(subscription);

        switch (delivery) {
            .steer => replay.steer(message, self.timestampMs()) catch |err| {
                collector.clear();
                return self.commandErrorLineAlloc(id, command, err);
            },
            .follow_up => replay.followUp(message, self.timestampMs()) catch |err| {
                collector.clear();
                return self.commandErrorLineAlloc(id, command, err);
            },
            .next_turn => unreachable,
        }
        self.state.pending_message_count = replay.pendingMessageCount();

        const response = try rpc_types.successLineAlloc(self.allocator, id, command, null);
        defer self.allocator.free(response);
        try collector.appendLine(response);
        return collector.toOwnedSlice();
    }

    fn bashLineAlloc(
        self: *RpcMode,
        id: ?[]const u8,
        object: std.json.ObjectMap,
    ) ![]u8 {
        const manager = self.session_manager orelse
            return self.sessionRuntimeRequiredLineAlloc(id, "bash");
        const command = optionalString(object, "command") orelse {
            return rpc_types.errorLineAlloc(self.allocator, id, "bash", "bash requires command");
        };
        const exclude_from_context = optionalBool(object, "excludeFromContext") orelse false;
        const operations = self.bash_operations orelse bash_tool.createLocalBashOperations(.{});

        var result = bash_executor.executeBashWithOperationsAlloc(
            self.allocator,
            self.io,
            command,
            manager.getCwd(),
            operations,
            .{},
        ) catch |err| return self.commandErrorLineAlloc(id, "bash", err);
        defer result.deinit(self.allocator);

        _ = manager.appendMessage(self.io, .{ .bash_execution = .{
            .command = command,
            .output = result.output,
            .exit_code = if (result.exit_code) |code| @intCast(code) else null,
            .cancelled = result.cancelled,
            .truncated = result.truncated,
            .full_output_path = result.full_output_path,
            .timestamp_ms = self.timestampMs(),
            .exclude_from_context = exclude_from_context,
        } }) catch |err| return self.commandErrorLineAlloc(id, "bash", err);
        try self.refreshSessionState();

        const data = try rpc_types.bashResultDataJsonAlloc(self.allocator, result);
        defer self.allocator.free(data);
        return rpc_types.successLineAlloc(self.allocator, id, "bash", data);
    }

    fn compactWithReplayLineAlloc(
        self: *RpcMode,
        id: ?[]const u8,
        object: std.json.ObjectMap,
    ) ![]u8 {
        const replay = self.session_replay orelse
            return self.sessionRuntimeRequiredLineAlloc(id, "compact");
        if (replay.auto_compaction == null) {
            return self.sessionRuntimeRequiredLineAlloc(id, "compact");
        }

        var collector = ReplayEventCollector.init(self.allocator);
        defer collector.deinit();
        const subscription = try replay.bridge.subscribeWithHandle(collector.listener());
        defer _ = replay.bridge.unsubscribe(subscription);

        var signal: ai.AbortSignal = .{};
        self.state.is_compacting = true;
        const result = replay.compactManual(
            self.io,
            optionalString(object, "customInstructions"),
            &signal,
        ) catch |err| {
            self.state.is_compacting = false;
            const response = try self.compactErrorLineAlloc(id, err);
            defer self.allocator.free(response);
            try collector.appendLine(response);
            return collector.toOwnedSlice();
        };
        self.state.is_compacting = false;
        try self.refreshSessionState();

        const data = try rpc_types.compactionResultDataJsonAlloc(self.allocator, result);
        defer self.allocator.free(data);
        const response = try rpc_types.successLineAlloc(self.allocator, id, "compact", data);
        defer self.allocator.free(response);
        try collector.appendLine(response);
        return collector.toOwnedSlice();
    }

    fn availableModelsDataJsonAlloc(self: *RpcMode) ![]u8 {
        if (self.model_registry) |registry| {
            const available = try registry.getAvailableAlloc(self.allocator);
            defer self.allocator.free(available);
            return rpc_types.availableModelsDataJsonAlloc(self.allocator, available);
        }

        const models = self.static_modelsOrGenerated();
        return rpc_types.allModelsDataJsonAlloc(self.allocator, models);
    }

    fn findAvailableModel(self: *RpcMode, provider: []const u8, model_id: []const u8) !?*const ai.Model {
        if (self.model_registry) |registry| {
            const available = try registry.getAvailableAlloc(self.allocator);
            defer self.allocator.free(available);
            for (available) |model| {
                if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) return model;
            }
            return null;
        }

        for (self.static_modelsOrGenerated()) |*model| {
            if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) return model;
        }
        return null;
    }

    fn cycleModel(self: *RpcMode) !?*const ai.Model {
        if (self.model_registry) |registry| {
            const available = try registry.getAvailableAlloc(self.allocator);
            defer self.allocator.free(available);
            const next = nextModelFromPointers(available, self.state.model) orelse return null;
            self.state.model = next;
            return next;
        }

        const models = self.static_modelsOrGenerated();
        const next = nextModelFromSlice(models, self.state.model) orelse return null;
        self.state.model = next;
        return next;
    }

    fn static_modelsOrGenerated(self: RpcMode) []const ai.Model {
        if (self.static_models.len > 0) return self.static_models;
        return ai.models.allModels();
    }

    fn commandsDataJsonAlloc(self: *RpcMode) ![]u8 {
        const runtime = self.session_runtime orelse return rpc_types.emptyCommandsDataJsonAlloc(self.allocator);
        var resolved = try runtime.session.getExtensionRunner().getRegisteredCommandsAlloc(self.allocator);
        defer resolved.deinit();

        const services = runtime.getServices();
        const prompts = services.resource_loader.getPrompts().prompts;
        const skills = services.resource_loader.getSkills().skills;
        var commands = try self.allocator.alloc(
            rpc_types.RpcSlashCommand,
            resolved.commands.len + prompts.len + skills.len,
        );
        defer self.allocator.free(commands);

        var skill_names: std.ArrayList([]u8) = .empty;
        defer {
            for (skill_names.items) |name| self.allocator.free(name);
            skill_names.deinit(self.allocator);
        }

        var index: usize = 0;
        for (resolved.commands) |command| {
            commands[index] = .{
                .name = command.invocation_name,
                .description = command.command.description,
                .source = .extension,
                .source_info = command.command.source_info,
            };
            index += 1;
        }
        for (prompts) |template| {
            commands[index] = .{
                .name = template.name,
                .description = template.description,
                .source = .prompt,
                .source_info = template.source_info,
            };
            index += 1;
        }
        for (skills) |skill| {
            const command_name = try std.fmt.allocPrint(self.allocator, "skill:{s}", .{skill.name});
            skill_names.append(self.allocator, command_name) catch |err| {
                self.allocator.free(command_name);
                return err;
            };
            commands[index] = .{
                .name = command_name,
                .description = skill.description,
                .source = .skill,
                .source_info = skill.source_info,
            };
            index += 1;
        }

        return rpc_types.commandsDataJsonAlloc(self.allocator, commands);
    }

    fn readStdinLineAlloc(self: *RpcMode, reader: *std.Io.File.Reader) ![]u8 {
        var line_writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer line_writer.deinit();

        _ = reader.interface.streamDelimiterLimit(
            &line_writer.writer,
            '\n',
            .limited(max_rpc_jsonl_line_bytes),
        ) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.WriteFailed => return error.OutOfMemory,
            error.StreamTooLong => return error.StreamTooLong,
        };

        const buffered = reader.interface.buffered();
        if (buffered.len > 0 and buffered[0] == '\n') {
            reader.interface.toss(1);
        } else if (line_writer.written().len == 0) {
            line_writer.deinit();
            return error.EndOfStream;
        }

        return line_writer.toOwnedSlice();
    }

    fn refreshSessionState(self: *RpcMode) !void {
        if (self.session_runtime) |runtime| {
            const manager = runtime.session.getSessionManager();
            self.session_manager = manager;
            if (self.session_replay) |replay| {
                if (replay.sessions != manager) self.session_replay = null;
            }
        }
        const manager = self.session_manager orelse return;
        self.state.session_file = manager.getSessionFile();
        self.state.session_id = manager.getSessionId();
        if (self.session_replay) |replay| {
            self.state.is_streaming = replay.is_streaming;
            self.state.pending_message_count = replay.pendingMessageCount();
            if (replay.auto_compaction) |config| {
                self.state.auto_compaction_enabled = config.settings.enabled;
            }
        }

        var context = try manager.buildSessionContextAlloc(self.allocator);
        defer context.deinit();
        self.state.message_count = context.messages.len;
        if (context.model) |session_model| {
            if (try self.findAvailableModel(session_model.provider, session_model.model_id)) |model| {
                self.state.model = model;
            }
        }
        if (sessionHasEntryType(manager, "thinking_level_change")) {
            if (rpc_types.parseThinkingLevel(context.thinking_level)) |level| {
                self.state.thinking_level = level;
            }
        }

        const name = try manager.getSessionName(self.allocator);
        if (self.session_name_storage) |previous| self.allocator.free(previous);
        self.session_name_storage = name;
        self.state.session_name = name;
    }

    fn sessionRuntimeRequiredLineAlloc(
        self: *RpcMode,
        id: ?[]const u8,
        command: []const u8,
    ) ![]u8 {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "RPC command {s} requires AgentSession runtime integration",
            .{command},
        );
        defer self.allocator.free(message);
        return rpc_types.errorLineAlloc(self.allocator, id, command, message);
    }

    fn commandErrorLineAlloc(
        self: *RpcMode,
        id: ?[]const u8,
        command: []const u8,
        err: anyerror,
    ) ![]u8 {
        return rpc_types.errorLineAlloc(self.allocator, id, command, @errorName(err));
    }

    fn compactErrorLineAlloc(self: *RpcMode, id: ?[]const u8, err: anyerror) ![]u8 {
        const message: []const u8 = switch (err) {
            error.AlreadyCompacted => "Already compacted",
            error.NothingToCompact => "Nothing to compact (session too small)",
            error.CompactionCancelled => "Compaction cancelled",
            error.CompactionAuthUnavailable => "Compaction failed: missing authentication",
            else => @errorName(err),
        };
        return rpc_types.errorLineAlloc(self.allocator, id, "compact", message);
    }

    fn timestampMs(self: *RpcMode) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    fn forkMessagesAlloc(
        self: *RpcMode,
        manager: *const session_manager.SessionManager,
    ) ![]rpc_types.ForkMessage {
        var result: std.ArrayList(rpc_types.ForkMessage) = .empty;
        errdefer {
            freeForkMessageItems(self.allocator, result.items);
            result.deinit(self.allocator);
        }

        for (manager.getEntries()) |entry| {
            if (entry.id == null or entry.entry_type == null or
                !std.mem.eql(u8, entry.entry_type.?, "message"))
            {
                continue;
            }
            const text = try userMessageTextFromEntryAlloc(self.allocator, entry.raw_json) orelse continue;
            errdefer self.allocator.free(text);
            if (text.len == 0) {
                self.allocator.free(text);
                continue;
            }
            const entry_id = try self.allocator.dupe(u8, entry.id.?);
            errdefer self.allocator.free(entry_id);
            try result.append(self.allocator, .{ .entry_id = entry_id, .text = text });
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn lastAssistantTextAlloc(
        self: *RpcMode,
        manager: *const session_manager.SessionManager,
    ) !?[]u8 {
        var context = try manager.buildSessionContextAlloc(self.allocator);
        defer context.deinit();

        var index = context.messages.len;
        while (index > 0) {
            index -= 1;
            const message = context.messages[index];
            if (message != .assistant) continue;
            const assistant = message.assistant;
            if (assistant.stop_reason == .aborted and assistant.content.len == 0) continue;

            var text: std.ArrayList(u8) = .empty;
            errdefer text.deinit(self.allocator);
            for (assistant.content) |content| {
                if (content == .text) try text.appendSlice(self.allocator, content.text.text);
            }
            const trimmed = std.mem.trim(u8, text.items, " \t\r\n");
            if (trimmed.len == 0) {
                text.deinit(self.allocator);
                return null;
            }
            const result = try self.allocator.dupe(u8, trimmed);
            text.deinit(self.allocator);
            return result;
        }
        return null;
    }

    fn forkBefore(
        self: *RpcMode,
        manager: *session_manager.SessionManager,
        entry_id: []const u8,
    ) ![]u8 {
        const entry = manager.getEntry(entry_id) orelse return error.InvalidForkEntry;
        const selected_text = try userMessageTextFromEntryAlloc(self.allocator, entry.raw_json) orelse
            return error.InvalidForkEntry;
        errdefer self.allocator.free(selected_text);
        const parent_id = try parentIdFromEntryAlloc(self.allocator, entry.raw_json);
        defer if (parent_id) |value| self.allocator.free(value);

        if (parent_id) |target| {
            _ = try manager.createBranchedSession(self.io, target);
        } else {
            const previous_file = manager.getSessionFile();
            _ = try manager.newSession(self.io, .{ .parent_session = previous_file });
        }
        return selected_text;
    }
};

const ReplayEventCollector = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) ReplayEventCollector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ReplayEventCollector) void {
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    fn listener(self: *ReplayEventCollector) session_events.SessionEventListener {
        return .{ .ptr = self, .call_fn = onEvent };
    }

    fn appendLine(self: *ReplayEventCollector, line: []const u8) !void {
        try self.lines.appendSlice(self.allocator, line);
    }

    fn clear(self: *ReplayEventCollector) void {
        self.lines.clearRetainingCapacity();
    }

    fn toOwnedSlice(self: *ReplayEventCollector) ![]u8 {
        return self.lines.toOwnedSlice(self.allocator);
    }

    fn onEvent(ptr: ?*anyopaque, event: session_events.SessionEvent) void {
        const self: *ReplayEventCollector = @ptrCast(@alignCast(ptr.?));
        const line = rpc_types.sessionEventLineAlloc(self.allocator, event) catch @panic("failed to serialize RPC session event");
        defer self.allocator.free(line);
        self.lines.appendSlice(self.allocator, line) catch @panic("failed to collect RPC session event");
    }
};

fn deinitForkMessages(allocator: std.mem.Allocator, messages: []const rpc_types.ForkMessage) void {
    freeForkMessageItems(allocator, messages);
    allocator.free(messages);
}

fn freeForkMessageItems(allocator: std.mem.Allocator, messages: []const rpc_types.ForkMessage) void {
    for (messages) |message| {
        allocator.free(@constCast(message.entry_id));
        allocator.free(@constCast(message.text));
    }
}

fn userMessageTextFromEntryAlloc(allocator: std.mem.Allocator, raw_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const message = parsed.value.object.get("message") orelse return null;
    if (message != .object) return null;
    const role = optionalString(message.object, "role") orelse return null;
    if (!std.mem.eql(u8, role, "user")) return null;
    const content = message.object.get("content") orelse return null;
    return textFromContentValueAlloc(allocator, content);
}

fn textFromContentValueAlloc(allocator: std.mem.Allocator, content: std.json.Value) !?[]u8 {
    if (content == .string) return try allocator.dupe(u8, content.string);
    if (content != .array) return null;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (content.array.items) |part| {
        if (part != .object) continue;
        const part_type = optionalString(part.object, "type") orelse continue;
        if (!std.mem.eql(u8, part_type, "text")) continue;
        const value = optionalString(part.object, "text") orelse continue;
        try text.appendSlice(allocator, value);
    }
    return try text.toOwnedSlice(allocator);
}

fn parentIdFromEntryAlloc(allocator: std.mem.Allocator, raw_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("parentId") orelse return null;
    if (value == .null) return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}

fn sessionHasEntryType(manager: *const session_manager.SessionManager, entry_type: []const u8) bool {
    for (manager.getEntries()) |entry| {
        const current = entry.entry_type orelse continue;
        if (std.mem.eql(u8, current, entry_type)) return true;
    }
    return false;
}

fn sessionQueueMode(mode: rpc_types.QueueMode) session_events.QueueMode {
    return switch (mode) {
        .all => .all,
        .one_at_a_time => .one_at_a_time,
    };
}

fn jsonArrayLen(object: std.json.ObjectMap, key: []const u8) usize {
    const value = object.get(key) orelse return 0;
    return if (value == .array) value.array.items.len else 0;
}

fn nextModelFromPointers(models: []const *const ai.Model, current: ?*const ai.Model) ?*const ai.Model {
    if (models.len == 0) return null;
    if (current) |selected| {
        for (models, 0..) |model, index| {
            if (std.mem.eql(u8, model.provider, selected.provider) and std.mem.eql(u8, model.id, selected.id)) {
                return models[(index + 1) % models.len];
            }
        }
    }
    return models[0];
}

fn nextModelFromSlice(models: []const ai.Model, current: ?*const ai.Model) ?*const ai.Model {
    if (models.len == 0) return null;
    if (current) |selected| {
        for (models, 0..) |*model, index| {
            if (std.mem.eql(u8, model.provider, selected.provider) and std.mem.eql(u8, model.id, selected.id)) {
                return &models[(index + 1) % models.len];
            }
        }
    }
    return &models[0];
}

fn nextThinkingLevel(level: ai.ThinkingLevel) ai.ThinkingLevel {
    return switch (level) {
        .off => .minimal,
        .minimal => .low,
        .low => .medium,
        .medium => .high,
        .high => .xhigh,
        .xhigh => .off,
    };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn writeRpcTestFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .read = true, .truncate = true },
    });
}

test "RPC mode handles state thinking queue and session-name commands" {
    const allocator = std.testing.allocator;
    const models = [_]ai.Model{.{
        .id = "demo",
        .name = "Demo",
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .base_url = "https://example.com/v1",
        .reasoning = false,
    }};
    var mode = RpcMode.init(allocator, .{
        .static_models = &models,
        .initial_model = &models[0],
        .session_id = "session-1",
    });
    defer mode.deinit();

    const thinking = (try mode.handleLineAlloc("{\"id\":\"1\",\"type\":\"set_thinking_level\",\"level\":\"high\"}")).?;
    defer allocator.free(thinking);
    try std.testing.expect(std.mem.indexOf(u8, thinking, "\"success\":true") != null);

    const queue = (try mode.handleLineAlloc("{\"id\":\"2\",\"type\":\"set_steering_mode\",\"mode\":\"all\"}")).?;
    defer allocator.free(queue);
    try std.testing.expect(std.mem.indexOf(u8, queue, "\"success\":true") != null);

    const name = (try mode.handleLineAlloc("{\"id\":\"3\",\"type\":\"set_session_name\",\"name\":\"  rpc test  \"}")).?;
    defer allocator.free(name);
    try std.testing.expect(std.mem.indexOf(u8, name, "\"success\":true") != null);

    const state = (try mode.handleLineAlloc("{\"id\":\"4\",\"type\":\"get_state\"}")).?;
    defer allocator.free(state);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, state[0 .. state.len - 1], .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("high", data.get("thinkingLevel").?.string);
    try std.testing.expectEqualStrings("all", data.get("steeringMode").?.string);
    try std.testing.expectEqualStrings("rpc test", data.get("sessionName").?.string);
}

test "RPC mode returns available models and structured unsupported runtime errors" {
    const allocator = std.testing.allocator;
    const models = [_]ai.Model{.{
        .id = "demo",
        .name = "Demo",
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .base_url = "https://example.com/v1",
        .reasoning = false,
    }};
    var mode = RpcMode.init(allocator, .{ .static_models = &models });
    defer mode.deinit();

    const available = (try mode.handleLineAlloc("{\"id\":\"m1\",\"type\":\"get_available_models\"}")).?;
    defer allocator.free(available);
    var parsed_available = try std.json.parseFromSlice(std.json.Value, allocator, available[0 .. available.len - 1], .{});
    defer parsed_available.deinit();
    const model = parsed_available.value.object.get("data").?.object.get("models").?.array.items[0].object;
    try std.testing.expectEqualStrings("demo", model.get("provider").?.string);
    try std.testing.expectEqual(@as(i64, 128000), model.get("contextWindow").?.integer);

    const prompt = (try mode.handleLineAlloc("{\"id\":\"p1\",\"type\":\"prompt\",\"message\":\"hi\"}")).?;
    defer allocator.free(prompt);
    var parsed_prompt = try std.json.parseFromSlice(std.json.Value, allocator, prompt[0 .. prompt.len - 1], .{});
    defer parsed_prompt.deinit();
    try std.testing.expectEqual(false, parsed_prompt.value.object.get("success").?.bool);
    try std.testing.expectEqualStrings("prompt", parsed_prompt.value.object.get("command").?.string);
    try std.testing.expect(std.mem.indexOf(u8, parsed_prompt.value.object.get("error").?.string, "AgentSession runtime integration") != null);
}

test "RPC mode prompt and queued messages emit replay-backed JSONL events" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var session = try session_manager.SessionManager.inMemory(allocator, io, "/tmp");
    defer session.deinit();
    var bridge = session_events.SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var extension_runtime = extensions.createExtensionRuntime(allocator);
    defer extension_runtime.deinit();
    var registry: model_registry.ModelRegistry = undefined;
    var runner = extensions.ExtensionRunner.init(allocator, &.{}, &extension_runtime, "/tmp", &session, &registry);
    defer runner.deinit();
    const retry = session_events.AutoRetryController.init(.{}, null);
    var replay = session_events.AgentSessionReplay.init(allocator, &bridge, &runner, &session, retry, &.{});
    defer replay.deinit();

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "pong" } }};
    const responses = [_]ai.AssistantMessage{.{
        .content = &assistant_content,
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .model = "demo",
        .stop_reason = .stop,
        .timestamp_ms = 2,
    }};
    replay.setResponses(&responses);

    var mode = RpcMode.init(allocator, .{
        .session_manager = &session,
        .session_replay = &replay,
    });
    defer mode.deinit();

    const prompt_response = (try mode.handleLineAlloc("{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"ping\"}")).?;
    defer allocator.free(prompt_response);
    var lines = std.mem.splitScalar(u8, prompt_response, '\n');
    const response_line = lines.next().?;
    var parsed_response = try std.json.parseFromSlice(std.json.Value, allocator, response_line, .{});
    defer parsed_response.deinit();
    try std.testing.expectEqualStrings("response", parsed_response.value.object.get("type").?.string);
    try std.testing.expectEqualStrings("prompt", parsed_response.value.object.get("command").?.string);
    try std.testing.expect(parsed_response.value.object.get("success").?.bool);

    var saw_agent_start = false;
    var saw_text_delta = false;
    var saw_agent_end = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const event_type = parsed.value.object.get("type").?.string;
        if (std.mem.eql(u8, event_type, "agent_start")) saw_agent_start = true;
        if (std.mem.eql(u8, event_type, "message_update")) {
            const assistant_event = parsed.value.object.get("assistantMessageEvent").?.object;
            if (std.mem.eql(u8, assistant_event.get("type").?.string, "text_delta")) {
                saw_text_delta = true;
                try std.testing.expectEqualStrings("pong", assistant_event.get("delta").?.string);
                try std.testing.expectEqualStrings("assistant", assistant_event.get("partial").?.object.get("role").?.string);
            }
        }
        if (std.mem.eql(u8, event_type, "agent_end")) {
            saw_agent_end = true;
            try std.testing.expectEqual(false, parsed.value.object.get("willRetry").?.bool);
        }
    }
    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_text_delta);
    try std.testing.expect(saw_agent_end);

    const steer_response = (try mode.handleLineAlloc("{\"id\":\"s\",\"type\":\"steer\",\"message\":\"adjust\"}")).?;
    defer allocator.free(steer_response);
    var steer_lines = std.mem.splitScalar(u8, steer_response, '\n');
    const queue_line = steer_lines.next().?;
    var parsed_queue = try std.json.parseFromSlice(std.json.Value, allocator, queue_line, .{});
    defer parsed_queue.deinit();
    try std.testing.expectEqualStrings("queue_update", parsed_queue.value.object.get("type").?.string);
    const steering = parsed_queue.value.object.get("steering").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), steering.len);
    try std.testing.expectEqualStrings("adjust", steering[0].string);

    const steer_success = steer_lines.next().?;
    var parsed_steer_success = try std.json.parseFromSlice(std.json.Value, allocator, steer_success, .{});
    defer parsed_steer_success.deinit();
    try std.testing.expectEqualStrings("steer", parsed_steer_success.value.object.get("command").?.string);
    try std.testing.expect(parsed_steer_success.value.object.get("success").?.bool);

    const follow_response = (try mode.handleLineAlloc("{\"id\":\"f\",\"type\":\"follow_up\",\"message\":\"next\"}")).?;
    defer allocator.free(follow_response);
    var follow_lines = std.mem.splitScalar(u8, follow_response, '\n');
    const follow_queue_line = follow_lines.next().?;
    var parsed_follow_queue = try std.json.parseFromSlice(std.json.Value, allocator, follow_queue_line, .{});
    defer parsed_follow_queue.deinit();
    try std.testing.expectEqualStrings("queue_update", parsed_follow_queue.value.object.get("type").?.string);
    const follow_up = parsed_follow_queue.value.object.get("followUp").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), follow_up.len);
    try std.testing.expectEqualStrings("next", follow_up[0].string);

    const follow_success = follow_lines.next().?;
    var parsed_follow_success = try std.json.parseFromSlice(std.json.Value, allocator, follow_success, .{});
    defer parsed_follow_success.deinit();
    try std.testing.expectEqualStrings("follow_up", parsed_follow_success.value.object.get("command").?.string);
    try std.testing.expect(parsed_follow_success.value.object.get("success").?.bool);

    const state_response = (try mode.handleLineAlloc("{\"id\":\"state\",\"type\":\"get_state\"}")).?;
    defer allocator.free(state_response);
    var parsed_state = try std.json.parseFromSlice(std.json.Value, allocator, state_response[0 .. state_response.len - 1], .{});
    defer parsed_state.deinit();
    try std.testing.expectEqual(@as(i64, 2), parsed_state.value.object.get("data").?.object.get("pendingMessageCount").?.integer);
}

const RpcCompactSummaryState = struct {
    summary: []const u8,
    calls: usize = 0,
    content: [1]ai.AssistantContent = undefined,

    fn executor(self: *@This()) compaction_mod.SummaryExecutor {
        return .{ .ptr = self, .complete_fn = complete };
    }

    fn complete(
        ptr: ?*anyopaque,
        model: ai.Model,
        context: ai.Context,
        options: ai.SimpleStreamOptions,
    ) !ai.AssistantMessage {
        _ = context;
        _ = options;
        const self: *@This() = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        self.content[0] = .{ .text = .{ .text = self.summary } };
        return .{
            .content = self.content[0..],
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = .stop,
        };
    }
};

fn rpcCompactModel() ai.Model {
    return .{
        .id = "rpc-compact",
        .name = "RPC Compact",
        .api = ai.types.api.openai_responses,
        .provider = "demo",
        .base_url = "https://example.invalid",
        .context_window = 200_000,
        .max_tokens = 8192,
    };
}

test "RPC mode compact emits replay-backed compaction events and result" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var session = try session_manager.SessionManager.inMemory(allocator, io, "/tmp");
    defer session.deinit();
    var bridge = session_events.SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var extension_runtime = extensions.createExtensionRuntime(allocator);
    defer extension_runtime.deinit();
    var registry: model_registry.ModelRegistry = undefined;
    var runner = extensions.ExtensionRunner.init(allocator, &.{}, &extension_runtime, "/tmp", &session, &registry);
    defer runner.deinit();
    const retry = session_events.AutoRetryController.init(.{ .enabled = false }, null);
    var replay = session_events.AgentSessionReplay.init(allocator, &bridge, &runner, &session, retry, &.{});
    defer replay.deinit();

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply before compact" } }};
    const responses = [_]ai.AssistantMessage{.{
        .content = &assistant_content,
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .model = "demo",
        .stop_reason = .stop,
        .timestamp_ms = 2,
    }};
    replay.setResponses(&responses);
    try replay.prompt(io, "message to compact", 1);

    var summary_state = RpcCompactSummaryState{ .summary = "rpc compact summary" };
    replay.setAutoCompaction(.{
        .model = rpcCompactModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 1024, .keep_recent_tokens = 1 },
    });

    var mode = RpcMode.init(allocator, .{
        .session_manager = &session,
        .session_replay = &replay,
    });
    defer mode.deinit();

    const disabled = (try mode.handleLineAlloc("{\"id\":\"ac0\",\"type\":\"set_auto_compaction\",\"enabled\":false}")).?;
    defer allocator.free(disabled);
    try std.testing.expectEqual(false, replay.auto_compaction.?.settings.enabled);

    const state_response = (try mode.handleLineAlloc("{\"id\":\"state\",\"type\":\"get_state\"}")).?;
    defer allocator.free(state_response);
    var parsed_state = try std.json.parseFromSlice(std.json.Value, allocator, state_response[0 .. state_response.len - 1], .{});
    defer parsed_state.deinit();
    try std.testing.expectEqual(false, parsed_state.value.object.get("data").?.object.get("autoCompactionEnabled").?.bool);

    const enabled = (try mode.handleLineAlloc("{\"id\":\"ac1\",\"type\":\"set_auto_compaction\",\"enabled\":true}")).?;
    defer allocator.free(enabled);
    try std.testing.expectEqual(true, replay.auto_compaction.?.settings.enabled);

    const compact_response = (try mode.handleLineAlloc("{\"id\":\"c\",\"type\":\"compact\",\"customInstructions\":\"keep it crisp\"}")).?;
    defer allocator.free(compact_response);
    try std.testing.expectEqual(@as(usize, 1), summary_state.calls);

    var saw_start = false;
    var saw_end = false;
    var saw_success = false;
    var saw_first_kept_entry_id = false;
    var lines = std.mem.splitScalar(u8, compact_response, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const line_type = parsed.value.object.get("type").?.string;
        if (std.mem.eql(u8, line_type, "compaction_start")) {
            saw_start = true;
            try std.testing.expectEqualStrings("manual", parsed.value.object.get("reason").?.string);
        } else if (std.mem.eql(u8, line_type, "compaction_end")) {
            saw_end = true;
            const result = parsed.value.object.get("result").?.object;
            try std.testing.expectEqualStrings("manual", parsed.value.object.get("reason").?.string);
            try std.testing.expect(std.mem.indexOf(u8, result.get("summary").?.string, "rpc compact summary") != null);
            try std.testing.expect(result.get("firstKeptEntryId").?.string.len > 0);
        } else {
            saw_success = true;
            try std.testing.expectEqualStrings("response", line_type);
            try std.testing.expectEqualStrings("compact", parsed.value.object.get("command").?.string);
            try std.testing.expect(parsed.value.object.get("success").?.bool);
            const data = parsed.value.object.get("data").?.object;
            try std.testing.expect(std.mem.indexOf(u8, data.get("summary").?.string, "rpc compact summary") != null);
            saw_first_kept_entry_id = data.get("firstKeptEntryId").?.string.len > 0;
            try std.testing.expect(data.get("tokensBefore").?.integer > 0);
            try std.testing.expect(data.get("details").?.object.get("readFiles") != null);
        }
    }
    try std.testing.expect(saw_start);
    try std.testing.expect(saw_end);
    try std.testing.expect(saw_success);
    try std.testing.expect(saw_first_kept_entry_id);

    const entries = session.getEntries();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("compaction", entries[2].entry_type.?);
}

const FakeBashOperations = struct {
    chunks: []const []const u8,
    exit_code: ?i32 = 0,

    fn operations(self: *FakeBashOperations) bash_executor.BashOperations {
        return .{ .ptr = self, .exec_fn = exec };
    }

    fn exec(
        ptr: ?*anyopaque,
        _: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
        _: []const u8,
        options: bash_executor.BashExecOptions,
    ) !bash_executor.BashExecResult {
        const self: *FakeBashOperations = @ptrCast(@alignCast(ptr.?));
        for (self.chunks) |chunk| try options.on_data.call(chunk);
        return .{ .exit_code = self.exit_code };
    }
};

test "RPC mode executes bash and records bashExecution messages" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var session = try session_manager.SessionManager.inMemory(allocator, io, "/tmp");
    defer session.deinit();
    const chunks = [_][]const u8{"hello\n"};
    var fake = FakeBashOperations{ .chunks = &chunks, .exit_code = 0 };
    var mode = RpcMode.init(allocator, .{
        .session_manager = &session,
        .bash_operations = fake.operations(),
    });
    defer mode.deinit();

    const response = (try mode.handleLineAlloc("{\"id\":\"b\",\"type\":\"bash\",\"command\":\"printf hello\"}")).?;
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response[0 .. response.len - 1], .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("hello\n", data.get("output").?.string);
    try std.testing.expectEqual(@as(i64, 0), data.get("exitCode").?.integer);
    try std.testing.expectEqual(false, data.get("cancelled").?.bool);

    const messages_response = (try mode.handleLineAlloc("{\"id\":\"m\",\"type\":\"get_messages\"}")).?;
    defer allocator.free(messages_response);
    var parsed_messages = try std.json.parseFromSlice(std.json.Value, allocator, messages_response[0 .. messages_response.len - 1], .{});
    defer parsed_messages.deinit();
    const messages_array = parsed_messages.value.object.get("data").?.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), messages_array.len);
    const bash_message = messages_array[0].object;
    try std.testing.expectEqualStrings("bashExecution", bash_message.get("role").?.string);
    try std.testing.expectEqualStrings("printf hello", bash_message.get("command").?.string);
    try std.testing.expectEqualStrings("hello\n", bash_message.get("output").?.string);
}

test "RPC mode exposes persisted session messages stats fork candidates and state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const models = [_]ai.Model{.{
        .id = "demo",
        .name = "Demo",
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .base_url = "https://example.com/v1",
        .reasoning = false,
        .context_window = 1000,
    }};
    var session = try session_manager.SessionManager.inMemory(allocator, io, "/tmp");
    defer session.deinit();

    const user_content = [_]ai.UserContent{.{ .text = .{ .text = "hello" } }};
    _ = try session.appendMessage(io, .{ .user = .{
        .content = &user_content,
        .timestamp_ms = 1,
    } });
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "  answer  " } }};
    _ = try session.appendMessage(io, .{ .assistant = .{
        .content = &assistant_content,
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .model = "demo",
        .usage = .{
            .input = 10,
            .output = 5,
            .cache_read = 2,
            .cache_write = 1,
            .cost = .{ .total = 0.25 },
        },
        .stop_reason = .stop,
        .timestamp_ms = 2,
    } });

    var mode = RpcMode.init(allocator, .{
        .static_models = &models,
        .initial_model = &models[0],
        .session_manager = &session,
    });
    defer mode.deinit();

    const messages_response = (try mode.handleLineAlloc("{\"id\":\"m\",\"type\":\"get_messages\"}")).?;
    defer allocator.free(messages_response);
    var parsed_messages = try std.json.parseFromSlice(std.json.Value, allocator, messages_response[0 .. messages_response.len - 1], .{});
    defer parsed_messages.deinit();
    const messages_array = parsed_messages.value.object.get("data").?.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages_array.len);
    try std.testing.expectEqualStrings("user", messages_array[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("assistant", messages_array[1].object.get("role").?.string);

    const fork_response = (try mode.handleLineAlloc("{\"id\":\"f\",\"type\":\"get_fork_messages\"}")).?;
    defer allocator.free(fork_response);
    var parsed_fork = try std.json.parseFromSlice(std.json.Value, allocator, fork_response[0 .. fork_response.len - 1], .{});
    defer parsed_fork.deinit();
    const fork_messages = parsed_fork.value.object.get("data").?.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), fork_messages.len);
    try std.testing.expectEqualStrings("hello", fork_messages[0].object.get("text").?.string);

    const last_response = (try mode.handleLineAlloc("{\"id\":\"l\",\"type\":\"get_last_assistant_text\"}")).?;
    defer allocator.free(last_response);
    var parsed_last = try std.json.parseFromSlice(std.json.Value, allocator, last_response[0 .. last_response.len - 1], .{});
    defer parsed_last.deinit();
    try std.testing.expectEqualStrings("answer", parsed_last.value.object.get("data").?.object.get("text").?.string);

    const stats_response = (try mode.handleLineAlloc("{\"id\":\"s\",\"type\":\"get_session_stats\"}")).?;
    defer allocator.free(stats_response);
    var parsed_stats = try std.json.parseFromSlice(std.json.Value, allocator, stats_response[0 .. stats_response.len - 1], .{});
    defer parsed_stats.deinit();
    const stats = parsed_stats.value.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 1), stats.get("userMessages").?.integer);
    try std.testing.expectEqual(@as(i64, 1), stats.get("assistantMessages").?.integer);
    try std.testing.expectEqual(@as(i64, 18), stats.get("tokens").?.object.get("total").?.integer);

    const name_response = (try mode.handleLineAlloc("{\"id\":\"n\",\"type\":\"set_session_name\",\"name\":\" rpc session \"}")).?;
    defer allocator.free(name_response);
    const thinking_response = (try mode.handleLineAlloc("{\"id\":\"t\",\"type\":\"set_thinking_level\",\"level\":\"high\"}")).?;
    defer allocator.free(thinking_response);
    const model_response = (try mode.handleLineAlloc("{\"id\":\"m2\",\"type\":\"set_model\",\"provider\":\"demo\",\"modelId\":\"demo\"}")).?;
    defer allocator.free(model_response);

    const state_response = (try mode.handleLineAlloc("{\"id\":\"q\",\"type\":\"get_state\"}")).?;
    defer allocator.free(state_response);
    var parsed_state = try std.json.parseFromSlice(std.json.Value, allocator, state_response[0 .. state_response.len - 1], .{});
    defer parsed_state.deinit();
    const state = parsed_state.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("rpc session", state.get("sessionName").?.string);
    try std.testing.expectEqualStrings("high", state.get("thinkingLevel").?.string);
    try std.testing.expectEqualStrings("demo", state.get("model").?.object.get("provider").?.string);
    try std.testing.expectEqual(@as(i64, 2), state.get("messageCount").?.integer);

    var context = try session.buildSessionContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expectEqualStrings("high", context.thinking_level);
    try std.testing.expectEqualStrings("demo", context.model.?.provider);
    try std.testing.expectEqualStrings("demo", context.model.?.model_id);
}

test "RPC mode performs session fork clone new and switch lifecycle commands" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const session_dir = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "sessions" });
    defer allocator.free(session_dir);

    var first = try session_manager.SessionManager.create(allocator, io, cwd, session_dir, .{});
    const first_user_content = [_]ai.UserContent{.{ .text = .{ .text = "first" } }};
    _ = try first.appendMessage(io, .{ .user = .{
        .content = &first_user_content,
        .timestamp_ms = 1,
    } });
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    _ = try first.appendMessage(io, .{ .assistant = .{
        .content = &assistant_content,
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .model = "demo",
        .stop_reason = .stop,
        .timestamp_ms = 2,
    } });
    const second_user_content = [_]ai.UserContent{.{ .text = .{ .text = "second" } }};
    const second_user_id = try first.appendMessage(io, .{ .user = .{
        .content = &second_user_content,
        .timestamp_ms = 3,
    } });
    const first_path = try allocator.dupe(u8, first.getSessionFile().?);
    defer allocator.free(first_path);

    var mode = RpcMode.init(allocator, .{ .session_manager = &first });
    defer mode.deinit();
    defer first.deinit();

    const fork_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"f\",\"type\":\"fork\",\"entryId\":\"{s}\"}}",
        .{second_user_id},
    );
    defer allocator.free(fork_command);
    const fork_response = (try mode.handleLineAlloc(fork_command)).?;
    defer allocator.free(fork_response);
    var parsed_fork = try std.json.parseFromSlice(std.json.Value, allocator, fork_response[0 .. fork_response.len - 1], .{});
    defer parsed_fork.deinit();
    try std.testing.expectEqualStrings("second", parsed_fork.value.object.get("data").?.object.get("text").?.string);

    const forked_id = try allocator.dupe(u8, first.getSessionId());
    defer allocator.free(forked_id);
    const clone_response = (try mode.handleLineAlloc("{\"id\":\"c\",\"type\":\"clone\"}")).?;
    defer allocator.free(clone_response);
    try std.testing.expect(!std.mem.eql(u8, forked_id, first.getSessionId()));

    const new_response = (try mode.handleLineAlloc("{\"id\":\"n\",\"type\":\"new_session\"}")).?;
    defer allocator.free(new_response);
    try std.testing.expectEqual(@as(usize, 0), first.getEntries().len);

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"s\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{first_path},
    );
    defer allocator.free(switch_command);
    const switch_response = (try mode.handleLineAlloc(switch_command)).?;
    defer allocator.free(switch_response);
    try std.testing.expectEqualStrings(first_path, first.getSessionFile().?);

    var switched_context = try first.buildSessionContextAlloc(allocator);
    defer switched_context.deinit();
    try std.testing.expectEqual(@as(usize, 3), switched_context.messages.len);
}

test "RPC mode uses AgentSessionRuntime for session lifecycle commands" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(session_dir);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);

    const manager = try allocator.create(session_manager.SessionManager);
    manager.* = try session_manager.SessionManager.create(allocator, io, cwd, session_dir, .{});

    const first_user_content = [_]ai.UserContent{.{ .text = .{ .text = "first" } }};
    _ = try manager.appendMessage(io, .{ .user = .{
        .content = &first_user_content,
        .timestamp_ms = 1,
    } });
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    _ = try manager.appendMessage(io, .{ .assistant = .{
        .content = &assistant_content,
        .api = ai.types.api.openai_completions,
        .provider = "demo",
        .model = "demo",
        .stop_reason = .stop,
        .timestamp_ms = 2,
    } });
    const second_user_content = [_]ai.UserContent{.{ .text = .{ .text = "second" } }};
    const second_user_id = try manager.appendMessage(io, .{ .user = .{
        .content = &second_user_content,
        .timestamp_ms = 3,
    } });
    const first_path = try allocator.dupe(u8, manager.getSessionFile().?);
    defer allocator.free(first_path);

    var host = rpc_runtime_host.RpcRuntimeHost.init(allocator, io, .{
        .env = &env,
        .agent_dir = agent_dir,
        .resource_loader_options = .{
            .no_extensions = true,
            .no_skills = true,
            .no_prompt_templates = true,
            .no_themes = true,
            .no_context_files = true,
        },
    });
    try host.start(manager);
    defer host.deinit();

    var mode = RpcMode.init(allocator, .{ .session_runtime = &host.runtime });
    defer mode.deinit();

    const fork_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"f\",\"type\":\"fork\",\"entryId\":\"{s}\"}}",
        .{second_user_id},
    );
    defer allocator.free(fork_command);
    const fork_response = (try mode.handleLineAlloc(fork_command)).?;
    defer allocator.free(fork_response);
    var parsed_fork = try std.json.parseFromSlice(std.json.Value, allocator, fork_response[0 .. fork_response.len - 1], .{});
    defer parsed_fork.deinit();
    try std.testing.expect(parsed_fork.value.object.get("success").?.bool);
    try std.testing.expectEqualStrings("second", parsed_fork.value.object.get("data").?.object.get("text").?.string);
    try std.testing.expect(mode.session_manager.? == host.runtime.session.getSessionManager());

    const forked_id = try allocator.dupe(u8, mode.session_manager.?.getSessionId());
    defer allocator.free(forked_id);
    const clone_response = (try mode.handleLineAlloc("{\"id\":\"c\",\"type\":\"clone\"}")).?;
    defer allocator.free(clone_response);
    var parsed_clone = try std.json.parseFromSlice(std.json.Value, allocator, clone_response[0 .. clone_response.len - 1], .{});
    defer parsed_clone.deinit();
    try std.testing.expect(parsed_clone.value.object.get("success").?.bool);
    try std.testing.expect(!std.mem.eql(u8, forked_id, mode.session_manager.?.getSessionId()));

    const new_response = (try mode.handleLineAlloc("{\"id\":\"n\",\"type\":\"new_session\",\"parentSession\":\"parent.jsonl\"}")).?;
    defer allocator.free(new_response);
    var parsed_new = try std.json.parseFromSlice(std.json.Value, allocator, new_response[0 .. new_response.len - 1], .{});
    defer parsed_new.deinit();
    try std.testing.expect(parsed_new.value.object.get("success").?.bool);
    try std.testing.expectEqual(@as(usize, 0), mode.session_manager.?.getEntries().len);

    const switch_command = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"s\",\"type\":\"switch_session\",\"sessionPath\":\"{s}\"}}",
        .{first_path},
    );
    defer allocator.free(switch_command);
    const switch_response = (try mode.handleLineAlloc(switch_command)).?;
    defer allocator.free(switch_response);
    var parsed_switch = try std.json.parseFromSlice(std.json.Value, allocator, switch_response[0 .. switch_response.len - 1], .{});
    defer parsed_switch.deinit();
    try std.testing.expect(parsed_switch.value.object.get("success").?.bool);
    try std.testing.expectEqualStrings(first_path, mode.session_manager.?.getSessionFile().?);
}

test "RPC mode get_commands uses AgentSessionRuntime prompt templates and skills" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const project_dir = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(project_dir);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(session_dir);
    const prompt_path = try std.fs.path.join(allocator, &.{ root, "prompts", "review.md" });
    defer allocator.free(prompt_path);
    const skill_root = try std.fs.path.join(allocator, &.{ root, "skills" });
    defer allocator.free(skill_root);
    const skill_path = try std.fs.path.join(allocator, &.{ skill_root, "debug-tool", "SKILL.md" });
    defer allocator.free(skill_path);

    try std.Io.Dir.cwd().createDirPath(io, project_dir);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);
    try writeRpcTestFile(prompt_path,
        \\---
        \\description: Review code
        \\---
        \\Review $ARGUMENTS
    );
    try writeRpcTestFile(skill_path,
        \\---
        \\name: debug-tool
        \\description: Debug helper
        \\---
        \\Use the debugger.
    );

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);

    const manager = try allocator.create(session_manager.SessionManager);
    manager.* = try session_manager.SessionManager.create(allocator, io, project_dir, session_dir, .{});

    var host = rpc_runtime_host.RpcRuntimeHost.init(allocator, io, .{
        .env = &env,
        .agent_dir = agent_dir,
        .resource_loader_options = .{
            .additional_skill_paths = &.{skill_root},
            .additional_prompt_template_paths = &.{prompt_path},
            .no_extensions = true,
            .no_skills = true,
            .no_prompt_templates = true,
            .no_themes = true,
            .no_context_files = true,
        },
    });
    try host.start(manager);
    defer host.deinit();

    var mode = RpcMode.init(allocator, .{ .session_runtime = &host.runtime });
    defer mode.deinit();

    const response = (try mode.handleLineAlloc("{\"id\":\"cmd\",\"type\":\"get_commands\"}")).?;
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response[0 .. response.len - 1], .{});
    defer parsed.deinit();
    const commands = parsed.value.object.get("data").?.object.get("commands").?.array.items;

    try std.testing.expectEqual(@as(usize, 2), commands.len);
    try std.testing.expectEqualStrings("review", commands[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("Review code", commands[0].object.get("description").?.string);
    try std.testing.expectEqualStrings("prompt", commands[0].object.get("source").?.string);
    try std.testing.expectEqualStrings(prompt_path, commands[0].object.get("sourceInfo").?.object.get("path").?.string);
    try std.testing.expectEqualStrings("temporary", commands[0].object.get("sourceInfo").?.object.get("scope").?.string);

    try std.testing.expectEqualStrings("skill:debug-tool", commands[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("Debug helper", commands[1].object.get("description").?.string);
    try std.testing.expectEqualStrings("skill", commands[1].object.get("source").?.string);
    try std.testing.expectEqualStrings(skill_path, commands[1].object.get("sourceInfo").?.object.get("path").?.string);
    try std.testing.expectEqualStrings("temporary", commands[1].object.get("sourceInfo").?.object.get("scope").?.string);
}
