//! The emulator boundary.
//!
//! This is the only file that talks to libmgba's C API. `struct mCore` is a
//! vtable of function pointers whose layout depends on the flags the library
//! was built with, which is why build.zig translates these headers with
//! exactly the same defines. Everything above this file sees plain Zig types.

const std = @import("std");
const Allocator = std.mem.Allocator;
const stream_mod = @import("stream.zig");

pub const c = @cImport({
    @cInclude("mgba/core/core.h");
    @cInclude("mgba/core/config.h");
    @cInclude("mgba/core/log.h");
    @cInclude("mgba-util/vfs.h");
    @cInclude("mgba-util/audio-buffer.h");
});

pub const Error = error{
    NoCoreForRom,
    CoreInitFailed,
    RomLoadFailed,
    SaveFileFailed,
    SaveStateFailed,
    LoadStateFailed,
    NoFramebuffer,
};

/// Buttons as the hardware sees them: one bit each, in GBA keypad order.
/// Laid out to `@bitCast` straight onto the mask mGBA's `setKeys` wants, so
/// there is no lookup table between "press A" and the register value.
pub const Buttons = packed struct(u10) {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    r: bool = false,
    l: bool = false,

    pub const none: Buttons = .{};

    pub fn mask(self: Buttons) u32 {
        return @as(u10, @bitCast(self));
    }

    pub fn eql(self: Buttons, other: Buttons) bool {
        return self.mask() == other.mask();
    }

    pub fn unionWith(self: Buttons, other: Buttons) Buttons {
        return @bitCast(@as(u10, @bitCast(self)) | @as(u10, @bitCast(other)));
    }

    pub fn isEmpty(self: Buttons) bool {
        return self.mask() == 0;
    }

    /// Parse one button name. Accepts the field names above.
    pub fn parse(name: []const u8) ?Buttons {
        var buf: [8]u8 = undefined;
        if (name.len == 0 or name.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, name);
        var out: Buttons = .{};
        inline for (@typeInfo(Buttons).@"struct".fields) |f| {
            if (std.mem.eql(u8, lower, f.name)) {
                @field(out, f.name) = true;
                return out;
            }
        }
        return null;
    }

    /// Parse a list of button names into one combination.
    pub fn parseAll(names: []const []const u8) ?Buttons {
        var out: Buttons = .{};
        for (names) |n| out = out.unionWith(parse(n) orelse return null);
        return out;
    }

    pub fn format(self: Buttons, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        inline for (@typeInfo(Buttons).@"struct".fields) |f| {
            if (@field(self, f.name)) {
                if (!first) try writer.writeByte('+');
                try writer.writeAll(f.name);
                first = false;
            }
        }
        if (first) try writer.writeAll("none");
    }
};

/// mGBA logs BIOS calls, DMA transfers and savedata chatter through a global
/// logger. For an MCP server stdout carries the protocol, so anything written
/// there would corrupt it: swallow everything by default.
var quiet_logger: c.struct_mLogger = .{ .log = logNothing, .filter = null };

fn logNothing(
    logger: [*c]c.struct_mLogger,
    category: c_int,
    level: c.enum_mLogLevel,
    format: [*c]const u8,
    args: c.va_list,
) callconv(.c) void {
    _ = .{ logger, category, level, format, args };
}

/// A small spin lock, because `std.Io.Mutex` wants an `Io` handed to every
/// lock call and that would have to be threaded through every memory read.
/// The emulation thread holds this for the length of one frame, well under a
/// millisecond, and readers hardly ever collide with it.
const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(l: *Lock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(l: *Lock) void {
        l.held.store(false, .release);
    }
};

pub const screen_width = 240;
pub const screen_height = 160;

pub const Emulator = struct {
    core: *c.struct_mCore,
    video: []align(@alignOf(u32)) u8,
    gpa: Allocator,

    /// Optional live view for a human watching. Set by `startStreaming`.
    /// Purely a debugging aid: nothing above this file reads pixels.
    stream: ?Stream = null,

    /// Optional sound capture for that same viewer. Set by `startAudio`.
    audio: ?Audio = null,

    /// Optional speed limit. Without one the emulator runs as fast as it can,
    /// which is about forty times real time and unwatchable.
    pace: ?Pace = null,

    /// Guards the core. Held for the length of one frame by the thread that
    /// is running the game, and by anyone reading or writing memory.
    lock: Lock = .{},

    /// Set when the game is running on its own thread. The point is that the
    /// world does not stop between an agent's decisions: NPCs keep walking,
    /// animations keep playing, and anyone watching sees a game rather than a
    /// slideshow. Buttons become something held for a while and then let go,
    /// which is what a controller actually does.
    freewheel: ?*Freewheel = null,

    pub const Freewheel = struct {
        thread: std.Thread,
        /// Buttons the pad is holding right now.
        held: Buttons = .none,
        /// Frame at which to let go of them; 0 means they are not held.
        release_at: u32 = 0,
        stop: bool = false,
    };

    pub const Pace = struct {
        io: std.Io,
        per_frame: std.Io.Duration,
        /// When the next frame is due. Kept as a deadline rather than a sleep
        /// per frame so the time spent emulating and encoding is absorbed
        /// instead of added on top.
        due: ?std.Io.Timestamp = null,
    };

    /// Stereo, which is what the hardware produces and the page expects.
    const channels: u16 = 2;

    /// How many chunks stay on disk. Enough for a viewer to be a little behind,
    /// few enough that the directory does not grow without bound.
    const keep_chunks: u32 = 24;

    pub const Audio = struct {
        io: std.Io,
        dir: std.Io.Dir,
        rate: u32,
        /// Interleaved stereo, waiting to reach a chunk's worth.
        pending: std.ArrayList(i16) = .empty,
        /// Frames per chunk.
        per_chunk: usize,
        chunk: u32 = 0,
    };

    pub const Stream = struct {
        io: std.Io,
        dir: std.Io.Dir,
        /// Write one frame in this many, so a fast-forwarding agent does not
        /// spend all its time encoding images.
        every: u32,
        counter: u32 = 0,
    };

    pub fn init(gpa: Allocator, rom_path: []const u8) !Emulator {
        c.mLogSetDefaultLogger(&quiet_logger);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{rom_path}) catch
            return error.RomLoadFailed;

        const core = c.mCoreFind(path_z.ptr) orelse return error.NoCoreForRom;
        errdefer core.*.deinit.?(core);

        if (!core.*.init.?(core)) return error.CoreInitFailed;
        c.mCoreInitConfig(core, null);

        // Headless, but the core still renders; it needs somewhere to draw.
        var w: c_uint = screen_width;
        var h: c_uint = screen_height;
        core.*.baseVideoSize.?(core, &w, &h);
        const video = try gpa.alignedAlloc(u8, .of(u32), @as(usize, w) * h * 4);
        errdefer gpa.free(video);
        @memset(video, 0);
        core.*.setVideoBuffer.?(core, @ptrCast(video.ptr), w);

        // No BIOS file on disk: use the HLE BIOS and skip the boot animation
        // so a reset lands somewhere deterministic.
        c.mCoreConfigSetIntValue(&core.*.config, "skipBios", 1);
        c.mCoreConfigSetIntValue(&core.*.config, "useBios", 0);
        // Loading the config copies the volume out of `core.opts` and over the
        // audio's own default, so a zero there mutes the game outright. The
        // values have to be mapped into `opts` first; setting them on the
        // config alone is not enough. 0x100 is GBA_AUDIO_VOLUME_MAX.
        c.mCoreConfigSetIntValue(&core.*.config, "volume", 0x100);
        c.mCoreConfigSetIntValue(&core.*.config, "mute", 0);
        c.mCoreConfigMap(&core.*.config, &core.*.opts);
        core.*.loadConfig.?(core, &core.*.config);

        if (!c.mCoreLoadFile(core, path_z.ptr)) return error.RomLoadFailed;
        core.*.reset.?(core);

        return .{ .core = core, .video = video, .gpa = gpa };
    }

    pub fn deinit(self: *Emulator) void {
        if (self.audio) |*au| au.pending.deinit(self.gpa);
        self.core.deinit.?(self.core);
        self.gpa.free(self.video);
        self.* = undefined;
    }

    /// Attach a battery save (.sav). Must come after init.
    pub fn loadSave(self: *Emulator, path: []const u8) !void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.SaveFileFailed;
        const vf = c.VFileOpen(path_z.ptr, c.O_CREAT | c.O_RDWR) orelse return error.SaveFileFailed;
        if (!self.core.loadSave.?(self.core, vf)) return error.SaveFileFailed;
    }

    pub fn reset(self: *Emulator) void {
        self.core.reset.?(self.core);
    }

    /// Run at `multiple` times real speed; 1.0 is a Game Boy Advance's own
    /// 59.7fps. Pass null to remove the limit.
    pub fn setSpeed(self: *Emulator, io: std.Io, multiple: ?f64) void {
        const m = multiple orelse {
            self.pace = null;
            return;
        };
        if (m <= 0) {
            self.pace = null;
            return;
        }
        // The GBA runs at 59.7275 frames per second.
        const ns: i96 = @intFromFloat(1_000_000_000.0 / (59.7275 * m));
        self.pace = .{ .io = io, .per_frame = .fromNanoseconds(ns) };
    }

    fn waitForFrameDeadline(self: *Emulator) void {
        const p = &(self.pace orelse return);
        const now = std.Io.Timestamp.now(p.io, .awake);
        const due = p.due orelse now;
        const remaining = now.durationTo(due);
        if (remaining.nanoseconds > 0) {
            std.Io.sleep(p.io, remaining, .awake) catch {};
        }
        // If we fell behind, start counting again from now rather than trying
        // to catch up in a burst.
        const base = if (remaining.nanoseconds > 0) due else now;
        p.due = base.addDuration(p.per_frame);
    }

    /// Let `n` frames go by.
    ///
    /// When the game has a thread of its own this waits for it to get there
    /// rather than stepping it, so callers never stall the world.
    pub fn runFrames(self: *Emulator, n: u32) void {
        if (self.freewheel != null) {
            const target = self.frameCounter() +% n;
            while (true) {
                const now = self.frameCounter();
                if (now -% target < 0x8000_0000) return;
                std.Thread.yield() catch {};
                if (self.pace) |p| std.Io.sleep(p.io, .fromMilliseconds(2), .awake) catch {};
            }
        }
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            self.lock.lock();
            self.core.runFrame.?(self.core);
            self.streamTick();
            self.lock.unlock();
            self.waitForFrameDeadline();
        }
    }

    /// Start dropping frames into `dir` for a human to watch.
    pub fn startStreaming(self: *Emulator, io: std.Io, dir: std.Io.Dir, every: u32) void {
        self.stream = .{ .io = io, .dir = dir, .every = @max(every, 1) };
    }

    /// Also send the sound there, as a run of short WAV chunks the page can
    /// stitch back together. The core keeps its own audio buffer; nothing has
    /// been draining it, so this both captures the sound and stops it filling.
    pub fn startAudio(self: *Emulator, io: std.Io, dir: std.Io.Dir) void {
        self.lock.lock();
        defer self.lock.unlock();
        const rate = self.core.audioSampleRate.?(self.core);
        // Room for well over a frame's worth, so nothing is lost between drains.
        self.core.setAudioBufferSize.?(self.core, 4096);
        self.audio = .{
            .io = io,
            .dir = dir,
            .rate = rate,
            // A fifth of a second per chunk: short enough to stay close to the
            // picture, long enough that the page is not fetching constantly.
            .per_chunk = rate / 5,
        };
    }

    /// Take whatever the core has produced and, once there is a chunk's worth,
    /// write it out. Called once per frame with the lock already held.
    fn audioTick(self: *Emulator) !void {
        const au = &(self.audio orelse return);
        const buffer = self.core.getAudioBuffer.?(self.core);

        // The rate is not fixed: it follows the sound hardware's resolution,
        // which a game sets for itself after boot. FireRed doubles it. Reading
        // it fresh keeps each chunk honest about how fast to play; caching the
        // value from startup makes everything come out at twice the speed.
        const rate = self.core.audioSampleRate.?(self.core);
        if (rate != 0) {
            au.rate = rate;
            au.per_chunk = @max(rate / 5, 1);
        }

        var scratch: [2048 * channels]i16 = undefined;
        while (true) {
            const available = c.mAudioBufferAvailable(buffer);
            if (available == 0) break;
            const want = @min(available, scratch.len / channels);
            const got = c.mAudioBufferRead(buffer, &scratch, want);
            if (got == 0) break;
            try au.pending.appendSlice(self.gpa, scratch[0 .. got * channels]);
        }

        if (au.pending.items.len < au.per_chunk * channels) return;

        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        try stream_mod.writeWav(&body.writer, au.pending.items, au.rate, channels);
        au.pending.clearRetainingCapacity();

        var name: [32]u8 = undefined;
        const chunk = try std.fmt.bufPrint(&name, "a{d}.wav", .{au.chunk});
        try au.dir.writeFile(au.io, .{ .sub_path = "a.tmp", .data = body.written() });
        try au.dir.rename("a.tmp", au.dir, chunk, au.io);

        // Say what exists, so the page knows what to fetch and can tell when it
        // has fallen behind.
        const first = au.chunk -| keep_chunks;
        var manifest: [96]u8 = undefined;
        const json = try std.fmt.bufPrint(
            &manifest,
            "{{\"rate\":{d},\"channels\":{d},\"first\":{d},\"latest\":{d}}}",
            .{ au.rate, channels, first, au.chunk },
        );
        try au.dir.writeFile(au.io, .{ .sub_path = "m.tmp", .data = json });
        try au.dir.rename("m.tmp", au.dir, "audio.json", au.io);

        // Drop the chunk that just fell out of the window.
        if (au.chunk >= keep_chunks) {
            var old: [32]u8 = undefined;
            const gone = try std.fmt.bufPrint(&old, "a{d}.wav", .{au.chunk - keep_chunks});
            au.dir.deleteFile(au.io, gone) catch {};
        }
        au.chunk += 1;
    }

    fn writeStreamFrame(self: *Emulator) !void {
        const st = self.stream orelse return;
        var pixels: [screen_width * screen_height * 4]u8 = undefined;
        try self.screenshotRgba(&pixels);

        var buf: [screen_width * screen_height * 3 + 64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try stream_mod.writeBmp(&w, &pixels, screen_width, screen_height);

        // Write then rename, so a reader never gets half a frame.
        try st.dir.writeFile(st.io, .{ .sub_path = "frame.tmp", .data = w.buffered() });
        try st.dir.rename("frame.tmp", st.dir, "frame.bmp", st.io);
    }

    pub fn frame(self: *Emulator) u32 {
        return self.frameCounter();
    }

    /// Press buttons. While the game runs on its own thread this records what
    /// the pad is holding; the thread applies it every frame until released.
    pub fn setButtons(self: *Emulator, buttons: Buttons) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.freewheel) |fw| {
            fw.held = buttons;
            fw.release_at = 0;
        }
        self.core.setKeys.?(self.core, buttons.mask());
    }

    /// Hold buttons for a number of frames, then let go, without blocking.
    pub fn holdButtons(self: *Emulator, buttons: Buttons, frames: u32) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.core.setKeys.?(self.core, buttons.mask());
        if (self.freewheel) |fw| {
            fw.held = buttons;
            fw.release_at = self.core.frameCounter.?(self.core) +% @max(frames, 1);
        }
    }

    /// Hand the game to a thread of its own, so it keeps running between
    /// calls. Everything else goes through the lock from then on.
    pub fn startFreewheel(self: *Emulator, gpa: Allocator) !void {
        if (self.freewheel != null) return;
        const fw = try gpa.create(Freewheel);
        fw.* = .{ .thread = undefined };
        self.freewheel = fw;
        fw.thread = try std.Thread.spawn(.{}, freewheelLoop, .{self});
    }

    pub fn stopFreewheel(self: *Emulator, gpa: Allocator) void {
        const fw = self.freewheel orelse return;
        self.lock.lock();
        fw.stop = true;
        self.lock.unlock();
        fw.thread.join();
        self.freewheel = null;
        gpa.destroy(fw);
    }

    fn freewheelLoop(self: *Emulator) void {
        while (true) {
            self.lock.lock();
            const fw = self.freewheel orelse {
                self.lock.unlock();
                return;
            };
            if (fw.stop) {
                self.lock.unlock();
                return;
            }
            const frame_now = self.core.frameCounter.?(self.core);
            // Let go of anything whose hold has expired, so a press behaves
            // like a press and not a stuck key.
            if (fw.release_at != 0 and frame_now >= fw.release_at) {
                fw.held = .none;
                fw.release_at = 0;
            }
            self.core.setKeys.?(self.core, fw.held.mask());
            self.core.runFrame.?(self.core);
            self.streamTick();
            self.lock.unlock();

            self.waitForFrameDeadline();
        }
    }

    fn streamTick(self: *Emulator) void {
        // Sound first: it has to be drained every frame, whatever the picture
        // is doing, or the core's buffer overruns and it comes out broken.
        self.audioTick() catch {};

        const st = &(self.stream orelse return);
        st.counter += 1;
        if (st.counter >= st.every) {
            st.counter = 0;
            self.writeStreamFrame() catch {};
        }
    }

    pub fn frameCounter(self: *Emulator) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.core.frameCounter.?(self.core);
    }

    // -- memory --------------------------------------------------------------

    // The public accessors take the lock; the raw ones assume the caller
    // already holds it. Keeping them apart is what stops a bulk read from
    // trying to lock once per byte.

    pub fn read8(self: *Emulator, addr: u32) u8 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.rawRead8(addr);
    }

    pub fn read16(self: *Emulator, addr: u32) u16 {
        self.lock.lock();
        defer self.lock.unlock();
        return @truncate(self.core.busRead16.?(self.core, addr));
    }

    pub fn read32(self: *Emulator, addr: u32) u32 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.rawRead32(addr);
    }

    fn rawRead8(self: *Emulator, addr: u32) u8 {
        return @truncate(self.core.busRead8.?(self.core, addr));
    }

    fn rawRead32(self: *Emulator, addr: u32) u32 {
        return self.core.busRead32.?(self.core, addr);
    }

    pub fn write8(self: *Emulator, addr: u32, value: u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.core.busWrite8.?(self.core, addr, value);
    }

    pub fn write16(self: *Emulator, addr: u32, value: u16) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.core.busWrite16.?(self.core, addr, value);
    }

    pub fn write32(self: *Emulator, addr: u32, value: u32) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.core.busWrite32.?(self.core, addr, value);
    }

    /// Bulk read into a caller-owned buffer. Decoding a save block means
    /// thousands of bytes, and a call per byte is what makes naive harnesses
    /// slow, so read words wherever alignment allows.
    pub fn readBytes(self: *Emulator, addr: u32, out: []u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        var i: usize = 0;
        while (i < out.len and (addr +% @as(u32, @intCast(i))) % 4 != 0) : (i += 1) {
            out[i] = self.rawRead8(addr +% @as(u32, @intCast(i)));
        }
        while (i + 4 <= out.len) : (i += 4) {
            std.mem.writeInt(u32, out[i..][0..4], self.rawRead32(addr +% @as(u32, @intCast(i))), .little);
        }
        while (i < out.len) : (i += 1) {
            out[i] = self.rawRead8(addr +% @as(u32, @intCast(i)));
        }
    }

    pub fn writeBytes(self: *Emulator, addr: u32, data: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (data, 0..) |b, i| self.core.busWrite8.?(self.core, addr +% @as(u32, @intCast(i)), b);
    }

    /// Read a game structure straight into its Zig declaration.
    ///
    /// The structs in `games/*` mirror the disassembly's layout exactly, so
    /// this replaces every hand-written offset with a field access the
    /// compiler checks. Both the GBA and every host we build for are
    /// little-endian, so the bytes need no swapping.
    pub fn readStruct(self: *Emulator, comptime T: type, addr: u32) T {
        var value: T = undefined;
        self.readBytes(addr, std.mem.asBytes(&value));
        return value;
    }

    // -- savestates ----------------------------------------------------------

    pub fn saveState(self: *Emulator, gpa: Allocator) ![]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        const size = self.core.stateSize.?(self.core);
        const buf = try gpa.alloc(u8, size);
        errdefer gpa.free(buf);
        if (!self.core.saveState.?(self.core, buf.ptr)) return error.SaveStateFailed;
        return buf;
    }

    pub fn loadState(self: *Emulator, blob: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        if (!self.core.loadState.?(self.core, blob.ptr)) return error.LoadStateFailed;
    }

    // -- pixels (for humans; the agent never needs these) --------------------

    pub fn screenshotRgba(self: *Emulator, out: *[screen_width * screen_height * 4]u8) !void {
        var pixels: ?*const anyopaque = null;
        var stride: usize = 0;
        self.core.getPixels.?(self.core, &pixels, &stride);
        const src: [*]const u32 = @ptrCast(@alignCast(pixels orelse return error.NoFramebuffer));
        for (0..screen_height) |y| {
            for (0..screen_width) |x| {
                const px = src[y * stride + x];
                const i = (y * screen_width + x) * 4;
                // mGBA's 32-bit pixels are 0xAABBGGRR: red is the low byte,
                // see M_COLOR_RED in mgba-util/image.h. Reading it the other
                // way round swaps red and blue, which turns water orange.
                out[i + 0] = @truncate(px);
                out[i + 1] = @truncate(px >> 8);
                out[i + 2] = @truncate(px >> 16);
                out[i + 3] = 0xFF;
            }
        }
    }
};

test "buttons map onto the hardware bitmask" {
    try std.testing.expectEqual(@as(u32, 1 << 0), (Buttons{ .a = true }).mask());
    try std.testing.expectEqual(@as(u32, 1 << 3), (Buttons{ .start = true }).mask());
    try std.testing.expectEqual(@as(u32, 1 << 6), (Buttons{ .up = true }).mask());
    try std.testing.expectEqual(
        @as(u32, (1 << 0) | (1 << 7)),
        (Buttons{ .a = true, .down = true }).mask(),
    );
}

test "button names parse, unknown ones do not" {
    try std.testing.expect(Buttons.parse("A").?.a);
    try std.testing.expect(Buttons.parse("start").?.start);
    try std.testing.expect(Buttons.parse("nope") == null);
    const combo = Buttons.parseAll(&.{ "a", "up" }).?;
    try std.testing.expect(combo.a and combo.up and !combo.b);
}
