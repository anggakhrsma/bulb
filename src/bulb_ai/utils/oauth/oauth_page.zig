const std = @import("std");

const logo_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 800" aria-hidden="true"><path fill="#fff" fill-rule="evenodd" d="M165.29 165.29 H517.36 V400 H400 V517.36 H282.65 V634.72 H165.29 Z M282.65 282.65 V400 H400 V282.65 Z"/><path fill="#fff" d="M517.36 400 H634.72 V634.72 H517.36 Z"/></svg>
;

const page_prefix =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8" />
    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\  <title>
;

const page_middle =
    \\</title>
    \\  <style>
    \\    :root {
    \\      --text: #fafafa;
    \\      --text-dim: #a1a1aa;
    \\      --page-bg: #09090b;
    \\      --font-sans: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol", "Noto Color Emoji";
    \\      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
    \\    }
    \\    * { box-sizing: border-box; }
    \\    html { color-scheme: dark; }
    \\    body {
    \\      margin: 0;
    \\      min-height: 100vh;
    \\      display: flex;
    \\      align-items: center;
    \\      justify-content: center;
    \\      padding: 24px;
    \\      background: var(--page-bg);
    \\      color: var(--text);
    \\      font-family: var(--font-sans);
    \\      text-align: center;
    \\    }
    \\    main {
    \\      width: 100%;
    \\      max-width: 560px;
    \\      display: flex;
    \\      flex-direction: column;
    \\      align-items: center;
    \\      justify-content: center;
    \\    }
    \\    .logo {
    \\      width: 72px;
    \\      height: 72px;
    \\      display: block;
    \\      margin-bottom: 24px;
    \\    }
    \\    h1 {
    \\      margin: 0 0 10px;
    \\      font-size: 28px;
    \\      line-height: 1.15;
    \\      font-weight: 650;
    \\      color: var(--text);
    \\    }
    \\    p {
    \\      margin: 0;
    \\      line-height: 1.7;
    \\      color: var(--text-dim);
    \\      font-size: 15px;
    \\    }
    \\    .details {
    \\      margin-top: 16px;
    \\      font-family: var(--font-mono);
    \\      font-size: 13px;
    \\      color: var(--text-dim);
    \\      white-space: pre-wrap;
    \\      word-break: break-word;
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <div class="logo">
;

const heading_prefix =
    \\</div>
    \\    <h1>
;

const message_prefix =
    \\</h1>
    \\    <p>
;

const details_prefix =
    \\</p>
    \\    <div class="details">
;

const page_suffix =
    \\  </main>
    \\</body>
    \\</html>
;

const RenderOptions = struct {
    title: []const u8,
    heading: []const u8,
    message: []const u8,
    details: ?[]const u8 = null,
};

pub fn oauthSuccessHtml(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    return renderPage(allocator, .{
        .title = "Authentication successful",
        .heading = "Authentication successful",
        .message = message,
    });
}

pub fn oauthErrorHtml(
    allocator: std.mem.Allocator,
    message: []const u8,
    details: ?[]const u8,
) ![]u8 {
    return renderPage(allocator, .{
        .title = "Authentication failed",
        .heading = "Authentication failed",
        .message = message,
        .details = details,
    });
}

fn renderPage(allocator: std.mem.Allocator, options: RenderOptions) ![]u8 {
    var html: std.ArrayList(u8) = .empty;
    errdefer html.deinit(allocator);

    try html.appendSlice(allocator, page_prefix);
    try appendEscapedHtml(allocator, &html, options.title);
    try html.appendSlice(allocator, page_middle);
    try html.appendSlice(allocator, logo_svg);
    try html.appendSlice(allocator, heading_prefix);
    try appendEscapedHtml(allocator, &html, options.heading);
    try html.appendSlice(allocator, message_prefix);
    try appendEscapedHtml(allocator, &html, options.message);
    if (options.details) |details| {
        try html.appendSlice(allocator, details_prefix);
        try appendEscapedHtml(allocator, &html, details);
        try html.appendSlice(allocator, "</div>\n");
    } else {
        try html.appendSlice(allocator, "</p>\n");
    }
    try html.appendSlice(allocator, page_suffix);
    return html.toOwnedSlice(allocator);
}

fn appendEscapedHtml(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    for (value) |byte| {
        try out.appendSlice(allocator, switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => &.{byte},
        });
    }
}

test "OAuth callback pages escape dynamic content" {
    const allocator = std.testing.allocator;
    const html = try oauthErrorHtml(allocator, "<bad & worse>", "\"details'\"");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;bad &amp; worse&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;details&#39;&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<bad & worse>") == null);
}

test "OAuth success page preserves shared branding and message" {
    const allocator = std.testing.allocator;
    const html = try oauthSuccessHtml(allocator, "Authentication complete.");
    defer allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Authentication successful</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, logo_svg) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Authentication complete.") != null);
}
