const std = @import("std");
const session_manager = @import("session_manager.zig");

pub const SessionTreeNode = session_manager.SessionTreeNode;

pub const FilterMode = enum {
    default,
    no_tools,
    user_only,
    labeled_only,
    all,
};

const FlatNode = struct {
    node: *SessionTreeNode,
    parent_index: ?usize,
};

pub const TreeSelector = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    filter_arena: std.heap.ArenaAllocator,
    flat_nodes: []FlatNode = &.{},
    filtered_indices: []usize = &.{},
    visible_parent: []?usize = &.{},
    visible_children: []std.ArrayList(usize) = &.{},
    root_indices: []usize = &.{},
    folded_nodes: std.StringHashMap(void),
    current_leaf_id: ?[]const u8,
    filter_mode: FilterMode = .default,
    search_query: std.ArrayList(u8) = .empty,
    selected_index: usize = 0,
    max_visible_lines: usize,
    show_label_timestamps: bool = false,
    last_selected_id: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        roots: []const *SessionTreeNode,
        current_leaf_id: ?[]const u8,
        terminal_height: usize,
    ) !TreeSelector {
        return initWithOptions(allocator, roots, current_leaf_id, terminal_height, null, .default);
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        roots: []const *SessionTreeNode,
        current_leaf_id: ?[]const u8,
        terminal_height: usize,
        initial_selected_id: ?[]const u8,
        initial_filter_mode: FilterMode,
    ) !TreeSelector {
        var selector = TreeSelector{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .filter_arena = std.heap.ArenaAllocator.init(allocator),
            .folded_nodes = std.StringHashMap(void).init(allocator),
            .current_leaf_id = current_leaf_id,
            .filter_mode = initial_filter_mode,
            .max_visible_lines = @max(@as(usize, 5), terminal_height / 2),
        };
        errdefer selector.deinit();

        var flat: std.ArrayList(FlatNode) = .empty;
        for (roots) |root| {
            try selector.flattenNode(&flat, root, null);
        }
        selector.flat_nodes = try flat.toOwnedSlice(selector.arena.allocator());

        try selector.rebuildFilter();
        selector.selected_index = selector.findNearestVisibleIndex(initial_selected_id orelse current_leaf_id);
        selector.last_selected_id = selector.selectedId();
        return selector;
    }

    pub fn deinit(self: *TreeSelector) void {
        self.search_query.deinit(self.allocator);
        self.folded_nodes.deinit();
        self.filter_arena.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn selectedNode(self: *const TreeSelector) ?*SessionTreeNode {
        if (self.filtered_indices.len == 0) return null;
        const clamped = @min(self.selected_index, self.filtered_indices.len - 1);
        return self.flat_nodes[self.filtered_indices[clamped]].node;
    }

    pub fn getSearchQuery(self: *const TreeSelector) []const u8 {
        return self.search_query.items;
    }

    pub fn updateNodeLabel(
        self: *TreeSelector,
        entry_id: []const u8,
        label: ?[]const u8,
        label_timestamp: ?[]const u8,
    ) void {
        for (self.flat_nodes) |flat| {
            const id = entryId(flat.node) orelse continue;
            if (!std.mem.eql(u8, id, entry_id)) continue;
            flat.node.label = label;
            flat.node.label_timestamp = if (label != null) label_timestamp else null;
            return;
        }
    }

    pub fn handleInput(self: *TreeSelector, key_data: []const u8) !void {
        if (std.mem.eql(u8, key_data, "\x1b[A")) {
            if (self.filtered_indices.len > 0) {
                self.selected_index = if (self.selected_index == 0) self.filtered_indices.len - 1 else self.selected_index - 1;
                self.last_selected_id = self.selectedId();
            }
            return;
        }
        if (std.mem.eql(u8, key_data, "\x1b[B")) {
            if (self.filtered_indices.len > 0) {
                self.selected_index = if (self.selected_index + 1 >= self.filtered_indices.len) 0 else self.selected_index + 1;
                self.last_selected_id = self.selectedId();
            }
            return;
        }
        if (isFoldOrUpKey(key_data)) {
            const current_flat = self.selectedFlatIndex() orelse return;
            const id = entryId(self.flat_nodes[current_flat].node) orelse return;
            if (self.isFoldable(current_flat) and !self.folded_nodes.contains(id)) {
                try self.folded_nodes.put(id, {});
                try self.applyFilter();
            } else {
                self.selected_index = self.findBranchSegmentStart(.up);
                self.last_selected_id = self.selectedId();
            }
            return;
        }
        if (isUnfoldOrDownKey(key_data)) {
            const current_flat = self.selectedFlatIndex() orelse return;
            const id = entryId(self.flat_nodes[current_flat].node) orelse return;
            if (self.folded_nodes.remove(id)) {
                try self.applyFilter();
            } else {
                self.selected_index = self.findBranchSegmentStart(.down);
                self.last_selected_id = self.selectedId();
            }
            return;
        }
        if (std.mem.eql(u8, key_data, "\x04")) {
            self.filter_mode = .default;
            self.folded_nodes.clearRetainingCapacity();
            try self.applyFilter();
            return;
        }
        if (std.mem.eql(u8, key_data, "\x15")) {
            self.filter_mode = if (self.filter_mode == .user_only) .default else .user_only;
            self.folded_nodes.clearRetainingCapacity();
            try self.applyFilter();
            return;
        }
        if (std.mem.eql(u8, key_data, "\x0c")) {
            self.filter_mode = if (self.filter_mode == .labeled_only) .default else .labeled_only;
            self.folded_nodes.clearRetainingCapacity();
            try self.applyFilter();
            return;
        }
        if (std.mem.eql(u8, key_data, "\x14")) {
            self.filter_mode = if (self.filter_mode == .no_tools) .default else .no_tools;
            self.folded_nodes.clearRetainingCapacity();
            try self.applyFilter();
            return;
        }
        if (std.mem.eql(u8, key_data, "\x01")) {
            self.filter_mode = if (self.filter_mode == .all) .default else .all;
            self.folded_nodes.clearRetainingCapacity();
            try self.applyFilter();
            return;
        }
        if (std.mem.eql(u8, key_data, "T")) {
            self.show_label_timestamps = !self.show_label_timestamps;
            return;
        }
        if (std.mem.eql(u8, key_data, "\x1b")) {
            if (self.search_query.items.len > 0) {
                self.search_query.clearRetainingCapacity();
                self.folded_nodes.clearRetainingCapacity();
                try self.applyFilter();
            }
            return;
        }
        if (std.mem.eql(u8, key_data, "\x7f")) {
            if (self.search_query.items.len > 0) {
                self.search_query.shrinkRetainingCapacity(self.search_query.items.len - 1);
                self.folded_nodes.clearRetainingCapacity();
                try self.applyFilter();
            }
            return;
        }
        if (isTextInput(key_data)) {
            try self.search_query.appendSlice(self.allocator, key_data);
            self.folded_nodes.clearRetainingCapacity();
            try self.applyFilter();
        }
    }

    pub fn renderAlloc(self: *const TreeSelector, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        if (self.filtered_indices.len == 0) {
            try lines.append(allocator, try truncateLineAlloc(allocator, "  No entries found", width));
            const status = try std.fmt.allocPrint(allocator, "  (0/0){s}", .{self.statusLabels()});
            defer allocator.free(status);
            try lines.append(allocator, try truncateLineAlloc(allocator, status, width));
            return lines.toOwnedSlice(allocator);
        }

        const start_index = startIndexForSelection(self.selected_index, self.filtered_indices.len, self.max_visible_lines);
        const end_index = @min(start_index + self.max_visible_lines, self.filtered_indices.len);
        for (start_index..end_index) |filtered_index| {
            const flat_index = self.filtered_indices[filtered_index];
            const flat = self.flat_nodes[flat_index];
            const selected_prefix: []const u8 = if (filtered_index == self.selected_index) "> " else "  ";
            const label = flat.node.label orelse "";
            const label_prefix = if (label.len > 0) try std.fmt.allocPrint(allocator, "[{s}] ", .{label}) else try allocator.dupe(u8, "");
            defer allocator.free(label_prefix);
            const label_time = if (self.show_label_timestamps and label.len > 0 and flat.node.label_timestamp != null)
                try formatLabelTimestampAlloc(allocator, flat.node.label_timestamp.?)
            else
                try allocator.dupe(u8, "");
            defer allocator.free(label_time);
            const label_time_prefix = if (label_time.len > 0) try std.fmt.allocPrint(allocator, "{s} ", .{label_time}) else try allocator.dupe(u8, "");
            defer allocator.free(label_time_prefix);
            const content = try entryDisplayTextAlloc(allocator, flat.node);
            defer allocator.free(content);
            const line = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
                selected_prefix,
                label_prefix,
                label_time_prefix,
                content,
            });
            defer allocator.free(line);
            try lines.append(allocator, try truncateLineAlloc(allocator, line, width));
        }

        const status = try std.fmt.allocPrint(allocator, "  ({d}/{d}){s}", .{
            self.selected_index + 1,
            self.filtered_indices.len,
            self.statusLabels(),
        });
        defer allocator.free(status);
        try lines.append(allocator, try truncateLineAlloc(allocator, status, width));

        return lines.toOwnedSlice(allocator);
    }

    fn flattenNode(
        self: *TreeSelector,
        flat: *std.ArrayList(FlatNode),
        node: *SessionTreeNode,
        parent_index: ?usize,
    ) !void {
        const index = flat.items.len;
        try flat.append(self.arena.allocator(), .{
            .node = node,
            .parent_index = parent_index,
        });
        for (node.children) |child| {
            try self.flattenNode(flat, child, index);
        }
    }

    fn applyFilter(self: *TreeSelector) !void {
        if (self.selectedId()) |id| self.last_selected_id = id;
        try self.rebuildFilter();
        if (self.last_selected_id) |id| {
            self.selected_index = self.findNearestVisibleIndex(id);
        } else if (self.filtered_indices.len == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= self.filtered_indices.len) {
            self.selected_index = self.filtered_indices.len - 1;
        }
        if (self.selectedId()) |id| self.last_selected_id = id;
    }

    fn rebuildFilter(self: *TreeSelector) !void {
        _ = self.filter_arena.reset(.retain_capacity);
        const filter_allocator = self.filter_arena.allocator();

        const skip = try filter_allocator.alloc(bool, self.flat_nodes.len);
        @memset(skip, false);
        for (self.flat_nodes, 0..) |flat, index| {
            if (flat.parent_index) |parent_index| {
                const parent_id = entryId(self.flat_nodes[parent_index].node);
                skip[index] = skip[parent_index] or (parent_id != null and self.folded_nodes.contains(parent_id.?));
            }
        }

        var filtered: std.ArrayList(usize) = .empty;
        for (self.flat_nodes, 0..) |flat, index| {
            if (skip[index]) continue;
            if (try self.nodePassesFilter(filter_allocator, flat.node)) {
                try filtered.append(filter_allocator, index);
            }
        }
        self.filtered_indices = try filtered.toOwnedSlice(filter_allocator);

        const visible = try filter_allocator.alloc(bool, self.flat_nodes.len);
        @memset(visible, false);
        for (self.filtered_indices) |flat_index| visible[flat_index] = true;

        self.visible_parent = try filter_allocator.alloc(?usize, self.flat_nodes.len);
        for (self.visible_parent) |*parent| parent.* = null;

        self.visible_children = try filter_allocator.alloc(std.ArrayList(usize), self.flat_nodes.len);
        for (self.visible_children) |*children| children.* = .empty;

        var roots: std.ArrayList(usize) = .empty;
        for (self.filtered_indices) |flat_index| {
            const parent_index = nearestVisibleParent(self.flat_nodes, visible, flat_index);
            self.visible_parent[flat_index] = parent_index;
            if (parent_index) |parent| {
                try self.visible_children[parent].append(filter_allocator, flat_index);
            } else {
                try roots.append(filter_allocator, flat_index);
            }
        }
        self.root_indices = try roots.toOwnedSlice(filter_allocator);
    }

    fn nodePassesFilter(self: *const TreeSelector, allocator: std.mem.Allocator, node: *SessionTreeNode) !bool {
        const id = entryId(node);
        const is_current_leaf = id != null and self.current_leaf_id != null and std.mem.eql(u8, id.?, self.current_leaf_id.?);
        if (!is_current_leaf and isAssistantHiddenByDefault(allocator, node.entry.raw_json)) {
            return false;
        }

        const passes_filter = switch (self.filter_mode) {
            .user_only => entryIsMessageRole(allocator, node.entry.raw_json, "user"),
            .no_tools => !isSettingsEntry(node) and !entryIsMessageRole(allocator, node.entry.raw_json, "toolResult"),
            .labeled_only => node.label != null,
            .all => true,
            .default => !isSettingsEntry(node),
        };
        if (!passes_filter) return false;

        if (self.search_query.items.len == 0) return true;
        const searchable = try searchableTextAlloc(allocator, node);
        const lower_searchable = try std.ascii.allocLowerString(allocator, searchable);
        const lower_query = try std.ascii.allocLowerString(allocator, self.search_query.items);
        var tokens = std.mem.tokenizeAny(u8, lower_query, " \t\r\n");
        while (tokens.next()) |token| {
            if (std.mem.indexOf(u8, lower_searchable, token) == null) return false;
        }
        return true;
    }

    fn findNearestVisibleIndex(self: *const TreeSelector, target_id: ?[]const u8) usize {
        if (self.filtered_indices.len == 0) return 0;
        var current_id = target_id;
        while (current_id) |id| {
            for (self.filtered_indices, 0..) |flat_index, filtered_index| {
                const flat_id = entryId(self.flat_nodes[flat_index].node) orelse continue;
                if (std.mem.eql(u8, flat_id, id)) return filtered_index;
            }
            const flat_index = self.findFlatIndexById(id) orelse break;
            current_id = if (self.flat_nodes[flat_index].parent_index) |parent_index|
                entryId(self.flat_nodes[parent_index].node)
            else
                null;
        }
        return self.filtered_indices.len - 1;
    }

    fn findFlatIndexById(self: *const TreeSelector, id: []const u8) ?usize {
        for (self.flat_nodes, 0..) |flat, index| {
            const node_id = entryId(flat.node) orelse continue;
            if (std.mem.eql(u8, node_id, id)) return index;
        }
        return null;
    }

    fn selectedFlatIndex(self: *const TreeSelector) ?usize {
        if (self.filtered_indices.len == 0) return null;
        return self.filtered_indices[@min(self.selected_index, self.filtered_indices.len - 1)];
    }

    fn selectedId(self: *const TreeSelector) ?[]const u8 {
        const flat_index = self.selectedFlatIndex() orelse return null;
        return entryId(self.flat_nodes[flat_index].node);
    }

    fn isFoldable(self: *const TreeSelector, flat_index: usize) bool {
        if (flat_index >= self.visible_children.len) return false;
        if (self.visible_children[flat_index].items.len == 0) return false;
        const parent_index = self.visible_parent[flat_index] orelse return true;
        return self.visible_children[parent_index].items.len > 1;
    }

    const BranchDirection = enum { up, down };

    fn findBranchSegmentStart(self: *const TreeSelector, direction: BranchDirection) usize {
        const selected_flat = self.selectedFlatIndex() orelse return self.selected_index;
        if (direction == .down) {
            var current = selected_flat;
            while (true) {
                const children = self.visible_children[current].items;
                if (children.len == 0) return self.filteredIndexOfFlat(current) orelse self.selected_index;
                if (children.len > 1) return self.filteredIndexOfFlat(children[0]) orelse self.selected_index;
                current = children[0];
            }
        }

        var current = selected_flat;
        while (true) {
            const parent = self.visible_parent[current] orelse return self.filteredIndexOfFlat(current) orelse self.selected_index;
            const siblings = self.visible_children[parent].items;
            if (siblings.len > 1) {
                const segment_index = self.filteredIndexOfFlat(current) orelse self.selected_index;
                if (segment_index < self.selected_index) return segment_index;
            }
            current = parent;
        }
    }

    fn filteredIndexOfFlat(self: *const TreeSelector, flat_index: usize) ?usize {
        for (self.filtered_indices, 0..) |candidate, filtered_index| {
            if (candidate == flat_index) return filtered_index;
        }
        return null;
    }

    fn statusLabels(self: *const TreeSelector) []const u8 {
        if (self.show_label_timestamps) {
            return switch (self.filter_mode) {
                .default => " [+label time]",
                .no_tools => " [no-tools] [+label time]",
                .user_only => " [user] [+label time]",
                .labeled_only => " [labeled] [+label time]",
                .all => " [all] [+label time]",
            };
        }
        return switch (self.filter_mode) {
            .default => "",
            .no_tools => " [no-tools]",
            .user_only => " [user]",
            .labeled_only => " [labeled]",
            .all => " [all]",
        };
    }
};

fn nearestVisibleParent(flat_nodes: []const FlatNode, visible: []const bool, flat_index: usize) ?usize {
    var parent = flat_nodes[flat_index].parent_index;
    while (parent) |parent_index| {
        if (visible[parent_index]) return parent_index;
        parent = flat_nodes[parent_index].parent_index;
    }
    return null;
}

fn entryId(node: *const SessionTreeNode) ?[]const u8 {
    return node.entry.id;
}

fn isSettingsEntry(node: *const SessionTreeNode) bool {
    const entry_type = node.entry.entry_type orelse return false;
    return std.mem.eql(u8, entry_type, "label") or
        std.mem.eql(u8, entry_type, "custom") or
        std.mem.eql(u8, entry_type, "model_change") or
        std.mem.eql(u8, entry_type, "thinking_level_change") or
        std.mem.eql(u8, entry_type, "session_info");
}

fn entryIsMessageRole(allocator: std.mem.Allocator, raw_json: []const u8, expected_role: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw_json, .{}) catch return false;
    if (parsed != .object) return false;
    const message = parsed.object.get("message") orelse return false;
    if (message != .object) return false;
    const role = objectString(message.object, "role") orelse return false;
    return std.mem.eql(u8, role, expected_role);
}

fn isAssistantHiddenByDefault(allocator: std.mem.Allocator, raw_json: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw_json, .{}) catch return false;
    if (parsed != .object) return false;
    const message = parsed.object.get("message") orelse return false;
    if (message != .object) return false;
    const role = objectString(message.object, "role") orelse return false;
    if (!std.mem.eql(u8, role, "assistant")) return false;
    if (hasTextContent(message.object.get("content"))) return false;
    const stop_reason = objectString(message.object, "stopReason");
    return stop_reason == null or std.mem.eql(u8, stop_reason.?, "stop") or std.mem.eql(u8, stop_reason.?, "toolUse");
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn hasTextContent(value: ?std.json.Value) bool {
    const content = value orelse return false;
    switch (content) {
        .string => |text| return std.mem.trim(u8, text, " \t\r\n").len > 0,
        .array => |array| {
            for (array.items) |item| {
                if (item != .object) continue;
                const type_value = objectString(item.object, "type") orelse continue;
                if (!std.mem.eql(u8, type_value, "text")) continue;
                const text = objectString(item.object, "text") orelse continue;
                if (std.mem.trim(u8, text, " \t\r\n").len > 0) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn searchableTextAlloc(allocator: std.mem.Allocator, node: *const SessionTreeNode) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    if (node.label) |label| {
        try text.appendSlice(allocator, label);
        try text.append(allocator, ' ');
    }
    const display = try entryDisplayTextAlloc(allocator, node);
    defer allocator.free(display);
    try text.appendSlice(allocator, display);
    return text.toOwnedSlice(allocator);
}

fn entryDisplayTextAlloc(allocator: std.mem.Allocator, node: *const SessionTreeNode) ![]u8 {
    const entry_type = node.entry.entry_type orelse "";
    if (std.mem.eql(u8, entry_type, "model_change")) {
        const model_id = try session_manager.entryStringFieldAlloc(allocator, node.entry.raw_json, "modelId") orelse try allocator.dupe(u8, "");
        defer allocator.free(model_id);
        return std.fmt.allocPrint(allocator, "[model: {s}]", .{model_id});
    }
    if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
        const thinking = try session_manager.entryStringFieldAlloc(allocator, node.entry.raw_json, "thinkingLevel") orelse try allocator.dupe(u8, "");
        defer allocator.free(thinking);
        return std.fmt.allocPrint(allocator, "[thinking: {s}]", .{thinking});
    }
    if (!std.mem.eql(u8, entry_type, "message")) {
        return std.fmt.allocPrint(allocator, "[{s}]", .{entry_type});
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), node.entry.raw_json, .{}) catch {
        return allocator.dupe(u8, "[message]");
    };
    if (parsed != .object) return allocator.dupe(u8, "[message]");
    const message = parsed.object.get("message") orelse return allocator.dupe(u8, "[message]");
    if (message != .object) return allocator.dupe(u8, "[message]");
    const role = objectString(message.object, "role") orelse "message";
    const content = try extractContentAlloc(allocator, message.object.get("content"));
    defer allocator.free(content);
    if (std.mem.eql(u8, role, "user")) return std.fmt.allocPrint(allocator, "user: {s}", .{content});
    if (std.mem.eql(u8, role, "assistant")) {
        if (content.len > 0) return std.fmt.allocPrint(allocator, "assistant: {s}", .{content});
        return allocator.dupe(u8, "assistant: (no content)");
    }
    return std.fmt.allocPrint(allocator, "[{s}]", .{role});
}

fn extractContentAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    const content = value orelse return allocator.dupe(u8, "");
    switch (content) {
        .string => |text| return allocator.dupe(u8, normalizeInline(text)),
        .array => |array| {
            var text: std.ArrayList(u8) = .empty;
            for (array.items) |item| {
                if (item != .object) continue;
                const type_value = objectString(item.object, "type") orelse continue;
                if (!std.mem.eql(u8, type_value, "text")) continue;
                const block_text = objectString(item.object, "text") orelse continue;
                try text.appendSlice(allocator, block_text);
                if (text.items.len >= 200) break;
            }
            const joined = try text.toOwnedSlice(allocator);
            errdefer allocator.free(joined);
            const normalized = try allocator.dupe(u8, normalizeInline(joined));
            allocator.free(joined);
            return normalized;
        },
        else => return allocator.dupe(u8, ""),
    }
}

fn normalizeInline(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn formatLabelTimestampAlloc(allocator: std.mem.Allocator, timestamp: []const u8) ![]u8 {
    if (timestamp.len < 16) return allocator.dupe(u8, timestamp);
    const month = std.fmt.parseInt(u8, timestamp[5..7], 10) catch return allocator.dupe(u8, timestamp);
    const day = std.fmt.parseInt(u8, timestamp[8..10], 10) catch return allocator.dupe(u8, timestamp);
    const time_index = std.mem.indexOfScalar(u8, timestamp, 'T') orelse
        (std.mem.indexOfScalar(u8, timestamp, ' ') orelse return allocator.dupe(u8, timestamp));
    if (time_index + 6 > timestamp.len) return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(allocator, "{d}/{d} {s}", .{ month, day, timestamp[time_index + 1 .. time_index + 6] });
}

fn truncateLineAlloc(allocator: std.mem.Allocator, line: []const u8, width: usize) ![]u8 {
    if (line.len <= width) return allocator.dupe(u8, line);
    return allocator.dupe(u8, line[0..width]);
}

fn startIndexForSelection(selected_index: usize, total: usize, max_visible: usize) usize {
    if (total <= max_visible) return 0;
    const half = max_visible / 2;
    const centered = if (selected_index > half) selected_index - half else 0;
    return @min(centered, total - max_visible);
}

fn isFoldOrUpKey(key_data: []const u8) bool {
    return std.mem.eql(u8, key_data, "\x1b[1;5D") or std.mem.eql(u8, key_data, "\x1b[1;3D");
}

fn isUnfoldOrDownKey(key_data: []const u8) bool {
    return std.mem.eql(u8, key_data, "\x1b[1;5C") or std.mem.eql(u8, key_data, "\x1b[1;3C");
}

fn isTextInput(key_data: []const u8) bool {
    if (key_data.len == 0) return false;
    for (key_data) |byte| {
        if (byte < 0x20 or byte == 0x7f or (byte >= 0x80 and byte <= 0x9f)) return false;
    }
    return true;
}

const TestTree = struct {
    arena: std.heap.ArenaAllocator,
    roots: []*SessionTreeNode,

    fn deinit(self: *TestTree) void {
        self.arena.deinit();
    }
};

fn testBuildTree(allocator: std.mem.Allocator, entries: []const session_manager.FileEntry) !TestTree {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var by_id = std.StringHashMap(usize).init(allocator);
    defer by_id.deinit();
    for (entries, 0..) |entry, index| {
        if (entry.id) |id| try by_id.put(id, index);
    }

    var child_counts = try allocator.alloc(usize, entries.len);
    defer allocator.free(child_counts);
    @memset(child_counts, 0);
    var root_count: usize = 0;
    for (entries) |entry| {
        const parent = try session_manager.entryStringFieldAlloc(allocator, entry.raw_json, "parentId");
        defer if (parent) |value| allocator.free(value);
        if (parent) |parent_id| {
            if (by_id.get(parent_id)) |parent_index| {
                child_counts[parent_index] += 1;
                continue;
            }
        }
        root_count += 1;
    }

    const nodes = try arena_allocator.alloc(SessionTreeNode, entries.len);
    for (entries, 0..) |entry, index| {
        nodes[index] = .{
            .entry = .{
                .raw_json = try arena_allocator.dupe(u8, entry.raw_json),
                .entry_type = if (entry.entry_type) |value| try arena_allocator.dupe(u8, value) else null,
                .id = if (entry.id) |value| try arena_allocator.dupe(u8, value) else null,
            },
            .children = try arena_allocator.alloc(*SessionTreeNode, child_counts[index]),
        };
        child_counts[index] = 0;
    }

    const roots = try arena_allocator.alloc(*SessionTreeNode, root_count);
    var root_index: usize = 0;
    for (entries, 0..) |entry, index| {
        const parent = try session_manager.entryStringFieldAlloc(allocator, entry.raw_json, "parentId");
        defer if (parent) |value| allocator.free(value);
        if (parent) |parent_id| {
            if (by_id.get(parent_id)) |parent_index| {
                const child_index = child_counts[parent_index];
                nodes[parent_index].children[child_index] = &nodes[index];
                child_counts[parent_index] = child_index + 1;
                continue;
            }
        }
        roots[root_index] = &nodes[index];
        root_index += 1;
    }

    return .{ .arena = arena, .roots = roots };
}

fn testMessageEntry(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    role: []const u8,
    content: []const u8,
) !session_manager.FileEntry {
    const parent = if (parent_id) |value| try std.fmt.allocPrint(allocator, "\"{s}\"", .{value}) else try allocator.dupe(u8, "null");
    defer allocator.free(parent);
    const raw_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"message\",\"id\":\"{s}\",\"parentId\":{s},\"timestamp\":\"2026-03-28T14:32:00.000Z\",\"message\":{{\"role\":\"{s}\",\"content\":\"{s}\"}}}}",
        .{ id, parent, role, content },
    );
    return .{ .raw_json = raw_json, .entry_type = "message", .id = id };
}

fn testAssistantTextEntry(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    text: []const u8,
) !session_manager.FileEntry {
    const parent = if (parent_id) |value| try std.fmt.allocPrint(allocator, "\"{s}\"", .{value}) else try allocator.dupe(u8, "null");
    defer allocator.free(parent);
    const raw_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"message\",\"id\":\"{s}\",\"parentId\":{s},\"timestamp\":\"2026-03-28T14:32:00.000Z\",\"message\":{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"stopReason\":\"stop\"}}}}",
        .{ id, parent, text },
    );
    return .{ .raw_json = raw_json, .entry_type = "message", .id = id };
}

fn testToolCallOnlyAssistant(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
) !session_manager.FileEntry {
    const parent = if (parent_id) |value| try std.fmt.allocPrint(allocator, "\"{s}\"", .{value}) else try allocator.dupe(u8, "null");
    defer allocator.free(parent);
    const raw_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"message\",\"id\":\"{s}\",\"parentId\":{s},\"timestamp\":\"2026-03-28T14:32:00.000Z\",\"message\":{{\"role\":\"assistant\",\"content\":[{{\"type\":\"toolCall\",\"id\":\"tc-{s}\",\"name\":\"read\",\"arguments\":{{\"path\":\"test.ts\"}}}}],\"stopReason\":\"toolUse\"}}}}",
        .{ id, parent, id },
    );
    return .{ .raw_json = raw_json, .entry_type = "message", .id = id };
}

fn testMetadataEntry(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    entry_type: []const u8,
    field_name: []const u8,
    field_value: []const u8,
) !session_manager.FileEntry {
    const parent = if (parent_id) |value| try std.fmt.allocPrint(allocator, "\"{s}\"", .{value}) else try allocator.dupe(u8, "null");
    defer allocator.free(parent);
    const raw_json = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"{s}\",\"id\":\"{s}\",\"parentId\":{s},\"timestamp\":\"2026-03-28T14:32:00.000Z\",\"{s}\":\"{s}\"}}",
        .{ entry_type, id, parent, field_name, field_value },
    );
    return .{ .raw_json = raw_json, .entry_type = entry_type, .id = id };
}

fn freeEntries(allocator: std.mem.Allocator, entries: []const session_manager.FileEntry) void {
    for (entries) |entry| allocator.free(@constCast(entry.raw_json));
}

fn expectSelected(selector: *const TreeSelector, expected_id: []const u8) !void {
    const selected = selector.selectedNode() orelse return error.MissingSelectedNode;
    try std.testing.expectEqualStrings(expected_id, selected.entry.id.?);
}

fn renderContains(allocator: std.mem.Allocator, selector: *const TreeSelector, needle: []const u8) !bool {
    const lines = try selector.renderAlloc(allocator, 200);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

fn testBranchingTree(allocator: std.mem.Allocator) !struct {
    entries: [11]session_manager.FileEntry,
    tree: TestTree,
} {
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "first message"),
        try testAssistantTextEntry(allocator, "asst-1", "user-1", "response 1"),
        try testMessageEntry(allocator, "user-2", "asst-1", "user", "second message"),
        try testAssistantTextEntry(allocator, "asst-2", "user-2", "response 2"),
        try testMessageEntry(allocator, "user-3a", "asst-2", "user", "branch A start"),
        try testAssistantTextEntry(allocator, "asst-3a", "user-3a", "branch A response"),
        try testMessageEntry(allocator, "user-4a", "asst-3a", "user", "branch A deep"),
        try testAssistantTextEntry(allocator, "asst-4a", "user-4a", "branch A leaf"),
        try testMessageEntry(allocator, "user-3b", "asst-2", "user", "branch B start"),
        try testAssistantTextEntry(allocator, "asst-3b", "user-3b", "branch B response"),
        try testMessageEntry(allocator, "user-4b", "asst-3b", "user", "branch B deep"),
    };
    const tree = try testBuildTree(allocator, &entries);
    return .{ .entries = entries, .tree = tree };
}

test "tree selector focuses nearest visible ancestor for metadata leaves" {
    const allocator = std.testing.allocator;
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "hello"),
        try testAssistantTextEntry(allocator, "asst-1", "user-1", "hi"),
        try testMessageEntry(allocator, "user-2", "asst-1", "user", "active branch"),
        try testMetadataEntry(allocator, "model-1", "user-2", "model_change", "modelId", "claude-sonnet-4"),
        try testMessageEntry(allocator, "user-3", "asst-1", "user", "sibling branch"),
    };
    defer freeEntries(allocator, &entries);
    var tree = try testBuildTree(allocator, &entries);
    defer tree.deinit();

    var selector = try TreeSelector.init(allocator, tree.roots, "model-1", 24);
    defer selector.deinit();
    try expectSelected(&selector, "user-2");
}

test "tree selector focuses nearest visible ancestor for thinking-level metadata leaf" {
    const allocator = std.testing.allocator;
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "hello"),
        try testAssistantTextEntry(allocator, "asst-1", "user-1", "hi"),
        try testMessageEntry(allocator, "user-2", "asst-1", "user", "active branch"),
        try testMetadataEntry(allocator, "thinking-1", "user-2", "thinking_level_change", "thinkingLevel", "high"),
        try testMessageEntry(allocator, "user-3", "asst-1", "user", "sibling branch"),
    };
    defer freeEntries(allocator, &entries);
    var tree = try testBuildTree(allocator, &entries);
    defer tree.deinit();

    var selector = try TreeSelector.init(allocator, tree.roots, "thinking-1", 24);
    defer selector.deinit();
    try expectSelected(&selector, "user-2");
}

test "tree selector switches to nearest visible user message when changing filters" {
    const allocator = std.testing.allocator;
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "hello"),
        try testAssistantTextEntry(allocator, "asst-1", "user-1", "hi"),
        try testMessageEntry(allocator, "user-2", "asst-1", "user", "active branch"),
        try testAssistantTextEntry(allocator, "asst-2", "user-2", "response"),
        try testMessageEntry(allocator, "user-3", "asst-1", "user", "sibling branch"),
    };
    defer freeEntries(allocator, &entries);
    var tree = try testBuildTree(allocator, &entries);
    defer tree.deinit();

    var selector = try TreeSelector.init(allocator, tree.roots, "asst-2", 24);
    defer selector.deinit();
    try expectSelected(&selector, "asst-2");

    try selector.handleInput("\x15");
    try expectSelected(&selector, "user-2");

    try selector.handleInput("\x04");
    try expectSelected(&selector, "user-2");
}

test "tree selector toggles label timestamps for labeled nodes" {
    const allocator = std.testing.allocator;
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "hello"),
        try testAssistantTextEntry(allocator, "asst-1", "user-1", "hi"),
    };
    defer freeEntries(allocator, &entries);
    var tree = try testBuildTree(allocator, &entries);
    defer tree.deinit();
    tree.roots[0].label = "checkpoint";
    tree.roots[0].label_timestamp = "2026-03-28T14:32:00.000Z";

    var selector = try TreeSelector.init(allocator, tree.roots, "asst-1", 24);
    defer selector.deinit();

    try std.testing.expect(try renderContains(allocator, &selector, "[checkpoint]"));
    try std.testing.expect(!try renderContains(allocator, &selector, "3/28 14:32"));
    try std.testing.expect(!try renderContains(allocator, &selector, "[+label time]"));

    try selector.handleInput("T");
    try std.testing.expect(try renderContains(allocator, &selector, "3/28 14:32"));
    try std.testing.expect(try renderContains(allocator, &selector, "[+label time]"));
}

test "tree selector preserves selection through empty labeled filters" {
    const allocator = std.testing.allocator;
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "hello"),
        try testAssistantTextEntry(allocator, "asst-1", "user-1", "hi"),
        try testMessageEntry(allocator, "user-2", "asst-1", "user", "bye"),
        try testAssistantTextEntry(allocator, "asst-2", "user-2", "goodbye"),
    };
    defer freeEntries(allocator, &entries);
    var tree = try testBuildTree(allocator, &entries);
    defer tree.deinit();

    var selector = try TreeSelector.init(allocator, tree.roots, "asst-2", 24);
    defer selector.deinit();
    try expectSelected(&selector, "asst-2");

    try selector.handleInput("\x0c");
    try std.testing.expect(selector.selectedNode() == null);

    try selector.handleInput("\x04");
    try expectSelected(&selector, "asst-2");

    try selector.handleInput("\x0c");
    try std.testing.expect(selector.selectedNode() == null);
    try selector.handleInput("\x0c");
    try expectSelected(&selector, "asst-2");
}

test "tree selector ctrl-right unfolds then jumps down branch segment" {
    const allocator = std.testing.allocator;
    var fixture = try testBranchingTree(allocator);
    defer freeEntries(allocator, &fixture.entries);
    defer fixture.tree.deinit();

    var selector = try TreeSelector.init(allocator, fixture.tree.roots, "asst-4a", 24);
    defer selector.deinit();

    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "user-3b");
    try selector.handleInput("\x1b[A");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[1;5C");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "asst-3a");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[1;5C");
    try expectSelected(&selector, "asst-4a");
}

test "tree selector alt-left and alt-right alias branch fold navigation" {
    const allocator = std.testing.allocator;
    var fixture = try testBranchingTree(allocator);
    defer freeEntries(allocator, &fixture.entries);
    defer fixture.tree.deinit();

    var selector = try TreeSelector.init(allocator, fixture.tree.roots, "asst-4a", 24);
    defer selector.deinit();

    try selector.handleInput("\x1b[1;3D");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[1;3D");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[1;3C");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[1;3C");
    try expectSelected(&selector, "asst-4a");
}

test "tree selector preserves nested folded branch when root unfolds" {
    const allocator = std.testing.allocator;
    var fixture = try testBranchingTree(allocator);
    defer freeEntries(allocator, &fixture.entries);
    defer fixture.tree.deinit();

    var selector = try TreeSelector.init(allocator, fixture.tree.roots, "asst-4a", 24);
    defer selector.deinit();

    try selector.handleInput("\x1b[1;5D");
    try selector.handleInput("\x1b[1;5D");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[1;5C");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[1;5C");
    try expectSelected(&selector, "user-3a");
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "user-3b");
}

test "tree selector folds and navigates non-active branches" {
    const allocator = std.testing.allocator;
    var fixture = try testBranchingTree(allocator);
    defer freeEntries(allocator, &fixture.entries);
    defer fixture.tree.deinit();

    var selector = try TreeSelector.init(allocator, fixture.tree.roots, "asst-4a", 24);
    defer selector.deinit();

    var found = false;
    for (0..20) |_| {
        try selector.handleInput("\x1b[B");
        if (selector.selectedNode()) |selected| {
            if (std.mem.eql(u8, selected.entry.id.?, "user-3b")) {
                found = true;
                break;
            }
        }
    }
    try std.testing.expect(found);

    try selector.handleInput("\x1b[1;5C");
    try expectSelected(&selector, "user-4b");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-3b");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-3b");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-1");
}

test "tree selector folds and navigates multiple roots" {
    const allocator = std.testing.allocator;
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "first root"),
        try testAssistantTextEntry(allocator, "asst-1", "user-1", "response 1"),
        try testMessageEntry(allocator, "user-2", null, "user", "second root"),
        try testAssistantTextEntry(allocator, "asst-2", "user-2", "response 2"),
    };
    defer freeEntries(allocator, &entries);
    var tree = try testBuildTree(allocator, &entries);
    defer tree.deinit();

    var selector = try TreeSelector.init(allocator, tree.roots, "asst-1", 24);
    defer selector.deinit();
    try expectSelected(&selector, "asst-1");

    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "user-2");
    try selector.handleInput("\x1b[1;5C");
    try expectSelected(&selector, "asst-2");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-2");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-2");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-2");
}

test "tree selector folded root hides descendants through filtered intermediate nodes" {
    const allocator = std.testing.allocator;
    var entries = [_]session_manager.FileEntry{
        try testMessageEntry(allocator, "user-1", null, "user", "hello"),
        try testToolCallOnlyAssistant(allocator, "tool-asst-1", "user-1"),
        try testMessageEntry(allocator, "user-2", "tool-asst-1", "user", "follow up"),
        try testAssistantTextEntry(allocator, "asst-2", "user-2", "response"),
    };
    defer freeEntries(allocator, &entries);
    var tree = try testBuildTree(allocator, &entries);
    defer tree.deinit();

    var selector = try TreeSelector.init(allocator, tree.roots, "asst-2", 24);
    defer selector.deinit();
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[1;5D");
    try expectSelected(&selector, "user-1");
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "user-1");
}

test "tree selector search and filter mode changes reset fold state" {
    const allocator = std.testing.allocator;
    var fixture = try testBranchingTree(allocator);
    defer freeEntries(allocator, &fixture.entries);
    defer fixture.tree.deinit();

    var selector = try TreeSelector.init(allocator, fixture.tree.roots, "asst-4a", 24);
    defer selector.deinit();
    try selector.handleInput("\x1b[1;5D");
    try selector.handleInput("\x1b[1;5D");
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "user-3b");
    try selector.handleInput("b");
    try selector.handleInput("\x1b");

    var current_id: []const u8 = "";
    for (0..20) |_| {
        try selector.handleInput("\x1b[B");
        current_id = selector.selectedNode().?.entry.id.?;
        if (std.mem.eql(u8, current_id, "user-3a")) break;
    }
    try std.testing.expectEqualStrings("user-3a", current_id);
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "asst-3a");

    try selector.handleInput("\x1b[1;5D");
    try selector.handleInput("\x1b[1;5D");
    try selector.handleInput("\x15");
    try selector.handleInput("\x04");
    for (0..20) |_| {
        try selector.handleInput("\x1b[B");
        current_id = selector.selectedNode().?.entry.id.?;
        if (std.mem.eql(u8, current_id, "user-3a")) break;
    }
    try std.testing.expectEqualStrings("user-3a", current_id);
    try selector.handleInput("\x1b[B");
    try expectSelected(&selector, "asst-3a");
}
