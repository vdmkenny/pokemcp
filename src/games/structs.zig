//! FireRed's data structures, as Zig types.
//!
//! These mirror include/*.h in the pret/pokefirered disassembly. Writing them
//! out as real types rather than a pile of offset constants means the compiler
//! computes every field position, and the `comptime` assertions at the bottom
//! of each group check those positions against the offsets the disassembly
//! documents. Get a field wrong and the build fails instead of the harness
//! quietly reporting nonsense.

const std = @import("std");

/// Fails the build if a field is not where the disassembly says it is.
fn expectOffset(comptime T: type, comptime field: []const u8, comptime want: comptime_int) void {
    const got = @offsetOf(T, field);
    if (got != want) @compileError(std.fmt.comptimePrint(
        "{s}.{s} is at 0x{X} but the disassembly puts it at 0x{X}",
        .{ @typeName(T), field, got, want },
    ));
}

fn expectSize(comptime T: type, comptime want: comptime_int) void {
    if (@sizeOf(T) != want) @compileError(std.fmt.comptimePrint(
        "{s} is {d} bytes, expected {d}",
        .{ @typeName(T), @sizeOf(T), want },
    ));
}

// -- shared ------------------------------------------------------------------

pub const Coords16 = extern struct { x: i16, y: i16 };

/// struct WarpData. The compiler pads a byte before the coordinate pair, which
/// is why this is 8 bytes wide and not 7.
pub const WarpData = extern struct {
    map_group: i8,
    map_num: i8,
    warp_id: i8,
    _pad: u8 = 0,
    x: i16,
    y: i16,
};

pub const Direction = enum(u4) {
    none = 0,
    south = 1,
    north = 2,
    west = 3,
    east = 4,
    _,

    pub fn delta(self: Direction) struct { x: i16, y: i16 } {
        return switch (self) {
            .north => .{ .x = 0, .y = -1 },
            .south => .{ .x = 0, .y = 1 },
            .west => .{ .x = -1, .y = 0 },
            .east => .{ .x = 1, .y = 0 },
            else => .{ .x = 0, .y = 0 },
        };
    }

    pub fn opposite(self: Direction) Direction {
        return switch (self) {
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
            else => .none,
        };
    }

    pub fn name(self: Direction) []const u8 {
        return switch (self) {
            .none => "none",
            .south => "south",
            .north => "north",
            .west => "west",
            .east => "east",
            _ => "unknown",
        };
    }

    /// Accepts compass points and d-pad names alike: the game talks in
    /// compass directions, the hardware has a d-pad, and an agent may use
    /// either.
    pub fn parse(s: []const u8) ?Direction {
        var buf: [8]u8 = undefined;
        if (s.len == 0 or s.len > buf.len) return null;
        const k = std.ascii.lowerString(&buf, s);
        const table = .{
            .{ "north", Direction.north }, .{ "up", Direction.north },
            .{ "south", Direction.south }, .{ "down", Direction.south },
            .{ "west", Direction.west },   .{ "left", Direction.west },
            .{ "east", Direction.east },   .{ "right", Direction.east },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, k, entry[0])) return entry[1];
        }
        return null;
    }
};

// -- Pokemon (include/pokemon.h) ---------------------------------------------

pub const party_size = 6;
pub const pokemon_name_length = 10;
pub const player_name_length = 7;
pub const max_mon_moves = 4;

/// status1, from include/constants/battle.h.
pub const Status = packed struct(u32) {
    sleep_turns: u3 = 0,
    poison: bool = false,
    burn: bool = false,
    freeze: bool = false,
    paralysis: bool = false,
    bad_poison: bool = false,
    _rest: u24 = 0,

    pub fn asleep(self: Status) bool {
        return self.sleep_turns != 0;
    }

    pub fn any(self: Status) bool {
        return self.asleep() or self.poison or self.burn or
            self.freeze or self.paralysis or self.bad_poison;
    }
};

pub const Growth = extern struct {
    species: u16,
    held_item: u16,
    experience: u32,
    pp_bonuses: u8,
    friendship: u8,
    _filler: u16 = 0,
};

pub const Attacks = extern struct {
    moves: [max_mon_moves]u16,
    pp: [max_mon_moves]u8,
};

pub const EffortValues = extern struct {
    hp: u8,
    attack: u8,
    defense: u8,
    speed: u8,
    sp_attack: u8,
    sp_defense: u8,
    cool: u8,
    beauty: u8,
    cute: u8,
    smart: u8,
    tough: u8,
    sheen: u8,
};

/// The individual values share one word with the egg and ability bits.
pub const IvsEgg = packed struct(u32) {
    hp: u5 = 0,
    attack: u5 = 0,
    defense: u5 = 0,
    speed: u5 = 0,
    sp_attack: u5 = 0,
    sp_defense: u5 = 0,
    is_egg: bool = false,
    ability_num: u1 = 0,
};

pub const Miscellaneous = extern struct {
    pokerus: u8,
    met_location: u8,
    origins: u16,
    ivs: IvsEgg,
    ribbons: u32,
};

pub const BoxFlags = packed struct(u8) {
    is_bad_egg: bool = false,
    has_species: bool = false,
    is_egg: bool = false,
    block_box_rs: bool = false,
    _unused: u4 = 0,
};

pub const substruct_bytes = 12;

pub const BoxPokemon = extern struct {
    personality: u32,
    ot_id: u32,
    nickname: [pokemon_name_length]u8,
    language: u8,
    flags: BoxFlags,
    ot_name: [player_name_length]u8,
    markings: u8,
    checksum: u16,
    _unknown: u16 = 0,
    /// Encrypted, and its four 12-byte substructs are permuted by personality.
    /// `pokemon.zig` unpacks it.
    secure: [substruct_bytes * 4]u8,
};

pub const Pokemon = extern struct {
    box: BoxPokemon,
    status: Status,
    level: u8,
    mail: u8,
    hp: u16,
    max_hp: u16,
    attack: u16,
    defense: u16,
    speed: u16,
    sp_attack: u16,
    sp_defense: u16,
};

comptime {
    expectSize(BoxPokemon, 80);
    expectSize(Pokemon, 100);
    expectOffset(BoxPokemon, "nickname", 0x08);
    expectOffset(BoxPokemon, "checksum", 0x1C);
    expectOffset(BoxPokemon, "secure", 0x20);
    expectOffset(Pokemon, "status", 0x50);
    expectOffset(Pokemon, "level", 0x54);
    expectOffset(Pokemon, "hp", 0x56);
    expectSize(Growth, substruct_bytes);
    expectSize(Attacks, substruct_bytes);
    expectSize(EffortValues, substruct_bytes);
    expectSize(Miscellaneous, substruct_bytes);
}

// -- battle (include/pokemon.h, include/battle.h) -----------------------------

pub const max_battlers = 4;

pub const BattlePokemon = extern struct {
    species: u16,
    attack: u16,
    defense: u16,
    speed: u16,
    sp_attack: u16,
    sp_defense: u16,
    moves: [max_mon_moves]u16,
    ivs: IvsEgg,
    stat_stages: [8]u8,
    ability: u8,
    type1: u8,
    type2: u8,
    _unknown: u8 = 0,
    pp: [max_mon_moves]u8,
    hp: u16,
    level: u8,
    friendship: u8,
    max_hp: u16,
    item: u16,
    nickname: [pokemon_name_length + 1]u8,
    pp_bonuses: u8,
    ot_name: [player_name_length + 1]u8,
    experience: u32,
    personality: u32,
    status1: Status,
    status2: u32,
    ot_id: u32,
};

/// gBattleTypeFlags, the bits this harness reports on.
pub const BattleTypeFlags = packed struct(u32) {
    double: bool = false,
    link: bool = false,
    is_master: bool = false,
    trainer: bool = false,
    first_battle: bool = false,
    _rest: u27 = 0,
};

comptime {
    expectSize(BattlePokemon, 0x58);
    expectOffset(BattlePokemon, "stat_stages", 0x18);
    expectOffset(BattlePokemon, "ability", 0x20);
    expectOffset(BattlePokemon, "pp", 0x24);
    expectOffset(BattlePokemon, "hp", 0x28);
    expectOffset(BattlePokemon, "level", 0x2A);
    expectOffset(BattlePokemon, "max_hp", 0x2C);
    expectOffset(BattlePokemon, "nickname", 0x30);
    expectOffset(BattlePokemon, "status1", 0x4C);
}

// -- field map (include/global.fieldmap.h) ------------------------------------

pub const object_events_count = 16;

pub const ObjectFlags = packed struct(u32) {
    active: bool = false,
    single_movement_active: bool = false,
    trigger_ground_effects_on_move: bool = false,
    trigger_ground_effects_on_stop: bool = false,
    disable_covering_ground_effects: bool = false,
    landing_jump: bool = false,
    held_movement_active: bool = false,
    held_movement_finished: bool = false,
    frozen: bool = false,
    facing_direction_locked: bool = false,
    disable_anim: bool = false,
    enable_anim: bool = false,
    inanimate: bool = false,
    invisible: bool = false,
    off_screen: bool = false,
    tracked_by_camera: bool = false,
    is_player: bool = false,
    has_reflection: bool = false,
    in_short_grass: bool = false,
    in_shallow_flowing_water: bool = false,
    in_sand_pile: bool = false,
    in_hot_springs: bool = false,
    has_shadow: bool = false,
    sprite_anim_paused_backup: bool = false,
    sprite_affine_anim_paused_backup: bool = false,
    disable_jump_landing_ground_effect: bool = false,
    fixed_priority: bool = false,
    hide_reflection: bool = false,
    _rest: u4 = 0,
};

pub const Nibbles = packed struct(u8) { low: u4 = 0, high: u4 = 0 };

pub const Directions = packed struct(u8) {
    facing: Direction = .none,
    movement: Direction = .none,
};

pub const ObjectEvent = extern struct {
    flags: ObjectFlags,
    sprite_id: u8,
    graphics_id: u8,
    movement_type: u8,
    trainer_type: u8,
    local_id: u8,
    map_num: u8,
    map_group: u8,
    elevation: Nibbles,
    /// Grid coordinates: the map coordinate plus MAP_OFFSET.
    initial_coords: Coords16,
    current_coords: Coords16,
    previous_coords: Coords16,
    directions: Directions,
    range: Nibbles,
    field_effect_sprite_id: u8,
    warp_arrow_sprite_id: u8,
    movement_action_id: u8,
    trainer_range_berry_tree_id: u8,
    current_metatile_behavior: u8,
    previous_metatile_behavior: u8,
    previous_movement_direction: u8,
    direction_sequence_index: u8,
    player_copyable_movement: u8,
};

comptime {
    expectSize(ObjectEvent, 0x24);
    expectOffset(ObjectEvent, "graphics_id", 0x05);
    expectOffset(ObjectEvent, "local_id", 0x08);
    expectOffset(ObjectEvent, "current_coords", 0x10);
    expectOffset(ObjectEvent, "directions", 0x18);
    expectOffset(ObjectEvent, "current_metatile_behavior", 0x1E);
}

pub const MapLayout = extern struct {
    width: i32,
    height: i32,
    border: u32,
    map: u32,
    primary_tileset: u32,
    secondary_tileset: u32,
    border_width: u8,
    border_height: u8,
};

pub const MapHeader = extern struct {
    map_layout: u32,
    events: u32,
    map_scripts: u32,
    connections: u32,
    music: u16,
    map_layout_id: u16,
    region_map_section_id: u8,
    cave: u8,
    weather: u8,
    map_type: u8,
    biking_allowed: u8,
    flags: u8,
    floor_num: i8,
    battle_type: u8,
};

pub const MapEvents = extern struct {
    object_event_count: u8,
    warp_count: u8,
    coord_event_count: u8,
    bg_event_count: u8,
    object_events: u32,
    warps: u32,
    coord_events: u32,
    bg_events: u32,
};

pub const WarpEvent = extern struct {
    x: i16,
    y: i16,
    elevation: u8,
    warp_id: u8,
    map_num: u8,
    map_group: u8,
};

pub const BgEvent = extern struct {
    x: u16,
    y: u16,
    elevation: u8,
    kind: u8,
    /// A script pointer or packed hidden-item data, depending on `kind`.
    payload: u32,
};

/// The live map grid, which includes the border and any connected maps.
pub const BackupMapLayout = extern struct {
    width: i32,
    height: i32,
    map: u32,
};

pub const Tileset = extern struct {
    is_compressed: u8,
    is_secondary: u8,
    _pad: u16 = 0,
    tiles: u32,
    palettes: u32,
    metatiles: u32,
    callback: u32,
    metatile_attributes: u32,
};

comptime {
    expectSize(WarpEvent, 8);
    expectSize(BgEvent, 12);
    expectSize(MapEvents, 20);
    expectOffset(MapEvents, "warps", 8);
    expectOffset(MapEvents, "bg_events", 16);
    expectOffset(MapHeader, "region_map_section_id", 0x14);
    expectOffset(MapHeader, "map_type", 0x17);
    expectOffset(MapLayout, "primary_tileset", 0x10);
    expectOffset(Tileset, "metatile_attributes", 0x14);
}

/// One cell of the map grid.
pub const MapBlock = packed struct(u16) {
    metatile_id: u10 = 0,
    collision: u2 = 0,
    elevation: u4 = 0,

    pub fn passable(self: MapBlock) bool {
        return self.collision == 0;
    }
};

// -- main loop (include/main.h) ----------------------------------------------

pub const Main = extern struct {
    callback1: u32,
    callback2: u32,
    saved_callback: u32,
    vblank_callback: u32,
    hblank_callback: u32,
    vcount_callback: u32,
    serial_callback: u32,
    intr_check: u16,
    _pad: u16 = 0,
    vblank_counter1: u32,
    vblank_counter2: u32,
    held_keys_raw: u16,
    new_keys_raw: u16,
    held_keys: u16,
    new_keys: u16,
    new_and_repeated_keys: u16,
    key_repeat_counter: u16,
    watched_keys_pressed: u16,
    watched_keys_mask: u16,
};

comptime {
    expectOffset(Main, "callback2", 0x04);
    expectOffset(Main, "held_keys", 0x2C);
    expectOffset(Main, "new_keys", 0x2E);
}

/// gMain.state and the bitfield after it sit at 0x438; `inBattle` is bit 1 of
/// the byte at 0x439. Reading one byte is simpler than modelling the 128-entry
/// OAM buffer that separates them.
pub const main_in_battle_offset = 0x439;
pub const main_in_battle_mask = 0x02;

// -- text printers (include/text.h) ------------------------------------------

pub const num_text_printers = 32;

pub const TextPrinterTemplate = extern struct {
    current_char: u32,
    window_id: u8,
    font_id: u8,
    x: u8,
    y: u8,
    current_x: u8,
    current_y: u8,
    letter_spacing: u8,
    line_spacing: u8,
    colors: u16,
};

pub const TextPrinter = extern struct {
    template: TextPrinterTemplate,
    callback: u32,
    sub_union: [7]u8,
    active: u8,
    state: u8,
    text_speed: u8,
    delay_counter: u8,
    scroll_distance: u8,
    min_letter_spacing: u8,
    japanese: u8,
};

comptime {
    expectSize(TextPrinter, 0x24);
    expectOffset(TextPrinter, "callback", 0x10);
    expectOffset(TextPrinter, "active", 0x1B);
    expectOffset(TextPrinter, "state", 0x1C);
}

test "direction parsing accepts compass and d-pad names" {
    try std.testing.expectEqual(Direction.north, Direction.parse("up").?);
    try std.testing.expectEqual(Direction.north, Direction.parse("NORTH").?);
    try std.testing.expectEqual(Direction.east, Direction.parse("right").?);
    try std.testing.expect(Direction.parse("sideways") == null);
    try std.testing.expectEqual(Direction.south, Direction.north.opposite());
    try std.testing.expectEqual(@as(i16, -1), Direction.north.delta().y);
}

test "map block splits into metatile, collision and elevation" {
    const block: MapBlock = @bitCast(@as(u16, 0x3401));
    try std.testing.expectEqual(@as(u10, 0x001), block.metatile_id);
    try std.testing.expectEqual(@as(u2, 1), block.collision);
    try std.testing.expectEqual(@as(u4, 3), block.elevation);
    try std.testing.expect(!block.passable());
}

test "status bits" {
    const s: Status = @bitCast(@as(u32, 0x08));
    try std.testing.expect(s.poison);
    try std.testing.expect(!s.asleep());
    const sleepy: Status = @bitCast(@as(u32, 0x03));
    try std.testing.expect(sleepy.asleep());
}
