const std = @import("std");

const extension_types = @import("extensions/types.zig");

pub const EventBus = extension_types.EventBus;
pub const EventBusSubscriber = extension_types.EventBusSubscriber;
pub const Unsubscribe = extension_types.Unsubscribe;

pub const EventBusController = struct {
    allocator: std.mem.Allocator,
    subscriptions: std.ArrayList(Subscription) = .empty,
    unsubscribe_states: std.ArrayList(*UnsubscribeState) = .empty,
    next_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator) EventBusController {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EventBusController) void {
        self.clear();
        self.subscriptions.deinit(self.allocator);
        for (self.unsubscribe_states.items) |state| self.allocator.destroy(state);
        self.unsubscribe_states.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn emit(self: *EventBusController, channel: []const u8, data: std.json.Value) void {
        for (self.subscriptions.items) |subscription| {
            if (!subscription.active or !std.mem.eql(u8, channel, subscription.channel)) continue;
            subscription.subscriber.handler_fn(subscription.subscriber.ptr, channel, data) catch {};
        }
    }

    pub fn on(self: *EventBusController, channel: []const u8, subscriber: EventBusSubscriber) !Unsubscribe {
        const owned_channel = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(owned_channel);

        const id = self.next_id;
        self.next_id += 1;
        try self.subscriptions.append(self.allocator, .{
            .id = id,
            .channel = owned_channel,
            .subscriber = subscriber,
        });

        const state = try self.allocator.create(UnsubscribeState);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .bus = self,
            .index = self.subscriptions.items.len - 1,
            .id = id,
        };
        try self.unsubscribe_states.append(self.allocator, state);
        return .{ .ptr = state, .unsubscribe_fn = unsubscribe };
    }

    pub fn clear(self: *EventBusController) void {
        for (self.subscriptions.items) |*subscription| {
            if (subscription.channel.len > 0) self.allocator.free(subscription.channel);
            subscription.channel = "";
            subscription.active = false;
        }
        self.subscriptions.clearRetainingCapacity();
    }

    pub fn asEventBus(self: *EventBusController) EventBus {
        return .{
            .ptr = self,
            .emit_fn = emitBridge,
            .on_fn = onBridge,
        };
    }
};

const Subscription = struct {
    id: usize,
    channel: []u8,
    subscriber: EventBusSubscriber,
    active: bool = true,
};

const UnsubscribeState = struct {
    bus: *EventBusController,
    index: usize,
    id: usize,
};

fn emitBridge(ptr: ?*anyopaque, channel: []const u8, data: std.json.Value) !void {
    const bus: *EventBusController = @ptrCast(@alignCast(ptr.?));
    bus.emit(channel, data);
}

fn onBridge(ptr: ?*anyopaque, channel: []const u8, subscriber: EventBusSubscriber) !Unsubscribe {
    const bus: *EventBusController = @ptrCast(@alignCast(ptr.?));
    return bus.on(channel, subscriber);
}

fn unsubscribe(ptr: ?*anyopaque) void {
    const state: *UnsubscribeState = @ptrCast(@alignCast(ptr.?));
    if (state.index >= state.bus.subscriptions.items.len) return;
    var subscription = &state.bus.subscriptions.items[state.index];
    if (subscription.id != state.id or !subscription.active) return;

    state.bus.allocator.free(subscription.channel);
    subscription.channel = "";
    subscription.active = false;
}

test "event bus emits matching channels and ignores others" {
    var bus = EventBusController.init(std.testing.allocator);
    defer bus.deinit();

    var calls: usize = 0;
    const Handler = struct {
        fn call(ptr: ?*anyopaque, channel: []const u8, data: std.json.Value) !void {
            _ = channel;
            try std.testing.expectEqualStrings("payload", data.string);
            const count: *usize = @ptrCast(@alignCast(ptr.?));
            count.* += 1;
        }
    };

    const sub = try bus.on("session", .{ .ptr = &calls, .handler_fn = Handler.call });
    defer sub.unsubscribe();

    bus.emit("other", .{ .string = "payload" });
    bus.emit("session", .{ .string = "payload" });
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "event bus unsubscribe and clear remove listeners" {
    var bus = EventBusController.init(std.testing.allocator);
    defer bus.deinit();

    var calls: usize = 0;
    const Handler = struct {
        fn call(ptr: ?*anyopaque, channel: []const u8, data: std.json.Value) !void {
            _ = channel;
            _ = data;
            const count: *usize = @ptrCast(@alignCast(ptr.?));
            count.* += 1;
        }
    };

    const first = try bus.on("input", .{ .ptr = &calls, .handler_fn = Handler.call });
    first.unsubscribe();
    bus.emit("input", .{ .null = {} });
    try std.testing.expectEqual(@as(usize, 0), calls);

    _ = try bus.on("input", .{ .ptr = &calls, .handler_fn = Handler.call });
    bus.clear();
    bus.emit("input", .{ .null = {} });
    try std.testing.expectEqual(@as(usize, 0), calls);
}

test "event bus swallows subscriber errors like Pi" {
    var bus = EventBusController.init(std.testing.allocator);
    defer bus.deinit();

    var calls: usize = 0;
    const Handler = struct {
        fn fail(ptr: ?*anyopaque, channel: []const u8, data: std.json.Value) !void {
            _ = ptr;
            _ = channel;
            _ = data;
            return error.HandlerFailed;
        }

        fn count(ptr: ?*anyopaque, channel: []const u8, data: std.json.Value) !void {
            _ = channel;
            _ = data;
            const counter: *usize = @ptrCast(@alignCast(ptr.?));
            counter.* += 1;
        }
    };

    _ = try bus.on("tick", .{ .handler_fn = Handler.fail });
    _ = try bus.on("tick", .{ .ptr = &calls, .handler_fn = Handler.count });
    bus.emit("tick", .{ .null = {} });
    try std.testing.expectEqual(@as(usize, 1), calls);
}
