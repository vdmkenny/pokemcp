//! What an agent gets to see.
//!
//! Deliberately limited to what the Game Boy Advance screen shows: the 15x10
//! metatiles around the player, the NPCs and doors inside them, and any text
//! box that is up. There is no whole-map view and no route planning, so
//! crossing a map means reading the screen, moving, and reading again.
//!
//! The party is the one exception and is always present: a player can open the
//! party menu at any time, so that information is never hidden.

const std = @import("std");

pub const Mode = enum {
    title,
    overworld,
    battle,
    menu,
    other,
    unknown,
};

pub const Screen = struct {
    /// The game's own main-loop callback, resolved through the symbol table.
    /// This is the most reliable "where am I" signal the game has.
    callback2: []const u8,
    callback1: []const u8,
    mode: Mode,
    in_battle: bool,
    /// While the screen is fading, input is ignored.
    fade_active: bool,
};

pub const Move = struct {
    name: []const u8,
    id: u16,
    pp: u8,
};

pub const Mon = struct {
    slot: u8,
    species: []const u8,
    species_id: u16,
    nickname: []const u8,
    level: u8,
    hp: u16,
    max_hp: u16,
    hp_percent: u8,
    status: []const []const u8,
    moves: []const Move,
    held_item: ?[]const u8 = null,
    is_egg: bool = false,
    nature: []const u8,
    friendship: u8,
    /// Absent when the game's checksum disagrees with what we decoded.
    checksum_ok: bool = true,
};

pub const Player = struct {
    name: []const u8,
    gender: []const u8,
    trainer_id: u16,
    money: u32,
    badges: []const []const u8,
    play_time: []const u8,
    facing: []const u8,
};

pub const Location = struct {
    map: []const u8,
    map_group: i8,
    map_num: i8,
    x: i16,
    y: i16,
    is_cave: bool,
    weather: u8,
};

pub const Dialog = struct {
    text: []const u8,
    box_open: bool,
    still_printing: bool,
};

pub const Npc = struct {
    local_id: u8,
    x: i16,
    y: i16,
    facing: []const u8,
    kind: []const u8,
    graphics_id: u8,
};

pub const Warp = struct {
    x: i16,
    y: i16,
    /// The terrain type of the tile, which is what says how it is entered.
    behavior: []const u8,
    /// "Stand on it and press this way", or null when it fires on arrival.
    /// Arrow tiles draw their arrow on screen, so this is visible information.
    trigger: ?[]const u8,
};

pub const Sign = struct {
    x: i16,
    y: i16,
    kind: u8,
};

pub const Tile = struct {
    x: i16,
    y: i16,
    passable: bool,
    elevation: u4,
    behavior: []const u8,
};

pub const Viewport = struct {
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,
    width: u8,
    height: u8,
};

pub const Overworld = struct {
    location: Location,
    viewport: Viewport,
    /// The 15x10 window as ASCII, one row per line.
    view: []const u8,
    legend: []const u8,
    tile_ahead: ?Tile,
    npcs: []const Npc,
    warps: []const Warp,
    signs: []const Sign,
};

pub const Battler = struct {
    side: []const u8,
    species: []const u8,
    nickname: []const u8,
    level: u8,
    hp: u16,
    max_hp: u16,
    hp_percent: u8,
    status: []const []const u8,
    ability: []const u8,
    types: []const []const u8,
    moves: []const Move,
};

pub const Battle = struct {
    is_trainer_battle: bool,
    is_double: bool,
    battlers: []const Battler,
    message: []const u8,
};

pub const Menu = struct {
    kind: []const u8,
    options: []const []const u8,
    cursor: u8,
    selected: ?[]const u8,
    /// Battle menus additionally track which move is highlighted.
    move_cursor: ?u8 = null,
    moves: []const Move = &.{},
};

/// The mode-specific half of an observation.
pub const Details = union(enum) {
    overworld: Overworld,
    battle: Battle,
    /// A menu, a cutscene, the title screen -- anywhere the map is not shown.
    elsewhere: void,
};

pub const Observation = struct {
    frame: u32,
    mode: Mode,
    screen: Screen,
    player: Player,
    party: []const Mon,
    dialog: ?Dialog,
    menu: ?Menu,
    details: Details,
};
