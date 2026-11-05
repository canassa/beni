## 2026-11-05 18:45 CET — browser-inline compiles URL attributes that change

**What I did**

- #1169. `browser-inline.md` §10.5 got a dated amendment first (with pointers in §8.2 and
  `prerender.md` §4.1): a URL attribute whose value changes is a binding whose value is
  `safeUrl(v)`, and so is a constant or a baked URL whose check turns on a character outside ASCII.
- `Inline.beni` holds `safeUrl` and its pattern, the code of `browser`'s `Rt.beni` byte for byte
  (a `diff` of the two declarations is empty). No second URL policy.
- `inline.zig`: a URL hole is baked when the build can decide it, and a binding otherwise. The
  write's operand is a tagged union, a hole's value or a constant text, so every reader of a
  binding's value had to handle both. The binding, its preparation and the prerender string form
  write `safeUrl` of the value.
- Fixtures: `browser/inline/SafeUrl` (the `dom` page's URLs in a changing `href`, plus two baked
  ones), `DynamicLink` (routing links in the view, a helper and an eager arm), `SafeUrlConstant`
  (non-ASCII constants decided by the runtime), `LinkPiece` (URL bindings in another module's
  markup), `browser/prerender/SafeUrl` and the golden `emit/release/inline/DynamicUrl`. Each is
  refused on master.

**What I learned**

- The write-set pass bakes an attribute only when the hole is exactly a model path whose `init`
  value is a string (`Writes.zig` `finishHoles`). `"/archive/" ++ model.archive` is a binding even
  when no key writes it; `model.archive` is baked.
- Release inlines `safeUrl` into its one use, so only the pattern ships: a page with one changing
  `href` pays 75 B brotli over the same binding on `class` (504 → 579). A page without one is the
  same file as on master.
- `zig build test-blackbox -Dcorpus=…` still runs every other black-box file. To bless one fixture,
  use `zig build test-blackbox-corpus -Dcorpus=…`.
