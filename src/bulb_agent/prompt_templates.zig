const std = @import("std");
const frontmatter = @import("frontmatter.zig");
const types = @import("types.zig");

pub const PromptTemplate = types.PromptTemplate;
pub const PromptTemplateDiagnosticCode = types.PromptTemplateDiagnosticCode;

pub const PromptTemplateDiagnostic = struct {
    allocator: std.mem.Allocator,
    type: []const u8 = "warning",
    code: PromptTemplateDiagnosticCode,
    message: []u8,
    path: []u8,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        code: PromptTemplateDiagnosticCode,
        message: []const u8,
        path: []const u8,
    ) !PromptTemplateDiagnostic {
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

    pub fn deinit(self: *PromptTemplateDiagnostic) void {
        self.allocator.free(self.message);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

pub const LoadPromptTemplatesOptions = struct {
    cwd: []const u8 = ".",
    paths: []const []const u8,
};

pub const LoadPromptTemplatesResult = struct {
    allocator: std.mem.Allocator,
    prompt_templates: []PromptTemplate,
    diagnostics: []PromptTemplateDiagnostic,

    pub fn deinit(self: *LoadPromptTemplatesResult) void {
        for (self.prompt_templates) |*template| template.deinit();
        self.allocator.free(self.prompt_templates);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit();
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const SourcedPromptTemplateInput = struct {
    path: []const u8,
    source: []const u8,
};

pub const SourcedPromptTemplate = struct {
    allocator: std.mem.Allocator,
    prompt_template: PromptTemplate,
    source: []u8,

    pub fn deinit(self: *SourcedPromptTemplate) void {
        self.prompt_template.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

pub const SourcedPromptTemplateDiagnostic = struct {
    allocator: std.mem.Allocator,
    diagnostic: PromptTemplateDiagnostic,
    source: []u8,

    pub fn deinit(self: *SourcedPromptTemplateDiagnostic) void {
        self.diagnostic.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }
};

pub const LoadSourcedPromptTemplatesResult = struct {
    allocator: std.mem.Allocator,
    prompt_templates: []SourcedPromptTemplate,
    diagnostics: []SourcedPromptTemplateDiagnostic,

    pub fn deinit(self: *LoadSourcedPromptTemplatesResult) void {
        for (self.prompt_templates) |*template| template.deinit();
        self.allocator.free(self.prompt_templates);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit();
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub fn loadPromptTemplatesAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadPromptTemplatesOptions,
) !LoadPromptTemplatesResult {
    var prompt_templates: std.ArrayList(PromptTemplate) = .empty;
    errdefer deinitPromptTemplateList(allocator, &prompt_templates);
    var diagnostics: std.ArrayList(PromptTemplateDiagnostic) = .empty;
    errdefer deinitDiagnosticList(allocator, &diagnostics);

    for (options.paths) |input_path| {
        const resolved_path = try resolvePathAlloc(allocator, options.cwd, input_path);
        defer allocator.free(resolved_path);

        const stat = statPath(io, resolved_path) catch continue;
        switch (stat.kind) {
            .directory => try loadTemplatesFromDir(allocator, io, resolved_path, &prompt_templates, &diagnostics),
            .file => if (std.ascii.endsWithIgnoreCase(resolved_path, ".md")) {
                if (try loadTemplateFromFileAlloc(allocator, io, resolved_path, &diagnostics)) |template| {
                    try prompt_templates.append(allocator, template);
                }
            },
            else => {},
        }
    }

    return .{
        .allocator = allocator,
        .prompt_templates = try prompt_templates.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn loadSourcedPromptTemplatesAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    inputs: []const SourcedPromptTemplateInput,
) !LoadSourcedPromptTemplatesResult {
    var prompt_templates: std.ArrayList(SourcedPromptTemplate) = .empty;
    errdefer deinitSourcedPromptTemplateList(allocator, &prompt_templates);
    var diagnostics: std.ArrayList(SourcedPromptTemplateDiagnostic) = .empty;
    errdefer deinitSourcedDiagnosticList(allocator, &diagnostics);

    for (inputs) |input| {
        var result = try loadPromptTemplatesAlloc(allocator, io, .{
            .cwd = cwd,
            .paths = &.{input.path},
        });
        defer result.deinit();

        for (result.prompt_templates) |*template| {
            try prompt_templates.append(allocator, .{
                .allocator = allocator,
                .prompt_template = try PromptTemplate.initAlloc(
                    allocator,
                    template.name,
                    template.description,
                    template.content,
                ),
                .source = try allocator.dupe(u8, input.source),
            });
        }
        for (result.diagnostics) |*diagnostic| {
            try diagnostics.append(allocator, .{
                .allocator = allocator,
                .diagnostic = try PromptTemplateDiagnostic.initAlloc(
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
        .prompt_templates = try prompt_templates.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn deinitCommandArgs(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

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

pub fn formatPromptTemplateInvocationAlloc(
    allocator: std.mem.Allocator,
    template: PromptTemplate,
    args: []const []const u8,
) ![]u8 {
    return substituteArgsAlloc(allocator, template.content, args);
}

fn loadTemplatesFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    templates: *std.ArrayList(PromptTemplate),
    diagnostics: *std.ArrayList(PromptTemplateDiagnostic),
) !void {
    var directory = openDirPath(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendDiagnosticFmt(allocator, diagnostics, .list_failed, dir_path, "{s}", .{@errorName(err)});
        return;
    };
    defer directory.close(io);

    const names = try readSortedEntryNames(allocator, io, &directory);
    defer freeStringList(allocator, names);

    for (names) |name| {
        if (!std.ascii.endsWithIgnoreCase(name, ".md")) continue;
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(file_path);
        const stat = statPath(io, file_path) catch continue;
        if (stat.kind != .file) continue;
        if (try loadTemplateFromFileAlloc(allocator, io, file_path, diagnostics)) |template| {
            try templates.append(allocator, template);
        }
    }
}

fn loadTemplateFromFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    diagnostics: *std.ArrayList(PromptTemplateDiagnostic),
) !?PromptTemplate {
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

    const base_name = std.fs.path.basename(file_path);
    const name = stripMarkdownExtension(base_name);
    const description = if (parsed.description) |description|
        description
    else
        try firstBodyDescriptionAlloc(allocator, parsed.body);
    defer if (parsed.description == null) allocator.free(description);

    return try PromptTemplate.initAlloc(allocator, name, description, parsed.body);
}

fn firstBodyDescriptionAlloc(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (line.len <= 60) return allocator.dupe(u8, line);
        return std.mem.concat(allocator, u8, &.{ line[0..60], "..." });
    }
    return allocator.dupe(u8, "");
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

fn resolvePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn statPath(io: std.Io, path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true });
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

fn stripMarkdownExtension(base_name: []const u8) []const u8 {
    if (base_name.len >= 3 and std.ascii.eqlIgnoreCase(base_name[base_name.len - 3 ..], ".md")) {
        return base_name[0 .. base_name.len - 3];
    }
    return base_name;
}

fn utf8Width(input: []const u8, index: usize) usize {
    const width = std.unicode.utf8ByteSequenceLength(input[index]) catch 1;
    return if (index + width <= input.len) width else 1;
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

fn appendDiagnosticFmt(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(PromptTemplateDiagnostic),
    code: PromptTemplateDiagnosticCode,
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try diagnostics.append(allocator, try PromptTemplateDiagnostic.initAlloc(allocator, code, message, path));
}

fn deinitPromptTemplateList(allocator: std.mem.Allocator, templates: *std.ArrayList(PromptTemplate)) void {
    for (templates.items) |*template| template.deinit();
    templates.deinit(allocator);
}

fn deinitDiagnosticList(allocator: std.mem.Allocator, diagnostics: *std.ArrayList(PromptTemplateDiagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit();
    diagnostics.deinit(allocator);
}

fn deinitSourcedPromptTemplateList(
    allocator: std.mem.Allocator,
    templates: *std.ArrayList(SourcedPromptTemplate),
) void {
    for (templates.items) |*template| template.deinit();
    templates.deinit(allocator);
}

fn deinitSourcedDiagnosticList(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(SourcedPromptTemplateDiagnostic),
) void {
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

test "loadPromptTemplates loads markdown templates non-recursively from one or more dirs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const a_one = try std.fs.path.join(allocator, &.{ root, "a", "one.md" });
    defer allocator.free(a_one);
    const nested_ignored = try std.fs.path.join(allocator, &.{ root, "a", "nested", "ignored.md" });
    defer allocator.free(nested_ignored);
    const b_two = try std.fs.path.join(allocator, &.{ root, "b", "two.md" });
    defer allocator.free(b_two);
    try writeFile(a_one, "---\ndescription: One template\n---\nHello $1");
    try writeFile(nested_ignored, "Ignored");
    try writeFile(b_two, "First line description\nBody");

    var result = try loadPromptTemplatesAlloc(allocator, io, .{ .cwd = root, .paths = &.{ "a", "b" } });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), result.prompt_templates.len);
    try std.testing.expectEqualStrings("one", result.prompt_templates[0].name);
    try std.testing.expectEqualStrings("One template", result.prompt_templates[0].description);
    try std.testing.expectEqualStrings("Hello $1", result.prompt_templates[0].content);
    try std.testing.expectEqualStrings("two", result.prompt_templates[1].name);
    try std.testing.expectEqualStrings("First line description", result.prompt_templates[1].description);
    try std.testing.expectEqualStrings("First line description\nBody", result.prompt_templates[1].content);
}

test "loadSourcedPromptTemplates preserves source info and attaches it to diagnostics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const example = try std.fs.path.join(allocator, &.{ root, "prompts", "example.md" });
    defer allocator.free(example);
    const broken = try std.fs.path.join(allocator, &.{ root, "broken.md" });
    defer allocator.free(broken);
    try writeFile(example, "---\ndescription: Example\n---\nExample body");
    try writeFile(broken, "---\ndescription: [unterminated\n---\nBody");

    var sourced = try loadSourcedPromptTemplatesAlloc(allocator, io, root, &.{
        .{ .path = "prompts", .source = "project" },
    });
    defer sourced.deinit();
    try std.testing.expectEqual(@as(usize, 0), sourced.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 1), sourced.prompt_templates.len);
    try std.testing.expectEqualStrings("example", sourced.prompt_templates[0].prompt_template.name);
    try std.testing.expectEqualStrings("project", sourced.prompt_templates[0].source);

    var with_diagnostic = try loadSourcedPromptTemplatesAlloc(allocator, io, root, &.{
        .{ .path = "broken.md", .source = "user" },
    });
    defer with_diagnostic.deinit();
    try std.testing.expectEqual(@as(usize, 0), with_diagnostic.prompt_templates.len);
    try std.testing.expectEqual(@as(usize, 1), with_diagnostic.diagnostics.len);
    try std.testing.expectEqual(PromptTemplateDiagnosticCode.parse_failed, with_diagnostic.diagnostics[0].diagnostic.code);
    try std.testing.expectEqualStrings("user", with_diagnostic.diagnostics[0].source);
}

test "loadPromptTemplates loads explicit markdown files and symlinked files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const target = try std.fs.path.join(allocator, &.{ root, "target.md" });
    defer allocator.free(target);
    const link = try std.fs.path.join(allocator, &.{ root, "link.md" });
    defer allocator.free(link);
    try writeFile(target, "---\ndescription: Target\n---\nTarget body");
    try std.Io.Dir.cwd().symLink(io, target, link, .{});

    var result = try loadPromptTemplatesAlloc(allocator, io, .{ .cwd = root, .paths = &.{ "target.md", "link.md" } });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.prompt_templates.len);
    try std.testing.expectEqualStrings("target", result.prompt_templates[0].name);
    try std.testing.expectEqualStrings("Target", result.prompt_templates[0].description);
    try std.testing.expectEqualStrings("Target body", result.prompt_templates[0].content);
    try std.testing.expectEqualStrings("link", result.prompt_templates[1].name);
    try std.testing.expectEqualStrings("Target", result.prompt_templates[1].description);
}

test "formatPromptTemplateInvocation substitutes command arguments" {
    const allocator = std.testing.allocator;
    var template = try PromptTemplate.initAlloc(allocator, "one", "", "$1 ${@:2} $ARGUMENTS");
    defer template.deinit();
    const rendered = try formatPromptTemplateInvocationAlloc(allocator, template, &.{ "hello world", "test" });
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("hello world test hello world test", rendered);
}
