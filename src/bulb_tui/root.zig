const std = @import("std");

pub const keys = @import("keys.zig");
pub const keybindings = @import("keybindings.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const autocomplete = @import("autocomplete.zig");

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;
const RESET = "\x1b[0m";

pub const AnsiCode = struct {
    code: []const u8,
    length: usize,
};

pub const SliceResult = struct {
    text: []u8,
    width: usize,
};

pub const ExtractedSegments = struct {
    before: []u8,
    before_width: usize,
    after: []u8,
    after_width: usize,

    pub fn deinit(self: ExtractedSegments, allocator: std.mem.Allocator) void {
        allocator.free(self.before);
        allocator.free(self.after);
    }
};

const DecodedCodepoint = struct {
    codepoint: u21,
    len: usize,
};

const Fragment = struct {
    text: []u8,
    width: usize,
};

const OscTerminator = enum {
    bel,
    st,
};

const ActiveHyperlink = struct {
    params: []const u8,
    url: []const u8,
    terminator: OscTerminator,
};

const AnsiCodeTracker = struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    fg_color: ColorCode = .{},
    bg_color: ColorCode = .{},
    active_hyperlink: ?ActiveHyperlink = null,

    const ColorCode = struct {
        bytes: [32]u8 = undefined,
        len: usize = 0,

        fn set(self: *ColorCode, value: []const u8) void {
            const len = @min(value.len, self.bytes.len);
            @memcpy(self.bytes[0..len], value[0..len]);
            self.len = len;
        }

        fn clear(self: *ColorCode) void {
            self.len = 0;
        }

        fn slice(self: *const ColorCode) ?[]const u8 {
            if (self.len == 0) return null;
            return self.bytes[0..self.len];
        }
    };

    fn clear(self: *AnsiCodeTracker) void {
        self.resetSgr();
        self.active_hyperlink = null;
    }

    fn process(self: *AnsiCodeTracker, ansi_code: []const u8) void {
        if (parseOsc8Hyperlink(ansi_code)) |state| {
            self.active_hyperlink = state;
            return;
        } else |not_osc_or_invalid| switch (not_osc_or_invalid) {
            error.NotOsc8 => {},
        }

        if (ansi_code.len < 3 or ansi_code[0] != ESC or ansi_code[1] != '[' or ansi_code[ansi_code.len - 1] != 'm') {
            return;
        }

        const params = ansi_code[2 .. ansi_code.len - 1];
        if (params.len == 0 or std.mem.eql(u8, params, "0")) {
            self.resetSgr();
            return;
        }

        var part_iter = std.mem.splitScalar(u8, params, ';');
        var parts: [16][]const u8 = undefined;
        var count: usize = 0;
        while (part_iter.next()) |part| {
            if (count < parts.len) {
                parts[count] = part;
                count += 1;
            }
        }

        var index: usize = 0;
        while (index < count) {
            const code = parseSgrCode(parts[index]) orelse {
                index += 1;
                continue;
            };

            if ((code == 38 or code == 48) and index + 2 < count and std.mem.eql(u8, parts[index + 1], "5")) {
                var buffer: [32]u8 = undefined;
                const color = std.fmt.bufPrint(&buffer, "{s};{s};{s}", .{ parts[index], parts[index + 1], parts[index + 2] }) catch "";
                if (code == 38) self.fg_color.set(color) else self.bg_color.set(color);
                index += 3;
                continue;
            }

            if ((code == 38 or code == 48) and index + 4 < count and std.mem.eql(u8, parts[index + 1], "2")) {
                var buffer: [32]u8 = undefined;
                const color = std.fmt.bufPrint(
                    &buffer,
                    "{s};{s};{s};{s};{s}",
                    .{ parts[index], parts[index + 1], parts[index + 2], parts[index + 3], parts[index + 4] },
                ) catch "";
                if (code == 38) self.fg_color.set(color) else self.bg_color.set(color);
                index += 5;
                continue;
            }

            switch (code) {
                0 => self.resetSgr(),
                1 => self.bold = true,
                2 => self.dim = true,
                3 => self.italic = true,
                4 => self.underline = true,
                5 => self.blink = true,
                7 => self.inverse = true,
                8 => self.hidden = true,
                9 => self.strikethrough = true,
                21 => self.bold = false,
                22 => {
                    self.bold = false;
                    self.dim = false;
                },
                23 => self.italic = false,
                24 => self.underline = false,
                25 => self.blink = false,
                27 => self.inverse = false,
                28 => self.hidden = false,
                29 => self.strikethrough = false,
                39 => self.fg_color.clear(),
                49 => self.bg_color.clear(),
                else => {
                    if ((code >= 30 and code <= 37) or (code >= 90 and code <= 97)) {
                        var buffer: [8]u8 = undefined;
                        const color = std.fmt.bufPrint(&buffer, "{d}", .{code}) catch "";
                        self.fg_color.set(color);
                    } else if ((code >= 40 and code <= 47) or (code >= 100 and code <= 107)) {
                        var buffer: [8]u8 = undefined;
                        const color = std.fmt.bufPrint(&buffer, "{d}", .{code}) catch "";
                        self.bg_color.set(color);
                    }
                },
            }

            index += 1;
        }
    }

    fn resetSgr(self: *AnsiCodeTracker) void {
        self.bold = false;
        self.dim = false;
        self.italic = false;
        self.underline = false;
        self.blink = false;
        self.inverse = false;
        self.hidden = false;
        self.strikethrough = false;
        self.fg_color.clear();
        self.bg_color.clear();
    }

    fn appendActiveCodes(self: *const AnsiCodeTracker, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        var wrote_sgr = false;

        if (self.bold) try appendSgrParam(allocator, output, &wrote_sgr, "1");
        if (self.dim) try appendSgrParam(allocator, output, &wrote_sgr, "2");
        if (self.italic) try appendSgrParam(allocator, output, &wrote_sgr, "3");
        if (self.underline) try appendSgrParam(allocator, output, &wrote_sgr, "4");
        if (self.blink) try appendSgrParam(allocator, output, &wrote_sgr, "5");
        if (self.inverse) try appendSgrParam(allocator, output, &wrote_sgr, "7");
        if (self.hidden) try appendSgrParam(allocator, output, &wrote_sgr, "8");
        if (self.strikethrough) try appendSgrParam(allocator, output, &wrote_sgr, "9");
        if (self.fg_color.slice()) |color| try appendSgrParam(allocator, output, &wrote_sgr, color);
        if (self.bg_color.slice()) |color| try appendSgrParam(allocator, output, &wrote_sgr, color);

        if (wrote_sgr) try output.append(allocator, 'm');
        if (self.active_hyperlink) |hyperlink| try appendOsc8Hyperlink(allocator, output, hyperlink);
    }

    fn activeCodesAlloc(self: *const AnsiCodeTracker, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try self.appendActiveCodes(allocator, &output);
        return output.toOwnedSlice(allocator);
    }

    fn appendLineEndReset(self: *const AnsiCodeTracker, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        if (self.underline) try output.appendSlice(allocator, "\x1b[24m");
        if (self.active_hyperlink) |hyperlink| try appendOsc8Close(allocator, output, hyperlink.terminator);
    }
};

fn appendSgrParam(allocator: std.mem.Allocator, output: *std.ArrayList(u8), wrote_any: *bool, param: []const u8) !void {
    if (!wrote_any.*) {
        try output.appendSlice(allocator, "\x1b[");
        wrote_any.* = true;
    } else {
        try output.append(allocator, ';');
    }
    try output.appendSlice(allocator, param);
}

fn appendOsc8Hyperlink(allocator: std.mem.Allocator, output: *std.ArrayList(u8), hyperlink: ActiveHyperlink) !void {
    try output.appendSlice(allocator, "\x1b]8;");
    try output.appendSlice(allocator, hyperlink.params);
    try output.append(allocator, ';');
    try output.appendSlice(allocator, hyperlink.url);
    try appendOscTerminator(allocator, output, hyperlink.terminator);
}

fn appendOsc8Close(allocator: std.mem.Allocator, output: *std.ArrayList(u8), terminator: OscTerminator) !void {
    try output.appendSlice(allocator, "\x1b]8;;");
    try appendOscTerminator(allocator, output, terminator);
}

fn appendOscTerminator(allocator: std.mem.Allocator, output: *std.ArrayList(u8), terminator: OscTerminator) !void {
    switch (terminator) {
        .bel => try output.append(allocator, BEL),
        .st => try output.appendSlice(allocator, "\x1b\\"),
    }
}

fn parseSgrCode(input: []const u8) ?u16 {
    if (input.len == 0) return 0;
    return std.fmt.parseInt(u16, input, 10) catch null;
}

fn parseOsc8Hyperlink(ansi_code: []const u8) error{NotOsc8}!?ActiveHyperlink {
    if (!std.mem.startsWith(u8, ansi_code, "\x1b]8;")) return error.NotOsc8;

    const terminator: OscTerminator = if (std.mem.endsWith(u8, ansi_code, "\x07")) .bel else .st;
    const body_end = switch (terminator) {
        .bel => ansi_code.len - 1,
        .st => ansi_code.len - 2,
    };
    if (body_end < 4) return null;

    const body = ansi_code[4..body_end];
    const separator_index = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    const params = body[0..separator_index];
    const url = body[separator_index + 1 ..];
    if (url.len == 0) return null;
    return ActiveHyperlink{ .params = params, .url = url, .terminator = terminator };
}

/// Extract ANSI CSI, OSC, and APC sequences from a byte position.
pub fn extractAnsiCode(input: []const u8, pos: usize) ?AnsiCode {
    if (pos >= input.len or input[pos] != ESC or pos + 1 >= input.len) return null;

    const next = input[pos + 1];
    if (next == '[') {
        var end = pos + 2;
        while (end < input.len) : (end += 1) {
            const byte = input[end];
            if (byte >= 0x40 and byte <= 0x7e) {
                return .{ .code = input[pos .. end + 1], .length = end + 1 - pos };
            }
        }
        return null;
    }

    if (next == ']' or next == '_') {
        var end = pos + 2;
        while (end < input.len) : (end += 1) {
            if (input[end] == BEL) {
                return .{ .code = input[pos .. end + 1], .length = end + 1 - pos };
            }
            if (input[end] == ESC and end + 1 < input.len and input[end + 1] == '\\') {
                return .{ .code = input[pos .. end + 2], .length = end + 2 - pos };
            }
        }
        return null;
    }

    return null;
}

pub fn visibleWidth(input: []const u8) usize {
    if (input.len == 0) return 0;
    if (isPrintableAscii(input)) return input.len;

    var index: usize = 0;
    var width: usize = 0;
    while (index < input.len) {
        if (extractAnsiCode(input, index)) |ansi| {
            index += ansi.length;
            continue;
        }

        if (input[index] == '\t') {
            index += 1;
            width += 3;
            continue;
        }

        const end = nextGraphemeEnd(input, index);
        if (end == index) {
            index += 1;
            continue;
        }
        width += graphemeWidth(input[index..end]);
        index = end;
    }

    return width;
}

/// Normalize terminal-only output while preserving the logical content width.
pub fn normalizeTerminalOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var index: usize = 0;
    var changed = false;
    while (index < input.len) {
        const decoded = decodeAt(input, index) orelse {
            try output.append(allocator, input[index]);
            index += 1;
            continue;
        };

        switch (decoded.codepoint) {
            0x0e33 => {
                try output.appendSlice(allocator, "\u{0e4d}\u{0e32}");
                changed = true;
            },
            0x0eb3 => {
                try output.appendSlice(allocator, "\u{0ecd}\u{0eb2}");
                changed = true;
            },
            else => try output.appendSlice(allocator, input[index .. index + decoded.len]),
        }
        index += decoded.len;
    }

    if (!changed) {
        output.deinit(allocator);
        return allocator.dupe(u8, input);
    }
    return output.toOwnedSlice(allocator);
}

pub fn wrapTextWithAnsi(allocator: std.mem.Allocator, text: []const u8, width: usize) ![][]u8 {
    if (text.len == 0) {
        const lines = try allocator.alloc([]u8, 1);
        lines[0] = try allocator.dupe(u8, "");
        return lines;
    }

    var result: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedLines(allocator, result.items);

    var tracker: AnsiCodeTracker = .{};
    var start: usize = 0;
    var first_line = true;
    while (true) {
        const newline_pos = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const input_line = text[start..newline_pos];

        var wrapped: [][]u8 = undefined;
        if (first_line) {
            wrapped = try wrapSingleLine(allocator, input_line, width);
        } else {
            const prefix = try tracker.activeCodesAlloc(allocator);
            defer allocator.free(prefix);
            const combined = try std.mem.concat(allocator, u8, &.{ prefix, input_line });
            defer allocator.free(combined);
            wrapped = try wrapSingleLine(allocator, combined, width);
        }
        defer allocator.free(wrapped);

        for (wrapped) |line| {
            try result.append(allocator, line);
        }

        updateTrackerFromText(input_line, &tracker);
        first_line = false;

        if (newline_pos == text.len) break;
        start = newline_pos + 1;
    }

    if (result.items.len == 0) {
        try result.append(allocator, try allocator.dupe(u8, ""));
    }
    return result.toOwnedSlice(allocator);
}

fn wrapSingleLine(allocator: std.mem.Allocator, line: []const u8, width: usize) ![][]u8 {
    if (line.len == 0) {
        const lines = try allocator.alloc([]u8, 1);
        lines[0] = try allocator.dupe(u8, "");
        return lines;
    }

    if (visibleWidth(line) <= width) {
        const lines = try allocator.alloc([]u8, 1);
        lines[0] = try allocator.dupe(u8, line);
        return lines;
    }

    var wrapped: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedLines(allocator, wrapped.items);

    var tracker: AnsiCodeTracker = .{};
    const tokens = try splitIntoTokensWithAnsi(allocator, line);
    defer freeOwnedLines(allocator, tokens);

    var current_line: std.ArrayList(u8) = .empty;
    defer current_line.deinit(allocator);
    var current_visible_length: usize = 0;

    for (tokens) |token| {
        const token_visible_length = visibleWidth(token);
        const whitespace = isWhitespaceToken(token);

        if (token_visible_length > width and !whitespace) {
            if (current_line.items.len > 0) {
                trimEndSpaces(&current_line);
                try tracker.appendLineEndReset(allocator, &current_line);
                try wrapped.append(allocator, try current_line.toOwnedSlice(allocator));
                current_visible_length = 0;
            }

            const broken = try breakLongWord(allocator, token, width, &tracker);
            defer allocator.free(broken);
            for (broken[0 .. broken.len - 1]) |line_part| {
                try wrapped.append(allocator, line_part);
            }

            current_line.deinit(allocator);
            current_line = .empty;
            if (broken.len > 0) {
                try current_line.appendSlice(allocator, broken[broken.len - 1]);
                allocator.free(broken[broken.len - 1]);
            }
            current_visible_length = visibleWidth(current_line.items);
            continue;
        }

        const total_needed = current_visible_length + token_visible_length;
        if (total_needed > width and current_visible_length > 0) {
            trimEndSpaces(&current_line);
            try tracker.appendLineEndReset(allocator, &current_line);
            try wrapped.append(allocator, try current_line.toOwnedSlice(allocator));

            current_line.deinit(allocator);
            current_line = .empty;
            if (!whitespace) {
                try tracker.appendActiveCodes(allocator, &current_line);
                try current_line.appendSlice(allocator, token);
                current_visible_length = token_visible_length;
            } else {
                try tracker.appendActiveCodes(allocator, &current_line);
                current_visible_length = 0;
            }
        } else {
            try current_line.appendSlice(allocator, token);
            current_visible_length += token_visible_length;
        }

        updateTrackerFromText(token, &tracker);
    }

    if (current_line.items.len > 0) {
        try wrapped.append(allocator, try current_line.toOwnedSlice(allocator));
    }

    if (wrapped.items.len == 0) {
        try wrapped.append(allocator, try allocator.dupe(u8, ""));
    } else {
        for (wrapped.items) |*line_item| {
            const trimmed = try trimEndSpacesAlloc(allocator, line_item.*);
            allocator.free(line_item.*);
            line_item.* = trimmed;
        }
    }

    return wrapped.toOwnedSlice(allocator);
}

fn breakLongWord(allocator: std.mem.Allocator, word: []const u8, width: usize, tracker: *AnsiCodeTracker) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedLines(allocator, lines.items);

    var current_line: std.ArrayList(u8) = .empty;
    defer current_line.deinit(allocator);
    try tracker.appendActiveCodes(allocator, &current_line);
    var current_width: usize = 0;

    var index: usize = 0;
    while (index < word.len) {
        if (extractAnsiCode(word, index)) |ansi| {
            try current_line.appendSlice(allocator, ansi.code);
            tracker.process(ansi.code);
            index += ansi.length;
            continue;
        }

        const end = nextGraphemeEnd(word, index);
        if (end == index) {
            index += 1;
            continue;
        }
        const grapheme = word[index..end];
        const width_of_grapheme = visibleWidth(grapheme);

        if (current_width + width_of_grapheme > width) {
            try tracker.appendLineEndReset(allocator, &current_line);
            try lines.append(allocator, try current_line.toOwnedSlice(allocator));
            current_line.deinit(allocator);
            current_line = .empty;
            try tracker.appendActiveCodes(allocator, &current_line);
            current_width = 0;
        }

        try current_line.appendSlice(allocator, grapheme);
        current_width += width_of_grapheme;
        index = end;
    }

    if (current_line.items.len > 0) {
        try lines.append(allocator, try current_line.toOwnedSlice(allocator));
    }
    if (lines.items.len == 0) {
        try lines.append(allocator, try allocator.dupe(u8, ""));
    }
    return lines.toOwnedSlice(allocator);
}

pub fn truncateToWidth(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
    ellipsis: []const u8,
    pad: bool,
) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    if (text.len == 0) {
        if (!pad) return allocator.dupe(u8, "");
        return repeatedSpaces(allocator, max_width);
    }

    const ellipsis_width = visibleWidth(ellipsis);
    if (ellipsis_width >= max_width) {
        const text_width = visibleWidth(text);
        if (text_width <= max_width) return maybePadToWidth(allocator, text, max_width, pad);

        const clipped_ellipsis = try truncateFragmentToWidth(allocator, ellipsis, max_width);
        defer allocator.free(clipped_ellipsis.text);
        if (clipped_ellipsis.width == 0) {
            if (pad) return repeatedSpaces(allocator, max_width);
            return allocator.dupe(u8, "");
        }
        return finalizeTruncatedResult(allocator, "", 0, clipped_ellipsis.text, clipped_ellipsis.width, max_width, pad);
    }

    if (isPrintableAscii(text)) {
        if (text.len <= max_width) return maybePadToWidth(allocator, text, max_width, pad);
        const target_width = max_width - ellipsis_width;
        return finalizeTruncatedResult(allocator, text[0..target_width], target_width, ellipsis, ellipsis_width, max_width, pad);
    }

    const target_width = max_width - ellipsis_width;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var pending_ansi: std.ArrayList(u8) = .empty;
    defer pending_ansi.deinit(allocator);

    var visible_so_far: usize = 0;
    var kept_width: usize = 0;
    var keep_contiguous_prefix = true;
    var overflowed = false;
    var exhausted_input = false;
    const has_ansi = std.mem.indexOfScalar(u8, text, ESC) != null;
    const has_tabs = std.mem.indexOfScalar(u8, text, '\t') != null;

    if (!has_ansi and !has_tabs) {
        var index: usize = 0;
        while (index < text.len) {
            const end = nextGraphemeEnd(text, index);
            if (end == index) {
                index += 1;
                continue;
            }
            const grapheme = text[index..end];
            const width_of_grapheme = graphemeWidth(grapheme);
            if (keep_contiguous_prefix and kept_width + width_of_grapheme <= target_width) {
                try result.appendSlice(allocator, grapheme);
                kept_width += width_of_grapheme;
            } else {
                keep_contiguous_prefix = false;
            }
            visible_so_far += width_of_grapheme;
            if (visible_so_far > max_width) {
                overflowed = true;
                break;
            }
            index = end;
        }
        exhausted_input = !overflowed;
    } else {
        var index: usize = 0;
        while (index < text.len) {
            if (extractAnsiCode(text, index)) |ansi| {
                try pending_ansi.appendSlice(allocator, ansi.code);
                index += ansi.length;
                continue;
            }

            if (text[index] == '\t') {
                if (keep_contiguous_prefix and kept_width + 3 <= target_width) {
                    try flushPendingAnsi(allocator, &result, &pending_ansi);
                    try result.append(allocator, '\t');
                    kept_width += 3;
                } else {
                    keep_contiguous_prefix = false;
                    pending_ansi.clearRetainingCapacity();
                }
                visible_so_far += 3;
                if (visible_so_far > max_width) {
                    overflowed = true;
                    break;
                }
                index += 1;
                continue;
            }

            const end = nextGraphemeEnd(text, index);
            if (end == index) {
                index += 1;
                continue;
            }
            const grapheme = text[index..end];
            const width_of_grapheme = graphemeWidth(grapheme);
            if (keep_contiguous_prefix and kept_width + width_of_grapheme <= target_width) {
                try flushPendingAnsi(allocator, &result, &pending_ansi);
                try result.appendSlice(allocator, grapheme);
                kept_width += width_of_grapheme;
            } else {
                keep_contiguous_prefix = false;
                pending_ansi.clearRetainingCapacity();
            }

            visible_so_far += width_of_grapheme;
            if (visible_so_far > max_width) {
                overflowed = true;
                break;
            }
            index = end;
        }
        exhausted_input = !overflowed;
    }

    if (!overflowed and exhausted_input) {
        return maybePadToWidth(allocator, text, max_width, pad);
    }

    return finalizeTruncatedResult(allocator, result.items, kept_width, ellipsis, ellipsis_width, max_width, pad);
}

fn truncateFragmentToWidth(allocator: std.mem.Allocator, text: []const u8, max_width: usize) !Fragment {
    if (max_width == 0 or text.len == 0) {
        return .{ .text = try allocator.dupe(u8, ""), .width = 0 };
    }

    if (isPrintableAscii(text)) {
        const width = @min(text.len, max_width);
        return .{ .text = try allocator.dupe(u8, text[0..width]), .width = width };
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var pending_ansi: std.ArrayList(u8) = .empty;
    defer pending_ansi.deinit(allocator);

    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (extractAnsiCode(text, index)) |ansi| {
            try pending_ansi.appendSlice(allocator, ansi.code);
            index += ansi.length;
            continue;
        }

        if (text[index] == '\t') {
            if (width + 3 > max_width) break;
            try flushPendingAnsi(allocator, &result, &pending_ansi);
            try result.append(allocator, '\t');
            width += 3;
            index += 1;
            continue;
        }

        const end = nextGraphemeEnd(text, index);
        if (end == index) {
            index += 1;
            continue;
        }
        const grapheme = text[index..end];
        const width_of_grapheme = graphemeWidth(grapheme);
        if (width + width_of_grapheme > max_width) break;
        try flushPendingAnsi(allocator, &result, &pending_ansi);
        try result.appendSlice(allocator, grapheme);
        width += width_of_grapheme;
        index = end;
    }

    return .{ .text = try result.toOwnedSlice(allocator), .width = width };
}

fn finalizeTruncatedResult(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    prefix_width: usize,
    ellipsis: []const u8,
    ellipsis_width: usize,
    max_width: usize,
    pad: bool,
) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, prefix);
    try result.appendSlice(allocator, RESET);
    if (ellipsis.len > 0) {
        try result.appendSlice(allocator, ellipsis);
        try result.appendSlice(allocator, RESET);
    }

    if (pad) {
        const visible = prefix_width + ellipsis_width;
        if (visible < max_width) {
            try appendSpaces(allocator, &result, max_width - visible);
        }
    }

    return result.toOwnedSlice(allocator);
}

pub fn sliceByColumn(allocator: std.mem.Allocator, line: []const u8, start_col: usize, length: usize, strict: bool) ![]u8 {
    const result = try sliceWithWidth(allocator, line, start_col, length, strict);
    return result.text;
}

pub fn sliceWithWidth(allocator: std.mem.Allocator, line: []const u8, start_col: usize, length: usize, strict: bool) !SliceResult {
    if (length == 0) return .{ .text = try allocator.dupe(u8, ""), .width = 0 };

    const end_col = start_col + length;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var pending_ansi: std.ArrayList(u8) = .empty;
    defer pending_ansi.deinit(allocator);

    var result_width: usize = 0;
    var current_col: usize = 0;
    var index: usize = 0;
    while (index < line.len) {
        if (extractAnsiCode(line, index)) |ansi| {
            if (current_col >= start_col and current_col < end_col) {
                try output.appendSlice(allocator, ansi.code);
            } else if (current_col < start_col) {
                try pending_ansi.appendSlice(allocator, ansi.code);
            }
            index += ansi.length;
            continue;
        }

        const grapheme_end = nextGraphemeEnd(line, index);
        if (grapheme_end == index) {
            index += 1;
            continue;
        }
        const grapheme = line[index..grapheme_end];
        const width_of_grapheme = graphemeWidth(grapheme);
        const in_range = current_col >= start_col and current_col < end_col;
        const fits = !strict or current_col + width_of_grapheme <= end_col;
        if (in_range and fits) {
            try flushPendingAnsi(allocator, &output, &pending_ansi);
            try output.appendSlice(allocator, grapheme);
            result_width += width_of_grapheme;
        }
        current_col += width_of_grapheme;
        index = grapheme_end;
        if (current_col >= end_col) break;
    }

    return .{ .text = try output.toOwnedSlice(allocator), .width = result_width };
}

pub fn extractSegments(
    allocator: std.mem.Allocator,
    line: []const u8,
    before_end: usize,
    after_start: usize,
    after_len: usize,
    strict_after: bool,
) !ExtractedSegments {
    var before: std.ArrayList(u8) = .empty;
    errdefer before.deinit(allocator);
    var after: std.ArrayList(u8) = .empty;
    errdefer after.deinit(allocator);
    var pending_ansi_before: std.ArrayList(u8) = .empty;
    defer pending_ansi_before.deinit(allocator);

    var tracker: AnsiCodeTracker = .{};
    var before_width: usize = 0;
    var after_width: usize = 0;
    var current_col: usize = 0;
    var index: usize = 0;
    var after_started = false;
    const after_end = after_start + after_len;

    while (index < line.len) {
        if (extractAnsiCode(line, index)) |ansi| {
            tracker.process(ansi.code);
            if (current_col < before_end) {
                try pending_ansi_before.appendSlice(allocator, ansi.code);
            } else if (current_col >= after_start and current_col < after_end and after_started) {
                try after.appendSlice(allocator, ansi.code);
            }
            index += ansi.length;
            continue;
        }

        const grapheme_end = nextGraphemeEnd(line, index);
        if (grapheme_end == index) {
            index += 1;
            continue;
        }
        const grapheme = line[index..grapheme_end];
        const width_of_grapheme = graphemeWidth(grapheme);

        if (current_col < before_end) {
            try flushPendingAnsi(allocator, &before, &pending_ansi_before);
            try before.appendSlice(allocator, grapheme);
            before_width += width_of_grapheme;
        } else if (current_col >= after_start and current_col < after_end) {
            const fits = !strict_after or current_col + width_of_grapheme <= after_end;
            if (fits) {
                if (!after_started) {
                    try tracker.appendActiveCodes(allocator, &after);
                    after_started = true;
                }
                try after.appendSlice(allocator, grapheme);
                after_width += width_of_grapheme;
            }
        }

        current_col += width_of_grapheme;
        index = grapheme_end;
        if (after_len == 0) {
            if (current_col >= before_end) break;
        } else if (current_col >= after_end) break;
    }

    return .{
        .before = try before.toOwnedSlice(allocator),
        .before_width = before_width,
        .after = try after.toOwnedSlice(allocator),
        .after_width = after_width,
    };
}

pub fn isWhitespaceChar(char: []const u8) bool {
    if (char.len == 0) return false;
    if (char.len == 1) return std.ascii.isWhitespace(char[0]);
    return false;
}

pub fn isPunctuationChar(char: []const u8) bool {
    return char.len == 1 and std.mem.indexOfScalar(u8, "(){}[]<>.,;:'\"!?+-=*/\\|&%^$#@~`", char[0]) != null;
}

pub fn applyBackgroundToLine(allocator: std.mem.Allocator, line: []const u8, width: usize, bg_fn: anytype) ![]u8 {
    const padded = try padToWidth(allocator, line, width);
    defer allocator.free(padded);
    return bg_fn(allocator, padded);
}

pub fn freeRenderedLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    freeOwnedLines(allocator, lines);
}

pub const TextStyle = struct {
    ptr: ?*anyopaque = null,
    apply_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8 = identityTextStyle,

    pub fn apply(self: TextStyle, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.apply_fn(self.ptr, allocator, text);
    }
};

pub const BackgroundStyle = TextStyle;

pub const Component = struct {
    ptr: *anyopaque,
    render_fn: *const fn (*anyopaque, std.mem.Allocator, usize) anyerror![][]u8,
    invalidate_fn: ?*const fn (*anyopaque) void = null,

    pub fn from(comptime T: type, ptr: *T) Component {
        const Adapter = struct {
            fn render(raw: *anyopaque, allocator: std.mem.Allocator, width: usize) anyerror![][]u8 {
                const self: *T = @ptrCast(@alignCast(raw));
                return self.render(allocator, width);
            }

            fn invalidate(raw: *anyopaque) void {
                if (@hasDecl(T, "invalidate")) {
                    const self: *T = @ptrCast(@alignCast(raw));
                    self.invalidate();
                }
            }
        };

        return .{
            .ptr = ptr,
            .render_fn = Adapter.render,
            .invalidate_fn = if (@hasDecl(T, "invalidate")) Adapter.invalidate else null,
        };
    }

    pub fn render(self: Component, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        return self.render_fn(self.ptr, allocator, width);
    }

    pub fn invalidate(self: Component) void {
        if (self.invalidate_fn) |invalidate_fn| invalidate_fn(self.ptr);
    }
};

pub const TruncatedText = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    padding_x: usize = 0,
    padding_y: usize = 0,

    pub fn init(allocator: std.mem.Allocator, text: []const u8, padding_x: usize, padding_y: usize) !TruncatedText {
        return .{
            .allocator = allocator,
            .text = try allocator.dupe(u8, text),
            .padding_x = padding_x,
            .padding_y = padding_y,
        };
    }

    pub fn deinit(self: *TruncatedText) void {
        self.allocator.free(self.text);
    }

    pub fn invalidate(_: *TruncatedText) void {}

    pub fn render(self: *const TruncatedText, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        var result: std.ArrayList([]u8) = .empty;
        errdefer {
            for (result.items) |line| allocator.free(line);
            result.deinit(allocator);
        }

        var top_padding: usize = 0;
        while (top_padding < self.padding_y) : (top_padding += 1) {
            try result.append(allocator, try repeatedSpaces(allocator, width));
        }

        const available_width = contentWidth(width, self.padding_x);
        const newline_index = std.mem.indexOfScalar(u8, self.text, '\n') orelse self.text.len;
        const display_text = try truncateToWidth(allocator, self.text[0..newline_index], available_width, "...", false);
        defer allocator.free(display_text);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try appendSpaces(allocator, &line, self.padding_x);
        try line.appendSlice(allocator, display_text);
        try appendSpaces(allocator, &line, self.padding_x);
        const line_visible_width = visibleWidth(line.items);
        if (line_visible_width < width) try appendSpaces(allocator, &line, width - line_visible_width);
        try result.append(allocator, try line.toOwnedSlice(allocator));

        var bottom_padding: usize = 0;
        while (bottom_padding < self.padding_y) : (bottom_padding += 1) {
            try result.append(allocator, try repeatedSpaces(allocator, width));
        }

        return result.toOwnedSlice(allocator);
    }
};

pub const Text = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    padding_x: usize = 1,
    padding_y: usize = 1,
    custom_bg_fn: ?BackgroundStyle = null,

    pub fn init(
        allocator: std.mem.Allocator,
        text: []const u8,
        padding_x: usize,
        padding_y: usize,
        custom_bg_fn: ?BackgroundStyle,
    ) !Text {
        return .{
            .allocator = allocator,
            .text = try allocator.dupe(u8, text),
            .padding_x = padding_x,
            .padding_y = padding_y,
            .custom_bg_fn = custom_bg_fn,
        };
    }

    pub fn deinit(self: *Text) void {
        self.allocator.free(self.text);
    }

    pub fn setText(self: *Text, text: []const u8) !void {
        const next = try self.allocator.dupe(u8, text);
        self.allocator.free(self.text);
        self.text = next;
    }

    pub fn setCustomBgFn(self: *Text, custom_bg_fn: ?BackgroundStyle) void {
        self.custom_bg_fn = custom_bg_fn;
    }

    pub fn invalidate(_: *Text) void {}

    pub fn render(self: *const Text, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        if (self.text.len == 0 or std.mem.trim(u8, self.text, " \t\r\n").len == 0) {
            return allocator.alloc([]u8, 0);
        }

        const normalized_text = try replaceTabsWithSpaces(allocator, self.text);
        defer allocator.free(normalized_text);

        const wrapped_lines = try wrapTextWithAnsi(allocator, normalized_text, contentWidth(width, self.padding_x));
        defer freeOwnedLines(allocator, wrapped_lines);

        var result: std.ArrayList([]u8) = .empty;
        errdefer {
            for (result.items) |line| allocator.free(line);
            result.deinit(allocator);
        }

        var top_padding: usize = 0;
        while (top_padding < self.padding_y) : (top_padding += 1) {
            try result.append(allocator, try self.applyBg(allocator, "", width));
        }

        for (wrapped_lines) |wrapped_line| {
            var line_with_margins: std.ArrayList(u8) = .empty;
            defer line_with_margins.deinit(allocator);
            try appendSpaces(allocator, &line_with_margins, self.padding_x);
            try line_with_margins.appendSlice(allocator, wrapped_line);
            try appendSpaces(allocator, &line_with_margins, self.padding_x);
            try result.append(allocator, try self.applyBg(allocator, line_with_margins.items, width));
        }

        var bottom_padding: usize = 0;
        while (bottom_padding < self.padding_y) : (bottom_padding += 1) {
            try result.append(allocator, try self.applyBg(allocator, "", width));
        }

        if (result.items.len == 0) {
            try result.append(allocator, try allocator.dupe(u8, ""));
        }

        return result.toOwnedSlice(allocator);
    }

    fn applyBg(self: *const Text, allocator: std.mem.Allocator, line: []const u8, width: usize) ![]u8 {
        if (self.custom_bg_fn) |bg_fn| {
            return applyBackgroundStyleToLine(allocator, line, width, bg_fn);
        }
        return padToWidth(allocator, line, width);
    }
};

pub const Box = struct {
    allocator: std.mem.Allocator,
    children: std.ArrayList(Component) = .empty,
    padding_x: usize = 1,
    padding_y: usize = 1,
    bg_fn: ?BackgroundStyle = null,

    pub fn init(allocator: std.mem.Allocator, padding_x: usize, padding_y: usize, bg_fn: ?BackgroundStyle) Box {
        return .{
            .allocator = allocator,
            .padding_x = padding_x,
            .padding_y = padding_y,
            .bg_fn = bg_fn,
        };
    }

    pub fn deinit(self: *Box) void {
        self.children.deinit(self.allocator);
    }

    pub fn addChild(self: *Box, component: Component) !void {
        try self.children.append(self.allocator, component);
    }

    pub fn removeChild(self: *Box, component: Component) void {
        for (self.children.items, 0..) |child, index| {
            if (child.ptr == component.ptr) {
                _ = self.children.orderedRemove(index);
                return;
            }
        }
    }

    pub fn clear(self: *Box) void {
        self.children.clearRetainingCapacity();
    }

    pub fn setBgFn(self: *Box, bg_fn: ?BackgroundStyle) void {
        self.bg_fn = bg_fn;
    }

    pub fn invalidate(self: *Box) void {
        for (self.children.items) |child| child.invalidate();
    }

    pub fn render(self: *Box, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        if (self.children.items.len == 0) return allocator.alloc([]u8, 0);

        const child_width = contentWidth(width, self.padding_x);
        var child_lines: std.ArrayList([]u8) = .empty;
        defer {
            for (child_lines.items) |line| allocator.free(line);
            child_lines.deinit(allocator);
        }

        for (self.children.items) |child| {
            const rendered = try child.render(allocator, child_width);
            defer freeOwnedLines(allocator, rendered);
            for (rendered) |line| {
                var padded_child: std.ArrayList(u8) = .empty;
                defer padded_child.deinit(allocator);
                try appendSpaces(allocator, &padded_child, self.padding_x);
                try padded_child.appendSlice(allocator, line);
                try child_lines.append(allocator, try padded_child.toOwnedSlice(allocator));
            }
        }

        if (child_lines.items.len == 0) return allocator.alloc([]u8, 0);

        var result: std.ArrayList([]u8) = .empty;
        errdefer {
            for (result.items) |line| allocator.free(line);
            result.deinit(allocator);
        }

        var top_padding: usize = 0;
        while (top_padding < self.padding_y) : (top_padding += 1) {
            try result.append(allocator, try self.applyBg(allocator, "", width));
        }

        for (child_lines.items) |line| {
            try result.append(allocator, try self.applyBg(allocator, line, width));
        }

        var bottom_padding: usize = 0;
        while (bottom_padding < self.padding_y) : (bottom_padding += 1) {
            try result.append(allocator, try self.applyBg(allocator, "", width));
        }

        return result.toOwnedSlice(allocator);
    }

    fn applyBg(self: *const Box, allocator: std.mem.Allocator, line: []const u8, width: usize) ![]u8 {
        if (self.bg_fn) |bg_fn| {
            return applyBackgroundStyleToLine(allocator, line, width, bg_fn);
        }
        return padToWidth(allocator, line, width);
    }
};

pub const SelectItem = struct {
    value: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const SelectListTheme = struct {
    selected_prefix: TextStyle = .{},
    selected_text: TextStyle = .{},
    description: TextStyle = .{},
    scroll_info: TextStyle = .{},
    no_match: TextStyle = .{},
};

pub const SelectListTruncatePrimaryContext = struct {
    text: []const u8,
    max_width: usize,
    column_width: usize,
    item: SelectItem,
    is_selected: bool,
};

pub const TruncatePrimaryFn = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, SelectListTruncatePrimaryContext) anyerror![]u8,

    pub fn call(self: TruncatePrimaryFn, allocator: std.mem.Allocator, context: SelectListTruncatePrimaryContext) ![]u8 {
        return self.call_fn(self.ptr, allocator, context);
    }
};

pub const SelectListLayoutOptions = struct {
    min_primary_column_width: ?usize = null,
    max_primary_column_width: ?usize = null,
    truncate_primary: ?TruncatePrimaryFn = null,
};

pub const SelectItemCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, SelectItem) void,

    pub fn call(self: SelectItemCallback, item: SelectItem) void {
        self.call_fn(self.ptr, item);
    }
};

pub const VoidCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) void,

    pub fn call(self: VoidCallback) void {
        self.call_fn(self.ptr);
    }
};

pub const SelectList = struct {
    allocator: std.mem.Allocator,
    items: []OwnedSelectItem,
    filtered_indices: std.ArrayList(usize),
    selected_index: usize = 0,
    max_visible: usize = 5,
    theme: SelectListTheme,
    layout: SelectListLayoutOptions,
    on_select: ?SelectItemCallback = null,
    on_cancel: ?VoidCallback = null,
    on_selection_change: ?SelectItemCallback = null,

    const DEFAULT_PRIMARY_COLUMN_WIDTH: usize = 32;
    const PRIMARY_COLUMN_GAP: usize = 2;
    const MIN_DESCRIPTION_WIDTH: usize = 10;

    pub fn init(
        allocator: std.mem.Allocator,
        items: []const SelectItem,
        max_visible: usize,
        theme: SelectListTheme,
        layout: SelectListLayoutOptions,
    ) !SelectList {
        var owned_items: std.ArrayList(OwnedSelectItem) = .empty;
        errdefer {
            for (owned_items.items) |*item| item.deinit(allocator);
            owned_items.deinit(allocator);
        }
        for (items) |item| {
            try owned_items.append(allocator, try OwnedSelectItem.clone(allocator, item));
        }

        var filtered_indices: std.ArrayList(usize) = .empty;
        errdefer filtered_indices.deinit(allocator);
        for (items, 0..) |_, index| try filtered_indices.append(allocator, index);

        return .{
            .allocator = allocator,
            .items = try owned_items.toOwnedSlice(allocator),
            .filtered_indices = filtered_indices,
            .max_visible = max_visible,
            .theme = theme,
            .layout = layout,
        };
    }

    pub fn deinit(self: *SelectList) void {
        for (self.items) |*item| item.deinit(self.allocator);
        self.allocator.free(self.items);
        self.filtered_indices.deinit(self.allocator);
    }

    pub fn setFilter(self: *SelectList, filter: []const u8) !void {
        self.filtered_indices.clearRetainingCapacity();
        for (self.items, 0..) |item, index| {
            if (startsWithIgnoreCaseAscii(item.value, filter)) {
                try self.filtered_indices.append(self.allocator, index);
            }
        }
        self.selected_index = 0;
    }

    pub fn setSelectedIndex(self: *SelectList, index: usize) void {
        if (self.filtered_indices.items.len == 0) {
            self.selected_index = 0;
            return;
        }
        self.selected_index = @min(index, self.filtered_indices.items.len - 1);
    }

    pub fn invalidate(_: *SelectList) void {}

    pub fn render(self: *SelectList, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        if (self.filtered_indices.items.len == 0) {
            const no_match = try self.theme.no_match.apply(allocator, "  No matching commands");
            try lines.append(allocator, no_match);
            return lines.toOwnedSlice(allocator);
        }

        const primary_column_width = self.getPrimaryColumnWidth();
        const half_visible = self.max_visible / 2;
        const max_start = if (self.filtered_indices.items.len > self.max_visible) self.filtered_indices.items.len - self.max_visible else 0;
        const centered_start = if (self.selected_index > half_visible) self.selected_index - half_visible else 0;
        const start_index = @min(centered_start, max_start);
        const end_index = @min(start_index + self.max_visible, self.filtered_indices.items.len);

        var index = start_index;
        while (index < end_index) : (index += 1) {
            const item_index = self.filtered_indices.items[index];
            const item = self.items[item_index].view();
            const description_single_line = if (item.description) |description|
                try normalizeToSingleLine(allocator, description)
            else
                null;
            defer if (description_single_line) |description| allocator.free(description);

            try lines.append(allocator, try self.renderItem(
                allocator,
                item,
                index == self.selected_index,
                width,
                description_single_line,
                primary_column_width,
            ));
        }

        if (start_index > 0 or end_index < self.filtered_indices.items.len) {
            const scroll_text = try std.fmt.allocPrint(allocator, "  ({d}/{d})", .{ self.selected_index + 1, self.filtered_indices.items.len });
            defer allocator.free(scroll_text);
            const scroll_width = if (width >= PRIMARY_COLUMN_GAP) width - PRIMARY_COLUMN_GAP else 0;
            const truncated = try truncateToWidth(allocator, scroll_text, scroll_width, "", false);
            defer allocator.free(truncated);
            try lines.append(allocator, try self.theme.scroll_info.apply(allocator, truncated));
        }

        return lines.toOwnedSlice(allocator);
    }

    pub fn handleInput(self: *SelectList, allocator: std.mem.Allocator, key_data: []const u8) !void {
        if (self.filtered_indices.items.len == 0) return;

        const manager = try keybindings.getKeybindings(allocator);
        if (manager.matches(key_data, "tui.select.up")) {
            self.selected_index = if (self.selected_index == 0) self.filtered_indices.items.len - 1 else self.selected_index - 1;
            self.notifySelectionChange();
        } else if (manager.matches(key_data, "tui.select.down")) {
            self.selected_index = if (self.selected_index == self.filtered_indices.items.len - 1) 0 else self.selected_index + 1;
            self.notifySelectionChange();
        } else if (manager.matches(key_data, "tui.select.confirm")) {
            if (self.on_select) |callback| callback.call(self.items[self.filtered_indices.items[self.selected_index]].view());
        } else if (manager.matches(key_data, "tui.select.cancel")) {
            if (self.on_cancel) |callback| callback.call();
        }
    }

    pub fn getSelectedItem(self: *const SelectList) ?SelectItem {
        if (self.filtered_indices.items.len == 0) return null;
        return self.items[self.filtered_indices.items[self.selected_index]].view();
    }

    fn renderItem(
        self: *const SelectList,
        allocator: std.mem.Allocator,
        item: SelectItem,
        is_selected: bool,
        width: usize,
        description_single_line: ?[]const u8,
        primary_column_width: usize,
    ) ![]u8 {
        const prefix = if (is_selected) "\u{2192} " else "  ";
        const prefix_width = visibleWidth(prefix);

        if (description_single_line) |description_text| {
            if (width > 40) {
                const available_primary = if (width > prefix_width + 4) width - prefix_width - 4 else 0;
                const effective_primary_column_width = @max(@as(usize, 1), @min(primary_column_width, available_primary));
                const max_primary_width = if (effective_primary_column_width > PRIMARY_COLUMN_GAP)
                    effective_primary_column_width - PRIMARY_COLUMN_GAP
                else
                    1;
                const truncated_value = try self.truncatePrimary(allocator, item, is_selected, max_primary_width, effective_primary_column_width);
                defer allocator.free(truncated_value);

                const truncated_value_width = visibleWidth(truncated_value);
                const spacing_width = @max(@as(usize, 1), effective_primary_column_width -| truncated_value_width);
                const description_start = prefix_width + truncated_value_width + spacing_width;
                const remaining_width = if (width > description_start + PRIMARY_COLUMN_GAP) width - description_start - PRIMARY_COLUMN_GAP else 0;

                if (remaining_width > MIN_DESCRIPTION_WIDTH) {
                    const truncated_description = try truncateToWidth(allocator, description_text, remaining_width, "", false);
                    defer allocator.free(truncated_description);

                    var line: std.ArrayList(u8) = .empty;
                    defer line.deinit(allocator);
                    try line.appendSlice(allocator, prefix);
                    try line.appendSlice(allocator, truncated_value);
                    try appendSpaces(allocator, &line, spacing_width);
                    if (is_selected) {
                        try line.appendSlice(allocator, truncated_description);
                        return self.theme.selected_text.apply(allocator, line.items);
                    }

                    const desc_text = try std.mem.concat(allocator, u8, &.{ line.items[prefix.len + truncated_value.len ..], truncated_description });
                    defer allocator.free(desc_text);
                    const styled_description = try self.theme.description.apply(allocator, desc_text);
                    defer allocator.free(styled_description);

                    var unselected: std.ArrayList(u8) = .empty;
                    errdefer unselected.deinit(allocator);
                    try unselected.appendSlice(allocator, prefix);
                    try unselected.appendSlice(allocator, truncated_value);
                    try unselected.appendSlice(allocator, styled_description);
                    return unselected.toOwnedSlice(allocator);
                }
            }
        }

        const max_width = if (width > prefix_width + PRIMARY_COLUMN_GAP) width - prefix_width - PRIMARY_COLUMN_GAP else 0;
        const truncated_value = try self.truncatePrimary(allocator, item, is_selected, max_width, max_width);
        defer allocator.free(truncated_value);

        const line = try std.mem.concat(allocator, u8, &.{ prefix, truncated_value });
        defer allocator.free(line);
        if (is_selected) return self.theme.selected_text.apply(allocator, line);
        return allocator.dupe(u8, line);
    }

    fn getPrimaryColumnWidth(self: *const SelectList) usize {
        const bounds = self.getPrimaryColumnBounds();
        var widest_primary: usize = 0;
        for (self.filtered_indices.items) |item_index| {
            const item = self.items[item_index].view();
            widest_primary = @max(widest_primary, visibleWidth(displayValue(item)) + PRIMARY_COLUMN_GAP);
        }
        return clampUsize(widest_primary, bounds.min, bounds.max);
    }

    fn getPrimaryColumnBounds(self: *const SelectList) struct { min: usize, max: usize } {
        const raw_min = self.layout.min_primary_column_width orelse
            (self.layout.max_primary_column_width orelse DEFAULT_PRIMARY_COLUMN_WIDTH);
        const raw_max = self.layout.max_primary_column_width orelse
            (self.layout.min_primary_column_width orelse DEFAULT_PRIMARY_COLUMN_WIDTH);
        return .{
            .min = @max(@as(usize, 1), @min(raw_min, raw_max)),
            .max = @max(@as(usize, 1), @max(raw_min, raw_max)),
        };
    }

    fn truncatePrimary(
        self: *const SelectList,
        allocator: std.mem.Allocator,
        item: SelectItem,
        is_selected: bool,
        max_width: usize,
        column_width: usize,
    ) ![]u8 {
        const display_value = displayValue(item);
        const truncated_value = if (self.layout.truncate_primary) |truncate_primary|
            try truncate_primary.call(allocator, .{
                .text = display_value,
                .max_width = max_width,
                .column_width = column_width,
                .item = item,
                .is_selected = is_selected,
            })
        else
            try truncateToWidth(allocator, display_value, max_width, "", false);
        defer allocator.free(truncated_value);

        return truncateToWidth(allocator, truncated_value, max_width, "", false);
    }

    fn notifySelectionChange(self: *SelectList) void {
        if (self.on_selection_change) |callback| {
            if (self.getSelectedItem()) |item| callback.call(item);
        }
    }
};

const OwnedSelectItem = struct {
    value: []u8,
    label: []u8,
    description: ?[]u8 = null,

    fn clone(allocator: std.mem.Allocator, item: SelectItem) !OwnedSelectItem {
        const value = try allocator.dupe(u8, item.value);
        errdefer allocator.free(value);
        const label = try allocator.dupe(u8, item.label);
        errdefer allocator.free(label);
        const description = if (item.description) |description_text|
            try allocator.dupe(u8, description_text)
        else
            null;

        return .{
            .value = value,
            .label = label,
            .description = description,
        };
    }

    fn deinit(self: *OwnedSelectItem, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.free(self.label);
        if (self.description) |description| allocator.free(description);
    }

    fn view(self: *const OwnedSelectItem) SelectItem {
        return .{
            .value = self.value,
            .label = self.label,
            .description = self.description,
        };
    }
};

fn identityTextStyle(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return allocator.dupe(u8, text);
}

fn applyBackgroundStyleToLine(allocator: std.mem.Allocator, line: []const u8, width: usize, bg_fn: BackgroundStyle) ![]u8 {
    const padded = try padToWidth(allocator, line, width);
    defer allocator.free(padded);
    return bg_fn.apply(allocator, padded);
}

fn contentWidth(width: usize, padding_x: usize) usize {
    const horizontal_padding = std.math.mul(usize, padding_x, 2) catch std.math.maxInt(usize);
    if (width > horizontal_padding) return width - horizontal_padding;
    return 1;
}

fn replaceTabsWithSpaces(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (text) |byte| {
        if (byte == '\t') {
            try output.appendSlice(allocator, "   ");
        } else {
            try output.append(allocator, byte);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn normalizeToSingleLine(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var in_newline_run = false;
    for (text) |byte| {
        if (byte == '\r' or byte == '\n') {
            if (!in_newline_run) {
                try output.append(allocator, ' ');
                in_newline_run = true;
            }
        } else {
            try output.append(allocator, byte);
            in_newline_run = false;
        }
    }

    const trimmed = std.mem.trim(u8, output.items, " \t\r\n");
    const result = try allocator.dupe(u8, trimmed);
    output.deinit(allocator);
    return result;
}

fn startsWithIgnoreCaseAscii(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (prefix, 0..) |byte, index| {
        if (std.ascii.toLower(text[index]) != std.ascii.toLower(byte)) return false;
    }
    return true;
}

fn clampUsize(value: usize, min: usize, max: usize) usize {
    return @max(min, @min(value, max));
}

fn displayValue(item: SelectItem) []const u8 {
    if (item.label.len > 0) return item.label;
    return item.value;
}

fn updateTrackerFromText(text: []const u8, tracker: *AnsiCodeTracker) void {
    var index: usize = 0;
    while (index < text.len) {
        if (extractAnsiCode(text, index)) |ansi| {
            tracker.process(ansi.code);
            index += ansi.length;
        } else {
            index += 1;
        }
    }
}

fn splitIntoTokensWithAnsi(allocator: std.mem.Allocator, text: []const u8) ![][]u8 {
    var tokens: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedLines(allocator, tokens.items);
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var pending_ansi: std.ArrayList(u8) = .empty;
    defer pending_ansi.deinit(allocator);

    var in_whitespace = false;
    var has_current = false;
    var index: usize = 0;
    while (index < text.len) {
        if (extractAnsiCode(text, index)) |ansi| {
            try pending_ansi.appendSlice(allocator, ansi.code);
            index += ansi.length;
            continue;
        }

        const end = nextUtf8SliceEnd(text, index);
        const slice = text[index..end];
        const char_is_space = slice.len == 1 and slice[0] == ' ';
        if (has_current and char_is_space != in_whitespace) {
            try tokens.append(allocator, try current.toOwnedSlice(allocator));
            has_current = false;
        }

        try flushPendingAnsi(allocator, &current, &pending_ansi);
        try current.appendSlice(allocator, slice);
        in_whitespace = char_is_space;
        has_current = true;
        index = end;
    }

    if (pending_ansi.items.len > 0) {
        try current.appendSlice(allocator, pending_ansi.items);
        pending_ansi.clearRetainingCapacity();
        has_current = true;
    }
    if (has_current) {
        try tokens.append(allocator, try current.toOwnedSlice(allocator));
    }
    return tokens.toOwnedSlice(allocator);
}

fn isWhitespaceToken(token: []const u8) bool {
    var index: usize = 0;
    var saw_space = false;
    while (index < token.len) {
        if (extractAnsiCode(token, index)) |ansi| {
            index += ansi.length;
            continue;
        }
        if (token[index] != ' ') return false;
        saw_space = true;
        index += 1;
    }
    return saw_space or token.len == 0;
}

fn trimEndSpaces(list: *std.ArrayList(u8)) void {
    while (list.items.len > 0 and list.items[list.items.len - 1] == ' ') {
        _ = list.pop();
    }
}

fn trimEndSpacesAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == ' ') end -= 1;
    return allocator.dupe(u8, input[0..end]);
}

fn freeOwnedLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

fn flushPendingAnsi(allocator: std.mem.Allocator, output: *std.ArrayList(u8), pending_ansi: *std.ArrayList(u8)) !void {
    if (pending_ansi.items.len == 0) return;
    try output.appendSlice(allocator, pending_ansi.items);
    pending_ansi.clearRetainingCapacity();
}

fn padToWidth(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, text);
    const text_width = visibleWidth(text);
    if (text_width < width) try appendSpaces(allocator, &output, width - text_width);
    return output.toOwnedSlice(allocator);
}

fn maybePadToWidth(allocator: std.mem.Allocator, text: []const u8, width: usize, pad: bool) ![]u8 {
    if (pad) return padToWidth(allocator, text, width);
    return allocator.dupe(u8, text);
}

fn repeatedSpaces(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const output = try allocator.alloc(u8, count);
    @memset(output, ' ');
    return output;
}

fn appendSpaces(allocator: std.mem.Allocator, output: *std.ArrayList(u8), count: usize) !void {
    try output.ensureUnusedCapacity(allocator, count);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) output.appendAssumeCapacity(' ');
}

fn isPrintableAscii(input: []const u8) bool {
    for (input) |byte| {
        if (byte < 0x20 or byte > 0x7e) return false;
    }
    return true;
}

fn decodeAt(input: []const u8, index: usize) ?DecodedCodepoint {
    if (index >= input.len) return null;
    const sequence_length = std.unicode.utf8ByteSequenceLength(input[index]) catch return null;
    const len: usize = @intCast(sequence_length);
    if (index + len > input.len) return null;
    const codepoint = std.unicode.utf8Decode(input[index .. index + len]) catch return null;
    return .{ .codepoint = codepoint, .len = len };
}

fn nextUtf8SliceEnd(input: []const u8, index: usize) usize {
    const decoded = decodeAt(input, index) orelse return index + 1;
    return index + decoded.len;
}

fn nextGraphemeEnd(input: []const u8, start: usize) usize {
    const first = decodeAt(input, start) orelse return start + 1;
    var end = start + first.len;
    var join_next = false;
    var regional_count: usize = if (isRegionalIndicator(first.codepoint)) 1 else 0;

    while (end < input.len) {
        const decoded = decodeAt(input, end) orelse break;
        const cp = decoded.codepoint;
        const should_join = join_next or
            cp == 0x200d or
            isZeroWidth(cp) or
            isSpacingMark(cp) or
            (regional_count == 1 and isRegionalIndicator(cp));
        if (!should_join) break;

        end += decoded.len;
        if (cp == 0x200d) {
            join_next = true;
        } else {
            join_next = false;
        }
        if (isRegionalIndicator(cp)) regional_count += 1;
    }

    return end;
}

fn graphemeWidth(segment: []const u8) usize {
    var first_visible: ?u21 = null;
    var width: usize = 0;
    var saw_zwj = false;
    var saw_emoji_modifier = false;
    var saw_vs16 = false;
    var saw_regional = false;

    var index: usize = 0;
    while (index < segment.len) {
        const decoded = decodeAt(segment, index) orelse {
            index += 1;
            continue;
        };
        const cp = decoded.codepoint;
        if (cp == 0x200d) saw_zwj = true;
        if (cp == 0xfe0f) saw_vs16 = true;
        if (cp >= 0x1f3fb and cp <= 0x1f3ff) saw_emoji_modifier = true;
        if (isRegionalIndicator(cp)) saw_regional = true;

        if (first_visible == null and !isNonPrinting(cp)) {
            first_visible = cp;
            width = codepointWidth(cp);
        } else if (first_visible != null) {
            if (cp >= 0xff00 and cp <= 0xffef) {
                width += codepointWidth(cp);
            } else if (cp == 0x0e33 or cp == 0x0eb3) {
                width += 1;
            }
        }

        index += decoded.len;
    }

    const base = first_visible orelse return 0;
    if (saw_regional and isRegionalIndicator(base)) return 2;
    if (isEmoji(base) or saw_zwj or saw_emoji_modifier or saw_vs16) return 2;
    return width;
}

fn codepointWidth(codepoint: u21) usize {
    if (isEmoji(codepoint) or isWide(codepoint)) return 2;
    return 1;
}

fn isRegionalIndicator(codepoint: u21) bool {
    return codepoint >= 0x1f1e6 and codepoint <= 0x1f1ff;
}

fn isEmoji(codepoint: u21) bool {
    return (codepoint >= 0x1f000 and codepoint <= 0x1fbff) or
        (codepoint >= 0x2300 and codepoint <= 0x23ff) or
        (codepoint >= 0x2600 and codepoint <= 0x27bf) or
        (codepoint >= 0x2b50 and codepoint <= 0x2b55);
}

fn isWide(codepoint: u21) bool {
    return (codepoint >= 0x1100 and codepoint <= 0x115f) or
        (codepoint >= 0x2329 and codepoint <= 0x232a) or
        (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or
        (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xfe10 and codepoint <= 0xfe19) or
        (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or
        (codepoint >= 0xff00 and codepoint <= 0xff60) or
        (codepoint >= 0xffe0 and codepoint <= 0xffe6) or
        (codepoint >= 0x20000 and codepoint <= 0x3fffd);
}

fn isZeroWidth(codepoint: u21) bool {
    return codepoint == 0xfe0f or
        (codepoint >= 0x0300 and codepoint <= 0x036f) or
        codepoint == 0x0e31 or
        (codepoint >= 0x0e34 and codepoint <= 0x0e3a) or
        (codepoint >= 0x0e47 and codepoint <= 0x0e4e) or
        codepoint == 0x0eb1 or
        (codepoint >= 0x0eb4 and codepoint <= 0x0ebc) or
        (codepoint >= 0x0ec8 and codepoint <= 0x0ece) or
        (codepoint >= 0x1ab0 and codepoint <= 0x1aff) or
        (codepoint >= 0x1dc0 and codepoint <= 0x1dff) or
        (codepoint >= 0x20d0 and codepoint <= 0x20ff) or
        (codepoint >= 0xfe20 and codepoint <= 0xfe2f) or
        (codepoint >= 0x1f3fb and codepoint <= 0x1f3ff);
}

fn isSpacingMark(codepoint: u21) bool {
    return codepoint == 0x0e33 or codepoint == 0x0eb3;
}

fn isNonPrinting(codepoint: u21) bool {
    return codepoint < 0x20 or codepoint == 0x7f or codepoint == 0x200d or isZeroWidth(codepoint);
}

fn expectOwnedString(expected: []const u8, actual: []u8) !void {
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectVisibleAtMost(text: []const u8, width: usize) !void {
    try std.testing.expect(visibleWidth(text) <= width);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}

fn lineHasVisibleText(line: []const u8) bool {
    var index: usize = 0;
    while (index < line.len) {
        if (extractAnsiCode(line, index)) |ansi| {
            index += ansi.length;
            continue;
        }
        if (line[index] != ' ') return true;
        index += 1;
    }
    return false;
}

test "truncateToWidth keeps output within width for very large unicode input" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    var i: usize = 0;
    while (i < 100_000) : (i += 1) try text.appendSlice(allocator, "🙂界");

    const truncated = try truncateToWidth(allocator, text.items, 40, "…", false);
    defer allocator.free(truncated);
    try expectVisibleAtMost(truncated, 40);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "…\x1b[0m"));
}

test "truncateToWidth preserves ANSI styling and resets around ellipsis" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "\x1b[31m");
    var i: usize = 0;
    while (i < 1000) : (i += 1) try text.appendSlice(allocator, "hello ");
    try text.appendSlice(allocator, "\x1b[0m");

    const truncated = try truncateToWidth(allocator, text.items, 20, "…", false);
    defer allocator.free(truncated);
    try expectVisibleAtMost(truncated, 20);
    try std.testing.expect(std.mem.indexOf(u8, truncated, "\x1b[31m") != null);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "\x1b[0m…\x1b[0m"));
}

test "truncateToWidth handles malformed ANSI escape prefixes without hanging" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "abc\x1bnot-ansi ");
    var i: usize = 0;
    while (i < 1000) : (i += 1) try text.appendSlice(allocator, "🙂");

    const truncated = try truncateToWidth(allocator, text.items, 20, "…", false);
    defer allocator.free(truncated);
    try expectVisibleAtMost(truncated, 20);
}

test "truncateToWidth clips wide ellipsis safely and brackets it with resets" {
    const allocator = std.testing.allocator;
    try expectOwnedString("", try truncateToWidth(allocator, "abcdef", 1, "🙂", false));
    try expectOwnedString("\x1b[0m🙂\x1b[0m", try truncateToWidth(allocator, "abcdef", 2, "🙂", false));

    const clipped = try truncateToWidth(allocator, "abcdef", 2, "🙂", false);
    defer allocator.free(clipped);
    try expectVisibleAtMost(clipped, 2);
}

test "truncateToWidth returns original text when it already fits even if ellipsis is too wide" {
    const allocator = std.testing.allocator;
    try expectOwnedString("a", try truncateToWidth(allocator, "a", 2, "🙂", false));
    try expectOwnedString("界", try truncateToWidth(allocator, "界", 2, "🙂", false));
}

test "truncateToWidth pads truncated output to requested width" {
    const allocator = std.testing.allocator;
    const truncated = try truncateToWidth(allocator, "🙂界🙂界🙂界", 8, "…", true);
    defer allocator.free(truncated);
    try std.testing.expectEqual(@as(usize, 8), visibleWidth(truncated));
}

test "truncateToWidth adds trailing reset when truncating without ellipsis" {
    const allocator = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, "\x1b[31m");
    var i: usize = 0;
    while (i < 100) : (i += 1) try text.appendSlice(allocator, "hello");

    const truncated = try truncateToWidth(allocator, text.items, 10, "", false);
    defer allocator.free(truncated);
    try expectVisibleAtMost(truncated, 10);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "\x1b[0m"));
}

test "truncateToWidth keeps a contiguous prefix instead of resuming after a wide grapheme" {
    const allocator = std.testing.allocator;
    try expectOwnedString("🙂\t\x1b[0m…\x1b[0m ", try truncateToWidth(allocator, "🙂\t界 \x1b_abc\x07", 7, "…", true));
}

test "visibleWidth counts tabs inline and skips ANSI, OSC, and APC inline" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\t\x1b[31m界\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\x1b]133;A\x07hello\x1b]133;B\x07"));
    try std.testing.expectEqual(@as(usize, 5), visibleWidth("\x1b]133;A\x1b\\hello\x1b]133;B\x1b\\"));
    try std.testing.expectEqual(@as(usize, 0), visibleWidth("\x1b_abc\x07"));
}

test "visibleWidth keeps Thai and Lao AM clusters at their normal cell width" {
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("ำ"));
    try std.testing.expectEqual(@as(usize, 1), visibleWidth("ຳ"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("กำ"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("ກຳ"));
}

test "normalizeTerminalOutput decomposes Thai and Lao AM vowels for terminal output" {
    const allocator = std.testing.allocator;
    try expectOwnedString("ํา", try normalizeTerminalOutput(allocator, "ำ"));
    try expectOwnedString("ໍາ", try normalizeTerminalOutput(allocator, "ຳ"));

    const thai = try normalizeTerminalOutput(allocator, "ำabc");
    defer allocator.free(thai);
    try std.testing.expectEqual(visibleWidth("ำabc"), visibleWidth(thai));

    const lao = try normalizeTerminalOutput(allocator, "ຳabc");
    defer allocator.free(lao);
    try std.testing.expectEqual(visibleWidth("ຳabc"), visibleWidth(lao));
}

test "regional indicator width regression cases" {
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("🇨"));
    try std.testing.expectEqual(@as(usize, 10), visibleWidth("      - 🇨"));

    const allocator = std.testing.allocator;
    const wrapped = try wrapTextWithAnsi(allocator, "      - 🇨", 9);
    defer freeOwnedLines(allocator, wrapped);
    try std.testing.expectEqual(@as(usize, 2), wrapped.len);
    try std.testing.expectEqual(@as(usize, 7), visibleWidth(wrapped[0]));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth(wrapped[1]));

    var cp: u21 = 0x1f1e6;
    while (cp <= 0x1f1ff) : (cp += 1) {
        var buffer: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buffer);
        try std.testing.expectEqual(@as(usize, 2), visibleWidth(buffer[0..len]));
    }

    const flags = [_][]const u8{ "🇯🇵", "🇺🇸", "🇬🇧", "🇨🇳", "🇩🇪", "🇫🇷" };
    for (flags) |flag| try std.testing.expectEqual(@as(usize, 2), visibleWidth(flag));

    const samples = [_][]const u8{ "👍", "👍🏻", "✅", "⚡", "⚡️", "👨", "👨‍💻", "🏳️‍🌈" };
    for (samples) |sample| try std.testing.expectEqual(@as(usize, 2), visibleWidth(sample));
}

test "wrapTextWithAnsi underline styling regressions" {
    const allocator = std.testing.allocator;
    const underline_on = "\x1b[4m";
    const underline_off = "\x1b[24m";

    const text = "read this thread " ++ underline_on ++ "https://example.com/very/long/path/that/will/wrap" ++ underline_off;
    const wrapped = try wrapTextWithAnsi(allocator, text, 40);
    defer freeOwnedLines(allocator, wrapped);
    try std.testing.expectEqualStrings("read this thread", wrapped[0]);
    try std.testing.expect(std.mem.startsWith(u8, wrapped[1], underline_on));
    try std.testing.expect(std.mem.indexOf(u8, wrapped[1], "https://") != null);

    const wrapped_trailing = try wrapTextWithAnsi(allocator, underline_on ++ "underlined text here " ++ underline_off ++ "more", 18);
    defer freeOwnedLines(allocator, wrapped_trailing);
    try std.testing.expect(std.mem.indexOf(u8, wrapped_trailing[0], " \x1b[24m") == null);

    const wrapped_url = try wrapTextWithAnsi(allocator, "prefix " ++ underline_on ++ "https://example.com/very/long/path/that/will/definitely/wrap" ++ underline_off ++ " suffix", 30);
    defer freeOwnedLines(allocator, wrapped_url);
    for (wrapped_url[1 .. wrapped_url.len - 1]) |line| {
        if (std.mem.indexOf(u8, line, underline_on) != null) {
            try std.testing.expect(std.mem.endsWith(u8, line, underline_off));
            try std.testing.expect(!std.mem.endsWith(u8, line, RESET));
        }
    }
}

test "wrapTextWithAnsi preserves background color across wrapped lines" {
    const allocator = std.testing.allocator;
    const bg_blue = "\x1b[44m";
    const wrapped = try wrapTextWithAnsi(allocator, bg_blue ++ "hello world this is blue background text" ++ RESET, 15);
    defer freeOwnedLines(allocator, wrapped);
    for (wrapped) |line| try std.testing.expect(std.mem.indexOf(u8, line, bg_blue) != null);
    for (wrapped[0 .. wrapped.len - 1]) |line| try std.testing.expect(!std.mem.endsWith(u8, line, RESET));

    const underline_on = "\x1b[4m";
    const underline_off = "\x1b[24m";
    const red_bg = "\x1b[41m";
    const wrapped_nested = try wrapTextWithAnsi(allocator, red_bg ++ "prefix " ++ underline_on ++ "UNDERLINED_CONTENT_THAT_WRAPS" ++ underline_off ++ " suffix" ++ RESET, 20);
    defer freeOwnedLines(allocator, wrapped_nested);
    for (wrapped_nested) |line| {
        const has_bg = std.mem.indexOf(u8, line, "[41m") != null or
            std.mem.indexOf(u8, line, ";41m") != null or
            std.mem.indexOf(u8, line, "[41;") != null;
        try std.testing.expect(has_bg);
    }
    for (wrapped_nested[0 .. wrapped_nested.len - 1]) |line| {
        const has_underline = std.mem.indexOf(u8, line, "[4m") != null or
            std.mem.indexOf(u8, line, "[4;") != null or
            std.mem.indexOf(u8, line, ";4m") != null;
        if (has_underline and std.mem.indexOf(u8, line, underline_off) == null) {
            try std.testing.expect(std.mem.endsWith(u8, line, underline_off));
            try std.testing.expect(!std.mem.endsWith(u8, line, RESET));
        }
    }
}

test "wrapTextWithAnsi basic wrapping and color preservation" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapTextWithAnsi(allocator, "hello world this is a test", 10);
    defer freeOwnedLines(allocator, wrapped);
    try std.testing.expect(wrapped.len > 1);
    for (wrapped) |line| try expectVisibleAtMost(line, 10);

    try std.testing.expectEqual(@as(usize, 2), visibleWidth("🇨"));
    try std.testing.expectEqual(@as(usize, 2), visibleWidth("🇨🇳"));

    const spaces = try wrapTextWithAnsi(allocator, "  ", 1);
    defer freeOwnedLines(allocator, spaces);
    try expectVisibleAtMost(spaces[0], 1);

    const red = "\x1b[31m";
    const colored = try wrapTextWithAnsi(allocator, red ++ "hello world this is red" ++ RESET, 10);
    defer freeOwnedLines(allocator, colored);
    for (colored[1..]) |line| try std.testing.expect(std.mem.startsWith(u8, line, red));
    for (colored[0 .. colored.len - 1]) |line| try std.testing.expect(!std.mem.endsWith(u8, line, RESET));
}

test "wrapTextWithAnsi re-emits and closes OSC 8 hyperlinks across wrapped lines" {
    const allocator = std.testing.allocator;
    const url = "https://example.com";
    const input = "\x1b]8;;" ++ url ++ "\x1b\\0123456789\x1b]8;;\x1b\\";
    const lines = try wrapTextWithAnsi(allocator, input, 6);
    defer freeOwnedLines(allocator, lines);

    for (lines) |line| {
        if (lineHasVisibleText(line)) {
            try std.testing.expect(std.mem.startsWith(u8, line, "\x1b]8;;" ++ url ++ "\x1b\\") or
                std.mem.indexOf(u8, line, "\x1b]8;;" ++ url ++ "\x1b\\") != null);
        }
    }
    for (lines[0 .. lines.len - 1]) |line| {
        if (std.mem.indexOf(u8, line, "\x1b]8;;" ++ url ++ "\x1b\\") != null) {
            try std.testing.expect(std.mem.endsWith(u8, line, "\x1b]8;;\x1b\\"));
        }
    }
}

test "wrapTextWithAnsi preserves OSC 8 BEL terminators and avoids extra links" {
    const allocator = std.testing.allocator;
    const oauth_url = "https://example.com/oauth/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const oauth_input = "\x1b]8;;" ++ oauth_url ++ "\x07" ++ oauth_url ++ "\x1b]8;;\x07";
    const oauth_lines = try wrapTextWithAnsi(allocator, oauth_input, 20);
    defer freeOwnedLines(allocator, oauth_lines);
    try std.testing.expect(oauth_lines.len > 1);
    for (oauth_lines) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, "\x1b]8;;" ++ oauth_url ++ "\x07") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "\x1b]8;;" ++ oauth_url ++ "\x1b\\") == null);
    }
    for (oauth_lines[0 .. oauth_lines.len - 1]) |line| {
        try std.testing.expect(std.mem.endsWith(u8, line, "\x1b]8;;\x07"));
    }

    const url = "https://example.com";
    const input = "before \x1b]8;;" ++ url ++ "\x1b\\link\x1b]8;;\x1b\\ after";
    const lines = try wrapTextWithAnsi(allocator, input, 80);
    defer freeOwnedLines(allocator, lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(lines[0], "\x1b]8;;https://example.com\x1b\\"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(lines[0], "\x1b]8;;\x1b\\"));
}

test "slice helpers preserve ANSI and widths" {
    const allocator = std.testing.allocator;
    const sliced = try sliceWithWidth(allocator, "\x1b[31mab界cd", 1, 3, true);
    defer allocator.free(sliced.text);
    try std.testing.expectEqual(@as(usize, 3), sliced.width);
    try std.testing.expectEqualStrings("\x1b[31mb界", sliced.text);

    const segments = try extractSegments(allocator, "\x1b[31mabcdef", 2, 4, 2, false);
    defer segments.deinit(allocator);
    try std.testing.expectEqualStrings("\x1b[31mab", segments.before);
    try std.testing.expectEqualStrings("\x1b[31mef", segments.after);
}

test "TruncatedText pads output lines to exactly match width" {
    const allocator = std.testing.allocator;
    var text = try TruncatedText.init(allocator, "Hello world", 1, 0);
    defer text.deinit();

    const lines = try text.render(allocator, 50);
    defer freeRenderedLines(allocator, lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 50), visibleWidth(lines[0]));
}

test "TruncatedText pads output with vertical padding lines to width" {
    const allocator = std.testing.allocator;
    var text = try TruncatedText.init(allocator, "Hello", 0, 2);
    defer text.deinit();

    const lines = try text.render(allocator, 40);
    defer freeRenderedLines(allocator, lines);

    try std.testing.expectEqual(@as(usize, 5), lines.len);
    for (lines) |line| try std.testing.expectEqual(@as(usize, 40), visibleWidth(line));
}

test "TruncatedText truncates long text and pads to width" {
    const allocator = std.testing.allocator;
    const long_text = "This is a very long piece of text that will definitely exceed the available width";
    var text = try TruncatedText.init(allocator, long_text, 1, 0);
    defer text.deinit();

    const lines = try text.render(allocator, 30);
    defer freeRenderedLines(allocator, lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 30), visibleWidth(lines[0]));
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "...") != null);
}

test "TruncatedText preserves ANSI codes in output and pads correctly" {
    const allocator = std.testing.allocator;
    var text = try TruncatedText.init(allocator, "\x1b[31mHello\x1b[0m \x1b[34mworld\x1b[0m", 1, 0);
    defer text.deinit();

    const lines = try text.render(allocator, 40);
    defer freeRenderedLines(allocator, lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 40), visibleWidth(lines[0]));
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "\x1b[") != null);
}

test "TruncatedText truncates styled text and adds reset code before ellipsis" {
    const allocator = std.testing.allocator;
    var text = try TruncatedText.init(allocator, "\x1b[31mThis is a very long red text that will be truncated\x1b[0m", 1, 0);
    defer text.deinit();

    const lines = try text.render(allocator, 20);
    defer freeRenderedLines(allocator, lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqual(@as(usize, 20), visibleWidth(lines[0]));
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "\x1b[0m...") != null);
}

test "TruncatedText handles fitting, empty, and multiline text" {
    const allocator = std.testing.allocator;

    var fitting = try TruncatedText.init(allocator, "Hello world", 1, 0);
    defer fitting.deinit();
    const fitting_lines = try fitting.render(allocator, 30);
    defer freeRenderedLines(allocator, fitting_lines);
    try std.testing.expectEqual(@as(usize, 30), visibleWidth(fitting_lines[0]));
    try std.testing.expect(std.mem.indexOf(u8, fitting_lines[0], "...") == null);

    var empty = try TruncatedText.init(allocator, "", 1, 0);
    defer empty.deinit();
    const empty_lines = try empty.render(allocator, 30);
    defer freeRenderedLines(allocator, empty_lines);
    try std.testing.expectEqual(@as(usize, 30), visibleWidth(empty_lines[0]));

    var multiline = try TruncatedText.init(allocator, "First line\nSecond line\nThird line", 1, 0);
    defer multiline.deinit();
    const multiline_lines = try multiline.render(allocator, 40);
    defer freeRenderedLines(allocator, multiline_lines);
    try std.testing.expect(std.mem.indexOf(u8, multiline_lines[0], "First line") != null);
    try std.testing.expect(std.mem.indexOf(u8, multiline_lines[0], "Second line") == null);

    var long_multiline = try TruncatedText.init(allocator, "This is a very long first line that needs truncation\nSecond line", 1, 0);
    defer long_multiline.deinit();
    const long_lines = try long_multiline.render(allocator, 25);
    defer freeRenderedLines(allocator, long_lines);
    try std.testing.expectEqual(@as(usize, 25), visibleWidth(long_lines[0]));
    try std.testing.expect(std.mem.indexOf(u8, long_lines[0], "...") != null);
    try std.testing.expect(std.mem.indexOf(u8, long_lines[0], "Second line") == null);
}

test "Text and Box render wrapped padded component output" {
    const allocator = std.testing.allocator;
    var text = try Text.init(allocator, "Hello\tworld this wraps", 1, 1, null);
    defer text.deinit();

    const text_lines = try text.render(allocator, 14);
    defer freeRenderedLines(allocator, text_lines);
    try std.testing.expect(text_lines.len > 2);
    for (text_lines) |line| try std.testing.expectEqual(@as(usize, 14), visibleWidth(line));

    var box = Box.init(allocator, 1, 1, null);
    defer box.deinit();
    try box.addChild(Component.from(Text, &text));
    const box_lines = try box.render(allocator, 18);
    defer freeRenderedLines(allocator, box_lines);
    try std.testing.expect(box_lines.len > text_lines.len);
    for (box_lines) |line| try std.testing.expectEqual(@as(usize, 18), visibleWidth(line));
}

fn visibleIndexOf(line: []const u8, text: []const u8) !usize {
    const index = std.mem.indexOf(u8, line, text) orelse return error.NotFound;
    return visibleWidth(line[0..index]);
}

test "SelectList normalizes multiline descriptions to single line" {
    const allocator = std.testing.allocator;
    const items = [_]SelectItem{.{
        .value = "test",
        .label = "test",
        .description = "Line one\nLine two\nLine three",
    }};
    var list = try SelectList.init(allocator, &items, 5, .{}, .{});
    defer list.deinit();

    const rendered = try list.render(allocator, 100);
    defer freeRenderedLines(allocator, rendered);

    try std.testing.expect(rendered.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered[0], '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0], "Line one Line two Line three") != null);
}

test "SelectList keeps descriptions aligned when the primary text is truncated" {
    const allocator = std.testing.allocator;
    const items = [_]SelectItem{
        .{ .value = "short", .label = "short", .description = "short description" },
        .{
            .value = "very-long-command-name-that-needs-truncation",
            .label = "very-long-command-name-that-needs-truncation",
            .description = "long description",
        },
    };
    var list = try SelectList.init(allocator, &items, 5, .{}, .{});
    defer list.deinit();

    const rendered = try list.render(allocator, 80);
    defer freeRenderedLines(allocator, rendered);

    try std.testing.expectEqual(try visibleIndexOf(rendered[0], "short description"), try visibleIndexOf(rendered[1], "long description"));
}

test "SelectList uses configured minimum and maximum primary column widths" {
    const allocator = std.testing.allocator;
    const min_items = [_]SelectItem{
        .{ .value = "a", .label = "a", .description = "first" },
        .{ .value = "bb", .label = "bb", .description = "second" },
    };
    var min_list = try SelectList.init(allocator, &min_items, 5, .{}, .{
        .min_primary_column_width = 12,
        .max_primary_column_width = 20,
    });
    defer min_list.deinit();
    const min_rendered = try min_list.render(allocator, 80);
    defer freeRenderedLines(allocator, min_rendered);
    try std.testing.expectEqual(@as(usize, 14), try visibleIndexOf(min_rendered[0], "first"));
    try std.testing.expectEqual(@as(usize, 14), try visibleIndexOf(min_rendered[1], "second"));

    const max_items = [_]SelectItem{
        .{
            .value = "very-long-command-name-that-needs-truncation",
            .label = "very-long-command-name-that-needs-truncation",
            .description = "first",
        },
        .{ .value = "short", .label = "short", .description = "second" },
    };
    var max_list = try SelectList.init(allocator, &max_items, 5, .{}, .{
        .min_primary_column_width = 12,
        .max_primary_column_width = 20,
    });
    defer max_list.deinit();
    const max_rendered = try max_list.render(allocator, 80);
    defer freeRenderedLines(allocator, max_rendered);
    try std.testing.expectEqual(@as(usize, 22), try visibleIndexOf(max_rendered[0], "first"));
    try std.testing.expectEqual(@as(usize, 22), try visibleIndexOf(max_rendered[1], "second"));
}

fn ellipsisTruncate(_: ?*anyopaque, allocator: std.mem.Allocator, context: SelectListTruncatePrimaryContext) ![]u8 {
    if (context.text.len <= context.max_width) return allocator.dupe(u8, context.text);
    const prefix_len = if (context.max_width > 0) context.max_width - 1 else 0;
    return std.mem.concat(allocator, u8, &.{ context.text[0..@min(prefix_len, context.text.len)], "…" });
}

test "SelectList allows overriding primary truncation while preserving description alignment" {
    const allocator = std.testing.allocator;
    const items = [_]SelectItem{
        .{
            .value = "very-long-command-name-that-needs-truncation",
            .label = "very-long-command-name-that-needs-truncation",
            .description = "first",
        },
        .{ .value = "short", .label = "short", .description = "second" },
    };
    var list = try SelectList.init(allocator, &items, 5, .{}, .{
        .min_primary_column_width = 12,
        .max_primary_column_width = 12,
        .truncate_primary = .{ .call_fn = ellipsisTruncate },
    });
    defer list.deinit();

    const rendered = try list.render(allocator, 80);
    defer freeRenderedLines(allocator, rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered[0], "…") != null);
    try std.testing.expectEqual(try visibleIndexOf(rendered[0], "first"), try visibleIndexOf(rendered[1], "second"));
}

test "SelectList filters, wraps selection input, and reports no matches" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    const items = [_]SelectItem{
        .{ .value = "alpha", .label = "alpha" },
        .{ .value = "beta", .label = "beta" },
    };
    var list = try SelectList.init(allocator, &items, 5, .{}, .{});
    defer list.deinit();

    try list.handleInput(allocator, "\x1b[B");
    try std.testing.expectEqualStrings("beta", list.getSelectedItem().?.value);
    try list.handleInput(allocator, "\x1b[B");
    try std.testing.expectEqualStrings("alpha", list.getSelectedItem().?.value);

    try list.setFilter("zzz");
    try std.testing.expectEqual(@as(?SelectItem, null), list.getSelectedItem());
    const rendered = try list.render(allocator, 40);
    defer freeRenderedLines(allocator, rendered);
    try std.testing.expectEqual(@as(usize, 1), rendered.len);
    try std.testing.expectEqualStrings("  No matching commands", rendered[0]);
}

test {
    _ = @import("keys.zig");
    _ = @import("keybindings.zig");
    _ = @import("fuzzy.zig");
    _ = @import("autocomplete.zig");
}
