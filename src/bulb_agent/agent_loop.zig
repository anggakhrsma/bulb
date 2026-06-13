const std = @import("std");
const ai = @import("bulb_ai");

const agent_messages = @import("messages.zig");
const types = @import("types.zig");

pub const AgentMessage = types.AgentMessage;
pub const ToolExecutionMode = enum { sequential, parallel };

pub const AgentLoopError = error{
    CannotContinueNoMessages,
    CannotContinueFromAssistant,
    MissingStreamFunction,
};

pub const AgentToolResult = struct {
    content: []const ai.UserContent = &.{},
    details_json: []const u8 = "{}",
    terminate: bool = false,
};

pub const ToolUpdateCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, AgentToolResult) anyerror!void = noopToolUpdate,

    pub fn call(self: ToolUpdateCallback, partial_result: AgentToolResult) !void {
        try self.call_fn(self.ptr, partial_result);
    }
};

pub const PrepareArgumentsHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8,

    pub fn call(self: PrepareArgumentsHandler, allocator: std.mem.Allocator, arguments_json: []const u8) ![]const u8 {
        return try self.call_fn(self.ptr, allocator, arguments_json);
    }
};

pub const ExecuteToolHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const u8,
        []const u8,
        ?*ai.AbortSignal,
        ToolUpdateCallback,
    ) anyerror!AgentToolResult,

    pub fn call(
        self: ExecuteToolHandler,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        arguments_json: []const u8,
        signal: ?*ai.AbortSignal,
        on_update: ToolUpdateCallback,
    ) !AgentToolResult {
        return try self.call_fn(self.ptr, allocator, tool_call_id, arguments_json, signal, on_update);
    }
};

pub const AgentLoopTool = struct {
    name: []const u8,
    label: []const u8 = "",
    description: []const u8 = "",
    parameters_json: []const u8 = "{}",
    execution_mode: ?ToolExecutionMode = null,
    prepare_arguments: ?PrepareArgumentsHandler = null,
    execute: ExecuteToolHandler,

    pub fn asAiTool(self: AgentLoopTool) ai.Tool {
        return .{
            .name = self.name,
            .description = self.description,
            .parameters_json = self.parameters_json,
        };
    }
};

pub const AgentContext = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const AgentMessage = &.{},
    tools: []const AgentLoopTool = &.{},
};

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
    arguments_json: ?[]const u8 = null,
};

pub const AfterToolCallResult = struct {
    content: ?[]const ai.UserContent = null,
    details_json: ?[]const u8 = null,
    is_error: ?bool = null,
    terminate: ?bool = null,
};

pub const BeforeToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    arguments_json: []const u8,
    context: AgentContext,
};

pub const AfterToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    arguments_json: []const u8,
    result: AgentToolResult,
    is_error: bool,
    context: AgentContext,
};

pub const ShouldStopAfterTurnContext = struct {
    message: AgentMessage,
    tool_results: []const ai.ToolResultMessage,
    context: AgentContext,
    new_messages: []const AgentMessage,
};

pub const AgentLoopTurnUpdate = struct {
    context: ?AgentContext = null,
    model: ?ai.Model = null,
    thinking_level: ?ai.ThinkingLevel = null,
};

pub const ConvertToLlmHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const AgentMessage, ?*ai.AbortSignal) anyerror![]ai.Message = defaultConvertToLlm,

    pub fn call(
        self: ConvertToLlmHandler,
        allocator: std.mem.Allocator,
        messages: []const AgentMessage,
        signal: ?*ai.AbortSignal,
    ) ![]ai.Message {
        return try self.call_fn(self.ptr, allocator, messages, signal);
    }
};

pub const TransformContextHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const AgentMessage, ?*ai.AbortSignal) anyerror![]const AgentMessage,

    pub fn call(
        self: TransformContextHandler,
        allocator: std.mem.Allocator,
        messages: []const AgentMessage,
        signal: ?*ai.AbortSignal,
    ) ![]const AgentMessage {
        return try self.call_fn(self.ptr, allocator, messages, signal);
    }
};

pub const GetApiKeyHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) anyerror!?[]const u8,

    pub fn call(self: GetApiKeyHandler, provider: []const u8) !?[]const u8 {
        return try self.call_fn(self.ptr, provider);
    }
};

pub const QueuedMessagesHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]const AgentMessage,

    pub fn call(self: QueuedMessagesHandler, allocator: std.mem.Allocator) ![]const AgentMessage {
        return try self.call_fn(self.ptr, allocator);
    }
};

pub const BeforeToolCallHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, BeforeToolCallContext, ?*ai.AbortSignal) anyerror!BeforeToolCallResult,

    pub fn call(self: BeforeToolCallHandler, context: BeforeToolCallContext, signal: ?*ai.AbortSignal) !BeforeToolCallResult {
        return try self.call_fn(self.ptr, context, signal);
    }
};

pub const AfterToolCallHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, AfterToolCallContext, ?*ai.AbortSignal) anyerror!?AfterToolCallResult,

    pub fn call(self: AfterToolCallHandler, context: AfterToolCallContext, signal: ?*ai.AbortSignal) !?AfterToolCallResult {
        return try self.call_fn(self.ptr, context, signal);
    }
};

pub const ShouldStopAfterTurnHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, ShouldStopAfterTurnContext) anyerror!bool,

    pub fn call(self: ShouldStopAfterTurnHandler, context: ShouldStopAfterTurnContext) !bool {
        return try self.call_fn(self.ptr, context);
    }
};

pub const PrepareNextTurnHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, ShouldStopAfterTurnContext) anyerror!?AgentLoopTurnUpdate,

    pub fn call(self: PrepareNextTurnHandler, context: ShouldStopAfterTurnContext) !?AgentLoopTurnUpdate {
        return try self.call_fn(self.ptr, context);
    }
};

pub const StreamHandler = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        ai.Model,
        ai.Context,
        ai.StreamOptions,
    ) anyerror!ai.StreamResult,

    pub fn call(
        self: StreamHandler,
        allocator: std.mem.Allocator,
        model: ai.Model,
        context: ai.Context,
        options: ai.StreamOptions,
    ) !ai.StreamResult {
        return try self.call_fn(self.ptr, allocator, model, context, options);
    }
};

pub const AgentLoopConfig = struct {
    model: ai.Model,
    thinking_level: ai.ThinkingLevel = .off,
    api_key: ?[]const u8 = null,
    stream_options: ai.StreamOptions = .{},
    stream: ?StreamHandler = null,
    convert_to_llm: ConvertToLlmHandler = .{},
    transform_context: ?TransformContextHandler = null,
    get_api_key: ?GetApiKeyHandler = null,
    get_steering_messages: ?QueuedMessagesHandler = null,
    get_follow_up_messages: ?QueuedMessagesHandler = null,
    before_tool_call: ?BeforeToolCallHandler = null,
    after_tool_call: ?AfterToolCallHandler = null,
    should_stop_after_turn: ?ShouldStopAfterTurnHandler = null,
    prepare_next_turn: ?PrepareNextTurnHandler = null,
    tool_execution: ToolExecutionMode = .parallel,
};

pub const AgentEvent = union(enum) {
    agent_start: void,
    agent_end: struct { messages: []const AgentMessage },
    turn_start: void,
    turn_end: struct { message: AgentMessage, tool_results: []const ai.ToolResultMessage },
    message_start: struct { message: AgentMessage },
    message_update: struct { message: AgentMessage, assistant_message_event: ai.StreamEvent },
    message_end: struct { message: AgentMessage },
    tool_execution_start: struct { tool_call_id: []const u8, tool_name: []const u8, arguments_json: []const u8 },
    tool_execution_update: struct { tool_call_id: []const u8, tool_name: []const u8, arguments_json: []const u8, partial_result: AgentToolResult },
    tool_execution_end: struct { tool_call_id: []const u8, tool_name: []const u8, result: AgentToolResult, is_error: bool },
};

pub const AgentLoopResult = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    events: []const AgentEvent,
    messages: []const AgentMessage,

    pub fn deinit(self: *AgentLoopResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const MutableContext = struct {
    system_prompt: ?[]const u8,
    messages: std.ArrayList(AgentMessage),
    tools: []const AgentLoopTool,

    fn snapshot(self: MutableContext) AgentContext {
        return .{
            .system_prompt = self.system_prompt,
            .messages = self.messages.items,
            .tools = self.tools,
        };
    }
};

const LoopState = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(AgentEvent),
    event_mutex: std.atomic.Mutex,
    new_messages: std.ArrayList(AgentMessage),
    current: MutableContext,
    config: AgentLoopConfig,
    signal: ?*ai.AbortSignal,
};

const ExecutedToolCallBatch = struct {
    messages: []const ai.ToolResultMessage,
    terminate: bool,
};

const PreparedToolCall = struct {
    tool_call: ai.ToolCall,
    tool: AgentLoopTool,
    arguments_json: []const u8,
};

const ImmediateToolCallOutcome = struct {
    result: AgentToolResult,
    is_error: bool,
};

const ToolPreparation = union(enum) {
    prepared: PreparedToolCall,
    immediate: ImmediateToolCallOutcome,
};

const ExecutedToolCallOutcome = struct {
    result: AgentToolResult,
    is_error: bool,
};

const FinalizedToolCallOutcome = struct {
    tool_call: ai.ToolCall,
    result: AgentToolResult,
    is_error: bool,
};

const EventSink = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList(AgentEvent),
    event_mutex: *std.atomic.Mutex,
    tool_call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
};

pub fn runAgentLoopAlloc(
    allocator: std.mem.Allocator,
    prompts: []const AgentMessage,
    context: AgentContext,
    config: AgentLoopConfig,
    signal: ?*ai.AbortSignal,
) !AgentLoopResult {
    var arena = std.heap.ArenaAllocator.init(if (canUseParallelToolExecution(config, context.tools)) std.heap.smp_allocator else allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var state = try initLoopState(a, context, config, signal);
    try appendEvent(a, &state.events, .{ .agent_start = {} });
    try appendEvent(a, &state.events, .{ .turn_start = {} });
    for (prompts) |prompt| {
        const current_prompt = try cloneAgentMessageAlloc(a, prompt);
        const new_prompt = try cloneAgentMessageAlloc(a, prompt);
        try state.current.messages.append(a, current_prompt);
        try state.new_messages.append(a, new_prompt);
        try appendEvent(a, &state.events, .{ .message_start = .{ .message = prompt } });
        try appendEvent(a, &state.events, .{ .message_end = .{ .message = prompt } });
    }

    try runLoop(&state);
    const events = try state.events.toOwnedSlice(a);
    const messages = try state.new_messages.toOwnedSlice(a);
    return .{
        .allocator = allocator,
        .arena = arena,
        .events = events,
        .messages = messages,
    };
}

pub fn runAgentLoopContinueAlloc(
    allocator: std.mem.Allocator,
    context: AgentContext,
    config: AgentLoopConfig,
    signal: ?*ai.AbortSignal,
) !AgentLoopResult {
    if (context.messages.len == 0) return error.CannotContinueNoMessages;
    if (context.messages[context.messages.len - 1] == .assistant) return error.CannotContinueFromAssistant;

    var arena = std.heap.ArenaAllocator.init(if (canUseParallelToolExecution(config, context.tools)) std.heap.smp_allocator else allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var state = try initLoopState(a, context, config, signal);
    try appendEvent(a, &state.events, .{ .agent_start = {} });
    try appendEvent(a, &state.events, .{ .turn_start = {} });

    try runLoop(&state);
    const events = try state.events.toOwnedSlice(a);
    const messages = try state.new_messages.toOwnedSlice(a);
    return .{
        .allocator = allocator,
        .arena = arena,
        .events = events,
        .messages = messages,
    };
}

fn initLoopState(
    allocator: std.mem.Allocator,
    context: AgentContext,
    config: AgentLoopConfig,
    signal: ?*ai.AbortSignal,
) !LoopState {
    var current_messages = std.ArrayList(AgentMessage).empty;
    for (context.messages) |message| {
        try current_messages.append(allocator, try cloneAgentMessageAlloc(allocator, message));
    }

    return .{
        .allocator = allocator,
        .events = .empty,
        .new_messages = .empty,
        .current = .{
            .system_prompt = if (context.system_prompt) |prompt| try allocator.dupe(u8, prompt) else null,
            .messages = current_messages,
            .tools = context.tools,
        },
        .event_mutex = .unlocked,
        .config = config,
        .signal = signal,
    };
}

fn runLoop(state: *LoopState) !void {
    const a = state.allocator;
    var first_turn = true;
    var pending_messages = try getQueuedMessages(a, state.config.get_steering_messages);

    while (true) {
        var has_more_tool_calls = true;

        while (has_more_tool_calls or pending_messages.len > 0) {
            if (!first_turn) {
                try appendEvent(a, &state.events, .{ .turn_start = {} });
            } else {
                first_turn = false;
            }

            if (pending_messages.len > 0) {
                for (pending_messages) |message| {
                    try state.current.messages.append(a, try cloneAgentMessageAlloc(a, message));
                    try state.new_messages.append(a, try cloneAgentMessageAlloc(a, message));
                    try appendEvent(a, &state.events, .{ .message_start = .{ .message = message } });
                    try appendEvent(a, &state.events, .{ .message_end = .{ .message = message } });
                }
                pending_messages = &.{};
            }

            const assistant_message = try streamAssistantResponse(state);
            try state.new_messages.append(a, try cloneAgentMessageAlloc(a, assistant_message));

            const assistant = assistant_message.assistant;
            if (assistant.stop_reason == .@"error" or assistant.stop_reason == .aborted) {
                try appendEvent(a, &state.events, .{ .turn_end = .{
                    .message = assistant_message,
                    .tool_results = &.{},
                } });
                try appendEvent(a, &state.events, .{ .agent_end = .{ .messages = state.new_messages.items } });
                return;
            }

            has_more_tool_calls = false;
            var tool_results: []const ai.ToolResultMessage = &.{};
            if (countToolCalls(assistant.content) > 0) {
                const executed = try executeToolCalls(state, assistant);
                tool_results = executed.messages;
                has_more_tool_calls = !executed.terminate;
                for (tool_results) |tool_result| {
                    const message: AgentMessage = .{ .tool_result = tool_result };
                    try state.current.messages.append(a, try cloneAgentMessageAlloc(a, message));
                    try state.new_messages.append(a, try cloneAgentMessageAlloc(a, message));
                }
            }

            try appendEvent(a, &state.events, .{ .turn_end = .{
                .message = assistant_message,
                .tool_results = tool_results,
            } });

            const turn_context: ShouldStopAfterTurnContext = .{
                .message = assistant_message,
                .tool_results = tool_results,
                .context = state.current.snapshot(),
                .new_messages = state.new_messages.items,
            };

            if (state.config.prepare_next_turn) |handler| {
                if (try handler.call(turn_context)) |update| {
                    if (update.context) |next_context| {
                        try replaceCurrentContext(a, &state.current, next_context);
                    }
                    if (update.model) |model| state.config.model = model;
                    if (update.thinking_level) |level| state.config.thinking_level = level;
                }
            }

            if (state.config.should_stop_after_turn) |handler| {
                if (try handler.call(.{
                    .message = assistant_message,
                    .tool_results = tool_results,
                    .context = state.current.snapshot(),
                    .new_messages = state.new_messages.items,
                })) {
                    try appendEvent(a, &state.events, .{ .agent_end = .{ .messages = state.new_messages.items } });
                    return;
                }
            }

            pending_messages = try getQueuedMessages(a, state.config.get_steering_messages);
        }

        const follow_up_messages = try getQueuedMessages(a, state.config.get_follow_up_messages);
        if (follow_up_messages.len > 0) {
            pending_messages = follow_up_messages;
            continue;
        }
        break;
    }

    try appendEvent(a, &state.events, .{ .agent_end = .{ .messages = state.new_messages.items } });
}

fn streamAssistantResponse(state: *LoopState) !AgentMessage {
    const a = state.allocator;
    const stream_handler = state.config.stream orelse return error.MissingStreamFunction;
    const messages_for_llm = if (state.config.transform_context) |handler|
        try handler.call(a, state.current.messages.items, state.signal)
    else
        state.current.messages.items;

    const llm_messages = try state.config.convert_to_llm.call(a, messages_for_llm, state.signal);
    const llm_tools = try toolsForLlmAlloc(a, state.current.tools);
    const llm_context: ai.Context = .{
        .system_prompt = state.current.system_prompt,
        .messages = llm_messages,
        .tools = llm_tools,
    };

    var options = state.config.stream_options;
    options.signal = state.signal;
    options.api_key = if (state.config.get_api_key) |handler|
        (try handler.call(state.config.model.provider)) orelse state.config.api_key
    else
        state.config.api_key;

    var response = try stream_handler.call(a, state.config.model, llm_context, options);
    defer response.deinit();

    const assistant_message = try cloneAssistantMessageAlloc(a, response.message);
    const agent_message: AgentMessage = .{ .assistant = assistant_message };
    var partial = AssistantPartialProjection.init(a, assistant_message);

    var emitted_start = false;
    for (response.events.items) |event| {
        switch (event) {
            .start => {
                if (!emitted_start) {
                    try appendEvent(a, &state.events, .{ .message_start = .{ .message = try partial.messageAlloc() } });
                    emitted_start = true;
                }
            },
            .text_start,
            .text_delta,
            .text_end,
            .thinking_start,
            .thinking_delta,
            .thinking_end,
            .toolcall_start,
            .toolcall_delta,
            .toolcall_end,
            => {
                if (!emitted_start) {
                    try appendEvent(a, &state.events, .{ .message_start = .{ .message = try partial.messageAlloc() } });
                    emitted_start = true;
                }
                try partial.apply(event);
                try appendEvent(a, &state.events, .{ .message_update = .{
                    .message = try partial.messageAlloc(),
                    .assistant_message_event = event,
                } });
            },
            .done, .@"error" => {},
        }
    }

    if (!emitted_start) {
        try appendEvent(a, &state.events, .{ .message_start = .{ .message = agent_message } });
    }
    try state.current.messages.append(a, try cloneAgentMessageAlloc(a, agent_message));
    try appendEvent(a, &state.events, .{ .message_end = .{ .message = agent_message } });
    return agent_message;
}

const AssistantPartialProjection = struct {
    allocator: std.mem.Allocator,
    template: ai.AssistantMessage,
    content: std.ArrayList(ai.AssistantContent) = .empty,

    fn init(allocator: std.mem.Allocator, template: ai.AssistantMessage) AssistantPartialProjection {
        return .{ .allocator = allocator, .template = template };
    }

    fn messageAlloc(self: *AssistantPartialProjection) !AgentMessage {
        const assistant = ai.AssistantMessage{
            .content = self.content.items,
            .api = self.template.api,
            .provider = self.template.provider,
            .model = self.template.model,
            .response_model = self.template.response_model,
            .usage = self.template.usage,
            .stop_reason = self.template.stop_reason,
            .error_message = self.template.error_message,
            .response_id = self.template.response_id,
            .diagnostics = self.template.diagnostics,
            .timestamp_ms = self.template.timestamp_ms,
        };
        return .{ .assistant = try cloneAssistantMessageAlloc(self.allocator, assistant) };
    }

    fn apply(self: *AssistantPartialProjection, event: ai.StreamEvent) !void {
        switch (event) {
            .text_start => |payload| try self.setText(payload.content_index, ""),
            .text_delta => |payload| try self.appendText(payload.content_index, payload.delta),
            .text_end => |payload| try self.setText(payload.content_index, payload.content),
            .thinking_start => |payload| try self.setThinking(payload.content_index, ""),
            .thinking_delta => |payload| try self.appendThinking(payload.content_index, payload.delta),
            .thinking_end => |payload| try self.setThinking(payload.content_index, payload.content),
            .toolcall_start => |payload| try self.setToolCall(payload.content_index, .{
                .id = "",
                .name = "",
                .arguments_json = "",
            }),
            .toolcall_delta => |payload| try self.appendToolCallArguments(payload.content_index, payload.delta),
            .toolcall_end => |payload| try self.setToolCall(payload.content_index, payload.tool_call),
            else => {},
        }
    }

    fn ensureSlot(self: *AssistantPartialProjection, index: usize) !void {
        while (self.content.items.len <= index) {
            try self.content.append(self.allocator, .{ .text = .{ .text = "" } });
        }
    }

    fn setText(self: *AssistantPartialProjection, index: usize, text: []const u8) !void {
        try self.ensureSlot(index);
        self.content.items[index] = .{ .text = .{ .text = try self.allocator.dupe(u8, text) } };
    }

    fn appendText(self: *AssistantPartialProjection, index: usize, delta: []const u8) !void {
        try self.ensureSlot(index);
        const current = switch (self.content.items[index]) {
            .text => |text| text.text,
            else => "",
        };
        self.content.items[index] = .{ .text = .{ .text = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current, delta }) } };
    }

    fn setThinking(self: *AssistantPartialProjection, index: usize, thinking: []const u8) !void {
        try self.ensureSlot(index);
        self.content.items[index] = .{ .thinking = .{
            .thinking = try self.allocator.dupe(u8, thinking),
            .thinking_signature = null,
            .redacted = false,
        } };
    }

    fn appendThinking(self: *AssistantPartialProjection, index: usize, delta: []const u8) !void {
        try self.ensureSlot(index);
        const current = switch (self.content.items[index]) {
            .thinking => |thinking| thinking.thinking,
            else => "",
        };
        self.content.items[index] = .{ .thinking = .{
            .thinking = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current, delta }),
            .thinking_signature = null,
            .redacted = false,
        } };
    }

    fn setToolCall(self: *AssistantPartialProjection, index: usize, tool_call: ai.ToolCall) !void {
        try self.ensureSlot(index);
        self.content.items[index] = .{ .tool_call = try cloneToolCallAlloc(self.allocator, tool_call) };
    }

    fn appendToolCallArguments(self: *AssistantPartialProjection, index: usize, delta: []const u8) !void {
        try self.ensureSlot(index);
        const current = switch (self.content.items[index]) {
            .tool_call => |tool_call| tool_call,
            else => ai.ToolCall{ .id = "", .name = "", .arguments_json = "" },
        };
        self.content.items[index] = .{ .tool_call = .{
            .id = try self.allocator.dupe(u8, current.id),
            .name = try self.allocator.dupe(u8, current.name),
            .arguments_json = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current.arguments_json, delta }),
            .thought_signature = if (current.thought_signature) |value| try self.allocator.dupe(u8, value) else null,
        } };
    }
};

fn executeToolCalls(state: *LoopState, assistant_message: ai.AssistantMessage) !ExecutedToolCallBatch {
    if (!canUseParallelToolExecution(state.config, state.current.tools) or countToolCalls(assistant_message.content) <= 1) {
        return try executeToolCallsSequential(state, assistant_message);
    }

    return try executeToolCallsParallel(state, assistant_message);
}

fn executeToolCallsSequential(state: *LoopState, assistant_message: ai.AssistantMessage) !ExecutedToolCallBatch {
    const a = state.allocator;
    var finalized_calls = std.ArrayList(FinalizedToolCallOutcome).empty;
    var messages = std.ArrayList(ai.ToolResultMessage).empty;

    for (assistant_message.content) |block| {
        if (block != .tool_call) continue;
        const tool_call = block.tool_call;
        try appendEvent(a, &state.events, .{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .arguments_json = tool_call.arguments_json,
        } });

        const preparation = try prepareToolCall(state, assistant_message, tool_call);
        const finalized = switch (preparation) {
            .immediate => |immediate| FinalizedToolCallOutcome{
                .tool_call = try cloneToolCallAlloc(a, tool_call),
                .result = try cloneAgentToolResultAlloc(a, immediate.result),
                .is_error = immediate.is_error,
            },
            .prepared => |prepared| blk: {
                const executed = try executePreparedToolCall(state, prepared);
                break :blk try finalizeExecutedToolCall(state, assistant_message, prepared, executed);
            },
        };

        try emitToolExecutionEnd(a, &state.events, finalized);
        const tool_result_message = try createToolResultMessageAlloc(a, finalized);
        try emitToolResultMessage(a, &state.events, tool_result_message);
        try finalized_calls.append(a, finalized);
        try messages.append(a, tool_result_message);

        if (state.signal) |signal| {
            if (signal.isAborted()) break;
        }
    }

    return .{
        .messages = try messages.toOwnedSlice(a),
        .terminate = shouldTerminateToolBatch(finalized_calls.items),
    };
}

const ParallelToolCallItem = struct {
    prepared: ?PreparedToolCall = null,
    finalized: ?FinalizedToolCallOutcome = null,
    thread: ?std.Thread = null,
};

const ParallelToolWorkerContext = struct {
    state: *LoopState,
    assistant_message: ai.AssistantMessage,
    item: *ParallelToolCallItem,
};

fn executeToolCallsParallel(state: *LoopState, assistant_message: ai.AssistantMessage) !ExecutedToolCallBatch {
    const a = state.allocator;
    const tool_call_count = countToolCalls(assistant_message.content);
    if (tool_call_count <= 1) return try executeToolCallsSequential(state, assistant_message);

    const items = try a.alloc(ParallelToolCallItem, tool_call_count);
    for (items) |*item| item.* = .{};

    var item_index: usize = 0;
    var prepared_count: usize = 0;
    for (assistant_message.content) |block| {
        if (block != .tool_call) continue;

        const tool_call = block.tool_call;
        try appendEvent(a, &state.events, .{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .arguments_json = tool_call.arguments_json,
        } });

        const preparation = try prepareToolCall(state, assistant_message, tool_call);
        switch (preparation) {
            .immediate => |immediate| {
                items[item_index].finalized = .{
                    .tool_call = try cloneToolCallAlloc(a, tool_call),
                    .result = try cloneAgentToolResultAlloc(a, immediate.result),
                    .is_error = immediate.is_error,
                };
            },
            .prepared => |prepared| {
                items[item_index].prepared = prepared;
                prepared_count += 1;
            },
        }

        item_index += 1;
    }

    for (items) |item| {
        if (item.finalized) |finalized| {
            try emitToolExecutionEnd(a, &state.events, finalized);
        }
    }

    var worker_contexts = try a.alloc(ParallelToolWorkerContext, prepared_count);
    var worker_index: usize = 0;
    for (items) |*item| {
        const prepared = item.prepared orelse continue;
        worker_contexts[worker_index] = .{
            .state = state,
            .assistant_message = assistant_message,
            .item = item,
        };
        item.thread = try std.Thread.spawn(.{}, parallelToolWorker, .{&worker_contexts[worker_index]});
        worker_index += 1;
        _ = prepared;
    }

    for (items) |*item| {
        if (item.thread) |thread| {
            thread.join();
            item.thread = null;
        }
    }

    var finalized_calls = std.ArrayList(FinalizedToolCallOutcome).empty;
    var messages = std.ArrayList(ai.ToolResultMessage).empty;
    for (items) |item| {
        const finalized = item.finalized orelse return error.Unexpected;
        try finalized_calls.append(a, finalized);
        const tool_result_message = try createToolResultMessageAlloc(a, finalized);
        try emitToolResultMessage(a, &state.events, tool_result_message);
        try messages.append(a, tool_result_message);
    }

    return .{
        .messages = try messages.toOwnedSlice(a),
        .terminate = shouldTerminateToolBatch(finalized_calls.items),
    };
}

fn parallelToolWorker(ctx: *ParallelToolWorkerContext) void {
    const state = ctx.state;
    const a = state.allocator;
    const prepared = ctx.item.prepared orelse return;
    const finalized = finalizeParallelToolCall(state, ctx.assistant_message, prepared) catch |err| blk: {
        const fallback_result = createErrorToolResultAlloc(a, @errorName(err)) catch blk2: {
            break :blk2 AgentToolResult{
                .content = &.{},
                .details_json = "{}",
            };
        };
        break :blk FinalizedToolCallOutcome{
            .tool_call = prepared.tool_call,
            .result = fallback_result,
            .is_error = true,
        };
    };

    ctx.item.finalized = finalized;
    _ = appendEventLocked(a, &state.event_mutex, &state.events, .{ .tool_execution_end = .{
        .tool_call_id = finalized.tool_call.id,
        .tool_name = finalized.tool_call.name,
        .result = finalized.result,
        .is_error = finalized.is_error,
    } }) catch {};
}

fn finalizeParallelToolCall(
    state: *LoopState,
    assistant_message: ai.AssistantMessage,
    prepared: PreparedToolCall,
) !FinalizedToolCallOutcome {
    const executed = try executePreparedToolCall(state, prepared);
    return try finalizeExecutedToolCall(state, assistant_message, prepared, executed);
}

fn prepareToolCall(
    state: *LoopState,
    assistant_message: ai.AssistantMessage,
    tool_call: ai.ToolCall,
) !ToolPreparation {
    const a = state.allocator;
    const tool = findTool(state.current.tools, tool_call.name) orelse return .{ .immediate = .{
        .result = try createErrorToolResultAlloc(a, try std.fmt.allocPrint(a, "Tool {s} not found", .{tool_call.name})),
        .is_error = true,
    } };

    return prepareKnownToolCall(state, assistant_message, tool_call, tool) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .immediate = .{
            .result = try createErrorToolResultAlloc(a, @errorName(err)),
            .is_error = true,
        } },
    };
}

fn prepareKnownToolCall(
    state: *LoopState,
    assistant_message: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    tool: AgentLoopTool,
) !ToolPreparation {
    const a = state.allocator;
    var arguments_json = tool_call.arguments_json;
    if (tool.prepare_arguments) |handler| {
        arguments_json = try handler.call(a, arguments_json);
    }

    const prepared_tool_call = try cloneToolCallWithArgsAlloc(a, tool_call, arguments_json);
    var validated_arguments = try ai.validation.validateToolArguments(a, tool.asAiTool(), prepared_tool_call);
    defer validated_arguments.deinit();
    arguments_json = try std.json.Stringify.valueAlloc(a, validated_arguments.value, .{});

    if (state.config.before_tool_call) |handler| {
        const result = try handler.call(.{
            .assistant_message = assistant_message,
            .tool_call = tool_call,
            .arguments_json = arguments_json,
            .context = state.current.snapshot(),
        }, state.signal);

        if (state.signal) |signal| {
            if (signal.isAborted()) return .{ .immediate = .{
                .result = try createErrorToolResultAlloc(a, "Operation aborted"),
                .is_error = true,
            } };
        }

        if (result.block) return .{ .immediate = .{
            .result = try createErrorToolResultAlloc(a, result.reason orelse "Tool execution was blocked"),
            .is_error = true,
        } };
        if (result.arguments_json) |next| arguments_json = next;
    }

    if (state.signal) |signal| {
        if (signal.isAborted()) return .{ .immediate = .{
            .result = try createErrorToolResultAlloc(a, "Operation aborted"),
            .is_error = true,
        } };
    }

    return .{ .prepared = .{
        .tool_call = try cloneToolCallWithArgsAlloc(a, tool_call, arguments_json),
        .tool = tool,
        .arguments_json = try a.dupe(u8, arguments_json),
    } };
}

fn executePreparedToolCall(state: *LoopState, prepared: PreparedToolCall) !ExecutedToolCallOutcome {
    const a = state.allocator;
    var sink: EventSink = .{
        .allocator = a,
        .events = &state.events,
        .event_mutex = &state.event_mutex,
        .tool_call_id = prepared.tool_call.id,
        .tool_name = prepared.tool_call.name,
        .arguments_json = prepared.arguments_json,
    };

    const callback: ToolUpdateCallback = .{
        .ptr = &sink,
        .call_fn = emitToolUpdate,
    };

    const result = prepared.tool.execute.call(
        a,
        prepared.tool_call.id,
        prepared.arguments_json,
        state.signal,
        callback,
    ) catch |err| return .{
        .result = try createErrorToolResultAlloc(a, @errorName(err)),
        .is_error = true,
    };

    return .{
        .result = try cloneAgentToolResultAlloc(a, result),
        .is_error = false,
    };
}

fn finalizeExecutedToolCall(
    state: *LoopState,
    assistant_message: ai.AssistantMessage,
    prepared: PreparedToolCall,
    executed: ExecutedToolCallOutcome,
) !FinalizedToolCallOutcome {
    const a = state.allocator;
    var result = try cloneAgentToolResultAlloc(a, executed.result);
    var is_error = executed.is_error;

    if (state.config.after_tool_call) |handler| {
        if (try handler.call(.{
            .assistant_message = assistant_message,
            .tool_call = prepared.tool_call,
            .arguments_json = prepared.arguments_json,
            .result = result,
            .is_error = is_error,
            .context = state.current.snapshot(),
        }, state.signal)) |after_result| {
            if (after_result.content) |content| result.content = try cloneUserContentSliceAlloc(a, content);
            if (after_result.details_json) |details| result.details_json = try a.dupe(u8, details);
            if (after_result.terminate) |terminate| result.terminate = terminate;
            if (after_result.is_error) |next_is_error| is_error = next_is_error;
        }
    }

    return .{
        .tool_call = try cloneToolCallAlloc(a, prepared.tool_call),
        .result = result,
        .is_error = is_error,
    };
}

fn createErrorToolResultAlloc(allocator: std.mem.Allocator, message: []const u8) !AgentToolResult {
    const content = try allocator.alloc(ai.UserContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, message) } };
    return .{ .content = content, .details_json = "{}" };
}

fn emitToolExecutionEnd(
    allocator: std.mem.Allocator,
    events: *std.ArrayList(AgentEvent),
    finalized: FinalizedToolCallOutcome,
) !void {
    try appendEvent(allocator, events, .{ .tool_execution_end = .{
        .tool_call_id = finalized.tool_call.id,
        .tool_name = finalized.tool_call.name,
        .result = finalized.result,
        .is_error = finalized.is_error,
    } });
}

fn createToolResultMessageAlloc(
    allocator: std.mem.Allocator,
    finalized: FinalizedToolCallOutcome,
) !ai.ToolResultMessage {
    return .{
        .tool_call_id = try allocator.dupe(u8, finalized.tool_call.id),
        .tool_name = try allocator.dupe(u8, finalized.tool_call.name),
        .content = try cloneUserContentSliceAlloc(allocator, finalized.result.content),
        .is_error = finalized.is_error,
        .timestamp_ms = 0,
    };
}

fn emitToolResultMessage(
    allocator: std.mem.Allocator,
    events: *std.ArrayList(AgentEvent),
    tool_result_message: ai.ToolResultMessage,
) !void {
    const message: AgentMessage = .{ .tool_result = tool_result_message };
    try appendEvent(allocator, events, .{ .message_start = .{ .message = message } });
    try appendEvent(allocator, events, .{ .message_end = .{ .message = message } });
}

fn shouldTerminateToolBatch(finalized_calls: []const FinalizedToolCallOutcome) bool {
    if (finalized_calls.len == 0) return false;
    for (finalized_calls) |finalized| {
        if (!finalized.result.terminate) return false;
    }
    return true;
}

fn getQueuedMessages(allocator: std.mem.Allocator, handler: ?QueuedMessagesHandler) ![]const AgentMessage {
    if (handler) |queue_handler| return try queue_handler.call(allocator);
    return &.{};
}

fn replaceCurrentContext(
    allocator: std.mem.Allocator,
    current: *MutableContext,
    next_context: AgentContext,
) !void {
    const cloned_messages = try cloneAgentMessageSliceAlloc(allocator, next_context.messages);
    current.system_prompt = if (next_context.system_prompt) |prompt| try allocator.dupe(u8, prompt) else null;
    current.messages.clearRetainingCapacity();
    for (cloned_messages) |message| try current.messages.append(allocator, message);
    current.tools = next_context.tools;
}

fn toolsForLlmAlloc(allocator: std.mem.Allocator, tools: []const AgentLoopTool) ![]ai.Tool {
    const output = try allocator.alloc(ai.Tool, tools.len);
    for (tools, 0..) |tool, index| output[index] = tool.asAiTool();
    return output;
}

fn countToolCalls(content: []const ai.AssistantContent) usize {
    var count: usize = 0;
    for (content) |block| {
        if (std.meta.activeTag(block) == .tool_call) count += 1;
    }
    return count;
}

fn findTool(tools: []const AgentLoopTool, name: []const u8) ?AgentLoopTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn defaultConvertToLlm(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    source: []const AgentMessage,
    _: ?*ai.AbortSignal,
) ![]ai.Message {
    const converted = try agent_messages.convertToLlmAlloc(allocator, source);
    return converted.messages;
}

fn appendEvent(
    allocator: std.mem.Allocator,
    events: *std.ArrayList(AgentEvent),
    event: AgentEvent,
) !void {
    try events.append(allocator, try cloneAgentEventAlloc(allocator, event));
}

fn appendEventLocked(
    allocator: std.mem.Allocator,
    mutex: *std.atomic.Mutex,
    events: *std.ArrayList(AgentEvent),
    event: AgentEvent,
) !void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
    defer mutex.unlock();
    try events.append(allocator, try cloneAgentEventAlloc(allocator, event));
}

fn canUseParallelToolExecution(config: AgentLoopConfig, tools: []const AgentLoopTool) bool {
    if (config.tool_execution == .sequential) return false;
    for (tools) |tool| {
        if (tool.execution_mode == .sequential) return false;
    }
    return true;
}

fn cloneAgentEventAlloc(allocator: std.mem.Allocator, event: AgentEvent) !AgentEvent {
    return switch (event) {
        .agent_start => .{ .agent_start = {} },
        .agent_end => |payload| .{ .agent_end = .{ .messages = try cloneAgentMessageSliceAlloc(allocator, payload.messages) } },
        .turn_start => .{ .turn_start = {} },
        .turn_end => |payload| .{ .turn_end = .{
            .message = try cloneAgentMessageAlloc(allocator, payload.message),
            .tool_results = try cloneToolResultMessageSliceAlloc(allocator, payload.tool_results),
        } },
        .message_start => |payload| .{ .message_start = .{ .message = try cloneAgentMessageAlloc(allocator, payload.message) } },
        .message_update => |payload| .{ .message_update = .{
            .message = try cloneAgentMessageAlloc(allocator, payload.message),
            .assistant_message_event = try cloneStreamEventAlloc(allocator, payload.assistant_message_event),
        } },
        .message_end => |payload| .{ .message_end = .{ .message = try cloneAgentMessageAlloc(allocator, payload.message) } },
        .tool_execution_start => |payload| .{ .tool_execution_start = .{
            .tool_call_id = try allocator.dupe(u8, payload.tool_call_id),
            .tool_name = try allocator.dupe(u8, payload.tool_name),
            .arguments_json = try allocator.dupe(u8, payload.arguments_json),
        } },
        .tool_execution_update => |payload| .{ .tool_execution_update = .{
            .tool_call_id = try allocator.dupe(u8, payload.tool_call_id),
            .tool_name = try allocator.dupe(u8, payload.tool_name),
            .arguments_json = try allocator.dupe(u8, payload.arguments_json),
            .partial_result = try cloneAgentToolResultAlloc(allocator, payload.partial_result),
        } },
        .tool_execution_end => |payload| .{ .tool_execution_end = .{
            .tool_call_id = try allocator.dupe(u8, payload.tool_call_id),
            .tool_name = try allocator.dupe(u8, payload.tool_name),
            .result = try cloneAgentToolResultAlloc(allocator, payload.result),
            .is_error = payload.is_error,
        } },
    };
}

fn cloneAgentMessageSliceAlloc(allocator: std.mem.Allocator, source: []const AgentMessage) ![]AgentMessage {
    const output = try allocator.alloc(AgentMessage, source.len);
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

fn cloneToolResultMessageSliceAlloc(
    allocator: std.mem.Allocator,
    source: []const ai.ToolResultMessage,
) ![]ai.ToolResultMessage {
    const output = try allocator.alloc(ai.ToolResultMessage, source.len);
    for (source, 0..) |message, index| output[index] = try cloneToolResultMessageAlloc(allocator, message);
    return output;
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
    for (source, 0..) |content, index| {
        output[index] = switch (content) {
            .text => |text| .{ .text = try cloneTextContentAlloc(allocator, text) },
            .image => |image| .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } },
        };
    }
    return output;
}

fn cloneAssistantContentSliceAlloc(
    allocator: std.mem.Allocator,
    source: []const ai.AssistantContent,
) ![]ai.AssistantContent {
    const output = try allocator.alloc(ai.AssistantContent, source.len);
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
    return try cloneToolCallWithArgsAlloc(allocator, source, source.arguments_json);
}

fn cloneToolCallWithArgsAlloc(allocator: std.mem.Allocator, source: ai.ToolCall, arguments_json: []const u8) !ai.ToolCall {
    return .{
        .id = try allocator.dupe(u8, source.id),
        .name = try allocator.dupe(u8, source.name),
        .arguments_json = try allocator.dupe(u8, arguments_json),
        .thought_signature = if (source.thought_signature) |value| try allocator.dupe(u8, value) else null,
    };
}

fn cloneAgentToolResultAlloc(allocator: std.mem.Allocator, source: AgentToolResult) !AgentToolResult {
    return .{
        .content = try cloneUserContentSliceAlloc(allocator, source.content),
        .details_json = try allocator.dupe(u8, source.details_json),
        .terminate = source.terminate,
    };
}

fn cloneDiagnosticsAlloc(
    allocator: std.mem.Allocator,
    diagnostics: []const ai.AssistantMessageDiagnostic,
) ![]ai.AssistantMessageDiagnostic {
    const output = try allocator.alloc(ai.AssistantMessageDiagnostic, diagnostics.len);
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

fn cloneStreamEventAlloc(allocator: std.mem.Allocator, event: ai.StreamEvent) !ai.StreamEvent {
    return switch (event) {
        .start => .{ .start = {} },
        .text_start => |payload| .{ .text_start = payload },
        .text_delta => |payload| .{ .text_delta = .{
            .content_index = payload.content_index,
            .delta = try allocator.dupe(u8, payload.delta),
        } },
        .text_end => |payload| .{ .text_end = .{
            .content_index = payload.content_index,
            .content = try allocator.dupe(u8, payload.content),
        } },
        .thinking_start => |payload| .{ .thinking_start = payload },
        .thinking_delta => |payload| .{ .thinking_delta = .{
            .content_index = payload.content_index,
            .delta = try allocator.dupe(u8, payload.delta),
        } },
        .thinking_end => |payload| .{ .thinking_end = .{
            .content_index = payload.content_index,
            .content = try allocator.dupe(u8, payload.content),
        } },
        .toolcall_start => |payload| .{ .toolcall_start = payload },
        .toolcall_delta => |payload| .{ .toolcall_delta = .{
            .content_index = payload.content_index,
            .delta = try allocator.dupe(u8, payload.delta),
        } },
        .toolcall_end => |payload| .{ .toolcall_end = .{
            .content_index = payload.content_index,
            .tool_call = try cloneToolCallAlloc(allocator, payload.tool_call),
        } },
        .done => |reason| .{ .done = reason },
        .@"error" => |terminal| .{ .@"error" = .{
            .reason = terminal.reason,
            .message = try cloneAssistantMessageAlloc(allocator, terminal.message),
        } },
    };
}

fn emitToolUpdate(ptr: ?*anyopaque, partial_result: AgentToolResult) !void {
    const sink: *EventSink = @ptrCast(@alignCast(ptr.?));
    try appendEventLocked(sink.allocator, sink.event_mutex, sink.events, .{ .tool_execution_update = .{
        .tool_call_id = sink.tool_call_id,
        .tool_name = sink.tool_name,
        .arguments_json = sink.arguments_json,
        .partial_result = partial_result,
    } });
}

fn noopToolUpdate(_: ?*anyopaque, _: AgentToolResult) !void {}

fn eventTags(allocator: std.mem.Allocator, events: []const AgentEvent) ![]std.meta.Tag(AgentEvent) {
    const output = try allocator.alloc(std.meta.Tag(AgentEvent), events.len);
    for (events, 0..) |event, index| output[index] = std.meta.activeTag(event);
    return output;
}

fn createModel() ai.Model {
    return .{
        .id = "mock",
        .name = "mock",
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .base_url = "https://example.invalid",
        .reasoning = false,
        .input = &.{"text"},
        .cost = .{},
        .context_window = 8192,
        .max_tokens = 2048,
    };
}

fn userMessage(content: []const ai.UserContent) AgentMessage {
    return .{ .user = .{ .content = content, .timestamp_ms = 1 } };
}

fn assistantTextAlloc(
    allocator: std.mem.Allocator,
    model: ai.Model,
    text: []const u8,
    stop_reason: ai.StopReason,
) !ai.AssistantMessage {
    const content = try allocator.alloc(ai.AssistantContent, 1);
    content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .stop_reason = stop_reason,
        .timestamp_ms = 2,
    };
}

fn assistantToolAlloc(
    allocator: std.mem.Allocator,
    model: ai.Model,
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) !ai.AssistantMessage {
    const content = try allocator.alloc(ai.AssistantContent, 1);
    content[0] = .{ .tool_call = .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, arguments_json),
    } };
    return .{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .stop_reason = .tool_use,
        .timestamp_ms = 2,
    };
}

fn doneStreamResult(allocator: std.mem.Allocator, message: ai.AssistantMessage) !ai.StreamResult {
    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = message,
    };
    try result.events.append(allocator, .{ .done = message.stop_reason });
    return result;
}

fn assistantRichToolAlloc(
    allocator: std.mem.Allocator,
    model: ai.Model,
) !ai.AssistantMessage {
    const content = try allocator.alloc(ai.AssistantContent, 3);
    content[0] = .{ .thinking = .{
        .thinking = "plan",
        .thinking_signature = "sig",
    } };
    content[1] = .{ .text = .{ .text = "answer" } };
    content[2] = .{ .tool_call = .{
        .id = "tool-1",
        .name = "echo",
        .arguments_json = "{\"value\":\"hello\"}",
    } };
    return .{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .stop_reason = .tool_use,
        .timestamp_ms = 2,
    };
}

fn richDeltaThenTextStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    _: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const state: *ToolStreamState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count > 0) {
        return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
    }

    const message = try assistantRichToolAlloc(allocator, model);
    const tool_call = message.content[2].tool_call;
    var result: ai.StreamResult = .{
        .allocator = allocator,
        .message = message,
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
    try result.events.append(allocator, .{ .toolcall_end = .{ .content_index = 2, .tool_call = tool_call } });
    try result.events.append(allocator, .{ .done = .tool_use });
    return result;
}

fn textStream(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    _: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "Hi there!", .stop));
}

const CaptureConvertState = struct {
    transformed_len: usize = 0,
    converted_len: usize = 0,
};

const ContinueCustomState = struct {
    call_count: usize = 0,
    saw_custom_as_user: bool = false,
};

fn keepLastTwo(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    source: []const AgentMessage,
    _: ?*ai.AbortSignal,
) ![]const AgentMessage {
    const state: *CaptureConvertState = @ptrCast(@alignCast(ptr.?));
    const kept = source[source.len - 2 ..];
    state.transformed_len = kept.len;
    return try cloneAgentMessageSliceAlloc(allocator, kept);
}

fn captureConvert(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    source: []const AgentMessage,
    _: ?*ai.AbortSignal,
) ![]ai.Message {
    const state: *CaptureConvertState = @ptrCast(@alignCast(ptr.?));
    state.converted_len = source.len;
    const converted = try agent_messages.convertToLlmAlloc(allocator, source);
    return converted.messages;
}

fn captureCustomContinueStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const state: *ContinueCustomState = @ptrCast(@alignCast(ptr.?));
    state.call_count += 1;
    if (context.messages.len == 1 and context.messages[0] == .user) {
        const user = context.messages[0].user;
        if (user.content.len == 1 and user.content[0] == .text and
            std.mem.eql(u8, user.content[0].text.text, "Hook content"))
        {
            state.saw_custom_as_user = true;
        }
    }
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "Response to custom message", .stop));
}

const ToolStreamState = struct {
    call_count: usize = 0,
};

fn toolThenTextStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    _ = context;
    const state: *ToolStreamState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count == 0) {
        return try doneStreamResult(
            allocator,
            try assistantToolAlloc(allocator, model, "tool-1", "echo", "{\"value\":\"hello\"}"),
        );
    }
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
}

fn numberStringToolThenTextStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    _ = context;
    const state: *ToolStreamState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count == 0) {
        return try doneStreamResult(
            allocator,
            try assistantToolAlloc(allocator, model, "tool-1", "echo", "{\"value\":\"42\"}"),
        );
    }
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
}

fn invalidBooleanToolThenTextStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    _ = context;
    const state: *ToolStreamState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count == 0) {
        return try doneStreamResult(
            allocator,
            try assistantToolAlloc(allocator, model, "tool-1", "echo", "{\"value\":\"1\"}"),
        );
    }
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
}

const EchoToolState = struct {
    executed: std.ArrayList([]const u8) = .empty,
};

fn echoToolExecute(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    arguments_json: []const u8,
    _: ?*ai.AbortSignal,
    on_update: ToolUpdateCallback,
) !AgentToolResult {
    const state: *EchoToolState = @ptrCast(@alignCast(ptr.?));
    const value = extractJsonStringValue(arguments_json, "value") orelse arguments_json;
    try state.executed.append(std.testing.allocator, value);

    const update_content = try allocator.alloc(ai.UserContent, 1);
    update_content[0] = .{ .text = .{ .text = "started" } };
    try on_update.call(.{ .content = update_content, .details_json = "{\"phase\":\"start\"}" });

    const content = try allocator.alloc(ai.UserContent, 1);
    content[0] = .{ .text = .{ .text = try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}) } };
    return .{
        .content = content,
        .details_json = try std.fmt.allocPrint(allocator, "{{\"value\":\"{s}\"}}", .{value}),
    };
}

fn terminatingEchoToolExecute(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    arguments_json: []const u8,
    signal: ?*ai.AbortSignal,
    on_update: ToolUpdateCallback,
) !AgentToolResult {
    var result = try echoToolExecute(ptr, allocator, tool_call_id, arguments_json, signal, on_update);
    result.terminate = true;
    return result;
}

fn extractJsonStringValue(json: []const u8, field: []const u8) ?[]const u8 {
    var pattern_buffer: [96]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buffer, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, json, pattern) orelse return null;
    const value_start = start + pattern.len;
    const value_end = std.mem.indexOfScalarPos(u8, json, value_start, '"') orelse return null;
    return json[value_start..value_end];
}

fn noQueuedMessages(_: ?*anyopaque, _: std.mem.Allocator) ![]const AgentMessage {
    return &.{};
}

const StopState = struct {
    steering_polls: usize = 0,
    follow_up_polls: usize = 0,
    callback_tool_results: usize = 0,
};

const BatchQueueState = struct {
    tool_state: *EchoToolState,
    queued_delivered: bool = false,
    polls: usize = 0,
};

fn queuedAfterToolStarts(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]const AgentMessage {
    const state: *BatchQueueState = @ptrCast(@alignCast(ptr.?));
    state.polls += 1;
    if (state.tool_state.executed.items.len >= 1 and !state.queued_delivered) {
        state.queued_delivered = true;
        const content = try allocator.alloc(ai.UserContent, 1);
        content[0] = .{ .text = .{ .text = "interrupt" } };
        const output = try allocator.alloc(AgentMessage, 1);
        output[0] = userMessage(content);
        return output;
    }
    return &.{};
}

fn countSteeringPolls(ptr: ?*anyopaque, _: std.mem.Allocator) ![]const AgentMessage {
    const state: *StopState = @ptrCast(@alignCast(ptr.?));
    state.steering_polls += 1;
    return &.{};
}

fn forbiddenFollowUps(ptr: ?*anyopaque, allocator: std.mem.Allocator) ![]const AgentMessage {
    const state: *StopState = @ptrCast(@alignCast(ptr.?));
    state.follow_up_polls += 1;
    const content = try allocator.alloc(ai.UserContent, 1);
    content[0] = .{ .text = .{ .text = "follow up should stay queued" } };
    const output = try allocator.alloc(AgentMessage, 1);
    output[0] = userMessage(content);
    return output;
}

fn stopAfterTurn(ptr: ?*anyopaque, context: ShouldStopAfterTurnContext) !bool {
    const state: *StopState = @ptrCast(@alignCast(ptr.?));
    state.callback_tool_results = context.tool_results.len;
    return true;
}

const PrepareState = struct {
    prepared: bool = false,
    call_count: usize = 0,
    second_system_prompt: ?[]const u8 = null,
};

fn prepareSecondPrompt(ptr: ?*anyopaque, context: ShouldStopAfterTurnContext) !?AgentLoopTurnUpdate {
    const state: *PrepareState = @ptrCast(@alignCast(ptr.?));
    if (state.prepared) return null;
    state.prepared = true;
    return .{ .context = .{
        .system_prompt = "second prompt",
        .messages = context.context.messages,
        .tools = context.context.tools,
    } };
}

fn captureSecondSystemPromptStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const state: *PrepareState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count == 0) {
        return try doneStreamResult(
            allocator,
            try assistantToolAlloc(allocator, model, "tool-1", "echo", "{\"value\":\"hello\"}"),
        );
    }
    state.second_system_prompt = context.system_prompt;
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
}

// Ported from packages/agent/test/agent-loop.test.ts event sequencing basics.
test "agent loop emits events with agent message types" {
    const allocator = std.testing.allocator;
    const content = [_]ai.UserContent{.{ .text = .{ .text = "Hello" } }};
    const prompt = userMessage(&content);
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .call_fn = textStream },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .system_prompt = "You are helpful." }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
    try std.testing.expect(result.messages[0] == .user);
    try std.testing.expect(result.messages[1] == .assistant);

    const tags = try eventTags(allocator, result.events);
    defer allocator.free(tags);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(AgentEvent), tags, .agent_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(AgentEvent), tags, .turn_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(AgentEvent), tags, .message_start) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(AgentEvent), tags, .message_end) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(AgentEvent), tags, .turn_end) != null);
    try std.testing.expect(std.mem.indexOfScalar(std.meta.Tag(AgentEvent), tags, .agent_end) != null);
}

// Ported from packages/agent/test/agent-loop.test.ts transform-before-convert behavior.
test "agent loop applies transform context before convert to llm" {
    const allocator = std.testing.allocator;
    const old1 = [_]ai.UserContent{.{ .text = .{ .text = "old message 1" } }};
    const old2 = [_]ai.UserContent{.{ .text = .{ .text = "old message 2" } }};
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "new message" } }};
    const old_assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "old response" } }};
    const context_messages = [_]AgentMessage{
        userMessage(&old1),
        .{ .assistant = .{
            .content = &old_assistant_content,
            .api = ai.types.api.openai_responses,
            .provider = "openai",
            .model = "mock",
        } },
        userMessage(&old2),
    };
    const prompt = userMessage(&prompt_content);

    var capture: CaptureConvertState = .{};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .call_fn = textStream },
        .transform_context = .{ .ptr = &capture, .call_fn = keepLastTwo },
        .convert_to_llm = .{ .ptr = &capture, .call_fn = captureConvert },
    };

    var result = try runAgentLoopAlloc(
        allocator,
        &.{prompt},
        .{ .system_prompt = "You are helpful.", .messages = &context_messages },
        config,
        null,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), capture.transformed_len);
    try std.testing.expectEqual(@as(usize, 2), capture.converted_len);
}

// Ported from packages/agent/test/agent-loop.test.ts tool call and tool result flow.
test "agent loop executes tool calls and emits tool events" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo something" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: ToolStreamState = .{};
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .label = "Echo",
        .description = "Echo tool",
        .parameters_json = "{\"type\":\"object\"}",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = toolThenTextStream },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), tool_state.executed.items.len);
    try std.testing.expectEqualStrings("hello", tool_state.executed.items[0]);
    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
    try std.testing.expect(result.messages[0] == .user);
    try std.testing.expect(result.messages[1] == .assistant);
    try std.testing.expect(result.messages[2] == .tool_result);
    try std.testing.expect(result.messages[3] == .assistant);

    var saw_start = false;
    var saw_update = false;
    var saw_end = false;
    for (result.events) |event| switch (event) {
        .tool_execution_start => saw_start = true,
        .tool_execution_update => saw_update = true,
        .tool_execution_end => |payload| {
            saw_end = true;
            try std.testing.expect(!payload.is_error);
        },
        else => {},
    };
    try std.testing.expect(saw_start);
    try std.testing.expect(saw_update);
    try std.testing.expect(saw_end);
}

// Ported from packages/agent/src/agent-loop.ts streamAssistantResponse partial update behavior.
test "agent loop projects assistant stream deltas into partial message updates" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "stream rich response" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: ToolStreamState = .{};
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = richDeltaThenTextStream },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), stream_state.call_count);
    try std.testing.expectEqual(@as(usize, 1), tool_state.executed.items.len);
    try std.testing.expectEqualStrings("hello", tool_state.executed.items[0]);

    var update_tags: std.ArrayList(std.meta.Tag(ai.StreamEvent)) = .empty;
    defer update_tags.deinit(allocator);
    var saw_empty_assistant_start = false;
    var saw_final_tool_use_end = false;

    for (result.events) |event| switch (event) {
        .message_start => |payload| if (payload.message == .assistant and payload.message.assistant.stop_reason == .tool_use) {
            saw_empty_assistant_start = payload.message.assistant.content.len == 0;
        },
        .message_update => |payload| {
            try update_tags.append(allocator, std.meta.activeTag(payload.assistant_message_event));
            const assistant = payload.message.assistant;
            switch (payload.assistant_message_event) {
                .thinking_delta => |delta| {
                    try std.testing.expect(assistant.content[0] == .thinking);
                    const expected = if (std.mem.eql(u8, delta.delta, "pl")) "pl" else "plan";
                    try std.testing.expectEqualStrings(expected, assistant.content[0].thinking.thinking);
                },
                .thinking_end => {
                    try std.testing.expect(assistant.content[0] == .thinking);
                    try std.testing.expectEqualStrings("plan", assistant.content[0].thinking.thinking);
                },
                .text_delta => |delta| {
                    try std.testing.expect(assistant.content[1] == .text);
                    const expected = if (std.mem.eql(u8, delta.delta, "ans")) "ans" else "answer";
                    try std.testing.expectEqualStrings(expected, assistant.content[1].text.text);
                },
                .text_end => {
                    try std.testing.expect(assistant.content[1] == .text);
                    try std.testing.expectEqualStrings("answer", assistant.content[1].text.text);
                },
                .toolcall_delta => |delta| {
                    try std.testing.expect(assistant.content[2] == .tool_call);
                    const expected = if (std.mem.eql(u8, delta.delta, "{\"value\":\""))
                        "{\"value\":\""
                    else
                        "{\"value\":\"hello\"}";
                    try std.testing.expectEqualStrings(expected, assistant.content[2].tool_call.arguments_json);
                },
                .toolcall_end => {
                    try std.testing.expect(assistant.content[2] == .tool_call);
                    try std.testing.expectEqualStrings("tool-1", assistant.content[2].tool_call.id);
                    try std.testing.expectEqualStrings("echo", assistant.content[2].tool_call.name);
                    try std.testing.expectEqualStrings("{\"value\":\"hello\"}", assistant.content[2].tool_call.arguments_json);
                },
                else => {},
            }
        },
        .message_end => |payload| if (payload.message == .assistant and payload.message.assistant.stop_reason == .tool_use) {
            const assistant = payload.message.assistant;
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expectEqualStrings("plan", assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("answer", assistant.content[1].text.text);
            try std.testing.expectEqualStrings("{\"value\":\"hello\"}", assistant.content[2].tool_call.arguments_json);
            saw_final_tool_use_end = true;
        },
        else => {},
    };

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
    try std.testing.expectEqualSlices(std.meta.Tag(ai.StreamEvent), &expected_tags, update_tags.items[0..expected_tags.len]);
    try std.testing.expect(saw_empty_assistant_start);
    try std.testing.expect(saw_final_tool_use_end);
}

// Ported from packages/agent/test/agent-loop.test.ts stop-after-turn semantics.
test "agent loop stops after current turn before follow-up polling" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo something" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: ToolStreamState = .{};
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    var stop_state: StopState = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = toolThenTextStream },
        .get_steering_messages = .{ .ptr = &stop_state, .call_fn = countSteeringPolls },
        .get_follow_up_messages = .{ .ptr = &stop_state, .call_fn = forbiddenFollowUps },
        .should_stop_after_turn = .{ .ptr = &stop_state, .call_fn = stopAfterTurn },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), stream_state.call_count);
    try std.testing.expectEqual(@as(usize, 1), tool_state.executed.items.len);
    try std.testing.expectEqual(@as(usize, 1), stop_state.steering_polls);
    try std.testing.expectEqual(@as(usize, 0), stop_state.follow_up_polls);
    try std.testing.expectEqual(@as(usize, 1), stop_state.callback_tool_results);
    try std.testing.expectEqual(@as(usize, 3), result.messages.len);
}

// Ported from packages/agent/test/agent-loop.test.ts all-terminate batch behavior.
test "agent loop stops after tool batch when every tool result terminates" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo something" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: ToolStreamState = .{};
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .ptr = &tool_state, .call_fn = terminatingEchoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = toolThenTextStream },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), stream_state.call_count);
    try std.testing.expectEqual(@as(usize, 3), result.messages.len);
    try std.testing.expect(result.messages[2] == .tool_result);
}

// Ported from packages/agent/test/agent-loop.test.ts continuation guards and result scope.
test "agent loop continue rejects invalid context and returns only new messages" {
    const allocator = std.testing.allocator;
    const user_content = [_]ai.UserContent{.{ .text = .{ .text = "Hello" } }};
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "prior" } }};
    const user = userMessage(&user_content);
    const assistant_message: AgentMessage = .{ .assistant = .{
        .content = &assistant_content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "mock",
    } };
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .call_fn = textStream },
    };

    try std.testing.expectError(
        error.CannotContinueNoMessages,
        runAgentLoopContinueAlloc(allocator, .{ .messages = &.{} }, config, null),
    );
    try std.testing.expectError(
        error.CannotContinueFromAssistant,
        runAgentLoopContinueAlloc(allocator, .{ .messages = &.{assistant_message} }, config, null),
    );

    var result = try runAgentLoopContinueAlloc(allocator, .{ .messages = &.{user} }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.messages.len);
    try std.testing.expect(result.messages[0] == .assistant);
    var message_end_count: usize = 0;
    for (result.events) |event| {
        if (event == .message_end) message_end_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), message_end_count);
}

// Ported from packages/agent/test/agent-loop.test.ts custom last-message continue behavior.
test "agent loop continue accepts custom last message converted for llm" {
    const allocator = std.testing.allocator;
    const custom_message: AgentMessage = .{ .custom = .{
        .custom_type = "custom",
        .content = .{ .text = "Hook content" },
        .display = true,
        .timestamp_ms = 1,
    } };

    var state: ContinueCustomState = .{};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &state, .call_fn = captureCustomContinueStream },
    };

    var result = try runAgentLoopContinueAlloc(allocator, .{ .messages = &.{custom_message} }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), state.call_count);
    try std.testing.expect(state.saw_custom_as_user);
    try std.testing.expectEqual(@as(usize, 1), result.messages.len);
    try std.testing.expect(result.messages[0] == .assistant);
}

// Ported from packages/agent/test/agent-loop.test.ts prepareNextTurn snapshot behavior.
test "agent loop uses prepare next turn snapshot before continuing" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "start" } }};
    const prompt = userMessage(&prompt_content);
    var prepare_state: PrepareState = .{};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &prepare_state, .call_fn = captureSecondSystemPromptStream },
        .prepare_next_turn = .{ .ptr = &prepare_state, .call_fn = prepareSecondPrompt },
    };
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    var result = try runAgentLoopAlloc(
        allocator,
        &.{prompt},
        .{ .system_prompt = "first prompt", .tools = &tools },
        config,
        null,
    );
    defer result.deinit();

    try std.testing.expect(prepare_state.prepared);
    try std.testing.expectEqualStrings("second prompt", prepare_state.second_system_prompt.?);
}

const NotificationFilterState = struct {
    converted_len: usize = 0,
};

fn filterNotificationsConvert(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    source: []const AgentMessage,
    _: ?*ai.AbortSignal,
) ![]ai.Message {
    const state: *NotificationFilterState = @ptrCast(@alignCast(ptr.?));
    var filtered: std.ArrayList(AgentMessage) = .empty;
    defer filtered.deinit(allocator);
    for (source) |message| {
        if (message == .custom and std.mem.eql(u8, message.custom.custom_type, "notification")) continue;
        try filtered.append(allocator, message);
    }
    state.converted_len = filtered.items.len;
    const converted = try agent_messages.convertToLlmAlloc(allocator, filtered.items);
    return converted.messages;
}

fn rewriteEchoArguments(
    _: ?*anyopaque,
    _: BeforeToolCallContext,
    _: ?*ai.AbortSignal,
) !BeforeToolCallResult {
    return .{ .arguments_json = "{\"value\":\"rewritten\"}" };
}

const ValidationHookState = struct {
    arguments_json: ?[]const u8 = null,
};

fn captureValidatedNumberThenRewrite(
    ptr: ?*anyopaque,
    context: BeforeToolCallContext,
    _: ?*ai.AbortSignal,
) !BeforeToolCallResult {
    const state: *ValidationHookState = @ptrCast(@alignCast(ptr.?));
    state.arguments_json = context.arguments_json;
    return .{ .arguments_json = "{\"value\":\"not-a-number\"}" };
}

const CaptureArgumentsState = struct {
    arguments_json: ?[]const u8 = null,
};

fn captureArgumentsToolExecute(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    arguments_json: []const u8,
    _: ?*ai.AbortSignal,
    _: ToolUpdateCallback,
) !AgentToolResult {
    const state: *CaptureArgumentsState = @ptrCast(@alignCast(ptr.?));
    state.arguments_json = try allocator.dupe(u8, arguments_json);
    return .{};
}

fn prepareEditArguments(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    arguments_json: []const u8,
) ![]const u8 {
    if (std.mem.indexOf(u8, arguments_json, "\"edits\"") != null) {
        return try allocator.dupe(u8, arguments_json);
    }

    const old_text = extractJsonStringValue(arguments_json, "oldText") orelse return try allocator.dupe(u8, arguments_json);
    const new_text = extractJsonStringValue(arguments_json, "newText") orelse return try allocator.dupe(u8, arguments_json);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"edits\":[{{\"oldText\":\"{s}\",\"newText\":\"{s}\"}}]}}",
        .{ old_text, new_text },
    );
}

const ParallelOrderState = struct {
    first_started: std.atomic.Value(bool) = .init(false),
    first_finished: std.atomic.Value(bool) = .init(false),
    second_started: std.atomic.Value(bool) = .init(false),
    release_first: std.atomic.Value(bool) = .init(false),
    parallel_observed: std.atomic.Value(bool) = .init(false),
};

fn parallelOrderToolExecute(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    arguments_json: []const u8,
    _: ?*ai.AbortSignal,
    _: ToolUpdateCallback,
) !AgentToolResult {
    const state: *ParallelOrderState = @ptrCast(@alignCast(ptr.?));
    const value = extractJsonStringValue(arguments_json, "value") orelse arguments_json;
    const is_first = std.mem.eql(u8, value, "first") or std.mem.eql(u8, value, "a");

    if (is_first) {
        state.first_started.store(true, .seq_cst);
        while (!state.release_first.load(.seq_cst)) {
            std.Thread.yield() catch {};
        }
        state.first_finished.store(true, .seq_cst);
    } else {
        state.second_started.store(true, .seq_cst);
        if (!state.first_finished.load(.seq_cst)) {
            state.parallel_observed.store(true, .seq_cst);
        }
    }

    const content = try allocator.alloc(ai.UserContent, 1);
    content[0] = .{ .text = .{ .text = try std.fmt.allocPrint(allocator, "parallel: {s}", .{value}) } };
    return .{
        .content = content,
        .details_json = try std.fmt.allocPrint(allocator, "{{\"value\":\"{s}\"}}", .{value}),
    };
}

fn conditionalTerminateToolExecute(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    arguments_json: []const u8,
    _: ?*ai.AbortSignal,
    _: ToolUpdateCallback,
) !AgentToolResult {
    _ = ptr;
    const value = extractJsonStringValue(arguments_json, "value") orelse arguments_json;
    const content = try allocator.alloc(ai.UserContent, 1);
    content[0] = .{ .text = .{ .text = try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}) } };
    return .{
        .content = content,
        .details_json = try std.fmt.allocPrint(allocator, "{{\"value\":\"{s}\"}}", .{value}),
        .terminate = std.mem.eql(u8, value, "first") or std.mem.eql(u8, value, "a"),
    };
}

fn terminateAfterToolCall(
    _: ?*anyopaque,
    _: AfterToolCallContext,
    _: ?*ai.AbortSignal,
) anyerror!?AfterToolCallResult {
    return .{ .terminate = true };
}

const ParallelLoopRunState = struct {
    result: ?AgentLoopResult = null,
    error_name: ?[]const u8 = null,
};

const ParallelLoopRunContext = struct {
    allocator: std.mem.Allocator,
    prompts: []const AgentMessage,
    context: AgentContext,
    config: AgentLoopConfig,
    signal: ?*ai.AbortSignal = null,
    state: *ParallelLoopRunState,
};

fn runAgentLoopThread(ctx: *ParallelLoopRunContext) void {
    ctx.state.result = runAgentLoopAlloc(
        ctx.allocator,
        ctx.prompts,
        ctx.context,
        ctx.config,
        ctx.signal,
    ) catch |err| {
        ctx.state.error_name = @errorName(err);
        return;
    };
}

const AssistantToolCallSpec = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

fn assistantToolBatchAlloc(
    allocator: std.mem.Allocator,
    model: ai.Model,
    tool_calls: []const AssistantToolCallSpec,
) !ai.AssistantMessage {
    const content = try allocator.alloc(ai.AssistantContent, tool_calls.len);
    for (tool_calls, 0..) |tool_call, index| {
        content[index] = .{ .tool_call = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments_json = try allocator.dupe(u8, tool_call.arguments_json),
        } };
    }
    return .{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .stop_reason = .tool_use,
        .timestamp_ms = 2,
    };
}

const MultiToolStreamState = struct {
    call_count: usize = 0,
    saw_interrupt_in_second_context: bool = false,
};

fn echoTwoToolCallStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    context: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const state: *MultiToolStreamState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count == 0) {
        return try doneStreamResult(allocator, try assistantToolBatchAlloc(allocator, model, &.{
            .{ .id = "tool-1", .name = "echo", .arguments_json = "{\"value\":\"first\"}" },
            .{ .id = "tool-2", .name = "echo", .arguments_json = "{\"value\":\"second\"}" },
        }));
    }
    for (context.messages) |message| {
        if (message == .user and message.user.content.len > 0 and message.user.content[0] == .text and
            std.mem.eql(u8, message.user.content[0].text.text, "interrupt"))
        {
            state.saw_interrupt_in_second_context = true;
        }
    }
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
}

fn slowFastToolCallStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    _: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const state: *MultiToolStreamState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count == 0) {
        return try doneStreamResult(allocator, try assistantToolBatchAlloc(allocator, model, &.{
            .{ .id = "tool-1", .name = "slow", .arguments_json = "{\"value\":\"a\"}" },
            .{ .id = "tool-2", .name = "fast", .arguments_json = "{\"value\":\"b\"}" },
        }));
    }
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
}

fn editToolCallStream(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    model: ai.Model,
    _: ai.Context,
    _: ai.StreamOptions,
) !ai.StreamResult {
    const state: *MultiToolStreamState = @ptrCast(@alignCast(ptr.?));
    defer state.call_count += 1;
    if (state.call_count == 0) {
        return try doneStreamResult(
            allocator,
            try assistantToolAlloc(allocator, model, "tool-1", "edit", "{\"oldText\":\"before\",\"newText\":\"after\"}"),
        );
    }
    return try doneStreamResult(allocator, try assistantTextAlloc(allocator, model, "done", .stop));
}

test "agent loop converts custom messages after filtering notifications" {
    const allocator = std.testing.allocator;
    const notification = AgentMessage{
        .custom = .{
            .custom_type = "notification",
            .content = .{ .text = "ignore me" },
            .display = false,
            .details_json = null,
            .timestamp_ms = 1,
        },
    };
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "Hello" } }};
    const prompt = userMessage(&prompt_content);

    var state: NotificationFilterState = .{};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .call_fn = textStream },
        .convert_to_llm = .{ .ptr = &state, .call_fn = filterNotificationsConvert },
    };

    var result = try runAgentLoopAlloc(
        allocator,
        &.{prompt},
        .{ .messages = &.{notification} },
        config,
        null,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), state.converted_len);
}

test "agent loop rewrites beforeToolCall arguments_json" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo something" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: ToolStreamState = .{};
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = toolThenTextStream },
        .before_tool_call = .{ .call_fn = rewriteEchoArguments },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), tool_state.executed.items.len);
    try std.testing.expectEqualStrings("rewritten", tool_state.executed.items[0]);
}

test "agent loop prepares tool arguments before execution" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "edit something" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: MultiToolStreamState = .{};
    var capture_state: CaptureArgumentsState = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "edit",
        .prepare_arguments = .{ .call_fn = prepareEditArguments },
        .execute = .{ .ptr = &capture_state, .call_fn = captureArgumentsToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = editToolCallStream },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expect(capture_state.arguments_json != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_state.arguments_json.?, "\"edits\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_state.arguments_json.?, "\"oldText\":\"before\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture_state.arguments_json.?, "\"newText\":\"after\"") != null);
}

test "agent loop validates tool arguments before beforeToolCall without revalidating hook rewrites" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo something" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: ToolStreamState = .{};
    var hook_state: ValidationHookState = .{};
    var capture_state: CaptureArgumentsState = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"number\"}},\"required\":[\"value\"]}",
        .execute = .{ .ptr = &capture_state, .call_fn = captureArgumentsToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = numberStringToolThenTextStream },
        .before_tool_call = .{ .ptr = &hook_state, .call_fn = captureValidatedNumberThenRewrite },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expect(hook_state.arguments_json != null);
    try std.testing.expectEqualStrings("{\"value\":42}", hook_state.arguments_json.?);
    try std.testing.expect(capture_state.arguments_json != null);
    try std.testing.expectEqualStrings("{\"value\":\"not-a-number\"}", capture_state.arguments_json.?);
    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
    try std.testing.expect(result.messages[2] == .tool_result);
    try std.testing.expect(!result.messages[2].tool_result.is_error);
}

test "agent loop emits an error tool result when validated arguments fail schema" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo something" } }};
    const prompt = userMessage(&prompt_content);

    var stream_state: ToolStreamState = .{};
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"boolean\"}},\"required\":[\"value\"]}",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = invalidBooleanToolThenTextStream },
    };

    var result = try runAgentLoopAlloc(allocator, &.{prompt}, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), tool_state.executed.items.len);
    try std.testing.expectEqual(@as(usize, 2), stream_state.call_count);
    try std.testing.expectEqual(@as(usize, 4), result.messages.len);
    try std.testing.expect(result.messages[2] == .tool_result);
    const tool_result = result.messages[2].tool_result;
    try std.testing.expect(tool_result.is_error);
    try std.testing.expectEqual(@as(usize, 1), tool_result.content.len);
    try std.testing.expect(tool_result.content[0] == .text);
    try std.testing.expect(std.mem.indexOf(u8, tool_result.content[0].text.text, "ValidationFailed") != null);
}

test "agent loop emits tool_execution_end in completion order while keeping tool results in source order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo both" } }};
    const prompt = userMessage(&prompt_content);
    const prompts = [_]AgentMessage{prompt};

    var state: ParallelOrderState = .{};
    var stream_state: MultiToolStreamState = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execution_mode = .parallel,
        .execute = .{ .ptr = &state, .call_fn = parallelOrderToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = echoTwoToolCallStream },
    };

    var run_state: ParallelLoopRunState = .{};
    var run_ctx: ParallelLoopRunContext = .{
        .allocator = allocator,
        .prompts = &prompts,
        .context = .{ .tools = &tools },
        .config = config,
        .state = &run_state,
    };
    const loop_thread = try std.Thread.spawn(.{}, runAgentLoopThread, .{&run_ctx});

    while (!state.first_started.load(.seq_cst)) {
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    state.release_first.store(true, .seq_cst);

    loop_thread.join();
    try std.testing.expect(run_state.error_name == null);
    var stream = run_state.result orelse return error.MissingStreamFunction;
    defer stream.deinit();

    try std.testing.expect(state.parallel_observed.load(.seq_cst));

    var end_ids: std.ArrayList([]const u8) = .empty;
    defer end_ids.deinit(allocator);
    var result_ids: std.ArrayList([]const u8) = .empty;
    defer result_ids.deinit(allocator);
    for (stream.events) |event| switch (event) {
        .tool_execution_end => |payload| try end_ids.append(allocator, payload.tool_call_id),
        .message_end => |payload| if (payload.message == .tool_result) try result_ids.append(allocator, payload.message.tool_result.tool_call_id),
        else => {},
    };

    try std.testing.expectEqualStrings("tool-2", end_ids.items[0]);
    try std.testing.expectEqualStrings("tool-1", end_ids.items[1]);
    try std.testing.expectEqualStrings("tool-1", result_ids.items[0]);
    try std.testing.expectEqualStrings("tool-2", result_ids.items[1]);
}

test "agent loop injects queued steering only after a tool batch completes" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "start" } }};
    const prompt = userMessage(&prompt_content);
    const prompts = [_]AgentMessage{prompt};

    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    var queue_state: BatchQueueState = .{ .tool_state = &tool_state };
    var stream_state: MultiToolStreamState = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = echoTwoToolCallStream },
        .get_steering_messages = .{ .ptr = &queue_state, .call_fn = queuedAfterToolStarts },
        .tool_execution = .sequential,
    };

    var result = try runAgentLoopAlloc(allocator, &prompts, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), tool_state.executed.items.len);
    try std.testing.expectEqualStrings("first", tool_state.executed.items[0]);
    try std.testing.expectEqualStrings("second", tool_state.executed.items[1]);
    try std.testing.expect(queue_state.queued_delivered);
    try std.testing.expect(queue_state.polls >= 2);
    try std.testing.expect(stream_state.saw_interrupt_in_second_context);
    try std.testing.expectEqual(@as(usize, 6), result.messages.len);

    const missing = std.math.maxInt(usize);
    var tool_1_index: usize = missing;
    var tool_2_index: usize = missing;
    var interrupt_index: usize = missing;
    for (result.events, 0..) |event, index| {
        if (event != .message_start) continue;
        switch (event.message_start.message) {
            .tool_result => |tool_result| {
                if (std.mem.eql(u8, tool_result.tool_call_id, "tool-1")) tool_1_index = index;
                if (std.mem.eql(u8, tool_result.tool_call_id, "tool-2")) tool_2_index = index;
            },
            .user => |user| {
                if (user.content.len > 0 and user.content[0] == .text and
                    std.mem.eql(u8, user.content[0].text.text, "interrupt"))
                {
                    interrupt_index = index;
                }
            },
            else => {},
        }
    }

    try std.testing.expect(tool_1_index != missing);
    try std.testing.expect(tool_2_index != missing);
    try std.testing.expect(interrupt_index != missing);
    try std.testing.expect(tool_1_index < interrupt_index);
    try std.testing.expect(tool_2_index < interrupt_index);
}

test "agent loop forces sequential execution when a tool is marked sequential" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo both" } }};
    const prompt = userMessage(&prompt_content);
    const prompts = [_]AgentMessage{prompt};

    var state: ParallelOrderState = .{};
    var stream_state: MultiToolStreamState = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execution_mode = .sequential,
        .execute = .{ .ptr = &state, .call_fn = parallelOrderToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = echoTwoToolCallStream },
    };

    var run_state: ParallelLoopRunState = .{};
    var run_ctx: ParallelLoopRunContext = .{
        .allocator = allocator,
        .prompts = &prompts,
        .context = .{ .tools = &tools },
        .config = config,
        .state = &run_state,
    };
    const loop_thread = try std.Thread.spawn(.{}, runAgentLoopThread, .{&run_ctx});

    while (!state.first_started.load(.seq_cst)) {
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    state.release_first.store(true, .seq_cst);

    loop_thread.join();
    try std.testing.expect(run_state.error_name == null);
    var run_result = run_state.result orelse return error.MissingStreamFunction;
    defer run_result.deinit();

    try std.testing.expect(!state.parallel_observed.load(.seq_cst));
}

test "agent loop forces sequential execution when one of multiple tools is sequential" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "run both" } }};
    const prompt = userMessage(&prompt_content);
    const prompts = [_]AgentMessage{prompt};

    var state: ParallelOrderState = .{};
    var stream_state: MultiToolStreamState = .{};
    const tools = [_]AgentLoopTool{
        .{
            .name = "slow",
            .execution_mode = .sequential,
            .execute = .{ .ptr = &state, .call_fn = parallelOrderToolExecute },
        },
        .{
            .name = "fast",
            .execute = .{ .ptr = &state, .call_fn = parallelOrderToolExecute },
        },
    };
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = slowFastToolCallStream },
    };

    var run_state: ParallelLoopRunState = .{};
    var run_ctx: ParallelLoopRunContext = .{
        .allocator = allocator,
        .prompts = &prompts,
        .context = .{ .tools = &tools },
        .config = config,
        .state = &run_state,
    };
    const loop_thread = try std.Thread.spawn(.{}, runAgentLoopThread, .{&run_ctx});

    while (!state.first_started.load(.seq_cst)) {
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    state.release_first.store(true, .seq_cst);

    loop_thread.join();
    try std.testing.expect(run_state.error_name == null);
    var run_result = run_state.result orelse return error.MissingStreamFunction;
    defer run_result.deinit();

    try std.testing.expect(!state.parallel_observed.load(.seq_cst));
}

test "agent loop allows parallel execution when all tools are parallel" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo both" } }};
    const prompt = userMessage(&prompt_content);
    const prompts = [_]AgentMessage{prompt};

    var state: ParallelOrderState = .{};
    var stream_state: MultiToolStreamState = .{};
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execution_mode = .parallel,
        .execute = .{ .ptr = &state, .call_fn = parallelOrderToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = echoTwoToolCallStream },
    };

    var run_state: ParallelLoopRunState = .{};
    var run_ctx: ParallelLoopRunContext = .{
        .allocator = allocator,
        .prompts = &prompts,
        .context = .{ .tools = &tools },
        .config = config,
        .state = &run_state,
    };
    const loop_thread = try std.Thread.spawn(.{}, runAgentLoopThread, .{&run_ctx});

    while (!state.first_started.load(.seq_cst)) {
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    state.release_first.store(true, .seq_cst);

    loop_thread.join();
    try std.testing.expect(run_state.error_name == null);
    var run_result = run_state.result orelse return error.MissingStreamFunction;
    defer run_result.deinit();

    try std.testing.expect(state.parallel_observed.load(.seq_cst));
}

test "agent loop continues after parallel tool calls when not all terminate" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo both" } }};
    const prompt = userMessage(&prompt_content);
    const prompts = [_]AgentMessage{prompt};

    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .call_fn = conditionalTerminateToolExecute },
    }};
    var stream_state: MultiToolStreamState = .{};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = echoTwoToolCallStream },
    };

    var result = try runAgentLoopAlloc(allocator, &prompts, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.messages.len);
    try std.testing.expect(result.messages[0] == .user);
    try std.testing.expect(result.messages[1] == .assistant);
    try std.testing.expect(result.messages[2] == .tool_result);
    try std.testing.expect(result.messages[3] == .tool_result);
    try std.testing.expect(result.messages[4] == .assistant);
}

test "agent loop lets afterToolCall mark a tool batch terminating" {
    const allocator = std.testing.allocator;
    const prompt_content = [_]ai.UserContent{.{ .text = .{ .text = "echo something" } }};
    const prompt = userMessage(&prompt_content);
    const prompts = [_]AgentMessage{prompt};

    var stream_state: ToolStreamState = .{};
    var tool_state: EchoToolState = .{};
    defer tool_state.executed.deinit(std.testing.allocator);
    const tools = [_]AgentLoopTool{.{
        .name = "echo",
        .execute = .{ .ptr = &tool_state, .call_fn = echoToolExecute },
    }};
    const config: AgentLoopConfig = .{
        .model = createModel(),
        .stream = .{ .ptr = &stream_state, .call_fn = toolThenTextStream },
        .after_tool_call = .{ .call_fn = terminateAfterToolCall },
    };

    var result = try runAgentLoopAlloc(allocator, &prompts, .{ .tools = &tools }, config, null);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.messages.len);
    try std.testing.expectEqual(@as(usize, 1), stream_state.call_count);
    try std.testing.expect(result.messages[0] == .user);
    try std.testing.expect(result.messages[1] == .assistant);
    try std.testing.expect(result.messages[2] == .tool_result);
}
