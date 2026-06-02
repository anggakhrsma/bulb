const std = @import("std");

pub const Api = enum {
    anthropic_messages,
    openai_completions,
    mistral_conversations,
    openai_responses,
    azure_openai_responses,
    openai_codex_responses,
    google_generative_ai,
    google_vertex,
    bedrock_converse_stream,
    openrouter_images,
};

pub const Transport = enum {
    sse,
    websocket,
    auto,
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    error_response,
    aborted,
};

pub const Cost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
    total: f64 = 0,

    pub fn calculateTotal(self: *Cost) void {
        self.total = self.input + self.output + self.cache_read + self.cache_write;
    }
};

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    total_tokens: u64 = 0,
    cost: Cost = .{},

    pub fn calculateTotalTokens(self: *Usage) void {
        self.total_tokens = self.input + self.output + self.cache_read + self.cache_write;
    }

    pub fn calculateTotalCost(self: *Usage) void {
        self.cost.calculateTotal();
    }
};

pub const TextContent = struct {
    text: []const u8,
};

pub const ImageContent = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8 = "{}",
};

pub const UserContent = union(enum) {
    text: TextContent,
    image: ImageContent,
};

pub const AssistantContent = union(enum) {
    text: TextContent,
    thinking: ThinkingContent,
    tool_call: ToolCall,
};

pub const UserMessage = struct {
    content: []const UserContent,
    timestamp_ms: i64 = 0,
};

pub const AssistantMessage = struct {
    content: []const AssistantContent,
    api: Api,
    provider: []const u8,
    model: []const u8,
    usage: Usage = .{},
    stop_reason: StopReason = .stop,
    error_message: ?[]const u8 = null,
    timestamp_ms: i64 = 0,
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const UserContent,
    is_error: bool = false,
    timestamp_ms: i64 = 0,
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const StreamEvent = union(enum) {
    start: AssistantMessage,
    text_delta: struct {
        content_index: usize,
        delta: []const u8,
    },
    thinking_delta: struct {
        content_index: usize,
        delta: []const u8,
    },
    tool_call_delta: struct {
        content_index: usize,
        delta: []const u8,
    },
    done: AssistantMessage,
    error_response: AssistantMessage,
};

pub const ModelCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: []const u8,
    base_url: []const u8,
    input: []const []const u8,
    cost: ModelCost = .{},
    context_window: u64,
    max_tokens: u64,
    reasoning: bool = false,
};

// Ported invariant from packages/ai/test/total-tokens.test.ts.
test "usage calculates token and cost totals" {
    var usage: Usage = .{
        .input = 10,
        .output = 5,
        .cache_read = 2,
        .cache_write = 3,
        .cost = .{
            .input = 1.0,
            .output = 2.0,
            .cache_read = 0.5,
            .cache_write = 0.25,
        },
    };

    usage.calculateTotalTokens();
    usage.calculateTotalCost();

    try std.testing.expectEqual(@as(u64, 20), usage.total_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 3.75), usage.cost.total, 0.0001);
}
