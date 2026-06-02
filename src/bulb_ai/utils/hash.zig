const std = @import("std");

pub fn shortHash(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var h1: u32 = 0xdeadbeef;
    var h2: u32 = 0x41c6ce57;
    var view = try std.unicode.Utf8View.init(text);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xffff) {
            hashCodeUnit(&h1, &h2, @intCast(codepoint));
        } else {
            const offset = codepoint - 0x10000;
            hashCodeUnit(&h1, &h2, @intCast(0xd800 + (offset >> 10)));
            hashCodeUnit(&h1, &h2, @intCast(0xdc00 + (offset & 0x3ff)));
        }
    }

    h1 = (h1 ^ (h1 >> 16)) *% 2_246_822_507 ^ (h2 ^ (h2 >> 13)) *% 3_266_489_909;
    h2 = (h2 ^ (h2 >> 16)) *% 2_246_822_507 ^ (h1 ^ (h1 >> 13)) *% 3_266_489_909;

    var h2_buffer: [7]u8 = undefined;
    var h1_buffer: [7]u8 = undefined;
    const h2_text = formatBase36(&h2_buffer, h2);
    const h1_text = formatBase36(&h1_buffer, h1);
    const result = try allocator.alloc(u8, h2_text.len + h1_text.len);
    @memcpy(result[0..h2_text.len], h2_text);
    @memcpy(result[h2_text.len..], h1_text);
    return result;
}

fn hashCodeUnit(h1: *u32, h2: *u32, code_unit: u16) void {
    h1.* = (h1.* ^ code_unit) *% 2_654_435_761;
    h2.* = (h2.* ^ code_unit) *% 1_597_334_677;
}

fn formatBase36(buffer: *[7]u8, value: u32) []const u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var remaining = value;
    var index: usize = buffer.len;
    while (true) {
        index -= 1;
        buffer[index] = digits[remaining % 36];
        remaining /= 36;
        if (remaining == 0) break;
    }
    return buffer[index..];
}

test "short hash matches Pi JavaScript hash snapshots" {
    const allocator = std.testing.allocator;
    const hello = try shortHash(allocator, "hello");
    defer allocator.free(hello);
    try std.testing.expectEqualStrings("1h6qa0qrowduu", hello);

    const unicode = try shortHash(allocator, "Bulb \xF0\x9F\x92\xA1");
    defer allocator.free(unicode);
    try std.testing.expectEqualStrings("1mx4qcsgqrue7", unicode);
}
