const std = @import("std");
const ai = @import("bulb_ai");

const messages_mod = @import("messages.zig");
const session_mod = @import("session.zig");
const types = @import("types.zig");

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

pub const branch_summary_preamble =
    \\The user explored a different conversation branch before returning here.
    \\Summary of that exploration:
    \\
    \\
;

pub const branch_summary_prompt =
    \\Create a structured summary of this conversation branch for context when returning later.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What was the user trying to accomplish in this branch?]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Work that was started but not finished]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [What should happen next to continue this work]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
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
    replace_instructions: bool = false,
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

pub const SummaryCompleteFn = *const fn (
    ?*anyopaque,
    ai.Model,
    ai.Context,
    ai.SimpleStreamOptions,
) anyerror!ai.AssistantMessage;

pub const SummaryExecutor = struct {
    ptr: ?*anyopaque = null,
    complete_fn: SummaryCompleteFn,

    pub fn complete(
        self: SummaryExecutor,
        model: ai.Model,
        context: ai.Context,
        options: ai.SimpleStreamOptions,
    ) !ai.AssistantMessage {
        return self.complete_fn(self.ptr, model, context, options);
    }
};

pub const CompactionPreparation = struct {
    arena: std.heap.ArenaAllocator,
    first_kept_entry_id: []const u8,
    messages_to_summarize: []const types.AgentMessage,
    turn_prefix_messages: []const types.AgentMessage,
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

pub const CompactionDetails = struct {
    read_files: []const []const u8 = &.{},
    modified_files: []const []const u8 = &.{},
};

pub const CompactionResult = struct {
    arena: std.heap.ArenaAllocator,
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    details: CompactionDetails = .{},
    details_json: []const u8,

    pub fn deinit(self: *CompactionResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const BranchSummaryDetails = struct {
    read_files: []const []const u8 = &.{},
    modified_files: []const []const u8 = &.{},
};

pub const BranchSummaryResult = struct {
    arena: std.heap.ArenaAllocator,
    summary: []const u8,
    read_files: []const []const u8 = &.{},
    modified_files: []const []const u8 = &.{},

    pub fn deinit(self: *BranchSummaryResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const BranchPreparation = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const types.AgentMessage,
    file_ops: FileOperations,
    total_tokens: u64,

    pub fn deinit(self: *BranchPreparation) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const CollectEntriesResult = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const types.SessionTreeEntry,
    common_ancestor_id: ?[]const u8,

    pub fn deinit(self: *CollectEntriesResult) void {
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

pub fn getLastAssistantUsage(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
) !?ai.Usage {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch_allocator = scratch_arena.allocator();

    var index = entries.len;
    while (index > 0) {
        index -= 1;
        const entry = entries[index];
        if (entry.kind != .message) continue;
        if (try messageFromEntryAlloc(scratch_allocator, entry)) |message| {
            if (getAssistantUsage(message)) |usage| return usage;
        }
    }
    return null;
}

pub fn estimateContextTokens(messages: []const types.AgentMessage) ContextUsageEstimate {
    const usage_info = getLastAssistantUsageInfo(messages);
    if (usage_info == null) {
        var estimated: u64 = 0;
        for (messages) |message| estimated += estimateTokens(message);
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
    for (messages[info.index + 1 ..]) |message| trailing_tokens += estimateTokens(message);
    return .{
        .tokens = usage_tokens + trailing_tokens,
        .usage_tokens = usage_tokens,
        .trailing_tokens = trailing_tokens,
        .last_usage_index = info.index,
    };
}

pub fn shouldCompact(context_tokens: u64, context_window: u64, settings: CompactionSettings) bool {
    if (!settings.enabled) return false;
    return context_tokens > context_window -| settings.reserve_tokens;
}

pub fn estimateTokens(message: types.AgentMessage) u64 {
    var chars: u64 = 0;
    switch (message) {
        .user => |msg| chars = estimateUserContentChars(msg.content),
        .assistant => |msg| {
            for (msg.content) |block| {
                chars += switch (block) {
                    .text => |text| text.text.len,
                    .thinking => |thinking| thinking.thinking.len,
                    .tool_call => |tool_call| tool_call.name.len + tool_call.arguments_json.len,
                };
            }
        },
        .tool_result => |msg| chars = estimateUserContentChars(msg.content),
        .bash_execution => |msg| chars = msg.command.len + msg.output.len,
        .custom => |msg| switch (msg.content) {
            .text => |text| chars = text.len,
            .parts => |parts| chars = estimateUserContentChars(parts),
        },
        .branch_summary => |msg| chars = msg.summary.len,
        .compaction_summary => |msg| chars = msg.summary.len,
    }
    return divCeilBy4(chars);
}

pub fn findCutPoint(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
    start_index: usize,
    end_index: usize,
    keep_recent_tokens: u64,
) !CutPointResult {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch_allocator = scratch_arena.allocator();

    const cut_points = try findValidCutPoints(scratch_allocator, entries, start_index, end_index);
    if (cut_points.len == 0) return .{ .first_kept_entry_index = start_index };

    var accumulated_tokens: u64 = 0;
    var cut_index = cut_points[0];
    var index = end_index;
    while (index > start_index) {
        index -= 1;
        const entry = entries[index];
        if (entry.kind != .message) continue;
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
        if (previous.kind == .compaction) break;
        if (previous.kind == .message) break;
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
    entries: []const types.SessionTreeEntry,
    entry_index: usize,
    start_index: usize,
) !?usize {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    return findTurnStartIndexScratch(scratch_arena.allocator(), entries, entry_index, start_index);
}

pub fn prepareCompaction(
    allocator: std.mem.Allocator,
    path_entries: []const types.SessionTreeEntry,
    settings: CompactionSettings,
) !?CompactionPreparation {
    if (path_entries.len == 0 or path_entries[path_entries.len - 1].kind == .compaction) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var prev_compaction_index: ?usize = null;
    var index = path_entries.len;
    while (index > 0) {
        index -= 1;
        if (path_entries[index].kind == .compaction) {
            prev_compaction_index = index;
            break;
        }
    }

    var previous_summary: ?[]const u8 = null;
    var boundary_start: usize = 0;
    if (prev_compaction_index) |prev_index| {
        const prev_compaction = path_entries[prev_index];
        previous_summary = if (prev_compaction.summary) |summary| try arena_allocator.dupe(u8, summary) else null;
        if (prev_compaction.first_kept_entry_id) |first_kept_id| {
            boundary_start = findEntryIndexById(path_entries, first_kept_id) orelse prev_index + 1;
        } else {
            boundary_start = prev_index + 1;
        }
    }

    var context = try buildAgentMessageContextAlloc(allocator, path_entries);
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
    if (first_kept_entry.id.len == 0) return error.InvalidSession;

    const history_end = if (cut_point.is_split_turn)
        cut_point.turn_start_index orelse cut_point.first_kept_entry_index
    else
        cut_point.first_kept_entry_index;

    var messages_to_summarize: std.ArrayList(types.AgentMessage) = .empty;
    for (path_entries[boundary_start..history_end]) |entry| {
        if (try messageFromEntryForCompactionAlloc(arena_allocator, entry)) |message| {
            try messages_to_summarize.append(arena_allocator, message);
        }
    }

    var turn_prefix_messages: std.ArrayList(types.AgentMessage) = .empty;
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
        .first_kept_entry_id = try arena_allocator.dupe(u8, first_kept_entry.id),
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
        if (!modified.contains(path)) try read_files.append(allocator, path);
    }

    var modified_files: std.ArrayList([]const u8) = .empty;
    errdefer modified_files.deinit(allocator);
    var modified_iter = modified.keyIterator();
    while (modified_iter.next()) |path| try modified_files.append(allocator, path.*);

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
    current_messages: []const types.AgentMessage,
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
    current_messages: []const types.AgentMessage,
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

pub fn buildBranchSummaryRequestAlloc(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
    model: ai.Model,
    request_options: SummaryRequestOptions,
    reserve_tokens: u64,
) !SummaryRequest {
    const token_budget = model.context_window -| reserve_tokens;
    var preparation = try prepareBranchEntriesAlloc(allocator, entries, token_budget);
    defer preparation.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const llm_messages = try messages_mod.convertToLlmAlloc(arena_allocator, preparation.messages);
    const conversation_text = try serializeConversationAlloc(arena_allocator, llm_messages.messages);
    const instructions = if (request_options.replace_instructions and request_options.custom_instructions != null)
        request_options.custom_instructions.?
    else if (request_options.custom_instructions) |custom|
        try std.fmt.allocPrint(arena_allocator, "{s}\n\nAdditional focus: {s}", .{ branch_summary_prompt, custom })
    else
        branch_summary_prompt;
    const prompt_text = try std.fmt.allocPrint(
        arena_allocator,
        "<conversation>\n{s}\n</conversation>\n\n{s}",
        .{ conversation_text, instructions },
    );

    return try buildSummaryRequestFromPromptAlloc(
        &arena,
        prompt_text,
        model,
        2048,
        request_options,
    );
}

pub fn generateSummaryAlloc(
    allocator: std.mem.Allocator,
    current_messages: []const types.AgentMessage,
    model: ai.Model,
    reserve_tokens: u64,
    request_options: SummaryRequestOptions,
    executor: SummaryExecutor,
) ![]u8 {
    var request = try buildSummaryRequestAlloc(allocator, current_messages, model, reserve_tokens, request_options);
    defer request.deinit();

    const response = try executor.complete(model, request.context, request.options);
    return assistantTextOrErrorAlloc(allocator, response, "Summarization");
}

pub fn generateTurnPrefixSummaryAlloc(
    allocator: std.mem.Allocator,
    current_messages: []const types.AgentMessage,
    model: ai.Model,
    reserve_tokens: u64,
    request_options: SummaryRequestOptions,
    executor: SummaryExecutor,
) ![]u8 {
    var request = try buildTurnPrefixSummaryRequestAlloc(allocator, current_messages, model, reserve_tokens, request_options);
    defer request.deinit();

    const response = try executor.complete(model, request.context, request.options);
    return assistantTextOrErrorAlloc(allocator, response, "TurnPrefixSummarization");
}

pub fn compactAlloc(
    allocator: std.mem.Allocator,
    preparation: *const CompactionPreparation,
    model: ai.Model,
    request_options: SummaryRequestOptions,
    executor: SummaryExecutor,
) !CompactionResult {
    if (preparation.first_kept_entry_id.len == 0) return error.InvalidSession;

    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    const scratch_allocator = scratch_arena.allocator();

    const summary_base = if (preparation.is_split_turn and preparation.turn_prefix_messages.len > 0) split: {
        const history_result = if (preparation.messages_to_summarize.len > 0)
            try generateSummaryAlloc(
                scratch_allocator,
                preparation.messages_to_summarize,
                model,
                preparation.settings.reserve_tokens,
                .{
                    .api_key = request_options.api_key,
                    .headers = request_options.headers,
                    .signal = request_options.signal,
                    .custom_instructions = request_options.custom_instructions,
                    .previous_summary = preparation.previous_summary,
                    .thinking_level = request_options.thinking_level,
                },
                executor,
            )
        else
            "No prior history.";

        const turn_prefix_result = try generateTurnPrefixSummaryAlloc(
            scratch_allocator,
            preparation.turn_prefix_messages,
            model,
            preparation.settings.reserve_tokens,
            .{
                .api_key = request_options.api_key,
                .headers = request_options.headers,
                .signal = request_options.signal,
                .thinking_level = request_options.thinking_level,
            },
            executor,
        );
        break :split try std.fmt.allocPrint(
            scratch_allocator,
            "{s}\n\n---\n\n**Turn Context (split turn):**\n\n{s}",
            .{ history_result, turn_prefix_result },
        );
    } else try generateSummaryAlloc(
        scratch_allocator,
        preparation.messages_to_summarize,
        model,
        preparation.settings.reserve_tokens,
        .{
            .api_key = request_options.api_key,
            .headers = request_options.headers,
            .signal = request_options.signal,
            .custom_instructions = request_options.custom_instructions,
            .previous_summary = preparation.previous_summary,
            .thinking_level = request_options.thinking_level,
        },
        executor,
    );

    const file_lists = try computeFileListsAlloc(scratch_allocator, preparation.file_ops);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const read_files = try cloneStringListAlloc(arena_allocator, file_lists.read_files);
    const modified_files = try cloneStringListAlloc(arena_allocator, file_lists.modified_files);
    const file_operations = try formatFileOperationsAlloc(arena_allocator, read_files, modified_files);
    const summary = try std.fmt.allocPrint(arena_allocator, "{s}{s}", .{ summary_base, file_operations });
    const details_json = try detailsJsonAlloc(arena_allocator, read_files, modified_files);

    return .{
        .arena = arena,
        .summary = summary,
        .first_kept_entry_id = try arena_allocator.dupe(u8, preparation.first_kept_entry_id),
        .tokens_before = preparation.tokens_before,
        .details = .{ .read_files = read_files, .modified_files = modified_files },
        .details_json = details_json,
    };
}

pub fn collectEntriesForBranchSummaryAlloc(
    allocator: std.mem.Allocator,
    session: anytype,
    old_leaf_id: ?[]const u8,
    target_id: []const u8,
) !CollectEntriesResult {
    if (old_leaf_id == null) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        return .{
            .arena = arena,
            .entries = &.{},
            .common_ancestor_id = null,
        };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const old_path = try session.getBranchAlloc(arena_allocator, old_leaf_id);
    const target_path = try session.getBranchAlloc(arena_allocator, target_id);

    var old_ids = std.StringHashMap(void).init(arena_allocator);
    for (old_path) |entry| try old_ids.put(entry.id, {});

    var common_ancestor_id: ?[]const u8 = null;
    var target_index = target_path.len;
    while (target_index > 0) {
        target_index -= 1;
        if (old_ids.contains(target_path[target_index].id)) {
            common_ancestor_id = try arena_allocator.dupe(u8, target_path[target_index].id);
            break;
        }
    }

    var reverse: std.ArrayList(types.SessionTreeEntry) = .empty;
    var current: ?[]const u8 = old_leaf_id;
    while (current) |id| {
        if (common_ancestor_id) |ancestor| {
            if (std.mem.eql(u8, id, ancestor)) break;
        }
        const entry = session.getEntry(id) orelse return error.InvalidSession;
        try reverse.append(arena_allocator, entry);
        current = entry.parent_id;
    }

    const entries = try arena_allocator.alloc(types.SessionTreeEntry, reverse.items.len);
    for (reverse.items, 0..) |entry, index| {
        entries[entries.len - index - 1] = entry;
    }

    return .{
        .arena = arena,
        .entries = entries,
        .common_ancestor_id = common_ancestor_id,
    };
}

pub fn prepareBranchEntriesAlloc(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
    token_budget: u64,
) !BranchPreparation {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var mutable = MutableFileOperations.init(arena_allocator);
    for (entries) |entry| {
        if (entry.kind == .branch_summary and !(entry.from_hook orelse false)) {
            try extractDetailsFileOperations(arena_allocator, &mutable, entry.details_json);
        }
    }

    var messages: std.ArrayList(types.AgentMessage) = .empty;
    var total_tokens: u64 = 0;
    var index = entries.len;
    while (index > 0) {
        index -= 1;
        const entry = entries[index];
        const message = try messageFromEntryForBranchAlloc(arena_allocator, entry) orelse continue;
        try extractFileOpsFromMessage(arena_allocator, &mutable, message);

        const tokens = estimateTokens(message);
        if (token_budget > 0 and total_tokens + tokens > token_budget) {
            if (entry.kind == .compaction or entry.kind == .branch_summary) {
                if (total_tokens < (token_budget * 9) / 10) {
                    try messages.insert(arena_allocator, 0, message);
                    total_tokens += tokens;
                }
            }
            break;
        }

        try messages.insert(arena_allocator, 0, message);
        total_tokens += tokens;
    }

    const file_ops = FileOperations{
        .read = try mapKeysAlloc(arena_allocator, &mutable.read),
        .written = try mapKeysAlloc(arena_allocator, &mutable.written),
        .edited = try mapKeysAlloc(arena_allocator, &mutable.edited),
    };

    return .{
        .arena = arena,
        .messages = try messages.toOwnedSlice(arena_allocator),
        .file_ops = file_ops,
        .total_tokens = total_tokens,
    };
}

pub fn generateBranchSummaryAlloc(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
    model: ai.Model,
    request_options: SummaryRequestOptions,
    executor: SummaryExecutor,
    reserve_tokens: u64,
) !BranchSummaryResult {
    const token_budget = model.context_window -| reserve_tokens;
    var preparation = try prepareBranchEntriesAlloc(allocator, entries, token_budget);
    defer preparation.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    if (preparation.messages.len == 0) {
        return .{
            .arena = arena,
            .summary = try arena_allocator.dupe(u8, "No content to summarize"),
            .read_files = &.{},
            .modified_files = &.{},
        };
    }

    var request = try buildBranchSummaryRequestAlloc(
        arena_allocator,
        entries,
        model,
        request_options,
        reserve_tokens,
    );
    defer request.deinit();

    const response = try executor.complete(model, request.context, request.options);
    const text = try assistantTextOrErrorAlloc(arena_allocator, response, "BranchSummary");
    const lists = try computeFileListsAlloc(arena_allocator, preparation.file_ops);
    const read_files = try cloneStringListAlloc(arena_allocator, lists.read_files);
    const modified_files = try cloneStringListAlloc(arena_allocator, lists.modified_files);
    const file_operations = try formatFileOperationsAlloc(arena_allocator, read_files, modified_files);
    const body = if (text.len > 0) text else "No summary generated";
    const summary = try std.fmt.allocPrint(arena_allocator, "{s}{s}{s}", .{ branch_summary_preamble, body, file_operations });

    return .{
        .arena = arena,
        .summary = summary,
        .read_files = read_files,
        .modified_files = modified_files,
    };
}

const OwnedAgentMessages = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const types.AgentMessage,

    fn deinit(self: *OwnedAgentMessages) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn buildAgentMessageContextAlloc(
    allocator: std.mem.Allocator,
    path_entries: []const types.SessionTreeEntry,
) !OwnedAgentMessages {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var compaction_index: ?usize = null;
    for (path_entries, 0..) |entry, index| {
        if (entry.kind == .compaction) compaction_index = index;
    }

    var result: std.ArrayList(types.AgentMessage) = .empty;
    if (compaction_index) |index| {
        if (try messageFromEntryForBranchAlloc(arena_allocator, path_entries[index])) |message| {
            try result.append(arena_allocator, message);
        }
        var found_first_kept = false;
        for (path_entries[0..index]) |entry| {
            if (path_entries[index].first_kept_entry_id) |first_kept| {
                if (std.mem.eql(u8, entry.id, first_kept)) found_first_kept = true;
            }
            if (found_first_kept) {
                if (try messageFromEntryForBranchAlloc(arena_allocator, entry)) |message| {
                    try result.append(arena_allocator, message);
                }
            }
        }
        for (path_entries[index + 1 ..]) |entry| {
            if (try messageFromEntryForBranchAlloc(arena_allocator, entry)) |message| {
                try result.append(arena_allocator, message);
            }
        }
    } else {
        for (path_entries) |entry| {
            if (try messageFromEntryForBranchAlloc(arena_allocator, entry)) |message| {
                try result.append(arena_allocator, message);
            }
        }
    }

    return .{
        .arena = arena,
        .messages = try result.toOwnedSlice(arena_allocator),
    };
}

fn getAssistantUsage(message: types.AgentMessage) ?ai.Usage {
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

fn getLastAssistantUsageInfo(messages: []const types.AgentMessage) ?AssistantUsageInfo {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (getAssistantUsage(messages[index])) |usage| return .{ .usage = usage, .index = index };
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
    entries: []const types.SessionTreeEntry,
    start_index: usize,
    end_index: usize,
) ![]usize {
    var cut_points: std.ArrayList(usize) = .empty;
    errdefer cut_points.deinit(allocator);

    for (entries[start_index..end_index], start_index..) |entry, index| {
        if (entry.kind == .message) {
            if (try messageFromEntryAlloc(allocator, entry)) |message| {
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
        if (entry.kind == .branch_summary or entry.kind == .custom_message) {
            try cut_points.append(allocator, index);
        }
    }

    return cut_points.toOwnedSlice(allocator);
}

fn findTurnStartIndexScratch(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
    entry_index: usize,
    start_index: usize,
) !?usize {
    var index = entry_index + 1;
    while (index > start_index) {
        index -= 1;
        const entry = entries[index];
        if (entry.kind == .branch_summary or entry.kind == .custom_message) return index;
        if (entry.kind == .message) {
            if (try messageFromEntryAlloc(allocator, entry)) |message| {
                switch (message) {
                    .user, .bash_execution => return index,
                    else => {},
                }
            }
        }
    }
    return null;
}

fn isEntryUserMessage(allocator: std.mem.Allocator, entry: types.SessionTreeEntry) !bool {
    if (entry.kind != .message) return false;
    const message = try messageFromEntryAlloc(allocator, entry);
    if (message) |msg| return msg == .user;
    return false;
}

fn messageFromEntryForCompactionAlloc(
    allocator: std.mem.Allocator,
    entry: types.SessionTreeEntry,
) !?types.AgentMessage {
    if (entry.kind == .compaction) return null;
    return messageFromEntryForBranchAlloc(allocator, entry);
}

fn messageFromEntryForBranchAlloc(
    allocator: std.mem.Allocator,
    entry: types.SessionTreeEntry,
) !?types.AgentMessage {
    switch (entry.kind) {
        .message => {
            const message = try messageFromEntryAlloc(allocator, entry) orelse return null;
            if (message == .tool_result) return null;
            return message;
        },
        .custom_message => {
            const custom_type = entry.custom_type orelse return null;
            const content_json = entry.content_json orelse return null;
            const content = try customContentFromJsonAlloc(allocator, content_json);
            const message = try messages_mod.createCustomMessage(
                try allocator.dupe(u8, custom_type),
                content,
                entry.display orelse true,
                if (entry.details_json) |details| try allocator.dupe(u8, details) else null,
                entry.timestamp,
            );
            return .{ .custom = message };
        },
        .branch_summary => {
            const summary = entry.summary orelse return null;
            const from_id = entry.from_id orelse "";
            return .{ .branch_summary = try messages_mod.createBranchSummaryMessage(
                try allocator.dupe(u8, summary),
                try allocator.dupe(u8, from_id),
                entry.timestamp,
            ) };
        },
        .compaction => {
            const summary = entry.summary orelse return null;
            return .{ .compaction_summary = try messages_mod.createCompactionSummaryMessage(
                try allocator.dupe(u8, summary),
                entry.tokens_before orelse 0,
                entry.timestamp,
            ) };
        },
        else => return null,
    }
}

fn messageFromEntryAlloc(
    allocator: std.mem.Allocator,
    entry: types.SessionTreeEntry,
) !?types.AgentMessage {
    const message_json = entry.message_json orelse return null;
    return messageFromJsonAlloc(allocator, message_json);
}

fn messageFromJsonAlloc(allocator: std.mem.Allocator, message_json: []const u8) !?types.AgentMessage {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, message_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    const role = optionalString(object, "role") orelse return null;

    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = .{
            .content = try userContentFieldAlloc(allocator, object, "content"),
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        return .{ .assistant = .{
            .content = try assistantContentFieldAlloc(allocator, object, "content"),
            .api = try allocator.dupe(u8, optionalString(object, "api") orelse ai.types.api.anthropic_messages),
            .provider = try allocator.dupe(u8, optionalString(object, "provider") orelse ""),
            .model = try allocator.dupe(u8, optionalString(object, "model") orelse ""),
            .usage = usageField(object),
            .stop_reason = stopReasonFromString(optionalString(object, "stopReason") orelse "stop"),
            .error_message = if (optionalString(object, "errorMessage")) |message| try allocator.dupe(u8, message) else null,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }
    if (std.mem.eql(u8, role, "toolResult")) {
        return .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, optionalString(object, "toolCallId") orelse ""),
            .tool_name = try allocator.dupe(u8, optionalString(object, "toolName") orelse ""),
            .content = try userContentFieldAlloc(allocator, object, "content"),
            .is_error = optionalBool(object, "isError") orelse false,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }
    if (std.mem.eql(u8, role, "bashExecution")) {
        return .{ .bash_execution = .{
            .command = try allocator.dupe(u8, optionalString(object, "command") orelse ""),
            .output = try allocator.dupe(u8, optionalString(object, "output") orelse ""),
            .exit_code = optionalI64(object, "exitCode"),
            .cancelled = optionalBool(object, "cancelled") orelse false,
            .truncated = optionalBool(object, "truncated") orelse false,
            .full_output_path = if (optionalString(object, "fullOutputPath")) |path| try allocator.dupe(u8, path) else null,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
            .exclude_from_context = optionalBool(object, "excludeFromContext") orelse false,
        } };
    }
    if (std.mem.eql(u8, role, "custom")) {
        const content_value = object.get("content") orelse std.json.Value{ .string = "" };
        return .{ .custom = .{
            .custom_type = try allocator.dupe(u8, optionalString(object, "customType") orelse ""),
            .content = try customContentFromValueAlloc(allocator, content_value),
            .display = optionalBool(object, "display") orelse true,
            .details_json = if (object.get("details")) |details| try std.json.Stringify.valueAlloc(allocator, details, .{}) else null,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }
    if (std.mem.eql(u8, role, "branchSummary")) {
        return .{ .branch_summary = .{
            .summary = try allocator.dupe(u8, optionalString(object, "summary") orelse ""),
            .from_id = try allocator.dupe(u8, optionalString(object, "fromId") orelse ""),
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }
    if (std.mem.eql(u8, role, "compactionSummary")) {
        return .{ .compaction_summary = .{
            .summary = try allocator.dupe(u8, optionalString(object, "summary") orelse ""),
            .tokens_before = optionalU64(object, "tokensBefore") orelse 0,
            .timestamp_ms = optionalI64(object, "timestamp") orelse 0,
        } };
    }
    return null;
}

fn extractFileOperationsAlloc(
    allocator: std.mem.Allocator,
    messages_to_summarize: []const types.AgentMessage,
    turn_prefix_messages: []const types.AgentMessage,
    entries: []const types.SessionTreeEntry,
    prev_compaction_index: ?usize,
) !FileOperations {
    var mutable = MutableFileOperations.init(allocator);
    if (prev_compaction_index) |index| {
        const entry = entries[index];
        if (!(entry.from_hook orelse false)) {
            try extractDetailsFileOperations(allocator, &mutable, entry.details_json);
        }
    }
    for (messages_to_summarize) |message| try extractFileOpsFromMessage(allocator, &mutable, message);
    for (turn_prefix_messages) |message| try extractFileOpsFromMessage(allocator, &mutable, message);
    return .{
        .read = try mapKeysAlloc(allocator, &mutable.read),
        .written = try mapKeysAlloc(allocator, &mutable.written),
        .edited = try mapKeysAlloc(allocator, &mutable.edited),
    };
}

fn extractDetailsFileOperations(
    allocator: std.mem.Allocator,
    mutable: *MutableFileOperations,
    details_json: ?[]const u8,
) !void {
    const json = details_json orelse return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    if (parsed.value.object.get("readFiles")) |read_files| try addStringArrayToMap(allocator, &mutable.read, read_files);
    if (parsed.value.object.get("modifiedFiles")) |modified_files| try addStringArrayToMap(allocator, &mutable.edited, modified_files);
}

fn extractFileOpsFromMessage(
    allocator: std.mem.Allocator,
    mutable: *MutableFileOperations,
    message: types.AgentMessage,
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
    while (iterator.next()) |key| try keys.append(allocator, key.*);
    sortStrings(keys.items);
    return keys.toOwnedSlice(allocator);
}

fn userContentFieldAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const ai.UserContent {
    const value = object.get(key) orelse return &.{};
    return userContentFromValueAlloc(allocator, value);
}

fn userContentFromValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]const ai.UserContent {
    switch (value) {
        .string => |text| {
            const content = try allocator.alloc(ai.UserContent, 1);
            content[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
            return content;
        },
        .array => |array| {
            var content: std.ArrayList(ai.UserContent) = .empty;
            for (array.items) |item| {
                if (item != .object) continue;
                const block_type = optionalString(item.object, "type") orelse continue;
                if (std.mem.eql(u8, block_type, "text")) {
                    try content.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, optionalString(item.object, "text") orelse "") } });
                } else if (std.mem.eql(u8, block_type, "image")) {
                    try content.append(allocator, .{ .image = .{
                        .mime_type = try allocator.dupe(u8, optionalString(item.object, "mimeType") orelse "image/png"),
                        .data = try allocator.dupe(u8, optionalString(item.object, "data") orelse ""),
                    } });
                }
            }
            return content.toOwnedSlice(allocator);
        },
        else => return &.{},
    }
}

fn assistantContentFieldAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const ai.AssistantContent {
    const value = object.get(key) orelse return &.{};
    if (value != .array) return &.{};

    var content: std.ArrayList(ai.AssistantContent) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const block_type = optionalString(item.object, "type") orelse continue;
        if (std.mem.eql(u8, block_type, "text")) {
            try content.append(allocator, .{ .text = .{ .text = try allocator.dupe(u8, optionalString(item.object, "text") orelse "") } });
        } else if (std.mem.eql(u8, block_type, "thinking")) {
            try content.append(allocator, .{ .thinking = .{ .thinking = try allocator.dupe(u8, optionalString(item.object, "thinking") orelse "") } });
        } else if (std.mem.eql(u8, block_type, "toolCall")) {
            const arguments_json = if (item.object.get("arguments")) |arguments|
                try std.json.Stringify.valueAlloc(allocator, arguments, .{})
            else
                try allocator.dupe(u8, "{}");
            try content.append(allocator, .{ .tool_call = .{
                .id = try allocator.dupe(u8, optionalString(item.object, "id") orelse ""),
                .name = try allocator.dupe(u8, optionalString(item.object, "name") orelse ""),
                .arguments_json = arguments_json,
            } });
        }
    }
    return content.toOwnedSlice(allocator);
}

fn customContentFromJsonAlloc(allocator: std.mem.Allocator, content_json: []const u8) !types.CustomMessageContent {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .text = try allocator.dupe(u8, "") },
    };
    defer parsed.deinit();
    return customContentFromValueAlloc(allocator, parsed.value);
}

fn customContentFromValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) !types.CustomMessageContent {
    return switch (value) {
        .string => |text| .{ .text = try allocator.dupe(u8, text) },
        .array => .{ .parts = try userContentFromValueAlloc(allocator, value) },
        else => .{ .text = try std.json.Stringify.valueAlloc(allocator, value, .{}) },
    };
}

fn usageField(object: std.json.ObjectMap) ai.Usage {
    const usage = object.get("usage") orelse return .{};
    if (usage != .object) return .{};
    return .{
        .input = optionalU64(usage.object, "input") orelse 0,
        .output = optionalU64(usage.object, "output") orelse 0,
        .cache_read = optionalU64(usage.object, "cacheRead") orelse 0,
        .cache_write = optionalU64(usage.object, "cacheWrite") orelse 0,
        .total_tokens = optionalU64(usage.object, "totalTokens") orelse 0,
    };
}

fn stopReasonFromString(value: []const u8) ai.StopReason {
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "tool_use") or std.mem.eql(u8, value, "toolUse")) return .tool_use;
    if (std.mem.eql(u8, value, "error")) return .@"error";
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return .stop;
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
    const marker = try std.fmt.allocPrint(allocator, "\n\n[... {d} more characters truncated]", .{text.len - max_chars});
    defer allocator.free(marker);
    try output.appendSlice(allocator, marker);
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
    messages[0] = .{ .user = .{ .content = content, .timestamp_ms = 0 } };

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

fn assistantTextOrErrorAlloc(
    allocator: std.mem.Allocator,
    response: ai.AssistantMessage,
    comptime prefix: []const u8,
) ![]u8 {
    if (response.stop_reason == .aborted) return error.SummarizationAborted;
    if (response.stop_reason == .@"error") {
        if (std.mem.eql(u8, prefix, "TurnPrefixSummarization")) return error.TurnPrefixSummarizationFailed;
        if (std.mem.eql(u8, prefix, "BranchSummary")) return error.BranchSummaryFailed;
        return error.SummarizationFailed;
    }
    return assistantTextAlloc(allocator, response);
}

fn assistantTextAlloc(allocator: std.mem.Allocator, response: ai.AssistantMessage) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var text_count: usize = 0;
    for (response.content) |block| {
        if (block != .text) continue;
        if (text_count > 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, block.text.text);
        text_count += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn cloneStringListAlloc(allocator: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |value, index| cloned[index] = try allocator.dupe(u8, value);
    return cloned;
}

fn detailsJsonAlloc(
    allocator: std.mem.Allocator,
    read_files: []const []const u8,
    modified_files: []const []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("readFiles");
    try json.beginArray();
    for (read_files) |path| try json.write(path);
    try json.endArray();
    try json.objectField("modifiedFiles");
    try json.beginArray();
    for (modified_files) |path| try json.write(path);
    try json.endArray();
    try json.endObject();
    return output.toOwnedSlice();
}

fn scaledTokens(value: u64, numerator: u64, denominator: u64) u64 {
    return (value *| numerator) / denominator;
}

fn clampSummaryMaxTokens(model: ai.Model, requested: u64) u64 {
    if (model.max_tokens == 0) return requested;
    return @min(requested, model.max_tokens);
}

fn sortStrings(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

fn findEntryIndexById(entries: []const types.SessionTreeEntry, id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, id)) return index;
    }
    return null;
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

fn optionalI64(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| if (std.math.isFinite(float) and @floor(float) == float) @intFromFloat(float) else null,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (std.math.isFinite(float) and float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        else => null,
    };
}

fn repeatAlloc(allocator: std.mem.Allocator, text: []const u8, count: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (0..count) |_| try output.appendSlice(allocator, text);
    return output.toOwnedSlice(allocator);
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

fn userMessageJsonAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return session_mod.userMessageJsonAlloc(allocator, text);
}

fn assistantMessageJsonWithUsageAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    usage: ai.Usage,
    stop_reason: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .role = "assistant",
        .content = .{.{ .type = "text", .text = text }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = .{
            .input = usage.input,
            .output = usage.output,
            .cacheRead = usage.cache_read,
            .cacheWrite = usage.cache_write,
            .totalTokens = usage.total_tokens,
        },
        .stopReason = stop_reason,
        .timestamp = @as(i64, 1),
    }, .{});
}

fn assistantToolCallJsonAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    path: []const u8,
    usage: ai.Usage,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .role = "assistant",
        .content = .{.{
            .type = "toolCall",
            .id = "tool-1",
            .name = name,
            .arguments = .{ .path = path },
        }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = .{
            .input = usage.input,
            .output = usage.output,
            .cacheRead = usage.cache_read,
            .cacheWrite = usage.cache_write,
            .totalTokens = usage.total_tokens,
        },
        .stopReason = "tool_use",
        .timestamp = @as(i64, 1),
    }, .{});
}

const SummaryExecutorCall = struct {
    max_tokens: ?u64,
    reasoning: ?ai.ThinkingLevel,
    api_key: ?[]const u8,
    prompt: []const u8,
};

const MockSummaryExecutor = struct {
    allocator: std.mem.Allocator,
    calls: std.ArrayList(SummaryExecutorCall) = .empty,
    owned_content: std.ArrayList([]ai.AssistantContent) = .empty,
    responses: []const []const u8 = &.{"## Goal\nTest summary"},
    fail_on_call: ?usize = null,
    abort_on_call: ?usize = null,

    fn init(allocator: std.mem.Allocator, responses: []const []const u8) MockSummaryExecutor {
        return .{ .allocator = allocator, .responses = responses };
    }

    fn deinit(self: *MockSummaryExecutor) void {
        for (self.calls.items) |call| {
            self.allocator.free(call.prompt);
            if (call.api_key) |api_key| self.allocator.free(api_key);
        }
        self.calls.deinit(self.allocator);
        for (self.owned_content.items) |content| self.allocator.free(content);
        self.owned_content.deinit(self.allocator);
    }

    fn executor(self: *MockSummaryExecutor) SummaryExecutor {
        return .{ .ptr = self, .complete_fn = complete };
    }

    fn complete(
        ptr: ?*anyopaque,
        model: ai.Model,
        context: ai.Context,
        options: ai.SimpleStreamOptions,
    ) !ai.AssistantMessage {
        const self: *MockSummaryExecutor = @ptrCast(@alignCast(ptr.?));
        const call_index = self.calls.items.len;
        const prompt = firstPromptText(context);
        const prompt_copy = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(prompt_copy);
        const api_key_copy = if (options.base.api_key) |api_key| try self.allocator.dupe(u8, api_key) else null;
        errdefer if (api_key_copy) |api_key| self.allocator.free(api_key);

        try self.calls.append(self.allocator, .{
            .max_tokens = options.base.max_tokens,
            .reasoning = options.reasoning,
            .api_key = api_key_copy,
            .prompt = prompt_copy,
        });

        if (self.fail_on_call) |fail_index| {
            if (call_index == fail_index) {
                return .{
                    .content = &.{},
                    .api = model.api,
                    .provider = model.provider,
                    .model = model.id,
                    .stop_reason = .@"error",
                    .error_message = "mock summary failure",
                };
            }
        }
        if (self.abort_on_call) |abort_index| {
            if (call_index == abort_index) {
                return .{
                    .content = &.{},
                    .api = model.api,
                    .provider = model.provider,
                    .model = model.id,
                    .stop_reason = .aborted,
                    .error_message = "mock aborted",
                };
            }
        }

        const response_text = if (self.responses.len == 0)
            ""
        else if (call_index < self.responses.len)
            self.responses[call_index]
        else
            self.responses[self.responses.len - 1];
        const content = try self.allocator.alloc(ai.AssistantContent, 1);
        errdefer self.allocator.free(content);
        content[0] = .{ .text = .{ .text = response_text } };
        try self.owned_content.append(self.allocator, content);
        return .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = mockUsage(10, 10, 0, 0),
            .stop_reason = .stop,
        };
    }
};

fn firstPromptText(context: ai.Context) []const u8 {
    if (context.messages.len == 0) return "";
    return switch (context.messages[0]) {
        .user => |message| if (message.content.len == 0) "" else switch (message.content[0]) {
            .text => |text| text.text,
            .image => "",
        },
        else => "",
    };
}

test "agent compaction calculates thresholds and token estimates" {
    try std.testing.expectEqual(@as(u64, 1800), calculateContextTokens(mockUsage(1000, 500, 200, 100)));
    try std.testing.expectEqual(@as(u64, 0), calculateContextTokens(mockUsage(0, 0, 0, 0)));

    const settings: CompactionSettings = .{ .enabled = true, .reserve_tokens = 10_000, .keep_recent_tokens = 20_000 };
    try std.testing.expect(shouldCompact(95_000, 100_000, settings));
    try std.testing.expect(!shouldCompact(89_000, 100_000, settings));
    try std.testing.expect(!shouldCompact(95_000, 100_000, .{ .enabled = false, .reserve_tokens = 10_000, .keep_recent_tokens = 20_000 }));

    const assistant_content = [_]ai.AssistantContent{
        .{ .thinking = .{ .thinking = "thinking" } },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = "{\"path\":\"file.ts\"}" } },
    };
    const assistant = types.AgentMessage{ .assistant = .{
        .content = &assistant_content,
        .api = ai.types.api.anthropic_messages,
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = mockUsage(10, 5, 3, 2),
    } };
    try std.testing.expect(estimateTokens(assistant) > 0);
    const user_content = [_]ai.UserContent{.{ .text = .{ .text = "tail" } }};
    const agent_messages = [_]types.AgentMessage{
        assistant,
        .{ .user = .{ .content = &user_content, .timestamp_ms = 1 } },
    };
    const estimate = estimateContextTokens(&agent_messages);
    try std.testing.expectEqual(@as(u64, 20), estimate.usage_tokens);
    try std.testing.expectEqual(@as(?usize, 0), estimate.last_usage_index);
}

test "agent compaction serializes conversation with truncated tool results" {
    const allocator = std.testing.allocator;
    const long_content = try repeatAlloc(allocator, "x", 5000);
    defer allocator.free(long_content);
    const hidden_tail = try repeatAlloc(allocator, "x", 3000);
    defer allocator.free(hidden_tail);

    const content = [_]ai.UserContent{.{ .text = .{ .text = long_content } }};
    const llm_messages = [_]ai.Message{.{ .tool_result = .{
        .tool_call_id = "tc1",
        .tool_name = "read",
        .content = &content,
        .is_error = false,
        .timestamp_ms = 1,
    } }};

    const result = try serializeConversationAlloc(allocator, &llm_messages);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "[Tool result]:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "[... 3000 more characters truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, hidden_tail) == null);
}

test "agent compaction finds cut points and prepares repeated compaction" {
    const session_storage = @import("session_storage.zig");
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);

    const user1_json = try userMessageJsonAlloc(allocator, "user msg 1");
    defer allocator.free(user1_json);
    const assistant1_json = try assistantMessageJsonWithUsageAlloc(allocator, "assistant msg 1", mockUsage(100, 50, 0, 0), "stop");
    defer allocator.free(assistant1_json);
    const user2_json = try userMessageJsonAlloc(allocator, "user msg 2 - kept");
    defer allocator.free(user2_json);
    const assistant2_json = try assistantMessageJsonWithUsageAlloc(allocator, "assistant msg 2", mockUsage(5000, 1000, 0, 0), "stop");
    defer allocator.free(assistant2_json);
    const user3_json = try userMessageJsonAlloc(allocator, "user msg 3");
    defer allocator.free(user3_json);
    const assistant3_json = try assistantMessageJsonWithUsageAlloc(allocator, "assistant msg 3", mockUsage(8000, 2000, 0, 0), "stop");
    defer allocator.free(assistant3_json);

    _ = try session.appendMessageJson(user1_json);
    _ = try session.appendMessageJson(assistant1_json);
    const kept_user_id = try session.appendMessageJson(user2_json);
    _ = try session.appendMessageJson(assistant2_json);
    _ = try session.appendCompaction("First summary", kept_user_id, 10_000, null, null);
    _ = try session.appendMessageJson(user3_json);
    _ = try session.appendMessageJson(assistant3_json);

    const entries = session.getEntries();
    const cut = try findCutPoint(allocator, entries, 0, entries.len, 1);
    try std.testing.expect(cut.first_kept_entry_index < entries.len);

    var preparation = (try prepareCompaction(allocator, entries, default_compaction_settings)).?;
    defer preparation.deinit();
    try std.testing.expectEqualStrings("First summary", preparation.previous_summary.?);
    try std.testing.expect(preparation.first_kept_entry_id.len > 0);
    try std.testing.expect(preparation.tokens_before > 0);
}

test "agent compaction prepares split turns and file operation details" {
    const session_storage = @import("session_storage.zig");
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);

    const user_json = try userMessageJsonAlloc(allocator, "large turn");
    defer allocator.free(user_json);
    const read_json = try assistantToolCallJsonAlloc(allocator, "read", "src/a.zig", mockUsage(100, 50, 0, 0));
    defer allocator.free(read_json);
    const edit_json = try assistantToolCallJsonAlloc(allocator, "edit", "src/b.zig", mockUsage(100, 50, 0, 0));
    defer allocator.free(edit_json);
    const write_json = try assistantToolCallJsonAlloc(allocator, "write", "src/c.zig", mockUsage(8000, 2000, 0, 0));
    defer allocator.free(write_json);

    const first_id = try session.appendMessageJson(user_json);
    _ = try session.appendMessageJson(read_json);
    _ = try session.appendCompaction(
        "First summary",
        first_id,
        10_000,
        "{\"readFiles\":[\"old-read.zig\"],\"modifiedFiles\":[\"old-edit.zig\"]}",
        false,
    );
    _ = try session.appendMessageJson(edit_json);
    _ = try session.appendMessageJson(write_json);

    var preparation = (try prepareCompaction(allocator, session.getEntries(), .{
        .enabled = true,
        .reserve_tokens = 100,
        .keep_recent_tokens = 1,
    })).?;
    defer preparation.deinit();

    const lists = try computeFileListsAlloc(allocator, preparation.file_ops);
    defer allocator.free(lists.read_files);
    defer allocator.free(lists.modified_files);
    try std.testing.expect(containsString(lists.read_files, "old-read.zig"));
    try std.testing.expect(containsString(lists.modified_files, "old-edit.zig"));
    try std.testing.expect(containsString(lists.modified_files, "src/b.zig"));
}

test "agent compaction builds summary requests and compact results" {
    const allocator = std.testing.allocator;
    const content = [_]ai.UserContent{.{ .text = .{ .text = "Summarize this." } }};
    const agent_messages = [_]types.AgentMessage{.{ .user = .{ .content = &content, .timestamp_ms = 1 } }};

    var mock = MockSummaryExecutor.init(allocator, &.{"history summary"});
    defer mock.deinit();
    const summary = try generateSummaryAlloc(
        allocator,
        &agent_messages,
        summaryTestModel(true, 8192),
        2000,
        .{ .api_key = "test-key", .thinking_level = .medium, .previous_summary = "old summary", .custom_instructions = "focus" },
        mock.executor(),
    );
    defer allocator.free(summary);
    try std.testing.expectEqualStrings("history summary", summary);
    try std.testing.expectEqual(ai.ThinkingLevel.medium, mock.calls.items[0].reasoning.?);
    try std.testing.expectEqualStrings("test-key", mock.calls.items[0].api_key.?);
    try std.testing.expect(std.mem.indexOf(u8, mock.calls.items[0].prompt, "<previous-summary>\nold summary\n</previous-summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.calls.items[0].prompt, "Additional focus: focus") != null);

    var preparation: CompactionPreparation = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .first_kept_entry_id = "entry-keep",
        .messages_to_summarize = &agent_messages,
        .turn_prefix_messages = &agent_messages,
        .is_split_turn = true,
        .tokens_before = 600_000,
        .file_ops = .{
            .read = &.{"src/a.zig"},
            .written = &.{"src/b.zig"},
            .edited = &.{"src/c.zig"},
        },
        .settings = .{ .enabled = true, .reserve_tokens = 500_000, .keep_recent_tokens = 20_000 },
    };
    defer preparation.arena.deinit();

    var compact_mock = MockSummaryExecutor.init(allocator, &.{ "history summary", "turn prefix summary" });
    defer compact_mock.deinit();
    var result = try compactAlloc(
        allocator,
        &preparation,
        summaryTestModel(false, 128_000),
        .{ .api_key = "test-key" },
        compact_mock.executor(),
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), compact_mock.calls.items.len);
    try std.testing.expectEqual(@as(u64, 128_000), compact_mock.calls.items[0].max_tokens.?);
    try std.testing.expectEqual(@as(u64, 128_000), compact_mock.calls.items[1].max_tokens.?);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "**Turn Context (split turn):**") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "<read-files>\nsrc/a.zig\n</read-files>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "<modified-files>\nsrc/b.zig\nsrc/c.zig\n</modified-files>") != null);
    try std.testing.expectEqualStrings("{\"readFiles\":[\"src/a.zig\"],\"modifiedFiles\":[\"src/b.zig\",\"src/c.zig\"]}", result.details_json);
}

test "agent branch summaries collect and prepare branch entries" {
    const session_storage = @import("session_storage.zig");
    const allocator = std.testing.allocator;
    var storage = try session_storage.InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{});
    defer storage.deinit();
    var session = session_mod.Session(session_storage.InMemorySessionStorage).init(allocator, std.testing.io, &storage);

    const root_json = try userMessageJsonAlloc(allocator, "root");
    defer allocator.free(root_json);
    const old_json = try assistantToolCallJsonAlloc(allocator, "read", "src/old.zig", mockUsage(100, 50, 0, 0));
    defer allocator.free(old_json);
    const target_json = try userMessageJsonAlloc(allocator, "target");
    defer allocator.free(target_json);

    const root_id = try session.appendMessageJson(root_json);
    const old_leaf = try session.appendMessageJson(old_json);
    try session.storage.setLeafId(root_id);
    const target_id = try session.appendMessageJson(target_json);

    var collected = try collectEntriesForBranchSummaryAlloc(allocator, &session, old_leaf, target_id);
    defer collected.deinit();
    try std.testing.expectEqualStrings(root_id, collected.common_ancestor_id.?);
    try std.testing.expectEqual(@as(usize, 1), collected.entries.len);

    var preparation = try prepareBranchEntriesAlloc(allocator, collected.entries, 0);
    defer preparation.deinit();
    try std.testing.expectEqual(@as(usize, 1), preparation.messages.len);
    const lists = try computeFileListsAlloc(allocator, preparation.file_ops);
    defer allocator.free(lists.read_files);
    defer allocator.free(lists.modified_files);
    try std.testing.expect(containsString(lists.read_files, "src/old.zig"));

    var mock = MockSummaryExecutor.init(allocator, &.{"## Goal\nReturn later"});
    defer mock.deinit();
    var result = try generateBranchSummaryAlloc(
        allocator,
        collected.entries,
        summaryTestModel(false, 8192),
        .{},
        mock.executor(),
        16_384,
    );
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(u8, result.summary, branch_summary_preamble) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.summary, "<read-files>\nsrc/old.zig\n</read-files>") != null);
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}
