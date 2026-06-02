const std = @import("std");
const builtin = @import("builtin");

pub const PathInputOptions = struct {
    trim: bool = false,
    expand_tilde: bool = true,
    home_dir: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    strip_at_prefix: bool = false,
    normalize_unicode_spaces: bool = false,
};

pub fn canonicalizePathAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch {
        return allocator.dupe(u8, path);
    };
    defer allocator.free(real);
    return allocator.dupe(u8, real);
}

pub fn isLocalPath(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const remote_prefixes = [_][]const u8{
        "npm:",
        "git:",
        "github:",
        "http:",
        "https:",
        "ssh:",
    };
    for (remote_prefixes) |prefix| {
        if (std.mem.startsWith(u8, trimmed, prefix)) return false;
    }
    return true;
}

pub fn normalizePathAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: PathInputOptions,
) ![]u8 {
    const trimmed = if (options.trim) std.mem.trim(u8, input, " \t\r\n") else input;
    var normalized = if (options.normalize_unicode_spaces)
        try normalizeUnicodeSpacesAlloc(allocator, trimmed)
    else
        try allocator.dupe(u8, trimmed);
    errdefer allocator.free(normalized);

    if (options.strip_at_prefix and std.mem.startsWith(u8, normalized, "@")) {
        const stripped = try allocator.dupe(u8, normalized[1..]);
        allocator.free(normalized);
        normalized = stripped;
    }

    if (options.expand_tilde) {
        if (std.mem.eql(u8, normalized, "~")) {
            const home = homeDir(options);
            allocator.free(normalized);
            return allocator.dupe(u8, home);
        }
        if (std.mem.startsWith(u8, normalized, "~/") or
            (builtin.os.tag == .windows and std.mem.startsWith(u8, normalized, "~\\")))
        {
            const home = homeDir(options);
            const joined = try std.fs.path.join(allocator, &.{ home, normalized[2..] });
            allocator.free(normalized);
            return joined;
        }
    }

    if (std.mem.startsWith(u8, normalized, "file://")) {
        const decoded = try fileUrlToPathAlloc(allocator, normalized);
        allocator.free(normalized);
        return decoded;
    }

    return normalized;
}

pub fn resolvePathAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    base_dir: []const u8,
    options: PathInputOptions,
) ![]u8 {
    const normalized = try normalizePathAlloc(allocator, input, options);
    defer allocator.free(normalized);
    const normalized_base_dir = try normalizePathAlloc(allocator, base_dir, .{});
    defer allocator.free(normalized_base_dir);

    if (std.fs.path.isAbsolute(normalized)) {
        return std.fs.path.resolve(allocator, &.{normalized});
    }
    return std.fs.path.resolve(allocator, &.{ normalized_base_dir, normalized });
}

pub fn getCwdRelativePathAlloc(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    cwd: []const u8,
) !?[]u8 {
    const resolved_cwd = try resolvePathAlloc(allocator, cwd, ".", .{});
    defer allocator.free(resolved_cwd);
    const resolved_path = try resolvePathAlloc(allocator, file_path, resolved_cwd, .{});
    defer allocator.free(resolved_path);
    const relative = try std.fs.path.relative(allocator, ".", null, resolved_cwd, resolved_path);
    errdefer allocator.free(relative);

    const inside_cwd =
        relative.len == 0 or
        (!std.mem.eql(u8, relative, "..") and
            !std.mem.startsWith(u8, relative, ".." ++ std.fs.path.sep_str) and
            !std.fs.path.isAbsolute(relative));

    if (!inside_cwd) {
        allocator.free(relative);
        return null;
    }

    if (relative.len == 0) {
        allocator.free(relative);
        return try allocator.dupe(u8, ".");
    }
    return relative;
}

pub fn formatPathRelativeToCwdOrAbsoluteAlloc(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    cwd: []const u8,
) ![]u8 {
    const absolute_path = try resolvePathAlloc(allocator, file_path, cwd, .{});
    defer allocator.free(absolute_path);

    if (try getCwdRelativePathAlloc(allocator, absolute_path, cwd)) |relative| {
        defer allocator.free(relative);
        return slashPathAlloc(allocator, relative);
    }
    return slashPathAlloc(allocator, absolute_path);
}

pub fn markPathIgnoredByCloudSync(allocator: std.mem.Allocator, io: std.Io, path: []const u8) void {
    switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            const attrs = [_][]const u8{ "com.dropbox.ignored", "com.apple.fileprovider.ignore#P" };
            for (attrs) |attr| {
                runIgnore(allocator, io, &.{ "xattr", "-w", attr, "1", path });
            }
        },
        .linux => runIgnore(allocator, io, &.{ "setfattr", "-n", "user.com.dropbox.ignored", "-v", "1", path }),
        else => {},
    }
}

fn homeDir(options: PathInputOptions) []const u8 {
    if (options.home_dir) |home| return home;
    if (options.env) |env| {
        if (env.get("HOME")) |home| return home;
        if (env.get("USERPROFILE")) |home| return home;
    }
    return ".";
}

fn normalizeUnicodeSpacesAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const width = std.unicode.utf8ByteSequenceLength(input[index]) catch 1;
        if (index + width > input.len) {
            try output.append(allocator, input[index]);
            index += 1;
            continue;
        }
        const slice = input[index .. index + width];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            try output.appendSlice(allocator, slice);
            index += width;
            continue;
        };
        if (isUnicodeSpace(codepoint)) {
            try output.append(allocator, ' ');
        } else {
            try output.appendSlice(allocator, slice);
        }
        index += width;
    }

    return output.toOwnedSlice(allocator);
}

fn isUnicodeSpace(codepoint: u21) bool {
    return codepoint == 0x00A0 or
        (codepoint >= 0x2000 and codepoint <= 0x200A) or
        codepoint == 0x202F or
        codepoint == 0x205F or
        codepoint == 0x3000;
}

const FileUrlError = error{ InvalidFileUrl, NonLocalFileUrl };

fn fileUrlToPathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const uri = std.Uri.parse(value) catch return error.InvalidFileUrl;
    if (!std.mem.eql(u8, uri.scheme, "file")) return error.InvalidFileUrl;
    if (uri.host) |host| {
        if (!host.isEmpty() and !std.mem.eql(u8, host.percent_encoded, "localhost")) {
            return error.NonLocalFileUrl;
        }
    }

    const decoded = try percentDecodeAlloc(allocator, uri.path.percent_encoded);
    errdefer allocator.free(decoded);
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidFileUrl;

    if (builtin.os.tag == .windows and decoded.len >= 3 and decoded[0] == '/' and std.ascii.isAlphabetic(decoded[1]) and decoded[2] == ':') {
        const trimmed = try allocator.dupe(u8, decoded[1..]);
        allocator.free(decoded);
        return trimmed;
    }
    return decoded;
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '%') {
            try output.append(allocator, input[index]);
            index += 1;
            continue;
        }
        if (index + 2 >= input.len) return error.InvalidFileUrl;
        const hi = hexValue(input[index + 1]) orelse return error.InvalidFileUrl;
        const lo = hexValue(input[index + 2]) orelse return error.InvalidFileUrl;
        try output.append(allocator, (hi << 4) | lo);
        index += 3;
    }

    return output.toOwnedSlice(allocator);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn slashPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') {
        for (result) |*byte| {
            if (byte.* == std.fs.path.sep) byte.* = '/';
        }
    }
    return result;
}

fn runIgnore(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) void {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .nothing,
        .stderr_limit = .nothing,
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "canonicalizePath returns real paths and falls back for missing targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(temp_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "hello" });
    const file_path = try std.fs.path.join(allocator, &.{ temp_path, "file.txt" });
    defer allocator.free(file_path);
    const canonical = try canonicalizePathAlloc(allocator, io, file_path);
    defer allocator.free(canonical);
    try std.testing.expect(std.fs.path.isAbsolute(canonical));
    try std.testing.expect(std.mem.endsWith(u8, canonical, "file.txt"));

    const missing_path = try std.fs.path.join(allocator, &.{ temp_path, "no-such-file" });
    defer allocator.free(missing_path);
    const missing = try canonicalizePathAlloc(allocator, io, missing_path);
    defer allocator.free(missing);
    try std.testing.expectEqualStrings(missing_path, missing);
}

test "canonicalizePath resolves symlinks and leaves dangling links raw" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(temp_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "hello" });
    try tmp.dir.symLink(io, "target.txt", "link.txt", .{});

    const target_path = try std.fs.path.join(allocator, &.{ temp_path, "target.txt" });
    defer allocator.free(target_path);
    const link_path = try std.fs.path.join(allocator, &.{ temp_path, "link.txt" });
    defer allocator.free(link_path);

    const target_canonical = try canonicalizePathAlloc(allocator, io, target_path);
    defer allocator.free(target_canonical);
    const link_canonical = try canonicalizePathAlloc(allocator, io, link_path);
    defer allocator.free(link_canonical);
    try std.testing.expectEqualStrings(target_canonical, link_canonical);

    try tmp.dir.symLink(io, "missing.txt", "dangling.txt", .{});
    const dangling_path = try std.fs.path.join(allocator, &.{ temp_path, "dangling.txt" });
    defer allocator.free(dangling_path);
    const dangling = try canonicalizePathAlloc(allocator, io, dangling_path);
    defer allocator.free(dangling);
    try std.testing.expectEqualStrings(dangling_path, dangling);
}

test "normalizePath expands only home tilde shortcuts and accepts file URLs" {
    const allocator = std.testing.allocator;
    const home = "/home/bulb";

    const tilde = try normalizePathAlloc(allocator, "~", .{ .home_dir = home });
    defer allocator.free(tilde);
    try std.testing.expectEqualStrings(home, tilde);

    const home_file = try normalizePathAlloc(allocator, "~/file.txt", .{ .home_dir = home });
    defer allocator.free(home_file);
    try std.testing.expectEqualStrings("/home/bulb/file.txt", home_file);

    const literal = try normalizePathAlloc(allocator, "~draft.md", .{ .home_dir = home });
    defer allocator.free(literal);
    try std.testing.expectEqualStrings("~draft.md", literal);

    const file_url = try normalizePathAlloc(allocator, "file:///tmp/file%20with%20spaces.txt", .{});
    defer allocator.free(file_url);
    try std.testing.expectEqualStrings("/tmp/file with spaces.txt", file_url);

    try std.testing.expectError(error.InvalidFileUrl, normalizePathAlloc(allocator, "file:///%E0%A4%A", .{}));
}

test "resolvePath and cwd-relative helpers preserve Pi path semantics" {
    const allocator = std.testing.allocator;
    const cwd = "/tmp/pi-paths-cwd";

    const resolved = try resolvePathAlloc(allocator, "subdir/file.txt", cwd, .{});
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("/tmp/pi-paths-cwd/subdir/file.txt", resolved);

    const dot_name = try getCwdRelativePathAlloc(allocator, "/tmp/pi-paths-cwd/..config/AGENTS.md", cwd);
    defer allocator.free(dot_name.?);
    try std.testing.expectEqualStrings("..config/AGENTS.md", dot_name.?);

    const parent = try getCwdRelativePathAlloc(allocator, "/tmp/AGENTS.md", cwd);
    try std.testing.expectEqual(@as(?[]u8, null), parent);

    const formatted = try formatPathRelativeToCwdOrAbsoluteAlloc(allocator, "/tmp/pi-paths-cwd/subdir/file.txt", cwd);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("subdir/file.txt", formatted);
}

test "isLocalPath rejects remote package protocols but keeps file URLs local" {
    try std.testing.expect(isLocalPath("my-package"));
    try std.testing.expect(isLocalPath("./foo"));
    try std.testing.expect(isLocalPath("file:///tmp/foo"));
    try std.testing.expect(!isLocalPath("npm:package"));
    try std.testing.expect(!isLocalPath("git://repo"));
    try std.testing.expect(!isLocalPath("https://example.com"));
}
