const std = @import("std");
const config = @import("config.zig");
const user_agent = @import("user_agent.zig");

pub const latest_version_path = "/api/latest-version";
pub const default_version_check_timeout_ms: u64 = 10_000;
pub const skip_version_check_env = "BULB_SKIP_VERSION_CHECK";
pub const offline_env = "BULB_OFFLINE";

const trim_chars = " \t\r\n";

pub const LatestBulbRelease = struct {
    allocator: std.mem.Allocator,
    version: []u8,
    package_name: ?[]u8 = null,
    note: ?[]u8 = null,

    pub fn deinit(self: *LatestBulbRelease) void {
        self.allocator.free(self.version);
        if (self.package_name) |package_name| self.allocator.free(package_name);
        if (self.note) |note| self.allocator.free(note);
        self.* = undefined;
    }
};

pub const VersionCheckRequest = struct {
    url: []const u8,
    user_agent: []const u8,
    accept: []const u8 = "application/json",
    timeout_ms: u64 = default_version_check_timeout_ms,
};

pub const VersionCheckResponse = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: *VersionCheckResponse) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const VersionCheckTransport = struct {
    ptr: ?*anyopaque = null,
    request_fn: *const fn (?*anyopaque, std.mem.Allocator, VersionCheckRequest) anyerror!VersionCheckResponse,

    pub fn request(
        self: VersionCheckTransport,
        allocator: std.mem.Allocator,
        request_info: VersionCheckRequest,
    ) !VersionCheckResponse {
        return self.request_fn(self.ptr, allocator, request_info);
    }
};

pub const VersionCheckOptions = struct {
    timeout_ms: ?u64 = null,
    service_base_url: ?[]const u8 = null,
    transport: ?VersionCheckTransport = null,
};

const ParsedVersion = struct {
    major: u64,
    minor: u64,
    patch: u64,
    prerelease: ?[]const u8 = null,
};

pub fn comparePackageVersions(left_version: []const u8, right_version: []const u8) ?i8 {
    const left = parsePackageVersion(left_version) orelse return null;
    const right = parsePackageVersion(right_version) orelse return null;

    if (compareU64(left.major, right.major) != 0) return compareU64(left.major, right.major);
    if (compareU64(left.minor, right.minor) != 0) return compareU64(left.minor, right.minor);
    if (compareU64(left.patch, right.patch) != 0) return compareU64(left.patch, right.patch);
    if (optionalEqual(left.prerelease, right.prerelease)) return 0;
    if (left.prerelease == null) return 1;
    if (right.prerelease == null) return -1;
    return switch (std.mem.order(u8, left.prerelease.?, right.prerelease.?)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub fn isNewerPackageVersion(candidate_version: []const u8, current_version: []const u8) bool {
    if (comparePackageVersions(candidate_version, current_version)) |comparison| {
        return comparison > 0;
    }

    const candidate_trimmed = std.mem.trim(u8, candidate_version, trim_chars);
    const current_trimmed = std.mem.trim(u8, current_version, trim_chars);
    return !std.mem.eql(u8, candidate_trimmed, current_trimmed);
}

pub fn getLatestBulbRelease(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    current_version: []const u8,
    options: VersionCheckOptions,
) !?LatestBulbRelease {
    if (isSetEnvFlag(environ.get(skip_version_check_env)) or isSetEnvFlag(environ.get(offline_env))) {
        return null;
    }

    const base_url = options.service_base_url orelse config.serviceBaseUrl(environ.*);
    const url = try latestVersionUrlAlloc(allocator, base_url);
    defer allocator.free(url);

    const agent = try user_agent.getBulbUserAgentAlloc(allocator, current_version, .{});
    defer allocator.free(agent);

    const transport = options.transport orelse stdVersionCheckTransport();
    var response = try transport.request(allocator, .{
        .url = url,
        .user_agent = agent,
        .timeout_ms = options.timeout_ms orelse default_version_check_timeout_ms,
    });
    defer response.deinit();

    if (!isOkStatus(response.status)) return null;
    return try parseLatestReleaseBody(allocator, response.body);
}

pub fn getLatestBulbVersion(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    current_version: []const u8,
    options: VersionCheckOptions,
) !?[]u8 {
    var release = (try getLatestBulbRelease(allocator, environ, current_version, options)) orelse return null;
    defer release.deinit();
    return try allocator.dupe(u8, release.version);
}

pub fn checkForNewBulbVersion(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    current_version: []const u8,
    options: VersionCheckOptions,
) ?LatestBulbRelease {
    var release = (getLatestBulbRelease(allocator, environ, current_version, options) catch return null) orelse return null;
    if (isNewerPackageVersion(release.version, current_version)) return release;
    release.deinit();
    return null;
}

fn stdVersionCheckTransport() VersionCheckTransport {
    return .{ .request_fn = stdVersionCheckRequest };
}

fn stdVersionCheckRequest(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    request_info: VersionCheckRequest,
) anyerror!VersionCheckResponse {
    _ = ptr;

    var client = std.http.Client{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer response_writer.deinit();

    const extra_headers = [_]std.http.Header{
        .{ .name = "accept", .value = request_info.accept },
    };

    const result = try client.fetch(.{
        .location = .{ .url = request_info.url },
        .method = .GET,
        .headers = .{
            .authorization = .omit,
            .content_type = .omit,
            .user_agent = .{ .override = request_info.user_agent },
        },
        .extra_headers = &extra_headers,
        .response_writer = &response_writer.writer,
        .keep_alive = false,
        .redirect_behavior = .not_allowed,
    });

    const body = try response_writer.toOwnedSlice();
    response_writer.deinit();
    return .{
        .allocator = allocator,
        .status = @intFromEnum(result.status),
        .body = body,
    };
}

fn latestVersionUrlAlloc(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base_url, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, latest_version_path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, latest_version_path });
}

fn parseLatestReleaseBody(allocator: std.mem.Allocator, body: []const u8) !?LatestBulbRelease {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    const version_text = optionalTrimmedString(object, "version") orelse return null;
    const version = try allocator.dupe(u8, version_text);
    errdefer allocator.free(version);

    const package_name = if (optionalTrimmedString(object, "packageName")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (package_name) |value| allocator.free(value);

    const note = if (optionalTrimmedString(object, "note")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (note) |value| allocator.free(value);

    return .{
        .allocator = allocator,
        .version = version,
        .package_name = package_name,
        .note = note,
    };
}

fn optionalTrimmedString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, trim_chars);
    return if (trimmed.len > 0) trimmed else null;
}

fn parsePackageVersion(version: []const u8) ?ParsedVersion {
    const text = std.mem.trim(u8, version, trim_chars);
    var index: usize = if (std.mem.startsWith(u8, text, "v")) 1 else 0;

    const major = parseVersionNumber(text, &index) orelse return null;
    if (!consumeByte(text, &index, '.')) return null;
    const minor = parseVersionNumber(text, &index) orelse return null;
    if (!consumeByte(text, &index, '.')) return null;
    const patch = parseVersionNumber(text, &index) orelse return null;

    var prerelease: ?[]const u8 = null;
    if (consumeByte(text, &index, '-')) {
        const start = index;
        while (index < text.len and isPrereleaseByte(text[index])) index += 1;
        if (index == start) return null;
        prerelease = text[start..index];
    }

    if (consumeByte(text, &index, '+')) {
        index = text.len;
    }

    if (index != text.len) return null;
    return .{
        .major = major,
        .minor = minor,
        .patch = patch,
        .prerelease = prerelease,
    };
}

fn parseVersionNumber(text: []const u8, index: *usize) ?u64 {
    const start = index.*;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) index.* += 1;
    if (index.* == start) return null;
    return std.fmt.parseInt(u64, text[start..index.*], 10) catch null;
}

fn consumeByte(text: []const u8, index: *usize, expected: u8) bool {
    if (index.* >= text.len or text[index.*] != expected) return false;
    index.* += 1;
    return true;
}

fn isPrereleaseByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-';
}

fn compareU64(left: u64, right: u64) i8 {
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn isSetEnvFlag(value: ?[]const u8) bool {
    return value != null and value.?.len > 0;
}

fn isOkStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

const FakeResponse = struct {
    status: u16 = 200,
    body: []const u8,
};

const RecordedRequest = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    user_agent: []u8,
    accept: []u8,
    timeout_ms: u64,

    fn deinit(self: *RecordedRequest) void {
        self.allocator.free(self.url);
        self.allocator.free(self.user_agent);
        self.allocator.free(self.accept);
        self.* = undefined;
    }
};

const FakeTransport = struct {
    allocator: std.mem.Allocator,
    responses: []const FakeResponse,
    calls: usize = 0,
    requests: std.ArrayList(RecordedRequest) = .empty,

    fn init(allocator: std.mem.Allocator, responses: []const FakeResponse) FakeTransport {
        return .{
            .allocator = allocator,
            .responses = responses,
        };
    }

    fn deinit(self: *FakeTransport) void {
        for (self.requests.items) |*recorded_request| recorded_request.deinit();
        self.requests.deinit(self.allocator);
    }

    fn transport(self: *FakeTransport) VersionCheckTransport {
        return .{
            .ptr = self,
            .request_fn = request,
        };
    }

    fn request(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        request_info: VersionCheckRequest,
    ) anyerror!VersionCheckResponse {
        const self: *FakeTransport = @ptrCast(@alignCast(ptr.?));
        try self.requests.append(self.allocator, .{
            .allocator = self.allocator,
            .url = try self.allocator.dupe(u8, request_info.url),
            .user_agent = try self.allocator.dupe(u8, request_info.user_agent),
            .accept = try self.allocator.dupe(u8, request_info.accept),
            .timeout_ms = request_info.timeout_ms,
        });
        if (self.calls >= self.responses.len) return error.UnexpectedVersionCheckRequest;
        const response = self.responses[self.calls];
        self.calls += 1;
        return .{
            .allocator = allocator,
            .status = response.status,
            .body = try allocator.dupe(u8, response.body),
        };
    }
};

fn testEnv(allocator: std.mem.Allocator) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(allocator);
    try env.put("HOME", "/home/bulb");
    return env;
}

test "comparePackageVersions ports package-version ordering" {
    try std.testing.expect(comparePackageVersions("0.70.6", "0.70.5").? > 0);
    try std.testing.expectEqual(@as(i8, 0), comparePackageVersions("0.70.5", "0.70.5").?);
    try std.testing.expect(comparePackageVersions("0.70.4", "0.70.5").? < 0);
    try std.testing.expect(!isNewerPackageVersion("0.70.5", "0.70.5"));
    try std.testing.expect(isNewerPackageVersion("0.70.6", "0.70.5"));
    try std.testing.expect(comparePackageVersions("v1.2.3-alpha+build.1", "1.2.3").? < 0);
    try std.testing.expect(isNewerPackageVersion("next", "1.2.3"));
}

test "checkForNewBulbVersion returns only newer versions" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator);
    defer env.deinit();

    const responses = [_]FakeResponse{
        .{ .body = "{\"version\":\"1.2.3\"}" },
        .{ .body = "{\"version\":\"1.2.3\"}" },
    };
    var transport = FakeTransport.init(allocator, &responses);
    defer transport.deinit();

    try std.testing.expectEqual(null, checkForNewBulbVersion(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    }));

    var release = checkForNewBulbVersion(allocator, &env, "1.2.2", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    }).?;
    defer release.deinit();

    try std.testing.expectEqualStrings("1.2.3", release.version);
}

test "getLatestBulbVersion uses configured service API with Bulb user agent" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator);
    defer env.deinit();

    const responses = [_]FakeResponse{
        .{ .body = "{\"version\":\"1.2.4\"}" },
    };
    var transport = FakeTransport.init(allocator, &responses);
    defer transport.deinit();

    const latest = (try getLatestBulbVersion(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev/",
        .timeout_ms = 1234,
        .transport = transport.transport(),
    })).?;
    defer allocator.free(latest);

    try std.testing.expectEqualStrings("1.2.4", latest);
    try std.testing.expectEqual(@as(usize, 1), transport.requests.items.len);
    const request_info = transport.requests.items[0];
    try std.testing.expectEqualStrings("https://bulb.dev/api/latest-version", request_info.url);
    try std.testing.expect(std.mem.startsWith(u8, request_info.user_agent, "bulb/1.2.3 "));
    try std.testing.expectEqualStrings("application/json", request_info.accept);
    try std.testing.expectEqual(@as(u64, 1234), request_info.timeout_ms);
}

test "getLatestBulbRelease returns active package metadata and update notes" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator);
    defer env.deinit();

    const responses = [_]FakeResponse{
        .{ .body = "{\"packageName\":\" @new-scope/bulb \",\"version\":\" 1.2.4 \"}" },
        .{ .body = "{\"note\":\" **Read this** \",\"version\":\"1.2.5\"}" },
    };
    var transport = FakeTransport.init(allocator, &responses);
    defer transport.deinit();

    var package_release = (try getLatestBulbRelease(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    })).?;
    defer package_release.deinit();
    try std.testing.expectEqualStrings("@new-scope/bulb", package_release.package_name.?);
    try std.testing.expectEqualStrings("1.2.4", package_release.version);
    try std.testing.expectEqual(null, package_release.note);

    var note_release = (try getLatestBulbRelease(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    })).?;
    defer note_release.deinit();
    try std.testing.expectEqualStrings("**Read this**", note_release.note.?);
    try std.testing.expectEqualStrings("1.2.5", note_release.version);
    try std.testing.expectEqual(null, note_release.package_name);
}

test "version checks skip API calls when disabled or offline" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator);
    defer env.deinit();
    try env.put(skip_version_check_env, "1");

    var transport = FakeTransport.init(allocator, &.{.{ .body = "{\"version\":\"9.9.9\"}" }});
    defer transport.deinit();

    try std.testing.expectEqual(null, try getLatestBulbVersion(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    }));
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);

    _ = env.swapRemove(skip_version_check_env);
    try env.put(offline_env, "1");

    try std.testing.expectEqual(null, try getLatestBulbVersion(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    }));
    try std.testing.expectEqual(@as(usize, 0), transport.requests.items.len);
}

test "getLatestBulbRelease ignores non-ok responses and missing versions" {
    const allocator = std.testing.allocator;
    var env = try testEnv(allocator);
    defer env.deinit();

    const responses = [_]FakeResponse{
        .{ .status = 500, .body = "{\"version\":\"9.9.9\"}" },
        .{ .body = "{\"version\":\"   \",\"note\":\"ignored\"}" },
    };
    var transport = FakeTransport.init(allocator, &responses);
    defer transport.deinit();

    try std.testing.expectEqual(null, try getLatestBulbRelease(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    }));
    try std.testing.expectEqual(null, try getLatestBulbRelease(allocator, &env, "1.2.3", .{
        .service_base_url = "https://bulb.dev",
        .transport = transport.transport(),
    }));
}
