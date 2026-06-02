const std = @import("std");

pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var sanitized: std.ArrayList(u8) = .empty;
    errdefer sanitized.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (isWtf8SurrogateAt(text, index)) {
            index += 3;
            continue;
        }
        try sanitized.append(allocator, text[index]);
        index += 1;
    }
    return sanitized.toOwnedSlice(allocator);
}

fn isWtf8SurrogateAt(text: []const u8, index: usize) bool {
    if (index + 2 >= text.len) return false;
    return text[index] == 0xed and
        text[index + 1] >= 0xa0 and text[index + 1] <= 0xbf and
        text[index + 2] >= 0x80 and text[index + 2] <= 0xbf;
}

test "surrogate sanitization preserves valid Unicode and removes WTF-8 surrogates" {
    const allocator = std.testing.allocator;
    const text = "Hello \xF0\x9F\x99\x88 \xED\xA0\xBD World \xED\xB0\x80";
    const sanitized = try sanitizeSurrogates(allocator, text);
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("Hello \xF0\x9F\x99\x88  World ", sanitized);
}

test "surrogate sanitization leaves ordinary malformed bytes untouched" {
    const allocator = std.testing.allocator;
    const sanitized = try sanitizeSurrogates(allocator, "before \xff after");
    defer allocator.free(sanitized);
    try std.testing.expectEqualSlices(u8, "before \xff after", sanitized);
}
