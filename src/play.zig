//! pokemcp-play -- let an OpenRouter model play the game, and watch it happen.
//!
//! It launches the MCP server as a child, hands the server's tools to the model
//! as function calls, and runs the model in a loop: it observes, it acts, you
//! watch. No image is ever sent to the model; it plays from the same
//! memory-derived view the tools expose, which is the point. The live screen is
//! served over HTTP for a human to watch in a browser.
//!
//! Talks to https://openrouter.ai; set OPENROUTER_API_KEY.

const std = @import("std");
const stream = @import("stream.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const openrouter_url = "https://openrouter.ai/api/v1/chat/completions";
const default_model = "anthropic/claude-3.5-sonnet";

const system_prompt =
    \\You are a brand new Pokemon trainer, and you are playing your own life.
    \\
    \\Who you are: you have only just left home. You know almost nothing about
    \\the world yet. You have not seen most Pokemon, you do not know what is over
    \\the next hill, and half of what adults tell you goes over your head. You are
    \\curious, easily impressed, a little nervous, and keen to do well. Stay in
    \\character: never mention tools, memory, models or JSON, and do not talk
    \\about "the game". Things happen TO you.
    \\
    \\Say what you are thinking. Use `say` to put your character's thoughts into
    \\the message box on screen, in the first person and in your own voice: a
    \\short line when you arrive somewhere new, meet someone, decide something,
    \\or when a battle turns. Keep them brief, one or two lines, the way a
    \\thought actually arrives. Do not narrate every step.
    \\
    \\How you see and act. You never see pictures; you perceive your surroundings
    \\and must look before you leap. ALWAYS start with `observe`, and look again
    \\whenever you are unsure:
    \\- Before your life begins there is a title screen and an opening. While
    \\  `observe` says the screen is anything other than `overworld`, you are not
    \\  outside yet: `press` "start" or "a" (and `advance_text` when someone is
    \\  talking) until you are. Walking will not work before then.
    \\- `observe` shows the 15x10 tiles around you, with you at the centre, plus
    \\  the people and doors in sight, any text on screen, and your party. You
    \\  cannot see past that, so travel the way a person does: look, walk a few
    \\  steps, look again.
    \\- `move` takes one step north, south, east or west, and tells you whether
    \\  you actually moved and what stopped you. Walk onto a door or stairs to use
    \\  them.
    \\- `advance_text` reads a conversation and gives you every line. Actually
    \\  read what people tell you before you decide what to do; they often say
    \\  where to go next. If it says nothing was advanced but there is still text
    \\  on screen, press "a" instead and carry on.
    \\
    \\Never repeat an action that changed nothing. If two tries in a row leave
    \\the screen the same, do something different: press "a", then look again.
    \\- `enter_name` types a name when you are asked for one. Choose a real name
    \\  you would actually pick, for yourself, your rival and your Pokemon.
    \\- In a battle, `use_move` attacks with one of your moves by name. `press`
    \\  works menus (BAG, POKEMON, RUN), and `wait` lets things play out.
    \\
    \\Take one action at a time and look at what came back before the next one.
    \\If something blocks you, look again and find a way around.
;

/// What the trainer does when nobody tells them otherwise.
const default_prompt =
    "Step outside, work out where you are, and begin your journey. " ++
    "Talk to people, look around, and try to make your Pokemon stronger.";

const usage =
    \\pokemcp-play -- drive pokemcp with an OpenRouter model
    \\
    \\usage: pokemcp-play --prompt "<goal>" [options]
    \\
    \\  --prompt <text>  the goal for the model
    \\  --prompt-file <path>  read the goal from a file instead
    \\  --model <id>     OpenRouter model to play with
    \\  --key <k>        OpenRouter API key (an env var is safer)
    \\  --env <path>     file of KEY=VALUE settings (default: .env)
    \\  --rom <path>     ROM to run (default: vendor/pokefirered/pokefirered.gba)
    \\  --data <path>    generated game table (default: data/firered.dat)
    \\  --save <path>    battery save (.sav) to attach; omit to start a new game
    \\  --server <path>  pokemcp binary (default: ./zig-out/bin/pokemcp)
    \\  --port <n>       port for the live screen (default: 8777)
    \\  --stream <dir>   where frames are written (default: /tmp/pokemcp_play)
    \\  --speed <mult>   emulation speed; 1 is realtime (default: 1)
    \\  --max-steps <n>  model turns before stopping (default: 300)
    \\  --no-open        do not open a browser
    \\  --help
    \\
    \\The goal, the model and the key can each come from a flag, the
    \\environment, or the --env file, in that order of precedence:
    \\
    \\  goal   --prompt / --prompt-file   POKEMCP_PROMPT
    \\  model  --model                    OPENROUTER_MODEL
    \\  key    --key                      OPENROUTER_API_KEY
    \\
;

const Options = struct {
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    key: ?[]const u8 = null,
    env_file: []const u8 = ".env",
    rom: []const u8 = "vendor/pokefirered/pokefirered.gba",
    data: []const u8 = "data/firered.dat",
    save: ?[]const u8 = null,
    model: ?[]const u8 = null,
    server: []const u8 = "./zig-out/bin/pokemcp",
    port: u16 = 8777,
    stream_dir: []const u8 = "/tmp/pokemcp_play",
    speed: []const u8 = "1",
    max_steps: u32 = 300,
    open: bool = true,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &stderr_buf);
    const err = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = struct {
            fn get(list: []const [:0]const u8, idx: *usize) ?[]const u8 {
                if (idx.* + 1 >= list.len) return null;
                idx.* += 1;
                return list[idx.*];
            }
        }.get;
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try err.writeAll(usage);
            try err.flush();
            return;
        } else if (std.mem.eql(u8, a, "--prompt") or std.mem.eql(u8, a, "-p")) {
            opts.prompt = next(args, &i);
        } else if (std.mem.eql(u8, a, "--prompt-file")) {
            opts.prompt_file = next(args, &i);
        } else if (std.mem.eql(u8, a, "--key")) {
            opts.key = next(args, &i);
        } else if (std.mem.eql(u8, a, "--env")) {
            opts.env_file = next(args, &i) orelse opts.env_file;
        } else if (std.mem.eql(u8, a, "--rom")) {
            opts.rom = next(args, &i) orelse opts.rom;
        } else if (std.mem.eql(u8, a, "--data")) {
            opts.data = next(args, &i) orelse opts.data;
        } else if (std.mem.eql(u8, a, "--save")) {
            opts.save = next(args, &i);
        } else if (std.mem.eql(u8, a, "--model")) {
            opts.model = next(args, &i);
        } else if (std.mem.eql(u8, a, "--server")) {
            opts.server = next(args, &i) orelse opts.server;
        } else if (std.mem.eql(u8, a, "--port")) {
            opts.port = std.fmt.parseInt(u16, next(args, &i) orelse "", 10) catch opts.port;
        } else if (std.mem.eql(u8, a, "--stream")) {
            opts.stream_dir = next(args, &i) orelse opts.stream_dir;
        } else if (std.mem.eql(u8, a, "--speed")) {
            opts.speed = next(args, &i) orelse opts.speed;
        } else if (std.mem.eql(u8, a, "--max-steps")) {
            opts.max_steps = std.fmt.parseInt(u32, next(args, &i) orelse "", 10) catch opts.max_steps;
        } else if (std.mem.eql(u8, a, "--no-open")) {
            opts.open = false;
        } else {
            try err.print("unknown argument: {s}\n\n{s}", .{ a, usage });
            try err.flush();
            std.process.exit(2);
        }
    }

    // Settings can come from a flag, the environment, or a KEY=VALUE file, in
    // that order, so a key never has to be pasted onto a command line.
    var dotenv = try DotEnv.load(gpa, io, opts.env_file);
    defer dotenv.deinit();
    const setting = struct {
        fn get(flag: ?[]const u8, env: *const std.process.Environ.Map, de: *const DotEnv, name: []const u8) ?[]const u8 {
            return flag orelse env.get(name) orelse de.get(name);
        }
    }.get;

    const prompt = blk: {
        if (opts.prompt_file) |path| {
            break :blk std.mem.trim(u8, try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 10)), " \n\r\t");
        }
        break :blk setting(opts.prompt, init.environ_map, &dotenv, "POKEMCP_PROMPT") orelse default_prompt;
    };

    const key = setting(opts.key, init.environ_map, &dotenv, "OPENROUTER_API_KEY") orelse {
        try err.print(
            "no API key. Pass --key, set OPENROUTER_API_KEY, or put it in {s}\n" ++
                "(get one at https://openrouter.ai/keys)\n",
            .{opts.env_file},
        );
        try err.flush();
        std.process.exit(2);
    };
    const model = setting(opts.model, init.environ_map, &dotenv, "OPENROUTER_MODEL") orelse default_model;

    // The live screen: write the viewer page now; the server that hands it out
    // is started once the game is connected, so its accept loop does not
    // contend with the handshake for the shared I/O.
    Io.Dir.cwd().createDirPath(io, opts.stream_dir) catch {};
    {
        const dir = try Io.Dir.cwd().openDir(io, opts.stream_dir, .{});
        try dir.writeFile(io, .{ .sub_path = "index.html", .data = stream.index_html });
    }

    // Launch the MCP server as a child and talk to it over its stdio.
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(gpa, &.{
        opts.server, "--rom", opts.rom, "--data", opts.data,
        "--stream",  opts.stream_dir, "--speed", opts.speed,
    });
    if (opts.save) |s| try argv.appendSlice(gpa, &.{ "--save", s });

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer _ = child.wait(io) catch {};

    const child_out_buf = try gpa.alloc(u8, 64 * 1024);
    var child_out = child.stdout.?.readerStreaming(io, child_out_buf);
    var mcp: Mcp = .{ .io = io, .stdin = child.stdin.?, .in = &child_out.interface };

    try err.writeAll("connecting to the game...\n");
    try err.flush();
    _ = try mcp.rpc(gpa, "initialize", "{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"pokemcp-play\",\"version\":\"0.1\"}}");
    const tools_json = try mcp.toolsAsFunctions(gpa);

    const screen = try Screen.start(gpa, io, opts.stream_dir, opts.port);
    const view = try std.fmt.allocPrint(gpa, "http://localhost:{d}", .{screen.port});
    try err.print("watch the screen at: {s}   (model {s})\n", .{ view, model });
    try err.flush();
    if (opts.open) openBrowser(io, gpa, view);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // The conversation, one JSON object string per message, kept for the whole
    // session so every request carries the full history.
    var session = std.heap.ArenaAllocator.init(gpa);
    defer session.deinit();
    const sa = session.allocator();
    var messages: std.ArrayList([]const u8) = .empty;
    try messages.append(sa, try message(sa, "system", system_prompt, null, null));
    try messages.append(sa, try message(sa, "user", prompt, null, null));

    var turn = std.heap.ArenaAllocator.init(gpa);
    defer turn.deinit();

    var step: u32 = 0;
    while (step < opts.max_steps) : (step += 1) {
        _ = turn.reset(.retain_capacity);
        const ta = turn.allocator();

        const body = try requestBody(ta, model, messages.items, tools_json);
        const reply = post(ta, &client, key, body) catch |e| {
            try err.print("[network error] {s}; retrying\n", .{@errorName(e)});
            try err.flush();
            Io.sleep(io, .fromSeconds(3), .awake) catch {};
            continue;
        };
        if (reply.status != .ok) {
            try err.print("[openrouter {d}] {s}\n", .{ @intFromEnum(reply.status), clip(reply.body, 400) });
            try err.flush();
            // A refusal (bad key, unknown model, no credit) will not fix itself.
            if (@intFromEnum(reply.status) < 500) {
                child.kill(io);
                screen.stop(io);
                std.process.exit(1);
            }
            Io.sleep(io, .fromSeconds(3), .awake) catch {};
            continue;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, ta, reply.body, .{}) catch |e| {
            try err.print("[bad reply] {s}: {s}\n", .{ @errorName(e), clip(reply.body, 200) });
            try err.flush();
            continue;
        };
        const msg = choiceMessage(parsed.value) orelse {
            try err.print("[no message] {s}\n", .{clip(reply.body, 200)});
            try err.flush();
            continue;
        };

        // Record the assistant turn verbatim: it may carry tool_calls the next
        // request must echo back.
        try messages.append(sa, try stringifyValue(sa, msg));

        if (objGet(msg, "content")) |c| switch (c) {
            .string => |t| if (t.len > 0) {
                try err.print("\n[{d}] {s}\n", .{ step, t });
                try err.flush();
            },
            else => {},
        };

        const calls = switch (objGet(msg, "tool_calls") orelse .null) {
            .array => |arr| arr.items,
            else => &.{},
        };
        if (calls.len == 0) {
            try messages.append(sa, try message(sa, "user",
                "Take the next action. Start with `observe` if unsure.", null, null));
            continue;
        }

        for (calls) |call| {
            const id = strField(call, "id") orelse "";
            const fnc = objGet(call, "function") orelse continue;
            const name = strField(fnc, "name") orelse continue;
            const arguments = strField(fnc, "arguments") orelse "{}";

            try err.print("    -> {s} {s}\n", .{ name, clip(arguments, 160) });
            try err.flush();

            const result = mcp.callTool(ta, name, arguments) catch |e|
                try std.fmt.allocPrint(ta, "tool call failed: {s}", .{@errorName(e)});
            try err.print("       {s}\n", .{clip(result, 200)});
            try err.flush();

            try messages.append(sa, try message(sa, "tool", result, id, name));
        }
    }

    try err.writeAll("\nreached the step limit; stopping.\n");
    try err.flush();
    child.kill(io);
    screen.stop(io);
}

// -- MCP client -------------------------------------------------------------

const Mcp = struct {
    io: Io,
    /// Written to directly rather than through a buffered writer: the request
    /// has to reach the child before we block reading its reply.
    stdin: Io.File,
    in: *Io.Reader,
    id: u32 = 0,

    /// Send one request and return the parsed reply, owned by `gpa`.
    fn rpc(self: *Mcp, gpa: Allocator, method: []const u8, params_json: []const u8) !std.json.Parsed(std.json.Value) {
        self.id += 1;
        const req = try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n",
            .{ self.id, method, params_json },
        );
        try self.stdin.writeStreamingAll(self.io, req);
        // Skip any line that is not the JSON reply we are waiting for. The
        // delimiter has to be tossed after each line: leaving it behind makes
        // the next take return an empty line forever.
        while (true) {
            const line = try self.in.takeDelimiterExclusive('\n');
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) {
                self.in.toss(1);
                continue;
            }
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch {
                self.in.toss(1);
                continue;
            };
            self.in.toss(1);
            if (idMatches(parsed.value, self.id)) return parsed;
            parsed.deinit();
        }
    }

    /// `tools/list`, rendered as an OpenAI-style `tools` array string.
    fn toolsAsFunctions(self: *Mcp, gpa: Allocator) ![]const u8 {
        const parsed = try self.rpc(gpa, "tools/list", "{}");
        defer parsed.deinit();
        const tools = switch (objGet(parsed.value, "result") orelse .null) {
            .object => |o| switch (o.get("tools") orelse .null) {
                .array => |arr| arr.items,
                else => return error.BadToolList,
            },
            else => return error.BadToolList,
        };
        var buf: Io.Writer.Allocating = .init(gpa);
        const w = &buf.writer;
        try w.writeByte('[');
        for (tools, 0..) |t, n| {
            if (n > 0) try w.writeByte(',');
            try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try writeJsonString(w, strField(t, "name") orelse "");
            try w.writeAll(",\"description\":");
            try writeJsonString(w, strField(t, "description") orelse "");
            try w.writeAll(",\"parameters\":");
            try stringifyInto(w, objGet(t, "inputSchema") orelse .{ .object = .{} });
            try w.writeAll("}}");
        }
        try w.writeByte(']');
        return buf.written();
    }

    /// Call a tool; return the text of its content, owned by `gpa`.
    fn callTool(self: *Mcp, gpa: Allocator, name: []const u8, arguments_json: []const u8) ![]const u8 {
        var params: Io.Writer.Allocating = .init(gpa);
        try params.writer.writeAll("{\"name\":");
        try writeJsonString(&params.writer, name);
        try params.writer.writeAll(",\"arguments\":");
        // arguments is already a JSON object string from the model.
        const args = std.mem.trim(u8, arguments_json, " \r\t\n");
        try params.writer.writeAll(if (args.len == 0) "{}" else args);
        try params.writer.writeByte('}');

        const parsed = try self.rpc(gpa, "tools/call", params.written());
        defer parsed.deinit();
        if (objGet(parsed.value, "error")) |e| return stringifyValue(gpa, e);
        const content = switch (objGet(parsed.value, "result") orelse .null) {
            .object => |o| switch (o.get("content") orelse .null) {
                .array => |arr| arr.items,
                else => return error.BadResult,
            },
            else => return error.BadResult,
        };
        var text: Io.Writer.Allocating = .init(gpa);
        for (content) |part| {
            if (strField(part, "type")) |ty| {
                if (std.mem.eql(u8, ty, "text")) {
                    if (strField(part, "text")) |t| try text.writer.writeAll(t);
                }
            }
        }
        return text.written();
    }
};

// -- OpenRouter -------------------------------------------------------------

const Reply = struct { status: std.http.Status, body: []const u8 };

fn post(gpa: Allocator, client: *std.http.Client, key: []const u8, body: []const u8) !Reply {
    const auth = try std.fmt.allocPrint(gpa, "Bearer {s}", .{key});
    var resp: Io.Writer.Allocating = .init(gpa);
    const res = try client.fetch(.{
        .location = .{ .url = openrouter_url },
        .method = .POST,
        .payload = body,
        .response_writer = &resp.writer,
        // Authorization and content-type are standard headers the client owns;
        // they have to be overridden here rather than added as extras, or they
        // are dropped and the request arrives unauthenticated.
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            .{ .name = "http-referer", .value = "https://github.com/vdmkenny/pokemcp" },
            .{ .name = "x-title", .value = "pokemcp" },
        },
    });
    return .{ .status = res.status, .body = resp.written() };
}

fn requestBody(gpa: Allocator, model: []const u8, messages: []const []const u8, tools_json: []const u8) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(gpa);
    const w = &buf.writer;
    try w.writeAll("{\"model\":");
    try writeJsonString(w, model);
    try w.writeAll(",\"messages\":[");
    for (messages, 0..) |m, n| {
        if (n > 0) try w.writeByte(',');
        try w.writeAll(m);
    }
    try w.writeAll("],\"tools\":");
    try w.writeAll(tools_json);
    try w.writeAll(",\"tool_choice\":\"auto\"}");
    return buf.written();
}

/// Build one chat message object as a JSON string. `tool_call_id`/`name` are for
/// tool-result messages.
fn message(gpa: Allocator, role: []const u8, content: []const u8, tool_call_id: ?[]const u8, name: ?[]const u8) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(gpa);
    const w = &buf.writer;
    try w.writeAll("{\"role\":");
    try writeJsonString(w, role);
    try w.writeAll(",\"content\":");
    try writeJsonString(w, content);
    if (tool_call_id) |id| {
        try w.writeAll(",\"tool_call_id\":");
        try writeJsonString(w, id);
    }
    if (name) |n| {
        try w.writeAll(",\"name\":");
        try writeJsonString(w, n);
    }
    try w.writeByte('}');
    return buf.written();
}

// -- the live screen --------------------------------------------------------

/// A tiny HTTP server on its own thread, serving the stream directory so a
/// human can watch. It only needs to hand back two files.
const Screen = struct {
    thread: std.Thread,
    io: Io,
    server: Io.net.Server,
    dir: []const u8,
    port: u16,
    gpa: Allocator,
    stop_flag: std.atomic.Value(bool) = .init(false),

    fn start(gpa: Allocator, io: Io, dir: []const u8, want_port: u16) !*Screen {
        const self = try gpa.create(Screen);
        // Take the first free port at or after the requested one.
        var port = want_port;
        const server = while (port < want_port + 16) : (port += 1) {
            var addr = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
            break Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch continue;
        } else return error.NoFreePort;
        self.* = .{ .thread = undefined, .io = io, .server = server, .dir = dir, .port = port, .gpa = gpa };
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
        return self;
    }

    fn stop(self: *Screen, io: Io) void {
        self.stop_flag.store(true, .release);
        self.server.deinit(io);
    }

    fn serveLoop(self: *Screen) void {
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.server.accept(self.io) catch return;
            self.handle(conn) catch {};
        }
    }

    fn handle(self: *Screen, conn_in: Io.net.Stream) !void {
        var conn = conn_in;
        defer conn.close(self.io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var r = conn.reader(self.io, &rbuf);
        var w = conn.writer(self.io, &wbuf);

        // Only the request line matters: "GET /path HTTP/1.1".
        const line = r.interface.takeDelimiterExclusive('\n') catch return;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next(); // method
        const path = it.next() orelse "/";

        // Everything is cache-busted with a query string, which is not part of
        // the file name.
        const no_query = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
        const sub = if (no_query.len <= 1) "index.html" else no_query[1..];
        const ctype = if (std.mem.endsWith(u8, sub, ".html"))
            "text/html; charset=utf-8"
        else if (std.mem.endsWith(u8, sub, ".bmp"))
            "image/bmp"
        else if (std.mem.endsWith(u8, sub, ".wav"))
            "audio/wav"
        else if (std.mem.endsWith(u8, sub, ".json"))
            "application/json"
        else
            "application/octet-stream";

        const dir = Io.Dir.cwd().openDir(self.io, self.dir, .{}) catch return sendStatus(&w.interface, "404 Not Found");
        const data = dir.readFileAlloc(self.io, sub, self.gpa, .limited(4 << 20)) catch
            return sendStatus(&w.interface, "404 Not Found");
        defer self.gpa.free(data);

        try w.interface.print(
            "HTTP/1.0 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
            .{ ctype, data.len },
        );
        try w.interface.writeAll(data);
        try w.interface.flush();
    }
};

fn sendStatus(w: *Io.Writer, status: []const u8) void {
    w.print("HTTP/1.0 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch {};
    w.flush() catch {};
}

// -- settings file ----------------------------------------------------------

/// A file of `KEY=VALUE` lines, so the API key and the model can be set once
/// and kept out of shell history. A missing file is simply empty.
const DotEnv = struct {
    map: std.StringHashMap([]const u8),
    arena: std.heap.ArenaAllocator,

    fn load(gpa: Allocator, io: Io, path: []const u8) !DotEnv {
        var self: DotEnv = .{
            .map = std.StringHashMap([]const u8).init(gpa),
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, self.arena.allocator(), .limited(64 << 10)) catch
            return self;
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = std.mem.trim(u8, line[0..eq], " \t");
            var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0])
                value = value[1 .. value.len - 1];
            if (name.len != 0) try self.map.put(name, value);
        }
        return self;
    }

    fn get(self: *const DotEnv, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    fn deinit(self: *DotEnv) void {
        self.map.deinit();
        self.arena.deinit();
    }
};

// -- small helpers ----------------------------------------------------------

fn openBrowser(io: Io, gpa: Allocator, url: []const u8) void {
    const opener = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
    var child = std.process.spawn(io, .{
        .argv = &.{ opener, url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
    _ = gpa;
}

fn objGet(v: std.json.Value, field: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(field),
        else => null,
    };
}

fn strField(v: std.json.Value, field: []const u8) ?[]const u8 {
    return switch (objGet(v, field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

fn idMatches(v: std.json.Value, id: u32) bool {
    return switch (objGet(v, "id") orelse .null) {
        .integer => |n| n == id,
        else => false,
    };
}

fn choiceMessage(v: std.json.Value) ?std.json.Value {
    const choices = switch (objGet(v, "choices") orelse .null) {
        .array => |a| a.items,
        else => return null,
    };
    if (choices.len == 0) return null;
    return objGet(choices[0], "message");
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{} };
    try js.write(s);
}

fn stringifyInto(w: *Io.Writer, v: std.json.Value) !void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{} };
    try js.write(v);
}

fn stringifyValue(gpa: Allocator, v: std.json.Value) ![]const u8 {
    var buf: Io.Writer.Allocating = .init(gpa);
    try stringifyInto(&buf.writer, v);
    return buf.written();
}

fn clip(s: []const u8, n: usize) []const u8 {
    var out = s;
    if (std.mem.indexOfScalar(u8, out, '\n')) |_| {
        // collapse to first line for the terminal log
    }
    if (out.len > n) out = out[0..n];
    return out;
}
