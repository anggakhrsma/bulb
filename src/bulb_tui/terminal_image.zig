const std = @import("std");

pub const ImageProtocol = enum {
    kitty,
    iterm2,
};

pub const TerminalCapabilities = struct {
    images: ?ImageProtocol,
    true_color: bool,
    hyperlinks: bool,
};

pub const CellDimensions = struct {
    width_px: usize,
    height_px: usize,
};

pub const ImageDimensions = struct {
    width_px: usize,
    height_px: usize,
};

pub const ImageRenderOptions = struct {
    max_width_cells: ?usize = null,
    max_height_cells: ?usize = null,
    preserve_aspect_ratio: bool = true,
    image_id: ?u32 = null,
    move_cursor: bool = true,
};

pub const ImageCellSize = struct {
    columns: usize,
    rows: usize,
};

pub const RenderedImage = struct {
    sequence: []u8,
    rows: usize,
    image_id: ?u32 = null,

    pub fn deinit(self: RenderedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.sequence);
    }
};

pub const TmuxHyperlinkProbe = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque) bool = defaultTmuxHyperlinkProbe,

    pub fn call(self: TmuxHyperlinkProbe) bool {
        return self.call_fn(self.ptr);
    }
};

const KITTY_PREFIX = "\x1b_G";
const ITERM2_PREFIX = "\x1b]1337;File=";

var cached_capabilities: ?TerminalCapabilities = null;
var cell_dimensions: CellDimensions = .{ .width_px = 9, .height_px = 18 };
var process_environ: ?*const std.process.Environ.Map = null;
var next_image_id: u32 = 0;

pub fn setProcessEnvironment(environ: ?*const std.process.Environ.Map) void {
    process_environ = environ;
    resetCapabilitiesCache();
}

pub fn getCellDimensions() CellDimensions {
    return cell_dimensions;
}

pub fn setCellDimensions(dims: CellDimensions) void {
    cell_dimensions = .{
        .width_px = @max(1, dims.width_px),
        .height_px = @max(1, dims.height_px),
    };
}

pub fn detectCapabilities(
    environ: ?*const std.process.Environ.Map,
    tmux_forwards_hyperlink: TmuxHyperlinkProbe,
) TerminalCapabilities {
    const term_program = env(environ, "TERM_PROGRAM") orelse "";
    const terminal_emulator = env(environ, "TERMINAL_EMULATOR") orelse "";
    const term = env(environ, "TERM") orelse "";
    const color_term = env(environ, "COLORTERM") orelse "";
    const has_true_color_hint = eqlIgnoreCase(color_term, "truecolor") or eqlIgnoreCase(color_term, "24bit");

    if (env(environ, "TMUX") != null or startsWithIgnoreCase(term, "tmux")) {
        return .{ .images = null, .true_color = has_true_color_hint, .hyperlinks = tmux_forwards_hyperlink.call() };
    }

    if (startsWithIgnoreCase(term, "screen")) {
        return .{ .images = null, .true_color = has_true_color_hint, .hyperlinks = false };
    }

    if (env(environ, "KITTY_WINDOW_ID") != null or eqlIgnoreCase(term_program, "kitty")) {
        return .{ .images = .kitty, .true_color = true, .hyperlinks = true };
    }

    if (eqlIgnoreCase(term_program, "ghostty") or containsIgnoreCase(term, "ghostty") or env(environ, "GHOSTTY_RESOURCES_DIR") != null) {
        return .{ .images = .kitty, .true_color = true, .hyperlinks = true };
    }

    if (env(environ, "WEZTERM_PANE") != null or eqlIgnoreCase(term_program, "wezterm")) {
        return .{ .images = .kitty, .true_color = true, .hyperlinks = true };
    }

    if (env(environ, "ITERM_SESSION_ID") != null or eqlIgnoreCase(term_program, "iterm.app")) {
        return .{ .images = .iterm2, .true_color = true, .hyperlinks = true };
    }

    if (env(environ, "WT_SESSION") != null) {
        return .{ .images = null, .true_color = true, .hyperlinks = true };
    }

    if (eqlIgnoreCase(term_program, "vscode")) {
        return .{ .images = null, .true_color = true, .hyperlinks = true };
    }

    if (eqlIgnoreCase(term_program, "alacritty")) {
        return .{ .images = null, .true_color = true, .hyperlinks = true };
    }

    if (eqlIgnoreCase(terminal_emulator, "jetbrains-jediterm")) {
        return .{ .images = null, .true_color = true, .hyperlinks = false };
    }

    return .{ .images = null, .true_color = has_true_color_hint, .hyperlinks = false };
}

pub fn getCapabilities() TerminalCapabilities {
    if (cached_capabilities) |caps| return caps;
    const caps = detectCapabilities(process_environ, .{});
    cached_capabilities = caps;
    return caps;
}

pub fn resetCapabilitiesCache() void {
    cached_capabilities = null;
}

pub fn setCapabilities(caps: TerminalCapabilities) void {
    cached_capabilities = caps;
}

pub fn isImageLine(line: []const u8) bool {
    return std.mem.indexOf(u8, line, KITTY_PREFIX) != null or
        std.mem.indexOf(u8, line, ITERM2_PREFIX) != null;
}

pub fn allocateImageId() u32 {
    next_image_id +%= 1;
    if (next_image_id == 0) next_image_id = 1;
    return next_image_id;
}

pub const KittyOptions = struct {
    columns: ?usize = null,
    rows: ?usize = null,
    image_id: ?u32 = null,
    move_cursor: bool = true,
};

pub fn encodeKitty(allocator: std.mem.Allocator, base64_data: []const u8, options: KittyOptions) ![]u8 {
    const chunk_size = 4096;
    const params = try kittyParams(allocator, options, null);
    defer allocator.free(params);

    if (base64_data.len <= chunk_size) {
        return std.fmt.allocPrint(allocator, "\x1b_G{s};{s}\x1b\\", .{ params, base64_data });
    }

    var chunks: std.ArrayList(u8) = .empty;
    errdefer chunks.deinit(allocator);

    var offset: usize = 0;
    var first = true;
    while (offset < base64_data.len) {
        const end = @min(offset + chunk_size, base64_data.len);
        const chunk = base64_data[offset..end];
        const last = end >= base64_data.len;

        if (first) {
            try chunks.print(allocator, "\x1b_G{s},m=1;{s}\x1b\\", .{ params, chunk });
            first = false;
        } else if (last) {
            try chunks.print(allocator, "\x1b_Gm=0;{s}\x1b\\", .{chunk});
        } else {
            try chunks.print(allocator, "\x1b_Gm=1;{s}\x1b\\", .{chunk});
        }

        offset = end;
    }

    return chunks.toOwnedSlice(allocator);
}

pub fn deleteKittyImage(allocator: std.mem.Allocator, image_id: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{image_id});
}

pub fn deleteAllKittyImages(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "\x1b_Ga=d,d=A,q=2\x1b\\");
}

pub const ITerm2Options = struct {
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    name: ?[]const u8 = null,
    preserve_aspect_ratio: bool = true,
    inline_image: bool = true,
};

pub fn encodeITerm2(allocator: std.mem.Allocator, base64_data: []const u8, options: ITerm2Options) ![]u8 {
    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(allocator);
    try params.print(allocator, "inline={d}", .{if (options.inline_image) @as(u8, 1) else @as(u8, 0)});

    if (options.width) |width| try params.print(allocator, ";width={s}", .{width});
    if (options.height) |height| try params.print(allocator, ";height={s}", .{height});
    if (options.name) |name| {
        const encoded_len = std.base64.standard.Encoder.calcSize(name.len);
        const encoded = try allocator.alloc(u8, encoded_len);
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, name);
        try params.print(allocator, ";name={s}", .{encoded});
    }
    if (!options.preserve_aspect_ratio) try params.appendSlice(allocator, ";preserveAspectRatio=0");

    return std.fmt.allocPrint(allocator, "\x1b]1337;File={s}:{s}\x07", .{ params.items, base64_data });
}

pub fn calculateImageCellSize(
    image_dimensions: ImageDimensions,
    max_width_cells: usize,
    max_height_cells: ?usize,
    dims: CellDimensions,
) ImageCellSize {
    const max_width = @max(1, max_width_cells);
    const max_height = if (max_height_cells) |value| @max(1, value) else null;
    const image_width = @max(1, image_dimensions.width_px);
    const image_height = @max(1, image_dimensions.height_px);
    const cell_width = @max(1, dims.width_px);
    const cell_height = @max(1, dims.height_px);

    const width_scale = @as(f64, @floatFromInt(max_width * cell_width)) / @as(f64, @floatFromInt(image_width));
    const height_scale = if (max_height) |height|
        @as(f64, @floatFromInt(height * cell_height)) / @as(f64, @floatFromInt(image_height))
    else
        width_scale;
    const scale = @min(width_scale, height_scale);

    const scaled_width_px = @as(f64, @floatFromInt(image_width)) * scale;
    const scaled_height_px = @as(f64, @floatFromInt(image_height)) * scale;
    const columns = ceilDivFloat(scaled_width_px, cell_width);
    const rows = ceilDivFloat(scaled_height_px, cell_height);

    return .{
        .columns = @max(1, @min(max_width, columns)),
        .rows = @max(1, if (max_height) |height| @min(height, rows) else rows),
    };
}

pub fn calculateImageRows(image_dimensions: ImageDimensions, target_width_cells: usize, dims: CellDimensions) usize {
    return calculateImageCellSize(image_dimensions, target_width_cells, null, dims).rows;
}

pub fn getPngDimensions(allocator: std.mem.Allocator, base64_data: []const u8) ?ImageDimensions {
    const buffer = decodeBase64(allocator, base64_data) orelse return null;
    defer allocator.free(buffer);
    if (buffer.len < 24) return null;
    if (!std.mem.eql(u8, buffer[0..4], "\x89PNG")) return null;
    return .{ .width_px = readU32BE(buffer[16..20]), .height_px = readU32BE(buffer[20..24]) };
}

pub fn getJpegDimensions(allocator: std.mem.Allocator, base64_data: []const u8) ?ImageDimensions {
    const buffer = decodeBase64(allocator, base64_data) orelse return null;
    defer allocator.free(buffer);
    if (buffer.len < 2 or buffer[0] != 0xff or buffer[1] != 0xd8) return null;

    var offset: usize = 2;
    while (offset < buffer.len -| 9) {
        if (buffer[offset] != 0xff) {
            offset += 1;
            continue;
        }

        const marker = buffer[offset + 1];
        if (marker >= 0xc0 and marker <= 0xc2) {
            return .{
                .width_px = readU16BE(buffer[offset + 7 .. offset + 9]),
                .height_px = readU16BE(buffer[offset + 5 .. offset + 7]),
            };
        }

        if (offset + 3 >= buffer.len) return null;
        const length = readU16BE(buffer[offset + 2 .. offset + 4]);
        if (length < 2) return null;
        offset += 2 + length;
    }

    return null;
}

pub fn getGifDimensions(allocator: std.mem.Allocator, base64_data: []const u8) ?ImageDimensions {
    const buffer = decodeBase64(allocator, base64_data) orelse return null;
    defer allocator.free(buffer);
    if (buffer.len < 10) return null;
    if (!std.mem.eql(u8, buffer[0..6], "GIF87a") and !std.mem.eql(u8, buffer[0..6], "GIF89a")) return null;
    return .{ .width_px = readU16LE(buffer[6..8]), .height_px = readU16LE(buffer[8..10]) };
}

pub fn getWebpDimensions(allocator: std.mem.Allocator, base64_data: []const u8) ?ImageDimensions {
    const buffer = decodeBase64(allocator, base64_data) orelse return null;
    defer allocator.free(buffer);
    if (buffer.len < 30) return null;
    if (!std.mem.eql(u8, buffer[0..4], "RIFF") or !std.mem.eql(u8, buffer[8..12], "WEBP")) return null;

    const chunk = buffer[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        return .{
            .width_px = readU16LE(buffer[26..28]) & 0x3fff,
            .height_px = readU16LE(buffer[28..30]) & 0x3fff,
        };
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (buffer.len < 25) return null;
        const bits = readU32LE(buffer[21..25]);
        return .{
            .width_px = (bits & 0x3fff) + 1,
            .height_px = ((bits >> 14) & 0x3fff) + 1,
        };
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        return .{
            .width_px = (@as(usize, buffer[24]) | (@as(usize, buffer[25]) << 8) | (@as(usize, buffer[26]) << 16)) + 1,
            .height_px = (@as(usize, buffer[27]) | (@as(usize, buffer[28]) << 8) | (@as(usize, buffer[29]) << 16)) + 1,
        };
    }

    return null;
}

pub fn getImageDimensions(allocator: std.mem.Allocator, base64_data: []const u8, mime_type: []const u8) ?ImageDimensions {
    if (std.mem.eql(u8, mime_type, "image/png")) return getPngDimensions(allocator, base64_data);
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return getJpegDimensions(allocator, base64_data);
    if (std.mem.eql(u8, mime_type, "image/gif")) return getGifDimensions(allocator, base64_data);
    if (std.mem.eql(u8, mime_type, "image/webp")) return getWebpDimensions(allocator, base64_data);
    return null;
}

pub fn renderImage(allocator: std.mem.Allocator, base64_data: []const u8, image_dimensions: ImageDimensions, options: ImageRenderOptions) !?RenderedImage {
    const caps = getCapabilities();
    const protocol = caps.images orelse return null;

    const max_width = options.max_width_cells orelse 80;
    const size = calculateImageCellSize(image_dimensions, max_width, options.max_height_cells, getCellDimensions());

    switch (protocol) {
        .kitty => {
            const sequence = try encodeKitty(allocator, base64_data, .{
                .columns = size.columns,
                .rows = size.rows,
                .image_id = options.image_id,
                .move_cursor = options.move_cursor,
            });
            return .{ .sequence = sequence, .rows = size.rows, .image_id = options.image_id };
        },
        .iterm2 => {
            const width = try std.fmt.allocPrint(allocator, "{d}", .{size.columns});
            defer allocator.free(width);
            const sequence = try encodeITerm2(allocator, base64_data, .{
                .width = width,
                .height = "auto",
                .preserve_aspect_ratio = options.preserve_aspect_ratio,
            });
            return .{ .sequence = sequence, .rows = size.rows };
        },
    }
}

pub fn hyperlink(allocator: std.mem.Allocator, text: []const u8, url: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "\x1b]8;;{s}\x1b\\{s}\x1b]8;;\x1b\\", .{ url, text });
}

pub fn imageFallback(allocator: std.mem.Allocator, mime_type: []const u8, dimensions: ?ImageDimensions, filename: ?[]const u8) ![]u8 {
    var parts: std.ArrayList(u8) = .empty;
    defer parts.deinit(allocator);

    if (filename) |name| try parts.print(allocator, "{s} ", .{name});
    try parts.print(allocator, "[{s}]", .{mime_type});
    if (dimensions) |dims| try parts.print(allocator, " {d}x{d}", .{ dims.width_px, dims.height_px });

    return std.fmt.allocPrint(allocator, "[Image: {s}]", .{parts.items});
}

fn kittyParams(allocator: std.mem.Allocator, options: KittyOptions, continuation: ?u8) ![]u8 {
    var params: std.ArrayList(u8) = .empty;
    errdefer params.deinit(allocator);

    try params.appendSlice(allocator, "a=T,f=100,q=2");
    if (!options.move_cursor) try params.appendSlice(allocator, ",C=1");
    if (options.columns) |columns| try params.print(allocator, ",c={d}", .{columns});
    if (options.rows) |rows| try params.print(allocator, ",r={d}", .{rows});
    if (options.image_id) |image_id| try params.print(allocator, ",i={d}", .{image_id});
    if (continuation) |flag| try params.print(allocator, ",m={c}", .{flag});

    return params.toOwnedSlice(allocator);
}

fn decodeBase64(allocator: std.mem.Allocator, data: []const u8) ?[]u8 {
    const decoder = if (std.mem.endsWith(u8, data, "=")) std.base64.standard.Decoder else std.base64.standard_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(data) catch return null;
    const decoded = allocator.alloc(u8, decoded_len) catch return null;
    decoder.decode(decoded, data) catch {
        allocator.free(decoded);
        return null;
    };
    return decoded;
}

fn defaultTmuxHyperlinkProbe(_: ?*anyopaque) bool {
    return false;
}

fn env(environ: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const map = environ orelse return null;
    return map.get(key);
}

fn eqlIgnoreCase(value: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, expected);
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn ceilDivFloat(value: f64, divisor: usize) usize {
    const divided = value / @as(f64, @floatFromInt(divisor));
    return @max(1, @as(usize, @intFromFloat(@ceil(divided))));
}

fn readU16BE(bytes: []const u8) usize {
    return (@as(usize, bytes[0]) << 8) | @as(usize, bytes[1]);
}

fn readU16LE(bytes: []const u8) usize {
    return @as(usize, bytes[0]) | (@as(usize, bytes[1]) << 8);
}

fn readU32BE(bytes: []const u8) usize {
    return (@as(usize, bytes[0]) << 24) |
        (@as(usize, bytes[1]) << 16) |
        (@as(usize, bytes[2]) << 8) |
        @as(usize, bytes[3]);
}

fn readU32LE(bytes: []const u8) usize {
    return @as(usize, bytes[0]) |
        (@as(usize, bytes[1]) << 8) |
        (@as(usize, bytes[2]) << 16) |
        (@as(usize, bytes[3]) << 24);
}

fn probeTrue(_: ?*anyopaque) bool {
    return true;
}

fn probeFalse(_: ?*anyopaque) bool {
    return false;
}

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

fn testEnv(allocator: std.mem.Allocator, entries: []const EnvEntry) !std.process.Environ.Map {
    var environ = std.process.Environ.Map.init(allocator);
    errdefer environ.deinit();
    for (entries) |entry| try environ.put(entry.key, entry.value);
    return environ;
}

fn expectOwned(expected: []const u8, actual: []u8) !void {
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "isImageLine detects terminal image protocols anywhere in a line" {
    try std.testing.expect(isImageLine("\x1b]1337;File=inline=1:data==\x07"));
    try std.testing.expect(isImageLine("prefix \x1b]1337;File=inline=1:data==\x07 suffix"));
    try std.testing.expect(isImageLine("\x1b_Ga=T,f=100;data...\x1b\\"));
    try std.testing.expect(isImageLine("prefix \x1b_Ga=T;data...\x1b\\ suffix"));
    try std.testing.expect(isImageLine("\x1b[31mError\x1b[0m: \x1b]1337;File=inline=1:image==\x07"));
}

test "isImageLine rejects plain text and unrelated escape sequences" {
    try std.testing.expect(!isImageLine(""));
    try std.testing.expect(!isImageLine("This is just text"));
    try std.testing.expect(!isImageLine("\x1b[31mRed\x1b[0m"));
    try std.testing.expect(!isImageLine("\x1b[1A\x1b[2KLine"));
    try std.testing.expect(!isImageLine("path/to/File_1337_backup/image.jpg"));
}

test "isImageLine handles long regression lines without terminal capability state" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "Output: \x1b]1337;File=size=800,600;inline=1:");
    var index: usize = 0;
    while (index < 3040) : (index += 1) try text.appendNTimes(std.testing.allocator, 'A', 100);
    try text.appendSlice(std.testing.allocator, " end");
    try std.testing.expect(text.items.len > 300_000);
    try std.testing.expect(isImageLine(text.items));
}

test "detectCapabilities mirrors upstream terminal image and hyperlink decisions" {
    const allocator = std.testing.allocator;

    {
        var environ = try testEnv(allocator, &.{});
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{});
        try std.testing.expect(caps.images == null);
        try std.testing.expect(!caps.true_color);
        try std.testing.expect(!caps.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{ .{ .key = "TMUX", .value = "/tmp/tmux" }, .{ .key = "TERM_PROGRAM", .value = "ghostty" } });
        defer environ.deinit();
        const yes = detectCapabilities(&environ, .{ .call_fn = probeTrue });
        const no = detectCapabilities(&environ, .{ .call_fn = probeFalse });
        try std.testing.expect(yes.images == null);
        try std.testing.expect(yes.hyperlinks);
        try std.testing.expect(!no.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{.{ .key = "TERM", .value = "screen-256color" }});
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{});
        try std.testing.expect(caps.images == null);
        try std.testing.expect(!caps.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{.{ .key = "KITTY_WINDOW_ID", .value = "1" }});
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{});
        try std.testing.expectEqual(ImageProtocol.kitty, caps.images.?);
        try std.testing.expect(caps.true_color);
        try std.testing.expect(caps.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{ .{ .key = "TERM_PROGRAM", .value = "ghostty" }, .{ .key = "CMUX_WORKSPACE_ID", .value = "workspace" } });
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{});
        try std.testing.expectEqual(ImageProtocol.kitty, caps.images.?);
        try std.testing.expect(caps.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{.{ .key = "ITERM_SESSION_ID", .value = "session" }});
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{});
        try std.testing.expectEqual(ImageProtocol.iterm2, caps.images.?);
        try std.testing.expect(caps.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{ .{ .key = "WT_SESSION", .value = "session" }, .{ .key = "TERM", .value = "xterm-256color" } });
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{});
        try std.testing.expect(caps.images == null);
        try std.testing.expect(caps.true_color);
        try std.testing.expect(caps.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{.{ .key = "TERMINAL_EMULATOR", .value = "JetBrains-JediTerm" }});
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{});
        try std.testing.expect(caps.images == null);
        try std.testing.expect(caps.true_color);
        try std.testing.expect(!caps.hyperlinks);
    }

    {
        var environ = try testEnv(allocator, &.{ .{ .key = "COLORTERM", .value = "truecolor" }, .{ .key = "TMUX", .value = "/tmp/tmux" }, .{ .key = "TERM", .value = "tmux-256color" } });
        defer environ.deinit();
        const caps = detectCapabilities(&environ, .{ .call_fn = probeFalse });
        try std.testing.expect(caps.true_color);
        try std.testing.expect(!caps.hyperlinks);
    }
}

test "Kitty image encoding, deletion, and render sizing match upstream protocol choices" {
    const allocator = std.testing.allocator;

    try expectOwned("\x1b_Ga=d,d=I,i=42,q=2\x1b\\", try deleteKittyImage(allocator, 42));
    try expectOwned("\x1b_Ga=d,d=A,q=2\x1b\\", try deleteAllKittyImages(allocator));

    const no_move = try encodeKitty(allocator, "AAAA", .{ .columns = 2, .rows = 2, .move_cursor = false });
    defer allocator.free(no_move);
    try std.testing.expect(std.mem.startsWith(u8, no_move, "\x1b_Ga=T,f=100,q=2,C=1,c=2,r=2;"));

    setCapabilities(.{ .images = .kitty, .true_color = true, .hyperlinks = true });
    setCellDimensions(.{ .width_px = 10, .height_px = 10 });
    defer {
        resetCapabilitiesCache();
        setCellDimensions(.{ .width_px = 9, .height_px = 18 });
    }

    const regular = (try renderImage(allocator, "AAAA", .{ .width_px = 20, .height_px = 20 }, .{ .max_width_cells = 2 })).?;
    defer regular.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, regular.sequence, ",C=1,") == null);
    try std.testing.expectEqual(@as(usize, 2), regular.rows);

    const fixed_cursor = (try renderImage(allocator, "AAAA", .{ .width_px = 20, .height_px = 20 }, .{ .max_width_cells = 2, .move_cursor = false })).?;
    defer fixed_cursor.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, fixed_cursor.sequence, ",C=1,") != null);
    try std.testing.expectEqual(@as(usize, 2), fixed_cursor.rows);

    const constrained = (try renderImage(allocator, "AAAA", .{ .width_px = 10, .height_px = 100 }, .{ .max_width_cells = 10, .max_height_cells = 5 })).?;
    defer constrained.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), constrained.rows);
    try std.testing.expect(std.mem.indexOf(u8, constrained.sequence, ",c=1,r=5") != null);
}

test "iTerm2 encoding, hyperlink, and fallback formatting match Pi helpers" {
    const allocator = std.testing.allocator;

    const iterm = try encodeITerm2(allocator, "AAAA", .{ .width = "2", .height = "auto", .name = "cat.png", .preserve_aspect_ratio = false });
    defer allocator.free(iterm);
    try std.testing.expect(std.mem.startsWith(u8, iterm, "\x1b]1337;File=inline=1;width=2;height=auto;name="));
    try std.testing.expect(std.mem.endsWith(u8, iterm, ";preserveAspectRatio=0:AAAA\x07"));

    try expectOwned("\x1b]8;;https://example.com\x1b\\click me\x1b]8;;\x1b\\", try hyperlink(allocator, "click me", "https://example.com"));
    try expectOwned("[Image: photo.png [image/png] 800x600]", try imageFallback(allocator, "image/png", .{ .width_px = 800, .height_px = 600 }, "photo.png"));
    try expectOwned("[Image: [image/jpeg]]", try imageFallback(allocator, "image/jpeg", null, null));
}

test "image dimension sniffers parse PNG GIF JPEG and WebP headers" {
    const allocator = std.testing.allocator;

    const png = try base64Encode(allocator, &.{
        0x89, 'P',  'N',  'G',  0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00, 0x10,
    });
    defer allocator.free(png);
    try std.testing.expectEqual(ImageDimensions{ .width_px = 32, .height_px = 16 }, getPngDimensions(allocator, png).?);

    const gif = try base64Encode(allocator, "GIF89a\x20\x00\x10\x00");
    defer allocator.free(gif);
    try std.testing.expectEqual(ImageDimensions{ .width_px = 32, .height_px = 16 }, getGifDimensions(allocator, gif).?);

    const jpeg = try base64Encode(allocator, &.{
        0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08,
        0x00, 0x10, 0x00, 0x20, 0x03, 0x01, 0x11,
        0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    });
    defer allocator.free(jpeg);
    try std.testing.expectEqual(ImageDimensions{ .width_px = 32, .height_px = 16 }, getJpegDimensions(allocator, jpeg).?);

    const webp = try base64Encode(allocator, &.{
        'R',  'I', 'F', 'F',  0x16, 0, 0, 0, 'W', 'E', 'B', 'P',
        'V',  'P', '8', 'X',  0,    0, 0, 0, 0,   0,   0,   0,
        0x1f, 0,   0,   0x0f, 0,    0,
    });
    defer allocator.free(webp);
    try std.testing.expectEqual(ImageDimensions{ .width_px = 32, .height_px = 16 }, getWebpDimensions(allocator, webp).?);

    try std.testing.expect(getImageDimensions(allocator, "bad", "image/png") == null);
    try std.testing.expect(getImageDimensions(allocator, png, "image/unknown") == null);
}

fn base64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}
