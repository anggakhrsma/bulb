const std = @import("std");
const ai = @import("bulb_ai");
const messages_mod = @import("messages.zig");
const session_manager = @import("session_manager.zig");

const FileEntry = session_manager.FileEntry;
const CodingAgentMessage = messages_mod.CodingAgentMessage;

const estimated_image_chars: u64 = 4800;

pub const CompactionSettings = struct {
    enabled: bool = true,
    reserve_tokens: u64 = 16_384,
    keep_recent_tokens: u64 = 20_000,
};

pub const default_compaction_settings: CompactionSettings = .{};

pub const ContextUsageEstimate = struct {
    tokens: u64,
    usage_tokens: u64,
    trailing_tokens: u64,
    last_usage_index: ?usize,
};

pub const CutPointResult = struct {
    first_kept_entry_index: usize,
    turn_start_index: ?usize = null,
    is_split_turn: bool = false,
};

pub const FileOperations = struct {
    read: []const []const u8 = &.{},
    written: []const []const u8 = &.{},
    edited: []const []const u8 = &.{},
};

pub const FileOperationLists = struct {
    read_files: []const []const u8 = &.{},
    modified_files: []const []const u8 = &.{},
};

pub const CompactionPreparation = struct {
    arena: std.heap.ArenaAllocator,
    first_kept_entry_id: []const u8,
    messages_to_summarize: []const CodingAgentMessage,
    turn_prefix_messages: []const CodingAgentMessage,
    is_split_turn: bool,
    tokens_before: u64,
    previous_summary: ?[]const u8 = null,
    file_ops: FileOperations = .{},
    settings: CompactionSettings,

    pub fn deinit(self: *CompactionPreparation) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const MutableFileOperations = struct {
    read: std.StringHashMap(void),
    written: std.StringHashMap(void),
    edited: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) MutableFileOperations {
        return .{
            .read = std.StringHashMap(void).init(allocator),
            .written = std.StringHashMap(void).init(allocator),
            .edited = std.StringHashMap(void).init(allocator),
        };
    }
};

pub fn calculateContextTokens(usage: ai.Usage) u64 {
    if (usage.total_tokens != 0) return usage.total_tokens;
    return usage.input + usage.output + usage.cache_read + usage.cache_write;
}

pub fn getLastAssistantUsage(entries: []const FileEntry, allocator: std.mem.Allocator) !?ai.Usage {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch_allocator = scratch_arena.allocator();

    var index = entries.len;
    while (index > 0) {
        index -= 1;
        const entry = entries[index];
        if (!entryTypeEquals(entry, "message")) continue;
        const message = try session_manager.agentMessageFromMessageEntryAlloc(scratch_allocator, entry.raw_json);
        if (message) |msg| {
            if (getAssistantUsage(msg)) |usage| return usage;
        }
    }
    return null;
}

pub fn estimateContextTokens(messages: []const CodingAgentMessage) ContextUsageEstimate {
    const usage_info = getLastAssistantUsageInfo(messages);
    if (usage_info == null) {
        var estimated: u64 = 0;
        for (messages) |message| {
            estimated += estimateTokens(message);
        }
        return .{
            .tokens = estimated,
            .usage_tokens = 0,
            .trailing_tokens = estimated,
            .last_usage_index = null,
        };
    }

    const info = usage_info.?;
    const usage_tokens = calculateContextTokens(info.usage);
    var trailing_tokens: u64 = 0;
    for (messages[info.index + 1 ..]) |message| {
        trailing_tokens += estimateTokens(message);
    }
    return .{
        .tokens = usage_tokens + trailing_tokens,
        .usage_tokens = usage_tokens,
        .trailing_tokens = trailing_tokens,
        .last_usage_index = info.index,
    };
}

pub fn shouldCompact(context_tokens: u64, context_window: u64, settings: CompactionSettings) bool {
    if (!settings.enabled) return false;
    const threshold = context_window -| settings.reserve_tokens;
    return context_tokens > threshold;
}

pub fn estimateTokens(message: CodingAgentMessage) u64 {
    var chars: u64 = 0;
    switch (message) {
        .user => |msg| {
            chars = estimateUserContentChars(msg.content);
        },
        .assistant => |msg| {
            for (msg.content) |block| {
                chars += switch (block) {
                    .text => |text| text.text.len,
                    .thinking => |thinking| thinking.thinking.len,
                    .tool_call => |tool_call| tool_call.name.len + tool_call.arguments_json.len,
                };
            }
        },
        .tool_result => |msg| {
            chars = estimateUserContentChars(msg.content);
        },
        .bash_execution => |msg| {
            chars = msg.command.len + msg.output.len;
        },
        .custom => |msg| switch (msg.content) {
            .text => |text| chars = text.len,
            .parts => |parts| chars = estimateUserContentChars(parts),
        },
        .branch_summary => |msg| {
            chars = msg.summary.len;
        },
        .compaction_summary => |msg| {
            chars = msg.summary.len;
        },
    }
    return divCeilBy4(chars);
}

pub fn findCutPoint(
    allocator: std.mem.Allocator,
    entries: []const FileEntry,
    start_index: usize,
    end_index: usize,
    keep_recent_tokens: u64,
) !CutPointResult {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch_allocator = scratch_arena.allocator();

    const cut_points = try findValidCutPoints(scratch_allocator, entries, start_index, end_index);

    if (cut_points.len == 0) {
        return .{ .first_kept_entry_index = start_index };
    }

    var accumulated_tokens: u64 = 0;
    var cut_index = cut_points[0];
    var index = end_index;
    while (index > start_index) {
        index -= 1;
        const entry = entries[index];
        if (!entryTypeEquals(entry, "message")) continue;

        if (try messageFromEntryForCompactionAlloc(scratch_allocator, entry)) |message| {
            accumulated_tokens += estimateTokens(message);
        }
        if (accumulated_tokens >= keep_recent_tokens) {
            for (cut_points) |candidate| {
                if (candidate >= index) {
                    cut_index = candidate;
                    break;
                }
            }
            break;
        }
    }

    while (cut_index > start_index) {
        const previous = entries[cut_index - 1];
        if (entryTypeEquals(previous, "compaction")) break;
        if (entryTypeEquals(previous, "message")) break;
        cut_index -= 1;
    }

    const is_user_message = try isEntryUserMessage(scratch_allocator, entries[cut_index]);
    const turn_start_index = if (is_user_message)
        null
    else
        try findTurnStartIndexScratch(scratch_allocator, entries, cut_index, start_index);

    return .{
        .first_kept_entry_index = cut_index,
        .turn_start_index = turn_start_index,
        .is_split_turn = !is_user_message and turn_start_index != null,
    };
}

pub fn findTurnStartIndex(
    allocator: std.mem.Allocator,
    entries: []const FileEntry,
    entry_index: usize,
    start_index: usize,
) !?usize {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    return findTurnStartIndexScratch(scratch_arena.allocator(), entries, entry_index, start_index);
}

fn findTurnStartIndexScratch(
    allocator: std.mem.Allocator,
    entries: []const FileEntry,
    entry_index: usize,
    start_index: usize,
) !?usize {
    var index = entry_index + 1;
    while (index > start_index) {
        index -= 1;
        const entry = entries[index];
        if (entryTypeEquals(entry, "branch_summary") or entryTypeEquals(entry, "custom_message")) {
            return index;
        }
        if (entryTypeEquals(entry, "message")) {
            if (try session_manager.agentMessageFromMessageEntryAlloc(allocator, entry.raw_json)) |message| {
                switch (message) {
                    .user, .bash_execution => return index,
                    else => {},
                }
            }
        }
    }
    return null;
}

pub fn prepareCompaction(
    allocator: std.mem.Allocator,
    path_entries: []const FileEntry,
    settings: CompactionSettings,
) !?CompactionPreparation {
    if (path_entries.len > 0 and entryTypeEquals(path_entries[path_entries.len - 1], "compaction")) {
        return null;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var prev_compaction_index: ?usize = null;
    var index = path_entries.len;
    while (index > 0) {
        index -= 1;
        if (entryTypeEquals(path_entries[index], "compaction")) {
            prev_compaction_index = index;
            break;
        }
    }

    var previous_summary: ?[]const u8 = null;
    var boundary_start: usize = 0;
    if (prev_compaction_index) |prev_index| {
        const prev_compaction = path_entries[prev_index];
        previous_summary = try session_manager.entryStringFieldAlloc(arena_allocator, prev_compaction.raw_json, "summary");
        if (try session_manager.entryStringFieldAlloc(arena_allocator, prev_compaction.raw_json, "firstKeptEntryId")) |first_kept_id| {
            if (findEntryIndexById(path_entries, first_kept_id)) |first_kept_index| {
                boundary_start = first_kept_index;
            } else {
                boundary_start = prev_index + 1;
            }
        } else {
            boundary_start = prev_index + 1;
        }
    }

    var context = try session_manager.buildSessionContextFromEntriesAlloc(allocator, path_entries, .last);
    defer context.deinit();
    const tokens_before = estimateContextTokens(context.messages).tokens;

    const cut_point = try findCutPoint(
        arena_allocator,
        path_entries,
        boundary_start,
        path_entries.len,
        settings.keep_recent_tokens,
    );

    if (cut_point.first_kept_entry_index >= path_entries.len) return null;
    const first_kept_entry = path_entries[cut_point.first_kept_entry_index];
    const first_kept_entry_id = first_kept_entry.id orelse return null;

    const history_end = if (cut_point.is_split_turn)
        cut_point.turn_start_index orelse cut_point.first_kept_entry_index
    else
        cut_point.first_kept_entry_index;

    var messages_to_summarize: std.ArrayList(CodingAgentMessage) = .empty;
    for (path_entries[boundary_start..history_end]) |entry| {
        if (try messageFromEntryForCompactionAlloc(arena_allocator, entry)) |message| {
            try messages_to_summarize.append(arena_allocator, message);
        }
    }

    var turn_prefix_messages: std.ArrayList(CodingAgentMessage) = .empty;
    if (cut_point.is_split_turn) {
        const turn_start = cut_point.turn_start_index orelse cut_point.first_kept_entry_index;
        for (path_entries[turn_start..cut_point.first_kept_entry_index]) |entry| {
            if (try messageFromEntryForCompactionAlloc(arena_allocator, entry)) |message| {
                try turn_prefix_messages.append(arena_allocator, message);
            }
        }
    }

    const file_ops = try extractFileOperationsAlloc(
        arena_allocator,
        messages_to_summarize.items,
        turn_prefix_messages.items,
        path_entries,
        prev_compaction_index,
    );

    return .{
        .arena = arena,
        .first_kept_entry_id = try arena_allocator.dupe(u8, first_kept_entry_id),
        .messages_to_summarize = try messages_to_summarize.toOwnedSlice(arena_allocator),
        .turn_prefix_messages = try turn_prefix_messages.toOwnedSlice(arena_allocator),
        .is_split_turn = cut_point.is_split_turn,
        .tokens_before = tokens_before,
        .previous_summary = previous_summary,
        .file_ops = file_ops,
        .settings = settings,
    };
}

pub fn computeFileListsAlloc(allocator: std.mem.Allocator, file_ops: FileOperations) !FileOperationLists {
    var modified = std.StringHashMap(void).init(allocator);
    defer modified.deinit();
    for (file_ops.edited) |path| try modified.put(path, {});
    for (file_ops.written) |path| try modified.put(path, {});

    var read_files: std.ArrayList([]const u8) = .empty;
    errdefer read_files.deinit(allocator);
    for (file_ops.read) |path| {
        if (!modified.contains(path)) {
            try read_files.append(allocator, path);
        }
    }

    var modified_files: std.ArrayList([]const u8) = .empty;
    errdefer modified_files.deinit(allocator);
    var modified_iter = modified.keyIterator();
    while (modified_iter.next()) |path| {
        try modified_files.append(allocator, path.*);
    }

    sortStrings(read_files.items);
    sortStrings(modified_files.items);
    return .{
        .read_files = try read_files.toOwnedSlice(allocator),
        .modified_files = try modified_files.toOwnedSlice(allocator),
    };
}

fn getAssistantUsage(message: CodingAgentMessage) ?ai.Usage {
    if (message != .assistant) return null;
    const assistant = message.assistant;
    if (assistant.stop_reason == .aborted or assistant.stop_reason == .@"error") return null;
    if (!hasUsage(assistant.usage)) return null;
    return assistant.usage;
}

fn hasUsage(usage: ai.Usage) bool {
    return usage.input != 0 or
        usage.output != 0 or
        usage.cache_read != 0 or
        usage.cache_write != 0 or
        usage.total_tokens != 0;
}

const AssistantUsageInfo = struct {
    usage: ai.Usage,
    index: usize,
};

fn getLastAssistantUsageInfo(messages: []const CodingAgentMessage) ?AssistantUsageInfo {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (getAssistantUsage(messages[index])) |usage| {
            return .{ .usage = usage, .index = index };
        }
    }
    return null;
}

fn estimateUserContentChars(content: []const ai.UserContent) u64 {
    var chars: u64 = 0;
    for (content) |block| {
        chars += switch (block) {
            .text => |text| text.text.len,
            .image => estimated_image_chars,
        };
    }
    return chars;
}

fn divCeilBy4(value: u64) u64 {
    return (value + 3) / 4;
}

fn findValidCutPoints(
    allocator: std.mem.Allocator,
    entries: []const FileEntry,
    start_index: usize,
    end_index: usize,
) ![]usize {
    var cut_points: std.ArrayList(usize) = .empty;
    errdefer cut_points.deinit(allocator);

    for (entries[start_index..end_index], start_index..) |entry, index| {
        if (entryTypeEquals(entry, "message")) {
            if (try session_manager.agentMessageFromMessageEntryAlloc(allocator, entry.raw_json)) |message| {
                switch (message) {
                    .tool_result => {},
                    .user,
                    .assistant,
                    .custom,
                    .bash_execution,
                    .branch_summary,
                    .compaction_summary,
                    => try cut_points.append(allocator, index),
                }
            }
        }
        if (entryTypeEquals(entry, "branch_summary") or entryTypeEquals(entry, "custom_message")) {
            try cut_points.append(allocator, index);
        }
    }

    return cut_points.toOwnedSlice(allocator);
}

fn isEntryUserMessage(allocator: std.mem.Allocator, entry: FileEntry) !bool {
    if (!entryTypeEquals(entry, "message")) return false;
    const message = try session_manager.agentMessageFromMessageEntryAlloc(allocator, entry.raw_json);
    if (message) |msg| {
        return msg == .user;
    }
    return false;
}

fn messageFromEntryForCompactionAlloc(
    allocator: std.mem.Allocator,
    entry: FileEntry,
) !?CodingAgentMessage {
    if (entryTypeEquals(entry, "compaction")) return null;
    if (entryTypeEquals(entry, "message")) {
        return try session_manager.agentMessageFromMessageEntryAlloc(allocator, entry.raw_json);
    }
    if (entryTypeEquals(entry, "custom_message")) {
        if (try session_manager.customMessageFromEntryAlloc(allocator, entry.raw_json)) |message| {
            return .{ .custom = message };
        }
    }
    if (entryTypeEquals(entry, "branch_summary")) {
        if (try session_manager.branchSummaryMessageFromEntryAlloc(allocator, entry.raw_json)) |message| {
            return .{ .branch_summary = message };
        }
    }
    return null;
}

fn extractFileOperationsAlloc(
    allocator: std.mem.Allocator,
    messages_to_summarize: []const CodingAgentMessage,
    turn_prefix_messages: []const CodingAgentMessage,
    entries: []const FileEntry,
    prev_compaction_index: ?usize,
) !FileOperations {
    var mutable = MutableFileOperations.init(allocator);
    if (prev_compaction_index) |index| {
        try extractPreviousCompactionFileOperations(allocator, &mutable, entries[index]);
    }
    for (messages_to_summarize) |message| {
        try extractFileOpsFromMessage(allocator, &mutable, message);
    }
    for (turn_prefix_messages) |message| {
        try extractFileOpsFromMessage(allocator, &mutable, message);
    }
    return .{
        .read = try mapKeysAlloc(allocator, &mutable.read),
        .written = try mapKeysAlloc(allocator, &mutable.written),
        .edited = try mapKeysAlloc(allocator, &mutable.edited),
    };
}

fn extractPreviousCompactionFileOperations(
    allocator: std.mem.Allocator,
    mutable: *MutableFileOperations,
    entry: FileEntry,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (optionalBool(parsed.value.object, "fromHook") orelse false) return;
    const details = parsed.value.object.get("details") orelse return;
    if (details != .object) return;
    if (details.object.get("readFiles")) |read_files| {
        try addStringArrayToMap(allocator, &mutable.read, read_files);
    }
    if (details.object.get("modifiedFiles")) |modified_files| {
        try addStringArrayToMap(allocator, &mutable.edited, modified_files);
    }
}

fn extractFileOpsFromMessage(
    allocator: std.mem.Allocator,
    mutable: *MutableFileOperations,
    message: CodingAgentMessage,
) !void {
    if (message != .assistant) return;
    for (message.assistant.content) |block| {
        if (block != .tool_call) continue;
        const tool_call = block.tool_call;
        const path = try pathFromArgumentsAlloc(allocator, tool_call.arguments_json) orelse continue;
        if (std.mem.eql(u8, tool_call.name, "read")) {
            try mutable.read.put(path, {});
        } else if (std.mem.eql(u8, tool_call.name, "write")) {
            try mutable.written.put(path, {});
        } else if (std.mem.eql(u8, tool_call.name, "edit")) {
            try mutable.edited.put(path, {});
        }
    }
}

fn pathFromArgumentsAlloc(allocator: std.mem.Allocator, arguments_json: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const path = optionalString(parsed.value.object, "path") orelse return null;
    return try allocator.dupe(u8, path);
}

fn addStringArrayToMap(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(void),
    value: std.json.Value,
) !void {
    if (value != .array) return;
    for (value.array.items) |item| {
        if (item != .string) continue;
        try map.put(try allocator.dupe(u8, item.string), {});
    }
}

fn mapKeysAlloc(allocator: std.mem.Allocator, map: *std.StringHashMap(void)) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(allocator);
    var iterator = map.keyIterator();
    while (iterator.next()) |key| {
        try keys.append(allocator, key.*);
    }
    sortStrings(keys.items);
    return keys.toOwnedSlice(allocator);
}

fn sortStrings(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

fn findEntryIndexById(entries: []const FileEntry, id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (entry.id) |entry_id| {
            if (std.mem.eql(u8, entry_id, id)) return index;
        }
    }
    return null;
}

fn entryTypeEquals(entry: FileEntry, expected: []const u8) bool {
    return if (entry.entry_type) |entry_type| std.mem.eql(u8, entry_type, expected) else false;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn appendUser(session: *session_manager.SessionManager, text: []const u8) ![]const u8 {
    const content = [_]ai.UserContent{.{ .text = .{ .text = text } }};
    return session.appendMessage(std.testing.io, .{ .user = .{
        .content = &content,
        .timestamp_ms = 1,
    } });
}

fn appendAssistant(
    session: *session_manager.SessionManager,
    text: []const u8,
    usage: ai.Usage,
    stop_reason: ai.StopReason,
) ![]const u8 {
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = text } }};
    return session.appendMessage(std.testing.io, .{ .assistant = .{
        .content = &content,
        .api = ai.types.api.anthropic_messages,
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = usage,
        .stop_reason = stop_reason,
        .timestamp_ms = 2,
    } });
}

fn appendAssistantToolCall(
    session: *session_manager.SessionManager,
    name: []const u8,
    arguments_json: []const u8,
    usage: ai.Usage,
) ![]const u8 {
    const content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "tool-1",
        .name = name,
        .arguments_json = arguments_json,
    } }};
    return session.appendMessage(std.testing.io, .{ .assistant = .{
        .content = &content,
        .api = ai.types.api.anthropic_messages,
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = usage,
        .stop_reason = .tool_use,
        .timestamp_ms = 2,
    } });
}

fn mockUsage(input: u64, output: u64, cache_read: u64, cache_write: u64) ai.Usage {
    return .{
        .input = input,
        .output = output,
        .cache_read = cache_read,
        .cache_write = cache_write,
        .total_tokens = input + output + cache_read + cache_write,
    };
}

fn repeatAlloc(allocator: std.mem.Allocator, text: []const u8, count: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (0..count) |_| try output.appendSlice(allocator, text);
    return output.toOwnedSlice(allocator);
}

fn extractTextAlloc(allocator: std.mem.Allocator, source: []const CodingAgentMessage) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (source) |message| {
        if (output.items.len > 0) try output.append(allocator, '\n');
        switch (message) {
            .user => |msg| try appendUserContentText(allocator, &output, msg.content),
            .assistant => |msg| {
                for (msg.content) |block| {
                    if (block == .text) try output.appendSlice(allocator, block.text.text);
                }
            },
            .tool_result => |msg| try appendUserContentText(allocator, &output, msg.content),
            .bash_execution => |msg| {
                try output.appendSlice(allocator, msg.command);
                try output.append(allocator, '\n');
                try output.appendSlice(allocator, msg.output);
            },
            .custom => |msg| switch (msg.content) {
                .text => |text| try output.appendSlice(allocator, text),
                .parts => |parts| try appendUserContentText(allocator, &output, parts),
            },
            .branch_summary => |msg| try output.appendSlice(allocator, msg.summary),
            .compaction_summary => |msg| try output.appendSlice(allocator, msg.summary),
        }
    }
    return output.toOwnedSlice(allocator);
}

fn appendUserContentText(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    content: []const ai.UserContent,
) !void {
    for (content) |block| {
        if (block == .text) try output.appendSlice(allocator, block.text.text);
    }
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "compaction calculates context tokens from usage" {
    try std.testing.expectEqual(@as(u64, 1800), calculateContextTokens(mockUsage(1000, 500, 200, 100)));
    try std.testing.expectEqual(@as(u64, 0), calculateContextTokens(mockUsage(0, 0, 0, 0)));
}

test "compaction finds the last non-aborted assistant usage" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    _ = try appendUser(&session, "Hello");
    _ = try appendAssistant(&session, "Hi", mockUsage(100, 50, 0, 0), .stop);
    _ = try appendUser(&session, "How are you?");
    _ = try appendAssistant(&session, "Good", mockUsage(200, 100, 0, 0), .stop);

    const usage = (try getLastAssistantUsage(session.getEntries(), allocator)).?;
    try std.testing.expectEqual(@as(u64, 200), usage.input);
}

test "compaction skips aborted assistant usage" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    _ = try appendUser(&session, "Hello");
    _ = try appendAssistant(&session, "Hi", mockUsage(100, 50, 0, 0), .stop);
    _ = try appendUser(&session, "How are you?");
    _ = try appendAssistant(&session, "Aborted", mockUsage(300, 150, 0, 0), .aborted);

    const usage = (try getLastAssistantUsage(session.getEntries(), allocator)).?;
    try std.testing.expectEqual(@as(u64, 100), usage.input);
}

test "compaction returns null without assistant usage" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    _ = try appendUser(&session, "Hello");
    try std.testing.expectEqual(@as(?ai.Usage, null), try getLastAssistantUsage(session.getEntries(), allocator));
}

test "compaction threshold honors reserve tokens and disabled setting" {
    const settings: CompactionSettings = .{
        .enabled = true,
        .reserve_tokens = 10_000,
        .keep_recent_tokens = 20_000,
    };
    try std.testing.expect(shouldCompact(95_000, 100_000, settings));
    try std.testing.expect(!shouldCompact(89_000, 100_000, settings));

    var disabled = settings;
    disabled.enabled = false;
    try std.testing.expect(!shouldCompact(95_000, 100_000, disabled));
}

test "compaction finds cut point based on recent token budget" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    for (0..10) |index| {
        const user_text = try std.fmt.allocPrint(allocator, "User {d}", .{index});
        defer allocator.free(user_text);
        const assistant_text = try std.fmt.allocPrint(allocator, "Assistant {d}", .{index});
        defer allocator.free(assistant_text);
        _ = try appendUser(&session, user_text);
        _ = try appendAssistant(&session, assistant_text, mockUsage(0, 100, (index + 1) * 1000, 0), .stop);
    }

    const result = try findCutPoint(allocator, session.getEntries(), 0, session.getEntries().len, 2500);
    try std.testing.expect(entryTypeEquals(session.getEntries()[result.first_kept_entry_index], "message"));
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const message = (try session_manager.agentMessageFromMessageEntryAlloc(scratch_arena.allocator(), session.getEntries()[result.first_kept_entry_index].raw_json)).?;
    try std.testing.expect(message == .user or message == .assistant);
}

test "compaction keeps everything when messages fit within budget" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    _ = try appendUser(&session, "1");
    _ = try appendAssistant(&session, "a", mockUsage(0, 50, 500, 0), .stop);
    _ = try appendUser(&session, "2");
    _ = try appendAssistant(&session, "b", mockUsage(0, 50, 1000, 0), .stop);

    const result = try findCutPoint(allocator, session.getEntries(), 0, session.getEntries().len, 50_000);
    try std.testing.expectEqual(@as(usize, 0), result.first_kept_entry_index);
}

test "compaction marks split turn when cutting at assistant message" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    _ = try appendUser(&session, "Turn 1");
    _ = try appendAssistant(&session, "A1", mockUsage(0, 100, 1000, 0), .stop);
    _ = try appendUser(&session, "Turn 2");
    _ = try appendAssistant(&session, "A2-1", mockUsage(0, 100, 5000, 0), .stop);
    _ = try appendAssistant(&session, "A2-2", mockUsage(0, 100, 8000, 0), .stop);
    _ = try appendAssistant(&session, "A2-3", mockUsage(0, 100, 10_000, 0), .stop);

    const result = try findCutPoint(allocator, session.getEntries(), 0, session.getEntries().len, 3);
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const cut_message = (try session_manager.agentMessageFromMessageEntryAlloc(scratch_arena.allocator(), session.getEntries()[result.first_kept_entry_index].raw_json)).?;
    if (cut_message == .assistant) {
        try std.testing.expect(result.is_split_turn);
        try std.testing.expectEqual(@as(?usize, 2), result.turn_start_index);
    }
}

test "compaction preparation preserves kept messages across repeated compactions" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    _ = try appendUser(&session, "user msg 1 (summarized by compaction1)");
    _ = try appendAssistant(&session, "assistant msg 1", mockUsage(100, 50, 0, 0), .stop);
    const kept_user_id = try appendUser(&session, "user msg 2 - kept by compaction1");
    _ = try appendAssistant(&session, "assistant msg 2", mockUsage(100, 50, 0, 0), .stop);
    _ = try appendUser(&session, "user msg 3 - kept by compaction1");
    _ = try appendAssistant(&session, "assistant msg 3", mockUsage(5000, 1000, 0, 0), .stop);
    _ = try session.appendCompactionJson(std.testing.io, "First summary", kept_user_id, 10_000, null, null);
    _ = try appendUser(&session, "user msg 4 (new after compaction1)");
    _ = try appendAssistant(&session, "assistant msg 4", mockUsage(8000, 2000, 0, 0), .stop);

    var context_before = try session_manager.buildSessionContextFromEntriesAlloc(allocator, session.getEntries(), .last);
    defer context_before.deinit();
    var preparation = (try prepareCompaction(allocator, session.getEntries(), default_compaction_settings)).?;
    defer preparation.deinit();

    try std.testing.expectEqualStrings(kept_user_id, preparation.first_kept_entry_id);
    try std.testing.expectEqualStrings("First summary", preparation.previous_summary.?);
    const summarized_text = try extractTextAlloc(allocator, preparation.messages_to_summarize);
    defer allocator.free(summarized_text);
    try std.testing.expect(std.mem.indexOf(u8, summarized_text, "First summary") == null);
    try std.testing.expectEqual(estimateContextTokens(context_before.messages).tokens, preparation.tokens_before);

    _ = try session.appendCompactionJson(std.testing.io, "Second summary", preparation.first_kept_entry_id, preparation.tokens_before, null, null);
    var context_after = try session_manager.buildSessionContextFromEntriesAlloc(allocator, session.getEntries(), .last);
    defer context_after.deinit();
    const context_after_text = try extractTextAlloc(allocator, context_after.messages);
    defer allocator.free(context_after_text);
    try std.testing.expect(std.mem.indexOf(u8, context_after_text, "user msg 2 - kept by compaction1") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_after_text, "user msg 3 - kept by compaction1") != null);
}

test "compaction preparation re-summarizes kept messages when recent window moves past them" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const user1 = try repeatAlloc(allocator, "user msg 1 (summarized by compaction1)", 4);
    defer allocator.free(user1);
    const assistant1 = try repeatAlloc(allocator, "assistant msg 1", 4);
    defer allocator.free(assistant1);
    const user2 = try repeatAlloc(allocator, "user msg 2 - kept by compaction1 ", 12);
    defer allocator.free(user2);
    const assistant2 = try repeatAlloc(allocator, "assistant msg 2 ", 12);
    defer allocator.free(assistant2);
    const user3 = try repeatAlloc(allocator, "user msg 3 - kept by compaction1 ", 12);
    defer allocator.free(user3);
    const assistant3 = try repeatAlloc(allocator, "assistant msg 3 ", 12);
    defer allocator.free(assistant3);
    const user4 = try repeatAlloc(allocator, "user msg 4 (new after compaction1) ", 12);
    defer allocator.free(user4);
    const assistant4 = try repeatAlloc(allocator, "assistant msg 4 ", 12);
    defer allocator.free(assistant4);

    _ = try appendUser(&session, user1);
    _ = try appendAssistant(&session, assistant1, mockUsage(100, 50, 0, 0), .stop);
    const kept_user_id = try appendUser(&session, user2);
    _ = try appendAssistant(&session, assistant2, mockUsage(100, 50, 0, 0), .stop);
    _ = try appendUser(&session, user3);
    _ = try appendAssistant(&session, assistant3, mockUsage(5000, 1000, 0, 0), .stop);
    _ = try session.appendCompactionJson(std.testing.io, "First summary", kept_user_id, 10_000, null, null);
    _ = try appendUser(&session, user4);
    _ = try appendAssistant(&session, assistant4, mockUsage(8000, 2000, 0, 0), .stop);

    var settings = default_compaction_settings;
    settings.keep_recent_tokens = 100;
    var preparation = (try prepareCompaction(allocator, session.getEntries(), settings)).?;
    defer preparation.deinit();

    const summarized_text = try extractTextAlloc(allocator, preparation.messages_to_summarize);
    defer allocator.free(summarized_text);
    try std.testing.expect(std.mem.indexOf(u8, summarized_text, "user msg 2 - kept by compaction1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summarized_text, "user msg 3 - kept by compaction1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summarized_text, "First summary") == null);
    try std.testing.expectEqualStrings("First summary", preparation.previous_summary.?);
}

test "compaction preparation extracts file operation details" {
    const allocator = std.testing.allocator;
    var session = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const first_id = try appendAssistantToolCall(&session, "read", "{\"path\":\"src/a.zig\"}", mockUsage(100, 50, 0, 0));
    _ = try appendAssistantToolCall(&session, "edit", "{\"path\":\"src/b.zig\"}", mockUsage(100, 50, 0, 0));
    _ = try session.appendCompactionJson(
        std.testing.io,
        "First summary",
        first_id,
        10_000,
        "{\"readFiles\":[\"old-read.zig\"],\"modifiedFiles\":[\"old-edit.zig\"]}",
        false,
    );
    _ = try appendAssistantToolCall(&session, "write", "{\"path\":\"src/c.zig\"}", mockUsage(8000, 2000, 0, 0));

    var settings = default_compaction_settings;
    settings.keep_recent_tokens = 1;
    var preparation = (try prepareCompaction(allocator, session.getEntries(), settings)).?;
    defer preparation.deinit();
    const lists = try computeFileListsAlloc(allocator, preparation.file_ops);
    defer allocator.free(lists.read_files);
    defer allocator.free(lists.modified_files);

    try std.testing.expect(containsString(lists.read_files, "old-read.zig"));
    try std.testing.expect(containsString(lists.modified_files, "old-edit.zig"));
    try std.testing.expect(containsString(lists.modified_files, "src/b.zig"));
}
