#!/bin/sh
# Regenerate everything git-ignored: the lifted PPU tree, the lifted SPU
# modules, and the HLE NID table. Run from the repo root.
#
# Supply your own copy of the game first (see README):
#   python ../ps3recomp/tools/pkg_extract.py <your>.pkg extracted
#   cp extracted/USRDIR/EBOOT.BIN game/ && rpcs3 --decrypt game/EBOOT.BIN
set -e
PS3RECOMP="${PS3RECOMP:-../ps3recomp}"
ELF=game/EBOOT.elf

mkdir -p analysis
python "$PS3RECOMP/tools/find_functions.py" "$ELF" --output analysis/functions.json
python "$PS3RECOMP/tools/gen_imports.py"    "$ELF" -o imports.json

# --hle-stubs rewrites each import trampoline as ps3_hle_call(nid) so a direct
# `bl` to an import reaches the HLE handler instead of the literal stub (whose
# pointer table the recomp never fills).
# --code-end stops the branch-target pass from exploding .rodata into functions.
# 0x121F47C is the end of the last executable section: the 294-entry .lib.stub
# trampoline table at 0x121CFBC + 0x24C0.
rm -rf src/recomp && mkdir -p src/recomp src/gen
python "$PS3RECOMP/tools/ppu_lifter.py" "$ELF" \
    --functions analysis/functions.json \
    --hle-stubs imports.json \
    --code-end 0x121F47C \
    -o src/recomp

python "$PS3RECOMP/tools/gen_hle_nids.py" --all --out src/gen/ppu_hle_nids.cpp

# ---- SPU -------------------------------------------------------------------
# All ten SPU modules are real ELFs embedded in the EBOOT (Sony MultiStream's
# audio DSP chain plus the title's own SPURS jobs), so they extract statically
# -- no SPU_DUMP_MISS capture run needed.
#
# build_spu_workloads.py lifts each image under its own C symbol prefix (they
# all define spu_func_* / spu_recomp_register, so they would otherwise collide)
# and emits src/spu_images.c, which registers every image with the runtime's
# workload registry by FNV-1a-64 fingerprint. cellSpurs dispatch fingerprints
# the image the guest hands it and looks it up there.
python "$PS3RECOMP/tools/extract_spu_images.py" "$ELF" --out analysis/spu
rm -rf src/spu_gen
python "$PS3RECOMP/tools/build_spu_workloads.py" \
    --images analysis/spu --lifted src/spu_gen \
    --out src/spu_images.c \
    --register-fn scottpilgrim_spu_register_all --constructor \
    --title scottpilgrim
