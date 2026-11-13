# 128 — The ownership kernel v3, an eighth blind test (reader G)

*Research report, 2026-11-13. A blind test of `src/own3/` at commit `fc61cc8a12` (pull request #2451),
against `ownership-v3-kernel.md` as it stands there. I read the kernel, the code and the platform rule
(`boundary.md` §9.4.8), and wrote programs to break the checker. I did not read the earlier blind
reports (110 to 127), their generators or their fault folders. Nothing under `src/` was changed.*

---

## 1. Result

**One soundness fault.** A function that a `schema` declaration names in a `via` conversion is
called by the compiled print worker with the program's value. No walked body calls it, so v3
accepts a write of its parameter, and the value that the program still holds changes. v1 and v2
have the same hole. 18 generated programs and 2 hand-made ones trap on it.

**Two slow checks.** The entry's largest solution is not counted by the walk's step limit, and it
costs about the fourth power of the model's list fields when `update` moves lists between fields:
18.7 s for 800 fields. A recursive group re-walks each member up to 64 times, and each walk can take
the whole step limit: 6.5 s for a 400-line program. Both end; neither is "a few seconds".

No other shape I tried was accepted and then read a changed list.

## 2. What I probed

- **The generator** `bench/ownership-sweeps/blind8g.mjs`: 121 programs in six families (its header
  lists them). Run:

  ```sh
  node bench/ownership-sweeps/blind8g.mjs <out>
  node bench/ownership-sweeps/run.mjs --beni=<ReleaseSafe beni> --checker=v3 --jobs=12 --tmp=<dir> <out>
  BLIND8G_FIELDS=800 BLIND8G_ROUNDS=60 node bench/ownership-sweeps/blind8g.mjs <out> slow   # §5 at full size
  ```

- **Hand probes**, about 110 programs, written before the generator and mostly folded into it: fibers
  that wait (`spawn`, `defer`, `onExit`, `bracket`), `Ref`, `Deferred`, `Queue`, `Dict`; non-regular and
  row types in recursive types; local recursive functions handed to `List.map`; one list at many
  places of a list made by 18 functions of `core/`; The Elm Architecture on `browser`, `browser-tea`
  and `browser-inline` with in-place model writes seen through `For` rows, nested `For`, class lists,
  helpers, arm `let`s, text and length holes; random commands, tasks and subscriptions that keep a
  model list; components that write their props; markup kept in the model; schemas in both
  directions; and the timing shapes of §5 at several sizes.
- **The code**: the `flow` memo (`FlowKey`, `upOf`, `ctx_floor`), the leaf memo, `tick` and the step
  limit, `solveGroup`, `solveCodes`, `entryCall`, `entryShape`, `isView`, markup (`keptItems`,
  `formCalls`, `runtimeCall`, `helperHoles`), `newItem` and `makesObject`, `isIdentity`, worded rows
  (`wordedContract`), `Loc.cover`, and `Enforce.checkModule`.

## 3. Verdicts

The generator under v3 (`--ownership=v3 --ownership-everywhere --sanitize-lists`):

| Family | Programs | TRAP | DIFF | CRASH | SAME live | REFUSED live | SAME dead | REFUSED dead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `schema` | 65 | **18** | 0 | 0 | 9 | 5 | 28 | 5 |
| `page` | 18 | 0 | 0 | 0 | 0 | 0 | 18 | 0 |
| `cell` | 12 | 0 | 0 | 0 | 0 | 9 | 0 | 3 |
| `type` | 5 | 0 | 0 | 0 | 0 | 5 | 0 | 0 |
| `maker` | 19 | 0 | 0 | 0 | 0 | 18 | 1 | 0 |
| `slow` | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 0 |
| **All** | **121** | **18** | 0 | 0 | 9 | 37 | 49 | 8 |

The nine "SAME live" programs are not holes: five name a lambda in the `via` (a lambda in a schema
declaration is not walked, so its write has no line and is not done in place), and four write with
`List.update`, which edits no list in place. The fault folder `bench/ownership-sweeps/blind8g-faults/`:

| Program | v3 | v2 | v1 |
|---|---|---|---|
| `schema-via.live` | **TRAP** | **TRAP** | **TRAP** |
| `schema-via.dead` | SAME | SAME | SAME |
| `schema-via-tea.live` | **TRAP** | **TRAP** | **TRAP** |
| `schema-via-tea.dead` | SAME | SAME | SAME |
| `entry-shift-slow.dead` | SAME, **18.7 s** | SAME, 0.07 s | REFUSED, 0.8 s |
| `entry-shift-control.dead` | SAME, 0.2 s | SAME | REFUSED |
| `group-rounds-slow.dead` | SAME, **6.5 s** | LIMIT, 0.06 s | REFUSED, 4.4 s |
| `group-rounds-control.dead` | SAME, 0.15 s | SAME | SAME |

The `schema` family under v2 traps on 21 programs and under v1 on 26 (they also accept the
`List.update` writes).

## 4. The fault

### 4.1 A function named in a schema's `via` has a caller that no walk sees

```beni
back : List Int → Result (List Schema.Issue) (List Int)
back l = Ok (List.push l 3)


schema Box =
    items : List Int via (Schema.conversion Ok back)


main : Program
main = Io.run λ⊤ →
    v = { items = [ 1, 2 ] }
    _ = Box.print v
    Debug.log (String.fromInt (List.length v.items)) ⊤
    Node.done
```

`back` writes its parameter. Its walk accepts the write on the ground `param`: every caller must hand
it a list it owns (§5.2, "every caller checked"). The only caller is the print worker that the
compiler emits for `Box`. It calls `back` with `v.items`, which `main` reads after. The sanitiser
traps on that read: a build that edits the accepted write in place prints `3` where the
plain build prints `2`. (The `node` build of this commit still emits the copying call; the sanitiser
stands for the in-place edit.)

The same holds for a function of another module (`Util.back`), a partial application (`back 1 _`),
both directions named (`Schema.conversion fwd back`), a list of declarations that convert, and every
writer (`push`, `set`, `insertAt`, `pop`). In an application (`schema-via-tea.live`), `update` prints
the model to save it, and the view then reads the list that the conversion wrote.

**The rule.** §5's theorem says that every call into the program's code is a call the walk applies:
direct calls, a function that flows to a holder (§6.2, §6.8), and "a call that the runtime makes into
the program's code … applied where the program hands the runtime what it calls the code with (the
rows of markup, §6.12; the record of an entry, §6.13)". The compiled schema workers are a third
caller of that kind, and the place where the program hands them the code is the schema declaration.
§6.11 names "a codec" among the functions the compiler derives, but only for what derived code reads
and calls by dispatch. No rule covers a `via` expression. So **the rule's argument is incomplete**,
and the code follows it:

- `src/own3/Check.zig:1341`: `checkModule` walks only declarations of kind `value`. A `schema`
  declaration is skipped, so its `via` expressions are never walked, and a function named there never
  flows to the default use (`mention`, `flowTop`), where `writesOwn` would refuse it.
- `src/own3/Frame.zig:2134`: a schema member (`Box.print`, `Box.parse`, `Box.schema`) is
  `v_outside`, "a function of the compiler's own … in the default state". A call of it is unknown code,
  so its arguments escape. An escape stops writes in the caller's frame, not a write inside `back`.

A conversion that is a top-level value (`conv = Schema.conversion Ok back`, then `via conv`) is walked,
and `Schema.conversion` loses its functions, so v3 refuses it (`schema.print.value.*`). The missing
fact is the same for the inline form: the functions in a `via` go to code that the walk does not
follow.

I found no instance in the parse direction: the parse worker hands the conversion an array that it
made and nothing else holds (`schema.parse.named.push.dead` is safe), and `Schema.decode` on a
program value hands the conversion a copy.

**v1 and v2**: both trap on the two programs of the fault folder (§3).

## 5. Slow checks

Neither is unbounded. Both are outside the bound that §8 states: "whatever the memos do not bound is
at most `max_walk_steps` steps per declaration".

### 5.1 The entry's largest solution is not counted

`entry-shift-slow.dead`: `update` sets each of 800 list fields of the model to the next field, and
the last to a top-level list. `entryCall` (`src/own3/Frame.zig:5336`) starts from `own` everywhere and
takes away until nothing changes. Here one field leaves `own` per round, so it takes 800 rounds. Each
round visits every model location, every result entry and, for each parameter source, every model
location again, through `locsMeet`. That is about n⁴ work, and none of it calls `Frame.tick`.

| Fields | v3 check |
|---:|---:|
| 100 | 0.08 s |
| 200 | 0.34 s |
| 400 | 2.39 s |
| 800 | 18.7 s |

With the last field a new list (`entry-shift-control.dead`) it is one round: 0.2 s at 800 fields.
The plain check takes 0.08 s; v2 accepts the program in 0.07 s, and v1 refuses it in 0.8 s. **The
rule's argument is wrong** in that §8 leaves the entry's fixed point out of its count; the code has
no step there.

### 5.2 A group's rounds multiply the step limit

`group-rounds-slow.dead`: `rot` rotates 60 list fields of a record on each recursive call, so its
contract learns one more written field each round, and its body makes 100 calls over a type of 1 024
locations. `solveGroup` (`src/own3/Check.zig:1047`) walks it about 60 times, and `walkDecl`
(`src/own3/Check.zig:996`) starts the step count again at each walk. 6.5 s for a 400-line program;
v2 stops at its own limit in 0.06 s, and v1 refuses it after 4.4 s. The worst case is 64 ×
`max_walk_steps` steps for each member of a group: one walk that reaches the limit takes about 0.5 s
here, so a group near both limits takes about 30 s for each member. **The text says "per
declaration" where the code bounds each walk.**

## 6. Precision

Real-looking safe programs that v3 refuses, most real first:

- `Ref.update r λl → List.push l 2`: a cell's contents are never `own`, so a callback of `Ref.update`
  that pushes is refused (`cell.refupdate.dead`). The same for a list taken out of a `Queue`
  (`cell.queue.dead`).
- `Task.bracket` whose `use` writes the resource it was handed (`cell.bracket.dead`, cause `supply`).
- A schema conversion that is a top-level value and writes in its backward direction, when nothing
  reads the printed value after (`schema.print.value.*.dead`). Expected: the functions go to the
  default use.
- A record update that writes one field with a lambda that reads another field of the same record
  (`{ model | rows = List.update model.rows 0 λr → List.push r (model.n + 10) }`) is refused with
  cause `disjoint`. Binding `model.n + 10` to a local first is accepted.
- 200 straight calls of an identity over a type of 2 048 list locations reach the step limit (a loud
  `ownership_limit`). Not a real shape.

## 7. What I did not cover

- The `Loc.cover` cases for deep levels with a type variable (`cycleWider`) beyond the three type
  probes; I found no program where the map was wrong.
- A judgment of `flow` that two equal uses would read differently. I read the memo key against
  every field of `Use` that a judgment reads and found none; I did not generate random DAGs.
- Derived `eq`/`compare` through `where` evidence across modules, and return-type dispatch, beyond
  reading `derivedEffect` and the `type_dispatch` case.
- The 4 096-location limit itself (I stayed at 2 048 locations).
- `Browser.hosted`, `Tea.application`, `Tea.document` and subscriptions that keep the model, past one
  probe each; `cloudflare` and `node` server programs; release builds.
- The parse direction of a schema with `reportInput` or with retried variants (untagged unions are not
  built).
