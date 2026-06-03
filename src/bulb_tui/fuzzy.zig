const std = @import("std");

pub const FuzzyMatch = struct {
    matches: bool,
    score: f64,
};

pub fn fuzzyMatch(allocator: std.mem.Allocator, query: []const u8, text: []const u8) !FuzzyMatch {
    const query_lower = try lowerAsciiAlloc(allocator, query);
    defer allocator.free(query_lower);
    const text_lower = try lowerAsciiAlloc(allocator, text);
    defer allocator.free(text_lower);

    const primary = matchNormalized(query_lower, text_lower);
    if (primary.matches) return primary;

    const swapped_query = try swappedAlphaNumericQuery(allocator, query_lower);
    defer if (swapped_query) |swapped| allocator.free(swapped);
    if (swapped_query == null) return primary;

    const swapped = matchNormalized(swapped_query.?, text_lower);
    if (!swapped.matches) return primary;
    return .{ .matches = true, .score = swapped.score + 5 };
}

pub fn fuzzyFilter(
    allocator: std.mem.Allocator,
    comptime T: type,
    items: []const T,
    query: []const u8,
    comptime getText: fn (item: T) []const u8,
) ![]T {
    if (std.mem.trim(u8, query, " \t\r\n").len == 0) {
        return allocator.dupe(T, items);
    }

    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var token_list: std.ArrayList([]const u8) = .empty;
    defer token_list.deinit(allocator);
    while (tokens.next()) |token| try token_list.append(allocator, token);
    if (token_list.items.len == 0) return allocator.dupe(T, items);

    const ScoredItem = struct {
        item: T,
        total_score: f64,
        index: usize,

        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            if (lhs.total_score < rhs.total_score) return true;
            if (lhs.total_score > rhs.total_score) return false;
            return lhs.index < rhs.index;
        }
    };

    var results: std.ArrayList(ScoredItem) = .empty;
    defer results.deinit(allocator);

    for (items, 0..) |item, index| {
        const text = getText(item);
        var total_score: f64 = 0;
        var all_match = true;
        for (token_list.items) |token| {
            const matched = try fuzzyMatch(allocator, token, text);
            if (matched.matches) {
                total_score += matched.score;
            } else {
                all_match = false;
                break;
            }
        }
        if (all_match) try results.append(allocator, .{ .item = item, .total_score = total_score, .index = index });
    }

    std.mem.sort(ScoredItem, results.items, {}, ScoredItem.lessThan);

    const filtered = try allocator.alloc(T, results.items.len);
    for (results.items, 0..) |result, index| filtered[index] = result.item;
    return filtered;
}

fn matchNormalized(normalized_query: []const u8, text_lower: []const u8) FuzzyMatch {
    if (normalized_query.len == 0) return .{ .matches = true, .score = 0 };
    if (normalized_query.len > text_lower.len) return .{ .matches = false, .score = 0 };

    var query_index: usize = 0;
    var score: f64 = 0;
    var last_match_index: ?usize = null;
    var consecutive_matches: usize = 0;

    var index: usize = 0;
    while (index < text_lower.len and query_index < normalized_query.len) : (index += 1) {
        if (text_lower[index] != normalized_query[query_index]) continue;

        const is_word_boundary = index == 0 or isWordBoundaryPreviousByte(text_lower[index - 1]);

        if (last_match_index != null and last_match_index.? + 1 == index) {
            consecutive_matches += 1;
            score -= @as(f64, @floatFromInt((consecutive_matches + 1) * 5));
        } else {
            consecutive_matches = 0;
            if (last_match_index) |last| {
                score += @as(f64, @floatFromInt(index - last - 1)) * 2;
            }
        }

        if (is_word_boundary) score -= 10;
        score += @as(f64, @floatFromInt(index)) * 0.1;

        last_match_index = index;
        query_index += 1;
    }

    if (query_index < normalized_query.len) return .{ .matches = false, .score = 0 };
    if (std.mem.eql(u8, normalized_query, text_lower)) score -= 100;
    return .{ .matches = true, .score = score };
}

fn isWordBoundaryPreviousByte(byte: u8) bool {
    return std.ascii.isWhitespace(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '/' or byte == ':';
}

fn lowerAsciiAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const lower = try allocator.dupe(u8, input);
    for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
    return lower;
}

fn swappedAlphaNumericQuery(allocator: std.mem.Allocator, query_lower: []const u8) !?[]u8 {
    if (query_lower.len < 2) return null;

    var split: usize = 0;
    while (split < query_lower.len and std.ascii.isAlphabetic(query_lower[split])) : (split += 1) {}
    if (split > 0 and split < query_lower.len) {
        var rest_index = split;
        while (rest_index < query_lower.len and std.ascii.isDigit(query_lower[rest_index])) : (rest_index += 1) {}
        if (rest_index == query_lower.len) {
            return try std.mem.concat(allocator, u8, &.{ query_lower[split..], query_lower[0..split] });
        }
    }

    split = 0;
    while (split < query_lower.len and std.ascii.isDigit(query_lower[split])) : (split += 1) {}
    if (split > 0 and split < query_lower.len) {
        var rest_index = split;
        while (rest_index < query_lower.len and std.ascii.isAlphabetic(query_lower[rest_index])) : (rest_index += 1) {}
        if (rest_index == query_lower.len) {
            return try std.mem.concat(allocator, u8, &.{ query_lower[split..], query_lower[0..split] });
        }
    }

    return null;
}

fn stringText(item: []const u8) []const u8 {
    return item;
}

const NamedItem = struct {
    name: []const u8,
    id: u8,
};

fn namedItemText(item: NamedItem) []const u8 {
    return item.name;
}

test "fuzzyMatch empty query matches everything with score 0" {
    const result = try fuzzyMatch(std.testing.allocator, "", "anything");
    try std.testing.expect(result.matches);
    try std.testing.expectEqual(@as(f64, 0), result.score);
}

test "fuzzyMatch query longer than text does not match" {
    const result = try fuzzyMatch(std.testing.allocator, "longquery", "short");
    try std.testing.expect(!result.matches);
}

test "fuzzyMatch exact match has good score" {
    const result = try fuzzyMatch(std.testing.allocator, "test", "test");
    try std.testing.expect(result.matches);
    try std.testing.expect(result.score < 0);
}

test "fuzzyMatch characters must appear in order" {
    const in_order = try fuzzyMatch(std.testing.allocator, "abc", "aXbXc");
    try std.testing.expect(in_order.matches);

    const out_of_order = try fuzzyMatch(std.testing.allocator, "abc", "cba");
    try std.testing.expect(!out_of_order.matches);
}

test "fuzzyMatch case insensitive matching" {
    const upper_query = try fuzzyMatch(std.testing.allocator, "ABC", "abc");
    try std.testing.expect(upper_query.matches);

    const upper_text = try fuzzyMatch(std.testing.allocator, "abc", "ABC");
    try std.testing.expect(upper_text.matches);
}

test "fuzzyMatch consecutive matches score better than scattered matches" {
    const consecutive = try fuzzyMatch(std.testing.allocator, "foo", "foobar");
    const scattered = try fuzzyMatch(std.testing.allocator, "foo", "f_o_o_bar");

    try std.testing.expect(consecutive.matches);
    try std.testing.expect(scattered.matches);
    try std.testing.expect(consecutive.score < scattered.score);
}

test "fuzzyMatch word boundary matches score better" {
    const at_boundary = try fuzzyMatch(std.testing.allocator, "fb", "foo-bar");
    const not_at_boundary = try fuzzyMatch(std.testing.allocator, "fb", "afbx");

    try std.testing.expect(at_boundary.matches);
    try std.testing.expect(not_at_boundary.matches);
    try std.testing.expect(at_boundary.score < not_at_boundary.score);
}

test "fuzzyMatch matches swapped alpha numeric tokens" {
    const result = try fuzzyMatch(std.testing.allocator, "codex52", "gpt-5.2-codex");
    try std.testing.expect(result.matches);
}

test "fuzzyFilter empty query returns all items unchanged" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "apple", "banana", "cherry" };
    const result = try fuzzyFilter(allocator, []const u8, &items, "", stringText);
    defer allocator.free(result);

    try std.testing.expectEqualSlices([]const u8, &items, result);
}

test "fuzzyFilter filters out non-matching items" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "apple", "banana", "cherry" };
    const result = try fuzzyFilter(allocator, []const u8, &items, "an", stringText);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("banana", result[0]);
}

test "fuzzyFilter sorts results by match quality" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "a_p_p", "app", "application" };
    const result = try fuzzyFilter(allocator, []const u8, &items, "app", stringText);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("app", result[0]);
}

test "fuzzyFilter prioritizes exact matches over longer prefix matches" {
    const allocator = std.testing.allocator;
    const items = [_][]const u8{ "clone", "cl" };
    const result = try fuzzyFilter(allocator, []const u8, &items, "cl", stringText);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("cl", result[0]);
    try std.testing.expectEqualStrings("clone", result[1]);
}

test "fuzzyFilter works with custom getText function" {
    const allocator = std.testing.allocator;
    const items = [_]NamedItem{
        .{ .name = "foo", .id = 1 },
        .{ .name = "bar", .id = 2 },
        .{ .name = "foobar", .id = 3 },
    };
    const result = try fuzzyFilter(allocator, NamedItem, &items, "foo", namedItemText);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("foo", result[0].name);
    try std.testing.expectEqualStrings("foobar", result[1].name);
}
