const std = @import("std");
const ai = @import("bulb_ai");
const types = @import("types.zig");

pub const compaction_summary_prefix =
    \\The conversation history before this point was compacted into the following summary:
    \\
    \\<summary>
    \\
;

pub const compaction_summary_suffix =
    \\
    \\</summary>
;

pub const branch_summary_prefix =
    \\The following is a summary of a branch that this conversation came back from:
    \\
    \\<summary>
    \\
;

pub const branch_summary_suffix = "</summary>";

pub const BashExecutionMessage = types.BashExecutionMessage;
pub const CustomMessageContent = types.CustomMessageContent;
pub const CustomMessage = types.CustomMessage;
pub const BranchSummaryMessage = types.BranchSummaryMessage;
pub const CompactionSummaryMessage = types.CompactionSummaryMessage;
pub const AgentMessage = types.AgentMessage;

pub const LlmMessages = struct {
    messages: []ai.Message = &.{},
    owned_content: [][]ai.UserContent = &.{},
    owned_text: [][]u8 = &.{},

    pub fn deinit(self: *LlmMessages, allocator: std.mem.Allocator) void {
        for (self.owned_content) |content| allocator.free(content);
        if (self.owned_content.len > 0) allocator.free(self.owned_content);
        for (self.owned_text) |text| allocator.free(text);
        if (self.owned_text.len > 0) allocator.free(self.owned_text);
        if (self.messages.len > 0) allocator.free(self.messages);
        self.* = .{};
    }
};

pub fn bashExecutionToTextAlloc(allocator: std.mem.Allocator, msg: BashExecutionMessage) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);

    try text.appendSlice(allocator, "Ran `");
    try text.appendSlice(allocator, msg.command);
    try text.appendSlice(allocator, "`\n");

    if (msg.output.len > 0) {
        try text.appendSlice(allocator, "```\n");
        try text.appendSlice(allocator, msg.output);
        try text.appendSlice(allocator, "\n```");
    } else {
        try text.appendSlice(allocator, "(no output)");
    }

    if (msg.cancelled) {
        try text.appendSlice(allocator, "\n\n(command cancelled)");
    } else if (msg.exit_code) |exit_code| {
        if (exit_code != 0) {
            const formatted = try std.fmt.allocPrint(allocator, "\n\nCommand exited with code {d}", .{exit_code});
            defer allocator.free(formatted);
            try text.appendSlice(allocator, formatted);
        }
    }

    if (msg.truncated) {
        if (msg.full_output_path) |path| {
            const formatted = try std.fmt.allocPrint(allocator, "\n\n[Output truncated. Full output: {s}]", .{path});
            defer allocator.free(formatted);
            try text.appendSlice(allocator, formatted);
        }
    }

    return try text.toOwnedSlice(allocator);
}

pub fn createBranchSummaryMessage(
    summary: []const u8,
    from_id: []const u8,
    timestamp: []const u8,
) !BranchSummaryMessage {
    return .{
        .summary = summary,
        .from_id = from_id,
        .timestamp_ms = try parseTimestampMs(timestamp),
    };
}

pub fn createCompactionSummaryMessage(
    summary: []const u8,
    tokens_before: u64,
    timestamp: []const u8,
) !CompactionSummaryMessage {
    return .{
        .summary = summary,
        .tokens_before = tokens_before,
        .timestamp_ms = try parseTimestampMs(timestamp),
    };
}

pub fn createCustomMessage(
    custom_type: []const u8,
    content: CustomMessageContent,
    display: bool,
    details_json: ?[]const u8,
    timestamp: []const u8,
) !CustomMessage {
    return .{
        .custom_type = custom_type,
        .content = content,
        .display = display,
        .details_json = details_json,
        .timestamp_ms = try parseTimestampMs(timestamp),
    };
}

pub fn convertToLlmAlloc(allocator: std.mem.Allocator, source: []const AgentMessage) !LlmMessages {
    var output: std.ArrayList(ai.Message) = .empty;
    errdefer output.deinit(allocator);

    var owned_content: std.ArrayList([]ai.UserContent) = .empty;
    errdefer {
        for (owned_content.items) |content| allocator.free(content);
        owned_content.deinit(allocator);
    }

    var owned_text: std.ArrayList([]u8) = .empty;
    errdefer {
        for (owned_text.items) |text| allocator.free(text);
        owned_text.deinit(allocator);
    }

    for (source) |message| {
        switch (message) {
            .bash_execution => |msg| {
                if (msg.exclude_from_context) continue;
                const text = try bashExecutionToTextAlloc(allocator, msg);
                var text_registered = false;
                errdefer if (!text_registered) allocator.free(text);
                try owned_text.append(allocator, text);
                text_registered = true;
                try appendTextUserMessage(allocator, &output, &owned_content, text, msg.timestamp_ms);
            },
            .custom => |msg| switch (msg.content) {
                .text => |text| try appendTextUserMessage(allocator, &output, &owned_content, text, msg.timestamp_ms),
                .parts => |parts| try output.append(allocator, .{ .user = .{
                    .content = parts,
                    .timestamp_ms = msg.timestamp_ms,
                } }),
            },
            .branch_summary => |msg| {
                const text = try std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ branch_summary_prefix, msg.summary, branch_summary_suffix },
                );
                var text_registered = false;
                errdefer if (!text_registered) allocator.free(text);
                try owned_text.append(allocator, text);
                text_registered = true;
                try appendTextUserMessage(allocator, &output, &owned_content, text, msg.timestamp_ms);
            },
            .compaction_summary => |msg| {
                const text = try std.fmt.allocPrint(
                    allocator,
                    "{s}{s}{s}",
                    .{ compaction_summary_prefix, msg.summary, compaction_summary_suffix },
                );
                var text_registered = false;
                errdefer if (!text_registered) allocator.free(text);
                try owned_text.append(allocator, text);
                text_registered = true;
                try appendTextUserMessage(allocator, &output, &owned_content, text, msg.timestamp_ms);
            },
            .user => |msg| try output.append(allocator, .{ .user = msg }),
            .assistant => |msg| try output.append(allocator, .{ .assistant = msg }),
            .tool_result => |msg| try output.append(allocator, .{ .tool_result = msg }),
        }
    }

    const messages_slice = try output.toOwnedSlice(allocator);
    errdefer if (messages_slice.len > 0) allocator.free(messages_slice);
    const content_slice = try owned_content.toOwnedSlice(allocator);
    errdefer {
        for (content_slice) |content| allocator.free(content);
        if (content_slice.len > 0) allocator.free(content_slice);
    }
    const text_slice = try owned_text.toOwnedSlice(allocator);

    return .{
        .messages = messages_slice,
        .owned_content = content_slice,
        .owned_text = text_slice,
    };
}

pub fn parseTimestampMs(timestamp: []const u8) !i64 {
    return parseIsoTimestampMs(timestamp) orelse error.InvalidTimestamp;
}

fn appendTextUserMessage(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(ai.Message),
    owned_content: *std.ArrayList([]ai.UserContent),
    text: []const u8,
    timestamp_ms: i64,
) !void {
    const content = try allocator.alloc(ai.UserContent, 1);
    var content_registered = false;
    errdefer if (!content_registered) allocator.free(content);
    content[0] = .{ .text = .{ .text = text } };
    try owned_content.append(allocator, content);
    content_registered = true;
    try output.append(allocator, .{ .user = .{
        .content = content,
        .timestamp_ms = timestamp_ms,
    } });
}

fn parseIsoTimestampMs(timestamp: []const u8) ?i64 {
    if (timestamp.len < 19) return null;
    if (timestamp[4] != '-' or timestamp[7] != '-') return null;
    if (timestamp[10] != 'T' and timestamp[10] != ' ') return null;
    if (timestamp[13] != ':' or timestamp[16] != ':') return null;

    const year = std.fmt.parseInt(u16, timestamp[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, timestamp[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, timestamp[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, timestamp[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, timestamp[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, timestamp[17..19], 10) catch return null;

    var index: usize = 19;
    var millisecond: u16 = 0;
    if (index < timestamp.len and timestamp[index] == '.') {
        index += 1;
        var digit_count: u8 = 0;
        while (index < timestamp.len and std.ascii.isDigit(timestamp[index])) : (index += 1) {
            if (digit_count < 3) {
                millisecond = millisecond * 10 + @as(u16, timestamp[index] - '0');
                digit_count += 1;
            }
        }
        if (digit_count == 0) return null;
        while (digit_count < 3) : (digit_count += 1) millisecond *= 10;
    }

    const timezone_offset_minutes = parseTimezoneOffsetMinutes(timestamp[index..]) orelse return null;
    const base_ms = utcDateTimeToEpochMs(year, month, day, hour, minute, second) orelse return null;
    const with_ms = std.math.add(i64, base_ms, millisecond) catch return null;
    return std.math.sub(i64, with_ms, timezone_offset_minutes * 60 * 1000) catch return null;
}

fn parseTimezoneOffsetMinutes(value: []const u8) ?i64 {
    if (value.len == 0) return 0;
    if (value.len == 1 and value[0] == 'Z') return 0;
    if (value.len != 6) return null;
    if (value[0] != '+' and value[0] != '-') return null;
    if (value[3] != ':') return null;
    const hour = std.fmt.parseInt(i64, value[1..3], 10) catch return null;
    const minute = std.fmt.parseInt(i64, value[4..6], 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    const offset = hour * 60 + minute;
    return if (value[0] == '+') offset else -offset;
}

fn utcDateTimeToEpochMs(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) ?i64 {
    if (year < 1970 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 60) return null;
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    const days_in_month = std.time.epoch.getDaysInMonth(year, month_enum);
    if (day > days_in_month) return null;

    var days: u64 = 0;
    var current_year: u16 = 1970;
    while (current_year < year) : (current_year += 1) {
        days += std.time.epoch.getDaysInYear(current_year);
    }

    var current_month: u8 = 1;
    while (current_month < month) : (current_month += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(current_month));
    }

    days += day - 1;
    const seconds = days * std.time.epoch.secs_per_day +
        @as(u64, hour) * 3600 +
        @as(u64, minute) * 60 +
        @as(u64, second);
    const millis = std.math.mul(u64, seconds, 1000) catch return null;
    return std.math.cast(i64, millis);
}

fn expectUserText(message: ai.Message, expected_text: []const u8, expected_timestamp: i64) !void {
    switch (message) {
        .user => |user| {
            try std.testing.expectEqual(expected_timestamp, user.timestamp_ms);
            try std.testing.expectEqual(@as(usize, 1), user.content.len);
            switch (user.content[0]) {
                .text => |text| try std.testing.expectEqualStrings(expected_text, text.text),
                else => return error.ExpectedTextContent,
            }
        },
        else => return error.ExpectedUserMessage,
    }
}

// Ported from packages/agent/src/harness/messages.ts bashExecutionToText.
test "agent harness messages format bash execution text for LLM context" {
    const allocator = std.testing.allocator;

    var text = try bashExecutionToTextAlloc(allocator, .{
        .command = "git status",
        .output = "clean",
        .exit_code = 0,
        .timestamp_ms = 1,
    });
    defer allocator.free(text);
    try std.testing.expectEqualStrings(
        \\Ran `git status`
        \\```
        \\clean
        \\```
    , text);

    allocator.free(text);
    text = try bashExecutionToTextAlloc(allocator, .{
        .command = "false",
        .output = "",
        .exit_code = 2,
        .timestamp_ms = 2,
    });
    try std.testing.expectEqualStrings(
        \\Ran `false`
        \\(no output)
        \\
        \\Command exited with code 2
    , text);

    allocator.free(text);
    text = try bashExecutionToTextAlloc(allocator, .{
        .command = "sleep 99",
        .output = "stopped",
        .exit_code = 130,
        .cancelled = true,
        .truncated = true,
        .full_output_path = "/tmp/full.log",
        .timestamp_ms = 3,
    });
    try std.testing.expectEqualStrings(
        \\Ran `sleep 99`
        \\```
        \\stopped
        \\```
        \\
        \\(command cancelled)
        \\
        \\[Output truncated. Full output: /tmp/full.log]
    , text);
}

// Ported from packages/agent/src/harness/messages.ts custom/summary creators.
test "agent harness messages create timestamped custom and summary messages" {
    const custom = try createCustomMessage(
        "status",
        .{ .text = "done" },
        true,
        "{\"ok\":true}",
        "2025-12-08T22:41:09.394Z",
    );
    try std.testing.expectEqualStrings("status", custom.custom_type);
    try std.testing.expect(custom.display);
    try std.testing.expectEqual(@as(i64, 1765233669394), custom.timestamp_ms);

    const branch = try createBranchSummaryMessage("went sideways", "turn-7", "2025-12-08T23:41:09.394+01:00");
    try std.testing.expectEqualStrings("turn-7", branch.from_id);
    try std.testing.expectEqual(@as(i64, 1765233669394), branch.timestamp_ms);

    const compaction = try createCompactionSummaryMessage("old context", 1234, "2025-12-08T17:41:09.394-05:00");
    try std.testing.expectEqual(@as(u64, 1234), compaction.tokens_before);
    try std.testing.expectEqual(@as(i64, 1765233669394), compaction.timestamp_ms);

    try std.testing.expectError(error.InvalidTimestamp, parseTimestampMs("not a date"));
}

// Ported from packages/agent/src/harness/messages.ts convertToLlm.
test "agent harness messages convert custom agent messages into LLM user messages" {
    const allocator = std.testing.allocator;
    const base_content = [_]ai.UserContent{.{ .text = .{ .text = "plain user" } }};
    const custom_parts = [_]ai.UserContent{
        .{ .text = .{ .text = "custom text" } },
        .{ .image = .{ .data = "ZmFrZQ==", .mime_type = "image/png" } },
    };
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "assistant pass-through" } }};

    const source = [_]AgentMessage{
        .{ .bash_execution = .{
            .command = "ls",
            .output = "a.txt",
            .exit_code = null,
            .timestamp_ms = 10,
        } },
        .{ .bash_execution = .{
            .command = "secret",
            .output = "hidden",
            .timestamp_ms = 11,
            .exclude_from_context = true,
        } },
        .{ .custom = .{
            .custom_type = "notice",
            .content = .{ .text = "hello from extension" },
            .display = false,
            .timestamp_ms = 12,
        } },
        .{ .custom = .{
            .custom_type = "image",
            .content = .{ .parts = &custom_parts },
            .display = true,
            .timestamp_ms = 13,
        } },
        .{ .branch_summary = .{
            .summary = "changed course",
            .from_id = "abc",
            .timestamp_ms = 14,
        } },
        .{ .compaction_summary = .{
            .summary = "earlier turns",
            .tokens_before = 999,
            .timestamp_ms = 15,
        } },
        .{ .user = .{
            .content = &base_content,
            .timestamp_ms = 16,
        } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = ai.types.api.openai_completions,
            .provider = "openai",
            .model = "gpt-test",
            .timestamp_ms = 17,
        } },
    };

    var converted = try convertToLlmAlloc(allocator, &source);
    defer converted.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), converted.messages.len);
    try expectUserText(converted.messages[0],
        \\Ran `ls`
        \\```
        \\a.txt
        \\```
    , 10);
    try expectUserText(converted.messages[1], "hello from extension", 12);
    switch (converted.messages[2]) {
        .user => |user| {
            try std.testing.expectEqual(@as(i64, 13), user.timestamp_ms);
            try std.testing.expectEqual(@as(usize, 2), user.content.len);
            switch (user.content[1]) {
                .image => |image| try std.testing.expectEqualStrings("image/png", image.mime_type),
                else => return error.ExpectedImageContent,
            }
        },
        else => return error.ExpectedUserMessage,
    }
    try expectUserText(converted.messages[3],
        \\The following is a summary of a branch that this conversation came back from:
        \\
        \\<summary>
        \\changed course</summary>
    , 14);
    try expectUserText(converted.messages[4],
        \\The conversation history before this point was compacted into the following summary:
        \\
        \\<summary>
        \\earlier turns
        \\</summary>
    , 15);
    try expectUserText(converted.messages[5], "plain user", 16);
    switch (converted.messages[6]) {
        .assistant => |assistant| try std.testing.expectEqualStrings("assistant pass-through", assistant.content[0].text.text),
        else => return error.ExpectedAssistantMessage,
    }
}
