const std = @import("std");

pub const ParsedValue = std.json.Parsed(std.json.Value);

pub fn repairJson(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var repaired: std.ArrayList(u8) = .empty;
    errdefer repaired.deinit(allocator);
    var in_string = false;
    var index: usize = 0;

    while (index < json.len) : (index += 1) {
        const byte = json[index];
        if (!in_string) {
            try repaired.append(allocator, byte);
            if (byte == '"') in_string = true;
            continue;
        }

        if (byte == '"') {
            try repaired.append(allocator, byte);
            in_string = false;
            continue;
        }

        if (byte == '\\') {
            if (index + 1 >= json.len) {
                try repaired.appendSlice(allocator, "\\\\");
                continue;
            }

            const next = json[index + 1];
            if (next == 'u' and index + 5 < json.len and isHexQuad(json[index + 2 .. index + 6])) {
                try repaired.appendSlice(allocator, json[index .. index + 6]);
                index += 5;
                continue;
            }
            if (isValidEscape(next)) {
                try repaired.appendSlice(allocator, json[index .. index + 2]);
                index += 1;
                continue;
            }

            try repaired.appendSlice(allocator, "\\\\");
            continue;
        }

        if (byte <= 0x1f) {
            try appendEscapedControl(allocator, &repaired, byte);
        } else {
            try repaired.append(allocator, byte);
        }
    }
    return repaired.toOwnedSlice(allocator);
}

pub fn parseJsonWithRepair(allocator: std.mem.Allocator, json: []const u8) !ParsedValue {
    if (try tryParse(allocator, json)) |parsed| return parsed;

    const repaired = try repairJson(allocator, json);
    defer allocator.free(repaired);
    if (std.mem.eql(u8, repaired, json)) return error.InvalidJson;
    return (try tryParse(allocator, repaired)) orelse error.InvalidJson;
}

pub fn parseStreamingJson(allocator: std.mem.Allocator, partial_json: ?[]const u8) !ParsedValue {
    const json = partial_json orelse return parseEmptyObject(allocator);
    if (std.mem.trim(u8, json, " \t\r\n").len == 0) return parseEmptyObject(allocator);
    if (try tryParse(allocator, json)) |parsed| return parsed;

    const repaired = try repairJson(allocator, json);
    defer allocator.free(repaired);
    if (try tryParse(allocator, repaired)) |parsed| return parsed;

    var end = repaired.len;
    while (end > 0) : (end -= 1) {
        const candidate = try completePartialCandidate(allocator, repaired[0..end]) orelse continue;
        defer allocator.free(candidate);
        if (try tryParse(allocator, candidate)) |parsed| return parsed;
    }
    return parseEmptyObject(allocator);
}

fn tryParse(allocator: std.mem.Allocator, json: []const u8) !?ParsedValue {
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn parseEmptyObject(allocator: std.mem.Allocator) !ParsedValue {
    return std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
}

fn completePartialCandidate(allocator: std.mem.Allocator, prefix: []const u8) !?[]u8 {
    var closers: std.ArrayList(u8) = .empty;
    defer closers.deinit(allocator);
    var in_string = false;
    var escaped = false;

    for (prefix) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }

        switch (byte) {
            '"' => in_string = true,
            '{' => try closers.append(allocator, '}'),
            '[' => try closers.append(allocator, ']'),
            '}', ']' => {
                if (closers.items.len == 0 or closers.items[closers.items.len - 1] != byte) return null;
                _ = closers.pop();
            },
            else => {},
        }
    }

    var candidate: std.ArrayList(u8) = .empty;
    errdefer candidate.deinit(allocator);
    try candidate.appendSlice(allocator, prefix);
    if (in_string) {
        if (escaped) try candidate.append(allocator, '\\');
        try candidate.append(allocator, '"');
    }
    var closer_index = closers.items.len;
    while (closer_index > 0) {
        closer_index -= 1;
        try candidate.append(allocator, closers.items[closer_index]);
    }
    return try candidate.toOwnedSlice(allocator);
}

fn isValidEscape(byte: u8) bool {
    return switch (byte) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u' => true,
        else => false,
    };
}

fn isHexQuad(bytes: []const u8) bool {
    if (bytes.len != 4) return false;
    for (bytes) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn appendEscapedControl(allocator: std.mem.Allocator, output: *std.ArrayList(u8), byte: u8) !void {
    const simple = switch (byte) {
        '\x08' => "\\b",
        '\x0c' => "\\f",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        else => null,
    };
    if (simple) |escape| return output.appendSlice(allocator, escape);

    try output.appendSlice(allocator, "\\u00");
    const digits = "0123456789abcdef";
    try output.append(allocator, digits[byte >> 4]);
    try output.append(allocator, digits[byte & 0x0f]);
}

test "JSON repair escapes malformed string literal content" {
    const allocator = std.testing.allocator;
    const repaired = try repairJson(allocator, "{\"path\":\"C:\\temp\\bulb\",\"line\":\"a\nb\",\"bad\":\"\\q\"}");
    defer allocator.free(repaired);
    try std.testing.expectEqualStrings("{\"path\":\"C:\\temp\\bulb\",\"line\":\"a\\nb\",\"bad\":\"\\\\q\"}", repaired);

    var parsed = try parseJsonWithRepair(allocator, "{\"path\":\"C:\\Users\"}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("C:\\Users", parsed.value.object.get("path").?.string);
}

test "streaming JSON parser completes partial objects and strings" {
    const allocator = std.testing.allocator;
    var parsed = try parseStreamingJson(allocator, "{\"name\":\"bul");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("bul", parsed.value.object.get("name").?.string);

    var trailing = try parseStreamingJson(allocator, "{\"first\":1,\"second\":");
    defer trailing.deinit();
    try std.testing.expectEqual(@as(i64, 1), trailing.value.object.get("first").?.integer);
    try std.testing.expect(trailing.value.object.get("second") == null);
}

test "streaming JSON parser always returns an object fallback" {
    const allocator = std.testing.allocator;
    var empty = try parseStreamingJson(allocator, null);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.object.count());

    var malformed = try parseStreamingJson(allocator, "]}}");
    defer malformed.deinit();
    try std.testing.expectEqual(@as(usize, 0), malformed.value.object.count());
}
