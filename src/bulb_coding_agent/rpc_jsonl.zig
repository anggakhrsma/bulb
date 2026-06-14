const std = @import("std");

pub const JsonlLineCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, []const u8) anyerror!void,

    pub fn call(self: JsonlLineCallback, line: []const u8) !void {
        try self.call_fn(self.ptr, line);
    }
};

pub const JsonlLineReader = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    read_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) JsonlLineReader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *JsonlLineReader) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *JsonlLineReader, chunk: []const u8, callback: JsonlLineCallback) !void {
        if (chunk.len > 0) try self.buffer.appendSlice(self.allocator, chunk);
        try self.drain(callback, false);
    }

    pub fn finish(self: *JsonlLineReader, callback: JsonlLineCallback) !void {
        try self.drain(callback, true);
    }

    fn drain(self: *JsonlLineReader, callback: JsonlLineCallback, flush_remainder: bool) !void {
        while (true) {
            const newline_index = std.mem.indexOfScalarPos(u8, self.buffer.items, self.read_index, '\n') orelse break;
            try callback.call(trimTrailingCarriageReturn(self.buffer.items[self.read_index..newline_index]));
            self.read_index = newline_index + 1;
        }

        if (flush_remainder and self.read_index < self.buffer.items.len) {
            try callback.call(trimTrailingCarriageReturn(self.buffer.items[self.read_index..]));
            self.read_index = self.buffer.items.len;
        }

        self.compact();
    }

    fn compact(self: *JsonlLineReader) void {
        if (self.read_index == 0) return;

        if (self.read_index >= self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.read_index = 0;
            return;
        }

        if (self.read_index < 4096 and self.read_index < self.buffer.items.len / 2) return;

        const remaining = self.buffer.items[self.read_index..];
        std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
        self.buffer.shrinkRetainingCapacity(remaining.len);
        self.read_index = 0;
    }
};

pub fn serializeJsonLineAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);

    const output = try allocator.alloc(u8, json.len + 1);
    @memcpy(output[0..json.len], json);
    output[json.len] = '\n';
    return output;
}

fn trimTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

test "serializeJsonLineAlloc preserves unicode separators and appends LF" {
    const allocator = std.testing.allocator;
    const line = try serializeJsonLineAlloc(allocator, .{ .text = "a\u{2028}b\u{2029}c" });
    defer allocator.free(line);

    try std.testing.expect(std.mem.indexOf(u8, line, "a\u{2028}b\u{2029}c") != null);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line[0 .. line.len - 1], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\u{2028}b\u{2029}c", parsed.value.object.get("text").?.string);
}

test "JsonlLineReader splits on LF only and preserves unicode separators" {
    const allocator = std.testing.allocator;
    var reader = JsonlLineReader.init(allocator);
    defer reader.deinit();

    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    const collector = struct {
        fn call(ptr: ?*anyopaque, line: []const u8) !void {
            const self: *std.ArrayList([]u8) = @ptrCast(@alignCast(ptr.?));
            try self.append(std.testing.allocator, try std.testing.allocator.dupe(u8, line));
        }
    };

    const payload = try serializeJsonLineAlloc(allocator, .{ .text = "a\u{2028}b\u{2029}c" });
    defer allocator.free(payload);

    try reader.feed(payload, .{ .call_fn = collector.call, .ptr = &lines });
    try reader.finish(.{ .call_fn = collector.call, .ptr = &lines });

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[0], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\u{2028}b\u{2029}c", parsed.value.object.get("text").?.string);
}

test "JsonlLineReader handles CRLF-delimited input" {
    const allocator = std.testing.allocator;
    var reader = JsonlLineReader.init(allocator);
    defer reader.deinit();

    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    const collector = struct {
        fn call(ptr: ?*anyopaque, line: []const u8) !void {
            const self: *std.ArrayList([]u8) = @ptrCast(@alignCast(ptr.?));
            try self.append(std.testing.allocator, try std.testing.allocator.dupe(u8, line));
        }
    };

    try reader.feed("{\"a\":1}\r\n{\"b\":2}\r\n", .{ .call_fn = collector.call, .ptr = &lines });
    try reader.finish(.{ .call_fn = collector.call, .ptr = &lines });

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("{\"a\":1}", lines.items[0]);
    try std.testing.expectEqualStrings("{\"b\":2}", lines.items[1]);
}

test "JsonlLineReader emits a final line without trailing LF" {
    const allocator = std.testing.allocator;
    var reader = JsonlLineReader.init(allocator);
    defer reader.deinit();

    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    const collector = struct {
        fn call(ptr: ?*anyopaque, line: []const u8) !void {
            const self: *std.ArrayList([]u8) = @ptrCast(@alignCast(ptr.?));
            try self.append(std.testing.allocator, try std.testing.allocator.dupe(u8, line));
        }
    };

    try reader.feed("{\"a\":1}", .{ .call_fn = collector.call, .ptr = &lines });
    try reader.finish(.{ .call_fn = collector.call, .ptr = &lines });

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("{\"a\":1}", lines.items[0]);
}
