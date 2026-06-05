const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");
const session_manager = @import("session_manager.zig");

pub const SessionInfo = session_manager.SessionInfo;

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
}
