const std = @import("std");
const session_manager_mod = @import("session_manager.zig");

pub const empty_name_error_message = "Error: --name requires a non-empty value";

pub const StartupSessionNameError = error{
    EmptySessionName,
};

pub fn normalizeStartupSessionName(name: []const u8) StartupSessionNameError![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return error.EmptySessionName;
    return trimmed;
}

/// Apply a startup --name value to the selected session before later runtime
/// validation can fail, matching Pi's CLI startup ordering.
pub fn applyStartupSessionName(
    session_manager: *session_manager_mod.SessionManager,
    io: std.Io,
    name: ?[]const u8,
) !?[]const u8 {
    const raw_name = name orelse return null;
    const normalized = try normalizeStartupSessionName(raw_name);
    return try session_manager.appendSessionInfo(io, normalized);
}

const LaterRuntimeError = error{MissingModel};

const TempStartupSession = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    session_dir: []u8,
    project_dir: []u8,
    session_file: []u8,

    fn deinit(self: *TempStartupSession) void {
        self.allocator.free(self.session_file);
        self.allocator.free(self.project_dir);
        self.allocator.free(self.session_dir);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn createStartupSession(allocator: std.mem.Allocator) !TempStartupSession {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const project_dir = try std.fs.path.join(allocator, &.{ tmp_path, "project" });
    errdefer allocator.free(project_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ tmp_path, "sessions" });
    errdefer allocator.free(session_dir);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, project_dir);

    var session = try session_manager_mod.SessionManager.create(
        allocator,
        std.testing.io,
        project_dir,
        session_dir,
        .{ .id = "existing-session" },
    );
    defer session.deinit();

    _ = try session.appendMessageJson(std.testing.io,
        \\{"role":"assistant","content":[{"type":"text","text":"hello"}],"provider":"anthropic","model":"claude-sonnet-4-5","timestamp":0}
    );

    return .{
        .allocator = allocator,
        .tmp = tmp,
        .session_dir = session_dir,
        .project_dir = project_dir,
        .session_file = try allocator.dupe(u8, session.getSessionFile().?),
    };
}

fn applyNameThenFail(
    session_manager: *session_manager_mod.SessionManager,
    name: ?[]const u8,
) !void {
    _ = try applyStartupSessionName(session_manager, std.testing.io, name);
    return LaterRuntimeError.MissingModel;
}

fn sessionInfoNamesAlloc(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(content);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, content, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const entry_type_value = parsed.value.object.get("type") orelse continue;
        if (entry_type_value != .string) continue;
        if (!std.mem.eql(u8, entry_type_value.string, "session_info")) continue;
        const name_value = parsed.value.object.get("name") orelse {
            try names.append(allocator, try allocator.dupe(u8, ""));
            continue;
        };
        if (name_value == .string) {
            try names.append(allocator, try allocator.dupe(u8, name_value.string));
        } else {
            try names.append(allocator, try allocator.dupe(u8, ""));
        }
    }

    return names.toOwnedSlice(allocator);
}

fn freeNames(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn expectSessionInfoNames(path: []const u8, expected: []const []const u8) !void {
    const names = try sessionInfoNamesAlloc(std.testing.allocator, path);
    defer freeNames(std.testing.allocator, names);

    try std.testing.expectEqual(expected.len, names.len);
    for (expected, names) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

// Ported from packages/coding-agent/test/startup-session-name.test.ts.
test "startup session name is saved before later runtime model validation fails" {
    var fixture = try createStartupSession(std.testing.allocator);
    defer fixture.deinit();

    var session = try session_manager_mod.SessionManager.open(
        std.testing.allocator,
        std.testing.io,
        fixture.session_file,
        .{
            .session_dir = fixture.session_dir,
            .cwd_override = fixture.project_dir,
        },
    );
    defer session.deinit();

    try std.testing.expectError(
        LaterRuntimeError.MissingModel,
        applyNameThenFail(&session, "  CLI Named Session  "),
    );
    try expectSessionInfoNames(fixture.session_file, &.{"CLI Named Session"});
}

test "startup session name rejects empty values without appending session metadata" {
    var fixture = try createStartupSession(std.testing.allocator);
    defer fixture.deinit();

    var session = try session_manager_mod.SessionManager.open(
        std.testing.allocator,
        std.testing.io,
        fixture.session_file,
        .{
            .session_dir = fixture.session_dir,
            .cwd_override = fixture.project_dir,
        },
    );
    defer session.deinit();

    try std.testing.expectError(error.EmptySessionName, applyStartupSessionName(&session, std.testing.io, "   "));
    try expectSessionInfoNames(fixture.session_file, &.{});
}
