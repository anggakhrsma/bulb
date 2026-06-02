const std = @import("std");
const builtin = @import("builtin");

pub const CommandRunner = struct {
    ptr: ?*anyopaque = null,
    run_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8 = runShellCommand,

    pub fn run(self: CommandRunner, allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
        return self.run_fn(self.ptr, allocator, command);
    }
};

pub const HeaderInput = struct {
    key: []const u8,
    value: []const u8,
};

pub const ResolvedHeader = struct {
    key: []u8,
    value: []u8,
};

pub const ResolvedHeaders = struct {
    entries: []ResolvedHeader,

    pub fn deinit(self: *ResolvedHeaders, allocator: std.mem.Allocator) void {
        deinitResolvedHeaders(allocator, self.entries);
        self.* = .{ .entries = &.{} };
    }

    pub fn get(self: ResolvedHeaders, key: []const u8) ?[]const u8 {
        for (self.entries) |header| {
            if (std.mem.eql(u8, header.key, key)) return header.value;
        }
        return null;
    }
};

pub const RequiredConfigValue = union(enum) {
    value: []u8,
    failure: []u8,

    pub fn deinit(self: *RequiredConfigValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .value => |value| allocator.free(value),
            .failure => |message| allocator.free(message),
        }
        self.* = .{ .value = &.{} };
    }
};

pub const RequiredHeaders = union(enum) {
    headers: ?ResolvedHeaders,
    failure: []u8,

    pub fn deinit(self: *RequiredHeaders, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .headers => |*headers| if (headers.*) |*resolved| resolved.deinit(allocator),
            .failure => |message| allocator.free(message),
        }
        self.* = .{ .headers = null };
    }
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    runner: CommandRunner = .{},
    command_cache: std.StringHashMap(?[]u8),

    pub fn init(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) Resolver {
        return .{
            .allocator = allocator,
            .env = env,
            .command_cache = std.StringHashMap(?[]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Resolver) void {
        var iterator = self.command_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| self.allocator.free(value);
        }
        self.command_cache.deinit();
    }

    pub fn clearConfigValueCache(self: *Resolver) void {
        var iterator = self.command_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| self.allocator.free(value);
        }
        self.command_cache.clearRetainingCapacity();
    }

    pub fn resolveConfigValueAlloc(
        self: *Resolver,
        allocator: std.mem.Allocator,
        config: []const u8,
    ) !?[]u8 {
        if (isCommandConfigValue(config)) return self.executeCommandAlloc(allocator, config);
        return resolveTemplateAlloc(allocator, self.env, config);
    }

    pub fn resolveConfigValueUncachedAlloc(
        self: *Resolver,
        allocator: std.mem.Allocator,
        config: []const u8,
    ) !?[]u8 {
        if (!isCommandConfigValue(config)) return resolveTemplateAlloc(allocator, self.env, config);
        return self.runner.run(allocator, config[1..]) catch null;
    }

    pub fn resolveConfigValueOrThrowAlloc(
        self: *Resolver,
        allocator: std.mem.Allocator,
        config: []const u8,
        description: []const u8,
    ) !RequiredConfigValue {
        if (try self.resolveConfigValueUncachedAlloc(allocator, config)) |value| {
            return .{ .value = value };
        }

        return .{ .failure = try configResolutionFailureMessageAlloc(allocator, self.env, config, description) };
    }

    pub fn resolveHeadersAlloc(
        self: *Resolver,
        allocator: std.mem.Allocator,
        headers: ?[]const HeaderInput,
    ) !?ResolvedHeaders {
        const input = headers orelse return null;
        var resolved: std.ArrayList(ResolvedHeader) = .empty;
        defer resolved.deinit(allocator);
        errdefer deinitResolvedHeaderItems(allocator, resolved.items);

        for (input) |header| {
            const value = try self.resolveConfigValueAlloc(allocator, header.value);
            if (value) |resolved_value| {
                if (resolved_value.len == 0) {
                    allocator.free(resolved_value);
                    continue;
                }
                try appendResolvedHeader(allocator, &resolved, header.key, resolved_value);
            }
        }

        if (resolved.items.len == 0) return null;
        return .{ .entries = try resolved.toOwnedSlice(allocator) };
    }

    pub fn resolveHeadersOrThrowAlloc(
        self: *Resolver,
        allocator: std.mem.Allocator,
        headers: ?[]const HeaderInput,
        description: []const u8,
    ) !RequiredHeaders {
        const input = headers orelse return .{ .headers = null };
        var resolved: std.ArrayList(ResolvedHeader) = .empty;
        defer resolved.deinit(allocator);
        errdefer deinitResolvedHeaderItems(allocator, resolved.items);

        for (input) |header| {
            const header_description = try std.fmt.allocPrint(
                allocator,
                "{s} header \"{s}\"",
                .{ description, header.key },
            );
            defer allocator.free(header_description);

            const value = try self.resolveConfigValueOrThrowAlloc(allocator, header.value, header_description);
            switch (value) {
                .value => |resolved_value| try appendResolvedHeader(allocator, &resolved, header.key, resolved_value),
                .failure => |message| {
                    deinitResolvedHeaderItems(allocator, resolved.items);
                    return .{ .failure = message };
                },
            }
        }

        if (resolved.items.len == 0) return .{ .headers = null };
        return .{ .headers = .{ .entries = try resolved.toOwnedSlice(allocator) } };
    }

    fn executeCommandAlloc(
        self: *Resolver,
        allocator: std.mem.Allocator,
        config: []const u8,
    ) !?[]u8 {
        if (self.command_cache.contains(config)) {
            const cached = self.command_cache.get(config).?;
            return if (cached) |value| try allocator.dupe(u8, value) else null;
        }

        const result = self.runner.run(self.allocator, config[1..]) catch null;
        errdefer if (result) |value| self.allocator.free(value);
        const copy = if (result) |value| try allocator.dupe(u8, value) else null;
        errdefer if (copy) |value| allocator.free(value);
        const key = try self.allocator.dupe(u8, config);
        errdefer self.allocator.free(key);
        try self.command_cache.put(key, result);
        return copy;
    }
};

pub fn getConfigValueEnvVarName(config: []const u8) ?[]const u8 {
    if (isCommandConfigValue(config)) return null;
    if (parseSingleEnvReference(config)) |reference| {
        if (reference.end == config.len) return reference.name;
    }
    return null;
}

pub fn getConfigValueEnvVarNames(
    allocator: std.mem.Allocator,
    config: []const u8,
) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    if (isCommandConfigValue(config)) return try names.toOwnedSlice(allocator);

    var index: usize = 0;
    while (index < config.len) {
        const dollar_index = std.mem.indexOfScalarPos(u8, config, index, '$') orelse break;
        const reference = parseEnvReference(config, dollar_index) orelse {
            index = @min(dollar_index + 2, config.len);
            continue;
        };
        var duplicate = false;
        for (names.items) |name| {
            if (std.mem.eql(u8, name, reference.name)) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try names.append(allocator, reference.name);
        index = reference.end;
    }
    return try names.toOwnedSlice(allocator);
}

pub fn getMissingConfigValueEnvVarNames(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    config: []const u8,
) ![][]const u8 {
    const names = try getConfigValueEnvVarNames(allocator, config);
    defer allocator.free(names);
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(allocator);
    for (names) |name| {
        if (getConfiguredEnv(env, name) == null) try missing.append(allocator, name);
    }
    return try missing.toOwnedSlice(allocator);
}

pub fn isCommandConfigValue(config: []const u8) bool {
    return std.mem.startsWith(u8, config, "!");
}

pub fn isConfigValueConfigured(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    config: []const u8,
) !bool {
    const missing = try getMissingConfigValueEnvVarNames(allocator, env, config);
    defer allocator.free(missing);
    return missing.len == 0;
}

pub fn isLegacyEnvVarNameConfigValue(config: []const u8) bool {
    if (config.len == 0 or !isLegacyEnvStart(config[0])) return false;
    for (config[1..]) |character| {
        if (!isLegacyEnvContinue(character)) return false;
    }
    return true;
}

fn resolveTemplateAlloc(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    config: []const u8,
) !?[]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < config.len) {
        const dollar_index = std.mem.indexOfScalarPos(u8, config, index, '$') orelse {
            try output.appendSlice(allocator, config[index..]);
            break;
        };
        try output.appendSlice(allocator, config[index..dollar_index]);

        if (dollar_index + 1 >= config.len) {
            try output.append(allocator, '$');
            break;
        }
        const next = config[dollar_index + 1];
        if (next == '$' or next == '!') {
            try output.append(allocator, next);
            index = dollar_index + 2;
            continue;
        }

        const reference = parseEnvReference(config, dollar_index) orelse {
            try output.append(allocator, '$');
            index = dollar_index + 1;
            continue;
        };
        const value = getConfiguredEnv(env, reference.name) orelse return null;
        try output.appendSlice(allocator, value);
        index = reference.end;
    }
    return try output.toOwnedSlice(allocator);
}

fn configResolutionFailureMessageAlloc(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    config: []const u8,
    description: []const u8,
) ![]u8 {
    if (isCommandConfigValue(config)) {
        return try std.fmt.allocPrint(
            allocator,
            "Failed to resolve {s} from shell command: {s}",
            .{ description, config[1..] },
        );
    }

    const missing = try getMissingConfigValueEnvVarNames(allocator, env, config);
    defer allocator.free(missing);
    if (missing.len == 1) {
        return try std.fmt.allocPrint(
            allocator,
            "Failed to resolve {s} from environment variable: {s}",
            .{ description, missing[0] },
        );
    }
    if (missing.len > 1) {
        const joined = try joinEnvVarNamesAlloc(allocator, missing);
        defer allocator.free(joined);
        return try std.fmt.allocPrint(
            allocator,
            "Failed to resolve {s} from environment variables: {s}",
            .{ description, joined },
        );
    }

    return try std.fmt.allocPrint(allocator, "Failed to resolve {s}", .{description});
}

fn joinEnvVarNamesAlloc(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (names, 0..) |name, index| {
        if (index > 0) try output.appendSlice(allocator, ", ");
        try output.appendSlice(allocator, name);
    }
    return try output.toOwnedSlice(allocator);
}

fn appendResolvedHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(ResolvedHeader),
    key: []const u8,
    value: []u8,
) !void {
    errdefer allocator.free(value);
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    try headers.append(allocator, .{ .key = key_copy, .value = value });
}

fn deinitResolvedHeaders(allocator: std.mem.Allocator, headers: []ResolvedHeader) void {
    deinitResolvedHeaderItems(allocator, headers);
    allocator.free(headers);
}

fn deinitResolvedHeaderItems(allocator: std.mem.Allocator, headers: []ResolvedHeader) void {
    for (headers) |header| {
        allocator.free(header.key);
        allocator.free(header.value);
    }
}

const EnvReference = struct {
    name: []const u8,
    end: usize,
};

fn parseSingleEnvReference(config: []const u8) ?EnvReference {
    if (config.len == 0 or config[0] != '$') return null;
    return parseEnvReference(config, 0);
}

fn parseEnvReference(config: []const u8, dollar_index: usize) ?EnvReference {
    if (dollar_index + 1 >= config.len or config[dollar_index] != '$') return null;
    const next = config[dollar_index + 1];
    if (next == '$' or next == '!') return null;

    if (next == '{') {
        const name_start = dollar_index + 2;
        const end = std.mem.indexOfScalarPos(u8, config, name_start, '}') orelse return null;
        const name = config[name_start..end];
        if (!isEnvName(name)) return null;
        return .{ .name = name, .end = end + 1 };
    }

    if (!isEnvStart(next)) return null;
    var end = dollar_index + 2;
    while (end < config.len and isEnvContinue(config[end])) : (end += 1) {}
    return .{ .name = config[dollar_index + 1 .. end], .end = end };
}

fn isEnvName(name: []const u8) bool {
    if (name.len == 0 or !isEnvStart(name[0])) return false;
    for (name[1..]) |character| {
        if (!isEnvContinue(character)) return false;
    }
    return true;
}

fn isEnvStart(character: u8) bool {
    return std.ascii.isAlphabetic(character) or character == '_';
}

fn isEnvContinue(character: u8) bool {
    return isEnvStart(character) or std.ascii.isDigit(character);
}

fn isLegacyEnvStart(character: u8) bool {
    return std.ascii.isUpper(character) or character == '_';
}

fn isLegacyEnvContinue(character: u8) bool {
    return isLegacyEnvStart(character) or std.ascii.isDigit(character);
}

fn getConfiguredEnv(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len > 0) value else null;
}

fn runShellCommand(_: ?*anyopaque, allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const process_allocator = std.heap.page_allocator;
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/s", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
    const result = std.process.run(process_allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch return null;
    defer process_allocator.free(result.stdout);
    defer process_allocator.free(result.stderr);
    switch (result.term) {
        .exited => |status| if (status != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (trimmed.len > 0) try allocator.dupe(u8, trimmed) else null;
}

const FakeRunner = struct {
    calls: usize = 0,

    fn run(ptr: ?*anyopaque, allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        if (std.mem.eql(u8, command, "fail")) return null;
        return try allocator.dupe(u8, command);
    }
};

test "config values resolve literals environment templates and escapes" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("LEFT", "left");
    try env.put("RIGHT_2", "right");

    var resolver = Resolver.init(allocator, &env);
    defer resolver.deinit();

    const cases = [_]struct { config: []const u8, expected: ?[]const u8 }{
        .{ .config = "literal", .expected = "literal" },
        .{ .config = "$LEFT", .expected = "left" },
        .{ .config = "${LEFT}_${RIGHT_2}", .expected = "left_right" },
        .{ .config = "$$LEFT", .expected = "$LEFT" },
        .{ .config = "$!literal-$RIGHT_2", .expected = "!literal-right" },
        .{ .config = "$MISSING", .expected = null },
    };
    for (cases) |case| {
        const actual = try resolver.resolveConfigValueAlloc(allocator, case.config);
        defer if (actual) |value| allocator.free(value);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, actual.?);
        } else {
            try std.testing.expectEqual(null, actual);
        }
    }
}

test "config command results including failures are cached until cleared" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: FakeRunner = .{};
    var resolver = Resolver.init(allocator, &env);
    defer resolver.deinit();
    resolver.runner = .{ .ptr = &runner, .run_fn = FakeRunner.run };

    for (0..3) |_| {
        const value = (try resolver.resolveConfigValueAlloc(allocator, "!cached")).?;
        defer allocator.free(value);
        try std.testing.expectEqualStrings("cached", value);
    }
    for (0..2) |_| try std.testing.expectEqual(null, try resolver.resolveConfigValueAlloc(allocator, "!fail"));
    try std.testing.expectEqual(@as(usize, 2), runner.calls);

    resolver.clearConfigValueCache();
    const value = (try resolver.resolveConfigValueAlloc(allocator, "!cached")).?;
    defer allocator.free(value);
    try std.testing.expectEqual(@as(usize, 3), runner.calls);
}

test "config value helpers expose environment references and legacy names" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ONE", "1");

    try std.testing.expectEqualStrings("ONE", getConfigValueEnvVarName("$ONE").?);
    try std.testing.expectEqual(null, getConfigValueEnvVarName("${ONE}-${TWO}"));
    const names = try getConfigValueEnvVarNames(allocator, "${ONE}-$TWO-${ONE}");
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("ONE", names[0]);
    try std.testing.expectEqualStrings("TWO", names[1]);
    const missing = try getMissingConfigValueEnvVarNames(allocator, &env, "${ONE}-$TWO");
    defer allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("TWO", missing[0]);
    try std.testing.expect(try isConfigValueConfigured(allocator, &env, "${ONE}"));
    try std.testing.expect(!try isConfigValueConfigured(allocator, &env, "$TWO"));
    try std.testing.expect(isLegacyEnvVarNameConfigValue("ANTHROPIC_API_KEY"));
    try std.testing.expect(!isLegacyEnvVarNameConfigValue("anthropic_api_key"));
}

test "required config values report Pi-compatible failure messages" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: FakeRunner = .{};
    var resolver = Resolver.init(allocator, &env);
    defer resolver.deinit();
    resolver.runner = .{ .ptr = &runner, .run_fn = FakeRunner.run };

    var literal = try resolver.resolveConfigValueOrThrowAlloc(allocator, "", "empty literal");
    defer literal.deinit(allocator);
    switch (literal) {
        .value => |value| try std.testing.expectEqualStrings("", value),
        .failure => return error.UnexpectedFailure,
    }

    var missing_one = try resolver.resolveConfigValueOrThrowAlloc(allocator, "$TOKEN", "API key");
    defer missing_one.deinit(allocator);
    switch (missing_one) {
        .value => return error.UnexpectedValue,
        .failure => |message| try std.testing.expectEqualStrings(
            "Failed to resolve API key from environment variable: TOKEN",
            message,
        ),
    }

    var missing_many = try resolver.resolveConfigValueOrThrowAlloc(allocator, "${LEFT}-$RIGHT", "headers");
    defer missing_many.deinit(allocator);
    switch (missing_many) {
        .value => return error.UnexpectedValue,
        .failure => |message| try std.testing.expectEqualStrings(
            "Failed to resolve headers from environment variables: LEFT, RIGHT",
            message,
        ),
    }

    var command_failure = try resolver.resolveConfigValueOrThrowAlloc(allocator, "!fail", "API key");
    defer command_failure.deinit(allocator);
    switch (command_failure) {
        .value => return error.UnexpectedValue,
        .failure => |message| try std.testing.expectEqualStrings(
            "Failed to resolve API key from shell command: fail",
            message,
        ),
    }
}

test "required config values execute commands uncached" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var runner: FakeRunner = .{};
    var resolver = Resolver.init(allocator, &env);
    defer resolver.deinit();
    resolver.runner = .{ .ptr = &runner, .run_fn = FakeRunner.run };

    for (0..2) |_| {
        var value = try resolver.resolveConfigValueOrThrowAlloc(allocator, "!uncached", "API key");
        defer value.deinit(allocator);
        switch (value) {
            .value => |resolved| try std.testing.expectEqualStrings("uncached", resolved),
            .failure => return error.UnexpectedFailure,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), runner.calls);
}

test "headers resolve optional values and required failures" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CUSTOM_HEADER", "custom-value");
    var runner: FakeRunner = .{};
    var resolver = Resolver.init(allocator, &env);
    defer resolver.deinit();
    resolver.runner = .{ .ptr = &runner, .run_fn = FakeRunner.run };

    const headers = [_]HeaderInput{
        .{ .key = "X-Literal", .value = "literal" },
        .{ .key = "X-Custom-Header", .value = "$CUSTOM_HEADER" },
        .{ .key = "X-Missing", .value = "$MISSING_HEADER" },
        .{ .key = "X-Empty", .value = "!fail" },
    };
    var optional = (try resolver.resolveHeadersAlloc(allocator, &headers)).?;
    defer optional.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), optional.entries.len);
    try std.testing.expectEqualStrings("literal", optional.get("X-Literal").?);
    try std.testing.expectEqualStrings("custom-value", optional.get("X-Custom-Header").?);
    try std.testing.expectEqual(null, optional.get("X-Missing"));

    const empty_optional = try resolver.resolveHeadersAlloc(allocator, &.{});
    try std.testing.expectEqual(null, empty_optional);

    const required_headers = [_]HeaderInput{
        .{ .key = "X-Empty", .value = "" },
        .{ .key = "X-Custom-Header", .value = "$CUSTOM_HEADER" },
    };
    var required = try resolver.resolveHeadersOrThrowAlloc(allocator, &required_headers, "provider \"custom\"");
    defer required.deinit(allocator);
    switch (required) {
        .headers => |maybe_headers| {
            const resolved = maybe_headers.?;
            try std.testing.expectEqual(@as(usize, 2), resolved.entries.len);
            try std.testing.expectEqualStrings("", resolved.get("X-Empty").?);
            try std.testing.expectEqualStrings("custom-value", resolved.get("X-Custom-Header").?);
        },
        .failure => return error.UnexpectedFailure,
    }

    const failing_headers = [_]HeaderInput{
        .{ .key = "X-Custom-Header", .value = "$CUSTOM_HEADER" },
        .{ .key = "X-Missing", .value = "$MISSING_HEADER" },
    };
    var failed = try resolver.resolveHeadersOrThrowAlloc(allocator, &failing_headers, "provider \"custom\"");
    defer failed.deinit(allocator);
    switch (failed) {
        .headers => return error.UnexpectedValue,
        .failure => |message| try std.testing.expectEqualStrings(
            "Failed to resolve provider \"custom\" header \"X-Missing\" from environment variable: MISSING_HEADER",
            message,
        ),
    }
}

test "config shell commands preserve pipes trim output and reject failures" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var resolver = Resolver.init(allocator, &env);
    defer resolver.deinit();

    const value = (try resolver.resolveConfigValueAlloc(allocator, "!echo 'hello world' | tr ' ' '-'")).?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("hello-world", value);
    try std.testing.expectEqual(null, try resolver.resolveConfigValueAlloc(allocator, "!exit 1"));
    try std.testing.expectEqual(null, try resolver.resolveConfigValueAlloc(allocator, "!printf ''"));
}
