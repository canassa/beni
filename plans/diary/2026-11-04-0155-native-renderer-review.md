## 2026-11-04 01:55 CET — Native renderer review follow-up

**What I did**

Built exact base d853ad81e3 and PR head1dce2894a8 on dagon, then compiled TodoMVC and WorkerNativeAdapters in development and release under the shared lock. Compared complete output inventories and bytes. TodoMVC development changes only Document.mjs.map and its manifest entry (86 files); WorkerNativeAdapters changes only EventTarget.mjs.map and its manifest entry (35 files). Every .mjs/.js is byte-identical. Both complete release trees are identical (3 and5 files respectively).

The changed maps differ only in sourcesContent, which matches the respective core native source files exactly. Encoded mappings, generated/original positions, names, sources and all other map fields are identical. The embedded source changes are the new imports and preceding renderer declarations. Evidence and reproduction scripts are saved under ~/worktree-evidence/wd-dom-native/review/.

Corrected the boundary contract to permit core and any checked platform package, with allowed=window limiting execution to the Window/page realm. Chose the smaller documentation-only option for rendererBody: calling before document.body exists violates its precondition and is a defect. No runtime check or emitted-code change.

**What I learned**

These foreign binding modules embed their complete beni source in their maps even when their emitted declarations and mappings stay unchanged. That explains the development-only run-hash drift; it is not a JavaScript regression or a changed mapping position.
