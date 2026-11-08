## 2026-11-08 00:43 CET — Adopt the WebGPU contract

**What I did.** Turned `docs/design/webgpu.md` from a proposal into the adopted contract (#2238).
Recorded the owner's decisions of 2026-11-08 in §11. Wrote the handle layout of #1281 into §2.1 and
the generated inputs and their pin into §2.2. Wrote the realm rules into §2.3, the typed lease
refusal of #1270 into §6.4, and main thread first into §2 and §10. Closed the review gaps #1266 and
#1269 (§7.1), #1267 (§8.2), #1268 (§3.1) and #1271 (§8.3). The failure ledger has the matching rows.
§10 is now a slice plan, S1–S6, with issues #2239–#2244, and performance is #2245. No code changed.

**What I learned.**
- The `webgpu.idl` in the pinned `@webref/idl` 3.86.0 archive is token-identical to the gpuweb
  `a1a1e79` extract. One archive and one Zig generator can therefore make both the native types
  and `Gpu.Types`.
- Static dispatch cannot reach the GPU operations under the acyclic `Gpu.Handle` layout. The type's
  module, generated or `Gpu.Handle`, cannot import the descriptors or the engine. The consequence
  is qualified calls and `▷`, not a language change.
- Without task identity, the only lease rule that cannot deadlock refuses every ordinary call on
  a leased device, from any fiber. Letting unrelated fibers wait needs a fiber-scoped slot in
  core. That decision belongs to the owner.
- The shipped-`Browser.Host` staleness test runs in `test-native-bindings`, not in the gates. The
  GPU files need a gated check.
