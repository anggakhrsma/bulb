const std = @import("std");
const ai = @import("bulb_ai");
const tui = @import("bulb_tui");

const DIM = "\x1b[2m";
const RESET = "\x1b[0m";

pub const ContextUsage = struct {
    context_window: u64,
    percent: ?f64,
};

pub const FooterStatus = struct {
    key: []const u8,
    text: []const u8,
};

pub const FooterDataSnapshot = struct {
    git_branch: ?[]const u8 = null,
    extension_statuses: []const FooterStatus = &.{},
    available_provider_count: usize = 0,
};

pub const FooterSessionSnapshot = struct {
    cwd: []const u8,
    home_dir: ?[]const u8 = null,
    session_name: []const u8 = "",
    model: ?ai.Model = null,
    thinking_level: ai.ThinkingLevel = .off,
    context_usage: ?ContextUsage = null,
    assistant_usages: []const ai.Usage = &.{},
    using_oauth_subscription: bool = false,
};

pub const FooterComponent = struct {
    session: FooterSessionSnapshot,
    footer_data: FooterDataSnapshot,
    auto_compact_enabled: bool = true,

    pub fn init(session: FooterSessionSnapshot, footer_data: FooterDataSnapshot) FooterComponent {
        return .{
            .session = session,
            .footer_data = footer_data,
        };
    }

    pub fn setSession(self: *FooterComponent, session: FooterSessionSnapshot) void {
        self.session = session;
    }

    pub fn setAutoCompactEnabled(self: *FooterComponent, enabled: bool) void {
        self.auto_compact_enabled = enabled;
    }

    pub fn invalidate(_: *FooterComponent) void {}

    pub fn dispose(_: *FooterComponent) void {}

    pub fn render(self: *const FooterComponent, allocator: std.mem.Allocator, width: usize) ![][]u8 {
        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |line| allocator.free(line);
            lines.deinit(allocator);
        }

        const pwd = try self.renderPwdLineAlloc(allocator, width);
        try lines.append(allocator, pwd);

        const stats = try self.renderStatsLineAlloc(allocator, width);
        try lines.append(allocator, stats);

        if (self.footer_data.extension_statuses.len > 0) {
            const status = try self.renderStatusLineAlloc(allocator, width);
            try lines.append(allocator, status);
        }

        return lines.toOwnedSlice(allocator);
    }

    fn renderPwdLineAlloc(self: *const FooterComponent, allocator: std.mem.Allocator, width: usize) ![]u8 {
        var pwd = try formatCwdForFooterAlloc(allocator, self.session.cwd, self.session.home_dir);
        defer allocator.free(pwd);

        if (self.footer_data.git_branch) |branch| {
            const next = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ pwd, branch });
            allocator.free(pwd);
            pwd = next;
        }

        if (self.session.session_name.len > 0) {
            const next = try std.fmt.allocPrint(allocator, "{s} • {s}", .{ pwd, self.session.session_name });
            allocator.free(pwd);
            pwd = next;
        }

        const dimmed = try dimAlloc(allocator, pwd);
        defer allocator.free(dimmed);
        const dim_ellipsis = try dimAlloc(allocator, "...");
        defer allocator.free(dim_ellipsis);
        return tui.truncateToWidth(allocator, dimmed, width, dim_ellipsis, false);
    }

    fn renderStatsLineAlloc(self: *const FooterComponent, allocator: std.mem.Allocator, width: usize) ![]u8 {
        const totals = totalUsage(self.session.assistant_usages);
        const stats_left = try self.buildStatsLeftAlloc(allocator, totals, width);
        defer allocator.free(stats_left);

        const stats_left_width = tui.visibleWidth(stats_left);
        const right_without_provider = try self.buildRightSideWithoutProviderAlloc(allocator);
        defer allocator.free(right_without_provider);

        var right_side = try allocator.dupe(u8, right_without_provider);
        defer allocator.free(right_side);
        if (self.footer_data.available_provider_count > 1) {
            if (self.session.model) |model| {
                const with_provider = try std.fmt.allocPrint(allocator, "({s}) {s}", .{ model.provider, right_without_provider });
                defer allocator.free(with_provider);
                if (stats_left_width + 2 + tui.visibleWidth(with_provider) <= width) {
                    allocator.free(right_side);
                    right_side = try allocator.dupe(u8, with_provider);
                }
            }
        }

        const right_width = tui.visibleWidth(right_side);
        const stats_line = try buildStatsLineAlloc(allocator, stats_left, stats_left_width, right_side, right_width, width);
        defer allocator.free(stats_line);

        const stats_left_len = @min(stats_left.len, stats_line.len);
        const dim_stats = try dimAlloc(allocator, stats_line[0..stats_left_len]);
        defer allocator.free(dim_stats);
        const dim_remainder = try dimAlloc(allocator, stats_line[stats_left_len..]);
        defer allocator.free(dim_remainder);
        return std.mem.concat(allocator, u8, &.{ dim_stats, dim_remainder });
    }

    fn buildStatsLeftAlloc(
        self: *const FooterComponent,
        allocator: std.mem.Allocator,
        totals: ai.Usage,
        width: usize,
    ) ![]u8 {
        var stats: std.ArrayList(u8) = .empty;
        defer stats.deinit(allocator);

        try appendTokenStat(allocator, &stats, "↑", totals.input);
        try appendTokenStat(allocator, &stats, "↓", totals.output);
        try appendTokenStat(allocator, &stats, "R", totals.cache_read);
        try appendTokenStat(allocator, &stats, "W", totals.cache_write);

        if (totals.cost.total != 0 or self.session.using_oauth_subscription) {
            const cost = if (self.session.using_oauth_subscription)
                try std.fmt.allocPrint(allocator, "${d:.3} (sub)", .{totals.cost.total})
            else
                try std.fmt.allocPrint(allocator, "${d:.3}", .{totals.cost.total});
            defer allocator.free(cost);
            try appendStatsPart(allocator, &stats, cost);
        }

        const context = self.contextUsage();
        const context_window = if (context) |value| value.context_window else if (self.session.model) |model| model.context_window else 0;
        const context_window_text = try formatTokensAlloc(allocator, context_window);
        defer allocator.free(context_window_text);
        const auto_indicator = if (self.auto_compact_enabled) " (auto)" else "";
        const context_part = if (context) |value| blk: {
            if (value.percent) |percent| {
                break :blk try std.fmt.allocPrint(allocator, "{d:.1}%/{s}{s}", .{ percent, context_window_text, auto_indicator });
            }
            break :blk try std.fmt.allocPrint(allocator, "?/{s}{s}", .{ context_window_text, auto_indicator });
        } else try std.fmt.allocPrint(allocator, "0.0%/{s}{s}", .{ context_window_text, auto_indicator });
        defer allocator.free(context_part);
        try appendStatsPart(allocator, &stats, context_part);

        const raw = try stats.toOwnedSlice(allocator);
        if (tui.visibleWidth(raw) <= width) return raw;
        defer allocator.free(raw);
        return tui.truncateToWidth(allocator, raw, width, "...", false);
    }

    fn contextUsage(self: *const FooterComponent) ?ContextUsage {
        if (self.session.context_usage) |context| return context;
        if (self.session.model) |model| {
            return .{ .context_window = model.context_window, .percent = 0 };
        }
        return null;
    }

    fn buildRightSideWithoutProviderAlloc(self: *const FooterComponent, allocator: std.mem.Allocator) ![]u8 {
        const model = self.session.model orelse return allocator.dupe(u8, "no-model");
        if (!model.reasoning) return allocator.dupe(u8, model.id);

        const thinking = thinkingLevelText(self.session.thinking_level);
        if (self.session.thinking_level == .off) {
            return std.fmt.allocPrint(allocator, "{s} • thinking off", .{model.id});
        }
        return std.fmt.allocPrint(allocator, "{s} • {s}", .{ model.id, thinking });
    }

    fn renderStatusLineAlloc(self: *const FooterComponent, allocator: std.mem.Allocator, width: usize) ![]u8 {
        const sorted = try allocator.dupe(FooterStatus, self.footer_data.extension_statuses);
        defer allocator.free(sorted);
        std.mem.sort(FooterStatus, sorted, {}, compareFooterStatusByKey);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        for (sorted) |status| {
            const sanitized = try sanitizeStatusTextAlloc(allocator, status.text);
            defer allocator.free(sanitized);
            if (sanitized.len == 0) continue;
            if (line.items.len > 0) try line.append(allocator, ' ');
            try line.appendSlice(allocator, sanitized);
        }

        const raw = try line.toOwnedSlice(allocator);
        defer allocator.free(raw);
        const dim_ellipsis = try dimAlloc(allocator, "...");
        defer allocator.free(dim_ellipsis);
        return tui.truncateToWidth(allocator, raw, width, dim_ellipsis, false);
    }
};

pub fn formatCwdForFooterAlloc(allocator: std.mem.Allocator, cwd: []const u8, home: ?[]const u8) ![]u8 {
    const home_value = home orelse return allocator.dupe(u8, cwd);
    if (home_value.len == 0) return allocator.dupe(u8, cwd);

    const resolved_cwd = std.fs.path.resolve(allocator, &.{cwd}) catch return allocator.dupe(u8, cwd);
    defer allocator.free(resolved_cwd);
    const resolved_home = std.fs.path.resolve(allocator, &.{home_value}) catch return allocator.dupe(u8, cwd);
    defer allocator.free(resolved_home);
    const relative = std.fs.path.relative(allocator, ".", null, resolved_home, resolved_cwd) catch return allocator.dupe(u8, cwd);
    defer allocator.free(relative);

    const inside_home =
        relative.len == 0 or
        (!std.mem.eql(u8, relative, "..") and
            !std.mem.startsWith(u8, relative, ".." ++ std.fs.path.sep_str) and
            !std.fs.path.isAbsolute(relative));

    if (!inside_home) return allocator.dupe(u8, cwd);
    if (relative.len == 0) return allocator.dupe(u8, "~");
    return std.fmt.allocPrint(allocator, "~{s}{s}", .{ std.fs.path.sep_str, relative });
}

pub fn sanitizeStatusTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    var previous_space = true;
    for (text) |byte| {
        const normalized: u8 = switch (byte) {
            '\r', '\n', '\t' => ' ',
            else => byte,
        };
        if (normalized == ' ') {
            if (!previous_space) try output.append(allocator, ' ');
            previous_space = true;
        } else {
            try output.append(allocator, normalized);
            previous_space = false;
        }
    }
    if (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        output.items.len -= 1;
    }
    return output.toOwnedSlice(allocator);
}

pub fn formatTokensAlloc(allocator: std.mem.Allocator, count: u64) ![]u8 {
    if (count < 1000) return std.fmt.allocPrint(allocator, "{d}", .{count});
    if (count < 10_000) return std.fmt.allocPrint(allocator, "{d:.1}k", .{@as(f64, @floatFromInt(count)) / 1000.0});
    if (count < 1_000_000) return std.fmt.allocPrint(allocator, "{d}k", .{(count + 500) / 1000});
    if (count < 10_000_000) return std.fmt.allocPrint(allocator, "{d:.1}M", .{@as(f64, @floatFromInt(count)) / 1_000_000.0});
    return std.fmt.allocPrint(allocator, "{d}M", .{(count + 500_000) / 1_000_000});
}

fn appendTokenStat(allocator: std.mem.Allocator, stats: *std.ArrayList(u8), prefix: []const u8, count: u64) !void {
    if (count == 0) return;
    const tokens = try formatTokensAlloc(allocator, count);
    defer allocator.free(tokens);
    const part = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, tokens });
    defer allocator.free(part);
    try appendStatsPart(allocator, stats, part);
}

fn appendStatsPart(allocator: std.mem.Allocator, stats: *std.ArrayList(u8), part: []const u8) !void {
    if (part.len == 0) return;
    if (stats.items.len > 0) try stats.append(allocator, ' ');
    try stats.appendSlice(allocator, part);
}

fn buildStatsLineAlloc(
    allocator: std.mem.Allocator,
    stats_left: []const u8,
    stats_left_width: usize,
    right_side: []const u8,
    right_width: usize,
    width: usize,
) ![]u8 {
    const min_padding: usize = 2;
    if (stats_left_width + min_padding + right_width <= width) {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, stats_left);
        try appendSpaces(allocator, &line, width - stats_left_width - right_width);
        try line.appendSlice(allocator, right_side);
        return line.toOwnedSlice(allocator);
    }

    const available_for_right = if (width > stats_left_width + min_padding)
        width - stats_left_width - min_padding
    else
        0;
    if (available_for_right > 0) {
        const truncated_right = try tui.truncateToWidth(allocator, right_side, available_for_right, "", false);
        defer allocator.free(truncated_right);
        const truncated_right_width = tui.visibleWidth(truncated_right);

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, stats_left);
        try appendSpaces(allocator, &line, width - stats_left_width - truncated_right_width);
        try line.appendSlice(allocator, truncated_right);
        return line.toOwnedSlice(allocator);
    }

    return allocator.dupe(u8, stats_left);
}

fn appendSpaces(allocator: std.mem.Allocator, output: *std.ArrayList(u8), count: usize) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) try output.append(allocator, ' ');
}

fn dimAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ DIM, text, RESET });
}

fn totalUsage(usages: []const ai.Usage) ai.Usage {
    var total: ai.Usage = .{};
    for (usages) |usage| {
        total.input += usage.input;
        total.output += usage.output;
        total.cache_read += usage.cache_read;
        total.cache_write += usage.cache_write;
        total.cost.input += usage.cost.input;
        total.cost.output += usage.cost.output;
        total.cost.cache_read += usage.cost.cache_read;
        total.cost.cache_write += usage.cost.cache_write;
        total.cost.total += usage.cost.total;
    }
    return total;
}

fn thinkingLevelText(level: ai.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn compareFooterStatusByKey(_: void, a: FooterStatus, b: FooterStatus) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn repeatedTextAlloc(allocator: std.mem.Allocator, text: []const u8, count: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var index: usize = 0;
    while (index < count) : (index += 1) try output.appendSlice(allocator, text);
    return output.toOwnedSlice(allocator);
}

fn createTestModel(id: []const u8, provider: []const u8, reasoning: bool) ai.Model {
    return .{
        .id = id,
        .name = id,
        .api = "openai-responses",
        .provider = provider,
        .base_url = "https://example.test",
        .reasoning = reasoning,
        .context_window = 200_000,
    };
}

test "formatCwdForFooter does not abbreviate sibling paths that share the home prefix" {
    const allocator = std.testing.allocator;
    const formatted = try formatCwdForFooterAlloc(allocator, "/home/user2", "/home/user");
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("/home/user2", formatted);
}

test "formatCwdForFooter abbreviates the home directory and descendants" {
    const allocator = std.testing.allocator;
    const home = try formatCwdForFooterAlloc(allocator, "/home/user", "/home/user");
    defer allocator.free(home);
    try std.testing.expectEqualStrings("~", home);

    const child = try formatCwdForFooterAlloc(allocator, "/home/user/project", "/home/user");
    defer allocator.free(child);
    try std.testing.expectEqualStrings("~/project", child);
}

test "FooterComponent keeps all lines within width for wide session names" {
    const allocator = std.testing.allocator;
    const session_name = try repeatedTextAlloc(allocator, "한글", 30);
    defer allocator.free(session_name);
    const model = createTestModel("test-model", "test", false);
    const footer = FooterComponent.init(.{
        .cwd = "/tmp/project",
        .home_dir = "/tmp",
        .session_name = session_name,
        .model = model,
        .context_usage = .{ .context_window = 200_000, .percent = 12.3 },
    }, .{
        .git_branch = "main",
        .available_provider_count = 1,
    });

    const lines = try footer.render(allocator, 93);
    defer tui.freeRenderedLines(allocator, lines);
    for (lines) |line| try std.testing.expect(tui.visibleWidth(line) <= 93);
}

test "FooterComponent keeps stats line within width for wide model and provider names" {
    const allocator = std.testing.allocator;
    const model_id = try repeatedTextAlloc(allocator, "模", 30);
    defer allocator.free(model_id);
    const usage: ai.Usage = .{
        .input = 12_345,
        .output = 6_789,
        .cost = .{ .total = 1.234 },
    };
    const model = createTestModel(model_id, "공급자", true);
    const footer = FooterComponent.init(.{
        .cwd = "/tmp/project",
        .home_dir = "/tmp",
        .model = model,
        .thinking_level = .high,
        .context_usage = .{ .context_window = 200_000, .percent = 12.3 },
        .assistant_usages = &.{usage},
    }, .{
        .git_branch = "main",
        .available_provider_count = 2,
    });

    const lines = try footer.render(allocator, 60);
    defer tui.freeRenderedLines(allocator, lines);
    for (lines) |line| try std.testing.expect(tui.visibleWidth(line) <= 60);
}

test "FooterComponent sanitizes and sorts extension statuses" {
    const allocator = std.testing.allocator;
    const statuses = [_]FooterStatus{
        .{ .key = "z", .text = "zeta\nstatus" },
        .{ .key = "a", .text = " alpha\t\tstatus " },
    };
    const footer = FooterComponent.init(.{
        .cwd = "/tmp/project",
        .home_dir = "/tmp",
        .context_usage = .{ .context_window = 0, .percent = 0 },
    }, .{ .extension_statuses = &statuses });

    const lines = try footer.render(allocator, 80);
    defer tui.freeRenderedLines(allocator, lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("alpha status zeta status", lines[2]);
}
