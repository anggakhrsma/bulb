const std = @import("std");
const config = @import("config.zig");
const frontmatter = @import("frontmatter.zig");
const paths = @import("paths.zig");
const source_info = @import("source_info.zig");

pub const SourceInfo = source_info.SourceInfo;

pub const PromptTemplate = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    description: []u8,
    argument_hint: ?[]u8,
    content: []u8,
    source_info: SourceInfo,
    file_path: []u8,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        name: []const u8,
        description: []const u8,
        argument_hint: ?[]const u8,
        content: []const u8,
        info: SourceInfo,
        file_path: []const u8,
    ) !PromptTemplate {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_description = try allocator.dupe(u8, description);
        errdefer allocator.free(owned_description);
        const owned_argument_hint = if (argument_hint) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_argument_hint) |value| allocator.free(value);
        const owned_content = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_content);
        const owned_file_path = try allocator.dupe(u8, file_path);
        errdefer allocator.free(owned_file_path);
        const owned_source_path = try allocator.dupe(u8, info.path);
        errdefer allocator.free(owned_source_path);
        const owned_source = try allocator.dupe(u8, info.source);
        errdefer allocator.free(owned_source);
        const owned_base_dir = if (info.base_dir) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_base_dir) |value| allocator.free(value);

        return .{
            .allocator = allocator,
            .name = owned_name,
            .description = owned_description,
            .argument_hint = owned_argument_hint,
            .content = owned_content,
            .source_info = .{
                .path = owned_source_path,
                .source = owned_source,
                .scope = info.scope,
                .origin = info.origin,
                .base_dir = owned_base_dir,
            },
            .file_path = owned_file_path,
        };
    }

    pub fn deinit(self: *PromptTemplate) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        if (self.argument_hint) |value| self.allocator.free(value);
        self.allocator.free(self.content);
        self.allocator.free(@constCast(self.source_info.path));
        self.allocator.free(@constCast(self.source_info.source));
        if (self.source_info.base_dir) |value| self.allocator.free(@constCast(value));
        self.allocator.free(self.file_path);
        self.* = undefined;
    }
};

pub const LoadPromptTemplatesOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    prompt_paths: []const []const u8 = &.{},
    include_defaults: bool = true,
    env: ?*const std.process.Environ.Map = null,
};

pub fn deinitPromptTemplates(allocator: std.mem.Allocator, templates: []PromptTemplate) void {
    for (templates) |*template| template.deinit();
    allocator.free(templates);
}

pub fn deinitCommandArgs(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

/// Parse command arguments with Pi's deliberately small bash-style quote
/// surface. Quotes group whitespace but backslashes remain literal.
pub fn parseCommandArgsAlloc(allocator: std.mem.Allocator, input: []const u8) ![][]u8 {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var quote: ?u8 = null;

    var index: usize = 0;
    while (index < input.len) {
        const width = utf8Width(input, index);
        const slice = input[index .. index + width];
        const byte = input[index];

        if (quote) |active_quote| {
            if (width == 1 and byte == active_quote) {
                quote = null;
            } else {
                try current.appendSlice(allocator, slice);
            }
        } else if (width == 1 and (byte == '"' or byte == '\'')) {
            quote = byte;
        } else if (isJsWhitespace(slice)) {
            if (current.items.len > 0) {
                try args.append(allocator, try current.toOwnedSlice(allocator));
            }
        } else {
            try current.appendSlice(allocator, slice);
        }
        index += width;
    }

    if (current.items.len > 0) {
        try args.append(allocator, try current.toOwnedSlice(allocator));
    }
    return args.toOwnedSlice(allocator);
}

/// Substitute placeholders in the same ordered passes as Pi. Replacement
/// values are not revisited by their own pass.
pub fn substituteArgsAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    args: []const []const u8,
) ![]u8 {
    const positional = try replacePositionalAlloc(allocator, content, args);
    defer allocator.free(positional);
    const slices = try replaceSlicesAlloc(allocator, positional, args);
    defer allocator.free(slices);
    const all_args = try joinArgsAlloc(allocator, args, 0, args.len);
    defer allocator.free(all_args);
    const arguments = try replaceLiteralAlloc(allocator, slices, "$ARGUMENTS", all_args);
    defer allocator.free(arguments);
    return replaceLiteralAlloc(allocator, arguments, "$@", all_args);
}

pub fn expandPromptTemplateAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    templates: []const PromptTemplate,
) ![]u8 {
    if (text.len < 2 or text[0] != '/') return allocator.dupe(u8, text);

    var name_end: usize = 1;
    while (name_end < text.len) {
        const width = utf8Width(text, name_end);
        if (isJsWhitespace(text[name_end .. name_end + width])) break;
        name_end += width;
    }
    if (name_end == 1) return allocator.dupe(u8, text);

    var args_start = name_end;
    while (args_start < text.len) {
        const width = utf8Width(text, args_start);
        if (!isJsWhitespace(text[args_start .. args_start + width])) break;
        args_start += width;
    }

    const name = text[1..name_end];
    for (templates) |template| {
        if (!std.mem.eql(u8, template.name, name)) continue;
        const args = try parseCommandArgsAlloc(allocator, text[args_start..]);
        defer deinitCommandArgs(allocator, args);
        return substituteArgsAlloc(allocator, template.content, args);
    }
    return allocator.dupe(u8, text);
}

pub fn loadPromptTemplatesAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadPromptTemplatesOptions,
) ![]PromptTemplate {
    const resolved_cwd = try paths.resolvePathAlloc(allocator, options.cwd, ".", .{
        .env = options.env,
    });
    defer allocator.free(resolved_cwd);
    const resolved_agent_dir = try paths.resolvePathAlloc(allocator, options.agent_dir, ".", .{
        .env = options.env,
    });
    defer allocator.free(resolved_agent_dir);
    const global_prompts_dir = try std.fs.path.join(allocator, &.{ resolved_agent_dir, "prompts" });
    defer allocator.free(global_prompts_dir);
    const project_prompts_dir = try std.fs.path.resolve(allocator, &.{ resolved_cwd, config.project_config_dir, "prompts" });
    defer allocator.free(project_prompts_dir);

    var templates: std.ArrayList(PromptTemplate) = .empty;
    errdefer deinitTemplateList(allocator, &templates);

    if (options.include_defaults) {
        try loadTemplatesFromDir(allocator, io, global_prompts_dir, global_prompts_dir, project_prompts_dir, &templates);
        try loadTemplatesFromDir(allocator, io, project_prompts_dir, global_prompts_dir, project_prompts_dir, &templates);
    }

    for (options.prompt_paths) |raw_path| {
        const resolved_path = paths.resolvePathAlloc(allocator, raw_path, resolved_cwd, .{
            .trim = true,
            .env = options.env,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer allocator.free(resolved_path);

        const stat = statPath(io, resolved_path) catch continue;
        if (stat.kind == .directory) {
            try loadTemplatesFromDir(allocator, io, resolved_path, global_prompts_dir, project_prompts_dir, &templates);
        } else if (stat.kind == .file and std.mem.endsWith(u8, resolved_path, ".md")) {
            const info = sourceInfoForPath(resolved_path, global_prompts_dir, project_prompts_dir);
            if (try loadTemplateFromFileAlloc(allocator, io, resolved_path, info)) |template| {
                try templates.append(allocator, template);
            }
        }
    }

    return templates.toOwnedSlice(allocator);
}

fn loadTemplatesFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    global_prompts_dir: []const u8,
    project_prompts_dir: []const u8,
    templates: *std.ArrayList(PromptTemplate),
) !void {
    var directory = openDirPath(io, directory_path, .{ .iterate = true }) catch return;
    defer directory.close(io);
    var iterator = directory.iterate();

    while (iterator.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const is_file = switch (entry.kind) {
            .file => true,
            .sym_link, .unknown => blk: {
                const stat = directory.statFile(io, entry.name, .{ .follow_symlinks = true }) catch break :blk false;
                break :blk stat.kind == .file;
            },
            else => false,
        };
        if (!is_file) continue;

        const file_path = try std.fs.path.join(allocator, &.{ directory_path, entry.name });
        defer allocator.free(file_path);
        const info = sourceInfoForPath(file_path, global_prompts_dir, project_prompts_dir);
        if (try loadTemplateFromFileAlloc(allocator, io, file_path, info)) |template| {
            try templates.append(allocator, template);
        }
    }
}

fn loadTemplateFromFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    info: SourceInfo,
) !?PromptTemplate {
    const raw_content = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        allocator,
        .unlimited,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(raw_content);

    var parsed = frontmatter.parseFrontmatterAlloc(allocator, raw_content) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();

    const base_name = std.fs.path.basename(file_path);
    const name = if (std.mem.endsWith(u8, base_name, ".md"))
        base_name[0 .. base_name.len - 3]
    else
        base_name;
    const frontmatter_description = parsed.getString("description");
    const fallback_description = if (frontmatter_description == null or frontmatter_description.?.len == 0)
        try firstBodyDescriptionAlloc(allocator, parsed.body)
    else
        null;
    defer if (fallback_description) |value| allocator.free(value);
    const description = if (frontmatter_description) |value|
        if (value.len > 0) value else fallback_description.?
    else
        fallback_description.?;
    const argument_hint = if (parsed.getString("argument-hint")) |value|
        if (value.len > 0) value else null
    else
        null;

    return try PromptTemplate.initAlloc(
        allocator,
        name,
        description,
        argument_hint,
        parsed.body,
        info,
        file_path,
    );
}

fn firstBodyDescriptionAlloc(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        const prefix_end = utf16PrefixEnd(line, 60);
        if (prefix_end == line.len) return allocator.dupe(u8, line);
        return std.mem.concat(allocator, u8, &.{ line[0..prefix_end], "..." });
    }
    return allocator.dupe(u8, "");
}

fn sourceInfoForPath(
    path: []const u8,
    global_prompts_dir: []const u8,
    project_prompts_dir: []const u8,
) SourceInfo {
    if (isUnderPath(path, global_prompts_dir)) {
        return source_info.createSyntheticSourceInfo(path, .{
            .source = "local",
            .scope = .user,
            .base_dir = global_prompts_dir,
        });
    }
    if (isUnderPath(path, project_prompts_dir)) {
        return source_info.createSyntheticSourceInfo(path, .{
            .source = "local",
            .scope = .project,
            .base_dir = project_prompts_dir,
        });
    }
    return source_info.createSyntheticSourceInfo(path, .{
        .source = "local",
        .base_dir = std.fs.path.dirname(path) orelse ".",
    });
}

fn isUnderPath(target: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, target, root)) return true;
    if (!std.mem.startsWith(u8, target, root)) return false;
    return target.len > root.len and target[root.len] == std.fs.path.sep;
}

fn statPath(io: std.Io, path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true });
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn replacePositionalAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    args: []const []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (index < content.len) {
        if (content[index] != '$' or index + 1 >= content.len or !std.ascii.isDigit(content[index + 1])) {
            try output.append(allocator, content[index]);
            index += 1;
            continue;
        }

        var end = index + 1;
        while (end < content.len and std.ascii.isDigit(content[end])) end += 1;
        const number = std.fmt.parseInt(usize, content[index + 1 .. end], 10) catch 0;
        if (number > 0 and number <= args.len) try output.appendSlice(allocator, args[number - 1]);
        index = end;
    }
    return output.toOwnedSlice(allocator);
}

fn replaceSlicesAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    args: []const []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;

    while (index < content.len) {
        const parsed = parseSlicePlaceholder(content, index) orelse {
            try output.append(allocator, content[index]);
            index += 1;
            continue;
        };
        const start = if (parsed.start == 0) 0 else parsed.start - 1;
        const end = if (parsed.length) |length|
            @min(args.len, std.math.add(usize, start, length) catch args.len)
        else
            args.len;
        try appendJoinedArgs(&output, allocator, args, @min(start, args.len), end);
        index = parsed.end;
    }
    return output.toOwnedSlice(allocator);
}

const ParsedSlicePlaceholder = struct {
    start: usize,
    length: ?usize,
    end: usize,
};

fn parseSlicePlaceholder(content: []const u8, index: usize) ?ParsedSlicePlaceholder {
    if (!std.mem.startsWith(u8, content[index..], "${@:")) return null;
    var cursor = index + 4;
    const start_begin = cursor;
    while (cursor < content.len and std.ascii.isDigit(content[cursor])) cursor += 1;
    if (cursor == start_begin) return null;
    const start = std.fmt.parseInt(usize, content[start_begin..cursor], 10) catch std.math.maxInt(usize);
    var length: ?usize = null;
    if (cursor < content.len and content[cursor] == ':') {
        cursor += 1;
        const length_begin = cursor;
        while (cursor < content.len and std.ascii.isDigit(content[cursor])) cursor += 1;
        if (cursor == length_begin) return null;
        length = std.fmt.parseInt(usize, content[length_begin..cursor], 10) catch std.math.maxInt(usize);
    }
    if (cursor >= content.len or content[cursor] != '}') return null;
    return .{ .start = start, .length = length, .end = cursor + 1 };
}

fn joinArgsAlloc(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    start: usize,
    end: usize,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try appendJoinedArgs(&output, allocator, args, start, end);
    return output.toOwnedSlice(allocator);
}

fn appendJoinedArgs(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    args: []const []const u8,
    start: usize,
    end: usize,
) !void {
    for (args[start..@min(end, args.len)], 0..) |arg, offset| {
        if (offset > 0) try output.append(allocator, ' ');
        try output.appendSlice(allocator, arg);
    }
}

fn replaceLiteralAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, content, index, needle)) |match_index| {
        try output.appendSlice(allocator, content[index..match_index]);
        try output.appendSlice(allocator, replacement);
        index = match_index + needle.len;
    }
    try output.appendSlice(allocator, content[index..]);
    return output.toOwnedSlice(allocator);
}

fn utf8Width(input: []const u8, index: usize) usize {
    const width = std.unicode.utf8ByteSequenceLength(input[index]) catch 1;
    return if (index + width <= input.len) width else 1;
}

fn utf16PrefixEnd(input: []const u8, max_units: usize) usize {
    var index: usize = 0;
    var units: usize = 0;
    while (index < input.len) {
        const width = utf8Width(input, index);
        const codepoint = std.unicode.utf8Decode(input[index .. index + width]) catch {
            if (units == max_units) break;
            units += 1;
            index += width;
            continue;
        };
        const codepoint_units: usize = if (codepoint > 0xFFFF) 2 else 1;
        if (units + codepoint_units > max_units) break;
        units += codepoint_units;
        index += width;
    }
    return index;
}

fn isJsWhitespace(slice: []const u8) bool {
    const codepoint = std.unicode.utf8Decode(slice) catch return false;
    return switch (codepoint) {
        0x0009...0x000D,
        0x0020,
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        0xFEFF,
        => true,
        else => false,
    };
}

fn deinitTemplateList(allocator: std.mem.Allocator, templates: *std.ArrayList(PromptTemplate)) void {
    for (templates.items) |*template| template.deinit();
    templates.deinit(allocator);
}

fn expectSubstitution(content: []const u8, args: []const []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try substituteArgsAlloc(allocator, content, args);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectParsedArgs(input: []const u8, expected: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try parseCommandArgsAlloc(allocator, input);
    defer deinitCommandArgs(allocator, actual);
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn findTemplate(templates: []PromptTemplate, name: []const u8) ?*PromptTemplate {
    for (templates) |*template| {
        if (std.mem.eql(u8, template.name, name)) return template;
    }
    return null;
}

test "substituteArgs ports wildcard positional and edge cases" {
    try expectSubstitution("Test: $ARGUMENTS", &.{ "a", "b", "c" }, "Test: a b c");
    try expectSubstitution("Test: $@", &.{ "a", "b", "c" }, "Test: a b c");
    try expectSubstitution("$ARGUMENTS", &.{ "$1", "$ARGUMENTS" }, "$1 $ARGUMENTS");
    try expectSubstitution("$@", &.{ "$100", "$1" }, "$100 $1");
    try expectSubstitution("$ARGUMENTS", &.{ "$100", "$1" }, "$100 $1");
    try expectSubstitution("$1: $ARGUMENTS", &.{ "prefix", "a", "b" }, "prefix: prefix a b");
    try expectSubstitution("$1: $@", &.{ "prefix", "a", "b" }, "prefix: prefix a b");
    try expectSubstitution("Test: $ARGUMENTS", &.{}, "Test: ");
    try expectSubstitution("Test: $@", &.{}, "Test: ");
    try expectSubstitution("Test: $1", &.{}, "Test: ");
    try expectSubstitution("$ARGUMENTS and $ARGUMENTS", &.{ "a", "b" }, "a b and a b");
    try expectSubstitution("$@ and $@", &.{ "a", "b" }, "a b and a b");
    try expectSubstitution("$@ and $ARGUMENTS", &.{ "a", "b" }, "a b and a b");
    try expectSubstitution("$1 $2: $ARGUMENTS", &.{ "arg100", "@user" }, "arg100 @user: arg100 @user");
    try expectSubstitution("$1 $2 $3 $4 $5", &.{ "a", "b" }, "a b   ");
    try expectSubstitution("$ARGUMENTS", &.{ "日本語", "🎉", "café" }, "日本語 🎉 café");
    try expectSubstitution("$1 $2", &.{ "line1\nline2", "tab\tthere" }, "line1\nline2 tab\tthere");
    try expectSubstitution("$1$2", &.{ "a", "b" }, "ab");
    try expectSubstitution("$ARGUMENTS", &.{ "first arg", "second arg" }, "first arg second arg");
    try expectSubstitution("Test: $ARGUMENTS", &.{"only"}, "Test: only");
    try expectSubstitution("Test: $@", &.{"only"}, "Test: only");
    try expectSubstitution("$0", &.{ "a", "b" }, "");
    try expectSubstitution("$1.5", &.{"a"}, "a.5");
    try expectSubstitution("pre$ARGUMENTS", &.{ "a", "b" }, "prea b");
    try expectSubstitution("pre$@", &.{ "a", "b" }, "prea b");
    try expectSubstitution("$ARGUMENTS", &.{ "a", "", "c" }, "a  c");
    try expectSubstitution("$ARGUMENTS", &.{ "  leading  ", "trailing  " }, "  leading   trailing  ");
    try expectSubstitution("Prefix $ARGUMENTS suffix", &.{"ARGUMENTS"}, "Prefix ARGUMENTS suffix");
    try expectSubstitution("$A $$ $ $ARGS", &.{"a"}, "$A $$ $ $ARGS");
    try expectSubstitution("$arguments $Arguments $ARGUMENTS", &.{ "a", "b" }, "$arguments $Arguments a b");
    try expectSubstitution("$@ and $ARGUMENTS", &.{ "x", "y", "z" }, "x y z and x y z");
    try expectSubstitution("$ARGUMENTS and $@", &.{ "x", "y", "z" }, "x y z and x y z");
    try expectSubstitution("$1 $2 $3", &.{ "a", "b", "c" }, "a b c");
    try expectSubstitution(
        "$10 $12 $15",
        &.{ "val0", "val1", "val2", "val3", "val4", "val5", "val6", "val7", "val8", "val9", "val10", "val11", "val12", "val13", "val14" },
        "val9 val11 val14",
    );
    try expectSubstitution("Price: \\$100", &.{}, "Price: \\");
    try expectSubstitution("$1: $@ ($ARGUMENTS)", &.{ "first", "second", "third" }, "first: first second third (first second third)");
    try expectSubstitution("Just plain text", &.{ "a", "b" }, "Just plain text");
    try expectSubstitution("$1 $2 $@", &.{ "a", "b", "c" }, "a b a b c");

    var long_args: [100][]const u8 = undefined;
    var owned: [100][8]u8 = undefined;
    for (&long_args, &owned, 0..) |*arg, *buffer, index| {
        arg.* = try std.fmt.bufPrint(buffer, "arg{d}", .{index});
    }
    const long_joined = try joinArgsAlloc(std.testing.allocator, &long_args, 0, long_args.len);
    defer std.testing.allocator.free(long_joined);
    try expectSubstitution("$ARGUMENTS", &long_args, long_joined);
}

test "substituteArgs ports bash-style array slicing" {
    try expectSubstitution("${@:2}", &.{ "a", "b", "c", "d" }, "b c d");
    try expectSubstitution("${@:1}", &.{ "a", "b", "c" }, "a b c");
    try expectSubstitution("${@:3}", &.{ "a", "b", "c", "d" }, "c d");
    try expectSubstitution("${@:2:2}", &.{ "a", "b", "c", "d" }, "b c");
    try expectSubstitution("${@:1:1}", &.{ "a", "b", "c" }, "a");
    try expectSubstitution("${@:3:1}", &.{ "a", "b", "c", "d" }, "c");
    try expectSubstitution("${@:2:3}", &.{ "a", "b", "c", "d", "e" }, "b c d");
    try expectSubstitution("${@:99}", &.{ "a", "b" }, "");
    try expectSubstitution("${@:5}", &.{ "a", "b" }, "");
    try expectSubstitution("${@:10:5}", &.{ "a", "b" }, "");
    try expectSubstitution("${@:2:0}", &.{ "a", "b", "c" }, "");
    try expectSubstitution("${@:1:0}", &.{ "a", "b" }, "");
    try expectSubstitution("${@:2:99}", &.{ "a", "b", "c" }, "b c");
    try expectSubstitution("${@:1:10}", &.{ "a", "b" }, "a b");
    try expectSubstitution("${@:2} vs $@", &.{ "a", "b", "c" }, "b c vs a b c");
    try expectSubstitution("First: ${@:1:1}, All: $@", &.{ "x", "y", "z" }, "First: x, All: x y z");
    try expectSubstitution("${@:1}", &.{ "${@:2}", "test" }, "${@:2} test");
    try expectSubstitution("${@:2}", &.{ "a", "${@:3}", "c" }, "${@:3} c");
    try expectSubstitution("$1: ${@:2}", &.{ "cmd", "arg1", "arg2" }, "cmd: arg1 arg2");
    try expectSubstitution("$1 $2 ${@:3}", &.{ "a", "b", "c", "d" }, "a b c d");
    try expectSubstitution("${@:0}", &.{ "a", "b", "c" }, "a b c");
    try expectSubstitution("${@:2}", &.{}, "");
    try expectSubstitution("${@:1}", &.{}, "");
    try expectSubstitution("${@:1}", &.{"only"}, "only");
    try expectSubstitution("${@:2}", &.{"only"}, "");
    try expectSubstitution("Process ${@:2} with $1", &.{ "tool", "file1", "file2" }, "Process file1 file2 with tool");
    try expectSubstitution("${@:1:1} and ${@:2}", &.{ "a", "b", "c" }, "a and b c");
    try expectSubstitution("${@:1:2} vs ${@:3:2}", &.{ "a", "b", "c", "d", "e" }, "a b vs c d");
    try expectSubstitution("${@:2}", &.{ "cmd", "first arg", "second arg" }, "first arg second arg");
    try expectSubstitution("${@:2}", &.{ "cmd", "$100", "@user", "#tag" }, "$100 @user #tag");
    try expectSubstitution("${@:1}", &.{ "日本語", "🎉", "café" }, "日本語 🎉 café");
    try expectSubstitution(
        "Run $1 on ${@:2:2}, then process $@",
        &.{ "eslint", "file1.ts", "file2.ts", "file3.ts" },
        "Run eslint on file1.ts file2.ts, then process eslint file1.ts file2.ts file3.ts",
    );
    try expectSubstitution("prefix${@:2}suffix", &.{ "a", "b", "c" }, "prefixb csuffix");
    try expectSubstitution(
        "${@:5:100}",
        &.{ "arg1", "arg2", "arg3", "arg4", "arg5", "arg6", "arg7", "arg8", "arg9", "arg10" },
        "arg5 arg6 arg7 arg8 arg9 arg10",
    );
}

test "parseCommandArgs ports quote whitespace special character and unicode cases" {
    try expectParsedArgs("a b c", &.{ "a", "b", "c" });
    try expectParsedArgs("\"first arg\" second", &.{ "first arg", "second" });
    try expectParsedArgs("'first arg' second", &.{ "first arg", "second" });
    try expectParsedArgs("\"double\" 'single' \"double again\"", &.{ "double", "single", "double again" });
    try expectParsedArgs("", &.{});
    try expectParsedArgs("a  b   c", &.{ "a", "b", "c" });
    try expectParsedArgs("a\tb\tc", &.{ "a", "b", "c" });
    try expectParsedArgs("\"\" \" \"", &.{" "});
    try expectParsedArgs("$100 @user #tag", &.{ "$100", "@user", "#tag" });
    try expectParsedArgs("日本語 🎉 café", &.{ "日本語", "🎉", "café" });
    try expectParsedArgs("\"line1\nline2\" second", &.{ "line1\nline2", "second" });
    try expectParsedArgs("label-2\n\nHere is some description #2.", &.{ "label-2", "Here", "is", "some", "description", "#2." });
    try expectParsedArgs("a\n\n\tb  c", &.{ "a", "b", "c" });
    try expectParsedArgs("\"quoted \\\"text\\\"\"", &.{"quoted \\text\\"});
    try expectParsedArgs("a b c   ", &.{ "a", "b", "c" });
    try expectParsedArgs("   a b c", &.{ "a", "b", "c" });
}

test "expandPromptTemplate ports multiline command integration" {
    const allocator = std.testing.allocator;
    var multiline_template = try PromptTemplate.initAlloc(
        allocator,
        "arg-test",
        "test",
        null,
        "- arg1: $1\n- rest: ${@:2}",
        source_info.createSyntheticSourceInfo("/tmp/arg-test.md", .{ .source = "local" }),
        "/tmp/arg-test.md",
    );
    defer multiline_template.deinit();

    const multiline = try expandPromptTemplateAlloc(
        allocator,
        "/arg-test label-2\n\nHere is some description #2.",
        &.{multiline_template},
    );
    defer allocator.free(multiline);
    try std.testing.expectEqualStrings("- arg1: label-2\n- rest: Here is some description #2.", multiline);

    var newline_template = try PromptTemplate.initAlloc(
        allocator,
        "arg-test",
        "test",
        null,
        "arg1: $1",
        source_info.createSyntheticSourceInfo("/tmp/arg-test.md", .{ .source = "local" }),
        "/tmp/arg-test.md",
    );
    defer newline_template.deinit();

    const newline = try expandPromptTemplateAlloc(allocator, "/arg-test\nlabel-2", &.{newline_template});
    defer allocator.free(newline);
    try std.testing.expectEqualStrings("arg1: label-2", newline);
}

test "parseCommandArgs and substituteArgs port upstream integration examples" {
    const allocator = std.testing.allocator;
    const args = try parseCommandArgsAlloc(allocator, "Button \"onClick handler\" \"disabled support\"");
    defer deinitCommandArgs(allocator, args);

    const component = try substituteArgsAlloc(allocator, "Create component $1 with features: $ARGUMENTS", args);
    defer allocator.free(component);
    try std.testing.expectEqualStrings(
        "Create component Button with features: Button onClick handler disabled support",
        component,
    );

    const readme = try substituteArgsAlloc(allocator, "Create a React component named $1 with features: $ARGUMENTS", args);
    defer allocator.free(readme);
    try std.testing.expectEqualStrings(
        "Create a React component named Button with features: Button onClick handler disabled support",
        readme,
    );

    const feature_args = try parseCommandArgsAlloc(allocator, "feature1 feature2 feature3");
    defer deinitCommandArgs(allocator, feature_args);
    const at_result = try substituteArgsAlloc(allocator, "Implement: $@", feature_args);
    defer allocator.free(at_result);
    const arguments_result = try substituteArgsAlloc(allocator, "Implement: $ARGUMENTS", feature_args);
    defer allocator.free(arguments_result);
    try std.testing.expectEqualStrings(at_result, arguments_result);
}

test "loadPromptTemplates ports argument-hint frontmatter cases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(test_dir);

    try tmp.dir.writeFile(io, .{
        .sub_path = "pr.md",
        .data =
        \\---
        \\description: Review PRs from URLs with structured issue and code analysis
        \\argument-hint: "<PR-URL>"
        \\---
        \\You are given one or more GitHub PR URLs: $@
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "wr.md",
        .data =
        \\---
        \\description: Finish the current task end-to-end with changelog, commit, and push
        \\argument-hint: "[instructions]"
        \\---
        \\Wrap it. Additional instructions: $ARGUMENTS
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "cl.md",
        .data =
        \\---
        \\description: Audit changelog entries before release
        \\---
        \\Audit changelog entries for all commits since the last release.
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "empty-hint.md",
        .data =
        \\---
        \\description: A command with empty hint
        \\argument-hint: ""
        \\---
        \\Do something
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "is.md",
        .data =
        \\---
        \\description: Analyze GitHub issues (bugs or feature requests)
        \\argument-hint: "<issue>"
        \\---
        \\Analyze GitHub issue(s): $ARGUMENTS
        ,
    });

    const templates = try loadPromptTemplatesAlloc(allocator, io, .{
        .cwd = test_dir,
        .agent_dir = test_dir,
        .prompt_paths = &.{test_dir},
        .include_defaults = false,
    });
    defer deinitPromptTemplates(allocator, templates);

    const pr = findTemplate(templates, "pr") orelse return error.MissingTemplate;
    try std.testing.expectEqualStrings("<PR-URL>", pr.argument_hint.?);
    try std.testing.expectEqualStrings("Review PRs from URLs with structured issue and code analysis", pr.description);

    const wr = findTemplate(templates, "wr") orelse return error.MissingTemplate;
    try std.testing.expectEqualStrings("[instructions]", wr.argument_hint.?);
    try std.testing.expectEqualStrings("Finish the current task end-to-end with changelog, commit, and push", wr.description);

    const cl = findTemplate(templates, "cl") orelse return error.MissingTemplate;
    try std.testing.expect(cl.argument_hint == null);

    const empty_hint = findTemplate(templates, "empty-hint") orelse return error.MissingTemplate;
    try std.testing.expect(empty_hint.argument_hint == null);

    const issue = findTemplate(templates, "is") orelse return error.MissingTemplate;
    try std.testing.expectEqualStrings("<issue>", issue.argument_hint.?);
}
