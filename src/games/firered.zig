//! Pokemon FireRed / LeafGreen (Game Boy Advance).
//!
//! Every address comes from the generated symbol table rather than being
//! hard-coded, and every structure is a checked Zig type in `structs.zig`, so
//! rebuilding the ROM -- or pointing the extractor at a romhack built from the
//! same disassembly -- keeps this working.

const std = @import("std");
const mgba = @import("../mgba.zig");
const text = @import("../text.zig");
const obs = @import("../observation.zig");
const gamedata = @import("../gamedata.zig");
const s = @import("structs.zig");
const pk = @import("pokemon.zig");

const Allocator = std.mem.Allocator;
const GameData = gamedata.GameData;

pub const name = "pokefirered";
/// Cartridge game codes this adapter claims.
pub const rom_codes = [_][]const u8{ "BPRE", "BPRS", "BPGE", "BPGS" };

/// What the screen actually shows. 240x160 pixels with 16x16 metatiles is
/// exactly 15x10 tiles, and the camera keeps the player at column 7, row 4.
/// Verified against a frame capture: an NPC three tiles below the player
/// renders three metatiles lower, and the map edges line up with these bounds.
pub const view_w = 15;
pub const view_h = 10;
pub const view_player_col = 7;
pub const view_player_row = 4;

/// Object events store their position in grid space; warps, signs and the
/// player position in the save block use plain map coordinates.
const map_offset = 7;

const num_metatiles_in_primary = 640;
const num_metatiles_total = 1024;
const metatile_behavior_mask = 0x1FF;

const sys_flags = 0x800;
const flag_badge01 = sys_flags + 0x20;

// Save block field offsets. The disassembly documents these in include/global.h;
// they are listed here rather than as a 15KB struct because only a handful of
// a save block's fields matter to an agent.
const sb1 = struct {
    const pos = 0x0000;
    const location = 0x0004;
    const weather = 0x002E;
    const party_count = 0x0034;
    const party = 0x0038;
    const money = 0x0290;
    const flags = 0x0EE0;
    const vars = 0x1000;
    const rival_name = 0x3A4C;
};

const sb2 = struct {
    const player_name = 0x000;
    const gender = 0x008;
    const trainer_id = 0x00A;
    const play_time_hours = 0x00E;
    const play_time_minutes = 0x010;
    const encryption_key = 0xF20;
};

/// How a warp tile is entered, decided by its terrain type.
/// A warp tile whose behaviour is not listed is an arrival point only: the
/// game will never send you anywhere from it, and every building has several.
pub const WarpTrigger = union(enum) {
    /// Fires as soon as you step on the tile.
    on_step,
    /// Stand on it, then keep walking this way.
    press: s.Direction,

    pub fn forBehavior(behavior: []const u8) ?WarpTrigger {
        const table = .{
            .{ "EAST_ARROW_WARP", WarpTrigger{ .press = .east } },
            .{ "WEST_ARROW_WARP", WarpTrigger{ .press = .west } },
            .{ "NORTH_ARROW_WARP", WarpTrigger{ .press = .north } },
            .{ "SOUTH_ARROW_WARP", WarpTrigger{ .press = .south } },
            .{ "UP_RIGHT_STAIR_WARP", WarpTrigger{ .press = .east } },
            .{ "DOWN_RIGHT_STAIR_WARP", WarpTrigger{ .press = .east } },
            .{ "UP_LEFT_STAIR_WARP", WarpTrigger{ .press = .west } },
            .{ "DOWN_LEFT_STAIR_WARP", WarpTrigger{ .press = .west } },
            .{ "WARP_DOOR", WarpTrigger.on_step },
            .{ "CAVE_DOOR", WarpTrigger.on_step },
            .{ "REGULAR_WARP", WarpTrigger.on_step },
            .{ "FALL_WARP", WarpTrigger.on_step },
            .{ "LADDER", WarpTrigger.on_step },
            .{ "UP_ESCALATOR", WarpTrigger.on_step },
            .{ "DOWN_ESCALATOR", WarpTrigger.on_step },
            .{ "LAVARIDGE_1F_WARP", WarpTrigger.on_step },
            .{ "UNION_ROOM_WARP", WarpTrigger.on_step },
        };
        inline for (table) |entry| {
            if (std.mem.eql(u8, behavior, entry[0])) return entry[1];
        }
        return null;
    }
};

/// Addresses looked up once, so a table that does not match the ROM fails
/// immediately and loudly rather than reading nonsense later.
const Symbols = struct {
    main: u32,
    save_block1_ptr: u32,
    save_block2_ptr: u32,
    map_header: u32,
    object_events: u32,
    vmap: u32,
    player_party: u32,
    player_party_count: u32,
    lock_field_controls: u32,
    naming_screen: u32,
    script_context: u32,
    script_status: u32,
    cmd_table: u32,
    cmd_table_end: u32,
    string_vars: [3]u32,
    string_var4: u32,
    displayed_string_battle: u32,
    text_printers: u32,
    palette_fade: u32,

    battle_mons: u32,
    battle_type_flags: u32,
    battlers_count: u32,
    battler_in_menu: u32,
    action_cursor: u32,
    move_cursor: u32,
    controller_funcs: u32,
    choose_action_fn: u32,
    choose_move_fn: u32,

    start_menu_window: u32,
    start_menu_cursor: u32,
    start_menu_order: u32,
    start_menu_count: u32,
    start_menu_actions: u32,

    species_names: u32,
    move_names: u32,
    ability_names: u32,
    type_names: u32,
    items: u32,

    fn load(data: *const GameData) !Symbols {
        return .{
            .main = try need(data, "gMain"),
            .save_block1_ptr = try need(data, "gSaveBlock1Ptr"),
            .save_block2_ptr = try need(data, "gSaveBlock2Ptr"),
            .map_header = try need(data, "gMapHeader"),
            .object_events = try need(data, "gObjectEvents"),
            .vmap = try need(data, "VMap"),
            .player_party = try need(data, "gPlayerParty"),
            .player_party_count = try need(data, "gPlayerPartyCount"),
            .lock_field_controls = try need(data, "sLockFieldControls"),
            .naming_screen = try need(data, "sNamingScreen"),
            .script_context = try need(data, "sGlobalScriptContext"),
            .script_status = try need(data, "sGlobalScriptContextStatus"),
            .cmd_table = try need(data, "gScriptCmdTable"),
            .cmd_table_end = try need(data, "gScriptCmdTableEnd"),
            .string_vars = .{
                try need(data, "gStringVar1"),
                try need(data, "gStringVar2"),
                try need(data, "gStringVar3"),
            },
            .string_var4 = try need(data, "gStringVar4"),
            .displayed_string_battle = try need(data, "gDisplayedStringBattle"),
            .text_printers = try need(data, "sTextPrinters"),
            .palette_fade = try need(data, "gPaletteFade"),
            .battle_mons = try need(data, "gBattleMons"),
            .battle_type_flags = try need(data, "gBattleTypeFlags"),
            .battlers_count = try need(data, "gBattlersCount"),
            .battler_in_menu = try need(data, "gBattlerInMenuId"),
            .action_cursor = try need(data, "gActionSelectionCursor"),
            .move_cursor = try need(data, "gMoveSelectionCursor"),
            .controller_funcs = try need(data, "gBattlerControllerFuncs"),
            .choose_action_fn = try need(data, "HandleInputChooseAction"),
            .choose_move_fn = try need(data, "HandleInputChooseMove"),
            .start_menu_window = try need(data, "sStartMenuWindowId"),
            .start_menu_cursor = try need(data, "sStartMenuCursorPos"),
            .start_menu_order = try need(data, "sStartMenuOrder"),
            .start_menu_count = try need(data, "sNumStartMenuItems"),
            .start_menu_actions = try need(data, "sStartMenuActionTable"),
            .species_names = try need(data, "gSpeciesNames"),
            .move_names = try need(data, "gMoveNames"),
            .ability_names = try need(data, "gAbilityNames"),
            .type_names = try need(data, "gTypeNames"),
            .items = try need(data, "gItems"),
        };
    }

    fn need(data: *const GameData, sym: []const u8) !u32 {
        return data.find(sym) orelse {
            std.log.err(
                "symbol '{s}' is missing from the generated table; " ++
                    "regenerate it against the ROM you are running",
                .{sym},
            );
            return error.SymbolMissing;
        };
    }
};

pub const FireRed = struct {
    emu: *mgba.Emulator,
    data: *const GameData,
    sym: Symbols,

    pub fn init(emu: *mgba.Emulator, data: *const GameData) !FireRed {
        return .{ .emu = emu, .data = data, .sym = try Symbols.load(data) };
    }

    // -- names read out of the ROM -------------------------------------------
    //
    // Species, move, ability and item names live in the cartridge as Gen 3
    // text. Reading them from there rather than shipping a table means they
    // are always the names this particular ROM uses, romhack or not.

    const species_name_stride = 11;
    const move_name_stride = 13;
    const ability_name_stride = 13;
    const type_name_stride = 7;
    const item_stride = 44;
    const item_name_len = 14;

    fn romName(self: *FireRed, gpa: Allocator, base: u32, stride: u32, index: u32) ![]const u8 {
        var raw: [32]u8 = undefined;
        const n = @min(stride, raw.len);
        self.emu.readBytes(base + index * stride, raw[0..n]);
        var out: [64]u8 = undefined;
        return gpa.dupe(u8, text.decodeName(&out, raw[0..n], &self.data.charmap));
    }

    pub fn speciesName(self: *FireRed, gpa: Allocator, id: u16) ![]const u8 {
        return self.romName(gpa, self.sym.species_names, species_name_stride, id);
    }
    pub fn moveName(self: *FireRed, gpa: Allocator, id: u16) ![]const u8 {
        return self.romName(gpa, self.sym.move_names, move_name_stride, id);
    }
    pub fn abilityName(self: *FireRed, gpa: Allocator, id: u8) ![]const u8 {
        return self.romName(gpa, self.sym.ability_names, ability_name_stride, id);
    }
    pub fn typeName(self: *FireRed, gpa: Allocator, id: u8) ![]const u8 {
        return self.romName(gpa, self.sym.type_names, type_name_stride, id);
    }
    pub fn itemName(self: *FireRed, gpa: Allocator, id: u16) ![]const u8 {
        var raw: [item_name_len]u8 = undefined;
        self.emu.readBytes(self.sym.items + @as(u32, id) * item_stride, &raw);
        var out: [64]u8 = undefined;
        return gpa.dupe(u8, text.decodeName(&out, &raw, &self.data.charmap));
    }

    // -- save blocks ---------------------------------------------------------

    fn saveBlock1(self: *FireRed) u32 {
        return self.emu.read32(self.sym.save_block1_ptr);
    }

    fn saveBlock2(self: *FireRed) u32 {
        return self.emu.read32(self.sym.save_block2_ptr);
    }

    /// Values the game splices into messages, so dialogue reads with real names.
    fn substitutions(self: *FireRed, gpa: Allocator) !text.Substitutions {
        var subs: text.Substitutions = .{};
        var raw: [32]u8 = undefined;
        var out: [64]u8 = undefined;

        const b2 = self.saveBlock2();
        if (b2 != 0) {
            self.emu.readBytes(b2 + sb2.player_name, raw[0..8]);
            subs.set(.player, try gpa.dupe(u8, text.decodeName(&out, raw[0..8], &self.data.charmap)));
        }
        const vars = [_]text.Placeholder{ .string_var_1, .string_var_2, .string_var_3 };
        for (vars, self.sym.string_vars) |which, addr| {
            self.emu.readBytes(addr, raw[0..24]);
            subs.set(which, try gpa.dupe(u8, text.decodeName(&out, raw[0..24], &self.data.charmap)));
        }
        const b1 = self.saveBlock1();
        if (b1 != 0) {
            self.emu.readBytes(b1 + sb1.rival_name, raw[0..8]);
            subs.set(.rival, try gpa.dupe(u8, text.decodeName(&out, raw[0..8], &self.data.charmap)));
        }
        return subs;
    }

    // -- which screen are we on ----------------------------------------------

    pub fn screen(self: *FireRed, gpa: Allocator) !obs.Screen {
        const main = self.emu.readStruct(s.Main, self.sym.main);
        const in_battle = self.inBattle();

        const cb2 = try self.symbolText(gpa, main.callback2);
        const cb1 = try self.symbolText(gpa, main.callback1);
        return .{
            .callback2 = cb2,
            .callback1 = cb1,
            .mode = classify(cb2, in_battle),
            .in_battle = in_battle,
            .fade_active = self.fadeActive(),
            .input_locked = self.inputLocked(),
        };
    }

    /// Function pointers carry the Thumb bit; symbol addresses do not.
    fn stripThumb(addr: u32) u32 {
        return addr & ~@as(u32, 1);
    }

    fn symbolText(self: *FireRed, gpa: Allocator, addr: u32) ![]const u8 {
        if (self.data.resolve(addr)) |sym| {
            const target = stripThumb(addr);
            if (sym.addr == target) return gpa.dupe(u8, sym.name);
            return std.fmt.allocPrint(gpa, "{s}+0x{x}", .{ sym.name, target - sym.addr });
        }
        return std.fmt.allocPrint(gpa, "0x{x:0>8}", .{addr});
    }

    /// True while a cutscene or a script owns the player.
    ///
    /// Walking, turning and talking all do nothing in this state, so an agent
    /// that does not know about it reads a blocked step as a wall and starts
    /// trying other directions. The answer is to wait, or press A if the
    /// script is waiting on a message.
    pub fn inputLocked(self: *FireRed) bool {
        return self.emu.read8(self.sym.lock_field_controls) != 0;
    }

    /// Most input is ignored while the screen is fading.
    fn fadeActive(self: *FireRed) bool {
        // struct PaletteFadeControl: `active` is bit 7 of the byte at 0x07.
        return (self.emu.read8(self.sym.palette_fade + 0x07) & 0x80) != 0;
    }

    /// Coarse bucket, derived from the name of the game's own main callback.
    fn classify(cb2: []const u8, in_battle: bool) obs.Mode {
        if (in_battle) return .battle;
        const base = upToPlus(cb2);
        const overworld = [_][]const u8{
            "CB2_Overworld",       "CB2_OverworldBasic",
            "CB2_ReturnToField",   "CB2_ReturnToFieldContinueScript",
            "CB2_LoadMap",         "CB2_LoadMap2",
            "CB2_ReturnToFieldLocal", "CB2_ReturnToFieldWithOpenMenu",
        };
        for (overworld) |n| if (std.mem.eql(u8, base, n)) return .overworld;

        const title = [_][]const u8{
            "CB2_InitTitleScreen", "CB2_TitleScreenRun", "CB2_MainMenu",
            "CB2_InitCopyrightScreenAfterBootup", "CB2_InitMainMenu",
            "CB2_Intro", "CB2_SetUpIntro", "CB2_InitCopyrightScreen",
        };
        for (title) |n| if (std.mem.eql(u8, base, n)) return .title;

        if (std.mem.indexOf(u8, base, "Battle") != null) return .battle;
        const menuish = [_][]const u8{
            "Menu", "Bag", "Party", "PokemonStorage", "Summary",
            "Shop", "Trainer_Card", "Pokedex", "Save",
        };
        for (menuish) |n| if (std.mem.indexOf(u8, base, n) != null) return .menu;
        if (std.mem.startsWith(u8, base, "0x")) return .unknown;
        return .other;
    }

    fn upToPlus(name_: []const u8) []const u8 {
        return name_[0 .. std.mem.indexOfScalar(u8, name_, '+') orelse name_.len];
    }

    // -- text ----------------------------------------------------------------

    pub fn dialog(self: *FireRed, gpa: Allocator) !?obs.Dialog {
        const subs = try self.substitutions(gpa);
        const opts: text.Options = .{ .subs = subs };

        const in_battle = self.inBattle();
        const source = if (in_battle) self.sym.displayed_string_battle else self.sym.string_var4;

        // The message buffers keep their contents after a box closes, so the
        // text printers decide whether anything is actually on screen. Without
        // this check an agent reads the last thing said as though it were
        // still displayed, and waits forever for a box that is already gone.
        var box_open = false;
        var printing = false;
        var i: u32 = 0;
        while (i < s.num_text_printers) : (i += 1) {
            const p = self.emu.readStruct(
                s.TextPrinter,
                self.sym.text_printers + i * @sizeOf(s.TextPrinter),
            );
            if (p.active == 0) continue;
            box_open = true;
            // State 0 is "still typing"; 6 is "finished, waiting".
            if (p.state != 0 and p.state != 6) printing = true;
        }
        if (!box_open) return null;

        var raw: [1024]u8 = undefined;
        self.emu.readBytes(source, &raw);
        const decoded = try text.decodeAlloc(gpa, &raw, &self.data.charmap, opts);
        const trimmed = std.mem.trim(u8, decoded, " \n\t");
        if (trimmed.len == 0) return null;

        return .{ .text = trimmed, .box_open = true, .still_printing = printing };
    }

    // -- the world -----------------------------------------------------------

    pub fn location(self: *FireRed, gpa: Allocator) !?obs.Location {
        _ = gpa;
        const b1 = self.saveBlock1();
        if (b1 == 0) return null;
        const pos = self.emu.readStruct(s.Coords16, b1 + sb1.pos);
        const warp = self.emu.readStruct(s.WarpData, b1 + sb1.location);
        const header = self.emu.readStruct(s.MapHeader, self.sym.map_header);
        return .{
            .map = self.data.mapName(@bitCast(warp.map_group), @bitCast(warp.map_num)) orelse "UNKNOWN",
            .map_group = warp.map_group,
            .map_num = warp.map_num,
            .x = pos.x,
            .y = pos.y,
            .is_cave = header.cave != 0,
            .weather = self.emu.read8(b1 + sb1.weather),
        };
    }

    pub fn position(self: *FireRed) s.Coords16 {
        const b1 = self.saveBlock1();
        if (b1 == 0) return .{ .x = 0, .y = 0 };
        return self.emu.readStruct(s.Coords16, b1 + sb1.pos);
    }

    /// Map identity plus position. A warp changes the map, not the tile, so
    /// movement has to compare both.
    pub fn where(self: *FireRed) struct { group: i8, num: i8, x: i16, y: i16 } {
        const b1 = self.saveBlock1();
        if (b1 == 0) return .{ .group = -1, .num = -1, .x = 0, .y = 0 };
        const pos = self.emu.readStruct(s.Coords16, b1 + sb1.pos);
        const warp = self.emu.readStruct(s.WarpData, b1 + sb1.location);
        return .{ .group = warp.map_group, .num = warp.map_num, .x = pos.x, .y = pos.y };
    }

    fn behaviorOf(self: *FireRed, layout_ptr: u32, metatile: u16) u16 {
        if (layout_ptr == 0 or metatile >= num_metatiles_total) return 0xFF;
        const layout = self.emu.readStruct(s.MapLayout, layout_ptr);
        const tileset_ptr = if (metatile < num_metatiles_in_primary)
            layout.primary_tileset
        else
            layout.secondary_tileset;
        const index: u32 = if (metatile < num_metatiles_in_primary)
            metatile
        else
            metatile - num_metatiles_in_primary;
        if (tileset_ptr == 0) return 0xFF;
        const tileset = self.emu.readStruct(s.Tileset, tileset_ptr);
        if (tileset.metatile_attributes == 0) return 0xFF;
        const attrs = self.emu.read32(tileset.metatile_attributes + index * 4);
        return @intCast(attrs & metatile_behavior_mask);
    }

    pub fn tileAt(self: *FireRed, x: i16, y: i16) obs.Tile {
        const vmap = self.emu.readStruct(s.BackupMapLayout, self.sym.vmap);
        const out_of_bounds: obs.Tile = .{
            .x = x, .y = y, .passable = false, .elevation = 0, .behavior = "OUT_OF_BOUNDS",
        };
        if (vmap.map == 0 or vmap.width <= 0 or vmap.height <= 0) return out_of_bounds;

        const gx = @as(i32, x) + map_offset;
        const gy = @as(i32, y) + map_offset;
        if (gx < 0 or gy < 0 or gx >= vmap.width or gy >= vmap.height) return out_of_bounds;

        const raw = self.emu.read16(vmap.map + @as(u32, @intCast(gy * vmap.width + gx)) * 2);
        const block: s.MapBlock = @bitCast(raw);
        const header = self.emu.readStruct(s.MapHeader, self.sym.map_header);
        const behavior = self.behaviorOf(header.map_layout, block.metatile_id);
        return .{
            .x = x,
            .y = y,
            .passable = block.passable(),
            .elevation = block.elevation,
            .behavior = self.data.behaviorName(behavior) orelse "UNKNOWN",
        };
    }

    pub fn viewport(self: *FireRed) obs.Viewport {
        const p = self.position();
        return .{
            .x0 = p.x - view_player_col,
            .y0 = p.y - view_player_row,
            .x1 = p.x + (view_w - 1 - view_player_col),
            .y1 = p.y + (view_h - 1 - view_player_row),
            .width = view_w,
            .height = view_h,
        };
    }

    pub fn onScreen(self: *FireRed, x: i16, y: i16) bool {
        const v = self.viewport();
        return x >= v.x0 and x <= v.x1 and y >= v.y0 and y <= v.y1;
    }

    pub fn facing(self: *FireRed) s.Direction {
        var i: u32 = 0;
        while (i < s.object_events_count) : (i += 1) {
            const e = self.emu.readStruct(
                s.ObjectEvent,
                self.sym.object_events + i * @sizeOf(s.ObjectEvent),
            );
            if (e.flags.active and e.flags.is_player) return e.directions.facing;
        }
        return .none;
    }

    pub fn tileAhead(self: *FireRed) ?obs.Tile {
        const dir = self.facing();
        const d = dir.delta();
        if (dir == .none) return null;
        const p = self.position();
        return self.tileAt(p.x + d.x, p.y + d.y);
    }

    /// NPCs the player can see. Object events store grid coordinates, so these
    /// are converted to map space to match everything else.
    pub fn visibleNpcs(self: *FireRed, gpa: Allocator) ![]obs.Npc {
        var list: std.ArrayList(obs.Npc) = .empty;
        var i: u32 = 0;
        while (i < s.object_events_count) : (i += 1) {
            const e = self.emu.readStruct(
                s.ObjectEvent,
                self.sym.object_events + i * @sizeOf(s.ObjectEvent),
            );
            if (!e.flags.active or e.flags.is_player or e.flags.invisible) continue;
            const x = e.current_coords.x - map_offset;
            const y = e.current_coords.y - map_offset;
            if (!self.onScreen(x, y)) continue;
            try list.append(gpa, .{
                .local_id = e.local_id,
                .x = x,
                .y = y,
                .facing = e.directions.facing.name(),
                .kind = if (e.trainer_type != 0) "trainer" else "npc",
                .graphics_id = e.graphics_id,
            });
        }
        return list.toOwnedSlice(gpa);
    }

    fn mapEvents(self: *FireRed) ?s.MapEvents {
        const header = self.emu.readStruct(s.MapHeader, self.sym.map_header);
        if (header.events == 0) return null;
        return self.emu.readStruct(s.MapEvents, header.events);
    }

    /// Doors and stairs on screen.
    ///
    /// Where they lead is deliberately not reported: a door is visible, but
    /// its destination is not until you walk through it.
    pub fn visibleWarps(self: *FireRed, gpa: Allocator) ![]obs.Warp {
        var list: std.ArrayList(obs.Warp) = .empty;
        const events = self.mapEvents() orelse return list.toOwnedSlice(gpa);
        if (events.warps == 0 or events.warp_count > 64) return list.toOwnedSlice(gpa);

        var i: u32 = 0;
        while (i < events.warp_count) : (i += 1) {
            const w = self.emu.readStruct(s.WarpEvent, events.warps + i * @sizeOf(s.WarpEvent));
            if (!self.onScreen(w.x, w.y)) continue;
            const behavior = self.tileAt(w.x, w.y).behavior;
            const trigger = WarpTrigger.forBehavior(behavior) orelse continue;
            try list.append(gpa, .{
                .x = w.x,
                .y = w.y,
                .behavior = behavior,
                .trigger = switch (trigger) {
                    .on_step => null,
                    .press => |d| d.name(),
                },
            });
        }
        return list.toOwnedSlice(gpa);
    }

    pub fn visibleSigns(self: *FireRed, gpa: Allocator) ![]obs.Sign {
        var list: std.ArrayList(obs.Sign) = .empty;
        const events = self.mapEvents() orelse return list.toOwnedSlice(gpa);
        if (events.bg_events == 0 or events.bg_event_count > 64) return list.toOwnedSlice(gpa);

        var i: u32 = 0;
        while (i < events.bg_event_count) : (i += 1) {
            const e = self.emu.readStruct(s.BgEvent, events.bg_events + i * @sizeOf(s.BgEvent));
            const x: i16 = @bitCast(e.x);
            const y: i16 = @bitCast(e.y);
            if (!self.onScreen(x, y)) continue;
            try list.append(gpa, .{ .x = x, .y = y, .kind = e.kind });
        }
        return list.toOwnedSlice(gpa);
    }

    pub const legend =
        "@ you  . walkable  # blocked  ~ water  \" grass  ^ ledge  " ++
        "N npc  D door/stairs  ? off-map";

    /// The 15x10 window the Game Boy draws, as ASCII with labelled axes.
    pub fn renderScreen(self: *FireRed, gpa: Allocator) ![]const u8 {
        const v = self.viewport();
        const p = self.position();
        const npcs = try self.visibleNpcs(gpa);
        const warps = try self.visibleWarps(gpa);

        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;

        try w.print("     x={d}..{d}\n", .{ v.x0, v.x1 });
        var y = v.y0;
        while (y <= v.y1) : (y += 1) {
            // Pad by hand: giving {d} a width makes Zig print a sign, and
            // "y=+2" reads like a relative offset rather than a coordinate.
            var label_buf: [12]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "y={d}", .{y}) catch "y=?";
            try w.writeAll(label);
            var pad = label.len;
            while (pad < 6) : (pad += 1) try w.writeByte(' ');
            var x = v.x0;
            while (x <= v.x1) : (x += 1) {
                try w.writeByte(self.glyphFor(x, y, p, npcs, warps));
            }
            try w.writeByte('\n');
        }
        return out.toOwnedSlice();
    }

    fn glyphFor(
        self: *FireRed,
        x: i16,
        y: i16,
        player_pos: s.Coords16,
        npcs: []const obs.Npc,
        warps: []const obs.Warp,
    ) u8 {
        if (x == player_pos.x and y == player_pos.y) return '@';
        for (npcs) |n| if (n.x == x and n.y == y) return 'N';
        for (warps) |wp| if (wp.x == x and wp.y == y) return 'D';

        const tile = self.tileAt(x, y);
        const b = tile.behavior;
        if (std.mem.eql(u8, b, "OUT_OF_BOUNDS")) return '?';
        if (std.mem.indexOf(u8, b, "JUMP") != null or std.mem.indexOf(u8, b, "LEDGE") != null)
            return '^';
        if (std.mem.indexOf(u8, b, "WATER") != null) return '~';
        if (std.mem.indexOf(u8, b, "GRASS") != null) return '"';
        return if (tile.passable) '.' else '#';
    }

    // -- player and party ----------------------------------------------------

    pub fn player(self: *FireRed, gpa: Allocator) !obs.Player {
        const b1 = self.saveBlock1();
        const b2 = self.saveBlock2();
        if (b1 == 0 or b2 == 0) {
            return .{
                .name = "", .gender = "unknown", .trainer_id = 0, .money = 0,
                .badges = &.{}, .play_time = "0:00", .facing = "none",
            };
        }
        var raw: [8]u8 = undefined;
        self.emu.readBytes(b2 + sb2.player_name, &raw);
        var buf: [32]u8 = undefined;
        const player_name = try gpa.dupe(u8, text.decodeName(&buf, &raw, &self.data.charmap));

        const hours = self.emu.read16(b2 + sb2.play_time_hours);
        const minutes = self.emu.read8(b2 + sb2.play_time_minutes);

        return .{
            .name = player_name,
            .gender = if (self.emu.read8(b2 + sb2.gender) != 0) "female" else "male",
            .trainer_id = self.emu.read16(b2 + sb2.trainer_id),
            .money = self.money(),
            .badges = try self.badges(gpa),
            .play_time = try std.fmt.allocPrint(gpa, "{d}:{d:0>2}", .{ hours, minutes }),
            .facing = self.facing().name(),
        };
    }

    /// Money is obfuscated with the save's encryption key.
    pub fn money(self: *FireRed) u32 {
        const b1 = self.saveBlock1();
        const b2 = self.saveBlock2();
        if (b1 == 0 or b2 == 0) return 0;
        return self.emu.read32(b1 + sb1.money) ^ self.emu.read32(b2 + sb2.encryption_key);
    }

    pub fn flag(self: *FireRed, id: u32) bool {
        const b1 = self.saveBlock1();
        if (b1 == 0) return false;
        return (self.emu.read8(b1 + sb1.flags + id / 8) & (@as(u8, 1) << @intCast(id % 8))) != 0;
    }

    pub fn variable(self: *FireRed, id: u32) u16 {
        const b1 = self.saveBlock1();
        if (b1 == 0) return 0;
        const index = if (id >= 0x4000) id - 0x4000 else id;
        return self.emu.read16(b1 + sb1.vars + index * 2);
    }

    fn badges(self: *FireRed, gpa: Allocator) ![]const []const u8 {
        const names = [_][]const u8{
            "Boulder", "Cascade", "Thunder", "Rainbow",
            "Soul",    "Marsh",   "Volcano", "Earth",
        };
        var list: std.ArrayList([]const u8) = .empty;
        for (names, 0..) |n, i| {
            if (self.flag(flag_badge01 + @as(u32, @intCast(i)))) try list.append(gpa, n);
        }
        return list.toOwnedSlice(gpa);
    }

    /// The party the player is actually carrying.
    ///
    /// Not the copy inside the save block: that one is only refreshed when the
    /// game saves (see CopyPartyToSaveBlock in src/load_save.c), so reading it
    /// reports an empty party right after catching something.
    pub fn party(self: *FireRed, gpa: Allocator) ![]obs.Mon {
        var list: std.ArrayList(obs.Mon) = .empty;
        const count = @min(self.emu.read8(self.sym.player_party_count), s.party_size);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const mon = self.emu.readStruct(
                s.Pokemon,
                self.sym.player_party + i * @sizeOf(s.Pokemon),
            );
            const secure = pk.unpack(mon.box);
            if (pk.isEmpty(mon, secure)) continue;

            const moves = try self.decodeMoves(gpa, &secure.attacks.moves, &secure.attacks.pp);
            const nickname = try self.dupeName(gpa, &mon.box.nickname);

            try list.append(gpa, .{
                .slot = @intCast(i),
                .species = try self.speciesName(gpa, secure.growth.species),
                .species_id = secure.growth.species,
                .nickname = nickname,
                .level = mon.level,
                .hp = mon.hp,
                .max_hp = mon.max_hp,
                .hp_percent = percent(mon.hp, mon.max_hp),
                .status = try statusNames(gpa, mon.status),
                .moves = moves,
                .held_item = if (secure.growth.held_item != 0)
                    try self.itemName(gpa, secure.growth.held_item)
                else
                    null,
                .is_egg = secure.misc.ivs.is_egg or mon.box.flags.is_egg,
                .nature = pk.Nature.fromPersonality(mon.box.personality).name(),
                .friendship = secure.growth.friendship,
                .checksum_ok = secure.checksum_ok,
            });
        }
        return list.toOwnedSlice(gpa);
    }

    // -- battle --------------------------------------------------------------

    pub fn battle(self: *FireRed, gpa: Allocator) !?obs.Battle {
        const in_battle = self.inBattle();
        if (!in_battle) return null;

        const flags: s.BattleTypeFlags = @bitCast(self.emu.read32(self.sym.battle_type_flags));
        const count = @min(self.emu.read8(self.sym.battlers_count), s.max_battlers);

        var list: std.ArrayList(obs.Battler) = .empty;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const b = self.emu.readStruct(
                s.BattlePokemon,
                self.sym.battle_mons + i * @sizeOf(s.BattlePokemon),
            );
            if (b.species == 0) continue;

            const types = try gpa.alloc([]const u8, 2);
            types[0] = try self.typeName(gpa, b.type1);
            types[1] = try self.typeName(gpa, b.type2);

            try list.append(gpa, .{
                // Even battler slots are the player's side.
                .side = if (i % 2 == 0) "player" else "opponent",
                .species = try self.speciesName(gpa, b.species),
                .nickname = try self.dupeName(gpa, &b.nickname),
                .level = b.level,
                .hp = b.hp,
                .max_hp = b.max_hp,
                .hp_percent = percent(b.hp, b.max_hp),
                .status = try statusNames(gpa, b.status1),
                .ability = try self.abilityName(gpa, b.ability),
                .types = types,
                .moves = try self.decodeMoves(gpa, &b.moves, &b.pp),
            });
        }

        var msg_raw: [1024]u8 = undefined;
        self.emu.readBytes(self.sym.displayed_string_battle, &msg_raw);
        const subs = try self.substitutions(gpa);
        const message = try text.decodeAlloc(gpa, &msg_raw, &self.data.charmap, .{ .subs = subs });

        return .{
            .is_trainer_battle = flags.trainer,
            .is_double = flags.double,
            .battlers = try list.toOwnedSlice(gpa),
            .message = std.mem.trim(u8, message, " \n\t"),
        };
    }

    // -- menus ---------------------------------------------------------------

    /// The battle action menu is a fixed 2x2 grid.
    const battle_actions = [_][]const u8{ "FIGHT", "BAG", "POKEMON", "RUN" };

    pub fn menu(self: *FireRed, gpa: Allocator) !?obs.Menu {
        if (try self.startMenu(gpa)) |m| return m;
        return self.battleMenu(gpa);
    }

    fn startMenu(self: *FireRed, gpa: Allocator) !?obs.Menu {
        // The window id is 0xFF whenever the start menu is not on screen.
        if (self.emu.read8(self.sym.start_menu_window) == 0xFF) return null;

        const count = @min(self.emu.read8(self.sym.start_menu_count), 9);
        const subs = try self.substitutions(gpa);
        var options: std.ArrayList([]const u8) = .empty;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const slot_id = self.emu.read8(self.sym.start_menu_order + i);
            // struct MenuAction { const u8 *text; ... } -- 8 bytes, text first.
            const text_ptr = self.emu.read32(self.sym.start_menu_actions + @as(u32, slot_id) * 8);
            var raw: [32]u8 = undefined;
            self.emu.readBytes(text_ptr, &raw);
            const decoded = try text.decodeAlloc(gpa, &raw, &self.data.charmap, .{ .subs = subs });
            try options.append(gpa, std.mem.trim(u8, decoded, " \n\t"));
        }
        const cursor = self.emu.read8(self.sym.start_menu_cursor);
        const opts = try options.toOwnedSlice(gpa);
        return .{
            .kind = "start_menu",
            .options = opts,
            .cursor = cursor,
            .selected = if (cursor < opts.len) opts[cursor] else null,
        };
    }

    fn battleMenu(self: *FireRed, gpa: Allocator) !?obs.Menu {
        const in_battle = self.inBattle();
        if (!in_battle) return null;

        const battler = self.menuBattler();
        const action = self.emu.read8(self.sym.action_cursor + battler) & cursor_mask;
        const move_cursor = self.emu.read8(self.sym.move_cursor + battler) & cursor_mask;

        const b = self.emu.readStruct(
            s.BattlePokemon,
            self.sym.battle_mons + battler * @sizeOf(s.BattlePokemon),
        );

        const opts = try gpa.dupe([]const u8, &battle_actions);
        return .{
            .kind = "battle_menu",
            .options = opts,
            .cursor = action,
            .selected = opts[action],
            .move_cursor = move_cursor,
            .moves = try self.decodeMoves(gpa, &b.moves, &b.pp),
        };
    }

    // -- battle actions ------------------------------------------------------

    pub fn inBattle(self: *FireRed) bool {
        return (self.emu.read8(self.sym.main + s.main_in_battle_offset) & s.main_in_battle_mask) != 0;
    }

    /// Turn parallel move-id and PP arrays into the observation's move list,
    /// dropping the empty slots. Party mons, battle mons and the battle menu
    /// all store moves the same way, so they all read them the same way.
    fn decodeMoves(self: *FireRed, gpa: Allocator, ids: []const u16, pps: []const u8) ![]obs.Move {
        var moves: std.ArrayList(obs.Move) = .empty;
        for (ids, pps) |mid, pp| {
            if (mid == 0) continue;
            try moves.append(gpa, .{ .name = try self.moveName(gpa, mid), .id = mid, .pp = pp });
        }
        return moves.toOwnedSlice(gpa);
    }

    /// Decode a name field and hand back an owned copy. Names come out of the
    /// game short, so one scratch buffer serves every caller.
    fn dupeName(self: *FireRed, gpa: Allocator, raw: []const u8) ![]const u8 {
        var buf: [64]u8 = undefined;
        return gpa.dupe(u8, text.decodeName(&buf, raw, &self.data.charmap));
    }

    /// Battler ids and battle-menu cursors are all in 0..3.
    const cursor_mask: u8 = 0x03;

    /// The battler whose action menu is up. Cursor arrays are indexed by it.
    fn menuBattler(self: *FireRed) u32 {
        return self.emu.read8(self.sym.battler_in_menu) & cursor_mask;
    }

    /// Point the top-level battle menu at an action (0=FIGHT..3=RUN). The game
    /// reads this the instant A is pressed, so writing it is the same as having
    /// walked the cursor there, without the guesswork of a blind 2x2 grid.
    pub fn setBattleAction(self: *FireRed, action: u8) void {
        self.emu.write8(self.sym.action_cursor + self.menuBattler(), action & cursor_mask);
    }

    /// Point the move submenu at a slot (0..3), same trick as setBattleAction.
    pub fn setBattleMoveSlot(self: *FireRed, slot: u8) void {
        self.emu.write8(self.sym.move_cursor + self.menuBattler(), slot & cursor_mask);
    }

    /// The controller function for a battler is the game's own record of what
    /// that battler's turn is waiting on -- the surest way to know a menu is
    /// really taking input rather than a message still being read out. Stored
    /// with the Thumb bit set, so compare with it masked off.
    fn controllerFn(self: *FireRed) u32 {
        return stripThumb(self.emu.read32(self.sym.controller_funcs + self.menuBattler() * 4));
    }

    /// The top-level battle menu (FIGHT/BAG/POKEMON/RUN) is awaiting a choice.
    pub fn battleAwaitingAction(self: *FireRed) bool {
        return self.inBattle() and self.controllerFn() == self.sym.choose_action_fn;
    }

    /// The move submenu is awaiting a choice.
    pub fn battleAwaitingMove(self: *FireRed) bool {
        return self.inBattle() and self.controllerFn() == self.sym.choose_move_fn;
    }

    // -- naming screen -------------------------------------------------------

    /// struct NamingScreenData, from src/naming_screen.c.
    const naming = struct {
        const text_buffer = 0x1800;
        const template_ptr = 0x1E28;
        /// struct NamingScreenTemplate: maxChars is the second byte.
        const template_max_chars = 1;
    };

    pub const Naming = struct {
        /// How many characters this particular screen will accept. Writing
        /// more would run past the buffer the game copies into.
        max_chars: u8,
    };

    /// The naming screen, if one is open.
    pub fn namingScreen(self: *FireRed) ?Naming {
        const ptr = self.emu.read32(self.sym.naming_screen);
        if (ptr == 0) return null;
        const template = self.emu.read32(ptr + naming.template_ptr);
        if (template == 0) return null;
        const max = self.emu.read8(template + naming.template_max_chars);
        if (max == 0 or max > 16) return null;
        return .{ .max_chars = max };
    }

    /// Type a name into the open naming screen.
    ///
    /// Writes straight into the screen's own text buffer rather than walking
    /// its on-screen keyboard, which would be dozens of button presses and
    /// depends on the cursor starting where you expect. The game copies this
    /// buffer to its destination when the name is confirmed, so the result is
    /// exactly what it would be if a person had typed it.
    pub fn writeName(self: *FireRed, wanted: []const u8) !u8 {
        const screen_info = self.namingScreen() orelse return error.NoNamingScreen;

        var encoded: [17]u8 = undefined;
        const bytes = text.encode(encoded[0 .. screen_info.max_chars + 1], wanted, &self.data.charmap) catch |e|
            switch (e) {
                error.NameTooLong => return error.NameTooLong,
                error.UnsupportedCharacter => return error.UnsupportedCharacter,
            };

        const ptr = self.emu.read32(self.sym.naming_screen);
        // Clear the buffer first: a shorter name must not leave the tail of a
        // longer one behind it.
        var blank: [0x10]u8 = @splat(@intFromEnum(text.Control.end));
        self.emu.writeBytes(ptr + naming.text_buffer, &blank);
        self.emu.writeBytes(ptr + naming.text_buffer, bytes);
        return screen_info.max_chars;
    }


    // -- putting a message on screen -----------------------------------------

    /// Script bytecode, from asm/macros/event.inc.
    const ScriptOp = enum(u8) {
        end = 0x02,
        callstd = 0x09,
        loadword = 0x0F,
        lockall = 0x69,
        releaseall = 0x6B,
    };

    /// callstd argument for an ordinary message box.
    const msgbox_default = 4;

    /// Text colours the game understands (include/characters.h).
    pub const TextColor = enum(u8) {
        transparent = 0x0,
        white = 0x1,
        dark_gray = 0x2,
        light_gray = 0x3,
        red = 0x4,
        light_red = 0x5,
        green = 0x6,
        light_green = 0x7,
        blue = 0x8,
        light_blue = 0x9,
        _,

        pub fn parse(s_: []const u8) ?TextColor {
            const table = .{
                .{ "white", TextColor.white },       .{ "gray", TextColor.dark_gray },
                .{ "grey", TextColor.dark_gray },    .{ "light_gray", TextColor.light_gray },
                .{ "red", TextColor.red },           .{ "light_red", TextColor.light_red },
                .{ "green", TextColor.green },       .{ "light_green", TextColor.light_green },
                .{ "blue", TextColor.blue },         .{ "light_blue", TextColor.light_blue },
            };
            inline for (table) |e| {
                if (std.ascii.eqlIgnoreCase(s_, e[0])) return e[1];
            }
            return null;
        }
    };

    /// How the AI's own messages are coloured, so they are obviously not the
    /// game talking. Red on a pale blue field, rather than the usual dark grey
    /// on white.
    pub const Palette = struct {
        text: TextColor = .red,
        background: TextColor = .light_blue,
        shadow: TextColor = .light_gray,
    };

    /// struct ScriptContext, from include/script.h.
    const script_ctx = struct {
        const stack_depth = 0x00;
        const mode = 0x01;
        const script_ptr = 0x08;
        const cmd_table = 0x5C;
        const cmd_table_end = 0x60;
        const mode_bytecode = 1;
        const status_running = 0;
    };

    /// SaveBlock1.ramScript: a kilobyte the game reserves for a script
    /// delivered over link, and never uses in ordinary play. Borrowing it
    /// avoids picking an address something else owns, and is safe across a
    /// save: the game checks this buffer's checksum before ever running it,
    /// and the checksum and header bytes ahead of the body are left alone, so
    /// what we write here stays inert as far as the game is concerned.
    const ram_script = 0x361C;
    const ram_script_body = ram_script + 4 + 4;

    pub const MessageError = error{
        NotInOverworld,
        ScriptAlreadyRunning,
        MessageTooLong,
        UnsupportedCharacter,
        NoSaveBlock,
    };

    /// Show text in a real message box, by handing the game a script.
    ///
    /// The box is the game's own: this assembles four bytecode instructions in
    /// the RAM the game keeps for link scripts, points the idle script context
    /// at them, and lets the engine run it on the next frame. What appears is
    /// a genuine field message, drawn by the game with its own font and
    /// window, not something painted over the picture afterwards.
    ///
    /// Only works standing in the overworld with nothing else going on;
    /// interrupting a running script would strand it half-finished.
    pub fn showMessage(self: *FireRed, message: []const u8, palette: Palette) MessageError!void {
        if (self.inputLocked()) return error.ScriptAlreadyRunning;
        if (self.emu.read8(self.sym.script_status) == script_ctx.status_running)
            return error.ScriptAlreadyRunning;

        const b1 = self.saveBlock1();
        if (b1 == 0) return error.NoSaveBlock;

        // Encode first: a message the font cannot render should change nothing.
        //
        // The colour goes in the message itself as an EXT_CTRL_CODE, rather
        // than by repainting the window, so nothing has to be put back
        // afterwards and the game's own dialogue keeps its usual look.
        var encoded: [256]u8 = undefined;
        encoded[0] = @intFromEnum(text.Control.ext);
        encoded[1] = 0x04; // EXT_CTRL_CODE_COLOR_HIGHLIGHT_SHADOW
        encoded[2] = @intFromEnum(palette.text);
        encoded[3] = @intFromEnum(palette.background);
        encoded[4] = @intFromEnum(palette.shadow);
        const body = encodeMessage(encoded[5..], message, &self.data.charmap) catch |e| return switch (e) {
            error.NameTooLong => error.MessageTooLong,
            error.UnsupportedCharacter => error.UnsupportedCharacter,
        };
        const text_bytes = encoded[0 .. 5 + body.len];

        const script_addr = b1 + ram_script_body;
        const text_addr = script_addr + 16;

        var code: [11]u8 = undefined;
        code[0] = @intFromEnum(ScriptOp.lockall);
        code[1] = @intFromEnum(ScriptOp.loadword);
        code[2] = 0; // destination slot 0, where callstd looks for the text
        std.mem.writeInt(u32, code[3..7], text_addr, .little);
        code[7] = @intFromEnum(ScriptOp.callstd);
        code[8] = msgbox_default;
        code[9] = @intFromEnum(ScriptOp.releaseall);
        code[10] = @intFromEnum(ScriptOp.end);

        self.emu.writeBytes(script_addr, &code);
        self.emu.writeBytes(text_addr, text_bytes);

        // Point the idle context at it and start it.
        const ctx = self.sym.script_context;
        self.emu.write8(ctx + script_ctx.stack_depth, 0);
        self.emu.write8(ctx + script_ctx.mode, script_ctx.mode_bytecode);
        self.emu.write32(ctx + script_ctx.script_ptr, script_addr);
        self.emu.write32(ctx + script_ctx.cmd_table, self.sym.cmd_table);
        self.emu.write32(ctx + script_ctx.cmd_table_end, self.sym.cmd_table_end);
        self.emu.write8(self.sym.script_status, script_ctx.status_running);
    }

    /// Like text.encode, but newlines become the game's line break so a
    /// message can use both lines of the box.
    fn encodeMessage(
        out: []u8,
        message: []const u8,
        charmap: *const [256][]const u8,
    ) error{ NameTooLong, UnsupportedCharacter }![]u8 {
        var written: usize = 0;
        var lines = std.mem.splitScalar(u8, message, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) {
                if (written >= out.len) return error.NameTooLong;
                out[written] = 0xFE; // CHAR_NEWLINE
                written += 1;
            }
            first = false;
            const encoded = try text.encode(out[written..], line, charmap);
            // encode terminates the slice; keep the characters, drop the
            // terminator so the next line can follow.
            written += encoded.len - 1;
        }
        if (written >= out.len) return error.NameTooLong;
        out[written] = 0xFF; // EOS
        return out[0 .. written + 1];
    }

    // -- helpers -------------------------------------------------------------

    fn percent(cur: u16, max: u16) u8 {
        if (max == 0) return 0;
        return @intCast(@min(@as(u32, 100), (@as(u32, cur) * 100 + max / 2) / max));
    }

    fn statusNames(gpa: Allocator, status: s.Status) ![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        if (status.asleep()) try list.append(gpa, "sleep");
        if (status.poison) try list.append(gpa, "poison");
        if (status.burn) try list.append(gpa, "burn");
        if (status.freeze) try list.append(gpa, "freeze");
        if (status.paralysis) try list.append(gpa, "paralysis");
        if (status.bad_poison) try list.append(gpa, "bad_poison");
        return list.toOwnedSlice(gpa);
    }
};

test "warp triggers come from the tile's terrain type" {
    try std.testing.expectEqual(
        s.Direction.south,
        WarpTrigger.forBehavior("SOUTH_ARROW_WARP").?.press,
    );
    try std.testing.expectEqual(
        s.Direction.east,
        WarpTrigger.forBehavior("UP_RIGHT_STAIR_WARP").?.press,
    );
    try std.testing.expect(WarpTrigger.forBehavior("WARP_DOOR").? == .on_step);
    // A plain tile listed as a warp is an arrival point, not a way out.
    try std.testing.expect(WarpTrigger.forBehavior("NORMAL") == null);
}

test "screen classification" {
    try std.testing.expectEqual(obs.Mode.overworld, FireRed.classify("CB2_Overworld", false));
    try std.testing.expectEqual(obs.Mode.overworld, FireRed.classify("CB2_Overworld+0x4", false));
    try std.testing.expectEqual(obs.Mode.battle, FireRed.classify("CB2_Overworld", true));
    try std.testing.expectEqual(obs.Mode.title, FireRed.classify("CB2_TitleScreenRun", false));
    try std.testing.expectEqual(obs.Mode.menu, FireRed.classify("CB2_BagMenuRun", false));
    try std.testing.expectEqual(obs.Mode.unknown, FireRed.classify("0x00000000", false));
}
