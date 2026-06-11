const std = @import("std");

const node_env = @import("node_env.zig");
const types = @import("types.zig");
const uuid = @import("uuid.zig");

pub const SessionStorageError = anyerror;

pub const JsonlSessionCreateOptions = struct {
    cwd: []const u8,
    session_id: []const u8,
    parent_session_path: ?[]const u8 = null,
};

const SessionHeader = struct {
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    parent_session_path: ?[]const u8 = null,
};

pub const OwnedJsonlSessionMetadata = struct {
    arena: std.heap.ArenaAllocator,
    metadata: types.JsonlSessionMetadata,

    pub fn deinit(self: *OwnedJsonlSessionMetadata) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const InMemorySessionStorageOptions = struct {
    entries: []const types.SessionTreeEntry = &.{},
    metadata: ?types.SessionMetadata = null,
};

pub const InMemorySessionStorage = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    metadata: types.SessionMetadata,
    entries: std.ArrayList(types.SessionTreeEntry),
    by_id: std.StringHashMapUnmanaged(usize),
    labels_by_id: std.StringHashMapUnmanaged([]const u8),
    leaf_id: ?[]const u8 = null,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: InMemorySessionStorageOptions,
    ) !InMemorySessionStorage {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const metadata = if (options.metadata) |source|
            try cloneMetadata(arena_allocator, source)
        else
            try createDefaultMetadata(arena_allocator, io);

        var storage = InMemorySessionStorage{
            .arena = arena,
            .io = io,
            .metadata = metadata,
            .entries = .empty,
            .by_id = .empty,
            .labels_by_id = .empty,
            .leaf_id = null,
        };
        errdefer storage.deinit();

        for (options.entries) |entry| {
            const cloned = try cloneEntry(storage.arena.allocator(), entry);
            try storage.indexOwnedEntry(cloned);
        }
        if (storage.leaf_id) |leaf_id| {
            if (!storage.by_id.contains(leaf_id)) return error.InvalidSession;
        }
        return storage;
    }

    pub fn deinit(self: *InMemorySessionStorage) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn getMetadata(self: *const InMemorySessionStorage) types.SessionMetadata {
        return self.metadata;
    }

    pub fn getLeafId(self: *const InMemorySessionStorage) SessionStorageError!?[]const u8 {
        if (self.leaf_id) |leaf_id| {
            if (!self.by_id.contains(leaf_id)) return error.InvalidSession;
        }
        return self.leaf_id;
    }

    pub fn setLeafId(self: *InMemorySessionStorage, leaf_id: ?[]const u8) SessionStorageError!void {
        if (leaf_id) |id| {
            if (!self.by_id.contains(id)) return error.SessionNotFound;
        }
        const entry = try self.leafEntry(leaf_id);
        try self.indexOwnedEntry(entry);
    }

    pub fn createEntryId(self: *InMemorySessionStorage) SessionStorageError![]const u8 {
        return try generateEntryIdAlloc(self.arena.allocator(), self.io, &self.by_id);
    }

    pub fn appendEntry(self: *InMemorySessionStorage, entry: types.SessionTreeEntry) SessionStorageError!void {
        const cloned = try cloneEntry(self.arena.allocator(), entry);
        try self.indexOwnedEntry(cloned);
    }

    pub fn getEntry(self: *const InMemorySessionStorage, id: []const u8) ?types.SessionTreeEntry {
        const index = self.by_id.get(id) orelse return null;
        return self.entries.items[index];
    }

    pub fn findEntriesAlloc(
        self: *const InMemorySessionStorage,
        allocator: std.mem.Allocator,
        kind: types.SessionEntryKind,
    ) ![]types.SessionTreeEntry {
        return findEntriesAllocImpl(allocator, self.entries.items, kind);
    }

    pub fn getLabel(self: *const InMemorySessionStorage, id: []const u8) ?[]const u8 {
        return self.labels_by_id.get(id);
    }

    pub fn getPathToRootAlloc(
        self: *const InMemorySessionStorage,
        allocator: std.mem.Allocator,
        leaf_id: ?[]const u8,
    ) SessionStorageError![]types.SessionTreeEntry {
        return try getPathToRootAllocImpl(allocator, self.entries.items, &self.by_id, leaf_id);
    }

    pub fn getEntries(self: *const InMemorySessionStorage) []const types.SessionTreeEntry {
        return self.entries.items;
    }

    fn leafEntry(self: *InMemorySessionStorage, leaf_id: ?[]const u8) SessionStorageError!types.SessionTreeEntry {
        const id = try self.createEntryId();
        const timestamp = try isoTimestampAlloc(self.arena.allocator(), std.Io.Clock.real.now(self.io).toMilliseconds());
        return .{
            .kind = .leaf,
            .type_name = "leaf",
            .id = id,
            .parent_id = self.leaf_id,
            .timestamp = timestamp,
            .target_id = leaf_id,
        };
    }

    fn indexOwnedEntry(self: *InMemorySessionStorage, entry: types.SessionTreeEntry) !void {
        const index = self.entries.items.len;
        try self.entries.append(self.arena.allocator(), entry);
        try self.by_id.put(self.arena.allocator(), entry.id, index);
        try updateLabelCache(self.arena.allocator(), &self.labels_by_id, entry);
        self.leaf_id = leafIdAfterEntry(entry);
    }
};

pub const JsonlSessionStorage = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    env: types.ExecutionEnv,
    file_path: []const u8,
    metadata: types.JsonlSessionMetadata,
    entries: std.ArrayList(types.SessionTreeEntry),
    by_id: std.StringHashMapUnmanaged(usize),
    labels_by_id: std.StringHashMapUnmanaged([]const u8),
    current_leaf_id: ?[]const u8 = null,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        env: types.ExecutionEnv,
        file_path: []const u8,
    ) !JsonlSessionStorage {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const read_result = try env.readTextFile(allocator, file_path, null);
        const content = try fileSystemValue([]u8, read_result);
        defer allocator.free(content);

        var storage = JsonlSessionStorage{
            .arena = arena,
            .io = io,
            .env = env,
            .file_path = undefined,
            .metadata = undefined,
            .entries = .empty,
            .by_id = .empty,
            .labels_by_id = .empty,
            .current_leaf_id = null,
        };
        errdefer storage.deinit();

        const storage_allocator = storage.arena.allocator();
        storage.file_path = try storage_allocator.dupe(u8, file_path);
        const loaded = try loadJsonlStorage(storage_allocator, file_path, content);
        storage.metadata = try headerToMetadataAlloc(storage_allocator, loaded.header, storage.file_path);
        for (loaded.entries) |entry| try storage.indexOwnedEntry(entry);
        return storage;
    }

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        env: types.ExecutionEnv,
        file_path: []const u8,
        options: JsonlSessionCreateOptions,
    ) !JsonlSessionStorage {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const timestamp = try isoTimestampAlloc(allocator, std.Io.Clock.real.now(io).toMilliseconds());
        defer allocator.free(timestamp);
        const header: SessionHeader = .{
            .id = options.session_id,
            .timestamp = timestamp,
            .cwd = options.cwd,
            .parent_session_path = options.parent_session_path,
        };
        const header_json = try headerJsonAlloc(allocator, header);
        defer allocator.free(header_json);
        const content = try std.fmt.allocPrint(allocator, "{s}\n", .{header_json});
        defer allocator.free(content);
        const write_result = try env.writeFile(file_path, content, null);
        _ = try fileSystemValue(void, write_result);

        const owned_header: SessionHeader = .{
            .id = try arena_allocator.dupe(u8, options.session_id),
            .timestamp = try arena_allocator.dupe(u8, timestamp),
            .cwd = try arena_allocator.dupe(u8, options.cwd),
            .parent_session_path = if (options.parent_session_path) |path|
                try arena_allocator.dupe(u8, path)
            else
                null,
        };
        const owned_path = try arena_allocator.dupe(u8, file_path);
        var storage = JsonlSessionStorage{
            .arena = arena,
            .io = io,
            .env = env,
            .file_path = owned_path,
            .metadata = undefined,
            .entries = .empty,
            .by_id = .empty,
            .labels_by_id = .empty,
            .current_leaf_id = null,
        };
        errdefer storage.deinit();
        storage.metadata = try headerToMetadataAlloc(storage.arena.allocator(), owned_header, owned_path);
        return storage;
    }

    pub fn deinit(self: *JsonlSessionStorage) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn getMetadata(self: *const JsonlSessionStorage) types.JsonlSessionMetadata {
        return self.metadata;
    }

    pub fn getLeafId(self: *const JsonlSessionStorage) SessionStorageError!?[]const u8 {
        if (self.current_leaf_id) |leaf_id| {
            if (!self.by_id.contains(leaf_id)) return error.InvalidSession;
        }
        return self.current_leaf_id;
    }

    pub fn setLeafId(self: *JsonlSessionStorage, leaf_id: ?[]const u8) SessionStorageError!void {
        if (leaf_id) |id| {
            if (!self.by_id.contains(id)) return error.SessionNotFound;
        }
        const entry = try self.leafEntry(leaf_id);
        const json = try entryJsonAlloc(self.arena.allocator(), entry);
        const line = try std.fmt.allocPrint(self.arena.allocator(), "{s}\n", .{json});
        const append_result = try self.env.appendFile(self.file_path, line, null);
        _ = try fileSystemValue(void, append_result);
        try self.indexOwnedEntry(entry);
    }

    pub fn createEntryId(self: *JsonlSessionStorage) SessionStorageError![]const u8 {
        return try generateEntryIdAlloc(self.arena.allocator(), self.io, &self.by_id);
    }

    pub fn appendEntry(self: *JsonlSessionStorage, entry: types.SessionTreeEntry) SessionStorageError!void {
        const json = try entryJsonAlloc(self.arena.allocator(), entry);
        const line = try std.fmt.allocPrint(self.arena.allocator(), "{s}\n", .{json});
        const append_result = try self.env.appendFile(self.file_path, line, null);
        _ = try fileSystemValue(void, append_result);
        const cloned = try cloneEntry(self.arena.allocator(), entry);
        try self.indexOwnedEntry(cloned);
    }

    pub fn getEntry(self: *const JsonlSessionStorage, id: []const u8) ?types.SessionTreeEntry {
        const index = self.by_id.get(id) orelse return null;
        return self.entries.items[index];
    }

    pub fn findEntriesAlloc(
        self: *const JsonlSessionStorage,
        allocator: std.mem.Allocator,
        kind: types.SessionEntryKind,
    ) ![]types.SessionTreeEntry {
        return findEntriesAllocImpl(allocator, self.entries.items, kind);
    }

    pub fn getLabel(self: *const JsonlSessionStorage, id: []const u8) ?[]const u8 {
        return self.labels_by_id.get(id);
    }

    pub fn getPathToRootAlloc(
        self: *const JsonlSessionStorage,
        allocator: std.mem.Allocator,
        leaf_id: ?[]const u8,
    ) SessionStorageError![]types.SessionTreeEntry {
        return try getPathToRootAllocImpl(allocator, self.entries.items, &self.by_id, leaf_id);
    }

    pub fn getEntries(self: *const JsonlSessionStorage) []const types.SessionTreeEntry {
        return self.entries.items;
    }

    fn leafEntry(self: *JsonlSessionStorage, leaf_id: ?[]const u8) SessionStorageError!types.SessionTreeEntry {
        const id = try self.createEntryId();
        const timestamp = try isoTimestampAlloc(self.arena.allocator(), std.Io.Clock.real.now(self.io).toMilliseconds());
        return .{
            .kind = .leaf,
            .type_name = "leaf",
            .id = id,
            .parent_id = self.current_leaf_id,
            .timestamp = timestamp,
            .target_id = leaf_id,
        };
    }

    fn indexOwnedEntry(self: *JsonlSessionStorage, entry: types.SessionTreeEntry) !void {
        const index = self.entries.items.len;
        try self.entries.append(self.arena.allocator(), entry);
        try self.by_id.put(self.arena.allocator(), entry.id, index);
        try updateLabelCache(self.arena.allocator(), &self.labels_by_id, entry);
        self.current_leaf_id = leafIdAfterEntry(entry);
    }
};

pub fn loadJsonlSessionMetadataAlloc(
    allocator: std.mem.Allocator,
    env: types.ExecutionEnv,
    file_path: []const u8,
) !OwnedJsonlSessionMetadata {
    const lines_result = try env.readTextLines(allocator, file_path, .{ .max_lines = 1 });
    const lines = try fileSystemValue([][]u8, lines_result);
    defer freeStringList(allocator, lines);
    if (lines.len == 0 or std.mem.trim(u8, lines[0], " \t\r\n").len == 0) return error.InvalidSession;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const header = try parseHeaderLine(arena.allocator(), lines[0], file_path);
    const path = try arena.allocator().dupe(u8, file_path);
    const metadata = try headerToMetadataAlloc(arena.allocator(), header, path);
    return .{
        .arena = arena,
        .metadata = metadata,
    };
}

pub fn messageEntry(
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    message_json: []const u8,
) types.SessionTreeEntry {
    return .{
        .kind = .message,
        .type_name = "message",
        .id = id,
        .parent_id = parent_id,
        .timestamp = timestamp,
        .message_json = message_json,
    };
}

pub fn labelEntry(
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    target_id: []const u8,
    label: ?[]const u8,
) types.SessionTreeEntry {
    return .{
        .kind = .label,
        .type_name = "label",
        .id = id,
        .parent_id = parent_id,
        .timestamp = timestamp,
        .target_id = target_id,
        .label = label,
    };
}

fn cloneMetadata(allocator: std.mem.Allocator, metadata: types.SessionMetadata) !types.SessionMetadata {
    return .{
        .id = try allocator.dupe(u8, metadata.id),
        .created_at = try allocator.dupe(u8, metadata.created_at),
    };
}

fn createDefaultMetadata(allocator: std.mem.Allocator, io: std.Io) !types.SessionMetadata {
    const id = uuid.uuidv7(io);
    return .{
        .id = try allocator.dupe(u8, &id),
        .created_at = try isoTimestampAlloc(allocator, std.Io.Clock.real.now(io).toMilliseconds()),
    };
}

fn cloneEntry(allocator: std.mem.Allocator, entry: types.SessionTreeEntry) !types.SessionTreeEntry {
    return .{
        .kind = entry.kind,
        .type_name = try allocator.dupe(u8, entry.type_name),
        .id = try allocator.dupe(u8, entry.id),
        .parent_id = try cloneOptionalString(allocator, entry.parent_id),
        .timestamp = try allocator.dupe(u8, entry.timestamp),
        .message_json = try cloneOptionalString(allocator, entry.message_json),
        .thinking_level = try cloneOptionalString(allocator, entry.thinking_level),
        .provider = try cloneOptionalString(allocator, entry.provider),
        .model_id = try cloneOptionalString(allocator, entry.model_id),
        .active_tool_names = try cloneStringListConst(allocator, entry.active_tool_names),
        .summary = try cloneOptionalString(allocator, entry.summary),
        .first_kept_entry_id = try cloneOptionalString(allocator, entry.first_kept_entry_id),
        .tokens_before = entry.tokens_before,
        .details_json = try cloneOptionalString(allocator, entry.details_json),
        .from_hook = entry.from_hook,
        .from_id = try cloneOptionalString(allocator, entry.from_id),
        .custom_type = try cloneOptionalString(allocator, entry.custom_type),
        .data_json = try cloneOptionalString(allocator, entry.data_json),
        .content_json = try cloneOptionalString(allocator, entry.content_json),
        .display = entry.display,
        .target_id = try cloneOptionalString(allocator, entry.target_id),
        .label = try cloneOptionalString(allocator, entry.label),
        .name = try cloneOptionalString(allocator, entry.name),
        .raw_json = try cloneOptionalString(allocator, entry.raw_json),
    };
}

fn cloneOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |actual| try allocator.dupe(u8, actual) else null;
}

fn cloneStringListConst(allocator: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    if (list.len == 0) return &.{};
    const cloned = try allocator.alloc([]const u8, list.len);
    for (list, 0..) |item, index| cloned[index] = try allocator.dupe(u8, item);
    return cloned;
}

fn generateEntryIdAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    by_id: *const std.StringHashMapUnmanaged(usize),
) SessionStorageError![]const u8 {
    for (0..100) |_| {
        const id = uuid.uuidv7(io);
        if (!by_id.contains(id[0..8])) return try allocator.dupe(u8, id[0..8]);
    }
    const id = uuid.uuidv7(io);
    if (!by_id.contains(&id)) return try allocator.dupe(u8, &id);
    return error.EntryIdCollision;
}

fn leafIdAfterEntry(entry: types.SessionTreeEntry) ?[]const u8 {
    return if (entry.kind == .leaf) entry.target_id else entry.id;
}

fn updateLabelCache(
    allocator: std.mem.Allocator,
    labels_by_id: *std.StringHashMapUnmanaged([]const u8),
    entry: types.SessionTreeEntry,
) !void {
    if (entry.kind != .label) return;
    const target_id = entry.target_id orelse return;
    const label = entry.label orelse {
        _ = labels_by_id.remove(target_id);
        return;
    };
    const trimmed = std.mem.trim(u8, label, " \t\r\n");
    if (trimmed.len == 0) {
        _ = labels_by_id.remove(target_id);
    } else {
        try labels_by_id.put(allocator, target_id, label);
    }
}

fn findEntriesAllocImpl(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
    kind: types.SessionEntryKind,
) ![]types.SessionTreeEntry {
    var result: std.ArrayList(types.SessionTreeEntry) = .empty;
    errdefer result.deinit(allocator);
    for (entries) |entry| {
        if (entry.kind == kind) try result.append(allocator, entry);
    }
    return try result.toOwnedSlice(allocator);
}

fn getPathToRootAllocImpl(
    allocator: std.mem.Allocator,
    entries: []const types.SessionTreeEntry,
    by_id: *const std.StringHashMapUnmanaged(usize),
    leaf_id: ?[]const u8,
) SessionStorageError![]types.SessionTreeEntry {
    const start_id = leaf_id orelse return try allocator.alloc(types.SessionTreeEntry, 0);
    var reverse: std.ArrayList(types.SessionTreeEntry) = .empty;
    errdefer reverse.deinit(allocator);

    var current_id: ?[]const u8 = start_id;
    while (current_id) |id| {
        const index = by_id.get(id) orelse return error.SessionNotFound;
        const current = entries[index];
        try reverse.append(allocator, current);
        current_id = current.parent_id;
    }

    const path = try allocator.alloc(types.SessionTreeEntry, reverse.items.len);
    for (reverse.items, 0..) |entry, index| {
        path[path.len - index - 1] = entry;
    }
    reverse.deinit(allocator);
    return path;
}

fn headerToMetadataAlloc(
    allocator: std.mem.Allocator,
    header: SessionHeader,
    path: []const u8,
) !types.JsonlSessionMetadata {
    return .{
        .id = try allocator.dupe(u8, header.id),
        .created_at = try allocator.dupe(u8, header.timestamp),
        .cwd = try allocator.dupe(u8, header.cwd),
        .path = try allocator.dupe(u8, path),
        .parent_session_path = try cloneOptionalString(allocator, header.parent_session_path),
    };
}

fn fileSystemValue(comptime Value: type, result: types.Result(Value, types.FileError)) SessionStorageError!Value {
    return switch (result) {
        .ok => |value| value,
        .err => |file_error| switch (file_error.code) {
            .not_found => error.SessionNotFound,
            else => error.SessionStorage,
        },
    };
}

fn loadJsonlStorage(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    content: []const u8,
) SessionStorageError!struct {
    header: SessionHeader,
    entries: []types.SessionTreeEntry,
} {
    var non_blank_index: usize = 0;
    var maybe_header: ?SessionHeader = null;
    var entries: std.ArrayList(types.SessionTreeEntry) = .empty;

    var iterator = std.mem.splitScalar(u8, content, '\n');
    while (iterator.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        non_blank_index += 1;
        if (maybe_header == null) {
            maybe_header = try parseHeaderLine(allocator, line, file_path);
        } else {
            const entry = try parseEntryLine(allocator, line, file_path, non_blank_index);
            try entries.append(allocator, entry);
        }
    }

    const header = maybe_header orelse return error.InvalidSession;
    return .{
        .header = header,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn parseHeaderLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    file_path: []const u8,
) SessionStorageError!SessionHeader {
    _ = file_path;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSession,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSession;
    const object = parsed.value.object;
    if (!std.mem.eql(u8, optionalString(object, "type") orelse "", "session")) return error.InvalidSession;
    const version = object.get("version") orelse return error.InvalidSession;
    if (!jsonIntegerEquals(version, 3)) return error.InvalidSession;
    const id = requiredString(object, "id") catch return error.InvalidSession;
    if (id.len == 0) return error.InvalidSession;
    const timestamp = requiredString(object, "timestamp") catch return error.InvalidSession;
    if (timestamp.len == 0) return error.InvalidSession;
    const cwd = requiredString(object, "cwd") catch return error.InvalidSession;
    if (cwd.len == 0) return error.InvalidSession;

    const parent_session_path = if (object.get("parentSession")) |parent| blk: {
        if (parent != .string) return error.InvalidSession;
        break :blk parent.string;
    } else null;

    return .{
        .id = try allocator.dupe(u8, id),
        .timestamp = try allocator.dupe(u8, timestamp),
        .cwd = try allocator.dupe(u8, cwd),
        .parent_session_path = try cloneOptionalString(allocator, parent_session_path),
    };
}

fn parseEntryLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    file_path: []const u8,
    line_number: usize,
) SessionStorageError!types.SessionTreeEntry {
    _ = file_path;
    _ = line_number;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidEntry,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEntry;
    const object = parsed.value.object;
    const type_name = requiredString(object, "type") catch return error.InvalidEntry;
    if (type_name.len == 0) return error.InvalidEntry;
    const id = requiredString(object, "id") catch return error.InvalidEntry;
    if (id.len == 0) return error.InvalidEntry;
    const parent_id = parentIdValue(object) catch return error.InvalidEntry;
    const timestamp = requiredString(object, "timestamp") catch return error.InvalidEntry;
    if (timestamp.len == 0) return error.InvalidEntry;

    const kind = entryKindFromTypeName(type_name);
    if (kind == .leaf) {
        const target = object.get("targetId") orelse return error.InvalidEntry;
        if (target != .null and target != .string) return error.InvalidEntry;
    }

    return .{
        .kind = kind,
        .type_name = try allocator.dupe(u8, type_name),
        .id = try allocator.dupe(u8, id),
        .parent_id = try cloneOptionalString(allocator, parent_id),
        .timestamp = try allocator.dupe(u8, timestamp),
        .message_json = try jsonObjectFieldRawAlloc(allocator, object, "message"),
        .thinking_level = try cloneOptionalString(allocator, optionalString(object, "thinkingLevel")),
        .provider = try cloneOptionalString(allocator, optionalString(object, "provider")),
        .model_id = try cloneOptionalString(allocator, optionalString(object, "modelId")),
        .active_tool_names = try stringArrayFieldAlloc(allocator, object, "activeToolNames"),
        .summary = try cloneOptionalString(allocator, optionalString(object, "summary")),
        .first_kept_entry_id = try cloneOptionalString(allocator, optionalString(object, "firstKeptEntryId")),
        .tokens_before = optionalU64(object, "tokensBefore"),
        .details_json = try jsonObjectFieldRawAlloc(allocator, object, "details"),
        .from_hook = optionalBool(object, "fromHook"),
        .from_id = try cloneOptionalString(allocator, optionalString(object, "fromId")),
        .custom_type = try cloneOptionalString(allocator, optionalString(object, "customType")),
        .data_json = try jsonObjectFieldRawAlloc(allocator, object, "data"),
        .content_json = try jsonObjectFieldRawAlloc(allocator, object, "content"),
        .display = optionalBool(object, "display"),
        .target_id = try cloneOptionalString(allocator, optionalStringOrNull(object, "targetId")),
        .label = try cloneOptionalString(allocator, optionalString(object, "label")),
        .name = try cloneOptionalString(allocator, optionalString(object, "name")),
        .raw_json = try allocator.dupe(u8, line),
    };
}

fn entryKindFromTypeName(type_name: []const u8) types.SessionEntryKind {
    if (std.mem.eql(u8, type_name, "message")) return .message;
    if (std.mem.eql(u8, type_name, "thinking_level_change")) return .thinking_level_change;
    if (std.mem.eql(u8, type_name, "model_change")) return .model_change;
    if (std.mem.eql(u8, type_name, "active_tools_change")) return .active_tools_change;
    if (std.mem.eql(u8, type_name, "compaction")) return .compaction;
    if (std.mem.eql(u8, type_name, "branch_summary")) return .branch_summary;
    if (std.mem.eql(u8, type_name, "custom")) return .custom;
    if (std.mem.eql(u8, type_name, "custom_message")) return .custom_message;
    if (std.mem.eql(u8, type_name, "label")) return .label;
    if (std.mem.eql(u8, type_name, "session_info")) return .session_info;
    if (std.mem.eql(u8, type_name, "leaf")) return .leaf;
    return .unknown;
}

fn headerJsonAlloc(allocator: std.mem.Allocator, header: SessionHeader) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("session");
    try json.objectField("version");
    try json.write(@as(u32, 3));
    try json.objectField("id");
    try json.write(header.id);
    try json.objectField("timestamp");
    try json.write(header.timestamp);
    try json.objectField("cwd");
    try json.write(header.cwd);
    if (header.parent_session_path) |parent| {
        try json.objectField("parentSession");
        try json.write(parent);
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn entryJsonAlloc(allocator: std.mem.Allocator, entry: types.SessionTreeEntry) ![]u8 {
    if (entry.raw_json) |raw_json| return try allocator.dupe(u8, raw_json);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try writeCommonEntryFields(&json, entry);

    switch (entry.kind) {
        .message => {
            try json.objectField("message");
            if (entry.message_json) |message_json| {
                try json.beginWriteRaw();
                try output.writer.writeAll(message_json);
                json.endWriteRaw();
            } else {
                try json.write(null);
            }
        },
        .thinking_level_change => if (entry.thinking_level) |level| {
            try json.objectField("thinkingLevel");
            try json.write(level);
        },
        .model_change => {
            if (entry.provider) |provider| {
                try json.objectField("provider");
                try json.write(provider);
            }
            if (entry.model_id) |model_id| {
                try json.objectField("modelId");
                try json.write(model_id);
            }
        },
        .active_tools_change => {
            try json.objectField("activeToolNames");
            try writeStringArray(&json, entry.active_tool_names);
        },
        .compaction => {
            if (entry.summary) |summary| {
                try json.objectField("summary");
                try json.write(summary);
            }
            if (entry.first_kept_entry_id) |first_kept_entry_id| {
                try json.objectField("firstKeptEntryId");
                try json.write(first_kept_entry_id);
            }
            if (entry.tokens_before) |tokens_before| {
                try json.objectField("tokensBefore");
                try json.write(tokens_before);
            }
            try writeOptionalRawJsonField(&json, &output.writer, "details", entry.details_json);
            if (entry.from_hook) |from_hook| {
                try json.objectField("fromHook");
                try json.write(from_hook);
            }
        },
        .branch_summary => {
            if (entry.from_id) |from_id| {
                try json.objectField("fromId");
                try json.write(from_id);
            }
            if (entry.summary) |summary| {
                try json.objectField("summary");
                try json.write(summary);
            }
            try writeOptionalRawJsonField(&json, &output.writer, "details", entry.details_json);
            if (entry.from_hook) |from_hook| {
                try json.objectField("fromHook");
                try json.write(from_hook);
            }
        },
        .custom => {
            if (entry.custom_type) |custom_type| {
                try json.objectField("customType");
                try json.write(custom_type);
            }
            try writeOptionalRawJsonField(&json, &output.writer, "data", entry.data_json);
        },
        .custom_message => {
            if (entry.custom_type) |custom_type| {
                try json.objectField("customType");
                try json.write(custom_type);
            }
            try writeOptionalRawJsonField(&json, &output.writer, "content", entry.content_json);
            try writeOptionalRawJsonField(&json, &output.writer, "details", entry.details_json);
            if (entry.display) |display| {
                try json.objectField("display");
                try json.write(display);
            }
        },
        .label => {
            if (entry.target_id) |target_id| {
                try json.objectField("targetId");
                try json.write(target_id);
            }
            if (entry.label) |label| {
                try json.objectField("label");
                try json.write(label);
            }
        },
        .session_info => if (entry.name) |name| {
            try json.objectField("name");
            try json.write(name);
        },
        .leaf => {
            try json.objectField("targetId");
            if (entry.target_id) |target_id| {
                try json.write(target_id);
            } else {
                try json.write(null);
            }
        },
        .unknown => {},
    }

    try json.endObject();
    return output.toOwnedSlice();
}

fn writeCommonEntryFields(json: *std.json.Stringify, entry: types.SessionTreeEntry) !void {
    try json.objectField("type");
    try json.write(entry.type_name);
    try json.objectField("id");
    try json.write(entry.id);
    try json.objectField("parentId");
    if (entry.parent_id) |parent_id| {
        try json.write(parent_id);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(entry.timestamp);
}

fn writeStringArray(json: *std.json.Stringify, values: []const []const u8) !void {
    try json.beginArray();
    for (values) |value| try json.write(value);
    try json.endArray();
}

fn writeOptionalRawJsonField(
    json: *std.json.Stringify,
    writer: *std.Io.Writer,
    name: []const u8,
    value: ?[]const u8,
) !void {
    if (value) |raw| {
        try json.objectField(name);
        try json.beginWriteRaw();
        try writer.writeAll(raw);
        json.endWriteRaw();
    }
}

fn isoTimestampAlloc(allocator: std.mem.Allocator, timestamp_ms: i64) SessionStorageError![]u8 {
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

fn jsonIntegerEquals(value: std.json.Value, expected: i64) bool {
    return switch (value) {
        .integer => |integer| integer == expected,
        .float => |float| @floor(float) == float and float == @as(f64, @floatFromInt(expected)),
        .number_string => |number| (std.fmt.parseInt(i64, number, 10) catch return false) == expected,
        else => false,
    };
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return if (value == .string) value.string else error.InvalidField;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalStringOrNull(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        .null => null,
        else => null,
    };
}

fn parentIdValue(object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("parentId") orelse return error.InvalidField;
    return switch (value) {
        .string => |string| string,
        .null => null,
        else => error.InvalidField,
    };
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else null,
        .float => |float| if (float >= 0 and @floor(float) == float) @intFromFloat(float) else null,
        .number_string => |number| std.fmt.parseInt(u64, number, 10) catch null,
        else => null,
    };
}

fn jsonObjectFieldRawAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]const u8 {
    const value = object.get(key) orelse return null;
    return try jsonValueToStringAlloc(allocator, value);
}

fn jsonValueToStringAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.write(value);
    return output.toOwnedSlice();
}

fn stringArrayFieldAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]const []const u8 {
    const value = object.get(key) orelse return &.{};
    if (value != .array) return &.{};
    const output = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, index| {
        output[index] = if (item == .string) try allocator.dupe(u8, item.string) else "";
    }
    return output;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn createUserMessageJsonAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .role = "user",
        .content = .{.{
            .type = "text",
            .text = text,
        }},
        .timestamp = @as(i64, 1),
    }, .{});
}

fn createAssistantMessageJsonAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .role = "assistant",
        .content = .{.{
            .type = "text",
            .text = text,
        }},
        .api = "anthropic-messages",
        .provider = "anthropic",
        .model = "claude-sonnet-4-5",
        .usage = .{
            .input = @as(u64, 0),
            .output = @as(u64, 0),
            .cacheRead = @as(u64, 0),
            .cacheWrite = @as(u64, 0),
            .totalTokens = @as(u64, 0),
            .cost = .{
                .input = @as(f64, 0),
                .output = @as(f64, 0),
                .cacheRead = @as(f64, 0),
                .cacheWrite = @as(f64, 0),
                .total = @as(f64, 0),
            },
        },
        .stopReason = "stop",
        .timestamp = @as(i64, 1),
    }, .{});
}

fn unwrap(comptime Value: type, result: anytype) Value {
    return switch (result) {
        .ok => |value| value,
        .err => unreachable,
    };
}

test "agent in-memory session storage returns configured metadata" {
    const allocator = std.testing.allocator;
    const metadata: types.SessionMetadata = .{
        .id = "session-1",
        .created_at = "2026-01-01T00:00:00.000Z",
    };
    var storage = try InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{ .metadata = metadata });
    defer storage.deinit();

    const actual = storage.getMetadata();
    try std.testing.expectEqualStrings(metadata.id, actual.id);
    try std.testing.expectEqualStrings(metadata.created_at, actual.created_at);
}

test "agent in-memory session storage copies entries and persists leaf changes" {
    const allocator = std.testing.allocator;
    const user_json = try createUserMessageJsonAlloc(allocator, "one");
    defer allocator.free(user_json);
    var initial_entries = [_]types.SessionTreeEntry{
        messageEntry("entry-1", null, "2026-01-01T00:00:00.000Z", user_json),
    };
    var storage = try InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{ .entries = &initial_entries });
    defer storage.deinit();

    initial_entries[0].id = "entry-2";
    try std.testing.expectEqualStrings("entry-1", storage.getEntries()[0].id);
    try std.testing.expectEqualStrings("entry-1", (try storage.getLeafId()).?);

    try storage.setLeafId(null);
    try std.testing.expectEqual(@as(?[]const u8, null), try storage.getLeafId());
    const latest = storage.getEntries()[storage.getEntries().len - 1];
    try std.testing.expectEqual(types.SessionEntryKind.leaf, latest.kind);
    try std.testing.expectEqual(@as(?[]const u8, null), latest.target_id);
}

test "agent in-memory session storage rejects invalid leaf ids" {
    var storage = try InMemorySessionStorage.initAlloc(std.testing.allocator, std.testing.io, .{});
    defer storage.deinit();
    try std.testing.expectError(error.SessionNotFound, storage.setLeafId("missing"));
}

test "agent in-memory session storage finds entries by type" {
    const allocator = std.testing.allocator;
    const user_json = try createUserMessageJsonAlloc(allocator, "one");
    defer allocator.free(user_json);
    const initial_entries = [_]types.SessionTreeEntry{
        messageEntry("entry-1", null, "2026-01-01T00:00:00.000Z", user_json),
    };
    var storage = try InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{ .entries = &initial_entries });
    defer storage.deinit();

    const messages = try storage.findEntriesAlloc(allocator, .message);
    defer allocator.free(messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("entry-1", messages[0].id);

    const session_infos = try storage.findEntriesAlloc(allocator, .session_info);
    defer allocator.free(session_infos);
    try std.testing.expectEqual(@as(usize, 0), session_infos.len);
}

test "agent in-memory session storage maintains label lookup" {
    const allocator = std.testing.allocator;
    const user_json = try createUserMessageJsonAlloc(allocator, "one");
    defer allocator.free(user_json);
    const initial_entries = [_]types.SessionTreeEntry{
        messageEntry("entry-1", null, "2026-01-01T00:00:00.000Z", user_json),
    };
    var storage = try InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{ .entries = &initial_entries });
    defer storage.deinit();

    try std.testing.expect(storage.getLabel("entry-1") == null);
    try storage.appendEntry(labelEntry(
        "label-1",
        "entry-1",
        "2026-01-01T00:00:01.000Z",
        "entry-1",
        "checkpoint",
    ));
    try std.testing.expectEqualStrings("checkpoint", storage.getLabel("entry-1").?);
    try storage.appendEntry(labelEntry(
        "label-2",
        "label-1",
        "2026-01-01T00:00:02.000Z",
        "entry-1",
        null,
    ));
    try std.testing.expect(storage.getLabel("entry-1") == null);
}

test "agent in-memory session storage walks paths to root" {
    const allocator = std.testing.allocator;
    const root_json = try createUserMessageJsonAlloc(allocator, "root");
    defer allocator.free(root_json);
    const child_json = try createAssistantMessageJsonAlloc(allocator, "child");
    defer allocator.free(child_json);
    const initial_entries = [_]types.SessionTreeEntry{
        messageEntry("root", null, "2026-01-01T00:00:00.000Z", root_json),
        messageEntry("child", "root", "2026-01-01T00:00:00.000Z", child_json),
    };
    var storage = try InMemorySessionStorage.initAlloc(allocator, std.testing.io, .{ .entries = &initial_entries });
    defer storage.deinit();

    const path = try storage.getPathToRootAlloc(allocator, "child");
    defer allocator.free(path);
    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expectEqualStrings("root", path[0].id);
    try std.testing.expectEqualStrings("child", path[1].id);

    const empty = try storage.getPathToRootAlloc(allocator, null);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "agent JSONL session storage throws for missing files when opening" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env = local.env();
    const file_path = try std.fs.path.join(allocator, &.{ root, "session.jsonl" });
    defer allocator.free(file_path);

    try std.testing.expectError(error.SessionNotFound, JsonlSessionStorage.open(allocator, io, env, file_path));
}

test "agent JSONL session storage writes header on create" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env = local.env();
    const file_path = try std.fs.path.join(allocator, &.{ root, "session.jsonl" });
    defer allocator.free(file_path);

    var storage = try JsonlSessionStorage.create(allocator, io, env, file_path, .{ .cwd = root, .session_id = "session-1" });
    defer storage.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try storage.getLeafId());
    try std.testing.expectEqual(@as(usize, 0), storage.getEntries().len);

    const user_json = try createUserMessageJsonAlloc(allocator, "one");
    defer allocator.free(user_json);
    try storage.appendEntry(messageEntry("user-1", null, "2026-01-01T00:00:00.000Z", user_json));

    const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited);
    defer allocator.free(content);
    var line_count: usize = 0;
    var saw_user = false;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, content, "\n"), '\n');
    while (lines.next()) |line| {
        line_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        if (line_count == 1) try std.testing.expectEqualStrings("session", parsed.value.object.get("type").?.string);
        if (line_count == 2) {
            try std.testing.expectEqualStrings("user-1", parsed.value.object.get("id").?.string);
            saw_user = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);
    try std.testing.expect(saw_user);
}

test "agent JSONL session storage throws for malformed headers and entries" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env = local.env();
    const file_path = try std.fs.path.join(allocator, &.{ root, "session.jsonl" });
    defer allocator.free(file_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "not json\n" });
    try std.testing.expectError(error.InvalidSession, JsonlSessionStorage.open(allocator, io, env, file_path));

    const header = try headerJsonAlloc(allocator, .{
        .id = "session-1",
        .timestamp = "2026-01-01T00:00:00.000Z",
        .cwd = root,
    });
    defer allocator.free(header);
    const user_json = try createUserMessageJsonAlloc(allocator, "one");
    defer allocator.free(user_json);
    const entry_json = try entryJsonAlloc(allocator, messageEntry("entry-1", null, "2026-01-01T00:00:00.000Z", user_json));
    defer allocator.free(entry_json);
    const bad_content = try std.fmt.allocPrint(allocator, "{s}\nnot json\n{s}\n", .{ header, entry_json });
    defer allocator.free(bad_content);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = bad_content });
    try std.testing.expectError(error.InvalidEntry, JsonlSessionStorage.open(allocator, io, env, file_path));
}

test "agent JSONL session storage creates and reads metadata from header" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env = local.env();
    const file_path = try std.fs.path.join(allocator, &.{ root, "session.jsonl" });
    defer allocator.free(file_path);

    var storage = try JsonlSessionStorage.create(allocator, io, env, file_path, .{
        .cwd = root,
        .session_id = "session-1",
        .parent_session_path = "/tmp/parent.jsonl",
    });
    defer storage.deinit();
    const metadata = storage.getMetadata();
    try std.testing.expectEqualStrings("session-1", metadata.id);
    try std.testing.expectEqualStrings(root, metadata.cwd);
    try std.testing.expectEqualStrings(file_path, metadata.path);
    try std.testing.expectEqualStrings("/tmp/parent.jsonl", metadata.parent_session_path.?);

    var loaded = try loadJsonlSessionMetadataAlloc(allocator, env, file_path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings(metadata.id, loaded.metadata.id);
    try std.testing.expectEqualStrings(metadata.created_at, loaded.metadata.created_at);
    try std.testing.expectEqualStrings(metadata.cwd, loaded.metadata.cwd);
    try std.testing.expectEqualStrings(metadata.path, loaded.metadata.path);
    try std.testing.expectEqualStrings(metadata.parent_session_path.?, loaded.metadata.parent_session_path.?);
}

test "agent JSONL session storage loads entries reconstructs leaf and walks paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root_dir);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root_dir, .temp_dir = root_dir });
    defer local.deinit();
    const env = local.env();
    const file_path = try std.fs.path.join(allocator, &.{ root_dir, "session.jsonl" });
    defer allocator.free(file_path);

    var storage = try JsonlSessionStorage.create(allocator, io, env, file_path, .{ .cwd = root_dir, .session_id = "session-1" });
    defer storage.deinit();
    const root_json = try createUserMessageJsonAlloc(allocator, "root");
    defer allocator.free(root_json);
    const child_json = try createAssistantMessageJsonAlloc(allocator, "child");
    defer allocator.free(child_json);
    try storage.appendEntry(messageEntry("root", null, "2026-01-01T00:00:00.000Z", root_json));
    try storage.appendEntry(messageEntry("child", "root", "2026-01-01T00:00:00.000Z", child_json));

    var loaded = try JsonlSessionStorage.open(allocator, io, env, file_path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("child", (try loaded.getLeafId()).?);
    try std.testing.expectEqual(@as(usize, 2), loaded.getEntries().len);
    try std.testing.expectEqualStrings("root", loaded.getEntries()[0].id);
    try std.testing.expectEqualStrings("child", loaded.getEntries()[1].id);

    try loaded.setLeafId("root");
    var reloaded = try JsonlSessionStorage.open(allocator, io, env, file_path);
    defer reloaded.deinit();
    try std.testing.expectEqualStrings("root", (try reloaded.getLeafId()).?);
    const latest = reloaded.getEntries()[reloaded.getEntries().len - 1];
    try std.testing.expectEqual(types.SessionEntryKind.leaf, latest.kind);
    try std.testing.expectEqualStrings("root", latest.target_id.?);

    const path = try loaded.getPathToRootAlloc(allocator, "child");
    defer allocator.free(path);
    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expectEqualStrings("root", path[0].id);
    try std.testing.expectEqualStrings("child", path[1].id);
}

test "agent JSONL session storage finds entries and maintains labels" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try node_env.LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env = local.env();
    const file_path = try std.fs.path.join(allocator, &.{ root, "session.jsonl" });
    defer allocator.free(file_path);

    var storage = try JsonlSessionStorage.create(allocator, io, env, file_path, .{ .cwd = root, .session_id = "session-1" });
    defer storage.deinit();
    const user_json = try createUserMessageJsonAlloc(allocator, "one");
    defer allocator.free(user_json);
    try storage.appendEntry(messageEntry("entry-1", null, "2026-01-01T00:00:00.000Z", user_json));

    const messages = try storage.findEntriesAlloc(allocator, .message);
    defer allocator.free(messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("entry-1", messages[0].id);

    const session_infos = try storage.findEntriesAlloc(allocator, .session_info);
    defer allocator.free(session_infos);
    try std.testing.expectEqual(@as(usize, 0), session_infos.len);

    try std.testing.expect(storage.getLabel("entry-1") == null);
    try storage.appendEntry(labelEntry(
        "label-1",
        "entry-1",
        "2026-01-01T00:00:01.000Z",
        "entry-1",
        "checkpoint",
    ));
    try std.testing.expectEqualStrings("checkpoint", storage.getLabel("entry-1").?);
    try storage.appendEntry(labelEntry(
        "label-2",
        "label-1",
        "2026-01-01T00:00:02.000Z",
        "entry-1",
        null,
    ));
    try std.testing.expect(storage.getLabel("entry-1") == null);

    var loaded = try JsonlSessionStorage.open(allocator, io, env, file_path);
    defer loaded.deinit();
    try std.testing.expect(loaded.getLabel("entry-1") == null);
}

const MetadataOnlyEnv = struct {
    header: []const u8,

    fn env(self: *MetadataOnlyEnv) types.ExecutionEnv {
        return .{
            .ptr = self,
            .cwd = "/tmp",
            .read_text_lines_fn = readTextLines,
            .read_text_file_fn = readTextFile,
        };
    }

    fn readTextLines(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: types.ReadTextLinesOptions,
    ) !types.Result([][]u8, types.FileError) {
        const self: *MetadataOnlyEnv = @ptrCast(@alignCast(ptr.?));
        const lines = try allocator.alloc([]u8, 1);
        lines[0] = try allocator.dupe(u8, self.header);
        return .{ .ok = lines };
    }

    fn readTextFile(
        _: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
        _: ?*const types.AbortSignal,
    ) !types.Result([]u8, types.FileError) {
        return error.ReadTextFileShouldNotBeCalled;
    }
};

test "agent JSONL metadata reads through line-reading filesystem operation" {
    const allocator = std.testing.allocator;
    const header = try headerJsonAlloc(allocator, .{
        .id = "session-1",
        .timestamp = "2026-01-01T00:00:00.000Z",
        .cwd = "/tmp/bulb-session",
    });
    defer allocator.free(header);
    var fake: MetadataOnlyEnv = .{ .header = header };
    var metadata = try loadJsonlSessionMetadataAlloc(allocator, fake.env(), "/tmp/session.jsonl");
    defer metadata.deinit();

    try std.testing.expectEqualStrings("session-1", metadata.metadata.id);
    try std.testing.expectEqualStrings("2026-01-01T00:00:00.000Z", metadata.metadata.created_at);
    try std.testing.expectEqualStrings("/tmp/bulb-session", metadata.metadata.cwd);
    try std.testing.expectEqualStrings("/tmp/session.jsonl", metadata.metadata.path);
    try std.testing.expect(metadata.metadata.parent_session_path == null);
}
