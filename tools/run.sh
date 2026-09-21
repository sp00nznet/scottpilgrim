#!/bin/sh
# Run the recompiled title against the extracted game data.
#
# PS3_VFS_ROOT   -- the PS3_GAME tree (PARAM.SFO + USRDIR); the harness reads
#                   the title id from PARAM.SFO, and cellGame builds every
#                   /dev_hdd0/game/<id> path from it.
# PS3_HDD0_ROOT  -- where the title's installed data lives.
# RSX_LIVE_DRAW  -- caner's live NV4097 -> D3D12 draw engine.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Git Bash rewrites POSIX-looking paths in environment values on the way to a
# native binary. Guest paths must survive intact; host paths must arrive in
# Windows form, so convert those explicitly rather than by heuristic.
export MSYS2_ENV_CONV_EXCL="*"
ROOT_W="$(cygpath -m "$ROOT")"

export PS3_VFS_ROOT="${PS3_VFS_ROOT:-$ROOT_W/vfs}"
export PS3_HDD0_ROOT="${PS3_HDD0_ROOT:-$ROOT_W/vfs/dev_hdd0}"
# Point at an RPCS3 dev_flash dump. No sane default exists, so this must be set.
export PS3_DEV_FLASH="${PS3_DEV_FLASH:?set PS3_DEV_FLASH to your RPCS3 dev_flash path}"
export PS3_TITLE="${PS3_TITLE:-Scott Pilgrim vs. The World: The Game - ps3recomp}"
export RSX_LIVE_DRAW="${RSX_LIVE_DRAW:-1}"

exec "$ROOT/build/scottpilgrim.exe" "$ROOT_W/vfs/PS3_GAME/USRDIR/EBOOT.elf" "$@"
