pub const ai = @import("bulb_ai");
pub const agent = @import("bulb_agent");
pub const tui = @import("bulb_tui");
pub const extension_sdk = @import("bulb_extension_sdk");
pub const config = @import("config.zig");
pub const resolve_config_value = @import("resolve_config_value.zig");
pub const auth_storage = @import("auth_storage.zig");
pub const model_registry = @import("model_registry.zig");
pub const model_resolver = @import("model_resolver.zig");
pub const messages = @import("messages.zig");
pub const paths = @import("paths.zig");
pub const path_utils = @import("path_utils.zig");
pub const user_agent = @import("user_agent.zig");

const build_options = @import("build_options");

pub const version = build_options.version;

test {
    _ = @import("config.zig");
    _ = @import("resolve_config_value.zig");
    _ = @import("auth_storage.zig");
    _ = @import("model_registry.zig");
    _ = @import("model_resolver.zig");
    _ = @import("messages.zig");
    _ = @import("paths.zig");
    _ = @import("path_utils.zig");
    _ = @import("user_agent.zig");
}
