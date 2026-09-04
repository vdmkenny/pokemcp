//! pokemcp -- an MCP server that plays Pokemon through emulator memory.
//!
//! Speaks JSON-RPC over stdio, so stdout carries the protocol and nothing
//! else; diagnostics go to stderr.

const std = @import("std");
const mgba = @import("mgba.zig");
const gamedata = @import("gamedata.zig");
const game_mod = @import("game.zig");
const mcp = @import("mcp.zig");

const usage =
    \\pokemcp -- MCP server for playing Pokemon through emulator memory
    \\
    \\usage: pokemcp --rom <file.gba> [options]
    \\
    \\  --rom <path>    ROM to run (required)
    \\  --data <path>   generated game table (default: data/firered.dat)
    \\  --save <path>   battery save file to attach (.sav)
    \\  --boot <n>      frames to run before serving (default: 0)
    \\  --help          this message
    \\
    \\The game table is produced from a built disassembly with
    \\`zig build gamedata -- <pokefirered-dir>`; see the README.
    \\
;

const Options = struct {
    rom: ?[]const u8 = null,
    data: []const u8 = "data/firered.dat",
    save: ?[]const u8 = null,
    boot: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const err = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try err.writeAll(usage);
            try err.flush();
            return;
        } else if (std.mem.eql(u8, a, "--rom") and i + 1 < args.len) {
            i += 1;
            opts.rom = args[i];
        } else if (std.mem.eql(u8, a, "--data") and i + 1 < args.len) {
            i += 1;
            opts.data = args[i];
        } else if (std.mem.eql(u8, a, "--save") and i + 1 < args.len) {
            i += 1;
            opts.save = args[i];
        } else if (std.mem.eql(u8, a, "--boot") and i + 1 < args.len) {
            i += 1;
            opts.boot = std.fmt.parseInt(u32, args[i], 10) catch 0;
        } else {
            try err.print("unknown argument: {s}\n\n{s}", .{ a, usage });
            try err.flush();
            std.process.exit(2);
        }
    }

    const rom = opts.rom orelse {
        try err.writeAll(usage);
        try err.flush();
        std.process.exit(2);
    };

    var emu = mgba.Emulator.init(gpa, rom) catch |e| {
        try err.print("could not load ROM {s}: {s}\n", .{ rom, @errorName(e) });
        try err.flush();
        std.process.exit(1);
    };
    defer emu.deinit();

    if (opts.save) |save_path| {
        emu.loadSave(save_path) catch |e| {
            try err.print("could not attach save {s}: {s}\n", .{ save_path, @errorName(e) });
            try err.flush();
        };
    }

    var data = gamedata.GameData.loadFile(gpa, io, opts.data) catch |e| {
        try err.print(
            "could not load the game table {s}: {s}\n" ++
                "generate it with: zig build gamedata -- <pokefirered-dir>\n",
            .{ opts.data, @errorName(e) },
        );
        try err.flush();
        std.process.exit(1);
    };
    defer data.deinit();

    var game = game_mod.Game.forRom(&emu, &data) catch |e| {
        try err.print("unsupported ROM: {s}\n", .{@errorName(e)});
        try err.flush();
        std.process.exit(1);
    };

    if (opts.boot > 0) emu.runFrames(opts.boot);

    try err.print(
        "pokemcp {s}: {s}, {d} symbols loaded, serving on stdio\n",
        .{ mcp.server_version, game.name(), data.by_addr.len },
    );
    try err.flush();

    var session: mcp.Session = .{ .gpa = gpa, .game = &game, .data = &data };
    defer session.deinit();

    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [256 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);

    var server: mcp.Server = .{ .session = &session, .out = &stdout.interface };
    try server.serve(gpa, &stdin.interface);
}

test {
    _ = @import("mgba.zig");
    _ = @import("text.zig");
    _ = @import("gamedata.zig");
    _ = @import("dataformat.zig");
    _ = @import("observation.zig");
    _ = @import("game.zig");
    _ = @import("games/structs.zig");
    _ = @import("games/pokemon.zig");
    _ = @import("games/firered.zig");
    _ = @import("mcp.zig");
}
