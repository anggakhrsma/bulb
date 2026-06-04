const std = @import("std");
const keybindings = @import("keybindings.zig");
const keys = @import("keys.zig");
const kill_ring = @import("kill_ring.zig");
const undo_stack = @import("undo_stack.zig");

const ESC: u8 = 0x1b;
const BEL: u8 = 0x07;
const CURSOR_MARKER = "\x1b_pi:c\x07";
const RESET = "\x1b[0m";
const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";

const LastAction = enum { kill, yank, type_word };
const JumpMode = enum { forward, backward };

pub const Cursor = struct {
    line: usize,
    col: usize,
};

pub const TextChunk = struct {
    text: []const u8,
    start_index: usize,
    end_index: usize,
};

pub const SegmentData = struct {
    segment: []const u8,
    index: usize,
};

pub const SubmitCallback = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: SubmitCallback, text: []const u8) void {
        self.call_fn(self.context, text);
    }
};

pub const ChangeCallback = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: ChangeCallback, text: []const u8) void {
        self.call_fn(self.context, text);
    }
};

pub const EditorOptions = struct {
    padding_x: usize = 0,
    terminal_rows: usize = 24,
};

pub const EditorComponent = struct {
    context: *anyopaque,
    get_text_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
    set_text_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    handle_input_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    render_fn: *const fn (*anyopaque, std.mem.Allocator, usize) anyerror![][]u8,

    pub fn getText(self: EditorComponent, allocator: std.mem.Allocator) ![]u8 {
        return self.get_text_fn(self.context, allocator);
    }

    pub fn setText(self: EditorComponent, text: []const u8) !void {
        try self.set_text_fn(self.context, text);
    }

    pub fn handleInput(self: EditorComponent, data: []const u8) !void {
        try self.handle_input_fn(self.context, data);
    }

    pub fn render(self: EditorComponent, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        return self.render_fn(self.context, allocator, width);
    }
};

const EditorState = struct {
    lines: [][]u8,
    cursor_line: usize,
    cursor_col: usize,

    fn clone(allocator: std.mem.Allocator, state: EditorState) !EditorState {
        var cloned = try allocator.alloc([]u8, state.lines.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |line| allocator.free(line);
            allocator.free(cloned);
        }
        for (state.lines, 0..) |line, index| {
            cloned[index] = try allocator.dupe(u8, line);
            initialized += 1;
        }

        return .{
            .lines = cloned,
            .cursor_line = state.cursor_line,
            .cursor_col = state.cursor_col,
        };
    }

    fn deinit(allocator: std.mem.Allocator, state: *EditorState) void {
        for (state.lines) |line| allocator.free(line);
        allocator.free(state.lines);
        state.lines = &.{};
    }
};

const LayoutLine = struct {
    text: []const u8,
    has_cursor: bool,
    cursor_pos: usize = 0,
};

const VisualLine = struct {
    logical_line: usize,
    start_col: usize,
    length: usize,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]u8) = .empty,
    cursor_line: usize = 0,
    cursor_col: usize = 0,
    focused: bool = false,
    disable_submit: bool = false,
    on_submit: ?SubmitCallback = null,
    on_change: ?ChangeCallback = null,
    padding_x: usize = 0,
    terminal_rows: usize = 24,
    last_width: usize = 80,
    scroll_offset: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    history_index: isize = -1,
    kill_ring: kill_ring.KillRing,
    last_action: ?LastAction = null,
    undo_stack: undo_stack.UndoStack(EditorState),
    paste_buffer: std.ArrayList(u8) = .empty,
    is_in_paste: bool = false,
    jump_mode: ?JumpMode = null,
    preferred_visual_col: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, options: EditorOptions) !Editor {
        var editor = Editor{
            .allocator = allocator,
            .kill_ring = kill_ring.KillRing.init(allocator),
            .undo_stack = undo_stack.UndoStack(EditorState).init(allocator, EditorState.clone, EditorState.deinit),
            .padding_x = options.padding_x,
            .terminal_rows = options.terminal_rows,
        };
        errdefer editor.deinit();
        try editor.lines.append(allocator, try allocator.dupe(u8, ""));
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        self.freeCurrentLines();
        self.lines.deinit(self.allocator);
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        self.kill_ring.deinit();
        self.undo_stack.deinit();
        self.paste_buffer.deinit(self.allocator);
    }

    pub fn component(self: *Editor) EditorComponent {
        return .{
            .context = self,
            .get_text_fn = componentGetText,
            .set_text_fn = componentSetText,
            .handle_input_fn = componentHandleInput,
            .render_fn = componentRender,
        };
    }

    pub fn getText(self: *const Editor, allocator: std.mem.Allocator) ![]u8 {
        if (self.lines.items.len == 0) return allocator.dupe(u8, "");

        var total: usize = self.lines.items.len - 1;
        for (self.lines.items) |line| total += line.len;

        var text = try allocator.alloc(u8, total);
        var pos: usize = 0;
        for (self.lines.items, 0..) |line, index| {
            if (index > 0) {
                text[pos] = '\n';
                pos += 1;
            }
            @memcpy(text[pos .. pos + line.len], line);
            pos += line.len;
        }
        return text;
    }

    pub fn getExpandedText(self: *const Editor, allocator: std.mem.Allocator) ![]u8 {
        return self.getText(allocator);
    }

    pub fn getLines(self: *const Editor, allocator: std.mem.Allocator) ![][]u8 {
        var cloned = try allocator.alloc([]u8, self.lines.items.len);
        errdefer {
            for (cloned[0..self.lines.items.len]) |line| {
                if (line.len != 0) allocator.free(line);
            }
            allocator.free(cloned);
        }

        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |line| allocator.free(line);
        }
        for (self.lines.items, 0..) |line, index| {
            cloned[index] = try allocator.dupe(u8, line);
            initialized += 1;
        }
        return cloned;
    }

    pub fn getCursor(self: *const Editor) Cursor {
        return .{ .line = self.cursor_line, .col = self.cursor_col };
    }

    pub fn setPaddingX(self: *Editor, padding: usize) void {
        self.padding_x = padding;
    }

    pub fn addToHistory(self: *Editor, text: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[0], trimmed)) return;

        try self.history.insert(self.allocator, 0, try self.allocator.dupe(u8, trimmed));
        if (self.history.items.len > 100) {
            const oldest = self.history.pop().?;
            self.allocator.free(oldest);
        }
    }

    pub fn setText(self: *Editor, text: []const u8) !void {
        self.last_action = null;
        self.history_index = -1;

        const normalized = try normalizeText(self.allocator, text);
        defer self.allocator.free(normalized);

        const current = try self.getText(self.allocator);
        defer self.allocator.free(current);
        if (!std.mem.eql(u8, current, normalized)) {
            try self.pushUndoSnapshot();
        }

        try self.setTextInternal(normalized);
    }

    pub fn insertTextAtCursor(self: *Editor, text: []const u8) !void {
        if (text.len == 0) return;
        self.last_action = null;
        self.history_index = -1;
        try self.pushUndoSnapshot();
        try self.insertTextAtCursorInternal(text);
    }

    pub fn invalidate(_: *Editor) void {}

    pub fn handleInput(self: *Editor, data: []const u8) !void {
        const kb = try keybindings.getKeybindings(self.allocator);

        if (self.jump_mode) |direction| {
            if (kb.matches(data, "tui.editor.jumpForward") or kb.matches(data, "tui.editor.jumpBackward")) {
                self.jump_mode = null;
                return;
            }

            const printable = keys.decodePrintableKey(data) orelse firstPrintableInput(data);
            if (printable) |char| {
                self.jump_mode = null;
                self.jumpToChar(char, direction);
                return;
            }

            self.jump_mode = null;
        }

        if (std.mem.indexOf(u8, data, BRACKETED_PASTE_START)) |start_index| {
            self.is_in_paste = true;
            self.paste_buffer.clearRetainingCapacity();
            if (start_index > 0) try self.handleInput(data[0..start_index]);
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
                if (remaining.len > 0) try self.handleInput(remaining);
            }
            return;
        }

        if (kb.matches(data, "tui.input.copy")) return;

        if (kb.matches(data, "tui.editor.undo")) {
            try self.undo();
            return;
        }

        if (kb.matches(data, "tui.editor.deleteToLineEnd")) {
            try self.deleteToEndOfLine();
            return;
        }
        if (kb.matches(data, "tui.editor.deleteToLineStart")) {
            try self.deleteToStartOfLine();
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
        if (kb.matches(data, "tui.editor.deleteCharBackward") or keys.matchesKey(data, "shift+backspace")) {
            try self.handleBackspace();
            return;
        }
        if (kb.matches(data, "tui.editor.deleteCharForward") or keys.matchesKey(data, "shift+delete")) {
            try self.handleForwardDelete();
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

        if (kb.matches(data, "tui.editor.cursorLineStart")) {
            self.moveToLineStart();
            return;
        }
        if (kb.matches(data, "tui.editor.cursorLineEnd")) {
            self.moveToLineEnd();
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

        if (kb.matches(data, "tui.editor.jumpForward")) {
            self.jump_mode = .forward;
            return;
        }
        if (kb.matches(data, "tui.editor.jumpBackward")) {
            self.jump_mode = .backward;
            return;
        }

        if (kb.matches(data, "tui.input.newLine") or
            std.mem.eql(u8, data, "\n") or
            std.mem.eql(u8, data, "\x1b\r") or
            std.mem.eql(u8, data, "\x1b[13;2~"))
        {
            try self.addNewLine();
            return;
        }

        if (kb.matches(data, "tui.input.submit")) {
            if (self.disable_submit) return;
            const current_line = self.currentLine();
            if (self.cursor_col > 0 and current_line[self.cursor_col - 1] == '\\') {
                try self.handleBackspace();
                try self.addNewLine();
                return;
            }
            try self.submitValue();
            return;
        }

        if (kb.matches(data, "tui.editor.cursorUp")) {
            if (self.isEditorEmpty()) {
                try self.navigateHistory(-1);
            } else if (self.history_index > -1 and self.isOnFirstVisualLine()) {
                try self.navigateHistory(-1);
            } else if (self.isOnFirstVisualLine()) {
                self.moveToLineStart();
            } else {
                self.moveCursorVertical(-1);
            }
            return;
        }
        if (kb.matches(data, "tui.editor.cursorDown")) {
            if (self.history_index > -1 and self.isOnLastVisualLine()) {
                try self.navigateHistory(1);
            } else if (self.isOnLastVisualLine()) {
                self.moveToLineEnd();
            } else {
                self.moveCursorVertical(1);
            }
            return;
        }
        if (kb.matches(data, "tui.editor.cursorRight")) {
            self.moveCursorHorizontal(1);
            return;
        }
        if (kb.matches(data, "tui.editor.cursorLeft")) {
            self.moveCursorHorizontal(-1);
            return;
        }

        if (keys.matchesKey(data, "shift+space")) {
            try self.insertCharacter(" ", false);
            return;
        }

        if (keys.decodePrintableKey(data)) |printable| {
            try self.insertCharacter(printable, false);
            return;
        }

        if (!hasControlChars(data)) {
            try self.insertCharacter(data, false);
        }
    }

    pub fn render(self: *Editor, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        const max_padding = if (width > 0) (width - 1) / 2 else 0;
        const padding_x = @min(self.padding_x, max_padding);
        const content_width = @max(@as(usize, 1), width -| (padding_x * 2));
        const layout_width = @max(@as(usize, 1), content_width - if (padding_x == 0) @as(usize, 1) else @as(usize, 0));
        self.last_width = layout_width;

        const layout_lines = try self.layoutText(allocator, layout_width);
        defer allocator.free(layout_lines);

        const max_visible_lines = @max(@as(usize, 5), self.terminal_rows * 3 / 10);
        var cursor_line_index: usize = 0;
        for (layout_lines, 0..) |line, index| {
            if (line.has_cursor) {
                cursor_line_index = index;
                break;
            }
        }

        if (cursor_line_index < self.scroll_offset) {
            self.scroll_offset = cursor_line_index;
        } else if (cursor_line_index >= self.scroll_offset + max_visible_lines) {
            self.scroll_offset = cursor_line_index - max_visible_lines + 1;
        }
        const max_scroll_offset = if (layout_lines.len > max_visible_lines) layout_lines.len - max_visible_lines else 0;
        self.scroll_offset = @min(self.scroll_offset, max_scroll_offset);

        const visible_start = self.scroll_offset;
        const visible_end = @min(layout_lines.len, visible_start + max_visible_lines);

        var result: std.ArrayList([]u8) = .empty;
        errdefer freeRenderedLines(allocator, result.items);

        try result.append(allocator, try repeatedText(allocator, "─", width));
        const left_padding = try repeatedText(allocator, " ", padding_x);
        defer allocator.free(left_padding);
        const right_padding = left_padding;

        for (layout_lines[visible_start..visible_end]) |layout_line| {
            const line = try self.renderLayoutLine(allocator, layout_line, content_width, left_padding, right_padding);
            errdefer allocator.free(line);
            try result.append(allocator, line);
        }

        try result.append(allocator, try repeatedText(allocator, "─", width));
        return result.toOwnedSlice(allocator);
    }

    fn componentGetText(context: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.getText(allocator);
    }

    fn componentSetText(context: *anyopaque, text: []const u8) !void {
        const self: *Editor = @ptrCast(@alignCast(context));
        try self.setText(text);
    }

    fn componentHandleInput(context: *anyopaque, data: []const u8) !void {
        const self: *Editor = @ptrCast(@alignCast(context));
        try self.handleInput(data);
    }

    fn componentRender(context: *anyopaque, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        const self: *Editor = @ptrCast(@alignCast(context));
        return self.render(allocator, width);
    }

    fn currentLine(self: *const Editor) []const u8 {
        if (self.cursor_line >= self.lines.items.len) return "";
        return self.lines.items[self.cursor_line];
    }

    fn currentLineMut(self: *Editor) *[]u8 {
        return &self.lines.items[self.cursor_line];
    }

    fn isEditorEmpty(self: *const Editor) bool {
        return self.lines.items.len == 1 and self.lines.items[0].len == 0;
    }

    fn isOnFirstVisualLine(self: *Editor) bool {
        const visual_lines = self.buildVisualLineMap(self.allocator, self.last_width) catch return self.cursor_line == 0;
        defer self.allocator.free(visual_lines);
        const current = self.findCurrentVisualLine(visual_lines);
        return current == 0;
    }

    fn isOnLastVisualLine(self: *Editor) bool {
        const visual_lines = self.buildVisualLineMap(self.allocator, self.last_width) catch return self.cursor_line + 1 >= self.lines.items.len;
        defer self.allocator.free(visual_lines);
        const current = self.findCurrentVisualLine(visual_lines);
        return current + 1 >= visual_lines.len;
    }

    fn navigateHistory(self: *Editor, direction: isize) !void {
        self.last_action = null;
        if (self.history.items.len == 0) return;

        const new_index = self.history_index - direction;
        if (new_index < -1 or new_index >= @as(isize, @intCast(self.history.items.len))) return;

        if (self.history_index == -1 and new_index >= 0) {
            try self.pushUndoSnapshot();
        }

        self.history_index = new_index;
        if (self.history_index == -1) {
            try self.setTextInternal("");
        } else {
            try self.setTextInternal(self.history.items[@intCast(self.history_index)]);
        }
    }

    fn setTextInternal(self: *Editor, text: []const u8) !void {
        self.freeCurrentLines();
        self.lines.clearRetainingCapacity();

        var splitter = std.mem.splitScalar(u8, text, '\n');
        var count: usize = 0;
        while (splitter.next()) |line| {
            try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
            count += 1;
        }
        if (count == 0) try self.lines.append(self.allocator, try self.allocator.dupe(u8, ""));

        self.cursor_line = self.lines.items.len - 1;
        self.setCursorCol(self.lines.items[self.cursor_line].len);
        self.scroll_offset = 0;
        try self.emitChange();
    }

    fn insertCharacter(self: *Editor, char: []const u8, skip_undo_coalescing: bool) !void {
        self.history_index = -1;
        if (!skip_undo_coalescing) {
            if (isWhitespaceText(char) or self.last_action != .type_word) {
                try self.pushUndoSnapshot();
            }
            self.last_action = .type_word;
        }

        const line = self.currentLine();
        const before = line[0..self.cursor_col];
        const after = line[self.cursor_col..];
        const replacement = try std.mem.concat(self.allocator, u8, &.{ before, char, after });
        self.allocator.free(self.currentLineMut().*);
        self.currentLineMut().* = replacement;
        self.setCursorCol(self.cursor_col + char.len);
        try self.emitChange();
    }

    fn handlePaste(self: *Editor, pasted_text: []const u8) !void {
        self.history_index = -1;
        self.last_action = null;
        try self.pushUndoSnapshot();

        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        var index: usize = 0;
        while (index < pasted_text.len) {
            if (decodeCsiUControl(pasted_text, index)) |decoded_control| {
                try decoded.append(self.allocator, decoded_control.byte);
                index += decoded_control.len;
                continue;
            }
            try decoded.append(self.allocator, pasted_text[index]);
            index += 1;
        }

        const normalized = try normalizeText(self.allocator, decoded.items);
        defer self.allocator.free(normalized);

        var filtered: std.ArrayList(u8) = .empty;
        defer filtered.deinit(self.allocator);
        var pos: usize = 0;
        while (pos < normalized.len) {
            const decoded_cp = decodeAt(normalized, pos) orelse {
                pos += 1;
                continue;
            };
            if (decoded_cp.codepoint == '\n' or decoded_cp.codepoint >= 32) {
                try filtered.appendSlice(self.allocator, normalized[pos .. pos + decoded_cp.len]);
            }
            pos += decoded_cp.len;
        }

        try self.insertTextAtCursorInternal(filtered.items);
    }

    fn insertTextAtCursorInternal(self: *Editor, text: []const u8) !void {
        if (text.len == 0) return;
        const normalized = try normalizeText(self.allocator, text);
        defer self.allocator.free(normalized);

        var inserted_lines: std.ArrayList([]const u8) = .empty;
        defer inserted_lines.deinit(self.allocator);
        var splitter = std.mem.splitScalar(u8, normalized, '\n');
        while (splitter.next()) |line| try inserted_lines.append(self.allocator, line);

        const current_line = self.currentLine();
        const before_cursor = current_line[0..self.cursor_col];
        const after_cursor = current_line[self.cursor_col..];

        if (inserted_lines.items.len <= 1) {
            const replacement = try std.mem.concat(self.allocator, u8, &.{ before_cursor, normalized, after_cursor });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(self.cursor_col + normalized.len);
        } else {
            var new_lines: std.ArrayList([]u8) = .empty;
            errdefer {
                for (new_lines.items) |line| self.allocator.free(line);
                new_lines.deinit(self.allocator);
            }

            for (self.lines.items[0..self.cursor_line]) |line| {
                try new_lines.append(self.allocator, try self.allocator.dupe(u8, line));
            }

            try new_lines.append(self.allocator, try std.mem.concat(self.allocator, u8, &.{ before_cursor, inserted_lines.items[0] }));
            if (inserted_lines.items.len > 2) {
                for (inserted_lines.items[1 .. inserted_lines.items.len - 1]) |line| {
                    try new_lines.append(self.allocator, try self.allocator.dupe(u8, line));
                }
            }
            const last_inserted = inserted_lines.items[inserted_lines.items.len - 1];
            try new_lines.append(self.allocator, try std.mem.concat(self.allocator, u8, &.{ last_inserted, after_cursor }));

            if (self.cursor_line + 1 < self.lines.items.len) {
                for (self.lines.items[self.cursor_line + 1 ..]) |line| {
                    try new_lines.append(self.allocator, try self.allocator.dupe(u8, line));
                }
            }

            self.freeCurrentLines();
            self.lines.deinit(self.allocator);
            self.lines = new_lines;
            self.cursor_line += inserted_lines.items.len - 1;
            self.setCursorCol(last_inserted.len);
        }

        try self.emitChange();
    }

    fn addNewLine(self: *Editor) !void {
        self.history_index = -1;
        self.last_action = null;
        try self.pushUndoSnapshot();

        const current_line = self.currentLine();
        const before = try self.allocator.dupe(u8, current_line[0..self.cursor_col]);
        errdefer self.allocator.free(before);
        const after = try self.allocator.dupe(u8, current_line[self.cursor_col..]);
        errdefer self.allocator.free(after);

        self.allocator.free(self.currentLineMut().*);
        self.currentLineMut().* = before;
        try self.lines.insert(self.allocator, self.cursor_line + 1, after);
        self.cursor_line += 1;
        self.setCursorCol(0);
        try self.emitChange();
    }

    fn submitValue(self: *Editor) !void {
        const text = try self.getExpandedText(self.allocator);
        defer self.allocator.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");

        self.freeCurrentLines();
        self.lines.clearRetainingCapacity();
        try self.lines.append(self.allocator, try self.allocator.dupe(u8, ""));
        self.cursor_line = 0;
        self.cursor_col = 0;
        self.history_index = -1;
        self.scroll_offset = 0;
        self.undo_stack.clear();
        self.last_action = null;

        try self.emitChange();
        if (self.on_submit) |callback| callback.call(trimmed);
    }

    fn handleBackspace(self: *Editor) !void {
        self.history_index = -1;
        self.last_action = null;

        if (self.cursor_col > 0) {
            try self.pushUndoSnapshot();
            const line = self.currentLine();
            const start = prevGraphemeStart(line, self.cursor_col);
            const replacement = try std.mem.concat(self.allocator, u8, &.{ line[0..start], line[self.cursor_col..] });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(start);
        } else if (self.cursor_line > 0) {
            try self.pushUndoSnapshot();
            const current_line = self.lines.orderedRemove(self.cursor_line);
            defer self.allocator.free(current_line);
            self.cursor_line -= 1;
            const previous = self.currentLine();
            const previous_len = previous.len;
            const replacement = try std.mem.concat(self.allocator, u8, &.{ previous, current_line });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(previous_len);
        } else {
            return;
        }

        try self.emitChange();
    }

    fn handleForwardDelete(self: *Editor) !void {
        self.history_index = -1;
        self.last_action = null;

        const line = self.currentLine();
        if (self.cursor_col < line.len) {
            try self.pushUndoSnapshot();
            const end = nextGraphemeEnd(line, self.cursor_col);
            const replacement = try std.mem.concat(self.allocator, u8, &.{ line[0..self.cursor_col], line[end..] });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
        } else if (self.cursor_line + 1 < self.lines.items.len) {
            try self.pushUndoSnapshot();
            const next_line = self.lines.orderedRemove(self.cursor_line + 1);
            defer self.allocator.free(next_line);
            const replacement = try std.mem.concat(self.allocator, u8, &.{ line, next_line });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
        } else {
            return;
        }

        try self.emitChange();
    }

    fn deleteToStartOfLine(self: *Editor) !void {
        self.history_index = -1;
        const current_line = self.currentLine();
        if (self.cursor_col > 0) {
            try self.pushUndoSnapshot();
            try self.kill_ring.push(current_line[0..self.cursor_col], .{ .prepend = true, .accumulate = self.last_action == .kill });
            self.last_action = .kill;

            const replacement = try self.allocator.dupe(u8, current_line[self.cursor_col..]);
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(0);
        } else if (self.cursor_line > 0) {
            try self.pushUndoSnapshot();
            try self.kill_ring.push("\n", .{ .prepend = true, .accumulate = self.last_action == .kill });
            self.last_action = .kill;

            const current = self.lines.orderedRemove(self.cursor_line);
            defer self.allocator.free(current);
            self.cursor_line -= 1;
            const previous = self.currentLine();
            const previous_len = previous.len;
            const replacement = try std.mem.concat(self.allocator, u8, &.{ previous, current });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(previous_len);
        } else {
            return;
        }
        try self.emitChange();
    }

    fn deleteToEndOfLine(self: *Editor) !void {
        self.history_index = -1;
        const current_line = self.currentLine();
        if (self.cursor_col < current_line.len) {
            try self.pushUndoSnapshot();
            try self.kill_ring.push(current_line[self.cursor_col..], .{ .prepend = false, .accumulate = self.last_action == .kill });
            self.last_action = .kill;

            const replacement = try self.allocator.dupe(u8, current_line[0..self.cursor_col]);
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
        } else if (self.cursor_line + 1 < self.lines.items.len) {
            try self.pushUndoSnapshot();
            try self.kill_ring.push("\n", .{ .prepend = false, .accumulate = self.last_action == .kill });
            self.last_action = .kill;

            const next_line = self.lines.orderedRemove(self.cursor_line + 1);
            defer self.allocator.free(next_line);
            const replacement = try std.mem.concat(self.allocator, u8, &.{ current_line, next_line });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
        } else {
            return;
        }
        try self.emitChange();
    }

    fn deleteWordBackwards(self: *Editor) !void {
        self.history_index = -1;
        const current_line = self.currentLine();
        if (self.cursor_col == 0) {
            if (self.cursor_line == 0) return;
            try self.pushUndoSnapshot();
            try self.kill_ring.push("\n", .{ .prepend = true, .accumulate = self.last_action == .kill });
            self.last_action = .kill;

            const current = self.lines.orderedRemove(self.cursor_line);
            defer self.allocator.free(current);
            self.cursor_line -= 1;
            const previous = self.currentLine();
            const previous_len = previous.len;
            const replacement = try std.mem.concat(self.allocator, u8, &.{ previous, current });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(previous_len);
        } else {
            try self.pushUndoSnapshot();
            const was_kill = self.last_action == .kill;
            const delete_from = findWordBackwardEditor(current_line, self.cursor_col);
            try self.kill_ring.push(current_line[delete_from..self.cursor_col], .{ .prepend = true, .accumulate = was_kill });
            self.last_action = .kill;

            const replacement = try std.mem.concat(self.allocator, u8, &.{ current_line[0..delete_from], current_line[self.cursor_col..] });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(delete_from);
        }
        try self.emitChange();
    }

    fn deleteWordForward(self: *Editor) !void {
        self.history_index = -1;
        const current_line = self.currentLine();
        if (self.cursor_col >= current_line.len) {
            if (self.cursor_line + 1 >= self.lines.items.len) return;
            try self.pushUndoSnapshot();
            try self.kill_ring.push("\n", .{ .prepend = false, .accumulate = self.last_action == .kill });
            self.last_action = .kill;

            const next_line = self.lines.orderedRemove(self.cursor_line + 1);
            defer self.allocator.free(next_line);
            const replacement = try std.mem.concat(self.allocator, u8, &.{ current_line, next_line });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
        } else {
            try self.pushUndoSnapshot();
            const was_kill = self.last_action == .kill;
            const delete_to = findWordForwardEditor(current_line, self.cursor_col);
            try self.kill_ring.push(current_line[self.cursor_col..delete_to], .{ .prepend = false, .accumulate = was_kill });
            self.last_action = .kill;

            const replacement = try std.mem.concat(self.allocator, u8, &.{ current_line[0..self.cursor_col], current_line[delete_to..] });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
        }
        try self.emitChange();
    }

    fn yank(self: *Editor) !void {
        const text = self.kill_ring.peek() orelse return;
        try self.pushUndoSnapshot();
        try self.insertYankedText(text);
        self.last_action = .yank;
    }

    fn yankPop(self: *Editor) !void {
        if (self.last_action != .yank or self.kill_ring.len() <= 1) return;
        try self.pushUndoSnapshot();
        try self.deleteYankedText();
        self.kill_ring.rotate();
        const text = self.kill_ring.peek() orelse return;
        try self.insertYankedText(text);
        self.last_action = .yank;
    }

    fn insertYankedText(self: *Editor, text: []const u8) !void {
        self.history_index = -1;
        try self.insertTextAtCursorInternal(text);
    }

    fn deleteYankedText(self: *Editor) !void {
        const text = self.kill_ring.peek() orelse return;
        var yank_lines: std.ArrayList([]const u8) = .empty;
        defer yank_lines.deinit(self.allocator);
        var splitter = std.mem.splitScalar(u8, text, '\n');
        while (splitter.next()) |line| try yank_lines.append(self.allocator, line);

        if (yank_lines.items.len <= 1) {
            const line = self.currentLine();
            const delete_len = @min(text.len, self.cursor_col);
            const start = self.cursor_col - delete_len;
            const replacement = try std.mem.concat(self.allocator, u8, &.{ line[0..start], line[self.cursor_col..] });
            self.allocator.free(self.currentLineMut().*);
            self.currentLineMut().* = replacement;
            self.setCursorCol(start);
        } else {
            const start_line = self.cursor_line - (yank_lines.items.len - 1);
            const first_len = yank_lines.items[0].len;
            const start_col = self.lines.items[start_line].len - first_len;
            const after_cursor = self.currentLine()[self.cursor_col..];
            const before_yank = self.lines.items[start_line][0..start_col];
            const merged = try std.mem.concat(self.allocator, u8, &.{ before_yank, after_cursor });

            for (self.lines.items[start_line .. self.cursor_line + 1]) |line| self.allocator.free(line);
            self.lines.replaceRangeAssumeCapacity(start_line, yank_lines.items.len, &.{merged});
            self.cursor_line = start_line;
            self.setCursorCol(start_col);
        }
        try self.emitChange();
    }

    fn pushUndoSnapshot(self: *Editor) !void {
        try self.undo_stack.push(self.snapshot());
    }

    fn undo(self: *Editor) !void {
        self.history_index = -1;
        var popped_state = self.undo_stack.pop() orelse return;
        defer EditorState.deinit(self.allocator, &popped_state);

        self.freeCurrentLines();
        self.lines.clearRetainingCapacity();
        for (popped_state.lines) |line| {
            try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
        self.cursor_line = @min(popped_state.cursor_line, self.lines.items.len - 1);
        self.setCursorCol(popped_state.cursor_col);
        self.last_action = null;
        self.preferred_visual_col = null;
        try self.emitChange();
    }

    fn snapshot(self: *const Editor) EditorState {
        return .{
            .lines = self.lines.items,
            .cursor_line = self.cursor_line,
            .cursor_col = self.cursor_col,
        };
    }

    fn moveToLineStart(self: *Editor) void {
        self.last_action = null;
        self.setCursorCol(0);
    }

    fn moveToLineEnd(self: *Editor) void {
        self.last_action = null;
        self.setCursorCol(self.currentLine().len);
    }

    fn moveWordBackwards(self: *Editor) void {
        self.last_action = null;
        if (self.cursor_col == 0) {
            if (self.cursor_line > 0) {
                self.cursor_line -= 1;
                self.setCursorCol(self.currentLine().len);
            }
            return;
        }
        self.setCursorCol(findWordBackwardEditor(self.currentLine(), self.cursor_col));
    }

    fn moveWordForwards(self: *Editor) void {
        self.last_action = null;
        if (self.cursor_col >= self.currentLine().len) {
            if (self.cursor_line + 1 < self.lines.items.len) {
                self.cursor_line += 1;
                self.setCursorCol(0);
            }
            return;
        }
        self.setCursorCol(findWordForwardEditor(self.currentLine(), self.cursor_col));
    }

    fn jumpToChar(self: *Editor, char: []const u8, direction: JumpMode) void {
        self.last_action = null;
        if (char.len == 0 or self.lines.items.len == 0) return;

        switch (direction) {
            .forward => {
                var line_index = self.cursor_line;
                while (line_index < self.lines.items.len) : (line_index += 1) {
                    const line = self.lines.items[line_index];
                    const search_from = if (line_index == self.cursor_line) @min(self.cursor_col + 1, line.len) else 0;
                    if (std.mem.indexOfPos(u8, line, search_from, char)) |match_index| {
                        self.cursor_line = line_index;
                        self.setCursorCol(match_index);
                        return;
                    }
                }
            },
            .backward => {
                var line_index: isize = @intCast(self.cursor_line);
                while (line_index >= 0) : (line_index -= 1) {
                    const current_index: usize = @intCast(line_index);
                    const line = self.lines.items[current_index];
                    const search_from = if (current_index == self.cursor_line)
                        if (self.cursor_col == 0) null else self.cursor_col - 1
                    else
                        line.len;
                    if (search_from) |from| {
                        if (lastIndexOfAtOrBefore(line, char, from)) |match_index| {
                            self.cursor_line = current_index;
                            self.setCursorCol(match_index);
                            return;
                        }
                    }
                }
            },
        }
    }

    fn moveCursorHorizontal(self: *Editor, direction: i32) void {
        self.last_action = null;
        const line = self.currentLine();
        if (direction > 0) {
            if (self.cursor_col < line.len) {
                self.setCursorCol(nextGraphemeEnd(line, self.cursor_col));
            } else if (self.cursor_line + 1 < self.lines.items.len) {
                self.cursor_line += 1;
                self.setCursorCol(0);
            } else {
                self.preferred_visual_col = self.cursor_col;
            }
        } else {
            if (self.cursor_col > 0) {
                self.setCursorCol(prevGraphemeStart(line, self.cursor_col));
            } else if (self.cursor_line > 0) {
                self.cursor_line -= 1;
                self.setCursorCol(self.currentLine().len);
            }
        }
    }

    fn moveCursorVertical(self: *Editor, direction: i32) void {
        self.last_action = null;
        const visual_lines = self.buildVisualLineMap(self.allocator, self.last_width) catch return;
        defer self.allocator.free(visual_lines);
        if (visual_lines.len == 0) return;

        const current = self.findCurrentVisualLine(visual_lines);
        if (direction < 0 and current == 0) return;
        if (direction > 0 and current + 1 >= visual_lines.len) return;
        const target_index = if (direction < 0) current - 1 else current + 1;
        const current_vl = visual_lines[current];
        const target_vl = visual_lines[target_index];
        const current_visual_col = self.cursor_col -| current_vl.start_col;
        const target_col = target_vl.start_col + @min(current_visual_col, target_vl.length);
        self.cursor_line = target_vl.logical_line;
        self.setCursorCol(target_col);
    }

    fn setCursorCol(self: *Editor, col: usize) void {
        const line = self.currentLine();
        self.cursor_col = clampToUtf8Boundary(line, @min(col, line.len));
        self.preferred_visual_col = null;
    }

    fn buildVisualLineMap(self: *Editor, allocator: std.mem.Allocator, width: usize) ![]VisualLine {
        var visual_lines: std.ArrayList(VisualLine) = .empty;
        errdefer visual_lines.deinit(allocator);

        for (self.lines.items, 0..) |line, logical_line| {
            if (line.len == 0) {
                try visual_lines.append(allocator, .{ .logical_line = logical_line, .start_col = 0, .length = 0 });
            } else if (visibleWidth(line) <= width) {
                try visual_lines.append(allocator, .{ .logical_line = logical_line, .start_col = 0, .length = line.len });
            } else {
                const chunks = try wordWrapLine(allocator, line, width, null);
                defer allocator.free(chunks);
                for (chunks) |chunk| {
                    try visual_lines.append(allocator, .{
                        .logical_line = logical_line,
                        .start_col = chunk.start_index,
                        .length = chunk.end_index - chunk.start_index,
                    });
                }
            }
        }

        return visual_lines.toOwnedSlice(allocator);
    }

    fn findCurrentVisualLine(self: *const Editor, visual_lines: []const VisualLine) usize {
        return self.findVisualLineAt(visual_lines, self.cursor_line, self.cursor_col);
    }

    fn findVisualLineAt(_: *const Editor, visual_lines: []const VisualLine, line: usize, col: usize) usize {
        for (visual_lines, 0..) |vl, index| {
            if (vl.logical_line != line) continue;
            const offset = col -| vl.start_col;
            const is_last_segment = index + 1 >= visual_lines.len or visual_lines[index + 1].logical_line != vl.logical_line;
            if (col >= vl.start_col and (offset < vl.length or (is_last_segment and offset == vl.length))) {
                return index;
            }
        }
        return if (visual_lines.len == 0) 0 else visual_lines.len - 1;
    }

    fn layoutText(self: *Editor, allocator: std.mem.Allocator, content_width: usize) ![]LayoutLine {
        var layout_lines: std.ArrayList(LayoutLine) = .empty;
        errdefer layout_lines.deinit(allocator);

        if (self.isEditorEmpty()) {
            try layout_lines.append(allocator, .{ .text = "", .has_cursor = true, .cursor_pos = 0 });
            return layout_lines.toOwnedSlice(allocator);
        }

        for (self.lines.items, 0..) |line, line_index| {
            const is_current_line = line_index == self.cursor_line;
            if (visibleWidth(line) <= content_width) {
                try layout_lines.append(allocator, .{
                    .text = line,
                    .has_cursor = is_current_line,
                    .cursor_pos = if (is_current_line) self.cursor_col else 0,
                });
                continue;
            }

            const chunks = try wordWrapLine(allocator, line, content_width, null);
            defer allocator.free(chunks);
            for (chunks, 0..) |chunk, chunk_index| {
                const is_last_chunk = chunk_index + 1 == chunks.len;
                var has_cursor = false;
                var adjusted_cursor: usize = 0;
                if (is_current_line) {
                    if (is_last_chunk) {
                        has_cursor = self.cursor_col >= chunk.start_index;
                        adjusted_cursor = self.cursor_col -| chunk.start_index;
                    } else {
                        has_cursor = self.cursor_col >= chunk.start_index and self.cursor_col < chunk.end_index;
                        adjusted_cursor = @min(self.cursor_col -| chunk.start_index, chunk.text.len);
                    }
                }
                try layout_lines.append(allocator, .{
                    .text = chunk.text,
                    .has_cursor = has_cursor,
                    .cursor_pos = adjusted_cursor,
                });
            }
        }

        return layout_lines.toOwnedSlice(allocator);
    }

    fn renderLayoutLine(
        self: *const Editor,
        allocator: std.mem.Allocator,
        layout_line: LayoutLine,
        content_width: usize,
        left_padding: []const u8,
        right_padding: []const u8,
    ) ![]u8 {
        var display: std.ArrayList(u8) = .empty;
        defer display.deinit(allocator);
        try display.appendSlice(allocator, layout_line.text);
        var line_visible_width = visibleWidth(layout_line.text);

        if (layout_line.has_cursor) {
            const cursor_pos = clampToUtf8Boundary(display.items, @min(layout_line.cursor_pos, display.items.len));
            var with_cursor: std.ArrayList(u8) = .empty;
            errdefer with_cursor.deinit(allocator);
            try with_cursor.appendSlice(allocator, display.items[0..cursor_pos]);
            if (self.focused) try with_cursor.appendSlice(allocator, CURSOR_MARKER);
            if (cursor_pos < display.items.len) {
                const cursor_end = nextGraphemeEnd(display.items, cursor_pos);
                try with_cursor.appendSlice(allocator, "\x1b[7m");
                try with_cursor.appendSlice(allocator, display.items[cursor_pos..cursor_end]);
                try with_cursor.appendSlice(allocator, RESET);
                try with_cursor.appendSlice(allocator, display.items[cursor_end..]);
            } else {
                try with_cursor.appendSlice(allocator, "\x1b[7m \x1b[0m");
                line_visible_width += 1;
            }
            display.deinit(allocator);
            display = with_cursor;
        }

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, left_padding);
        try output.appendSlice(allocator, display.items);
        try appendSpaces(allocator, &output, content_width -| line_visible_width);
        try output.appendSlice(allocator, right_padding);
        return output.toOwnedSlice(allocator);
    }

    fn emitChange(self: *Editor) !void {
        if (self.on_change) |callback| {
            const text = try self.getText(self.allocator);
            defer self.allocator.free(text);
            callback.call(text);
        }
    }

    fn freeCurrentLines(self: *Editor) void {
        for (self.lines.items) |line| self.allocator.free(line);
    }
};

pub fn wordWrapLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    max_width: usize,
    pre_segmented: ?[]const SegmentData,
) ![]TextChunk {
    if (line.len == 0 or max_width == 0) {
        const chunks = try allocator.alloc(TextChunk, 1);
        chunks[0] = .{ .text = "", .start_index = 0, .end_index = 0 };
        return chunks;
    }

    if (visibleWidth(line) <= max_width) {
        const chunks = try allocator.alloc(TextChunk, 1);
        chunks[0] = .{ .text = line, .start_index = 0, .end_index = line.len };
        return chunks;
    }

    const owned_segments = if (pre_segmented == null) try segmentGraphemes(allocator, line) else null;
    defer if (owned_segments) |segments| allocator.free(segments);
    const segments = pre_segmented orelse owned_segments.?;

    var chunks_list: std.ArrayList(TextChunk) = .empty;
    errdefer chunks_list.deinit(allocator);

    var current_width: usize = 0;
    var chunk_start: usize = 0;
    var wrap_opp_index: ?usize = null;
    var wrap_opp_width: usize = 0;

    var i: usize = 0;
    while (i < segments.len) : (i += 1) {
        const seg = segments[i];
        const grapheme = seg.segment;
        const g_width = visibleWidth(grapheme);
        const char_index = seg.index;
        const is_ws = !isPasteMarker(grapheme) and isWhitespaceText(grapheme);

        if (current_width + g_width > max_width) {
            if (wrap_opp_index) |opp_index| {
                if (current_width - wrap_opp_width + g_width <= max_width) {
                    try chunks_list.append(allocator, .{
                        .text = line[chunk_start..opp_index],
                        .start_index = chunk_start,
                        .end_index = opp_index,
                    });
                    chunk_start = opp_index;
                    current_width -= wrap_opp_width;
                } else if (chunk_start < char_index) {
                    try chunks_list.append(allocator, .{
                        .text = line[chunk_start..char_index],
                        .start_index = chunk_start,
                        .end_index = char_index,
                    });
                    chunk_start = char_index;
                    current_width = 0;
                }
            } else if (chunk_start < char_index) {
                try chunks_list.append(allocator, .{
                    .text = line[chunk_start..char_index],
                    .start_index = chunk_start,
                    .end_index = char_index,
                });
                chunk_start = char_index;
                current_width = 0;
            }
            wrap_opp_index = null;
        }

        if (g_width > max_width) {
            const sub_chunks = try wordWrapLine(allocator, grapheme, max_width, null);
            defer allocator.free(sub_chunks);
            if (sub_chunks.len > 1) {
                for (sub_chunks[0 .. sub_chunks.len - 1]) |sub_chunk| {
                    try chunks_list.append(allocator, .{
                        .text = line[char_index + sub_chunk.start_index .. char_index + sub_chunk.end_index],
                        .start_index = char_index + sub_chunk.start_index,
                        .end_index = char_index + sub_chunk.end_index,
                    });
                }
            }
            const last = sub_chunks[sub_chunks.len - 1];
            chunk_start = char_index + last.start_index;
            current_width = visibleWidth(last.text);
            wrap_opp_index = null;
            continue;
        }

        current_width += g_width;
        if (i + 1 < segments.len) {
            const next = segments[i + 1];
            if (is_ws and (isPasteMarker(next.segment) or !isWhitespaceText(next.segment))) {
                wrap_opp_index = next.index;
                wrap_opp_width = current_width;
            }
        }
    }

    try chunks_list.append(allocator, .{
        .text = line[chunk_start..],
        .start_index = chunk_start,
        .end_index = line.len,
    });
    return chunks_list.toOwnedSlice(allocator);
}

pub fn visibleWidth(input: []const u8) usize {
    if (input.len == 0) return 0;

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

fn normalizeText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\r') {
            if (index + 1 < text.len and text[index + 1] == '\n') index += 1;
            try normalized.append(allocator, '\n');
        } else if (text[index] == '\t') {
            try normalized.appendSlice(allocator, "    ");
        } else {
            try normalized.append(allocator, text[index]);
        }
        index += 1;
    }
    return normalized.toOwnedSlice(allocator);
}

fn segmentGraphemes(allocator: std.mem.Allocator, text: []const u8) ![]SegmentData {
    var segments: std.ArrayList(SegmentData) = .empty;
    errdefer segments.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const end = nextGraphemeEnd(text, index);
        if (end <= index) {
            index += 1;
            continue;
        }
        try segments.append(allocator, .{ .segment = text[index..end], .index = index });
        index = end;
    }
    return segments.toOwnedSlice(allocator);
}

fn isPasteMarker(segment: []const u8) bool {
    if (!std.mem.startsWith(u8, segment, "[paste #") or !std.mem.endsWith(u8, segment, "]")) return false;
    return std.mem.indexOfScalar(u8, segment, '#') != null;
}

fn extractAnsiCode(input: []const u8, pos: usize) ?struct { code: []const u8, length: usize } {
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
            if (input[end] == BEL) return .{ .code = input[pos .. end + 1], .length = end + 1 - pos };
            if (input[end] == ESC and end + 1 < input.len and input[end + 1] == '\\') {
                return .{ .code = input[pos .. end + 2], .length = end + 2 - pos };
            }
        }
    }
    return null;
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

fn nextGraphemeEnd(input: []const u8, start: usize) usize {
    const first = decodeAt(input, start) orelse return @min(input.len, start + 1);
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
        join_next = cp == 0x200d;
        if (isRegionalIndicator(cp)) regional_count += 1;
    }
    return end;
}

fn prevGraphemeStart(input: []const u8, cursor: usize) usize {
    const target = @min(cursor, input.len);
    if (target == 0) return 0;
    var index: usize = 0;
    var previous: usize = 0;
    while (index < target) {
        previous = index;
        const next = nextGraphemeEnd(input, index);
        if (next >= target or next <= index) return previous;
        index = next;
    }
    return previous;
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

fn firstPrintableInput(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    const decoded = decodeAt(data, 0) orelse return null;
    return if (decoded.codepoint >= 32) data else null;
}

fn lastIndexOfAtOrBefore(haystack: []const u8, needle: []const u8, search_from: usize) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    const max_start = @min(search_from, haystack.len - needle.len);
    var start = max_start + 1;
    while (start > 0) {
        start -= 1;
        if (std.mem.eql(u8, haystack[start .. start + needle.len], needle)) return start;
    }
    return null;
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

fn findWordBackwardEditor(text: []const u8, cursor: usize) usize {
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

fn findWordForwardEditor(text: []const u8, cursor: usize) usize {
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

fn prevCodepointStart(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var start = @min(cursor, text.len) - 1;
    while (start > 0 and (text[start] & 0xc0) == 0x80) start -= 1;
    return start;
}

fn clampToUtf8Boundary(text: []const u8, cursor: usize) usize {
    var index = @min(cursor, text.len);
    if (index >= text.len) return text.len;
    while (index > 0 and (text[index] & 0xc0) == 0x80) index -= 1;
    return index;
}

fn appendSpaces(allocator: std.mem.Allocator, output: *std.ArrayList(u8), count: usize) !void {
    try output.ensureUnusedCapacity(allocator, count);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) output.appendAssumeCapacity(' ');
}

fn repeatedText(allocator: std.mem.Allocator, text: []const u8, count: usize) ![]u8 {
    var output = try std.ArrayList(u8).initCapacity(allocator, text.len * count);
    errdefer output.deinit(allocator);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) try output.appendSlice(allocator, text);
    return output.toOwnedSlice(allocator);
}

fn freeRenderedLines(allocator: std.mem.Allocator, lines: []const []u8) void {
    for (lines) |line| allocator.free(line);
}

pub fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

const DecodedControl = struct {
    byte: u8,
    len: usize,
};

fn decodeCsiUControl(text: []const u8, index: usize) ?DecodedControl {
    if (index >= text.len or text[index] != ESC) return null;
    if (!std.mem.startsWith(u8, text[index..], "\x1b[")) return null;
    const end = std.mem.indexOfScalarPos(u8, text, index + 2, 'u') orelse return null;
    const body = text[index + 2 .. end];
    const semi = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    if (!std.mem.eql(u8, body[semi + 1 ..], "5")) return null;
    const cp = std.fmt.parseInt(u21, body[0..semi], 10) catch return null;
    if (cp >= 'a' and cp <= 'z') return .{ .byte = @intCast(cp - 96), .len = end + 1 - index };
    if (cp >= 'A' and cp <= 'Z') return .{ .byte = @intCast(cp - 64), .len = end + 1 - index };
    return null;
}

fn expectText(editor: *const Editor, expected: []const u8) !void {
    const actual = try editor.getText(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectChunks(chunks: []const TextChunk, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, chunks.len);
    for (expected, 0..) |text, index| {
        try std.testing.expectEqualStrings(text, chunks[index].text);
    }
}

fn strippedContains(line: []const u8, needle: []const u8) bool {
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(std.testing.allocator);
    var index: usize = 0;
    while (index < line.len) {
        if (extractAnsiCode(line, index)) |ansi| {
            index += ansi.length;
            continue;
        }
        stripped.append(std.testing.allocator, line[index]) catch return false;
        index += 1;
    }
    return std.mem.indexOf(u8, stripped.items, needle) != null;
}

test "Editor prompt history navigation" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.handleInput("\x1b[A");
    try expectText(&editor, "");

    try editor.addToHistory("first prompt");
    try editor.addToHistory("second prompt");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "second prompt");

    try editor.addToHistory("third prompt");
    try editor.setText("");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "third prompt");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "second prompt");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "first prompt");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "first prompt");

    try editor.handleInput("\x1b[B");
    try expectText(&editor, "second prompt");
    try editor.handleInput("\x1b[B");
    try expectText(&editor, "third prompt");
    try editor.handleInput("\x1b[B");
    try expectText(&editor, "");
}

test "Editor history filters blanks, consecutive duplicates, and caps at 100" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.addToHistory("");
    try editor.addToHistory("   ");
    try editor.addToHistory("valid");
    try editor.addToHistory("valid");
    try editor.addToHistory("other");
    try editor.addToHistory("valid");

    try editor.handleInput("\x1b[A");
    try expectText(&editor, "valid");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "other");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "valid");

    var capped = try Editor.init(allocator, .{});
    defer capped.deinit();
    var index: usize = 0;
    while (index < 105) : (index += 1) {
        const prompt = try std.fmt.allocPrint(allocator, "prompt {d}", .{index});
        defer allocator.free(prompt);
        try capped.addToHistory(prompt);
    }
    index = 0;
    while (index < 100) : (index += 1) try capped.handleInput("\x1b[A");
    try expectText(&capped, "prompt 5");
    try capped.handleInput("\x1b[A");
    try expectText(&capped, "prompt 5");
}

test "Editor history cooperates with multiline cursor movement" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.addToHistory("older entry");
    try editor.addToHistory("line1\nline2\nline3");
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "line1\nline2\nline3");

    try editor.handleInput("\x1b[A");
    try std.testing.expectEqual(Cursor{ .line = 1, .col = 5 }, editor.getCursor());
    try editor.handleInput("\x1b[A");
    try std.testing.expectEqual(Cursor{ .line = 0, .col = 5 }, editor.getCursor());
    try editor.handleInput("\x1b[A");
    try expectText(&editor, "older entry");

    try editor.setText("line1\nline2");
    try editor.handleInput("\x1b[A");
    try editor.handleInput("X");
    try expectText(&editor, "line1X\nline2");
}

test "Editor public state accessors" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
    try editor.handleInput("a");
    try editor.handleInput("b");
    try editor.handleInput("c");
    try std.testing.expectEqual(Cursor{ .line = 0, .col = 3 }, editor.getCursor());
    try editor.handleInput("\x1b[D");
    try std.testing.expectEqual(Cursor{ .line = 0, .col = 2 }, editor.getCursor());

    try editor.setText("a\nb");
    const lines = try editor.getLines(allocator);
    defer freeLines(allocator, lines);
    try std.testing.expectEqualStrings("a", lines[0]);
    lines[0][0] = 'z';
    const again = try editor.getLines(allocator);
    defer freeLines(allocator, again);
    try std.testing.expectEqualStrings("a", again[0]);
}

test "Editor backslash enter newline workaround" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.handleInput("\\");
    try expectText(&editor, "\\");
    try editor.handleInput("\r");
    try expectText(&editor, "\n");

    try editor.setText("");
    try editor.handleInput("\\");
    try editor.handleInput("x");
    try expectText(&editor, "\\x");

    try editor.setText("");
    try editor.handleInput("\\");
    try editor.handleInput("\\");
    try editor.handleInput("\\");
    try editor.handleInput("\r");
    try expectText(&editor, "\\\\\n");
}

test "Editor printable CSI-u handling" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.handleInput("\x1b[99;9u");
    try expectText(&editor, "");

    try editor.handleInput("\x1b[69;2u");
    try expectText(&editor, "E");

    try editor.setText("");
    try editor.handleInput("\x1b[27;2;69~");
    try expectText(&editor, "E");
}

test "Editor unicode insertion deletion and cursor movement" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.handleInput("Hello äöü 😀");
    try expectText(&editor, "Hello äöü 😀");

    try editor.setText("äöü");
    try editor.handleInput("\x7f");
    try expectText(&editor, "äö");

    try editor.setText("😀👍");
    try editor.handleInput("\x7f");
    try expectText(&editor, "😀");

    try editor.setText("äöü");
    try editor.handleInput("\x1b[D");
    try editor.handleInput("\x1b[D");
    try editor.handleInput("x");
    try expectText(&editor, "äxöü");

    try editor.setText("😀👍🎉");
    try editor.handleInput("\x1b[D");
    try editor.handleInput("\x1b[D");
    try editor.handleInput("x");
    try expectText(&editor, "😀x👍🎉");

    try editor.setText("äöü\nÄÖÜ");
    try expectText(&editor, "äöü\nÄÖÜ");
}

test "Editor word deletion and navigation" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.setText("foo bar baz");
    try editor.handleInput("\x17");
    try expectText(&editor, "foo bar ");

    try editor.setText("foo bar...");
    try editor.handleInput("\x17");
    try expectText(&editor, "foo bar");

    try editor.setText("foo.bar");
    try editor.handleInput("\x17");
    try expectText(&editor, "foo.");

    try editor.setText("line one\nline two");
    try editor.handleInput("\x17");
    try expectText(&editor, "line one\nline ");

    try editor.setText("line one\n");
    try editor.handleInput("\x17");
    try expectText(&editor, "line one");

    try editor.setText("foo bar... baz");
    try editor.handleInput("\x1b[1;5D");
    try std.testing.expectEqual(@as(usize, 11), editor.getCursor().col);
    try editor.handleInput("\x1b[1;5D");
    try std.testing.expectEqual(@as(usize, 7), editor.getCursor().col);
    try editor.handleInput("\x1b[1;5C");
    try std.testing.expectEqual(@as(usize, 10), editor.getCursor().col);
}

test "Editor wordWrapLine upstream boundary regressions" {
    const allocator = std.testing.allocator;

    {
        const chunks = try wordWrapLine(allocator, "hello world test", 11, null);
        defer allocator.free(chunks);
        try expectChunks(chunks, &.{ "hello ", "world test" });
    }
    {
        const chunks = try wordWrapLine(allocator, "hello world test", 12, null);
        defer allocator.free(chunks);
        try expectChunks(chunks, &.{ "hello world ", "test" });
    }
    {
        const chunks = try wordWrapLine(allocator, "aaaaaaaaaaaa aaaa", 12, null);
        defer allocator.free(chunks);
        try expectChunks(chunks, &.{ "aaaaaaaaaaaa", " aaaa" });
    }
    {
        const chunks = try wordWrapLine(allocator, "      aaaaaaaaaaaa", 12, null);
        defer allocator.free(chunks);
        try expectChunks(chunks, &.{ "      ", "aaaaaaaaaaaa" });
    }
    {
        const chunks = try wordWrapLine(allocator, "Lorem ipsum dolor sit amet,    consectetur", 30, null);
        defer allocator.free(chunks);
        try expectChunks(chunks, &.{ "Lorem ipsum dolor sit ", "amet,    consectetur" });
    }
    {
        const chunks = try wordWrapLine(allocator, "Lorem ipsum dolor sit amet,               consectetur", 30, null);
        defer allocator.free(chunks);
        try expectChunks(chunks, &.{ "Lorem ipsum dolor sit ", "amet,               ", "consectetur" });
    }
}

test "Editor wordWrapLine splits oversized atomic segments" {
    const allocator = std.testing.allocator;
    const marker = "[paste #1 +20 lines]";
    const line = "A" ++ marker ++ "B";
    const segments = [_]SegmentData{
        .{ .segment = "A", .index = 0 },
        .{ .segment = marker, .index = 1 },
        .{ .segment = "B", .index = 1 + marker.len },
    };

    const chunks = try wordWrapLine(allocator, line, 10, &segments);
    defer allocator.free(chunks);

    var reconstructed: std.ArrayList(u8) = .empty;
    defer reconstructed.deinit(allocator);
    for (chunks) |chunk| {
        try std.testing.expect(visibleWidth(chunk.text) <= 10);
        try reconstructed.appendSlice(allocator, line[chunk.start_index..chunk.end_index]);
    }
    try std.testing.expectEqualStrings(line, reconstructed.items);
}

test "Editor render keeps wide text within width" {
    const allocator = std.testing.allocator;
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.setText("日本語テスト");
    const rendered = try editor.render(allocator, 11);
    defer allocator.free(rendered);
    defer freeRenderedLines(allocator, rendered);

    for (rendered) |line| try std.testing.expectEqual(@as(usize, 11), visibleWidth(line));
    try std.testing.expect(strippedContains(rendered[1], "日本語テス"));
    try std.testing.expect(strippedContains(rendered[2], "ト"));
}

test "Editor kill ring and undo basics" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);
    var editor = try Editor.init(allocator, .{});
    defer editor.deinit();

    try editor.setText("foo bar baz");
    try editor.handleInput("\x17");
    try expectText(&editor, "foo bar ");
    try editor.handleInput("\x01");
    try editor.handleInput("\x19");
    try expectText(&editor, "bazfoo bar ");

    try editor.handleInput("\x1b[45;5u");
    try expectText(&editor, "foo bar ");

    try editor.setText("");
    try editor.handleInput("a");
    try editor.handleInput("b");
    try editor.handleInput("c");
    try expectText(&editor, "abc");
    try editor.handleInput("\x1b[45;5u");
    try expectText(&editor, "");
}

test "Editor character jump Ctrl bracket" {
    const allocator = std.testing.allocator;
    defer keybindings.resetGlobalKeybindings(allocator);

    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x01");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
        try editor.handleInput("\x1d");
        try editor.handleInput("o");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 4 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x01");
        var index: usize = 0;
        while (index < 4) : (index += 1) try editor.handleInput("\x1b[C");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 4 }, editor.getCursor());
        try editor.handleInput("\x1d");
        try editor.handleInput("o");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 7 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("abc\ndef\nghi");
        try editor.handleInput("\x1b[A");
        try editor.handleInput("\x1b[A");
        try editor.handleInput("\x01");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
        try editor.handleInput("\x1d");
        try editor.handleInput("g");
        try std.testing.expectEqual(Cursor{ .line = 2, .col = 0 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 11 }, editor.getCursor());
        try editor.handleInput("\x1b\x1d");
        try editor.handleInput("o");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 7 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("abc\ndef\nghi");
        try std.testing.expectEqual(Cursor{ .line = 2, .col = 3 }, editor.getCursor());
        try editor.handleInput("\x1b\x1d");
        try editor.handleInput("a");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x01");
        try editor.handleInput("\x1d");
        try editor.handleInput("z");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x1b\x1d");
        try editor.handleInput("z");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 11 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("Hello World");
        try editor.handleInput("\x01");
        try editor.handleInput("\x1d");
        try editor.handleInput("h");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
        try editor.handleInput("\x1d");
        try editor.handleInput("W");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 6 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x01");
        try editor.handleInput("\x1d");
        try editor.handleInput("\x1d");
        try editor.handleInput("o");
        try expectText(&editor, "ohello world");
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x01");
        try editor.handleInput("\x1d");
        try editor.handleInput("\x1b");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
        try editor.handleInput("o");
        try expectText(&editor, "ohello world");
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x1b\x1d");
        try editor.handleInput("\x1b\x1d");
        try editor.handleInput("o");
        try expectText(&editor, "hello worldo");
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("foo(bar) = baz;");
        try editor.handleInput("\x01");
        try editor.handleInput("\x1d");
        try editor.handleInput("(");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 3 }, editor.getCursor());
        try editor.handleInput("\x1d");
        try editor.handleInput("=");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 9 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("");
        try editor.handleInput("\x1d");
        try editor.handleInput("x");
        try std.testing.expectEqual(Cursor{ .line = 0, .col = 0 }, editor.getCursor());
    }
    {
        var editor = try Editor.init(allocator, .{});
        defer editor.deinit();
        try editor.setText("hello world");
        try editor.handleInput("\x01");
        try editor.handleInput("x");
        try expectText(&editor, "xhello world");
        try editor.handleInput("\x1d");
        try editor.handleInput("o");
        try editor.handleInput("Y");
        try expectText(&editor, "xhellYo world");
        try editor.handleInput("\x1b[45;5u");
        try expectText(&editor, "xhello world");
    }
}
