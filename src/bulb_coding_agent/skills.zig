const std = @import("std");
const config = @import("config.zig");
const frontmatter = @import("frontmatter.zig");
const paths = @import("paths.zig");
const source_info = @import("source_info.zig");

pub const SourceInfo = source_info.SourceInfo;

const max_name_length = 64;
const max_description_length = 1024;
const ignore_file_names = [_][]const u8{ ".gitignore", ".ignore", ".fdignore" };

pub const DiagnosticType = enum {
    warning,
    collision,
};

pub const ResourceCollision = struct {
    resource_type: []u8,
    name: []u8,
    winner_path: []u8,
    loser_path: []u8,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        resource_type: []const u8,
        name: []const u8,
        winner_path: []const u8,
        loser_path: []const u8,
    ) !ResourceCollision {
        const owned_resource_type = try allocator.dupe(u8, resource_type);
        errdefer allocator.free(owned_resource_type);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_winner_path = try allocator.dupe(u8, winner_path);
        errdefer allocator.free(owned_winner_path);
        const owned_loser_path = try allocator.dupe(u8, loser_path);
        errdefer allocator.free(owned_loser_path);
        return .{
            .resource_type = owned_resource_type,
            .name = owned_name,
            .winner_path = owned_winner_path,
            .loser_path = owned_loser_path,
        };
    }

    fn deinit(self: *ResourceCollision, allocator: std.mem.Allocator) void {
        allocator.free(self.resource_type);
        allocator.free(self.name);
        allocator.free(self.winner_path);
        allocator.free(self.loser_path);
        self.* = undefined;
    }
};

pub const ResourceDiagnostic = struct {
    allocator: std.mem.Allocator,
    type: DiagnosticType,
    message: []u8,
    path: []u8,
    collision: ?ResourceCollision = null,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        diagnostic_type: DiagnosticType,
        message: []const u8,
        path: []const u8,
        collision: ?ResourceCollision,
    ) !ResourceDiagnostic {
        const owned_message = try allocator.dupe(u8, message);
        errdefer allocator.free(owned_message);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        return .{
            .allocator = allocator,
            .type = diagnostic_type,
            .message = owned_message,
            .path = owned_path,
            .collision = collision,
        };
    }

    pub fn deinit(self: *ResourceDiagnostic) void {
        self.allocator.free(self.message);
        self.allocator.free(self.path);
        if (self.collision) |*collision| collision.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Skill = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    description: []u8,
    file_path: []u8,
    base_dir: []u8,
    source_info: SourceInfo,
    disable_model_invocation: bool,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        name: []const u8,
        description: []const u8,
        file_path: []const u8,
        base_dir: []const u8,
        info: SourceInfo,
        disable_model_invocation: bool,
    ) !Skill {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_description = try allocator.dupe(u8, description);
        errdefer allocator.free(owned_description);
        const owned_file_path = try allocator.dupe(u8, file_path);
        errdefer allocator.free(owned_file_path);
        const owned_base_dir = try allocator.dupe(u8, base_dir);
        errdefer allocator.free(owned_base_dir);
        const owned_source_path = try allocator.dupe(u8, info.path);
        errdefer allocator.free(owned_source_path);
        const owned_source = try allocator.dupe(u8, info.source);
        errdefer allocator.free(owned_source);
        const owned_source_base_dir = if (info.base_dir) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_source_base_dir) |value| allocator.free(value);

        return .{
            .allocator = allocator,
            .name = owned_name,
            .description = owned_description,
            .file_path = owned_file_path,
            .base_dir = owned_base_dir,
            .source_info = .{
                .path = owned_source_path,
                .source = owned_source,
                .scope = info.scope,
                .origin = info.origin,
                .base_dir = owned_source_base_dir,
            },
            .disable_model_invocation = disable_model_invocation,
        };
    }

    pub fn deinit(self: *Skill) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.file_path);
        self.allocator.free(self.base_dir);
        self.allocator.free(@constCast(self.source_info.path));
        self.allocator.free(@constCast(self.source_info.source));
        if (self.source_info.base_dir) |value| self.allocator.free(@constCast(value));
        self.* = undefined;
    }
};

pub const LoadSkillsResult = struct {
    allocator: std.mem.Allocator,
    skills: []Skill,
    diagnostics: []ResourceDiagnostic,

    pub fn deinit(self: *LoadSkillsResult) void {
        for (self.skills) |*skill| skill.deinit();
        self.allocator.free(self.skills);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit();
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const LoadSkillsFromDirOptions = struct {
    dir: []const u8,
    source: []const u8,
};

pub const LoadSkillsOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8 = "",
    skill_paths: []const []const u8 = &.{},
    include_defaults: bool = true,
    env: ?*const std.process.Environ.Map = null,
};

pub fn loadSkillsFromDirAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadSkillsFromDirOptions,
) !LoadSkillsResult {
    var skills: std.ArrayList(Skill) = .empty;
    errdefer deinitSkillList(allocator, &skills);
    var diagnostics: std.ArrayList(ResourceDiagnostic) = .empty;
    errdefer deinitDiagnosticList(allocator, &diagnostics);

    var ignore_matcher = IgnoreMatcher.init(allocator);
    defer ignore_matcher.deinit();
    try loadSkillsFromDirInternal(
        allocator,
        io,
        options.dir,
        options.source,
        true,
        options.dir,
        &ignore_matcher,
        &skills,
        &diagnostics,
    );

    return .{
        .allocator = allocator,
        .skills = try skills.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn loadSkillsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadSkillsOptions,
) !LoadSkillsResult {
    const resolved_cwd = try paths.resolvePathAlloc(allocator, options.cwd, ".", .{ .env = options.env });
    defer allocator.free(resolved_cwd);
    const resolved_agent_dir = if (options.agent_dir.len > 0)
        try paths.resolvePathAlloc(allocator, options.agent_dir, ".", .{ .env = options.env })
    else if (options.env) |env|
        try config.agentDirAlloc(allocator, env)
    else
        try paths.resolvePathAlloc(allocator, ".bulb/agent", ".", .{});
    defer allocator.free(resolved_agent_dir);

    const user_skills_dir = try std.fs.path.join(allocator, &.{ resolved_agent_dir, "skills" });
    defer allocator.free(user_skills_dir);
    const project_skills_dir = try std.fs.path.resolve(allocator, &.{ resolved_cwd, config.project_config_dir, "skills" });
    defer allocator.free(project_skills_dir);

    var skills: std.ArrayList(Skill) = .empty;
    errdefer deinitSkillList(allocator, &skills);
    var diagnostics: std.ArrayList(ResourceDiagnostic) = .empty;
    errdefer deinitDiagnosticList(allocator, &diagnostics);
    var skill_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer skill_map.deinit(allocator);
    var real_path_set: std.StringHashMapUnmanaged(void) = .empty;
    defer deinitStringSet(allocator, &real_path_set);

    if (options.include_defaults) {
        var user = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = user_skills_dir, .source = "user" });
        try addSkillsFromResult(allocator, io, &user, &skills, &diagnostics, &skill_map, &real_path_set);
        var project = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = project_skills_dir, .source = "project" });
        try addSkillsFromResult(allocator, io, &project, &skills, &diagnostics, &skill_map, &real_path_set);
    }

    for (options.skill_paths) |raw_path| {
        const resolved_path = paths.resolvePathAlloc(allocator, raw_path, resolved_cwd, .{
            .trim = true,
            .env = options.env,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(resolved_path);

        const stat = std.Io.Dir.cwd().statFile(io, resolved_path, .{ .follow_symlinks = true }) catch {
            try appendDiagnosticFmt(
                allocator,
                &diagnostics,
                .warning,
                resolved_path,
                "skill path does not exist",
                .{},
            );
            continue;
        };

        const source = skillSourceForPath(resolved_path, user_skills_dir, project_skills_dir, options.include_defaults);
        if (stat.kind == .directory) {
            var result = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = resolved_path, .source = source });
            try addSkillsFromResult(allocator, io, &result, &skills, &diagnostics, &skill_map, &real_path_set);
        } else if (stat.kind == .file and std.mem.endsWith(u8, resolved_path, ".md")) {
            var single_skills: std.ArrayList(Skill) = .empty;
            errdefer deinitSkillList(allocator, &single_skills);
            var single_diagnostics: std.ArrayList(ResourceDiagnostic) = .empty;
            errdefer deinitDiagnosticList(allocator, &single_diagnostics);
            try appendSkillFromFile(allocator, io, resolved_path, source, &single_skills, &single_diagnostics);
            var one_result = LoadSkillsResult{
                .allocator = allocator,
                .skills = try single_skills.toOwnedSlice(allocator),
                .diagnostics = try single_diagnostics.toOwnedSlice(allocator),
            };
            errdefer one_result.deinit();
            try addSkillsFromResult(allocator, io, &one_result, &skills, &diagnostics, &skill_map, &real_path_set);
        } else {
            try appendDiagnosticFmt(
                allocator,
                &diagnostics,
                .warning,
                resolved_path,
                "skill path is not a markdown file",
                .{},
            );
        }
    }

    return .{
        .allocator = allocator,
        .skills = try skills.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn deinitSkills(allocator: std.mem.Allocator, skills: []Skill) void {
    for (skills) |*skill| skill.deinit();
    allocator.free(skills);
}

pub fn deinitDiagnostics(allocator: std.mem.Allocator, diagnostics: []ResourceDiagnostic) void {
    for (diagnostics) |*diagnostic| diagnostic.deinit();
    allocator.free(diagnostics);
}

pub fn formatSkillsForPromptAlloc(allocator: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var visible_count: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible_count += 1;
    }
    if (visible_count == 0) return allocator.dupe(u8, "");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(
        allocator,
        "\n\nThe following skills provide specialized instructions for specific tasks.\n" ++
            "Use the read tool to load a skill's file when the task matches its description.\n" ++
            "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n" ++
            "<available_skills>",
    );
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try output.appendSlice(allocator, "\n  <skill>\n    <name>");
        try appendEscapedXml(&output, allocator, skill.name);
        try output.appendSlice(allocator, "</name>\n    <description>");
        try appendEscapedXml(&output, allocator, skill.description);
        try output.appendSlice(allocator, "</description>\n    <location>");
        try appendEscapedXml(&output, allocator, skill.file_path);
        try output.appendSlice(allocator, "</location>\n  </skill>");
    }
    try output.appendSlice(allocator, "\n</available_skills>");
    return output.toOwnedSlice(allocator);
}

fn loadSkillsFromDirInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    source: []const u8,
    include_root_files: bool,
    root_dir: []const u8,
    ignore_matcher: *IgnoreMatcher,
    skills: *std.ArrayList(Skill),
    diagnostics: *std.ArrayList(ResourceDiagnostic),
) !void {
    var directory = openDirPath(io, dir, .{ .iterate = true }) catch return;
    defer directory.close(io);
    try ignore_matcher.addRulesFromDir(io, dir, root_dir);

    var iterator = directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (!std.mem.eql(u8, entry.name, "SKILL.md")) continue;
        if (!try entryIsFile(allocator, io, dir, &directory, entry)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir, entry.name });
        defer allocator.free(full_path);
        if (try ignore_matcher.ignoresPathAlloc(full_path, root_dir)) continue;

        try appendSkillFromFile(allocator, io, full_path, source, skills, diagnostics);
        return;
    }

    var directory_second_pass = openDirPath(io, dir, .{ .iterate = true }) catch return;
    defer directory_second_pass.close(io);
    var second_iterator = directory_second_pass.iterate();
    while (second_iterator.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir, entry.name });
        defer allocator.free(full_path);

        const stat = entryStat(allocator, io, dir, &directory_second_pass, entry) orelse continue;
        const ignored = if (stat.kind == .directory)
            try ignore_matcher.ignoresDirectoryAlloc(full_path, root_dir)
        else
            try ignore_matcher.ignoresPathAlloc(full_path, root_dir);
        if (ignored) continue;

        if (stat.kind == .directory) {
            try loadSkillsFromDirInternal(
                allocator,
                io,
                full_path,
                source,
                false,
                root_dir,
                ignore_matcher,
                skills,
                diagnostics,
            );
        } else if (include_root_files and stat.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            try appendSkillFromFile(allocator, io, full_path, source, skills, diagnostics);
        }
    }
}

fn appendSkillFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    source: []const u8,
    skills: *std.ArrayList(Skill),
    diagnostics: *std.ArrayList(ResourceDiagnostic),
) !void {
    const raw_content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try appendDiagnosticFmt(
                allocator,
                diagnostics,
                .warning,
                file_path,
                "failed to read skill file",
                .{},
            );
            return;
        },
    };
    defer allocator.free(raw_content);

    var parse_diagnostic: frontmatter.ParseDiagnostic = .{};
    var parsed = frontmatter.parseFrontmatterAllocWithDiagnostic(allocator, raw_content, &parse_diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidYaml => {
            try appendDiagnosticFmt(
                allocator,
                diagnostics,
                .warning,
                file_path,
                "invalid YAML at line {d}, column {d}",
                .{ parse_diagnostic.line, parse_diagnostic.column },
            );
            return;
        },
    };
    defer parsed.deinit();

    const skill_dir = std.fs.path.dirname(file_path) orelse ".";
    const parent_dir_name = std.fs.path.basename(skill_dir);
    const name = parsed.getString("name") orelse parent_dir_name;
    const description = parsed.getString("description");

    if (validateDescription(description)) |message| {
        try appendDiagnosticFmt(allocator, diagnostics, .warning, file_path, "{s}", .{message});
    }
    const name_validation = validateName(name);
    for (name_validation.messages[0..name_validation.len]) |message| {
        try appendDiagnosticFmt(allocator, diagnostics, .warning, file_path, "{s}", .{message});
    }

    const actual_description = description orelse return;
    if (std.mem.trim(u8, actual_description, " \t\r\n").len == 0) return;

    const info = createSkillSourceInfo(file_path, skill_dir, source);
    const skill = try Skill.initAlloc(
        allocator,
        name,
        actual_description,
        file_path,
        skill_dir,
        info,
        parsed.getBool("disable-model-invocation") orelse false,
    );
    try skills.append(allocator, skill);
}

const NameValidation = struct {
    messages: [4][]const u8 = undefined,
    len: usize = 0,
};

fn validateName(name: []const u8) NameValidation {
    var result: NameValidation = .{};

    if (utf16Length(name) > max_name_length) {
        result.messages[result.len] = "name exceeds 64 characters";
        result.len += 1;
    }
    if (!nameCharsAreValid(name)) {
        result.messages[result.len] = "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)";
        result.len += 1;
    }
    if (std.mem.startsWith(u8, name, "-") or std.mem.endsWith(u8, name, "-")) {
        result.messages[result.len] = "name must not start or end with a hyphen";
        result.len += 1;
    }
    if (std.mem.indexOf(u8, name, "--") != null) {
        result.messages[result.len] = "name must not contain consecutive hyphens";
        result.len += 1;
    }

    return result;
}

fn validateDescription(description: ?[]const u8) ?[]const u8 {
    const value = description orelse return "description is required";
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return "description is required";
    if (utf16Length(value) > max_description_length) return "description exceeds 1024 characters";
    return null;
}

fn nameCharsAreValid(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (byte >= 'a' and byte <= 'z') continue;
        if (byte >= '0' and byte <= '9') continue;
        if (byte == '-') continue;
        return false;
    }
    return true;
}

fn utf16Length(input: []const u8) usize {
    var index: usize = 0;
    var units: usize = 0;
    while (index < input.len) {
        const width = std.unicode.utf8ByteSequenceLength(input[index]) catch 1;
        if (index + width > input.len) {
            units += 1;
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(input[index .. index + width]) catch {
            units += 1;
            index += width;
            continue;
        };
        units += if (codepoint > 0xFFFF) 2 else 1;
        index += width;
    }
    return units;
}

fn createSkillSourceInfo(file_path: []const u8, base_dir: []const u8, source: []const u8) SourceInfo {
    if (std.mem.eql(u8, source, "user")) {
        return source_info.createSyntheticSourceInfo(file_path, .{
            .source = "local",
            .scope = .user,
            .base_dir = base_dir,
        });
    }
    if (std.mem.eql(u8, source, "project")) {
        return source_info.createSyntheticSourceInfo(file_path, .{
            .source = "local",
            .scope = .project,
            .base_dir = base_dir,
        });
    }
    if (std.mem.eql(u8, source, "path")) {
        return source_info.createSyntheticSourceInfo(file_path, .{
            .source = "local",
            .base_dir = base_dir,
        });
    }
    return source_info.createSyntheticSourceInfo(file_path, .{
        .source = source,
        .base_dir = base_dir,
    });
}

fn skillSourceForPath(
    resolved_path: []const u8,
    user_skills_dir: []const u8,
    project_skills_dir: []const u8,
    include_defaults: bool,
) []const u8 {
    if (!include_defaults) {
        if (isUnderPath(resolved_path, user_skills_dir)) return "user";
        if (isUnderPath(resolved_path, project_skills_dir)) return "project";
    }
    return "path";
}

fn addSkillsFromResult(
    allocator: std.mem.Allocator,
    io: std.Io,
    result: *LoadSkillsResult,
    skills: *std.ArrayList(Skill),
    diagnostics: *std.ArrayList(ResourceDiagnostic),
    skill_map: *std.StringHashMapUnmanaged(usize),
    real_path_set: *std.StringHashMapUnmanaged(void),
) !void {
    for (result.diagnostics) |diagnostic| {
        try diagnostics.append(allocator, diagnostic);
    }
    allocator.free(result.diagnostics);
    result.diagnostics = &.{};

    for (result.skills) |skill| {
        var moved_skill = skill;
        const canonical = try paths.canonicalizePathAlloc(allocator, io, moved_skill.file_path);
        errdefer allocator.free(canonical);
        if (real_path_set.contains(canonical)) {
            allocator.free(canonical);
            moved_skill.deinit();
            continue;
        }

        if (skill_map.get(moved_skill.name)) |winner_index| {
            allocator.free(canonical);
            const winner = skills.items[winner_index];
            var collision = try ResourceCollision.initAlloc(
                allocator,
                "skill",
                moved_skill.name,
                winner.file_path,
                moved_skill.file_path,
            );
            var collision_owned = true;
            errdefer if (collision_owned) collision.deinit(allocator);
            const message = try std.fmt.allocPrint(allocator, "name \"{s}\" collision", .{moved_skill.name});
            defer allocator.free(message);
            var diagnostic = try ResourceDiagnostic.initAlloc(
                allocator,
                .collision,
                message,
                moved_skill.file_path,
                collision,
            );
            collision_owned = false;
            var diagnostic_owned = true;
            errdefer if (diagnostic_owned) diagnostic.deinit();
            try diagnostics.append(allocator, diagnostic);
            diagnostic_owned = false;
            moved_skill.deinit();
            continue;
        }

        try real_path_set.put(allocator, canonical, {});
        try skill_map.put(allocator, moved_skill.name, skills.items.len);
        try skills.append(allocator, moved_skill);
    }
    allocator.free(result.skills);
    result.skills = &.{};
}

fn appendDiagnosticFmt(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(ResourceDiagnostic),
    diagnostic_type: DiagnosticType,
    path: []const u8,
    comptime format: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(message);
    try diagnostics.append(allocator, try ResourceDiagnostic.initAlloc(
        allocator,
        diagnostic_type,
        message,
        path,
        null,
    ));
}

fn appendEscapedXml(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |byte| {
        switch (byte) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&apos;"),
            else => try output.append(allocator, byte),
        }
    }
}

const IgnoreMatcher = struct {
    allocator: std.mem.Allocator,
    rules: std.ArrayList(IgnoreRule) = .empty,

    fn init(allocator: std.mem.Allocator) IgnoreMatcher {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *IgnoreMatcher) void {
        for (self.rules.items) |*rule| rule.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        self.* = undefined;
    }

    fn addRulesFromDir(self: *IgnoreMatcher, io: std.Io, dir: []const u8, root_dir: []const u8) !void {
        const relative_dir = try relativePathAlloc(self.allocator, dir, root_dir);
        defer self.allocator.free(relative_dir);
        const posix_relative_dir = try toPosixPathAlloc(self.allocator, relative_dir);
        defer self.allocator.free(posix_relative_dir);
        const prefix = if (posix_relative_dir.len == 0)
            try self.allocator.dupe(u8, "")
        else
            try std.mem.concat(self.allocator, u8, &.{ posix_relative_dir, "/" });
        defer self.allocator.free(prefix);

        for (ignore_file_names) |name| {
            const ignore_path = try std.fs.path.join(self.allocator, &.{ dir, name });
            defer self.allocator.free(ignore_path);
            const content = std.Io.Dir.cwd().readFileAlloc(io, ignore_path, self.allocator, .limited(1024 * 1024)) catch continue;
            defer self.allocator.free(content);

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const normalized_line = if (std.mem.endsWith(u8, line, "\r"))
                    line[0 .. line.len - 1]
                else
                    line;
                const pattern = (try prefixIgnorePatternAlloc(self.allocator, normalized_line, prefix)) orelse continue;
                errdefer self.allocator.free(pattern.pattern);
                try self.rules.append(self.allocator, pattern);
            }
        }
    }

    fn ignoresPathAlloc(self: *IgnoreMatcher, target_path: []const u8, root_dir: []const u8) !bool {
        const relative = try relativePathAlloc(self.allocator, target_path, root_dir);
        defer self.allocator.free(relative);
        const posix = try toPosixPathAlloc(self.allocator, relative);
        defer self.allocator.free(posix);
        return self.ignores(posix);
    }

    fn ignoresDirectoryAlloc(self: *IgnoreMatcher, target_path: []const u8, root_dir: []const u8) !bool {
        const relative = try relativePathAlloc(self.allocator, target_path, root_dir);
        defer self.allocator.free(relative);
        const posix = try toPosixPathAlloc(self.allocator, relative);
        defer self.allocator.free(posix);
        const with_slash = try std.mem.concat(self.allocator, u8, &.{ posix, "/" });
        defer self.allocator.free(with_slash);
        return self.ignores(with_slash) or self.ignores(posix);
    }

    fn ignores(self: *const IgnoreMatcher, relative_path: []const u8) bool {
        var ignored = false;
        for (self.rules.items) |rule| {
            if (rule.matches(relative_path)) {
                ignored = !rule.negated;
            }
        }
        return ignored;
    }
};

const IgnoreRule = struct {
    pattern: []u8,
    negated: bool,

    fn deinit(self: *IgnoreRule, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        self.* = undefined;
    }

    fn matches(self: IgnoreRule, relative_path: []const u8) bool {
        const pattern = self.pattern;
        if (pattern.len == 0) return false;
        if (std.mem.endsWith(u8, pattern, "/")) {
            return std.mem.startsWith(u8, relative_path, pattern) or
                pathContainsSegment(relative_path, pattern[0 .. pattern.len - 1]);
        }
        if (std.mem.indexOfScalar(u8, pattern, '/') != null) {
            return globMatch(pattern, relative_path);
        }
        return basenameOrSegmentGlobMatch(pattern, relative_path);
    }
};

fn prefixIgnorePatternAlloc(allocator: std.mem.Allocator, line: []const u8, prefix: []const u8) !?IgnoreRule {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "#") and !std.mem.startsWith(u8, trimmed, "\\#")) return null;

    var pattern = line;
    var negated = false;
    if (std.mem.startsWith(u8, pattern, "!")) {
        negated = true;
        pattern = pattern[1..];
    } else if (std.mem.startsWith(u8, pattern, "\\!")) {
        pattern = pattern[1..];
    }
    if (std.mem.startsWith(u8, pattern, "/")) pattern = pattern[1..];
    const trimmed_pattern = std.mem.trim(u8, pattern, " \t\r\n");
    if (trimmed_pattern.len == 0) return null;
    const owned_pattern = try std.mem.concat(allocator, u8, &.{ prefix, trimmed_pattern });
    return .{ .pattern = owned_pattern, .negated = negated };
}

fn basenameOrSegmentGlobMatch(pattern: []const u8, relative_path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, relative_path, '/');
    while (segments.next()) |segment| {
        if (globMatch(pattern, segment)) return true;
    }
    return false;
}

fn pathContainsSegment(relative_path: []const u8, segment: []const u8) bool {
    var segments = std.mem.splitScalar(u8, relative_path, '/');
    while (segments.next()) |part| {
        if (std.mem.eql(u8, part, segment)) return true;
    }
    return false;
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_index: ?usize = null;
    var match_index: usize = 0;

    while (text_index < text.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or pattern[pattern_index] == text[text_index]))
        {
            pattern_index += 1;
            text_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            match_index = text_index;
            pattern_index += 1;
        } else if (star_index) |star| {
            pattern_index = star + 1;
            match_index += 1;
            text_index = match_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn entryIsFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    directory: *std.Io.Dir,
    entry: std.Io.Dir.Entry,
) !bool {
    const stat = entryStat(allocator, io, dir_path, directory, entry) orelse return false;
    return stat.kind == .file;
}

fn entryStat(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    directory: *std.Io.Dir,
    entry: std.Io.Dir.Entry,
) ?std.Io.File.Stat {
    _ = entry.kind;
    return directory.statFile(io, entry.name, .{ .follow_symlinks = true }) catch blk: {
        const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch break :blk null;
        defer allocator.free(full_path);
        break :blk std.Io.Dir.cwd().statFile(io, full_path, .{ .follow_symlinks = true }) catch null;
    };
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn relativePathAlloc(allocator: std.mem.Allocator, target_path: []const u8, root_dir: []const u8) ![]u8 {
    if (std.mem.eql(u8, target_path, root_dir)) return allocator.dupe(u8, "");
    if (std.mem.startsWith(u8, target_path, root_dir) and
        target_path.len > root_dir.len and
        (target_path[root_dir.len] == std.fs.path.sep or target_path[root_dir.len] == '/'))
    {
        return allocator.dupe(u8, target_path[root_dir.len + 1 ..]);
    }
    return std.fs.path.relative(allocator, ".", null, root_dir, target_path) catch allocator.dupe(u8, target_path);
}

fn toPosixPathAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const output = try allocator.dupe(u8, input);
    if (std.fs.path.sep != '/') {
        for (output) |*byte| {
            if (byte.* == std.fs.path.sep) byte.* = '/';
        }
    }
    return output;
}

fn isUnderPath(target: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, target, root)) return true;
    if (!std.mem.startsWith(u8, target, root)) return false;
    return target.len > root.len and target[root.len] == std.fs.path.sep;
}

fn deinitSkillList(allocator: std.mem.Allocator, skills: *std.ArrayList(Skill)) void {
    for (skills.items) |*skill| skill.deinit();
    skills.deinit(allocator);
}

fn deinitDiagnosticList(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(ResourceDiagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit();
    diagnostics.deinit(allocator);
}

fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
    var iterator = set.iterator();
    while (iterator.next()) |entry| allocator.free(@constCast(entry.key_ptr.*));
    set.deinit(allocator);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn writeSkillFixture(root: []const u8, relative_dir: []const u8, data: []const u8) !void {
    const allocator = std.testing.allocator;
    const skill_dir = try std.fs.path.join(allocator, &.{ root, relative_dir });
    defer allocator.free(skill_dir);
    const skill_file = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
    defer allocator.free(skill_file);
    try writeFile(skill_file, data);
}

fn createSkillFixtures(root: []const u8) !void {
    try writeSkillFixture(root, "valid-skill",
        \\---
        \\name: valid-skill
        \\description: A valid skill for testing purposes.
        \\---
        \\
        \\# Valid Skill
        \\
        \\This is a valid skill that follows the Agent Skills standard.
    );
    try writeSkillFixture(root, "name-mismatch",
        \\---
        \\name: different-name
        \\description: A skill with a name that doesn't match the directory.
        \\---
        \\
        \\# Name Mismatch
    );
    try writeSkillFixture(root, "invalid-name-chars",
        \\---
        \\name: Invalid_Name
        \\description: A skill with invalid characters in the name.
        \\---
        \\
        \\# Invalid Name
    );
    try writeSkillFixture(root, "long-name",
        \\---
        \\name: this-is-a-very-long-skill-name-that-exceeds-the-sixty-four-character-limit-set-by-the-standard
        \\description: A skill with a name that exceeds 64 characters.
        \\---
        \\
        \\# Long Name
    );
    try writeSkillFixture(root, "missing-description",
        \\---
        \\name: missing-description
        \\---
        \\
        \\# Missing Description
    );
    try writeSkillFixture(root, "unknown-field",
        \\---
        \\name: unknown-field
        \\description: A skill with an unknown frontmatter field.
        \\author: someone
        \\version: 1.0
        \\---
        \\
        \\# Unknown Field
    );
    try writeSkillFixture(root, "nested/child-skill",
        \\---
        \\name: child-skill
        \\description: A nested skill in a subdirectory.
        \\---
        \\
        \\# Child Skill
    );
    try writeSkillFixture(root, "root-skill-preferred",
        \\---
        \\description: Root skill should win.
        \\---
    );
    try writeSkillFixture(root, "root-skill-preferred/nested-child",
        \\---
        \\description: Nested skill should be ignored.
        \\---
    );
    try writeSkillFixture(root, "no-frontmatter",
        \\# No Frontmatter
        \\
        \\This skill has no YAML frontmatter at all.
    );
    try writeSkillFixture(root, "invalid-yaml",
        \\---
        \\name: invalid-yaml
        \\description: [unclosed bracket
        \\---
        \\
        \\# Invalid YAML Skill
    );
    try writeSkillFixture(root, "multiline-description",
        \\---
        \\name: multiline-description
        \\description: |
        \\  This is a multiline description.
        \\  It spans multiple lines.
        \\  And should be normalized.
        \\---
        \\
        \\# Multiline Description Skill
    );
    try writeSkillFixture(root, "consecutive-hyphens",
        \\---
        \\name: bad--name
        \\description: A skill with consecutive hyphens in the name.
        \\---
        \\
        \\# Consecutive Hyphens
    );
    try writeSkillFixture(root, "disable-model-invocation",
        \\---
        \\name: disable-model-invocation
        \\description: A skill that cannot be invoked by the model.
        \\disable-model-invocation: true
        \\---
        \\
        \\# Manual Only Skill
    );
}

fn findSkill(skills: []Skill, name: []const u8) ?*Skill {
    for (skills) |*skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

fn diagnosticsContain(diagnostics: []ResourceDiagnostic, needle: []const u8) bool {
    for (diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return true;
    }
    return false;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

test "loadSkillsFromDir ports upstream skill fixture discovery and diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures", "skills" });
    defer allocator.free(fixtures_dir);
    try createSkillFixtures(fixtures_dir);

    const valid_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "valid-skill" });
    defer allocator.free(valid_dir);
    var valid = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = valid_dir, .source = "test" });
    defer valid.deinit();
    try std.testing.expectEqual(@as(usize, 1), valid.skills.len);
    try std.testing.expectEqualStrings("valid-skill", valid.skills[0].name);
    try std.testing.expectEqualStrings("A valid skill for testing purposes.", valid.skills[0].description);
    try std.testing.expectEqualStrings("test", valid.skills[0].source_info.source);
    try std.testing.expectEqual(@as(usize, 0), valid.diagnostics.len);

    const mismatch_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "name-mismatch" });
    defer allocator.free(mismatch_dir);
    var mismatch = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = mismatch_dir, .source = "test" });
    defer mismatch.deinit();
    try std.testing.expectEqual(@as(usize, 1), mismatch.skills.len);
    try std.testing.expectEqualStrings("different-name", mismatch.skills[0].name);
    try std.testing.expect(!diagnosticsContain(mismatch.diagnostics, "does not match parent directory"));

    const invalid_name_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "invalid-name-chars" });
    defer allocator.free(invalid_name_dir);
    var invalid_name = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = invalid_name_dir, .source = "test" });
    defer invalid_name.deinit();
    try std.testing.expectEqual(@as(usize, 1), invalid_name.skills.len);
    try std.testing.expect(diagnosticsContain(invalid_name.diagnostics, "invalid characters"));

    const long_name_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "long-name" });
    defer allocator.free(long_name_dir);
    var long_name = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = long_name_dir, .source = "test" });
    defer long_name.deinit();
    try std.testing.expectEqual(@as(usize, 1), long_name.skills.len);
    try std.testing.expect(diagnosticsContain(long_name.diagnostics, "exceeds 64 characters"));

    const missing_description_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "missing-description" });
    defer allocator.free(missing_description_dir);
    var missing_description = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = missing_description_dir, .source = "test" });
    defer missing_description.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing_description.skills.len);
    try std.testing.expect(diagnosticsContain(missing_description.diagnostics, "description is required"));

    const unknown_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "unknown-field" });
    defer allocator.free(unknown_dir);
    var unknown = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = unknown_dir, .source = "test" });
    defer unknown.deinit();
    try std.testing.expectEqual(@as(usize, 1), unknown.skills.len);
    try std.testing.expectEqual(@as(usize, 0), unknown.diagnostics.len);

    const nested_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "nested" });
    defer allocator.free(nested_dir);
    var nested = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = nested_dir, .source = "test" });
    defer nested.deinit();
    try std.testing.expectEqual(@as(usize, 1), nested.skills.len);
    try std.testing.expectEqualStrings("child-skill", nested.skills[0].name);

    const root_preferred_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "root-skill-preferred" });
    defer allocator.free(root_preferred_dir);
    var root_preferred = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = root_preferred_dir, .source = "test" });
    defer root_preferred.deinit();
    try std.testing.expectEqual(@as(usize, 1), root_preferred.skills.len);
    try std.testing.expectEqualStrings("root-skill-preferred", root_preferred.skills[0].name);
    try std.testing.expectEqualStrings("Root skill should win.", root_preferred.skills[0].description);

    const no_frontmatter_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "no-frontmatter" });
    defer allocator.free(no_frontmatter_dir);
    var no_frontmatter = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = no_frontmatter_dir, .source = "test" });
    defer no_frontmatter.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_frontmatter.skills.len);
    try std.testing.expect(diagnosticsContain(no_frontmatter.diagnostics, "description is required"));

    const invalid_yaml_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "invalid-yaml" });
    defer allocator.free(invalid_yaml_dir);
    var invalid_yaml = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = invalid_yaml_dir, .source = "test" });
    defer invalid_yaml.deinit();
    try std.testing.expectEqual(@as(usize, 0), invalid_yaml.skills.len);
    try std.testing.expect(diagnosticsContain(invalid_yaml.diagnostics, "at line"));

    const multiline_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "multiline-description" });
    defer allocator.free(multiline_dir);
    var multiline = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = multiline_dir, .source = "test" });
    defer multiline.deinit();
    try std.testing.expectEqual(@as(usize, 1), multiline.skills.len);
    try expectContains(multiline.skills[0].description, "\n");
    try expectContains(multiline.skills[0].description, "This is a multiline description.");

    const consecutive_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "consecutive-hyphens" });
    defer allocator.free(consecutive_dir);
    var consecutive = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = consecutive_dir, .source = "test" });
    defer consecutive.deinit();
    try std.testing.expectEqual(@as(usize, 1), consecutive.skills.len);
    try std.testing.expect(diagnosticsContain(consecutive.diagnostics, "consecutive hyphens"));

    var all = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = fixtures_dir, .source = "test" });
    defer all.deinit();
    try std.testing.expect(all.skills.len >= 6);

    var missing_dir = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = "/non/existent/path", .source = "test" });
    defer missing_dir.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing_dir.skills.len);
    try std.testing.expectEqual(@as(usize, 0), missing_dir.diagnostics.len);

    const disabled_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "disable-model-invocation" });
    defer allocator.free(disabled_dir);
    var disabled = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = disabled_dir, .source = "test" });
    defer disabled.deinit();
    try std.testing.expectEqual(@as(usize, 1), disabled.skills.len);
    try std.testing.expect(disabled.skills[0].disable_model_invocation);
}

test "formatSkillsForPrompt ports upstream XML prompt formatting" {
    const allocator = std.testing.allocator;
    var visible = try Skill.initAlloc(
        allocator,
        "test-skill",
        "A skill with <special> & \"characters\".",
        "/path/to/skill/SKILL.md",
        "/path/to/skill",
        source_info.createSyntheticSourceInfo("/path/to/skill/SKILL.md", .{ .source = "test" }),
        false,
    );
    defer visible.deinit();
    var second = try Skill.initAlloc(
        allocator,
        "skill-two",
        "Second skill.",
        "/path/two/SKILL.md",
        "/path/two",
        source_info.createSyntheticSourceInfo("/path/two/SKILL.md", .{ .source = "test" }),
        false,
    );
    defer second.deinit();
    var hidden = try Skill.initAlloc(
        allocator,
        "hidden-skill",
        "A hidden skill.",
        "/path/hidden/SKILL.md",
        "/path/hidden",
        source_info.createSyntheticSourceInfo("/path/hidden/SKILL.md", .{ .source = "test" }),
        true,
    );
    defer hidden.deinit();

    const empty = try formatSkillsForPromptAlloc(allocator, &.{});
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    const result = try formatSkillsForPromptAlloc(allocator, &.{ visible, second, hidden });
    defer allocator.free(result);
    try expectContains(result, "The following skills provide specialized instructions");
    try expectContains(result, "Use the read tool to load a skill's file");
    try expectContains(result, "<available_skills>");
    try expectContains(result, "</available_skills>");
    try expectContains(result, "<name>test-skill</name>");
    try expectContains(result, "<description>A skill with &lt;special&gt; &amp; &quot;characters&quot;.</description>");
    try expectContains(result, "<location>/path/to/skill/SKILL.md</location>");
    try expectContains(result, "<name>skill-two</name>");
    try expectNotContains(result, "<name>hidden-skill</name>");

    const all_hidden = try formatSkillsForPromptAlloc(allocator, &.{hidden});
    defer allocator.free(all_hidden);
    try std.testing.expectEqualStrings("", all_hidden);
}

test "loadSkills ports explicit paths tilde expansion duplicates and collisions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    const fixtures_dir = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures", "skills" });
    defer allocator.free(fixtures_dir);
    try createSkillFixtures(fixtures_dir);

    const empty_agent_dir = try std.fs.path.join(allocator, &.{ tmp_path, "empty-agent" });
    defer allocator.free(empty_agent_dir);
    const empty_cwd = try std.fs.path.join(allocator, &.{ tmp_path, "empty-cwd" });
    defer allocator.free(empty_cwd);
    try std.Io.Dir.cwd().createDirPath(io, empty_agent_dir);
    try std.Io.Dir.cwd().createDirPath(io, empty_cwd);

    const valid_dir = try std.fs.path.join(allocator, &.{ fixtures_dir, "valid-skill" });
    defer allocator.free(valid_dir);
    var explicit = try loadSkillsAlloc(allocator, io, .{
        .agent_dir = empty_agent_dir,
        .cwd = empty_cwd,
        .skill_paths = &.{valid_dir},
        .include_defaults = true,
    });
    defer explicit.deinit();
    try std.testing.expectEqual(@as(usize, 1), explicit.skills.len);
    try std.testing.expectEqual(source_info.SourceScope.temporary, explicit.skills[0].source_info.scope);
    try std.testing.expectEqual(@as(usize, 0), explicit.diagnostics.len);

    var missing = try loadSkillsAlloc(allocator, io, .{
        .agent_dir = empty_agent_dir,
        .cwd = empty_cwd,
        .skill_paths = &.{"/non/existent/path"},
        .include_defaults = true,
    });
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.skills.len);
    try std.testing.expect(diagnosticsContain(missing.diagnostics, "does not exist"));

    const home_dir = try std.fs.path.join(allocator, &.{ tmp_path, "home" });
    defer allocator.free(home_dir);
    const home_skills_dir = try std.fs.path.join(allocator, &.{ home_dir, ".bulb", "agent", "skills" });
    defer allocator.free(home_skills_dir);
    try writeSkillFixture(home_skills_dir, "valid-skill",
        \\---
        \\name: valid-skill
        \\description: A valid skill under home.
        \\---
    );
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", home_dir);

    var with_tilde = try loadSkillsAlloc(allocator, io, .{
        .agent_dir = empty_agent_dir,
        .cwd = empty_cwd,
        .skill_paths = &.{"~/.bulb/agent/skills"},
        .include_defaults = true,
        .env = &env,
    });
    defer with_tilde.deinit();
    var without_tilde = try loadSkillsAlloc(allocator, io, .{
        .agent_dir = empty_agent_dir,
        .cwd = empty_cwd,
        .skill_paths = &.{home_skills_dir},
        .include_defaults = true,
        .env = &env,
    });
    defer without_tilde.deinit();
    try std.testing.expectEqual(with_tilde.skills.len, without_tilde.skills.len);

    var duplicate = try loadSkillsAlloc(allocator, io, .{
        .agent_dir = empty_agent_dir,
        .cwd = empty_cwd,
        .skill_paths = &.{ valid_dir, valid_dir },
        .include_defaults = false,
    });
    defer duplicate.deinit();
    try std.testing.expectEqual(@as(usize, 1), duplicate.skills.len);
    try std.testing.expectEqual(@as(usize, 0), duplicate.diagnostics.len);

    const collision_first = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures", "skills-collision", "first", "calendar" });
    defer allocator.free(collision_first);
    const collision_second = try std.fs.path.join(allocator, &.{ tmp_path, "fixtures", "skills-collision", "second", "calendar" });
    defer allocator.free(collision_second);
    try writeSkillFixture(collision_first, "",
        \\---
        \\name: calendar
        \\description: First calendar skill.
        \\---
    );
    try writeSkillFixture(collision_second, "",
        \\---
        \\name: calendar
        \\description: Second calendar skill.
        \\---
    );
    var collision = try loadSkillsAlloc(allocator, io, .{
        .agent_dir = empty_agent_dir,
        .cwd = empty_cwd,
        .skill_paths = &.{ collision_first, collision_second },
        .include_defaults = false,
    });
    defer collision.deinit();
    try std.testing.expectEqual(@as(usize, 1), collision.skills.len);
    try std.testing.expectEqualStrings("calendar", collision.skills[0].name);
    try std.testing.expect(diagnosticsContain(collision.diagnostics, "collision"));
    try std.testing.expect(collision.diagnostics[0].collision != null);
}

test "loadSkillsFromDir honors SKILL roots root markdown files and ignore files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);

    const root = try std.fs.path.join(allocator, &.{ tmp_path, "ignore-fixture" });
    defer allocator.free(root);
    const ignore_file = try std.fs.path.join(allocator, &.{ root, ".gitignore" });
    defer allocator.free(ignore_file);
    try writeFile(ignore_file, "ignored/\n*.skip.md\n");
    try writeSkillFixture(root, "ignored/hidden",
        \\---
        \\name: hidden
        \\description: Hidden by ignore.
        \\---
    );
    const root_markdown = try std.fs.path.join(allocator, &.{ root, "direct.md" });
    defer allocator.free(root_markdown);
    try writeFile(root_markdown,
        \\---
        \\name: direct
        \\description: Direct root markdown skill.
        \\---
    );
    const skipped_markdown = try std.fs.path.join(allocator, &.{ root, "ignored.skip.md" });
    defer allocator.free(skipped_markdown);
    try writeFile(skipped_markdown,
        \\---
        \\name: skipped
        \\description: Ignored markdown skill.
        \\---
    );
    try writeSkillFixture(root, "nested/visible",
        \\---
        \\name: visible
        \\description: Visible nested skill.
        \\---
    );

    var result = try loadSkillsFromDirAlloc(allocator, io, .{ .dir = root, .source = "test" });
    defer result.deinit();
    try std.testing.expect(findSkill(result.skills, "direct") != null);
    try std.testing.expect(findSkill(result.skills, "visible") != null);
    try std.testing.expect(findSkill(result.skills, "hidden") == null);
    try std.testing.expect(findSkill(result.skills, "skipped") == null);
}
