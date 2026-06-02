const std = @import("std");
const generated = @import("models_generated.zig");
const types = @import("types.zig");

const all_thinking_levels = [_]types.ThinkingLevel{ .off, .minimal, .low, .medium, .high, .xhigh };

pub const ThinkingLevels = struct {
    values: [all_thinking_levels.len]types.ThinkingLevel = undefined,
    len: usize = 0,

    pub fn append(self: *ThinkingLevels, level: types.ThinkingLevel) void {
        self.values[self.len] = level;
        self.len += 1;
    }

    pub fn asSlice(self: *const ThinkingLevels) []const types.ThinkingLevel {
        return self.values[0..self.len];
    }

    pub fn contains(self: *const ThinkingLevels, level: types.ThinkingLevel) bool {
        for (self.asSlice()) |candidate| {
            if (candidate == level) return true;
        }
        return false;
    }
};

pub const ModelIterator = struct {
    provider: []const u8,
    index: usize = 0,

    pub fn next(self: *ModelIterator) ?*const types.Model {
        while (self.index < generated.models.len) {
            const model = &generated.models[self.index];
            self.index += 1;
            if (std.mem.eql(u8, model.provider, self.provider)) return model;
        }
        return null;
    }

    pub fn count(self: ModelIterator) usize {
        var iterator = self;
        var result: usize = 0;
        while (iterator.next() != null) result += 1;
        return result;
    }
};

pub fn allModels() []const types.Model {
    return generated.models[0..];
}

pub fn getProviders() []const []const u8 {
    return generated.providers[0..];
}

pub fn getModels(provider: []const u8) ModelIterator {
    return .{ .provider = provider };
}

pub fn getModel(provider: []const u8, model_id: []const u8) ?*const types.Model {
    for (&generated.models) |*model| {
        if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) {
            return model;
        }
    }
    return null;
}

pub fn calculateCost(model: types.Model, usage: *types.Usage) types.Cost {
    usage.cost.input = perMillion(model.cost.input, usage.input);
    usage.cost.output = perMillion(model.cost.output, usage.output);
    usage.cost.cache_read = perMillion(model.cost.cache_read, usage.cache_read);
    usage.cost.cache_write = perMillion(model.cost.cache_write, usage.cache_write);
    usage.calculateTotalCost();
    return usage.cost;
}

pub fn getSupportedThinkingLevels(model: types.Model) ThinkingLevels {
    var result: ThinkingLevels = .{};
    if (!model.reasoning) {
        result.append(.off);
        return result;
    }

    for (all_thinking_levels) |level| {
        const mapped = model.thinking_level_map.get(level);
        switch (mapped) {
            .unsupported => continue,
            .unset => {
                if (level == .xhigh) continue;
            },
            .mapped => {},
        }
        result.append(level);
    }
    return result;
}

pub fn clampThinkingLevel(model: types.Model, level: types.ThinkingLevel) types.ThinkingLevel {
    const available = getSupportedThinkingLevels(model);
    if (available.contains(level)) return level;

    const requested_index = thinkingLevelIndex(level);
    var forward = requested_index + 1;
    while (forward < all_thinking_levels.len) : (forward += 1) {
        const candidate = all_thinking_levels[forward];
        if (available.contains(candidate)) return candidate;
    }

    var backward = requested_index;
    while (backward > 0) {
        backward -= 1;
        const candidate = all_thinking_levels[backward];
        if (available.contains(candidate)) return candidate;
    }

    return available.asSlice()[0];
}

pub fn modelsAreEqual(a: ?*const types.Model, b: ?*const types.Model) bool {
    const left = a orelse return false;
    const right = b orelse return false;
    return std.mem.eql(u8, left.id, right.id) and std.mem.eql(u8, left.provider, right.provider);
}

fn perMillion(cost: f64, tokens: u64) f64 {
    return (cost / 1_000_000.0) * @as(f64, @floatFromInt(tokens));
}

fn thinkingLevelIndex(level: types.ThinkingLevel) usize {
    for (all_thinking_levels, 0..) |candidate, index| {
        if (candidate == level) return index;
    }
    unreachable;
}

fn expectLevelSet(provider: []const u8, model_id: []const u8, expected: []const types.ThinkingLevel) !void {
    const model = getModel(provider, model_id) orelse return error.ModelMissing;
    const levels = getSupportedThinkingLevels(model.*);
    try std.testing.expectEqualSlices(types.ThinkingLevel, expected, levels.asSlice());
}

fn expectUnsupported(value: types.ThinkingLevelOverride) !void {
    switch (value) {
        .unsupported => {},
        else => return error.ExpectedUnsupportedThinkingLevel,
    }
}

fn expectMapped(value: types.ThinkingLevelOverride, expected: []const u8) !void {
    switch (value) {
        .mapped => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedMappedThinkingLevel,
    }
}

// Ported from packages/ai/src/models.ts and packages/ai/test/total-tokens.test.ts.
test "model registry calculates cost from model metadata" {
    const model = getModel("fireworks", "accounts/fireworks/models/kimi-k2p6") orelse return error.ModelMissing;
    var usage: types.Usage = .{
        .input = 1_000_000,
        .output = 500_000,
        .cache_read = 250_000,
        .cache_write = 125_000,
    };

    const cost = calculateCost(model.*, &usage);

    try std.testing.expectApproxEqAbs(@as(f64, 0.95), cost.input, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), cost.output, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.04), cost.cache_read, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), cost.cache_write, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.99), cost.total, 0.000001);
}

// Ported from packages/ai/test/supports-xhigh.test.ts.
test "model registry preserves supported thinking levels" {
    try std.testing.expect(getSupportedThinkingLevels(getModel("anthropic", "claude-opus-4-6").?.*).contains(.xhigh));
    try std.testing.expect(getSupportedThinkingLevels(getModel("anthropic", "claude-opus-4-8").?.*).contains(.xhigh));
    try std.testing.expect(!getSupportedThinkingLevels(getModel("anthropic", "claude-sonnet-4-5").?.*).contains(.xhigh));
    try std.testing.expect(getSupportedThinkingLevels(getModel("openai-codex", "gpt-5.4").?.*).contains(.xhigh));
    try std.testing.expect(getSupportedThinkingLevels(getModel("openai-codex", "gpt-5.5").?.*).contains(.xhigh));

    try expectLevelSet("openai", "gpt-5.5-pro", &.{ .medium, .high, .xhigh });
    try expectLevelSet("openrouter", "openai/gpt-5.5-pro", &.{ .medium, .high, .xhigh });
    try expectLevelSet("deepseek", "deepseek-v4-flash", &.{ .off, .high, .xhigh });
    try expectLevelSet("opencode-go", "deepseek-v4-flash", &.{ .off, .high, .xhigh });
    try expectLevelSet("opencode-go", "kimi-k2.6", &.{ .off, .high });
    try expectLevelSet("opencode", "grok-build-0.1", &.{.high});
    try expectLevelSet("openrouter", "deepseek/deepseek-v4-flash", &.{ .off, .high, .xhigh });
    try std.testing.expect(getSupportedThinkingLevels(getModel("openrouter", "anthropic/claude-opus-4.6").?.*).contains(.xhigh));
}

// Ported from packages/ai/test/together-models.test.ts.
test "Together model metadata matches Pi snapshot" {
    const kimi = getModel("together", "moonshotai/Kimi-K2.6") orelse return error.ModelMissing;
    try std.testing.expectEqualStrings("openai-completions", kimi.api);
    try std.testing.expectEqualStrings("together", kimi.provider);
    try std.testing.expectEqualStrings("https://api.together.ai/v1", kimi.base_url);
    try std.testing.expect(kimi.reasoning);
    try expectUnsupported(kimi.thinking_level_map.minimal);
    try expectUnsupported(kimi.thinking_level_map.low);
    try expectUnsupported(kimi.thinking_level_map.medium);
    try std.testing.expectEqualSlices([]const u8, &.{ "text", "image" }, kimi.input);
    try std.testing.expectEqual(@as(u64, 262144), kimi.context_window);
    try std.testing.expectEqual(@as(u64, 131000), kimi.max_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), kimi.cost.input, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), kimi.cost.output, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), kimi.cost.cache_read, 0.000001);
    try std.testing.expectEqual(@as(?bool, false), kimi.compat.supports_store);
    try std.testing.expectEqual(@as(?bool, false), kimi.compat.supports_developer_role);
    try std.testing.expectEqual(@as(?bool, false), kimi.compat.supports_reasoning_effort);
    try std.testing.expectEqual(@as(?types.MaxTokensField, .max_tokens), kimi.compat.max_tokens_field);
    try std.testing.expectEqual(@as(?types.ThinkingFormat, .together), kimi.compat.thinking_format);
    try std.testing.expectEqual(@as(?bool, false), kimi.compat.supports_strict_mode);
    try std.testing.expectEqual(@as(?bool, false), kimi.compat.supports_long_cache_retention);

    const gpt_oss = getModel("together", "openai/gpt-oss-120b") orelse return error.ModelMissing;
    try expectUnsupported(gpt_oss.thinking_level_map.off);
    try expectUnsupported(gpt_oss.thinking_level_map.minimal);
    try std.testing.expectEqual(@as(?bool, true), gpt_oss.compat.supports_reasoning_effort);
    try std.testing.expectEqual(@as(?types.ThinkingFormat, .openai), gpt_oss.compat.thinking_format);

    const deepseek = getModel("together", "deepseek-ai/DeepSeek-V4-Pro") orelse return error.ModelMissing;
    try expectUnsupported(deepseek.thinking_level_map.minimal);
    try expectUnsupported(deepseek.thinking_level_map.low);
    try expectUnsupported(deepseek.thinking_level_map.medium);
    try expectMapped(deepseek.thinking_level_map.high, "high");
    try expectUnsupported(deepseek.thinking_level_map.xhigh);
    try std.testing.expectEqual(@as(?bool, true), deepseek.compat.supports_reasoning_effort);
    try std.testing.expectEqual(@as(?types.ThinkingFormat, .together), deepseek.compat.thinking_format);

    const minimax = getModel("together", "MiniMaxAI/MiniMax-M2.7") orelse return error.ModelMissing;
    try expectUnsupported(minimax.thinking_level_map.off);
    try expectUnsupported(minimax.thinking_level_map.minimal);
    try expectUnsupported(minimax.thinking_level_map.low);
    try expectUnsupported(minimax.thinking_level_map.medium);
    try std.testing.expectEqual(@as(?types.ThinkingFormat, null), minimax.compat.thinking_format);
    try std.testing.expectEqual(@as(?bool, false), minimax.compat.supports_reasoning_effort);
}

// Ported from packages/ai/test/fireworks-models.test.ts.
test "Fireworks model metadata matches Pi snapshot" {
    const model = getModel("fireworks", "accounts/fireworks/models/kimi-k2p6") orelse return error.ModelMissing;

    try std.testing.expectEqualStrings("anthropic-messages", model.api);
    try std.testing.expectEqualStrings("fireworks", model.provider);
    try std.testing.expectEqualStrings("https://api.fireworks.ai/inference", model.base_url);
    try std.testing.expect(model.reasoning);
    try std.testing.expectEqualSlices([]const u8, &.{ "text", "image" }, model.input);
    try std.testing.expectEqual(@as(u64, 262000), model.context_window);
    try std.testing.expectEqual(@as(u64, 262000), model.max_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), model.cost.input, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 4), model.cost.output, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.16), model.cost.cache_read, 0.000001);
    try std.testing.expectEqual(@as(?bool, true), model.compat.send_session_affinity_headers);
    try std.testing.expectEqual(@as(?bool, false), model.compat.supports_eager_tool_input_streaming);
    try std.testing.expectEqual(@as(?bool, false), model.compat.supports_cache_control_on_tools);
    try std.testing.expectEqual(@as(?bool, false), model.compat.supports_long_cache_retention);

    var fireworks = getModels("fireworks");
    var found_turbo_router = false;
    while (fireworks.next()) |candidate| {
        if (std.mem.startsWith(u8, candidate.id, "accounts/fireworks/routers/") and
            std.mem.endsWith(u8, candidate.id, "-turbo"))
        {
            found_turbo_router = true;
            try std.testing.expectEqualStrings("anthropic-messages", candidate.api);
            try std.testing.expectEqualStrings("https://api.fireworks.ai/inference", candidate.base_url);
            try std.testing.expectEqualSlices([]const u8, &.{ "text", "image" }, candidate.input);
        }
    }
    try std.testing.expect(found_turbo_router);
}

// Ported from packages/ai/test/xiaomi-models.test.ts.
test "Xiaomi token-plan providers omit API-billed MiMo flash model" {
    try std.testing.expect(getModel("xiaomi", "mimo-v2-flash") != null);

    const token_plan_providers = [_][]const u8{
        "xiaomi-token-plan-cn",
        "xiaomi-token-plan-ams",
        "xiaomi-token-plan-sgp",
    };
    for (token_plan_providers) |provider| {
        var iterator = getModels(provider);
        while (iterator.next()) |model| {
            try std.testing.expect(!std.mem.eql(u8, model.id, "mimo-v2-flash"));
        }
    }
}

test "model equality compares provider and id" {
    const left = getModel("anthropic", "claude-opus-4-8");
    const same = getModel("anthropic", "claude-opus-4-8");
    const different_provider = getModel("openrouter", "anthropic/claude-opus-4.8");

    try std.testing.expect(modelsAreEqual(left, same));
    try std.testing.expect(!modelsAreEqual(left, different_provider));
    try std.testing.expect(!modelsAreEqual(left, null));
}
