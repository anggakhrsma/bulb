const std = @import("std");

pub const keys = @import("keys.zig");
pub const keybindings = @import("keybindings.zig");

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

test {
    _ = @import("keys.zig");
    _ = @import("keybindings.zig");
}
