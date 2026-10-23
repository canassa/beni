## 2026-10-23 06:07 CEST — Renderer independent entry rows

**What I did**

Completed the ownership-checker half of #319 after O2 #842 merged. The
entry word always selects the direct protocol. Removed the template row,
platform refusal cause and message prose, and unused per-module renderer
selection metadata. Ownership summary rule version 35 invalidates cached
reports from the previous rule. Enforcement scope remains a separate concern.

Added three red-first full-report comparisons for Tea, Browser.program and
Browser.hosted; made Page's existing test check entry acceptance without the
flag. Existing hosted sharing refusals remain. Entry tests, the complete
ownership corpus, cache tests, typekeys and repkeys pass. An independent audit
proves exactly 284 former platform lines in eleven goldens changed to their
entry-row verdict, with no other demand, summary, cause or pending change.
Nine fixture comments keep their original line counts. Updated the normative
entry sections and the developer skill. No runtime or emitter source changed.

**What I learned**

The template row did not change entry analysis: it overwrote an already
accepted demand at the last reporting step. Removing that override preserves
all actual sharing checks. A boolean entry marker carries all remaining
information; manifest flags and per-module list mode no longer belong in the
ownership input. The cache rule version must move even though serialized
summary structure is unchanged, because an old private report can retain a
platform refusal. Builds and tests ran only on dagon; no measurements.
