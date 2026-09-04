//! The generated tables, loaded at startup.
//!
//! Produced by `zig build gamedata` from a built disassembly. Two lookups
//! matter: a name to its address (so the harness never hard-codes one), and
//! an address back to a name, which is what turns a raw function pointer read
//! out of RAM into "you are on the battle screen".

const std = @import("std");
const dataformat = @import("dataformat.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ BadMagic, Truncated, OutOfMemory };

pub const GameData = struct {
    arena: std.heap.ArenaAllocator,
    game: []const u8,

    /// Symbol name -> address.
    by_name: std.StringHashMapUnmanaged(u32),
    /// Every symbol, sorted by address, for nearest-preceding lookup.
    by_addr: []Symbol,
    /// Gen 3 byte -> UTF-8 character.
    charmap: [256][]const u8,
    maps: std.AutoHashMapUnmanaged(u16, []const u8),
    behaviors: std.AutoHashMapUnmanaged(u16, []const u8),

    pub const Symbol = struct { addr: u32, name: []const u8 };

    /// Every name in the returned tables points into the file bytes, so the
    /// table takes its own copy and keeps it for as long as it lives. One
    /// allocation beats duplicating a quarter of a million symbol names.
    pub fn load(gpa: Allocator, bytes: []const u8) Error!GameData {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const owned = try arena.dupe(u8, bytes);
        var r = try dataformat.Reader.init(owned);
        const game = try r.string();
        _ = try r.string(); // commit, unused for now

        var by_name: std.StringHashMapUnmanaged(u32) = .empty;
        const sym_count = try r.count();
        const syms = try arena.alloc(Symbol, sym_count);
        for (syms) |*s| {
            const addr = try r.u32le();
            const name = try r.string();
            s.* = .{ .addr = addr, .name = name };
            // Locals from different translation units share names; the first
            // definition is the one callers mean.
            const gop = try by_name.getOrPut(arena, name);
            if (!gop.found_existing) gop.value_ptr.* = addr;
        }
        std.mem.sortUnstable(Symbol, syms, {}, lessByAddr);

        var charmap: [256][]const u8 = @splat("");
        const cm_count = try r.count();
        for (0..cm_count) |_| {
            const b = try r.byte();
            charmap[b] = try r.string();
        }

        var maps: std.AutoHashMapUnmanaged(u16, []const u8) = .empty;
        const map_count = try r.count();
        for (0..map_count) |_| {
            const group = try r.byte();
            const num = try r.byte();
            const name = try r.string();
            try maps.put(arena, mapKey(group, num), name);
        }

        var behaviors: std.AutoHashMapUnmanaged(u16, []const u8) = .empty;
        const beh_count = try r.count();
        for (0..beh_count) |_| {
            const id = try r.u16le();
            const name = try r.string();
            try behaviors.put(arena, id, name);
        }

        return .{
            .arena = arena_state,
            .game = game,
            .by_name = by_name,
            .by_addr = syms,
            .charmap = charmap,
            .maps = maps,
            .behaviors = behaviors,
        };
    }

    /// Load from a file. The table is generated locally and is a few
    /// megabytes, so it is read once and kept.
    pub fn loadFile(gpa: Allocator, io: std.Io, path: []const u8) !GameData {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        defer gpa.free(bytes);
        return load(gpa, bytes);
    }

    pub fn deinit(self: *GameData) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn lessByAddr(_: void, a: Symbol, b: Symbol) bool {
        return a.addr < b.addr;
    }

    fn mapKey(group: u8, num: u8) u16 {
        return (@as(u16, group) << 8) | num;
    }

    /// Address of a symbol, or null when the table does not have it.
    pub fn find(self: *const GameData, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    /// Address of a symbol the caller knows must exist.
    pub fn must(self: *const GameData, name: []const u8) u32 {
        return self.find(name) orelse std.debug.panic(
            "symbol {s} missing from the generated table; regenerate it against the ROM you are running",
            .{name},
        );
    }

    /// Address -> symbol name.
    ///
    /// Function pointers read out of RAM are Thumb-encoded with the low bit
    /// set, so it is masked off first. An address inside a known symbol comes
    /// back as that symbol, which is what keeps an unrecognised callback
    /// legible rather than turning into a bare hex number.
    pub fn resolve(self: *const GameData, addr: u32) ?Symbol {
        if (addr == 0) return null;
        const target = addr & ~@as(u32, 1);
        var lo: usize = 0;
        var hi: usize = self.by_addr.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.by_addr[mid].addr <= target) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        const sym = self.by_addr[lo - 1];
        // Past a few KB we are almost certainly beyond the end of that symbol.
        if (target - sym.addr > 0x2000) return null;
        return sym;
    }

    pub fn mapName(self: *const GameData, group: u8, num: u8) ?[]const u8 {
        const raw = self.maps.get(mapKey(group, num)) orelse return null;
        return trimPrefix(raw, "MAP_");
    }

    pub fn behaviorName(self: *const GameData, id: u16) ?[]const u8 {
        const raw = self.behaviors.get(id) orelse return null;
        return trimPrefix(raw, "MB_");
    }

    fn trimPrefix(s: []const u8, prefix: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, s, prefix)) s[prefix.len..] else s;
    }
};

test "resolve finds the containing symbol" {
    var syms = [_]GameData.Symbol{
        .{ .addr = 0x0800_1000, .name = "First" },
        .{ .addr = 0x0800_2000, .name = "Second" },
    };
    const gd: GameData = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .game = "test",
        .by_name = .empty,
        .by_addr = &syms,
        .charmap = @splat(""),
        .maps = .empty,
        .behaviors = .empty,
    };
    try std.testing.expectEqualStrings("First", gd.resolve(0x0800_1000).?.name);
    // Thumb pointers carry the low bit; it must not shift the lookup.
    try std.testing.expectEqualStrings("Second", gd.resolve(0x0800_2001).?.name);
    try std.testing.expectEqualStrings("Second", gd.resolve(0x0800_2004).?.name);
    // Far past the last symbol is not a match.
    try std.testing.expect(gd.resolve(0x0800_9000) == null);
    try std.testing.expect(gd.resolve(0) == null);
}
