const std = @import("std");
const ai = @import("bulb_ai");
const bash_executor = @import("bash_executor.zig");
const messages = @import("messages.zig");
const source_info = @import("source_info.zig");
const session_manager = @import("session_manager.zig");
const session_events = @import("session_events.zig");
const session_stats = @import("session_stats.zig");

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const RpcSessionState = struct {
    model: ?*const ai.Model = null,
    thinking_level: ai.ThinkingLevel = .medium,
    is_streaming: bool = false,
    is_compacting: bool = false,
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    session_file: ?[]const u8 = null,
    session_id: []const u8,
    session_name: ?[]const u8 = null,
    auto_compaction_enabled: bool = true,
    message_count: u64 = 0,
    pending_message_count: u64 = 0,
};

pub const RpcSlashCommandSource = enum {
    extension,
    prompt,
    skill,
};

pub const RpcSlashCommand = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    source: RpcSlashCommandSource,
    source_info: source_info.SourceInfo,
};

pub fn thinkingLevelName(level: ai.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

pub fn parseThinkingLevel(value: []const u8) ?ai.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

pub fn queueModeName(mode: QueueMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

pub fn parseQueueMode(value: []const u8) ?QueueMode {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "one-at-a-time")) return .one_at_a_time;
    return null;
}

pub fn successLineAlloc(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    command: []const u8,
    data_json: ?[]const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    if (id) |value| try appendStringField(allocator, &output, &first, "id", value);
    try appendStringField(allocator, &output, &first, "type", "response");
    try appendStringField(allocator, &output, &first, "command", command);
    try appendBoolField(allocator, &output, &first, "success", true);
    if (data_json) |json| try appendRawField(allocator, &output, &first, "data", json);
    try output.append(allocator, '}');
    try output.append(allocator, '\n');
    return output.toOwnedSlice(allocator);
}

pub fn errorLineAlloc(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    command: []const u8,
    message: []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    if (id) |value| try appendStringField(allocator, &output, &first, "id", value);
    try appendStringField(allocator, &output, &first, "type", "response");
    try appendStringField(allocator, &output, &first, "command", command);
    try appendBoolField(allocator, &output, &first, "success", false);
    try appendStringField(allocator, &output, &first, "error", message);
    try output.append(allocator, '}');
    try output.append(allocator, '\n');
    return output.toOwnedSlice(allocator);
}

pub fn stateDataJsonAlloc(allocator: std.mem.Allocator, state: RpcSessionState) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    if (state.model) |model| try appendModelField(allocator, &output, &first, "model", model.*);
    try appendStringField(allocator, &output, &first, "thinkingLevel", thinkingLevelName(state.thinking_level));
    try appendBoolField(allocator, &output, &first, "isStreaming", state.is_streaming);
    try appendBoolField(allocator, &output, &first, "isCompacting", state.is_compacting);
    try appendStringField(allocator, &output, &first, "steeringMode", queueModeName(state.steering_mode));
    try appendStringField(allocator, &output, &first, "followUpMode", queueModeName(state.follow_up_mode));
    if (state.session_file) |session_file| try appendStringField(allocator, &output, &first, "sessionFile", session_file);
    try appendStringField(allocator, &output, &first, "sessionId", state.session_id);
    if (state.session_name) |session_name| try appendStringField(allocator, &output, &first, "sessionName", session_name);
    try appendBoolField(allocator, &output, &first, "autoCompactionEnabled", state.auto_compaction_enabled);
    try appendUnsignedField(allocator, &output, &first, "messageCount", state.message_count);
    try appendUnsignedField(allocator, &output, &first, "pendingMessageCount", state.pending_message_count);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn availableModelsDataJsonAlloc(allocator: std.mem.Allocator, models: []const *const ai.Model) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"models\":[");
    for (models, 0..) |model, index| {
        if (index > 0) try output.append(allocator, ',');
        try appendModelJson(allocator, &output, model.*);
    }
    try output.appendSlice(allocator, "]}");
    return output.toOwnedSlice(allocator);
}

pub fn allModelsDataJsonAlloc(allocator: std.mem.Allocator, models: []const ai.Model) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"models\":[");
    for (models, 0..) |model, index| {
        if (index > 0) try output.append(allocator, ',');
        try appendModelJson(allocator, &output, model);
    }
    try output.appendSlice(allocator, "]}");
    return output.toOwnedSlice(allocator);
}

pub fn modelDataJsonAlloc(allocator: std.mem.Allocator, model: ai.Model) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendModelJson(allocator, &output, model);
    return output.toOwnedSlice(allocator);
}

pub fn cycleModelDataJsonAlloc(
    allocator: std.mem.Allocator,
    model: ?*const ai.Model,
    thinking_level: ai.ThinkingLevel,
) ![]u8 {
    if (model == null) return allocator.dupe(u8, "null");
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    try appendModelField(allocator, &output, &first, "model", model.?.*);
    try appendStringField(allocator, &output, &first, "thinkingLevel", thinkingLevelName(thinking_level));
    try appendBoolField(allocator, &output, &first, "isScoped", false);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn levelDataJsonAlloc(allocator: std.mem.Allocator, level: ai.ThinkingLevel) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"level\":\"{s}\"}}", .{thinkingLevelName(level)});
}

pub fn cancelledDataJsonAlloc(allocator: std.mem.Allocator, cancelled: bool) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"cancelled\":{s}}}", .{if (cancelled) "true" else "false"});
}

pub fn forkDataJsonAlloc(allocator: std.mem.Allocator, selected_text: []const u8, cancelled: bool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    try appendStringField(allocator, &output, &first, "text", selected_text);
    try appendBoolField(allocator, &output, &first, "cancelled", cancelled);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn emptyCommandsDataJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"commands\":[]}");
}

pub fn commandsDataJsonAlloc(
    allocator: std.mem.Allocator,
    commands: []const RpcSlashCommand,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"commands\":[");
    for (commands, 0..) |command, index| {
        if (index > 0) try output.append(allocator, ',');
        try appendRpcSlashCommandJson(allocator, &output, command);
    }
    try output.appendSlice(allocator, "]}");
    return output.toOwnedSlice(allocator);
}

pub fn emptyMessagesDataJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"messages\":[]}");
}

pub fn messagesDataJsonAlloc(
    allocator: std.mem.Allocator,
    values: []const messages.CodingAgentMessage,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"messages\":[");
    for (values, 0..) |message, index| {
        if (index > 0) try output.append(allocator, ',');
        const json = try messageJsonAlloc(allocator, message);
        defer allocator.free(json);
        try output.appendSlice(allocator, json);
    }
    try output.appendSlice(allocator, "]}");
    return output.toOwnedSlice(allocator);
}

fn messageJsonAlloc(
    allocator: std.mem.Allocator,
    message: messages.CodingAgentMessage,
) ![]u8 {
    return switch (message) {
        .branch_summary => |summary| branchSummaryMessageJsonAlloc(allocator, summary),
        .compaction_summary => |summary| compactionSummaryMessageJsonAlloc(allocator, summary),
        else => session_manager.codingAgentMessageJsonAlloc(allocator, message),
    };
}

fn branchSummaryMessageJsonAlloc(
    allocator: std.mem.Allocator,
    message: messages.BranchSummaryMessage,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    try appendStringField(allocator, &output, &first, "role", "branchSummary");
    try appendStringField(allocator, &output, &first, "summary", message.summary);
    try appendStringField(allocator, &output, &first, "fromId", message.from_id);
    try appendSignedField(allocator, &output, &first, "timestamp", message.timestamp_ms);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

fn compactionSummaryMessageJsonAlloc(
    allocator: std.mem.Allocator,
    message: messages.CompactionSummaryMessage,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    try appendStringField(allocator, &output, &first, "role", "compactionSummary");
    try appendStringField(allocator, &output, &first, "summary", message.summary);
    try appendUnsignedField(allocator, &output, &first, "tokensBefore", message.tokens_before);
    try appendSignedField(allocator, &output, &first, "timestamp", message.timestamp_ms);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub const ForkMessage = struct {
    entry_id: []const u8,
    text: []const u8,
};

pub fn forkMessagesDataJsonAlloc(
    allocator: std.mem.Allocator,
    values: []const ForkMessage,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"messages\":[");
    for (values, 0..) |message, index| {
        if (index > 0) try output.append(allocator, ',');
        try output.append(allocator, '{');
        var first = true;
        try appendStringField(allocator, &output, &first, "entryId", message.entry_id);
        try appendStringField(allocator, &output, &first, "text", message.text);
        try output.append(allocator, '}');
    }
    try output.appendSlice(allocator, "]}");
    return output.toOwnedSlice(allocator);
}

pub fn lastAssistantTextDataJsonAlloc(allocator: std.mem.Allocator, text: ?[]const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "{\"text\":");
    if (text) |value| {
        try appendJsonString(allocator, &output, value);
    } else {
        try output.appendSlice(allocator, "null");
    }
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn bashResultDataJsonAlloc(
    allocator: std.mem.Allocator,
    result: bash_executor.BashResult,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    try appendStringField(allocator, &output, &first, "output", result.output);
    try fieldPrefix(allocator, &output, &first, "exitCode");
    if (result.exit_code) |exit_code| {
        try output.print(allocator, "{d}", .{exit_code});
    } else {
        try output.appendSlice(allocator, "null");
    }
    try appendBoolField(allocator, &output, &first, "cancelled", result.cancelled);
    try appendBoolField(allocator, &output, &first, "truncated", result.truncated);
    if (result.full_output_path) |path| try appendStringField(allocator, &output, &first, "fullOutputPath", path);
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn compactionResultDataJsonAlloc(
    allocator: std.mem.Allocator,
    result: session_events.CompactionSessionResult,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendCompactionResultJson(allocator, &output, result);
    return output.toOwnedSlice(allocator);
}

pub fn sessionEventLineAlloc(
    allocator: std.mem.Allocator,
    event: session_events.SessionEvent,
) ![]u8 {
    const json = try sessionEventJsonAlloc(allocator, event);
    defer allocator.free(json);
    return std.fmt.allocPrint(allocator, "{s}\n", .{json});
}

pub fn sessionEventJsonAlloc(
    allocator: std.mem.Allocator,
    event: session_events.SessionEvent,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;

    switch (event) {
        .agent_start => {
            try appendStringField(allocator, &output, &first, "type", "agent_start");
        },
        .agent_end => |payload| {
            try appendStringField(allocator, &output, &first, "type", "agent_end");
            try appendMessagesField(allocator, &output, &first, "messages", payload.messages);
            try appendBoolField(allocator, &output, &first, "willRetry", payload.will_retry);
        },
        .auto_retry_start => |payload| {
            try appendStringField(allocator, &output, &first, "type", "auto_retry_start");
            try appendUnsignedField(allocator, &output, &first, "attempt", payload.attempt);
            try appendUnsignedField(allocator, &output, &first, "maxAttempts", payload.max_attempts);
            try appendUnsignedField(allocator, &output, &first, "delayMs", payload.delay_ms);
            try appendStringField(allocator, &output, &first, "errorMessage", payload.error_message);
        },
        .auto_retry_end => |payload| {
            try appendStringField(allocator, &output, &first, "type", "auto_retry_end");
            try appendBoolField(allocator, &output, &first, "success", payload.success);
            try appendUnsignedField(allocator, &output, &first, "attempt", payload.attempt);
            if (payload.final_error) |message| try appendStringField(allocator, &output, &first, "finalError", message);
        },
        .queue_update => |payload| {
            try appendStringField(allocator, &output, &first, "type", "queue_update");
            try appendStringArrayField(allocator, &output, &first, "steering", payload.steering);
            try appendStringArrayField(allocator, &output, &first, "followUp", payload.follow_up);
        },
        .compaction_start => |payload| {
            try appendStringField(allocator, &output, &first, "type", "compaction_start");
            try appendStringField(allocator, &output, &first, "reason", compactionReasonName(payload.reason));
        },
        .compaction_end => |payload| {
            try appendStringField(allocator, &output, &first, "type", "compaction_end");
            try appendStringField(allocator, &output, &first, "reason", compactionReasonName(payload.reason));
            if (payload.result) |result| try appendCompactionResultField(allocator, &output, &first, "result", result);
            try appendBoolField(allocator, &output, &first, "aborted", payload.aborted);
            try appendBoolField(allocator, &output, &first, "willRetry", payload.will_retry);
            if (payload.error_message) |message| try appendStringField(allocator, &output, &first, "errorMessage", message);
        },
        .turn_start => {
            try appendStringField(allocator, &output, &first, "type", "turn_start");
        },
        .turn_end => |payload| {
            try appendStringField(allocator, &output, &first, "type", "turn_end");
            try appendMessageField(allocator, &output, &first, "message", payload.message);
            try appendToolResultsField(allocator, &output, &first, "toolResults", payload.tool_results);
        },
        .message_start => |payload| {
            try appendStringField(allocator, &output, &first, "type", "message_start");
            try appendMessageField(allocator, &output, &first, "message", payload.message);
        },
        .message_update => |payload| {
            try appendStringField(allocator, &output, &first, "type", "message_update");
            try appendMessageField(allocator, &output, &first, "message", payload.message);
            try appendStreamEventField(allocator, &output, &first, "assistantMessageEvent", payload.message, payload.assistant_message_event);
        },
        .message_end => |payload| {
            try appendStringField(allocator, &output, &first, "type", "message_end");
            try appendMessageField(allocator, &output, &first, "message", payload.message);
        },
        .tool_execution_start => |payload| {
            try appendStringField(allocator, &output, &first, "type", "tool_execution_start");
            try appendStringField(allocator, &output, &first, "toolCallId", payload.tool_call_id);
            try appendStringField(allocator, &output, &first, "toolName", payload.tool_name);
            try appendJsonValueField(allocator, &output, &first, "args", payload.args);
        },
        .tool_execution_update => |payload| {
            try appendStringField(allocator, &output, &first, "type", "tool_execution_update");
            try appendStringField(allocator, &output, &first, "toolCallId", payload.tool_call_id);
            try appendStringField(allocator, &output, &first, "toolName", payload.tool_name);
            try appendJsonValueField(allocator, &output, &first, "args", payload.args);
            try appendJsonValueField(allocator, &output, &first, "partialResult", payload.partial_result);
        },
        .tool_execution_end => |payload| {
            try appendStringField(allocator, &output, &first, "type", "tool_execution_end");
            try appendStringField(allocator, &output, &first, "toolCallId", payload.tool_call_id);
            try appendStringField(allocator, &output, &first, "toolName", payload.tool_name);
            try appendJsonValueField(allocator, &output, &first, "result", payload.result);
            try appendBoolField(allocator, &output, &first, "isError", payload.is_error);
        },
    }

    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

pub fn sessionStatsDataJsonAlloc(
    allocator: std.mem.Allocator,
    stats: session_stats.SessionStats,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    var first = true;
    if (stats.session_file) |session_file| try appendStringField(allocator, &output, &first, "sessionFile", session_file);
    try appendStringField(allocator, &output, &first, "sessionId", stats.session_id);
    try appendUnsignedField(allocator, &output, &first, "userMessages", stats.user_messages);
    try appendUnsignedField(allocator, &output, &first, "assistantMessages", stats.assistant_messages);
    try appendUnsignedField(allocator, &output, &first, "toolCalls", stats.tool_calls);
    try appendUnsignedField(allocator, &output, &first, "toolResults", stats.tool_results);
    try appendUnsignedField(allocator, &output, &first, "totalMessages", stats.total_messages);
    try fieldPrefix(allocator, &output, &first, "tokens");
    try output.append(allocator, '{');
    var tokens_first = true;
    try appendUnsignedField(allocator, &output, &tokens_first, "input", stats.tokens.input);
    try appendUnsignedField(allocator, &output, &tokens_first, "output", stats.tokens.output);
    try appendUnsignedField(allocator, &output, &tokens_first, "cacheRead", stats.tokens.cache_read);
    try appendUnsignedField(allocator, &output, &tokens_first, "cacheWrite", stats.tokens.cache_write);
    try appendUnsignedField(allocator, &output, &tokens_first, "total", stats.tokens.total);
    try output.append(allocator, '}');
    try appendFloatField(allocator, &output, &first, "cost", stats.cost);
    if (stats.context_usage) |usage| {
        try fieldPrefix(allocator, &output, &first, "contextUsage");
        try output.append(allocator, '{');
        var usage_first = true;
        try appendOptionalUnsignedField(allocator, &output, &usage_first, "tokens", usage.tokens);
        try appendUnsignedField(allocator, &output, &usage_first, "contextWindow", usage.context_window);
        try appendOptionalFloatField(allocator, &output, &usage_first, "percent", usage.percent);
        try output.append(allocator, '}');
    }
    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

fn appendMessagesField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    values: []const messages.CodingAgentMessage,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.append(allocator, '[');
    for (values, 0..) |message, index| {
        if (index > 0) try output.append(allocator, ',');
        const json = try messageJsonAlloc(allocator, message);
        defer allocator.free(json);
        try output.appendSlice(allocator, json);
    }
    try output.append(allocator, ']');
}

fn appendMessageField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    message: messages.CodingAgentMessage,
) !void {
    try fieldPrefix(allocator, output, first, key);
    const json = try messageJsonAlloc(allocator, message);
    defer allocator.free(json);
    try output.appendSlice(allocator, json);
}

fn appendToolResultsField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    values: []const ai.ToolResultMessage,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.append(allocator, '[');
    for (values, 0..) |tool_result, index| {
        if (index > 0) try output.append(allocator, ',');
        const json = try messageJsonAlloc(allocator, .{ .tool_result = tool_result });
        defer allocator.free(json);
        try output.appendSlice(allocator, json);
    }
    try output.append(allocator, ']');
}

fn appendStreamEventField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    message: messages.CodingAgentMessage,
    event: ai.StreamEvent,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try streamEventJson(allocator, output, message, event);
}

fn streamEventJson(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: messages.CodingAgentMessage,
    event: ai.StreamEvent,
) !void {
    try output.append(allocator, '{');
    var first = true;
    switch (event) {
        .start => {
            try appendStringField(allocator, output, &first, "type", "start");
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .text_start => |payload| {
            try appendStringField(allocator, output, &first, "type", "text_start");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .text_delta => |payload| {
            try appendStringField(allocator, output, &first, "type", "text_delta");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendStringField(allocator, output, &first, "delta", payload.delta);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .text_end => |payload| {
            try appendStringField(allocator, output, &first, "type", "text_end");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendStringField(allocator, output, &first, "content", payload.content);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .thinking_start => |payload| {
            try appendStringField(allocator, output, &first, "type", "thinking_start");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .thinking_delta => |payload| {
            try appendStringField(allocator, output, &first, "type", "thinking_delta");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendStringField(allocator, output, &first, "delta", payload.delta);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .thinking_end => |payload| {
            try appendStringField(allocator, output, &first, "type", "thinking_end");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendStringField(allocator, output, &first, "content", payload.content);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .toolcall_start => |payload| {
            try appendStringField(allocator, output, &first, "type", "toolcall_start");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .toolcall_delta => |payload| {
            try appendStringField(allocator, output, &first, "type", "toolcall_delta");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendStringField(allocator, output, &first, "delta", payload.delta);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .toolcall_end => |payload| {
            try appendStringField(allocator, output, &first, "type", "toolcall_end");
            try appendUnsignedField(allocator, output, &first, "contentIndex", payload.content_index);
            try appendToolCallField(allocator, output, &first, "toolCall", payload.tool_call);
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .done => |reason| {
            try appendStringField(allocator, output, &first, "type", "done");
            try appendStringField(allocator, output, &first, "reason", stopReasonName(reason));
            try appendMessageField(allocator, output, &first, "partial", message);
        },
        .@"error" => |payload| {
            try appendStringField(allocator, output, &first, "type", "error");
            try appendStringField(allocator, output, &first, "reason", stopReasonName(payload.reason));
            try appendMessageField(allocator, output, &first, "message", .{ .assistant = payload.message });
            try appendMessageField(allocator, output, &first, "partial", message);
        },
    }
    try output.append(allocator, '}');
}

fn appendToolCallField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    tool_call: ai.ToolCall,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.append(allocator, '{');
    var tool_first = true;
    try appendStringField(allocator, output, &tool_first, "id", tool_call.id);
    try appendStringField(allocator, output, &tool_first, "name", tool_call.name);
    try appendJsonOrStringField(allocator, output, &tool_first, "arguments", tool_call.arguments_json);
    if (tool_call.thought_signature) |signature| try appendStringField(allocator, output, &tool_first, "thoughtSignature", signature);
    try output.append(allocator, '}');
}

fn appendCompactionResultField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    result: session_events.CompactionSessionResult,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try appendCompactionResultJson(allocator, output, result);
}

fn appendCompactionResultJson(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    result: session_events.CompactionSessionResult,
) !void {
    try output.append(allocator, '{');
    var result_first = true;
    try appendStringField(allocator, output, &result_first, "summary", result.summary);
    try appendStringField(allocator, output, &result_first, "firstKeptEntryId", result.first_kept_entry_id);
    try appendUnsignedField(allocator, output, &result_first, "tokensBefore", result.tokens_before);
    if (result.details_json) |details| try appendJsonOrStringField(allocator, output, &result_first, "details", details);
    try output.append(allocator, '}');
}

fn appendModelField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    model: ai.Model,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try appendModelJson(allocator, output, model);
}

fn appendModelJson(allocator: std.mem.Allocator, output: *std.ArrayList(u8), model: ai.Model) !void {
    try output.append(allocator, '{');
    var first = true;
    try appendStringField(allocator, output, &first, "id", model.id);
    try appendStringField(allocator, output, &first, "name", model.name);
    try appendStringField(allocator, output, &first, "api", model.api);
    try appendStringField(allocator, output, &first, "provider", model.provider);
    try appendStringField(allocator, output, &first, "baseUrl", model.base_url);
    try appendBoolField(allocator, output, &first, "reasoning", model.reasoning);
    if (thinkingLevelMapHasValues(model.thinking_level_map)) try appendThinkingLevelMapField(allocator, output, &first, model.thinking_level_map);
    try appendStringArrayField(allocator, output, &first, "input", model.input);
    try appendCostField(allocator, output, &first, model.cost);
    try appendUnsignedField(allocator, output, &first, "contextWindow", model.context_window);
    try appendUnsignedField(allocator, output, &first, "maxTokens", model.max_tokens);
    if (model.headers.len > 0) try appendHeadersField(allocator, output, &first, model.headers);
    if (compatHasValues(model.compat)) try appendCompatField(allocator, output, &first, model.compat);
    try output.append(allocator, '}');
}

fn appendCostField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    cost: ai.ModelCost,
) !void {
    try fieldPrefix(allocator, output, first, "cost");
    try output.append(allocator, '{');
    var cost_first = true;
    try appendFloatField(allocator, output, &cost_first, "input", cost.input);
    try appendFloatField(allocator, output, &cost_first, "output", cost.output);
    try appendFloatField(allocator, output, &cost_first, "cacheRead", cost.cache_read);
    try appendFloatField(allocator, output, &cost_first, "cacheWrite", cost.cache_write);
    try output.append(allocator, '}');
}

fn appendThinkingLevelMapField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    map: ai.ThinkingLevelMap,
) !void {
    try fieldPrefix(allocator, output, first, "thinkingLevelMap");
    try output.append(allocator, '{');
    var map_first = true;
    try appendThinkingLevelOverrideField(allocator, output, &map_first, "off", map.off);
    try appendThinkingLevelOverrideField(allocator, output, &map_first, "minimal", map.minimal);
    try appendThinkingLevelOverrideField(allocator, output, &map_first, "low", map.low);
    try appendThinkingLevelOverrideField(allocator, output, &map_first, "medium", map.medium);
    try appendThinkingLevelOverrideField(allocator, output, &map_first, "high", map.high);
    try appendThinkingLevelOverrideField(allocator, output, &map_first, "xhigh", map.xhigh);
    try output.append(allocator, '}');
}

fn appendThinkingLevelOverrideField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: ai.ThinkingLevelOverride,
) !void {
    switch (value) {
        .unset => {},
        .unsupported => try appendRawField(allocator, output, first, key, "null"),
        .mapped => |mapped| try appendStringField(allocator, output, first, key, mapped),
    }
}

fn appendHeadersField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    headers: []const ai.Header,
) !void {
    try fieldPrefix(allocator, output, first, "headers");
    try output.append(allocator, '{');
    var header_first = true;
    for (headers) |header| try appendStringField(allocator, output, &header_first, header.name, header.value);
    try output.append(allocator, '}');
}

fn appendCompatField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    compat: ai.ModelCompat,
) !void {
    try fieldPrefix(allocator, output, first, "compat");
    try output.append(allocator, '{');
    var compat_first = true;
    if (compat.supports_store) |value| try appendBoolField(allocator, output, &compat_first, "supportsStore", value);
    if (compat.supports_developer_role) |value| try appendBoolField(allocator, output, &compat_first, "supportsDeveloperRole", value);
    if (compat.supports_reasoning_effort) |value| try appendBoolField(allocator, output, &compat_first, "supportsReasoningEffort", value);
    if (compat.supports_usage_in_streaming) |value| try appendBoolField(allocator, output, &compat_first, "supportsUsageInStreaming", value);
    if (compat.max_tokens_field) |value| try appendStringField(allocator, output, &compat_first, "maxTokensField", maxTokensFieldName(value));
    if (compat.requires_tool_result_name) |value| try appendBoolField(allocator, output, &compat_first, "requiresToolResultName", value);
    if (compat.requires_assistant_after_tool_result) |value| try appendBoolField(allocator, output, &compat_first, "requiresAssistantAfterToolResult", value);
    if (compat.requires_thinking_as_text) |value| try appendBoolField(allocator, output, &compat_first, "requiresThinkingAsText", value);
    if (compat.requires_reasoning_content_on_assistant_messages) |value| try appendBoolField(allocator, output, &compat_first, "requiresReasoningContentOnAssistantMessages", value);
    if (compat.thinking_format) |value| try appendStringField(allocator, output, &compat_first, "thinkingFormat", thinkingFormatName(value));
    if (compat.cache_control_format) |value| try appendStringField(allocator, output, &compat_first, "cacheControlFormat", value);
    if (compat.open_router_routing_json) |value| try appendJsonOrStringField(allocator, output, &compat_first, "openRouterRouting", value);
    if (compat.vercel_gateway_routing_json) |value| try appendJsonOrStringField(allocator, output, &compat_first, "vercelGatewayRouting", value);
    if (compat.zai_tool_stream) |value| try appendBoolField(allocator, output, &compat_first, "zaiToolStream", value);
    if (compat.supports_strict_mode) |value| try appendBoolField(allocator, output, &compat_first, "supportsStrictMode", value);
    if (compat.send_session_affinity_headers) |value| try appendBoolField(allocator, output, &compat_first, "sendSessionAffinityHeaders", value);
    if (compat.send_session_id_header) |value| try appendBoolField(allocator, output, &compat_first, "sendSessionIdHeader", value);
    if (compat.supports_long_cache_retention) |value| try appendBoolField(allocator, output, &compat_first, "supportsLongCacheRetention", value);
    if (compat.supports_eager_tool_input_streaming) |value| try appendBoolField(allocator, output, &compat_first, "supportsEagerToolInputStreaming", value);
    if (compat.supports_cache_control_on_tools) |value| try appendBoolField(allocator, output, &compat_first, "supportsCacheControlOnTools", value);
    if (compat.supports_temperature) |value| try appendBoolField(allocator, output, &compat_first, "supportsTemperature", value);
    if (compat.force_adaptive_thinking) |value| try appendBoolField(allocator, output, &compat_first, "forceAdaptiveThinking", value);
    if (compat.allow_empty_signature) |value| try appendBoolField(allocator, output, &compat_first, "allowEmptySignature", value);
    try output.append(allocator, '}');
}

fn appendStringArrayField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    values: []const []const u8,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index > 0) try output.append(allocator, ',');
        try appendJsonString(allocator, output, value);
    }
    try output.append(allocator, ']');
}

fn appendRpcSlashCommandJson(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    command: RpcSlashCommand,
) !void {
    try output.append(allocator, '{');
    var first = true;
    try appendStringField(allocator, output, &first, "name", command.name);
    if (command.description) |description| try appendStringField(allocator, output, &first, "description", description);
    try appendStringField(allocator, output, &first, "source", slashCommandSourceName(command.source));
    try appendSourceInfoField(allocator, output, &first, "sourceInfo", command.source_info);
    try output.append(allocator, '}');
}

fn appendSourceInfoField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    info: source_info.SourceInfo,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.append(allocator, '{');
    var info_first = true;
    try appendStringField(allocator, output, &info_first, "path", info.path);
    try appendStringField(allocator, output, &info_first, "source", info.source);
    try appendStringField(allocator, output, &info_first, "scope", sourceScopeName(info.scope));
    try appendStringField(allocator, output, &info_first, "origin", sourceOriginName(info.origin));
    if (info.base_dir) |base_dir| try appendStringField(allocator, output, &info_first, "baseDir", base_dir);
    try output.append(allocator, '}');
}

fn appendStringField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try appendJsonString(allocator, output, value);
}

fn appendBoolField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: bool,
) !void {
    try appendRawField(allocator, output, first, key, if (value) "true" else "false");
}

fn appendUnsignedField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: anytype,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.print(allocator, "{d}", .{value});
}

fn appendSignedField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: i64,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.print(allocator, "{d}", .{value});
}

fn appendFloatField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: f64,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try appendJsonValueAlloc(allocator, output, value);
}

fn appendOptionalUnsignedField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: ?u64,
) !void {
    if (value) |number| {
        try appendUnsignedField(allocator, output, first, key, number);
    } else {
        try appendRawField(allocator, output, first, key, "null");
    }
}

fn appendOptionalFloatField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: ?f64,
) !void {
    if (value) |number| {
        try appendFloatField(allocator, output, first, key, number);
    } else {
        try appendRawField(allocator, output, first, key, "null");
    }
}

fn appendJsonOrStringField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    raw_json: []const u8,
) !void {
    try fieldPrefix(allocator, output, first, key);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch {
        try appendJsonString(allocator, output, raw_json);
        return;
    };
    defer parsed.deinit();
    const json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    defer allocator.free(json);
    try output.appendSlice(allocator, json);
}

fn appendJsonValueField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    value: std.json.Value,
) !void {
    try fieldPrefix(allocator, output, first, key);
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    try output.appendSlice(allocator, json);
}

fn appendRawField(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
    raw_json: []const u8,
) !void {
    try fieldPrefix(allocator, output, first, key);
    try output.appendSlice(allocator, raw_json);
}

fn fieldPrefix(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    first: *bool,
    key: []const u8,
) !void {
    if (!first.*) try output.append(allocator, ',');
    first.* = false;
    try appendJsonString(allocator, output, key);
    try output.append(allocator, ':');
}

fn appendJsonString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    try appendJsonValueAlloc(allocator, output, value);
}

fn appendJsonValueAlloc(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    try output.appendSlice(allocator, json);
}

fn slashCommandSourceName(source: RpcSlashCommandSource) []const u8 {
    return switch (source) {
        .extension => "extension",
        .prompt => "prompt",
        .skill => "skill",
    };
}

fn sourceScopeName(scope: source_info.SourceScope) []const u8 {
    return switch (scope) {
        .user => "user",
        .project => "project",
        .temporary => "temporary",
    };
}

fn sourceOriginName(origin: source_info.SourceOrigin) []const u8 {
    return switch (origin) {
        .package => "package",
        .top_level => "top-level",
    };
}

fn thinkingLevelMapHasValues(map: ai.ThinkingLevelMap) bool {
    return map.off != .unset or
        map.minimal != .unset or
        map.low != .unset or
        map.medium != .unset or
        map.high != .unset or
        map.xhigh != .unset;
}

fn stopReasonName(reason: ai.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .@"error" => "error",
        .aborted => "aborted",
    };
}

fn compactionReasonName(reason: session_events.CompactionReason) []const u8 {
    return switch (reason) {
        .manual => "manual",
        .threshold => "threshold",
        .overflow => "overflow",
    };
}

fn compatHasValues(compat: ai.ModelCompat) bool {
    return compat.supports_store != null or
        compat.supports_developer_role != null or
        compat.supports_reasoning_effort != null or
        compat.supports_usage_in_streaming != null or
        compat.max_tokens_field != null or
        compat.requires_tool_result_name != null or
        compat.requires_assistant_after_tool_result != null or
        compat.requires_thinking_as_text != null or
        compat.requires_reasoning_content_on_assistant_messages != null or
        compat.thinking_format != null or
        compat.cache_control_format != null or
        compat.open_router_routing_json != null or
        compat.vercel_gateway_routing_json != null or
        compat.zai_tool_stream != null or
        compat.supports_strict_mode != null or
        compat.send_session_affinity_headers != null or
        compat.send_session_id_header != null or
        compat.supports_long_cache_retention != null or
        compat.supports_eager_tool_input_streaming != null or
        compat.supports_cache_control_on_tools != null or
        compat.supports_temperature != null or
        compat.force_adaptive_thinking != null or
        compat.allow_empty_signature != null;
}

fn maxTokensFieldName(value: ai.MaxTokensField) []const u8 {
    return switch (value) {
        .max_completion_tokens => "max_completion_tokens",
        .max_tokens => "max_tokens",
    };
}

fn thinkingFormatName(value: ai.ThinkingFormat) []const u8 {
    return switch (value) {
        .openai => "openai",
        .openrouter => "openrouter",
        .deepseek => "deepseek",
        .together => "together",
        .zai => "zai",
        .qwen => "qwen",
        .qwen_chat_template => "qwen-chat-template",
        .string_thinking => "string-thinking",
    };
}

test "RPC commands JSON serializes slash commands and source info" {
    const allocator = std.testing.allocator;
    const commands = [_]RpcSlashCommand{
        .{
            .name = "ask:1",
            .description = "Ask extension",
            .source = .extension,
            .source_info = source_info.createSyntheticSourceInfo("/tmp/ext.zig", .{
                .source = "extension:test",
                .scope = .project,
                .origin = .package,
                .base_dir = "/tmp",
            }),
        },
        .{
            .name = "daily",
            .source = .prompt,
            .source_info = source_info.createSyntheticSourceInfo("/tmp/daily.md", .{
                .source = "cli",
            }),
        },
        .{
            .name = "skill:debug",
            .description = "Debug things",
            .source = .skill,
            .source_info = source_info.createSyntheticSourceInfo("/tmp/debug/SKILL.md", .{
                .source = "local",
                .scope = .user,
            }),
        },
    };

    const json = try commandsDataJsonAlloc(allocator, &commands);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const array = parsed.value.object.get("commands").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), array.len);
    try std.testing.expectEqualStrings("ask:1", array[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("extension", array[0].object.get("source").?.string);
    try std.testing.expectEqualStrings("project", array[0].object.get("sourceInfo").?.object.get("scope").?.string);
    try std.testing.expectEqualStrings("package", array[0].object.get("sourceInfo").?.object.get("origin").?.string);
    try std.testing.expectEqualStrings("/tmp", array[0].object.get("sourceInfo").?.object.get("baseDir").?.string);
    try std.testing.expect(array[1].object.get("description") == null);
    try std.testing.expect(array[1].object.get("sourceInfo").?.object.get("baseDir") == null);
    try std.testing.expectEqualStrings("skill:debug", array[2].object.get("name").?.string);
    try std.testing.expectEqualStrings("skill", array[2].object.get("source").?.string);
}

test "RPC model JSON uses Pi-compatible camelCase fields" {
    const allocator = std.testing.allocator;
    const model: ai.Model = .{
        .id = "demo",
        .name = "Demo",
        .api = ai.types.api.openai_completions,
        .provider = "demo-provider",
        .base_url = "https://example.com/v1",
        .reasoning = true,
        .thinking_level_map = .{ .minimal = .unsupported, .high = .{ .mapped = "max" } },
        .input = &.{"text"},
        .cost = .{ .input = 1, .output = 2, .cache_read = 3, .cache_write = 4 },
        .context_window = 1000,
        .max_tokens = 100,
        .headers = &.{.{ .name = "X-Test", .value = "yes" }},
        .compat = .{
            .supports_usage_in_streaming = false,
            .max_tokens_field = .max_completion_tokens,
            .cache_control_format = "anthropic",
        },
    };

    const json = try modelDataJsonAlloc(allocator, model);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const object = parsed.value.object;
    try std.testing.expectEqualStrings("https://example.com/v1", object.get("baseUrl").?.string);
    try std.testing.expectEqual(@as(i64, 1000), object.get("contextWindow").?.integer);
    try std.testing.expectEqual(@as(i64, 100), object.get("maxTokens").?.integer);
    try std.testing.expectEqual(.null, object.get("thinkingLevelMap").?.object.get("minimal").?);
    try std.testing.expectEqualStrings("max", object.get("thinkingLevelMap").?.object.get("high").?.string);
    try std.testing.expectEqualStrings("yes", object.get("headers").?.object.get("X-Test").?.string);
    try std.testing.expectEqual(false, object.get("compat").?.object.get("supportsUsageInStreaming").?.bool);
    try std.testing.expectEqualStrings("max_completion_tokens", object.get("compat").?.object.get("maxTokensField").?.string);
}

test "RPC message JSON serializes context-only summary roles" {
    const allocator = std.testing.allocator;
    const values = [_]messages.CodingAgentMessage{
        .{ .branch_summary = .{
            .summary = "alternate branch",
            .from_id = "entry-1",
            .timestamp_ms = 10,
        } },
        .{ .compaction_summary = .{
            .summary = "old context",
            .tokens_before = 123,
            .timestamp_ms = 20,
        } },
    };

    const json = try messagesDataJsonAlloc(allocator, &values);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const array = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings("branchSummary", array[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("entry-1", array[0].object.get("fromId").?.string);
    try std.testing.expectEqualStrings("compactionSummary", array[1].object.get("role").?.string);
    try std.testing.expectEqual(@as(i64, 123), array[1].object.get("tokensBefore").?.integer);
}
