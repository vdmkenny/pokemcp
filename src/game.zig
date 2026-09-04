//! One running game, and the control loop that drives any of them.
//!
//! Adapters differ in how they read a game's memory; they do not differ in
//! what it means to take a step, wait for a text box, or press a button. That
//! shared half lives here, so adding Silver, Red, Crystal or a romhack means
//! writing a reader, not another control loop. mGBA's core runs Game Boy,
//! Game Boy Color and Game Boy Advance titles alike, so the emulator below is
//! already game-agnostic.

const std = @import("std");
const mgba = @import("mgba.zig");
const obs = @import("observation.zig");
const gamedata = @import("gamedata.zig");
const structs = @import("games/structs.zig");
const firered = @import("games/firered.zig");

const Allocator = std.mem.Allocator;
pub const Direction = structs.Direction;

pub const Error = error{
    UnsupportedRom,
    SymbolMissing,
} || mgba.Error || Allocator.Error;

/// Every supported game. Adding a variant makes the compiler point at each
/// place that has to handle it.
pub const Game = union(enum) {
    firered: firered.FireRed,

    pub const rom_title_addr = 0x080000A0;
    pub const rom_code_addr = 0x080000AC;

    pub const Identity = struct { title: []const u8, code: []const u8 };

    /// Read the cartridge header, which is what decides the adapter.
    pub fn identify(emu: *mgba.Emulator, out: *[16]u8) Identity {
        emu.readBytes(rom_title_addr, out[0..12]);
        emu.readBytes(rom_code_addr, out[12..16]);
        const title = std.mem.sliceTo(out[0..12], 0);
        return .{
            .title = std.mem.trim(u8, title, " "),
            .code = out[12..16],
        };
    }

    pub fn forRom(emu: *mgba.Emulator, data: *const gamedata.GameData) Error!Game {
        var buf: [16]u8 = undefined;
        const id = identify(emu, &buf);
        for (firered.rom_codes) |code| {
            if (std.mem.eql(u8, id.code, code))
                return .{ .firered = try firered.FireRed.init(emu, data) };
        }
        std.log.err(
            "no adapter for ROM '{s}' (code '{s}'); supported: {s} ({s})",
            .{ id.title, id.code, firered.name, firered.rom_codes[0] },
        );
        return error.UnsupportedRom;
    }

    pub fn name(self: Game) []const u8 {
        return switch (self) {
            .firered => firered.name,
        };
    }

    pub fn emulator(self: *Game) *mgba.Emulator {
        return switch (self.*) {
            inline else => |*g| g.emu,
        };
    }

    // -- reads, forwarded to the adapter -------------------------------------

    pub fn screen(self: *Game, gpa: Allocator) !obs.Screen {
        return switch (self.*) {
            inline else => |*g| g.screen(gpa),
        };
    }
    pub fn player(self: *Game, gpa: Allocator) !obs.Player {
        return switch (self.*) {
            inline else => |*g| g.player(gpa),
        };
    }
    pub fn party(self: *Game, gpa: Allocator) ![]obs.Mon {
        return switch (self.*) {
            inline else => |*g| g.party(gpa),
        };
    }
    pub fn location(self: *Game, gpa: Allocator) !?obs.Location {
        return switch (self.*) {
            inline else => |*g| g.location(gpa),
        };
    }
    pub fn dialog(self: *Game, gpa: Allocator) !?obs.Dialog {
        return switch (self.*) {
            inline else => |*g| g.dialog(gpa),
        };
    }
    pub fn battle(self: *Game, gpa: Allocator) !?obs.Battle {
        return switch (self.*) {
            inline else => |*g| g.battle(gpa),
        };
    }
    pub fn menu(self: *Game, gpa: Allocator) !?obs.Menu {
        return switch (self.*) {
            inline else => |*g| g.menu(gpa),
        };
    }
    pub fn viewport(self: *Game) obs.Viewport {
        return switch (self.*) {
            inline else => |*g| g.viewport(),
        };
    }
    pub fn renderScreen(self: *Game, gpa: Allocator) ![]const u8 {
        return switch (self.*) {
            inline else => |*g| g.renderScreen(gpa),
        };
    }
    pub fn legend(self: *Game) []const u8 {
        return switch (self.*) {
            .firered => firered.FireRed.legend,
        };
    }
    pub fn tileAhead(self: *Game) ?obs.Tile {
        return switch (self.*) {
            inline else => |*g| g.tileAhead(),
        };
    }
    pub fn tileAt(self: *Game, x: i16, y: i16) obs.Tile {
        return switch (self.*) {
            inline else => |*g| g.tileAt(x, y),
        };
    }
    pub fn visibleNpcs(self: *Game, gpa: Allocator) ![]obs.Npc {
        return switch (self.*) {
            inline else => |*g| g.visibleNpcs(gpa),
        };
    }
    pub fn visibleWarps(self: *Game, gpa: Allocator) ![]obs.Warp {
        return switch (self.*) {
            inline else => |*g| g.visibleWarps(gpa),
        };
    }
    pub fn visibleSigns(self: *Game, gpa: Allocator) ![]obs.Sign {
        return switch (self.*) {
            inline else => |*g| g.visibleSigns(gpa),
        };
    }
    pub fn facing(self: *Game) Direction {
        return switch (self.*) {
            inline else => |*g| g.facing(),
        };
    }

    /// Map identity plus tile. A warp changes the map without changing the
    /// coordinates, so movement compares all four.
    const Where = struct { group: i8, num: i8, x: i16, y: i16 };

    fn where(self: *Game) Where {
        return switch (self.*) {
            inline else => |*g| blk: {
                const w = g.where();
                break :blk .{ .group = w.group, .num = w.num, .x = w.x, .y = w.y };
            },
        };
    }

    // -- control, shared by every game ---------------------------------------

    /// Hold a button combination, then release it.
    ///
    /// The release matters: the game acts on newly-pressed keys, so a button
    /// left held reads as one press and then nothing at all.
    pub fn press(self: *Game, buttons: mgba.Buttons, hold: u32, release: u32) void {
        const emu = self.emulator();
        emu.setButtons(buttons);
        emu.runFrames(hold);
        emu.setButtons(.none);
        emu.runFrames(release);
    }

    pub fn wait(self: *Game, frames: u32) void {
        const emu = self.emulator();
        emu.setButtons(.none);
        emu.runFrames(frames);
    }

    pub const Point = struct { x: i16, y: i16 };

    pub const StepResult = struct {
        direction: []const u8,
        moved: bool,
        from: Point,
        to: Point,
        frames: u32,
        warped: bool = false,
        blocked_by: ?[]const u8 = null,
    };

    /// Take one step, and report whether it actually happened.
    ///
    /// Holds the d-pad until the player's map position changes rather than for
    /// a fixed number of frames, because a step takes longer on stairs, in
    /// tall grass, or while the game is busy. A step that does not move the
    /// player is a result, not an error: it is how an agent finds a wall, a
    /// ledge, or an NPC in the way.
    pub fn step(self: *Game, gpa: Allocator, dir: Direction, max_frames: u32) !StepResult {
        const emu = self.emulator();
        const start = self.where();

        emu.setButtons(buttonFor(dir));
        var elapsed: u32 = 0;
        while (elapsed < max_frames) : (elapsed += 4) {
            emu.runFrames(4);
            if (!sameWhere(self.where(), start)) break;
        }
        emu.setButtons(.none);
        // Let the walk animation settle so the next read sees a finished tile.
        emu.runFrames(8);

        var end = self.where();
        const warped = end.group != start.group or end.num != start.num;
        if (warped) {
            // A door can land us on the same coordinates on a different map.
            self.wait(40);
            end = self.where();
        }

        const moved = !sameWhere(end, start);
        return .{
            .direction = dir.name(),
            .moved = moved,
            .from = .{ .x = start.x, .y = start.y },
            .to = .{ .x = end.x, .y = end.y },
            .frames = elapsed,
            .warped = warped,
            .blocked_by = if (moved) null else try self.blocker(gpa),
        };
    }

    fn sameWhere(a: Where, b: Where) bool {
        return a.group == b.group and a.num == b.num and a.x == b.x and a.y == b.y;
    }

    fn buttonFor(dir: Direction) mgba.Buttons {
        return switch (dir) {
            .north => .{ .up = true },
            .south => .{ .down = true },
            .west => .{ .left = true },
            .east => .{ .right = true },
            else => .none,
        };
    }

    /// The best available explanation for a step that did not happen.
    fn blocker(self: *Game, gpa: Allocator) !?[]const u8 {
        if (try self.dialog(gpa)) |d| {
            if (d.box_open) return "dialog_open";
        }
        const ahead = self.tileAhead() orelse return "unknown";
        const npcs = try self.visibleNpcs(gpa);
        for (npcs) |n| {
            if (n.x == ahead.x and n.y == ahead.y) return n.kind;
        }
        if (std.mem.indexOf(u8, ahead.behavior, "WATER") != null) return "water";
        if (std.mem.indexOf(u8, ahead.behavior, "JUMP") != null or
            std.mem.indexOf(u8, ahead.behavior, "LEDGE") != null) return "ledge_wrong_way";
        if (!ahead.passable) return "wall";
        return "unknown";
    }

    pub const MoveResult = struct {
        requested: u32,
        completed: u32,
        position: Point,
        blocked_by: ?[]const u8,
        warped: bool,
        steps: []const StepResult,
    };

    /// Repeat `step`, stopping early when something blocks the way.
    pub fn move(self: *Game, gpa: Allocator, dir: Direction, count: u32) !MoveResult {
        var taken: std.ArrayList(StepResult) = .empty;
        var completed: u32 = 0;
        var warped = false;
        var i: u32 = 0;
        while (i < @max(count, 1)) : (i += 1) {
            const r = try self.step(gpa, dir, 64);
            try taken.append(gpa, r);
            if (r.moved) completed += 1;
            if (r.warped) warped = true;
            if (!r.moved or r.warped) break;
        }
        const last = taken.items[taken.items.len - 1];
        return .{
            .requested = count,
            .completed = completed,
            .position = last.to,
            .blocked_by = if (last.moved) null else last.blocked_by,
            .warped = warped,
            .steps = try taken.toOwnedSlice(gpa),
        };
    }

    pub const TextResult = struct {
        messages: []const []const u8,
        box_open: bool,
    };

    /// Press A until the text box closes or stops changing, collecting
    /// everything that was said so a conversation is still readable.
    pub fn advanceText(self: *Game, gpa: Allocator, max_presses: u32) !TextResult {
        var seen: std.ArrayList([]const u8) = .empty;
        var i: u32 = 0;
        var open = false;
        while (i < max_presses) : (i += 1) {
            const d = try self.dialog(gpa);
            open = if (d) |dd| dd.box_open else false;
            if (d) |dd| {
                const last = if (seen.items.len > 0) seen.items[seen.items.len - 1] else "";
                if (dd.text.len != 0 and !std.mem.eql(u8, last, dd.text)) {
                    try seen.append(gpa, dd.text);
                }
            }
            if (!open and seen.items.len > 0) break;
            self.press(.{ .a = true }, 4, 12);
        }
        const final = try self.dialog(gpa);
        return .{
            .messages = try seen.toOwnedSlice(gpa),
            .box_open = if (final) |f| f.box_open else false,
        };
    }

    // -- the whole picture ---------------------------------------------------

    pub fn observe(self: *Game, gpa: Allocator) !obs.Observation {
        const scr = try self.screen(gpa);
        return .{
            .frame = self.emulator().frame(),
            .mode = scr.mode,
            .screen = scr,
            .player = try self.player(gpa),
            .party = try self.party(gpa),
            .dialog = try self.dialog(gpa),
            .menu = try self.menu(gpa),
            .details = switch (scr.mode) {
                .battle => if (try self.battle(gpa)) |b|
                    .{ .battle = b }
                else
                    .elsewhere,
                .overworld => if (try self.location(gpa)) |loc| .{ .overworld = .{
                    .location = loc,
                    .viewport = self.viewport(),
                    .view = try self.renderScreen(gpa),
                    .legend = self.legend(),
                    .tile_ahead = self.tileAhead(),
                    .npcs = try self.visibleNpcs(gpa),
                    .warps = try self.visibleWarps(gpa),
                    .signs = try self.visibleSigns(gpa),
                } } else .elsewhere,
                else => .elsewhere,
            },
        };
    }
};
