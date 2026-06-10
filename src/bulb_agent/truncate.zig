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
    const lines = try splitLinesAlloc(allocator, content, .keep_trailing_empty);
    defer allocator.free(lines);
    const total_lines = lines.len;

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return makeResult(
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
        return makeResult(
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
    return makeResult(
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
    const lines = try splitLinesAlloc(allocator, content, .drop_single_trailing_empty);
    defer allocator.free(lines);
    const total_lines = lines.len;

    if (total_lines <= options.max_lines and total_bytes <= options.max_bytes) {
        return makeResult(
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
    return makeResult(
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

fn makeResult(
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

const TrailingEmptyMode = enum {
    keep_trailing_empty,
    drop_single_trailing_empty,
};

fn splitLinesAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    trailing_mode: TrailingEmptyMode,
) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, start, '\n')) |newline| {
        try lines.append(allocator, content[start..newline]);
        start = newline + 1;
    }
    try lines.append(allocator, content[start..]);

    if (trailing_mode == .drop_single_trailing_empty and lines.items.len > 1 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
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

fn bufferTailAlloc(allocator: std.mem.Allocator, content: []const u8, max_bytes: usize) ![]u8 {
    if (content.len <= max_bytes) return allocator.dupe(u8, content);

    var start = content.len - max_bytes;
    while (start < content.len and (content[start] & 0xc0) == 0x80) {
        start += 1;
    }
    return allocator.dupe(u8, content[start..]);
}

fn assertMatchesBufferTail(
    allocator: std.mem.Allocator,
    input: []const u8,
    max_byte_values: []const usize,
) !void {
    for (max_byte_values) |max_bytes| {
        var result = try truncateTailAlloc(allocator, input, .{
            .max_bytes = max_bytes,
            .max_lines = 10,
        });
        defer result.deinit(allocator);

        const expected = try bufferTailAlloc(allocator, input, max_bytes);
        defer allocator.free(expected);

        try std.testing.expectEqualStrings(expected, result.content);
        try std.testing.expect(result.output_bytes <= max_bytes);
    }
}

fn sampledByteLimitsAlloc(allocator: std.mem.Allocator, input: []const u8) ![]usize {
    const total_bytes = input.len;
    const raw_candidates = [_]isize{
        0,
        1,
        2,
        3,
        4,
        5,
        8,
        @as(isize, @intCast(total_bytes / 2)) - 1,
        @as(isize, @intCast(total_bytes / 2)),
        @as(isize, @intCast(total_bytes / 2)) + 1,
        @as(isize, @intCast(total_bytes)) - 8,
        @as(isize, @intCast(total_bytes)) - 5,
        @as(isize, @intCast(total_bytes)) - 4,
        @as(isize, @intCast(total_bytes)) - 3,
        @as(isize, @intCast(total_bytes)) - 2,
        @as(isize, @intCast(total_bytes)) - 1,
        @as(isize, @intCast(total_bytes)),
        @as(isize, @intCast(total_bytes)) + 1,
        @as(isize, @intCast(total_bytes)) + 4,
    };

    var values: std.ArrayList(usize) = .empty;
    defer values.deinit(allocator);

    for (raw_candidates) |candidate| {
        if (candidate < 0) continue;
        const value: usize = @intCast(candidate);
        if (std.mem.indexOfScalar(usize, values.items, value) == null) {
            try values.append(allocator, value);
        }
    }
    std.mem.sort(usize, values.items, {}, std.sort.asc(usize));
    return values.toOwnedSlice(allocator);
}

fn checkExhaustiveTailSamples(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    depth: usize,
    alphabet: []const []const u8,
) !void {
    const limits = try sampledByteLimitsAlloc(allocator, prefix);
    defer allocator.free(limits);
    try assertMatchesBufferTail(allocator, prefix, limits);

    if (depth == 0) return;

    for (alphabet) |character| {
        const next = try std.mem.concat(allocator, u8, &.{ prefix, character });
        defer allocator.free(next);
        try checkExhaustiveTailSamples(allocator, next, depth - 1, alphabet);
    }
}

test "agent truncate utilities count UTF-8 bytes" {
    const allocator = std.testing.allocator;

    var truncated = try truncateHeadAlloc(allocator, "aé🙂\nb", .{
        .max_bytes = 100,
        .max_lines = 10,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(!truncated.truncated);
    try std.testing.expectEqual(@as(usize, 9), truncated.total_bytes);
    try std.testing.expectEqual(@as(usize, 9), truncated.output_bytes);
}

test "agent truncateHead obeys UTF-8 byte limits without partial lines" {
    const allocator = std.testing.allocator;

    var truncated = try truncateHeadAlloc(allocator, "éé\nabc", .{
        .max_bytes = 4,
        .max_lines = 10,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
    try std.testing.expectEqual(@as(usize, 4), truncated.output_bytes);
    try std.testing.expect(!truncated.first_line_exceeds_limit);
    try std.testing.expectEqualStrings("éé", truncated.content);
}

test "agent truncateHead reports first line byte overflow" {
    const allocator = std.testing.allocator;

    var truncated = try truncateHeadAlloc(allocator, "éé\nabc", .{
        .max_bytes = 3,
        .max_lines = 10,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
    try std.testing.expect(truncated.first_line_exceeds_limit);
    try std.testing.expectEqualStrings("", truncated.content);
}

test "agent truncateTail keeps UTF-8 boundaries for a partial final line" {
    const allocator = std.testing.allocator;

    var truncated = try truncateTailAlloc(allocator, "aé🙂b", .{
        .max_bytes = 5,
        .max_lines = 10,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
    try std.testing.expect(truncated.last_line_partial);
    try std.testing.expectEqual(@as(usize, 5), truncated.output_bytes);
    try std.testing.expectEqualStrings("🙂b", truncated.content);
}

test "agent truncateTail trims an oversized single line with trailing newline" {
    const allocator = std.testing.allocator;

    const input = try allocator.alloc(u8, 300_001);
    defer allocator.free(input);
    @memset(input[0..300_000], 'X');
    input[300_000] = '\n';

    var truncated = try truncateTailAlloc(allocator, input, .{
        .max_bytes = 1024,
        .max_lines = 100,
    });
    defer truncated.deinit(allocator);

    const expected = try allocator.alloc(u8, 1024);
    defer allocator.free(expected);
    @memset(expected, 'X');

    try std.testing.expectEqualStrings(expected, truncated.content);
    try std.testing.expectEqual(@as(usize, 1024), truncated.output_bytes);
    try std.testing.expectEqual(@as(usize, 1), truncated.output_lines);
    try std.testing.expect(truncated.last_line_partial);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
}

test "agent truncateTail drops an oversized trailing character that cannot fit" {
    const allocator = std.testing.allocator;

    var truncated = try truncateTailAlloc(allocator, "abc🙂", .{
        .max_bytes = 3,
        .max_lines = 10,
    });
    defer truncated.deinit(allocator);

    try std.testing.expect(truncated.truncated);
    try std.testing.expectEqual(TruncationKind.bytes, truncated.truncated_by.?);
    try std.testing.expect(truncated.last_line_partial);
    try std.testing.expectEqual(@as(usize, 0), truncated.output_bytes);
    try std.testing.expectEqualStrings("", truncated.content);
}

test "agent truncateTail matches byte-buffer tail semantics across UTF-8 cases" {
    const allocator = std.testing.allocator;

    const examples = [_][]const u8{
        "a",
        "é",
        "aé🙂b",
        "🙂🙂",
        "👩‍💻",
    };
    for (examples) |input| {
        var limits = std.ArrayList(usize).empty;
        defer limits.deinit(allocator);

        var max_bytes: usize = 0;
        while (max_bytes <= input.len + 4) : (max_bytes += 1) {
            try limits.append(allocator, max_bytes);
        }
        try assertMatchesBufferTail(allocator, input, limits.items);
    }
}

test "agent truncateTail matches deterministic UTF-8 fuzz samples" {
    const allocator = std.testing.allocator;

    const alphabet = [_][]const u8{
        "a",
        "\x7f",
        "\u{80}",
        "é",
        "\u{7ff}",
        "\u{800}",
        "中",
        "\u{d7ff}",
        "\u{e000}",
        "\u{ffff}",
        "🙂",
    };
    try checkExhaustiveTailSamples(allocator, "", 2, &alphabet);

    var seed: u32 = 0x12345678;
    var case_index: usize = 0;
    while (case_index < 250) : (case_index += 1) {
        seed = seed *% 1664525 +% 1013904223;
        const length = @as(usize, @intCast(seed % 80));

        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(allocator);

        var char_index: usize = 0;
        while (char_index < length) : (char_index += 1) {
            seed = seed *% 1664525 +% 1013904223;
            try input.appendSlice(allocator, alphabet[@as(usize, @intCast(seed % alphabet.len))]);
        }

        const limits = try sampledByteLimitsAlloc(allocator, input.items);
        defer allocator.free(limits);
        try assertMatchesBufferTail(allocator, input.items, limits);
    }
}

test "agent truncate helpers expose size formatting and grep line truncation" {
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

    var fitting = try truncateLineAlloc(allocator, "short", GREP_MAX_LINE_LENGTH);
    defer fitting.deinit(allocator);
    try std.testing.expect(!fitting.was_truncated);
    try std.testing.expectEqualStrings("short", fitting.text);

    var truncated = try truncateLineAlloc(allocator, "abcdef", 3);
    defer truncated.deinit(allocator);
    try std.testing.expect(truncated.was_truncated);
    try std.testing.expectEqualStrings("abc... [truncated]", truncated.text);
}
