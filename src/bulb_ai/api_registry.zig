const std = @import("std");
const simple_options = @import("providers/simple_options.zig");
const types = @import("types.zig");

pub const CompleteFn = *const fn (
    context: *anyopaque,
    model: types.Model,
    prompt: types.Context,
    options: types.StreamOptions,
) anyerror!types.AssistantMessage;

pub const StreamFn = *const fn (
    context: *anyopaque,
    model: types.Model,
    prompt: types.Context,
    options: types.StreamOptions,
) anyerror!types.StreamResult;

pub const StreamSimpleFn = *const fn (
    context: *anyopaque,
    model: types.Model,
    prompt: types.Context,
    options: ?simple_options.SimpleStreamOptions,
) anyerror!types.StreamResult;

pub const SimpleStream = struct {
    context: *anyopaque,
    stream_fn: StreamSimpleFn,
};

pub const Provider = struct {
    api: []const u8,
    context: *anyopaque,
    complete_fn: ?CompleteFn = null,
    stream_fn: ?StreamFn = null,
    stream_simple_fn: ?StreamSimpleFn = null,
    source_id: ?[]const u8 = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayList(Provider) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit(self.allocator);
    }

    pub fn register(self: *Registry, provider: Provider) !void {
        if (provider.source_id) |source_id| {
            self.unregisterSource(source_id);
        } else {
            self.unregisterUnsourced(provider.api);
        }
        try self.providers.append(self.allocator, provider);
    }

    pub fn unregister(self: *Registry, api_name: []const u8) void {
        var index = self.providers.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.providers.items[index].api, api_name)) {
                _ = self.providers.orderedRemove(index);
            }
        }
    }

    pub fn unregisterSource(self: *Registry, source_id: []const u8) void {
        var index = self.providers.items.len;
        while (index > 0) {
            index -= 1;
            const registered_source = self.providers.items[index].source_id orelse continue;
            if (std.mem.eql(u8, registered_source, source_id)) {
                _ = self.providers.orderedRemove(index);
            }
        }
    }

    pub fn get(self: Registry, api_name: []const u8) ?Provider {
        var index = self.providers.items.len;
        while (index > 0) {
            index -= 1;
            const provider = self.providers.items[index];
            if (std.mem.eql(u8, provider.api, api_name)) return provider;
        }
        return null;
    }

    pub fn complete(
        self: Registry,
        model: types.Model,
        prompt: types.Context,
        options: types.StreamOptions,
    ) !types.AssistantMessage {
        const provider = self.get(model.api) orelse return error.ApiProviderNotRegistered;
        const complete_fn = provider.complete_fn orelse return error.ApiProviderDoesNotSupportComplete;
        return complete_fn(provider.context, model, prompt, options);
    }

    pub fn stream(
        self: Registry,
        model: types.Model,
        prompt: types.Context,
        options: types.StreamOptions,
    ) !types.StreamResult {
        const provider = self.get(model.api) orelse return error.ApiProviderNotRegistered;
        if (provider.stream_fn) |stream_fn| return stream_fn(provider.context, model, prompt, options);
        const stream_simple_fn = provider.stream_simple_fn orelse return error.ApiProviderDoesNotSupportStream;
        return stream_simple_fn(provider.context, model, prompt, .{ .base = options });
    }

    pub fn streamSimple(
        self: Registry,
        model: types.Model,
        prompt: types.Context,
        options: ?simple_options.SimpleStreamOptions,
    ) !types.StreamResult {
        const provider = self.get(model.api) orelse return error.ApiProviderNotRegistered;
        const stream_simple_fn = provider.stream_simple_fn orelse return error.ApiProviderDoesNotSupportSimpleStream;
        return stream_simple_fn(provider.context, model, prompt, options);
    }

    fn unregisterUnsourced(self: *Registry, api_name: []const u8) void {
        var index = self.providers.items.len;
        while (index > 0) {
            index -= 1;
            const provider = self.providers.items[index];
            if (provider.source_id == null and std.mem.eql(u8, provider.api, api_name)) {
                _ = self.providers.orderedRemove(index);
            }
        }
    }
};

const TestSimpleStreamContext = struct {
    calls: usize = 0,
    marker: []const u8,
};

fn testSimpleStream(
    ptr: *anyopaque,
    model: types.Model,
    _: types.Context,
    _: ?simple_options.SimpleStreamOptions,
) !types.StreamResult {
    const context: *TestSimpleStreamContext = @ptrCast(@alignCast(ptr));
    context.calls += 1;
    return .{
        .allocator = std.testing.allocator,
        .message = .{
            .content = &.{},
            .api = model.api,
            .provider = context.marker,
            .model = model.id,
        },
    };
}

test "API registry removes sourced overrides and reveals previous provider" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var builtin = TestSimpleStreamContext{ .marker = "builtin" };
    var extension = TestSimpleStreamContext{ .marker = "extension" };
    const model: types.Model = .{
        .id = "test",
        .name = "Test",
        .api = types.api.openai_completions,
        .provider = "openai",
        .base_url = "http://localhost",
    };

    try registry.register(.{
        .api = model.api,
        .context = &builtin,
        .stream_simple_fn = testSimpleStream,
    });
    try registry.register(.{
        .api = model.api,
        .context = &extension,
        .stream_simple_fn = testSimpleStream,
        .source_id = "provider:extension",
    });

    var overridden = try registry.streamSimple(model, .{ .messages = &.{} }, null);
    defer overridden.deinit();
    try std.testing.expectEqualStrings("extension", overridden.message.provider);

    registry.unregisterSource("provider:extension");
    var restored = try registry.streamSimple(model, .{ .messages = &.{} }, null);
    defer restored.deinit();
    try std.testing.expectEqualStrings("builtin", restored.message.provider);
}

test "API registry delegates regular streams to simple-only providers" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var context = TestSimpleStreamContext{ .marker = "simple" };
    const model: types.Model = .{
        .id = "test",
        .name = "Test",
        .api = "simple-only",
        .provider = "simple-only",
        .base_url = "http://localhost",
    };

    try registry.register(.{
        .api = model.api,
        .context = &context,
        .stream_simple_fn = testSimpleStream,
    });
    var result = try registry.stream(model, .{ .messages = &.{} }, .{ .max_tokens = 123 });
    defer result.deinit();
    try std.testing.expectEqualStrings("simple", result.message.provider);
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}
