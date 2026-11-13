# 124. The ownership kernel, a sixth blind test: reader E

*2026-11-13. A blind soundness test of `src/own3/` (`--ownership=v3`) at commit `5fa471d27d` (branch
`ownership-v2-design-review`, pull request #2451). Reader E worked from the code, the kernel
(`ownership-v3-kernel.md`) and `boundary.md` §9.4.8, and did not read reports 110 to 123, the other
blind generators or their fault folders, the v3 black-box tests, or the corpus fixtures with a
`.sanitize-lists-v3` file. Nothing under `src/` was changed.*

## 1. Summary

v3 accepts programs that then read a list after an in-place write. There are **two distinct
faults**, each shown by two programs:

| Fault | Shape | Kernel rule | Code or rule wrong |
|---|---|---|---|
| **F1** | a function of the program's record takes the model as an extensible record (`{ r \| n : Int }`) and keeps it | §6.13 | the code |
| **F2** | a function hands a list it made to its function parameter, writes the list, and goes where the checker does not follow it (`top`) | §6.8 (its invariant), §6.2 | the code; the rule's text is too short |

Both are real-app shapes. F1 is a generic `view`, `subscriptions`, `update` or `settle`. F2 is a
command's body that takes the runtime's `send` under an alias the program declares
(`type alias Out = Browser.Send Msg`), or a callback stored in a `Ref`.

## 2. What I probed

**By hand: 67 programs** (scratch, not committed), one question each: the entry rule with model
shapes (a function field, `Maybe`, a constructor, a pair, an undo history, a `Dict`), markup kept in
the model, commands and keyed commands that keep a model list, `Sub.listen` bodies, a sender that
writes after it sends, core builders that can put one cell at two places (`List.repeat`,
`initialize`, `map`, `filterMap`, `concatMap`, `intersperse`, a fold that pushes one list twice, a
partial application), `Task.timeout` and `Task.raceOk` (whose rows say `fresh`), `Dict` (one list at
two keys; `update`, `map`, `values`, `foldl`, `get`), `Random` generators, generic functions over
extensible records outside the entry (direct call, function parameter, fold callback, an answer),
and the 4 096-location limit in the module and in an imported module.

**The generator `bench/ownership-sweeps/blind6e.mjs`: 238 programs in five families.**

| Family | Programs | What |
|---|---:|---|
| `row.*` | 92 | the entry, where a function of the record takes the model as `{ r \| n : Int }`, `{ r \| n : Int, tag : String }`, a type variable or the model, and keeps it: a `browser` view whose outer handler runs when the inner click bubbles; the same view under `Tea.element` and `Tea.document`; a `Sub.listen` body; a `Browser.hosted` `update` or `settle` that keeps it in a fiber. Given directly, as a partial application, or through a lambda |
| `app.*` | 96 | The Elm Architecture written the usual way on `browser`, `browser-tea` and `browser-inline`: `update` pushes, sets or updates a model list in place, and a `For` row's message, a bubbling handler, a helper and `Html.map`, text holes, or a `Show` body holds a list of the model |
| `ssr.*` | 18 | markup on `node`: a hole, a helper, a closure in a hole, a `For` row, a row that puts its item in a `Ref`, a `Show`, a component's children, an attribute, nested markup |
| `fiber.*` | 10 | fibers that sleep and then read a list: `spawn`, `scope`, `join`, `Task.soon`, a fold step that spawns |
| `top.*` | 22 | a function that hands its own new list to its function parameter and then writes it, reached through a `Ref`, a record or `Maybe` or list in a `Ref`, and a command's body (`Cmd.perform`, `Cmd.keyed`, `Cmd.afterRender`) whose `send` has the program's own alias or the platform's |

Commands (a ReleaseSafe beni built from `5fa471d27d` with `zig build -Doptimize=ReleaseSafe`):

```sh
node bench/ownership-sweeps/blind6e.mjs <out>/sweep
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v3 --jobs=12 --tmp=<disk> <out>/sweep
node bench/ownership-sweeps/run.mjs --beni=<beni> --checker=v2 --jobs=12 --tmp=<disk> <out>/sweep
```

Each sweep takes about 10 seconds.

## 3. Verdicts

| Verdict | v3 live | v3 dead | v2 live | v2 dead |
|---|---:|---:|---:|---:|
| SAME | 0 | 90 | 6 | 91 |
| REFUSED | 93 | 29 | 36 | 28 |
| **TRAP** | **19** | 0 | **70** | 0 |
| DIFF, CRASH | 0 | 0 | 0 | 0 |
| PLAINFAIL | 7 | 0 | 7 | 0 |

No compile failed to end. The 7 `PLAINFAIL` programs are `app.inline.*.live`: `browser-inline`
declares `"lists": "in-place"`, so its plain build runs v1, and v1 refuses them. They are not faults.

The 19 v3 traps are the 12 `row.*.{row,row2}.direct.live` programs (F1) and 7 `top.*.live` programs
(F2). Every `conc` and `var` control of `row.*` is refused, and every `direct` control of `top.*` is
refused. Each `dead` twin of a trapping program is accepted and prints the same.

## 4. The faults

The programs and their twins are in `bench/ownership-sweeps/blind6e-faults/`. For each fault
`<name>/` is the program v3 accepts, `<name>.live/` is the same program written so that v3 must
refuse it (it does), and `<name>.dead/` is the safe program (v3 accepts it, as it should).

| Program | v3 | v2 | v1 |
|---|---|---|---|
| `entry-row-view` | TRAP | TRAP | REFUSED |
| `entry-row-view.live` | REFUSED | TRAP | REFUSED |
| `entry-row-view.dead` | SAME | SAME | SAME |
| `entry-row-update` | TRAP | TRAP | REFUSED |
| `entry-row-update.live` | REFUSED | TRAP | REFUSED |
| `entry-row-update.dead` | SAME | SAME | SAME |
| `top-rewrite` | TRAP | REFUSED | TRAP |
| `top-rewrite.live` | REFUSED | REFUSED | TRAP |
| `top-rewrite.dead` | SAME | REFUSED | SAME |
| `top-rewrite-send` | TRAP | REFUSED | REFUSED |
| `top-rewrite-send.live` | REFUSED | REFUSED | REFUSED |
| `top-rewrite-send.dead` | SAME | SAME | REFUSED |

### F1. A row of the model at the entry

**The program** (`entry-row-view`, platform `browser`):

```text
view : { r | n : Int } → Html Msg
view model =
    <div id="outer" onClick={λ_ → Debug.log (Debug.toString model) Noop}>
        <button id="add" onClick={λ_ → Add}>add</button>
    </div>
```

`update` pushes onto `model.items` in place. A click on `#add` sends `Add`, and `update` runs at
once. The click then bubbles to `#outer`, whose handler is the old render's and shows the old model:
the plain build prints `{ items = [1], n = 1 }`, and the checked build reads the poisoned list. With
`view : Model → Html Msg` (`.live`), v3 refuses `update`'s write, as it should. With an outer handler
that does not show the model (`.dead`), v3 accepts and prints the same.

The same hole is in the producers. In `entry-row-update` (`Browser.hosted`), `update` is
`Host Msg, Msg, { r | n : Int } → { r | n : Int }` and keeps the model in a fiber that sleeps;
`settle` pushes onto `model.items` in place; the fiber then shows the old model. The other
`row.*` traps are a `Sub.listen` body (it keeps running across messages while its key stays), a
`Tea.element` view, a `Tea.document` view, and a generic `settle` with a concrete `update`.

**The rule.** Kernel §6.13: a model location is `own` only where each producer's source of it is
`own`, and "a location they [the consumers] keep is not `own`".

**The code.** `entryCall` (`src/own3/Frame.zig`) matches a model location to a location of a
function's contract by its label path only:

- the consumers, `Frame.zig:5115`: `me.loc == pe.loc or (pe.kind.wide() and isPrefix(pe.loc, me.loc))`;
- the producers, `Frame.zig:5060` to `5062`: a result entry whose `loc` is not `want` is skipped,
  unless it is wide and its label path is a prefix of `want`.

A record type with a row has the fields it does not name under a `row` label (`Loc.zig`, the
`row` label of `cover`, line 667). The model's `items` is `field items`; the generic function's
location is `row`, which is not a prefix of it. So no entry matches, and the loop reads "no entry"
as "holds nothing": the consumer's escape of its whole parameter is not seen, and the producer's
answer at the model's `items` has no source, so it is never tested. `Loc.cover` maps a field to the
row of a signature that does not name it; the entry rule does not use it.

**Code or rule wrong:** the code. The rule asks for every source and every kept location; the code
derives "none" from a failed label comparison. This is the pattern of kernel §1: a missing fact
read as the empty one.

**v1 and v2:** v1 refuses both programs. v2 traps on both, and it also traps on both `.live`
programs, which v3 refuses: v2's entry rule does not see these holders even when the type is the
model.

### F2. A function that writes what it handed its function parameter, at `top`

**The program** (`top-rewrite`, platform `node`):

```text
body : (List Int → ⊤) → ⊤
body send =
    xs = [ 1 ]
    send xs
    ys = List.push xs 2
    send ys

main = Io.run λ⊤ →
    r = Ref.make []
    cell = Ref.make body
    g = Ref.get cell
    g λl → Ref.set r (List.concat [ Ref.get r, [ l ] ])
    ...
```

`body` hands `xs` to `send`, then pushes onto `xs` in place. The function it is handed keeps `xs`
in the cell `r`, so the second element of `r` is the first one, edited: the plain build prints
`[[1],[1,2]]`, and the checked build reads the poisoned list. When `main` calls `body` with the
keeper directly (`.live`), v3 refuses, with "the function keeps a value that the callee changes
later". When `body` writes a copy (`.dead`), v3 accepts. Here `body` goes into a `Ref`, and the
code that runs it is the default.

`top-rewrite-send` is the same fault written as an application (`browser-tea`):

```text
type alias Out =
    Browser.Send Msg

body : Out → ⊤
body send =
    xs = [ 1 ]
    send (Got xs)
    Time.sleep (Time.millis 10)
    ys = List.push xs 2
    send (Got ys)
```

`update` returns `Cmd.perform body`; `Got xs` stores the list in the model. The platform's alias
carries the word `sender`, so with `body : Browser.Send Msg → ⊤` (`.live`) the send is a demand and
v3 refuses. The program's own alias carries no word (`Check.Mod.isSender`, `Check.zig:259`, reads no
alias of the `app` package), so `send` is an ordinary function parameter, and `Cmd.perform` hands
`body` to JavaScript, which is the `top` use. The same holds for `Cmd.keyed` and `Cmd.afterRender`,
and for a callback reached through a record, a `Maybe` or a list in a `Ref`.

**The rule.** Kernel §6.8, its invariant: "a function in a default location asks nothing and keeps
what it is handed (`flowUnknown`, `flowCode` with `top`)". The default location also **hands** the
function's own function parameters a function that keeps what it is handed. §6.2: "each function
handed flows".

**The code.** `flowCode` (`Frame.zig:3770` to `3781`), where `use.kind == .top`, a callee lost the
function, or the arity differs, refuses only a function that writes its own parameters
(`writesOwn`, line 3772). A function whose contract says that it writes a cell after it handed the
cell to its function parameter (`Fn.rewrites`, set in `demand`, line 1459) is not refused there. The
check that does read `rewrites` is `Use.rewrites` (line 256), which stops at a `top` use and returns
false, and is read only for a known holder (line 3783) or an unknown function in a known holder's
location (`flowUnknown`, line 3893). So the one case where the holder is unknown and the function is
known is not judged.

**Code or rule wrong:** the code; the rule's text is also too short. "Asks nothing" is implemented as
"writes no parameter", and the negative fact "no holder keeps what this function hands its function
parameters" is assumed at `top` instead of being derived: at `top` the parameter is the default
function, which keeps. The rule should name it: a function at `top` (or lost, or partially applied)
must have no function parameter whose contract has `rewrites`.

**v1 and v2:** v2 refuses both programs. v1 traps on `top-rewrite` and on its `.live` twin, and
refuses `top-rewrite-send`.

## 5. Precision

Real-looking safe programs that v3 refuses, the most common first:

1. **A lambda that reads a field of the model, handed to a writer of the model** (all 12
   `app.*.upd.dead`): `{ model | rows = List.update model.rows 0 λr → List.push r model.n }` is
   refused with "disjoint: another operand of the same operation reaches it". The lambda captures
   `model`, which holds `model.rows`. The same on `node` (scratch `upd-cap`). Reading `model.n` into a
   local first is the work-around; every TEA program meets this.
2. **`Dict.update` with a callback that writes the value**, on a dictionary nothing else reads
   (scratch `dict-dead`): refused, "supply: the function writes a parameter".
3. **A `Sub.listen` body that captures the model and does not read its lists**
   (`row.tea-subs.*.dead`): refused. The closure holds the model, so this is the rule, not a gap.
4. **`Show` and component children on `node`** (`ssr.show.dead`, `ssr.children.dead`): a `Show` over
   a list made in the frame, or children that read it, then a write after the render, is refused
   ("escaped before the write").
5. **Fibers:** a write of the answer of `Task.join` (`fiber.join.dead`, "no claim on this value"),
   and of a list that a `Task.scope` body answers after a child fiber was spawned
   (`fiber.scope.dead`).
6. **`Random`:** a list made by a generator, even `Random.list (Random.map (Random.int 1 2) λi → [ i ]) 2`
   (scratch `rnd-listfresh`), cannot be written: the platform's rows are unknown code.
7. **The `sender` word refuses a copy after a send** (`top.*.word.dead`): `send (Got xs)` gives `xs`
   up, so a later `List.copy xs` is a later read of a cell given up. By the rule.

## 6. What I did not cover

- Comparisons by identity in a runtime. On `browser` and `node` a v3 build without
  `--sanitize-lists` copies, so a write in place is seen only on `browser-inline`, whose plain build
  runs v1 and refuses most of the programs above. The `dom` lowering's group tests keep a path's
  value, which can be a list, and compare it with `!==` (`backend.md` §15.4); that is #2504's kind
  and the sanitiser cannot show it.
- Derived `eq` and `compare` (§6.11) beyond what the hand probes touched, `where` evidence, schemas,
  `Json`, and types with methods in a second module.
- `browser-inline` beyond two holders: it compiles no `For` yet, and its plain build runs v1.
- Workers, `cloudflare`, `Browser.programs` with several mounts, `Tea.application`.
- Long random programs; the generator is a grid.
