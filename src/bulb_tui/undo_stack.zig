const std = @import("std");

pub fn UndoStack(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        stack: std.ArrayList(T) = .empty,
        clone_fn: *const fn (std.mem.Allocator, T) anyerror!T,
        deinit_fn: ?*const fn (std.mem.Allocator, *T) void = null,

        pub fn init(
            allocator: std.mem.Allocator,
            clone_fn: *const fn (std.mem.Allocator, T) anyerror!T,
            deinit_fn: ?*const fn (std.mem.Allocator, *T) void,
        ) Self {
            return .{
                .allocator = allocator,
                .clone_fn = clone_fn,
                .deinit_fn = deinit_fn,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.stack.deinit(self.allocator);
        }

        pub fn push(self: *Self, state: T) !void {
            try self.stack.append(self.allocator, try self.clone_fn(self.allocator, state));
        }

        pub fn pop(self: *Self) ?T {
            if (self.stack.items.len == 0) return null;
            return self.stack.pop();
        }

        pub fn clear(self: *Self) void {
            if (self.deinit_fn) |deinit_fn| {
                for (self.stack.items) |*item| deinit_fn(self.allocator, item);
            }
            self.stack.clearRetainingCapacity();
        }

        pub fn len(self: *const Self) usize {
            return self.stack.items.len;
        }
    };
}

test "UndoStack" {
    const allocator = std.testing.allocator;

    const Snapshot = struct {
        const Self = @This();

        text: []u8,

        fn clone(a: std.mem.Allocator, value: Self) !Self {
            return .{ .text = try a.dupe(u8, value.text) };
        }

        fn deinit(a: std.mem.Allocator, value: *Self) void {
            a.free(value.text);
        }
    };

    var stack = UndoStack(Snapshot).init(allocator, Snapshot.clone, Snapshot.deinit);
    defer stack.deinit();

    const first = try allocator.dupe(u8, "first");
    defer allocator.free(first);
    try stack.push(.{ .text = first });

    const second = try allocator.dupe(u8, "second");
    defer allocator.free(second);
    try stack.push(.{ .text = second });
    try std.testing.expectEqual(@as(usize, 2), stack.len());

    var popped = stack.pop().?;
    defer Snapshot.deinit(allocator, &popped);
    try std.testing.expectEqualStrings("second", popped.text);
    try std.testing.expectEqual(@as(usize, 1), stack.len());
}
