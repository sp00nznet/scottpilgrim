#!/bin/sh
# Lay out vfs/ -- the guest filesystem the harness serves -- from your own
# unpacked copy of the game in extracted/.
#
# The title reaches its data through /app_home, which ppu_fs maps to the VFS
# ROOT, not to PS3_GAME/USRDIR: '/app_home/gamedata' resolves to <root>/gamedata.
# So the root has to BE the USRDIR as far as the game is concerned, while still
# carrying PS3_GAME/PARAM.SFO for cellGame and the harness's title-id lookup.
# Both views are the same bytes -- everything here is a hard link or a junction,
# so vfs/ costs nothing on top of extracted/.
#
#   vfs/
#   ├── gamedata, gamedata.fat, Audio/, Localization/, EBOOT.elf   <- /app_home/*
#   ├── PS3_GAME/{PARAM.SFO, USRDIR -> ...}                        <- /dev_bdvd/*
#   └── dev_hdd0/game/NPEB00258/{PARAM.SFO, USRDIR -> ...}         <- /dev_hdd0/*
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/extracted"
TITLE=NPEB00258

[ -f "$SRC/USRDIR/EBOOT.elf" ] || {
    echo "extracted/USRDIR/EBOOT.elf missing -- unpack your PKG and decrypt first:"
    echo "  python ../ps3recomp/tools/pkg_extract.py your.pkg extracted"
    echo "  cp extracted/USRDIR/EBOOT.BIN game/ && rpcs3 --decrypt game/EBOOT.BIN"
    echo "  cp game/EBOOT.elf extracted/USRDIR/"
    exit 1
}

link() {   # link <host-src> <host-dst>; junction for dirs, hard link for files
    s=$(cygpath -w "$1"); d=$(cygpath -w "$2")
    [ -e "$2" ] && return 0
    if [ -d "$1" ]; then cmd //c mklink //J "$d" "$s" >/dev/null
    else                 cmd //c mklink //H "$d" "$s" >/dev/null; fi
}

rm -rf "$ROOT/vfs"
mkdir -p "$ROOT/vfs/PS3_GAME" "$ROOT/vfs/dev_hdd0/game/$TITLE"
for f in "$SRC"/USRDIR/*; do link "$f" "$ROOT/vfs/$(basename "$f")"; done
cp "$SRC/PARAM.SFO" "$ROOT/vfs/PS3_GAME/PARAM.SFO"
cp "$SRC/PARAM.SFO" "$ROOT/vfs/dev_hdd0/game/$TITLE/PARAM.SFO"
link "$SRC/USRDIR" "$ROOT/vfs/PS3_GAME/USRDIR"
link "$SRC/USRDIR" "$ROOT/vfs/dev_hdd0/game/$TITLE/USRDIR"
echo "vfs/ ready"
