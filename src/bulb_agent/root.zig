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
pub const LocalExecutionEnvOptions = node_env.LocalExecutionEnvOptions;
pub const LocalExecutionEnv = node_env.LocalExecutionEnv;
pub const NodeExecutionEnvOptions = node_env.NodeExecutionEnvOptions;
pub const NodeExecutionEnv = node_env.NodeExecutionEnv;
pub const session_storage = @import("session_storage.zig");
pub const session = @import("session.zig");
pub const session_repo = @import("session_repo.zig");
pub const compaction = @import("compaction.zig");
pub const harness = @import("harness.zig");
pub const agent_loop = @import("agent_loop.zig");
pub const agent = @import("agent.zig");
pub const proxy = @import("proxy.zig");

pub const PromptTemplate = types.PromptTemplate;
pub const Skill = types.Skill;
pub const AgentMessage = types.AgentMessage;
pub const InMemorySessionStorage = session_storage.InMemorySessionStorage;
pub const JsonlSessionStorage = session_storage.JsonlSessionStorage;
pub const InMemorySessionRepo = session_repo.InMemorySessionRepo;
pub const JsonlSessionRepo = session_repo.JsonlSessionRepo;
pub const CompactionSettings = compaction.CompactionSettings;
pub const AgentHarness = harness.AgentHarness;
pub const AgentHarnessOptions = harness.AgentHarnessOptions;
pub const AgentHarnessStreamOptions = harness.AgentHarnessStreamOptions;
pub const AgentHarnessStreamOptionsPatch = harness.AgentHarnessStreamOptionsPatch;
pub const AgentTool = harness.AgentTool;
pub const AgentLoopConfig = agent_loop.AgentLoopConfig;
pub const AgentLoopTool = agent_loop.AgentLoopTool;
pub const AgentLoopResult = agent_loop.AgentLoopResult;
pub const AgentEvent = agent_loop.AgentEvent;
pub const QueueMode = harness.QueueMode;
pub const Agent = agent.Agent;
pub const AgentOptions = agent.AgentOptions;
pub const AgentState = agent.AgentState;
pub const AgentInitialState = agent.AgentInitialState;
pub const AgentListener = agent.AgentListener;
pub const PendingMessageQueue = agent.PendingMessageQueue;
pub const ProxyStreamOptions = proxy.ProxyStreamOptions;
pub const ProxyTransport = proxy.ProxyTransport;
pub const streamProxy = proxy.streamProxy;

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

pub const AgentError = agent.AgentError;

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
    _ = @import("harness.zig");
    _ = @import("agent_loop.zig");
    _ = @import("agent.zig");
    _ = @import("proxy.zig");
}
