const std = @import("std");
const tui = @import("bulb_tui");
const session_manager = @import("session_manager.zig");

pub const SessionInfo = session_manager.SessionInfo;

pub const SortMode = enum {
    threaded,
    recent,
    relevance,
};

pub const NameFilter = enum {
    all,
    named,
};

pub const SearchMode = enum {
    tokens,
    regex,
};

pub const SearchTokenKind = enum {
    fuzzy,
    phrase,
};

pub const SearchToken = struct {
    kind: SearchTokenKind,
    value: []const u8,
};

pub const RegexPart = union(enum) {
    literal: []const u8,
    word_boundary,
    any_char,
};

pub const RegexPattern = struct {
    parts: []RegexPart,
};

pub const ParsedSearchQuery = struct {
    arena: std.heap.ArenaAllocator,
    mode: SearchMode,
    tokens: []SearchToken,
    regex: ?RegexPattern,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *ParsedSearchQuery) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const MatchResult = struct {
    matches: bool,
    score: f64,
};

pub fn hasSessionName(session: SessionInfo) bool {
    const name = session.name orelse return false;
    return std.mem.trim(u8, name, " \t\r\n").len > 0;
}

pub fn parseSearchQuery(allocator: std.mem.Allocator, query: []const u8) !ParsedSearchQuery {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        return .{
            .arena = arena,
            .mode = .tokens,
            .tokens = try arena_allocator.alloc(SearchToken, 0),
            .regex = null,
        };
    }

    if (std.mem.startsWith(u8, trimmed, "re:")) {
        const pattern = std.mem.trim(u8, trimmed[3..], " \t\r\n");
        if (pattern.len == 0) {
            return .{
                .arena = arena,
                .mode = .regex,
                .tokens = try arena_allocator.alloc(SearchToken, 0),
                .regex = null,
                .error_message = "Empty regex",
            };
        }
        const regex = parseRegexPattern(arena_allocator, pattern) catch |err| switch (err) {
            error.InvalidRegex => return .{
                .arena = arena,
                .mode = .regex,
                .tokens = try arena_allocator.alloc(SearchToken, 0),
                .regex = null,
                .error_message = "Invalid regex",
            },
            else => return err,
        };
        return .{
            .arena = arena,
            .mode = .regex,
            .tokens = try arena_allocator.alloc(SearchToken, 0),
            .regex = regex,
        };
    }

    var tokens: std.ArrayList(SearchToken) = .empty;
    errdefer tokens.deinit(arena_allocator);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(arena_allocator);
    var in_quote = false;
    var had_unclosed_quote = false;

    for (trimmed) |byte| {
        if (byte == '"') {
            try appendSearchToken(arena_allocator, &tokens, if (in_quote) .phrase else .fuzzy, buffer.items);
            buffer.clearRetainingCapacity();
            in_quote = !in_quote;
            continue;
        }

        if (!in_quote and std.ascii.isWhitespace(byte)) {
            try appendSearchToken(arena_allocator, &tokens, .fuzzy, buffer.items);
            buffer.clearRetainingCapacity();
            continue;
        }

        try buffer.append(arena_allocator, byte);
    }

    if (in_quote) had_unclosed_quote = true;
    if (had_unclosed_quote) {
        tokens.clearRetainingCapacity();
        try appendWhitespaceTokens(arena_allocator, &tokens, trimmed);
    } else {
        try appendSearchToken(arena_allocator, &tokens, if (in_quote) .phrase else .fuzzy, buffer.items);
    }

    return .{
        .arena = arena,
        .mode = .tokens,
        .tokens = try tokens.toOwnedSlice(arena_allocator),
        .regex = null,
    };
}

pub fn matchSession(
    allocator: std.mem.Allocator,
    session: SessionInfo,
    parsed: ParsedSearchQuery,
) !MatchResult {
    const text = try getSessionSearchTextAlloc(allocator, session);
    defer allocator.free(text);

    switch (parsed.mode) {
        .regex => {
            const regex = parsed.regex orelse return .{ .matches = false, .score = 0 };
            const index = regexIndexOf(text, regex) orelse return .{ .matches = false, .score = 0 };
            return .{ .matches = true, .score = @as(f64, @floatFromInt(index)) * 0.1 };
        },
        .tokens => {},
    }

    if (parsed.tokens.len == 0) return .{ .matches = true, .score = 0 };

    var total_score: f64 = 0;
    var normalized_text: ?[]u8 = null;
    defer if (normalized_text) |text_value| allocator.free(text_value);

    for (parsed.tokens) |token| {
        switch (token.kind) {
            .phrase => {
                if (normalized_text == null) normalized_text = try normalizeWhitespaceLowerAlloc(allocator, text);
                const phrase = try normalizeWhitespaceLowerAlloc(allocator, token.value);
                defer allocator.free(phrase);
                if (phrase.len == 0) continue;
                const index = std.mem.indexOf(u8, normalized_text.?, phrase) orelse return .{ .matches = false, .score = 0 };
                total_score += @as(f64, @floatFromInt(index)) * 0.1;
            },
            .fuzzy => {
                const result = try tui.fuzzyMatch(allocator, token.value, text);
                if (!result.matches) return .{ .matches = false, .score = 0 };
                total_score += result.score;
            },
        }
    }

    return .{ .matches = true, .score = total_score };
}

pub fn filterAndSortSessions(
    allocator: std.mem.Allocator,
    sessions: []const SessionInfo,
    query: []const u8,
    sort_mode: SortMode,
    name_filter: NameFilter,
) ![]SessionInfo {
    var name_filtered: std.ArrayList(SessionInfo) = .empty;
    defer name_filtered.deinit(allocator);
    for (sessions) |session| {
        if (matchesNameFilter(session, name_filter)) try name_filtered.append(allocator, session);
    }

    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return name_filtered.toOwnedSlice(allocator);

    var parsed = try parseSearchQuery(allocator, query);
    defer parsed.deinit();
    if (parsed.error_message != null) return try allocator.alloc(SessionInfo, 0);

    if (sort_mode == .recent) {
        var filtered: std.ArrayList(SessionInfo) = .empty;
        defer filtered.deinit(allocator);
        for (name_filtered.items) |session| {
            const matched = try matchSession(allocator, session, parsed);
            if (matched.matches) try filtered.append(allocator, session);
        }
        return filtered.toOwnedSlice(allocator);
    }

    const ScoredSession = struct {
        session: SessionInfo,
        score: f64,

        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            if (lhs.score < rhs.score) return true;
            if (lhs.score > rhs.score) return false;
            return lhs.session.modified_ms > rhs.session.modified_ms;
        }
    };

    var scored: std.ArrayList(ScoredSession) = .empty;
    defer scored.deinit(allocator);
    for (name_filtered.items) |session| {
        const matched = try matchSession(allocator, session, parsed);
        if (matched.matches) try scored.append(allocator, .{ .session = session, .score = matched.score });
    }

    std.mem.sort(ScoredSession, scored.items, {}, ScoredSession.lessThan);
    const result = try allocator.alloc(SessionInfo, scored.items.len);
    for (scored.items, 0..) |entry, index| result[index] = entry.session;
    return result;
}

fn getSessionSearchTextAlloc(allocator: std.mem.Allocator, session: SessionInfo) ![]u8 {
    return std.mem.concat(allocator, u8, &.{
        session.id,
        " ",
        session.name orelse "",
        " ",
        session.all_messages_text,
        " ",
        session.cwd,
    });
}

fn matchesNameFilter(session: SessionInfo, filter: NameFilter) bool {
    return switch (filter) {
        .all => true,
        .named => hasSessionName(session),
    };
}

fn appendSearchToken(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(SearchToken),
    kind: SearchTokenKind,
    value: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;
    try tokens.append(allocator, .{
        .kind = kind,
        .value = try allocator.dupe(u8, trimmed),
    });
}

fn appendWhitespaceTokens(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList(SearchToken),
    query: []const u8,
) !void {
    var parts = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (parts.next()) |part| {
        try tokens.append(allocator, .{
            .kind = .fuzzy,
            .value = try allocator.dupe(u8, part),
        });
    }
}

fn normalizeWhitespaceLowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var pending_space = false;
    var wrote_text = false;

    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (wrote_text) pending_space = true;
            continue;
        }

        if (pending_space) {
            try output.append(allocator, ' ');
            pending_space = false;
        }
        try output.append(allocator, std.ascii.toLower(byte));
        wrote_text = true;
    }

    return output.toOwnedSlice(allocator);
}

fn parseRegexPattern(allocator: std.mem.Allocator, pattern: []const u8) !RegexPattern {
    var parts: std.ArrayList(RegexPart) = .empty;
    errdefer parts.deinit(allocator);
    var literal: std.ArrayList(u8) = .empty;
    defer literal.deinit(allocator);

    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\') {
            if (index + 1 >= pattern.len) return error.InvalidRegex;
            index += 1;
            const escaped = pattern[index];
            if (escaped == 'b') {
                try flushRegexLiteral(allocator, &literal, &parts);
                try parts.append(allocator, .word_boundary);
            } else {
                try literal.append(allocator, std.ascii.toLower(escaped));
            }
            continue;
        }

        switch (byte) {
            '.' => {
                try flushRegexLiteral(allocator, &literal, &parts);
                try parts.append(allocator, .any_char);
            },
            '(', ')', '[', ']', '{', '}', '*', '+', '?', '|' => return error.InvalidRegex,
            else => try literal.append(allocator, std.ascii.toLower(byte)),
        }
    }

    try flushRegexLiteral(allocator, &literal, &parts);
    return .{ .parts = try parts.toOwnedSlice(allocator) };
}

fn flushRegexLiteral(
    allocator: std.mem.Allocator,
    literal: *std.ArrayList(u8),
    parts: *std.ArrayList(RegexPart),
) !void {
    if (literal.items.len == 0) return;
    try parts.append(allocator, .{ .literal = try allocator.dupe(u8, literal.items) });
    literal.clearRetainingCapacity();
}

fn regexIndexOf(text: []const u8, pattern: RegexPattern) ?usize {
    var index: usize = 0;
    while (index <= text.len) : (index += 1) {
        if (matchRegexAt(text, pattern, index)) return index;
    }
    return null;
}

fn matchRegexAt(text: []const u8, pattern: RegexPattern, start: usize) bool {
    var cursor = start;
    for (pattern.parts) |part| {
        switch (part) {
            .literal => |literal| {
                if (cursor + literal.len > text.len) return false;
                for (literal, 0..) |expected, offset| {
                    if (std.ascii.toLower(text[cursor + offset]) != expected) return false;
                }
                cursor += literal.len;
            },
            .word_boundary => if (!isRegexWordBoundary(text, cursor)) return false,
            .any_char => {
                if (cursor >= text.len) return false;
                cursor += 1;
            },
        }
    }
    return true;
}

fn isRegexWordBoundary(text: []const u8, index: usize) bool {
    const prev_word = index > 0 and isRegexWordByte(text[index - 1]);
    const next_word = index < text.len and isRegexWordByte(text[index]);
    return prev_word != next_word;
}

fn isRegexWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn makeSession(
    id: []const u8,
    name: ?[]const u8,
    modified_ms: i64,
    all_messages_text: []const u8,
) SessionInfo {
    return .{
        .path = id,
        .id = id,
        .cwd = "",
        .name = name,
        .parent_session_path = null,
        .created_ms = 0,
        .modified_ms = modified_ms,
        .message_count = 1,
        .first_message = "(no messages)",
        .all_messages_text = all_messages_text,
    };
}

fn expectSessionIds(sessions: []const SessionInfo, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, sessions.len);
    for (expected, 0..) |id, index| try std.testing.expectEqualStrings(id, sessions[index].id);
}

test "session selector search filters by quoted phrase with whitespace normalization" {
    const allocator = std.testing.allocator;
    const sessions = [_]SessionInfo{
        makeSession("a", null, 1, "node\n\n   cve was discussed"),
        makeSession("b", null, 2, "node something else"),
    };

    const result = try filterAndSortSessions(allocator, &sessions, "\"node cve\"", .recent, .all);
    defer allocator.free(result);
    try expectSessionIds(result, &.{"a"});
}

test "session selector search filters by regex and is case-insensitive" {
    const allocator = std.testing.allocator;
    const sessions = [_]SessionInfo{
        makeSession("a", null, 2, "Brave is great"),
        makeSession("b", null, 3, "bravery is not the same"),
    };

    const result = try filterAndSortSessions(allocator, &sessions, "re:\\bbrave\\b", .recent, .all);
    defer allocator.free(result);
    try expectSessionIds(result, &.{"a"});
}

test "session selector search recent sort preserves input order" {
    const allocator = std.testing.allocator;
    const sessions = [_]SessionInfo{
        makeSession("newer", null, 3, "brave"),
        makeSession("older", null, 1, "brave"),
        makeSession("nomatch", null, 4, "something else"),
    };

    const result = try filterAndSortSessions(allocator, &sessions, "\"brave\"", .recent, .all);
    defer allocator.free(result);
    try expectSessionIds(result, &.{ "newer", "older" });
}

test "session selector search relevance sort orders by score and modified tie-break" {
    const allocator = std.testing.allocator;
    const sessions = [_]SessionInfo{
        makeSession("late", null, 3, "xxxx brave"),
        makeSession("early", null, 1, "brave xxxx"),
    };

    const result1 = try filterAndSortSessions(allocator, &sessions, "\"brave\"", .relevance, .all);
    defer allocator.free(result1);
    try expectSessionIds(result1, &.{ "early", "late" });

    const tie_sessions = [_]SessionInfo{
        makeSession("newer", null, 3, "brave"),
        makeSession("older", null, 1, "brave"),
    };
    const result2 = try filterAndSortSessions(allocator, &tie_sessions, "\"brave\"", .relevance, .all);
    defer allocator.free(result2);
    try expectSessionIds(result2, &.{ "newer", "older" });
}

test "session selector search returns empty list for invalid regex" {
    const allocator = std.testing.allocator;
    const sessions = [_]SessionInfo{
        makeSession("a", null, 1, "brave"),
    };

    const result = try filterAndSortSessions(allocator, &sessions, "re:(", .recent, .all);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "session selector search name filter" {
    const allocator = std.testing.allocator;
    const sessions = [_]SessionInfo{
        makeSession("named1", "My Project", 3, "blueberry"),
        makeSession("named2", "Another Named", 2, "blueberry"),
        makeSession("other1", null, 4, "blueberry"),
        makeSession("other2", null, 1, "blueberry"),
    };

    const all = try filterAndSortSessions(allocator, &sessions, "", .recent, .all);
    defer allocator.free(all);
    try expectSessionIds(all, &.{ "named1", "named2", "other1", "other2" });

    const named = try filterAndSortSessions(allocator, &sessions, "", .recent, .named);
    defer allocator.free(named);
    try expectSessionIds(named, &.{ "named1", "named2" });

    const named_search = try filterAndSortSessions(allocator, &sessions, "blueberry", .recent, .named);
    defer allocator.free(named_search);
    try expectSessionIds(named_search, &.{ "named1", "named2" });
}

test "session selector search excludes whitespace-only names from named filter" {
    const allocator = std.testing.allocator;
    const sessions = [_]SessionInfo{
        makeSession("whitespace", "   ", 1, "test"),
        makeSession("empty", "", 2, "test"),
        makeSession("named", "Real Name", 3, "test"),
    };

    const result = try filterAndSortSessions(allocator, &sessions, "", .recent, .named);
    defer allocator.free(result);
    try expectSessionIds(result, &.{"named"});
}
