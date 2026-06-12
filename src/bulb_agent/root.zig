const std = @import("std");
const ai = @import("bulb_ai");

pub const uuid = @import("uuid.zig");
pub const truncate = @import("truncate.zig");
pub const types = @import("types.zig");
pub const prompt_templates = @import("prompt_templates.zig");
pub const skills = @import("skills.zig");
pub const system_prompt = @import("system_prompt.zig");
pub const messages = @import("messages.zig");
pub const shell_output = @import("shell_output.zig");
pub const node_env = @import("node_env.zig");
pub const session_storage = @import("session_storage.zig");
pub const session = @import("session.zig");
pub const session_repo = @import("session_repo.zig");
pub const compaction = @import("compaction.zig");

pub const PromptTemplate = types.PromptTemplate;
pub const Skill = types.Skill;
pub const AgentMessage = types.AgentMessage;
pub const InMemorySessionStorage = session_storage.InMemorySessionStorage;
pub const JsonlSessionStorage = session_storage.JsonlSessionStorage;
pub const InMemorySessionRepo = session_repo.InMemorySessionRepo;
pub const JsonlSessionRepo = session_repo.JsonlSessionRepo;
pub const CompactionSettings = compaction.CompactionSettings;

pub const AgentStatus = enum {
    idle,
    streaming,
};

pub const AgentEventTag = enum {
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    message_start,
    message_update,
    message_end,
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
};

pub const AgentError = error{
    AlreadyStreaming,
    NotStreaming,
};

pub const AgentState = struct {
    status: AgentStatus = .idle,
    thinking_level: ai.ThinkingLevel = .off,
    turn_count: usize = 0,

    pub fn beginTurn(self: *AgentState) AgentError!void {
        if (self.status == .streaming) return error.AlreadyStreaming;
        self.status = .streaming;
        self.turn_count += 1;
    }

    pub fn endTurn(self: *AgentState) AgentError!void {
        if (self.status != .streaming) return error.NotStreaming;
        self.status = .idle;
    }
};

// Ported subset of packages/agent/test/agent.test.ts streaming guard cases.
test "agent lifecycle guards streaming state" {
    var state: AgentState = .{};

    try state.beginTurn();
    try std.testing.expectEqual(AgentStatus.streaming, state.status);
    try std.testing.expectError(error.AlreadyStreaming, state.beginTurn());
    try state.endTurn();
    try std.testing.expectEqual(@as(usize, 1), state.turn_count);
    try std.testing.expectError(error.NotStreaming, state.endTurn());
}

test {
    _ = @import("frontmatter.zig");
    _ = @import("types.zig");
    _ = @import("prompt_templates.zig");
    _ = @import("skills.zig");
    _ = @import("system_prompt.zig");
    _ = @import("messages.zig");
    _ = @import("uuid.zig");
    _ = @import("truncate.zig");
    _ = @import("shell_output.zig");
    _ = @import("node_env.zig");
    _ = @import("session_storage.zig");
    _ = @import("session.zig");
    _ = @import("session_repo.zig");
    _ = @import("compaction.zig");
}
