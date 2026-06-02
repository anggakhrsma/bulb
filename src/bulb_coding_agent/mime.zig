const std = @import("std");

pub const image_type_sniff_bytes: usize = 4100;
const png_signature = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

pub fn detectSupportedImageMimeType(buffer: []const u8) ?[]const u8 {
    if (startsWith(buffer, &[_]u8{ 0xff, 0xd8, 0xff })) {
        return if (buffer.len > 3 and buffer[3] == 0xf7) null else "image/jpeg";
    }
    if (startsWith(buffer, &png_signature)) {
        return if (isPng(buffer) and !isAnimatedPng(buffer)) "image/png" else null;
    }
    if (startsWithAscii(buffer, 0, "GIF")) {
        return "image/gif";
    }
    if (startsWithAscii(buffer, 0, "RIFF") and startsWithAscii(buffer, 8, "WEBP")) {
        return "image/webp";
    }
    return null;
}

pub fn detectSupportedImageMimeTypeFromFile(io: std.Io, file_path: []const u8) !?[]const u8 {
    var buffer: [image_type_sniff_bytes]u8 = undefined;
    const bytes = try std.Io.Dir.cwd().readFile(io, file_path, &buffer);
    return detectSupportedImageMimeType(bytes);
}

fn isPng(buffer: []const u8) bool {
    return buffer.len >= 16 and readUint32BE(buffer, png_signature.len) == 13 and startsWithAscii(buffer, 12, "IHDR");
}

fn isAnimatedPng(buffer: []const u8) bool {
    var offset: usize = png_signature.len;
    while (offset + 8 <= buffer.len) {
        const chunk_length = readUint32BE(buffer, offset);
        const chunk_type_offset = offset + 4;
        if (startsWithAscii(buffer, chunk_type_offset, "acTL")) return true;
        if (startsWithAscii(buffer, chunk_type_offset, "IDAT")) return false;

        const next_offset = offset + 8 + @as(usize, chunk_length) + 4;
        if (next_offset <= offset or next_offset > buffer.len) return false;
        offset = next_offset;
    }
    return false;
}

fn readUint32BE(buffer: []const u8, offset: usize) u32 {
    return (@as(u32, byteAt(buffer, offset)) << 24) |
        (@as(u32, byteAt(buffer, offset + 1)) << 16) |
        (@as(u32, byteAt(buffer, offset + 2)) << 8) |
        @as(u32, byteAt(buffer, offset + 3));
}

fn byteAt(buffer: []const u8, offset: usize) u8 {
    return if (offset < buffer.len) buffer[offset] else 0;
}

fn startsWith(buffer: []const u8, bytes: []const u8) bool {
    return buffer.len >= bytes.len and std.mem.eql(u8, buffer[0..bytes.len], bytes);
}

fn startsWithAscii(buffer: []const u8, offset: usize, text: []const u8) bool {
    return offset + text.len <= buffer.len and std.mem.eql(u8, buffer[offset .. offset + text.len], text);
}

fn expectMime(expected: []const u8, actual: ?[]const u8) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualStrings(expected, actual.?);
}

test "detectSupportedImageMimeType detects supported image headers" {
    try expectMime("image/jpeg", detectSupportedImageMimeType(&[_]u8{ 0xff, 0xd8, 0xff, 0xe0 }));
    try expectMime("image/jpeg", detectSupportedImageMimeType(&[_]u8{ 0xff, 0xd8, 0xff }));
    try expectMime("image/gif", detectSupportedImageMimeType("GIF89a"));
    try expectMime("image/webp", detectSupportedImageMimeType("RIFF\x00\x00\x00\x00WEBP"));

    const png = try pngBytesAlloc(std.testing.allocator, false);
    defer std.testing.allocator.free(png);
    try expectMime("image/png", detectSupportedImageMimeType(png));
}

test "detectSupportedImageMimeType rejects unsupported or ambiguous image headers" {
    try std.testing.expect(detectSupportedImageMimeType(&[_]u8{ 0xff, 0xd8, 0xff, 0xf7 }) == null);
    try std.testing.expect(detectSupportedImageMimeType("not an image") == null);

    var invalid_png = std.ArrayList(u8).empty;
    defer invalid_png.deinit(std.testing.allocator);
    try invalid_png.appendSlice(std.testing.allocator, &png_signature);
    try appendU32BE(&invalid_png, std.testing.allocator, 12);
    try invalid_png.appendSlice(std.testing.allocator, "IHDR");
    try std.testing.expect(detectSupportedImageMimeType(invalid_png.items) == null);

    const apng = try pngBytesAlloc(std.testing.allocator, true);
    defer std.testing.allocator.free(apng);
    try std.testing.expect(detectSupportedImageMimeType(apng) == null);
}

test "detectSupportedImageMimeTypeFromFile reads the sniffing prefix" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = try pngBytesAlloc(allocator, false);
    defer allocator.free(png);
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = png });

    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const file_path = try std.fs.path.join(allocator, &.{ tmp_path, "image.png" });
    defer allocator.free(file_path);

    try expectMime("image/png", try detectSupportedImageMimeTypeFromFile(io, file_path));
}

fn pngBytesAlloc(allocator: std.mem.Allocator, animated: bool) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(allocator);

    try bytes.appendSlice(allocator, &png_signature);
    try appendPngChunk(&bytes, allocator, 13, "IHDR", 13);
    if (animated) {
        try appendPngChunk(&bytes, allocator, 8, "acTL", 8);
    } else {
        try appendPngChunk(&bytes, allocator, 0, "IDAT", 0);
    }

    return bytes.toOwnedSlice(allocator);
}

fn appendPngChunk(
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    length: u32,
    chunk_type: []const u8,
    data_len: usize,
) !void {
    std.debug.assert(chunk_type.len == 4);
    try appendU32BE(bytes, allocator, length);
    try bytes.appendSlice(allocator, chunk_type);
    var index: usize = 0;
    while (index < data_len) : (index += 1) {
        try bytes.append(allocator, 0);
    }
    index = 0;
    while (index < 4) : (index += 1) {
        try bytes.append(allocator, 0);
    }
}

fn appendU32BE(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try bytes.append(allocator, @as(u8, @intCast((value >> 24) & 0xff)));
    try bytes.append(allocator, @as(u8, @intCast((value >> 16) & 0xff)));
    try bytes.append(allocator, @as(u8, @intCast((value >> 8) & 0xff)));
    try bytes.append(allocator, @as(u8, @intCast(value & 0xff)));
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}
