const std = @import("std");

pub const ParseError = error{
    OutOfMemory,
    InvalidFrontmatter,
};

pub const ParsedFrontmatter = struct {
    allocator: std.mem.Allocator,
    name: ?[]u8 = null,
    description: ?[]u8 = null,
    argument_hint: ?[]u8 = null,
    disable_model_invocation: ?bool = null,
    body: []u8,

    pub fn deinit(self: *ParsedFrontmatter) void {
        if (self.name) |value| self.allocator.free(value);
        if (self.description) |value| self.allocator.free(value);
        if (self.argument_hint) |value| self.allocator.free(value);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn parseAlloc(allocator: std.mem.Allocator, content: []const u8) ParseError!ParsedFrontmatter {
    const normalized = try normalizeNewlinesAlloc(allocator, content);
    defer allocator.free(normalized);

    const extracted = extractFrontmatter(normalized);
    var parsed = ParsedFrontmatter{
        .allocator = allocator,
        .body = try allocator.dupe(u8, extracted.body),
    };
    errdefer parsed.deinit();

    if (extracted.yaml) |yaml| {
        try parseYamlFields(allocator, yaml, &parsed);
    }

    return parsed;
}

const ExtractedFrontmatter = struct {
    yaml: ?[]const u8,
    body: []const u8,
};

fn extractFrontmatter(normalized: []const u8) ExtractedFrontmatter {
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

fn parseYamlFields(
    allocator: std.mem.Allocator,
    yaml: []const u8,
    parsed: *ParsedFrontmatter,
) ParseError!void {
    var lines = std.mem.splitScalar(u8, yaml, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or std.mem.startsWith(u8, trimmed_line, "#")) continue;
        if (std.mem.startsWith(u8, line, " ") or std.mem.startsWith(u8, line, "\t")) {
            continue;
        }

        const colon_index = std.mem.indexOfScalar(u8, trimmed_line, ':') orelse
            return error.InvalidFrontmatter;
        const key = std.mem.trim(u8, trimmed_line[0..colon_index], " \t");
        const raw_value = std.mem.trim(u8, trimmed_line[colon_index + 1 ..], " \t");
        if (key.len == 0) return error.InvalidFrontmatter;
        if (hasUnbalancedFlowScalar(raw_value)) return error.InvalidFrontmatter;

        if (std.mem.eql(u8, key, "disable-model-invocation")) {
            if (std.mem.eql(u8, raw_value, "true")) parsed.disable_model_invocation = true;
            if (std.mem.eql(u8, raw_value, "false")) parsed.disable_model_invocation = false;
            continue;
        }

        const value = try parseScalarAlloc(allocator, raw_value);
        errdefer allocator.free(value);
        if (std.mem.eql(u8, key, "name")) {
            if (parsed.name) |old| allocator.free(old);
            parsed.name = value;
        } else if (std.mem.eql(u8, key, "description")) {
            if (parsed.description) |old| allocator.free(old);
            parsed.description = value;
        } else if (std.mem.eql(u8, key, "argument-hint")) {
            if (parsed.argument_hint) |old| allocator.free(old);
            parsed.argument_hint = value;
        } else {
            allocator.free(value);
        }
    }
}

fn parseScalarAlloc(allocator: std.mem.Allocator, raw_value: []const u8) ParseError![]u8 {
    if (raw_value.len >= 2) {
        const first = raw_value[0];
        const last = raw_value[raw_value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return allocator.dupe(u8, raw_value[1 .. raw_value.len - 1]);
        }
    }
    return allocator.dupe(u8, raw_value);
}

fn hasUnbalancedFlowScalar(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '[' and std.mem.indexOfScalar(u8, value, ']') == null) return true;
    if (value[0] == '{' and std.mem.indexOfScalar(u8, value, '}') == null) return true;
    return false;
}

fn normalizeNewlinesAlloc(allocator: std.mem.Allocator, content: []const u8) ParseError![]u8 {
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

test "frontmatter parser normalizes body and scalar metadata" {
    var parsed = try parseAlloc(
        std.testing.allocator,
        "---\r\nname: example\r\ndescription: Example\r\ndisable-model-invocation: true\r\n---\r\nBody\r\n",
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("example", parsed.name.?);
    try std.testing.expectEqualStrings("Example", parsed.description.?);
    try std.testing.expectEqual(true, parsed.disable_model_invocation.?);
    try std.testing.expectEqualStrings("Body", parsed.body);
}
