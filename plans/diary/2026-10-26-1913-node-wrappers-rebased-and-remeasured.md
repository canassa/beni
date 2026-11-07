## 2026-10-26 19:13 CET — node wrappers: rebased and measured again

**What I did.** #912 (the `node` thin wrappers in beni, #877), after its review: `Node.done` is its own
literal (F1), `backend.md` §15.6 says what the `run/Markup*` programs gain (F2), the counts are the
measured ones (F3), the plan quotes the reviewer's speed medians (F4), the stale `Node.js` references
are gone (F5), #924 holds F6. Rebased onto master `cb7bc51a8` (ownership v2 landed in between);
the conflicts were release goldens and run hashes only, taken from master and regenerated. Measured
again with both compilers: 642 node lines, −15 379 B brotli (−1.14 %), 625 smaller, 5 equal, 12
larger (11 programs by 1–17 B, `bench/corpus` by 44 B) at fewer raw bytes; the 19 pages and apps
unchanged; the floor 184 → 128. The owner's answer to `runtime-in-beni-q1` is still open.

**What I learned.**
- `bench/size.mjs` now writes `"page": true` with a `name`, where a page line's `page` was its name;
  a compare script keyed on `o.page` gets `true` for every page and falls over on the first
  `startsWith`. Key on `program`, then `page === true ? name`.
- A heavy chain whose first steps switch branches must be followed by a chain that does not: once
  the compilers are built and the sizes measured, bless, gates and run hashes run alone, and the
  tree stays on the pull request's branch the whole time.
- `Node.done` as a literal pays at the floor (−48 B of the −56) and in every program whose `main`
  is `done`; a value whose body is a call into a function that nothing else reaches ships that
  function.
