const std = @import("std");
const Io = std.Io;
const ai = @import("bulb_ai");
const build_options = @import("build_options");
const support = @import("support.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (support.hasArg(args, "--version")) {
        try stdout.print("bulb-ai {s}\n", .{build_options.version});
    } else {
        try stdout.writeAll(
            \\Bulb native AI utility
            \\
            \\Usage:
            \\  bulb-ai --help       Show this help
            \\  bulb-ai --version    Print the Bulb AI utility version
            \\
        );
        try stdout.print("Native APIs declared: {d}\n", .{ai.known_api_count});
    }

    try stdout.flush();
}
