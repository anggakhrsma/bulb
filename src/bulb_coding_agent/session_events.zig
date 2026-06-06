const std = @import("std");

const ai = @import("bulb_ai");
const auth_storage = @import("auth_storage.zig");
const config_value = @import("resolve_config_value.zig");
const extensions = @import("extensions/root.zig");
const messages = @import("messages.zig");
const model_registry = @import("model_registry.zig");
const session_manager = @import("session_manager.zig");
const source_info = @import("source_info.zig");

pub const AgentEndSessionEvent = struct {
    messages: []messages.CodingAgentMessage,
    will_retry: bool,
};

pub const TurnStartSessionEvent = struct {
    turn_index: usize,
    timestamp_ms: i64,
};

pub const TurnEndSessionEvent = struct {
    turn_index: usize,
    message: messages.CodingAgentMessage,
    tool_results: []ai.ToolResultMessage,
};

pub const MessageSessionEvent = struct {
    message: messages.CodingAgentMessage,
};

pub const MessageUpdateSessionEvent = struct {
    message: messages.CodingAgentMessage,
    assistant_message_event: ai.StreamEvent,
};

pub const ToolExecutionStartSessionEvent = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,
};

pub const ToolExecutionUpdateSessionEvent = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    args: std.json.Value,
    partial_result: std.json.Value,
};

pub const ToolExecutionEndSessionEvent = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    result: std.json.Value,
    is_error: bool,
};

pub const SessionEvent = union(enum) {
    agent_start: void,
    agent_end: AgentEndSessionEvent,
    turn_start: TurnStartSessionEvent,
    turn_end: TurnEndSessionEvent,
    message_start: MessageSessionEvent,
    message_update: MessageUpdateSessionEvent,
    message_end: MessageSessionEvent,
    tool_execution_start: ToolExecutionStartSessionEvent,
    tool_execution_update: ToolExecutionUpdateSessionEvent,
    tool_execution_end: ToolExecutionEndSessionEvent,
};

pub const SessionEventListener = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, SessionEvent) void,

    pub fn call(self: SessionEventListener, event: SessionEvent) void {
        self.call_fn(self.ptr, event);
    }
};

pub const MessageEndListener = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, messages.CodingAgentMessage) void,

    pub fn call(self: MessageEndListener, message: messages.CodingAgentMessage) void {
        self.call_fn(self.ptr, message);
    }
};

pub const SessionEventBridge = struct {
    allocator: std.mem.Allocator,
    turn_index: usize = 0,
    message_end_replacements: std.ArrayList(extensions.MessageEndEmitResult) = .empty,
    event_listeners: std.ArrayList(SessionEventListener) = .empty,
    message_end_listeners: std.ArrayList(MessageEndListener) = .empty,

    pub fn init(allocator: std.mem.Allocator) SessionEventBridge {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionEventBridge) void {
        for (self.message_end_replacements.items) |*replacement| replacement.deinit();
        self.message_end_replacements.deinit(self.allocator);
        self.event_listeners.deinit(self.allocator);
        self.message_end_listeners.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn subscribe(self: *SessionEventBridge, listener: SessionEventListener) !void {
        try self.event_listeners.append(self.allocator, listener);
    }

    pub fn onMessageEnd(self: *SessionEventBridge, listener: MessageEndListener) !void {
        try self.message_end_listeners.append(self.allocator, listener);
    }

    pub fn handleAgentStart(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
    ) !void {
        self.turn_index = 0;
        _ = try runner.emit(.{ .agent_start = .{} });
        self.emitPublic(.{ .agent_start = {} });
    }

    pub fn handleAgentEnd(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        agent_messages: []messages.CodingAgentMessage,
        will_retry: bool,
    ) !void {
        _ = try runner.emit(.{ .agent_end = .{ .messages = agent_messages } });
        self.emitPublic(.{ .agent_end = .{
            .messages = agent_messages,
            .will_retry = will_retry,
        } });
    }

    pub fn handleTurnStart(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        timestamp_ms: i64,
    ) !void {
        const event = TurnStartSessionEvent{
            .turn_index = self.turn_index,
            .timestamp_ms = timestamp_ms,
        };
        _ = try runner.emit(.{ .turn_start = .{
            .turn_index = event.turn_index,
            .timestamp_ms = event.timestamp_ms,
        } });
        self.emitPublic(.{ .turn_start = event });
    }

    pub fn handleTurnEnd(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        message: messages.CodingAgentMessage,
        tool_results: []ai.ToolResultMessage,
    ) !void {
        const event = TurnEndSessionEvent{
            .turn_index = self.turn_index,
            .message = message,
            .tool_results = tool_results,
        };
        _ = try runner.emit(.{ .turn_end = .{
            .turn_index = event.turn_index,
            .message = event.message,
            .tool_results = event.tool_results,
        } });
        self.emitPublic(.{ .turn_end = event });
        self.turn_index += 1;
    }

    pub fn handleMessageStart(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        message: messages.CodingAgentMessage,
    ) !void {
        _ = try runner.emit(.{ .message_start = .{ .message = message } });
        self.emitPublic(.{ .message_start = .{ .message = message } });
    }

    pub fn handleMessageUpdate(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        message: messages.CodingAgentMessage,
        assistant_message_event: ai.StreamEvent,
    ) !void {
        _ = try runner.emit(.{ .message_update = .{
            .message = message,
            .assistant_message_event = assistant_message_event,
        } });
        self.emitPublic(.{ .message_update = .{
            .message = message,
            .assistant_message_event = assistant_message_event,
        } });
    }

    pub fn handleMessageEnd(
        self: *SessionEventBridge,
        io: std.Io,
        runner: *extensions.ExtensionRunner,
        sessions: *session_manager.SessionManager,
        message: *messages.CodingAgentMessage,
    ) !void {
        try self.emitMessageEndExtensions(runner, message);
        self.emitPublic(.{ .message_end = .{ .message = message.* } });
        try persistMessageEnd(io, sessions, self.allocator, message.*);
    }

    pub fn handleToolExecutionStart(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        event: ToolExecutionStartSessionEvent,
    ) !void {
        _ = try runner.emit(.{ .tool_execution_start = .{
            .tool_call_id = event.tool_call_id,
            .tool_name = event.tool_name,
            .args = event.args,
        } });
        self.emitPublic(.{ .tool_execution_start = event });
    }

    pub fn handleToolExecutionUpdate(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        event: ToolExecutionUpdateSessionEvent,
    ) !void {
        _ = try runner.emit(.{ .tool_execution_update = .{
            .tool_call_id = event.tool_call_id,
            .tool_name = event.tool_name,
            .args = event.args,
            .partial_result = event.partial_result,
        } });
        self.emitPublic(.{ .tool_execution_update = event });
    }

    pub fn handleToolExecutionEnd(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        event: ToolExecutionEndSessionEvent,
    ) !void {
        _ = try runner.emit(.{ .tool_execution_end = .{
            .tool_call_id = event.tool_call_id,
            .tool_name = event.tool_name,
            .result = event.result,
            .is_error = event.is_error,
        } });
        self.emitPublic(.{ .tool_execution_end = event });
    }

    fn emitMessageEndExtensions(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        message: *messages.CodingAgentMessage,
    ) !void {
        var replacement = (try runner.emitMessageEndAlloc(
            self.allocator,
            .{ .message = message.* },
        )) orelse return;
        var stored = false;
        errdefer if (!stored) replacement.deinit();

        try self.message_end_replacements.append(self.allocator, replacement);
        stored = true;
        message.* = self.message_end_replacements.items[self.message_end_replacements.items.len - 1].message;
    }

    fn emitPublic(self: *SessionEventBridge, event: SessionEvent) void {
        for (self.event_listeners.items) |listener| listener.call(event);
        switch (event) {
            .message_end => |payload| {
                for (self.message_end_listeners.items) |listener| listener.call(payload.message);
            },
            else => {},
        }
    }
};

fn persistMessageEnd(
    io: std.Io,
    sessions: *session_manager.SessionManager,
    allocator: std.mem.Allocator,
    message: messages.CodingAgentMessage,
) !void {
    switch (message) {
        .custom => |custom| {
            const content_json = try customContentJsonAlloc(allocator, custom.content);
            defer allocator.free(content_json);
            _ = try sessions.appendCustomMessageEntryJson(
                io,
                custom.custom_type,
                content_json,
                custom.display,
                custom.details_json,
            );
        },
        .user, .assistant, .tool_result => {
            _ = try sessions.appendMessage(io, message);
        },
        .bash_execution, .branch_summary, .compaction_summary => {},
    }
}

fn customContentJsonAlloc(
    allocator: std.mem.Allocator,
    content: messages.CustomContent,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };

    switch (content) {
        .text => |text| try json.write(text),
        .parts => |parts| try writeUserContentArray(&json, parts),
    }

    return output.toOwnedSlice();
}

fn writeUserContentArray(json: *std.json.Stringify, content: []const ai.UserContent) !void {
    try json.beginArray();
    for (content) |part| {
        try json.beginObject();
        switch (part) {
            .text => |text| {
                try json.objectField("type");
                try json.write("text");
                try json.objectField("text");
                try json.write(text.text);
            },
            .image => |image| {
                try json.objectField("type");
                try json.write("image");
                try json.objectField("data");
                try json.write(image.data);
                try json.objectField("mimeType");
                try json.write(image.mime_type);
            },
        }
        try json.endObject();
    }
    try json.endArray();
}

test "AgentSession message_end replacements update memory public event and persistence" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var handler_arena = std.heap.ArenaAllocator.init(allocator);
    defer handler_arena.deinit();

    var state = MessageEndReplacementState{ .allocator = handler_arena.allocator() };
    const handlers = [_]extensions.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .message_end,
        .handler_fn = MessageEndReplacementState.handler,
    }};
    const extension_list = [_]extensions.Extension{
        testExtension("/tmp/message-end-cost.zig", &handlers),
    };
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &extension_list,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var observed = MessageEndObserver{};
    try bridge.onMessageEnd(.{ .ptr = &observed, .call_fn = MessageEndObserver.onMessageEnd });

    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "original" } }};
    var message = messages.CodingAgentMessage{ .assistant = .{
        .content = &content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
        .usage = .{
            .input = 1,
            .output = 1,
            .total_tokens = 2,
            .cost = .{ .total = 0.001 },
        },
        .timestamp_ms = 42,
    } };

    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &message);

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqualStrings("patched", message.assistant.content[0].text.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.123), message.assistant.usage.cost.total, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.123), observed.assistant_cost_total.?, 0.000001);

    const entries = harness.sessions.getEntries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try expectEntryType(entries[0], "message");
    try expectPersistedAssistantTextAndCost(allocator, entries[0], "patched", 0.123);
}

test "AgentSession message_end skips persistence for bash and summary messages" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var runner = extensions.ExtensionRunner.init(
        allocator,
        &.{},
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();
    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();

    var bash_message = messages.CodingAgentMessage{ .bash_execution = .{
        .command = "zig build",
        .output = "ok",
        .timestamp_ms = 1,
    } };
    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &bash_message);

    var summary_message = messages.CodingAgentMessage{ .compaction_summary = .{
        .summary = "summary",
        .tokens_before = 10,
        .timestamp_ms = 2,
    } };
    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &summary_message);

    try std.testing.expectEqual(@as(usize, 0), harness.sessions.getEntries().len);
}

test "AgentSession bridge emits extension message events before public subscribers" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var order: std.ArrayList(MessageOrderObservation) = .empty;
    defer order.deinit(allocator);
    var state = MessageOrderState{ .allocator = allocator, .order = &order };
    const handlers = [_]extensions.ExtensionHandler{
        .{
            .ptr = &state,
            .event_name = .message_start,
            .handler_fn = MessageOrderState.extensionHandler,
        },
        .{
            .ptr = &state,
            .event_name = .message_end,
            .handler_fn = MessageOrderState.extensionHandler,
        },
    };
    const extension_list = [_]extensions.Extension{
        testExtension("/tmp/message-order.zig", &handlers),
    };
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &extension_list,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    try bridge.subscribe(.{ .ptr = &state, .call_fn = MessageOrderState.publicListener });

    const user_content = [_]ai.UserContent{.{ .text = .{ .text = "hi" } }};
    const user_message = messages.CodingAgentMessage{ .user = .{
        .content = &user_content,
        .timestamp_ms = 1,
    } };
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "done" } }};
    const assistant_message = messages.CodingAgentMessage{ .assistant = .{
        .content = &assistant_content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
        .usage = .{},
        .timestamp_ms = 2,
    } };

    var user_end = user_message;
    var assistant_end = assistant_message;
    try bridge.handleMessageStart(&runner, user_message);
    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &user_end);
    try bridge.handleMessageStart(&runner, assistant_message);
    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &assistant_end);

    const expected = [_]MessageOrderObservation{
        .{ .phase = .extension, .event = .message_start, .role = .user },
        .{ .phase = .public, .event = .message_start, .role = .user },
        .{ .phase = .extension, .event = .message_end, .role = .user },
        .{ .phase = .public, .event = .message_end, .role = .user },
        .{ .phase = .extension, .event = .message_start, .role = .assistant },
        .{ .phase = .public, .event = .message_start, .role = .assistant },
        .{ .phase = .extension, .event = .message_end, .role = .assistant },
        .{ .phase = .public, .event = .message_end, .role = .assistant },
    };
    try std.testing.expectEqualSlices(MessageOrderObservation, &expected, order.items);
}

test "AgentSession bridge emits lifecycle events extension-first and advances turn index" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var order: std.ArrayList(LifecycleObservation) = .empty;
    defer order.deinit(allocator);
    var state = LifecycleOrderState{ .allocator = allocator, .order = &order };
    const handlers = [_]extensions.ExtensionHandler{
        .{
            .ptr = &state,
            .event_name = .agent_start,
            .handler_fn = LifecycleOrderState.extensionHandler,
        },
        .{
            .ptr = &state,
            .event_name = .turn_start,
            .handler_fn = LifecycleOrderState.extensionHandler,
        },
        .{
            .ptr = &state,
            .event_name = .turn_end,
            .handler_fn = LifecycleOrderState.extensionHandler,
        },
        .{
            .ptr = &state,
            .event_name = .agent_end,
            .handler_fn = LifecycleOrderState.extensionHandler,
        },
    };
    const extension_list = [_]extensions.Extension{
        testExtension("/tmp/lifecycle-order.zig", &handlers),
    };
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &extension_list,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    try bridge.subscribe(.{ .ptr = &state, .call_fn = LifecycleOrderState.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "done" } }};
    const assistant_message = messages.CodingAgentMessage{ .assistant = .{
        .content = &assistant_content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
        .usage = .{},
        .timestamp_ms = 2,
    } };
    var tool_results: [0]ai.ToolResultMessage = .{};
    var agent_messages = [_]messages.CodingAgentMessage{assistant_message};

    try bridge.handleAgentStart(&runner);
    try bridge.handleTurnStart(&runner, 123);
    try bridge.handleTurnEnd(&runner, assistant_message, tool_results[0..]);
    try bridge.handleAgentEnd(&runner, agent_messages[0..], true);

    const expected = [_]LifecycleObservation{
        .{ .phase = .extension, .event = .agent_start },
        .{ .phase = .public, .event = .agent_start },
        .{ .phase = .extension, .event = .turn_start, .turn_index = 0 },
        .{ .phase = .public, .event = .turn_start, .turn_index = 0 },
        .{ .phase = .extension, .event = .turn_end, .turn_index = 0 },
        .{ .phase = .public, .event = .turn_end, .turn_index = 0 },
        .{ .phase = .extension, .event = .agent_end },
        .{ .phase = .public, .event = .agent_end, .will_retry = true },
    };
    try std.testing.expectEqualSlices(LifecycleObservation, &expected, order.items);
    try std.testing.expectEqual(@as(usize, 1), bridge.turn_index);
}

const MessageEndReplacementState = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn handler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = ctx;
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        if (event_value.message_end.message != .assistant) return null;
        state.calls += 1;
        return try std.json.parseFromSliceLeaky(
            std.json.Value,
            state.allocator,
            \\{
            \\  "message": {
            \\    "role": "assistant",
            \\    "content": [{ "type": "text", "text": "patched" }],
            \\    "api": "openai-responses",
            \\    "provider": "openai",
            \\    "model": "gpt-test",
            \\    "usage": {
            \\      "input": 1,
            \\      "output": 1,
            \\      "cacheRead": 0,
            \\      "cacheWrite": 0,
            \\      "totalTokens": 2,
            \\      "cost": {
            \\        "input": 0,
            \\        "output": 0,
            \\        "cacheRead": 0,
            \\        "cacheWrite": 0,
            \\        "total": 0.123
            \\      }
            \\    },
            \\    "stopReason": "stop",
            \\    "timestamp": 42
            \\  }
            \\}
        ,
            .{},
        );
    }
};

const MessageEndObserver = struct {
    assistant_cost_total: ?f64 = null,

    fn onMessageEnd(ptr: ?*anyopaque, message: messages.CodingAgentMessage) void {
        const observer: *@This() = @ptrCast(@alignCast(ptr.?));
        if (message == .assistant) observer.assistant_cost_total = message.assistant.usage.cost.total;
    }
};

const ObservationPhase = enum {
    extension,
    public,
};

const ObservedMessageEvent = enum {
    message_start,
    message_end,
};

const ObservedRole = enum {
    user,
    assistant,
    tool_result,
    bash_execution,
    custom,
    branch_summary,
    compaction_summary,
};

const MessageOrderObservation = struct {
    phase: ObservationPhase,
    event: ObservedMessageEvent,
    role: ObservedRole,
};

const MessageOrderState = struct {
    allocator: std.mem.Allocator,
    order: *std.ArrayList(MessageOrderObservation),

    fn extensionHandler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = ctx;
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event_value) {
            .message_start => |event| try state.append(.extension, .message_start, event.message),
            .message_end => |event| try state.append(.extension, .message_end, event.message),
            else => {},
        }
        return null;
    }

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .message_start => |payload| state.append(.public, .message_start, payload.message) catch @panic("out of memory"),
            .message_end => |payload| state.append(.public, .message_end, payload.message) catch @panic("out of memory"),
            else => {},
        }
    }

    fn append(
        self: *@This(),
        phase: ObservationPhase,
        event: ObservedMessageEvent,
        message: messages.CodingAgentMessage,
    ) !void {
        try self.order.append(self.allocator, .{
            .phase = phase,
            .event = event,
            .role = observedRole(message),
        });
    }
};

fn observedRole(message: messages.CodingAgentMessage) ObservedRole {
    return switch (message) {
        .user => .user,
        .assistant => .assistant,
        .tool_result => .tool_result,
        .bash_execution => .bash_execution,
        .custom => .custom,
        .branch_summary => .branch_summary,
        .compaction_summary => .compaction_summary,
    };
}

const ObservedLifecycleEvent = enum {
    agent_start,
    agent_end,
    turn_start,
    turn_end,
};

const LifecycleObservation = struct {
    phase: ObservationPhase,
    event: ObservedLifecycleEvent,
    turn_index: ?usize = null,
    will_retry: ?bool = null,
};

const LifecycleOrderState = struct {
    allocator: std.mem.Allocator,
    order: *std.ArrayList(LifecycleObservation),

    fn extensionHandler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = ctx;
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event_value) {
            .agent_start => try state.append(.extension, .agent_start, null, null),
            .agent_end => try state.append(.extension, .agent_end, null, null),
            .turn_start => |event| try state.append(.extension, .turn_start, event.turn_index, null),
            .turn_end => |event| try state.append(.extension, .turn_end, event.turn_index, null),
            else => {},
        }
        return null;
    }

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .agent_start => state.append(.public, .agent_start, null, null) catch @panic("out of memory"),
            .agent_end => |payload| state.append(.public, .agent_end, null, payload.will_retry) catch @panic("out of memory"),
            .turn_start => |payload| state.append(.public, .turn_start, payload.turn_index, null) catch @panic("out of memory"),
            .turn_end => |payload| state.append(.public, .turn_end, payload.turn_index, null) catch @panic("out of memory"),
            else => {},
        }
    }

    fn append(
        self: *@This(),
        phase: ObservationPhase,
        event: ObservedLifecycleEvent,
        turn_index: ?usize,
        will_retry: ?bool,
    ) !void {
        try self.order.append(self.allocator, .{
            .phase = phase,
            .event = event,
            .turn_index = turn_index,
            .will_retry = will_retry,
        });
    }
};

const TestHarness = struct {
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    oauth_registry: *ai.oauth.Registry,
    resolver: *config_value.Resolver,
    storage: *auth_storage.AuthStorage,
    registry: *model_registry.ModelRegistry,
    sessions: *session_manager.SessionManager,
    runtime: *extensions.loader.ExtensionRuntimeController,

    fn init(allocator: std.mem.Allocator) !TestHarness {
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

        const runtime = try allocator.create(extensions.loader.ExtensionRuntimeController);
        errdefer allocator.destroy(runtime);
        runtime.* = extensions.createExtensionRuntime(allocator);
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

    fn deinit(self: *TestHarness) void {
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

fn testExtension(path: []const u8, handlers: []const extensions.ExtensionHandler) extensions.Extension {
    return .{
        .path = path,
        .resolved_path = path,
        .source_info = source_info.createSyntheticSourceInfo(path, .{ .source = "test" }),
        .handlers = handlers,
    };
}

fn expectEntryType(entry: session_manager.FileEntry, expected: []const u8) !void {
    const actual = entry.entry_type orelse return error.MissingEntryType;
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectPersistedAssistantTextAndCost(
    allocator: std.mem.Allocator,
    entry: session_manager.FileEntry,
    expected_text: []const u8,
    expected_cost_total: f64,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const message_value = parsed.value.object.get("message") orelse return error.MissingMessage;
    try std.testing.expect(message_value == .object);

    const role_value = message_value.object.get("role") orelse return error.MissingRole;
    try std.testing.expect(role_value == .string);
    try std.testing.expectEqualStrings("assistant", role_value.string);

    const content_value = message_value.object.get("content") orelse return error.MissingContent;
    try std.testing.expect(content_value == .array);
    try std.testing.expect(content_value.array.items.len > 0);
    const first_content = content_value.array.items[0];
    try std.testing.expect(first_content == .object);
    const text_value = first_content.object.get("text") orelse return error.MissingText;
    try std.testing.expect(text_value == .string);
    try std.testing.expectEqualStrings(expected_text, text_value.string);

    const usage_value = message_value.object.get("usage") orelse return error.MissingUsage;
    try std.testing.expect(usage_value == .object);
    const cost_value = usage_value.object.get("cost") orelse return error.MissingCost;
    try std.testing.expect(cost_value == .object);
    const total_value = cost_value.object.get("total") orelse return error.MissingCostTotal;
    const total = switch (total_value) {
        .float => |value| value,
        .integer => |value| @as(f64, @floatFromInt(value)),
        else => return error.InvalidCostTotal,
    };
    try std.testing.expectApproxEqAbs(expected_cost_total, total, 0.000001);
}
