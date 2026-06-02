const std = @import("std");
const types = @import("../types.zig");

pub fn EventStream(comptime Event: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        const CompleteFn = *const fn (Event) bool;
        const ExtractFn = *const fn (Event) Result;

        allocator: std.mem.Allocator,
        queue: std.ArrayList(Event) = .empty,
        done: bool = false,
        final_result: ?Result = null,
        is_complete: CompleteFn,
        extract_result: ExtractFn,

        pub fn init(allocator: std.mem.Allocator, is_complete: CompleteFn, extract_result: ExtractFn) Self {
            return .{
                .allocator = allocator,
                .is_complete = is_complete,
                .extract_result = extract_result,
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
        }

        pub fn push(self: *Self, event: Event) !void {
            if (self.done) return;

            if (self.is_complete(event)) {
                self.done = true;
                self.final_result = self.extract_result(event);
            }

            try self.queue.append(self.allocator, event);
        }

        pub fn end(self: *Self, final_result: ?Result) void {
            self.done = true;
            if (final_result) |value| self.final_result = value;
        }

        pub fn next(self: *Self) ?Event {
            if (self.queue.items.len == 0) return null;
            return self.queue.orderedRemove(0);
        }

        pub fn result(self: Self) ?Result {
            return self.final_result;
        }
    };
}

pub const AssistantMessageEventResult = union(enum) {
    message: types.AssistantMessage,
    @"error": types.AssistantMessage,
};

pub const AssistantMessageEventStream = EventStream(types.StreamEvent, AssistantMessageEventResult);

pub fn createAssistantMessageEventStream(allocator: std.mem.Allocator) AssistantMessageEventStream {
    return AssistantMessageEventStream.init(allocator, assistantEventIsComplete, extractAssistantEventResult);
}

fn assistantEventIsComplete(event: types.StreamEvent) bool {
    return switch (event) {
        .@"error" => true,
        else => false,
    };
}

fn extractAssistantEventResult(event: types.StreamEvent) AssistantMessageEventResult {
    return switch (event) {
        .@"error" => |terminal| .{ .@"error" = terminal.message },
        else => unreachable,
    };
}

const SampleEvent = union(enum) {
    value: i32,
    done: i32,
};

fn sampleIsComplete(event: SampleEvent) bool {
    return switch (event) {
        .done => true,
        else => false,
    };
}

fn sampleExtractResult(event: SampleEvent) i32 {
    return switch (event) {
        .done => |value| value,
        else => unreachable,
    };
}

test "event stream queues events and resolves final result on complete event" {
    const allocator = std.testing.allocator;
    var stream = EventStream(SampleEvent, i32).init(allocator, sampleIsComplete, sampleExtractResult);
    defer stream.deinit();

    try stream.push(.{ .value = 1 });
    try stream.push(.{ .done = 42 });
    try stream.push(.{ .value = 99 });

    try std.testing.expectEqual(@as(i32, 1), stream.next().?.value);
    try std.testing.expectEqual(@as(i32, 42), stream.next().?.done);
    try std.testing.expect(stream.next() == null);
    try std.testing.expect(stream.done);
    try std.testing.expectEqual(@as(i32, 42), stream.result().?);
}

test "event stream can be ended with an explicit result" {
    const allocator = std.testing.allocator;
    var stream = EventStream(SampleEvent, i32).init(allocator, sampleIsComplete, sampleExtractResult);
    defer stream.deinit();

    stream.end(7);
    try stream.push(.{ .value = 1 });

    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqual(@as(i32, 7), stream.result().?);
}
