const std = @import("std");

const ESC: u8 = 0x1b;

const whitespace_chars = " \t\r\n";
const punctuation_chars = "(){}[]<>.,;:'\"!?+-=*/\\|&%^$#@~`";

pub const Segment = struct {
    segment: []const u8,
    is_word_like: bool,
};

pub const WordNavigationOptions = struct {
    segment: ?*const fn (text: []const u8) []const Segment = null,
    is_atomic_segment: ?*const fn (segment: []const u8) bool = null,
};

pub fn findWordBackward(text: []const u8, cursor: usize, options: ?WordNavigationOptions) usize {
    if (cursor == 0) return 0;
    if (options) |opts| {
        if (opts.segment) |segment_fn| {
            const segments = segment_fn(text[0..@min(cursor, text.len)]);
            return findWordBackwardFromSegments(segments, opts.is_atomic_segment);
        }
    }
    return findWordBackwardDefault(text, @min(cursor, text.len));
}

pub fn findWordForward(text: []const u8, cursor: usize, options: ?WordNavigationOptions) usize {
    if (cursor >= text.len) return text.len;
    if (options) |opts| {
        if (opts.segment) |segment_fn| {
            const segments = segment_fn(text[@min(cursor, text.len)..]);
            return @min(text.len, cursor + findWordForwardFromSegments(segments, opts.is_atomic_segment));
        }
    }
    return findWordForwardDefault(text, @min(cursor, text.len));
}

fn findWordBackwardFromSegments(segments: []const Segment, is_atomic_segment: ?*const fn (segment: []const u8) bool) usize {
    var new_cursor: usize = totalLength(segments);
    var index: usize = segments.len;

    while (index > 0) {
        const segment = segments[index - 1];
        if (isAtomicSegment(is_atomic_segment, segment.segment)) break;
        if (!segment.is_word_like and isWhitespaceSegment(segment.segment)) {
            new_cursor -= segment.segment.len;
            index -= 1;
            continue;
        }
        break;
    }

    if (index == 0) return new_cursor;

    const last = segments[index - 1];
    if (isAtomicSegment(is_atomic_segment, last.segment)) {
        new_cursor -= last.segment.len;
    } else if (last.is_word_like) {
        new_cursor -= last.segment.len;
    } else {
        while (index > 0) {
            const segment = segments[index - 1];
            if (isAtomicSegment(is_atomic_segment, segment.segment) or segment.is_word_like or isWhitespaceSegment(segment.segment)) break;
            new_cursor -= segment.segment.len;
            index -= 1;
        }
    }

    return new_cursor;
}

fn findWordForwardFromSegments(segments: []const Segment, is_atomic_segment: ?*const fn (segment: []const u8) bool) usize {
    var new_cursor: usize = 0;
    var index: usize = 0;

    while (index < segments.len) {
        const segment = segments[index];
        if (isAtomicSegment(is_atomic_segment, segment.segment)) break;
        if (!segment.is_word_like and isWhitespaceSegment(segment.segment)) {
            new_cursor += segment.segment.len;
            index += 1;
            continue;
        }
        break;
    }

    if (index >= segments.len) return new_cursor;

    const next = segments[index];
    if (isAtomicSegment(is_atomic_segment, next.segment)) {
        new_cursor += next.segment.len;
    } else if (next.is_word_like) {
        new_cursor += next.segment.len;
    } else {
        while (index < segments.len) {
            const segment = segments[index];
            if (isAtomicSegment(is_atomic_segment, segment.segment) or segment.is_word_like or isWhitespaceSegment(segment.segment)) break;
            new_cursor += segment.segment.len;
            index += 1;
        }
    }

    return new_cursor;
}

fn findWordBackwardDefault(text: []const u8, cursor: usize) usize {
    var index = cursor;
    while (index > 0 and isAsciiWhitespaceByte(text[index - 1])) {
        index -= 1;
    }
    if (index == 0) return 0;

    const class = classifyBeforeCursor(text, index);
    switch (class) {
        .punctuation => {
            while (index > 0 and isAsciiPunctuationByte(text[index - 1])) {
                index -= 1;
            }
        },
        .word => {
            while (index > 0 and isAsciiWordByte(text[index - 1])) {
                index -= 1;
            }
        },
        .codepoint => {
            index = prevCodepointStart(text, index);
        },
    }

    return index;
}

fn findWordForwardDefault(text: []const u8, cursor: usize) usize {
    var index = cursor;
    while (index < text.len and isAsciiWhitespaceByte(text[index])) {
        index += 1;
    }
    if (index >= text.len) return text.len;

    const class = classifyAtCursor(text, index);
    switch (class) {
        .punctuation => {
            while (index < text.len and isAsciiPunctuationByte(text[index])) {
                index += 1;
            }
        },
        .word => {
            while (index < text.len and isAsciiWordByte(text[index])) {
                index += 1;
            }
        },
        .codepoint => {
            index = nextCodepointEnd(text, index);
        },
    }

    return index;
}

const SegmentClass = enum { punctuation, word, codepoint };

fn classifyBeforeCursor(text: []const u8, cursor: usize) SegmentClass {
    if (cursor == 0) return .word;
    const start = prevCodepointStart(text, cursor);
    if (start >= cursor) return .codepoint;
    if (cursor - start == 1 and isAsciiPunctuationByte(text[start])) return .punctuation;
    if (cursor - start == 1 and isAsciiWordByte(text[start])) return .word;
    return .codepoint;
}

fn classifyAtCursor(text: []const u8, cursor: usize) SegmentClass {
    if (cursor >= text.len) return .word;
    const byte = text[cursor];
    if (byte < 0x80) {
        if (isAsciiPunctuationByte(byte)) return .punctuation;
        return .word;
    }
    return .codepoint;
}

fn prevCodepointStart(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var start = cursor - 1;
    while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
    return start;
}

fn nextCodepointEnd(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    const first = text[cursor];
    const len: usize = std.unicode.utf8ByteSequenceLength(first) catch 1;
    return @min(text.len, cursor + len);
}

fn totalLength(segments: []const Segment) usize {
    var total: usize = 0;
    for (segments) |segment| total += segment.segment.len;
    return total;
}

fn isAtomicSegment(is_atomic_segment: ?*const fn (segment: []const u8) bool, segment: []const u8) bool {
    return is_atomic_segment != null and is_atomic_segment.?(segment);
}

fn isWhitespaceSegment(segment: []const u8) bool {
    return segment.len == 1 and isAsciiWhitespaceByte(segment[0]);
}

fn isAsciiWhitespaceByte(byte: u8) bool {
    return std.mem.indexOfScalar(u8, whitespace_chars, byte) != null;
}

fn isAsciiPunctuationByte(byte: u8) bool {
    return std.mem.indexOfScalar(u8, punctuation_chars, byte) != null;
}

fn isAsciiWordByte(byte: u8) bool {
    return byte < 0x80 and !isAsciiWhitespaceByte(byte) and !isAsciiPunctuationByte(byte);
}

test "findWordBackward" {
    try std.testing.expectEqual(@as(usize, 6), findWordBackward("hello world", 11, null));
    try std.testing.expectEqual(@as(usize, 0), findWordBackward("hello world", 6, null));

    const dotted = "foo.bar";
    try std.testing.expectEqual(@as(usize, 4), findWordBackward(dotted, 7, null));
    try std.testing.expectEqual(@as(usize, 3), findWordBackward(dotted, 4, null));
    try std.testing.expectEqual(@as(usize, 0), findWordBackward(dotted, 3, null));

    const path = "path/to/file";
    try std.testing.expectEqual(@as(usize, 8), findWordBackward(path, 12, null));
    try std.testing.expectEqual(@as(usize, 7), findWordBackward(path, 8, null));
    try std.testing.expectEqual(@as(usize, 5), findWordBackward(path, 7, null));
    try std.testing.expectEqual(@as(usize, 4), findWordBackward(path, 5, null));
    try std.testing.expectEqual(@as(usize, 0), findWordBackward(path, 4, null));
}

test "findWordForward" {
    try std.testing.expectEqual(@as(usize, 5), findWordForward("hello world", 0, null));
    try std.testing.expectEqual(@as(usize, 11), findWordForward("hello world", 5, null));

    const dotted = "foo.bar";
    try std.testing.expectEqual(@as(usize, 3), findWordForward(dotted, 0, null));
    try std.testing.expectEqual(@as(usize, 4), findWordForward(dotted, 3, null));
    try std.testing.expectEqual(@as(usize, 7), findWordForward(dotted, 4, null));

    const path = "path/to/file";
    try std.testing.expectEqual(@as(usize, 4), findWordForward(path, 0, null));
    try std.testing.expectEqual(@as(usize, 5), findWordForward(path, 4, null));
    try std.testing.expectEqual(@as(usize, 7), findWordForward(path, 5, null));
    try std.testing.expectEqual(@as(usize, 8), findWordForward(path, 7, null));
    try std.testing.expectEqual(@as(usize, 12), findWordForward(path, 8, null));
}

test "atomic segments" {
    const marker = "[paste #1 +5 lines]";
    const text = "hello [paste #1 +5 lines] world";

    const segments_full = [_]Segment{
        .{ .segment = "hello", .is_word_like = true },
        .{ .segment = " ", .is_word_like = false },
        .{ .segment = marker, .is_word_like = true },
        .{ .segment = " ", .is_word_like = false },
        .{ .segment = "world", .is_word_like = true },
    };

    const segments_before_26 = [_]Segment{
        .{ .segment = "hello", .is_word_like = true },
        .{ .segment = " ", .is_word_like = false },
        .{ .segment = marker, .is_word_like = true },
        .{ .segment = " ", .is_word_like = false },
    };

    const segments_after_6 = [_]Segment{
        .{ .segment = marker, .is_word_like = true },
        .{ .segment = " ", .is_word_like = false },
        .{ .segment = "world", .is_word_like = true },
    };

    const opts = WordNavigationOptions{
        .segment = struct {
            fn segment(input: []const u8) []const Segment {
                if (std.mem.eql(u8, input, text)) return &segments_full;
                if (std.mem.eql(u8, input, text[0..26])) return &segments_before_26;
                if (std.mem.eql(u8, input, text[6..])) return &segments_after_6;
                return &.{};
            }
        }.segment,
        .is_atomic_segment = struct {
            fn isAtomic(segment: []const u8) bool {
                return std.mem.eql(u8, segment, marker);
            }
        }.isAtomic,
    };

    try std.testing.expectEqual(@as(usize, 26), findWordBackward(text, text.len, opts));
    try std.testing.expectEqual(@as(usize, 6), findWordBackward(text, 26, opts));
    try std.testing.expectEqual(@as(usize, 6 + marker.len), findWordForward(text, 6, opts));
}
