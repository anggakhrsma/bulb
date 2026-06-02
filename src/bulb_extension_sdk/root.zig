const std = @import("std");

pub const abi_version: u32 = 1;
pub const manifest_schema_version: u32 = 1;

pub const HostHandle = opaque {};
pub const ExtensionHandle = opaque {};
pub const SessionHandle = opaque {};

pub const Status = enum(u32) {
    ok = 0,
    incompatible_abi = 1,
    invalid_argument = 2,
    internal_error = 3,
};

pub const LogLevel = enum(u32) {
    debug,
    info,
    warning,
    err,
};

pub const Slice = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    pub fn fromString(value: []const u8) Slice {
        return .{
            .ptr = value.ptr,
            .len = value.len,
        };
    }
};

pub const ReleaseBufferFn = *const fn (
    context: ?*anyopaque,
    ptr: ?[*]u8,
    len: usize,
) callconv(.c) void;

pub const Buffer = extern struct {
    ptr: ?[*]u8,
    len: usize,
    release: ?ReleaseBufferFn,
    release_context: ?*anyopaque,
};

pub const LogFn = *const fn (
    host: ?*HostHandle,
    level: LogLevel,
    message: Slice,
) callconv(.c) void;

pub const RegisterToolJsonFn = *const fn (
    host: ?*HostHandle,
    definition_json: Slice,
) callconv(.c) Status;

pub const HostV1 = extern struct {
    abi_version: u32,
    handle: ?*HostHandle,
    log: ?LogFn,
    register_tool_json: ?RegisterToolJsonFn,
};

pub const InitFn = *const fn (
    host: *const HostV1,
    extension: *?*ExtensionHandle,
) callconv(.c) Status;

pub const DeinitFn = *const fn (
    extension: ?*ExtensionHandle,
) callconv(.c) void;

pub const ExtensionV1 = extern struct {
    abi_version: u32,
    name: Slice,
    version: Slice,
    init: ?InitFn,
    deinit: ?DeinitFn,
};

pub const ResourcePaths = struct {
    extensions: []const []const u8 = &.{},
    skills: []const []const u8 = &.{},
    prompts: []const []const u8 = &.{},
    themes: []const []const u8 = &.{},
};

pub const Prebuilt = struct {
    target: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const PackageManifest = struct {
    identity: []const u8,
    version: []const u8,
    sdk_abi: u32 = abi_version,
    resources: ResourcePaths = .{},
    gallery_metadata_json: ?[]const u8 = null,
    prebuilts: []const Prebuilt = &.{},
};

pub fn isCompatible(extension_abi_version: u32) bool {
    return extension_abi_version == abi_version;
}

test "extension SDK rejects unknown ABI versions" {
    try std.testing.expect(isCompatible(abi_version));
    try std.testing.expect(!isCompatible(abi_version + 1));
}

test "slice preserves borrowed string bytes" {
    const value = "bulb";
    const slice = Slice.fromString(value);
    try std.testing.expectEqual(value.len, slice.len);
    try std.testing.expectEqualSlices(u8, value, slice.ptr.?[0..slice.len]);
}
