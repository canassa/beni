## 2026-11-11 14:44 CET — Helper branches and class lists on browser-inline

**What I did**

- Lane `beni-markup` of the page port: the owner's item 1, two S1 completions, each its own
  issue and pull request, stacked on the browser base's top branch until #2464 is merged.
- #2498: a view helper whose body is a `case`/`if` of element-or-`<></>` arms compiles — the
  helper's context holding the branch's eager `when`s (`browser-inline.md` §8.4, amended;
  interface 1.30, `Callee.Refusal.branch`). `HelperCase`, `HelperCaseTwice`, the two refusals.
- #2499: a class list that changes compiles — constant `True` entries baked, each changing
  entry a `toggle` through the runtime, in entry order (§8.2, *A class list*; `prerender.md`
  §4.1). `ClassList` as a page, a prerendered page and an emit golden; `ClassListValue`,
  `ClassListNames`; `StringClassList` withdrawn.
- Opened #2500: the root plan makes an empty bucket, and ships `passes`, for a view helper's pure
  argument group (45 B brotli of `HelperCase`; `ViewHelper`'s `i[0][0]` on master).

**What I learned**

- A transcript must be one in happy-dom and Chrome. `classList.toggle(name, false)` on a node
  with no class writes nothing in the DOM Standard, but happy-dom runs the update steps and
  leaves `class=""`; so the toggle's compare is the runtime's (`classList.contains`), as every
  binding's compare is. The first design text said the DOM was the compare; the bless showed it.
- A hole whose value calls a helper has its own facts on the path outside the call; once the
  call's frame has extended the path, `programHole` on that hole finds nothing. Read the hole's
  facts before entering, then enter.
- Once the call's frame is on the path, `chainOfRef` reports the callee recursive, so the branch
  of a call-bodied helper is read from the frame (`Chain.branch`), not resolved again.
- The pass records a selector only for a hole whose value is a `case` written there; a call
  hole keeps its whole group. Exact, a few comparisons more per pass.
- This Mac cannot build beni: a `.zig-cache` is 13–17 GB per worktree. Probes with the base
  stack's binary; every build and test on dagon, synced by pushing refs into the owner's repo
  there and detaching a worktree of my own at them (fish is dagon's login shell: wrap remote
  commands in `bash -c`; `pkill -f` with a pattern that appears in the ssh command kills the
  ssh).
