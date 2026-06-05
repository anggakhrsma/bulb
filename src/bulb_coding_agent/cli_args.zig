const std = @import("std");
const ai = @import("bulb_ai");
const config = @import("config.zig");

pub const Mode = enum {
    text,
    json,
    rpc,
};

pub const DiagnosticKind = enum {
    warning,
    @"error",
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    message: []const u8,
};

pub const UnknownFlagValue = union(enum) {
    boolean: bool,
    string: []const u8,
};

pub const UnknownFlag = struct {
    name: []const u8,
    value: UnknownFlagValue,
};

pub const ListModels = union(enum) {
    all,
    search: []const u8,
};

pub const Args = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: std.ArrayList([]const u8) = .empty,
    thinking: ?ai.ThinkingLevel = null,
    continue_flag: bool = false,
    resume_flag: bool = false,
    help: bool = false,
    version: bool = false,
    mode: ?Mode = null,
    name: ?[]const u8 = null,
    no_session: bool = false,
    session: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    fork: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    models: std.ArrayList([]const u8) = .empty,
    tools: std.ArrayList([]const u8) = .empty,
    exclude_tools: std.ArrayList([]const u8) = .empty,
    no_tools: bool = false,
    no_builtin_tools: bool = false,
    extensions: std.ArrayList([]const u8) = .empty,
    no_extensions: bool = false,
    print: bool = false,
    export_path: ?[]const u8 = null,
    no_skills: bool = false,
    skills: std.ArrayList([]const u8) = .empty,
    prompt_templates: std.ArrayList([]const u8) = .empty,
    no_prompt_templates: bool = false,
    themes: std.ArrayList([]const u8) = .empty,
    no_themes: bool = false,
    no_context_files: bool = false,
    list_models: ?ListModels = null,
    offline: bool = false,
    verbose: bool = false,
    messages: std.ArrayList([]const u8) = .empty,
    file_args: std.ArrayList([]const u8) = .empty,
    unknown_flags: std.ArrayList(UnknownFlag) = .empty,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        for (self.diagnostics.items) |diagnostic| {
            allocator.free(diagnostic.message);
        }
        self.append_system_prompt.deinit(allocator);
        self.models.deinit(allocator);
        self.tools.deinit(allocator);
        self.exclude_tools.deinit(allocator);
        self.extensions.deinit(allocator);
        self.skills.deinit(allocator);
        self.prompt_templates.deinit(allocator);
        self.themes.deinit(allocator);
        self.messages.deinit(allocator);
        self.file_args.deinit(allocator);
        self.unknown_flags.deinit(allocator);
        self.diagnostics.deinit(allocator);
        self.* = .{};
    }

    pub fn unknownFlag(self: Args, name: []const u8) ?UnknownFlagValue {
        for (self.unknown_flags.items) |flag| {
            if (std.mem.eql(u8, flag.name, name)) return flag.value;
        }
        return null;
    }

    pub fn hasErrors(self: Args) bool {
        for (self.diagnostics.items) |diagnostic| {
            if (diagnostic.kind == .@"error") return true;
        }
        return false;
    }

    pub fn exitsBeforeSessionReservation(self: Args) bool {
        return self.help or self.version or self.list_models != null;
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var result: Args = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.version = true;
        } else if (std.mem.eql(u8, arg, "--mode") and i + 1 < argv.len) {
            i += 1;
            if (parseMode(argv[i])) |mode| result.mode = mode;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            result.continue_flag = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            result.resume_flag = true;
        } else if (std.mem.eql(u8, arg, "--provider") and i + 1 < argv.len) {
            i += 1;
            result.provider = argv[i];
        } else if (std.mem.eql(u8, arg, "--model") and i + 1 < argv.len) {
            i += 1;
            result.model = argv[i];
        } else if (std.mem.eql(u8, arg, "--api-key") and i + 1 < argv.len) {
            i += 1;
            result.api_key = argv[i];
        } else if (std.mem.eql(u8, arg, "--system-prompt") and i + 1 < argv.len) {
            i += 1;
            result.system_prompt = argv[i];
        } else if (std.mem.eql(u8, arg, "--append-system-prompt") and i + 1 < argv.len) {
            i += 1;
            try result.append_system_prompt.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            if (i + 1 < argv.len) {
                i += 1;
                result.name = argv[i];
            } else {
                try appendDiagnostic(allocator, &result, .@"error", "--name requires a value");
            }
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            result.no_session = true;
        } else if (std.mem.eql(u8, arg, "--session") and i + 1 < argv.len) {
            i += 1;
            result.session = argv[i];
        } else if (std.mem.eql(u8, arg, "--session-id") and i + 1 < argv.len) {
            i += 1;
            result.session_id = argv[i];
        } else if (std.mem.eql(u8, arg, "--fork") and i + 1 < argv.len) {
            i += 1;
            result.fork = argv[i];
        } else if (std.mem.eql(u8, arg, "--session-dir") and i + 1 < argv.len) {
            i += 1;
            result.session_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--models") and i + 1 < argv.len) {
            i += 1;
            try appendCommaSeparated(allocator, &result.models, argv[i], false);
        } else if (std.mem.eql(u8, arg, "--no-tools") or std.mem.eql(u8, arg, "-nt")) {
            result.no_tools = true;
        } else if (std.mem.eql(u8, arg, "--no-builtin-tools") or std.mem.eql(u8, arg, "-nbt")) {
            result.no_builtin_tools = true;
        } else if ((std.mem.eql(u8, arg, "--tools") or std.mem.eql(u8, arg, "-t")) and i + 1 < argv.len) {
            i += 1;
            try appendCommaSeparated(allocator, &result.tools, argv[i], true);
        } else if ((std.mem.eql(u8, arg, "--exclude-tools") or std.mem.eql(u8, arg, "-xt")) and i + 1 < argv.len) {
            i += 1;
            try appendCommaSeparated(allocator, &result.exclude_tools, argv[i], true);
        } else if (std.mem.eql(u8, arg, "--thinking") and i + 1 < argv.len) {
            i += 1;
            const level = argv[i];
            if (parseThinkingLevel(level)) |thinking| {
                result.thinking = thinking;
            } else {
                const message = try std.fmt.allocPrint(
                    allocator,
                    "Invalid thinking level \"{s}\". Valid values: {s}",
                    .{ level, valid_thinking_levels_text },
                );
                defer allocator.free(message);
                try appendDiagnostic(allocator, &result, .warning, message);
            }
        } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print = true;
            if (i + 1 < argv.len and shouldPrintConsume(argv[i + 1])) {
                i += 1;
                try result.messages.append(allocator, argv[i]);
            }
        } else if (std.mem.eql(u8, arg, "--export") and i + 1 < argv.len) {
            i += 1;
            result.export_path = argv[i];
        } else if ((std.mem.eql(u8, arg, "--extension") or std.mem.eql(u8, arg, "-e")) and i + 1 < argv.len) {
            i += 1;
            try result.extensions.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-extensions") or std.mem.eql(u8, arg, "-ne")) {
            result.no_extensions = true;
        } else if (std.mem.eql(u8, arg, "--skill") and i + 1 < argv.len) {
            i += 1;
            try result.skills.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--prompt-template") and i + 1 < argv.len) {
            i += 1;
            try result.prompt_templates.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--theme") and i + 1 < argv.len) {
            i += 1;
            try result.themes.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-skills") or std.mem.eql(u8, arg, "-ns")) {
            result.no_skills = true;
        } else if (std.mem.eql(u8, arg, "--no-prompt-templates") or std.mem.eql(u8, arg, "-np")) {
            result.no_prompt_templates = true;
        } else if (std.mem.eql(u8, arg, "--no-themes")) {
            result.no_themes = true;
        } else if (std.mem.eql(u8, arg, "--no-context-files") or std.mem.eql(u8, arg, "-nc")) {
            result.no_context_files = true;
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-") and !std.mem.startsWith(u8, argv[i + 1], "@")) {
                i += 1;
                result.list_models = .{ .search = argv[i] };
            } else {
                result.list_models = .all;
            }
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            result.offline = true;
        } else if (std.mem.startsWith(u8, arg, "@")) {
            try result.file_args.append(allocator, arg[1..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq_index| {
                try appendUnknownFlag(allocator, &result, arg[2..eq_index], .{ .string = arg[eq_index + 1 ..] });
            } else {
                const flag_name = arg[2..];
                if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-") and !std.mem.startsWith(u8, argv[i + 1], "@")) {
                    i += 1;
                    try appendUnknownFlag(allocator, &result, flag_name, .{ .string = argv[i] });
                } else {
                    try appendUnknownFlag(allocator, &result, flag_name, .{ .boolean = true });
                }
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            const message = try std.fmt.allocPrint(allocator, "Unknown option: {s}", .{arg});
            defer allocator.free(message);
            try appendDiagnostic(allocator, &result, .@"error", message);
        } else {
            try result.messages.append(allocator, arg);
        }
    }

    return result;
}

pub fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.print(
        \\{s} - AI coding assistant with read, bash, edit, write tools
        \\
        \\Usage:
        \\  {s} [options] [@files...] [messages...]
        \\
        \\Commands:
        \\  {s} install <source> [-l]     Install extension source and add to settings
        \\  {s} remove <source> [-l]      Remove extension source from settings
        \\  {s} uninstall <source> [-l]   Alias for remove
        \\  {s} update [source|self|bulb] Update Bulb and installed extensions
        \\  {s} list                      List installed extensions from settings
        \\  {s} config                    Open TUI to enable/disable package resources
        \\
        \\Options:
        \\  --provider <name>              Provider name (default: google)
        \\  --model <pattern>              Model pattern or ID (supports "provider/id" and optional ":<thinking>")
        \\  --api-key <key>                API key (defaults to env vars)
        \\  --system-prompt <text>         System prompt (default: coding assistant prompt)
        \\  --append-system-prompt <text>  Append text or file contents to the system prompt (can be used multiple times)
        \\  --mode <mode>                  Output mode: text (default), json, or rpc
        \\  --print, -p                    Non-interactive mode: process prompt and exit
        \\  --continue, -c                 Continue previous session
        \\  --resume, -r                   Select a session to resume
        \\  --session <path|id>            Use specific session file or partial UUID
        \\  --session-id <id>              Use exact project session ID, creating it if missing
        \\  --fork <path|id>               Fork specific session file or partial UUID into a new session
        \\  --session-dir <dir>            Directory for session storage and lookup
        \\  --no-session                   Don't save session (ephemeral)
        \\  --name, -n <name>              Set session display name
        \\  --models <patterns>            Comma-separated model patterns for Ctrl+P cycling
        \\  --no-tools, -nt                Disable all tools by default (built-in and extension)
        \\  --no-builtin-tools, -nbt       Disable built-in tools by default but keep extension/custom tools enabled
        \\  --tools, -t <tools>            Comma-separated allowlist of tool names to enable
        \\  --exclude-tools, -xt <tools>   Comma-separated denylist of tool names to disable
        \\  --thinking <level>             Set thinking level: {s}
        \\  --extension, -e <path>         Load an extension file (can be used multiple times)
        \\  --no-extensions, -ne           Disable extension discovery (explicit -e paths still work)
        \\  --skill <path>                 Load a skill file or directory (can be used multiple times)
        \\  --no-skills, -ns               Disable skills discovery and loading
        \\  --prompt-template <path>       Load a prompt template file or directory (can be used multiple times)
        \\  --no-prompt-templates, -np     Disable prompt template discovery and loading
        \\  --theme <path>                 Load a theme file or directory (can be used multiple times)
        \\  --no-themes                    Disable theme discovery and loading
        \\  --no-context-files, -nc        Disable AGENTS.md and CLAUDE.md discovery and loading
        \\  --export <file>                Export session file to HTML and exit
        \\  --list-models [search]         List available models (with optional fuzzy search)
        \\  --verbose                      Force verbose startup
        \\  --offline                      Disable startup network operations
        \\  --help, -h                     Show this help
        \\  --version, -v                  Show version number
        \\
        \\Environment Variables:
        \\  ANTHROPIC_API_KEY              - Anthropic Claude API key
        \\  OPENAI_API_KEY                 - OpenAI GPT API key
        \\  GEMINI_API_KEY                 - Google Gemini API key
        \\  AWS_REGION                     - AWS region for Amazon Bedrock
        \\  {s}             - Config directory (default: ~/{s})
        \\  {s}     - Session storage directory (overridden by --session-dir)
        \\  BULB_PACKAGE_DIR               - Override package directory
        \\  BULB_OFFLINE                   - Disable startup network operations when set to 1/true/yes
        \\  BULB_TELEMETRY                 - Override install telemetry when set to 1/true/yes or 0/false/no
        \\  BULB_SHARE_VIEWER_URL          - Base URL for /share command
        \\
        \\Built-in Tool Names:
        \\  read   - Read file contents
        \\  bash   - Execute bash commands
        \\  edit   - Edit files with find/replace
        \\  write  - Write files (creates/overwrites)
        \\  grep   - Search file contents (read-only, off by default)
        \\  find   - Find files by glob pattern (read-only, off by default)
        \\  ls     - List directory contents (read-only, off by default)
        \\
    , .{
        config.product_name,
        config.command_name,
        config.command_name,
        config.command_name,
        config.command_name,
        config.command_name,
        config.command_name,
        config.command_name,
        valid_thinking_levels_text,
        config.agent_dir_env,
        config.global_config_dir,
        config.session_dir_env,
    });
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "rpc")) return .rpc;
    return null;
}

pub const valid_thinking_levels_text = "off, minimal, low, medium, high, xhigh";

pub fn parseThinkingLevel(value: []const u8) ?ai.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

fn shouldPrintConsume(next: []const u8) bool {
    return !std.mem.startsWith(u8, next, "@") and
        (!std.mem.startsWith(u8, next, "-") or std.mem.startsWith(u8, next, "---"));
}

fn appendCommaSeparated(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
    filter_empty: bool,
) !void {
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (filter_empty and trimmed.len == 0) continue;
        try list.append(allocator, trimmed);
    }
}

fn appendDiagnostic(
    allocator: std.mem.Allocator,
    args: *Args,
    kind: DiagnosticKind,
    message: []const u8,
) !void {
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    try args.diagnostics.append(allocator, .{
        .kind = kind,
        .message = owned_message,
    });
}

fn appendUnknownFlag(
    allocator: std.mem.Allocator,
    args: *Args,
    name: []const u8,
    value: UnknownFlagValue,
) !void {
    try args.unknown_flags.append(allocator, .{
        .name = name,
        .value = value,
    });
}

fn deinitParsed(args: *Args) void {
    args.deinit(std.testing.allocator);
}

fn parseTest(argv: []const []const u8) !Args {
    return parseArgs(std.testing.allocator, argv);
}

fn expectStrings(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_value, actual_value| {
        try std.testing.expectEqualStrings(expected_value, actual_value);
    }
}

fn expectUnknownString(args: Args, name: []const u8, expected: []const u8) !void {
    const value = args.unknownFlag(name) orelse return error.MissingUnknownFlag;
    switch (value) {
        .string => |actual| try std.testing.expectEqualStrings(expected, actual),
        .boolean => return error.ExpectedUnknownString,
    }
}

fn expectUnknownBoolean(args: Args, name: []const u8, expected: bool) !void {
    const value = args.unknownFlag(name) orelse return error.MissingUnknownFlag;
    switch (value) {
        .boolean => |actual| try std.testing.expectEqual(expected, actual),
        .string => return error.ExpectedUnknownBoolean,
    }
}

// Ported from packages/coding-agent/test/args.test.ts.
test "parseArgs ports version help print continue and resume flags" {
    var version = try parseTest(&.{"--version"});
    defer deinitParsed(&version);
    try std.testing.expect(version.version);

    var shorthand_version = try parseTest(&.{"-v"});
    defer deinitParsed(&shorthand_version);
    try std.testing.expect(shorthand_version.version);

    var precedence = try parseTest(&.{ "--version", "--help", "some message" });
    defer deinitParsed(&precedence);
    try std.testing.expect(precedence.version);
    try std.testing.expect(precedence.help);
    try expectStrings(precedence.messages.items, &.{"some message"});

    var help = try parseTest(&.{"--help"});
    defer deinitParsed(&help);
    try std.testing.expect(help.help);

    var shorthand_help = try parseTest(&.{"-h"});
    defer deinitParsed(&shorthand_help);
    try std.testing.expect(shorthand_help.help);

    var print = try parseTest(&.{"--print"});
    defer deinitParsed(&print);
    try std.testing.expect(print.print);

    var shorthand_print = try parseTest(&.{"-p"});
    defer deinitParsed(&shorthand_print);
    try std.testing.expect(shorthand_print.print);

    const prompt = "---\ntitle: hello\n---\nSay hi.";
    var frontmatter = try parseTest(&.{ "-p", prompt });
    defer deinitParsed(&frontmatter);
    try std.testing.expect(frontmatter.print);
    try expectStrings(frontmatter.messages.items, &.{prompt});
    try std.testing.expectEqual(@as(usize, 0), frontmatter.unknown_flags.items.len);

    var options_after_print = try parseTest(&.{ "-p", "--provider", "openai", "Say hi." });
    defer deinitParsed(&options_after_print);
    try std.testing.expect(options_after_print.print);
    try std.testing.expectEqualStrings("openai", options_after_print.provider.?);
    try expectStrings(options_after_print.messages.items, &.{"Say hi."});

    var continue_arg = try parseTest(&.{"--continue"});
    defer deinitParsed(&continue_arg);
    try std.testing.expect(continue_arg.continue_flag);

    var continue_short = try parseTest(&.{"-c"});
    defer deinitParsed(&continue_short);
    try std.testing.expect(continue_short.continue_flag);

    var resume_args = try parseTest(&.{"--resume"});
    defer deinitParsed(&resume_args);
    try std.testing.expect(resume_args.resume_flag);

    var resume_short = try parseTest(&.{"-r"});
    defer deinitParsed(&resume_short);
    try std.testing.expect(resume_short.resume_flag);
}

test "parseArgs ports value flags" {
    var provider = try parseTest(&.{ "--provider", "openai" });
    defer deinitParsed(&provider);
    try std.testing.expectEqualStrings("openai", provider.provider.?);

    var model = try parseTest(&.{ "--model", "gpt-4o" });
    defer deinitParsed(&model);
    try std.testing.expectEqualStrings("gpt-4o", model.model.?);

    var api_key = try parseTest(&.{ "--api-key", "sk-test-key" });
    defer deinitParsed(&api_key);
    try std.testing.expectEqualStrings("sk-test-key", api_key.api_key.?);

    var system_prompt = try parseTest(&.{ "--system-prompt", "You are a helpful assistant" });
    defer deinitParsed(&system_prompt);
    try std.testing.expectEqualStrings("You are a helpful assistant", system_prompt.system_prompt.?);

    var append_one = try parseTest(&.{ "--append-system-prompt", "Additional context" });
    defer deinitParsed(&append_one);
    try expectStrings(append_one.append_system_prompt.items, &.{"Additional context"});

    var append_many = try parseTest(&.{ "--append-system-prompt", "Context A", "--append-system-prompt", "Context B" });
    defer deinitParsed(&append_many);
    try expectStrings(append_many.append_system_prompt.items, &.{ "Context A", "Context B" });

    var mode_json = try parseTest(&.{ "--mode", "json" });
    defer deinitParsed(&mode_json);
    try std.testing.expectEqual(Mode.json, mode_json.mode.?);

    var mode_rpc = try parseTest(&.{ "--mode", "rpc" });
    defer deinitParsed(&mode_rpc);
    try std.testing.expectEqual(Mode.rpc, mode_rpc.mode.?);

    var session = try parseTest(&.{ "--session", "/path/to/session.jsonl" });
    defer deinitParsed(&session);
    try std.testing.expectEqualStrings("/path/to/session.jsonl", session.session.?);

    var session_id = try parseTest(&.{ "--session-id", "orchestrated-session" });
    defer deinitParsed(&session_id);
    try std.testing.expectEqualStrings("orchestrated-session", session_id.session_id.?);

    var fork = try parseTest(&.{ "--fork", "1234abcd" });
    defer deinitParsed(&fork);
    try std.testing.expectEqualStrings("1234abcd", fork.fork.?);
    try expectStrings(fork.messages.items, &.{});

    var export_arg = try parseTest(&.{ "--export", "session.jsonl" });
    defer deinitParsed(&export_arg);
    try std.testing.expectEqualStrings("session.jsonl", export_arg.export_path.?);

    var thinking = try parseTest(&.{ "--thinking", "high" });
    defer deinitParsed(&thinking);
    try std.testing.expectEqual(ai.ThinkingLevel.high, thinking.thinking.?);

    var models = try parseTest(&.{ "--models", "gpt-4o,claude-sonnet,gemini-pro" });
    defer deinitParsed(&models);
    try expectStrings(models.models.items, &.{ "gpt-4o", "claude-sonnet", "gemini-pro" });
}

test "parseArgs ports name flag behavior" {
    var named = try parseTest(&.{ "--name", "my-session" });
    defer deinitParsed(&named);
    try std.testing.expectEqualStrings("my-session", named.name.?);

    var shorthand = try parseTest(&.{ "-n", "quick-session" });
    defer deinitParsed(&shorthand);
    try std.testing.expectEqualStrings("quick-session", shorthand.name.?);

    var empty = try parseTest(&.{ "--name", "" });
    defer deinitParsed(&empty);
    try std.testing.expectEqualStrings("", empty.name.?);

    var missing = try parseTest(&.{"--name"});
    defer deinitParsed(&missing);
    try std.testing.expectEqual(@as(usize, 1), missing.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticKind.@"error", missing.diagnostics.items[0].kind);
    try std.testing.expectEqualStrings("--name requires a value", missing.diagnostics.items[0].message);

    var combined = try parseTest(&.{ "--name", "named-run", "--print", "--model", "gpt-4o", "hello" });
    defer deinitParsed(&combined);
    try std.testing.expectEqualStrings("named-run", combined.name.?);
    try std.testing.expect(combined.print);
    try std.testing.expectEqualStrings("gpt-4o", combined.model.?);
    try expectStrings(combined.messages.items, &.{"hello"});
}

test "parseArgs ports package resource flags" {
    var no_session = try parseTest(&.{"--no-session"});
    defer deinitParsed(&no_session);
    try std.testing.expect(no_session.no_session);

    var extension = try parseTest(&.{ "--extension", "./my-extension.ts" });
    defer deinitParsed(&extension);
    try expectStrings(extension.extensions.items, &.{"./my-extension.ts"});

    var extension_short = try parseTest(&.{ "-e", "./my-extension.ts" });
    defer deinitParsed(&extension_short);
    try expectStrings(extension_short.extensions.items, &.{"./my-extension.ts"});

    var extensions = try parseTest(&.{ "--extension", "./ext1.ts", "-e", "./ext2.ts" });
    defer deinitParsed(&extensions);
    try expectStrings(extensions.extensions.items, &.{ "./ext1.ts", "./ext2.ts" });

    var no_extensions = try parseTest(&.{"--no-extensions"});
    defer deinitParsed(&no_extensions);
    try std.testing.expect(no_extensions.no_extensions);

    var no_extensions_with_explicit = try parseTest(&.{ "--no-extensions", "-e", "foo.ts", "-e", "bar.ts" });
    defer deinitParsed(&no_extensions_with_explicit);
    try std.testing.expect(no_extensions_with_explicit.no_extensions);
    try expectStrings(no_extensions_with_explicit.extensions.items, &.{ "foo.ts", "bar.ts" });

    var skill = try parseTest(&.{ "--skill", "./skill-dir" });
    defer deinitParsed(&skill);
    try expectStrings(skill.skills.items, &.{"./skill-dir"});

    var skills = try parseTest(&.{ "--skill", "./skill-a", "--skill", "./skill-b" });
    defer deinitParsed(&skills);
    try expectStrings(skills.skills.items, &.{ "./skill-a", "./skill-b" });

    var prompt_template = try parseTest(&.{ "--prompt-template", "./prompts" });
    defer deinitParsed(&prompt_template);
    try expectStrings(prompt_template.prompt_templates.items, &.{"./prompts"});

    var prompt_templates = try parseTest(&.{ "--prompt-template", "./one", "--prompt-template", "./two" });
    defer deinitParsed(&prompt_templates);
    try expectStrings(prompt_templates.prompt_templates.items, &.{ "./one", "./two" });

    var theme = try parseTest(&.{ "--theme", "./theme.json" });
    defer deinitParsed(&theme);
    try expectStrings(theme.themes.items, &.{"./theme.json"});

    var themes = try parseTest(&.{ "--theme", "./dark.json", "--theme", "./light.json" });
    defer deinitParsed(&themes);
    try expectStrings(themes.themes.items, &.{ "./dark.json", "./light.json" });

    var no_skills = try parseTest(&.{"--no-skills"});
    defer deinitParsed(&no_skills);
    try std.testing.expect(no_skills.no_skills);

    var no_prompt_templates = try parseTest(&.{"--no-prompt-templates"});
    defer deinitParsed(&no_prompt_templates);
    try std.testing.expect(no_prompt_templates.no_prompt_templates);

    var no_themes = try parseTest(&.{"--no-themes"});
    defer deinitParsed(&no_themes);
    try std.testing.expect(no_themes.no_themes);

    var no_context_files = try parseTest(&.{"--no-context-files"});
    defer deinitParsed(&no_context_files);
    try std.testing.expect(no_context_files.no_context_files);

    var no_context_files_short = try parseTest(&.{"-nc"});
    defer deinitParsed(&no_context_files_short);
    try std.testing.expect(no_context_files_short.no_context_files);

    var verbose = try parseTest(&.{"--verbose"});
    defer deinitParsed(&verbose);
    try std.testing.expect(verbose.verbose);

    var offline = try parseTest(&.{"--offline"});
    defer deinitParsed(&offline);
    try std.testing.expect(offline.offline);
}

test "parseArgs ports tool flags" {
    var no_tools = try parseTest(&.{"--no-tools"});
    defer deinitParsed(&no_tools);
    try std.testing.expect(no_tools.no_tools);

    var no_tools_short = try parseTest(&.{"-nt"});
    defer deinitParsed(&no_tools_short);
    try std.testing.expect(no_tools_short.no_tools);

    var no_builtin_tools = try parseTest(&.{"--no-builtin-tools"});
    defer deinitParsed(&no_builtin_tools);
    try std.testing.expect(no_builtin_tools.no_builtin_tools);

    var no_builtin_tools_short = try parseTest(&.{"-nbt"});
    defer deinitParsed(&no_builtin_tools_short);
    try std.testing.expect(no_builtin_tools_short.no_builtin_tools);

    var tools = try parseTest(&.{ "--tools", "read,bash" });
    defer deinitParsed(&tools);
    try expectStrings(tools.tools.items, &.{ "read", "bash" });

    var tools_short = try parseTest(&.{ "-t", "read,bash" });
    defer deinitParsed(&tools_short);
    try expectStrings(tools_short.tools.items, &.{ "read", "bash" });

    var exclude_tools = try parseTest(&.{ "--exclude-tools", "read,bash" });
    defer deinitParsed(&exclude_tools);
    try expectStrings(exclude_tools.exclude_tools.items, &.{ "read", "bash" });

    var exclude_tools_short = try parseTest(&.{ "-xt", "read,bash" });
    defer deinitParsed(&exclude_tools_short);
    try expectStrings(exclude_tools_short.exclude_tools.items, &.{ "read", "bash" });

    var no_tools_with_tools = try parseTest(&.{ "--no-tools", "--tools", "read,bash" });
    defer deinitParsed(&no_tools_with_tools);
    try std.testing.expect(no_tools_with_tools.no_tools);
    try expectStrings(no_tools_with_tools.tools.items, &.{ "read", "bash" });

    var no_builtin_with_tools = try parseTest(&.{ "--no-builtin-tools", "--tools", "read,bash" });
    defer deinitParsed(&no_builtin_with_tools);
    try std.testing.expect(no_builtin_with_tools.no_builtin_tools);
    try expectStrings(no_builtin_with_tools.tools.items, &.{ "read", "bash" });
}

test "parseArgs ports messages file args and unknown flags" {
    var messages = try parseTest(&.{ "hello", "world" });
    defer deinitParsed(&messages);
    try expectStrings(messages.messages.items, &.{ "hello", "world" });

    var files = try parseTest(&.{ "@README.md", "@src/main.ts" });
    defer deinitParsed(&files);
    try expectStrings(files.file_args.items, &.{ "README.md", "src/main.ts" });

    var mixed = try parseTest(&.{ "@file.txt", "explain this", "@image.png" });
    defer deinitParsed(&mixed);
    try expectStrings(mixed.file_args.items, &.{ "file.txt", "image.png" });
    try expectStrings(mixed.messages.items, &.{"explain this"});

    var unknown_string = try parseTest(&.{ "--unknown-flag", "message" });
    defer deinitParsed(&unknown_string);
    try expectStrings(unknown_string.messages.items, &.{});
    try expectUnknownString(unknown_string, "unknown-flag", "message");

    var unknown_boolean = try parseTest(&.{"--unknown-flag"});
    defer deinitParsed(&unknown_boolean);
    try expectUnknownBoolean(unknown_boolean, "unknown-flag", true);

    var unknown_equals = try parseTest(&.{"--unknown-flag=value"});
    defer deinitParsed(&unknown_equals);
    try expectUnknownString(unknown_equals, "unknown-flag", "value");
}

test "parseArgs ports complex combinations" {
    var result = try parseTest(&.{
        "--provider",
        "anthropic",
        "--model",
        "claude-sonnet",
        "--print",
        "--thinking",
        "high",
        "@prompt.md",
        "Do the task",
    });
    defer deinitParsed(&result);

    try std.testing.expectEqualStrings("anthropic", result.provider.?);
    try std.testing.expectEqualStrings("claude-sonnet", result.model.?);
    try std.testing.expect(result.print);
    try std.testing.expectEqual(ai.ThinkingLevel.high, result.thinking.?);
    try expectStrings(result.file_args.items, &.{"prompt.md"});
    try expectStrings(result.messages.items, &.{"Do the task"});
}

test "parseArgs ports list-models optional search and read-only session reservation helper" {
    var all = try parseTest(&.{ "--session-id", "read-only-models", "--list-models" });
    defer deinitParsed(&all);
    try std.testing.expectEqualStrings("read-only-models", all.session_id.?);
    try std.testing.expect(all.exitsBeforeSessionReservation());
    switch (all.list_models.?) {
        .all => {},
        .search => return error.ExpectedListModelsAll,
    }

    var search = try parseTest(&.{ "--list-models", "sonnet" });
    defer deinitParsed(&search);
    switch (search.list_models.?) {
        .search => |value| try std.testing.expectEqualStrings("sonnet", value),
        .all => return error.ExpectedListModelsSearch,
    }

    var help = try parseTest(&.{ "--session-id", "read-only-help", "--help" });
    defer deinitParsed(&help);
    try std.testing.expect(help.exitsBeforeSessionReservation());

    var prompt = try parseTest(&.{ "--session-id", "persistent", "-p", "hi" });
    defer deinitParsed(&prompt);
    try std.testing.expect(!prompt.exitsBeforeSessionReservation());
}
