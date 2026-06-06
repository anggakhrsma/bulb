const std = @import("std");

const path_utils = @import("../path_utils.zig");

pub const Edit = struct {
    old_text: []const u8,
    new_text: []const u8,
};

pub const AppliedEdits = struct {
    base_content: []u8,
    new_content: []u8,

    pub fn deinit(self: *AppliedEdits, allocator: std.mem.Allocator) void {
        allocator.free(self.base_content);
        allocator.free(self.new_content);
        self.* = undefined;
    }
};

pub const ApplyEditsOutcome = union(enum) {
    success: AppliedEdits,
    failure: []u8,

    pub fn deinit(self: *ApplyEditsOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*value| value.deinit(allocator),
            .failure => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub const DiffString = struct {
    diff: []u8,
    first_changed_line: ?usize = null,

    pub fn deinit(self: *DiffString, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
        self.* = undefined;
    }
};

pub const EditDiffResult = struct {
    diff: []u8,
    first_changed_line: ?usize = null,

    pub fn deinit(self: *EditDiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.diff);
        self.* = undefined;
    }
};

pub const EditDiffPreview = union(enum) {
    result: EditDiffResult,
    @"error": []u8,

    pub fn deinit(self: *EditDiffPreview, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .result => |*value| value.deinit(allocator),
            .@"error" => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

const FuzzyMatchResult = struct {
    found: bool,
    index: usize = 0,
    match_len: usize = 0,
    used_fuzzy_match: bool = false,
};

const MatchedEdit = struct {
    edit_index: usize,
    match_index: usize,
    match_len: usize,
    new_text: []const u8,
};

pub const EditDiffOperations = struct {
    ptr: ?*anyopaque = null,
    access_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror!void = defaultReadAccess,
    read_file_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, []const u8) anyerror![]u8 = defaultReadFile,
    format_access_error_fn: *const fn (?*anyopaque, std.mem.Allocator, anyerror) anyerror![]u8 = defaultFormatAccessError,

    pub fn access(self: EditDiffOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !void {
        return self.access_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn readFile(self: EditDiffOperations, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
        return self.read_file_fn(self.ptr, allocator, io, absolute_path);
    }

    pub fn formatAccessError(self: EditDiffOperations, allocator: std.mem.Allocator, err: anyerror) ![]u8 {
        return self.format_access_error_fn(self.ptr, allocator, err);
    }
};

pub fn detectLineEnding(content: []const u8) []const u8 {
    const crlf_index = std.mem.indexOf(u8, content, "\r\n");
    const lf_index = std.mem.indexOfScalar(u8, content, '\n');
    if (lf_index == null) return "\n";
    if (crlf_index == null) return "\n";
    return if (crlf_index.? < lf_index.?) "\r\n" else "\n";
}

pub fn normalizeToLFAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return allocator.dupe(u8, text);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\r') {
            if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
            try output.append(allocator, '\n');
        } else {
            try output.append(allocator, text[index]);
        }
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

pub fn restoreLineEndingsAlloc(allocator: std.mem.Allocator, text: []const u8, ending: []const u8) ![]u8 {
    if (!std.mem.eql(u8, ending, "\r\n")) return allocator.dupe(u8, text);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (text) |byte| {
        if (byte == '\n') {
            try output.appendSlice(allocator, "\r\n");
        } else {
            try output.append(allocator, byte);
        }
    }
    return output.toOwnedSlice(allocator);
}

pub const StripBomResult = struct {
    bom: []const u8,
    text: []const u8,
};

pub fn stripBom(content: []const u8) StripBomResult {
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, content, bom)) return .{ .bom = content[0..bom.len], .text = content[bom.len..] };
    return .{ .bom = "", .text = content };
}

pub fn normalizeForFuzzyMatchAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const trimmed_end = trimTrailingWhitespaceEnd(text[line_start..newline]);
        try appendFuzzyNormalizedSlice(allocator, &output, text[line_start .. line_start + trimmed_end]);
        if (newline == text.len) break;
        try output.append(allocator, '\n');
        line_start = newline + 1;
    }

    return output.toOwnedSlice(allocator);
}

pub fn applyEditsToNormalizedContentAlloc(
    allocator: std.mem.Allocator,
    normalized_content: []const u8,
    edits: []const Edit,
    path: []const u8,
) !ApplyEditsOutcome {
    var normalized_edits: std.ArrayList(Edit) = .empty;
    defer {
        for (normalized_edits.items) |edit| {
            allocator.free(@constCast(edit.old_text));
            allocator.free(@constCast(edit.new_text));
        }
        normalized_edits.deinit(allocator);
    }

    for (edits, 0..) |edit, index| {
        const normalized_old = try normalizeToLFAlloc(allocator, edit.old_text);
        errdefer allocator.free(normalized_old);
        const normalized_new = try normalizeToLFAlloc(allocator, edit.new_text);
        errdefer allocator.free(normalized_new);
        if (normalized_old.len == 0) {
            allocator.free(normalized_old);
            allocator.free(normalized_new);
            return .{ .failure = try emptyOldTextErrorAlloc(allocator, path, index, edits.len) };
        }
        try normalized_edits.append(allocator, .{
            .old_text = normalized_old,
            .new_text = normalized_new,
        });
    }

    var needs_fuzzy_base = false;
    for (normalized_edits.items) |edit| {
        const match = try fuzzyFindTextAlloc(allocator, normalized_content, edit.old_text);
        if (match.used_fuzzy_match) needs_fuzzy_base = true;
    }

    const base_content = if (needs_fuzzy_base)
        try normalizeForFuzzyMatchAlloc(allocator, normalized_content)
    else
        try allocator.dupe(u8, normalized_content);
    errdefer allocator.free(base_content);

    var matched_edits: std.ArrayList(MatchedEdit) = .empty;
    defer matched_edits.deinit(allocator);

    for (normalized_edits.items, 0..) |edit, index| {
        const match = try fuzzyFindTextAlloc(allocator, base_content, edit.old_text);
        if (!match.found) {
            allocator.free(base_content);
            return .{ .failure = try notFoundErrorAlloc(allocator, path, index, normalized_edits.items.len) };
        }

        const occurrences = try countOccurrencesAlloc(allocator, base_content, edit.old_text);
        if (occurrences > 1) {
            allocator.free(base_content);
            return .{ .failure = try duplicateErrorAlloc(allocator, path, index, normalized_edits.items.len, occurrences) };
        }

        try matched_edits.append(allocator, .{
            .edit_index = index,
            .match_index = match.index,
            .match_len = match.match_len,
            .new_text = edit.new_text,
        });
    }

    std.mem.sort(MatchedEdit, matched_edits.items, {}, matchedEditLessThan);
    for (matched_edits.items[1..], 1..) |current, offset_index| {
        const previous = matched_edits.items[offset_index - 1];
        if (previous.match_index + previous.match_len > current.match_index) {
            allocator.free(base_content);
            return .{ .failure = try std.fmt.allocPrint(
                allocator,
                "edits[{d}] and edits[{d}] overlap in {s}. Merge them into one edit or target disjoint regions.",
                .{ previous.edit_index, current.edit_index, path },
            ) };
        }
    }

    var new_content = try allocator.dupe(u8, base_content);
    errdefer allocator.free(new_content);

    var reverse_index = matched_edits.items.len;
    while (reverse_index > 0) {
        reverse_index -= 1;
        const edit = matched_edits.items[reverse_index];
        const replaced = try replaceRangeAlloc(
            allocator,
            new_content,
            edit.match_index,
            edit.match_len,
            edit.new_text,
        );
        allocator.free(new_content);
        new_content = replaced;
    }

    if (std.mem.eql(u8, base_content, new_content)) {
        allocator.free(base_content);
        allocator.free(new_content);
        return .{ .failure = try noChangeErrorAlloc(allocator, path, normalized_edits.items.len) };
    }

    return .{ .success = .{
        .base_content = base_content,
        .new_content = new_content,
    } };
}

pub fn generateUnifiedPatchAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_content: []const u8,
    new_content: []const u8,
    context_lines: usize,
) ![]u8 {
    const old_lines = try splitLinesForDiffAlloc(allocator, old_content);
    defer freeLineList(allocator, old_lines);
    const new_lines = try splitLinesForDiffAlloc(allocator, new_content);
    defer freeLineList(allocator, new_lines);
    var ops = try diffLineOpsAlloc(allocator, old_lines, new_lines);
    defer ops.deinit(allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try output.print(allocator, "--- {s}\n+++ {s}\n", .{ path, path });

    var index: usize = 0;
    var old_line: usize = 1;
    var new_line: usize = 1;
    while (index < ops.items.len) {
        while (index < ops.items.len and ops.items[index].kind == .equal) {
            old_line += 1;
            new_line += 1;
            index += 1;
        }
        if (index >= ops.items.len) break;

        const change_start = index;
        const old_start_at_change = old_line;
        const new_start_at_change = new_line;
        var change_end = index;
        var trailing_equal_count: usize = 0;
        while (change_end < ops.items.len) : (change_end += 1) {
            if (ops.items[change_end].kind == .equal) {
                trailing_equal_count += 1;
                if (trailing_equal_count > context_lines) break;
            } else {
                trailing_equal_count = 0;
            }
        }

        const hunk_start = if (change_start > context_lines) change_start - context_lines else 0;
        const hunk_end = @min(ops.items.len, change_end);
        const leading = change_start - hunk_start;
        const old_hunk_start = old_start_at_change - leading;
        const new_hunk_start = new_start_at_change - leading;
        var old_count: usize = 0;
        var new_count: usize = 0;
        for (ops.items[hunk_start..hunk_end]) |op| switch (op.kind) {
            .equal, .remove => old_count += 1,
            .add => new_count += 1,
        };
        for (ops.items[hunk_start..hunk_end]) |op| switch (op.kind) {
            .equal, .add => {},
            .remove => {},
        };

        try output.print(allocator, "@@ -{d},{d} +{d},{d} @@\n", .{
            old_hunk_start,
            old_count,
            new_hunk_start,
            new_count,
        });
        for (ops.items[hunk_start..hunk_end]) |op| {
            const prefix: u8 = switch (op.kind) {
                .equal => ' ',
                .remove => '-',
                .add => '+',
            };
            try output.append(allocator, prefix);
            try output.appendSlice(allocator, op.line);
            try output.append(allocator, '\n');
        }

        index = hunk_end;
        old_line = old_hunk_start + old_count;
        new_line = new_hunk_start + new_count;
    }

    return output.toOwnedSlice(allocator);
}

pub fn generateDiffStringAlloc(
    allocator: std.mem.Allocator,
    old_content: []const u8,
    new_content: []const u8,
    context_lines: usize,
) !DiffString {
    const old_lines = try splitLinesForDiffAlloc(allocator, old_content);
    defer freeLineList(allocator, old_lines);
    const new_lines = try splitLinesForDiffAlloc(allocator, new_content);
    defer freeLineList(allocator, new_lines);
    var ops = try diffLineOpsAlloc(allocator, old_lines, new_lines);
    defer ops.deinit(allocator);

    const max_line_num = @max(old_lines.len, new_lines.len);
    const line_num_width = decimalDigits(@max(max_line_num, 1));

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var old_line_num: usize = 1;
    var new_line_num: usize = 1;
    var first_changed_line: ?usize = null;
    var last_was_change = false;

    var index: usize = 0;
    while (index < ops.items.len) : (index += 1) {
        const op = ops.items[index];
        if (op.kind != .equal) {
            if (first_changed_line == null) first_changed_line = new_line_num;
            if (op.kind == .add) {
                try appendDiffOutputLine(allocator, &output, '+', new_line_num, line_num_width, op.line);
                new_line_num += 1;
            } else {
                try appendDiffOutputLine(allocator, &output, '-', old_line_num, line_num_width, op.line);
                old_line_num += 1;
            }
            last_was_change = true;
            continue;
        }

        const equal_start = index;
        while (index < ops.items.len and ops.items[index].kind == .equal) : (index += 1) {}
        const equal_end = index;
        index -= 1;

        const has_leading_change = last_was_change;
        const has_trailing_change = equal_end < ops.items.len;
        const equal_len = equal_end - equal_start;

        if (has_leading_change and has_trailing_change) {
            if (equal_len <= context_lines * 2) {
                for (ops.items[equal_start..equal_end]) |equal_op| {
                    try appendDiffOutputLine(allocator, &output, ' ', old_line_num, line_num_width, equal_op.line);
                    old_line_num += 1;
                    new_line_num += 1;
                }
            } else {
                for (ops.items[equal_start .. equal_start + context_lines]) |equal_op| {
                    try appendDiffOutputLine(allocator, &output, ' ', old_line_num, line_num_width, equal_op.line);
                    old_line_num += 1;
                    new_line_num += 1;
                }
                try appendEllipsisLine(allocator, &output, line_num_width);
                old_line_num += equal_len - context_lines * 2;
                new_line_num += equal_len - context_lines * 2;
                for (ops.items[equal_end - context_lines .. equal_end]) |equal_op| {
                    try appendDiffOutputLine(allocator, &output, ' ', old_line_num, line_num_width, equal_op.line);
                    old_line_num += 1;
                    new_line_num += 1;
                }
            }
        } else if (has_leading_change) {
            const shown = @min(equal_len, context_lines);
            for (ops.items[equal_start .. equal_start + shown]) |equal_op| {
                try appendDiffOutputLine(allocator, &output, ' ', old_line_num, line_num_width, equal_op.line);
                old_line_num += 1;
                new_line_num += 1;
            }
            const skipped = equal_len - shown;
            if (skipped > 0) {
                try appendEllipsisLine(allocator, &output, line_num_width);
                old_line_num += skipped;
                new_line_num += skipped;
            }
        } else if (has_trailing_change) {
            const skipped = if (equal_len > context_lines) equal_len - context_lines else 0;
            if (skipped > 0) {
                try appendEllipsisLine(allocator, &output, line_num_width);
                old_line_num += skipped;
                new_line_num += skipped;
            }
            for (ops.items[equal_start + skipped .. equal_end]) |equal_op| {
                try appendDiffOutputLine(allocator, &output, ' ', old_line_num, line_num_width, equal_op.line);
                old_line_num += 1;
                new_line_num += 1;
            }
        } else {
            old_line_num += equal_len;
            new_line_num += equal_len;
        }

        last_was_change = false;
    }

    return .{
        .diff = try output.toOwnedSlice(allocator),
        .first_changed_line = first_changed_line,
    };
}

pub fn computeEditsDiffAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    edits: []const Edit,
    cwd: []const u8,
    operations: EditDiffOperations,
) !EditDiffPreview {
    const absolute_path = try path_utils.resolveToCwdAlloc(allocator, path, cwd, null);
    defer allocator.free(absolute_path);

    operations.access(allocator, io, absolute_path) catch |err| {
        const error_message = try operations.formatAccessError(allocator, err);
        defer allocator.free(error_message);
        return .{ .@"error" = try std.fmt.allocPrint(allocator, "Could not edit file: {s}. {s}.", .{
            path,
            error_message,
        }) };
    };

    const raw_content = operations.readFile(allocator, io, absolute_path) catch |err| {
        const error_message = try operations.formatAccessError(allocator, err);
        defer allocator.free(error_message);
        return .{ .@"error" = try std.fmt.allocPrint(allocator, "Could not edit file: {s}. {s}.", .{
            path,
            error_message,
        }) };
    };
    defer allocator.free(raw_content);

    const bom_stripped = stripBom(raw_content);
    const normalized = try normalizeToLFAlloc(allocator, bom_stripped.text);
    defer allocator.free(normalized);
    var applied = try applyEditsToNormalizedContentAlloc(allocator, normalized, edits, path);
    defer applied.deinit(allocator);

    switch (applied) {
        .failure => |message| return .{ .@"error" = try allocator.dupe(u8, message) },
        .success => |success| {
            const diff = try generateDiffStringAlloc(allocator, success.base_content, success.new_content, 4);
            return .{ .result = .{
                .diff = diff.diff,
                .first_changed_line = diff.first_changed_line,
            } };
        },
    }
}

pub fn computeEditDiffAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    cwd: []const u8,
    operations: EditDiffOperations,
) !EditDiffPreview {
    const edit = [_]Edit{.{ .old_text = old_text, .new_text = new_text }};
    return computeEditsDiffAlloc(allocator, io, path, &edit, cwd, operations);
}

fn fuzzyFindTextAlloc(allocator: std.mem.Allocator, content: []const u8, old_text: []const u8) !FuzzyMatchResult {
    if (std.mem.indexOf(u8, content, old_text)) |index| {
        return .{
            .found = true,
            .index = index,
            .match_len = old_text.len,
        };
    }

    const fuzzy_content = try normalizeForFuzzyMatchAlloc(allocator, content);
    defer allocator.free(fuzzy_content);
    const fuzzy_old = try normalizeForFuzzyMatchAlloc(allocator, old_text);
    defer allocator.free(fuzzy_old);

    if (std.mem.indexOf(u8, fuzzy_content, fuzzy_old)) |index| {
        return .{
            .found = true,
            .index = index,
            .match_len = fuzzy_old.len,
            .used_fuzzy_match = true,
        };
    }

    return .{ .found = false };
}

fn countOccurrencesAlloc(allocator: std.mem.Allocator, content: []const u8, old_text: []const u8) !usize {
    const fuzzy_content = try normalizeForFuzzyMatchAlloc(allocator, content);
    defer allocator.free(fuzzy_content);
    const fuzzy_old = try normalizeForFuzzyMatchAlloc(allocator, old_text);
    defer allocator.free(fuzzy_old);
    if (fuzzy_old.len == 0) return 0;

    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, fuzzy_content, index, fuzzy_old)) |found| {
        count += 1;
        index = found + fuzzy_old.len;
    }
    return count;
}

fn replaceRangeAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
    len: usize,
    replacement: []const u8,
) ![]u8 {
    var output = try allocator.alloc(u8, text.len - len + replacement.len);
    @memcpy(output[0..start], text[0..start]);
    @memcpy(output[start .. start + replacement.len], replacement);
    @memcpy(output[start + replacement.len ..], text[start + len ..]);
    return output;
}

fn matchedEditLessThan(_: void, left: MatchedEdit, right: MatchedEdit) bool {
    return left.match_index < right.match_index;
}

fn trimTrailingWhitespaceEnd(line: []const u8) usize {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) end -= 1;
    return end;
}

fn appendFuzzyNormalizedSlice(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        if (index + width > text.len) {
            try output.append(allocator, text[index]);
            index += 1;
            continue;
        }
        const slice = text[index .. index + width];
        const codepoint = std.unicode.utf8Decode(slice) catch {
            try output.appendSlice(allocator, slice);
            index += width;
            continue;
        };
        if (fuzzyReplacement(codepoint)) |replacement| {
            try output.appendSlice(allocator, replacement);
        } else {
            try output.appendSlice(allocator, slice);
        }
        index += width;
    }
}

fn fuzzyReplacement(codepoint: u21) ?[]const u8 {
    return switch (codepoint) {
        0x2018, 0x2019, 0x201A, 0x201B => "'",
        0x201C, 0x201D, 0x201E, 0x201F => "\"",
        0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212 => "-",
        0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000 => " ",
        else => null,
    };
}

fn notFoundErrorAlloc(allocator: std.mem.Allocator, path: []const u8, edit_index: usize, total_edits: usize) ![]u8 {
    if (total_edits == 1) {
        return std.fmt.allocPrint(
            allocator,
            "Could not find the exact text in {s}. The old text must match exactly including all whitespace and newlines.",
            .{path},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Could not find edits[{d}] in {s}. The oldText must match exactly including all whitespace and newlines.",
        .{ edit_index, path },
    );
}

fn duplicateErrorAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    edit_index: usize,
    total_edits: usize,
    occurrences: usize,
) ![]u8 {
    if (total_edits == 1) {
        return std.fmt.allocPrint(
            allocator,
            "Found {d} occurrences of the text in {s}. The text must be unique. Please provide more context to make it unique.",
            .{ occurrences, path },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Found {d} occurrences of edits[{d}] in {s}. Each oldText must be unique. Please provide more context to make it unique.",
        .{ occurrences, edit_index, path },
    );
}

fn emptyOldTextErrorAlloc(allocator: std.mem.Allocator, path: []const u8, edit_index: usize, total_edits: usize) ![]u8 {
    if (total_edits == 1) return std.fmt.allocPrint(allocator, "oldText must not be empty in {s}.", .{path});
    return std.fmt.allocPrint(allocator, "edits[{d}].oldText must not be empty in {s}.", .{ edit_index, path });
}

fn noChangeErrorAlloc(allocator: std.mem.Allocator, path: []const u8, total_edits: usize) ![]u8 {
    if (total_edits == 1) {
        return std.fmt.allocPrint(
            allocator,
            "No changes made to {s}. The replacement produced identical content. This might indicate an issue with special characters or the text not existing as expected.",
            .{path},
        );
    }
    return std.fmt.allocPrint(allocator, "No changes made to {s}. The replacements produced identical content.", .{path});
}

const LineDiffOpKind = enum {
    equal,
    remove,
    add,
};

const LineDiffOp = struct {
    kind: LineDiffOpKind,
    line: []const u8,
};

fn splitLinesForDiffAlloc(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |newline| {
        try lines.append(allocator, try allocator.dupe(u8, text[start..newline]));
        start = newline + 1;
    }
    if (start < text.len) {
        try lines.append(allocator, try allocator.dupe(u8, text[start..]));
    } else if (text.len > 0 and text[text.len - 1] != '\n') {
        try lines.append(allocator, try allocator.dupe(u8, ""));
    }
    return lines.toOwnedSlice(allocator);
}

fn freeLineList(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

fn diffLineOpsAlloc(allocator: std.mem.Allocator, old_lines: []const []const u8, new_lines: []const []const u8) !std.ArrayList(LineDiffOp) {
    const max_dynamic_cells: usize = 2_000_000;
    const rows = old_lines.len + 1;
    const cols = new_lines.len + 1;
    if (rows > max_dynamic_cells / @max(cols, 1)) {
        return fallbackLineOpsAlloc(allocator, old_lines, new_lines);
    }

    const width = new_lines.len + 1;
    const table = try allocator.alloc(usize, (old_lines.len + 1) * width);
    defer allocator.free(table);
    @memset(table, 0);

    var old_index = old_lines.len;
    while (old_index > 0) {
        old_index -= 1;
        var new_index = new_lines.len;
        while (new_index > 0) {
            new_index -= 1;
            const slot = old_index * width + new_index;
            if (std.mem.eql(u8, old_lines[old_index], new_lines[new_index])) {
                table[slot] = table[(old_index + 1) * width + new_index + 1] + 1;
            } else {
                table[slot] = @max(table[(old_index + 1) * width + new_index], table[old_index * width + new_index + 1]);
            }
        }
    }

    var ops: std.ArrayList(LineDiffOp) = .empty;
    errdefer ops.deinit(allocator);

    var i: usize = 0;
    var j: usize = 0;
    while (i < old_lines.len and j < new_lines.len) {
        if (std.mem.eql(u8, old_lines[i], new_lines[j])) {
            try ops.append(allocator, .{ .kind = .equal, .line = old_lines[i] });
            i += 1;
            j += 1;
        } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
            try ops.append(allocator, .{ .kind = .remove, .line = old_lines[i] });
            i += 1;
        } else {
            try ops.append(allocator, .{ .kind = .add, .line = new_lines[j] });
            j += 1;
        }
    }
    while (i < old_lines.len) : (i += 1) try ops.append(allocator, .{ .kind = .remove, .line = old_lines[i] });
    while (j < new_lines.len) : (j += 1) try ops.append(allocator, .{ .kind = .add, .line = new_lines[j] });
    return ops;
}

fn fallbackLineOpsAlloc(allocator: std.mem.Allocator, old_lines: []const []const u8, new_lines: []const []const u8) !std.ArrayList(LineDiffOp) {
    var ops: std.ArrayList(LineDiffOp) = .empty;
    errdefer ops.deinit(allocator);

    var prefix: usize = 0;
    while (prefix < old_lines.len and prefix < new_lines.len and std.mem.eql(u8, old_lines[prefix], new_lines[prefix])) {
        try ops.append(allocator, .{ .kind = .equal, .line = old_lines[prefix] });
        prefix += 1;
    }

    var old_suffix = old_lines.len;
    var new_suffix = new_lines.len;
    while (old_suffix > prefix and new_suffix > prefix and std.mem.eql(u8, old_lines[old_suffix - 1], new_lines[new_suffix - 1])) {
        old_suffix -= 1;
        new_suffix -= 1;
    }

    for (old_lines[prefix..old_suffix]) |line| try ops.append(allocator, .{ .kind = .remove, .line = line });
    for (new_lines[prefix..new_suffix]) |line| try ops.append(allocator, .{ .kind = .add, .line = line });
    for (old_lines[old_suffix..]) |line| try ops.append(allocator, .{ .kind = .equal, .line = line });

    return ops;
}

fn appendDiffOutputLine(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    prefix: u8,
    line_number: usize,
    width: usize,
    line: []const u8,
) !void {
    if (output.items.len > 0) try output.append(allocator, '\n');
    try output.append(allocator, prefix);
    try appendPaddedDecimal(allocator, output, line_number, width);
    try output.append(allocator, ' ');
    try output.appendSlice(allocator, line);
}

fn appendEllipsisLine(allocator: std.mem.Allocator, output: *std.ArrayList(u8), width: usize) !void {
    if (output.items.len > 0) try output.append(allocator, '\n');
    try output.append(allocator, ' ');
    for (0..width) |_| try output.append(allocator, ' ');
    try output.appendSlice(allocator, " ...");
}

fn appendPaddedDecimal(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: usize, width: usize) !void {
    const digits = decimalDigits(value);
    for (0..width - digits) |_| try output.append(allocator, ' ');
    try output.print(allocator, "{d}", .{value});
}

fn decimalDigits(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) {
        remaining /= 10;
        digits += 1;
    }
    return digits;
}

fn defaultReadAccess(_: ?*anyopaque, _: std.mem.Allocator, io: std.Io, absolute_path: []const u8) !void {
    try std.Io.Dir.cwd().access(io, absolute_path, .{});
}

fn defaultReadFile(_: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .unlimited);
}

pub fn defaultFormatAccessError(_: ?*anyopaque, allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "Error code: {s}", .{nodeErrorCode(err)});
}

pub fn nodeErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "ENOENT",
        error.AccessDenied, error.PermissionDenied => "EACCES",
        error.NotDir => "ENOTDIR",
        error.IsDir => "EISDIR",
        else => @errorName(err),
    };
}

test "edit diff applies exact replacements and reports duplicates not found overlap and no change" {
    const allocator = std.testing.allocator;

    var single = try applyEditsToNormalizedContentAlloc(
        allocator,
        "Hello, world!",
        &.{.{ .old_text = "world", .new_text = "testing" }},
        "edit-test.txt",
    );
    defer single.deinit(allocator);
    try std.testing.expectEqualStrings("Hello, testing!", single.success.new_content);

    var missing = try applyEditsToNormalizedContentAlloc(
        allocator,
        "Hello, world!",
        &.{.{ .old_text = "nonexistent", .new_text = "testing" }},
        "edit-test.txt",
    );
    defer missing.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, missing.failure, "Could not find the exact text") != null);

    var duplicate = try applyEditsToNormalizedContentAlloc(
        allocator,
        "foo foo foo",
        &.{.{ .old_text = "foo", .new_text = "bar" }},
        "edit-test.txt",
    );
    defer duplicate.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, duplicate.failure, "Found 3 occurrences") != null);

    var overlap = try applyEditsToNormalizedContentAlloc(
        allocator,
        "one\ntwo\nthree\n",
        &.{
            .{ .old_text = "one\ntwo\n", .new_text = "ONE\nTWO\n" },
            .{ .old_text = "two\nthree\n", .new_text = "TWO\nTHREE\n" },
        },
        "edit-overlap.txt",
    );
    defer overlap.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, overlap.failure, "overlap") != null);

    var no_change = try applyEditsToNormalizedContentAlloc(
        allocator,
        "hello\n",
        &.{.{ .old_text = "hello", .new_text = "hello" }},
        "same.txt",
    );
    defer no_change.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, no_change.failure, "No changes made") != null);
}

test "edit diff replaces multiple disjoint regions against original content" {
    const allocator = std.testing.allocator;

    var applied = try applyEditsToNormalizedContentAlloc(
        allocator,
        "foo\nbar\nbaz\n",
        &.{
            .{ .old_text = "foo\n", .new_text = "foo bar\n" },
            .{ .old_text = "bar\n", .new_text = "BAR\n" },
        },
        "edit-multi-original.txt",
    );
    defer applied.deinit(allocator);

    try std.testing.expectEqualStrings("foo bar\nBAR\nbaz\n", applied.success.new_content);
}

test "edit diff preserves BOM line endings and fuzzy quote matching" {
    const allocator = std.testing.allocator;

    const bom = stripBom("\xEF\xBB\xBFhello\r\nworld\r\n");
    try std.testing.expectEqualStrings("\xEF\xBB\xBF", bom.bom);
    const ending = detectLineEnding(bom.text);
    const normalized = try normalizeToLFAlloc(allocator, bom.text);
    defer allocator.free(normalized);
    const restored = try restoreLineEndingsAlloc(allocator, normalized, ending);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings("hello\r\nworld\r\n", restored);

    var fuzzy = try applyEditsToNormalizedContentAlloc(
        allocator,
        "quote: \u{201C}hello\u{201D}\n",
        &.{.{ .old_text = "quote: \"hello\"", .new_text = "quote: \"world\"" }},
        "quote.txt",
    );
    defer fuzzy.deinit(allocator);
    try std.testing.expectEqualStrings("quote: \"world\"\n", fuzzy.success.new_content);
}

test "edit diff renders display diff and unified patch with collapsed gaps" {
    const allocator = std.testing.allocator;

    var diff = try generateDiffStringAlloc(allocator, "Hello, world!", "Hello, testing!", 4);
    defer diff.deinit(allocator);
    try std.testing.expectEqual(@as(?usize, 1), diff.first_changed_line);
    try std.testing.expect(std.mem.indexOf(u8, diff.diff, "-1 Hello, world!") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff.diff, "+1 Hello, testing!") != null);

    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(allocator);
    for (0..600) |index| {
        try lines.print(allocator, "line {d:0>3}\n", .{index + 1});
    }
    var edited = try applyEditsToNormalizedContentAlloc(
        allocator,
        lines.items,
        &.{
            .{ .old_text = "line 100\n", .new_text = "LINE 100\n" },
            .{ .old_text = "line 300\n", .new_text = "LINE 300\n" },
            .{ .old_text = "line 500\n", .new_text = "LINE 500\n" },
        },
        "large.txt",
    );
    defer edited.deinit(allocator);
    var large_diff = try generateDiffStringAlloc(allocator, edited.success.base_content, edited.success.new_content, 4);
    defer large_diff.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, large_diff.diff, "LINE 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, large_diff.diff, "LINE 300") != null);
    try std.testing.expect(std.mem.indexOf(u8, large_diff.diff, "LINE 500") != null);
    try std.testing.expect(std.mem.indexOf(u8, large_diff.diff, "...") != null);
    try std.testing.expect(std.mem.indexOf(u8, large_diff.diff, "line 250") == null);

    const patch = try generateUnifiedPatchAlloc(allocator, "hello.txt", "Hello, world!", "Hello, testing!", 4);
    defer allocator.free(patch);
    try std.testing.expect(std.mem.indexOf(u8, patch, "--- hello.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+++ hello.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "@@") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "-Hello, world!") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch, "+Hello, testing!") != null);
}

test "compute edits diff reports missing preview access with Node-style code" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);
    const missing = try std.fs.path.join(allocator, &.{ cwd, "missing-preview.txt" });
    defer allocator.free(missing);

    var preview = try computeEditsDiffAlloc(
        allocator,
        io,
        missing,
        &.{.{ .old_text = "hello", .new_text = "world" }},
        cwd,
        .{},
    );
    defer preview.deinit(allocator);
    const expected = try std.fmt.allocPrint(allocator, "Could not edit file: {s}. Error code: ENOENT.", .{missing});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, preview.@"error");
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}
