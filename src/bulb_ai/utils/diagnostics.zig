const std = @import("std");
const types = @import("../types.zig");

pub fn formatThrownError(err: anyerror) []const u8 {
    return @errorName(err);
}

pub fn formatThrownValue(value: []const u8) []const u8 {
    return value;
}

pub fn extractDiagnosticError(err: anyerror) types.DiagnosticErrorInfo {
    return .{
        .name = "ZigError",
        .message = formatThrownError(err),
    };
}

pub fn extractDiagnosticThrownValue(value: []const u8) types.DiagnosticErrorInfo {
    return .{
        .name = "ThrownValue",
        .message = formatThrownValue(value),
    };
}

pub fn createAssistantMessageDiagnosticFromError(
    diagnostic_type: []const u8,
    err: anyerror,
    details_json: ?[]const u8,
) types.AssistantMessageDiagnostic {
    return .{
        .type = diagnostic_type,
        .timestamp_ms = currentTimestampMs(),
        .@"error" = extractDiagnosticError(err),
        .details_json = details_json,
    };
}

pub fn createAssistantMessageDiagnosticFromThrownValue(
    diagnostic_type: []const u8,
    value: []const u8,
    details_json: ?[]const u8,
) types.AssistantMessageDiagnostic {
    return .{
        .type = diagnostic_type,
        .timestamp_ms = currentTimestampMs(),
        .@"error" = extractDiagnosticThrownValue(value),
        .details_json = details_json,
    };
}

pub fn currentTimestampMs() i64 {
    return 0;
}

pub fn appendAssistantMessageDiagnostic(
    allocator: std.mem.Allocator,
    message: *types.AssistantMessage,
    diagnostic: types.AssistantMessageDiagnostic,
) !void {
    const next = try allocator.alloc(types.AssistantMessageDiagnostic, message.diagnostics.len + 1);
    @memcpy(next[0..message.diagnostics.len], message.diagnostics);
    next[message.diagnostics.len] = diagnostic;
    message.diagnostics = next;
}

test "diagnostics format Zig errors and thrown values" {
    const from_error = extractDiagnosticError(error.ProviderUnavailable);
    try std.testing.expectEqualStrings("ZigError", from_error.name.?);
    try std.testing.expectEqualStrings("ProviderUnavailable", from_error.message);

    const from_value = extractDiagnosticThrownValue("plain thrown value");
    try std.testing.expectEqualStrings("ThrownValue", from_value.name.?);
    try std.testing.expectEqualStrings("plain thrown value", from_value.message);
}

test "diagnostics append to assistant messages without replacing existing entries" {
    const allocator = std.testing.allocator;
    var message: types.AssistantMessage = .{
        .content = &.{},
        .api = types.api.anthropic_messages,
        .provider = "anthropic",
        .model = "claude-haiku-4-5",
    };
    defer allocator.free(message.diagnostics);

    try appendAssistantMessageDiagnostic(
        allocator,
        &message,
        createAssistantMessageDiagnosticFromThrownValue("provider.error", "failed", "{\"retry\":false}"),
    );

    try std.testing.expectEqual(@as(usize, 1), message.diagnostics.len);
    try std.testing.expectEqualStrings("provider.error", message.diagnostics[0].type);
    try std.testing.expectEqualStrings("failed", message.diagnostics[0].@"error".?.message);
    try std.testing.expectEqualStrings("{\"retry\":false}", message.diagnostics[0].details_json.?);
}
