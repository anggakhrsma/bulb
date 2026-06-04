const std = @import("std");
const paths = @import("paths.zig");
const session_cwd = @import("session_cwd.zig");

pub const current_session_version: u32 = 3;

pub const invalid_session_id_message =
    "Session id must be non-empty, contain only alphanumeric characters, '-', '_', and '.', and start and end with an alphanumeric character";

pub const SessionHeader = struct {
    version: ?u32,
    id: []const u8,
    timestamp: ?[]const u8,
    cwd: ?[]const u8,
    parent_session: ?[]const u8,
};

/// A lossless raw JSONL entry with the common fields needed by the manager foundation.
pub const FileEntry = struct {
    raw_json: []const u8,
    entry_type: ?[]const u8,
    id: ?[]const u8,
};

pub const LoadedEntries = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const FileEntry,
    header: ?SessionHeader,

    pub fn deinit(self: *LoadedEntries) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OpenOptions = struct {
    session_dir: ?[]const u8 = null,
    cwd_override: ?[]const u8 = null,
};

pub const SessionManager = struct {
    arena: std.heap.ArenaAllocator,
    session_id: []const u8,
    session_file: ?[]const u8,
    session_dir: []const u8,
    cwd: []const u8,
    file_entries: []const FileEntry,
    header: SessionHeader,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        options: OpenOptions,
    ) !SessionManager {
        const process_cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(process_cwd);
        const resolved_path = try paths.resolvePathAlloc(allocator, path, process_cwd, .{});
        defer allocator.free(resolved_path);

        var loaded = try loadEntriesFromFile(allocator, io, resolved_path);
        errdefer loaded.deinit();
        const header = loaded.header orelse return error.InvalidSessionFile;
        const effective_cwd_input = options.cwd_override orelse header.cwd orelse process_cwd;
        const resolved_cwd = try paths.resolvePathAlloc(allocator, effective_cwd_input, process_cwd, .{});
        defer allocator.free(resolved_cwd);

        const normalized_session_dir = if (options.session_dir) |session_dir|
            try paths.normalizePathAlloc(allocator, session_dir, .{})
        else
            try allocator.dupe(u8, std.fs.path.dirname(resolved_path) orelse process_cwd);
        defer allocator.free(normalized_session_dir);

        const arena_allocator = loaded.arena.allocator();
        const manager_session_file = try arena_allocator.dupe(u8, resolved_path);
        const manager_session_dir = try arena_allocator.dupe(u8, normalized_session_dir);
        const manager_cwd = try arena_allocator.dupe(u8, resolved_cwd);
        const manager = SessionManager{
            .arena = loaded.arena,
            .session_id = header.id,
            .session_file = manager_session_file,
            .session_dir = manager_session_dir,
            .cwd = manager_cwd,
            .file_entries = loaded.entries,
            .header = header,
        };
        return manager;
    }

    pub fn deinit(self: *SessionManager) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn getCwd(self: *const SessionManager) []const u8 {
        return self.cwd;
    }

    pub fn getSessionDir(self: *const SessionManager) []const u8 {
        return self.session_dir;
    }

    pub fn getSessionId(self: *const SessionManager) []const u8 {
        return self.session_id;
    }

    pub fn getSessionFile(self: *const SessionManager) ?[]const u8 {
        return self.session_file;
    }

    pub fn getHeader(self: *const SessionManager) ?SessionHeader {
        return self.header;
    }

    pub fn getFileEntries(self: *const SessionManager) []const FileEntry {
        return self.file_entries;
    }

    pub fn getEntries(self: *const SessionManager) []const FileEntry {
        return self.file_entries[1..];
    }

    pub fn cwdSource(self: *const SessionManager) session_cwd.SessionCwdSource {
        return .{
            .ptr = self,
            .get_cwd_fn = sourceGetCwd,
            .get_session_file_fn = sourceGetSessionFile,
        };
    }

    fn sourceGetCwd(ptr: *const anyopaque) []const u8 {
        const self: *const SessionManager = @ptrCast(@alignCast(ptr));
        return self.getCwd();
    }

    fn sourceGetSessionFile(ptr: *const anyopaque) ?[]const u8 {
        const self: *const SessionManager = @ptrCast(@alignCast(ptr));
        return self.getSessionFile();
    }
};

pub fn isValidSessionId(id: []const u8) bool {
    if (id.len == 0 or !std.ascii.isAlphanumeric(id[0]) or !std.ascii.isAlphanumeric(id[id.len - 1])) {
        return false;
    }
    if (id.len == 1) return true;
    for (id[1 .. id.len - 1]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') {
            return false;
        }
    }
    return true;
}

pub fn assertValidSessionId(id: []const u8) error{InvalidSessionId}!void {
    if (!isValidSessionId(id)) return error.InvalidSessionId;
}

/// Loads JSONL entries without requiring the entire session file to fit in one string.
/// Malformed lines are skipped, matching Pi's loader behavior.
pub fn loadEntriesFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) !LoadedEntries {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var entries: std.ArrayList(FileEntry) = .empty;

    var file = std.Io.Dir.cwd().openFile(io, file_path, .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .entries = &.{}, .header = null },
        else => |open_error| return open_error,
    };
    defer file.close(io);

    var read_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    while (true) {
        var line_writer: std.Io.Writer.Allocating = .init(allocator);
        defer line_writer.deinit();
        _ = file_reader.interface.streamDelimiterEnding(&line_writer.writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
            error.WriteFailed => return error.OutOfMemory,
        };

        const at_end = blk: {
            const byte = file_reader.interface.peekByte() catch |err| switch (err) {
                error.EndOfStream => break :blk true,
                error.ReadFailed => return file_reader.err.?,
            };
            std.debug.assert(byte == '\n');
            _ = file_reader.interface.takeByte() catch unreachable;
            break :blk false;
        };

        if (try parseEntryLine(arena_allocator, allocator, line_writer.written())) |entry| {
            try entries.append(arena_allocator, entry);
        }
        if (at_end) break;
    }

    if (entries.items.len == 0) {
        return .{ .arena = arena, .entries = &.{}, .header = null };
    }
    const header = try parseHeaderFromRaw(arena_allocator, allocator, entries.items[0].raw_json) orelse {
        return .{ .arena = arena, .entries = &.{}, .header = null };
    };
    const owned_entries = try entries.toOwnedSlice(arena_allocator);
    return .{
        .arena = arena,
        .entries = owned_entries,
        .header = header,
    };
}

fn parseEntryLine(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    line: []const u8,
) !?FileEntry {
    if (std.mem.trim(u8, line, " \t\r\n").len == 0) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();

    const entry_type = if (parsed.value == .object)
        try optionalStringDup(output_allocator, parsed.value.object, "type")
    else
        null;
    errdefer if (entry_type) |value| output_allocator.free(value);
    const id = if (parsed.value == .object)
        try optionalStringDup(output_allocator, parsed.value.object, "id")
    else
        null;
    errdefer if (id) |value| output_allocator.free(value);

    return .{
        .raw_json = try output_allocator.dupe(u8, line),
        .entry_type = entry_type,
        .id = id,
    };
}

fn parseHeaderFromRaw(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    raw_json: []const u8,
) !?SessionHeader {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    const entry_type = optionalString(object, "type") orelse return null;
    if (!std.mem.eql(u8, entry_type, "session")) return null;
    const id = optionalString(object, "id") orelse return null;

    return .{
        .version = optionalU32(object, "version"),
        .id = try output_allocator.dupe(u8, id),
        .timestamp = try optionalStringDup(output_allocator, object, "timestamp"),
        .cwd = try optionalStringDup(output_allocator, object, "cwd"),
        .parent_session = try optionalStringDup(output_allocator, object, "parentSession"),
    };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalStringDup(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]const u8 {
    const value = optionalString(object, key) orelse return null;
    return try allocator.dupe(u8, value);
}

fn optionalU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn sessionHeaderJsonAlloc(allocator: std.mem.Allocator, id: []const u8, cwd: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("session");
    try json.objectField("version");
    try json.write(current_session_version);
    try json.objectField("id");
    try json.write(id);
    try json.objectField("timestamp");
    try json.write("2025-01-01T00:00:00.000Z");
    try json.objectField("cwd");
    try json.write(cwd);
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn writeAbsoluteFile(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .read = true, .truncate = true },
    });
}

// Ported from packages/coding-agent/test/session-manager/custom-session-id.test.ts.
test "session ids allow alphanumeric values with interior punctuation" {
    const valid_ids = [_][]const u8{ "a", "abc", "abc-123_def.456", "A9" };
    for (valid_ids) |id| {
        try assertValidSessionId(id);
        try std.testing.expect(isValidSessionId(id));
    }
}

test "session ids reject invalid custom values" {
    const invalid_ids = [_][]const u8{
        "",
        "-abc",
        "abc-",
        "_abc",
        "abc_",
        ".abc",
        "abc.",
        "abc/def",
        "abc\\def",
        "abc def",
    };
    for (invalid_ids) |id| {
        try std.testing.expect(!isValidSessionId(id));
        try std.testing.expectError(error.InvalidSessionId, assertValidSessionId(id));
    }
    try std.testing.expect(std.mem.startsWith(
        u8,
        invalid_session_id_message,
        "Session id must be non-empty, contain only alphanumeric characters",
    ));
}

// Ported from packages/coding-agent/test/session-manager/file-operations.test.ts.
test "loadEntriesFromFile returns empty entries for missing empty malformed and headerless files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    const missing_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing.jsonl" });
    defer allocator.free(missing_path);
    var missing = try loadEntriesFromFile(allocator, std.testing.io, missing_path);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.entries.len);

    const cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "empty.jsonl", .data = "" },
        .{ .name = "malformed.jsonl", .data = "not json\n" },
        .{ .name = "no-header.jsonl", .data = "{\"type\":\"message\",\"id\":\"1\"}\n" },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(allocator, &.{ tmp_path, case.name });
        defer allocator.free(path);
        try writeAbsoluteFile(std.testing.io, path, case.data);
        var loaded = try loadEntriesFromFile(allocator, std.testing.io, path);
        defer loaded.deinit();
        try std.testing.expectEqual(@as(usize, 0), loaded.entries.len);
        try std.testing.expectEqual(null, loaded.header);
    }
}

test "loadEntriesFromFile loads valid entries and skips malformed lines" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "mixed.jsonl" });
    defer allocator.free(path);
    const content =
        "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" ++
        "not valid json\n" ++
        "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n";
    try writeAbsoluteFile(std.testing.io, path, content);

    var loaded = try loadEntriesFromFile(allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try std.testing.expectEqualStrings("session", loaded.entries[0].entry_type.?);
    try std.testing.expectEqualStrings("message", loaded.entries[1].entry_type.?);
    try std.testing.expectEqualStrings("abc", loaded.header.?.id);
}

test "SessionManager opens persisted sessions and exposes header and entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "session.jsonl" });
    defer allocator.free(path);
    const content =
        "{\"type\":\"session\",\"version\":3,\"id\":\"session-id\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" ++
        "{\"type\":\"message\",\"id\":\"1\"}\n";
    try writeAbsoluteFile(std.testing.io, path, content);

    var manager = try SessionManager.open(allocator, std.testing.io, path, .{});
    defer manager.deinit();
    try std.testing.expectEqualStrings("session-id", manager.getSessionId());
    try std.testing.expectEqualStrings("/tmp", manager.getCwd());
    try std.testing.expectEqualStrings(path, manager.getSessionFile().?);
    try std.testing.expectEqualStrings(tmp_path, manager.getSessionDir());
    try std.testing.expectEqualStrings("session-id", manager.getHeader().?.id);
    try std.testing.expectEqual(@as(usize, 1), manager.getEntries().len);
}

// Ported integration cases from packages/coding-agent/test/session-cwd.test.ts.
test "SessionManager preserves stored cwd issues and supports effective cwd override" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fallback_cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(fallback_cwd);
    const missing_cwd = try std.fs.path.join(allocator, &.{ fallback_cwd, "does-not-exist" });
    defer allocator.free(missing_cwd);
    const path = try std.fs.path.join(allocator, &.{ fallback_cwd, "session.jsonl" });
    defer allocator.free(path);
    const header_json = try sessionHeaderJsonAlloc(allocator, "session-id", missing_cwd);
    defer allocator.free(header_json);
    try writeAbsoluteFile(std.testing.io, path, header_json);

    var stored = try SessionManager.open(allocator, std.testing.io, path, .{});
    defer stored.deinit();
    const issue = session_cwd.getMissingSessionCwdIssue(std.testing.io, stored.cwdSource(), fallback_cwd).?;
    try std.testing.expectEqualStrings(missing_cwd, issue.session_cwd);
    try std.testing.expectEqualStrings(path, issue.session_file.?);

    var overridden = try SessionManager.open(allocator, std.testing.io, path, .{
        .cwd_override = fallback_cwd,
    });
    defer overridden.deinit();
    try std.testing.expectEqualStrings(fallback_cwd, overridden.getCwd());
    try std.testing.expectEqual(
        null,
        session_cwd.getMissingSessionCwdIssue(std.testing.io, overridden.cwdSource(), fallback_cwd),
    );
}
