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
    pub const Naming = struct { max_chars: u8 };

    /// The open naming screen, if there is one.
    pub fn namingScreen(self: *Game) ?Naming {
        return switch (self.*) {
            inline else => |*g| if (g.namingScreen()) |n|
                Naming{ .max_chars = n.max_chars }
            else
                null,
        };
    }

    /// Type a name into the open naming screen and confirm it.
    pub fn typeName(self: *Game, wanted: []const u8) !u8 {
        const max = switch (self.*) {
            inline else => |*g| try g.writeName(wanted),
        };
        // START is the naming screen's OK button. It takes a moment to accept
        // the name and fade out, and how long varies, so wait for the screen
        // to actually go rather than guessing a frame count.
        self.press(.{ .start = true }, 6, 30);
        var waited: u32 = 0;
        while (waited < 360) : (waited += 20) {
            self.wait(20);
            if (self.namingScreen() == null) break;
        }
        return max;
    }

    /// Show text in the game's own message box, where the adapter supports
    /// it. Optional on purpose: it needs a script engine, which not every
    /// generation drives the same way, so an adapter without it simply says
    /// so rather than every adapter having to provide one.
    /// Stated rather than inferred: with one adapter implementing this the
    /// compiler would never see the unsupported branch, and adding a second
    /// game would silently change the error set callers handle.
    pub const MessageError = error{
        NotInOverworld,
        ScriptAlreadyRunning,
        MessageTooLong,
        UnsupportedCharacter,
        NoSaveBlock,
        NotSupportedByThisGame,
        UnknownColor,
    };

    /// Colour names an adapter understands, or null for its default.
    pub fn showMessage(
        self: *Game,
        message: []const u8,
        color: ?[]const u8,
        background: ?[]const u8,
    ) MessageError!void {
        return switch (self.*) {
            inline else => |*g| blk: {
                const G = @TypeOf(g.*);
                if (!@hasDecl(G, "showMessage")) break :blk error.NotSupportedByThisGame;
                var palette: G.Palette = .{};
                if (color) |c| palette.text = G.TextColor.parse(c) orelse
                    break :blk error.UnknownColor;
                if (background) |c| palette.background = G.TextColor.parse(c) orelse
                    break :blk error.UnknownColor;
                break :blk g.showMessage(message, palette);
            },
        };
    }

    pub fn inputLocked(self: *Game) bool {
        return switch (self.*) {
            inline else => |*g| g.inputLocked(),
        };
    }

    pub fn inBattle(self: *Game) bool {
        return switch (self.*) {
            inline else => |*g| g.inBattle(),
        };
    }

    fn setBattleAction(self: *Game, action: u8) void {
        switch (self.*) {
            inline else => |*g| g.setBattleAction(action),
        }
    }

    fn setBattleMoveSlot(self: *Game, slot: u8) void {
        switch (self.*) {
            inline else => |*g| g.setBattleMoveSlot(slot),
        }
    }

    fn battleAwaitingAction(self: *Game) bool {
        return switch (self.*) {
            inline else => |*g| g.battleAwaitingAction(),
        };
    }

    fn battleAwaitingMove(self: *Game) bool {
        return switch (self.*) {
            inline else => |*g| g.battleAwaitingMove(),
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
            .blocked_by = if (moved) null else try self.blocker(gpa, dir),
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
    ///
    /// Judged on the tile in the direction that was actually tried, not the
    /// one the player happens to be facing. A blocked step often leaves the
    /// facing unchanged, so using it would blame whatever is in front of the
    /// player for every direction alike.
    fn blocker(self: *Game, gpa: Allocator, dir: Direction) !?[]const u8 {
        // A script that owns the player blocks every direction equally, so
        // check it before blaming the scenery.
        if (self.inputLocked()) return "script_running";
        if (try self.dialog(gpa)) |d| {
            if (d.box_open) return "dialog_open";
        }

        const w = self.where();
        const d = dir.delta();
        const target = self.tileAt(w.x + d.x, w.y + d.y);

        const npcs = try self.visibleNpcs(gpa);
        for (npcs) |n| {
            if (n.x == target.x and n.y == target.y) return n.kind;
        }
        if (std.mem.indexOf(u8, target.behavior, "WATER") != null) return "water";
        if (std.mem.indexOf(u8, target.behavior, "JUMP") != null or
            std.mem.indexOf(u8, target.behavior, "LEDGE") != null) return "ledge_wrong_way";
        if (!target.passable) return "wall";
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

    /// Press A until the text box closes, collecting everything that was said
    /// so a conversation is still readable afterwards.
    ///
    /// Does nothing when no box is open: this advances text, it does not start
    /// a conversation. Mashing A at an empty overworld would walk into signs
    /// and talk to whoever happened to be standing there.
    pub fn advanceText(self: *Game, gpa: Allocator, max_presses: u32) !TextResult {
        var seen: std.ArrayList([]const u8) = .empty;
        // There is something to advance whenever a box is up OR a field script
        // holds the controls. A script can park in `waitbuttonpress` with its
        // message box already flag-hidden but the text still drawn and input
        // locked -- a player presses A there to go on, and so must we. While
        // input is locked A can only feed that script; it cannot walk into a
        // sign or talk to an NPC, so pressing it is safe even through the
        // scripted movement that a farewell like the rival's runs afterwards.
        if (try self.dialog(gpa) == null and !self.inputLocked()) {
            return .{ .messages = &.{}, .box_open = false };
        }

        var i: u32 = 0;
        while (i < max_presses) : (i += 1) {
            if (try self.dialog(gpa)) |dd| {
                try appendMessage(gpa, &seen, dd.text);
            } else if (!self.inputLocked()) {
                // No box, and control has come back to the player: done.
                break;
            }
            self.press(.{ .a = true }, 4, 12);
        }
        return .{
            .messages = try seen.toOwnedSlice(gpa),
            .box_open = try self.dialog(gpa) != null,
        };
    }

    pub const UseMoveResult = struct {
        used: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
        messages: []const []const u8 = &.{},
        in_battle: bool = false,
    };

    /// Pick a move in battle by name or 1-based number, then play the turn out.
    ///
    /// By hand this means opening FIGHT and walking a 2x2 grid with no reliable
    /// read of where the cursor began -- easy to fumble into the wrong move, or
    /// into RUN. Instead this writes the two cursor variables the game consults
    /// the instant A is pressed, so the choice is exact, then presses through
    /// the turn's text and hands back what was said. Call it while the
    /// FIGHT/BAG/POKEMON/RUN menu is showing.
    pub fn useMove(self: *Game, gpa: Allocator, want: []const u8) !UseMoveResult {
        if (!self.inBattle()) return .{ .@"error" = "not in a battle; nothing to attack" };
        const m = try self.menu(gpa) orelse
            return .{ .in_battle = true, .@"error" = "no battle menu is up yet; wait for your turn" };
        if (!std.mem.eql(u8, m.kind, "battle_menu"))
            return .{ .in_battle = true, .@"error" = "not the battle menu right now" };

        // Resolve the request to a move slot: a 1-based number, or a name
        // (case-insensitive). Anything else comes back with the known moves
        // listed, so the caller can retry without guessing.
        var slot: ?u8 = null;
        if (std.fmt.parseInt(u32, want, 10) catch null) |n| {
            if (n >= 1 and n <= m.moves.len) slot = @intCast(n - 1);
        }
        if (slot == null) for (m.moves, 0..) |mv, i| {
            if (std.ascii.eqlIgnoreCase(mv.name, want)) {
                slot = @intCast(i);
                break;
            }
        };
        const chosen = slot orelse {
            var names: std.ArrayList([]const u8) = .empty;
            for (m.moves) |mv| try names.append(gpa, mv.name);
            return .{ .in_battle = true, .@"error" = try std.fmt.allocPrint(
                gpa,
                "no move '{s}'; you know: {s}",
                .{ want, try std.mem.join(gpa, ", ", names.items) },
            ) };
        };
        const move_name = m.moves[chosen].name;

        var seen: std.ArrayList([]const u8) = .empty;

        // Reach the action menu first, reading out any battle text on the way.
        // The game tells us when a menu is genuinely taking input, so presses
        // here only ever advance messages; the choice itself is made by writing
        // the cursor, so nothing is selected while text is still on screen --
        // the trap that eats a naive "just press A" during "Wild X appeared!".
        if (!try self.reachBattlePrompt(gpa, &seen, .action))
            return self.battleResult(gpa, null, &seen);

        // FIGHT, wait for the move menu to take over, then the move. The game
        // reads each cursor the instant A lands.
        self.setBattleAction(0);
        self.press(.{ .a = true }, 4, 12);
        if (!try self.reachBattlePrompt(gpa, &seen, .move))
            return self.battleResult(gpa, null, &seen);
        self.setBattleMoveSlot(chosen);
        self.press(.{ .a = true }, 4, 12);

        // Play the turn out: read every line, and stop when the battle ends or
        // it is our turn to choose again.
        try self.playBattleTurn(gpa, &seen);
        return self.battleResult(gpa, move_name, &seen);
    }

    const BattlePrompt = enum { action, move };

    /// Advance battle text until the given menu is actually taking input.
    /// Returns false if the battle ended, or the budget ran out, first.
    fn reachBattlePrompt(
        self: *Game,
        gpa: Allocator,
        seen: *std.ArrayList([]const u8),
        which: BattlePrompt,
    ) !bool {
        var i: u32 = 0;
        while (i < 240) : (i += 1) {
            if (!self.inBattle()) return false;
            const ready = switch (which) {
                .action => self.battleAwaitingAction(),
                .move => self.battleAwaitingMove(),
            };
            if (ready) return true;
            try self.advanceBattleText(gpa, seen);
        }
        return false;
    }

    /// Read out a turn until the battle ends or the action menu comes back.
    fn playBattleTurn(self: *Game, gpa: Allocator, seen: *std.ArrayList([]const u8)) !void {
        var i: u32 = 0;
        while (i < 400) : (i += 1) {
            if (!self.inBattle() or self.battleAwaitingAction()) return;
            try self.advanceBattleText(gpa, seen);
        }
    }

    /// One step through a turn that is playing out: record any new line, then
    /// press A to move things along.
    ///
    /// A is pressed whether or not there is readable text, because some prompts
    /// that wait for the player show none -- the level-up stat box is the one
    /// that hangs the whole battle if it is never answered. That is safe here:
    /// the callers only run this while the battle is busy, never while a menu is
    /// actually taking a choice (those are gated by the await checks), so the
    /// press can only dismiss narration and acknowledgements, not pick an
    /// option behind the agent's back. Pressing during an animation is a no-op.
    fn advanceBattleText(self: *Game, gpa: Allocator, seen: *std.ArrayList([]const u8)) !void {
        if (try self.dialog(gpa)) |d| try appendMessage(gpa, seen, d.text);
        self.press(.{ .a = true }, 4, 12);
    }

    fn appendMessage(gpa: Allocator, seen: *std.ArrayList([]const u8), line: []const u8) !void {
        const last = if (seen.items.len > 0) seen.items[seen.items.len - 1] else "";
        if (line.len != 0 and !std.mem.eql(u8, last, line)) try seen.append(gpa, line);
    }

    fn battleResult(
        self: *Game,
        gpa: Allocator,
        used: ?[]const u8,
        seen: *std.ArrayList([]const u8),
    ) !UseMoveResult {
        return .{
            .used = used,
            .messages = try seen.toOwnedSlice(gpa),
            .in_battle = self.inBattle(),
            // A null move with the battle still running means we never reached
            // the menu; if the battle ended, that is an outcome, not an error.
            .@"error" = if (used == null and self.inBattle())
                "could not reach the move menu; observe and try again"
            else
                null,
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
