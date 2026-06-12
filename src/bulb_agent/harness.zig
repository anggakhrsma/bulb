const std = @import("std");
const ai = @import("bulb_ai");

const session_mod = @import("session.zig");
const session_storage = @import("session_storage.zig");
const types = @import("types.zig");

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const AgentHarnessPhase = enum {
    idle,
    turn,
    compaction,
    branch_summary,
    retry,
};

pub const HarnessError = error{
    Busy,
    InvalidState,
    InvalidArgument,
    Hook,
    Session,
};

pub fn ValuePatch(comptime T: type) type {
    return union(enum) {
        unchanged,
        clear,
        set: T,
    };
}

pub const MetadataEntry = struct {
    key: []const u8,
    value_json: []const u8,
};

pub const MetadataPatchEntry = struct {
    key: []const u8,
    value_json: ?[]const u8,
};

pub const HeaderPatchEntry = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const HeaderPatch = union(enum) {
    unchanged,
    clear,
    merge: []const HeaderPatchEntry,
};

pub const MetadataPatch = union(enum) {
    unchanged,
    clear,
    merge: []const MetadataPatchEntry,
};

pub const AgentHarnessStreamOptions = struct {
    transport: ?ai.Transport = null,
    timeout_ms: ?u64 = null,
    max_retries: ?u32 = null,
    max_retry_delay_ms: ?u64 = null,
    cache_retention: ?ai.CacheRetention = null,
    headers: []const ai.Header = &.{},
    metadata: []const MetadataEntry = &.{},

    pub fn cloneAlloc(self: AgentHarnessStreamOptions, allocator: std.mem.Allocator) !AgentHarnessStreamOptions {
        return .{
            .transport = self.transport,
            .timeout_ms = self.timeout_ms,
            .max_retries = self.max_retries,
            .max_retry_delay_ms = self.max_retry_delay_ms,
            .cache_retention = self.cache_retention,
            .headers = try cloneHeadersAlloc(allocator, self.headers),
            .metadata = try cloneMetadataAlloc(allocator, self.metadata),
        };
    }

    pub fn deinit(self: *AgentHarnessStreamOptions, allocator: std.mem.Allocator) void {
        freeHeaders(allocator, self.headers);
        freeMetadata(allocator, self.metadata);
        self.* = undefined;
    }

    pub fn toAiOptionsAlloc(
        self: AgentHarnessStreamOptions,
        allocator: std.mem.Allocator,
        api_key: ?[]const u8,
        session_id: ?[]const u8,
    ) !ai.StreamOptions {
        return .{
            .api_key = api_key,
            .transport = self.transport,
            .cache_retention = self.cache_retention orelse .short,
            .session_id = session_id,
            .headers = try cloneHeadersAlloc(allocator, self.headers),
            .timeout_ms = self.timeout_ms,
            .max_retries = self.max_retries,
            .max_retry_delay_ms = self.max_retry_delay_ms,
            .metadata_json = try metadataJsonAlloc(allocator, self.metadata),
        };
    }
};

pub const AgentHarnessStreamOptionsPatch = struct {
    transport: ValuePatch(ai.Transport) = .unchanged,
    timeout_ms: ValuePatch(u64) = .unchanged,
    max_retries: ValuePatch(u32) = .unchanged,
    max_retry_delay_ms: ValuePatch(u64) = .unchanged,
    cache_retention: ValuePatch(ai.CacheRetention) = .unchanged,
    headers: HeaderPatch = .unchanged,
    metadata: MetadataPatch = .unchanged,
};

pub const AuthHeaders = struct {
    api_key: ?[]const u8 = null,
    headers: []const ai.Header = &.{},
};

pub const ProviderRequestOptions = struct {
    allocator: std.mem.Allocator,
    api_key: ?[]const u8 = null,
    session_id: []u8,
    stream_options: AgentHarnessStreamOptions,

    pub fn deinit(self: *ProviderRequestOptions) void {
        if (self.api_key) |api_key| self.allocator.free(@constCast(api_key));
        self.allocator.free(self.session_id);
        self.stream_options.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn toAiOptionsAlloc(self: ProviderRequestOptions, allocator: std.mem.Allocator) !ai.StreamOptions {
        return try self.stream_options.toAiOptionsAlloc(allocator, self.api_key, self.session_id);
    }
};

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8 = "",
    parameters_json: []const u8 = "{}",
    source: ?[]const u8 = null,

    pub fn cloneAlloc(self: AgentTool, allocator: std.mem.Allocator) !AgentTool {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .description = try allocator.dupe(u8, self.description),
            .parameters_json = try allocator.dupe(u8, self.parameters_json),
            .source = if (self.source) |source| try allocator.dupe(u8, source) else null,
        };
    }

    pub fn deinit(self: *AgentTool, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.name));
        allocator.free(@constCast(self.description));
        allocator.free(@constCast(self.parameters_json));
        if (self.source) |source| allocator.free(@constCast(source));
        self.* = undefined;
    }

    pub fn asAiTool(self: AgentTool) ai.Tool {
        return .{
            .name = self.name,
            .description = self.description,
            .parameters_json = self.parameters_json,
        };
    }
};

pub const ResourceRef = struct {
    name: []const u8,
    description: []const u8 = "",
    content: []const u8 = "",
    file_path: []const u8 = "",
    source: ?[]const u8 = null,

    pub fn cloneAlloc(self: ResourceRef, allocator: std.mem.Allocator) !ResourceRef {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .description = try allocator.dupe(u8, self.description),
            .content = try allocator.dupe(u8, self.content),
            .file_path = try allocator.dupe(u8, self.file_path),
            .source = if (self.source) |source| try allocator.dupe(u8, source) else null,
        };
    }

    pub fn deinit(self: *ResourceRef, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.name));
        allocator.free(@constCast(self.description));
        allocator.free(@constCast(self.content));
        allocator.free(@constCast(self.file_path));
        if (self.source) |source| allocator.free(@constCast(source));
        self.* = undefined;
    }
};

pub const AgentHarnessResources = struct {
    skills: []const ResourceRef = &.{},
    prompt_templates: []const ResourceRef = &.{},

    pub fn cloneAlloc(self: AgentHarnessResources, allocator: std.mem.Allocator) !AgentHarnessResources {
        return .{
            .skills = try cloneResourcesAlloc(allocator, self.skills),
            .prompt_templates = try cloneResourcesAlloc(allocator, self.prompt_templates),
        };
    }

    pub fn deinit(self: *AgentHarnessResources, allocator: std.mem.Allocator) void {
        freeResources(allocator, self.skills);
        freeResources(allocator, self.prompt_templates);
        self.* = undefined;
    }
};

pub const QueueUpdateSnapshot = struct {
    steer: usize,
    follow_up: usize,
    next_turn: usize,
};

pub const AbortResult = struct {
    allocator: std.mem.Allocator,
    cleared_steer: []const types.AgentMessage,
    cleared_follow_up: []const types.AgentMessage,

    pub fn deinit(self: *AbortResult) void {
        self.allocator.free(@constCast(self.cleared_steer));
        self.allocator.free(@constCast(self.cleared_follow_up));
        self.* = undefined;
    }
};

pub const BeforeProviderRequestEvent = struct {
    model: *const ai.Model,
    session_id: []const u8,
    stream_options: AgentHarnessStreamOptions,
};

pub const BeforeProviderRequestResult = struct {
    stream_options: ?AgentHarnessStreamOptionsPatch = null,
};

pub const BeforeProviderRequestHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, BeforeProviderRequestEvent) anyerror!BeforeProviderRequestResult,

    pub fn call(self: BeforeProviderRequestHandler, event: BeforeProviderRequestEvent) !BeforeProviderRequestResult {
        return try self.call_fn(self.ptr, event);
    }
};

pub const BeforeProviderPayloadEvent = struct {
    model: *const ai.Model,
    payload_json: []const u8,
};

pub const BeforeProviderPayloadResult = struct {
    payload_json: ?[]const u8 = null,
};

pub const BeforeProviderPayloadHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, BeforeProviderPayloadEvent) anyerror!BeforeProviderPayloadResult,

    pub fn call(self: BeforeProviderPayloadHandler, event: BeforeProviderPayloadEvent) !BeforeProviderPayloadResult {
        return try self.call_fn(self.ptr, event);
    }
};

pub fn AgentHarnessOptions(comptime SessionType: type) type {
    return struct {
        env: types.ExecutionEnv,
        session: *SessionType,
        model: *const ai.Model,
        thinking_level: ai.ThinkingLevel = .off,
        stream_options: AgentHarnessStreamOptions = .{},
        resources: AgentHarnessResources = .{},
        tools: []const AgentTool = &.{},
        active_tool_names: ?[]const []const u8 = null,
        steering_mode: QueueMode = .one_at_a_time,
        follow_up_mode: QueueMode = .one_at_a_time,
    };
}

pub fn AgentHarness(comptime SessionType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        env: types.ExecutionEnv,
        session: *SessionType,
        phase: AgentHarnessPhase = .idle,
        model: *const ai.Model,
        thinking_level: ai.ThinkingLevel,
        stream_options: AgentHarnessStreamOptions,
        resources: AgentHarnessResources = .{},
        tools: std.ArrayList(AgentTool) = .empty,
        active_tool_names: std.ArrayList([]u8) = .empty,
        steer_queue: std.ArrayList(types.AgentMessage) = .empty,
        follow_up_queue: std.ArrayList(types.AgentMessage) = .empty,
        next_turn_queue: std.ArrayList(types.AgentMessage) = .empty,
        queue_updates: std.ArrayList(QueueUpdateSnapshot) = .empty,
        before_provider_request_handlers: std.ArrayList(BeforeProviderRequestHandler) = .empty,
        before_provider_payload_handlers: std.ArrayList(BeforeProviderPayloadHandler) = .empty,
        run_signal: ?*ai.AbortSignal = null,
        steering_mode: QueueMode = .one_at_a_time,
        follow_up_mode: QueueMode = .one_at_a_time,

        pub fn init(allocator: std.mem.Allocator, options: AgentHarnessOptions(SessionType)) !Self {
            var result: Self = .{
                .allocator = allocator,
                .arena = std.heap.ArenaAllocator.init(allocator),
                .env = options.env,
                .session = options.session,
                .model = options.model,
                .thinking_level = options.thinking_level,
                .stream_options = try options.stream_options.cloneAlloc(allocator),
                .resources = try options.resources.cloneAlloc(allocator),
            };
            errdefer result.deinit();

            try validateUniqueToolNames(options.tools, "Duplicate tool name");
            for (options.tools) |tool| try result.tools.append(allocator, try tool.cloneAlloc(allocator));

            if (options.active_tool_names) |active_names| {
                try result.validateAndSetActiveToolNames(active_names);
            } else {
                const names = try allocator.alloc([]const u8, options.tools.len);
                defer allocator.free(names);
                for (options.tools, 0..) |tool, index| names[index] = tool.name;
                try result.validateAndSetActiveToolNames(names);
            }

            result.steering_mode = options.steering_mode;
            result.follow_up_mode = options.follow_up_mode;
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.stream_options.deinit(self.allocator);
            self.resources.deinit(self.allocator);
            for (self.tools.items) |*tool| tool.deinit(self.allocator);
            self.tools.deinit(self.allocator);
            for (self.active_tool_names.items) |name| self.allocator.free(name);
            self.active_tool_names.deinit(self.allocator);
            self.steer_queue.deinit(self.allocator);
            self.follow_up_queue.deinit(self.allocator);
            self.next_turn_queue.deinit(self.allocator);
            self.queue_updates.deinit(self.allocator);
            self.before_provider_request_handlers.deinit(self.allocator);
            self.before_provider_payload_handlers.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn getModel(self: *const Self) *const ai.Model {
            return self.model;
        }

        pub fn setModel(self: *Self, model: *const ai.Model) !void {
            const previous = self.model;
            if (self.phase == .idle) {
                _ = self.session.appendModelChange(model.provider, model.id) catch return error.Session;
            }
            self.model = model;
            _ = previous;
        }

        pub fn getThinkingLevel(self: *const Self) ai.ThinkingLevel {
            return self.thinking_level;
        }

        pub fn setThinkingLevel(self: *Self, level: ai.ThinkingLevel) !void {
            if (self.phase == .idle) {
                _ = self.session.appendThinkingLevelChange(thinkingLevelName(level)) catch return error.Session;
            }
            self.thinking_level = level;
        }

        pub fn getSteeringMode(self: *const Self) QueueMode {
            return self.steering_mode;
        }

        pub fn setSteeringMode(self: *Self, mode: QueueMode) void {
            self.steering_mode = mode;
        }

        pub fn getFollowUpMode(self: *const Self) QueueMode {
            return self.follow_up_mode;
        }

        pub fn setFollowUpMode(self: *Self, mode: QueueMode) void {
            self.follow_up_mode = mode;
        }

        pub fn getToolsAlloc(self: *const Self, allocator: std.mem.Allocator) ![]AgentTool {
            return try cloneToolsAlloc(allocator, self.tools.items);
        }

        pub fn getActiveToolsAlloc(self: *const Self, allocator: std.mem.Allocator) ![]AgentTool {
            var output: std.ArrayList(AgentTool) = .empty;
            errdefer {
                for (output.items) |*tool| tool.deinit(allocator);
                output.deinit(allocator);
            }
            for (self.active_tool_names.items) |name| {
                const tool = self.findTool(name) orelse return error.InvalidArgument;
                try output.append(allocator, try tool.cloneAlloc(allocator));
            }
            return try output.toOwnedSlice(allocator);
        }

        pub fn setActiveTools(self: *Self, names: []const []const u8) !void {
            try self.validateToolNames(names, self.tools.items);
            const owned = try cloneNameSliceAlloc(self.allocator, names);
            errdefer freeNameSlice(self.allocator, owned);

            if (self.phase == .idle) {
                _ = self.session.appendActiveToolsChange(names) catch return error.Session;
            }

            for (self.active_tool_names.items) |name| self.allocator.free(name);
            self.active_tool_names.clearRetainingCapacity();
            for (owned) |name| try self.active_tool_names.append(self.allocator, name);
            self.allocator.free(owned);
        }

        pub fn setTools(self: *Self, tools: []const AgentTool, active_tool_names: ?[]const []const u8) !void {
            try validateUniqueToolNames(tools, "Duplicate tool name");
            const next_active_names = active_tool_names orelse self.active_tool_names.items;
            try self.validateToolNames(next_active_names, tools);

            const cloned_tools = try cloneToolsAlloc(self.allocator, tools);
            errdefer freeTools(self.allocator, cloned_tools);
            const cloned_names = try cloneNameSliceAlloc(self.allocator, next_active_names);
            errdefer freeNameSlice(self.allocator, cloned_names);

            if (self.phase == .idle) {
                _ = self.session.appendActiveToolsChange(next_active_names) catch return error.Session;
            }

            for (self.tools.items) |*tool| tool.deinit(self.allocator);
            self.tools.clearRetainingCapacity();
            for (cloned_tools) |tool| try self.tools.append(self.allocator, tool);
            self.allocator.free(cloned_tools);

            for (self.active_tool_names.items) |name| self.allocator.free(name);
            self.active_tool_names.clearRetainingCapacity();
            for (cloned_names) |name| try self.active_tool_names.append(self.allocator, name);
            self.allocator.free(cloned_names);
        }

        pub fn getResourcesAlloc(self: *const Self, allocator: std.mem.Allocator) !AgentHarnessResources {
            return try self.resources.cloneAlloc(allocator);
        }

        pub fn setResources(self: *Self, resources: AgentHarnessResources) !void {
            var clone = try resources.cloneAlloc(self.allocator);
            errdefer clone.deinit(self.allocator);
            self.resources.deinit(self.allocator);
            self.resources = clone;
        }

        pub fn getStreamOptionsAlloc(self: *const Self, allocator: std.mem.Allocator) !AgentHarnessStreamOptions {
            return try self.stream_options.cloneAlloc(allocator);
        }

        pub fn setStreamOptions(self: *Self, stream_options: AgentHarnessStreamOptions) !void {
            var clone = try stream_options.cloneAlloc(self.allocator);
            errdefer clone.deinit(self.allocator);
            self.stream_options.deinit(self.allocator);
            self.stream_options = clone;
        }

        pub fn beginTurn(self: *Self) !void {
            if (self.phase != .idle) return error.Busy;
            self.phase = .turn;
        }

        pub fn finishRun(self: *Self) void {
            self.phase = .idle;
            self.run_signal = null;
        }

        pub fn attachRunSignal(self: *Self, signal: *ai.AbortSignal) void {
            self.run_signal = signal;
        }

        pub fn steer(self: *Self, text: []const u8) !void {
            if (self.phase == .idle) return error.InvalidState;
            try self.steer_queue.append(self.allocator, try self.createUserMessage(text));
            try self.emitQueueUpdate();
        }

        pub fn followUp(self: *Self, text: []const u8) !void {
            if (self.phase == .idle) return error.InvalidState;
            try self.follow_up_queue.append(self.allocator, try self.createUserMessage(text));
            try self.emitQueueUpdate();
        }

        pub fn nextTurn(self: *Self, text: []const u8) !void {
            try self.next_turn_queue.append(self.allocator, try self.createUserMessage(text));
            try self.emitQueueUpdate();
        }

        pub fn drainSteeringAlloc(self: *Self, allocator: std.mem.Allocator) ![]types.AgentMessage {
            return try self.drainQueuedMessagesAlloc(allocator, &self.steer_queue, self.steering_mode);
        }

        pub fn drainFollowUpAlloc(self: *Self, allocator: std.mem.Allocator) ![]types.AgentMessage {
            return try self.drainQueuedMessagesAlloc(allocator, &self.follow_up_queue, self.follow_up_mode);
        }

        pub fn drainNextTurnAlloc(self: *Self, allocator: std.mem.Allocator) ![]types.AgentMessage {
            return try self.drainQueuedMessagesAlloc(allocator, &self.next_turn_queue, .all);
        }

        pub fn abortAlloc(self: *Self, allocator: std.mem.Allocator) !AbortResult {
            const cleared_steer = try allocator.dupe(types.AgentMessage, self.steer_queue.items);
            errdefer allocator.free(cleared_steer);
            const cleared_follow_up = try allocator.dupe(types.AgentMessage, self.follow_up_queue.items);
            errdefer allocator.free(cleared_follow_up);
            self.steer_queue.clearRetainingCapacity();
            self.follow_up_queue.clearRetainingCapacity();
            if (self.run_signal) |signal| signal.abort();
            try self.emitQueueUpdate();
            return .{
                .allocator = allocator,
                .cleared_steer = cleared_steer,
                .cleared_follow_up = cleared_follow_up,
            };
        }

        pub fn addBeforeProviderRequestHook(self: *Self, handler: BeforeProviderRequestHandler) !void {
            try self.before_provider_request_handlers.append(self.allocator, handler);
        }

        pub fn addBeforeProviderPayloadHook(self: *Self, handler: BeforeProviderPayloadHandler) !void {
            try self.before_provider_payload_handlers.append(self.allocator, handler);
        }

        pub fn prepareProviderRequestAlloc(
            self: *Self,
            allocator: std.mem.Allocator,
            session_id: []const u8,
            auth: AuthHeaders,
        ) !ProviderRequestOptions {
            var snapshot = try self.stream_options.cloneAlloc(allocator);
            errdefer snapshot.deinit(allocator);
            const merged_headers = try mergeHeadersAlloc(allocator, snapshot.headers, auth.headers);
            freeHeaders(allocator, snapshot.headers);
            snapshot.headers = merged_headers;

            const patched = try self.emitBeforeProviderRequestAlloc(allocator, self.model, session_id, snapshot);
            snapshot.deinit(allocator);

            return .{
                .allocator = allocator,
                .api_key = if (auth.api_key) |api_key| try allocator.dupe(u8, api_key) else null,
                .session_id = try allocator.dupe(u8, session_id),
                .stream_options = patched,
            };
        }

        pub fn emitBeforeProviderPayloadAlloc(
            self: *Self,
            allocator: std.mem.Allocator,
            model: *const ai.Model,
            payload_json: []const u8,
        ) ![]u8 {
            var current = try allocator.dupe(u8, payload_json);
            errdefer allocator.free(current);
            for (self.before_provider_payload_handlers.items) |handler| {
                const result = handler.call(.{
                    .model = model,
                    .payload_json = current,
                }) catch return error.Hook;
                if (result.payload_json) |next| {
                    const cloned = try allocator.dupe(u8, next);
                    allocator.free(current);
                    current = cloned;
                }
            }
            return current;
        }

        fn emitBeforeProviderRequestAlloc(
            self: *Self,
            allocator: std.mem.Allocator,
            model: *const ai.Model,
            session_id: []const u8,
            stream_options: AgentHarnessStreamOptions,
        ) !AgentHarnessStreamOptions {
            var current = try stream_options.cloneAlloc(allocator);
            errdefer current.deinit(allocator);
            for (self.before_provider_request_handlers.items) |handler| {
                var event_options = try current.cloneAlloc(allocator);
                defer event_options.deinit(allocator);
                const result = handler.call(.{
                    .model = model,
                    .session_id = session_id,
                    .stream_options = event_options,
                }) catch return error.Hook;
                if (result.stream_options) |patch| {
                    const next = try applyStreamOptionsPatchAlloc(allocator, current, patch);
                    current.deinit(allocator);
                    current = next;
                }
            }
            return current;
        }

        fn validateAndSetActiveToolNames(self: *Self, names: []const []const u8) !void {
            try self.validateToolNames(names, self.tools.items);
            const cloned = try cloneNameSliceAlloc(self.allocator, names);
            errdefer freeNameSlice(self.allocator, cloned);
            for (cloned) |name| try self.active_tool_names.append(self.allocator, name);
            self.allocator.free(cloned);
        }

        fn validateToolNames(self: *const Self, names: []const []const u8, tools: []const AgentTool) !void {
            _ = self;
            try validateUniqueNames(names, "Duplicate active tool name");
            for (names) |name| {
                if (!containsToolName(tools, name)) return error.InvalidArgument;
            }
        }

        fn findTool(self: *const Self, name: []const u8) ?AgentTool {
            for (self.tools.items) |tool| {
                if (std.mem.eql(u8, tool.name, name)) return tool;
            }
            return null;
        }

        fn createUserMessage(self: *Self, text: []const u8) !types.AgentMessage {
            const arena_allocator = self.arena.allocator();
            const owned_text = try arena_allocator.dupe(u8, text);
            const content = try arena_allocator.alloc(ai.UserContent, 1);
            content[0] = .{ .text = .{ .text = owned_text } };
            return .{ .user = .{
                .content = content,
                .timestamp_ms = 0,
            } };
        }

        fn drainQueuedMessagesAlloc(
            self: *Self,
            allocator: std.mem.Allocator,
            queue: *std.ArrayList(types.AgentMessage),
            mode: QueueMode,
        ) ![]types.AgentMessage {
            const count = switch (mode) {
                .all => queue.items.len,
                .one_at_a_time => @min(queue.items.len, 1),
            };
            const output = try allocator.alloc(types.AgentMessage, count);
            for (0..count) |index| output[index] = queue.items[index];
            if (count > 0) {
                for (0..(queue.items.len - count)) |index| {
                    queue.items[index] = queue.items[index + count];
                }
                queue.shrinkRetainingCapacity(queue.items.len - count);
                try self.emitQueueUpdate();
            }
            return output;
        }

        fn emitQueueUpdate(self: *Self) !void {
            try self.queue_updates.append(self.allocator, .{
                .steer = self.steer_queue.items.len,
                .follow_up = self.follow_up_queue.items.len,
                .next_turn = self.next_turn_queue.items.len,
            });
        }
    };
}

pub fn applyStreamOptionsPatchAlloc(
    allocator: std.mem.Allocator,
    base: AgentHarnessStreamOptions,
    patch: AgentHarnessStreamOptionsPatch,
) !AgentHarnessStreamOptions {
    var result = try base.cloneAlloc(allocator);
    errdefer result.deinit(allocator);

    switch (patch.transport) {
        .unchanged => {},
        .clear => result.transport = null,
        .set => |value| result.transport = value,
    }
    switch (patch.timeout_ms) {
        .unchanged => {},
        .clear => result.timeout_ms = null,
        .set => |value| result.timeout_ms = value,
    }
    switch (patch.max_retries) {
        .unchanged => {},
        .clear => result.max_retries = null,
        .set => |value| result.max_retries = value,
    }
    switch (patch.max_retry_delay_ms) {
        .unchanged => {},
        .clear => result.max_retry_delay_ms = null,
        .set => |value| result.max_retry_delay_ms = value,
    }
    switch (patch.cache_retention) {
        .unchanged => {},
        .clear => result.cache_retention = null,
        .set => |value| result.cache_retention = value,
    }

    switch (patch.headers) {
        .unchanged => {},
        .clear => {
            freeHeaders(allocator, result.headers);
            result.headers = &.{};
        },
        .merge => |entries| {
            const next = try applyHeaderPatchAlloc(allocator, result.headers, entries);
            freeHeaders(allocator, result.headers);
            result.headers = next;
        },
    }

    switch (patch.metadata) {
        .unchanged => {},
        .clear => {
            freeMetadata(allocator, result.metadata);
            result.metadata = &.{};
        },
        .merge => |entries| {
            const next = try applyMetadataPatchAlloc(allocator, result.metadata, entries);
            freeMetadata(allocator, result.metadata);
            result.metadata = next;
        },
    }

    return result;
}

pub fn mergeHeadersAlloc(
    allocator: std.mem.Allocator,
    first: []const ai.Header,
    second: []const ai.Header,
) ![]ai.Header {
    var result = try cloneHeadersAlloc(allocator, first);
    errdefer freeHeaders(allocator, result);

    for (second) |header| {
        if (findHeaderIndex(result, header.name)) |index| {
            allocator.free(@constCast(result[index].value));
            result[index].value = try allocator.dupe(u8, header.value);
        } else {
            const extended = try allocator.realloc(result, result.len + 1);
            result = extended;
            result[result.len - 1] = .{
                .name = try allocator.dupe(u8, header.name),
                .value = try allocator.dupe(u8, header.value),
            };
        }
    }
    return result;
}

fn applyHeaderPatchAlloc(
    allocator: std.mem.Allocator,
    base: []const ai.Header,
    entries: []const HeaderPatchEntry,
) ![]ai.Header {
    var result = try cloneHeadersAlloc(allocator, base);
    errdefer freeHeaders(allocator, result);

    for (entries) |entry| {
        if (entry.value) |value| {
            if (findHeaderIndex(result, entry.name)) |index| {
                allocator.free(@constCast(result[index].value));
                result[index].value = try allocator.dupe(u8, value);
            } else {
                result = try allocator.realloc(result, result.len + 1);
                result[result.len - 1] = .{
                    .name = try allocator.dupe(u8, entry.name),
                    .value = try allocator.dupe(u8, value),
                };
            }
        } else if (findHeaderIndex(result, entry.name)) |index| {
            allocator.free(@constCast(result[index].name));
            allocator.free(@constCast(result[index].value));
            for (index..(result.len - 1)) |shift| result[shift] = result[shift + 1];
            result = try allocator.realloc(result, result.len - 1);
        }
    }
    return result;
}

fn applyMetadataPatchAlloc(
    allocator: std.mem.Allocator,
    base: []const MetadataEntry,
    entries: []const MetadataPatchEntry,
) ![]MetadataEntry {
    var result = try cloneMetadataAlloc(allocator, base);
    errdefer freeMetadata(allocator, result);

    for (entries) |entry| {
        if (entry.value_json) |value_json| {
            if (findMetadataIndex(result, entry.key)) |index| {
                allocator.free(@constCast(result[index].value_json));
                result[index].value_json = try allocator.dupe(u8, value_json);
            } else {
                result = try allocator.realloc(result, result.len + 1);
                result[result.len - 1] = .{
                    .key = try allocator.dupe(u8, entry.key),
                    .value_json = try allocator.dupe(u8, value_json),
                };
            }
        } else if (findMetadataIndex(result, entry.key)) |index| {
            allocator.free(@constCast(result[index].key));
            allocator.free(@constCast(result[index].value_json));
            for (index..(result.len - 1)) |shift| result[shift] = result[shift + 1];
            result = try allocator.realloc(result, result.len - 1);
        }
    }
    return result;
}

fn cloneHeadersAlloc(allocator: std.mem.Allocator, headers: []const ai.Header) ![]ai.Header {
    if (headers.len == 0) return try allocator.alloc(ai.Header, 0);
    const output = try allocator.alloc(ai.Header, headers.len);
    errdefer allocator.free(output);
    for (headers, 0..) |header, index| {
        output[index] = .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        };
    }
    return output;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const ai.Header) void {
    if (headers.len == 0) return;
    for (headers) |header| {
        allocator.free(@constCast(header.name));
        allocator.free(@constCast(header.value));
    }
    allocator.free(@constCast(headers));
}

fn cloneMetadataAlloc(allocator: std.mem.Allocator, metadata: []const MetadataEntry) ![]MetadataEntry {
    if (metadata.len == 0) return try allocator.alloc(MetadataEntry, 0);
    const output = try allocator.alloc(MetadataEntry, metadata.len);
    errdefer allocator.free(output);
    for (metadata, 0..) |entry, index| {
        output[index] = .{
            .key = try allocator.dupe(u8, entry.key),
            .value_json = try allocator.dupe(u8, entry.value_json),
        };
    }
    return output;
}

fn freeMetadata(allocator: std.mem.Allocator, metadata: []const MetadataEntry) void {
    if (metadata.len == 0) return;
    for (metadata) |entry| {
        allocator.free(@constCast(entry.key));
        allocator.free(@constCast(entry.value_json));
    }
    allocator.free(@constCast(metadata));
}

fn metadataJsonAlloc(allocator: std.mem.Allocator, metadata: []const MetadataEntry) !?[]u8 {
    if (metadata.len == 0) return null;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    for (metadata, 0..) |entry, index| {
        if (index > 0) try output.append(allocator, ',');
        try std.json.Stringify.value(entry.key, .{}, output.writer(allocator));
        try output.append(allocator, ':');
        try output.appendSlice(allocator, entry.value_json);
    }
    try output.append(allocator, '}');
    return try output.toOwnedSlice(allocator);
}

fn cloneResourcesAlloc(allocator: std.mem.Allocator, resources: []const ResourceRef) ![]ResourceRef {
    if (resources.len == 0) return try allocator.alloc(ResourceRef, 0);
    const output = try allocator.alloc(ResourceRef, resources.len);
    errdefer allocator.free(output);
    for (resources, 0..) |resource, index| output[index] = try resource.cloneAlloc(allocator);
    return output;
}

fn freeResources(allocator: std.mem.Allocator, resources: []const ResourceRef) void {
    if (resources.len == 0) return;
    for (@constCast(resources)) |*resource| resource.deinit(allocator);
    allocator.free(@constCast(resources));
}

fn cloneToolsAlloc(allocator: std.mem.Allocator, tools: []const AgentTool) ![]AgentTool {
    if (tools.len == 0) return try allocator.alloc(AgentTool, 0);
    const output = try allocator.alloc(AgentTool, tools.len);
    errdefer allocator.free(output);
    for (tools, 0..) |tool, index| output[index] = try tool.cloneAlloc(allocator);
    return output;
}

fn freeTools(allocator: std.mem.Allocator, tools: []const AgentTool) void {
    if (tools.len == 0) return;
    for (@constCast(tools)) |*tool| tool.deinit(allocator);
    allocator.free(@constCast(tools));
}

fn cloneNameSliceAlloc(allocator: std.mem.Allocator, names: []const []const u8) ![][]u8 {
    if (names.len == 0) return try allocator.alloc([]u8, 0);
    const output = try allocator.alloc([]u8, names.len);
    errdefer allocator.free(output);
    for (names, 0..) |name, index| output[index] = try allocator.dupe(u8, name);
    return output;
}

fn freeNameSlice(allocator: std.mem.Allocator, names: [][]u8) void {
    if (names.len == 0) return;
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn validateUniqueToolNames(tools: []const AgentTool, message: []const u8) !void {
    for (tools, 0..) |tool, index| {
        for (tools[(index + 1)..]) |other| {
            if (std.mem.eql(u8, tool.name, other.name)) {
                _ = message;
                return error.InvalidArgument;
            }
        }
    }
}

fn validateUniqueNames(names: []const []const u8, message: []const u8) !void {
    for (names, 0..) |name, index| {
        for (names[(index + 1)..]) |other| {
            if (std.mem.eql(u8, name, other)) {
                _ = message;
                return error.InvalidArgument;
            }
        }
    }
}

fn containsToolName(tools: []const AgentTool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

fn findHeaderIndex(headers: []const ai.Header, name: []const u8) ?usize {
    for (headers, 0..) |header, index| {
        if (std.mem.eql(u8, header.name, name)) return index;
    }
    return null;
}

fn findMetadataIndex(metadata: []const MetadataEntry, key: []const u8) ?usize {
    for (metadata, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.key, key)) return index;
    }
    return null;
}

fn thinkingLevelName(level: ai.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn expectHeaderValues(headers: []const ai.Header, expected: []const ai.Header) !void {
    try std.testing.expectEqual(expected.len, headers.len);
    for (expected, 0..) |entry, index| {
        try std.testing.expectEqualStrings(entry.name, headers[index].name);
        try std.testing.expectEqualStrings(entry.value, headers[index].value);
    }
}

fn userText(message: types.AgentMessage) []const u8 {
    return switch (message) {
        .user => |user| switch (user.content[0]) {
            .text => |text| text.text,
            else => "",
        },
        else => "",
    };
}

fn testModel(id: []const u8) ai.Model {
    return .{
        .id = id,
        .name = id,
        .api = "faux",
        .provider = "faux",
        .base_url = "http://localhost",
        .reasoning = true,
    };
}

fn nullEnv() types.ExecutionEnv {
    return .{ .cwd = "/tmp" };
}

const RequestHookState = struct {
    seen_headers: std.ArrayList([]u8) = .empty,

    fn deinit(self: *RequestHookState, allocator: std.mem.Allocator) void {
        for (self.seen_headers.items) |value| allocator.free(value);
        self.seen_headers.deinit(allocator);
    }

    fn first(ptr: ?*anyopaque, event: BeforeProviderRequestEvent) !BeforeProviderRequestResult {
        const self: *RequestHookState = @ptrCast(@alignCast(ptr.?));
        const value = if (findHeaderIndex(event.stream_options.headers, "remove")) |index|
            event.stream_options.headers[index].value
        else
            "missing";
        try self.seen_headers.append(std.testing.allocator, try std.testing.allocator.dupe(u8, value));
        return .{ .stream_options = .{
            .headers = .{ .merge = &.{
                .{ .name = "first", .value = "1" },
                .{ .name = "remove", .value = null },
            } },
            .metadata = .{ .merge = &.{
                .{ .key = "first", .value_json = "1" },
                .{ .key = "remove", .value_json = null },
            } },
        } };
    }

    fn second(ptr: ?*anyopaque, event: BeforeProviderRequestEvent) !BeforeProviderRequestResult {
        const self: *RequestHookState = @ptrCast(@alignCast(ptr.?));
        const value = if (findHeaderIndex(event.stream_options.headers, "first")) |index|
            event.stream_options.headers[index].value
        else
            "missing";
        try self.seen_headers.append(std.testing.allocator, try std.testing.allocator.dupe(u8, value));
        return .{ .stream_options = .{
            .timeout_ms = .clear,
            .headers = .{ .merge = &.{.{ .name = "second", .value = "2" }} },
            .metadata = .clear,
        } };
    }
};

const PayloadHookState = struct {
    seen: std.ArrayList([]u8) = .empty,

    fn deinit(self: *PayloadHookState, allocator: std.mem.Allocator) void {
        for (self.seen.items) |value| allocator.free(value);
        self.seen.deinit(allocator);
    }

    fn first(ptr: ?*anyopaque, event: BeforeProviderPayloadEvent) !BeforeProviderPayloadResult {
        const self: *PayloadHookState = @ptrCast(@alignCast(ptr.?));
        try self.seen.append(std.testing.allocator, try std.testing.allocator.dupe(u8, event.payload_json));
        return .{ .payload_json = "{\"steps\":[\"provider\",\"first\"]}" };
    }

    fn second(ptr: ?*anyopaque, event: BeforeProviderPayloadEvent) !BeforeProviderPayloadResult {
        const self: *PayloadHookState = @ptrCast(@alignCast(ptr.?));
        try self.seen.append(std.testing.allocator, try std.testing.allocator.dupe(u8, event.payload_json));
        return .{ .payload_json = "{\"steps\":[\"provider\",\"first\",\"second\"]}" };
    }
};

// Ported from packages/agent/test/harness/agent-harness.test.ts constructor and queue-mode coverage.
test "agent harness constructs directly and exposes queue modes" {
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);
    const model = testModel("first");
    var harness = try AgentHarness(@TypeOf(session)).init(allocator, .{
        .env = nullEnv(),
        .session = &session,
        .model = &model,
        .thinking_level = .high,
        .steering_mode = .all,
        .follow_up_mode = .all,
    });
    defer harness.deinit();

    try std.testing.expectEqual(&model, harness.getModel());
    try std.testing.expectEqual(ai.ThinkingLevel.high, harness.getThinkingLevel());
    try std.testing.expectEqual(QueueMode.all, harness.getSteeringMode());
    try std.testing.expectEqual(QueueMode.all, harness.getFollowUpMode());
    harness.setSteeringMode(.one_at_a_time);
    harness.setFollowUpMode(.one_at_a_time);
    try std.testing.expectEqual(QueueMode.one_at_a_time, harness.getSteeringMode());
    try std.testing.expectEqual(QueueMode.one_at_a_time, harness.getFollowUpMode());
}

// Ported from packages/agent/test/harness/agent-harness.test.ts queue update regressions.
test "agent harness drains steering and follow-up queues by configured mode" {
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);
    const model = testModel("first");
    var harness = try AgentHarness(@TypeOf(session)).init(allocator, .{
        .env = nullEnv(),
        .session = &session,
        .model = &model,
        .steering_mode = .one_at_a_time,
        .follow_up_mode = .all,
    });
    defer harness.deinit();

    try std.testing.expectError(error.InvalidState, harness.steer("idle"));
    try harness.beginTurn();
    try harness.steer("one");
    try harness.steer("two");
    try harness.followUp("follow one");
    try harness.followUp("follow two");

    const first = try harness.drainSteeringAlloc(allocator);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("one", userText(first[0]));
    try std.testing.expectEqual(@as(usize, 1), harness.steer_queue.items.len);

    const second = try harness.drainSteeringAlloc(allocator);
    defer allocator.free(second);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("two", userText(second[0]));
    try std.testing.expectEqual(@as(usize, 0), harness.steer_queue.items.len);

    const follow_up = try harness.drainFollowUpAlloc(allocator);
    defer allocator.free(follow_up);
    try std.testing.expectEqual(@as(usize, 2), follow_up.len);
    try std.testing.expectEqualStrings("follow one", userText(follow_up[0]));
    try std.testing.expectEqualStrings("follow two", userText(follow_up[1]));
    try std.testing.expectEqualSlices(QueueUpdateSnapshot, &.{
        .{ .steer = 1, .follow_up = 0, .next_turn = 0 },
        .{ .steer = 2, .follow_up = 0, .next_turn = 0 },
        .{ .steer = 2, .follow_up = 1, .next_turn = 0 },
        .{ .steer = 2, .follow_up = 2, .next_turn = 0 },
        .{ .steer = 1, .follow_up = 2, .next_turn = 0 },
        .{ .steer = 0, .follow_up = 2, .next_turn = 0 },
        .{ .steer = 0, .follow_up = 0, .next_turn = 0 },
    }, harness.queue_updates.items);
}

// Ported from packages/agent/test/harness/agent-harness.test.ts abort queue handling.
test "agent harness abort clears steer and follow-up queues but preserves next-turn messages" {
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);
    const model = testModel("first");
    var harness = try AgentHarness(@TypeOf(session)).init(allocator, .{
        .env = nullEnv(),
        .session = &session,
        .model = &model,
    });
    defer harness.deinit();
    var signal: ai.AbortSignal = .{};

    try harness.beginTurn();
    harness.attachRunSignal(&signal);
    try harness.steer("steer");
    try harness.followUp("follow");
    try harness.nextTurn("next");
    var result = try harness.abortAlloc(allocator);
    defer result.deinit();

    try std.testing.expect(signal.aborted);
    try std.testing.expectEqual(@as(usize, 1), result.cleared_steer.len);
    try std.testing.expectEqual(@as(usize, 1), result.cleared_follow_up.len);
    try std.testing.expectEqualStrings("steer", userText(result.cleared_steer[0]));
    try std.testing.expectEqualStrings("follow", userText(result.cleared_follow_up[0]));
    try std.testing.expectEqual(@as(usize, 0), harness.steer_queue.items.len);
    try std.testing.expectEqual(@as(usize, 0), harness.follow_up_queue.items.len);
    try std.testing.expectEqual(@as(usize, 1), harness.next_turn_queue.items.len);
    try std.testing.expectEqual(QueueUpdateSnapshot{ .steer = 0, .follow_up = 0, .next_turn = 1 }, harness.queue_updates.items[harness.queue_updates.items.len - 1]);
}

// Ported from packages/agent/test/harness/agent-harness-stream.test.ts stream patch behavior.
test "agent harness stream options merge headers metadata and deletion patches" {
    const allocator = std.testing.allocator;
    const base = AgentHarnessStreamOptions{
        .timeout_ms = 1000,
        .max_retries = 2,
        .headers = &.{
            .{ .name = "keep", .value = "base" },
            .{ .name = "remove", .value = "base" },
        },
        .metadata = &.{
            .{ .key = "keep", .value_json = "\"base\"" },
            .{ .key = "remove", .value_json = "\"base\"" },
        },
    };

    var patched = try applyStreamOptionsPatchAlloc(allocator, base, .{
        .timeout_ms = .clear,
        .headers = .{ .merge = &.{
            .{ .name = "first", .value = "1" },
            .{ .name = "remove", .value = null },
            .{ .name = "second", .value = "2" },
        } },
        .metadata = .{ .merge = &.{
            .{ .key = "first", .value_json = "1" },
            .{ .key = "remove", .value_json = null },
        } },
    });
    defer patched.deinit(allocator);

    try std.testing.expectEqual(@as(?u64, null), patched.timeout_ms);
    try std.testing.expectEqual(@as(?u32, 2), patched.max_retries);
    try expectHeaderValues(patched.headers, &.{
        .{ .name = "keep", .value = "base" },
        .{ .name = "first", .value = "1" },
        .{ .name = "second", .value = "2" },
    });
    try std.testing.expectEqual(@as(usize, 2), patched.metadata.len);
    try std.testing.expectEqualStrings("keep", patched.metadata[0].key);
    try std.testing.expectEqualStrings("\"base\"", patched.metadata[0].value_json);
    try std.testing.expectEqualStrings("first", patched.metadata[1].key);
    try std.testing.expectEqualStrings("1", patched.metadata[1].value_json);

    var cleared = try applyStreamOptionsPatchAlloc(allocator, patched, .{ .headers = .clear, .metadata = .clear });
    defer cleared.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), cleared.headers.len);
    try std.testing.expectEqual(@as(usize, 0), cleared.metadata.len);
}

// Ported from packages/agent/test/harness/agent-harness-stream.test.ts provider request hooks.
test "agent harness snapshots stream options and chains provider request hooks" {
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{
        .metadata = .{ .id = "session-1", .created_at = "now" },
    });
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);
    const model = testModel("first");
    var harness = try AgentHarness(@TypeOf(session)).init(allocator, .{
        .env = nullEnv(),
        .session = &session,
        .model = &model,
        .stream_options = .{
            .timeout_ms = 1000,
            .max_retries = 2,
            .max_retry_delay_ms = 3000,
            .headers = &.{
                .{ .name = "x-base", .value = "base" },
                .{ .name = "remove", .value = "base" },
            },
            .metadata = &.{
                .{ .key = "base", .value_json = "true" },
                .{ .key = "remove", .value_json = "true" },
            },
            .cache_retention = .none,
        },
    });
    defer harness.deinit();
    var state: RequestHookState = .{};
    defer state.deinit(allocator);
    try harness.addBeforeProviderRequestHook(.{ .ptr = &state, .call_fn = RequestHookState.first });
    try harness.addBeforeProviderRequestHook(.{ .ptr = &state, .call_fn = RequestHookState.second });

    var request = try harness.prepareProviderRequestAlloc(allocator, "session-1", .{
        .api_key = "secret",
        .headers = &.{.{ .name = "x-auth", .value = "auth" }},
    });
    defer request.deinit();

    try std.testing.expectEqualStrings("secret", request.api_key.?);
    try std.testing.expectEqualStrings("session-1", request.session_id);
    try std.testing.expectEqual(@as(?u64, null), request.stream_options.timeout_ms);
    try std.testing.expectEqual(@as(?u32, 2), request.stream_options.max_retries);
    try std.testing.expectEqual(@as(?u64, 3000), request.stream_options.max_retry_delay_ms);
    try std.testing.expectEqual(ai.CacheRetention.none, request.stream_options.cache_retention.?);
    try expectHeaderValues(request.stream_options.headers, &.{
        .{ .name = "x-base", .value = "base" },
        .{ .name = "x-auth", .value = "auth" },
        .{ .name = "first", .value = "1" },
        .{ .name = "second", .value = "2" },
    });
    try std.testing.expectEqual(@as(usize, 0), request.stream_options.metadata.len);
    try std.testing.expectEqualStrings("base", state.seen_headers.items[0]);
    try std.testing.expectEqualStrings("1", state.seen_headers.items[1]);
}

// Ported from packages/agent/test/harness/agent-harness-stream.test.ts save-point stream snapshots.
test "agent harness uses updated stream options for later save-point snapshots" {
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);
    const model = testModel("first");
    var harness = try AgentHarness(@TypeOf(session)).init(allocator, .{
        .env = nullEnv(),
        .session = &session,
        .model = &model,
        .stream_options = .{
            .timeout_ms = 1000,
            .headers = &.{.{ .name = "turn", .value = "first" }},
        },
    });
    defer harness.deinit();

    var first_request = try harness.prepareProviderRequestAlloc(allocator, "session-1", .{});
    defer first_request.deinit();

    try harness.setStreamOptions(.{
        .timeout_ms = 2000,
        .headers = &.{.{ .name = "turn", .value = "second" }},
    });
    var second_request = try harness.prepareProviderRequestAlloc(allocator, "session-1", .{});
    defer second_request.deinit();

    try std.testing.expectEqual(@as(?u64, 1000), first_request.stream_options.timeout_ms);
    try expectHeaderValues(first_request.stream_options.headers, &.{.{ .name = "turn", .value = "first" }});
    try std.testing.expectEqual(@as(?u64, 2000), second_request.stream_options.timeout_ms);
    try expectHeaderValues(second_request.stream_options.headers, &.{.{ .name = "turn", .value = "second" }});
}

// Ported from packages/agent/test/harness/agent-harness-stream.test.ts provider payload hooks.
test "agent harness chains provider payload hooks" {
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);
    const model = testModel("first");
    var harness = try AgentHarness(@TypeOf(session)).init(allocator, .{
        .env = nullEnv(),
        .session = &session,
        .model = &model,
    });
    defer harness.deinit();
    var state: PayloadHookState = .{};
    defer state.deinit(allocator);
    try harness.addBeforeProviderPayloadHook(.{ .ptr = &state, .call_fn = PayloadHookState.first });
    try harness.addBeforeProviderPayloadHook(.{ .ptr = &state, .call_fn = PayloadHookState.second });

    const final_payload = try harness.emitBeforeProviderPayloadAlloc(allocator, &model, "{\"steps\":[\"provider\"]}");
    defer allocator.free(final_payload);

    try std.testing.expectEqualStrings("{\"steps\":[\"provider\"]}", state.seen.items[0]);
    try std.testing.expectEqualStrings("{\"steps\":[\"provider\",\"first\"]}", state.seen.items[1]);
    try std.testing.expectEqualStrings("{\"steps\":[\"provider\",\"first\",\"second\"]}", final_payload);
}

// Ported from packages/agent/test/harness/agent-harness.test.ts tool and resource getter/update coverage.
test "agent harness validates and updates tools resources model and thinking state" {
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);
    const first_model = testModel("first");
    const second_model = testModel("second");
    const inspect: AgentTool = .{ .name = "inspect", .description = "Inspect", .source = "builtin" };
    const search: AgentTool = .{ .name = "search", .description = "Search", .source = "extension" };
    var harness = try AgentHarness(@TypeOf(session)).init(allocator, .{
        .env = nullEnv(),
        .session = &session,
        .model = &first_model,
        .tools = &.{ inspect, search },
        .active_tool_names = &.{"inspect"},
    });
    defer harness.deinit();

    const tools = try harness.getToolsAlloc(allocator);
    defer freeTools(allocator, tools);
    const active_tools = try harness.getActiveToolsAlloc(allocator);
    defer freeTools(allocator, active_tools);
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("builtin", active_tools[0].source.?);

    try harness.setActiveTools(&.{"search"});
    try harness.setTools(&.{search}, &.{"search"});
    try std.testing.expectError(error.InvalidArgument, harness.setActiveTools(&.{"missing"}));
    try std.testing.expectError(error.InvalidArgument, harness.setActiveTools(&.{ "search", "search" }));
    try std.testing.expectError(error.InvalidArgument, harness.setTools(&.{inspect}, null));
    try std.testing.expectError(error.InvalidArgument, harness.setTools(&.{ inspect, inspect }, &.{"inspect"}));

    try harness.setModel(&second_model);
    try harness.setThinkingLevel(.high);
    try std.testing.expectEqual(&second_model, harness.getModel());
    try std.testing.expectEqual(ai.ThinkingLevel.high, harness.getThinkingLevel());

    const context = try session.buildContextAlloc(allocator);
    defer {
        var owned_context = context;
        owned_context.deinit();
    }
    try std.testing.expectEqualStrings("second", context.model.?.model_id);
    try std.testing.expectEqualStrings("high", context.thinking_level);
    try std.testing.expectEqualStrings("search", context.active_tool_names.?[0]);

    try harness.setResources(.{
        .skills = &.{.{ .name = "inspect", .description = "Inspect", .content = "Use inspection tools.", .source = "project" }},
        .prompt_templates = &.{.{ .name = "review", .content = "Review $1", .source = "user" }},
    });
    var resources = try harness.getResourcesAlloc(allocator);
    defer resources.deinit(allocator);
    try std.testing.expectEqualStrings("project", resources.skills[0].source.?);
    try std.testing.expectEqualStrings("user", resources.prompt_templates[0].source.?);
}
