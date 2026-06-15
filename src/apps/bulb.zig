const std = @import("std");
const Io = std.Io;
const coding_agent = @import("bulb_coding_agent");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    _ = try coding_agent.restoreSandboxEnv(allocator, init.io, init.environ_map);

    coding_agent.tui.keys.setProcessEnvironment(init.environ_map);
    coding_agent.tui.terminal_image.setProcessEnvironment(init.environ_map);

    const process_args = try init.minimal.args.toSlice(allocator);
    const argv = if (process_args.len > 1) process_args[1..] else &.{};
    var parsed = try coding_agent.cli_args.parseArgs(allocator, argv);
    defer parsed.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    for (parsed.diagnostics.items) |diagnostic| {
        const label = switch (diagnostic.kind) {
            .warning => "Warning",
            .@"error" => "Error",
        };
        try stderr.print("{s}: {s}\n", .{ label, diagnostic.message });
    }

    if (parsed.hasErrors()) {
        try stderr.flush();
        std.process.exit(1);
    } else if (parsed.version) {
        try stdout.print("bulb {s}\n", .{build_options.version});
    } else if (parsed.help) {
        try coding_agent.cli_args.writeHelp(stdout);
    } else if (parsed.list_models) |list_models| {
        try writeModelList(allocator, init.io, init.environ_map, stdout, stderr, list_models);
    } else if (parsed.mode == .rpc) {
        try runRpcMode(allocator, init.io, init.environ_map, stdout, &parsed);
    } else {
        try stdout.writeAll(
            \\Bulb native coding agent
            \\
            \\Usage:
            \\  bulb --help       Show this help
            \\  bulb --version    Print the Bulb version
            \\
        );
        try stdout.print("Config: ~/{s}\n", .{coding_agent.config.global_config_dir});
    }

    try stdout.flush();
    try stderr.flush();
}

fn runRpcMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    parsed: *const coding_agent.cli_args.Args,
) !void {
    var oauth_registry = try coding_agent.ai.oauth.Registry.init(allocator);
    defer oauth_registry.deinit();

    var resolver = coding_agent.resolve_config_value.Resolver.init(allocator, environ);
    defer resolver.deinit();

    const agent_dir = try coding_agent.config.agentDirAlloc(allocator, environ);
    defer allocator.free(agent_dir);
    const auth_path = try std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    const models_json_path = try std.fs.path.join(allocator, &.{ agent_dir, "models.json" });
    defer allocator.free(models_json_path);

    var auth_storage = try coding_agent.auth_storage.AuthStorage.initFile(
        allocator,
        environ,
        &oauth_registry,
        &resolver,
        auth_path,
    );
    defer auth_storage.deinit();

    if (parsed.api_key) |api_key| {
        if (parsed.provider) |provider| try auth_storage.setRuntimeApiKey(provider, api_key);
    }

    var registry = try coding_agent.model_registry.ModelRegistry.init(allocator, &auth_storage, models_json_path);
    defer registry.deinit();

    const initial_session = try allocator.create(coding_agent.SessionManager);
    var initial_session_owned = true;
    errdefer if (initial_session_owned) {
        initial_session.deinit();
        allocator.destroy(initial_session);
    };
    initial_session.* = try createRpcSessionManager(allocator, io, environ, agent_dir, parsed);
    if (parsed.name) |name| _ = try initial_session.appendSessionInfo(io, name);

    var runtime_host = coding_agent.RpcRuntimeHost.init(allocator, io, .{
        .env = environ,
        .agent_dir = agent_dir,
        .auth_storage = &auth_storage,
        .model_registry = &registry,
    });
    try runtime_host.start(initial_session);
    initial_session_owned = false;
    defer runtime_host.deinit();

    const initial_model = findInitialRpcModel(&registry, parsed.provider, parsed.model);
    const thinking_level = parsed.thinking orelse coding_agent.model_resolver.default_thinking_level;
    var rpc = coding_agent.rpc_mode.RpcMode.init(allocator, .{
        .io = io,
        .model_registry = &registry,
        .session_runtime = &runtime_host.runtime,
        .initial_model = initial_model,
        .thinking_level = thinking_level,
    });
    defer rpc.deinit();

    try rpc.run(stdout);
}

fn createRpcSessionManager(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    agent_dir: []const u8,
    parsed: *const coding_agent.cli_args.Args,
) !coding_agent.SessionManager {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    if (parsed.no_session) {
        return coding_agent.SessionManager.inMemory(allocator, io, cwd);
    }

    const session_dir = try rpcSessionDirAlloc(allocator, io, environ, cwd, agent_dir, parsed.session_dir);
    defer allocator.free(session_dir);

    if (parsed.fork) |source_arg| {
        const source_path = try resolveRpcSessionArgAlloc(allocator, io, cwd, session_dir, agent_dir, source_arg);
        defer allocator.free(source_path);
        return coding_agent.session_manager.forkFrom(
            allocator,
            io,
            source_path,
            cwd,
            session_dir,
            .{ .id = parsed.session_id },
        );
    }

    if (parsed.session) |session_arg| {
        const session_path = try resolveRpcSessionArgAlloc(allocator, io, cwd, session_dir, agent_dir, session_arg);
        defer allocator.free(session_path);
        return coding_agent.SessionManager.open(allocator, io, session_path, .{
            .session_dir = session_dir,
        });
    }

    if (parsed.continue_flag or parsed.resume_flag) {
        return coding_agent.SessionManager.continueRecent(allocator, io, cwd, session_dir);
    }

    if (parsed.session_id) |session_id| {
        try coding_agent.session_manager.assertValidSessionId(session_id);
        var sessions = try coding_agent.SessionManager.list(allocator, io, cwd, session_dir, agent_dir);
        defer sessions.deinit();
        for (sessions.sessions) |info| {
            if (std.mem.eql(u8, info.id, session_id)) {
                return coding_agent.SessionManager.open(allocator, io, info.path, .{
                    .session_dir = session_dir,
                });
            }
        }
    }

    return coding_agent.SessionManager.create(allocator, io, cwd, session_dir, .{
        .id = parsed.session_id,
    });
}

fn resolveRpcSessionArgAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    session_dir: []const u8,
    agent_dir: []const u8,
    arg: []const u8,
) ![]u8 {
    if (pathExists(io, arg)) return allocator.dupe(u8, arg);

    var sessions = try coding_agent.SessionManager.list(allocator, io, cwd, session_dir, agent_dir);
    defer sessions.deinit();
    for (sessions.sessions) |info| {
        if (std.mem.eql(u8, info.id, arg)) return allocator.dupe(u8, info.path);
    }

    var match: ?[]const u8 = null;
    for (sessions.sessions) |info| {
        if (std.mem.startsWith(u8, info.id, arg)) {
            if (match != null) return error.AmbiguousSessionId;
            match = info.path;
        }
    }
    if (match) |path| return allocator.dupe(u8, path);
    return allocator.dupe(u8, arg);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn rpcSessionDirAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    cwd: []const u8,
    agent_dir: []const u8,
    cli_session_dir: ?[]const u8,
) ![]u8 {
    if (cli_session_dir) |path| return allocator.dupe(u8, path);
    if (environ.get(coding_agent.config.session_dir_env)) |path| return allocator.dupe(u8, path);

    var settings = try coding_agent.SettingsManager.create(allocator, io, cwd, agent_dir);
    defer settings.deinit();
    if (try settings.getSessionDirAlloc(allocator, environ.get("HOME"))) |path| return path;
    return coding_agent.session_manager.getDefaultSessionDirPathAlloc(allocator, io, cwd, agent_dir);
}

fn findInitialRpcModel(
    registry: *const coding_agent.model_registry.ModelRegistry,
    provider: ?[]const u8,
    model_id: ?[]const u8,
) ?*const coding_agent.ai.Model {
    if (provider) |provider_name| {
        if (model_id) |id| {
            if (registry.find(provider_name, id)) |model| return model;
        } else if (coding_agent.model_resolver.defaultModelForProvider(provider_name)) |default_id| {
            if (registry.find(provider_name, default_id)) |model| return model;
        }
    }

    if (model_id) |id| {
        var match: ?*const coding_agent.ai.Model = null;
        for (registry.getAll()) |*model| {
            if (std.mem.eql(u8, model.id, id)) {
                if (match != null) return null;
                match = model;
            }
        }
        return match;
    }

    return null;
}

fn writeModelList(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    list_models: coding_agent.cli_args.ListModels,
) !void {
    const search = switch (list_models) {
        .all => null,
        .search => |value| value,
    };

    var oauth_registry = try coding_agent.ai.oauth.Registry.init(allocator);
    defer oauth_registry.deinit();

    var resolver = coding_agent.resolve_config_value.Resolver.init(allocator, environ);
    defer resolver.deinit();

    const agent_dir = try coding_agent.config.agentDirAlloc(allocator, environ);
    defer allocator.free(agent_dir);
    const auth_path = try std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    const models_json_path = try std.fs.path.join(allocator, &.{ agent_dir, "models.json" });
    defer allocator.free(models_json_path);

    var auth_storage = try coding_agent.auth_storage.AuthStorage.initFile(
        allocator,
        environ,
        &oauth_registry,
        &resolver,
        auth_path,
    );
    defer auth_storage.deinit();

    var registry = try coding_agent.model_registry.ModelRegistry.init(allocator, &auth_storage, models_json_path);
    defer registry.deinit();

    try coding_agent.list_models.writeListModels(
        allocator,
        stdout,
        stderr,
        io,
        environ,
        &registry,
        search,
    );
}
