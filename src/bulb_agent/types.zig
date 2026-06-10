const std = @import("std");

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
