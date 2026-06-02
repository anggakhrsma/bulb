const std = @import("std");

pub const CleanupFn = *const fn (session_id: ?[]const u8) anyerror!void;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    cleanups: std.ArrayList(CleanupFn) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.cleanups.deinit(self.allocator);
    }

    pub fn register(self: *Registry, cleanup_fn: CleanupFn) !void {
        for (self.cleanups.items) |registered| {
            if (registered == cleanup_fn) return;
        }
        try self.cleanups.append(self.allocator, cleanup_fn);
    }

    pub fn unregister(self: *Registry, cleanup_fn: CleanupFn) void {
        for (self.cleanups.items, 0..) |registered, index| {
            if (registered == cleanup_fn) {
                _ = self.cleanups.swapRemove(index);
                return;
            }
        }
    }

    pub fn cleanup(self: Registry, session_id: ?[]const u8) !void {
        var first_error: ?anyerror = null;
        for (self.cleanups.items) |cleanup_fn| {
            cleanup_fn(session_id) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| return err;
    }
};

var cleanup_count: usize = 0;
var cleaned_session: ?[]const u8 = null;

fn recordCleanup(session_id: ?[]const u8) !void {
    cleanup_count += 1;
    cleaned_session = session_id;
}

fn failCleanup(_: ?[]const u8) !void {
    cleanup_count += 1;
    return error.CleanupFailed;
}

test "session resources deduplicate unregister and clean up by session" {
    cleanup_count = 0;
    cleaned_session = null;
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(recordCleanup);
    try registry.register(recordCleanup);
    try std.testing.expectEqual(@as(usize, 1), registry.cleanups.items.len);
    try registry.cleanup("session-1");
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
    try std.testing.expectEqualStrings("session-1", cleaned_session.?);

    registry.unregister(recordCleanup);
    try registry.cleanup("session-2");
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "session resources invoke all cleanup hooks before returning errors" {
    cleanup_count = 0;
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(failCleanup);
    try registry.register(recordCleanup);

    try std.testing.expectError(error.CleanupFailed, registry.cleanup(null));
    try std.testing.expectEqual(@as(usize, 2), cleanup_count);
}
