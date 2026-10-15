## 2026-10-15 18:28 CEST — Ownership everywhere: specified and measured

**What I did.** I wrote the owner's decision of 2026-10-15 into the spec: "no 'fallbacks', i want a
proper implementation. this is no longer a platform decision, it's core to beni." This change has no
code. It is stacked on PR #148.

- **`ownership-checker.md` §30** (new) holds:
  - the decision;
  - the measured precondition;
  - the `entry` word, which gives every program constructor the direct row;
  - the writer passed as a value;
  - siblings and the platforms' own modules;
  - cost and the firewall;
  - the slices O0–O6.

  I added pointers in §1.3, §3.1, §20.2 and §28.2.
- **`backend.md` §4** gains *Every platform edits in place*. **§15.5** takes a list's identity out
  of every skip in the `dom` lowering: the `For` skip, `same`, items, inputs and holes whose type
  is a list, and root value groups.
- **`language.md`** changes in four places:
  - §6.8: ownership is the language's rule;
  - §10's catalogue row;
  - §11.11: a list never counts as unchanged;
  - §11.12: W27's in-place amendment (Q4) is written down at last.
- **`boundary.md`**: §5.2's `"lists"` is withdrawn, §4's sibling rule applies on every platform,
  and §9.4.4 bars skipping on a list's identity.
- **`browser-direct.md`**: S7 becomes O0–O6. C3's reference is now the E1tp goldens plus the
  stale-read sanitiser, with no copying writers.
- I updated `CLAUDE.md`'s `List` paragraph and added a pointer in `plans/compile-away.md`.

**What I learned.**

- **The measurement used a local patch** (not committed) that forced enforcement and the direct
  row on every chain. **31 of 831 programs are rejected.** 17 of them really share: top-level lists
  written, and the persistence and identity tests. 14 hit checker limits. The largest family is a
  tagger's result through `Cmd.task`/`Http.send` (10 `browser/tea/` programs). All 214
  `browser/direct/` sources and all three examples pass on `browser-tea`.
- **`browser-tea`'s own `Tea.application` has 2 `need` lines.** Under §28.7 they would fail the
  build of beni itself.
- **A crash.** `summary_bytes.write` indexes `packages[none]` on four `SchemaDecl*` run projects
  when a cache is written. ReleaseFast gets `SIGSEGV`, and Debug gets a bounds panic.
- **The writer-as-value worry was already handled** by §16.5. `apply List.push xs` is a checked
  demand, and `{ f = List.push }` is pending, which is an error.
- **The pass's cost now lands everywhere**: Conduit on `browser-tea` +74 %, Bike Wars +28 %,
  `bench/corpus` +63 %. So the DAG and interface work (§28.11 item 1) becomes slice O2.
- **The thesis's P7 identity argument covers only values whose type is a list.** Records,
  constructors and blocks keep their `===` skips, because only lists are written in place and the
  checker rejects a write while a holder is read afterwards.
