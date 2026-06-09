const std = @import("std");

pub const default_active_tool_names = [_][]const u8{ "read", "bash", "edit", "write" };

pub const NoToolsMode = enum {
    none,
    all,
    builtin,
};

pub const InitialActiveToolOptions = struct {
    tools: ?[]const []const u8 = null,
    no_tools: NoToolsMode = .none,
    excluded_tool_names: []const []const u8 = &.{},
};

pub const RefreshActiveToolOptions = struct {
    registry_tool_names: []const []const u8,
    extension_tool_names: []const []const u8 = &.{},
    previous_registry_tool_names: []const []const u8 = &.{},
    previous_active_tool_names: []const []const u8 = &.{},
    active_tool_names: ?[]const []const u8 = null,
    allowed_tool_names: ?[]const []const u8 = null,
    excluded_tool_names: []const []const u8 = &.{},
    include_all_extension_tools: bool = false,
};

pub fn containsToolName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

pub fn isToolAllowed(
    name: []const u8,
    allowed_tool_names: ?[]const []const u8,
    excluded_tool_names: []const []const u8,
) bool {
    if (allowed_tool_names) |allowed| {
        if (!containsToolName(allowed, name)) return false;
    }
    return !containsToolName(excluded_tool_names, name);
}

pub fn filterToolNamesAlloc(
    allocator: std.mem.Allocator,
    names: []const []const u8,
    allowed_tool_names: ?[]const []const u8,
    excluded_tool_names: []const []const u8,
) ![]const []const u8 {
    var filtered: std.ArrayList([]const u8) = .empty;
    errdefer filtered.deinit(allocator);

    for (names) |name| {
        if (isToolAllowed(name, allowed_tool_names, excluded_tool_names)) {
            try filtered.append(allocator, name);
        }
    }

    return filtered.toOwnedSlice(allocator);
}

pub fn initialActiveToolNamesAlloc(
    allocator: std.mem.Allocator,
    options: InitialActiveToolOptions,
) ![]const []const u8 {
    const source = if (options.tools) |tools|
        tools
    else if (options.no_tools != .none)
        @as([]const []const u8, &.{})
    else
        default_active_tool_names[0..];

    return filterToolNamesAlloc(allocator, source, null, options.excluded_tool_names);
}

pub fn refreshActiveToolNamesAlloc(
    allocator: std.mem.Allocator,
    options: RefreshActiveToolOptions,
) ![]const []const u8 {
    var next: std.ArrayList([]const u8) = .empty;
    errdefer next.deinit(allocator);

    const seed = options.active_tool_names orelse options.previous_active_tool_names;
    try appendFilteredUnique(&next, allocator, seed, options.allowed_tool_names, options.excluded_tool_names);

    if (options.allowed_tool_names) |allowed_tool_names| {
        for (options.registry_tool_names) |name| {
            if (containsToolName(allowed_tool_names, name) and
                isToolAllowed(name, options.allowed_tool_names, options.excluded_tool_names))
            {
                try appendUnique(&next, allocator, name);
            }
        }
    } else if (options.include_all_extension_tools) {
        try appendFilteredUnique(&next, allocator, options.extension_tool_names, null, options.excluded_tool_names);
    } else if (options.active_tool_names == null) {
        for (options.registry_tool_names) |name| {
            if (!containsToolName(options.previous_registry_tool_names, name) and
                isToolAllowed(name, null, options.excluded_tool_names))
            {
                try appendUnique(&next, allocator, name);
            }
        }
    }

    return next.toOwnedSlice(allocator);
}

fn appendFilteredUnique(
    names: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    candidates: []const []const u8,
    allowed_tool_names: ?[]const []const u8,
    excluded_tool_names: []const []const u8,
) !void {
    for (candidates) |candidate| {
        if (isToolAllowed(candidate, allowed_tool_names, excluded_tool_names)) {
            try appendUnique(names, allocator, candidate);
        }
    }
}

fn appendUnique(
    names: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) !void {
    if (!containsToolName(names.items, name)) {
        try names.append(allocator, name);
    }
}

fn expectNames(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_name, actual_name| {
        try std.testing.expectEqualStrings(expected_name, actual_name);
    }
}

test "tool selection ports allowlist filtering for extension tools" {
    const allocator = std.testing.allocator;
    const registry = [_][]const u8{ "read", "bash", "edit", "write", "dynamic_tool" };
    const builtins = [_][]const u8{ "read", "bash", "edit", "write" };
    const extensions = [_][]const u8{"dynamic_tool"};
    const allowlist = [_][]const u8{ "read", "dynamic_tool" };

    const available = try filterToolNamesAlloc(allocator, registry[0..], allowlist[0..], &.{});
    defer allocator.free(available);
    try expectNames(available, &.{ "read", "dynamic_tool" });

    const active = try refreshActiveToolNamesAlloc(allocator, .{
        .registry_tool_names = available,
        .extension_tool_names = extensions[0..],
        .previous_registry_tool_names = builtins[0..],
        .previous_active_tool_names = builtins[0..],
        .allowed_tool_names = allowlist[0..],
    });
    defer allocator.free(active);
    try expectNames(active, &.{ "read", "dynamic_tool" });

    const empty_allowlist: []const []const u8 = &.{};
    const empty_available = try filterToolNamesAlloc(allocator, registry[0..], empty_allowlist, &.{});
    defer allocator.free(empty_available);
    try expectNames(empty_available, &.{});

    const empty_active = try refreshActiveToolNamesAlloc(allocator, .{
        .registry_tool_names = empty_available,
        .previous_active_tool_names = builtins[0..],
        .allowed_tool_names = empty_allowlist,
    });
    defer allocator.free(empty_active);
    try expectNames(empty_active, &.{});
}

test "tool selection keeps extension tools active when built-in defaults are disabled" {
    const allocator = std.testing.allocator;
    const registry = [_][]const u8{ "read", "bash", "edit", "write", "grep", "find", "ls", "dynamic_tool" };
    const builtins = [_][]const u8{ "read", "bash", "edit", "write", "grep", "find", "ls" };
    const extensions = [_][]const u8{"dynamic_tool"};

    const initial = try initialActiveToolNamesAlloc(allocator, .{ .no_tools = .builtin });
    defer allocator.free(initial);
    try expectNames(initial, &.{});

    const active = try refreshActiveToolNamesAlloc(allocator, .{
        .registry_tool_names = registry[0..],
        .extension_tool_names = extensions[0..],
        .previous_registry_tool_names = builtins[0..],
        .previous_active_tool_names = initial,
        .include_all_extension_tools = true,
    });
    defer allocator.free(active);
    try expectNames(active, &.{"dynamic_tool"});

    const empty_allowlist: []const []const u8 = &.{};
    const disabled_available = try filterToolNamesAlloc(allocator, registry[0..], empty_allowlist, &.{});
    defer allocator.free(disabled_available);
    try expectNames(disabled_available, &.{});
}

test "tool selection lets excluded tools override allowlists" {
    const allocator = std.testing.allocator;
    const registry = [_][]const u8{ "read", "bash", "edit", "write", "ask_question", "dynamic_tool" };
    const extensions = [_][]const u8{ "ask_question", "dynamic_tool" };
    const excluded = [_][]const u8{ "read", "ask_question" };
    const allowlist = [_][]const u8{ "read", "bash", "ask_question" };

    const available = try filterToolNamesAlloc(allocator, registry[0..], null, excluded[0..]);
    defer allocator.free(available);
    try expectNames(available, &.{ "bash", "edit", "write", "dynamic_tool" });

    const initial = try initialActiveToolNamesAlloc(allocator, .{ .excluded_tool_names = excluded[0..] });
    defer allocator.free(initial);
    try expectNames(initial, &.{ "bash", "edit", "write" });

    const active = try refreshActiveToolNamesAlloc(allocator, .{
        .registry_tool_names = available,
        .extension_tool_names = extensions[0..],
        .previous_active_tool_names = initial,
        .include_all_extension_tools = true,
        .excluded_tool_names = excluded[0..],
    });
    defer allocator.free(active);
    try expectNames(active, &.{ "bash", "edit", "write", "dynamic_tool" });

    const allowed_available = try filterToolNamesAlloc(allocator, registry[0..], allowlist[0..], excluded[0..]);
    defer allocator.free(allowed_available);
    try expectNames(allowed_available, &.{"bash"});

    const allowed_initial = try initialActiveToolNamesAlloc(allocator, .{
        .tools = allowlist[0..],
        .excluded_tool_names = excluded[0..],
    });
    defer allocator.free(allowed_initial);
    try expectNames(allowed_initial, &.{"bash"});

    const allowed_active = try refreshActiveToolNamesAlloc(allocator, .{
        .registry_tool_names = allowed_available,
        .extension_tool_names = extensions[0..],
        .previous_active_tool_names = allowed_initial,
        .allowed_tool_names = allowlist[0..],
        .excluded_tool_names = excluded[0..],
    });
    defer allocator.free(allowed_active);
    try expectNames(allowed_active, &.{"bash"});
}
