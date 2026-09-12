# Memory & performance strategy (Zig 0.16)

> Copied from unmaker86 (zdos); written for an emulator, adopted by lar as
> doctrine. Where it says "emulator", read "long-running daemon" — lar goes
> further: steady-state ZERO allocation (see SKILL.md). Emulator-specific
> examples (decode loops, video) are illustrative, not lar subsystems.

How to manage memory and lay out data in a long-running program. The wrong default —
`allocator.alloc`/`free` per operation — is slow, error-prone, fragmenting,
and cache-hostile. This guide is the right default.

Synthesized from: the Zig 0.16 stdlib source (`references/zig/lib/std/`), the Zig compiler's own
practice (`references/zig/src/`), the three reference emulators (dosbox-x, dosbox-staging, spice86),
TigerBeetle's TIGER_STYLE, and Andrew Kelley's *"A Practical Guide to Applying Data-Oriented
Design"* talk. Citations at the bottom.

---

## TL;DR — the rules

1. **CPU is fast, memory is slow.** A cache miss to DRAM costs ~60–270+ cycles — more than 100
   arithmetic ops. Hot loops are memory-bound; **layout, not instruction count, sets the speed.**
2. **Don't alloc/free per op.** Allocate up front; in steady state the hot loops should do **zero**
   `alloc`/`free`. (TigerBeetle: all memory static after init.)
3. **Two-allocator discipline.** One long-lived `gpa` for emulator-lifetime state; short-lived
   **arenas** for transient/per-frame work, reset (not freed) each frame.
4. **"Where there is one, there are many."** For the *many* (device/timer/scheduler tables), make
   each element **smaller**: smallest int types, **indexes instead of pointers**, struct-of-arrays
   to kill padding. Kelley measured a **39% wall-clock reduction** in a real project just from
   halving object sizes.
5. **The one (the CPU register file) stays compact AoS, register-resident.** DOD targets collections,
   not singletons.
6. **Measure, don't guess.** `perf stat` cache-misses / branch-misses / IPC against the `bench/` harness.

---

## 1. The allocator model

Zig has **no global allocator and no hidden allocation**: anything that may allocate takes an
explicit `std.mem.Allocator`. The interface is a type-erased fat pointer (`ptr: *anyopaque` +
`*const VTable`) — `references/zig/lib/std/mem/Allocator.zig`. The load-bearing consequence: the
*caller* picks the strategy. The same code can be backed by OS pages, a stack buffer, an arena, or a
pool — so we choose a different discipline **per subsystem** without changing the consuming code, and
inject a checking allocator in tests vs a fast one in release.

⚠️ 0.16: the vtable has **four** methods — `alloc`/`resize`/`remap`/`free` (`remap` added in 0.14) —
and alignment is `std.mem.Alignment`, **not** a log2 `u8`. Pre-0.14 tutorials are wrong.

## 2. Allocator catalog (0.16)

All in `references/zig/lib/std/heap/`. Read the source before using.

| Allocator | Cost / behavior | Use for |
|---|---|---|
| `std.heap.DebugAllocator` ⚠️ (was `GeneralPurposeAllocator`) | Slow & wasteful **on purpose**: stack traces, double-free + leak detection, never reuses addresses. | Debug builds & tests. Assert no leaks. Never the hot path. |
| `std.heap.smp_allocator` | The general **release** allocator; per-thread freelists; singleton; matches glibc malloc. | The ReleaseFast root allocator everything is built on. |
| `std.heap.ArenaAllocator` | Allocate-many / free-once; `alloc` ≈ bump; `free` ≈ no-op; `deinit`/`reset` frees all. | Phased lifetimes: per-frame scratch, boot/config parse. See §3. |
| `std.heap.FixedBufferAllocator` | Pure bump over a caller `[]u8`; **zero heap**; full ⇒ `OutOfMemory`. | Bounded scratch with no OS calls (decode/format buffers). |
| `std.heap.page_allocator` | Whole OS pages; coarse, slow per call; thread-safe. | Backing for arenas/pools; **the one big guest-RAM block**. |
| `std.heap.c_allocator` | libc malloc wrapper (needs libc). | C device-lib interop. |
| `std.heap.MemoryPool(T)` | Free-list of fixed-size slots; O(1) `create`/`destroy`, **reuses** memory; `initCapacity(n)`, `growable=false` for a hard cap. | Churny same-type objects (events, IRQs, recompiled blocks). |

⚠️ **`std.BoundedArray` is removed in 0.16.** Use a fixed `[N]T` + `len`, or `ArrayList` +
`initCapacity` + `*AssumeCapacity`. (Single most common stale-tutorial trap.)
⚠️ **`std.ArrayList` is unmanaged by default** — methods take the allocator per call;
`ArrayListUnmanaged` is now a deprecated alias.

> Evidence from the Zig compiler: it uses **only** `gpa` + `ArenaAllocator` (per-task, reset/deinit).
> `MemoryPool` has **zero** usages in `src/` — reach for it only when you have real create/destroy churn.

## 3. The arena pattern (workhorse for phased work)

```zig
var arena = std.heap.ArenaAllocator.init(backing); // backing = page_allocator / smp_allocator
defer arena.deinit();                              // frees the WHOLE graph at once
const a = arena.allocator();
// hundreds of a.alloc / a.create — no per-object free(), no use-after-free surface
```

Two wins at once: (1) removes free() bugs by construction — the whole phase dies at `deinit`; (2)
throughput — `alloc` is a bump after the first chunk.

**Per-frame idiom — `reset(.retain_capacity)`** (`heap/ArenaAllocator.zig`): keeps one preheated
buffer sized to the prior peak. The source: *"after the biggest operation, no memory allocations are
performed anymore."* Amortizes to **O(1)**.

```zig
var frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer frame_arena.deinit();
while (running) {
    const fa = frame_arena.allocator();
    renderFrame(fa, ...);                 // dirty rects, scanline temps, audio mix
    _ = frame_arena.reset(.retain_capacity); // zero OS calls in steady state
}
```

This is exactly the compiler's per-analysis-unit pattern (`src/Zcu/PerThread.zig`) and gives dynamic
ergonomics with static steady-state behavior.

## 4. Avoiding per-op churn in hot loops

- **Preallocate + `*AssumeCapacity`** — reserve once, assert thereafter (bugs become panics, not
  silent reallocs):
  ```zig
  var list: std.ArrayList(Event) = .empty;
  try list.ensureTotalCapacity(gpa, max_events); // ONE allocation up front
  list.appendAssumeCapacity(ev);                 // hot loop: provably no allocation
  ```
- **Fixed-capacity arrays** (the `BoundedArray` replacement): `struct { buf: [16]u8 = undefined, len: u8 = 0 }` — device FIFOs, x86 prefetch queue.
- **Object pools**: `std.heap.MemoryPool(T)` with `initCapacity` — O(1) reuse for churny same-type objects.
- **Ring buffers**: `std.RingBuffer` (or power-of-two mask) for audio/serial streams — one alloc, index math after.
- **Hoist scratch** out of the loop (a subsystem field, or a `FixedBufferAllocator` reset per iteration).

## 5. Data-Oriented Design & cache (make each thing smaller)

Cache facts: line ≈ **64 bytes** (the unit of DRAM transfer — you never load "an int", you load its
line); miss ≈ 60–270+ cycles; **pointer chasing** is the worst case (data-dependent loads the
prefetcher can't predict); linear array scans are ideal.

⚠️ Corollary: **math can be faster than an L1 read** (Kelley: multiplication beats an L1 load). So
**don't memoize cheap computations** — recomputing line/column or a token's end position is cheaper
than the cache pressure of storing it. *"Stop memoizing stuff — I can calculate that."*

Kelley's thesis: *"identify where you have a lot of the same thing in memory and make the size of each
thing smaller."* His measured results (the "monster" toy examples, then the real Zig compiler):
- indexes instead of pointers: monster 24 B → 12 B; 100 monsters **2.4 KB → 1.2 KB**;
- array-of-structs → struct-of-arrays: 10,000 monsters **160 KB → 91 KB** (kills per-element padding);
- sparse field moved to a hashmap: 10,000 monsters **366 KB → 198 KB**;
- **real compiler**: token **64 B → 5 B**, AST node **120 B → 15.6 B avg** ⇒ **22% faster** parsing;
  then ZIR instruction **54 B → 20.3 B avg** ⇒ a further **39% wall-clock reduction** on top.
- *"If you do the tricks, you will get faster code."*

### Techniques

**(a) Indexes/handles, not pointers.** Replace `*T` (8 B) with a `u32` index into the owning array.
Half the size, prefetcher-friendly (`arr[handle]` is predictable), **survives realloc and save-state
serialization** (a raw pointer dangles), and is bounds-checkable. Use a strong type and a sentinel
for "none":
```zig
const DeviceId = enum(u32) { none = std.math.maxInt(u32), _ }; // 4 B, not interchangeable with int
```
⚠️ Kelley's caveat: you lose pointer type-safety — use a named `enum` handle, not a bare `u32`.

**(b) Struct-of-Arrays via `std.MultiArrayList`** (`references/zig/lib/std/multi_array_list.zig`):
one backing allocation, each field its own column, **fields ordered by descending alignment ⇒ zero
inter-field padding**. A loop over one column reads only that column's bytes — every cache line 100%
useful. This is the compiler's default for the AST/ZIR/AIR.
```zig
const Device = struct { io_base: u16, irq: u8, enabled: bool, cycles_owed: u64 }; // AoS pads to 16 B
var devs: std.MultiArrayList(Device) = .empty;
defer devs.deinit(gpa);
try devs.ensureTotalCapacity(gpa, 256);
devs.appendAssumeCapacity(.{ .io_base = 0x3F8, .irq = 4, .enabled = true, .cycles_owed = 0 });
const bases = devs.items(.io_base);  // []u16 — tight, no padding pulled in
var s = devs.slice();                // compute per-field pointers ONCE when touching several columns
const on = s.items(.enabled); const owed = s.items(.cycles_owed);
```
Wins when N is large and hot loops touch a *subset* of fields. **Doesn't** win for small N, loops
touching all fields together, or when you need a `*T` to a whole element (SoA `get`/`set` copy).

**(c) Shrink fields.** Smallest int that fits (`u8`, `u3`…); `enum(u8)` tags; `packed struct(uN)` for
hardware flag/status registers; `extern struct` field-ordered largest-alignment-first for
memory-mapped layouts. **Lock layouts** with `comptime { std.debug.assert(@sizeOf(T) == N); }` so a
future field that re-bloats the struct fails the build (TigerBeetle practice). Tools: `@sizeOf`,
`@alignOf`, `@offsetOf`, `@bitSizeOf`.
```zig
const Flags = packed struct(u16) { cf: bool, _1: u1, pf: bool, _3: u1, af: bool, _5: u1,
    zf: bool, sf: bool, tf: bool, ifl: bool, df: bool, of: bool, _hi: u4 }; // exactly 2 bytes
```

**(d) Dense-integer-keyed tables → plain arrays, not hash maps.** Interrupt vectors, I/O port →
handler, opcode → handler: index a plain array by the integer. Most cache-friendly possible; skip
hashing. If you *do* need a map and **iterate it often**, prefer `std.ArrayHashMap` (contiguous,
insertion-ordered, ~10× faster iteration) over `std.HashMap` (lookup-optimized, scattered buckets).

**(e) Booleans out of band.** Don't store a partitioning flag in the struct — encode it by *which
array the object lives in* (e.g. alive vs dead). The flag's byte vanishes, and the hot loop drops both
the branch (`if (m.dead) continue;`) and the load. (Kelley: *"the answer I didn't understand when I
first watched Acton's talk."*)

**(f) Sparse data → side hashmap.** If a field is empty/default for most elements, remove it from the
struct and store it out of band keyed by index. Tailor the split to the *observed* distribution (e.g.
keep the common 1-item case inline, special-case the rare 4-item case). This is where the 366→198 KB
win came from.

**(g) Encodings instead of one canonical representation.** A tagged union sized for the largest
variant wastes space when variants differ wildly (his "humans vs bees"). Define multiple **encodings**
of the same concept: fold distinguishing booleans/enums into the *tag*, and repurpose an index field
per-tag to point at variant-specific data out of band. This is how compiler nodes hit ~15.6 B avg.
The byte cost then depends on your data distribution — which is the point: encode for *your* reality.

**(h) Hot-loop control flow.** Batch work; scan arrays linearly; keep cold fields out of hot lines;
group/sort by tag to cut branch mispredicts; `@Vector(N,T)` SIMD where a column is contiguous (SoA is
the prerequisite). Extract hot loops into free functions taking primitive slices
(`fn step(opcodes: []const u8, regs: []u16)`), not methods.

## 6. Measure

```
perf stat -e cache-misses,cache-references,LLC-load-misses,branch-misses,instructions,cycles ./zdos ...
```
Watch miss rate, **LLC-load-misses** (the expensive DRAM trips), branch-misses, and **IPC** (low IPC
+ high cycles ≈ memory-bound stalls). `perf record`/`report` to attribute to source; `perf c2c` for
false sharing. Optimize by **frequency × cost** — a miss in the per-instruction loop dominates; the
same miss at boot is irrelevant. Benchmark before/after with `bench/`.

## 7. zdos subsystem decision table

| Subsystem | Looks like | Use | Why |
|---|---|---|---|
| **Guest RAM** (~1–16 MB, fixed) | one big block, whole-process life | `page_allocator.alignedAlloc(u8, .@"4096", total)` **once** at startup; index by offset | All 3 reference emulators do exactly this (one block, direct indexing, never per-op). |
| **CPU register file** | small singleton, touched every instruction | compact **AoS** struct, register-resident; `packed union { dword: u32, word: [2]u16, byte: [4]u8 }` for AX/AH/AL aliasing | "The one." Lives in L1; SoA would only add indirection. Mirrors dosbox-staging `GenReg32`. |
| **Per-frame scratch** | clear lifetime, varies | `ArenaAllocator` + `reset(.retain_capacity)` per frame | Convenient API, zero free() bugs, zero steady-state allocation. |
| **Boot/config/BIOS parse** | one-shot, throwaway | `ArenaAllocator`, `deinit` after init | Allocate-many-free-once. |
| **Device/timer/scheduler tables** | many, scanned in hot loops, referenced by id | `MultiArrayList` SoA + `enum(u32)` handles + small fields | SoA cache win; handles shrink refs & survive save-states. |
| **Dispatch/lookup tables** (IVT, port→handler, opcode→handler) | dense integer key | **plain array** indexed by the int | Most cache-friendly; no hashing. |
| **Device FIFOs / prefetch queue** | tiny fixed max | fixed `[N]u8` + `len` | Inline, zero alloc (`BoundedArray` is gone). |
| **Streaming audio / serial** | producer/consumer | `std.RingBuffer`, allocated once | Index math only. |
| **Deferred IRQs / scheduled events** | churny same type | `MemoryPool(Event)` + `initCapacity` | O(1) create/destroy, memory reused. |
| **Disk/file I/O staging** | bounded, no heap on fast path | `FixedBufferAllocator` over `[N]u8` | No OS calls; full ⇒ explicit `OutOfMemory`. |
| **Root / debug & test** | base allocator | `DebugAllocator` (debug/test) / `smp_allocator` (release) | Leak detection while developing; fast in release. |

**Overall architecture:** root = `DebugAllocator` (debug) / `smp_allocator` (release). Allocate guest
RAM + all fixed device buffers from it **once**. Give the render loop a frame arena reset per frame.
Use `MultiArrayList`/`MemoryPool` for iteration-heavy / recycling structures. After boot, hot loops
do **zero** alloc/free — verify in debug with a counting wrapper allocator that panics on alloc
during a frame.

## 8. 0.16 version traps (verified against the in-repo source)

- `BoundedArray` **removed** — use `[N]T`+`len` or `ArrayList`+`initCapacity`+`*AssumeCapacity`.
- `GeneralPurposeAllocator` → **`DebugAllocator`**; 4-method vtable (`remap`); `std.mem.Alignment`.
- `std.ArrayList` is **unmanaged by default**; allocator passed per method.
- Confirm any `std.*` signature in `references/zig/lib/std/` before relying on it.

---

## Sources

Primary / authoritative:
- Andrew Kelley, *A Practical Guide to Applying Data-Oriented Design* (Handmade Seattle 2021) —
  YouTube `IroPQ150F6c`, https://media.handmade-seattle.com/practical-data-oriented-design/,
  https://vimeo.com/649009599. (Transcript mined directly for the figures above.)
- Mike Acton, *Data-Oriented Design and C++* (CppCon 2014) — https://www.youtube.com/watch?v=rX0ItVEVjHc
- TigerBeetle TIGER_STYLE — https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md;
  *A Database Without Dynamic Memory* — https://tigerbeetle.com/blog/2022-10-12-a-database-without-dynamic-memory/
- Zig 0.14.0 release notes (DebugAllocator rename, SmpAllocator) — https://ziglang.org/download/0.14.0/release-notes.html
- "Handles are the better pointers" (floooh / Andre Weissflog) — referenced by Kelley as the *how* for indexes-vs-pointers.

In-repo (read directly, gold standard):
- Allocators: `references/zig/lib/std/mem/Allocator.zig`, `heap.zig`, `heap/{ArenaAllocator,FixedBufferAllocator,SmpAllocator,PageAllocator,debug_allocator,memory_pool}.zig`
- SoA / containers: `references/zig/lib/std/{multi_array_list,array_list,array_hash_map}.zig`
- Compiler practice: `references/zig/lib/std/zig/{AstGen,Ast,Zir}.zig`, `references/zig/src/{Sema,InternPool}.zig`, `references/zig/src/Zcu/PerThread.zig`
- Emulator practice: dosbox-x `src/hardware/memory.cpp`, `include/mem.h`; dosbox-staging `src/hardware/memory.cpp`, `src/cpu/registers.h`; spice86 `src/Spice86.Core/Emulator/Memory/{Ram,Memory}.cs`, `CPU/Registers/RegistersHolder.cs`
