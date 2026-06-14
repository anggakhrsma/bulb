const std = @import("std");
const ai = @import("bulb_ai");
const mime = @import("mime.zig");
const path_utils = @import("path_utils.zig");

pub const ProcessedFiles = struct {
    text: []u8,
    images: []ai.ImageContent,

    pub fn deinit(self: *ProcessedFiles, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.images) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(self.images);
        self.* = .{ .text = &.{}, .images = &.{} };
    }
};

pub const ResizedImage = struct {
    data: []u8,
    mime_type: []u8,
    original_width: u32 = 0,
    original_height: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    was_resized: bool = false,

    pub fn deinit(self: *ResizedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.mime_type);
        self.* = .{ .data = &.{}, .mime_type = &.{} };
    }
};

pub const ResizeImageCallback = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!?ResizedImage,

    pub fn call(
        self: ResizeImageCallback,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        mime_type: []const u8,
    ) !?ResizedImage {
        return self.call_fn(self.ptr, allocator, bytes, mime_type);
    }
};

pub const ProcessFileOptions = struct {
    cwd: []const u8 = ".",
    home_dir: ?[]const u8 = null,
    auto_resize_images: bool = true,
    resize_image: ?ResizeImageCallback = null,
};

pub fn processFileArgumentsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_args: []const []const u8,
    options: ProcessFileOptions,
) !ProcessedFiles {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);

    var images: std.ArrayList(ai.ImageContent) = .empty;
    errdefer deinitImageList(allocator, &images);

    for (file_args) |file_arg| {
        const absolute_path = try path_utils.resolveReadPathAlloc(allocator, io, file_arg, options.cwd, options.home_dir);
        defer allocator.free(absolute_path);

        std.Io.Dir.cwd().access(io, absolute_path, .{}) catch return error.FileNotFound;

        const stat = try std.Io.Dir.cwd().statFile(io, absolute_path, .{ .follow_symlinks = true });
        if (stat.size == 0) continue;

        const mime_type = try mime.detectSupportedImageMimeTypeFromFile(io, absolute_path);
        if (mime_type) |image_mime_type| {
            try processImageFile(allocator, io, &text, &images, absolute_path, image_mime_type, options);
        } else {
            try processTextFile(allocator, io, &text, absolute_path);
        }
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .images = try images.toOwnedSlice(allocator),
    };
}

fn processTextFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: *std.ArrayList(u8),
    absolute_path: []const u8,
) !void {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .unlimited);
    defer allocator.free(content);
    try text.print(allocator, "<file name=\"{s}\">\n{s}\n</file>\n", .{ absolute_path, content });
}

fn processImageFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: *std.ArrayList(u8),
    images: *std.ArrayList(ai.ImageContent),
    absolute_path: []const u8,
    image_mime_type: []const u8,
    options: ProcessFileOptions,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, absolute_path, allocator, .unlimited);
    defer allocator.free(bytes);

    if (options.auto_resize_images) {
        if (options.resize_image) |resize| {
            var resized = (try resize.call(allocator, bytes, image_mime_type)) orelse {
                try text.print(allocator, "<file name=\"{s}\">[Image omitted: could not be resized below the inline image size limit.]</file>\n", .{absolute_path});
                return;
            };
            defer resized.deinit(allocator);

            const owned_data = try allocator.dupe(u8, resized.data);
            errdefer allocator.free(owned_data);
            const owned_mime = try allocator.dupe(u8, resized.mime_type);
            errdefer allocator.free(owned_mime);
            try images.append(allocator, .{ .data = owned_data, .mime_type = owned_mime });

            if (try formatDimensionNoteAlloc(allocator, resized)) |note| {
                defer allocator.free(note);
                try text.print(allocator, "<file name=\"{s}\">{s}</file>\n", .{ absolute_path, note });
            } else {
                try text.print(allocator, "<file name=\"{s}\"></file>\n", .{absolute_path});
            }
            return;
        }
    }

    const encoded = try base64Alloc(allocator, bytes);
    errdefer allocator.free(encoded);
    const owned_mime = try allocator.dupe(u8, image_mime_type);
    errdefer allocator.free(owned_mime);
    try images.append(allocator, .{ .data = encoded, .mime_type = owned_mime });
    try text.print(allocator, "<file name=\"{s}\"></file>\n", .{absolute_path});
}

pub fn formatDimensionNoteAlloc(allocator: std.mem.Allocator, result: ResizedImage) !?[]u8 {
    if (!result.was_resized) return null;
    if (result.width == 0) return null;

    const scale = @as(f64, @floatFromInt(result.original_width)) / @as(f64, @floatFromInt(result.width));
    return try std.fmt.allocPrint(
        allocator,
        "[Image: original {d}x{d}, displayed at {d}x{d}. Multiply coordinates by {d:.2} to map to original image.]",
        .{ result.original_width, result.original_height, result.width, result.height, scale },
    );
}

fn base64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn deinitImageList(allocator: std.mem.Allocator, images: *std.ArrayList(ai.ImageContent)) void {
    for (images.items) |image| {
        allocator.free(image.data);
        allocator.free(image.mime_type);
    }
    images.deinit(allocator);
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "processFileArguments embeds text files and skips empty files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "hello\nworld" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.txt", .data = "" });

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);

    var result = try processFileArgumentsAlloc(allocator, io, &.{ "note.txt", "empty.txt" }, .{ .cwd = cwd });
    defer result.deinit(allocator);

    const note_path = try std.fs.path.join(allocator, &.{ cwd, "note.txt" });
    defer allocator.free(note_path);
    const expected = try std.fmt.allocPrint(allocator, "<file name=\"{s}\">\nhello\nworld\n</file>\n", .{note_path});
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, result.text);
    try std.testing.expectEqual(@as(usize, 0), result.images.len);
}

test "processFileArguments attaches supported images as base64" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00IDAT\x00\x00\x00\x00";
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = png });

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);

    var result = try processFileArgumentsAlloc(allocator, io, &.{"image.png"}, .{ .cwd = cwd, .auto_resize_images = false });
    defer result.deinit(allocator);

    const image_path = try std.fs.path.join(allocator, &.{ cwd, "image.png" });
    defer allocator.free(image_path);
    const expected_text = try std.fmt.allocPrint(allocator, "<file name=\"{s}\"></file>\n", .{image_path});
    defer allocator.free(expected_text);

    try std.testing.expectEqualStrings(expected_text, result.text);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqualStrings("image/png", result.images[0].mime_type);
    const expected_data = try base64Alloc(allocator, png);
    defer allocator.free(expected_data);
    try std.testing.expectEqualStrings(expected_data, result.images[0].data);
}

const ResizeState = struct {
    mode: enum { resized, omitted },
};

fn testResizeCallback(ptr: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8, mime_type: []const u8) !?ResizedImage {
    _ = bytes;
    _ = mime_type;
    const state: *ResizeState = @ptrCast(@alignCast(ptr.?));
    if (state.mode == .omitted) return null;
    return .{
        .data = try allocator.dupe(u8, "resized-base64"),
        .mime_type = try allocator.dupe(u8, "image/jpeg"),
        .original_width = 4000,
        .original_height = 2000,
        .width = 2000,
        .height = 1000,
        .was_resized = true,
    };
}

test "processFileArguments uses resize hook and dimension notes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00IDAT\x00\x00\x00\x00";
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = png });

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);

    var state: ResizeState = .{ .mode = .resized };
    var result = try processFileArgumentsAlloc(allocator, io, &.{"image.png"}, .{
        .cwd = cwd,
        .resize_image = .{ .ptr = &state, .call_fn = testResizeCallback },
    });
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "[Image: original 4000x2000, displayed at 2000x1000.") != null);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqualStrings("resized-base64", result.images[0].data);
    try std.testing.expectEqualStrings("image/jpeg", result.images[0].mime_type);
}

test "processFileArguments omits images when resize hook cannot fit them" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00IDAT\x00\x00\x00\x00";
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = png });

    const cwd = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(cwd);

    var state: ResizeState = .{ .mode = .omitted };
    var result = try processFileArgumentsAlloc(allocator, io, &.{"image.png"}, .{
        .cwd = cwd,
        .resize_image = .{ .ptr = &state, .call_fn = testResizeCallback },
    });
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.text, "[Image omitted: could not be resized below the inline image size limit.]") != null);
    try std.testing.expectEqual(@as(usize, 0), result.images.len);
}

test "processFileArguments reports missing files" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.FileNotFound, processFileArgumentsAlloc(allocator, std.testing.io, &.{"missing.txt"}, .{}));
}
