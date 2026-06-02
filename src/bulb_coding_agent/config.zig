const std = @import("std");
const build_options = @import("build_options");

pub const product_name = "Bulb";
pub const command_name = "bulb";
pub const global_config_dir = ".bulb/agent";
pub const project_config_dir = ".bulb";
pub const service_base_url_env = "BULB_SERVICE_BASE_URL";
pub const compiled_service_base_url = build_options.service_base_url;

pub fn serviceBaseUrl(environ: std.process.Environ.Map) []const u8 {
    return environ.get(service_base_url_env) orelse compiled_service_base_url;
}

test "compiled service URL is configured" {
    try std.testing.expect(compiled_service_base_url.len > 0);
}
