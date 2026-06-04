const std = @import("std");

pub const GitSource = struct {
    allocator: std.mem.Allocator,
    repo: []u8,
    host: []u8,
    path: []u8,
    ref: ?[]u8,
    pinned: bool,

    pub fn deinit(self: *GitSource) void {
        self.allocator.free(self.repo);
        self.allocator.free(self.host);
        self.allocator.free(self.path);
        if (self.ref) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

const SplitRef = struct {
    repo: []const u8,
    ref: ?[]const u8 = null,
};

/// Parse the Git source forms accepted by Pi package declarations.
///
/// Explicit protocol URLs are accepted directly. Historical SCP-like and
/// host/path shorthands require the `git:` prefix.
pub fn parseGitUrlAlloc(allocator: std.mem.Allocator, source: []const u8) !?GitSource {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    const has_git_prefix = std.mem.startsWith(u8, trimmed, "git:");
    const url = if (has_git_prefix)
        std.mem.trim(u8, trimmed["git:".len..], " \t\r\n")
    else
        trimmed;

    if (url.len == 0) return null;
    if (!has_git_prefix and !hasExplicitGitProtocol(url)) return null;

    const split = splitRef(url);
    return parseGenericGitUrlAlloc(allocator, split);
}

fn parseGenericGitUrlAlloc(allocator: std.mem.Allocator, split: SplitRef) !?GitSource {
    const repo_without_ref = split.repo;
    var host_slice: []const u8 = "";
    var path_slice: []const u8 = "";
    var add_https_prefix = false;

    if (parseScpLike(repo_without_ref)) |scp| {
        host_slice = scp.host;
        path_slice = scp.path;
    } else if (protocolParts(repo_without_ref)) |parts| {
        host_slice = parts.host;
        path_slice = parts.path;
    } else {
        const slash_index = std.mem.indexOfScalar(u8, repo_without_ref, '/') orelse return null;
        host_slice = repo_without_ref[0..slash_index];
        path_slice = repo_without_ref[slash_index + 1 ..];
        if (!std.mem.eql(u8, host_slice, "localhost") and
            std.mem.indexOfScalar(u8, host_slice, '.') == null)
        {
            return null;
        }
        add_https_prefix = true;
    }

    const normalized_path = normalizeRepoPath(path_slice);
    if (host_slice.len == 0 or normalized_path.len == 0 or
        std.mem.indexOfScalar(u8, normalized_path, '/') == null)
    {
        return null;
    }

    const repo = if (add_https_prefix)
        try std.fmt.allocPrint(allocator, "https://{s}", .{repo_without_ref})
    else
        try allocator.dupe(u8, repo_without_ref);
    errdefer allocator.free(repo);

    const host = try allocator.dupe(u8, host_slice);
    errdefer allocator.free(host);
    const path = try allocator.dupe(u8, normalized_path);
    errdefer allocator.free(path);
    const ref = if (split.ref) |value| try allocator.dupe(u8, value) else null;
    errdefer if (ref) |value| allocator.free(value);

    return .{
        .allocator = allocator,
        .repo = repo,
        .host = host,
        .path = path,
        .ref = ref,
        .pinned = ref != null,
    };
}

fn splitRef(url: []const u8) SplitRef {
    const path_start = if (parseScpLike(url)) |scp|
        scp.path.ptr - url.ptr
    else if (protocolPathStart(url)) |start|
        start
    else if (std.mem.indexOfScalar(u8, url, '/')) |slash_index|
        slash_index + 1
    else
        return .{ .repo = url };

    const ref_offset = std.mem.indexOfScalarPos(u8, url, path_start, '@') orelse return .{ .repo = url };
    if (ref_offset == path_start or ref_offset + 1 >= url.len) return .{ .repo = url };
    return .{
        .repo = url[0..ref_offset],
        .ref = url[ref_offset + 1 ..],
    };
}

const ScpLike = struct {
    host: []const u8,
    path: []const u8,
};

fn parseScpLike(url: []const u8) ?ScpLike {
    if (!std.mem.startsWith(u8, url, "git@")) return null;
    const colon_index = std.mem.indexOfScalarPos(u8, url, "git@".len, ':') orelse return null;
    if (colon_index == "git@".len or colon_index + 1 >= url.len) return null;
    return .{
        .host = url["git@".len..colon_index],
        .path = url[colon_index + 1 ..],
    };
}

const ProtocolParts = struct {
    host: []const u8,
    path: []const u8,
};

fn protocolParts(url: []const u8) ?ProtocolParts {
    const path_start = protocolPathStart(url) orelse return null;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const authority = url[scheme_end + 3 .. path_start - 1];
    if (authority.len == 0) return null;

    const host_port = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
        authority[at + 1 ..]
    else
        authority;
    const host = stripPort(host_port);
    if (host.len == 0) return null;

    return .{
        .host = host,
        .path = url[path_start..],
    };
}

fn protocolPathStart(url: []const u8) ?usize {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    if (scheme_end == 0) return null;
    return if (std.mem.indexOfScalarPos(u8, url, scheme_end + 3, '/')) |slash_index|
        slash_index + 1
    else
        null;
}

fn stripPort(host_port: []const u8) []const u8 {
    if (host_port.len == 0) return host_port;
    if (host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse return host_port;
        return host_port[0 .. close + 1];
    }
    const colon = std.mem.indexOfScalar(u8, host_port, ':') orelse return host_port;
    return host_port[0..colon];
}

fn normalizeRepoPath(path: []const u8) []const u8 {
    var normalized = std.mem.trimStart(u8, path, "/");
    if (std.mem.endsWith(u8, normalized, ".git")) {
        normalized = normalized[0 .. normalized.len - ".git".len];
    }
    return normalized;
}

fn hasExplicitGitProtocol(url: []const u8) bool {
    const protocols = [_][]const u8{ "http://", "https://", "ssh://", "git://" };
    for (protocols) |protocol| {
        if (startsWithIgnoreCase(url, protocol)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn expectGitSource(
    input: []const u8,
    expected_repo: []const u8,
    expected_host: []const u8,
    expected_path: []const u8,
    expected_ref: ?[]const u8,
) !void {
    var source = (try parseGitUrlAlloc(std.testing.allocator, input)).?;
    defer source.deinit();

    try std.testing.expectEqualStrings(expected_repo, source.repo);
    try std.testing.expectEqualStrings(expected_host, source.host);
    try std.testing.expectEqualStrings(expected_path, source.path);
    try std.testing.expectEqual(expected_ref != null, source.pinned);
    if (expected_ref) |value| {
        try std.testing.expectEqualStrings(value, source.ref.?);
    } else {
        try std.testing.expect(source.ref == null);
    }
}

test "parseGitUrl accepts explicit protocol URLs" {
    try expectGitSource(
        "https://github.com/user/repo",
        "https://github.com/user/repo",
        "github.com",
        "user/repo",
        null,
    );
    try expectGitSource(
        "ssh://git@github.com/user/repo",
        "ssh://git@github.com/user/repo",
        "github.com",
        "user/repo",
        null,
    );
    try expectGitSource(
        "https://github.com/user/repo@v1.0.0",
        "https://github.com/user/repo",
        "github.com",
        "user/repo",
        "v1.0.0",
    );
}

test "parseGitUrl accepts shorthand URLs only with git prefix" {
    try expectGitSource(
        "git:git@github.com:user/repo",
        "git@github.com:user/repo",
        "github.com",
        "user/repo",
        null,
    );
    try expectGitSource(
        "git:github.com/user/repo",
        "https://github.com/user/repo",
        "github.com",
        "user/repo",
        null,
    );
    try expectGitSource(
        "git:git@github.com:user/repo@v1.0.0",
        "git@github.com:user/repo",
        "github.com",
        "user/repo",
        "v1.0.0",
    );
}

test "parseGitUrl rejects unsupported shorthand URLs without git prefix" {
    try std.testing.expect(try parseGitUrlAlloc(std.testing.allocator, "git@github.com:user/repo") == null);
    try std.testing.expect(try parseGitUrlAlloc(std.testing.allocator, "github.com/user/repo") == null);
    try std.testing.expect(try parseGitUrlAlloc(std.testing.allocator, "user/repo") == null);
}

test "parseGitUrl normalizes git suffixes and trims declaration whitespace" {
    try expectGitSource(
        " git:https://code.example.test/team/repo.git@release ",
        "https://code.example.test/team/repo.git",
        "code.example.test",
        "team/repo",
        "release",
    );
}
