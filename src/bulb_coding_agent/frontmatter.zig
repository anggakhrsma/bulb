const std = @import("std");

pub const Value = union(enum) {
    string: []u8,
    boolean: bool,
    null_value: void,

    fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |value| allocator.free(value),
            .boolean, .null_value => {},
        }
        self.* = undefined;
    }
};

pub const ParseDiagnostic = struct {
    line: usize = 0,
    column: usize = 0,
};

pub const ParsedFrontmatter = struct {
    allocator: std.mem.Allocator,
    frontmatter: std.StringHashMapUnmanaged(Value) = .empty,
    body: []u8,

    pub fn deinit(self: *ParsedFrontmatter) void {
        var iterator = self.frontmatter.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.frontmatter.deinit(self.allocator);
        self.allocator.free(self.body);
        self.* = undefined;
    }

    pub fn getString(self: *const ParsedFrontmatter, key: []const u8) ?[]const u8 {
        const value = self.frontmatter.get(key) orelse return null;
        return switch (value) {
            .string => |string| string,
            else => null,
        };
    }

    pub fn getBool(self: *const ParsedFrontmatter, key: []const u8) ?bool {
        const value = self.frontmatter.get(key) orelse return null;
        return switch (value) {
            .boolean => |boolean| boolean,
            else => null,
        };
    }
};

/// Parse the scalar YAML frontmatter surface used by Pi prompt templates and
/// skills. Newlines are normalized before extraction, matching the upstream
/// helper.
pub fn parseFrontmatterAlloc(allocator: std.mem.Allocator, content: []const u8) !ParsedFrontmatter {
    return parseFrontmatterAllocWithDiagnostic(allocator, content, null);
}

pub fn parseFrontmatterAllocWithDiagnostic(
    allocator: std.mem.Allocator,
    content: []const u8,
    diagnostic: ?*ParseDiagnostic,
) !ParsedFrontmatter {
    if (diagnostic) |value| value.* = .{};
    const normalized = try normalizeNewlinesAlloc(allocator, content);
    defer allocator.free(normalized);

    const extracted = extractFrontmatter(normalized);
    const body = try allocator.dupe(u8, extracted.body);
    var result = ParsedFrontmatter{
        .allocator = allocator,
        .body = body,
    };
    errdefer result.deinit();

    if (extracted.yaml) |yaml| {
        try parseYamlMapping(allocator, &result.frontmatter, yaml, diagnostic);
    }

    return result;
}

pub fn stripFrontmatterAlloc(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var parsed = try parseFrontmatterAlloc(allocator, content);
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.body);
}

const Extracted = struct {
    yaml: ?[]const u8,
    body: []const u8,
};

fn extractFrontmatter(normalized: []const u8) Extracted {
    if (!std.mem.startsWith(u8, normalized, "---")) {
        return .{ .yaml = null, .body = normalized };
    }

    const end_index = std.mem.indexOfPos(u8, normalized, 3, "\n---") orelse
        return .{ .yaml = null, .body = normalized };

    const yaml_start = @min(@as(usize, 4), end_index);
    return .{
        .yaml = normalized[yaml_start..end_index],
        .body = std.mem.trim(u8, normalized[end_index + 4 ..], " \t\r\n"),
    };
}

fn normalizeNewlinesAlloc(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < content.len) {
        if (content[index] == '\r') {
            try output.append(allocator, '\n');
            index += if (index + 1 < content.len and content[index + 1] == '\n') 2 else 1;
            continue;
        }
        try output.append(allocator, content[index]);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

fn parseYamlMapping(
    allocator: std.mem.Allocator,
    frontmatter: *std.StringHashMapUnmanaged(Value),
    yaml: []const u8,
    diagnostic: ?*ParseDiagnostic,
) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, yaml, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);

    var index: usize = 0;
    while (index < lines.items.len) {
        const line = lines.items[index];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            index += 1;
            continue;
        }
        if (line.len != std.mem.trimStart(u8, line, " \t").len) {
            return invalidYaml(diagnostic, index + 1, 1);
        }

        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse
            return invalidYaml(diagnostic, index + 1, line.len + 1);
        const key = std.mem.trim(u8, line[0..colon_index], " \t");
        if (key.len == 0) return invalidYaml(diagnostic, index + 1, 1);
        const raw_value = std.mem.trim(u8, line[colon_index + 1 ..], " \t");

        if (isBlockIndicator(raw_value)) {
            const block = try parseBlockScalarAlloc(allocator, lines.items, index + 1, raw_value);
            try putValue(allocator, frontmatter, key, .{ .string = block.value });
            index = block.next_index;
            continue;
        }

        if (raw_value.len > 0 and (raw_value[0] == '[' or raw_value[0] == '{')) {
            return invalidYaml(diagnostic, index + 1, line.len + 1);
        }
        const value = try parseScalarAlloc(allocator, raw_value);
        try putValue(allocator, frontmatter, key, value);
        index += 1;
    }
}

fn invalidYaml(diagnostic: ?*ParseDiagnostic, line: usize, column: usize) error{InvalidYaml} {
    if (diagnostic) |value| {
        value.* = .{ .line = line, .column = column };
    }
    return error.InvalidYaml;
}

fn putValue(
    allocator: std.mem.Allocator,
    frontmatter: *std.StringHashMapUnmanaged(Value),
    key: []const u8,
    value: Value,
) !void {
    var owned_value = value;
    errdefer owned_value.deinit(allocator);

    if (frontmatter.getPtr(key)) |existing| {
        existing.deinit(allocator);
        existing.* = owned_value;
        return;
    }

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try frontmatter.put(allocator, owned_key, owned_value);
}

fn parseScalarAlloc(allocator: std.mem.Allocator, raw: []const u8) !Value {
    if (raw.len == 0) return .{ .null_value = {} };

    if (raw[0] == '"' or raw[0] == '\'') {
        return .{ .string = try parseQuotedScalarAlloc(allocator, raw) };
    }

    const without_comment = if (std.mem.indexOf(u8, raw, " #")) |comment_index|
        std.mem.trimEnd(u8, raw[0..comment_index], " \t")
    else
        raw;
    if (without_comment.len == 0) return .{ .null_value = {} };
    if (std.mem.eql(u8, without_comment, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, without_comment, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, without_comment, "null") or std.mem.eql(u8, without_comment, "~")) {
        return .{ .null_value = {} };
    }
    return .{ .string = try allocator.dupe(u8, without_comment) };
}

fn parseQuotedScalarAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const quote = raw[0];
    if (raw.len < 2 or raw[raw.len - 1] != quote) return error.InvalidYaml;
    const value = raw[1 .. raw.len - 1];

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < value.len) {
        if (quote == '\'' and value[index] == '\'' and index + 1 < value.len and value[index + 1] == '\'') {
            try output.append(allocator, '\'');
            index += 2;
            continue;
        }
        if (quote == '"' and value[index] == '\\') {
            if (index + 1 >= value.len) return error.InvalidYaml;
            const escaped = value[index + 1];
            try output.append(allocator, switch (escaped) {
                '"', '\\', '/' => escaped,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.InvalidYaml,
            });
            index += 2;
            continue;
        }
        try output.append(allocator, value[index]);
        index += 1;
    }

    return output.toOwnedSlice(allocator);
}

const BlockScalar = struct {
    value: []u8,
    next_index: usize,
};

fn parseBlockScalarAlloc(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    start: usize,
    indicator: []const u8,
) !BlockScalar {
    var end = start;
    var indent: ?usize = null;
    while (end < lines.len) : (end += 1) {
        const line = lines[end];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const line_indent = leadingSpaces(line);
        if (line_indent == 0) break;
        if (indent == null or line_indent < indent.?) indent = line_indent;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const block_indent = indent orelse 0;
    for (lines[start..end]) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) {
            try output.append(allocator, '\n');
            continue;
        }
        if (leadingSpaces(line) < block_indent) return error.InvalidYaml;
        try output.appendSlice(allocator, line[block_indent..]);
        try output.append(allocator, '\n');
    }

    if (std.mem.eql(u8, indicator, "|-")) {
        trimTrailingNewlines(&output);
    } else if (std.mem.eql(u8, indicator, "|")) {
        trimTrailingNewlines(&output);
        if (start < end) try output.append(allocator, '\n');
    }

    return .{
        .value = try output.toOwnedSlice(allocator),
        .next_index = end,
    };
}

fn isBlockIndicator(value: []const u8) bool {
    return std.mem.eql(u8, value, "|") or
        std.mem.eql(u8, value, "|-") or
        std.mem.eql(u8, value, "|+");
}

fn leadingSpaces(value: []const u8) usize {
    var count: usize = 0;
    while (count < value.len and value[count] == ' ') : (count += 1) {}
    return count;
}

fn trimTrailingNewlines(output: *std.ArrayList(u8)) void {
    while (output.items.len > 0 and output.items[output.items.len - 1] == '\n') {
        output.items.len -= 1;
    }
}

test "parseFrontmatter parses keys, strips quotes, and returns body" {
    const input = "---\nname: \"skill-name\"\ndescription: 'A desc'\nfoo-bar: value\n---\n\nBody text";
    var parsed = try parseFrontmatterAlloc(std.testing.allocator, input);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("skill-name", parsed.getString("name").?);
    try std.testing.expectEqualStrings("A desc", parsed.getString("description").?);
    try std.testing.expectEqualStrings("value", parsed.getString("foo-bar").?);
    try std.testing.expectEqualStrings("Body text", parsed.body);
}

test "parseFrontmatter normalizes newlines and handles CRLF" {
    const input = "---\r\nname: test\r\n---\r\nLine one\r\nLine two";
    var parsed = try parseFrontmatterAlloc(std.testing.allocator, input);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Line one\nLine two", parsed.body);
}

test "parseFrontmatter rejects invalid YAML frontmatter" {
    const input = "---\nfoo: [bar\n---\nBody";
    var diagnostic: ParseDiagnostic = .{};
    try std.testing.expectError(
        error.InvalidYaml,
        parseFrontmatterAllocWithDiagnostic(std.testing.allocator, input, &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 1), diagnostic.line);
    try std.testing.expectEqual(@as(usize, 10), diagnostic.column);
}

test "parseFrontmatter parses multiline scalar syntax" {
    const input = "---\ndescription: |\n  Line one\n  Line two\n---\n\nBody";
    var parsed = try parseFrontmatterAlloc(std.testing.allocator, input);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Line one\nLine two\n", parsed.getString("description").?);
    try std.testing.expectEqualStrings("Body", parsed.body);
}

test "parseFrontmatter returns original content when frontmatter is missing or unterminated" {
    var no_frontmatter = try parseFrontmatterAlloc(std.testing.allocator, "Just text\nsecond line");
    defer no_frontmatter.deinit();
    try std.testing.expectEqualStrings("Just text\nsecond line", no_frontmatter.body);

    var missing_end = try parseFrontmatterAlloc(std.testing.allocator, "---\nname: test\nBody without terminator");
    defer missing_end.deinit();
    try std.testing.expectEqualStrings("---\nname: test\nBody without terminator", missing_end.body);
}

test "parseFrontmatter returns empty map for comment-only frontmatter" {
    var parsed = try parseFrontmatterAlloc(std.testing.allocator, "---\n# just a comment\n---\nBody");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.frontmatter.count());

    var empty = try parseFrontmatterAlloc(std.testing.allocator, "---\n---\nBody");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.frontmatter.count());
    try std.testing.expectEqualStrings("Body", empty.body);
}

test "parseFrontmatter exposes boolean skill metadata" {
    var parsed = try parseFrontmatterAlloc(
        std.testing.allocator,
        "---\ndisable-model-invocation: true\n---\nBody",
    );
    defer parsed.deinit();
    try std.testing.expectEqual(true, parsed.getBool("disable-model-invocation").?);
}

test "stripFrontmatter removes frontmatter and preserves plain bodies" {
    const stripped = try stripFrontmatterAlloc(std.testing.allocator, "---\nkey: value\n---\n\nBody\n");
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("Body", stripped);

    const plain = try stripFrontmatterAlloc(std.testing.allocator, "\n  No frontmatter body  \n");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("\n  No frontmatter body  \n", plain);
}
