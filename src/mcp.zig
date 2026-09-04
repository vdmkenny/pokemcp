//! The MCP server: JSON-RPC 2.0 over stdio.
//!
//! The tool surface is deliberately narrow and primitive. It reports what the
//! screen shows and it presses buttons; it does not path-find, auto-navigate,
//! or reveal the map beyond the viewport. Working out how to get somewhere is
//! the agent's job, the same way it is a player's.

const std = @import("std");
const mgba = @import("mgba.zig");
const game_mod = @import("game.zig");
const gamedata = @import("gamedata.zig");
const structs = @import("games/structs.zig");

const Allocator = std.mem.Allocator;
const Game = game_mod.Game;
const Json = std.json.Stringify;

pub const protocol_version = "2025-06-18";
pub const server_name = "pokemcp";
pub const server_version = "0.1.0";

pub const save_slots = 8;

pub const Session = struct {
    gpa: Allocator,
    game: *Game,
    data: *const gamedata.GameData,
    io: std.Io,
    states: [save_slots]?[]u8 = @splat(null),

    pub fn deinit(self: *Session) void {
        for (self.states) |maybe| {
            if (maybe) |blob| self.gpa.free(blob);
        }
    }
};

/// Arguments of one tool call, as parsed JSON.
const Args = struct {
    value: std.json.Value,

    fn get(self: Args, name: []const u8) ?std.json.Value {
        return switch (self.value) {
            .object => |o| o.get(name),
            else => null,
        };
    }

    fn int(self: Args, name: []const u8, default: i64) i64 {
        const v = self.get(name) orelse return default;
        return switch (v) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            .string => |s| std.fmt.parseInt(i64, s, 0) catch default,
            else => default,
        };
    }

    fn uint(self: Args, name: []const u8, default: u32) u32 {
        const i = self.int(name, default);
        return if (i < 0) default else @intCast(i);
    }

    fn string(self: Args, name: []const u8) ?[]const u8 {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn array(self: Args, name: []const u8) ?[]std.json.Value {
        const v = self.get(name) orelse return null;
        return switch (v) {
            .array => |a| a.items,
            else => null,
        };
    }
};

pub const ToolError = error{ BadArgument, OutOfMemory } ||
    std.Io.Writer.Error || mgba.Error || anyerror;

const Handler = *const fn (*Session, Args, Allocator, *Json) ToolError!void;

const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Pre-rendered JSON Schema. Written verbatim into `tools/list`.
    schema: []const u8,
    handler: Handler,
};

const empty_schema = "{\"type\":\"object\",\"properties\":{}}";

/// The whole agent-facing surface, in one table. `tools/list` is generated
/// from it, so a tool cannot be added without also being described.
const tools = [_]Tool{
    .{
        .name = "observe",
        .description =
            \\Everything on screen right now, as structured data: the game mode, the
            \\15x10 tile view around the player with a legend, visible NPCs, doors and
            \\signs, any open text box or menu, and the full party. This is the main
            \\tool; call it after anything that changes the game.
            \\
            \\Only what the Game Boy screen shows is reported. There is no world map
            \\and no path-finding: to cross a map, read the view, move, and read again.
        ,
        .schema = empty_schema,
        .handler = toolObserve,
    },
    .{
        .name = "screen",
        .description = "Just the ASCII tile view and the player's coordinates. " ++
            "Cheaper than observe when you are only navigating.",
        .schema = empty_schema,
        .handler = toolScreen,
    },
    .{
        .name = "move",
        .description =
            \\Walk one or more tiles in a direction, checking after each step that the
            \\player actually moved. Stops early when something is in the way and says
            \\what: a wall, water, an NPC, a ledge, or an open text box.
            \\
            \\Doors and stairs are entered by walking onto them; stairs and arrow tiles
            \\need one more press in the direction the "trigger" field of that warp
            \\gives. Accepts north/south/east/west or up/down/left/right.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"direction\":{\"type\":\"string\",\"enum\":[\"north\",\"south\",\"east\",\"west\",\"up\",\"down\",\"left\",\"right\"]},\"steps\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":64,\"default\":1}},\"required\":[\"direction\"]}",
        .handler = toolMove,
    },
    .{
        .name = "press",
        .description =
            \\Press buttons: a, b, start, select, up, down, left, right, l, r. Several
            \\names at once are pressed together. Use this for menus, battles and
            \\confirmations; use `move` for walking, since it verifies the result.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"buttons\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"button names pressed together\"},\"repeat\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":64,\"default\":1},\"hold_frames\":{\"type\":\"integer\",\"default\":4},\"release_frames\":{\"type\":\"integer\",\"default\":12}},\"required\":[\"buttons\"]}",
        .handler = toolPress,
    },
    .{
        .name = "wait",
        .description = "Let the game run without input, for animations, " ++
            "screen fades and scripted scenes. 60 frames is one second.",
        .schema = "{\"type\":\"object\",\"properties\":{\"frames\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":3600,\"default\":60}}}",
        .handler = toolWait,
    },
    .{
        .name = "advance_text",
        .description =
            \\Press A until the text box closes, returning every message shown along
            \\the way so nothing said is missed. Use it for conversations and signs.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"max_presses\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200,\"default\":30}}}",
        .handler = toolAdvanceText,
    },
    .{
        .name = "party",
        .description = "The player's Pokemon: species, level, HP, status, moves and PP. " ++
            "Always available, whether or not the party menu is open.",
        .schema = empty_schema,
        .handler = toolParty,
    },
    .{
        .name = "save_state",
        .description = "Snapshot the whole machine so an experiment can be undone. " ++
            "Numbered slots last for this session; give a path to keep one on disk " ++
            "and reload it in a later session.",
        .schema = "{\"type\":\"object\",\"properties\":{\"slot\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":7,\"default\":0},\"path\":{\"type\":\"string\",\"description\":\"write the snapshot here instead of a slot\"}}}",
        .handler = toolSaveState,
    },
    .{
        .name = "load_state",
        .description = "Restore a snapshot taken with save_state, from a slot or a path.",
        .schema = "{\"type\":\"object\",\"properties\":{\"slot\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":7,\"default\":0},\"path\":{\"type\":\"string\"}}}",
        .handler = toolLoadState,
    },
    .{
        .name = "read_memory",
        .description =
            \\Read raw bytes, by address or by symbol name from the disassembly.
            \\An escape hatch for things the structured tools do not cover; the
            \\other tools are easier for anything they already report.
        ,
        .schema = "{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\",\"description\":\"symbol name, e.g. gSaveBlock1Ptr\"},\"address\":{\"type\":\"integer\",\"description\":\"absolute GBA address, if no symbol\"},\"offset\":{\"type\":\"integer\",\"default\":0,\"description\":\"added to the symbol address\"},\"length\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":4096,\"default\":16}}}",
        .handler = toolReadMemory,
    },
    .{
        .name = "find_symbol",
        .description = "Look a symbol up by name, or find which symbol an address " ++
            "falls inside. Useful for exploring with read_memory.",
        .schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"address\":{\"type\":\"integer\"}}}",
        .handler = toolFindSymbol,
    },
};

// -- tool implementations ----------------------------------------------------

fn toolObserve(session: *Session, _: Args, gpa: Allocator, out: *Json) ToolError!void {
    try out.write(try session.game.observe(gpa));
}

fn toolScreen(session: *Session, _: Args, gpa: Allocator, out: *Json) ToolError!void {
    const g = session.game;
    const scr = try g.screen(gpa);
    if (scr.mode != .overworld) {
        try out.write(.{
            .mode = @tagName(scr.mode),
            .screen = scr,
            .note = "not on the map; the tile view only exists in the overworld",
        });
        return;
    }
    try out.write(.{
        .mode = @tagName(scr.mode),
        .screen = scr,
        .location = try g.location(gpa),
        .viewport = g.viewport(),
        .view = try g.renderScreen(gpa),
        .legend = g.legend(),
        .tile_ahead = g.tileAhead(),
        .facing = g.facing().name(),
    });
}

fn toolMove(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    const name = args.string("direction") orelse return error.BadArgument;
    const dir = structs.Direction.parse(name) orelse return error.BadArgument;
    const steps = args.uint("steps", 1);
    const result = try session.game.move(gpa, dir, steps);
    try out.write(.{
        .moved = result.completed,
        .requested = result.requested,
        .position = result.position,
        .blocked_by = result.blocked_by,
        .warped = result.warped,
        .view = try session.game.renderScreen(gpa),
    });
}

fn toolPress(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    const names = args.array("buttons") orelse return error.BadArgument;
    var buttons: mgba.Buttons = .none;
    for (names) |v| {
        const s = switch (v) {
            .string => |str| str,
            else => return error.BadArgument,
        };
        buttons = buttons.unionWith(mgba.Buttons.parse(s) orelse return error.BadArgument);
    }
    if (buttons.isEmpty()) return error.BadArgument;

    const repeat = @min(args.uint("repeat", 1), 64);
    const hold = args.uint("hold_frames", 4);
    const release = args.uint("release_frames", 12);
    var i: u32 = 0;
    while (i < @max(repeat, 1)) : (i += 1) session.game.press(buttons, hold, release);

    try out.write(.{
        .pressed = try std.fmt.allocPrint(gpa, "{f}", .{buttons}),
        .repeat = repeat,
        .frame = session.game.emulator().frame(),
        .screen = try session.game.screen(gpa),
        .dialog = try session.game.dialog(gpa),
        .menu = try session.game.menu(gpa),
    });
}

fn toolWait(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    const frames = @min(args.uint("frames", 60), 3600);
    session.game.wait(frames);
    try out.write(.{
        .waited = frames,
        .frame = session.game.emulator().frame(),
        .screen = try session.game.screen(gpa),
        .dialog = try session.game.dialog(gpa),
    });
}

fn toolAdvanceText(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    const max = @min(args.uint("max_presses", 30), 200);
    const r = try session.game.advanceText(gpa, max);
    try out.write(.{
        .messages = r.messages,
        .box_still_open = r.box_open,
        .screen = try session.game.screen(gpa),
    });
}

fn toolParty(session: *Session, _: Args, gpa: Allocator, out: *Json) ToolError!void {
    try out.write(.{ .party = try session.game.party(gpa) });
}

fn toolSaveState(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    if (args.string("path")) |path| {
        const blob = try session.game.emulator().saveState(gpa);
        try std.Io.Dir.cwd().writeFile(session.io, .{ .sub_path = path, .data = blob });
        try out.write(.{ .saved = true, .path = path, .bytes = blob.len });
        return;
    }
    const slot = args.uint("slot", 0);
    if (slot >= save_slots) return error.BadArgument;
    const blob = try session.game.emulator().saveState(session.gpa);
    if (session.states[slot]) |old| session.gpa.free(old);
    session.states[slot] = blob;
    try out.write(.{ .saved = true, .slot = slot, .bytes = blob.len });
}

fn toolLoadState(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    if (args.string("path")) |path| {
        const blob = std.Io.Dir.cwd().readFileAlloc(
            session.io,
            path,
            gpa,
            .limited(16 << 20),
        ) catch {
            try out.write(.{ .loaded = false, .path = path, .@"error" = "cannot read that file" });
            return;
        };
        try session.game.emulator().loadState(blob);
        try out.write(.{ .loaded = true, .path = path, .screen = try session.game.screen(gpa) });
        return;
    }
    const slot = args.uint("slot", 0);
    if (slot >= save_slots) return error.BadArgument;
    const blob = session.states[slot] orelse {
        try out.write(.{ .loaded = false, .slot = slot, .@"error" = "slot is empty" });
        return;
    };
    try session.game.emulator().loadState(blob);
    try out.write(.{
        .loaded = true,
        .slot = slot,
        .screen = try session.game.screen(gpa),
    });
}

fn toolReadMemory(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    const length = @min(args.uint("length", 16), 4096);
    var base: u32 = undefined;
    if (args.string("symbol")) |name| {
        base = session.data.find(name) orelse {
            try out.write(.{ .@"error" = "unknown symbol", .symbol = name });
            return;
        };
    } else {
        const addr = args.int("address", -1);
        if (addr < 0) return error.BadArgument;
        base = @intCast(addr);
    }
    const offset = args.int("offset", 0);
    const addr: u32 = @intCast(@as(i64, base) + offset);

    const bytes = try gpa.alloc(u8, length);
    session.game.emulator().readBytes(addr, bytes);

    const hex = try gpa.alloc(u8, bytes.len * 2);
    _ = std.fmt.bufPrint(hex, "{x}", .{bytes}) catch {};

    try out.write(.{
        .address = try std.fmt.allocPrint(gpa, "0x{x:0>8}", .{addr}),
        .length = length,
        .hex = hex,
    });
}

fn toolFindSymbol(session: *Session, args: Args, gpa: Allocator, out: *Json) ToolError!void {
    if (args.string("name")) |name| {
        if (session.data.find(name)) |addr| {
            try out.write(.{
                .name = name,
                .address = try std.fmt.allocPrint(gpa, "0x{x:0>8}", .{addr}),
            });
        } else {
            try out.write(.{ .name = name, .found = false });
        }
        return;
    }
    const addr = args.int("address", -1);
    if (addr < 0) return error.BadArgument;
    if (session.data.resolve(@intCast(addr))) |sym| {
        try out.write(.{
            .name = sym.name,
            .address = try std.fmt.allocPrint(gpa, "0x{x:0>8}", .{sym.addr}),
            .offset = @as(u32, @intCast(addr)) - sym.addr,
        });
    } else {
        try out.write(.{ .found = false });
    }
}

// -- JSON-RPC ---------------------------------------------------------------

pub const Server = struct {
    session: *Session,
    out: *std.Io.Writer,

    pub fn serve(self: *Server, gpa: Allocator, in: *std.Io.Reader) !void {
        while (true) {
            const line = in.takeDelimiterExclusive('\n') catch |err| switch (err) {
                error.EndOfStream => return,
                error.StreamTooLong => {
                    in.tossBuffered();
                    continue;
                },
                else => return err,
            };
            defer in.toss(1);
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;

            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            try self.handleLine(arena_state.allocator(), trimmed);
        }
    }

    fn handleLine(self: *Server, arena: Allocator, line: []const u8) !void {
        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            line,
            .{},
        ) catch {
            try self.writeError(arena, .null, -32700, "invalid JSON");
            return;
        };
        const obj = switch (parsed) {
            .object => |o| o,
            else => {
                try self.writeError(arena, .null, -32600, "request must be an object");
                return;
            },
        };
        const method = switch (obj.get("method") orelse .null) {
            .string => |m| m,
            else => {
                try self.writeError(arena, .null, -32600, "missing method");
                return;
            },
        };
        const id = obj.get("id") orelse .null;
        const params = obj.get("params") orelse .null;

        // Notifications carry no id and expect no reply.
        const is_notification = id == .null;

        if (std.mem.eql(u8, method, "initialize")) {
            try self.writeInitialize(arena, id);
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try self.writeToolList(arena, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try self.callTool(arena, id, params);
        } else if (std.mem.eql(u8, method, "ping")) {
            try self.beginResult(id);
            try self.json().beginObject();
            try self.json().endObject();
            try self.endResult();
        } else if (is_notification) {
            // initialized, cancelled, and anything else we do not act on.
        } else {
            try self.writeError(arena, id, -32601, "unknown method");
        }
    }

    var stringify_storage: Json = undefined;

    fn json(self: *Server) *Json {
        stringify_storage = .{ .writer = self.out, .options = .{} };
        return &stringify_storage;
    }

    fn writeInitialize(self: *Server, arena: Allocator, id: std.json.Value) !void {
        _ = arena;
        var js: Json = .{ .writer = self.out, .options = .{} };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("result");
        try js.write(.{
            .protocolVersion = protocol_version,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = server_name, .version = server_version },
            .instructions =
                \\Plays Pokemon FireRed through emulator memory rather than pixels.
                \\
                \\Call `observe` to see the game: it returns the 15x10 tile view the
                \\Game Boy is drawing, the NPCs and doors inside it, any text box or
                \\menu, and your party. Nothing outside that view is reported, so
                \\navigate the way a player does -- look, move a few tiles, look again.
                \\
                \\`move` walks and tells you whether you actually moved and what
                \\stopped you. `press` handles menus and battles. `advance_text` gets
                \\through conversations without losing what was said.
            ,
        });
        try js.endObject();
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    fn writeToolList(self: *Server, arena: Allocator, id: std.json.Value) !void {
        _ = arena;
        var js: Json = .{ .writer = self.out, .options = .{} };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("result");
        try js.beginObject();
        try js.objectField("tools");
        try js.beginArray();
        inline for (tools) |tool| {
            try js.beginObject();
            try js.objectField("name");
            try js.write(tool.name);
            try js.objectField("description");
            try js.write(tool.description);
            try js.objectField("inputSchema");
            // The schema is already JSON; hand it through untouched.
            try js.beginWriteRaw();
            try self.out.writeAll(tool.schema);
            js.endWriteRaw();
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
        try js.endObject();
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    fn callTool(self: *Server, arena: Allocator, id: std.json.Value, params: std.json.Value) !void {
        const name = switch (params) {
            .object => |o| switch (o.get("name") orelse .null) {
                .string => |n| n,
                else => return self.writeError(arena, id, -32602, "missing tool name"),
            },
            else => return self.writeError(arena, id, -32602, "missing params"),
        };
        const args: Args = .{
            .value = switch (params) {
                .object => |o| o.get("arguments") orelse .null,
                else => .null,
            },
        };

        // Render the tool's result into a buffer first: MCP carries it as a
        // text block, so it has to be embedded as a JSON string.
        var body: std.Io.Writer.Allocating = .init(arena);
        var body_js: Json = .{ .writer = &body.writer, .options = .{ .whitespace = .indent_2 } };

        var found = false;
        var failed: ?[]const u8 = null;
        inline for (tools) |tool| {
            if (!found and std.mem.eql(u8, name, tool.name)) {
                found = true;
                tool.handler(self.session, args, arena, &body_js) catch |err| {
                    failed = @errorName(err);
                };
            }
        }
        if (!found) return self.writeError(arena, id, -32602, "unknown tool");

        var js: Json = .{ .writer = self.out, .options = .{} };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("result");
        try js.beginObject();
        try js.objectField("content");
        try js.beginArray();
        try js.beginObject();
        try js.objectField("type");
        try js.write("text");
        try js.objectField("text");
        if (failed) |e| {
            try js.print("\"{s} failed: {s}\"", .{ name, e });
        } else {
            try js.write(body.written());
        }
        try js.endObject();
        try js.endArray();
        if (failed != null) {
            try js.objectField("isError");
            try js.write(true);
        }
        try js.endObject();
        try js.endObject();
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    fn writeError(
        self: *Server,
        arena: Allocator,
        id: std.json.Value,
        code: i32,
        message: []const u8,
    ) !void {
        _ = arena;
        var js: Json = .{ .writer = self.out, .options = .{} };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("error");
        try js.write(.{ .code = code, .message = message });
        try js.endObject();
        try self.out.writeByte('\n');
        try self.out.flush();
    }

    fn beginResult(self: *Server, id: std.json.Value) !void {
        var js: Json = .{ .writer = self.out, .options = .{} };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("result");
    }

    fn endResult(self: *Server) !void {
        var js: Json = .{ .writer = self.out, .options = .{} };
        try js.endObject();
        try self.out.writeByte('\n');
        try self.out.flush();
    }
};

test "schemas contain no newlines" {
    // MCP frames messages one per line, and schemas are written into the
    // response verbatim. A literal newline inside one would cut the message
    // in half and every client would see truncated JSON.
    inline for (tools) |tool| {
        try std.testing.expect(std.mem.indexOfScalar(u8, tool.schema, '\n') == null);
    }
}

test "every tool has a name, a description and a schema" {
    inline for (tools) |tool| {
        try std.testing.expect(tool.name.len > 0);
        try std.testing.expect(tool.description.len > 20);
        try std.testing.expect(std.mem.startsWith(u8, tool.schema, "{"));
        // The schema must parse: it is handed to clients verbatim.
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            tool.schema,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
}

test "tool names are unique" {
    inline for (tools, 0..) |a, i| {
        inline for (tools, 0..) |b, j| {
            if (i != j) try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}
