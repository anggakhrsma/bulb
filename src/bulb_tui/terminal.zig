const std = @import("std");

const keys = @import("keys.zig");

pub const TERMINAL_PROGRESS_KEEPALIVE_MS: u64 = 1000;
pub const TERMINAL_PROGRESS_ACTIVE_SEQUENCE = "\x1b]9;4;3\x07";
pub const TERMINAL_PROGRESS_CLEAR_SEQUENCE = "\x1b]9;4;0;\x07";
pub const APPLE_TERMINAL_SHIFT_ENTER_SEQUENCE = "\x1b[13;2u";
pub const DESIRED_KITTY_KEYBOARD_PROTOCOL_FLAGS: u16 = 7;
pub const KITTY_KEYBOARD_PROTOCOL_FALLBACK_TIMEOUT_MS: u64 = 150;
pub const KEYBOARD_PROTOCOL_RESPONSE_FRAGMENT_TIMEOUT_MS: u64 = 150;
pub const KITTY_KEYBOARD_PROTOCOL_QUERY = "\x1b[>7u\x1b[?u\x1b[c";

pub const KeyboardProtocolNegotiationSequence = union(enum) {
    kitty_flags: u32,
    device_attributes,
};

pub fn parseKeyboardProtocolNegotiationSequence(sequence: []const u8) ?KeyboardProtocolNegotiationSequence {
    if (std.mem.startsWith(u8, sequence, "\x1b[?") and std.mem.endsWith(u8, sequence, "u")) {
        const body = sequence[3 .. sequence.len - 1];
        if (body.len == 0) return null;
        for (body) |byte| if (!std.ascii.isDigit(byte)) return null;
        const flags = std.fmt.parseInt(u32, body, 10) catch return null;
        return .{ .kitty_flags = flags };
    }

    if (std.mem.startsWith(u8, sequence, "\x1b[?") and std.mem.endsWith(u8, sequence, "c")) {
        const body = sequence[3 .. sequence.len - 1];
        for (body) |byte| {
            if (!std.ascii.isDigit(byte) and byte != ';') return null;
        }
        return .device_attributes;
    }

    return null;
}

pub fn isKeyboardProtocolNegotiationSequencePrefix(sequence: []const u8, allow_bare_escape_prefix: bool) bool {
    if (allow_bare_escape_prefix and std.mem.eql(u8, sequence, "\x1b")) return true;
    if (std.mem.eql(u8, sequence, "\x1b[")) return true;
    if (!std.mem.startsWith(u8, sequence, "\x1b[?")) return false;
    for (sequence[3..]) |byte| {
        if (!std.ascii.isDigit(byte) and byte != ';') return false;
    }
    return true;
}

pub fn normalizeAppleTerminalInput(data: []const u8, is_apple_terminal: bool, is_shift_pressed: bool) []const u8 {
    if (is_apple_terminal and is_shift_pressed and std.mem.eql(u8, data, "\r")) return APPLE_TERMINAL_SHIFT_ENTER_SEQUENCE;
    return data;
}

pub fn isAppleTerminalSession(environ: ?*const std.process.Environ.Map, builtin_os: std.Target.Os.Tag) bool {
    if (builtin_os != .macos) return false;
    const map = environ orelse return false;
    return std.mem.eql(u8, map.get("TERM_PROGRAM") orelse "", "Apple_Terminal");
}

pub const InputCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: InputCallback, data: []const u8) void {
        self.call_fn(self.ptr, data);
    }
};

pub const VoidCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) void,

    pub fn call(self: VoidCallback) void {
        self.call_fn(self.ptr);
    }
};

pub const WriteCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    pub fn call(self: WriteCallback, data: []const u8) !void {
        try self.call_fn(self.ptr, data);
    }
};

pub const Terminal = struct {
    ptr: *anyopaque,
    start_fn: *const fn (*anyopaque, InputCallback, VoidCallback) anyerror!void,
    stop_fn: *const fn (*anyopaque) anyerror!void,
    drain_input_fn: *const fn (*anyopaque, u64, u64) anyerror!void,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    columns_fn: *const fn (*anyopaque) usize,
    rows_fn: *const fn (*anyopaque) usize,
    kitty_protocol_active_fn: *const fn (*anyopaque) bool,
    move_by_fn: *const fn (*anyopaque, isize) anyerror!void,
    hide_cursor_fn: *const fn (*anyopaque) anyerror!void,
    show_cursor_fn: *const fn (*anyopaque) anyerror!void,
    clear_line_fn: *const fn (*anyopaque) anyerror!void,
    clear_from_cursor_fn: *const fn (*anyopaque) anyerror!void,
    clear_screen_fn: *const fn (*anyopaque) anyerror!void,
    set_title_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    set_progress_fn: *const fn (*anyopaque, bool) anyerror!void,

    pub fn from(comptime T: type, ptr: *T) Terminal {
        const Adapter = struct {
            fn start(raw: *anyopaque, on_input: InputCallback, on_resize: VoidCallback) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.start(on_input, on_resize);
            }

            fn stop(raw: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.stop();
            }

            fn drainInput(raw: *anyopaque, max_ms: u64, idle_ms: u64) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.drainInput(max_ms, idle_ms);
            }

            fn write(raw: *anyopaque, data: []const u8) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.write(data);
            }

            fn columns(raw: *anyopaque) usize {
                const self: *T = @ptrCast(@alignCast(raw));
                return self.columns();
            }

            fn rows(raw: *anyopaque) usize {
                const self: *T = @ptrCast(@alignCast(raw));
                return self.rows();
            }

            fn kittyProtocolActive(raw: *anyopaque) bool {
                const self: *T = @ptrCast(@alignCast(raw));
                return self.kittyProtocolActive();
            }

            fn moveBy(raw: *anyopaque, lines: isize) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.moveBy(lines);
            }

            fn hideCursor(raw: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.hideCursor();
            }

            fn showCursor(raw: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.showCursor();
            }

            fn clearLine(raw: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.clearLine();
            }

            fn clearFromCursor(raw: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.clearFromCursor();
            }

            fn clearScreen(raw: *anyopaque) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.clearScreen();
            }

            fn setTitle(raw: *anyopaque, title: []const u8) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.setTitle(title);
            }

            fn setProgress(raw: *anyopaque, active: bool) anyerror!void {
                const self: *T = @ptrCast(@alignCast(raw));
                try self.setProgress(active);
            }
        };

        return .{
            .ptr = ptr,
            .start_fn = Adapter.start,
            .stop_fn = Adapter.stop,
            .drain_input_fn = Adapter.drainInput,
            .write_fn = Adapter.write,
            .columns_fn = Adapter.columns,
            .rows_fn = Adapter.rows,
            .kitty_protocol_active_fn = Adapter.kittyProtocolActive,
            .move_by_fn = Adapter.moveBy,
            .hide_cursor_fn = Adapter.hideCursor,
            .show_cursor_fn = Adapter.showCursor,
            .clear_line_fn = Adapter.clearLine,
            .clear_from_cursor_fn = Adapter.clearFromCursor,
            .clear_screen_fn = Adapter.clearScreen,
            .set_title_fn = Adapter.setTitle,
            .set_progress_fn = Adapter.setProgress,
        };
    }

    pub fn start(self: Terminal, on_input: InputCallback, on_resize: VoidCallback) !void {
        try self.start_fn(self.ptr, on_input, on_resize);
    }

    pub fn stop(self: Terminal) !void {
        try self.stop_fn(self.ptr);
    }

    pub fn drainInput(self: Terminal, max_ms: u64, idle_ms: u64) !void {
        try self.drain_input_fn(self.ptr, max_ms, idle_ms);
    }

    pub fn write(self: Terminal, data: []const u8) !void {
        try self.write_fn(self.ptr, data);
    }

    pub fn columns(self: Terminal) usize {
        return self.columns_fn(self.ptr);
    }

    pub fn rows(self: Terminal) usize {
        return self.rows_fn(self.ptr);
    }

    pub fn kittyProtocolActive(self: Terminal) bool {
        return self.kitty_protocol_active_fn(self.ptr);
    }

    pub fn moveBy(self: Terminal, lines: isize) !void {
        try self.move_by_fn(self.ptr, lines);
    }

    pub fn hideCursor(self: Terminal) !void {
        try self.hide_cursor_fn(self.ptr);
    }

    pub fn showCursor(self: Terminal) !void {
        try self.show_cursor_fn(self.ptr);
    }

    pub fn clearLine(self: Terminal) !void {
        try self.clear_line_fn(self.ptr);
    }

    pub fn clearFromCursor(self: Terminal) !void {
        try self.clear_from_cursor_fn(self.ptr);
    }

    pub fn clearScreen(self: Terminal) !void {
        try self.clear_screen_fn(self.ptr);
    }

    pub fn setTitle(self: Terminal, title: []const u8) !void {
        try self.set_title_fn(self.ptr, title);
    }

    pub fn setProgress(self: Terminal, active: bool) !void {
        try self.set_progress_fn(self.ptr, active);
    }
};

pub const ProcessTerminalOptions = struct {
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map = null,
    writer: ?WriteCallback = null,
    columns: ?usize = null,
    rows: ?usize = null,
};

pub const ProcessTerminal = struct {
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map = null,
    writer: ?WriteCallback = null,
    columns_override: ?usize = null,
    rows_override: ?usize = null,
    input_handler: ?InputCallback = null,
    resize_handler: ?VoidCallback = null,
    kitty_protocol_active: bool = false,
    modify_other_keys_active: bool = false,
    keyboard_protocol_pushed: bool = false,
    keyboard_protocol_negotiation_pending: bool = false,
    keyboard_protocol_late_response_pending: bool = false,
    keyboard_protocol_negotiation_buffer: std.ArrayList(u8) = .empty,
    progress_active: bool = false,

    const ReadNegotiationResult = union(enum) {
        pending,
        sequence: KeyboardProtocolNegotiationSequence,
        none,
    };

    pub fn init(options: ProcessTerminalOptions) ProcessTerminal {
        return .{
            .allocator = options.allocator,
            .environ = options.environ,
            .writer = options.writer,
            .columns_override = options.columns,
            .rows_override = options.rows,
        };
    }

    pub fn deinit(self: *ProcessTerminal) void {
        self.keyboard_protocol_negotiation_buffer.deinit(self.allocator);
    }

    pub fn asTerminal(self: *ProcessTerminal) Terminal {
        return Terminal.from(ProcessTerminal, self);
    }

    pub fn start(self: *ProcessTerminal, on_input: InputCallback, on_resize: VoidCallback) !void {
        self.input_handler = on_input;
        self.resize_handler = on_resize;
        try self.write("\x1b[?2004h");
        try self.queryAndEnableKittyProtocol();
    }

    pub fn queryAndEnableKittyProtocol(self: *ProcessTerminal) !void {
        self.keyboard_protocol_pushed = true;
        self.keyboard_protocol_negotiation_pending = true;
        self.keyboard_protocol_late_response_pending = false;
        self.clearKeyboardProtocolNegotiationBuffer();
        try self.write(KITTY_KEYBOARD_PROTOCOL_QUERY);
    }

    pub fn receiveInput(self: *ProcessTerminal, sequence: []const u8) !void {
        if (self.keyboard_protocol_negotiation_pending) {
            const negotiation = try self.readKeyboardProtocolNegotiationSequence(sequence, true);
            switch (negotiation) {
                .pending => return,
                .sequence => |value| if (try self.handleKeyboardProtocolNegotiationSequence(value)) return,
                .none => {},
            }
        }

        if (self.keyboard_protocol_late_response_pending) {
            const negotiation = try self.readKeyboardProtocolNegotiationSequence(sequence, false);
            switch (negotiation) {
                .pending => return,
                .sequence => |value| if (try self.handleKeyboardProtocolNegotiationSequence(value)) return,
                .none => {},
            }
        }

        self.forwardInputSequence(sequence);
    }

    pub fn triggerKeyboardProtocolFallback(self: *ProcessTerminal) !void {
        self.keyboard_protocol_negotiation_pending = false;
        self.keyboard_protocol_late_response_pending = true;
        if (std.mem.eql(u8, self.keyboard_protocol_negotiation_buffer.items, "\x1b")) {
            self.flushKeyboardProtocolNegotiationBufferAsInput();
        }
        try self.enableModifyOtherKeys();
    }

    pub fn triggerKeyboardProtocolBufferFlush(self: *ProcessTerminal) void {
        self.flushKeyboardProtocolNegotiationBufferAsInput();
    }

    fn handleKeyboardProtocolNegotiationSequence(self: *ProcessTerminal, negotiation_sequence: KeyboardProtocolNegotiationSequence) !bool {
        switch (negotiation_sequence) {
            .kitty_flags => |flags| {
                if (flags != 0 and !self.kitty_protocol_active) {
                    self.kitty_protocol_active = true;
                    keys.setKittyProtocolActive(true);
                    self.keyboard_protocol_negotiation_pending = false;
                    self.keyboard_protocol_late_response_pending = true;
                    self.clearKeyboardProtocolNegotiationBuffer();
                }
                return true;
            },
            .device_attributes => {
                self.keyboard_protocol_negotiation_pending = false;
                self.keyboard_protocol_late_response_pending = true;
                self.clearKeyboardProtocolNegotiationBuffer();
                try self.enableModifyOtherKeys();
                return true;
            },
        }
    }

    fn readKeyboardProtocolNegotiationSequence(
        self: *ProcessTerminal,
        sequence: []const u8,
        allow_bare_escape_prefix: bool,
    ) !ReadNegotiationResult {
        if (self.keyboard_protocol_negotiation_buffer.items.len > 0) {
            var buffered: std.ArrayList(u8) = .empty;
            defer buffered.deinit(self.allocator);
            try buffered.appendSlice(self.allocator, self.keyboard_protocol_negotiation_buffer.items);
            try buffered.appendSlice(self.allocator, sequence);

            if (parseKeyboardProtocolNegotiationSequence(buffered.items)) |negotiation| {
                self.clearKeyboardProtocolNegotiationBuffer();
                return .{ .sequence = negotiation };
            }
            if (isKeyboardProtocolNegotiationSequencePrefix(buffered.items, allow_bare_escape_prefix)) {
                try self.setKeyboardProtocolNegotiationBuffer(buffered.items);
                return .pending;
            }
            self.flushKeyboardProtocolNegotiationBufferAsInput();
        }

        if (parseKeyboardProtocolNegotiationSequence(sequence)) |negotiation| return .{ .sequence = negotiation };
        if (isKeyboardProtocolNegotiationSequencePrefix(sequence, allow_bare_escape_prefix)) {
            try self.setKeyboardProtocolNegotiationBuffer(sequence);
            return .pending;
        }
        return .none;
    }

    fn setKeyboardProtocolNegotiationBuffer(self: *ProcessTerminal, sequence: []const u8) !void {
        self.keyboard_protocol_negotiation_buffer.clearRetainingCapacity();
        try self.keyboard_protocol_negotiation_buffer.appendSlice(self.allocator, sequence);
    }

    fn clearKeyboardProtocolNegotiationBuffer(self: *ProcessTerminal) void {
        self.keyboard_protocol_negotiation_buffer.clearRetainingCapacity();
    }

    fn flushKeyboardProtocolNegotiationBufferAsInput(self: *ProcessTerminal) void {
        if (self.keyboard_protocol_negotiation_buffer.items.len == 0) return;
        self.forwardInputSequence(self.keyboard_protocol_negotiation_buffer.items);
        self.clearKeyboardProtocolNegotiationBuffer();
    }

    fn forwardInputSequence(self: *ProcessTerminal, sequence: []const u8) void {
        if (self.input_handler) |handler| {
            const apple = std.mem.eql(u8, sequence, "\r") and isAppleTerminalSession(self.environ, @import("builtin").os.tag);
            handler.call(normalizeAppleTerminalInput(sequence, apple, false));
        }
    }

    fn enableModifyOtherKeys(self: *ProcessTerminal) !void {
        if (self.kitty_protocol_active or self.modify_other_keys_active) return;
        try self.write("\x1b[>4;2m");
        self.modify_other_keys_active = true;
    }

    pub fn drainInput(self: *ProcessTerminal, _: u64, _: u64) !void {
        try self.disableKeyboardProtocols();
        self.input_handler = null;
    }

    pub fn stop(self: *ProcessTerminal) !void {
        if (self.progress_active) {
            self.progress_active = false;
            try self.write(TERMINAL_PROGRESS_CLEAR_SEQUENCE);
        }
        try self.write("\x1b[?2004l");
        try self.disableKeyboardProtocols();
        self.input_handler = null;
        self.resize_handler = null;
    }

    fn disableKeyboardProtocols(self: *ProcessTerminal) !void {
        const should_disable_kitty = self.keyboard_protocol_pushed or self.kitty_protocol_active or self.keyboard_protocol_negotiation_pending;
        self.keyboard_protocol_late_response_pending = false;
        self.keyboard_protocol_negotiation_pending = false;
        self.clearKeyboardProtocolNegotiationBuffer();
        if (should_disable_kitty) {
            try self.write("\x1b[<u");
            self.keyboard_protocol_pushed = false;
            self.kitty_protocol_active = false;
            keys.setKittyProtocolActive(false);
        }
        if (self.modify_other_keys_active) {
            try self.write("\x1b[>4;0m");
            self.modify_other_keys_active = false;
        }
    }

    pub fn write(self: *ProcessTerminal, data: []const u8) !void {
        if (self.writer) |writer| {
            try writer.call(data);
            return;
        }
        return error.NoTerminalWriterConfigured;
    }

    pub fn columns(self: *ProcessTerminal) usize {
        if (self.columns_override) |value| return value;
        if (self.environ) |map| if (map.get("COLUMNS")) |value| return std.fmt.parseInt(usize, value, 10) catch 80;
        return 80;
    }

    pub fn rows(self: *ProcessTerminal) usize {
        if (self.rows_override) |value| return value;
        if (self.environ) |map| if (map.get("LINES")) |value| return std.fmt.parseInt(usize, value, 10) catch 24;
        return 24;
    }

    pub fn kittyProtocolActive(self: *ProcessTerminal) bool {
        return self.kitty_protocol_active;
    }

    pub fn moveBy(self: *ProcessTerminal, lines: isize) !void {
        if (lines > 0) {
            const sequence = try std.fmt.allocPrint(self.allocator, "\x1b[{d}B", .{lines});
            defer self.allocator.free(sequence);
            try self.write(sequence);
        } else if (lines < 0) {
            const sequence = try std.fmt.allocPrint(self.allocator, "\x1b[{d}A", .{-lines});
            defer self.allocator.free(sequence);
            try self.write(sequence);
        }
    }

    pub fn hideCursor(self: *ProcessTerminal) !void {
        try self.write("\x1b[?25l");
    }

    pub fn showCursor(self: *ProcessTerminal) !void {
        try self.write("\x1b[?25h");
    }

    pub fn clearLine(self: *ProcessTerminal) !void {
        try self.write("\x1b[K");
    }

    pub fn clearFromCursor(self: *ProcessTerminal) !void {
        try self.write("\x1b[J");
    }

    pub fn clearScreen(self: *ProcessTerminal) !void {
        try self.write("\x1b[2J\x1b[H");
    }

    pub fn setTitle(self: *ProcessTerminal, title: []const u8) !void {
        const sequence = try std.fmt.allocPrint(self.allocator, "\x1b]0;{s}\x07", .{title});
        defer self.allocator.free(sequence);
        try self.write(sequence);
    }

    pub fn setProgress(self: *ProcessTerminal, active: bool) !void {
        if (active) {
            self.progress_active = true;
            try self.write(TERMINAL_PROGRESS_ACTIVE_SEQUENCE);
        } else {
            self.progress_active = false;
            try self.write(TERMINAL_PROGRESS_CLEAR_SEQUENCE);
        }
    }
};

test "parseKeyboardProtocolNegotiationSequence mirrors Kitty and DA responses" {
    try std.testing.expectEqual(@as(u32, 1), parseKeyboardProtocolNegotiationSequence("\x1b[?1u").?.kitty_flags);
    try std.testing.expectEqual(@as(u32, 7), parseKeyboardProtocolNegotiationSequence("\x1b[?7u").?.kitty_flags);
    try std.testing.expect(parseKeyboardProtocolNegotiationSequence("\x1b[?62;4;52c").? == .device_attributes);
    try std.testing.expect(parseKeyboardProtocolNegotiationSequence("\x1b[13;2u") == null);
    try std.testing.expect(parseKeyboardProtocolNegotiationSequence("\x1b[?7x") == null);
}

test "normalizeAppleTerminalInput rewrites shifted return only for Apple Terminal" {
    try std.testing.expectEqualStrings(APPLE_TERMINAL_SHIFT_ENTER_SEQUENCE, normalizeAppleTerminalInput("\r", true, true));
    try std.testing.expectEqualStrings("\r", normalizeAppleTerminalInput("\r", true, false));
    try std.testing.expectEqualStrings("\r", normalizeAppleTerminalInput("\r", false, true));
    try std.testing.expectEqualStrings("\x1b[13;2u", normalizeAppleTerminalInput("\x1b[13;2u", true, true));
    try std.testing.expectEqualStrings("a", normalizeAppleTerminalInput("a", true, true));
}

const TestSink = struct {
    allocator: std.mem.Allocator,
    writes: std.ArrayList(u8) = .empty,
    input: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestSink) void {
        self.writes.deinit(self.allocator);
        self.input.deinit(self.allocator);
    }

    fn write(ptr: ?*anyopaque, data: []const u8) !void {
        const self: *TestSink = @ptrCast(@alignCast(ptr.?));
        try self.writes.appendSlice(self.allocator, data);
    }

    fn inputFn(ptr: ?*anyopaque, data: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ptr.?));
        self.input.appendSlice(self.allocator, data) catch unreachable;
    }

    fn noop(_: ?*anyopaque) void {}
};

test "ProcessTerminal activates Kitty mode for non-zero negotiated flags" {
    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    var terminal = ProcessTerminal.init(.{
        .allocator = std.testing.allocator,
        .writer = .{ .ptr = &sink, .call_fn = TestSink.write },
    });
    defer terminal.deinit();

    terminal.input_handler = .{ .ptr = &sink, .call_fn = TestSink.inputFn };
    try terminal.queryAndEnableKittyProtocol();
    try terminal.receiveInput("\x1b[?1u");
    try terminal.triggerKeyboardProtocolFallback();

    try std.testing.expectEqualStrings(KITTY_KEYBOARD_PROTOCOL_QUERY, sink.writes.items[0..KITTY_KEYBOARD_PROTOCOL_QUERY.len]);
    try std.testing.expect(std.mem.indexOf(u8, sink.writes.items, "\x1b[>4;2m") == null);
    try std.testing.expectEqualStrings("", sink.input.items);
    try std.testing.expect(terminal.kittyProtocolActive());

    try terminal.stop();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.writes.items, "\x1b[<u"));
}

test "ProcessTerminal falls back to modifyOtherKeys for unsupported or silent terminals" {
    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    var terminal = ProcessTerminal.init(.{
        .allocator = std.testing.allocator,
        .writer = .{ .ptr = &sink, .call_fn = TestSink.write },
    });
    defer terminal.deinit();

    terminal.input_handler = .{ .ptr = &sink, .call_fn = TestSink.inputFn };
    try terminal.queryAndEnableKittyProtocol();
    try terminal.receiveInput("\x1b[?62;4;52c");

    try std.testing.expect(std.mem.indexOf(u8, sink.writes.items, "\x1b[>4;2m") != null);
    try std.testing.expect(!terminal.kittyProtocolActive());
    try std.testing.expectEqualStrings("", sink.input.items);
}

test "ProcessTerminal tracks late split Kitty confirmation after fallback" {
    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    var terminal = ProcessTerminal.init(.{
        .allocator = std.testing.allocator,
        .writer = .{ .ptr = &sink, .call_fn = TestSink.write },
    });
    defer terminal.deinit();

    terminal.input_handler = .{ .ptr = &sink, .call_fn = TestSink.inputFn };
    try terminal.queryAndEnableKittyProtocol();
    try terminal.triggerKeyboardProtocolFallback();
    try terminal.receiveInput("\x1b[?7");
    try std.testing.expectEqualStrings("", sink.input.items);
    try terminal.receiveInput("u");

    try std.testing.expect(std.mem.indexOf(u8, sink.writes.items, "\x1b[>4;2m") != null);
    try std.testing.expect(terminal.kittyProtocolActive());

    try terminal.stop();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.writes.items, "\x1b[<u"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sink.writes.items, "\x1b[>4;0m"));
}

test "ProcessTerminal replays buffered CSI-prefix input after fallback" {
    var sink = TestSink{ .allocator = std.testing.allocator };
    defer sink.deinit();
    var terminal = ProcessTerminal.init(.{
        .allocator = std.testing.allocator,
        .writer = .{ .ptr = &sink, .call_fn = TestSink.write },
    });
    defer terminal.deinit();

    terminal.input_handler = .{ .ptr = &sink, .call_fn = TestSink.inputFn };
    try terminal.queryAndEnableKittyProtocol();
    try terminal.receiveInput("\x1b[");
    try terminal.triggerKeyboardProtocolFallback();
    try std.testing.expectEqualStrings("", sink.input.items);
    terminal.triggerKeyboardProtocolBufferFlush();
    try std.testing.expectEqualStrings("\x1b[", sink.input.items);
}

test "ProcessTerminal dimensions fall back to COLUMNS and LINES before defaults" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("COLUMNS", "123");
    try environ.put("LINES", "45");

    var terminal = ProcessTerminal.init(.{ .allocator = std.testing.allocator, .environ = &environ });
    defer terminal.deinit();
    try std.testing.expectEqual(@as(usize, 123), terminal.columns());
    try std.testing.expectEqual(@as(usize, 45), terminal.rows());

    var default_terminal = ProcessTerminal.init(.{ .allocator = std.testing.allocator });
    defer default_terminal.deinit();
    try std.testing.expectEqual(@as(usize, 80), default_terminal.columns());
    try std.testing.expectEqual(@as(usize, 24), default_terminal.rows());
}
