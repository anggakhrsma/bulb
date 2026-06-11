const std = @import("std");
const ai = @import("bulb_ai");

pub const PromptTemplate = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    description: []u8,
    content: []u8,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        name: []const u8,
        description: []const u8,
        content: []const u8,
    ) !PromptTemplate {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_description = try allocator.dupe(u8, description);
        errdefer allocator.free(owned_description);
        const owned_content = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_content);
        return .{
            .allocator = allocator,
            .name = owned_name,
            .description = owned_description,
            .content = owned_content,
        };
    }

    pub fn deinit(self: *PromptTemplate) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

pub const Skill = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    description: []u8,
    content: []u8,
    file_path: []u8,
    disable_model_invocation: bool = false,

    pub fn initAlloc(
        allocator: std.mem.Allocator,
        name: []const u8,
        description: []const u8,
        content: []const u8,
        file_path: []const u8,
        disable_model_invocation: bool,
    ) !Skill {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_description = try allocator.dupe(u8, description);
        errdefer allocator.free(owned_description);
        const owned_content = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_content);
        const owned_file_path = try allocator.dupe(u8, file_path);
        errdefer allocator.free(owned_file_path);
        return .{
            .allocator = allocator,
            .name = owned_name,
            .description = owned_description,
            .content = owned_content,
            .file_path = owned_file_path,
            .disable_model_invocation = disable_model_invocation,
        };
    }

    pub fn deinit(self: *Skill) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.free(self.content);
        self.allocator.free(self.file_path);
        self.* = undefined;
    }
};

pub const PromptTemplateDiagnosticCode = enum {
    file_info_failed,
    list_failed,
    read_failed,
    parse_failed,
};

pub const SkillDiagnosticCode = enum {
    file_info_failed,
    list_failed,
    read_failed,
    parse_failed,
    invalid_metadata,
};

pub fn Result(comptime Value: type, comptime Failure: type) type {
    return union(enum) {
        ok: Value,
        err: Failure,

        pub fn isOk(self: @This()) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }
    };
}

pub const FileKind = enum {
    file,
    directory,
    symlink,
};

pub const FileErrorCode = enum {
    aborted,
    not_found,
    permission_denied,
    not_directory,
    is_directory,
    invalid,
    not_supported,
    unknown,
};

pub const FileError = struct {
    code: FileErrorCode,
    message: []const u8,
    path: ?[]const u8 = null,
};

pub const ExecutionErrorCode = enum {
    aborted,
    timeout,
    shell_unavailable,
    spawn_error,
    callback_error,
    unknown,
};

pub const ExecutionError = struct {
    code: ExecutionErrorCode,
    message: []const u8,
};

pub const FileInfo = struct {
    name: []const u8,
    path: []const u8,
    kind: FileKind,
    size: u64,
    mtime_ms: i64,

    pub fn deinit(self: *FileInfo, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.name));
        allocator.free(@constCast(self.path));
        self.* = undefined;
    }
};

pub const AbortSignal = struct {
    aborted: bool = false,

    pub fn isAborted(self: *const AbortSignal) bool {
        return self.aborted;
    }
};

pub const ExecutionChunkCallback = struct {
    ptr: ?*anyopaque = null,
    callback_fn: *const fn (?*anyopaque, []const u8) anyerror!void = noopChunkCallback,

    pub fn call(self: ExecutionChunkCallback, chunk: []const u8) !void {
        try self.callback_fn(self.ptr, chunk);
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const ExecutionEnvExecOptions = struct {
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    timeout_seconds: ?u64 = null,
    abort_signal: ?*const AbortSignal = null,
    on_stdout: ?ExecutionChunkCallback = null,
    on_stderr: ?ExecutionChunkCallback = null,
};

pub const ExecutionEnvExecResult = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    exit_code: i32,
    owns_output: bool = false,

    pub fn deinit(self: *ExecutionEnvExecResult, allocator: std.mem.Allocator) void {
        if (self.owns_output) {
            allocator.free(@constCast(self.stdout));
            allocator.free(@constCast(self.stderr));
        }
        self.* = undefined;
    }
};

pub const ReadTextLinesOptions = struct {
    max_lines: ?usize = null,
    abort_signal: ?*const AbortSignal = null,
};

pub const CreateDirOptions = struct {
    recursive: bool = true,
    abort_signal: ?*const AbortSignal = null,
};

pub const RemoveOptions = struct {
    recursive: bool = false,
    force: bool = false,
    abort_signal: ?*const AbortSignal = null,
};

pub const CreateTempFileOptions = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    abort_signal: ?*const AbortSignal = null,
};

pub const CreateTempDirOptions = struct {
    prefix: []const u8 = "tmp-",
    abort_signal: ?*const AbortSignal = null,
};

pub const ExecutionEnv = struct {
    ptr: ?*anyopaque = null,
    cwd: []const u8,
    absolute_path_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!Result([]u8, FileError) = defaultAbsolutePath,
    join_path_fn: *const fn (?*anyopaque, std.mem.Allocator, []const []const u8) anyerror!Result([]u8, FileError) = defaultJoinPath,
    exec_fn: *const fn (?*anyopaque, []const u8, ExecutionEnvExecOptions) anyerror!Result(ExecutionEnvExecResult, ExecutionError) = defaultExec,
    read_text_file_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, ?*const AbortSignal) anyerror!Result([]u8, FileError) = defaultReadTextFile,
    read_text_lines_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, ReadTextLinesOptions) anyerror!Result([][]u8, FileError) = defaultReadTextLines,
    read_binary_file_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, ?*const AbortSignal) anyerror!Result([]u8, FileError) = defaultReadBinaryFile,
    write_file_fn: *const fn (?*anyopaque, []const u8, []const u8, ?*const AbortSignal) anyerror!Result(void, FileError) = defaultWriteFile,
    append_file_fn: *const fn (?*anyopaque, []const u8, []const u8, ?*const AbortSignal) anyerror!Result(void, FileError) = defaultAppendFile,
    file_info_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!Result(FileInfo, FileError) = defaultFileInfo,
    list_dir_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, ?*const AbortSignal) anyerror!Result([]FileInfo, FileError) = defaultListDir,
    canonical_path_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!Result([]u8, FileError) = defaultCanonicalPath,
    exists_fn: *const fn (?*anyopaque, []const u8) anyerror!Result(bool, FileError) = defaultExists,
    create_dir_fn: *const fn (?*anyopaque, []const u8, CreateDirOptions) anyerror!Result(void, FileError) = defaultCreateDir,
    remove_fn: *const fn (?*anyopaque, []const u8, RemoveOptions) anyerror!Result(void, FileError) = defaultRemove,
    create_temp_dir_fn: *const fn (?*anyopaque, std.mem.Allocator, CreateTempDirOptions) anyerror!Result([]u8, FileError) = defaultCreateTempDir,
    create_temp_file_fn: *const fn (?*anyopaque, std.mem.Allocator, CreateTempFileOptions) anyerror!Result([]u8, FileError) = defaultCreateTempFile,
    cleanup_fn: *const fn (?*anyopaque) anyerror!void = defaultCleanup,

    pub fn absolutePath(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !Result([]u8, FileError) {
        return try self.absolute_path_fn(self.ptr, allocator, path);
    }

    pub fn joinPath(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        parts: []const []const u8,
    ) !Result([]u8, FileError) {
        return try self.join_path_fn(self.ptr, allocator, parts);
    }

    pub fn exec(
        self: ExecutionEnv,
        command: []const u8,
        options: ExecutionEnvExecOptions,
    ) !Result(ExecutionEnvExecResult, ExecutionError) {
        return try self.exec_fn(self.ptr, command, options);
    }

    pub fn readTextFile(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        path: []const u8,
        abort_signal: ?*const AbortSignal,
    ) !Result([]u8, FileError) {
        return try self.read_text_file_fn(self.ptr, allocator, path, abort_signal);
    }

    pub fn readTextLines(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        path: []const u8,
        options: ReadTextLinesOptions,
    ) !Result([][]u8, FileError) {
        return try self.read_text_lines_fn(self.ptr, allocator, path, options);
    }

    pub fn readBinaryFile(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        path: []const u8,
        abort_signal: ?*const AbortSignal,
    ) !Result([]u8, FileError) {
        return try self.read_binary_file_fn(self.ptr, allocator, path, abort_signal);
    }

    pub fn writeFile(
        self: ExecutionEnv,
        path: []const u8,
        content: []const u8,
        abort_signal: ?*const AbortSignal,
    ) !Result(void, FileError) {
        return try self.write_file_fn(self.ptr, path, content, abort_signal);
    }

    pub fn appendFile(
        self: ExecutionEnv,
        path: []const u8,
        content: []const u8,
        abort_signal: ?*const AbortSignal,
    ) !Result(void, FileError) {
        return try self.append_file_fn(self.ptr, path, content, abort_signal);
    }

    pub fn fileInfo(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !Result(FileInfo, FileError) {
        return try self.file_info_fn(self.ptr, allocator, path);
    }

    pub fn listDir(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        path: []const u8,
        abort_signal: ?*const AbortSignal,
    ) !Result([]FileInfo, FileError) {
        return try self.list_dir_fn(self.ptr, allocator, path, abort_signal);
    }

    pub fn canonicalPath(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !Result([]u8, FileError) {
        return try self.canonical_path_fn(self.ptr, allocator, path);
    }

    pub fn exists(self: ExecutionEnv, path: []const u8) !Result(bool, FileError) {
        return try self.exists_fn(self.ptr, path);
    }

    pub fn createDir(
        self: ExecutionEnv,
        path: []const u8,
        options: CreateDirOptions,
    ) !Result(void, FileError) {
        return try self.create_dir_fn(self.ptr, path, options);
    }

    pub fn remove(
        self: ExecutionEnv,
        path: []const u8,
        options: RemoveOptions,
    ) !Result(void, FileError) {
        return try self.remove_fn(self.ptr, path, options);
    }

    pub fn createTempDir(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        options: CreateTempDirOptions,
    ) !Result([]u8, FileError) {
        return try self.create_temp_dir_fn(self.ptr, allocator, options);
    }

    pub fn createTempFile(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        options: CreateTempFileOptions,
    ) !Result([]u8, FileError) {
        return try self.create_temp_file_fn(self.ptr, allocator, options);
    }

    pub fn cleanup(self: ExecutionEnv) !void {
        try self.cleanup_fn(self.ptr);
    }
};

pub const SessionErrorCode = enum {
    not_found,
    invalid_session,
    invalid_entry,
    invalid_fork_target,
    storage,
    unknown,
};

pub const SessionError = struct {
    code: SessionErrorCode,
    message: []const u8,
};

pub const AgentHarnessErrorCode = enum {
    busy,
    invalid_state,
    invalid_argument,
    session,
    hook,
    auth,
    compaction,
    branch_summary,
    unknown,
};

pub const AgentHarnessError = struct {
    code: AgentHarnessErrorCode,
    message: []const u8,
};

pub const CompactionErrorCode = enum {
    aborted,
    summarization_failed,
    invalid_session,
    unknown,
};

pub const CompactionError = struct {
    code: CompactionErrorCode,
    message: []const u8,
};

pub const BranchSummaryErrorCode = enum {
    aborted,
    summarization_failed,
    invalid_session,
};

pub const BranchSummaryError = struct {
    code: BranchSummaryErrorCode,
    message: []const u8,
};

pub const BashExecutionMessage = struct {
    command: []const u8,
    output: []const u8,
    exit_code: ?i64 = null,
    cancelled: bool = false,
    truncated: bool = false,
    full_output_path: ?[]const u8 = null,
    timestamp_ms: i64,
    exclude_from_context: bool = false,
};

pub const CustomMessageContent = union(enum) {
    text: []const u8,
    parts: []const ai.UserContent,
};

pub const CustomMessage = struct {
    custom_type: []const u8,
    content: CustomMessageContent,
    display: bool,
    details_json: ?[]const u8 = null,
    timestamp_ms: i64,
};

pub const BranchSummaryMessage = struct {
    summary: []const u8,
    from_id: []const u8,
    timestamp_ms: i64,
};

pub const CompactionSummaryMessage = struct {
    summary: []const u8,
    tokens_before: u64,
    timestamp_ms: i64,
};

pub const AgentMessage = union(enum) {
    user: ai.UserMessage,
    assistant: ai.AssistantMessage,
    tool_result: ai.ToolResultMessage,
    bash_execution: BashExecutionMessage,
    custom: CustomMessage,
    branch_summary: BranchSummaryMessage,
    compaction_summary: CompactionSummaryMessage,
};

pub const SessionEntryKind = enum {
    message,
    thinking_level_change,
    model_change,
    active_tools_change,
    compaction,
    branch_summary,
    custom,
    custom_message,
    label,
    session_info,
    leaf,
    unknown,
};

pub const SessionTreeEntry = struct {
    kind: SessionEntryKind,
    type_name: []const u8,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,

    message_json: ?[]const u8 = null,
    thinking_level: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    active_tool_names: []const []const u8 = &.{},

    summary: ?[]const u8 = null,
    first_kept_entry_id: ?[]const u8 = null,
    tokens_before: ?u64 = null,
    details_json: ?[]const u8 = null,
    from_hook: ?bool = null,
    from_id: ?[]const u8 = null,

    custom_type: ?[]const u8 = null,
    data_json: ?[]const u8 = null,
    content_json: ?[]const u8 = null,
    display: ?bool = null,

    target_id: ?[]const u8 = null,
    label: ?[]const u8 = null,
    name: ?[]const u8 = null,

    raw_json: ?[]const u8 = null,
};

pub const SessionMetadata = struct {
    id: []const u8,
    created_at: []const u8,
};

pub const JsonlSessionMetadata = struct {
    id: []const u8,
    created_at: []const u8,
    cwd: []const u8,
    path: []const u8,
    parent_session_path: ?[]const u8 = null,
};

pub fn appendEscapedXml(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: []const u8,
) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&apos;"),
            else => try output.append(allocator, byte),
        }
    }
}

fn noopChunkCallback(_: ?*anyopaque, _: []const u8) !void {}

fn unsupportedFileResult() Result(void, FileError) {
    return .{ .err = .{ .code = .not_supported, .message = "not supported" } };
}

fn unsupportedFileError() FileError {
    return .{ .code = .not_supported, .message = "not supported" };
}

fn defaultAbsolutePath(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) !Result([]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultJoinPath(_: ?*anyopaque, _: std.mem.Allocator, _: []const []const u8) !Result([]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultExec(_: ?*anyopaque, _: []const u8, _: ExecutionEnvExecOptions) !Result(ExecutionEnvExecResult, ExecutionError) {
    return .{ .err = .{ .code = .unknown, .message = "not supported" } };
}

fn defaultReadTextFile(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ?*const AbortSignal) !Result([]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultReadTextLines(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ReadTextLinesOptions) !Result([][]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultReadBinaryFile(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ?*const AbortSignal) !Result([]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultWriteFile(_: ?*anyopaque, _: []const u8, _: []const u8, _: ?*const AbortSignal) !Result(void, FileError) {
    return unsupportedFileResult();
}

fn defaultAppendFile(_: ?*anyopaque, _: []const u8, _: []const u8, _: ?*const AbortSignal) !Result(void, FileError) {
    return unsupportedFileResult();
}

fn defaultFileInfo(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) !Result(FileInfo, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultListDir(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: ?*const AbortSignal) !Result([]FileInfo, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultCanonicalPath(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) !Result([]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultExists(_: ?*anyopaque, _: []const u8) !Result(bool, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultCreateDir(_: ?*anyopaque, _: []const u8, _: CreateDirOptions) !Result(void, FileError) {
    return unsupportedFileResult();
}

fn defaultRemove(_: ?*anyopaque, _: []const u8, _: RemoveOptions) !Result(void, FileError) {
    return unsupportedFileResult();
}

fn defaultCreateTempDir(_: ?*anyopaque, _: std.mem.Allocator, _: CreateTempDirOptions) !Result([]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultCreateTempFile(_: ?*anyopaque, _: std.mem.Allocator, _: CreateTempFileOptions) !Result([]u8, FileError) {
    return .{ .err = unsupportedFileError() };
}

fn defaultCleanup(_: ?*anyopaque) !void {}
