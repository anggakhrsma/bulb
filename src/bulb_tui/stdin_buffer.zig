const std = @import("std");

const ESC: u8 = 0x1b;
const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";

pub const DataListener = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: DataListener, data: []const u8) void {
        self.call_fn(self.context, data);
    }
};

pub const PasteListener = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) void,

    pub fn call(self: PasteListener, data: []const u8) void {
        self.call_fn(self.context, data);
    }
};

pub const StdinBufferOptions = struct {
    timeout_ms: u64 = 10,
};

const SequenceStatus = enum { complete, incomplete, not_escape };

pub const StdinBuffer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    timeout_ms: u64,
    timeout_remaining_ms: ?u64 = null,
    paste_mode: bool = false,
    paste_buffer: std.ArrayList(u8) = .empty,
    pending_kitty_printable_codepoint: ?u21 = null,
    data_listeners: std.ArrayList(DataListener) = .empty,
    paste_listeners: std.ArrayList(PasteListener) = .empty,

    pub fn init(allocator: std.mem.Allocator, options: StdinBufferOptions) StdinBuffer {
        return .{
            .allocator = allocator,
            .timeout_ms = options.timeout_ms,
        };
    }

    pub fn deinit(self: *StdinBuffer) void {
        self.clear();
        self.buffer.deinit(self.allocator);
        self.paste_buffer.deinit(self.allocator);
        self.data_listeners.deinit(self.allocator);
        self.paste_listeners.deinit(self.allocator);
    }

    pub fn onData(self: *StdinBuffer, listener: DataListener) !void {
        try self.data_listeners.append(self.allocator, listener);
    }

    pub fn onPaste(self: *StdinBuffer, listener: PasteListener) !void {
        try self.paste_listeners.append(self.allocator, listener);
    }

    pub fn process(self: *StdinBuffer, data: []const u8) error{OutOfMemory}!void {
        try self.poll();

        var converted: [2]u8 = undefined;
        const input = if (data.len == 1 and data[0] > 127) blk: {
            converted[0] = ESC;
            converted[1] = data[0] - 128;
            break :blk converted[0..2];
        } else data;

        if (input.len == 0 and self.buffer.items.len == 0 and !self.paste_mode) {
            self.emitDataSequence("");
            return;
        }

        try self.buffer.appendSlice(self.allocator, input);

        if (self.paste_mode) {
            try self.paste_buffer.appendSlice(self.allocator, self.buffer.items);
            self.buffer.clearRetainingCapacity();
            self.timeout_remaining_ms = null;
            try self.consumePasteBuffer();
            return;
        }

        if (std.mem.indexOf(u8, self.buffer.items, BRACKETED_PASTE_START)) |start_index| {
            const snapshot = try self.allocator.dupe(u8, self.buffer.items);
            defer self.allocator.free(snapshot);

            if (start_index > 0) {
                const before_paste = snapshot[0..start_index];
                const extracted = try extractCompleteSequences(self.allocator, before_paste);
                defer freeExtracted(self.allocator, extracted);
                for (extracted.sequences) |sequence| self.emitDataSequence(sequence);
            }

            const after_start = snapshot[start_index + BRACKETED_PASTE_START.len ..];
            self.buffer.clearRetainingCapacity();
            self.paste_buffer.clearRetainingCapacity();
            try self.paste_buffer.appendSlice(self.allocator, after_start);
            self.paste_mode = true;
            self.timeout_remaining_ms = null;
            self.pending_kitty_printable_codepoint = null;
            try self.consumePasteBuffer();
            return;
        }

        const snapshot = try self.allocator.dupe(u8, self.buffer.items);
        defer self.allocator.free(snapshot);

        const extracted = try extractCompleteSequences(self.allocator, snapshot);
        defer freeExtracted(self.allocator, extracted);

        self.buffer.clearRetainingCapacity();
        if (extracted.remainder_index < snapshot.len) {
            try self.buffer.appendSlice(self.allocator, snapshot[extracted.remainder_index..]);
        }

        self.timeout_remaining_ms = if (self.buffer.items.len > 0) self.timeout_ms else null;

        for (extracted.sequences) |sequence| self.emitDataSequence(sequence);
    }

    pub fn advanceTimeout(self: *StdinBuffer, elapsed_ms: u64) error{OutOfMemory}!void {
        if (self.paste_mode) return;
        if (self.timeout_remaining_ms) |remaining| {
            self.timeout_remaining_ms = if (elapsed_ms >= remaining) 0 else remaining - elapsed_ms;
            try self.poll();
        }
    }

    pub fn poll(self: *StdinBuffer) error{OutOfMemory}!void {
        if (self.paste_mode) return;
        if (self.timeout_remaining_ms) |remaining| {
            if (remaining == 0 and self.buffer.items.len > 0) {
                const flushed = try self.flush();
                defer freeFlushed(self.allocator, flushed);
                for (flushed) |sequence| self.emitDataSequence(sequence);
            } else if (self.buffer.items.len == 0) {
                self.timeout_remaining_ms = null;
            }
        }
    }

    pub fn flush(self: *StdinBuffer) error{OutOfMemory}![][]u8 {
        if (self.buffer.items.len == 0) {
            self.timeout_remaining_ms = null;
            return self.allocator.alloc([]u8, 0);
        }

        const text = try self.allocator.dupe(u8, self.buffer.items);
        errdefer self.allocator.free(text);
        self.buffer.clearRetainingCapacity();
        self.timeout_remaining_ms = null;
        self.pending_kitty_printable_codepoint = null;

        const sequences = try self.allocator.alloc([]u8, 1);
        sequences[0] = text;
        return sequences;
    }

    pub fn clear(self: *StdinBuffer) void {
        self.buffer.clearRetainingCapacity();
        self.paste_buffer.clearRetainingCapacity();
        self.paste_mode = false;
        self.timeout_remaining_ms = null;
        self.pending_kitty_printable_codepoint = null;
    }

    pub fn getBuffer(self: *const StdinBuffer) []const u8 {
        return self.buffer.items;
    }

    pub fn destroy(self: *StdinBuffer) void {
        self.clear();
    }

    fn emitDataSequence(self: *StdinBuffer, sequence: []const u8) void {
        const raw_codepoint = decodeSingleCodepoint(sequence);
        if (raw_codepoint) |codepoint| {
            if (self.pending_kitty_printable_codepoint) |pending| {
                if (pending == codepoint) {
                    self.pending_kitty_printable_codepoint = null;
                    return;
                }
            }
        }

        self.pending_kitty_printable_codepoint = parseUnmodifiedKittyPrintableCodepoint(sequence);
        for (self.data_listeners.items) |listener| listener.call(sequence);
    }

    fn consumePasteBuffer(self: *StdinBuffer) error{OutOfMemory}!void {
        const snapshot = try self.allocator.dupe(u8, self.paste_buffer.items);
        defer self.allocator.free(snapshot);

        if (std.mem.indexOf(u8, snapshot, BRACKETED_PASTE_END)) |end_index| {
            const pasted_content = snapshot[0..end_index];
            const remaining = snapshot[end_index + BRACKETED_PASTE_END.len ..];

            self.paste_mode = false;
            self.paste_buffer.clearRetainingCapacity();
            self.timeout_remaining_ms = null;
            self.pending_kitty_printable_codepoint = null;
            for (self.paste_listeners.items) |listener| listener.call(pasted_content);

            if (remaining.len > 0) {
                const remaining_copy = try self.allocator.dupe(u8, remaining);
                defer self.allocator.free(remaining_copy);
                try self.process(remaining_copy);
            }
        }
    }
};

const ExtractedSequences = struct {
    sequences: [][]u8,
    remainder_index: usize,
};

fn freeExtracted(allocator: std.mem.Allocator, extracted: ExtractedSequences) void {
    freeFlushed(allocator, extracted.sequences);
}

fn freeFlushed(allocator: std.mem.Allocator, sequences: [][]u8) void {
    for (sequences) |sequence| allocator.free(sequence);
    allocator.free(sequences);
}

fn extractCompleteSequences(allocator: std.mem.Allocator, input: []const u8) error{OutOfMemory}!ExtractedSequences {
    var sequences = std.ArrayList([]u8).empty;
    errdefer freeFlushed(allocator, sequences.items);

    var pos: usize = 0;
    while (pos < input.len) {
        const remaining = input[pos..];
        if (remaining[0] == ESC) {
            var seq_end: usize = 1;
            while (seq_end <= remaining.len) {
                const candidate = remaining[0..seq_end];
                switch (isCompleteSequence(candidate)) {
                    .complete => {
                        if (candidate.len == 2 and candidate[0] == ESC and candidate[1] == ESC and seq_end < remaining.len) {
                            const next_char = remaining[seq_end];
                            if (next_char == '[' or next_char == ']' or next_char == 'O' or next_char == 'P' or next_char == '_') {
                                try sequences.append(allocator, try allocator.dupe(u8, remaining[0..1]));
                                pos += 1;
                                break;
                            }
                        }
                        try sequences.append(allocator, try allocator.dupe(u8, candidate));
                        pos += seq_end;
                        break;
                    },
                    .incomplete => {
                        seq_end += 1;
                    },
                    .not_escape => {
                        try sequences.append(allocator, try allocator.dupe(u8, candidate));
                        pos += seq_end;
                        break;
                    },
                }

                if (seq_end > remaining.len) {
                    return .{
                        .sequences = try sequences.toOwnedSlice(allocator),
                        .remainder_index = pos,
                    };
                }
            }
        } else {
            const end = nextUtf8SliceEnd(remaining);
            try sequences.append(allocator, try allocator.dupe(u8, remaining[0..end]));
            pos += end;
        }
    }

    return .{
        .sequences = try sequences.toOwnedSlice(allocator),
        .remainder_index = input.len,
    };
}

fn isCompleteSequence(data: []const u8) SequenceStatus {
    if (data.len == 0 or data[0] != ESC) return .not_escape;
    if (data.len == 1) return .incomplete;
    const after_esc = data[1..];

    if (after_esc[0] == '[') {
        if (after_esc.len >= 2 and after_esc[1] == 'M') {
            return if (data.len >= 6) .complete else .incomplete;
        }
        return isCompleteCsiSequence(data);
    }

    if (after_esc[0] == ']') return isCompleteOscSequence(data);
    if (after_esc[0] == 'P') return isCompleteDcsSequence(data);
    if (after_esc[0] == '_') return isCompleteApcSequence(data);
    if (after_esc[0] == 'O') return if (after_esc.len >= 2) .complete else .incomplete;
    if (after_esc.len == 1) return .complete;
    return .complete;
}

fn isCompleteCsiSequence(data: []const u8) SequenceStatus {
    if (!std.mem.startsWith(u8, data, "\x1b[")) return .complete;
    if (data.len < 3) return .incomplete;
    const payload = data[2..];
    if (payload.len == 0) return .incomplete;
    const last = payload[payload.len - 1];
    if (last < 0x40 or last > 0x7e) return .incomplete;

    if (payload[0] == '<') {
        return if (isSgrMouseSequence(payload)) .complete else .incomplete;
    }

    return .complete;
}

fn isSgrMouseSequence(payload: []const u8) bool {
    if (payload.len < 3 or payload[0] != '<') return false;
    var index: usize = 1;
    inline for (0..3) |part_index| {
        var digits = false;
        while (index < payload.len and std.ascii.isDigit(payload[index])) : (index += 1) {
            digits = true;
        }
        if (!digits) return false;
        if (part_index < 2) {
            if (index >= payload.len or payload[index] != ';') return false;
            index += 1;
        }
    }

    return index + 1 == payload.len and (payload[index] == 'M' or payload[index] == 'm');
}

fn isCompleteOscSequence(data: []const u8) SequenceStatus {
    if (!std.mem.startsWith(u8, data, "\x1b]")) return .complete;
    if (data.len < 3) return .incomplete;
    if (std.mem.endsWith(u8, data, "\x1b\\")) return .complete;
    if (data[data.len - 1] == 0x07) return .complete;
    return .incomplete;
}

fn isCompleteDcsSequence(data: []const u8) SequenceStatus {
    if (!std.mem.startsWith(u8, data, "\x1bP")) return .complete;
    if (data.len < 3) return .incomplete;
    return if (std.mem.endsWith(u8, data, "\x1b\\")) .complete else .incomplete;
}

fn isCompleteApcSequence(data: []const u8) SequenceStatus {
    if (!std.mem.startsWith(u8, data, "\x1b_")) return .complete;
    if (data.len < 3) return .incomplete;
    return if (std.mem.endsWith(u8, data, "\x1b\\")) .complete else .incomplete;
}

fn nextUtf8SliceEnd(input: []const u8) usize {
    if (input.len == 0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch 1;
    return @min(input.len, len);
}

fn decodeSingleCodepoint(sequence: []const u8) ?u21 {
    if (sequence.len == 0) return null;
    const len = nextUtf8SliceEnd(sequence);
    if (len != sequence.len) return null;
    return std.unicode.utf8Decode(sequence) catch null;
}

fn parseUnmodifiedKittyPrintableCodepoint(sequence: []const u8) ?u21 {
    if (!std.mem.startsWith(u8, sequence, "\x1b[") or sequence.len < 4 or sequence[sequence.len - 1] != 'u') return null;
    const body = sequence[2 .. sequence.len - 1];
    if (body.len == 0) return null;
    for (body) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    const codepoint = std.fmt.parseInt(u21, body, 10) catch return null;
    return if (codepoint >= 32) codepoint else null;
}

const SequenceCollector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Self) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    fn clear(self: *Self) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.clearRetainingCapacity();
    }

    fn append(self: *Self, value: []const u8) void {
        const copy = self.allocator.dupe(u8, value) catch @panic("out of memory");
        self.items.append(self.allocator, copy) catch @panic("out of memory");
    }
};

const TestHarness = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    buffer: StdinBuffer,
    emitted: *SequenceCollector,
    pasted: *SequenceCollector,

    fn init(allocator: std.mem.Allocator) !Self {
        const emitted = try allocator.create(SequenceCollector);
        errdefer allocator.destroy(emitted);
        emitted.* = SequenceCollector.init(allocator);

        const pasted = try allocator.create(SequenceCollector);
        errdefer {
            pasted.deinit();
            allocator.destroy(pasted);
        }
        pasted.* = SequenceCollector.init(allocator);

        var buffer = StdinBuffer.init(allocator, .{ .timeout_ms = 10 });
        errdefer buffer.deinit();

        try buffer.onData(.{ .context = emitted, .call_fn = collectorListener });
        try buffer.onPaste(.{ .context = pasted, .call_fn = collectorListener });

        return .{
            .allocator = allocator,
            .buffer = buffer,
            .emitted = emitted,
            .pasted = pasted,
        };
    }

    fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.emitted.deinit();
        self.allocator.destroy(self.emitted);
        self.pasted.deinit();
        self.allocator.destroy(self.pasted);
    }

    fn reset(self: *Self) void {
        self.emitted.clear();
        self.pasted.clear();
    }
};

fn collectorListener(context: ?*anyopaque, sequence: []const u8) void {
    const collector: *SequenceCollector = @ptrCast(@alignCast(context.?));
    collector.append(sequence);
}

fn expectSequences(actual: []const []u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |sequence, index| {
        try std.testing.expectEqualStrings(sequence, actual[index]);
    }
}

fn sleepAndPoll(buffer: *StdinBuffer, milliseconds: u64) !void {
    try buffer.advanceTimeout(milliseconds);
}

test "StdinBuffer regular characters" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("a");
    try h.buffer.process("bc");
    try h.buffer.process("hello 世界");

    try expectSequences(h.emitted.items.items, &.{
        "a",
        "b",
        "c",
        "h",
        "e",
        "l",
        "l",
        "o",
        " ",
        "世",
        "界",
    });
}

test "StdinBuffer complete escape sequences" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("\x1b[<35;20;5m");
    try h.buffer.process("\x1b[A");
    try h.buffer.process("\x1b[11~");
    try h.buffer.process("\x1ba");
    try h.buffer.process("\x1bOA");

    try expectSequences(h.emitted.items.items, &.{
        "\x1b[<35;20;5m",
        "\x1b[A",
        "\x1b[11~",
        "\x1ba",
        "\x1bOA",
    });
}

test "StdinBuffer partial escape sequences" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("\x1b");
    try std.testing.expectEqualStrings("\x1b", h.buffer.getBuffer());
    try std.testing.expectEqual(@as(usize, 0), h.emitted.items.items.len);

    try h.buffer.process("[<35");
    try std.testing.expectEqualStrings("\x1b[<35", h.buffer.getBuffer());
    try std.testing.expectEqual(@as(usize, 0), h.emitted.items.items.len);

    try h.buffer.process(";20;5m");
    try expectSequences(h.emitted.items.items, &.{"\x1b[<35;20;5m"});
    try std.testing.expectEqualStrings("", h.buffer.getBuffer());

    h.reset();
    try h.buffer.process("\x1b[");
    try h.buffer.process("1;");
    try h.buffer.process("5H");
    try expectSequences(h.emitted.items.items, &.{"\x1b[1;5H"});

    h.reset();
    try h.buffer.process("\x1b[<35");
    try sleepAndPoll(&h.buffer, 15);
    try expectSequences(h.emitted.items.items, &.{"\x1b[<35"});
}

test "StdinBuffer mixed content" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("abc\x1b[A");
    try expectSequences(h.emitted.items.items, &.{ "a", "b", "c", "\x1b[A" });

    h.reset();
    try h.buffer.process("\x1b[Aabc");
    try expectSequences(h.emitted.items.items, &.{ "\x1b[A", "a", "b", "c" });

    h.reset();
    try h.buffer.process("\x1b[A\x1b[B\x1b[C");
    try expectSequences(h.emitted.items.items, &.{ "\x1b[A", "\x1b[B", "\x1b[C" });

    h.reset();
    try h.buffer.process("abc\x1b[<35");
    try expectSequences(h.emitted.items.items, &.{ "a", "b", "c" });
    try std.testing.expectEqualStrings("\x1b[<35", h.buffer.getBuffer());
    try h.buffer.process(";20;5m");
    try expectSequences(h.emitted.items.items, &.{ "a", "b", "c", "\x1b[<35;20;5m" });
}

test "StdinBuffer kitty keyboard protocol" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("\x1b[97u");
    try h.buffer.process("\x1b[97;1:3u");
    try h.buffer.process("\x1b[97u\x1b[97;1:3u");
    try h.buffer.process("\x1b[97u\x1b[97;1:3u\x1b[98u\x1b[98;1:3u");
    try h.buffer.process("\x1b[1;1:1A");
    try h.buffer.process("\x1b[3;1:3~");
    try h.buffer.process("\x1b\x1b[27;129:3u");
    try h.buffer.process("\x1b\x1b[27;1:3u");
    try h.buffer.process("\x1b\x1b");
    try h.buffer.process("a\x1b[97;1:3u");
    try h.buffer.process("\x1b[224uà");
    try h.buffer.process("\x1b[64u");
    try h.buffer.process("@");
    try h.buffer.process("\x1b[97ub");
    try h.buffer.process("\x1b[64;3u@");
    try h.buffer.process("\x1b[104u\x1b[104;1:3u\x1b[105u\x1b[105;1:3u");

    try expectSequences(h.emitted.items.items, &.{
        "\x1b[97u",
        "\x1b[97;1:3u",
        "\x1b[97u",
        "\x1b[97;1:3u",
        "\x1b[97u",
        "\x1b[97;1:3u",
        "\x1b[98u",
        "\x1b[98;1:3u",
        "\x1b[1;1:1A",
        "\x1b[3;1:3~",
        "\x1b",
        "\x1b[27;129:3u",
        "\x1b",
        "\x1b[27;1:3u",
        "\x1b\x1b",
        "a",
        "\x1b[97;1:3u",
        "\x1b[224u",
        "\x1b[64u",
        "\x1b[97u",
        "b",
        "\x1b[64;3u",
        "@",
        "\x1b[104u",
        "\x1b[104;1:3u",
        "\x1b[105u",
        "\x1b[105;1:3u",
    });
}

test "StdinBuffer mouse events" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("\x1b[<0;10;5M");
    try h.buffer.process("\x1b[<0;10;5m");
    try h.buffer.process("\x1b[<35;20;5m");
    try expectSequences(h.emitted.items.items, &.{
        "\x1b[<0;10;5M",
        "\x1b[<0;10;5m",
        "\x1b[<35;20;5m",
    });

    h.buffer.clear();
    h.reset();
    try h.buffer.process("\x1b[<3");
    try h.buffer.process("5;1");
    try h.buffer.process("5;");
    try h.buffer.process("10m");
    try expectSequences(h.emitted.items.items, &.{
        "\x1b[<35;15;10m",
    });

    h.buffer.clear();
    h.reset();
    try h.buffer.process("\x1b[<35;1;1m\x1b[<35;2;2m\x1b[<35;3;3m");
    try expectSequences(h.emitted.items.items, &.{
        "\x1b[<35;1;1m",
        "\x1b[<35;2;2m",
        "\x1b[<35;3;3m",
    });

    h.buffer.clear();
    h.reset();
    try h.buffer.process("\x1b[M abc");
    try expectSequences(h.emitted.items.items, &.{
        "\x1b[M ab",
        "c",
    });

    h.buffer.clear();
    h.reset();
    try h.buffer.process("\x1b[M");
    try std.testing.expectEqualStrings("\x1b[M", h.buffer.getBuffer());
    try h.buffer.process(" a");
    try std.testing.expectEqualStrings("\x1b[M a", h.buffer.getBuffer());
    try h.buffer.process("b");
    try expectSequences(h.emitted.items.items, &.{
        "\x1b[M ab",
    });
    try std.testing.expectEqualStrings("", h.buffer.getBuffer());
}

test "StdinBuffer edge cases" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("");
    try std.testing.expectEqual(@as(usize, 1), h.emitted.items.items.len);
    try std.testing.expectEqualStrings("", h.emitted.items.items[0]);

    h.reset();
    try h.buffer.process("\x1b");
    try std.testing.expectEqual(@as(usize, 0), h.emitted.items.items.len);
    try sleepAndPoll(&h.buffer, 15);
    try expectSequences(h.emitted.items.items, &.{"\x1b"});

    h.reset();
    try h.buffer.process("\x1b");
    const flushed = try h.buffer.flush();
    defer freeFlushed(allocator, flushed);
    try expectSequences(flushed, &.{"\x1b"});
    try std.testing.expectEqualStrings("", h.buffer.getBuffer());

    h.reset();
    try h.buffer.process(&[_]u8{ ESC, '[', 'A' });
    try expectSequences(h.emitted.items.items, &.{"\x1b[A"});

    h.reset();
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);
    try builder.appendSlice(allocator, "\x1b[");
    var i: usize = 0;
    while (i < 50) : (i += 1) try builder.appendSlice(allocator, "1;");
    try builder.appendSlice(allocator, "H");
    try h.buffer.process(builder.items);
    try expectSequences(h.emitted.items.items, &.{builder.items});
}

test "StdinBuffer flush" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("\x1b[<35");
    const flushed = try h.buffer.flush();
    defer freeFlushed(allocator, flushed);
    try expectSequences(flushed, &.{"\x1b[<35"});
    try std.testing.expectEqualStrings("", h.buffer.getBuffer());

    const empty_flush = try h.buffer.flush();
    defer freeFlushed(allocator, empty_flush);
    try expectSequences(empty_flush, &.{});
}

test "StdinBuffer clear" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("\x1b[<35");
    try std.testing.expectEqualStrings("\x1b[<35", h.buffer.getBuffer());
    h.buffer.clear();
    try std.testing.expectEqualStrings("", h.buffer.getBuffer());
    try std.testing.expectEqual(@as(usize, 0), h.emitted.items.items.len);
}

test "StdinBuffer bracketed paste" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process(BRACKETED_PASTE_START ++ "hello world" ++ BRACKETED_PASTE_END);
    try expectSequences(h.pasted.items.items, &.{"hello world"});
    try std.testing.expectEqual(@as(usize, 0), h.emitted.items.items.len);

    h.reset();
    try h.buffer.process(BRACKETED_PASTE_START);
    try h.buffer.process("hello ");
    try h.buffer.process("world" ++ BRACKETED_PASTE_END);
    try expectSequences(h.pasted.items.items, &.{"hello world"});

    h.reset();
    try h.buffer.process("a");
    try h.buffer.process(BRACKETED_PASTE_START ++ "pasted" ++ BRACKETED_PASTE_END);
    try h.buffer.process("b");
    try expectSequences(h.emitted.items.items, &.{ "a", "b" });
    try expectSequences(h.pasted.items.items, &.{"pasted"});

    h.reset();
    try h.buffer.process(BRACKETED_PASTE_START ++ "line1\nline2\nline3" ++ BRACKETED_PASTE_END);
    try expectSequences(h.pasted.items.items, &.{"line1\nline2\nline3"});

    h.reset();
    try h.buffer.process(BRACKETED_PASTE_START ++ "Hello 世界 🎉" ++ BRACKETED_PASTE_END);
    try expectSequences(h.pasted.items.items, &.{"Hello 世界 🎉"});
}

test "StdinBuffer destroy" {
    const allocator = std.testing.allocator;
    var h = try TestHarness.init(allocator);
    defer h.deinit();

    try h.buffer.process("\x1b[<35");
    try std.testing.expectEqualStrings("\x1b[<35", h.buffer.getBuffer());
    h.buffer.destroy();
    try std.testing.expectEqualStrings("", h.buffer.getBuffer());

    h.reset();
    try h.buffer.process("\x1b[<35");
    h.buffer.destroy();
    try sleepAndPoll(&h.buffer, 15);
    try std.testing.expectEqual(@as(usize, 0), h.emitted.items.items.len);
}
