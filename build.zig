const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Bulb version string") orelse "0.0.0-dev";
    const service_base_url = b.option(
        []const u8,
        "service-base-url",
        "Default service base URL; BULB_SERVICE_BASE_URL overrides this at runtime",
    ) orelse "http://127.0.0.1:8080";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "service_base_url", service_base_url);
    const build_options_module = build_options.createModule();

    const ai = b.addModule("bulb_ai", .{
        .root_source_file = b.path("src/bulb_ai/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const agent = b.addModule("bulb_agent", .{
        .root_source_file = b.path("src/bulb_agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bulb_ai", .module = ai },
        },
    });

    const tui = b.addModule("bulb_tui", .{
        .root_source_file = b.path("src/bulb_tui/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const extension_sdk = b.addModule("bulb_extension_sdk", .{
        .root_source_file = b.path("src/bulb_extension_sdk/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const coding_agent = b.addModule("bulb_coding_agent", .{
        .root_source_file = b.path("src/bulb_coding_agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bulb_ai", .module = ai },
            .{ .name = "bulb_agent", .module = agent },
            .{ .name = "bulb_tui", .module = tui },
            .{ .name = "bulb_extension_sdk", .module = extension_sdk },
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    const bulb = addExecutable(b, .{
        .name = "bulb",
        .source = "src/apps/bulb.zig",
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bulb_coding_agent", .module = coding_agent },
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    const bulb_ai = addExecutable(b, .{
        .name = "bulb-ai",
        .source = "src/apps/bulb_ai.zig",
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bulb_ai", .module = ai },
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    const bulb_web = addExecutable(b, .{
        .name = "bulb-web",
        .source = "src/apps/bulb_web.zig",
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bulb_coding_agent", .module = coding_agent },
            .{ .name = "build_options", .module = build_options_module },
        },
    });

    addRunStep(b, bulb, "run", "Run the Bulb coding agent");
    addRunStep(b, bulb_ai, "run-ai", "Run the Bulb AI utility");
    addRunStep(b, bulb_web, "run-web", "Run the Bulb companion service");

    const test_step = b.step("test", "Run native Bulb tests");
    addModuleTests(b, test_step, ai);
    addModuleTests(b, test_step, agent);
    addModuleTests(b, test_step, tui);
    addModuleTests(b, test_step, extension_sdk);
    addModuleTests(b, test_step, coding_agent);

    const check_step = b.step("check", "Compile all native Bulb executables");
    check_step.dependOn(&bulb.step);
    check_step.dependOn(&bulb_ai.step);
    check_step.dependOn(&bulb_web.step);

    const fmt = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "src" });
    const fmt_step = b.step("fmt-check", "Check Zig formatting");
    fmt_step.dependOn(&fmt.step);
}

const ExecutableOptions = struct {
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
};

fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile {
    const executable = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.source),
            .target = options.target,
            .optimize = options.optimize,
            .imports = options.imports,
        }),
    });
    b.installArtifact(executable);
    return executable;
}

fn addRunStep(b: *std.Build, executable: *std.Build.Step.Compile, name: []const u8, description: []const u8) void {
    const run_artifact = b.addRunArtifact(executable);
    if (b.args) |args| run_artifact.addArgs(args);
    const run_step = b.step(name, description);
    run_step.dependOn(&run_artifact.step);
}

fn addModuleTests(b: *std.Build, test_step: *std.Build.Step, module: *std.Build.Module) void {
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
