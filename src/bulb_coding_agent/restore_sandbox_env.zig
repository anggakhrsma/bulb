const std = @import("std");

pub const RestoreSandboxEnvOptions = struct {
    os_tag: std.Target.Os.Tag = @import("builtin").os.tag,
    environ_path: []const u8 = "/proc/self/environ",
};

pub fn restoreSandboxEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
) !bool {
    return restoreSandboxEnvWithOptions(allocator, io, env, .{});
}

pub fn restoreSandboxEnvWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    options: RestoreSandboxEnvOptions,
) !bool {
    if (env.count() > 0) return false;
    if (options.os_tag != .linux) return false;

    const data = std.Io.Dir.cwd().readFileAlloc(io, options.environ_path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(data);

    var restored = false;
    var iterator = std.mem.splitScalar(u8, data, 0);
    while (iterator.next()) |entry| {
        if (entry.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (separator == 0) continue;
        try env.put(entry[0..separator], entry[separator + 1 ..]);
        restored = true;
    }
    return restored;
}

test "restore sandbox env does nothing when env already has entries" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("RESTORE_SANDBOX_ENV_TEST", "1");

    const restored = try restoreSandboxEnvWithOptions(allocator, std.testing.io, &env, .{
        .os_tag = .linux,
        .environ_path = "/definitely/missing",
    });

    try std.testing.expect(!restored);
    try std.testing.expectEqual(@as(usize, 1), env.count());
    try std.testing.expectEqualStrings("1", env.get("RESTORE_SANDBOX_ENV_TEST").?);
}

test "restore sandbox env is linux only" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const restored = try restoreSandboxEnvWithOptions(allocator, std.testing.io, &env, .{
        .os_tag = .macos,
        .environ_path = "/definitely/missing",
    });

    try std.testing.expect(!restored);
    try std.testing.expectEqual(@as(usize, 0), env.count());
}

test "restore sandbox env recovers entries from proc environ format" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "environ",
        .data = "FOO=bar\x00BAZ=qux\x00NO_EQUALS\x00=INVALID\x00EMPTY=\x00",
    });

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const environ_path = try tmp.dir.realPathFileAlloc(std.testing.io, "environ", allocator);
    defer allocator.free(environ_path);

    const restored = try restoreSandboxEnvWithOptions(allocator, std.testing.io, &env, .{
        .os_tag = .linux,
        .environ_path = environ_path,
    });

    try std.testing.expect(restored);
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
    try std.testing.expectEqualStrings("qux", env.get("BAZ").?);
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
    try std.testing.expectEqual(@as(usize, 3), env.count());
}
