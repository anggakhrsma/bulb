const std = @import("std");
const agent = @import("bulb_agent");
const config = @import("config.zig");
const messages_mod = @import("messages.zig");
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

pub const LabelState = struct {
    label: []u8,
    timestamp: []u8,
};

pub const SessionTreeNode = struct {
    entry: FileEntry,
    children: []*SessionTreeNode,
    label: ?[]const u8 = null,
    label_timestamp: ?[]const u8 = null,
};

pub const SessionTree = struct {
    arena: std.heap.ArenaAllocator,
    roots: []*SessionTreeNode,

    pub fn deinit(self: *SessionTree) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SessionContextModel = struct {
    provider: []const u8,
    model_id: []const u8,
};

pub const SessionContext = struct {
    arena: std.heap.ArenaAllocator,
    messages: []FileEntry,
    thinking_level: []const u8 = "off",
    model: ?SessionContextModel = null,

    pub fn deinit(self: *SessionContext) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SessionInfo = struct {
    path: []const u8,
    id: []const u8,
    cwd: []const u8,
    name: ?[]const u8,
    parent_session_path: ?[]const u8,
    created_ms: i64,
    modified_ms: i64,
    message_count: usize,
    first_message: []const u8,
    all_messages_text: []const u8,
};

pub const SessionInfoList = struct {
    arena: std.heap.ArenaAllocator,
    sessions: []SessionInfo,

    pub fn deinit(self: *SessionInfoList) void {
        self.arena.deinit();
        self.* = undefined;
    }
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
    leaf_id: ?[]const u8,

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
            .leaf_id = findLeafId(loaded.entries),
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
        self.leaf_id = null;
        self.flushed = false;
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

    pub fn getLeafId(self: *const SessionManager) ?[]const u8 {
        return self.leaf_id;
    }

    pub fn getLeafEntry(self: *const SessionManager) ?FileEntry {
        const leaf_id = self.leaf_id orelse return null;
        return self.getEntry(leaf_id);
    }

    pub fn getEntry(self: *const SessionManager, id: []const u8) ?FileEntry {
        for (self.getEntries()) |entry| {
            if (entry.id) |entry_id| {
                if (std.mem.eql(u8, entry_id, id)) return entry;
            }
        }
        return null;
    }

    pub fn getBranchAlloc(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        from_id: ?[]const u8,
    ) ![]FileEntry {
        const start_id = from_id orelse self.leaf_id orelse return allocator.alloc(FileEntry, 0);
        var current = self.getEntry(start_id) orelse return allocator.alloc(FileEntry, 0);
        var reversed: std.ArrayList(FileEntry) = .empty;
        errdefer reversed.deinit(allocator);

        while (true) {
            try reversed.append(allocator, current);
            const parent_id = try entryParentIdAlloc(allocator, current.raw_json);
            defer if (parent_id) |id| allocator.free(id);
            const next_id = parent_id orelse break;
            current = self.getEntry(next_id) orelse break;
        }

        std.mem.reverse(FileEntry, reversed.items);
        return reversed.toOwnedSlice(allocator);
    }

    pub fn branch(self: *SessionManager, branch_from_id: []const u8) !void {
        if (self.getEntry(branch_from_id) == null) return error.EntryNotFound;
        self.leaf_id = branch_from_id;
    }

    pub fn resetLeaf(self: *SessionManager) void {
        self.leaf_id = null;
    }

    pub fn branchWithSummary(
        self: *SessionManager,
        io: std.Io,
        branch_from_id: ?[]const u8,
        summary: []const u8,
    ) ![]const u8 {
        if (branch_from_id) |id| {
            if (self.getEntry(id) == null) return error.EntryNotFound;
        }
        self.leaf_id = branch_from_id;

        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const raw_json = try branchSummaryEntryJsonAlloc(
            arena_allocator,
            entry_id,
            branch_from_id,
            timestamp,
            branch_from_id orelse "root",
            summary,
        );
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "branch_summary",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendMessageJson(
        self: *SessionManager,
        io: std.Io,
        message_json: []const u8,
    ) ![]const u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.child_allocator, message_json, .{});
        defer parsed.deinit();

        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const raw_json = try messageEntryJsonAlloc(arena_allocator, entry_id, self.leaf_id, timestamp, message_json);
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "message",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendSessionInfo(self: *SessionManager, io: std.Io, name: []const u8) ![]const u8 {
        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        const raw_json = try sessionInfoEntryJsonAlloc(arena_allocator, entry_id, self.leaf_id, timestamp, trimmed);
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "session_info",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendCustomEntryJson(
        self: *SessionManager,
        io: std.Io,
        custom_type: []const u8,
        data_json: ?[]const u8,
    ) ![]const u8 {
        if (data_json) |data| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.child_allocator, data, .{});
            defer parsed.deinit();
        }

        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const raw_json = try customEntryJsonAlloc(arena_allocator, entry_id, self.leaf_id, timestamp, custom_type, data_json);
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "custom",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendThinkingLevelChange(
        self: *SessionManager,
        io: std.Io,
        thinking_level: []const u8,
    ) ![]const u8 {
        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const raw_json = try thinkingLevelEntryJsonAlloc(arena_allocator, entry_id, self.leaf_id, timestamp, thinking_level);
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "thinking_level_change",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendModelChange(
        self: *SessionManager,
        io: std.Io,
        provider: []const u8,
        model_id: []const u8,
    ) ![]const u8 {
        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const raw_json = try modelChangeEntryJsonAlloc(arena_allocator, entry_id, self.leaf_id, timestamp, provider, model_id);
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "model_change",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendCompactionJson(
        self: *SessionManager,
        io: std.Io,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        details_json: ?[]const u8,
        from_hook: ?bool,
    ) ![]const u8 {
        if (details_json) |details| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.child_allocator, details, .{});
            defer parsed.deinit();
        }

        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const raw_json = try compactionEntryJsonAlloc(
            arena_allocator,
            entry_id,
            self.leaf_id,
            timestamp,
            summary,
            first_kept_entry_id,
            tokens_before,
            details_json,
            from_hook,
        );
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "compaction",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendCustomMessageEntryJson(
        self: *SessionManager,
        io: std.Io,
        custom_type: []const u8,
        content_json: []const u8,
        display: bool,
        details_json: ?[]const u8,
    ) ![]const u8 {
        {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.child_allocator, content_json, .{});
            defer parsed.deinit();
            switch (parsed.value) {
                .string, .array => {},
                else => return error.InvalidCustomMessageContent,
            }
        }
        if (details_json) |details| {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.arena.child_allocator, details, .{});
            defer parsed.deinit();
        }

        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const raw_json = try customMessageEntryJsonAlloc(
            arena_allocator,
            entry_id,
            self.leaf_id,
            timestamp,
            custom_type,
            content_json,
            display,
            details_json,
        );
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "custom_message",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn appendLabelChange(
        self: *SessionManager,
        io: std.Io,
        target_id: []const u8,
        label: ?[]const u8,
    ) ![]const u8 {
        if (self.getEntry(target_id) == null) return error.EntryNotFound;

        const arena_allocator = self.arena.allocator();
        const entry_id = try generateEntryIdAlloc(arena_allocator, io, self.file_entries);
        errdefer arena_allocator.free(entry_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const normalized_label = if (label) |value| blk: {
            if (value.len == 0) break :blk null;
            break :blk value;
        } else null;
        const raw_json = try labelEntryJsonAlloc(arena_allocator, entry_id, self.leaf_id, timestamp, target_id, normalized_label);
        errdefer arena_allocator.free(raw_json);
        const grown = try arena_allocator.alloc(FileEntry, self.file_entries.len + 1);
        @memcpy(grown[0..self.file_entries.len], self.file_entries);
        grown[self.file_entries.len] = .{
            .raw_json = raw_json,
            .entry_type = "label",
            .id = entry_id,
        };
        self.file_entries = grown;
        self.leaf_id = entry_id;
        try self.persistEntry(io, raw_json);
        return entry_id;
    }

    pub fn getLabelAlloc(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        target_id: []const u8,
    ) !?[]u8 {
        const state = try self.getLabelStateAlloc(allocator, target_id);
        if (state) |value| {
            allocator.free(value.timestamp);
            return value.label;
        }
        return null;
    }

    pub fn getLabelStateAlloc(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        target_id: []const u8,
    ) !?LabelState {
        return latestLabelForIdAlloc(allocator, allocator, self.getEntries(), target_id);
    }

    pub fn getSessionName(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        var index = self.file_entries.len;
        while (index > 1) {
            index -= 1;
            const entry = self.file_entries[index];
            if (entry.entry_type == null or !std.mem.eql(u8, entry.entry_type.?, "session_info")) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            };
            defer parsed.deinit();
            if (parsed.value != .object) return null;
            const name = optionalString(parsed.value.object, "name") orelse return null;
            const trimmed = std.mem.trim(u8, name, " \t\r\n");
            if (trimmed.len == 0) return null;
            return try allocator.dupe(u8, trimmed);
        }
        return null;
    }

    pub fn buildSessionContextAlloc(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
    ) !SessionContext {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const branch_entries = try self.getBranchAlloc(arena_allocator, null);
        var thinking_level: []const u8 = "off";
        var model: ?SessionContextModel = null;
        var compaction_index: ?usize = null;
        for (branch_entries, 0..) |entry, index| {
            if (entryTypeEquals(entry, "thinking_level_change")) {
                thinking_level = (try entryStringFieldAlloc(arena_allocator, entry.raw_json, "thinkingLevel")) orelse "off";
            } else if (entryTypeEquals(entry, "model_change")) {
                const provider = try entryStringFieldAlloc(arena_allocator, entry.raw_json, "provider");
                const model_id = try entryStringFieldAlloc(arena_allocator, entry.raw_json, "modelId");
                if (provider != null and model_id != null) {
                    model = .{ .provider = provider.?, .model_id = model_id.? };
                }
            } else if (entryTypeEquals(entry, "message")) {
                if (try assistantModelAlloc(arena_allocator, arena_allocator, entry.raw_json)) |assistant_model| {
                    model = assistant_model;
                }
            } else if (entryTypeEquals(entry, "compaction")) {
                compaction_index = index;
            }
        }

        var messages: std.ArrayList(FileEntry) = .empty;
        if (compaction_index) |index| {
            const compaction = branch_entries[index];
            try messages.append(arena_allocator, try cloneFileEntry(arena_allocator, compaction));

            const first_kept_entry_id = try entryStringFieldAlloc(arena_allocator, compaction.raw_json, "firstKeptEntryId");
            var found_first_kept = false;
            for (branch_entries[0..index]) |entry| {
                if (first_kept_entry_id) |target_id| {
                    if (entry.id) |entry_id| {
                        if (std.mem.eql(u8, entry_id, target_id)) {
                            found_first_kept = true;
                        }
                    }
                }
                if (found_first_kept) {
                    try appendContextSourceEntryAlloc(arena_allocator, &messages, entry);
                }
            }
            for (branch_entries[index + 1 ..]) |entry| {
                try appendContextSourceEntryAlloc(arena_allocator, &messages, entry);
            }
        } else {
            for (branch_entries) |entry| {
                try appendContextSourceEntryAlloc(arena_allocator, &messages, entry);
            }
        }

        return .{
            .arena = arena,
            .messages = try messages.toOwnedSlice(arena_allocator),
            .thinking_level = thinking_level,
            .model = model,
        };
    }

    pub fn getTreeAlloc(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
    ) !SessionTree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const scratch_allocator = allocator;
        const entries = self.getEntries();

        var by_id = std.StringHashMap(usize).init(scratch_allocator);
        defer by_id.deinit();
        for (entries, 0..) |entry, index| {
            if (entry.id) |id| {
                try by_id.put(id, index);
            }
        }

        var child_counts = try scratch_allocator.alloc(usize, entries.len);
        defer scratch_allocator.free(child_counts);
        @memset(child_counts, 0);
        var root_count: usize = 0;
        for (entries, 0..) |entry, index| {
            const parent_id = try entryParentIdAlloc(scratch_allocator, entry.raw_json);
            defer if (parent_id) |value| scratch_allocator.free(value);
            if (parent_id) |parent| {
                if (entry.id == null or !std.mem.eql(u8, parent, entry.id.?)) {
                    if (by_id.get(parent)) |parent_index| {
                        child_counts[parent_index] += 1;
                        continue;
                    }
                }
            }
            _ = index;
            root_count += 1;
        }

        const nodes = try arena_allocator.alloc(SessionTreeNode, entries.len);
        for (entries, 0..) |entry, index| {
            const label_state = if (entry.id) |id|
                try latestLabelForIdAlloc(arena_allocator, scratch_allocator, entries, id)
            else
                null;
            nodes[index] = .{
                .entry = try cloneFileEntry(arena_allocator, entry),
                .children = try arena_allocator.alloc(*SessionTreeNode, child_counts[index]),
                .label = if (label_state) |state| state.label else null,
                .label_timestamp = if (label_state) |state| state.timestamp else null,
            };
            child_counts[index] = 0;
        }

        const roots = try arena_allocator.alloc(*SessionTreeNode, root_count);
        var root_index: usize = 0;
        for (entries, 0..) |entry, index| {
            const parent_id = try entryParentIdAlloc(scratch_allocator, entry.raw_json);
            defer if (parent_id) |value| scratch_allocator.free(value);
            if (parent_id) |parent| {
                if (entry.id == null or !std.mem.eql(u8, parent, entry.id.?)) {
                    if (by_id.get(parent)) |parent_index| {
                        const write_index = child_counts[parent_index];
                        nodes[parent_index].children[write_index] = &nodes[index];
                        child_counts[parent_index] = write_index + 1;
                        continue;
                    }
                }
            }
            roots[root_index] = &nodes[index];
            root_index += 1;
        }

        return .{
            .arena = arena,
            .roots = roots,
        };
    }

    pub fn createBranchedSession(
        self: *SessionManager,
        io: std.Io,
        leaf_id: []const u8,
    ) !?[]const u8 {
        const scratch_allocator = self.arena.child_allocator;
        const path = try self.getBranchAlloc(scratch_allocator, leaf_id);
        defer scratch_allocator.free(path);
        if (path.len == 0) return error.EntryNotFound;

        var path_without_labels: std.ArrayList(FileEntry) = .empty;
        defer path_without_labels.deinit(scratch_allocator);
        for (path) |entry| {
            if (entryTypeEquals(entry, "label")) continue;
            try path_without_labels.append(scratch_allocator, entry);
        }

        var label_arena = std.heap.ArenaAllocator.init(scratch_allocator);
        defer label_arena.deinit();
        const label_allocator = label_arena.allocator();
        const LabelToWrite = struct {
            target_id: []const u8,
            label: []const u8,
            timestamp: []const u8,
        };
        var labels_to_write: std.ArrayList(LabelToWrite) = .empty;
        for (path_without_labels.items) |entry| {
            const target_id = entry.id orelse continue;
            const label_state = try latestLabelForIdAlloc(
                label_allocator,
                scratch_allocator,
                self.getEntries(),
                target_id,
            ) orelse continue;
            try labels_to_write.append(label_allocator, .{
                .target_id = target_id,
                .label = label_state.label,
                .timestamp = label_state.timestamp,
            });
        }

        var generated_id: [36]u8 = agent.uuid.uuidv7(io);
        const arena_allocator = self.arena.allocator();
        const new_session_id = try arena_allocator.dupe(u8, generated_id[0..]);
        errdefer arena_allocator.free(new_session_id);
        const timestamp = try isoTimestampAlloc(
            arena_allocator,
            std.Io.Clock.real.now(io).toMilliseconds(),
        );
        errdefer arena_allocator.free(timestamp);
        const parent_session = if (self.persist) blk: {
            const previous = self.session_file orelse break :blk null;
            break :blk try arena_allocator.dupe(u8, previous);
        } else null;
        errdefer if (parent_session) |parent| arena_allocator.free(parent);
        const header = SessionHeader{
            .version = current_session_version,
            .id = new_session_id,
            .timestamp = timestamp,
            .cwd = self.cwd,
            .parent_session = parent_session,
        };
        const raw_header = try freshHeaderJsonAlloc(arena_allocator, header);
        errdefer arena_allocator.free(raw_header);

        const new_entries = try arena_allocator.alloc(FileEntry, path_without_labels.items.len + labels_to_write.items.len + 1);
        new_entries[0] = .{
            .raw_json = raw_header,
            .entry_type = "session",
            .id = new_session_id,
        };
        @memcpy(new_entries[1 .. 1 + path_without_labels.items.len], path_without_labels.items);
        var write_index: usize = 1 + path_without_labels.items.len;
        var label_parent_id: ?[]const u8 = if (path_without_labels.items.len > 0)
            path_without_labels.items[path_without_labels.items.len - 1].id
        else
            null;
        for (labels_to_write.items) |label_to_write| {
            const label_id = try generateEntryIdAlloc(arena_allocator, io, new_entries[0..write_index]);
            errdefer arena_allocator.free(label_id);
            const raw_label = try labelEntryJsonAlloc(
                arena_allocator,
                label_id,
                label_parent_id,
                label_to_write.timestamp,
                label_to_write.target_id,
                label_to_write.label,
            );
            errdefer arena_allocator.free(raw_label);
            new_entries[write_index] = .{
                .raw_json = raw_label,
                .entry_type = "label",
                .id = label_id,
            };
            label_parent_id = label_id;
            write_index += 1;
        }

        const new_session_file = if (self.persist)
            try freshSessionFileAlloc(arena_allocator, self.session_dir, timestamp, new_session_id)
        else
            null;
        errdefer if (new_session_file) |file| arena_allocator.free(file);

        self.session_id = new_session_id;
        self.header = header;
        self.file_entries = new_entries;
        self.session_file = new_session_file;
        self.leaf_id = findLeafId(self.file_entries);

        if (self.persist and self.hasAssistantMessage()) {
            try self.rewriteFile(io);
            self.flushed = true;
        } else {
            self.flushed = false;
        }

        return self.session_file;
    }

    pub fn list(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: ?[]const u8,
        agent_dir: []const u8,
    ) !SessionInfoList {
        const dir = if (session_dir) |custom_dir|
            try paths.normalizePathAlloc(allocator, custom_dir, .{})
        else
            try getDefaultSessionDirAlloc(allocator, io, cwd, agent_dir);
        defer allocator.free(dir);

        const default_path = try getDefaultSessionDirPathAlloc(allocator, io, cwd, agent_dir);
        defer allocator.free(default_path);
        const filter_cwd = session_dir != null and !std.mem.eql(u8, dir, default_path);
        const process_cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(process_cwd);
        const resolved_cwd = try paths.resolvePathAlloc(allocator, cwd, process_cwd, .{});
        defer allocator.free(resolved_cwd);

        var list_result = try listSessionsFromDir(allocator, io, dir);
        errdefer list_result.deinit();
        if (filter_cwd) {
            filterSessionInfosByCwd(&list_result, resolved_cwd, process_cwd);
        }
        sortSessionInfos(list_result.sessions);
        return list_result;
    }

    pub fn listAll(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_dir: ?[]const u8,
        agent_dir: []const u8,
    ) !SessionInfoList {
        if (session_dir) |custom_dir| {
            const normalized = try paths.normalizePathAlloc(allocator, custom_dir, .{});
            defer allocator.free(normalized);
            const sessions = try listSessionsFromDir(allocator, io, normalized);
            sortSessionInfos(sessions.sessions);
            return sessions;
        }

        const sessions_root = try std.fs.path.join(allocator, &.{ agent_dir, "sessions" });
        defer allocator.free(sessions_root);
        var directory = openDirPath(io, sessions_root, .{ .iterate = true }) catch {
            return emptySessionInfoList(allocator);
        };
        defer directory.close(io);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        var all: std.ArrayList(SessionInfo) = .empty;
        var iterator = directory.iterate();
        while (true) {
            const maybe_entry = iterator.next(io) catch break;
            const entry = maybe_entry orelse break;
            if (entry.kind != .directory) continue;
            const child_dir = try std.fs.path.join(allocator, &.{ sessions_root, entry.name });
            defer allocator.free(child_dir);
            var child = try listSessionsFromDir(allocator, io, child_dir);
            defer child.deinit();
            for (child.sessions) |info| {
                try all.append(arena_allocator, try cloneSessionInfo(arena_allocator, info));
            }
        }
        const sessions = try all.toOwnedSlice(arena_allocator);
        sortSessionInfos(sessions);
        return .{ .arena = arena, .sessions = sessions };
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
            .leaf_id = null,
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

    fn persistEntry(self: *SessionManager, io: std.Io, raw_json: []const u8) !void {
        if (!self.persist) return;
        const session_file = self.session_file orelse return;
        if (!self.hasAssistantMessage()) {
            if (self.flushed) {
                try appendJsonLine(io, session_file, raw_json);
            } else {
                self.flushed = false;
            }
            return;
        }

        if (!self.flushed) {
            try self.writeFileExclusive(io);
            self.flushed = true;
        } else {
            try appendJsonLine(io, session_file, raw_json);
        }
    }

    fn writeFileExclusive(self: *const SessionManager, io: std.Io) !void {
        const session_file = self.session_file orelse return;
        var file = try std.Io.Dir.cwd().createFile(io, session_file, .{
            .read = false,
            .truncate = false,
            .exclusive = true,
        });
        defer file.close(io);
        var output: std.Io.Writer.Allocating = .init(self.arena.child_allocator);
        defer output.deinit();
        for (self.file_entries) |entry| {
            try output.writer.writeAll(entry.raw_json);
            try output.writer.writeByte('\n');
        }
        try file.writeStreamingAll(io, output.written());
    }

    fn hasAssistantMessage(self: *const SessionManager) bool {
        for (self.file_entries) |entry| {
            if (entry.entry_type == null or !std.mem.eql(u8, entry.entry_type.?, "message")) continue;
            if (messageRoleEquals(self.arena.child_allocator, entry.raw_json, "assistant")) return true;
        }
        return false;
    }
};

pub fn forkFrom(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
    target_cwd: []const u8,
    session_dir: []const u8,
    options: NewSessionOptions,
) !SessionManager {
    if (options.id) |id| try assertValidSessionId(id);

    const process_cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(process_cwd);
    const resolved_source_path = try paths.resolvePathAlloc(allocator, source_path, process_cwd, .{});
    defer allocator.free(resolved_source_path);
    const resolved_target_cwd = try paths.resolvePathAlloc(allocator, target_cwd, process_cwd, .{});
    defer allocator.free(resolved_target_cwd);
    const normalized_session_dir = try paths.normalizePathAlloc(allocator, session_dir, .{});
    defer allocator.free(normalized_session_dir);
    try std.Io.Dir.cwd().createDirPath(io, normalized_session_dir);

    var loaded = try loadEntriesFromFile(allocator, io, resolved_source_path);
    defer loaded.deinit();
    if (loaded.header == null) return error.InvalidSourceSession;

    var generated_id: [36]u8 = undefined;
    const new_session_id = options.id orelse blk: {
        generated_id = agent.uuid.uuidv7(io);
        break :blk generated_id[0..];
    };
    const timestamp = try isoTimestampAlloc(allocator, std.Io.Clock.real.now(io).toMilliseconds());
    defer allocator.free(timestamp);
    const new_session_file = try freshSessionFileAlloc(allocator, normalized_session_dir, timestamp, new_session_id);
    defer allocator.free(new_session_file);
    const header = SessionHeader{
        .version = current_session_version,
        .id = new_session_id,
        .timestamp = timestamp,
        .cwd = resolved_target_cwd,
        .parent_session = resolved_source_path,
    };
    const raw_header = try freshHeaderJsonAlloc(allocator, header);
    defer allocator.free(raw_header);

    {
        var file = try std.Io.Dir.cwd().createFile(io, new_session_file, .{
            .read = false,
            .truncate = false,
            .exclusive = true,
        });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.Writer.init(file, io, &buffer);
        try writer.interface.writeAll(raw_header);
        try writer.interface.writeByte('\n');
        for (loaded.entries[1..]) |entry| {
            try writer.interface.writeAll(entry.raw_json);
            try writer.interface.writeByte('\n');
        }
        try writer.flush();
    }

    return SessionManager.open(allocator, io, new_session_file, .{
        .session_dir = normalized_session_dir,
        .cwd_override = resolved_target_cwd,
    });
}

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

fn emptySessionInfoList(allocator: std.mem.Allocator) !SessionInfoList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const sessions = try arena.allocator().alloc(SessionInfo, 0);
    return .{ .arena = arena, .sessions = sessions };
}

fn listSessionsFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !SessionInfoList {
    var directory = openDirPath(io, dir, .{ .iterate = true }) catch {
        return emptySessionInfoList(allocator);
    };
    defer directory.close(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var sessions: std.ArrayList(SessionInfo) = .empty;
    var iterator = directory.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch break;
        const entry = maybe_entry orelse break;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir, entry.name });
        defer allocator.free(path);
        const info = try buildSessionInfo(arena_allocator, allocator, io, path) orelse continue;
        try sessions.append(arena_allocator, info);
    }
    return .{
        .arena = arena,
        .sessions = try sessions.toOwnedSlice(arena_allocator),
    };
}

fn buildSessionInfo(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) !?SessionInfo {
    const stats = std.Io.Dir.cwd().statFile(io, file_path, .{ .follow_symlinks = true }) catch return null;
    if (stats.kind != .file) return null;

    var loaded = loadEntriesFromFile(scratch_allocator, io, file_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer loaded.deinit();
    const header = loaded.header orelse return null;

    var message_count: usize = 0;
    var first_message: ?[]const u8 = null;
    var all_messages_text: std.ArrayList(u8) = .empty;
    var name: ?[]const u8 = null;
    var last_activity_ms: ?i64 = null;

    for (loaded.entries[1..]) |entry| {
        if (entry.entry_type) |entry_type| {
            if (std.mem.eql(u8, entry_type, "session_info")) {
                name = try sessionInfoNameAlloc(output_allocator, scratch_allocator, entry.raw_json);
                continue;
            }
            if (!std.mem.eql(u8, entry_type, "message")) continue;
        } else {
            continue;
        }

        message_count += 1;
        const inspected = try inspectMessageEntry(output_allocator, scratch_allocator, entry.raw_json);
        if (inspected.activity_ms) |activity_ms| {
            const previous = last_activity_ms orelse 0;
            last_activity_ms = @max(previous, activity_ms);
        }
        const text = inspected.text orelse continue;
        if (text.len == 0) continue;
        if (all_messages_text.items.len > 0) try all_messages_text.append(output_allocator, ' ');
        try all_messages_text.appendSlice(output_allocator, text);
        if (first_message == null and inspected.role == .user) {
            first_message = text;
        }
    }

    const header_ms = if (header.timestamp) |timestamp|
        messages_mod.parseTimestampMs(timestamp) catch null
    else
        null;
    const modified_ms = if (last_activity_ms != null and last_activity_ms.? > 0)
        last_activity_ms.?
    else
        header_ms orelse stats.mtime.toMilliseconds();
    const cwd = if (header.cwd) |cwd_value| cwd_value else "";

    return .{
        .path = try output_allocator.dupe(u8, file_path),
        .id = try output_allocator.dupe(u8, header.id),
        .cwd = try output_allocator.dupe(u8, cwd),
        .name = name,
        .parent_session_path = if (header.parent_session) |parent|
            try output_allocator.dupe(u8, parent)
        else
            null,
        .created_ms = header_ms orelse 0,
        .modified_ms = modified_ms,
        .message_count = message_count,
        .first_message = if (first_message) |message|
            message
        else
            try output_allocator.dupe(u8, "(no messages)"),
        .all_messages_text = try all_messages_text.toOwnedSlice(output_allocator),
    };
}

const MessageRole = enum { user, assistant, other };

const MessageInspection = struct {
    role: MessageRole = .other,
    text: ?[]const u8 = null,
    activity_ms: ?i64 = null,
};

fn inspectMessageEntry(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    raw_json: []const u8,
) !MessageInspection {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{},
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const entry_object = parsed.value.object;
    const message_value = entry_object.get("message") orelse return .{};
    if (message_value != .object) return .{};
    const message_object = message_value.object;
    const role = roleFromString(optionalString(message_object, "role"));
    if (role == .other) return .{ .role = role };

    const content_value = message_object.get("content") orelse return .{ .role = role };
    const activity_ms = valueToI64(message_object.get("timestamp")) orelse blk: {
        const entry_timestamp = optionalString(entry_object, "timestamp") orelse break :blk null;
        break :blk messages_mod.parseTimestampMs(entry_timestamp) catch null;
    };
    return .{
        .role = role,
        .text = try extractTextContentAlloc(output_allocator, content_value),
        .activity_ms = activity_ms,
    };
}

fn roleFromString(role: ?[]const u8) MessageRole {
    const value = role orelse return .other;
    if (std.mem.eql(u8, value, "user")) return .user;
    if (std.mem.eql(u8, value, "assistant")) return .assistant;
    return .other;
}

fn valueToI64(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |integer| std.math.cast(i64, integer),
        .float => |float| {
            if (!std.math.isFinite(float)) return null;
            if (float < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                float > @as(f64, @floatFromInt(std.math.maxInt(i64))))
            {
                return null;
            }
            return @intFromFloat(float);
        },
        else => null,
    };
}

fn extractTextContentAlloc(
    allocator: std.mem.Allocator,
    content_value: std.json.Value,
) !?[]const u8 {
    switch (content_value) {
        .string => |text| {
            if (text.len == 0) return null;
            return try allocator.dupe(u8, text);
        },
        .array => |array| {
            var joined: std.ArrayList(u8) = .empty;
            for (array.items) |block| {
                if (block != .object) continue;
                const block_object = block.object;
                const block_type = optionalString(block_object, "type") orelse continue;
                if (!std.mem.eql(u8, block_type, "text")) continue;
                const text = optionalString(block_object, "text") orelse continue;
                if (text.len == 0) continue;
                if (joined.items.len > 0) try joined.append(allocator, ' ');
                try joined.appendSlice(allocator, text);
            }
            if (joined.items.len == 0) return null;
            return try joined.toOwnedSlice(allocator);
        },
        else => return null,
    }
}

fn sessionInfoNameAlloc(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    raw_json: []const u8,
) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const name = optionalString(parsed.value.object, "name") orelse return null;
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try output_allocator.dupe(u8, trimmed);
}

fn filterSessionInfosByCwd(
    list: *SessionInfoList,
    resolved_cwd: []const u8,
    process_cwd: []const u8,
) void {
    var write_index: usize = 0;
    const scratch_allocator = list.arena.child_allocator;
    for (list.sessions) |info| {
        if (sessionCwdMatchesAlloc(scratch_allocator, info.cwd, resolved_cwd, process_cwd)) {
            list.sessions[write_index] = info;
            write_index += 1;
        }
    }
    list.sessions = list.sessions[0..write_index];
}

fn sessionCwdMatchesAlloc(
    scratch_allocator: std.mem.Allocator,
    cwd: []const u8,
    resolved_cwd: []const u8,
    process_cwd: []const u8,
) bool {
    if (cwd.len == 0) return false;
    const resolved = paths.resolvePathAlloc(scratch_allocator, cwd, process_cwd, .{}) catch return false;
    defer scratch_allocator.free(resolved);
    return std.mem.eql(u8, resolved, resolved_cwd);
}

fn sortSessionInfos(sessions: []SessionInfo) void {
    std.mem.sort(SessionInfo, sessions, {}, struct {
        fn lessThan(_: void, lhs: SessionInfo, rhs: SessionInfo) bool {
            return lhs.modified_ms > rhs.modified_ms;
        }
    }.lessThan);
}

fn cloneSessionInfo(allocator: std.mem.Allocator, info: SessionInfo) !SessionInfo {
    return .{
        .path = try allocator.dupe(u8, info.path),
        .id = try allocator.dupe(u8, info.id),
        .cwd = try allocator.dupe(u8, info.cwd),
        .name = if (info.name) |name| try allocator.dupe(u8, name) else null,
        .parent_session_path = if (info.parent_session_path) |parent| try allocator.dupe(u8, parent) else null,
        .created_ms = info.created_ms,
        .modified_ms = info.modified_ms,
        .message_count = info.message_count,
        .first_message = try allocator.dupe(u8, info.first_message),
        .all_messages_text = try allocator.dupe(u8, info.all_messages_text),
    };
}

fn cloneFileEntry(allocator: std.mem.Allocator, entry: FileEntry) !FileEntry {
    return .{
        .raw_json = try allocator.dupe(u8, entry.raw_json),
        .entry_type = if (entry.entry_type) |entry_type|
            try allocator.dupe(u8, entry_type)
        else
            null,
        .id = if (entry.id) |id| try allocator.dupe(u8, id) else null,
    };
}

fn appendContextSourceEntryAlloc(
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(FileEntry),
    entry: FileEntry,
) !void {
    if (!entryParticipatesInContext(entry)) return;
    try messages.append(allocator, try cloneFileEntry(allocator, entry));
}

fn entryParticipatesInContext(entry: FileEntry) bool {
    return entryTypeEquals(entry, "message") or
        entryTypeEquals(entry, "custom_message") or
        entryTypeEquals(entry, "branch_summary");
}

fn assistantModelAlloc(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    raw_json: []const u8,
) !?SessionContextModel {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const message_value = parsed.value.object.get("message") orelse return null;
    if (message_value != .object) return null;
    const message = message_value.object;
    const role = optionalString(message, "role") orelse return null;
    if (!std.mem.eql(u8, role, "assistant")) return null;
    const provider = optionalString(message, "provider") orelse return null;
    const model_id = optionalString(message, "model") orelse return null;
    return .{
        .provider = try output_allocator.dupe(u8, provider),
        .model_id = try output_allocator.dupe(u8, model_id),
    };
}

fn latestLabelForIdAlloc(
    output_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    entries: []const FileEntry,
    target_id: []const u8,
) !?LabelState {
    var latest: ?LabelState = null;
    errdefer if (latest) |state| {
        output_allocator.free(state.label);
        output_allocator.free(state.timestamp);
    };

    for (entries) |entry| {
        if (!entryTypeEquals(entry, "label")) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, entry.raw_json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        const current_target = optionalString(object, "targetId") orelse continue;
        if (!std.mem.eql(u8, current_target, target_id)) continue;

        if (latest) |state| {
            output_allocator.free(state.label);
            output_allocator.free(state.timestamp);
            latest = null;
        }

        const label = optionalString(object, "label") orelse continue;
        if (label.len == 0) continue;
        const timestamp = optionalString(object, "timestamp") orelse "";
        latest = .{
            .label = try output_allocator.dupe(u8, label),
            .timestamp = try output_allocator.dupe(u8, timestamp),
        };
    }

    return latest;
}

fn findLeafId(entries: []const FileEntry) ?[]const u8 {
    var index = entries.len;
    while (index > 1) {
        index -= 1;
        const entry = entries[index];
        if (entry.entry_type) |entry_type| {
            if (!std.mem.eql(u8, entry_type, "session")) {
                return entry.id;
            }
        }
    }
    return null;
}

fn entryIdExists(entries: []const FileEntry, id: []const u8) bool {
    for (entries) |entry| {
        if (entry.id) |entry_id| {
            if (std.mem.eql(u8, entry_id, id)) return true;
        }
    }
    return false;
}

fn generateEntryIdAlloc(allocator: std.mem.Allocator, io: std.Io, entries: []const FileEntry) ![]u8 {
    for (0..100) |_| {
        const uuid = agent.uuid.uuidv7(io);
        const encoded = uuid[24..32];
        if (!entryIdExists(entries, encoded)) return allocator.dupe(u8, encoded);
    }
    return error.EntryIdCollision;
}

fn messageEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    message_json: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("message");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.objectField("message");
    try json.beginWriteRaw();
    try output.writer.writeAll(message_json);
    json.endWriteRaw();
    try json.endObject();
    return output.toOwnedSlice();
}

fn sessionInfoEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    name: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("session_info");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.objectField("name");
    try json.write(name);
    try json.endObject();
    return output.toOwnedSlice();
}

fn customEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    custom_type: []const u8,
    data_json: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("custom");
    try json.objectField("customType");
    try json.write(custom_type);
    if (data_json) |data| {
        try json.objectField("data");
        try json.beginWriteRaw();
        try output.writer.writeAll(data);
        json.endWriteRaw();
    }
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.endObject();
    return output.toOwnedSlice();
}

fn thinkingLevelEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    thinking_level: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("thinking_level_change");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.objectField("thinkingLevel");
    try json.write(thinking_level);
    try json.endObject();
    return output.toOwnedSlice();
}

fn modelChangeEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    provider: []const u8,
    model_id: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("model_change");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.objectField("provider");
    try json.write(provider);
    try json.objectField("modelId");
    try json.write(model_id);
    try json.endObject();
    return output.toOwnedSlice();
}

fn compactionEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    details_json: ?[]const u8,
    from_hook: ?bool,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("compaction");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.objectField("summary");
    try json.write(summary);
    try json.objectField("firstKeptEntryId");
    try json.write(first_kept_entry_id);
    try json.objectField("tokensBefore");
    try json.write(tokens_before);
    if (details_json) |details| {
        try json.objectField("details");
        try json.beginWriteRaw();
        try output.writer.writeAll(details);
        json.endWriteRaw();
    }
    if (from_hook) |value| {
        try json.objectField("fromHook");
        try json.write(value);
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn customMessageEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    custom_type: []const u8,
    content_json: []const u8,
    display: bool,
    details_json: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("custom_message");
    try json.objectField("customType");
    try json.write(custom_type);
    try json.objectField("content");
    try json.beginWriteRaw();
    try output.writer.writeAll(content_json);
    json.endWriteRaw();
    try json.objectField("display");
    try json.write(display);
    if (details_json) |details| {
        try json.objectField("details");
        try json.beginWriteRaw();
        try output.writer.writeAll(details);
        json.endWriteRaw();
    }
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.endObject();
    return output.toOwnedSlice();
}

fn labelEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    target_id: []const u8,
    label: ?[]const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("label");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.objectField("targetId");
    try json.write(target_id);
    if (label) |value| {
        try json.objectField("label");
        try json.write(value);
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn branchSummaryEntryJsonAlloc(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    from_id: []const u8,
    summary: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("type");
    try json.write("branch_summary");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("parentId");
    if (parent_id) |parent| {
        try json.write(parent);
    } else {
        try json.write(null);
    }
    try json.objectField("timestamp");
    try json.write(timestamp);
    try json.objectField("fromId");
    try json.write(from_id);
    try json.objectField("summary");
    try json.write(summary);
    try json.endObject();
    return output.toOwnedSlice();
}

fn appendJsonLine(io: std.Io, path: []const u8, raw_json: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .write_only,
        .allow_directory = false,
    });
    defer file.close(io);
    const stats = try file.stat(io);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(file, io, &buffer);
    try writer.seekTo(stats.size);
    try writer.interface.writeAll(raw_json);
    try writer.interface.writeByte('\n');
    try writer.flush();
}

fn messageRoleEquals(
    scratch_allocator: std.mem.Allocator,
    raw_json: []const u8,
    expected: []const u8,
) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, raw_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const message_value = parsed.value.object.get("message") orelse return false;
    if (message_value != .object) return false;
    const role = optionalString(message_value.object, "role") orelse return false;
    return std.mem.eql(u8, role, expected);
}

fn entryTypeEquals(entry: FileEntry, expected: []const u8) bool {
    const entry_type = entry.entry_type orelse return false;
    return std.mem.eql(u8, entry_type, expected);
}

fn entryParentIdAlloc(allocator: std.mem.Allocator, raw_json: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    return optionalStringDup(allocator, parsed.value.object, "parentId");
}

fn entryStringFieldAlloc(allocator: std.mem.Allocator, raw_json: []const u8, field: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    return optionalStringDup(allocator, parsed.value.object, field);
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
    defer allocator.free(file_timestamp);
    std.mem.replaceScalar(u8, file_timestamp, ':', '-');
    std.mem.replaceScalar(u8, file_timestamp, '.', '-');
    const filename = try std.fmt.allocPrint(allocator, "{s}_{s}.jsonl", .{ file_timestamp, id });
    defer allocator.free(filename);
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

fn testUserMessageJsonAlloc(allocator: std.mem.Allocator, content: []const u8, timestamp_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("role");
    try json.write("user");
    try json.objectField("content");
    try json.write(content);
    try json.objectField("timestamp");
    try json.write(timestamp_ms);
    try json.endObject();
    return output.toOwnedSlice();
}

fn testAssistantMessageJsonAlloc(allocator: std.mem.Allocator, content: []const u8, timestamp_ms: i64) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("role");
    try json.write("assistant");
    try json.objectField("content");
    try json.beginArray();
    try json.beginObject();
    try json.objectField("type");
    try json.write("text");
    try json.objectField("text");
    try json.write(content);
    try json.endObject();
    try json.endArray();
    try json.objectField("timestamp");
    try json.write(timestamp_ms);
    try json.objectField("api");
    try json.write("anthropic-messages");
    try json.objectField("provider");
    try json.write("anthropic");
    try json.objectField("model");
    try json.write("claude-test");
    try json.endObject();
    return output.toOwnedSlice();
}

fn createPersistedTestSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    cwd: []const u8,
    label: []const u8,
    name: ?[]const u8,
) ![]u8 {
    var session = try SessionManager.create(allocator, io, cwd, session_dir, .{});
    defer session.deinit();

    const started = std.Io.Clock.real.now(io).toMilliseconds();
    const user_json = try testUserMessageJsonAlloc(allocator, label, started);
    defer allocator.free(user_json);
    _ = try session.appendMessageJson(io, user_json);

    if (name) |session_name| {
        _ = try session.appendSessionInfo(io, session_name);
    }

    const reply = try std.fmt.allocPrint(allocator, "reply to {s}", .{label});
    defer allocator.free(reply);
    const assistant_json = try testAssistantMessageJsonAlloc(allocator, reply, started + 1);
    defer allocator.free(assistant_json);
    _ = try session.appendMessageJson(io, assistant_json);

    const session_file = session.getSessionFile().?;
    try std.Io.Dir.cwd().access(io, session_file, .{});
    return allocator.dupe(u8, session_file);
}

fn expectEntryParent(
    allocator: std.mem.Allocator,
    entry: FileEntry,
    expected_parent: ?[]const u8,
) !void {
    const parent = try entryParentIdAlloc(allocator, entry.raw_json);
    defer if (parent) |value| allocator.free(value);
    if (expected_parent) |expected| {
        try std.testing.expectEqualStrings(expected, parent.?);
    } else {
        try std.testing.expectEqual(null, parent);
    }
}

fn expectOneHeaderAndUniqueEntryIds(allocator: std.mem.Allocator, path: []const u8) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(content);

    var seen_ids = std.StringHashMap(void).init(allocator);
    defer seen_ids.deinit();
    var session_headers: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, content, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const object = parsed.value.object;
        const entry_type = optionalString(object, "type") orelse continue;
        if (std.mem.eql(u8, entry_type, "session")) {
            session_headers += 1;
            continue;
        }
        const id = optionalString(object, "id") orelse continue;
        try std.testing.expect(!seen_ids.contains(id));
        try seen_ids.put(id, {});
    }
    try std.testing.expectEqual(@as(usize, 1), session_headers);
}

fn findEntryByType(entries: []const FileEntry, entry_type: []const u8) ?FileEntry {
    for (entries) |entry| {
        if (entryTypeEquals(entry, entry_type)) return entry;
    }
    return null;
}

fn findEntryById(entries: []const FileEntry, id: []const u8) ?FileEntry {
    for (entries) |entry| {
        if (entry.id) |entry_id| {
            if (std.mem.eql(u8, entry_id, id)) return entry;
        }
    }
    return null;
}

fn countEntriesByType(entries: []const FileEntry, entry_type: []const u8) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (entryTypeEquals(entry, entry_type)) count += 1;
    }
    return count;
}

fn findTreeNodeById(nodes: []*SessionTreeNode, id: []const u8) ?*SessionTreeNode {
    for (nodes) |node| {
        if (node.entry.id) |entry_id| {
            if (std.mem.eql(u8, entry_id, id)) return node;
        }
        if (findTreeNodeById(node.children, id)) |found| return found;
    }
    return null;
}

fn expectEntryStringField(
    allocator: std.mem.Allocator,
    entry: FileEntry,
    field: []const u8,
    expected: []const u8,
) !void {
    const value = try entryStringFieldAlloc(allocator, entry.raw_json, field);
    defer allocator.free(value.?);
    try std.testing.expectEqualStrings(expected, value.?);
}

fn expectEntryU64Field(
    allocator: std.mem.Allocator,
    entry: FileEntry,
    field: []const u8,
    expected: u64,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const value = parsed.value.object.get(field) orelse return error.MissingField;
    try std.testing.expect(value == .integer);
    try std.testing.expectEqual(expected, @as(u64, @intCast(value.integer)));
}

fn expectMessageText(
    allocator: std.mem.Allocator,
    entry: FileEntry,
    expected: []const u8,
) !void {
    const inspected = try inspectMessageEntry(allocator, allocator, entry.raw_json);
    const text = inspected.text orelse return error.MissingMessageText;
    defer allocator.free(text);
    try std.testing.expectEqualStrings(expected, text);
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

test "SessionManager createBranchedSession generates UUIDv7 ids" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const user_json = try testUserMessageJsonAlloc(allocator, "hello", 1);
    defer allocator.free(user_json);
    const first_id = try session.appendMessageJson(std.testing.io, user_json);

    try std.testing.expectEqual(null, try session.createBranchedSession(std.testing.io, first_id));
    try expectUuidV7(session.getSessionId());
    try std.testing.expectEqualStrings(session.getSessionId(), session.getHeader().?.id);
}

test "SessionManager forkFrom generates and accepts custom ids" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const source_path = try std.fs.path.join(allocator, &.{ tmp_path, "source.jsonl" });
    defer allocator.free(source_path);
    const header = try sessionHeaderJsonAlloc(allocator, "source-session-id", tmp_path);
    defer allocator.free(header);
    try writeAbsoluteFile(std.testing.io, source_path, header);

    var generated = try forkFrom(
        allocator,
        std.testing.io,
        source_path,
        tmp_path,
        tmp_path,
        .{},
    );
    defer generated.deinit();
    try expectUuidV7(generated.getSessionId());
    try std.testing.expectEqualStrings(source_path, generated.getHeader().?.parent_session.?);

    var custom = try forkFrom(
        allocator,
        std.testing.io,
        source_path,
        tmp_path,
        tmp_path,
        .{ .id = "forked-session-id" },
    );
    defer custom.deinit();
    try std.testing.expectEqualStrings("forked-session-id", custom.getSessionId());
    try std.testing.expectEqualStrings("forked-session-id", custom.getHeader().?.id);
    try std.testing.expectEqualStrings(source_path, custom.getHeader().?.parent_session.?);
    try expectTimestampedSessionBasename(custom.getSessionFile().?, "forked-session-id");
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

test "loadEntriesFromFile opens sparse session files larger than one read buffer" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const path = try std.fs.path.join(allocator, &.{ tmp_path, "large.jsonl" });
    defer allocator.free(path);
    try writeAbsoluteFile(
        std.testing.io,
        path,
        "{\"type\":\"session\",\"version\":3,\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n",
    );

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{
            .mode = .write_only,
            .allow_directory = false,
        });
        defer file.close(std.testing.io);
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.Writer.init(file, std.testing.io, &buffer);
        const stride: u64 = 2 * 1024 * 1024;
        const final_offset: u64 = stride * 8;
        var offset: u64 = stride;
        while (offset <= final_offset) : (offset += stride) {
            try writer.seekTo(offset);
            try writer.interface.writeByte('\n');
        }
        try writer.seekTo(final_offset + 1);
        try writer.interface.writeAll(
            "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n",
        );
        try writer.flush();
    }

    var loaded = try loadEntriesFromFile(allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try std.testing.expectEqualStrings("abc", loaded.header.?.id);
    try std.testing.expectEqualStrings("message", loaded.entries[1].entry_type.?);
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

test "SessionManager custom flat session directory scopes current-folder APIs while listing all flat sessions" {
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

    const session_a = try createPersistedTestSession(
        allocator,
        std.testing.io,
        tmp_path,
        project_a,
        "from A",
        "  A session  ",
    );
    defer allocator.free(session_a);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    const session_b = try createPersistedTestSession(
        allocator,
        std.testing.io,
        tmp_path,
        project_b,
        "from B",
        null,
    );
    defer allocator.free(session_b);

    var current_a = try SessionManager.list(
        allocator,
        std.testing.io,
        project_a,
        tmp_path,
        tmp_path,
    );
    defer current_a.deinit();
    try std.testing.expectEqual(@as(usize, 1), current_a.sessions.len);
    try std.testing.expectEqualStrings(session_a, current_a.sessions[0].path);
    try std.testing.expectEqualStrings(project_a, current_a.sessions[0].cwd);
    try std.testing.expectEqualStrings("A session", current_a.sessions[0].name.?);
    try std.testing.expectEqual(@as(usize, 2), current_a.sessions[0].message_count);
    try std.testing.expectEqualStrings("from A", current_a.sessions[0].first_message);
    try std.testing.expectEqualStrings("from A reply to from A", current_a.sessions[0].all_messages_text);

    var all = try SessionManager.listAll(
        allocator,
        std.testing.io,
        tmp_path,
        tmp_path,
    );
    defer all.deinit();
    try std.testing.expectEqual(@as(usize, 2), all.sessions.len);
    var saw_a = false;
    var saw_b = false;
    for (all.sessions) |info| {
        if (std.mem.eql(u8, info.path, session_a)) saw_a = true;
        if (std.mem.eql(u8, info.path, session_b)) saw_b = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);

    var continued_a = try SessionManager.continueRecent(
        allocator,
        std.testing.io,
        project_a,
        tmp_path,
    );
    defer continued_a.deinit();
    try std.testing.expectEqualStrings(session_a, continued_a.getSessionFile().?);
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

// Ported from packages/coding-agent/test/session-manager/tree-traversal.test.ts branch/fork cases.
test "SessionManager branches update leaf and parent chains" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const first_json = try testUserMessageJsonAlloc(allocator, "first", 1);
    defer allocator.free(first_json);
    const second_json = try testAssistantMessageJsonAlloc(allocator, "second", 2);
    defer allocator.free(second_json);
    const third_json = try testUserMessageJsonAlloc(allocator, "third", 3);
    defer allocator.free(third_json);
    const branch_json = try testUserMessageJsonAlloc(allocator, "branched", 4);
    defer allocator.free(branch_json);

    const id1 = try session.appendMessageJson(std.testing.io, first_json);
    const id2 = try session.appendMessageJson(std.testing.io, second_json);
    const id3 = try session.appendMessageJson(std.testing.io, third_json);
    try std.testing.expectEqualStrings(id3, session.getLeafId().?);

    try session.branch(id1);
    try std.testing.expectEqualStrings(id1, session.getLeafId().?);
    const branched_id = try session.appendMessageJson(std.testing.io, branch_json);
    const branched = session.getEntry(branched_id) orelse return error.MissingBranchedEntry;
    try expectEntryParent(allocator, branched, id1);

    const branch = try session.getBranchAlloc(allocator, branched_id);
    defer allocator.free(branch);
    try std.testing.expectEqual(@as(usize, 2), branch.len);
    try std.testing.expectEqualStrings(id1, branch[0].id.?);
    try std.testing.expectEqualStrings(branched_id, branch[1].id.?);

    const original_branch = try session.getBranchAlloc(allocator, id2);
    defer allocator.free(original_branch);
    try std.testing.expectEqual(@as(usize, 2), original_branch.len);
    try std.testing.expectEqualStrings(id1, original_branch[0].id.?);
    try std.testing.expectEqualStrings(id2, original_branch[1].id.?);

    try std.testing.expectError(error.EntryNotFound, session.branch("nonexistent"));
}

test "SessionManager branchWithSummary appends summary under branch point" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const first_json = try testUserMessageJsonAlloc(allocator, "first", 1);
    defer allocator.free(first_json);
    const second_json = try testAssistantMessageJsonAlloc(allocator, "second", 2);
    defer allocator.free(second_json);
    const id1 = try session.appendMessageJson(std.testing.io, first_json);
    _ = try session.appendMessageJson(std.testing.io, second_json);

    const summary_id = try session.branchWithSummary(std.testing.io, id1, "Summary of abandoned work");
    try std.testing.expectEqualStrings(summary_id, session.getLeafId().?);
    const summary_entry = session.getEntry(summary_id) orelse return error.MissingSummaryEntry;
    try std.testing.expect(entryTypeEquals(summary_entry, "branch_summary"));
    try expectEntryParent(allocator, summary_entry, id1);

    const from_id = try entryStringFieldAlloc(allocator, summary_entry.raw_json, "fromId");
    defer allocator.free(from_id.?);
    try std.testing.expectEqualStrings(id1, from_id.?);
    const summary = try entryStringFieldAlloc(allocator, summary_entry.raw_json, "summary");
    defer allocator.free(summary.?);
    try std.testing.expectEqualStrings("Summary of abandoned work", summary.?);
    try std.testing.expectError(
        error.EntryNotFound,
        session.branchWithSummary(std.testing.io, "nonexistent", "summary"),
    );
}

test "SessionManager append setting and compaction entries integrate into tree" {
    const allocator = std.testing.allocator;

    {
        var session = try SessionManager.inMemory(allocator, std.testing.io, null);
        defer session.deinit();

        const user_json = try testUserMessageJsonAlloc(allocator, "hello", 1);
        defer allocator.free(user_json);
        const assistant_json = try testAssistantMessageJsonAlloc(allocator, "response", 2);
        defer allocator.free(assistant_json);

        const msg_id = try session.appendMessageJson(std.testing.io, user_json);
        const thinking_id = try session.appendThinkingLevelChange(std.testing.io, "high");
        _ = try session.appendMessageJson(std.testing.io, assistant_json);

        const entries = session.getEntries();
        try std.testing.expectEqual(@as(usize, 3), entries.len);
        const thinking_entry = findEntryByType(entries, "thinking_level_change") orelse return error.MissingThinkingEntry;
        try std.testing.expectEqualStrings(thinking_id, thinking_entry.id.?);
        try expectEntryParent(allocator, thinking_entry, msg_id);
        try expectEntryStringField(allocator, thinking_entry, "thinkingLevel", "high");
        try expectEntryParent(allocator, entries[2], thinking_id);
    }

    {
        var session = try SessionManager.inMemory(allocator, std.testing.io, null);
        defer session.deinit();

        const user_json = try testUserMessageJsonAlloc(allocator, "hello", 1);
        defer allocator.free(user_json);
        const assistant_json = try testAssistantMessageJsonAlloc(allocator, "response", 2);
        defer allocator.free(assistant_json);

        const msg_id = try session.appendMessageJson(std.testing.io, user_json);
        const model_id = try session.appendModelChange(std.testing.io, "openai", "gpt-4");
        _ = try session.appendMessageJson(std.testing.io, assistant_json);

        const entries = session.getEntries();
        const model_entry = findEntryByType(entries, "model_change") orelse return error.MissingModelEntry;
        try std.testing.expectEqualStrings(model_id, model_entry.id.?);
        try expectEntryParent(allocator, model_entry, msg_id);
        try expectEntryStringField(allocator, model_entry, "provider", "openai");
        try expectEntryStringField(allocator, model_entry, "modelId", "gpt-4");
        try expectEntryParent(allocator, entries[2], model_id);
    }

    {
        var session = try SessionManager.inMemory(allocator, std.testing.io, null);
        defer session.deinit();

        const first_json = try testUserMessageJsonAlloc(allocator, "1", 1);
        defer allocator.free(first_json);
        const second_json = try testAssistantMessageJsonAlloc(allocator, "2", 2);
        defer allocator.free(second_json);
        const third_json = try testUserMessageJsonAlloc(allocator, "3", 3);
        defer allocator.free(third_json);

        const id1 = try session.appendMessageJson(std.testing.io, first_json);
        const id2 = try session.appendMessageJson(std.testing.io, second_json);
        const compaction_id = try session.appendCompactionJson(std.testing.io, "summary", id1, 1000, "{\"kind\":\"test\"}", true);
        _ = try session.appendMessageJson(std.testing.io, third_json);

        const entries = session.getEntries();
        const compaction_entry = findEntryByType(entries, "compaction") orelse return error.MissingCompactionEntry;
        try std.testing.expectEqualStrings(compaction_id, compaction_entry.id.?);
        try expectEntryParent(allocator, compaction_entry, id2);
        try expectEntryStringField(allocator, compaction_entry, "summary", "summary");
        try expectEntryStringField(allocator, compaction_entry, "firstKeptEntryId", id1);
        try expectEntryU64Field(allocator, compaction_entry, "tokensBefore", 1000);
        try expectEntryParent(allocator, entries[3], compaction_id);
    }
}

test "SessionManager buildSessionContext resolves settings summaries and custom messages" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const msg1 = try testUserMessageJsonAlloc(allocator, "first", 1);
    defer allocator.free(msg1);
    const msg2 = try testAssistantMessageJsonAlloc(allocator, "response1", 2);
    defer allocator.free(msg2);
    const msg3 = try testUserMessageJsonAlloc(allocator, "second", 3);
    defer allocator.free(msg3);
    const msg4 = try testAssistantMessageJsonAlloc(allocator, "response2", 4);
    defer allocator.free(msg4);
    const msg5 = try testUserMessageJsonAlloc(allocator, "third", 5);
    defer allocator.free(msg5);

    _ = try session.appendMessageJson(std.testing.io, msg1);
    _ = try session.appendModelChange(std.testing.io, "openai", "gpt-4");
    _ = try session.appendThinkingLevelChange(std.testing.io, "high");
    _ = try session.appendMessageJson(std.testing.io, msg2);
    const kept_id = try session.appendMessageJson(std.testing.io, msg3);
    _ = try session.appendCustomEntryJson(std.testing.io, "hidden_state", "{\"ignored\":true}");
    _ = try session.appendCustomMessageEntryJson(
        std.testing.io,
        "visible_context",
        "\"extension says hi\"",
        false,
        "{\"source\":\"test\"}",
    );
    _ = try session.appendMessageJson(std.testing.io, msg4);
    _ = try session.appendCompactionJson(std.testing.io, "Summary of first two turns", kept_id, 1000, null, null);
    _ = try session.appendMessageJson(std.testing.io, msg5);

    var context = try session.buildSessionContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expectEqualStrings("high", context.thinking_level);
    try std.testing.expect(context.model != null);
    try std.testing.expectEqualStrings("anthropic", context.model.?.provider);
    try std.testing.expectEqualStrings("claude-test", context.model.?.model_id);
    try std.testing.expectEqual(@as(usize, 5), context.messages.len);
    try std.testing.expect(entryTypeEquals(context.messages[0], "compaction"));
    try expectEntryStringField(allocator, context.messages[0], "summary", "Summary of first two turns");
    try expectMessageText(allocator, context.messages[1], "second");
    try std.testing.expect(entryTypeEquals(context.messages[2], "custom_message"));
    try expectEntryStringField(allocator, context.messages[2], "customType", "visible_context");
    try expectMessageText(allocator, context.messages[3], "response2");
    try expectMessageText(allocator, context.messages[4], "third");
}

test "SessionManager buildSessionContext includes branch summaries and follows current branch" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const msg1 = try testUserMessageJsonAlloc(allocator, "start", 1);
    defer allocator.free(msg1);
    const msg2 = try testAssistantMessageJsonAlloc(allocator, "response", 2);
    defer allocator.free(msg2);
    const wrong = try testUserMessageJsonAlloc(allocator, "abandoned path", 3);
    defer allocator.free(wrong);
    const resumed = try testUserMessageJsonAlloc(allocator, "new direction", 4);
    defer allocator.free(resumed);

    _ = try session.appendMessageJson(std.testing.io, msg1);
    const response_id = try session.appendMessageJson(std.testing.io, msg2);
    _ = try session.appendMessageJson(std.testing.io, wrong);
    const summary_id = try session.branchWithSummary(std.testing.io, response_id, "Summary of abandoned work");
    _ = try session.appendMessageJson(std.testing.io, resumed);

    var context = try session.buildSessionContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try expectMessageText(allocator, context.messages[0], "start");
    try expectMessageText(allocator, context.messages[1], "response");
    try std.testing.expect(entryTypeEquals(context.messages[2], "branch_summary"));
    try std.testing.expectEqualStrings(summary_id, context.messages[2].id.?);
    try expectEntryStringField(allocator, context.messages[2], "summary", "Summary of abandoned work");
    try expectMessageText(allocator, context.messages[3], "new direction");
}

test "SessionManager createBranchedSession extracts selected path in memory" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const msg1 = try testUserMessageJsonAlloc(allocator, "1", 1);
    defer allocator.free(msg1);
    const msg2 = try testAssistantMessageJsonAlloc(allocator, "2", 2);
    defer allocator.free(msg2);
    const msg3 = try testUserMessageJsonAlloc(allocator, "3", 3);
    defer allocator.free(msg3);
    const msg4 = try testAssistantMessageJsonAlloc(allocator, "4", 4);
    defer allocator.free(msg4);
    const msg5 = try testUserMessageJsonAlloc(allocator, "5", 5);
    defer allocator.free(msg5);

    const id1 = try session.appendMessageJson(std.testing.io, msg1);
    const id2 = try session.appendMessageJson(std.testing.io, msg2);
    const id3 = try session.appendMessageJson(std.testing.io, msg3);
    _ = try session.appendMessageJson(std.testing.io, msg4);
    try session.branch(id3);
    const id5 = try session.appendMessageJson(std.testing.io, msg5);

    try std.testing.expectEqual(null, try session.createBranchedSession(std.testing.io, id5));
    const entries = session.getEntries();
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings(id1, entries[0].id.?);
    try std.testing.expectEqualStrings(id2, entries[1].id.?);
    try std.testing.expectEqualStrings(id3, entries[2].id.?);
    try std.testing.expectEqualStrings(id5, entries[3].id.?);
}

test "SessionManager createBranchedSession defers or writes forked files by assistant presence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    var session = try SessionManager.create(allocator, std.testing.io, tmp_path, tmp_path, .{});
    defer session.deinit();
    const first_question = try testUserMessageJsonAlloc(allocator, "first question", 1);
    defer allocator.free(first_question);
    const first_answer = try testAssistantMessageJsonAlloc(allocator, "first answer", 2);
    defer allocator.free(first_answer);
    const second_question = try testUserMessageJsonAlloc(allocator, "second question", 3);
    defer allocator.free(second_question);
    const second_answer = try testAssistantMessageJsonAlloc(allocator, "second answer", 4);
    defer allocator.free(second_answer);
    const new_answer = try testAssistantMessageJsonAlloc(allocator, "new answer", 5);
    defer allocator.free(new_answer);

    const id1 = try session.appendMessageJson(std.testing.io, first_question);
    const id2 = try session.appendMessageJson(std.testing.io, first_answer);
    _ = try session.appendMessageJson(std.testing.io, second_question);
    _ = try session.appendMessageJson(std.testing.io, second_answer);

    const assistant_file = (try session.createBranchedSession(std.testing.io, id2)).?;
    try std.Io.Dir.cwd().access(std.testing.io, assistant_file, .{});
    try expectOneHeaderAndUniqueEntryIds(allocator, assistant_file);

    const user_only_file = (try session.createBranchedSession(std.testing.io, id1)).?;
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, user_only_file, .{}),
    );
    _ = try session.appendSessionInfo(std.testing.io, "preset state");
    _ = try session.appendMessageJson(std.testing.io, new_answer);
    try std.Io.Dir.cwd().access(std.testing.io, user_only_file, .{});
    try expectOneHeaderAndUniqueEntryIds(allocator, user_only_file);
}

// Ported from packages/coding-agent/test/session-manager/save-entry.test.ts.
test "SessionManager appendCustomEntryJson saves custom entries and skips them in context" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const user_json = try testUserMessageJsonAlloc(allocator, "hello", 1);
    defer allocator.free(user_json);
    const msg_id = try session.appendMessageJson(std.testing.io, user_json);
    const custom_id = try session.appendCustomEntryJson(std.testing.io, "my_data", "{\"foo\":\"bar\"}");
    const assistant_json = try testAssistantMessageJsonAlloc(allocator, "hi", 2);
    defer allocator.free(assistant_json);
    const msg2_id = try session.appendMessageJson(std.testing.io, assistant_json);

    const entries = session.getEntries();
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    const custom_entry = findEntryByType(entries, "custom") orelse return error.MissingCustomEntry;
    try std.testing.expectEqualStrings(custom_id, custom_entry.id.?);
    try expectEntryStringField(allocator, custom_entry, "customType", "my_data");
    try expectEntryParent(allocator, custom_entry, msg_id);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, custom_entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const data = parsed.value.object.get("data") orelse return error.MissingCustomData;
    try std.testing.expect(data == .object);
    try std.testing.expectEqualStrings("bar", optionalString(data.object, "foo").?);

    const branch = try session.getBranchAlloc(allocator, null);
    defer allocator.free(branch);
    try std.testing.expectEqual(@as(usize, 3), branch.len);
    try std.testing.expectEqualStrings(msg_id, branch[0].id.?);
    try std.testing.expectEqualStrings(custom_id, branch[1].id.?);
    try std.testing.expectEqualStrings(msg2_id, branch[2].id.?);

    var context = try session.buildSessionContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expect(entryTypeEquals(context.messages[0], "message"));
    try std.testing.expect(entryTypeEquals(context.messages[1], "message"));
}

// Ported from packages/coding-agent/test/session-manager/labels.test.ts.
test "SessionManager labels set clear and last label wins" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const user_json = try testUserMessageJsonAlloc(allocator, "hello", 1);
    defer allocator.free(user_json);
    const msg_id = try session.appendMessageJson(std.testing.io, user_json);

    try std.testing.expectEqual(null, try session.getLabelAlloc(allocator, msg_id));

    const first_label_id = try session.appendLabelChange(std.testing.io, msg_id, "checkpoint");
    const first_label = (try session.getLabelAlloc(allocator, msg_id)).?;
    defer allocator.free(first_label);
    try std.testing.expectEqualStrings("checkpoint", first_label);

    const first_label_entry = findEntryById(session.getEntries(), first_label_id) orelse return error.MissingLabelEntry;
    try expectEntryStringField(allocator, first_label_entry, "targetId", msg_id);
    try expectEntryStringField(allocator, first_label_entry, "label", "checkpoint");

    _ = try session.appendLabelChange(std.testing.io, msg_id, null);
    try std.testing.expectEqual(null, try session.getLabelAlloc(allocator, msg_id));

    _ = try session.appendLabelChange(std.testing.io, msg_id, "first");
    _ = try session.appendLabelChange(std.testing.io, msg_id, "second");
    const last_label_id = try session.appendLabelChange(std.testing.io, msg_id, "third");
    const last_label = (try session.getLabelAlloc(allocator, msg_id)).?;
    defer allocator.free(last_label);
    try std.testing.expectEqualStrings("third", last_label);

    const last_label_entry = findEntryById(session.getEntries(), last_label_id) orelse return error.MissingLabelEntry;
    const last_timestamp = try entryStringFieldAlloc(allocator, last_label_entry.raw_json, "timestamp");
    defer allocator.free(last_timestamp.?);
    var tree = try session.getTreeAlloc(allocator);
    defer tree.deinit();
    const msg_node = findTreeNodeById(tree.roots, msg_id) orelse return error.MissingMessageNode;
    try std.testing.expectEqualStrings("third", msg_node.label.?);
    try std.testing.expectEqualStrings(last_timestamp.?, msg_node.label_timestamp.?);
}

test "SessionManager labels annotate tree nodes and are skipped in context" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const msg1_json = try testUserMessageJsonAlloc(allocator, "hello", 1);
    defer allocator.free(msg1_json);
    const msg2_json = try testAssistantMessageJsonAlloc(allocator, "hi", 2);
    defer allocator.free(msg2_json);
    const msg1_id = try session.appendMessageJson(std.testing.io, msg1_json);
    const msg2_id = try session.appendMessageJson(std.testing.io, msg2_json);
    const msg1_label_id = try session.appendLabelChange(std.testing.io, msg1_id, "start");
    const msg2_label_id = try session.appendLabelChange(std.testing.io, msg2_id, "response");

    const msg1_label_entry = findEntryById(session.getEntries(), msg1_label_id) orelse return error.MissingLabelEntry;
    const msg2_label_entry = findEntryById(session.getEntries(), msg2_label_id) orelse return error.MissingLabelEntry;
    const msg1_label_timestamp = try entryStringFieldAlloc(allocator, msg1_label_entry.raw_json, "timestamp");
    defer allocator.free(msg1_label_timestamp.?);
    const msg2_label_timestamp = try entryStringFieldAlloc(allocator, msg2_label_entry.raw_json, "timestamp");
    defer allocator.free(msg2_label_timestamp.?);

    var tree = try session.getTreeAlloc(allocator);
    defer tree.deinit();
    const msg1_node = findTreeNodeById(tree.roots, msg1_id) orelse return error.MissingMessageNode;
    try std.testing.expectEqualStrings("start", msg1_node.label.?);
    try std.testing.expectEqualStrings(msg1_label_timestamp.?, msg1_node.label_timestamp.?);
    const msg2_node = findTreeNodeById(msg1_node.children, msg2_id) orelse return error.MissingMessageNode;
    try std.testing.expectEqualStrings("response", msg2_node.label.?);
    try std.testing.expectEqualStrings(msg2_label_timestamp.?, msg2_node.label_timestamp.?);

    var context = try session.buildSessionContextAlloc(allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectError(
        error.EntryNotFound,
        session.appendLabelChange(std.testing.io, "non-existent", "label"),
    );
}

test "SessionManager createBranchedSession preserves labels only for selected path" {
    const allocator = std.testing.allocator;
    var session = try SessionManager.inMemory(allocator, std.testing.io, null);
    defer session.deinit();

    const msg1_json = try testUserMessageJsonAlloc(allocator, "hello", 1);
    defer allocator.free(msg1_json);
    const msg2_json = try testAssistantMessageJsonAlloc(allocator, "hi", 2);
    defer allocator.free(msg2_json);
    const msg3_json = try testUserMessageJsonAlloc(allocator, "followup", 3);
    defer allocator.free(msg3_json);
    const msg1_id = try session.appendMessageJson(std.testing.io, msg1_json);
    const msg2_id = try session.appendMessageJson(std.testing.io, msg2_json);
    const msg3_id = try session.appendMessageJson(std.testing.io, msg3_json);

    const msg1_label_id = try session.appendLabelChange(std.testing.io, msg1_id, "first");
    const msg2_label_id = try session.appendLabelChange(std.testing.io, msg2_id, "second");
    _ = try session.appendLabelChange(std.testing.io, msg3_id, "third");
    const msg1_label_entry = findEntryById(session.getEntries(), msg1_label_id) orelse return error.MissingLabelEntry;
    const msg2_label_entry = findEntryById(session.getEntries(), msg2_label_id) orelse return error.MissingLabelEntry;
    const msg1_label_timestamp = try entryStringFieldAlloc(allocator, msg1_label_entry.raw_json, "timestamp");
    defer allocator.free(msg1_label_timestamp.?);
    const msg2_label_timestamp = try entryStringFieldAlloc(allocator, msg2_label_entry.raw_json, "timestamp");
    defer allocator.free(msg2_label_timestamp.?);

    try std.testing.expectEqual(null, try session.createBranchedSession(std.testing.io, msg2_id));
    try std.testing.expectEqual(@as(usize, 2), countEntriesByType(session.getEntries(), "label"));

    const msg1_label = (try session.getLabelAlloc(allocator, msg1_id)).?;
    defer allocator.free(msg1_label);
    const msg2_label = (try session.getLabelAlloc(allocator, msg2_id)).?;
    defer allocator.free(msg2_label);
    try std.testing.expectEqualStrings("first", msg1_label);
    try std.testing.expectEqualStrings("second", msg2_label);
    try std.testing.expectEqual(null, try session.getLabelAlloc(allocator, msg3_id));

    var tree = try session.getTreeAlloc(allocator);
    defer tree.deinit();
    const msg1_node = findTreeNodeById(tree.roots, msg1_id) orelse return error.MissingMessageNode;
    const msg2_node = findTreeNodeById(msg1_node.children, msg2_id) orelse return error.MissingMessageNode;
    try std.testing.expectEqualStrings(msg1_label_timestamp.?, msg1_node.label_timestamp.?);
    try std.testing.expectEqualStrings(msg2_label_timestamp.?, msg2_node.label_timestamp.?);
}
