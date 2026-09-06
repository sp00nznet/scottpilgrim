# Progress log

Newest first. Each entry is what was tried, what the log said, and what it turned
out to be — including the wrong turns, because those are the expensive part.

---

## 2026-09-05 — day one: extract → lift → build → boot → audio SPU

Everything below happened in one session, from a `.rar` to a title that boots,
opens a D3D12 window, presents at 32 fps and loads its data.

### Extraction and lift

The `.rar` holds a nested multipart archive with two packages: the retail
`_Full.pkg` (208 MB, `pkg_type` key revision `0x0004` — NPDRM, wants a RAP) and a
`_Crack-4.21.pkg` (22.6 MB, key revision `0x001C` — a 4.21 retail resign of just
the EBOOT). `rpcs3 --decrypt` takes the resigned one with no RAP or klicensee.

```
find_functions:  53,453 .opd descriptors -> 57,318 functions (9.2 s)
ppu_lifter:      59,429 functions, 9 TUs, 298 MB of C++ (63 s)
                 +1,967 mid-function tail-entry wrappers, 15,973 call targets
extract_spu:     10 embedded SPU ELFs, 120,680 B
clang-cl build:  101 MB scottpilgrim.exe (2 m 22 s, 27 targets)
```

`--code-end 0x121F47C` — the end of the `.lib.stub` trampoline table. Without it
the branch-target pass explodes 2 MB of `.rodata` into phantom functions.

### First boot

Further than expected for a first run. The recompiled CRT runs, `sys_initialize_tls`
lands, argv is built, and the title's own engine starts: threads named
`Gear::AsynchDevice`, `Gear::AsynchGeneric`, `Onyx Loading Worker`, `Onyx Task
Worker` — Ubisoft's Gear/Onyx/Claw engine, with `Dare::` for audio.
`cellGame BootCheck` → `DataCheck` → `ContentPermit` all complete, `cellVideoOut`
configures 1280x720, tiles and both display buffers are set, and the live NV4097 →
D3D12 engine comes up and presents. **32 fps, no geometry** — nothing is submitting
draws yet, because loading never finishes.

### Blocker 1 — every file open missed

`/app_home/gamedata` resolved to `<vfs>/gamedata`, and the vfs root was the
`PS3_GAME` parent. 37 failed opens, zero successes: the title reaches its data
through `/app_home`, which `ppu_fs` maps to the VFS ROOT rather than to
`PS3_GAME/USRDIR`.

Fixed in the port, not the runtime: `tools/setup_vfs.sh` lays the root out so it
*is* the USRDIR (hard links and junctions — no copies), while still carrying
`PS3_GAME/PARAM.SFO` for `cellGame` and the harness's title-id lookup.

### Blocker 2 — one open, no reads

With paths fixed it opened `gamedata_1.fat` and then stopped dead: the main thread
spun on `0x0FEFFAE8` forever. The log named the cause plainly once the unresolved
NIDs were mapped back to their libraries:

```
0xDB869F20  sys_fs  cellFsAioInit
0xC1C507E7  sys_fs  cellFsAioRead
```

**This title does not use `cellFsRead` at all.** It opens a file and then reads it
exclusively through `cellFsAioRead` with a completion callback. Both NIDs were
unimplemented in ps3recomp, so the loader submitted requests that nothing ever
completed.

Implemented `cellFsAioInit` / `AioRead` / `AioFinish` / `AioCancel` in
`runtime/ppu/ppu_fs.cpp`. The read is absolute (it must not disturb the fd's own
file position — the guest interleaves AIO across threads) and the guest completion
OPD is invoked through `ps3_invoke_guest`. It runs synchronously and fires the
callback before the submit returns; a title that armed its wait *after* submitting
would miss it, which is a known ceiling, not a bug seen here.

Result: `gamedata`, `gamedata.fat`, `gamedata_1`, `gamedata_1.fat` all open and
read, `flashATRAC.pic` loads out of firmware, `cellSaveData AutoSave` runs, and
`cellAudio` initialises with its mixing thread.

### Blocker 3 — every SPU image registered under a fingerprint nothing dispatches

```
[spu_workload] async dispatch MISS fp=0x5CFFBA88D1D9616D size=7012
[spu_workload] async dispatch MISS fp=0xB8D923CF62CDEAFF size=67220
```

The images we registered were 7,012−52 = 6,960 and 67,220−52 = 67,168 bytes. Both
short by exactly 52 bytes, so both fingerprints were wrong.

`spu_elf_image_size()` in `runtime/spu/spu_workload.c` decides how many bytes the
dispatcher hashes when the guest hands an image to cellSpurs. `extract_spu_images.py`
was computing something else: it counted only `PT_LOAD` extents, and seeded its
running end from the program-header table rather than the section-header table.
These SPU images have **no section headers at all** and one non-`PT_LOAD` segment
past the last `PT_LOAD` — so the extract stopped 52 bytes early, every time.

Made the extractor mirror the runtime function exactly. All ten images now extract
to the byte count the dispatcher reports, and both fingerprints hit:

```
[spu_workload] dispatch HIT (async) fp=0x5CFFBA88D1D9616D image=1 -> spawning thread
[spu_workload] dispatch HIT (async) fp=0xB8D923CF62CDEAFF image=2 -> spawning thread
```

This is a general fix — any title whose SPU images have this shape was affected.

### Blocker 4 — a signal lost to one missing byte swap

The audio SPU task started and immediately parked, while the PPU waited on the
event flag that task would set. A two-sided deadlock, and the log had already
printed the evidence three lines earlier:

```
[cellSpurs] CreateTask(id=1, entry=0x013F1F80, ...)
[cellSpurs] _SendSignal(taskset=0x01629A80 id=16777216)
```

`16777216` is `0x01000000` — `1`, byte-swapped. `cellSpursCreateTask` wrote its
`taskId` out-param with a native host store; the guest read it big-endian, got
`0x01000000`, and handed that straight back to `_cellSpursSendSignal`. No task by
that id exists, so the signal was dropped on the floor.

Fixed with `vm_write32`, and while there, hand back the **slot index** rather than
the global counter — `i` is what `spurs_taskset_add_task()` sets as the taskset's
bitset bit and what `spu_taskset_signal_task()` looks up, so it has to be the same
number the guest signals with.

After that the signal delivers, the task runs, the event flag wakes twice, and the
boot goes on to load NP2 / HTTP / HTTPS, open the audio port, start it, and spawn
`Dare::StreamUpdater`, `Dare::AudioRenderer` and `Dare::HLPLoadingManager`.

### Blocker 5 (current) — the audio SPU jumps into code that was never in the ELF

```
[spu] img=2 branched into unlifted LS 0x33190 (lr=0x05F50) -- ending the job
[spu_workload] async image=2 RETURNED rc=0 (job ran to completion, did not loop)
```

Local store `0x33190` is 209,296 — far past the 67,220-byte image. The MultiStream
audio runtime (`cellMSDSPLoadDSPFromMemory` is right there in the binary's symbols)
**DMAs its DSP modules into local store at runtime**. They are not in the embedded
ELF, so nothing lifted them, and the task falls out of its loop the moment it
branches into one.

Downstream of it, and therefore not separate problems: `Dare::AudioRenderer` and
`Dare::HLPLoadingManager` both exit immediately, a later `_SendSignal` has nothing
alive to receive it, and loading never completes — which is why the renderer has
submitted zero packets so far.

Next: capture the DMA'd overlays at the moment they land in LS and lift them the
way `SPU_DUMP_MISS` captures raw SPURS job images.
