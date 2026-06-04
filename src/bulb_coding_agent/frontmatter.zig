const std = @import("std");

pub const Value = union(enum) {
    string: []u8,
    boolean: bool,
    integer: i64,
    float: f64,
    null_value: void,
    sequence: std.ArrayList(Value),
    mapping: std.StringHashMapUnmanaged(Value),

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |value| allocator.free(value),
            .sequence => |*sequence| {
                for (sequence.items) |*item| item.deinit(allocator);
                sequence.deinit(allocator);
            },
            .mapping => |*mapping| deinitMapping(allocator, mapping),
            .boolean, .integer, .float, .null_value => {},
        }
        self.* = undefined;
    }

    pub fn getString(self: *const Value, key: []const u8) ?[]const u8 {
        return switch (self.*) {
            .mapping => |mapping| if (mapping.get(key)) |value|
                switch (value) {
                    .string => |string| string,
                    else => null,
                }
            else
                null,
            else => null,
        };
    }
};

pub const ParseDiagnostic = struct {
    line: usize = 0,
    column: usize = 0,
};

const FrontmatterParseError = error{ OutOfMemory, InvalidYaml };

pub const ParsedFrontmatter = struct {
    allocator: std.mem.Allocator,
    frontmatter: std.StringHashMapUnmanaged(Value) = .empty,
    body: []u8,

    pub fn deinit(self: *ParsedFrontmatter) void {
        deinitMapping(self.allocator, &self.frontmatter);
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

fn deinitMapping(allocator: std.mem.Allocator, mapping: *std.StringHashMapUnmanaged(Value)) void {
    var iterator = mapping.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    mapping.deinit(allocator);
}

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
) FrontmatterParseError!void {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, yaml, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);

    var index: usize = 0;
    try parseMappingInto(allocator, frontmatter, lines.items, &index, 0, diagnostic);
    while (index < lines.items.len) {
        if (!isIgnorableLine(lines.items[index])) {
            return invalidYaml(diagnostic, index + 1, leadingSpaces(lines.items[index]) + 1);
        }
        index += 1;
    }
}

fn parseMappingInto(
    allocator: std.mem.Allocator,
    mapping: *std.StringHashMapUnmanaged(Value),
    lines: []const []const u8,
    index: *usize,
    indent: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!void {
    while (index.* < lines.len) {
        const line = lines[index.*];
        if (isIgnorableLine(line)) {
            index.* += 1;
            continue;
        }

        const line_indent = leadingSpaces(line);
        if (line_indent < indent) break;
        if (line_indent > indent) {
            return invalidYaml(diagnostic, index.* + 1, indent + 1);
        }

        const trimmed = line[line_indent..];
        if (isSequenceItem(trimmed)) {
            return invalidYaml(diagnostic, index.* + 1, line_indent + 1);
        }

        const colon_index = findMappingColon(trimmed, false) orelse
            return invalidYaml(diagnostic, index.* + 1, line.len + 1);
        const raw_key = std.mem.trim(u8, trimmed[0..colon_index], " \t");
        if (raw_key.len == 0) return invalidYaml(diagnostic, index.* + 1, line_indent + 1);
        const key = parseKeyAlloc(allocator, raw_key, index.* + 1, diagnostic) catch |err| switch (err) {
            error.InvalidYaml => return invalidYaml(diagnostic, index.* + 1, line_indent + 1),
            else => |other| return other,
        };
        defer allocator.free(key);
        const raw_value = std.mem.trim(u8, trimmed[colon_index + 1 ..], " \t");

        if (raw_value.len == 0) {
            index.* += 1;
            const value = if (try nextContentIndent(lines, index.*, diagnostic)) |child_indent|
                if (child_indent > line_indent)
                    try parseBlockValueAlloc(allocator, lines, index, child_indent, diagnostic)
                else
                    Value{ .null_value = {} }
            else
                Value{ .null_value = {} };
            try putValue(allocator, mapping, key, value);
            continue;
        }

        if (isBlockIndicator(raw_value)) {
            const block = try parseBlockScalarAlloc(allocator, lines, index.* + 1, raw_value, line_indent);
            try putValue(allocator, mapping, key, .{ .string = block.value });
            index.* = block.next_index;
            continue;
        }

        const value = parseValueAlloc(allocator, raw_value, index.* + 1, diagnostic) catch |err| switch (err) {
            error.InvalidYaml => return invalidYaml(diagnostic, index.* + 1, line.len + 1),
            else => |other| return other,
        };
        try putValue(allocator, mapping, key, value);
        index.* += 1;
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

fn parseBlockValueAlloc(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    index: *usize,
    indent: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!Value {
    while (index.* < lines.len and isIgnorableLine(lines[index.*])) index.* += 1;
    if (index.* >= lines.len) return .{ .null_value = {} };

    const line = lines[index.*];
    const line_indent = leadingSpaces(line);
    if (line_indent < indent) return .{ .null_value = {} };
    if (line_indent > indent) return invalidYaml(diagnostic, index.* + 1, indent + 1);

    const trimmed = line[line_indent..];
    if (isSequenceItem(trimmed)) {
        return .{ .sequence = try parseSequenceAlloc(allocator, lines, index, line_indent, diagnostic) };
    }

    var mapping: std.StringHashMapUnmanaged(Value) = .empty;
    errdefer deinitMapping(allocator, &mapping);
    try parseMappingInto(allocator, &mapping, lines, index, line_indent, diagnostic);
    return .{ .mapping = mapping };
}

fn parseSequenceAlloc(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    index: *usize,
    indent: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!std.ArrayList(Value) {
    var sequence: std.ArrayList(Value) = .empty;
    errdefer deinitSequence(allocator, &sequence);

    while (index.* < lines.len) {
        const line = lines[index.*];
        if (isIgnorableLine(line)) {
            index.* += 1;
            continue;
        }

        const line_indent = leadingSpaces(line);
        if (line_indent < indent) break;
        if (line_indent > indent) return invalidYaml(diagnostic, index.* + 1, indent + 1);

        const trimmed = line[line_indent..];
        if (!isSequenceItem(trimmed)) break;

        const raw_item = std.mem.trim(u8, trimmed[1..], " \t");
        const item = if (raw_item.len == 0)
            try parseEmptySequenceItemAlloc(allocator, lines, index, line_indent, diagnostic)
        else if (isBlockIndicator(raw_item))
            try parseBlockSequenceItemAlloc(allocator, lines, index, raw_item, line_indent)
        else if (findMappingColon(raw_item, true) != null)
            try parseMappingSequenceItemAlloc(allocator, lines, index, raw_item, line_indent, diagnostic)
        else
            try parseScalarSequenceItemAlloc(allocator, lines, index, raw_item, diagnostic);

        try sequence.append(allocator, item);
    }

    return sequence;
}

fn parseEmptySequenceItemAlloc(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    index: *usize,
    line_indent: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!Value {
    index.* += 1;
    return if (try nextContentIndent(lines, index.*, diagnostic)) |child_indent|
        if (child_indent > line_indent)
            try parseBlockValueAlloc(allocator, lines, index, child_indent, diagnostic)
        else
            Value{ .null_value = {} }
    else
        Value{ .null_value = {} };
}

fn parseBlockSequenceItemAlloc(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    index: *usize,
    indicator: []const u8,
    line_indent: usize,
) FrontmatterParseError!Value {
    const block = try parseBlockScalarAlloc(allocator, lines, index.* + 1, indicator, line_indent);
    index.* = block.next_index;
    return .{ .string = block.value };
}

fn parseScalarSequenceItemAlloc(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    index: *usize,
    raw_item: []const u8,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!Value {
    const value = parseValueAlloc(allocator, raw_item, index.* + 1, diagnostic) catch |err| switch (err) {
        error.InvalidYaml => return invalidYaml(diagnostic, index.* + 1, lines[index.*].len + 1),
        else => |other| return other,
    };
    index.* += 1;
    return value;
}

fn parseMappingSequenceItemAlloc(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    index: *usize,
    raw_item: []const u8,
    line_indent: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!Value {
    var mapping: std.StringHashMapUnmanaged(Value) = .empty;
    errdefer deinitMapping(allocator, &mapping);

    const colon_index = findMappingColon(raw_item, true).?;
    const raw_key = std.mem.trim(u8, raw_item[0..colon_index], " \t");
    if (raw_key.len == 0) return invalidYaml(diagnostic, index.* + 1, line_indent + 3);
    const key = parseKeyAlloc(allocator, raw_key, index.* + 1, diagnostic) catch |err| switch (err) {
        error.InvalidYaml => return invalidYaml(diagnostic, index.* + 1, line_indent + 3),
        else => |other| return other,
    };
    defer allocator.free(key);

    const raw_value = std.mem.trim(u8, raw_item[colon_index + 1 ..], " \t");
    if (raw_value.len == 0) {
        index.* += 1;
        const value = if (try nextContentIndent(lines, index.*, diagnostic)) |child_indent|
            if (child_indent > line_indent)
                try parseBlockValueAlloc(allocator, lines, index, child_indent, diagnostic)
            else
                Value{ .null_value = {} }
        else
            Value{ .null_value = {} };
        try putValue(allocator, &mapping, key, value);
    } else {
        const value = parseValueAlloc(allocator, raw_value, index.* + 1, diagnostic) catch |err| switch (err) {
            error.InvalidYaml => return invalidYaml(diagnostic, index.* + 1, lines[index.*].len + 1),
            else => |other| return other,
        };
        try putValue(allocator, &mapping, key, value);
        index.* += 1;
    }

    if (try nextContentIndent(lines, index.*, diagnostic)) |child_indent| {
        if (child_indent > line_indent) {
            try parseMappingInto(allocator, &mapping, lines, index, child_indent, diagnostic);
        }
    }

    return .{ .mapping = mapping };
}

fn deinitSequence(allocator: std.mem.Allocator, sequence: *std.ArrayList(Value)) void {
    for (sequence.items) |*item| item.deinit(allocator);
    sequence.deinit(allocator);
}

fn parseValueAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    line: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!Value {
    if (raw.len > 0 and (raw[0] == '[' or raw[0] == '{')) {
        var parser = FlowParser{
            .allocator = allocator,
            .input = raw,
            .line = line,
            .diagnostic = diagnostic,
        };
        var value = try parser.parseValue();
        errdefer value.deinit(allocator);
        parser.skipSpaces();
        if (parser.index < raw.len and raw[parser.index] != '#') {
            return invalidYaml(diagnostic, line, parser.index + 1);
        }
        return value;
    }

    return parseScalarAlloc(allocator, raw);
}

fn parseScalarAlloc(allocator: std.mem.Allocator, raw: []const u8) FrontmatterParseError!Value {
    if (raw.len == 0) return .{ .null_value = {} };

    if (raw[0] == '"' or raw[0] == '\'') {
        return .{ .string = try parseQuotedScalarAlloc(allocator, raw) };
    }

    const without_comment = trimPlainScalarComment(raw);
    if (without_comment.len == 0) return .{ .null_value = {} };
    if (asciiEqlIgnoreCase(without_comment, "true")) return .{ .boolean = true };
    if (asciiEqlIgnoreCase(without_comment, "false")) return .{ .boolean = false };
    if (asciiEqlIgnoreCase(without_comment, "null") or std.mem.eql(u8, without_comment, "~")) {
        return .{ .null_value = {} };
    }
    if (parseYamlNumber(without_comment)) |number| return number;
    return .{ .string = try allocator.dupe(u8, without_comment) };
}

const FlowParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    line: usize,
    diagnostic: ?*ParseDiagnostic,

    fn parseValue(self: *FlowParser) FrontmatterParseError!Value {
        self.skipSpaces();
        if (self.index >= self.input.len) return invalidYaml(self.diagnostic, self.line, self.index + 1);

        return switch (self.input[self.index]) {
            '[' => self.parseSequence(),
            '{' => self.parseMapping(),
            '"', '\'' => .{ .string = try self.parseQuoted() },
            else => self.parseBareScalar(),
        };
    }

    fn parseSequence(self: *FlowParser) FrontmatterParseError!Value {
        self.index += 1;
        var sequence: std.ArrayList(Value) = .empty;
        errdefer deinitSequence(self.allocator, &sequence);

        self.skipSpaces();
        if (self.consume(']')) return .{ .sequence = sequence };

        while (true) {
            {
                var item = try self.parseValue();
                errdefer item.deinit(self.allocator);
                try sequence.append(self.allocator, item);
            }

            self.skipSpaces();
            if (self.consume(']')) break;
            if (!self.consume(',')) return invalidYaml(self.diagnostic, self.line, self.index + 1);
            self.skipSpaces();
            if (self.consume(']')) break;
        }

        return .{ .sequence = sequence };
    }

    fn parseMapping(self: *FlowParser) FrontmatterParseError!Value {
        self.index += 1;
        var mapping: std.StringHashMapUnmanaged(Value) = .empty;
        errdefer deinitMapping(self.allocator, &mapping);

        self.skipSpaces();
        if (self.consume('}')) return .{ .mapping = mapping };

        while (true) {
            const key = try self.parseKey();
            defer self.allocator.free(key);
            self.skipSpaces();
            if (!self.consume(':')) return invalidYaml(self.diagnostic, self.line, self.index + 1);

            {
                var value = try self.parseValue();
                errdefer value.deinit(self.allocator);
                try putValue(self.allocator, &mapping, key, value);
            }

            self.skipSpaces();
            if (self.consume('}')) break;
            if (!self.consume(',')) return invalidYaml(self.diagnostic, self.line, self.index + 1);
            self.skipSpaces();
            if (self.consume('}')) break;
        }

        return .{ .mapping = mapping };
    }

    fn parseKey(self: *FlowParser) FrontmatterParseError![]u8 {
        self.skipSpaces();
        if (self.index >= self.input.len) return invalidYaml(self.diagnostic, self.line, self.index + 1);
        if (self.input[self.index] == '"' or self.input[self.index] == '\'') {
            return self.parseQuoted();
        }

        const start = self.index;
        while (self.index < self.input.len and self.input[self.index] != ':') {
            if (self.input[self.index] == ',' or self.input[self.index] == '}') {
                return invalidYaml(self.diagnostic, self.line, self.index + 1);
            }
            self.index += 1;
        }
        const raw = std.mem.trim(u8, self.input[start..self.index], " \t");
        if (raw.len == 0) return invalidYaml(self.diagnostic, self.line, start + 1);
        return self.allocator.dupe(u8, raw);
    }

    fn parseQuoted(self: *FlowParser) FrontmatterParseError![]u8 {
        const start = self.index;
        const quote = self.input[self.index];
        self.index += 1;
        while (self.index < self.input.len) {
            if (quote == '\'' and self.input[self.index] == '\'' and self.index + 1 < self.input.len and self.input[self.index + 1] == '\'') {
                self.index += 2;
                continue;
            }
            if (quote == '"' and self.input[self.index] == '\\') {
                self.index += 2;
                continue;
            }
            if (self.input[self.index] == quote) {
                self.index += 1;
                return parseQuotedScalarAlloc(self.allocator, self.input[start..self.index]);
            }
            self.index += 1;
        }
        return invalidYaml(self.diagnostic, self.line, self.input.len + 1);
    }

    fn parseBareScalar(self: *FlowParser) FrontmatterParseError!Value {
        const start = self.index;
        while (self.index < self.input.len) {
            switch (self.input[self.index]) {
                ',', ']', '}' => break,
                else => self.index += 1,
            }
        }
        const raw = std.mem.trim(u8, self.input[start..self.index], " \t");
        if (raw.len == 0) return invalidYaml(self.diagnostic, self.line, start + 1);
        return parseScalarAlloc(self.allocator, raw);
    }

    fn skipSpaces(self: *FlowParser) void {
        while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t')) {
            self.index += 1;
        }
    }

    fn consume(self: *FlowParser, byte: u8) bool {
        if (self.index < self.input.len and self.input[self.index] == byte) {
            self.index += 1;
            return true;
        }
        return false;
    }
};

fn parseKeyAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    line: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError![]u8 {
    if (raw[0] == '"' or raw[0] == '\'') {
        return parseQuotedScalarAlloc(allocator, raw) catch |err| switch (err) {
            error.InvalidYaml => return invalidYaml(diagnostic, line, 1),
            else => |other| return other,
        };
    }
    return allocator.dupe(u8, raw);
}

fn findMappingColon(value: []const u8, require_separator: bool) ?usize {
    var quote: ?u8 = null;
    var flow_depth: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (quote) |active| {
            if (active == '\'' and byte == '\'' and index + 1 < value.len and value[index + 1] == '\'') {
                index += 1;
                continue;
            }
            if (active == '"' and byte == '\\') {
                index += 1;
                continue;
            }
            if (byte == active) quote = null;
            continue;
        }

        switch (byte) {
            '"', '\'' => quote = byte,
            '[', '{' => flow_depth += 1,
            ']', '}' => {
                if (flow_depth > 0) flow_depth -= 1;
            },
            ':' => if (flow_depth == 0 and (!require_separator or index + 1 == value.len or value[index + 1] == ' ' or value[index + 1] == '\t')) return index,
            else => {},
        }
    }
    return null;
}

fn isIgnorableLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len == 0 or trimmed[0] == '#';
}

fn isSequenceItem(trimmed: []const u8) bool {
    return trimmed.len > 0 and trimmed[0] == '-' and
        (trimmed.len == 1 or trimmed[1] == ' ' or trimmed[1] == '\t');
}

fn nextContentIndent(
    lines: []const []const u8,
    start: usize,
    diagnostic: ?*ParseDiagnostic,
) FrontmatterParseError!?usize {
    var index = start;
    while (index < lines.len) : (index += 1) {
        if (isIgnorableLine(lines[index])) continue;
        const indent = leadingSpaces(lines[index]);
        if (indent < lines[index].len and lines[index][indent] == '\t') {
            return invalidYaml(diagnostic, index + 1, indent + 1);
        }
        return indent;
    }
    return null;
}

fn trimPlainScalarComment(raw: []const u8) []const u8 {
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (raw[index] == '#' and (index == 0 or raw[index - 1] == ' ' or raw[index - 1] == '\t')) {
            return std.mem.trimEnd(u8, raw[0..index], " \t");
        }
    }
    return raw;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (asciiLower(left) != asciiLower(right)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn parseYamlNumber(raw: []const u8) ?Value {
    if (!looksLikeYamlNumber(raw)) return null;
    if (containsAny(raw, ".eE")) {
        const value = std.fmt.parseFloat(f64, raw) catch return null;
        return .{ .float = value };
    }
    const value = std.fmt.parseInt(i64, raw, 10) catch return null;
    return .{ .integer = value };
}

fn looksLikeYamlNumber(raw: []const u8) bool {
    if (raw.len == 0) return false;
    var index: usize = if (raw[0] == '-' or raw[0] == '+') 1 else 0;
    if (index >= raw.len) return false;

    var digits: usize = 0;
    var dots: usize = 0;
    var exponent_seen = false;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (byte >= '0' and byte <= '9') {
            digits += 1;
            continue;
        }
        if (byte == '.' and !exponent_seen) {
            dots += 1;
            if (dots > 1) return false;
            continue;
        }
        if ((byte == 'e' or byte == 'E') and !exponent_seen and digits > 0) {
            exponent_seen = true;
            if (index + 1 < raw.len and (raw[index + 1] == '-' or raw[index + 1] == '+')) {
                index += 1;
            }
            if (index + 1 >= raw.len) return false;
            continue;
        }
        return false;
    }
    return digits > 0;
}

fn containsAny(value: []const u8, needles: []const u8) bool {
    for (value) |byte| {
        if (std.mem.indexOfScalar(u8, needles, byte) != null) return true;
    }
    return false;
}

fn parseQuotedScalarAlloc(allocator: std.mem.Allocator, raw: []const u8) FrontmatterParseError![]u8 {
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
    parent_indent: usize,
) FrontmatterParseError!BlockScalar {
    var end = start;
    var indent: ?usize = null;
    while (end < lines.len) : (end += 1) {
        const line = lines[end];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        const line_indent = leadingSpaces(line);
        if (line_indent <= parent_indent) break;
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

fn expectMapping(value: *Value) !*std.StringHashMapUnmanaged(Value) {
    return switch (value.*) {
        .mapping => |*mapping| mapping,
        else => error.TestUnexpectedResult,
    };
}

fn expectSequence(value: *Value) !*std.ArrayList(Value) {
    return switch (value.*) {
        .sequence => |*sequence| sequence,
        else => error.TestUnexpectedResult,
    };
}

fn expectStringValue(value: *const Value, expected: []const u8) !void {
    switch (value.*) {
        .string => |actual| try std.testing.expectEqualStrings(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectBoolValue(value: *const Value, expected: bool) !void {
    switch (value.*) {
        .boolean => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectIntegerValue(value: *const Value, expected: i64) !void {
    switch (value.*) {
        .integer => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectFloatValue(value: *const Value, expected: f64) !void {
    switch (value.*) {
        .float => |actual| try std.testing.expectApproxEqAbs(expected, actual, 0.000001),
        else => return error.TestUnexpectedResult,
    }
}

fn expectNullValue(value: *const Value) !void {
    switch (value.*) {
        .null_value => {},
        else => return error.TestUnexpectedResult,
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

test "parseFrontmatter preserves nested YAML collections" {
    const input =
        \\---
        \\agent:
        \\  name: scout
        \\  tools:
        \\    - read
        \\    - grep
        \\  options:
        \\    enabled: true
        \\    retries: 2
        \\"quoted:key": ok
        \\---
        \\Body
    ;
    var parsed = try parseFrontmatterAlloc(std.testing.allocator, input);
    defer parsed.deinit();

    var agent = try expectMapping(parsed.frontmatter.getPtr("agent").?);
    try expectStringValue(agent.getPtr("name").?, "scout");

    const tools = try expectSequence(agent.getPtr("tools").?);
    try std.testing.expectEqual(@as(usize, 2), tools.items.len);
    try expectStringValue(&tools.items[0], "read");
    try expectStringValue(&tools.items[1], "grep");

    var options = try expectMapping(agent.getPtr("options").?);
    try expectBoolValue(options.getPtr("enabled").?, true);
    try expectIntegerValue(options.getPtr("retries").?, 2);
    try expectStringValue(parsed.frontmatter.getPtr("quoted:key").?, "ok");
}

test "parseFrontmatter parses inline YAML collections" {
    const input =
        \\---
        \\tools: [read, grep, {name: bash, enabled: false}]
        \\metadata: {cost: 1.5, aliases: ["one", 'two'], nested: {nullish: null}}
        \\---
        \\Body
    ;
    var parsed = try parseFrontmatterAlloc(std.testing.allocator, input);
    defer parsed.deinit();

    const tools = try expectSequence(parsed.frontmatter.getPtr("tools").?);
    try std.testing.expectEqual(@as(usize, 3), tools.items.len);
    try expectStringValue(&tools.items[0], "read");
    try expectStringValue(&tools.items[1], "grep");

    var tool_config = try expectMapping(&tools.items[2]);
    try expectStringValue(tool_config.getPtr("name").?, "bash");
    try expectBoolValue(tool_config.getPtr("enabled").?, false);

    var metadata = try expectMapping(parsed.frontmatter.getPtr("metadata").?);
    try expectFloatValue(metadata.getPtr("cost").?, 1.5);
    const aliases = try expectSequence(metadata.getPtr("aliases").?);
    try expectStringValue(&aliases.items[0], "one");
    try expectStringValue(&aliases.items[1], "two");
    var nested = try expectMapping(metadata.getPtr("nested").?);
    try expectNullValue(nested.getPtr("nullish").?);
}

test "stripFrontmatter removes frontmatter and preserves plain bodies" {
    const stripped = try stripFrontmatterAlloc(std.testing.allocator, "---\nkey: value\n---\n\nBody\n");
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("Body", stripped);

    const plain = try stripFrontmatterAlloc(std.testing.allocator, "\n  No frontmatter body  \n");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("\n  No frontmatter body  \n", plain);
}
