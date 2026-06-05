const std = @import("std");
const build_options = @import("build_options");

pub const product_name = "Bulb";
pub const command_name = "bulb";
pub const global_config_dir = ".bulb/agent";
pub const project_config_dir = ".bulb";
pub const service_base_url_env = "BULB_SERVICE_BASE_URL";
pub const agent_dir_env = "BULB_CODING_AGENT_DIR";
pub const session_dir_env = "BULB_CODING_AGENT_SESSION_DIR";
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
