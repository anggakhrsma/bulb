pub fn hasArg(args: []const []const u8, expected: []const u8) bool {
    for (args[1..]) |arg| {
        if (eql(arg, expected)) return true;
    }
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (a_byte != b_byte) return false;
    }
    return true;
}
