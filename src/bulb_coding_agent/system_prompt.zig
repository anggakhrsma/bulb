const std = @import("std");
const config = @import("config.zig");
const skills_mod = @import("skills.zig");

const default_tools = [_][]const u8{ "read", "bash", "edit", "write" };

pub const Skill = skills_mod.Skill;

pub const ContextFile = struct {
    path: []const u8,
    content: []const u8,
};

pub const ToolSnippet = struct {
    name: []const u8,
    snippet: []const u8,
};

pub const DocumentationPaths = struct {
    readme_path: []const u8,
    docs_path: []const u8,
    examples_path: []const u8,
};

pub const BuildSystemPromptOptions = struct {
    cwd: []const u8,
    custom_prompt: ?[]const u8 = null,
    selected_tools: ?[]const []const u8 = null,
    tool_snippets: []const ToolSnippet = &.{},
    prompt_guidelines: []const []const u8 = &.{},
    append_system_prompt: ?[]const u8 = null,
    context_files: []const ContextFile = &.{},
    skills: []const Skill = &.{},
    documentation_paths: ?DocumentationPaths = null,
    date_override: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
};

pub fn buildSystemPromptAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: BuildSystemPromptOptions,
) ![]u8 {
    const prompt_cwd = try slashPathAlloc(allocator, options.cwd);
    defer allocator.free(prompt_cwd);

    var owned_date: ?[]u8 = null;
    defer if (owned_date) |date| allocator.free(date);
    const date = if (options.date_override) |value| value else blk: {
        owned_date = try currentDateAlloc(allocator, io);
        break :blk owned_date.?;
    };

    var prompt: std.ArrayList(u8) = .empty;
    errdefer prompt.deinit(allocator);

    if (options.custom_prompt) |custom_prompt| {
        try prompt.appendSlice(allocator, custom_prompt);
        try appendOptionalText(&prompt, allocator, options.append_system_prompt);
        try appendProjectContext(&prompt, allocator, options.context_files);

        const custom_prompt_has_read = if (options.selected_tools) |selected|
            containsName(selected, "read")
        else
            true;
        if (custom_prompt_has_read and options.skills.len > 0) {
            const formatted_skills = try skills_mod.formatSkillsForPromptAlloc(allocator, options.skills);
            defer allocator.free(formatted_skills);
            try prompt.appendSlice(allocator, formatted_skills);
        }

        try appendDateAndCwd(&prompt, allocator, date, prompt_cwd);
        return prompt.toOwnedSlice(allocator);
    }

    var readme_path_owned: ?[]u8 = null;
    var docs_path_owned: ?[]u8 = null;
    var examples_path_owned: ?[]u8 = null;
    defer if (readme_path_owned) |path| allocator.free(path);
    defer if (docs_path_owned) |path| allocator.free(path);
    defer if (examples_path_owned) |path| allocator.free(path);

    const docs_paths = options.documentation_paths orelse blk: {
        readme_path_owned = try config.readmePathAlloc(allocator, io, options.env);
        docs_path_owned = try config.docsPathAlloc(allocator, io, options.env);
        examples_path_owned = try config.examplesPathAlloc(allocator, io, options.env);
        break :blk DocumentationPaths{
            .readme_path = readme_path_owned.?,
            .docs_path = docs_path_owned.?,
            .examples_path = examples_path_owned.?,
        };
    };

    const tools = options.selected_tools orelse default_tools[0..];
    const tools_list = try formatToolsListAlloc(allocator, tools, options.tool_snippets);
    defer allocator.free(tools_list);
    const guidelines = try formatGuidelinesAlloc(allocator, tools, options.prompt_guidelines);
    defer allocator.free(guidelines);

    try prompt.appendSlice(
        allocator,
        "You are an expert coding assistant operating inside bulb, a coding agent harness. " ++
            "You help users by reading files, executing commands, editing code, and writing new files.\n\n" ++
            "Available tools:\n",
    );
    try prompt.appendSlice(allocator, tools_list);
    try prompt.appendSlice(allocator, "\n\nIn addition to the tools above, you may have access to other custom tools depending on the project.\n\nGuidelines:\n");
    try prompt.appendSlice(allocator, guidelines);
    try prompt.appendSlice(allocator, "\n\nBulb documentation (read only when the user asks about bulb itself, its SDK, extensions, themes, skills, or TUI):\n");
    try appendFmt(
        &prompt,
        allocator,
        "- Main documentation: {s}\n- Additional docs: {s}\n- Examples: {s} (extensions, custom tools, SDK)\n",
        .{ docs_paths.readme_path, docs_paths.docs_path, docs_paths.examples_path },
    );
    try prompt.appendSlice(
        allocator,
        "- When reading bulb docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory\n" ++
            "- When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), bulb packages (docs/packages.md)\n" ++
            "- When working on bulb topics, read the docs and examples, and follow .md cross-references before implementing\n" ++
            "- Always read bulb .md files completely and follow links to related docs (e.g., tui.md for TUI API details)",
    );

    try appendOptionalText(&prompt, allocator, options.append_system_prompt);
    try appendProjectContext(&prompt, allocator, options.context_files);

    if (containsName(tools, "read") and options.skills.len > 0) {
        const formatted_skills = try skills_mod.formatSkillsForPromptAlloc(allocator, options.skills);
        defer allocator.free(formatted_skills);
        try prompt.appendSlice(allocator, formatted_skills);
    }

    try appendDateAndCwd(&prompt, allocator, date, prompt_cwd);
    return prompt.toOwnedSlice(allocator);
}

fn formatToolsListAlloc(
    allocator: std.mem.Allocator,
    tools: []const []const u8,
    tool_snippets: []const ToolSnippet,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var visible_count: usize = 0;

    for (tools) |name| {
        const snippet = findToolSnippet(tool_snippets, name) orelse continue;
        if (visible_count > 0) try output.append(allocator, '\n');
        try appendFmt(&output, allocator, "- {s}: {s}", .{ name, snippet });
        visible_count += 1;
    }

    if (visible_count == 0) {
        try output.appendSlice(allocator, "(none)");
    }
    return output.toOwnedSlice(allocator);
}

fn formatGuidelinesAlloc(
    allocator: std.mem.Allocator,
    tools: []const []const u8,
    prompt_guidelines: []const []const u8,
) ![]u8 {
    var guidelines: std.ArrayList([]const u8) = .empty;
    defer guidelines.deinit(allocator);

    if (containsName(tools, "bash") and
        !containsName(tools, "grep") and
        !containsName(tools, "find") and
        !containsName(tools, "ls"))
    {
        try addGuideline(allocator, &guidelines, "Use bash for file operations like ls, rg, find");
    }

    for (prompt_guidelines) |guideline| {
        const normalized = std.mem.trim(u8, guideline, " \t\r\n");
        if (normalized.len > 0) try addGuideline(allocator, &guidelines, normalized);
    }

    try addGuideline(allocator, &guidelines, "Be concise in your responses");
    try addGuideline(allocator, &guidelines, "Show file paths clearly when working with files");

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (guidelines.items, 0..) |guideline, index| {
        if (index > 0) try output.append(allocator, '\n');
        try appendFmt(&output, allocator, "- {s}", .{guideline});
    }
    return output.toOwnedSlice(allocator);
}

fn addGuideline(
    allocator: std.mem.Allocator,
    guidelines: *std.ArrayList([]const u8),
    guideline: []const u8,
) !void {
    for (guidelines.items) |existing| {
        if (std.mem.eql(u8, existing, guideline)) return;
    }
    try guidelines.append(allocator, guideline);
}

fn appendOptionalText(output: *std.ArrayList(u8), allocator: std.mem.Allocator, text: ?[]const u8) !void {
    if (text) |value| {
        if (value.len > 0) {
            try output.appendSlice(allocator, "\n\n");
            try output.appendSlice(allocator, value);
        }
    }
}

fn appendProjectContext(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    context_files: []const ContextFile,
) !void {
    if (context_files.len == 0) return;
    try output.appendSlice(allocator, "\n\n<project_context>\n\nProject-specific instructions and guidelines:\n\n");
    for (context_files) |context_file| {
        try appendFmt(
            output,
            allocator,
            "<project_instructions path=\"{s}\">\n{s}\n</project_instructions>\n\n",
            .{ context_file.path, context_file.content },
        );
    }
    try output.appendSlice(allocator, "</project_context>\n");
}

fn appendDateAndCwd(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    date: []const u8,
    cwd: []const u8,
) !void {
    try appendFmt(output, allocator, "\nCurrent date: {s}\nCurrent working directory: {s}", .{ date, cwd });
}

fn findToolSnippet(tool_snippets: []const ToolSnippet, name: []const u8) ?[]const u8 {
    for (tool_snippets) |snippet| {
        if (std.mem.eql(u8, snippet.name, name)) return snippet.snippet;
    }
    return null;
}

fn containsName(values: []const []const u8, name: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, name)) return true;
    }
    return false;
}

fn currentDateAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const timestamp_ms = std.Io.Clock.real.now(io).toMilliseconds();
    if (timestamp_ms < 0) return allocator.dupe(u8, "1970-01-01");
    const epoch_seconds = std.time.epoch.EpochSeconds{
        .secs = @intCast(@divTrunc(timestamp_ms, std.time.ms_per_s)),
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{
            year_day.year,
            month_day.month.numeric(),
            @as(u8, month_day.day_index) + 1,
        },
    );
}

fn slashPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, path);
    for (result) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return result;
}

fn appendFmt(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOf(u8, haystack[index..], needle)) |offset| {
        count += 1;
        index += offset + needle.len;
    }
    return count;
}

const test_docs = DocumentationPaths{
    .readme_path = "/opt/bulb/README.md",
    .docs_path = "/opt/bulb/docs",
    .examples_path = "/opt/bulb/examples",
};

test "buildSystemPrompt shows none for empty tools list" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .selected_tools = &.{},
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try expectContains(prompt, "Available tools:\n(none)");
}

test "buildSystemPrompt shows file paths guideline even with no tools" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .selected_tools = &.{},
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try expectContains(prompt, "Show file paths clearly");
}

test "buildSystemPrompt includes all default tools when snippets are provided" {
    const allocator = std.testing.allocator;
    const snippets = [_]ToolSnippet{
        .{ .name = "read", .snippet = "Read file contents" },
        .{ .name = "bash", .snippet = "Execute bash commands" },
        .{ .name = "edit", .snippet = "Make surgical edits" },
        .{ .name = "write", .snippet = "Create or overwrite files" },
    };
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .tool_snippets = &snippets,
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try expectContains(prompt, "- read:");
    try expectContains(prompt, "- bash:");
    try expectContains(prompt, "- edit:");
    try expectContains(prompt, "- write:");
}

test "buildSystemPrompt instructs models to resolve Bulb docs and examples under absolute base paths" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try expectContains(prompt, "- When reading bulb docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory");
}

test "buildSystemPrompt includes custom tools in available tools section when promptSnippet is provided" {
    const allocator = std.testing.allocator;
    const selected = [_][]const u8{ "read", "dynamic_tool" };
    const snippets = [_]ToolSnippet{.{ .name = "dynamic_tool", .snippet = "Run dynamic test behavior" }};
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .selected_tools = &selected,
        .tool_snippets = &snippets,
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try expectContains(prompt, "- dynamic_tool: Run dynamic test behavior");
}

test "buildSystemPrompt omits custom tools from available tools section when promptSnippet is not provided" {
    const allocator = std.testing.allocator;
    const selected = [_][]const u8{ "read", "dynamic_tool" };
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .selected_tools = &selected,
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try expectNotContains(prompt, "dynamic_tool");
}

test "buildSystemPrompt appends promptGuidelines to default guidelines" {
    const allocator = std.testing.allocator;
    const selected = [_][]const u8{ "read", "dynamic_tool" };
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .selected_tools = &selected,
        .prompt_guidelines = &.{"Use dynamic_tool for project summaries."},
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try expectContains(prompt, "- Use dynamic_tool for project summaries.");
}

test "buildSystemPrompt deduplicates and trims promptGuidelines" {
    const allocator = std.testing.allocator;
    const selected = [_][]const u8{ "read", "dynamic_tool" };
    const prompt = try buildSystemPromptAlloc(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .selected_tools = &selected,
        .prompt_guidelines = &.{
            "Use dynamic_tool for summaries.",
            "  Use dynamic_tool for summaries.  ",
            "   ",
        },
        .context_files = &.{},
        .skills = &.{},
        .documentation_paths = test_docs,
        .date_override = "2026-06-01",
    });
    defer allocator.free(prompt);

    try std.testing.expectEqual(@as(usize, 1), countOccurrences(prompt, "- Use dynamic_tool for summaries."));
}
