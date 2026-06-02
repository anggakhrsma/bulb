const std = @import("std");

pub fn visibleWidth(input: []const u8) usize {
    var index: usize = 0;
    var width: usize = 0;
    var regional_indicator_pending = false;
    var join_next = false;

    while (index < input.len) {
        if (input[index] == 0x1b and index + 1 < input.len and input[index + 1] == '[') {
            index += 2;
            while (index < input.len) {
                const byte = input[index];
                index += 1;
                if (byte >= 0x40 and byte <= 0x7e) break;
            }
            continue;
        }

        const byte = input[index];
        if (byte == '\t') {
            index += 1;
            width += 3;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            index += 1;
            continue;
        }

        if (byte < 0x80) {
            index += 1;
            width += 1;
            continue;
        }

        const sequence_length = std.unicode.utf8ByteSequenceLength(byte) catch {
            index += 1;
            continue;
        };
        const codepoint_len: usize = @intCast(sequence_length);
        if (index + codepoint_len > input.len) break;
        const codepoint = std.unicode.utf8Decode(input[index..][0..codepoint_len]) catch {
            index += 1;
            continue;
        };
        index += codepoint_len;

        if (codepoint == 0x200d) {
            join_next = true;
            continue;
        }
        if (isZeroWidth(codepoint)) continue;
        if (join_next) {
            join_next = false;
            continue;
        }
        if (isRegionalIndicator(codepoint)) {
            if (regional_indicator_pending) {
                regional_indicator_pending = false;
            } else {
                regional_indicator_pending = true;
                width += 2;
            }
            continue;
        }
        regional_indicator_pending = false;
        width += codepointWidth(codepoint);
    }

    return width;
}

fn codepointWidth(codepoint: u21) usize {
    if (isEmoji(codepoint) or isWide(codepoint)) return 2;
    return 1;
}

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

fn isEmoji(codepoint: u21) bool {
    return (codepoint >= 0x1f000 and codepoint <= 0x1fbff) or
        (codepoint >= 0x2600 and codepoint <= 0x27bf) or
        (codepoint >= 0x2b50 and codepoint <= 0x2b55);
}

fn isWide(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115f) or
        (codepoint >= 0x2329 and codepoint <= 0x232a) or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd);
}

fn isZeroWidth(codepoint: u21) bool {
    return codepoint == 0xfe0f or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f) or
        (codepoint >= 0x1f3fb and codepoint <= 0x1f3ff);
}

// Ported subset of packages/tui/test/truncate-to-width.test.ts.
test "visible width counts tabs inline and skips ANSI inline" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\t\x1b[31m界\x1b[0m"));
}

// Ported subset of packages/tui/test/truncate-to-width.test.ts.
test "visible width keeps Thai and Lao AM clusters at their normal cell width" {
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("ำ"));
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("ຳ"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("กำ"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("ກຳ"));
}

// Ported subset of packages/tui/test/regression-regional-indicator-width.test.ts.
test "visible width treats regional indicator graphemes as full width" {
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("🇨"));
    try std.testing.expectEqual(@as(usize, 10), visibleWidth("      - 🇨"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("🇨🇳"));
}

// Ported subset of packages/tui/test/regression-regional-indicator-width.test.ts.
test "visible width keeps streaming emoji intermediates stable" {
    const samples = [_][]const u8{ "👍", "👍🏻", "✅", "⚡", "⚡️", "👨", "👨‍💻", "🏳️‍🌈" };
    for (samples) |sample| {
        try std.testing.expectEqual(@as(usize, 2), visibleWidth(sample));
    }
}
