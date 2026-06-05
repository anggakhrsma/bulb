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
        try writeModelList(stdout, list_models);
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

fn writeModelList(stdout: *std.Io.Writer, list_models: coding_agent.cli_args.ListModels) !void {
    const search = switch (list_models) {
        .all => null,
        .search => |value| value,
    };
    for (coding_agent.ai.models.allModels()) |model| {
        if (search) |query| {
            if (!containsIgnoreCase(model.provider, query) and
                !containsIgnoreCase(model.id, query) and
                !containsIgnoreCase(model.name, query))
            {
                continue;
            }
        }
        try stdout.print("{s}/{s}\t{s}\n", .{ model.provider, model.id, model.name });
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}
