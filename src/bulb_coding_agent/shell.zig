const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

pub const ProcessId = i64;

pub const ShellError = error{
    CustomShellPathNotFound,
    NoBashShellFound,
};

pub const ShellConfig = struct {
    shell: []u8,
    args: []const []const u8 = &.{"-c"},

    pub fn deinit(self: *ShellConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.shell);
        self.* = .{ .shell = &.{} };
    }
};

pub const ProcessTerminator = struct {
    ptr: ?*anyopaque = null,
    kill_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, ProcessId) void = defaultKillProcessTree,

    pub fn kill(self: ProcessTerminator, allocator: std.mem.Allocator, io: std.Io, pid: ProcessId) void {
        self.kill_fn(self.ptr, allocator, io, pid);
    }
};

pub const DetachedChildTracker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pids: std.AutoHashMap(ProcessId, void),
    terminator: ProcessTerminator = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io) DetachedChildTracker {
        return .{
            .allocator = allocator,
            .io = io,
            .pids = std.AutoHashMap(ProcessId, void).init(allocator),
        };
    }

    pub fn deinit(self: *DetachedChildTracker) void {
        self.pids.deinit();
        self.* = undefined;
    }

    pub fn trackDetachedChildPid(self: *DetachedChildTracker, pid: ProcessId) !void {
        try self.pids.put(pid, {});
    }

    pub fn untrackDetachedChildPid(self: *DetachedChildTracker, pid: ProcessId) void {
        _ = self.pids.remove(pid);
    }

    pub fn killTrackedDetachedChildren(self: *DetachedChildTracker) void {
        var iterator = self.pids.keyIterator();
        while (iterator.next()) |pid| {
            self.terminator.kill(self.allocator, self.io, pid.*);
        }
        self.pids.clearRetainingCapacity();
    }
};

pub fn getShellConfigAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    custom_shell_path: ?[]const u8,
) !ShellConfig {
    return getShellConfigForOsAlloc(allocator, io, env, custom_shell_path, builtin.os.tag);
}

pub fn getShellConfigForOsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    custom_shell_path: ?[]const u8,
    os_tag: std.Target.Os.Tag,
) !ShellConfig {
    if (custom_shell_path) |path| {
        if (pathExists(io, path)) return .{ .shell = try allocator.dupe(u8, path) };
        return error.CustomShellPathNotFound;
    }

    if (os_tag == .windows) {
        const known_paths = try knownWindowsGitBashPathsAlloc(allocator, env);
        defer {
            for (known_paths) |path| allocator.free(path);
            allocator.free(known_paths);
        }

        for (known_paths) |path| {
            if (pathExists(io, path)) return .{ .shell = try allocator.dupe(u8, path) };
        }

        if (try findBashOnPathAlloc(allocator, io, env, os_tag)) |bash| {
            return .{ .shell = bash };
        }

        return error.NoBashShellFound;
    }

    if (pathExists(io, "/bin/bash")) {
        return .{ .shell = try allocator.dupe(u8, "/bin/bash") };
    }
    if (try findBashOnPathAlloc(allocator, io, env, os_tag)) |bash| {
        return .{ .shell = bash };
    }
    return .{ .shell = try allocator.dupe(u8, "sh") };
}

pub fn getShellEnvAlloc(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) !std.process.Environ.Map {
    var updated = try env.clone(allocator);
    errdefer updated.deinit();

    const bin_dir = try binDirAlloc(allocator, env);
    defer allocator.free(bin_dir);

    const key = findPathKey(env) orelse "PATH";
    const current_path = env.get(key) orelse "";
    if (!pathListContains(current_path, bin_dir)) {
        const new_path = if (current_path.len == 0)
            try allocator.dupe(u8, bin_dir)
        else
            try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ bin_dir, pathDelimiterForOs(builtin.os.tag), current_path });
        defer allocator.free(new_path);
        try updated.put(key, new_path);
    }

    return updated;
}

pub fn sanitizeBinaryOutputAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        const first = input[index];
        const width = std.unicode.utf8ByteSequenceLength(first) catch {
            index += 1;
            continue;
        };
        if (index + width > input.len) break;

        const slice = input[index .. index + width];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            index += 1;
            continue;
        };
        index += width;

        if (codepoint == 0x09 or codepoint == 0x0a or codepoint == 0x0d) {
            try output.appendSlice(allocator, slice);
            continue;
        }
        if (codepoint <= 0x1f) continue;
        if (codepoint >= 0xfff9 and codepoint <= 0xfffb) continue;

        try output.appendSlice(allocator, slice);
    }

    return output.toOwnedSlice(allocator);
}

pub fn killProcessTree(allocator: std.mem.Allocator, io: std.Io, pid: ProcessId) void {
    defaultKillProcessTree(null, allocator, io, pid);
}

fn defaultKillProcessTree(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, pid: ProcessId) void {
    if (builtin.os.tag == .windows) {
        const pid_string = std.fmt.allocPrint(allocator, "{d}", .{pid}) catch return;
        defer allocator.free(pid_string);
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "taskkill", "/F", "/T", "/PID", pid_string },
            .stdout_limit = .nothing,
            .stderr_limit = .nothing,
        }) catch return;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return;
    }

    const posix_pid = std.math.cast(std.posix.pid_t, pid) orelse return;
    std.posix.kill(-posix_pid, .KILL) catch {
        std.posix.kill(posix_pid, .KILL) catch {};
    };
}

fn pathExists(io: std.Io, file_path: []const u8) bool {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch return false;
    return true;
}

fn findBashOnPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    os_tag: std.Target.Os.Tag,
) !?[]u8 {
    const path_key = findPathKey(env) orelse return null;
    const path_value = env.get(path_key) orelse return null;
    var iterator = std.mem.splitScalar(u8, path_value, pathDelimiterForOs(os_tag));
    while (iterator.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try bashCandidateAlloc(allocator, entry, os_tag);
        if (pathExists(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn bashCandidateAlloc(allocator: std.mem.Allocator, dir: []const u8, os_tag: std.Target.Os.Tag) ![]u8 {
    const executable = if (os_tag == .windows) "bash.exe" else "bash";
    if (dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, executable });
    }
    const separator: u8 = if (os_tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, separator, executable });
}

fn knownWindowsGitBashPathsAlloc(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
) ![][]u8 {
    var paths: std.ArrayList([]u8) = .empty;
    defer paths.deinit(allocator);
    errdefer {
        for (paths.items) |path| allocator.free(path);
    }

    if (env.get("ProgramFiles")) |program_files| {
        try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}\\Git\\bin\\bash.exe", .{program_files}));
    }
    if (env.get("ProgramFiles(x86)")) |program_files_x86| {
        try paths.append(allocator, try std.fmt.allocPrint(allocator, "{s}\\Git\\bin\\bash.exe", .{program_files_x86}));
    }

    return paths.toOwnedSlice(allocator);
}

fn findPathKey(env: *const std.process.Environ.Map) ?[]const u8 {
    var iterator = env.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "PATH")) return entry.key_ptr.*;
    }
    return null;
}

fn pathListContains(path_value: []const u8, needle: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, path_value, pathDelimiterForOs(builtin.os.tag));
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn pathDelimiterForOs(os_tag: std.Target.Os.Tag) u8 {
    return if (os_tag == .windows) ';' else ':';
}

fn binDirAlloc(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const agent_dir = try config.agentDirAlloc(allocator, env);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "bin" });
}

const FakeTerminator = struct {
    killed: std.ArrayList(ProcessId) = .empty,

    fn kill(ptr: ?*anyopaque, _: std.mem.Allocator, _: std.Io, pid: ProcessId) void {
        const self: *FakeTerminator = @ptrCast(@alignCast(ptr.?));
        self.killed.append(std.testing.allocator, pid) catch unreachable;
    }
};

test "shell config honors custom shell and Unix fallback order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "custom-bash", .data = "" });

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const custom_shell = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], "custom-bash" });
    defer allocator.free(custom_shell);

    var custom = try getShellConfigForOsAlloc(allocator, io, &env, custom_shell, .linux);
    defer custom.deinit(allocator);
    try std.testing.expectEqualStrings(custom_shell, custom.shell);
    try std.testing.expectEqualStrings("-c", custom.args[0]);

    try std.testing.expectError(
        error.CustomShellPathNotFound,
        getShellConfigForOsAlloc(allocator, io, &env, "/missing/bulb-shell", .linux),
    );

    if (!pathExists(io, "/bin/bash")) {
        var fallback = try getShellConfigForOsAlloc(allocator, io, &env, null, .linux);
        defer fallback.deinit(allocator);
        try std.testing.expectEqualStrings("sh", fallback.shell);
    }
}

test "shell env prepends Bulb managed bin directory once and preserves PATH key casing" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/bulb");
    try env.put("Path", "/usr/bin:/bin");

    var first = try getShellEnvAlloc(allocator, &env);
    defer first.deinit();
    try std.testing.expectEqualStrings("/home/bulb/.bulb/agent/bin:/usr/bin:/bin", first.get("Path").?);
    try std.testing.expectEqual(null, first.get("PATH"));

    var second = try getShellEnvAlloc(allocator, &first);
    defer second.deinit();
    try std.testing.expectEqualStrings("/home/bulb/.bulb/agent/bin:/usr/bin:/bin", second.get("Path").?);
}

test "sanitizeBinaryOutput strips dangerous controls and preserves printable Unicode" {
    const allocator = std.testing.allocator;
    const input = "ok\t\n\r\x00\x08\x1f\x7f\u{fff9}\u{fffa}\u{fffb} snow \u{2603}";
    const sanitized = try sanitizeBinaryOutputAlloc(allocator, input);
    defer allocator.free(sanitized);

    try std.testing.expectEqualStrings("ok\t\n\r\x7f snow \u{2603}", sanitized);
}

test "sanitizeBinaryOutput skips invalid UTF-8 bytes" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 'a', 0xff, 'b', 0xc3 };
    const sanitized = try sanitizeBinaryOutputAlloc(allocator, &input);
    defer allocator.free(sanitized);

    try std.testing.expectEqualStrings("ab", sanitized);
}

test "detached child tracker tracks untracks kills and clears pids" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fake: FakeTerminator = .{};
    defer fake.killed.deinit(allocator);

    var tracker = DetachedChildTracker.init(allocator, io);
    defer tracker.deinit();
    tracker.terminator = .{ .ptr = &fake, .kill_fn = FakeTerminator.kill };

    try tracker.trackDetachedChildPid(10);
    try tracker.trackDetachedChildPid(20);
    tracker.untrackDetachedChildPid(10);
    tracker.killTrackedDetachedChildren();

    try std.testing.expectEqual(@as(usize, 1), fake.killed.items.len);
    try std.testing.expectEqual(@as(ProcessId, 20), fake.killed.items[0]);
    try std.testing.expectEqual(@as(usize, 0), tracker.pids.count());
}
