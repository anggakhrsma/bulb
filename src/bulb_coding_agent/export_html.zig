const std = @import("std");

const ai = @import("bulb_ai");
const config = @import("config.zig");
const messages = @import("messages.zig");
const paths = @import("paths.zig");
const session_manager = @import("session_manager.zig");

pub const ExportHtmlError = error{
    CannotExportInMemorySession,
    NothingToExportYet,
};

pub fn exportSessionToHtmlAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    manager: *const session_manager.SessionManager,
    output_path: ?[]const u8,
) ![]u8 {
    const session_file = manager.getSessionFile() orelse return ExportHtmlError.CannotExportInMemorySession;
    if (!pathExists(io, session_file)) return ExportHtmlError.NothingToExportYet;

    var context = try manager.buildSessionContextAlloc(allocator);
    defer context.deinit();

    const html = try renderHtmlAlloc(allocator, manager, session_file, &context);
    defer allocator.free(html);

    const resolved_output = if (output_path) |path|
        try paths.normalizePathAlloc(allocator, path, .{})
    else
        try defaultOutputPathAlloc(allocator, session_file);
    defer allocator.free(resolved_output);

    if (std.fs.path.dirname(resolved_output)) |parent| {
        if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = resolved_output,
        .data = html,
        .flags = .{ .read = true, .truncate = true },
    });

    return try allocator.dupe(u8, resolved_output);
}

fn defaultOutputPathAlloc(allocator: std.mem.Allocator, session_file: []const u8) ![]u8 {
    const base = std.fs.path.basename(session_file);
    const stem = if (std.mem.endsWith(u8, base, ".jsonl")) base[0 .. base.len - ".jsonl".len] else base;
    return std.fmt.allocPrint(allocator, "{s}-session-{s}.html", .{ config.command_name, stem });
}

fn renderHtmlAlloc(
    allocator: std.mem.Allocator,
    manager: *const session_manager.SessionManager,
    session_file: []const u8,
    context: *const session_manager.SessionContext,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const header = manager.getHeader();
    const session_id = manager.getSessionId();

    try output.appendSlice(allocator, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++ "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" ++ "<title>Bulb session export</title>" ++ "<style>" ++ "body{margin:0;background:#0f172a;color:#e5e7eb;font-family:system-ui,-apple-system,Segoe UI,sans-serif;}" ++ "main{max-width:1100px;margin:0 auto;padding:24px;}" ++ "header{background:#111827;border:1px solid #334155;border-radius:16px;padding:20px;margin-bottom:20px;}" ++ "h1{margin:0 0 12px;font-size:24px;}" ++ ".meta-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;}" ++ ".meta{background:#0b1220;border:1px solid #334155;border-radius:12px;padding:12px;}" ++ ".meta-label{display:block;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#94a3b8;margin-bottom:4px;}" ++ ".meta-value{white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere;}" ++ ".transcript{display:grid;gap:16px;}" ++ ".message{background:#111827;border:1px solid #334155;border-radius:16px;padding:16px;}" ++ ".message-user{border-left:4px solid #38bdf8;}" ++ ".message-assistant{border-left:4px solid #4ade80;}" ++ ".message-tool_result{border-left:4px solid #a78bfa;}" ++ ".message-bash_execution{border-left:4px solid #f59e0b;}" ++ ".message-custom{border-left:4px solid #fb7185;}" ++ ".message-branch_summary,.message-compaction_summary{border-left:4px solid #f97316;}" ++ ".message-header{display:flex;flex-wrap:wrap;gap:10px;align-items:baseline;margin-bottom:10px;}" ++ ".message-role{font-weight:700;font-size:14px;}" ++ ".message-meta{font-size:12px;color:#94a3b8;}" ++ ".message-body{display:grid;gap:10px;}" ++ "pre{margin:0;white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere;" ++ "font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;}" ++ "blockquote{margin:0;padding-left:12px;border-left:4px solid #f59e0b;color:#e2e8f0;white-space:pre-wrap;}" ++ "details{background:#0b1220;border:1px solid #334155;border-radius:12px;padding:10px 12px;}" ++ "summary{cursor:pointer;font-weight:600;color:#cbd5e1;}" ++ "img{max-width:100%;height:auto;border-radius:10px;border:1px solid #334155;background:#020617;}" ++ ".small{color:#94a3b8;font-size:12px;}" ++ "</style></head><body><main>");

    try output.appendSlice(allocator, "<header><h1>");
    try appendEscapedHtml(allocator, &output, config.product_name);
    try output.appendSlice(allocator, " session export</h1><div class=\"meta-grid\">");
    try appendMeta(allocator, &output, "Session ID", session_id);
    try appendMeta(allocator, &output, "Session File", session_file);
    if (header) |value| {
        if (value.timestamp) |timestamp| try appendMeta(allocator, &output, "Created", timestamp);
        if (value.cwd) |cwd| try appendMeta(allocator, &output, "CWD", cwd);
        if (value.parent_session) |parent| try appendMeta(allocator, &output, "Parent", parent);
    }
    if (context.model) |model| {
        var model_list: std.ArrayList(u8) = .empty;
        defer model_list.deinit(allocator);
        try appendEscapedHtml(allocator, &model_list, model.provider);
        try model_list.append(allocator, '/');
        try appendEscapedHtml(allocator, &model_list, model.model_id);
        try appendMeta(allocator, &output, "Model", model_list.items);
    }
    try appendMeta(allocator, &output, "Thinking", context.thinking_level);
    try appendMetaInt(allocator, &output, "Messages", context.messages.len);
    try output.appendSlice(allocator, "</div></header><section class=\"transcript\">");

    for (context.messages) |message| {
        try appendMessageBlock(allocator, &output, message);
    }

    try output.appendSlice(allocator, "</section></main></body></html>");
    return output.toOwnedSlice(allocator);
}

fn appendMeta(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    label: []const u8,
    value: []const u8,
) !void {
    try output.appendSlice(allocator, "<div class=\"meta\"><span class=\"meta-label\">");
    try appendEscapedHtml(allocator, output, label);
    try output.appendSlice(allocator, "</span><div class=\"meta-value\">");
    try appendEscapedHtml(allocator, output, value);
    try output.appendSlice(allocator, "</div></div>");
}

fn appendMetaInt(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    label: []const u8,
    value: usize,
) !void {
    try output.appendSlice(allocator, "<div class=\"meta\"><span class=\"meta-label\">");
    try appendEscapedHtml(allocator, output, label);
    try output.appendSlice(allocator, "</span><div class=\"meta-value\">");
    try output.print(allocator, "{d}", .{value});
    try output.appendSlice(allocator, "</div></div>");
}

fn appendMessageBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: messages.CodingAgentMessage,
) !void {
    const role = messageRole(message);
    const class_name = messageClass(message);
    try output.appendSlice(allocator, "<article class=\"message ");
    try appendEscapedHtml(allocator, output, class_name);
    try output.appendSlice(allocator, "\"><div class=\"message-header\"><span class=\"message-role\">");
    try appendEscapedHtml(allocator, output, role);
    try output.appendSlice(allocator, "</span>");
    try appendMessageMeta(allocator, output, message);
    try output.appendSlice(allocator, "</div><div class=\"message-body\">");

    switch (message) {
        .user => |value| try appendUserContentBlocks(allocator, output, value.content),
        .assistant => |value| try appendAssistantContentBlocks(allocator, output, value),
        .tool_result => |value| try appendToolResultContentBlocks(allocator, output, value),
        .bash_execution => |value| try appendBashExecutionBlock(allocator, output, value),
        .custom => |value| try appendCustomMessageBlock(allocator, output, value),
        .branch_summary => |value| try appendSummaryBlock(allocator, output, "Branch summary", value.summary),
        .compaction_summary => |value| try appendCompactionSummaryBlock(allocator, output, value),
    }

    try output.appendSlice(allocator, "</div></article>");
}

fn appendMessageMeta(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: messages.CodingAgentMessage,
) !void {
    try output.appendSlice(allocator, "<span class=\"message-meta\">");
    switch (message) {
        .user => |value| {
            try output.print(allocator, "timestamp {d}", .{value.timestamp_ms});
        },
        .assistant => |value| {
            try appendEscapedHtml(allocator, output, value.provider);
            try output.appendSlice(allocator, "/");
            try appendEscapedHtml(allocator, output, value.model);
            try output.appendSlice(allocator, " - stop ");
            try appendEscapedHtml(allocator, output, @tagName(value.stop_reason));
            if (value.response_model) |response_model| {
                try output.appendSlice(allocator, " - response ");
                try appendEscapedHtml(allocator, output, response_model);
            }
        },
        .tool_result => |value| {
            try appendEscapedHtml(allocator, output, value.tool_name);
            try output.appendSlice(allocator, " - ");
            try appendEscapedHtml(allocator, output, value.tool_call_id);
            try output.appendSlice(allocator, if (value.is_error) " - error" else " - ok");
        },
        .bash_execution => |value| {
            try output.appendSlice(allocator, "command ");
            try appendEscapedHtml(allocator, output, value.command);
            try output.appendSlice(allocator, if (value.cancelled) " - cancelled" else " - finished");
        },
        .custom => |value| {
            try appendEscapedHtml(allocator, output, value.custom_type);
            try output.appendSlice(allocator, if (value.display) " - display" else " - hidden");
        },
        .branch_summary => |value| {
            try output.appendSlice(allocator, "from ");
            try appendEscapedHtml(allocator, output, value.from_id);
            try output.print(allocator, " - timestamp {d}", .{value.timestamp_ms});
        },
        .compaction_summary => |value| {
            try output.print(allocator, "tokens before {d} - timestamp {d}", .{ value.tokens_before, value.timestamp_ms });
        },
    }
    try output.appendSlice(allocator, "</span>");
}

fn appendUserContentBlocks(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    content: []const ai.UserContent,
) !void {
    for (content) |part| {
        switch (part) {
            .text => |text| {
                try output.appendSlice(allocator, "<pre>");
                try appendEscapedHtml(allocator, output, text.text);
                try output.appendSlice(allocator, "</pre>");
            },
            .image => |image| try appendImageBlock(allocator, output, image.mime_type, image.data),
        }
    }
}

fn appendAssistantContentBlocks(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: ai.AssistantMessage,
) !void {
    for (message.content) |part| {
        switch (part) {
            .text => |text| {
                try output.appendSlice(allocator, "<pre>");
                try appendEscapedHtml(allocator, output, text.text);
                try output.appendSlice(allocator, "</pre>");
            },
            .thinking => |thinking| {
                try output.appendSlice(allocator, "<details><summary>Thinking");
                if (thinking.redacted) try output.appendSlice(allocator, " (redacted)");
                try output.appendSlice(allocator, "</summary><pre>");
                try appendEscapedHtml(allocator, output, thinking.thinking);
                try output.appendSlice(allocator, "</pre></details>");
            },
            .tool_call => |tool_call| {
                try output.appendSlice(allocator, "<details><summary>Tool call: ");
                try appendEscapedHtml(allocator, output, tool_call.name);
                try output.appendSlice(allocator, "</summary><pre>");
                try appendEscapedHtml(allocator, output, tool_call.arguments_json);
                try output.appendSlice(allocator, "</pre></details>");
            },
        }
    }
}

fn appendToolResultContentBlocks(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: ai.ToolResultMessage,
) !void {
    try output.appendSlice(allocator, "<div class=\"small\">tool call ");
    try appendEscapedHtml(allocator, output, message.tool_call_id);
    try output.appendSlice(allocator, "</div>");
    try appendUserContentBlocks(allocator, output, message.content);
}

fn appendBashExecutionBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: messages.BashExecutionMessage,
) !void {
    try output.appendSlice(allocator, "<pre>");
    try output.appendSlice(allocator, "command: ");
    try appendEscapedHtml(allocator, output, message.command);
    try output.appendSlice(allocator, "\n");
    try output.appendSlice(allocator, "output:\n");
    try appendEscapedHtml(allocator, output, message.output);
    if (message.exit_code) |exit_code| {
        try output.print(allocator, "\nexit code: {d}", .{exit_code});
    }
    if (message.cancelled) {
        try output.appendSlice(allocator, "\ncancelled: true");
    }
    if (message.truncated) {
        try output.appendSlice(allocator, "\ntruncated: true");
    }
    if (message.full_output_path) |path| {
        try output.appendSlice(allocator, "\nfull output: ");
        try appendEscapedHtml(allocator, output, path);
    }
    try output.appendSlice(allocator, "</pre>");
}

fn appendCustomMessageBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: messages.CustomMessage,
) !void {
    if (message.details_json) |details| {
        try output.appendSlice(allocator, "<div class=\"small\">details</div><pre>");
        try appendEscapedHtml(allocator, output, details);
        try output.appendSlice(allocator, "</pre>");
    }

    switch (message.content) {
        .text => |text| {
            try output.appendSlice(allocator, "<pre>");
            try appendEscapedHtml(allocator, output, text);
            try output.appendSlice(allocator, "</pre>");
        },
        .parts => |parts| try appendUserContentBlocks(allocator, output, parts),
    }
}

fn appendSummaryBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    label: []const u8,
    summary: []const u8,
) !void {
    try output.appendSlice(allocator, "<div class=\"small\">");
    try appendEscapedHtml(allocator, output, label);
    try output.appendSlice(allocator, "</div><blockquote>");
    try appendEscapedHtml(allocator, output, summary);
    try output.appendSlice(allocator, "</blockquote>");
}

fn appendCompactionSummaryBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    message: messages.CompactionSummaryMessage,
) !void {
    try output.print(allocator, "<div class=\"small\">tokens before {d}</div>", .{message.tokens_before});
    try appendSummaryBlock(allocator, output, "Compaction summary", message.summary);
}

fn appendImageBlock(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    mime_type: []const u8,
    data: []const u8,
) !void {
    try output.appendSlice(allocator, "<figure><img loading=\"lazy\" alt=\"image\" src=\"data:");
    try appendEscapedHtml(allocator, output, mime_type);
    try output.appendSlice(allocator, ";base64,");
    try appendEscapedHtml(allocator, output, data);
    try output.appendSlice(allocator, "\"></figure>");
}

fn appendEscapedHtml(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try output.appendSlice(allocator, "&amp;"),
            '<' => try output.appendSlice(allocator, "&lt;"),
            '>' => try output.appendSlice(allocator, "&gt;"),
            '"' => try output.appendSlice(allocator, "&quot;"),
            '\'' => try output.appendSlice(allocator, "&#39;"),
            else => try output.append(allocator, byte),
        }
    }
}

fn messageRole(message: messages.CodingAgentMessage) []const u8 {
    return switch (message) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "toolResult",
        .bash_execution => "bashExecution",
        .custom => "custom",
        .branch_summary => "branchSummary",
        .compaction_summary => "compactionSummary",
    };
}

fn messageClass(message: messages.CodingAgentMessage) []const u8 {
    return switch (message) {
        .user => "message-user",
        .assistant => "message-assistant",
        .tool_result => "message-tool_result",
        .bash_execution => "message-bash_execution",
        .custom => "message-custom",
        .branch_summary => "message-branch_summary",
        .compaction_summary => "message-compaction_summary",
    };
}

fn pathExists(io: std.Io, file_path: []const u8) bool {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch return false;
    return true;
}

test "export html writes a readable transcript with escaped content" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const project_dir = try std.fs.path.join(allocator, &.{ root, "project" });
    defer allocator.free(project_dir);
    const session_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(session_dir);
    const output_path = try std.fs.path.join(allocator, &.{ root, "exports", "session.html" });
    defer allocator.free(output_path);

    try std.Io.Dir.cwd().createDirPath(io, project_dir);
    try std.Io.Dir.cwd().createDirPath(io, session_dir);

    const manager = try allocator.create(session_manager.SessionManager);
    manager.* = try session_manager.SessionManager.create(allocator, io, project_dir, session_dir, .{});
    defer allocator.destroy(manager);
    defer manager.deinit();

    const user_content = [_]ai.UserContent{.{ .text = .{ .text = "<script>alert(1)</script>" } }};
    _ = try manager.appendMessage(io, .{
        .user = .{
            .content = &user_content,
            .timestamp_ms = 1234,
        },
    });
    const assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "Done" } }};
    _ = try manager.appendMessage(io, .{
        .assistant = .{
            .content = &assistant_content,
            .api = ai.types.api.openai_completions,
            .provider = "demo",
            .model = "demo",
            .timestamp_ms = 1235,
        },
    });

    const written = try exportSessionToHtmlAlloc(allocator, io, manager, output_path);
    defer allocator.free(written);
    try std.testing.expectEqualStrings(output_path, written);

    const html = try std.Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .unlimited);
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;alert(1)&lt;/script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Bulb session export") != null);
}
