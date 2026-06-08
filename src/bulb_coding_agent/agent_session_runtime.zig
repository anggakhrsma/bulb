const std = @import("std");

const agent_session_services = @import("agent_session_services.zig");
const extensions = @import("extensions/root.zig");
const session_cwd = @import("session_cwd.zig");
const session_manager = @import("session_manager.zig");
const source_info = @import("source_info.zig");

const stale_session_message =
    "This extension ctx is stale after session replacement or reload. Do not use a captured Bulb ctx after session replacement or reload.";

pub const RuntimeError = error{
    ReplacedSessionContextUnavailable,
};

pub const CreateAgentSessionRuntimeOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    session_manager: *session_manager.SessionManager,
    session_start_event: ?extensions.SessionStartEvent = null,
};

pub const CreateAgentSessionRuntimeResult = struct {
    session: RuntimeSession,
    services: *agent_session_services.AgentSessionServices,
    model_fallback_message: ?[]const u8 = null,
};

pub const CreateAgentSessionRuntimeFactory = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, std.Io, CreateAgentSessionRuntimeOptions) anyerror!CreateAgentSessionRuntimeResult,

    pub fn call(
        self: CreateAgentSessionRuntimeFactory,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: CreateAgentSessionRuntimeOptions,
    ) !CreateAgentSessionRuntimeResult {
        return self.call_fn(self.ptr, allocator, io, options);
    }
};

pub const RuntimeSession = struct {
    ptr: *anyopaque,
    get_session_file_fn: *const fn (*anyopaque) ?[]const u8,
    get_session_manager_fn: *const fn (*anyopaque) *session_manager.SessionManager,
    get_extension_runner_fn: *const fn (*anyopaque) *extensions.ExtensionRunner,
    dispose_fn: *const fn (*anyopaque) void,
    create_replaced_session_context_fn: ?*const fn (*anyopaque) extensions.ReplacedSessionContext = null,
    refresh_session_context_fn: ?*const fn (*anyopaque) anyerror!void = null,

    pub fn getSessionFile(self: RuntimeSession) ?[]const u8 {
        return self.get_session_file_fn(self.ptr);
    }

    pub fn getSessionManager(self: RuntimeSession) *session_manager.SessionManager {
        return self.get_session_manager_fn(self.ptr);
    }

    pub fn getExtensionRunner(self: RuntimeSession) *extensions.ExtensionRunner {
        return self.get_extension_runner_fn(self.ptr);
    }

    pub fn dispose(self: RuntimeSession) void {
        self.dispose_fn(self.ptr);
    }

    pub fn createReplacedSessionContext(self: RuntimeSession) !extensions.ReplacedSessionContext {
        const create_fn = self.create_replaced_session_context_fn orelse return RuntimeError.ReplacedSessionContextUnavailable;
        return create_fn(self.ptr);
    }

    pub fn refreshSessionContext(self: RuntimeSession) !void {
        const refresh_fn = self.refresh_session_context_fn orelse return;
        try refresh_fn(self.ptr);
    }
};

pub const RebindSessionCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, RuntimeSession) anyerror!void,

    pub fn call(self: RebindSessionCallback, session: RuntimeSession) !void {
        try self.call_fn(self.ptr, session);
    }
};

pub const BeforeSessionInvalidateCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) anyerror!void,

    pub fn call(self: BeforeSessionInvalidateCallback) !void {
        try self.call_fn(self.ptr);
    }
};

pub const SessionChangeResult = struct {
    cancelled: bool = false,
};

pub const SwitchSessionOptions = struct {
    cwd_override: ?[]const u8 = null,
    with_session: ?extensions.types.WithSessionCallback = null,
};

pub const AgentSessionRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: RuntimeSession,
    services: *agent_session_services.AgentSessionServices,
    create_runtime: CreateAgentSessionRuntimeFactory,
    model_fallback_message: ?[]const u8 = null,
    rebind_session: ?RebindSessionCallback = null,
    before_session_invalidate: ?BeforeSessionInvalidateCallback = null,
    active: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        result: CreateAgentSessionRuntimeResult,
        create_runtime: CreateAgentSessionRuntimeFactory,
    ) AgentSessionRuntime {
        return .{
            .allocator = allocator,
            .io = io,
            .session = result.session,
            .services = result.services,
            .create_runtime = create_runtime,
            .model_fallback_message = result.model_fallback_message,
        };
    }

    pub fn getServices(self: *const AgentSessionRuntime) *agent_session_services.AgentSessionServices {
        return self.services;
    }

    pub fn cwd(self: *const AgentSessionRuntime) []const u8 {
        return self.services.cwd;
    }

    pub fn diagnostics(self: *const AgentSessionRuntime) []const agent_session_services.AgentSessionRuntimeDiagnostic {
        return self.services.diagnostics;
    }

    pub fn modelFallbackMessage(self: *const AgentSessionRuntime) ?[]const u8 {
        return self.model_fallback_message;
    }

    pub fn setRebindSession(self: *AgentSessionRuntime, callback: ?RebindSessionCallback) void {
        self.rebind_session = callback;
    }

    pub fn setBeforeSessionInvalidate(self: *AgentSessionRuntime, callback: ?BeforeSessionInvalidateCallback) void {
        self.before_session_invalidate = callback;
    }

    pub fn newSession(
        self: *AgentSessionRuntime,
        options: extensions.types.NewSessionOptions,
    ) !SessionChangeResult {
        const before_result = try self.emitBeforeSwitch(.new, null);
        if (before_result.cancelled) return before_result;

        const previous_session_file = self.session.getSessionFile();
        const agent_dir = try self.allocator.dupe(u8, self.services.agent_dir);
        defer self.allocator.free(agent_dir);
        const old_session_dir = try self.allocator.dupe(u8, self.session.getSessionManager().getSessionDir());
        defer self.allocator.free(old_session_dir);
        const current_cwd = try self.allocator.dupe(u8, self.cwd());
        defer self.allocator.free(current_cwd);

        const new_manager = try self.boxSessionManager(try session_manager.SessionManager.create(
            self.allocator,
            self.io,
            current_cwd,
            old_session_dir,
            .{ .parent_session = options.parent_session },
        ));
        var manager_owned = true;
        errdefer if (manager_owned) destroySessionManager(self.allocator, new_manager);

        const target_session_file = new_manager.getSessionFile();
        try self.teardownCurrent(.new, target_session_file);
        const result = try self.create_runtime.call(self.allocator, self.io, .{
            .cwd = new_manager.getCwd(),
            .agent_dir = agent_dir,
            .session_manager = new_manager,
            .session_start_event = .{ .reason = .new, .previous_session_file = previous_session_file },
        });
        manager_owned = false;
        self.apply(result);

        if (options.setup) |setup| {
            try setup.call(self.session.getSessionManager());
            try self.session.refreshSessionContext();
        }
        try self.finishSessionReplacement(options.with_session);
        return .{};
    }

    pub fn switchSession(
        self: *AgentSessionRuntime,
        session_path: []const u8,
        options: SwitchSessionOptions,
    ) !SessionChangeResult {
        const before_result = try self.emitBeforeSwitch(.@"resume", session_path);
        if (before_result.cancelled) return before_result;

        const previous_session_file = self.session.getSessionFile();
        const agent_dir = try self.allocator.dupe(u8, self.services.agent_dir);
        defer self.allocator.free(agent_dir);
        const fallback_cwd = try self.allocator.dupe(u8, self.cwd());
        defer self.allocator.free(fallback_cwd);

        const opened_manager = try self.boxSessionManager(try session_manager.SessionManager.open(
            self.allocator,
            self.io,
            session_path,
            .{ .cwd_override = options.cwd_override },
        ));
        var manager_owned = true;
        errdefer if (manager_owned) destroySessionManager(self.allocator, opened_manager);

        try session_cwd.assertSessionCwdExists(self.io, opened_manager.cwdSource(), fallback_cwd);
        try self.teardownCurrent(.@"resume", opened_manager.getSessionFile());
        const result = try self.create_runtime.call(self.allocator, self.io, .{
            .cwd = opened_manager.getCwd(),
            .agent_dir = agent_dir,
            .session_manager = opened_manager,
            .session_start_event = .{ .reason = .@"resume", .previous_session_file = previous_session_file },
        });
        manager_owned = false;
        self.apply(result);

        try self.finishSessionReplacement(options.with_session);
        return .{};
    }

    pub fn dispose(self: *AgentSessionRuntime) !void {
        if (!self.active) return;
        try self.teardownCurrent(.quit, null);
    }

    fn emitBeforeSwitch(
        self: *AgentSessionRuntime,
        reason: extensions.types.SessionReplacementReason,
        target_session_file: ?[]const u8,
    ) !SessionChangeResult {
        const runner = self.session.getExtensionRunner();
        if (!runner.hasHandlers(.session_before_switch)) return .{};

        const result = try runner.emitSessionBeforeSwitch(.{
            .reason = reason,
            .target_session_file = target_session_file,
        });
        return .{ .cancelled = if (result) |value| value.cancel else false };
    }

    fn teardownCurrent(
        self: *AgentSessionRuntime,
        reason: extensions.types.SessionShutdownReason,
        target_session_file: ?[]const u8,
    ) !void {
        if (!self.active) return;
        const runner = self.session.getExtensionRunner();
        if (runner.hasHandlers(.session_shutdown)) {
            _ = try runner.emit(.{ .session = .{ .shutdown = .{
                .reason = reason,
                .target_session_file = target_session_file,
            } } });
        }
        if (self.before_session_invalidate) |callback| try callback.call();
        self.session.dispose();
        destroyServices(self.allocator, self.services);
        self.active = false;
    }

    fn finishSessionReplacement(
        self: *AgentSessionRuntime,
        with_session: ?extensions.types.WithSessionCallback,
    ) !void {
        if (self.rebind_session) |callback| try callback.call(self.session);
        if (with_session) |callback| {
            var ctx = try self.session.createReplacedSessionContext();
            try callback.call(&ctx);
        }
    }

    fn apply(self: *AgentSessionRuntime, result: CreateAgentSessionRuntimeResult) void {
        self.session = result.session;
        self.services = result.services;
        self.model_fallback_message = result.model_fallback_message;
        self.active = true;
    }

    fn boxSessionManager(
        self: *AgentSessionRuntime,
        manager: session_manager.SessionManager,
    ) !*session_manager.SessionManager {
        const boxed = try self.allocator.create(session_manager.SessionManager);
        boxed.* = manager;
        return boxed;
    }
};

pub fn createAgentSessionRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    create_runtime: CreateAgentSessionRuntimeFactory,
    options: CreateAgentSessionRuntimeOptions,
) !AgentSessionRuntime {
    try session_cwd.assertSessionCwdExists(io, options.session_manager.cwdSource(), options.cwd);
    const result = try create_runtime.call(allocator, io, options);
    return AgentSessionRuntime.init(allocator, io, result, create_runtime);
}

fn destroyServices(allocator: std.mem.Allocator, services: *agent_session_services.AgentSessionServices) void {
    services.deinit();
    allocator.destroy(services);
}

fn destroySessionManager(allocator: std.mem.Allocator, manager: *session_manager.SessionManager) void {
    manager.deinit();
    allocator.destroy(manager);
}

const TestSession = struct {
    allocator: std.mem.Allocator,
    manager: *session_manager.SessionManager,
    runtime: *extensions.loader.ExtensionRuntimeController,
    runner: *extensions.ExtensionRunner,
    disposed: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        services: *agent_session_services.AgentSessionServices,
        manager: *session_manager.SessionManager,
        extension_list: []const extensions.Extension,
    ) !*TestSession {
        const runtime = try allocator.create(extensions.loader.ExtensionRuntimeController);
        errdefer allocator.destroy(runtime);
        runtime.* = extensions.loader.createExtensionRuntime(allocator);
        errdefer runtime.deinit();

        const runner = try allocator.create(extensions.ExtensionRunner);
        errdefer allocator.destroy(runner);
        runner.* = extensions.ExtensionRunner.init(
            allocator,
            extension_list,
            runtime,
            services.cwd,
            manager,
            services.model_registry,
        );
        errdefer runner.deinit();

        const session = try allocator.create(TestSession);
        session.* = .{
            .allocator = allocator,
            .manager = manager,
            .runtime = runtime,
            .runner = runner,
        };
        return session;
    }

    fn deinit(self: *TestSession) void {
        self.runner.deinit();
        self.allocator.destroy(self.runner);
        self.runtime.deinit();
        self.allocator.destroy(self.runtime);
        destroySessionManager(self.allocator, self.manager);
        self.allocator.destroy(self);
    }

    fn handle(self: *TestSession) RuntimeSession {
        return .{
            .ptr = self,
            .get_session_file_fn = getSessionFile,
            .get_session_manager_fn = getSessionManager,
            .get_extension_runner_fn = getExtensionRunner,
            .dispose_fn = dispose,
            .create_replaced_session_context_fn = createReplacedSessionContext,
        };
    }

    fn getSessionFile(ptr: *anyopaque) ?[]const u8 {
        const self: *TestSession = @ptrCast(@alignCast(ptr));
        return self.manager.getSessionFile();
    }

    fn getSessionManager(ptr: *anyopaque) *session_manager.SessionManager {
        const self: *TestSession = @ptrCast(@alignCast(ptr));
        return self.manager;
    }

    fn getExtensionRunner(ptr: *anyopaque) *extensions.ExtensionRunner {
        const self: *TestSession = @ptrCast(@alignCast(ptr));
        return self.runner;
    }

    fn dispose(ptr: *anyopaque) void {
        const self: *TestSession = @ptrCast(@alignCast(ptr));
        self.runner.invalidate(stale_session_message);
        self.disposed = true;
    }

    fn createReplacedSessionContext(ptr: *anyopaque) extensions.ReplacedSessionContext {
        const self: *TestSession = @ptrCast(@alignCast(ptr));
        return .{ .command = .{ .base = self.runner.createContext() catch unreachable } };
    }
};

const RuntimeHarness = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: std.process.Environ.Map,
    extension_list: []const extensions.Extension,
    sessions: std.ArrayList(*TestSession) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        home: []const u8,
        extension_list: []const extensions.Extension,
    ) !RuntimeHarness {
        var env = std.process.Environ.Map.init(allocator);
        errdefer env.deinit();
        try env.put("HOME", home);
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .extension_list = extension_list,
        };
    }

    fn deinit(self: *RuntimeHarness) void {
        for (self.sessions.items) |session| session.deinit();
        self.sessions.deinit(self.allocator);
        self.env.deinit();
        self.* = undefined;
    }

    fn factory(self: *RuntimeHarness) CreateAgentSessionRuntimeFactory {
        return .{ .ptr = self, .call_fn = createRuntime };
    }

    fn createRuntime(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: CreateAgentSessionRuntimeOptions,
    ) !CreateAgentSessionRuntimeResult {
        const self: *RuntimeHarness = @ptrCast(@alignCast(ptr.?));
        const services = try allocator.create(agent_session_services.AgentSessionServices);
        errdefer allocator.destroy(services);
        services.* = try agent_session_services.createAgentSessionServicesAlloc(allocator, io, .{
            .cwd = options.cwd,
            .agent_dir = options.agent_dir,
            .env = &self.env,
            .resource_loader_options = .{
                .no_extensions = true,
                .no_skills = true,
                .no_prompt_templates = true,
                .no_themes = true,
                .no_context_files = true,
            },
        });
        errdefer services.deinit();

        const session = try TestSession.init(allocator, services, options.session_manager, self.extension_list);
        errdefer session.deinit();
        try self.sessions.append(self.allocator, session);

        if (options.session_start_event) |event| {
            if (session.runner.hasHandlers(.session_start)) {
                _ = try session.runner.emit(.{ .session = .{ .start = event } });
            }
        }

        return .{
            .session = session.handle(),
            .services = services,
        };
    }
};

const RecordedEvent = struct {
    name: []const u8,
    reason: []const u8,
    target_session_file: ?[]u8 = null,
    previous_session_file: ?[]u8 = null,
    entry_id: ?[]u8 = null,
    position: ?[]const u8 = null,
};

const EventRecorder = struct {
    allocator: std.mem.Allocator,
    json_arena: std.heap.ArenaAllocator,
    events: std.ArrayList(RecordedEvent) = .empty,
    cancel_next_switch: bool = false,

    fn init(allocator: std.mem.Allocator) EventRecorder {
        return .{
            .allocator = allocator,
            .json_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    fn deinit(self: *EventRecorder) void {
        for (self.events.items) |event| {
            if (event.target_session_file) |value| self.allocator.free(value);
            if (event.previous_session_file) |value| self.allocator.free(value);
            if (event.entry_id) |value| self.allocator.free(value);
        }
        self.events.deinit(self.allocator);
        self.json_arena.deinit();
        self.* = undefined;
    }

    fn handler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = ctx;
        const self: *EventRecorder = @ptrCast(@alignCast(ptr.?));
        switch (event_value) {
            .session => |session_event| switch (session_event) {
                .start => |event| {
                    try self.events.append(self.allocator, .{
                        .name = "session_start",
                        .reason = event.reason.text(),
                        .previous_session_file = try optionalDupe(self.allocator, event.previous_session_file),
                    });
                },
                .before_switch => |event| {
                    try self.events.append(self.allocator, .{
                        .name = "session_before_switch",
                        .reason = event.reason.text(),
                        .target_session_file = try optionalDupe(self.allocator, event.target_session_file),
                    });
                    if (self.cancel_next_switch) {
                        self.cancel_next_switch = false;
                        var object = std.json.Value{ .object = .empty };
                        try object.object.put(self.json_arena.allocator(), "cancel", .{ .bool = true });
                        return object;
                    }
                },
                .before_fork => |event| {
                    try self.events.append(self.allocator, .{
                        .name = "session_before_fork",
                        .reason = "fork",
                        .entry_id = try optionalDupe(self.allocator, event.entry_id),
                        .position = event.position.text(),
                    });
                },
                .shutdown => |event| {
                    try self.events.append(self.allocator, .{
                        .name = "session_shutdown",
                        .reason = event.reason.text(),
                        .target_session_file = try optionalDupe(self.allocator, event.target_session_file),
                    });
                },
                else => {},
            },
            else => {},
        }
        return null;
    }
};

const PhaseRecorder = struct {
    allocator: std.mem.Allocator,
    phases: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *PhaseRecorder) void {
        self.phases.deinit(self.allocator);
        self.* = undefined;
    }

    fn shutdownHandler(ptr: ?*anyopaque, event_value: extensions.ExtensionEvent, ctx: *extensions.ExtensionContext) !?std.json.Value {
        _ = event_value;
        _ = ctx;
        const self: *PhaseRecorder = @ptrCast(@alignCast(ptr.?));
        try self.phases.append(self.allocator, "session_shutdown");
        return null;
    }

    fn beforeInvalidate(ptr: ?*anyopaque) !void {
        const self: *PhaseRecorder = @ptrCast(@alignCast(ptr.?));
        try self.phases.append(self.allocator, "beforeSessionInvalidate");
    }

    fn rebind(ptr: ?*anyopaque, session: RuntimeSession) !void {
        _ = session;
        const self: *PhaseRecorder = @ptrCast(@alignCast(ptr.?));
        try self.phases.append(self.allocator, "rebindSession");
    }
};

fn optionalDupe(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn testSource(path: []const u8) source_info.SourceInfo {
    return source_info.createSyntheticSourceInfo(path, .{ .source = "test" });
}

fn testExtension(path: []const u8, handlers: []const extensions.ExtensionHandler) extensions.Extension {
    return .{
        .path = path,
        .resolved_path = path,
        .source_info = testSource(path),
        .handlers = handlers,
    };
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn createBoxedSessionManager(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    session_dir: []const u8,
) !*session_manager.SessionManager {
    const manager = try allocator.create(session_manager.SessionManager);
    errdefer allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.create(allocator, io, cwd, session_dir, .{});
    return manager;
}

fn appendPersistingMessages(manager: *session_manager.SessionManager, io: std.Io) !void {
    _ = try manager.appendMessageJson(io, "{\"role\":\"user\",\"content\":\"hello\",\"timestamp\":1}");
    _ = try manager.appendMessageJson(io, "{\"role\":\"assistant\",\"content\":\"ok\",\"timestamp\":2}");
}

fn expectRecordedEvent(event: RecordedEvent, name: []const u8, reason: []const u8) !void {
    try std.testing.expectEqualStrings(name, event.name);
    try std.testing.expectEqualStrings(reason, event.reason);
}

test "createAgentSessionRuntime checks missing cwd before factory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const temp_dir = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(temp_dir);
    const missing_cwd = try std.fs.path.join(allocator, &.{ temp_dir, "missing" });
    defer allocator.free(missing_cwd);
    const session_file = try std.fs.path.join(allocator, &.{ temp_dir, "session.jsonl" });
    defer allocator.free(session_file);

    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"session\",\"version\":3,\"id\":\"session-id\",\"timestamp\":\"2026-06-01T00:00:00Z\",\"cwd\":\"{s}\"}}\n",
        .{missing_cwd},
    );
    defer allocator.free(content);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = session_file, .data = content });

    const manager = try allocator.create(session_manager.SessionManager);
    defer allocator.destroy(manager);
    manager.* = try session_manager.SessionManager.open(allocator, io, session_file, .{});
    defer manager.deinit();

    const FailingFactory = struct {
        fn create(ptr: ?*anyopaque, factory_allocator: std.mem.Allocator, factory_io: std.Io, options: CreateAgentSessionRuntimeOptions) !CreateAgentSessionRuntimeResult {
            _ = ptr;
            _ = factory_allocator;
            _ = factory_io;
            _ = options;
            return error.FactoryShouldNotRun;
        }
    };

    try std.testing.expectError(
        error.MissingSessionCwd,
        createAgentSessionRuntime(
            allocator,
            io,
            .{ .call_fn = FailingFactory.create },
            .{
                .cwd = temp_dir,
                .agent_dir = temp_dir,
                .session_manager = manager,
            },
        ),
    );
}

test "AgentSessionRuntime emits new and resume lifecycle events" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);
    const agent_dir = try std.fs.path.join(allocator, &.{ cwd, "agent" });
    defer allocator.free(agent_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ cwd, "sessions" });
    defer allocator.free(session_dir);

    var recorder = EventRecorder.init(allocator);
    defer recorder.deinit();
    const handlers = [_]extensions.ExtensionHandler{
        .{ .ptr = &recorder, .event_name = .session_start, .handler_fn = EventRecorder.handler },
        .{ .ptr = &recorder, .event_name = .session_before_switch, .handler_fn = EventRecorder.handler },
        .{ .ptr = &recorder, .event_name = .session_shutdown, .handler_fn = EventRecorder.handler },
    };
    const extension_list = [_]extensions.Extension{testExtension("/tmp/runtime-events.zig", &handlers)};
    var harness = try RuntimeHarness.init(allocator, io, cwd, &extension_list);
    defer harness.deinit();

    const initial_manager = try createBoxedSessionManager(allocator, io, cwd, session_dir);
    try appendPersistingMessages(initial_manager, io);
    var runtime = try createAgentSessionRuntime(
        allocator,
        io,
        harness.factory(),
        .{
            .cwd = cwd,
            .agent_dir = agent_dir,
            .session_manager = initial_manager,
            .session_start_event = .{ .reason = .startup },
        },
    );
    defer runtime.dispose() catch {};

    try std.testing.expectEqual(@as(usize, 1), recorder.events.items.len);
    try expectRecordedEvent(recorder.events.items[0], "session_start", "startup");
    const original_session_file = runtime.session.getSessionFile().?;
    recorder.deinit();
    recorder = EventRecorder.init(allocator);

    const new_result = try runtime.newSession(.{});
    try std.testing.expect(!new_result.cancelled);
    try std.testing.expectEqual(@as(usize, 3), recorder.events.items.len);
    try expectRecordedEvent(recorder.events.items[0], "session_before_switch", "new");
    try std.testing.expectEqual(@as(?[]u8, null), recorder.events.items[0].target_session_file);
    try expectRecordedEvent(recorder.events.items[1], "session_shutdown", "new");
    try std.testing.expectEqualStrings(runtime.session.getSessionFile().?, recorder.events.items[1].target_session_file.?);
    try expectRecordedEvent(recorder.events.items[2], "session_start", "new");
    try std.testing.expectEqualStrings(original_session_file, recorder.events.items[2].previous_session_file.?);
    const second_session_file = runtime.session.getSessionFile().?;
    recorder.deinit();
    recorder = EventRecorder.init(allocator);

    const switch_result = try runtime.switchSession(original_session_file, .{});
    try std.testing.expect(!switch_result.cancelled);
    try std.testing.expectEqual(@as(usize, 3), recorder.events.items.len);
    try expectRecordedEvent(recorder.events.items[0], "session_before_switch", "resume");
    try std.testing.expectEqualStrings(original_session_file, recorder.events.items[0].target_session_file.?);
    try expectRecordedEvent(recorder.events.items[1], "session_shutdown", "resume");
    try std.testing.expectEqualStrings(original_session_file, recorder.events.items[1].target_session_file.?);
    try expectRecordedEvent(recorder.events.items[2], "session_start", "resume");
    try std.testing.expectEqualStrings(second_session_file, recorder.events.items[2].previous_session_file.?);
}

test "AgentSessionRuntime honors session_before_switch cancellation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);
    const agent_dir = try std.fs.path.join(allocator, &.{ cwd, "agent" });
    defer allocator.free(agent_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ cwd, "sessions" });
    defer allocator.free(session_dir);

    var recorder = EventRecorder.init(allocator);
    recorder.cancel_next_switch = true;
    defer recorder.deinit();
    const handlers = [_]extensions.ExtensionHandler{
        .{ .ptr = &recorder, .event_name = .session_start, .handler_fn = EventRecorder.handler },
        .{ .ptr = &recorder, .event_name = .session_before_switch, .handler_fn = EventRecorder.handler },
    };
    const extension_list = [_]extensions.Extension{testExtension("/tmp/runtime-cancel.zig", &handlers)};
    var harness = try RuntimeHarness.init(allocator, io, cwd, &extension_list);
    defer harness.deinit();

    const initial_manager = try createBoxedSessionManager(allocator, io, cwd, session_dir);
    var runtime = try createAgentSessionRuntime(
        allocator,
        io,
        harness.factory(),
        .{
            .cwd = cwd,
            .agent_dir = agent_dir,
            .session_manager = initial_manager,
            .session_start_event = .{ .reason = .startup },
        },
    );
    defer runtime.dispose() catch {};
    const original_session_file = runtime.session.getSessionFile().?;
    recorder.deinit();
    recorder = EventRecorder.init(allocator);
    recorder.cancel_next_switch = true;

    const result = try runtime.newSession(.{});
    try std.testing.expect(result.cancelled);
    try std.testing.expectEqualStrings(original_session_file, runtime.session.getSessionFile().?);
    try std.testing.expectEqual(@as(usize, 1), recorder.events.items.len);
    try expectRecordedEvent(recorder.events.items[0], "session_before_switch", "new");
}

test "AgentSessionRuntime runs invalidation before rebind" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);
    const agent_dir = try std.fs.path.join(allocator, &.{ cwd, "agent" });
    defer allocator.free(agent_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ cwd, "sessions" });
    defer allocator.free(session_dir);

    var phases = PhaseRecorder{ .allocator = allocator };
    defer phases.deinit();
    const handlers = [_]extensions.ExtensionHandler{.{
        .ptr = &phases,
        .event_name = .session_shutdown,
        .handler_fn = PhaseRecorder.shutdownHandler,
    }};
    const extension_list = [_]extensions.Extension{testExtension("/tmp/runtime-phases.zig", &handlers)};
    var harness = try RuntimeHarness.init(allocator, io, cwd, &extension_list);
    defer harness.deinit();

    const initial_manager = try createBoxedSessionManager(allocator, io, cwd, session_dir);
    var runtime = try createAgentSessionRuntime(
        allocator,
        io,
        harness.factory(),
        .{
            .cwd = cwd,
            .agent_dir = agent_dir,
            .session_manager = initial_manager,
        },
    );
    defer runtime.dispose() catch {};

    const old_session = runtime.session;
    runtime.setBeforeSessionInvalidate(.{ .ptr = &phases, .call_fn = PhaseRecorder.beforeInvalidate });
    runtime.setRebindSession(.{ .ptr = &phases, .call_fn = PhaseRecorder.rebind });

    _ = try runtime.newSession(.{});

    try std.testing.expectEqual(@as(usize, 3), phases.phases.items.len);
    try std.testing.expectEqualStrings("session_shutdown", phases.phases.items[0]);
    try std.testing.expectEqualStrings("beforeSessionInvalidate", phases.phases.items[1]);
    try std.testing.expectEqualStrings("rebindSession", phases.phases.items[2]);
    try std.testing.expectError(error.ExtensionContextStale, old_session.getExtensionRunner().assertActive());
}
