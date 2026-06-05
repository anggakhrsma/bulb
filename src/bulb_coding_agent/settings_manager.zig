const std = @import("std");

const config = @import("config.zig");
const paths = @import("paths.zig");

pub const default_http_idle_timeout_ms: i64 = 300_000;
const max_settings_file_bytes = 4 * 1024 * 1024;

pub const SettingsScope = enum {
    global,
    project,
};

pub const SettingsError = struct {
    scope: SettingsScope,
    message: []const u8,
};

pub const PackageSource = union(enum) {
    string: []const u8,
    object: PackageObject,
};

pub const PackageObject = struct {
    source: []const u8,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,
};

pub fn deinitPackageSources(allocator: std.mem.Allocator, packages: []PackageSource) void {
    for (packages) |package| {
        switch (package) {
            .string => |value| allocator.free(value),
            .object => |object| {
                allocator.free(object.source);
                freeOptionalStringArray(allocator, object.extensions);
                freeOptionalStringArray(allocator, object.skills);
                freeOptionalStringArray(allocator, object.prompts);
                freeOptionalStringArray(allocator, object.themes);
            },
        }
    }
    allocator.free(packages);
}

pub const SettingsManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    cwd: []u8,
    agent_dir: []u8,
    global_settings_path: []u8,
    project_settings_path: []u8,
    global_settings: std.json.Value,
    project_settings: std.json.Value,
    settings: std.json.Value,
    modified_fields: std.ArrayList(ModifiedField) = .empty,
    modified_project_fields: std.ArrayList(ModifiedField) = .empty,
    errors: std.ArrayList(SettingsError) = .empty,
    global_settings_load_error: bool = false,
    project_settings_load_error: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        agent_dir: []const u8,
    ) !SettingsManager {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const resolved_cwd = try paths.resolvePathAlloc(arena_allocator, cwd, ".", .{});
        const resolved_agent_dir = try paths.resolvePathAlloc(arena_allocator, agent_dir, ".", .{});
        const global_settings_path = try std.fs.path.join(arena_allocator, &.{ resolved_agent_dir, "settings.json" });
        const project_settings_path = try std.fs.path.join(arena_allocator, &.{
            resolved_cwd,
            config.project_config_dir,
            "settings.json",
        });

        var manager: SettingsManager = .{
            .allocator = allocator,
            .io = io,
            .arena = arena,
            .cwd = resolved_cwd,
            .agent_dir = resolved_agent_dir,
            .global_settings_path = global_settings_path,
            .project_settings_path = project_settings_path,
            .global_settings = objectValue(),
            .project_settings = objectValue(),
            .settings = objectValue(),
        };
        errdefer manager.deinit();

        const global_load = try manager.loadScopedSettings(.global);
        manager.global_settings = global_load.value;
        manager.global_settings_load_error = global_load.failed;
        if (global_load.error_message) |message| try manager.recordError(.global, message);

        const project_load = try manager.loadScopedSettings(.project);
        manager.project_settings = project_load.value;
        manager.project_settings_load_error = project_load.failed;
        if (project_load.error_message) |message| try manager.recordError(.project, message);

        manager.settings = try deepMergeSettings(manager.arena.allocator(), manager.global_settings, manager.project_settings);
        return manager;
    }

    pub fn deinit(self: *SettingsManager) void {
        self.modified_fields.deinit(self.allocator);
        self.modified_project_fields.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn reload(self: *SettingsManager) !void {
        self.modified_fields.clearRetainingCapacity();
        self.modified_project_fields.clearRetainingCapacity();

        const global_load = try self.loadScopedSettings(.global);
        if (global_load.failed) {
            self.global_settings_load_error = true;
            if (global_load.error_message) |message| try self.recordError(.global, message);
        } else {
            self.global_settings = global_load.value;
            self.global_settings_load_error = false;
        }

        const project_load = try self.loadScopedSettings(.project);
        if (project_load.failed) {
            self.project_settings_load_error = true;
            if (project_load.error_message) |message| try self.recordError(.project, message);
        } else {
            self.project_settings = project_load.value;
            self.project_settings_load_error = false;
        }

        self.settings = try deepMergeSettings(self.arena.allocator(), self.global_settings, self.project_settings);
    }

    pub fn flush(self: *SettingsManager) !void {
        _ = self;
    }

    pub fn drainErrorsAlloc(self: *SettingsManager, allocator: std.mem.Allocator) ![]SettingsError {
        const drained = try allocator.dupe(SettingsError, self.errors.items);
        self.errors.clearRetainingCapacity();
        return drained;
    }

    pub fn getTheme(self: *const SettingsManager) ?[]const u8 {
        return optionalString(self.settings, "theme");
    }

    pub fn setTheme(self: *SettingsManager, theme: []const u8) !void {
        try putString(self.arena.allocator(), &self.global_settings, "theme", theme);
        try self.markModified("theme");
        try self.saveGlobal();
    }

    pub fn getDefaultModel(self: *const SettingsManager) ?[]const u8 {
        return optionalString(self.settings, "defaultModel");
    }

    pub fn getDefaultThinkingLevel(self: *const SettingsManager) ?[]const u8 {
        return optionalString(self.settings, "defaultThinkingLevel");
    }

    pub fn setDefaultThinkingLevel(self: *SettingsManager, level: []const u8) !void {
        try putString(self.arena.allocator(), &self.global_settings, "defaultThinkingLevel", level);
        try self.markModified("defaultThinkingLevel");
        try self.saveGlobal();
    }

    pub fn getShellCommandPrefix(self: *const SettingsManager) ?[]const u8 {
        return optionalString(self.settings, "shellCommandPrefix");
    }

    pub fn setShellCommandPrefix(self: *SettingsManager, prefix: ?[]const u8) !void {
        try putOptionalString(self.arena.allocator(), &self.global_settings, "shellCommandPrefix", prefix);
        try self.markModified("shellCommandPrefix");
        try self.saveGlobal();
    }

    pub fn getSessionDirAlloc(self: *const SettingsManager, allocator: std.mem.Allocator, home_dir: ?[]const u8) !?[]u8 {
        const session_dir = optionalString(self.settings, "sessionDir") orelse return null;
        const normalized = try paths.normalizePathAlloc(allocator, session_dir, .{ .home_dir = home_dir });
        return @as(?[]u8, normalized);
    }

    pub fn getHttpIdleTimeoutMs(self: *const SettingsManager) !i64 {
        return (try parseTimeoutSetting(fieldValue(self.settings, "httpIdleTimeoutMs"), "httpIdleTimeoutMs")) orelse default_http_idle_timeout_ms;
    }

    pub fn setHttpIdleTimeoutMs(self: *SettingsManager, timeout_ms: i64) !void {
        if (timeout_ms < 0) return error.InvalidHttpIdleTimeoutMs;
        try putInteger(self.arena.allocator(), &self.global_settings, "httpIdleTimeoutMs", timeout_ms);
        try self.markModified("httpIdleTimeoutMs");
        try self.saveGlobal();
    }

    pub fn getPackagesAlloc(self: *const SettingsManager, allocator: std.mem.Allocator) ![]PackageSource {
        const value = fieldValue(self.settings, "packages") orelse return allocator.alloc(PackageSource, 0);
        if (value != .array) return allocator.alloc(PackageSource, 0);

        var packages: std.ArrayList(PackageSource) = .empty;
        errdefer deinitPackageSources(allocator, packages.items);

        for (value.array.items) |item| {
            switch (item) {
                .string => |source| try packages.append(allocator, .{ .string = try allocator.dupe(u8, source) }),
                .object => {
                    const source = optionalString(item, "source") orelse continue;
                    try packages.append(allocator, .{ .object = .{
                        .source = try allocator.dupe(u8, source),
                        .extensions = try optionalStringArrayAlloc(allocator, fieldValue(item, "extensions")),
                        .skills = try optionalStringArrayAlloc(allocator, fieldValue(item, "skills")),
                        .prompts = try optionalStringArrayAlloc(allocator, fieldValue(item, "prompts")),
                        .themes = try optionalStringArrayAlloc(allocator, fieldValue(item, "themes")),
                    } });
                },
                else => {},
            }
        }

        return packages.toOwnedSlice(allocator);
    }

    pub fn setProjectPackages(self: *SettingsManager, packages: []const PackageSource) !void {
        const value = try packageSourcesValue(self.arena.allocator(), packages);
        try putValue(self.arena.allocator(), &self.project_settings, "packages", value);
        try self.markProjectModified("packages");
        try self.saveProject();
    }

    pub fn getExtensionPathsAlloc(self: *const SettingsManager, allocator: std.mem.Allocator) ![]const []const u8 {
        return optionalStringArrayAlloc(allocator, fieldValue(self.settings, "extensions"));
    }

    pub fn setExtensionPaths(self: *SettingsManager, extension_paths: []const []const u8) !void {
        try putStringArray(self.arena.allocator(), &self.global_settings, "extensions", extension_paths);
        try self.markModified("extensions");
        try self.saveGlobal();
    }

    pub fn setProjectExtensionPaths(self: *SettingsManager, extension_paths: []const []const u8) !void {
        try putStringArray(self.arena.allocator(), &self.project_settings, "extensions", extension_paths);
        try self.markProjectModified("extensions");
        try self.saveProject();
    }

    pub fn getProjectPromptTemplatePathsAlloc(self: *const SettingsManager, allocator: std.mem.Allocator) ![]const []const u8 {
        return optionalStringArrayAlloc(allocator, fieldValue(self.project_settings, "prompts"));
    }

    fn loadScopedSettings(self: *SettingsManager, scope: SettingsScope) !LoadResult {
        const content = try self.readSettingsFile(scope);
        defer if (content) |bytes| self.allocator.free(bytes);
        if (content == null or content.?.len == 0) return .{ .value = objectValue() };

        var value = std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), content.?, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => |parse_error| return .{
                .value = objectValue(),
                .failed = true,
                .error_message = try std.fmt.allocPrint(self.arena.allocator(), "Invalid settings JSON: {s}", .{@errorName(parse_error)}),
            },
        };
        if (value != .object) return .{ .value = objectValue() };
        try migrateSettings(self.arena.allocator(), &value);
        return .{ .value = value };
    }

    fn readSettingsFile(self: *const SettingsManager, scope: SettingsScope) !?[]u8 {
        const path = self.pathForScope(scope);
        return std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(max_settings_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |read_error| return read_error,
        };
    }

    fn saveGlobal(self: *SettingsManager) !void {
        self.settings = try deepMergeSettings(self.arena.allocator(), self.global_settings, self.project_settings);
        if (self.global_settings_load_error) return;
        try self.persistScopedSettings(.global, self.global_settings, self.modified_fields.items);
        self.modified_fields.clearRetainingCapacity();
    }

    fn saveProject(self: *SettingsManager) !void {
        self.settings = try deepMergeSettings(self.arena.allocator(), self.global_settings, self.project_settings);
        if (self.project_settings_load_error) return;
        try self.persistScopedSettings(.project, self.project_settings, self.modified_project_fields.items);
        self.modified_project_fields.clearRetainingCapacity();
    }

    fn persistScopedSettings(
        self: *SettingsManager,
        scope: SettingsScope,
        snapshot_settings: std.json.Value,
        modified_fields: []const ModifiedField,
    ) !void {
        var current_file_settings: std.json.Value = objectValue();
        const current = try self.readSettingsFile(scope);
        defer if (current) |bytes| self.allocator.free(bytes);
        if (current) |content| {
            current_file_settings = std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), content, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => objectValue(),
            };
            if (current_file_settings != .object) current_file_settings = objectValue();
            try migrateSettings(self.arena.allocator(), &current_file_settings);
        }

        for (modified_fields) |modified| {
            const value = fieldValue(snapshot_settings, modified.field) orelse std.json.Value.null;
            if (modified.nested) |nested| {
                try putNestedModifiedValue(self.arena.allocator(), &current_file_settings, modified.field, nested, value);
            } else {
                try putValue(self.arena.allocator(), &current_file_settings, modified.field, value);
            }
        }

        const json = try stringifyJsonValue(self.allocator, current_file_settings);
        defer self.allocator.free(json);
        try self.writeSettingsFile(scope, json);
    }

    fn writeSettingsFile(self: *const SettingsManager, scope: SettingsScope, data: []const u8) !void {
        const path = self.pathForScope(scope);
        if (std.fs.path.dirname(path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(self.io, parent);
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = data,
            .flags = .{ .read = true, .truncate = true },
        });
    }

    fn pathForScope(self: *const SettingsManager, scope: SettingsScope) []const u8 {
        return switch (scope) {
            .global => self.global_settings_path,
            .project => self.project_settings_path,
        };
    }

    fn markModified(self: *SettingsManager, field: []const u8) !void {
        try self.modified_fields.append(self.allocator, .{ .field = field });
    }

    fn markProjectModified(self: *SettingsManager, field: []const u8) !void {
        try self.modified_project_fields.append(self.allocator, .{ .field = field });
    }

    fn recordError(self: *SettingsManager, scope: SettingsScope, message: []const u8) !void {
        try self.errors.append(self.allocator, .{
            .scope = scope,
            .message = message,
        });
    }
};

const ModifiedField = struct {
    field: []const u8,
    nested: ?[]const u8 = null,
};

const LoadResult = struct {
    value: std.json.Value,
    failed: bool = false,
    error_message: ?[]const u8 = null,
};

fn objectValue() std.json.Value {
    return .{ .object = .empty };
}

fn deepMergeSettings(allocator: std.mem.Allocator, base: std.json.Value, overrides: std.json.Value) !std.json.Value {
    if (base != .object and overrides != .object) return objectValue();
    if (base != .object) return cloneObjectValue(allocator, overrides);
    if (overrides != .object) return cloneObjectValue(allocator, base);

    var result = objectValue();
    var base_it = base.object.iterator();
    while (base_it.next()) |entry| {
        try putValue(allocator, &result, entry.key_ptr.*, entry.value_ptr.*);
    }

    var override_it = overrides.object.iterator();
    while (override_it.next()) |entry| {
        const base_value = result.object.get(entry.key_ptr.*);
        const override_value = entry.value_ptr.*;
        if (base_value) |existing| {
            if (existing == .object and override_value == .object) {
                try putValue(allocator, &result, entry.key_ptr.*, try shallowMergeObjects(allocator, existing, override_value));
                continue;
            }
        }
        try putValue(allocator, &result, entry.key_ptr.*, override_value);
    }

    return result;
}

fn shallowMergeObjects(allocator: std.mem.Allocator, base: std.json.Value, overrides: std.json.Value) !std.json.Value {
    var result = objectValue();
    var base_it = base.object.iterator();
    while (base_it.next()) |entry| {
        try putValue(allocator, &result, entry.key_ptr.*, entry.value_ptr.*);
    }
    var override_it = overrides.object.iterator();
    while (override_it.next()) |entry| {
        try putValue(allocator, &result, entry.key_ptr.*, entry.value_ptr.*);
    }
    return result;
}

fn cloneObjectValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    if (value != .object) return objectValue();
    var result = objectValue();
    var it = value.object.iterator();
    while (it.next()) |entry| {
        try putValue(allocator, &result, entry.key_ptr.*, entry.value_ptr.*);
    }
    return result;
}

fn migrateSettings(allocator: std.mem.Allocator, settings: *std.json.Value) !void {
    if (settings.* != .object) return;
    const object = &settings.object;

    if (object.get("queueMode")) |queue_mode| {
        if (object.get("steeringMode") == null) {
            try object.put(allocator, "steeringMode", queue_mode);
        }
        _ = object.orderedRemove("queueMode");
    }

    if (object.get("transport") == null) {
        if (object.get("websockets")) |websockets| {
            if (websockets == .bool) {
                try object.put(allocator, "transport", .{ .string = if (websockets.bool) "websocket" else "sse" });
                _ = object.orderedRemove("websockets");
            }
        }
    }

    if (object.get("skills")) |skills| {
        if (skills == .object) {
            if (skills.object.get("enableSkillCommands")) |enabled| {
                if (object.get("enableSkillCommands") == null) {
                    try object.put(allocator, "enableSkillCommands", enabled);
                }
            }
            if (skills.object.get("customDirectories")) |custom_directories| {
                if (custom_directories == .array and custom_directories.array.items.len > 0) {
                    try object.put(allocator, "skills", custom_directories);
                } else {
                    _ = object.orderedRemove("skills");
                }
            } else {
                _ = object.orderedRemove("skills");
            }
        }
    }

    if (object.getPtr("retry")) |retry| {
        if (retry.* == .object) {
            if (retry.object.get("maxDelayMs")) |max_delay_ms| {
                var provider = retry.object.get("provider") orelse objectValue();
                if (provider != .object) provider = objectValue();
                if (provider.object.get("maxRetryDelayMs") == null or provider.object.get("maxRetryDelayMs").? == .null) {
                    try provider.object.put(allocator, "maxRetryDelayMs", max_delay_ms);
                    try retry.object.put(allocator, "provider", provider);
                }
                _ = retry.object.orderedRemove("maxDelayMs");
            }
        }
    }
}

fn parseTimeoutSetting(value: ?std.json.Value, setting_name: []const u8) !?i64 {
    return parseHttpIdleTimeoutMs(value) orelse {
        if (value != null) {
            std.log.debug("invalid setting: {s}", .{setting_name});
            return error.InvalidHttpIdleTimeoutMs;
        }
        return null;
    };
}

fn parseHttpIdleTimeoutMs(value: ?std.json.Value) ?i64 {
    const actual = value orelse return null;
    return switch (actual) {
        .string => |text| parseHttpIdleTimeoutString(text),
        .integer => |integer| if (integer >= 0) integer else null,
        .float => |float| if (std.math.isFinite(float) and float >= 0) @intFromFloat(@floor(float)) else null,
        .number_string => |number| blk: {
            const parsed = std.fmt.parseFloat(f64, number) catch break :blk null;
            break :blk if (std.math.isFinite(parsed) and parsed >= 0) @as(i64, @intFromFloat(@floor(parsed))) else null;
        },
        else => null,
    };
}

fn parseHttpIdleTimeoutString(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "disabled")) return 0;
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (!std.math.isFinite(parsed) or parsed < 0) return null;
    return @intFromFloat(@floor(parsed));
}

fn fieldValue(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn optionalString(value: std.json.Value, field: []const u8) ?[]const u8 {
    const nested = fieldValue(value, field) orelse return null;
    if (nested != .string) return null;
    return nested.string;
}

fn optionalStringArrayAlloc(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]const []const u8 {
    const value = maybe_value orelse return allocator.alloc([]const u8, 0);
    if (value != .array) return allocator.alloc([]const u8, 0);

    var items: std.ArrayList([]const u8) = .empty;
    errdefer freeStringArray(allocator, items.items);
    for (value.array.items) |item| {
        if (item == .string) try items.append(allocator, try allocator.dupe(u8, item.string));
    }
    return items.toOwnedSlice(allocator);
}

fn freeOptionalStringArray(allocator: std.mem.Allocator, maybe_array: ?[]const []const u8) void {
    if (maybe_array) |array| freeStringArray(allocator, array);
}

fn freeStringArray(allocator: std.mem.Allocator, array: []const []const u8) void {
    for (array) |item| allocator.free(item);
    allocator.free(array);
}

fn putValue(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    if (object.* != .object) object.* = objectValue();
    try object.object.put(allocator, try allocator.dupe(u8, key), value);
}

fn putString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: []const u8) !void {
    try putValue(allocator, object, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putOptionalString(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try putString(allocator, object, key, text);
    } else {
        try putValue(allocator, object, key, .null);
    }
}

fn putInteger(allocator: std.mem.Allocator, object: *std.json.Value, key: []const u8, value: i64) !void {
    try putValue(allocator, object, key, .{ .integer = value });
}

fn putStringArray(
    allocator: std.mem.Allocator,
    object: *std.json.Value,
    key: []const u8,
    values: []const []const u8,
) !void {
    var array = std.json.Array.init(allocator);
    for (values) |value| {
        try array.append(.{ .string = try allocator.dupe(u8, value) });
    }
    try putValue(allocator, object, key, .{ .array = array });
}

fn putNestedModifiedValue(
    allocator: std.mem.Allocator,
    object: *std.json.Value,
    field: []const u8,
    nested: []const u8,
    value: std.json.Value,
) !void {
    var nested_object = fieldValue(object.*, field) orelse objectValue();
    if (nested_object != .object) nested_object = objectValue();
    const nested_value = if (value == .object) fieldValue(value, nested) orelse std.json.Value.null else std.json.Value.null;
    try putValue(allocator, &nested_object, nested, nested_value);
    try putValue(allocator, object, field, nested_object);
}

fn packageSourcesValue(allocator: std.mem.Allocator, packages: []const PackageSource) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (packages) |package| {
        switch (package) {
            .string => |source| try array.append(.{ .string = try allocator.dupe(u8, source) }),
            .object => |object| {
                var value = objectValue();
                try putString(allocator, &value, "source", object.source);
                if (object.extensions) |extensions| try putStringArray(allocator, &value, "extensions", extensions);
                if (object.skills) |skills| try putStringArray(allocator, &value, "skills", skills);
                if (object.prompts) |prompts| try putStringArray(allocator, &value, "prompts", prompts);
                if (object.themes) |themes| try putStringArray(allocator, &value, "themes", themes);
                try array.append(value);
            },
        }
    }
    return .{ .array = array };
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.write(value);
    return output.toOwnedSlice();
}

fn readJsonFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_settings_file_bytes));
    defer allocator.free(data);
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{});
}

fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .read = true, .truncate = true },
    });
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn settingsTestDirs(allocator: std.mem.Allocator) !struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    agent: []u8,
    project: []u8,

    fn cleanup(self: *@This(), allocator_: std.mem.Allocator) void {
        allocator_.free(self.project);
        allocator_.free(self.agent);
        allocator_.free(self.root);
        self.tmp.cleanup();
    }
} {
    var tmp = std.testing.tmpDir(.{});
    const root = try tempDirPathAlloc(allocator, &tmp);
    errdefer allocator.free(root);
    const agent = try std.fs.path.join(allocator, &.{ root, "agent" });
    errdefer allocator.free(agent);
    const project = try std.fs.path.join(allocator, &.{ root, "project" });
    errdefer allocator.free(project);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, agent);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project);
    return .{
        .tmp = tmp,
        .root = root,
        .agent = agent,
        .project = project,
    };
}

fn expectStringArray(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |expected_item, index| {
        try std.testing.expectEqualStrings(expected_item, actual[index]);
    }
}

fn expectJsonStringArray(value: std.json.Value, expected: []const []const u8) !void {
    try std.testing.expect(value == .array);
    try std.testing.expectEqual(expected.len, value.array.items.len);
    for (expected, 0..) |expected_item, index| {
        try std.testing.expect(value.array.items[index] == .string);
        try std.testing.expectEqualStrings(expected_item, value.array.items[index].string);
    }
}

// Ported from packages/coding-agent/test/settings-manager-bug.test.ts.
test "settings manager preserves file changes to packages array when changing unrelated setting" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"theme\":\"dark\",\"packages\":[\"npm:pi-mcp-adapter\"]}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();
    const initial_packages = try manager.getPackagesAlloc(allocator);
    defer deinitPackageSources(allocator, initial_packages);
    try std.testing.expectEqual(@as(usize, 1), initial_packages.len);
    try std.testing.expectEqualStrings("npm:pi-mcp-adapter", initial_packages[0].string);

    try writeFile(settings_path, "{\"theme\":\"dark\",\"packages\":[]}");
    try manager.setTheme("light");
    try manager.flush();

    var saved = try readJsonFile(allocator, settings_path);
    defer saved.deinit();
    try expectJsonStringArray(saved.value.object.get("packages").?, &.{});
    try std.testing.expectEqualStrings("light", saved.value.object.get("theme").?.string);
}

test "settings manager preserves file changes to extensions array when changing unrelated setting" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"theme\":\"dark\",\"extensions\":[\"/old/extension.ts\"]}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try writeFile(settings_path, "{\"theme\":\"dark\",\"extensions\":[\"/new/extension.ts\"]}");
    try manager.setDefaultThinkingLevel("high");
    try manager.flush();

    var saved = try readJsonFile(allocator, settings_path);
    defer saved.deinit();
    try expectJsonStringArray(saved.value.object.get("extensions").?, &.{"/new/extension.ts"});
    try std.testing.expectEqualStrings("high", saved.value.object.get("defaultThinkingLevel").?.string);
}

test "settings manager preserves external project settings changes when updating unrelated project field" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const project_settings_path = try std.fs.path.join(allocator, &.{ dirs.project, config.project_config_dir, "settings.json" });
    defer allocator.free(project_settings_path);
    try writeFile(project_settings_path, "{\"extensions\":[\"./old-extension.ts\"],\"prompts\":[\"./old-prompt.md\"]}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try writeFile(project_settings_path, "{\"extensions\":[\"./old-extension.ts\"],\"prompts\":[\"./new-prompt.md\"]}");
    try manager.setProjectExtensionPaths(&.{"./updated-extension.ts"});
    try manager.flush();

    var saved = try readJsonFile(allocator, project_settings_path);
    defer saved.deinit();
    try expectJsonStringArray(saved.value.object.get("prompts").?, &.{"./new-prompt.md"});
    try expectJsonStringArray(saved.value.object.get("extensions").?, &.{"./updated-extension.ts"});
}

test "settings manager lets in-memory project changes override external changes for same project field" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const project_settings_path = try std.fs.path.join(allocator, &.{ dirs.project, config.project_config_dir, "settings.json" });
    defer allocator.free(project_settings_path);
    try writeFile(project_settings_path, "{\"extensions\":[\"./initial-extension.ts\"]}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try writeFile(project_settings_path, "{\"extensions\":[\"./external-extension.ts\"]}");
    try manager.setProjectExtensionPaths(&.{"./in-memory-extension.ts"});
    try manager.flush();

    var saved = try readJsonFile(allocator, project_settings_path);
    defer saved.deinit();
    try expectJsonStringArray(saved.value.object.get("extensions").?, &.{"./in-memory-extension.ts"});
}

// Ported from packages/coding-agent/test/settings-manager.test.ts.
test "settings manager preserves externally added enabledModels when changing thinking level" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"theme\":\"dark\",\"defaultModel\":\"claude-sonnet\"}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try writeFile(settings_path, "{\"theme\":\"dark\",\"defaultModel\":\"claude-sonnet\",\"enabledModels\":[\"claude-opus-4-5\",\"gpt-5.2-codex\"]}");
    try manager.setDefaultThinkingLevel("high");
    try manager.flush();

    var saved = try readJsonFile(allocator, settings_path);
    defer saved.deinit();
    try expectJsonStringArray(saved.value.object.get("enabledModels").?, &.{ "claude-opus-4-5", "gpt-5.2-codex" });
    try std.testing.expectEqualStrings("high", saved.value.object.get("defaultThinkingLevel").?.string);
    try std.testing.expectEqualStrings("dark", saved.value.object.get("theme").?.string);
    try std.testing.expectEqualStrings("claude-sonnet", saved.value.object.get("defaultModel").?.string);
}

test "settings manager preserves custom settings when changing theme" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"defaultModel\":\"claude-sonnet\"}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try writeFile(settings_path, "{\"defaultModel\":\"claude-sonnet\",\"shellPath\":\"/bin/zsh\",\"extensions\":[\"/path/to/extension.ts\"]}");
    try manager.setTheme("light");
    try manager.flush();

    var saved = try readJsonFile(allocator, settings_path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("/bin/zsh", saved.value.object.get("shellPath").?.string);
    try expectJsonStringArray(saved.value.object.get("extensions").?, &.{"/path/to/extension.ts"});
    try std.testing.expectEqualStrings("light", saved.value.object.get("theme").?.string);
}

test "settings manager lets in-memory changes override file changes for same key" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"theme\":\"dark\"}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try writeFile(settings_path, "{\"theme\":\"dark\",\"defaultThinkingLevel\":\"low\"}");
    try manager.setDefaultThinkingLevel("high");
    try manager.flush();

    var saved = try readJsonFile(allocator, settings_path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("high", saved.value.object.get("defaultThinkingLevel").?.string);
}

test "settings manager keeps local-only extensions in extensions array" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"extensions\":[\"/local/ext.ts\",\"./relative/ext.ts\"]}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    const packages = try manager.getPackagesAlloc(allocator);
    defer deinitPackageSources(allocator, packages);
    try std.testing.expectEqual(@as(usize, 0), packages.len);

    const extensions = try manager.getExtensionPathsAlloc(allocator);
    defer freeStringArray(allocator, extensions);
    try expectStringArray(extensions, &.{ "/local/ext.ts", "./relative/ext.ts" });
}

test "settings manager handles packages with filtering objects" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path,
        \\{"packages":["npm:simple-pkg",{"source":"npm:shitty-extensions","extensions":["extensions/oracle.ts"],"skills":[]}]}
    );

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    const packages = try manager.getPackagesAlloc(allocator);
    defer deinitPackageSources(allocator, packages);
    try std.testing.expectEqual(@as(usize, 2), packages.len);
    try std.testing.expectEqualStrings("npm:simple-pkg", packages[0].string);
    try std.testing.expectEqualStrings("npm:shitty-extensions", packages[1].object.source);
    try expectStringArray(packages[1].object.extensions.?, &.{"extensions/oracle.ts"});
    try expectStringArray(packages[1].object.skills.?, &.{});
}

test "settings manager reloads global settings from disk and keeps previous settings on invalid reload" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"theme\":\"dark\",\"extensions\":[\"/before.ts\"]}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try writeFile(settings_path, "{\"theme\":\"light\",\"extensions\":[\"/after.ts\"],\"defaultModel\":\"claude-sonnet\"}");
    try manager.reload();
    try std.testing.expectEqualStrings("light", manager.getTheme().?);
    const extensions = try manager.getExtensionPathsAlloc(allocator);
    defer freeStringArray(allocator, extensions);
    try expectStringArray(extensions, &.{"/after.ts"});
    try std.testing.expectEqualStrings("claude-sonnet", manager.getDefaultModel().?);

    try writeFile(settings_path, "{ invalid json");
    try manager.reload();
    try std.testing.expectEqualStrings("light", manager.getTheme().?);
}

test "settings manager collects and clears load errors via drainErrors" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const global_settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(global_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &.{ dirs.project, config.project_config_dir, "settings.json" });
    defer allocator.free(project_settings_path);
    try writeFile(global_settings_path, "{ invalid global json");
    try writeFile(project_settings_path, "{ invalid project json");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();
    const errors = try manager.drainErrorsAlloc(allocator);
    defer allocator.free(errors);
    try std.testing.expectEqual(@as(usize, 2), errors.len);
    try std.testing.expectEqual(SettingsScope.global, errors[0].scope);
    try std.testing.expectEqual(SettingsScope.project, errors[1].scope);

    const empty = try manager.drainErrorsAlloc(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "settings manager does not create project config folder when only reading" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    const project_config_dir = try std.fs.path.join(allocator, &.{ dirs.project, config.project_config_dir });
    defer allocator.free(project_config_dir);
    try writeFile(settings_path, "{\"theme\":\"dark\"}");

    try std.Io.Dir.cwd().deleteTree(std.testing.io, project_config_dir);
    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();

    try std.testing.expect(!pathExists(project_config_dir));
    try std.testing.expectEqualStrings("dark", manager.getTheme().?);
}

test "settings manager creates project config folder when writing project settings" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    const project_config_dir = try std.fs.path.join(allocator, &.{ dirs.project, config.project_config_dir });
    defer allocator.free(project_config_dir);
    const project_settings_path = try std.fs.path.join(allocator, &.{ project_config_dir, "settings.json" });
    defer allocator.free(project_settings_path);
    try writeFile(settings_path, "{\"theme\":\"dark\"}");

    try std.Io.Dir.cwd().deleteTree(std.testing.io, project_config_dir);
    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();
    try std.testing.expect(!pathExists(project_config_dir));

    try manager.setProjectPackages(&.{.{ .object = .{ .source = "npm:test-pkg" } }});
    try manager.flush();

    try std.testing.expect(pathExists(project_config_dir));
    try std.testing.expect(pathExists(project_settings_path));
}

test "settings manager httpIdleTimeoutMs defaults merges and rejects invalid values" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();
    try std.testing.expectEqual(default_http_idle_timeout_ms, try manager.getHttpIdleTimeoutMs());

    const global_settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(global_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &.{ dirs.project, config.project_config_dir, "settings.json" });
    defer allocator.free(project_settings_path);
    try writeFile(global_settings_path, "{\"httpIdleTimeoutMs\":300000}");
    try writeFile(project_settings_path, "{\"httpIdleTimeoutMs\":0}");
    try manager.reload();
    try std.testing.expectEqual(@as(i64, 0), try manager.getHttpIdleTimeoutMs());

    try writeFile(global_settings_path, "{\"httpIdleTimeoutMs\":-1}");
    try writeFile(project_settings_path, "{}");
    try manager.reload();
    try std.testing.expectError(error.InvalidHttpIdleTimeoutMs, manager.getHttpIdleTimeoutMs());
}

test "settings manager loads and preserves shellCommandPrefix" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"shellCommandPrefix\":\"shopt -s expand_aliases\"}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();
    try std.testing.expectEqualStrings("shopt -s expand_aliases", manager.getShellCommandPrefix().?);

    try manager.setTheme("light");
    try manager.flush();

    var saved = try readJsonFile(allocator, settings_path);
    defer saved.deinit();
    try std.testing.expectEqualStrings("shopt -s expand_aliases", saved.value.object.get("shellCommandPrefix").?.string);
    try std.testing.expectEqualStrings("light", saved.value.object.get("theme").?.string);
}

test "settings manager shellCommandPrefix returns null when unset" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    const settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(settings_path);
    try writeFile(settings_path, "{\"theme\":\"dark\"}");

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();
    try std.testing.expect(manager.getShellCommandPrefix() == null);
}

test "settings manager getSessionDir uses project override and expands home" {
    const allocator = std.testing.allocator;
    var dirs = try settingsTestDirs(allocator);
    defer dirs.cleanup(allocator);

    var manager = try SettingsManager.create(allocator, std.testing.io, dirs.project, dirs.agent);
    defer manager.deinit();
    try std.testing.expect(try manager.getSessionDirAlloc(allocator, "/home/bulb") == null);

    const global_settings_path = try std.fs.path.join(allocator, &.{ dirs.agent, "settings.json" });
    defer allocator.free(global_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &.{ dirs.project, config.project_config_dir, "settings.json" });
    defer allocator.free(project_settings_path);
    try writeFile(global_settings_path, "{\"sessionDir\":\"/tmp/sessions\"}");
    try manager.reload();
    const global_session_dir = (try manager.getSessionDirAlloc(allocator, "/home/bulb")).?;
    defer allocator.free(global_session_dir);
    try std.testing.expectEqualStrings("/tmp/sessions", global_session_dir);

    try writeFile(project_settings_path, "{\"sessionDir\":\"./sessions\"}");
    try manager.reload();
    const project_session_dir = (try manager.getSessionDirAlloc(allocator, "/home/bulb")).?;
    defer allocator.free(project_session_dir);
    try std.testing.expectEqualStrings("./sessions", project_session_dir);

    try writeFile(project_settings_path, "{}");
    try writeFile(global_settings_path, "{\"sessionDir\":\"~/sessions\"}");
    try manager.reload();
    const expanded = (try manager.getSessionDirAlloc(allocator, "/home/bulb")).?;
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("/home/bulb/sessions", expanded);
}
