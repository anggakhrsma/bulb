const std = @import("std");

const ai = @import("bulb_ai");
const bash = @import("bash.zig");
const edit = @import("edit.zig");
const find = @import("find.zig");
const grep = @import("grep.zig");
const ls = @import("ls.zig");
const read = @import("read.zig");
const render_utils = @import("render_utils.zig");
const truncate = @import("truncate.zig");
const write = @import("write.zig");

pub const ToolName = enum {
    read,
    bash,
    edit,
    write,
    grep,
    find,
    ls,

    pub fn text(self: ToolName) []const u8 {
        return switch (self) {
            .read => "read",
            .bash => "bash",
            .edit => "edit",
            .write => "write",
            .grep => "grep",
            .find => "find",
            .ls => "ls",
        };
    }

    pub fn parse(name: []const u8) ?ToolName {
        inline for (all_tool_names) |tool_name| {
            if (std.mem.eql(u8, name, tool_name.text())) return tool_name;
        }
        return null;
    }
};

pub const all_tool_names = [_]ToolName{ .read, .bash, .edit, .write, .grep, .find, .ls };
pub const coding_tool_names = [_]ToolName{ .read, .bash, .edit, .write };
pub const read_only_tool_names = [_]ToolName{ .read, .grep, .find, .ls };

pub const ToolExecutionMode = enum {
    parallel,
    sequential,
};

pub const ToolExecuteOptions = struct {
    bash_update: ?bash.BashUpdateCallback = null,
};

pub const ToolResult = struct {
    content: []render_utils.ToolContentBlock,
    details_json: ?[]u8 = null,

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        for (self.content) |block| {
            if (block.text) |text| allocator.free(text);
            if (block.data) |data| allocator.free(data);
            if (block.mime_type) |mime_type| allocator.free(mime_type);
        }
        allocator.free(self.content);
        if (self.details_json) |details_json| allocator.free(details_json);
        self.* = undefined;
    }
};

pub const ToolExecution = union(enum) {
    success: ToolResult,
    failure: []u8,

    pub fn deinit(self: *ToolExecution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*result| result.deinit(allocator),
            .failure => |message| allocator.free(message),
        }
        self.* = undefined;
    }
};

pub const CustomExecuteFn = *const fn (
    ?*anyopaque,
    std.mem.Allocator,
    std.Io,
    []const u8,
    std.json.Value,
    ToolExecuteOptions,
) anyerror!ToolExecution;

pub const ToolDefinition = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    prompt_snippet: ?[]const u8 = null,
    prompt_guidelines: []const []const u8 = &.{},
    execution_mode: ?ToolExecutionMode = null,
    render_shell: ?[]const u8 = null,
    cwd: []const u8 = "",
    builtin_name: ?ToolName = null,
    options: ToolsOptions = .{},
    ptr: ?*anyopaque = null,
    custom_execute_fn: ?CustomExecuteFn = null,

    pub fn toAiTool(self: ToolDefinition) ai.Tool {
        return .{
            .name = self.name,
            .description = self.description,
            .parameters_json = self.parameters_json,
        };
    }

    pub fn executeJsonAlloc(
        self: *const ToolDefinition,
        allocator: std.mem.Allocator,
        io: std.Io,
        params_json: []const u8,
        execute_options: ToolExecuteOptions,
    ) !ToolExecution {
        var parsed = try parseParamsJson(allocator, params_json);
        defer parsed.deinit();
        return self.executeValueAlloc(allocator, io, parsed.value, execute_options);
    }

    pub fn executeValueAlloc(
        self: *const ToolDefinition,
        allocator: std.mem.Allocator,
        io: std.Io,
        params: std.json.Value,
        execute_options: ToolExecuteOptions,
    ) !ToolExecution {
        if (self.builtin_name) |builtin| {
            return executeBuiltInToolAlloc(allocator, io, builtin, self.cwd, self.options, params, execute_options);
        }
        const execute_fn = self.custom_execute_fn orelse return error.ToolDefinitionNotExecutable;
        return execute_fn(self.ptr, allocator, io, self.cwd, params, execute_options);
    }
};

pub const AgentTool = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execution_mode: ?ToolExecutionMode = null,
    cwd: []const u8 = "",
    builtin_name: ?ToolName = null,
    options: ToolsOptions = .{},
    ptr: ?*anyopaque = null,
    custom_execute_fn: ?CustomExecuteFn = null,

    pub fn executeJsonAlloc(
        self: *const AgentTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        params_json: []const u8,
        execute_options: ToolExecuteOptions,
    ) !ToolExecution {
        var parsed = try parseParamsJson(allocator, params_json);
        defer parsed.deinit();
        return self.executeValueAlloc(allocator, io, parsed.value, execute_options);
    }

    pub fn executeValueAlloc(
        self: *const AgentTool,
        allocator: std.mem.Allocator,
        io: std.Io,
        params: std.json.Value,
        execute_options: ToolExecuteOptions,
    ) !ToolExecution {
        if (self.builtin_name) |builtin| {
            return executeBuiltInToolAlloc(allocator, io, builtin, self.cwd, self.options, params, execute_options);
        }
        const execute_fn = self.custom_execute_fn orelse return error.ToolDefinitionNotExecutable;
        return execute_fn(self.ptr, allocator, io, self.cwd, params, execute_options);
    }
};

pub const ToolsOptions = struct {
    read: read.ReadToolOptions = .{},
    bash: bash.BashToolOptions = .{},
    edit: edit.EditToolOptions = .{},
    write: write.WriteToolOptions = .{},
    grep: grep.GrepToolOptions = .{},
    find: find.FindToolOptions = .{},
    ls: ls.LsToolOptions = .{},
};

pub const AllToolDefinitions = struct {
    read: ToolDefinition,
    bash: ToolDefinition,
    edit: ToolDefinition,
    write: ToolDefinition,
    grep: ToolDefinition,
    find: ToolDefinition,
    ls: ToolDefinition,

    pub fn get(self: *const AllToolDefinitions, name: ToolName) *const ToolDefinition {
        return switch (name) {
            .read => &self.read,
            .bash => &self.bash,
            .edit => &self.edit,
            .write => &self.write,
            .grep => &self.grep,
            .find => &self.find,
            .ls => &self.ls,
        };
    }
};

pub const AllTools = struct {
    read: AgentTool,
    bash: AgentTool,
    edit: AgentTool,
    write: AgentTool,
    grep: AgentTool,
    find: AgentTool,
    ls: AgentTool,

    pub fn get(self: *const AllTools, name: ToolName) *const AgentTool {
        return switch (name) {
            .read => &self.read,
            .bash => &self.bash,
            .edit => &self.edit,
            .write => &self.write,
            .grep => &self.grep,
            .find => &self.find,
            .ls => &self.ls,
        };
    }
};

pub fn createToolDefinition(tool_name: ToolName, cwd: []const u8, options: ToolsOptions) ToolDefinition {
    return .{
        .name = tool_name.text(),
        .label = tool_name.text(),
        .description = descriptionFor(tool_name),
        .parameters_json = parametersJsonFor(tool_name),
        .prompt_snippet = promptSnippetFor(tool_name),
        .prompt_guidelines = promptGuidelinesFor(tool_name),
        .render_shell = if (tool_name == .edit) "self" else null,
        .cwd = cwd,
        .builtin_name = tool_name,
        .options = options,
    };
}

pub fn createToolDefinitionByName(name: []const u8, cwd: []const u8, options: ToolsOptions) !ToolDefinition {
    const tool_name = ToolName.parse(name) orelse return error.UnknownToolName;
    return createToolDefinition(tool_name, cwd, options);
}

pub fn createTool(tool_name: ToolName, cwd: []const u8, options: ToolsOptions) AgentTool {
    return wrapToolDefinition(createToolDefinition(tool_name, cwd, options));
}

pub fn createToolByName(name: []const u8, cwd: []const u8, options: ToolsOptions) !AgentTool {
    return wrapToolDefinition(try createToolDefinitionByName(name, cwd, options));
}

pub fn createCodingToolDefinitionsAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    options: ToolsOptions,
) ![]ToolDefinition {
    return createDefinitionsAlloc(allocator, &coding_tool_names, cwd, options);
}

pub fn createReadOnlyToolDefinitionsAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    options: ToolsOptions,
) ![]ToolDefinition {
    return createDefinitionsAlloc(allocator, &read_only_tool_names, cwd, options);
}

pub fn createAllToolDefinitions(cwd: []const u8, options: ToolsOptions) AllToolDefinitions {
    return .{
        .read = createToolDefinition(.read, cwd, options),
        .bash = createToolDefinition(.bash, cwd, options),
        .edit = createToolDefinition(.edit, cwd, options),
        .write = createToolDefinition(.write, cwd, options),
        .grep = createToolDefinition(.grep, cwd, options),
        .find = createToolDefinition(.find, cwd, options),
        .ls = createToolDefinition(.ls, cwd, options),
    };
}

pub fn createCodingToolsAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    options: ToolsOptions,
) ![]AgentTool {
    return createToolsAlloc(allocator, &coding_tool_names, cwd, options);
}

pub fn createReadOnlyToolsAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    options: ToolsOptions,
) ![]AgentTool {
    return createToolsAlloc(allocator, &read_only_tool_names, cwd, options);
}

pub fn createAllTools(cwd: []const u8, options: ToolsOptions) AllTools {
    const definitions = createAllToolDefinitions(cwd, options);
    return .{
        .read = wrapToolDefinition(definitions.read),
        .bash = wrapToolDefinition(definitions.bash),
        .edit = wrapToolDefinition(definitions.edit),
        .write = wrapToolDefinition(definitions.write),
        .grep = wrapToolDefinition(definitions.grep),
        .find = wrapToolDefinition(definitions.find),
        .ls = wrapToolDefinition(definitions.ls),
    };
}

pub fn wrapToolDefinition(definition: ToolDefinition) AgentTool {
    return .{
        .name = definition.name,
        .label = definition.label,
        .description = definition.description,
        .parameters_json = definition.parameters_json,
        .execution_mode = definition.execution_mode,
        .cwd = definition.cwd,
        .builtin_name = definition.builtin_name,
        .options = definition.options,
        .ptr = definition.ptr,
        .custom_execute_fn = definition.custom_execute_fn,
    };
}

pub fn wrapToolDefinitionsAlloc(
    allocator: std.mem.Allocator,
    definitions: []const ToolDefinition,
) ![]AgentTool {
    var tools = try allocator.alloc(AgentTool, definitions.len);
    errdefer allocator.free(tools);
    for (definitions, 0..) |definition, index| {
        tools[index] = wrapToolDefinition(definition);
    }
    return tools;
}

pub fn createToolDefinitionFromAgentTool(tool: AgentTool) ToolDefinition {
    return .{
        .name = tool.name,
        .label = tool.label,
        .description = tool.description,
        .parameters_json = tool.parameters_json,
        .execution_mode = tool.execution_mode,
        .cwd = tool.cwd,
        .builtin_name = tool.builtin_name,
        .options = tool.options,
        .ptr = tool.ptr,
        .custom_execute_fn = tool.custom_execute_fn,
    };
}

fn createDefinitionsAlloc(
    allocator: std.mem.Allocator,
    names: []const ToolName,
    cwd: []const u8,
    options: ToolsOptions,
) ![]ToolDefinition {
    var definitions = try allocator.alloc(ToolDefinition, names.len);
    errdefer allocator.free(definitions);
    for (names, 0..) |tool_name, index| {
        definitions[index] = createToolDefinition(tool_name, cwd, options);
    }
    return definitions;
}

fn createToolsAlloc(
    allocator: std.mem.Allocator,
    names: []const ToolName,
    cwd: []const u8,
    options: ToolsOptions,
) ![]AgentTool {
    var tools = try allocator.alloc(AgentTool, names.len);
    errdefer allocator.free(tools);
    for (names, 0..) |tool_name, index| {
        tools[index] = createTool(tool_name, cwd, options);
    }
    return tools;
}

fn executeBuiltInToolAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    tool_name: ToolName,
    cwd: []const u8,
    options: ToolsOptions,
    params: std.json.Value,
    execute_options: ToolExecuteOptions,
) !ToolExecution {
    return switch (tool_name) {
        .read => executeReadAlloc(allocator, io, cwd, try parseReadInput(params), options.read),
        .bash => executeBashAlloc(allocator, io, cwd, try parseBashInput(params), options.bash, execute_options.bash_update),
        .edit => |name| {
            _ = name;
            const input = try parseEditInputAlloc(allocator, params);
            defer allocator.free(input.edits);
            return executeEditAlloc(allocator, io, cwd, input, options.edit);
        },
        .write => executeWriteAlloc(allocator, io, cwd, try parseWriteInput(params), options.write),
        .grep => executeGrepAlloc(allocator, io, cwd, try parseGrepInput(params), options.grep),
        .find => executeFindAlloc(allocator, io, cwd, try parseFindInput(params), options.find),
        .ls => executeLsAlloc(allocator, io, cwd, try parseLsInput(params), options.ls),
    };
}

fn executeReadAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: read.ReadToolInput,
    options: read.ReadToolOptions,
) !ToolExecution {
    var result = read.executeAlloc(allocator, io, cwd, input, options) catch |err| {
        return .{ .failure = try errorMessageAlloc(allocator, err) };
    };
    errdefer result.deinit(allocator);

    const content = result.content;
    result.content = &.{};
    if (result.details) |*details| details.deinit(allocator);
    return .{ .success = .{ .content = content } };
}

fn executeBashAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: bash.BashToolInput,
    options: bash.BashToolOptions,
    on_update: ?bash.BashUpdateCallback,
) !ToolExecution {
    var execution = try bash.executeWithDiagnosticAlloc(allocator, io, cwd, input, options, on_update);
    switch (execution) {
        .success => |*result| {
            const content = result.content;
            result.content = &.{};
            if (result.details) |*details| details.deinit(allocator);
            return .{ .success = .{ .content = content } };
        },
        .failure => |message| {
            execution = undefined;
            return .{ .failure = message };
        },
    }
}

fn executeEditAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: edit.EditToolInput,
    options: edit.EditToolOptions,
) !ToolExecution {
    var execution = try edit.executeWithDiagnosticAlloc(allocator, io, cwd, input, options);
    switch (execution) {
        .success => |*result| {
            const content = result.content;
            result.content = &.{};
            if (result.details) |*details| details.deinit(allocator);
            return .{ .success = .{ .content = content } };
        },
        .failure => |message| {
            execution = undefined;
            return .{ .failure = message };
        },
    }
}

fn executeWriteAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: write.WriteToolInput,
    options: write.WriteToolOptions,
) !ToolExecution {
    var result = write.executeAlloc(allocator, io, cwd, input, options) catch |err| {
        return .{ .failure = try errorMessageAlloc(allocator, err) };
    };
    const content = result.content;
    result.content = &.{};
    return .{ .success = .{ .content = content } };
}

fn executeGrepAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: grep.GrepToolInput,
    options: grep.GrepToolOptions,
) !ToolExecution {
    var result = grep.executeAlloc(allocator, io, cwd, input, options) catch |err| {
        return .{ .failure = try errorMessageAlloc(allocator, err) };
    };
    errdefer result.deinit(allocator);
    return textResultExecutionAlloc(allocator, &result.text);
}

fn executeFindAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: find.FindToolInput,
    options: find.FindToolOptions,
) !ToolExecution {
    var result = find.executeAlloc(allocator, io, cwd, input, options) catch |err| {
        return .{ .failure = try errorMessageAlloc(allocator, err) };
    };
    errdefer result.deinit(allocator);
    return textResultExecutionAlloc(allocator, &result.text);
}

fn executeLsAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    input: ls.LsToolInput,
    options: ls.LsToolOptions,
) !ToolExecution {
    var result = ls.executeAlloc(allocator, io, cwd, input, options) catch |err| {
        return .{ .failure = try errorMessageAlloc(allocator, err) };
    };
    errdefer result.deinit(allocator);
    return textResultExecutionAlloc(allocator, &result.text);
}

fn textResultExecutionAlloc(allocator: std.mem.Allocator, text: *[]u8) !ToolExecution {
    const blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = render_utils.textBlock(text.*);
    text.* = &.{};
    return .{ .success = .{ .content = blocks } };
}

fn parseParamsJson(allocator: std.mem.Allocator, params_json: []const u8) !std.json.Parsed(std.json.Value) {
    const trimmed = std.mem.trim(u8, params_json, " \t\r\n");
    if (trimmed.len == 0) return std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
    return std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
}

fn parseReadInput(value: std.json.Value) !read.ReadToolInput {
    const object = try objectValue(value);
    return .{
        .path = optionalString(object, "path"),
        .offset = try optionalUsize(object, "offset"),
        .limit = try optionalUsize(object, "limit"),
    };
}

fn parseBashInput(value: std.json.Value) !bash.BashToolInput {
    const object = try objectValue(value);
    return .{
        .command = optionalString(object, "command"),
        .timeout = try optionalU64(object, "timeout"),
    };
}

fn parseEditInputAlloc(allocator: std.mem.Allocator, value: std.json.Value) !edit.EditToolInput {
    const object = try objectValue(value);
    const edits_value = object.get("edits") orelse return .{ .path = optionalString(object, "path") };
    if (edits_value != .array) return error.InvalidToolArguments;
    var edits = try allocator.alloc(edit.Edit, edits_value.array.items.len);
    errdefer allocator.free(edits);
    for (edits_value.array.items, 0..) |item, index| {
        const edit_object = try objectValue(item);
        edits[index] = .{
            .old_text = try requiredString(edit_object, "oldText"),
            .new_text = try requiredString(edit_object, "newText"),
        };
    }
    return .{
        .path = optionalString(object, "path"),
        .file_path = optionalString(object, "filePath"),
        .edits = edits,
        .old_text = optionalString(object, "oldText"),
        .new_text = optionalString(object, "newText"),
    };
}

fn parseWriteInput(value: std.json.Value) !write.WriteToolInput {
    const object = try objectValue(value);
    return .{
        .path = optionalString(object, "path"),
        .file_path = optionalString(object, "filePath"),
        .content = optionalString(object, "content"),
    };
}

fn parseGrepInput(value: std.json.Value) !grep.GrepToolInput {
    const object = try objectValue(value);
    return .{
        .pattern = optionalString(object, "pattern"),
        .path = optionalString(object, "path"),
        .glob = optionalString(object, "glob"),
        .ignore_case = try optionalBool(object, "ignoreCase"),
        .literal = try optionalBool(object, "literal"),
        .context = try optionalUsize(object, "context"),
        .limit = try optionalUsize(object, "limit"),
    };
}

fn parseFindInput(value: std.json.Value) !find.FindToolInput {
    const object = try objectValue(value);
    return .{
        .pattern = optionalString(object, "pattern"),
        .path = optionalString(object, "path"),
        .limit = try optionalUsize(object, "limit"),
    };
}

fn parseLsInput(value: std.json.Value) !ls.LsToolInput {
    const object = try objectValue(value);
    return .{
        .path = optionalString(object, "path"),
        .limit = try optionalUsize(object, "limit"),
    };
}

fn objectValue(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidToolArguments;
    return value.object;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return optionalString(object, key) orelse error.InvalidToolArguments;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    if (value != .bool) return error.InvalidToolArguments;
    return value.bool;
}

fn optionalUsize(object: std.json.ObjectMap, key: []const u8) !?usize {
    const value = object.get(key) orelse return null;
    return try jsonValueToUnsigned(usize, value);
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    return try jsonValueToUnsigned(u64, value);
}

fn jsonValueToUnsigned(comptime T: type, value: std.json.Value) !T {
    return switch (value) {
        .integer => |number| {
            if (number < 0) return error.InvalidToolArguments;
            return std.math.cast(T, number) orelse error.InvalidToolArguments;
        },
        .float => |number| {
            if (!std.math.isFinite(number) or number < 0 or @floor(number) != number) return error.InvalidToolArguments;
            return std.math.cast(T, @as(u64, @intFromFloat(number))) orelse error.InvalidToolArguments;
        },
        else => error.InvalidToolArguments,
    };
}

fn errorMessageAlloc(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
}

fn descriptionFor(tool_name: ToolName) []const u8 {
    return switch (tool_name) {
        .read => "Read the contents of a file. Supports text files and images (jpg, png, gif, webp). Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete.",
        .bash => "Execute a bash command in the current working directory. Returns stdout and stderr. Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output is saved to a temp file. Optionally provide a timeout in seconds.",
        .edit => "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, non-overlapping region of the original file. If two changes affect the same block or nearby lines, merge them into one edit instead of emitting overlapping edits. Do not include large unchanged regions just to connect distant changes.",
        .write => "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. Automatically creates parent directories.",
        .grep => "Search file contents for a pattern. Returns matching lines with file paths and line numbers. Respects .gitignore. Output is truncated to 100 matches or 50KB (whichever is hit first). Long lines are truncated to 500 chars.",
        .find => "Search for files by glob pattern. Returns matching file paths relative to the search directory. Respects .gitignore. Output is truncated to 1000 results or 50KB (whichever is hit first).",
        .ls => "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first).",
    };
}

fn promptSnippetFor(tool_name: ToolName) ?[]const u8 {
    return switch (tool_name) {
        .read => "Read file contents",
        .bash => "Execute bash commands (ls, grep, find, etc.)",
        .edit => "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
        .write => "Create or overwrite files",
        .grep => "Search file contents for patterns (respects .gitignore)",
        .find => "Find files by glob pattern (respects .gitignore)",
        .ls => "List directory contents",
    };
}

fn promptGuidelinesFor(tool_name: ToolName) []const []const u8 {
    return switch (tool_name) {
        .read => &read_prompt_guidelines,
        .edit => &edit_prompt_guidelines,
        .write => &write_prompt_guidelines,
        else => &.{},
    };
}

fn parametersJsonFor(tool_name: ToolName) []const u8 {
    return switch (tool_name) {
        .read => read_parameters_json,
        .bash => bash_parameters_json,
        .edit => edit_parameters_json,
        .write => write_parameters_json,
        .grep => grep_parameters_json,
        .find => find_parameters_json,
        .ls => ls_parameters_json,
    };
}

const read_prompt_guidelines = [_][]const u8{
    "Use read to examine files instead of cat or sed.",
};

const edit_prompt_guidelines = [_][]const u8{
    "Use edit for precise changes (edits[].oldText must match exactly)",
    "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls",
    "Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
    "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.",
};

const write_prompt_guidelines = [_][]const u8{
    "Use write only for new files or complete rewrites.",
};

const read_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to read (relative or absolute)"},"offset":{"type":"number","description":"Line number to start reading from (1-indexed)"},"limit":{"type":"number","description":"Maximum number of lines to read"}},"required":["path"],"additionalProperties":false}
;

const bash_parameters_json =
    \\{"type":"object","properties":{"command":{"type":"string","description":"Bash command to execute"},"timeout":{"type":"number","description":"Timeout in seconds (optional, no default timeout)"}},"required":["command"]}
;

const edit_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to edit (relative or absolute)"},"edits":{"type":"array","description":"One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.","items":{"type":"object","properties":{"oldText":{"type":"string","description":"Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."},"newText":{"type":"string","description":"Replacement text for this targeted edit."}},"required":["oldText","newText"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
;

const write_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Path to the file to write (relative or absolute)"},"content":{"type":"string","description":"Content to write to the file"}},"required":["path","content"]}
;

const grep_parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Search pattern (regex or literal string)"},"path":{"type":"string","description":"Directory or file to search (default: current directory)"},"glob":{"type":"string","description":"Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'"},"ignoreCase":{"type":"boolean","description":"Case-insensitive search (default: false)"},"literal":{"type":"boolean","description":"Treat pattern as literal string instead of regex (default: false)"},"context":{"type":"number","description":"Number of lines to show before and after each match (default: 0)"},"limit":{"type":"number","description":"Maximum number of matches to return (default: 100)"}},"required":["pattern"]}
;

const find_parameters_json =
    \\{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'"},"path":{"type":"string","description":"Directory to search in (default: current directory)"},"limit":{"type":"number","description":"Maximum number of results (default: 1000)"}},"required":["pattern"]}
;

const ls_parameters_json =
    \\{"type":"object","properties":{"path":{"type":"string","description":"Directory to list (default: current directory)"},"limit":{"type":"number","description":"Maximum number of entries to return (default: 500)"}}}
;

const FakeBashOperations = struct {
    command_seen: ?[]u8 = null,
    timeout_seen: ?u64 = null,

    fn deinit(self: *FakeBashOperations, allocator: std.mem.Allocator) void {
        if (self.command_seen) |command| allocator.free(command);
        self.* = .{};
    }

    fn exec(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        command: []const u8,
        _: []const u8,
        options: bash.BashExecOptions,
    ) !bash.BashExecResult {
        const self: *FakeBashOperations = @ptrCast(@alignCast(ptr.?));
        self.command_seen = try allocator.dupe(u8, command);
        self.timeout_seen = options.timeout_seconds;
        try options.on_data.call("ok\n");
        return .{ .exit_code = 0 };
    }
};

test "tool registry preserves Pi tool groups and all-tool record" {
    const allocator = std.testing.allocator;
    const coding = try createCodingToolDefinitionsAlloc(allocator, "/tmp", .{});
    defer allocator.free(coding);
    try std.testing.expectEqual(@as(usize, 4), coding.len);
    try std.testing.expectEqualStrings("read", coding[0].name);
    try std.testing.expectEqualStrings("bash", coding[1].name);
    try std.testing.expectEqualStrings("edit", coding[2].name);
    try std.testing.expectEqualStrings("write", coding[3].name);

    const readonly = try createReadOnlyToolsAlloc(allocator, "/tmp", .{});
    defer allocator.free(readonly);
    try std.testing.expectEqual(@as(usize, 4), readonly.len);
    try std.testing.expectEqualStrings("read", readonly[0].name);
    try std.testing.expectEqualStrings("grep", readonly[1].name);
    try std.testing.expectEqualStrings("find", readonly[2].name);
    try std.testing.expectEqualStrings("ls", readonly[3].name);

    const all = createAllToolDefinitions("/tmp", .{});
    try std.testing.expectEqualStrings("bash", all.get(.bash).name);
    try std.testing.expectEqualStrings("ls", all.get(.ls).name);
}

test "tool definition exposes AI metadata and JSON schema" {
    const allocator = std.testing.allocator;
    const definition = createToolDefinition(.grep, "/tmp", .{});
    const ai_tool = definition.toAiTool();
    try std.testing.expectEqualStrings("grep", ai_tool.name);
    try std.testing.expect(std.mem.indexOf(u8, ai_tool.description, "Search file contents") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, ai_tool.parameters_json, .{});
    defer parsed.deinit();
    const properties = parsed.value.object.get("properties").?.object;
    try std.testing.expect(properties.get("ignoreCase") != null);
    try std.testing.expect(properties.get("pattern") != null);
}

test "tool registry rejects unknown names" {
    try std.testing.expect(ToolName.parse("nope") == null);
    try std.testing.expectError(error.UnknownToolName, createToolDefinitionByName("nope", "/tmp", .{}));
}

test "wrapped builtin tool executes JSON input through dispatcher" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fake: FakeBashOperations = .{};
    defer fake.deinit(allocator);

    const tool = createTool(.bash, "/tmp", .{
        .bash = .{ .operations = .{ .ptr = &fake, .exec_fn = FakeBashOperations.exec } },
    });

    var execution = try tool.executeJsonAlloc(allocator, io, "{\"command\":\"echo ok\",\"timeout\":7}", .{});
    defer execution.deinit(allocator);
    try std.testing.expectEqualStrings("echo ok", fake.command_seen.?);
    try std.testing.expectEqual(@as(?u64, 7), fake.timeout_seen);
    const text = try render_utils.getTextOutputAlloc(allocator, .{ .content = execution.success.content }, false);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("ok\n", text);
}

test "wrapper round-trips custom agent tool metadata and executor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const custom = AgentTool{
        .name = "custom",
        .label = "Custom",
        .description = "Custom tool",
        .parameters_json = "{\"type\":\"object\"}",
        .execution_mode = .sequential,
        .custom_execute_fn = customExecute,
    };

    const definition = createToolDefinitionFromAgentTool(custom);
    try std.testing.expectEqualStrings("custom", definition.name);
    try std.testing.expectEqual(ToolExecutionMode.sequential, definition.execution_mode.?);

    const wrapped = wrapToolDefinition(definition);
    var execution = try wrapped.executeJsonAlloc(allocator, io, "{}", .{});
    defer execution.deinit(allocator);
    const text = try render_utils.getTextOutputAlloc(allocator, .{ .content = execution.success.content }, false);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("custom-ok", text);
}

fn customExecute(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
    _: std.json.Value,
    _: ToolExecuteOptions,
) !ToolExecution {
    const blocks = try allocator.alloc(render_utils.ToolContentBlock, 1);
    errdefer allocator.free(blocks);
    blocks[0] = render_utils.textBlock(try allocator.dupe(u8, "custom-ok"));
    return .{ .success = .{ .content = blocks } };
}

test "registry constants stay aligned with upstream truncation defaults" {
    try std.testing.expectEqual(@as(usize, 2000), truncate.DEFAULT_MAX_LINES);
    try std.testing.expectEqual(@as(usize, 50 * 1024), truncate.DEFAULT_MAX_BYTES);
    try std.testing.expectEqual(@as(usize, 500), truncate.GREP_MAX_LINE_LENGTH);
}
