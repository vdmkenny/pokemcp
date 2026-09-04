//! The emulator boundary.
//!
//! This is the only file that talks to libmgba's C API. `struct mCore` is a
//! vtable of function pointers whose layout depends on the flags the library
//! was built with, which is why build.zig translates these headers with
//! exactly the same defines. Everything above this file sees plain Zig types.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @cImport({
    @cInclude("mgba/core/core.h");
    @cInclude("mgba/core/config.h");
    @cInclude("mgba/core/log.h");
    @cInclude("mgba-util/vfs.h");
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

pub const screen_width = 240;
pub const screen_height = 160;

pub const Emulator = struct {
    core: *c.struct_mCore,
    video: []align(@alignOf(u32)) u8,
    gpa: Allocator,

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
        core.*.loadConfig.?(core, &core.*.config);

        if (!c.mCoreLoadFile(core, path_z.ptr)) return error.RomLoadFailed;
        core.*.reset.?(core);

        return .{ .core = core, .video = video, .gpa = gpa };
    }

    pub fn deinit(self: *Emulator) void {
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

    pub fn runFrames(self: *Emulator, n: u32) void {
        var i: u32 = 0;
        while (i < n) : (i += 1) self.core.runFrame.?(self.core);
    }

    pub fn frame(self: *Emulator) u32 {
        return self.core.frameCounter.?(self.core);
    }

    pub fn setButtons(self: *Emulator, buttons: Buttons) void {
        self.core.setKeys.?(self.core, buttons.mask());
    }

    // -- memory --------------------------------------------------------------

    pub fn read8(self: *Emulator, addr: u32) u8 {
        return @truncate(self.core.busRead8.?(self.core, addr));
    }

    pub fn read16(self: *Emulator, addr: u32) u16 {
        return @truncate(self.core.busRead16.?(self.core, addr));
    }

    pub fn read32(self: *Emulator, addr: u32) u32 {
        return self.core.busRead32.?(self.core, addr);
    }

    pub fn write8(self: *Emulator, addr: u32, value: u8) void {
        self.core.busWrite8.?(self.core, addr, value);
    }

    pub fn write16(self: *Emulator, addr: u32, value: u16) void {
        self.core.busWrite16.?(self.core, addr, value);
    }

    pub fn write32(self: *Emulator, addr: u32, value: u32) void {
        self.core.busWrite32.?(self.core, addr, value);
    }

    /// Bulk read into a caller-owned buffer. Decoding a save block means
    /// thousands of bytes, and a call per byte is what makes naive harnesses
    /// slow, so read words wherever alignment allows.
    pub fn readBytes(self: *Emulator, addr: u32, out: []u8) void {
        var i: usize = 0;
        while (i < out.len and (addr +% @as(u32, @intCast(i))) % 4 != 0) : (i += 1) {
            out[i] = self.read8(addr +% @as(u32, @intCast(i)));
        }
        while (i + 4 <= out.len) : (i += 4) {
            std.mem.writeInt(u32, out[i..][0..4], self.read32(addr +% @as(u32, @intCast(i))), .little);
        }
        while (i < out.len) : (i += 1) {
            out[i] = self.read8(addr +% @as(u32, @intCast(i)));
        }
    }

    pub fn writeBytes(self: *Emulator, addr: u32, data: []const u8) void {
        for (data, 0..) |b, i| self.write8(addr +% @as(u32, @intCast(i)), b);
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
        const size = self.core.stateSize.?(self.core);
        const buf = try gpa.alloc(u8, size);
        errdefer gpa.free(buf);
        if (!self.core.saveState.?(self.core, buf.ptr)) return error.SaveStateFailed;
        return buf;
    }

    pub fn loadState(self: *Emulator, blob: []const u8) !void {
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
                out[i + 0] = @truncate(px >> 16);
                out[i + 1] = @truncate(px >> 8);
                out[i + 2] = @truncate(px);
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
