const std = @import("std");
const api_registry = @import("api_registry.zig");
const simple_options = @import("providers/simple_options.zig");
const env_api_keys = @import("utils/env_api_keys.zig");
const types = @import("types.zig");

pub fn stream(
    registry: api_registry.Registry,
    env: ?*const std.process.Environ.Map,
    model: types.Model,
    context: types.Context,
    options: types.StreamOptions,
) !types.StreamResult {
    return registry.stream(model, context, withEnvApiKey(env, model, options));
}

pub fn streamSimple(
    registry: api_registry.Registry,
    env: ?*const std.process.Environ.Map,
    model: types.Model,
    context: types.Context,
    options: ?simple_options.SimpleStreamOptions,
) !types.StreamResult {
    return registry.streamSimple(model, context, withEnvApiKeySimple(env, model, options));
}

pub fn complete(
    registry: api_registry.Registry,
    env: ?*const std.process.Environ.Map,
    model: types.Model,
    context: types.Context,
    options: types.StreamOptions,
) !types.AssistantMessage {
    return registry.complete(model, context, withEnvApiKey(env, model, options));
}

pub fn withEnvApiKey(
    env: ?*const std.process.Environ.Map,
    model: types.Model,
    options: types.StreamOptions,
) types.StreamOptions {
    if (options.api_key) |api_key| {
        if (std.mem.trim(u8, api_key, " \t\r\n").len > 0) return options;
    }
    const environ = env orelse return options;
    const api_key = env_api_keys.getEnvApiKey(environ, model.provider) orelse return options;
    var resolved = options;
    resolved.api_key = api_key;
    return resolved;
}

pub fn withEnvApiKeySimple(
    env: ?*const std.process.Environ.Map,
    model: types.Model,
    options: ?simple_options.SimpleStreamOptions,
) simple_options.SimpleStreamOptions {
    var resolved = options orelse simple_options.SimpleStreamOptions{};
    resolved.base = withEnvApiKey(env, model, resolved.base);
    return resolved;
}

test "stream facade injects provider environment key unless explicitly configured" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("OPENAI_API_KEY", "environment-key");
    const model: types.Model = .{
        .id = "test",
        .name = "Test",
        .api = types.api.openai_responses,
        .provider = "openai",
        .base_url = "http://localhost",
    };

    const resolved = withEnvApiKey(&env, model, .{});
    try std.testing.expectEqualStrings("environment-key", resolved.api_key.?);

    const explicit = withEnvApiKey(&env, model, .{ .api_key = "explicit-key" });
    try std.testing.expectEqualStrings("explicit-key", explicit.api_key.?);

    const whitespace = withEnvApiKey(&env, model, .{ .api_key = "  " });
    try std.testing.expectEqualStrings("environment-key", whitespace.api_key.?);

    const simple = withEnvApiKeySimple(&env, model, null);
    try std.testing.expectEqualStrings("environment-key", simple.base.api_key.?);
}
