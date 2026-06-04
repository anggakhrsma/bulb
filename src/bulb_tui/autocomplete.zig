const std = @import("std");
const builtin = @import("builtin");
const fuzzy = @import("fuzzy.zig");

const PATH_DELIMITERS = " \t\"'=";
const default_max_fuzzy_walk_results = 100;
const default_max_fuzzy_suggestions = 20;
const max_walk_depth = 32;

pub const AutocompleteItem = struct {
    value: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,

    pub fn clone(allocator: std.mem.Allocator, item: AutocompleteItem) !AutocompleteItem {
        return .{
            .value = try allocator.dupe(u8, item.value),
            .label = try allocator.dupe(u8, item.label),
            .description = if (item.description) |description| try allocator.dupe(u8, description) else null,
        };
    }

    pub fn deinit(self: AutocompleteItem, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.free(self.label);
        if (self.description) |description| allocator.free(description);
    }
};

pub const ArgumentCompletionCallback = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]AutocompleteItem,

    pub fn call(self: ArgumentCompletionCallback, allocator: std.mem.Allocator, argument_prefix: []const u8) !?[]AutocompleteItem {
        return self.call_fn(self.context, allocator, argument_prefix);
    }
};

pub const SlashCommand = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    argument_hint: ?[]const u8 = null,
    get_argument_completions: ?ArgumentCompletionCallback = null,
};

pub const SuggestionOptions = struct {
    force: bool = false,
    aborted: bool = false,
};

pub const AutocompleteSuggestions = struct {
    items: []AutocompleteItem,
    prefix: []const u8,

    pub fn deinit(self: AutocompleteSuggestions, allocator: std.mem.Allocator) void {
        freeAutocompleteItems(allocator, self.items);
        allocator.free(self.prefix);
    }
};

pub const CompletionApplication = struct {
    lines: [][]u8,
    cursor_line: usize,
    cursor_col: usize,

    pub fn deinit(self: CompletionApplication, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
    }
};

pub const AutocompleteProvider = struct {
    context: ?*anyopaque = null,
    get_suggestions_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const []const u8,
        usize,
        usize,
        SuggestionOptions,
    ) anyerror!?AutocompleteSuggestions,
    apply_completion_fn: *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        []const []const u8,
        usize,
        usize,
        AutocompleteItem,
        []const u8,
    ) anyerror!CompletionApplication,
    should_trigger_file_completion_fn: ?*const fn (?*anyopaque, []const []const u8, usize, usize) bool = null,

    pub fn getSuggestions(
        self: AutocompleteProvider,
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
        options: SuggestionOptions,
    ) !?AutocompleteSuggestions {
        return self.get_suggestions_fn(self.context, allocator, lines, cursor_line, cursor_col, options);
    }

    pub fn applyCompletion(
        self: AutocompleteProvider,
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
        item: AutocompleteItem,
        prefix: []const u8,
    ) !CompletionApplication {
        return self.apply_completion_fn(self.context, allocator, lines, cursor_line, cursor_col, item, prefix);
    }

    pub fn shouldTriggerFileCompletion(
        self: AutocompleteProvider,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
    ) bool {
        const call_fn = self.should_trigger_file_completion_fn orelse return true;
        return call_fn(self.context, lines, cursor_line, cursor_col);
    }
};

const OwnedSlashCommand = struct {
    name: []u8,
    description: ?[]u8 = null,
    argument_hint: ?[]u8 = null,
    get_argument_completions: ?ArgumentCompletionCallback = null,

    fn clone(allocator: std.mem.Allocator, command: SlashCommand) !OwnedSlashCommand {
        return .{
            .name = try allocator.dupe(u8, command.name),
            .description = if (command.description) |description| try allocator.dupe(u8, description) else null,
            .argument_hint = if (command.argument_hint) |hint| try allocator.dupe(u8, hint) else null,
            .get_argument_completions = command.get_argument_completions,
        };
    }

    fn deinit(self: OwnedSlashCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.description) |description| allocator.free(description);
        if (self.argument_hint) |hint| allocator.free(hint);
    }
};

pub const CombinedAutocompleteProvider = struct {
    allocator: std.mem.Allocator,
    commands: []OwnedSlashCommand,
    base_path: []u8,
    fd_path: ?[]u8,
    home_dir: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        commands: []const SlashCommand,
        base_path: []const u8,
        fd_path: ?[]const u8,
    ) !CombinedAutocompleteProvider {
        return initWithHome(allocator, commands, base_path, fd_path, ".");
    }

    pub fn initWithHome(
        allocator: std.mem.Allocator,
        commands: []const SlashCommand,
        base_path: []const u8,
        fd_path: ?[]const u8,
        home_dir: []const u8,
    ) !CombinedAutocompleteProvider {
        var owned_commands = try allocator.alloc(OwnedSlashCommand, commands.len);
        errdefer allocator.free(owned_commands);
        var initialized: usize = 0;
        errdefer {
            for (owned_commands[0..initialized]) |command| command.deinit(allocator);
        }

        for (commands, 0..) |command, index| {
            owned_commands[index] = try OwnedSlashCommand.clone(allocator, command);
            initialized += 1;
        }

        return .{
            .allocator = allocator,
            .commands = owned_commands,
            .base_path = try allocator.dupe(u8, base_path),
            .fd_path = if (fd_path) |path| try allocator.dupe(u8, path) else null,
            .home_dir = try allocator.dupe(u8, home_dir),
        };
    }

    pub fn deinit(self: *CombinedAutocompleteProvider) void {
        for (self.commands) |command| command.deinit(self.allocator);
        self.allocator.free(self.commands);
        self.allocator.free(self.base_path);
        if (self.fd_path) |fd_path| self.allocator.free(fd_path);
        self.allocator.free(self.home_dir);
        self.* = undefined;
    }

    pub fn provider(self: *CombinedAutocompleteProvider) AutocompleteProvider {
        return .{
            .context = self,
            .get_suggestions_fn = combinedGetSuggestions,
            .apply_completion_fn = combinedApplyCompletion,
            .should_trigger_file_completion_fn = combinedShouldTriggerFileCompletion,
        };
    }

    pub fn getSuggestions(
        self: *const CombinedAutocompleteProvider,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
        options: SuggestionOptions,
    ) !?AutocompleteSuggestions {
        if (options.aborted) return null;

        const current_line = if (cursor_line < lines.len) lines[cursor_line] else "";
        const clamped_col = @min(cursor_col, current_line.len);
        const text_before_cursor = current_line[0..clamped_col];

        if (extractAtPrefix(text_before_cursor)) |at_prefix| {
            const parsed = parsePathPrefix(at_prefix);
            const suggestions = try self.getFuzzyFileSuggestions(parsed.raw_prefix, .{
                .is_quoted_prefix = parsed.is_quoted_prefix,
                .aborted = options.aborted,
            });
            if (suggestions.len == 0) return null;
            return .{
                .items = suggestions,
                .prefix = try self.allocator.dupe(u8, at_prefix),
            };
        }

        if (!options.force and std.mem.startsWith(u8, text_before_cursor, "/")) {
            if (std.mem.indexOfScalar(u8, text_before_cursor, ' ') == null) {
                return try self.getCommandSuggestions(text_before_cursor);
            }

            const space_index = std.mem.indexOfScalar(u8, text_before_cursor, ' ').?;
            const command_name = text_before_cursor[1..space_index];
            const argument_text = text_before_cursor[space_index + 1 ..];
            for (self.commands) |command| {
                if (!std.mem.eql(u8, command.name, command_name)) continue;
                const callback = command.get_argument_completions orelse return null;
                const argument_suggestions = try callback.call(self.allocator, argument_text) orelse return null;
                if (argument_suggestions.len == 0) {
                    freeAutocompleteItems(self.allocator, argument_suggestions);
                    return null;
                }
                return .{
                    .items = argument_suggestions,
                    .prefix = try self.allocator.dupe(u8, argument_text),
                };
            }
            return null;
        }

        const path_match = extractPathPrefix(text_before_cursor, options.force) orelse return null;
        const suggestions = try self.getFileSuggestions(path_match);
        if (suggestions.len == 0) return null;
        return .{
            .items = suggestions,
            .prefix = try self.allocator.dupe(u8, path_match),
        };
    }

    pub fn applyCompletion(
        self: *const CombinedAutocompleteProvider,
        lines: []const []const u8,
        cursor_line: usize,
        cursor_col: usize,
        item: AutocompleteItem,
        prefix: []const u8,
    ) !CompletionApplication {
        const line_count = @max(lines.len, cursor_line + 1);
        var new_lines = try self.allocator.alloc([]u8, line_count);
        errdefer self.allocator.free(new_lines);
        var initialized: usize = 0;
        errdefer {
            for (new_lines[0..initialized]) |line| self.allocator.free(line);
        }

        for (0..line_count) |index| {
            const source = if (index < lines.len) lines[index] else "";
            new_lines[index] = try self.allocator.dupe(u8, source);
            initialized += 1;
        }

        const current_line = new_lines[cursor_line];
        const clamped_col = @min(cursor_col, current_line.len);
        const prefix_len = @min(prefix.len, clamped_col);
        const before_prefix = current_line[0 .. clamped_col - prefix_len];
        const after_cursor = current_line[clamped_col..];
        const is_quoted_prefix = std.mem.startsWith(u8, prefix, "\"") or std.mem.startsWith(u8, prefix, "@\"");
        const has_leading_quote_after_cursor = std.mem.startsWith(u8, after_cursor, "\"");
        const has_trailing_quote_in_item = std.mem.endsWith(u8, item.value, "\"");
        const adjusted_after_cursor = if (is_quoted_prefix and has_trailing_quote_in_item and has_leading_quote_after_cursor)
            after_cursor[1..]
        else
            after_cursor;

        const is_slash_command =
            std.mem.startsWith(u8, prefix, "/") and
            std.mem.trim(u8, before_prefix, " \t\r\n").len == 0 and
            std.mem.indexOfScalar(u8, prefix[1..], '/') == null;

        var replacement: []u8 = undefined;
        var new_cursor_col: usize = 0;
        if (is_slash_command) {
            replacement = try std.mem.concat(self.allocator, u8, &.{ before_prefix, "/", item.value, " ", adjusted_after_cursor });
            new_cursor_col = before_prefix.len + item.value.len + 2;
        } else if (std.mem.startsWith(u8, prefix, "@")) {
            const is_directory = std.mem.endsWith(u8, item.label, "/");
            const suffix = if (is_directory) "" else " ";
            replacement = try std.mem.concat(self.allocator, u8, &.{ before_prefix, item.value, suffix, adjusted_after_cursor });
            const cursor_offset = if (is_directory and has_trailing_quote_in_item) item.value.len - 1 else item.value.len;
            new_cursor_col = before_prefix.len + cursor_offset + suffix.len;
        } else {
            replacement = try std.mem.concat(self.allocator, u8, &.{ before_prefix, item.value, adjusted_after_cursor });
            const is_directory = std.mem.endsWith(u8, item.label, "/");
            const cursor_offset = if (is_directory and has_trailing_quote_in_item) item.value.len - 1 else item.value.len;
            new_cursor_col = before_prefix.len + cursor_offset;
        }
        errdefer self.allocator.free(replacement);

        self.allocator.free(new_lines[cursor_line]);
        new_lines[cursor_line] = replacement;

        return .{
            .lines = new_lines,
            .cursor_line = cursor_line,
            .cursor_col = new_cursor_col,
        };
    }

    pub fn shouldTriggerFileCompletion(_: *const CombinedAutocompleteProvider, lines: []const []const u8, cursor_line: usize, cursor_col: usize) bool {
        const current_line = if (cursor_line < lines.len) lines[cursor_line] else "";
        const clamped_col = @min(cursor_col, current_line.len);
        const text_before_cursor = std.mem.trim(u8, current_line[0..clamped_col], " \t\r\n");
        if (std.mem.startsWith(u8, text_before_cursor, "/") and std.mem.indexOfScalar(u8, text_before_cursor, ' ') == null) {
            return false;
        }
        return true;
    }

    fn getCommandSuggestions(self: *const CombinedAutocompleteProvider, text_before_cursor: []const u8) !?AutocompleteSuggestions {
        const prefix = text_before_cursor[1..];
        var command_items = try self.allocator.alloc(CommandFilterItem, self.commands.len);
        defer {
            for (command_items) |item| item.deinit(self.allocator);
            self.allocator.free(command_items);
        }

        for (self.commands, 0..) |command, index| {
            const description = try commandDescription(self.allocator, command.description, command.argument_hint);
            command_items[index] = .{
                .name = command.name,
                .label = command.name,
                .description = description,
            };
        }

        const filtered = try fuzzy.fuzzyFilter(self.allocator, CommandFilterItem, command_items, prefix, CommandFilterItem.text);
        defer self.allocator.free(filtered);
        if (filtered.len == 0) return null;

        var items = try self.allocator.alloc(AutocompleteItem, filtered.len);
        errdefer freeAutocompleteItems(self.allocator, items);
        for (filtered, 0..) |command, index| {
            items[index] = .{
                .value = try self.allocator.dupe(u8, command.name),
                .label = try self.allocator.dupe(u8, command.label),
                .description = if (command.description) |description| try self.allocator.dupe(u8, description) else null,
            };
        }

        return .{
            .items = items,
            .prefix = try self.allocator.dupe(u8, text_before_cursor),
        };
    }

    fn getFileSuggestions(self: *const CombinedAutocompleteProvider, prefix: []const u8) ![]AutocompleteItem {
        const parsed = parsePathPrefix(prefix);
        const raw_prefix = parsed.raw_prefix;
        const expanded_prefix = try self.expandHomePath(raw_prefix);
        defer self.allocator.free(expanded_prefix);

        const is_root_prefix =
            raw_prefix.len == 0 or
            std.mem.eql(u8, raw_prefix, "./") or
            std.mem.eql(u8, raw_prefix, "../") or
            std.mem.eql(u8, raw_prefix, "~") or
            std.mem.eql(u8, raw_prefix, "~/") or
            std.mem.eql(u8, raw_prefix, "/") or
            (parsed.is_at_prefix and raw_prefix.len == 0);

        var search_dir: []u8 = undefined;
        var search_prefix: []const u8 = "";

        if (is_root_prefix) {
            search_dir = if (std.mem.startsWith(u8, raw_prefix, "~") or std.fs.path.isAbsolute(expanded_prefix))
                try self.allocator.dupe(u8, expanded_prefix)
            else
                try joinFsPath(self.allocator, self.base_path, expanded_prefix);
        } else if (std.mem.endsWith(u8, raw_prefix, "/")) {
            search_dir = if (std.mem.startsWith(u8, raw_prefix, "~") or std.fs.path.isAbsolute(expanded_prefix))
                try self.allocator.dupe(u8, expanded_prefix)
            else
                try joinFsPath(self.allocator, self.base_path, expanded_prefix);
        } else {
            const dir = dirnameDisplay(expanded_prefix);
            const file = basenameDisplay(expanded_prefix);
            search_dir = if (std.mem.startsWith(u8, raw_prefix, "~") or std.fs.path.isAbsolute(expanded_prefix))
                try self.allocator.dupe(u8, dir)
            else
                try joinFsPath(self.allocator, self.base_path, dir);
            search_prefix = file;
        }
        defer self.allocator.free(search_dir);

        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = openDirPath(io, search_dir, .{ .iterate = true }) catch return &.{};
        defer dir.close(io);

        var suggestions: std.ArrayList(AutocompleteItem) = .empty;
        errdefer freeAutocompleteItems(self.allocator, suggestions.items);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (!startsWithIgnoreCaseAscii(entry.name, search_prefix)) continue;
            const is_directory = try entryIsDirectory(io, dir, entry.name, entry.kind);
            const display_path = try self.displayPathForEntry(raw_prefix, entry.name);
            defer self.allocator.free(display_path);
            const path_value = if (is_directory)
                try std.mem.concat(self.allocator, u8, &.{ display_path, "/" })
            else
                try self.allocator.dupe(u8, display_path);
            defer self.allocator.free(path_value);

            const value = try buildCompletionValue(self.allocator, path_value, .{
                .is_directory = is_directory,
                .is_at_prefix = parsed.is_at_prefix,
                .is_quoted_prefix = parsed.is_quoted_prefix,
            });
            errdefer self.allocator.free(value);
            const label = try std.mem.concat(self.allocator, u8, &.{ entry.name, if (is_directory) "/" else "" });
            errdefer self.allocator.free(label);

            try suggestions.append(self.allocator, .{
                .value = value,
                .label = label,
            });
        }

        std.mem.sort(AutocompleteItem, suggestions.items, {}, lessFileSuggestion);
        return suggestions.toOwnedSlice(self.allocator);
    }

    fn getFuzzyFileSuggestions(
        self: *const CombinedAutocompleteProvider,
        query: []const u8,
        options: struct {
            is_quoted_prefix: bool,
            aborted: bool,
        },
    ) ![]AutocompleteItem {
        if (options.aborted) return &.{};

        var scoped = try self.resolveScopedFuzzyQuery(query);
        defer if (scoped) |*value| value.deinit(self.allocator);

        const base_dir = if (scoped) |value| value.base_dir else self.base_path;
        const fd_query = if (scoped) |value| value.query else query;

        const entries = try walkDirectoryNative(self.allocator, base_dir, default_max_fuzzy_walk_results);
        defer freeFuzzyFileEntries(self.allocator, entries);

        const ScoredEntry = struct {
            entry: FuzzyFileEntry,
            score: i32,
            index: usize,

            fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
                if (lhs.score > rhs.score) return true;
                if (lhs.score < rhs.score) return false;
                return lhs.index < rhs.index;
            }
        };

        var scored: std.ArrayList(ScoredEntry) = .empty;
        defer scored.deinit(self.allocator);
        for (entries, 0..) |entry, index| {
            const score = if (fd_query.len > 0) scoreEntry(entry.path, fd_query, entry.is_directory) else 1;
            if (score > 0) try scored.append(self.allocator, .{ .entry = entry, .score = score, .index = index });
        }

        std.mem.sort(ScoredEntry, scored.items, {}, ScoredEntry.lessThan);
        const count = @min(default_max_fuzzy_suggestions, scored.items.len);
        var suggestions = try self.allocator.alloc(AutocompleteItem, count);
        errdefer freeAutocompleteItems(self.allocator, suggestions);

        for (scored.items[0..count], 0..) |scored_entry, index| {
            const entry = scored_entry.entry;
            const path_without_slash = if (entry.is_directory and std.mem.endsWith(u8, entry.path, "/"))
                entry.path[0 .. entry.path.len - 1]
            else
                entry.path;
            const display_path = if (scoped) |value|
                try scopedPathForDisplay(self.allocator, value.display_base, path_without_slash)
            else
                try self.allocator.dupe(u8, path_without_slash);
            errdefer self.allocator.free(display_path);

            const entry_name = basenameDisplay(path_without_slash);
            const completion_path = if (entry.is_directory)
                try std.mem.concat(self.allocator, u8, &.{ display_path, "/" })
            else
                try self.allocator.dupe(u8, display_path);
            defer self.allocator.free(completion_path);

            const value = try buildCompletionValue(self.allocator, completion_path, .{
                .is_directory = entry.is_directory,
                .is_at_prefix = true,
                .is_quoted_prefix = options.is_quoted_prefix,
            });
            errdefer self.allocator.free(value);
            const label = try std.mem.concat(self.allocator, u8, &.{ entry_name, if (entry.is_directory) "/" else "" });
            errdefer self.allocator.free(label);

            suggestions[index] = .{
                .value = value,
                .label = label,
                .description = display_path,
            };
        }

        return suggestions;
    }

    fn expandHomePath(self: *const CombinedAutocompleteProvider, path: []const u8) ![]u8 {
        if (std.mem.eql(u8, path, "~")) return self.allocator.dupe(u8, self.home_dir);
        if (std.mem.startsWith(u8, path, "~/")) {
            const expanded = try joinFsPath(self.allocator, self.home_dir, path[2..]);
            if (std.mem.endsWith(u8, path, "/") and !std.mem.endsWith(u8, expanded, "/")) {
                const with_slash = try std.mem.concat(self.allocator, u8, &.{ expanded, "/" });
                self.allocator.free(expanded);
                return with_slash;
            }
            return expanded;
        }
        return self.allocator.dupe(u8, path);
    }

    fn resolveScopedFuzzyQuery(self: *const CombinedAutocompleteProvider, raw_query: []const u8) !?ScopedFuzzyQuery {
        const normalized_query = try toDisplayPathAlloc(self.allocator, raw_query);
        defer self.allocator.free(normalized_query);

        const slash_index = lastIndexOfScalar(normalized_query, '/') orelse return null;
        const display_base = try self.allocator.dupe(u8, normalized_query[0 .. slash_index + 1]);
        errdefer self.allocator.free(display_base);
        const query = try self.allocator.dupe(u8, normalized_query[slash_index + 1 ..]);
        errdefer self.allocator.free(query);

        const base_dir = if (std.mem.startsWith(u8, display_base, "~/"))
            try self.expandHomePath(display_base)
        else if (std.mem.startsWith(u8, display_base, "/"))
            try self.allocator.dupe(u8, display_base)
        else
            try joinFsPath(self.allocator, self.base_path, display_base);
        errdefer self.allocator.free(base_dir);

        if (!isDirectoryPath(base_dir)) {
            self.allocator.free(base_dir);
            self.allocator.free(query);
            self.allocator.free(display_base);
            return null;
        }
        return .{
            .base_dir = base_dir,
            .query = query,
            .display_base = display_base,
        };
    }

    fn displayPathForEntry(self: *const CombinedAutocompleteProvider, raw_prefix: []const u8, name: []const u8) ![]u8 {
        const display_prefix = raw_prefix;
        if (std.mem.endsWith(u8, display_prefix, "/")) {
            return std.mem.concat(self.allocator, u8, &.{ display_prefix, name });
        }

        if (std.mem.indexOfScalar(u8, display_prefix, '/') != null or std.mem.indexOfScalar(u8, display_prefix, '\\') != null) {
            if (std.mem.startsWith(u8, display_prefix, "~/")) {
                const home_relative_dir = display_prefix[2..];
                const dir = dirnameDisplay(home_relative_dir);
                if (std.mem.eql(u8, dir, ".")) {
                    return std.mem.concat(self.allocator, u8, &.{ "~/", name });
                }
                return std.mem.concat(self.allocator, u8, &.{ "~/", dir, "/", name });
            }

            if (std.mem.startsWith(u8, display_prefix, "/")) {
                const dir = dirnameDisplay(display_prefix);
                if (std.mem.eql(u8, dir, "/")) {
                    return std.mem.concat(self.allocator, u8, &.{ "/", name });
                }
                return std.mem.concat(self.allocator, u8, &.{ dir, "/", name });
            }

            const dir = dirnameDisplay(display_prefix);
            var relative_path = try joinDisplayPath(self.allocator, dir, name);
            if (std.mem.startsWith(u8, display_prefix, "./") and !std.mem.startsWith(u8, relative_path, "./")) {
                const with_dot = try std.mem.concat(self.allocator, u8, &.{ "./", relative_path });
                self.allocator.free(relative_path);
                relative_path = with_dot;
            }
            return relative_path;
        }

        if (std.mem.startsWith(u8, display_prefix, "~")) {
            return std.mem.concat(self.allocator, u8, &.{ "~/", name });
        }
        return self.allocator.dupe(u8, name);
    }
};

fn combinedGetSuggestions(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    cursor_line: usize,
    cursor_col: usize,
    options: SuggestionOptions,
) !?AutocompleteSuggestions {
    const provider: *CombinedAutocompleteProvider = @ptrCast(@alignCast(context.?));
    const suggestions = try provider.getSuggestions(lines, cursor_line, cursor_col, options) orelse return null;
    defer suggestions.deinit(provider.allocator);

    return .{
        .items = try cloneAutocompleteItems(allocator, suggestions.items),
        .prefix = try allocator.dupe(u8, suggestions.prefix),
    };
}

fn combinedApplyCompletion(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    cursor_line: usize,
    cursor_col: usize,
    item: AutocompleteItem,
    prefix: []const u8,
) !CompletionApplication {
    const provider: *CombinedAutocompleteProvider = @ptrCast(@alignCast(context.?));
    var applied = try provider.applyCompletion(lines, cursor_line, cursor_col, item, prefix);
    defer applied.deinit(provider.allocator);

    var cloned_lines = try allocator.alloc([]u8, applied.lines.len);
    errdefer allocator.free(cloned_lines);
    var initialized: usize = 0;
    errdefer {
        for (cloned_lines[0..initialized]) |line| allocator.free(line);
    }
    for (applied.lines, 0..) |line, index| {
        cloned_lines[index] = try allocator.dupe(u8, line);
        initialized += 1;
    }

    return .{
        .lines = cloned_lines,
        .cursor_line = applied.cursor_line,
        .cursor_col = applied.cursor_col,
    };
}

fn combinedShouldTriggerFileCompletion(
    context: ?*anyopaque,
    lines: []const []const u8,
    cursor_line: usize,
    cursor_col: usize,
) bool {
    const provider: *CombinedAutocompleteProvider = @ptrCast(@alignCast(context.?));
    return provider.shouldTriggerFileCompletion(lines, cursor_line, cursor_col);
}

const CommandFilterItem = struct {
    name: []const u8,
    label: []const u8,
    description: ?[]u8,

    fn text(item: CommandFilterItem) []const u8 {
        return item.name;
    }

    fn deinit(self: CommandFilterItem, allocator: std.mem.Allocator) void {
        if (self.description) |description| allocator.free(description);
    }
};

const ParsedPathPrefix = struct {
    raw_prefix: []const u8,
    is_at_prefix: bool,
    is_quoted_prefix: bool,
};

const BuildCompletionOptions = struct {
    is_directory: bool,
    is_at_prefix: bool,
    is_quoted_prefix: bool,
};

const ScopedFuzzyQuery = struct {
    base_dir: []u8,
    query: []u8,
    display_base: []u8,

    fn deinit(self: ScopedFuzzyQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.base_dir);
        allocator.free(self.query);
        allocator.free(self.display_base);
    }
};

const FuzzyFileEntry = struct {
    path: []u8,
    is_directory: bool,

    fn deinit(self: FuzzyFileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub fn freeAutocompleteItems(allocator: std.mem.Allocator, items: []AutocompleteItem) void {
    for (items) |item| item.deinit(allocator);
    allocator.free(items);
}

pub fn cloneAutocompleteItems(allocator: std.mem.Allocator, items: []const AutocompleteItem) ![]AutocompleteItem {
    var owned_items = try allocator.alloc(AutocompleteItem, items.len);
    var initialized: usize = 0;
    errdefer {
        for (owned_items[0..initialized]) |item| item.deinit(allocator);
        allocator.free(owned_items);
    }
    for (items, 0..) |item, index| {
        owned_items[index] = try AutocompleteItem.clone(allocator, item);
        initialized += 1;
    }
    return owned_items;
}

fn commandDescription(allocator: std.mem.Allocator, description: ?[]const u8, argument_hint: ?[]const u8) !?[]u8 {
    if (argument_hint) |hint| {
        if (description) |desc| {
            return try std.mem.concat(allocator, u8, &.{ hint, " - ", desc });
        }
        return try allocator.dupe(u8, hint);
    }
    if (description) |desc| return try allocator.dupe(u8, desc);
    return null;
}

fn parsePathPrefix(prefix: []const u8) ParsedPathPrefix {
    if (std.mem.startsWith(u8, prefix, "@\"")) {
        return .{ .raw_prefix = prefix[2..], .is_at_prefix = true, .is_quoted_prefix = true };
    }
    if (std.mem.startsWith(u8, prefix, "\"")) {
        return .{ .raw_prefix = prefix[1..], .is_at_prefix = false, .is_quoted_prefix = true };
    }
    if (std.mem.startsWith(u8, prefix, "@")) {
        return .{ .raw_prefix = prefix[1..], .is_at_prefix = true, .is_quoted_prefix = false };
    }
    return .{ .raw_prefix = prefix, .is_at_prefix = false, .is_quoted_prefix = false };
}

fn buildCompletionValue(allocator: std.mem.Allocator, path: []const u8, options: BuildCompletionOptions) ![]u8 {
    _ = options.is_directory;
    const needs_quotes = options.is_quoted_prefix or std.mem.indexOfScalar(u8, path, ' ') != null;
    const prefix = if (options.is_at_prefix) "@" else "";
    if (!needs_quotes) return std.mem.concat(allocator, u8, &.{ prefix, path });
    return std.mem.concat(allocator, u8, &.{ prefix, "\"", path, "\"" });
}

fn extractAtPrefix(text: []const u8) ?[]const u8 {
    if (extractQuotedPrefix(text)) |quoted_prefix| {
        if (std.mem.startsWith(u8, quoted_prefix, "@\"")) return quoted_prefix;
    }

    const token_start = if (findLastDelimiter(text)) |last| last + 1 else 0;
    if (token_start < text.len and text[token_start] == '@') {
        return text[token_start..];
    }
    return null;
}

fn extractPathPrefix(text: []const u8, force_extract: bool) ?[]const u8 {
    if (extractQuotedPrefix(text)) |quoted_prefix| return quoted_prefix;

    const token_start = if (findLastDelimiter(text)) |last| last + 1 else 0;
    const path_prefix = text[token_start..];

    if (force_extract) return path_prefix;
    if (std.mem.indexOfScalar(u8, path_prefix, '/') != null or
        std.mem.startsWith(u8, path_prefix, ".") or
        std.mem.startsWith(u8, path_prefix, "~/"))
    {
        return path_prefix;
    }

    if (path_prefix.len == 0 and std.mem.endsWith(u8, text, " ")) return path_prefix;
    return null;
}

fn extractQuotedPrefix(text: []const u8) ?[]const u8 {
    const quote_start = findUnclosedQuoteStart(text) orelse return null;
    if (quote_start > 0 and text[quote_start - 1] == '@') {
        if (!isTokenStart(text, quote_start - 1)) return null;
        return text[quote_start - 1 ..];
    }
    if (!isTokenStart(text, quote_start)) return null;
    return text[quote_start..];
}

fn findUnclosedQuoteStart(text: []const u8) ?usize {
    var in_quotes = false;
    var quote_start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte != '"') continue;
        in_quotes = !in_quotes;
        if (in_quotes) quote_start = index;
    }
    return if (in_quotes) quote_start else null;
}

fn findLastDelimiter(text: []const u8) ?usize {
    var index = text.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.indexOfScalar(u8, PATH_DELIMITERS, text[index]) != null) return index;
    }
    return null;
}

fn isTokenStart(text: []const u8, index: usize) bool {
    return index == 0 or std.mem.indexOfScalar(u8, PATH_DELIMITERS, text[index - 1]) != null;
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn entryIsDirectory(io: std.Io, dir: std.Io.Dir, name: []const u8, kind: std.Io.File.Kind) !bool {
    if (kind == .directory) return true;
    if (kind != .sym_link) return false;
    const stat = dir.statFile(io, name, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .directory;
}

fn lessFileSuggestion(_: void, lhs: AutocompleteItem, rhs: AutocompleteItem) bool {
    const lhs_is_dir = std.mem.endsWith(u8, lhs.label, "/");
    const rhs_is_dir = std.mem.endsWith(u8, rhs.label, "/");
    if (lhs_is_dir and !rhs_is_dir) return true;
    if (!lhs_is_dir and rhs_is_dir) return false;
    return std.mem.order(u8, lhs.label, rhs.label) == .lt;
}

fn scoreEntry(file_path: []const u8, query: []const u8, is_directory: bool) i32 {
    const file_name = basenameDisplay(if (is_directory and std.mem.endsWith(u8, file_path, "/")) file_path[0 .. file_path.len - 1] else file_path);
    var score: i32 = 0;
    if (eqlIgnoreCaseAscii(file_name, query)) {
        score = 100;
    } else if (startsWithIgnoreCaseAscii(file_name, query)) {
        score = 80;
    } else if (containsIgnoreCaseAscii(file_name, query)) {
        score = 50;
    } else if (containsIgnoreCaseAscii(file_path, query)) {
        score = 30;
    }
    if (is_directory and score > 0) score += 10;
    return score;
}

fn walkDirectoryNative(allocator: std.mem.Allocator, base_dir: []const u8, max_results: usize) ![]FuzzyFileEntry {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = openDirPath(io, base_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var results: std.ArrayList(FuzzyFileEntry) = .empty;
    errdefer freeFuzzyFileEntries(allocator, results.items);
    try walkDirectoryRecursive(allocator, io, dir, "", &results, max_results, 0);
    return results.toOwnedSlice(allocator);
}

fn walkDirectoryRecursive(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    results: *std.ArrayList(FuzzyFileEntry),
    max_results: usize,
    depth: usize,
) !void {
    if (results.items.len >= max_results or depth > max_walk_depth) return;

    var iterator = dir.iterate();
    while (results.items.len < max_results) {
        const maybe_entry = iterator.next(io) catch break;
        const entry = maybe_entry orelse break;

        const relative = try joinDisplayPath(allocator, prefix, entry.name);
        defer allocator.free(relative);
        if (isGitPath(relative)) continue;

        const is_directory = try entryIsDirectory(io, dir, entry.name, entry.kind);
        if (is_directory) {
            const display_path = try std.mem.concat(allocator, u8, &.{ relative, "/" });
            errdefer allocator.free(display_path);
            try results.append(allocator, .{ .path = display_path, .is_directory = true });

            var child = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = true }) catch continue;
            defer child.close(io);
            try walkDirectoryRecursive(allocator, io, child, relative, results, max_results, depth + 1);
        } else if (entry.kind == .file or entry.kind == .sym_link or entry.kind == .unknown) {
            try results.append(allocator, .{
                .path = try allocator.dupe(u8, relative),
                .is_directory = false,
            });
        }
    }
}

fn freeFuzzyFileEntries(allocator: std.mem.Allocator, entries: []FuzzyFileEntry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn scopedPathForDisplay(allocator: std.mem.Allocator, display_base: []const u8, relative_path: []const u8) ![]u8 {
    const normalized_relative = try toDisplayPathAlloc(allocator, relative_path);
    defer allocator.free(normalized_relative);
    if (std.mem.eql(u8, display_base, "/")) {
        return std.mem.concat(allocator, u8, &.{ "/", normalized_relative });
    }
    return std.mem.concat(allocator, u8, &.{ toDisplayPathSlice(display_base), normalized_relative });
}

fn isDirectoryPath(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .directory;
}

fn isGitPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".git") or
        std.mem.startsWith(u8, path, ".git/") or
        std.mem.indexOf(u8, path, "/.git/") != null;
}

fn joinFsPath(allocator: std.mem.Allocator, base: []const u8, child: []const u8) ![]u8 {
    if (child.len == 0) return allocator.dupe(u8, base);
    return std.fs.path.join(allocator, &.{ base, child });
}

fn joinDisplayPath(allocator: std.mem.Allocator, base: []const u8, child: []const u8) ![]u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return allocator.dupe(u8, child);
    if (std.mem.eql(u8, base, "/")) return std.mem.concat(allocator, u8, &.{ "/", child });
    if (std.mem.endsWith(u8, base, "/")) return std.mem.concat(allocator, u8, &.{ base, child });
    return std.mem.concat(allocator, u8, &.{ base, "/", child });
}

fn dirnameDisplay(path: []const u8) []const u8 {
    const trimmed = trimTrailingSeparators(path);
    if (trimmed.len == 0) return ".";
    if (std.mem.eql(u8, trimmed, "/")) return "/";
    const slash = lastIndexOfAny(trimmed, "/\\") orelse return ".";
    if (slash == 0) return trimmed[0..1];
    return trimmed[0..slash];
}

fn basenameDisplay(path: []const u8) []const u8 {
    const trimmed = trimTrailingSeparators(path);
    if (trimmed.len == 0) return "";
    const slash = lastIndexOfAny(trimmed, "/\\") orelse return trimmed;
    return trimmed[slash + 1 ..];
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    if (path.len <= 1) return path;
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
    return path[0..end];
}

fn lastIndexOfScalar(input: []const u8, scalar: u8) ?usize {
    var index = input.len;
    while (index > 0) {
        index -= 1;
        if (input[index] == scalar) return index;
    }
    return null;
}

fn lastIndexOfAny(input: []const u8, needles: []const u8) ?usize {
    var index = input.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.indexOfScalar(u8, needles, input[index]) != null) return index;
    }
    return null;
}

fn toDisplayPathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const output = try allocator.dupe(u8, value);
    for (output) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return output;
}

fn toDisplayPathSlice(value: []const u8) []const u8 {
    return value;
}

fn startsWithIgnoreCaseAscii(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    return eqlIgnoreCaseAscii(text[0..prefix.len], prefix);
}

fn containsIgnoreCaseAscii(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    var index: usize = 0;
    while (index + needle.len <= text.len) : (index += 1) {
        if (eqlIgnoreCaseAscii(text[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn eqlIgnoreCaseAscii(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn makeAbsoluteDir(path: []const u8) !void {
    const io = std.testing.io;
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn writeAbsoluteFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const parent = dirnameDisplay(path);
    if (!std.mem.eql(u8, parent, ".")) try makeAbsoluteDir(parent);
    const io = std.testing.io;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
    _ = allocator;
}

fn setupFolder(allocator: std.mem.Allocator, base_dir: []const u8, dirs: []const []const u8, files: []const FileFixture) !void {
    for (dirs) |dir| {
        const path = try std.fs.path.join(allocator, &.{ base_dir, dir });
        defer allocator.free(path);
        try makeAbsoluteDir(path);
    }
    for (files) |file| {
        const path = try std.fs.path.join(allocator, &.{ base_dir, file.path });
        defer allocator.free(path);
        try writeAbsoluteFile(allocator, path, file.content);
    }
}

const FileFixture = struct {
    path: []const u8,
    content: []const u8 = "content",
};

fn valuesContain(items: []AutocompleteItem, expected: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.value, expected)) return true;
    }
    return false;
}

fn valuesExcludeGitDir(items: []AutocompleteItem) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item.value, "@.git") or std.mem.startsWith(u8, item.value, "@.git/")) return false;
    }
    return true;
}

fn suggestionValuesAlloc(allocator: std.mem.Allocator, suggestions: AutocompleteSuggestions) ![][]const u8 {
    const values = try allocator.alloc([]const u8, suggestions.items.len);
    for (suggestions.items, 0..) |item, index| values[index] = item.value;
    return values;
}

test "CombinedAutocompleteProvider extracts path prefixes when forced" {
    const allocator = std.testing.allocator;
    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, "/tmp", null);
    defer provider.deinit();

    const root_line = [_][]const u8{"hey /"};
    const root_result = try provider.getSuggestions(&root_line, 0, 5, .{ .force = true });
    try std.testing.expect(root_result != null);
    if (root_result) |result| {
        defer result.deinit(allocator);
        try std.testing.expectEqualStrings("/", result.prefix);
    }

    const absolute_line = [_][]const u8{"/A"};
    const absolute_result = try provider.getSuggestions(&absolute_line, 0, 2, .{ .force = true });
    if (absolute_result) |result| {
        defer result.deinit(allocator);
        try std.testing.expectEqualStrings("/A", result.prefix);
    }

    const slash_command_line = [_][]const u8{"/model"};
    const slash_result = try provider.getSuggestions(&slash_command_line, 0, 6, .{ .force = true });
    try std.testing.expect(slash_result == null);

    const argument_line = [_][]const u8{"/command /"};
    const argument_result = try provider.getSuggestions(&argument_line, 0, 10, .{ .force = true });
    try std.testing.expect(argument_result != null);
    if (argument_result) |result| {
        defer result.deinit(allocator);
        try std.testing.expectEqualStrings("/", result.prefix);
    }
}

test "CombinedAutocompleteProvider returns fuzzy @ files and folders" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(base_dir);

    try setupFolder(allocator, base_dir, &.{"src"}, &.{.{ .path = "README.md", .content = "readme" }});

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const line = [_][]const u8{"@"};
    const result = (try provider.getSuggestions(&line, 0, 1, .{})).?;
    defer result.deinit(allocator);

    try std.testing.expect(valuesContain(result.items, "@README.md"));
    try std.testing.expect(valuesContain(result.items, "@src/"));
}

test "CombinedAutocompleteProvider fuzzy @ matching covers extension, case, directories, and nested paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(base_dir);

    try setupFolder(
        allocator,
        base_dir,
        &.{"src"},
        &.{
            .{ .path = "file.txt" },
            .{ .path = "README.md", .content = "readme" },
            .{ .path = "src/index.ts", .content = "export {};\n" },
            .{ .path = "src.txt", .content = "text" },
        },
    );

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const file_line = [_][]const u8{"@file.txt"};
    const file_result = (try provider.getSuggestions(&file_line, 0, file_line[0].len, .{})).?;
    defer file_result.deinit(allocator);
    try std.testing.expect(valuesContain(file_result.items, "@file.txt"));

    const case_line = [_][]const u8{"@re"};
    const case_result = (try provider.getSuggestions(&case_line, 0, case_line[0].len, .{})).?;
    defer case_result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), case_result.items.len);
    try std.testing.expectEqualStrings("@README.md", case_result.items[0].value);

    const dir_line = [_][]const u8{"@src"};
    const dir_result = (try provider.getSuggestions(&dir_line, 0, dir_line[0].len, .{})).?;
    defer dir_result.deinit(allocator);
    try std.testing.expectEqualStrings("@src/", dir_result.items[0].value);
    try std.testing.expect(valuesContain(dir_result.items, "@src.txt"));

    const nested_line = [_][]const u8{"@index"};
    const nested_result = (try provider.getSuggestions(&nested_line, 0, nested_line[0].len, .{})).?;
    defer nested_result.deinit(allocator);
    try std.testing.expect(valuesContain(nested_result.items, "@src/index.ts"));
}

test "CombinedAutocompleteProvider fuzzy @ full path and scoped matching" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root_dir);
    const base_dir = try std.fs.path.join(allocator, &.{ root_dir, "cwd" });
    defer allocator.free(base_dir);
    const outside_dir = try std.fs.path.join(allocator, &.{ root_dir, "outside" });
    defer allocator.free(outside_dir);
    try makeAbsoluteDir(base_dir);
    try makeAbsoluteDir(outside_dir);

    try setupFolder(
        allocator,
        base_dir,
        &.{},
        &.{
            .{ .path = "packages/tui/src/autocomplete.ts", .content = "export {};" },
            .{ .path = "packages/ai/src/autocomplete.ts", .content = "export {};" },
            .{ .path = "src/components/Button.tsx", .content = "export {};" },
            .{ .path = "src/utils/helpers.ts", .content = "export {};" },
        },
    );
    try setupFolder(
        allocator,
        outside_dir,
        &.{},
        &.{
            .{ .path = "nested/alpha.ts", .content = "export {};" },
            .{ .path = "nested/deeper/also-alpha.ts", .content = "export {};" },
            .{ .path = "nested/deeper/zzz.ts", .content = "export {};" },
        },
    );

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const deep_line = [_][]const u8{"@tui/src/auto"};
    const deep_result = (try provider.getSuggestions(&deep_line, 0, deep_line[0].len, .{})).?;
    defer deep_result.deinit(allocator);
    try std.testing.expect(valuesContain(deep_result.items, "@packages/tui/src/autocomplete.ts"));
    try std.testing.expect(!valuesContain(deep_result.items, "@packages/ai/src/autocomplete.ts"));

    const middle_line = [_][]const u8{"@components/"};
    const middle_result = (try provider.getSuggestions(&middle_line, 0, middle_line[0].len, .{})).?;
    defer middle_result.deinit(allocator);
    try std.testing.expect(valuesContain(middle_result.items, "@src/components/Button.tsx"));
    try std.testing.expect(!valuesContain(middle_result.items, "@src/utils/helpers.ts"));

    const scoped_line = [_][]const u8{"@../outside/a"};
    const scoped_result = (try provider.getSuggestions(&scoped_line, 0, scoped_line[0].len, .{})).?;
    defer scoped_result.deinit(allocator);
    try std.testing.expect(valuesContain(scoped_result.items, "@../outside/nested/alpha.ts"));
    try std.testing.expect(valuesContain(scoped_result.items, "@../outside/nested/deeper/also-alpha.ts"));
    try std.testing.expect(!valuesContain(scoped_result.items, "@../outside/nested/deeper/zzz.ts"));
}

test "CombinedAutocompleteProvider quotes @ paths with spaces and excludes .git" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(base_dir);

    try setupFolder(
        allocator,
        base_dir,
        &.{ "my folder", ".pi", ".github", ".git" },
        &.{
            .{ .path = "my folder/test.txt" },
            .{ .path = ".pi/config.json", .content = "{}" },
            .{ .path = ".github/workflows/ci.yml", .content = "name: ci" },
            .{ .path = ".git/config", .content = "[core]" },
        },
    );

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const spaced_line = [_][]const u8{"@my"};
    const spaced_result = (try provider.getSuggestions(&spaced_line, 0, spaced_line[0].len, .{})).?;
    defer spaced_result.deinit(allocator);
    try std.testing.expect(valuesContain(spaced_result.items, "@\"my folder/\""));

    const hidden_line = [_][]const u8{"@"};
    const hidden_result = (try provider.getSuggestions(&hidden_line, 0, hidden_line[0].len, .{})).?;
    defer hidden_result.deinit(allocator);
    try std.testing.expect(valuesContain(hidden_result.items, "@.pi/"));
    try std.testing.expect(valuesContain(hidden_result.items, "@.github/"));
    try std.testing.expect(valuesExcludeGitDir(hidden_result.items));
}

test "CombinedAutocompleteProvider follows symlinked files and directories for fuzzy @ search" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root_dir);
    const base_dir = try std.fs.path.join(allocator, &.{ root_dir, "cwd" });
    defer allocator.free(base_dir);
    const outside_dir = try std.fs.path.join(allocator, &.{ root_dir, "outside" });
    defer allocator.free(outside_dir);
    try makeAbsoluteDir(base_dir);
    try makeAbsoluteDir(outside_dir);

    try setupFolder(allocator, base_dir, &.{}, &.{ .{ .path = "dir/some_file.txt", .content = "real" }, .{ .path = "original.txt" } });
    try setupFolder(allocator, outside_dir, &.{}, &.{ .{ .path = "some_file.txt", .content = "symlinked" }, .{ .path = "nested/file.txt" } });
    const symlinked_dir_path = try std.fs.path.join(allocator, &.{ base_dir, "symlinked_dir" });
    defer allocator.free(symlinked_dir_path);
    try std.Io.Dir.cwd().symLink(std.testing.io, "../outside", symlinked_dir_path, .{});
    const link_path = try std.fs.path.join(allocator, &.{ base_dir, "link.txt" });
    defer allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(std.testing.io, "original.txt", link_path, .{});

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const some_line = [_][]const u8{"@some"};
    const some_result = (try provider.getSuggestions(&some_line, 0, some_line[0].len, .{})).?;
    defer some_result.deinit(allocator);
    try std.testing.expect(valuesContain(some_result.items, "@dir/some_file.txt"));
    try std.testing.expect(valuesContain(some_result.items, "@symlinked_dir/some_file.txt"));

    const symlinked_line = [_][]const u8{"@symlinked"};
    const symlinked_result = (try provider.getSuggestions(&symlinked_line, 0, symlinked_line[0].len, .{})).?;
    defer symlinked_result.deinit(allocator);
    try std.testing.expect(valuesContain(symlinked_result.items, "@symlinked_dir/"));

    const link_line = [_][]const u8{"@link"};
    const link_result = (try provider.getSuggestions(&link_line, 0, link_line[0].len, .{})).?;
    defer link_result.deinit(allocator);
    try std.testing.expect(valuesContain(link_result.items, "@link.txt"));
}

test "CombinedAutocompleteProvider returns stable @ suggestions when cwd path contains query" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root_dir);
    const normal_base = try std.fs.path.join(allocator, &.{ root_dir, "cwd-normal" });
    defer allocator.free(normal_base);
    const query_base = try std.fs.path.join(allocator, &.{ root_dir, "cwd-plan-repro" });
    defer allocator.free(query_base);
    try makeAbsoluteDir(normal_base);
    try makeAbsoluteDir(query_base);

    const files = [_]FileFixture{
        .{ .path = "packages/coding-agent/examples/extensions/plan-mode/README.md", .content = "readme" },
        .{ .path = "packages/tui/docs/plan.md", .content = "plan" },
    };
    try setupFolder(allocator, normal_base, &.{"packages/coding-agent/examples/extensions/plan-mode"}, &files);
    try setupFolder(allocator, query_base, &.{"packages/coding-agent/examples/extensions/plan-mode"}, &files);

    var normal_provider = try CombinedAutocompleteProvider.init(allocator, &.{}, normal_base, null);
    defer normal_provider.deinit();
    var query_provider = try CombinedAutocompleteProvider.init(allocator, &.{}, query_base, null);
    defer query_provider.deinit();

    const line = [_][]const u8{"@plan"};
    const normal_result = (try normal_provider.getSuggestions(&line, 0, line[0].len, .{})).?;
    defer normal_result.deinit(allocator);
    const query_result = (try query_provider.getSuggestions(&line, 0, line[0].len, .{})).?;
    defer query_result.deinit(allocator);

    try std.testing.expectEqual(normal_result.items.len, query_result.items.len);
    try std.testing.expect(valuesContain(normal_result.items, "@packages/coding-agent/examples/extensions/plan-mode/"));
    try std.testing.expect(valuesContain(normal_result.items, "@packages/tui/docs/plan.md"));
    for (normal_result.items, query_result.items) |normal_item, query_item| {
        try std.testing.expectEqualStrings(normal_item.label, query_item.label);
        try std.testing.expectEqualStrings(normal_item.description.?, query_item.description.?);
    }
}

test "CombinedAutocompleteProvider continues and applies quoted @ paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(base_dir);

    try setupFolder(
        allocator,
        base_dir,
        &.{},
        &.{
            .{ .path = "my folder/test.txt" },
            .{ .path = "my folder/other.txt" },
        },
    );

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const folder_line = [_][]const u8{"@\"my folder/\""};
    const folder_result = (try provider.getSuggestions(&folder_line, 0, folder_line[0].len - 1, .{})).?;
    defer folder_result.deinit(allocator);
    try std.testing.expect(valuesContain(folder_result.items, "@\"my folder/test.txt\""));
    try std.testing.expect(valuesContain(folder_result.items, "@\"my folder/other.txt\""));

    const line = [_][]const u8{"@\"my folder/te\""};
    const cursor_col = line[0].len - 1;
    const result = (try provider.getSuggestions(&line, 0, cursor_col, .{})).?;
    defer result.deinit(allocator);
    var selected: ?AutocompleteItem = null;
    for (result.items) |item| {
        if (std.mem.eql(u8, item.value, "@\"my folder/test.txt\"")) selected = item;
    }
    try std.testing.expect(selected != null);
    const applied = try provider.applyCompletion(&line, 0, cursor_col, selected.?, result.prefix);
    defer applied.deinit(allocator);
    try std.testing.expectEqualStrings("@\"my folder/test.txt\" ", applied.lines[0]);
}

test "CombinedAutocompleteProvider preserves dot slash path completions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(base_dir);

    try setupFolder(
        allocator,
        base_dir,
        &.{"src"},
        &.{
            .{ .path = "update.sh", .content = "#!/bin/bash" },
            .{ .path = "utils.ts", .content = "export {};" },
            .{ .path = "src/index.ts", .content = "export {};" },
        },
    );

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const file_line = [_][]const u8{"./up"};
    const file_result = (try provider.getSuggestions(&file_line, 0, file_line[0].len, .{ .force = true })).?;
    defer file_result.deinit(allocator);
    try std.testing.expect(valuesContain(file_result.items, "./update.sh"));

    const dir_line = [_][]const u8{"./sr"};
    const dir_result = (try provider.getSuggestions(&dir_line, 0, dir_line[0].len, .{ .force = true })).?;
    defer dir_result.deinit(allocator);
    try std.testing.expect(valuesContain(dir_result.items, "./src/"));
}

test "CombinedAutocompleteProvider quotes direct paths with spaces and applies without duplicating quotes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(base_dir);

    try setupFolder(
        allocator,
        base_dir,
        &.{"my folder"},
        &.{
            .{ .path = "my folder/test.txt" },
            .{ .path = "my folder/other.txt" },
        },
    );

    var provider = try CombinedAutocompleteProvider.init(allocator, &.{}, base_dir, null);
    defer provider.deinit();

    const line = [_][]const u8{"my"};
    const result = (try provider.getSuggestions(&line, 0, line[0].len, .{ .force = true })).?;
    defer result.deinit(allocator);
    try std.testing.expect(valuesContain(result.items, "\"my folder/\""));

    const folder_line = [_][]const u8{"\"my folder/\""};
    const folder_result = (try provider.getSuggestions(&folder_line, 0, folder_line[0].len - 1, .{ .force = true })).?;
    defer folder_result.deinit(allocator);
    try std.testing.expect(valuesContain(folder_result.items, "\"my folder/test.txt\""));
    try std.testing.expect(valuesContain(folder_result.items, "\"my folder/other.txt\""));

    const apply_line = [_][]const u8{"\"my folder/te\""};
    const cursor_col = apply_line[0].len - 1;
    const apply_result = (try provider.getSuggestions(&apply_line, 0, cursor_col, .{ .force = true })).?;
    defer apply_result.deinit(allocator);
    var selected: ?AutocompleteItem = null;
    for (apply_result.items) |item| {
        if (std.mem.eql(u8, item.value, "\"my folder/test.txt\"")) selected = item;
    }
    try std.testing.expect(selected != null);
    const applied = try provider.applyCompletion(&apply_line, 0, cursor_col, selected.?, apply_result.prefix);
    defer applied.deinit(allocator);
    try std.testing.expectEqualStrings("\"my folder/test.txt\"", applied.lines[0]);
}
