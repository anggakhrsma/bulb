const std = @import("std");

pub const api = struct {
    pub const anthropic_messages = "anthropic-messages";
    pub const openai_completions = "openai-completions";
    pub const mistral_conversations = "mistral-conversations";
    pub const openai_responses = "openai-responses";
    pub const azure_openai_responses = "azure-openai-responses";
    pub const openai_codex_responses = "openai-codex-responses";
    pub const google_generative_ai = "google-generative-ai";
    pub const google_vertex = "google-vertex";
    pub const bedrock_converse_stream = "bedrock-converse-stream";
    pub const openrouter_images = "openrouter-images";
};

pub const known_api_count = 10;
pub const Api = []const u8;

pub const Transport = enum {
    sse,
    websocket,
    websocket_cached,
    auto,
};

pub const CacheRetention = enum {
    none,
    short,
    long,
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
    @"error",
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

pub const DiagnosticCode = union(enum) {
    string: []const u8,
    number: i64,
};

pub const DiagnosticErrorInfo = struct {
    name: ?[]const u8 = null,
    message: []const u8,
    stack: ?[]const u8 = null,
    code: ?DiagnosticCode = null,
};

pub const AssistantMessageDiagnostic = struct {
    type: []const u8,
    timestamp_ms: i64,
    @"error": ?DiagnosticErrorInfo = null,
    details_json: ?[]const u8 = null,
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
    response_id: ?[]const u8 = null,
    diagnostics: []const AssistantMessageDiagnostic = &.{},
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

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: []const Tool = &.{},
};

pub const AbortSignal = struct {
    aborted: bool = false,
    reason: ?[]const u8 = null,

    pub fn abort(self: *AbortSignal) void {
        self.aborted = true;
    }

    pub fn abortWithReason(self: *AbortSignal, reason: []const u8) void {
        self.aborted = true;
        self.reason = reason;
    }

    pub fn isAborted(self: *const AbortSignal) bool {
        return self.aborted;
    }
};

pub const ContentIndex = struct {
    content_index: usize,
};

pub const ContentDelta = struct {
    content_index: usize,
    delta: []const u8,
};

pub const ContentEnd = struct {
    content_index: usize,
    content: []const u8,
};

pub const ToolCallEnd = struct {
    content_index: usize,
    tool_call: ToolCall,
};

pub const TerminalError = struct {
    reason: StopReason,
    message: AssistantMessage,
};

pub const StreamEvent = union(enum) {
    start: void,
    text_start: ContentIndex,
    text_delta: ContentDelta,
    text_end: ContentEnd,
    thinking_start: ContentIndex,
    thinking_delta: ContentDelta,
    thinking_end: ContentEnd,
    toolcall_start: ContentIndex,
    toolcall_delta: ContentDelta,
    toolcall_end: ToolCallEnd,
    done: StopReason,
    @"error": TerminalError,
};

pub const EventObserver = *const fn (signal: *AbortSignal, event: StreamEvent) void;

pub const StreamOptions = struct {
    api_key: ?[]const u8 = null,
    cache_retention: CacheRetention = .short,
    session_id: ?[]const u8 = null,
    signal: ?*AbortSignal = null,
    on_event: ?EventObserver = null,
};

pub const StreamResult = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(StreamEvent) = .empty,
    message: AssistantMessage,

    pub fn deinit(self: *StreamResult) void {
        self.events.deinit(self.allocator);
    }
};

pub const ModelCost = struct {
    input: f64 = 0,
    output: f64 = 0,
    cache_read: f64 = 0,
    cache_write: f64 = 0,
};

pub const ThinkingLevelOverride = union(enum) {
    unset,
    unsupported,
    mapped: []const u8,
};

pub const ThinkingLevelMap = struct {
    off: ThinkingLevelOverride = .unset,
    minimal: ThinkingLevelOverride = .unset,
    low: ThinkingLevelOverride = .unset,
    medium: ThinkingLevelOverride = .unset,
    high: ThinkingLevelOverride = .unset,
    xhigh: ThinkingLevelOverride = .unset,

    pub fn get(self: ThinkingLevelMap, level: ThinkingLevel) ThinkingLevelOverride {
        return switch (level) {
            .off => self.off,
            .minimal => self.minimal,
            .low => self.low,
            .medium => self.medium,
            .high => self.high,
            .xhigh => self.xhigh,
        };
    }
};

pub const MaxTokensField = enum {
    max_completion_tokens,
    max_tokens,
};

pub const ThinkingFormat = enum {
    openai,
    openrouter,
    deepseek,
    together,
    zai,
    qwen,
    qwen_chat_template,
    string_thinking,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ModelCompat = struct {
    supports_store: ?bool = null,
    supports_developer_role: ?bool = null,
    supports_reasoning_effort: ?bool = null,
    supports_usage_in_streaming: ?bool = null,
    max_tokens_field: ?MaxTokensField = null,
    requires_tool_result_name: ?bool = null,
    requires_assistant_after_tool_result: ?bool = null,
    requires_thinking_as_text: ?bool = null,
    requires_reasoning_content_on_assistant_messages: ?bool = null,
    thinking_format: ?ThinkingFormat = null,
    zai_tool_stream: ?bool = null,
    supports_strict_mode: ?bool = null,
    send_session_affinity_headers: ?bool = null,
    send_session_id_header: ?bool = null,
    supports_long_cache_retention: ?bool = null,
    supports_eager_tool_input_streaming: ?bool = null,
    supports_cache_control_on_tools: ?bool = null,
    supports_temperature: ?bool = null,
    force_adaptive_thinking: ?bool = null,
    allow_empty_signature: ?bool = null,
};

pub const default_model_input = [_][]const u8{ "text", "image" };
pub const default_image_output = [_][]const u8{"image"};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: []const u8,
    base_url: []const u8,
    reasoning: bool = false,
    thinking_level_map: ThinkingLevelMap = .{},
    input: []const []const u8 = &default_model_input,
    cost: ModelCost = .{},
    context_window: u64 = 128_000,
    max_tokens: u64 = 16_384,
    headers: []const Header = &.{},
    compat: ModelCompat = .{},
};

pub const ImageModel = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: []const u8,
    base_url: []const u8,
    input: []const []const u8 = &default_model_input,
    output: []const []const u8 = &default_image_output,
    cost: ModelCost = .{},
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
