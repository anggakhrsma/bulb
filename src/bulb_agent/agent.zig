const std = @import("std");
const ai = @import("bulb_ai");

const agent_loop = @import("agent_loop.zig");
const agent_messages = @import("messages.zig");
const harness = @import("harness.zig");
const types = @import("types.zig");

pub const AgentMessage = types.AgentMessage;
pub const AgentLoopTool = agent_loop.AgentLoopTool;
pub const AgentEvent = agent_loop.AgentEvent;
pub const QueueMode = harness.QueueMode;
pub const ToolExecutionMode = agent_loop.ToolExecutionMode;

const empty_model_input = [_][]const u8{};

pub const default_model: ai.Model = .{
    .id = "unknown",
    .name = "unknown",
    .api = "unknown",
    .provider = "unknown",
    .base_url = "",
    .reasoning = false,
    .input = &empty_model_input,
    .cost = .{},
    .context_window = 0,
    .max_tokens = 0,
};

pub const AgentError = error{
    AlreadyProcessing,
    CannotContinueNoMessages,
    CannotContinueFromAssistant,
};

pub const AgentInitialState = struct {
    system_prompt: []const u8 = "",
    model: ai.Model = default_model,
    thinking_level: ai.ThinkingLevel = .off,
    tools: []const AgentLoopTool = &.{},
    messages: []const AgentMessage = &.{},
};

pub const AgentOptions = struct {
    initial_state: AgentInitialState = .{},
    stream: ?agent_loop.StreamHandler = null,
    stream_options: ai.StreamOptions = .{},
    api_key: ?[]const u8 = null,
    convert_to_llm: agent_loop.ConvertToLlmHandler = .{},
    transform_context: ?agent_loop.TransformContextHandler = null,
    get_api_key: ?agent_loop.GetApiKeyHandler = null,
    before_tool_call: ?agent_loop.BeforeToolCallHandler = null,
    after_tool_call: ?agent_loop.AfterToolCallHandler = null,
    should_stop_after_turn: ?agent_loop.ShouldStopAfterTurnHandler = null,
    prepare_next_turn: ?agent_loop.PrepareNextTurnHandler = null,
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    session_id: ?[]const u8 = null,
    tool_execution: ToolExecutionMode = .parallel,
};

pub const AgentListener = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, AgentEvent, *ai.AbortSignal) anyerror!void = noopAgentListener,

    pub fn call(self: AgentListener, event: AgentEvent, signal: *ai.AbortSignal) !void {
        try self.call_fn(self.ptr, event, signal);
    }
};

const AgentListenerRegistration = struct {
    id: usize,
    listener: AgentListener,
    active: bool = true,
};

const RunPromptOptions = struct {
    skip_initial_steering_poll: bool = false,
};

const QueueDrainContext = struct {
    agent: *Agent,
    skip_initial_steering_poll: bool = false,
};

pub const AgentState = struct {
    allocator: std.mem.Allocator,
    system_prompt: []u8,
    model: ai.Model,
    thinking_level: ai.ThinkingLevel,
    tools: []AgentLoopTool,
    messages: []AgentMessage,
    is_streaming: bool = false,
    streaming_message: ?AgentMessage = null,
    pending_tool_calls: std.StringHashMap(void),
    error_message: ?[]u8 = null,

    pub fn initAlloc(allocator: std.mem.Allocator, initial: AgentInitialState) !AgentState {
        var state: AgentState = .{
            .allocator = allocator,
            .system_prompt = try allocator.dupe(u8, initial.system_prompt),
            .model = initial.model,
            .thinking_level = initial.thinking_level,
            .tools = &.{},
            .messages = &.{},
            .pending_tool_calls = .init(allocator),
        };
        errdefer state.deinit();

        state.tools = try cloneToolSliceAlloc(allocator, initial.tools);
        state.messages = try cloneAgentMessageSliceAlloc(allocator, initial.messages);
        return state;
    }

    pub fn deinit(self: *AgentState) void {
        self.allocator.free(self.system_prompt);
        deinitToolSlice(self.allocator, self.tools);
        deinitAgentMessageSlice(self.allocator, self.messages);
        self.clearStreamingMessage();
        self.clearPendingToolCalls();
        self.pending_tool_calls.deinit();
        if (self.error_message) |message| self.allocator.free(message);
        self.* = undefined;
    }

    pub fn setSystemPrompt(self: *AgentState, system_prompt: []const u8) !void {
        const owned = try self.allocator.dupe(u8, system_prompt);
        self.allocator.free(self.system_prompt);
        self.system_prompt = owned;
    }

    pub fn setModel(self: *AgentState, model: ai.Model) void {
        self.model = model;
    }

    pub fn setThinkingLevel(self: *AgentState, thinking_level: ai.ThinkingLevel) void {
        self.thinking_level = thinking_level;
    }

    pub fn setToolsAlloc(self: *AgentState, tools: []const AgentLoopTool) !void {
        const owned = try cloneToolSliceAlloc(self.allocator, tools);
        deinitToolSlice(self.allocator, self.tools);
        self.tools = owned;
    }

    pub fn setMessagesAlloc(self: *AgentState, messages: []const AgentMessage) !void {
        const owned = try cloneAgentMessageSliceAlloc(self.allocator, messages);
        deinitAgentMessageSlice(self.allocator, self.messages);
        self.messages = owned;
    }

    pub fn appendMessage(self: *AgentState, message: AgentMessage) !void {
        var cloned = try cloneAgentMessageAlloc(self.allocator, message);
        errdefer deinitAgentMessage(self.allocator, &cloned);
        try appendOwnedMessage(self.allocator, &self.messages, cloned);
    }

    pub fn setStreamingMessage(self: *AgentState, message: AgentMessage) !void {
        const cloned = try cloneAgentMessageAlloc(self.allocator, message);
        self.clearStreamingMessage();
        self.streaming_message = cloned;
    }

    pub fn clearStreamingMessage(self: *AgentState) void {
        if (self.streaming_message) |*message| deinitAgentMessage(self.allocator, message);
        self.streaming_message = null;
    }

    pub fn addPendingToolCall(self: *AgentState, tool_call_id: []const u8) !void {
        if (self.pending_tool_calls.contains(tool_call_id)) return;
        try self.pending_tool_calls.put(try self.allocator.dupe(u8, tool_call_id), {});
    }

    pub fn removePendingToolCall(self: *AgentState, tool_call_id: []const u8) void {
        if (self.pending_tool_calls.fetchRemove(tool_call_id)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    pub fn clearPendingToolCalls(self: *AgentState) void {
        var keys = self.pending_tool_calls.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.pending_tool_calls.clearRetainingCapacity();
    }

    pub fn setErrorMessage(self: *AgentState, message: ?[]const u8) !void {
        if (self.error_message) |current| self.allocator.free(current);
        self.error_message = if (message) |value| try self.allocator.dupe(u8, value) else null;
    }

    pub fn resetRuntime(self: *AgentState) void {
        self.is_streaming = false;
        self.clearStreamingMessage();
        self.clearPendingToolCalls();
        if (self.error_message) |message| self.allocator.free(message);
        self.error_message = null;
    }

    pub fn resetTranscriptAndRuntime(self: *AgentState) void {
        deinitAgentMessageSlice(self.allocator, self.messages);
        self.messages = &.{};
        self.resetRuntime();
    }
};

pub const PendingMessageQueue = struct {
    allocator: std.mem.Allocator,
    messages: []AgentMessage = &.{},
    mode: QueueMode,

    pub fn init(allocator: std.mem.Allocator, mode: QueueMode) PendingMessageQueue {
        return .{
            .allocator = allocator,
            .mode = mode,
        };
    }

    pub fn deinit(self: *PendingMessageQueue) void {
        self.clear();
        self.* = undefined;
    }

    pub fn enqueue(self: *PendingMessageQueue, message: AgentMessage) !void {
        var cloned = try cloneAgentMessageAlloc(self.allocator, message);
        errdefer deinitAgentMessage(self.allocator, &cloned);
        try appendOwnedMessage(self.allocator, &self.messages, cloned);
    }

    pub fn hasItems(self: *const PendingMessageQueue) bool {
        return self.messages.len > 0;
    }

    pub fn drainAlloc(self: *PendingMessageQueue, allocator: std.mem.Allocator) ![]AgentMessage {
        if (self.messages.len == 0) return &.{};

        if (self.mode == .all) {
            const drained = try cloneAgentMessageSliceAlloc(allocator, self.messages);
            self.clear();
            return drained;
        }

        const drained = try allocator.alloc(AgentMessage, 1);
        errdefer allocator.free(drained);
        drained[0] = try cloneAgentMessageAlloc(allocator, self.messages[0]);

        var removed = self.messages[0];
        deinitAgentMessage(self.allocator, &removed);
        if (self.messages.len == 1) {
            self.allocator.free(self.messages);
            self.messages = &.{};
        } else {
            std.mem.copyForwards(AgentMessage, self.messages[0 .. self.messages.len - 1], self.messages[1..]);
            self.messages = try self.allocator.realloc(self.messages, self.messages.len - 1);
        }
        return drained;
    }

    pub fn clear(self: *PendingMessageQueue) void {
        deinitAgentMessageSlice(self.allocator, self.messages);
        self.messages = &.{};
    }
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    state: AgentState,
    steering_queue: PendingMessageQueue,
    follow_up_queue: PendingMessageQueue,
    listeners: []AgentListenerRegistration = &.{},
    next_listener_id: usize = 1,
    stream: ?agent_loop.StreamHandler = null,
    stream_options: ai.StreamOptions = .{},
    api_key: ?[]u8 = null,
    convert_to_llm: agent_loop.ConvertToLlmHandler = .{},
    transform_context: ?agent_loop.TransformContextHandler = null,
    get_api_key: ?agent_loop.GetApiKeyHandler = null,
    before_tool_call: ?agent_loop.BeforeToolCallHandler = null,
    after_tool_call: ?agent_loop.AfterToolCallHandler = null,
    should_stop_after_turn: ?agent_loop.ShouldStopAfterTurnHandler = null,
    prepare_next_turn: ?agent_loop.PrepareNextTurnHandler = null,
    session_id: ?[]u8 = null,
    tool_execution: ToolExecutionMode = .parallel,
    active: bool = false,
    abort_signal: ai.AbortSignal = .{},

    pub fn initAlloc(allocator: std.mem.Allocator, options: AgentOptions) !Agent {
        var result: Agent = .{
            .allocator = allocator,
            .state = try AgentState.initAlloc(allocator, options.initial_state),
            .steering_queue = PendingMessageQueue.init(allocator, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(allocator, options.follow_up_mode),
            .stream = options.stream,
            .stream_options = options.stream_options,
            .api_key = if (options.api_key) |value| try allocator.dupe(u8, value) else null,
            .convert_to_llm = options.convert_to_llm,
            .transform_context = options.transform_context,
            .get_api_key = options.get_api_key,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .should_stop_after_turn = options.should_stop_after_turn,
            .prepare_next_turn = options.prepare_next_turn,
            .session_id = if (options.session_id) |value| try allocator.dupe(u8, value) else null,
            .tool_execution = options.tool_execution,
        };
        errdefer result.deinit();
        return result;
    }

    pub fn deinit(self: *Agent) void {
        self.state.deinit();
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        self.allocator.free(self.listeners);
        if (self.api_key) |value| self.allocator.free(value);
        if (self.session_id) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn setSessionId(self: *Agent, session_id: ?[]const u8) !void {
        if (self.session_id) |value| self.allocator.free(value);
        self.session_id = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
    }

    pub fn setApiKey(self: *Agent, api_key: ?[]const u8) !void {
        if (self.api_key) |value| self.allocator.free(value);
        self.api_key = if (api_key) |value| try self.allocator.dupe(u8, value) else null;
    }

    pub fn subscribe(self: *Agent, listener: AgentListener) !usize {
        const id = self.next_listener_id;
        self.next_listener_id += 1;
        const next = try self.allocator.realloc(self.listeners, self.listeners.len + 1);
        self.listeners = next;
        self.listeners[self.listeners.len - 1] = .{
            .id = id,
            .listener = listener,
        };
        return id;
    }

    pub fn unsubscribe(self: *Agent, id: usize) void {
        for (self.listeners) |*registration| {
            if (registration.id == id) {
                registration.active = false;
                return;
            }
        }
    }

    pub fn steeringMode(self: *const Agent) QueueMode {
        return self.steering_queue.mode;
    }

    pub fn setSteeringMode(self: *Agent, mode: QueueMode) void {
        self.steering_queue.mode = mode;
    }

    pub fn followUpMode(self: *const Agent) QueueMode {
        return self.follow_up_queue.mode;
    }

    pub fn setFollowUpMode(self: *Agent, mode: QueueMode) void {
        self.follow_up_queue.mode = mode;
    }

    pub fn steer(self: *Agent, message: AgentMessage) !void {
        try self.steering_queue.enqueue(message);
    }

    pub fn followUp(self: *Agent, message: AgentMessage) !void {
        try self.follow_up_queue.enqueue(message);
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        self.steering_queue.clear();
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        self.follow_up_queue.clear();
    }

    pub fn clearAllQueues(self: *Agent) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn hasQueuedMessages(self: *const Agent) bool {
        return self.steering_queue.hasItems() or self.follow_up_queue.hasItems();
    }

    pub fn signal(self: *Agent) ?*ai.AbortSignal {
        return if (self.active) &self.abort_signal else null;
    }

    pub fn waitForIdle(self: *const Agent) bool {
        return !self.active;
    }

    pub fn abort(self: *Agent) void {
        if (self.active) self.abort_signal.abort();
    }

    pub fn beginRun(self: *Agent) AgentError!*ai.AbortSignal {
        if (self.active) return error.AlreadyProcessing;
        self.active = true;
        self.abort_signal = .{};
        self.state.is_streaming = true;
        self.state.clearStreamingMessage();
        self.state.setErrorMessage(null) catch {};
        return &self.abort_signal;
    }

    pub fn finishRun(self: *Agent) void {
        self.active = false;
        self.state.is_streaming = false;
        self.state.clearStreamingMessage();
        self.state.clearPendingToolCalls();
    }

    pub fn reset(self: *Agent) void {
        self.state.resetTranscriptAndRuntime();
        self.clearAllQueues();
        self.active = false;
        self.abort_signal = .{};
    }

    pub fn promptTextAlloc(
        self: *Agent,
        text: []const u8,
        images: []const ai.ImageContent,
    ) !void {
        const messages = try self.normalizePromptTextAlloc(self.allocator, text, images, ai.diagnostics.currentTimestampMs());
        defer deinitOwnedMessages(self.allocator, messages);
        try self.promptMessagesAlloc(messages);
    }

    pub fn promptMessageAlloc(self: *Agent, message: AgentMessage) !void {
        const messages = [_]AgentMessage{message};
        try self.promptMessagesAlloc(&messages);
    }

    pub fn promptMessagesAlloc(self: *Agent, messages: []const AgentMessage) !void {
        if (self.active) return error.AlreadyProcessing;
        try self.runPromptMessagesAlloc(messages, .{});
    }

    pub fn continueRunAlloc(self: *Agent) !void {
        if (self.active) return error.AlreadyProcessing;
        if (self.state.messages.len == 0) return error.CannotContinueNoMessages;

        const last_message = self.state.messages[self.state.messages.len - 1];
        if (last_message == .assistant) {
            const queued_steering = try self.steering_queue.drainAlloc(self.allocator);
            defer deinitOwnedMessages(self.allocator, queued_steering);
            if (queued_steering.len > 0) {
                try self.runPromptMessagesAlloc(queued_steering, .{ .skip_initial_steering_poll = true });
                return;
            }

            const queued_follow_ups = try self.follow_up_queue.drainAlloc(self.allocator);
            defer deinitOwnedMessages(self.allocator, queued_follow_ups);
            if (queued_follow_ups.len > 0) {
                try self.runPromptMessagesAlloc(queued_follow_ups, .{});
                return;
            }

            return error.CannotContinueFromAssistant;
        }

        try self.runContinuationAlloc();
    }

    pub fn normalizePromptTextAlloc(
        self: *Agent,
        allocator: std.mem.Allocator,
        text: []const u8,
        images: []const ai.ImageContent,
        timestamp_ms: i64,
    ) ![]AgentMessage {
        _ = self;
        const content = try allocator.alloc(ai.UserContent, 1 + images.len);
        errdefer allocator.free(content);

        content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
        errdefer deinitUserContent(allocator, content[0]);

        for (images, 0..) |image, index| {
            content[index + 1] = .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } };
        }

        const messages = try allocator.alloc(AgentMessage, 1);
        messages[0] = .{ .user = .{
            .content = content,
            .timestamp_ms = timestamp_ms,
        } };
        return messages;
    }

    pub fn processEvent(self: *Agent, event: AgentEvent) !void {
        switch (event) {
            .message_start => |payload| try self.state.setStreamingMessage(payload.message),
            .message_update => |payload| try self.state.setStreamingMessage(payload.message),
            .message_end => |payload| {
                self.state.clearStreamingMessage();
                try self.state.appendMessage(payload.message);
            },
            .tool_execution_start => |payload| try self.state.addPendingToolCall(payload.tool_call_id),
            .tool_execution_end => |payload| self.state.removePendingToolCall(payload.tool_call_id),
            .turn_end => |payload| {
                if (payload.message == .assistant) {
                    try self.state.setErrorMessage(payload.message.assistant.error_message);
                }
            },
            .agent_end => self.state.clearStreamingMessage(),
            else => {},
        }
    }

    fn runPromptMessagesAlloc(
        self: *Agent,
        messages: []const AgentMessage,
        options: RunPromptOptions,
    ) !void {
        const signal_ref = try self.beginRun();
        defer self.finishRun();

        var queue_context: QueueDrainContext = .{
            .agent = self,
            .skip_initial_steering_poll = options.skip_initial_steering_poll,
        };
        const config = self.createLoopConfig(&queue_context);
        var result = agent_loop.runAgentLoopAlloc(
            self.allocator,
            messages,
            self.createContextSnapshot(),
            config,
            signal_ref,
        ) catch |err| {
            try self.handleRunFailure(err, signal_ref.isAborted(), messages);
            return;
        };
        defer result.deinit();
        try self.processEvents(result.events);
    }

    fn runContinuationAlloc(self: *Agent) !void {
        const signal_ref = try self.beginRun();
        defer self.finishRun();

        var queue_context: QueueDrainContext = .{ .agent = self };
        const config = self.createLoopConfig(&queue_context);
        var result = agent_loop.runAgentLoopContinueAlloc(
            self.allocator,
            self.createContextSnapshot(),
            config,
            signal_ref,
        ) catch |err| {
            try self.handleRunFailure(err, signal_ref.isAborted(), &.{});
            return;
        };
        defer result.deinit();
        try self.processEvents(result.events);
    }

    fn createContextSnapshot(self: *Agent) agent_loop.AgentContext {
        return .{
            .system_prompt = self.state.system_prompt,
            .messages = self.state.messages,
            .tools = self.state.tools,
        };
    }

    fn createLoopConfig(self: *Agent, queue_context: *QueueDrainContext) agent_loop.AgentLoopConfig {
        var stream_options = self.stream_options;
        stream_options.session_id = self.session_id;
        return .{
            .model = self.state.model,
            .thinking_level = self.state.thinking_level,
            .api_key = self.api_key,
            .stream_options = stream_options,
            .stream = self.stream,
            .convert_to_llm = self.convert_to_llm,
            .transform_context = self.transform_context,
            .get_api_key = self.get_api_key,
            .get_steering_messages = .{
                .ptr = queue_context,
                .call_fn = drainSteeringMessages,
            },
            .get_follow_up_messages = .{
                .ptr = queue_context,
                .call_fn = drainFollowUpMessages,
            },
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .should_stop_after_turn = self.should_stop_after_turn,
            .prepare_next_turn = self.prepare_next_turn,
            .tool_execution = self.tool_execution,
        };
    }

    fn processEvents(self: *Agent, events: []const AgentEvent) !void {
        for (events) |event| try self.processEventAndNotify(event);
    }

    fn processEventAndNotify(self: *Agent, event: AgentEvent) !void {
        try self.processEvent(event);
        const signal_ref = self.signal() orelse return error.AgentListenerOutsideActiveRun;
        for (self.listeners) |registration| {
            if (!registration.active) continue;
            try registration.listener.call(event, signal_ref);
        }
    }

    fn handleRunFailure(
        self: *Agent,
        err: anyerror,
        aborted: bool,
        initial_messages: []const AgentMessage,
    ) !void {
        try self.processEventAndNotify(.{ .agent_start = {} });
        try self.processEventAndNotify(.{ .turn_start = {} });
        for (initial_messages) |message| {
            try self.processEventAndNotify(.{ .message_start = .{ .message = message } });
            try self.processEventAndNotify(.{ .message_end = .{ .message = message } });
        }

        var failure = try self.failureMessageAlloc(err, aborted);
        defer deinitAgentMessage(self.allocator, &failure);
        try self.processEventAndNotify(.{ .message_start = .{ .message = failure } });
        try self.processEventAndNotify(.{ .message_end = .{ .message = failure } });
        try self.processEventAndNotify(.{ .turn_end = .{
            .message = failure,
            .tool_results = &.{},
        } });
        try self.processEventAndNotify(.{ .agent_end = .{ .messages = &.{failure} } });
    }

    fn failureMessageAlloc(self: *Agent, err: anyerror, aborted: bool) !AgentMessage {
        const content = try self.allocator.alloc(ai.AssistantContent, 1);
        errdefer self.allocator.free(content);
        content[0] = .{ .text = .{ .text = try self.allocator.dupe(u8, "") } };
        errdefer deinitAssistantContentSlice(self.allocator, content);

        return .{ .assistant = .{
            .content = content,
            .api = try self.allocator.dupe(u8, self.state.model.api),
            .provider = try self.allocator.dupe(u8, self.state.model.provider),
            .model = try self.allocator.dupe(u8, self.state.model.id),
            .stop_reason = if (aborted) .aborted else .@"error",
            .error_message = try self.allocator.dupe(u8, @errorName(err)),
            .timestamp_ms = ai.diagnostics.currentTimestampMs(),
        } };
    }
};

fn noopAgentListener(_: ?*anyopaque, _: AgentEvent, _: *ai.AbortSignal) !void {}

fn drainSteeringMessages(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]const AgentMessage {
    const context: *QueueDrainContext = @ptrCast(@alignCast(ptr.?));
    if (context.skip_initial_steering_poll) {
        context.skip_initial_steering_poll = false;
        return &.{};
    }
    return try context.agent.steering_queue.drainAlloc(allocator);
}

fn drainFollowUpMessages(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]const AgentMessage {
    const context: *QueueDrainContext = @ptrCast(@alignCast(ptr.?));
    return try context.agent.follow_up_queue.drainAlloc(allocator);
}

fn appendOwnedMessage(
    allocator: std.mem.Allocator,
    target: *[]AgentMessage,
    message: AgentMessage,
) !void {
    const old = target.*;
    const next = try allocator.alloc(AgentMessage, old.len + 1);
    if (old.len > 0) @memcpy(next[0..old.len], old);
    next[old.len] = message;
    allocator.free(old);
    target.* = next;
}

fn cloneToolSliceAlloc(allocator: std.mem.Allocator, source: []const AgentLoopTool) ![]AgentLoopTool {
    const output = try allocator.alloc(AgentLoopTool, source.len);
    errdefer allocator.free(output);
    for (source, 0..) |tool, index| {
        output[index] = try cloneToolAlloc(allocator, tool);
    }
    return output;
}

fn cloneToolAlloc(allocator: std.mem.Allocator, tool: AgentLoopTool) !AgentLoopTool {
    return .{
        .name = try allocator.dupe(u8, tool.name),
        .label = try allocator.dupe(u8, tool.label),
        .description = try allocator.dupe(u8, tool.description),
        .parameters_json = try allocator.dupe(u8, tool.parameters_json),
        .execution_mode = tool.execution_mode,
        .prepare_arguments = tool.prepare_arguments,
        .execute = tool.execute,
    };
}

fn deinitToolSlice(allocator: std.mem.Allocator, tools: []AgentLoopTool) void {
    for (tools) |*tool| deinitTool(allocator, tool);
    allocator.free(tools);
}

fn deinitTool(allocator: std.mem.Allocator, tool: *AgentLoopTool) void {
    allocator.free(@constCast(tool.name));
    allocator.free(@constCast(tool.label));
    allocator.free(@constCast(tool.description));
    allocator.free(@constCast(tool.parameters_json));
    tool.* = undefined;
}

fn cloneAgentMessageSliceAlloc(allocator: std.mem.Allocator, source: []const AgentMessage) ![]AgentMessage {
    const output = try allocator.alloc(AgentMessage, source.len);
    errdefer allocator.free(output);
    for (source, 0..) |message, index| output[index] = try cloneAgentMessageAlloc(allocator, message);
    return output;
}

fn cloneAgentMessageAlloc(allocator: std.mem.Allocator, message: AgentMessage) !AgentMessage {
    return switch (message) {
        .user => |user| .{ .user = try cloneUserMessageAlloc(allocator, user) },
        .assistant => |assistant| .{ .assistant = try cloneAssistantMessageAlloc(allocator, assistant) },
        .tool_result => |tool_result| .{ .tool_result = try cloneToolResultMessageAlloc(allocator, tool_result) },
        .bash_execution => |bash| .{ .bash_execution = .{
            .command = try allocator.dupe(u8, bash.command),
            .output = try allocator.dupe(u8, bash.output),
            .exit_code = bash.exit_code,
            .cancelled = bash.cancelled,
            .truncated = bash.truncated,
            .full_output_path = if (bash.full_output_path) |path| try allocator.dupe(u8, path) else null,
            .timestamp_ms = bash.timestamp_ms,
            .exclude_from_context = bash.exclude_from_context,
        } },
        .custom => |custom| .{ .custom = .{
            .custom_type = try allocator.dupe(u8, custom.custom_type),
            .content = switch (custom.content) {
                .text => |text| .{ .text = try allocator.dupe(u8, text) },
                .parts => |parts| .{ .parts = try cloneUserContentSliceAlloc(allocator, parts) },
            },
            .display = custom.display,
            .details_json = if (custom.details_json) |details| try allocator.dupe(u8, details) else null,
            .timestamp_ms = custom.timestamp_ms,
        } },
        .branch_summary => |summary| .{ .branch_summary = .{
            .summary = try allocator.dupe(u8, summary.summary),
            .from_id = try allocator.dupe(u8, summary.from_id),
            .timestamp_ms = summary.timestamp_ms,
        } },
        .compaction_summary => |summary| .{ .compaction_summary = .{
            .summary = try allocator.dupe(u8, summary.summary),
            .tokens_before = summary.tokens_before,
            .timestamp_ms = summary.timestamp_ms,
        } },
    };
}

fn cloneUserMessageAlloc(allocator: std.mem.Allocator, source: ai.UserMessage) !ai.UserMessage {
    return .{
        .content = try cloneUserContentSliceAlloc(allocator, source.content),
        .timestamp_ms = source.timestamp_ms,
    };
}

fn cloneAssistantMessageAlloc(allocator: std.mem.Allocator, source: ai.AssistantMessage) !ai.AssistantMessage {
    return .{
        .content = try cloneAssistantContentSliceAlloc(allocator, source.content),
        .api = try allocator.dupe(u8, source.api),
        .provider = try allocator.dupe(u8, source.provider),
        .model = try allocator.dupe(u8, source.model),
        .response_model = if (source.response_model) |value| try allocator.dupe(u8, value) else null,
        .usage = source.usage,
        .stop_reason = source.stop_reason,
        .error_message = if (source.error_message) |value| try allocator.dupe(u8, value) else null,
        .response_id = if (source.response_id) |value| try allocator.dupe(u8, value) else null,
        .diagnostics = try cloneDiagnosticsAlloc(allocator, source.diagnostics),
        .timestamp_ms = source.timestamp_ms,
    };
}

fn cloneToolResultMessageAlloc(allocator: std.mem.Allocator, source: ai.ToolResultMessage) !ai.ToolResultMessage {
    return .{
        .tool_call_id = try allocator.dupe(u8, source.tool_call_id),
        .tool_name = try allocator.dupe(u8, source.tool_name),
        .content = try cloneUserContentSliceAlloc(allocator, source.content),
        .is_error = source.is_error,
        .timestamp_ms = source.timestamp_ms,
    };
}

fn cloneUserContentSliceAlloc(allocator: std.mem.Allocator, source: []const ai.UserContent) ![]ai.UserContent {
    const output = try allocator.alloc(ai.UserContent, source.len);
    errdefer allocator.free(output);
    for (source, 0..) |content, index| output[index] = try cloneUserContentAlloc(allocator, content);
    return output;
}

fn cloneUserContentAlloc(allocator: std.mem.Allocator, content: ai.UserContent) !ai.UserContent {
    return switch (content) {
        .text => |text| .{ .text = try cloneTextContentAlloc(allocator, text) },
        .image => |image| .{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
    };
}

fn cloneAssistantContentSliceAlloc(
    allocator: std.mem.Allocator,
    source: []const ai.AssistantContent,
) ![]ai.AssistantContent {
    const output = try allocator.alloc(ai.AssistantContent, source.len);
    errdefer allocator.free(output);
    for (source, 0..) |content, index| {
        output[index] = switch (content) {
            .text => |text| .{ .text = try cloneTextContentAlloc(allocator, text) },
            .thinking => |thinking| .{ .thinking = .{
                .thinking = try allocator.dupe(u8, thinking.thinking),
                .thinking_signature = if (thinking.thinking_signature) |value| try allocator.dupe(u8, value) else null,
                .redacted = thinking.redacted,
            } },
            .tool_call => |tool_call| .{ .tool_call = try cloneToolCallAlloc(allocator, tool_call) },
        };
    }
    return output;
}

fn cloneTextContentAlloc(allocator: std.mem.Allocator, source: ai.TextContent) !ai.TextContent {
    return .{
        .text = try allocator.dupe(u8, source.text),
        .text_signature = if (source.text_signature) |value| try allocator.dupe(u8, value) else null,
    };
}

fn cloneToolCallAlloc(allocator: std.mem.Allocator, source: ai.ToolCall) !ai.ToolCall {
    return .{
        .id = try allocator.dupe(u8, source.id),
        .name = try allocator.dupe(u8, source.name),
        .arguments_json = try allocator.dupe(u8, source.arguments_json),
        .thought_signature = if (source.thought_signature) |value| try allocator.dupe(u8, value) else null,
    };
}

fn cloneDiagnosticsAlloc(
    allocator: std.mem.Allocator,
    diagnostics: []const ai.AssistantMessageDiagnostic,
) ![]ai.AssistantMessageDiagnostic {
    const output = try allocator.alloc(ai.AssistantMessageDiagnostic, diagnostics.len);
    errdefer allocator.free(output);
    for (diagnostics, 0..) |diagnostic, index| {
        output[index] = .{
            .type = try allocator.dupe(u8, diagnostic.type),
            .timestamp_ms = diagnostic.timestamp_ms,
            .@"error" = if (diagnostic.@"error") |error_info| .{
                .name = if (error_info.name) |value| try allocator.dupe(u8, value) else null,
                .message = try allocator.dupe(u8, error_info.message),
                .stack = if (error_info.stack) |value| try allocator.dupe(u8, value) else null,
                .code = if (error_info.code) |code| switch (code) {
                    .string => |value| .{ .string = try allocator.dupe(u8, value) },
                    .number => |value| .{ .number = value },
                } else null,
            } else null,
            .details_json = if (diagnostic.details_json) |value| try allocator.dupe(u8, value) else null,
        };
    }
    return output;
}

fn deinitAgentMessageSlice(allocator: std.mem.Allocator, messages: []AgentMessage) void {
    for (messages) |*message| deinitAgentMessage(allocator, message);
    allocator.free(messages);
}

fn deinitAgentMessage(allocator: std.mem.Allocator, message: *AgentMessage) void {
    switch (message.*) {
        .user => |user| deinitUserMessage(allocator, user),
        .assistant => |assistant| deinitAssistantMessage(allocator, assistant),
        .tool_result => |tool_result| deinitToolResultMessage(allocator, tool_result),
        .bash_execution => |bash| {
            allocator.free(@constCast(bash.command));
            allocator.free(@constCast(bash.output));
            if (bash.full_output_path) |path| allocator.free(@constCast(path));
        },
        .custom => |custom| {
            allocator.free(@constCast(custom.custom_type));
            switch (custom.content) {
                .text => |text| allocator.free(@constCast(text)),
                .parts => |parts| deinitUserContentSlice(allocator, parts),
            }
            if (custom.details_json) |details| allocator.free(@constCast(details));
        },
        .branch_summary => |summary| {
            allocator.free(@constCast(summary.summary));
            allocator.free(@constCast(summary.from_id));
        },
        .compaction_summary => |summary| allocator.free(@constCast(summary.summary)),
    }
    message.* = undefined;
}

pub fn deinitOwnedMessages(allocator: std.mem.Allocator, messages: []AgentMessage) void {
    deinitAgentMessageSlice(allocator, messages);
}

fn deinitUserMessage(allocator: std.mem.Allocator, message: ai.UserMessage) void {
    deinitUserContentSlice(allocator, message.content);
}

fn deinitAssistantMessage(allocator: std.mem.Allocator, message: ai.AssistantMessage) void {
    deinitAssistantContentSlice(allocator, message.content);
    allocator.free(@constCast(message.api));
    allocator.free(@constCast(message.provider));
    allocator.free(@constCast(message.model));
    if (message.response_model) |value| allocator.free(@constCast(value));
    if (message.error_message) |value| allocator.free(@constCast(value));
    if (message.response_id) |value| allocator.free(@constCast(value));
    deinitDiagnostics(allocator, message.diagnostics);
}

fn deinitToolResultMessage(allocator: std.mem.Allocator, message: ai.ToolResultMessage) void {
    allocator.free(@constCast(message.tool_call_id));
    allocator.free(@constCast(message.tool_name));
    deinitUserContentSlice(allocator, message.content);
}

fn deinitUserContentSlice(allocator: std.mem.Allocator, content: []const ai.UserContent) void {
    for (content) |item| deinitUserContent(allocator, item);
    allocator.free(@constCast(content));
}

fn deinitUserContent(allocator: std.mem.Allocator, content: ai.UserContent) void {
    switch (content) {
        .text => |text| deinitTextContent(allocator, text),
        .image => |image| {
            allocator.free(@constCast(image.data));
            allocator.free(@constCast(image.mime_type));
        },
    }
}

fn deinitAssistantContentSlice(allocator: std.mem.Allocator, content: []const ai.AssistantContent) void {
    for (content) |item| {
        switch (item) {
            .text => |text| deinitTextContent(allocator, text),
            .thinking => |thinking| {
                allocator.free(@constCast(thinking.thinking));
                if (thinking.thinking_signature) |value| allocator.free(@constCast(value));
            },
            .tool_call => |tool_call| {
                allocator.free(@constCast(tool_call.id));
                allocator.free(@constCast(tool_call.name));
                allocator.free(@constCast(tool_call.arguments_json));
                if (tool_call.thought_signature) |value| allocator.free(@constCast(value));
            },
        }
    }
    allocator.free(@constCast(content));
}

fn deinitTextContent(allocator: std.mem.Allocator, text: ai.TextContent) void {
    allocator.free(@constCast(text.text));
    if (text.text_signature) |value| allocator.free(@constCast(value));
}

fn deinitDiagnostics(allocator: std.mem.Allocator, diagnostics: []const ai.AssistantMessageDiagnostic) void {
    for (diagnostics) |diagnostic| {
        allocator.free(@constCast(diagnostic.type));
        if (diagnostic.@"error") |error_info| {
            if (error_info.name) |value| allocator.free(@constCast(value));
            allocator.free(@constCast(error_info.message));
            if (error_info.stack) |value| allocator.free(@constCast(value));
            if (error_info.code) |code| switch (code) {
                .string => |value| allocator.free(@constCast(value)),
                .number => {},
            };
        }
        if (diagnostic.details_json) |value| allocator.free(@constCast(value));
    }
    allocator.free(@constCast(diagnostics));
}

fn noopToolExecute(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: ?*ai.AbortSignal,
    _: agent_loop.ToolUpdateCallback,
) !agent_loop.AgentToolResult {
    return .{};
}

fn testUserMessageAlloc(allocator: std.mem.Allocator, text: []const u8, timestamp_ms: i64) !AgentMessage {
    const content = try allocator.alloc(ai.UserContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .user = .{ .content = content, .timestamp_ms = timestamp_ms } };
}

fn testAssistantMessageAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    stop_reason: ai.StopReason,
    error_message: ?[]const u8,
) !AgentMessage {
    const content = try allocator.alloc(ai.AssistantContent, 1);
    errdefer allocator.free(content);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    errdefer deinitAssistantContentSlice(allocator, content);
    return .{ .assistant = .{
        .content = content,
        .api = try allocator.dupe(u8, "openai-responses"),
        .provider = try allocator.dupe(u8, "openai"),
        .model = try allocator.dupe(u8, "mock"),
        .stop_reason = stop_reason,
        .error_message = if (error_message) |value| try allocator.dupe(u8, value) else null,
        .timestamp_ms = 123,
    } };
}

fn testTool(name: []const u8) AgentLoopTool {
    return .{
        .name = name,
        .label = name,
        .description = "test tool",
        .parameters_json = "{}",
        .execute = .{ .call_fn = noopToolExecute },
    };
}

const TestStreamContext = struct {
    response_count: usize = 0,
    received_session_id: ?[]const u8 = null,
    received_signal: ?*ai.AbortSignal = null,
};

const StreamOptionsCapture = struct {
    resolver_calls: usize = 0,
    resolved_api_key: ?[]const u8 = null,
    resolver_provider: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_tokens: ?u64 = null,
    cache_retention: ai.CacheRetention = .short,
    metadata_json: ?[]const u8 = null,
    header_count: usize = 0,
    context_message_count: usize = 0,
    system_prompt: ?[]const u8 = null,
    signal_seen: bool = false,
};

const TransformConvertCapture = struct {
    transform_source_len: usize = 0,
    transform_output_len: usize = 0,
    converted_len: usize = 0,
    stream_message_len: usize = 0,
    transform_signal_seen: bool = false,
    convert_signal_seen: bool = false,
    stream_signal_seen: bool = false,
};

const ToolHookCapture = struct {
    stream_calls: usize = 0,
    before_context_len: usize = 0,
    after_context_len: usize = 0,
    before_signal_seen: bool = false,
    after_signal_seen: bool = false,
    execute_signal_seen: bool = false,
    after_is_error: bool = true,
    executed_arguments_json: ?[]u8 = null,

    fn deinit(self: *ToolHookCapture, allocator: std.mem.Allocator) void {
        if (self.executed_arguments_json) |value| allocator.free(value);
        self.* = undefined;
    }
};

const after_tool_content = [_]ai.UserContent{.{ .text = .{ .text = "after hook" } }};
const rich_stream_content = [_]ai.AssistantContent{
    .{ .thinking = .{ .thinking = "plan", .thinking_signature = "sig" } },
    .{ .text = .{ .text = "answer" } },
    .{ .tool_call = .{
        .id = "tool-1",
        .name = "echo",
        .arguments_json = "{\"value\":\"hello\"}",
    } },
};
const done_stream_content = [_]ai.AssistantContent{.{ .text = .{ .text = "done" } }};

fn testOkStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    _: ai.Context,
    options: ai.StreamOptions,
) !ai.StreamResult {
    const context: *TestStreamContext = @ptrCast(@alignCast(ptr.?));
    context.response_count += 1;
    context.received_session_id = options.session_id;
    context.received_signal = options.signal;

    const content = try allocator.alloc(ai.AssistantContent, 1);
    content[0] = .{ .text = .{
        .text = try std.fmt.allocPrint(allocator, "Processed {d}", .{context.response_count}),
    } };

    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = .stop,
            .timestamp_ms = @intCast(context.response_count),
        },
    };
    errdefer result.deinit();
    try result.events.append(allocator, .{ .start = {} });
    try result.events.append(allocator, .{ .done = .stop });
    return result;
}

fn testThrowingStream(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: ai.Model,
    _: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    return error.ProviderExploded;
}

fn testCaptureOptionsStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    options: ai.StreamOptions,
) !ai.StreamResult {
    const capture: *StreamOptionsCapture = @ptrCast(@alignCast(ptr.?));
    capture.api_key = options.api_key;
    capture.temperature = options.temperature;
    capture.max_tokens = options.max_tokens;
    capture.cache_retention = options.cache_retention;
    capture.metadata_json = options.metadata_json;
    capture.header_count = options.headers.len;
    capture.context_message_count = context.messages.len;
    capture.system_prompt = context.system_prompt;
    capture.signal_seen = options.signal != null;

    const content = try allocator.alloc(ai.AssistantContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "ok") } };
    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = .stop,
            .timestamp_ms = 1,
        },
    };
    errdefer result.deinit();
    try result.events.append(allocator, .{ .done = .stop });
    return result;
}

fn testResolveApiKey(ptr: ?*anyopaque, provider: []const u8) !?[]const u8 {
    const capture: *StreamOptionsCapture = @ptrCast(@alignCast(ptr.?));
    capture.resolver_calls += 1;
    capture.resolver_provider = provider;
    return capture.resolved_api_key;
}

fn testKeepOnlyLatestMessage(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    source: []const AgentMessage,
    signal: ?*ai.AbortSignal,
) ![]const AgentMessage {
    const capture: *TransformConvertCapture = @ptrCast(@alignCast(ptr.?));
    capture.transform_source_len = source.len;
    capture.transform_signal_seen = signal != null;
    const kept = source[source.len - 1 ..];
    capture.transform_output_len = kept.len;
    return try cloneAgentMessageSliceAlloc(allocator, kept);
}

fn testCaptureConvertToLlm(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    source: []const AgentMessage,
    signal: ?*ai.AbortSignal,
) ![]ai.Message {
    const capture: *TransformConvertCapture = @ptrCast(@alignCast(ptr.?));
    capture.converted_len = source.len;
    capture.convert_signal_seen = signal != null;
    const converted = try agent_messages.convertToLlmAlloc(allocator, source);
    return converted.messages;
}

fn testCaptureLlmContextStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    options: ai.StreamOptions,
) !ai.StreamResult {
    const capture: *TransformConvertCapture = @ptrCast(@alignCast(ptr.?));
    capture.stream_message_len = context.messages.len;
    capture.stream_signal_seen = options.signal != null;

    const content = try allocator.alloc(ai.AssistantContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "converted") } };
    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = .stop,
            .timestamp_ms = 1,
        },
    };
    errdefer result.deinit();
    try result.events.append(allocator, .{ .done = .stop });
    return result;
}

fn testToolCallStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    _: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const capture: *ToolHookCapture = @ptrCast(@alignCast(ptr.?));
    capture.stream_calls += 1;

    const content = try allocator.alloc(ai.AssistantContent, 1);
    content[0] = .{ .tool_call = .{
        .id = try allocator.dupe(u8, "tool-1"),
        .name = try allocator.dupe(u8, "echo"),
        .arguments_json = try allocator.dupe(u8, "{\"value\":\"original\"}"),
    } };
    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = .tool_use,
            .timestamp_ms = 1,
        },
    };
    errdefer result.deinit();
    try result.events.append(allocator, .{ .done = .tool_use });
    return result;
}

fn testRichDeltaThenTextStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    _: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const context: *TestStreamContext = @ptrCast(@alignCast(ptr.?));
    defer context.response_count += 1;

    if (context.response_count > 0) {
        var result: ai.StreamResult = .{
            .allocator = allocator,
            .message = .{
                .content = &done_stream_content,
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .stop_reason = .stop,
                .timestamp_ms = 3,
            },
        };
        try result.events.append(allocator, .{ .done = .stop });
        return result;
    }

    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = .{
            .content = &rich_stream_content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = .tool_use,
            .timestamp_ms = 2,
        },
    };
    try result.events.append(allocator, .{ .start = {} });
    try result.events.append(allocator, .{ .thinking_start = .{ .content_index = 0 } });
    try result.events.append(allocator, .{ .thinking_delta = .{ .content_index = 0, .delta = "pl" } });
    try result.events.append(allocator, .{ .thinking_delta = .{ .content_index = 0, .delta = "an" } });
    try result.events.append(allocator, .{ .thinking_end = .{ .content_index = 0, .content = "plan" } });
    try result.events.append(allocator, .{ .text_start = .{ .content_index = 1 } });
    try result.events.append(allocator, .{ .text_delta = .{ .content_index = 1, .delta = "ans" } });
    try result.events.append(allocator, .{ .text_delta = .{ .content_index = 1, .delta = "wer" } });
    try result.events.append(allocator, .{ .text_end = .{ .content_index = 1, .content = "answer" } });
    try result.events.append(allocator, .{ .toolcall_start = .{ .content_index = 2 } });
    try result.events.append(allocator, .{ .toolcall_delta = .{ .content_index = 2, .delta = "{\"value\":\"" } });
    try result.events.append(allocator, .{ .toolcall_delta = .{ .content_index = 2, .delta = "hello\"}" } });
    try result.events.append(allocator, .{ .toolcall_end = .{
        .content_index = 2,
        .tool_call = rich_stream_content[2].tool_call,
    } });
    try result.events.append(allocator, .{ .done = .tool_use });
    return result;
}

fn testBeforeToolCallRewrite(
    ptr: ?*anyopaque,
    context: agent_loop.BeforeToolCallContext,
    signal: ?*ai.AbortSignal,
) !agent_loop.BeforeToolCallResult {
    const capture: *ToolHookCapture = @ptrCast(@alignCast(ptr.?));
    capture.before_context_len = context.context.messages.len;
    capture.before_signal_seen = signal != null;
    return .{ .arguments_json = "{\"value\":\"rewritten\"}" };
}

fn testAfterToolCallTerminate(
    ptr: ?*anyopaque,
    context: agent_loop.AfterToolCallContext,
    signal: ?*ai.AbortSignal,
) !?agent_loop.AfterToolCallResult {
    const capture: *ToolHookCapture = @ptrCast(@alignCast(ptr.?));
    capture.after_context_len = context.context.messages.len;
    capture.after_signal_seen = signal != null;
    capture.after_is_error = context.is_error;
    return .{
        .content = &after_tool_content,
        .details_json = "{\"after\":true}",
        .terminate = true,
    };
}

fn testCaptureToolExecute(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    arguments_json: []const u8,
    signal: ?*ai.AbortSignal,
    _: agent_loop.ToolUpdateCallback,
) !agent_loop.AgentToolResult {
    const capture: *ToolHookCapture = @ptrCast(@alignCast(ptr.?));
    if (capture.executed_arguments_json) |value| std.testing.allocator.free(value);
    capture.executed_arguments_json = try std.testing.allocator.dupe(u8, arguments_json);
    capture.execute_signal_seen = signal != null;

    const content = try allocator.alloc(ai.UserContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "tool result") } };
    return .{ .content = content, .details_json = "{\"before\":true}" };
}

const ListenerCapture = struct {
    agent: *Agent,
    tags: std.ArrayList(std.meta.Tag(AgentEvent)) = .empty,
    saw_agent_end_while_active: bool = false,
    saw_agent_start_unaborted: bool = false,

    fn deinit(self: *ListenerCapture, allocator: std.mem.Allocator) void {
        self.tags.deinit(allocator);
    }
};

const StreamingProjectionCapture = struct {
    agent: *Agent,
    update_tags: std.ArrayList(std.meta.Tag(ai.StreamEvent)) = .empty,
    saw_empty_tool_use_start: bool = false,
    saw_final_tool_use_end: bool = false,

    fn deinit(self: *StreamingProjectionCapture, allocator: std.mem.Allocator) void {
        self.update_tags.deinit(allocator);
    }
};

fn captureListener(ptr: ?*anyopaque, event: AgentEvent, signal: *ai.AbortSignal) !void {
    const capture: *ListenerCapture = @ptrCast(@alignCast(ptr.?));
    const tag = std.meta.activeTag(event);
    try capture.tags.append(std.testing.allocator, tag);
    if (tag == .agent_start) {
        capture.saw_agent_start_unaborted = !signal.isAborted();
    }
    if (tag == .agent_end) {
        capture.saw_agent_end_while_active = capture.agent.active and capture.agent.state.is_streaming;
    }
}

fn captureStreamingProjection(ptr: ?*anyopaque, event: AgentEvent, _: *ai.AbortSignal) !void {
    const capture: *StreamingProjectionCapture = @ptrCast(@alignCast(ptr.?));
    switch (event) {
        .message_start => |payload| if (payload.message == .assistant and payload.message.assistant.stop_reason == .tool_use) {
            capture.saw_empty_tool_use_start = payload.message.assistant.content.len == 0;
            const streaming_message = capture.agent.state.streaming_message orelse return error.ExpectedStreamingMessage;
            try std.testing.expect(streaming_message == .assistant);
            try std.testing.expectEqual(@as(usize, 0), streaming_message.assistant.content.len);
        },
        .message_update => |payload| {
            try capture.update_tags.append(std.testing.allocator, std.meta.activeTag(payload.assistant_message_event));
            try expectRichPartialAssistant(payload.message.assistant, payload.assistant_message_event);
            const streaming_message = capture.agent.state.streaming_message orelse return error.ExpectedStreamingMessage;
            try std.testing.expect(streaming_message == .assistant);
            try expectRichPartialAssistant(streaming_message.assistant, payload.assistant_message_event);
        },
        .message_end => |payload| if (payload.message == .assistant and payload.message.assistant.stop_reason == .tool_use) {
            capture.saw_final_tool_use_end = true;
            try std.testing.expect(capture.agent.state.streaming_message == null);
            try std.testing.expectEqual(@as(usize, 3), payload.message.assistant.content.len);
            try std.testing.expectEqualStrings("plan", payload.message.assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("answer", payload.message.assistant.content[1].text.text);
            try std.testing.expectEqualStrings("{\"value\":\"hello\"}", payload.message.assistant.content[2].tool_call.arguments_json);
        },
        else => {},
    }
}

fn expectRichPartialAssistant(assistant: ai.AssistantMessage, event: ai.StreamEvent) !void {
    switch (event) {
        .thinking_start => {
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            try std.testing.expect(assistant.content[0] == .thinking);
            try std.testing.expectEqualStrings("", assistant.content[0].thinking.thinking);
        },
        .thinking_delta => |delta| {
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            try std.testing.expect(assistant.content[0] == .thinking);
            const expected = if (std.mem.eql(u8, delta.delta, "pl")) "pl" else "plan";
            try std.testing.expectEqualStrings(expected, assistant.content[0].thinking.thinking);
        },
        .thinking_end => {
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            try std.testing.expect(assistant.content[0] == .thinking);
            try std.testing.expectEqualStrings("plan", assistant.content[0].thinking.thinking);
        },
        .text_start => {
            try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
            try std.testing.expect(assistant.content[1] == .text);
            try std.testing.expectEqualStrings("", assistant.content[1].text.text);
        },
        .text_delta => |delta| {
            try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
            try std.testing.expect(assistant.content[1] == .text);
            const expected = if (std.mem.eql(u8, delta.delta, "ans")) "ans" else "answer";
            try std.testing.expectEqualStrings(expected, assistant.content[1].text.text);
        },
        .text_end => {
            try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
            try std.testing.expect(assistant.content[1] == .text);
            try std.testing.expectEqualStrings("answer", assistant.content[1].text.text);
        },
        .toolcall_start => {
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expect(assistant.content[2] == .tool_call);
            try std.testing.expectEqualStrings("", assistant.content[2].tool_call.id);
            try std.testing.expectEqualStrings("", assistant.content[2].tool_call.name);
            try std.testing.expectEqualStrings("", assistant.content[2].tool_call.arguments_json);
        },
        .toolcall_delta => |delta| {
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expect(assistant.content[2] == .tool_call);
            const expected = if (std.mem.eql(u8, delta.delta, "{\"value\":\""))
                "{\"value\":\""
            else
                "{\"value\":\"hello\"}";
            try std.testing.expectEqualStrings(expected, assistant.content[2].tool_call.arguments_json);
        },
        .toolcall_end => {
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expect(assistant.content[2] == .tool_call);
            try std.testing.expectEqualStrings("tool-1", assistant.content[2].tool_call.id);
            try std.testing.expectEqualStrings("echo", assistant.content[2].tool_call.name);
            try std.testing.expectEqualStrings("{\"value\":\"hello\"}", assistant.content[2].tool_call.arguments_json);
        },
        else => return error.ExpectedAssistantDeltaEvent,
    }
}

fn hasUserText(messages: []const AgentMessage, text: []const u8) bool {
    for (messages) |message| {
        if (message != .user) continue;
        for (message.user.content) |content| {
            if (content == .text and std.mem.eql(u8, content.text.text, text)) return true;
        }
    }
    return false;
}

// Ported from packages/agent/test/agent.test.ts default construction.
test "agent creates default state" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{});
    defer agent.deinit();

    try std.testing.expectEqualStrings("", agent.state.system_prompt);
    try std.testing.expectEqualStrings("unknown", agent.state.model.id);
    try std.testing.expectEqualStrings("unknown", agent.state.model.provider);
    try std.testing.expectEqual(ai.ThinkingLevel.off, agent.state.thinking_level);
    try std.testing.expectEqual(@as(usize, 0), agent.state.tools.len);
    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
    try std.testing.expect(!agent.state.is_streaming);
    try std.testing.expect(agent.state.streaming_message == null);
    try std.testing.expectEqual(@as(usize, 0), agent.state.pending_tool_calls.count());
    try std.testing.expect(agent.state.error_message == null);
    try std.testing.expectEqual(QueueMode.one_at_a_time, agent.steeringMode());
    try std.testing.expectEqual(QueueMode.one_at_a_time, agent.followUpMode());
    try std.testing.expectEqual(ToolExecutionMode.parallel, agent.tool_execution);
}

// Ported from packages/agent/test/agent.test.ts custom initial state behavior.
test "agent creates custom initial state with owned top-level arrays" {
    const custom_model: ai.Model = .{
        .id = "gpt-4o-mini",
        .name = "GPT 4o mini",
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .base_url = "https://api.openai.test",
    };
    const tools = [_]AgentLoopTool{testTool("search")};
    var initial_message = try testUserMessageAlloc(std.testing.allocator, "hello", 1);
    defer deinitAgentMessage(std.testing.allocator, &initial_message);
    const initial_messages = [_]AgentMessage{initial_message};

    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .initial_state = .{
            .system_prompt = "You are a helpful assistant.",
            .model = custom_model,
            .thinking_level = .low,
            .tools = &tools,
            .messages = &initial_messages,
        },
        .session_id = "session-abc",
        .tool_execution = .sequential,
    });
    defer agent.deinit();

    try std.testing.expectEqualStrings("You are a helpful assistant.", agent.state.system_prompt);
    try std.testing.expectEqualStrings("gpt-4o-mini", agent.state.model.id);
    try std.testing.expectEqual(ai.ThinkingLevel.low, agent.state.thinking_level);
    try std.testing.expectEqual(@as(usize, 1), agent.state.tools.len);
    try std.testing.expectEqual(@as(usize, 1), agent.state.messages.len);
    try std.testing.expect(agent.state.tools.ptr != tools[0..].ptr);
    try std.testing.expect(agent.state.messages.ptr != initial_messages[0..].ptr);
    try std.testing.expectEqualStrings("session-abc", agent.session_id.?);
    try std.testing.expectEqual(ToolExecutionMode.sequential, agent.tool_execution);
}

// Ported from packages/agent/test/agent.test.ts state mutator copy semantics.
test "agent state mutators copy tools and messages" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{});
    defer agent.deinit();

    try agent.state.setSystemPrompt("Custom prompt");
    try std.testing.expectEqualStrings("Custom prompt", agent.state.system_prompt);

    const new_model: ai.Model = .{
        .id = "gemini-2.5-flash",
        .name = "Gemini 2.5 Flash",
        .api = ai.types.api.google_generative_ai,
        .provider = "google",
        .base_url = "https://generativelanguage.googleapis.test",
    };
    agent.state.setModel(new_model);
    try std.testing.expectEqualStrings("google", agent.state.model.provider);
    agent.state.setThinkingLevel(.high);
    try std.testing.expectEqual(ai.ThinkingLevel.high, agent.state.thinking_level);

    const tools = [_]AgentLoopTool{testTool("test")};
    try agent.state.setToolsAlloc(&tools);
    try std.testing.expectEqual(@as(usize, 1), agent.state.tools.len);
    try std.testing.expect(agent.state.tools.ptr != tools[0..].ptr);

    var user = try testUserMessageAlloc(std.testing.allocator, "Hello", 10);
    defer deinitAgentMessage(std.testing.allocator, &user);
    const messages = [_]AgentMessage{user};
    try agent.state.setMessagesAlloc(&messages);
    try std.testing.expectEqual(@as(usize, 1), agent.state.messages.len);
    try std.testing.expect(agent.state.messages.ptr != messages[0..].ptr);

    var assistant = try testAssistantMessageAlloc(std.testing.allocator, "Hi", .stop, null);
    defer deinitAgentMessage(std.testing.allocator, &assistant);
    try agent.state.appendMessage(assistant);
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);

    try agent.state.setMessagesAlloc(&.{});
    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
}

// Ported from packages/agent/test/agent.test.ts queue helpers.
test "agent supports steering and follow-up queues" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{});
    defer agent.deinit();

    var steering = try testUserMessageAlloc(std.testing.allocator, "Steering message", 1);
    defer deinitAgentMessage(std.testing.allocator, &steering);
    var follow_up = try testUserMessageAlloc(std.testing.allocator, "Follow-up message", 2);
    defer deinitAgentMessage(std.testing.allocator, &follow_up);
    try agent.steer(steering);
    try agent.followUp(follow_up);
    try std.testing.expect(agent.hasQueuedMessages());
    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);

    const steer_one = try agent.steering_queue.drainAlloc(std.testing.allocator);
    defer deinitOwnedMessages(std.testing.allocator, steer_one);
    try std.testing.expectEqual(@as(usize, 1), steer_one.len);
    try std.testing.expectEqual(@as(usize, 0), agent.steering_queue.messages.len);

    agent.setFollowUpMode(.all);
    var follow_up_two = try testUserMessageAlloc(std.testing.allocator, "Follow-up two", 3);
    defer deinitAgentMessage(std.testing.allocator, &follow_up_two);
    try agent.followUp(follow_up_two);
    const follow_all = try agent.follow_up_queue.drainAlloc(std.testing.allocator);
    defer deinitOwnedMessages(std.testing.allocator, follow_all);
    try std.testing.expectEqual(@as(usize, 2), follow_all.len);
    try std.testing.expect(!agent.hasQueuedMessages());
}

// Ported from packages/agent/test/agent.test.ts abort and reset runtime state.
test "agent aborts active runs and reset clears transcript runtime and queues" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{});
    defer agent.deinit();

    const signal = try agent.beginRun();
    try std.testing.expect(agent.state.is_streaming);
    try std.testing.expect(!signal.isAborted());
    try std.testing.expectError(error.AlreadyProcessing, agent.beginRun());

    agent.abort();
    try std.testing.expect(signal.isAborted());
    try agent.state.addPendingToolCall("call-1");
    var partial = try testAssistantMessageAlloc(std.testing.allocator, "partial", .stop, null);
    defer deinitAgentMessage(std.testing.allocator, &partial);
    try agent.state.setStreamingMessage(partial);
    try agent.state.setErrorMessage("provider exploded");
    var hello = try testUserMessageAlloc(std.testing.allocator, "hello", 1);
    defer deinitAgentMessage(std.testing.allocator, &hello);
    var again = try testUserMessageAlloc(std.testing.allocator, "again", 2);
    defer deinitAgentMessage(std.testing.allocator, &again);
    try agent.state.appendMessage(hello);
    try agent.followUp(again);

    agent.reset();

    try std.testing.expect(!agent.state.is_streaming);
    try std.testing.expect(!agent.active);
    try std.testing.expect(agent.state.streaming_message == null);
    try std.testing.expect(agent.state.error_message == null);
    try std.testing.expectEqual(@as(usize, 0), agent.state.pending_tool_calls.count());
    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
    try std.testing.expect(!agent.hasQueuedMessages());
}

// Ported from packages/agent/src/agent.ts processEvents state reducer.
test "agent processEvent updates streaming message pending tool calls and errors" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{});
    defer agent.deinit();

    var partial = try testAssistantMessageAlloc(std.testing.allocator, "partial", .stop, null);
    defer deinitAgentMessage(std.testing.allocator, &partial);
    try agent.processEvent(.{ .message_start = .{ .message = partial } });
    try std.testing.expect(agent.state.streaming_message != null);

    try agent.processEvent(.{ .tool_execution_start = .{
        .tool_call_id = "tool-call-1",
        .tool_name = "search",
        .arguments_json = "{}",
    } });
    try std.testing.expect(agent.state.pending_tool_calls.contains("tool-call-1"));

    try agent.processEvent(.{ .tool_execution_end = .{
        .tool_call_id = "tool-call-1",
        .tool_name = "search",
        .result = .{},
        .is_error = false,
    } });
    try std.testing.expect(!agent.state.pending_tool_calls.contains("tool-call-1"));

    var failed = try testAssistantMessageAlloc(std.testing.allocator, "", .@"error", "provider exploded");
    defer deinitAgentMessage(std.testing.allocator, &failed);
    try agent.processEvent(.{ .message_end = .{ .message = failed } });
    try agent.processEvent(.{ .turn_end = .{ .message = failed, .tool_results = &.{} } });
    try std.testing.expectEqual(@as(usize, 1), agent.state.messages.len);
    try std.testing.expectEqualStrings("provider exploded", agent.state.error_message.?);
    try std.testing.expect(agent.state.streaming_message == null);
}

// Ported from packages/agent/src/agent.ts normalizePromptInput text+images path.
test "agent normalizes text prompt input with images" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{});
    defer agent.deinit();

    const images = [_]ai.ImageContent{.{ .data = "abc", .mime_type = "image/png" }};
    const messages = try agent.normalizePromptTextAlloc(std.testing.allocator, "hello", &images, 42);
    defer deinitOwnedMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expect(messages[0] == .user);
    try std.testing.expectEqual(@as(i64, 42), messages[0].user.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 2), messages[0].user.content.len);
    try std.testing.expectEqualStrings("hello", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("image/png", messages[0].user.content[1].image.mime_type);
}

// Ported from packages/agent/test/agent.test.ts subscribe and prompt lifecycle coverage.
test "agent prompt replays lifecycle events to subscribers before becoming idle" {
    var stream_context: TestStreamContext = .{};
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .stream = .{ .ptr = &stream_context, .call_fn = testOkStream },
    });
    defer agent.deinit();

    var capture: ListenerCapture = .{ .agent = &agent };
    defer capture.deinit(std.testing.allocator);
    const listener_id = try agent.subscribe(.{ .ptr = &capture, .call_fn = captureListener });

    try agent.promptTextAlloc("hello", &.{});

    const expected = [_]std.meta.Tag(AgentEvent){
        .agent_start,
        .turn_start,
        .message_start,
        .message_end,
        .message_start,
        .message_end,
        .turn_end,
        .agent_end,
    };
    try std.testing.expectEqualSlices(std.meta.Tag(AgentEvent), &expected, capture.tags.items);
    try std.testing.expect(capture.saw_agent_start_unaborted);
    try std.testing.expect(capture.saw_agent_end_while_active);
    try std.testing.expect(agent.waitForIdle());
    try std.testing.expect(!agent.state.is_streaming);
    try std.testing.expect(agent.state.streaming_message == null);
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[0] == .user);
    try std.testing.expect(agent.state.messages[1] == .assistant);

    agent.unsubscribe(listener_id);
    try agent.promptTextAlloc("again", &.{});
    try std.testing.expectEqual(@as(usize, expected.len), capture.tags.items.len);
}

// Ported from packages/agent/test/agent.test.ts streaming message state and subscriber visibility.
test "agent prompt exposes assistant stream partial updates to subscribers" {
    var stream_context: TestStreamContext = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .label = "Echo",
        .description = "Echo tool",
        .parameters_json = "{}",
        .execute = .{ .call_fn = noopToolExecute },
    }};
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .initial_state = .{ .tools = &tools },
        .stream = .{ .ptr = &stream_context, .call_fn = testRichDeltaThenTextStream },
    });
    defer agent.deinit();

    var capture: StreamingProjectionCapture = .{ .agent = &agent };
    defer capture.deinit(std.testing.allocator);
    _ = try agent.subscribe(.{ .ptr = &capture, .call_fn = captureStreamingProjection });

    try agent.promptTextAlloc("stream rich response", &.{});

    const expected_tags = [_]std.meta.Tag(ai.StreamEvent){
        .thinking_start,
        .thinking_delta,
        .thinking_delta,
        .thinking_end,
        .text_start,
        .text_delta,
        .text_delta,
        .text_end,
        .toolcall_start,
        .toolcall_delta,
        .toolcall_delta,
        .toolcall_end,
    };
    try std.testing.expectEqualSlices(std.meta.Tag(ai.StreamEvent), &expected_tags, capture.update_tags.items[0..expected_tags.len]);
    try std.testing.expect(capture.saw_empty_tool_use_start);
    try std.testing.expect(capture.saw_final_tool_use_end);
    try std.testing.expect(agent.waitForIdle());
    try std.testing.expect(agent.state.streaming_message == null);
    try std.testing.expectEqual(@as(usize, 2), stream_context.response_count);
    try std.testing.expectEqual(@as(usize, 4), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[1] == .assistant);
    try std.testing.expectEqual(ai.StopReason.tool_use, agent.state.messages[1].assistant.stop_reason);
    try std.testing.expect(agent.state.messages[2] == .tool_result);
    try std.testing.expect(agent.state.messages[3] == .assistant);
    try std.testing.expectEqualStrings("done", agent.state.messages[3].assistant.content[0].text.text);
}

// Ported from packages/agent/test/agent.test.ts thrown run failure lifecycle.
test "agent emits full lifecycle events for thrown run failures" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .stream = .{ .call_fn = testThrowingStream },
    });
    defer agent.deinit();

    var capture: ListenerCapture = .{ .agent = &agent };
    defer capture.deinit(std.testing.allocator);
    _ = try agent.subscribe(.{ .ptr = &capture, .call_fn = captureListener });

    try agent.promptTextAlloc("hello", &.{});

    const expected = [_]std.meta.Tag(AgentEvent){
        .agent_start,
        .turn_start,
        .message_start,
        .message_end,
        .message_start,
        .message_end,
        .turn_end,
        .agent_end,
    };
    try std.testing.expectEqualSlices(std.meta.Tag(AgentEvent), &expected, capture.tags.items);
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);
    const last_message = agent.state.messages[agent.state.messages.len - 1];
    try std.testing.expect(last_message == .assistant);
    try std.testing.expectEqual(ai.StopReason.@"error", last_message.assistant.stop_reason);
    try std.testing.expectEqualStrings("ProviderExploded", last_message.assistant.error_message.?);
    try std.testing.expectEqualStrings("ProviderExploded", agent.state.error_message.?);
    try std.testing.expect(agent.waitForIdle());
}

// Ported from packages/agent/test/agent.test.ts active run guards.
test "agent rejects nested prompts while a run is active" {
    const NestedPromptCapture = struct {
        agent: *Agent,
        rejected: bool = false,

        fn listener(ptr: ?*anyopaque, event: AgentEvent, _: *ai.AbortSignal) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (event != .agent_start) return;
            self.agent.promptTextAlloc("nested", &.{}) catch |err| {
                if (err == error.AlreadyProcessing) {
                    self.rejected = true;
                    return;
                }
                return err;
            };
            return error.ExpectedAlreadyProcessing;
        }
    };

    var stream_context: TestStreamContext = .{};
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .stream = .{ .ptr = &stream_context, .call_fn = testOkStream },
    });
    defer agent.deinit();

    var capture: NestedPromptCapture = .{ .agent = &agent };
    _ = try agent.subscribe(.{ .ptr = &capture, .call_fn = NestedPromptCapture.listener });

    try agent.promptTextAlloc("hello", &.{});
    try std.testing.expect(capture.rejected);
}

// Ported from packages/agent/test/agent.test.ts sessionId forwarding.
test "agent forwards session id to stream options and supports setter" {
    var stream_context: TestStreamContext = .{};
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .stream = .{ .ptr = &stream_context, .call_fn = testOkStream },
        .session_id = "session-abc",
    });
    defer agent.deinit();

    try agent.promptTextAlloc("hello", &.{});
    try std.testing.expect(stream_context.received_signal != null);
    try std.testing.expectEqualStrings("session-abc", stream_context.received_session_id.?);

    try agent.setSessionId("session-def");
    try agent.promptTextAlloc("hello again", &.{});
    try std.testing.expectEqualStrings("session-def", stream_context.received_session_id.?);
}

// Ported from packages/agent/test/agent.test.ts stream option and auth forwarding.
test "agent forwards stream options and api key resolver results" {
    const headers = [_]ai.Header{.{ .name = "x-test", .value = "one" }};
    var capture: StreamOptionsCapture = .{ .resolved_api_key = "resolved-key" };
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .initial_state = .{
            .system_prompt = "system prompt",
            .model = .{
                .id = "mock",
                .name = "mock",
                .api = ai.types.api.openai_responses,
                .provider = "openai",
                .base_url = "https://example.invalid",
            },
        },
        .stream = .{ .ptr = &capture, .call_fn = testCaptureOptionsStream },
        .stream_options = .{
            .temperature = 0.7,
            .max_tokens = 123,
            .cache_retention = .long,
            .headers = &headers,
            .metadata_json = "{\"trace\":\"abc\"}",
        },
        .api_key = "fallback-key",
        .get_api_key = .{ .ptr = &capture, .call_fn = testResolveApiKey },
    });
    defer agent.deinit();

    try agent.promptTextAlloc("hello", &.{});
    try std.testing.expectEqual(@as(usize, 1), capture.resolver_calls);
    try std.testing.expectEqualStrings("openai", capture.resolver_provider.?);
    try std.testing.expectEqualStrings("resolved-key", capture.api_key.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), capture.temperature.?, 0.000001);
    try std.testing.expectEqual(@as(u64, 123), capture.max_tokens.?);
    try std.testing.expectEqual(ai.CacheRetention.long, capture.cache_retention);
    try std.testing.expectEqualStrings("{\"trace\":\"abc\"}", capture.metadata_json.?);
    try std.testing.expectEqual(@as(usize, 1), capture.header_count);
    try std.testing.expectEqual(@as(usize, 1), capture.context_message_count);
    try std.testing.expectEqualStrings("system prompt", capture.system_prompt.?);
    try std.testing.expect(capture.signal_seen);

    capture.resolved_api_key = null;
    try agent.setApiKey("next-fallback");
    try agent.promptTextAlloc("hello again", &.{});
    try std.testing.expectEqual(@as(usize, 2), capture.resolver_calls);
    try std.testing.expectEqualStrings("next-fallback", capture.api_key.?);
}

// Ported from packages/agent/test/agent.test.ts transform/convert option forwarding.
test "agent forwards transform context and convert to llm hooks" {
    var capture: TransformConvertCapture = .{};
    var old_user = try testUserMessageAlloc(std.testing.allocator, "old user", 1);
    defer deinitAgentMessage(std.testing.allocator, &old_user);
    var old_assistant = try testAssistantMessageAlloc(std.testing.allocator, "old assistant", .stop, null);
    defer deinitAgentMessage(std.testing.allocator, &old_assistant);
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .initial_state = .{ .messages = &.{ old_user, old_assistant } },
        .stream = .{ .ptr = &capture, .call_fn = testCaptureLlmContextStream },
        .transform_context = .{ .ptr = &capture, .call_fn = testKeepOnlyLatestMessage },
        .convert_to_llm = .{ .ptr = &capture, .call_fn = testCaptureConvertToLlm },
    });
    defer agent.deinit();

    try agent.promptTextAlloc("latest", &.{});

    try std.testing.expectEqual(@as(usize, 3), capture.transform_source_len);
    try std.testing.expectEqual(@as(usize, 1), capture.transform_output_len);
    try std.testing.expectEqual(@as(usize, 1), capture.converted_len);
    try std.testing.expectEqual(@as(usize, 1), capture.stream_message_len);
    try std.testing.expect(capture.transform_signal_seen);
    try std.testing.expect(capture.convert_signal_seen);
    try std.testing.expect(capture.stream_signal_seen);
}

// Ported from packages/agent/test/agent.test.ts tool hook forwarding through Agent.
test "agent forwards before and after tool call hooks through prompt runs" {
    var capture: ToolHookCapture = .{};
    defer capture.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .label = "Echo",
        .description = "Echo tool",
        .parameters_json = "{}",
        .execute = .{ .ptr = &capture, .call_fn = testCaptureToolExecute },
    }};
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .initial_state = .{ .tools = &tools },
        .stream = .{ .ptr = &capture, .call_fn = testToolCallStream },
        .before_tool_call = .{ .ptr = &capture, .call_fn = testBeforeToolCallRewrite },
        .after_tool_call = .{ .ptr = &capture, .call_fn = testAfterToolCallTerminate },
    });
    defer agent.deinit();

    try agent.promptTextAlloc("use a tool", &.{});

    try std.testing.expectEqual(@as(usize, 1), capture.stream_calls);
    try std.testing.expectEqual(@as(usize, 2), capture.before_context_len);
    try std.testing.expectEqual(@as(usize, 2), capture.after_context_len);
    try std.testing.expect(capture.before_signal_seen);
    try std.testing.expect(capture.after_signal_seen);
    try std.testing.expect(capture.execute_signal_seen);
    try std.testing.expect(!capture.after_is_error);
    try std.testing.expectEqualStrings("{\"value\":\"rewritten\"}", capture.executed_arguments_json.?);
    try std.testing.expectEqual(@as(usize, 3), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[2] == .tool_result);
    try std.testing.expectEqualStrings("after hook", agent.state.messages[2].tool_result.content[0].text.text);
    try std.testing.expect(!agent.state.messages[2].tool_result.is_error);
}

// Ported from packages/agent/test/agent.test.ts continue run guard behavior.
test "agent continueRun rejects empty state and assistant tails without queued work" {
    var agent = try Agent.initAlloc(std.testing.allocator, .{});
    defer agent.deinit();

    try std.testing.expectError(error.CannotContinueNoMessages, agent.continueRunAlloc());

    var assistant = try testAssistantMessageAlloc(std.testing.allocator, "done", .stop, null);
    defer deinitAgentMessage(std.testing.allocator, &assistant);
    try agent.state.setMessagesAlloc(&.{assistant});

    try std.testing.expectError(error.CannotContinueFromAssistant, agent.continueRunAlloc());
}

// Ported from packages/agent/test/agent.test.ts assistant-tail follow-up continuation.
test "agent continueRun processes queued follow-up messages after assistant tail" {
    var stream_context: TestStreamContext = .{};
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .stream = .{ .ptr = &stream_context, .call_fn = testOkStream },
    });
    defer agent.deinit();

    var initial_user = try testUserMessageAlloc(std.testing.allocator, "Initial", 1);
    defer deinitAgentMessage(std.testing.allocator, &initial_user);
    var initial_assistant = try testAssistantMessageAlloc(std.testing.allocator, "Initial response", .stop, null);
    defer deinitAgentMessage(std.testing.allocator, &initial_assistant);
    try agent.state.setMessagesAlloc(&.{ initial_user, initial_assistant });

    var follow_up = try testUserMessageAlloc(std.testing.allocator, "Queued follow-up", 2);
    defer deinitAgentMessage(std.testing.allocator, &follow_up);
    try agent.followUp(follow_up);

    try agent.continueRunAlloc();

    try std.testing.expect(hasUserText(agent.state.messages, "Queued follow-up"));
    try std.testing.expect(agent.state.messages[agent.state.messages.len - 1] == .assistant);
    try std.testing.expectEqual(@as(usize, 1), stream_context.response_count);
}

// Ported from packages/agent/test/agent.test.ts assistant-tail one-at-a-time steering semantics.
test "agent continueRun keeps one-at-a-time steering semantics from assistant tail" {
    var stream_context: TestStreamContext = .{};
    var agent = try Agent.initAlloc(std.testing.allocator, .{
        .stream = .{ .ptr = &stream_context, .call_fn = testOkStream },
    });
    defer agent.deinit();

    var initial_user = try testUserMessageAlloc(std.testing.allocator, "Initial", 1);
    defer deinitAgentMessage(std.testing.allocator, &initial_user);
    var initial_assistant = try testAssistantMessageAlloc(std.testing.allocator, "Initial response", .stop, null);
    defer deinitAgentMessage(std.testing.allocator, &initial_assistant);
    try agent.state.setMessagesAlloc(&.{ initial_user, initial_assistant });

    var steering_one = try testUserMessageAlloc(std.testing.allocator, "Steering 1", 2);
    defer deinitAgentMessage(std.testing.allocator, &steering_one);
    var steering_two = try testUserMessageAlloc(std.testing.allocator, "Steering 2", 3);
    defer deinitAgentMessage(std.testing.allocator, &steering_two);
    try agent.steer(steering_one);
    try agent.steer(steering_two);

    try agent.continueRunAlloc();

    try std.testing.expectEqual(@as(usize, 2), stream_context.response_count);
    try std.testing.expectEqual(@as(usize, 6), agent.state.messages.len);
    const recent = agent.state.messages[2..];
    try std.testing.expect(recent[0] == .user);
    try std.testing.expect(recent[1] == .assistant);
    try std.testing.expect(recent[2] == .user);
    try std.testing.expect(recent[3] == .assistant);
    try std.testing.expect(hasUserText(recent, "Steering 1"));
    try std.testing.expect(hasUserText(recent, "Steering 2"));
}
