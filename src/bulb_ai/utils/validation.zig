const std = @import("std");
const types = @import("../types.zig");

pub const ValidatedArguments = std.json.Parsed(std.json.Value);

pub fn validateToolCall(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    tool_call: types.ToolCall,
) !ValidatedArguments {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, tool_call.name)) {
            return validateToolArguments(allocator, tool, tool_call);
        }
    }
    return error.ToolNotFound;
}

pub fn validateToolArguments(
    allocator: std.mem.Allocator,
    tool: types.Tool,
    tool_call: types.ToolCall,
) !ValidatedArguments {
    var schema = std.json.parseFromSlice(std.json.Value, allocator, tool.parameters_json, .{}) catch
        return error.InvalidToolSchema;
    defer schema.deinit();
    var arguments = std.json.parseFromSlice(std.json.Value, allocator, tool_call.arguments_json, .{}) catch
        return error.ValidationFailed;
    errdefer arguments.deinit();

    try coerceValue(arguments.arena.allocator(), &arguments.value, schema.value);
    if (!validateValue(arguments.value, schema.value)) return error.ValidationFailed;
    return arguments;
}

fn coerceValue(allocator: std.mem.Allocator, value: *std.json.Value, schema: std.json.Value) !void {
    if (schema != .object) return;

    if (schema.object.get("allOf")) |all_of| {
        if (all_of == .array) {
            for (all_of.array.items) |nested| try coerceValue(allocator, value, nested);
        }
    }

    if (schema.object.get("type")) |schema_type| {
        if (!matchesAnySchemaType(value.*, schema_type)) {
            try coercePrimitive(allocator, value, schema_type);
        }
    }

    switch (value.*) {
        .object => |*object| {
            if (schema.object.get("properties")) |properties| {
                if (properties == .object) {
                    var iterator = properties.object.iterator();
                    while (iterator.next()) |entry| {
                        if (object.getPtr(entry.key_ptr.*)) |property_value| {
                            try coerceValue(allocator, property_value, entry.value_ptr.*);
                        }
                    }
                }
            }
            if (schema.object.get("additionalProperties")) |additional| {
                if (additional == .object) {
                    var iterator = object.iterator();
                    while (iterator.next()) |entry| {
                        if (!isDefinedProperty(schema, entry.key_ptr.*)) {
                            try coerceValue(allocator, entry.value_ptr, additional);
                        }
                    }
                }
            }
        },
        .array => |*array| {
            if (schema.object.get("items")) |items| {
                if (items == .object) {
                    for (array.items) |*item| try coerceValue(allocator, item, items);
                } else if (items == .array) {
                    for (array.items, 0..) |*item, index| {
                        if (index < items.array.items.len) try coerceValue(allocator, item, items.array.items[index]);
                    }
                }
            }
        },
        else => {},
    }
}

fn coercePrimitive(allocator: std.mem.Allocator, value: *std.json.Value, schema_type: std.json.Value) !void {
    if (schema_type == .string) return coercePrimitiveAs(allocator, value, schema_type.string);
    if (schema_type != .array) return;

    for (schema_type.array.items) |candidate| {
        if (candidate != .string) continue;
        const before = value.*;
        try coercePrimitiveAs(allocator, value, candidate.string);
        if (!std.meta.eql(before, value.*)) return;
    }
}

fn coercePrimitiveAs(allocator: std.mem.Allocator, value: *std.json.Value, schema_type: []const u8) !void {
    if (std.mem.eql(u8, schema_type, "number")) {
        value.* = switch (value.*) {
            .null => .{ .integer = 0 },
            .bool => |boolean| .{ .integer = @intFromBool(boolean) },
            .string => |text| parseJsonNumber(text) orelse return,
            else => return,
        };
    } else if (std.mem.eql(u8, schema_type, "integer")) {
        value.* = switch (value.*) {
            .null => .{ .integer = 0 },
            .bool => |boolean| .{ .integer = @intFromBool(boolean) },
            .string => |text| .{ .integer = std.fmt.parseInt(i64, text, 10) catch return },
            else => return,
        };
    } else if (std.mem.eql(u8, schema_type, "boolean")) {
        value.* = switch (value.*) {
            .null => .{ .bool = false },
            .integer => |integer| switch (integer) {
                0 => .{ .bool = false },
                1 => .{ .bool = true },
                else => return,
            },
            .float => |float| if (float == 0)
                .{ .bool = false }
            else if (float == 1)
                .{ .bool = true }
            else
                return,
            .string => |text| if (std.mem.eql(u8, text, "true"))
                .{ .bool = true }
            else if (std.mem.eql(u8, text, "false"))
                .{ .bool = false }
            else
                return,
            else => return,
        };
    } else if (std.mem.eql(u8, schema_type, "string")) {
        value.* = switch (value.*) {
            .null => .{ .string = try allocator.dupe(u8, "") },
            .bool => |boolean| .{ .string = try allocator.dupe(u8, if (boolean) "true" else "false") },
            .integer => |integer| .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{integer}) },
            .float => |float| .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{float}) },
            else => return,
        };
    } else if (std.mem.eql(u8, schema_type, "null")) {
        value.* = switch (value.*) {
            .string => |text| if (text.len == 0) .null else return,
            .integer => |integer| if (integer == 0) .null else return,
            .float => |float| if (float == 0) .null else return,
            .bool => |boolean| if (!boolean) .null else return,
            else => return,
        };
    }
}

fn parseJsonNumber(text: []const u8) ?std.json.Value {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
    if (std.fmt.parseInt(i64, text, 10)) |integer| {
        return .{ .integer = integer };
    } else |_| {}
    const float = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(float)) return null;
    return .{ .float = float };
}

fn validateValue(value: std.json.Value, schema: std.json.Value) bool {
    if (schema != .object) return true;
    if (schema.object.get("type")) |schema_type| {
        if (!matchesAnySchemaType(value, schema_type)) return false;
    }

    if (schema.object.get("allOf")) |all_of| {
        if (all_of == .array) {
            for (all_of.array.items) |nested| {
                if (!validateValue(value, nested)) return false;
            }
        }
    }

    switch (value) {
        .object => |object| {
            if (schema.object.get("required")) |required| {
                if (required == .array) {
                    for (required.array.items) |property| {
                        if (property != .string or object.get(property.string) == null) return false;
                    }
                }
            }
            if (schema.object.get("properties")) |properties| {
                if (properties == .object) {
                    var iterator = properties.object.iterator();
                    while (iterator.next()) |entry| {
                        if (object.get(entry.key_ptr.*)) |property_value| {
                            if (!validateValue(property_value, entry.value_ptr.*)) return false;
                        }
                    }
                }
            }
        },
        .array => |array| {
            if (schema.object.get("items")) |items| {
                if (items == .object) {
                    for (array.items) |item| {
                        if (!validateValue(item, items)) return false;
                    }
                } else if (items == .array) {
                    for (array.items, 0..) |item, index| {
                        if (index < items.array.items.len and !validateValue(item, items.array.items[index])) return false;
                    }
                }
            }
        },
        else => {},
    }
    return true;
}

fn matchesAnySchemaType(value: std.json.Value, schema_type: std.json.Value) bool {
    if (schema_type == .string) return matchesSchemaType(value, schema_type.string);
    if (schema_type != .array) return true;
    for (schema_type.array.items) |candidate| {
        if (candidate == .string and matchesSchemaType(value, candidate.string)) return true;
    }
    return false;
}

fn matchesSchemaType(value: std.json.Value, schema_type: []const u8) bool {
    if (std.mem.eql(u8, schema_type, "number")) return value == .integer or value == .float;
    if (std.mem.eql(u8, schema_type, "integer")) return value == .integer;
    if (std.mem.eql(u8, schema_type, "boolean")) return value == .bool;
    if (std.mem.eql(u8, schema_type, "string")) return value == .string;
    if (std.mem.eql(u8, schema_type, "null")) return value == .null;
    if (std.mem.eql(u8, schema_type, "array")) return value == .array;
    if (std.mem.eql(u8, schema_type, "object")) return value == .object;
    return false;
}

fn isDefinedProperty(schema: std.json.Value, property: []const u8) bool {
    const properties = schema.object.get("properties") orelse return false;
    return properties == .object and properties.object.get(property) != null;
}

fn wrappedTool(schema: []const u8) types.Tool {
    return .{
        .name = "echo",
        .description = "Echo tool",
        .parameters_json = schema,
    };
}

fn echoCall(arguments: []const u8) types.ToolCall {
    return .{
        .id = "tool-1",
        .name = "echo",
        .arguments_json = arguments,
    };
}

test "tool validation coerces serialized plain JSON schema primitives" {
    const allocator = std.testing.allocator;
    const Case = struct {
        schema: []const u8,
        arguments: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"number\"}},\"required\":[\"value\"]}", .arguments = "{\"value\":\"42\"}", .expected = "{\"value\":42}" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"number\"}},\"required\":[\"value\"]}", .arguments = "{\"value\":true}", .expected = "{\"value\":1}" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"boolean\"}},\"required\":[\"value\"]}", .arguments = "{\"value\":\"false\"}", .expected = "{\"value\":false}" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"]}", .arguments = "{\"value\":null}", .expected = "{\"value\":\"\"}" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"null\"}},\"required\":[\"value\"]}", .arguments = "{\"value\":0}", .expected = "{\"value\":null}" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":[\"number\",\"string\"]}},\"required\":[\"value\"]}", .arguments = "{\"value\":\"1\"}", .expected = "{\"value\":\"1\"}" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":[\"boolean\",\"number\"]}},\"required\":[\"value\"]}", .arguments = "{\"value\":\"1\"}", .expected = "{\"value\":1}" },
    };

    for (cases) |case| {
        var validated = try validateToolArguments(allocator, wrappedTool(case.schema), echoCall(case.arguments));
        defer validated.deinit();
        const actual = try std.json.Stringify.valueAlloc(allocator, validated.value, .{});
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "tool validation rejects invalid coercions and missing tools" {
    const allocator = std.testing.allocator;
    const boolean_tool = wrappedTool("{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"boolean\"}},\"required\":[\"value\"]}");
    try std.testing.expectError(error.ValidationFailed, validateToolArguments(allocator, boolean_tool, echoCall("{\"value\":\"1\"}")));
    try std.testing.expectError(error.ValidationFailed, validateToolArguments(allocator, boolean_tool, echoCall("{}")));
    try std.testing.expectError(error.ToolNotFound, validateToolCall(allocator, &.{boolean_tool}, .{
        .id = "tool-2",
        .name = "missing",
    }));
}

test "tool validation coerces nested objects arrays and additional properties" {
    const allocator = std.testing.allocator;
    const tool = wrappedTool(
        \\{"type":"object","properties":{"items":{"type":"array","items":{"type":"integer"}}},"additionalProperties":{"type":"boolean"}}
    );
    var validated = try validateToolArguments(allocator, tool, echoCall("{\"items\":[\"1\",\"2\"],\"enabled\":\"true\"}"));
    defer validated.deinit();
    const actual = try std.json.Stringify.valueAlloc(allocator, validated.value, .{});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("{\"items\":[1,2],\"enabled\":true}", actual);
}
