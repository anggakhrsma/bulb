const std = @import("std");
const keybindings = @import("keybindings.zig");
const keys = @import("keys.zig");
const kill_ring = @import("kill_ring.zig");
const undo_stack = @import("undo_stack.zig");

const CURSOR_MARKER = "\x1b_pi:c\x07";
const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";

const LastAction = enum { kill, yank, type_word };

pub const SubmitCallback = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: SubmitCallback, value: []const u8) void {
        self.call_fn(self.context, value);
    }
};

pub const EscapeCallback = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) void,

    pub fn call(self: EscapeCallback) void {
        self.call_fn(self.context);
    }
};

const InputState = struct {
    value: []u8,
    cursor: usize,

    fn clone(allocator: std.mem.Allocator, state: InputState) !InputState {
        return .{
            .value = try allocator.dupe(u8, state.value),
            .cursor = state.cursor,
        };
    }

    fn deinit(allocator: std.mem.Allocator, state: *InputState) void {
        allocator.free(state.value);
    }
};

pub const Input = struct {
    allocator: std.mem.Allocator,
    value: []u8,
    cursor: usize = 0,
    on_submit: ?SubmitCallback = null,
    on_escape: ?EscapeCallback = null,
    focused: bool = false,
    paste_buffer: std.ArrayList(u8) = .empty,
    is_in_paste: bool = false,
    kill_ring: kill_ring.KillRing,
    last_action: ?LastAction = null,
    undo_stack: undo_stack.UndoStack(InputState),

    pub fn init(allocator: std.mem.Allocator) !Input {
        return .{
            .allocator = allocator,
            .value = try allocator.dupe(u8, ""),
            .kill_ring = kill_ring.KillRing.init(allocator),
            .undo_stack = undo_stack.UndoStack(InputState).init(allocator, InputState.clone, InputState.deinit),
        };
    }

    pub fn deinit(self: *Input) void {
        self.allocator.free(self.value);
        self.paste_buffer.deinit(self.allocator);
        self.kill_ring.deinit();
        self.undo_stack.deinit();
    }

    pub fn getValue(self: *const Input) []const u8 {
        return self.value;
    }

    pub fn setValue(self: *Input, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.value);
        self.value = owned;
        self.cursor = @min(self.cursor, self.value.len);
        self.cursor = clampToUtf8Boundary(self.value, self.cursor);
    }

    pub fn handleInput(self: *Input, allocator: std.mem.Allocator, data: []const u8) !void {
        if (std.mem.indexOf(u8, data, BRACKETED_PASTE_START)) |start_index| {
            self.is_in_paste = true;
            self.paste_buffer.clearRetainingCapacity();

            if (start_index > 0) {
                try self.handleInput(allocator, data[0..start_index]);
            }
            try self.paste_buffer.appendSlice(self.allocator, data[start_index + BRACKETED_PASTE_START.len ..]);
        } else if (self.is_in_paste) {
            try self.paste_buffer.appendSlice(self.allocator, data);
        }

        if (self.is_in_paste) {
            if (std.mem.indexOf(u8, self.paste_buffer.items, BRACKETED_PASTE_END)) |end_index| {
                const paste_content = self.paste_buffer.items[0..end_index];
                const remaining = try self.allocator.dupe(u8, self.paste_buffer.items[end_index + BRACKETED_PASTE_END.len ..]);
                defer self.allocator.free(remaining);

                try self.handlePaste(paste_content);
                self.is_in_paste = false;
                self.paste_buffer.clearRetainingCapacity();

                if (remaining.len > 0) try self.handleInput(allocator, remaining);
            }
            return;
        }

        const kb = try keybindings.getKeybindings(allocator);

        if (kb.matches(data, "tui.select.cancel")) {
            if (self.on_escape) |callback| callback.call();
            return;
        }

        if (kb.matches(data, "tui.editor.undo")) {
            self.undo();
            return;
        }

        if (kb.matches(data, "tui.input.submit") or std.mem.eql(u8, data, "\n")) {
            if (self.on_submit) |callback| callback.call(self.value);
            return;
        }

        if (kb.matches(data, "tui.editor.deleteCharBackward")) {
            try self.handleBackspace();
            return;
        }

        if (kb.matches(data, "tui.editor.deleteCharForward")) {
            try self.handleForwardDelete();
            return;
        }

        if (kb.matches(data, "tui.editor.deleteWordBackward")) {
            try self.deleteWordBackwards();
            return;
        }

        if (kb.matches(data, "tui.editor.deleteWordForward")) {
            try self.deleteWordForward();
            return;
        }

        if (kb.matches(data, "tui.editor.deleteToLineStart")) {
            try self.deleteToLineStart();
            return;
        }

        if (kb.matches(data, "tui.editor.deleteToLineEnd")) {
            try self.deleteToLineEnd();
            return;
        }

        if (kb.matches(data, "tui.editor.yank")) {
            try self.yank();
            return;
        }

        if (kb.matches(data, "tui.editor.yankPop")) {
            try self.yankPop();
            return;
        }

        if (kb.matches(data, "tui.editor.cursorLeft")) {
            self.last_action = null;
            self.cursor = prevGraphemeStart(self.value, self.cursor);
            return;
        }

        if (kb.matches(data, "tui.editor.cursorRight")) {
            self.last_action = null;
            self.cursor = nextGraphemeEnd(self.value, self.cursor);
            return;
        }

        if (kb.matches(data, "tui.editor.cursorLineStart")) {
            self.last_action = null;
            self.cursor = 0;
            return;
        }

        if (kb.matches(data, "tui.editor.cursorLineEnd")) {
            self.last_action = null;
            self.cursor = self.value.len;
            return;
        }

        if (kb.matches(data, "tui.editor.cursorWordLeft")) {
            self.moveWordBackwards();
            return;
        }

        if (kb.matches(data, "tui.editor.cursorWordRight")) {
            self.moveWordForwards();
            return;
        }

        if (keys.decodeKittyPrintable(data)) |printable| {
            try self.insertCharacter(printable);
            return;
        }

        if (!hasControlChars(data)) {
            try self.insertCharacter(data);
        }
    }

    fn insertCharacter(self: *Input, char: []const u8) !void {
        if (isWhitespaceText(char) or self.last_action != .type_word) {
            try self.pushUndo();
        }
        self.last_action = .type_word;

        const replacement = try std.mem.concat(self.allocator, u8, &.{ self.value[0..self.cursor], char, self.value[self.cursor..] });
        self.allocator.free(self.value);
        self.value = replacement;
        self.cursor += char.len;
    }

    fn handleBackspace(self: *Input) !void {
        self.last_action = null;
        if (self.cursor == 0) return;

        try self.pushUndo();
        const delete_from = prevGraphemeStart(self.value, self.cursor);
        const replacement = try std.mem.concat(self.allocator, u8, &.{ self.value[0..delete_from], self.value[self.cursor..] });
        self.allocator.free(self.value);
        self.value = replacement;
        self.cursor = delete_from;
    }

    fn handleForwardDelete(self: *Input) !void {
        self.last_action = null;
        if (self.cursor >= self.value.len) return;

        try self.pushUndo();
        const delete_to = nextGraphemeEnd(self.value, self.cursor);
        const replacement = try std.mem.concat(self.allocator, u8, &.{ self.value[0..self.cursor], self.value[delete_to..] });
        self.allocator.free(self.value);
        self.value = replacement;
    }

    fn deleteToLineStart(self: *Input) !void {
        if (self.cursor == 0) return;

        try self.pushUndo();
        const deleted = self.value[0..self.cursor];
        try self.kill_ring.push(deleted, .{ .prepend = true, .accumulate = self.last_action == .kill });
        self.last_action = .kill;

        const replacement = try self.allocator.dupe(u8, self.value[self.cursor..]);
        self.allocator.free(self.value);
        self.value = replacement;
        self.cursor = 0;
    }

    fn deleteToLineEnd(self: *Input) !void {
        if (self.cursor >= self.value.len) return;

        try self.pushUndo();
        const deleted = self.value[self.cursor..];
        try self.kill_ring.push(deleted, .{ .prepend = false, .accumulate = self.last_action == .kill });
        self.last_action = .kill;

        const replacement = try self.allocator.dupe(u8, self.value[0..self.cursor]);
        self.allocator.free(self.value);
        self.value = replacement;
    }

    fn deleteWordBackwards(self: *Input) !void {
        if (self.cursor == 0) return;

        const was_kill = self.last_action == .kill;
        try self.pushUndo();

        const delete_from = findWordBackwardInput(self.value, self.cursor);
        const deleted = self.value[delete_from..self.cursor];
        try self.kill_ring.push(deleted, .{ .prepend = true, .accumulate = was_kill });
        self.last_action = .kill;

        const replacement = try std.mem.concat(self.allocator, u8, &.{ self.value[0..delete_from], self.value[self.cursor..] });
        self.allocator.free(self.value);
        self.value = replacement;
        self.cursor = delete_from;
    }

    fn deleteWordForward(self: *Input) !void {
        if (self.cursor >= self.value.len) return;

        const was_kill = self.last_action == .kill;
        try self.pushUndo();

        const delete_to = findWordForwardInput(self.value, self.cursor);
        const deleted = self.value[self.cursor..delete_to];
        try self.kill_ring.push(deleted, .{ .prepend = false, .accumulate = was_kill });
        self.last_action = .kill;

        const replacement = try std.mem.concat(self.allocator, u8, &.{ self.value[0..self.cursor], self.value[delete_to..] });
        self.allocator.free(self.value);
        self.value = replacement;
    }

    fn yank(self: *Input) !void {
        const text = self.kill_ring.peek() orelse return;

        try self.pushUndo();
        const replacement = try std.mem.concat(self.allocator, u8, &.{ self.value[0..self.cursor], text, self.value[self.cursor..] });
        self.allocator.free(self.value);
        self.value = replacement;
        self.cursor += text.len;
        self.last_action = .yank;
    }

    fn yankPop(self: *Input) !void {
        if (self.last_action != .yank or self.kill_ring.len() <= 1) return;

        try self.pushUndo();

        const prev_text = self.kill_ring.peek() orelse "";
        const yank_start = if (self.cursor >= prev_text.len) self.cursor - prev_text.len else self.cursor;
        var without_prev = try std.mem.concat(self.allocator, u8, &.{ self.value[0..yank_start], self.value[self.cursor..] });
        self.allocator.free(self.value);
        self.value = without_prev;
        self.cursor = yank_start;

        self.kill_ring.rotate();
        const text = self.kill_ring.peek() orelse "";
        without_prev = try std.mem.concat(self.allocator, u8, &.{ self.value[0..self.cursor], text, self.value[self.cursor..] });
        self.allocator.free(self.value);
        self.value = without_prev;
        self.cursor += text.len;
        self.last_action = .yank;
    }

    fn pushUndo(self: *Input) !void {
        try self.undo_stack.push(.{
            .value = self.value,
            .cursor = self.cursor,
        });
    }

    fn undo(self: *Input) void {
        var snapshot = self.undo_stack.pop() orelse return;
        self.allocator.free(self.value);
        self.value = snapshot.value;
        self.cursor = snapshot.cursor;
        snapshot.value = &.{};
        self.last_action = null;
    }

    fn moveWordBackwards(self: *Input) void {
        if (self.cursor == 0) return;
        self.last_action = null;
        self.cursor = findWordBackwardInput(self.value, self.cursor);
    }

    fn moveWordForwards(self: *Input) void {
        if (self.cursor >= self.value.len) return;
        self.last_action = null;
        self.cursor = findWordForwardInput(self.value, self.cursor);
    }

    fn handlePaste(self: *Input, pasted_text: []const u8) !void {
        self.last_action = null;
        try self.pushUndo();

        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(self.allocator);
        var index: usize = 0;
        while (index < pasted_text.len) {
            if (index + 1 < pasted_text.len and pasted_text[index] == '\r' and pasted_text[index + 1] == '\n') {
                index += 2;
                continue;
            }
            switch (pasted_text[index]) {
                '\r', '\n' => index += 1,
                '\t' => {
                    try clean.appendSlice(self.allocator, "    ");
                    index += 1;
                },
                else => {
                    try clean.append(self.allocator, pasted_text[index]);
                    index += 1;
                },
            }
        }

        const replacement = try std.mem.concat(self.allocator, u8, &.{ self.value[0..self.cursor], clean.items, self.value[self.cursor..] });
        self.allocator.free(self.value);
        self.value = replacement;
        self.cursor += clean.items.len;
    }

    pub fn invalidate(_: *Input) void {}

    pub fn render(self: *Input, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        const prompt = "> ";
        const lines = try allocator.alloc([]u8, 1);
        errdefer allocator.free(lines);

        if (width <= prompt.len) {
            lines[0] = try allocator.dupe(u8, prompt);
            return lines;
        }

        const available_width = width - prompt.len;
        var visible_text: []u8 = undefined;
        var cursor_display: usize = self.cursor;
        const total_width = displayWidth(self.value);

        if (total_width < available_width) {
            visible_text = try allocator.dupe(u8, self.value);
        } else {
            const scroll_width = if (self.cursor == self.value.len and available_width > 0) available_width - 1 else available_width;
            const cursor_col = displayWidth(self.value[0..self.cursor]);

            if (scroll_width > 0) {
                const half_width = scroll_width / 2;
                var start_col: usize = 0;
                if (cursor_col < half_width) {
                    start_col = 0;
                } else if (cursor_col > total_width -| half_width) {
                    start_col = total_width -| scroll_width;
                } else {
                    start_col = cursor_col - half_width;
                }

                visible_text = try sliceByColumn(allocator, self.value, start_col, scroll_width, true);
                const before_cursor = try sliceByColumn(allocator, self.value, start_col, cursor_col -| start_col, true);
                cursor_display = before_cursor.len;
                allocator.free(before_cursor);
            } else {
                visible_text = try allocator.dupe(u8, "");
                cursor_display = 0;
            }
        }
        defer allocator.free(visible_text);

        const cursor_end = nextGraphemeEnd(visible_text, cursor_display);
        const at_cursor = if (cursor_display < visible_text.len) visible_text[cursor_display..cursor_end] else " ";
        const before_cursor = visible_text[0..@min(cursor_display, visible_text.len)];
        const after_cursor = if (cursor_display < visible_text.len) visible_text[cursor_end..] else "";
        const marker = if (self.focused) CURSOR_MARKER else "";
        const visual_width = displayWidth(before_cursor) + displayWidth(at_cursor) + displayWidth(after_cursor);
        const padding_width = available_width -| visual_width;

        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, prompt);
        try line.appendSlice(allocator, before_cursor);
        try line.appendSlice(allocator, marker);
        try line.appendSlice(allocator, "\x1b[7m");
        try line.appendSlice(allocator, at_cursor);
        try line.appendSlice(allocator, "\x1b[27m");
        try line.appendSlice(allocator, after_cursor);
        try appendSpaces(allocator, &line, padding_width);

        lines[0] = try line.toOwnedSlice(allocator);
        return lines;
    }
};

fn hasControlChars(data: []const u8) bool {
    var index: usize = 0;
    while (index < data.len) {
        const decoded = decodeAt(data, index) orelse return true;
        const cp = decoded.codepoint;
        if (cp < 32 or cp == 0x7f or (cp >= 0x80 and cp <= 0x9f)) return true;
        index += decoded.len;
    }
    return false;
}

fn isWhitespaceText(text: []const u8) bool {
    if (text.len == 0) return false;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse return false;
        if (!isWhitespaceCodepoint(decoded.codepoint)) return false;
        index += decoded.len;
    }
    return true;
}

fn isWhitespaceCodepoint(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\r' or cp == '\n';
}

const CodepointClass = enum { whitespace, ascii_punctuation, word, punctuation };

fn classifyCodepoint(cp: u21) CodepointClass {
    if (isWhitespaceCodepoint(cp)) return .whitespace;
    if (cp < 0x80) {
        if (std.mem.indexOfScalar(u8, "(){}[]<>.,;:'\"!?+-=*/\\|&%^$#@~`", @intCast(cp)) != null) return .ascii_punctuation;
        return .word;
    }
    if (isCjkPunctuation(cp)) return .punctuation;
    return .word;
}

fn findWordBackwardInput(text: []const u8, cursor: usize) usize {
    var index = @min(cursor, text.len);
    while (index > 0) {
        const start = prevCodepointStart(text, index);
        const decoded = decodeAt(text, start) orelse break;
        if (classifyCodepoint(decoded.codepoint) != .whitespace) break;
        index = start;
    }
    if (index == 0) return 0;

    const first_start = prevCodepointStart(text, index);
    const first = decodeAt(text, first_start) orelse return first_start;
    return switch (classifyCodepoint(first.codepoint)) {
        .ascii_punctuation => scanBackwardAsciiPunctuation(text, first_start),
        .punctuation, .whitespace => first_start,
        .word => scanBackwardWord(text, index),
    };
}

fn findWordForwardInput(text: []const u8, cursor: usize) usize {
    var index = @min(cursor, text.len);
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse return index + 1;
        if (classifyCodepoint(decoded.codepoint) != .whitespace) break;
        index += decoded.len;
    }
    if (index >= text.len) return text.len;

    const first = decodeAt(text, index) orelse return index + 1;
    return switch (classifyCodepoint(first.codepoint)) {
        .ascii_punctuation => scanForwardAsciiPunctuation(text, index),
        .punctuation, .whitespace => index + first.len,
        .word => scanForwardWord(text, index),
    };
}

fn scanBackwardAsciiPunctuation(text: []const u8, cursor_before_punctuation: usize) usize {
    var index = cursor_before_punctuation;
    while (index > 0) {
        const start = prevCodepointStart(text, index);
        const decoded = decodeAt(text, start) orelse break;
        if (classifyCodepoint(decoded.codepoint) != .ascii_punctuation) break;
        index = start;
    }
    return index;
}

fn scanForwardAsciiPunctuation(text: []const u8, cursor: usize) usize {
    var index = cursor;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse break;
        if (classifyCodepoint(decoded.codepoint) != .ascii_punctuation) break;
        index += decoded.len;
    }
    return index;
}

fn scanBackwardWord(text: []const u8, cursor: usize) usize {
    const first_start = prevCodepointStart(text, cursor);
    const first = decodeAt(text, first_start) orelse return first_start;
    if (first.codepoint < 0x80) {
        var index = first_start;
        while (index > 0) {
            const start = prevCodepointStart(text, index);
            const decoded = decodeAt(text, start) orelse break;
            if (classifyCodepoint(decoded.codepoint) != .word or decoded.codepoint >= 0x80) break;
            index = start;
        }
        return index;
    }

    var index = cursor;
    var count: usize = 0;
    while (index > 0 and count < 2) {
        const start = prevCodepointStart(text, index);
        const decoded = decodeAt(text, start) orelse break;
        if (classifyCodepoint(decoded.codepoint) != .word or decoded.codepoint < 0x80) break;
        index = start;
        count += 1;
    }
    return index;
}

fn scanForwardWord(text: []const u8, cursor: usize) usize {
    const first = decodeAt(text, cursor) orelse return cursor + 1;
    if (first.codepoint < 0x80) {
        var index = cursor;
        while (index < text.len) {
            const decoded = decodeAt(text, index) orelse break;
            if (classifyCodepoint(decoded.codepoint) != .word or decoded.codepoint >= 0x80) break;
            index += decoded.len;
        }
        return index;
    }

    var index = cursor;
    var count: usize = 0;
    while (index < text.len and count < 2) {
        const decoded = decodeAt(text, index) orelse break;
        if (classifyCodepoint(decoded.codepoint) != .word or decoded.codepoint < 0x80) break;
        index += decoded.len;
        count += 1;
    }
    return index;
}

fn isCjkPunctuation(cp: u21) bool {
    return (cp >= 0x3000 and cp <= 0x303f) or
        (cp >= 0xff00 and cp <= 0xffef and !(cp >= 0xff10 and cp <= 0xff19) and !(cp >= 0xff21 and cp <= 0xff3a) and !(cp >= 0xff41 and cp <= 0xff5a));
}

fn clampToUtf8Boundary(text: []const u8, cursor: usize) usize {
    var index = @min(cursor, text.len);
    if (index >= text.len) return text.len;
    while (index > 0 and (text[index] & 0xc0) == 0x80) index -= 1;
    return index;
}

fn prevGraphemeStart(text: []const u8, cursor: usize) usize {
    return prevCodepointStart(text, @min(cursor, text.len));
}

fn nextGraphemeEnd(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    const decoded = decodeAt(text, cursor) orelse return cursor + 1;
    return cursor + decoded.len;
}

fn prevCodepointStart(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var start = @min(cursor, text.len) - 1;
    while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
    return start;
}

const Decoded = struct {
    codepoint: u21,
    len: usize,
};

fn decodeAt(input: []const u8, index: usize) ?Decoded {
    if (index >= input.len) return null;
    const sequence_length = std.unicode.utf8ByteSequenceLength(input[index]) catch return null;
    const len: usize = @intCast(sequence_length);
    if (index + len > input.len) return null;
    const codepoint = std.unicode.utf8Decode(input[index .. index + len]) catch return null;
    return .{ .codepoint = codepoint, .len = len };
}

fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse {
            index += 1;
            continue;
        };
        if (decoded.codepoint == 0x1b) {
            if (skipAnsi(text, index)) |end| {
                index = end;
                continue;
            }
        }
        if (decoded.codepoint == '\t') {
            width += 3;
        } else if (!isNonPrinting(decoded.codepoint)) {
            width += codepointWidth(decoded.codepoint);
        }
        index += decoded.len;
    }
    return width;
}

fn skipAnsi(text: []const u8, index: usize) ?usize {
    if (index + 1 >= text.len or text[index] != 0x1b) return null;
    if (text[index + 1] == '[') {
        var pos = index + 2;
        while (pos < text.len) : (pos += 1) {
            if (text[pos] >= 0x40 and text[pos] <= 0x7e) return pos + 1;
        }
        return text.len;
    }
    if (text[index + 1] == '_') {
        if (std.mem.indexOfScalarPos(u8, text, index + 2, 0x07)) |bel| return bel + 1;
        return text.len;
    }
    return null;
}

fn sliceByColumn(allocator: std.mem.Allocator, text: []const u8, start_col: usize, length: usize, strict: bool) ![]u8 {
    if (length == 0) return allocator.dupe(u8, "");

    const end_col = start_col + length;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var col: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse {
            index += 1;
            continue;
        };
        const char_width = if (decoded.codepoint == '\t') @as(usize, 3) else if (isNonPrinting(decoded.codepoint)) @as(usize, 0) else codepointWidth(decoded.codepoint);
        const in_range = col >= start_col and col < end_col;
        const fits = !strict or col + char_width <= end_col;
        if (in_range and fits) {
            try output.appendSlice(allocator, text[index .. index + decoded.len]);
        }
        col += char_width;
        index += decoded.len;
        if (col >= end_col) break;
    }

    return output.toOwnedSlice(allocator);
}

fn isNonPrinting(cp: u21) bool {
    return cp == 0 or
        (cp < 32 and cp != '\t' and cp != '\n' and cp != '\r') or
        cp == 0x7f or
        (cp >= 0x80 and cp <= 0x9f) or
        (cp >= 0x0300 and cp <= 0x036f) or
        cp == 0x200d or
        cp == 0xfe0f;
}

fn codepointWidth(cp: u21) usize {
    if (cp >= 0x1100 and
        (cp <= 0x115f or
            cp == 0x2329 or
            cp == 0x232a or
            (cp >= 0x2e80 and cp <= 0xa4cf and cp != 0x303f) or
            (cp >= 0xac00 and cp <= 0xd7a3) or
            (cp >= 0xf900 and cp <= 0xfaff) or
            (cp >= 0xfe10 and cp <= 0xfe19) or
            (cp >= 0xfe30 and cp <= 0xfe6f) or
            (cp >= 0xff00 and cp <= 0xff60) or
            (cp >= 0xffe0 and cp <= 0xffe6) or
            (cp >= 0x1f300 and cp <= 0x1faff)))
    {
        return 2;
    }
    return 1;
}

fn appendSpaces(allocator: std.mem.Allocator, output: *std.ArrayList(u8), count: usize) !void {
    try output.ensureUnusedCapacity(allocator, count);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) output.appendAssumeCapacity(' ');
}

fn freeRenderedLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

fn sendChars(input: *Input, allocator: std.mem.Allocator, text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decodeAt(text, index) orelse return error.InvalidUtf8;
        try input.handleInput(allocator, text[index .. index + decoded.len]);
        index += decoded.len;
    }
}

fn moveRight(input: *Input, allocator: std.mem.Allocator, count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try input.handleInput(allocator, "\x1b[C");
}

fn expectValue(input: *const Input, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, input.getValue());
}

fn renderOne(input: *Input, allocator: std.mem.Allocator, width: usize) ![]u8 {
    const lines = try input.render(allocator, width);
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    return lines[0];
}

test "Input submits value including backslash on Enter" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    const Context = struct {
        submitted: ?[]const u8 = null,

        fn submit(raw: ?*anyopaque, value: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.submitted = value;
        }
    };

    var context = Context{};
    var input = try Input.init(allocator);
    defer input.deinit();
    input.on_submit = .{ .context = &context, .call_fn = Context.submit };

    try sendChars(&input, allocator, "hello\\");
    try input.handleInput(allocator, "\r");

    try std.testing.expect(context.submitted != null);
    try std.testing.expectEqualStrings("hello\\", context.submitted.?);
}

test "Input inserts backslash as regular character" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    var input = try Input.init(allocator);
    defer input.deinit();

    try input.handleInput(allocator, "\\");
    try input.handleInput(allocator, "x");
    try expectValue(&input, "\\x");
}

test "Input render does not overflow with wide text and keeps cursor visible" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    const cases = [_][]const u8{
        "가나다라마바사아자차카타파하 한글 텍스트가 터미널 너비를 초과하면 크래시가 발생합니다 이것은 재현용 테스트입니다",
        "これはテスト文章です。日本語のテキストが正しく表示されるかどうかを確認するためのサンプルテキストです。あいうえお",
        "这是一段测试文本，用于验证中文字符在终端中的显示宽度是否被正确计算，如果不正确就会导致用户界面崩溃的问题",
        "ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ０１２３４５６７８９ａｂｃｄｅｆｇｈｉｊｋｌｍ",
    };
    const width: usize = 93;

    for (cases) |text| {
        var at_start = try Input.init(allocator);
        defer at_start.deinit();
        try at_start.setValue(text);
        at_start.focused = true;
        const start_line = try renderOne(&at_start, allocator, width);
        defer allocator.free(start_line);
        try std.testing.expect(displayWidth(start_line) <= width);

        var middle = try Input.init(allocator);
        defer middle.deinit();
        try middle.setValue(text);
        middle.focused = true;
        try moveRight(&middle, allocator, 10);
        const middle_line = try renderOne(&middle, allocator, width);
        defer allocator.free(middle_line);
        try std.testing.expect(displayWidth(middle_line) <= width);

        var at_end = try Input.init(allocator);
        defer at_end.deinit();
        try at_end.setValue(text);
        at_end.focused = true;
        try at_end.handleInput(allocator, "\x05");
        const end_line = try renderOne(&at_end, allocator, width);
        defer allocator.free(end_line);
        try std.testing.expect(displayWidth(end_line) <= width);
    }

    var scrolled = try Input.init(allocator);
    defer scrolled.deinit();
    try scrolled.setValue("가나다라마바사아자차카타파하");
    scrolled.focused = true;
    try scrolled.handleInput(allocator, "\x01");
    try moveRight(&scrolled, allocator, 5);
    const line = try renderOne(&scrolled, allocator, 20);
    defer allocator.free(line);
    try std.testing.expect(displayWidth(line) <= 20);
}

test "Input kill ring delete, yank, yank-pop, and accumulation behavior" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("foo bar baz");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "foo bar ");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "bazfoo bar ");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("foo.bar");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "foo.");
        try input.setValue("foo:bar");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "foo:");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("你好世界。你好，世界");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "你好世界。你好，");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "你好世界。你好");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "你好世界。");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "你好世界");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "你好");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("hello world");
        try input.handleInput(allocator, "\x01");
        try moveRight(&input, allocator, 6);
        try input.handleInput(allocator, "\x15");
        try expectValue(&input, "world");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "hello world");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("hello world");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x0b");
        try expectValue(&input, "");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "hello world");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("test");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "test");
    }
}

test "Input yank-pop cycles and persists kill ring rotation" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("first");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("second");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("third");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "third");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "second");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "first");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "third");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("test");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("other");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "x");
        try expectValue(&input, "otherx");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "otherx");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("only");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "only");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "only");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("first");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("second");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("third");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("");
        try input.handleInput(allocator, "\x19");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "second");
        try input.handleInput(allocator, "x");
        try input.setValue("");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "second");
    }
}

test "Input kill accumulation covers backward and forward word deletion" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("one two three");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.handleInput(allocator, "\x17");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "one two three");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("foo bar baz");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "foo bar ");
        try input.handleInput(allocator, "x");
        try expectValue(&input, "foo bar x");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "foo bar ");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "foo bar x");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "foo bar baz");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("hello world test");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, " world test");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, " test");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "hello world test");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("foo.bar baz");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, ".bar baz");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, "bar baz");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, " baz");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("你好世界。你好，世界");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, "世界。你好，世界");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, "。你好，世界");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, "你好，世界");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, "，世界");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, "世界");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, "");
    }
}

test "Input yank and yank-pop work in the middle of text" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("word");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("hello world");
        try input.handleInput(allocator, "\x01");
        try moveRight(&input, allocator, 6);
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "hello wordworld");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("FIRST");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("SECOND");
        try input.handleInput(allocator, "\x05");
        try input.handleInput(allocator, "\x17");
        try input.setValue("hello world");
        try input.handleInput(allocator, "\x01");
        try moveRight(&input, allocator, 6);
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "hello SECONDworld");
        try input.handleInput(allocator, "\x1by");
        try expectValue(&input, "hello FIRSTworld");
    }
}

test "Input undo mirrors Pi single-line editing snapshots" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello world");
        try expectValue(&input, "hello world");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello  ");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello ");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello");
        try input.handleInput(allocator, "\x7f");
        try expectValue(&input, "hell");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x1b[C");
        try input.handleInput(allocator, "\x1b[3~");
        try expectValue(&input, "hllo");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello world");
        try input.handleInput(allocator, "\x17");
        try expectValue(&input, "hello ");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello world");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello world");
        try input.handleInput(allocator, "\x01");
        try moveRight(&input, allocator, 6);
        try input.handleInput(allocator, "\x0b");
        try expectValue(&input, "hello ");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello world");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello world");
        try input.handleInput(allocator, "\x01");
        try moveRight(&input, allocator, 6);
        try input.handleInput(allocator, "\x15");
        try expectValue(&input, "world");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello world");
    }
}

test "Input undo covers yank, paste, Alt+D, and movement-separated typing" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "hello ");
        try input.handleInput(allocator, "\x17");
        try input.handleInput(allocator, "\x19");
        try expectValue(&input, "hello ");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("hello world");
        try input.handleInput(allocator, "\x01");
        try moveRight(&input, allocator, 5);
        try input.handleInput(allocator, "\x1b[200~beep boop\x1b[201~");
        try expectValue(&input, "hellobeep boop world");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello world");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try input.setValue("hello world");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x1bd");
        try expectValue(&input, " world");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "hello world");
    }

    {
        var input = try Input.init(allocator);
        defer input.deinit();
        try sendChars(&input, allocator, "abc");
        try input.handleInput(allocator, "\x01");
        try input.handleInput(allocator, "\x05");
        try sendChars(&input, allocator, "de");
        try expectValue(&input, "abcde");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "abc");
        try input.handleInput(allocator, "\x1b[45;5u");
        try expectValue(&input, "");
    }
}
