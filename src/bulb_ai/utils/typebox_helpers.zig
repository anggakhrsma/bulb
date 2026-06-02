const std = @import("std");

pub const StringEnumOptions = struct {
    description: ?[]const u8 = null,
    default: ?[]const u8 = null,
};

pub fn stringEnumSchemaJson(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    options: StringEnumOptions,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, "{\"type\":\"string\",\"enum\":[");
    for (values, 0..) |value, index| {
        if (index > 0) try output.append(allocator, ',');
        try appendJsonString(allocator, &output, value);
    }
    try output.append(allocator, ']');
    if (options.description) |description| {
        try output.appendSlice(allocator, ",\"description\":");
        try appendJsonString(allocator, &output, description);
    }
    if (options.default) |default| {
        try output.appendSlice(allocator, ",\"default\":");
        try appendJsonString(allocator, &output, default);
    }
    try output.append(allocator, '}');

    return output.toOwnedSlice(allocator);
}

fn appendJsonString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    try output.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            '\n' => try output.appendSlice(allocator, "\\n"),
            '\r' => try output.appendSlice(allocator, "\\r"),
            '\t' => try output.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0e...0x1f => {
                try output.appendSlice(allocator, "\\u00");
                const digits = "0123456789abcdef";
                try output.append(allocator, digits[byte >> 4]);
                try output.append(allocator, digits[byte & 0x0f]);
            },
            else => try output.append(allocator, byte),
        }
    }
    try output.append(allocator, '"');
}

// Ported from packages/ai/src/utils/typebox-helpers.ts.
test "StringEnum creates provider-compatible string enum schema JSON" {
    const allocator = std.testing.allocator;
    const schema = try stringEnumSchemaJson(
        allocator,
        &.{ "add", "subtract", "multiply", "divide" },
        .{
            .description = "The operation to perform",
            .default = "add",
        },
    );
    defer allocator.free(schema);

    try std.testing.expectEqualStrings(
        "{\"type\":\"string\",\"enum\":[\"add\",\"subtract\",\"multiply\",\"divide\"],\"description\":\"The operation to perform\",\"default\":\"add\"}",
        schema,
    );
}
