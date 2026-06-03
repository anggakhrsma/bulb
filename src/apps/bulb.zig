const std = @import("std");
const Io = std.Io;
const coding_agent = @import("bulb_coding_agent");
const build_options = @import("build_options");
const support = @import("support.zig");

pub fn main(init: std.process.Init) !void {
    coding_agent.tui.keys.setProcessEnvironment(init.environ_map);
    coding_agent.tui.terminal_image.setProcessEnvironment(init.environ_map);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (support.hasArg(args, "--version")) {
        try stdout.print("bulb {s}\n", .{build_options.version});
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
}
