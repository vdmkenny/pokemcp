const std = @import("std");

/// Preprocessor defines libmgba was compiled with. `struct mCore` is a vtable
/// whose layout changes with these, so the Zig side must translate the headers
/// with exactly the same set or every call lands on the wrong offset.
/// scripts/setup.sh scrapes these from the CMake build and keeps them in sync.
const mgba_defines = [_][]const u8{
    "ENABLE_DEBUGGERS", "ENABLE_DIRECTORIES", "ENABLE_GDB_STUB",
    "ENABLE_VFS",       "ENABLE_VFS_FD",      "HAVE_CRC32",
    "HAVE_FREELOCALE",  "HAVE_FUTIMENS",      "HAVE_FUTIMES",
    "HAVE_LOCALE",      "HAVE_LOCALTIME_R",   "HAVE_NEWLOCALE",
    "HAVE_PTHREAD_CREATE", "HAVE_PTHREAD_SETNAME_NP", "HAVE_REALPATH",
    "HAVE_SETLOCALE",   "HAVE_SNPRINTF_L",    "HAVE_STRDUP",
    "HAVE_STRLCPY",     "HAVE_STRNDUP",       "HAVE_STRTOF_L",
    "HAVE_USELOCALE",   "HAVE_VASPRINTF",     "HAVE_XLOCALE",
    "MGBA_DLL",         "M_CORE_GB",          "M_CORE_GBA",
    "NDEBUG",           "USE_EDITLINE",       "USE_FREETYPE",
    "USE_LZMA",         "USE_MINIZIP",        "USE_PNG",
    "USE_PTHREADS",     "USE_SQLITE3",        "USE_ZLIB",
    "_DARWIN_C_SOURCE",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mgba_src = b.option([]const u8, "mgba-src", "mGBA source checkout") orelse "vendor/mgba";
    const mgba_build = b.option([]const u8, "mgba-build", "mGBA cmake build dir") orelse "build/mgba";

    const exe = b.addExecutable(.{
        .name = "pokemcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkMgba(b, exe, mgba_src, mgba_build);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the MCP server").dependOn(&run.step);

    // The player: a standalone client that drives the MCP server with an
    // OpenRouter model and serves the live screen. It spawns the server binary
    // rather than linking it, so it needs no mGBA.
    const play = b.addExecutable(.{
        .name = "pokemcp-play",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/play.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(play);
    const play_run = b.addRunArtifact(play);
    play_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| play_run.addArgs(args);
    b.step("play", "Let an OpenRouter model play, and watch").dependOn(&play_run.step);

    // Extracts the symbol table, charmap and constant names from a built
    // pokefirered checkout. Its output is derived from the disassembly, so it
    // is generated locally and never committed.
    // The extractor and the loader share the on-disk format definition.
    const dataformat = b.createModule(.{
        .root_source_file = b.path("src/dataformat.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_gamedata.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    gen_mod.addImport("dataformat", dataformat);
    const gen = b.addExecutable(.{ .name = "gen-gamedata", .root_module = gen_mod });
    b.installArtifact(gen);
    const gen_run = b.addRunArtifact(gen);
    if (b.args) |args| gen_run.addArgs(args);
    b.step("gamedata", "Extract game data from a built pokefirered ROM")
        .dependOn(&gen_run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    linkMgba(b, tests, mgba_src, mgba_build);
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

fn linkMgba(b: *std.Build, step: *std.Build.Step.Compile, src: []const u8, bld: []const u8) void {
    const m = step.root_module;
    m.link_libc = true;
    for (mgba_defines) |d| m.addCMacro(d, "1");
    m.addIncludePath(b.path(b.pathJoin(&.{ src, "include" })));
    m.addIncludePath(b.path(b.pathJoin(&.{ bld, "include" })));
    m.addIncludePath(b.path(bld));
    m.addLibraryPath(b.path(bld));
    m.linkSystemLibrary("mgba", .{});
    m.addRPath(b.path(bld));
}
