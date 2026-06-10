const std = @import("std");
const skills = @import("skills.zig");

pub const Skill = skills.Skill;

pub fn formatSkillsForSystemPromptAlloc(allocator: std.mem.Allocator, items: []const Skill) ![]u8 {
    return skills.formatSkillsForSystemPromptAlloc(allocator, items);
}

test "formatSkillsForSystemPrompt formats visible skills and escapes XML" {
    const allocator = std.testing.allocator;
    var visible = try Skill.initAlloc(
        allocator,
        "visible",
        "Use <this> & that",
        "visible content",
        "/skills/visible/SKILL.md",
        false,
    );
    defer visible.deinit();
    var second = try Skill.initAlloc(
        allocator,
        "second",
        "Second skill",
        "second content",
        "/skills/second/SKILL.md",
        false,
    );
    defer second.deinit();
    var disabled = try Skill.initAlloc(
        allocator,
        "hidden",
        "Hidden",
        "hidden content",
        "/skills/hidden/SKILL.md",
        true,
    );
    defer disabled.deinit();

    const result = try formatSkillsForSystemPromptAlloc(allocator, &.{ visible, disabled, second });
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        "The following skills provide specialized instructions for specific tasks.\n" ++
            "Read the full skill file when the task matches its description.\n" ++
            "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n" ++
            "<available_skills>\n" ++
            "  <skill>\n" ++
            "    <name>visible</name>\n" ++
            "    <description>Use &lt;this&gt; &amp; that</description>\n" ++
            "    <location>/skills/visible/SKILL.md</location>\n" ++
            "  </skill>\n" ++
            "  <skill>\n" ++
            "    <name>second</name>\n" ++
            "    <description>Second skill</description>\n" ++
            "    <location>/skills/second/SKILL.md</location>\n" ++
            "  </skill>\n" ++
            "</available_skills>",
        result,
    );

    const empty = try formatSkillsForSystemPromptAlloc(allocator, &.{disabled});
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    var escaped = try Skill.initAlloc(
        allocator,
        "a&b",
        "Quote \"double\" and 'single'",
        "content",
        "/skills/<bad>&\"quote\"/SKILL.md",
        false,
    );
    defer escaped.deinit();
    const escaped_result = try formatSkillsForSystemPromptAlloc(allocator, &.{escaped});
    defer allocator.free(escaped_result);
    try std.testing.expect(std.mem.indexOf(
        u8,
        escaped_result,
        "<name>a&amp;b</name>\n    <description>Quote &quot;double&quot; and &apos;single&apos;</description>\n    <location>/skills/&lt;bad&gt;&amp;&quot;quote&quot;/SKILL.md</location>",
    ) != null);
}
