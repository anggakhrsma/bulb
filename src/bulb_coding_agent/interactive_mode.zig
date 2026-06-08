const std = @import("std");
const agent_session_runtime = @import("agent_session_runtime.zig");
const config = @import("config.zig");
const session_manager_mod = @import("session_manager.zig");

pub const ImportRuntimeHost = struct {
    ptr: ?*anyopaque = null,
    import_from_jsonl_fn: *const fn (?*anyopaque, []const u8, ?[]const u8) anyerror!agent_session_runtime.SessionChangeResult,

    pub fn importFromJsonl(
        self: ImportRuntimeHost,
        input_path: []const u8,
        cwd_override: ?[]const u8,
    ) !agent_session_runtime.SessionChangeResult {
        return self.import_from_jsonl_fn(self.ptr, input_path, cwd_override);
    }
};

pub const ImportCommandUi = struct {
    ptr: ?*anyopaque = null,
    show_error_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    show_status_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    show_confirm_fn: *const fn (?*anyopaque, []const u8, []const u8) anyerror!bool,
    clear_status_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    render_current_session_state_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    prompt_missing_session_cwd_fn: ?*const fn (?*anyopaque) anyerror!?[]const u8 = null,
    handle_fatal_runtime_error_fn: ?*const fn (?*anyopaque, []const u8, anyerror) anyerror!void = null,

    fn showError(self: ImportCommandUi, message: []const u8) !void {
        try self.show_error_fn(self.ptr, message);
    }

    fn showStatus(self: ImportCommandUi, message: []const u8) !void {
        try self.show_status_fn(self.ptr, message);
    }

    fn showConfirm(self: ImportCommandUi, title: []const u8, message: []const u8) !bool {
        return self.show_confirm_fn(self.ptr, title, message);
    }

    fn clearStatus(self: ImportCommandUi) !void {
        if (self.clear_status_fn) |clear_fn| try clear_fn(self.ptr);
    }

    fn renderCurrentSessionState(self: ImportCommandUi) !void {
        if (self.render_current_session_state_fn) |render_fn| try render_fn(self.ptr);
    }

    fn promptForMissingSessionCwd(self: ImportCommandUi) !?[]const u8 {
        const prompt_fn = self.prompt_missing_session_cwd_fn orelse return null;
        return prompt_fn(self.ptr);
    }

    fn handleFatalRuntimeError(
        self: ImportCommandUi,
        allocator: std.mem.Allocator,
        prefix: []const u8,
        err: anyerror,
    ) !void {
        if (self.handle_fatal_runtime_error_fn) |fatal_fn| {
            try fatal_fn(self.ptr, prefix, err);
            return;
        }

        const message = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, @errorName(err) });
        defer allocator.free(message);
        try self.showError(message);
    }
};

pub const ImportCommandContext = struct {
    runtime_host: ImportRuntimeHost,
    ui: ImportCommandUi,
};

pub fn getPathCommandArgument(text: []const u8, command: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, text, command)) return null;
    if (!std.mem.startsWith(u8, text, command)) return null;
    if (text.len <= command.len or text[command.len] != ' ') return null;

    const args_string = trimLeftAsciiWhitespace(text[command.len + 1 ..]);
    if (args_string.len == 0) return null;

    const first_char = args_string[0];
    if (first_char == '"' or first_char == '\'') {
        const closing_quote_index = std.mem.indexOfScalarPos(u8, args_string, 1, first_char) orelse return null;
        return args_string[1..closing_quote_index];
    }

    const first_whitespace_index = firstAsciiWhitespaceIndex(args_string) orelse return args_string;
    return args_string[0..first_whitespace_index];
}

pub fn handleImportCommand(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    text: []const u8,
) !void {
    const input_path = getPathCommandArgument(text, "/import") orelse {
        try context.ui.showError("Usage: /import <path.jsonl>");
        return;
    };

    const confirm_message = try std.fmt.allocPrint(
        allocator,
        "Replace current session with {s}?",
        .{input_path},
    );
    defer allocator.free(confirm_message);

    const confirmed = try context.ui.showConfirm("Import session", confirm_message);
    if (!confirmed) {
        try context.ui.showStatus("Import cancelled");
        return;
    }

    try context.ui.clearStatus();
    const result = context.runtime_host.importFromJsonl(input_path, null) catch |err| {
        try handleImportCommandError(allocator, context, input_path, err);
        return;
    };
    try finishImportCommand(allocator, context, input_path, result);
}

fn handleImportCommandError(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    input_path: []const u8,
    err: anyerror,
) !void {
    switch (err) {
        error.MissingSessionCwd => {
            const selected_cwd = try context.ui.promptForMissingSessionCwd() orelse {
                try context.ui.showStatus("Import cancelled");
                return;
            };
            const retry_result = context.runtime_host.importFromJsonl(input_path, selected_cwd) catch |retry_err| {
                try showImportRuntimeError(allocator, context, input_path, retry_err);
                return;
            };
            try finishImportCommand(allocator, context, input_path, retry_result);
        },
        else => try showImportRuntimeError(allocator, context, input_path, err),
    }
}

fn showImportRuntimeError(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    input_path: []const u8,
    err: anyerror,
) !void {
    if (err == error.SessionImportFileNotFound) {
        const error_detail = try (agent_session_runtime.SessionImportFileNotFoundError{
            .file_path = input_path,
        }).messageAlloc(allocator);
        defer allocator.free(error_detail);
        const message = try std.fmt.allocPrint(allocator, "Failed to import session: {s}", .{error_detail});
        defer allocator.free(message);
        try context.ui.showError(message);
        return;
    }
    try context.ui.handleFatalRuntimeError(allocator, "Failed to import session", err);
}

fn finishImportCommand(
    allocator: std.mem.Allocator,
    context: ImportCommandContext,
    input_path: []const u8,
    result: agent_session_runtime.SessionChangeResult,
) !void {
    var owned_result = result;
    defer owned_result.deinit(allocator);

    if (owned_result.cancelled) {
        try context.ui.showStatus("Import cancelled");
        return;
    }

    try context.ui.renderCurrentSessionState();
    const status = try std.fmt.allocPrint(allocator, "Session imported from: {s}", .{input_path});
    defer allocator.free(status);
    try context.ui.showStatus(status);
}

fn firstAsciiWhitespaceIndex(value: []const u8) ?usize {
    for (value, 0..) |byte, index| {
        switch (byte) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => return index,
            else => {},
        }
    }
    return null;
}

fn trimLeftAsciiWhitespace(value: []const u8) []const u8 {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => {},
            else => break,
        }
    }
    return value[index..];
}

pub const FormatResumeCommandSession = struct {
    persisted: bool = true,
    session_file: ?[]const u8 = null,
    session_id: []const u8,
    session_dir: []const u8 = "",
    uses_default_session_dir: bool = true,
};

pub fn formatResumeCommandAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: FormatResumeCommandSession,
    stdout_is_tty: bool,
) !?[]u8 {
    if (!stdout_is_tty) return null;
    if (!session.persisted) return null;

    const session_file = session.session_file orelse return null;
    std.Io.Dir.cwd().access(io, session_file, .{}) catch return null;

    var command: std.Io.Writer.Allocating = .init(allocator);
    errdefer command.deinit();

    try command.writer.writeAll(config.command_name);
    if (!session.uses_default_session_dir) {
        const quoted_session_dir = try quoteIfNeededAlloc(allocator, session.session_dir);
        defer allocator.free(quoted_session_dir);
        try command.writer.print(" --session-dir {s}", .{quoted_session_dir});
    }
    try command.writer.print(" --session {s}", .{session.session_id});
    return try command.toOwnedSlice();
}

pub fn formatResumeCommandFromManagerAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_manager: *const session_manager_mod.SessionManager,
    stdout_is_tty: bool,
    agent_dir: []const u8,
) !?[]u8 {
    const uses_default_session_dir = try session_manager.usesDefaultSessionDir(allocator, io, agent_dir);
    return formatResumeCommandAlloc(allocator, io, .{
        .persisted = session_manager.isPersisted(),
        .session_file = session_manager.getSessionFile(),
        .session_id = session_manager.getSessionId(),
        .session_dir = session_manager.getSessionDir(),
        .uses_default_session_dir = uses_default_session_dir,
    }, stdout_is_tty);
}

fn quoteIfNeededAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len > 0 and isShellSafeUnquoted(value)) {
        return allocator.dupe(u8, value);
    }

    var quoted: std.ArrayList(u8) = .empty;
    errdefer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try quoted.appendSlice(allocator, "'\\''");
        } else {
            try quoted.append(allocator, byte);
        }
    }
    try quoted.append(allocator, '\'');
    return quoted.toOwnedSlice(allocator);
}

fn isShellSafeUnquoted(value: []const u8) bool {
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '_', '-', '.', '/', '~', ':', '@' => continue,
            else => return false,
        }
    }
    return true;
}

const TempSessionFile = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    path: []u8,

    fn deinit(self: *TempSessionFile) void {
        self.allocator.free(self.path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn tempDirPathAlloc(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
}

fn createTempSessionFile(allocator: std.mem.Allocator) !TempSessionFile {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const tmp_path = try tempDirPathAlloc(allocator, &tmp);
    defer allocator.free(tmp_path);
    const session_file = try std.fs.path.join(allocator, &.{ tmp_path, "session.jsonl" });
    errdefer allocator.free(session_file);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = session_file,
        .data = "\n",
        .flags = .{ .read = true, .truncate = true },
    });
    return .{
        .allocator = allocator,
        .tmp = tmp,
        .path = session_file,
    };
}

fn expectResumeCommand(session: FormatResumeCommandSession, stdout_is_tty: bool, expected: ?[]const u8) !void {
    const actual = try formatResumeCommandAlloc(std.testing.allocator, std.testing.io, session, stdout_is_tty);
    defer if (actual) |value| std.testing.allocator.free(value);

    if (expected) |expected_value| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(expected_value, actual.?);
    } else {
        try std.testing.expectEqual(null, actual);
    }
}

// Ported from packages/coding-agent/test/format-resume-command.test.ts.
test "formatResumeCommand returns session resume command for default session dirs" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
    }, true, "bulb --session test-session");
}

test "formatResumeCommand includes and quotes non-default session dirs" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom-bulb-sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir /tmp/custom-bulb-sessions --session test-session");

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom bulb sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir '/tmp/custom bulb sessions' --session test-session");

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
        .session_dir = "/tmp/custom bulb's sessions",
        .uses_default_session_dir = false,
    }, true, "bulb --session-dir '/tmp/custom bulb'\\''s sessions' --session test-session");
}

test "formatResumeCommand returns null for non-TTY in-memory and missing session files" {
    var session_file = try createTempSessionFile(std.testing.allocator);
    defer session_file.deinit();

    try expectResumeCommand(.{
        .session_file = session_file.path,
        .session_id = "test-session",
    }, false, null);

    try expectResumeCommand(.{
        .persisted = false,
        .session_file = session_file.path,
        .session_id = "test-session",
    }, true, null);

    try expectResumeCommand(.{
        .session_file = "/tmp/bulb-missing-session.jsonl",
        .session_id = "test-session",
    }, true, null);

    try expectResumeCommand(.{
        .session_file = null,
        .session_id = "test-session",
    }, true, null);
}

const TestImportUi = struct {
    allocator: std.mem.Allocator,
    confirm_result: bool = true,
    prompt_cwd: ?[]const u8 = null,
    errors: std.ArrayList([]u8) = .empty,
    statuses: std.ArrayList([]u8) = .empty,
    confirm_titles: std.ArrayList([]u8) = .empty,
    confirm_messages: std.ArrayList([]u8) = .empty,
    clear_count: usize = 0,
    render_count: usize = 0,
    fatal_count: usize = 0,

    fn init(allocator: std.mem.Allocator) TestImportUi {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestImportUi) void {
        freeMessageList(self.allocator, &self.errors);
        freeMessageList(self.allocator, &self.statuses);
        freeMessageList(self.allocator, &self.confirm_titles);
        freeMessageList(self.allocator, &self.confirm_messages);
        self.* = undefined;
    }

    fn callbacks(self: *TestImportUi) ImportCommandUi {
        return .{
            .ptr = self,
            .show_error_fn = showError,
            .show_status_fn = showStatus,
            .show_confirm_fn = showConfirm,
            .clear_status_fn = clearStatus,
            .render_current_session_state_fn = renderCurrentSessionState,
            .prompt_missing_session_cwd_fn = promptForMissingSessionCwd,
            .handle_fatal_runtime_error_fn = handleFatalRuntimeError,
        };
    }

    fn appendMessage(self: *TestImportUi, list: *std.ArrayList([]u8), message: []const u8) !void {
        const copy = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(copy);
        try list.append(self.allocator, copy);
    }

    fn showError(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.errors, message);
    }

    fn showStatus(ptr: ?*anyopaque, message: []const u8) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.statuses, message);
    }

    fn showConfirm(ptr: ?*anyopaque, title: []const u8, message: []const u8) !bool {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        try self.appendMessage(&self.confirm_titles, title);
        try self.appendMessage(&self.confirm_messages, message);
        return self.confirm_result;
    }

    fn clearStatus(ptr: ?*anyopaque) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        self.clear_count += 1;
    }

    fn renderCurrentSessionState(ptr: ?*anyopaque) !void {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        self.render_count += 1;
    }

    fn promptForMissingSessionCwd(ptr: ?*anyopaque) !?[]const u8 {
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        return self.prompt_cwd;
    }

    fn handleFatalRuntimeError(ptr: ?*anyopaque, prefix: []const u8, err: anyerror) !void {
        _ = prefix;
        _ = @errorName(err);
        const self: *TestImportUi = @ptrCast(@alignCast(ptr.?));
        self.fatal_count += 1;
    }
};

fn freeMessageList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |message| allocator.free(message);
    list.deinit(allocator);
}

const ImportRuntimeScenario = enum {
    success,
    cancelled,
    missing_file,
    missing_cwd_once,
};

const ImportCall = struct {
    input_path: []u8,
    cwd_override: ?[]u8,
};

const TestImportRuntimeHost = struct {
    allocator: std.mem.Allocator,
    scenario: ImportRuntimeScenario,
    calls: std.ArrayList(ImportCall) = .empty,

    fn init(allocator: std.mem.Allocator, scenario: ImportRuntimeScenario) TestImportRuntimeHost {
        return .{
            .allocator = allocator,
            .scenario = scenario,
        };
    }

    fn deinit(self: *TestImportRuntimeHost) void {
        for (self.calls.items) |call| {
            self.allocator.free(call.input_path);
            if (call.cwd_override) |cwd_override| self.allocator.free(cwd_override);
        }
        self.calls.deinit(self.allocator);
        self.* = undefined;
    }

    fn callbacks(self: *TestImportRuntimeHost) ImportRuntimeHost {
        return .{
            .ptr = self,
            .import_from_jsonl_fn = importFromJsonl,
        };
    }

    fn importFromJsonl(
        ptr: ?*anyopaque,
        input_path: []const u8,
        cwd_override: ?[]const u8,
    ) !agent_session_runtime.SessionChangeResult {
        const self: *TestImportRuntimeHost = @ptrCast(@alignCast(ptr.?));
        const input_copy = try self.allocator.dupe(u8, input_path);
        var keep_call = false;
        errdefer if (!keep_call) self.allocator.free(input_copy);
        const cwd_copy = if (cwd_override) |cwd| try self.allocator.dupe(u8, cwd) else null;
        errdefer if (!keep_call) {
            if (cwd_copy) |cwd| self.allocator.free(cwd);
        };
        try self.calls.append(self.allocator, .{
            .input_path = input_copy,
            .cwd_override = cwd_copy,
        });
        keep_call = true;

        switch (self.scenario) {
            .success => return .{},
            .cancelled => return .{ .cancelled = true },
            .missing_file => return error.SessionImportFileNotFound,
            .missing_cwd_once => {
                if (self.calls.items.len == 1) return error.MissingSessionCwd;
                return .{};
            },
        }
    }
};

// Ported from packages/coding-agent/test/interactive-mode-import-command.test.ts.
test "InteractiveMode /import parsing strips quotes from path arguments" {
    try std.testing.expectEqualStrings(
        "path/to/session.jsonl",
        getPathCommandArgument("/import \"path/to/session.jsonl\"", "/import").?,
    );
    try std.testing.expectEqualStrings(
        "path with spaces/session.jsonl",
        getPathCommandArgument("/import \"path with spaces/session.jsonl\"", "/import").?,
    );
}

test "InteractiveMode /import parsing preserves apostrophes in unquoted path arguments" {
    try std.testing.expectEqualStrings(
        "john's/session.jsonl",
        getPathCommandArgument("/import john's/session.jsonl", "/import").?,
    );
}

test "InteractiveMode path command parsing enforces command token boundaries" {
    try std.testing.expect(getPathCommandArgument("/important /tmp/session.jsonl", "/import") == null);
    try std.testing.expect(getPathCommandArgument("/exporter out.html", "/export") == null);
    try std.testing.expectEqualStrings(
        "/tmp/session.jsonl",
        getPathCommandArgument("/import /tmp/session.jsonl", "/import").?,
    );
}

test "InteractiveMode handleImportCommand passes unquoted path to runtime host" {
    const allocator = std.testing.allocator;
    var ui = TestImportUi.init(allocator);
    defer ui.deinit();
    var runtime = TestImportRuntimeHost.init(allocator, .success);
    defer runtime.deinit();

    try handleImportCommand(allocator, .{
        .runtime_host = runtime.callbacks(),
        .ui = ui.callbacks(),
    }, "/import \"path/to/session.jsonl\"");

    try std.testing.expectEqual(@as(usize, 1), ui.confirm_titles.items.len);
    try std.testing.expectEqualStrings("Import session", ui.confirm_titles.items[0]);
    try std.testing.expectEqualStrings("Replace current session with path/to/session.jsonl?", ui.confirm_messages.items[0]);
    try std.testing.expectEqual(@as(usize, 1), runtime.calls.items.len);
    try std.testing.expectEqualStrings("path/to/session.jsonl", runtime.calls.items[0].input_path);
    try std.testing.expect(runtime.calls.items[0].cwd_override == null);
    try std.testing.expectEqual(@as(usize, 0), ui.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), ui.statuses.items.len);
    try std.testing.expectEqualStrings("Session imported from: path/to/session.jsonl", ui.statuses.items[0]);
    try std.testing.expectEqual(@as(usize, 1), ui.clear_count);
    try std.testing.expectEqual(@as(usize, 1), ui.render_count);
}

test "InteractiveMode handleImportCommand preserves unquoted apostrophe paths" {
    const allocator = std.testing.allocator;
    var ui = TestImportUi.init(allocator);
    defer ui.deinit();
    var runtime = TestImportRuntimeHost.init(allocator, .success);
    defer runtime.deinit();

    try handleImportCommand(allocator, .{
        .runtime_host = runtime.callbacks(),
        .ui = ui.callbacks(),
    }, "/import john's/session.jsonl");

    try std.testing.expectEqual(@as(usize, 1), runtime.calls.items.len);
    try std.testing.expectEqualStrings("john's/session.jsonl", runtime.calls.items[0].input_path);
    try std.testing.expectEqual(@as(usize, 0), ui.errors.items.len);
    try std.testing.expectEqualStrings("Session imported from: john's/session.jsonl", ui.statuses.items[0]);
}

test "InteractiveMode handleImportCommand shows non-fatal error for missing import path" {
    const allocator = std.testing.allocator;
    var ui = TestImportUi.init(allocator);
    defer ui.deinit();
    var runtime = TestImportRuntimeHost.init(allocator, .missing_file);
    defer runtime.deinit();

    try handleImportCommand(allocator, .{
        .runtime_host = runtime.callbacks(),
        .ui = ui.callbacks(),
    }, "/import /tmp/missing-session.jsonl");

    try std.testing.expectEqual(@as(usize, 1), runtime.calls.items.len);
    try std.testing.expectEqualStrings("/tmp/missing-session.jsonl", runtime.calls.items[0].input_path);
    try std.testing.expectEqual(@as(usize, 1), ui.errors.items.len);
    try std.testing.expectEqualStrings(
        "Failed to import session: File not found: /tmp/missing-session.jsonl",
        ui.errors.items[0],
    );
    try std.testing.expectEqual(@as(usize, 0), ui.statuses.items.len);
    try std.testing.expectEqual(@as(usize, 0), ui.fatal_count);
}
