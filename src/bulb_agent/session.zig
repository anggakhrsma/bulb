const std = @import("std");

const types = @import("types.zig");

pub const ForkPosition = enum {
    before,
    at,
};

pub const ForkOptions = struct {
    entry_id: ?[]const u8 = null,
    position: ForkPosition = .before,
};

pub const ModelRef = struct {
    provider: []const u8,
    model_id: []const u8,
};

pub const SessionContextMessage = struct {
    role: []const u8,
    entry_id: []const u8,
};

pub const OwnedSessionContext = struct {
    arena: std.heap.ArenaAllocator,
    messages: []SessionContextMessage,
    thinking_level: []const u8,
    model: ?ModelRef = null,
    active_tool_names: ?[]const []const u8 = null,

    pub fn deinit(self: *OwnedSessionContext) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn Session(comptime Storage: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        storage: *Storage,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, storage: *Storage) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .storage = storage,
            };
        }

        pub fn getMetadata(self: *const Self) @TypeOf(self.storage.getMetadata()) {
            return self.storage.getMetadata();
        }

        pub fn getStorage(self: *Self) *Storage {
            return self.storage;
        }

        pub fn getLeafId(self: *Self) !?[]const u8 {
            return try self.storage.getLeafId();
        }

        pub fn getEntry(self: *Self, id: []const u8) ?types.SessionTreeEntry {
            return self.storage.getEntry(id);
        }

        pub fn getEntries(self: *Self) []const types.SessionTreeEntry {
            return self.storage.getEntries();
        }

        pub fn getBranchAlloc(self: *Self, allocator: std.mem.Allocator, from_id: ?[]const u8) ![]types.SessionTreeEntry {
            const leaf_id = from_id orelse try self.storage.getLeafId();
            return try self.storage.getPathToRootAlloc(allocator, leaf_id);
        }

        pub fn buildContextAlloc(self: *Self, allocator: std.mem.Allocator) !OwnedSessionContext {
            const branch = try self.getBranchAlloc(allocator, null);
            defer allocator.free(branch);
            return try buildSessionContextAlloc(allocator, branch);
        }

        pub fn getLabel(self: *Self, id: []const u8) ?[]const u8 {
            return self.storage.getLabel(id);
        }

        pub fn getSessionName(self: *Self) !?[]const u8 {
            const entries = try self.storage.findEntriesAlloc(self.allocator, .session_info);
            defer self.allocator.free(entries);
            if (entries.len == 0) return null;

            var index = entries.len;
            while (index > 0) {
                index -= 1;
                if (entries[index].name) |name| {
                    const trimmed = std.mem.trim(u8, name, " \t\r\n");
                    if (trimmed.len > 0) return trimmed;
                }
            }
            return null;
        }

        pub fn appendMessageJson(self: *Self, message_json: []const u8) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .message,
                .type_name = "message",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .message_json = message_json,
            });
        }

        pub fn appendThinkingLevelChange(self: *Self, thinking_level: []const u8) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .thinking_level_change,
                .type_name = "thinking_level_change",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .thinking_level = thinking_level,
            });
        }

        pub fn appendModelChange(self: *Self, provider: []const u8, model_id: []const u8) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .model_change,
                .type_name = "model_change",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .provider = provider,
                .model_id = model_id,
            });
        }

        pub fn appendActiveToolsChange(self: *Self, active_tool_names: []const []const u8) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .active_tools_change,
                .type_name = "active_tools_change",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .active_tool_names = active_tool_names,
            });
        }

        pub fn appendCompaction(
            self: *Self,
            summary: []const u8,
            first_kept_entry_id: []const u8,
            tokens_before: u64,
            details_json: ?[]const u8,
            from_hook: ?bool,
        ) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .compaction,
                .type_name = "compaction",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .summary = summary,
                .first_kept_entry_id = first_kept_entry_id,
                .tokens_before = tokens_before,
                .details_json = details_json,
                .from_hook = from_hook,
            });
        }

        pub fn appendCustomEntry(self: *Self, custom_type: []const u8, data_json: ?[]const u8) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .custom,
                .type_name = "custom",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .custom_type = custom_type,
                .data_json = data_json,
            });
        }

        pub fn appendCustomMessageEntry(
            self: *Self,
            custom_type: []const u8,
            content_json: []const u8,
            display: bool,
            details_json: ?[]const u8,
        ) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .custom_message,
                .type_name = "custom_message",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .custom_type = custom_type,
                .content_json = content_json,
                .display = display,
                .details_json = details_json,
            });
        }

        pub fn appendLabel(self: *Self, target_id: []const u8, label: ?[]const u8) ![]const u8 {
            if (self.storage.getEntry(target_id) == null) return error.SessionNotFound;
            return try self.appendTypedEntry(.{
                .kind = .label,
                .type_name = "label",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .target_id = target_id,
                .label = label,
            });
        }

        pub fn appendSessionName(self: *Self, name: []const u8) ![]const u8 {
            return try self.appendTypedEntry(.{
                .kind = .session_info,
                .type_name = "session_info",
                .id = try self.storage.createEntryId(),
                .parent_id = try self.storage.getLeafId(),
                .timestamp = try self.timestampAlloc(),
                .name = std.mem.trim(u8, name, " \t\r\n"),
            });
        }

        pub fn moveTo(
            self: *Self,
            entry_id: ?[]const u8,
            summary: ?BranchSummaryOptions,
        ) !?[]const u8 {
            if (entry_id) |id| {
                if (self.storage.getEntry(id) == null) return error.SessionNotFound;
            }
            try self.storage.setLeafId(entry_id);
            const summary_options = summary orelse return null;
            const from_id = entry_id orelse "root";
            return try self.appendTypedEntryWithParent(.{
                .kind = .branch_summary,
                .type_name = "branch_summary",
                .id = try self.storage.createEntryId(),
                .parent_id = entry_id,
                .timestamp = try self.timestampAlloc(),
                .from_id = from_id,
                .summary = summary_options.summary,
                .details_json = summary_options.details_json,
                .from_hook = summary_options.from_hook,
            });
        }

        fn appendTypedEntry(self: *Self, entry: types.SessionTreeEntry) ![]const u8 {
            try self.storage.appendEntry(entry);
            return entry.id;
        }

        fn appendTypedEntryWithParent(self: *Self, entry: types.SessionTreeEntry) ![]const u8 {
            try self.storage.appendEntry(entry);
            return entry.id;
        }

        fn timestampAlloc(self: *Self) ![]const u8 {
            return try createTimestampAlloc(self.storage.arena.allocator(), self.io);
        }
    };
}

pub const BranchSummaryOptions = struct {
    summary: []const u8,
    details_json: ?[]const u8 = null,
    from_hook: ?bool = null,
};

pub fn buildSessionContextAlloc(
    allocator: std.mem.Allocator,
    path_entries: []const types.SessionTreeEntry,
) !OwnedSessionContext {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var thinking_level: []const u8 = "off";
    var model: ?ModelRef = null;
    var active_tool_names: ?[]const []const u8 = null;
    var compaction_index: ?usize = null;

    for (path_entries, 0..) |entry, index| {
        switch (entry.kind) {
            .thinking_level_change => {
                if (entry.thinking_level) |level| thinking_level = level;
            },
            .model_change => {
                if (entry.provider) |provider| {
                    if (entry.model_id) |model_id| model = .{ .provider = provider, .model_id = model_id };
                }
            },
            .message => {
                if ((messageRole(entry.message_json) orelse .unknown) == .assistant) {
                    if (try messageProviderModelAlloc(arena_allocator, entry.message_json)) |provider_model| {
                        model = provider_model;
                    }
                }
            },
            .active_tools_change => active_tool_names = entry.active_tool_names,
            .compaction => compaction_index = index,
            else => {},
        }
    }

    var context_messages: std.ArrayList(SessionContextMessage) = .empty;
    errdefer context_messages.deinit(arena_allocator);

    if (compaction_index) |index| {
        const compaction = path_entries[index];
        try appendContextMessage(arena_allocator, &context_messages, compaction, "compactionSummary");

        var found_first_kept = false;
        for (path_entries[0..index]) |entry| {
            if (compaction.first_kept_entry_id) |first_kept| {
                if (std.mem.eql(u8, entry.id, first_kept)) found_first_kept = true;
            }
            if (found_first_kept) try appendEntryAsMessage(arena_allocator, &context_messages, entry);
        }
        for (path_entries[index + 1 ..]) |entry| {
            try appendEntryAsMessage(arena_allocator, &context_messages, entry);
        }
    } else {
        for (path_entries) |entry| {
            try appendEntryAsMessage(arena_allocator, &context_messages, entry);
        }
    }

    return .{
        .arena = arena,
        .messages = try context_messages.toOwnedSlice(arena_allocator),
        .thinking_level = thinking_level,
        .model = model,
        .active_tool_names = active_tool_names,
    };
}

pub fn createTimestampAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return try isoTimestampAlloc(allocator, std.Io.Clock.real.now(io).toMilliseconds());
}

pub fn messageRole(message_json: ?[]const u8) ?MessageRole {
    const json = message_json orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const role = parsed.value.object.get("role") orelse return null;
    if (role != .string) return null;
    return messageRoleFromString(role.string);
}

pub const MessageRole = enum {
    user,
    assistant,
    toolResult,
    bashExecution,
    custom,
    branchSummary,
    compactionSummary,
    unknown,
};

pub fn messageRoleName(role: MessageRole) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .toolResult => "toolResult",
        .bashExecution => "bashExecution",
        .custom => "custom",
        .branchSummary => "branchSummary",
        .compactionSummary => "compactionSummary",
        .unknown => "unknown",
    };
}

fn messageRoleFromString(role: []const u8) MessageRole {
    if (std.mem.eql(u8, role, "user")) return .user;
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "toolResult")) return .toolResult;
    if (std.mem.eql(u8, role, "bashExecution")) return .bashExecution;
    if (std.mem.eql(u8, role, "custom")) return .custom;
    if (std.mem.eql(u8, role, "branchSummary")) return .branchSummary;
    if (std.mem.eql(u8, role, "compactionSummary")) return .compactionSummary;
    return .unknown;
}

fn messageProviderModelAlloc(allocator: std.mem.Allocator, message_json: ?[]const u8) !?ModelRef {
    const json = message_json orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    const role = object.get("role") orelse return null;
    if (role != .string or !std.mem.eql(u8, role.string, "assistant")) return null;
    const provider = object.get("provider") orelse return null;
    const model = object.get("model") orelse return null;
    if (provider != .string or model != .string) return null;
    return .{ .provider = provider.string, .model_id = model.string };
}

fn appendEntryAsMessage(
    allocator: std.mem.Allocator,
    context_messages: *std.ArrayList(SessionContextMessage),
    entry: types.SessionTreeEntry,
) !void {
    switch (entry.kind) {
        .message => {
            const role = messageRole(entry.message_json) orelse .unknown;
            try appendContextMessage(allocator, context_messages, entry, messageRoleName(role));
        },
        .custom_message => try appendContextMessage(allocator, context_messages, entry, "custom"),
        .branch_summary => {
            if (entry.summary != null) {
                try appendContextMessage(allocator, context_messages, entry, "branchSummary");
            }
        },
        else => {},
    }
}

fn appendContextMessage(
    allocator: std.mem.Allocator,
    context_messages: *std.ArrayList(SessionContextMessage),
    entry: types.SessionTreeEntry,
    role: []const u8,
) !void {
    try context_messages.append(allocator, .{
        .role = try allocator.dupe(u8, role),
        .entry_id = try allocator.dupe(u8, entry.id),
    });
}

fn isoTimestampAlloc(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    if (timestamp_ms < 0) return error.InvalidTimestamp;
    const epoch_seconds = std.time.epoch.EpochSeconds{
        .secs = @intCast(@divTrunc(timestamp_ms, std.time.ms_per_s)),
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            @as(u16, @intCast(@mod(timestamp_ms, std.time.ms_per_s))),
        },
    );
}

pub fn userMessageJsonAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .role = "user",
        .content = .{.{
            .type = "text",
            .text = text,
        }},
        .timestamp = @as(i64, 1),
    }, .{});
}

pub fn assistantMessageJsonAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .role = "assistant",
        .content = .{.{
            .type = "text",
            .text = text,
        }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = .{
            .input = @as(u64, 0),
            .output = @as(u64, 0),
            .cacheRead = @as(u64, 0),
            .cacheWrite = @as(u64, 0),
            .totalTokens = @as(u64, 0),
            .cost = .{
                .input = @as(f64, 0),
                .output = @as(f64, 0),
                .cacheRead = @as(f64, 0),
                .cacheWrite = @as(f64, 0),
                .total = @as(f64, 0),
            },
        },
        .stopReason = "stop",
        .timestamp = @as(i64, 1),
    }, .{});
}

test "agent session appends messages and builds context in order" {
    const session_storage = @import("session_storage.zig");
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);

    const user_json = try userMessageJsonAlloc(allocator, "one");
    defer allocator.free(user_json);
    const assistant_json = try assistantMessageJsonAlloc(allocator, "two");
    defer allocator.free(assistant_json);

    _ = try session.appendMessageJson(user_json);
    _ = try session.appendMessageJson(assistant_json);
    var context = try session.buildContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("user", context.messages[0].role);
    try std.testing.expectEqualStrings("assistant", context.messages[1].role);
}

test "agent session tracks model thinking branch compaction label and session info entries" {
    const session_storage = @import("session_storage.zig");
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);

    const user1_json = try userMessageJsonAlloc(allocator, "one");
    defer allocator.free(user1_json);
    const assistant1_json = try assistantMessageJsonAlloc(allocator, "two");
    defer allocator.free(assistant1_json);
    const user2_json = try userMessageJsonAlloc(allocator, "three");
    defer allocator.free(user2_json);
    const assistant2_json = try assistantMessageJsonAlloc(allocator, "four");
    defer allocator.free(assistant2_json);

    const user1 = try session.appendMessageJson(user1_json);
    const assistant1 = try session.appendMessageJson(assistant1_json);
    _ = assistant1;
    const user2 = try session.appendMessageJson(user2_json);
    _ = try session.appendMessageJson(assistant2_json);
    _ = try session.appendModelChange("openai", "gpt-4.1");
    _ = try session.appendThinkingLevelChange("high");
    var model_context = try session.buildContextAlloc(allocator);
    defer model_context.deinit();
    try std.testing.expectEqualStrings("high", model_context.thinking_level);
    try std.testing.expectEqualStrings("openai", model_context.model.?.provider);
    try std.testing.expectEqualStrings("gpt-4.1", model_context.model.?.model_id);

    _ = try session.appendCompaction("summary", user2, 1234, null, null);
    const user3_json = try userMessageJsonAlloc(allocator, "five");
    defer allocator.free(user3_json);
    _ = try session.appendMessageJson(user3_json);
    var compacted = try session.buildContextAlloc(allocator);
    defer compacted.deinit();
    try std.testing.expectEqualStrings("compactionSummary", compacted.messages[0].role);

    _ = try session.appendLabel(user1, "checkpoint");
    _ = try session.appendSessionName(" name ");
    try std.testing.expectEqualStrings("checkpoint", session.getLabel(user1).?);
    try std.testing.expectEqualStrings("name", (try session.getSessionName()).?);

    _ = try session.moveTo(user1, .{ .summary = "summary text" });
    const branch = try session.getBranchAlloc(allocator, null);
    defer allocator.free(branch);
    try std.testing.expectEqualStrings(user1, branch[0].id);
    try std.testing.expectError(error.SessionNotFound, session.appendLabel("missing", "checkpoint"));
}
