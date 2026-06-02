const std = @import("std");
const builtin = @import("builtin");

pub const RuntimeInfo = struct {
    platform: []const u8 = platformName(),
    runtime: []const u8 = defaultRuntime(),
    arch: []const u8 = archName(),
};

pub fn getBulbUserAgentAlloc(
    allocator: std.mem.Allocator,
    version: []const u8,
    runtime_info: RuntimeInfo,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "bulb/{s} ({s}; {s}; {s})",
        .{ version, runtime_info.platform, runtime_info.runtime, runtime_info.arch },
    );
}

fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        else => @tagName(builtin.os.tag),
    };
}

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn defaultRuntime() []const u8 {
    return "zig/" ++ builtin.zig_version_string;
}

test "getBulbUserAgent formats the native service user agent" {
    const allocator = std.testing.allocator;
    const user_agent = try getBulbUserAgentAlloc(allocator, "1.2.3", .{
        .platform = "darwin",
        .runtime = "zig/0.16.0",
        .arch = "arm64",
    });
    defer allocator.free(user_agent);

    try std.testing.expectEqualStrings("bulb/1.2.3 (darwin; zig/0.16.0; arm64)", user_agent);
    try std.testing.expect(std.mem.startsWith(u8, user_agent, "bulb/"));
    try std.testing.expect(std.mem.indexOf(u8, user_agent, " (") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_agent, "; zig/") != null);
}

test "default runtime info exposes Zig-native platform and arch names" {
    const allocator = std.testing.allocator;
    const user_agent = try getBulbUserAgentAlloc(allocator, "0.0.0-dev", .{});
    defer allocator.free(user_agent);

    try std.testing.expect(std.mem.startsWith(u8, user_agent, "bulb/0.0.0-dev ("));
    try std.testing.expect(std.mem.indexOf(u8, user_agent, "zig/") != null);
    try std.testing.expect(std.mem.endsWith(u8, user_agent, ")"));
}
