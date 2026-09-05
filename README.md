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
| `use_move` | In battle, use a move by name or number; plays the turn out and returns what happened |
| `party` | The party, at any time |
| `save_state` / `load_state` | Snapshot and rewind, for trying something reversible |
| `enter_name` | Type on a naming screen: the player, the rival, a nickname |
| `say` | Speak in the game's own message box, in your own colour |
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

## Watching it play

Unthrottled the emulator runs about forty times faster than a Game Boy, which
is useless to watch. `--realtime` paces it to the real 59.7fps, and `--stream`
drops each frame in a directory with a page to view it:

```bash
./zig-out/bin/pokemcp --rom pokefirered.gba --realtime --stream /tmp/pokemcp
```

Serve that directory with any static file server and open `index.html`.

`--speed 4` and the like sit in between, for skipping the parts nobody wants to
watch.

Setting a speed also hands the game its own thread, so it keeps running between
tool calls rather than freezing on every decision. NPCs keep walking, water
keeps animating, and a button press is something held for a while and then let
go, the way a controller works. Without a speed limit the emulator steps only
when asked, which is faster and reproducible: better for tests, and for getting
through a long stretch quickly.

## Letting a model play it

`pokemcp-play` is the other half: it starts the server, hands the tools to a
model on [OpenRouter](https://openrouter.ai) as function calls, serves the
screen, and runs the loop.

```bash
cp .env.example .env      # put your key in it
zig build play
```

That is the whole thing. It opens the live screen in a browser and starts
playing. The goal, the model and the key can each come from a flag, the
environment, or `.env`, in that order:

| | flag | variable |
| --- | --- | --- |
| goal | `--prompt` / `--prompt-file` | `POKEMCP_PROMPT` |
| model | `--model` | `OPENROUTER_MODEL` |
| key | `--key` | `OPENROUTER_API_KEY` |

```bash
./zig-out/bin/pokemcp-play --model openai/gpt-4o-mini \
    --prompt "Get to Viridian City and catch something on the way."
```

`.env` is gitignored, so the key stays out of the repository and out of your
shell history.

The model is told it is a brand new trainer who has only just left home and
knows almost nothing about the world, and to stay in character: no talk of
tools or models, things happen to it. It puts its thoughts on screen with
`say`, so what you are watching is a nervous rookie thinking out loud rather
than a program narrating itself. It is also told to read what people tell it
rather than mashing through, and to pick real names when the game asks for one.

It never sees a picture. The screen in your browser is for you.

## Talking to the audience

`say` puts text in the game's own message box:

```
say  "Route 1 next.\nI need a Potion first."
```

It is a real message, not something drawn over the picture: the tool assembles
four bytecode instructions in the RAM the game reserves for link scripts,
points the idle script context at them, and the engine runs it on the next
frame. The game draws the box, in its own font and window.

It comes out red on pale blue rather than the usual dark grey on white, so
viewers can tell your voice from the game's; `color` and `background` change
that. The colour rides along in the message as one of the game's own text
control codes, so nothing has to be restored afterwards and ordinary dialogue
is untouched.

It only works standing in the overworld with nothing else happening, since
interrupting a script the game is already running would strand it.

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

**Naming is done by writing, not typing.** `enter_name` puts the name straight
into the naming screen's buffer instead of walking its on-screen keyboard,
which would be dozens of presses and depends on the cursor starting where you
expect. The game copies that buffer to its destination when the name is
confirmed, so the result is what it would have been by hand. The screen's own
character limit is respected: a name too long for it is refused rather than
allowed to overflow into the save data behind it.

**Moving verifies itself.** `move` holds the d-pad until the position actually
changes rather than for a fixed number of frames, because a step takes longer
on stairs or while the game is busy. A step that does not move you is a result,
not an error: it is how you find a wall, a ledge, or an NPC in the way.

**Battle moves are chosen by name.** Picking a move by hand means opening FIGHT
and walking a 2x2 grid with no reliable read of where the cursor started, which
is easy for a small model to fumble into the wrong move or into RUN. `use_move`
takes a name or a 1-based number and writes the two cursor variables the game
reads the instant A is pressed, so the choice is exact. It knows when to act
from the game's own record of what each battler is waiting on: it presses only
while `HandleInputChooseAction` or `HandleInputChooseMove` is live, so a press
never leaks into a message still being read out. Then it plays the turn out,
returning every line shown, and stops when the battle ends or it is your turn to
choose again. It presses through acknowledgements with no text of their own, the
level-up stat box in particular, which would otherwise hang the battle.

**Reading, not mashing.** The text tools exist so the agent reads the game, not
so it skips it: `advance_text` and `use_move` return every line they pass, and
`observe` reports the current box. Forgiving input helps a small model stay in
the loop rather than stall: `press` takes a single name or a list and accepts
the compass words `move` uses for the d-pad, and a bad button or direction comes
back naming the valid ones instead of a bare error code.

## Tests

```bash
zig build test
```

Covers the text codec against real control codes, the Pokémon decryption and
its checksum, the structure offsets, symbol resolution, warp rules, and the
tool table.
