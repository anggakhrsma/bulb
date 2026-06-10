const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const types = @import("types.zig");

pub const Skill = types.Skill;
pub const SkillDiagnosticCode = types.SkillDiagnosticCode;

const max_name_length = 64;
const max_description_length = 1024;

pub const SkillDiagnostic = struct {
    allocator: std.mem.Allocator,
    type: []const u8 = "warning",
    code: SkillDiagnosticCode,
    message: []u8,
    path: []u8,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        code: SkillDiagnosticCode,
        message: []const u8,
        path: []const u8,
    ) !SkillDiagnostic {
        const owned_message = try allocator.dupe(u8, message);
        errdefer allocator.free(owned_message);
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        return .{
            .allocator = allocator,
            .code = code,
            .message = owned_message,
            .path = owned_path,
        };
    }

    pub fn deinit(self: *SkillDiagnostic) void {
        self.allocator.free(self.message);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const LoadSkillsOptions = struct {
    cwd: []const u8 = ".",
    paths: []const []const u8,
};

pub const LoadSkillsResult = struct {
    allocator: std.mem.Allocator,
    skills: []Skill,
    diagnostics: []SkillDiagnostic,

    pub fn deinit(self: *LoadSkillsResult) void {
        for (self.skills) |*skill| skill.deinit();
        self.allocator.free(self.skills);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit();
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const SourcedSkillInput = struct {
    path: []const u8,
    source: []const u8,
};

pub const SourcedSkill = struct {
    allocator: std.mem.Allocator,
    skill: Skill,
    source: []u8,

    pub fn deinit(self: *SourcedSkill) void {
        self.skill.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

pub const SourcedSkillDiagnostic = struct {
    allocator: std.mem.Allocator,
    diagnostic: SkillDiagnostic,
    source: []u8,

    pub fn deinit(self: *SourcedSkillDiagnostic) void {
        self.diagnostic.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

pub const LoadSourcedSkillsResult = struct {
    allocator: std.mem.Allocator,
    skills: []SourcedSkill,
    diagnostics: []SourcedSkillDiagnostic,

    pub fn deinit(self: *LoadSourcedSkillsResult) void {
        for (self.skills) |*skill| skill.deinit();
        self.allocator.free(self.skills);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit();
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub fn formatSkillInvocationAlloc(
    allocator: std.mem.Allocator,
    skill: Skill,
    additional_instructions: ?[]const u8,
) ![]u8 {
    const skill_dir = dirnameEnvPath(skill.file_path);
    const skill_block = try std.fmt.allocPrint(
        allocator,
        "<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>",
        .{ skill.name, skill.file_path, skill_dir, skill.content },
    );
    errdefer allocator.free(skill_block);
    if (additional_instructions) |instructions| {
        defer allocator.free(skill_block);
        return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ skill_block, instructions });
    }
    return skill_block;
}

pub fn formatSkillsForSystemPromptAlloc(allocator: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var visible_count: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible_count += 1;
    }
    if (visible_count == 0) return allocator.dupe(u8, "");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(
        allocator,
        "The following skills provide specialized instructions for specific tasks.\n" ++
            "Read the full skill file when the task matches its description.\n" ++
            "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n" ++
            "<available_skills>",
    );
    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try output.appendSlice(allocator, "\n  <skill>\n    <name>");
        try types.appendEscapedXml(&output, allocator, skill.name);
        try output.appendSlice(allocator, "</name>\n    <description>");
        try types.appendEscapedXml(&output, allocator, skill.description);
        try output.appendSlice(allocator, "</description>\n    <location>");
        try types.appendEscapedXml(&output, allocator, skill.file_path);
        try output.appendSlice(allocator, "</location>\n  </skill>");
    }
    try output.appendSlice(allocator, "\n</available_skills>");
    return output.toOwnedSlice(allocator);
}

pub fn loadSkillsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadSkillsOptions,
) !LoadSkillsResult {
    var skills: std.ArrayList(Skill) = .empty;
    errdefer deinitSkillList(allocator, &skills);
    var diagnostics: std.ArrayList(SkillDiagnostic) = .empty;
    errdefer deinitDiagnosticList(allocator, &diagnostics);

    for (options.paths) |input_path| {
        const resolved_path = try resolvePathAlloc(allocator, options.cwd, input_path);
        defer allocator.free(resolved_path);
        const stat = statPath(io, resolved_path) catch continue;
        if (stat.kind != .directory) continue;
        try loadSkillsFromDirInternal(
            allocator,
            io,
            resolved_path,
            true,
            &skills,
            &diagnostics,
        );
    }

    return .{
        .allocator = allocator,
        .skills = try skills.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn loadSourcedSkillsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    inputs: []const SourcedSkillInput,
) !LoadSourcedSkillsResult {
    var skills: std.ArrayList(SourcedSkill) = .empty;
    errdefer deinitSourcedSkillList(allocator, &skills);
    var diagnostics: std.ArrayList(SourcedSkillDiagnostic) = .empty;
    errdefer deinitSourcedDiagnosticList(allocator, &diagnostics);

    for (inputs) |input| {
        var result = try loadSkillsAlloc(allocator, io, .{
            .cwd = cwd,
            .paths = &.{input.path},
        });
        defer result.deinit();

        for (result.skills) |*skill| {
            try skills.append(allocator, .{
                .allocator = allocator,
                .skill = try Skill.initAlloc(
                    allocator,
                    skill.name,
                    skill.description,
                    skill.content,
                    skill.file_path,
                    skill.disable_model_invocation,
                ),
                .source = try allocator.dupe(u8, input.source),
            });
        }
        for (result.diagnostics) |*diagnostic| {
            try diagnostics.append(allocator, .{
                .allocator = allocator,
                .diagnostic = try SkillDiagnostic.initAlloc(
                    allocator,
                    diagnostic.code,
                    diagnostic.message,
                    diagnostic.path,
                ),
                .source = try allocator.dupe(u8, input.source),
            });
        }
    }

    return .{
        .allocator = allocator,
        .skills = try skills.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn loadSkillsFromDirInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    include_root_files: bool,
    skills: *std.ArrayList(Skill),
    diagnostics: *std.ArrayList(SkillDiagnostic),
) !void {
    var directory = openDirPath(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendDiagnosticFmt(allocator, diagnostics, .list_failed, dir_path, "{s}", .{@errorName(err)});
        return;
    };
    defer directory.close(io);

    const skill_file_path = try std.fs.path.join(allocator, &.{ dir_path, "SKILL.md" });
    defer allocator.free(skill_file_path);
    if (isFile(io, skill_file_path)) {
        if (try loadSkillFromFileAlloc(allocator, io, skill_file_path, diagnostics)) |skill| {
            try skills.append(allocator, skill);
        }
        return;
    }

    const names = try readSortedEntryNames(allocator, io, &directory);
    defer freeStringList(allocator, names);
    for (names) |name| {
        if (name.len == 0 or name[0] == '.' or std.mem.eql(u8, name, "node_modules")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(path);
        const stat = statPath(io, path) catch continue;
        if (stat.kind == .directory) {
            try loadSkillsFromDirInternal(allocator, io, path, false, skills, diagnostics);
            continue;
        }
        if (stat.kind != .file or !include_root_files or !std.ascii.endsWithIgnoreCase(name, ".md")) continue;
        if (try loadSkillFromFileAlloc(allocator, io, path, diagnostics)) |skill| {
            try skills.append(allocator, skill);
        }
    }
}

fn loadSkillFromFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    diagnostics: *std.ArrayList(SkillDiagnostic),
) !?Skill {
    const raw_content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch |err| {
        try appendDiagnosticFmt(allocator, diagnostics, .read_failed, file_path, "{s}", .{@errorName(err)});
        return null;
    };
    defer allocator.free(raw_content);

    var parsed = frontmatter.parseAlloc(allocator, raw_content) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidFrontmatter => {
            try appendDiagnosticFmt(allocator, diagnostics, .parse_failed, file_path, "invalid YAML frontmatter", .{});
            return null;
        },
    };
    defer parsed.deinit();

    const skill_dir = dirnameEnvPath(file_path);
    const parent_dir_name = basenameEnvPath(skill_dir);
    const description = parsed.description;
    try validateDescription(allocator, diagnostics, file_path, description);

    const name = parsed.name orelse parent_dir_name;
    try validateName(allocator, diagnostics, file_path, name, parent_dir_name);

    if (description == null or std.mem.trim(u8, description.?, " \t\r\n").len == 0) return null;
    return try Skill.initAlloc(
        allocator,
        name,
        description.?,
        parsed.body,
        file_path,
        parsed.disable_model_invocation orelse false,
    );
}

fn validateName(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(SkillDiagnostic),
    file_path: []const u8,
    name: []const u8,
    parent_dir_name: []const u8,
) !void {
    if (!std.mem.eql(u8, name, parent_dir_name)) {
        try appendDiagnosticFmt(
            allocator,
            diagnostics,
            .invalid_metadata,
            file_path,
            "name \"{s}\" does not match parent directory \"{s}\"",
            .{ name, parent_dir_name },
        );
    }
    if (name.len > max_name_length) {
        try appendDiagnosticFmt(
            allocator,
            diagnostics,
            .invalid_metadata,
            file_path,
            "name exceeds {d} characters ({d})",
            .{ max_name_length, name.len },
        );
    }
    if (!isValidNameCharacters(name)) {
        try appendDiagnosticFmt(
            allocator,
            diagnostics,
            .invalid_metadata,
            file_path,
            "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)",
            .{},
        );
    }
    if (name.len > 0 and (name[0] == '-' or name[name.len - 1] == '-')) {
        try appendDiagnosticFmt(allocator, diagnostics, .invalid_metadata, file_path, "name must not start or end with a hyphen", .{});
    }
    if (std.mem.indexOf(u8, name, "--") != null) {
        try appendDiagnosticFmt(allocator, diagnostics, .invalid_metadata, file_path, "name must not contain consecutive hyphens", .{});
    }
}

fn validateDescription(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(SkillDiagnostic),
    file_path: []const u8,
    description: ?[]const u8,
) !void {
    if (description == null or std.mem.trim(u8, description.?, " \t\r\n").len == 0) {
        try appendDiagnosticFmt(allocator, diagnostics, .invalid_metadata, file_path, "description is required", .{});
    } else if (description.?.len > max_description_length) {
        try appendDiagnosticFmt(
            allocator,
            diagnostics,
            .invalid_metadata,
            file_path,
            "description exceeds {d} characters ({d})",
            .{ max_description_length, description.?.len },
        );
    }
}

fn isValidNameCharacters(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if ((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-') continue;
        return false;
    }
    return true;
}

fn resolvePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn statPath(io: std.Io, path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true });
}

fn isFile(io: std.Io, path: []const u8) bool {
    const stat = statPath(io, path) catch return false;
    return stat.kind == .file;
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn readSortedEntryNames(allocator: std.mem.Allocator, io: std.Io, directory: *std.Io.Dir) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, names.items);
    var iterator = directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    const owned = try names.toOwnedSlice(allocator);
    std.mem.sort([]u8, owned, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return owned;
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn dirnameEnvPath(path: []const u8) []const u8 {
    const normalized = trimTrailingSlashes(path);
    const slash_index = std.mem.lastIndexOfScalar(u8, normalized, '/') orelse return "/";
    if (slash_index == 0) return "/";
    return normalized[0..slash_index];
}

fn basenameEnvPath(path: []const u8) []const u8 {
    const normalized = trimTrailingSlashes(path);
    const slash_index = std.mem.lastIndexOfScalar(u8, normalized, '/') orelse return normalized;
    return normalized[slash_index + 1 ..];
}

fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn appendDiagnosticFmt(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(SkillDiagnostic),
    code: SkillDiagnosticCode,
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try diagnostics.append(allocator, try SkillDiagnostic.initAlloc(allocator, code, message, path));
}

fn deinitSkillList(allocator: std.mem.Allocator, skills: *std.ArrayList(Skill)) void {
    for (skills.items) |*skill| skill.deinit();
    skills.deinit(allocator);
}

fn deinitDiagnosticList(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(SkillDiagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit();
    diagnostics.deinit(allocator);
}

fn deinitSourcedSkillList(allocator: std.mem.Allocator, skills: *std.ArrayList(SourcedSkill)) void {
    for (skills.items) |*skill| skill.deinit();
    skills.deinit(allocator);
}

fn deinitSourcedDiagnosticList(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(SourcedSkillDiagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit();
    diagnostics.deinit(allocator);
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

test "formatSkillInvocation formats skill block with additional instructions" {
    const allocator = std.testing.allocator;
    var skill = try Skill.initAlloc(
        allocator,
        "inspect",
        "Inspect things",
        "Use inspection tools.",
        "/project/.bulb/skills/inspect/SKILL.md",
        false,
    );
    defer skill.deinit();

    const rendered = try formatSkillInvocationAlloc(allocator, skill, "Check errors.");
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "<skill name=\"inspect\" location=\"/project/.bulb/skills/inspect/SKILL.md\">\nReferences are relative to /project/.bulb/skills/inspect.\n\nUse inspection tools.\n</skill>\n\nCheck errors.",
        rendered,
    );
}

test "loadSkills loads SKILL.md files and direct root markdown children" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const skill_file = try std.fs.path.join(allocator, &.{ root, ".agents", "skills", "example", "SKILL.md" });
    defer allocator.free(skill_file);
    try writeFile(skill_file,
        \\---
        \\name: example
        \\description: Example skill
        \\disable-model-invocation: true
        \\---
        \\Use this skill.
    );

    var loaded = try loadSkillsAlloc(allocator, io, .{ .cwd = root, .paths = &.{".agents/skills"} });
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.skills.len);
    try std.testing.expectEqualStrings("example", loaded.skills[0].name);
    try std.testing.expectEqualStrings("Example skill", loaded.skills[0].description);
    try std.testing.expectEqualStrings("Use this skill.", loaded.skills[0].content);
    try std.testing.expect(loaded.skills[0].disable_model_invocation);

    const root_skill = try std.fs.path.join(allocator, &.{ root, "plain-skills", "root.md" });
    defer allocator.free(root_skill);
    const nested_ignored = try std.fs.path.join(allocator, &.{ root, "plain-skills", "nested", "ignored.md" });
    defer allocator.free(nested_ignored);
    try writeFile(root_skill, "---\ndescription: Root skill\n---\nRoot content");
    try writeFile(nested_ignored, "---\ndescription: Ignored\n---\nIgnored content");
    var root_loaded = try loadSkillsAlloc(allocator, io, .{ .cwd = root, .paths = &.{"plain-skills"} });
    defer root_loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), root_loaded.skills.len);
    try std.testing.expectEqualStrings("plain-skills", root_loaded.skills[0].name);
    try std.testing.expectEqualStrings("Root content", root_loaded.skills[0].content);
}

test "loadSkills handles symlinked directories and sourced diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const actual_skill = try std.fs.path.join(allocator, &.{ root, "actual", "example", "SKILL.md" });
    defer allocator.free(actual_skill);
    const actual_dir = try std.fs.path.join(allocator, &.{ root, "actual" });
    defer allocator.free(actual_dir);
    const link_dir = try std.fs.path.join(allocator, &.{ root, "skills-link" });
    defer allocator.free(link_dir);
    try writeFile(actual_skill, "---\nname: example\ndescription: Example skill\n---\nUse this skill.");
    try std.Io.Dir.cwd().symLink(io, actual_dir, link_dir, .{});

    var symlinked = try loadSkillsAlloc(allocator, io, .{ .cwd = root, .paths = &.{"skills-link"} });
    defer symlinked.deinit();
    try std.testing.expectEqual(@as(usize, 1), symlinked.skills.len);
    try std.testing.expectEqualStrings("example", symlinked.skills[0].name);
    try std.testing.expect(std.mem.indexOf(u8, symlinked.skills[0].file_path, "skills-link/example/SKILL.md") != null);

    const broken = try std.fs.path.join(allocator, &.{ root, "user", "broken", "SKILL.md" });
    defer allocator.free(broken);
    try writeFile(broken, "---\nname: broken\n---\nMissing description.");
    var sourced = try loadSourcedSkillsAlloc(allocator, io, root, &.{
        .{ .path = "user", .source = "user" },
    });
    defer sourced.deinit();
    try std.testing.expectEqual(@as(usize, 0), sourced.skills.len);
    try std.testing.expectEqual(@as(usize, 1), sourced.diagnostics.len);
    try std.testing.expectEqual(SkillDiagnosticCode.invalid_metadata, sourced.diagnostics[0].diagnostic.code);
    try std.testing.expectEqualStrings("description is required", sourced.diagnostics[0].diagnostic.message);
    try std.testing.expectEqualStrings("user", sourced.diagnostics[0].source);
}
