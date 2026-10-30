## 2026-10-30 01:05 CET — Embed text files at compile time

**What I did**

Implemented issue #1275 on Dagon: `import "./shader.wgsl" as shader : String`.
Specified strict UTF-8 preservation, source-relative paths, private ordinary String
values, diagnostics, embedded packages and the frontend/check cache split.
Extended parsing, formatting, lowering and frontend artifact version 28. The
session reloads assets after storing syntax artifacts; checked keys include their
contents. Existing project watching receives explicit dependencies, including
missing paths. Updated the developer skill and added black-box scenarios, an
embedded platform fixture and a development/release run-corpus fixture.

Used the Debug compiler for focused iteration. Focused text, cache, watch,
layered-package and corpus checks passed. The final unfiltered `zig build gates`
passed after updating two format-width assertions and correcting a new fixture's
markup argument. Recorded the new corpus hashes and 12 scenario run hashes.
WGSL validation/minification remain separate in #1276. No runtime WebGPU work.

**What I learned**

Text assets must be loaded after the syntax cache is stored and before checked
keys are computed. This preserves warm frontend hits while avoiding stale text.
Embedded modules need their shipped asset/source tables, rather than filesystem
lookups in the app's cwd. The existing corpus source copier needed to preserve
non-module inputs beside source files. Explicit watch dependencies also preserve
the distinction between imported assets and unrelated files with the same suffix.
