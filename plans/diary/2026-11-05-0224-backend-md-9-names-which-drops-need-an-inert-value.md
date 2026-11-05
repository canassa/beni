## 2026-11-05 02:24 CET — backend.md §9 names which drops need an inert value

**What I did**

I fixed one sentence in `docs/design/backend.md` §9, slice 8, item 2 (*Amended 2026-10-15: a record field's lambda*), for #250. The sentence said that item 1's drop of a local binding needs an `inert` value. It does not. Now the text says that `dropKeys` drops an unread key when its value is `inert`, and that the pass drops an unread top-level binding only when its value is `inert` (`Spec.candidate`). Item 1 drops an unread local binding unless `Lower` kept its initialiser. The rule still asks an `inert` value of a local binding, because slice 9 can move its initialiser into a key. No code changed.

**What I learned**

- Item 1's zero-use drop (`Opt.list`) has no `inert` test. It keeps a binding only when it is in `keep`, when a fold pinned it, or when it holds an in-place record store (`JsIr.holdsStore`).
- `dropKeys` asks `effectFree`, not `inert`. `effectFree` accepts an `inert` value, a safe chain and a pure call. So "only an `inert` key goes" is too narrow. The new text says "when", not "only when".
- `soleCalls`'s comment (`src/js/Spec.zig`, at the `.property` prong) already gave the correct reason. The document had a wider claim than the code.
- The edited lines of `backend.md` had no non-ASCII bytes. I wrote the new text in ASCII only, so it adds no mojibake before #886 lands.
