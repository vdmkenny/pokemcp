//! Extracts everything the harness needs from a built pokefirered checkout.
//!
//!     zig build gamedata -- <disassembly-dir> [output.dat]
//!
//! Reads the linked ELF's symbol table directly, plus the charmap and the
//! constant headers, and writes the binary table `src/gamedata.zig` loads.
//! The result is derived from the disassembly, so it stays on the machine
//! that produced it: this repository ships the extractor, not the data.

const std = @import("std");
const dataformat = @import("dataformat");

const usage =
    \\usage: gen-gamedata <pokefirered-dir> [out.dat]
    \\
    \\  <pokefirered-dir>  a built pret/pokefirered checkout (pokefirered.elf present)
    \\  [out.dat]          defaults to data/firered.dat
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const disasm = args[1];
    const out_path = if (args.len > 2) args[2] else "data/firered.dat";

    var dir = std.Io.Dir.cwd().openDir(io, disasm, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ disasm, @errorName(err) });
        std.process.exit(1);
    };
    defer dir.close(io);

    const elf_bytes = readFile(arena, io, dir, "pokefirered.elf") catch {
        std.debug.print(
            "{s}/pokefirered.elf not found -- build the ROM first (see README)\n",
            .{disasm},
        );
        std.process.exit(1);
    };

    const symbols = try readSymbols(arena, elf_bytes);
    const charmap = try readCharmap(arena, try readFile(arena, io, dir, "charmap.txt"));
    const maps = try readMapConstants(
        arena,
        try readFile(arena, io, dir, "include/constants/map_groups.h"),
    );
    const behaviors = try readBehaviors(
        arena,
        try readFile(arena, io, dir, "include/constants/metatile_behaviors.h"),
    );

    var buf: std.Io.Writer.Allocating = .init(arena);
    defer buf.deinit();
    const w: dataformat.Writer = .{ .out = &buf.writer };

    try w.magicHeader("pokefirered", "");

    try w.count(symbols.len);
    for (symbols) |s| {
        try w.u32le(s.addr);
        try w.string(s.name);
    }
    try w.count(charmap.count());
    {
        var it = charmap.iterator();
        while (it.next()) |e| {
            try w.byte(e.key_ptr.*);
            try w.string(e.value_ptr.*);
        }
    }
    try w.count(maps.items.len);
    for (maps.items) |m| {
        try w.byte(m.group);
        try w.byte(m.num);
        try w.string(m.name);
    }
    try w.count(behaviors.items.len);
    for (behaviors.items) |b| {
        try w.u16le(b.id);
        try w.string(b.name);
    }

    if (std.fs.path.dirname(out_path)) |d| {
        std.Io.Dir.cwd().createDirPath(io, d) catch {};
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = buf.written() });

    std.debug.print(
        "wrote {s}\n  symbols:   {d}\n  charmap:   {d}\n  maps:      {d}\n  behaviors: {d}\n",
        .{ out_path, symbols.len, charmap.count(), maps.items.len, behaviors.items.len },
    );
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub: []const u8) ![]u8 {
    return dir.readFileAlloc(io, sub, gpa, .limited(64 << 20));
}

const Symbol = struct { addr: u32, name: []const u8 };

/// Walk the ELF section headers to the symbol table and pull out every named
/// symbol with an address. `nm` would do this too, but parsing it ourselves
/// keeps the extractor free of a toolchain dependency.
fn readSymbols(gpa: std.mem.Allocator, bytes: []const u8) ![]Symbol {
    if (bytes.len < @sizeOf(std.elf.Elf32_Ehdr)) return error.NotAnElf;
    if (!std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return error.NotAnElf;

    const hdr = std.mem.bytesToValue(std.elf.Elf32_Ehdr, bytes[0..@sizeOf(std.elf.Elf32_Ehdr)]);
    var out: std.ArrayList(Symbol) = .empty;

    var i: usize = 0;
    while (i < hdr.e_shnum) : (i += 1) {
        const off = hdr.e_shoff + i * hdr.e_shentsize;
        if (off + @sizeOf(std.elf.Elf32_Shdr) > bytes.len) break;
        const sh = std.mem.bytesToValue(
            std.elf.Elf32_Shdr,
            bytes[off..][0..@sizeOf(std.elf.Elf32_Shdr)],
        );
        if (sh.sh_type != std.elf.SHT_SYMTAB) continue;

        const str_off = hdr.e_shoff + sh.sh_link * hdr.e_shentsize;
        const strtab_hdr = std.mem.bytesToValue(
            std.elf.Elf32_Shdr,
            bytes[str_off..][0..@sizeOf(std.elf.Elf32_Shdr)],
        );
        const strtab = bytes[strtab_hdr.sh_offset..][0..strtab_hdr.sh_size];
        const syms = bytes[sh.sh_offset..][0..sh.sh_size];

        var j: usize = 0;
        while (j + @sizeOf(std.elf.Elf32_Sym) <= syms.len) : (j += @sizeOf(std.elf.Elf32_Sym)) {
            const sym = std.mem.bytesToValue(
                std.elf.Elf32_Sym,
                syms[j..][0..@sizeOf(std.elf.Elf32_Sym)],
            );
            if (sym.st_name == 0 or sym.st_value == 0) continue;
            // Sections and files are not addressable by name.
            const kind = sym.st_type();
            if (kind != std.elf.STT_OBJECT and kind != std.elf.STT_FUNC and kind != std.elf.STT_NOTYPE)
                continue;
            const name = std.mem.sliceTo(strtab[sym.st_name..], 0);
            if (name.len == 0) continue;
            // ARM mapping symbols ($a, $t, $d) mark instruction-set changes
            // rather than named things. They sit at the same addresses as real
            // code and would win every nearest-address lookup, so a callback
            // would resolve to "$t" instead of the function it points into.
            if (name[0] == '$') continue;
            // Thumb functions are stored with bit 0 set, which is how the CPU
            // is told the instruction set -- it is not part of the address.
            // Callbacks read out of RAM carry the same bit, so both sides are
            // normalised here (this is what `nm` shows too). Data symbols keep
            // their value: a byte array can legitimately start on an odd
            // address.
            const addr = if (kind == std.elf.STT_FUNC) sym.st_value & ~@as(u32, 1) else sym.st_value;
            try out.append(gpa, .{ .addr = addr, .name = name });
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Byte -> UTF-8 character, from charmap.txt.
///
/// Several byte values appear twice: once in the Latin block and again in the
/// Japanese kana block further down (0x1B is both "e-acute" and a hiragana).
/// The Latin block comes first and is the right reading for an English ROM,
/// so the first definition wins.
const Charmap = std.AutoArrayHashMapUnmanaged(u8, []const u8);

fn readCharmap(gpa: std.mem.Allocator, text: []const u8) !Charmap {
    var map: Charmap = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 5 or line[0] != '\'') continue;
        // '<char>' = XX
        const close = std.mem.lastIndexOfScalar(u8, line, '\'') orelse continue;
        if (close == 0) continue;
        var ch = line[1..close];
        if (std.mem.eql(u8, ch, "\\'")) ch = "'";
        if (ch.len == 0) continue;
        const eq = std.mem.indexOfScalarPos(u8, line, close, '=') orelse continue;
        const rest = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        const hex = firstToken(rest);
        if (hex.len != 2) continue;
        const value = std.fmt.parseInt(u8, hex, 16) catch continue;
        if (!map.contains(value)) try map.put(gpa, value, ch);
    }
    return map;
}

const MapName = struct { group: u8, num: u8, name: []const u8 };

/// `#define MAP_PALLET_TOWN (0 | (3 << 8))` -> group 3, number 0.
fn readMapConstants(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(MapName) {
    var out: std.ArrayList(MapName) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "#define MAP_")) continue;
        var rest = line["#define ".len..];
        const name = firstToken(rest);
        rest = rest[name.len..];
        const open = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const num = parseFirstInt(rest[open + 1 ..]) orelse continue;
        const shift = std.mem.indexOf(u8, rest, "<<") orelse continue;
        // the group is the number just before the shift operator
        const before = std.mem.trimEnd(u8, rest[0..shift], " \t");
        const group = lastInt(before) orelse continue;
        try out.append(gpa, .{
            .group = @intCast(group),
            .num = @intCast(num),
            .name = name,
        });
    }
    return out;
}

const Behavior = struct { id: u16, name: []const u8 };

fn readBehaviors(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(Behavior) {
    var out: std.ArrayList(Behavior) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "#define MB_")) continue;
        var rest = line["#define ".len..];
        const name = firstToken(rest);
        rest = std.mem.trim(u8, rest[name.len..], " \t");
        const value = parseCInt(firstToken(rest)) orelse continue;
        try out.append(gpa, .{ .id = @intCast(value), .name = name });
    }
    return out;
}

// -- small parsing helpers ---------------------------------------------------

fn firstToken(s: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, s, " \t");
    var end: usize = 0;
    while (end < t.len and !std.ascii.isWhitespace(t[end]) and t[end] != '(' and t[end] != ')') : (end += 1) {}
    return t[0..end];
}

fn parseCInt(tok: []const u8) ?u32 {
    if (tok.len == 0) return null;
    if (std.mem.startsWith(u8, tok, "0x") or std.mem.startsWith(u8, tok, "0X"))
        return std.fmt.parseInt(u32, tok[2..], 16) catch null;
    return std.fmt.parseInt(u32, tok, 10) catch null;
}

fn parseFirstInt(s: []const u8) ?u32 {
    var i: usize = 0;
    while (i < s.len and !std.ascii.isDigit(s[i])) : (i += 1) {}
    var j = i;
    while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {}
    if (i == j) return null;
    return std.fmt.parseInt(u32, s[i..j], 10) catch null;
}

fn lastInt(s: []const u8) ?u32 {
    var end = s.len;
    while (end > 0 and !std.ascii.isDigit(s[end - 1])) : (end -= 1) {}
    if (end == 0) return null;
    var start = end;
    while (start > 0 and std.ascii.isDigit(s[start - 1])) : (start -= 1) {}
    return std.fmt.parseInt(u32, s[start..end], 10) catch null;
}

test "map constant parsing" {
    const line = "#define MAP_PALLET_TOWN (0 | (3 << 8))\n";
    var list = try readMapConstants(std.testing.allocator, line);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(u8, 3), list.items[0].group);
    try std.testing.expectEqual(@as(u8, 0), list.items[0].num);
    try std.testing.expectEqualStrings("MAP_PALLET_TOWN", list.items[0].name);
}

test "charmap keeps the first definition of a byte" {
    const text = "'e'         = 1B\n'X' = 1B\n";
    var map = try readCharmap(std.testing.allocator, text);
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("e", map.get(0x1B).?);
}
