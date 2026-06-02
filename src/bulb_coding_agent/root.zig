pub const ai = @import("bulb_ai");
pub const agent = @import("bulb_agent");
pub const tui = @import("bulb_tui");
pub const extension_sdk = @import("bulb_extension_sdk");
pub const config = @import("config.zig");

const build_options = @import("build_options");

pub const version = build_options.version;

test {
    _ = @import("config.zig");
}
