const std = @import("std");
const keys = @import("keys.zig");

pub const Keybinding = []const u8;
pub const Keybindings = []const KeybindingDefinition;
pub const KeybindingDefinitions = []const KeybindingDefinition;

pub const KeybindingDefinition = struct {
    id: []const u8,
    default_keys: []const []const u8,
    description: []const u8,
};

pub const KeybindingValueKind = enum { string, array };

pub const KeybindingValue = struct {
    keys: [][]const u8,
    kind: KeybindingValueKind,

    pub fn deinit(self: KeybindingValue, allocator: std.mem.Allocator) void {
        for (self.keys) |key| allocator.free(key);
        allocator.free(self.keys);
    }

    pub fn clone(self: KeybindingValue, allocator: std.mem.Allocator) !KeybindingValue {
        var cloned_keys = try allocator.alloc([]const u8, self.keys.len);
        errdefer allocator.free(cloned_keys);
        for (self.keys, 0..) |key, index| {
            cloned_keys[index] = try allocator.dupe(u8, key);
        }
        return .{ .keys = cloned_keys, .kind = self.kind };
    }
};

pub const KeybindingsConfig = std.array_hash_map.String(KeybindingValue);

pub const KeybindingConflict = struct {
    key: []u8,
    keybindings: [][]u8,

    pub fn deinit(self: KeybindingConflict, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        for (self.keybindings) |keybinding| allocator.free(keybinding);
        allocator.free(self.keybindings);
    }
};

pub const KeybindingsManager = struct {
    allocator: std.mem.Allocator,
    definitions: []const KeybindingDefinition,
    user_bindings: KeybindingsConfig,
    conflicts: std.ArrayList(KeybindingConflict) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        definitions: []const KeybindingDefinition,
        user_bindings: *const KeybindingsConfig,
    ) !KeybindingsManager {
        var manager = KeybindingsManager{
            .allocator = allocator,
            .definitions = definitions,
            .user_bindings = .empty,
        };
        errdefer manager.deinit();
        try cloneConfigInto(allocator, &manager.user_bindings, user_bindings);
        try manager.rebuild();
        return manager;
    }

    pub fn initDefaults(allocator: std.mem.Allocator, definitions: []const KeybindingDefinition) !KeybindingsManager {
        var empty: KeybindingsConfig = .empty;
        defer empty.deinit(allocator);
        return init(allocator, definitions, &empty);
    }

    pub fn deinit(self: *KeybindingsManager) void {
        self.clearConflicts();
        self.conflicts.deinit(self.allocator);
        deinitConfig(self.allocator, &self.user_bindings);
    }

    pub fn setUserBindings(self: *KeybindingsManager, user_bindings: *const KeybindingsConfig) !void {
        deinitConfig(self.allocator, &self.user_bindings);
        self.user_bindings = .empty;
        try cloneConfigInto(self.allocator, &self.user_bindings, user_bindings);
        try self.rebuild();
    }

    pub fn matches(self: *const KeybindingsManager, data: []const u8, keybinding: []const u8) bool {
        const binding_keys = self.keysFor(keybinding) orelse return false;
        for (binding_keys) |key| {
            if (keys.matchesKey(data, key)) return true;
        }
        return false;
    }

    pub fn getKeysAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator, keybinding: []const u8) ![][]const u8 {
        const binding_keys = self.keysFor(keybinding) orelse &.{};
        return cloneStringSlice(allocator, binding_keys);
    }

    pub fn getDefinition(self: *const KeybindingsManager, keybinding: []const u8) ?KeybindingDefinition {
        return self.definitionFor(keybinding);
    }

    pub fn getConflictsAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator) ![]KeybindingConflict {
        var result = try allocator.alloc(KeybindingConflict, self.conflicts.items.len);
        errdefer allocator.free(result);
        for (self.conflicts.items, 0..) |conflict, index| {
            result[index] = try cloneConflict(allocator, conflict);
        }
        return result;
    }

    pub fn getUserBindingsAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator) !KeybindingsConfig {
        var config: KeybindingsConfig = .empty;
        errdefer deinitConfig(allocator, &config);
        try cloneConfigInto(allocator, &config, &self.user_bindings);
        return config;
    }

    pub fn getResolvedBindingsAlloc(self: *const KeybindingsManager, allocator: std.mem.Allocator) !KeybindingsConfig {
        var resolved: KeybindingsConfig = .empty;
        errdefer deinitConfig(allocator, &resolved);
        for (self.definitions) |definition| {
            const binding_keys = self.keysFor(definition.id) orelse &.{};
            try putOwnedBindingFromStrings(
                allocator,
                &resolved,
                definition.id,
                binding_keys,
                if (binding_keys.len == 1) .string else .array,
            );
        }
        return resolved;
    }

    fn rebuild(self: *KeybindingsManager) !void {
        self.clearConflicts();

        var user_claims: std.array_hash_map.String(std.ArrayList([]u8)) = .empty;
        defer deinitClaims(self.allocator, &user_claims);

        var iterator = self.user_bindings.iterator();
        while (iterator.next()) |entry| {
            if (self.definitionFor(entry.key_ptr.*) == null) continue;
            const normalized = try normalizeKeysAlloc(self.allocator, entry.value_ptr.keys);
            defer freeStringSlice(self.allocator, normalized);

            for (normalized) |key| {
                const claim = try user_claims.getOrPut(self.allocator, key);
                if (!claim.found_existing) {
                    claim.key_ptr.* = try self.allocator.dupe(u8, key);
                    claim.value_ptr.* = .empty;
                }
                if (!containsString(claim.value_ptr.items, entry.key_ptr.*)) {
                    try claim.value_ptr.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
                }
            }
        }

        var claims_iterator = user_claims.iterator();
        while (claims_iterator.next()) |entry| {
            if (entry.value_ptr.items.len <= 1) continue;
            try self.conflicts.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, entry.key_ptr.*),
                .keybindings = try cloneMutableStringSlice(self.allocator, entry.value_ptr.items),
            });
        }
    }

    fn clearConflicts(self: *KeybindingsManager) void {
        for (self.conflicts.items) |conflict| conflict.deinit(self.allocator);
        self.conflicts.clearRetainingCapacity();
    }

    fn keysFor(self: *const KeybindingsManager, keybinding: []const u8) ?[]const []const u8 {
        if (self.user_bindings.get(keybinding)) |value| {
            return value.keys;
        }
        if (self.definitionFor(keybinding)) |definition| {
            return definition.default_keys;
        }
        return null;
    }

    fn definitionFor(self: *const KeybindingsManager, keybinding: []const u8) ?KeybindingDefinition {
        for (self.definitions) |definition| {
            if (std.mem.eql(u8, definition.id, keybinding)) return definition;
        }
        return null;
    }
};

var global_keybindings: ?*KeybindingsManager = null;
var global_keybindings_owned = false;

pub fn setKeybindings(allocator: std.mem.Allocator, keybindings: *KeybindingsManager) void {
    resetGlobalKeybindings(allocator);
    global_keybindings = keybindings;
    global_keybindings_owned = false;
}

pub fn getKeybindings(allocator: std.mem.Allocator) !*KeybindingsManager {
    if (global_keybindings) |manager| return manager;
    const manager = try allocator.create(KeybindingsManager);
    errdefer allocator.destroy(manager);
    manager.* = try KeybindingsManager.initDefaults(allocator, &TUI_KEYBINDINGS);
    global_keybindings = manager;
    global_keybindings_owned = true;
    return manager;
}

pub fn resetGlobalKeybindings(allocator: std.mem.Allocator) void {
    if (global_keybindings) |manager| {
        if (global_keybindings_owned) {
            manager.deinit();
            allocator.destroy(manager);
        }
    }
    global_keybindings = null;
    global_keybindings_owned = false;
}

pub const TUI_KEYBINDINGS = [_]KeybindingDefinition{
    binding("tui.editor.cursorUp", &.{"up"}, "Move cursor up"),
    binding("tui.editor.cursorDown", &.{"down"}, "Move cursor down"),
    binding("tui.editor.cursorLeft", &.{ "left", "ctrl+b" }, "Move cursor left"),
    binding("tui.editor.cursorRight", &.{ "right", "ctrl+f" }, "Move cursor right"),
    binding("tui.editor.cursorWordLeft", &.{ "alt+left", "ctrl+left", "alt+b" }, "Move cursor word left"),
    binding("tui.editor.cursorWordRight", &.{ "alt+right", "ctrl+right", "alt+f" }, "Move cursor word right"),
    binding("tui.editor.cursorLineStart", &.{ "home", "ctrl+a" }, "Move to line start"),
    binding("tui.editor.cursorLineEnd", &.{ "end", "ctrl+e" }, "Move to line end"),
    binding("tui.editor.jumpForward", &.{"ctrl+]"}, "Jump forward to character"),
    binding("tui.editor.jumpBackward", &.{"ctrl+alt+]"}, "Jump backward to character"),
    binding("tui.editor.pageUp", &.{"pageUp"}, "Page up"),
    binding("tui.editor.pageDown", &.{"pageDown"}, "Page down"),
    binding("tui.editor.deleteCharBackward", &.{"backspace"}, "Delete character backward"),
    binding("tui.editor.deleteCharForward", &.{ "delete", "ctrl+d" }, "Delete character forward"),
    binding("tui.editor.deleteWordBackward", &.{ "ctrl+w", "alt+backspace" }, "Delete word backward"),
    binding("tui.editor.deleteWordForward", &.{ "alt+d", "alt+delete" }, "Delete word forward"),
    binding("tui.editor.deleteToLineStart", &.{"ctrl+u"}, "Delete to line start"),
    binding("tui.editor.deleteToLineEnd", &.{"ctrl+k"}, "Delete to line end"),
    binding("tui.editor.yank", &.{"ctrl+y"}, "Yank"),
    binding("tui.editor.yankPop", &.{"alt+y"}, "Yank pop"),
    binding("tui.editor.undo", &.{"ctrl+-"}, "Undo"),
    binding("tui.input.newLine", &.{"shift+enter"}, "Insert newline"),
    binding("tui.input.submit", &.{"enter"}, "Submit input"),
    binding("tui.input.tab", &.{"tab"}, "Tab / autocomplete"),
    binding("tui.input.copy", &.{"ctrl+c"}, "Copy selection"),
    binding("tui.select.up", &.{"up"}, "Move selection up"),
    binding("tui.select.down", &.{"down"}, "Move selection down"),
    binding("tui.select.pageUp", &.{"pageUp"}, "Selection page up"),
    binding("tui.select.pageDown", &.{"pageDown"}, "Selection page down"),
    binding("tui.select.confirm", &.{"enter"}, "Confirm selection"),
    binding("tui.select.cancel", &.{ "escape", "ctrl+c" }, "Cancel selection"),
};

pub fn deinitConfig(allocator: std.mem.Allocator, config: *KeybindingsConfig) void {
    var iterator = config.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    config.deinit(allocator);
}

pub fn putStringBinding(
    allocator: std.mem.Allocator,
    config: *KeybindingsConfig,
    keybinding: []const u8,
    key: []const u8,
) !void {
    try putOwnedBindingFromStrings(allocator, config, keybinding, &.{key}, .string);
}

pub fn putArrayBinding(
    allocator: std.mem.Allocator,
    config: *KeybindingsConfig,
    keybinding: []const u8,
    binding_keys: []const []const u8,
) !void {
    try putOwnedBindingFromStrings(allocator, config, keybinding, binding_keys, .array);
}

pub fn writeBindingValue(json: *std.json.Stringify, value: KeybindingValue) !void {
    if (value.kind == .string and value.keys.len > 0) {
        try json.write(value.keys[0]);
        return;
    }
    try json.beginArray();
    for (value.keys) |key| try json.write(key);
    try json.endArray();
}

fn putOwnedBindingFromStrings(
    allocator: std.mem.Allocator,
    config: *KeybindingsConfig,
    keybinding: []const u8,
    binding_keys: []const []const u8,
    kind: KeybindingValueKind,
) !void {
    const owned_keybinding = try allocator.dupe(u8, keybinding);
    errdefer allocator.free(owned_keybinding);
    var value = try cloneValueFromStrings(allocator, binding_keys, kind);
    errdefer value.deinit(allocator);

    if (config.fetchOrderedRemove(keybinding)) |old| {
        allocator.free(old.key);
        old.value.deinit(allocator);
    }
    try config.put(allocator, owned_keybinding, value);
}

fn cloneValueFromStrings(
    allocator: std.mem.Allocator,
    binding_keys: []const []const u8,
    kind: KeybindingValueKind,
) !KeybindingValue {
    const cloned_keys = try cloneStringSlice(allocator, binding_keys);
    return .{ .keys = cloned_keys, .kind = kind };
}

fn cloneConfigInto(
    allocator: std.mem.Allocator,
    target: *KeybindingsConfig,
    source: *const KeybindingsConfig,
) !void {
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try putOwnedBindingFromStrings(allocator, target, entry.key_ptr.*, entry.value_ptr.keys, entry.value_ptr.kind);
    }
}

fn binding(id: []const u8, default_keys: []const []const u8, description: []const u8) KeybindingDefinition {
    return .{ .id = id, .default_keys = default_keys, .description = description };
}

fn cloneStringSlice(allocator: std.mem.Allocator, strings: []const []const u8) ![][]const u8 {
    var result = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(result);
    for (strings, 0..) |string, index| {
        result[index] = try allocator.dupe(u8, string);
    }
    return result;
}

fn cloneMutableStringSlice(allocator: std.mem.Allocator, strings: []const []u8) ![][]u8 {
    var result = try allocator.alloc([]u8, strings.len);
    errdefer allocator.free(result);
    for (strings, 0..) |string, index| {
        result[index] = try allocator.dupe(u8, string);
    }
    return result;
}

pub fn freeStringSlice(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn normalizeKeysAlloc(allocator: std.mem.Allocator, input: []const []const u8) ![][]const u8 {
    var result = std.ArrayList([]const u8).empty;
    errdefer {
        for (result.items) |key| allocator.free(key);
        result.deinit(allocator);
    }
    for (input) |key| {
        if (containsString(result.items, key)) continue;
        try result.append(allocator, try allocator.dupe(u8, key));
    }
    return result.toOwnedSlice(allocator);
}

fn containsString(strings: []const []const u8, needle: []const u8) bool {
    for (strings) |string| {
        if (std.mem.eql(u8, string, needle)) return true;
    }
    return false;
}

fn deinitClaims(allocator: std.mem.Allocator, claims: *std.array_hash_map.String(std.ArrayList([]u8))) void {
    var iterator = claims.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        for (entry.value_ptr.items) |keybinding| allocator.free(keybinding);
        entry.value_ptr.deinit(allocator);
    }
    claims.deinit(allocator);
}

fn cloneConflict(allocator: std.mem.Allocator, conflict: KeybindingConflict) !KeybindingConflict {
    return .{
        .key = try allocator.dupe(u8, conflict.key),
        .keybindings = try cloneMutableStringSlice(allocator, conflict.keybindings),
    };
}

fn expectKeys(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |key, index| {
        try std.testing.expectEqualStrings(key, actual[index]);
    }
}

test "KeybindingsManager does not evict selector confirm when input submit is rebound" {
    const allocator = std.testing.allocator;
    var config: KeybindingsConfig = .empty;
    defer deinitConfig(allocator, &config);
    try putArrayBinding(allocator, &config, "tui.input.submit", &.{ "enter", "ctrl+enter" });

    var manager = try KeybindingsManager.init(allocator, &TUI_KEYBINDINGS, &config);
    defer manager.deinit();

    const submit = try manager.getKeysAlloc(allocator, "tui.input.submit");
    defer freeStringSlice(allocator, submit);
    try expectKeys(submit, &.{ "enter", "ctrl+enter" });

    const confirm = try manager.getKeysAlloc(allocator, "tui.select.confirm");
    defer freeStringSlice(allocator, confirm);
    try expectKeys(confirm, &.{"enter"});
}

test "KeybindingsManager does not evict cursor bindings when another action reuses the same key" {
    const allocator = std.testing.allocator;
    var config: KeybindingsConfig = .empty;
    defer deinitConfig(allocator, &config);
    try putArrayBinding(allocator, &config, "tui.select.up", &.{ "up", "ctrl+p" });

    var manager = try KeybindingsManager.init(allocator, &TUI_KEYBINDINGS, &config);
    defer manager.deinit();

    const select_up = try manager.getKeysAlloc(allocator, "tui.select.up");
    defer freeStringSlice(allocator, select_up);
    try expectKeys(select_up, &.{ "up", "ctrl+p" });

    const cursor_up = try manager.getKeysAlloc(allocator, "tui.editor.cursorUp");
    defer freeStringSlice(allocator, cursor_up);
    try expectKeys(cursor_up, &.{"up"});
}

test "KeybindingsManager still reports direct user binding conflicts without evicting defaults" {
    const allocator = std.testing.allocator;
    var config: KeybindingsConfig = .empty;
    defer deinitConfig(allocator, &config);
    try putStringBinding(allocator, &config, "tui.input.submit", "ctrl+x");
    try putStringBinding(allocator, &config, "tui.select.confirm", "ctrl+x");

    var manager = try KeybindingsManager.init(allocator, &TUI_KEYBINDINGS, &config);
    defer manager.deinit();

    const conflicts = try manager.getConflictsAlloc(allocator);
    defer {
        for (conflicts) |conflict| conflict.deinit(allocator);
        allocator.free(conflicts);
    }
    try std.testing.expectEqual(@as(usize, 1), conflicts.len);
    try std.testing.expectEqualStrings("ctrl+x", conflicts[0].key);
    try expectKeys(conflicts[0].keybindings, &.{ "tui.input.submit", "tui.select.confirm" });

    const cursor_left = try manager.getKeysAlloc(allocator, "tui.editor.cursorLeft");
    defer freeStringSlice(allocator, cursor_left);
    try expectKeys(cursor_left, &.{ "left", "ctrl+b" });
}

test "global keybindings returns the default singleton until replaced" {
    const allocator = std.testing.allocator;
    defer resetGlobalKeybindings(allocator);

    const first = try getKeybindings(allocator);
    const second = try getKeybindings(allocator);
    try std.testing.expect(first == second);

    var replacement = try KeybindingsManager.initDefaults(allocator, &TUI_KEYBINDINGS);
    defer replacement.deinit();
    setKeybindings(allocator, &replacement);
    try std.testing.expect((try getKeybindings(allocator)) == &replacement);
}
