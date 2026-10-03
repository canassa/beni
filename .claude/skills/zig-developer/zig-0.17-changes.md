# Zig 0.16 → 0.17

Condensed from the [0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html). Use the installed 0.17 standard library for exact signatures; the bundled language reference describes 0.16.

## Language

- `@bitCast` now reinterprets logical bits, independent of endianness. Array/vector casts can silently change meaning; audit them. `extern struct`/`extern union` casts are rejected; use `@ptrCast` or an `extern union` to reinterpret memory. Casting to an enum checks for invalid tags.
- `@backingInt`/`@fromBackingInt` replace deprecated `@intFromEnum`/`@enumFromInt`; they also handle explicitly integer-backed bitpacks, and `@backingInt` handles tagged unions. `std.meta.BackingInt` gives the backing type. Empty enums must use `noreturn` backing integers. `zig fmt` migrates the old builtins.
- Added `@divCeil` and SPIR-V-only `@SpirvType` (samplers, images, sampled images, runtime arrays). Removed array repetition `a ** b`; use `@splat` with a result type.
- `@hasDecl` sees only public declarations, even within the declaring file. Comptime-length slices can be dereferenced or coerced to array pointers.
- Replace `void{}` with `{}`. `errdefer |err|` capture and primitive `i0` are gone (`u0` usually replaces `i0`). `std.lang.GlobalLinkage` dropped `internal` and `link_once`; omit `@export` or use `weak`, respectively.
- `@cImport` is removed. `std.Build.Step.TranslateC` is deprecated; use the separate `translate-c` package. The formal grammar is now checked against the parser by fuzzing.

## Standard library

- `std.builtin` is deprecated in favor of `std.lang`. `std.lang.OptimizeMode` → `Optimize`, with tags `.debug`, `.safe`, `.fast`, `.small`; prefer `Optimize.runtimeSafety` over `std.debug.runtime_safety`. `@import("builtin").{cpu,os,abi,object_format}` is deprecated; use `.target.{cpu,os,abi,ofmt}`.
- Struct/union `@typeInfo` uses parallel arrays such as `field_names` and `field_types`, rather than `fields`. `std.meta.fieldInfo`, `fieldNames`, and `fieldTypes` are deprecated.
- `std.heap.StackFallbackAllocator` is no longer size-generic: pass an aligned buffer to `.init(buffer, fallback)` and call `.allocator()`. New thread-safe `std.heap.SafeAllocator` replaces deprecated `DebugAllocator`/`Check`; its `deinit` frees backing storage and reports leaks. `memory_pool.AlignedManaged`/`ExtraManaged` became `Aligned`/`Extra`.
- `ArrayList.getLastOrNull`/`getLast` → `last()`/`last().?`; new `lastPtr()` returns `?*T`. List pointer stability checks are stronger. `debug.SafetyLock` adds `lockShared`/`unlockShared`; `DoublyLinkedList.pop` → `popLast`.
- `std.fmt.allocPrint(allocator, ...)` → `allocator.print(...)`. `{q}` preserves UTF-8; `{qf}` quotes formatted output. ZON parsing now takes an options struct and a result arena; `fromSliceAlloc` → `fromSlice`, old `fromSlice` → `fromSliceNoAlloc` (similarly for other `from` methods), and `updateFrom*` methods update existing values.
- Bit sets: `IntegerBitSet` → `bit_set.Integer`, `ArrayBitSet` → `bit_set.Array`, `StaticBitSet` → `bit_set.Static`, `DynamicBitSetUnmanaged` → `bit_set.Dynamic`; managed dynamic sets are deprecated. Empty/full constructors are now `.empty`/`.full`, including `enums.EnumSet`.
- `std.gpu` → `std.spirv`, with image helpers. `std.Target.parseCpuModel` returns an optional. Added `Io.Semaphore.waitTimeout`, `f128` `@exp`/`@exp2`, and `fs.path` appending variants of `relative`/`resolve`; `hash.crc` names were reorganized.
- Removed `ascii.indexOfIgnoreCase*` (use `findIgnoreCase*`), `mem.containsAtLeastScalar2` (use `containsAtLeastScalar`), and packed-int `Native`/`Foreign` readers/writers (use `readPackedInt`/`writePackedInt`). `mem.eql`/`findDiff` on float slices now respect NaN even when both slices point to the same memory. `Uri.getHost` → `net.HostName.fromUri` with different validation/errors; `getHostAlloc` is removed.

## Build and package APIs

- `zig build` splits configuration (`build.zig`) from execution (the cached maker), serializes the graph, and can skip configuration. `--print-configuration` emits ZON. Custom build runners are gone; `--listen=-` exposes a build server protocol. This protocol did not yet restore ZLS functionality at 0.17.0 release.
- `b.build_root` → `b.root` (`Path`, not `Directory`); declare configuration inputs with `dependOnFileContents`, `dependOnFileMetadata`, `dependOnDirectoryContents`, or `dependOnDirectoryMetadata`. Untracked configuration side effects poison its cache; `--cache-poison` controls that. The cache now tracks directories/metadata, uses a binary manifest, and offers `zig cache-cat`.
- `b.args` is gone: use `Run.addPassthruArgs()`; configure code can no longer inspect run arguments. `Fmt` paths/exclusions are `LazyPath` lists (`b.pathList`). `Step.Options` separates file, directory, and untracked paths via `addOptionPath`, `addOptionPathDirectory`, and `addOptionPathUntracked`.
- `findProgram` resolves immediately and poisons the configuration cache; `findProgramLazy` resolves at make time. `dependency` handles lazy dependencies, and `dependencyLazy` returns `error.LazyDependencyNeeded` rather than `null`. `LazyPath.getDisplayName` → formatting with `{f}`; `basename` is removed. `ConfigHeader.Options.include_guard_override` → `include_guard`.
- `Run` argument helpers (`addArtifactArg`, `addOutputFileArg`, `addFileContentArg`, `addOutputDirectoryArg`, `addDirectoryArg`, `addDepFileOutputArg`, `addFileArg` and their prefixed/decorated forms) converge on their `*Arg2` counterparts.
- Package management moved from the compiler into the build system. `--pkg-path`/`ZIG_LOCAL_PKG_DIR` now apply to fetch and build; `zig fetch --save` also populates the local package path, while `zig build` fetches locally. On Windows/Wine, Run step DLL `PATH` setup now considers only argv[0]. Win32 resource build APIs are deprecated pending the separate `rc` package.

## Compiler, targets, and tools

- `-fincremental --watch` is usable for most `x86_64-linux` projects with the new ELF linker. The new ELF linker gains x86-64/SPARC64, libraries, symbols/relocations, DWARF, and mostly reproducible output, but is still opt-in except with incremental builds. COFF linking now handles objects, archives, import libraries, TLS, COMDAT, GNU/MSVC libc, and DLL imports. SPIR-V linking was rewritten for incremental builds and external `.spv` objects; linker tests now use objdump snapshots.
- SPIR-V codegen is multithreaded; execution modes come from calling conventions, with new task/mesh shader conventions; capabilities/extensions move from assembly to `-mcpu`. A LoongArch64 self-hosted backend started but is not usable yet. The WebAssembly self-hosted backend passes the behavior suite but lacks debug info.
- Added/expanded targets: usable SPARC64; `loongarch32-linux-gnu[sf]`; early Xtensa Linux; x32/N32 ABIs; listed console targets; C-backend ARC/CSKY/M88K; no-libc MicroBlaze/SH/SPARC. Native CPU detection and several baseline CPUs changed. PowerPC requires IEEE `long double`; `powerpc-linux-gnueabi[hf]` and big-endian `powerpc64-linux-gnu` were dropped. Explicit ABI target triples no longer infer a native libc version. ARM32/SPARC stack traces and AArch64 pointer-auth unwinding are supported.
- LLVM/Clang 22.1.8; loop vectorization remains disabled. Bundled libc/header levels: musl 1.2.5, glibc 2.44, Linux 7.2, macOS 27.0, NetBSD 11.0, OpenBSD 7.9, plus updated MinGW-w64. Some musl/MinGW/WASI functions now come from Zig libc. In `libc.txt`, `gcc_dir` → `cc_dir`, required on Linux.
- New `zig objdump` inspects headers, symbols, imports/exports, relocations, TLS, and archives, with redaction for snapshots. `zig fmt --complexity` reports token and AST-node counts. The integrated fuzzer has no direct changes.
