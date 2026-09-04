//! Unpacking a stored Pokemon.
//!
//! The interesting half of a Pokemon -- species, moves, IVs, EVs -- lives in a
//! 48-byte block that is XOR-encrypted and whose four 12-byte substructs are
//! permuted by the personality value. This undoes both and checks the result
//! against the game's own checksum, so a bad decode is never reported as real
//! data.

const std = @import("std");
const s = @import("structs.zig");

/// sSubstructOrders in src/pokemon.c: [personality % 24][substruct] -> slot.
const substruct_orders = [24][4]u2{
    .{ 0, 1, 2, 3 }, .{ 0, 1, 3, 2 }, .{ 0, 2, 1, 3 }, .{ 0, 3, 1, 2 },
    .{ 0, 2, 3, 1 }, .{ 0, 3, 2, 1 }, .{ 1, 0, 2, 3 }, .{ 1, 0, 3, 2 },
    .{ 2, 0, 1, 3 }, .{ 3, 0, 1, 2 }, .{ 2, 0, 3, 1 }, .{ 3, 0, 2, 1 },
    .{ 1, 2, 0, 3 }, .{ 1, 3, 0, 2 }, .{ 2, 1, 0, 3 }, .{ 3, 1, 0, 2 },
    .{ 2, 3, 0, 1 }, .{ 3, 2, 0, 1 }, .{ 1, 2, 3, 0 }, .{ 1, 3, 2, 0 },
    .{ 2, 1, 3, 0 }, .{ 3, 1, 2, 0 }, .{ 2, 3, 1, 0 }, .{ 3, 2, 1, 0 },
};

pub const Nature = enum(u8) {
    hardy, lonely, brave, adamant, naughty,
    bold, docile, relaxed, impish, lax,
    timid, hasty, serious, jolly, naive,
    modest, mild, quiet, bashful, rash,
    calm, gentle, sassy, careful, quirky,

    pub fn fromPersonality(personality: u32) Nature {
        return @enumFromInt(@as(u8, @intCast(personality % 25)));
    }

    pub fn name(self: Nature) []const u8 {
        return @tagName(self);
    }
};

/// The four substructs, decrypted and put back in a known order.
pub const Secure = struct {
    growth: s.Growth,
    attacks: s.Attacks,
    evs: s.EffortValues,
    misc: s.Miscellaneous,
    /// False when the game's own checksum disagrees with what we decoded.
    /// An unhatched slot or a mid-write read will land here.
    checksum_ok: bool,
};

/// Decrypt and unscramble a box Pokemon's secure block.
pub fn unpack(box: s.BoxPokemon) Secure {
    const key = box.personality ^ box.ot_id;

    var plain: [s.substruct_bytes * 4]u8 = undefined;
    var i: usize = 0;
    while (i < plain.len) : (i += 4) {
        const word = std.mem.readInt(u32, box.secure[i..][0..4], .little) ^ key;
        std.mem.writeInt(u32, plain[i..][0..4], word, .little);
    }

    // The game's integrity check: every u16 of the decrypted block, summed.
    var sum: u16 = 0;
    var j: usize = 0;
    while (j < plain.len) : (j += 2) {
        sum +%= std.mem.readInt(u16, plain[j..][0..2], .little);
    }

    const order = substruct_orders[box.personality % 24];
    return .{
        .growth = slot(s.Growth, &plain, order[0]),
        .attacks = slot(s.Attacks, &plain, order[1]),
        .evs = slot(s.EffortValues, &plain, order[2]),
        .misc = slot(s.Miscellaneous, &plain, order[3]),
        .checksum_ok = sum == box.checksum,
    };
}

fn slot(comptime T: type, plain: *const [s.substruct_bytes * 4]u8, index: u2) T {
    const off = @as(usize, index) * s.substruct_bytes;
    var out: T = undefined;
    @memcpy(std.mem.asBytes(&out), plain[off..][0..s.substruct_bytes]);
    return out;
}

/// True for a party slot that holds no Pokemon.
pub fn isEmpty(mon: s.Pokemon, secure: Secure) bool {
    return secure.growth.species == 0 and !secure.checksum_ok and mon.level == 0;
}

test "encrypt/decrypt round trip with the real permutation" {
    var box: s.BoxPokemon = std.mem.zeroes(s.BoxPokemon);
    box.personality = 0x1234_5678;
    box.ot_id = 0x9ABC_DEF0;

    // Build the plaintext the game would have: growth in its permuted slot.
    const order = substruct_orders[box.personality % 24];
    var plain: [48]u8 = @splat(0);
    const growth: s.Growth = .{
        .species = 25,
        .held_item = 0,
        .experience = 1000,
        .pp_bonuses = 0,
        .friendship = 70,
    };
    @memcpy(
        plain[@as(usize, order[0]) * 12 ..][0..12],
        std.mem.asBytes(&growth),
    );

    var sum: u16 = 0;
    var j: usize = 0;
    while (j < plain.len) : (j += 2) sum +%= std.mem.readInt(u16, plain[j..][0..2], .little);
    box.checksum = sum;

    const key = box.personality ^ box.ot_id;
    var i: usize = 0;
    while (i < plain.len) : (i += 4) {
        const w = std.mem.readInt(u32, plain[i..][0..4], .little) ^ key;
        std.mem.writeInt(u32, box.secure[i..][0..4], w, .little);
    }

    const got = unpack(box);
    try std.testing.expect(got.checksum_ok);
    try std.testing.expectEqual(@as(u16, 25), got.growth.species);
    try std.testing.expectEqual(@as(u32, 1000), got.growth.experience);
    try std.testing.expectEqual(@as(u8, 70), got.growth.friendship);
}

test "a corrupted block fails its checksum" {
    var box: s.BoxPokemon = std.mem.zeroes(s.BoxPokemon);
    box.personality = 7;
    box.ot_id = 9;
    box.checksum = 0x1234;
    try std.testing.expect(!unpack(box).checksum_ok);
}

test "natures come from the personality value" {
    try std.testing.expectEqual(Nature.hardy, Nature.fromPersonality(0));
    try std.testing.expectEqual(Nature.quirky, Nature.fromPersonality(24));
    try std.testing.expectEqual(Nature.hardy, Nature.fromPersonality(25));
    try std.testing.expectEqualStrings("adamant", Nature.fromPersonality(3).name());
}
