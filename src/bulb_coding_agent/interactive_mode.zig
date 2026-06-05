const std = @import("std");
const config = @import("config.zig");
const session_manager_mod = @import("session_manager.zig");

pub const FormatResumeCommandSession = struct {
    persisted: bool = true,
    session_file: ?[]const u8 = null,
    session_id: []const u8,
    session_dir: []const u8 = "",
    uses_default_session_dir: bool = true,
};

pub fn formatResumeCommandAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: FormatResumeCommandSession,
    stdout_is_tty: bool,
) !?[]u8 {
    if (!stdout_is_tty) return null;
    if (!session.persisted) return null;

    const session_file = session.session_file orelse return null;
    std.Io.Dir.cwd().access(io, session_file, .{}) catch return null;

    var command: std.Io.Writer.Allocating = .init(allocator);
    errdefer command.deinit();

    try command.writer.writeAll(config.command_name);
    if (!session.uses_default_session_dir) {
        const quoted_session_dir = try quoteIfNeededAlloc(allocator, session.session_dir);
        defer allocator.free(quoted_session_dir);
        try command.writer.print(" --session-dir {s}", .{quoted_session_dir});
    }
    try command.writer.print(" --session {s}", .{session.session_id});
    return try command.toOwnedSlice();
}

pub fn formatResumeCommandFromManagerAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_manager: *const session_manager_mod.SessionManager,
    stdout_is_tty: bool,
    agent_dir: []const u8,
) !?[]u8 {
    const uses_default_session_dir = try session_manager.usesDefaultSessionDir(allocator, io, agent_dir);
    return formatResumeCommandAlloc(allocator, io, .{
        .persisted = session_manager.isPersisted(),
        .session_file = session_manager.getSessionFile(),
        .session_id = session_manager.getSessionId(),
        .session_dir = session_manager.getSessionDir(),
        .uses_default_session_dir = uses_default_session_dir,
    }, stdout_is_tty);
}

fn quoteIfNeededAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len > 0 and isShellSafeUnquoted(value)) {
        return allocator.dupe(u8, value);
    }

    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try quoted.appendSlice(allocator, "'\\''");
        } else {
            try quoted.append(allocator, byte);
        }
    }
    try quoted.append(allocator, '\'');
    return quoted.toOwnedSlice(allocator);
}

fn isShellSafeUnquoted(value: []const u8) bool {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '_', '-', '.', '/', '~', ':', '@' => continue,
            else => return false,
        }
    }
    return true;
}

const TempSessionFile = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    path: []u8,

    fn deinit(self: *TempSessionFile) void {
        self.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn createTempSessionFile(allocator: std.mem.Allocator) !TempSessionFile {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const session_file = try std.fs.path.join(allocator, &.{ tmp_path, "session.jsonl" });
    errdefer allocator.free(session_file);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = session_file,
        .data = "\n",
        .flags = .{ .read = true, .truncate = true },
    });
    return .{
        .allocator = allocator,
        .tmp = tmp,
        .path = session_file,
    };
}

fn expectResumeCommand(session: FormatResumeCommandSession, stdout_is_tty: bool, expected: ?[]const u8) !void {
    const actual = try formatResumeCommandAlloc(std.testing.allocator, std.testing.io, session, stdout_is_tty);
    defer if (actual) |value| std.testing.allocator.free(value);

    if (expected) |expected_value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(expected_value, actual.?);
    } else {
        try std.testing.expectEqual(null, actual);
    }
}

// Ported from packages/coding-agent/test/format-resume-command.test.ts.
test "formatResumeCommand returns session resume command for default session dirs" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
    }, true, "bulb --session test-session");
}

test "formatResumeCommand includes and quotes non-default session dirs" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom-bulb-sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir /tmp/custom-bulb-sessions --session test-session");

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom bulb sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir '/tmp/custom bulb sessions' --session test-session");

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom bulb's sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir '/tmp/custom bulb'\\''s sessions' --session test-session");
}

test "formatResumeCommand returns null for non-TTY in-memory and missing session files" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
    }, false, null);

    try expectResumeCommand(.{
        .persisted = false,
        .session_file = session_file.path,
        .session_id = "test-session",
    }, true, null);

    try expectResumeCommand(.{
        .session_file = "/tmp/bulb-missing-session.jsonl",
        .session_id = "test-session",
    }, true, null);

    try expectResumeCommand(.{
        .session_file = null,
        .session_id = "test-session",
    }, true, null);
}
