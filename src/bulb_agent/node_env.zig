const std = @import("std");
const builtin = @import("builtin");

const shell_output = @import("shell_output.zig");
const types = @import("types.zig");
const uuid = @import("uuid.zig");

const Result = types.Result;

pub const LocalExecutionEnvOptions = struct {
    cwd: []const u8,
    shell_path: ?[]const u8 = null,
    shell_env: ?*const std.process.Environ.Map = null,
    temp_dir: ?[]const u8 = null,
};

pub const LocalExecutionEnv = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []u8,
    shell_path: ?[]u8 = null,
    shell_env: ?std.process.Environ.Map = null,
    temp_dir: []u8,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: LocalExecutionEnvOptions,
    ) !LocalExecutionEnv {
        const cwd = try std.fs.path.resolve(allocator, &.{options.cwd});
        errdefer allocator.free(cwd);

        const shell_path = if (options.shell_path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (shell_path) |path| allocator.free(path);

        var shell_env = if (options.shell_env) |base_env| try base_env.clone(allocator) else null;
        errdefer if (shell_env) |*base_env| base_env.deinit();

        const temp_dir = if (options.temp_dir) |path|
            try std.fs.path.resolve(allocator, &.{path})
        else
            try defaultTempDirAlloc(allocator);
        errdefer allocator.free(temp_dir);

        return .{
            .allocator = allocator,
            .io = io,
            .cwd = cwd,
            .shell_path = shell_path,
            .shell_env = shell_env,
            .temp_dir = temp_dir,
        };
    }

    pub fn deinit(self: *LocalExecutionEnv) void {
        self.allocator.free(self.cwd);
        if (self.shell_path) |path| self.allocator.free(path);
        if (self.shell_env) |*base_env| base_env.deinit();
        self.allocator.free(self.temp_dir);
        self.* = undefined;
    }

    pub fn env(self: *LocalExecutionEnv) types.ExecutionEnv {
        return .{
            .ptr = self,
            .cwd = self.cwd,
            .absolute_path_fn = absolutePath,
            .join_path_fn = joinPath,
            .exec_fn = exec,
            .read_text_file_fn = readTextFile,
            .read_text_lines_fn = readTextLines,
            .read_binary_file_fn = readBinaryFile,
            .write_file_fn = writeFile,
            .append_file_fn = appendFile,
            .file_info_fn = fileInfo,
            .list_dir_fn = listDir,
            .canonical_path_fn = canonicalPath,
            .exists_fn = exists,
            .create_dir_fn = createDir,
            .remove_fn = remove,
            .create_temp_dir_fn = createTempDir,
            .create_temp_file_fn = createTempFile,
            .cleanup_fn = cleanup,
        };
    }

    pub fn absolutePathAlloc(self: *LocalExecutionEnv, allocator: std.mem.Allocator, path: []const u8) !Result([]u8, types.FileError) {
        return absolutePath(self, allocator, path);
    }

    pub fn joinPathAlloc(self: *LocalExecutionEnv, allocator: std.mem.Allocator, parts: []const []const u8) !Result([]u8, types.FileError) {
        return joinPath(self, allocator, parts);
    }
};

pub const NodeExecutionEnvOptions = LocalExecutionEnvOptions;
pub const NodeExecutionEnv = LocalExecutionEnv;

fn absolutePath(ptr: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) !Result([]u8, types.FileError) {
    const self = context(ptr);
    return .{ .ok = try resolvePathAlloc(allocator, self.cwd, path) };
}

fn joinPath(_: ?*anyopaque, allocator: std.mem.Allocator, parts: []const []const u8) !Result([]u8, types.FileError) {
    return .{ .ok = try std.fs.path.join(allocator, parts) };
}

fn exec(
    ptr: ?*anyopaque,
    command: []const u8,
    options: types.ExecutionEnvExecOptions,
) !Result(types.ExecutionEnvExecResult, types.ExecutionError) {
    const self = context(ptr);
    if (isAborted(options.abort_signal)) {
        return .{ .err = .{ .code = .aborted, .message = "aborted" } };
    }

    const cwd = if (options.cwd) |cwd_value|
        try resolvePathAlloc(self.allocator, self.cwd, cwd_value)
    else
        try self.allocator.dupe(u8, self.cwd);
    defer self.allocator.free(cwd);

    var env_storage: ?std.process.Environ.Map = null;
    defer if (env_storage) |*env_map| env_map.deinit();
    const env = try buildEnvMap(self.allocator, if (self.shell_env) |*env_map| env_map else null, options.env, &env_storage);

    var shell_config = getShellConfigAlloc(self.allocator, self.io, env, self.shell_path) catch |err| switch (err) {
        error.ShellUnavailable => return .{ .err = .{ .code = .shell_unavailable, .message = "No bash shell found" } },
        else => |other| return other,
    };
    defer shell_config.deinit(self.allocator);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.allocator);
    try argv.append(self.allocator, shell_config.shell);
    for (shell_config.args) |arg| try argv.append(self.allocator, arg);
    try argv.append(self.allocator, command);

    var child = std.process.spawn(self.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .windows) null else 0,
        .create_no_window = true,
    }) catch |err| {
        return .{ .err = .{ .code = .spawn_error, .message = @errorName(err) } };
    };
    var child_running = true;
    defer if (child_running) child.kill(self.io);

    const pid = childPid(child);
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(self.allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(self.allocator);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(self.allocator, self.io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const timeout = timeoutFromSeconds(options.timeout_seconds).toDeadline(self.io);
    while (true) {
        multi_reader.fill(1024, timeout) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                killSpawnedChild(self.allocator, self.io, pid, &child, &child_running);
                return .{ .err = .{ .code = .timeout, .message = "timeout" } };
            },
            else => |fill_err| return fill_err,
        };

        if (try drainReader(self.allocator, multi_reader.reader(0), &stdout, options.on_stdout)) |callback_error| {
            killSpawnedChild(self.allocator, self.io, pid, &child, &child_running);
            return .{ .err = callback_error };
        }
        if (try drainReader(self.allocator, multi_reader.reader(1), &stderr, options.on_stderr)) |callback_error| {
            killSpawnedChild(self.allocator, self.io, pid, &child, &child_running);
            return .{ .err = callback_error };
        }
        if (isAborted(options.abort_signal)) {
            killSpawnedChild(self.allocator, self.io, pid, &child, &child_running);
            return .{ .err = .{ .code = .aborted, .message = "aborted" } };
        }
    }

    if (try drainReader(self.allocator, multi_reader.reader(0), &stdout, options.on_stdout)) |callback_error| {
        killSpawnedChild(self.allocator, self.io, pid, &child, &child_running);
        return .{ .err = callback_error };
    }
    if (try drainReader(self.allocator, multi_reader.reader(1), &stderr, options.on_stderr)) |callback_error| {
        killSpawnedChild(self.allocator, self.io, pid, &child, &child_running);
        return .{ .err = callback_error };
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(self.io);
    child_running = false;

    const owned_stdout = try stdout.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_stdout);
    const owned_stderr = try stderr.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned_stderr);

    return .{ .ok = .{
        .stdout = owned_stdout,
        .stderr = owned_stderr,
        .exit_code = exitCodeFromTerm(term),
        .owns_output = true,
    } };
}

fn readTextFile(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
    abort_signal: ?*const types.AbortSignal,
) !Result([]u8, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(allocator, self.cwd, path);
    defer allocator.free(resolved);
    if (abortFileResult([]u8, abort_signal, resolved)) |result| return result;
    const content = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, allocator, .unlimited) catch |err| {
        return .{ .err = fileError(err, path) };
    };
    return .{ .ok = content };
}

fn readTextLines(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: types.ReadTextLinesOptions,
) !Result([][]u8, types.FileError) {
    const self = context(ptr);
    if (options.max_lines) |max_lines| {
        if (max_lines == 0) return .{ .ok = try allocator.alloc([]u8, 0) };
    }

    const file_result = try readTextFile(self, allocator, path, options.abort_signal);
    const content = switch (file_result) {
        .ok => |value| value,
        .err => |err_value| return .{ .err = err_value },
    };
    defer allocator.free(content);
    if (abortFileResult([][]u8, options.abort_signal, path)) |result| return result;

    var lines: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, lines.items);

    var start: usize = 0;
    while (start < content.len) {
        if (options.max_lines) |max_lines| {
            if (lines.items.len >= max_lines) break;
        }
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        const raw_line = content[start..end];
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        try lines.append(allocator, try allocator.dupe(u8, line));
        if (end == content.len) break;
        start = end + 1;
    }

    return .{ .ok = try lines.toOwnedSlice(allocator) };
}

fn readBinaryFile(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
    abort_signal: ?*const types.AbortSignal,
) !Result([]u8, types.FileError) {
    return readTextFile(ptr, allocator, path, abort_signal);
}

fn writeFile(
    ptr: ?*anyopaque,
    path: []const u8,
    content: []const u8,
    abort_signal: ?*const types.AbortSignal,
) !Result(void, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(self.allocator, self.cwd, path);
    defer self.allocator.free(resolved);
    if (abortFileResult(void, abort_signal, resolved)) |result| return result;

    createParentDirs(self.io, resolved) catch |err| return .{ .err = fileError(err, path) };
    if (abortFileResult(void, abort_signal, resolved)) |result| return result;

    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = resolved, .data = content }) catch |err| {
        return .{ .err = fileError(err, path) };
    };
    return .{ .ok = {} };
}

fn appendFile(
    ptr: ?*anyopaque,
    path: []const u8,
    content: []const u8,
    abort_signal: ?*const types.AbortSignal,
) !Result(void, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(self.allocator, self.cwd, path);
    defer self.allocator.free(resolved);
    if (abortFileResult(void, abort_signal, resolved)) |result| return result;

    createParentDirs(self.io, resolved) catch |err| return .{ .err = fileError(err, path) };
    if (abortFileResult(void, abort_signal, resolved)) |result| return result;

    appendFileAbsolute(self.io, resolved, content) catch |err| {
        return .{ .err = fileError(err, path) };
    };
    return .{ .ok = {} };
}

fn fileInfo(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
) !Result(types.FileInfo, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(allocator, self.cwd, path);
    defer allocator.free(resolved);

    const stat = std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = false }) catch |err| {
        return .{ .err = fileError(err, path) };
    };
    return fileInfoFromStatAlloc(allocator, resolved, stat);
}

fn listDir(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
    abort_signal: ?*const types.AbortSignal,
) !Result([]types.FileInfo, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(allocator, self.cwd, path);
    defer allocator.free(resolved);
    if (abortFileResult([]types.FileInfo, abort_signal, resolved)) |result| return result;

    var directory = openDirPath(self.io, resolved, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        return .{ .err = fileError(err, path) };
    };
    defer directory.close(self.io);

    var infos: std.ArrayList(types.FileInfo) = .empty;
    errdefer deinitFileInfoList(allocator, infos.items);

    var iterator = directory.iterate();
    while (iterator.next(self.io) catch |err| return .{ .err = fileError(err, path) }) |entry| {
        if (abortFileResult([]types.FileInfo, abort_signal, resolved)) |result| return result;

        const entry_path = try std.fs.path.join(allocator, &.{ resolved, entry.name });
        defer allocator.free(entry_path);
        const stat = std.Io.Dir.cwd().statFile(self.io, entry_path, .{ .follow_symlinks = false }) catch |err| {
            return .{ .err = fileError(err, entry_path) };
        };
        const info_result = try fileInfoFromStatAlloc(allocator, entry_path, stat);
        switch (info_result) {
            .ok => |info| try infos.append(allocator, info),
            .err => {},
        }
    }

    return .{ .ok = try infos.toOwnedSlice(allocator) };
}

fn canonicalPath(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    path: []const u8,
) !Result([]u8, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(allocator, self.cwd, path);
    defer allocator.free(resolved);

    const real = std.Io.Dir.cwd().realPathFileAlloc(self.io, resolved, allocator) catch |err| {
        return .{ .err = fileError(err, path) };
    };
    defer allocator.free(real);
    return .{ .ok = try allocator.dupe(u8, real) };
}

fn exists(ptr: ?*anyopaque, path: []const u8) !Result(bool, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(self.allocator, self.cwd, path);
    defer self.allocator.free(resolved);

    _ = std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = false },
        else => return .{ .err = fileError(err, path) },
    };
    return .{ .ok = true };
}

fn createDir(
    ptr: ?*anyopaque,
    path: []const u8,
    options: types.CreateDirOptions,
) !Result(void, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(self.allocator, self.cwd, path);
    defer self.allocator.free(resolved);
    if (abortFileResult(void, options.abort_signal, resolved)) |result| return result;

    if (options.recursive) {
        std.Io.Dir.cwd().createDirPath(self.io, resolved) catch |err| return .{ .err = fileError(err, path) };
    } else {
        std.Io.Dir.cwd().createDir(self.io, resolved, .default_dir) catch |err| return .{ .err = fileError(err, path) };
    }
    return .{ .ok = {} };
}

fn remove(
    ptr: ?*anyopaque,
    path: []const u8,
    options: types.RemoveOptions,
) !Result(void, types.FileError) {
    const self = context(ptr);
    const resolved = try resolvePathAlloc(self.allocator, self.cwd, path);
    defer self.allocator.free(resolved);
    if (abortFileResult(void, options.abort_signal, resolved)) |result| return result;

    if (options.recursive) {
        if (!options.force) {
            _ = std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = false }) catch |err| {
                return .{ .err = fileError(err, path) };
            };
        }
        std.Io.Dir.cwd().deleteTree(self.io, resolved) catch |err| return .{ .err = fileError(err, path) };
        return .{ .ok = {} };
    }

    const stat = std.Io.Dir.cwd().statFile(self.io, resolved, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            if (options.force) return .{ .ok = {} };
            return .{ .err = fileError(err, path) };
        },
        else => return .{ .err = fileError(err, path) },
    };

    switch (stat.kind) {
        .directory => std.Io.Dir.cwd().deleteDir(self.io, resolved) catch |err| return .{ .err = fileError(err, path) },
        else => std.Io.Dir.cwd().deleteFile(self.io, resolved) catch |err| return .{ .err = fileError(err, path) },
    }
    return .{ .ok = {} };
}

fn createTempDir(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    options: types.CreateTempDirOptions,
) !Result([]u8, types.FileError) {
    const self = context(ptr);
    if (abortFileResult([]u8, options.abort_signal, self.temp_dir)) |result| return result;

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        const id = uuid.uuidv7(self.io);
        const name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ options.prefix, &id });
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ self.temp_dir, name });
        errdefer allocator.free(path);
        std.Io.Dir.cwd().createDirPath(self.io, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return .{ .err = fileError(err, path) },
        };
        return .{ .ok = path };
    }
    return .{ .err = .{ .code = .unknown, .message = "unable to create temporary directory" } };
}

fn createTempFile(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    options: types.CreateTempFileOptions,
) !Result([]u8, types.FileError) {
    const self = context(ptr);
    const dir_result = try createTempDir(self, allocator, .{
        .prefix = "tmp-",
        .abort_signal = options.abort_signal,
    });
    const dir = switch (dir_result) {
        .ok => |value| value,
        .err => |err_value| return .{ .err = err_value },
    };
    errdefer allocator.free(dir);

    const id = uuid.uuidv7(self.io);
    const name = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ options.prefix, &id, options.suffix });
    defer allocator.free(name);
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    allocator.free(dir);
    errdefer allocator.free(path);

    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "" }) catch |err| {
        return .{ .err = fileError(err, path) };
    };
    return .{ .ok = path };
}

fn cleanup(_: ?*anyopaque) !void {}

const ShellConfig = struct {
    shell: []u8,
    args: []const []const u8 = &.{"-c"},

    fn deinit(self: *ShellConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.shell);
        self.* = .{ .shell = &.{} };
    }
};

const ShellConfigError = error{ShellUnavailable} || std.mem.Allocator.Error;

fn getShellConfigAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    custom_shell_path: ?[]const u8,
) ShellConfigError!ShellConfig {
    if (custom_shell_path) |path| {
        if (pathExists(io, path)) return .{ .shell = try allocator.dupe(u8, path) };
        return error.ShellUnavailable;
    }

    if (builtin.os.tag == .windows) {
        if (env) |env_map| {
            if (env_map.get("ProgramFiles")) |program_files| {
                const candidate = try std.fmt.allocPrint(allocator, "{s}\\Git\\bin\\bash.exe", .{program_files});
                if (pathExists(io, candidate)) return .{ .shell = candidate };
                allocator.free(candidate);
            }
            if (env_map.get("ProgramFiles(x86)")) |program_files_x86| {
                const candidate = try std.fmt.allocPrint(allocator, "{s}\\Git\\bin\\bash.exe", .{program_files_x86});
                if (pathExists(io, candidate)) return .{ .shell = candidate };
                allocator.free(candidate);
            }
            if (try findBashOnPathAlloc(allocator, io, env_map, .windows)) |bash| return .{ .shell = bash };
        }
        return error.ShellUnavailable;
    }

    if (pathExists(io, "/bin/bash")) {
        return .{ .shell = try allocator.dupe(u8, "/bin/bash") };
    }
    if (env) |env_map| {
        if (try findBashOnPathAlloc(allocator, io, env_map, builtin.os.tag)) |bash| {
            return .{ .shell = bash };
        }
    }
    return .{ .shell = try allocator.dupe(u8, "sh") };
}

fn buildEnvMap(
    allocator: std.mem.Allocator,
    base: ?*const std.process.Environ.Map,
    extra: []const types.EnvVar,
    storage: *?std.process.Environ.Map,
) !?*const std.process.Environ.Map {
    if (base == null and extra.len == 0) return null;
    storage.* = if (base) |env| try env.clone(allocator) else std.process.Environ.Map.init(allocator);
    for (extra) |entry| try storage.*.?.put(entry.name, entry.value);
    return &storage.*.?;
}

fn findBashOnPathAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    os_tag: std.Target.Os.Tag,
) !?[]u8 {
    const path_value = env.get("PATH") orelse env.get("Path") orelse return null;
    var iterator = std.mem.splitScalar(u8, path_value, pathDelimiterForOs(os_tag));
    while (iterator.next()) |entry| {
        if (entry.len == 0) continue;
        const candidate = try bashCandidateAlloc(allocator, entry, os_tag);
        if (pathExists(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn bashCandidateAlloc(allocator: std.mem.Allocator, dir: []const u8, os_tag: std.Target.Os.Tag) ![]u8 {
    const executable = if (os_tag == .windows) "bash.exe" else "bash";
    if (dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ dir, executable });
    }
    const separator: u8 = if (os_tag == .windows) '\\' else '/';
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ dir, separator, executable });
}

fn pathDelimiterForOs(os_tag: std.Target.Os.Tag) u8 {
    return if (os_tag == .windows) ';' else ':';
}

fn resolvePathAlloc(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn defaultTempDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => allocator.dupe(u8, "C:\\Windows\\Temp"),
        else => allocator.dupe(u8, "/tmp"),
    };
}

fn openDirPath(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, options);
    return std.Io.Dir.cwd().openDir(io, path, options);
}

fn createParentDirs(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn appendFileAbsolute(io: std.Io, path: []const u8, content: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => {
            var created = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer created.close(io);
            try created.writeStreamingAll(io, content);
            return;
        },
        else => |open_err| return open_err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    try file.writePositionalAll(io, content, stat.size);
}

fn fileInfoFromStatAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    stat: std.Io.File.Stat,
) !Result(types.FileInfo, types.FileError) {
    const kind = switch (stat.kind) {
        .file => types.FileKind.file,
        .directory => types.FileKind.directory,
        .sym_link => types.FileKind.symlink,
        else => return .{ .err = .{ .code = .invalid, .message = "Unsupported file type", .path = path } },
    };

    const trimmed = trimTrailingSeparators(path);
    const basename = std.fs.path.basename(trimmed);
    return .{ .ok = .{
        .name = try allocator.dupe(u8, if (basename.len == 0) path else basename),
        .path = try allocator.dupe(u8, path),
        .kind = kind,
        .size = stat.size,
        .mtime_ms = stat.mtime.toMilliseconds(),
    } };
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
    return path[0..end];
}

fn drainReader(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    output: *std.ArrayList(u8),
    callback: ?types.ExecutionChunkCallback,
) !?types.ExecutionError {
    const buffered = reader.buffered();
    if (buffered.len == 0) return null;
    try output.appendSlice(allocator, buffered);
    if (callback) |handler| {
        handler.call(buffered) catch |err| {
            reader.toss(buffered.len);
            return .{ .code = .callback_error, .message = @errorName(err) };
        };
    }
    reader.toss(buffered.len);
    return null;
}

fn timeoutFromSeconds(timeout_seconds: ?u64) std.Io.Timeout {
    const seconds = timeout_seconds orelse return .none;
    if (seconds == 0) return .none;
    const clamped = @min(seconds, @as(u64, @intCast(std.math.maxInt(i64))));
    return .{ .duration = .{
        .raw = .fromSeconds(@intCast(clamped)),
        .clock = .awake,
    } };
}

fn exitCodeFromTerm(term: std.process.Child.Term) i32 {
    return switch (term) {
        .exited => |code| @intCast(code),
        else => 0,
    };
}

fn childPid(child: std.process.Child) ?i64 {
    if (builtin.os.tag == .windows) return null;
    const id = child.id orelse return null;
    return @intCast(id);
}

fn killSpawnedChild(
    allocator: std.mem.Allocator,
    io: std.Io,
    pid: ?i64,
    child: *std.process.Child,
    child_running: *bool,
) void {
    if (pid) |actual_pid| killProcessTree(allocator, io, actual_pid);
    child.kill(io);
    child_running.* = false;
}

fn killProcessTree(allocator: std.mem.Allocator, io: std.Io, pid: i64) void {
    if (builtin.os.tag == .windows) {
        const pid_string = std.fmt.allocPrint(allocator, "{d}", .{pid}) catch return;
        defer allocator.free(pid_string);
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "taskkill", "/F", "/T", "/PID", pid_string },
            .stdout_limit = .nothing,
            .stderr_limit = .nothing,
        }) catch return;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return;
    }

    const posix_pid = std.math.cast(std.posix.pid_t, pid) orelse return;
    std.posix.kill(-posix_pid, .KILL) catch {
        std.posix.kill(posix_pid, .KILL) catch {};
    };
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn fileError(err: anyerror, path: []const u8) types.FileError {
    return .{
        .code = switch (err) {
            error.Canceled => .aborted,
            error.FileNotFound => .not_found,
            error.AccessDenied, error.PermissionDenied => .permission_denied,
            error.NotDir => .not_directory,
            error.IsDir => .is_directory,
            error.BadPathName, error.NameTooLong, error.InvalidWtf8, error.InvalidUtf8 => .invalid,
            else => .unknown,
        },
        .message = @errorName(err),
        .path = path,
    };
}

fn abortFileResult(comptime Value: type, signal: ?*const types.AbortSignal, path: []const u8) ?Result(Value, types.FileError) {
    if (!isAborted(signal)) return null;
    return .{ .err = .{ .code = .aborted, .message = "aborted", .path = path } };
}

fn isAborted(signal: ?*const types.AbortSignal) bool {
    return if (signal) |value| value.isAborted() else false;
}

fn context(ptr: ?*anyopaque) *LocalExecutionEnv {
    return @ptrCast(@alignCast(ptr.?));
}

fn deinitFileInfoList(allocator: std.mem.Allocator, list: []types.FileInfo) void {
    for (list) |*info| info.deinit(allocator);
    allocator.free(list);
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn unwrap(comptime Value: type, result: anytype) Value {
    return switch (result) {
        .ok => |value| value,
        .err => unreachable,
    };
}

fn expectFileErrorCode(comptime code: types.FileErrorCode, result: anytype) !void {
    switch (result) {
        .ok => return error.ExpectedFileError,
        .err => |err_value| try std.testing.expectEqual(code, err_value.code),
    }
}

fn expectExecErrorCode(comptime code: types.ExecutionErrorCode, result: Result(types.ExecutionEnvExecResult, types.ExecutionError)) !void {
    switch (result) {
        .ok => return error.ExpectedExecutionError,
        .err => |err_value| try std.testing.expectEqual(code, err_value.code),
    }
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

test "agent local execution env reads writes lists and removes files and directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    const absolute = unwrap([]u8, try env_handle.absolutePath(allocator, "nested/child"));
    defer allocator.free(absolute);
    const expected_absolute = try std.fs.path.join(allocator, &.{ root, "nested/child" });
    defer allocator.free(expected_absolute);
    try std.testing.expectEqualStrings(expected_absolute, absolute);

    const joined = unwrap([]u8, try env_handle.joinPath(allocator, &.{ root, "nested", "child" }));
    defer allocator.free(joined);
    try std.testing.expectEqualStrings(expected_absolute, joined);

    _ = unwrap(void, try env_handle.createDir("nested/child", .{}));
    _ = unwrap(void, try env_handle.writeFile("nested/child/file.txt", "hel", null));
    _ = unwrap(void, try env_handle.appendFile("nested/child/file.txt", "lo", null));

    const text = unwrap([]u8, try env_handle.readTextFile(allocator, "nested/child/file.txt", null));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);

    const lines = unwrap([][]u8, try env_handle.readTextLines(allocator, "nested/child/file.txt", .{ .max_lines = 1 }));
    defer freeStringList(allocator, lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("hello", lines[0]);

    const binary = unwrap([]u8, try env_handle.readBinaryFile(allocator, "nested/child/file.txt", null));
    defer allocator.free(binary);
    try std.testing.expectEqualStrings("hello", binary);

    const entries = unwrap([]types.FileInfo, try env_handle.listDir(allocator, "nested/child", null));
    defer deinitFileInfoList(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("file.txt", entries[0].name);
    try std.testing.expectEqual(types.FileKind.file, entries[0].kind);
    try std.testing.expectEqual(@as(u64, 5), entries[0].size);

    const exists_before = unwrap(bool, try env_handle.exists("nested/child/file.txt"));
    try std.testing.expect(exists_before);
    _ = unwrap(void, try env_handle.remove("nested/child/file.txt", .{}));
    const exists_after = unwrap(bool, try env_handle.exists("nested/child/file.txt"));
    try std.testing.expect(!exists_after);
}

test "agent local execution env returns fileInfo for symlinks without following them" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    _ = unwrap(void, try env_handle.createDir("dir", .{}));
    _ = unwrap(void, try env_handle.writeFile("dir/file.txt", "hello", null));
    const target_path = try std.fs.path.join(allocator, &.{ root, "dir/file.txt" });
    defer allocator.free(target_path);
    const link_path = try std.fs.path.join(allocator, &.{ root, "file-link" });
    defer allocator.free(link_path);
    try std.Io.Dir.cwd().symLink(io, target_path, link_path, .{});

    var dir_info = unwrap(types.FileInfo, try env_handle.fileInfo(allocator, "dir"));
    defer dir_info.deinit(allocator);
    try std.testing.expectEqual(types.FileKind.directory, dir_info.kind);

    var file_info = unwrap(types.FileInfo, try env_handle.fileInfo(allocator, "dir/file.txt"));
    defer file_info.deinit(allocator);
    try std.testing.expectEqual(types.FileKind.file, file_info.kind);
    try std.testing.expectEqual(@as(u64, 5), file_info.size);

    var link_info = unwrap(types.FileInfo, try env_handle.fileInfo(allocator, "file-link"));
    defer link_info.deinit(allocator);
    try std.testing.expectEqual(types.FileKind.symlink, link_info.kind);

    const canonical = unwrap([]u8, try env_handle.canonicalPath(allocator, "file-link"));
    defer allocator.free(canonical);
    try std.testing.expect(std.mem.endsWith(u8, canonical, "dir/file.txt"));
}

test "agent local execution env stops reading text lines at the requested limit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    _ = unwrap(void, try env_handle.writeFile("file.txt", "one\ntwo\nthree", null));
    const lines = unwrap([][]u8, try env_handle.readTextLines(allocator, "file.txt", .{ .max_lines = 1 }));
    defer freeStringList(allocator, lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("one", lines[0]);
}

test "agent local execution env maps missing and non-directory file errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    try expectFileErrorCode(.not_found, try env_handle.fileInfo(allocator, "missing.txt"));
    try std.testing.expect(!unwrap(bool, try env_handle.exists("missing.txt")));

    _ = unwrap(void, try env_handle.writeFile("file.txt", "hello", null));
    try expectFileErrorCode(.not_directory, try env_handle.listDir(allocator, "file.txt", null));
}

test "agent local execution env appends to new files and creates parent directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    _ = unwrap(void, try env_handle.appendFile("new/nested/file.txt", "a", null));
    _ = unwrap(void, try env_handle.appendFile("new/nested/file.txt", "b", null));
    const text = unwrap([]u8, try env_handle.readTextFile(allocator, "new/nested/file.txt", null));
    defer allocator.free(text);
    try std.testing.expectEqualStrings("ab", text);
}

test "agent local execution env creates temporary directories and files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    const temp_dir = unwrap([]u8, try env_handle.createTempDir(allocator, .{ .prefix = "node-env-test-" }));
    defer allocator.free(temp_dir);
    try std.Io.Dir.cwd().access(io, temp_dir, .{});

    const temp_file = unwrap([]u8, try env_handle.createTempFile(allocator, .{ .prefix = "prefix-", .suffix = ".txt" }));
    defer allocator.free(temp_file);
    try std.Io.Dir.cwd().access(io, temp_file, .{});
    try std.testing.expect(std.mem.endsWith(u8, temp_file, ".txt"));
}

test "agent local execution env honors createDir recursive false and remove options" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    try expectFileErrorCode(.not_found, try env_handle.createDir("missing/child", .{ .recursive = false }));

    _ = unwrap(void, try env_handle.writeFile("dir/child/file.txt", "hello", null));
    const remove_directory = try env_handle.remove("dir", .{ .recursive = false });
    try std.testing.expect(!remove_directory.isOk());
    _ = unwrap(void, try env_handle.remove("dir", .{ .recursive = true }));
    try std.testing.expect(!unwrap(bool, try env_handle.exists("dir")));

    try expectFileErrorCode(.not_found, try env_handle.remove("missing", .{ .force = false }));
    _ = unwrap(void, try env_handle.remove("missing", .{ .force = true }));
}

test "agent local execution env returns aborted results for pre-aborted file operations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    _ = unwrap(void, try env_handle.writeFile("file.txt", "hello", null));
    const signal: types.AbortSignal = .{ .aborted = true };

    try expectFileErrorCode(.aborted, try env_handle.readTextFile(allocator, "file.txt", &signal));
    try expectFileErrorCode(.aborted, try env_handle.readTextLines(allocator, "file.txt", .{ .abort_signal = &signal }));
    try expectFileErrorCode(.aborted, try env_handle.readBinaryFile(allocator, "file.txt", &signal));
    try expectFileErrorCode(.aborted, try env_handle.writeFile("other.txt", "hello", &signal));
    try expectFileErrorCode(.aborted, try env_handle.listDir(allocator, ".", &signal));
}

test "agent local execution env cleanup is best-effort" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    try local.env().cleanup();
}

test "agent local execution env executes commands in cwd with env overrides" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    var result = unwrap(types.ExecutionEnvExecResult, try env_handle.exec("printf '%s:%s' \"$PWD\" \"$NODE_ENV_TEST\"", .{
        .env = &.{.{ .name = "NODE_ENV_TEST", .value = "ok" }},
    }));
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.endsWith(u8, result.stdout, ":ok"));
}

const StreamCollector = struct {
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,

    fn deinit(self: *StreamCollector, allocator: std.mem.Allocator) void {
        self.stdout.deinit(allocator);
        self.stderr.deinit(allocator);
    }

    fn onStdout(ptr: ?*anyopaque, chunk: []const u8) !void {
        const self: *StreamCollector = @ptrCast(@alignCast(ptr.?));
        try self.stdout.appendSlice(std.testing.allocator, chunk);
    }

    fn onStderr(ptr: ?*anyopaque, chunk: []const u8) !void {
        const self: *StreamCollector = @ptrCast(@alignCast(ptr.?));
        try self.stderr.appendSlice(std.testing.allocator, chunk);
    }
};

test "agent local execution env streams stdout and stderr chunks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    var collector: StreamCollector = .{};
    defer collector.deinit(allocator);
    var result = unwrap(types.ExecutionEnvExecResult, try env_handle.exec("printf out; printf err >&2", .{
        .on_stdout = .{ .ptr = &collector, .callback_fn = StreamCollector.onStdout },
        .on_stderr = .{ .ptr = &collector, .callback_fn = StreamCollector.onStderr },
    }));
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("out", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqualStrings("out", collector.stdout.items);
    try std.testing.expectEqualStrings("err", collector.stderr.items);
}

test "agent local execution env returns non-zero command exit codes as successful execution results" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    var result = unwrap(types.ExecutionEnvExecResult, try local.env().exec("exit 7", .{}));
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(i32, 7), result.exit_code);
}

fn failingChunk(_: ?*anyopaque, _: []const u8) !void {
    return error.CallbackFailed;
}

test "agent local execution env returns timeout and callback errors from exec" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const env_handle = local.env();

    try expectExecErrorCode(.timeout, try env_handle.exec("sleep 5", .{ .timeout_seconds = 1 }));
    const callback_result = try env_handle.exec("printf out", .{
        .on_stdout = .{ .callback_fn = failingChunk },
    });
    try expectExecErrorCode(.callback_error, callback_result);
}

test "agent local execution env returns shell unavailable and spawn errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const missing_shell = try std.fs.path.join(allocator, &.{ root, "missing-shell" });
    defer allocator.free(missing_shell);
    var missing_shell_env = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .shell_path = missing_shell, .temp_dir = root });
    defer missing_shell_env.deinit();
    try expectExecErrorCode(.shell_unavailable, try missing_shell_env.env().exec("printf ok", .{}));

    const shell_path = try std.fs.path.join(allocator, &.{ root, "not-executable-shell" });
    defer allocator.free(shell_path);
    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    _ = unwrap(void, try local.env().writeFile(shell_path, "not executable", null));

    var spawn_error_env = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .shell_path = shell_path, .temp_dir = root });
    defer spawn_error_env.deinit();
    try expectExecErrorCode(.spawn_error, try spawn_error_env.env().exec("printf ok", .{}));
}

test "agent local execution env returns an aborted result for pre-aborted commands" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();
    const signal: types.AbortSignal = .{ .aborted = true };
    try expectExecErrorCode(.aborted, try local.env().exec("sleep 5", .{ .abort_signal = &signal }));
}

test "agent local execution env captures large shell output through execution env" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    var local = try LocalExecutionEnv.initAlloc(allocator, io, .{ .cwd = root, .temp_dir = root });
    defer local.deinit();

    var capture_result = unwrap(shell_output.ShellCaptureResult, try shell_output.executeShellWithCaptureAlloc(
        allocator,
        local.env(),
        "yes line | head -n 15000",
        .{},
    ));
    defer capture_result.deinit(allocator);

    try std.testing.expect(capture_result.truncated);
    try std.testing.expect(capture_result.full_output_path != null);
    const full_output = unwrap([]u8, try local.env().readTextFile(allocator, capture_result.full_output_path.?, null));
    defer allocator.free(full_output);
    try std.testing.expect(full_output.len > capture_result.output.len);
    try std.testing.expect(std.mem.count(u8, full_output, "\n") > 10_000);
}
