const std = @import("std");

const agent_session_runtime = @import("agent_session_runtime.zig");
const agent_session_services = @import("agent_session_services.zig");
const auth_storage = @import("auth_storage.zig");
const extensions = @import("extensions/root.zig");
const model_registry = @import("model_registry.zig");
const session_manager = @import("session_manager.zig");

pub const RpcRuntimeHostOptions = struct {
    env: ?*const std.process.Environ.Map = null,
    agent_dir: []const u8,
    auth_storage: ?*auth_storage.AuthStorage = null,
    model_registry: ?*model_registry.ModelRegistry = null,
    resource_loader_options: agent_session_services.ResourceLoaderOptions = .{},
};

pub const RpcRuntimeHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    agent_dir: []const u8,
    auth_storage: ?*auth_storage.AuthStorage,
    model_registry: ?*model_registry.ModelRegistry,
    resource_loader_options: agent_session_services.ResourceLoaderOptions,
    runtime: agent_session_runtime.AgentSessionRuntime = undefined,
    active: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: RpcRuntimeHostOptions,
    ) RpcRuntimeHost {
        return .{
            .allocator = allocator,
            .io = io,
            .env = options.env,
            .agent_dir = options.agent_dir,
            .auth_storage = options.auth_storage,
            .model_registry = options.model_registry,
            .resource_loader_options = options.resource_loader_options,
        };
    }

    pub fn start(
        self: *RpcRuntimeHost,
        initial_session_manager: *session_manager.SessionManager,
    ) !void {
        self.runtime = try agent_session_runtime.createAgentSessionRuntime(
            self.allocator,
            self.io,
            self.factory(),
            .{
                .cwd = initial_session_manager.getCwd(),
                .agent_dir = self.agent_dir,
                .session_manager = initial_session_manager,
                .session_start_event = .{ .reason = .startup },
            },
        );
        self.active = true;
    }

    pub fn deinit(self: *RpcRuntimeHost) void {
        if (self.active) {
            self.runtime.dispose() catch {};
            self.active = false;
        }
        self.* = undefined;
    }

    pub fn factory(self: *RpcRuntimeHost) agent_session_runtime.CreateAgentSessionRuntimeFactory {
        return .{ .ptr = self, .call_fn = createRuntime };
    }

    fn createRuntime(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: agent_session_runtime.CreateAgentSessionRuntimeOptions,
    ) !agent_session_runtime.CreateAgentSessionRuntimeResult {
        const self: *RpcRuntimeHost = @ptrCast(@alignCast(ptr.?));

        const services = try allocator.create(agent_session_services.AgentSessionServices);
        errdefer allocator.destroy(services);
        services.* = try agent_session_services.createAgentSessionServicesAlloc(allocator, io, .{
            .cwd = options.cwd,
            .agent_dir = options.agent_dir,
            .env = self.env,
            .auth_storage = self.auth_storage,
            .model_registry = self.model_registry,
            .resource_loader_options = self.resource_loader_options,
        });
        errdefer services.deinit();

        const session = try RpcRuntimeSession.init(allocator, io, services, options.session_manager);
        errdefer session.destroy();

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

const RpcRuntimeSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: ?*session_manager.SessionManager,
    loaded_extensions: extensions.loader.LoadExtensionsResult,
    extension_snapshot: []extensions.Extension,
    runner: *extensions.ExtensionRunner,
    disposed: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        services: *agent_session_services.AgentSessionServices,
        manager: *session_manager.SessionManager,
    ) !*RpcRuntimeSession {
        const loaded_paths = services.resource_loader.getExtensions().extensions;
        var extension_paths = try allocator.alloc([]const u8, loaded_paths.len);
        defer allocator.free(extension_paths);
        for (loaded_paths, 0..) |loaded, index| extension_paths[index] = loaded.path;

        var loaded_extensions = try extensions.loadExtensionsAlloc(
            allocator,
            extension_paths,
            services.cwd,
            null,
        );
        errdefer loaded_extensions.deinit();

        const extension_snapshot = try allocator.alloc(extensions.Extension, loaded_extensions.extensions.len);
        errdefer allocator.free(extension_snapshot);
        for (loaded_extensions.extensions, 0..) |loaded, index| {
            extension_snapshot[index] = loaded.extension;
        }

        const runner = try allocator.create(extensions.ExtensionRunner);
        errdefer allocator.destroy(runner);
        runner.* = extensions.ExtensionRunner.init(
            allocator,
            extension_snapshot,
            &loaded_extensions.runtime,
            services.cwd,
            manager,
            services.model_registry,
        );
        runner.setUIContext(.{}, .rpc);
        errdefer runner.deinit();

        const session = try allocator.create(RpcRuntimeSession);
        session.* = .{
            .allocator = allocator,
            .io = io,
            .manager = manager,
            .loaded_extensions = loaded_extensions,
            .extension_snapshot = extension_snapshot,
            .runner = runner,
        };
        return session;
    }

    fn handle(self: *RpcRuntimeSession) agent_session_runtime.RuntimeSession {
        return .{
            .ptr = self,
            .get_session_file_fn = getSessionFile,
            .get_session_manager_fn = getSessionManager,
            .get_extension_runner_fn = getExtensionRunner,
            .dispose_fn = dispose,
            .release_session_manager_fn = releaseSessionManager,
            .create_replaced_session_context_fn = createReplacedSessionContext,
            .refresh_session_context_fn = refreshSessionContext,
        };
    }

    fn destroy(self: *RpcRuntimeSession) void {
        self.runner.deinit();
        self.allocator.destroy(self.runner);
        self.allocator.free(self.extension_snapshot);
        self.loaded_extensions.deinit();
        if (self.manager) |manager| {
            manager.deinit();
            self.allocator.destroy(manager);
        }
        self.allocator.destroy(self);
    }

    fn getSessionFile(ptr: *anyopaque) ?[]const u8 {
        const self: *RpcRuntimeSession = @ptrCast(@alignCast(ptr));
        return self.manager.?.getSessionFile();
    }

    fn getSessionManager(ptr: *anyopaque) *session_manager.SessionManager {
        const self: *RpcRuntimeSession = @ptrCast(@alignCast(ptr));
        return self.manager.?;
    }

    fn getExtensionRunner(ptr: *anyopaque) *extensions.ExtensionRunner {
        const self: *RpcRuntimeSession = @ptrCast(@alignCast(ptr));
        return self.runner;
    }

    fn dispose(ptr: *anyopaque) void {
        const self: *RpcRuntimeSession = @ptrCast(@alignCast(ptr));
        if (self.disposed) return;
        self.disposed = true;
        self.runner.invalidate("This extension ctx is stale after session replacement or reload. Do not use a captured Bulb ctx after session replacement or reload.");
        self.destroy();
    }

    fn releaseSessionManager(ptr: *anyopaque) void {
        const self: *RpcRuntimeSession = @ptrCast(@alignCast(ptr));
        self.manager = null;
    }

    fn createReplacedSessionContext(ptr: *anyopaque) extensions.ReplacedSessionContext {
        const self: *RpcRuntimeSession = @ptrCast(@alignCast(ptr));
        return .{ .command = .{ .base = self.runner.createContext() catch unreachable } };
    }

    fn refreshSessionContext(ptr: *anyopaque) !void {
        _ = ptr;
    }

};

test "RpcRuntimeHost owns runtime-backed session replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const agent_dir = try std.fs.path.join(allocator, &.{ root, "agent" });
    defer allocator.free(agent_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(session_dir);

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", root);

    const manager = try allocator.create(session_manager.SessionManager);
    manager.* = try session_manager.SessionManager.create(allocator, io, cwd, session_dir, .{});

    var host = RpcRuntimeHost.init(allocator, io, .{
        .env = &env,
        .agent_dir = agent_dir,
        .resource_loader_options = .{
            .no_extensions = true,
            .no_skills = true,
            .no_prompt_templates = true,
            .no_themes = true,
            .no_context_files = true,
        },
    });
    try host.start(manager);
    defer host.deinit();

    const first_file = try allocator.dupe(u8, host.runtime.session.getSessionFile().?);
    defer allocator.free(first_file);

    const new_result = try host.runtime.newSession(.{ .parent_session = first_file });
    defer new_result.deinit(allocator);
    try std.testing.expect(!new_result.cancelled);
    try std.testing.expect(!std.mem.eql(u8, first_file, host.runtime.session.getSessionFile().?));

    const switch_result = try host.runtime.switchSession(first_file, .{});
    defer switch_result.deinit(allocator);
    try std.testing.expect(!switch_result.cancelled);
    try std.testing.expectEqualStrings(first_file, host.runtime.session.getSessionFile().?);
}
