const std = @import("std");

pub const authenticated_marker = "<authenticated>";

const ProviderEnv = struct {
    provider: []const u8,
    variables: []const []const u8,
};

const provider_env = [_]ProviderEnv{
    .{ .provider = "github-copilot", .variables = &.{"COPILOT_GITHUB_TOKEN"} },
    .{ .provider = "anthropic", .variables = &.{ "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY" } },
    .{ .provider = "openai", .variables = &.{"OPENAI_API_KEY"} },
    .{ .provider = "azure-openai-responses", .variables = &.{"AZURE_OPENAI_API_KEY"} },
    .{ .provider = "deepseek", .variables = &.{"DEEPSEEK_API_KEY"} },
    .{ .provider = "google", .variables = &.{"GEMINI_API_KEY"} },
    .{ .provider = "google-vertex", .variables = &.{"GOOGLE_CLOUD_API_KEY"} },
    .{ .provider = "groq", .variables = &.{"GROQ_API_KEY"} },
    .{ .provider = "cerebras", .variables = &.{"CEREBRAS_API_KEY"} },
    .{ .provider = "xai", .variables = &.{"XAI_API_KEY"} },
    .{ .provider = "openrouter", .variables = &.{"OPENROUTER_API_KEY"} },
    .{ .provider = "vercel-ai-gateway", .variables = &.{"AI_GATEWAY_API_KEY"} },
    .{ .provider = "zai", .variables = &.{"ZAI_API_KEY"} },
    .{ .provider = "mistral", .variables = &.{"MISTRAL_API_KEY"} },
    .{ .provider = "minimax", .variables = &.{"MINIMAX_API_KEY"} },
    .{ .provider = "minimax-cn", .variables = &.{"MINIMAX_CN_API_KEY"} },
    .{ .provider = "moonshotai", .variables = &.{"MOONSHOT_API_KEY"} },
    .{ .provider = "moonshotai-cn", .variables = &.{"MOONSHOT_API_KEY"} },
    .{ .provider = "huggingface", .variables = &.{"HF_TOKEN"} },
    .{ .provider = "fireworks", .variables = &.{"FIREWORKS_API_KEY"} },
    .{ .provider = "together", .variables = &.{"TOGETHER_API_KEY"} },
    .{ .provider = "opencode", .variables = &.{"OPENCODE_API_KEY"} },
    .{ .provider = "opencode-go", .variables = &.{"OPENCODE_API_KEY"} },
    .{ .provider = "kimi-coding", .variables = &.{"KIMI_API_KEY"} },
    .{ .provider = "cloudflare-workers-ai", .variables = &.{"CLOUDFLARE_API_KEY"} },
    .{ .provider = "cloudflare-ai-gateway", .variables = &.{"CLOUDFLARE_API_KEY"} },
    .{ .provider = "xiaomi", .variables = &.{"XIAOMI_API_KEY"} },
    .{ .provider = "xiaomi-token-plan-cn", .variables = &.{"XIAOMI_TOKEN_PLAN_CN_API_KEY"} },
    .{ .provider = "xiaomi-token-plan-ams", .variables = &.{"XIAOMI_TOKEN_PLAN_AMS_API_KEY"} },
    .{ .provider = "xiaomi-token-plan-sgp", .variables = &.{"XIAOMI_TOKEN_PLAN_SGP_API_KEY"} },
};

pub fn findEnvKeys(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    provider: []const u8,
) !?[][]const u8 {
    const variables = getApiKeyEnvVars(provider) orelse return null;
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);

    for (variables) |variable| {
        if (getConfigured(env, variable) != null) try result.append(allocator, variable);
    }
    if (result.items.len == 0) return null;
    return try result.toOwnedSlice(allocator);
}

pub fn getEnvApiKey(env: *const std.process.Environ.Map, provider: []const u8) ?[]const u8 {
    if (getApiKeyEnvVars(provider)) |variables| {
        for (variables) |variable| {
            if (getConfigured(env, variable)) |value| return value;
        }
    }

    if (std.mem.eql(u8, provider, "amazon-bedrock") and hasBedrockCredentials(env)) {
        return authenticated_marker;
    }
    return null;
}

fn getApiKeyEnvVars(provider: []const u8) ?[]const []const u8 {
    for (provider_env) |entry| {
        if (std.mem.eql(u8, provider, entry.provider)) return entry.variables;
    }
    return null;
}

fn getConfigured(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len > 0) value else null;
}

fn hasBedrockCredentials(env: *const std.process.Environ.Map) bool {
    return getConfigured(env, "AWS_PROFILE") != null or
        (getConfigured(env, "AWS_ACCESS_KEY_ID") != null and getConfigured(env, "AWS_SECRET_ACCESS_KEY") != null) or
        getConfigured(env, "AWS_BEARER_TOKEN_BEDROCK") != null or
        getConfigured(env, "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") != null or
        getConfigured(env, "AWS_CONTAINER_CREDENTIALS_FULL_URI") != null or
        getConfigured(env, "AWS_WEB_IDENTITY_TOKEN_FILE") != null;
}

test "environment keys do not treat generic GitHub tokens as Copilot credentials" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("GH_TOKEN", "gh-token");
    try env.put("GITHUB_TOKEN", "github-token");

    try std.testing.expectEqual(null, try findEnvKeys(allocator, &env, "github-copilot"));
    try std.testing.expectEqual(null, getEnvApiKey(&env, "github-copilot"));
}

test "environment keys resolve Copilot credentials and Anthropic precedence" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("COPILOT_GITHUB_TOKEN", "copilot-token");
    try env.put("ANTHROPIC_API_KEY", "api-key");
    try env.put("ANTHROPIC_OAUTH_TOKEN", "oauth-token");

    const keys = (try findEnvKeys(allocator, &env, "github-copilot")).?;
    defer allocator.free(keys);
    try std.testing.expectEqualSlices([]const u8, &.{"COPILOT_GITHUB_TOKEN"}, keys);
    try std.testing.expectEqualStrings("copilot-token", getEnvApiKey(&env, "github-copilot").?);
    try std.testing.expectEqualStrings("oauth-token", getEnvApiKey(&env, "anthropic").?);
}

test "environment keys resolve package providers and ambient credentials" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("FIREWORKS_API_KEY", "fireworks-token");
    try env.put("TOGETHER_API_KEY", "together-token");
    try env.put("AWS_PROFILE", "bulb");

    try std.testing.expectEqualStrings("fireworks-token", getEnvApiKey(&env, "fireworks").?);
    try std.testing.expectEqualStrings("together-token", getEnvApiKey(&env, "together").?);
    try std.testing.expectEqualStrings(authenticated_marker, getEnvApiKey(&env, "amazon-bedrock").?);
}
