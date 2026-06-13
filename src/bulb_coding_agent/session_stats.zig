const std = @import("std");

const ai = @import("bulb_ai");
const compaction = @import("compaction.zig");
const extensions = @import("extensions/root.zig");
const messages = @import("messages.zig");
const session_manager = @import("session_manager.zig");

pub const SessionTokenStats = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    total: u64 = 0,
};

pub const SessionStats = struct {
    session_file: ?[]const u8,
    session_id: []const u8,
    user_messages: usize,
    assistant_messages: usize,
    tool_calls: usize,
    tool_results: usize,
    total_messages: usize,
    tokens: SessionTokenStats,
    cost: f64,
    context_usage: ?extensions.ContextUsage,
};

pub const SessionStatsOptions = struct {
    session_manager: *const session_manager.SessionManager,
    messages: []const messages.CodingAgentMessage,
    model: ?ai.Model = null,
};

pub fn getSessionStatsAlloc(
    allocator: std.mem.Allocator,
    options: SessionStatsOptions,
) !SessionStats {
    var stats = SessionStats{
        .session_file = options.session_manager.getSessionFile(),
        .session_id = options.session_manager.getSessionId(),
        .user_messages = 0,
        .assistant_messages = 0,
        .tool_calls = 0,
        .tool_results = 0,
        .total_messages = options.messages.len,
        .tokens = .{},
        .cost = 0,
        .context_usage = try getContextUsageAlloc(allocator, options),
    };

    for (options.messages) |message| {
        switch (message) {
            .user => stats.user_messages += 1,
            .assistant => |assistant| {
                stats.assistant_messages += 1;
                for (assistant.content) |block| {
                    if (block == .tool_call) stats.tool_calls += 1;
                }
                stats.tokens.input += assistant.usage.input;
                stats.tokens.output += assistant.usage.output;
                stats.tokens.cache_read += assistant.usage.cache_read;
                stats.tokens.cache_write += assistant.usage.cache_write;
                stats.cost += assistant.usage.cost.total;
            },
            .tool_result => stats.tool_results += 1,
            else => {},
        }
    }

    stats.tokens.total = stats.tokens.input +
        stats.tokens.output +
        stats.tokens.cache_read +
        stats.tokens.cache_write;
    return stats;
}

pub fn getContextUsageAlloc(
    allocator: std.mem.Allocator,
    options: SessionStatsOptions,
) !?extensions.ContextUsage {
    const model = options.model orelse return null;
    if (model.context_window == 0) return null;

    const branch = try options.session_manager.getBranchAlloc(allocator, null);
    defer allocator.free(branch);

    if (latestCompactionIndex(branch)) |compaction_index| {
        const has_post_compaction_usage = try hasTrustedAssistantUsageAfterCompaction(
            allocator,
            branch,
            compaction_index,
        );
        if (!has_post_compaction_usage) {
            return .{
                .tokens = null,
                .context_window = model.context_window,
                .percent = null,
            };
        }
    }

    const estimate = compaction.estimateContextTokens(options.messages);
    return .{
        .tokens = estimate.tokens,
        .context_window = model.context_window,
        .percent = (@as(f64, @floatFromInt(estimate.tokens)) / @as(f64, @floatFromInt(model.context_window))) * 100,
    };
}

fn latestCompactionIndex(entries: []const session_manager.FileEntry) ?usize {
    var latest: ?usize = null;
    for (entries, 0..) |entry, index| {
        if (entry.entry_type) |entry_type| {
            if (std.mem.eql(u8, entry_type, "compaction")) latest = index;
        }
    }
    return latest;
}

fn hasTrustedAssistantUsageAfterCompaction(
    allocator: std.mem.Allocator,
    entries: []const session_manager.FileEntry,
    compaction_index: usize,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var index = entries.len;
    while (index > compaction_index + 1) {
        index -= 1;
        const entry = entries[index];
        if (!entryTypeEquals(entry, "message")) continue;
        const message = try session_manager.agentMessageFromMessageEntryAlloc(arena_allocator, entry.raw_json) orelse continue;
        if (message != .assistant) continue;

        const assistant = message.assistant;
        if (assistant.stop_reason == .aborted or assistant.stop_reason == .@"error") continue;
        return compaction.calculateContextTokens(assistant.usage) > 0;
    }
    return false;
}

fn entryTypeEquals(entry: session_manager.FileEntry, expected: []const u8) bool {
    const entry_type = entry.entry_type orelse return false;
    return std.mem.eql(u8, entry_type, expected);
}

fn testModel(context_window: u64) ai.Model {
    return .{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = ai.types.api.anthropic_messages,
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1/messages",
        .reasoning = true,
        .input = &[_][]const u8{"text"},
        .cost = .{},
        .context_window = context_window,
        .max_tokens = 8192,
    };
}

fn usage(total_tokens: u64) ai.Usage {
    return .{
        .input = total_tokens,
        .total_tokens = total_tokens,
    };
}

fn appendUser(session: *session_manager.SessionManager, text: []const u8, timestamp_ms: i64) ![]const u8 {
    const content = [_]ai.UserContent{.{ .text = .{ .text = text } }};
    return session.appendMessage(std.testing.io, .{ .user = .{
        .content = content[0..],
        .timestamp_ms = timestamp_ms,
    } });
}

fn appendAssistant(
    session: *session_manager.SessionManager,
    text: []const u8,
    total_tokens: u64,
    timestamp_ms: i64,
) ![]const u8 {
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = text } }};
    return session.appendMessage(std.testing.io, .{ .assistant = .{
        .content = content[0..],
        .api = ai.types.api.anthropic_messages,
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = usage(total_tokens),
        .stop_reason = .stop,
        .timestamp_ms = timestamp_ms,
    } });
}

fn currentMessagesAlloc(
    allocator: std.mem.Allocator,
    session: *const session_manager.SessionManager,
) !session_manager.SessionContext {
    return session.buildSessionContextAlloc(allocator);
}

test "session stats exposes context usage alongside token totals" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const model = testModel(200_000);
    _ = try appendUser(&session, "hello", 1);
    _ = try appendAssistant(&session, "hi", 200, 2);

    var context = try currentMessagesAlloc(allocator, &session);
    defer context.deinit();

    const stats = try getSessionStatsAlloc(allocator, .{
        .session_manager = &session,
        .messages = context.messages,
        .model = model,
    });

    try std.testing.expectEqual(@as(u64, 200), stats.tokens.input);
    try std.testing.expectEqual(@as(u64, 200), stats.tokens.total);
    try std.testing.expect(stats.context_usage != null);
    try std.testing.expectEqual(@as(?u64, 200), stats.context_usage.?.tokens);
    try std.testing.expectEqual(@as(u64, 200_000), stats.context_usage.?.context_window);
    try std.testing.expectEqual(@as(?f64, 0.1), stats.context_usage.?.percent);
}

test "session stats reports unknown current context usage immediately after compaction" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const model = testModel(200_000);
    _ = try appendUser(&session, "first", 1);
    _ = try appendAssistant(&session, "response1", 180_000, 2);
    const kept_user_id = try appendUser(&session, "second", 3);
    _ = try appendAssistant(&session, "response2", 195_000, 4);
    _ = try session.appendCompactionJson(std.testing.io, "summary", kept_user_id, 195_000, null, null);
    _ = try appendUser(&session, "third", 5);

    var context = try currentMessagesAlloc(allocator, &session);
    defer context.deinit();

    const stats = try getSessionStatsAlloc(allocator, .{
        .session_manager = &session,
        .messages = context.messages,
        .model = model,
    });

    try std.testing.expectEqual(@as(u64, 195_000), stats.tokens.input);
    try std.testing.expect(stats.context_usage != null);
    try std.testing.expectEqual(@as(?u64, null), stats.context_usage.?.tokens);
    try std.testing.expectEqual(@as(?f64, null), stats.context_usage.?.percent);
}

test "session stats uses post-compaction usage instead of stale kept usage" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const model = testModel(200_000);
    _ = try appendUser(&session, "first", 1);
    _ = try appendAssistant(&session, "response1", 180_000, 2);
    const kept_user_id = try appendUser(&session, "second", 3);
    _ = try appendAssistant(&session, "response2", 195_000, 4);
    _ = try session.appendCompactionJson(std.testing.io, "summary", kept_user_id, 195_000, null, null);
    _ = try appendUser(&session, "third", 5);
    _ = try appendAssistant(&session, "response3", 25_000, 6);

    var context = try currentMessagesAlloc(allocator, &session);
    defer context.deinit();

    const stats = try getSessionStatsAlloc(allocator, .{
        .session_manager = &session,
        .messages = context.messages,
        .model = model,
    });

    try std.testing.expectEqual(@as(u64, 220_000), stats.tokens.input);
    try std.testing.expect(stats.context_usage != null);
    try std.testing.expectEqual(@as(?u64, 25_000), stats.context_usage.?.tokens);
    try std.testing.expectEqual(@as(?f64, 12.5), stats.context_usage.?.percent);
}
