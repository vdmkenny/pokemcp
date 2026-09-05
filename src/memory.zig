//! What the player remembers of where they have been.
//!
//! The viewport is a keyhole: fifteen tiles by ten, and the moment you step
//! away it is gone. A person does not play that way -- you remember the street
//! you just walked down, and you know you have already tried that corner. An
//! agent given only the current view has to rebuild the map from its own
//! transcript every turn, and a small one simply cannot, so it paces back and
//! forth over ground it has already covered.
//!
//! This records the tiles that have actually been looked at, and nothing else.
//! It is a memory, not a map: it can only ever hand back something the player
//! has already seen with their own eyes, so it gives away no more than being
//! there did.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Marks a tile the player has stood on, so retreading is visible.
pub const trail: u8 = ',';
/// A tile that has never been in view.
pub const unseen: u8 = ' ';

pub const Seen = struct {
    gpa: Allocator,
    maps: std.AutoHashMapUnmanaged(u32, Grid) = .empty,

    pub const Grid = struct {
        w: u16,
        h: u16,
        /// Row-major, `unseen` until looked at.
        cells: []u8,
    };

    pub fn deinit(self: *Seen) void {
        var it = self.maps.valueIterator();
        while (it.next()) |g| self.gpa.free(g.cells);
        self.maps.deinit(self.gpa);
    }

    /// Maps are identified the way the game identifies them.
    pub fn key(group: i8, num: i8) u32 {
        const g: u32 = @as(u8, @bitCast(group));
        const n: u32 = @as(u8, @bitCast(num));
        return (g << 8) | n;
    }

    fn grid(self: *Seen, k: u32, w: u16, h: u16) !?*Grid {
        if (w == 0 or h == 0 or w > 512 or h > 512) return null;
        const found = try self.maps.getOrPut(self.gpa, k);
        if (!found.found_existing) {
            const cells = try self.gpa.alloc(u8, @as(usize, w) * h);
            @memset(cells, unseen);
            found.value_ptr.* = .{ .w = w, .h = h, .cells = cells };
        }
        return found.value_ptr;
    }

    /// Remember one tile. Ground already walked stays marked as walked.
    pub fn note(self: *Seen, k: u32, w: u16, h: u16, x: i32, y: i32, glyph: u8) !void {
        const g = (try self.grid(k, w, h)) orelse return;
        if (x < 0 or y < 0 or x >= g.w or y >= g.h) return;
        const i = @as(usize, @intCast(y)) * g.w + @as(usize, @intCast(x));
        if (g.cells[i] == trail) return;
        g.cells[i] = glyph;
    }

    /// Remember standing somewhere.
    pub fn noteVisit(self: *Seen, k: u32, w: u16, h: u16, x: i32, y: i32) !void {
        const g = (try self.grid(k, w, h)) orelse return;
        if (x < 0 or y < 0 or x >= g.w or y >= g.h) return;
        g.cells[@as(usize, @intCast(y)) * g.w + @as(usize, @intCast(x))] = trail;
    }

    /// Draw what is remembered around a point, `radius_x` by `radius_y` either
    /// side. Returns null when there is nothing worth showing yet.
    pub fn render(
        self: *Seen,
        gpa: Allocator,
        k: u32,
        cx: i32,
        cy: i32,
        radius_x: i32,
        radius_y: i32,
    ) !?[]const u8 {
        const g = self.maps.getPtr(k) orelse return null;

        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;

        const x0 = @max(cx - radius_x, 0);
        const x1 = @min(cx + radius_x, @as(i32, g.w) - 1);
        const y0 = @max(cy - radius_y, 0);
        const y1 = @min(cy + radius_y, @as(i32, g.h) - 1);
        if (x1 < x0 or y1 < y0) return null;

        try w.print("     x={d}..{d}\n", .{ x0, x1 });
        var y = y0;
        while (y <= y1) : (y += 1) {
            var label_buf: [12]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "y={d}", .{y}) catch "y=?";
            try w.writeAll(label);
            var pad = label.len;
            while (pad < 6) : (pad += 1) try w.writeByte(' ');
            var x = x0;
            while (x <= x1) : (x += 1) {
                if (x == cx and y == cy) {
                    try w.writeByte('@');
                } else {
                    try w.writeByte(g.cells[@as(usize, @intCast(y)) * g.w + @as(usize, @intCast(x))]);
                }
            }
            try w.writeByte('\n');
        }
        return try out.toOwnedSlice();
    }
};

test "remembers only what it was shown" {
    var seen: Seen = .{ .gpa = std.testing.allocator };
    defer seen.deinit();
    const k = Seen.key(3, 19);

    try seen.note(k, 20, 20, 5, 5, '#');
    try seen.noteVisit(k, 20, 20, 4, 5);

    const drawn = (try seen.render(std.testing.allocator, k, 4, 5, 2, 1)).?;
    defer std.testing.allocator.free(drawn);

    // The tile looked at is there, the one stood on is a trail, and a tile
    // never in view stays blank.
    try std.testing.expect(std.mem.indexOfScalar(u8, drawn, '#') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, drawn, '@') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, drawn, unseen) != null);
}

test "walked ground keeps its trail" {
    var seen: Seen = .{ .gpa = std.testing.allocator };
    defer seen.deinit();
    const k = Seen.key(0, 0);
    try seen.noteVisit(k, 8, 8, 2, 2);
    // Looking at it again later must not erase that it was walked.
    try seen.note(k, 8, 8, 2, 2, '.');
    const drawn = (try seen.render(std.testing.allocator, k, 0, 0, 7, 7)).?;
    defer std.testing.allocator.free(drawn);
    try std.testing.expect(std.mem.indexOfScalar(u8, drawn, trail) != null);
}
