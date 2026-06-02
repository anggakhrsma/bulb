const std = @import("std");
const types = @import("../types.zig");

pub const HeaderRecord = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) HeaderRecord {
        return .{
            .allocator = allocator,
            .map = .init(allocator),
        };
    }

    pub fn deinit(self: *HeaderRecord) void {
        var keys = self.map.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        var values = self.map.valueIterator();
        while (values.next()) |value| self.allocator.free(value.*);
        self.map.deinit();
    }

    pub fn get(self: *const HeaderRecord, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }
};

pub fn headersToRecord(allocator: std.mem.Allocator, headers: []const types.Header) !HeaderRecord {
    var result = HeaderRecord.init(allocator);
    errdefer result.deinit();

    for (headers) |header| {
        if (result.map.fetchRemove(header.name)) |old| {
            allocator.free(old.key);
            allocator.free(old.value);
        }

        const key = try allocator.dupe(u8, header.name);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);

        try result.map.put(key, value);
    }

    return result;
}

test "headers convert ordered header entries into a record" {
    const allocator = std.testing.allocator;
    var record = try headersToRecord(allocator, &.{
        .{ .name = "content-type", .value = "text/event-stream" },
        .{ .name = "x-request-id", .value = "abc" },
        .{ .name = "x-request-id", .value = "override" },
    });
    defer record.deinit();

    try std.testing.expectEqual(@as(usize, 2), record.map.count());
    try std.testing.expectEqualStrings("text/event-stream", record.get("content-type").?);
    try std.testing.expectEqualStrings("override", record.get("x-request-id").?);
}
