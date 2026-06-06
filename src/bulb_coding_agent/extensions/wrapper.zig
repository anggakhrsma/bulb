const std = @import("std");

const tools = @import("../tools/root.zig");
const types = @import("types.zig");

pub const AgentTool = tools.tool_registry.AgentTool;

pub fn wrapRegisteredTool(registered_tool: types.RegisteredTool) AgentTool {
    return tools.tool_registry.wrapToolDefinition(registered_tool.definition);
}

pub fn wrapRegisteredToolsAlloc(
    allocator: std.mem.Allocator,
    registered_tools: []const types.RegisteredTool,
) ![]AgentTool {
    var wrapped = try allocator.alloc(AgentTool, registered_tools.len);
    errdefer allocator.free(wrapped);

    for (registered_tools, 0..) |registered_tool, index| {
        wrapped[index] = wrapRegisteredTool(registered_tool);
    }
    return wrapped;
}

test "wrap registered tool preserves extension tool metadata and execution callback" {
    const Context = struct {
        called: bool = false,

        fn execute(
            ptr: ?*anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            cwd: []const u8,
            params: std.json.Value,
            options: tools.tool_registry.ToolExecuteOptions,
        ) !tools.tool_registry.ToolExecution {
            _ = io;
            _ = cwd;
            _ = params;
            _ = options;
            const ctx: *@This() = @ptrCast(@alignCast(ptr.?));
            ctx.called = true;
            const content = try allocator.alloc(tools.render_utils.ToolContentBlock, 1);
            content[0] = tools.render_utils.textBlock(try allocator.dupe(u8, "ok"));
            return .{ .success = .{ .content = content } };
        }
    };

    var context: Context = .{};
    const registered = types.RegisteredTool{
        .definition = .{
            .name = "oracle",
            .label = "Oracle",
            .description = "answers",
            .parameters_json = "{\"type\":\"object\"}",
            .ptr = &context,
            .custom_execute_fn = Context.execute,
        },
        .source_info = .{
            .path = "<inline>",
            .source = "inline",
            .scope = .temporary,
            .origin = .top_level,
        },
    };

    var tool = wrapRegisteredTool(registered);
    try std.testing.expectEqualStrings("oracle", tool.name);
    try std.testing.expectEqualStrings("Oracle", tool.label);
    var execution = try tool.executeJsonAlloc(std.testing.allocator, std.testing.io, "{}", .{});
    defer execution.deinit(std.testing.allocator);
    try std.testing.expect(context.called);
}

test "wrap registered tools maps all definitions in order" {
    const registered = [_]types.RegisteredTool{
        .{
            .definition = .{
                .name = "first",
                .label = "first",
                .description = "first",
                .parameters_json = "{\"type\":\"object\"}",
            },
            .source_info = .{
                .path = "<first>",
                .source = "inline",
                .scope = .temporary,
                .origin = .top_level,
            },
        },
        .{
            .definition = .{
                .name = "second",
                .label = "second",
                .description = "second",
                .parameters_json = "{\"type\":\"object\"}",
            },
            .source_info = .{
                .path = "<second>",
                .source = "inline",
                .scope = .temporary,
                .origin = .top_level,
            },
        },
    };

    const wrapped = try wrapRegisteredToolsAlloc(std.testing.allocator, &registered);
    defer std.testing.allocator.free(wrapped);
    try std.testing.expectEqualStrings("first", wrapped[0].name);
    try std.testing.expectEqualStrings("second", wrapped[1].name);
}
