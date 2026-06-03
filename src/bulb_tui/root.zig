const std = @import("std");

pub const keys = @import("keys.zig");
pub const keybindings = @import("keybindings.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const autocomplete = @import("autocomplete.zig");
pub const word_navigation = @import("word_navigation.zig");
pub const kill_ring = @import("kill_ring.zig");
pub const undo_stack = @import("undo_stack.zig");
pub const stdin_buffer = @import("stdin_buffer.zig");
pub const terminal_image = @import("terminal_image.zig");
pub const native_modifiers = @import("native_modifiers.zig");

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

pub const RenderRequester = struct {
    ptr: ?*anyopaque = null,
    request_fn: *const fn (?*anyopaque) void,

    pub fn requestRender(self: RenderRequester) void {
        self.request_fn(self.ptr);
    }
};

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

pub const Spacer = struct {
    lines: usize = 1,

    pub fn init(lines: usize) Spacer {
        return .{ .lines = lines };
    }

    pub fn setLines(self: *Spacer, lines: usize) void {
        self.lines = lines;
    }

    pub fn invalidate(_: *Spacer) void {}

    pub fn render(self: *const Spacer, allocator: std.mem.Allocator, _: usize) ![][]u8 {
        var result: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, result.items);
        var index: usize = 0;
        while (index < self.lines) : (index += 1) {
            try result.append(allocator, try allocator.dupe(u8, ""));
        }
        return result.toOwnedSlice(allocator);
    }
};

pub const ImageTheme = struct {
    fallback_color: TextStyle = .{},
};

pub const ImageOptions = struct {
    max_width_cells: ?usize = null,
    max_height_cells: ?usize = null,
    filename: ?[]const u8 = null,
    image_id: ?u32 = null,
};

pub const Image = struct {
    allocator: std.mem.Allocator,
    base64_data: []u8,
    mime_type: []u8,
    dimensions: terminal_image.ImageDimensions,
    theme: ImageTheme,
    options: ImageOptions,
    owned_filename: ?[]u8 = null,
    image_id: ?u32 = null,
    cached_lines: ?[][]u8 = null,
    cached_width: ?usize = null,

    pub fn init(
        allocator: std.mem.Allocator,
        base64_data: []const u8,
        mime_type: []const u8,
        theme: ImageTheme,
        options: ImageOptions,
        dimensions: ?terminal_image.ImageDimensions,
    ) !Image {
        const owned_base64 = try allocator.dupe(u8, base64_data);
        errdefer allocator.free(owned_base64);
        const owned_mime = try allocator.dupe(u8, mime_type);
        errdefer allocator.free(owned_mime);
        const owned_filename = if (options.filename) |filename|
            try allocator.dupe(u8, filename)
        else
            null;
        errdefer if (owned_filename) |filename| allocator.free(filename);

        var stored_options = options;
        stored_options.filename = owned_filename;

        return .{
            .allocator = allocator,
            .base64_data = owned_base64,
            .mime_type = owned_mime,
            .dimensions = dimensions orelse
                (terminal_image.getImageDimensions(allocator, base64_data, mime_type) orelse .{ .width_px = 800, .height_px = 600 }),
            .theme = theme,
            .options = stored_options,
            .owned_filename = owned_filename,
            .image_id = options.image_id,
        };
    }

    pub fn deinit(self: *Image) void {
        self.clearCache();
        self.allocator.free(self.base64_data);
        self.allocator.free(self.mime_type);
        if (self.owned_filename) |filename| self.allocator.free(filename);
    }

    pub fn getImageId(self: *const Image) ?u32 {
        return self.image_id;
    }

    pub fn invalidate(self: *Image) void {
        self.clearCache();
    }

    pub fn render(self: *Image, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        if (self.cached_lines) |lines| {
            if (self.cached_width == width) return cloneOwnedLines(allocator, lines);
        }

        const available = if (width > 2) width - 2 else 0;
        const requested_max_width = self.options.max_width_cells orelse 60;
        const max_width = @max(@as(usize, 1), @min(available, requested_max_width));
        const cell_dimensions = terminal_image.getCellDimensions();
        const default_max_height = ceilDiv(max_width * cell_dimensions.width_px, cell_dimensions.height_px);
        const max_height = self.options.max_height_cells orelse @max(@as(usize, 1), default_max_height);
        const caps = terminal_image.getCapabilities();

        const lines = if (caps.images != null)
            try self.renderProtocolLines(self.allocator, max_width, max_height, caps.images.?)
        else
            try self.renderFallback(self.allocator);
        errdefer freeOwnedLines(self.allocator, lines);

        self.replaceCache(lines, width);
        return cloneOwnedLines(allocator, self.cached_lines.?);
    }

    fn renderProtocolLines(
        self: *Image,
        allocator: std.mem.Allocator,
        max_width: usize,
        max_height: usize,
        protocol: terminal_image.ImageProtocol,
    ) ![][]u8 {
        if (protocol == .kitty and self.image_id == null) {
            self.image_id = terminal_image.allocateImageId();
        }

        const rendered = (try terminal_image.renderImage(allocator, self.base64_data, self.dimensions, .{
            .max_width_cells = max_width,
            .max_height_cells = max_height,
            .image_id = self.image_id,
            .move_cursor = false,
        })) orelse return self.renderFallback(allocator);
        defer rendered.deinit(allocator);

        if (rendered.image_id) |image_id| self.image_id = image_id;

        var lines: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, lines.items);

        if (protocol == .kitty) {
            try lines.append(allocator, try allocator.dupe(u8, rendered.sequence));
            var row: usize = 1;
            while (row < rendered.rows) : (row += 1) try lines.append(allocator, try allocator.dupe(u8, ""));
        } else {
            var row: usize = 1;
            while (row < rendered.rows) : (row += 1) try lines.append(allocator, try allocator.dupe(u8, ""));
            if (rendered.rows > 1) {
                try lines.append(allocator, try std.fmt.allocPrint(allocator, "\x1b[{d}A{s}", .{ rendered.rows - 1, rendered.sequence }));
            } else {
                try lines.append(allocator, try allocator.dupe(u8, rendered.sequence));
            }
        }

        return lines.toOwnedSlice(allocator);
    }

    fn renderFallback(self: *Image, allocator: std.mem.Allocator) ![][]u8 {
        const fallback = try terminal_image.imageFallback(allocator, self.mime_type, self.dimensions, self.options.filename);
        defer allocator.free(fallback);
        const styled = try self.theme.fallback_color.apply(allocator, fallback);
        errdefer allocator.free(styled);
        var lines = try allocator.alloc([]u8, 1);
        lines[0] = styled;
        return lines;
    }

    fn replaceCache(self: *Image, lines: [][]u8, width: usize) void {
        self.clearCache();
        self.cached_lines = lines;
        self.cached_width = width;
    }

    fn clearCache(self: *Image) void {
        if (self.cached_lines) |lines| freeOwnedLines(self.allocator, lines);
        self.cached_lines = null;
        self.cached_width = null;
    }
};

pub const DefaultTextStyle = struct {
    color: ?TextStyle = null,
    bg_color: ?BackgroundStyle = null,
    bold: bool = false,
    italic: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
};

pub const MarkdownTheme = struct {
    heading: TextStyle = .{},
    link: TextStyle = .{},
    link_url: TextStyle = .{},
    code: TextStyle = .{},
    code_block: TextStyle = .{},
    code_block_border: TextStyle = .{},
    quote: TextStyle = .{},
    quote_border: TextStyle = .{},
    hr: TextStyle = .{},
    list_bullet: TextStyle = .{},
    bold: TextStyle = .{},
    italic: TextStyle = .{},
    strikethrough: TextStyle = .{},
    underline: TextStyle = .{},
    code_block_indent: []const u8 = "  ",
};

pub const MarkdownOptions = struct {
    preserve_ordered_list_markers: bool = false,
};

const InlineStyleKind = enum {
    default,
    none,
    heading_one,
    heading,
    quote,
};

const InlineStyleContext = struct {
    kind: InlineStyleKind,
    style_prefix: []u8,

    fn deinit(self: InlineStyleContext, allocator: std.mem.Allocator) void {
        allocator.free(self.style_prefix);
    }
};

const MarkdownBlockKind = enum {
    paragraph,
    heading,
    code,
    list,
    table,
    blockquote,
    hr,
    space,
};

const ListMarker = struct {
    indent: usize,
    depth: usize,
    ordered: bool,
    number: usize,
    marker_len: usize,
    delimiter: u8,

    fn content(self: ListMarker, line: []const u8) []const u8 {
        return line[self.marker_len..];
    }
};

pub const Markdown = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    padding_x: usize,
    padding_y: usize,
    theme: MarkdownTheme,
    default_text_style: ?DefaultTextStyle = null,
    options: MarkdownOptions = .{},
    cached_width: ?usize = null,
    cached_lines: ?[][]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        text: []const u8,
        padding_x: usize,
        padding_y: usize,
        theme: MarkdownTheme,
        default_text_style: ?DefaultTextStyle,
        options: MarkdownOptions,
    ) !Markdown {
        return .{
            .allocator = allocator,
            .text = try allocator.dupe(u8, text),
            .padding_x = padding_x,
            .padding_y = padding_y,
            .theme = theme,
            .default_text_style = default_text_style,
            .options = options,
        };
    }

    pub fn deinit(self: *Markdown) void {
        self.clearCache();
        self.allocator.free(self.text);
    }

    pub fn setText(self: *Markdown, text: []const u8) !void {
        const next = try self.allocator.dupe(u8, text);
        self.allocator.free(self.text);
        self.text = next;
        self.invalidate();
    }

    pub fn invalidate(self: *Markdown) void {
        self.clearCache();
    }

    pub fn render(self: *Markdown, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        if (self.cached_lines) |lines| {
            if (self.cached_width == width) return cloneOwnedLines(allocator, lines);
        }

        const rendered = try self.renderFresh(self.allocator, width);
        errdefer freeOwnedLines(self.allocator, rendered);
        self.replaceCache(rendered, width);
        return cloneOwnedLines(allocator, self.cached_lines.?);
    }

    fn renderFresh(self: *Markdown, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        if (self.text.len == 0 or std.mem.trim(u8, self.text, " \t\r\n").len == 0) {
            return allocator.alloc([]u8, 0);
        }

        const normalized = try replaceTabsWithSpaces(allocator, self.text);
        defer allocator.free(normalized);

        const content_width = contentWidth(width, self.padding_x);
        const rendered_lines = try self.renderBlocks(allocator, normalized, content_width, .default);
        defer freeOwnedLines(allocator, rendered_lines);

        var wrapped_lines: std.ArrayList([]u8) = .empty;
        defer {
            for (wrapped_lines.items) |line| allocator.free(line);
            wrapped_lines.deinit(allocator);
        }
        for (rendered_lines) |line| {
            if (terminal_image.isImageLine(line)) {
                try wrapped_lines.append(allocator, try allocator.dupe(u8, line));
                continue;
            }
            if (visibleWidth(line) <= content_width) {
                try wrapped_lines.append(allocator, try allocator.dupe(u8, line));
                continue;
            }
            const wrapped = try wrapTextWithAnsi(allocator, line, content_width);
            defer freeOwnedLines(allocator, wrapped);
            for (wrapped) |wrapped_line| try wrapped_lines.append(allocator, try allocator.dupe(u8, wrapped_line));
        }

        var result: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, result.items);

        const empty_line = try repeatedSpaces(allocator, width);
        defer allocator.free(empty_line);
        var y: usize = 0;
        while (y < self.padding_y) : (y += 1) {
            try result.append(allocator, try self.applyMarkdownBackground(allocator, empty_line, width));
        }

        for (wrapped_lines.items) |line| {
            if (terminal_image.isImageLine(line)) {
                try result.append(allocator, try allocator.dupe(u8, line));
                continue;
            }

            var line_with_margins: std.ArrayList(u8) = .empty;
            defer line_with_margins.deinit(allocator);
            try appendSpaces(allocator, &line_with_margins, self.padding_x);
            try line_with_margins.appendSlice(allocator, line);
            try appendSpaces(allocator, &line_with_margins, self.padding_x);
            try result.append(allocator, try self.applyMarkdownBackground(allocator, line_with_margins.items, width));
        }

        y = 0;
        while (y < self.padding_y) : (y += 1) {
            try result.append(allocator, try self.applyMarkdownBackground(allocator, empty_line, width));
        }

        if (result.items.len == 0) try result.append(allocator, try allocator.dupe(u8, ""));
        return result.toOwnedSlice(allocator);
    }

    fn renderBlocks(self: *Markdown, allocator: std.mem.Allocator, text: []const u8, width: usize, style_kind: InlineStyleKind) anyerror![][]u8 {
        const lines = try splitBorrowedLines(allocator, text);
        defer allocator.free(lines);

        var output: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, output.items);

        var index: usize = 0;
        while (index < lines.len) {
            const line = lines[index];
            if (isBlankLine(line)) {
                try appendSingleBlank(allocator, &output);
                index += 1;
                continue;
            }

            const kind = blockKindAt(lines, index);
            switch (kind) {
                .heading => {
                    const parsed = parseHeading(line).?;
                    const heading_kind: InlineStyleKind = if (parsed.level == 1) .heading_one else .heading;
                    const ctx = try self.makeInlineStyleContext(allocator, heading_kind);
                    defer ctx.deinit(allocator);
                    const heading_text = try self.renderInlineText(allocator, parsed.text, ctx);
                    defer allocator.free(heading_text);
                    if (parsed.level >= 3) {
                        const prefix = try repeatedSlice(allocator, "#", parsed.level);
                        defer allocator.free(prefix);
                        const marker = try std.mem.concat(allocator, u8, &.{ prefix, " " });
                        defer allocator.free(marker);
                        const styled_marker = try self.applyStyleKind(allocator, heading_kind, marker);
                        defer allocator.free(styled_marker);
                        try output.append(allocator, try std.mem.concat(allocator, u8, &.{ styled_marker, heading_text }));
                    } else {
                        try output.append(allocator, try allocator.dupe(u8, heading_text));
                    }
                    index += 1;
                },
                .code => {
                    const parsed = try self.renderFencedCode(allocator, lines, index);
                    defer freeOwnedLines(allocator, parsed.lines);
                    for (parsed.lines) |rendered| try output.append(allocator, try allocator.dupe(u8, rendered));
                    index = parsed.next_index;
                },
                .list => {
                    const start = index;
                    index += 1;
                    while (index < lines.len and !isBlankLine(lines[index])) : (index += 1) {
                        if (parseListMarker(lines[index]) != null) continue;
                        if (leadingSpaceCount(lines[index]) > 0) continue;
                        break;
                    }
                    const list_lines = try self.renderListLines(allocator, lines[start..index], width, style_kind);
                    defer freeOwnedLines(allocator, list_lines);
                    for (list_lines) |rendered| try output.append(allocator, try allocator.dupe(u8, rendered));
                },
                .table => {
                    const start = index;
                    index += 2;
                    while (index < lines.len and isTableRow(lines[index])) : (index += 1) {}
                    const table_lines = try self.renderTableLines(allocator, lines[start..index], width, style_kind);
                    defer freeOwnedLines(allocator, table_lines);
                    for (table_lines) |rendered| try output.append(allocator, try allocator.dupe(u8, rendered));
                },
                .blockquote => {
                    const start = index;
                    index += 1;
                    while (index < lines.len and !isBlankLine(lines[index]) and continuesBlockquote(lines[index])) : (index += 1) {}
                    const quote_lines = try self.renderQuoteLines(allocator, lines[start..index], width);
                    defer freeOwnedLines(allocator, quote_lines);
                    for (quote_lines) |rendered| try output.append(allocator, try allocator.dupe(u8, rendered));
                },
                .hr => {
                    const count = @min(width, 80);
                    const rule = try repeatedSlice(allocator, "─", count);
                    defer allocator.free(rule);
                    try output.append(allocator, try self.theme.hr.apply(allocator, rule));
                    index += 1;
                },
                .paragraph => {
                    const start = index;
                    index += 1;
                    while (index < lines.len and !isBlankLine(lines[index]) and blockKindAt(lines, index) == .paragraph) : (index += 1) {}
                    const paragraph = try joinLinesWith(allocator, lines[start..index], "\n");
                    defer allocator.free(paragraph);
                    const ctx = try self.makeInlineStyleContext(allocator, style_kind);
                    defer ctx.deinit(allocator);
                    const rendered = try self.renderInlineText(allocator, paragraph, ctx);
                    try output.append(allocator, rendered);
                },
                .space => unreachable,
            }

            if (index < lines.len and !isBlankLine(lines[index]) and addsSpacingBeforeNext(kind, blockKindAt(lines, index))) {
                try appendSingleBlank(allocator, &output);
            }
        }

        return output.toOwnedSlice(allocator);
    }

    fn renderFencedCode(self: *Markdown, allocator: std.mem.Allocator, lines: []const []const u8, start: usize) !struct { lines: [][]u8, next_index: usize } {
        const fence_line = std.mem.trim(u8, lines[start], " \t");
        const lang = std.mem.trim(u8, fence_line[3..], " \t");
        var rendered: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, rendered.items);

        const opening = try std.mem.concat(allocator, u8, &.{ "```", lang });
        defer allocator.free(opening);
        try rendered.append(allocator, try self.theme.code_block_border.apply(allocator, opening));

        var index = start + 1;
        while (index < lines.len) : (index += 1) {
            const trimmed = std.mem.trim(u8, lines[index], " \t");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                index += 1;
                break;
            }
            const styled = try self.theme.code_block.apply(allocator, lines[index]);
            defer allocator.free(styled);
            try rendered.append(allocator, try std.mem.concat(allocator, u8, &.{ self.theme.code_block_indent, styled }));
        }
        try rendered.append(allocator, try self.theme.code_block_border.apply(allocator, "```"));

        return .{ .lines = try rendered.toOwnedSlice(allocator), .next_index = index };
    }

    fn renderListLines(self: *Markdown, allocator: std.mem.Allocator, lines: []const []const u8, width: usize, style_kind: InlineStyleKind) anyerror![][]u8 {
        var output: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, output.items);

        var ordered_counters = [_]usize{0} ** 16;
        var ordered_active = [_]bool{false} ** 16;
        var index: usize = 0;
        while (index < lines.len) {
            const marker = parseListMarker(lines[index]) orelse {
                index += 1;
                continue;
            };
            const depth = @min(marker.depth, ordered_counters.len - 1);
            var content = trimRightBytes(marker.content(lines[index]), " \t\r");

            var marker_text: []u8 = undefined;
            if (marker.ordered) {
                const number = if (self.options.preserve_ordered_list_markers)
                    marker.number
                else if (ordered_active[depth] and marker.number == 1)
                    ordered_counters[depth] + 1
                else
                    marker.number;
                ordered_counters[depth] = number;
                ordered_active[depth] = true;
                marker_text = try std.fmt.allocPrint(allocator, "{d}{c} ", .{ number, marker.delimiter });
            } else {
                marker_text = try allocator.dupe(u8, "- ");
                ordered_active[depth] = false;
            }
            defer allocator.free(marker_text);
            for (depth + 1..ordered_active.len) |clear_index| ordered_active[clear_index] = false;

            var task_marker: ?[]const u8 = null;
            if (std.mem.startsWith(u8, content, "[ ] ")) {
                task_marker = "[ ] ";
                content = content[4..];
            } else if (std.mem.startsWith(u8, content, "[x] ") or std.mem.startsWith(u8, content, "[X] ")) {
                task_marker = "[x] ";
                content = content[4..];
            }
            const full_marker = if (task_marker) |task|
                try std.mem.concat(allocator, u8, &.{ marker_text, task })
            else
                try allocator.dupe(u8, marker_text);
            defer allocator.free(full_marker);

            const indent_spaces = marker.depth * 4;
            const styled_marker = try self.theme.list_bullet.apply(allocator, full_marker);
            defer allocator.free(styled_marker);
            const first_prefix = try prefixedSpacesConcat(allocator, indent_spaces, styled_marker);
            defer allocator.free(first_prefix);
            const continuation_prefix = try repeatedSpaces(allocator, indent_spaces + visibleWidth(full_marker));
            defer allocator.free(continuation_prefix);
            const item_width = if (width > visibleWidth(first_prefix)) width - visibleWidth(first_prefix) else 1;

            if (std.mem.startsWith(u8, trimLeftBytes(content, " \t"), "```")) {
                const consumed = try self.renderListCode(allocator, lines, index, content, item_width, first_prefix, continuation_prefix);
                defer freeOwnedLines(allocator, consumed.lines);
                for (consumed.lines) |rendered| try output.append(allocator, try allocator.dupe(u8, rendered));
                index = consumed.next_index;
                continue;
            }

            if (std.mem.startsWith(u8, trimLeftBytes(content, " \t"), ">")) {
                const quote_text = stripBlockquoteMarker(trimLeftBytes(content, " \t"));
                const quote_lines = [_][]const u8{quote_text};
                const rendered_quote = try self.renderQuoteLines(allocator, quote_lines[0..], item_width);
                defer freeOwnedLines(allocator, rendered_quote);
                for (rendered_quote, 0..) |quote_line, quote_index| {
                    const prefix = if (quote_index == 0) first_prefix else continuation_prefix;
                    try output.append(allocator, try std.mem.concat(allocator, u8, &.{ prefix, quote_line }));
                }
                index += 1;
                continue;
            }

            const ctx = try self.makeInlineStyleContext(allocator, style_kind);
            defer ctx.deinit(allocator);
            const rendered_content = try self.renderInlineText(allocator, content, ctx);
            defer allocator.free(rendered_content);
            const wrapped = try wrapTextWithAnsi(allocator, rendered_content, item_width);
            defer freeOwnedLines(allocator, wrapped);
            if (wrapped.len == 0) {
                try output.append(allocator, try allocator.dupe(u8, first_prefix));
            } else {
                for (wrapped, 0..) |wrapped_line, wrapped_index| {
                    const prefix = if (wrapped_index == 0) first_prefix else continuation_prefix;
                    try output.append(allocator, try std.mem.concat(allocator, u8, &.{ prefix, wrapped_line }));
                }
            }
            index += 1;
        }

        return output.toOwnedSlice(allocator);
    }

    fn renderListCode(
        self: *Markdown,
        allocator: std.mem.Allocator,
        lines: []const []const u8,
        start: usize,
        first_content: []const u8,
        item_width: usize,
        first_prefix: []const u8,
        continuation_prefix: []const u8,
    ) !struct { lines: [][]u8, next_index: usize } {
        var output: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, output.items);

        const opening = std.mem.trim(u8, first_content, " \t");
        const opening_wrapped = try wrapTextWithAnsi(allocator, opening, item_width);
        defer freeOwnedLines(allocator, opening_wrapped);
        for (opening_wrapped, 0..) |line, line_index| {
            const prefix = if (line_index == 0) first_prefix else continuation_prefix;
            try output.append(allocator, try std.mem.concat(allocator, u8, &.{ prefix, line }));
        }

        var index = start + 1;
        while (index < lines.len) : (index += 1) {
            const stripped = stripContinuationIndent(lines[index]);
            const trimmed = std.mem.trim(u8, stripped, " \t");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                try output.append(allocator, try std.mem.concat(allocator, u8, &.{ continuation_prefix, "```" }));
                index += 1;
                break;
            }

            const styled = try self.theme.code_block.apply(allocator, stripped);
            defer allocator.free(styled);
            const code_line = try std.mem.concat(allocator, u8, &.{ self.theme.code_block_indent, styled });
            defer allocator.free(code_line);
            const wrapped = try wrapTextWithAnsi(allocator, code_line, item_width);
            defer freeOwnedLines(allocator, wrapped);
            for (wrapped) |line| try output.append(allocator, try std.mem.concat(allocator, u8, &.{ continuation_prefix, line }));
        }

        return .{ .lines = try output.toOwnedSlice(allocator), .next_index = index };
    }

    fn renderQuoteLines(self: *Markdown, allocator: std.mem.Allocator, quote_lines: []const []const u8, width: usize) anyerror![][]u8 {
        var inner: std.ArrayList([]const u8) = .empty;
        defer inner.deinit(allocator);
        for (quote_lines) |line| try inner.append(allocator, stripBlockquoteMarker(line));

        const joined = try joinLinesWith(allocator, inner.items, "\n");
        defer allocator.free(joined);
        const quote_content_width = if (width > 2) width - 2 else 1;
        const rendered_inner = try self.renderBlocks(allocator, joined, quote_content_width, .none);
        defer freeOwnedLines(allocator, rendered_inner);

        var result: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, result.items);
        const quote_ctx = try self.makeInlineStyleContext(allocator, .quote);
        defer quote_ctx.deinit(allocator);
        const border = try self.theme.quote_border.apply(allocator, "│ ");
        defer allocator.free(border);

        var end = rendered_inner.len;
        while (end > 0 and rendered_inner[end - 1].len == 0) end -= 1;
        const reset_with_prefix = try std.mem.concat(allocator, u8, &.{ RESET, quote_ctx.style_prefix });
        defer allocator.free(reset_with_prefix);
        for (rendered_inner[0..end]) |inner_line| {
            const restored = try replaceAll(allocator, inner_line, RESET, reset_with_prefix);
            defer allocator.free(restored);
            const styled = try self.applyStyleKind(allocator, .quote, restored);
            defer allocator.free(styled);
            const wrapped = try wrapTextWithAnsi(allocator, styled, quote_content_width);
            defer freeOwnedLines(allocator, wrapped);
            for (wrapped) |wrapped_line| try result.append(allocator, try std.mem.concat(allocator, u8, &.{ border, wrapped_line }));
        }

        return result.toOwnedSlice(allocator);
    }

    fn renderTableLines(self: *Markdown, allocator: std.mem.Allocator, table_source: []const []const u8, available_width: usize, style_kind: InlineStyleKind) ![][]u8 {
        const header = try splitTableRow(allocator, table_source[0]);
        defer freeOwnedLines(allocator, header);
        if (header.len == 0) return allocator.alloc([]u8, 0);
        const num_cols = header.len;

        var rows: std.ArrayList([][]u8) = .empty;
        defer {
            for (rows.items) |row| freeOwnedLines(allocator, row);
            rows.deinit(allocator);
        }
        for (table_source[2..]) |row_line| {
            const row = try splitTableRow(allocator, row_line);
            errdefer freeOwnedLines(allocator, row);
            try rows.append(allocator, row);
        }

        const border_overhead = 3 * num_cols + 1;
        if (available_width <= border_overhead or available_width - border_overhead < num_cols) {
            const raw = try joinLinesWith(allocator, table_source, "\n");
            defer allocator.free(raw);
            return wrapTextWithAnsi(allocator, raw, available_width);
        }
        const available_for_cells = available_width - border_overhead;

        var natural_widths = try allocator.alloc(usize, num_cols);
        defer allocator.free(natural_widths);
        var min_word_widths = try allocator.alloc(usize, num_cols);
        defer allocator.free(min_word_widths);
        @memset(natural_widths, 0);
        @memset(min_word_widths, 1);

        const ctx = try self.makeInlineStyleContext(allocator, style_kind);
        defer ctx.deinit(allocator);

        for (header, 0..) |cell, i| try self.measureTableCell(allocator, cell, ctx, &natural_widths[i], &min_word_widths[i]);
        for (rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < num_cols) try self.measureTableCell(allocator, cell, ctx, &natural_widths[i], &min_word_widths[i]);
            }
        }

        var min_widths = try allocator.dupe(usize, min_word_widths);
        defer allocator.free(min_widths);
        var min_cells_width = sumUsize(min_widths);
        if (min_cells_width > available_for_cells) {
            @memset(min_widths, 1);
            const remaining = available_for_cells - num_cols;
            if (remaining > 0) {
                var total_weight: usize = 0;
                for (min_word_widths) |w| total_weight += w -| 1;
                var allocated: usize = 0;
                for (min_widths, 0..) |*w, i| {
                    const weight = min_word_widths[i] -| 1;
                    const growth = if (total_weight > 0) (weight * remaining) / total_weight else 0;
                    w.* += growth;
                    allocated += growth;
                }
                var leftover = remaining - allocated;
                var i: usize = 0;
                while (leftover > 0 and i < num_cols) : (i += 1) {
                    min_widths[i] += 1;
                    leftover -= 1;
                }
            }
            min_cells_width = sumUsize(min_widths);
        }

        const column_widths = try allocator.alloc(usize, num_cols);
        defer allocator.free(column_widths);
        const total_natural = sumUsize(natural_widths) + border_overhead;
        if (total_natural <= available_width) {
            for (column_widths, 0..) |*w, i| w.* = @max(natural_widths[i], min_widths[i]);
        } else {
            var total_grow: usize = 0;
            for (natural_widths, 0..) |w, i| total_grow += w -| min_widths[i];
            const extra = available_for_cells -| min_cells_width;
            var allocated: usize = 0;
            for (column_widths, 0..) |*w, i| {
                const delta = natural_widths[i] -| min_widths[i];
                const grow = if (total_grow > 0) (delta * extra) / total_grow else 0;
                w.* = min_widths[i] + grow;
                allocated += w.*;
            }
            var remaining = available_for_cells -| allocated;
            while (remaining > 0) {
                var grew = false;
                for (column_widths, 0..) |*w, i| {
                    if (remaining == 0) break;
                    if (w.* < natural_widths[i]) {
                        w.* += 1;
                        remaining -= 1;
                        grew = true;
                    }
                }
                if (!grew) break;
            }
        }

        var result: std.ArrayList([]u8) = .empty;
        errdefer freeOwnedLines(allocator, result.items);
        try result.append(allocator, try renderTableBorder(allocator, "┌", "┬", "┐", column_widths));
        try self.appendTableRow(allocator, &result, header, column_widths, ctx, true);
        try result.append(allocator, try renderTableBorder(allocator, "├", "┼", "┤", column_widths));
        for (rows.items, 0..) |row, row_index| {
            try self.appendTableRow(allocator, &result, row, column_widths, ctx, false);
            if (row_index < rows.items.len - 1) try result.append(allocator, try renderTableBorder(allocator, "├", "┼", "┤", column_widths));
        }
        try result.append(allocator, try renderTableBorder(allocator, "└", "┴", "┘", column_widths));
        return result.toOwnedSlice(allocator);
    }

    fn measureTableCell(self: *Markdown, allocator: std.mem.Allocator, cell: []const u8, ctx: InlineStyleContext, natural: *usize, min_word: *usize) !void {
        const rendered = try self.renderInlineText(allocator, cell, ctx);
        defer allocator.free(rendered);
        natural.* = @max(natural.*, visibleWidth(rendered));
        min_word.* = @max(min_word.*, getLongestWordWidth(rendered, 30));
    }

    fn appendTableRow(
        self: *Markdown,
        allocator: std.mem.Allocator,
        result: *std.ArrayList([]u8),
        cells: [][]u8,
        column_widths: []const usize,
        ctx: InlineStyleContext,
        header: bool,
    ) !void {
        var wrapped_cells = try allocator.alloc([][]u8, column_widths.len);
        var initialized: usize = 0;
        defer {
            for (wrapped_cells[0..initialized]) |cell_lines| freeOwnedLines(allocator, cell_lines);
            allocator.free(wrapped_cells);
        }

        var max_lines: usize = 1;
        for (column_widths, 0..) |width, i| {
            const cell_text = if (i < cells.len) cells[i] else "";
            const rendered = try self.renderInlineText(allocator, cell_text, ctx);
            defer allocator.free(rendered);
            wrapped_cells[i] = try wrapTextWithAnsi(allocator, rendered, width);
            initialized += 1;
            max_lines = @max(max_lines, wrapped_cells[i].len);
        }

        var line_index: usize = 0;
        while (line_index < max_lines) : (line_index += 1) {
            var line: std.ArrayList(u8) = .empty;
            errdefer line.deinit(allocator);
            try line.appendSlice(allocator, "│ ");
            for (wrapped_cells, 0..) |cell_lines, col| {
                const text = if (line_index < cell_lines.len) cell_lines[line_index] else "";
                const padded = try padToWidth(allocator, text, column_widths[col]);
                defer allocator.free(padded);
                if (header) {
                    const styled = try self.theme.bold.apply(allocator, padded);
                    defer allocator.free(styled);
                    try line.appendSlice(allocator, styled);
                } else {
                    try line.appendSlice(allocator, padded);
                }
                if (col + 1 < wrapped_cells.len) try line.appendSlice(allocator, " │ ") else try line.appendSlice(allocator, " │");
            }
            try result.append(allocator, try line.toOwnedSlice(allocator));
        }
    }

    fn renderInlineText(self: *Markdown, allocator: std.mem.Allocator, text: []const u8, ctx: InlineStyleContext) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var index: usize = 0;
        while (index < text.len) {
            if (std.mem.startsWith(u8, text[index..], "`")) {
                if (std.mem.indexOfScalarPos(u8, text, index + 1, '`')) |end| {
                    const styled = try self.theme.code.apply(allocator, text[index + 1 .. end]);
                    defer allocator.free(styled);
                    try output.appendSlice(allocator, styled);
                    try output.appendSlice(allocator, ctx.style_prefix);
                    index = end + 1;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, text[index..], "**")) {
                if (std.mem.indexOfPos(u8, text, index + 2, "**")) |end| {
                    const inner = try self.renderInlineText(allocator, text[index + 2 .. end], ctx);
                    defer allocator.free(inner);
                    const styled = try self.theme.bold.apply(allocator, inner);
                    defer allocator.free(styled);
                    try output.appendSlice(allocator, styled);
                    try output.appendSlice(allocator, ctx.style_prefix);
                    index = end + 2;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, text[index..], "~~")) {
                if (strictDelEnd(text, index + 2)) |end| {
                    const inner = try self.renderInlineText(allocator, text[index + 2 .. end], ctx);
                    defer allocator.free(inner);
                    const styled = try self.theme.strikethrough.apply(allocator, inner);
                    defer allocator.free(styled);
                    try output.appendSlice(allocator, styled);
                    try output.appendSlice(allocator, ctx.style_prefix);
                    index = end + 2;
                    continue;
                }
            }
            if (text[index] == '[') {
                if (parseInlineLink(text, index)) |link| {
                    const link_text = try self.renderInlineText(allocator, link.text, ctx);
                    defer allocator.free(link_text);
                    try self.appendRenderedLink(allocator, &output, link_text, link.raw_text, link.href, ctx.style_prefix);
                    index = link.end;
                    continue;
                }
            }
            if (std.mem.startsWith(u8, text[index..], "http://") or std.mem.startsWith(u8, text[index..], "https://")) {
                const end = scanBareUrl(text, index);
                const url = text[index..end];
                try self.appendRenderedLink(allocator, &output, url, url, url, ctx.style_prefix);
                index = end;
                continue;
            }
            if (scanEmail(text, index)) |email_end| {
                const email = text[index..email_end];
                const href = try std.mem.concat(allocator, u8, &.{ "mailto:", email });
                defer allocator.free(href);
                try self.appendRenderedLink(allocator, &output, email, email, href, ctx.style_prefix);
                index = email_end;
                continue;
            }
            if (text[index] == '*') {
                if (index + 1 < text.len and text[index + 1] != '*') {
                    if (std.mem.indexOfScalarPos(u8, text, index + 1, '*')) |end| {
                        const inner = try self.renderInlineText(allocator, text[index + 1 .. end], ctx);
                        defer allocator.free(inner);
                        const styled = try self.theme.italic.apply(allocator, inner);
                        defer allocator.free(styled);
                        try output.appendSlice(allocator, styled);
                        try output.appendSlice(allocator, ctx.style_prefix);
                        index = end + 1;
                        continue;
                    }
                }
            }

            const next = nextInlineSpecial(text, index + 1);
            const styled = try self.applyTextWithNewlines(allocator, text[index..next], ctx.kind);
            defer allocator.free(styled);
            try output.appendSlice(allocator, styled);
            index = next;
        }

        while (ctx.style_prefix.len > 0 and std.mem.endsWith(u8, output.items, ctx.style_prefix)) {
            output.shrinkRetainingCapacity(output.items.len - ctx.style_prefix.len);
        }
        return output.toOwnedSlice(allocator);
    }

    fn appendRenderedLink(
        self: *Markdown,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(u8),
        link_text: []const u8,
        raw_text: []const u8,
        href: []const u8,
        style_prefix: []const u8,
    ) !void {
        const underlined = try self.theme.underline.apply(allocator, link_text);
        defer allocator.free(underlined);
        const styled_link = try self.theme.link.apply(allocator, underlined);
        defer allocator.free(styled_link);

        if (terminal_image.getCapabilities().hyperlinks) {
            const linked = try terminal_image.hyperlink(allocator, styled_link, href);
            defer allocator.free(linked);
            try output.appendSlice(allocator, linked);
            try output.appendSlice(allocator, style_prefix);
            return;
        }

        const href_for_comparison = if (std.mem.startsWith(u8, href, "mailto:")) href[7..] else href;
        try output.appendSlice(allocator, styled_link);
        if (!std.mem.eql(u8, raw_text, href) and !std.mem.eql(u8, raw_text, href_for_comparison)) {
            const url_text = try std.fmt.allocPrint(allocator, " ({s})", .{href});
            defer allocator.free(url_text);
            const styled_url = try self.theme.link_url.apply(allocator, url_text);
            defer allocator.free(styled_url);
            try output.appendSlice(allocator, styled_url);
        }
        try output.appendSlice(allocator, style_prefix);
    }

    fn makeInlineStyleContext(self: *Markdown, allocator: std.mem.Allocator, kind: InlineStyleKind) !InlineStyleContext {
        return .{ .kind = kind, .style_prefix = try self.getStylePrefix(allocator, kind) };
    }

    fn applyTextWithNewlines(self: *Markdown, allocator: std.mem.Allocator, text: []const u8, kind: InlineStyleKind) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var start: usize = 0;
        while (true) {
            const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
            const styled = try self.applyStyleKind(allocator, kind, text[start..newline]);
            defer allocator.free(styled);
            try output.appendSlice(allocator, styled);
            if (newline == text.len) break;
            try output.append(allocator, '\n');
            start = newline + 1;
        }
        return output.toOwnedSlice(allocator);
    }

    fn applyStyleKind(self: *Markdown, allocator: std.mem.Allocator, kind: InlineStyleKind, text: []const u8) ![]u8 {
        switch (kind) {
            .default => return self.applyDefaultStyle(allocator, text),
            .none => return allocator.dupe(u8, text),
            .heading_one => {
                const underlined = try self.theme.underline.apply(allocator, text);
                defer allocator.free(underlined);
                const bold = try self.theme.bold.apply(allocator, underlined);
                defer allocator.free(bold);
                return self.theme.heading.apply(allocator, bold);
            },
            .heading => {
                const bold = try self.theme.bold.apply(allocator, text);
                defer allocator.free(bold);
                return self.theme.heading.apply(allocator, bold);
            },
            .quote => {
                const italic = try self.theme.italic.apply(allocator, text);
                defer allocator.free(italic);
                return self.theme.quote.apply(allocator, italic);
            },
        }
    }

    fn applyDefaultStyle(self: *Markdown, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        const style = self.default_text_style orelse return allocator.dupe(u8, text);
        var current = try allocator.dupe(u8, text);
        errdefer allocator.free(current);
        if (style.color) |color| try replaceStyled(allocator, &current, color);
        if (style.bold) try replaceStyled(allocator, &current, self.theme.bold);
        if (style.italic) try replaceStyled(allocator, &current, self.theme.italic);
        if (style.strikethrough) try replaceStyled(allocator, &current, self.theme.strikethrough);
        if (style.underline) try replaceStyled(allocator, &current, self.theme.underline);
        return current;
    }

    fn getStylePrefix(self: *Markdown, allocator: std.mem.Allocator, kind: InlineStyleKind) ![]u8 {
        const styled = try self.applyStyleKind(allocator, kind, "\x00");
        defer allocator.free(styled);
        const sentinel = std.mem.indexOfScalar(u8, styled, 0) orelse return allocator.dupe(u8, "");
        return allocator.dupe(u8, styled[0..sentinel]);
    }

    fn applyMarkdownBackground(self: *Markdown, allocator: std.mem.Allocator, line: []const u8, width: usize) ![]u8 {
        if (self.default_text_style) |style| {
            if (style.bg_color) |bg| return applyBackgroundStyleToLine(allocator, line, width, bg);
        }
        return padToWidth(allocator, line, width);
    }

    fn replaceCache(self: *Markdown, lines: [][]u8, width: usize) void {
        self.clearCache();
        self.cached_lines = lines;
        self.cached_width = width;
    }

    fn clearCache(self: *Markdown) void {
        if (self.cached_lines) |lines| freeOwnedLines(self.allocator, lines);
        self.cached_lines = null;
        self.cached_width = null;
    }
};

pub const LoaderIndicatorOptions = struct {
    frames: ?[]const []const u8 = null,
    interval_ms: ?u64 = null,
};

const DEFAULT_LOADER_FRAMES = [_][]const u8{
    "\u{280b}",
    "\u{2819}",
    "\u{2839}",
    "\u{2838}",
    "\u{283c}",
    "\u{2834}",
    "\u{2826}",
    "\u{2827}",
    "\u{2807}",
    "\u{280f}",
};
const DEFAULT_LOADER_INTERVAL_MS: u64 = 80;

pub const Loader = struct {
    allocator: std.mem.Allocator,
    text: Text,
    frames: [][]u8,
    interval_ms: u64 = DEFAULT_LOADER_INTERVAL_MS,
    current_frame: usize = 0,
    running: bool = false,
    render_indicator_verbatim: bool = false,
    requester: ?RenderRequester = null,
    spinner_color_fn: TextStyle = .{},
    message_color_fn: TextStyle = .{},
    message: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        requester: ?RenderRequester,
        spinner_color_fn: TextStyle,
        message_color_fn: TextStyle,
        message: []const u8,
        indicator: ?LoaderIndicatorOptions,
    ) !Loader {
        var moved = false;
        var text = try Text.init(allocator, "", 1, 0, null);
        errdefer if (!moved) text.deinit();
        const frames = try cloneFrames(allocator, DEFAULT_LOADER_FRAMES[0..]);
        errdefer if (!moved) freeFrames(allocator, frames);
        const owned_message = try allocator.dupe(u8, message);
        errdefer if (!moved) allocator.free(owned_message);

        var loader = Loader{
            .allocator = allocator,
            .text = text,
            .frames = frames,
            .requester = requester,
            .spinner_color_fn = spinner_color_fn,
            .message_color_fn = message_color_fn,
            .message = owned_message,
        };
        moved = true;
        errdefer loader.deinit();
        try loader.setIndicator(indicator);
        return loader;
    }

    pub fn deinit(self: *Loader) void {
        self.text.deinit();
        freeFrames(self.allocator, self.frames);
        self.allocator.free(self.message);
    }

    pub fn render(self: *const Loader, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        const rendered_text = try self.text.render(allocator, width);
        defer freeOwnedLines(allocator, rendered_text);

        var result = try allocator.alloc([]u8, rendered_text.len + 1);
        var initialized: usize = 0;
        errdefer {
            for (result[0..initialized]) |line| allocator.free(line);
            allocator.free(result);
        }
        result[0] = try allocator.dupe(u8, "");
        initialized += 1;
        for (rendered_text, 0..) |line, index| {
            result[index + 1] = try allocator.dupe(u8, line);
            initialized += 1;
        }
        return result;
    }

    pub fn start(self: *Loader) !void {
        self.running = true;
        try self.updateDisplay();
    }

    pub fn stop(self: *Loader) void {
        self.running = false;
    }

    pub fn animationRunning(self: *const Loader) bool {
        return self.running and self.frames.len > 1;
    }

    pub fn setMessage(self: *Loader, message: []const u8) !void {
        const next = try self.allocator.dupe(u8, message);
        self.allocator.free(self.message);
        self.message = next;
        try self.updateDisplay();
    }

    pub fn setIndicator(self: *Loader, indicator: ?LoaderIndicatorOptions) !void {
        const next_frames = if (indicator) |options|
            try cloneFrames(self.allocator, options.frames orelse DEFAULT_LOADER_FRAMES[0..])
        else
            try cloneFrames(self.allocator, DEFAULT_LOADER_FRAMES[0..]);
        freeFrames(self.allocator, self.frames);
        self.frames = next_frames;
        self.interval_ms = if (indicator) |options|
            if (options.interval_ms) |interval| if (interval > 0) interval else DEFAULT_LOADER_INTERVAL_MS else DEFAULT_LOADER_INTERVAL_MS
        else
            DEFAULT_LOADER_INTERVAL_MS;
        self.current_frame = 0;
        self.render_indicator_verbatim = indicator != null;
        try self.start();
    }

    pub fn advanceFrame(self: *Loader) !void {
        if (!self.animationRunning()) return;
        self.current_frame = (self.current_frame + 1) % self.frames.len;
        try self.updateDisplay();
    }

    fn updateDisplay(self: *Loader) !void {
        const frame = if (self.current_frame < self.frames.len) self.frames[self.current_frame] else "";
        const rendered_frame = if (self.render_indicator_verbatim)
            try self.allocator.dupe(u8, frame)
        else
            try self.spinner_color_fn.apply(self.allocator, frame);
        defer self.allocator.free(rendered_frame);

        const rendered_message = try self.message_color_fn.apply(self.allocator, self.message);
        defer self.allocator.free(rendered_message);

        const display_text = if (frame.len > 0)
            try std.mem.concat(self.allocator, u8, &.{ rendered_frame, " ", rendered_message })
        else
            try self.allocator.dupe(u8, rendered_message);
        defer self.allocator.free(display_text);

        try self.text.setText(display_text);
        if (self.requester) |requester| requester.requestRender();
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

pub const AbortSignal = struct {
    aborted: bool = false,

    pub fn abort(self: *AbortSignal) void {
        self.aborted = true;
    }

    pub fn isAborted(self: *const AbortSignal) bool {
        return self.aborted;
    }
};

pub const CancellableLoader = struct {
    loader: Loader,
    signal: AbortSignal = .{},
    on_abort: ?VoidCallback = null,

    pub fn init(
        allocator: std.mem.Allocator,
        requester: ?RenderRequester,
        spinner_color_fn: TextStyle,
        message_color_fn: TextStyle,
        message: []const u8,
        indicator: ?LoaderIndicatorOptions,
    ) !CancellableLoader {
        return .{
            .loader = try Loader.init(allocator, requester, spinner_color_fn, message_color_fn, message, indicator),
        };
    }

    pub fn deinit(self: *CancellableLoader) void {
        self.loader.deinit();
    }

    pub fn render(self: *const CancellableLoader, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        return self.loader.render(allocator, width);
    }

    pub fn start(self: *CancellableLoader) !void {
        try self.loader.start();
    }

    pub fn stop(self: *CancellableLoader) void {
        self.loader.stop();
    }

    pub fn dispose(self: *CancellableLoader) void {
        self.stop();
    }

    pub fn handleInput(self: *CancellableLoader, allocator: std.mem.Allocator, data: []const u8) !void {
        const manager = try keybindings.getKeybindings(allocator);
        if (manager.matches(data, "tui.select.cancel")) {
            self.signal.abort();
            if (self.on_abort) |callback| callback.call();
        }
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

fn replaceStyled(allocator: std.mem.Allocator, current: *[]u8, style: TextStyle) !void {
    const next = try style.apply(allocator, current.*);
    allocator.free(current.*);
    current.* = next;
}

fn splitBorrowedLines(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var start: usize = 0;
    while (true) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        var line = text[start..newline];
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        try lines.append(allocator, line);
        if (newline == text.len) break;
        start = newline + 1;
    }
    return lines.toOwnedSlice(allocator);
}

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r\n").len == 0;
}

fn trimLeftBytes(input: []const u8, values: []const u8) []const u8 {
    var start: usize = 0;
    while (start < input.len and std.mem.indexOfScalar(u8, values, input[start]) != null) : (start += 1) {}
    return input[start..];
}

fn trimRightBytes(input: []const u8, values: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and std.mem.indexOfScalar(u8, values, input[end - 1]) != null) : (end -= 1) {}
    return input[0..end];
}

const ParsedHeading = struct {
    level: usize,
    text: []const u8,
};

fn parseHeading(line: []const u8) ?ParsedHeading {
    var index: usize = 0;
    var leading: usize = 0;
    while (index < line.len and line[index] == ' ' and leading < 4) : ({
        index += 1;
        leading += 1;
    }) {}
    if (leading > 3) return null;
    var level: usize = 0;
    while (index + level < line.len and line[index + level] == '#' and level < 6) : (level += 1) {}
    if (level == 0) return null;
    if (index + level >= line.len or line[index + level] != ' ') return null;
    return .{ .level = level, .text = std.mem.trim(u8, line[index + level + 1 ..], " \t") };
}

fn blockKindAt(lines: []const []const u8, index: usize) MarkdownBlockKind {
    if (index >= lines.len) return .space;
    const line = lines[index];
    if (isBlankLine(line)) return .space;
    if (parseHeading(line) != null) return .heading;
    if (isFenceLine(line)) return .code;
    if (parseListMarker(line) != null) return .list;
    if (isBlockquoteStart(line)) return .blockquote;
    if (isHrLine(line)) return .hr;
    if (index + 1 < lines.len and isTableRow(line) and isTableDelimiterLine(lines[index + 1])) return .table;
    return .paragraph;
}

fn addsSpacingBeforeNext(current: MarkdownBlockKind, next: MarkdownBlockKind) bool {
    return switch (current) {
        .heading, .code, .table, .blockquote, .hr => next != .space,
        .paragraph => next != .space and next != .list,
        else => false,
    };
}

fn appendSingleBlank(allocator: std.mem.Allocator, output: *std.ArrayList([]u8)) !void {
    if (output.items.len == 0 or output.items[output.items.len - 1].len != 0) {
        try output.append(allocator, try allocator.dupe(u8, ""));
    }
}

fn isFenceLine(line: []const u8) bool {
    return std.mem.startsWith(u8, trimLeftBytes(line, " \t"), "```");
}

fn isHrLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    const first = trimmed[0];
    if (first != '-' and first != '*' and first != '_') return false;
    for (trimmed) |byte| {
        if (byte != first) return false;
    }
    return true;
}

fn isBlockquoteStart(line: []const u8) bool {
    const trimmed = trimLeftBytes(line, " \t");
    return std.mem.startsWith(u8, trimmed, ">");
}

fn continuesBlockquote(line: []const u8) bool {
    if (isBlankLine(line)) return false;
    const kind = blockKindAt(&.{line}, 0);
    return kind == .paragraph or kind == .blockquote or kind == .list;
}

fn stripBlockquoteMarker(line: []const u8) []const u8 {
    const trimmed = trimLeftBytes(line, " \t");
    if (!std.mem.startsWith(u8, trimmed, ">")) return trimmed;
    var rest = trimmed[1..];
    if (std.mem.startsWith(u8, rest, " ")) rest = rest[1..];
    return rest;
}

fn parseListMarker(line: []const u8) ?ListMarker {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') : (index += 1) {}
    if (index >= line.len) return null;
    const indent = index;
    const depth = indent / 2;

    if ((line[index] == '-' or line[index] == '*' or line[index] == '+') and index + 1 < line.len and std.ascii.isWhitespace(line[index + 1])) {
        return .{
            .indent = indent,
            .depth = depth,
            .ordered = false,
            .number = 0,
            .marker_len = index + 2,
            .delimiter = line[index],
        };
    }

    if (!std.ascii.isDigit(line[index])) return null;
    var end = index;
    var value: usize = 0;
    var digits: usize = 0;
    while (end < line.len and std.ascii.isDigit(line[end]) and digits < 9) : ({
        end += 1;
        digits += 1;
    }) {
        value = value * 10 + (line[end] - '0');
    }
    if (digits == 0 or end >= line.len or (line[end] != '.' and line[end] != ')')) return null;
    if (end + 1 >= line.len or !std.ascii.isWhitespace(line[end + 1])) return null;
    return .{
        .indent = indent,
        .depth = depth,
        .ordered = true,
        .number = value,
        .marker_len = end + 2,
        .delimiter = line[end],
    };
}

fn leadingSpaceCount(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn stripContinuationIndent(line: []const u8) []const u8 {
    var index: usize = 0;
    var removed: usize = 0;
    while (index < line.len and line[index] == ' ' and removed < 2) : ({
        index += 1;
        removed += 1;
    }) {}
    return line[index..];
}

fn isTableRow(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn isTableDelimiterLine(line: []const u8) bool {
    var cells = std.mem.splitScalar(u8, std.mem.trim(u8, line, " \t|"), '|');
    var count: usize = 0;
    while (cells.next()) |raw_cell| {
        const cell = std.mem.trim(u8, raw_cell, " \t");
        if (cell.len == 0) return false;
        var hyphens: usize = 0;
        for (cell) |byte| {
            if (byte == '-') {
                hyphens += 1;
            } else if (byte != ':') {
                return false;
            }
        }
        if (hyphens < 3) return false;
        count += 1;
    }
    return count > 0;
}

fn splitTableRow(allocator: std.mem.Allocator, line: []const u8) ![][]u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    const without_left = if (std.mem.startsWith(u8, trimmed, "|")) trimmed[1..] else trimmed;
    const without_edges = if (std.mem.endsWith(u8, without_left, "|")) without_left[0 .. without_left.len - 1] else without_left;
    var cells: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedLines(allocator, cells.items);
    var parts = std.mem.splitScalar(u8, without_edges, '|');
    while (parts.next()) |part| {
        try cells.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, part, " \t")));
    }
    return cells.toOwnedSlice(allocator);
}

fn repeatedSlice(allocator: std.mem.Allocator, slice: []const u8, count: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < count) : (index += 1) try output.appendSlice(allocator, slice);
    return output.toOwnedSlice(allocator);
}

fn prefixedSpacesConcat(allocator: std.mem.Allocator, spaces: usize, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try appendSpaces(allocator, &output, spaces);
    try output.appendSlice(allocator, text);
    return output.toOwnedSlice(allocator);
}

fn joinLinesWith(allocator: std.mem.Allocator, lines: []const []const u8, separator: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (lines, 0..) |line, index| {
        if (index > 0) try output.appendSlice(allocator, separator);
        try output.appendSlice(allocator, line);
    }
    return output.toOwnedSlice(allocator);
}

fn replaceAll(allocator: std.mem.Allocator, text: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, text);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, needle)) |found| {
        try output.appendSlice(allocator, text[index..found]);
        try output.appendSlice(allocator, replacement);
        index = found + needle.len;
    }
    try output.appendSlice(allocator, text[index..]);
    return output.toOwnedSlice(allocator);
}

fn renderTableBorder(allocator: std.mem.Allocator, left: []const u8, mid: []const u8, right: []const u8, widths: []const usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, left);
    try output.appendSlice(allocator, "─");
    for (widths, 0..) |width, index| {
        var i: usize = 0;
        while (i < width) : (i += 1) try output.appendSlice(allocator, "─");
        if (index + 1 < widths.len) {
            try output.appendSlice(allocator, "─");
            try output.appendSlice(allocator, mid);
            try output.appendSlice(allocator, "─");
        }
    }
    try output.appendSlice(allocator, "─");
    try output.appendSlice(allocator, right);
    return output.toOwnedSlice(allocator);
}

fn sumUsize(values: []const usize) usize {
    var sum: usize = 0;
    for (values) |value| sum += value;
    return sum;
}

fn getLongestWordWidth(text: []const u8, max_width: usize) usize {
    var longest: usize = 0;
    var start: usize = 0;
    while (start < text.len) {
        while (start < text.len and std.ascii.isWhitespace(text[start])) : (start += 1) {}
        const end = blk: {
            var index = start;
            while (index < text.len and !std.ascii.isWhitespace(text[index])) : (index += 1) {}
            break :blk index;
        };
        if (end > start) longest = @max(longest, visibleWidth(text[start..end]));
        start = end + @intFromBool(end < text.len);
    }
    return @min(longest, max_width);
}

const InlineLink = struct {
    text: []const u8,
    raw_text: []const u8,
    href: []const u8,
    end: usize,
};

fn parseInlineLink(text: []const u8, start: usize) ?InlineLink {
    const close_bracket = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;
    const close_paren = std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')') orelse return null;
    return .{
        .text = text[start + 1 .. close_bracket],
        .raw_text = text[start + 1 .. close_bracket],
        .href = text[close_bracket + 2 .. close_paren],
        .end = close_paren + 1,
    };
}

fn strictDelEnd(text: []const u8, start: usize) ?usize {
    if (start >= text.len or std.ascii.isWhitespace(text[start]) or text[start] == '~') return null;
    var index = start;
    while (std.mem.indexOfPos(u8, text, index, "~~")) |end| {
        if (end > start and !std.ascii.isWhitespace(text[end - 1]) and text[end - 1] != '~') return end;
        index = end + 2;
    }
    return null;
}

fn scanBareUrl(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len) : (end += 1) {
        const byte = text[end];
        if (std.ascii.isWhitespace(byte) or byte == '|' or byte == ')' or byte == ']') break;
    }
    while (end > start and std.mem.indexOfScalar(u8, ".,;:!?", text[end - 1]) != null) end -= 1;
    return end;
}

fn scanEmail(text: []const u8, start: usize) ?usize {
    if (start > 0 and isEmailChar(text[start - 1])) return null;
    if (!isEmailLocalStart(text[start])) return null;
    var end = start;
    var at_seen = false;
    var dot_after_at = false;
    while (end < text.len and isEmailChar(text[end])) : (end += 1) {
        if (text[end] == '@') at_seen = true;
        if (at_seen and text[end] == '.') dot_after_at = true;
    }
    if (!at_seen or !dot_after_at or end == start) return null;
    if (end < text.len and isEmailChar(text[end])) return null;
    return end;
}

fn isEmailLocalStart(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte);
}

fn isEmailChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '@' or byte == '.' or byte == '_' or byte == '%' or byte == '+' or byte == '-';
}

fn nextInlineSpecial(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        if (std.mem.startsWith(u8, text[index..], "`") or
            std.mem.startsWith(u8, text[index..], "**") or
            std.mem.startsWith(u8, text[index..], "~~") or
            std.mem.startsWith(u8, text[index..], "http://") or
            std.mem.startsWith(u8, text[index..], "https://") or
            text[index] == '[' or
            text[index] == '*')
        {
            return index;
        }
        if (scanEmail(text, index) != null) return index;
    }
    return text.len;
}

fn cloneFrames(allocator: std.mem.Allocator, frames: []const []const u8) ![][]u8 {
    var result = try allocator.alloc([]u8, frames.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |frame| allocator.free(frame);
        allocator.free(result);
    }
    for (frames, 0..) |frame, index| {
        result[index] = try allocator.dupe(u8, frame);
        initialized += 1;
    }
    return result;
}

fn freeFrames(allocator: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |frame| allocator.free(frame);
    allocator.free(frames);
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

fn cloneOwnedLines(allocator: std.mem.Allocator, lines: []const []const u8) ![][]u8 {
    var result = try allocator.alloc([]u8, lines.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |line| allocator.free(line);
        allocator.free(result);
    }
    for (lines, 0..) |line, index| {
        result[index] = try allocator.dupe(u8, line);
        initialized += 1;
    }
    return result;
}

fn ceilDiv(numerator: usize, denominator: usize) usize {
    const safe_denominator = @max(@as(usize, 1), denominator);
    return if (numerator == 0) 0 else 1 + ((numerator - 1) / safe_denominator);
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

const TestRenderCounter = struct {
    count: usize = 0,

    fn request(ptr: ?*anyopaque) void {
        const self: *TestRenderCounter = @ptrCast(@alignCast(ptr.?));
        self.count += 1;
    }
};

fn bracketStyle(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "[{s}]", .{text});
}

fn parenStyle(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "({s})", .{text});
}

fn ansiBold(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[1m{s}\x1b[22m", .{text});
}

fn ansiItalic(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[3m{s}\x1b[23m", .{text});
}

fn ansiUnderline(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[4m{s}\x1b[24m", .{text});
}

fn ansiStrike(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[9m{s}\x1b[29m", .{text});
}

fn ansiCyan(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[36m{s}\x1b[39m", .{text});
}

fn ansiBlue(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[34m{s}\x1b[39m", .{text});
}

fn ansiDim(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[2m{s}\x1b[22m", .{text});
}

fn ansiYellow(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[33m{s}\x1b[39m", .{text});
}

fn ansiGreen(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[32m{s}\x1b[39m", .{text});
}

fn ansiGray(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[90m{s}\x1b[39m", .{text});
}

fn ansiMagenta(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[35m{s}\x1b[39m", .{text});
}

fn ansiBgBlue(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b[44m{s}\x1b[49m", .{text});
}

const test_markdown_theme = MarkdownTheme{
    .heading = .{ .apply_fn = ansiCyan },
    .link = .{ .apply_fn = ansiBlue },
    .link_url = .{ .apply_fn = ansiDim },
    .code = .{ .apply_fn = ansiYellow },
    .code_block = .{ .apply_fn = ansiGreen },
    .code_block_border = .{ .apply_fn = ansiDim },
    .quote = .{ .apply_fn = ansiItalic },
    .quote_border = .{ .apply_fn = ansiDim },
    .hr = .{ .apply_fn = ansiDim },
    .list_bullet = .{ .apply_fn = ansiCyan },
    .bold = .{ .apply_fn = ansiBold },
    .italic = .{ .apply_fn = ansiItalic },
    .strikethrough = .{ .apply_fn = ansiStrike },
    .underline = .{ .apply_fn = ansiUnderline },
};

fn stripAnsiAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (extractAnsiCode(text, index)) |ansi| {
            index += ansi.length;
            continue;
        }
        try output.append(allocator, text[index]);
        index += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn renderMarkdownPlain(allocator: std.mem.Allocator, markdown: *Markdown, width: usize) ![][]u8 {
    const lines = try markdown.render(allocator, width);
    defer freeRenderedLines(allocator, lines);
    var plain = try allocator.alloc([]u8, lines.len);
    var initialized: usize = 0;
    errdefer {
        for (plain[0..initialized]) |line| allocator.free(line);
        allocator.free(plain);
    }
    for (lines, 0..) |line, index| {
        const stripped = try stripAnsiAlloc(allocator, line);
        defer allocator.free(stripped);
        plain[index] = try trimEndSpacesAlloc(allocator, stripped);
        initialized += 1;
    }
    return plain;
}

fn containsLineWith(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

fn removeTableNoise(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (text) |byte| {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            else => {
                if (std.mem.indexOfScalar(u8, "│├┤┌┐└┘┬┴┼─", byte) == null) {
                    try output.append(allocator, byte);
                }
            },
        }
    }
    return output.toOwnedSlice(allocator);
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

test "Spacer renders configurable empty lines" {
    const allocator = std.testing.allocator;
    var spacer = Spacer.init(2);

    const lines = try spacer.render(allocator, 80);
    defer freeRenderedLines(allocator, lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("", lines[0]);
    try std.testing.expectEqualStrings("", lines[1]);

    spacer.setLines(0);
    const empty = try spacer.render(allocator, 80);
    defer freeRenderedLines(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Loader renders messages and advances custom indicators deterministically" {
    const allocator = std.testing.allocator;
    var counter: TestRenderCounter = .{};
    var loader = try Loader.init(
        allocator,
        .{ .ptr = &counter, .request_fn = TestRenderCounter.request },
        .{ .apply_fn = bracketStyle },
        .{ .apply_fn = parenStyle },
        "Working",
        null,
    );
    defer loader.deinit();

    try std.testing.expect(loader.animationRunning());
    try std.testing.expect(counter.count > 0);

    const lines = try loader.render(allocator, 40);
    defer freeRenderedLines(allocator, lines);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("", lines[0]);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "(Working)") != null);

    try loader.setMessage("Done");
    const custom_frames = [_][]const u8{ ">", "-" };
    try loader.setIndicator(.{ .frames = custom_frames[0..], .interval_ms = 0 });
    try std.testing.expectEqual(DEFAULT_LOADER_INTERVAL_MS, loader.interval_ms);

    const custom = try loader.render(allocator, 40);
    defer freeRenderedLines(allocator, custom);
    try std.testing.expect(std.mem.indexOf(u8, custom[1], "> (Done)") != null);
    try std.testing.expect(std.mem.indexOf(u8, custom[1], "[>") == null);

    try loader.advanceFrame();
    const advanced = try loader.render(allocator, 40);
    defer freeRenderedLines(allocator, advanced);
    try std.testing.expect(std.mem.indexOf(u8, advanced[1], "- (Done)") != null);

    loader.stop();
    const stopped_frame = loader.current_frame;
    try loader.advanceFrame();
    try std.testing.expectEqual(stopped_frame, loader.current_frame);
}

test "CancellableLoader aborts on select cancel keybinding" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    var abort_counter: TestRenderCounter = .{};
    var loader = try CancellableLoader.init(
        allocator,
        null,
        .{},
        .{},
        "Cancelling",
        .{ .frames = &.{"."} },
    );
    defer loader.deinit();
    loader.on_abort = .{ .ptr = &abort_counter, .call_fn = TestRenderCounter.request };

    try loader.handleInput(allocator, "x");
    try std.testing.expect(!loader.signal.isAborted());
    try std.testing.expectEqual(@as(usize, 0), abort_counter.count);

    try loader.handleInput(allocator, "\x1b");
    try std.testing.expect(loader.signal.isAborted());
    try std.testing.expectEqual(@as(usize, 1), abort_counter.count);

    loader.dispose();
    try std.testing.expect(!loader.loader.animationRunning());
}

test "Image falls back to styled metadata when terminal images are unavailable" {
    const allocator = std.testing.allocator;
    terminal_image.setCapabilities(.{ .images = null, .true_color = false, .hyperlinks = false });
    defer terminal_image.resetCapabilitiesCache();

    var image = try Image.init(
        allocator,
        "AAAA",
        "image/png",
        .{ .fallback_color = .{ .apply_fn = bracketStyle } },
        .{ .filename = "photo.png" },
        .{ .width_px = 800, .height_px = 600 },
    );
    defer image.deinit();

    const rendered = try image.render(allocator, 80);
    defer freeRenderedLines(allocator, rendered);
    try std.testing.expectEqual(@as(usize, 1), rendered.len);
    try std.testing.expectEqualStrings("[[Image: photo.png [image/png] 800x600]]", rendered[0]);
}

test "Image renders Kitty protocol rows and keeps a reusable image id" {
    const allocator = std.testing.allocator;
    terminal_image.setCapabilities(.{ .images = .kitty, .true_color = true, .hyperlinks = true });
    terminal_image.setCellDimensions(.{ .width_px = 10, .height_px = 10 });
    defer {
        terminal_image.resetCapabilitiesCache();
        terminal_image.setCellDimensions(.{ .width_px = 9, .height_px = 18 });
    }

    var image = try Image.init(
        allocator,
        "AAAA",
        "image/png",
        .{},
        .{ .max_width_cells = 2 },
        .{ .width_px = 20, .height_px = 20 },
    );
    defer image.deinit();

    const rendered = try image.render(allocator, 4);
    defer freeRenderedLines(allocator, rendered);
    const image_id = image.getImageId() orelse return error.ExpectedImageId;
    const id_param = try std.fmt.allocPrint(allocator, ",i={d}", .{image_id});
    defer allocator.free(id_param);

    try std.testing.expectEqual(@as(usize, 2), rendered.len);
    try std.testing.expect(std.mem.startsWith(u8, rendered[0], "\x1b_G"));
    try std.testing.expect(std.mem.indexOf(u8, rendered[0], ",C=1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered[0], id_param) != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered[0], "\x1b\\"));
    try std.testing.expectEqualStrings("", rendered[1]);
}

test "Image caches per width and invalidates cached render lines" {
    const allocator = std.testing.allocator;
    terminal_image.setCapabilities(.{ .images = null, .true_color = false, .hyperlinks = false });
    defer terminal_image.resetCapabilitiesCache();

    var image = try Image.init(
        allocator,
        "AAAA",
        "image/png",
        .{},
        .{},
        .{ .width_px = 10, .height_px = 10 },
    );
    defer image.deinit();

    const first = try image.render(allocator, 40);
    defer freeRenderedLines(allocator, first);
    try std.testing.expect(image.cached_lines != null);
    try std.testing.expectEqual(@as(?usize, 40), image.cached_width);

    image.invalidate();
    try std.testing.expect(image.cached_lines == null);
    try std.testing.expect(image.cached_width == null);
}

test "Image renders iTerm2 sequence on the last accounted row" {
    const allocator = std.testing.allocator;
    terminal_image.setCapabilities(.{ .images = .iterm2, .true_color = true, .hyperlinks = true });
    terminal_image.setCellDimensions(.{ .width_px = 10, .height_px = 10 });
    defer {
        terminal_image.resetCapabilitiesCache();
        terminal_image.setCellDimensions(.{ .width_px = 9, .height_px = 18 });
    }

    var image = try Image.init(
        allocator,
        "AAAA",
        "image/png",
        .{},
        .{ .max_width_cells = 2 },
        .{ .width_px = 20, .height_px = 20 },
    );
    defer image.deinit();

    const rendered = try image.render(allocator, 4);
    defer freeRenderedLines(allocator, rendered);

    try std.testing.expectEqual(@as(usize, 2), rendered.len);
    try std.testing.expectEqualStrings("", rendered[0]);
    try std.testing.expect(std.mem.startsWith(u8, rendered[1], "\x1b[1A\x1b]1337;File="));
}

test "Markdown renders nested and ordered lists with Pi-compatible markers" {
    const allocator = std.testing.allocator;

    var nested = try Markdown.init(
        allocator,
        "- Item 1\n  - Nested 1.1\n  - Nested 1.2\n- Item 2",
        0,
        0,
        test_markdown_theme,
        null,
        .{},
    );
    defer nested.deinit();
    const nested_lines = try renderMarkdownPlain(allocator, &nested, 80);
    defer freeRenderedLines(allocator, nested_lines);
    try std.testing.expect(containsLineWith(nested_lines, "- Item 1"));
    try std.testing.expect(containsLineWith(nested_lines, "    - Nested 1.1"));
    try std.testing.expect(containsLineWith(nested_lines, "    - Nested 1.2"));
    try std.testing.expect(containsLineWith(nested_lines, "- Item 2"));

    var normalized = try Markdown.init(allocator, "1. alpha\n1. beta\n1. gamma", 0, 0, test_markdown_theme, null, .{});
    defer normalized.deinit();
    const normalized_lines = try renderMarkdownPlain(allocator, &normalized, 80);
    defer freeRenderedLines(allocator, normalized_lines);
    try std.testing.expectEqualStrings("1. alpha", normalized_lines[0]);
    try std.testing.expectEqualStrings("2. beta", normalized_lines[1]);
    try std.testing.expectEqualStrings("3. gamma", normalized_lines[2]);

    var preserved = try Markdown.init(
        allocator,
        "  4. forth\n  3. third\n\n10) ten\n7) seven",
        0,
        0,
        test_markdown_theme,
        null,
        .{ .preserve_ordered_list_markers = true },
    );
    defer preserved.deinit();
    const preserved_lines = try renderMarkdownPlain(allocator, &preserved, 80);
    defer freeRenderedLines(allocator, preserved_lines);
    try std.testing.expectEqualStrings("    4. forth", preserved_lines[0]);
    try std.testing.expectEqualStrings("    3. third", preserved_lines[1]);
    try std.testing.expectEqualStrings("", preserved_lines[2]);
    try std.testing.expectEqualStrings("10) ten", preserved_lines[3]);
    try std.testing.expectEqualStrings("7) seven", preserved_lines[4]);
}

test "Markdown indents wrapped list continuations and task markers" {
    const allocator = std.testing.allocator;
    var unordered = try Markdown.init(allocator, "- alpha beta gamma delta epsilon", 0, 0, test_markdown_theme, null, .{});
    defer unordered.deinit();
    const unordered_lines = try renderMarkdownPlain(allocator, &unordered, 20);
    defer freeRenderedLines(allocator, unordered_lines);
    try std.testing.expectEqualStrings("- alpha beta gamma", unordered_lines[0]);
    try std.testing.expectEqualStrings("  delta epsilon", unordered_lines[1]);

    var ordered = try Markdown.init(allocator, "10. alpha beta gamma delta epsilon", 0, 0, test_markdown_theme, null, .{});
    defer ordered.deinit();
    const ordered_lines = try renderMarkdownPlain(allocator, &ordered, 21);
    defer freeRenderedLines(allocator, ordered_lines);
    try std.testing.expectEqualStrings("10. alpha beta gamma", ordered_lines[0]);
    try std.testing.expectEqualStrings("    delta epsilon", ordered_lines[1]);

    var tasks = try Markdown.init(allocator, "- [ ] beep\n- [x] boop", 0, 0, test_markdown_theme, null, .{});
    defer tasks.deinit();
    const task_lines = try renderMarkdownPlain(allocator, &tasks, 80);
    defer freeRenderedLines(allocator, task_lines);
    try std.testing.expectEqualStrings("- [ ] beep", task_lines[0]);
    try std.testing.expectEqualStrings("- [x] boop", task_lines[1]);
}

test "Markdown renders blockquotes inside and outside list items" {
    const allocator = std.testing.allocator;
    var list_quote = try Markdown.init(allocator, "- > alpha beta gamma delta epsilon zeta", 0, 0, test_markdown_theme, null, .{});
    defer list_quote.deinit();
    const list_quote_lines = try renderMarkdownPlain(allocator, &list_quote, 24);
    defer freeRenderedLines(allocator, list_quote_lines);
    try std.testing.expectEqualStrings("- │ alpha beta gamma", list_quote_lines[0]);
    try std.testing.expectEqualStrings("  │ delta epsilon zeta", list_quote_lines[1]);

    var quote = try Markdown.init(
        allocator,
        ">Foo\nbar",
        0,
        0,
        test_markdown_theme,
        .{ .color = .{ .apply_fn = ansiMagenta } },
        .{},
    );
    defer quote.deinit();
    const quote_lines = try quote.render(allocator, 80);
    defer freeRenderedLines(allocator, quote_lines);
    const stripped_foo = try stripAnsiAlloc(allocator, quote_lines[0]);
    defer allocator.free(stripped_foo);
    const stripped_bar = try stripAnsiAlloc(allocator, quote_lines[1]);
    defer allocator.free(stripped_bar);
    const plain_foo = try trimEndSpacesAlloc(allocator, stripped_foo);
    defer allocator.free(plain_foo);
    const plain_bar = try trimEndSpacesAlloc(allocator, stripped_bar);
    defer allocator.free(plain_bar);
    try std.testing.expectEqualStrings("│ Foo", plain_foo);
    try std.testing.expectEqualStrings("│ bar", plain_bar);
    try std.testing.expect(std.mem.indexOf(u8, quote_lines[0], "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, quote_lines[1], "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, quote_lines[0], "\x1b[35m") == null);
    try std.testing.expect(std.mem.indexOf(u8, quote_lines[1], "\x1b[35m") == null);
}

test "Markdown renders list item fenced code with continuation prefixes" {
    const allocator = std.testing.allocator;
    var markdown = try Markdown.init(
        allocator,
        "- ```ts\n  alpha beta gamma delta epsilon zeta\n  ```",
        0,
        0,
        test_markdown_theme,
        null,
        .{},
    );
    defer markdown.deinit();
    const lines = try renderMarkdownPlain(allocator, &markdown, 24);
    defer freeRenderedLines(allocator, lines);
    try std.testing.expectEqualStrings("- ```ts", lines[0]);
    try std.testing.expectEqualStrings("    alpha beta gamma", lines[1]);
    try std.testing.expectEqualStrings("  delta epsilon zeta", lines[2]);
    try std.testing.expectEqualStrings("  ```", lines[3]);
}

test "Markdown renders and wraps tables within the available width" {
    const allocator = std.testing.allocator;
    terminal_image.setCapabilities(.{ .images = null, .true_color = false, .hyperlinks = false });
    defer terminal_image.resetCapabilitiesCache();

    var markdown = try Markdown.init(
        allocator,
        "| Value |\n| --- |\n| prefix https://example.com/this/is/a/very/long/url/that/should/wrap |",
        0,
        0,
        test_markdown_theme,
        null,
        .{},
    );
    defer markdown.deinit();
    const lines = try renderMarkdownPlain(allocator, &markdown, 30);
    defer freeRenderedLines(allocator, lines);
    for (lines) |line| try std.testing.expect(visibleWidth(line) <= 30);
    for (lines) |line| {
        if (std.mem.startsWith(u8, line, "│")) {
            try std.testing.expectEqual(@as(usize, 2), countOccurrences(line, "│"));
        }
    }
    const joined = try joinLinesWith(allocator, lines, "");
    defer allocator.free(joined);
    const compact = try removeTableNoise(allocator, joined);
    defer allocator.free(compact);
    try std.testing.expect(std.mem.indexOf(u8, compact, "prefix") != null);
    try std.testing.expect(std.mem.indexOf(u8, compact, "https://example.com/this/is/a/very/long/url/that/should/wrap") != null);
}

test "Markdown normalizes spacing around block elements without trailing blanks" {
    const allocator = std.testing.allocator;
    var code = try Markdown.init(allocator, "hello this is text\n```\ncode block\n```\nmore text", 0, 0, test_markdown_theme, null, .{});
    defer code.deinit();
    const code_lines = try renderMarkdownPlain(allocator, &code, 80);
    defer freeRenderedLines(allocator, code_lines);
    const expected = [_][]const u8{ "hello this is text", "", "```", "  code block", "```", "", "more text" };
    try std.testing.expectEqual(expected.len, code_lines.len);
    for (expected, 0..) |line, index| try std.testing.expectEqualStrings(line, code_lines[index]);

    var heading = try Markdown.init(allocator, "# Hello", 0, 0, test_markdown_theme, null, .{});
    defer heading.deinit();
    const heading_lines = try renderMarkdownPlain(allocator, &heading, 80);
    defer freeRenderedLines(allocator, heading_lines);
    try std.testing.expect(heading_lines.len > 0);
    try std.testing.expect(!std.mem.eql(u8, heading_lines[heading_lines.len - 1], ""));

    var divider = try Markdown.init(allocator, "---", 0, 0, test_markdown_theme, null, .{});
    defer divider.deinit();
    const divider_lines = try renderMarkdownPlain(allocator, &divider, 80);
    defer freeRenderedLines(allocator, divider_lines);
    try std.testing.expect(divider_lines.len > 0);
    try std.testing.expect(!std.mem.eql(u8, divider_lines[divider_lines.len - 1], ""));
}

test "Markdown restores default and heading styles after inline spans" {
    const allocator = std.testing.allocator;
    var thinking = try Markdown.init(
        allocator,
        "This is thinking with `inline code` and **bold text** after",
        1,
        0,
        test_markdown_theme,
        .{ .color = .{ .apply_fn = ansiGray }, .italic = true },
        .{},
    );
    defer thinking.deinit();
    const rendered = try thinking.render(allocator, 100);
    defer freeRenderedLines(allocator, rendered);
    const joined = try joinLinesWith(allocator, rendered, "\n");
    defer allocator.free(joined);
    try std.testing.expect(std.mem.indexOf(u8, joined, "\x1b[90m") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "\x1b[33m") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "\x1b[1m") != null);

    var heading = try Markdown.init(allocator, "### Why `sourceInfo` should not be optional", 0, 0, test_markdown_theme, null, .{});
    defer heading.deinit();
    const heading_rendered = try heading.render(allocator, 80);
    defer freeRenderedLines(allocator, heading_rendered);
    const heading_joined = try joinLinesWith(allocator, heading_rendered, "\n");
    defer allocator.free(heading_joined);
    const after_code = std.mem.indexOf(u8, heading_joined, "should not be optional") orelse return error.MissingHeadingTail;
    const prefix_start = after_code -| 64;
    const preceding = heading_joined[prefix_start..after_code];
    try std.testing.expect(std.mem.indexOf(u8, preceding, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, preceding, "\x1b[36m") != null);
}

test "Markdown strict strikethrough and single tilde behavior" {
    const allocator = std.testing.allocator;
    var struck = try Markdown.init(allocator, "Use ~~strikethrough~~ here", 0, 0, test_markdown_theme, null, .{});
    defer struck.deinit();
    const struck_lines = try struck.render(allocator, 80);
    defer freeRenderedLines(allocator, struck_lines);
    const struck_joined = try joinLinesWith(allocator, struck_lines, "\n");
    defer allocator.free(struck_joined);
    try std.testing.expect(std.mem.indexOf(u8, struck_joined, "\x1b[9m") != null);
    const struck_plain = try stripAnsiAlloc(allocator, struck_joined);
    defer allocator.free(struck_plain);
    try std.testing.expect(std.mem.indexOf(u8, struck_plain, "strikethrough") != null);
    try std.testing.expect(std.mem.indexOf(u8, struck_plain, "~~strikethrough~~") == null);

    var literal = try Markdown.init(allocator, "Use ~strikethrough~ literally", 0, 0, test_markdown_theme, null, .{});
    defer literal.deinit();
    const literal_lines = try literal.render(allocator, 80);
    defer freeRenderedLines(allocator, literal_lines);
    const literal_joined = try joinLinesWith(allocator, literal_lines, "\n");
    defer allocator.free(literal_joined);
    const literal_plain = try stripAnsiAlloc(allocator, literal_joined);
    defer allocator.free(literal_plain);
    try std.testing.expect(std.mem.indexOf(u8, literal_plain, "~strikethrough~") != null);
    try std.testing.expect(std.mem.indexOf(u8, literal_joined, "\x1b[9m") == null);
}

test "Markdown links match fallback and OSC8 behavior" {
    const allocator = std.testing.allocator;
    terminal_image.setCapabilities(.{ .images = null, .true_color = false, .hyperlinks = false });

    var email = try Markdown.init(allocator, "Contact user@example.com for help", 0, 0, test_markdown_theme, null, .{});
    defer email.deinit();
    const email_lines = try renderMarkdownPlain(allocator, &email, 80);
    defer freeRenderedLines(allocator, email_lines);
    const email_joined = try joinLinesWith(allocator, email_lines, " ");
    defer allocator.free(email_joined);
    try std.testing.expect(std.mem.indexOf(u8, email_joined, "user@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, email_joined, "mailto:") == null);

    var named = try Markdown.init(allocator, "[click here](https://example.com)", 0, 0, test_markdown_theme, null, .{});
    defer named.deinit();
    const named_lines = try renderMarkdownPlain(allocator, &named, 80);
    defer freeRenderedLines(allocator, named_lines);
    try std.testing.expect(std.mem.indexOf(u8, named_lines[0], "click here") != null);
    try std.testing.expect(std.mem.indexOf(u8, named_lines[0], "(https://example.com)") != null);

    terminal_image.setCapabilities(.{ .images = null, .true_color = false, .hyperlinks = true });
    defer terminal_image.resetCapabilitiesCache();
    var osc = try Markdown.init(allocator, "[click here](https://example.com)", 0, 0, test_markdown_theme, null, .{});
    defer osc.deinit();
    const osc_lines = try osc.render(allocator, 80);
    defer freeRenderedLines(allocator, osc_lines);
    const osc_joined = try joinLinesWith(allocator, osc_lines, "");
    defer allocator.free(osc_joined);
    try std.testing.expect(std.mem.indexOf(u8, osc_joined, "\x1b]8;;https://example.com\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, osc_joined, "\x1b]8;;\x1b\\") != null);
}

test "Markdown caches per width and applies full-line background padding" {
    const allocator = std.testing.allocator;
    var markdown = try Markdown.init(
        allocator,
        "hello",
        1,
        1,
        test_markdown_theme,
        .{ .bg_color = .{ .apply_fn = ansiBgBlue } },
        .{},
    );
    defer markdown.deinit();
    const first = try markdown.render(allocator, 12);
    defer freeRenderedLines(allocator, first);
    try std.testing.expect(markdown.cached_lines != null);
    try std.testing.expectEqual(@as(?usize, 12), markdown.cached_width);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    for (first) |line| {
        try std.testing.expectEqual(@as(usize, 12), visibleWidth(line));
        try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[44m") != null);
    }
    markdown.invalidate();
    try std.testing.expect(markdown.cached_lines == null);
    try std.testing.expect(markdown.cached_width == null);
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
    _ = @import("word_navigation.zig");
    _ = @import("kill_ring.zig");
    _ = @import("undo_stack.zig");
    _ = @import("stdin_buffer.zig");
    _ = @import("terminal_image.zig");
    _ = @import("native_modifiers.zig");
}
