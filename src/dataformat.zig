//! The on-disk format of the extracted game data.
//!
//! The symbol table, character map and constant names all come out of a
//! disassembly, so they are generated on the machine that builds the ROM and
//! never travel with this repository. Both the generator and the loader use
//! the definitions here, which is what keeps them from drifting apart.

const std = @import("std");

pub const magic = "POKEMCP\x01";

/// Sections are written in this order, each prefixed with a u32 count.
pub const Section = enum(u8) {
    symbols,
    charmap,
    maps,
    behaviors,
};

pub const Writer = struct {
    out: *std.Io.Writer,

    pub fn magicHeader(self: Writer, game: []const u8, commit: []const u8) !void {
        try self.out.writeAll(magic);
        try self.string(game);
        try self.string(commit);
    }

    pub fn string(self: Writer, s: []const u8) !void {
        try self.out.writeInt(u16, @intCast(s.len), .little);
        try self.out.writeAll(s);
    }

    pub fn count(self: Writer, n: usize) !void {
        try self.out.writeInt(u32, @intCast(n), .little);
    }

    pub fn u32le(self: Writer, v: u32) !void {
        try self.out.writeInt(u32, v, .little);
    }

    pub fn u16le(self: Writer, v: u16) !void {
        try self.out.writeInt(u16, v, .little);
    }

    pub fn byte(self: Writer, v: u8) !void {
        try self.out.writeByte(v);
    }
};

/// Reads back what `Writer` produced. Operates on a slice already in memory:
/// the whole table is a few hundred kilobytes and is read once at startup.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub const Error = error{ BadMagic, Truncated };

    pub fn init(bytes: []const u8) Error!Reader {
        if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic))
            return error.BadMagic;
        return .{ .bytes = bytes, .pos = magic.len };
    }

    pub fn string(self: *Reader) Error![]const u8 {
        const len = try self.u16le();
        if (self.pos + len > self.bytes.len) return error.Truncated;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    pub fn count(self: *Reader) Error!u32 {
        return self.u32le();
    }

    pub fn u32le(self: *Reader) Error!u32 {
        if (self.pos + 4 > self.bytes.len) return error.Truncated;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
    }

    pub fn u16le(self: *Reader) Error!u16 {
        if (self.pos + 2 > self.bytes.len) return error.Truncated;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.bytes[self.pos..][0..2], .little);
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.pos + 1 > self.bytes.len) return error.Truncated;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }
};

test "round trip" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const w: Writer = .{ .out = &buf.writer };
    try w.magicHeader("firered", "abc123");
    try w.count(2);
    try w.u32le(0x08000000);
    try w.string("gMain");

    var r = try Reader.init(buf.written());
    try std.testing.expectEqualStrings("firered", try r.string());
    try std.testing.expectEqualStrings("abc123", try r.string());
    try std.testing.expectEqual(@as(u32, 2), try r.count());
    try std.testing.expectEqual(@as(u32, 0x08000000), try r.u32le());
    try std.testing.expectEqualStrings("gMain", try r.string());
}
