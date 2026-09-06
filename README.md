# 🎸 scottpilgrim-ps3 — Static Recompilation

A static recompilation of **Scott Pilgrim vs. The World: The Game** (PlayStation 3 / PSN)
into a native PC executable — no emulator required — built on
[ps3recomp](https://github.com/sp00nznet/ps3recomp).

> *"We are Sex Bob-Omb and we are here to make you think about death and get sad and stuff."*

---

## 🎯 Why This One

Ubisoft put this out in August 2010: a four-player beat-'em-up drawn by **Paul Robertson**,
scored by **Anamanaguchi**, built to look like a lost 1994 arcade cabinet. It was the rare
licensed tie-in that was better than it had any right to be.

Then, on **31 December 2014**, it vanished. Delisted from PSN and XBLA with a music-licence
expiry as the stated reason, and there was never a disc — this was digital-only, both
regions, both consoles. If you hadn't bought it, you couldn't. For six years the only way
to play it was to already own it.

It came back in January 2021 as the *Complete Edition*, and that's a good thing. But the
Complete Edition is a re-release on a different runtime, with the DLC folded in and the
edges sanded off. **The original PSN build is its own artifact** — a specific 22 MB
PowerPC executable, compiled once in 2010, that exists on a console nobody manufactures
any more. That's the thing this repo is about.

---

## 📊 Status: Phase 2 — Boots, Opens a Window, Loads Its Data

The title boots end-to-end, brings up its own engine, opens a D3D12 window and
presents at 32 fps. It reads every one of its archives. It does not yet draw
geometry, because loading stops on an audio SPU task — see the blocker below.

| Milestone | Status |
|---|---|
| Locate & extract the PSN PKG | ✅ Done — full + 4.21 resign, `pkg_extract.py` |
| Decrypt EBOOT.BIN (SELF → ELF) | ✅ Done — `rpcs3 --decrypt`, key revision `0x1C`, no RAP needed |
| Import table resolution (PLT/NID) | ✅ Done — 294 imports, 20 libraries, 274 named (93%) |
| Function discovery | ✅ Done — **57,318** functions, every `.opd` descriptor verified as a start |
| PPU lift → C++ | ✅ Done — **59,429** functions, 298 MB across 9 translation units |
| SPU images | ✅ Done — 10 embedded ELFs, extracted statically, all lifted |
| Build (clang-cl + Ninja) | ✅ Done — 101 MB exe in 2 m 22 s |
| First boot / CRT / `main()` | ✅ Done — recompiled CRT runs, TLS + argv land |
| Guest threads | ✅ Done — `Gear::`, `Onyx`, `Dare::` workers all spawn and run |
| `cellGame` boot flow | ✅ Done — BootCheck / DataCheck / ContentPermit complete |
| Graphics backend (RSX → D3D12) | ⚠️ **Partial** — window opens, presents at 32 fps, **no geometry yet** |
| Game data / asset loading | ✅ Done — all four `gamedata` archives open and read (via AIO) |
| SPU dispatch | ✅ Done — both SPURS tasks fingerprint-match and run, 0 misses |
| Audio (MultiStream → cellAudio) | ⚠️ **Partial** — port opens and starts, SPU task dies on a DMA'd overlay |
| Input (cellPad → XInput) | ⬜ Not started |
| 🎸 Playable | ⬜ Not started |

### What's Working

- **59,429 PPU functions** recompiled to native C++ and linked into one 101 MB binary
- **The title's own engine runs** — Ubisoft's Gear/Onyx/Claw, with named worker
  threads (`Gear::AsynchDevice`, `Onyx Loading Worker`, `Dare::AudioRenderer`)
- **A window with the game's own present loop behind it** — `cellVideoOut` configures
  720p, both display buffers register, the live NV4097 → D3D12 engine comes up and
  flips at 32 fps
- **Every archive the boot asks for opens and reads** — `gamedata`, `gamedata.fat`,
  `gamedata_1`, `gamedata_1.fat`, plus `flashATRAC.pic` out of firmware
- **Both SPURS tasks dispatch and run** — zero fingerprint misses across a run
- **Audio initialises** — `cellAudioInit`, `PortOpen(8ch × 8 blocks)`, `PortStart`

### Current Blocker

**The MultiStream audio SPU task branches into code that was never in the ELF.**

```
[spu] img=2 branched into unlifted LS 0x33190 (lr=0x05F50) -- ending the job
[spu_workload] async image=2 RETURNED rc=0 (job ran to completion, did not loop)
```

Local store `0x33190` is 209,296 — far past the end of the 67,220-byte image. Sony
MultiStream **DMAs its DSP modules into local store at runtime** (`cellMSDSPLoadDSPFromMemory`
is right there in the binary's symbols), so they are not in the embedded ELF and
nothing lifted them. The task falls out of its loop the instant it branches into one.

Everything downstream is consequence, not cause: `Dare::AudioRenderer` and
`Dare::HLPLoadingManager` exit immediately, a later `cellSpursSendSignal` has nothing
alive to receive it, loading never completes, and the renderer has therefore
submitted zero draw packets. The next step is capturing those overlays as they land
in LS and lifting them, the way `SPU_DUMP_MISS` captures raw SPURS job images.

### Fixed So Far

Four blockers, three of them fixes to ps3recomp itself that every port inherits.
Full account, in the order it happened: [`PROGRESS.md`](PROGRESS.md).

- **Every file open missed.** `/app_home/...` maps to the VFS *root*, not to
  `PS3_GAME/USRDIR`, so all 37 opens failed. `tools/setup_vfs.sh` now lays the root
  out so it *is* the USRDIR (hard links and junctions, no copies) while still
  carrying `PS3_GAME/PARAM.SFO` for `cellGame`.
- **One open, then nothing.** This title never calls `cellFsRead` — it reads
  everything through **`cellFsAioRead`**, which was an unresolved NID. Its loader
  submitted requests nothing ever completed. Implemented `cellFsAioInit` / `AioRead`
  / `AioFinish` / `AioCancel` in the runtime.
- **All ten SPU images registered under fingerprints nothing would dispatch.**
  `extract_spu_images.py` disagreed with the runtime's `spu_elf_image_size()` — it
  counted only `PT_LOAD` extents and seeded from the wrong header table. These
  images have no section headers and one non-`PT_LOAD` segment past the last
  `PT_LOAD`, so every extract came out **52 bytes short**.
- **A signal lost to one missing byte swap.** `cellSpursCreateTask` wrote its
  `taskId` out-param host-endian; the guest read `0x01000000` for task 1 and handed
  that back to `cellSpursSendSignal`, which dropped it. The SPU task sat in
  `WAIT_SIGNAL` while the PPU waited on the event flag it would have set.

**This is the largest ps3recomp target attempted so far**, by a wide margin:

| Port | Functions lifted |
|---|---|
| Twisted Metal (`ps1_netemu`) | 3,512 |
| The Simpsons Arcade Game | 5,019 |
| Tokyo Jungle | 7,924 |
| **Scott Pilgrim** | **59,429** |

18.9 MB of `.text` against Tokyo Jungle's ~1.3 MB. A 2D beat-'em-up has no business
being this big — the size is the engine, the middleware and the statically-linked
Sony libraries riding along inside one EBOOT, not the game logic.

---

## 📺 The Game

| | |
|---|---|
| **Title** | Scott Pilgrim vs. The World: The Game |
| **Platform** | PlayStation 3 (PSN download, no physical release) |
| **Title ID** | `NPEB00258` (EU) |
| **Content ID** | `EP0001-NPEB00258_00-SCOTTPILGRIM0002` |
| **App version** | `01.03` (the final patch) |
| **Trophy ID** | `NPWR01320_00` |
| **Category** | `HG` — a native PS3 title, not an emulator wrapper |
| **Min firmware** | `03.4000` |
| **Developer** | Ubisoft Chengdu |
| **Publisher** | Ubisoft |
| **Released** | August 2010 · **delisted 31 December 2014** |
| **Art** | Paul Robertson · **Music** Anamanaguchi |

## 🔬 The Binary

`EBOOT.BIN` decrypted with `rpcs3 --decrypt` from the 4.21 resigned package
(key revision `0x1C`, no RAP or klicensee required):

| | |
|---|---|
| Decrypted ELF | 22,659,040 B — PPC64, big-endian, `ET_EXEC` |
| Entry | `0x01455798` |
| `.text` | `0x00010230` .. `0x0121CF78` — **18.9 MB**, 5,234,714 instructions |
| `.lib.stub` | `0x0121CFBC` .. `0x0121F47C` — 294 import trampolines (the `--code-end`) |
| Data segment | PT_LOAD @ `0x01410000`, filesz `0x198780`, memsz `0x25CB38` |
| `.opd` descriptors | **53,453** |
| Functions found | **57,318** (`find_functions.py`) |
| Functions lifted | **59,429** — the extra 1,967 are mid-function tail-entry wrappers |
| Unique call targets | 15,973 |
| Embedded SPU ELFs | **10**, 120,576 B total, extracted statically |

### Imports, by library

Twenty libraries, and the shape of them says a lot about the title:

```
 40  sceNp          27  cellSpurs      25  sys_net        24  sysPrxForUser
 24  cellSysutil    24  cellGcmSys     23  sceNp2         21  sys_fs
 20  sys_io         14  cellSpursJq    10  cellSysutilAvc2 9  sceNpTrophy
  7  cellAudio       6  cellNetCtl      5  cellGame        4  cellUserInfo
  3  sceNpCommerce2  3  cellSysmodule   3  cellSync        2  cellRtc
```

**76 of the 294 imports are network and PSN.** `sceNp`, `sceNp2`, `sceNpCommerce2`,
`cellNetCtl`, `sys_net` and `cellSysutilAvc2` (audio/video chat) — this is a 2010 title
built around online co-op against servers that no longer answer. Getting past that
politely is going to be part of the work, and it is exactly the kind of thing that makes
a preservation port worth doing.

**Audio is Sony MultiStream**, statically linked: 102 `cellMS*` symbols
(`cellMSStreamOpen`, `cellMSCoreSetDSP`, `cellMSSurroundSetListener`, …) are in the
binary itself rather than imported, which is why 10 SPU images ship inside the EBOOT.
Only 7 `cellAudio` imports — MultiStream does the mixing on the SPUs and hands
`cellAudio` a finished pair of buffers.

**Graphics are raw `cellGcmSys`** — 24 imports, no PhyreEngine, no middleware renderer.
The RSX command stream is the title's own, which is the case the harness's live NV4097 →
D3D12 engine is built for.

### Game data

| File | Size |
|---|---|
| `USRDIR/gamedata` + `.fat` | 61,512,740 B + 313,060 B |
| `USRDIR/gamedata_1` + `.fat` | 18,427,702 B + 205,735 B |
| `USRDIR/Audio/Packages/*.spk` | ~90 MultiStream sound packages |
| `USRDIR/Localization/*.bof` | 7 languages (EN/FR/DE/IT/ES/NL/JP) |

A `.fat` index beside a flat blob is a straightforward archive pair; nothing here is
encrypted past the package layer.

---

## 🛠️ Pipeline

```
  PSN PKG ──► EBOOT.BIN ──► EBOOT.elf ──► ppu_lifter ──► C++ ──► link ps3recomp ──► scottpilgrim.exe
              (SELF)        (decrypt)     (59,429 fns)          (shared harness + HLE)
                                              ▲
              10 embedded SPU ELFs ── spu_lifter ──┘   (MultiStream DSP + SPURS jobs)
```

Same five-stage flow as every ps3recomp port — extract, decrypt, analyse, lift, link.
[`flOw`](https://github.com/sp00nznet/flow) is the reference implementation of this
pipeline; [`tokyojungle`](https://github.com/sp00nznet/tokyojungle) is the closest
comparable native 3D title.

## 📦 Building

Prereqs: Python 3.9+, CMake 3.20+, **clang-cl** + Ninja (the shared harness uses
`__builtin_bswap` and weak symbols MSVC lacks), and a sibling
[ps3recomp](https://github.com/sp00nznet/ps3recomp) checkout.

```bash
# 1. Supply your own legally obtained copy of the game and unpack it:
python ../ps3recomp/tools/pkg_extract.py your.pkg extracted
mkdir -p game && cp extracted/USRDIR/EBOOT.BIN game/
rpcs3 --decrypt game/EBOOT.BIN && cp game/EBOOT.elf extracted/USRDIR/

# 2. Lift the PPU image + the 10 SPU images, and generate the HLE NID table:
PS3RECOMP=../ps3recomp ./tools/relift.sh

# 3. Lay out the guest filesystem (hard links + junctions, no copies):
./tools/setup_vfs.sh

# 4. Build. Release is the default and it matters -- an unoptimised build of a
#    298 MB recompiled tree runs at a third the speed. Budget the disk space.
#    llvm-rc: clang-cl outside a VS dev prompt cannot find Microsoft's rc.exe.
cmake -S . -B build -G Ninja \
    -DCMAKE_C_COMPILER="C:/Program Files/LLVM/bin/clang-cl.exe" \
    -DCMAKE_CXX_COMPILER="C:/Program Files/LLVM/bin/clang-cl.exe" \
    -DCMAKE_RC_COMPILER="C:/Program Files/LLVM/bin/llvm-rc.exe"
cmake --build build

# 5. Run, with the live NV4097 -> D3D12 draw engine:
./tools/run.sh
```

`tools/run.sh` sets `PS3_VFS_ROOT` (the `PS3_GAME` tree the harness reads `PARAM.SFO`
from), `PS3_HDD0_ROOT` (where the installed data lives) and `RSX_LIVE_DRAW=1`.

## ⚖️ Legal

This repository contains **no copyrighted game code, assets, binaries, or encryption
keys** — only analysis notes, configuration and recompilation tooling. You must supply
your own legally obtained copy of the game. `pkg/`, `pkg_x/`, `extracted/`, `game/`,
`vfs/`, `analysis/` and the lifted output (`src/recomp/`, `src/spu_gen/`, `src/gen/`)
are git-ignored.

Licence: [MIT](LICENSE), covering this repository's own tooling, scripts and notes.

**Scott Pilgrim vs. The World: The Game** is a trademark of Ubisoft Entertainment; the
Scott Pilgrim characters belong to Bryan Lee O'Malley. This project is not affiliated
with, endorsed by, or connected to Ubisoft, Oni Press or any rights holder. It exists
for game preservation purposes.

## 🔗 Related Projects

- [ps3recomp](https://github.com/sp00nznet/ps3recomp) — the PS3 HLE runtime this links against
- [flOw](https://github.com/sp00nznet/flow) · [simpsonsarcade-ps3](https://github.com/sp00nznet/simpsonsarcade-ps3) · [tokyojungle](https://github.com/sp00nznet/tokyojungle) · [tmpsn](https://github.com/sp00nznet/tmpsn) — sister PS3 ports
- [N64Recomp](https://github.com/N64Recomp/N64Recomp) · [UnleashedRecomp](https://github.com/hedge-dev/UnleashedRecomp) — prior art
- [RPCS3](https://github.com/RPCS3/rpcs3) — emulator whose HLE research (and `--decrypt`) makes this possible

---

*"The power of understanding was in your heart the whole time."* — port it natively instead.
