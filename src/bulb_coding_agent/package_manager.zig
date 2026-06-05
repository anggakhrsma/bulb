const std = @import("std");
const config = @import("config.zig");
const paths = @import("paths.zig");
const settings_manager = @import("settings_manager.zig");
const source_info = @import("source_info.zig");

pub const PathMetadata = source_info.PathMetadata;
pub const SourceScope = source_info.SourceScope;
pub const SourceOrigin = source_info.SourceOrigin;
pub const PackageSource = settings_manager.PackageSource;
pub const PackageObject = settings_manager.PackageObject;

const ResourceType = enum {
    extensions,
    skills,
    prompts,
    themes,
};

pub const ResolvedResource = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    enabled: bool,
    metadata: PathMetadata,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        path: []const u8,
        enabled: bool,
        metadata: PathMetadata,
    ) !ResolvedResource {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_source = try allocator.dupe(u8, metadata.source);
        errdefer allocator.free(owned_source);
        const owned_base_dir = if (metadata.base_dir) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_base_dir) |value| allocator.free(value);
        return .{
            .allocator = allocator,
            .path = owned_path,
            .enabled = enabled,
            .metadata = .{
                .source = owned_source,
                .scope = metadata.scope,
                .origin = metadata.origin,
                .base_dir = owned_base_dir,
            },
        };
    }

    pub fn deinit(self: *ResolvedResource) void {
        self.allocator.free(self.path);
        self.allocator.free(@constCast(self.metadata.source));
        if (self.metadata.base_dir) |value| self.allocator.free(@constCast(value));
        self.* = undefined;
    }
};

pub const ResolvedPaths = struct {
    allocator: std.mem.Allocator,
    extensions: []ResolvedResource,
    skills: []ResolvedResource,
    prompts: []ResolvedResource,
    themes: []ResolvedResource,

    pub fn deinit(self: *ResolvedPaths) void {
        deinitResolvedResources(self.allocator, self.extensions);
        deinitResolvedResources(self.allocator, self.skills);
        deinitResolvedResources(self.allocator, self.prompts);
        deinitResolvedResources(self.allocator, self.themes);
        self.* = undefined;
    }
};

pub const DefaultPackageManagerOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: *settings_manager.SettingsManager,
};

pub const DefaultPackageManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
    agent_dir: []u8,
    settings_manager: *settings_manager.SettingsManager,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: DefaultPackageManagerOptions,
    ) !DefaultPackageManager {
        const resolved_cwd = try paths.resolvePathAlloc(allocator, options.cwd, ".", .{});
        errdefer allocator.free(resolved_cwd);
        const resolved_agent_dir = try paths.resolvePathAlloc(allocator, options.agent_dir, ".", .{});
        errdefer allocator.free(resolved_agent_dir);
        return .{
            .allocator = allocator,
            .io = io,
            .cwd = resolved_cwd,
            .agent_dir = resolved_agent_dir,
            .settings_manager = options.settings_manager,
        };
    }

    pub fn deinit(self: *DefaultPackageManager) void {
        self.allocator.free(self.cwd);
        self.allocator.free(self.agent_dir);
        self.* = undefined;
    }

    pub fn resolve(self: *DefaultPackageManager) !ResolvedPaths {
        var accumulator = ResourceAccumulator.init(self.allocator);
        defer accumulator.deinit();

        const project_base_dir = try std.fs.path.join(self.allocator, &.{ self.cwd, config.project_config_dir });
        defer self.allocator.free(project_base_dir);
        const global_base_dir = self.agent_dir;

        try self.resolveScopedLocalEntries(.project, project_base_dir, &accumulator);
        try self.addAutoDiscoveredResources(.project, project_base_dir, &accumulator);
        try self.resolveScopedLocalEntries(.user, global_base_dir, &accumulator);
        try self.addAutoDiscoveredResources(.user, global_base_dir, &accumulator);
        try self.resolveConfiguredPackages(&accumulator);

        return try accumulator.toResolvedPaths(self.io);
    }

    pub fn resolveExtensionSources(
        self: *DefaultPackageManager,
        sources: []const []const u8,
        temporary: bool,
        local: bool,
    ) !ResolvedPaths {
        var accumulator = ResourceAccumulator.init(self.allocator);
        defer accumulator.deinit();
        const scope: SourceScope = if (temporary) .temporary else if (local) .project else .user;
        const base_dir = try self.baseDirForScopeAlloc(scope);
        defer self.allocator.free(base_dir);
        for (sources) |source| {
            try self.resolvePackageSource(.{ .string = source }, scope, base_dir, &accumulator);
        }
        return try accumulator.toResolvedPaths(self.io);
    }

    fn resolveScopedLocalEntries(
        self: *DefaultPackageManager,
        scope: SourceScope,
        base_dir: []const u8,
        accumulator: *ResourceAccumulator,
    ) !void {
        const metadata = PathMetadata{
            .source = "local",
            .scope = scope,
            .origin = .top_level,
            .base_dir = base_dir,
        };
        switch (scope) {
            .project => {
                const extension_paths = try self.settings_manager.getProjectExtensionPathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, extension_paths);
                const skill_paths = try self.settings_manager.getProjectSkillPathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, skill_paths);
                const prompt_paths = try self.settings_manager.getProjectPromptTemplatePathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, prompt_paths);
                const theme_paths = try self.settings_manager.getProjectThemePathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, theme_paths);
                try self.resolveLocalEntries(extension_paths, .extensions, metadata, base_dir, &accumulator.extensions);
                try self.resolveLocalEntries(skill_paths, .skills, metadata, base_dir, &accumulator.skills);
                try self.resolveLocalEntries(prompt_paths, .prompts, metadata, base_dir, &accumulator.prompts);
                try self.resolveLocalEntries(theme_paths, .themes, metadata, base_dir, &accumulator.themes);
            },
            .user => {
                const extension_paths = try self.settings_manager.getGlobalExtensionPathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, extension_paths);
                const skill_paths = try self.settings_manager.getGlobalSkillPathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, skill_paths);
                const prompt_paths = try self.settings_manager.getGlobalPromptTemplatePathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, prompt_paths);
                const theme_paths = try self.settings_manager.getGlobalThemePathsAlloc(self.allocator);
                defer freeStringArray(self.allocator, theme_paths);
                try self.resolveLocalEntries(extension_paths, .extensions, metadata, base_dir, &accumulator.extensions);
                try self.resolveLocalEntries(skill_paths, .skills, metadata, base_dir, &accumulator.skills);
                try self.resolveLocalEntries(prompt_paths, .prompts, metadata, base_dir, &accumulator.prompts);
                try self.resolveLocalEntries(theme_paths, .themes, metadata, base_dir, &accumulator.themes);
            },
            .temporary => {},
        }
    }

    fn resolveConfiguredPackages(self: *DefaultPackageManager, accumulator: *ResourceAccumulator) !void {
        const project_packages = try self.settings_manager.getProjectPackagesAlloc(self.allocator);
        defer settings_manager.deinitPackageSources(self.allocator, project_packages);
        const global_packages = try self.settings_manager.getGlobalPackagesAlloc(self.allocator);
        defer settings_manager.deinitPackageSources(self.allocator, global_packages);

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer deinitStringSet(self.allocator, &seen);

        const project_base_dir = try self.baseDirForScopeAlloc(.project);
        defer self.allocator.free(project_base_dir);
        for (project_packages) |package| {
            const key = try self.packageIdentityAlloc(package, .project, project_base_dir);
            defer self.allocator.free(key);
            if (seen.contains(key)) continue;
            try seen.put(self.allocator, try self.allocator.dupe(u8, key), {});
            try self.resolvePackageSource(package, .project, project_base_dir, accumulator);
        }

        const global_base_dir = try self.baseDirForScopeAlloc(.user);
        defer self.allocator.free(global_base_dir);
        for (global_packages) |package| {
            const key = try self.packageIdentityAlloc(package, .user, global_base_dir);
            defer self.allocator.free(key);
            if (seen.contains(key)) continue;
            try seen.put(self.allocator, try self.allocator.dupe(u8, key), {});
            try self.resolvePackageSource(package, .user, global_base_dir, accumulator);
        }
    }

    fn packageIdentityAlloc(
        self: *DefaultPackageManager,
        package: PackageSource,
        scope: SourceScope,
        base_dir: []const u8,
    ) ![]u8 {
        _ = scope;
        const source = packageSourceString(package);
        if (!paths.isLocalPath(source)) return std.fmt.allocPrint(self.allocator, "remote:{s}", .{source});
        const resolved = try paths.resolvePathAlloc(self.allocator, source, base_dir, .{ .trim = true });
        defer self.allocator.free(resolved);
        return std.fmt.allocPrint(self.allocator, "local:{s}", .{resolved});
    }

    fn resolvePackageSource(
        self: *DefaultPackageManager,
        package: PackageSource,
        scope: SourceScope,
        base_dir: []const u8,
        accumulator: *ResourceAccumulator,
    ) !void {
        const source = packageSourceString(package);
        if (!paths.isLocalPath(source)) return;
        const resolved = try paths.resolvePathAlloc(self.allocator, source, base_dir, .{ .trim = true });
        defer self.allocator.free(resolved);

        const stat = std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = true }) catch return;
        var metadata = PathMetadata{
            .source = source,
            .scope = scope,
            .origin = .package,
            .base_dir = if (stat.kind == .directory) resolved else std.fs.path.dirname(resolved),
        };
        if (stat.kind == .file) {
            try accumulator.add(.extensions, resolved, true, metadata);
            return;
        }
        if (stat.kind != .directory) return;

        metadata.base_dir = resolved;
        if (package == .object) {
            _ = try self.collectPackageResources(resolved, package.object, metadata, accumulator);
        } else if (!try self.collectPackageResources(resolved, null, metadata, accumulator)) {
            try accumulator.add(.extensions, resolved, true, metadata);
        }
    }

    fn collectPackageResources(
        self: *DefaultPackageManager,
        package_root: []const u8,
        filter: ?PackageObject,
        metadata: PathMetadata,
        accumulator: *ResourceAccumulator,
    ) !bool {
        var found = false;
        inline for (.{ ResourceType.extensions, ResourceType.skills, ResourceType.prompts, ResourceType.themes }) |resource_type| {
            const filter_patterns = if (filter) |object| switch (resource_type) {
                .extensions => object.extensions,
                .skills => object.skills,
                .prompts => object.prompts,
                .themes => object.themes,
            } else null;
            if (filter_patterns) |patterns| {
                found = true;
                _ = try self.collectPackageResourceType(package_root, resource_type, patterns, metadata, accumulator);
            } else if (try self.collectPackageResourceType(package_root, resource_type, null, metadata, accumulator)) {
                found = true;
            }
        }
        return found;
    }

    fn collectPackageResourceType(
        self: *DefaultPackageManager,
        package_root: []const u8,
        resource_type: ResourceType,
        patterns: ?[]const []const u8,
        metadata: PathMetadata,
        accumulator: *ResourceAccumulator,
    ) !bool {
        var files: std.ArrayList([]u8) = .empty;
        defer freePathList(self.allocator, &files);

        if (try self.manifestEntriesAlloc(package_root, resource_type)) |entries| {
            defer freeStringArray(self.allocator, entries);
            try self.collectFilesFromManifestEntries(entries, package_root, resource_type, &files);
        } else {
            const convention_dir = try std.fs.path.join(self.allocator, &.{ package_root, resourceTypeName(resource_type) });
            defer self.allocator.free(convention_dir);
            try self.collectFilesFromPath(convention_dir, resource_type, true, &files);
        }
        if (files.items.len == 0) return false;

        const target = accumulator.target(resource_type);
        for (files.items) |file_path| {
            const enabled = if (patterns) |filter_patterns|
                filter_patterns.len > 0 and applyPatterns(file_path, filter_patterns, package_root)
            else
                true;
            try target.append(self.allocator, try ResolvedResource.initAlloc(self.allocator, file_path, enabled, metadata));
        }
        return true;
    }

    fn manifestEntriesAlloc(
        self: *DefaultPackageManager,
        package_root: []const u8,
        resource_type: ResourceType,
    ) !?[]const []const u8 {
        const package_json_path = try std.fs.path.join(self.allocator, &.{ package_root, "package.json" });
        defer self.allocator.free(package_json_path);
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, package_json_path, self.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        defer self.allocator.free(content);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const json = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), content, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (json != .object) return null;
        const pi = json.object.get("pi") orelse json.object.get("bulb") orelse return null;
        if (pi != .object) return null;
        const entries_value = pi.object.get(resourceTypeName(resource_type)) orelse return null;
        return stringArrayFromJsonAlloc(self.allocator, entries_value);
    }

    fn collectFilesFromManifestEntries(
        self: *DefaultPackageManager,
        entries: []const []const u8,
        root: []const u8,
        resource_type: ResourceType,
        files: *std.ArrayList([]u8),
    ) !void {
        for (entries) |entry| {
            if (isOverridePattern(entry)) continue;
            if (hasGlobPattern(entry)) continue;
            const resolved = try paths.resolvePathAlloc(self.allocator, entry, root, .{ .trim = true });
            defer self.allocator.free(resolved);
            try self.collectFilesFromPath(resolved, resource_type, true, files);
        }
    }

    fn resolveLocalEntries(
        self: *DefaultPackageManager,
        entries: []const []const u8,
        resource_type: ResourceType,
        metadata: PathMetadata,
        base_dir: []const u8,
        target: *std.ArrayList(ResolvedResource),
    ) !void {
        for (entries) |entry| {
            if (isPattern(entry)) continue;
            const resolved = try paths.resolvePathAlloc(self.allocator, entry, base_dir, .{ .trim = true });
            defer self.allocator.free(resolved);

            var files: std.ArrayList([]u8) = .empty;
            defer freePathList(self.allocator, &files);
            try self.collectFilesFromPath(resolved, resource_type, true, &files);
            for (files.items) |file_path| {
                const enabled = applyPatterns(file_path, entries, base_dir);
                try target.append(self.allocator, try ResolvedResource.initAlloc(self.allocator, file_path, enabled, metadata));
            }
        }
    }

    fn addAutoDiscoveredResources(
        self: *DefaultPackageManager,
        scope: SourceScope,
        base_dir: []const u8,
        accumulator: *ResourceAccumulator,
    ) !void {
        const metadata = PathMetadata{
            .source = "auto",
            .scope = scope,
            .origin = .top_level,
            .base_dir = base_dir,
        };
        const extension_overrides = if (scope == .project)
            try self.settings_manager.getProjectExtensionPathsAlloc(self.allocator)
        else
            try self.settings_manager.getGlobalExtensionPathsAlloc(self.allocator);
        defer freeStringArray(self.allocator, extension_overrides);
        const skill_overrides = if (scope == .project)
            try self.settings_manager.getProjectSkillPathsAlloc(self.allocator)
        else
            try self.settings_manager.getGlobalSkillPathsAlloc(self.allocator);
        defer freeStringArray(self.allocator, skill_overrides);
        const prompt_overrides = if (scope == .project)
            try self.settings_manager.getProjectPromptTemplatePathsAlloc(self.allocator)
        else
            try self.settings_manager.getGlobalPromptTemplatePathsAlloc(self.allocator);
        defer freeStringArray(self.allocator, prompt_overrides);
        const theme_overrides = if (scope == .project)
            try self.settings_manager.getProjectThemePathsAlloc(self.allocator)
        else
            try self.settings_manager.getGlobalThemePathsAlloc(self.allocator);
        defer freeStringArray(self.allocator, theme_overrides);

        try self.addAutoResourceType(base_dir, "extensions", .extensions, metadata, extension_overrides, &accumulator.extensions);
        try self.addAutoResourceType(base_dir, "skills", .skills, metadata, skill_overrides, &accumulator.skills);
        try self.addAutoResourceType(base_dir, "prompts", .prompts, metadata, prompt_overrides, &accumulator.prompts);
        try self.addAutoResourceType(base_dir, "themes", .themes, metadata, theme_overrides, &accumulator.themes);
    }

    fn addAutoResourceType(
        self: *DefaultPackageManager,
        base_dir: []const u8,
        child_dir: []const u8,
        resource_type: ResourceType,
        metadata: PathMetadata,
        overrides: []const []const u8,
        target: *std.ArrayList(ResolvedResource),
    ) !void {
        const dir = try std.fs.path.join(self.allocator, &.{ base_dir, child_dir });
        defer self.allocator.free(dir);
        var files: std.ArrayList([]u8) = .empty;
        defer freePathList(self.allocator, &files);
        const recursive = resource_type == .extensions or resource_type == .skills;
        try self.collectFilesFromPath(dir, resource_type, recursive, &files);
        for (files.items) |file_path| {
            const enabled = isEnabledByOverrides(file_path, overrides, base_dir);
            try target.append(self.allocator, try ResolvedResource.initAlloc(self.allocator, file_path, enabled, metadata));
        }
    }

    fn collectFilesFromPath(
        self: *DefaultPackageManager,
        path: []const u8,
        resource_type: ResourceType,
        recursive: bool,
        files: *std.ArrayList([]u8),
    ) !void {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = true }) catch return;
        if (stat.kind == .file) {
            if (matchesResourceFile(path, resource_type)) try files.append(self.allocator, try self.allocator.dupe(u8, path));
            return;
        }
        if (stat.kind != .directory) return;
        switch (resource_type) {
            .extensions => try self.collectExtensions(path, recursive, files),
            .skills => try self.collectSkills(path, recursive, true, path, files),
            .prompts => try self.collectNamedFiles(path, ".md", recursive, files),
            .themes => try self.collectNamedFiles(path, ".json", recursive, files),
        }
    }

    fn collectExtensions(
        self: *DefaultPackageManager,
        dir: []const u8,
        recursive: bool,
        files: *std.ArrayList([]u8),
    ) !void {
        if (try self.extensionEntriesForDir(dir)) |entries| {
            defer freeStringArray(self.allocator, entries);
            for (entries) |entry| try files.append(self.allocator, try self.allocator.dupe(u8, entry));
            return;
        }
        if (!recursive) return;
        var directory = openDirPath(self.io, dir, .{ .iterate = true }) catch return;
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.eql(u8, entry.name, "node_modules")) continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ dir, entry.name });
            defer self.allocator.free(full_path);
            const kind = entryKindFollowSymlink(self.io, directory, entry) orelse continue;
            if (kind == .file and matchesResourceFile(full_path, .extensions)) {
                try files.append(self.allocator, try self.allocator.dupe(u8, full_path));
            } else if (kind == .directory) {
                try self.collectExtensions(full_path, recursive, files);
            }
        }
    }

    fn extensionEntriesForDir(self: *DefaultPackageManager, dir: []const u8) !?[]const []const u8 {
        if (try self.manifestEntriesAlloc(dir, .extensions)) |entries| {
            if (entries.len > 0) return entries;
            freeStringArray(self.allocator, entries);
        }
        const index_zig = try std.fs.path.join(self.allocator, &.{ dir, "index.zig" });
        defer self.allocator.free(index_zig);
        if (statKind(self.io, index_zig) == .file) return @as(?[]const []const u8, try singleStringArrayAlloc(self.allocator, index_zig));
        const index_ts = try std.fs.path.join(self.allocator, &.{ dir, "index.ts" });
        defer self.allocator.free(index_ts);
        if (statKind(self.io, index_ts) == .file) return @as(?[]const []const u8, try singleStringArrayAlloc(self.allocator, index_ts));
        const index_js = try std.fs.path.join(self.allocator, &.{ dir, "index.js" });
        defer self.allocator.free(index_js);
        if (statKind(self.io, index_js) == .file) return @as(?[]const []const u8, try singleStringArrayAlloc(self.allocator, index_js));
        return null;
    }

    fn collectSkills(
        self: *DefaultPackageManager,
        dir: []const u8,
        recursive: bool,
        include_root_files: bool,
        root: []const u8,
        files: *std.ArrayList([]u8),
    ) !void {
        var directory = openDirPath(self.io, dir, .{ .iterate = true }) catch return;
        defer directory.close(self.io);
        var iterator = directory.iterate();
        var entries: std.ArrayList(std.Io.Dir.Entry) = .empty;
        defer entries.deinit(self.allocator);
        while (iterator.next(self.io) catch null) |entry| {
            try entries.append(self.allocator, entry);
            if (std.mem.eql(u8, entry.name, "SKILL.md")) {
                const kind = entryKindFollowSymlink(self.io, directory, entry) orelse continue;
                if (kind == .file) {
                    const skill_path = try std.fs.path.join(self.allocator, &.{ dir, entry.name });
                    try files.append(self.allocator, skill_path);
                    return;
                }
            }
        }

        for (entries.items) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.eql(u8, entry.name, "node_modules")) continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ dir, entry.name });
            defer self.allocator.free(full_path);
            const kind = entryKindFollowSymlink(self.io, directory, entry) orelse continue;
            if (kind == .file and include_root_files and std.mem.eql(u8, dir, root) and std.mem.endsWith(u8, entry.name, ".md")) {
                try files.append(self.allocator, try self.allocator.dupe(u8, full_path));
            } else if (kind == .directory and recursive) {
                try self.collectSkills(full_path, recursive, false, root, files);
            }
        }
    }

    fn collectNamedFiles(
        self: *DefaultPackageManager,
        dir: []const u8,
        suffix: []const u8,
        recursive: bool,
        files: *std.ArrayList([]u8),
    ) !void {
        var directory = openDirPath(self.io, dir, .{ .iterate = true }) catch return;
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.' or std.mem.eql(u8, entry.name, "node_modules")) continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ dir, entry.name });
            defer self.allocator.free(full_path);
            const kind = entryKindFollowSymlink(self.io, directory, entry) orelse continue;
            if (kind == .file and std.mem.endsWith(u8, entry.name, suffix)) {
                try files.append(self.allocator, try self.allocator.dupe(u8, full_path));
            } else if (kind == .directory and recursive) {
                try self.collectNamedFiles(full_path, suffix, recursive, files);
            }
        }
    }

    fn baseDirForScopeAlloc(self: *DefaultPackageManager, scope: SourceScope) ![]u8 {
        return switch (scope) {
            .project => std.fs.path.join(self.allocator, &.{ self.cwd, config.project_config_dir }),
            .user => self.allocator.dupe(u8, self.agent_dir),
            .temporary => self.allocator.dupe(u8, self.cwd),
        };
    }
};

const ResourceAccumulator = struct {
    allocator: std.mem.Allocator,
    extensions: std.ArrayList(ResolvedResource) = .empty,
    skills: std.ArrayList(ResolvedResource) = .empty,
    prompts: std.ArrayList(ResolvedResource) = .empty,
    themes: std.ArrayList(ResolvedResource) = .empty,

    fn init(allocator: std.mem.Allocator) ResourceAccumulator {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ResourceAccumulator) void {
        deinitResolvedResourceList(self.allocator, &self.extensions);
        deinitResolvedResourceList(self.allocator, &self.skills);
        deinitResolvedResourceList(self.allocator, &self.prompts);
        deinitResolvedResourceList(self.allocator, &self.themes);
    }

    fn target(self: *ResourceAccumulator, resource_type: ResourceType) *std.ArrayList(ResolvedResource) {
        return switch (resource_type) {
            .extensions => &self.extensions,
            .skills => &self.skills,
            .prompts => &self.prompts,
            .themes => &self.themes,
        };
    }

    fn add(
        self: *ResourceAccumulator,
        resource_type: ResourceType,
        path: []const u8,
        enabled: bool,
        metadata: PathMetadata,
    ) !void {
        try self.target(resource_type).append(self.allocator, try ResolvedResource.initAlloc(self.allocator, path, enabled, metadata));
    }

    fn toResolvedPaths(self: *ResourceAccumulator, io: std.Io) !ResolvedPaths {
        return .{
            .allocator = self.allocator,
            .extensions = try dedupeResolvedList(self.allocator, io, &self.extensions),
            .skills = try dedupeResolvedList(self.allocator, io, &self.skills),
            .prompts = try dedupeResolvedList(self.allocator, io, &self.prompts),
            .themes = try dedupeResolvedList(self.allocator, io, &self.themes),
        };
    }
};

fn dedupeResolvedList(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayList(ResolvedResource),
) ![]ResolvedResource {
    var output: std.ArrayList(ResolvedResource) = .empty;
    errdefer deinitResolvedResourceList(allocator, &output);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer deinitStringSet(allocator, &seen);

    for (list.items) |resource| {
        var moved = resource;
        const canonical = try paths.canonicalizePathAlloc(allocator, io, moved.path);
        errdefer allocator.free(canonical);
        if (seen.contains(canonical)) {
            allocator.free(canonical);
            moved.deinit();
            continue;
        }
        try seen.put(allocator, canonical, {});
        try output.append(allocator, moved);
    }
    list.clearRetainingCapacity();
    return output.toOwnedSlice(allocator);
}

fn packageSourceString(package: PackageSource) []const u8 {
    return switch (package) {
        .string => |value| value,
        .object => |object| object.source,
    };
}

fn resourceTypeName(resource_type: ResourceType) []const u8 {
    return switch (resource_type) {
        .extensions => "extensions",
        .skills => "skills",
        .prompts => "prompts",
        .themes => "themes",
    };
}

fn matchesResourceFile(path: []const u8, resource_type: ResourceType) bool {
    return switch (resource_type) {
        .extensions => std.mem.endsWith(u8, path, ".zig") or
            std.mem.endsWith(u8, path, ".ts") or
            std.mem.endsWith(u8, path, ".js") or
            std.mem.endsWith(u8, path, ".so") or
            std.mem.endsWith(u8, path, ".dylib") or
            std.mem.endsWith(u8, path, ".dll"),
        .skills => std.mem.endsWith(u8, path, ".md"),
        .prompts => std.mem.endsWith(u8, path, ".md"),
        .themes => std.mem.endsWith(u8, path, ".json"),
    };
}

fn isPattern(value: []const u8) bool {
    return isOverridePattern(value) or hasGlobPattern(value);
}

fn isOverridePattern(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "!") or
        std.mem.startsWith(u8, value, "+") or
        std.mem.startsWith(u8, value, "-");
}

fn hasGlobPattern(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "*?") != null;
}

fn applyPatterns(file_path: []const u8, patterns: []const []const u8, base_dir: []const u8) bool {
    var has_includes = false;
    var enabled = true;
    for (patterns) |pattern| {
        if (!isOverridePattern(pattern)) {
            has_includes = true;
            break;
        }
    }
    if (has_includes) {
        enabled = false;
        for (patterns) |pattern| {
            if (isOverridePattern(pattern)) continue;
            if (matchesPattern(file_path, pattern, base_dir)) {
                enabled = true;
                break;
            }
        }
    }
    for (patterns) |pattern| {
        if (pattern.len < 2) continue;
        if (pattern[0] == '!' and matchesPattern(file_path, pattern[1..], base_dir)) enabled = false;
    }
    for (patterns) |pattern| {
        if (pattern.len < 2) continue;
        if (pattern[0] == '+' and matchesPattern(file_path, pattern[1..], base_dir)) enabled = true;
    }
    for (patterns) |pattern| {
        if (pattern.len < 2) continue;
        if (pattern[0] == '-' and matchesPattern(file_path, pattern[1..], base_dir)) enabled = false;
    }
    return enabled;
}

fn isEnabledByOverrides(file_path: []const u8, overrides: []const []const u8, base_dir: []const u8) bool {
    if (overrides.len == 0) return true;
    var enabled = true;
    for (overrides) |pattern| {
        if (pattern.len < 2) continue;
        if (pattern[0] == '!' and matchesPattern(file_path, pattern[1..], base_dir)) enabled = false;
    }
    for (overrides) |pattern| {
        if (pattern.len < 2) continue;
        if (pattern[0] == '+' and matchesPattern(file_path, pattern[1..], base_dir)) enabled = true;
    }
    for (overrides) |pattern| {
        if (pattern.len < 2) continue;
        if (pattern[0] == '-' and matchesPattern(file_path, pattern[1..], base_dir)) enabled = false;
    }
    return enabled;
}

fn matchesPattern(file_path: []const u8, pattern: []const u8, base_dir: []const u8) bool {
    var rel_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const rel = relativeToBaseBuf(file_path, base_dir, &rel_buffer);
    var rel_posix_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const rel_posix = toPosixBuf(rel, &rel_posix_buffer);
    var path_posix_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_posix = toPosixBuf(file_path, &path_posix_buffer);
    var pattern_posix_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var pattern_posix = toPosixBuf(pattern, &pattern_posix_buffer);
    if (std.mem.startsWith(u8, pattern_posix, "./")) pattern_posix = pattern_posix[2..];

    if (matchCandidate(rel_posix, pattern_posix) or
        matchCandidate(path_posix, pattern_posix) or
        matchCandidate(std.fs.path.basename(file_path), pattern_posix))
    {
        return true;
    }

    if (std.mem.eql(u8, std.fs.path.basename(file_path), "SKILL.md")) {
        if (std.fs.path.dirname(file_path)) |parent| {
            var parent_rel_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const parent_rel = relativeToBaseBuf(parent, base_dir, &parent_rel_buffer);
            var parent_rel_posix_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const parent_rel_posix = toPosixBuf(parent_rel, &parent_rel_posix_buffer);
            var parent_posix_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const parent_posix = toPosixBuf(parent, &parent_posix_buffer);
            return matchCandidate(parent_rel_posix, pattern_posix) or
                matchCandidate(parent_posix, pattern_posix) or
                matchCandidate(std.fs.path.basename(parent), pattern_posix);
        }
    }
    return false;
}

fn matchCandidate(candidate: []const u8, pattern: []const u8) bool {
    if (hasGlobPattern(pattern)) return wildcardMatch(candidate, pattern);
    return std.mem.eql(u8, candidate, pattern);
}

fn relativeToBaseBuf(path: []const u8, base_dir: []const u8, buffer: []u8) []const u8 {
    if (std.mem.eql(u8, path, base_dir)) return "";
    if (std.mem.startsWith(u8, path, base_dir) and
        path.len > base_dir.len and
        (path[base_dir.len] == std.fs.path.sep or path[base_dir.len] == '/'))
    {
        const relative = path[base_dir.len + 1 ..];
        const len = @min(relative.len, buffer.len);
        @memcpy(buffer[0..len], relative[0..len]);
        return buffer[0..len];
    }
    return path;
}

fn wildcardMatch(candidate: []const u8, pattern: []const u8) bool {
    var c: usize = 0;
    var p: usize = 0;
    var star: ?usize = null;
    var match_index: usize = 0;
    while (c < candidate.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == candidate[c])) {
            c += 1;
            p += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            match_index = c;
            p += 1;
        } else if (star) |star_index| {
            p = star_index + 1;
            match_index += 1;
            c = match_index;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn toPosixBuf(path: []const u8, buffer: []u8) []const u8 {
    const len = @min(path.len, buffer.len);
    for (path[0..len], 0..) |byte, index| {
        buffer[index] = if (byte == std.fs.path.sep) '/' else byte;
    }
    return buffer[0..len];
}

fn stringArrayFromJsonAlloc(allocator: std.mem.Allocator, value: std.json.Value) !?[]const []const u8 {
    if (value != .array) return null;
    var strings: std.ArrayList([]const u8) = .empty;
    errdefer freeStringArray(allocator, strings.items);
    for (value.array.items) |item| {
        if (item != .string) continue;
        try strings.append(allocator, try allocator.dupe(u8, item.string));
    }
    return @as(?[]const []const u8, try strings.toOwnedSlice(allocator));
}

fn singleStringArrayAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    const array = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(array);
    array[0] = try allocator.dupe(u8, value);
    return array;
}

fn statKind(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return null;
    return stat.kind;
}

fn entryKindFollowSymlink(io: std.Io, directory: std.Io.Dir, entry: std.Io.Dir.Entry) ?std.Io.File.Kind {
    return switch (entry.kind) {
        .file, .directory => entry.kind,
        .sym_link, .unknown => blk: {
            const stat = directory.statFile(io, entry.name, .{ .follow_symlinks = true }) catch break :blk null;
            break :blk stat.kind;
        },
        else => null,
    };
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn deinitResolvedResources(allocator: std.mem.Allocator, resources: []ResolvedResource) void {
    for (resources) |*resource| resource.deinit();
    allocator.free(resources);
}

fn deinitResolvedResourceList(allocator: std.mem.Allocator, list: *std.ArrayList(ResolvedResource)) void {
    for (list.items) |*resource| resource.deinit();
    list.deinit(allocator);
}

fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(@constCast(value));
    allocator.free(values);
}

fn freePathList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |path| allocator.free(path);
    list.deinit(allocator);
}

fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var it = set.keyIterator();
    while (it.next()) |key| allocator.free(@constCast(key.*));
    set.deinit(allocator);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = data,
        .flags = .{ .read = true, .truncate = true },
    });
}

test "DefaultPackageManager resolves Bulb local resources with project precedence and overrides" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const cwd = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(cwd);
    try std.Io.Dir.cwd().createDirPath(io, agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, cwd);

    const user_prompt = try std.fs.path.join(allocator, &.{ agent_dir, "prompts", "commit.md" });
    defer allocator.free(user_prompt);
    const project_prompt = try std.fs.path.join(allocator, &.{ cwd, ".bulb", "prompts", "commit.md" });
    defer allocator.free(project_prompt);
    try writeFile(user_prompt, "User prompt");
    try writeFile(project_prompt, "Project prompt");

    const disabled_skill = try std.fs.path.join(allocator, &.{ agent_dir, "skills", "skip-skill", "SKILL.md" });
    defer allocator.free(disabled_skill);
    try writeFile(disabled_skill, "---\nname: skip-skill\ndescription: Skip me\n---\nSkip");

    var manager = try settings_manager.SettingsManager.create(allocator, io, cwd, agent_dir);
    defer manager.deinit();
    try manager.setSkillPaths(&.{"-skills/skip-skill"});

    var package_manager = try DefaultPackageManager.initAlloc(allocator, io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .settings_manager = &manager,
    });
    defer package_manager.deinit();

    var resolved = try package_manager.resolve();
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 2), resolved.prompts.len);
    try std.testing.expectEqualStrings(project_prompt, resolved.prompts[0].path);
    try std.testing.expectEqual(source_info.SourceScope.project, resolved.prompts[0].metadata.scope);
    try std.testing.expectEqual(false, resolved.skills[0].enabled);
}
