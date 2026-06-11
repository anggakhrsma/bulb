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
};

pub const CreateTempFileOptions = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    abort_signal: ?*const AbortSignal = null,
};

pub const ExecutionEnv = struct {
    ptr: ?*anyopaque = null,
    cwd: []const u8,
    exec_fn: *const fn (?*anyopaque, []const u8, ExecutionEnvExecOptions) anyerror!Result(ExecutionEnvExecResult, ExecutionError),
    append_file_fn: *const fn (?*anyopaque, []const u8, []const u8, ?*const AbortSignal) anyerror!Result(void, FileError),
    create_temp_file_fn: *const fn (?*anyopaque, std.mem.Allocator, CreateTempFileOptions) anyerror!Result([]u8, FileError),

    pub fn exec(
        self: ExecutionEnv,
        command: []const u8,
        options: ExecutionEnvExecOptions,
    ) !Result(ExecutionEnvExecResult, ExecutionError) {
        return try self.exec_fn(self.ptr, command, options);
    }

    pub fn appendFile(
        self: ExecutionEnv,
        path: []const u8,
        content: []const u8,
        abort_signal: ?*const AbortSignal,
    ) !Result(void, FileError) {
        return try self.append_file_fn(self.ptr, path, content, abort_signal);
    }

    pub fn createTempFile(
        self: ExecutionEnv,
        allocator: std.mem.Allocator,
        options: CreateTempFileOptions,
    ) !Result([]u8, FileError) {
        return try self.create_temp_file_fn(self.ptr, allocator, options);
    }
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
