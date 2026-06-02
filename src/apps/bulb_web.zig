const std = @import("std");
const Io = std.Io;
const coding_agent = @import("bulb_coding_agent");
const build_options = @import("build_options");
const support = @import("support.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (support.hasArg(args, "--version")) {
        try stdout.print("bulb-web {s}\n", .{build_options.version});
    } else {
        try stdout.writeAll(
            \\Bulb companion service scaffold
            \\
            \\Usage:
            \\  bulb-web --help       Show this help
            \\  bulb-web --version    Print the companion service version
            \\
        );
        try stdout.print(
            "Service base URL: {s}\n",
            .{coding_agent.config.serviceBaseUrl(init.environ_map.*)},
        );
    }

    try stdout.flush();
}
