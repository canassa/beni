## 2026-09-27 — R8e: deep-safe comparisons, cheaper than before

**What I did**

- The reviewer's alternatives to R8d's shape: a derived function's tail self-call is a loop, so
  list-like types need no depth or twin at all; types whose depth-taking calls are all in tail
  position (`Maybe`, `Result`, wrappers) only forward the depth; one runtime file,
  `_core/_derived.mjs`, is written only when imported, replacing the per-module engines, and
  `core/List.js` is back to its pre-R8d bytes.
- Against e86883a (before R8d): user lists 51–61 % faster, trees 11–15 % faster, a rose tree
  through `List` 3.5 % slower (the one real remaining cost); release brotli +1.1 % across 164
  programs (R8d was +2.5 %), 144 of them byte-identical in dev. A 5.2 M-line ordered-log fuzz
  matched e86883a exactly. All seven steps green.
- Owed: the dev and `--release` copies of the runtime are kept in step by hand, tied only by the
  `run/` corpus running both.

**What I learned**

- The loop form beat both the old recursive code and the stack-safe version: removing the
  problem's cause (recursion on a tail) was better than managing it.
