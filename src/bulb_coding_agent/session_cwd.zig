const std = @import("std");

pub const SessionCwdIssue = struct {
    session_file: ?[]const u8,
    session_cwd: []const u8,
    fallback_cwd: []const u8,
};

pub const SessionCwdSource = struct {
    ptr: *const anyopaque,
    get_cwd_fn: *const fn (*const anyopaque) []const u8,
    get_session_file_fn: *const fn (*const anyopaque) ?[]const u8,

    pub fn getCwd(self: SessionCwdSource) []const u8 {
        return self.get_cwd_fn(self.ptr);
    }

    pub fn getSessionFile(self: SessionCwdSource) ?[]const u8 {
        return self.get_session_file_fn(self.ptr);
    }
};

pub const MissingSessionCwdError = struct {
    issue: SessionCwdIssue,

    pub fn messageAlloc(self: MissingSessionCwdError, allocator: std.mem.Allocator) ![]u8 {
        return formatMissingSessionCwdErrorAlloc(allocator, self.issue);
    }
};

pub const AssertError = error{MissingSessionCwd};

pub fn getMissingSessionCwdIssue(
    io: std.Io,
    session_manager: SessionCwdSource,
    fallback_cwd: []const u8,
) ?SessionCwdIssue {
    const session_file = session_manager.getSessionFile() orelse return null;
    const session_cwd = session_manager.getCwd();
    if (session_cwd.len == 0 or pathExists(io, session_cwd)) return null;

    return .{
        .session_file = session_file,
        .session_cwd = session_cwd,
        .fallback_cwd = fallback_cwd,
    };
}

pub fn formatMissingSessionCwdErrorAlloc(
    allocator: std.mem.Allocator,
    issue: SessionCwdIssue,
) ![]u8 {
    if (issue.session_file) |session_file| {
        return std.fmt.allocPrint(
            allocator,
            "Stored session working directory does not exist: {s}\nSession file: {s}\nCurrent working directory: {s}",
            .{ issue.session_cwd, session_file, issue.fallback_cwd },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Stored session working directory does not exist: {s}\nCurrent working directory: {s}",
        .{ issue.session_cwd, issue.fallback_cwd },
    );
}

pub fn formatMissingSessionCwdPromptAlloc(
    allocator: std.mem.Allocator,
    issue: SessionCwdIssue,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "cwd from session file does not exist\n{s}\n\ncontinue in current cwd\n{s}",
        .{ issue.session_cwd, issue.fallback_cwd },
    );
}

pub fn assertSessionCwdExists(
    io: std.Io,
    session_manager: SessionCwdSource,
    fallback_cwd: []const u8,
) AssertError!void {
    if (getMissingSessionCwdIssue(io, session_manager, fallback_cwd) != null) {
        return error.MissingSessionCwd;
    }
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const TestSessionManager = struct {
    cwd: []const u8,
    session_file: ?[]const u8,

    fn source(self: *const TestSessionManager) SessionCwdSource {
        return .{
            .ptr = self,
            .get_cwd_fn = getCwd,
            .get_session_file_fn = getSessionFile,
        };
    }

    fn getCwd(ptr: *const anyopaque) []const u8 {
        const self: *const TestSessionManager = @ptrCast(@alignCast(ptr));
        return self.cwd;
    }

    fn getSessionFile(ptr: *const anyopaque) ?[]const u8 {
        const self: *const TestSessionManager = @ptrCast(@alignCast(ptr));
        return self.session_file;
    }
};

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "detects missing session cwd from persisted sessions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fallback_cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(fallback_cwd);
    const missing_cwd = try std.fs.path.join(allocator, &.{ fallback_cwd, "does-not-exist" });
    defer allocator.free(missing_cwd);
    const session_file = try std.fs.path.join(allocator, &.{ fallback_cwd, "session.jsonl" });
    defer allocator.free(session_file);

    const session_manager: TestSessionManager = .{
        .cwd = missing_cwd,
        .session_file = session_file,
    };
    const issue = getMissingSessionCwdIssue(std.testing.io, session_manager.source(), fallback_cwd).?;

    try std.testing.expectEqualStrings(session_file, issue.session_file.?);
    try std.testing.expectEqualStrings(missing_cwd, issue.session_cwd);
    try std.testing.expectEqualStrings(fallback_cwd, issue.fallback_cwd);
}

test "supports overriding the effective cwd when opening a session" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fallback_cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(fallback_cwd);
    const session_file = try std.fs.path.join(allocator, &.{ fallback_cwd, "session.jsonl" });
    defer allocator.free(session_file);

    const session_manager: TestSessionManager = .{
        .cwd = fallback_cwd,
        .session_file = session_file,
    };
    try std.testing.expectEqual(
        null,
        getMissingSessionCwdIssue(std.testing.io, session_manager.source(), fallback_cwd),
    );
}

test "throws a controlled error before runtime creation when the stored cwd is missing" {
    const RuntimeHarness = struct {
        fn create(
            io: std.Io,
            session_manager: SessionCwdSource,
            fallback_cwd: []const u8,
            create_runtime_called: *bool,
        ) !void {
            try assertSessionCwdExists(io, session_manager, fallback_cwd);
            create_runtime_called.* = true;
        }
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fallback_cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(fallback_cwd);
    const missing_cwd = try std.fs.path.join(allocator, &.{ fallback_cwd, "does-not-exist" });
    defer allocator.free(missing_cwd);
    const session_file = try std.fs.path.join(allocator, &.{ fallback_cwd, "session.jsonl" });
    defer allocator.free(session_file);

    const session_manager: TestSessionManager = .{
        .cwd = missing_cwd,
        .session_file = session_file,
    };
    var create_runtime_called = false;

    try std.testing.expectError(
        error.MissingSessionCwd,
        RuntimeHarness.create(
            std.testing.io,
            session_manager.source(),
            fallback_cwd,
            &create_runtime_called,
        ),
    );
    try std.testing.expect(!create_runtime_called);
}
