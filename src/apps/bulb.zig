const std = @import("std");
const Io = std.Io;
const coding_agent = @import("bulb_coding_agent");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    coding_agent.tui.keys.setProcessEnvironment(init.environ_map);
    coding_agent.tui.terminal_image.setProcessEnvironment(init.environ_map);

    const allocator = init.arena.allocator();
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
