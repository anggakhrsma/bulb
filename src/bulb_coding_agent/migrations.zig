const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const keybindings = @import("keybindings.zig");
const config_value = @import("resolve_config_value.zig");
const json_utils = @import("json.zig");
const paths = @import("paths.zig");
const session_manager = @import("session_manager.zig");

const max_config_file_bytes = 4 * 1024 * 1024;

pub const ConfigValueMigration = struct {
    location: []u8,
    from: []u8,
    to: []u8,

    pub fn deinit(self: *ConfigValueMigration, allocator: std.mem.Allocator) void {
        allocator.free(self.location);
        allocator.free(self.from);
        allocator.free(self.to);
        self.* = .{
            .location = &.{},
            .from = &.{},
            .to = &.{},
        };
    }
};

pub const ConfigValueMigrationResult = struct {
    items: []ConfigValueMigration,

    pub fn deinit(self: *ConfigValueMigrationResult, allocator: std.mem.Allocator) void {
        for (self.items) |*migration| migration.deinit(allocator);
        allocator.free(self.items);
        self.* = .{ .items = &.{} };
    }
};

pub const RunMigrationsResult = struct {
    config_value_migrations: ConfigValueMigrationResult,

    pub fn deinit(self: *RunMigrationsResult, allocator: std.mem.Allocator) void {
        self.config_value_migrations.deinit(allocator);
        self.* = .{ .config_value_migrations = .{ .items = &.{} } };
    }
};

pub fn runMigrationsAlloc(allocator: std.mem.Allocator, agent_dir: []const u8) !RunMigrationsResult {
    migrateAuthToAuthJsonAlloc(allocator, agent_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };

    const config_value_migrations = migrateExplicitEnvVarConfigValuesAlloc(allocator, agent_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => ConfigValueMigrationResult{ .items = &.{} },
    };

    migrateSessionsFromAgentRootAlloc(allocator, agent_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };
    _ = keybindings.migrateKeybindingsConfigFile(allocator, agent_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    migrateToolsToBinAlloc(allocator, agent_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };

    return .{ .config_value_migrations = config_value_migrations };
}

pub fn runStartupMigrationsAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    agent_dir: []const u8,
) !RunMigrationsResult {
    var result = try runMigrationsAlloc(allocator, agent_dir);
    errdefer result.deinit(allocator);
    migrateCommandsToPromptsAlloc(allocator, agent_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };
    const project_dir = try std.fs.path.join(allocator, &.{ cwd, config.project_config_dir });
    defer allocator.free(project_dir);
    migrateCommandsToPromptsAlloc(allocator, project_dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    };
    return result;
}

fn migrateAuthToAuthJsonAlloc(allocator: std.mem.Allocator, agent_dir: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const process_cwd = try std.process.currentPathAlloc(io, temp_allocator);
    const resolved_agent_dir = try paths.resolvePathAlloc(temp_allocator, agent_dir, process_cwd, .{});

    const auth_path = try std.fs.path.join(temp_allocator, &.{ resolved_agent_dir, "auth.json" });
    const existing_auth = readExistingFileAlloc(allocator, auth_path) catch return;
    if (existing_auth) |existing| {
        allocator.free(existing);
        return;
    }

    var auth_value: std.json.Value = .{ .object = .empty };
    var oauth_migrated = false;
    const oauth_path = try std.fs.path.join(temp_allocator, &.{ resolved_agent_dir, "oauth.json" });
    const oauth_content = readExistingFileAlloc(allocator, oauth_path) catch return;
    if (oauth_content) |content| {
        defer allocator.free(content);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, temp_allocator, content, .{}) catch return;
        if (parsed == .object) {
            oauth_migrated = true;
            var iterator = parsed.object.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != .object) continue;
                var credential = &entry.value_ptr.object;
                if (credential.get("type") == null) {
                    try credential.put(temp_allocator, "type", .{ .string = "oauth" });
                }
                const provider = try temp_allocator.dupe(u8, entry.key_ptr.*);
                try auth_value.object.put(temp_allocator, provider, entry.value_ptr.*);
            }
        }
    }

    var settings_value: ?std.json.Value = null;
    var settings_needs_write = false;
    const settings_path = try std.fs.path.join(temp_allocator, &.{ resolved_agent_dir, "settings.json" });
    const settings_content = readExistingFileAlloc(allocator, settings_path) catch return;
    if (settings_content) |content| {
        defer allocator.free(content);
        var parsed = std.json.parseFromSliceLeaky(std.json.Value, temp_allocator, content, .{}) catch return;
        if (parsed == .object) {
            if (parsed.object.getPtr("apiKeys")) |api_keys_value| {
                if (api_keys_value.* == .object) {
                    var iterator = api_keys_value.object.iterator();
                    while (iterator.next()) |entry| {
                        if (entry.value_ptr.* != .string) continue;
                        if (auth_value.object.get(entry.key_ptr.*) != null) continue;

                        var credential: std.json.Value = .{ .object = .empty };
                        try credential.object.put(temp_allocator, "type", .{ .string = "api_key" });
                        try credential.object.put(temp_allocator, "key", .{ .string = entry.value_ptr.string });
                        const provider = try temp_allocator.dupe(u8, entry.key_ptr.*);
                        try auth_value.object.put(temp_allocator, provider, credential);
                    }
                    _ = parsed.object.orderedRemove("apiKeys");
                    settings_value = parsed;
                    settings_needs_write = true;
                }
            }
        }
    }

    if (auth_value.object.count() > 0 or settings_needs_write) {
        try std.Io.Dir.cwd().createDirPath(io, resolved_agent_dir);
    }

    if (auth_value.object.count() > 0) {
        try writeJsonValueFile(temp_allocator, auth_path, auth_value, true);
    }

    if (oauth_migrated) {
        const migrated_oauth_path = try std.fmt.allocPrint(temp_allocator, "{s}.migrated", .{oauth_path});
        std.Io.Dir.renameAbsolute(oauth_path, migrated_oauth_path, io) catch {};
    }

    if (settings_needs_write) {
        try writeJsonValueFile(temp_allocator, settings_path, settings_value.?, false);
    }
}

fn migrateSessionsFromAgentRootAlloc(allocator: std.mem.Allocator, agent_dir: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const process_cwd = try std.process.currentPathAlloc(io, temp_allocator);
    const resolved_agent_dir = try paths.resolvePathAlloc(temp_allocator, agent_dir, process_cwd, .{});

    var directory = std.Io.Dir.cwd().openDir(io, resolved_agent_dir, .{ .iterate = true }) catch return;
    defer directory.close(io);

    var iterator = directory.iterate();
    while (iterator.next(io) catch return) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const source_path = try std.fs.path.join(temp_allocator, &.{ resolved_agent_dir, entry.name });
        const content = (readExistingFileAlloc(allocator, source_path) catch continue) orelse continue;
        defer allocator.free(content);

        const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
        const first_line = std.mem.trim(u8, content[0..first_line_end], " \t\r\n");
        if (first_line.len == 0) continue;

        const header = std.json.parseFromSliceLeaky(std.json.Value, temp_allocator, first_line, .{}) catch continue;
        if (header != .object) continue;

        const type_value = header.object.get("type") orelse continue;
        if (type_value != .string or !std.mem.eql(u8, type_value.string, "session")) continue;

        const cwd_value = header.object.get("cwd") orelse continue;
        if (cwd_value != .string) continue;

        const target_dir = try session_manager.getDefaultSessionDirPathAlloc(temp_allocator, io, cwd_value.string, resolved_agent_dir);
        std.Io.Dir.cwd().createDirPath(io, target_dir) catch continue;

        const destination_path = try std.fs.path.join(temp_allocator, &.{ target_dir, entry.name });
        if (pathExists(io, destination_path)) continue;
        std.Io.Dir.renameAbsolute(source_path, destination_path, io) catch continue;
    }
}

fn migrateCommandsToPromptsAlloc(allocator: std.mem.Allocator, base_dir: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const process_cwd = try std.process.currentPathAlloc(io, temp_allocator);
    const resolved_base_dir = try paths.resolvePathAlloc(temp_allocator, base_dir, process_cwd, .{});
    const commands_dir = try std.fs.path.join(temp_allocator, &.{ resolved_base_dir, "commands" });
    if (!pathExists(io, commands_dir)) return;

    const prompts_dir = try std.fs.path.join(temp_allocator, &.{ resolved_base_dir, "prompts" });
    if (pathExists(io, prompts_dir)) return;
    std.Io.Dir.renameAbsolute(commands_dir, prompts_dir, io) catch {};
}

fn migrateToolsToBinAlloc(allocator: std.mem.Allocator, agent_dir: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    const process_cwd = try std.process.currentPathAlloc(io, temp_allocator);
    const resolved_agent_dir = try paths.resolvePathAlloc(temp_allocator, agent_dir, process_cwd, .{});
    const tools_dir = try std.fs.path.join(temp_allocator, &.{ resolved_agent_dir, "tools" });
    if (!pathExists(io, tools_dir)) return;

    const bin_dir = try std.fs.path.join(temp_allocator, &.{ resolved_agent_dir, "bin" });
    std.Io.Dir.cwd().createDirPath(io, bin_dir) catch return;

    for ([_][]const u8{ "fd", "rg", "fd.exe", "rg.exe" }) |tool_name| {
        const old_path = try std.fs.path.join(temp_allocator, &.{ tools_dir, tool_name });
        if (!pathExists(io, old_path)) continue;

        const new_path = try std.fs.path.join(temp_allocator, &.{ bin_dir, tool_name });
        if (pathExists(io, new_path)) {
            std.Io.Dir.cwd().deleteFile(io, old_path) catch {};
            continue;
        }

        std.Io.Dir.renameAbsolute(old_path, new_path, io) catch {};
    }
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn migrateExplicitEnvVarConfigValuesAlloc(
    allocator: std.mem.Allocator,
    agent_dir: []const u8,
) !ConfigValueMigrationResult {
    var migrations: std.ArrayList(ConfigValueMigration) = .empty;
    errdefer deinitMigrationItems(allocator, migrations.items);
    defer migrations.deinit(allocator);

    try migrateAuthJsonConfigValues(allocator, agent_dir, &migrations);
    try migrateModelsJsonConfigValues(allocator, agent_dir, &migrations);

    return .{ .items = try migrations.toOwnedSlice(allocator) };
}

pub fn formatConfigValueMigrationWarningAlloc(
    allocator: std.mem.Allocator,
    migrations: []const ConfigValueMigration,
) ![]u8 {
    if (migrations.len == 0) return allocator.dupe(u8, "");

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll(
        "Warning: Migrated API key/header environment references to explicit $ENV_VAR syntax. Plain strings will be treated as literals.",
    );
    for (migrations) |migration| {
        try output.writer.print("\n  - {s}: {s} -> {s}", .{ migration.location, migration.from, migration.to });
    }
    return output.toOwnedSlice();
}

fn migrateAuthJsonConfigValues(
    allocator: std.mem.Allocator,
    agent_dir: []const u8,
    migrations: *std.ArrayList(ConfigValueMigration),
) !void {
    const auth_path = try std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    const content = (try readExistingFileAlloc(allocator, auth_path)) orelse return;
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const start_len = migrations.items.len;
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        var credential = &entry.value_ptr.object;
        const type_value = credential.get("type") orelse continue;
        if (type_value != .string or !std.mem.eql(u8, type_value.string, "api_key")) continue;

        const provider_key = try jsonQuoteAlloc(allocator, entry.key_ptr.*);
        defer allocator.free(provider_key);
        const location = try std.fmt.allocPrint(allocator, "auth.json[{s}].key", .{provider_key});
        defer allocator.free(location);
        _ = try migrateStringProperty(allocator, credential, "key", location, migrations);
    }

    if (migrations.items.len == start_len) return;
    try writeJsonValueFile(allocator, auth_path, parsed.value, true);
}

fn migrateModelsJsonConfigValues(
    allocator: std.mem.Allocator,
    agent_dir: []const u8,
    migrations: *std.ArrayList(ConfigValueMigration),
) !void {
    const models_path = try std.fs.path.join(allocator, &.{ agent_dir, "models.json" });
    defer allocator.free(models_path);
    const content = (try readExistingFileAlloc(allocator, models_path)) orelse return;
    defer allocator.free(content);
    const stripped = try json_utils.stripJsonCommentsAlloc(allocator, content);
    defer allocator.free(stripped);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const providers_value = parsed.value.object.getPtr("providers") orelse return;
    if (providers_value.* != .object) return;

    const start_len = migrations.items.len;
    var provider_iterator = providers_value.object.iterator();
    while (provider_iterator.next()) |provider_entry| {
        if (provider_entry.value_ptr.* != .object) continue;
        var provider_record = &provider_entry.value_ptr.object;
        const provider_key = try jsonQuoteAlloc(allocator, provider_entry.key_ptr.*);
        defer allocator.free(provider_key);
        const provider_location = try std.fmt.allocPrint(
            allocator,
            "models.json.providers[{s}]",
            .{provider_key},
        );
        defer allocator.free(provider_location);

        const api_key_location = try std.fmt.allocPrint(allocator, "{s}.apiKey", .{provider_location});
        defer allocator.free(api_key_location);
        _ = try migrateStringProperty(allocator, provider_record, "apiKey", api_key_location, migrations);

        const headers_location = try std.fmt.allocPrint(allocator, "{s}.headers", .{provider_location});
        defer allocator.free(headers_location);
        try migrateHeadersConfig(allocator, provider_record.getPtr("headers"), headers_location, migrations);

        if (provider_record.getPtr("models")) |models_value| {
            if (models_value.* == .array) {
                for (models_value.array.items, 0..) |*model_value, index| {
                    if (model_value.* != .object) continue;
                    var model_record = &model_value.object;
                    const model_key = try modelLocationKeyAlloc(allocator, model_record, index);
                    defer allocator.free(model_key);
                    const model_headers_location = try std.fmt.allocPrint(
                        allocator,
                        "{s}.models[{s}].headers",
                        .{ provider_location, model_key },
                    );
                    defer allocator.free(model_headers_location);
                    try migrateHeadersConfig(allocator, model_record.getPtr("headers"), model_headers_location, migrations);
                }
            }
        }

        if (provider_record.getPtr("modelOverrides")) |overrides_value| {
            if (overrides_value.* == .object) {
                var override_iterator = overrides_value.object.iterator();
                while (override_iterator.next()) |override_entry| {
                    if (override_entry.value_ptr.* != .object) continue;
                    const model_key = try jsonQuoteAlloc(allocator, override_entry.key_ptr.*);
                    defer allocator.free(model_key);
                    const override_headers_location = try std.fmt.allocPrint(
                        allocator,
                        "{s}.modelOverrides[{s}].headers",
                        .{ provider_location, model_key },
                    );
                    defer allocator.free(override_headers_location);
                    try migrateHeadersConfig(
                        allocator,
                        override_entry.value_ptr.object.getPtr("headers"),
                        override_headers_location,
                        migrations,
                    );
                }
            }
        }
    }

    if (migrations.items.len == start_len) return;
    try writeJsonValueFile(allocator, models_path, parsed.value, false);
}

fn migrateStringProperty(
    allocator: std.mem.Allocator,
    record: *std.json.ObjectMap,
    key: []const u8,
    location: []const u8,
    migrations: *std.ArrayList(ConfigValueMigration),
) !bool {
    const value = record.getPtr(key) orelse return false;
    return migrateStringValue(allocator, value, location, migrations);
}

fn migrateHeadersConfig(
    allocator: std.mem.Allocator,
    headers: ?*std.json.Value,
    location: []const u8,
    migrations: *std.ArrayList(ConfigValueMigration),
) !void {
    const headers_value = headers orelse return;
    if (headers_value.* != .object) return;

    var iterator = headers_value.object.iterator();
    while (iterator.next()) |entry| {
        const header_key = try jsonQuoteAlloc(allocator, entry.key_ptr.*);
        defer allocator.free(header_key);
        const header_location = try std.fmt.allocPrint(allocator, "{s}[{s}]", .{ location, header_key });
        defer allocator.free(header_location);
        _ = try migrateStringValue(allocator, entry.value_ptr, header_location, migrations);
    }
}

fn migrateStringValue(
    allocator: std.mem.Allocator,
    value: *std.json.Value,
    location: []const u8,
    migrations: *std.ArrayList(ConfigValueMigration),
) !bool {
    if (value.* != .string) return false;
    if (!config_value.isLegacyEnvVarNameConfigValue(value.string)) return false;

    const migrated = try appendConfigValueMigration(allocator, migrations, location, value.string);
    value.* = .{ .string = migrated };
    return true;
}

fn appendConfigValueMigration(
    allocator: std.mem.Allocator,
    migrations: *std.ArrayList(ConfigValueMigration),
    location: []const u8,
    from: []const u8,
) ![]u8 {
    const migrated = try std.fmt.allocPrint(allocator, "${s}", .{from});
    errdefer allocator.free(migrated);
    const location_copy = try allocator.dupe(u8, location);
    errdefer allocator.free(location_copy);
    const from_copy = try allocator.dupe(u8, from);
    errdefer allocator.free(from_copy);
    try migrations.append(allocator, .{
        .location = location_copy,
        .from = from_copy,
        .to = migrated,
    });
    return migrated;
}

fn modelLocationKeyAlloc(
    allocator: std.mem.Allocator,
    model_record: *std.json.ObjectMap,
    index: usize,
) ![]u8 {
    if (model_record.get("id")) |id| {
        if (id == .string) return jsonQuoteAlloc(allocator, id.string);
    }
    return std.fmt.allocPrint(allocator, "{d}", .{index});
}

fn readExistingFileAlloc(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_config_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |read_error| return read_error,
    };
}

fn writeJsonValueFile(allocator: std.mem.Allocator, path: []const u8, value: std.json.Value, private: bool) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var writer: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try writer.write(value);
    try output.writer.writeByte('\n');
    const content = try output.toOwnedSlice();
    defer allocator.free(content);

    if (private) {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = content,
            .flags = .{
                .read = true,
                .truncate = true,
                .permissions = privateFilePermissions(),
            },
        });
    } else {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = content,
        });
    }
}

fn jsonQuoteAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
}

fn deinitMigrationItems(allocator: std.mem.Allocator, items: []ConfigValueMigration) void {
    for (items) |*migration| migration.deinit(allocator);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn expectMigration(migrations: []const ConfigValueMigration, location: []const u8, from: []const u8, to: []const u8) !void {
    for (migrations) |migration| {
        if (!std.mem.eql(u8, migration.location, location)) continue;
        try std.testing.expectEqualStrings(from, migration.from);
        try std.testing.expectEqualStrings(to, migration.to);
        return;
    }
    return error.MissingMigration;
}

test "config value migration rewrites legacy uppercase auth.json API key values to explicit env references" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data =
        \\{
        \\  "anthropic": { "type": "api_key", "key": "ANTHROPIC_API_KEY" },
        \\  "openai": { "type": "api_key", "key": "$OPENAI_API_KEY" },
        \\  "opencode": { "type": "api_key", "key": "public" },
        \\  "github": { "type": "oauth", "access": "ACCESS_TOKEN", "refresh": "REFRESH_TOKEN", "expires": 1 }
        \\}
        ,
    });
    const auth_path = try tmp.dir.realPathFileAlloc(io, "auth.json", allocator);
    defer allocator.free(auth_path);
    const agent_dir = try allocator.dupe(u8, std.fs.path.dirname(auth_path).?);
    defer allocator.free(agent_dir);

    var result = try runMigrationsAlloc(allocator, agent_dir);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.config_value_migrations.items.len);
    try expectMigration(
        result.config_value_migrations.items,
        "auth.json[\"anthropic\"].key",
        "ANTHROPIC_API_KEY",
        "$ANTHROPIC_API_KEY",
    );

    const migrated = try tmp.dir.readFileAlloc(io, "auth.json", allocator, .limited(max_config_file_bytes));
    defer allocator.free(migrated);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, migrated, .{});
    defer parsed.deinit();
    const auth = parsed.value.object;
    try std.testing.expectEqualStrings("$ANTHROPIC_API_KEY", auth.get("anthropic").?.object.get("key").?.string);
    try std.testing.expectEqualStrings("$OPENAI_API_KEY", auth.get("openai").?.object.get("key").?.string);
    try std.testing.expectEqualStrings("public", auth.get("opencode").?.object.get("key").?.string);
    try std.testing.expectEqualStrings("ACCESS_TOKEN", auth.get("github").?.object.get("access").?.string);

    const warning = try formatConfigValueMigrationWarningAlloc(allocator, result.config_value_migrations.items);
    defer allocator.free(warning);
    try std.testing.expect(std.mem.indexOf(u8, warning, "explicit $ENV_VAR syntax") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        warning,
        "auth.json[\"anthropic\"].key: ANTHROPIC_API_KEY -> $ANTHROPIC_API_KEY",
    ) != null);
}

test "config value migration rewrites legacy uppercase models.json API key and header values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "models.json",
        .data =
        \\{
        \\  "providers": {
        \\    "custom-provider": {
        \\      "baseUrl": "https://example.com/v1",
        \\      "apiKey": "CUSTOM_API_KEY",
        \\      "api": "openai-completions",
        \\      "headers": {
        \\        "x-api-key": "HEADER_API_KEY",
        \\        "x-literal": "literal"
        \\      },
        \\      "models": [
        \\        {
        \\          "id": "model-a",
        \\          "headers": { "x-model-key": "MODEL_API_KEY" }
        \\        }
        \\      ],
        \\      "modelOverrides": {
        \\        "model-b": { "headers": { "x-override-key": "OVERRIDE_API_KEY" } }
        \\      }
        \\    }
        \\  }
        \\}
        ,
    });
    const models_path = try tmp.dir.realPathFileAlloc(io, "models.json", allocator);
    defer allocator.free(models_path);
    const agent_dir = try allocator.dupe(u8, std.fs.path.dirname(models_path).?);
    defer allocator.free(agent_dir);

    var result = try runMigrationsAlloc(allocator, agent_dir);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), result.config_value_migrations.items.len);
    try expectMigration(
        result.config_value_migrations.items,
        "models.json.providers[\"custom-provider\"].apiKey",
        "CUSTOM_API_KEY",
        "$CUSTOM_API_KEY",
    );
    try expectMigration(
        result.config_value_migrations.items,
        "models.json.providers[\"custom-provider\"].headers[\"x-api-key\"]",
        "HEADER_API_KEY",
        "$HEADER_API_KEY",
    );
    try expectMigration(
        result.config_value_migrations.items,
        "models.json.providers[\"custom-provider\"].models[\"model-a\"].headers[\"x-model-key\"]",
        "MODEL_API_KEY",
        "$MODEL_API_KEY",
    );
    try expectMigration(
        result.config_value_migrations.items,
        "models.json.providers[\"custom-provider\"].modelOverrides[\"model-b\"].headers[\"x-override-key\"]",
        "OVERRIDE_API_KEY",
        "$OVERRIDE_API_KEY",
    );

    const migrated = try tmp.dir.readFileAlloc(io, "models.json", allocator, .limited(max_config_file_bytes));
    defer allocator.free(migrated);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, migrated, .{});
    defer parsed.deinit();
    const provider = parsed.value.object.get("providers").?.object.get("custom-provider").?.object;
    try std.testing.expectEqualStrings("$CUSTOM_API_KEY", provider.get("apiKey").?.string);
    try std.testing.expectEqualStrings("$HEADER_API_KEY", provider.get("headers").?.object.get("x-api-key").?.string);
    try std.testing.expectEqualStrings("literal", provider.get("headers").?.object.get("x-literal").?.string);
    try std.testing.expectEqualStrings(
        "$MODEL_API_KEY",
        provider.get("models").?.array.items[0].object.get("headers").?.object.get("x-model-key").?.string,
    );
    try std.testing.expectEqualStrings(
        "$OVERRIDE_API_KEY",
        provider.get("modelOverrides").?.object.get("model-b").?.object.get("headers").?.object.get("x-override-key").?.string,
    );

    const warning = try formatConfigValueMigrationWarningAlloc(allocator, result.config_value_migrations.items);
    defer allocator.free(warning);
    try std.testing.expect(std.mem.indexOf(
        u8,
        warning,
        "models.json.providers[\"custom-provider\"].apiKey: CUSTOM_API_KEY -> $CUSTOM_API_KEY",
    ) != null);
}

test "startup migrations move legacy oauth.json and settings apiKeys into auth.json" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(temp_path);
    const agent_dir = try std.fs.path.join(allocator, &.{ temp_path, "agent" });
    defer allocator.free(agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);

    try tmp.dir.writeFile(io, .{
        .sub_path = "agent/oauth.json",
        .data =
        \\{
        \\  "anthropic": {
        \\    "access": "ACCESS_TOKEN",
        \\    "refresh": "REFRESH_TOKEN",
        \\    "expires": 1
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "agent/settings.json",
        .data =
        \\{
        \\  "theme": "dark",
        \\  "apiKeys": {
        \\    "openai": "openai-secret"
        \\  }
        \\}
        ,
    });

    var result = try runMigrationsAlloc(allocator, agent_dir);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.config_value_migrations.items.len);

    const migrated_auth = try tmp.dir.readFileAlloc(io, "agent/auth.json", allocator, .limited(max_config_file_bytes));
    defer allocator.free(migrated_auth);
    var auth_parsed = try std.json.parseFromSlice(std.json.Value, allocator, migrated_auth, .{});
    defer auth_parsed.deinit();
    const auth = auth_parsed.value.object;
    try std.testing.expectEqualStrings("oauth", auth.get("anthropic").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("ACCESS_TOKEN", auth.get("anthropic").?.object.get("access").?.string);
    try std.testing.expectEqualStrings("REFRESH_TOKEN", auth.get("anthropic").?.object.get("refresh").?.string);
    try std.testing.expectEqual(@as(i64, 1), auth.get("anthropic").?.object.get("expires").?.integer);
    try std.testing.expectEqualStrings("api_key", auth.get("openai").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("openai-secret", auth.get("openai").?.object.get("key").?.string);

    const migrated_settings = try tmp.dir.readFileAlloc(io, "agent/settings.json", allocator, .limited(max_config_file_bytes));
    defer allocator.free(migrated_settings);
    var settings_parsed = try std.json.parseFromSlice(std.json.Value, allocator, migrated_settings, .{});
    defer settings_parsed.deinit();
    try std.testing.expectEqualStrings("dark", settings_parsed.value.object.get("theme").?.string);
    try std.testing.expectEqual(null, settings_parsed.value.object.get("apiKeys"));

    try tmp.dir.access(io, "agent/oauth.json.migrated", .{});
}

test "startup migrations move agent root sessions into encoded session directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(temp_path);
    const agent_dir = try std.fs.path.join(allocator, &.{ temp_path, "agent" });
    defer allocator.free(agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);

    const project_cwd = try std.fs.path.join(allocator, &.{ temp_path, "project" });
    defer allocator.free(project_cwd);

    const session_file_name = "legacy.jsonl";
    const source_session_path = try std.fs.path.join(allocator, &.{ agent_dir, session_file_name });
    defer allocator.free(source_session_path);
    const session_content = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"session\",\"cwd\":\"{s}\",\"id\":\"legacy-session\"}}\n",
        .{project_cwd},
    );
    defer allocator.free(session_content);
    try tmp.dir.writeFile(io, .{
        .sub_path = "agent/legacy.jsonl",
        .data = session_content,
    });

    var result = try runMigrationsAlloc(allocator, agent_dir);
    defer result.deinit(allocator);

    const expected_session_dir = try session_manager.getDefaultSessionDirPathAlloc(
        allocator,
        io,
        project_cwd,
        agent_dir,
    );
    defer allocator.free(expected_session_dir);
    const expected_session_path = try std.fs.path.join(allocator, &.{ expected_session_dir, session_file_name });
    defer allocator.free(expected_session_path);

    try std.Io.Dir.cwd().access(io, expected_session_path, .{});
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, source_session_path, .{}));
}
