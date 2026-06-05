const std = @import("std");
const builtin = @import("builtin");

const keybindings = @import("../keybindings.zig");
const path_utils = @import("../path_utils.zig");
const render_utils = @import("render_utils.zig");
const truncate = @import("truncate.zig");

pub const DEFAULT_LIMIT: usize = 1000;

const default_ignore_patterns = [_][]const u8{
    "**/node_modules/**",
    "**/.git/**",
};

pub const FindToolInput = struct {
    pattern: ?[]const u8 = null,
    path: ?[]const u8 = null,
    limit: ?usize = null,
};

pub const FindGlobOptions = struct {
    ignore: []const []const u8 = &default_ignore_patterns,
    limit: usize,
};

pub const FindOperations = struct {
    ptr: ?*anyopaque = null,
    exists_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!bool = defaultExists,
    glob_fn: ?*const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8, []const u8, FindGlobOptions) anyerror![][]u8 = null,

    pub fn exists(self: FindOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !bool {
        return self.exists_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn glob(
        self: FindOperations,
        allocator: std.mem.Allocator,
        io: std.Io,
        pattern: []const u8,
        cwd: []const u8,
        options: FindGlobOptions,
    ) ![][]u8 {
        const glob_fn = self.glob_fn orelse return error.MissingGlobOperation;
        return glob_fn(self.ptr, allocator, io, pattern, cwd, options);
    }

    pub fn hasCustomGlob(self: FindOperations) bool {
        return self.glob_fn != null;
    }
};

pub const FindToolOptions = struct {
    operations: FindOperations = .{},
    home_dir: ?[]const u8 = null,
};

pub const FindToolDetails = struct {
    truncation: ?truncate.TruncationResult = null,
    result_limit_reached: ?usize = null,

    pub fn hasDetails(self: FindToolDetails) bool {
        return self.truncation != null or self.result_limit_reached != null;
    }

    pub fn deinit(self: *FindToolDetails, allocator: std.mem.Allocator) void {
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const FindToolResult = struct {
    text: []u8,
    details: ?FindToolDetails = null,

    pub fn deinit(self: *FindToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: FindToolInput,
    options: FindToolOptions,
) !FindToolResult {
    const pattern = input.pattern orelse return error.InvalidPattern;
    try validateGlob(pattern);

    const requested_path = input.path orelse ".";
    const search_path = try path_utils.resolveToCwdAlloc(allocator, requested_path, cwd, options.home_dir);
    defer allocator.free(search_path);

    const effective_limit = input.limit orelse DEFAULT_LIMIT;
    const ops = options.operations;

    if (ops.hasCustomGlob()) {
        if (!try ops.exists(allocator, io, search_path)) return error.PathNotFound;
        const results = try ops.glob(allocator, io, pattern, search_path, .{
            .ignore = &default_ignore_patterns,
            .limit = effective_limit,
        });
        defer freeStringSlice(allocator, results);
        return formatFindOutputAlloc(allocator, search_path, results, effective_limit, .custom);
    }

    if (!try defaultExists(null, allocator, io, search_path)) return error.PathNotFound;
    const stat = try std.Io.Dir.cwd().statFile(io, search_path, .{ .follow_symlinks = true });
    if (stat.kind != .directory) return error.NotDirectory;

    const results = try nativeGlobAlloc(allocator, io, search_path, pattern, effective_limit);
    defer freeStringSlice(allocator, results);
    return formatFindOutputAlloc(allocator, search_path, results, effective_limit, .native);
}

pub fn formatFindCallAlloc(
    allocator: std.mem.Allocator,
    args: ?FindToolInput,
    theme: render_utils.RenderTheme,
    options: FindToolOptions,
) ![]u8 {
    const input = args orelse FindToolInput{};
    const pattern = input.pattern orelse "";
    const raw_path = input.path orelse "";
    const path_source = if (raw_path.len > 0) raw_path else ".";
    const path = try render_utils.shortenPathAlloc(allocator, path_source, options.home_dir);
    defer allocator.free(path);

    const title_bold = try theme.boldAlloc(allocator, "find");
    defer allocator.free(title_bold);
    const title = try theme.fgAlloc(allocator, .tool_title, title_bold);
    defer allocator.free(title);
    const styled_pattern = try theme.fgAlloc(allocator, .accent, pattern);
    defer allocator.free(styled_pattern);
    const in_path = try std.fmt.allocPrint(allocator, " in {s}", .{path});
    defer allocator.free(in_path);
    const styled_path = try theme.fgAlloc(allocator, .tool_output, in_path);
    defer allocator.free(styled_path);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.print(allocator, "{s} {s}{s}", .{ title, styled_pattern, styled_path });
    if (input.limit) |limit| {
        const limit_text = try std.fmt.allocPrint(allocator, " (limit {d})", .{limit});
        defer allocator.free(limit_text);
        const styled_limit = try theme.fgAlloc(allocator, .tool_output, limit_text);
        defer allocator.free(styled_limit);
        try output.appendSlice(allocator, styled_limit);
    }
    return output.toOwnedSlice(allocator);
}

pub fn formatFindResultAlloc(
    allocator: std.mem.Allocator,
    result: FindToolResult,
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
        const max_lines = if (options.expanded) lines.len else @min(lines.len, 20);
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
        if (details.result_limit_reached != null or (details.truncation != null and details.truncation.?.truncated)) {
            var warnings: std.ArrayList([]u8) = .empty;
            defer {
                for (warnings.items) |warning| allocator.free(warning);
                warnings.deinit(allocator);
            }

            if (details.result_limit_reached) |limit| {
                try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{d} results limit", .{limit}));
            }
            if (details.truncation) |truncation_result| {
                if (truncation_result.truncated) {
                    const size = try truncate.formatSizeAlloc(allocator, truncation_result.max_bytes);
                    defer allocator.free(size);
                    try warnings.append(allocator, try std.fmt.allocPrint(allocator, "{s} limit", .{size}));
                }
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

const FindOutputMode = enum {
    custom,
    native,
};

fn formatFindOutputAlloc(
    allocator: std.mem.Allocator,
    search_path: []const u8,
    results: []const []u8,
    effective_limit: usize,
    mode: FindOutputMode,
) !FindToolResult {
    if (results.len == 0) {
        return .{ .text = try allocator.dupe(u8, "No files found matching pattern") };
    }

    var relativized: std.ArrayList([]u8) = .empty;
    defer {
        for (relativized.items) |path| allocator.free(path);
        relativized.deinit(allocator);
    }

    for (results) |result_path| {
        try relativized.append(allocator, try relativizePathAlloc(allocator, search_path, result_path));
    }
    std.mem.sort([]u8, relativized.items, {}, caseInsensitiveLessThan);

    const result_limit_reached = relativized.items.len >= effective_limit;
    const raw_output = try joinLinesAlloc(allocator, relativized.items);
    defer allocator.free(raw_output);

    var truncation_result = try truncate.truncateHeadAlloc(allocator, raw_output, .{ .max_lines = std.math.maxInt(usize) });
    var truncation_moved = false;
    defer if (!truncation_moved) truncation_result.deinit(allocator);

    var details: FindToolDetails = .{};
    errdefer details.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, truncation_result.content);

    var notices: std.ArrayList([]u8) = .empty;
    defer {
        for (notices.items) |notice| allocator.free(notice);
        notices.deinit(allocator);
    }

    if (result_limit_reached) {
        const notice = switch (mode) {
            .custom => try std.fmt.allocPrint(allocator, "{d} results limit reached", .{effective_limit}),
            .native => try std.fmt.allocPrint(
                allocator,
                "{d} results limit reached. Use limit={d} for more, or refine pattern",
                .{ effective_limit, effective_limit *| 2 },
            ),
        };
        try notices.append(allocator, notice);
        details.result_limit_reached = effective_limit;
    }

    if (truncation_result.truncated) {
        const size = try truncate.formatSizeAlloc(allocator, truncate.DEFAULT_MAX_BYTES);
        defer allocator.free(size);
        try notices.append(allocator, try std.fmt.allocPrint(allocator, "{s} limit reached", .{size}));
        details.truncation = truncation_result;
        truncation_moved = true;
    }

    if (notices.items.len > 0) {
        try output.appendSlice(allocator, "\n\n[");
        for (notices.items, 0..) |notice, index| {
            if (index > 0) try output.appendSlice(allocator, ". ");
            try output.appendSlice(allocator, notice);
        }
        try output.append(allocator, ']');
    }

    return .{
        .text = try output.toOwnedSlice(allocator),
        .details = if (details.hasDetails()) details else null,
    };
}

fn defaultExists(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !bool {
    return path_utils.pathExists(io, absolute_path);
}

fn nativeGlobAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    search_path: []const u8,
    pattern: []const u8,
    limit: usize,
) ![][]u8 {
    var parsed = try ParsedGlob.init(allocator, pattern);
    defer parsed.deinit(allocator);

    var context = NativeFindContext{
        .allocator = allocator,
        .io = io,
        .search_path = search_path,
        .parsed = parsed,
        .limit = limit,
    };
    return context.run();
}

const NativeFindContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    search_path: []const u8,
    parsed: ParsedGlob,
    limit: usize,
    results: std.ArrayList([]u8) = .empty,
    ignore_rules: std.ArrayList(IgnoreRule) = .empty,

    fn run(self: *NativeFindContext) ![][]u8 {
        errdefer {
            for (self.results.items) |path| self.allocator.free(path);
            self.results.deinit(self.allocator);
            self.freeIgnoreRulesFrom(0);
            self.ignore_rules.deinit(self.allocator);
        }
        try self.walkDir(self.search_path, "");
        self.freeIgnoreRulesFrom(0);
        self.ignore_rules.deinit(self.allocator);
        return self.results.toOwnedSlice(self.allocator);
    }

    fn walkDir(self: *NativeFindContext, absolute_dir: []const u8, relative_dir: []const u8) !void {
        if (self.results.items.len >= self.limit) return;

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
            if (self.results.items.len >= self.limit) return;

            const relative_path = try relativeChildPathAlloc(self.allocator, relative_dir, entry.name);
            defer self.allocator.free(relative_path);

            if (try self.isIgnored(relative_path, entry.is_directory)) continue;

            if (try self.parsed.matches(self.allocator, relative_path, entry.absolute_path, entry.name)) {
                try self.results.append(self.allocator, try self.allocator.dupe(u8, entry.absolute_path));
                if (self.results.items.len >= self.limit) return;
            }

            if (entry.is_directory) {
                try self.walkDir(entry.absolute_path, relative_path);
            }
        }
    }

    fn loadGitignoreRules(self: *NativeFindContext, absolute_dir: []const u8, relative_dir: []const u8) !void {
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

    fn isIgnored(self: *NativeFindContext, relative_path: []const u8, is_directory: bool) !bool {
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

    fn freeIgnoreRulesFrom(self: *NativeFindContext, start: usize) void {
        if (start >= self.ignore_rules.items.len) return;
        for (self.ignore_rules.items[start..]) |*rule| rule.deinit(self.allocator);
        self.ignore_rules.shrinkRetainingCapacity(start);
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
                    const class = try matchCharacterClass(pattern, pattern_index, text[text_index]);
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

const ClassMatch = struct {
    matches: bool,
    next_index: usize,
};

fn matchCharacterClass(pattern: []const u8, start: usize, byte: u8) !ClassMatch {
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

fn relativizePathAlloc(allocator: std.mem.Allocator, search_path: []const u8, candidate: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, candidate, search_path)) {
        if (candidate.len <= search_path.len) return allocator.dupe(u8, "");
        var offset = search_path.len;
        if (candidate[offset] == '/' or candidate[offset] == '\\') offset += 1;
        return toPosixPathAlloc(allocator, candidate[offset..]);
    }

    const relative = try std.fs.path.relative(allocator, ".", null, search_path, candidate);
    defer allocator.free(relative);
    return toPosixPathAlloc(allocator, relative);
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

fn freeStringSlice(allocator: std.mem.Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
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

const CustomGlobOperations = struct {
    root_path: []const u8,
    results: []const []const u8,
    last_pattern: ?[]u8 = null,
    last_cwd: ?[]u8 = null,
    last_limit: ?usize = null,

    fn operations(self: *CustomGlobOperations) FindOperations {
        return .{
            .ptr = self,
            .exists_fn = exists,
            .glob_fn = glob,
        };
    }

    fn deinit(self: *CustomGlobOperations, allocator: std.mem.Allocator) void {
        if (self.last_pattern) |value| allocator.free(value);
        if (self.last_cwd) |value| allocator.free(value);
        self.* = undefined;
    }

    fn exists(ptr: ?*anyopaque, _: std.mem.Allocator, _: std.Io, absolute_path: []const u8) !bool {
        const self: *CustomGlobOperations = @ptrCast(@alignCast(ptr.?));
        return std.mem.eql(u8, absolute_path, self.root_path);
    }

    fn glob(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        pattern: []const u8,
        cwd: []const u8,
        options: FindGlobOptions,
    ) ![][]u8 {
        const self: *CustomGlobOperations = @ptrCast(@alignCast(ptr.?));
        if (self.last_pattern) |value| allocator.free(value);
        if (self.last_cwd) |value| allocator.free(value);
        self.last_pattern = try allocator.dupe(u8, pattern);
        self.last_cwd = try allocator.dupe(u8, cwd);
        self.last_limit = options.limit;
        try std.testing.expectEqual(@as(usize, 2), options.ignore.len);

        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |item| allocator.free(item);
            out.deinit(allocator);
        }
        for (self.results) |result| {
            try out.append(allocator, try allocator.dupe(u8, result));
        }
        return out.toOwnedSlice(allocator);
    }
};

test "find custom operations relativize results and receive Pi-compatible options" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const results = [_][]const u8{
        "/mock/root/src/main.zig",
        "/mock/root/.secret/hidden.zig",
    };
    var custom_ops = CustomGlobOperations{
        .root_path = "/mock/root",
        .results = &results,
    };
    defer custom_ops.deinit(allocator);

    var result = try executeAlloc(
        allocator,
        io,
        "/mock/root",
        .{ .pattern = "**/*.zig", .path = ".", .limit = 10 },
        .{ .operations = custom_ops.operations() },
    );
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(".secret/hidden.zig\nsrc/main.zig", result.text);
    try std.testing.expectEqualStrings("**/*.zig", custom_ops.last_pattern.?);
    try std.testing.expectEqualStrings("/mock/root", custom_ops.last_cwd.?);
    try std.testing.expectEqual(@as(usize, 10), custom_ops.last_limit.?);
}

test "find native glob includes hidden files and respects simple gitignore patterns" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, ".secret", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".secret/hidden.txt", .data = "hidden" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "ignored.txt\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignored.txt", .data = "ignored" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "visible" });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var result = try executeAlloc(allocator, io, root, .{ .pattern = "**/*.txt", .path = root }, .{});
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "visible.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, ".secret/hidden.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "ignored.txt") == null);
}

test "find native glob treats flag-like patterns as search text and rejects malformed glob" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var no_match = try executeAlloc(allocator, io, root, .{ .pattern = "--help", .path = root }, .{});
    defer no_match.deinit(allocator);
    try std.testing.expectEqualStrings("No files found matching pattern", no_match.text);

    try std.testing.expectError(error.InvalidGlob, executeAlloc(allocator, io, root, .{ .pattern = "[", .path = root }, .{}));
}

test "find path-based glob patterns match nested paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "some", .default_dir);
    try tmp.dir.createDir(io, "some/parent", .default_dir);
    try tmp.dir.createDir(io, "some/parent/child", .default_dir);
    try tmp.dir.createDir(io, "src", .default_dir);
    try tmp.dir.createDir(io, "src/foo", .default_dir);
    try tmp.dir.createDir(io, "src/foo/bar", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "some/parent/child/file.ext", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "some/parent/child/test.spec.ts", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/foo/bar/example.spec.ts", .data = "" });

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var basename_result = try executeAlloc(allocator, io, root, .{ .pattern = "*.spec.ts", .path = root }, .{});
    defer basename_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, basename_result.text, "some/parent/child/test.spec.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, basename_result.text, "src/foo/bar/example.spec.ts") != null);

    var subtree_result = try executeAlloc(allocator, io, root, .{ .pattern = "some/parent/child/**", .path = root }, .{});
    defer subtree_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, subtree_result.text, "some/parent/child/file.ext") != null);
    try std.testing.expect(std.mem.indexOf(u8, subtree_result.text, "some/parent/child/test.spec.ts") != null);

    var leading_star_result = try executeAlloc(allocator, io, root, .{ .pattern = "**/parent/child/*", .path = root }, .{});
    defer leading_star_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, leading_star_result.text, "some/parent/child/file.ext") != null);
    try std.testing.expect(std.mem.indexOf(u8, leading_star_result.text, "some/parent/child/test.spec.ts") != null);

    var src_result = try executeAlloc(allocator, io, root, .{ .pattern = "src/**/*.spec.ts", .path = root }, .{});
    defer src_result.deinit(allocator);
    try std.testing.expectEqualStrings("src/foo/bar/example.spec.ts", src_result.text);
}

test "find result limit and byte truncation details mirror Pi notices" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var index: usize = 0;
    while (index < 6) : (index += 1) {
        const name = try std.fmt.allocPrint(allocator, "entry-{d}.txt", .{index});
        defer allocator.free(name);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }

    var limited = try executeAlloc(allocator, io, root, .{ .pattern = "*.txt", .path = root, .limit = 3 }, .{});
    defer limited.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, limited.text, "[3 results limit reached. Use limit=6 for more, or refine pattern]") != null);
    try std.testing.expectEqual(@as(usize, 3), limited.details.?.result_limit_reached.?);

    var long_results: std.ArrayList([]u8) = .empty;
    defer {
        for (long_results.items) |path| allocator.free(path);
        long_results.deinit(allocator);
    }
    index = 0;
    while (index < 900) : (index += 1) {
        try long_results.append(
            allocator,
            try std.fmt.allocPrint(allocator, "{s}/entry-{d:0>4}-{s}.txt", .{
                root,
                index,
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            }),
        );
    }

    var custom_ops = CustomGlobOperations{
        .root_path = root,
        .results = long_results.items,
    };
    defer custom_ops.deinit(allocator);

    var truncated_result = try executeAlloc(
        allocator,
        io,
        root,
        .{ .pattern = "*.txt", .path = root, .limit = 900 },
        .{ .operations = custom_ops.operations() },
    );
    defer truncated_result.deinit(allocator);
    try std.testing.expect(truncated_result.details.?.truncation.?.truncated);
    try std.testing.expect(std.mem.indexOf(u8, truncated_result.text, "50.0KB limit reached") != null);
}

test "find render call and result use Pi styling and collapse behavior" {
    const allocator = std.testing.allocator;
    const theme = styledTestTheme();

    const call = try formatFindCallAlloc(
        allocator,
        .{ .pattern = "**/*.zig", .path = "/Users/alice/project", .limit = 5 },
        theme,
        .{ .home_dir = "/Users/alice" },
    );
    defer allocator.free(call);
    try std.testing.expectEqualStrings(
        "<toolTitle><bold>find</></> <accent>**/*.zig</><toolOutput> in ~/project</><toolOutput> (limit 5)</>",
        call,
    );

    var long_output: std.ArrayList(u8) = .empty;
    defer long_output.deinit(allocator);
    var index: usize = 0;
    while (index < 25) : (index += 1) {
        if (index > 0) try long_output.append(allocator, '\n');
        try long_output.print(allocator, "file-{d}.zig", .{index});
    }

    var result = FindToolResult{
        .text = try long_output.toOwnedSlice(allocator),
        .details = .{ .result_limit_reached = 25 },
    };
    defer result.deinit(allocator);

    const rendered = try formatFindResultAlloc(allocator, result, .{ .expanded = false }, theme, false);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "<toolOutput>file-0.zig</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<muted>\n... (5 more lines,</>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "<warning>[Truncated: 25 results limit]</>") != null);
}
