const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const tui = @import("bulb_tui");

pub const KeybindingDefinition = tui.keybindings.KeybindingDefinition;
pub const KeybindingValue = tui.keybindings.KeybindingValue;
pub const KeybindingValueKind = tui.keybindings.KeybindingValueKind;
pub const KeybindingsConfig = tui.keybindings.KeybindingsConfig;
pub const KeybindingConflict = tui.keybindings.KeybindingConflict;

const max_keybindings_file_bytes = 1024 * 1024;

const APP_KEYBINDINGS = [_]KeybindingDefinition{
    binding("app.interrupt", &.{"escape"}, "Cancel or abort"),
    binding("app.clear", &.{"ctrl+c"}, "Clear editor"),
    binding("app.exit", &.{"ctrl+d"}, "Exit when editor is empty"),
    binding("app.suspend", if (builtin.os.tag == .windows) &.{} else &.{"ctrl+z"}, "Suspend to background"),
    binding("app.thinking.cycle", &.{"shift+tab"}, "Cycle thinking level"),
    binding("app.model.cycleForward", &.{"ctrl+p"}, "Cycle to next model"),
    binding("app.model.cycleBackward", &.{"shift+ctrl+p"}, "Cycle to previous model"),
    binding("app.model.select", &.{"ctrl+l"}, "Open model selector"),
    binding("app.tools.expand", &.{"ctrl+o"}, "Toggle tool output"),
    binding("app.thinking.toggle", &.{"ctrl+t"}, "Toggle thinking blocks"),
    binding("app.session.toggleNamedFilter", &.{"ctrl+n"}, "Toggle named session filter"),
    binding("app.editor.external", &.{"ctrl+g"}, "Open external editor"),
    binding("app.message.followUp", &.{"alt+enter"}, "Queue follow-up message"),
    binding("app.message.dequeue", &.{"alt+up"}, "Restore queued messages"),
    binding("app.clipboard.pasteImage", if (builtin.os.tag == .windows) &.{"alt+v"} else &.{"ctrl+v"}, "Paste image from clipboard"),
    binding("app.session.new", &.{}, "Start a new session"),
    binding("app.session.tree", &.{}, "Open session tree"),
    binding("app.session.fork", &.{}, "Fork current session"),
    binding("app.session.resume", &.{}, "Resume a session"),
    binding("app.tree.foldOrUp", &.{ "ctrl+left", "alt+left" }, "Fold tree branch or move up"),
    binding("app.tree.unfoldOrDown", &.{ "ctrl+right", "alt+right" }, "Unfold tree branch or move down"),
    binding("app.tree.editLabel", &.{"shift+l"}, "Edit tree label"),
    binding("app.tree.toggleLabelTimestamp", &.{"shift+t"}, "Toggle tree label timestamps"),
    binding("app.session.togglePath", &.{"ctrl+p"}, "Toggle session path display"),
    binding("app.session.toggleSort", &.{"ctrl+s"}, "Toggle session sort mode"),
    binding("app.session.rename", &.{"ctrl+r"}, "Rename session"),
    binding("app.session.delete", &.{"ctrl+d"}, "Delete session"),
    binding("app.session.deleteNoninvasive", &.{"ctrl+backspace"}, "Delete session when query is empty"),
    binding("app.models.save", &.{"ctrl+s"}, "Save model selection"),
    binding("app.models.enableAll", &.{"ctrl+a"}, "Enable all models"),
    binding("app.models.clearAll", &.{"ctrl+x"}, "Clear all models"),
    binding("app.models.toggleProvider", &.{"ctrl+p"}, "Toggle all models for provider"),
    binding("app.models.reorderUp", &.{"alt+up"}, "Move model up in order"),
    binding("app.models.reorderDown", &.{"alt+down"}, "Move model down"),
    binding("app.tree.filter.default", &.{"ctrl+d"}, "Tree filter: default view"),
    binding("app.tree.filter.noTools", &.{"ctrl+t"}, "Tree filter: hide tool results"),
    binding("app.tree.filter.userOnly", &.{"ctrl+u"}, "Tree filter: user messages only"),
    binding("app.tree.filter.labeledOnly", &.{"ctrl+l"}, "Tree filter: labeled entries only"),
    binding("app.tree.filter.all", &.{"ctrl+a"}, "Tree filter: show all entries"),
    binding("app.tree.filter.cycleForward", &.{"ctrl+o"}, "Tree filter: cycle forward"),
    binding("app.tree.filter.cycleBackward", &.{"shift+ctrl+o"}, "Tree filter: cycle backward"),
};

pub const KEYBINDINGS = tui.keybindings.TUI_KEYBINDINGS ++ APP_KEYBINDINGS;

pub const KeybindingsManager = struct {
    allocator: std.mem.Allocator,
    inner: tui.keybindings.KeybindingsManager,
    config_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, user_bindings: *const KeybindingsConfig) !KeybindingsManager {
        return .{
            .allocator = allocator,
            .inner = try tui.keybindings.KeybindingsManager.init(allocator, &KEYBINDINGS, user_bindings),
        };
    }

    pub fn create(allocator: std.mem.Allocator, agent_dir: []const u8) !KeybindingsManager {
        const config_path = try std.fs.path.join(allocator, &.{ agent_dir, "keybindings.json" });
        errdefer allocator.free(config_path);

        var user_bindings = try loadFromFileAlloc(allocator, config_path);
        defer tui.keybindings.deinitConfig(allocator, &user_bindings);

        return .{
            .allocator = allocator,
            .inner = try tui.keybindings.KeybindingsManager.init(allocator, &KEYBINDINGS, &user_bindings),
            .config_path = config_path,
        };
    }

    pub fn createFromEnv(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !KeybindingsManager {
        const agent_dir = try config.agentDirAlloc(allocator, environ);
        defer allocator.free(agent_dir);
        return create(allocator, agent_dir);
    }

    pub fn deinit(self: *KeybindingsManager) void {
        self.inner.deinit();
        if (self.config_path) |path| self.allocator.free(path);
    }

    pub fn reload(self: *KeybindingsManager) !void {
        const path = self.config_path orelse return;
        var user_bindings = try loadFromFileAlloc(self.allocator, path);
        defer tui.keybindings.deinitConfig(self.allocator, &user_bindings);
        try self.inner.setUserBindings(&user_bindings);
    }

    pub fn matches(self: *const KeybindingsManager, data: []const u8, keybinding: []const u8) bool {
        return self.inner.matches(data, keybinding);
    }

    pub fn getKeysAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator, keybinding: []const u8) ![][]const u8 {
        return self.inner.getKeysAlloc(allocator, keybinding);
    }

    pub fn getDefinition(self: *const KeybindingsManager, keybinding: []const u8) ?KeybindingDefinition {
        return self.inner.getDefinition(keybinding);
    }

    pub fn getConflictsAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator) ![]KeybindingConflict {
        return self.inner.getConflictsAlloc(allocator);
    }

    pub fn getUserBindingsAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator) !KeybindingsConfig {
        return self.inner.getUserBindingsAlloc(allocator);
    }

    pub fn getEffectiveConfigAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator) !KeybindingsConfig {
        return self.inner.getResolvedBindingsAlloc(allocator);
    }
};

pub fn loadFromFileAlloc(allocator: std.mem.Allocator, path: []const u8) !KeybindingsConfig {
    var config_map: KeybindingsConfig = .empty;
    errdefer tui.keybindings.deinitConfig(allocator, &config_map);

    const content = try readOptionalFileAlloc(allocator, path) orelse return config_map;
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return config_map;
    defer parsed.deinit();
    if (parsed.value != .object) return config_map;

    var migrated = try migrateKeybindingsConfigAlloc(allocator, parsed.value.object);
    defer migrated.deinit(allocator);
    try toKeybindingsConfig(allocator, migrated.entries, &config_map);
    return config_map;
}

pub fn migrateKeybindingsConfigFile(allocator: std.mem.Allocator, agent_dir: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ agent_dir, "keybindings.json" });
    defer allocator.free(path);
    return migrateKeybindingsConfigPath(allocator, path);
}

pub fn migrateKeybindingsConfigPath(allocator: std.mem.Allocator, path: []const u8) !bool {
    const content = try readOptionalFileAlloc(allocator, path) orelse return false;
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    var migrated = try migrateKeybindingsConfigAlloc(allocator, parsed.value.object);
    defer migrated.deinit(allocator);
    if (!migrated.migrated) return false;

    const serialized = try stringifyMigratedConfigAlloc(allocator, migrated.entries);
    defer allocator.free(serialized);
    try writeFile(path, serialized);
    return true;
}

const MigratedEntry = struct {
    key: []u8,
    value: std.json.Value,

    fn deinit(self: MigratedEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub const MigratedKeybindingsConfig = struct {
    entries: []MigratedEntry,
    migrated: bool,

    pub fn deinit(self: *MigratedKeybindingsConfig, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub fn migrateKeybindingsConfigAlloc(
    allocator: std.mem.Allocator,
    raw_config: std.json.ObjectMap,
) !MigratedKeybindingsConfig {
    var raw_entries = std.ArrayList(MigratedEntry).empty;
    defer {
        for (raw_entries.items) |entry| entry.deinit(allocator);
        raw_entries.deinit(allocator);
    }

    var migrated = false;
    var raw_iterator = raw_config.iterator();
    while (raw_iterator.next()) |entry| {
        const next_key = legacyKeybindingName(entry.key_ptr.*) orelse entry.key_ptr.*;
        if (!std.mem.eql(u8, next_key, entry.key_ptr.*)) migrated = true;
        if (!std.mem.eql(u8, next_key, entry.key_ptr.*) and raw_config.get(next_key) != null) {
            migrated = true;
            continue;
        }
        try raw_entries.append(allocator, .{
            .key = try allocator.dupe(u8, next_key),
            .value = entry.value_ptr.*,
        });
    }

    var used = try allocator.alloc(bool, raw_entries.items.len);
    defer allocator.free(used);
    @memset(used, false);

    var ordered = std.ArrayList(MigratedEntry).empty;
    errdefer {
        for (ordered.items) |entry| entry.deinit(allocator);
        ordered.deinit(allocator);
    }

    for (KEYBINDINGS) |definition| {
        if (findUnusedEntry(raw_entries.items, used, definition.id)) |index| {
            used[index] = true;
            try appendMigratedEntryClone(allocator, &ordered, raw_entries.items[index]);
        }
    }

    var extras = std.ArrayList(usize).empty;
    defer extras.deinit(allocator);
    for (used, 0..) |is_used, index| {
        if (!is_used) try extras.append(allocator, index);
    }
    sortExtraIndexes(raw_entries.items, extras.items);
    for (extras.items) |index| {
        try appendMigratedEntryClone(allocator, &ordered, raw_entries.items[index]);
    }

    return .{
        .entries = try ordered.toOwnedSlice(allocator),
        .migrated = migrated,
    };
}

pub fn stringifyMigratedConfigAlloc(allocator: std.mem.Allocator, entries: []const MigratedEntry) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    for (entries) |entry| {
        try json.objectField(entry.key);
        try json.write(entry.value);
    }
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn toKeybindingsConfig(
    allocator: std.mem.Allocator,
    entries: []const MigratedEntry,
    config_map: *KeybindingsConfig,
) !void {
    for (entries) |entry| {
        switch (entry.value) {
            .string => |key| try tui.keybindings.putStringBinding(allocator, config_map, entry.key, key),
            .array => |array| {
                var strings = std.ArrayList([]const u8).empty;
                defer strings.deinit(allocator);
                for (array.items) |item| {
                    if (item != .string) {
                        strings.clearRetainingCapacity();
                        break;
                    }
                    try strings.append(allocator, item.string);
                }
                if (strings.items.len == array.items.len) {
                    try tui.keybindings.putArrayBinding(allocator, config_map, entry.key, strings.items);
                }
            },
            else => {},
        }
    }
}

fn appendMigratedEntryClone(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(MigratedEntry),
    entry: MigratedEntry,
) !void {
    try entries.append(allocator, .{
        .key = try allocator.dupe(u8, entry.key),
        .value = entry.value,
    });
}

fn findUnusedEntry(entries: []const MigratedEntry, used: []const bool, key: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (!used[index] and std.mem.eql(u8, entry.key, key)) return index;
    }
    return null;
}

fn sortExtraIndexes(entries: []const MigratedEntry, indexes: []usize) void {
    var index: usize = 1;
    while (index < indexes.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and std.mem.order(u8, entries[indexes[cursor - 1]].key, entries[indexes[cursor]].key) == .gt) {
            std.mem.swap(usize, &indexes[cursor - 1], &indexes[cursor]);
            cursor -= 1;
        }
    }
}

fn legacyKeybindingName(key: []const u8) ?[]const u8 {
    inline for (KEYBINDING_NAME_MIGRATIONS) |migration| {
        if (std.mem.eql(u8, key, migration.from)) return migration.to;
    }
    return null;
}

const KEYBINDING_NAME_MIGRATIONS = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "cursorUp", .to = "tui.editor.cursorUp" },
    .{ .from = "cursorDown", .to = "tui.editor.cursorDown" },
    .{ .from = "cursorLeft", .to = "tui.editor.cursorLeft" },
    .{ .from = "cursorRight", .to = "tui.editor.cursorRight" },
    .{ .from = "cursorWordLeft", .to = "tui.editor.cursorWordLeft" },
    .{ .from = "cursorWordRight", .to = "tui.editor.cursorWordRight" },
    .{ .from = "cursorLineStart", .to = "tui.editor.cursorLineStart" },
    .{ .from = "cursorLineEnd", .to = "tui.editor.cursorLineEnd" },
    .{ .from = "jumpForward", .to = "tui.editor.jumpForward" },
    .{ .from = "jumpBackward", .to = "tui.editor.jumpBackward" },
    .{ .from = "pageUp", .to = "tui.editor.pageUp" },
    .{ .from = "pageDown", .to = "tui.editor.pageDown" },
    .{ .from = "deleteCharBackward", .to = "tui.editor.deleteCharBackward" },
    .{ .from = "deleteCharForward", .to = "tui.editor.deleteCharForward" },
    .{ .from = "deleteWordBackward", .to = "tui.editor.deleteWordBackward" },
    .{ .from = "deleteWordForward", .to = "tui.editor.deleteWordForward" },
    .{ .from = "deleteToLineStart", .to = "tui.editor.deleteToLineStart" },
    .{ .from = "deleteToLineEnd", .to = "tui.editor.deleteToLineEnd" },
    .{ .from = "yank", .to = "tui.editor.yank" },
    .{ .from = "yankPop", .to = "tui.editor.yankPop" },
    .{ .from = "undo", .to = "tui.editor.undo" },
    .{ .from = "newLine", .to = "tui.input.newLine" },
    .{ .from = "submit", .to = "tui.input.submit" },
    .{ .from = "tab", .to = "tui.input.tab" },
    .{ .from = "copy", .to = "tui.input.copy" },
    .{ .from = "selectUp", .to = "tui.select.up" },
    .{ .from = "selectDown", .to = "tui.select.down" },
    .{ .from = "selectPageUp", .to = "tui.select.pageUp" },
    .{ .from = "selectPageDown", .to = "tui.select.pageDown" },
    .{ .from = "selectConfirm", .to = "tui.select.confirm" },
    .{ .from = "selectCancel", .to = "tui.select.cancel" },
    .{ .from = "interrupt", .to = "app.interrupt" },
    .{ .from = "clear", .to = "app.clear" },
    .{ .from = "exit", .to = "app.exit" },
    .{ .from = "suspend", .to = "app.suspend" },
    .{ .from = "cycleThinkingLevel", .to = "app.thinking.cycle" },
    .{ .from = "cycleModelForward", .to = "app.model.cycleForward" },
    .{ .from = "cycleModelBackward", .to = "app.model.cycleBackward" },
    .{ .from = "selectModel", .to = "app.model.select" },
    .{ .from = "expandTools", .to = "app.tools.expand" },
    .{ .from = "toggleThinking", .to = "app.thinking.toggle" },
    .{ .from = "toggleSessionNamedFilter", .to = "app.session.toggleNamedFilter" },
    .{ .from = "externalEditor", .to = "app.editor.external" },
    .{ .from = "followUp", .to = "app.message.followUp" },
    .{ .from = "dequeue", .to = "app.message.dequeue" },
    .{ .from = "pasteImage", .to = "app.clipboard.pasteImage" },
    .{ .from = "newSession", .to = "app.session.new" },
    .{ .from = "tree", .to = "app.session.tree" },
    .{ .from = "fork", .to = "app.session.fork" },
    .{ .from = "resume", .to = "app.session.resume" },
    .{ .from = "treeFoldOrUp", .to = "app.tree.foldOrUp" },
    .{ .from = "treeUnfoldOrDown", .to = "app.tree.unfoldOrDown" },
    .{ .from = "treeEditLabel", .to = "app.tree.editLabel" },
    .{ .from = "treeToggleLabelTimestamp", .to = "app.tree.toggleLabelTimestamp" },
    .{ .from = "toggleSessionPath", .to = "app.session.togglePath" },
    .{ .from = "toggleSessionSort", .to = "app.session.toggleSort" },
    .{ .from = "renameSession", .to = "app.session.rename" },
    .{ .from = "deleteSession", .to = "app.session.delete" },
    .{ .from = "deleteSessionNoninvasive", .to = "app.session.deleteNoninvasive" },
};

fn binding(id: []const u8, default_keys: []const []const u8, description: []const u8) KeybindingDefinition {
    return .{ .id = id, .default_keys = default_keys, .description = description };
}

fn readOptionalFileAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |open_error| return open_error,
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_keybindings_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |read_error| return read_error,
    };
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = content,
        .flags = .{ .read = true, .truncate = true },
    });
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn expectBindingString(config_map: *const KeybindingsConfig, keybinding: []const u8, expected: []const u8) !void {
    const binding_value = config_map.get(keybinding) orelse return error.MissingBinding;
    try std.testing.expectEqual(KeybindingValueKind.string, binding_value.kind);
    try std.testing.expectEqual(@as(usize, 1), binding_value.keys.len);
    try std.testing.expectEqualStrings(expected, binding_value.keys[0]);
}

fn expectBindingArray(config_map: *const KeybindingsConfig, keybinding: []const u8, expected: []const []const u8) !void {
    const binding_value = config_map.get(keybinding) orelse return error.MissingBinding;
    try std.testing.expectEqual(KeybindingValueKind.array, binding_value.kind);
    try std.testing.expectEqual(expected.len, binding_value.keys.len);
    for (expected, 0..) |key, index| {
        try std.testing.expectEqualStrings(key, binding_value.keys[index]);
    }
}

fn readTestFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return (try readOptionalFileAlloc(allocator, path)) orelse error.FileNotFound;
}

test "keybindings migration rewrites old key names to namespaced ids" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "cursorUp": ["up", "ctrl+p"],
        \\  "expandTools": "ctrl+x"
        \\}
        ,
    });
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    try std.testing.expect(try migrateKeybindingsConfigFile(allocator, tmp_path));

    const config_path = try std.fs.path.join(allocator, &.{ tmp_path, "keybindings.json" });
    defer allocator.free(config_path);
    const migrated_json = try readTestFileAlloc(allocator, config_path);
    defer allocator.free(migrated_json);
    try std.testing.expectEqualStrings(
        \\{
        \\  "tui.editor.cursorUp": [
        \\    "up",
        \\    "ctrl+p"
        \\  ],
        \\  "app.tools.expand": "ctrl+x"
        \\}
        \\
    , migrated_json);
}

test "keybindings migration keeps the namespaced value when old and new names both exist" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "expandTools": "ctrl+x",
        \\  "app.tools.expand": "ctrl+y"
        \\}
        ,
    });
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    try std.testing.expect(try migrateKeybindingsConfigFile(allocator, tmp_path));

    const config_path = try std.fs.path.join(allocator, &.{ tmp_path, "keybindings.json" });
    defer allocator.free(config_path);
    const migrated_json = try readTestFileAlloc(allocator, config_path);
    defer allocator.free(migrated_json);
    try std.testing.expectEqualStrings(
        \\{
        \\  "app.tools.expand": "ctrl+y"
        \\}
        \\
    , migrated_json);
}

test "keybindings manager loads old key names in memory before the file is rewritten" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "keybindings.json",
        .data =
        \\{
        \\  "selectConfirm": "enter",
        \\  "interrupt": "ctrl+x"
        \\}
        ,
    });
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    var manager = try KeybindingsManager.create(allocator, tmp_path);
    defer manager.deinit();

    var user_bindings = try manager.getUserBindingsAlloc(allocator);
    defer tui.keybindings.deinitConfig(allocator, &user_bindings);
    try expectBindingString(&user_bindings, "tui.select.confirm", "enter");
    try expectBindingString(&user_bindings, "app.interrupt", "ctrl+x");

    var effective = try manager.getEffectiveConfigAlloc(allocator);
    defer tui.keybindings.deinitConfig(allocator, &effective);
    try expectBindingString(&effective, "tui.select.confirm", "enter");
    try expectBindingString(&effective, "app.interrupt", "ctrl+x");
}
