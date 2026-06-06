const std = @import("std");

pub const FileMutationGuard = struct {
    entry: *QueueEntry,
    locked: bool = true,

    pub fn deinit(self: *FileMutationGuard, io: std.Io) void {
        if (!self.locked) return;
        const entry = self.entry;
        entry.mutex.unlock(io);
        registry.release(io, entry);
        self.locked = false;
    }
};

const QueueEntry = struct {
    key: []u8,
    mutex: std.Io.Mutex = .init,
    ref_count: usize = 0,
};

const QueueRegistry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(*QueueEntry) = .empty,

    fn acquire(self: *QueueRegistry, io: std.Io, key: []const u8) !*QueueEntry {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.entries.get(key)) |entry| {
            entry.ref_count += 1;
            return entry;
        }

        const owned_key = try std.heap.smp_allocator.dupe(u8, key);
        errdefer std.heap.smp_allocator.free(owned_key);
        const entry = try std.heap.smp_allocator.create(QueueEntry);
        errdefer std.heap.smp_allocator.destroy(entry);
        entry.* = .{ .key = owned_key, .ref_count = 1 };
        try self.entries.put(std.heap.smp_allocator, entry.key, entry);
        return entry;
    }

    fn release(self: *QueueRegistry, io: std.Io, entry: *QueueEntry) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        std.debug.assert(entry.ref_count > 0);
        entry.ref_count -= 1;
        if (entry.ref_count != 0) return;

        const removed = self.entries.remove(entry.key);
        std.debug.assert(removed);
        std.heap.smp_allocator.free(entry.key);
        std.heap.smp_allocator.destroy(entry);
    }
};

var registry: QueueRegistry = .{};

pub fn lockFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) !FileMutationGuard {
    const key = try mutationQueueKeyAlloc(allocator, io, file_path);
    defer allocator.free(key);

    const entry = try registry.acquire(io, key);
    entry.mutex.lockUncancelable(io);
    return .{ .entry = entry };
}

pub fn mutationQueueKeyAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) ![]u8 {
    const resolved = try std.fs.path.resolve(allocator, &.{file_path});
    errdefer allocator.free(resolved);

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = std.Io.Dir.cwd().realPathFile(io, resolved, &buffer) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return resolved,
        else => return err,
    };
    allocator.free(resolved);
    return allocator.dupe(u8, buffer[0..real_len]);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

const SameFileThreadContext = struct {
    io: std.Io,
    path: []const u8,
    order: *std.ArrayList([]const u8),
    order_mutex: *std.Io.Mutex,
    hold_ms: i64 = 0,
};

fn appendOrder(ctx: *SameFileThreadContext, value: []const u8) void {
    ctx.order_mutex.lockUncancelable(ctx.io);
    defer ctx.order_mutex.unlock(ctx.io);
    ctx.order.append(std.testing.allocator, value) catch @panic("append failed");
}

fn queueWorker(ctx: *SameFileThreadContext, start: []const u8, end: []const u8) void {
    var guard = lockFileAlloc(std.testing.allocator, ctx.io, ctx.path) catch @panic("lock failed");
    defer guard.deinit(ctx.io);

    appendOrder(ctx, start);
    if (ctx.hold_ms > 0) {
        std.Io.sleep(ctx.io, .fromMilliseconds(ctx.hold_ms), .awake) catch @panic("sleep failed");
    }
    appendOrder(ctx, end);
}

fn firstWorker(ctx: *SameFileThreadContext) void {
    queueWorker(ctx, "first:start", "first:end");
}

fn secondWorker(ctx: *SameFileThreadContext) void {
    queueWorker(ctx, "second:start", "second:end");
}

test "file mutation queue serializes operations for the same file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(allocator);
    var order_mutex: std.Io.Mutex = .init;
    const path = "/tmp/bulb-file-mutation-queue-same";
    var first_ctx: SameFileThreadContext = .{
        .io = io,
        .path = path,
        .order = &order,
        .order_mutex = &order_mutex,
        .hold_ms = 30,
    };
    var second_ctx: SameFileThreadContext = .{
        .io = io,
        .path = path,
        .order = &order,
        .order_mutex = &order_mutex,
    };

    const first = try std.Thread.spawn(.{}, firstWorker, .{&first_ctx});
    try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    const second = try std.Thread.spawn(.{}, secondWorker, .{&second_ctx});
    first.join();
    second.join();

    try std.testing.expectEqual(@as(usize, 4), order.items.len);
    try std.testing.expectEqualStrings("first:start", order.items[0]);
    try std.testing.expectEqualStrings("first:end", order.items[1]);
    try std.testing.expectEqualStrings("second:start", order.items[2]);
    try std.testing.expectEqualStrings("second:end", order.items[3]);
}

test "file mutation queue allows different files to proceed in parallel" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(allocator);
    var order_mutex: std.Io.Mutex = .init;
    var a_ctx: SameFileThreadContext = .{
        .io = io,
        .path = "/tmp/bulb-file-mutation-queue-a",
        .order = &order,
        .order_mutex = &order_mutex,
        .hold_ms = 30,
    };
    var b_ctx: SameFileThreadContext = .{
        .io = io,
        .path = "/tmp/bulb-file-mutation-queue-b",
        .order = &order,
        .order_mutex = &order_mutex,
    };

    const first = try std.Thread.spawn(.{}, firstWorker, .{&a_ctx});
    try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    const second = try std.Thread.spawn(.{}, secondWorker, .{&b_ctx});
    first.join();
    second.join();

    try std.testing.expect(indexOfString(order.items, "first:start").? < indexOfString(order.items, "first:end").?);
    try std.testing.expect(indexOfString(order.items, "second:start").? < indexOfString(order.items, "second:end").?);
    try std.testing.expect(indexOfString(order.items, "second:start").? < indexOfString(order.items, "first:end").?);
}

test "file mutation queue uses the same queue for symlink aliases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);
    const target_path = try std.fs.path.join(allocator, &.{ root, "target.txt" });
    defer allocator.free(target_path);
    const alias_path = try std.fs.path.join(allocator, &.{ root, "alias.txt" });
    defer allocator.free(alias_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "target.txt", .data = "hello\n" });
    try std.Io.Dir.cwd().symLink(io, target_path, alias_path, .{});

    var order: std.ArrayList([]const u8) = .empty;
    defer order.deinit(allocator);
    var order_mutex: std.Io.Mutex = .init;
    var target_ctx: SameFileThreadContext = .{
        .io = io,
        .path = target_path,
        .order = &order,
        .order_mutex = &order_mutex,
        .hold_ms = 30,
    };
    var alias_ctx: SameFileThreadContext = .{
        .io = io,
        .path = alias_path,
        .order = &order,
        .order_mutex = &order_mutex,
    };

    const first = try std.Thread.spawn(.{}, firstWorker, .{&target_ctx});
    try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    const second = try std.Thread.spawn(.{}, secondWorker, .{&alias_ctx});
    first.join();
    second.join();

    try std.testing.expectEqual(@as(usize, 4), order.items.len);
    try std.testing.expectEqualStrings("first:start", order.items[0]);
    try std.testing.expectEqualStrings("first:end", order.items[1]);
    try std.testing.expectEqualStrings("second:start", order.items[2]);
    try std.testing.expectEqualStrings("second:end", order.items[3]);
}

fn indexOfString(values: []const []const u8, needle: []const u8) ?usize {
    for (values, 0..) |value, index| {
        if (std.mem.eql(u8, value, needle)) return index;
    }
    return null;
}
