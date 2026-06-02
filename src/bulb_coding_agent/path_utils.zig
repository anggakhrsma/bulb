const std = @import("std");
const paths = @import("paths.zig");

pub fn pathExists(io: std.Io, file_path: []const u8) bool {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch return false;
    return true;
}

pub fn expandPathAlloc(allocator: std.mem.Allocator, file_path: []const u8, home_dir: ?[]const u8) ![]u8 {
    return paths.normalizePathAlloc(allocator, file_path, .{
        .home_dir = home_dir,
        .normalize_unicode_spaces = true,
        .strip_at_prefix = true,
    });
}

pub fn resolveToCwdAlloc(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    cwd: []const u8,
    home_dir: ?[]const u8,
) ![]u8 {
    return paths.resolvePathAlloc(allocator, file_path, cwd, .{
        .home_dir = home_dir,
        .normalize_unicode_spaces = true,
        .strip_at_prefix = true,
    });
}

pub fn resolveReadPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    cwd: []const u8,
    home_dir: ?[]const u8,
) ![]u8 {
    const resolved = try resolveToCwdAlloc(allocator, file_path, cwd, home_dir);
    errdefer allocator.free(resolved);

    if (pathExists(io, resolved)) return resolved;

    const am_pm_variant = try tryMacOSScreenshotPathAlloc(allocator, resolved);
    defer allocator.free(am_pm_variant);
    if (!std.mem.eql(u8, am_pm_variant, resolved) and pathExists(io, am_pm_variant)) {
        allocator.free(resolved);
        return allocator.dupe(u8, am_pm_variant);
    }

    const nfd_variant = try tryNFDVariantAlloc(allocator, resolved);
    defer allocator.free(nfd_variant);
    if (!std.mem.eql(u8, nfd_variant, resolved) and pathExists(io, nfd_variant)) {
        allocator.free(resolved);
        return allocator.dupe(u8, nfd_variant);
    }

    const curly_variant = try tryCurlyQuoteVariantAlloc(allocator, resolved);
    defer allocator.free(curly_variant);
    if (!std.mem.eql(u8, curly_variant, resolved) and pathExists(io, curly_variant)) {
        allocator.free(resolved);
        return allocator.dupe(u8, curly_variant);
    }

    const nfd_curly_variant = try tryCurlyQuoteVariantAlloc(allocator, nfd_variant);
    defer allocator.free(nfd_curly_variant);
    if (!std.mem.eql(u8, nfd_curly_variant, resolved) and pathExists(io, nfd_curly_variant)) {
        allocator.free(resolved);
        return allocator.dupe(u8, nfd_curly_variant);
    }

    return resolved;
}

fn tryMacOSScreenshotPathAlloc(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < file_path.len) {
        if (index + 4 <= file_path.len and file_path[index] == ' ' and
            isAsciiLetter(file_path[index + 1], 'A', 'a') and
            isAsciiLetter(file_path[index + 2], 'M', 'm') and
            file_path[index + 3] == '.')
        {
            try output.appendSlice(allocator, "\u{202F}");
            try output.appendSlice(allocator, file_path[index + 1 .. index + 4]);
            index += 4;
            continue;
        }
        if (index + 4 <= file_path.len and file_path[index] == ' ' and
            isAsciiLetter(file_path[index + 1], 'P', 'p') and
            isAsciiLetter(file_path[index + 2], 'M', 'm') and
            file_path[index + 3] == '.')
        {
            try output.appendSlice(allocator, "\u{202F}");
            try output.appendSlice(allocator, file_path[index + 1 .. index + 4]);
            index += 4;
            continue;
        }
        try output.append(allocator, file_path[index]);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn tryNFDVariantAlloc(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < file_path.len) {
        const width = std.unicode.utf8ByteSequenceLength(file_path[index]) catch 1;
        if (index + width > file_path.len) {
            try output.append(allocator, file_path[index]);
            index += 1;
            continue;
        }
        const slice = file_path[index .. index + width];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            try output.appendSlice(allocator, slice);
            index += width;
            continue;
        };
        if (decomposedLatin1(codepoint)) |decomposed| {
            try output.appendSlice(allocator, decomposed);
        } else {
            try output.appendSlice(allocator, slice);
        }
        index += width;
    }

    return output.toOwnedSlice(allocator);
}

fn tryCurlyQuoteVariantAlloc(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    for (file_path) |byte| {
        if (byte == '\'') {
            try output.appendSlice(allocator, "\u{2019}");
        } else {
            try output.append(allocator, byte);
        }
    }

    return output.toOwnedSlice(allocator);
}

fn isAsciiLetter(actual: u8, upper: u8, lower: u8) bool {
    return actual == upper or actual == lower;
}

fn decomposedLatin1(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        0x00C0 => "A\u{0300}",
        0x00C1 => "A\u{0301}",
        0x00C8 => "E\u{0300}",
        0x00C9 => "E\u{0301}",
        0x00CC => "I\u{0300}",
        0x00CD => "I\u{0301}",
        0x00D2 => "O\u{0300}",
        0x00D3 => "O\u{0301}",
        0x00D9 => "U\u{0300}",
        0x00DA => "U\u{0301}",
        0x00E0 => "a\u{0300}",
        0x00E1 => "a\u{0301}",
        0x00E8 => "e\u{0300}",
        0x00E9 => "e\u{0301}",
        0x00EC => "i\u{0300}",
        0x00ED => "i\u{0301}",
        0x00F2 => "o\u{0300}",
        0x00F3 => "o\u{0301}",
        0x00F9 => "u\u{0300}",
        0x00FA => "u\u{0301}",
        else => null,
    };
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "expandPath expands home shortcuts, strips @, and normalizes unicode spaces" {
    const allocator = std.testing.allocator;
    const home = "/home/bulb";

    const home_only = try expandPathAlloc(allocator, "~", home);
    defer allocator.free(home_only);
    try std.testing.expectEqualStrings(home, home_only);

    const document = try expandPathAlloc(allocator, "~/Documents/file.txt", home);
    defer allocator.free(document);
    try std.testing.expectEqualStrings("/home/bulb/Documents/file.txt", document);

    const tilde_file = try expandPathAlloc(allocator, "~draft.md", home);
    defer allocator.free(tilde_file);
    try std.testing.expectEqualStrings("~draft.md", tilde_file);

    const at_tilde_file = try expandPathAlloc(allocator, "@~draft.md", home);
    defer allocator.free(at_tilde_file);
    try std.testing.expectEqualStrings("~draft.md", at_tilde_file);

    const unicode_space = try expandPathAlloc(allocator, "file\u{00A0}name.txt", home);
    defer allocator.free(unicode_space);
    try std.testing.expectEqualStrings("file name.txt", unicode_space);
}

test "resolveToCwd resolves absolute, relative, and tilde-prefixed literal names" {
    const allocator = std.testing.allocator;
    const cwd = "/tmp/pi-path-utils-cwd";

    const absolute = try resolveToCwdAlloc(allocator, "/tmp/absolute/path/file.txt", "/tmp/some/cwd", null);
    defer allocator.free(absolute);
    try std.testing.expectEqualStrings("/tmp/absolute/path/file.txt", absolute);

    const relative = try resolveToCwdAlloc(allocator, "relative/file.txt", "/some/cwd", null);
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("/some/cwd/relative/file.txt", relative);

    const tilde = try resolveToCwdAlloc(allocator, "~draft.md", cwd, "/home/bulb");
    defer allocator.free(tilde);
    try std.testing.expectEqualStrings("/tmp/pi-path-utils-cwd/~draft.md", tilde);

    const at_tilde = try resolveToCwdAlloc(allocator, "@~draft.md", cwd, "/home/bulb");
    defer allocator.free(at_tilde);
    try std.testing.expectEqualStrings("/tmp/pi-path-utils-cwd/~draft.md", at_tilde);
}

test "resolveReadPath handles existing files and macOS filename variants" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(temp_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "test-file.txt", .data = "content" });
    const existing = try resolveReadPathAlloc(allocator, io, "test-file.txt", temp_path, null);
    defer allocator.free(existing);
    const expected_existing = try std.fs.path.join(allocator, &.{ temp_path, "test-file.txt" });
    defer allocator.free(expected_existing);
    try std.testing.expectEqualStrings(expected_existing, existing);

    try tmp.dir.writeFile(io, .{ .sub_path = "filee\u{0301}.txt", .data = "content" });
    const nfd = try resolveReadPathAlloc(allocator, io, "file\u{00E9}.txt", temp_path, null);
    defer allocator.free(nfd);
    try std.testing.expect(std.mem.startsWith(u8, nfd, temp_path));
    try std.testing.expect(std.mem.indexOf(u8, nfd, "file") != null);
    try std.testing.expect(std.mem.endsWith(u8, nfd, ".txt"));

    try tmp.dir.writeFile(io, .{ .sub_path = "Capture d\u{2019}cran.txt", .data = "content" });
    const curly = try resolveReadPathAlloc(allocator, io, "Capture d'cran.txt", temp_path, null);
    defer allocator.free(curly);
    try std.testing.expect(std.mem.endsWith(u8, curly, "Capture d\u{2019}cran.txt"));

    try tmp.dir.writeFile(io, .{ .sub_path = "Screenshot 2024-01-01 at 10.00.00\u{202F}AM.png", .data = "content" });
    const am = try resolveReadPathAlloc(allocator, io, "Screenshot 2024-01-01 at 10.00.00 AM.png", temp_path, null);
    defer allocator.free(am);
    try std.testing.expect(std.mem.endsWith(u8, am, "Screenshot 2024-01-01 at 10.00.00\u{202F}AM.png"));

    try tmp.dir.writeFile(io, .{ .sub_path = "Screenshot 2024-01-01 at 10.00.00\u{202F}am.png", .data = "content" });
    const lower_am = try resolveReadPathAlloc(allocator, io, "Screenshot 2024-01-01 at 10.00.00 am.png", temp_path, null);
    defer allocator.free(lower_am);
    try std.testing.expect(std.mem.endsWith(u8, lower_am, "Screenshot 2024-01-01 at 10.00.00\u{202F}am.png"));
}

test "resolveReadPath handles combined straight quote and accented screenshot names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(temp_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "Capture d\u{2019}\u{00E9}cran.txt", .data = "content" });
    const resolved = try resolveReadPathAlloc(allocator, io, "Capture d'\u{00E9}cran.txt", temp_path, null);
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "Capture d\u{2019}\u{00E9}cran.txt"));
}
