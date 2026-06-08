const std = @import("std");

const ai = @import("bulb_ai");
const auth_storage = @import("auth_storage.zig");
const compaction_mod = @import("compaction.zig");
const config_value = @import("resolve_config_value.zig");
const extensions = @import("extensions/root.zig");
const messages = @import("messages.zig");
const model_registry = @import("model_registry.zig");
const session_manager = @import("session_manager.zig");
const settings_manager = @import("settings_manager.zig");
const source_info = @import("source_info.zig");
const tools = @import("tools/root.zig");

pub const AgentEndSessionEvent = struct {
    messages: []messages.CodingAgentMessage,
    will_retry: bool,
};

pub const AutoRetryStartSessionEvent = struct {
    attempt: usize,
    max_attempts: usize,
    delay_ms: u64,
    error_message: []const u8,
};

pub const AutoRetryEndSessionEvent = struct {
    success: bool,
    attempt: usize,
    final_error: ?[]const u8 = null,
};

pub const QueueUpdateSessionEvent = struct {
    steering: []const []const u8,
    follow_up: []const []const u8,
};

pub const CompactionReason = enum {
    manual,
    threshold,
    overflow,
};

pub const CompactionSessionResult = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    details_json: ?[]const u8 = null,
};

pub const CompactionStartSessionEvent = struct {
    reason: CompactionReason,
};

pub const CompactionEndSessionEvent = struct {
    reason: CompactionReason,
    result: ?CompactionSessionResult = null,
    aborted: bool,
    will_retry: bool,
    error_message: ?[]const u8 = null,
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
    auto_retry_start: AutoRetryStartSessionEvent,
    auto_retry_end: AutoRetryEndSessionEvent,
    queue_update: QueueUpdateSessionEvent,
    compaction_start: CompactionStartSessionEvent,
    compaction_end: CompactionEndSessionEvent,
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

pub const SessionSubscription = struct {
    id: usize,
};

const RegisteredSessionEventListener = struct {
    id: usize,
    active: bool = true,
    listener: SessionEventListener,
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
    event_listeners: std.ArrayList(RegisteredSessionEventListener) = .empty,
    message_end_listeners: std.ArrayList(MessageEndListener) = .empty,
    next_listener_id: usize = 1,
    public_emit_depth: usize = 0,

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
        _ = try self.subscribeWithHandle(listener);
    }

    pub fn subscribeWithHandle(
        self: *SessionEventBridge,
        listener: SessionEventListener,
    ) !SessionSubscription {
        const subscription = SessionSubscription{ .id = self.next_listener_id };
        self.next_listener_id += 1;
        try self.event_listeners.append(self.allocator, .{
            .id = subscription.id,
            .listener = listener,
        });
        return subscription;
    }

    pub fn unsubscribe(self: *SessionEventBridge, subscription: SessionSubscription) bool {
        for (self.event_listeners.items) |*registered| {
            if (registered.id == subscription.id and registered.active) {
                registered.active = false;
                if (self.public_emit_depth == 0) self.compactInactiveEventListeners();
                return true;
            }
        }
        return false;
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

    pub fn handleAutoRetryStart(self: *SessionEventBridge, event: AutoRetryStartSessionEvent) void {
        self.emitPublic(.{ .auto_retry_start = event });
    }

    pub fn handleAutoRetryEnd(self: *SessionEventBridge, event: AutoRetryEndSessionEvent) void {
        self.emitPublic(.{ .auto_retry_end = event });
    }

    pub fn handleQueueUpdate(
        self: *SessionEventBridge,
        steering: []const []const u8,
        follow_up: []const []const u8,
    ) void {
        self.emitPublic(.{ .queue_update = .{
            .steering = steering,
            .follow_up = follow_up,
        } });
    }

    pub fn handleCompactionStart(self: *SessionEventBridge, reason: CompactionReason) void {
        self.emitPublic(.{ .compaction_start = .{ .reason = reason } });
    }

    pub fn handleCompactionEnd(self: *SessionEventBridge, event: CompactionEndSessionEvent) void {
        self.emitPublic(.{ .compaction_end = event });
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
        self.public_emit_depth += 1;
        const initial_len = self.event_listeners.items.len;
        var index: usize = 0;
        while (index < initial_len and index < self.event_listeners.items.len) : (index += 1) {
            const registered = self.event_listeners.items[index];
            if (registered.active) registered.listener.call(event);
        }
        self.public_emit_depth -= 1;
        if (self.public_emit_depth == 0) self.compactInactiveEventListeners();

        switch (event) {
            .message_end => |payload| {
                for (self.message_end_listeners.items) |listener| listener.call(payload.message);
            },
            else => {},
        }
    }

    fn compactInactiveEventListeners(self: *SessionEventBridge) void {
        var index: usize = 0;
        while (index < self.event_listeners.items.len) {
            if (!self.event_listeners.items[index].active) {
                _ = self.event_listeners.orderedRemove(index);
                continue;
            }
            index += 1;
        }
    }
};

pub const AutoRetryController = struct {
    settings: settings_manager.RetrySettings = .{},
    context_window: ?u64 = null,
    retry_attempt: usize = 0,
    retrying: bool = false,

    pub fn init(settings: settings_manager.RetrySettings, context_window: ?u64) AutoRetryController {
        return .{
            .settings = settings,
            .context_window = context_window,
        };
    }

    pub fn isRetrying(self: *const AutoRetryController) bool {
        return self.retrying;
    }

    pub fn willRetryAfterAgentEnd(
        self: *const AutoRetryController,
        agent_messages: []const messages.CodingAgentMessage,
    ) bool {
        if (!self.settings.enabled or self.retry_attempt >= self.settings.max_retries) return false;
        var index = agent_messages.len;
        while (index > 0) {
            index -= 1;
            switch (agent_messages[index]) {
                .assistant => |assistant| return isRetryableError(assistant, self.context_window),
                else => {},
            }
        }
        return false;
    }

    pub fn prepareRetry(
        self: *AutoRetryController,
        bridge: *SessionEventBridge,
        message: ai.AssistantMessage,
    ) ?AutoRetryStartSessionEvent {
        if (!self.settings.enabled) return null;
        if (!isRetryableError(message, self.context_window)) return null;

        self.retry_attempt += 1;
        if (self.retry_attempt > self.settings.max_retries) {
            self.retry_attempt -= 1;
            return null;
        }

        const event = AutoRetryStartSessionEvent{
            .attempt = self.retry_attempt,
            .max_attempts = self.settings.max_retries,
            .delay_ms = retryDelayMs(self.settings.base_delay_ms, self.retry_attempt),
            .error_message = message.error_message orelse "Unknown error",
        };
        self.retrying = true;
        bridge.handleAutoRetryStart(event);
        return event;
    }

    pub fn completeRetryDelay(self: *AutoRetryController) void {
        self.retrying = false;
    }

    pub fn completeRetrySuccess(
        self: *AutoRetryController,
        bridge: *SessionEventBridge,
    ) ?AutoRetryEndSessionEvent {
        if (self.retry_attempt == 0) return null;
        const event = AutoRetryEndSessionEvent{
            .success = true,
            .attempt = self.retry_attempt,
        };
        self.retry_attempt = 0;
        self.retrying = false;
        bridge.handleAutoRetryEnd(event);
        return event;
    }

    pub fn completeRetryFailure(
        self: *AutoRetryController,
        bridge: *SessionEventBridge,
        final_error: ?[]const u8,
    ) ?AutoRetryEndSessionEvent {
        if (self.retry_attempt == 0) return null;
        const event = AutoRetryEndSessionEvent{
            .success = false,
            .attempt = self.retry_attempt,
            .final_error = final_error,
        };
        self.retry_attempt = 0;
        self.retrying = false;
        bridge.handleAutoRetryEnd(event);
        return event;
    }

    pub fn abortRetry(self: *AutoRetryController, bridge: *SessionEventBridge) ?AutoRetryEndSessionEvent {
        if (!self.retrying and self.retry_attempt == 0) return null;
        return self.completeRetryFailure(bridge, "Retry cancelled");
    }
};

pub const QueueMode = enum {
    one_at_a_time,
    all,
};

pub const CustomMessageDelivery = enum {
    steer,
    follow_up,
    next_turn,
};

const QueuedSessionMessage = struct {
    text: []const u8,
    message: messages.CodingAgentMessage,
};

pub const CompactionAuthMode = enum {
    require_api_key,
    optional,
};

pub const ResolvedCompactionRequestOptions = struct {
    options: compaction_mod.SummaryRequestOptions,
    owned_auth: ?model_registry.RequestAuth = null,

    pub fn deinit(self: *ResolvedCompactionRequestOptions, allocator: std.mem.Allocator) void {
        if (self.owned_auth) |*auth| auth.deinit(allocator);
        self.* = undefined;
    }
};

pub const CompactionRequestAuthResolver = struct {
    registry: *model_registry.ModelRegistry,
    mode: CompactionAuthMode = .require_api_key,

    pub fn resolveAlloc(
        self: CompactionRequestAuthResolver,
        allocator: std.mem.Allocator,
        model: ai.Model,
        base_options: compaction_mod.SummaryRequestOptions,
    ) !?ResolvedCompactionRequestOptions {
        const result = try self.registry.getApiKeyAndHeadersAlloc(allocator, &model);
        switch (result) {
            .failure => |message| {
                allocator.free(message);
                if (self.mode == .optional) {
                    return .{ .options = base_options };
                }
                return null;
            },
            .ok => |request_auth_value| {
                var request_auth = request_auth_value;
                if (self.mode == .require_api_key and request_auth.api_key == null) {
                    request_auth.deinit(allocator);
                    return null;
                }

                var options = base_options;
                options.api_key = request_auth.api_key;
                options.headers = request_auth.headers;
                return .{
                    .options = options,
                    .owned_auth = request_auth,
                };
            },
        }
    }
};

pub const AutoCompactionConfig = struct {
    model: ai.Model,
    executor: compaction_mod.SummaryExecutor,
    settings: compaction_mod.CompactionSettings = compaction_mod.default_compaction_settings,
    request_options: compaction_mod.SummaryRequestOptions = .{},
    auth_resolver: ?CompactionRequestAuthResolver = null,
};

pub const AgentSessionReplay = struct {
    allocator: std.mem.Allocator,
    bridge: *SessionEventBridge,
    runner: *extensions.ExtensionRunner,
    sessions: *session_manager.SessionManager,
    retry: AutoRetryController,
    agent_tools: []const tools.tool_registry.AgentTool = &.{},
    responses: []const ai.AssistantMessage = &.{},
    next_response: usize = 0,
    messages: std.ArrayList(messages.CodingAgentMessage) = .empty,
    owned_texts: std.ArrayList([]u8) = .empty,
    owned_content: std.ArrayList([]ai.UserContent) = .empty,
    owned_assistant_content: std.ArrayList([]ai.AssistantContent) = .empty,
    owned_diagnostics: std.ArrayList([]ai.AssistantMessageDiagnostic) = .empty,
    owned_details: std.ArrayList([]u8) = .empty,
    steering_messages: std.ArrayList(QueuedSessionMessage) = .empty,
    follow_up_messages: std.ArrayList(QueuedSessionMessage) = .empty,
    next_turn_messages: std.ArrayList(QueuedSessionMessage) = .empty,
    retry_sleeps: std.ArrayList(u64) = .empty,
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    is_streaming: bool = false,
    auto_compaction: ?AutoCompactionConfig = null,
    overflow_recovery_attempted: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        bridge: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        sessions: *session_manager.SessionManager,
        retry: AutoRetryController,
        agent_tools: []const tools.tool_registry.AgentTool,
    ) AgentSessionReplay {
        return .{
            .allocator = allocator,
            .bridge = bridge,
            .runner = runner,
            .sessions = sessions,
            .retry = retry,
            .agent_tools = agent_tools,
        };
    }

    pub fn deinit(self: *AgentSessionReplay) void {
        for (self.owned_texts.items) |text| self.allocator.free(text);
        self.owned_texts.deinit(self.allocator);
        for (self.owned_content.items) |content| self.allocator.free(content);
        self.owned_content.deinit(self.allocator);
        for (self.owned_assistant_content.items) |content| self.allocator.free(content);
        self.owned_assistant_content.deinit(self.allocator);
        for (self.owned_diagnostics.items) |diagnostics| self.allocator.free(diagnostics);
        self.owned_diagnostics.deinit(self.allocator);
        for (self.owned_details.items) |details| self.allocator.free(details);
        self.owned_details.deinit(self.allocator);
        self.steering_messages.deinit(self.allocator);
        self.follow_up_messages.deinit(self.allocator);
        self.next_turn_messages.deinit(self.allocator);
        self.retry_sleeps.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setResponses(self: *AgentSessionReplay, responses: []const ai.AssistantMessage) void {
        self.responses = responses;
        self.next_response = 0;
    }

    pub fn setAutoCompaction(self: *AgentSessionReplay, config: ?AutoCompactionConfig) void {
        self.auto_compaction = config;
    }

    pub fn pendingResponseCount(self: *const AgentSessionReplay) usize {
        return self.responses.len - self.next_response;
    }

    pub fn pendingMessageCount(self: *const AgentSessionReplay) usize {
        return self.steering_messages.items.len + self.follow_up_messages.items.len;
    }

    pub fn hasQueuedMessages(self: *const AgentSessionReplay) bool {
        return self.steering_messages.items.len > 0 or
            self.follow_up_messages.items.len > 0 or
            self.next_turn_messages.items.len > 0;
    }

    pub fn isRetrying(self: *const AgentSessionReplay) bool {
        return self.retry.isRetrying();
    }

    pub fn setSteeringMode(self: *AgentSessionReplay, mode: QueueMode) void {
        self.steering_mode = mode;
    }

    pub fn setFollowUpMode(self: *AgentSessionReplay, mode: QueueMode) void {
        self.follow_up_mode = mode;
    }

    pub fn abortRetry(self: *AgentSessionReplay) ?AutoRetryEndSessionEvent {
        return self.retry.abortRetry(self.bridge);
    }

    pub fn compactWithExtension(
        self: *AgentSessionReplay,
        io: std.Io,
        preparation: extensions.CompactionPreparation,
        custom_instructions: ?[]const u8,
        reason: CompactionReason,
        will_retry: bool,
        signal: *const ai.AbortSignal,
    ) !CompactionSessionResult {
        self.bridge.handleCompactionStart(reason);

        const branch_entries = try self.sessions.getBranchAlloc(self.allocator, null);
        defer self.allocator.free(branch_entries);

        var maybe_emit_result = try self.runner.emitSessionBeforeCompactAlloc(.{
            .preparation = preparation,
            .branch_entries = branch_entries,
            .custom_instructions = custom_instructions,
            .signal = signal,
        });
        defer if (maybe_emit_result) |*emit_result| emit_result.deinit();

        const cancelled_by_extension = if (maybe_emit_result) |*emit_result| emit_result.result.cancel else false;
        if (signal.isAborted() or cancelled_by_extension) {
            self.bridge.handleCompactionEnd(.{
                .reason = reason,
                .result = null,
                .aborted = true,
                .will_retry = false,
                .error_message = "Compaction cancelled",
            });
            return error.CompactionCancelled;
        }

        const emitted = if (maybe_emit_result) |*emit_result| emit_result else {
            self.bridge.handleCompactionEnd(.{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = will_retry,
                .error_message = "Extension did not provide compaction",
            });
            return error.CompactionNotProvided;
        };
        const compaction = emitted.result.compaction orelse {
            self.bridge.handleCompactionEnd(.{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = will_retry,
                .error_message = "Extension did not provide compaction",
            });
            return error.CompactionNotProvided;
        };

        const first_kept_entry_id = compaction.first_kept_entry_id orelse preparation.first_kept_entry_id orelse {
            self.bridge.handleCompactionEnd(.{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = will_retry,
                .error_message = "Extension compaction missing firstKeptEntryId",
            });
            return error.MissingFirstKeptEntryId;
        };
        const tokens_before = compaction.tokens_before orelse preparation.tokens_before orelse {
            self.bridge.handleCompactionEnd(.{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = will_retry,
                .error_message = "Extension compaction missing tokensBefore",
            });
            return error.MissingTokensBefore;
        };

        return try self.persistCompactionResult(
            io,
            .{
                .summary = compaction.summary,
                .first_kept_entry_id = first_kept_entry_id,
                .tokens_before = tokens_before,
                .details_json = compaction.details_json,
            },
            true,
            reason,
            will_retry,
        );
    }

    pub fn compactWithGeneratedSummary(
        self: *AgentSessionReplay,
        io: std.Io,
        preparation: *const compaction_mod.CompactionPreparation,
        model: ai.Model,
        request_options: compaction_mod.SummaryRequestOptions,
        executor: compaction_mod.SummaryExecutor,
        reason: CompactionReason,
        will_retry: bool,
    ) !CompactionSessionResult {
        self.bridge.handleCompactionStart(reason);
        errdefer |err| self.bridge.handleCompactionEnd(.{
            .reason = reason,
            .result = null,
            .aborted = err == error.CompactionCancelled,
            .will_retry = if (err == error.CompactionCancelled) false else will_retry,
            .error_message = compactionErrorMessage(err),
        });

        const signal = request_options.signal orelse &never_aborted_signal;
        const branch_entries = try self.sessions.getBranchAlloc(self.allocator, null);
        defer self.allocator.free(branch_entries);

        if (self.runner.hasHandlers(.session_before_compact)) {
            var maybe_emit_result = try self.runner.emitSessionBeforeCompactAlloc(.{
                .preparation = extensionPreparationFromCompaction(preparation),
                .branch_entries = branch_entries,
                .custom_instructions = request_options.custom_instructions,
                .signal = signal,
            });
            defer if (maybe_emit_result) |*emit_result| emit_result.deinit();

            const cancelled_by_extension = if (maybe_emit_result) |*emit_result| emit_result.result.cancel else false;
            if (signal.isAborted() or cancelled_by_extension) return error.CompactionCancelled;

            if (maybe_emit_result) |*emit_result| {
                if (emit_result.result.compaction) |extension_compaction| {
                    const first_kept_entry_id = extension_compaction.first_kept_entry_id orelse preparation.first_kept_entry_id;
                    const tokens_before = extension_compaction.tokens_before orelse preparation.tokens_before;
                    return try self.persistCompactionResult(
                        io,
                        .{
                            .summary = extension_compaction.summary,
                            .first_kept_entry_id = first_kept_entry_id,
                            .tokens_before = tokens_before,
                            .details_json = extension_compaction.details_json,
                        },
                        true,
                        reason,
                        will_retry,
                    );
                }
            }
        } else if (signal.isAborted()) {
            return error.CompactionCancelled;
        }

        var generated = try compaction_mod.compactAlloc(
            self.allocator,
            preparation,
            model,
            request_options,
            executor,
        );
        defer generated.deinit();

        if (signal.isAborted()) return error.CompactionCancelled;
        return try self.persistCompactionResult(
            io,
            .{
                .summary = generated.summary,
                .first_kept_entry_id = generated.first_kept_entry_id,
                .tokens_before = generated.tokens_before,
                .details_json = generated.details_json,
            },
            false,
            reason,
            will_retry,
        );
    }

    pub fn checkAutoCompaction(
        self: *AgentSessionReplay,
        io: std.Io,
        assistant_message: ai.AssistantMessage,
        skip_aborted_check: bool,
    ) !bool {
        const config = self.auto_compaction orelse return false;
        if (!config.settings.enabled) return false;
        if (skip_aborted_check and assistant_message.stop_reason == .aborted) return false;

        const branch_entries = try self.sessions.getBranchAlloc(self.allocator, null);
        defer self.allocator.free(branch_entries);
        const compaction_boundary_ms = try latestCompactionTimestampMsAlloc(self.allocator, branch_entries);
        if (compaction_boundary_ms) |boundary_ms| {
            if (assistant_message.timestamp_ms <= boundary_ms) return false;
        }

        const same_model = std.mem.eql(u8, assistant_message.provider, config.model.provider) and
            std.mem.eql(u8, assistant_message.model, config.model.id);
        if (same_model and ai.overflow.isContextOverflow(assistant_message, config.model.context_window)) {
            if (self.overflow_recovery_attempted) {
                self.bridge.handleCompactionEnd(.{
                    .reason = .overflow,
                    .result = null,
                    .aborted = false,
                    .will_retry = false,
                    .error_message = "Context overflow recovery failed after one compact-and-retry attempt. Try reducing context or switching to a larger-context model.",
                });
                return false;
            }

            self.overflow_recovery_attempted = true;
            self.removeTrailingAssistantError();
            return try self.runAutoCompaction(io, .overflow, true);
        }

        const context_tokens = if (assistant_message.stop_reason == .@"error") context_tokens: {
            const estimate = compaction_mod.estimateContextTokens(self.messages.items);
            const usage_index = estimate.last_usage_index orelse return false;
            if (compaction_boundary_ms) |boundary_ms| {
                const usage_message = self.messages.items[usage_index];
                if (usage_message == .assistant and usage_message.assistant.timestamp_ms <= boundary_ms) {
                    return false;
                }
            }
            break :context_tokens estimate.tokens;
        } else compaction_mod.calculateContextTokens(assistant_message.usage);

        if (compaction_mod.shouldCompact(context_tokens, config.model.context_window, config.settings)) {
            return try self.runAutoCompaction(io, .threshold, false);
        }
        return false;
    }

    pub fn runAutoCompaction(
        self: *AgentSessionReplay,
        io: std.Io,
        reason: CompactionReason,
        will_retry: bool,
    ) !bool {
        const config = self.auto_compaction orelse {
            self.bridge.handleCompactionStart(reason);
            self.bridge.handleCompactionEnd(.{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = false,
            });
            return false;
        };

        var resolved_request_options: ?ResolvedCompactionRequestOptions = null;
        defer {
            if (resolved_request_options) |*resolved| resolved.deinit(self.allocator);
        }
        var request_options = config.request_options;
        if (config.auth_resolver) |resolver| {
            resolved_request_options = try resolver.resolveAlloc(self.allocator, config.model, config.request_options);
            if (resolved_request_options) |resolved| {
                request_options = resolved.options;
            } else {
                self.bridge.handleCompactionStart(reason);
                self.bridge.handleCompactionEnd(.{
                    .reason = reason,
                    .result = null,
                    .aborted = false,
                    .will_retry = false,
                });
                return false;
            }
        }

        const branch_entries = try self.sessions.getBranchAlloc(self.allocator, null);
        defer self.allocator.free(branch_entries);
        var preparation = (try compaction_mod.prepareCompaction(self.allocator, branch_entries, config.settings)) orelse {
            self.bridge.handleCompactionStart(reason);
            self.bridge.handleCompactionEnd(.{
                .reason = reason,
                .result = null,
                .aborted = false,
                .will_retry = false,
            });
            return false;
        };
        defer preparation.deinit();

        _ = self.compactWithGeneratedSummary(
            io,
            &preparation,
            config.model,
            request_options,
            config.executor,
            reason,
            will_retry,
        ) catch return false;

        if (will_retry) {
            self.removeTrailingAssistantError();
            return true;
        }
        return self.hasQueuedMessages();
    }

    fn persistCompactionResult(
        self: *AgentSessionReplay,
        io: std.Io,
        result: CompactionSessionResult,
        from_extension: bool,
        reason: CompactionReason,
        will_retry: bool,
    ) !CompactionSessionResult {
        const retained_summary = try self.retainText(result.summary);
        const retained_first_kept_entry_id = try self.retainText(result.first_kept_entry_id);
        const retained_details_json = if (result.details_json) |details| try self.retainDetails(details) else null;
        const event_result = CompactionSessionResult{
            .summary = retained_summary,
            .first_kept_entry_id = retained_first_kept_entry_id,
            .tokens_before = result.tokens_before,
            .details_json = retained_details_json,
        };

        const entry_id = try self.sessions.appendCompactionJson(
            io,
            event_result.summary,
            event_result.first_kept_entry_id,
            event_result.tokens_before,
            event_result.details_json,
            from_extension,
        );
        const compaction_entry = self.sessions.getEntry(entry_id) orelse return error.MissingCompactionEntry;

        try self.refreshMessagesFromSessionContext();

        _ = try self.runner.emit(.{ .session = .{ .compact = .{
            .compaction_entry = compaction_entry,
            .from_extension = from_extension,
        } } });

        self.bridge.handleCompactionEnd(.{
            .reason = reason,
            .result = event_result,
            .aborted = false,
            .will_retry = will_retry,
        });
        return event_result;
    }

    pub fn steer(self: *AgentSessionReplay, text: []const u8, timestamp_ms: i64) !void {
        try self.throwIfQueuedExtensionCommand(text);
        try self.queueTextMessage(&self.steering_messages, text, timestamp_ms);
    }

    pub fn followUp(self: *AgentSessionReplay, text: []const u8, timestamp_ms: i64) !void {
        try self.throwIfQueuedExtensionCommand(text);
        try self.queueTextMessage(&self.follow_up_messages, text, timestamp_ms);
    }

    pub fn sendUserTextMessage(
        self: *AgentSessionReplay,
        io: std.Io,
        text: []const u8,
        timestamp_ms: i64,
        delivery: CustomMessageDelivery,
    ) !void {
        if (!self.is_streaming) {
            try self.promptRawUserText(io, text, timestamp_ms);
            return;
        }

        switch (delivery) {
            .steer => try self.queueTextMessage(&self.steering_messages, text, timestamp_ms),
            .follow_up => try self.queueTextMessage(&self.follow_up_messages, text, timestamp_ms),
            .next_turn => try self.queueTextMessage(&self.next_turn_messages, text, timestamp_ms),
        }
    }

    pub fn sendCustomTextMessage(
        self: *AgentSessionReplay,
        custom_type: []const u8,
        text: []const u8,
        display: bool,
        details_json: ?[]const u8,
        timestamp_ms: i64,
        delivery: CustomMessageDelivery,
    ) !void {
        const message = try self.customTextMessage(custom_type, text, display, details_json, timestamp_ms);
        const queued = QueuedSessionMessage{ .text = customMessageText(message), .message = message };
        switch (delivery) {
            .steer => {
                try self.steering_messages.append(self.allocator, queued);
                try self.emitQueueUpdate();
            },
            .follow_up => {
                try self.follow_up_messages.append(self.allocator, queued);
                try self.emitQueueUpdate();
            },
            .next_turn => try self.next_turn_messages.append(self.allocator, queued),
        }
    }

    pub fn clearQueue(self: *AgentSessionReplay) !void {
        self.steering_messages.clearRetainingCapacity();
        self.follow_up_messages.clearRetainingCapacity();
        try self.emitQueueUpdate();
    }

    pub fn prompt(self: *AgentSessionReplay, io: std.Io, text: []const u8, timestamp_ms: i64) !void {
        if (try self.tryExecuteExtensionCommand(text)) return;
        try self.promptRawUserText(io, text, timestamp_ms);
    }

    fn promptRawUserText(self: *AgentSessionReplay, io: std.Io, text: []const u8, timestamp_ms: i64) !void {
        if (self.is_streaming) return error.AgentAlreadyProcessing;
        self.is_streaming = true;
        defer self.is_streaming = false;

        try self.bridge.handleAgentStart(self.runner);
        try self.runPromptBody(io, text, timestamp_ms);
    }

    fn tryExecuteExtensionCommand(self: *AgentSessionReplay, text: []const u8) !bool {
        const invocation = slashCommandInvocation(text) orelse return false;
        const resolved = try self.runner.getCommandAlloc(self.allocator, invocation.name) orelse return false;
        defer self.allocator.free(resolved.invocation_name);

        var ctx = try self.runner.createCommandContext();
        try resolved.command.handler.call(invocation.args, &ctx);
        return true;
    }

    fn runPromptBody(self: *AgentSessionReplay, io: std.Io, text: []const u8, timestamp_ms: i64) !void {
        var emit_prompt = true;
        var drain_follow_up = false;
        while (true) {
            try self.bridge.handleTurnStart(self.runner, timestamp_ms);

            if (emit_prompt) {
                const user_message = try self.textUserMessage(text, timestamp_ms);
                try self.emitAndStoreMessage(io, user_message);
                try self.emitQueuedMessages(io, &self.next_turn_messages, .all, false);
                emit_prompt = false;
            } else if (self.steering_messages.items.len > 0) {
                try self.emitQueuedMessages(io, &self.steering_messages, self.steering_mode, true);
                drain_follow_up = false;
            } else if (drain_follow_up and self.follow_up_messages.items.len > 0) {
                try self.emitQueuedMessages(io, &self.follow_up_messages, self.follow_up_mode, true);
                drain_follow_up = false;
            }

            var assistant_message = try self.nextAssistantResponse();
            try self.bridge.handleMessageStart(self.runner, .{ .assistant = assistant_message });
            try self.emitAssistantStreamUpdates(assistant_message);
            var coding_assistant = messages.CodingAgentMessage{ .assistant = assistant_message };
            try self.bridge.handleMessageEnd(io, self.runner, self.sessions, &coding_assistant);
            assistant_message = coding_assistant.assistant;
            try self.messages.append(self.allocator, coding_assistant);
            if (assistant_message.stop_reason != .@"error") {
                self.overflow_recovery_attempted = false;
            }

            if (assistant_message.stop_reason != .@"error" and self.retry.retry_attempt > 0) {
                _ = self.retry.completeRetrySuccess(self.bridge);
            }

            if (assistant_message.stop_reason == .@"error" or assistant_message.stop_reason == .aborted) {
                if (try self.finishTurnAndMaybeRetry(io, assistant_message)) {
                    try self.bridge.handleAgentStart(self.runner);
                    emit_prompt = false;
                    continue;
                }
                return;
            }

            var turn_tool_results: std.ArrayList(ai.ToolResultMessage) = .empty;
            defer turn_tool_results.deinit(self.allocator);
            try self.executeToolCalls(io, assistant_message, &turn_tool_results, timestamp_ms);

            try self.bridge.handleTurnEnd(self.runner, .{ .assistant = assistant_message }, turn_tool_results.items);
            if (turn_tool_results.items.len > 0 and assistant_message.stop_reason == .tool_use) {
                continue;
            }
            if (self.steering_messages.items.len > 0) {
                continue;
            }
            if (self.follow_up_messages.items.len > 0) {
                drain_follow_up = true;
                continue;
            }

            try self.bridge.handleAgentEnd(self.runner, self.messages.items, false);
            if (try self.checkAutoCompaction(io, assistant_message, true)) {
                continue;
            }
            if (self.steering_messages.items.len > 0 or self.follow_up_messages.items.len > 0) {
                drain_follow_up = true;
                continue;
            }
            return;
        }
    }

    fn finishTurnAndMaybeRetry(
        self: *AgentSessionReplay,
        io: std.Io,
        assistant_message: ai.AssistantMessage,
    ) !bool {
        var no_tool_results: [0]ai.ToolResultMessage = .{};
        const will_retry = self.retry.willRetryAfterAgentEnd(self.messages.items);
        try self.bridge.handleTurnEnd(self.runner, .{ .assistant = assistant_message }, no_tool_results[0..]);
        try self.bridge.handleAgentEnd(self.runner, self.messages.items, will_retry);

        if (assistant_message.stop_reason == .aborted) return false;

        if (try self.checkAutoCompaction(io, assistant_message, true)) {
            return true;
        }

        if (self.retry.prepareRetry(self.bridge, assistant_message)) |event| {
            try self.retry_sleeps.append(self.allocator, event.delay_ms);
            self.retry.completeRetryDelay();
            if (self.messages.items.len > 0) {
                self.messages.items.len -= 1;
            }
            return true;
        }

        if (assistant_message.stop_reason == .@"error" and self.retry.retry_attempt > 0) {
            _ = self.retry.completeRetryFailure(self.bridge, assistant_message.error_message);
        }
        return false;
    }

    fn nextAssistantResponse(self: *AgentSessionReplay) !ai.AssistantMessage {
        if (self.next_response >= self.responses.len) return error.NoReplayResponse;
        defer self.next_response += 1;
        return self.responses[self.next_response];
    }

    fn textUserMessage(self: *AgentSessionReplay, text: []const u8, timestamp_ms: i64) !messages.CodingAgentMessage {
        const owned_text = try self.retainText(text);

        const content = try self.allocator.alloc(ai.UserContent, 1);
        var content_registered = false;
        errdefer if (!content_registered) self.allocator.free(content);

        content[0] = .{ .text = .{ .text = owned_text } };
        try self.owned_content.append(self.allocator, content);
        content_registered = true;

        return .{ .user = .{
            .content = content,
            .timestamp_ms = timestamp_ms,
        } };
    }

    fn emitAndStoreMessage(self: *AgentSessionReplay, io: std.Io, message: messages.CodingAgentMessage) !void {
        var mutable = message;
        try self.bridge.handleMessageStart(self.runner, mutable);
        try self.bridge.handleMessageEnd(io, self.runner, self.sessions, &mutable);
        try self.messages.append(self.allocator, mutable);
    }

    fn queueTextMessage(
        self: *AgentSessionReplay,
        queue: *std.ArrayList(QueuedSessionMessage),
        text: []const u8,
        timestamp_ms: i64,
    ) !void {
        const message = try self.textUserMessage(text, timestamp_ms);
        try queue.append(self.allocator, .{
            .text = userMessageText(message).?,
            .message = message,
        });
        try self.emitQueueUpdate();
    }

    fn throwIfQueuedExtensionCommand(self: *AgentSessionReplay, text: []const u8) !void {
        const command_name = queuedSlashCommandName(text) orelse return;
        const resolved = try self.runner.getCommandAlloc(self.allocator, command_name) orelse return;
        self.allocator.free(resolved.invocation_name);
        return error.ExtensionCommandCannotBeQueued;
    }

    fn customTextMessage(
        self: *AgentSessionReplay,
        custom_type: []const u8,
        text: []const u8,
        display: bool,
        details_json: ?[]const u8,
        timestamp_ms: i64,
    ) !messages.CodingAgentMessage {
        const owned_custom_type = try self.retainText(custom_type);
        const owned_text = try self.retainText(text);
        const owned_details = if (details_json) |details| try self.retainDetails(details) else null;

        return .{ .custom = .{
            .custom_type = owned_custom_type,
            .content = .{ .text = owned_text },
            .display = display,
            .details_json = owned_details,
            .timestamp_ms = timestamp_ms,
        } };
    }

    fn emitQueuedMessages(
        self: *AgentSessionReplay,
        io: std.Io,
        queue: *std.ArrayList(QueuedSessionMessage),
        mode: QueueMode,
        emit_update: bool,
    ) !void {
        const count = switch (mode) {
            .one_at_a_time => @min(queue.items.len, 1),
            .all => queue.items.len,
        };

        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            const queued = queue.orderedRemove(0);
            if (emit_update) try self.emitQueueUpdate();
            try self.emitAndStoreMessage(io, queued.message);
        }
    }

    fn refreshMessagesFromSessionContext(self: *AgentSessionReplay) !void {
        var context = try self.sessions.buildSessionContextAlloc(self.allocator);
        defer context.deinit();

        self.messages.clearRetainingCapacity();
        for (context.messages) |message| {
            try self.messages.append(self.allocator, try self.cloneCodingAgentMessage(message));
        }
    }

    fn removeTrailingAssistantError(self: *AgentSessionReplay) void {
        if (self.messages.items.len == 0) return;
        const last = self.messages.items[self.messages.items.len - 1];
        if (last == .assistant and last.assistant.stop_reason == .@"error") {
            self.messages.items.len -= 1;
        }
    }

    fn cloneCodingAgentMessage(
        self: *AgentSessionReplay,
        message: messages.CodingAgentMessage,
    ) !messages.CodingAgentMessage {
        return switch (message) {
            .user => |user| .{ .user = .{
                .content = try self.cloneUserContentSlice(user.content),
                .timestamp_ms = user.timestamp_ms,
            } },
            .assistant => |assistant| .{ .assistant = try self.cloneAssistantMessage(assistant) },
            .tool_result => |tool_result| .{ .tool_result = .{
                .tool_call_id = try self.retainText(tool_result.tool_call_id),
                .tool_name = try self.retainText(tool_result.tool_name),
                .content = try self.cloneUserContentSlice(tool_result.content),
                .is_error = tool_result.is_error,
                .timestamp_ms = tool_result.timestamp_ms,
            } },
            .bash_execution => |bash| .{ .bash_execution = .{
                .command = try self.retainText(bash.command),
                .output = try self.retainText(bash.output),
                .exit_code = bash.exit_code,
                .cancelled = bash.cancelled,
                .truncated = bash.truncated,
                .full_output_path = try self.optionalRetainText(bash.full_output_path),
                .timestamp_ms = bash.timestamp_ms,
                .exclude_from_context = bash.exclude_from_context,
            } },
            .custom => |custom| .{ .custom = .{
                .custom_type = try self.retainText(custom.custom_type),
                .content = switch (custom.content) {
                    .text => |text| .{ .text = try self.retainText(text) },
                    .parts => |parts| .{ .parts = try self.cloneUserContentSlice(parts) },
                },
                .display = custom.display,
                .details_json = if (custom.details_json) |details| try self.retainDetails(details) else null,
                .timestamp_ms = custom.timestamp_ms,
            } },
            .branch_summary => |summary| .{ .branch_summary = .{
                .summary = try self.retainText(summary.summary),
                .from_id = try self.retainText(summary.from_id),
                .timestamp_ms = summary.timestamp_ms,
            } },
            .compaction_summary => |summary| .{ .compaction_summary = .{
                .summary = try self.retainText(summary.summary),
                .tokens_before = summary.tokens_before,
                .timestamp_ms = summary.timestamp_ms,
            } },
        };
    }

    fn cloneAssistantMessage(self: *AgentSessionReplay, source: ai.AssistantMessage) !ai.AssistantMessage {
        return .{
            .content = try self.cloneAssistantContentSlice(source.content),
            .api = source.api,
            .provider = try self.retainText(source.provider),
            .model = try self.retainText(source.model),
            .response_model = try self.optionalRetainText(source.response_model),
            .usage = source.usage,
            .stop_reason = source.stop_reason,
            .error_message = try self.optionalRetainText(source.error_message),
            .response_id = try self.optionalRetainText(source.response_id),
            .diagnostics = try self.cloneDiagnosticsSlice(source.diagnostics),
            .timestamp_ms = source.timestamp_ms,
        };
    }

    fn cloneUserContentSlice(
        self: *AgentSessionReplay,
        content: []const ai.UserContent,
    ) ![]ai.UserContent {
        const cloned = try self.allocator.alloc(ai.UserContent, content.len);
        var registered = false;
        errdefer if (!registered) self.allocator.free(cloned);

        for (content, 0..) |block, index| {
            cloned[index] = switch (block) {
                .text => |text| .{ .text = .{
                    .text = try self.retainText(text.text),
                    .text_signature = try self.optionalRetainText(text.text_signature),
                } },
                .image => |image| .{ .image = .{
                    .data = try self.retainText(image.data),
                    .mime_type = try self.retainText(image.mime_type),
                } },
            };
        }
        try self.owned_content.append(self.allocator, cloned);
        registered = true;
        return cloned;
    }

    fn cloneAssistantContentSlice(
        self: *AgentSessionReplay,
        content: []const ai.AssistantContent,
    ) ![]ai.AssistantContent {
        const cloned = try self.allocator.alloc(ai.AssistantContent, content.len);
        var registered = false;
        errdefer if (!registered) self.allocator.free(cloned);

        for (content, 0..) |block, index| {
            cloned[index] = switch (block) {
                .text => |text| .{ .text = .{
                    .text = try self.retainText(text.text),
                    .text_signature = try self.optionalRetainText(text.text_signature),
                } },
                .thinking => |thinking| .{ .thinking = .{
                    .thinking = try self.retainText(thinking.thinking),
                    .thinking_signature = try self.optionalRetainText(thinking.thinking_signature),
                    .redacted = thinking.redacted,
                } },
                .tool_call => |tool_call| .{ .tool_call = .{
                    .id = try self.retainText(tool_call.id),
                    .name = try self.retainText(tool_call.name),
                    .arguments_json = try self.retainText(tool_call.arguments_json),
                    .thought_signature = try self.optionalRetainText(tool_call.thought_signature),
                } },
            };
        }
        try self.owned_assistant_content.append(self.allocator, cloned);
        registered = true;
        return cloned;
    }

    fn cloneDiagnosticsSlice(
        self: *AgentSessionReplay,
        diagnostics: []const ai.AssistantMessageDiagnostic,
    ) ![]ai.AssistantMessageDiagnostic {
        const cloned = try self.allocator.alloc(ai.AssistantMessageDiagnostic, diagnostics.len);
        var registered = false;
        errdefer if (!registered) self.allocator.free(cloned);

        for (diagnostics, 0..) |diagnostic, index| {
            cloned[index] = .{
                .type = try self.retainText(diagnostic.type),
                .timestamp_ms = diagnostic.timestamp_ms,
                .@"error" = if (diagnostic.@"error") |err| .{
                    .name = try self.optionalRetainText(err.name),
                    .message = try self.retainText(err.message),
                    .stack = try self.optionalRetainText(err.stack),
                    .code = err.code,
                } else null,
                .details_json = try self.optionalRetainText(diagnostic.details_json),
            };
        }
        try self.owned_diagnostics.append(self.allocator, cloned);
        registered = true;
        return cloned;
    }

    fn optionalRetainText(self: *AgentSessionReplay, maybe_text: ?[]const u8) !?[]u8 {
        return if (maybe_text) |text| try self.retainText(text) else null;
    }

    fn retainText(self: *AgentSessionReplay, text: []const u8) ![]u8 {
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        try self.owned_texts.append(self.allocator, owned_text);
        return owned_text;
    }

    fn retainDetails(self: *AgentSessionReplay, details_json: []const u8) ![]u8 {
        const owned_details = try self.allocator.dupe(u8, details_json);
        errdefer self.allocator.free(owned_details);
        try self.owned_details.append(self.allocator, owned_details);
        return owned_details;
    }

    fn emitQueueUpdate(self: *AgentSessionReplay) !void {
        const steering = try queuedTextsAlloc(self.allocator, self.steering_messages.items);
        defer self.allocator.free(steering);
        const follow_up = try queuedTextsAlloc(self.allocator, self.follow_up_messages.items);
        defer self.allocator.free(follow_up);
        self.bridge.handleQueueUpdate(steering, follow_up);
    }

    fn emitAssistantStreamUpdates(self: *AgentSessionReplay, assistant_message: ai.AssistantMessage) !void {
        for (assistant_message.content, 0..) |content, index| {
            switch (content) {
                .thinking => |thinking| if (thinking.thinking.len > 0) {
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .thinking_start = .{ .content_index = index },
                    });
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .thinking_delta = .{
                            .content_index = index,
                            .delta = thinking.thinking,
                        },
                    });
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .thinking_end = .{
                            .content_index = index,
                            .content = thinking.thinking,
                        },
                    });
                },
                .text => |text| if (text.text.len > 0) {
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .text_start = .{ .content_index = index },
                    });
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .text_delta = .{
                            .content_index = index,
                            .delta = text.text,
                        },
                    });
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .text_end = .{
                            .content_index = index,
                            .content = text.text,
                        },
                    });
                },
                .tool_call => |tool_call| {
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .toolcall_start = .{ .content_index = index },
                    });
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .toolcall_delta = .{
                            .content_index = index,
                            .delta = tool_call.arguments_json,
                        },
                    });
                    try self.bridge.handleMessageUpdate(self.runner, .{ .assistant = assistant_message }, .{
                        .toolcall_end = .{
                            .content_index = index,
                            .tool_call = tool_call,
                        },
                    });
                },
            }
        }
    }

    fn executeToolCalls(
        self: *AgentSessionReplay,
        io: std.Io,
        assistant_message: ai.AssistantMessage,
        turn_tool_results: *std.ArrayList(ai.ToolResultMessage),
        timestamp_ms: i64,
    ) !void {
        for (assistant_message.content) |content| {
            if (content != .tool_call) continue;
            const tool_call = content.tool_call;

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            var parsed_args = try std.json.parseFromSlice(std.json.Value, arena_allocator, tool_call.arguments_json, .{});
            defer parsed_args.deinit();

            try self.bridge.handleToolExecutionStart(self.runner, .{
                .tool_call_id = tool_call.id,
                .tool_name = tool_call.name,
                .args = parsed_args.value,
            });

            const execution = try self.executeToolAlloc(io, tool_call, parsed_args.value);
            var owned_execution = execution;
            defer owned_execution.deinit(self.allocator);

            const result_text = try self.toolExecutionTextAlloc(owned_execution);
            defer self.allocator.free(result_text);
            const result_value = try toolExecutionResultJsonAlloc(arena_allocator, result_text);
            const is_error = std.meta.activeTag(owned_execution) == .failure;
            try self.bridge.handleToolExecutionEnd(self.runner, .{
                .tool_call_id = tool_call.id,
                .tool_name = tool_call.name,
                .result = result_value,
                .is_error = is_error,
            });

            const tool_result = try self.toolResultMessageFromText(tool_call, result_text, is_error, timestamp_ms);
            try turn_tool_results.append(self.allocator, tool_result);
            try self.emitAndStoreMessage(io, .{ .tool_result = tool_result });
        }
    }

    fn executeToolAlloc(
        self: *AgentSessionReplay,
        io: std.Io,
        tool_call: ai.ToolCall,
        args: std.json.Value,
    ) !tools.tool_registry.ToolExecution {
        const tool = self.findTool(tool_call.name) orelse {
            const message = try std.fmt.allocPrint(self.allocator, "Tool {s} not found", .{tool_call.name});
            return .{ .failure = message };
        };
        return tool.executeValueAlloc(self.allocator, io, args, .{});
    }

    fn findTool(self: *const AgentSessionReplay, name: []const u8) ?*const tools.tool_registry.AgentTool {
        for (self.agent_tools) |*tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    fn toolExecutionTextAlloc(self: *AgentSessionReplay, execution: tools.tool_registry.ToolExecution) ![]u8 {
        return switch (execution) {
            .success => |result| try tools.render_utils.getTextOutputAlloc(self.allocator, .{ .content = result.content }, true),
            .failure => |message| try self.allocator.dupe(u8, message),
        };
    }

    fn toolResultMessageFromText(
        self: *AgentSessionReplay,
        tool_call: ai.ToolCall,
        text: []const u8,
        is_error: bool,
        timestamp_ms: i64,
    ) !ai.ToolResultMessage {
        const owned_text = try self.allocator.dupe(u8, text);
        var text_registered = false;
        errdefer if (!text_registered) self.allocator.free(owned_text);

        const content = try self.allocator.alloc(ai.UserContent, 1);
        var content_registered = false;
        errdefer if (!content_registered) self.allocator.free(content);

        content[0] = .{ .text = .{ .text = owned_text } };
        try self.owned_texts.append(self.allocator, owned_text);
        text_registered = true;
        try self.owned_content.append(self.allocator, content);
        content_registered = true;

        return .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .content = content,
            .is_error = is_error,
            .timestamp_ms = timestamp_ms,
        };
    }
};

fn latestCompactionTimestampMsAlloc(
    allocator: std.mem.Allocator,
    branch_entries: []const session_manager.FileEntry,
) !?i64 {
    var index = branch_entries.len;
    while (index > 0) {
        index -= 1;
        if (!try fileEntryTypeEqualsAlloc(allocator, branch_entries[index], "compaction")) continue;
        const timestamp = try session_manager.entryStringFieldAlloc(
            allocator,
            branch_entries[index].raw_json,
            "timestamp",
        );
        defer if (timestamp) |value| allocator.free(value);
        return if (timestamp) |value| messages.parseTimestampMs(value) catch null else null;
    }
    return null;
}

fn fileEntryTypeEqualsAlloc(
    allocator: std.mem.Allocator,
    entry: session_manager.FileEntry,
    expected: []const u8,
) !bool {
    const entry_type = try session_manager.entryStringFieldAlloc(allocator, entry.raw_json, "type");
    defer if (entry_type) |value| allocator.free(value);
    return if (entry_type) |value| std.mem.eql(u8, value, expected) else false;
}

const never_aborted_signal: ai.AbortSignal = .{};

fn extensionPreparationFromCompaction(preparation: *const compaction_mod.CompactionPreparation) extensions.CompactionPreparation {
    return .{
        .first_kept_entry_id = preparation.first_kept_entry_id,
        .messages_to_summarize = preparation.messages_to_summarize,
        .turn_prefix_messages = preparation.turn_prefix_messages,
        .is_split_turn = preparation.is_split_turn,
        .tokens_before = preparation.tokens_before,
        .previous_summary = preparation.previous_summary,
        .tokens = preparation.tokens_before,
    };
}

fn compactionErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.CompactionCancelled => "Compaction cancelled",
        error.SummarizationFailed => "Compaction failed: SummarizationFailed",
        error.TurnPrefixSummarizationFailed => "Compaction failed: TurnPrefixSummarizationFailed",
        else => "Compaction failed",
    };
}

pub fn isRetryableError(message: ai.AssistantMessage, context_window: ?u64) bool {
    if (message.stop_reason != .@"error") return false;
    const error_message = message.error_message orelse return false;
    if (ai.overflow.isContextOverflow(message, context_window)) return false;
    if (isNonRetryableProviderLimitError(error_message)) return false;
    return isRetryableErrorText(error_message);
}

pub fn isNonRetryableProviderLimitError(error_message: []const u8) bool {
    const non_retryable = [_][]const u8{
        "GoUsageLimitError",
        "FreeUsageLimitError",
        "Monthly usage limit reached",
        "available balance",
        "insufficient_quota",
        "out of budget",
        "quota exceeded",
        "billing",
    };
    return containsAnyAsciiIgnoreCase(error_message, &non_retryable);
}

pub fn retryDelayMs(base_delay_ms: u64, attempt: usize) u64 {
    if (attempt == 0) return base_delay_ms;
    var delay = base_delay_ms;
    var remaining = attempt - 1;
    while (remaining > 0) : (remaining -= 1) {
        delay = std.math.mul(u64, delay, 2) catch return std.math.maxInt(u64);
    }
    return delay;
}

fn isRetryableErrorText(error_message: []const u8) bool {
    const direct_phrases = [_][]const u8{
        "overloaded",
        "overloaded_error",
        "provider returned error",
        "provider_returned_error",
        "rate limit",
        "rate_limit",
        "too many requests",
        "429",
        "500",
        "502",
        "503",
        "504",
        "service unavailable",
        "service_unavailable",
        "server error",
        "server_error",
        "internal error",
        "internal_error",
        "network error",
        "network_error",
        "connection error",
        "connection_error",
        "connection refused",
        "connection_refused",
        "connection lost",
        "connection_lost",
        "websocket closed",
        "websocket error",
        "other side closed",
        "fetch failed",
        "upstream connect",
        "reset before headers",
        "socket hang up",
        "ended without",
        "stream ended before message_stop",
        "http2 request did not get a response",
        "timed out",
        "timeout",
        "terminated",
        "retry delay",
    };
    if (containsAnyAsciiIgnoreCase(error_message, &direct_phrases)) return true;

    const token_groups = [_][]const []const u8{
        &.{ "provider", "returned", "error" },
        &.{ "rate", "limit" },
        &.{ "service", "unavailable" },
        &.{ "server", "error" },
        &.{ "internal", "error" },
        &.{ "network", "error" },
        &.{ "connection", "error" },
        &.{ "connection", "refused" },
        &.{ "connection", "lost" },
        &.{ "websocket", "closed" },
        &.{ "websocket", "error" },
        &.{ "upstream", "connect" },
        &.{ "retry", "delay" },
    };
    for (token_groups) |tokens| {
        if (containsTokenSequenceAsciiIgnoreCase(error_message, tokens)) return true;
    }
    return false;
}

fn containsAnyAsciiIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsAsciiIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return indexOfAsciiIgnoreCase(haystack, needle, 0) != null;
}

fn containsTokenSequenceAsciiIgnoreCase(haystack: []const u8, tokens: []const []const u8) bool {
    var start: usize = 0;
    for (tokens) |token| {
        const found = indexOfAsciiIgnoreCase(haystack, token, start) orelse return false;
        start = found + token.len;
    }
    return true;
}

fn indexOfAsciiIgnoreCase(haystack: []const u8, needle: []const u8, start_index: usize) ?usize {
    if (needle.len == 0) return start_index;
    if (start_index >= haystack.len or needle.len > haystack.len - start_index) return null;
    var index = start_index;
    while (index <= haystack.len - needle.len) : (index += 1) {
        var matches = true;
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(byte)) {
                matches = false;
                break;
            }
        }
        if (matches) return index;
    }
    return null;
}

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

fn queuedTextsAlloc(
    allocator: std.mem.Allocator,
    queue: []const QueuedSessionMessage,
) ![][]const u8 {
    const texts = try allocator.alloc([]const u8, queue.len);
    for (queue, 0..) |queued, index| texts[index] = queued.text;
    return texts;
}

const SlashCommandInvocation = struct {
    name: []const u8,
    args: []const u8,
};

fn slashCommandInvocation(text: []const u8) ?SlashCommandInvocation {
    if (text.len < 2 or text[0] != '/') return null;
    const rest = text[1..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    if (end == 0) return null;
    return .{
        .name = rest[0..end],
        .args = if (end == rest.len) "" else rest[end + 1 ..],
    };
}

fn queuedSlashCommandName(text: []const u8) ?[]const u8 {
    const invocation = slashCommandInvocation(text) orelse return null;
    return invocation.name;
}

pub fn queuedExtensionCommandErrorMessageAlloc(
    allocator: std.mem.Allocator,
    command_name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Extension command \"/{s}\" cannot be queued. Use prompt() or execute the command when not streaming.",
        .{command_name},
    );
}

fn userMessageText(message: messages.CodingAgentMessage) ?[]const u8 {
    if (message != .user) return null;
    return firstUserContentText(message.user.content);
}

fn customMessageText(message: messages.CodingAgentMessage) []const u8 {
    if (message != .custom) return "";
    return switch (message.custom.content) {
        .text => |text| text,
        .parts => |parts| firstUserContentText(parts) orelse "",
    };
}

fn firstUserContentText(content: []const ai.UserContent) ?[]const u8 {
    for (content) |part| {
        switch (part) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return null;
}

fn toolExecutionResultJsonAlloc(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var result = std.json.Value{ .object = .empty };
    try putJsonString(allocator, &result, "text", text);
    return result;
}

fn putJsonString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .string = value });
}

fn putJsonInt(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: i64) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .integer = value });
}

fn putJsonBool(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: bool) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putJsonValue(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    try object.object.put(allocator, try allocator.dupe(u8, key), value);
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

test "AgentSession bridge subscription handles unsubscribe safely during emit" {
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

    var state = SubscriptionTestState{ .bridge = &bridge };
    const self_handle = try bridge.subscribeWithHandle(.{ .ptr = &state, .call_fn = SubscriptionTestState.selfListener });
    state.self_handle = self_handle;
    const other_handle = try bridge.subscribeWithHandle(.{ .ptr = &state, .call_fn = SubscriptionTestState.otherListener });

    try bridge.handleAgentStart(&runner);
    try bridge.handleAgentStart(&runner);

    try std.testing.expectEqual(@as(usize, 1), state.self_calls);
    try std.testing.expectEqual(@as(usize, 2), state.other_calls);
    try std.testing.expect(!bridge.unsubscribe(self_handle));
    try std.testing.expect(bridge.unsubscribe(other_handle));

    try bridge.handleAgentStart(&runner);
    try std.testing.expectEqual(@as(usize, 1), state.self_calls);
    try std.testing.expectEqual(@as(usize, 2), state.other_calls);
}

test "AgentSession retry controller emits retry start and success end events" {
    const allocator = std.testing.allocator;
    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();

    var observations: std.ArrayList(RetryObservation) = .empty;
    defer observations.deinit(allocator);
    var observer = RetryObserver{ .allocator = allocator, .observations = &observations };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = RetryObserver.publicListener });

    var controller = AutoRetryController.init(.{
        .enabled = true,
        .max_retries = 3,
        .base_delay_ms = 1,
    }, null);

    const overloaded = assistantError("overloaded_error");
    const agent_messages = [_]messages.CodingAgentMessage{.{ .assistant = overloaded }};
    try std.testing.expect(controller.willRetryAfterAgentEnd(&agent_messages));

    const first_start = controller.prepareRetry(&bridge, overloaded).?;
    try std.testing.expectEqual(@as(usize, 1), first_start.attempt);
    try std.testing.expectEqual(@as(u64, 1), first_start.delay_ms);
    try std.testing.expect(controller.isRetrying());

    const second_start = controller.prepareRetry(&bridge, overloaded).?;
    try std.testing.expectEqual(@as(usize, 2), second_start.attempt);
    try std.testing.expectEqual(@as(u64, 2), second_start.delay_ms);

    const success = controller.completeRetrySuccess(&bridge).?;
    try std.testing.expect(success.success);
    try std.testing.expectEqual(@as(usize, 2), success.attempt);
    try std.testing.expect(!controller.isRetrying());
    try std.testing.expectEqual(@as(usize, 0), controller.retry_attempt);

    const expected = [_]RetryObservation{
        .{ .event = .start, .attempt = 1, .max_attempts = 3, .delay_ms = 1 },
        .{ .event = .start, .attempt = 2, .max_attempts = 3, .delay_ms = 2 },
        .{ .event = .end, .attempt = 2, .success = true },
    };
    try std.testing.expectEqualSlices(RetryObservation, &expected, observations.items);
}

test "AgentSession retry controller exhausts max retries and emits failure end" {
    const allocator = std.testing.allocator;
    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();

    var observations: std.ArrayList(RetryObservation) = .empty;
    defer observations.deinit(allocator);
    var observer = RetryObserver{ .allocator = allocator, .observations = &observations };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = RetryObserver.publicListener });

    var controller = AutoRetryController.init(.{
        .enabled = true,
        .max_retries = 2,
        .base_delay_ms = 10,
    }, null);
    const overloaded = assistantError("Provider finish_reason: network_error");

    try std.testing.expect(controller.prepareRetry(&bridge, overloaded) != null);
    try std.testing.expect(controller.prepareRetry(&bridge, overloaded) != null);
    try std.testing.expect(controller.prepareRetry(&bridge, overloaded) == null);

    const agent_messages = [_]messages.CodingAgentMessage{.{ .assistant = overloaded }};
    try std.testing.expect(!controller.willRetryAfterAgentEnd(&agent_messages));

    const failure = controller.completeRetryFailure(&bridge, null).?;
    try std.testing.expect(!failure.success);
    try std.testing.expectEqual(@as(usize, 2), failure.attempt);
    try std.testing.expect(!controller.isRetrying());

    const expected = [_]RetryObservation{
        .{ .event = .start, .attempt = 1, .max_attempts = 2, .delay_ms = 10 },
        .{ .event = .start, .attempt = 2, .max_attempts = 2, .delay_ms = 20 },
        .{ .event = .end, .attempt = 2, .success = false },
    };
    try std.testing.expectEqualSlices(RetryObservation, &expected, observations.items);
}

test "AgentSession retry controller skips disabled non-retryable and overflow errors" {
    const allocator = std.testing.allocator;
    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();

    var disabled = AutoRetryController.init(.{ .enabled = false }, null);
    try std.testing.expect(disabled.prepareRetry(&bridge, assistantError("overloaded_error")) == null);

    var enabled = AutoRetryController.init(.{ .enabled = true, .max_retries = 3, .base_delay_ms = 1 }, 32_768);
    try std.testing.expect(enabled.prepareRetry(&bridge, assistantError("invalid_api_key")) == null);
    try std.testing.expect(enabled.prepareRetry(&bridge, assistantError("insufficient_quota")) == null);
    try std.testing.expect(enabled.prepareRetry(&bridge, assistantError("context_length_exceeded")) == null);
    try std.testing.expect(isRetryableError(assistantError("Service unavailable: retry later"), 200_000));
    try std.testing.expect(!isRetryableError(assistantError("Billing quota exceeded"), 200_000));
}

test "AgentSession retry controller cancels retry sleep as failure event" {
    const allocator = std.testing.allocator;
    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();

    var observations: std.ArrayList(RetryObservation) = .empty;
    defer observations.deinit(allocator);
    var observer = RetryObserver{ .allocator = allocator, .observations = &observations };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = RetryObserver.publicListener });

    var controller = AutoRetryController.init(.{
        .enabled = true,
        .max_retries = 3,
        .base_delay_ms = 100,
    }, null);
    try std.testing.expect(controller.prepareRetry(&bridge, assistantError("connection lost")) != null);
    const cancelled = controller.abortRetry(&bridge).?;
    try std.testing.expect(!cancelled.success);
    try std.testing.expectEqualStrings("Retry cancelled", cancelled.final_error.?);
    try std.testing.expect(!controller.isRetrying());

    const expected = [_]RetryObservation{
        .{ .event = .start, .attempt = 1, .max_attempts = 3, .delay_ms = 100 },
        .{ .event = .end, .attempt = 1, .success = false, .final_error = .cancelled },
    };
    try std.testing.expectEqualSlices(RetryObservation, &expected, observations.items);
}

test "AgentSession replay emits upstream single prompt event order" {
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
    var observed_events: std.ArrayList(ReplayEventObservation) = .empty;
    defer observed_events.deinit(allocator);
    var will_retry_flags: std.ArrayList(bool) = .empty;
    defer will_retry_flags.deinit(allocator);
    var update_tags: std.ArrayList(std.meta.Tag(ai.StreamEvent)) = .empty;
    defer update_tags.deinit(allocator);
    var recorder = ReplayEventRecorder{
        .allocator = allocator,
        .events = &observed_events,
        .will_retry_flags = &will_retry_flags,
        .update_tags = &update_tags,
    };
    try bridge.subscribe(.{ .ptr = &recorder, .call_fn = ReplayEventRecorder.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello" } }};
    const responses = [_]ai.AssistantMessage{assistantMessage(&assistant_content, .stop)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "hi", 123);

    const expected = [_]ReplayEventObservation{
        .agent_start,
        .turn_start,
        .message_start_user,
        .message_end_user,
        .message_start_assistant,
        .message_update,
        .message_end_assistant,
        .turn_end,
        .agent_end,
    };
    try std.testing.expectEqualSlices(ReplayEventObservation, &expected, observed_events.items);
    try std.testing.expectEqualSlices(bool, &[_]bool{false}, will_retry_flags.items);
    try std.testing.expectEqual(@as(usize, 2), replay.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), replay.pendingResponseCount());
}

test "AgentSession replay emits rich streaming update boundaries" {
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
    var observed_events: std.ArrayList(ReplayEventObservation) = .empty;
    defer observed_events.deinit(allocator);
    var will_retry_flags: std.ArrayList(bool) = .empty;
    defer will_retry_flags.deinit(allocator);
    var update_tags: std.ArrayList(std.meta.Tag(ai.StreamEvent)) = .empty;
    defer update_tags.deinit(allocator);
    var update_indexes: std.ArrayList(usize) = .empty;
    defer update_indexes.deinit(allocator);
    var update_deltas: std.ArrayList(ReplayUpdateDeltaKind) = .empty;
    defer update_deltas.deinit(allocator);
    var recorder = ReplayEventRecorder{
        .allocator = allocator,
        .events = &observed_events,
        .will_retry_flags = &will_retry_flags,
        .update_tags = &update_tags,
        .update_indexes = &update_indexes,
        .update_deltas = &update_deltas,
    };
    try bridge.subscribe(.{ .ptr = &recorder, .call_fn = ReplayEventRecorder.publicListener });

    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};

    const mixed_content = [_]ai.AssistantContent{
        .{ .thinking = .{ .thinking = "plan", .thinking_signature = "sig" } },
        .{ .text = .{ .text = "answer" } },
        .{ .tool_call = .{
            .id = "call-1",
            .name = "echo",
            .arguments_json = "{\"text\":\"hello\"}",
        } },
    };
    const final_content = [_]ai.AssistantContent{.{ .text = .{ .text = "done" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&mixed_content, .tool_use),
        assistantMessage(&final_content, .stop),
    };
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &replay_tools,
    );
    defer replay.deinit();
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "hi", 123);

    const expected_tags = [_]std.meta.Tag(ai.StreamEvent){
        .thinking_start,
        .thinking_delta,
        .thinking_end,
        .text_start,
        .text_delta,
        .text_end,
        .toolcall_start,
        .toolcall_delta,
        .toolcall_end,
    };
    const expected_indexes = [_]usize{ 0, 0, 0, 1, 1, 1, 2, 2, 2 };
    const expected_deltas = [_]ReplayUpdateDeltaKind{
        .none,
        .thinking_plan,
        .thinking_plan,
        .none,
        .text_answer,
        .text_answer,
        .none,
        .tool_args,
        .tool_args,
    };
    try std.testing.expect(update_tags.items.len >= expected_tags.len);
    try std.testing.expectEqualSlices(std.meta.Tag(ai.StreamEvent), &expected_tags, update_tags.items[0..expected_tags.len]);
    try std.testing.expectEqualSlices(usize, &expected_indexes, update_indexes.items[0..expected_indexes.len]);
    try std.testing.expectEqualSlices(ReplayUpdateDeltaKind, &expected_deltas, update_deltas.items[0..expected_deltas.len]);
    try std.testing.expectEqual(@as(usize, 1), echo_state.runs.items.len);
}

test "AgentSession replay removes queued steer before queued message_start" {
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
    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &replay_tools,
    );
    defer replay.deinit();

    var counts_at_start: std.ArrayList(usize) = .empty;
    defer counts_at_start.deinit(allocator);
    var queue_counts: std.ArrayList(usize) = .empty;
    defer queue_counts.deinit(allocator);
    var state = QueueDuringToolState{
        .replay = &replay,
        .delivery = .steer,
        .queued_text = "queued",
        .counts_at_message_start = &counts_at_start,
        .queue_counts = &queue_counts,
    };
    try bridge.subscribe(.{ .ptr = &state, .call_fn = QueueDuringToolState.publicListener });

    const tool_content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "echo",
        .arguments_json = "{\"text\":\"hello\"}",
    } }};
    const final_content = [_]ai.AssistantContent{.{ .text = .{ .text = "done" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&tool_content, .tool_use),
        assistantMessage(&final_content, .stop),
    };
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "start", 123);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, queue_counts.items);
    try std.testing.expectEqualSlices(usize, &[_]usize{0}, counts_at_start.items);
    try std.testing.expectEqual(@as(usize, 0), replay.pendingMessageCount());
    try expectReplayUserTexts(&replay, &[_][]const u8{ "start", "queued" });
    try std.testing.expectEqual(@as(usize, 1), echo_state.runs.items.len);
}

test "AgentSession replay delays follow-up until tool continuation finishes" {
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
    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &replay_tools,
    );
    defer replay.deinit();

    var counts_at_start: std.ArrayList(usize) = .empty;
    defer counts_at_start.deinit(allocator);
    var queue_counts: std.ArrayList(usize) = .empty;
    defer queue_counts.deinit(allocator);
    var state = QueueDuringToolState{
        .replay = &replay,
        .delivery = .follow_up,
        .queued_text = "after current run",
        .counts_at_message_start = &counts_at_start,
        .queue_counts = &queue_counts,
    };
    try bridge.subscribe(.{ .ptr = &state, .call_fn = QueueDuringToolState.publicListener });

    const tool_content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "echo",
        .arguments_json = "{\"text\":\"hello\"}",
    } }};
    const original_content = [_]ai.AssistantContent{.{ .text = .{ .text = "original turn complete" } }};
    const follow_up_content = [_]ai.AssistantContent{.{ .text = .{ .text = "handled follow-up" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&tool_content, .tool_use),
        assistantMessage(&original_content, .stop),
        assistantMessage(&follow_up_content, .stop),
    };
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "start", 123);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, queue_counts.items);
    try std.testing.expectEqualSlices(usize, &[_]usize{0}, counts_at_start.items);
    try expectReplayUserTexts(&replay, &[_][]const u8{ "start", "after current run" });
    try expectReplayAssistantTexts(&replay, &[_][]const u8{ "", "original turn complete", "handled follow-up" });
}

test "AgentSession replay injects next-turn custom messages without queue update" {
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
    var queue_updates: std.ArrayList(usize) = .empty;
    defer queue_updates.deinit(allocator);
    var observer = QueueUpdateCounter{ .allocator = allocator, .counts = &queue_updates };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = QueueUpdateCounter.publicListener });

    const final_content = [_]ai.AssistantContent{.{ .text = .{ .text = "done" } }};
    const responses = [_]ai.AssistantMessage{assistantMessage(&final_content, .stop)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    try replay.sendCustomTextMessage("next-turn", "carry this", true, "{\"value\":1}", 122, .next_turn);
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "normal prompt", 123);

    try std.testing.expectEqual(@as(usize, 0), queue_updates.items.len);
    try expectReplayRoles(&replay, &[_]ObservedRole{ .user, .custom, .assistant });
    try std.testing.expectEqualStrings("next-turn", replay.messages.items[1].custom.custom_type);
    try std.testing.expectEqualStrings("carry this", customMessageText(replay.messages.items[1]));
    try std.testing.expectEqualStrings("{\"value\":1}", replay.messages.items[1].custom.details_json.?);
}

test "AgentSession replay delivers multiple steering messages in order in one-at-a-time mode" {
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
    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &replay_tools,
    );
    defer replay.deinit();

    var counts_at_start: std.ArrayList(usize) = .empty;
    defer counts_at_start.deinit(allocator);
    var queue_counts: std.ArrayList(usize) = .empty;
    defer queue_counts.deinit(allocator);
    var state = QueueDuringToolState{
        .replay = &replay,
        .delivery = .steer,
        .queued_text = "steer 1",
        .extra_queued_text = "steer 2",
        .counts_at_message_start = &counts_at_start,
        .queue_counts = &queue_counts,
    };
    try bridge.subscribe(.{ .ptr = &state, .call_fn = QueueDuringToolState.publicListener });

    const tool_content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "echo",
        .arguments_json = "{\"text\":\"hello\"}",
    } }};
    const first_content = [_]ai.AssistantContent{.{ .text = .{ .text = "handled steer 1" } }};
    const second_content = [_]ai.AssistantContent{.{ .text = .{ .text = "handled steer 2" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&tool_content, .tool_use),
        assistantMessage(&first_content, .stop),
        assistantMessage(&second_content, .stop),
    };
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "start", 123);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2, 1, 0 }, queue_counts.items);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, counts_at_start.items);
    try expectReplayUserTexts(&replay, &[_][]const u8{ "start", "steer 1", "steer 2" });
    try expectReplayAssistantTexts(&replay, &[_][]const u8{ "", "handled steer 1", "handled steer 2" });
}

test "AgentSession replay delivers all steering messages in one batch in all mode" {
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
    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &replay_tools,
    );
    defer replay.deinit();
    replay.setSteeringMode(.all);

    var counts_at_start: std.ArrayList(usize) = .empty;
    defer counts_at_start.deinit(allocator);
    var queue_counts: std.ArrayList(usize) = .empty;
    defer queue_counts.deinit(allocator);
    var state = QueueDuringToolState{
        .replay = &replay,
        .delivery = .steer,
        .queued_text = "steer 1",
        .extra_queued_text = "steer 2",
        .counts_at_message_start = &counts_at_start,
        .queue_counts = &queue_counts,
    };
    try bridge.subscribe(.{ .ptr = &state, .call_fn = QueueDuringToolState.publicListener });

    const tool_content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "echo",
        .arguments_json = "{\"text\":\"hello\"}",
    } }};
    const final_content = [_]ai.AssistantContent{.{ .text = .{ .text = "batched steer response" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&tool_content, .tool_use),
        assistantMessage(&final_content, .stop),
    };
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "start", 123);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2, 1, 0 }, queue_counts.items);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, counts_at_start.items);
    try expectReplayUserTexts(&replay, &[_][]const u8{ "start", "steer 1", "steer 2" });
    try expectReplayAssistantTexts(&replay, &[_][]const u8{ "", "batched steer response" });
}

test "AgentSession replay delivers all follow-up messages in one batch in all mode" {
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
    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &replay_tools,
    );
    defer replay.deinit();
    replay.setFollowUpMode(.all);

    var counts_at_start: std.ArrayList(usize) = .empty;
    defer counts_at_start.deinit(allocator);
    var queue_counts: std.ArrayList(usize) = .empty;
    defer queue_counts.deinit(allocator);
    var state = QueueDuringToolState{
        .replay = &replay,
        .delivery = .follow_up,
        .queued_text = "follow-up 1",
        .extra_queued_text = "follow-up 2",
        .counts_at_message_start = &counts_at_start,
        .queue_counts = &queue_counts,
    };
    try bridge.subscribe(.{ .ptr = &state, .call_fn = QueueDuringToolState.publicListener });

    const tool_content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "echo",
        .arguments_json = "{\"text\":\"hello\"}",
    } }};
    const original_content = [_]ai.AssistantContent{.{ .text = .{ .text = "original turn complete" } }};
    const final_content = [_]ai.AssistantContent{.{ .text = .{ .text = "batched follow-up response" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&tool_content, .tool_use),
        assistantMessage(&original_content, .stop),
        assistantMessage(&final_content, .stop),
    };
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "start", 123);

    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 2, 1, 0 }, queue_counts.items);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 1, 0 }, counts_at_start.items);
    try expectReplayUserTexts(&replay, &[_][]const u8{ "start", "follow-up 1", "follow-up 2" });
    try expectReplayAssistantTexts(&replay, &[_][]const u8{ "", "original turn complete", "batched follow-up response" });
}

test "AgentSession replay dispatches extension commands immediately when prompted while idle" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var command_args: std.ArrayList([]u8) = .empty;
    defer {
        for (command_args.items) |args| allocator.free(args);
        command_args.deinit(allocator);
    }
    var recorder = CommandRunRecorder{
        .allocator = allocator,
        .args = &command_args,
    };

    const command_source = source_info.createSyntheticSourceInfo("/tmp/command.zig", .{ .source = "test" });
    const commands = [_]extensions.RegisteredCommand{.{
        .name = "testcmd",
        .source_info = command_source,
        .description = "Test command",
        .handler = .{ .ptr = &recorder, .handler_fn = CommandRunRecorder.command },
    }};
    const registered_extensions = [_]extensions.Extension{testCommandExtension("/tmp/commands.zig", &commands)};
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &registered_extensions,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();

    try replay.prompt(std.testing.io, "/testcmd hello world", 123);

    try std.testing.expectEqual(@as(usize, 1), command_args.items.len);
    try std.testing.expectEqualStrings("hello world", command_args.items[0]);
    try std.testing.expectEqual(@as(usize, 0), replay.pendingResponseCount());
    try std.testing.expectEqual(@as(usize, 0), replay.messages.items.len);
}

test "AgentSession replay rejects queued registered extension commands from public steer and follow-up" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    const command_source = source_info.createSyntheticSourceInfo("/tmp/command.zig", .{ .source = "test" });
    const commands = [_]extensions.RegisteredCommand{.{
        .name = "testcmd",
        .source_info = command_source,
        .description = "Test command",
        .handler = .{ .handler_fn = QueueCommandCallbacks.command },
    }};
    const registered_extensions = [_]extensions.Extension{testCommandExtension("/tmp/commands.zig", &commands)};
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &registered_extensions,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();

    try std.testing.expectError(error.ExtensionCommandCannotBeQueued, replay.steer("/testcmd queued", 123));
    try std.testing.expectError(error.ExtensionCommandCannotBeQueued, replay.followUp("/testcmd queued", 123));
    try std.testing.expectEqual(@as(usize, 0), replay.pendingMessageCount());
    try replay.steer("/unknown queued", 123);
    try std.testing.expectEqual(@as(usize, 1), replay.pendingMessageCount());

    const message = try queuedExtensionCommandErrorMessageAlloc(allocator, "testcmd");
    defer allocator.free(message);
    try std.testing.expectEqualStrings(
        "Extension command \"/testcmd\" cannot be queued. Use prompt() or execute the command when not streaming.",
        message,
    );
}

test "AgentSession replay treats extension-origin queued slash-command follow-ups as raw user text" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var command_args: std.ArrayList([]u8) = .empty;
    defer {
        for (command_args.items) |args| allocator.free(args);
        command_args.deinit(allocator);
    }
    var recorder = CommandRunRecorder{
        .allocator = allocator,
        .args = &command_args,
    };

    const command_source = source_info.createSyntheticSourceInfo("/tmp/command.zig", .{ .source = "test" });
    const commands = [_]extensions.RegisteredCommand{.{
        .name = "testcmd",
        .source_info = command_source,
        .description = "Test command",
        .handler = .{ .ptr = &recorder, .handler_fn = CommandRunRecorder.command },
    }};
    const registered_extensions = [_]extensions.Extension{testCommandExtension("/tmp/commands.zig", &commands)};
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &registered_extensions,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &replay_tools,
    );
    defer replay.deinit();

    var follow_up_state = ExtensionOriginFollowUpState{ .replay = &replay };
    try bridge.subscribe(.{ .ptr = &follow_up_state, .call_fn = ExtensionOriginFollowUpState.publicListener });

    const tool_content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "tool-1",
        .name = "echo",
        .arguments_json = "{\"text\":\"hello\"}",
    } }};
    const original_content = [_]ai.AssistantContent{.{ .text = .{ .text = "first turn complete" } }};
    const follow_up_content = [_]ai.AssistantContent{.{ .text = .{ .text = "queued follow-up handled by model" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&tool_content, .tool_use),
        assistantMessage(&original_content, .stop),
        assistantMessage(&follow_up_content, .stop),
    };
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "start", 123);

    try std.testing.expectEqual(@as(usize, 0), command_args.items.len);
    try expectReplayUserTexts(&replay, &[_][]const u8{ "start", "/testcmd queued" });
    try expectReplayAssistantTexts(&replay, &[_][]const u8{ "", "first turn complete", "queued follow-up handled by model" });
}

test "AgentSession replay delivers follow-ups queued during agent_end" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var follow_up_state = AgentEndFollowUpState{ .queued_text = "conflict report" };
    const handlers = [_]extensions.ExtensionHandler{.{
        .event_name = .agent_end,
        .ptr = &follow_up_state,
        .handler_fn = AgentEndFollowUpState.handler,
    }};
    const registered_extensions = [_]extensions.Extension{testExtension("/tmp/agent-end-follow-up.zig", &handlers)};
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &registered_extensions,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    follow_up_state.replay = &replay;

    const reply_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const follow_up_content = [_]ai.AssistantContent{.{ .text = .{ .text = "follow-up reply" } }};
    const responses = [_]ai.AssistantMessage{
        assistantMessage(&reply_content, .stop),
        assistantMessage(&follow_up_content, .stop),
    };
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "hello", 123);

    try expectReplayUserTexts(&replay, &[_][]const u8{ "hello", "conflict report" });
    try expectReplayAssistantTexts(&replay, &[_][]const u8{ "reply", "follow-up reply" });
    try std.testing.expectEqual(@as(usize, 1), follow_up_state.calls);
    try std.testing.expectEqual(@as(usize, 0), replay.pendingMessageCount());
}

test "AgentSession replay compact uses extension-provided summary and emits saved compact event" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var handler_arena = std.heap.ArenaAllocator.init(allocator);
    defer handler_arena.deinit();
    var extension_state = CompactExtensionState{
        .allocator = handler_arena.allocator(),
        .summary = "summary from extension",
    };
    const handlers = [_]extensions.ExtensionHandler{
        .{
            .ptr = &extension_state,
            .event_name = .session_before_compact,
            .handler_fn = CompactExtensionState.handler,
        },
        .{
            .ptr = &extension_state,
            .event_name = .session_compact,
            .handler_fn = CompactExtensionState.handler,
        },
    };
    const registered_extensions = [_]extensions.Extension{testExtension("/tmp/session-compact.zig", &handlers)};
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &registered_extensions,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantMessage(&assistant_content, .stop)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 123);

    const entries_before = harness.sessions.getEntries();
    try std.testing.expectEqual(@as(usize, 2), entries_before.len);
    const first_kept_entry_id = entries_before[0].id.?;
    var signal: ai.AbortSignal = .{};

    const result = try replay.compactWithExtension(
        std.testing.io,
        .{
            .first_kept_entry_id = first_kept_entry_id,
            .tokens_before = 222,
        },
        "keep it crisp",
        .manual,
        false,
        &signal,
    );

    try std.testing.expectEqualStrings("summary from extension", result.summary);
    try std.testing.expectEqualStrings(first_kept_entry_id, result.first_kept_entry_id);
    try std.testing.expectEqual(@as(u64, 222), result.tokens_before);
    try std.testing.expectEqualStrings("{\"source\":\"extension\"}", result.details_json.?);
    try std.testing.expectEqual(@as(usize, 1), extension_state.before_calls);
    try std.testing.expectEqual(@as(usize, 1), extension_state.compact_calls);
    try std.testing.expectEqual(@as(usize, 2), extension_state.seen_branch_entries_len);
    try std.testing.expectEqualStrings("keep it crisp", extension_state.seen_custom_instructions.?);
    try std.testing.expectEqualStrings(first_kept_entry_id, extension_state.seen_first_kept_entry_id.?);
    try std.testing.expectEqual(@as(u64, 222), extension_state.seen_tokens_before.?);
    try std.testing.expectEqual(true, extension_state.seen_from_extension.?);

    const entries_after = harness.sessions.getEntries();
    try std.testing.expectEqual(@as(usize, 3), entries_after.len);
    const compaction_entry = entries_after[2];
    try expectEntryType(compaction_entry, "compaction");
    try expectEntryJsonStringField(allocator, compaction_entry, "summary", "summary from extension");
    try expectEntryJsonStringField(allocator, compaction_entry, "firstKeptEntryId", first_kept_entry_id);
    try expectEntryJsonU64Field(allocator, compaction_entry, "tokensBefore", 222);
    try expectEntryJsonNestedStringField(allocator, compaction_entry, "details", "source", "extension");
    try expectEntryJsonBoolField(allocator, compaction_entry, "fromHook", true);

    var context = try harness.sessions.buildSessionContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expect(context.messages.len >= 1);
    try std.testing.expectEqual(ObservedRole.compaction_summary, observedRole(context.messages[0]));
    try std.testing.expectEqualStrings("summary from extension", context.messages[0].compaction_summary.summary);

    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .manual },
        .{ .event = .end, .reason = .manual, .aborted = false, .will_retry = false, .summary = .extension },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items);
}

test "AgentSession replay compact falls back to generated summary and emits saved compact event" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantMessage(&assistant_content, .stop)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 123);

    const entries_before = harness.sessions.getEntries();
    try std.testing.expectEqual(@as(usize, 2), entries_before.len);
    const first_kept_entry_id = entries_before[0].id.?;
    var signal: ai.AbortSignal = .{};
    var preparation = compaction_mod.CompactionPreparation{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .first_kept_entry_id = first_kept_entry_id,
        .messages_to_summarize = replay.messages.items,
        .turn_prefix_messages = &.{},
        .is_split_turn = false,
        .tokens_before = 333,
        .settings = .{ .reserve_tokens = 1024, .keep_recent_tokens = 1 },
    };
    defer preparation.deinit();
    var summary_state = GeneratedSummaryState{ .summary = "summary from generated executor" };

    const result = try replay.compactWithGeneratedSummary(
        std.testing.io,
        &preparation,
        sessionCompactionModel(),
        .{
            .api_key = "test-key",
            .signal = &signal,
            .custom_instructions = "keep the generated summary crisp",
        },
        summary_state.executor(),
        .manual,
        false,
    );

    try std.testing.expectEqualStrings("summary from generated executor", result.summary);
    try std.testing.expectEqual(@as(usize, 1), summary_state.calls);
    try std.testing.expectEqual(@as(?u64, 819), summary_state.seen_max_tokens);
    try std.testing.expectEqualStrings("test-key", summary_state.seen_api_key.?);

    const entries_after = harness.sessions.getEntries();
    try std.testing.expectEqual(@as(usize, 3), entries_after.len);
    const compaction_entry = entries_after[2];
    try expectEntryType(compaction_entry, "compaction");
    try expectEntryJsonStringField(allocator, compaction_entry, "summary", "summary from generated executor");
    try expectEntryJsonStringField(allocator, compaction_entry, "firstKeptEntryId", first_kept_entry_id);
    try expectEntryJsonU64Field(allocator, compaction_entry, "tokensBefore", 333);
    try expectEntryJsonBoolField(allocator, compaction_entry, "fromHook", false);

    var context = try harness.sessions.buildSessionContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expect(context.messages.len >= 1);
    try std.testing.expectEqual(ObservedRole.compaction_summary, observedRole(context.messages[0]));
    try std.testing.expectEqualStrings("summary from generated executor", context.messages[0].compaction_summary.summary);

    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .manual },
        .{ .event = .end, .reason = .manual, .aborted = false, .will_retry = false, .summary = .other },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items);
}

test "AgentSession replay generated compact lets extension-provided summary win" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var handler_arena = std.heap.ArenaAllocator.init(allocator);
    defer handler_arena.deinit();
    var extension_state = CompactExtensionState{
        .allocator = handler_arena.allocator(),
        .summary = "summary from extension",
    };
    const handlers = [_]extensions.ExtensionHandler{
        .{
            .ptr = &extension_state,
            .event_name = .session_before_compact,
            .handler_fn = CompactExtensionState.handler,
        },
        .{
            .ptr = &extension_state,
            .event_name = .session_compact,
            .handler_fn = CompactExtensionState.handler,
        },
    };
    const registered_extensions = [_]extensions.Extension{testExtension("/tmp/session-compact-generated-override.zig", &handlers)};
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &registered_extensions,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantMessage(&assistant_content, .stop)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 123);

    const entries_before = harness.sessions.getEntries();
    const first_kept_entry_id = entries_before[0].id.?;
    var signal: ai.AbortSignal = .{};
    var preparation = compaction_mod.CompactionPreparation{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .first_kept_entry_id = first_kept_entry_id,
        .messages_to_summarize = replay.messages.items,
        .turn_prefix_messages = &.{},
        .is_split_turn = false,
        .tokens_before = 444,
        .settings = .{ .reserve_tokens = 1024, .keep_recent_tokens = 1 },
    };
    defer preparation.deinit();
    var summary_state = GeneratedSummaryState{ .summary = "unused generated summary" };

    const result = try replay.compactWithGeneratedSummary(
        std.testing.io,
        &preparation,
        sessionCompactionModel(),
        .{ .api_key = "test-key", .signal = &signal },
        summary_state.executor(),
        .manual,
        false,
    );

    try std.testing.expectEqualStrings("summary from extension", result.summary);
    try std.testing.expectEqual(@as(usize, 0), summary_state.calls);
    try std.testing.expectEqual(@as(usize, 1), extension_state.before_calls);
    try std.testing.expectEqual(@as(usize, 1), extension_state.compact_calls);
    try std.testing.expectEqual(true, extension_state.seen_from_extension.?);
    const compaction_entry = harness.sessions.getEntries()[2];
    try expectEntryJsonBoolField(allocator, compaction_entry, "fromHook", true);
}

test "AgentSession replay auto-compaction returns true when queued messages should resume" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantUsageMessage(&assistant_content, .stop, 20_000, 200)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 100);
    try replay.followUp("queued custom", 300);

    var summary_state = GeneratedSummaryState{ .summary = "threshold summary" };
    replay.setAutoCompaction(.{
        .model = sessionCompactionModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 1_000, .keep_recent_tokens = 1 },
        .request_options = .{ .api_key = "test-key" },
    });

    try std.testing.expect(try replay.runAutoCompaction(std.testing.io, .threshold, false));
    try std.testing.expectEqual(@as(usize, 1), replay.pendingMessageCount());
    try std.testing.expectEqual(@as(usize, 1), summary_state.calls);

    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .threshold },
        .{ .event = .end, .reason = .threshold, .aborted = false, .will_retry = false, .summary = .other },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items[public_events.items.len - 2 ..]);
}

test "AgentSession replay auto-compaction resolves registry auth for built-in summary streams" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    try harness.storage.setApiKey("openai", "stored-key");

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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantUsageMessage(&assistant_content, .stop, 20_000, 200)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 100);

    const model_headers = [_]ai.Header{.{ .name = "X-Bulb-Test", .value = "from-model" }};
    var model = sessionCompactionModel();
    model.headers = &model_headers;
    var summary_state = GeneratedSummaryState{
        .summary = "registry-auth summary",
        .expected_api_key = "stored-key",
        .expected_header_name = "X-Bulb-Test",
        .expected_header_value = "from-model",
    };
    replay.setAutoCompaction(.{
        .model = model,
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 1_000, .keep_recent_tokens = 1 },
        .auth_resolver = .{ .registry = harness.registry, .mode = .require_api_key },
    });

    try std.testing.expect(!try replay.runAutoCompaction(std.testing.io, .threshold, false));
    try std.testing.expectEqual(@as(usize, 1), summary_state.calls);
    try std.testing.expect(summary_state.saw_expected_api_key);
    try std.testing.expect(summary_state.saw_expected_header);
    try expectEntryType(harness.sessions.getEntries()[2], "compaction");

    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .threshold },
        .{ .event = .end, .reason = .threshold, .aborted = false, .will_retry = false, .summary = .other },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items);
}

test "AgentSession replay auto-compaction skips built-in summary when auth is missing" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantUsageMessage(&assistant_content, .stop, 20_000, 200)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 100);

    var summary_state = GeneratedSummaryState{ .summary = "should not run" };
    replay.setAutoCompaction(.{
        .model = sessionCompactionModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 1_000, .keep_recent_tokens = 1 },
        .auth_resolver = .{ .registry = harness.registry, .mode = .require_api_key },
    });

    try std.testing.expect(!try replay.runAutoCompaction(std.testing.io, .threshold, false));
    try std.testing.expectEqual(@as(usize, 0), summary_state.calls);
    try std.testing.expectEqual(@as(usize, 2), harness.sessions.getEntries().len);

    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .threshold },
        .{ .event = .end, .reason = .threshold, .aborted = false, .will_retry = false },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items);
}

test "AgentSession replay auto-compaction allows injected summaries without auth" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantUsageMessage(&assistant_content, .stop, 20_000, 200)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 100);

    var summary_state = GeneratedSummaryState{ .summary = "optional-auth summary" };
    replay.setAutoCompaction(.{
        .model = sessionCompactionModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 1_000, .keep_recent_tokens = 1 },
        .auth_resolver = .{ .registry = harness.registry, .mode = .optional },
    });

    try std.testing.expect(!try replay.runAutoCompaction(std.testing.io, .threshold, false));
    try std.testing.expectEqual(@as(usize, 1), summary_state.calls);
    try std.testing.expect(summary_state.seen_api_key == null);
    try expectEntryType(harness.sessions.getEntries()[2], "compaction");

    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .threshold },
        .{ .event = .end, .reason = .threshold, .aborted = false, .will_retry = false, .summary = .other },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items);
}

test "AgentSession replay auto-compaction ignores stale pre-compaction assistant usage" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const stale_content = [_]ai.AssistantContent{.{ .text = .{ .text = "large response before compaction" } }};
    const stale_assistant = assistantUsageMessage(&stale_content, .stop, 610_000, 100);
    const responses = [_]ai.AssistantMessage{stale_assistant};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "before compaction", 50);

    const first_kept_entry_id = harness.sessions.getEntries()[0].id.?;
    _ = try harness.sessions.appendCompactionJson(
        std.testing.io,
        "summary",
        first_kept_entry_id,
        stale_assistant.usage.total_tokens,
        null,
        false,
    );

    var summary_state = GeneratedSummaryState{ .summary = "should not run" };
    replay.setAutoCompaction(.{
        .model = sessionCompactionModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 1_000 },
        .request_options = .{ .api_key = "test-key" },
    });

    try std.testing.expect(!try replay.checkAutoCompaction(std.testing.io, stale_assistant, false));
    try std.testing.expectEqual(@as(usize, 0), summary_state.calls);
    try std.testing.expectEqual(@as(usize, 0), public_events.items.len);
}

test "AgentSession replay auto-compaction thresholds error messages using last successful usage" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const success_content = [_]ai.AssistantContent{.{ .text = .{ .text = "large successful response" } }};
    const error_content = [_]ai.AssistantContent{.{ .text = .{ .text = "" } }};
    const responses = [_]ai.AssistantMessage{
        assistantUsageMessage(&success_content, .stop, 190_000, 200),
        assistantErrorAt(&error_content, "529 overloaded", 400),
    };
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "hello", 100);

    var summary_state = GeneratedSummaryState{ .summary = "error-threshold summary" };
    replay.setAutoCompaction(.{
        .model = sessionCompactionModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 10_000, .keep_recent_tokens = 1 },
        .request_options = .{ .api_key = "test-key" },
    });

    try replay.prompt(std.testing.io, "another prompt", 300);
    try std.testing.expectEqual(@as(usize, 1), summary_state.calls);
    try expectEntryType(harness.sessions.getEntries()[4], "compaction");

    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .threshold },
        .{ .event = .end, .reason = .threshold, .aborted = false, .will_retry = false, .summary = .other },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items);
}

test "AgentSession replay auto-compaction skips error threshold without post-compaction usage" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const error_content = [_]ai.AssistantContent{.{ .text = .{ .text = "" } }};
    const responses = [_]ai.AssistantMessage{assistantErrorAt(&error_content, "529 overloaded", 200)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    var summary_state = GeneratedSummaryState{ .summary = "should not run" };
    replay.setAutoCompaction(.{
        .model = sessionCompactionModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 10_000 },
        .request_options = .{ .api_key = "test-key" },
    });
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "hello", 100);
    try std.testing.expectEqual(@as(usize, 0), summary_state.calls);
    try std.testing.expectEqual(@as(usize, 0), public_events.items.len);
}

test "AgentSession replay auto-compaction ignores kept pre-compaction usage for error threshold" {
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
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const kept_content = [_]ai.AssistantContent{.{ .text = .{ .text = "kept response from before compaction" } }};
    const kept_assistant = assistantUsageMessage(&kept_content, .stop, 190_000, 100);
    const responses = [_]ai.AssistantMessage{kept_assistant};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "before compaction", 50);

    const first_kept_entry_id = harness.sessions.getEntries()[0].id.?;
    _ = try harness.sessions.appendCompactionJson(
        std.testing.io,
        "summary",
        first_kept_entry_id,
        kept_assistant.usage.total_tokens,
        null,
        false,
    );

    const error_content = [_]ai.AssistantContent{.{ .text = .{ .text = "" } }};
    const error_assistant = assistantErrorAt(&error_content, "529 overloaded", 1_000_000);
    try replay.messages.append(allocator, .{ .user = .{
        .content = &[_]ai.UserContent{.{ .text = .{ .text = "new prompt" } }},
        .timestamp_ms = 999_900,
    } });
    try replay.messages.append(allocator, .{ .assistant = error_assistant });

    var summary_state = GeneratedSummaryState{ .summary = "should not run" };
    replay.setAutoCompaction(.{
        .model = sessionCompactionModel(),
        .executor = summary_state.executor(),
        .settings = .{ .reserve_tokens = 10_000 },
        .request_options = .{ .api_key = "test-key" },
    });

    try std.testing.expect(!try replay.checkAutoCompaction(std.testing.io, error_assistant, true));
    try std.testing.expectEqual(@as(usize, 0), summary_state.calls);
    try std.testing.expectEqual(@as(usize, 0), public_events.items.len);
}

test "AgentSession replay compact cancellation stops session_compact and persistence" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var handler_arena = std.heap.ArenaAllocator.init(allocator);
    defer handler_arena.deinit();
    var extension_state = CompactExtensionState{
        .allocator = handler_arena.allocator(),
        .summary = "not used",
        .cancel = true,
    };
    const handlers = [_]extensions.ExtensionHandler{
        .{
            .ptr = &extension_state,
            .event_name = .session_before_compact,
            .handler_fn = CompactExtensionState.handler,
        },
        .{
            .ptr = &extension_state,
            .event_name = .session_compact,
            .handler_fn = CompactExtensionState.handler,
        },
    };
    const registered_extensions = [_]extensions.Extension{testExtension("/tmp/session-compact-cancel.zig", &handlers)};
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &registered_extensions,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var public_events: std.ArrayList(CompactionEventObservation) = .empty;
    defer public_events.deinit(allocator);
    var observer = CompactionEventObserver{ .allocator = allocator, .events = &public_events };
    try bridge.subscribe(.{ .ptr = &observer, .call_fn = CompactionEventObserver.publicListener });

    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "reply" } }};
    const responses = [_]ai.AssistantMessage{assistantMessage(&assistant_content, .stop)};
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = false }, null),
        &.{},
    );
    defer replay.deinit();
    replay.setResponses(&responses);
    try replay.prompt(std.testing.io, "message to compact", 123);

    const entries_before = harness.sessions.getEntries();
    const first_kept_entry_id = entries_before[0].id.?;
    var signal: ai.AbortSignal = .{};

    try std.testing.expectError(
        error.CompactionCancelled,
        replay.compactWithExtension(
            std.testing.io,
            .{
                .first_kept_entry_id = first_kept_entry_id,
                .tokens_before = 222,
            },
            null,
            .manual,
            false,
            &signal,
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), extension_state.before_calls);
    try std.testing.expectEqual(@as(usize, 0), extension_state.compact_calls);
    try std.testing.expectEqual(@as(usize, 2), harness.sessions.getEntries().len);
    const expected_events = [_]CompactionEventObservation{
        .{ .event = .start, .reason = .manual },
        .{
            .event = .end,
            .reason = .manual,
            .aborted = true,
            .will_retry = false,
            .error_kind = .cancelled,
        },
    };
    try std.testing.expectEqualSlices(CompactionEventObservation, &expected_events, public_events.items);
}

test "AgentSession replay waits for retry recovery tool loop before returning" {
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
    var observed_events: std.ArrayList(ReplayEventObservation) = .empty;
    defer observed_events.deinit(allocator);
    var will_retry_flags: std.ArrayList(bool) = .empty;
    defer will_retry_flags.deinit(allocator);
    var update_tags: std.ArrayList(std.meta.Tag(ai.StreamEvent)) = .empty;
    defer update_tags.deinit(allocator);
    var recorder = ReplayEventRecorder{
        .allocator = allocator,
        .events = &observed_events,
        .will_retry_flags = &will_retry_flags,
        .update_tags = &update_tags,
    };
    try bridge.subscribe(.{ .ptr = &recorder, .call_fn = ReplayEventRecorder.publicListener });

    var echo_state = EchoToolState{ .allocator = allocator };
    defer echo_state.deinit();
    const echo_tool = echoTool(&echo_state);
    const replay_tools = [_]tools.tool_registry.AgentTool{echo_tool};

    const tool_content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "echo",
        .arguments_json = "{\"text\":\"hello\"}",
    } }};
    const final_content = [_]ai.AssistantContent{.{ .text = .{ .text = "final answer" } }};
    const follow_up_content = [_]ai.AssistantContent{.{ .text = .{ .text = "follow-up answer" } }};
    const responses = [_]ai.AssistantMessage{
        assistantError("overloaded_error"),
        assistantMessage(&tool_content, .tool_use),
        assistantMessage(&final_content, .stop),
        assistantMessage(&follow_up_content, .stop),
    };
    var replay = AgentSessionReplay.init(
        allocator,
        &bridge,
        &runner,
        harness.sessions,
        AutoRetryController.init(.{ .enabled = true, .max_retries = 3, .base_delay_ms = 1 }, null),
        &replay_tools,
    );
    defer replay.deinit();
    replay.setResponses(&responses);

    try replay.prompt(std.testing.io, "test", 123);
    try replay.prompt(std.testing.io, "follow-up", 124);

    const expected_prefix = [_]ReplayEventObservation{
        .agent_start,
        .turn_start,
        .message_start_user,
        .message_end_user,
        .message_start_assistant,
        .message_end_assistant,
        .turn_end,
        .agent_end,
        .auto_retry_start,
        .agent_start,
        .turn_start,
        .message_start_assistant,
        .message_update,
        .message_end_assistant,
        .auto_retry_end,
        .tool_execution_start_echo,
        .tool_execution_end_echo,
        .message_start_tool_result,
        .message_end_tool_result,
        .turn_end,
        .turn_start,
        .message_start_assistant,
        .message_update,
        .message_end_assistant,
        .turn_end,
        .agent_end,
    };
    try std.testing.expect(observed_events.items.len >= expected_prefix.len);
    try std.testing.expectEqualSlices(
        ReplayEventObservation,
        &expected_prefix,
        observed_events.items[0..expected_prefix.len],
    );
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, will_retry_flags.items[0..2]);
    try std.testing.expectEqualSlices(u64, &[_]u64{1}, replay.retry_sleeps.items);
    try std.testing.expectEqual(@as(usize, 1), echo_state.runs.items.len);
    try std.testing.expectEqualStrings("hello", echo_state.runs.items[0]);
    try std.testing.expect(!replay.is_streaming);
    try std.testing.expect(!replay.isRetrying());
    try std.testing.expectEqual(@as(usize, 0), replay.pendingResponseCount());
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

const SubscriptionTestState = struct {
    bridge: *SessionEventBridge,
    self_handle: ?SessionSubscription = null,
    self_calls: usize = 0,
    other_calls: usize = 0,

    fn selfListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .agent_start => {
                state.self_calls += 1;
                _ = state.bridge.unsubscribe(state.self_handle.?);
            },
            else => {},
        }
    }

    fn otherListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .agent_start => state.other_calls += 1,
            else => {},
        }
    }
};

const ObservedRetryEvent = enum {
    start,
    end,
};

const ObservedRetryFinalError = enum {
    none,
    cancelled,
    other,
};

const RetryObservation = struct {
    event: ObservedRetryEvent,
    attempt: usize,
    max_attempts: usize = 0,
    delay_ms: u64 = 0,
    success: ?bool = null,
    final_error: ObservedRetryFinalError = .none,
};

const RetryObserver = struct {
    allocator: std.mem.Allocator,
    observations: *std.ArrayList(RetryObservation),

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const observer: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .auto_retry_start => |payload| observer.observations.append(observer.allocator, .{
                .event = .start,
                .attempt = payload.attempt,
                .max_attempts = payload.max_attempts,
                .delay_ms = payload.delay_ms,
            }) catch @panic("out of memory"),
            .auto_retry_end => |payload| observer.observations.append(observer.allocator, .{
                .event = .end,
                .attempt = payload.attempt,
                .success = payload.success,
                .final_error = if (payload.final_error) |final_error|
                    if (std.mem.eql(u8, final_error, "Retry cancelled")) .cancelled else .other
                else
                    .none,
            }) catch @panic("out of memory"),
            else => {},
        }
    }
};

const QueueDuringToolState = struct {
    replay: *AgentSessionReplay,
    delivery: CustomMessageDelivery,
    queued_text: []const u8,
    extra_queued_text: ?[]const u8 = null,
    sent: bool = false,
    counts_at_message_start: *std.ArrayList(usize),
    queue_counts: *std.ArrayList(usize),

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .tool_execution_start => {
                if (state.sent) return;
                state.sent = true;
                state.queueText(state.queued_text);
                if (state.extra_queued_text) |extra_text| state.queueText(extra_text);
            },
            .message_start => |payload| {
                const text = userMessageText(payload.message) orelse return;
                if (std.mem.eql(u8, text, state.queued_text) or
                    (state.extra_queued_text != null and std.mem.eql(u8, text, state.extra_queued_text.?)))
                {
                    state.counts_at_message_start.append(
                        state.replay.allocator,
                        state.replay.pendingMessageCount(),
                    ) catch @panic("out of memory");
                }
            },
            .queue_update => |payload| state.queue_counts.append(
                state.replay.allocator,
                payload.steering.len + payload.follow_up.len,
            ) catch @panic("out of memory"),
            else => {},
        }
    }

    fn queueText(self: *@This(), text: []const u8) void {
        switch (self.delivery) {
            .steer => self.replay.steer(text, 124) catch @panic("out of memory"),
            .follow_up => self.replay.followUp(text, 124) catch @panic("out of memory"),
            .next_turn => self.replay.sendCustomTextMessage(
                "queue-test",
                text,
                true,
                null,
                124,
                .next_turn,
            ) catch @panic("out of memory"),
        }
    }
};

const AgentEndFollowUpState = struct {
    replay: ?*AgentSessionReplay = null,
    queued_text: []const u8,
    calls: usize = 0,

    fn handler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = event_value;
        _ = ctx;
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        if (state.calls > 0) return null;
        state.calls += 1;
        try state.replay.?.followUp(state.queued_text, 124);
        return null;
    }
};

const GeneratedSummaryState = struct {
    summary: []const u8,
    calls: usize = 0,
    seen_max_tokens: ?u64 = null,
    seen_api_key: ?[]const u8 = null,
    expected_api_key: ?[]const u8 = null,
    saw_expected_api_key: bool = false,
    expected_header_name: ?[]const u8 = null,
    expected_header_value: ?[]const u8 = null,
    saw_expected_header: bool = false,
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
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        state.calls += 1;
        state.seen_max_tokens = options.base.max_tokens;
        state.seen_api_key = options.base.api_key;
        if (state.expected_api_key) |expected| {
            state.saw_expected_api_key = if (options.base.api_key) |actual|
                std.mem.eql(u8, actual, expected)
            else
                false;
        }
        if (state.expected_header_name) |name| {
            const expected_value = state.expected_header_value orelse "";
            state.saw_expected_header = if (findAiHeader(options.base.headers, name)) |actual|
                std.mem.eql(u8, actual, expected_value)
            else
                false;
        }
        state.content[0] = .{ .text = .{ .text = state.summary } };
        return .{
            .content = state.content[0..],
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .stop_reason = .stop,
        };
    }
};

fn findAiHeader(headers: []const ai.Header, name: []const u8) ?[]const u8 {
    var index = headers.len;
    while (index > 0) {
        index -= 1;
        if (std.ascii.eqlIgnoreCase(headers[index].name, name)) return headers[index].value;
    }
    return null;
}

const CompactExtensionState = struct {
    allocator: std.mem.Allocator,
    summary: []const u8,
    cancel: bool = false,
    before_calls: usize = 0,
    compact_calls: usize = 0,
    seen_branch_entries_len: usize = 0,
    seen_custom_instructions: ?[]const u8 = null,
    seen_first_kept_entry_id: ?[]const u8 = null,
    seen_tokens_before: ?u64 = null,
    seen_from_extension: ?bool = null,

    fn handler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = ctx;
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event_value) {
            .session => |session_event| switch (session_event) {
                .before_compact => |event| return try state.beforeCompact(event),
                .compact => |event| {
                    state.compact_calls += 1;
                    state.seen_from_extension = event.from_extension;
                    return null;
                },
                else => return null,
            },
            else => return null,
        }
    }

    fn beforeCompact(self: *@This(), event: extensions.SessionBeforeCompactEvent) !std.json.Value {
        self.before_calls += 1;
        self.seen_branch_entries_len = event.branch_entries.len;
        self.seen_custom_instructions = event.custom_instructions;
        self.seen_first_kept_entry_id = event.preparation.first_kept_entry_id;
        self.seen_tokens_before = event.preparation.tokens_before;

        var object = std.json.Value{ .object = .empty };
        if (self.cancel) {
            try putJsonBool(self.allocator, &object, "cancel", true);
            return object;
        }

        var compaction = std.json.Value{ .object = .empty };
        try putJsonString(self.allocator, &compaction, "summary", self.summary);
        try putJsonString(self.allocator, &compaction, "firstKeptEntryId", event.preparation.first_kept_entry_id.?);
        try putJsonInt(self.allocator, &compaction, "tokensBefore", @as(i64, @intCast(event.preparation.tokens_before.?)));
        var details = std.json.Value{ .object = .empty };
        try putJsonString(self.allocator, &details, "source", "extension");
        try putJsonValue(self.allocator, &compaction, "details", details);
        try putJsonValue(self.allocator, &object, "compaction", compaction);
        return object;
    }
};

const ObservedCompactionPublicEvent = enum {
    start,
    end,
};

const ObservedCompactionSummary = enum {
    none,
    extension,
    other,
};

const ObservedCompactionError = enum {
    none,
    cancelled,
    other,
};

const CompactionEventObservation = struct {
    event: ObservedCompactionPublicEvent,
    reason: CompactionReason,
    aborted: ?bool = null,
    will_retry: ?bool = null,
    summary: ObservedCompactionSummary = .none,
    error_kind: ObservedCompactionError = .none,
};

const CompactionEventObserver = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList(CompactionEventObservation),

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const observer: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .compaction_start => |payload| observer.events.append(observer.allocator, .{
                .event = .start,
                .reason = payload.reason,
            }) catch @panic("out of memory"),
            .compaction_end => |payload| observer.events.append(observer.allocator, .{
                .event = .end,
                .reason = payload.reason,
                .aborted = payload.aborted,
                .will_retry = payload.will_retry,
                .summary = compactionSummaryKind(payload.result),
                .error_kind = compactionErrorKind(payload.error_message),
            }) catch @panic("out of memory"),
            else => {},
        }
    }
};

fn compactionSummaryKind(result: ?CompactionSessionResult) ObservedCompactionSummary {
    const payload = result orelse return .none;
    if (std.mem.eql(u8, payload.summary, "summary from extension")) return .extension;
    return .other;
}

fn compactionErrorKind(message: ?[]const u8) ObservedCompactionError {
    const error_message = message orelse return .none;
    if (std.mem.eql(u8, error_message, "Compaction cancelled")) return .cancelled;
    return .other;
}

const QueueCommandCallbacks = struct {
    fn command(ptr: ?*anyopaque, args: []const u8, ctx: *extensions.ExtensionCommandContext) !void {
        _ = ptr;
        _ = args;
        _ = ctx;
    }
};

const CommandRunRecorder = struct {
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]u8),

    fn command(ptr: ?*anyopaque, args: []const u8, ctx: *extensions.ExtensionCommandContext) !void {
        _ = ctx;
        const recorder: *@This() = @ptrCast(@alignCast(ptr.?));
        const owned_args = try recorder.allocator.dupe(u8, args);
        errdefer recorder.allocator.free(owned_args);
        try recorder.args.append(recorder.allocator, owned_args);
    }
};

const ExtensionOriginFollowUpState = struct {
    replay: *AgentSessionReplay,
    sent: bool = false,

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .tool_execution_start => {
                if (state.sent) return;
                state.sent = true;
                state.replay.sendUserTextMessage(
                    std.testing.io,
                    "/testcmd queued",
                    124,
                    .follow_up,
                ) catch @panic("out of memory");
            },
            else => {},
        }
    }
};

const QueueUpdateCounter = struct {
    allocator: std.mem.Allocator,
    counts: *std.ArrayList(usize),

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const counter: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .queue_update => |payload| counter.counts.append(
                counter.allocator,
                payload.steering.len + payload.follow_up.len,
            ) catch @panic("out of memory"),
            else => {},
        }
    }
};

const ReplayEventObservation = enum {
    agent_start,
    agent_end,
    auto_retry_start,
    auto_retry_end,
    turn_start,
    turn_end,
    message_start_user,
    message_end_user,
    message_start_assistant,
    message_update,
    message_end_assistant,
    message_start_tool_result,
    message_end_tool_result,
    tool_execution_start_echo,
    tool_execution_end_echo,
    compaction_start,
    compaction_end,
};

const ReplayEventRecorder = struct {
    allocator: std.mem.Allocator,
    events: *std.ArrayList(ReplayEventObservation),
    will_retry_flags: *std.ArrayList(bool),
    update_tags: *std.ArrayList(std.meta.Tag(ai.StreamEvent)),
    update_indexes: ?*std.ArrayList(usize) = null,
    update_deltas: ?*std.ArrayList(ReplayUpdateDeltaKind) = null,

    fn publicListener(ptr: ?*anyopaque, event: SessionEvent) void {
        const recorder: *@This() = @ptrCast(@alignCast(ptr.?));
        switch (event) {
            .agent_start => recorder.append(.agent_start) catch @panic("out of memory"),
            .agent_end => |payload| {
                recorder.append(.agent_end) catch @panic("out of memory");
                recorder.will_retry_flags.append(recorder.allocator, payload.will_retry) catch @panic("out of memory");
            },
            .auto_retry_start => recorder.append(.auto_retry_start) catch @panic("out of memory"),
            .auto_retry_end => recorder.append(.auto_retry_end) catch @panic("out of memory"),
            .compaction_start => recorder.append(.compaction_start) catch @panic("out of memory"),
            .compaction_end => recorder.append(.compaction_end) catch @panic("out of memory"),
            .turn_start => recorder.append(.turn_start) catch @panic("out of memory"),
            .turn_end => recorder.append(.turn_end) catch @panic("out of memory"),
            .message_start => |payload| recorder.append(messageObservation(.start, payload.message) orelse return) catch @panic("out of memory"),
            .message_update => |payload| {
                recorder.update_tags.append(recorder.allocator, std.meta.activeTag(payload.assistant_message_event)) catch @panic("out of memory");
                if (recorder.update_indexes) |indexes| {
                    indexes.append(recorder.allocator, streamEventContentIndex(payload.assistant_message_event)) catch @panic("out of memory");
                }
                if (recorder.update_deltas) |deltas| {
                    deltas.append(recorder.allocator, replayUpdateDeltaKind(payload.assistant_message_event)) catch @panic("out of memory");
                }
                recorder.append(.message_update) catch @panic("out of memory");
            },
            .message_end => |payload| recorder.append(messageObservation(.end, payload.message) orelse return) catch @panic("out of memory"),
            .tool_execution_start => |payload| {
                if (std.mem.eql(u8, payload.tool_name, "echo")) recorder.append(.tool_execution_start_echo) catch @panic("out of memory");
            },
            .tool_execution_end => |payload| {
                if (std.mem.eql(u8, payload.tool_name, "echo")) recorder.append(.tool_execution_end_echo) catch @panic("out of memory");
            },
            .tool_execution_update => {},
            .queue_update => {},
        }
    }

    fn append(self: *@This(), observation: ReplayEventObservation) !void {
        if (observation == .message_update and self.events.items.len > 0) {
            if (self.events.items[self.events.items.len - 1] == .message_update) return;
        }
        try self.events.append(self.allocator, observation);
    }
};

const ReplayUpdateDeltaKind = enum {
    none,
    thinking_plan,
    text_answer,
    tool_args,
    other,
};

fn streamEventContentIndex(event: ai.StreamEvent) usize {
    return switch (event) {
        .text_start => |payload| payload.content_index,
        .text_delta => |payload| payload.content_index,
        .text_end => |payload| payload.content_index,
        .thinking_start => |payload| payload.content_index,
        .thinking_delta => |payload| payload.content_index,
        .thinking_end => |payload| payload.content_index,
        .toolcall_start => |payload| payload.content_index,
        .toolcall_delta => |payload| payload.content_index,
        .toolcall_end => |payload| payload.content_index,
        else => 0,
    };
}

fn replayUpdateDeltaKind(event: ai.StreamEvent) ReplayUpdateDeltaKind {
    return switch (event) {
        .thinking_delta => |payload| replayDeltaTextKind(payload.delta),
        .thinking_end => |payload| replayDeltaTextKind(payload.content),
        .text_delta => |payload| replayDeltaTextKind(payload.delta),
        .text_end => |payload| replayDeltaTextKind(payload.content),
        .toolcall_delta => |payload| replayDeltaTextKind(payload.delta),
        .toolcall_end => |payload| replayDeltaTextKind(payload.tool_call.arguments_json),
        else => .none,
    };
}

fn replayDeltaTextKind(text: []const u8) ReplayUpdateDeltaKind {
    if (std.mem.eql(u8, text, "plan")) return .thinking_plan;
    if (std.mem.eql(u8, text, "answer")) return .text_answer;
    if (std.mem.eql(u8, text, "{\"text\":\"hello\"}")) return .tool_args;
    return .other;
}

const MessageBoundary = enum {
    start,
    end,
};

fn messageObservation(boundary: MessageBoundary, message: messages.CodingAgentMessage) ?ReplayEventObservation {
    return switch (message) {
        .user => if (boundary == .start) .message_start_user else .message_end_user,
        .assistant => if (boundary == .start) .message_start_assistant else .message_end_assistant,
        .tool_result => if (boundary == .start) .message_start_tool_result else .message_end_tool_result,
        else => null,
    };
}

fn expectReplayUserTexts(replay: *const AgentSessionReplay, expected: []const []const u8) !void {
    var index: usize = 0;
    for (replay.messages.items) |message| {
        if (message != .user) continue;
        if (index >= expected.len) return error.UnexpectedUserMessage;
        try std.testing.expectEqualStrings(expected[index], userMessageText(message).?);
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
}

fn expectReplayAssistantTexts(replay: *const AgentSessionReplay, expected: []const []const u8) !void {
    var index: usize = 0;
    for (replay.messages.items) |message| {
        if (message != .assistant) continue;
        if (index >= expected.len) return error.UnexpectedAssistantMessage;
        try std.testing.expectEqualStrings(expected[index], assistantMessageText(message.assistant));
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
}

fn expectReplayRoles(replay: *const AgentSessionReplay, expected: []const ObservedRole) !void {
    try std.testing.expectEqual(expected.len, replay.messages.items.len);
    for (expected, 0..) |role, index| {
        try std.testing.expectEqual(role, observedRole(replay.messages.items[index]));
    }
}

fn assistantMessageText(message: ai.AssistantMessage) []const u8 {
    for (message.content) |content| {
        switch (content) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return "";
}

const EchoToolState = struct {
    allocator: std.mem.Allocator,
    runs: std.ArrayList([]u8) = .empty,

    fn deinit(self: *@This()) void {
        for (self.runs.items) |run| self.allocator.free(run);
        self.runs.deinit(self.allocator);
    }

    fn execute(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        params: std.json.Value,
        execute_options: tools.tool_registry.ToolExecuteOptions,
    ) !tools.tool_registry.ToolExecution {
        _ = io;
        _ = cwd;
        _ = execute_options;
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        const text = jsonObjectString(params, "text") orelse "";

        const recorded = try state.allocator.dupe(u8, text);
        var recorded_registered = false;
        errdefer if (!recorded_registered) state.allocator.free(recorded);
        try state.runs.append(state.allocator, recorded);
        recorded_registered = true;

        const output = try std.fmt.allocPrint(allocator, "echo:{s}", .{text});
        var output_registered = false;
        errdefer if (!output_registered) allocator.free(output);

        const blocks = try allocator.alloc(tools.render_utils.ToolContentBlock, 1);
        errdefer allocator.free(blocks);
        blocks[0] = tools.render_utils.textBlock(output);
        output_registered = true;
        return .{ .success = .{ .content = blocks } };
    }
};

fn echoTool(state: *EchoToolState) tools.tool_registry.AgentTool {
    return .{
        .name = "echo",
        .label = "Echo",
        .description = "Echo text back",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
        .ptr = state,
        .custom_execute_fn = EchoToolState.execute,
    };
}

fn jsonObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn assistantMessage(content: []const ai.AssistantContent, stop_reason: ai.StopReason) ai.AssistantMessage {
    return .{
        .content = content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
        .stop_reason = stop_reason,
    };
}

fn assistantUsageMessage(
    content: []const ai.AssistantContent,
    stop_reason: ai.StopReason,
    total_tokens: u64,
    timestamp_ms: i64,
) ai.AssistantMessage {
    var message = assistantMessage(content, stop_reason);
    message.usage = .{
        .input = total_tokens,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .total_tokens = total_tokens,
        .cost = .{},
    };
    message.timestamp_ms = timestamp_ms;
    return message;
}

fn sessionCompactionModel() ai.Model {
    return .{
        .id = "gpt-test",
        .name = "GPT Test",
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .base_url = "https://example.invalid",
        .context_window = 200_000,
        .max_tokens = 8192,
    };
}

fn assistantErrorAt(
    content: []const ai.AssistantContent,
    error_message: []const u8,
    timestamp_ms: i64,
) ai.AssistantMessage {
    return .{
        .content = content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
        .stop_reason = .@"error",
        .error_message = error_message,
        .timestamp_ms = timestamp_ms,
    };
}

fn assistantError(error_message: []const u8) ai.AssistantMessage {
    return .{
        .content = &.{},
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
        .stop_reason = .@"error",
        .error_message = error_message,
    };
}

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

fn testCommandExtension(path: []const u8, commands: []const extensions.RegisteredCommand) extensions.Extension {
    return .{
        .path = path,
        .resolved_path = path,
        .source_info = source_info.createSyntheticSourceInfo(path, .{ .source = "test" }),
        .commands = commands,
    };
}

fn expectEntryType(entry: session_manager.FileEntry, expected: []const u8) !void {
    const actual = entry.entry_type orelse return error.MissingEntryType;
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectEntryJsonStringField(
    allocator: std.mem.Allocator,
    entry: session_manager.FileEntry,
    key: []const u8,
    expected: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const value = parsed.value.object.get(key) orelse return error.MissingEntryField;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

fn expectEntryJsonU64Field(
    allocator: std.mem.Allocator,
    entry: session_manager.FileEntry,
    key: []const u8,
    expected: u64,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const value = parsed.value.object.get(key) orelse return error.MissingEntryField;
    const actual: u64 = switch (value) {
        .integer => |integer| @intCast(integer),
        else => return error.InvalidEntryField,
    };
    try std.testing.expectEqual(expected, actual);
}

fn expectEntryJsonBoolField(
    allocator: std.mem.Allocator,
    entry: session_manager.FileEntry,
    key: []const u8,
    expected: bool,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const value = parsed.value.object.get(key) orelse return error.MissingEntryField;
    try std.testing.expect(value == .bool);
    try std.testing.expectEqual(expected, value.bool);
}

fn expectEntryJsonNestedStringField(
    allocator: std.mem.Allocator,
    entry: session_manager.FileEntry,
    parent_key: []const u8,
    key: []const u8,
    expected: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const parent = parsed.value.object.get(parent_key) orelse return error.MissingEntryField;
    try std.testing.expect(parent == .object);
    const value = parent.object.get(key) orelse return error.MissingEntryField;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
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
