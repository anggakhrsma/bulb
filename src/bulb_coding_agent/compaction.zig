const std = @import("std");
const ai = @import("bulb_ai");
const messages_mod = @import("messages.zig");
const session_manager = @import("session_manager.zig");

const FileEntry = session_manager.FileEntry;
const CodingAgentMessage = messages_mod.CodingAgentMessage;

const estimated_image_chars: u64 = 4800;
const tool_result_summary_max_chars: usize = 2000;

pub const summarization_system_prompt =
    \\You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.
    \\
    \\Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
;

pub const summarization_prompt =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, examples, or references needed to continue]
    \\- [Or "(none)" if not applicable]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

pub const update_summarization_prompt =
    \\The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.
    \\
    \\Update the existing structured summary with new information. RULES:
    \\- PRESERVE all existing information from the previous summary
    \\- ADD new progress, decisions, and context from the new messages
    \\- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    \\- UPDATE "Next Steps" based on what was accomplished
    \\- PRESERVE exact file paths, function names, and error messages
    \\- If something is no longer relevant, you may remove it
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[Preserve existing goals, add new ones if the task expanded]
    \\
    \\## Constraints & Preferences
    \\- [Preserve existing, add new ones discovered]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Include previously done items AND newly completed items]
    \\
    \\### In Progress
    \\- [ ] [Current work - update based on progress]
    \\
    \\### Blocked
    \\- [Current blockers - remove if resolved]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale] (preserve all previous, add new)
    \\
    \\## Next Steps
    \\1. [Update based on current state]
    \\
    \\## Critical Context
    \\- [Preserve important context, add new if needed]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

pub const turn_prefix_summarization_prompt =
    \\This is the PREFIX of a turn that was too large to keep. The SUFFIX (recent work) is retained.
    \\
    \\Summarize the prefix to provide context for the retained suffix:
    \\
    \\## Original Request
    \\[What did the user ask for in this turn?]
    \\
    \\## Early Progress
    \\- [Key decisions and work done in the prefix]
    \\
    \\## Context for Suffix
    \\- [Information needed to understand the retained recent work]
    \\
    \\Be concise. Focus on what's needed to understand the kept suffix.
;

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

pub const SummaryRequestOptions = struct {
    api_key: ?[]const u8 = null,
    headers: []const ai.Header = &.{},
    signal: ?*ai.AbortSignal = null,
    custom_instructions: ?[]const u8 = null,
    previous_summary: ?[]const u8 = null,
    thinking_level: ?ai.ThinkingLevel = null,
};

pub const SummaryRequest = struct {
    arena: std.heap.ArenaAllocator,
    context: ai.Context,
    options: ai.SimpleStreamOptions,

    pub fn deinit(self: *SummaryRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
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

pub fn formatFileOperationsAlloc(
    allocator: std.mem.Allocator,
    read_files: []const []const u8,
    modified_files: []const []const u8,
) ![]u8 {
    if (read_files.len == 0 and modified_files.len == 0) return allocator.dupe(u8, "");

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "\n\n");

    var wrote_section = false;
    if (read_files.len > 0) {
        try appendFileOperationSection(allocator, &output, "read-files", read_files);
        wrote_section = true;
    }
    if (modified_files.len > 0) {
        if (wrote_section) try output.appendSlice(allocator, "\n\n");
        try appendFileOperationSection(allocator, &output, "modified-files", modified_files);
    }

    return output.toOwnedSlice(allocator);
}

pub fn serializeConversationAlloc(allocator: std.mem.Allocator, messages: []const ai.Message) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (messages) |message| {
        switch (message) {
            .user => |msg| {
                var content: std.ArrayList(u8) = .empty;
                defer content.deinit(allocator);
                try appendUserContentText(allocator, &content, msg.content);
                if (content.items.len > 0) try appendSerializedPart(allocator, &output, "[User]: ", content.items);
            },
            .assistant => |msg| {
                var text_parts: std.ArrayList(u8) = .empty;
                defer text_parts.deinit(allocator);
                var thinking_parts: std.ArrayList(u8) = .empty;
                defer thinking_parts.deinit(allocator);
                var tool_calls: std.ArrayList(u8) = .empty;
                defer tool_calls.deinit(allocator);

                var text_count: usize = 0;
                var thinking_count: usize = 0;
                var tool_count: usize = 0;
                for (msg.content) |block| {
                    switch (block) {
                        .text => |text| {
                            if (text_count > 0) try text_parts.append(allocator, '\n');
                            try text_parts.appendSlice(allocator, text.text);
                            text_count += 1;
                        },
                        .thinking => |thinking| {
                            if (thinking_count > 0) try thinking_parts.append(allocator, '\n');
                            try thinking_parts.appendSlice(allocator, thinking.thinking);
                            thinking_count += 1;
                        },
                        .tool_call => |tool_call| {
                            if (tool_count > 0) try tool_calls.appendSlice(allocator, "; ");
                            try tool_calls.appendSlice(allocator, tool_call.name);
                            try tool_calls.append(allocator, '(');
                            try appendToolCallArguments(allocator, &tool_calls, tool_call.arguments_json);
                            try tool_calls.append(allocator, ')');
                            tool_count += 1;
                        },
                    }
                }

                if (thinking_count > 0) try appendSerializedPart(allocator, &output, "[Assistant thinking]: ", thinking_parts.items);
                if (text_count > 0) try appendSerializedPart(allocator, &output, "[Assistant]: ", text_parts.items);
                if (tool_count > 0) try appendSerializedPart(allocator, &output, "[Assistant tool calls]: ", tool_calls.items);
            },
            .tool_result => |msg| {
                var content: std.ArrayList(u8) = .empty;
                defer content.deinit(allocator);
                try appendUserContentText(allocator, &content, msg.content);
                if (content.items.len > 0) {
                    var truncated: std.ArrayList(u8) = .empty;
                    defer truncated.deinit(allocator);
                    try appendTruncatedForSummary(allocator, &truncated, content.items, tool_result_summary_max_chars);
                    try appendSerializedPart(allocator, &output, "[Tool result]: ", truncated.items);
                }
            },
        }
    }

    return output.toOwnedSlice(allocator);
}

pub fn historySummaryMaxTokens(model: ai.Model, reserve_tokens: u64) u64 {
    return clampSummaryMaxTokens(model, scaledTokens(reserve_tokens, 8, 10));
}

pub fn turnPrefixSummaryMaxTokens(model: ai.Model, reserve_tokens: u64) u64 {
    return clampSummaryMaxTokens(model, scaledTokens(reserve_tokens, 1, 2));
}

pub fn createSummarizationOptions(
    model: ai.Model,
    max_tokens: u64,
    api_key: ?[]const u8,
    headers: []const ai.Header,
    signal: ?*ai.AbortSignal,
    thinking_level: ?ai.ThinkingLevel,
) ai.SimpleStreamOptions {
    var options = ai.SimpleStreamOptions{ .base = .{
        .max_tokens = max_tokens,
        .api_key = api_key,
        .headers = headers,
        .signal = signal,
    } };
    if (model.reasoning) {
        if (thinking_level) |level| {
            if (level != .off) options.reasoning = level;
        }
    }
    return options;
}

pub fn buildSummaryRequestAlloc(
    allocator: std.mem.Allocator,
    current_messages: []const CodingAgentMessage,
    model: ai.Model,
    reserve_tokens: u64,
    request_options: SummaryRequestOptions,
) !SummaryRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const llm_messages = try messages_mod.convertToLlmAlloc(arena_allocator, current_messages);
    const conversation_text = try serializeConversationAlloc(arena_allocator, llm_messages.messages);

    var base_prompt: []const u8 = if (request_options.previous_summary != null)
        update_summarization_prompt
    else
        summarization_prompt;
    if (request_options.custom_instructions) |custom| {
        base_prompt = try std.fmt.allocPrint(
            arena_allocator,
            "{s}\n\nAdditional focus: {s}",
            .{ base_prompt, custom },
        );
    }

    const prompt_text = if (request_options.previous_summary) |previous|
        try std.fmt.allocPrint(
            arena_allocator,
            "<conversation>\n{s}\n</conversation>\n\n<previous-summary>\n{s}\n</previous-summary>\n\n{s}",
            .{ conversation_text, previous, base_prompt },
        )
    else
        try std.fmt.allocPrint(
            arena_allocator,
            "<conversation>\n{s}\n</conversation>\n\n{s}",
            .{ conversation_text, base_prompt },
        );

    return try buildSummaryRequestFromPromptAlloc(
        &arena,
        prompt_text,
        model,
        historySummaryMaxTokens(model, reserve_tokens),
        request_options,
    );
}

pub fn buildTurnPrefixSummaryRequestAlloc(
    allocator: std.mem.Allocator,
    current_messages: []const CodingAgentMessage,
    model: ai.Model,
    reserve_tokens: u64,
    request_options: SummaryRequestOptions,
) !SummaryRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const llm_messages = try messages_mod.convertToLlmAlloc(arena_allocator, current_messages);
    const conversation_text = try serializeConversationAlloc(arena_allocator, llm_messages.messages);
    const prompt_text = try std.fmt.allocPrint(
        arena_allocator,
        "<conversation>\n{s}\n</conversation>\n\n{s}",
        .{ conversation_text, turn_prefix_summarization_prompt },
    );

    return try buildSummaryRequestFromPromptAlloc(
        &arena,
        prompt_text,
        model,
        turnPrefixSummaryMaxTokens(model, reserve_tokens),
        request_options,
    );
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

fn appendFileOperationSection(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    tag_name: []const u8,
    files: []const []const u8,
) !void {
    try output.append(allocator, '<');
    try output.appendSlice(allocator, tag_name);
    try output.appendSlice(allocator, ">\n");
    for (files, 0..) |file, index| {
        if (index > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, file);
    }
    try output.appendSlice(allocator, "\n</");
    try output.appendSlice(allocator, tag_name);
    try output.append(allocator, '>');
}

fn appendSerializedPart(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    label: []const u8,
    content: []const u8,
) !void {
    if (output.items.len > 0) try output.appendSlice(allocator, "\n\n");
    try output.appendSlice(allocator, label);
    try output.appendSlice(allocator, content);
}

fn appendToolCallArguments(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    arguments_json: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try output.appendSlice(allocator, arguments_json);
            return;
        },
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try output.appendSlice(allocator, arguments_json);
        return;
    }

    var wrote_arg = false;
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (wrote_arg) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, entry.key_ptr.*);
        try output.append(allocator, '=');
        const value_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        defer allocator.free(value_json);
        try output.appendSlice(allocator, value_json);
        wrote_arg = true;
    }
}

fn appendTruncatedForSummary(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    text: []const u8,
    max_chars: usize,
) !void {
    if (text.len <= max_chars) {
        try output.appendSlice(allocator, text);
        return;
    }
    try output.appendSlice(allocator, text[0..max_chars]);
    const marker = try std.fmt.allocPrint(
        allocator,
        "\n\n[... {d} more characters truncated]",
        .{text.len - max_chars},
    );
    defer allocator.free(marker);
    try output.appendSlice(allocator, marker);
}

fn scaledTokens(value: u64, numerator: u64, denominator: u64) u64 {
    return (value *| numerator) / denominator;
}

fn clampSummaryMaxTokens(model: ai.Model, requested: u64) u64 {
    if (model.max_tokens == 0) return requested;
    return @min(requested, model.max_tokens);
}

fn buildSummaryRequestFromPromptAlloc(
    arena: *std.heap.ArenaAllocator,
    prompt_text: []const u8,
    model: ai.Model,
    max_tokens: u64,
    request_options: SummaryRequestOptions,
) !SummaryRequest {
    const arena_allocator = arena.allocator();
    const content = try arena_allocator.alloc(ai.UserContent, 1);
    content[0] = .{ .text = .{ .text = prompt_text } };
    const messages = try arena_allocator.alloc(ai.Message, 1);
    messages[0] = .{ .user = .{
        .content = content,
        .timestamp_ms = 0,
    } };

    return .{
        .arena = arena.*,
        .context = .{
            .system_prompt = summarization_system_prompt,
            .messages = messages,
        },
        .options = createSummarizationOptions(
            model,
            max_tokens,
            request_options.api_key,
            request_options.headers,
            request_options.signal,
            request_options.thinking_level,
        ),
    };
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

fn summaryTestModel(reasoning: bool, max_tokens: u64) ai.Model {
    return .{
        .id = if (reasoning) "reasoning-model" else "non-reasoning-model",
        .name = if (reasoning) "Reasoning Model" else "Non-reasoning Model",
        .api = ai.types.api.anthropic_messages,
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = reasoning,
        .input = &.{"text"},
        .context_window = 200_000,
        .max_tokens = max_tokens,
    };
}

// Ported from packages/coding-agent/test/compaction-serialization.test.ts.
test "serializeConversation truncates long tool results" {
    const allocator = std.testing.allocator;
    const long_content = try repeatAlloc(allocator, "x", 5000);
    defer allocator.free(long_content);
    const hidden_tail = try repeatAlloc(allocator, "x", 3000);
    defer allocator.free(hidden_tail);

    const content = [_]ai.UserContent{.{ .text = .{ .text = long_content } }};
    const messages = [_]ai.Message{.{ .tool_result = .{
        .tool_call_id = "tc1",
        .tool_name = "read",
        .content = &content,
        .is_error = false,
        .timestamp_ms = 1,
    } }};

    const result = try serializeConversationAlloc(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "[Tool result]:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[... 3000 more characters truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, hidden_tail) == null);
    try std.testing.expect(std.mem.indexOf(u8, result, long_content[0..2000]) != null);
}

// Ported from packages/coding-agent/test/compaction-serialization.test.ts.
test "serializeConversation does not truncate short tool results" {
    const allocator = std.testing.allocator;
    const short_content = try repeatAlloc(allocator, "x", 1500);
    defer allocator.free(short_content);
    const expected = try std.fmt.allocPrint(allocator, "[Tool result]: {s}", .{short_content});
    defer allocator.free(expected);

    const content = [_]ai.UserContent{.{ .text = .{ .text = short_content } }};
    const messages = [_]ai.Message{.{ .tool_result = .{
        .tool_call_id = "tc1",
        .tool_name = "read",
        .content = &content,
        .is_error = false,
        .timestamp_ms = 1,
    } }};

    const result = try serializeConversationAlloc(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
    try std.testing.expect(std.mem.indexOf(u8, result, "truncated") == null);
}

// Ported from packages/coding-agent/test/compaction-serialization.test.ts.
test "serializeConversation does not truncate assistant or user messages" {
    const allocator = std.testing.allocator;
    const long_text = try repeatAlloc(allocator, "y", 5000);
    defer allocator.free(long_text);

    const user_content = [_]ai.UserContent{.{ .text = .{ .text = long_text } }};
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = long_text } }};
    const messages = [_]ai.Message{
        .{ .user = .{
            .content = &user_content,
            .timestamp_ms = 1,
        } },
        .{ .assistant = .{
            .content = &assistant_content,
            .api = ai.types.api.anthropic_messages,
            .provider = "anthropic",
            .model = "test",
            .usage = mockUsage(0, 0, 0, 0),
            .stop_reason = .stop,
            .timestamp_ms = 2,
        } },
    };

    const result = try serializeConversationAlloc(allocator, &messages);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "truncated") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, long_text) != null);
}

// Ported from packages/coding-agent/test/compaction-summary-reasoning.test.ts.
test "compaction summary options use reasoning only for supported non-off thinking levels" {
    const reasoning_model = summaryTestModel(true, 8192);
    const non_reasoning_model = summaryTestModel(false, 8192);

    const medium = createSummarizationOptions(reasoning_model, 1600, "test-key", &.{}, null, .medium);
    try std.testing.expectEqual(ai.ThinkingLevel.medium, medium.reasoning.?);
    try std.testing.expectEqualStrings("test-key", medium.base.api_key.?);

    const off = createSummarizationOptions(reasoning_model, 1600, "test-key", &.{}, null, .off);
    try std.testing.expect(off.reasoning == null);
    try std.testing.expectEqualStrings("test-key", off.base.api_key.?);

    const unsupported = createSummarizationOptions(non_reasoning_model, 1600, "test-key", &.{}, null, .medium);
    try std.testing.expect(unsupported.reasoning == null);
    try std.testing.expectEqualStrings("test-key", unsupported.base.api_key.?);
}

// Ported from packages/coding-agent/test/compaction-summary-reasoning.test.ts.
test "compaction summary maxTokens are clamped to model output cap" {
    const model = summaryTestModel(false, 128_000);

    try std.testing.expectEqual(@as(u64, 128_000), historySummaryMaxTokens(model, 500_000));
    try std.testing.expectEqual(@as(u64, 128_000), turnPrefixSummaryMaxTokens(model, 500_000));
}

test "compaction summary request wraps conversation previous summary and focus" {
    const allocator = std.testing.allocator;
    const content = [_]ai.UserContent{.{ .text = .{ .text = "Summarize this." } }};
    const messages = [_]CodingAgentMessage{.{ .user = .{
        .content = &content,
        .timestamp_ms = 1,
    } }};

    var request = try buildSummaryRequestAlloc(
        allocator,
        &messages,
        summaryTestModel(true, 8192),
        2000,
        .{
            .api_key = "test-key",
            .custom_instructions = "focus on file paths",
            .previous_summary = "Existing summary",
            .thinking_level = .medium,
        },
    );
    defer request.deinit();

    try std.testing.expectEqualStrings(summarization_system_prompt, request.context.system_prompt.?);
    try std.testing.expectEqual(@as(u64, 1600), request.options.base.max_tokens.?);
    try std.testing.expectEqual(ai.ThinkingLevel.medium, request.options.reasoning.?);
    const prompt = request.context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<conversation>\n[User]: Summarize this.\n</conversation>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "<previous-summary>\nExisting summary\n</previous-summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, update_summarization_prompt) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Additional focus: focus on file paths") != null);
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
