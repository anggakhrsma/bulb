const std = @import("std");

pub const PushOptions = struct {
    prepend: bool,
    accumulate: bool = false,
};

pub const KillRing = struct {
    allocator: std.mem.Allocator,
    ring: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) KillRing {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *KillRing) void {
        for (self.ring.items) |entry| self.allocator.free(entry);
        self.ring.deinit(self.allocator);
    }

    pub fn push(self: *KillRing, text: []const u8, opts: PushOptions) !void {
        if (text.len == 0) return;

        if (opts.accumulate and self.ring.items.len > 0) {
            const last = self.ring.pop().?;
            const combined = if (opts.prepend)
                try std.mem.concat(self.allocator, u8, &.{ text, last })
            else
                try std.mem.concat(self.allocator, u8, &.{ last, text });
            self.allocator.free(last);
            try self.ring.append(self.allocator, combined);
            return;
        }

        try self.ring.append(self.allocator, try self.allocator.dupe(u8, text));
    }

    pub fn peek(self: *const KillRing) ?[]const u8 {
        if (self.ring.items.len == 0) return null;
        return self.ring.items[self.ring.items.len - 1];
    }

    pub fn rotate(self: *KillRing) void {
        if (self.ring.items.len <= 1) return;

        const last = self.ring.pop().?;
        self.ring.appendAssumeCapacity(last);
        const count = self.ring.items.len;
        std.mem.copyBackwards([]u8, self.ring.items[1..count], self.ring.items[0 .. count - 1]);
        self.ring.items[0] = last;
    }

    pub fn len(self: *const KillRing) usize {
        return self.ring.items.len;
    }
};

test "KillRing" {
    const allocator = std.testing.allocator;
    var ring = KillRing.init(allocator);
    defer ring.deinit();

    try ring.push("", .{ .prepend = true });
    try std.testing.expectEqual(@as(usize, 0), ring.len());

    try ring.push("first", .{ .prepend = true });
    try ring.push("second", .{ .prepend = true });
    try std.testing.expectEqualStrings("second", ring.peek().?);

    try ring.push("third", .{ .prepend = true, .accumulate = true });
    try std.testing.expectEqualStrings("thirdsecond", ring.peek().?);

    try ring.push("fourth", .{ .prepend = false, .accumulate = true });
    try std.testing.expectEqualStrings("thirdsecondfourth", ring.peek().?);

    ring.rotate();
    try std.testing.expectEqualStrings("first", ring.peek().?);
}
