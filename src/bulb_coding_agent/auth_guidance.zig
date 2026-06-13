const std = @import("std");
const config = @import("config.zig");

pub const unknown_provider = "unknown";

pub fn getProviderLoginHelpAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    const docs_path = try config.docsPathAlloc(allocator, io, environ);
    defer allocator.free(docs_path);
    return getProviderLoginHelpWithDocsPathAlloc(allocator, docs_path);
}

pub fn getProviderLoginHelpWithDocsPathAlloc(
    allocator: std.mem.Allocator,
    docs_path: []const u8,
) ![]u8 {
    const providers_path = try std.fs.path.join(allocator, &.{ docs_path, "providers.md" });
    defer allocator.free(providers_path);
    const models_path = try std.fs.path.join(allocator, &.{ docs_path, "models.md" });
    defer allocator.free(models_path);
    return std.fmt.allocPrint(
        allocator,
        "Use /login to log into a provider via OAuth or API key. See:\n  {s}\n  {s}",
        .{ providers_path, models_path },
    );
}

pub fn formatNoModelsAvailableMessageAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    const help = try getProviderLoginHelpAlloc(allocator, io, environ);
    defer allocator.free(help);
    return formatNoModelsAvailableMessageWithHelpAlloc(allocator, help);
}

pub fn formatNoModelsAvailableMessageWithDocsPathAlloc(
    allocator: std.mem.Allocator,
    docs_path: []const u8,
) ![]u8 {
    const help = try getProviderLoginHelpWithDocsPathAlloc(allocator, docs_path);
    defer allocator.free(help);
    return formatNoModelsAvailableMessageWithHelpAlloc(allocator, help);
}

pub fn formatNoModelSelectedMessageAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    const help = try getProviderLoginHelpAlloc(allocator, io, environ);
    defer allocator.free(help);
    return formatNoModelSelectedMessageWithHelpAlloc(allocator, help);
}

pub fn formatNoModelSelectedMessageWithDocsPathAlloc(
    allocator: std.mem.Allocator,
    docs_path: []const u8,
) ![]u8 {
    const help = try getProviderLoginHelpWithDocsPathAlloc(allocator, docs_path);
    defer allocator.free(help);
    return formatNoModelSelectedMessageWithHelpAlloc(allocator, help);
}

pub fn formatNoApiKeyFoundMessageAlloc(
    allocator: std.mem.Allocator,
    provider: []const u8,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    const help = try getProviderLoginHelpAlloc(allocator, io, environ);
    defer allocator.free(help);
    return formatNoApiKeyFoundMessageWithHelpAlloc(allocator, provider, help);
}

pub fn formatNoApiKeyFoundMessageWithDocsPathAlloc(
    allocator: std.mem.Allocator,
    provider: []const u8,
    docs_path: []const u8,
) ![]u8 {
    const help = try getProviderLoginHelpWithDocsPathAlloc(allocator, docs_path);
    defer allocator.free(help);
    return formatNoApiKeyFoundMessageWithHelpAlloc(allocator, provider, help);
}

fn formatNoModelsAvailableMessageWithHelpAlloc(
    allocator: std.mem.Allocator,
    help: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "No models available. {s}", .{help});
}

fn formatNoModelSelectedMessageWithHelpAlloc(
    allocator: std.mem.Allocator,
    help: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "No model selected.\n\n{s}\n\nThen use /model to select a model.", .{help});
}

fn formatNoApiKeyFoundMessageWithHelpAlloc(
    allocator: std.mem.Allocator,
    provider: []const u8,
    help: []const u8,
) ![]u8 {
    const provider_display = if (std.mem.eql(u8, provider, unknown_provider)) "the selected model" else provider;
    return std.fmt.allocPrint(allocator, "No API key found for {s}.\n\n{s}", .{ provider_display, help });
}

test "provider login help points at Bulb provider and model docs" {
    const allocator = std.testing.allocator;
    const message = try getProviderLoginHelpWithDocsPathAlloc(allocator, "/opt/bulb/docs");
    defer allocator.free(message);

    try std.testing.expectEqualStrings(
        "Use /login to log into a provider via OAuth or API key. See:\n  /opt/bulb/docs/providers.md\n  /opt/bulb/docs/models.md",
        message,
    );
}

test "auth guidance formats Pi-compatible no model messages with Bulb docs paths" {
    const allocator = std.testing.allocator;

    const no_models = try formatNoModelsAvailableMessageWithDocsPathAlloc(allocator, "/opt/bulb/docs");
    defer allocator.free(no_models);
    try std.testing.expectEqualStrings(
        "No models available. Use /login to log into a provider via OAuth or API key. See:\n  /opt/bulb/docs/providers.md\n  /opt/bulb/docs/models.md",
        no_models,
    );

    const no_selected = try formatNoModelSelectedMessageWithDocsPathAlloc(allocator, "/opt/bulb/docs");
    defer allocator.free(no_selected);
    try std.testing.expectEqualStrings(
        "No model selected.\n\nUse /login to log into a provider via OAuth or API key. See:\n  /opt/bulb/docs/providers.md\n  /opt/bulb/docs/models.md\n\nThen use /model to select a model.",
        no_selected,
    );
}

test "auth guidance formats provider-specific API key failures" {
    const allocator = std.testing.allocator;

    const known = try formatNoApiKeyFoundMessageWithDocsPathAlloc(allocator, "anthropic", "/opt/bulb/docs");
    defer allocator.free(known);
    try std.testing.expectEqualStrings(
        "No API key found for anthropic.\n\nUse /login to log into a provider via OAuth or API key. See:\n  /opt/bulb/docs/providers.md\n  /opt/bulb/docs/models.md",
        known,
    );

    const unknown = try formatNoApiKeyFoundMessageWithDocsPathAlloc(allocator, unknown_provider, "/opt/bulb/docs");
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings(
        "No API key found for the selected model.\n\nUse /login to log into a provider via OAuth or API key. See:\n  /opt/bulb/docs/providers.md\n  /opt/bulb/docs/models.md",
        unknown,
    );
}

test "auth guidance resolves docs paths from Bulb package directory override" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put(config.package_dir_env, "/tmp/bulb-package");

    const message = try formatNoModelsAvailableMessageAlloc(allocator, std.testing.io, &env);
    defer allocator.free(message);
    try std.testing.expectEqualStrings(
        "No models available. Use /login to log into a provider via OAuth or API key. See:\n  /tmp/bulb-package/docs/providers.md\n  /tmp/bulb-package/docs/models.md",
        message,
    );
}
