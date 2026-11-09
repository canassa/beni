## 2026-11-09 16:02 CET — make Binary scalar access fast, and propose regions and bulk operations

**What I did.** Rewrote `core/Binary.beni`'s scalar path with no contract change: sharedness
now comes from ES2024's `detached` (ArrayBuffer) and `growable` (SharedArrayBuffer) getters,
the throwing brand check runs only on a host with neither, and a scalar access never asks,
builds no record and reuses a DataView view. New fixture `run/BinaryAccessCost` counts the
brand getter's calls and DataViews made (master 4001/2001 per 2000 accesses, now 0/1) and
proves an older host still tells the kinds apart. The 1024² texture went from 2.6–3.2 s to
0.41–0.45 s in Chrome on a normal page, 50 s to 0.42 s on an isolated page, 74–84 s to
0.8–0.95 s on Node 24. Then specified binary.md §6 (checked regions), §7 (bulk operations)
and §8 (eight choices for the owner); not built.

**What I learned.** The throwing brand check cost far more where `SharedArrayBuffer`
exists (Node, isolated pages: ~75 s) than on a normal page, so the investigation's normal-page
number understated the defect. On macOS, zorg's `--watch -fincremental` panics
(`TODO(MachO2): load archive`); a one-shot build takes about 75 s. `build --library
--release` printed `export{l}` for `Surface.generate`, worth a look of its own.
