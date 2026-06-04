// Portions derived from ansi-regex and strip-ansi.
// MIT License. Copyright (c) Sindre Sorhus.
const std = @import("std");

/// Strip the OSC and CSI sequences recognized by Pi's `strip-ansi` compatible
/// helper while preserving incomplete or unrelated control strings.
pub fn stripAnsiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0x1b) == null and
        std.mem.indexOfScalar(u8, value, 0x9b) == null)
    {
        return allocator.dupe(u8, value);
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < value.len) {
        if (matchAnsiLength(value, index)) |length| {
            index += length;
            continue;
        }
        try output.append(allocator, value[index]);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn matchAnsiLength(value: []const u8, start: usize) ?usize {
    if (start >= value.len) return null;

    if (value[start] == 0x1b and start + 1 < value.len and value[start + 1] == ']') {
        if (matchOscLength(value, start)) |length| return length;
    }

    return matchCsiLength(value, start);
}

fn matchOscLength(value: []const u8, start: usize) ?usize {
    var index = start + 2;
    while (index < value.len) : (index += 1) {
        if (value[index] == 0x07 or value[index] == 0x9c) {
            return index + 1 - start;
        }
        if (value[index] == 0x1b and index + 1 < value.len and value[index + 1] == '\\') {
            return index + 2 - start;
        }
    }
    return null;
}

fn matchCsiLength(value: []const u8, start: usize) ?usize {
    if (value[start] != 0x1b and value[start] != 0x9b) return null;
    if (start + 1 >= value.len) return null;

    var scan_end = start + 1;
    while (scan_end < value.len and isCsiCandidateByte(value[scan_end])) : (scan_end += 1) {}

    var candidate_end = scan_end;
    while (candidate_end > start + 1) : (candidate_end -= 1) {
        const final = value[candidate_end - 1];
        if (!isCsiFinal(final)) continue;
        if (isCsiBody(value[start + 1 .. candidate_end - 1])) {
            return candidate_end - start;
        }
    }
    return null;
}

fn isCsiBody(body: []const u8) bool {
    var index: usize = 0;
    while (index < body.len and isCsiPrefix(body[index])) : (index += 1) {}
    if (index == body.len) return true;
    if (!std.ascii.isDigit(body[index])) return false;

    const first_digits = consumeDigits(body, index);
    if (first_digits == 0 or first_digits > 4) return false;
    index += first_digits;

    while (index < body.len) {
        if (body[index] != ';' and body[index] != ':') return false;
        index += 1;
        const digits = consumeDigits(body, index);
        if (digits > 4) return false;
        index += digits;
    }

    return true;
}

fn consumeDigits(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {}
    return index - start;
}

fn isCsiCandidateByte(byte: u8) bool {
    return isCsiPrefix(byte) or byte == ':' or std.ascii.isDigit(byte) or isCsiFinal(byte);
}

fn isCsiPrefix(byte: u8) bool {
    return switch (byte) {
        '[', ']', '(', ')', '#', ';', '?' => true,
        else => false,
    };
}

fn isCsiFinal(byte: u8) bool {
    return std.ascii.isDigit(byte) or
        (byte >= 'A' and byte <= 'P') or
        (byte >= 'R' and byte <= 'T') or
        byte == 'Z' or
        byte == 'c' or
        (byte >= 'f' and byte <= 'n') or
        (byte >= 'q' and byte <= 'u') or
        byte == 'y' or
        byte == '=' or
        byte == '>' or
        byte == '<' or
        byte == '~';
}

fn expectStripped(input: []const u8, expected: []const u8) !void {
    const stripped = try stripAnsiAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings(expected, stripped);
}

fn expectReferenceCompatible(input: []const u8) !void {
    const allocator = std.testing.allocator;
    const expected = try referenceStripAnsiAlloc(allocator, input);
    defer allocator.free(expected);
    const actual = try stripAnsiAlloc(allocator, input);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn referenceStripAnsiAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < value.len) {
        if (referenceMatchLength(value, index)) |length| {
            index += length;
        } else {
            try output.append(allocator, value[index]);
            index += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

fn referenceMatchLength(value: []const u8, start: usize) ?usize {
    if (start >= value.len) return null;
    if (value[start] == 0x1b and start + 1 < value.len and value[start + 1] == ']') {
        if (matchOscLength(value, start)) |length| return length;
    }
    if (value[start] != 0x1b and value[start] != 0x9b) return null;

    var best: ?usize = null;
    var end = start + 2;
    while (end <= value.len) : (end += 1) {
        if (!referenceIsFinal(value[end - 1])) continue;
        if (referenceIsBody(value[start + 1 .. end - 1])) {
            best = end - start;
        }
    }
    return best;
}

fn referenceIsBody(body: []const u8) bool {
    var index: usize = 0;
    while (index < body.len and std.mem.indexOfScalar(u8, "[]()#;?", body[index]) != null) : (index += 1) {}
    if (index == body.len) return true;

    var digits: usize = 0;
    while (index < body.len and std.ascii.isDigit(body[index])) : (index += 1) {
        digits += 1;
    }
    if (digits == 0 or digits > 4) return false;

    while (index < body.len) {
        if (body[index] != ';' and body[index] != ':') return false;
        index += 1;
        digits = 0;
        while (index < body.len and std.ascii.isDigit(body[index])) : (index += 1) {
            digits += 1;
        }
        if (digits > 4) return false;
    }
    return true;
}

fn referenceIsFinal(byte: u8) bool {
    return std.mem.indexOfScalar(
        u8,
        "0123456789ABCDEFGHIJKLMNOPRSTZcfghijklmnqrstuy=><~",
        byte,
    ) != null;
}

test "stripAnsi strips common ANSI sequences used in tool output" {
    try expectStripped(
        "a\x1b[31mred\x1b[0m\x1b]8;;https://example.com\x07link\x1b]8;;\x07z",
        "aredlinkz",
    );
}

test "stripAnsi preserves incomplete OSC and unrelated control strings" {
    try expectStripped("plain", "plain");
    try expectStripped("a\x1b]unterminated", "anterminated");
    try expectStripped("a\x1bPabc\x1b\\z", "aabc\x1b\\z");
    try expectStripped("a\x9dabc\x9cz", "a\x9dabc\x9cz");
}

test "stripAnsi handles C1 CSI and single-byte ESC sequences" {
    try expectStripped("a\x9b31mred", "ared");
    try expectStripped("\x1bcdone", "done");

    var code: u8 = 'g';
    while (code <= 'm') : (code += 1) {
        var input = [_]u8{ 0x1b, code, 'o', 'k' };
        try expectStripped(&input, "ok");
    }
    code = 'r';
    while (code <= 't') : (code += 1) {
        var input = [_]u8{ 0x1b, code, 'o', 'k' };
        try expectStripped(&input, "ok");
    }
}

test "stripAnsi matches representative strip-ansi compatibility inputs" {
    const inputs = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "a\x1b[31mred\x1b[0mz", .expected = "aredz" },
        .{ .input = "a\x1b]8;;https://example.com\x07link\x1b]8;;\x07z", .expected = "alinkz" },
        .{ .input = "a\x1b]funterminated", .expected = "aunterminated" },
        .{ .input = "a\x1b^abc\x07z", .expected = "a\x1b^abc\x07z" },
        .{ .input = "a\x1b_abc\x9cz", .expected = "a\x1b_abc\x9cz" },
        .{ .input = "a\x90abc\x9cz", .expected = "a\x90abc\x9cz" },
        .{ .input = "a\x1b(0x", .expected = "ax" },
        .{ .input = "a\x1b*0x", .expected = "a\x1b*0x" },
        .{ .input = "a\x1b+c", .expected = "a\x1b+c" },
        .{ .input = "a\x1b/0x", .expected = "a\x1b/0x" },
        .{ .input = "a\x1b\\ok", .expected = "a\x1b\\ok" },
    };

    for (inputs) |entry| {
        try expectStripped(entry.input, entry.expected);
    }
}

test "stripAnsi matches strip-ansi for generated compatibility inputs" {
    const inputs = [_][]const u8{
        "plain",
        "a\x1b[31mred\x1b[0mz",
        "a\x1b]8;;https://example.com\x07link\x1b]8;;\x07z",
        "a\x1b]unterminated",
        "a\x1b]funterminated",
        "a\x1bPabc\x1b\\z",
        "a\x1b^abc\x07z",
        "a\x1b_abc\x9cz",
        "a\x90abc\x9cz",
        "a\x9dabc\x9cz",
        "a\x9b31mred",
        "a\x1b(0x",
        "a\x1b*0x",
        "a\x1b+c",
        "a\x1b/0x",
        "a\x1bcok",
        "a\x1b\\ok",
    };
    for (inputs) |input| try expectReferenceCompatible(input);

    const chars = [_]u8{
        'a',  'f',  '0',  '1',  ';',  ':',  '[', ']', '(', ')', '#', '?', 'm', 'P', '_', '\\',
        0x07, 0x1b, 0x9b, 0x9c, 0x90, 0x9d,
    };
    for (chars) |char| {
        const esc_input = [_]u8{ 'x', 0x1b, char, 'y' };
        try expectReferenceCompatible(&esc_input);
        const c1_input = [_]u8{ 'x', 0x9b, char, 'y' };
        try expectReferenceCompatible(&c1_input);

        var index: usize = 0;
        while (index < chars.len) : (index += 3) {
            const pair_input = [_]u8{ 'x', 0x1b, char, chars[index], 'y' };
            try expectReferenceCompatible(&pair_input);
        }
    }
}
