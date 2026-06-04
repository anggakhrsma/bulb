const std = @import("std");

pub const Generator = struct {
    last_timestamp_ms: i64 = std.math.minInt(i64),
    sequence: u32 = 0,

    pub fn generate(self: *Generator, random: [16]u8, timestamp_ms: i64) [36]u8 {
        if (timestamp_ms > self.last_timestamp_ms) {
            self.sequence =
                (@as(u32, random[6]) << 24) |
                (@as(u32, random[7]) << 16) |
                (@as(u32, random[8]) << 8) |
                @as(u32, random[9]);
            self.last_timestamp_ms = timestamp_ms;
        } else {
            self.sequence +%= 1;
            if (self.sequence == 0) self.last_timestamp_ms += 1;
        }

        const timestamp: u64 = @intCast(@max(self.last_timestamp_ms, 0));
        var bytes: [16]u8 = undefined;
        bytes[0] = @truncate(timestamp >> 40);
        bytes[1] = @truncate(timestamp >> 32);
        bytes[2] = @truncate(timestamp >> 24);
        bytes[3] = @truncate(timestamp >> 16);
        bytes[4] = @truncate(timestamp >> 8);
        bytes[5] = @truncate(timestamp);
        bytes[6] = 0x70 | @as(u8, @truncate((self.sequence >> 28) & 0x0f));
        bytes[7] = @truncate(self.sequence >> 20);
        bytes[8] = 0x80 | @as(u8, @truncate((self.sequence >> 14) & 0x3f));
        bytes[9] = @truncate(self.sequence >> 6);
        bytes[10] = @as(u8, @truncate((self.sequence & 0x3f) << 2)) | (random[10] & 0x03);
        @memcpy(bytes[11..], random[11..]);
        return formatUuid(bytes);
    }
};

var global_generator: Generator = .{};
var global_mutex: std.Io.Mutex = .init;

pub fn uuidv7(io: std.Io) [36]u8 {
    var random: [16]u8 = undefined;
    std.Io.random(io, &random);
    const timestamp_ms = std.Io.Clock.real.now(io).toMilliseconds();

    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);
    return global_generator.generate(random, timestamp_ms);
}

fn formatUuid(bytes: [16]u8) [36]u8 {
    const hex = "0123456789abcdef";
    var output: [36]u8 = undefined;
    var output_index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        if (byte_index == 4 or byte_index == 6 or byte_index == 8 or byte_index == 10) {
            output[output_index] = '-';
            output_index += 1;
        }
        output[output_index] = hex[byte >> 4];
        output[output_index + 1] = hex[byte & 0x0f];
        output_index += 2;
    }
    return output;
}

// Ported from packages/agent/test/harness/session-uuid.test.ts.
test "uuidv7 uses RFC 9562 layout and preserves monotonic order" {
    const timestamp = 0x0123456789ab;
    const first_random = [16]u8{
        0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xfe, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55,
    };
    const empty_random = [_]u8{0} ** 16;
    var generator: Generator = .{};

    const first = generator.generate(first_random, timestamp);
    const second = generator.generate(empty_random, timestamp);
    const third = generator.generate(empty_random, timestamp);

    try std.testing.expectEqualStrings("01234567-89ab-7fff-bfff-f91122334455", &first);
    try std.testing.expectEqualStrings("01234567-89ab-7fff-bfff-fc0000000000", &second);
    try std.testing.expectEqualStrings("01234567-89ac-7000-8000-000000000000", &third);
    try std.testing.expect(std.mem.lessThan(u8, &first, &second));
    try std.testing.expect(std.mem.lessThan(u8, &second, &third));
}
