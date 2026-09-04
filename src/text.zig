//! Gen 3 text.
//!
//! Game text is not ASCII: it is a custom single-byte encoding with embedded
//! control codes, described by the disassembly's charmap.txt. Decoding it is
//! what lets an agent read dialogue, names and menu entries as plain strings
//! instead of looking at pixels.

const std = @import("std");

/// Byte values that mean something other than "print this character".
pub const Control = enum(u8) {
    /// Waits for a button press, then scrolls the box up a line.
    prompt_scroll = 0xFA,
    /// Waits for a button press, then clears the box.
    prompt_clear = 0xFB,
    /// Introduces an extended control code (colour, font, pauses, sounds).
    ext = 0xFC,
    /// Introduces a runtime substitution such as the player's name.
    placeholder = 0xFD,
    newline = 0xFE,
    end = 0xFF,
    _,
};

/// Runtime substitutions, spliced in by the game as it prints.
pub const Placeholder = enum(u8) {
    unknown = 0x00,
    player = 0x01,
    string_var_1 = 0x02,
    string_var_2 = 0x03,
    string_var_3 = 0x04,
    kun = 0x05,
    rival = 0x06,
    version = 0x07,
    magma = 0x08,
    aqua = 0x09,
    maxie = 0x0A,
    archie = 0x0B,
    groudon = 0x0C,
    kyogre = 0x0D,
    _,

    /// The text shown when the game has not told us the real value.
    pub fn fallback(self: Placeholder) []const u8 {
        return switch (self) {
            .player => "{PLAYER}",
            .string_var_1 => "{STR_VAR_1}",
            .string_var_2 => "{STR_VAR_2}",
            .string_var_3 => "{STR_VAR_3}",
            .rival => "{RIVAL}",
            .version => "{VERSION}",
            else => "{VAR}",
        };
    }
};

/// Total length of an extended control code including the code byte itself.
/// Mirrors GetExtCtrlCodeLength in src/string_util.c; a wrong length here
/// would make the decoder print the code's arguments as text.
const ext_lengths = [_]u8{
    1, 2, 2, 2, 4, 2, 2, 1, 2, 1, 1, 3, 2,
    2, 2, 1, 3, 2, 2, 2, 2, 1, 1, 1, 1,
};

/// Values the game can splice into a message, indexed by placeholder id.
pub const Substitutions = struct {
    values: [16]?[]const u8 = @splat(null),

    pub fn set(self: *Substitutions, which: Placeholder, value: []const u8) void {
        const i = @intFromEnum(which);
        if (i < self.values.len) self.values[i] = value;
    }

    pub fn get(self: Substitutions, which: Placeholder) ?[]const u8 {
        const i = @intFromEnum(which);
        return if (i < self.values.len) self.values[i] else null;
    }
};

pub const Options = struct {
    /// Values for {PLAYER} and friends, so dialogue reads with real names.
    subs: Substitutions = .{},
    /// Render "press A to continue" breaks as a blank line rather than a marker.
    paragraph_as_blank_line: bool = true,
};

/// Decode a Gen 3 string up to its terminator, appending to `out`.
///
/// Line breaks become "\n" and paragraph breaks become "\n\n", so an agent can
/// tell that more text follows without being shown control bytes.
pub fn decode(
    out: *std.Io.Writer,
    raw: []const u8,
    charmap: *const [256][]const u8,
    options: Options,
) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < raw.len) {
        const byte = raw[i];
        switch (@as(Control, @enumFromInt(byte))) {
            .end => return,
            .newline => {
                try out.writeByte('\n');
                i += 1;
            },
            .prompt_scroll, .prompt_clear => {
                try out.writeAll(if (options.paragraph_as_blank_line) "\n\n" else "{PROMPT}");
                i += 1;
            },
            .ext => {
                if (i + 1 >= raw.len) return;
                const code = raw[i + 1];
                const len: usize = if (code < ext_lengths.len) ext_lengths[code] else 1;
                i += 1 + len;
            },
            .placeholder => {
                if (i + 1 >= raw.len) return;
                const which: Placeholder = @enumFromInt(raw[i + 1]);
                try out.writeAll(options.subs.get(which) orelse which.fallback());
                i += 2;
            },
            else => {
                const glyph = charmap[byte];
                try out.writeAll(if (glyph.len != 0) glyph else "?");
                i += 1;
            },
        }
    }
}

/// Decode into a freshly allocated string.
pub fn decodeAlloc(
    gpa: std.mem.Allocator,
    raw: []const u8,
    charmap: *const [256][]const u8,
    options: Options,
) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    try decode(&buf.writer, raw, charmap, options);
    return buf.toOwnedSlice();
}

/// Encode UTF-8 into the game's character set.
///
/// The reverse of `decode`, used to type a name straight into a naming
/// screen's buffer. Characters the game has no glyph for are refused rather
/// than silently replaced: a name is the player's, and quietly changing it
/// would be worse than saying it cannot be typed.
pub fn encode(
    out: []u8,
    text: []const u8,
    charmap: *const [256][]const u8,
) error{ NameTooLong, UnsupportedCharacter }![]u8 {
    var written: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // The charmap holds UTF-8, so match the longest glyph first: a
        // multi-byte character must not be mistaken for its first byte.
        var matched = false;
        var best_len: usize = 0;
        var best_byte: u8 = 0;
        for (charmap, 0..) |glyph, byte| {
            if (glyph.len == 0 or glyph.len > text.len - i) continue;
            if (!std.mem.eql(u8, glyph, text[i..][0..glyph.len])) continue;
            if (glyph.len > best_len) {
                best_len = glyph.len;
                best_byte = @intCast(byte);
                matched = true;
            }
        }
        if (!matched) return error.UnsupportedCharacter;
        if (written >= out.len) return error.NameTooLong;
        out[written] = best_byte;
        written += 1;
        i += best_len;
    }
    if (written >= out.len) return error.NameTooLong;
    out[written] = @intFromEnum(Control.end);
    return out[0 .. written + 1];
}

/// Decode a name-shaped string: single line, surrounding space removed.
/// Names and menu entries carry padding that is an artifact of the text box.
pub fn decodeName(
    out: []u8,
    raw: []const u8,
    charmap: *const [256][]const u8,
) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    decode(&w, raw, charmap, .{}) catch {};
    const written = w.buffered();
    return std.mem.trim(u8, written, " \n\t");
}

fn testCharmap() [256][]const u8 {
    var cm: [256][]const u8 = @splat("");
    cm[0x00] = " ";
    cm[0xBB] = "A";
    cm[0xBC] = "B";
    cm[0xD5] = "o";
    return cm;
}

test "plain text stops at the terminator" {
    const cm = testCharmap();
    const out = try decodeAlloc(
        std.testing.allocator,
        &.{ 0xBB, 0xBC, 0xFF, 0xBB },
        &cm,
        .{},
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("AB", out);
}

test "newlines and paragraph breaks" {
    const cm = testCharmap();
    const out = try decodeAlloc(
        std.testing.allocator,
        &.{ 0xBB, 0xFE, 0xBC, 0xFB, 0xBB, 0xFF },
        &cm,
        .{},
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("A\nB\n\nA", out);
}

test "extended control codes are skipped with their arguments" {
    const cm = testCharmap();
    // FC 04 takes three argument bytes; none of them should be printed.
    const out = try decodeAlloc(
        std.testing.allocator,
        &.{ 0xBB, 0xFC, 0x04, 0xBB, 0xBB, 0xBB, 0xBC, 0xFF },
        &cm,
        .{},
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("AB", out);
}

test "encode is the inverse of decode" {
    const cm = testCharmap();
    var buf: [16]u8 = undefined;
    const bytes = try encode(&buf, "AB A", &cm);
    try std.testing.expectEqualSlices(u8, &.{ 0xBB, 0xBC, 0x00, 0xBB, 0xFF }, bytes);

    const back = try decodeAlloc(std.testing.allocator, bytes, &cm, .{});
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings("AB A", back);
}

test "encode refuses what the game cannot show" {
    const cm = testCharmap();
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.UnsupportedCharacter, encode(&buf, "Z", &cm));
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.NameTooLong, encode(&tiny, "AAAA", &cm));
}

test "placeholders use the runtime value when there is one" {
    const cm = testCharmap();
    var opts: Options = .{};
    opts.subs.set(.player, "RED");
    const out = try decodeAlloc(
        std.testing.allocator,
        &.{ 0xFD, 0x01, 0x00, 0xBB, 0xFF },
        &cm,
        opts,
    );
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("RED A", out);

    const bare = try decodeAlloc(std.testing.allocator, &.{ 0xFD, 0x01, 0xFF }, &cm, .{});
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("{PLAYER}", bare);
}
