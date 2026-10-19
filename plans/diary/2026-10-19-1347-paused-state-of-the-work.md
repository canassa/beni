## 2026-10-19 13:47 CEST — paused: the state of the work

**What I did**

The owner said "pause everything", and every agent is stopped. Local branches may carry uncommitted work in their worktrees. Resume from this list.

**Open PRs, and what each needs**
- **#436, view helpers (S1).** It needs its @claude review answered: a gap in how a helper's arguments are evaluated. Branch `inline-view-helpers`, to be squash-merged. It makes big-component build: baseline 2 068 + 92.7 B/widget against tea-inline's 1 552 + 71.8.
- **#441, #426's fix.** browser-inline's `Cmd.perform`/`Sub.on`/`Sub.map` hosted rows. Gates were running; check its review.
- **#447, the `nested` soundness fix (#446).** DIRTY: master must be merged in and the review answered.
- **#448, #427's cross-check fix plus the CI job.** DIRTY, and the review flags a gap across cell kinds. Its u16 commit duplicates master's.
- **#449, retirement PR 4.** DIRTY. Its pending `SendInPayload`/`NestedLambdaSend` copies name deleted browser-direct goldens, so drop them once #441 is in, or repoint them. PR 5 (`retire-direct-dead`, dead code) and PR 6 (`retire-direct-docs`, the docs move) are local and stacked on it.
- **#454, fix 2.** A validator run calls its worker where it stands, which removes the 48-site cliff; N=1 is 1.25× tea-inline. Its @claude review was pending. After it: T 25 → 29 (`schema.md` §6, the threshold fixtures).
- **#409, the bound-argument doc.** It needs the correction that casts through records and tuples are F2's to fold.
- **#386, the Lean oracle.** Paused by the owner. WIP `6e94d583a` on `lean-tree-marker`, not pushed.

**Local work, not yet a PR**
- **`own-remove-k`** (stacked on #447): `k` removed, compiling. It is blocked: core `Schema` (`collect`, `unpack`, `productOf`) doesn't settle without the cut, because casts through records and tuples have no fold. Next is the F2 spike: a full-type cast marker, measured against master with `k`, numbers to the owner before building (owner, 2026-10-18).
- **The records slice (#315):** #421 is merged. Next is #419 (`split-element-apart`, which promotes CK-264), then #420 (record conditions for `List.filter`/`append`/`reverse`/`sortBy`/`swapAt`). #420 must land before R4, or TodoMVC is refused at the entry. Then R4–R7.
- **S1 cuts:** one pass call per handler (about 27 B/widget), cut 6 re-scoped (each handler written at its wiring), cut 5, then the small cuts.

**Decisions taken today** (see the earlier entries): browser-direct retired; the composed-path fold for polymorphic recursion; the copy cut at T = 25 (now 29 after #454); `max_sites` 48 → 1000 (#443, interim, #442); `@claude`-only review; Sonnet for focused agents; Lean paused.

**Where S1 stands** (`./rr measure`, `--lists none`)
- unique-components: 2 328 + 274.4 B/widget on #454, against tea-inline's 2 025 + 146.1.
- big-component: 2 068 + 92.7 against 1 552 + 71.8.
- The cap is 1.1× the fit, judged after #315 and the shared validator.

**What I learned**
- **Read-only reviewer agents found most of the serious defects.** Since they stopped, the implementers' own probes and @claude carry that.
