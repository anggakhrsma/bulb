const std = @import("std");
const source_info = @import("source_info.zig");

pub const SourceInfo = source_info.SourceInfo;

pub const Theme = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    source_path: []u8,
    source_info: SourceInfo,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        name: []const u8,
        source_path: []const u8,
        info: SourceInfo,
    ) !Theme {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_source_path = try allocator.dupe(u8, source_path);
        errdefer allocator.free(owned_source_path);
        const owned_info_path = try allocator.dupe(u8, info.path);
        errdefer allocator.free(owned_info_path);
        const owned_info_source = try allocator.dupe(u8, info.source);
        errdefer allocator.free(owned_info_source);
        const owned_base_dir = if (info.base_dir) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_base_dir) |value| allocator.free(value);

        return .{
            .allocator = allocator,
            .name = owned_name,
            .source_path = owned_source_path,
            .source_info = .{
                .path = owned_info_path,
                .source = owned_info_source,
                .scope = info.scope,
                .origin = info.origin,
                .base_dir = owned_base_dir,
            },
        };
    }

    pub fn deinit(self: *Theme) void {
        self.allocator.free(self.name);
        self.allocator.free(self.source_path);
        self.allocator.free(@constCast(self.source_info.path));
        self.allocator.free(@constCast(self.source_info.source));
        if (self.source_info.base_dir) |value| self.allocator.free(@constCast(value));
        self.* = undefined;
    }
};

pub fn deinitThemes(allocator: std.mem.Allocator, themes: []Theme) void {
    for (themes) |*loaded_theme| loaded_theme.deinit();
    allocator.free(themes);
}

pub fn loadThemeFromPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    theme_path: []const u8,
    info: SourceInfo,
) !Theme {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, theme_path, allocator, .unlimited);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const json = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidThemeJson,
    };
    if (json != .object) return error.InvalidThemeJson;
    const name_value = json.object.get("name") orelse return error.InvalidThemeJson;
    const colors_value = json.object.get("colors") orelse return error.InvalidThemeJson;
    if (name_value != .string or name_value.string.len == 0 or colors_value != .object) {
        return error.InvalidThemeJson;
    }
    return Theme.initAlloc(allocator, name_value.string, theme_path, info);
}

test "loadThemeFromPath ports JSON validation and source metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const theme_path = try std.fs.path.join(allocator, &.{ root, "ocean.json" });
    defer allocator.free(theme_path);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = theme_path,
        .data = "{\"name\":\"ocean\",\"colors\":{\"accent\":\"#00ffff\"}}",
        .flags = .{ .read = true, .truncate = true },
    });

    var loaded = try loadThemeFromPathAlloc(allocator, io, theme_path, source_info.createSyntheticSourceInfo(theme_path, .{
        .source = "local",
        .scope = .project,
        .base_dir = root,
    }));
    defer loaded.deinit();

    try std.testing.expectEqualStrings("ocean", loaded.name);
    try std.testing.expectEqualStrings(theme_path, loaded.source_path);
    try std.testing.expectEqual(source_info.SourceScope.project, loaded.source_info.scope);
}
