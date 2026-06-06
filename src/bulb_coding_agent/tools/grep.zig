const std = @import("std");
const builtin = @import("builtin");

const keybindings = @import("../keybindings.zig");
const path_utils = @import("../path_utils.zig");
const render_utils = @import("render_utils.zig");
const truncate = @import("truncate.zig");

pub const DEFAULT_LIMIT: usize = 100;

const default_ignore_patterns = [_][]const u8{
    "**/node_modules/**",
    "**/.git/**",
};

pub const GrepToolInput = struct {
    pattern: ?[]const u8 = null,
    path: ?[]const u8 = null,
    glob: ?[]const u8 = null,
    ignore_case: ?bool = null,
    literal: ?bool = null,
    context: ?usize = null,
    limit: ?usize = null,
};

pub const GrepOperations = struct {
    ptr: ?*anyopaque = null,
    is_directory_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!bool = defaultIsDirectory,
    read_file_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror![]u8 = defaultReadFile,

    pub fn isDirectory(self: GrepOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !bool {
        return self.is_directory_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn readFile(self: GrepOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
        return self.read_file_fn(self.ptr, allocator, io, absolute_path);
    }
};

pub const GrepToolOptions = struct {
    operations: GrepOperations = .{},
    home_dir: ?[]const u8 = null,
};

pub const GrepToolDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    match_limit_reached: ?usize = null,
    lines_truncated: bool = false,

    pub fn hasDetails(self: GrepToolDetails) bool {
        return self.truncation != null or self.match_limit_reached != null or self.lines_truncated;
    }

    pub fn deinit(self: *GrepToolDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const GrepToolResult = struct {
    text: []u8,
    details: ?GrepToolDetails = null,

    pub fn deinit(self: *GrepToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: GrepToolInput,
    options: GrepToolOptions,
) !GrepToolResult {
    const pattern = input.pattern orelse return error.InvalidPattern;
    if (input.glob) |glob| try validateGlob(glob);

    const requested_path = input.path orelse ".";
    const search_path = try path_utils.resolveToCwdAlloc(allocator, requested_path, cwd, options.home_dir);
    defer allocator.free(search_path);

    const ops = options.operations;
    const is_directory = ops.isDirectory(allocator, io, search_path) catch return error.PathNotFound;
    const effective_limit = @max(@as(usize, 1), input.limit orelse DEFAULT_LIMIT);
    const context_value = if (input.context) |value| if (value > 0) value else 0 else 0;

    const matcher = Matcher{
        .pattern = pattern,
        .ignore_case = input.ignore_case orelse false,
        .literal = input.literal orelse false,
    };

    var search = SearchContext{
        .allocator = allocator,
        .io = io,
        .operations = ops,
        .search_path = search_path,
        .is_directory = is_directory,
        .glob = input.glob,
        .matcher = matcher,
        .context_value = context_value,
        .effective_limit = effective_limit,
    };
    defer search.deinit();

    try search.run();
    return search.finishAlloc();
}

pub fn formatGrepCallAlloc(
    allocator: std.mem.Allocator,
    args: ?GrepToolInput,
    theme: render_utils.RenderTheme,
    options: GrepToolOptions,
) ![]u8 {
    const input = args orelse GrepToolInput{};
    const pattern = input.pattern orelse "";
    const raw_path = input.path orelse "";
    const path_source = if (raw_path.len > 0) raw_path else ".";
    const path = try render_utils.shortenPathAlloc(allocator, path_source, options.home_dir);
    defer allocator.free(path);

    const title_bold = try theme.boldAlloc(allocator, "grep");
    defer allocator.free(title_bold);
    const title = try theme.fgAlloc(allocator, .tool_title, title_bold);
    defer allocator.free(title);
    const pattern_text = try std.fmt.allocPrint(allocator, "/{s}/", .{pattern});
    defer allocator.free(pattern_text);
    const styled_pattern = try theme.fgAlloc(allocator, .accent, pattern_text);
    defer allocator.free(styled_pattern);
    const in_path = try std.fmt.allocPrint(allocator, " in {s}", .{path});
    defer allocator.free(in_path);
    const styled_path = try theme.fgAlloc(allocator, .tool_output, in_path);
    defer allocator.free(styled_path);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.print(allocator, "{s} {s}{s}", .{ title, styled_pattern, styled_path });

    if (input.glob) |glob| {
        if (glob.len > 0) {
            const glob_text = try std.fmt.allocPrint(allocator, " ({s})", .{glob});
            defer allocator.free(glob_text);
            const styled_glob = try theme.fgAlloc(allocator, .tool_output, glob_text);
            defer allocator.free(styled_glob);
            try output.appendSlice(allocator, styled_glob);
        }
    }
    if (input.limit) |limit| {
        const limit_text = try std.fmt.allocPrint(allocator, " limit {d}", .{limit});
        defer allocator.free(limit_text);
        const styled_limit = try theme.fgAlloc(allocator, .tool_output, limit_text);
        defer allocator.free(styled_limit);
        try output.appendSlice(allocator, styled_limit);
    }

    return output.toOwnedSlice(allocator);
}

pub fn formatGrepResultAlloc(
    allocator: std.mem.Allocator,
    result: GrepToolResult,
    options: render_utils.ToolRenderResultOptions,
    theme: render_utils.RenderTheme,
    show_images: bool,
) ![]u8 {
    const blocks = [_]render_utils.ToolContentBlock{render_utils.textBlock(result.text)};
    const text_output = try render_utils.getTextOutputAlloc(allocator, .{ .content = &blocks }, show_images);
    defer allocator.free(text_output);
    const trimmed = std.mem.trim(u8, text_output, " \t\r\n");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    if (trimmed.len > 0) {
        const lines = try splitLinesAlloc(allocator, trimmed);
        defer allocator.free(lines);
        const max_lines = if (options.expanded) lines.len else @min(lines.len, 15);
        try output.append(allocator, '\n');
        for (lines[0..max_lines], 0..) |line, index| {
            if (index > 0) try output.append(allocator, '\n');
            const styled = try theme.fgAlloc(allocator, .tool_output, line);
            defer allocator.free(styled);
            try output.appendSlice(allocator, styled);
        }

        const remaining = lines.len - max_lines;
        if (remaining > 0) {
            const prefix = try std.fmt.allocPrint(allocator, "\n... ({d} more lines,", .{remaining});
            defer allocator.free(prefix);
            const styled_prefix = try theme.fgAlloc(allocator, .muted, prefix);
            defer allocator.free(styled_prefix);
            const hint = try keyHintAlloc(allocator, theme, "app.tools.expand", "to expand");
            defer allocator.free(hint);
            try output.print(allocator, "{s} {s})", .{ styled_prefix, hint });
        }
    }

    if (result.details) |details| {
        if (details.match_limit_reached != null or
            (details.truncation != null and details.truncation.?.truncated) or
            details.lines_truncated)
        {
            var warnings: std.ArrayList([]u8) = .empty;
            defer {
                for (warnings.items) |warning| allocator.free(warning);
                warnings.deinit(allocator);
            }

            if (details.match_limit_reached) |limit| {
                try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{d} matches limit", .{limit}));
            }
            if (details.truncation) |truncation_result| {
                if (truncation_result.truncated) {
                    const size = try truncate.formatSizeAlloc(allocator, truncation_result.max_bytes);
                    defer allocator.free(size);
                    try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{s} limit", .{size}));
                }
            }
            if (details.lines_truncated) {
                try warnings.append(allocator, try allocator.dupe(u8, "some lines truncated"));
            }

            const warning_text = try joinWithSeparatorAlloc(allocator, warnings.items, ", ");
            defer allocator.free(warning_text);
            const bracketed = try std.fmt.allocPrint(allocator, "[Truncated: {s}]", .{warning_text});
            defer allocator.free(bracketed);
            const styled = try theme.fgAlloc(allocator, .warning, bracketed);
            defer allocator.free(styled);
            try output.print(allocator, "\n{s}", .{styled});
        }
    }

    return output.toOwnedSlice(allocator);
}

const SearchContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    operations: GrepOperations,
    search_path: []const u8,
    is_directory: bool,
    glob: ?[]const u8,
    matcher: Matcher,
    context_value: usize,
    effective_limit: usize,
    output_lines: std.ArrayList([]u8) = .empty,
    ignore_rules: std.ArrayList(IgnoreRule) = .empty,
    match_count: usize = 0,
    match_limit_reached: bool = false,
    lines_truncated: bool = false,
    stopped: bool = false,

    fn deinit(self: *SearchContext) void {
        for (self.output_lines.items) |line| self.allocator.free(line);
        self.output_lines.deinit(self.allocator);
        self.freeIgnoreRulesFrom(0);
        self.ignore_rules.deinit(self.allocator);
    }

    fn run(self: *SearchContext) !void {
        if (self.is_directory) {
            try self.walkDir(self.search_path, "");
        } else {
            const display_name = basename(self.search_path);
            if (try self.fileMatchesGlob(display_name, self.search_path)) {
                try self.processFile(self.search_path, display_name);
            }
        }
    }

    fn finishAlloc(self: *SearchContext) !GrepToolResult {
        if (self.match_count == 0) {
            return .{ .text = try self.allocator.dupe(u8, "No matches found") };
        }

        const raw_output = try joinLinesAlloc(self.allocator, self.output_lines.items);
        defer self.allocator.free(raw_output);

        var truncation_result = try truncate.truncateHeadAlloc(self.allocator, raw_output, .{
            .max_lines = std.math.maxInt(usize),
        });
        var truncation_moved = false;
        defer if (!truncation_moved) truncation_result.deinit(self.allocator);

        var details: GrepToolDetails = .{};
        errdefer details.deinit(self.allocator);

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, truncation_result.content);

        var notices: std.ArrayList([]u8) = .empty;
        defer {
            for (notices.items) |notice| self.allocator.free(notice);
            notices.deinit(self.allocator);
        }

        if (self.match_limit_reached) {
            try notices.append(
                self.allocator,
                try std.fmt.allocPrint(
                    self.allocator,
                    "{d} matches limit reached. Use limit={d} for more, or refine pattern",
                    .{ self.effective_limit, self.effective_limit *| 2 },
                ),
            );
            details.match_limit_reached = self.effective_limit;
        }

        if (truncation_result.truncated) {
            const size = try truncate.formatSizeAlloc(self.allocator, truncate.DEFAULT_MAX_BYTES);
            defer self.allocator.free(size);
            try notices.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} limit reached", .{size}));
            details.truncation = truncation_result;
            truncation_moved = true;
        }

        if (self.lines_truncated) {
            try notices.append(
                self.allocator,
                try std.fmt.allocPrint(
                    self.allocator,
                    "Some lines truncated to {d} chars. Use read tool to see full lines",
                    .{truncate.GREP_MAX_LINE_LENGTH},
                ),
            );
            details.lines_truncated = true;
        }

        if (notices.items.len > 0) {
            try output.appendSlice(self.allocator, "\n\n[");
            for (notices.items, 0..) |notice, index| {
                if (index > 0) try output.appendSlice(self.allocator, ". ");
                try output.appendSlice(self.allocator, notice);
            }
            try output.append(self.allocator, ']');
        }

        return .{
            .text = try output.toOwnedSlice(self.allocator),
            .details = if (details.hasDetails()) details else null,
        };
    }

    fn walkDir(self: *SearchContext, absolute_dir: []const u8, relative_dir: []const u8) !void {
        if (self.stopped) return;

        const saved_rules_len = self.ignore_rules.items.len;
        defer self.freeIgnoreRulesFrom(saved_rules_len);
        try self.loadGitignoreRules(absolute_dir, relative_dir);

        var directory = try openDirPath(self.io, absolute_dir, .{ .iterate = true });
        defer directory.close(self.io);

        var entries: std.ArrayList(DirectoryEntry) = .empty;
        defer {
            for (entries.items) |*entry| entry.deinit(self.allocator);
            entries.deinit(self.allocator);
        }

        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            const full_path = try std.fs.path.join(self.allocator, &.{ absolute_dir, entry.name });
            errdefer self.allocator.free(full_path);
            const stat = std.Io.Dir.cwd().statFile(self.io, full_path, .{ .follow_symlinks = true }) catch {
                self.allocator.free(full_path);
                continue;
            };
            try entries.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.name),
                .absolute_path = full_path,
                .is_directory = stat.kind == .directory,
            });
        }
        std.mem.sort(DirectoryEntry, entries.items, {}, directoryEntryLessThan);

        for (entries.items) |entry| {
            if (self.stopped) return;

            const relative_path = try relativeChildPathAlloc(self.allocator, relative_dir, entry.name);
            defer self.allocator.free(relative_path);

            if (try self.isIgnored(relative_path, entry.is_directory)) continue;

            if (entry.is_directory) {
                try self.walkDir(entry.absolute_path, relative_path);
            } else if (try self.fileMatchesGlob(relative_path, entry.absolute_path)) {
                try self.processFile(entry.absolute_path, relative_path);
            }
        }
    }

    fn processFile(self: *SearchContext, absolute_path: []const u8, relative_path: []const u8) !void {
        if (self.stopped) return;

        const content = self.operations.readFile(self.allocator, self.io, absolute_path) catch return;
        defer self.allocator.free(content);
        const normalized = try normalizeLineBreaksAlloc(self.allocator, content);
        defer self.allocator.free(normalized);
        const lines = try splitLinesAlloc(self.allocator, normalized);
        defer self.allocator.free(lines);

        for (lines, 0..) |line, index| {
            if (self.stopped) return;
            if (!try self.matcher.matches(self.allocator, line)) continue;

            self.match_count += 1;
            const line_number = index + 1;
            try self.appendFormattedBlock(relative_path, lines, line_number);

            if (self.match_count >= self.effective_limit) {
                self.match_limit_reached = true;
                self.stopped = true;
                return;
            }
        }
    }

    fn appendFormattedBlock(self: *SearchContext, relative_path: []const u8, lines: []const []const u8, line_number: usize) !void {
        const start_line = if (self.context_value > 0 and line_number > self.context_value)
            line_number - self.context_value
        else
            line_number;
        const end_line = if (self.context_value > 0)
            @min(lines.len, line_number + self.context_value)
        else
            line_number;

        const display_path = if (self.is_directory)
            try toPosixPathAlloc(self.allocator, relative_path)
        else
            try self.allocator.dupe(u8, basename(self.search_path));
        defer self.allocator.free(display_path);

        var current = start_line;
        while (current <= end_line) : (current += 1) {
            const line = lines[current - 1];
            var truncated_line = try truncate.truncateLineAlloc(self.allocator, line, truncate.GREP_MAX_LINE_LENGTH);
            defer truncated_line.deinit(self.allocator);
            if (truncated_line.was_truncated) self.lines_truncated = true;

            const is_match_line = current == line_number;
            const formatted = if (is_match_line)
                try std.fmt.allocPrint(self.allocator, "{s}:{d}: {s}", .{ display_path, current, truncated_line.text })
            else
                try std.fmt.allocPrint(self.allocator, "{s}-{d}- {s}", .{ display_path, current, truncated_line.text });
            try self.output_lines.append(self.allocator, formatted);
        }
    }

    fn fileMatchesGlob(self: *SearchContext, relative_path: []const u8, absolute_path: []const u8) !bool {
        const pattern = self.glob orelse return true;
        var parsed = try ParsedGlob.init(self.allocator, pattern);
        defer parsed.deinit(self.allocator);
        return parsed.matches(self.allocator, relative_path, absolute_path, basename(relative_path));
    }

    fn loadGitignoreRules(self: *SearchContext, absolute_dir: []const u8, relative_dir: []const u8) !void {
        const gitignore_path = try std.fs.path.join(self.allocator, &.{ absolute_dir, ".gitignore" });
        defer self.allocator.free(gitignore_path);

        const content = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            gitignore_path,
            self.allocator,
            .limited(1024 * 1024),
        ) catch return;
        defer self.allocator.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line_with_cr| {
            const line = std.mem.trimEnd(u8, line_with_cr, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            try self.ignore_rules.append(self.allocator, try IgnoreRule.init(self.allocator, relative_dir, line));
        }
    }

    fn isIgnored(self: *SearchContext, relative_path: []const u8, is_directory: bool) !bool {
        var ignored = false;

        for (default_ignore_patterns) |ignore_pattern| {
            var parsed = try ParsedGlob.init(self.allocator, ignore_pattern);
            defer parsed.deinit(self.allocator);
            if (try parsed.matches(self.allocator, relative_path, relative_path, basename(relative_path))) {
                ignored = true;
            }
        }

        for (self.ignore_rules.items) |rule| {
            if (try rule.matches(self.allocator, relative_path, is_directory)) {
                ignored = !rule.negated;
            }
        }

        return ignored;
    }

    fn freeIgnoreRulesFrom(self: *SearchContext, start: usize) void {
        if (start >= self.ignore_rules.items.len) return;
        for (self.ignore_rules.items[start..]) |*rule| rule.deinit(self.allocator);
        self.ignore_rules.shrinkRetainingCapacity(start);
    }
};

const Matcher = struct {
    pattern: []const u8,
    ignore_case: bool,
    literal: bool,

    fn matches(self: Matcher, allocator: std.mem.Allocator, text: []const u8) !bool {
        if (self.pattern.len == 0) return true;
        if (self.literal) return containsLiteral(text, self.pattern, self.ignore_case);
        return regexContains(allocator, self.pattern, text, self.ignore_case);
    }
};

const DirectoryEntry = struct {
    name: []u8,
    absolute_path: []u8,
    is_directory: bool,

    fn deinit(self: *DirectoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.absolute_path);
        self.* = undefined;
    }
};

const ParsedGlob = struct {
    pattern: []const u8,
    has_slash: bool,
    absolute: bool,
    segments: [][]const u8,

    fn init(allocator: std.mem.Allocator, pattern: []const u8) !ParsedGlob {
        try validateGlob(pattern);
        return .{
            .pattern = pattern,
            .has_slash = std.mem.indexOfScalar(u8, pattern, '/') != null,
            .absolute = std.mem.startsWith(u8, pattern, "/"),
            .segments = try splitPathSegmentsAlloc(allocator, pattern),
        };
    }

    fn deinit(self: *ParsedGlob, allocator: std.mem.Allocator) void {
        allocator.free(self.segments);
        self.* = undefined;
    }

    fn matches(
        self: ParsedGlob,
        allocator: std.mem.Allocator,
        relative_path: []const u8,
        absolute_path: []const u8,
        entry_name: []const u8,
    ) !bool {
        if (!self.has_slash) return matchGlobSegment(self.pattern, entry_name);

        const target = if (self.absolute) absolute_path else relative_path;
        const posix_target = try toPosixPathAlloc(allocator, target);
        defer allocator.free(posix_target);
        const target_segments = try splitPathSegmentsAlloc(allocator, posix_target);
        defer allocator.free(target_segments);
        return matchPathSegments(self.segments, target_segments);
    }
};

const IgnoreRule = struct {
    base_relative: []u8,
    pattern: []u8,
    negated: bool,
    directory_only: bool,
    anchored: bool,
    has_slash: bool,

    fn init(allocator: std.mem.Allocator, base_relative: []const u8, raw_line: []const u8) !IgnoreRule {
        var line = std.mem.trim(u8, raw_line, " \t\r\n");
        var negated = false;
        if (std.mem.startsWith(u8, line, "!")) {
            negated = true;
            line = line[1..];
        }

        var anchored = false;
        if (std.mem.startsWith(u8, line, "/")) {
            anchored = true;
            line = line[1..];
        }

        var directory_only = false;
        if (line.len > 0 and line[line.len - 1] == '/') {
            directory_only = true;
            line = line[0 .. line.len - 1];
        }

        const owned_base = try allocator.dupe(u8, base_relative);
        errdefer allocator.free(owned_base);
        const owned_pattern = try allocator.dupe(u8, line);

        return .{
            .base_relative = owned_base,
            .pattern = owned_pattern,
            .negated = negated,
            .directory_only = directory_only,
            .anchored = anchored,
            .has_slash = std.mem.indexOfScalar(u8, line, '/') != null,
        };
    }

    fn deinit(self: *IgnoreRule, allocator: std.mem.Allocator) void {
        allocator.free(self.base_relative);
        allocator.free(self.pattern);
        self.* = undefined;
    }

    fn matches(self: IgnoreRule, allocator: std.mem.Allocator, relative_path: []const u8, is_directory: bool) !bool {
        if (self.pattern.len == 0) return false;
        if (self.directory_only and !is_directory) return false;

        const local_path = localPathForRule(self.base_relative, relative_path) orelse return false;
        if (self.anchored or self.has_slash) {
            var parsed = try ParsedGlob.init(allocator, self.pattern);
            defer parsed.deinit(allocator);
            return parsed.matches(allocator, local_path, local_path, basename(local_path));
        }
        return matchGlobSegment(self.pattern, basename(local_path));
    }
};

const Atom = union(enum) {
    literal: u8,
    any,
    digit,
    word,
    space,
    class: CharacterClass,

    fn matches(self: Atom, byte: u8, ignore_case: bool) bool {
        return switch (self) {
            .literal => |literal| bytesEqual(literal, byte, ignore_case),
            .any => true,
            .digit => std.ascii.isDigit(byte),
            .word => std.ascii.isAlphanumeric(byte) or byte == '_',
            .space => byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r',
            .class => |class| class.matches(byte, ignore_case),
        };
    }
};

const CharacterClass = struct {
    source: []const u8,
    negated: bool,

    fn matches(self: CharacterClass, byte: u8, ignore_case: bool) bool {
        var index: usize = 0;
        var matched = false;
        while (index < self.source.len) {
            if (index + 2 < self.source.len and self.source[index + 1] == '-') {
                const lower = normalizedByte(self.source[index], ignore_case);
                const upper = normalizedByte(self.source[index + 2], ignore_case);
                const actual = normalizedByte(byte, ignore_case);
                if (lower <= actual and actual <= upper) matched = true;
                index += 3;
                continue;
            }

            if (bytesEqual(self.source[index], byte, ignore_case)) matched = true;
            index += 1;
        }
        return if (self.negated) !matched else matched;
    }
};

const ParsedAtom = struct {
    atom: Atom,
    next_index: usize,
};

const RegexMatchError = error{InvalidRegex};

fn defaultIsDirectory(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !bool {
    const stat = try std.Io.Dir.cwd().statFile(io, absolute_path, .{ .follow_symlinks = true });
    return stat.kind == .directory;
}

fn defaultReadFile(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .unlimited);
}

fn regexContains(allocator: std.mem.Allocator, pattern: []const u8, text: []const u8, ignore_case: bool) !bool {
    const alternatives = try splitRegexAlternativesAlloc(allocator, pattern);
    defer allocator.free(alternatives);

    for (alternatives) |alternative| {
        if (try regexAlternativeContains(alternative, text, ignore_case)) return true;
    }
    return false;
}

fn regexAlternativeContains(pattern: []const u8, text: []const u8, ignore_case: bool) RegexMatchError!bool {
    if (std.mem.startsWith(u8, pattern, "^")) {
        return matchHere(pattern, 1, text, 0, ignore_case);
    }

    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (try matchHere(pattern, 0, text, index, ignore_case)) return true;
    }
    return false;
}

fn matchHere(pattern: []const u8, pattern_index: usize, text: []const u8, text_index: usize, ignore_case: bool) RegexMatchError!bool {
    if (pattern_index >= pattern.len) return true;
    if (pattern[pattern_index] == '$' and pattern_index + 1 == pattern.len) return text_index == text.len;

    const parsed = try parseAtom(pattern, pattern_index);
    const next_index = parsed.next_index;
    if (next_index < pattern.len) {
        switch (pattern[next_index]) {
            '*' => return matchStar(parsed.atom, pattern, next_index + 1, text, text_index, ignore_case),
            '+' => return matchPlus(parsed.atom, pattern, next_index + 1, text, text_index, ignore_case),
            '?' => return matchQuestion(parsed.atom, pattern, next_index + 1, text, text_index, ignore_case),
            else => {},
        }
    }

    if (text_index < text.len and parsed.atom.matches(text[text_index], ignore_case)) {
        return matchHere(pattern, next_index, text, text_index + 1, ignore_case);
    }
    return false;
}

fn matchStar(atom: Atom, pattern: []const u8, next_index: usize, text: []const u8, text_index: usize, ignore_case: bool) RegexMatchError!bool {
    var end = text_index;
    while (end < text.len and atom.matches(text[end], ignore_case)) : (end += 1) {}

    var cursor = end;
    while (true) {
        if (try matchHere(pattern, next_index, text, cursor, ignore_case)) return true;
        if (cursor == text_index) break;
        cursor -= 1;
    }
    return false;
}

fn matchPlus(atom: Atom, pattern: []const u8, next_index: usize, text: []const u8, text_index: usize, ignore_case: bool) RegexMatchError!bool {
    if (text_index >= text.len or !atom.matches(text[text_index], ignore_case)) return false;
    return matchStar(atom, pattern, next_index, text, text_index + 1, ignore_case);
}

fn matchQuestion(atom: Atom, pattern: []const u8, next_index: usize, text: []const u8, text_index: usize, ignore_case: bool) RegexMatchError!bool {
    if (text_index < text.len and atom.matches(text[text_index], ignore_case)) {
        if (try matchHere(pattern, next_index, text, text_index + 1, ignore_case)) return true;
    }
    return matchHere(pattern, next_index, text, text_index, ignore_case);
}

fn parseAtom(pattern: []const u8, index: usize) RegexMatchError!ParsedAtom {
    if (index >= pattern.len) return error.InvalidRegex;
    const byte = pattern[index];
    if (byte == '.') return .{ .atom = .any, .next_index = index + 1 };
    if (byte == '\\') {
        if (index + 1 >= pattern.len) return .{ .atom = .{ .literal = byte }, .next_index = index + 1 };
        return switch (pattern[index + 1]) {
            'd' => .{ .atom = .digit, .next_index = index + 2 },
            'w' => .{ .atom = .word, .next_index = index + 2 },
            's' => .{ .atom = .space, .next_index = index + 2 },
            else => |escaped| .{ .atom = .{ .literal = escaped }, .next_index = index + 2 },
        };
    }
    if (byte == '[') {
        const class_start = index + 1;
        if (class_start >= pattern.len) return error.InvalidRegex;
        var source_start = class_start;
        var negated = false;
        if (pattern[source_start] == '^' or pattern[source_start] == '!') {
            negated = true;
            source_start += 1;
        }

        var cursor = source_start;
        while (cursor < pattern.len and pattern[cursor] != ']') : (cursor += 1) {}
        if (cursor >= pattern.len) return error.InvalidRegex;
        return .{
            .atom = .{ .class = .{ .source = pattern[source_start..cursor], .negated = negated } },
            .next_index = cursor + 1,
        };
    }
    return .{ .atom = .{ .literal = byte }, .next_index = index + 1 };
}

fn splitRegexAlternativesAlloc(allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
    var alternatives: std.ArrayList([]const u8) = .empty;
    defer alternatives.deinit(allocator);

    var start: usize = 0;
    var index: usize = 0;
    var in_class = false;
    var escaped = false;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '[') {
            in_class = true;
            continue;
        }
        if (byte == ']') {
            in_class = false;
            continue;
        }
        if (byte == '|' and !in_class) {
            try alternatives.append(allocator, pattern[start..index]);
            start = index + 1;
        }
    }
    try alternatives.append(allocator, pattern[start..]);
    return alternatives.toOwnedSlice(allocator);
}

fn containsLiteral(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var offset: usize = 0;
        while (offset < needle.len) : (offset += 1) {
            if (!bytesEqual(haystack[index + offset], needle[offset], ignore_case)) break;
        } else {
            return true;
        }
    }
    return false;
}

fn bytesEqual(lhs: u8, rhs: u8, ignore_case: bool) bool {
    return normalizedByte(lhs, ignore_case) == normalizedByte(rhs, ignore_case);
}

fn normalizedByte(byte: u8, ignore_case: bool) u8 {
    return if (ignore_case) std.ascii.toLower(byte) else byte;
}

fn normalizeLineBreaksAlloc(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < content.len) : (index += 1) {
        if (content[index] == '\r') {
            try output.append(allocator, '\n');
            if (index + 1 < content.len and content[index + 1] == '\n') index += 1;
        } else {
            try output.append(allocator, content[index]);
        }
    }

    return output.toOwnedSlice(allocator);
}

fn localPathForRule(base_relative: []const u8, relative_path: []const u8) ?[]const u8 {
    if (base_relative.len == 0) return relative_path;
    if (!std.mem.startsWith(u8, relative_path, base_relative)) return null;
    if (relative_path.len == base_relative.len) return "";
    if (relative_path[base_relative.len] != '/') return null;
    return relative_path[base_relative.len + 1 ..];
}

fn validateGlob(pattern: []const u8) !void {
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] != '[') continue;
        index += 1;
        if (index < pattern.len and (pattern[index] == '!' or pattern[index] == '^')) index += 1;
        var found = false;
        while (index < pattern.len) : (index += 1) {
            if (pattern[index] == ']') {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidGlob;
    }
}

fn matchPathSegments(pattern_segments: []const []const u8, path_segments: []const []const u8) !bool {
    if (pattern_segments.len == 0) return path_segments.len == 0;

    if (std.mem.eql(u8, pattern_segments[0], "**")) {
        if (pattern_segments.len == 1) return true;
        var skip: usize = 0;
        while (skip <= path_segments.len) : (skip += 1) {
            if (try matchPathSegments(pattern_segments[1..], path_segments[skip..])) return true;
        }
        return false;
    }

    if (path_segments.len == 0) return false;
    if (!try matchGlobSegment(pattern_segments[0], path_segments[0])) return false;
    return matchPathSegments(pattern_segments[1..], path_segments[1..]);
}

fn matchGlobSegment(pattern: []const u8, text: []const u8) !bool {
    var pattern_index: usize = 0;
    var text_index: usize = 0;
    var star_index: ?usize = null;
    var star_text_index: usize = 0;

    while (text_index < text.len) {
        if (pattern_index < pattern.len) {
            switch (pattern[pattern_index]) {
                '*' => {
                    star_index = pattern_index;
                    pattern_index += 1;
                    star_text_index = text_index;
                    continue;
                },
                '?' => {
                    pattern_index += 1;
                    text_index += 1;
                    continue;
                },
                '[' => {
                    const class = try matchGlobCharacterClass(pattern, pattern_index, text[text_index]);
                    if (class.matches) {
                        pattern_index = class.next_index;
                        text_index += 1;
                        continue;
                    }
                },
                else => {
                    if (pattern[pattern_index] == text[text_index]) {
                        pattern_index += 1;
                        text_index += 1;
                        continue;
                    }
                },
            }
        }

        if (star_index) |star| {
            pattern_index = star + 1;
            star_text_index += 1;
            text_index = star_text_index;
            continue;
        }
        return false;
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

const GlobClassMatch = struct {
    matches: bool,
    next_index: usize,
};

fn matchGlobCharacterClass(pattern: []const u8, start: usize, byte: u8) !GlobClassMatch {
    var index = start + 1;
    if (index >= pattern.len) return error.InvalidGlob;

    var negated = false;
    if (pattern[index] == '!' or pattern[index] == '^') {
        negated = true;
        index += 1;
    }

    var matched = false;
    var saw_closing = false;
    while (index < pattern.len) {
        if (pattern[index] == ']') {
            saw_closing = true;
            index += 1;
            break;
        }

        if (index + 2 < pattern.len and pattern[index + 1] == '-' and pattern[index + 2] != ']') {
            const lower = pattern[index];
            const upper = pattern[index + 2];
            if (lower <= byte and byte <= upper) matched = true;
            index += 3;
            continue;
        }

        if (pattern[index] == byte) matched = true;
        index += 1;
    }

    if (!saw_closing) return error.InvalidGlob;
    return .{
        .matches = if (negated) !matched else matched,
        .next_index = index,
    };
}

fn relativeChildPathAlloc(allocator: std.mem.Allocator, relative_dir: []const u8, name: []const u8) ![]u8 {
    if (relative_dir.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_dir, name });
}

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |slash| return path[slash + 1 ..];
    return path;
}

fn toPosixPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') {
        for (result) |*byte| {
            if (byte.* == std.fs.path.sep) byte.* = '/';
        }
    }
    return result;
}

fn splitPathSegmentsAlloc(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        try segments.append(allocator, segment);
    }
    return segments.toOwnedSlice(allocator);
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn directoryEntryLessThan(_: void, lhs: DirectoryEntry, rhs: DirectoryEntry) bool {
    return caseInsensitiveLessThan({}, lhs.name, rhs.name);
}

fn caseInsensitiveLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const min_len = @min(lhs.len, rhs.len);
    var index: usize = 0;
    while (index < min_len) : (index += 1) {
        const left = std.ascii.toLower(lhs[index]);
        const right = std.ascii.toLower(rhs[index]);
        if (left < right) return true;
        if (left > right) return false;
    }
    if (lhs.len != rhs.len) return lhs.len < rhs.len;
    return std.mem.lessThan(u8, lhs, rhs);
}

fn joinLinesAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    return joinWithSeparatorAlloc(allocator, lines, "\n");
}

fn joinWithSeparatorAlloc(allocator: std.mem.Allocator, parts: []const []const u8, separator: []const u8) ![]u8 {
    if (parts.len == 0) return allocator.dupe(u8, "");
    var total_len: usize = separator.len * (parts.len - 1);
    for (parts) |part| total_len += part.len;

    const output = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (parts, 0..) |part, index| {
        if (index > 0) {
            @memcpy(output[offset .. offset + separator.len], separator);
            offset += separator.len;
        }
        @memcpy(output[offset .. offset + part.len], part);
        offset += part.len;
    }
    return output;
}

fn splitLinesAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    if (text.len == 0) return lines.toOwnedSlice(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
        try lines.append(allocator, text[start..newline]);
        start = newline + 1;
    }
    if (start < text.len) try lines.append(allocator, text[start..]);
    return lines.toOwnedSlice(allocator);
}

fn keyHintAlloc(
    allocator: std.mem.Allocator,
    theme: render_utils.RenderTheme,
    keybinding: []const u8,
    description: []const u8,
) ![]u8 {
    const key_text = try keyTextAlloc(allocator, keybinding);
    defer allocator.free(key_text);
    const styled_key = try theme.fgAlloc(allocator, .dim, key_text);
    defer allocator.free(styled_key);
    const description_text = try std.fmt.allocPrint(allocator, " {s}", .{description});
    defer allocator.free(description_text);
    const styled_description = try theme.fgAlloc(allocator, .muted, description_text);
    defer allocator.free(styled_description);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ styled_key, styled_description });
}

fn keyTextAlloc(allocator: std.mem.Allocator, keybinding: []const u8) ![]u8 {
    var empty: keybindings.KeybindingsConfig = .empty;
    defer empty.deinit(allocator);
    var manager = try keybindings.KeybindingsManager.init(allocator, &empty);
    defer manager.deinit();

    const keys = try manager.getKeysAlloc(allocator, keybinding);
    defer freeConstStringSlice(allocator, keys);
    return formatKeysAlloc(allocator, keys);
}

fn formatKeysAlloc(allocator: std.mem.Allocator, keys: []const []const u8) ![]u8 {
    if (keys.len == 0) return allocator.dupe(u8, "");
    const joined = try joinWithSeparatorAlloc(allocator, keys, "/");
    defer allocator.free(joined);
    return formatKeyTextAlloc(allocator, joined);
}

fn formatKeyTextAlloc(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var slash_iter = std.mem.splitScalar(u8, key, '/');
    var first_key = true;
    while (slash_iter.next()) |combo| {
        if (!first_key) try output.append(allocator, '/');
        first_key = false;

        var plus_iter = std.mem.splitScalar(u8, combo, '+');
        var first_part = true;
        while (plus_iter.next()) |part| {
            if (!first_part) try output.append(allocator, '+');
            first_part = false;
            if (builtin.os.tag == .macos and std.ascii.eqlIgnoreCase(part, "alt")) {
                try output.appendSlice(allocator, "option");
            } else {
                try output.appendSlice(allocator, part);
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

fn freeConstStringSlice(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

const StyledTestTheme = struct {
    pub fn bold(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "<bold>{s}</>", .{text});
    }

    pub fn fg(_: ?*anyopaque, allocator: std.mem.Allocator, color: render_utils.ThemeColor, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "<{s}>{s}</>", .{ colorName(color), text });
    }
};

fn colorName(color: render_utils.ThemeColor) []const u8 {
    return switch (color) {
        .accent => "accent",
        .dim => "dim",
        .@"error" => "error",
        .muted => "muted",
        .tool_title => "toolTitle",
        .tool_output => "toolOutput",
        .warning => "warning",
    };
}

fn styledTestTheme() render_utils.RenderTheme {
    return .{ .bold_fn = StyledTestTheme.bold, .fg_fn = StyledTestTheme.fg };
}

test "grep includes filename when searching a single file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "example.txt", .data = "first line\nmatch line\nlast line" });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "example.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{
        .pattern = "match",
        .path = test_file,
    }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "example.txt:2: match line") != null);
}

test "grep respects global limit and includes context lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "context.txt", .data = "before\nmatch one\nafter\nmiddle\nmatch two\nafter two" },
    );

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const test_file = try std.fs.path.join(allocator, &.{ root, "context.txt" });
    defer allocator.free(test_file);

    var result = try executeAlloc(allocator, io, root, .{
        .pattern = "match",
        .path = test_file,
        .limit = 1,
        .context = 1,
    }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "context.txt-1- before") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "context.txt:2: match one") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "context.txt-3- after") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "[1 matches limit reached. Use limit=2 for more, or refine pattern]") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "match two") == null);
}

test "grep treats flag-like patterns as search text" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "payload.sh", .data = "#!/bin/sh\necho executed\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "target\n" });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var result = try executeAlloc(allocator, io, root, .{
        .pattern = "--pre=payload.sh",
        .path = root,
    }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "No matches found") != null);
}

test "grep native search respects glob filters gitignore hidden files and simple regex options" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, ".secret", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".secret/hidden.txt", .data = "Needle hidden\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored.txt", .data = "Needle ignored\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "Needle visible\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.md", .data = "Needle markdown\n" });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var result = try executeAlloc(allocator, io, root, .{
        .pattern = "^needle",
        .path = root,
        .glob = "**/*.txt",
        .ignore_case = true,
    }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, ".secret/hidden.txt:1: Needle hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "visible.txt:1: Needle visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "ignored.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "visible.md") == null);
}

test "grep truncates long lines and renders collapsed results" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var long_line: std.ArrayList(u8) = .empty;
    defer long_line.deinit(allocator);
    try long_line.appendSlice(allocator, "match ");
    var index: usize = 0;
    while (index < truncate.GREP_MAX_LINE_LENGTH + 20) : (index += 1) {
        try long_line.append(allocator, 'x');
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "long.txt", .data = long_line.items });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var result = try executeAlloc(allocator, io, root, .{
        .pattern = "match",
        .path = root,
    }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(result.details.?.lines_truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Some lines truncated to 500 chars") != null);

    const theme = styledTestTheme();
    const rendered = try formatGrepResultAlloc(allocator, result, .{}, theme, false);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<warning>[Truncated: some lines truncated]</>") != null);
}

test "grep render call uses Pi styling and optional glob and limit" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    const rendered = try formatGrepCallAlloc(allocator, .{
        .pattern = "needle",
        .path = "/Users/alice/project",
        .glob = "**/*.zig",
        .limit = 5,
    }, theme, .{ .home_dir = "/Users/alice" });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<toolTitle><bold>grep</></> <accent>/needle/</><toolOutput> in ~/project</><toolOutput> (**/*.zig)</><toolOutput> limit 5</>",
        rendered,
    );
}
