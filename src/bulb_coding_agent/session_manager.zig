const std = @import("std");
const agent = @import("bulb_agent");
const config = @import("config.zig");
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

pub const NewSessionOptions = struct {
    id: ?[]const u8 = null,
    parent_session: ?[]const u8 = null,
};

pub const SessionManager = struct {
    arena: std.heap.ArenaAllocator,
    persist: bool,
    flushed: bool,
    session_id: []const u8,
    session_file: ?[]const u8,
    session_dir: []const u8,
    cwd: []const u8,
    file_entries: []const FileEntry,
    header: SessionHeader,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        options: NewSessionOptions,
    ) !SessionManager {
        return initNew(allocator, io, cwd, session_dir, true, options);
    }

    pub fn createDefault(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        agent_dir: []const u8,
        options: NewSessionOptions,
    ) !SessionManager {
        const session_dir = try getDefaultSessionDirAlloc(allocator, io, cwd, agent_dir);
        defer allocator.free(session_dir);
        return initNew(allocator, io, cwd, session_dir, true, options);
    }

    pub fn createDefaultFromEnv(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        environ: *const std.process.Environ.Map,
        options: NewSessionOptions,
    ) !SessionManager {
        const session_dir = try getDefaultSessionDirFromEnvAlloc(allocator, io, cwd, environ);
        defer allocator.free(session_dir);
        return initNew(allocator, io, cwd, session_dir, true, options);
    }

    pub fn continueRecent(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
    ) !SessionManager {
        const normalized_session_dir = try paths.normalizePathAlloc(allocator, session_dir, .{});
        defer allocator.free(normalized_session_dir);
        const most_recent = try findMostRecentSessionAlloc(allocator, io, normalized_session_dir, cwd);
        defer if (most_recent) |path| allocator.free(path);
        if (most_recent) |path| {
            return open(allocator, io, path, .{
                .session_dir = normalized_session_dir,
                .cwd_override = cwd,
            });
        }
        return initNew(allocator, io, cwd, normalized_session_dir, true, .{});
    }

    pub fn continueRecentDefault(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        agent_dir: []const u8,
    ) !SessionManager {
        const session_dir = try getDefaultSessionDirAlloc(allocator, io, cwd, agent_dir);
        defer allocator.free(session_dir);
        const most_recent = try findMostRecentSessionAlloc(allocator, io, session_dir, null);
        defer if (most_recent) |path| allocator.free(path);
        if (most_recent) |path| {
            return open(allocator, io, path, .{
                .session_dir = session_dir,
                .cwd_override = cwd,
            });
        }
        return initNew(allocator, io, cwd, session_dir, true, .{});
    }

    pub fn continueRecentDefaultFromEnv(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        environ: *const std.process.Environ.Map,
    ) !SessionManager {
        const agent_dir = try config.agentDirAlloc(allocator, environ);
        defer allocator.free(agent_dir);
        return continueRecentDefault(allocator, io, cwd, agent_dir);
    }

    pub fn inMemory(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: ?[]const u8,
    ) !SessionManager {
        const process_cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(process_cwd);
        return initNew(allocator, io, cwd orelse process_cwd, "", false, .{});
    }

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
        const normalized_session_dir = if (options.session_dir) |session_dir|
            try paths.normalizePathAlloc(allocator, session_dir, .{})
        else
            try allocator.dupe(u8, std.fs.path.dirname(resolved_path) orelse process_cwd);
        defer allocator.free(normalized_session_dir);

        const file_exists = blk: {
            std.Io.Dir.cwd().access(io, resolved_path, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => |access_error| return access_error,
            };
            break :blk true;
        };
        var loaded = try loadEntriesFromFile(allocator, io, resolved_path);
        var loaded_released = false;
        errdefer if (!loaded_released) loaded.deinit();
        const header = loaded.header orelse {
            loaded_released = true;
            loaded.deinit();
            var manager = try initNew(
                allocator,
                io,
                options.cwd_override orelse process_cwd,
                normalized_session_dir,
                true,
                .{},
            );
            errdefer manager.deinit();
            manager.session_file = try manager.arena.allocator().dupe(u8, resolved_path);
            if (file_exists) {
                try manager.rewriteFile(io);
                manager.flushed = true;
            }
            return manager;
        };
        const effective_cwd_input = options.cwd_override orelse header.cwd orelse process_cwd;
        const resolved_cwd = try paths.resolvePathAlloc(allocator, effective_cwd_input, process_cwd, .{});
        defer allocator.free(resolved_cwd);

        const arena_allocator = loaded.arena.allocator();
        const manager_session_file = try arena_allocator.dupe(u8, resolved_path);
        const manager_session_dir = try arena_allocator.dupe(u8, normalized_session_dir);
        const manager_cwd = try arena_allocator.dupe(u8, resolved_cwd);
        const manager = SessionManager{
            .arena = loaded.arena,
            .persist = true,
            .flushed = true,
            .session_id = header.id,
            .session_file = manager_session_file,
            .session_dir = manager_session_dir,
            .cwd = manager_cwd,
            .file_entries = loaded.entries,
            .header = header,
        };
        loaded_released = true;
        return manager;
    }

    pub fn newSession(
        self: *SessionManager,
        io: std.Io,
        options: NewSessionOptions,
    ) !?[]const u8 {
        if (options.id) |id| try assertValidSessionId(id);

        var generated_id: [36]u8 = undefined;
        const id_input = options.id orelse blk: {
            generated_id = agent.uuid.uuidv7(io);
            break :blk generated_id[0..];
        };
        const arena_allocator = self.arena.allocator();
        const id = try arena_allocator.dupe(u8, id_input);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        const parent_session = if (options.parent_session) |parent|
            try arena_allocator.dupe(u8, parent)
        else
            null;
        const header = SessionHeader{
            .version = current_session_version,
            .id = id,
            .timestamp = timestamp,
            .cwd = self.cwd,
            .parent_session = parent_session,
        };
        const raw_json = try freshHeaderJsonAlloc(arena_allocator, header);
        const entries = try arena_allocator.alloc(FileEntry, 1);
        entries[0] = .{
            .raw_json = raw_json,
            .entry_type = "session",
            .id = id,
        };
        const session_file = if (self.persist)
            try freshSessionFileAlloc(arena_allocator, self.session_dir, timestamp, id)
        else
            null;

        self.session_id = id;
        self.header = header;
        self.file_entries = entries;
        self.session_file = session_file;
        return self.session_file;
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

    pub fn isPersisted(self: *const SessionManager) bool {
        return self.persist;
    }

    pub fn usesDefaultSessionDir(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        agent_dir: []const u8,
    ) !bool {
        const default_dir = try getDefaultSessionDirPathAlloc(allocator, io, self.cwd, agent_dir);
        defer allocator.free(default_dir);
        return std.mem.eql(u8, self.session_dir, default_dir);
    }

    pub fn usesDefaultSessionDirFromEnv(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
    ) !bool {
        const agent_dir = try config.agentDirAlloc(allocator, environ);
        defer allocator.free(agent_dir);
        return self.usesDefaultSessionDir(allocator, io, agent_dir);
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

    fn initNew(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        persist: bool,
        options: NewSessionOptions,
    ) !SessionManager {
        const process_cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(process_cwd);
        const resolved_cwd = try paths.resolvePathAlloc(allocator, cwd, process_cwd, .{});
        defer allocator.free(resolved_cwd);
        const normalized_session_dir = try paths.normalizePathAlloc(allocator, session_dir, .{});
        defer allocator.free(normalized_session_dir);
        if (persist and normalized_session_dir.len > 0) {
            try std.Io.Dir.cwd().createDirPath(io, normalized_session_dir);
        }

        var manager = SessionManager{
            .arena = .init(allocator),
            .persist = persist,
            .flushed = false,
            .session_id = "",
            .session_file = null,
            .session_dir = "",
            .cwd = "",
            .file_entries = &.{},
            .header = .{
                .version = null,
                .id = "",
                .timestamp = null,
                .cwd = null,
                .parent_session = null,
            },
        };
        errdefer manager.deinit();
        const arena_allocator = manager.arena.allocator();
        manager.session_dir = try arena_allocator.dupe(u8, normalized_session_dir);
        manager.cwd = try arena_allocator.dupe(u8, resolved_cwd);
        _ = try manager.newSession(io, options);
        return manager;
    }

    fn rewriteFile(self: *const SessionManager, io: std.Io) !void {
        if (!self.persist) return;
        const session_file = self.session_file orelse return;
        var output: std.Io.Writer.Allocating = .init(self.arena.child_allocator);
        defer output.deinit();
        for (self.file_entries) |entry| {
            try output.writer.writeAll(entry.raw_json);
            try output.writer.writeByte('\n');
        }
        try writeAbsoluteFile(io, session_file, output.written());
    }
};

pub fn getDefaultSessionDirPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    const process_cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(process_cwd);
    const resolved_cwd = try paths.resolvePathAlloc(allocator, cwd, process_cwd, .{});
    defer allocator.free(resolved_cwd);
    const resolved_agent_dir = try paths.resolvePathAlloc(allocator, agent_dir, process_cwd, .{});
    defer allocator.free(resolved_agent_dir);
    const safe_path = try defaultSessionSafePathAlloc(allocator, resolved_cwd);
    defer allocator.free(safe_path);
    return std.fs.path.join(allocator, &.{ resolved_agent_dir, "sessions", safe_path });
}

pub fn getDefaultSessionDirAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    const session_dir = try getDefaultSessionDirPathAlloc(allocator, io, cwd, agent_dir);
    errdefer allocator.free(session_dir);
    try std.Io.Dir.cwd().createDirPath(io, session_dir);
    return session_dir;
}

pub fn getDefaultSessionDirFromEnvAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const agent_dir = try config.agentDirAlloc(allocator, environ);
    defer allocator.free(agent_dir);
    return getDefaultSessionDirAlloc(allocator, io, cwd, agent_dir);
}

fn defaultSessionSafePathAlloc(allocator: std.mem.Allocator, resolved_cwd: []const u8) ![]u8 {
    const start: usize = if (resolved_cwd.len > 0 and (resolved_cwd[0] == '/' or resolved_cwd[0] == '\\')) 1 else 0;
    const body = resolved_cwd[start..];
    const safe = try allocator.alloc(u8, body.len + 4);
    safe[0] = '-';
    safe[1] = '-';
    for (body, 0..) |byte, index| {
        safe[index + 2] = switch (byte) {
            '/', '\\', ':' => '-',
            else => byte,
        };
    }
    safe[safe.len - 2] = '-';
    safe[safe.len - 1] = '-';
    return safe;
}

/// Finds the newest valid session JSONL file in a flat session directory.
/// The returned path is allocator-owned.
pub fn findMostRecentSessionAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    cwd: ?[]const u8,
) !?[]u8 {
    const process_cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(process_cwd);
    const normalized_session_dir = try paths.normalizePathAlloc(allocator, session_dir, .{});
    defer allocator.free(normalized_session_dir);
    const resolved_cwd = if (cwd) |value|
        try paths.resolvePathAlloc(allocator, value, process_cwd, .{})
    else
        null;
    defer if (resolved_cwd) |value| allocator.free(value);

    var directory = openDirPath(io, normalized_session_dir, .{ .iterate = true }) catch return null;
    defer directory.close(io);
    var iterator = directory.iterate();

    var best_path: ?[]u8 = null;
    errdefer if (best_path) |path| allocator.free(path);
    var best_mtime: ?std.Io.Timestamp = null;

    while (iterator.next(io) catch return null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const candidate_path = try std.fs.path.join(allocator, &.{ normalized_session_dir, entry.name });
        errdefer allocator.free(candidate_path);

        if (!try sessionHeaderMatchesCwd(allocator, io, candidate_path, resolved_cwd, process_cwd)) {
            allocator.free(candidate_path);
            continue;
        }
        const stat = std.Io.Dir.cwd().statFile(io, candidate_path, .{ .follow_symlinks = true }) catch {
            allocator.free(candidate_path);
            continue;
        };
        if (stat.kind != .file) {
            allocator.free(candidate_path);
            continue;
        }

        const is_newer = best_mtime == null or stat.mtime.nanoseconds > best_mtime.?.nanoseconds;
        if (is_newer) {
            if (best_path) |old_path| allocator.free(old_path);
            best_path = candidate_path;
            best_mtime = stat.mtime;
        } else {
            allocator.free(candidate_path);
        }
    }

    return best_path;
}

fn sessionHeaderMatchesCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    resolved_cwd: ?[]const u8,
    process_cwd: []const u8,
) !bool {
    var file = std.Io.Dir.cwd().openFile(io, file_path, .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch return false;
    defer file.close(io);

    var file_buffer: [512]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    var header_buffer: [512]u8 = undefined;
    const bytes_read = file_reader.interface.readSliceShort(&header_buffer) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
    };
    if (bytes_read == 0) return false;

    const header_chunk = header_buffer[0..bytes_read];
    const line_end = std.mem.indexOfScalar(u8, header_chunk, '\n') orelse header_chunk.len;
    const header_line = header_chunk[0..line_end];
    if (header_line.len == 0) return false;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, header_line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const object = parsed.value.object;
    const entry_type = optionalString(object, "type") orelse return false;
    if (!std.mem.eql(u8, entry_type, "session")) return false;
    _ = optionalString(object, "id") orelse return false;

    const expected_cwd = resolved_cwd orelse return true;
    const header_cwd = optionalString(object, "cwd") orelse return false;
    if (header_cwd.len == 0) return false;
    const resolved_header_cwd = try paths.resolvePathAlloc(allocator, header_cwd, process_cwd, .{});
    defer allocator.free(resolved_header_cwd);
    return std.mem.eql(u8, resolved_header_cwd, expected_cwd);
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

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

fn isoTimestampAlloc(allocator: std.mem.Allocator, timestamp_ms: i64) ![]u8 {
    if (timestamp_ms < 0) return error.InvalidTimestamp;
    const epoch_seconds = std.time.epoch.EpochSeconds{
        .secs = @intCast(@divTrunc(timestamp_ms, std.time.ms_per_s)),
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            @as(u16, @intCast(@mod(timestamp_ms, std.time.ms_per_s))),
        },
    );
}

fn freshHeaderJsonAlloc(allocator: std.mem.Allocator, header: SessionHeader) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("session");
    try json.objectField("version");
    try json.write(header.version.?);
    try json.objectField("id");
    try json.write(header.id);
    try json.objectField("timestamp");
    try json.write(header.timestamp.?);
    try json.objectField("cwd");
    try json.write(header.cwd.?);
    if (header.parent_session) |parent_session| {
        try json.objectField("parentSession");
        try json.write(parent_session);
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn freshSessionFileAlloc(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    timestamp: []const u8,
    id: []const u8,
) ![]u8 {
    const file_timestamp = try allocator.dupe(u8, timestamp);
    std.mem.replaceScalar(u8, file_timestamp, ':', '-');
    std.mem.replaceScalar(u8, file_timestamp, '.', '-');
    const filename = try std.fmt.allocPrint(allocator, "{s}_{s}.jsonl", .{ file_timestamp, id });
    return std.fs.path.join(allocator, &.{ session_dir, filename });
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

fn expectRecoveredSessionFile(allocator: std.mem.Allocator, path: []const u8, session_id: []const u8) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024),
    );
    defer allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    const header_line = lines.next() orelse return error.MissingRecoveredSessionHeader;
    try std.testing.expectEqual(null, lines.next());

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, header_line, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("session", optionalString(object, "type").?);
    try std.testing.expectEqualStrings(session_id, optionalString(object, "id").?);
    try std.testing.expectEqual(current_session_version, optionalU32(object, "version").?);
}

fn expectUuidV7(id: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 36), id.len);
    for (id, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            try std.testing.expectEqual(@as(u8, '-'), byte);
        } else {
            try std.testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));
        }
    }
    try std.testing.expectEqual(@as(u8, '7'), id[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", id[19]) != null);
}

fn expectTimestampedSessionBasename(path: []const u8, id: []const u8) !void {
    const basename = std.fs.path.basename(path);
    try std.testing.expectEqual(@as(?usize, 24), std.mem.indexOfScalar(u8, basename, '_'));
    try std.testing.expectEqual(@as(usize, 24 + 1 + id.len + ".jsonl".len), basename.len);
    const timestamp = basename[0..24];
    for (timestamp, 0..) |byte, index| {
        const expected: ?u8 = switch (index) {
            4, 7, 13, 16, 19 => '-',
            10 => 'T',
            23 => 'Z',
            else => null,
        };
        if (expected) |literal| {
            try std.testing.expectEqual(@as(u8, literal), byte);
        } else {
            try std.testing.expect(std.ascii.isDigit(byte));
        }
    }
    try std.testing.expectEqual(@as(u8, '_'), basename[24]);
    try std.testing.expectEqualStrings(id, basename[25 .. 25 + id.len]);
    try std.testing.expectEqualStrings(".jsonl", basename[25 + id.len ..]);
}

// Ported from packages/coding-agent/src/core/session-manager.ts default directory helpers.
test "default session directories use Bulb agent dir and Pi-compatible cwd encoding" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    const cwd = try std.fs.path.join(allocator, &.{ tmp_path, "project:a", "nested" });
    defer allocator.free(cwd);
    const agent_dir = try std.fs.path.join(allocator, &.{ tmp_path, "agent-root" });
    defer allocator.free(agent_dir);

    const resolved_cwd = try paths.resolvePathAlloc(allocator, cwd, tmp_path, .{});
    defer allocator.free(resolved_cwd);
    const expected_safe_path = try defaultSessionSafePathAlloc(allocator, resolved_cwd);
    defer allocator.free(expected_safe_path);
    const expected_dir = try std.fs.path.join(allocator, &.{ agent_dir, "sessions", expected_safe_path });
    defer allocator.free(expected_dir);

    const default_dir_path = try getDefaultSessionDirPathAlloc(
        allocator,
        std.testing.io,
        cwd,
        agent_dir,
    );
    defer allocator.free(default_dir_path);
    try std.testing.expectEqualStrings(expected_dir, default_dir_path);
    try std.testing.expectEqual(null, std.mem.indexOf(u8, default_dir_path, ".pi"));

    const created_dir = try getDefaultSessionDirAlloc(
        allocator,
        std.testing.io,
        cwd,
        agent_dir,
    );
    defer allocator.free(created_dir);
    try std.testing.expectEqualStrings(default_dir_path, created_dir);
    try std.Io.Dir.cwd().access(std.testing.io, created_dir, .{});

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", tmp_path);
    const env_dir = try getDefaultSessionDirFromEnvAlloc(
        allocator,
        std.testing.io,
        cwd,
        &env,
    );
    defer allocator.free(env_dir);
    const expected_env_prefix = try std.fs.path.join(allocator, &.{ tmp_path, ".bulb", "agent", "sessions" });
    defer allocator.free(expected_env_prefix);
    try std.testing.expect(std.mem.startsWith(u8, env_dir, expected_env_prefix));
    try std.testing.expectEqualStrings(expected_safe_path, std.fs.path.basename(env_dir));
    try std.Io.Dir.cwd().access(std.testing.io, env_dir, .{});
}

test "SessionManager createDefault uses encoded default session directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const cwd = try std.fs.path.join(allocator, &.{ tmp_path, "project" });
    defer allocator.free(cwd);
    const agent_dir = try std.fs.path.join(allocator, &.{ tmp_path, "agent-root" });
    defer allocator.free(agent_dir);

    var session = try SessionManager.createDefault(
        allocator,
        std.testing.io,
        cwd,
        agent_dir,
        .{ .id = "default-dir-session" },
    );
    defer session.deinit();

    const default_dir = try getDefaultSessionDirPathAlloc(
        allocator,
        std.testing.io,
        cwd,
        agent_dir,
    );
    defer allocator.free(default_dir);
    try std.testing.expect(session.isPersisted());
    try std.testing.expect(try session.usesDefaultSessionDir(
        allocator,
        std.testing.io,
        agent_dir,
    ));
    try std.testing.expectEqualStrings(default_dir, session.getSessionDir());
    try std.testing.expectEqualStrings(default_dir, std.fs.path.dirname(session.getSessionFile().?).?);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, session.getSessionFile().?, .{}),
    );
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

test "SessionManager in-memory sessions use custom ids and generate UUIDv7 ids" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    try expectUuidV7(session.getSessionId());
    try std.testing.expectEqualStrings(session.getSessionId(), session.getHeader().?.id);
    try std.testing.expectEqual(null, session.getSessionFile());

    _ = try session.newSession(std.testing.io, .{ .id = "my-custom-id" });
    try std.testing.expectEqualStrings("my-custom-id", session.getSessionId());
    try std.testing.expectEqualStrings("my-custom-id", session.getHeader().?.id);
    try std.testing.expectEqual(@as(usize, 1), session.getFileEntries().len);
    try std.testing.expectEqual(@as(usize, 0), session.getEntries().len);

    _ = try session.newSession(std.testing.io, .{ .id = "abc-123_def.456" });
    try std.testing.expectEqualStrings("abc-123_def.456", session.getSessionId());

    _ = try session.newSession(std.testing.io, .{ .parent_session = "parent.jsonl" });
    try expectUuidV7(session.getSessionId());
    try std.testing.expectEqualStrings("parent.jsonl", session.getHeader().?.parent_session.?);

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
        try std.testing.expectError(
            error.InvalidSessionId,
            session.newSession(std.testing.io, .{ .id = id }),
        );
    }
}

test "SessionManager create uses a custom id in a deferred persisted session path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    var session = try SessionManager.create(
        allocator,
        std.testing.io,
        tmp_path,
        tmp_path,
        .{ .id = "created-session-id" },
    );
    defer session.deinit();

    try std.testing.expectEqualStrings("created-session-id", session.getSessionId());
    try std.testing.expectEqualStrings("created-session-id", session.getHeader().?.id);
    try std.testing.expectEqualStrings(tmp_path, session.getCwd());
    try std.testing.expectEqualStrings(tmp_path, session.getSessionDir());
    const session_file = session.getSessionFile().?;
    try expectTimestampedSessionBasename(session_file, "created-session-id");
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, session_file, .{}),
    );
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

test "findMostRecentSession returns null for empty missing and invalid directories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    try std.testing.expectEqual(null, try findMostRecentSessionAlloc(
        allocator,
        std.testing.io,
        tmp_path,
        null,
    ));

    const missing_dir = try std.fs.path.join(allocator, &.{ tmp_path, "nonexistent" });
    defer allocator.free(missing_dir);
    try std.testing.expectEqual(null, try findMostRecentSessionAlloc(
        allocator,
        std.testing.io,
        missing_dir,
        null,
    ));

    const text_path = try std.fs.path.join(allocator, &.{ tmp_path, "file.txt" });
    defer allocator.free(text_path);
    const json_path = try std.fs.path.join(allocator, &.{ tmp_path, "file.json" });
    defer allocator.free(json_path);
    const invalid_jsonl = try std.fs.path.join(allocator, &.{ tmp_path, "invalid.jsonl" });
    defer allocator.free(invalid_jsonl);
    try writeAbsoluteFile(std.testing.io, text_path, "hello");
    try writeAbsoluteFile(std.testing.io, json_path, "{}");
    try writeAbsoluteFile(std.testing.io, invalid_jsonl, "{\"type\":\"message\"}\n");

    try std.testing.expectEqual(null, try findMostRecentSessionAlloc(
        allocator,
        std.testing.io,
        tmp_path,
        null,
    ));
}

test "findMostRecentSession returns single valid session file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "session.jsonl" });
    defer allocator.free(path);
    try writeAbsoluteFile(
        std.testing.io,
        path,
        "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n",
    );

    const found = (try findMostRecentSessionAlloc(allocator, std.testing.io, tmp_path, null)).?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(path, found);
}

test "findMostRecentSession returns newest modified valid session and skips invalid files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const older = try std.fs.path.join(allocator, &.{ tmp_path, "older.jsonl" });
    defer allocator.free(older);
    const invalid = try std.fs.path.join(allocator, &.{ tmp_path, "invalid.jsonl" });
    defer allocator.free(invalid);
    const newer = try std.fs.path.join(allocator, &.{ tmp_path, "newer.jsonl" });
    defer allocator.free(newer);

    try writeAbsoluteFile(
        std.testing.io,
        older,
        "{\"type\":\"session\",\"id\":\"old\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n",
    );
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try writeAbsoluteFile(std.testing.io, invalid, "{\"type\":\"not-session\"}\n");
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try writeAbsoluteFile(
        std.testing.io,
        newer,
        "{\"type\":\"session\",\"id\":\"new\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n",
    );

    const found = (try findMostRecentSessionAlloc(allocator, std.testing.io, tmp_path, null)).?;
    defer allocator.free(found);
    try std.testing.expectEqualStrings(newer, found);
}

test "findMostRecentSession filters newest session by cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const project_a = try std.fs.path.join(allocator, &.{ tmp_path, "project-a" });
    defer allocator.free(project_a);
    const project_b = try std.fs.path.join(allocator, &.{ tmp_path, "project-b" });
    defer allocator.free(project_b);
    const file_a = try std.fs.path.join(allocator, &.{ tmp_path, "a.jsonl" });
    defer allocator.free(file_a);
    const file_b = try std.fs.path.join(allocator, &.{ tmp_path, "b.jsonl" });
    defer allocator.free(file_b);

    const header_a = try sessionHeaderJsonAlloc(allocator, "a", project_a);
    defer allocator.free(header_a);
    const header_b = try sessionHeaderJsonAlloc(allocator, "b", project_b);
    defer allocator.free(header_b);
    try writeAbsoluteFile(std.testing.io, file_a, header_a);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try writeAbsoluteFile(std.testing.io, file_b, header_b);

    const found_a = (try findMostRecentSessionAlloc(allocator, std.testing.io, tmp_path, project_a)).?;
    defer allocator.free(found_a);
    try std.testing.expectEqualStrings(file_a, found_a);

    const found_b = (try findMostRecentSessionAlloc(allocator, std.testing.io, tmp_path, project_b)).?;
    defer allocator.free(found_b);
    try std.testing.expectEqualStrings(file_b, found_b);
}

test "SessionManager continueRecent scopes custom flat session directories by cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const project_a = try std.fs.path.join(allocator, &.{ tmp_path, "project-a" });
    defer allocator.free(project_a);
    const project_b = try std.fs.path.join(allocator, &.{ tmp_path, "project-b" });
    defer allocator.free(project_b);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project_a);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project_b);
    const file_a = try std.fs.path.join(allocator, &.{ tmp_path, "a.jsonl" });
    defer allocator.free(file_a);
    const file_b = try std.fs.path.join(allocator, &.{ tmp_path, "b.jsonl" });
    defer allocator.free(file_b);

    const header_a = try sessionHeaderJsonAlloc(allocator, "a", project_a);
    defer allocator.free(header_a);
    const header_b = try sessionHeaderJsonAlloc(allocator, "b", project_b);
    defer allocator.free(header_b);
    try writeAbsoluteFile(std.testing.io, file_a, header_a);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try writeAbsoluteFile(std.testing.io, file_b, header_b);

    var continued_a = try SessionManager.continueRecent(
        allocator,
        std.testing.io,
        project_a,
        tmp_path,
    );
    defer continued_a.deinit();
    try std.testing.expectEqualStrings(file_a, continued_a.getSessionFile().?);
    try std.testing.expectEqualStrings("a", continued_a.getSessionId());
    try std.testing.expectEqualStrings(project_a, continued_a.getCwd());
    try std.testing.expectEqualStrings(tmp_path, continued_a.getSessionDir());

    var continued_b = try SessionManager.continueRecent(
        allocator,
        std.testing.io,
        project_b,
        tmp_path,
    );
    defer continued_b.deinit();
    try std.testing.expectEqualStrings(file_b, continued_b.getSessionFile().?);
    try std.testing.expectEqualStrings("b", continued_b.getSessionId());
    try std.testing.expectEqualStrings(project_b, continued_b.getCwd());
}

test "SessionManager continueRecent creates fresh sessions when no recent file exists" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const cwd = try std.fs.path.join(allocator, &.{ tmp_path, "project" });
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, cwd);

    var session = try SessionManager.continueRecent(
        allocator,
        std.testing.io,
        cwd,
        tmp_path,
    );
    defer session.deinit();

    try expectUuidV7(session.getSessionId());
    try std.testing.expectEqualStrings(cwd, session.getCwd());
    try std.testing.expectEqualStrings(tmp_path, session.getSessionDir());
    try std.testing.expectEqualStrings(tmp_path, std.fs.path.dirname(session.getSessionFile().?).?);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, session.getSessionFile().?, .{}),
    );
}

test "SessionManager continueRecentDefault uses encoded default session directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const cwd = try std.fs.path.join(allocator, &.{ tmp_path, "project" });
    defer allocator.free(cwd);
    const agent_dir = try std.fs.path.join(allocator, &.{ tmp_path, "agent-root" });
    defer allocator.free(agent_dir);

    var session = try SessionManager.continueRecentDefault(
        allocator,
        std.testing.io,
        cwd,
        agent_dir,
    );
    defer session.deinit();

    const default_dir = try getDefaultSessionDirPathAlloc(
        allocator,
        std.testing.io,
        cwd,
        agent_dir,
    );
    defer allocator.free(default_dir);
    try std.testing.expect(try session.usesDefaultSessionDir(
        allocator,
        std.testing.io,
        agent_dir,
    ));
    try std.testing.expectEqualStrings(default_dir, session.getSessionDir());
    try std.testing.expectEqualStrings(default_dir, std.fs.path.dirname(session.getSessionFile().?).?);
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

test "SessionManager open recovers existing empty and headerless session files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    const cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "empty.jsonl", .data = "" },
        .{
            .name = "no-header.jsonl",
            .data = "{\"type\":\"message\",\"id\":\"abc\",\"parentId\":\"orphaned\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":\"test\"}}\n",
        },
    };
    for (cases) |case| {
        const path = try std.fs.path.join(allocator, &.{ tmp_path, case.name });
        defer allocator.free(path);
        try writeAbsoluteFile(std.testing.io, path, case.data);

        var manager = try SessionManager.open(allocator, std.testing.io, path, .{
            .session_dir = tmp_path,
        });
        defer manager.deinit();

        try expectUuidV7(manager.getSessionId());
        try std.testing.expectEqualStrings(path, manager.getSessionFile().?);
        try std.testing.expectEqual(current_session_version, manager.getHeader().?.version.?);
        try expectRecoveredSessionFile(allocator, path, manager.getSessionId());
        try std.testing.expectEqual(@as(usize, 0), manager.getEntries().len);
    }
}

test "SessionManager open preserves explicit path and reloads recovered corrupted files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    const explicit_path = try std.fs.path.join(allocator, &.{ tmp_path, "my-session.jsonl" });
    defer allocator.free(explicit_path);
    try writeAbsoluteFile(std.testing.io, explicit_path, "");
    var explicit = try SessionManager.open(allocator, std.testing.io, explicit_path, .{
        .session_dir = tmp_path,
    });
    defer explicit.deinit();
    try std.testing.expectEqualStrings(explicit_path, explicit.getSessionFile().?);
    try expectRecoveredSessionFile(allocator, explicit_path, explicit.getSessionId());

    const corrupted_path = try std.fs.path.join(allocator, &.{ tmp_path, "corrupted.jsonl" });
    defer allocator.free(corrupted_path);
    try writeAbsoluteFile(std.testing.io, corrupted_path, "garbage content\n");
    var first = try SessionManager.open(allocator, std.testing.io, corrupted_path, .{
        .session_dir = tmp_path,
    });
    const recovered_id = try allocator.dupe(u8, first.getSessionId());
    defer allocator.free(recovered_id);
    first.deinit();

    var second = try SessionManager.open(allocator, std.testing.io, corrupted_path, .{
        .session_dir = tmp_path,
    });
    defer second.deinit();
    try std.testing.expectEqualStrings(recovered_id, second.getSessionId());
    try expectRecoveredSessionFile(allocator, corrupted_path, recovered_id);
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
