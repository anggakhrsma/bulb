const std = @import("std");
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

pub const Provider = struct {
    api: []const u8,
    context: *anyopaque,
    complete_fn: CompleteFn,
    stream_fn: StreamFn,
};

pub const Registry = struct {
    providers: std.StringHashMap(Provider),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .providers = .init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit();
    }

    pub fn register(self: *Registry, provider: Provider) !void {
        try self.providers.put(provider.api, provider);
    }

    pub fn unregister(self: *Registry, api_name: []const u8) void {
        _ = self.providers.remove(api_name);
    }

    pub fn complete(
        self: Registry,
        model: types.Model,
        prompt: types.Context,
        options: types.StreamOptions,
    ) !types.AssistantMessage {
        const provider = self.providers.get(model.api) orelse return error.ApiProviderNotRegistered;
        return provider.complete_fn(provider.context, model, prompt, options);
    }

    pub fn stream(
        self: Registry,
        model: types.Model,
        prompt: types.Context,
        options: types.StreamOptions,
    ) !types.StreamResult {
        const provider = self.providers.get(model.api) orelse return error.ApiProviderNotRegistered;
        return provider.stream_fn(provider.context, model, prompt, options);
    }
};
