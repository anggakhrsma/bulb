const std = @import("std");

const node_env = @import("node_env.zig");
const session = @import("session.zig");
const session_storage = @import("session_storage.zig");
const types = @import("types.zig");
const uuid = @import("uuid.zig");

pub const InMemorySession = session.Session(session_storage.InMemorySessionStorage);
pub const JsonlSession = session.Session(session_storage.JsonlSessionStorage);

pub const InMemorySessionCreateOptions = struct {
    id: ?[]const u8 = null,
};

pub const InMemorySessionForkOptions = struct {
    entry_id: ?[]const u8 = null,
    position: session.ForkPosition = .before,
    id: ?[]const u8 = null,
};

pub const JsonlSessionCreateOptions = struct {
    cwd: []const u8,
    id: ?[]const u8 = null,
    parent_session_path: ?[]const u8 = null,
};

pub const JsonlSessionListOptions = struct {
    cwd: ?[]const u8 = null,
};

pub const JsonlSessionForkOptions = struct {
    cwd: []const u8,
    entry_id: ?[]const u8 = null,
    position: session.ForkPosition = .before,
    id: ?[]const u8 = null,
    parent_session_path: ?[]const u8 = null,
};

pub const OwnedSessionMetadataList = struct {
    arena: std.heap.ArenaAllocator,
    items: []types.SessionMetadata,

    pub fn deinit(self: *OwnedSessionMetadataList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedJsonlSessionMetadataList = struct {
    arena: std.heap.ArenaAllocator,
    items: []types.JsonlSessionMetadata,

    pub fn deinit(self: *OwnedJsonlSessionMetadataList) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const InMemorySessionRepo = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    storages: std.ArrayList(*session_storage.InMemorySessionStorage) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) InMemorySessionRepo {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *InMemorySessionRepo) void {
        for (self.storages.items) |storage| {
            storage.deinit();
            self.allocator.destroy(storage);
        }
        self.storages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn create(self: *InMemorySessionRepo, options: InMemorySessionCreateOptions) !InMemorySession {
        const id_storage = try createSessionIdAlloc(self.allocator, self.io, options.id);
        defer self.allocator.free(id_storage);
        const timestamp = try session.createTimestampAlloc(self.allocator, self.io);
        defer self.allocator.free(timestamp);
        const metadata: types.SessionMetadata = .{
            .id = id_storage,
            .created_at = timestamp,
        };
        const storage = try self.allocator.create(session_storage.InMemorySessionStorage);
        errdefer self.allocator.destroy(storage);
        storage.* = try session_storage.InMemorySessionStorage.initAlloc(self.allocator, self.io, .{ .metadata = metadata });
        errdefer storage.deinit();
        try self.storages.append(self.allocator, storage);
        return InMemorySession.init(self.allocator, self.io, storage);
    }

    pub fn open(self: *InMemorySessionRepo, metadata: types.SessionMetadata) !InMemorySession {
        const storage = self.findStorage(metadata.id) orelse return error.SessionNotFound;
        return InMemorySession.init(self.allocator, self.io, storage);
    }

    pub fn listAlloc(self: *InMemorySessionRepo, allocator: std.mem.Allocator) !OwnedSessionMetadataList {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const items = try arena_allocator.alloc(types.SessionMetadata, self.storages.items.len);
        for (self.storages.items, 0..) |storage, index| {
            const metadata = storage.getMetadata();
            items[index] = .{
                .id = try arena_allocator.dupe(u8, metadata.id),
                .created_at = try arena_allocator.dupe(u8, metadata.created_at),
            };
        }
        return .{ .arena = arena, .items = items };
    }

    pub fn delete(self: *InMemorySessionRepo, metadata: types.SessionMetadata) void {
        for (self.storages.items, 0..) |storage, index| {
            if (std.mem.eql(u8, storage.getMetadata().id, metadata.id)) {
                storage.deinit();
                self.allocator.destroy(storage);
                _ = self.storages.orderedRemove(index);
                return;
            }
        }
    }

    pub fn fork(self: *InMemorySessionRepo, source_metadata: types.SessionMetadata, options: InMemorySessionForkOptions) !InMemorySession {
        var source = try self.open(source_metadata);
        const forked_entries = try getEntriesToForkAlloc(
            self.allocator,
            source.getStorage(),
            .{ .entry_id = options.entry_id, .position = options.position },
        );
        defer self.allocator.free(forked_entries);

        const id_storage = try createSessionIdAlloc(self.allocator, self.io, options.id);
        defer self.allocator.free(id_storage);
        const timestamp = try session.createTimestampAlloc(self.allocator, self.io);
        defer self.allocator.free(timestamp);
        const metadata: types.SessionMetadata = .{
            .id = id_storage,
            .created_at = timestamp,
        };

        const storage = try self.allocator.create(session_storage.InMemorySessionStorage);
        errdefer self.allocator.destroy(storage);
        storage.* = try session_storage.InMemorySessionStorage.initAlloc(self.allocator, self.io, .{
            .metadata = metadata,
            .entries = forked_entries,
        });
        errdefer storage.deinit();
        try self.storages.append(self.allocator, storage);
        return InMemorySession.init(self.allocator, self.io, storage);
    }

    fn findStorage(self: *InMemorySessionRepo, id: []const u8) ?*session_storage.InMemorySessionStorage {
        for (self.storages.items) |storage| {
            if (std.mem.eql(u8, storage.getMetadata().id, id)) return storage;
        }
        return null;
    }
};

pub const JsonlSessionRepo = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: types.ExecutionEnv,
    sessions_root_input: []u8,
    sessions_root: ?[]u8 = null,
    storages: std.ArrayList(*session_storage.JsonlSessionStorage) = .empty,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        io: std.Io,
        env: types.ExecutionEnv,
        sessions_root: []const u8,
    ) !JsonlSessionRepo {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .sessions_root_input = try allocator.dupe(u8, sessions_root),
        };
    }

    pub fn deinit(self: *JsonlSessionRepo) void {
        for (self.storages.items) |storage| {
            storage.deinit();
            self.allocator.destroy(storage);
        }
        self.storages.deinit(self.allocator);
        if (self.sessions_root) |root| self.allocator.free(root);
        self.allocator.free(self.sessions_root_input);
        self.* = undefined;
    }

    pub fn create(self: *JsonlSessionRepo, options: JsonlSessionCreateOptions) !JsonlSession {
        const id_storage = try createSessionIdAlloc(self.allocator, self.io, options.id);
        defer self.allocator.free(id_storage);
        const timestamp = try session.createTimestampAlloc(self.allocator, self.io);
        defer self.allocator.free(timestamp);

        const session_dir = try self.getSessionDirAlloc(options.cwd);
        defer self.allocator.free(session_dir);
        _ = try fileSystemValue(void, try self.env.createDir(session_dir, .{ .recursive = true }));

        const file_path = try self.createSessionFilePathAlloc(options.cwd, id_storage, timestamp);
        defer self.allocator.free(file_path);
        const storage = try self.allocator.create(session_storage.JsonlSessionStorage);
        errdefer self.allocator.destroy(storage);
        storage.* = try session_storage.JsonlSessionStorage.create(self.allocator, self.io, self.env, file_path, .{
            .cwd = options.cwd,
            .session_id = id_storage,
            .parent_session_path = options.parent_session_path,
        });
        errdefer storage.deinit();
        try self.storages.append(self.allocator, storage);
        return JsonlSession.init(self.allocator, self.io, storage);
    }

    pub fn open(self: *JsonlSessionRepo, metadata: types.JsonlSessionMetadata) !JsonlSession {
        const exists = try fileSystemValue(bool, try self.env.exists(metadata.path));
        if (!exists) return error.SessionNotFound;
        const storage = try self.allocator.create(session_storage.JsonlSessionStorage);
        errdefer self.allocator.destroy(storage);
        storage.* = try session_storage.JsonlSessionStorage.open(self.allocator, self.io, self.env, metadata.path);
        errdefer storage.deinit();
        try self.storages.append(self.allocator, storage);
        return JsonlSession.init(self.allocator, self.io, storage);
    }

    pub fn listAlloc(self: *JsonlSessionRepo, allocator: std.mem.Allocator, options: JsonlSessionListOptions) !OwnedJsonlSessionMetadataList {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        var sessions: std.ArrayList(types.JsonlSessionMetadata) = .empty;
        errdefer sessions.deinit(arena_allocator);

        if (options.cwd) |cwd| {
            const dir = try self.getSessionDirAlloc(cwd);
            defer self.allocator.free(dir);
            try self.appendSessionsFromDir(arena_allocator, &sessions, dir);
        } else {
            const dirs = try self.listSessionDirsAlloc(self.allocator);
            defer {
                for (dirs) |dir| self.allocator.free(@constCast(dir));
                self.allocator.free(dirs);
            }
            for (dirs) |dir| try self.appendSessionsFromDir(arena_allocator, &sessions, dir);
        }

        std.mem.sort(types.JsonlSessionMetadata, sessions.items, {}, sortJsonlMetadataDesc);
        return .{
            .arena = arena,
            .items = try sessions.toOwnedSlice(arena_allocator),
        };
    }

    pub fn delete(self: *JsonlSessionRepo, metadata: types.JsonlSessionMetadata) !void {
        _ = try fileSystemValue(void, try self.env.remove(metadata.path, .{ .force = true }));
    }

    pub fn fork(self: *JsonlSessionRepo, source_metadata: types.JsonlSessionMetadata, options: JsonlSessionForkOptions) !JsonlSession {
        var source = try self.open(source_metadata);
        const forked_entries = try getEntriesToForkAlloc(
            self.allocator,
            source.getStorage(),
            .{ .entry_id = options.entry_id, .position = options.position },
        );
        defer self.allocator.free(forked_entries);

        const id_storage = try createSessionIdAlloc(self.allocator, self.io, options.id);
        defer self.allocator.free(id_storage);
        const timestamp = try session.createTimestampAlloc(self.allocator, self.io);
        defer self.allocator.free(timestamp);
        const session_dir = try self.getSessionDirAlloc(options.cwd);
        defer self.allocator.free(session_dir);
        _ = try fileSystemValue(void, try self.env.createDir(session_dir, .{ .recursive = true }));
        const file_path = try self.createSessionFilePathAlloc(options.cwd, id_storage, timestamp);
        defer self.allocator.free(file_path);

        const storage = try self.allocator.create(session_storage.JsonlSessionStorage);
        errdefer self.allocator.destroy(storage);
        storage.* = try session_storage.JsonlSessionStorage.create(self.allocator, self.io, self.env, file_path, .{
            .cwd = options.cwd,
            .session_id = id_storage,
            .parent_session_path = options.parent_session_path orelse source_metadata.path,
        });
        errdefer storage.deinit();
        for (forked_entries) |entry| try storage.appendEntry(entry);
        try self.storages.append(self.allocator, storage);
        return JsonlSession.init(self.allocator, self.io, storage);
    }

    fn getSessionsRoot(self: *JsonlSessionRepo) ![]const u8 {
        if (self.sessions_root == null) {
            self.sessions_root = try fileSystemValue([]u8, try self.env.absolutePath(self.allocator, self.sessions_root_input));
        }
        return self.sessions_root.?;
    }

    fn getSessionDirAlloc(self: *JsonlSessionRepo, cwd: []const u8) ![]u8 {
        const root = try self.getSessionsRoot();
        const encoded = try encodeCwdAlloc(self.allocator, cwd);
        defer self.allocator.free(encoded);
        const parts = [_][]const u8{ root, encoded };
        return try fileSystemValue([]u8, try self.env.joinPath(self.allocator, &parts));
    }

    fn createSessionFilePathAlloc(
        self: *JsonlSessionRepo,
        cwd: []const u8,
        session_id: []const u8,
        timestamp: []const u8,
    ) ![]u8 {
        const session_dir = try self.getSessionDirAlloc(cwd);
        defer self.allocator.free(session_dir);
        const safe_timestamp = try timestampForFileNameAlloc(self.allocator, timestamp);
        defer self.allocator.free(safe_timestamp);
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}.jsonl", .{ safe_timestamp, session_id });
        defer self.allocator.free(file_name);
        const parts = [_][]const u8{ session_dir, file_name };
        return try fileSystemValue([]u8, try self.env.joinPath(self.allocator, &parts));
    }

    fn listSessionDirsAlloc(self: *JsonlSessionRepo, allocator: std.mem.Allocator) ![]const []const u8 {
        const sessions_root = try self.getSessionsRoot();
        const exists = try fileSystemValue(bool, try self.env.exists(sessions_root));
        if (!exists) return try allocator.alloc([]const u8, 0);
        const entries = try fileSystemValue([]types.FileInfo, try self.env.listDir(allocator, sessions_root, null));
        defer deinitFileInfoList(allocator, entries);

        var dirs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (dirs.items) |dir| allocator.free(@constCast(dir));
            dirs.deinit(allocator);
        }
        for (entries) |entry| {
            if (entry.kind == .directory) try dirs.append(allocator, try allocator.dupe(u8, entry.path));
        }
        return try dirs.toOwnedSlice(allocator);
    }

    fn appendSessionsFromDir(
        self: *JsonlSessionRepo,
        allocator: std.mem.Allocator,
        sessions: *std.ArrayList(types.JsonlSessionMetadata),
        dir: []const u8,
    ) !void {
        const exists = try fileSystemValue(bool, try self.env.exists(dir));
        if (!exists) return;
        const files = try fileSystemValue([]types.FileInfo, try self.env.listDir(self.allocator, dir, null));
        defer deinitFileInfoList(self.allocator, files);

        for (files) |file| {
            if (file.kind == .directory or !std.mem.endsWith(u8, file.name, ".jsonl")) continue;
            var loaded = session_storage.loadJsonlSessionMetadataAlloc(self.allocator, self.env, file.path) catch |err| switch (err) {
                error.InvalidSession => continue,
                else => |other| return other,
            };
            defer loaded.deinit();
            try sessions.append(allocator, try cloneJsonlMetadata(allocator, loaded.metadata));
        }
    }
};

pub fn createSessionIdAlloc(allocator: std.mem.Allocator, io: std.Io, maybe_id: ?[]const u8) ![]u8 {
    if (maybe_id) |id| return try allocator.dupe(u8, id);
    const generated = uuid.uuidv7(io);
    return try allocator.dupe(u8, &generated);
}

pub fn getEntriesToForkAlloc(
    allocator: std.mem.Allocator,
    storage: anytype,
    options: session.ForkOptions,
) ![]types.SessionTreeEntry {
    const entry_id = options.entry_id orelse {
        const entries = storage.getEntries();
        const copy = try allocator.alloc(types.SessionTreeEntry, entries.len);
        @memcpy(copy, entries);
        return copy;
    };

    const target = storage.getEntry(entry_id) orelse return error.InvalidForkTarget;
    const effective_leaf_id = switch (options.position) {
        .at => target.id,
        .before => blk: {
            if (target.kind != .message or (session.messageRole(target.message_json) orelse .unknown) != .user) {
                return error.InvalidForkTarget;
            }
            break :blk target.parent_id;
        },
    };
    return try storage.getPathToRootAlloc(allocator, effective_leaf_id);
}

pub fn encodeCwdAlloc(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "--");
    const start: usize = if (cwd.len > 0 and (cwd[0] == '/' or cwd[0] == '\\')) 1 else 0;
    for (cwd[start..]) |byte| {
        switch (byte) {
            '/', '\\', ':' => try output.append(allocator, '-'),
            else => try output.append(allocator, byte),
        }
    }
    try output.appendSlice(allocator, "--");
    return try output.toOwnedSlice(allocator);
}

fn timestampForFileNameAlloc(allocator: std.mem.Allocator, timestamp: []const u8) ![]u8 {
    const output = try allocator.dupe(u8, timestamp);
    for (output) |*byte| {
        if (byte.* == ':' or byte.* == '.') byte.* = '-';
    }
    return output;
}

fn fileSystemValue(comptime Value: type, result: types.Result(Value, types.FileError)) !Value {
    return switch (result) {
        .ok => |value| value,
        .err => |file_error| switch (file_error.code) {
            .not_found => error.SessionNotFound,
            else => error.SessionStorage,
        },
    };
}

fn cloneJsonlMetadata(allocator: std.mem.Allocator, metadata: types.JsonlSessionMetadata) !types.JsonlSessionMetadata {
    return .{
        .id = try allocator.dupe(u8, metadata.id),
        .created_at = try allocator.dupe(u8, metadata.created_at),
        .cwd = try allocator.dupe(u8, metadata.cwd),
        .path = try allocator.dupe(u8, metadata.path),
        .parent_session_path = if (metadata.parent_session_path) |path| try allocator.dupe(u8, path) else null,
    };
}

fn deinitFileInfoList(allocator: std.mem.Allocator, entries: []types.FileInfo) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn sortJsonlMetadataDesc(_: void, lhs: types.JsonlSessionMetadata, rhs: types.JsonlSessionMetadata) bool {
    return std.mem.order(u8, lhs.created_at, rhs.created_at) == .gt;
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "agent in-memory session repo opens deletes and forks by metadata" {
    const allocator = std.testing.allocator;
    var repo = InMemorySessionRepo.init(allocator, std.testing.io);
    defer repo.deinit();

    var source = try repo.create(.{ .id = "session-1" });
    const metadata = source.getMetadata();
    const user1_json = try session.userMessageJsonAlloc(allocator, "one");
    defer allocator.free(user1_json);
    const assistant_json = try session.assistantMessageJsonAlloc(allocator, "two");
    defer allocator.free(assistant_json);
    const user2_json = try session.userMessageJsonAlloc(allocator, "three");
    defer allocator.free(user2_json);

    const user1 = try source.appendMessageJson(user1_json);
    const assistant1 = try source.appendMessageJson(assistant_json);
    const user2 = try source.appendMessageJson(user2_json);

    var opened = try repo.open(metadata);
    try std.testing.expectEqualStrings(metadata.id, opened.getMetadata().id);
    var listed = try repo.listAlloc(allocator);
    defer listed.deinit();
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("session-1", listed.items[0].id);

    var fork = try repo.fork(metadata, .{ .entry_id = user2, .id = "session-2" });
    const fork_entries = fork.getEntries();
    try std.testing.expectEqual(@as(usize, 2), fork_entries.len);
    try std.testing.expectEqualStrings(user1, fork_entries[0].id);
    try std.testing.expectEqualStrings(assistant1, fork_entries[1].id);

    var full_fork = try repo.fork(metadata, .{ .id = "session-3" });
    try std.testing.expectEqual(@as(usize, 3), full_fork.getEntries().len);
    repo.delete(metadata);
    try std.testing.expectError(error.SessionNotFound, repo.open(metadata));
}

test "agent JSONL session repo stores sessions below encoded cwd directories and lists by cwd" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    var repo = try JsonlSessionRepo.initAlloc(allocator, io, local.env(), root);
    defer repo.deinit();

    var source = try repo.create(.{ .cwd = "/tmp/my-project", .id = "019de8c2-de29-73e9-ae0c-e134db34c447" });
    var other = try repo.create(.{ .cwd = "/tmp/other-project", .id = "other-session" });
    const metadata = source.getMetadata();
    const other_metadata = other.getMetadata();
    try std.testing.expect(std.mem.indexOf(u8, metadata.path, "--tmp-my-project--") != null);
    try std.testing.expect(std.mem.indexOf(u8, other_metadata.path, "--tmp-other-project--") != null);
    const exists = try local.env().exists(metadata.path);
    try std.testing.expect(switch (exists) {
        .ok => |value| value,
        .err => false,
    });

    var cwd_list = try repo.listAlloc(allocator, .{ .cwd = "/tmp/my-project" });
    defer cwd_list.deinit();
    try std.testing.expectEqual(@as(usize, 1), cwd_list.items.len);
    try std.testing.expectEqualStrings(metadata.id, cwd_list.items[0].id);

    var all = try repo.listAlloc(allocator, .{});
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.items.len);
}

test "agent JSONL session repo opens deletes and forks by metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    var repo = try JsonlSessionRepo.initAlloc(allocator, io, local.env(), root);
    defer repo.deinit();

    var source = try repo.create(.{ .cwd = "/tmp/source", .id = "source-session" });
    const source_metadata = source.getMetadata();
    const user1_json = try session.userMessageJsonAlloc(allocator, "one");
    defer allocator.free(user1_json);
    const assistant_json = try session.assistantMessageJsonAlloc(allocator, "two");
    defer allocator.free(assistant_json);
    const user2_json = try session.userMessageJsonAlloc(allocator, "three");
    defer allocator.free(user2_json);

    const user1 = try source.appendMessageJson(user1_json);
    const assistant1 = try source.appendMessageJson(assistant_json);
    const user2 = try source.appendMessageJson(user2_json);

    var opened = try repo.open(source_metadata);
    try std.testing.expectEqualStrings(source_metadata.id, opened.getMetadata().id);

    var fork = try repo.fork(source_metadata, .{ .cwd = "/tmp/target", .id = "fork-session", .entry_id = user2 });
    const fork_metadata = fork.getMetadata();
    try std.testing.expectEqualStrings("/tmp/target", fork_metadata.cwd);
    try std.testing.expectEqualStrings(source_metadata.path, fork_metadata.parent_session_path.?);
    const fork_entries = fork.getEntries();
    try std.testing.expectEqual(@as(usize, 2), fork_entries.len);
    try std.testing.expectEqualStrings(user1, fork_entries[0].id);
    try std.testing.expectEqualStrings(assistant1, fork_entries[1].id);

    var full_fork = try repo.fork(source_metadata, .{ .cwd = "/tmp/target", .id = "full-fork-session" });
    try std.testing.expectEqual(@as(usize, 3), full_fork.getEntries().len);
    try repo.delete(source_metadata);
    try std.testing.expectError(error.SessionNotFound, repo.open(source_metadata));
}
