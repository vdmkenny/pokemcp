//! A live view of the screen, for humans.
//!
//! The agent never needs this: it reads the game out of memory. But being able
//! to watch what the agent is doing is worth a lot when something goes wrong,
//! so the emulator can drop the current frame on disk as it runs.
//!
//! BMP rather than PNG because it needs no compression library, and every
//! browser renders it. The file is written to a temporary name and renamed
//! into place so a reader never sees a half-written frame.

const std = @import("std");

pub const file_header_len = 14;
pub const info_header_len = 40;

/// Write a 24-bit top-down BMP of an RGBA framebuffer.
pub fn writeBmp(
    out: *std.Io.Writer,
    rgba: []const u8,
    width: u32,
    height: u32,
) std.Io.Writer.Error!void {
    // 240 pixels * 3 bytes is already a multiple of 4, but keep the padding
    // arithmetic honest in case the source size ever changes.
    const row_bytes = width * 3;
    const padding = (4 - (row_bytes % 4)) % 4;
    const image_bytes = (row_bytes + padding) * height;
    const total = file_header_len + info_header_len + image_bytes;

    try out.writeAll("BM");
    try out.writeInt(u32, total, .little);
    try out.writeInt(u32, 0, .little);
    try out.writeInt(u32, file_header_len + info_header_len, .little);

    try out.writeInt(u32, info_header_len, .little);
    try out.writeInt(i32, @intCast(width), .little);
    // Negative height means the rows are stored top-down, which saves
    // flipping the framebuffer.
    try out.writeInt(i32, -@as(i32, @intCast(height)), .little);
    try out.writeInt(u16, 1, .little);
    try out.writeInt(u16, 24, .little);
    try out.writeInt(u32, 0, .little); // BI_RGB
    try out.writeInt(u32, image_bytes, .little);
    try out.writeInt(i32, 2835, .little);
    try out.writeInt(i32, 2835, .little);
    try out.writeInt(u32, 0, .little);
    try out.writeInt(u32, 0, .little);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const i = (y * width + x) * 4;
            // BMP stores pixels as BGR.
            try out.writeByte(rgba[i + 2]);
            try out.writeByte(rgba[i + 1]);
            try out.writeByte(rgba[i + 0]);
        }
        var p: u32 = 0;
        while (p < padding) : (p += 1) try out.writeByte(0);
    }
}

/// Write 16-bit PCM as a WAV. Short chunks of this are what the page stitches
/// back together to get sound; WAV because it needs no encoder and every
/// browser can decode it.
pub fn writeWav(
    out: *std.Io.Writer,
    samples: []const i16,
    rate: u32,
    channels: u16,
) std.Io.Writer.Error!void {
    const data_bytes: u32 = @intCast(samples.len * 2);
    const byte_rate = rate * channels * 2;

    try out.writeAll("RIFF");
    try out.writeInt(u32, 36 + data_bytes, .little);
    try out.writeAll("WAVEfmt ");
    try out.writeInt(u32, 16, .little); // PCM header length
    try out.writeInt(u16, 1, .little); // uncompressed
    try out.writeInt(u16, channels, .little);
    try out.writeInt(u32, rate, .little);
    try out.writeInt(u32, byte_rate, .little);
    try out.writeInt(u16, channels * 2, .little); // block align
    try out.writeInt(u16, 16, .little); // bits per sample
    try out.writeAll("data");
    try out.writeInt(u32, data_bytes, .little);
    for (samples) |s| try out.writeInt(i16, s, .little);
}

/// The page the browser polls. Scaled up and pixellated, because the real
/// thing is 240x160.
pub const index_html =
    \\<!doctype html><meta charset="utf-8"><title>pokemcp</title>
    \\<style>
    \\  body{margin:0;background:#101216;color:#c8ccd4;
    \\       font:13px ui-monospace,SFMono-Regular,Menlo,monospace;
    \\       display:flex;flex-direction:column;align-items:center;
    \\       justify-content:center;height:100vh;gap:12px}
    \\  img{width:min(94vw,720px);height:auto;display:block;
    \\      image-rendering:pixelated;border-radius:4px;
    \\      box-shadow:0 10px 50px #0009}
    \\  .bar{opacity:.5;letter-spacing:.05em;font-size:12px;
    \\       display:flex;gap:10px;align-items:center}
    \\  button{font:inherit;color:inherit;background:#232734;border:1px solid #3a4051;
    \\         border-radius:4px;padding:2px 8px;cursor:pointer}
    \\  button:hover{background:#2c3242}
    \\</style>
    \\<img id="s" alt="game screen">
    \\<div class="bar">pokemcp &middot; <span id="n">0</span> frames
    \\  <button id="snd">enable sound</button></div>
    \\<script>
    \\  let n = 0;
    \\  const img = document.getElementById('s');
    \\  const counter = document.getElementById('n');
    \\  function tick() {
    \\    const next = new Image();
    \\    next.onload = () => {
    \\      img.src = next.src; counter.textContent = ++n; setTimeout(tick, 70);
    \\    };
    \\    next.onerror = () => setTimeout(tick, 300);
    \\    next.src = 'frame.bmp?t=' + Date.now();
    \\  }
    \\  tick();
    \\
    \\  // Sound arrives as a run of short WAVs. Play them back to back, and if
    \\  // we ever fall behind the window kept on disk, jump to the live edge
    \\  // rather than trying to catch up through stale audio.
    \\  const btn = document.getElementById('snd');
    \\  let ctx = null, want = -1, playAt = 0, busy = false;
    \\  btn.onclick = async () => {
    \\    if (ctx) { await ctx.close(); ctx = null; want = -1; btn.textContent = 'enable sound'; return; }
    \\    ctx = new (window.AudioContext || window.webkitAudioContext)();
    \\    await ctx.resume();
    \\    btn.textContent = 'mute';
    \\  };
    \\  async function pump() {
    \\    if (ctx && !busy) {
    \\      busy = true;
    \\      try {
    \\        const m = await (await fetch('audio.json?t=' + Date.now(), {cache:'no-store'})).json();
    \\        if (want < 0 || want < m.first) { want = m.latest; playAt = 0; }
    \\        while (want <= m.latest) {
    \\          const r = await fetch('a' + want + '.wav', {cache:'no-store'});
    \\          if (!r.ok) break;
    \\          const buf = await ctx.decodeAudioData(await r.arrayBuffer());
    \\          const src = ctx.createBufferSource();
    \\          src.buffer = buf; src.connect(ctx.destination);
    \\          if (playAt < ctx.currentTime + 0.05) playAt = ctx.currentTime + 0.2;
    \\          src.start(playAt);
    \\          playAt += buf.duration;
    \\          want++;
    \\        }
    \\        // If the queue has crept ahead of the picture, drop what is left
    \\        // and rejoin at the live edge rather than drifting further.
    \\        if (playAt - ctx.currentTime > 1.2) { want = m.latest + 1; playAt = 0; }
    \\      } catch (e) {}
    \\      busy = false;
    \\    }
    \\    setTimeout(pump, 120);
    \\  }
    \\  pump();
    \\</script>
;

test "bmp header is well formed" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const rgba = [_]u8{0} ** (2 * 2 * 4);
    try writeBmp(&buf.writer, &rgba, 2, 2);
    const out = buf.written();
    try std.testing.expectEqualStrings("BM", out[0..2]);
    try std.testing.expectEqual(
        @as(u32, file_header_len + info_header_len),
        std.mem.readInt(u32, out[10..14], .little),
    );
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, out[28..30], .little));
    // 2x2 pixels, 6 bytes per row padded to 8.
    try std.testing.expectEqual(@as(usize, file_header_len + info_header_len + 16), out.len);
}
