const std = @import("std");

const MOD_SHIFT: u16 = 1;
const MOD_ALT: u16 = 2;
const MOD_CTRL: u16 = 4;
const MOD_SUPER: u16 = 8;
const LOCK_MASK: u16 = 64 + 128;
const SUPPORTED_MODIFIERS: u16 = MOD_SHIFT | MOD_ALT | MOD_CTRL | MOD_SUPER;

const CP_ESCAPE: i32 = 27;
const CP_TAB: i32 = 9;
const CP_ENTER: i32 = 13;
const CP_SPACE: i32 = 32;
const CP_BACKSPACE: i32 = 127;
const CP_KP_ENTER: i32 = 57414;

const CP_UP: i32 = -1;
const CP_DOWN: i32 = -2;
const CP_RIGHT: i32 = -3;
const CP_LEFT: i32 = -4;

const CP_DELETE: i32 = -10;
const CP_INSERT: i32 = -11;
const CP_PAGE_UP: i32 = -12;
const CP_PAGE_DOWN: i32 = -13;
const CP_HOME: i32 = -14;
const CP_END: i32 = -15;

const KeyEventType = enum { press, repeat, release };

const ParsedKittySequence = struct {
    codepoint: i32,
    shifted_key: ?i32 = null,
    base_layout_key: ?i32 = null,
    modifier: u16,
    event_type: KeyEventType = .press,
};

const ParsedModifyOtherKeysSequence = struct {
    codepoint: i32,
    modifier: u16,
};

const ParsedKeyId = struct {
    key: []const u8,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

var kitty_protocol_active = false;
var last_event_type: KeyEventType = .press;
var parse_key_buffer: [96]u8 = undefined;
var printable_buffer: [4]u8 = undefined;
var windows_terminal_session_override: ?bool = null;
var process_environ: ?*const std.process.Environ.Map = null;

pub fn setKittyProtocolActive(active: bool) void {
    kitty_protocol_active = active;
}

pub fn isKittyProtocolActive() bool {
    return kitty_protocol_active;
}

pub fn setWindowsTerminalSessionForTesting(value: ?bool) void {
    windows_terminal_session_override = value;
}

pub fn setProcessEnvironment(environ: ?*const std.process.Environ.Map) void {
    process_environ = environ;
}

pub fn isKeyRelease(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\x1b[200~") != null) return false;
    return containsAny(data, &.{
        ":3u",
        ":3~",
        ":3A",
        ":3B",
        ":3C",
        ":3D",
        ":3H",
        ":3F",
    });
}

pub fn isKeyRepeat(data: []const u8) bool {
    if (std.mem.indexOf(u8, data, "\x1b[200~") != null) return false;
    return containsAny(data, &.{
        ":2u",
        ":2~",
        ":2A",
        ":2B",
        ":2C",
        ":2D",
        ":2H",
        ":2F",
    });
}

fn containsAny(data: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, data, needle) != null) return true;
    }
    return false;
}

pub fn matchesKey(data: []const u8, key_id: []const u8) bool {
    const parsed = parseKeyId(key_id) orelse return false;
    const key = parsed.key;
    const modifier = modifierFromParsedKeyId(parsed);

    if (keyEql(key, "escape") or keyEql(key, "esc")) {
        if (modifier != 0) return false;
        return std.mem.eql(u8, data, "\x1b") or
            matchesKittySequence(data, CP_ESCAPE, 0) or
            matchesModifyOtherKeys(data, CP_ESCAPE, 0);
    }

    if (keyEql(key, "space")) {
        if (!kitty_protocol_active) {
            if (modifier == MOD_CTRL and std.mem.eql(u8, data, "\x00")) return true;
            if (modifier == MOD_ALT and std.mem.eql(u8, data, "\x1b ")) return true;
        }
        if (modifier == 0) {
            return std.mem.eql(u8, data, " ") or
                matchesKittySequence(data, CP_SPACE, 0) or
                matchesModifyOtherKeys(data, CP_SPACE, 0);
        }
        return matchesKittySequence(data, CP_SPACE, modifier) or
            matchesModifyOtherKeys(data, CP_SPACE, modifier);
    }

    if (keyEql(key, "tab")) {
        if (modifier == MOD_SHIFT) {
            return std.mem.eql(u8, data, "\x1b[Z") or
                matchesKittySequence(data, CP_TAB, MOD_SHIFT) or
                matchesModifyOtherKeys(data, CP_TAB, MOD_SHIFT);
        }
        if (modifier == 0) {
            return std.mem.eql(u8, data, "\t") or matchesKittySequence(data, CP_TAB, 0);
        }
        return matchesKittySequence(data, CP_TAB, modifier) or
            matchesModifyOtherKeys(data, CP_TAB, modifier);
    }

    if (keyEql(key, "enter") or keyEql(key, "return")) {
        if (modifier == MOD_SHIFT) {
            if (matchesKittySequence(data, CP_ENTER, MOD_SHIFT) or
                matchesKittySequence(data, CP_KP_ENTER, MOD_SHIFT) or
                matchesModifyOtherKeys(data, CP_ENTER, MOD_SHIFT))
            {
                return true;
            }
            if (kitty_protocol_active) return std.mem.eql(u8, data, "\x1b\r") or std.mem.eql(u8, data, "\n");
            return false;
        }
        if (modifier == MOD_ALT) {
            if (matchesKittySequence(data, CP_ENTER, MOD_ALT) or
                matchesKittySequence(data, CP_KP_ENTER, MOD_ALT) or
                matchesModifyOtherKeys(data, CP_ENTER, MOD_ALT))
            {
                return true;
            }
            if (!kitty_protocol_active) return std.mem.eql(u8, data, "\x1b\r");
            return false;
        }
        if (modifier == 0) {
            return std.mem.eql(u8, data, "\r") or
                (!kitty_protocol_active and std.mem.eql(u8, data, "\n")) or
                std.mem.eql(u8, data, "\x1bOM") or
                matchesKittySequence(data, CP_ENTER, 0) or
                matchesKittySequence(data, CP_KP_ENTER, 0);
        }
        return matchesKittySequence(data, CP_ENTER, modifier) or
            matchesKittySequence(data, CP_KP_ENTER, modifier) or
            matchesModifyOtherKeys(data, CP_ENTER, modifier);
    }

    if (keyEql(key, "backspace")) {
        if (modifier == MOD_ALT) {
            if (std.mem.eql(u8, data, "\x1b\x7f") or std.mem.eql(u8, data, "\x1b\x08")) return true;
            return matchesKittySequence(data, CP_BACKSPACE, MOD_ALT) or
                matchesModifyOtherKeys(data, CP_BACKSPACE, MOD_ALT);
        }
        if (modifier == MOD_CTRL) {
            if (matchesRawBackspace(data, MOD_CTRL)) return true;
            return matchesKittySequence(data, CP_BACKSPACE, MOD_CTRL) or
                matchesModifyOtherKeys(data, CP_BACKSPACE, MOD_CTRL);
        }
        if (modifier == 0) {
            return matchesRawBackspace(data, 0) or
                matchesKittySequence(data, CP_BACKSPACE, 0) or
                matchesModifyOtherKeys(data, CP_BACKSPACE, 0);
        }
        return matchesKittySequence(data, CP_BACKSPACE, modifier) or
            matchesModifyOtherKeys(data, CP_BACKSPACE, modifier);
    }

    if (keyEql(key, "clear")) {
        if (modifier == 0) return matchesLegacySequence(data, "clear");
        return matchesLegacyModifierSequence(data, "clear", modifier);
    }

    if (matchesFunctionalKey(data, key, modifier)) return true;
    if (matchesArrowKey(data, key, modifier)) return true;
    if (matchesFunctionKey(data, key, modifier)) return true;

    if (key.len == 1 and isPlainKey(key[0])) {
        const key_byte = std.ascii.toLower(key[0]);
        const codepoint: i32 = key_byte;
        const raw_ctrl = rawCtrlChar(key_byte);
        const is_letter = key_byte >= 'a' and key_byte <= 'z';
        const is_digit = isDigitByte(key_byte);

        if (modifier == MOD_CTRL + MOD_ALT and !kitty_protocol_active) {
            if (raw_ctrl) |raw| {
                if (data.len == 2 and data[0] == '\x1b' and data[1] == raw) return true;
            }
        }

        if (modifier == MOD_ALT and !kitty_protocol_active and (is_letter or is_digit)) {
            if (data.len == 2 and data[0] == '\x1b' and data[1] == key_byte) return true;
        }

        if (modifier == MOD_CTRL) {
            if (raw_ctrl) |raw| {
                if (data.len == 1 and data[0] == raw) return true;
            }
            return matchesKittySequence(data, codepoint, MOD_CTRL) or
                matchesPrintableModifyOtherKeys(data, codepoint, MOD_CTRL);
        }

        if (modifier == MOD_SHIFT + MOD_CTRL) {
            return matchesKittySequence(data, codepoint, MOD_SHIFT + MOD_CTRL) or
                matchesPrintableModifyOtherKeys(data, codepoint, MOD_SHIFT + MOD_CTRL);
        }

        if (modifier == MOD_SHIFT) {
            if (is_letter and data.len == 1 and data[0] == std.ascii.toUpper(key_byte)) return true;
            return matchesKittySequence(data, codepoint, MOD_SHIFT) or
                matchesPrintableModifyOtherKeys(data, codepoint, MOD_SHIFT);
        }

        if (modifier != 0) {
            return matchesKittySequence(data, codepoint, modifier) or
                matchesPrintableModifyOtherKeys(data, codepoint, modifier);
        }

        return std.mem.eql(u8, data, key) or matchesKittySequence(data, codepoint, 0);
    }

    return false;
}

fn matchesFunctionalKey(data: []const u8, key: []const u8, modifier: u16) bool {
    if (functionalCodepointForKey(key)) |codepoint| {
        if (modifier == 0) {
            return matchesLegacySequence(data, key) or matchesKittySequence(data, codepoint, 0);
        }
        if (matchesLegacyModifierSequence(data, key, modifier)) return true;
        return matchesKittySequence(data, codepoint, modifier);
    }
    return false;
}

fn matchesArrowKey(data: []const u8, key: []const u8, modifier: u16) bool {
    const codepoint = arrowCodepointForKey(key) orelse return false;

    if (keyEql(key, "up") and modifier == MOD_ALT) {
        return std.mem.eql(u8, data, "\x1bp") or matchesKittySequence(data, codepoint, MOD_ALT);
    }
    if (keyEql(key, "down") and modifier == MOD_ALT) {
        return std.mem.eql(u8, data, "\x1bn") or matchesKittySequence(data, codepoint, MOD_ALT);
    }
    if (keyEql(key, "left") and modifier == MOD_ALT) {
        return std.mem.eql(u8, data, "\x1b[1;3D") or
            (!kitty_protocol_active and std.mem.eql(u8, data, "\x1bB")) or
            std.mem.eql(u8, data, "\x1bb") or
            matchesKittySequence(data, codepoint, MOD_ALT);
    }
    if (keyEql(key, "right") and modifier == MOD_ALT) {
        return std.mem.eql(u8, data, "\x1b[1;3C") or
            (!kitty_protocol_active and std.mem.eql(u8, data, "\x1bF")) or
            std.mem.eql(u8, data, "\x1bf") or
            matchesKittySequence(data, codepoint, MOD_ALT);
    }
    if (keyEql(key, "left") and modifier == MOD_CTRL) {
        return std.mem.eql(u8, data, "\x1b[1;5D") or
            matchesLegacyModifierSequence(data, "left", MOD_CTRL) or
            matchesKittySequence(data, codepoint, MOD_CTRL);
    }
    if (keyEql(key, "right") and modifier == MOD_CTRL) {
        return std.mem.eql(u8, data, "\x1b[1;5C") or
            matchesLegacyModifierSequence(data, "right", MOD_CTRL) or
            matchesKittySequence(data, codepoint, MOD_CTRL);
    }

    if (modifier == 0) return matchesLegacySequence(data, key) or matchesKittySequence(data, codepoint, 0);
    if (matchesLegacyModifierSequence(data, key, modifier)) return true;
    return matchesKittySequence(data, codepoint, modifier);
}

fn matchesFunctionKey(data: []const u8, key: []const u8, modifier: u16) bool {
    if (!isFunctionKey(key)) return false;
    if (modifier != 0) return false;
    return matchesLegacySequence(data, key);
}

pub fn parseKey(data: []const u8) ?[]const u8 {
    if (parseKittySequence(data)) |kitty| {
        return formatParsedKey(kitty.codepoint, kitty.modifier, kitty.base_layout_key);
    }

    if (parseModifyOtherKeysSequence(data)) |modify_other_keys| {
        return formatParsedKey(modify_other_keys.codepoint, modify_other_keys.modifier, null);
    }

    if (kitty_protocol_active) {
        if (std.mem.eql(u8, data, "\x1b\r") or std.mem.eql(u8, data, "\n")) return "shift+enter";
    }

    if (legacySequenceKeyId(data)) |key_id| return key_id;

    if (std.mem.eql(u8, data, "\x1b")) return "escape";
    if (std.mem.eql(u8, data, "\x1c")) return "ctrl+\\";
    if (std.mem.eql(u8, data, "\x1d")) return "ctrl+]";
    if (std.mem.eql(u8, data, "\x1f")) return "ctrl+-";
    if (std.mem.eql(u8, data, "\x1b\x1b")) return "ctrl+alt+[";
    if (std.mem.eql(u8, data, "\x1b\x1c")) return "ctrl+alt+\\";
    if (std.mem.eql(u8, data, "\x1b\x1d")) return "ctrl+alt+]";
    if (std.mem.eql(u8, data, "\x1b\x1f")) return "ctrl+alt+-";
    if (std.mem.eql(u8, data, "\t")) return "tab";
    if (std.mem.eql(u8, data, "\r") or (!kitty_protocol_active and std.mem.eql(u8, data, "\n")) or std.mem.eql(u8, data, "\x1bOM")) return "enter";
    if (std.mem.eql(u8, data, "\x00")) return "ctrl+space";
    if (std.mem.eql(u8, data, " ")) return "space";
    if (std.mem.eql(u8, data, "\x7f")) return "backspace";
    if (std.mem.eql(u8, data, "\x08")) return if (isWindowsTerminalSession()) "ctrl+backspace" else "backspace";
    if (std.mem.eql(u8, data, "\x1b[Z")) return "shift+tab";
    if (!kitty_protocol_active and std.mem.eql(u8, data, "\x1b\r")) return "alt+enter";
    if (!kitty_protocol_active and std.mem.eql(u8, data, "\x1b ")) return "alt+space";
    if (std.mem.eql(u8, data, "\x1b\x7f") or std.mem.eql(u8, data, "\x1b\x08")) return "alt+backspace";
    if (!kitty_protocol_active and std.mem.eql(u8, data, "\x1bB")) return "alt+left";
    if (!kitty_protocol_active and std.mem.eql(u8, data, "\x1bF")) return "alt+right";

    if (!kitty_protocol_active and data.len == 2 and data[0] == '\x1b') {
        const code = data[1];
        if (code >= 1 and code <= 26) return formatStatic("ctrl+alt+{c}", .{code + 96});
        if ((code >= 'a' and code <= 'z') or isDigitByte(code)) return formatStatic("alt+{c}", .{code});
    }

    if (std.mem.eql(u8, data, "\x1b[A")) return "up";
    if (std.mem.eql(u8, data, "\x1b[B")) return "down";
    if (std.mem.eql(u8, data, "\x1b[C")) return "right";
    if (std.mem.eql(u8, data, "\x1b[D")) return "left";
    if (std.mem.eql(u8, data, "\x1b[H") or std.mem.eql(u8, data, "\x1bOH")) return "home";
    if (std.mem.eql(u8, data, "\x1b[F") or std.mem.eql(u8, data, "\x1bOF")) return "end";
    if (std.mem.eql(u8, data, "\x1b[3~")) return "delete";
    if (std.mem.eql(u8, data, "\x1b[5~")) return "pageUp";
    if (std.mem.eql(u8, data, "\x1b[6~")) return "pageDown";

    if (data.len == 1) {
        const code = data[0];
        if (code >= 1 and code <= 26) return ctrlLetter(code);
        if (code >= 32 and code <= 126) return data;
    }

    return null;
}

fn parseKeyId(key_id: []const u8) ?ParsedKeyId {
    if (key_id.len == 0) return null;
    var result: ParsedKeyId = .{ .key = key_id };
    var start: usize = 0;
    var found_key = false;

    while (start <= key_id.len) {
        const plus = std.mem.indexOfScalarPos(u8, key_id, start, '+');
        const end = plus orelse key_id.len;
        const part = key_id[start..end];
        if (part.len == 0) return null;

        if (plus == null) {
            result.key = part;
            found_key = true;
            break;
        }

        if (keyEql(part, "ctrl")) {
            result.ctrl = true;
        } else if (keyEql(part, "shift")) {
            result.shift = true;
        } else if (keyEql(part, "alt")) {
            result.alt = true;
        } else if (keyEql(part, "super")) {
            result.super = true;
        } else {
            return null;
        }

        start = end + 1;
    }

    return if (found_key and result.key.len > 0) result else null;
}

fn modifierFromParsedKeyId(parsed: ParsedKeyId) u16 {
    var modifier: u16 = 0;
    if (parsed.shift) modifier |= MOD_SHIFT;
    if (parsed.alt) modifier |= MOD_ALT;
    if (parsed.ctrl) modifier |= MOD_CTRL;
    if (parsed.super) modifier |= MOD_SUPER;
    return modifier;
}

fn parseKittySequence(data: []const u8) ?ParsedKittySequence {
    if (!std.mem.startsWith(u8, data, "\x1b[") or data.len < 4) return null;

    if (data[data.len - 1] == 'u') {
        const body = data[2 .. data.len - 1];
        const semicolon = std.mem.indexOfScalar(u8, body, ';');
        const key_part = if (semicolon) |index| body[0..index] else body;
        const mod_event_part = if (semicolon) |index| body[index + 1 ..] else "";

        var colon_it = std.mem.splitScalar(u8, key_part, ':');
        const codepoint_text = colon_it.next() orelse return null;
        const codepoint = parsePositiveI32(codepoint_text) orelse return null;
        var shifted_key: ?i32 = null;
        var base_layout_key: ?i32 = null;

        if (colon_it.next()) |part| {
            if (part.len > 0) shifted_key = parsePositiveI32(part) orelse return null;
            if (colon_it.next()) |base_part| {
                if (base_part.len > 0) base_layout_key = parsePositiveI32(base_part) orelse return null;
                if (colon_it.next() != null) return null;
            }
        }

        const mod_event = parseModifierEvent(mod_event_part) orelse return null;
        last_event_type = mod_event.event_type;
        return .{
            .codepoint = codepoint,
            .shifted_key = shifted_key,
            .base_layout_key = base_layout_key,
            .modifier = mod_event.modifier,
            .event_type = mod_event.event_type,
        };
    }

    const final = data[data.len - 1];
    if (final == 'A' or final == 'B' or final == 'C' or final == 'D') {
        const body = data[2 .. data.len - 1];
        if (!std.mem.startsWith(u8, body, "1;")) return null;
        const mod_event = parseModifierEvent(body[2..]) orelse return null;
        const codepoint: i32 = switch (final) {
            'A' => CP_UP,
            'B' => CP_DOWN,
            'C' => CP_RIGHT,
            'D' => CP_LEFT,
            else => unreachable,
        };
        last_event_type = mod_event.event_type;
        return .{ .codepoint = codepoint, .modifier = mod_event.modifier, .event_type = mod_event.event_type };
    }

    if (final == '~') {
        const body = data[2 .. data.len - 1];
        const semicolon = std.mem.indexOfScalar(u8, body, ';');
        const key_num_text = if (semicolon) |index| body[0..index] else body;
        const key_num = parsePositiveI32(key_num_text) orelse return null;
        const codepoint = functionalCodepointForNumber(key_num) orelse return null;
        const mod_event = parseModifierEvent(if (semicolon) |index| body[index + 1 ..] else "") orelse return null;
        last_event_type = mod_event.event_type;
        return .{ .codepoint = codepoint, .modifier = mod_event.modifier, .event_type = mod_event.event_type };
    }

    if (final == 'H' or final == 'F') {
        const body = data[2 .. data.len - 1];
        if (!std.mem.startsWith(u8, body, "1;")) return null;
        const mod_event = parseModifierEvent(body[2..]) orelse return null;
        const codepoint: i32 = if (final == 'H') CP_HOME else CP_END;
        last_event_type = mod_event.event_type;
        return .{ .codepoint = codepoint, .modifier = mod_event.modifier, .event_type = mod_event.event_type };
    }

    return null;
}

const ParsedModifierEvent = struct {
    modifier: u16,
    event_type: KeyEventType = .press,
};

fn parseModifierEvent(text: []const u8) ?ParsedModifierEvent {
    if (text.len == 0) return .{ .modifier = 0, .event_type = .press };

    const colon = std.mem.indexOfScalar(u8, text, ':');
    const mod_text = if (colon) |index| text[0..index] else text;
    const event_text = if (colon) |index| text[index + 1 ..] else "";
    const mod_value = parsePositiveU16(mod_text) orelse return null;
    if (mod_value == 0) return null;

    return .{
        .modifier = mod_value - 1,
        .event_type = parseEventType(event_text),
    };
}

fn parseEventType(text: []const u8) KeyEventType {
    if (text.len == 0) return .press;
    const event_value = parsePositiveU16(text) orelse return .press;
    return switch (event_value) {
        2 => .repeat,
        3 => .release,
        else => .press,
    };
}

fn parseModifyOtherKeysSequence(data: []const u8) ?ParsedModifyOtherKeysSequence {
    if (!std.mem.startsWith(u8, data, "\x1b[27;") or !std.mem.endsWith(u8, data, "~")) return null;
    const body = data[5 .. data.len - 1];
    const semicolon = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    const mod_value = parsePositiveU16(body[0..semicolon]) orelse return null;
    if (mod_value == 0) return null;
    const codepoint = parsePositiveI32(body[semicolon + 1 ..]) orelse return null;
    return .{ .codepoint = codepoint, .modifier = mod_value - 1 };
}

fn matchesKittySequence(data: []const u8, expected_codepoint: i32, expected_modifier: u16) bool {
    const parsed = parseKittySequence(data) orelse return false;
    const actual_mod = parsed.modifier & ~LOCK_MASK;
    const expected_mod = expected_modifier & ~LOCK_MASK;
    if (actual_mod != expected_mod) return false;

    const normalized_codepoint = normalizeShiftedLetterIdentityCodepoint(
        normalizeKittyFunctionalCodepoint(parsed.codepoint),
        parsed.modifier,
    );
    const normalized_expected = normalizeShiftedLetterIdentityCodepoint(
        normalizeKittyFunctionalCodepoint(expected_codepoint),
        expected_modifier,
    );

    if (normalized_codepoint == normalized_expected) return true;

    if (parsed.base_layout_key) |base_layout_key| {
        if (base_layout_key == expected_codepoint) {
            const cp = normalized_codepoint;
            if (!isLatinLetterCodepoint(cp) and !isKnownSymbolCodepoint(cp)) return true;
        }
    }

    return false;
}

fn matchesModifyOtherKeys(data: []const u8, expected_keycode: i32, expected_modifier: u16) bool {
    const parsed = parseModifyOtherKeysSequence(data) orelse return false;
    return parsed.codepoint == expected_keycode and parsed.modifier == expected_modifier;
}

fn matchesPrintableModifyOtherKeys(data: []const u8, expected_keycode: i32, expected_modifier: u16) bool {
    if (expected_modifier == 0) return false;
    const parsed = parseModifyOtherKeysSequence(data) orelse return false;
    if (parsed.modifier != expected_modifier) return false;
    return normalizeShiftedLetterIdentityCodepoint(parsed.codepoint, parsed.modifier) ==
        normalizeShiftedLetterIdentityCodepoint(expected_keycode, expected_modifier);
}

fn normalizeKittyFunctionalCodepoint(codepoint: i32) i32 {
    return switch (codepoint) {
        57399 => '0',
        57400 => '1',
        57401 => '2',
        57402 => '3',
        57403 => '4',
        57404 => '5',
        57405 => '6',
        57406 => '7',
        57407 => '8',
        57408 => '9',
        57409 => '.',
        57410 => '/',
        57411 => '*',
        57412 => '-',
        57413 => '+',
        57415 => '=',
        57416 => ',',
        57417 => CP_LEFT,
        57418 => CP_RIGHT,
        57419 => CP_UP,
        57420 => CP_DOWN,
        57421 => CP_PAGE_UP,
        57422 => CP_PAGE_DOWN,
        57423 => CP_HOME,
        57424 => CP_END,
        57425 => CP_INSERT,
        57426 => CP_DELETE,
        else => codepoint,
    };
}

fn normalizeShiftedLetterIdentityCodepoint(codepoint: i32, modifier: u16) i32 {
    const effective_modifier = modifier & ~LOCK_MASK;
    if ((effective_modifier & MOD_SHIFT) != 0 and codepoint >= 'A' and codepoint <= 'Z') return codepoint + 32;
    return codepoint;
}

fn formatParsedKey(codepoint: i32, modifier: u16, base_layout_key: ?i32) ?[]const u8 {
    const normalized = normalizeKittyFunctionalCodepoint(codepoint);
    const identity = normalizeShiftedLetterIdentityCodepoint(normalized, modifier);

    const use_identity = isLatinLetterCodepoint(identity) or
        isDigitCodepoint(identity) or
        isKnownSymbolCodepoint(identity);
    const effective = if (use_identity) identity else base_layout_key orelse identity;
    const key_name = keyNameFromCodepoint(effective) orelse return null;
    return formatKeyNameWithModifiers(key_name, modifier);
}

fn formatKeyNameWithModifiers(key_name: []const u8, modifier: u16) ?[]const u8 {
    const effective_modifier = modifier & ~LOCK_MASK;
    if ((effective_modifier & ~SUPPORTED_MODIFIERS) != 0) return null;
    if (effective_modifier == 0) return key_name;

    var pos: usize = 0;
    if ((effective_modifier & MOD_SHIFT) != 0) appendToken(&parse_key_buffer, &pos, "shift+");
    if ((effective_modifier & MOD_CTRL) != 0) appendToken(&parse_key_buffer, &pos, "ctrl+");
    if ((effective_modifier & MOD_ALT) != 0) appendToken(&parse_key_buffer, &pos, "alt+");
    if ((effective_modifier & MOD_SUPER) != 0) appendToken(&parse_key_buffer, &pos, "super+");
    appendToken(&parse_key_buffer, &pos, key_name);
    return parse_key_buffer[0..pos];
}

fn appendToken(buffer: []u8, pos: *usize, token: []const u8) void {
    std.debug.assert(pos.* + token.len <= buffer.len);
    @memcpy(buffer[pos.* .. pos.* + token.len], token);
    pos.* += token.len;
}

fn formatStatic(comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.bufPrint(&parse_key_buffer, fmt, args) catch null;
}

pub fn decodeKittyPrintable(data: []const u8) ?[]const u8 {
    const parsed = parseKittySequence(data) orelse return null;
    const modifier = parsed.modifier;
    const allowed_modifiers = MOD_SHIFT | LOCK_MASK;
    if ((modifier & ~allowed_modifiers) != 0) return null;
    if ((modifier & (MOD_ALT | MOD_CTRL)) != 0) return null;

    var effective_codepoint = parsed.codepoint;
    if ((modifier & MOD_SHIFT) != 0) {
        if (parsed.shifted_key) |shifted_key| effective_codepoint = shifted_key;
    }
    effective_codepoint = normalizeKittyFunctionalCodepoint(effective_codepoint);
    return encodePrintableCodepoint(effective_codepoint);
}

fn decodeModifyOtherKeysPrintable(data: []const u8) ?[]const u8 {
    const parsed = parseModifyOtherKeysSequence(data) orelse return null;
    const modifier = parsed.modifier & ~LOCK_MASK;
    if ((modifier & ~MOD_SHIFT) != 0) return null;
    return encodePrintableCodepoint(parsed.codepoint);
}

pub fn decodePrintableKey(data: []const u8) ?[]const u8 {
    return decodeKittyPrintable(data) orelse decodeModifyOtherKeysPrintable(data);
}

fn encodePrintableCodepoint(codepoint: i32) ?[]const u8 {
    if (codepoint < 32 or codepoint > 0x10ffff) return null;
    if (codepoint >= 0xd800 and codepoint <= 0xdfff) return null;
    const cp: u21 = @intCast(codepoint);
    const len = std.unicode.utf8Encode(cp, &printable_buffer) catch return null;
    return printable_buffer[0..len];
}

fn legacySequenceKeyId(data: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, data, "\x1bOA")) return "up";
    if (std.mem.eql(u8, data, "\x1bOB")) return "down";
    if (std.mem.eql(u8, data, "\x1bOC")) return "right";
    if (std.mem.eql(u8, data, "\x1bOD")) return "left";
    if (std.mem.eql(u8, data, "\x1bOH")) return "home";
    if (std.mem.eql(u8, data, "\x1bOF")) return "end";
    if (std.mem.eql(u8, data, "\x1b[E")) return "clear";
    if (std.mem.eql(u8, data, "\x1bOE")) return "clear";
    if (std.mem.eql(u8, data, "\x1bOe")) return "ctrl+clear";
    if (std.mem.eql(u8, data, "\x1b[e")) return "shift+clear";
    if (std.mem.eql(u8, data, "\x1b[2~")) return "insert";
    if (std.mem.eql(u8, data, "\x1b[2$")) return "shift+insert";
    if (std.mem.eql(u8, data, "\x1b[2^")) return "ctrl+insert";
    if (std.mem.eql(u8, data, "\x1b[3$")) return "shift+delete";
    if (std.mem.eql(u8, data, "\x1b[3^")) return "ctrl+delete";
    if (std.mem.eql(u8, data, "\x1b[[5~")) return "pageUp";
    if (std.mem.eql(u8, data, "\x1b[[6~")) return "pageDown";
    if (std.mem.eql(u8, data, "\x1b[a")) return "shift+up";
    if (std.mem.eql(u8, data, "\x1b[b")) return "shift+down";
    if (std.mem.eql(u8, data, "\x1b[c")) return "shift+right";
    if (std.mem.eql(u8, data, "\x1b[d")) return "shift+left";
    if (std.mem.eql(u8, data, "\x1bOa")) return "ctrl+up";
    if (std.mem.eql(u8, data, "\x1bOb")) return "ctrl+down";
    if (std.mem.eql(u8, data, "\x1bOc")) return "ctrl+right";
    if (std.mem.eql(u8, data, "\x1bOd")) return "ctrl+left";
    if (std.mem.eql(u8, data, "\x1b[5$")) return "shift+pageUp";
    if (std.mem.eql(u8, data, "\x1b[6$")) return "shift+pageDown";
    if (std.mem.eql(u8, data, "\x1b[7$")) return "shift+home";
    if (std.mem.eql(u8, data, "\x1b[8$")) return "shift+end";
    if (std.mem.eql(u8, data, "\x1b[5^")) return "ctrl+pageUp";
    if (std.mem.eql(u8, data, "\x1b[6^")) return "ctrl+pageDown";
    if (std.mem.eql(u8, data, "\x1b[7^")) return "ctrl+home";
    if (std.mem.eql(u8, data, "\x1b[8^")) return "ctrl+end";
    if (std.mem.eql(u8, data, "\x1bOP") or std.mem.eql(u8, data, "\x1b[11~") or std.mem.eql(u8, data, "\x1b[[A")) return "f1";
    if (std.mem.eql(u8, data, "\x1bOQ") or std.mem.eql(u8, data, "\x1b[12~") or std.mem.eql(u8, data, "\x1b[[B")) return "f2";
    if (std.mem.eql(u8, data, "\x1bOR") or std.mem.eql(u8, data, "\x1b[13~") or std.mem.eql(u8, data, "\x1b[[C")) return "f3";
    if (std.mem.eql(u8, data, "\x1bOS") or std.mem.eql(u8, data, "\x1b[14~") or std.mem.eql(u8, data, "\x1b[[D")) return "f4";
    if (std.mem.eql(u8, data, "\x1b[[E") or std.mem.eql(u8, data, "\x1b[15~")) return "f5";
    if (std.mem.eql(u8, data, "\x1b[17~")) return "f6";
    if (std.mem.eql(u8, data, "\x1b[18~")) return "f7";
    if (std.mem.eql(u8, data, "\x1b[19~")) return "f8";
    if (std.mem.eql(u8, data, "\x1b[20~")) return "f9";
    if (std.mem.eql(u8, data, "\x1b[21~")) return "f10";
    if (std.mem.eql(u8, data, "\x1b[23~")) return "f11";
    if (std.mem.eql(u8, data, "\x1b[24~")) return "f12";
    if (std.mem.eql(u8, data, "\x1bb")) return "alt+left";
    if (std.mem.eql(u8, data, "\x1bf")) return "alt+right";
    if (std.mem.eql(u8, data, "\x1bp")) return "alt+up";
    if (std.mem.eql(u8, data, "\x1bn")) return "alt+down";
    return null;
}

fn matchesLegacySequence(data: []const u8, key: []const u8) bool {
    if (keyEql(key, "up")) return std.mem.eql(u8, data, "\x1b[A") or std.mem.eql(u8, data, "\x1bOA");
    if (keyEql(key, "down")) return std.mem.eql(u8, data, "\x1b[B") or std.mem.eql(u8, data, "\x1bOB");
    if (keyEql(key, "right")) return std.mem.eql(u8, data, "\x1b[C") or std.mem.eql(u8, data, "\x1bOC");
    if (keyEql(key, "left")) return std.mem.eql(u8, data, "\x1b[D") or std.mem.eql(u8, data, "\x1bOD");
    if (keyEql(key, "home")) return std.mem.eql(u8, data, "\x1b[H") or std.mem.eql(u8, data, "\x1bOH") or std.mem.eql(u8, data, "\x1b[1~") or std.mem.eql(u8, data, "\x1b[7~");
    if (keyEql(key, "end")) return std.mem.eql(u8, data, "\x1b[F") or std.mem.eql(u8, data, "\x1bOF") or std.mem.eql(u8, data, "\x1b[4~") or std.mem.eql(u8, data, "\x1b[8~");
    if (keyEql(key, "insert")) return std.mem.eql(u8, data, "\x1b[2~");
    if (keyEql(key, "delete")) return std.mem.eql(u8, data, "\x1b[3~");
    if (keyEql(key, "pageUp")) return std.mem.eql(u8, data, "\x1b[5~") or std.mem.eql(u8, data, "\x1b[[5~");
    if (keyEql(key, "pageDown")) return std.mem.eql(u8, data, "\x1b[6~") or std.mem.eql(u8, data, "\x1b[[6~");
    if (keyEql(key, "clear")) return std.mem.eql(u8, data, "\x1b[E") or std.mem.eql(u8, data, "\x1bOE");
    if (keyEql(key, "f1")) return std.mem.eql(u8, data, "\x1bOP") or std.mem.eql(u8, data, "\x1b[11~") or std.mem.eql(u8, data, "\x1b[[A");
    if (keyEql(key, "f2")) return std.mem.eql(u8, data, "\x1bOQ") or std.mem.eql(u8, data, "\x1b[12~") or std.mem.eql(u8, data, "\x1b[[B");
    if (keyEql(key, "f3")) return std.mem.eql(u8, data, "\x1bOR") or std.mem.eql(u8, data, "\x1b[13~") or std.mem.eql(u8, data, "\x1b[[C");
    if (keyEql(key, "f4")) return std.mem.eql(u8, data, "\x1bOS") or std.mem.eql(u8, data, "\x1b[14~") or std.mem.eql(u8, data, "\x1b[[D");
    if (keyEql(key, "f5")) return std.mem.eql(u8, data, "\x1b[15~") or std.mem.eql(u8, data, "\x1b[[E");
    if (keyEql(key, "f6")) return std.mem.eql(u8, data, "\x1b[17~");
    if (keyEql(key, "f7")) return std.mem.eql(u8, data, "\x1b[18~");
    if (keyEql(key, "f8")) return std.mem.eql(u8, data, "\x1b[19~");
    if (keyEql(key, "f9")) return std.mem.eql(u8, data, "\x1b[20~");
    if (keyEql(key, "f10")) return std.mem.eql(u8, data, "\x1b[21~");
    if (keyEql(key, "f11")) return std.mem.eql(u8, data, "\x1b[23~");
    if (keyEql(key, "f12")) return std.mem.eql(u8, data, "\x1b[24~");
    return false;
}

fn matchesLegacyModifierSequence(data: []const u8, key: []const u8, modifier: u16) bool {
    if (modifier == MOD_SHIFT) return matchesLegacyShiftSequence(data, key);
    if (modifier == MOD_CTRL) return matchesLegacyCtrlSequence(data, key);
    return false;
}

fn matchesLegacyShiftSequence(data: []const u8, key: []const u8) bool {
    if (keyEql(key, "up")) return std.mem.eql(u8, data, "\x1b[a");
    if (keyEql(key, "down")) return std.mem.eql(u8, data, "\x1b[b");
    if (keyEql(key, "right")) return std.mem.eql(u8, data, "\x1b[c");
    if (keyEql(key, "left")) return std.mem.eql(u8, data, "\x1b[d");
    if (keyEql(key, "clear")) return std.mem.eql(u8, data, "\x1b[e");
    if (keyEql(key, "insert")) return std.mem.eql(u8, data, "\x1b[2$");
    if (keyEql(key, "delete")) return std.mem.eql(u8, data, "\x1b[3$");
    if (keyEql(key, "pageUp")) return std.mem.eql(u8, data, "\x1b[5$");
    if (keyEql(key, "pageDown")) return std.mem.eql(u8, data, "\x1b[6$");
    if (keyEql(key, "home")) return std.mem.eql(u8, data, "\x1b[7$");
    if (keyEql(key, "end")) return std.mem.eql(u8, data, "\x1b[8$");
    return false;
}

fn matchesLegacyCtrlSequence(data: []const u8, key: []const u8) bool {
    if (keyEql(key, "up")) return std.mem.eql(u8, data, "\x1bOa");
    if (keyEql(key, "down")) return std.mem.eql(u8, data, "\x1bOb");
    if (keyEql(key, "right")) return std.mem.eql(u8, data, "\x1bOc");
    if (keyEql(key, "left")) return std.mem.eql(u8, data, "\x1bOd");
    if (keyEql(key, "clear")) return std.mem.eql(u8, data, "\x1bOe");
    if (keyEql(key, "insert")) return std.mem.eql(u8, data, "\x1b[2^");
    if (keyEql(key, "delete")) return std.mem.eql(u8, data, "\x1b[3^");
    if (keyEql(key, "pageUp")) return std.mem.eql(u8, data, "\x1b[5^");
    if (keyEql(key, "pageDown")) return std.mem.eql(u8, data, "\x1b[6^");
    if (keyEql(key, "home")) return std.mem.eql(u8, data, "\x1b[7^");
    if (keyEql(key, "end")) return std.mem.eql(u8, data, "\x1b[8^");
    return false;
}

fn functionalCodepointForKey(key: []const u8) ?i32 {
    if (keyEql(key, "insert")) return CP_INSERT;
    if (keyEql(key, "delete")) return CP_DELETE;
    if (keyEql(key, "home")) return CP_HOME;
    if (keyEql(key, "end")) return CP_END;
    if (keyEql(key, "pageUp")) return CP_PAGE_UP;
    if (keyEql(key, "pageDown")) return CP_PAGE_DOWN;
    if (keyEql(key, "clear")) return null;
    return null;
}

fn functionalCodepointForNumber(number: i32) ?i32 {
    return switch (number) {
        2 => CP_INSERT,
        3 => CP_DELETE,
        5 => CP_PAGE_UP,
        6 => CP_PAGE_DOWN,
        7 => CP_HOME,
        8 => CP_END,
        else => null,
    };
}

fn arrowCodepointForKey(key: []const u8) ?i32 {
    if (keyEql(key, "up")) return CP_UP;
    if (keyEql(key, "down")) return CP_DOWN;
    if (keyEql(key, "right")) return CP_RIGHT;
    if (keyEql(key, "left")) return CP_LEFT;
    return null;
}

fn isFunctionKey(key: []const u8) bool {
    inline for (1..13) |number| {
        var name_buffer: [4]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "f{d}", .{number}) catch unreachable;
        if (keyEql(key, name)) return true;
    }
    return false;
}

fn keyNameFromCodepoint(codepoint: i32) ?[]const u8 {
    return switch (codepoint) {
        CP_ESCAPE => "escape",
        CP_TAB => "tab",
        CP_ENTER, CP_KP_ENTER => "enter",
        CP_SPACE => "space",
        CP_BACKSPACE => "backspace",
        CP_DELETE => "delete",
        CP_INSERT => "insert",
        CP_HOME => "home",
        CP_END => "end",
        CP_PAGE_UP => "pageUp",
        CP_PAGE_DOWN => "pageDown",
        CP_UP => "up",
        CP_DOWN => "down",
        CP_LEFT => "left",
        CP_RIGHT => "right",
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
        else => null,
    };
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

fn rawCtrlChar(key: u8) ?u8 {
    const char = std.ascii.toLower(key);
    if ((char >= 'a' and char <= 'z') or char == '[' or char == '\\' or char == ']' or char == '_') {
        return char & 0x1f;
    }
    if (char == '-') return 31;
    return null;
}

fn matchesRawBackspace(data: []const u8, expected_modifier: u16) bool {
    if (std.mem.eql(u8, data, "\x7f")) return expected_modifier == 0;
    if (!std.mem.eql(u8, data, "\x08")) return false;
    return if (isWindowsTerminalSession()) expected_modifier == MOD_CTRL else expected_modifier == 0;
}

fn isWindowsTerminalSession() bool {
    if (windows_terminal_session_override) |override| return override;
    const environ = process_environ orelse return false;
    return isWindowsTerminalSessionFromEnv(environ);
}

pub fn isWindowsTerminalSessionFromEnv(environ: *const std.process.Environ.Map) bool {
    return environ.get("WT_SESSION") != null and
        environ.get("SSH_CONNECTION") == null and
        environ.get("SSH_CLIENT") == null and
        environ.get("SSH_TTY") == null;
}

fn isPlainKey(byte: u8) bool {
    const lower = std.ascii.toLower(byte);
    return (lower >= 'a' and lower <= 'z') or isDigitByte(lower) or isKnownSymbolByte(byte);
}

fn isDigitByte(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isLatinLetterCodepoint(codepoint: i32) bool {
    return codepoint >= 'a' and codepoint <= 'z';
}

fn isDigitCodepoint(codepoint: i32) bool {
    return codepoint >= '0' and codepoint <= '9';
}

fn isKnownSymbolCodepoint(codepoint: i32) bool {
    if (codepoint < 0 or codepoint > 127) return false;
    return isKnownSymbolByte(@intCast(codepoint));
}

fn isKnownSymbolByte(byte: u8) bool {
    return switch (byte) {
        '`', '-', '=', '[', ']', '\\', ';', '\'', ',', '.', '/', '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '|', '~', '{', '}', ':', '<', '>', '?' => true,
        else => false,
    };
}

fn keyEql(actual: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(actual, expected);
}

fn parsePositiveI32(text: []const u8) ?i32 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(i32, text, 10) catch null;
}

fn parsePositiveU16(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(u16, text, 10) catch null;
}

// Ported subset of packages/tui/test/keys.test.ts.
test "keys parse common legacy terminal inputs" {
    setKittyProtocolActive(false);
    try std.testing.expect(matchesKey("\x03", "ctrl+c"));
    try std.testing.expect(matchesKey("\x1b[A", "up"));
    try std.testing.expect(matchesKey("\x1bb", "alt+b"));
    try std.testing.expect(matchesKey("P", "shift+p"));
    try std.testing.expect(!matchesKey("\x03", "ctrl+d"));
}

// Ported from packages/tui/test/keys.test.ts: Kitty protocol alternate keys.
test "keys match Kitty CSI-u alternate layout and super modifiers" {
    setKittyProtocolActive(true);
    defer setKittyProtocolActive(false);

    try std.testing.expect(matchesKey("\x1b[1089::99;5u", "ctrl+c"));
    try std.testing.expect(matchesKey("\x1b[1074::100;5u", "ctrl+d"));
    try std.testing.expect(matchesKey("\x1b[1103::122;5u", "ctrl+z"));
    try std.testing.expect(matchesKey("\x1b[1079::112;6u", "ctrl+shift+p"));
    try std.testing.expect(matchesKey("\x1b[99;5u", "ctrl+c"));
    try std.testing.expect(matchesKey("\x1b[107;9u", "super+k"));
    try std.testing.expect(matchesKey("\x1b[13;9u", "super+enter"));
    try std.testing.expect(matchesKey("\x1b[107;13u", "ctrl+super+k"));
    try std.testing.expect(matchesKey("\x1b[107;14u", "ctrl+shift+super+k"));
    try std.testing.expect(!matchesKey("\x1b[107;13u", "super+k"));
    try std.testing.expectEqualStrings("super+k", parseKey("\x1b[107;9u").?);
    try std.testing.expectEqualStrings("super+enter", parseKey("\x1b[13;9u").?);
    try std.testing.expectEqualStrings("ctrl+super+k", parseKey("\x1b[107;13u").?);
    try std.testing.expectEqualStrings("shift+ctrl+super+k", parseKey("\x1b[107;14u").?);
}

// Ported from packages/tui/test/keys.test.ts: Kitty digits and keypad equivalents.
test "keys normalize Kitty digit and keypad functional codepoints" {
    setKittyProtocolActive(true);
    defer setKittyProtocolActive(false);

    try std.testing.expect(matchesKey("\x1b[49u", "1"));
    try std.testing.expect(matchesKey("\x1b[49;5u", "ctrl+1"));
    try std.testing.expect(!matchesKey("\x1b[49;5u", "ctrl+2"));
    try std.testing.expectEqualStrings("1", parseKey("\x1b[49u").?);
    try std.testing.expectEqualStrings("ctrl+1", parseKey("\x1b[49;5u").?);
    try std.testing.expect(matchesKey("\x1b[57400u", "1"));
    try std.testing.expect(matchesKey("\x1b[57410u", "/"));
    try std.testing.expect(matchesKey("\x1b[57417u", "left"));
    try std.testing.expect(matchesKey("\x1b[57426u", "delete"));
    try std.testing.expectEqualStrings("0", parseKey("\x1b[57399u").?);
    try std.testing.expectEqualStrings(".", parseKey("\x1b[57409u").?);
    try std.testing.expectEqualStrings("+", parseKey("\x1b[57413u").?);
    try std.testing.expectEqualStrings(",", parseKey("\x1b[57416u").?);
    try std.testing.expectEqualStrings("left", parseKey("\x1b[57417u").?);
    try std.testing.expectEqualStrings("right", parseKey("\x1b[57418u").?);
    try std.testing.expectEqualStrings("up", parseKey("\x1b[57419u").?);
    try std.testing.expectEqualStrings("down", parseKey("\x1b[57420u").?);
    try std.testing.expectEqualStrings("pageUp", parseKey("\x1b[57421u").?);
    try std.testing.expectEqualStrings("pageDown", parseKey("\x1b[57422u").?);
    try std.testing.expectEqualStrings("home", parseKey("\x1b[57423u").?);
    try std.testing.expectEqualStrings("end", parseKey("\x1b[57424u").?);
    try std.testing.expectEqualStrings("insert", parseKey("\x1b[57425u").?);
    try std.testing.expectEqualStrings("delete", parseKey("\x1b[57426u").?);
}

// Ported from packages/tui/test/keys.test.ts: Kitty event/base-layout edge cases.
test "keys handle Kitty shifted, event, and remapped layout fields" {
    setKittyProtocolActive(true);
    defer setKittyProtocolActive(false);

    try std.testing.expect(matchesKey("\x1b[99:67:99;2u", "shift+c"));
    try std.testing.expect(matchesKey("\x1b[1089::99;5:3u", "ctrl+c"));
    try std.testing.expect(matchesKey("\x1b[1089:1057:99;6:2u", "ctrl+shift+c"));
    try std.testing.expect(matchesKey("\x1b[107::118;5u", "ctrl+k"));
    try std.testing.expect(!matchesKey("\x1b[107::118;5u", "ctrl+v"));
    try std.testing.expect(matchesKey("\x1b[47::91;5u", "ctrl+/"));
    try std.testing.expect(!matchesKey("\x1b[47::91;5u", "ctrl+["));
    try std.testing.expect(!matchesKey("\x1b[1089::99;5u", "ctrl+d"));
    try std.testing.expect(!matchesKey("\x1b[1089::99;5u", "ctrl+shift+c"));
    try std.testing.expectEqualStrings("ctrl+c", parseKey("\x1b[1089::99;5u").?);
    try std.testing.expectEqualStrings("ctrl+k", parseKey("\x1b[107::118;5u").?);
    try std.testing.expectEqualStrings("ctrl+/", parseKey("\x1b[47::91;5u").?);
    try std.testing.expectEqualStrings("shift+e", parseKey("\x1b[69;2u").?);
    try std.testing.expect(parseKey("\x1b[99;17u") == null);
}

// Ported from packages/tui/test/keys.test.ts: xterm modifyOtherKeys.
test "keys parse xterm modifyOtherKeys variants" {
    setKittyProtocolActive(false);

    try std.testing.expect(matchesKey("\x1b[27;5;99~", "ctrl+c"));
    try std.testing.expectEqualStrings("ctrl+c", parseKey("\x1b[27;5;99~").?);
    try std.testing.expect(matchesKey("\x1b[27;5;100~", "ctrl+d"));
    try std.testing.expectEqualStrings("ctrl+d", parseKey("\x1b[27;5;100~").?);
    try std.testing.expect(matchesKey("\x1b[27;5;122~", "ctrl+z"));
    try std.testing.expect(matchesKey("\x1b[27;5;13~", "ctrl+enter"));
    try std.testing.expect(matchesKey("\x1b[27;2;13~", "shift+enter"));
    try std.testing.expect(matchesKey("\x1b[27;3;13~", "alt+enter"));
    try std.testing.expect(matchesKey("\x1b[27;2;9~", "shift+tab"));
    try std.testing.expect(matchesKey("\x1b[27;5;9~", "ctrl+tab"));
    try std.testing.expect(matchesKey("\x1b[27;3;9~", "alt+tab"));
    try std.testing.expect(matchesKey("\x1b[27;1;127~", "backspace"));
    try std.testing.expect(matchesKey("\x1b[27;5;127~", "ctrl+backspace"));
    try std.testing.expect(matchesKey("\x1b[27;3;127~", "alt+backspace"));
    try std.testing.expect(matchesKey("\x1b[27;1;27~", "escape"));
    try std.testing.expect(matchesKey("\x1b[27;1;32~", "space"));
    try std.testing.expect(matchesKey("\x1b[27;5;32~", "ctrl+space"));
    try std.testing.expect(matchesKey("\x1b[27;5;47~", "ctrl+/"));
    try std.testing.expect(matchesKey("\x1b[27;5;49~", "ctrl+1"));
    try std.testing.expect(matchesKey("\x1b[27;2;49~", "shift+1"));
    try std.testing.expect(matchesKey("\x1b[27;2;69~", "shift+e"));
    try std.testing.expect(matchesKey("\x1b[27;6;69~", "ctrl+shift+e"));
    try std.testing.expectEqualStrings("shift+ctrl+e", parseKey("\x1b[27;6;69~").?);
    try std.testing.expect(matchesKey("\x1b[104;7u", "ctrl+alt+h"));
    try std.testing.expectEqualStrings("ctrl+alt+h", parseKey("\x1b[104;7u").?);
    try std.testing.expect(matchesKey("\x1b[27;7;104~", "ctrl+alt+h"));
}

// Ported from packages/tui/test/keys.test.ts: legacy key matching.
test "keys parse legacy controls, symbols, alt prefixes, and navigation" {
    setKittyProtocolActive(false);
    setWindowsTerminalSessionForTesting(null);
    defer setWindowsTerminalSessionForTesting(null);

    try std.testing.expect(matchesKey("\x03", "ctrl+c"));
    try std.testing.expect(matchesKey("\x04", "ctrl+d"));
    try std.testing.expect(matchesKey("\x1b", "escape"));
    try std.testing.expect(matchesKey("\n", "enter"));
    try std.testing.expectEqualStrings("enter", parseKey("\n").?);

    setKittyProtocolActive(true);
    try std.testing.expect(matchesKey("\n", "shift+enter"));
    try std.testing.expect(!matchesKey("\n", "enter"));
    try std.testing.expectEqualStrings("shift+enter", parseKey("\n").?);
    setKittyProtocolActive(false);

    try std.testing.expect(matchesKey("\x00", "ctrl+space"));
    try std.testing.expectEqualStrings("ctrl+space", parseKey("\x00").?);
    try std.testing.expect(matchesKey("\x1c", "ctrl+\\"));
    try std.testing.expect(matchesKey("\x1d", "ctrl+]"));
    try std.testing.expect(matchesKey("\x1f", "ctrl+_"));
    try std.testing.expect(matchesKey("\x1f", "ctrl+-"));
    try std.testing.expectEqualStrings("ctrl+-", parseKey("\x1f").?);
    try std.testing.expect(matchesKey("\x1b\x1b", "ctrl+alt+["));
    try std.testing.expect(matchesKey("\x1b\x1c", "ctrl+alt+\\"));
    try std.testing.expect(matchesKey("\x1b\x1d", "ctrl+alt+]"));
    try std.testing.expect(matchesKey("\x1b\x1f", "ctrl+alt+_"));
    try std.testing.expect(matchesKey("\x1b\x1f", "ctrl+alt+-"));
    try std.testing.expectEqualStrings("ctrl+alt+-", parseKey("\x1b\x1f").?);

    try std.testing.expect(matchesKey("\x7f", "backspace"));
    try std.testing.expect(!matchesKey("\x7f", "ctrl+backspace"));
    try std.testing.expect(matchesKey("\x08", "backspace"));
    try std.testing.expect(!matchesKey("\x08", "ctrl+backspace"));
    try std.testing.expect(matchesKey("\x08", "ctrl+h"));
    setWindowsTerminalSessionForTesting(true);
    try std.testing.expect(matchesKey("\x08", "ctrl+backspace"));
    try std.testing.expect(!matchesKey("\x08", "backspace"));
    try std.testing.expectEqualStrings("ctrl+backspace", parseKey("\x08").?);
    setWindowsTerminalSessionForTesting(false);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WT_SESSION", "test-session");
    setWindowsTerminalSessionForTesting(null);
    setProcessEnvironment(&env);
    defer setProcessEnvironment(null);
    try std.testing.expect(isWindowsTerminalSessionFromEnv(&env));
    try std.testing.expect(matchesKey("\x08", "ctrl+backspace"));
    try env.put("SSH_CONNECTION", "1 2 3 4");
    try std.testing.expect(!isWindowsTerminalSessionFromEnv(&env));
    try std.testing.expect(matchesKey("\x08", "backspace"));

    try std.testing.expect(matchesKey("\x1b ", "alt+space"));
    try std.testing.expect(matchesKey("\x1b\x08", "alt+backspace"));
    try std.testing.expect(matchesKey("\x1b\x03", "ctrl+alt+c"));
    try std.testing.expect(matchesKey("\x1bB", "alt+left"));
    try std.testing.expect(matchesKey("\x1bF", "alt+right"));
    try std.testing.expect(matchesKey("\x1ba", "alt+a"));
    try std.testing.expect(matchesKey("\x1b1", "alt+1"));
    try std.testing.expect(matchesKey("\x1by", "alt+y"));
    try std.testing.expect(matchesKey("\x1bz", "alt+z"));

    setKittyProtocolActive(true);
    try std.testing.expect(!matchesKey("\x1b ", "alt+space"));
    try std.testing.expect(parseKey("\x1b ") == null);
    try std.testing.expect(matchesKey("\x1b\x08", "alt+backspace"));
    try std.testing.expect(!matchesKey("\x1b\x03", "ctrl+alt+c"));
    try std.testing.expect(!matchesKey("\x1bB", "alt+left"));
    try std.testing.expect(parseKey("\x1bB") == null);
    setKittyProtocolActive(false);

    try std.testing.expect(matchesKey("\x1b[A", "up"));
    try std.testing.expect(matchesKey("\x1b[B", "down"));
    try std.testing.expect(matchesKey("\x1b[C", "right"));
    try std.testing.expect(matchesKey("\x1b[D", "left"));
    try std.testing.expect(matchesKey("\x1bOA", "up"));
    try std.testing.expect(matchesKey("\x1bOB", "down"));
    try std.testing.expect(matchesKey("\x1bOC", "right"));
    try std.testing.expect(matchesKey("\x1bOD", "left"));
    try std.testing.expect(matchesKey("\x1bOH", "home"));
    try std.testing.expect(matchesKey("\x1bOF", "end"));
    try std.testing.expect(matchesKey("\x1bOP", "f1"));
    try std.testing.expect(matchesKey("\x1b[24~", "f12"));
    try std.testing.expect(matchesKey("\x1b[E", "clear"));
    try std.testing.expect(matchesKey("\x1bp", "alt+up"));
    try std.testing.expect(!matchesKey("\x1bp", "up"));
    try std.testing.expect(matchesKey("\x1b[a", "shift+up"));
    try std.testing.expect(matchesKey("\x1bOa", "ctrl+up"));
    try std.testing.expect(matchesKey("\x1b[2$", "shift+insert"));
    try std.testing.expect(matchesKey("\x1b[2^", "ctrl+insert"));
    try std.testing.expect(matchesKey("\x1b[7$", "shift+home"));
}

// Ported from packages/tui/test/keys.test.ts: explicit parseKey legacy regressions.
test "keys parse legacy key identifiers explicitly" {
    setKittyProtocolActive(false);

    try std.testing.expectEqualStrings("ctrl+c", parseKey("\x03").?);
    try std.testing.expectEqualStrings("ctrl+d", parseKey("\x04").?);
    try std.testing.expectEqualStrings("escape", parseKey("\x1b").?);
    try std.testing.expectEqualStrings("tab", parseKey("\t").?);
    try std.testing.expectEqualStrings("enter", parseKey("\r").?);
    try std.testing.expectEqualStrings("enter", parseKey("\n").?);
    try std.testing.expectEqualStrings("ctrl+space", parseKey("\x00").?);
    try std.testing.expectEqualStrings("space", parseKey(" ").?);
    try std.testing.expectEqualStrings("1", parseKey("1").?);
    try std.testing.expect(matchesKey("1", "1"));

    try std.testing.expectEqualStrings("up", parseKey("\x1b[A").?);
    try std.testing.expectEqualStrings("down", parseKey("\x1b[B").?);
    try std.testing.expectEqualStrings("right", parseKey("\x1b[C").?);
    try std.testing.expectEqualStrings("left", parseKey("\x1b[D").?);
    try std.testing.expectEqualStrings("up", parseKey("\x1bOA").?);
    try std.testing.expectEqualStrings("down", parseKey("\x1bOB").?);
    try std.testing.expectEqualStrings("right", parseKey("\x1bOC").?);
    try std.testing.expectEqualStrings("left", parseKey("\x1bOD").?);
    try std.testing.expectEqualStrings("home", parseKey("\x1bOH").?);
    try std.testing.expectEqualStrings("end", parseKey("\x1bOF").?);
    try std.testing.expectEqualStrings("f1", parseKey("\x1bOP").?);
    try std.testing.expectEqualStrings("f12", parseKey("\x1b[24~").?);
    try std.testing.expectEqualStrings("clear", parseKey("\x1b[E").?);
    try std.testing.expectEqualStrings("ctrl+insert", parseKey("\x1b[2^").?);
    try std.testing.expectEqualStrings("alt+up", parseKey("\x1bp").?);
    try std.testing.expectEqualStrings("pageUp", parseKey("\x1b[[5~").?);
}

// Ported from packages/tui/test/keys.test.ts: printable decoders.
test "keys decode Kitty and modifyOtherKeys printable sequences" {
    try std.testing.expectEqualStrings("0", decodeKittyPrintable("\x1b[57399u").?);
    try std.testing.expectEqualStrings("1", decodeKittyPrintable("\x1b[57400u").?);
    try std.testing.expectEqualStrings(".", decodeKittyPrintable("\x1b[57409u").?);
    try std.testing.expectEqualStrings("/", decodeKittyPrintable("\x1b[57410u").?);
    try std.testing.expectEqualStrings("*", decodeKittyPrintable("\x1b[57411u").?);
    try std.testing.expectEqualStrings("-", decodeKittyPrintable("\x1b[57412u").?);
    try std.testing.expectEqualStrings("+", decodeKittyPrintable("\x1b[57413u").?);
    try std.testing.expectEqualStrings("=", decodeKittyPrintable("\x1b[57415u").?);
    try std.testing.expectEqualStrings(",", decodeKittyPrintable("\x1b[57416u").?);
    try std.testing.expect(decodeKittyPrintable("\x1b[57417u") == null);

    try std.testing.expectEqualStrings("E", decodePrintableKey("\x1b[27;2;69~").?);
    try std.testing.expectEqualStrings("Ä", decodePrintableKey("\x1b[27;2;196~").?);
    try std.testing.expectEqualStrings(" ", decodePrintableKey("\x1b[27;2;32~").?);
    try std.testing.expect(decodePrintableKey("\x1b[27;2;13~") == null);
    try std.testing.expect(decodePrintableKey("\x1b[27;6;69~") == null);
}

// Ported from packages/tui/src/keys.ts event helper behavior.
test "keys detect Kitty repeat and release events without bracketed paste false positives" {
    try std.testing.expect(isKeyRelease("\x1b[1089::99;5:3u"));
    try std.testing.expect(isKeyRelease("\x1b[1;5:3D"));
    try std.testing.expect(!isKeyRelease("\x1b[200~90:62:3F:A5\x1b[201~"));
    try std.testing.expect(isKeyRepeat("\x1b[1089::99;5:2u"));
    try std.testing.expect(isKeyRepeat("\x1b[1;5:2D"));
    try std.testing.expect(!isKeyRepeat("\x1b[200~a:2F:b\x1b[201~"));
}
