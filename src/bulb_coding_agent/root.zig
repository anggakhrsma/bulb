pub const ai = @import("bulb_ai");
pub const agent = @import("bulb_agent");
pub const tui = @import("bulb_tui");
pub const extension_sdk = @import("bulb_extension_sdk");
pub const config = @import("config.zig");
pub const resolve_config_value = @import("resolve_config_value.zig");
pub const auth_storage = @import("auth_storage.zig");
pub const model_registry = @import("model_registry.zig");

const build_options = @import("build_options");

pub const version = build_options.version;

test {
    _ = @import("config.zig");
    _ = @import("resolve_config_value.zig");
    _ = @import("auth_storage.zig");
    _ = @import("model_registry.zig");
}
