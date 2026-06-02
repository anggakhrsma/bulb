const std = @import("std");

/// Strip `//` line comments and trailing commas from JSON, leaving string literals untouched.
pub fn stripJsonCommentsAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const without_comments = try stripLineCommentsAlloc(allocator, input);
    defer allocator.free(without_comments);
    return stripTrailingCommasAlloc(allocator, without_comments);
}

fn stripLineCommentsAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    var in_string = false;
    var escaped = false;

    while (index < input.len) {
        const byte = input[index];

        if (in_string) {
            try output.append(allocator, byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if (byte == '"') {
            in_string = true;
            try output.append(allocator, byte);
            index += 1;
            continue;
        }

        if (byte == '/' and index + 1 < input.len and input[index + 1] == '/') {
            index += 2;
            while (index < input.len and input[index] != '\n') : (index += 1) {}
            continue;
        }

        try output.append(allocator, byte);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn stripTrailingCommasAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    var in_string = false;
    var escaped = false;

    while (index < input.len) {
        const byte = input[index];

        if (in_string) {
            try output.append(allocator, byte);
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if (byte == '"') {
            in_string = true;
            try output.append(allocator, byte);
            index += 1;
            continue;
        }

        if (byte == ',') {
            var lookahead = index + 1;
            while (lookahead < input.len and std.ascii.isWhitespace(input[lookahead])) : (lookahead += 1) {}
            if (lookahead < input.len and (input[lookahead] == '}' or input[lookahead] == ']')) {
                try output.appendSlice(allocator, input[index + 1 .. lookahead + 1]);
                index = lookahead + 1;
                continue;
            }
        }

        try output.append(allocator, byte);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

test "stripJsonComments strips line comments and trailing commas" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  // provider comment
        \\  "provider": "openai",
        \\  "models": [
        \\    "gpt-4.1",
        \\    "o3",
        \\  ],
        \\}
    ;

    const stripped = try stripJsonCommentsAlloc(allocator, input);
    defer allocator.free(stripped);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("openai", parsed.value.object.get("provider").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("models").?.array.items.len);
}

test "stripJsonComments leaves string literals untouched" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "url": "https://example.test//path",
        \\  "escaped": "quote: \" // still text",
        \\  "literal": ",]",
        \\}
    ;

    const stripped = try stripJsonCommentsAlloc(allocator, input);
    defer allocator.free(stripped);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://example.test//path", parsed.value.object.get("url").?.string);
    try std.testing.expectEqualStrings("quote: \" // still text", parsed.value.object.get("escaped").?.string);
    try std.testing.expectEqualStrings(",]", parsed.value.object.get("literal").?.string);
}

test "stripJsonComments does not strip block comments" {
    const allocator = std.testing.allocator;
    const input = "{\"a\": /* block */ 1}";
    const stripped = try stripJsonCommentsAlloc(allocator, input);
    defer allocator.free(stripped);
    try std.testing.expectEqualStrings(input, stripped);
}
