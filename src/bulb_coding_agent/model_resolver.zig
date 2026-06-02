const std = @import("std");
const ai = @import("bulb_ai");
const model_registry = @import("model_registry.zig");

pub const default_thinking_level: ai.ThinkingLevel = .medium;

pub const ProviderDefault = struct {
    provider: []const u8,
    model_id: []const u8,
};

pub const default_model_per_provider = [_]ProviderDefault{
    .{ .provider = "amazon-bedrock", .model_id = "us.anthropic.claude-opus-4-6-v1" },
    .{ .provider = "anthropic", .model_id = "claude-opus-4-8" },
    .{ .provider = "openai", .model_id = "gpt-5.4" },
    .{ .provider = "azure-openai-responses", .model_id = "gpt-5.4" },
    .{ .provider = "openai-codex", .model_id = "gpt-5.5" },
    .{ .provider = "deepseek", .model_id = "deepseek-v4-pro" },
    .{ .provider = "google", .model_id = "gemini-3.1-pro-preview" },
    .{ .provider = "google-vertex", .model_id = "gemini-3.1-pro-preview" },
    .{ .provider = "github-copilot", .model_id = "gpt-5.4" },
    .{ .provider = "openrouter", .model_id = "moonshotai/kimi-k2.6" },
    .{ .provider = "vercel-ai-gateway", .model_id = "zai/glm-5.1" },
    .{ .provider = "xai", .model_id = "grok-4.20-0309-reasoning" },
    .{ .provider = "groq", .model_id = "openai/gpt-oss-120b" },
    .{ .provider = "cerebras", .model_id = "zai-glm-4.7" },
    .{ .provider = "zai", .model_id = "glm-5.1" },
    .{ .provider = "mistral", .model_id = "devstral-medium-latest" },
    .{ .provider = "minimax", .model_id = "MiniMax-M2.7" },
    .{ .provider = "minimax-cn", .model_id = "MiniMax-M2.7" },
    .{ .provider = "moonshotai", .model_id = "kimi-k2.6" },
    .{ .provider = "moonshotai-cn", .model_id = "kimi-k2.6" },
    .{ .provider = "huggingface", .model_id = "moonshotai/Kimi-K2.6" },
    .{ .provider = "fireworks", .model_id = "accounts/fireworks/models/kimi-k2p6" },
    .{ .provider = "together", .model_id = "moonshotai/Kimi-K2.6" },
    .{ .provider = "opencode", .model_id = "kimi-k2.6" },
    .{ .provider = "opencode-go", .model_id = "kimi-k2.6" },
    .{ .provider = "kimi-coding", .model_id = "kimi-for-coding" },
    .{ .provider = "cloudflare-workers-ai", .model_id = "@cf/moonshotai/kimi-k2.6" },
    .{ .provider = "cloudflare-ai-gateway", .model_id = "workers-ai/@cf/moonshotai/kimi-k2.6" },
    .{ .provider = "xiaomi", .model_id = "mimo-v2.5-pro" },
    .{ .provider = "xiaomi-token-plan-cn", .model_id = "mimo-v2.5-pro" },
    .{ .provider = "xiaomi-token-plan-ams", .model_id = "mimo-v2.5-pro" },
    .{ .provider = "xiaomi-token-plan-sgp", .model_id = "mimo-v2.5-pro" },
};

pub const ScopedModel = struct {
    model: ai.Model,
    thinking_level: ?ai.ThinkingLevel = null,
};

pub const ParseModelOptions = struct {
    allow_invalid_thinking_level_fallback: bool = true,
};

pub const ModelPatternWarning = struct {
    suffix: []const u8,
    pattern: []const u8,

    pub fn formatAlloc(self: ModelPatternWarning, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "Invalid thinking level \"{s}\" in pattern \"{s}\". Using default instead.",
            .{ self.suffix, self.pattern },
        );
    }
};

pub const ParsedModelResult = struct {
    model: ?ai.Model = null,
    thinking_level: ?ai.ThinkingLevel = null,
    warning: ?ModelPatternWarning = null,
};

pub const ResolveCliModelOptions = struct {
    cli_provider: ?[]const u8 = null,
    cli_model: ?[]const u8 = null,
    model_registry: *model_registry.ModelRegistry,
};

pub const ResolveCliModelResult = struct {
    model: ?ai.Model = null,
    thinking_level: ?ai.ThinkingLevel = null,
    warning: ?[]u8 = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *ResolveCliModelResult, allocator: std.mem.Allocator) void {
        if (self.warning) |warning| allocator.free(warning);
        if (self.error_message) |message| allocator.free(message);
        self.* = .{};
    }
};

pub const FindInitialModelOptions = struct {
    cli_provider: ?[]const u8 = null,
    cli_model: ?[]const u8 = null,
    scoped_models: []const ScopedModel = &.{},
    is_continuing: bool,
    default_provider: ?[]const u8 = null,
    default_model_id: ?[]const u8 = null,
    default_thinking_level: ?ai.ThinkingLevel = null,
    model_registry: *model_registry.ModelRegistry,
};

pub const InitialModelResult = struct {
    model: ?ai.Model = null,
    thinking_level: ai.ThinkingLevel = default_thinking_level,
    fallback_message: ?[]u8 = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *InitialModelResult, allocator: std.mem.Allocator) void {
        if (self.fallback_message) |message| allocator.free(message);
        if (self.error_message) |message| allocator.free(message);
        self.* = .{};
    }
};

pub const RestoreModelResult = struct {
    model: ?ai.Model = null,
    fallback_message: ?[]u8 = null,

    pub fn deinit(self: *RestoreModelResult, allocator: std.mem.Allocator) void {
        if (self.fallback_message) |message| allocator.free(message);
        self.* = .{};
    }
};

pub const ResolveModelScopeResult = struct {
    scoped_models: []ScopedModel = &.{},
    warnings: [][]u8 = &.{},

    pub fn deinit(self: *ResolveModelScopeResult, allocator: std.mem.Allocator) void {
        if (self.scoped_models.len > 0) allocator.free(self.scoped_models);
        for (self.warnings) |warning| allocator.free(warning);
        if (self.warnings.len > 0) allocator.free(self.warnings);
        self.* = .{};
    }
};

pub fn defaultModelForProvider(provider: []const u8) ?[]const u8 {
    for (&default_model_per_provider) |entry| {
        if (std.mem.eql(u8, entry.provider, provider)) return entry.model_id;
    }
    return null;
}

pub fn isValidThinkingLevel(value: []const u8) bool {
    return parseThinkingLevel(value) != null;
}

pub fn parseThinkingLevel(value: []const u8) ?ai.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

pub fn findExactModelReferenceMatch(model_reference: []const u8, available_models: []const ai.Model) ?ai.Model {
    const trimmed_reference = std.mem.trim(u8, model_reference, " \t\r\n");
    if (trimmed_reference.len == 0) return null;

    var canonical_match: ?ai.Model = null;
    var canonical_count: usize = 0;
    for (available_models) |model| {
        if (canonicalModelReferenceEquals(model, trimmed_reference)) {
            canonical_match = model;
            canonical_count += 1;
        }
    }
    if (canonical_count == 1) return canonical_match;
    if (canonical_count > 1) return null;

    if (std.mem.indexOfScalar(u8, trimmed_reference, '/')) |slash_index| {
        const provider = std.mem.trim(u8, trimmed_reference[0..slash_index], " \t\r\n");
        const model_id = std.mem.trim(u8, trimmed_reference[slash_index + 1 ..], " \t\r\n");
        if (provider.len > 0 and model_id.len > 0) {
            var provider_match: ?ai.Model = null;
            var provider_count: usize = 0;
            for (available_models) |model| {
                if (std.ascii.eqlIgnoreCase(model.provider, provider) and std.ascii.eqlIgnoreCase(model.id, model_id)) {
                    provider_match = model;
                    provider_count += 1;
                }
            }
            if (provider_count == 1) return provider_match;
            if (provider_count > 1) return null;
        }
    }

    var id_match: ?ai.Model = null;
    var id_count: usize = 0;
    for (available_models) |model| {
        if (std.ascii.eqlIgnoreCase(model.id, trimmed_reference)) {
            id_match = model;
            id_count += 1;
        }
    }
    return if (id_count == 1) id_match else null;
}

pub fn parseModelPattern(
    pattern: []const u8,
    available_models: []const ai.Model,
    options: ParseModelOptions,
) ParsedModelResult {
    if (tryMatchModel(pattern, available_models)) |model| {
        return .{ .model = model };
    }

    const last_colon_index = std.mem.lastIndexOfScalar(u8, pattern, ':') orelse {
        return .{};
    };
    const prefix = pattern[0..last_colon_index];
    const suffix = pattern[last_colon_index + 1 ..];

    if (parseThinkingLevel(suffix)) |thinking_level| {
        const result = parseModelPattern(prefix, available_models, options);
        if (result.model) |model| {
            return .{
                .model = model,
                .thinking_level = if (result.warning == null) thinking_level else null,
                .warning = result.warning,
            };
        }
        return result;
    }

    if (!options.allow_invalid_thinking_level_fallback) {
        return .{};
    }

    const result = parseModelPattern(prefix, available_models, options);
    if (result.model) |model| {
        return .{
            .model = model,
            .warning = .{ .suffix = suffix, .pattern = pattern },
        };
    }
    return result;
}

pub fn resolveCliModelAlloc(
    allocator: std.mem.Allocator,
    options: ResolveCliModelOptions,
) !ResolveCliModelResult {
    const cli_model = options.cli_model orelse return .{};
    const available_models = options.model_registry.getAll();
    return resolveCliModelFromModelsAlloc(allocator, options.cli_provider, cli_model, available_models);
}

pub fn resolveCliModelFromModelsAlloc(
    allocator: std.mem.Allocator,
    cli_provider: ?[]const u8,
    cli_model: []const u8,
    available_models: []const ai.Model,
) !ResolveCliModelResult {
    if (available_models.len == 0) {
        return .{
            .error_message = try allocator.dupe(
                u8,
                "No models available. Check your installation or add models to models.json.",
            ),
        };
    }

    var provider: ?[]const u8 = if (cli_provider) |value| findCanonicalProvider(value, available_models) else null;
    if (cli_provider != null and provider == null) {
        return .{
            .error_message = try std.fmt.allocPrint(
                allocator,
                "Unknown provider \"{s}\". Use --list-models to see available providers/models.",
                .{cli_provider.?},
            ),
        };
    }

    var pattern = cli_model;
    var inferred_provider = false;

    if (provider == null) {
        if (std.mem.indexOfScalar(u8, cli_model, '/')) |slash_index| {
            const maybe_provider = cli_model[0..slash_index];
            if (findCanonicalProvider(maybe_provider, available_models)) |canonical| {
                provider = canonical;
                pattern = cli_model[slash_index + 1 ..];
                inferred_provider = true;
            }
        }
    }

    if (provider == null) {
        if (findExactCliModel(cli_model, available_models)) |model| {
            return .{ .model = model };
        }
    }

    if (cli_provider != null and provider != null) {
        const provider_value = provider.?;
        if (startsWithProviderPrefix(cli_model, provider_value)) {
            pattern = cli_model[provider_value.len + 1 ..];
        }
    }

    const candidates = try filterModelsForProviderAlloc(allocator, available_models, provider);
    defer allocator.free(candidates);

    const parsed = parseModelPattern(pattern, candidates, .{
        .allow_invalid_thinking_level_fallback = false,
    });
    if (parsed.model) |model| {
        return .{
            .model = model,
            .thinking_level = parsed.thinking_level,
            .warning = if (parsed.warning) |warning| try warning.formatAlloc(allocator) else null,
        };
    }

    if (inferred_provider) {
        if (findExactCliModel(cli_model, available_models)) |model| {
            return .{ .model = model };
        }
        const fallback = parseModelPattern(cli_model, available_models, .{
            .allow_invalid_thinking_level_fallback = false,
        });
        if (fallback.model) |model| {
            return .{
                .model = model,
                .thinking_level = fallback.thinking_level,
                .warning = if (fallback.warning) |warning| try warning.formatAlloc(allocator) else null,
            };
        }
    }

    if (provider) |provider_value| {
        if (buildFallbackModel(provider_value, pattern, available_models)) |fallback_model| {
            return .{
                .model = fallback_model,
                .warning = try std.fmt.allocPrint(
                    allocator,
                    "Model \"{s}\" not found for provider \"{s}\". Using custom model id.",
                    .{ pattern, provider_value },
                ),
            };
        }
    }

    const display = if (provider) |provider_value|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider_value, pattern })
    else
        try allocator.dupe(u8, cli_model);
    defer allocator.free(display);

    return .{
        .error_message = try std.fmt.allocPrint(
            allocator,
            "Model \"{s}\" not found. Use --list-models to see available models.",
            .{display},
        ),
    };
}

pub fn resolveModelScopeAlloc(
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
    registry: *model_registry.ModelRegistry,
) !ResolveModelScopeResult {
    const available = try registry.getAvailableAlloc(allocator);
    defer allocator.free(available);

    const models = try allocator.alloc(ai.Model, available.len);
    defer allocator.free(models);
    for (available, 0..) |model, index| models[index] = model.*;

    var scoped_models: std.ArrayList(ScopedModel) = .empty;
    errdefer scoped_models.deinit(allocator);
    var warnings: std.ArrayList([]u8) = .empty;
    errdefer {
        for (warnings.items) |warning| allocator.free(warning);
        warnings.deinit(allocator);
    }

    for (patterns) |pattern| {
        if (hasGlobCharacters(pattern)) {
            var glob_pattern = pattern;
            var thinking_level: ?ai.ThinkingLevel = null;
            if (std.mem.lastIndexOfScalar(u8, pattern, ':')) |colon_index| {
                const suffix = pattern[colon_index + 1 ..];
                if (parseThinkingLevel(suffix)) |level| {
                    thinking_level = level;
                    glob_pattern = pattern[0..colon_index];
                }
            }

            var matched = false;
            for (models) |model| {
                if (globMatchesModel(glob_pattern, model)) {
                    matched = true;
                    if (!containsScopedModel(scoped_models.items, model)) {
                        try scoped_models.append(allocator, .{ .model = model, .thinking_level = thinking_level });
                    }
                }
            }
            if (!matched) {
                try warnings.append(allocator, try std.fmt.allocPrint(
                    allocator,
                    "No models match pattern \"{s}\"",
                    .{pattern},
                ));
            }
            continue;
        }

        const parsed = parseModelPattern(pattern, models, .{});
        if (parsed.warning) |warning| {
            try warnings.append(allocator, try warning.formatAlloc(allocator));
        }
        const model = parsed.model orelse {
            try warnings.append(allocator, try std.fmt.allocPrint(
                allocator,
                "No models match pattern \"{s}\"",
                .{pattern},
            ));
            continue;
        };
        if (!containsScopedModel(scoped_models.items, model)) {
            try scoped_models.append(allocator, .{ .model = model, .thinking_level = parsed.thinking_level });
        }
    }

    return .{
        .scoped_models = try scoped_models.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

pub fn findInitialModelAlloc(
    allocator: std.mem.Allocator,
    options: FindInitialModelOptions,
) !InitialModelResult {
    if (options.cli_provider != null and options.cli_model != null) {
        var resolved = try resolveCliModelAlloc(allocator, .{
            .cli_provider = options.cli_provider,
            .cli_model = options.cli_model,
            .model_registry = options.model_registry,
        });
        defer {
            resolved.deinit(allocator);
        }
        if (resolved.error_message) |message| {
            resolved.error_message = null;
            return .{ .error_message = message };
        }
        if (resolved.model) |model| {
            return .{ .model = model, .thinking_level = default_thinking_level };
        }
    }

    if (options.scoped_models.len > 0 and !options.is_continuing) {
        const scoped_model = options.scoped_models[0];
        return .{
            .model = scoped_model.model,
            .thinking_level = scoped_model.thinking_level orelse options.default_thinking_level orelse default_thinking_level,
        };
    }

    if (options.default_provider != null and options.default_model_id != null) {
        if (options.model_registry.find(options.default_provider.?, options.default_model_id.?)) |model| {
            return .{
                .model = model.*,
                .thinking_level = options.default_thinking_level orelse default_thinking_level,
            };
        }
    }

    const available = try options.model_registry.getAvailableAlloc(allocator);
    defer allocator.free(available);
    if (available.len > 0) {
        if (findDefaultAvailableModel(available)) |model| {
            return .{ .model = model.* };
        }
        return .{ .model = available[0].* };
    }

    return .{};
}

pub fn restoreModelFromSessionAlloc(
    allocator: std.mem.Allocator,
    saved_provider: []const u8,
    saved_model_id: []const u8,
    current_model: ?ai.Model,
    model_registry_value: *model_registry.ModelRegistry,
) !RestoreModelResult {
    const restored_model = model_registry_value.find(saved_provider, saved_model_id);
    const has_configured_auth = if (restored_model) |model|
        try model_registry_value.hasConfiguredAuth(model)
    else
        false;

    if (restored_model != null and has_configured_auth) {
        return .{ .model = restored_model.?.* };
    }

    const reason = if (restored_model == null) "model no longer exists" else "no auth configured";
    if (current_model) |model| {
        return .{
            .model = model,
            .fallback_message = try std.fmt.allocPrint(
                allocator,
                "Could not restore model {s}/{s} ({s}). Using {s}/{s}.",
                .{ saved_provider, saved_model_id, reason, model.provider, model.id },
            ),
        };
    }

    const available = try model_registry_value.getAvailableAlloc(allocator);
    defer allocator.free(available);
    if (available.len == 0) return .{};

    const fallback_model = if (findDefaultAvailableModel(available)) |model| model else available[0];
    return .{
        .model = fallback_model.*,
        .fallback_message = try std.fmt.allocPrint(
            allocator,
            "Could not restore model {s}/{s} ({s}). Using {s}/{s}.",
            .{ saved_provider, saved_model_id, reason, fallback_model.provider, fallback_model.id },
        ),
    };
}

fn tryMatchModel(model_pattern: []const u8, available_models: []const ai.Model) ?ai.Model {
    if (findExactModelReferenceMatch(model_pattern, available_models)) |exact_match| return exact_match;

    var best_alias: ?ai.Model = null;
    var best_dated: ?ai.Model = null;
    for (available_models) |model| {
        const matches = containsIgnoreCase(model.id, model_pattern) or containsIgnoreCase(model.name, model_pattern);
        if (!matches) continue;

        if (isAlias(model.id)) {
            if (best_alias == null or std.mem.order(u8, model.id, best_alias.?.id) == .gt) {
                best_alias = model;
            }
        } else if (best_dated == null or std.mem.order(u8, model.id, best_dated.?.id) == .gt) {
            best_dated = model;
        }
    }

    return best_alias orelse best_dated;
}

fn isAlias(id: []const u8) bool {
    if (std.mem.endsWith(u8, id, "-latest")) return true;
    return !endsWithDateSuffix(id);
}

fn endsWithDateSuffix(value: []const u8) bool {
    if (value.len < 9) return false;
    const suffix = value[value.len - 9 ..];
    if (suffix[0] != '-') return false;
    for (suffix[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

fn canonicalModelReferenceEquals(model: ai.Model, reference: []const u8) bool {
    if (reference.len != model.provider.len + 1 + model.id.len) return false;
    if (!std.ascii.eqlIgnoreCase(reference[0..model.provider.len], model.provider)) return false;
    if (reference[model.provider.len] != '/') return false;
    return std.ascii.eqlIgnoreCase(reference[model.provider.len + 1 ..], model.id);
}

fn findCanonicalProvider(provider: []const u8, available_models: []const ai.Model) ?[]const u8 {
    for (available_models) |model| {
        if (std.ascii.eqlIgnoreCase(model.provider, provider)) return model.provider;
    }
    return null;
}

fn startsWithProviderPrefix(value: []const u8, provider: []const u8) bool {
    if (value.len <= provider.len) return false;
    if (value[provider.len] != '/') return false;
    return std.ascii.eqlIgnoreCase(value[0..provider.len], provider);
}

fn findExactCliModel(cli_model: []const u8, available_models: []const ai.Model) ?ai.Model {
    for (available_models) |model| {
        if (std.ascii.eqlIgnoreCase(model.id, cli_model) or canonicalModelReferenceEquals(model, cli_model)) return model;
    }
    return null;
}

fn filterModelsForProviderAlloc(
    allocator: std.mem.Allocator,
    available_models: []const ai.Model,
    provider: ?[]const u8,
) ![]ai.Model {
    if (provider == null) return try allocator.dupe(ai.Model, available_models);

    var filtered: std.ArrayList(ai.Model) = .empty;
    defer filtered.deinit(allocator);
    for (available_models) |model| {
        if (std.mem.eql(u8, model.provider, provider.?)) try filtered.append(allocator, model);
    }
    return try filtered.toOwnedSlice(allocator);
}

fn buildFallbackModel(provider: []const u8, model_id: []const u8, available_models: []const ai.Model) ?ai.Model {
    var first_provider_model: ?ai.Model = null;
    var default_provider_model: ?ai.Model = null;
    const default_model_id = defaultModelForProvider(provider);
    for (available_models) |model| {
        if (!std.mem.eql(u8, model.provider, provider)) continue;
        if (first_provider_model == null) first_provider_model = model;
        if (default_model_id != null and std.mem.eql(u8, model.id, default_model_id.?)) {
            default_provider_model = model;
        }
    }

    var fallback = default_provider_model orelse first_provider_model orelse return null;
    fallback.id = model_id;
    fallback.name = model_id;
    return fallback;
}

fn findDefaultAvailableModel(available_models: []const *const ai.Model) ?*const ai.Model {
    for (&default_model_per_provider) |entry| {
        for (available_models) |model| {
            if (std.mem.eql(u8, model.provider, entry.provider) and std.mem.eql(u8, model.id, entry.model_id)) return model;
        }
    }
    return null;
}

fn containsScopedModel(scoped_models: []const ScopedModel, model: ai.Model) bool {
    for (scoped_models) |scoped_model| {
        if (modelsAreEqual(scoped_model.model, model)) return true;
    }
    return false;
}

fn modelsAreEqual(a: ai.Model, b: ai.Model) bool {
    return std.mem.eql(u8, a.provider, b.provider) and std.mem.eql(u8, a.id, b.id);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn hasGlobCharacters(pattern: []const u8) bool {
    for (pattern) |byte| {
        if (byte == '*' or byte == '?' or byte == '[') return true;
    }
    return false;
}

fn globMatchesModel(pattern: []const u8, model: ai.Model) bool {
    if (globMatchesIgnoreCase(pattern, model.id)) return true;
    var full_reference_buffer: [1024]u8 = undefined;
    const full_reference = std.fmt.bufPrint(&full_reference_buffer, "{s}/{s}", .{ model.provider, model.id }) catch return false;
    return globMatchesIgnoreCase(pattern, full_reference);
}

fn globMatchesIgnoreCase(pattern: []const u8, value: []const u8) bool {
    return globMatchesAt(pattern, 0, value, 0);
}

fn globMatchesAt(pattern: []const u8, pattern_index: usize, value: []const u8, value_index: usize) bool {
    var p = pattern_index;
    var v = value_index;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                while (p + 1 < pattern.len and pattern[p + 1] == '*') p += 1;
                if (p + 1 == pattern.len) return true;
                var next_value_index = v;
                while (next_value_index <= value.len) : (next_value_index += 1) {
                    if (globMatchesAt(pattern, p + 1, value, next_value_index)) return true;
                }
                return false;
            },
            '?' => {
                if (v >= value.len) return false;
                p += 1;
                v += 1;
            },
            '[' => {
                if (v >= value.len) return false;
                const result = matchGlobClass(pattern[p..], value[v]) orelse {
                    if (!asciiByteEquals(pattern[p], value[v])) return false;
                    p += 1;
                    v += 1;
                    continue;
                };
                if (!result.matched) return false;
                p += result.consumed;
                v += 1;
            },
            else => |byte| {
                if (v >= value.len or !asciiByteEquals(byte, value[v])) return false;
                p += 1;
                v += 1;
            },
        }
    }
    return v == value.len;
}

const GlobClassResult = struct {
    matched: bool,
    consumed: usize,
};

fn matchGlobClass(pattern: []const u8, value: u8) ?GlobClassResult {
    if (pattern.len < 2 or pattern[0] != '[') return null;
    var index: usize = 1;
    var negate = false;
    if (index < pattern.len and (pattern[index] == '!' or pattern[index] == '^')) {
        negate = true;
        index += 1;
    }

    var matched = false;
    var saw_end = false;
    var previous: ?u8 = null;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == ']') {
            saw_end = true;
            break;
        }
        if (byte == '-' and previous != null and index + 1 < pattern.len and pattern[index + 1] != ']') {
            const start = std.ascii.toLower(previous.?);
            const end = std.ascii.toLower(pattern[index + 1]);
            const candidate = std.ascii.toLower(value);
            if (candidate >= @min(start, end) and candidate <= @max(start, end)) matched = true;
            previous = null;
            index += 1;
            continue;
        }
        if (asciiByteEquals(byte, value)) matched = true;
        previous = byte;
    }

    if (!saw_end) return null;
    return .{ .matched = if (negate) !matched else matched, .consumed = index + 1 };
}

fn asciiByteEquals(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

const mock_text_input = [_][]const u8{"text"};
const mock_text_image_input = [_][]const u8{ "text", "image" };

const mock_models = [_]ai.Model{
    .{
        .id = "claude-sonnet-4-5",
        .name = "Claude Sonnet 4.5",
        .api = ai.types.api.anthropic_messages,
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com",
        .reasoning = true,
        .input = &mock_text_image_input,
        .cost = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 },
        .context_window = 200000,
        .max_tokens = 8192,
    },
    .{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = ai.types.api.anthropic_messages,
        .provider = "openai",
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &mock_text_image_input,
        .cost = .{ .input = 5, .output = 15, .cache_read = 0.5, .cache_write = 5 },
        .context_window = 128000,
        .max_tokens = 4096,
    },
    .{
        .id = "qwen/qwen3-coder:exacto",
        .name = "Qwen3 Coder Exacto",
        .api = ai.types.api.anthropic_messages,
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .reasoning = true,
        .input = &mock_text_input,
        .cost = .{ .input = 1, .output = 2, .cache_read = 0.1, .cache_write = 1 },
        .context_window = 128000,
        .max_tokens = 8192,
    },
    .{
        .id = "openai/gpt-4o:extended",
        .name = "GPT-4o Extended",
        .api = ai.types.api.anthropic_messages,
        .provider = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .reasoning = false,
        .input = &mock_text_image_input,
        .cost = .{ .input = 5, .output = 15, .cache_read = 0.5, .cache_write = 5 },
        .context_window = 128000,
        .max_tokens = 4096,
    },
};

fn expectParsed(pattern: []const u8, expected_id: ?[]const u8, expected_level: ?ai.ThinkingLevel, expected_warning: ?[]const u8) !void {
    const result = parseModelPattern(pattern, &mock_models, .{});
    if (expected_id) |id| {
        try std.testing.expect(result.model != null);
        try std.testing.expectEqualStrings(id, result.model.?.id);
    } else {
        try std.testing.expect(result.model == null);
    }
    try std.testing.expectEqual(expected_level, result.thinking_level);
    if (expected_warning) |needle| {
        try std.testing.expect(result.warning != null);
        const warning = try result.warning.?.formatAlloc(std.testing.allocator);
        defer std.testing.allocator.free(warning);
        try std.testing.expect(std.mem.indexOf(u8, warning, needle) != null);
    } else {
        try std.testing.expect(result.warning == null);
    }
}

// Ported from packages/coding-agent/test/model-resolver.test.ts parseModelPattern cases.
test "model resolver parses simple model patterns and thinking suffixes" {
    try expectParsed("claude-sonnet-4-5", "claude-sonnet-4-5", null, null);
    try expectParsed("sonnet", "claude-sonnet-4-5", null, null);
    try expectParsed("nonexistent", null, null, null);
    try expectParsed("sonnet:high", "claude-sonnet-4-5", .high, null);
    try expectParsed("gpt-4o:medium", "gpt-4o", .medium, null);

    for ([_]ai.ThinkingLevel{ .off, .minimal, .low, .medium, .high, .xhigh }) |level| {
        const pattern = try std.fmt.allocPrint(std.testing.allocator, "sonnet:{s}", .{@tagName(level)});
        defer std.testing.allocator.free(pattern);
        try expectParsed(pattern, "claude-sonnet-4-5", level, null);
    }

    try expectParsed("sonnet:random", "claude-sonnet-4-5", null, "Invalid thinking level");
    try expectParsed("gpt-4o:invalid", "gpt-4o", null, "Invalid thinking level");
}

// Ported from packages/coding-agent/test/model-resolver.test.ts OpenRouter colon ID cases.
test "model resolver preserves provider and model id colons while parsing thinking suffixes" {
    try expectParsed("qwen/qwen3-coder:exacto", "qwen/qwen3-coder:exacto", null, null);
    {
        const result = parseModelPattern("openrouter/qwen/qwen3-coder:exacto", &mock_models, .{});
        try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", result.model.?.id);
        try std.testing.expectEqualStrings("openrouter", result.model.?.provider);
        try std.testing.expect(result.warning == null);
    }
    try expectParsed("qwen/qwen3-coder:exacto:high", "qwen/qwen3-coder:exacto", .high, null);
    {
        const result = parseModelPattern("openrouter/qwen/qwen3-coder:exacto:high", &mock_models, .{});
        try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", result.model.?.id);
        try std.testing.expectEqualStrings("openrouter", result.model.?.provider);
        try std.testing.expectEqual(@as(?ai.ThinkingLevel, .high), result.thinking_level);
    }
    try expectParsed("openai/gpt-4o:extended", "openai/gpt-4o:extended", null, null);
    try expectParsed("qwen/qwen3-coder:exacto:random", "qwen/qwen3-coder:exacto", null, "random");
    try expectParsed("qwen/qwen3-coder:exacto:high:random", "qwen/qwen3-coder:exacto", null, "random");
    try expectParsed("", "qwen/qwen3-coder:exacto", null, null);
    try expectParsed("sonnet:", "claude-sonnet-4-5", null, "Invalid thinking level");
}

// Ported from packages/coding-agent/test/model-resolver.test.ts resolveCliModel cases.
test "model resolver resolves CLI provider and model patterns" {
    const allocator = std.testing.allocator;

    var result = try resolveCliModelFromModelsAlloc(allocator, null, "openai/gpt-4o", &mock_models);
    defer result.deinit(allocator);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openai", result.model.?.provider);
    try std.testing.expectEqualStrings("gpt-4o", result.model.?.id);

    result.deinit(allocator);
    result = try resolveCliModelFromModelsAlloc(allocator, "openai", "4o", &mock_models);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openai", result.model.?.provider);
    try std.testing.expectEqualStrings("gpt-4o", result.model.?.id);

    result.deinit(allocator);
    result = try resolveCliModelFromModelsAlloc(allocator, null, "sonnet:high", &mock_models);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", result.model.?.id);
    try std.testing.expectEqual(@as(?ai.ThinkingLevel, .high), result.thinking_level);

    result.deinit(allocator);
    result = try resolveCliModelFromModelsAlloc(allocator, null, "openai/gpt-4o:extended", &mock_models);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openrouter", result.model.?.provider);
    try std.testing.expectEqualStrings("openai/gpt-4o:extended", result.model.?.id);

    result.deinit(allocator);
    result = try resolveCliModelFromModelsAlloc(allocator, "openai", "gpt-4o:extended", &mock_models);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openai", result.model.?.provider);
    try std.testing.expectEqualStrings("gpt-4o:extended", result.model.?.id);

    result.deinit(allocator);
    result = try resolveCliModelFromModelsAlloc(allocator, "openrouter", "openrouter/openai/ghost-model", &mock_models);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openrouter", result.model.?.provider);
    try std.testing.expectEqualStrings("openai/ghost-model", result.model.?.id);

    result.deinit(allocator);
    result = try resolveCliModelFromModelsAlloc(allocator, "openai", "gpt-4o", &.{});
    try std.testing.expect(result.model == null);
    try std.testing.expect(result.error_message != null);
    try std.testing.expect(std.mem.indexOf(u8, result.error_message.?, "No models available") != null);
}

// Ported from packages/coding-agent/test/model-resolver.test.ts provider/model precedence cases.
test "model resolver prefers provider split before gateway ids and supports provider-prefixed fuzzy matching" {
    const allocator = std.testing.allocator;
    const extra_models = [_]ai.Model{
        .{
            .id = "glm-5",
            .name = "GLM-5",
            .api = ai.types.api.anthropic_messages,
            .provider = "zai",
            .base_url = "https://open.bigmodel.cn/api/paas/v4",
            .reasoning = true,
            .input = &mock_text_input,
            .cost = .{ .input = 1, .output = 2, .cache_read = 0.1, .cache_write = 1 },
            .context_window = 128000,
            .max_tokens = 8192,
        },
        .{
            .id = "zai/glm-5",
            .name = "GLM-5",
            .api = ai.types.api.anthropic_messages,
            .provider = "vercel-ai-gateway",
            .base_url = "https://ai-gateway.vercel.sh",
            .reasoning = true,
            .input = &mock_text_input,
            .cost = .{ .input = 1, .output = 2, .cache_read = 0.1, .cache_write = 1 },
            .context_window = 128000,
            .max_tokens = 8192,
        },
    };
    var models = try std.ArrayList(ai.Model).initCapacity(allocator, mock_models.len + extra_models.len);
    defer models.deinit(allocator);
    try models.appendSlice(allocator, &mock_models);
    try models.appendSlice(allocator, &extra_models);

    var result = try resolveCliModelFromModelsAlloc(allocator, null, "zai/glm-5", models.items);
    defer result.deinit(allocator);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("zai", result.model.?.provider);
    try std.testing.expectEqualStrings("glm-5", result.model.?.id);

    result.deinit(allocator);
    result = try resolveCliModelFromModelsAlloc(allocator, null, "openrouter/qwen", &mock_models);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openrouter", result.model.?.provider);
    try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", result.model.?.id);
}

// Ported from packages/coding-agent/test/model-resolver.test.ts default model constants.
test "model resolver default model selection tracks Pi snapshot" {
    try std.testing.expectEqualStrings("gpt-5.4", defaultModelForProvider("openai").?);
    try std.testing.expectEqualStrings("gpt-5.5", defaultModelForProvider("openai-codex").?);
    try std.testing.expectEqualStrings("glm-5.1", defaultModelForProvider("zai").?);
    try std.testing.expectEqualStrings("MiniMax-M2.7", defaultModelForProvider("minimax").?);
    try std.testing.expectEqualStrings("MiniMax-M2.7", defaultModelForProvider("minimax-cn").?);
    try std.testing.expectEqualStrings("zai-glm-4.7", defaultModelForProvider("cerebras").?);
    try std.testing.expectEqualStrings("zai/glm-5.1", defaultModelForProvider("vercel-ai-gateway").?);
}

// Ported from packages/coding-agent/test/model-resolver.test.ts findInitialModel pure selection cases.
test "model resolver initial selection accepts custom provider model ids and available defaults" {
    const allocator = std.testing.allocator;
    var result = try resolveCliModelFromModelsAlloc(
        allocator,
        "openrouter",
        "openrouter/openai/ghost-model",
        &mock_models,
    );
    defer result.deinit(allocator);
    try std.testing.expect(result.error_message == null);
    try std.testing.expectEqualStrings("openrouter", result.model.?.provider);
    try std.testing.expectEqualStrings("openai/ghost-model", result.model.?.id);

    const ai_gateway_model = ai.Model{
        .id = "anthropic/claude-opus-4-6",
        .name = "Claude Opus 4.6",
        .api = ai.types.api.anthropic_messages,
        .provider = "vercel-ai-gateway",
        .base_url = "https://ai-gateway.vercel.sh",
        .reasoning = true,
        .input = &mock_text_image_input,
        .cost = .{ .input = 5, .output = 15, .cache_read = 0.5, .cache_write = 5 },
        .context_window = 200000,
        .max_tokens = 8192,
    };
    const available = [_]*const ai.Model{&ai_gateway_model};
    const selected = findDefaultAvailableModel(&available) orelse available[0];
    try std.testing.expectEqualStrings("vercel-ai-gateway", selected.provider);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4-6", selected.id);
}
