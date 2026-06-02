const std = @import("std");
const builtin = @import("builtin");
const ai = @import("bulb_ai");
const config_value = @import("resolve_config_value.zig");

const max_auth_file_bytes = 1024 * 1024;
const auth_lock_max_attempts = 10;
const auth_lock_retry_delay_ms = 20;

pub const ApiKeyCredential = struct {
    key: []u8,
};

pub const AuthCredential = union(enum) {
    api_key: ApiKeyCredential,
    oauth: ai.oauth.OAuthCredentials,

    pub fn deinit(self: *AuthCredential, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .api_key => |credential| allocator.free(credential.key),
            .oauth => |*credential| credential.deinit(),
        }
    }

    pub fn clone(self: AuthCredential, allocator: std.mem.Allocator) !AuthCredential {
        return switch (self) {
            .api_key => |credential| .{ .api_key = .{ .key = try allocator.dupe(u8, credential.key) } },
            .oauth => |credential| .{ .oauth = try credential.clone(allocator) },
        };
    }
};

pub const AuthSource = enum {
    stored,
    runtime,
    environment,
    fallback,
    models_json_key,
    models_json_command,
};

pub const AuthStatus = struct {
    configured: bool,
    source: ?AuthSource = null,
    label: ?[]const u8 = null,
};

pub const FallbackResolver = struct {
    ptr: ?*anyopaque = null,
    resolve_fn: *const fn (?*anyopaque, []const u8) ?[]const u8,

    pub fn resolve(self: FallbackResolver, provider: []const u8) ?[]const u8 {
        return self.resolve_fn(self.ptr, provider);
    }
};

pub const AuthStorageLockProbe = struct {
    ptr: ?*anyopaque = null,
    after_acquire_fn: *const fn (?*anyopaque) anyerror!bool,

    pub fn afterAcquire(self: AuthStorageLockProbe) !bool {
        return self.after_acquire_fn(self.ptr);
    }
};

const StorageUpdate = struct {
    next: ?[]u8 = null,
};

const Backend = union(enum) {
    memory: ?[]u8,
    file: []u8,

    fn deinit(self: *Backend, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .memory => |content| if (content) |value| allocator.free(value),
            .file => |path| allocator.free(path),
        }
    }

    fn readAlloc(self: *const Backend, allocator: std.mem.Allocator) !?[]u8 {
        switch (self.*) {
            .memory => |content| return if (content) |value| try allocator.dupe(u8, value) else null,
            .file => |path| {
                const io = std.Io.Threaded.global_single_threaded.io();
                return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_auth_file_bytes)) catch |err| switch (err) {
                    error.FileNotFound => null,
                    else => |read_error| return read_error,
                };
            },
        }
    }

    fn write(self: *Backend, allocator: std.mem.Allocator, content: []const u8) !void {
        switch (self.*) {
            .memory => |*stored| {
                const copy = try allocator.dupe(u8, content);
                if (stored.*) |previous| allocator.free(previous);
                stored.* = copy;
            },
            .file => |path| try writeFileSecure(path, content),
        }
    }

    fn withLockUpdate(
        self: *Backend,
        allocator: std.mem.Allocator,
        probe: ?AuthStorageLockProbe,
        context: anytype,
        comptime callback: fn (@TypeOf(context), std.mem.Allocator, ?[]const u8) anyerror!StorageUpdate,
    ) !void {
        switch (self.*) {
            .memory => |content| {
                if (probe) |lock_probe| {
                    if (try lock_probe.afterAcquire()) return error.AuthStorageLockCompromised;
                }
                const update = try callback(context, allocator, content);
                if (update.next) |next| {
                    defer allocator.free(next);
                    try self.write(allocator, next);
                }
            },
            .file => |path| {
                try ensureFileExists(path);
                const io = std.Io.Threaded.global_single_threaded.io();
                var file = try openFileLockedWithRetry(io, path);
                defer file.close(io);
                defer file.unlock(io);

                if (probe) |lock_probe| {
                    if (try lock_probe.afterAcquire()) return error.AuthStorageLockCompromised;
                }

                const current = try readOpenFileAlloc(file, io, allocator);
                defer allocator.free(current);
                const update = try callback(context, allocator, current);
                if (update.next) |next| {
                    defer allocator.free(next);
                    try self.write(allocator, next);
                }
            },
        }
    }
};

pub const AuthStorage = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    env: *const std.process.Environ.Map,
    oauth_registry: *ai.oauth.Registry,
    config_resolver: *config_value.Resolver,
    data: std.StringHashMap(AuthCredential),
    runtime_overrides: std.StringHashMap([]u8),
    fallback_resolver: ?FallbackResolver = null,
    lock_probe: ?AuthStorageLockProbe = null,
    load_error: bool = false,
    errors: std.ArrayList([]u8) = .empty,

    pub fn initMemory(
        allocator: std.mem.Allocator,
        env: *const std.process.Environ.Map,
        oauth_registry: *ai.oauth.Registry,
        config_resolver: *config_value.Resolver,
    ) !AuthStorage {
        var storage = AuthStorage.init(allocator, .{ .memory = null }, env, oauth_registry, config_resolver);
        errdefer storage.deinit();
        try storage.reload();
        return storage;
    }

    pub fn initFile(
        allocator: std.mem.Allocator,
        env: *const std.process.Environ.Map,
        oauth_registry: *ai.oauth.Registry,
        config_resolver: *config_value.Resolver,
        auth_path: []const u8,
    ) !AuthStorage {
        var storage = AuthStorage.init(
            allocator,
            .{ .file = try allocator.dupe(u8, auth_path) },
            env,
            oauth_registry,
            config_resolver,
        );
        errdefer storage.deinit();
        if (try storage.backend.readAlloc(allocator)) |content| {
            allocator.free(content);
        } else {
            try storage.backend.write(allocator, "{}");
        }
        try storage.reload();
        return storage;
    }

    fn init(
        allocator: std.mem.Allocator,
        backend: Backend,
        env: *const std.process.Environ.Map,
        oauth_registry: *ai.oauth.Registry,
        config_resolver: *config_value.Resolver,
    ) AuthStorage {
        return .{
            .allocator = allocator,
            .backend = backend,
            .env = env,
            .oauth_registry = oauth_registry,
            .config_resolver = config_resolver,
            .data = std.StringHashMap(AuthCredential).init(allocator),
            .runtime_overrides = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *AuthStorage) void {
        deinitCredentialMap(self.allocator, &self.data);
        deinitStringMap(self.allocator, &self.runtime_overrides);
        for (self.errors.items) |message| self.allocator.free(message);
        self.errors.deinit(self.allocator);
        self.backend.deinit(self.allocator);
    }

    pub fn reload(self: *AuthStorage) !void {
        var context = ReloadContext{ .storage = self };
        self.backend.withLockUpdate(self.allocator, self.lock_probe, &context, reloadLocked) catch |err| {
            self.recordError(@errorName(err));
            self.load_error = true;
            return;
        };
    }

    pub fn setRuntimeApiKey(self: *AuthStorage, provider: []const u8, api_key: []const u8) !void {
        try putOwnedString(self.allocator, &self.runtime_overrides, provider, api_key);
    }

    pub fn removeRuntimeApiKey(self: *AuthStorage, provider: []const u8) void {
        removeString(self.allocator, &self.runtime_overrides, provider);
    }

    pub fn setFallbackResolver(self: *AuthStorage, resolver: FallbackResolver) void {
        self.fallback_resolver = resolver;
    }

    pub fn setLockProbe(self: *AuthStorage, probe: ?AuthStorageLockProbe) void {
        self.lock_probe = probe;
    }

    pub fn setApiKey(self: *AuthStorage, provider: []const u8, api_key: []const u8) !void {
        const key = try self.allocator.dupe(u8, api_key);
        try putOwnedCredential(self.allocator, &self.data, provider, .{ .api_key = .{ .key = key } });
        self.persistProviderChange(provider);
    }

    pub fn setOAuth(self: *AuthStorage, provider: []const u8, credentials: ai.oauth.OAuthCredentials) !void {
        try putOwnedCredential(self.allocator, &self.data, provider, .{ .oauth = try credentials.clone(self.allocator) });
        self.persistProviderChange(provider);
    }

    pub fn remove(self: *AuthStorage, provider: []const u8) void {
        removeCredential(self.allocator, &self.data, provider);
        self.persistProviderChange(provider);
    }

    pub fn get(self: *const AuthStorage, provider: []const u8) ?*const AuthCredential {
        return self.data.getPtr(provider);
    }

    pub fn has(self: *const AuthStorage, provider: []const u8) bool {
        return self.data.contains(provider);
    }

    pub fn hasAuth(self: *const AuthStorage, provider: []const u8) bool {
        if (self.runtime_overrides.contains(provider)) return true;
        if (self.data.contains(provider)) return true;
        if (ai.env_api_keys.getEnvApiKey(self.env, provider) != null) return true;
        if (self.fallback_resolver) |resolver| return resolver.resolve(provider) != null;
        return false;
    }

    pub fn getAuthStatus(self: *const AuthStorage, provider: []const u8) !AuthStatus {
        if (self.data.contains(provider)) return .{ .configured = true, .source = .stored };
        if (self.runtime_overrides.contains(provider)) {
            return .{ .configured = false, .source = .runtime, .label = "--api-key" };
        }
        if (try ai.env_api_keys.findEnvKeys(self.allocator, self.env, provider)) |keys| {
            defer self.allocator.free(keys);
            return .{ .configured = false, .source = .environment, .label = keys[0] };
        }
        if (self.fallback_resolver) |resolver| {
            if (resolver.resolve(provider) != null) {
                return .{ .configured = false, .source = .fallback, .label = "custom provider config" };
            }
        }
        return .{ .configured = false };
    }

    pub fn list(self: *const AuthStorage, allocator: std.mem.Allocator) ![][]const u8 {
        const providers = try allocator.alloc([]const u8, self.data.count());
        var iterator = self.data.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) providers[index] = entry.key_ptr.*;
        return providers;
    }

    pub fn drainErrors(self: *AuthStorage, allocator: std.mem.Allocator) ![][]u8 {
        const drained = try allocator.alloc([]u8, self.errors.items.len);
        @memcpy(drained, self.errors.items);
        self.errors.clearRetainingCapacity();
        return drained;
    }

    pub fn login(self: *AuthStorage, provider: []const u8, callbacks: ai.oauth.OAuthLoginCallbacks) !void {
        const oauth_provider = self.oauth_registry.getOAuthProvider(provider) orelse return error.UnknownOAuthProvider;
        var result = try oauth_provider.login(self.allocator, callbacks);
        defer result.deinit();
        switch (result) {
            .credentials => |credentials| try self.setOAuth(provider, credentials),
            .failed => |failure| {
                self.recordError(failure.message);
                return error.OAuthLoginFailed;
            },
        }
    }

    pub fn logout(self: *AuthStorage, provider: []const u8) void {
        self.remove(provider);
    }

    pub fn getOAuthProviders(self: *const AuthStorage) []const ai.oauth.OAuthProviderInterface {
        return self.oauth_registry.getOAuthProviders();
    }

    pub fn getApiKeyAlloc(
        self: *AuthStorage,
        allocator: std.mem.Allocator,
        provider: []const u8,
        options: GetApiKeyOptions,
    ) !?[]u8 {
        if (self.runtime_overrides.get(provider)) |api_key| return try allocator.dupe(u8, api_key);

        if (self.data.getPtr(provider)) |credential| {
            switch (credential.*) {
                .api_key => |api_key| return self.config_resolver.resolveConfigValueAlloc(allocator, api_key.key),
                .oauth => |oauth_credentials| {
                    const oauth_provider = self.oauth_registry.getOAuthProvider(provider) orelse return null;
                    if (options.clock.now() < oauth_credentials.expires) {
                        return try allocator.dupe(u8, oauth_provider.getApiKey(oauth_credentials));
                    }
                    return self.refreshOAuthApiKeyAlloc(allocator, provider, options.clock, oauth_provider);
                },
            }
        }

        if (ai.env_api_keys.getEnvApiKey(self.env, provider)) |api_key| return try allocator.dupe(u8, api_key);
        if (options.include_fallback) {
            if (self.fallback_resolver) |resolver| {
                if (resolver.resolve(provider)) |api_key| return try allocator.dupe(u8, api_key);
            }
        }
        return null;
    }

    fn refreshOAuthApiKeyAlloc(
        self: *AuthStorage,
        allocator: std.mem.Allocator,
        provider: []const u8,
        clock: ai.oauth_device_code.Clock,
        oauth_provider: ai.oauth.OAuthProviderInterface,
    ) !?[]u8 {
        var context = RefreshOAuthContext{
            .storage = self,
            .output_allocator = allocator,
            .provider = provider,
            .clock = clock,
            .oauth_provider = oauth_provider,
        };
        self.backend.withLockUpdate(self.allocator, self.lock_probe, &context, refreshOAuthLocked) catch |err| {
            self.recordError(@errorName(err));
            try self.reload();
            if (self.data.getPtr(provider)) |updated| {
                switch (updated.*) {
                    .oauth => |oauth_credentials| {
                        if (clock.now() < oauth_credentials.expires) {
                            return try allocator.dupe(u8, oauth_provider.getApiKey(oauth_credentials));
                        }
                    },
                    .api_key => {},
                }
            }
            return null;
        };
        return context.api_key;
    }

    fn persistProviderChange(self: *AuthStorage, provider: []const u8) void {
        if (self.load_error) return;
        var context = PersistProviderContext{ .storage = self, .provider = provider };
        self.backend.withLockUpdate(self.allocator, self.lock_probe, &context, persistProviderLocked) catch |err| {
            self.recordError(@errorName(err));
        };
    }

    fn recordError(self: *AuthStorage, message: []const u8) void {
        const copy = self.allocator.dupe(u8, message) catch return;
        self.errors.append(self.allocator, copy) catch self.allocator.free(copy);
    }
};

pub const GetApiKeyOptions = struct {
    include_fallback: bool = true,
    clock: ai.oauth_device_code.Clock = .{},
};

const ReloadContext = struct {
    storage: *AuthStorage,
};

fn reloadLocked(context: *ReloadContext, _: std.mem.Allocator, current: ?[]const u8) !StorageUpdate {
    const self = context.storage;
    const loaded = parseStorageData(self.allocator, storageContentOrDefault(current)) catch |err| {
        self.recordError(@errorName(err));
        self.load_error = true;
        return .{};
    };
    deinitCredentialMap(self.allocator, &self.data);
    self.data = loaded;
    self.load_error = false;
    return .{};
}

const PersistProviderContext = struct {
    storage: *AuthStorage,
    provider: []const u8,
};

fn persistProviderLocked(
    context: *PersistProviderContext,
    _: std.mem.Allocator,
    current: ?[]const u8,
) !StorageUpdate {
    const self = context.storage;
    var merged = parseStorageData(self.allocator, storageContentOrDefault(current)) catch |err| {
        self.recordError(@errorName(err));
        return .{};
    };
    defer deinitCredentialMap(self.allocator, &merged);

    if (self.data.get(context.provider)) |credential| {
        try putOwnedCredential(self.allocator, &merged, context.provider, try credential.clone(self.allocator));
    } else {
        removeCredential(self.allocator, &merged, context.provider);
    }

    return .{ .next = try stringifyStorageData(self.allocator, &merged) };
}

const RefreshOAuthContext = struct {
    storage: *AuthStorage,
    output_allocator: std.mem.Allocator,
    provider: []const u8,
    clock: ai.oauth_device_code.Clock,
    oauth_provider: ai.oauth.OAuthProviderInterface,
    api_key: ?[]u8 = null,
};

fn refreshOAuthLocked(
    context: *RefreshOAuthContext,
    _: std.mem.Allocator,
    current: ?[]const u8,
) !StorageUpdate {
    const self = context.storage;
    const loaded = parseStorageData(self.allocator, storageContentOrDefault(current)) catch |err| {
        self.recordError(@errorName(err));
        self.load_error = true;
        return .{};
    };
    deinitCredentialMap(self.allocator, &self.data);
    self.data = loaded;
    self.load_error = false;

    const credential = self.data.getPtr(context.provider) orelse return .{};
    switch (credential.*) {
        .api_key => return .{},
        .oauth => |oauth_credentials| {
            if (context.clock.now() < oauth_credentials.expires) {
                context.api_key = try context.output_allocator.dupe(
                    u8,
                    context.oauth_provider.getApiKey(oauth_credentials),
                );
                return .{};
            }
        },
    }

    var credentials = std.StringHashMap(ai.oauth.OAuthCredentials).init(self.allocator);
    defer credentials.deinit();
    var iterator = self.data.iterator();
    while (iterator.next()) |entry| {
        switch (entry.value_ptr.*) {
            .oauth => |oauth_credentials| try credentials.put(entry.key_ptr.*, oauth_credentials),
            .api_key => {},
        }
    }

    var result = self.oauth_registry.getOAuthApiKey(
        self.allocator,
        context.provider,
        &credentials,
        context.clock,
    ) catch |err| {
        self.recordError(@errorName(err));
        return .{};
    };
    defer result.deinit();
    switch (result) {
        .missing => return .{},
        .failed => |failure| {
            self.recordError(failure.message);
            return .{};
        },
        .resolved => |resolved| {
            const api_key = try context.output_allocator.dupe(u8, resolved.api_key);
            errdefer context.output_allocator.free(api_key);
            try putOwnedCredential(
                self.allocator,
                &self.data,
                context.provider,
                .{ .oauth = try resolved.credentials.clone(self.allocator) },
            );
            const next = try stringifyStorageData(self.allocator, &self.data);
            context.api_key = api_key;
            return .{ .next = next };
        },
    }
}

fn storageContentOrDefault(content: ?[]const u8) []const u8 {
    const value = content orelse return "{}";
    return if (value.len == 0) "{}" else value;
}

fn parseStorageData(allocator: std.mem.Allocator, content: []const u8) !std.StringHashMap(AuthCredential) {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthStorage;

    var result = std.StringHashMap(AuthCredential).init(allocator);
    errdefer deinitCredentialMap(allocator, &result);
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) return error.InvalidAuthCredential;
        const object = entry.value_ptr.object;
        const type_value = object.get("type") orelse return error.InvalidAuthCredential;
        if (type_value != .string) return error.InvalidAuthCredential;

        const credential: AuthCredential = if (std.mem.eql(u8, type_value.string, "api_key"))
            .{ .api_key = .{ .key = try allocator.dupe(u8, try requiredString(object, "key")) } }
        else if (std.mem.eql(u8, type_value.string, "oauth"))
            .{ .oauth = try parseOAuthCredential(allocator, object) }
        else
            return error.InvalidAuthCredential;
        try putOwnedCredential(allocator, &result, entry.key_ptr.*, credential);
    }
    return result;
}

fn parseOAuthCredential(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !ai.oauth.OAuthCredentials {
    var credential = try ai.oauth.OAuthCredentials.init(
        allocator,
        try requiredString(object, "refresh"),
        try requiredString(object, "access"),
        try requiredI64(object, "expires"),
    );
    errdefer credential.deinit();
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "type") or
            std.mem.eql(u8, entry.key_ptr.*, "refresh") or
            std.mem.eql(u8, entry.key_ptr.*, "access") or
            std.mem.eql(u8, entry.key_ptr.*, "expires")) continue;
        if (entry.value_ptr.* == .string) try credential.putExtra(entry.key_ptr.*, entry.value_ptr.string);
    }
    return credential;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidAuthCredential;
    return if (value == .string) value.string else error.InvalidAuthCredential;
}

fn requiredI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidAuthCredential;
    return switch (value) {
        .integer => |integer| integer,
        else => error.InvalidAuthCredential,
    };
}

fn stringifyStorageData(
    allocator: std.mem.Allocator,
    data: *const std.StringHashMap(AuthCredential),
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    var iterator = data.iterator();
    while (iterator.next()) |entry| {
        try json.objectField(entry.key_ptr.*);
        try json.beginObject();
        switch (entry.value_ptr.*) {
            .api_key => |credential| {
                try json.objectField("type");
                try json.write("api_key");
                try json.objectField("key");
                try json.write(credential.key);
            },
            .oauth => |credential| {
                try json.objectField("type");
                try json.write("oauth");
                try json.objectField("refresh");
                try json.write(credential.refresh);
                try json.objectField("access");
                try json.write(credential.access);
                try json.objectField("expires");
                try json.write(credential.expires);
                var extra_iterator = credential.extra.iterator();
                while (extra_iterator.next()) |extra| {
                    try json.objectField(extra.key_ptr.*);
                    try json.write(extra.value_ptr.*);
                }
            },
        }
        try json.endObject();
    }
    try json.endObject();
    return output.toOwnedSlice();
}

fn ensureFileExists(path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        _ = try cwd.createDirPathStatus(io, parent, privateDirPermissions());
    }
    var file = cwd.openFile(io, path, .{
        .mode = .read_write,
        .allow_directory = false,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            try cwd.writeFile(io, .{
                .sub_path = path,
                .data = "{}",
                .flags = .{
                    .read = true,
                    .truncate = true,
                    .permissions = privateFilePermissions(),
                },
            });
            return;
        },
        else => |open_error| return open_error,
    };
    defer file.close(io);
}

fn openFileLockedWithRetry(io: std.Io, path: []const u8) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    for (0..auth_lock_max_attempts) |attempt| {
        return cwd.openFile(io, path, .{
            .mode = .read_write,
            .allow_directory = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => {
                if (attempt + 1 == auth_lock_max_attempts) return error.AuthStorageLockUnavailable;
                try std.Io.sleep(io, .fromMilliseconds(auth_lock_retry_delay_ms), .awake);
                continue;
            },
            else => |open_error| return open_error,
        };
    }
    return error.AuthStorageLockUnavailable;
}

fn readOpenFileAlloc(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_auth_file_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |read_error| return read_error,
    };
}

fn writeFileSecure(path: []const u8, content: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        _ = try cwd.createDirPathStatus(io, parent, privateDirPermissions());
    }
    var atomic_file = try cwd.createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
        .permissions = privateFilePermissions(),
    });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, content);
    try atomic_file.replace(io);
}

fn privateFilePermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
}

fn privateDirPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else @enumFromInt(0o700);
}

fn deinitCredentialMap(allocator: std.mem.Allocator, map: *std.StringHashMap(AuthCredential)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn putOwnedCredential(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(AuthCredential),
    provider: []const u8,
    credential: AuthCredential,
) !void {
    var owned = credential;
    errdefer owned.deinit(allocator);
    if (map.getPtr(provider)) |existing| {
        existing.deinit(allocator);
        existing.* = owned;
        return;
    }
    const key = try allocator.dupe(u8, provider);
    errdefer allocator.free(key);
    try map.put(key, owned);
}

fn removeCredential(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap(AuthCredential),
    provider: []const u8,
) void {
    const entry = map.fetchRemove(provider) orelse return;
    allocator.free(entry.key);
    var credential = entry.value;
    credential.deinit(allocator);
}

fn deinitStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn putOwnedString(
    allocator: std.mem.Allocator,
    map: *std.StringHashMap([]u8),
    key_value: []const u8,
    value: []const u8,
) !void {
    const value_copy = try allocator.dupe(u8, value);
    errdefer allocator.free(value_copy);
    if (map.getPtr(key_value)) |existing| {
        allocator.free(existing.*);
        existing.* = value_copy;
        return;
    }
    const key_copy = try allocator.dupe(u8, key_value);
    errdefer allocator.free(key_copy);
    try map.put(key_copy, value_copy);
}

fn removeString(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8), key: []const u8) void {
    const entry = map.fetchRemove(key) orelse return;
    allocator.free(entry.key);
    allocator.free(entry.value);
}

fn makeTestStorage(
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    registry: *ai.oauth.Registry,
    resolver: *config_value.Resolver,
) !AuthStorage {
    return AuthStorage.initMemory(allocator, env, registry, resolver);
}

test "auth storage resolves API keys with runtime stored environment and fallback precedence" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("ANTHROPIC_API_KEY", "environment-key");
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();
    var storage = try makeTestStorage(allocator, &env, &registry, &resolver);
    defer storage.deinit();
    var fallback = TestFallback{ .value = "fallback-key" };
    storage.setFallbackResolver(.{ .ptr = &fallback, .resolve_fn = TestFallback.resolve });

    var key = (try storage.getApiKeyAlloc(allocator, "anthropic", .{})).?;
    try std.testing.expectEqualStrings("environment-key", key);

    try storage.setApiKey("anthropic", "stored-key");
    allocator.free(key);
    key = (try storage.getApiKeyAlloc(allocator, "anthropic", .{})).?;
    try std.testing.expectEqualStrings("stored-key", key);

    try storage.setRuntimeApiKey("anthropic", "runtime-key");
    allocator.free(key);
    key = (try storage.getApiKeyAlloc(allocator, "anthropic", .{})).?;
    try std.testing.expectEqualStrings("runtime-key", key);
    storage.removeRuntimeApiKey("anthropic");

    storage.remove("anthropic");
    _ = env.orderedRemove("ANTHROPIC_API_KEY");
    allocator.free(key);
    key = (try storage.getApiKeyAlloc(allocator, "anthropic", .{})).?;
    try std.testing.expectEqualStrings("fallback-key", key);
    allocator.free(key);
    try std.testing.expectEqual(null, try storage.getApiKeyAlloc(allocator, "anthropic", .{ .include_fallback = false }));
}

test "auth storage persists provider changes without overwriting external edits" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();

    try tmp.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data = "{\"anthropic\":{\"type\":\"api_key\",\"key\":\"old\"},\"openai\":{\"type\":\"api_key\",\"key\":\"openai-key\"}}",
    });
    const path = try tmp.dir.realPathFileAlloc(io, "auth.json", allocator);
    defer allocator.free(path);
    var storage = try AuthStorage.initFile(allocator, &env, &registry, &resolver, path);
    defer storage.deinit();
    try tmp.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data = "{\"anthropic\":{\"type\":\"api_key\",\"key\":\"old\"},\"openai\":{\"type\":\"api_key\",\"key\":\"openai-key\"},\"google\":{\"type\":\"api_key\",\"key\":\"google-key\"}}",
    });
    try storage.setApiKey("anthropic", "new");

    const content = try tmp.dir.readFileAlloc(io, "auth.json", allocator, .limited(max_auth_file_bytes));
    defer allocator.free(content);
    var merged = try parseStorageData(allocator, content);
    defer deinitCredentialMap(allocator, &merged);
    try std.testing.expectEqualStrings("new", merged.get("anthropic").?.api_key.key);
    try std.testing.expectEqualStrings("openai-key", merged.get("openai").?.api_key.key);
    try std.testing.expectEqualStrings("google-key", merged.get("google").?.api_key.key);
}

test "auth storage protects malformed files and drains reload errors" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();
    var storage = try makeTestStorage(allocator, &env, &registry, &resolver);
    defer storage.deinit();
    try storage.setApiKey("anthropic", "anthropic-key");
    try storage.backend.write(allocator, "{invalid-json");

    try storage.reload();
    try std.testing.expectEqualStrings("anthropic-key", storage.get("anthropic").?.api_key.key);
    try storage.setApiKey("openai", "openai-key");
    const raw = (try storage.backend.readAlloc(allocator)).?;
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("{invalid-json", raw);

    const errors = try storage.drainErrors(allocator);
    defer allocator.free(errors);
    defer for (errors) |message| allocator.free(message);
    try std.testing.expect(errors.len > 0);
    const empty = try storage.drainErrors(allocator);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "auth status never exposes stored secrets" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();
    var storage = try makeTestStorage(allocator, &env, &registry, &resolver);
    defer storage.deinit();
    try storage.setApiKey("anthropic", "secret-api-key");

    const status = try storage.getAuthStatus("anthropic");
    try std.testing.expect(status.configured);
    try std.testing.expectEqual(AuthSource.stored, status.source.?);
    try std.testing.expectEqual(null, status.label);
}

test "auth storage resolves stored command values through the shared cache" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var runner: TestCommandRunner = .{};
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();
    resolver.runner = .{ .ptr = &runner, .run_fn = TestCommandRunner.run };
    var storage = try makeTestStorage(allocator, &env, &registry, &resolver);
    defer storage.deinit();
    try storage.setApiKey("anthropic", "!stored-command");

    for (0..3) |_| {
        const key = (try storage.getApiKeyAlloc(allocator, "anthropic", .{})).?;
        defer allocator.free(key);
        try std.testing.expectEqualStrings("stored-command", key);
    }
    try std.testing.expectEqual(@as(usize, 1), runner.calls);

    resolver.clearConfigValueCache();
    const key = (try storage.getApiKeyAlloc(allocator, "anthropic", .{})).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("stored-command", key);
    try std.testing.expectEqual(@as(usize, 2), runner.calls);
}

test "auth storage refreshes expired OAuth credentials and persists open metadata" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var provider_state: TestOAuthProvider = .{};
    try registry.registerOAuthProvider(provider_state.provider());
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();
    var storage = try makeTestStorage(allocator, &env, &registry, &resolver);
    defer storage.deinit();

    var credentials = try ai.oauth.OAuthCredentials.init(allocator, "old-refresh", "old-access", 100);
    defer credentials.deinit();
    try credentials.putExtra("accountId", "account-old");
    try storage.setOAuth("test-oauth", credentials);

    var clock: TestClock = .{ .now_value = 200 };
    const key = (try storage.getApiKeyAlloc(
        allocator,
        "test-oauth",
        .{ .clock = .{ .ptr = &clock, .now_ms = TestClock.now } },
    )).?;
    defer allocator.free(key);
    try std.testing.expectEqualStrings("refreshed-access", key);
    try std.testing.expectEqual(@as(usize, 1), provider_state.refresh_calls);
    const stored = storage.get("test-oauth").?.oauth;
    try std.testing.expectEqualStrings("refreshed-access", stored.access);
    try std.testing.expectEqualStrings("account-new", stored.getExtra("accountId").?);

    const raw = (try storage.backend.readAlloc(allocator)).?;
    defer allocator.free(raw);
    var reparsed = try parseStorageData(allocator, raw);
    defer deinitCredentialMap(allocator, &reparsed);
    try std.testing.expectEqualStrings("account-new", reparsed.get("test-oauth").?.oauth.getExtra("accountId").?);
}

test "auth storage exposes OAuth providers and login logout persistence" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var provider_state: TestOAuthProvider = .{};
    try registry.registerOAuthProvider(provider_state.provider());
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();
    var storage = try makeTestStorage(allocator, &env, &registry, &resolver);
    defer storage.deinit();

    const providers = storage.getOAuthProviders();
    var found = false;
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, "test-oauth")) found = true;
    }
    try std.testing.expect(found);

    try storage.login("test-oauth", .{});
    try std.testing.expect(storage.has("test-oauth"));
    try std.testing.expectEqualStrings("login-access", storage.get("test-oauth").?.oauth.access);

    storage.logout("test-oauth");
    try std.testing.expect(!storage.has("test-oauth"));
}

test "auth storage locked OAuth refresh rereads persisted credentials first" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var provider_state: TestOAuthProvider = .{};
    try registry.registerOAuthProvider(provider_state.provider());
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();

    try tmp.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data = "{\"test-oauth\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\",\"access\":\"expired-access\",\"expires\":100}}",
    });
    const path = try tmp.dir.realPathFileAlloc(io, "auth.json", allocator);
    defer allocator.free(path);
    var storage = try AuthStorage.initFile(allocator, &env, &registry, &resolver, path);
    defer storage.deinit();

    try tmp.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data = "{\"test-oauth\":{\"type\":\"oauth\",\"refresh\":\"fresh-refresh\",\"access\":\"fresh-access\",\"expires\":1000}}",
    });
    var clock: TestClock = .{ .now_value = 200 };
    const key = (try storage.getApiKeyAlloc(
        allocator,
        "test-oauth",
        .{ .clock = .{ .ptr = &clock, .now_ms = TestClock.now } },
    )).?;
    defer allocator.free(key);

    try std.testing.expectEqualStrings("fresh-access", key);
    try std.testing.expectEqual(@as(usize, 0), provider_state.refresh_calls);
    try std.testing.expectEqualStrings("fresh-access", storage.get("test-oauth").?.oauth.access);
}

test "auth storage compromised refresh lock returns null and allows retry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    var registry = try ai.oauth.Registry.init(allocator);
    defer registry.deinit();
    var provider_state: TestOAuthProvider = .{};
    try registry.registerOAuthProvider(provider_state.provider());
    var resolver = config_value.Resolver.init(allocator, &env);
    defer resolver.deinit();

    try tmp.dir.writeFile(io, .{
        .sub_path = "auth.json",
        .data = "{\"test-oauth\":{\"type\":\"oauth\",\"refresh\":\"refresh-token\",\"access\":\"expired-access\",\"expires\":100}}",
    });
    const path = try tmp.dir.realPathFileAlloc(io, "auth.json", allocator);
    defer allocator.free(path);
    var storage = try AuthStorage.initFile(allocator, &env, &registry, &resolver, path);
    defer storage.deinit();
    var probe: OneShotLockProbe = .{};
    storage.setLockProbe(.{ .ptr = &probe, .after_acquire_fn = OneShotLockProbe.afterAcquire });

    var clock: TestClock = .{ .now_value = 200 };
    const first = try storage.getApiKeyAlloc(
        allocator,
        "test-oauth",
        .{ .clock = .{ .ptr = &clock, .now_ms = TestClock.now } },
    );
    try std.testing.expect(first == null);
    try std.testing.expectEqual(@as(usize, 0), provider_state.refresh_calls);
    const errors = try storage.drainErrors(allocator);
    defer allocator.free(errors);
    defer for (errors) |message| allocator.free(message);
    try std.testing.expect(errors.len > 0);

    const second = (try storage.getApiKeyAlloc(
        allocator,
        "test-oauth",
        .{ .clock = .{ .ptr = &clock, .now_ms = TestClock.now } },
    )).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("refreshed-access", second);
    try std.testing.expectEqual(@as(usize, 1), provider_state.refresh_calls);
}

const TestFallback = struct {
    value: ?[]const u8,

    fn resolve(ptr: ?*anyopaque, _: []const u8) ?[]const u8 {
        const self: *TestFallback = @ptrCast(@alignCast(ptr.?));
        return self.value;
    }
};

const TestCommandRunner = struct {
    calls: usize = 0,

    fn run(ptr: ?*anyopaque, allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
        const self: *TestCommandRunner = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        return try allocator.dupe(u8, command);
    }
};

const TestOAuthProvider = struct {
    refresh_calls: usize = 0,

    fn provider(self: *TestOAuthProvider) ai.oauth.OAuthProviderInterface {
        return .{
            .id = "test-oauth",
            .name = "Test OAuth",
            .context = self,
            .login_fn = login,
            .refresh_token_fn = refresh,
            .get_api_key_fn = apiKey,
        };
    }

    fn login(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: ai.oauth.OAuthLoginCallbacks,
    ) !ai.oauth.OAuthCredentialsResult {
        return .{ .credentials = try ai.oauth.OAuthCredentials.init(allocator, "login-refresh", "login-access", 1_000) };
    }

    fn refresh(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        _: ai.oauth.OAuthCredentials,
    ) !ai.oauth.OAuthCredentialsResult {
        const self: *TestOAuthProvider = @ptrCast(@alignCast(ptr));
        self.refresh_calls += 1;
        var credentials = try ai.oauth.OAuthCredentials.init(allocator, "refreshed-refresh", "refreshed-access", 1_000);
        errdefer credentials.deinit();
        try credentials.putExtra("accountId", "account-new");
        return .{ .credentials = credentials };
    }

    fn apiKey(_: *anyopaque, credentials: ai.oauth.OAuthCredentials) []const u8 {
        return credentials.access;
    }
};

const TestClock = struct {
    now_value: i64,

    fn now(ptr: ?*anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ptr.?));
        return self.now_value;
    }
};

const OneShotLockProbe = struct {
    remaining: usize = 1,

    fn afterAcquire(ptr: ?*anyopaque) !bool {
        const self: *OneShotLockProbe = @ptrCast(@alignCast(ptr.?));
        if (self.remaining == 0) return false;
        self.remaining -= 1;
        return true;
    }
};
