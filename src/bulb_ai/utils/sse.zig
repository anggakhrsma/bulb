const std = @import("std");

pub const ServerSentEvent = struct {
    event: ?[]u8,
    data: []u8,
    raw: [][]u8,

    pub fn deinit(self: *ServerSentEvent, allocator: std.mem.Allocator) void {
        if (self.event) |event_name| allocator.free(event_name);
        allocator.free(self.data);
        for (self.raw) |line| allocator.free(line);
        allocator.free(self.raw);
    }
};

pub const ServerSentEvents = struct {
    allocator: std.mem.Allocator,
    events: []ServerSentEvent,

    pub fn deinit(self: *ServerSentEvents) void {
        for (self.events) |*event| event.deinit(self.allocator);
        self.allocator.free(self.events);
    }
};

const DecoderState = struct {
    event: ?[]u8 = null,
    data: std.ArrayList([]u8) = .empty,
    raw: std.ArrayList([]u8) = .empty,

    fn deinit(self: *DecoderState, allocator: std.mem.Allocator) void {
        if (self.event) |event_name| allocator.free(event_name);
        for (self.data.items) |part| allocator.free(part);
        self.data.deinit(allocator);
        for (self.raw.items) |line| allocator.free(line);
        self.raw.deinit(allocator);
    }
};

pub fn decodeAll(allocator: std.mem.Allocator, body: []const u8) !ServerSentEvents {
    var output: std.ArrayList(ServerSentEvent) = .empty;
    errdefer {
        for (output.items) |*event| event.deinit(allocator);
        output.deinit(allocator);
    }

    var state: DecoderState = .{};
    defer state.deinit(allocator);

    var index: usize = 0;
    while (index < body.len) {
        const relative_break = nextLineBreakIndex(body[index..]) orelse break;
        const line_break = index + relative_break;
        try decodeLine(allocator, body[index..line_break], &state, &output);

        index = line_break + 1;
        if (body[line_break] == '\r' and index < body.len and body[index] == '\n') {
            index += 1;
        }
    }

    if (index < body.len) {
        try decodeLine(allocator, body[index..], &state, &output);
    }
    try flushEvent(allocator, &state, &output);

    return .{
        .allocator = allocator,
        .events = try output.toOwnedSlice(allocator),
    };
}

fn decodeLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    state: *DecoderState,
    output: *std.ArrayList(ServerSentEvent),
) !void {
    if (line.len == 0) {
        try flushEvent(allocator, state, output);
        return;
    }

    try state.raw.append(allocator, try allocator.dupe(u8, line));

    if (line[0] == ':') return;

    const delimiter_index = std.mem.indexOfScalar(u8, line, ':');
    const field_name = if (delimiter_index) |delimiter| line[0..delimiter] else line;
    var value = if (delimiter_index) |delimiter| line[delimiter + 1 ..] else "";
    if (value.len > 0 and value[0] == ' ') value = value[1..];

    if (std.mem.eql(u8, field_name, "event")) {
        if (state.event) |event_name| allocator.free(event_name);
        state.event = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, field_name, "data")) {
        try state.data.append(allocator, try allocator.dupe(u8, value));
    }
}

fn flushEvent(
    allocator: std.mem.Allocator,
    state: *DecoderState,
    output: *std.ArrayList(ServerSentEvent),
) !void {
    if (state.event == null and state.data.items.len == 0) return;

    const data = try joinDataLines(allocator, state.data.items);
    for (state.data.items) |part| allocator.free(part);
    state.data.clearRetainingCapacity();

    const raw = try state.raw.toOwnedSlice(allocator);
    const event = state.event;
    state.event = null;
    state.raw = .empty;

    errdefer {
        if (event) |event_name| allocator.free(event_name);
        allocator.free(data);
        for (raw) |line| allocator.free(line);
        allocator.free(raw);
    }
    try output.append(allocator, .{
        .event = event,
        .data = data,
        .raw = raw,
    });
}

fn joinDataLines(allocator: std.mem.Allocator, lines: []const []u8) ![]u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");

    var size: usize = lines.len - 1;
    for (lines) |line| size += line.len;

    const joined = try allocator.alloc(u8, size);
    var cursor: usize = 0;
    for (lines, 0..) |line, line_index| {
        if (line_index > 0) {
            joined[cursor] = '\n';
            cursor += 1;
        }
        @memcpy(joined[cursor .. cursor + line.len], line);
        cursor += line.len;
    }
    return joined;
}

fn nextLineBreakIndex(text: []const u8) ?usize {
    const carriage_return_index = std.mem.indexOfScalar(u8, text, '\r');
    const newline_index = std.mem.indexOfScalar(u8, text, '\n');
    if (carriage_return_index == null) return newline_index;
    if (newline_index == null) return carriage_return_index;
    return @min(carriage_return_index.?, newline_index.?);
}

test "SSE decoder joins data lines, preserves raw fields, and handles CRLF" {
    const allocator = std.testing.allocator;
    var events = try decodeAll(allocator, "event: message\r\ndata: first\r\ndata: second\r\n: comment\r\nignored: value\r\n\r\n");
    defer events.deinit();

    try std.testing.expectEqual(@as(usize, 1), events.events.len);
    try std.testing.expectEqualStrings("message", events.events[0].event.?);
    try std.testing.expectEqualStrings("first\nsecond", events.events[0].data);
    try std.testing.expectEqual(@as(usize, 5), events.events[0].raw.len);
}

test "SSE decoder flushes trailing events without a final blank line" {
    const allocator = std.testing.allocator;
    var events = try decodeAll(allocator, "event: done\ndata: [DONE]");
    defer events.deinit();

    try std.testing.expectEqual(@as(usize, 1), events.events.len);
    try std.testing.expectEqualStrings("done", events.events[0].event.?);
    try std.testing.expectEqualStrings("[DONE]", events.events[0].data);
}
