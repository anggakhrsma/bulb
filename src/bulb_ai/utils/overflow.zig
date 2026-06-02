const std = @import("std");
const types = @import("../types.zig");

const overflow_phrases = [_][]const u8{
    "prompt is too long",
    "request_too_large",
    "input is too long for requested model",
    "exceeds the context window",
    "maximum prompt length is ",
    "reduce the length of the messages",
    "maximum context length is ",
    "maximum context length of ",
    "maximum allowed input length of ",
    "is longer than the model's context length",
    "exceeds the limit of ",
    "exceeds the available context size",
    "greater than the context length",
    "context window exceeds limit",
    "exceeded model token limit",
    "too large for model with ",
    "model_context_window_exceeded",
    "prompt too long; exceeded max context length",
    "prompt too long; exceeded context length",
    "context_length_exceeded",
    "context length exceeded",
    "too many tokens",
    "token limit exceeded",
};

const non_overflow_phrases = [_][]const u8{
    "throttling error:",
    "service unavailable:",
    "rate limit",
    "too many requests",
};

pub fn isContextOverflow(message: types.AssistantMessage, context_window: ?u64) bool {
    if (message.stop_reason == .@"error") {
        if (message.error_message) |error_message| {
            if (!containsAnyAsciiIgnoreCase(error_message, &non_overflow_phrases) and
                (containsAnyAsciiIgnoreCase(error_message, &overflow_phrases) or
                    (containsAsciiIgnoreCase(error_message, "input token count") and
                        containsAsciiIgnoreCase(error_message, "exceeds the maximum")) or
                    isEmptyBodyOverflow(error_message)))
            {
                return true;
            }
        }
    }

    if (context_window) |window| {
        const input_tokens = message.usage.input + message.usage.cache_read;
        if (message.stop_reason == .stop and input_tokens > window) return true;
        if (message.stop_reason == .length and message.usage.output == 0) {
            return @as(f64, @floatFromInt(input_tokens)) >= @as(f64, @floatFromInt(window)) * 0.99;
        }
    }
    return false;
}

fn containsAnyAsciiIgnoreCase(haystack: []const u8, phrases: []const []const u8) bool {
    for (phrases) |phrase| {
        if (containsAsciiIgnoreCase(haystack, phrase)) return true;
    }
    return false;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var matches = true;
        for (needle, 0..) |byte, index| {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(byte)) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn isEmptyBodyOverflow(message: []const u8) bool {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    return std.mem.eql(u8, trimmed, "400 (no body)") or
        std.mem.eql(u8, trimmed, "413 (no body)") or
        std.mem.eql(u8, trimmed, "400 status code (no body)") or
        std.mem.eql(u8, trimmed, "413 status code (no body)");
}

fn errorMessage(error_message: []const u8) types.AssistantMessage {
    return .{
        .content = &.{},
        .api = types.api.openai_completions,
        .provider = "ollama",
        .model = "qwen3.5:35b",
        .stop_reason = .@"error",
        .error_message = error_message,
    };
}

test "overflow detects upstream explicit provider errors" {
    const cases = [_][]const u8{
        "400 `prompt too long; exceeded max context length by 100918 tokens`",
        "400 The input (516368 tokens) is longer than the model's context length (262144 tokens).",
        "Requested token count exceeds the model's maximum context length of 131072 tokens.",
        "Provider returned error: Input length 131393 exceeds the maximum allowed input length of 131040 tokens.",
        "Prompt contains 999 tokens too large for model with 512 maximum context length",
        "413 status code (no body)",
    };
    for (cases) |message| try std.testing.expect(isContextOverflow(errorMessage(message), 32_768));
}

test "overflow excludes rate limiting and ordinary server errors" {
    const cases = [_][]const u8{
        "500 `model runner crashed unexpectedly`",
        "Throttling error: Too many tokens, please wait before trying again.",
        "Service unavailable: The service is temporarily unavailable.",
        "Rate limit exceeded, please retry after 30 seconds.",
        "Too many requests. Please slow down.",
    };
    for (cases) |message| try std.testing.expect(!isContextOverflow(errorMessage(message), 200_000));
}

test "overflow detects silent and length-stop provider behavior" {
    var message = errorMessage("");
    message.stop_reason = .stop;
    message.usage = .{ .input = 1_049_000, .cache_read = 100 };
    try std.testing.expect(isContextOverflow(message, 1_048_576));

    message.stop_reason = .length;
    message.usage = .{ .input = 58, .cache_read = 1_048_512, .output = 0 };
    try std.testing.expect(isContextOverflow(message, 1_048_576));

    message.usage = .{ .input = 1_000, .output = 4_096 };
    try std.testing.expect(!isContextOverflow(message, 200_000));
    message.usage = .{ .input = 100, .output = 0 };
    try std.testing.expect(!isContextOverflow(message, 200_000));
}
