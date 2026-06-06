const std = @import("std");

const ai = @import("bulb_ai");
const auth_storage = @import("auth_storage.zig");
const config_value = @import("resolve_config_value.zig");
const extensions = @import("extensions/root.zig");
const messages = @import("messages.zig");
const model_registry = @import("model_registry.zig");
const session_manager = @import("session_manager.zig");
const source_info = @import("source_info.zig");

pub const MessageEndListener = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, messages.CodingAgentMessage) void,

    pub fn call(self: MessageEndListener, message: messages.CodingAgentMessage) void {
        self.call_fn(self.ptr, message);
    }
};

pub const SessionEventBridge = struct {
    allocator: std.mem.Allocator,
    message_end_replacements: std.ArrayList(extensions.MessageEndEmitResult) = .empty,
    message_end_listeners: std.ArrayList(MessageEndListener) = .empty,

    pub fn init(allocator: std.mem.Allocator) SessionEventBridge {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionEventBridge) void {
        for (self.message_end_replacements.items) |*replacement| replacement.deinit();
        self.message_end_replacements.deinit(self.allocator);
        self.message_end_listeners.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn onMessageEnd(self: *SessionEventBridge, listener: MessageEndListener) !void {
        try self.message_end_listeners.append(self.allocator, listener);
    }

    pub fn handleMessageEnd(
        self: *SessionEventBridge,
        io: std.Io,
        runner: *extensions.ExtensionRunner,
        sessions: *session_manager.SessionManager,
        message: *messages.CodingAgentMessage,
    ) !void {
        try self.emitMessageEndExtensions(runner, message);
        self.emitMessageEnd(message.*);
        try persistMessageEnd(io, sessions, self.allocator, message.*);
    }

    fn emitMessageEndExtensions(
        self: *SessionEventBridge,
        runner: *extensions.ExtensionRunner,
        message: *messages.CodingAgentMessage,
    ) !void {
        var replacement = (try runner.emitMessageEndAlloc(
            self.allocator,
            .{ .message = message.* },
        )) orelse return;
        var stored = false;
        errdefer if (!stored) replacement.deinit();

        try self.message_end_replacements.append(self.allocator, replacement);
        stored = true;
        message.* = self.message_end_replacements.items[self.message_end_replacements.items.len - 1].message;
    }

    fn emitMessageEnd(self: *SessionEventBridge, message: messages.CodingAgentMessage) void {
        for (self.message_end_listeners.items) |listener| listener.call(message);
    }
};

fn persistMessageEnd(
    io: std.Io,
    sessions: *session_manager.SessionManager,
    allocator: std.mem.Allocator,
    message: messages.CodingAgentMessage,
) !void {
    switch (message) {
        .custom => |custom| {
            const content_json = try customContentJsonAlloc(allocator, custom.content);
            defer allocator.free(content_json);
            _ = try sessions.appendCustomMessageEntryJson(
                io,
                custom.custom_type,
                content_json,
                custom.display,
                custom.details_json,
            );
        },
        .user, .assistant, .tool_result => {
            _ = try sessions.appendMessage(io, message);
        },
        .bash_execution, .branch_summary, .compaction_summary => {},
    }
}

fn customContentJsonAlloc(
    allocator: std.mem.Allocator,
    content: messages.CustomContent,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };

    switch (content) {
        .text => |text| try json.write(text),
        .parts => |parts| try writeUserContentArray(&json, parts),
    }

    return output.toOwnedSlice();
}

fn writeUserContentArray(json: *std.json.Stringify, content: []const ai.UserContent) !void {
    try json.beginArray();
    for (content) |part| {
        try json.beginObject();
        switch (part) {
            .text => |text| {
                try json.objectField("type");
                try json.write("text");
                try json.objectField("text");
                try json.write(text.text);
            },
            .image => |image| {
                try json.objectField("type");
                try json.write("image");
                try json.objectField("data");
                try json.write(image.data);
                try json.objectField("mimeType");
                try json.write(image.mime_type);
            },
        }
        try json.endObject();
    }
    try json.endArray();
}

test "AgentSession message_end replacements update memory public event and persistence" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();
    var handler_arena = std.heap.ArenaAllocator.init(allocator);
    defer handler_arena.deinit();

    var state = MessageEndReplacementState{ .allocator = handler_arena.allocator() };
    const handlers = [_]extensions.ExtensionHandler{.{
        .ptr = &state,
        .event_name = .message_end,
        .handler_fn = MessageEndReplacementState.handler,
    }};
    const extension_list = [_]extensions.Extension{
        testExtension("/tmp/message-end-cost.zig", &handlers),
    };
    var runner = extensions.ExtensionRunner.init(
        allocator,
        &extension_list,
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();

    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();
    var observed = MessageEndObserver{};
    try bridge.onMessageEnd(.{ .ptr = &observed, .call_fn = MessageEndObserver.onMessageEnd });

    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "original" } }};
    var message = messages.CodingAgentMessage{ .assistant = .{
        .content = &content,
        .api = ai.types.api.openai_responses,
        .provider = "openai",
        .model = "gpt-test",
        .usage = .{
            .input = 1,
            .output = 1,
            .total_tokens = 2,
            .cost = .{ .total = 0.001 },
        },
        .timestamp_ms = 42,
    } };

    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &message);

    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqualStrings("patched", message.assistant.content[0].text.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0.123), message.assistant.usage.cost.total, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.123), observed.assistant_cost_total.?, 0.000001);

    const entries = harness.sessions.getEntries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try expectEntryType(entries[0], "message");
    try expectPersistedAssistantTextAndCost(allocator, entries[0], "patched", 0.123);
}

test "AgentSession message_end skips persistence for bash and summary messages" {
    const allocator = std.testing.allocator;
    var harness = try TestHarness.init(allocator);
    defer harness.deinit();

    var runner = extensions.ExtensionRunner.init(
        allocator,
        &.{},
        harness.runtime,
        "/tmp",
        harness.sessions,
        harness.registry,
    );
    defer runner.deinit();
    var bridge = SessionEventBridge.init(allocator);
    defer bridge.deinit();

    var bash_message = messages.CodingAgentMessage{ .bash_execution = .{
        .command = "zig build",
        .output = "ok",
        .timestamp_ms = 1,
    } };
    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &bash_message);

    var summary_message = messages.CodingAgentMessage{ .compaction_summary = .{
        .summary = "summary",
        .tokens_before = 10,
        .timestamp_ms = 2,
    } };
    try bridge.handleMessageEnd(std.testing.io, &runner, harness.sessions, &summary_message);

    try std.testing.expectEqual(@as(usize, 0), harness.sessions.getEntries().len);
}

const MessageEndReplacementState = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn handler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = ctx;
        const state: *@This() = @ptrCast(@alignCast(ptr.?));
        if (event_value.message_end.message != .assistant) return null;
        state.calls += 1;
        return try std.json.parseFromSliceLeaky(
            std.json.Value,
            state.allocator,
            \\{
            \\  "message": {
            \\    "role": "assistant",
            \\    "content": [{ "type": "text", "text": "patched" }],
            \\    "api": "openai-responses",
            \\    "provider": "openai",
            \\    "model": "gpt-test",
            \\    "usage": {
            \\      "input": 1,
            \\      "output": 1,
            \\      "cacheRead": 0,
            \\      "cacheWrite": 0,
            \\      "totalTokens": 2,
            \\      "cost": {
            \\        "input": 0,
            \\        "output": 0,
            \\        "cacheRead": 0,
            \\        "cacheWrite": 0,
            \\        "total": 0.123
            \\      }
            \\    },
            \\    "stopReason": "stop",
            \\    "timestamp": 42
            \\  }
            \\}
        ,
            .{},
        );
    }
};

const MessageEndObserver = struct {
    assistant_cost_total: ?f64 = null,

    fn onMessageEnd(ptr: ?*anyopaque, message: messages.CodingAgentMessage) void {
        const observer: *@This() = @ptrCast(@alignCast(ptr.?));
        if (message == .assistant) observer.assistant_cost_total = message.assistant.usage.cost.total;
    }
};

const TestHarness = struct {
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    oauth_registry: *ai.oauth.Registry,
    resolver: *config_value.Resolver,
    storage: *auth_storage.AuthStorage,
    registry: *model_registry.ModelRegistry,
    sessions: *session_manager.SessionManager,
    runtime: *extensions.loader.ExtensionRuntimeController,

    fn init(allocator: std.mem.Allocator) !TestHarness {
        const env = try allocator.create(std.process.Environ.Map);
        errdefer allocator.destroy(env);
        env.* = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();

        const oauth_registry = try allocator.create(ai.oauth.Registry);
        errdefer allocator.destroy(oauth_registry);
        oauth_registry.* = try ai.oauth.Registry.init(allocator);
        errdefer oauth_registry.deinit();

        const resolver = try allocator.create(config_value.Resolver);
        errdefer allocator.destroy(resolver);
        resolver.* = config_value.Resolver.init(allocator, env);
        errdefer resolver.deinit();

        const storage = try allocator.create(auth_storage.AuthStorage);
        errdefer allocator.destroy(storage);
        storage.* = try auth_storage.AuthStorage.initMemory(allocator, env, oauth_registry, resolver);
        errdefer storage.deinit();

        const registry = try allocator.create(model_registry.ModelRegistry);
        errdefer allocator.destroy(registry);
        registry.* = try model_registry.ModelRegistry.inMemory(allocator, storage);
        errdefer registry.deinit();

        const sessions = try allocator.create(session_manager.SessionManager);
        errdefer allocator.destroy(sessions);
        sessions.* = try session_manager.SessionManager.inMemory(allocator, std.testing.io, null);
        errdefer sessions.deinit();

        const runtime = try allocator.create(extensions.loader.ExtensionRuntimeController);
        errdefer allocator.destroy(runtime);
        runtime.* = extensions.createExtensionRuntime(allocator);
        errdefer runtime.deinit();

        return .{
            .allocator = allocator,
            .env = env,
            .oauth_registry = oauth_registry,
            .resolver = resolver,
            .storage = storage,
            .registry = registry,
            .sessions = sessions,
            .runtime = runtime,
        };
    }

    fn deinit(self: *TestHarness) void {
        self.runtime.deinit();
        self.allocator.destroy(self.runtime);
        self.sessions.deinit();
        self.allocator.destroy(self.sessions);
        self.registry.deinit();
        self.allocator.destroy(self.registry);
        self.storage.deinit();
        self.allocator.destroy(self.storage);
        self.resolver.deinit();
        self.allocator.destroy(self.resolver);
        self.oauth_registry.deinit();
        self.allocator.destroy(self.oauth_registry);
        self.env.deinit();
        self.allocator.destroy(self.env);
    }
};

fn testExtension(path: []const u8, handlers: []const extensions.ExtensionHandler) extensions.Extension {
    return .{
        .path = path,
        .resolved_path = path,
        .source_info = source_info.createSyntheticSourceInfo(path, .{ .source = "test" }),
        .handlers = handlers,
    };
}

fn expectEntryType(entry: session_manager.FileEntry, expected: []const u8) !void {
    const actual = entry.entry_type orelse return error.MissingEntryType;
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectPersistedAssistantTextAndCost(
    allocator: std.mem.Allocator,
    entry: session_manager.FileEntry,
    expected_text: []const u8,
    expected_cost_total: f64,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry.raw_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const message_value = parsed.value.object.get("message") orelse return error.MissingMessage;
    try std.testing.expect(message_value == .object);

    const role_value = message_value.object.get("role") orelse return error.MissingRole;
    try std.testing.expect(role_value == .string);
    try std.testing.expectEqualStrings("assistant", role_value.string);

    const content_value = message_value.object.get("content") orelse return error.MissingContent;
    try std.testing.expect(content_value == .array);
    try std.testing.expect(content_value.array.items.len > 0);
    const first_content = content_value.array.items[0];
    try std.testing.expect(first_content == .object);
    const text_value = first_content.object.get("text") orelse return error.MissingText;
    try std.testing.expect(text_value == .string);
    try std.testing.expectEqualStrings(expected_text, text_value.string);

    const usage_value = message_value.object.get("usage") orelse return error.MissingUsage;
    try std.testing.expect(usage_value == .object);
    const cost_value = usage_value.object.get("cost") orelse return error.MissingCost;
    try std.testing.expect(cost_value == .object);
    const total_value = cost_value.object.get("total") orelse return error.MissingCostTotal;
    const total = switch (total_value) {
        .float => |value| value,
        .integer => |value| @as(f64, @floatFromInt(value)),
        else => return error.InvalidCostTotal,
    };
    try std.testing.expectApproxEqAbs(expected_cost_total, total, 0.000001);
}
