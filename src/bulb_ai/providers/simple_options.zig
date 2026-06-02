const std = @import("std");
const types = @import("../types.zig");

pub const SimpleStreamOptions = struct {
    base: types.StreamOptions = .{},
    reasoning: ?types.ThinkingLevel = null,
    thinking_budgets: types.ThinkingBudgets = .{},
};

pub const AdjustedThinking = struct {
    max_tokens: u64,
    thinking_budget: u64,
};

pub fn buildBaseOptions(
    _model: types.Model,
    options: ?SimpleStreamOptions,
    api_key: ?[]const u8,
) types.StreamOptions {
    _ = _model;
    const base = if (options) |value| value.base else types.StreamOptions{};
    var result = base;
    if (api_key) |key| {
        result.api_key = key;
    }
    return result;
}

pub fn clampReasoning(effort: ?types.ThinkingLevel) ?types.ThinkingLevel {
    const value = effort orelse return null;
    return if (value == .xhigh) .high else value;
}

pub fn adjustMaxTokensForThinking(
    base_max_tokens: ?u64,
    model_max_tokens: u64,
    reasoning_level: types.ThinkingLevel,
    custom_budgets: ?types.ThinkingBudgets,
) !AdjustedThinking {
    const level = clampReasoning(reasoning_level) orelse return error.MissingReasoningLevel;
    const budget = budgetFor(level, custom_budgets orelse .{}) orelse return error.UnsupportedReasoningLevel;
    const max_tokens = if (base_max_tokens) |base|
        @min(base +| budget, model_max_tokens)
    else
        model_max_tokens;

    const min_output_tokens: u64 = 1024;
    const thinking_budget = if (max_tokens <= budget)
        if (max_tokens > min_output_tokens) max_tokens - min_output_tokens else 0
    else
        budget;

    return .{
        .max_tokens = max_tokens,
        .thinking_budget = thinking_budget,
    };
}

fn budgetFor(level: types.ThinkingLevel, custom_budgets: types.ThinkingBudgets) ?u64 {
    if (custom_budgets.budgetFor(level)) |custom| return custom;
    return switch (level) {
        .minimal => 1024,
        .low => 2048,
        .medium => 8192,
        .high => 16_384,
        else => null,
    };
}

// Ported from packages/ai/src/providers/simple-options.ts.
test "simple options build base options with explicit api key override" {
    const model: types.Model = .{
        .id = "faux",
        .name = "Faux",
        .api = "faux",
        .provider = "faux",
        .base_url = "http://localhost",
    };
    const headers = [_]types.Header{.{ .name = "x-test", .value = "one" }};
    const options: SimpleStreamOptions = .{ .base = .{
        .temperature = 0.2,
        .max_tokens = 100,
        .api_key = "original",
        .transport = .sse,
        .cache_retention = .long,
        .session_id = "session",
        .headers = &headers,
        .timeout_ms = 1000,
        .websocket_connect_timeout_ms = 2000,
        .max_retries = 3,
        .max_retry_delay_ms = 4000,
        .metadata_json = "{\"user_id\":\"u1\"}",
    } };

    const base = buildBaseOptions(model, options, "override");
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), base.temperature.?, 0.0001);
    try std.testing.expectEqual(@as(u64, 100), base.max_tokens.?);
    try std.testing.expectEqualStrings("override", base.api_key.?);
    try std.testing.expectEqual(types.Transport.sse, base.transport.?);
    try std.testing.expectEqual(types.CacheRetention.long, base.cache_retention);
    try std.testing.expectEqualStrings("session", base.session_id.?);
    try std.testing.expectEqual(@as(usize, 1), base.headers.len);
    try std.testing.expectEqual(@as(u64, 1000), base.timeout_ms.?);
    try std.testing.expectEqual(@as(u64, 2000), base.websocket_connect_timeout_ms.?);
    try std.testing.expectEqual(@as(u32, 3), base.max_retries.?);
    try std.testing.expectEqual(@as(u64, 4000), base.max_retry_delay_ms.?);
    try std.testing.expectEqualStrings("{\"user_id\":\"u1\"}", base.metadata_json.?);
}

// Ported from packages/ai/src/providers/simple-options.ts.
test "simple options clamp xhigh reasoning to high" {
    try std.testing.expectEqual(types.ThinkingLevel.high, clampReasoning(.xhigh).?);
    try std.testing.expectEqual(types.ThinkingLevel.medium, clampReasoning(.medium).?);
    try std.testing.expectEqual(@as(?types.ThinkingLevel, null), clampReasoning(null));
}

// Ported from packages/ai/src/providers/simple-options.ts.
test "simple options adjust max tokens to keep thinking inside output cap" {
    const defaulted = try adjustMaxTokensForThinking(null, 20_000, .high, null);
    try std.testing.expectEqual(@as(u64, 20_000), defaulted.max_tokens);
    try std.testing.expectEqual(@as(u64, 16_384), defaulted.thinking_budget);

    const capped = try adjustMaxTokensForThinking(4096, 10_000, .high, null);
    try std.testing.expectEqual(@as(u64, 10_000), capped.max_tokens);
    try std.testing.expectEqual(@as(u64, 8976), capped.thinking_budget);

    const custom = try adjustMaxTokensForThinking(1000, 10_000, .medium, .{ .medium = 3000 });
    try std.testing.expectEqual(@as(u64, 4000), custom.max_tokens);
    try std.testing.expectEqual(@as(u64, 3000), custom.thinking_budget);
}
