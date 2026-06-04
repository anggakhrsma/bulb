const std = @import("std");

pub const BuiltInProviderDisplayName = struct {
    id: []const u8,
    name: []const u8,
};

pub const built_in_provider_display_names = [_]BuiltInProviderDisplayName{
    .{ .id = "anthropic", .name = "Anthropic" },
    .{ .id = "amazon-bedrock", .name = "Amazon Bedrock" },
    .{ .id = "azure-openai-responses", .name = "Azure OpenAI Responses" },
    .{ .id = "cerebras", .name = "Cerebras" },
    .{ .id = "cloudflare-ai-gateway", .name = "Cloudflare AI Gateway" },
    .{ .id = "cloudflare-workers-ai", .name = "Cloudflare Workers AI" },
    .{ .id = "deepseek", .name = "DeepSeek" },
    .{ .id = "fireworks", .name = "Fireworks" },
    .{ .id = "google", .name = "Google Gemini" },
    .{ .id = "google-vertex", .name = "Google Vertex AI" },
    .{ .id = "groq", .name = "Groq" },
    .{ .id = "huggingface", .name = "Hugging Face" },
    .{ .id = "kimi-coding", .name = "Kimi For Coding" },
    .{ .id = "mistral", .name = "Mistral" },
    .{ .id = "minimax", .name = "MiniMax" },
    .{ .id = "minimax-cn", .name = "MiniMax (China)" },
    .{ .id = "moonshotai", .name = "Moonshot AI" },
    .{ .id = "moonshotai-cn", .name = "Moonshot AI (China)" },
    .{ .id = "opencode", .name = "OpenCode Zen" },
    .{ .id = "opencode-go", .name = "OpenCode Go" },
    .{ .id = "openai", .name = "OpenAI" },
    .{ .id = "openrouter", .name = "OpenRouter" },
    .{ .id = "together", .name = "Together AI" },
    .{ .id = "vercel-ai-gateway", .name = "Vercel AI Gateway" },
    .{ .id = "xai", .name = "xAI" },
    .{ .id = "zai", .name = "ZAI" },
    .{ .id = "xiaomi", .name = "Xiaomi MiMo" },
    .{ .id = "xiaomi-token-plan-cn", .name = "Xiaomi MiMo Token Plan (China)" },
    .{ .id = "xiaomi-token-plan-ams", .name = "Xiaomi MiMo Token Plan (Amsterdam)" },
    .{ .id = "xiaomi-token-plan-sgp", .name = "Xiaomi MiMo Token Plan (Singapore)" },
};

pub fn get(provider: []const u8) ?[]const u8 {
    for (built_in_provider_display_names) |entry| {
        if (std.mem.eql(u8, entry.id, provider)) return entry.name;
    }
    return null;
}

pub fn has(provider: []const u8) bool {
    return get(provider) != null;
}

test "built-in provider display names match Pi table" {
    try std.testing.expectEqualStrings("Anthropic", get("anthropic").?);
    try std.testing.expectEqualStrings("OpenAI", get("openai").?);
    try std.testing.expectEqualStrings("Xiaomi MiMo Token Plan (Singapore)", get("xiaomi-token-plan-sgp").?);
    try std.testing.expect(get("custom-provider") == null);
}
