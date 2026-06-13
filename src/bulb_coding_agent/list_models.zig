const std = @import("std");

const ai = @import("bulb_ai");
const tui = @import("bulb_tui");
const auth_guidance = @import("auth_guidance.zig");
const auth_storage = @import("auth_storage.zig");
const config_value = @import("resolve_config_value.zig");
const model_registry = @import("model_registry.zig");

pub fn writeListModels(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    registry: *model_registry.ModelRegistry,
    search_pattern: ?[]const u8,
) !void {
    if (registry.getError()) |load_error| {
        try stderr.print("Warning: errors loading models.json:\n{s}\n", .{load_error});
    }

    const available = try registry.getAvailableAlloc(allocator);
    defer allocator.free(available);

    if (available.len == 0) {
        const message = try auth_guidance.formatNoModelsAvailableMessageAlloc(allocator, io, environ);
        defer allocator.free(message);
        try stdout.print("{s}\n", .{message});
        return;
    }

    const filtered = if (search_pattern) |query|
        try filterModelsAlloc(allocator, available, query)
    else
        try allocator.dupe(*const ai.Model, available);
    defer allocator.free(filtered);

    if (filtered.len == 0) {
        try stdout.print("No models matching \"{s}\"\n", .{search_pattern.?});
        return;
    }

    std.mem.sort(*const ai.Model, filtered, {}, modelLessThan);
    try writeModelTable(allocator, stdout, filtered);
}

pub fn formatTokenCountBuf(buffer: *[32]u8, count: u64) ![]const u8 {
    if (count >= 1_000_000) {
        return formatScaledTokenCountBuf(buffer, count, 1_000_000, "M");
    }
    if (count >= 1_000) {
        return formatScaledTokenCountBuf(buffer, count, 1_000, "K");
    }
    return std.fmt.bufPrint(buffer, "{d}", .{count});
}

fn formatScaledTokenCountBuf(buffer: *[32]u8, count: u64, scale: u64, suffix: []const u8) ![]const u8 {
    const tenths: u128 = (@as(u128, count) * 10 + scale / 2) / scale;
    const whole = tenths / 10;
    const fraction = tenths % 10;
    if (fraction == 0) return std.fmt.bufPrint(buffer, "{d}{s}", .{ whole, suffix });
    return std.fmt.bufPrint(buffer, "{d}.{d}{s}", .{ whole, fraction, suffix });
}

const SearchCandidate = struct {
    model: *const ai.Model,
    search_text: []const u8,

    fn text(item: SearchCandidate) []const u8 {
        return item.search_text;
    }
};

fn filterModelsAlloc(
    allocator: std.mem.Allocator,
    models: []const *const ai.Model,
    query: []const u8,
) ![]*const ai.Model {
    var candidates: std.ArrayList(SearchCandidate) = .empty;
    defer {
        for (candidates.items) |candidate| allocator.free(candidate.search_text);
        candidates.deinit(allocator);
    }

    try candidates.ensureTotalCapacity(allocator, models.len);
    for (models) |model| {
        const search_text = try std.fmt.allocPrint(allocator, "{s} {s}", .{ model.provider, model.id });
        errdefer allocator.free(search_text);
        candidates.appendAssumeCapacity(.{ .model = model, .search_text = search_text });
    }

    const filtered_candidates = try tui.fuzzyFilter(allocator, SearchCandidate, candidates.items, query, SearchCandidate.text);
    defer allocator.free(filtered_candidates);

    const filtered = try allocator.alloc(*const ai.Model, filtered_candidates.len);
    for (filtered_candidates, 0..) |candidate, index| filtered[index] = candidate.model;
    return filtered;
}

fn modelLessThan(_: void, left: *const ai.Model, right: *const ai.Model) bool {
    const provider_order = std.mem.order(u8, left.provider, right.provider);
    if (provider_order == .lt) return true;
    if (provider_order == .gt) return false;
    return std.mem.order(u8, left.id, right.id) == .lt;
}

const Row = struct {
    provider: []const u8,
    model: []const u8,
    context_buffer: [32]u8 = undefined,
    context_len: usize = 0,
    max_out_buffer: [32]u8 = undefined,
    max_out_len: usize = 0,
    thinking: []const u8,
    images: []const u8,

    fn fromModel(model: *const ai.Model) !Row {
        var row = Row{
            .provider = model.provider,
            .model = model.id,
            .thinking = if (model.reasoning) "yes" else "no",
            .images = if (modelAcceptsImages(model.*)) "yes" else "no",
        };
        const context_text = try formatTokenCountBuf(&row.context_buffer, model.context_window);
        row.context_len = context_text.len;
        const max_out = try formatTokenCountBuf(&row.max_out_buffer, model.max_tokens);
        row.max_out_len = max_out.len;
        return row;
    }

    fn context(self: *const Row) []const u8 {
        return self.context_buffer[0..self.context_len];
    }

    fn maxOut(self: *const Row) []const u8 {
        return self.max_out_buffer[0..self.max_out_len];
    }
};

fn writeModelTable(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    models: []const *const ai.Model,
) !void {
    const headers = Row{
        .provider = "provider",
        .model = "model",
        .context_buffer = tokenBuffer("context"),
        .context_len = "context".len,
        .max_out_buffer = tokenBuffer("max-out"),
        .max_out_len = "max-out".len,
        .thinking = "thinking",
        .images = "images",
    };

    var rows = try allocator.alloc(Row, models.len);
    defer allocator.free(rows);
    for (models, 0..) |model, index| rows[index] = try Row.fromModel(model);

    var widths = ColumnWidths.fromHeader(headers);
    for (rows) |*row| widths.include(row);

    try writeRow(stdout, headers, widths);
    for (rows) |row| try writeRow(stdout, row, widths);
}

fn tokenBuffer(comptime value: []const u8) [32]u8 {
    var buffer: [32]u8 = undefined;
    @memcpy(buffer[0..value.len], value);
    return buffer;
}

const ColumnWidths = struct {
    provider: usize,
    model: usize,
    context: usize,
    max_out: usize,
    thinking: usize,
    images: usize,

    fn fromHeader(header: Row) ColumnWidths {
        return .{
            .provider = header.provider.len,
            .model = header.model.len,
            .context = header.context_len,
            .max_out = header.max_out_len,
            .thinking = header.thinking.len,
            .images = header.images.len,
        };
    }

    fn include(self: *ColumnWidths, row: *const Row) void {
        self.provider = @max(self.provider, row.provider.len);
        self.model = @max(self.model, row.model.len);
        self.context = @max(self.context, row.context().len);
        self.max_out = @max(self.max_out, row.maxOut().len);
        self.thinking = @max(self.thinking, row.thinking.len);
        self.images = @max(self.images, row.images.len);
    }
};

fn writeRow(stdout: *std.Io.Writer, row: Row, widths: ColumnWidths) !void {
    try writePadded(stdout, row.provider, widths.provider);
    try stdout.writeAll("  ");
    try writePadded(stdout, row.model, widths.model);
    try stdout.writeAll("  ");
    try writePadded(stdout, row.context(), widths.context);
    try stdout.writeAll("  ");
    try writePadded(stdout, row.maxOut(), widths.max_out);
    try stdout.writeAll("  ");
    try writePadded(stdout, row.thinking, widths.thinking);
    try stdout.writeAll("  ");
    try stdout.writeAll(row.images);
    try stdout.writeAll("\n");
}

fn writePadded(stdout: *std.Io.Writer, value: []const u8, width: usize) !void {
    try stdout.writeAll(value);
    var remaining = width - value.len;
    while (remaining > 0) : (remaining -= 1) try stdout.writeByte(' ');
}

fn modelAcceptsImages(model: ai.Model) bool {
    for (model.input) |kind| {
        if (std.mem.eql(u8, kind, "image")) return true;
    }
    return false;
}

const TestRegistryHarness = struct {
    allocator: std.mem.Allocator,
    oauth_registry: *ai.oauth.Registry,
    resolver: *config_value.Resolver,
    storage: *auth_storage.AuthStorage,
    registry: model_registry.ModelRegistry,

    fn init(
        allocator: std.mem.Allocator,
        env: *const std.process.Environ.Map,
        models_json_path: ?[]const u8,
    ) !TestRegistryHarness {
        const oauth_registry = try allocator.create(ai.oauth.Registry);
        errdefer allocator.destroy(oauth_registry);
        oauth_registry.* = try ai.oauth.Registry.init(allocator);
        errdefer oauth_registry.deinit();

        const resolver = try allocator.create(config_value.Resolver);
        errdefer allocator.destroy(resolver);
        resolver.* = config_value.Resolver.init(allocator, env);
        errdefer resolver.deinit();

        const storage = try allocator.create(auth_storage.AuthStorage);
        errdefer allocator.destroy(storage);
        storage.* = try auth_storage.AuthStorage.initMemory(allocator, env, oauth_registry, resolver);
        errdefer storage.deinit();

        var registry = try model_registry.ModelRegistry.init(allocator, storage, models_json_path);
        errdefer registry.deinit();

        return .{
            .allocator = allocator,
            .oauth_registry = oauth_registry,
            .resolver = resolver,
            .storage = storage,
            .registry = registry,
        };
    }

    fn deinit(self: *TestRegistryHarness) void {
        self.registry.deinit();
        self.storage.deinit();
        self.allocator.destroy(self.storage);
        self.resolver.deinit();
        self.allocator.destroy(self.resolver);
        self.oauth_registry.deinit();
        self.allocator.destroy(self.oauth_registry);
    }
};

const TestWriters = struct {
    stdout: std.Io.Writer.Allocating,
    stderr: std.Io.Writer.Allocating,

    fn init(allocator: std.mem.Allocator) TestWriters {
        return .{ .stdout = .init(allocator), .stderr = .init(allocator) };
    }

    fn deinit(self: *TestWriters) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }
};

test "list models formats available models table with fuzzy search" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/bulb");
    try env.put("ANTHROPIC_API_KEY", "test-key");

    var harness = try TestRegistryHarness.init(allocator, &env, null);
    defer harness.deinit();

    var writers = TestWriters.init(allocator);
    defer writers.deinit();

    try writeListModels(
        allocator,
        &writers.stdout.writer,
        &writers.stderr.writer,
        std.testing.io,
        &env,
        &harness.registry,
        "sonnet",
    );

    const output = writers.stdout.written();
    try std.testing.expect(std.mem.startsWith(u8, output, "provider   model"));
    try std.testing.expect(std.mem.indexOf(u8, output, "anthropic  claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "thinking  images") != null);
    try std.testing.expectEqual(@as(usize, 0), writers.stderr.written().len);
}

test "list models prints auth guidance when no providers are configured" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/bulb");
    try env.put("BULB_PACKAGE_DIR", "/opt/bulb");

    var harness = try TestRegistryHarness.init(allocator, &env, null);
    defer harness.deinit();

    var writers = TestWriters.init(allocator);
    defer writers.deinit();

    try writeListModels(
        allocator,
        &writers.stdout.writer,
        &writers.stderr.writer,
        std.testing.io,
        &env,
        &harness.registry,
        null,
    );

    try std.testing.expectEqualStrings(
        "No models available. Use /login to log into a provider via OAuth or API key. See:\n  /opt/bulb/docs/providers.md\n  /opt/bulb/docs/models.md\n",
        writers.stdout.written(),
    );
    try std.testing.expectEqual(@as(usize, 0), writers.stderr.written().len);
}

test "list models reports no fuzzy matches" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/bulb");
    try env.put("ANTHROPIC_API_KEY", "test-key");

    var harness = try TestRegistryHarness.init(allocator, &env, null);
    defer harness.deinit();

    var writers = TestWriters.init(allocator);
    defer writers.deinit();

    try writeListModels(
        allocator,
        &writers.stdout.writer,
        &writers.stderr.writer,
        std.testing.io,
        &env,
        &harness.registry,
        "definitely-not-a-model",
    );

    try std.testing.expectEqualStrings("No models matching \"definitely-not-a-model\"\n", writers.stdout.written());
    try std.testing.expectEqual(@as(usize, 0), writers.stderr.written().len);
}

test "list models surfaces models.json load warnings on stderr" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/bulb");
    try env.put("ANTHROPIC_API_KEY", "test-key");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = "{}" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "models.json", allocator);
    defer allocator.free(path);

    var harness = try TestRegistryHarness.init(allocator, &env, path);
    defer harness.deinit();

    var writers = TestWriters.init(allocator);
    defer writers.deinit();

    try writeListModels(
        allocator,
        &writers.stdout.writer,
        &writers.stderr.writer,
        std.testing.io,
        &env,
        &harness.registry,
        "sonnet",
    );

    try std.testing.expect(std.mem.indexOf(u8, writers.stdout.written(), "anthropic  claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, writers.stderr.written(), "Warning: errors loading models.json:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writers.stderr.written(), "Invalid models.json schema:") != null);
}

test "format token count matches Pi list-models abbreviations" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("999", try formatTokenCountBuf(&buffer, 999));
    try std.testing.expectEqualStrings("1K", try formatTokenCountBuf(&buffer, 1_000));
    try std.testing.expectEqualStrings("1.5K", try formatTokenCountBuf(&buffer, 1_500));
    try std.testing.expectEqualStrings("200K", try formatTokenCountBuf(&buffer, 200_000));
    try std.testing.expectEqualStrings("1M", try formatTokenCountBuf(&buffer, 1_000_000));
    try std.testing.expectEqualStrings("1.6M", try formatTokenCountBuf(&buffer, 1_550_000));
}
