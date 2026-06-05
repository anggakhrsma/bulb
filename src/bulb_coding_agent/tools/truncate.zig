const std = @import("std");

pub const DEFAULT_MAX_LINES: usize = 2000;
pub const DEFAULT_MAX_BYTES: usize = 50 * 1024;
pub const GREP_MAX_LINE_LENGTH: usize = 500;

pub const TruncationKind = enum {
    lines,
    bytes,
};

pub const TruncationOptions = struct {
    max_lines: usize = DEFAULT_MAX_LINES,
    max_bytes: usize = DEFAULT_MAX_BYTES,
};

pub const TruncationResult = struct {
    content: []u8,
    truncated: bool,
    truncated_by: ?TruncationKind,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool,
    first_line_exceeds_limit: bool,
    max_lines: usize,
    max_bytes: usize,

    pub fn deinit(self: *TruncationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const LineTruncationResult = struct {
    text: []u8,
    was_truncated: bool,

    pub fn deinit(self: *LineTruncationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn formatSizeAlloc(allocator: std.mem.Allocator, bytes: usize) ![]u8 {
    if (bytes < 1024) {
        return std.fmt.allocPrint(allocator, "{d}B", .{bytes});
    }
    if (bytes < 1024 * 1024) {
        return std.fmt.allocPrint(allocator, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    }
    return std.fmt.allocPrint(allocator, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
}

pub fn truncateHeadAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    options: TruncationOptions,
) !TruncationResult {
    const total_bytes = content.len;
    const lines = try splitLinesForCountingAlloc(allocator, content);
    defer allocator.free(lines);
    const total_lines = lines.len;

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return result(
            try allocator.dupe(u8, content),
            false,
            null,
            total_lines,
            total_bytes,
            total_lines,
            total_bytes,
            false,
            false,
            options,
        );
    }

    const first_line_bytes = if (lines.len > 0) lines[0].len else 0;
    if (first_line_bytes > options.max_bytes) {
        return result(
            try allocator.dupe(u8, ""),
            true,
            .bytes,
            total_lines,
            total_bytes,
            0,
            0,
            false,
            true,
            options,
        );
    }

    var output_lines: std.ArrayList([]const u8) = .empty;
    defer output_lines.deinit(allocator);
    var output_bytes_count: usize = 0;
    var truncated_by: TruncationKind = .lines;

    var index: usize = 0;
    while (index < lines.len and index < options.max_lines) : (index += 1) {
        const line = lines[index];
        const line_bytes = line.len + if (index > 0) @as(usize, 1) else 0;
        if (output_bytes_count + line_bytes > options.max_bytes) {
            truncated_by = .bytes;
            break;
        }
        try output_lines.append(allocator, line);
        output_bytes_count += line_bytes;
    }

    if (output_lines.items.len >= options.max_lines and output_bytes_count <= options.max_bytes) {
        truncated_by = .lines;
    }

    const output_content = try joinLinesAlloc(allocator, output_lines.items);
    return result(
        output_content,
        true,
        truncated_by,
        total_lines,
        total_bytes,
        output_lines.items.len,
        output_content.len,
        false,
        false,
        options,
    );
}

pub fn truncateTailAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    options: TruncationOptions,
) !TruncationResult {
    const total_bytes = content.len;
    const lines = try splitLinesForCountingAlloc(allocator, content);
    defer allocator.free(lines);
    const total_lines = lines.len;

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return result(
            try allocator.dupe(u8, content),
            false,
            null,
            total_lines,
            total_bytes,
            total_lines,
            total_bytes,
            false,
            false,
            options,
        );
    }

    var output_reversed: std.ArrayList([]const u8) = .empty;
    defer output_reversed.deinit(allocator);
    var partial_line: ?[]u8 = null;
    defer if (partial_line) |line| allocator.free(line);

    var output_bytes_count: usize = 0;
    var truncated_by: TruncationKind = .lines;
    var last_line_partial = false;

    var index = lines.len;
    while (index > 0 and output_reversed.items.len < options.max_lines) {
        index -= 1;
        const line = lines[index];
        const line_bytes = line.len + if (output_reversed.items.len > 0) @as(usize, 1) else 0;

        if (output_bytes_count + line_bytes > options.max_bytes) {
            truncated_by = .bytes;
            if (output_reversed.items.len == 0) {
                partial_line = try truncateStringToBytesFromEndAlloc(allocator, line, options.max_bytes);
                try output_reversed.append(allocator, partial_line.?);
                output_bytes_count = partial_line.?.len;
                last_line_partial = true;
            }
            break;
        }

        try output_reversed.append(allocator, line);
        output_bytes_count += line_bytes;
    }

    if (output_reversed.items.len >= options.max_lines and output_bytes_count <= options.max_bytes) {
        truncated_by = .lines;
    }

    const output_content = try joinReversedLinesAlloc(allocator, output_reversed.items);
    return result(
        output_content,
        true,
        truncated_by,
        total_lines,
        total_bytes,
        output_reversed.items.len,
        output_content.len,
        last_line_partial,
        false,
        options,
    );
}

pub fn truncateLineAlloc(
    allocator: std.mem.Allocator,
    line: []const u8,
    max_chars: usize,
) !LineTruncationResult {
    if (countUtf8Scalars(line) <= max_chars) {
        return .{
            .text = try allocator.dupe(u8, line),
            .was_truncated = false,
        };
    }

    const prefix = prefixByUtf8Scalars(line, max_chars);
    return .{
        .text = try std.fmt.allocPrint(allocator, "{s}... [truncated]", .{prefix}),
        .was_truncated = true,
    };
}

fn result(
    content: []u8,
    truncated_value: bool,
    truncated_by: ?TruncationKind,
    total_lines: usize,
    total_bytes: usize,
    output_lines: usize,
    output_bytes: usize,
    last_line_partial: bool,
    first_line_exceeds_limit: bool,
    options: TruncationOptions,
) TruncationResult {
    return .{
        .content = content,
        .truncated = truncated_value,
        .truncated_by = truncated_by,
        .total_lines = total_lines,
        .total_bytes = total_bytes,
        .output_lines = output_lines,
        .output_bytes = output_bytes,
        .last_line_partial = last_line_partial,
        .first_line_exceeds_limit = first_line_exceeds_limit,
        .max_lines = options.max_lines,
        .max_bytes = options.max_bytes,
    };
}

fn splitLinesForCountingAlloc(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    if (content.len == 0) return lines.toOwnedSlice(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, start, '\n')) |newline| {
        try lines.append(allocator, content[start..newline]);
        start = newline + 1;
    }
    if (start < content.len) {
        try lines.append(allocator, content[start..]);
    }

    return lines.toOwnedSlice(allocator);
}

fn joinLinesAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");

    var total_len: usize = lines.len - 1;
    for (lines) |line| total_len += line.len;

    const output = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (lines, 0..) |line, index| {
        if (index > 0) {
            output[offset] = '\n';
            offset += 1;
        }
        @memcpy(output[offset .. offset + line.len], line);
        offset += line.len;
    }
    return output;
}

fn joinReversedLinesAlloc(allocator: std.mem.Allocator, lines_reversed: []const []const u8) ![]u8 {
    if (lines_reversed.len == 0) return allocator.dupe(u8, "");

    var total_len: usize = lines_reversed.len - 1;
    for (lines_reversed) |line| total_len += line.len;

    const output = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    var remaining = lines_reversed.len;
    while (remaining > 0) {
        remaining -= 1;
        if (remaining != lines_reversed.len - 1) {
            output[offset] = '\n';
            offset += 1;
        }
        const line = lines_reversed[remaining];
        @memcpy(output[offset .. offset + line.len], line);
        offset += line.len;
    }
    return output;
}

fn truncateStringToBytesFromEndAlloc(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    if (text.len <= max_bytes) return allocator.dupe(u8, text);

    var start = text.len - max_bytes;
    while (start < text.len and (text[start] & 0xc0) == 0x80) {
        start += 1;
    }
    return allocator.dupe(u8, text[start..]);
}

fn countUtf8Scalars(text: []const u8) usize {
    var index: usize = 0;
    var count: usize = 0;
    while (index < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index += if (index + width <= text.len) width else 1;
        count += 1;
    }
    return count;
}

fn prefixByUtf8Scalars(text: []const u8, max_chars: usize) []const u8 {
    var index: usize = 0;
    var count: usize = 0;
    while (index < text.len and count < max_chars) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        index += if (index + width <= text.len) width else 1;
        count += 1;
    }
    return text[0..index];
}

test "formatSize ports Pi byte display thresholds" {
    const allocator = std.testing.allocator;

    const bytes = try formatSizeAlloc(allocator, 512);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("512B", bytes);

    const kb = try formatSizeAlloc(allocator, 1536);
    defer allocator.free(kb);
    try std.testing.expectEqualStrings("1.5KB", kb);

    const mb = try formatSizeAlloc(allocator, 2 * 1024 * 1024 + 512 * 1024);
    defer allocator.free(mb);
    try std.testing.expectEqualStrings("2.5MB", mb);
}

test "truncateHead preserves fitting content and ignores trailing newline for line count" {
    const allocator = std.testing.allocator;
    var truncated = try truncateHeadAlloc(allocator, "alpha\nbeta\n", .{});
    defer truncated.deinit(allocator);

    try std.testing.expect(!truncated.truncated);
    try std.testing.expectEqual(@as(?TruncationKind, null), truncated.truncated_by);
    try std.testing.expectEqual(@as(usize, 2), truncated.total_lines);
    try std.testing.expectEqualStrings("alpha\nbeta\n", truncated.content);
}

test "truncateHead keeps complete lines when the line limit wins" {
    const allocator = std.testing.allocator;
    var truncated = try truncateHeadAlloc(allocator, "one\ntwo\nthree\nfour", .{
        .max_lines = 3,
        .max_bytes = 1024,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.lines, truncated.truncated_by.?);
    try std.testing.expectEqual(@as(usize, 4), truncated.total_lines);
    try std.testing.expectEqual(@as(usize, 3), truncated.output_lines);
    try std.testing.expectEqualStrings("one\ntwo\nthree", truncated.content);
}

test "truncateHead keeps complete lines when the byte limit wins" {
    const allocator = std.testing.allocator;
    var truncated = try truncateHeadAlloc(allocator, "aaa\nbbb\nccc", .{
        .max_lines = 10,
        .max_bytes = 7,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
    try std.testing.expectEqual(@as(usize, 3), truncated.total_lines);
    try std.testing.expectEqual(@as(usize, 2), truncated.output_lines);
    try std.testing.expectEqual(@as(usize, 7), truncated.output_bytes);
    try std.testing.expectEqualStrings("aaa\nbbb", truncated.content);
}

test "truncateHead reports first line over byte limit without partial output" {
    const allocator = std.testing.allocator;
    var truncated = try truncateHeadAlloc(allocator, "abcdef\nnext", .{
        .max_lines = 10,
        .max_bytes = 5,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
    try std.testing.expect(truncated.first_line_exceeds_limit);
    try std.testing.expectEqual(@as(usize, 0), truncated.output_lines);
    try std.testing.expectEqualStrings("", truncated.content);
}

test "truncateTail keeps the last complete lines when the line limit wins" {
    const allocator = std.testing.allocator;
    var truncated = try truncateTailAlloc(allocator, "one\ntwo\nthree\nfour", .{
        .max_lines = 2,
        .max_bytes = 1024,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.lines, truncated.truncated_by.?);
    try std.testing.expectEqual(@as(usize, 4), truncated.total_lines);
    try std.testing.expectEqual(@as(usize, 2), truncated.output_lines);
    try std.testing.expectEqualStrings("three\nfour", truncated.content);
}

test "truncateTail keeps the last complete lines when the byte limit wins" {
    const allocator = std.testing.allocator;
    var truncated = try truncateTailAlloc(allocator, "aaa\nbbbb\ncc", .{
        .max_lines = 10,
        .max_bytes = 7,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
    try std.testing.expect(!truncated.last_line_partial);
    try std.testing.expectEqualStrings("bbbb\ncc", truncated.content);
}

test "truncateTail takes the end of an oversized last line on a UTF-8 boundary" {
    const allocator = std.testing.allocator;
    var ascii = try truncateTailAlloc(allocator, "abcdef", .{
        .max_lines = 10,
        .max_bytes = 3,
    });
    defer ascii.deinit(allocator);
    try std.testing.expect(ascii.last_line_partial);
    try std.testing.expectEqualStrings("def", ascii.content);

    var unicode = try truncateTailAlloc(allocator, "a🙂b", .{
        .max_lines = 10,
        .max_bytes = 5,
    });
    defer unicode.deinit(allocator);
    try std.testing.expect(unicode.last_line_partial);
    try std.testing.expectEqualStrings("🙂b", unicode.content);
}

test "truncateLine adds the Pi grep truncation suffix" {
    const allocator = std.testing.allocator;

    var fitting = try truncateLineAlloc(allocator, "short", GREP_MAX_LINE_LENGTH);
    defer fitting.deinit(allocator);
    try std.testing.expect(!fitting.was_truncated);
    try std.testing.expectEqualStrings("short", fitting.text);

    var truncated = try truncateLineAlloc(allocator, "abcdef", 3);
    defer truncated.deinit(allocator);
    try std.testing.expect(truncated.was_truncated);
    try std.testing.expectEqualStrings("abc... [truncated]", truncated.text);
}
