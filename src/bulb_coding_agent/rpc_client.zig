const std = @import("std");
const builtin = @import("builtin");

const rpc_jsonl = @import("rpc_jsonl.zig");

pub const default_cli_path = "bulb";
const stdout_buffer_bytes = 64 * 1024;
const max_rpc_jsonl_line_bytes = 16 * 1024 * 1024;

pub const RpcClientError = error{
    ClientAlreadyStarted,
    ClientNotStarted,
    AgentProcessExited,
    InvalidResponse,
    RpcResponseError,
    RpcLineTooLong,
    RpcReadFailed,
};

pub const RpcClientOptions = struct {
    cli_path: []const u8 = default_cli_path,
    cwd: ?[]const u8 = null,
    environ_map: ?*const std.process.Environ.Map = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    io: ?std.Io = null,
};

pub const CloneResult = struct {
    cancelled: bool,
};

pub const RpcEventListener = struct {
    ptr: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.json.Value) anyerror!void,

    pub fn call(self: RpcEventListener, event: std.json.Value) !void {
        try self.call_fn(self.ptr, event);
    }
};

pub const RpcClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RpcClientOptions,
    process: ?std.process.Child = null,
    stdout_reader: ?std.Io.File.Reader = null,
    stdout_buffer: []u8 = &.{},
    request_id: u64 = 0,
    last_error: ?[]u8 = null,
    event_listeners: std.ArrayList(RpcEventListener) = .empty,

    pub fn init(allocator: std.mem.Allocator, options: RpcClientOptions) RpcClient {
        return .{
            .allocator = allocator,
            .io = options.io orelse std.Io.Threaded.global_single_threaded.io(),
            .options = options,
        };
    }

    pub fn deinit(self: *RpcClient) void {
        self.stop() catch {};
        self.clearLastError();
        self.event_listeners.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn start(self: *RpcClient) !void {
        if (self.process != null) return error.ClientAlreadyStarted;
        self.clearLastError();

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        try argv.append(self.allocator, self.options.cli_path);
        try argv.append(self.allocator, "--mode");
        try argv.append(self.allocator, "rpc");
        if (self.options.provider) |provider| {
            try argv.append(self.allocator, "--provider");
            try argv.append(self.allocator, provider);
        }
        if (self.options.model) |model| {
            try argv.append(self.allocator, "--model");
            try argv.append(self.allocator, model);
        }
        for (self.options.args) |arg| try argv.append(self.allocator, arg);

        const cwd: std.process.Child.Cwd = if (self.options.cwd) |path| .{ .path = path } else .inherit;
        var child = std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = cwd,
            .environ_map = self.options.environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        }) catch |err| {
            try self.setLastErrorAlloc("Agent process error: {s}. Stderr: ", .{@errorName(err)});
            return err;
        };
        errdefer child.kill(self.io);

        const stdout_file = child.stdout orelse return error.InvalidResponse;
        const buffer = try self.allocator.alloc(u8, stdout_buffer_bytes);
        errdefer self.allocator.free(buffer);

        self.process = child;
        self.stdout_buffer = buffer;
        self.stdout_reader = stdout_file.readerStreaming(self.io, self.stdout_buffer);
    }

    pub fn stop(self: *RpcClient) !void {
        if (self.process) |*child| {
            child.kill(self.io);
            self.process = null;
        }
        self.releaseStdoutReader();
    }

    pub fn addEventListener(self: *RpcClient, listener: RpcEventListener) !void {
        try self.event_listeners.append(self.allocator, listener);
    }

    pub fn clearEventListeners(self: *RpcClient) void {
        self.event_listeners.clearRetainingCapacity();
    }

    pub fn getLastError(self: RpcClient) ?[]const u8 {
        return self.last_error;
    }

    pub fn getStderr(_: RpcClient) []const u8 {
        return "";
    }

    pub fn clone(self: *RpcClient) !CloneResult {
        var response = try self.sendSimpleCommandAlloc(self.allocator, "clone");
        defer response.deinit();

        const data = requiredObjectField(response.value, "data") orelse return error.InvalidResponse;
        const cancelled = optionalBool(data, "cancelled") orelse return error.InvalidResponse;
        return .{ .cancelled = cancelled };
    }

    pub fn getCommandsAlloc(self: *RpcClient, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        return self.sendSimpleCommandAlloc(allocator, "get_commands");
    }

    fn sendSimpleCommandAlloc(
        self: *RpcClient,
        allocator: std.mem.Allocator,
        command_type: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        const id = try self.nextRequestIdAlloc(allocator);
        defer allocator.free(id);

        const line = try rpc_jsonl.serializeJsonLineAlloc(allocator, .{ .id = id, .type = command_type });
        defer allocator.free(line);

        try self.writeCommandLine(line);
        return self.waitForResponseAlloc(allocator, id, command_type);
    }

    fn writeCommandLine(self: *RpcClient, line: []const u8) !void {
        if (self.process) |*child| {
            const stdin = child.stdin orelse return error.ClientNotStarted;
            stdin.writeStreamingAll(self.io, line) catch |err| {
                try self.setLastErrorAlloc("Agent process stdin error: {s}. Stderr: ", .{@errorName(err)});
                return err;
            };
            return;
        }
        return error.ClientNotStarted;
    }

    fn waitForResponseAlloc(
        self: *RpcClient,
        allocator: std.mem.Allocator,
        id: []const u8,
        command_type: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        while (true) {
            const raw_line = self.readJsonLineAlloc(allocator) catch |err| switch (err) {
                error.EndOfStream => {
                    try self.finishExitedProcess();
                    return error.AgentProcessExited;
                },
                else => |read_err| return read_err,
            };
            defer allocator.free(raw_line);
            const line = trimTrailingCarriageReturn(raw_line);

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };

            if (isMatchingResponse(parsed.value, id)) {
                try self.validateResponse(parsed.value, command_type);
                return parsed;
            }

            self.dispatchEvent(parsed.value);
            parsed.deinit();
        }
    }

    fn readJsonLineAlloc(self: *RpcClient, allocator: std.mem.Allocator) ![]u8 {
        if (self.stdout_reader) |*reader| {
            var line_writer: std.Io.Writer.Allocating = .init(allocator);
            errdefer line_writer.deinit();

            _ = reader.interface.streamDelimiterLimit(
                &line_writer.writer,
                '\n',
                .limited(max_rpc_jsonl_line_bytes),
            ) catch |err| switch (err) {
                error.ReadFailed => return error.RpcReadFailed,
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => return error.RpcLineTooLong,
            };

            const buffered = reader.interface.buffered();
            if (buffered.len > 0 and buffered[0] == '\n') {
                reader.interface.toss(1);
            } else if (line_writer.written().len == 0) {
                line_writer.deinit();
                return error.EndOfStream;
            }

            return line_writer.toOwnedSlice();
        }
        return error.ClientNotStarted;
    }

    fn validateResponse(self: *RpcClient, response: std.json.Value, command_type: []const u8) !void {
        const object = if (response == .object) response.object else return error.InvalidResponse;
        const success = optionalBool(object, "success") orelse return error.InvalidResponse;
        if (success) return;

        const message = optionalString(object, "error") orelse "RPC command failed";
        try self.setLastErrorAlloc("RPC command {s} failed: {s}", .{ command_type, message });
        return error.RpcResponseError;
    }

    fn dispatchEvent(self: *RpcClient, event: std.json.Value) void {
        for (self.event_listeners.items) |listener| {
            listener.call(event) catch {};
        }
    }

    fn finishExitedProcess(self: *RpcClient) !void {
        if (self.process) |*child| {
            const term = try child.wait(self.io);
            self.process = null;
            self.releaseStdoutReader();
            try self.setProcessExitError(term);
            return;
        }
        try self.setLastErrorAlloc("Agent process exited. Stderr: ", .{});
    }

    fn setProcessExitError(self: *RpcClient, term: std.process.Child.Term) !void {
        switch (term) {
            .exited => |code| try self.setLastErrorAlloc(
                "Agent process exited (code={d} signal=null). Stderr: {s}",
                .{ code, self.getStderr() },
            ),
            .signal => |signal| try self.setLastErrorAlloc(
                "Agent process exited (code=null signal={s}). Stderr: {s}",
                .{ @tagName(signal), self.getStderr() },
            ),
            .stopped => |signal| try self.setLastErrorAlloc(
                "Agent process exited (code=null signal=stopped:{s}). Stderr: {s}",
                .{ @tagName(signal), self.getStderr() },
            ),
            .unknown => |code| try self.setLastErrorAlloc(
                "Agent process exited (code=unknown:{d} signal=null). Stderr: {s}",
                .{ code, self.getStderr() },
            ),
        }
    }

    fn nextRequestIdAlloc(self: *RpcClient, allocator: std.mem.Allocator) ![]u8 {
        self.request_id += 1;
        return std.fmt.allocPrint(allocator, "{d}", .{self.request_id});
    }

    fn clearLastError(self: *RpcClient) void {
        if (self.last_error) |message| self.allocator.free(message);
        self.last_error = null;
    }

    fn setLastErrorAlloc(self: *RpcClient, comptime format: []const u8, args: anytype) !void {
        self.clearLastError();
        self.last_error = try std.fmt.allocPrint(self.allocator, format, args);
    }

    fn releaseStdoutReader(self: *RpcClient) void {
        self.stdout_reader = null;
        if (self.stdout_buffer.len > 0) {
            self.allocator.free(self.stdout_buffer);
            self.stdout_buffer = &.{};
        }
    }
};

fn isMatchingResponse(value: std.json.Value, id: []const u8) bool {
    if (value != .object) return false;
    const object = value.object;
    const response_type = optionalString(object, "type") orelse return false;
    if (!std.mem.eql(u8, response_type, "response")) return false;
    const response_id = optionalString(object, "id") orelse return false;
    return std.mem.eql(u8, response_id, id);
}

fn requiredObjectField(value: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (value != .object) return null;
    const nested = value.object.get(key) orelse return null;
    return if (nested == .object) nested.object else null;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn trimTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn writeExecutableScriptAlloc(
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    contents: []const u8,
) ![]u8 {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const path = try std.fs.path.join(allocator, &.{ root, name });
    errdefer allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{
        .read = true,
        .truncate = true,
        .permissions = @enumFromInt(0o755),
    });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, contents);
    try file.setPermissions(std.testing.io, @enumFromInt(0o755));
    return path;
}

test "RpcClient clone sends clone command and returns cancellation state" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const script = try writeExecutableScriptAlloc(allocator, root, "clone-rpc.sh",
        \\#!/bin/sh
        \\IFS= read -r line || exit 1
        \\id=$(printf "%s\n" "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        \\type=$(printf "%s\n" "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
        \\if [ "$type" = "clone" ]; then
        \\  printf '{"id":"%s","type":"response","command":"clone","success":true,"data":{"cancelled":false}}\n' "$id"
        \\else
        \\  printf '{"id":"%s","type":"response","command":"%s","success":false,"error":"unexpected command"}\n' "$id" "$type"
        \\fi
    );
    defer allocator.free(script);

    var client = RpcClient.init(allocator, .{ .cli_path = script, .io = std.testing.io });
    defer client.deinit();
    try client.start();

    const result = try client.clone();
    try std.testing.expectEqual(false, result.cancelled);
}

test "RpcClient rejects an in-flight request when the child exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(root);

    const script = try writeExecutableScriptAlloc(allocator, root, "exit-rpc.sh",
        \\#!/bin/sh
        \\IFS= read -r _line || exit 1
        \\exit 43
    );
    defer allocator.free(script);

    var client = RpcClient.init(allocator, .{ .cli_path = script, .io = std.testing.io });
    defer client.deinit();
    try client.start();

    try std.testing.expectError(error.AgentProcessExited, client.getCommandsAlloc(allocator));
    try std.testing.expect(client.getLastError() != null);
    try std.testing.expect(std.mem.indexOf(u8, client.getLastError().?, "Agent process exited (code=43 signal=null)") != null);
}
