# pokemcp

An MCP server that plays Pokémon by reading emulator memory, so an agent can
know what is going on and control the game without ever looking at a
screenshot.

It runs the game headless inside mGBA and reports state the way the game itself
stores it: the tiles on screen and whether they can be walked on, the NPCs and
doors among them, the text in the message box, the party, the battle, the open
menu. Every address comes from the disassembly's own symbol table, so nothing
is a magic number.

## What the agent sees

Only what the Game Boy Advance is drawing. The screen is 240x160 pixels with
16x16 metatiles, which is exactly 15x10 tiles with the player at column 7,
row 4, and that is the whole window:

```
     x=-1..13
y=2   .#.......##D...
y=3   .#.......##....
y=4   .#.....#.......
y=5   .#.....#.......
y=6   .#.#...@.......
y=7   .#.............
y=8   .#.............
y=9   ...............
y=10  ...............
y=11  ...............
@ you  . walkable  # blocked  ~ water  " grass  ^ ledge  N npc  D door/stairs  ? off-map
```

There is no world map and no path-finding tool. Crossing a map means reading
the view, moving a few tiles, and reading again, the same loop a person plays
with. The one thing always visible regardless of the screen is the party, since
a player can open that menu at any time.

Text is decoded from the game's own character encoding, placeholders and all,
so dialogue arrives as `PROF. OAK: Hello there!` rather than bytes.

## Tools

| Tool | What it does |
| --- | --- |
| `observe` | Everything on screen: mode, tile view, NPCs, doors, text box, menu, party |
| `screen` | Just the tile view and position, for when you are only navigating |
| `move` | Walk, checking each step actually happened and saying what blocked it |
| `press` | Any button combination, for menus and battles |
| `wait` | Let animations and scripted scenes run |
| `advance_text` | Press through a conversation, returning everything that was said |
| `party` | The party, at any time |
| `save_state` / `load_state` | Snapshot and rewind, for trying something reversible |
| `read_memory` / `find_symbol` | Escape hatch, by address or by symbol name |

## Setup

Needs Zig 0.16, CMake, and a C toolchain. On Apple Silicon, use a native arm64
Zig: an x86_64 Zig under Rosetta will build an x86_64 binary that cannot link
against an arm64 libmgba.

```bash
./scripts/setup.sh
```

That clones mGBA and `pret/pokefirered`, builds a headless libmgba, builds the
ROM from the disassembly, verifies it against the retail checksum, extracts the
game table, and builds the server. It takes a while the first time, mostly
compiling the ROM.

Then:

```bash
./zig-out/bin/pokemcp --rom vendor/pokefirered/pokefirered.gba
```

It speaks JSON-RPC over stdio. Point an MCP client at that command.

## What is not in this repository

No ROM, no save files, and no part of the disassembly. `scripts/setup.sh`
fetches `pret/pokefirered` and builds the ROM from it locally; the resulting
`data/firered.dat`, which holds the symbol table and character map extracted
from that build, is generated on your machine and is gitignored. What is here
is the harness: the emulator binding, the readers, and the server.

## Adding another game

The split is between reading a game's memory and driving any game. `game.zig`
holds everything that is true of all of them, including how a step is taken and
verified and what "on screen" means. `games/firered.zig` holds the part that
knows FireRed.

Adding Silver, Red or Crystal means writing one adapter and adding it to the
`Game` union, which the compiler then forces you to handle everywhere. mGBA's
core already runs Game Boy and Game Boy Color titles, so the emulator layer does
not change; the viewport constants and the text encoding are per-adapter,
because a Game Boy screen is a different size and Gen 2 encodes text
differently.

A romhack built from the same disassembly is easier still: it keeps the
structures and only moves the addresses, so it needs a regenerated table rather
than new code.

```bash
zig build gamedata -- /path/to/your/hack
./zig-out/bin/pokemcp --rom hack.gba --data data/firered.dat
```

## Design notes

**Symbols, not magic numbers.** `zig build gamedata` reads the linked ELF and
extracts every symbol, the character map, and the map and terrain constant
names. Rebuilding the ROM keeps everything pointing at the right place.

**Structures are checked at compile time.** The game's structs are Zig types in
`games/structs.zig`, with `comptime` assertions against the offsets the
disassembly documents. A field in the wrong place fails the build instead of
quietly reporting nonsense.

**Screens are named by the game's own callback.** `gMain.callback2` is the
function the game runs each frame, so resolving it through the symbol table
names the screen exactly: `CB2_Overworld`, `BattleMainCB2`, `CB2_BagMenuRun`.

**Warps carry the rule for using them.** Every building lists several warp
tiles, but most are arrival points that never fire. The terrain type says which
ones work and how: a door opens when you step on it, an arrow tile or a
staircase needs one more press in the direction it points. `observe` reports
that as the `trigger` field.

**Moving verifies itself.** `move` holds the d-pad until the position actually
changes rather than for a fixed number of frames, because a step takes longer
on stairs or while the game is busy. A step that does not move you is a result,
not an error: it is how you find a wall, a ledge, or an NPC in the way.

## Tests

```bash
zig build test
```

Covers the text codec against real control codes, the Pokémon decryption and
its checksum, the structure offsets, symbol resolution, warp rules, and the
tool table.
