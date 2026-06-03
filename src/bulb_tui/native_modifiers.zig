const builtin = @import("builtin");

pub const ModifierKey = enum {
    shift,
    command,
    control,
    option,
};

pub fn isNativeModifierPressed(_: ModifierKey) bool {
    // Pi loads an optional macOS Node native helper and falls back to false when
    // the helper is unavailable. Bulb has no Node addon path, so the portable
    // foundation keeps the same safe fallback until native hooks land.
    _ = builtin.os.tag;
    return false;
}

test "native modifier fallback reports unpressed keys" {
    try @import("std").testing.expect(!isNativeModifierPressed(.shift));
    try @import("std").testing.expect(!isNativeModifierPressed(.command));
    try @import("std").testing.expect(!isNativeModifierPressed(.control));
    try @import("std").testing.expect(!isNativeModifierPressed(.option));
}
