const std = @import("std");
const types = @import("../types.zig");

pub const CacheControl = struct {
    type: []const u8 = "ephemeral",
    ttl: ?[]const u8 = null,
};

pub const AnthropicCacheControlResult = struct {
    retention: types.CacheRetention,
    cache_control: ?CacheControl = null,
};

pub fn resolveCacheRetention(
    env: ?*const std.process.Environ.Map,
    override: ?types.CacheRetention,
) types.CacheRetention {
    if (override) |retention| return retention;
    if (env) |map| {
        if (map.get("BULB_CACHE_RETENTION")) |value| {
            if (std.mem.eql(u8, value, "long")) return .long;
        }
    }
    return .short;
}

pub fn getAnthropicCacheControl(
    model: types.Model,
    retention_override: ?types.CacheRetention,
    env: ?*const std.process.Environ.Map,
) AnthropicCacheControlResult {
    const retention = resolveCacheRetention(env, retention_override);
    if (retention == .none) return .{ .retention = retention };
    const supports_long = model.compat.supports_long_cache_retention orelse !std.mem.eql(u8, model.provider, "fireworks");
    return .{
        .retention = retention,
        .cache_control = .{
            .ttl = if (retention == .long and supports_long) "1h" else null,
        },
    };
}

pub fn getOpenAIPromptCacheRetention(model: types.Model, retention: types.CacheRetention) ?[]const u8 {
    const supports_long = model.compat.supports_long_cache_retention orelse true;
    if (retention == .long and supports_long) return "24h";
    return null;
}

// Ported from packages/ai/test/cache-retention.test.ts, translated from
// PI_CACHE_RETENTION to Bulb's product-specific BULB_CACHE_RETENTION.
test "cache retention resolves explicit options before BULB environment" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("BULB_CACHE_RETENTION", "long");

    try std.testing.expectEqual(types.CacheRetention.long, resolveCacheRetention(&env, null));
    try std.testing.expectEqual(types.CacheRetention.none, resolveCacheRetention(&env, .none));
    try std.testing.expectEqual(types.CacheRetention.short, resolveCacheRetention(null, null));
}

// Ported from packages/ai/test/cache-retention.test.ts (Anthropic branch).
test "Anthropic cache control applies ttl only for long-compatible models" {
    var model: types.Model = .{
        .id = "claude-haiku-4-5",
        .name = "Claude Haiku 4.5",
        .api = types.api.anthropic_messages,
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
    };

    const short = getAnthropicCacheControl(model, null, null);
    try std.testing.expectEqual(types.CacheRetention.short, short.retention);
    try std.testing.expectEqualStrings("ephemeral", short.cache_control.?.type);
    try std.testing.expectEqual(@as(?[]const u8, null), short.cache_control.?.ttl);

    const long = getAnthropicCacheControl(model, .long, null);
    try std.testing.expectEqualStrings("1h", long.cache_control.?.ttl.?);

    model.compat.supports_long_cache_retention = false;
    const unsupported = getAnthropicCacheControl(model, .long, null);
    try std.testing.expectEqual(@as(?[]const u8, null), unsupported.cache_control.?.ttl);

    const none = getAnthropicCacheControl(model, .none, null);
    try std.testing.expectEqual(@as(?CacheControl, null), none.cache_control);
}
