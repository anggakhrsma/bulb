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
    if (try parseHostedGitUrlAlloc(allocator, split)) |source_info| {
        return source_info;
    }
    return parseGenericGitUrlAlloc(allocator, split);
}

const HostedHost = struct {
    domain: []const u8,
    kind: Kind,

    const Kind = enum {
        github,
        gitlab,
        bitbucket,
        gist,
        sourcehut,
    };
};

const HashSplit = struct {
    base: []const u8,
    ref: ?[]const u8 = null,
};

fn parseHostedGitUrlAlloc(allocator: std.mem.Allocator, split: SplitRef) !?GitSource {
    const hash_split = splitHashRef(split.repo);
    const repo_without_ref = hash_split.base;
    const ref = split.ref orelse hash_split.ref;

    if (parseScpLike(repo_without_ref)) |scp| {
        const hosted = hostedHostForDomain(scp.host) orelse return null;
        const path = normalizeHostedPath(hosted, scp.path) orelse return null;
        return try makeGitSource(allocator, repo_without_ref, hosted.domain, path, ref);
    }

    if (protocolParts(repo_without_ref)) |parts| {
        const hosted = hostedHostForDomain(parts.host) orelse return null;
        const path = normalizeHostedPath(hosted, parts.path) orelse return null;
        return try makeGitSource(allocator, repo_without_ref, hosted.domain, path, ref);
    }

    if (parseHostedShortcut(repo_without_ref)) |shortcut| {
        const repo = try std.fmt.allocPrint(allocator, "https://{s}/{s}", .{
            shortcut.host.domain,
            shortcut.path,
        });
        errdefer allocator.free(repo);
        return try makeGitSourceWithOwnedRepo(allocator, repo, shortcut.host.domain, shortcut.path, ref);
    }

    if (parseHostedDomainShorthand(repo_without_ref)) |shortcut| {
        const repo = try std.fmt.allocPrint(allocator, "https://{s}/{s}", .{
            shortcut.host.domain,
            shortcut.path,
        });
        errdefer allocator.free(repo);
        return try makeGitSourceWithOwnedRepo(allocator, repo, shortcut.host.domain, shortcut.path, ref);
    }

    if (parseGithubPathShorthand(repo_without_ref)) |path| {
        const repo = try std.fmt.allocPrint(allocator, "https://github.com/{s}", .{path});
        errdefer allocator.free(repo);
        return try makeGitSourceWithOwnedRepo(allocator, repo, "github.com", path, ref);
    }

    return null;
}

fn makeGitSource(
    allocator: std.mem.Allocator,
    repo: []const u8,
    host: []const u8,
    path: []const u8,
    ref: ?[]const u8,
) !GitSource {
    const owned_repo = try allocator.dupe(u8, repo);
    errdefer allocator.free(owned_repo);
    return try makeGitSourceWithOwnedRepo(allocator, owned_repo, host, path, ref);
}

fn makeGitSourceWithOwnedRepo(
    allocator: std.mem.Allocator,
    repo: []u8,
    host: []const u8,
    path: []const u8,
    ref: ?[]const u8,
) !GitSource {
    const owned_host = try allocator.dupe(u8, host);
    errdefer allocator.free(owned_host);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_ref = if (ref) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_ref) |value| allocator.free(value);

    return .{
        .allocator = allocator,
        .repo = repo,
        .host = owned_host,
        .path = owned_path,
        .ref = owned_ref,
        .pinned = ref != null,
    };
}

fn splitHashRef(value: []const u8) HashSplit {
    const hash_index = std.mem.indexOfScalar(u8, value, '#') orelse return .{ .base = value };
    if (hash_index == 0 or hash_index + 1 >= value.len) return .{ .base = value };
    return .{
        .base = value[0..hash_index],
        .ref = value[hash_index + 1 ..],
    };
}

fn hostedHostForDomain(raw_host: []const u8) ?HostedHost {
    const host = stripWww(raw_host);
    if (std.ascii.eqlIgnoreCase(host, "github.com")) {
        return .{ .domain = "github.com", .kind = .github };
    }
    if (std.ascii.eqlIgnoreCase(host, "gitlab.com")) {
        return .{ .domain = "gitlab.com", .kind = .gitlab };
    }
    if (std.ascii.eqlIgnoreCase(host, "bitbucket.org")) {
        return .{ .domain = "bitbucket.org", .kind = .bitbucket };
    }
    if (std.ascii.eqlIgnoreCase(host, "gist.github.com")) {
        return .{ .domain = "gist.github.com", .kind = .gist };
    }
    if (std.ascii.eqlIgnoreCase(host, "git.sr.ht")) {
        return .{ .domain = "git.sr.ht", .kind = .sourcehut };
    }
    return null;
}

fn hostedHostForShortcut(shortcut: []const u8) ?HostedHost {
    if (std.ascii.eqlIgnoreCase(shortcut, "github")) {
        return .{ .domain = "github.com", .kind = .github };
    }
    if (std.ascii.eqlIgnoreCase(shortcut, "gitlab")) {
        return .{ .domain = "gitlab.com", .kind = .gitlab };
    }
    if (std.ascii.eqlIgnoreCase(shortcut, "bitbucket")) {
        return .{ .domain = "bitbucket.org", .kind = .bitbucket };
    }
    if (std.ascii.eqlIgnoreCase(shortcut, "gist")) {
        return .{ .domain = "gist.github.com", .kind = .gist };
    }
    if (std.ascii.eqlIgnoreCase(shortcut, "sourcehut")) {
        return .{ .domain = "git.sr.ht", .kind = .sourcehut };
    }
    return null;
}

fn stripWww(host: []const u8) []const u8 {
    return if (startsWithIgnoreCase(host, "www.")) host["www.".len..] else host;
}

fn normalizeHostedPath(host: HostedHost, raw_path: []const u8) ?[]const u8 {
    const normalized = normalizeRepoPath(raw_path);
    if (normalized.len == 0) return null;

    switch (host.kind) {
        .github, .bitbucket, .sourcehut => {
            if (std.mem.indexOfScalar(u8, normalized, '/') == null) return null;
            return normalized;
        },
        .gitlab => {
            if (std.mem.indexOfScalar(u8, normalized, '/') == null) return null;
            return normalized;
        },
        .gist => return normalized,
    }
}

const HostedShortcut = struct {
    host: HostedHost,
    path: []const u8,
};

fn parseHostedShortcut(value: []const u8) ?HostedShortcut {
    if (std.mem.indexOf(u8, value, "://") != null) return null;
    const colon_index = std.mem.indexOfScalar(u8, value, ':') orelse return null;
    if (colon_index == 0 or colon_index + 1 >= value.len) return null;

    const host = hostedHostForShortcut(value[0..colon_index]) orelse return null;
    var path = value[colon_index + 1 ..];
    path = std.mem.trimStart(u8, path, "/");
    path = normalizeHostedPath(host, path) orelse return null;
    return .{ .host = host, .path = path };
}

fn parseHostedDomainShorthand(value: []const u8) ?HostedShortcut {
    if (std.mem.indexOf(u8, value, "://") != null) return null;
    if (std.mem.indexOfScalar(u8, value, ':') != null) return null;

    const slash_index = std.mem.indexOfScalar(u8, value, '/') orelse return null;
    if (slash_index == 0 or slash_index + 1 >= value.len) return null;

    const host = hostedHostForDomain(value[0..slash_index]) orelse return null;
    const path = normalizeHostedPath(host, value[slash_index + 1 ..]) orelse return null;
    return .{ .host = host, .path = path };
}

fn parseGithubPathShorthand(value: []const u8) ?[]const u8 {
    if (value.len == 0 or value[0] == '/' or value[0] == '.' or value[0] == '@') return null;
    if (std.mem.indexOfScalar(u8, value, ':') != null) return null;
    if (hasWhitespace(value)) return null;

    const first_slash = std.mem.indexOfScalar(u8, value, '/') orelse return null;
    if (first_slash == 0 or first_slash + 1 >= value.len) return null;
    if (std.mem.indexOfScalarPos(u8, value, first_slash + 1, '/') != null) return null;

    const normalized = normalizeRepoPath(value);
    if (std.mem.indexOfScalar(u8, normalized, '/') == null) return null;
    return normalized;
}

fn hasWhitespace(value: []const u8) bool {
    for (value) |char| {
        if (std.ascii.isWhitespace(char)) return true;
    }
    return false;
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

test "parseGitUrl accepts hosted aliases only with git prefix" {
    try expectGitSource(
        "git:github:user/repo",
        "https://github.com/user/repo",
        "github.com",
        "user/repo",
        null,
    );
    try expectGitSource(
        "git:user/repo#main",
        "https://github.com/user/repo",
        "github.com",
        "user/repo",
        "main",
    );
    try expectGitSource(
        "git:gitlab:group/subgroup/repo#release",
        "https://gitlab.com/group/subgroup/repo",
        "gitlab.com",
        "group/subgroup/repo",
        "release",
    );
    try expectGitSource(
        "git:bitbucket:user/repo#default",
        "https://bitbucket.org/user/repo",
        "bitbucket.org",
        "user/repo",
        "default",
    );
    try expectGitSource(
        "git:sourcehut:~user/repo#main",
        "https://git.sr.ht/~user/repo",
        "git.sr.ht",
        "~user/repo",
        "main",
    );

    try std.testing.expect(try parseGitUrlAlloc(std.testing.allocator, "github:user/repo") == null);
    try std.testing.expect(try parseGitUrlAlloc(std.testing.allocator, "user/repo#main") == null);
}

test "parseGitUrl extracts hosted fragment refs" {
    try expectGitSource(
        "https://github.com/user/repo#v1.0.0",
        "https://github.com/user/repo",
        "github.com",
        "user/repo",
        "v1.0.0",
    );
    try expectGitSource(
        "https://gitlab.com/group/subgroup/repo.git#main",
        "https://gitlab.com/group/subgroup/repo.git",
        "gitlab.com",
        "group/subgroup/repo",
        "main",
    );
    try expectGitSource(
        "git:github.com/user/repo#v2",
        "https://github.com/user/repo",
        "github.com",
        "user/repo",
        "v2",
    );
    try expectGitSource(
        "git:git@gitlab.com:group/subgroup/repo#main",
        "git@gitlab.com:group/subgroup/repo",
        "gitlab.com",
        "group/subgroup/repo",
        "main",
    );
}
