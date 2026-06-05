const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const session_manager = @import("session_manager.zig");
const session_selector_search = @import("session_selector_search.zig");

pub const SessionInfo = session_manager.SessionInfo;
pub const SortMode = session_selector_search.SortMode;
pub const NameFilter = session_selector_search.NameFilter;

pub const SessionScope = enum {
    current,
    all,
};

pub const SessionSelectorMode = enum {
    list,
    rename,
};

pub const SessionTreeNode = struct {
    session: SessionInfo,
    children: []*SessionTreeNode,
};

pub const SessionTree = struct {
    arena: std.heap.ArenaAllocator,
    roots: []*SessionTreeNode,

    pub fn deinit(self: *SessionTree) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const FlatSessionNode = struct {
    session: SessionInfo,
    depth: usize,
    is_last: bool,
    ancestor_continues: []const bool,
};

pub const FlatSessionTree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []FlatSessionNode,

    pub fn deinit(self: *FlatSessionTree) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SessionListAction = union(enum) {
    none,
    toggle_scope,
    toggle_sort,
    toggle_name_filter,
    toggle_path: bool,
    delete_confirmation_changed: ?[]const u8,
    delete_session: []const u8,
    rename_session: []const u8,
    select: []const u8,
    cancel,
    failure: []const u8,
};

pub const SessionSelectorAction = union(enum) {
    none,
    load_all: u64,
    select: []const u8,
    cancel,
    delete_session: []const u8,
    enter_rename: []const u8,
    rename_submitted: RenameRequest,
    failure: []const u8,
};

pub const RenameRequest = struct {
    path: []const u8,
    name: []const u8,
};

pub const SessionSelectorOptions = struct {
    can_rename: bool = false,
    show_rename_hint: ?bool = null,
    sort_mode: SortMode = .threaded,
    name_filter: NameFilter = .all,
};

pub const SessionListState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: []const SessionInfo = &.{},
    filtered_sessions: []FlatSessionNode = &.{},
    query: std.ArrayList(u8) = .empty,
    filter_arena: std.heap.ArenaAllocator,
    show_cwd: bool,
    sort_mode: SortMode,
    name_filter: NameFilter,
    selected_index: usize = 0,
    show_path: bool = false,
    confirming_delete_path: ?[]const u8 = null,
    current_session_canonical_path: ?[]u8 = null,
    max_visible: usize = 10,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        sessions: []const SessionInfo,
        show_cwd: bool,
        sort_mode: SortMode,
        name_filter: NameFilter,
        current_session_file_path: ?[]const u8,
    ) !SessionListState {
        var self = SessionListState{
            .allocator = allocator,
            .io = io,
            .filter_arena = std.heap.ArenaAllocator.init(allocator),
            .show_cwd = show_cwd,
            .sort_mode = sort_mode,
            .name_filter = name_filter,
        };
        errdefer self.deinit();

        if (current_session_file_path) |path| {
            self.current_session_canonical_path = try paths.canonicalizePathAlloc(allocator, io, path);
        }
        try self.setSessions(sessions, show_cwd);
        return self;
    }

    pub fn deinit(self: *SessionListState) void {
        self.query.deinit(self.allocator);
        self.filter_arena.deinit();
        if (self.current_session_canonical_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn setSessions(self: *SessionListState, sessions: []const SessionInfo, show_cwd: bool) !void {
        self.sessions = sessions;
        self.show_cwd = show_cwd;
        try self.filterSessions();
    }

    pub fn setSortMode(self: *SessionListState, sort_mode: SortMode) !void {
        self.sort_mode = sort_mode;
        try self.filterSessions();
    }

    pub fn setNameFilter(self: *SessionListState, name_filter: NameFilter) !void {
        self.name_filter = name_filter;
        try self.filterSessions();
    }

    pub fn selectedSession(self: *const SessionListState) ?FlatSessionNode {
        if (self.filtered_sessions.len == 0) return null;
        return self.filtered_sessions[@min(self.selected_index, self.filtered_sessions.len - 1)];
    }

    pub fn queryValue(self: *const SessionListState) []const u8 {
        return self.query.items;
    }

    pub fn confirmingDeletePath(self: *const SessionListState) ?[]const u8 {
        return self.confirming_delete_path;
    }

    pub fn handleInput(self: *SessionListState, key_data: []const u8) !SessionListAction {
        if (self.confirming_delete_path) |path| {
            if (isConfirmKey(key_data)) {
                self.confirming_delete_path = null;
                return .{ .delete_session = path };
            }
            if (isCancelKey(key_data)) {
                self.confirming_delete_path = null;
                return .{ .delete_confirmation_changed = null };
            }
            return .none;
        }

        if (std.mem.eql(u8, key_data, "\t")) return .toggle_scope;
        if (std.mem.eql(u8, key_data, "\x13")) return .toggle_sort;
        if (std.mem.eql(u8, key_data, "\x0e")) return .toggle_name_filter;
        if (std.mem.eql(u8, key_data, "\x10")) {
            self.show_path = !self.show_path;
            return .{ .toggle_path = self.show_path };
        }
        if (std.mem.eql(u8, key_data, "\x04")) return self.startDeleteConfirmationForSelectedSession();
        if (isRenameKey(key_data)) {
            const selected = self.selectedSession() orelse return .none;
            return .{ .rename_session = selected.session.path };
        }
        if (isCtrlBackspace(key_data)) {
            if (self.query.items.len > 0) {
                self.deleteQueryWordBackward();
                try self.filterSessions();
                return .none;
            }
            return self.startDeleteConfirmationForSelectedSession();
        }

        if (std.mem.eql(u8, key_data, "\x1b[A")) {
            if (self.selected_index > 0) self.selected_index -= 1;
            return .none;
        }
        if (std.mem.eql(u8, key_data, "\x1b[B")) {
            if (self.filtered_sessions.len > 0) {
                self.selected_index = @min(self.filtered_sessions.len - 1, self.selected_index + 1);
            }
            return .none;
        }
        if (std.mem.eql(u8, key_data, "\x1b[5~")) {
            self.selected_index = if (self.selected_index > self.max_visible) self.selected_index - self.max_visible else 0;
            return .none;
        }
        if (std.mem.eql(u8, key_data, "\x1b[6~")) {
            if (self.filtered_sessions.len > 0) {
                self.selected_index = @min(self.filtered_sessions.len - 1, self.selected_index + self.max_visible);
            }
            return .none;
        }
        if (isConfirmKey(key_data)) {
            const selected = self.selectedSession() orelse return .none;
            return .{ .select = selected.session.path };
        }
        if (isCancelKey(key_data)) return .cancel;

        if (std.mem.eql(u8, key_data, "\x7f")) {
            if (self.query.items.len > 0) {
                self.query.shrinkRetainingCapacity(self.query.items.len - 1);
                try self.filterSessions();
            }
            return .none;
        }

        if (isTextInput(key_data)) {
            try self.query.appendSlice(self.allocator, key_data);
            try self.filterSessions();
        }
        return .none;
    }

    fn startDeleteConfirmationForSelectedSession(self: *SessionListState) !SessionListAction {
        const selected = self.selectedSession() orelse return .none;
        if (try self.isCurrentSessionPath(selected.session.path)) {
            return .{ .failure = "Cannot delete the currently active session" };
        }
        self.confirming_delete_path = selected.session.path;
        return .{ .delete_confirmation_changed = selected.session.path };
    }

    fn isCurrentSessionPath(self: *const SessionListState, path: []const u8) !bool {
        const current = self.current_session_canonical_path orelse return false;
        const canonical = try paths.canonicalizePathAlloc(self.allocator, self.io, path);
        defer self.allocator.free(canonical);
        return std.mem.eql(u8, current, canonical);
    }

    fn deleteQueryWordBackward(self: *SessionListState) void {
        var end = self.query.items.len;
        while (end > 0 and std.ascii.isWhitespace(self.query.items[end - 1])) end -= 1;
        while (end > 0 and !std.ascii.isWhitespace(self.query.items[end - 1])) end -= 1;
        self.query.shrinkRetainingCapacity(end);
    }

    fn filterSessions(self: *SessionListState) !void {
        self.resetFilterArena();
        const arena_allocator = self.filter_arena.allocator();

        var name_filtered: std.ArrayList(SessionInfo) = .empty;
        for (self.sessions) |session| {
            if (self.name_filter == .all or session_selector_search.hasSessionName(session)) {
                try name_filtered.append(arena_allocator, session);
            }
        }

        const trimmed = std.mem.trim(u8, self.query.items, " \t\r\n");
        if (self.sort_mode == .threaded and trimmed.len == 0) {
            var tree = try buildSessionTree(self.allocator, self.io, name_filtered.items);
            defer tree.deinit();
            var flat = try flattenSessionTree(self.allocator, tree.roots);
            defer flat.deinit();
            self.filtered_sessions = try copyFlatNodes(arena_allocator, flat.nodes);
        } else {
            const filtered = try session_selector_search.filterAndSortSessions(
                arena_allocator,
                name_filtered.items,
                self.query.items,
                self.sort_mode,
                .all,
            );
            self.filtered_sessions = try arena_allocator.alloc(FlatSessionNode, filtered.len);
            for (filtered, 0..) |session, index| {
                self.filtered_sessions[index] = .{
                    .session = session,
                    .depth = 0,
                    .is_last = true,
                    .ancestor_continues = &.{},
                };
            }
        }

        if (self.filtered_sessions.len == 0) {
            self.selected_index = 0;
        } else {
            self.selected_index = @min(self.selected_index, self.filtered_sessions.len - 1);
        }
    }

    fn resetFilterArena(self: *SessionListState) void {
        self.filter_arena.deinit();
        self.filter_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.filtered_sessions = &.{};
    }
};

pub const SessionSelectorController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: SessionScope = .current,
    sort_mode: SortMode,
    name_filter: NameFilter,
    current_sessions: []SessionInfo,
    all_sessions: []SessionInfo = &.{},
    has_all_sessions: bool = false,
    current_loading: bool = false,
    all_loading: bool = false,
    all_load_seq: u64 = 0,
    show_path: bool = false,
    can_rename: bool,
    show_rename_hint: bool,
    mode: SessionSelectorMode = .list,
    list: SessionListState,
    rename_value: std.ArrayList(u8) = .empty,
    rename_cursor: usize = 0,
    rename_target_path: ?[]const u8 = null,

    pub fn initLoadedCurrent(
        allocator: std.mem.Allocator,
        io: std.Io,
        current_sessions: []const SessionInfo,
        current_session_file_path: ?[]const u8,
        options: SessionSelectorOptions,
    ) !SessionSelectorController {
        const owned_current = try allocator.dupe(SessionInfo, current_sessions);
        errdefer allocator.free(owned_current);

        var list = try SessionListState.init(
            allocator,
            io,
            owned_current,
            false,
            options.sort_mode,
            options.name_filter,
            current_session_file_path,
        );
        errdefer list.deinit();

        const can_rename = options.can_rename;
        return .{
            .allocator = allocator,
            .io = io,
            .sort_mode = options.sort_mode,
            .name_filter = options.name_filter,
            .current_sessions = owned_current,
            .can_rename = can_rename,
            .show_rename_hint = options.show_rename_hint orelse can_rename,
            .list = list,
        };
    }

    pub fn deinit(self: *SessionSelectorController) void {
        self.list.deinit();
        self.allocator.free(self.current_sessions);
        if (self.has_all_sessions) self.allocator.free(self.all_sessions);
        self.rename_value.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handleInput(self: *SessionSelectorController, key_data: []const u8) !SessionSelectorAction {
        if (self.mode == .rename) return self.handleRenameInput(key_data);

        const action = try self.list.handleInput(key_data);
        switch (action) {
            .none => return .none,
            .toggle_scope => return self.toggleScope(),
            .toggle_sort => {
                self.sort_mode = switch (self.sort_mode) {
                    .threaded => .recent,
                    .recent => .relevance,
                    .relevance => .threaded,
                };
                try self.list.setSortMode(self.sort_mode);
                return .none;
            },
            .toggle_name_filter => {
                self.name_filter = if (self.name_filter == .all) .named else .all;
                try self.list.setNameFilter(self.name_filter);
                return .none;
            },
            .toggle_path => |show| {
                self.show_path = show;
                return .none;
            },
            .delete_confirmation_changed => return .none,
            .delete_session => |path| return .{ .delete_session = path },
            .rename_session => |path| {
                if (!self.can_rename) return .none;
                if ((self.scope == .current and self.current_loading) or
                    (self.scope == .all and self.all_loading))
                {
                    return .none;
                }
                try self.enterRenameMode(path);
                return .{ .enter_rename = path };
            },
            .select => |path| return .{ .select = path },
            .cancel => return .cancel,
            .failure => |message| return .{ .failure = message },
        }
    }

    pub fn completeAllLoad(
        self: *SessionSelectorController,
        seq: u64,
        sessions: []const SessionInfo,
    ) !SessionSelectorAction {
        if (self.has_all_sessions) self.allocator.free(self.all_sessions);
        self.all_sessions = try self.allocator.dupe(SessionInfo, sessions);
        self.has_all_sessions = true;
        self.all_loading = false;

        if (self.scope != .all or seq != self.all_load_seq) return .none;

        try self.list.setSessions(self.all_sessions, true);
        if (self.all_sessions.len == 0 and self.current_sessions.len == 0) return .cancel;
        return .none;
    }

    pub fn applyDeletedSession(self: *SessionSelectorController, session_path: []const u8) !void {
        self.current_sessions = try removeSessionByPath(self.allocator, self.current_sessions, session_path);
        if (self.has_all_sessions) {
            self.all_sessions = try removeSessionByPath(self.allocator, self.all_sessions, session_path);
        }
        try self.list.setSessions(if (self.scope == .all) self.all_sessions else self.current_sessions, self.scope == .all);
    }

    pub fn modeTitle(self: *const SessionSelectorController) []const u8 {
        if (self.mode == .rename) return "Rename Session";
        return if (self.scope == .current) "Resume Session (Current Folder)" else "Resume Session (All)";
    }

    pub fn headerHintsAlloc(self: *const SessionSelectorController, allocator: std.mem.Allocator) ![]u8 {
        const path_state = if (self.show_path) "on" else "off";
        if (self.show_rename_hint) {
            return std.fmt.allocPrint(
                allocator,
                "ctrl+s sort · ctrl+n named · ctrl+d delete · ctrl+p path ({s}) · ctrl+r rename",
                .{path_state},
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "ctrl+s sort · ctrl+n named · ctrl+d delete · ctrl+p path ({s})",
            .{path_state},
        );
    }

    pub fn renameValue(self: *const SessionSelectorController) []const u8 {
        return self.rename_value.items;
    }

    fn toggleScope(self: *SessionSelectorController) !SessionSelectorAction {
        if (self.scope == .current) {
            self.scope = .all;
            if (self.has_all_sessions) {
                self.all_loading = false;
                try self.list.setSessions(self.all_sessions, true);
                return .none;
            }
            if (!self.all_loading) {
                self.all_loading = true;
                self.all_load_seq += 1;
                return .{ .load_all = self.all_load_seq };
            }
            return .none;
        }

        self.scope = .current;
        try self.list.setSessions(self.current_sessions, false);
        return .none;
    }

    fn enterRenameMode(self: *SessionSelectorController, session_path: []const u8) !void {
        self.mode = .rename;
        self.rename_target_path = session_path;
        self.rename_value.clearRetainingCapacity();
        if (self.findSessionName(session_path)) |name| try self.rename_value.appendSlice(self.allocator, name);
        self.rename_cursor = 0;
    }

    fn exitRenameMode(self: *SessionSelectorController) void {
        self.mode = .list;
        self.rename_target_path = null;
        self.rename_value.clearRetainingCapacity();
        self.rename_cursor = 0;
    }

    fn handleRenameInput(self: *SessionSelectorController, key_data: []const u8) !SessionSelectorAction {
        if (isCancelKey(key_data)) {
            self.exitRenameMode();
            return .none;
        }
        if (isConfirmKey(key_data)) {
            const next = std.mem.trim(u8, self.rename_value.items, " \t\r\n");
            if (next.len == 0) return .none;
            const target = self.rename_target_path orelse {
                self.exitRenameMode();
                return .none;
            };
            const request: RenameRequest = .{ .path = target, .name = next };
            self.mode = .list;
            self.rename_target_path = null;
            self.rename_cursor = 0;
            return .{ .rename_submitted = request };
        }
        if (std.mem.eql(u8, key_data, "\x7f")) {
            if (self.rename_cursor > 0) {
                const old = self.rename_value.items;
                var next: std.ArrayList(u8) = .empty;
                defer next.deinit(self.allocator);
                try next.appendSlice(self.allocator, old[0 .. self.rename_cursor - 1]);
                try next.appendSlice(self.allocator, old[self.rename_cursor..]);
                self.rename_value.clearRetainingCapacity();
                try self.rename_value.appendSlice(self.allocator, next.items);
                self.rename_cursor -= 1;
            }
            return .none;
        }
        if (isTextInput(key_data)) {
            const old = self.rename_value.items;
            var next: std.ArrayList(u8) = .empty;
            defer next.deinit(self.allocator);
            try next.appendSlice(self.allocator, old[0..self.rename_cursor]);
            try next.appendSlice(self.allocator, key_data);
            try next.appendSlice(self.allocator, old[self.rename_cursor..]);
            self.rename_value.clearRetainingCapacity();
            try self.rename_value.appendSlice(self.allocator, next.items);
            self.rename_cursor += key_data.len;
        }
        return .none;
    }

    fn findSessionName(self: *const SessionSelectorController, session_path: []const u8) ?[]const u8 {
        const sessions = if (self.scope == .all and self.has_all_sessions) self.all_sessions else self.current_sessions;
        for (sessions) |session| {
            if (std.mem.eql(u8, session.path, session_path)) return session.name;
        }
        return null;
    }
};

const NodeBuilder = struct {
    node: *SessionTreeNode,
    children: std.ArrayList(*SessionTreeNode),
};

pub fn buildSessionTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: []const SessionInfo,
) !SessionTree {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var builders = try arena_allocator.alloc(*NodeBuilder, sessions.len);
    var by_path = std.StringHashMap(*NodeBuilder).init(allocator);
    defer by_path.deinit();

    for (sessions, 0..) |session, index| {
        const children = try arena_allocator.alloc(*SessionTreeNode, 0);
        const node = try arena_allocator.create(SessionTreeNode);
        node.* = .{
            .session = session,
            .children = children,
        };
        const builder = try arena_allocator.create(NodeBuilder);
        builder.* = .{
            .node = node,
            .children = .empty,
        };
        builders[index] = builder;

        const canonical_path = try paths.canonicalizePathAlloc(arena_allocator, io, session.path);
        try by_path.put(canonical_path, builder);
    }

    var roots: std.ArrayList(*SessionTreeNode) = .empty;
    for (sessions) |session| {
        const canonical_session_path = try paths.canonicalizePathAlloc(allocator, io, session.path);
        defer allocator.free(canonical_session_path);
        const builder = by_path.get(canonical_session_path) orelse continue;

        if (session.parent_session_path) |parent_session_path| {
            const canonical_parent_path = try paths.canonicalizePathAlloc(allocator, io, parent_session_path);
            defer allocator.free(canonical_parent_path);
            if (by_path.get(canonical_parent_path)) |parent| {
                try parent.children.append(arena_allocator, builder.node);
                continue;
            }
        }

        try roots.append(arena_allocator, builder.node);
    }

    for (builders) |builder| {
        builder.node.children = try builder.children.toOwnedSlice(arena_allocator);
    }

    const root_slice = try roots.toOwnedSlice(arena_allocator);
    sortNodes(root_slice);

    return .{
        .arena = arena,
        .roots = root_slice,
    };
}

pub fn flattenSessionTree(
    allocator: std.mem.Allocator,
    roots: []const *SessionTreeNode,
) !FlatSessionTree {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var nodes: std.ArrayList(FlatSessionNode) = .empty;
    for (roots, 0..) |root, index| {
        try walkFlatten(
            arena_allocator,
            &nodes,
            root,
            0,
            &.{},
            index == roots.len - 1,
        );
    }

    return .{
        .arena = arena,
        .nodes = try nodes.toOwnedSlice(arena_allocator),
    };
}

pub fn buildTreePrefixAlloc(allocator: std.mem.Allocator, node: FlatSessionNode) ![]u8 {
    if (node.depth == 0) return allocator.dupe(u8, "");

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (node.ancestor_continues) |continues| {
        try output.appendSlice(allocator, if (continues) "│  " else "   ");
    }
    try output.appendSlice(allocator, if (node.is_last) "└─ " else "├─ ");
    return output.toOwnedSlice(allocator);
}

pub fn isCurrentSessionPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_session_file_path: ?[]const u8,
    path: []const u8,
) !bool {
    const current_path = current_session_file_path orelse return false;
    const current_canonical = try paths.canonicalizePathAlloc(allocator, io, current_path);
    defer allocator.free(current_canonical);
    const candidate_canonical = try paths.canonicalizePathAlloc(allocator, io, path);
    defer allocator.free(candidate_canonical);
    return std.mem.eql(u8, current_canonical, candidate_canonical);
}

fn walkFlatten(
    allocator: std.mem.Allocator,
    nodes: *std.ArrayList(FlatSessionNode),
    node: *SessionTreeNode,
    depth: usize,
    ancestor_continues: []const bool,
    is_last: bool,
) !void {
    try nodes.append(allocator, .{
        .session = node.session,
        .depth = depth,
        .is_last = is_last,
        .ancestor_continues = try allocator.dupe(bool, ancestor_continues),
    });

    for (node.children, 0..) |child, index| {
        const next = try allocator.alloc(bool, ancestor_continues.len + 1);
        @memcpy(next[0..ancestor_continues.len], ancestor_continues);
        next[ancestor_continues.len] = if (depth > 0) !is_last else false;
        try walkFlatten(
            allocator,
            nodes,
            child,
            depth + 1,
            next,
            index == node.children.len - 1,
        );
    }
}

fn sortNodes(nodes: []*SessionTreeNode) void {
    std.mem.sort(*SessionTreeNode, nodes, {}, newerSessionFirst);
    for (nodes) |node| sortNodes(node.children);
}

fn newerSessionFirst(_: void, lhs: *SessionTreeNode, rhs: *SessionTreeNode) bool {
    return lhs.session.modified_ms > rhs.session.modified_ms;
}

fn copyFlatNodes(allocator: std.mem.Allocator, nodes: []const FlatSessionNode) ![]FlatSessionNode {
    const result = try allocator.alloc(FlatSessionNode, nodes.len);
    for (nodes, 0..) |node, index| {
        result[index] = .{
            .session = node.session,
            .depth = node.depth,
            .is_last = node.is_last,
            .ancestor_continues = try allocator.dupe(bool, node.ancestor_continues),
        };
    }
    return result;
}

fn removeSessionByPath(
    allocator: std.mem.Allocator,
    sessions: []SessionInfo,
    session_path: []const u8,
) ![]SessionInfo {
    var kept: std.ArrayList(SessionInfo) = .empty;
    errdefer kept.deinit(allocator);
    for (sessions) |session| {
        if (!std.mem.eql(u8, session.path, session_path)) try kept.append(allocator, session);
    }
    allocator.free(sessions);
    return kept.toOwnedSlice(allocator);
}

fn isConfirmKey(key_data: []const u8) bool {
    return std.mem.eql(u8, key_data, "\r");
}

fn isCancelKey(key_data: []const u8) bool {
    return std.mem.eql(u8, key_data, "\x1b");
}

fn isRenameKey(key_data: []const u8) bool {
    return std.mem.eql(u8, key_data, "\x12") or std.mem.eql(u8, key_data, "\x1b[114;5u");
}

fn isCtrlBackspace(key_data: []const u8) bool {
    return std.mem.eql(u8, key_data, "\x1b[127;5u");
}

fn isTextInput(key_data: []const u8) bool {
    if (key_data.len == 0) return false;
    for (key_data) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn makeSession(overrides: struct {
    id: []const u8,
    path: ?[]const u8 = null,
    name: ?[]const u8 = null,
    parent_session_path: ?[]const u8 = null,
    modified_ms: i64 = 0,
}) SessionInfo {
    return .{
        .path = overrides.path orelse overrides.id,
        .id = overrides.id,
        .cwd = "",
        .name = overrides.name,
        .parent_session_path = overrides.parent_session_path,
        .created_ms = 0,
        .modified_ms = overrides.modified_ms,
        .message_count = 1,
        .first_message = "hello",
        .all_messages_text = "hello",
    };
}

fn expectFlatIds(nodes: []const FlatSessionNode, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, nodes.len);
    for (expected, 0..) |id, index| {
        try std.testing.expectEqualStrings(id, nodes[index].session.id);
    }
}

fn expectListActionTag(action: SessionListAction, tag: std.meta.Tag(SessionListAction)) !void {
    try std.testing.expectEqual(tag, std.meta.activeTag(action));
}

fn expectSelectorActionTag(action: SessionSelectorAction, tag: std.meta.Tag(SessionSelectorAction)) !void {
    try std.testing.expectEqual(tag, std.meta.activeTag(action));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn makeAbsoluteDir(path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
}

fn writeAbsoluteFile(path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = content,
    });
}

const SymlinkedSessionPaths = struct {
    base_dir: []u8,
    parent_alias_a: []u8,
    parent_alias_b: []u8,
    child_alias_b: []u8,

    fn deinit(self: SymlinkedSessionPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.base_dir);
        allocator.free(self.parent_alias_a);
        allocator.free(self.parent_alias_b);
        allocator.free(self.child_alias_b);
    }
};

fn createSymlinkedSessionPaths(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
) !SymlinkedSessionPaths {
    const base_dir = try tempDirPathAlloc(allocator, tmp);
    errdefer allocator.free(base_dir);

    const real_dir = try std.fs.path.join(allocator, &.{ base_dir, "real" });
    defer allocator.free(real_dir);
    const alias_a_dir = try std.fs.path.join(allocator, &.{ base_dir, "alias-a" });
    defer allocator.free(alias_a_dir);
    const alias_b_dir = try std.fs.path.join(allocator, &.{ base_dir, "alias-b" });
    defer allocator.free(alias_b_dir);
    try makeAbsoluteDir(real_dir);
    try makeAbsoluteDir(alias_a_dir);
    try makeAbsoluteDir(alias_b_dir);

    const shared_dir = try std.fs.path.join(allocator, &.{ real_dir, "sessions" });
    defer allocator.free(shared_dir);
    try makeAbsoluteDir(shared_dir);

    const alias_a_sessions = try std.fs.path.join(allocator, &.{ alias_a_dir, "sessions" });
    defer allocator.free(alias_a_sessions);
    const alias_b_sessions = try std.fs.path.join(allocator, &.{ alias_b_dir, "sessions" });
    defer allocator.free(alias_b_sessions);
    try std.Io.Dir.cwd().symLink(std.testing.io, shared_dir, alias_a_sessions, .{});
    try std.Io.Dir.cwd().symLink(std.testing.io, shared_dir, alias_b_sessions, .{});

    const parent_real_path = try std.fs.path.join(allocator, &.{ shared_dir, "parent.jsonl" });
    defer allocator.free(parent_real_path);
    const child_real_path = try std.fs.path.join(allocator, &.{ shared_dir, "child.jsonl" });
    defer allocator.free(child_real_path);
    try writeAbsoluteFile(parent_real_path, "parent\n");
    try writeAbsoluteFile(child_real_path, "child\n");

    return .{
        .base_dir = base_dir,
        .parent_alias_a = try std.fs.path.join(allocator, &.{ alias_a_sessions, "parent.jsonl" }),
        .parent_alias_b = try std.fs.path.join(allocator, &.{ alias_b_sessions, "parent.jsonl" }),
        .child_alias_b = try std.fs.path.join(allocator, &.{ alias_b_sessions, "child.jsonl" }),
    };
}

test "session selector tree sorts roots and children by modified time" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{
        makeSession(.{ .id = "older-root", .modified_ms = 100 }),
        makeSession(.{ .id = "newer-root", .modified_ms = 300 }),
        makeSession(.{ .id = "older-child", .parent_session_path = "newer-root", .modified_ms = 150 }),
        makeSession(.{ .id = "newer-child", .parent_session_path = "newer-root", .modified_ms = 250 }),
    };

    var tree = try buildSessionTree(allocator, io, &sessions);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 2), tree.roots.len);
    try std.testing.expectEqualStrings("newer-root", tree.roots[0].session.id);
    try std.testing.expectEqualStrings("older-root", tree.roots[1].session.id);
    try std.testing.expectEqualStrings("newer-child", tree.roots[0].children[0].session.id);
    try std.testing.expectEqualStrings("older-child", tree.roots[0].children[1].session.id);

    var flat = try flattenSessionTree(allocator, tree.roots);
    defer flat.deinit();
    try expectFlatIds(flat.nodes, &.{ "newer-root", "newer-child", "older-child", "older-root" });
    try std.testing.expectEqual(@as(usize, 1), flat.nodes[1].depth);
    try std.testing.expect(!flat.nodes[1].is_last);
    try std.testing.expect(flat.nodes[2].is_last);
}

test "session selector tree builds renderable branch prefixes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{
        makeSession(.{ .id = "parent", .modified_ms = 3 }),
        makeSession(.{ .id = "child-a", .parent_session_path = "parent", .modified_ms = 2 }),
        makeSession(.{ .id = "child-b", .parent_session_path = "parent", .modified_ms = 1 }),
    };

    var tree = try buildSessionTree(allocator, io, &sessions);
    defer tree.deinit();
    var flat = try flattenSessionTree(allocator, tree.roots);
    defer flat.deinit();

    const root_prefix = try buildTreePrefixAlloc(allocator, flat.nodes[0]);
    defer allocator.free(root_prefix);
    try std.testing.expectEqualStrings("", root_prefix);
    const first_child_prefix = try buildTreePrefixAlloc(allocator, flat.nodes[1]);
    defer allocator.free(first_child_prefix);
    try std.testing.expectEqualStrings("   ├─ ", first_child_prefix);
    const last_child_prefix = try buildTreePrefixAlloc(allocator, flat.nodes[2]);
    defer allocator.free(last_child_prefix);
    try std.testing.expectEqualStrings("   └─ ", last_child_prefix);
}

test "session selector does not treat Ctrl+Backspace as delete when search query is non-empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{
        makeSession(.{ .id = "a", .path = "/tmp/a.jsonl" }),
        makeSession(.{ .id = "b", .path = "/tmp/b.jsonl" }),
    };

    var list = try SessionListState.init(allocator, io, &sessions, false, .threaded, .all, null);
    defer list.deinit();

    try expectListActionTag(try list.handleInput("a"), .none);
    try expectListActionTag(try list.handleInput("\x1b[127;5u"), .none);
    try std.testing.expect(list.confirmingDeletePath() == null);
}

test "session selector enters confirmation mode on Ctrl+D even with a non-empty search query" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{
        makeSession(.{ .id = "a", .path = "/tmp/a.jsonl" }),
        makeSession(.{ .id = "b", .path = "/tmp/b.jsonl" }),
    };

    var list = try SessionListState.init(allocator, io, &sessions, false, .threaded, .all, null);
    defer list.deinit();

    try expectListActionTag(try list.handleInput("a"), .none);
    const action = try list.handleInput("\x04");
    switch (action) {
        .delete_confirmation_changed => |path| try std.testing.expectEqualStrings(sessions[0].path, path.?),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings(sessions[0].path, list.confirmingDeletePath().?);
}

test "session selector enters confirmation mode on Ctrl+Backspace when search query is empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{
        makeSession(.{ .id = "a", .path = "/tmp/a.jsonl" }),
        makeSession(.{ .id = "b", .path = "/tmp/b.jsonl" }),
    };

    var list = try SessionListState.init(allocator, io, &sessions, false, .threaded, .all, null);
    defer list.deinit();

    const confirmation = try list.handleInput("\x1b[127;5u");
    switch (confirmation) {
        .delete_confirmation_changed => |path| try std.testing.expectEqualStrings(sessions[0].path, path.?),
        else => return error.TestUnexpectedResult,
    }

    const deleted = try list.handleInput("\r");
    switch (deleted) {
        .delete_session => |path| try std.testing.expectEqualStrings(sessions[0].path, path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(list.confirmingDeletePath() == null);
}

test "session selector does not switch scope back to All when All load resolves after toggling back to Current" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const current_sessions = [_]SessionInfo{makeSession(.{ .id = "current", .path = "/tmp/current.jsonl" })};
    const all_sessions = [_]SessionInfo{makeSession(.{ .id = "all", .path = "/tmp/all.jsonl" })};

    var selector = try SessionSelectorController.initLoadedCurrent(allocator, io, &current_sessions, null, .{});
    defer selector.deinit();

    const load = try selector.handleInput("\t");
    const seq = switch (load) {
        .load_all => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(SessionScope.all, selector.scope);

    try expectSelectorActionTag(try selector.handleInput("\t"), .none);
    try std.testing.expectEqual(SessionScope.current, selector.scope);

    try expectSelectorActionTag(try selector.completeAllLoad(seq, &all_sessions), .none);
    try std.testing.expectEqual(SessionScope.current, selector.scope);
    try std.testing.expectEqualStrings("Resume Session (Current Folder)", selector.modeTitle());
    try std.testing.expectEqualStrings("current", selector.list.selectedSession().?.session.id);
}

test "session selector does not start redundant All loads while All is already loading" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const current_sessions = [_]SessionInfo{makeSession(.{ .id = "current", .path = "/tmp/current.jsonl" })};
    const all_sessions = [_]SessionInfo{makeSession(.{ .id = "all", .path = "/tmp/all.jsonl" })};

    var selector = try SessionSelectorController.initLoadedCurrent(allocator, io, &current_sessions, null, .{});
    defer selector.deinit();

    const load = try selector.handleInput("\t");
    const seq = switch (load) {
        .load_all => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try expectSelectorActionTag(try selector.handleInput("\t"), .none);
    try expectSelectorActionTag(try selector.handleInput("\t"), .none);
    try std.testing.expectEqual(@as(u64, 1), selector.all_load_seq);

    try expectSelectorActionTag(try selector.completeAllLoad(seq, &all_sessions), .none);
    try std.testing.expectEqual(SessionScope.all, selector.scope);
    try std.testing.expectEqualStrings("all", selector.list.selectedSession().?.session.id);
}

test "session selector shows rename hint when configured" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{makeSession(.{ .id = "a", .path = "/tmp/a.jsonl" })};

    var selector = try SessionSelectorController.initLoadedCurrent(
        allocator,
        io,
        &sessions,
        null,
        .{ .show_rename_hint = true },
    );
    defer selector.deinit();

    const hints = try selector.headerHintsAlloc(allocator);
    defer allocator.free(hints);
    try expectContains(hints, "ctrl+r");
    try expectContains(hints, "rename");
}

test "session selector hides rename hint when configured" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{makeSession(.{ .id = "a", .path = "/tmp/a.jsonl" })};

    var selector = try SessionSelectorController.initLoadedCurrent(
        allocator,
        io,
        &sessions,
        null,
        .{ .show_rename_hint = false },
    );
    defer selector.deinit();

    const hints = try selector.headerHintsAlloc(allocator);
    defer allocator.free(hints);
    try expectNotContains(hints, "ctrl+r");
    try expectNotContains(hints, "rename");
}

test "session selector enters rename mode on Ctrl+R and submits with Enter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const sessions = [_]SessionInfo{makeSession(.{
        .id = "a",
        .path = "/tmp/a.jsonl",
        .name = "Old",
    })};

    var selector = try SessionSelectorController.initLoadedCurrent(
        allocator,
        io,
        &sessions,
        null,
        .{ .can_rename = true, .show_rename_hint = true },
    );
    defer selector.deinit();

    const enter = try selector.handleInput("\x1b[114;5u");
    switch (enter) {
        .enter_rename => |path| try std.testing.expectEqualStrings(sessions[0].path, path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(SessionSelectorMode.rename, selector.mode);
    try std.testing.expectEqualStrings("Rename Session", selector.modeTitle());
    try expectNotContains(selector.modeTitle(), "Resume Session");

    try expectSelectorActionTag(try selector.handleInput("X"), .none);
    try std.testing.expectEqualStrings("XOld", selector.renameValue());

    const submitted = try selector.handleInput("\r");
    switch (submitted) {
        .rename_submitted => |request| {
            try std.testing.expectEqualStrings(sessions[0].path, request.path);
            try std.testing.expectEqualStrings("XOld", request.name);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(SessionSelectorMode.list, selector.mode);
}

test "session selector threads sessions when parent and child paths use different symlink aliases" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_paths = try createSymlinkedSessionPaths(allocator, &tmp);
    defer session_paths.deinit(allocator);

    const sessions = [_]SessionInfo{
        makeSession(.{
            .id = "parent",
            .path = session_paths.parent_alias_b,
            .name = "Parent",
            .modified_ms = 200,
        }),
        makeSession(.{
            .id = "child",
            .path = session_paths.child_alias_b,
            .name = "Child",
            .parent_session_path = session_paths.parent_alias_a,
            .modified_ms = 100,
        }),
    };

    var tree = try buildSessionTree(allocator, io, &sessions);
    defer tree.deinit();
    var flat = try flattenSessionTree(allocator, tree.roots);
    defer flat.deinit();
    try expectFlatIds(flat.nodes, &.{ "parent", "child" });

    const child_prefix = try buildTreePrefixAlloc(allocator, flat.nodes[1]);
    defer allocator.free(child_prefix);
    try std.testing.expectEqualStrings("   └─ ", child_prefix);
}

test "session selector treats current session as active across symlink aliases" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_paths = try createSymlinkedSessionPaths(allocator, &tmp);
    defer session_paths.deinit(allocator);

    try std.testing.expect(try isCurrentSessionPath(
        allocator,
        io,
        session_paths.parent_alias_a,
        session_paths.parent_alias_b,
    ));
    try std.testing.expect(!try isCurrentSessionPath(
        allocator,
        io,
        null,
        session_paths.parent_alias_b,
    ));

    const sessions = [_]SessionInfo{makeSession(.{
        .id = "parent",
        .path = session_paths.parent_alias_b,
        .name = "Parent",
    })};
    var list = try SessionListState.init(allocator, io, &sessions, false, .threaded, .all, session_paths.parent_alias_a);
    defer list.deinit();

    const action = try list.handleInput("\x04");
    switch (action) {
        .failure => |message| try std.testing.expectEqualStrings("Cannot delete the currently active session", message),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(list.confirmingDeletePath() == null);
}
