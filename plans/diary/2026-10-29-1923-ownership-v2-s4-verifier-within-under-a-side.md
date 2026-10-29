## 2026-10-29 19:23 CET — ownership v2 S4-verifier: within holds under a side of its pair

**What I did**

- Round 3 of #1189's review. A `within` cell now has to be under one of the pre-fold pair's sides.
  The invocation-only bit is computed over the answer and allocation labels the fold merges; splits
  are certified by the traversal marks.
- Modeled List.map's read-off faithfully in the C.6 control. It stays accepted, and for the right
  reason: mapHelp allocates nothing at `ι_m`, so the only answers folded into `ι_m⋆` are the pair's.
- `prefixWithin` made before its callee's provenance now waits for it. The `env` text is corrected:
  a capture becomes `⊤`.
- Attacked the rule before pushing: a nested call inside a side, a helper's own allocation, a second
  pair at another depth, and sides under different prefixes.

**What I learned**

- "Agrees down to the parting depth" was still too weak. A call inside the same prefix as one side,
  but not under it, was never compared with the other side.
