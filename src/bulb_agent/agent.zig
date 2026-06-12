const std = @import("std");
const ai = @import("bulb_ai");

const agent_loop = @import("agent_loop.zig");
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
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    session_id: ?[]const u8 = null,
    tool_execution: ToolExecutionMode = .parallel,
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
        if (self.session_id) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn setSessionId(self: *Agent, session_id: ?[]const u8) !void {
        if (self.session_id) |value| self.allocator.free(value);
        self.session_id = if (session_id) |value| try self.allocator.dupe(u8, value) else null;
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
};

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
