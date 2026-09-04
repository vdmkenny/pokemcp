#!/bin/bash
# One-time setup: fetch and build everything pokemcp needs.
#
# Nothing this script downloads is redistributed by this repository. mGBA is
# the emulator; pokefirered is the disassembly, which builds a ROM from its own
# source and is also where the symbol table comes from.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

say() { printf '\n==> %s\n' "$*"; }

mkdir -p vendor

# -- mGBA ---------------------------------------------------------------------

if [ ! -d vendor/mgba ]; then
	say "cloning mGBA"
	git clone --depth 1 https://github.com/mgba-emu/mgba.git vendor/mgba
fi

say "building libmgba (headless: no Qt, no SDL, no scripting)"
cmake -S vendor/mgba -B build/mgba \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF \
	-DUSE_FFMPEG=OFF -DUSE_DISCORD_RPC=OFF -DUSE_LUA=OFF -DBUILD_PYTHON=OFF \
	-DUSE_EPOXY=OFF -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_TEST=OFF \
	-DENABLE_SCRIPTING=OFF >/dev/null
cmake --build build/mgba -j "$JOBS" >/dev/null

# `struct mCore` is a vtable whose layout depends on these defines. Zig
# translates mGBA's headers with the list in build.zig, and if the two ever
# disagree every call goes through the wrong offset and the server crashes
# somewhere unhelpful. Check it here, where the cause is obvious.
say "checking that build.zig matches how libmgba was compiled"
FLAGS="build/mgba/CMakeFiles/mgba.dir/flags.make"
if [ -f "$FLAGS" ]; then
	missing=""
	while read -r def; do
		[ -z "$def" ] && continue
		grep -q "\"$def\"" build.zig || missing="$missing $def"
	done < <(grep -oE '\-D[A-Za-z0-9_]+' "$FLAGS" | sed 's/^-D//' | sort -u | grep -v '^mgba_EXPORTS$')
	if [ -n "$missing" ]; then
		echo "warning: libmgba was built with defines build.zig does not set:$missing" >&2
		echo "         add them to mgba_defines in build.zig, or calls will land on" >&2
		echo "         the wrong vtable offsets at runtime." >&2
	else
		echo "    ok"
	fi
fi

# -- the disassembly, and the ROM it builds -----------------------------------

if [ ! -d vendor/pokefirered ]; then
	say "cloning pret/pokefirered"
	git clone --depth 1 https://github.com/pret/pokefirered.git vendor/pokefirered
fi

if [ ! -f vendor/pokefirered/tools/agbcc/bin/agbcc ]; then
	say "building agbcc (the period compiler the disassembly needs)"
	[ -d vendor/agbcc ] || git clone --depth 1 https://github.com/pret/agbcc.git vendor/agbcc
	(cd vendor/agbcc && ./build.sh >/dev/null && ./install.sh ../pokefirered >/dev/null)
fi

say "building the ROM"
(
	cd vendor/pokefirered
	export CPPFLAGS="-I/opt/homebrew/include" LDFLAGS="-L/opt/homebrew/lib"
	./build_tools.sh >/dev/null
	make -j "$JOBS" >/dev/null
)

if command -v shasum >/dev/null && [ -f vendor/pokefirered/firered.sha1 ]; then
	say "verifying the ROM against the retail checksum"
	(cd vendor/pokefirered && shasum -c firered.sha1) || \
		echo "warning: the built ROM does not match retail FireRed" >&2
fi

# -- the generated table ------------------------------------------------------

say "extracting the symbol table, charmap and constants"
zig build gamedata -- vendor/pokefirered

say "building pokemcp"
zig build -Doptimize=ReleaseFast

cat <<EOF

Done. Run the server with:

  ./zig-out/bin/pokemcp --rom vendor/pokefirered/pokefirered.gba

EOF
