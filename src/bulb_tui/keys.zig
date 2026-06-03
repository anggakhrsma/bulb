const std = @import("std");

var kitty_protocol_active = false;

pub fn setKittyProtocolActive(active: bool) void {
    kitty_protocol_active = active;
}

pub fn isKittyProtocolActive() bool {
    return kitty_protocol_active;
}

pub fn matchesKey(data: []const u8, key_id: []const u8) bool {
    return if (parseKey(data)) |parsed| std.mem.eql(u8, parsed, key_id) else false;
}

pub fn parseKey(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    if (std.mem.eql(u8, data, "\x1b")) return "escape";
    if (std.mem.eql(u8, data, "\r") or std.mem.eql(u8, data, "\n")) return "enter";
    if (std.mem.eql(u8, data, "\t")) return "tab";
    if (std.mem.eql(u8, data, "\x7f")) return "backspace";
    if (std.mem.eql(u8, data, "\x1b[A")) return "up";
    if (std.mem.eql(u8, data, "\x1b[B")) return "down";
    if (std.mem.eql(u8, data, "\x1b[C")) return "right";
    if (std.mem.eql(u8, data, "\x1b[D")) return "left";
    if (std.mem.eql(u8, data, "\x1b[H")) return "home";
    if (std.mem.eql(u8, data, "\x1b[F")) return "end";
    if (std.mem.eql(u8, data, "\x1b[3~")) return "delete";
    if (std.mem.eql(u8, data, "\x1b[5~")) return "pageUp";
    if (std.mem.eql(u8, data, "\x1b[6~")) return "pageDown";

    if (data.len == 1) {
        const byte = data[0];
        if (byte >= 1 and byte <= 26) return ctrlLetter(byte);
        if (byte >= ' ' and byte <= '~') return asciiKey(byte);
    }

    if (data.len == 2 and data[0] == '\x1b') {
        if (data[1] >= 'a' and data[1] <= 'z') return altLetter(data[1]);
        if (data[1] >= 'A' and data[1] <= 'Z') return shiftAltLetter(std.ascii.toLower(data[1]));
    }

    return null;
}

fn ctrlLetter(byte: u8) []const u8 {
    return switch (byte) {
        1 => "ctrl+a",
        2 => "ctrl+b",
        3 => "ctrl+c",
        4 => "ctrl+d",
        5 => "ctrl+e",
        6 => "ctrl+f",
        7 => "ctrl+g",
        8 => "ctrl+h",
        9 => "ctrl+i",
        10 => "ctrl+j",
        11 => "ctrl+k",
        12 => "ctrl+l",
        13 => "ctrl+m",
        14 => "ctrl+n",
        15 => "ctrl+o",
        16 => "ctrl+p",
        17 => "ctrl+q",
        18 => "ctrl+r",
        19 => "ctrl+s",
        20 => "ctrl+t",
        21 => "ctrl+u",
        22 => "ctrl+v",
        23 => "ctrl+w",
        24 => "ctrl+x",
        25 => "ctrl+y",
        26 => "ctrl+z",
        else => unreachable,
    };
}

fn asciiKey(byte: u8) []const u8 {
    return switch (byte) {
        ' ' => "space",
        'a'...'z' => singleAscii(byte),
        'A'...'Z' => shiftLetter(std.ascii.toLower(byte)),
        '0'...'9' => singleAscii(byte),
        '`' => "`",
        '-' => "-",
        '=' => "=",
        '[' => "[",
        ']' => "]",
        '\\' => "\\",
        ';' => ";",
        '\'' => "'",
        ',' => ",",
        '.' => ".",
        '/' => "/",
        '!' => "!",
        '@' => "@",
        '#' => "#",
        '$' => "$",
        '%' => "%",
        '^' => "^",
        '&' => "&",
        '*' => "*",
        '(' => "(",
        ')' => ")",
        '_' => "_",
        '+' => "+",
        '|' => "|",
        '~' => "~",
        '{' => "{",
        '}' => "}",
        ':' => ":",
        '<' => "<",
        '>' => ">",
        '?' => "?",
        else => "",
    };
}

fn singleAscii(byte: u8) []const u8 {
    return switch (byte) {
        'a' => "a",
        'b' => "b",
        'c' => "c",
        'd' => "d",
        'e' => "e",
        'f' => "f",
        'g' => "g",
        'h' => "h",
        'i' => "i",
        'j' => "j",
        'k' => "k",
        'l' => "l",
        'm' => "m",
        'n' => "n",
        'o' => "o",
        'p' => "p",
        'q' => "q",
        'r' => "r",
        's' => "s",
        't' => "t",
        'u' => "u",
        'v' => "v",
        'w' => "w",
        'x' => "x",
        'y' => "y",
        'z' => "z",
        '0' => "0",
        '1' => "1",
        '2' => "2",
        '3' => "3",
        '4' => "4",
        '5' => "5",
        '6' => "6",
        '7' => "7",
        '8' => "8",
        '9' => "9",
        else => "",
    };
}

fn shiftLetter(byte: u8) []const u8 {
    return switch (byte) {
        'a' => "shift+a",
        'b' => "shift+b",
        'c' => "shift+c",
        'd' => "shift+d",
        'e' => "shift+e",
        'f' => "shift+f",
        'g' => "shift+g",
        'h' => "shift+h",
        'i' => "shift+i",
        'j' => "shift+j",
        'k' => "shift+k",
        'l' => "shift+l",
        'm' => "shift+m",
        'n' => "shift+n",
        'o' => "shift+o",
        'p' => "shift+p",
        'q' => "shift+q",
        'r' => "shift+r",
        's' => "shift+s",
        't' => "shift+t",
        'u' => "shift+u",
        'v' => "shift+v",
        'w' => "shift+w",
        'x' => "shift+x",
        'y' => "shift+y",
        'z' => "shift+z",
        else => "",
    };
}

fn altLetter(byte: u8) []const u8 {
    return switch (byte) {
        'a' => "alt+a",
        'b' => "alt+b",
        'c' => "alt+c",
        'd' => "alt+d",
        'e' => "alt+e",
        'f' => "alt+f",
        'g' => "alt+g",
        'h' => "alt+h",
        'i' => "alt+i",
        'j' => "alt+j",
        'k' => "alt+k",
        'l' => "alt+l",
        'm' => "alt+m",
        'n' => "alt+n",
        'o' => "alt+o",
        'p' => "alt+p",
        'q' => "alt+q",
        'r' => "alt+r",
        's' => "alt+s",
        't' => "alt+t",
        'u' => "alt+u",
        'v' => "alt+v",
        'w' => "alt+w",
        'x' => "alt+x",
        'y' => "alt+y",
        'z' => "alt+z",
        else => "",
    };
}

fn shiftAltLetter(byte: u8) []const u8 {
    return switch (byte) {
        'a' => "shift+alt+a",
        'b' => "shift+alt+b",
        'c' => "shift+alt+c",
        'd' => "shift+alt+d",
        'e' => "shift+alt+e",
        'f' => "shift+alt+f",
        'g' => "shift+alt+g",
        'h' => "shift+alt+h",
        'i' => "shift+alt+i",
        'j' => "shift+alt+j",
        'k' => "shift+alt+k",
        'l' => "shift+alt+l",
        'm' => "shift+alt+m",
        'n' => "shift+alt+n",
        'o' => "shift+alt+o",
        'p' => "shift+alt+p",
        'q' => "shift+alt+q",
        'r' => "shift+alt+r",
        's' => "shift+alt+s",
        't' => "shift+alt+t",
        'u' => "shift+alt+u",
        'v' => "shift+alt+v",
        'w' => "shift+alt+w",
        'x' => "shift+alt+x",
        'y' => "shift+alt+y",
        'z' => "shift+alt+z",
        else => "",
    };
}

test "keys parse common legacy terminal inputs" {
    try std.testing.expect(matchesKey("\x03", "ctrl+c"));
    try std.testing.expect(matchesKey("\x1b[A", "up"));
    try std.testing.expect(matchesKey("\x1bb", "alt+b"));
    try std.testing.expect(matchesKey("P", "shift+p"));
    try std.testing.expect(!matchesKey("\x03", "ctrl+d"));
}
