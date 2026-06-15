const std = @import("std");

const ai = @import("bulb_ai");
const model_registry = @import("model_registry.zig");
const rpc_types = @import("rpc_types.zig");

const stdin_buffer_bytes = 64 * 1024;
const max_rpc_jsonl_line_bytes = 16 * 1024 * 1024;
const default_session_id = "rpc-session";

pub const RpcModeOptions = struct {
    io: ?std.Io = null,
    model_registry: ?*model_registry.ModelRegistry = null,
    initial_model: ?*const ai.Model = null,
    static_models: []const ai.Model = &.{},
    thinking_level: ai.ThinkingLevel = .medium,
    session_id: []const u8 = default_session_id,
};

pub const RpcMode = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    model_registry: ?*model_registry.ModelRegistry,
    static_models: []const ai.Model,
    state: rpc_types.RpcSessionState,
    auto_retry_enabled: bool = true,
    session_name_storage: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, options: RpcModeOptions) RpcMode {
        return .{
            .allocator = allocator,
            .io = options.io orelse std.Io.Threaded.global_single_threaded.io(),
            .model_registry = options.model_registry,
            .static_models = options.static_models,
            .state = .{
                .model = options.initial_model,
                .thinking_level = options.thinking_level,
                .session_id = options.session_id,
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
            const data = try rpc_types.modelDataJsonAlloc(self.allocator, model.*);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "set_model", data);
        }

        if (std.mem.eql(u8, command_type, "cycle_model")) {
            const model = try self.cycleModel();
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
            return rpc_types.successLineAlloc(self.allocator, id, "set_thinking_level", null);
        }

        if (std.mem.eql(u8, command_type, "cycle_thinking_level")) {
            self.state.thinking_level = nextThinkingLevel(self.state.thinking_level);
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
            return rpc_types.successLineAlloc(self.allocator, id, "set_follow_up_mode", null);
        }

        if (std.mem.eql(u8, command_type, "set_auto_compaction")) {
            self.state.auto_compaction_enabled = optionalBool(object, "enabled") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_auto_compaction", "set_auto_compaction requires enabled");
            };
            return rpc_types.successLineAlloc(self.allocator, id, "set_auto_compaction", null);
        }

        if (std.mem.eql(u8, command_type, "set_auto_retry")) {
            self.auto_retry_enabled = optionalBool(object, "enabled") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_auto_retry", "set_auto_retry requires enabled");
            };
            return rpc_types.successLineAlloc(self.allocator, id, "set_auto_retry", null);
        }

        if (std.mem.eql(u8, command_type, "abort") or
            std.mem.eql(u8, command_type, "abort_bash") or
            std.mem.eql(u8, command_type, "abort_retry"))
        {
            return rpc_types.successLineAlloc(self.allocator, id, command_type, null);
        }

        if (std.mem.eql(u8, command_type, "get_session_stats")) {
            const data = try rpc_types.sessionStatsDataJsonAlloc(self.allocator, self.state);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_session_stats", data);
        }

        if (std.mem.eql(u8, command_type, "get_messages")) {
            const data = try rpc_types.emptyMessagesDataJsonAlloc(self.allocator);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_messages", data);
        }

        if (std.mem.eql(u8, command_type, "get_fork_messages")) {
            const data = try rpc_types.emptyMessagesDataJsonAlloc(self.allocator);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_fork_messages", data);
        }

        if (std.mem.eql(u8, command_type, "get_last_assistant_text")) {
            const data = try rpc_types.lastAssistantTextDataJsonAlloc(self.allocator, null);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_last_assistant_text", data);
        }

        if (std.mem.eql(u8, command_type, "set_session_name")) {
            const raw_name = optionalString(object, "name") orelse {
                return rpc_types.errorLineAlloc(self.allocator, id, "set_session_name", "set_session_name requires name");
            };
            const name = std.mem.trim(u8, raw_name, " \t\r\n");
            if (name.len == 0) return rpc_types.errorLineAlloc(self.allocator, id, "set_session_name", "Session name cannot be empty");
            const copy = try self.allocator.dupe(u8, name);
            if (self.session_name_storage) |previous| self.allocator.free(previous);
            self.session_name_storage = copy;
            self.state.session_name = copy;
            return rpc_types.successLineAlloc(self.allocator, id, "set_session_name", null);
        }

        if (std.mem.eql(u8, command_type, "get_commands")) {
            const data = try rpc_types.emptyCommandsDataJsonAlloc(self.allocator);
            defer self.allocator.free(data);
            return rpc_types.successLineAlloc(self.allocator, id, "get_commands", data);
        }

        if (std.mem.eql(u8, command_type, "new_session") or
            std.mem.eql(u8, command_type, "switch_session") or
            std.mem.eql(u8, command_type, "fork") or
            std.mem.eql(u8, command_type, "clone") or
            std.mem.eql(u8, command_type, "prompt") or
            std.mem.eql(u8, command_type, "steer") or
            std.mem.eql(u8, command_type, "follow_up") or
            std.mem.eql(u8, command_type, "compact") or
            std.mem.eql(u8, command_type, "bash") or
            std.mem.eql(u8, command_type, "export_html"))
        {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "RPC command {s} requires AgentSession runtime integration",
                .{command_type},
            );
            defer self.allocator.free(message);
            return rpc_types.errorLineAlloc(self.allocator, id, command_type, message);
        }

        const message = try std.fmt.allocPrint(self.allocator, "Unknown command: {s}", .{command_type});
        defer self.allocator.free(message);
        return rpc_types.errorLineAlloc(self.allocator, null, command_type, message);
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
};

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
