const std = @import("std");
const build_options = @import("build_options");

pub const product_name = "Bulb";
pub const command_name = "bulb";
pub const global_config_dir = ".bulb/agent";
pub const project_config_dir = ".bulb";
pub const service_base_url_env = "BULB_SERVICE_BASE_URL";
pub const agent_dir_env = "BULB_CODING_AGENT_DIR";
pub const session_dir_env = "BULB_CODING_AGENT_SESSION_DIR";
pub const package_dir_env = "BULB_PACKAGE_DIR";
pub const compiled_service_base_url = build_options.service_base_url;

pub fn serviceBaseUrl(environ: std.process.Environ.Map) []const u8 {
    return environ.get(service_base_url_env) orelse compiled_service_base_url;
}

pub fn agentDirAlloc(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get(agent_dir_env)) |configured| {
        return expandTildeAlloc(allocator, environ, configured);
    }
    const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse ".";
    return std.fs.path.join(allocator, &.{ home, ".bulb", "agent" });
}

pub fn authPathAlloc(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const agent_dir = try agentDirAlloc(allocator, environ);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "auth.json" });
}

pub fn packageDirAlloc(allocator: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ![]u8 {
    if (environ) |env| {
        if (env.get(package_dir_env)) |configured| {
            return expandTildeAlloc(allocator, env, configured);
        }
    }

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return findPackageRootAlloc(allocator, io, cwd);
}

pub fn readmePathAlloc(allocator: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ![]u8 {
    const package_dir = try packageDirAlloc(allocator, io, environ);
    defer allocator.free(package_dir);
    return std.fs.path.resolve(allocator, &.{ package_dir, "README.md" });
}

pub fn docsPathAlloc(allocator: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ![]u8 {
    const package_dir = try packageDirAlloc(allocator, io, environ);
    defer allocator.free(package_dir);
    return std.fs.path.resolve(allocator, &.{ package_dir, "docs" });
}

pub fn examplesPathAlloc(allocator: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) ![]u8 {
    const package_dir = try packageDirAlloc(allocator, io, environ);
    defer allocator.free(package_dir);
    return std.fs.path.resolve(allocator, &.{ package_dir, "examples" });
}

fn expandTildeAlloc(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    path: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, path, "~")) {
        return allocator.dupe(u8, environ.get("HOME") orelse environ.get("USERPROFILE") orelse ".");
    }
    if (std.mem.startsWith(u8, path, "~/") or std.mem.startsWith(u8, path, "~\\")) {
        const home = environ.get("HOME") orelse environ.get("USERPROFILE") orelse ".";
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return allocator.dupe(u8, path);
}

fn findPackageRootAlloc(allocator: std.mem.Allocator, io: std.Io, start: []const u8) ![]u8 {
    var current = try allocator.dupe(u8, start);
    errdefer allocator.free(current);

    while (true) {
        if (hasPackageMarkers(allocator, io, current)) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return current;
}

fn hasPackageMarkers(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    const readme_path = std.fs.path.join(allocator, &.{ dir, "README.md" }) catch return false;
    defer allocator.free(readme_path);
    const zon_path = std.fs.path.join(allocator, &.{ dir, "build.zig.zon" }) catch return false;
    defer allocator.free(zon_path);
    return pathExists(io, readme_path) and pathExists(io, zon_path);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "compiled service URL is configured" {
    try std.testing.expect(compiled_service_base_url.len > 0);
}

test "Bulb agent paths use native config directory and environment override" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/bulb");

    const default_path = try authPathAlloc(allocator, &env);
    defer allocator.free(default_path);
    try std.testing.expectEqualStrings("/home/bulb/.bulb/agent/auth.json", default_path);

    try env.put(agent_dir_env, "~/custom-agent");
    const overridden = try authPathAlloc(allocator, &env);
    defer allocator.free(overridden);
    try std.testing.expectEqualStrings("/home/bulb/custom-agent/auth.json", overridden);
    try std.testing.expectEqualStrings("BULB_CODING_AGENT_SESSION_DIR", session_dir_env);
}

test "Bulb documentation paths resolve from package directory override" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(package_dir_env, "/opt/bulb");

    const readme = try readmePathAlloc(allocator, std.testing.io, &env);
    defer allocator.free(readme);
    try std.testing.expectEqualStrings("/opt/bulb/README.md", readme);

    const docs = try docsPathAlloc(allocator, std.testing.io, &env);
    defer allocator.free(docs);
    try std.testing.expectEqualStrings("/opt/bulb/docs", docs);

    const examples = try examplesPathAlloc(allocator, std.testing.io, &env);
    defer allocator.free(examples);
    try std.testing.expectEqualStrings("/opt/bulb/examples", examples);
}
