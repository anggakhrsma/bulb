const std = @import("std");

pub const TodoItem = struct {
    step: usize,
    text: []u8,
    completed: bool = false,

    pub fn deinit(self: *TodoItem, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = .{ .step = 0, .text = &.{}, .completed = false };
    }
};

pub fn deinitTodoItems(allocator: std.mem.Allocator, items: *std.ArrayList(TodoItem)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

pub fn isSafeCommand(command: []const u8) bool {
    return !hasDestructivePattern(command) and hasSafePattern(command);
}

pub fn cleanStepTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var markdown_removed: std.ArrayList(u8) = .empty;
    defer markdown_removed.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == '*' or byte == '`') {
            index += 1;
            continue;
        }
        try markdown_removed.append(allocator, byte);
        index += 1;
    }

    const without_action = stripLeadingActionWord(markdown_removed.items);

    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(allocator);

    var saw_non_space = false;
    var pending_space = false;
    for (without_action) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (saw_non_space) pending_space = true;
            continue;
        }
        if (pending_space and normalized.items.len > 0) {
            try normalized.append(allocator, ' ');
        }
        try normalized.append(allocator, byte);
        saw_non_space = true;
        pending_space = false;
    }

    if (normalized.items.len > 0) {
        normalized.items[0] = std.ascii.toUpper(normalized.items[0]);
    }

    const max_len = 50;
    if (normalized.items.len > max_len) {
        var truncated: std.ArrayList(u8) = .empty;
        defer truncated.deinit(allocator);
        try truncated.appendSlice(allocator, normalized.items[0..47]);
        try truncated.appendSlice(allocator, "...");
        return truncated.toOwnedSlice(allocator);
    }

    return normalized.toOwnedSlice(allocator);
}

pub fn extractTodoItemsAlloc(allocator: std.mem.Allocator, message: []const u8) !std.ArrayList(TodoItem) {
    var items: std.ArrayList(TodoItem) = .empty;
    errdefer deinitTodoItems(allocator, &items);

    const plan_start = findPlanSectionStart(message) orelse return items;
    var line_iter = std.mem.splitScalar(u8, message[plan_start..], '\n');
    while (line_iter.next()) |line| {
        const raw_text = parseNumberedPlanLine(line) orelse continue;
        const text = std.mem.trim(u8, raw_text, " \t\r\n");
        if (text.len <= 5) continue;
        if (text[0] == '`' or text[0] == '/' or text[0] == '-') continue;

        const cleaned = try cleanStepTextAlloc(allocator, text);
        errdefer allocator.free(cleaned);
        if (cleaned.len <= 3) {
            allocator.free(cleaned);
            continue;
        }

        try items.append(allocator, .{
            .step = items.items.len + 1,
            .text = cleaned,
            .completed = false,
        });
    }

    return items;
}

pub fn extractDoneStepsAlloc(allocator: std.mem.Allocator, message: []const u8) ![]usize {
    var steps: std.ArrayList(usize) = .empty;
    defer steps.deinit(allocator);

    var index: usize = 0;
    while (index < message.len) {
        const marker = findDoneMarker(message, index) orelse break;
        try steps.append(allocator, marker.step);
        index = marker.end;
    }

    return steps.toOwnedSlice(allocator);
}

pub fn markCompletedSteps(text: []const u8, items: []TodoItem) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const marker = findDoneMarker(text, index) orelse break;
        count += 1;
        for (items) |*item| {
            if (item.step == marker.step) {
                item.completed = true;
                break;
            }
        }
        index = marker.end;
    }
    return count;
}

const DoneMarker = struct {
    step: usize,
    end: usize,
};

fn findDoneMarker(message: []const u8, start: usize) ?DoneMarker {
    var index = start;
    while (std.mem.indexOfScalarPos(u8, message, index, '[')) |open| {
        if (open + "[DONE:".len > message.len) return null;
        if (!std.ascii.eqlIgnoreCase(message[open .. open + "[DONE:".len], "[DONE:")) {
            index = open + 1;
            continue;
        }

        var cursor = open + "[DONE:".len;
        const digits_start = cursor;
        while (cursor < message.len and std.ascii.isDigit(message[cursor])) : (cursor += 1) {}
        if (cursor == digits_start or cursor >= message.len or message[cursor] != ']') {
            index = open + 1;
            continue;
        }

        const step = std.fmt.parseUnsigned(usize, message[digits_start..cursor], 10) catch {
            index = open + 1;
            continue;
        };
        return .{ .step = step, .end = cursor + 1 };
    }
    return null;
}

fn hasDestructivePattern(command: []const u8) bool {
    if (hasBlockedRedirection(command)) return true;

    const destructive_words = [_][]const u8{
        "rm",
        "rmdir",
        "mv",
        "cp",
        "mkdir",
        "touch",
        "chmod",
        "chown",
        "chgrp",
        "ln",
        "tee",
        "truncate",
        "dd",
        "shred",
        "sudo",
        "su",
        "kill",
        "pkill",
        "killall",
        "reboot",
        "shutdown",
        "vi",
        "vim",
        "nano",
        "emacs",
        "code",
        "subl",
    };
    for (destructive_words) |word| {
        if (containsAsciiWordIgnoreCase(command, word)) return true;
    }

    if (containsCommandAction(command, "npm", &.{ "install", "uninstall", "update", "ci", "link", "publish" })) return true;
    if (containsCommandAction(command, "yarn", &.{ "add", "remove", "install", "publish" })) return true;
    if (containsCommandAction(command, "pnpm", &.{ "add", "remove", "install", "publish" })) return true;
    if (containsCommandAction(command, "pip", &.{ "install", "uninstall" })) return true;
    if (containsCommandAction(command, "brew", &.{ "install", "uninstall", "upgrade" })) return true;
    if (containsCommandAction(command, "systemctl", &.{ "start", "stop", "restart", "enable", "disable" })) return true;

    if (containsAptAction(command)) return true;
    if (containsGitWriteAction(command)) return true;
    if (containsServiceWriteAction(command)) return true;

    return false;
}

fn hasSafePattern(command: []const u8) bool {
    const trimmed = trimLeftAscii(command);
    const simple_safe = [_][]const u8{
        "cat",
        "head",
        "tail",
        "less",
        "more",
        "grep",
        "find",
        "ls",
        "pwd",
        "echo",
        "printf",
        "wc",
        "sort",
        "uniq",
        "diff",
        "file",
        "stat",
        "du",
        "df",
        "tree",
        "which",
        "whereis",
        "type",
        "env",
        "printenv",
        "uname",
        "whoami",
        "id",
        "date",
        "cal",
        "uptime",
        "ps",
        "top",
        "htop",
        "free",
        "jq",
        "awk",
        "rg",
        "fd",
        "bat",
        "eza",
    };
    for (simple_safe) |word| {
        if (startsWithAsciiWord(trimmed, word)) return true;
    }

    if (startsWithGitRead(trimmed)) return true;
    if (startsWithCommandAction(trimmed, "npm", &.{ "list", "ls", "view", "info", "search", "outdated", "audit" })) return true;
    if (startsWithCommandAction(trimmed, "yarn", &.{ "list", "info", "why", "audit" })) return true;
    if (startsWithWords(trimmed, "node", "--version")) return true;
    if (startsWithWords(trimmed, "python", "--version")) return true;
    if (startsWithIgnoreCase(trimmed, "curl") and trimmed.len > "curl".len and std.ascii.isWhitespace(trimmed["curl".len])) return true;
    if (startsWithWgetStdout(trimmed)) return true;
    if (startsWithWords(trimmed, "sed", "-n")) return true;
    return false;
}

fn hasBlockedRedirection(command: []const u8) bool {
    for (command, 0..) |byte, index| {
        if (byte != '>') continue;
        const next_is_gt = index + 1 < command.len and command[index + 1] == '>';
        const previous_is_lt = index > 0 and command[index - 1] == '<';
        if (next_is_gt or !previous_is_lt) return true;
    }
    return false;
}

fn containsAptAction(command: []const u8) bool {
    var index: usize = 0;
    while (nextAsciiWordIgnoreCase(command, "apt", index)) |match| {
        if (match.end < command.len and command[match.end] == '-') {
            if (match.end + "-get".len <= command.len and
                std.ascii.eqlIgnoreCase(command[match.end .. match.end + "-get".len], "-get"))
            {
                if (hasFollowingAction(command, match.end + "-get".len, &.{ "install", "remove", "purge", "update", "upgrade" })) return true;
            }
        } else if (hasFollowingAction(command, match.end, &.{ "install", "remove", "purge", "update", "upgrade" })) {
            return true;
        }
        index = match.end;
    }
    return false;
}

fn containsGitWriteAction(command: []const u8) bool {
    var index: usize = 0;
    while (nextAsciiWordIgnoreCase(command, "git", index)) |match| {
        var cursor = skipAsciiWhitespace(command, match.end);
        const action_start = cursor;
        while (cursor < command.len and !std.ascii.isWhitespace(command[cursor])) : (cursor += 1) {}
        const action = command[action_start..cursor];

        const write_actions = [_][]const u8{
            "add",
            "commit",
            "push",
            "pull",
            "merge",
            "rebase",
            "reset",
            "checkout",
            "stash",
            "cherry-pick",
            "revert",
            "tag",
            "init",
            "clone",
        };
        for (write_actions) |write_action| {
            if (std.ascii.eqlIgnoreCase(action, write_action)) return true;
        }
        if (std.ascii.eqlIgnoreCase(action, "branch")) {
            const flag_start = skipAsciiWhitespace(command, cursor);
            if (flag_start + 2 <= command.len and command[flag_start] == '-' and
                (command[flag_start + 1] == 'd' or command[flag_start + 1] == 'D'))
            {
                return true;
            }
        }

        index = match.end;
    }
    return false;
}

fn containsServiceWriteAction(command: []const u8) bool {
    var index: usize = 0;
    while (nextAsciiWordIgnoreCase(command, "service", index)) |match| {
        var cursor = skipAsciiWhitespace(command, match.end);
        while (cursor < command.len and !std.ascii.isWhitespace(command[cursor])) : (cursor += 1) {}
        if (hasFollowingAction(command, cursor, &.{ "start", "stop", "restart" })) return true;
        index = match.end;
    }
    return false;
}

fn containsCommandAction(command: []const u8, command_word: []const u8, actions: []const []const u8) bool {
    var index: usize = 0;
    while (nextAsciiWordIgnoreCase(command, command_word, index)) |match| {
        if (hasFollowingAction(command, match.end, actions)) return true;
        index = match.end;
    }
    return false;
}

fn startsWithCommandAction(command: []const u8, command_word: []const u8, actions: []const []const u8) bool {
    if (!startsWithAsciiWordIgnoreCase(command, command_word)) return false;
    return hasFollowingAction(command, command_word.len, actions);
}

fn hasFollowingAction(command: []const u8, offset: usize, actions: []const []const u8) bool {
    const cursor = skipAsciiWhitespace(command, offset);
    if (cursor == offset or cursor >= command.len) return false;
    for (actions) |action| {
        if (cursor + action.len <= command.len and std.ascii.eqlIgnoreCase(command[cursor .. cursor + action.len], action)) {
            return true;
        }
    }
    return false;
}

fn startsWithGitRead(command: []const u8) bool {
    if (!startsWithAsciiWordIgnoreCase(command, "git")) return false;
    const rest = trimLeftAscii(command["git".len..]);
    if (startsWithIgnoreCase(rest, "ls-")) return true;
    if (startsWithIgnoreCase(rest, "config")) {
        const after_config = trimLeftAscii(rest["config".len..]);
        return startsWithIgnoreCase(after_config, "--get");
    }
    const actions = [_][]const u8{ "status", "log", "diff", "show", "branch", "remote" };
    for (actions) |action| {
        if (startsWithIgnoreCase(rest, action)) return true;
    }
    return false;
}

fn startsWithWgetStdout(command: []const u8) bool {
    if (!startsWithAsciiWordIgnoreCase(command, "wget")) return false;
    var rest = command["wget".len..];
    const trimmed = trimLeftAscii(rest);
    if (trimmed.len == rest.len) return false;
    rest = trimmed;
    if (!startsWithIgnoreCase(rest, "-O")) return false;
    rest = rest["-O".len..];
    rest = trimLeftAscii(rest);
    return std.mem.startsWith(u8, rest, "-");
}

fn startsWithWords(command: []const u8, first: []const u8, second: []const u8) bool {
    if (!startsWithAsciiWordIgnoreCase(command, first)) return false;
    const rest = trimLeftAscii(command[first.len..]);
    if (rest.len == command[first.len..].len) return false;
    return startsWithIgnoreCase(rest, second);
}

const WordMatch = struct {
    start: usize,
    end: usize,
};

fn nextAsciiWordIgnoreCase(haystack: []const u8, needle: []const u8, start: usize) ?WordMatch {
    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) continue;
        if (index > 0 and isWordByte(haystack[index - 1])) continue;
        const end = index + needle.len;
        if (end < haystack.len and isWordByte(haystack[end])) continue;
        return .{ .start = index, .end = end };
    }
    return null;
}

fn containsAsciiWordIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return nextAsciiWordIgnoreCase(haystack, needle, 0) != null;
}

fn startsWithAsciiWord(value: []const u8, word: []const u8) bool {
    if (value.len < word.len) return false;
    if (!std.mem.eql(u8, value[0..word.len], word)) return false;
    return value.len == word.len or !isWordByte(value[word.len]);
}

fn startsWithAsciiWordIgnoreCase(value: []const u8, word: []const u8) bool {
    if (value.len < word.len) return false;
    if (!std.ascii.eqlIgnoreCase(value[0..word.len], word)) return false;
    return value.len == word.len or !isWordByte(value[word.len]);
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn skipAsciiWhitespace(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len and std.ascii.isWhitespace(value[index])) : (index += 1) {}
    return index;
}

fn trimLeftAscii(value: []const u8) []const u8 {
    return value[skipAsciiWhitespace(value, 0)..];
}

fn stripLeadingActionWord(text: []const u8) []const u8 {
    const action_words = [_][]const u8{
        "use",
        "run",
        "execute",
        "create",
        "write",
        "read",
        "check",
        "verify",
        "update",
        "modify",
        "add",
        "remove",
        "delete",
        "install",
    };
    for (action_words) |word| {
        if (text.len < word.len) continue;
        if (!std.ascii.eqlIgnoreCase(text[0..word.len], word)) continue;
        if (text.len == word.len or !std.ascii.isWhitespace(text[word.len])) continue;

        var cursor = skipAsciiWhitespace(text, word.len);
        if (cursor + "the".len <= text.len and std.ascii.eqlIgnoreCase(text[cursor .. cursor + "the".len], "the") and
            (cursor + "the".len == text.len or std.ascii.isWhitespace(text[cursor + "the".len])))
        {
            cursor = skipAsciiWhitespace(text, cursor + "the".len);
        }
        return text[cursor..];
    }
    return text;
}

fn findPlanSectionStart(message: []const u8) ?usize {
    var line_start: usize = 0;
    while (line_start <= message.len) {
        const newline = std.mem.indexOfScalarPos(u8, message, line_start, '\n') orelse message.len;
        const line = std.mem.trim(u8, message[line_start..newline], " \t\r");
        if (isPlanHeader(line)) return if (newline < message.len) newline + 1 else message.len;
        if (newline == message.len) break;
        line_start = newline + 1;
    }
    return null;
}

fn isPlanHeader(line: []const u8) bool {
    var value = line;
    var removed_left: usize = 0;
    while (removed_left < 2 and value.len > 0 and value[0] == '*') : (removed_left += 1) {
        value = value[1..];
    }
    var removed_right: usize = 0;
    while (removed_right < 2 and value.len > 0 and value[value.len - 1] == '*') : (removed_right += 1) {
        value = value[0 .. value.len - 1];
    }
    return std.ascii.eqlIgnoreCase(value, "Plan:");
}

fn parseNumberedPlanLine(line: []const u8) ?[]const u8 {
    const trimmed = trimLeftAscii(line);
    var cursor: usize = 0;
    while (cursor < trimmed.len and std.ascii.isDigit(trimmed[cursor])) : (cursor += 1) {}
    if (cursor == 0 or cursor >= trimmed.len) return null;
    if (trimmed[cursor] != '.' and trimmed[cursor] != ')') return null;
    cursor += 1;
    if (cursor >= trimmed.len or !std.ascii.isWhitespace(trimmed[cursor])) return null;
    cursor = skipAsciiWhitespace(trimmed, cursor);
    var stars: usize = 0;
    while (stars < 2 and cursor < trimmed.len and trimmed[cursor] == '*') : (stars += 1) {
        cursor += 1;
    }
    const text_start = cursor;
    while (cursor < trimmed.len and trimmed[cursor] != '*') : (cursor += 1) {}
    return trimmed[text_start..cursor];
}

fn expectClean(input: []const u8, expected: []const u8) !void {
    const actual = try cleanStepTextAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectSafe(input: []const u8, expected: bool) !void {
    try std.testing.expectEqual(expected, isSafeCommand(input));
}

fn expectTodoItems(message: []const u8, expected: []const []const u8) !void {
    var items = try extractTodoItemsAlloc(std.testing.allocator, message);
    defer deinitTodoItems(std.testing.allocator, &items);

    try std.testing.expectEqual(expected.len, items.items.len);
    for (expected, items.items, 0..) |expected_text, item, index| {
        try std.testing.expectEqual(index + 1, item.step);
        try std.testing.expectEqualStrings(expected_text, item.text);
        try std.testing.expect(!item.completed);
    }
}

fn expectDoneSteps(message: []const u8, expected: []const usize) !void {
    const actual = try extractDoneStepsAlloc(std.testing.allocator, message);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(usize, expected, actual);
}

// Ported from packages/coding-agent/test/plan-mode-utils.test.ts.
test "plan-mode isSafeCommand allows read-only commands" {
    try expectSafe("ls -la", true);
    try expectSafe("cat file.txt", true);
    try expectSafe("head -n 10 file.txt", true);
    try expectSafe("tail -f log.txt", true);
    try expectSafe("grep pattern file", true);
    try expectSafe("find . -name '*.ts'", true);
    try expectSafe("git status", true);
    try expectSafe("git log --oneline", true);
    try expectSafe("git diff", true);
    try expectSafe("git branch", true);
    try expectSafe("npm list", true);
    try expectSafe("npm outdated", true);
    try expectSafe("yarn info react", true);
    try expectSafe("pwd", true);
    try expectSafe("echo hello", true);
    try expectSafe("wc -l file.txt", true);
    try expectSafe("du -sh .", true);
    try expectSafe("df -h", true);
}

test "plan-mode isSafeCommand blocks destructive commands" {
    try expectSafe("rm file.txt", false);
    try expectSafe("rm -rf dir", false);
    try expectSafe("mv old new", false);
    try expectSafe("cp src dst", false);
    try expectSafe("mkdir newdir", false);
    try expectSafe("touch newfile", false);
    try expectSafe("git add .", false);
    try expectSafe("git commit -m 'msg'", false);
    try expectSafe("git push", false);
    try expectSafe("git checkout main", false);
    try expectSafe("git reset --hard", false);
    try expectSafe("npm install lodash", false);
    try expectSafe("yarn add react", false);
    try expectSafe("pip install requests", false);
    try expectSafe("brew install node", false);
    try expectSafe("echo hello > file.txt", false);
    try expectSafe("cat foo >> bar", false);
    try expectSafe(">file.txt", false);
    try expectSafe("sudo rm -rf /", false);
    try expectSafe("kill -9 1234", false);
    try expectSafe("reboot", false);
    try expectSafe("vim file.txt", false);
    try expectSafe("nano file.txt", false);
    try expectSafe("code .", false);
}

test "plan-mode isSafeCommand handles edge cases" {
    try expectSafe("unknown-command", false);
    try expectSafe("my-script.sh", false);
    try expectSafe("  ls -la", true);
    try expectSafe("  rm file", false);
}

test "plan-mode cleanStepText removes markdown and action words" {
    try expectClean("**bold text**", "Bold text");
    try expectClean("*italic text*", "Italic text");
    try expectClean("run `npm install`", "Npm install");
    try expectClean("check the `config.json` file", "Config.json file");
    try expectClean("Create the new file", "New file");
    try expectClean("Run the tests", "Tests");
    try expectClean("Check the status", "Status");
    try expectClean("update config", "Config");
    try expectClean("multiple   spaces   here", "Multiple spaces here");
}

test "plan-mode cleanStepText truncates long text" {
    const long_text = "This is a very long step description that exceeds the maximum allowed length for display";
    const result = try cleanStepTextAlloc(std.testing.allocator, long_text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 50), result.len);
    try std.testing.expect(std.mem.endsWith(u8, result, "..."));
}

test "plan-mode extractTodoItems parses plan sections" {
    try expectTodoItems(
        \\Here's what we'll do:
        \\
        \\Plan:
        \\1. First step here
        \\2. Second step here
        \\3. Third step here
    , &.{ "First step here", "Second step here", "Third step here" });

    try expectTodoItems(
        \\**Plan:**
        \\1. Do something
    , &.{"Do something"});

    try expectTodoItems(
        \\Plan:
        \\1) First item
        \\2) Second item
    , &.{ "First item", "Second item" });

    try expectTodoItems(
        \\Here are some steps:
        \\1. First step
        \\2. Second step
    , &.{});
}

test "plan-mode extractTodoItems filters invalid items" {
    var short_items = try extractTodoItemsAlloc(std.testing.allocator,
        \\Plan:
        \\1. OK
        \\2. This is a proper step
    );
    defer deinitTodoItems(std.testing.allocator, &short_items);
    try std.testing.expectEqual(@as(usize, 1), short_items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, short_items.items[0].text, "proper") != null);

    try expectTodoItems(
        \\Plan:
        \\1. `npm install`
        \\2. Run the build process
    , &.{"Build process"});
}

test "plan-mode extractDoneSteps parses DONE markers" {
    try expectDoneSteps("I've completed the first step [DONE:1]", &.{1});
    try expectDoneSteps("Did steps [DONE:1] and [DONE:2] and [DONE:3]", &.{ 1, 2, 3 });
    try expectDoneSteps("[done:1] [DONE:2] [Done:3]", &.{ 1, 2, 3 });
    try expectDoneSteps("No markers here", &.{});
    try expectDoneSteps("[DONE:abc] [DONE:] [DONE:1]", &.{1});
}

test "plan-mode markCompletedSteps marks matching todos and counts markers" {
    var items = [_]TodoItem{
        .{ .step = 1, .text = @constCast("First"), .completed = false },
        .{ .step = 2, .text = @constCast("Second"), .completed = false },
        .{ .step = 3, .text = @constCast("Third"), .completed = false },
    };

    const count = markCompletedSteps("[DONE:1] [DONE:3]", &items);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(items[0].completed);
    try std.testing.expect(!items[1].completed);
    try std.testing.expect(items[2].completed);
}

test "plan-mode markCompletedSteps handles misses and completed items" {
    var first = [_]TodoItem{.{ .step = 1, .text = @constCast("First"), .completed = false }};
    try std.testing.expectEqual(@as(usize, 1), markCompletedSteps("[DONE:1]", &first));
    try std.testing.expectEqual(@as(usize, 0), markCompletedSteps("no markers", &first));

    var missing = [_]TodoItem{.{ .step = 1, .text = @constCast("First"), .completed = false }};
    try std.testing.expectEqual(@as(usize, 1), markCompletedSteps("[DONE:99]", &missing));
    try std.testing.expect(!missing[0].completed);

    var already = [_]TodoItem{.{ .step = 1, .text = @constCast("First"), .completed = true }};
    _ = markCompletedSteps("[DONE:1]", &already);
    try std.testing.expect(already[0].completed);
}
