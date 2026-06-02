const std = @import("std");
const cache_retention = @import("cache_retention.zig");
const types = @import("../types.zig");

pub const OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH = 64;

pub fn clampOpenAIPromptCacheKey(allocator: std.mem.Allocator, key: ?[]const u8) !?[]u8 {
    const value = key orelse return null;
    const end = firstUtf8CodepointPrefix(value, OPENAI_PROMPT_CACHE_KEY_MAX_LENGTH);
    return @as(?[]u8, try allocator.dupe(u8, value[0..end]));
}

pub fn responsesPromptCacheKey(
    allocator: std.mem.Allocator,
    session_id: ?[]const u8,
    retention: types.CacheRetention,
) !?[]u8 {
    if (retention == .none) return null;
    return clampOpenAIPromptCacheKey(allocator, session_id);
}

pub fn promptCacheRetention(model: types.Model, retention: types.CacheRetention) ?[]const u8 {
    const supports_long = model.compat.supports_long_cache_retention orelse true;
    if (retention == .long and supports_long) return "24h";
    return null;
}

pub fn completionsPromptCacheKey(
    allocator: std.mem.Allocator,
    model: types.Model,
    session_id: ?[]const u8,
    retention: types.CacheRetention,
) !?[]u8 {
    const supports_long = model.compat.supports_long_cache_retention orelse true;
    const should_send = (std.mem.indexOf(u8, model.base_url, "api.openai.com") != null and retention != .none) or
        (retention == .long and supports_long);
    if (!should_send) return null;
    return clampOpenAIPromptCacheKey(allocator, session_id);
}

fn firstUtf8CodepointPrefix(value: []const u8, max_codepoints: usize) usize {
    var index: usize = 0;
    var count: usize = 0;
    while (index < value.len and count < max_codepoints) : (count += 1) {
        const width = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        if (index + width > value.len) return index;
        index += width;
    }
    return index;
}

test "OpenAI prompt cache key clamps by Unicode code point count" {
    const allocator = std.testing.allocator;
    const long = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!🙂🙂";
    const clamped = (try clampOpenAIPromptCacheKey(allocator, long)).?;
    defer allocator.free(clamped);

    try std.testing.expectEqual(@as(usize, 65), try std.unicode.utf8CountCodepoints(long));
    try std.testing.expectEqual(@as(usize, 64), try std.unicode.utf8CountCodepoints(clamped));
    try std.testing.expect(std.mem.endsWith(u8, clamped, "🙂"));
}

// Ported from packages/ai/test/cache-retention.test.ts (OpenAI Responses branch).
test "OpenAI Responses prompt cache honors none and long retention" {
    const allocator = std.testing.allocator;
    const model: types.Model = .{
        .id = "gpt-4o-mini",
        .name = "GPT-4o mini",
        .api = types.api.openai_responses,
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
    };

    try std.testing.expectEqual(@as(?[]u8, null), try responsesPromptCacheKey(allocator, "session-1", .none));
    try std.testing.expectEqual(@as(?[]const u8, null), promptCacheRetention(model, .short));
    try std.testing.expectEqualStrings("24h", promptCacheRetention(model, .long).?);

    const key = (try responsesPromptCacheKey(allocator, "session-2", .long)).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("session-2", key);
}

// Ported from packages/ai/test/cache-retention.test.ts (OpenAI Completions branch).
test "OpenAI Completions cache key honors proxy compatibility" {
    const allocator = std.testing.allocator;
    var model: types.Model = .{
        .id = "test-model",
        .name = "Test Model",
        .api = types.api.openai_completions,
        .provider = "test-openai-completions",
        .base_url = "https://my-proxy.example.com/v1",
    };

    const key = (try completionsPromptCacheKey(allocator, model, "session-completions", .long)).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("session-completions", key);
    try std.testing.expectEqualStrings("24h", promptCacheRetention(model, .long).?);

    model.compat.supports_long_cache_retention = false;
    try std.testing.expectEqual(@as(?[]u8, null), try completionsPromptCacheKey(allocator, model, "session-nope", .long));
    try std.testing.expectEqual(@as(?[]const u8, null), promptCacheRetention(model, .long));
}

test "OpenAI prompt cache uses BULB cache retention resolver" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("BULB_CACHE_RETENTION", "long");
    try std.testing.expectEqual(types.CacheRetention.long, cache_retention.resolveCacheRetention(&env, null));
}
