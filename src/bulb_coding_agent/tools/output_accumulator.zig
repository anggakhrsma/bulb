const std = @import("std");

const truncate = @import("truncate.zig");

pub const OutputAccumulatorOptions = struct {
    max_lines: usize = truncate.DEFAULT_MAX_LINES,
    max_bytes: usize = truncate.DEFAULT_MAX_BYTES,
    temp_file_prefix: []const u8 = "bulb-output",
};

pub const OutputSnapshot = struct {
    truncation: truncate.TruncationResult,
    full_output_path: ?[]u8 = null,

    pub fn content(self: *const OutputSnapshot) []const u8 {
        return self.truncation.content;
    }

    pub fn deinit(self: *OutputSnapshot, allocator: std.mem.Allocator) void {
        self.truncation.deinit(allocator);
        if (self.full_output_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

pub const OutputAccumulator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    max_lines: usize,
    max_bytes: usize,
    max_rolling_bytes: usize,
    temp_file_prefix: []u8,
    raw_chunks: std.ArrayList([]u8) = .empty,
    tail_text: std.ArrayList(u8) = .empty,
    pending_utf8: std.ArrayList(u8) = .empty,
    tail_bytes: usize = 0,
    tail_starts_at_line_boundary: bool = true,
    total_raw_bytes: usize = 0,
    total_decoded_bytes: usize = 0,
    completed_lines: usize = 0,
    total_lines: usize = 0,
    current_line_bytes: usize = 0,
    has_open_line: bool = false,
    finished: bool = false,
    temp_file_path: ?[]u8 = null,
    temp_file: ?std.Io.File = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: OutputAccumulatorOptions,
    ) !OutputAccumulator {
        return .{
            .allocator = allocator,
            .io = io,
            .max_lines = options.max_lines,
            .max_bytes = options.max_bytes,
            .max_rolling_bytes = @max(options.max_bytes * 2, 1),
            .temp_file_prefix = try allocator.dupe(u8, options.temp_file_prefix),
        };
    }

    pub fn deinit(self: *OutputAccumulator) void {
        for (self.raw_chunks.items) |chunk| self.allocator.free(chunk);
        self.raw_chunks.deinit(self.allocator);
        self.tail_text.deinit(self.allocator);
        self.pending_utf8.deinit(self.allocator);
        self.allocator.free(self.temp_file_prefix);
        if (self.temp_file) |file| file.close(self.io);
        if (self.temp_file_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn append(self: *OutputAccumulator, data: []const u8) !void {
        if (self.finished) return error.OutputAccumulatorFinished;

        self.total_raw_bytes += data.len;
        const decoded = try self.decodeStreamingAlloc(data, false);
        defer self.allocator.free(decoded);
        try self.appendDecodedText(decoded);

        if (self.temp_file != null or self.shouldUseTempFile()) {
            try self.ensureTempFile();
            try self.temp_file.?.writeStreamingAll(self.io, data);
        } else if (data.len > 0) {
            try self.raw_chunks.append(self.allocator, try self.allocator.dupe(u8, data));
        }
    }

    pub fn finish(self: *OutputAccumulator) !void {
        if (self.finished) return;
        self.finished = true;

        const decoded = try self.decodeStreamingAlloc("", true);
        defer self.allocator.free(decoded);
        try self.appendDecodedText(decoded);

        if (self.shouldUseTempFile()) {
            try self.ensureTempFile();
        }
    }

    pub fn snapshot(self: *OutputAccumulator, persist_if_truncated: bool) !OutputSnapshot {
        const snapshot_text = self.snapshotText();
        var tail_truncation = try truncate.truncateTailAlloc(self.allocator, snapshot_text, .{
            .max_lines = self.max_lines,
            .max_bytes = self.max_bytes,
        });
        errdefer tail_truncation.deinit(self.allocator);

        const truncated_value = self.total_lines > self.max_lines or self.total_decoded_bytes > self.max_bytes;
        if (truncated_value) {
            tail_truncation.truncated = true;
            if (tail_truncation.truncated_by == null) {
                tail_truncation.truncated_by = if (self.total_decoded_bytes > self.max_bytes) .bytes else .lines;
            }
            tail_truncation.total_lines = self.total_lines;
            tail_truncation.total_bytes = self.total_decoded_bytes;
            tail_truncation.max_lines = self.max_lines;
            tail_truncation.max_bytes = self.max_bytes;
        }

        if (persist_if_truncated and tail_truncation.truncated) {
            try self.ensureTempFile();
        }

        return .{
            .truncation = tail_truncation,
            .full_output_path = if (self.temp_file_path) |path| try self.allocator.dupe(u8, path) else null,
        };
    }

    pub fn closeTempFile(self: *OutputAccumulator) void {
        if (self.temp_file) |file| {
            file.close(self.io);
            self.temp_file = null;
        }
    }

    pub fn getLastLineBytes(self: *const OutputAccumulator) usize {
        return self.current_line_bytes;
    }

    fn appendDecodedText(self: *OutputAccumulator, text: []const u8) !void {
        if (text.len == 0) return;

        self.total_decoded_bytes += text.len;
        try self.tail_text.appendSlice(self.allocator, text);
        self.tail_bytes += text.len;
        if (self.tail_bytes > self.max_rolling_bytes * 2) {
            try self.trimTail();
        }

        var newlines: usize = 0;
        var last_newline: ?usize = null;
        var index: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, index, '\n')) |newline| {
            newlines += 1;
            last_newline = newline;
            index = newline + 1;
        }

        if (newlines == 0) {
            self.current_line_bytes += text.len;
            self.has_open_line = true;
        } else {
            self.completed_lines += newlines;
            const tail = text[last_newline.? + 1 ..];
            self.current_line_bytes = tail.len;
            self.has_open_line = tail.len > 0;
        }
        self.total_lines = self.completed_lines + if (self.has_open_line) @as(usize, 1) else 0;
    }

    fn trimTail(self: *OutputAccumulator) !void {
        if (self.tail_text.items.len <= self.max_rolling_bytes) {
            self.tail_bytes = self.tail_text.items.len;
            return;
        }

        var start = self.tail_text.items.len - self.max_rolling_bytes;
        while (start < self.tail_text.items.len and isUtf8Continuation(self.tail_text.items[start])) {
            start += 1;
        }

        if (start > 0) {
            self.tail_starts_at_line_boundary = self.tail_text.items[start - 1] == '\n';
        }

        const remaining = self.tail_text.items[start..];
        @memmove(self.tail_text.items[0..remaining.len], remaining);
        self.tail_text.shrinkRetainingCapacity(remaining.len);
        self.tail_bytes = self.tail_text.items.len;
    }

    fn snapshotText(self: *const OutputAccumulator) []const u8 {
        if (self.tail_starts_at_line_boundary) return self.tail_text.items;
        const first_newline = std.mem.indexOfScalar(u8, self.tail_text.items, '\n') orelse return self.tail_text.items;
        return self.tail_text.items[first_newline + 1 ..];
    }

    fn shouldUseTempFile(self: *const OutputAccumulator) bool {
        return self.total_raw_bytes > self.max_bytes or
            self.total_decoded_bytes > self.max_bytes or
            self.total_lines > self.max_lines;
    }

    fn ensureTempFile(self: *OutputAccumulator) !void {
        if (self.temp_file_path == null) {
            self.temp_file_path = try tempFilePathAlloc(self.allocator, self.temp_file_prefix);
            self.temp_file = try std.Io.Dir.cwd().createFile(self.io, self.temp_file_path.?, .{
                .read = false,
                .truncate = true,
            });
            for (self.raw_chunks.items) |chunk| {
                try self.temp_file.?.writeStreamingAll(self.io, chunk);
                self.allocator.free(chunk);
            }
            self.raw_chunks.clearRetainingCapacity();
        }
    }

    fn decodeStreamingAlloc(self: *OutputAccumulator, data: []const u8, flush: bool) ![]u8 {
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.allocator);
        try combined.appendSlice(self.allocator, self.pending_utf8.items);
        try combined.appendSlice(self.allocator, data);
        self.pending_utf8.clearRetainingCapacity();

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);

        var index: usize = 0;
        while (index < combined.items.len) {
            const first = combined.items[index];
            const width = std.unicode.utf8ByteSequenceLength(first) catch {
                try output.append(self.allocator, first);
                index += 1;
                continue;
            };

            if (index + width > combined.items.len) {
                if (flush) {
                    try output.appendSlice(self.allocator, combined.items[index..]);
                    index = combined.items.len;
                } else {
                    try self.pending_utf8.appendSlice(self.allocator, combined.items[index..]);
                    break;
                }
            } else {
                const slice = combined.items[index .. index + width];
                _ = std.unicode.utf8Decode(slice) catch {
                    try output.append(self.allocator, first);
                    index += 1;
                    continue;
                };
                try output.appendSlice(self.allocator, slice);
                index += width;
            }
        }

        return output.toOwnedSlice(self.allocator);
    }
};

pub fn tempFilePathAlloc(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const id = temp_file_counter.fetchAdd(1, .monotonic);
    const file_name = try std.fmt.allocPrint(allocator, "{s}-{x}.log", .{ prefix, id });
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ "/tmp", file_name });
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

var temp_file_counter: std.atomic.Value(usize) = .init(0);

test "output accumulator keeps split UTF-8 chunks and ignores trailing newline line count" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var output = try OutputAccumulator.init(allocator, io, .{ .max_lines = 2, .max_bytes = 1024 });
    defer output.deinit();

    const euro = "€\n";
    try output.append(euro[0..1]);
    try output.append(euro[1..]);
    try output.append("two\nthree\n");
    try output.finish();

    var snapshot = try output.snapshot(false);
    defer snapshot.deinit(allocator);

    try std.testing.expect(snapshot.truncation.truncated);
    try std.testing.expectEqual(truncate.TruncationKind.lines, snapshot.truncation.truncated_by.?);
    try std.testing.expectEqual(@as(usize, 3), snapshot.truncation.total_lines);
    try std.testing.expectEqual(@as(usize, 2), snapshot.truncation.output_lines);
    try std.testing.expectEqualStrings("two\nthree", snapshot.content());
}

test "output accumulator persists full output when line truncation wins" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var output = try OutputAccumulator.init(allocator, io, .{
        .max_lines = 2,
        .max_bytes = 1024,
        .temp_file_prefix = "bulb-output-test",
    });
    defer output.deinit();

    try output.append("one\ntwo\nthree\n");
    try output.finish();

    var snapshot = try output.snapshot(true);
    defer snapshot.deinit(allocator);
    output.closeTempFile();

    try std.testing.expect(snapshot.truncation.truncated);
    try std.testing.expect(snapshot.full_output_path != null);
    defer std.Io.Dir.cwd().deleteFile(io, snapshot.full_output_path.?) catch {};

    var file = try std.Io.Dir.cwd().openFile(io, snapshot.full_output_path.?, .{ .mode = .read_only });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const full = try reader.interface.allocRemaining(allocator, .limited(1024));
    defer allocator.free(full);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", full);
}
