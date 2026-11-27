# The ownership checker v3: the soundness kernel

*Normative for `src/own3/`, 2026-11-12; §6.4, §6.8, §6.11 to §6.13 and §8 revised 2026-11-13 (research
report 120); §6.12 and §6.13 revised again the same day (research report 123); §4.1, §6.2, §6.8 and
§6.13 revised again the same day (research report 125); §6.8, §6.9 and §8 revised again the same day
(research report 127); §5, §6.9, §6.11, §8 and §9 revised and §6.14 added the same day (research report
129); §8 revised 2026-11-14 (research report 130); §6.14 and §8 revised again the same day (research
report 131); §5, §5.3, §6.12, §6.14, §8 and §9 revised again the same day (research report 134); §6 rule 9 and §8
revised 2026-11-15 (research report 141). §0 revised and §11 added the same day (research report 142); §5, §6 rule 2 and
§11 revised again the same day (research report 144); §4.4, §6 rule 13 and §8 revised again the same day
(research report 143). §3.4 added, §6 rule 10, §8 and §9 revised 2026-11-16 (research report 146); §3.4, §6 rules 4 to 6, §9 and §11 revised again the same day (research report 147); §3.4, §4.1, §5, §6 rules 10 and 12, §9 and §11 revised again the same day (research report 148); §3.4, §6 rule 10 and §9 revised again the same day (research report 150); §3.4, §6 rules 10 and 11 and §9 revised 2026-11-17 (research report 151); §6 rules 3 and 10 and §11 revised again the same day (research report 153); §4.4, §5, §6 rules 1 and 10 revised again the same day (research report 154); §4.4, §6 rule 10 and §9 revised 2026-11-18 (research report 156); §4.4, §6 rule 10 and §9 revised again the same day (research report 157); §3.1, §3.4, §4.1 and §4.4 revised again the same day (research report 158); §4.4, §6 rules 10 and 13 and §8 revised again the same day (research report 159). §12 added 2026-11-19 (research report 160), and revised the same day (research reports 161 and 163). §6 rule 10, §7 and §9 revised again the same day (research report 162). §6 rule 10, §7, §9 and §12 revised again the same day (research report 164). §13 added 2026-11-20, and §0, §4.2 and §6 rules 8 and 11 revised (research report 165, slices 1 to 3); §13 items 4, 8 and 10 revised and item 11 added the same day (research report 165, slice 4); §13 item 11 revised again the same day (#2586); §0 and §13 items 10 and 12 the same day (#2581); §4.1, §6 rule 2, §11 item 5 and §13 the same day (#2583, #2588); §6 rule 11 and §9 revised 2026-11-22 (#2601); §13 items 3 and 5 the same day (blind round BN); §13 item 5 again and item 13 added the same day (blind round BN's undo app); §13 item 12 revised 2026-11-23 (#2613); §12 item 8 added 2026-11-24 (#2657), and §6 rules 3 and 10 revised the same day (#2652); §6 rule 13 revised 2026-11-27 (*A message a command builds*, the owner's decision, #2657). The owner
ordered it after research report 116: "Write the rules
and do a principled fix on the core. The core must have soundness." Report 110 §6 is the design this
kernel keeps; reports 111 to 115 are its history; report 117 measures this text's implementation. The
section numbers here are referenced from the code (`kernel §N`): never renumber them (`CLAUDE.md` rule 2).*

---

## 0. Scope

A beni `List` is a plain array. The checker accepts an in-place write only when no later read can observe
the old value. It judges lists and, since 2026-11-15, records (§11), since 2026-11-19 dictionaries (§12), and since 2026-11-20 a cell's contents (§13), with the loan rule for a cell that fibers share (§13 item
12), the later stage of the same rules that report 116 §5.4 names. It runs behind `--ownership=v3`. v1 (`src/own/`) is the production checker and is not touched.

## 1. The principle

A write is safe when two things hold:

- **(a)** the writer may write: its target is `own`;
- **(b)** no other holder observes the old value: no other operand, no escape, no duplicate, no later read.

(a) is a fact about one reference, and v3 carried it as a permission from report 110 on. (b) is a universal
statement over every holder in the frame, and every hole of reports 111 to 115 was a state of the holder
model that meant "I do not know what this holds" and was read as "this holds nothing" (report 116 §2).

**The rule of this kernel: every fact that a verdict depends on negatively is derived from named, positive
facts, and a fact that no rule derives is the pessimistic one.** The negative facts of (b) are: no other
holder, no escape, no duplicate, no later read. The positive facts they are derived from are: the cells a
value holds (§3), the names of cells (§4), the reads, escapes and demands the walk records (§5).

The five forms report 116 §5.2 named are the five places where the old code had a state that meant
"unknown" and read as "empty". Each is closed by construction below:

| Form | Where | Section |
|---|---|---|
| a fresh cell has a name | `Contract.Src.fresh(k, escaped)`, `Frame.freshAtom`, `Frame.freshId`, `Check.siteId` | §4.2 |
| "no claim" and "no cell" are two values, the second with its reason | `Frame.Tag.outside` and `.unknown`; `Frame.giveUp` | §3 |
| a summary location is `twice` until shown otherwise; `linear` is derived | `Frame.partDup`, `Frame.deriveLinear`, `Frame.Linear` | §4.4 |
| one clock, the walk's | `Frame.timeOf` | §5.3 |
| no fact by a name | `Frame.methodCall`, `Frame.evidence`, `Frame.derivedEffect`, `Check.edgeEffect`, `Check.isSender`, `Check.wordedFn`, `Check.undescribed` | §6.10, §6.11 |

## 2. The facts and their kinds

The walk (`Frame.zig`) goes over one body in evaluation order and records these facts. Each kind has one
invariant, stated here and kept by every rule of §6.

| Fact | Kind | Invariant |
|---|---|---|
| a **value** | `Frame.Tag`: `none`, `outside`, `ref`, `built`, `join`, `closure`, `fnref`, `unknown`, `later` | its leaves (`leaves`, `allLeaves`) are every cell it can hold, as atoms (§3) |
| a **root** | `Frame.RootKind`: `outside`, `param`, `capture`, `local`, `answer`, `fresh` | every cell that enters a frame is an atom of some root; root 0 is the one root of every cell outside the frame |
| an **atom** `(root, path, entry)` | `Frame.Atom` | names the cells of one location of a root at or below a path; two atoms can be one cell only when they have one root, one entry and comparable paths (`overlap`) |
| an **entry** of a root the frame made | `Frame.REntry`: a run of atoms, `kind`, `twice` | the run is every cell of other roots the location can hold; `twice` is derived where the run is built (§4.4) |
| a **source** of a contract | `Contract.Src`: `outside`, `fresh(k, esc)`, `param`, `answer`, `twice` | each names cells; a location with no source holds none, as a fact of the body's walk (`Contract.zig` header) |
| a **use** of a function value | `Frame.Use`: `call`, `inner`, `top` | a known function leaves the known state only through `flow` (report 112 §2.6) |
| a **read**, an **escape**, a **demand** | `Frame.Read`, `.Escape`, `.Demand` | each carries the time of the walk's clock (§5.3); an escape owns a copy of its atoms (`esc_atoms`) |

## 3. Values: no state reads "unknown" as "empty"

### 3.1 `outside`: no cell of the frame, with its reason

`Tag.outside` (`v_outside`) is a value whose every cell is outside this frame. It is given only where a
positive fact says so, and the fact is the **position rule**: a top-level value is held by every reader of
the program and holds nothing that any frame made (`evalInner .top`); a function that captured nothing (a
named declaration, a constructor, a function in the default state) holds nothing of the frame
(`ctorValue`, `project .fnref`); a part of an outside value is outside (`project .outside`). Its one atom is
`outside_atom` (root 0), which refuses a write (§5, test 1) and overlaps nothing.

A top-level value is read through its contract (`evalInner .top`): it holds `outside` at each location
where an entry of its contract has a source, and nothing where none has, since a location with no source
holds none as a fact of the body's walk (`Dict.empty`'s values). A location that every entry of the
contract covers (`Loc.all`: a deep level that the contract reads through a type variable, §4.1) holds
`outside` where some entry has a source, and nothing where no entry has one (`topHolds`). *Research report
158: such a location held `outside` whatever the contract said, so `Dict.empty` read as `Dict Int R` had
`outside` at its deep level, and a write of a value taken out of it was refused.*

`Contract.Src.outside` is the same fact in a contract: a cell of a top-level value, a cell's contents, or
JavaScript's. What went into a cell or to JavaScript escaped in the frame that put it there (§5, test 3), so
such a cell holds nothing any frame may still write.

### 3.2 `unknown(V)`: no claim, and every cell of V

A value the walk cannot follow is `unknown` over the values it was made of (`unknownOf`): a part the place
graph does not name, a constructor with no row, a list literal whose place has no element step (§6.4),
the answer of unknown code, a `?` on a type that is not `Result` or `Maybe`, the value of markup (§6.12).
Its leaves are `outside_atom` and every leaf of V. It is `outside` only when each value of V holds no cell of the frame, which is then a fact of those values, not a
default. The answer of unknown code is `unknown` over its arguments and the callee (`call`, `methodCall`,
`type_dispatch`), after each of them escaped.

### 3.3 Giving up

Where the walk cannot say what a value is — a local read before its binding, code with no contract to read
in its rounds, a tag that is not an expression — it **gives up** (`giveUp`): the frame is `failed`, the walk
completes so that every line is made, every demand of the frame is refused (`finishDemands`), every line
the declaration's walk accepted is refused at the limit (`Check.gaveUp`: a send's, an entry's, a line of a
code whose own walk ended well, one judged before a later step passed the budget), and the
declaration **publishes no contract** (`Check.walkDecl` returns null, `Check.solveGroup` keeps null). A
caller reads a callee with no contract as unknown code. Safe builds assert that a declaration whose walk
gave up has no contract at `publish` (`Check.checkModule`).

The value of a local before its binding is `v_unbound`, which nothing reads: `evalInner .local` reads a
local only where its frame bound it, and safe builds assert it (`evalInner`, `capVal`).

Every `switch` over `Tag`, `RootKind`, `EKind`, `Src.Kind`, `Use.kind`, `Bir.Inst.Tag`, `Place.Kind`,
`Facts.Cause`, `Edges.Edge` and `Dispatch.Term` in `src/own3/` has no `else`: a new kind compiles only once each reader
has a case. A tag that a reader takes the same way as others is listed with them under a comment that says why that
answer is right for it, and where it is not known to be right the answer is the pessimistic one (a refusal, `unknown`, a
given-up walk). A position that holds a closed set of tags, a pattern or a binding of a `let`, is classified once
(`Frame.patTag`, `Frame.letTag`), and a tag outside the set gives up the declaration. Where one or two tags are special
and every other goes to a reader that is exhaustive itself (`eval`: `let` and `case`, else `evalInner`; `call`: a
constructor or a top-level callee, else `eval`), the test is an `if`, not a `switch`. A predicate over the type store's shapes
(`fnType`, `isMarkup`, `isView`, `isSender`) answers no for any shape it does not name, which is the refusing side. (Research
report 148 noted ten
exceptions in `Frame.zig`; #2541 removed them.)

### 3.4 A value read at a type with more places than its own

A value has the layout of its own place, and it can be read at a place whose type has more locations: a
`Js.Value` that `Js.to` gives the type `List R` (`Js.to` is an identity, `apply`), a value of a type
variable read at `List (List b)`, a local that the type check generalised (`got = Js.to v`, `∀c. c`) read
at an instance of its type, a payload of a non-regular type, which the place graph folds onto a type
variable (`type T a = Leaf a | Wrap (T (List a))`). The value's own layout then has **one wide entry**
where the reading has a location and the locations below it. The wide entry names every cell at or below
its place, so it holds the cells of each of those locations, and **a reading of any of them reads all of
the wide entry**: it is the fallback that §4.1 names. The call map (`Loc.cover`) sends the wide entry to
the reading's entry at the same place, so a reading through the map alone found nothing below it, and a
location that can hold every cell of the value read as holding none.

`Loc.Table.holes(view, own)` names, for each location `j` of the reading, the wide entry of the value's
own layout strictly above it (`above`), and that entry again where the map puts it at another location
(`read`). Every reading of a value through a map reads `read[j]` with the entries the map gives:
`leavesSet` (the parts of a construction, the arms of a join, a frame's result in `finish`), `argEntries`
(what a call reads, writes, lets escape and answers of an argument, `argLeaves`, `pairedLeaves`) and the
flags of a call that `readBy` and `otherReaches` compare (`holeFlags`). Where a reading below a wide
entry passes a suffix (`argEntries`), a `var` or `opaque` entry above the part asked for is read too.
**A summary location below a wide entry is no single place** (`dup`, §4.4): the wide entry is one
location, and it cannot say that one cell is not at two of the summary's places (`Js.array [ x, x ]`
read as a list). Projections need no new rule: a step that a value's own layout does not have makes
`unknown` over the value (`project`). Worded rows read a parameter the same way (rule 10, `holdsAt`).

**Two locations below one wide entry are no two places of it.** A wide location holds one value, and the
locations of another reading below it can hold one cell at two of them (`Js.to (Js.from ( x, x ))` read
as a pair: both parts are `x`). Four facts that rest on "apart" are read so:

- **a callee's claim** (§4.4) is about its own locations. Where two locations of the caller's result
  are at one wide location of the callee's result, or at every one of them (`Loc.all`), the claim says
  nothing of them: they are tested by their atoms, as an answer's are, each pair that can hold one cell
  (`canShare`: two fields' slots, a slot and a list, cannot) (`apply`, `deriveLinearSplit`);
- **the apart-arguments rule** (§4.4): an argument read through a wide entry of its own that is above
  two locations of the parameter, or above a summary location, is not apart (`argsSplit`);
- **another location of the written operand** (§5, test 2): where the written location is below a wide
  entry of the operand's own layout, that entry is the written cells, and any other location of the
  signature below it, or at it, that the callee reads or answers reaches them, with no claim that the two
  are apart (`otherReaches`);
- **a part a result is read at** (`pairedLeaves`): where the part is no location of the argument's own
  layout and every entry is read, a summary location of the caller is no single place (`dup`).
  *Amended 2026-11-21 (#2594, #2580).* Where the callee is a cell's row (`Contract.cell_row`: `Ref`,
  `Deferred`, `Task`, whose JavaScript stores, answers and hands the value at a type variable as it
  is), its location is wide and the caller's is the location at that same place (no suffix below it),
  the part is the argument's cell at that place, and not every cell below it (`paired_exact`):
  `Ref.make [ [ 1 ] ]` holds the outer list at `r◆` and the inner one at `r◆[*]`, as the row's words
  say (§13 item 2), where before `r◆` held both, and a helper that writes `r◆` and `r◆[*]` was
  refused `disjoint` on one cell at its two operands. A parameter of a function that a cell's
  callback answers at the same place reads what the row hands there the same way (`Fn.once`,
  `answerSrcs`, `resolve_exact`), so the renewal `Ref.update r λv → List.push v [ 30 ]` publishes is
  `π1◆ := π1@1`, not `π1@1 π1@2`. Any other callee keeps the reading of every cell below: another
  row can build a new value at the variable of the argument's parts, which no word counts
  (`elementof a` answering `[ l[i][0], l[i][0] ]` read as a list of records, research report 156),
  and a walked body can answer such a row's answer; nor where a callee or a function handed to it
  casts. Where the argument has no entry at that place, every entry below the wide location is read,
  as before (`suffix_fallback`). A wide location of the caller's own reading still reads every cell
  below it.

And a contract that holds one cell of its parameter at two places of its answer (`nonlinear`) answers no
value as it is: it is applied as a call, not as an identity (`isIdentity`).

**A construction read at a step its own place does not have.** The same holds of a value that is no
root: a construction read at another type of the same JavaScript shape (`backend.md` §4: a tuple, a
record of fields `a`, `b`, … and a constructor's value are one object of those properties), which a
platform function over `Js` can answer as it is. A construction names every part of its own place that
holds a cell, so a step its own place has and no part is at holds none (another constructor's argument,
a field whose value held no object); **a step its own place does not have is `unknown` over the
construction** (`project`, `builtAbsent`), as on a root.

**A record's slot that the value's own place has no slot for.** A record's object is a cell only where a
layout names its slots (§11.1). A tuple's or a constructor's object is no cell, since no write in place
reaches one; read as a record, its slots are a cell that no atom names, and every other holder of the
object reads it by parts that hold no location for it (a number, or nothing at all). So a reading of a
slot of the record at a value's root, where the value's own place is no record that names the field and
no wide place, holds `outside` as well as what the map gives (`rootSlotLost`): a write of it has no claim.
It is applied at each reading of a value through a map — `leavesSet` (each part of a construction and
each arm of a join is read at its own place, so the slots below a value's root are asked of the part
that holds them) and `argEntries` (a callee's slot of its parameter's root) — at the update of a value
whose type does not name the slot (`slotAtoms`), and at a write of a slot that holds no cell: a record
always holds its object (§11.2), so a slot write whose atoms are none (a tuple of numbers read as a
record, which is no cell at all) writes an object no cell names (`recordUpdate`, `applyAt`).

**A cast.** Two places of one call can be two types of one object where a callee answers a value of
another type than the one it was handed (`Js.to (Js.from x)`):
- an identity whose answer is read at another type of parts than its argument's own, both concrete, with
  a field slot or a constructor's argument that no location of the argument's own layout covers (the
  call map, `cover`), answers `unknown` over the argument (`punned`; any location of any kind since research
  report 148, below). The constructor's argument is the
  other half of rule 5's "another constructor's argument holds none": a step names a constructor by its
  position, so `V`'s argument and `X`'s are one step, and a value built as `Y xs` of
  `type W = X (List Int) | Y (List Int)`, read as `type V = V (List Int)`, has that step in its own place
  and no part there, though `V u` reads `.a` with no test. An array read as another type of array (`List
  a` as `Builder a`) has every location covered, and is no cast here;
- a contract that pairs a wide location of a parameter with a wide location of its answer, below which
  the caller reads a slot (`argEntries`, from `pairedLeaves`), or a wide location with a concrete one
  (`toR : a → R`, `toR x = Pun.conv x`: the answer's slot `.a=` holds the parameter's one location;
  `castSlotLost`), can be a cast, and is read as one: the slot's
  record is the argument's part at the parameter's location, and the slot below it is the label path the
  caller asks there. It is held only where the argument's own layout has a slot at that path, or a wide
  entry at or above it (`slotHeld`); else it holds `outside`. A label path is a test here only outside a
  cycle: the call map pairs a cycle's deep level with its entry level, which name one place by two paths,
  so in a deep level a slot of the same field holds it.

*Research report 147: a tuple read as a record through `Js.to` (`run/RecordPunTuple`) projected `.a` on
the tuple's construction to `none`, so a push of `p.a` wrote no cell v3 knew of; and a function that
updated a tuple of numbers or a constructor read as a record (`run/RecordPunHelper`,
`run/RecordPunConstructor`, `run/RecordPunAnswer`, `run/RecordPunDeep`, `run/RecordPunBeside`) wrote an
object no atom named, so the caller's demand was of nothing, or of the lists beside it, and was
accepted. Its review found the two casts: a constructor read as another type's (`run/RecordPunOrdinal`),
and a function of a type variable that answers its parameter as a record (`run/RecordPunGenericCast`).*
What stays open: a cast of a value whose type has a cycle, read at a type whose slot of a field is in
the deep level where the value's own record of that field is another object (#2540).

**Every location a cast's reading has that the value's own place does not.** The cast above is not
only of slots and constructors' arguments: an `Int` read as a list, a list of numbers read as a list of
lists, a tuple of numbers read as a tuple of lists each read a location — an array — that no location of
the value's own layout covers. The map answers `none` for it where the value's own layout is empty and
`Loc.all` where it is not, and the readers of the answer go through the map the other way (`argEntries`,
`leavesSet`), where no entry of the value's own layout is at it: they found nothing. So an identity whose
reading has **any** location that the map leaves uncovered (`none` or `Loc.all`), of any kind, answers
`unknown` over its argument (`punned`); so does an identity of a value of no cell (`v_none`: a number)
read at a type with a location, whatever the argument's type was (`fromInt n = Js.to (Js.from n)` reads
`n` through `Js.Value`), and at a type variable too (`unhide : Int → b`, read by its caller as a list).
Otherwise a type variable or an opaque type of the reading is no pun: it is a wide entry, which §3.4's
first half reads.

**A value read at a type with fewer places than its own.** The converse holds too: `hide : List Int →
Int`, `hide l = Js.to (Js.from l)` answers the list as a number, and a later cast reads it as a list
again. The reading has no location for the list's array, so no reader of the answer can name it, and
nothing then says who holds it. Each location of the value's own layout that no location of the reading
covers (`cover(view, own)` is `none` where the reading's layout is empty, and `Loc.all` where it has
locations elsewhere) holds cells that **escape at the identity** (`narrowed`): a holder no rule follows.
So does each **wide** location of the value's own layout (a `Js.Value`, a type variable), whose cells can
be at any place below it, where the reading at its place is not wide and has a part of no location below
it (`Loc.holeAt`: `List Int`'s elements, a record's `Int` field, `Maybe Int`'s argument). *Until research
report 150 the text said that a location at `Loc.all` is held by every entry of the reading, "and nothing
is lost"; but a part of the reading at a type of no location is `outside` (below), so `( _, h ) = Js.to
(Js.from ( x, x ))` read as `List Int × Int` gave `h` nobody's cells (`run/CastPairNoLocation`).* So **a
value whose type has no location holds `outside`**, as a fact: whatever a cast
put in it escaped there. A parameter, a capture, a part of a root, a construction of parts that hold
anything and the answer of a call, each of a type of no location, is `v_outside`, never `v_none`
(`rootVal`, `capture`, `project`, `built`, `unknownOf`, `applyAt`): such a value is read nowhere but
where a cast reads it at a type with a location, and there it has no claim (a cast handed to `Maybe.map`
as a function value reads the `Int` in a parameter's `Maybe` as a list). A literal is `v_none`: it holds
no cell at all. And where a callee answers what it was handed at a location the caller reads as a list,
the argument gives no cell there (none, or only a record's slots), and the argument's type holds no cell
at that path (`Int` at the callee's `a`, read as a list at its `b`: `un : W a → W b` cast what it was
handed), the caller's list holds `outside` (`pairedLeaves`, `Loc.emptyAlongLabels`). A reader of a value
of an empty layout then reads nothing (`Frame.checkPlaced`, §9).

**A contract's location that the caller's reading does not have.** The same holds where no cast is
written at the call: a contract is written for the callee's own type, and a caller reads the answer at an
instance of it, which can have fewer locations (a type variable filled in with `Int`, `Maybe b` read as
`Maybe Int`, a pair whose second part is a variable read as `List Int × Int`). The answer is the same
JavaScript value whatever type the caller reads it at, so what the callee put at such a location is there,
and a cast reads it back. The call map pairs each location of the reading with one of the contract's
result (`Loc.cover`); a location of the contract's result that no location of the reading is paired with,
where none is paired with `Loc.all`, holds cells that no reader of the answer can name, so **its sources
escape at the call** (`Frame.escapeUnplaced`), each as the call reads it: a parameter's cells, the answer
of a function parameter, a cell the callee made. That another location of the answer holds the same cells
is not enough: a part of the answer at a type of no location is `v_outside` (above), so `( _, h ) = g x`
reads `h` as holding nothing of `x`. The same holds where a function value meets the holder it is handed
to: its contract is written for its own type, the holder reads its answer at the holder's type, and a
result location of the function that no location of the holder's answer holds (which `answerOfCode`
skips: the function's type is wider there) lets what it holds escape where the function meets the holder
(`Frame.escapeUnplacedAnswer`; `apply : (a → Int), a → Int` handed `cast : a → b`). A location whose every source names no cell a reader
could miss is skipped (`holderGivesNone`): a parameter location at whose place the holder's parameter
type has no location (`List a → List a` held as `List Int → List Int`), a capture of no cell, a cell
the function made that no other location of its result holds, that it did not let escape, that it
left in no cell (a renewal) and handed no function (*amended 2026-11-22*, #2598: before, only the other
locations of the result were read, and a cell the function also stored or let go was skipped). **A location placed
nowhere never holds nothing.**

**A cast hidden behind a type variable.** A location of the contract's result that the reading does
have can still hide cells: where it is wide (a type variable) and the body put there a value of another
type, the caller fills the variable in, and a part of no location below it (`b` read as `List Int ×
Int`) holds cells of the value that no reader finds (`g x = Js.to (Js.from ( x, x ))`). A body that reads
a value at a type variable that is not the value's own type (`narrowed` with a reading of a type
variable), that calls a callee whose contract says so, or whose worded row puts a wide location at
another type's place (`returned a → b`, `Check.castsAt`), **casts** (`Contract.casts`). At a call of a
callee that casts, or that is handed a function value whose code casts (`argsCast`), each wide location
of the result that the caller reads with a part of no location below it lets what it holds escape
(`Frame.escapeHidden`); where a function that casts meets a holder that reads its wide answer location
at a location that is not wide, what that location holds escapes there (`escapeUnplacedAnswer`). A
callee that does not cast answers at a type variable only values of that variable, whose cells each
reading names where the argument's own type does: `Maybe.withDefault m []` read as `List Int` is no
cast. The flag is the pessimistic side: it is set for the whole contract, and a caller of a function
that casts casts too. A `Js.Value` read at a type variable does not set it: `core/` keeps values in
JavaScript arrays and objects and reads them back so, and the flag made every list function cast. What
the `Js.Value` was made from decides instead (*What a value was made from*, below).

**A value of no location in a typed answer** (research report 158). An argument of a type of no location
holds `outside` (above), and a call reads a parameter source of the callee's result as the argument's
leaves (`expandSrcs`), so a callee whose places put the parameter at a location of the result put
`outside` there: `Dict.insert`'s walk reads the key and the value of a tree at one place (`k` and `v` are
one place, and a deep level read through a type variable is `Loc.all`, §4.1), and every value of a
dictionary built by `insert` with an `Int` key held `outside`, which refuses its write. A callee that does
not cast, handed no function value whose code casts (`Contract.casts`, `argsCast`), answers a value only at
a location of the value's own type (*What a value was made from*, below); the reading has a location at
the entry, and the argument's type has none, so the two are two types and the argument is not there. So
at such a call **a parameter source whose argument is of a type of no location gives nothing at an entry
of the reading** (`SrcState.typed`). A call of a callee that casts reads it as before: the cast can put the
argument anywhere, and whatever a cast put in the `Int` escaped where it was cast.

**A cast function in a holder** (research report 158). A function value that casts (`Contract.casts`) answers
what it was handed at a depth no type names, and a holder hands it values through the holder's own layout
of the function's type, which can have no location for them: an `Int` that a cast made of a list, handed by
`λy → k y` to a captured `k = Pun.conv` (a supply at a location of no location is no source). Read at the
holder's answer, the function's sources then named nothing, and the answer was a list nobody held: the lambda's
caller wrote it in place while the list it was cast from was read after. So where the code of a function in
a holder casts and the holder reads its answer at a location that is not wide, the answer is lost
(`answerOfCode`, `lostAnswer`: `outside` and every argument in sight). A holder that reads the answer at a
wide location keeps it whole there, and `escapeUnplacedAnswer` applies as before. *The second review of
research report 158 found it on the base: `run/CastCapturedLambda`, a lambda and `Maybe.map`.*

**A wide parameter answered at a wide result location** is the argument, or its part there, as it is,
read at the caller's type (`Frame.escapeWide`): where both are roots, as an identity's (`narrowed`);
elsewhere (`Maybe a → b`, `List Js.Value → b`, `{ r | v : a } → b`), where the argument's own type at
the parameter's place (`Loc.placeAt`) hides a cell from the caller's type at the result's place (`hides`:
`narrowed`'s test of types alone), every cell of the argument there escapes; where the caller reads it
at a type variable of its own, a value of another type than the variable (not a `Js.Value`) makes the
caller cast, so its own caller reads it (`λ⊤ → fm (Just ( x, x ))` with `fm : Maybe a → b`). A function value of that
shape that meets a holder which reads its wide answer location at a location that is not wide lets what
it holds escape, unless the holder's parameter and answer are one layout and the two locations one place (`List.reverse` held as `List Int → List Int`)
(`escapeUnplacedAnswer`). At a call of a callee that casts, the escape of a
wide location covers every cell of a parameter at its entry (`allSrcs`), not the part a reading would
take: where the body cast, the part is not where the types say. *What this did not cover* (research report 150 §11): a
path that no place step names (a deep level of a cycle, a row, the inside of a `Dict`), an argument of
the caller's own type variable or a function value, and a `Js.Value` inside a container cast at a type
variable in a frame whose own result is that variable (`λ⊤ → fromMaybeV (Just v)`). Research report 151
covers them by the three facts below: every cast of one type variable to another is seen where it is
written, so a callee that does not cast answers at its type variable only values of that variable, and
the paths that `escapeWide` skips hide nothing a type can; a `Js.Value` at the parameter's location is
read as what it was made from.

**What a value was made from** (research report 151). Where a value's cells sit is a fact of the walk,
not of the types alone, and three facts say it; where one does not hold, the frame casts, or the cells
escape:

- **A type variable is a type, not a place.** The place graph has one place for every type variable:
  `a` and `b` are one place, and so are `List a` and `List b`. Two places that are one are one type only
  where their types are one: one variable of the store, or one structure whose parts are one type each
  (`Mod.sameType`; the type at a location is read through elements, a tuple's parts and a record's
  fields and a constructor's argument written as a type parameter, `Mod.typeAt`, `typeAtPath`,
  `ctorArgType`, and any other step is another type, the pessimistic side). So a
  row whose word puts a wide location at a place of another type casts by its types (`returned a → b`,
  `stored a → List b`, `aliased a → b`: `Check.castsAt`, `aliasedCasts`; rule 10), at every instance:
  before, the places said "one type", the row had no mark, and a caller that filled both variables
  with `List Int` read it as an identity, though its JavaScript `(a) => [a]` puts the argument at an
  `Int` element (`run/CastRowSameLayout`, `CastRowSameRecord`, `CastRowAliased`). And a value read
  through an identity at the place it has, where that place has a type variable (`Js.to (Js.from v)`
  with `v : a` read at `b`; `fm : Maybe a → b`), casts unless the walk knows the value is of the
  reading's type (`Frame.varAtVar`): a part of a parameter, a capture or a root the frame made, by the
  type of the root (a parameter's pattern, a capture's local, the instruction that made it) and the
  steps of its path; a tuple or a record built of values of the types of its parts; a join of such
  arms; or a value of the expression's type, since a value has the type of its expression unless an
  identity read it at another type, and each identity is judged so where it is (`valIs`, the argument
  instruction's type). Before, `own == place` read as one type, and a callee that cast `a` to `b` did
  not cast (`run/CastVarDeepLevel`, `CastVarFunctionValue`). A type variable inside the reading (`List
  b`, `b × Int`) is filled in by a caller as one at its root is: a location of the value's own layout
  at or below it that is not a type variable at its place casts (`narrowed`).
- **An identity is what the build writes, not what the words say.** `returned a → Js.Value` is as true
  of `(a) => [a]` as of `(a) => a`. A call answers its argument as it is (`Frame.identityCall`; the
  argument read at the reading's type, `narrowed`) where its contract is an identity's and does not
  cast; where the walked body answers its one parameter itself, whole, through identities only, whatever
  type it read it at (`Contract.exact`: `conv v = Js.to (Js.from v)` at `a → b`; a call of it is the
  argument read at the caller's type, a function value of it keeps the cast mark, since its holder reads
  its answer at the holder's types); or where the build writes the call as its argument: `Js.from` and `Js.to` of the core package,
  which the backend compiles to nothing (`Mod.emitsArgument`, keyed as `js/JsIntrinsic.zig` keys them:
  the core package, the module `Js`, the declaration's name; a module of another package of that name
  is an ordinary module). That is a fact of the code the build writes, and the one place the kernel
  reads a declaration by its name (rule 11). A row that casts is a call: its answer is read where
  `escapeHidden` and `escapeUnplacedAnswer` read a cast's (`run/CastRowMapped`, `CastRowGeneric`). A
  callee that casts can also hand a cast value on, to a function parameter (`feed x g = g (Js.to
  (Js.from x))`, whose argument the caller's function reads at its own type and casts back), or answer
  the answer of a function parameter below its answer (`ans g = Js.to (Js.from (g ⊤))`), where
  `escapeHidden` reads the answer only as the caller's reading names it. So at a call of a walked callee
  that casts, each cell that the contract hands a function parameter escapes (its supply: an argument's
  cells, and every cell another function argument's answer can hold), and so does every cell of a
  function argument's answer that the contract answers (`escapeHandedOff`, `escapeAnswer`; research
  report 151's review). A row says it in its words, which say what is a cast, so its call needs no
  more: a cast placement of a function parameter's
  answer (`once returned (⊤ → a) → b`) makes that answer escape (`Fn.ans_escapes`), and a supply of a
  type variable's or a `Js.Value`'s location at a function parameter location of another type (`feed :
  borrowed a, once returned (b → c) → c`) makes the location escape. The type at a constructor's
  argument is read where the type's declaration writes it as one of the type's parameters
  (`Mod.ctorArgType`: `Just a` of `Maybe a`); any other argument is no type the test names.
- **A `Js.Value` is what it was made from.** A value read through an identity is the value it was:
  `Js.from x` is `x`, and `Just (Js.from ( x, x ))`, of type `Maybe Js.Value`, has the pair as its part,
  which a reader of the part reads (`Frame.partAt`, step by step from the place of each part reached;
  `escapeWide` reads it at the caller's type, `run/JsValueMaybeInThunk`). A `Js.Value` the caller
  handed (a parameter, a capture, a part of one) is the caller's: the caller reads it as it made it,
  where it reads the answer. A `Js.Value` the frame made of parts — the root of a call that put cells
  in it (`Js.array [ Js.from x ]`, `Js.object`, a function that answers one), a construction, an
  `unknown` — holds them below its place, at a depth no type names (`madeOfParts`): read at a type
  variable, or at a type with a type variable at or below the place of the `Js.Value`, each cell it
  holds escapes there (`readAtVar`, `narrowed`; `run/JsArrayAtVar`, `JsObjectAtVar`,
  `JsArrayAtListVar`). Where no step names the part (a cycle's deep level, the inside of a `Dict`), an
  argument the caller made of parts lets its cells at the parameter's location escape where the
  reading has a type variable or a part of no location there (`escapeWide`). The answer of unknown
  code (`Js.get`, `Js.call`, `Js.at`) escaped already, so `core/` loses nothing: every demand of the
  2 796 ownership roots has the verdict it had (research report 151 §7).

*Research report 150: a worded row whose result had no location dropped the parameter it put there
(`run/WordedReturnedNoLocation`, and `stored`, `elementof`, `taken`, `copyof` and a function parameter's
answer, rule 10); a call whose instance has fewer locations than the contract dropped them the same way
(`run/WordedMaybeInstance`, `run/GenericAnswerAtInt`, `run/GenericAnswerInPair`, `run/MapAnswerAtInt`),
and so did a function that met its holder (`run/FunctionAnswerAtInt`). The cost: where the argument's own
layout is one wide entry (a `Js.Value`, a folded payload), the source at such a location is all of it, and
it all escapes (research report 150 names the fixtures this refuses).*

*Research report 148: an audit of every place in `src/own3/` where a missing fact can become an empty
answer, for the mistake of reports 146 and 147. A helper that cast a list to an `Int` let its contract say
that it keeps nothing (`run/HostValueNarrowInt`); an `Int` read back as a list was a list nobody held, in a
body (`run/HostValueWidenInt`) or in a platform function of `Int → List Int` (`run/HostValueFromInt`); a list
of lists read as a list of numbers and back lost its inner arrays (`run/HostValueNarrowList`). Its review
found a value of no cell read back through a type variable: answered as it is (`run/HostValueVarAnswer`),
in a constructor (`run/HostValueVarCtor`), in a record (`run/HostValueVarRecord`), and by a cast handed to
`Maybe.map` (`run/HostValueVarMap`). A first fix that refused every list write of no cell refused
`bench/corpus`'s `FormValidation.andMap`, whose `++` writes `Invalid`'s list of a `Valid` construction: a
write of no cell is a dead constructor's argument there, so the rule went.*

So the cells of a converted value are where the value is: a cell the host made is `outside` already
(the answer of unknown code, §3.2), and a cell of the frame that went through `Js` and came back is
still that cell, at every location the type gives it. *Research report 146: `Queue.takeAll` and
`Queue.takeN` make their answer with `Js.to` from a `Js.Value`, and their contracts said that the
elements hold nothing; an element was then a cell nobody else held, and `{ v | x = 99 }` of a record
taken back out of the queue was accepted while the program read the record. `Schema.describe`'s
definitions, the elements of `Schema`'s engine lists (`fieldList`, `variantList`, `ctorList`) and the
input of an issue (`Json`, `Schema`) were the same; and so were writes below the folded payloads of
the corpus's polymorphic recursion, which v3 accepted though their fixtures say each is a list another
holder reads (`run/SanitiserFoldedType`, `run/SanitiserFamilyRead`, `ownership/OneListTwoLevels`). The
review of the report found the four facts above: a platform function that answers `( x, x )` at a type
variable had a contract of one location, and a caller that read the answer as a pair wrote one part in
place and read the other (`run/HostValueSplit`).*

## 4. Names

### 4.1 Locations

A location names the cells of a value by its type: a path of labels through the place graph, with one
location for the entry level of a type cycle and one for its deep level (`Loc.zig`, report 111 §2.1). The
call map (`Loc.cover`) maps a caller's locations to a callee's; a location it cannot map is covered by
every signature entry (`Loc.all`), the pessimistic side.

**Two layouts' locations are compared only through the call map** (`Frame.locsMeet`, `anyMeets`). Two
layouts are two readings of one type position, and one can be wider than the other: a type variable
where the other has `List Int`, or a row `{ r | n : Int }` where the other names `items`. The row's
location is no prefix of the field's, so a label path says nothing about whether two locations share a
cell. The map, read in both directions, does: where it maps an entry to an entry of the other layout that
is no narrower, that entry holds every cell of it, and since the entries of one layout name apart
positions, the answer decides whether the two meet. Where neither direction decides, the two meet. Label
paths are compared only inside one layout, or to narrow a wide entry to a part that the type names at
exactly that path, with all of the entry as the fallback.

The map itself pairs a location of a deep level by its label path only where the signature reads that
cycle's region with no type variable and no row (`Loc.cycleWider`). Then the region's type is concrete,
the caller's type there is the same type, and each deep location names the same cells in both. Where the
signature has a variable or a row there, a type argument can name the container again (`Tree2 T`, where
`T` holds a `List (Tree2 T)`), at that variable or in a cycle nested below it, and one deep location of the
caller can hold cells that the signature names at several entries; a location can stand for several
places, so no sample path decides it. Every match the map can take inside that deep level — the location
itself, a wide entry above it, or a row that holds its field — then answers `Loc.all`.

**A reading with the signature's own layout** (research report 158). The danger above is a caller whose
layout splits what a wide entry of the signature names: its places name the container again below the
variable. A reading whose layout is the signature's own, one layout of one place (`cover(sig, of)` with
`sig == of`), has no such split, so each of its locations is the signature's location of the same label
path, a deep level's included (`Loc.cover`): a recursive call at the type the function declares, or a
helper of the same module over the same type (`balance` called by `insertHelp`). This holds only where the
type is regular: a non-regular type's family has one place for all of its instantiations, whose payload
names cells at every depth (`ownership-v2.md` §2.1, *A family*), so `T (List a)` and `T a` are one place of
two shapes. So the place must have no family below it (`Loc.familyBelow`: no `var` place other than the
one place of every type variable, `plain_var`, and none with a step, which a family's payload and a knot
of a type with no name are). *Before, the recursive call of a generic tree's insert was `Loc.all` at its
deep level: each deep location of the answer held every source of the result, keys and values, both
levels, and the answer was `twice` there.*

*Research report 124 F1: the entry compared a
model location with a contract's location by label prefix, so a function over `{ r | n : Int }` held
nothing of the model; report 125 found the same in the composition of answers and of supplies
(`answersAt`, `slotsOf`, and the label tests `Loc.noObject` and `Loc.belowWide`, now deleted) and in a
constructor's row (`ctorValue`); its review found the call map pairing two deep levels of different
cycles (`Loc.cover`).*

**A location of a part that the whole's layout does not name.** A projection maps each location of a
part to one of the whole's (`Loc.Proj.up`, and a path's `to_root`); in a folded type (polymorphic
recursion, §3.4) a location of the part can have none. It can hold any cell of the root, so a reader of
it reads every entry of the root (`leavesOwnWalk`), a test of it reaches (`refReaches`), the index of a
construction's parts reads that part for every entry (`builtIndex`), and an `elementof` row with such a
location is the pessimistic row (`Check.wordedContract`). *Research report 148: these read nothing; in
the corpus's polymorphic recursion a function that pushed an element of its parameter's folded payload
then had a contract that wrote nothing of its parameter (`PolyRecBranch.ww`).*

**A part of a root reads the entries below it** (`Frame.rootReach`, `runsReach`, `entriesBelow`). An
entry's run is every cell of other roots that its location can hold (§2), and a part names exactly the
locations its path maps to (`to_root`). So a read of a part of a root the frame made tests the runs of
those entries and no other: a read of one part of a pair is no read of the other, whatever made the root
(a construction, a call's answer, a cell's contents). A part with a location the root's layout does not
name reads every entry, as above. *#2583: a call's answer read whole at each of its parts, so
`case sel p of ( a, b ) → … List.push a 8 … b` was refused; `run/CallAnswerPartsApart` and its live
twin.*

### 4.2 A fresh cell has a name

A cell a body makes is `Src.fresh(k, escaped)` in its contract: `k` is its **allocation site**, `escaped`
says the body let it escape. Two sources with one `k` may be one cell. In the caller, the sources `fresh(k)`
of one callee read at one holder are **one root** of kind `fresh` (`freshAtom`, keyed by the holder's
`Use.key`, the contract and `k`), so a cell at two result entries overlaps with itself, a cell handed to a
function parameter and answered is the cell in the result, and a cell the callee let escape is noted as
escaped at the call. A known function's cell that it hands a function it captured is read at the inner
use of that function, and is keyed by the known function's own use, as its answer's cells are
(`resolve`, `answerSrcs`). *Research report 165: it was keyed by the inner use, so one cell had two
names, and a function that handed a new list to a captured function that stored it in a cell, and
answered it, said they were two (`run/FreshHandedAndAnswered`).* A `fresh` root has no value and no layout: it exists as atoms.

The site `k` is canonical, so the rounds of a recursive group settle (`freshId`, `Mod.siteId`): a cell the
frame made is named by the instruction that made it and the entry; a cell a callee made is named by the
call and the callee's site; a cell of a callee whose contract is a **draft** (a member of the group in its
rounds, a local function in `solveCodes`' rounds: `Mod.drafts`) is named by the call alone, which bounds
the names of a recursion by its call sites. A local function's contract from an earlier walk of its
declaration (a round of the declaration's group) starts the next walk's rounds, and is a draft while they
run too: read as a finished contract, the cells of its own recursive call had new names in each walk, and
the group never settled (`TailModConsBranches.chunks`, 66 walks; research report 138). Collapsing two cells into one name is on the pessimistic side.

A worded row's new cells are one site, `0` (`Check.wordedContract`), but where the row says `exclusive` or
makes a cell's handle (§6 rule 10).

### 4.3 The frame's own cells

A root the frame made has an **own atom** at an entry whose kind has one (`REntry.hasOwn`): `own`, a cell
the frame made; `derived`, its own cell or those of the run (a prepend that may answer its base's array);
`version`, the new name of cells a callee wrote and answers; `taken`, an element a trusted loop took out.
`alias` has none: the location is its run (a call's result; the fresh cells of the callee are `fresh` roots
in the run). In the contract, an own atom of `own` or `derived` is `fresh(k)`; an own atom of `version` or
`taken` is the sources of its run, never `fresh`: it names an array that exists (`atomSrcs`).

### 4.4 Duplicates: `twice` and `linear` are derived

A **summary** location names the cells of many positions (list elements, a deep level). One cell at two of
its places cannot be seen by atoms alone, so it is a fact of the entry: `REntry.twice`, and `Src.twice` in a
contract. It is derived in **one test**, `partDup`, where a run is built from parts: a part that holds a
cell an earlier part holds (`dupOverlap`). Every test of a set of runs for one cell in two of them
(`partDup`, `deriveLinear`, `finish`, `operandLeaves`, `runsApart`, `expandSrcs`) is `runsShare` when
the set holds more than 64 atoms: the same answer as the test of every pair, in time about linear in the
atoms (§8). Two overlapping atoms are two cells only when they were read
through two **apart parts** of one root the frame made that holds each cell once (`viaApart`: the same
`via`, `linear`, and two parts with different entries or incomparable paths). An atom records the part it
was read through (`Atom.via`, `via_path`, `via_e`, set in `copyAtoms`), so two reads of one part of a list
the frame made — `[ a, a ]` with `a` read out of it — are one cell. `leavesOwn` applies the test to
the parts of a construction and the entries of one part; `listOf` to the items of a literal; `expandSrcs` to
the sources of a result entry; `finish` to the result's entries. A `twice` entry keeps its claim; its parts
are not apart (`rootLeaves` reads a part of it as all of it), and a callee that writes it is refused
(`demand`, cause `element`).

**A worded row builds no run** (research report 156, #2557). A row is not walked (§6 rule 10), so no part of
its result is tested against another, and nothing derives that a cell is at one place of a summary location
of its result: `(a) => [a, a]` is as true of `stored a → fresh List a` as `(a) => [a]` is, and the words say
no count. So each summary location of a row's result that holds a cell is `Src.twice` (`Check.wordedContract`),
unless a word states the positions of what it puts there (`Check.statesPositions`, which the marker and
the safe-build check of §9 both read, so the two cannot read the list below two ways):

- `returned`, `builderdone`, the list of `prepended` and the elements of `copyof` and `concatenated` put a
  location of a parameter at the result's location of the **same place**: the result there is the parameter's
  own positions (`returned`, `builderdone`: "the same cells, children and κ", `ownership-v2.md` §2.13.6), a
  copy of them (`copyof`: "a fresh copy of … storage", `language.md` §5.4; `[*] = π₁[*]`), or two lists one
  after the other (`concatenated`, `prepended`). A cell at two of those places was at two places of an
  argument, which the apart-arguments rule refuses at the call;
- `stored` beside a `written returned` parameter is one write at one position of that list (`put`, `push`,
  `set`, `insertAt`, `focus`'s stored answer: "stores parameter 3 into `[*]`, computing κ by §2.9 at every
  store"), and the first parameter of `prepended` is the one item in front. Each puts the location at the
  result's element location or below it, nowhere else. "That list" exists only where the row writes one
  list and answers it: exactly one other parameter is `written returned`, it is a list at its root (its
  place has an element step: a `sequence`, `List` or `Builder`), and so is the result. The stored value
  (or the callback's answer, or `prepended`'s item) is an element: its type is the element type of the
  result and of that parameter. A value of another type is put below an element, inside a container no
  word names (`l.push([a, a])` for `stored List Int` into a `List (List (List Int))`), with no count: it
  is at every element location, never at the one its label path names (`intoElems`), and `twice` there.
  `stored` is "a value retained at the result's `[*]`" (`ownership-v2.md` §2.13.6), and `written` is a write of the parameter's own storage at `ε`. Where
  the `written returned` parameter is no list at its root (a record, a tuple, `Maybe`, a scalar, a type
  variable), the row writes no list that a word names: `written returned { items : List a }, stored a →
  { items : List a }` writes the record's own storage, and no word says that the item goes into `items`,
  or how many times. Where two parameters are `written returned`, it can write two lists. Where the result
  is no list at its root, it has no `[*]`, and the row puts the location at every location of the result
  (`intoElems`): a placement below another place. Each of these is `twice`. *Before research report 157
  the marker read `stored` beside any `written returned` parameter as one store, at any location of the
  result, and the safe-build check read it at element locations only: the check panicked on such a row
  (#2559, `run/WordedStoredRecordDest`). Both read a store beside a `written returned` `Int` as one
  (`run/WordedStoredScalarDest`), and a value of another type at the element by its label path
  (`run/WordedStoredBelowElement`): each wrote in place while a copy the words did not count was read;*
- `exclusive` says outright that each new cell of the result is at one place.

Any other placement states no count, and is `twice`: `stored` into a new list, `fresh` without
`exclusive` (a row of no parameter that answers one new record twice), `elementof`, `taken`, `aliased`, a
parameter with no word, `unknown`, `Record.copy`'s values, a word that puts a location below another place
(a wide parameter over the result's parts), and every location of the pessimistic row (`undescribed`). A
walked body is not affected: its contract's `twice` is derived by `finish` from the runs its walk built, and a
caller of a function that calls a row reads the row's `twice` there as at any call. A row that states
positions its JavaScript does not keep (`copyof` answering `l.concat([l[0]])`) is a false row, as one that
leaves out a word is (rule 10). *Before research report 156 a row's result was read as holding each cell once:
`gg (dupW r)` with `gg list = case list of [ b, …rest ] → …` wrote `b` in place while `rest` held `r`
(`run/WordedStoredTwice`; the safe twins over the rows of `core/` are `run/WordedPositionsApart`).*

`Root.linear` says that no cell of another root is at two places of a root the frame made. It is
three-valued (`Frame.Linear`): `undecided` until `deriveLinear` ran, the one writer. A reader that meets
`undecided` reads it as `no`, and safe builds assert that none does (`isLinear`). For a literal the frame's
atoms decide. For a call's result the callee's claim (`!Contract.nonlinear`, derived in the callee's
`finish` from its own atoms) is taken **only as far as the callee could see**: only when the arguments are
apart (`argsApart`: a contract is written for arguments of which no cell is at two places, and where that
does not hold every summary entry fed by two sources, or by an answer that can hold a cell the holder handed
on (`SrcState.handed`), is `twice`, and the result is not linear: an answer that holds none holds cells
the function made in its run, which no two runs share, captured cells, which are `twice` already, and
cells outside the frame, so a cell at two places of the arguments is at no two places of it; research
report 143), and never for an entry that holds the **answer of a function parameter**, which the callee's frame
saw as an opaque root: a pair of entries with one is tested by the caller's atoms (`apply`,
`deriveLinear`'s `answers`). Within one summary entry, two sources are tested as atoms, with one named
exception (`alternatives`): the answer of a function `g` and a parameter location the callee hands `g`
`free` are alternatives, because a cell handed `free` is read by the callee no more, so it is in the answer
or it stays, never both (the `taken` rows of `core/`).

**Two readings through a later root** (research report 159, #2564). An atom records the first root the frame
made that it was read through (`via`), and two of its readings are two cells where that root holds each cell
once and they were read through two of its parts. A cell can then go through a second such root: a call's
answer (`balance`'s, in a red-black tree's `insert`) that holds the answer of an earlier call (the recursive
`insert`) at two of its entries, one in each arm. The second root's claim (`linear`: no cell is at two of its
entries) says that its two entries hold two cells; but the atoms copied there name the first root, at one of
its entries, so they were one cell, and the tree's deep level was `twice`. So an atom also records the last
root it was read through and the entry (`Atom.via2`, `via2_e`, `copyAtoms`), and two readings are two cells
where that root holds each cell once and the entries differ (`via2Apart`, read by `viaApart`). Each root's
claim is about its own entries, so either one tells the readings apart. A part and a part below it in one
entry are not told apart by the later root (the pessimistic side). The linear-time duplicate test (§8) keys
its tables by the first root alone, so where an atom of another key that it finds is apart from the atom by
the later root, it compares the atom with each atom of its group (`TablesShare.all`): the answer is the test
in pairs', as before. *Before, a value taken out of a dictionary that `insert` built was refused (`element`),
in a tree of a user's own type as in `core/`'s `Dict` (`run/TreeInsertRebalanced`; the live twin is
`run/TreeInsertShared`).* What it does not cover: `core/`'s `Dict` read by a caller at an instance of `Dict k v`
(`Dict Int R`), whose deep level the call map reads through the type variables as `Loc.all` (§4.1); every
value of such a dictionary is still at both levels of the caller's reading.

**The parts of a list pattern are apart** (research report 154, #2548). A list pattern `[ p₁, …, pₙ, …r ]`
(the spread anywhere, or none) binds the items at n distinct positions of one list and, through its
spread, a view of the other positions. Where the list holds each cell once, no cell is in two of these
parts: an item is the cell at its position and the cells below it, the spread the cells at the other
positions and below them (and the list's storage, which no item is). The list holds each cell once where
the scrutinee is a part of one root N that is

- a **parameter**, by the apart-arguments rule: a callee's contract is written for arguments of which no
  cell is at two places; a caller reads its claims about the answer only where that holds (`argsApart`),
  and a callee that writes a summary location of an argument that holds a cell at two of its places is
  refused at the call (§5, test 1); or
- a root the frame made that is `linear` and has no `twice` entry.

Then each part is a value that carries the match and its position (`Node.pos`, `Frame.listParts`), every
atom of it carries them too (`Atom.pos`, set where its leaves are read and kept by `project`), and two
atoms of one match at two positions are two cells: `overlap` says no, so the four tests of §5 and the
duplicate test above treat them as apart. A match is one run of the binding in the walk (`Check.Mod.
next_match`), not the instruction, since a body can be walked more than once; atoms of two matches are
compared as before. A part matched again by an inner pattern takes the inner match's positions and gives
up the outer one's (the pessimistic side). A scrutinee of any other root — the answer of a function
parameter, a capture, a cell a callee made, `outside` — or of a construction or a join carries no
position. A set of atoms with positions is tested in pairs (`shareWith`): the tables of `runsShare` keep
two atoms of each path by their `via` alone. *Research report 153 §5 and a blind round (#2548): a walk
`[ b, …rest ] → loop rest (List.push acc (write b))` was refused, `disjoint`, as was `rest ++ [ x ]`
(`twice`): `b` and `rest` read one summary location, and no atom said at which position.*

**The parts of a constructor pattern are apart** (research report 158). A constructor pattern `C p₁ … pₙ`
(n ≥ 2, a constructor with a row) binds n arguments of one object: where the value holds each cell once,
no cell is in two of them. Each is one location of the value's layout, but in a recursive type two
children (`Node k v l r`'s `l` and `r`) read one deep level, so only a position says they are two. So under
the same condition as a list pattern's (the scrutinee is a part of a parameter, or of a `linear` root the
frame made with no `twice` entry: `listParts`), each argument is bound at a position of one new match
(`bindPattern .ctor`). A scrutinee that carries a position already, a part of a list pattern's match
(`[ Rose l k, …rest ]`), keeps it and starts no match: its parts are apart from the list's other parts by
the outer match, which an inner one would give up (`run/CycleLinkReadAfter`'s walk).

**One value of a join at a time** (research report 158). A contract says it is `nonlinear` where a cell of a
parameter can be at two locations of its result (`finish`). The result is a `join` of the values of its
`case` arms and its return points, and a run answers one of them: a cell at the entry level in one arm
(`Leaf → Node x Leaf Leaf`) and at the deep level in another (`Node v l r → Node v (go l x) r`) is at one
place of each. So where the runs of the merged result say a cell is at two locations, and the result is a
join, each of its values is tested on its own (`atTwoLocations`, joins nested to depth 8; deeper, the merged
runs, a superset of each), and the contract is `nonlinear` only where one of them has a cell at two
locations. A location's own `twice` (one cell at two places of one summary location) is read as before.
*Before, a recursive insert into a tree was `nonlinear` because its argument was at the root in one arm
and below it in the other; its caller then read the deep level as `twice`, and a write of a list the tree
holds was refused (`ownership/ReturnedKids`, `LevelFresh`, `FoldLevels`).*

## 5. The write rule

A write of the atoms W at time t is accepted when (`demand`, `finishDemands`):

1. **permission**: no atom of W has root `outside`, `capture` or `answer` (a function parameter's answer is
   never the frame's own), and W is not a `twice` summary location written by a callee. A function value
   that writes below the location a callee hands it (a whole list, whose elements it writes) writes a
   summary location where the written one is one, though the handed one is single (`OwnSink.atoms`;
   research report 154: `app [ r, r ] λl → …` wrote `r` at two places, `run/PatternPartsHanded`);
2. **no other operand**: no other operand that the operation reads or answers reaches W (`otherReaches`). A
   callee that answers a parameter location holds its cells in the result: where it writes the same cell
   through another parameter, the answer is the written cell, so the location is an operand of the call
   whether the callee reads it or not (`Contract.flag_a`, §11). Another
   location of the written operand itself, when the operand is a part of one root N, is another place of N:
   its cells are apart from W when N holds each cell once — a parameter by the apart-arguments rule, a root
   the frame made by its own `linear`, never the answer of a function parameter. A location of the operand
   that the call map cannot place (`Loc.all`: a deep level whose region the signature reads with a type
   variable) is at every location of the signature, the written one and each other the callee reads or
   answers: it is another place of the operand wherever another location has a flag, apart from W only
   when the operand holds each cell once (`valueApart`) and the location holds no cell at two of its places
   (research report 148: it was skipped as the written location itself, and `T xs [ T xs [] ]` handed to a
   callee over `T a` that wrote the entry level and read the deep level was accepted, `run/CycleVarOtherPlace`);
3. **no escape**: no escape whose context is compatible with the write's overlaps W. An escape owns a copy
   of its atoms (`esc_atoms`), and where the answer of a function parameter escapes, so does what the
   function was handed (`Answer.base`, in `noteEscape`): the answer can hold it;
4. **no later read**: no read at a time after t, in a compatible context, reaches W (`useReaches`).

**Theorem.** If the four tests pass, no live reference reads the old value, and the in-place program prints
what the copying program prints. Argument: every cell the frame can observe is an atom of some root (§2);
every consumer records a read of every atom it can observe (`readAll`, `readBy`, a list pattern, the
frame's result); every holder the walk does not follow records an escape of every atom it can hold (§3.2,
§6.10), and so does the default that a holder hands a function's function parameters (§6.2) and a value
that a lowering keeps beyond the call that made it, which the lowering names (§5.3, §6.14); a
write by a callee is a demand at the call (§6.2); and every call into the program's code that no walked
body makes — by the markup runtime, the entry's runtime, derived code, a schema's compiled workers, host
JavaScript, or a callee of `core/` or a platform — is in the list of §6.14, each with the rule that
applies it: as a call where the program hands the caller what it calls the code with, or as a function
in the default location (§6.8), which writes nothing. The list is derived from where the backend emits
and roots code, and safe builds check that every instruction that names code in an emitted declaration
was walked (§6.14, §9). So an observation of W after t is a read after t, an escape, or another operand
— each refused.

*Research report 128: the theorem named two callers of this kind (the rows of markup, the record of an
entry), and a schema's print worker, a third, called a `via` function that no walk read. It was the
third time a hand-written list of these callers proved incomplete (markup rows and keys, report 121; the
entry's functions, reports 121 and 122). Report 129 found a fourth, host JavaScript in a `--library`
build.*

### 5.1 New names

Where a callee writes a location and answers it, the result's location is a new atom (`version`), and the
old names carry the time of that call (`Atom.dead`, `oldNames`). The holder of the new name is no reader
of the old value for a write at that time or before (`isOld`); for a later write it holds the same cells.
This is what makes test 4 one test with no definition points (report 111 §3.10).

### 5.2 Grounds

A line says what its acceptance rests on (`groundOf`): `fresh`, a cell the frame made; `call`, a callee's
contract; `param`, the caller's hand. A `fresh` root's ground is `call`.

### 5.3 One clock

Every read, write, escape and new name has a time from the walk's clock (`timeOf`), which advances with
the walk in the order the emitted JavaScript evaluates (`language.md` §6). An instruction number is never
compared for order.

The clock orders one call of the code. It says nothing of a value that one call makes and a later call
reads: a value that a lowering or a runtime keeps beyond the call that made it. The walk sees a value
made on each call; the program reads, at a later call, a value an earlier call made, and possibly wrote.
So such a value is a holder the walk does not follow, and **it escapes where it is made** (§6.14, *What
a lowering keeps*): every write of it, or of a cell it shares, is refused by test 3, at any time of the
walk. The clock is never asked to order two calls.

*Research report 133 §4, report 134: the `dom` lowering keeps a `let` that only its root reads from one
render to the next (`backend.md` §15.4, *The `let` rule*); the walk saw it made on each call of `view`,
and a push of it in place, which nothing read after in that call, passed the four tests. The next render
pushed onto the same array.*

## 6. The rules, one for each construct

Each rule keeps the invariants of §2. The argument is one sentence each.

1. **Bind** (`binding`, `bindPattern`): a binding makes another holder of the same value and reads nothing.
   A list pattern reads its list (`readsList`); its parts are apart where the list holds each cell once
   (§4.4, `listParts`); a pattern a row does not describe binds `unknown` over the scrutinee. *Invariant:
   the bound value's leaves are the scrutinee's part's leaves.*
2. **Call** (`call`, `apply`): the callee's contract says, per parameter location, read, answered, written, escaped,
   handed to a function; each escaped location escapes and each function handed flows (`flow`, which can
   escape a function's answer) **before** each written location is a demand at the call with the other
   arguments as operands, so a write is judged against every escape of the call; the result's entries are the contract's sources expanded to
   atoms (`expandSrcs`: a parameter source to the argument's leaves, `fresh` to a `fresh` root, `outside`
   to `outside_atom`, an answer to what the function there answers: of a join of functions, what each arm answers, each
   function and its captures one answer in work, `SrcState.visit`; #2588). A callee with no contract is unknown
   code (§3.2). A contract of another arity is a partial application: every value flows to `top` and
   escapes, and the callee is at `top` (rule 8's invariant). **A function that a holder runs is handed, at
   each of its own function parameters, a function in the default state** (`defaultParams`): whatever a
   holder's frame hands a function parameter is a value that no contract follows there, so it went to
   `top` (`mention`), and the default hands one too. So each such parameter is the default meeting its
   use: what the function hands it escapes, and a function that writes a cell after it handed the cell
   there (`Fn.rewrites`) is refused. This holds wherever the holder can run the function — it calls it
   (`Fn.called`), it loses it, or it is the default. Only a direct call, where the frame flows each
   argument to the callee's contract for it, hands a function parameter a known function. *Invariant:
   every cell the callee can hold or answer is in a demand, an escape or the result.* *Research report
   124 F2 and report 125: a function that hands a list to its callback and then writes it was judged
   only where it was called directly, and never where a holder runs it.*

   **A capture of a named function** (*added 2026-11-27, #2657*; `Frame.namedCapture`). A call, in a
   lambda's or a local function's frame, of a capture whose local a `let` binds, with no parameter, to a
   reference to a top-level function (`fl = List.foldl`) is a call of that function's contract, as the
   reference itself is in the frame that binds it. A local is bound once, so every closure that captures
   it captures that one function value; the evidence of a reference is judged at the reference (rule
   11). Before, the capture was the frame's own function parameter, and a lambda that writes its
   parameter handed to it was refused as going where the checker does not follow it
   (`browser/inline/NestedFoldValue`).
3. **Capture** (`capture`, `codeValue`, `solveCodes`): a lambda or a local function is walked in its own
   frame, its captures are parameters of its contract, and the closure value holds them (`closureOf`). A
   capture bound after the closure is made is a `later` slot read as the value bound there (`capVal`;
   lowering guarantees it is bound before any run). Local functions that name each other in a cycle are
   one group walked to a fixed point (`findGroups`). *Invariant: a closure's leaves are its captures' at the
   locations a run of it reaches (below), or all of them where it is held whole.*

   **A kept closure is observed only through its calls** (`escape`, `heldLeaves`). A holder that the walk
   does not follow and that keeps a closure (an item of markup the runtime keeps, unknown code, a holder
   that lost the function) can do one thing with what the closure captured: run its code, at any time, any
   number of times. JavaScript gives no other way into a closure's environment, and an identity compare of
   the function reads none of it. A run of the code reaches a location of a capture only where its
   contract says so: a flag (read, written, escaped, handed to a function that can write), a source of its
   answer, or a supply to a function. So the cells a kept closure holds are the leaves of its captures at
   those locations, and only they escape; a capture location with no flag, no source and no supply is one
   that no run of the code reaches. A captured function (what its own calls reach is another contract's),
   a contract that casts (§3.4: its reads are not where the types say), and a draft (a contract of a round
   of a group, which can still grow) escape whole. *Research report 153: a handler `λ_ → Toggle todo.id`
   kept by the markup runtime escaped every slot of `todo`, and `update`'s in-place write of
   `todo.completed` was refused (TodoMVC); the handler reads `.id=` alone.*

   **Every holder of a closure observes it only through its runs** (*amended 2026-11-24, #2652*). The
   same reading holds wherever the walk reads the cells a closure holds, not only where a holder keeps
   it: a closure's leaves (`leaves`, so `allLeaves` and a result's sources; `reach`, the test of another
   operand, still reads each capture whole, the pessimistic side)
   are its captures' leaves at the locations its contract reaches (`closureReached`: a flag, a source
   of its answer, a supply, or a renewal of a cell it was handed, `capHeld`), and every cell
   of them where it is held whole (a captured function, a contract that casts, a draft). A writer's
   handle among the captures is kept: two holders of a handle are a fact of the handle (§13), not of
   an escape. A run is the one way into the environment, wherever the closure is: in a command, a
   subscription, a record, a tuple, a callee's answer. *Before, a closure inside a value held every
   cell of each capture, so `Cmd.task (λ⊤ → Navigation.goBack model.key 0) …` in `update`'s answer
   held every location of the model, none was `update`'s own (rule 13), and every write of `update`
   was refused (`browser/tea/NavigatePush`; `run/ClosureFieldInPlace` and its live twin).*
4. **Construct** (`built`, `listOf`, `spreadChain`, `appendChain`): a tuple, record or constructor names
   each part that holds a cell; a list literal's storage is the frame's own cell, its elements are the
   items' leaves as one run with `partDup`; a spread's base is written (a demand) and its storage is a new
   name; a prepend may answer its base's array unless the item is a new object (`newItem`). A list whose
   place has no element step — a literal typed by a callee's type variable, as `Js.call`'s argument list
   and `Js.object`'s fields are — has no location for its elements, so it is `unknown` over every value
   it was made of (§3.2); before, its elements went nowhere, and a list handed to JavaScript inside one
   did not escape (report 117 §10; research report 120 §5 found the same hole through `Hosted.tap`, where
   a subscription's body lost what it captured). **A record alias's constructor builds the record**
   (`backend.md` §4), so its application is the record literal it stands for, with its object and its
   slots (`recordOf`, §11.2), and as a function value its contract answers a new object: each slot of its
   answer is a cell it made (`ctorValue`). *Invariant: a part the construction does not name holds
   none, and a construction that cannot name its parts is `unknown`.* *Research report 147: the
   alias's constructor built a construction of its fields alone, so `a = P n [ 1 ]` had no slots, `{ a |
   k = 5 }` wrote no cell, and `a.k` read after it read 5 in place.*
5. **Project** (`project`): a step on a root extends its path; on a construction takes the named part, or
   `none` where its own place has the step and no part is at it, or `unknown` over the construction where
   its own place does not have the step (§3.4, `builtAbsent`); on `unknown` stays `unknown`; on a closure
   is `unknown` over it. *Invariant: a part's leaves are a subset of the whole's, and a step a value's own
   place does not have is no claim.*
6. **Pattern and `?`** (`bindPattern`, `evalInner .try`): a constructor pattern projects by the row of its
   constructor; **a record alias's constructor pattern is a record pattern** (`backend.md` §4): its
   argument `k` is the field the alias writes `k`-th, read out of its slot where the pattern matches
   (§11.4), whatever form binds it (`case`, `let`, `as`, a parameter, a lambda); `?` on `Result` or
   `Maybe` is the argument of the first constructor (`language.md` §6.6), any other type `unknown` over
   the scrutinee; the failure answers the scrutinee (a read), at the frame's answer place
   (`tryFailure`): where the two layouts differ it is `Nothing`, which holds nothing, or the scrutinee's
   `Err` argument at the answer's `Err`, never the success part. *Research report 147: the alias's pattern
   projected by a constructor's step, which a record does not have, so it bound nothing and its contract
   read no slot. #2595: the scrutinee itself, read at an answer of another type, put a list at a cell's
   handle and the contents below it at no location of the scrutinee, and a safe build stopped
   (`run/CellTryAnswer`, its live twin `CellTryAnswerLive`).*
7. **`if` and `case`** (`caseOf`, `joinVal`): the value is a `join` of the arms, each with its context; two
   arms of one `case` are never one run (`compatible`), so a holder in another arm is no holder.
   *Amended 2026-11-21 (#2594).* The arm stays on what a run takes from the join: each atom that a
   walk of the join finds in an arm holds that arm's context (`Atom.ctx`, the innermost arm it came
   through), and a call's answer, a version and every other run made of the join keep it. A later
   read is no holder of an atom whose arm is another arm of a `case` that holds the write
   (`atomLive`, in the later-read test of §5 alone): on the run where the write runs, the join was
   never that arm's value. So `ys = if c then List.set xs 0 7 else xs` read through `idl ys`, and a
   cell written in one arm and read after the `if` (§13 item 6), are accepted. Two atoms of one cell
   from two arms are two atoms of the run (`atomEql` compares the context), so neither arm's is lost.
   *Amended 2026-11-22.* An atom found through an arm of a join that an arm of another join holds is
   held on a run through both arms: where one arm is inside the other it keeps the inner one, and
   otherwise their **meeting** (`meet`, `Ctx.both`), which is live only where each of the two is
   (`ctxLive`). Before, it kept the first arm it came through, the inner join's: in two `if`s in a row
   that write one cell, what the second `if`'s other arm keeps of the first `if`'s value read as held
   where the second `if`'s write runs, and `Ref.get` after both refused that write (blind round BM,
   `twoIfsOneCell`; `run/CellWrittenInTwoIfs`). The meeting is as pessimistic or more than each arm
   alone: a run that holds the atom goes through both. A meeting keeps two arms, the innermost and
   the outermost of the way the atom was found through: a meeting of every arm on the way tells each
   way apart, and in a chain of `case`s that each answer the value before, the atoms grew as the ways
   did (`check_test.zig`'s chains: 26 s and 2.6 GB at 30 levels). Dropping an arm is the pessimistic
   side, so of three `if`s in a row, a write in the middle one is held by what the others keep.
8. **Loops** are recursion and the worded loops of `core/`: a function handed to a callee flows to the
   callee's contract for it (`flow`); where the callee hands the function its own answer (a fold), the
   answer must be the function's own (`answerOwn`), because the callee hands it back as a parameter that
   the function may write. Its own means that no other holder of it exists, and every holder that the
   function's contract can name is a source of the same cells somewhere in that contract: so the answer
   is its own where each source of it is a cell the function made whose site has no escape bit, is at no
   other result location and is in no supply to a function (`freshOwn`), or a parameter handed `free`
   that the function did not let escape, answers at no other location, and handed to no function that
   keeps it (`handedBack`), or the answer of a function that it captured which passes that answer on
   once. *Report 118 §4.5: the text asked "did not let go" of a parameter only, and a new list that the
   function put in a `Ref` and answered came back as `own`. A cell the function made is one source
   among the others, and the same three facts are read for it.*

   **A function parameter whose answer the function lets escape** (`Fn.ans_escapes`) can answer what the
   holder hands it, at any depth: so what the holder hands at that parameter escapes where the
   function meets the holder, as where the function lets the parameter itself escape (`flowCode`).
   The answer of the frame's own function parameter holds the function itself (`ownAnswer`, as
   `callParam`'s does). *Research report 165: only the parameter's own flag was read, and `List.map [
   λ⊤ → y ] λq → Ref.set holder (q ⊤)` let `y` be written in place while a top-level cell held it
   (`run/CallbackAnswerKept`).*

   **What a function in a default location may ask.** The code that runs a function in a default
   location (`flowCode` with `top`, a holder that lost it, a partial application) runs it at any time,
   any number of times; it hands each parameter a value with no claim, each function parameter a
   function in the default state (which keeps what it is handed and runs at any later time), and it
   keeps the answer. Of the facts a contract carries, two ask something of the code that runs it, and
   both are refused there: a written parameter location (`writesOwn`), since the value has no claim;
   and a function parameter whose `Fn.rewrites` is set, since the function there keeps the cell that is
   written after (`defaultParams`). The other facts ask nothing: a read; an escape; an answer, which
   the default keeps; what it hands a function parameter, `free` or not, which escapes, since the default
   writes nothing; whether it calls it; a captured function, which goes to the use the two
   contracts compose to (`flowCaptures`). `rewritesOf` is false at `top` as a derived fact, not a
   default: the default hands only cells outside every frame, so it writes no cell after it handed it.
   *Invariant: a function in a default location asks nothing and keeps what it is handed (`flowUnknown`,
   `flowCode` with `top`, `defaultParams`).* *Research report 124 F2: the text said "asks nothing", the
   code asked only `writesOwn`, and a function that wrote what it had handed its callback was accepted
   in a `Ref` or as a command's body.*
9. **Recursion** (`Check.solveGroup`, `solveCodes`): a group starts from the contract with no flag and no
   source and is walked until no contract changes; contracts only grow (`Contract.join`), so the last
   round's verdicts stand on the least fixed point. Each round walks the members callees first
   (`groupOrder`): a depth-first walk of the group's own calls, from each member in the order of the names,
   each member after the members it calls, the calls of a body in the order it writes them. The order reads
   the names and the bodies, never where a declaration stands in the module, so how many rounds a group
   takes, and whether it settles, does not depend on the order of the declarations. *Research report 141:
   in the module's order a ring of 40 functions written callers first moved its contract one member a
   round and did not settle in 64; reversed, it settled in a few.* A function value declared with no parameter,
   whose body is a lambda of its signature's arity, starts from its signature's bottom contract
   (`Check.bottom`), as a function does: with no
   contract at the start, a member walked before it read it as unknown code, and what escaped then stayed.
   Fresh names of drafts are bounded (§4.2). A member
   whose walk gave up has no contract in that round and after. A group that has not settled after 64
   rounds publishes no contract for any member (§8): a contract of a round before the fixed point says
   less than the group does. The rounds of a member share its one step budget (§8): a member past it
   stops the rounds, and no member publishes a contract.
10. **`foreign` and the rows of `core/`** (`Check.wordedContract`, `Check.wordedFn`): a declaration with
    ownership words is not walked; its words are its contract, a trusted row. A result the words do not
    describe is `undescribed`: `outside` (no frame may write it) and every cell of every parameter at any
    place (`nonlinear`). A function parameter the words do not describe is handed every cell of every
    parameter, not `free`. The word `fresh` names one site, `0`, for every location of the result: it says
    that the cells are new, not that two locations hold two of them, and a row builds no run (§4.4), so
    `(n) => { const r = {}; return {a: r, b: r}; }` is as true of `fresh R × R` as two objects are.
    `fresh exclusive` names one site for each location (a builder's storage and its elements are two
    cells), since `exclusive` says that no new cell is at two places or two paths; so do `cellnew` and
    `cellempty`, whose handle is one new cell. `copyof` and its kin name one site, the new list. *Before
    research report 156 every `fresh` row named a site for each location, so the two parts of such a pair
    were two cells, and an update of one was accepted while the other held the record
    (`run/WordedFreshShared`).* A `foreign`
    with no word has no contract: unknown code. *The missing fact is the pessimistic one.* A word that
    puts a parameter's location in the result (`returned`, `stored`, `elementof`, `taken`,
    `builderdone`, the elements of `copyof`) puts it at the result's location of the same place (for
    `stored`, of the result's element, where the value is of the element's type, and at every element
    location where it is not: §4.4) and,
    where the parameter's location is wide, at every result location below it (`Check.holdsAt`, §3.4):
    a word that matched the place alone gave the locations below a wide entry no source. No row of
    `core/` or of a platform has such a pair today (research report 146). A location of a parameter
    that no location of the result holds is at every one of them, for `builderdone` as for
    `returned`; the wide storage of a `copyof` parameter (one of a type variable) holds its elements
    too, so it is read as one; and the answer of a function parameter that holds a cell, where no word
    (`returned`, `stored`, `aliased`) puts it in the result, escapes (`Fn.ans_escapes`). No row has any
    of these today either (research report 148).

    **A word that puts a location in a result with no location to hold it lets it escape**, as a
    walked cast does (`narrowed`, §3.4): `returned a → Int`, `stored a → ⊤`, `aliased a → Int`,
    `elementof Int`, `taken Int`, the elements of `copyof Int`, a storage that `concatenated` or
    `prepended` puts in a result of no storage, and `builderdone` at a result of no location each set
    the escape flag of the location (`Check.wordedContract`, `intoElems`, `elemsToElems`, `selfToSelf`);
    a function parameter's answer that `returned`, `stored` or `aliased` puts in such a result escapes
    (`Fn.ans_escapes`). So does a location that a result location holds where a part of the result
    below it has no location and the location is wide, so its cells can be there (`returned a → a ×
    Int`, whose JavaScript answers `{a: a, b: a}`; `stored a → List a × Int`; `returned a → { l : a,
    n : Int }`), unless a wide location of the result holds it whole (`Check.placedSafely`; `aliased`
    and an answer anywhere, `placedAnywhere`). A word that puts a wide location at the place of
    another type (`returned a → b`) casts (`Contract.casts`, `Check.castsAt`, §3.4): another type by
    the types of the store, not by the places, since every type variable is one place (`a` and `b`,
    `List a` and `List b`); `stored` at the place of the result's elements, `elementof`, `taken` and
    `builderdone` likewise, and `aliased`, which puts the location at any place, casts where the result
    has a type variable of another type than the location's (`aliasedCasts`). A row that casts answers
    its parameter at or below its answer, at a depth no word names: its call is no identity, however its
    caller fills the variables in (`run/CastRowSameLayout`: `returned a → b` read at `List Int → List
    Int`, JavaScript `(a) => [a]`); `Js.from` and `Js.to`, which cast by their types, are identities by
    the code the build writes (§3.4, *What a value was made from*). Safe builds read the words and the
    types again (`Check.checkWordedCasts`, §9). No row of `core/` or of a shipped platform casts that
    did not before (research report 151): `Js.from`, `Js.to`, `Ref.update` and `Ref.modify` cast by
    their places already, and `Task.raceOk` (`many aliased List (⊤ → Result e a)`) casts now. The
    JavaScript value is what the word says it is, and a cast reads it back; "at
    every location of the result" is at none when there are none, and a location placed nowhere was
    gone. A result of no location that no word describes holds no parameter: each parameter has a word
    that does not put it there (`List.length : borrowed List a → Int`), and those words are the
    positive facts. Only the result word `unknown`, and an element a word names that the list's layout
    cannot place, make every parameter location escape there, where the result has no wide location
    at its root that holds them (`undescribed`, `placedAnywhere`). Safe builds check each
    row: every location a word puts in the result is a source of some result location or escapes
    (`Check.checkWordedPlaced`, §9). The rows of a type variable that a caller reads at a type of no
    location are §3.4's: the call lets what it cannot place escape. No row of `core/` or of a shipped
    platform has a result of no location with such a word (research report 150).

    **A row's summary location is `twice` unless a word states positions** (§4.4, *A worded row builds no
    run*; research report 156): the words say where a location goes, not how many times, so only the
    words whose definitions name positions — the same place for `returned`, `builderdone`, `copyof`,
    `concatenated` and `prepended`'s list, one store for `stored` beside the one `written returned` parameter, where it and the result are
    lists at their roots, and for `prepended`'s item, each a value of the element type at the result's elements, and `exclusive` — leave a
    summary location of the result without `twice` (research report 157: `stored` beside a `written
    returned` record states no position). Safe builds check what the marker did with that reading
    (`Check.checkWordedTwice`, §9). No row of `core/` or of a shipped
    platform changes a verdict (every demand of the 2 856 ownership roots has the verdict it had).

    **A position** (research report 159, #2563). `List.get l i` … `List.set l i v` replaces the
    element that the `get` read, and no word said so: `set : written returned List a, borrowed Int,
    stored a → List a` is as true of `insertAt`, which keeps it, and no rule reads `set` by its name
    (rule 11). The word **`position`** on parameter `q` says that `q` names one position of the list
    that parameter 0 is: the element that `elementof` answers is the one at that position
    (`unsafeGet : borrowed List a, borrowed position Int → elementof a`), and where parameter 0 is
    `written returned` beside a `stored` parameter, the stored value goes into that position in
    place of the element there, and the result's other elements are parameter 0's at the other
    positions (`set : written returned List a, borrowed position Int, stored a → List a`). Only v3
    reads it: it is kept in a column of its own (`Ast.OwnWord3`, `Bir.ownSlotsV3`), beside the
    signature's other words, which stay in v1's or v2's column, so v1 and v2 read the row as before.
    Lowering accepts it on one parameter after the first, a value, in a signature whose parameter 0
    the words read so (`own_position_word`). The row marks each source of parameter 0 at or below
    its element location (`Src.p`; the dump writes `π1@1[π2]` at the position and `π1@1[≠π2]` at the
    others), unless the row casts, places a location at any place, or is pessimistic
    (`Check.wordedContract`).

    A caller reads such a source at the positions of a **match**, as a list pattern's parts
    (§4.4): one match for each list and index local of the frame (`Frame.posKey`), whose position
    0 is the element at the index and position 1 the others. The list is a part of a root that
    holds each cell once (a parameter, or a `linear` root the frame made with no `twice` entry,
    `holdsEachOnce`), at a location that names one value (no element step or deep level on the
    way), read at the position of a list pattern it was read at, if any (a spread is a view of
    other indices than its list's); the index is a local this frame bound, and a frame binds a
    local once. So two calls of one match name one array at one index, and that array is the
    same between them: a write of it in place is accepted only where nothing reads it after
    (§5, test 4), and the second call reads it; a callee that writes it and answers it gives the
    answer a new root, and so a new match. Two facts then hold. The element at the index is one
    cell and the elements at the other positions are others, since the list holds each cell
    once, so atoms at the two positions are apart (`posApart`). And the cells that `set` answers
    at the other positions do not include the element it replaced. A walked body publishes the
    mark where the list is one of its parameters, whole, and the index the local that another
    parameter's pattern binds (`Frame.posSrc`): `List.get`'s answer is `#Just.0 π1@1[π2]`, and its
    caller reads it at a match of its own arguments.

    The apart-arguments rule (§4.4) at such a call: the stored value can hold parts of the element
    that the call replaces (`{ Record.copy c | occ = 5 }` holds `c`'s `coord`), which the list holds
    at the index, so the arguments are not apart. But the callee's claims about its result do not
    rest on that element, which is in no part of the result. So where a contract holds a parameter
    in its result and in its supplies only at its storage and at its elements at the other
    positions (`Frame.positionedParam`), the argument's elements are read at the other positions
    of its match when the arguments are tested (`argsApartAt`).

    What it does not cover. `focus` (`List.update`) needs no position: its `taken` element and its
    callback's stored answer are alternatives already (`alternatives`). A read of a list by such a
    callee is a flag of the whole location, not of positions, so an element written in place
    between the `get` and the `set` is still read by the `set`, and refused. An index computed
    again (`i + 0`), or bound again to another local (`k = i`), names no match. A `Dict` has no
    such row: its `get` and `insert` are walked bodies over a tree, and `insert` writes nothing in
    place, so no `written returned` row describes it. *Before, Sternhalma's `setOccupant` answered
    its board's `coord` records `twice`, and a fold of it was refused (#2532 item 4).*

    The words are shared: a signature with a word that only v2 and v3 read is kept in a column of its
    own, which v2 and v3 read and v1 does not; any other signature is in v1's column, which all three
    read (`Lower.recordOwnWords`, `Bir.ownSlotsV2`). So a row is written only where its words are true
    and **v1 and v2 read them as before**: v1 is frozen, and v2 judges the same programs in the gates. A true row that fails this is
    not written, and the function stays walked or unknown code — the pessimistic side. `Dict.focus` is
    one (report 117 §10): `taken` names an element of a list, and v2's reader of rows knows no other
    value to take, so a row there changes v2's verdicts.

    **A platform's trusted row** (the owner's decision of 2026-11-15, #2508; built on `Hosted`'s own
    body by research report 154, #2552). A row may stand on a walked body that runs code the checker
    cannot follow, where a fact of that body says what the code is. One does: `Hosted.compare : borrowed
    Key, borrowed Key → Order` (`platforms/browser-base`). Its body runs a comparer (`Js.apply`), which no
    rule follows. It reads that comparer from a `Map` private to `Hosted`, keyed by a type identity, never
    from a key (`boundary.md` §9.8.3, amended 2026-11-17), and `Hosted.key` is the map's only writer: it
    stores `comparer k`, a call of the key type's own `compare`, which `key`'s `where k.compare` hands as
    evidence and which is judged there (rule 11): a `compare` that writes or keeps a parameter is refused
    where `key` is called, in whatever package calls it. A refusal of evidence stops the build of core and
    of every platform, a project's own layer included, as it stops the program's, though their writes are
    not enforced: evidence can be kept and run later on another package's values, as `key` keeps it
    (`Enforce.checkModule`; `browser/tea/KeyLayerKeeps`, a layer that made a key of its own type whose
    `compare` kept its list, which the first review of research report 154 found accepted and trapping). Checker v1 reads the same words, so it does the same: a function handed as evidence that writes or keeps a parameter is a pending line in every package (`Ownership.evidence_detail`), and `Enforce.checkModule` stops the build of core and every platform on it (a v1 line of the same kind as v3's; `KeyLayerKeeps`'s `.sanitize-lists-refuses`).
    So every comparer `compare` can run reads its two keys and keeps nothing, and `compare` borrows both;
    an identity with no comparer stops the program. The fact is one of `Hosted`'s code (and of the host's
    `Map`, whose methods a platform could change for every module at once, as it could change the
    built-ins that every sibling of core calls), so it holds whatever a `Key` value is: research report 153 §4 found a `Key` made with `Js.to`
    whose comparer kept its key (`browser/tea/KeyForgedKeeps`), and a real key whose comparer property a
    platform overwrites (`browser/tea/KeyAltered`) is the same; neither comparer runs now. (The owner
    asked for every `Key` to come from `Hosted.key`; that alone would not close the second program, which
    alters a real key.) What a forged key still has is `Js.to`'s general hazard, which every type has: a
    value whose reads run a getter or a proxy's trap, the platform's duty (`boundary.md` §4.2). The words
    are v1's too, and v1 reads them. The test is `browser/tea/KeyCompareKept`: a key type whose `compare`
    writes its key is refused where `Cmd.keyed` hands it to `Hosted.key`. The platforms write nothing in
    place of their own, so the row wins verdicts of `Tea`'s tables (`tableInsert`, `tableRemove`,
    `tableGet`, `tableLower`, `tableMember`), not stores.

    A row of JavaScript is true only of what the operation can run. A property read (`Js.get`) runs a
    getter or a proxy's trap with the object as receiver, and turns an object name into a key with its
    `toString`; a comparison (`Js.lt`, `gt`, `le`, `ge`) runs an object operand's `valueOf`. Each can
    keep what it is handed, so each operand has no word and escapes: `Js.get` is unknown code, and the
    comparisons are `a, a → fresh bool`. `unused` is true only of an operation that coerces nothing
    and whose answer no write in place changes (`isNull`, `typeIs`, `fingerprint`). `Js.same` coerces
    nothing but is `borrowed a, borrowed a → fresh bool`: an in-place write keeps its base's object, so
    a value kept from before the write is `===` to the written list, which it is not where the write
    copies. An identity compare reads its operands (research report 140).

    **A worded body is checked against its walk** (research report 162, #2573). A row is trusted
    because the checker cannot see what its JavaScript does. A worded declaration with a beni body
    is walked all the same (§7), and where its body **reaches no JavaScript** the walk sees all of
    it: its contract is a fact of the body, and a word that claims less than it is a mistake of the
    platform's author that the build can see (`peekBody : borrowed shallow Dict Int (List Int) →
    Int` whose body reads `Dict.get d 1`'s length: a caller wrote that list in place, then called
    it). So the walk's contract must be **below** the words' (`Check.falseWord`): every fact a
    caller reads of the walk, the words say too, or something more pessimistic. Words that claim
    more than the walk found (a conservative word) are allowed. Where the walk's contract is not
    below the words', the declaration is refused, `false_ownership_word` at its name, in the build
    of every program that loads the package that declares it, wherever its lines are enforced
    (`--ownership=v3` with `--ownership-everywhere` or a chain that writes in place), naming the
    declaration, the parameter or the result, and the word. It is a refusal, not a panic: the
    mistake is the platform's, and every build makes it. The check runs when the module's walks and
    budgets are done, and counts no work: no limit and no other verdict depends on it.

    A declaration **reaches JavaScript** (`Check.reachesJs`) when one of its edges
    (`Edges.declEdgesAt`: the values its instructions and local functions name, its dispatch
    terms) is

    - a declaration of core's `Js`, a `foreign` with no words, a markup primitive or a name with no
      definition, named where the type it is read at holds a cell (`Check.touchesCells`: a
      parameter, a function parameter or the result of that type has a location, or the value's own
      type has one; `Js.shiftRightZero` on two `Int`s, as `List`'s bounds test calls it, sees none);
    - another module's derived row with no published fact, or a codec: the compiler's code, which no
      walk reads by a body (this module's derived rows are read through the methods they call, which
      `Edges` yields as edges of their own, so `( 1, 2 ) == ( 2, 1 )` reaches nothing);
    - a worded row that hands a parameter to code no walk sees (`Check.handsUnseen`: a parameter
      with no word or `unknown` that holds a cell, a function parameter with no word, the result
      word `unknown`), or whose contract casts;
    - a declaration with no words that has no contract (its walk gave up, or its module passed a
      limit), whose contract casts, or whose own body reaches JavaScript, in this module or another
      (`Published.js`; a module of an application has no words and publishes none, so each of its
      declarations reads as one that does).

    **An edge counts only where what it can see reaches the contract** (research report 164,
    #2577). Each of the edges above is read where it is, by the walk's own values:

    - an edge that is the callee of a call or a method call that the walk applied, in a frame that
      it finished (`Frame.noteJsSite`, `Frame.judgeJsSites`), counts where a value handed to the
      call — an argument, the receiver, a closure's captures, at any depth of the runs of the roots
      that hold them — can hold a location of a parameter, a capture or a function parameter's
      answer (a part of a parameter with no location holds none: `round x` on a `Float` sees no
      cell); where a root that the call was handed or answered is one the frame's answer can hold
      (what the answer is made from); or where the call made the frame cast (`casts`, which the
      walk does not trace by value). Every walk of the instruction counts: one that counts is
      enough;
    - any other edge — a function value handed on (`List.map xs String.fromInt`), a dispatch site
      that is no call, an instruction that no finished frame applied — counts where the type it is
      read at holds a cell (`touchesCells`), whatever kind of callee it names, and is then read by
      its kind as above;
    - a row of the reference table (`Edges`' first leg, at no instruction) names a reference that
      an instruction of the declaration holds, and is read there; a row whose name no instruction
      of the declaration holds counts.

    The values are read as they are, with no step (`Frame.siteHolds` reads the nodes, the roots
    and their runs, never `leaves` or `reach`, which count work), so the reading counts no work:
    no limit and no verdict depends on it. So `peek d = if round 1.5 == 2 then List.length
    (Maybe.withDefault (Dict.get d 1) []) else 0` reaches nothing: `round`, a wordless body over
    `Js.call`, is handed a `Float` and answers an `Int`. `Js.same [ 1 ] [ 1 ]` is handed two new
    lists that the answer does not hold, and reaches nothing; `Js.same [ d ] [ d ]` is handed a
    list that holds `d`, and a wordless helper that hands its parameter to `Js.same` reaches
    JavaScript for a caller that hands it `d`, not for one that hands it `[ 1 ]`. *Before, each
    edge to such a callee counted whatever it was handed: one call of `round`, `toFloat`, `//`,
    `String.fromInt`, a string `++`, `Debug.toString` or `Js.same` turned the check off, and a lying
    body was trusted (blind round AO; `run/WordedBodyFalse`'s `peekRound` and its twins).*

    A worded callee is read by its words, which are its contract, and its own body is checked where
    it is declared: it does not carry the bit to its callers. A body that reaches JavaScript is not
    checked: the walk reads JavaScript by its rows, which are pessimistic where they see a cell
    (`Js.call` lets each operand escape, `Js.to` casts), so the walk finds more than the body does.
    JavaScript that sees no cell the contract describes makes nothing of the contract pessimistic
    but the cells it is handed and answers, and those the answer does not hold: the walk's contract
    of the rest of the body is the body's. (A value it answers that the body hands a function
    parameter is read as the row says, `outside` where it says so: a refusal at most, never an
    acceptance.)
    A body that reaches none and whose walk gave up or passed a limit has nothing to check its words
    against, and an importer trusts them all the same: it is refused. (Where its module publishes no
    contract, past the layout limit, no importer reads the words, and nothing is refused.)

    *Below*, as callers read a contract (`Contract.zig`):

    - **a parameter's flags**: where the walk reads a location (`flag_r`), the words read it —
      `unused`, and `shallow` below the storage, say that they do not; where the walk writes it
      (`flag_w`), the words write it (`written` at the storage, `consumed`); where the walk lets it
      escape (`flag_e`), so do the words (`escaped`, `aliased`, a cell's words, a placement with
      nowhere to go); where the walk answers it (`flag_a`), the words read or answer it. `flag_s`
      is read through the function parameter's `free`, below;
    - **the result's sources**: each source of each location of the walk's result is named by the
      words' sources at that location — a parameter location by itself, at the same position or at
      none (`position` claims one only where the walk found it); a function parameter's answer by
      itself; `outside` (a top-level value or JavaScript's) by `outside` alone, since a caller of a
      `fresh` row writes a value every reader holds; a cell the body made by `outside`, or, where
      the body did not let it go, by a new cell of the words, a parameter location or a function
      parameter's answer (each of which a caller writes only where it may write what it handed);
      and one new cell at two locations only where the words name one site for both (`exclusive`
      names one for each);
    - **the contract's claims**: where the walk is `nonlinear` by a parameter's cell at two
      locations, `casts`, or can answer an object that was there before the call (`old_result`),
      the words are too;
    - **a function parameter's use** (`Contract.Fn`), entry by entry: each parameter location or
      answer the walk hands, the words hand; a cell the body made that it hands and also answers,
      likewise, so that a caller sees what its function kept of the answer; where the words say
      that the owner reads it no more (`free`), the walk does too, and hands no `outside` cell
      the words do not; and where the walk calls the function, loses it, lets its answer escape
      or writes a cell after it handed it (`called`, `lost`, `ans_escapes`, `rewrites`), the words
      say so.

    What it does not judge, each by its reason: a **count** of cells the body was handed (`twice`
    at a location where the walk has only parameter locations, function answers or `outside`, and
    `nonlinear` that only a cell at two places of one summary location makes), since a word that
    states positions (`returned`, one `stored`, `copyof`) asserts it as `taken` does and no walk of
    a permutation or a merge derives it. Where a cell the body made is at the location, it can be
    the one at two places, so the count is judged: `fresh exclusive` over `[ t, t ]` is refused, and
    so is `List.push (List.push xs t) t` beside handed cells under `written returned` and `stored`: `List.swap`'s two `set`s read the element they put back as
    at two places, and `sortWith`'s merge does the same (a body that stores one value twice beside
    a `written returned` list is a false row the check does not see, `bench/ownership-sweeps/
    worded-bodies.mjs`'s `twice`); `taken`'s `free`, asserted for loops that hand each position
    once; `entry`, a protocol of the runtime, judged at the program's entry (rule 13); `Record.copy`'s
    `copyof`, applied by its caller's own rule (`Frame.recordCopy`); and, **in a module of core
    only**, a new cell at a location of a **type variable** (`Loc.Kind.var`) where the walk does not
    cast, at the result (in a count) or handed to a function parameter (`Check.phantomAt`). A body
    of core gets a new cell at a type variable from the element location of an empty list it made
    (`[]`), which the walk reads as one, or from a row of core that names one there, and each of
    those makes none: `List.builder`'s holes (`fresh exclusive Builder a`), a key (`Dict.keyIndex`,
    a key holds no cell, §12), an empty dictionary, the words `fresh` beside `copyof`
    (`Record.copy`) or a callback's `aliased` answer (`Task.raceOk`, `Task.timeout`), which names
    the cells that are there, and `Js`'s rows, which answer JavaScript's primitives (`same : … →
    fresh bool`) or never answer (`throw`). A safe build stops at a row of core that names a new
    cell at a type variable of its result and is not one of those (`Check.core_phantoms`, §9). A
    platform's row can answer a real one (`foreign make : ⊤ → fresh a`, whose JavaScript answers
    `[ 1 ]`), so a platform's body is judged in full: `dupe ⊤ = x = make ⊤; [ x, x ]` under `fresh
    exclusive List a` is refused. `List.sortWith` met the over-reading once `slice`'s call of
    `clampIndex` (two `Int`s) stopped reaching JavaScript: its walk answers the element location of
    `slice`'s `[]` and of `merge`'s builder at `[*]`, beside a count it does not derive (#2575),
    and hands them to `cmp`. A word that says "new storage, no cell below", and a reading of `[]`'s
    element location as holding none, would end the exemption; both change contracts the walk
    publishes, and they are the owner's decision (#2578; research report 164).

    **A call that never answers** (*amended 2026-11-24, #2652*). `Js.throw : escaped Value → fresh
    hollow a` answers no value, so its result holds none (`hollow`, §12 item 8), and nor does a
    walked body whose every answer is a throw's (`Debug.todo`). Before, `throw`'s `fresh` named
    one new cell at every location of the result, so an arm of `update` that is `Debug.todo`
    answered one cell at each model location and in the command, no model location was the
    model's alone (rule 13, `freshOwn`), and every write of `update` was refused
    (`browser/tea/DefectInUpdate`). An arm of a join that throws is no run that answers.

    **A declaration with no parameter whose body is a function** has the contract of that function.
    A lambda's or a partial's (`peek = λd → …`, `peek = at _ 1`) is its walk, judged as any body's.
    **An alias** (`same = keep`, `peek = Help.inner`, in this module or another), whose body is a
    name of a function, has the contract of the function the name reaches through names with no
    words (`Mod.calleeOf`): `keep`'s walk, or its words where it has words. So the alias's words are
    compared with that contract (`Check.aliasWord`), by the same *below*, and where that function
    reaches JavaScript, so does the alias, and it is not checked. Where the function has no
    contract (its walk gave up, or its module passed a limit), no word of the alias can be checked,
    and it is refused, as a walk that gave up is. Where the function's contract has other layouts
    than the words' (`keep : a → a` under words at `List Int`), the comparison needs the contract
    at the alias's types, which no walk made: the alias is refused too, and the refusal names the
    fix, the alias written with its parameters (`same l = keep l`), whose walk is at those types.
    No shipped row is an alias. Any other function value with no parameter (`if True then keep
    else keep`, a `let` or a `case` that answers one, a field `table.f`, a call's answer) has a
    walk of the value, not of a call of it, at other layouts than the words': refused, with the same
    fix (`Check.falseWord`). *Before, a walk whose contract had other layouts than the words' was
    not compared, which left every alias and every such value unchecked, and its callers trusted its
    words (blind round AO, and the second review of research report 164; `run/WordedBodyFalse`'s
    `aliasSame`, `ifSame`, `fieldSame` and their twins).*

    A body whose walk is more pessimistic than the truth — a callee whose words are
    conservative (`List.length` says `borrowed`, not `shallow`) — is refused where its words are
    sharper than the walk can show: a refusal, never an acceptance, of the platform's own code.
    *Before, a worded body's contract was its words whatever the walk found, so `peekBody` above was
    accepted and its caller trapped under the sanitiser (`run/WordedBodyFalse`; its true twin is
    `run/WordedBodyTrue`).* No row of `core/` or of a shipped platform is refused, and no verdict of
    the ownership roots changes (research report 162).
11. **No fact by a name** (`methodCall`, `evidence`, `derivedEffect`, `Check.edgeEffect`, `Check.isSender`):
    a method call or an operator runs the code the dispatch table names: a declaration is a call of its
    contract; a function the compiler derives (`eq`, `compare` of a type that declares none, a codec)
    reads its operands and calls its evidence **and the declared methods of the parts of its type,
    directly, at any depth** (`static-dispatch-spike.md` §3.3: derivation is structural and recursive);
    a derived codec (`Edges.Edge.codec`) is a function of `⊤` that answers a codec, so a call of it
    reads nothing: the code that later runs the codec's workers on a value runs a function it has no
    contract for, so the value escapes there (§3.2), and every function those workers run — a `via`, a
    function in a `codec` value that a type's module declares — is in the default location (§6.14);
    a method declared as a constant (`pub eq = keeper`) has no fact here, since its contract says what
    its value holds, not what a call of it does, and is read as code with no contract;
    a call of an evidence parameter (`a.eq` under `where a.eq`) reads its operands, because the caller
    that handed the evidence was judged; anything else is unknown code. **The evidence is judged at
    every instruction whose dispatch site carries it**, whatever the form of the callee: a call or a
    reference of a declaration, a call of a local function generalised over a `where` (a lambda, a
    local definition, a `_` placeholder: its emitted code takes the evidence as hidden parameters, and
    the call hands it in), a reference to such a local handed as a value (`List.map xs f`, where no
    call applies it), a method call and a return-type dispatch. An evidence parameter of a `let`
    binder is a parameter as one of a declaration is: the local's callers handed it and were judged,
    so evidence handed on through a second local, or stored in a closure that escapes, was judged
    where it was first handed. *#2601: the walk read a site's evidence only where the callee was a
    declaration, so `f = λk → addOnce k xs; f Sink`, with `Sink.add` writing its parameter, was
    accepted and wrote `xs` in place; so were `λp q → p == q` over a user `eq` that writes, `λl →
    List.sort l` and return-type dispatch through a generalised local.* A safe build checks that
    every site of a walked declaration that carries evidence was judged (§9). The functions that derived code
    calls are the edges of the site's terms, through the body of each derived row of the module, each
    term once (`Check.termEdges` over `Edges.termsEdges`); a derived row of another module is read by
    the fact that its module published for it (`Contract.DerivedFact`), and a row with no fact can write
    and keep. What those functions can do (`Contract.Effect`, read off each one's contract) is applied
    to the operands, which each is handed a part of once: where one keeps, or has no contract, each
    operand escapes; where one writes, every cell of each operand is a demand at the call, with the
    other operands as its other operands, and a cell at two places of an operand is refused (the
    derived code reads the second place after the method wrote the first). Return-type dispatch
    (`type_dispatch`) runs its callee the same way. Evidence (`where`) is called by code the walk does
    not follow, any number of times, with values it does not own: a function that writes or keeps a
    parameter is refused where it is handed, and so is one with no contract, and one that stores into a
    cell it is handed (`Contract.renew`, §13: `Ref.set` as `where a.set`), which writes and keeps there
    (`Check.edgeEffect`). The runtime's `send` is
    the alias with the word `sender` (`platforms/browser/Browser.beni`, and `platforms/browser-base/Hosted.beni`, whose `Send` every renderer's `Cmd.Send` aliases), followed through aliases of it;
    a message sent is given up, so each cell of it is a demand (`callParam`). No declaration is read by
    its name, and no method is read as read-only because it is derived, but two: the decoding runs of
    rule 14 (*What a decoding run answers*), and a call of `Js.from` or
    `Js.to` of the core package is its argument, since the build writes it so (`Mod.emitsArgument`, the
    key of `js/JsIntrinsic.zig`; §3.4, *What a value was made from*). The fact is of the code the build
    writes, which no word of the rows can say (`returned a → Js.Value` is as true of a row that answers
    `[a]`); the value of such a call is read at the reading's type where it is read (`narrowed`). *Report 118 §4.6: the text said
    that a derived method calls its evidence, and the walk read it as code that only reads its operands;
    a derived `eq` of a tuple or of `type W = W T Int` calls `T.eq`, which no walk saw.*
12. **Markup** (`evalInner .markup`, `formCalls`, `runtimeCall`, `call` of a markup primitive): the value
    of markup is `unknown` over the values of its holes and over the arguments of a hole that calls a
    top-level function (a helper the platform may call where it renders, `language.md` §11.6; a hole
    of text is one too): the runtime reads them when it renders the markup, after the frame that made
    it, so until then whoever holds the markup holds them, and a write of one of them before the
    render is refused. A lowering may evaluate a hole's expression where it renders, from the values
    the expression reads (the `dom` lowering's block of a root's inputs, `backend.md` §15.4), so the
    markup holds **everything a hole's evaluation can read**: every local and capture it reads, and
    every closure it makes, which holds what it captured (`closureOf`; #2505, research report 123).
    **Every value at an item of markup that no row of the dispatch table names as an attribute** — an
    event's handler or message, a component's prop, a spread of attributes — escapes, whatever
    expression made it (`keptItems`): the runtime keeps it after the render, and calls or sends it
    after `update` has run (two clicks in one task, an event that bubbles through two handlers;
    `boundary.md` §9.4.8 counts each as escaped where the markup is made). A component's children are
    a prop (`children`, `language.md` §11.8): everything their holes read escapes. A hole's value
    that is built here, or a function that answers anything but markup, escapes too, and so does one
    of several values (an `if` or a `case`) of which one arm is such a value (`keptHole`; research
    report 148: a `join` was read whatever its arms were). **The runtime
    calls the functions the markup gives it with items of the markup's own values** (`boundary.md`
    §9.4.8, *The render*): a `For`'s row function and key function with each item of `each` (and a
    row's position), a `Show`'s body and key function with the value in `when`. Each is **applied to
    those items as at a call site** (`formCalls`, `runtimeCall`, rule 2): what its contract lets
    escape escapes, what it hands a function is supplied, and a function with no contract is unknown
    code, so the items and the function escape. The function is also in the default use (`mention`),
    so one that writes its parameter is refused: the runtime can call it more than once with one
    item. The other functions the runtime calls are handed nothing of the frame: an event's handler
    gets the event, and `Html.map`'s function gets a message, which is an event's message or a
    handler's answer and so holds only escaped cells and new ones. A markup primitive of the
    vocabulary (`Html.map`) answers markup that holds each of its arguments; the markup it is handed
    does not escape, and every other argument (`map`'s function) does. **The markup the runtime
    renders holds none of its holes after the render.** This rests on the platform rule of
    `boundary.md` §9.4.8 (the owner's decision, 2026-11-13): a runtime reads a hole's value only
    while it renders the markup, and keeps no list from a hole to read after that. The checker cannot
    see a runtime, so it trusts that rule, and each platform's fixture tests it. The rule is used at
    one place: the entry (rule 13). **A value that the lowering keeps beyond the call is held by the
    root** (`binding`, `Check.Options.kept_lets`): a lowering that evaluates a root's values itself
    (`groups`) can keep a `let` of the enclosing function that only the root reads, and read it at a
    later render (§6.14, *What a lowering keeps*). Each such `let` escapes where it is bound, so no
    write of it, or of a cell it shares, runs in place, in that call or a later one. The lowering
    says which `let`s it keeps; the checker does not guess.

    *The argument.* The runtime is a holder that the walk does not follow, and it does two things
    with markup: it reads the values the markup holds while it renders, and it calls code the markup
    gives it. The first is covered by the markup holding every value its holes can read until it is
    rendered, and by the platform rule after that. The second is a call: the callee's contract says
    what it keeps of its arguments, and the arguments are the items the runtime takes out of the
    markup's values. So each such call is applied, and the theorem of §5 holds with the runtime's
    calls as calls. *Research report 121 §4.3–§4.4, report 122 §3.3: the text counted what markup
    holds and what escapes, and left out that the runtime calls rows, keys and `Show` bodies with
    items; a row that put its item in an event's message, or a key function that put it in a `Ref`,
    kept a list the entry called `own`. A closure made in a hole was not held, because its captures
    were read through `capSlot`, not as locals.*
13. **The entry** (`entryCall`, `fnMembers`, `Mod.entryShape`, `freshOwn`, `paramOwn`, `handsOn`): the
    runtime holds the model and the record's functions, and calls each function of the record with
    the model or with what it makes; a location of the model is `update`'s own only where a positive
    fact names its one holder, the model, at every place the model comes from.

    **Every function of the record is accounted for by a contract.** The value of a field is a known
    function, or a `join` of known functions, each of which is applied as that field (`fnMembers`).
    A field whose value has no known code — the answer of a call, a field of a top-level record,
    `Maybe.withDefault`, a function value that no rule names — is the default: it can write nothing
    (`flowTop` refuses that), and it can keep each thing the runtime hands it, so **no location of
    the model is `own`**. So is a field the entry's type does not name, a record that is not written
    at the call, and an entry with no producer that is handed no model (the runtime then makes the
    first model). A constructor whose answer holds no cell is the one function value of no object,
    and keeps nothing.

    **Where each function has the model is read off the entry's declared type** (`Mod.entryShape`,
    the `entry` parameter's record type in the platform's source), never guessed from locations. The
    model is the type variable of `update`'s last parameter. A field whose answer type is that
    variable answers the model; one whose answer is a tuple with that variable at item *k*
    (`model × Cmd msg`) has the model at *k*; a parameter that is that variable is the model
    parameter. A field that names the variable in any other way (inside a list, twice) has no fact,
    and no location is `own`. A field whose answer has the model is a **producer** (`init`, `update`,
    `settle`); every other function field is a **consumer** (`view`, `subscriptions`,
    `onUrlRequest`, …).

    A location is `own` (the largest solution, from `own` everywhere, taking away) only where each
    source of it, at the model's place in the answer of each value of each producer, is
    - a cell that the producer made, whose site has no escape bit, is at no other location of the
      answer (another model location, a command, the rest of a pair) and is in no supply to a function
      (`freshOwn`, as rule 8); or
    - a location of the producer's own model parameter that is `own` in its turn, that the producer
      did not let escape, answers at no other location and hands to no function (`paramOwn`).

    **One value of the answer at a time** (research report 159, #2550). "At no other location" is a
    fact of one run: a run answers one value of the producer's join, and the producer's contract says,
    where it is not `nonlinear`, that no cell of a parameter is at two locations of any one of them
    (§4.4, *One value of a join at a time*). So where the contract is not `nonlinear`, a location the
    producer answers at two locations in two arms (`Swap → { m | w = m.w2, w2 = m.w }`, `Bump → { m |
    w = … }`) is at one of them in each run, and the other is no holder of it; where it is, every
    other location that holds it is another holder, as before. *Before, a field swap in one arm of
    `update` took every record of the swap out of `own`, and every later write of them was refused
    (`browser/tea/EntrySwapArms`; the live twin, an arm that answers `w` at both places, is
    `browser/tea/EntrySwapShared`).*

    **What a consumer keeps is taken away before the taking away** (the second review of research report 159).
    A location a consumer keeps (`view`, a subscription) is not `own`, and a location that a producer
    answers from it needs it: so the consumers are read first, and their locations start the work list of
    the taking away with the others (`entryCall`). Before, they were taken away after it, and a location
    that needed one stayed `own`; the test of "no other location" hid it, until it was read one value at a
    time: `Keep model.w` in a message of `view`, then `Swap`, then a write of `w2` in place
    (`browser/tea/EntrySwapKept`).

    Every other source has another holder or no fact, and is not `own`: a top-level value
    (`outside`), the answer of a function, a capture (the record holds it for as long as the program
    runs), the `Host`, and **the message**.

    **Every comparison of a model location with a location of a function's contract goes through the
    call map** (`locsMeet`, §4.1). The contract's layouts are those of the function's declared type,
    which can be wider than the model's: a type variable, or `{ r | n : Int }`, whose row holds the
    model's `items`. The sources of a model location in a producer's answer are the sources of every
    entry of the answer that can hold a cell of it, as at a call (rule 2): a wide entry holds each cell
    below it or in its row, so each of its sources is one of the location's. A parameter source names
    every model location that its entry meets, and each must be `own`. The consumers keep what they
    write, let escape, hand to a function, or (except a `view`) answer; every model location that a
    location they keep meets is not `own`. A write by a producer is accepted only where every model
    location that the written location meets is `own`. The runtime hands a function parameter of a
    function of the record the default (rule 2, `defaultParams`). A `view` (a function of the record
    whose answer is the build's markup type, or a record or tuple with markup in it,
    `Check.Mod.isView`) does not keep what its answer holds: the runtime renders the answer before it
    runs `update` again (rule 12, `boundary.md` §9.4.8). **The message is never `own`**, except where *A message a command builds*, below, holds: a handler of
    the rendered markup keeps its message until the next render and can send it twice, a message can
    hold a top-level value, and the runtime's commands, subscriptions and platform events make
    messages that no rule of the checker follows; a `send` written in the program is checked where it
    is written (`callParam`), but it is one source among these. So a send asks nothing of the sender: its
    line is accepted, on the entry rule where the cells are not the sender's own, and the test of its cells
    says only whether the function is handed the message `free` (`finishDemands`). What the sender hands
    `send` escapes where the function goes to the runtime's default (rule 2, `defaultParams`), and a
    function that writes a cell after it sent it is refused there (`Fn.rewrites`). *Research report 143:
    a send of a list the sender did not own was a refusal, so each of Conduit's commands that sends a
    loaded feed stopped every write of its module, though no write rested on the message.* A function that is not a producer
    handed the model and writes a parameter is refused: the runtime hands it a value it does not own.
    The record's functions escape; the program's value is `unknown` over the record. *Amended
    2026-11-26 (#2695):* each known function of the record meets the default use, as any function
    value the walk loses does (`flowCode`, with `Use.entry`): the runtime holds it and runs it
    where the walk does not follow, on whatever fiber calls into the program (`send` runs `update`
    and the render), which can be masked or lent. So what it captured has another holder, a write of
    the contents of a cell it captured is refused, and so is a function whose contract has `hosts`
    (§13 item 12 (d), *Up*; *The ways in, from the code*, item 12). Only what it writes of its own
    parameters is not judged there: the rows above judge that. Before, the record's functions got
    only `flowCaptures` and `defaultParams`: an `update` that forked a hosting fiber, and an
    `update` that wrote the contents of a cell `main` made and a command had read, were wholly
    accepted and trapped (code reader CR9's `e_updstart`; the lane's reviewer's `capw`).

    *The argument.* "No other holder" of a model location is a universal statement over every
    function the runtime calls with the model and every function that makes it. It is derived only
    from a contract of each, read at the place the declared type gives; a function with no contract,
    or a place no type gives, leaves the statement without a ground, so it does not hold. Each of
    those contracts names its locations by the function's own type, so the statement is read at every
    location of the contract that can share a cell with the model location: a comparison that fails for
    any reason but "apart" (a label path that a row or a type variable changes) leaves it without a
    ground too. *Research report 124 F1: a view, a subscription body, an `update` or a `settle` over
    `{ r | n : Int }` kept the model, and the entry read the row's location as no model location.*
    *Report 118
    §4.1–§4.4: the text took a new list of `init` as `own` without its escape bit, compared two
    locations of the answer only for a parameter source of `update`, did not read the escape of a
    model location that `update` answers, and made the message `own` where every model location was.
    Research report 121 §4.1–§4.2 and report 122 §3.1–§3.2, §3.4: a field with no known code was
    dropped (neither producer nor consumer), and whether an answer was the model or a pair was guessed
    from its locations, so a tuple model was read at the wrong place.*
    **A message a command builds** (*the owner's decision, 2026-11-27, #2657*: "a message whose
    constructor is only ever built inside the program's own commands counts as `update`'s own").
    The platform's fact: the runtime hands each message that a command's body sends (its `send`, the
    word `sender`) to `update` once, and keeps none of it after `update` returns (`Inline.commands`,
    `boundary.md` §9.8.4); a platform makes a message only by calling a function the program handed
    it, or by handing on a message the program made. So where no construction of a constructor `C`
    can reach the runtime except through such a send, and nothing but that send holds what it sends,
    a location of the message at `C` is `update`'s own (`Mod.cmdBuilt`, `Frame.msgOwn`). Each of
    these is a positive fact, and where one does not hold the message is not `own`, as before:

    1. `update`'s field is a declaration of the entry's module, and its message parameter's type
       `T` is a type of that module with no type parameter. No other module of the program can
       name `T`'s constructors: one that imports the entry's module is not imported by it.
    2. **Every construction of `C`** in the module (`Mod.cmdBuilt`) is one the walk saw as one of
       these, in each walk of its body (`Frame.noteCmdSite`):
       - `send (C a…)`: the whole argument of a call of the function's own parameter of sender
         type, whose demands all hold on the function's own ground (`fresh` or `call`): the
         function made each cell that a write can edit, and does not read it again; and no cell of the
         message is at two of its locations (`Pair xs xs`, `Tup ( xs, xs )`), which the demands, each of one
         location, do not see; and every cell it asks for is one this function made, never an answer of a
         function parameter (`send (Items (mk ⊤))`), which a demand reads as the function's own (both the review
         of this rule);
       - `C`, as an argument of a call of a declaration of a platform package (not core, not the
         program's), whose contract answers no answer of that function, hands it to no other
         function parameter, and hands it, at each of its parameter's cells, only the answer of
         another function parameter, `free`; where each such function is, at this call, known code
         whose answer there is only cells it made and let go nowhere (`freshOwn`). `Cmd.task
         (λ⊤ → [ "first" ]) Response` is one: each run calls the work again.

       A constructor used in any other way (in `view`, in a subscription's or a handler's
       function, partly applied, inside a lambda the send is not the parameter of, in code the
       walk never reached) makes messages that no send gives up, and is not `C` of this rule.
    3. **No decoder in the module**: no derived codec and no schema declaration, which make a
       message that no construction made.
    4. **No function of the program keeps a message** (`Mod.keepsMessages`, published by each
       module for those it imports, `Contract.Published.keeps_messages`): every lambda, and every
       declaration used as a value, whose parameter's type can hold a message — it names `T`, any
       type of the program, or a type variable, outside a function's parameter — has a contract,
       and that contract lets no such parameter location escape, hands it to no function and
       leaves it in no cell. A platform hands a command's messages to the program's functions
       there (`Cmd.map`'s function, a sender the program made), and one that kept a message could
       send it again.
    5. **The model's type does not name `T`** outside a function's parameter: a model that holds a
       message hands it to `view`, whose handler sends it again.
    6. **`update` gives the location up**: its contract does not let it escape, leaves it in no
       cell, hands it to no function, answers it only at the model's item of the answer, and, where
       the contract is `nonlinear`, at one location there (`paramOwn`).

    So a send in a command asks what it always did (`callParam`), and its line is accepted as
    before; what changes is that a write of `update` that rests on the message, and a model
    location answered from it, are `own` where the six facts hold. *Before, the message was never
    `own`, and `browser/inline/OwnedCommandSend` and the four `Conduit*Errors` pages were refused.*
14. **Calls into the program that no walked body makes** (`Check.walkSchema`, `Check.walkExports`,
    `Check.checkCovered`). The theorem of §5 needs every call of the program's code to be applied by a
    rule. Code that is not a walked body of the program calls it in the places below, and only there.
    The list is read off the backend — every edge and root of `js/Reach.zig` that reaches a declaration
    of the program, and every call that `js/Lower.zig`, `js/SchemaLower.zig` and the markup lowerings
    emit that is not the lowering of a call in a body — and not written from memory. Research report 129
    §2 gives the evidence for each row.

    | Caller | What it calls, and with what | Rule |
    |---|---|---|
    | the program's own body | a function, with the arguments written | rule 2 |
    | a function of `core/` or a platform, walked or worded, or a `foreign` (a callback of `List.map`, `Ref.update`, `Task`, `Cmd`, `Sub`, `Io`, `Hosted`, `Browser.Worker.program`, a Cloudflare `Worker.program`) | the function it was handed, with what its contract says | rules 2 and 8 (the contract, or the default where it loses it), rule 10 (words; no word is unknown code) |
    | the markup runtime | a `For`'s row and key function and a `Show`'s body and key function, with items of the markup's values | rule 12: applied as at a call site |
    | the markup runtime | an event's handler, `Html.map`'s function, a component's function (the module's `view`), with an event, a message or the props | rule 12: each is a value at an item of markup, so it goes to the `top` use (rule 8) and writes nothing; the props and what the handlers capture escape |
    | the markup runtime | a top-level function in a hole (a helper, `language.md` §11.6), re-made where it renders | rule 12: the markup holds what the call is handed |
    | the entry's runtime | each function of the entry's record, with the model, a message or what it makes | rule 13 |
    | derived `eq` and `compare`, `==` and `<`, a method call, return-type dispatch, `where` evidence, `core/`'s derived JavaScript (`listEq` calls the element's comparator) | the methods the dispatch table names, with the operands or their parts | rule 11 |
    | the compiled workers of a `schema` (`S.print`, `S.parse`, `S.encode`, `S.decode`, `S.read`, `S.write`, `S.valid`, the description) and `S.schema`, which `core/Schema`'s runners run; the workers of every schema that names it; a derived codec that names it | each function of a `via` conversion, with a part of the value the worker was handed, or with a new value the worker made | **this rule**, below |
    | a derived codec | the `codec` value that the type's module declares, by name, with `⊤` | rule 2 for its body: it is a declaration of the program, walked; the functions in the codec it answers went to the `top` use where the codec was made (rule 8, through `Schema.conversion`) |
    | host JavaScript, in a `--library` build | each value that the root package exports (`Reach.collectRoots`: `pub` values, the entry declaration, the members of a `pub schema`, the derived rows of its types), with values it may still hold | **this rule**, below |
    | the module loader | each top-level constant, with nothing | §7: its body is walked; its value is `outside` (§3.1) |
    | the entry file | `main`'s value, handed to the platform's `run` (and its `exports`, `"exports": "program"`) | rule 2 or 10: `main`'s value went to the platform function it was handed to |
    | a lowering that rewrites the program: the `browser-inline` program hook (the record is never built; its parts are inlined into the mount), a function's suspendable twin (its rest is a continuation), a helper re-made at render | the same functions, with the same values, in the order `language.md` §6 gives | the rule of the call it rewrites. The checker trusts each lowering to keep the program's calls and their order, as it trusts the platform rule of §6.12 |
    | a lowering that keeps a value of the program beyond the call that made it, and reads it at a later call: the `dom` root's `let`s (`backend.md` §15.4, *The `let` rule*), in a `view`, a helper's root or a component's | the code that reads the kept value, at a later call, with the value an earlier call made | **the value escapes where it is made** (§5.3, rule 12): the lowering says what it keeps (`Lowering.keeps_let`), below |

    **A schema's `via`.** A `via` conversion is evaluated once, where the module loads, and the schema's
    compiled workers and its `S.schema` value hold it for as long as the program runs. They call its
    functions at any time, any number of times: a print or encode worker with a part of the value the
    program handed the worker, which the program can still hold; a parse or decode worker with a value it
    made. So the conversion is a **value in the default location**: the expression of each `via` is walked
    in a frame of the schema declaration (`walkSchema`), its value goes where no contract follows it, so
    each function in it goes to the `top` use (`mention`, rule 8) and each cell it holds escapes. A
    function at `top` that writes its parameter is refused (`writesOwn`), at the `via`. The program's call
    of a worker is a call of code that the walk does not follow (a schema member is `outside`, §3.1, and
    has no contract): each argument escapes there (§3.2). *Invariant: a function that a compiled worker
    calls writes nothing it is handed, and whatever it keeps escaped where the program handed it to the
    worker.* This holds wherever the worker is called from: another schema's worker, a derived codec,
    `core/Schema`'s runners through `S.schema`. A conversion that is a top-level value (`via conv`) is
    walked as a declaration, and `Schema.conversion` loses its functions, so they went to `top` there.
    The default costs precision: a print whose value nothing reads after is refused, and a parse worker's
    value is new, so its conversion could write it (research report 129 §9).

    **What a decoding run answers** (*added 2026-11-27, #2657*; `schema.md` §6, *What a run answers,
    for ownership*). A run of `core/Schema` or `Json` reaches its worker through JavaScript
    (`compiledRun`, `Js.apply`), so its walked contract answers what JavaScript hands back: `outside`,
    the input at every location, the issues' cells. For the runs below, the backend writes the
    decoding worker of a statically known definition, and what that worker answers is a fact of the
    code it emits (`js/SchemaLower.zig`'s workers, `core/Schema`'s shape readers): **every record,
    list, tuple and constructor with a payload that it answers is an object it made in that run**
    (`{ … }`, `[]` filled with `push`, `{ $: tag, a: payload }`), each at one place of the answer; a
    primitive and a nullary constructor's constant hold no cell; and a `Value` is the input's own
    object, or a part of it, as it was handed (`v["key"]`). It never answers an object of a former
    run, and never the host's array (`schema.md` §6, *Lists are arrays*: an array the caller handed
    in as a host value is never adopted). The runs (`Mod.decodingRun`), each named directly at the
    call, not through an alias:
    - `Json.decode`, `decodeWith` and `decodeValue` whose `where a.codec` evidence at the call is a
      derived codec with no argument (`Dispatch` term `codec`): the backend writes the codec's
      worker, or its shape (`SchemaValid.sites`, `Schema.compiledRun`);
    - `Schema.read`, `readWith`, `parse` and `parseWith` whose schema argument is written at the
      call as `S.schema ⊤` of a declaration (`SchemaValid.schemaRoot`).

    and only where the definition, closed over every declaration and derived codec it names, has
    no parameter, no `via`, no check and no module `codec` (`SchemaGraph.buildsFresh`): a `via`'s
    function answers what it likes (a capture, a top-level value), a check's function is handed
    the value the worker built and can keep it, and a module's `codec` is a runtime builder's,
    whose adapters no walk follows. At such a call the contract is the walked one with its answer
    read at the call's own result type (`Frame.decodedContract`): each location below `Ok` that is
    a list or a record's slot holds a new cell of a site of its own, at no escape, apart from every
    other; each wide location below `Ok` (a `Value`) holds the run's input, its last argument, or a
    new cell where the input holds none (`parse`'s text: `JSON.parse` made the objects); every
    location below `Err` holds every source of the walked answer. No location of the answer is a
    cast's, and no object of it was there before the call. So a value decoded into the model is
    the model's own (rule 13, `freshOwn`), and a write of it runs in place. *Before, the answer
    was the walked one, `outside` at every location, and each loader page of `browser-inline`
    whose route decodes its slice (`browser/inline/CaseLoader`, `NestedStableLoad`,
    `PartialRoutes`, `ResearchS3`, `ShapeLoader`, `SnapshotFromTable`, `TickFresh`,
    `TickInPlace`, `ValidatedLoader`) had every later write of the slice refused at the entry.*
    This is the second fact the checker reads by a name (rule 11): the fact is of the code the
    build writes for the call, which no word of a row can say (`fresh` names one site for every
    location, and none says that a `Value` is the input).

    **A `--library` build.** Host JavaScript calls each value that the root package exports, at any time,
    with values that it may still hold and read after. An exported function is a **function in the default
    location** (`walkExports`): it goes to the `top` use, so one that writes a parameter is refused. A
    constant that holds a function put it into its value where the value was made, which sent it to `top`
    (`mention`). A derived row reads; the declared methods it calls are `pub`, so they are exports too. A
    member of a `pub schema` runs the `via`s, which are in the default location already.

    **What a lowering keeps.** A lowering that evaluates a root's values itself can skip an evaluation:
    it keeps a value from one call of the enclosing function and reads it at a later one. The walk of the
    function sees the value made on each call, so such a value is a holder that the walk does not follow,
    and it is the lowering's to name. **The lowering tells the checker what it keeps**, through the
    markup interface it implements (`Lowering.keeps_let`, `boundary.md` §9.4.8, *What a lowering
    keeps*), and the checker reads each kept value as held by the root: it escapes where it is bound
    (`binding`). The facts come from the code that decides them, not from a list here:

    - the compiler finds the `let`s that a root may evaluate itself (`Root.lets`) with the analysis the
      emitter uses (`MarkupTree.build`, built again in the check, `Enforce.keptLets`, with every
      declaration of the module live and in every module, whatever its dispatch table says (a root made
      of a component call alone has no row there): a superset of what the emitter builds, and a root that the emitter
      does not group evaluates its `let`s in place, so the set is never smaller than what is kept);
    - the lowering says, of each, whether it keeps it (`keeps_let`). **The default is that it keeps every
      one**: a lowering that says nothing is read on the side that refuses. A lowering that does not
      `groups` evaluates no `let` of its own, and is not asked.

    The audit of every lowering of the tree, 2026-11-14 (research report 134 §3):

    | Lowering | What it keeps beyond the call that made it | What the checker knows |
    |---|---|---|
    | `dom` (`browser`, `browser-tea`) | a root's `let` in `d<k>`, made again only when a path it reads is not `===` the one it was made from; a `let` that reads a path whose value is not identity-safe (a list, or anything that holds one) is made again on every render, before it is read (`keepsLet`, checked against the emitted test in safe builds) | each kept `let` escapes where it is bound |
    | `dom` | the last value of an operand, for a test by `===`: only an identity-safe one (`identityOperand`, `Tree.identitySafe`), a text, a number, a boolean; a class or style list's written `Set`, which the runtime makes | nothing: an identity-safe value holds no cell that can be written in place |
    | `dom` | a skipped helper's or component's block, restated: the values a call made, of arguments that are all identity-safe, so the call is the same and its block holds what it held | rule 12: the markup held them while it was made |
    | `dom` | a `Show`'s key, or a `For`'s items and keys, kept by the runtime to match rows | not known: a breach of `boundary.md` §9.4.8 (#2504), out of this rule |
    | `inline` (`browser-inline`) | nothing of a root: a `let` is a `const` of each binding function that reads it, made each time it runs, and one that two functions read is refused (`keepsNoLet`); the model, which the entry holds (rule 13) | nothing to know |
    | `ssr` (`node`), `toy`, `shared-toy` | nothing: they do not `groups`, and render as the markup is made | nothing to know |

    A `let` the lowering keeps that the program then writes is a refusal, not a copy the compiler adds:
    the program writes a copy (`List.copy`), or makes the `let` from a list of the model.

    *The argument.* A call of the program's code by code that the walk does not follow is a call like any
    other (rule 2) when the walk knows where the caller gets the arguments (markup, the entry), and
    otherwise the code is in the default location (rule 8): it is handed values with no claim, so it may
    write none, and what it keeps was given up where the caller got it. Each row of the table is one of
    the two. *Research report 128 §4.1: no walk read a schema declaration, so the function named in a
    `via` never went to the default location; report 129 found the same of a `--library` build's
    exports.*

    **What a schema puts in a program, instruction by instruction.** Each instruction that a schema
    declaration or a use of one lowers to has one rule. *Research report 131: the check of the next
    paragraph took a tagged schema's constructor for code, and no walk evaluates the constructor of a
    pattern, so 54 of the 2 731 ownership roots, each a program that names a schema, stopped the safe
    compiler.*

    | Instruction | What the backend emits | Rule |
    |---|---|---|
    | `schema_member_top`, `ext_schema_member` (`Box.print`, `Box.schema`) | a compiled worker, or `S.schema` | code with no contract (§3.1, §3.2): its value is `outside`, and a call of it lets each argument escape; the workers call the `via`s, the row above |
    | `schema_ctor_top`, `ext_schema_ctor` (`Event.Set`) | `{$: "Set", a: payload}`, or the bare tag (`js/SchemaCtor.zig`, `Lower.ctorValue`), as for a type's constructor | **no code**: no function of the program runs. In a pattern it is a tag test (rule 6): no row describes its parts, so the pattern binds `unknown` over the scrutinee. Called, no row describes its parts either, so it is read as code with no contract (§3.2): each argument escapes and its answer is `unknown` over them. As a value it is `outside` |
    | `schema_via` | the conversion, made once where the module loads | the default location, above (`walkSchema`) |
    | `schema_value_ref`, `schema_expr_ref` | a reference in a `via` or a body | names code; walked where it is evaluated |
    | the plan: `schema_ref`, `schema_app`, `schema_paren`, `schema_record`, `schema_field`, `schema_value`, `schema_tagged`, `schema_variant`, `schema_as`, `schema_optional`, `schema_nullable`, `schema_parameter`, `schema_primitive`, `schema_target_top`, `ext_schema_target`, `schema_type_top`, `ext_schema_type`, `schema_type_ref`, `schema_ctor_ref` | the workers, and types | no code of its own: the workers call only the `via`s and the workers of other schemas (the rows above) |

    **The mechanical check** (`Check.checkCovered`, safe builds). Every instruction that names or runs
    code (`namesCode`: a reference to a value, a lambda, a call of any kind, markup; a constructor of a
    type or of a tagged schema is not one), in every declaration
    whose code the backend emits, was evaluated by a walk or accounted for by a rule (`Frame.noteWalked`):
    otherwise the build panics, naming the instruction. The kinds of declaration are a `switch` with no
    `else` (`value`: its body; `schema`: its `via`s; `foreign_value` and `vocab_markup`: JavaScript of a
    sibling or a runtime, rules 10 and 12; the others: no code), and so are the kinds of instruction: a new
    kind of either compiles only once it is classified. It is what found research report 128's fault
    again in one run: with `walkSchema` turned off, the first program with a `via` fails the check. A
    declaration whose walk gave up or passed its steps is not checked; it publishes nothing and its module
    authorises no write. *What it cannot catch:* a call with no instruction behind it — a name that the
    compiler makes up (a derived row, a dispatch edge, the entry's protocol, the workers of one schema
    calling another's, the exports of a `--library` build, a codec found by the name `codec`); a contract
    of `core/`, a platform or a `foreign` that is wrong; and a lowering that changes which calls run or
    their order. Each of those is a row of the table above, and a new one must be added to it by hand.

## 7. The module

Declarations are walked in dependency order, callees first (`Check.checkModule`); a contract crosses a
module as label paths (`Contract.publish`, `Contract.Reader`), so it means the same in every module. A
worded declaration's body is walked for its own lines, after every contract is known; its contract is its
words, and where the body reaches no JavaScript that can see a cell its contract describes, a word that
claims less than the walk found refuses the declaration; an alias's words are compared with the contract
of the function it names (§6 rule 10, *A worded body is checked against its walk*). A module whose walk reached a limit, or that is not an application
module, authorises no in-place write (`Enforce.checkModule`, `Hoists.finish`).

**A constant read once** (*added 2026-11-27, #2657*; `Mod.soleReference`, the `.top` arm of
`Frame.evalInner`). A top-level value is `outside` every frame (§3.1) because every reader has it. A
constant that is not `pub`, is no function, and that exactly one instruction of the module names has one
reader; where that instruction is in the body of another constant, evaluated by that constant's own
frame and in no markup (`Frame.onceInBody`: no lambda's or local function's body, which another frame walks, and no hole, which a lowering can evaluate where the markup renders, as often as it renders it; the module loader runs the rest once), and where that constant runs once (`Mod.runsAtLoad`: the backend defines both as plain constants, not as a memo per evidence as it does a constant with a `where` clause; `Frame.loaderRunsOnce`: its value holds no function and no foreign value, and it has no markup, since a lowering inlines a constant of markup at each place that shows it, `browser-inline.md` §8.2, and runs it there as often as it renders, as the `dom` renderer does per instance, and a program value's parts run at each mount), the reference is the
constant's evaluation: it is applied as a call of the constant's contract (rule 2), so what the
constant made and let escape nowhere is the reader's own, and a write of it runs in place. No other code
can read the value: the module's other instructions do not name it, another module cannot (it is not
`pub`), and host JavaScript cannot (a `--library` build exports every constant it can call, so the rule
is off there, as in a module with a name that a `via` keeps unresolved, `schema_value_ref` or
`schema_expr_ref`). *Before, `extended = seed ++ [ 3 ]` with `seed = List.range 1 2` read nowhere
else was refused, `unknown` (`browser/inline/InitializationTransfer`).*

## 8. Resource limits

**Every walk ends, and its work is bounded by design.** Research report 126 found a walk that did not: a
function whose local closures form a DAG, each capturing the three of the level below, made `flow` follow
each of the 3ᴺ paths through the captures. Four rules bound each walk that can reach one thing by many
paths:

- **`flow` judges each function once for each use** (`FlowKey`). A judgment reads the function, the
  holder's contract, the capture, the captured values, and two facts of the use above, set where the use
  is made: whether it is the default, and whether a holder above writes what it handed on
  (`Use.up_rewrites`). A judgment that read nothing else above its own use is kept for the rest of the
  walk, and an equal use reaches it again for free. A judgment that read more is judged again on each
  path: one that read the use above it (`upOf`), a key (`freshAtom`: a key names the whole path of
  holders), a draft of the frame's own function, or what an answer was handed (both grow while the walk
  runs). A judgment that meets itself in work gives up (§3.3): its function reaches itself through what
  it captured.
- **A walk of values** (`leaves`, `leavesOwn`, `reach`) walks each value once for each set of entries
  in one walk, and copies what it found, without repeats, where it reaches the value again. The atoms of
  a value are a set and its `dup` is its own, so the copy is what a second walk would find.
- **`flow` follows every use, at any depth.** Before report 127 a use deeper than 16 went to the
  `top` use and the depth started again at 0, so the bound bounded nothing, and the use's supplies never
  escaped: a list handed down 18 closures to one that kept it was written in place. A walk is bounded by
  the two rules above and the limit below, not by a depth.
- **One declaration does at most what its own instructions earn, and never more than
  `Check.max_walk_steps` units of work** (33 554 432), **over all of its walks**: one budget for each
  declaration (`Mod.declBudget`, `Mod.decl_steps`), which every loop that no memo bounds counts
  against. The location table's work counts against the module alone: the table keeps what it built for
  every declaration, so which declaration builds a layout or a projection first depends on their order
  (the review of research report 138). The budget of each declaration is made before any walk. It earns
  (research report 138):
  - **1 048 576 units** (`decl_floor`), whatever its size;
  - **what its instructions earn** (`Mod.earnedUnits`, below): 32 768 for each that a walk evaluates,
    128 for each of a literal or a type, and the pairs of the lists of its literals;
  - **128 units for each entry of the layout of each instruction that a walk evaluates**
    (`layout_units`): a walk of a value visits each entry of its layout a few times, a call each, and
    the duplicate test groups each of its cells (`runsShare`). `f p = p` over nested pairs of 4 096
    lists took 52 units for each entry of its two instructions; a list of 45 references to nested pairs
    of 2 048 lists, 41; a list of 45 calls of a function over them, 270.

  It depends on the declaration's own instructions alone, so it is the same at any `--jobs` and in any
  order. *Before research report 138 the budget was pooled over the module, so what one declaration
  earned another spent: dense lines of cheap references paid for a function whose walk cost the square
  of its layout.* Past it, the limit line names the declaration's own budget ("the walk took more than
  `N` units of work (what the declaration earns)"), or `max_walk_steps` when that is its budget. Two
  kinds of thing count:
  - **a call, 32 units** (`Check.call_units`: about what a call costs beside the loops inside it, so the
    budget is about a million calls; `Frame.tick`): each expression the walk evaluates (`eval`; past
    the budget the walk goes no deeper, and a write it did not reach has no line, so it is not
    authorised); each call of `flow`, `resolve`, `answerOf`, `answerOfCode`, `leaves`, `leavesOwn`,
    `reach`, `partsOf`, `ownSupply`, `answerOwn` and `expandSrcs`; each pair of a write and an escape
    (`demand`) and of a write and a later read (`finishDemands`); in the entry (`entryCall`, rule 13),
    each entry of the contract's answer that a model location meets and each model location that a
    parameter entry meets (`meetsOf`), and each step of the taking away;
  - **an element visited, 1 unit** (`Frame.charge`): each atom compared in a test of two runs of atoms
    (`overlapAny`, `dupOverlap`, `atomsReach`; an old name, which is compared with nothing, is 1), each
    pair of entries that `deriveLinear` tests, each part of a construction that a walk of values or a
    projection visits, each part a record update copies, each atom of a run that `uniqueTail` makes
    unique (and a lookup, 4 units, for each atom of a run of more than 16, which it keeps in a hash
    set), each atom copied out of a run (`copyAtoms`), out of the memo of the walks of values or into
    it (`leafKeep`), each entry of a call map read (`argEntries`), and each atom of a target that
    `rootReach` compares a part of a root with and each entry of the part and of the root it scans; each part of a construction that a
    walk of values goes into is 4 units (`Loc.lookup_units`, the units of a lookup in a hash table: it
    looks up its projection); each location of
    a frame's result, each pair of locations of a written operand and another that are compared
    (`otherReaches`), and each pair of two parts of one location (`expandSrcs`);
  - **a scan, 1 unit and one for each four words** (`Loc.scanUnits`): the scans
    of a contract's flags (`applyAt`, `readBy`, `otherReaches`, `keepsOwn`, `writesOwn`) and of a
    layout or an answer's layout for one location (`selfAtoms`, `readSelf`, `newItem`, `answerOwn`,
    `answerOfCode`, `ownAnswer`, `DraftSink.answer`), each entry of a call map that `readBy` or
    `otherReaches` walks, 1 unit, and an index of two layouts (`meetIndex`, `coverHits`), twice its two
    layouts, once for each frame; the climb of a path to the depth of another, 1 unit for each four
    steps beyond the test it is part of (`Frame.comparable`, `Frame.pathPrefix`: a path into a
    recursive type is as deep as the chain of projections that made it, so one test of two atoms can
    climb hundreds of steps). A projection of a part of a root is a lookup (`project`), and a
    projection of a join is a lookup, and a call where the join's part is made (below).

  Every round of the declaration's recursive group (`solveGroup`, rule 9) and of a group of its local
  functions (`solveCodes`) counts too: the rounds walk again and keep counting; they do not start the
  count again.

- **One module does at most `Check.moduleBudget` units of work: 65 536 (`module_floor`), what its
  instructions earn** (`Mod.earnedUnits`), **`decl_floor` for each value declaration and what the layouts of
  each walked declaration earn** (`Mod.declBudget`), **and never more than 134 217 728 (2²⁷,
  `Check.module_cap`)**: the sum of its declarations' budgets and the work of its types, with the cap as
  a backstop. An instruction earns for what its walks can cost, not for its tokens (research report 136):
  - **each instruction that a walk evaluates, 32 768 units** (`inst_units`, a thousand calls): a
    reference, a call, a binding, a pattern, a `case` and its arms, a function, a record update, a
    markup site, a list built of anything but literals. At 8 192, `NotesApp.viewSidebar` and
    `Ui.Html.map` would pass their budgets (research report 138 §4);
  - **each instruction of a literal, 128 units** (`literal_units`, four calls), and **2 units for each
    pair of two lists of literals that a construction brings together** (`pair_units`), whether or not
    the construction is a literal itself (`[ first, [ 0, 1 ], [ 1, 2 ], … ]`). A literal is a number, a character, a string, `⊤`, a
    constructor, a negated number (`-1`, a call of `Basics.negate`, and the reference to it), and a
    tuple, a list, a record or a constructor applied whose elements are all literals. Its walk
    evaluates each of its instructions once: a list of numbers took 32 units for each and a tuple
    nested 511 deep 80. A list in a literal is a cell, and the walk tests each pair of the cells of a
    value (`deriveLinear`): a literal of `n` fresh lists took about n²/2 + 142·n units;
  - **each instruction of a type or of a schema's plan, 128 units** (`type_units`): no walk evaluates
    one, and the location table counts the places and layouts built for it (an annotation nested 511
    deep took 48 units for each).

  *Before, a module earned 16 384 units for each token of its source, so a literal earned far more than
  its walk could cost and the functions beside it spent the rest: six modules of 200 lines, each with a
  literal of 9 000 numbers on one line and 30 functions `f p = p` over nested pairs of 4 096 lists,
  took 5.7 s of v3 at `--jobs=1` (research report 135 §8); each module now reaches its own budget at
  its first such function.*

  **The bound in time** (research report 138 §5). A declaration spends only what it earns, so a line
  pays for itself: its instructions, and the layouts they walk. An instruction that a walk evaluates
  earns at most 32 768 + 128 · 4 096 units (a layout has at most 4 096 entries, `Loc.max_layout_entries`),
  about 1.6 ms at 3 ns a unit (ReleaseFast); one of three to five over small types, the common case,
  earns 0.1 to 0.2 ms with the floor shared over its declaration. A declaration never does more than
  2²⁵ units and a module never more than 2²⁷ (0.3 s at the 2.2 ns a unit measured there, ReleaseFast).
  The walks that the budget pays for are about linear in what they earn for (*The duplicate test*,
  below), so the shapes of research reports 135 and 136 are accepted, at 0.06 to 0.13 s of v3 for a
  thousand lines at `--jobs=1` (ReleaseFast, LLVM). The slowest found, functions that each build a list of
  45 calls of a function over nested pairs of 2 048 lists, reach the module's cap: 1.4 s for a thousand
  lines as generated, each list on one line.

  Every unit that a
  declaration counts counts against its module too
  (`Mod.module_units`), and so does the work of the module's location table (`Loc.Table.units`): each
  step that the visit of a layout takes and each step of the path that a projection follows for each
  entry (`abstractPath`), each a lookup; each label of a layout of an imported contract that the
  module reads, a lookup (`Contract.Reader`: an entry shares the prefix of its labels with the entry
  before it, and only the rest is looked up); each entry that a layout adds, each entry of a
  projection, a path and a call map that the table builds, and each location that the search of a
  call map climbs; and each place and step that the place graph adds for a type the module names,
  32 units (`Mod.chargePlaces`: `own2`'s adapter takes about as long for one as a call of a walk).
  A scan or a copy of a run of words (the path of an entry, the places on a path
  through a cycle, the climb of a location to its root) is one unit and one for each four words
  (`scanUnits`). `Mod.overBudget` tests the two budgets together at each
  count. A memo entry of the table is built whole, and a loop that has begun ends its pass, so a
  module passes its budget by at most one such piece of work: a call map of two layouts of 4 096
  entries, or one pass over the entries of one layout, about 2²⁴ units.

  Four loops cost their answer and not the product of two layouts (research report 130): the walk of
  a construction reads the rank of each entry asked once, and each part reads its own entries
  (`leavesOwnWalk`); a value read through another layout marks the entries asked (`leavesSet`); a
  set of more than 32 entries tests its members in one step (`Entries`); and the tests of pairs of
  locations for a cell that both hold pair only locations that hold an atom (`finish`,
  `operandLeaves`, `runsApart`): a pair with an empty location compared nothing and cost nothing,
  and 4 096 empty locations were 8 million such pairs in each walk. Each gives the same answer as
  before.
  The scan of an answer's map for one location asked (`answerOfCode`, `answerOwn`) reads the map the
  other way once for that location, not once for each entry of the map (`AnswersAt`, research report
  143): asked of each location of an answer that escapes, the scan of an answer of 4 096 locations was
  16 million reads of a map. It gives `locsMeet`'s answer, pair for pair (safe builds check it for
  layouts of at most 64 entries).

  **The duplicate test is about linear in the cells** (`Frame.runsShare`, research report 138). The
  tests of a set of runs for one cell in two of them (§4.4) compared each pair of runs atom by atom: `f
  p = p` over nested pairs of 4 096 lists did 8.4 million pairs for 4 instructions, and a part of a
  construction was compared with every part before it. A set of more than 64 atoms is now tested in one
  pass, run by run, each atom against the runs before it, ending at the first pair that is one cell:
  two atoms can overlap only at one root and entry, so each atom is grouped by them (a lookup); a group
  of at most 32 atoms compares each pair; a larger one keeps, for each path, two atoms at it and two at
  or below it, of two different `via` keys (an atom with no `via`, or one through a root that is not
  linear, has the key 0), and an atom looks up its own path and each path above it to the group's
  shallowest. Two atoms at comparable paths are one cell unless both were read through two apart parts
  of one root (`viaApart`), so one of the two kept is one cell with the atom whenever any atom there is.
  Atoms read through one part (`via`, `via_e`) have their own tables, and a pair found there is tested
  for its `via_path`; when that fails, the atom is compared with each atom of its part. Two atoms of two
  keys can still be two cells, read last through two entries of one later root (`via2Apart`, §4.4, *Two
  readings through a later root*): where the atom found is apart from the atom so, the atom is compared
  with each atom of its group (research report 159), each pair a unit as before. The largest run
  is taken last, and is only looked up. Each atom grouped, each path looked up or added to, is a lookup;
  each pair compared is a unit. A set of at most 64 atoms is tested in pairs as before, and a safe build
  checks there that `runsShare` answers the same, with its groups compared in pairs and with every group
  tested by tables (`checkShare`). A test whose answer is already yes (a `twice` part, a duplicate found
  before) is not run. The walk of a few entries of a construction of many parts reads only the parts
  that hold a location at one of them (`builtIndex`, made once in a frame), so the walk of each entry of
  a record of `n` fields in `finish` costs `n` and not its square. A list literal past the budget makes
  no projection (`listOf`): a list nested 400 deep made one for each level on the way back up, each the
  size of its layout times its depth, long after the budget was passed (4.1 s on the gates' compiler).
  The answers are the ones the tests in pairs gave: every dump of the 2 314 ownership roots is the same,
  but where a group now settles and where a budget moved (research report 138 §3).

  **The runs of new names are walked once** (research report 134). The run of a `version` or `taken`
  entry holds older atoms, and their runs older ones again, so a chain of `n` writes reaches `n`
  entries from its last name. Three walks follow those runs: `markAtom` (the flags of the contract),
  `groundOf` (what a line rests on) and `atomSrcs` (the sources of a contract). Each goes with a work
  list, not by recursion, and counts each entry it opens and each atom of that entry's run. A run
  never changes once its entry is made, and marking is idempotent, so each entry's run is marked once
  for each flag in a walk, and its highest ground is kept (`RunFact`): the `n` writes of a chain cost
  `n` entries over all of their demands, not `n` each. *Before, each of these walks visited every
  entry again for each write, and counted nothing: 400 writes took 17.8 s after the budget was passed.*
  The tests of pairs count the elements they pass over too: each escape and each read that a demand
  skips (another context, an earlier time), each answer it compares, and each context that the test of
  two contexts climbs to their common case (`compatible`): a write and a read in two arms of cases 2 000
  deep cost 2 000 steps for each pair and counted 1 (the review of report 134).

  **A read of a name of a chain reads its run in one step when the run is old** (research report 135).
  A read of the `n`-th name of a chain holds the `n` older names in its run, and each demand of a write
  before it tests that read: a write `k`, then every later read, each of `n` atoms. Every atom of such a
  run is an old name for the write (its `dead` is at or after the write's time), and an old name is no
  holder (`isOld`, §5.1). A run never changes once its entry is made, so its lowest `dead` is found once
  (`RunFact.old`, one scan) and a run whose every atom is old for the write in judgement reaches nothing,
  in one step (`runReaches`); a read of part of a root tests its atoms where they are, with no copy
  (`refReaches`, the atoms that `leavesOwnWalk` and `rootLeaves` make). Safe builds check, for runs of
  at most 64 atoms, that every atom of such a run is old. The answer is the one the scan gives, so no
  verdict moves but through the budget. The counted work of a chain is still quadratic in its length
  (each pair of a write and a later read is a step), and a chain of more than about 800 writes in one
  function reaches the declaration's budget (about 550 before research report 145 indexed the write,
  below). *Before, the pairs were counted by the old names they passed over, so about 85 writes reached
  the module's budget.*

  **A part of a join is projected once in a frame** (`proj_memo`, research report 135). The arms of a
  join can be values of earlier `case`s, so the values of a walk are a DAG, and `project` made the part
  of each arm again for each path that reached it: a chain of `n` `case`s each of which can answer the
  value of the one before (`t1 = case t0 of Node _ (Just t) → t; _ → t0`) made 2ⁿ joins, each counted
  as its arms while its allocations went uncounted (about 0.1 µs a unit; 20 levels to a limit in 0.7
  s, 400 levels in 3.6 s). A value never changes once it is made, so its part at one step is the part a
  second projection makes: it is kept, by the value and the step, for the rest of the frame. A chain of
  `n` `case`s now makes at most a part for each of its values and each step, O(n²) for `n` levels.

  **A join of a cell's versions is read once at each path, and a value read now is no deeper than
  before** (#2599). After each `case` whose arms renew a cell, the cell's latest version is the join of
  the arms' latest (§13 item 6), and an arm's latest can be the join of a `case` inside it. Each reading
  of the cell reads its latest at a path (`reroot`), and two things made the joins grow faster than the
  work they counted:
  - `reroot` made the whole join again at each reading, and counted nothing. It is now kept, by the
    join and the path, for the rest of the frame (`reroot_memo`); the lookup is a lookup, and a join
    made is a call and its arms.
  - A value read now (`cellsNow`) whose every arm read as one value was a join of copies of that value.
    The arms of a join of versions all read as the cell's latest, which is that join itself, so each
    second reading (`apply` reads its arguments again after `cellsApart`) made a join one level deeper,
    and the next reading of it made each copy again. Such a join is now the one value (§13 item 6).

  One function that makes its own cell and nests an `if` `d` deep, each arm writing the cell, has `2ᵈ`
  ways through it. Before, depth 6 (300 lines) made 262 143 joins in `reroot` and 533 360 values in
  all, and passed its declaration's budget at 0.9 GB; depth 8 made 33.7 million values before it
  passed its budget, and held 4.4 GB; depth 9 ran out of memory past 9 GB, before any limit.
  Now depth 9 makes 7 154 values and 8 180 arms and parts, and is judged in 0.5 s at 61 MB
  (ReleaseSafe, self-hosted); the shape family of `bench/ownership-sweeps/nested-arms.mjs` (depths 1 to
  10, `if` and `case`, a cell made or handed, arms that write or read, the nesting in a local
  function or not, a loan before it or in each arm) ends in a verdict or a limit in at most 1 s and
  110 MB each. The limits it meets are the pairs of a write and a later read (above), which are
  counted: depth 10 has 2 046 writes, each paired with the reads after it.

  **What a walk holds grows no faster than the work it counts** (`Frame.heldItems`, #2599). Each
  element of each list and map of the frame (`quiet_parts`: values, the arms and parts of joins and
  constructions, roots and their entries, atoms, reads, escapes, demands, contexts, memo entries), of
  the frames it is in and of the frames of the walk that ended, is an **item**. At every 512th call
  unit of the walk (`Frame.tick`, `held_every`: the test reads each store of each frame of the chain,
  and at every unit it made a walk of lambdas nested 199 deep ten times slower) the walk holds at most as many items as the units its declaration has counted, and
  `decl_floor`: an item is at least a unit. Past it the declaration is past its budget, and its limit
  line says so ("the walk held `N` items …, more than the units of work it counted and 1048576"). A
  count of lengths, not of bytes, so it is the same on every target and at any `--jobs`. Over the 2 510
  ownership roots the most a walk holds is 0.21 of what it may (`platforms/browser`'s and
  `tests/platforms/gpu`'s modules of `Gpu`); depth 8 of the shape above held 100 million items for 11
  million units. It bounds what a walk holds to within what 512 call units make; a loop that makes items
  with no call unit between them is bounded only by its own count. A mutation that adds 65 536
  uncounted items to each join `reroot` makes ends in this limit in 0.4 s at 86 MB. So each builder of a structure that grows
  with arms, joins, runs or renewals counts what it makes:
  - `joinCells`: each root and arm it joins, and each root it looks up among the keys;
  - `joinVal`: its callers count the arms (a `case`'s arms are evaluated, `projectJoin` is a call and
    its arms, `joinCells` above, the returns of `finish`);
  - `saveCells`: each tracked root it saves, at each `case` and each operand that may not run;
  - `reroot` and `cellsNowIn`: each join and construction they visit or make;
  - `versionOf` and `renewHandle`: each entry of a version is a walk of values (`leavesAs`), and each
    renewal's sources a call (`expandSrcs`);
  - `noteReturnCells` and `backfillCapture`: each entry of each tracked root's contents noted at each
    return point;
  - `runWriter` (§13 item 12): each other operand and capture it judges a writer's run against, at each
    switch point; the reads, demands and renewals of the run count as they do anywhere.

  **A wide record costs its width, not its square** (research report 145). A literal of 3 000 fields
  and one update that writes all of them took 7.9 s of v3 (ReleaseSafe), with no limit, and the time
  grew with the square of the width. Five loops each cost the width once for each field, and each is
  a lookup now, with the same answers:
  - **The budget reads the layout that the walk makes** (`Mod.budgetPlace`). A reference to a local
    earns for the local's layout: the walk's value of a reference is the local's (`.local` in
    `evalInner`). Its own type is an instance of the local's that the type check copied for this
    reference alone, and the adapter read each copy whole, uncounted: n references to a record of n
    number fields were n² reads of a variable, almost all of the 7.9 s. The adapter's work is
    counted now (`Groups.Adapter.var_work`, `Check.var_units`, a lookup each: `Mod.chargePlaces`),
    a field whose type is a leaf is read with no stack (`childId`), and the budgets stop being made
    once the location table's work passes `module_cap`: the module passes its budget whatever the
    rest earns, so no more of it is done. A reference to a top-level value still reads its instance,
    which the walk projects (`.top`): counted, so the cap bounds it (a top-level record of 3 000 fields
    read field by field reaches about 78 million units, 0.8 s of ReleaseFast).
  - **A write of more than 32 atoms is indexed** (`Frame.indexWrite`, `w_index_min`). The tests of
    §5 compare the atoms of each other operand, escape, answer and later read with the write's; two
    atoms overlap only at one root and entry, so the write's atoms are grouped by them (and by root, for
    `rootReach`), and an atom compares its group only (`atomsReachIndexed`, `overlapIndexed`). An atom
    looked up costs a lookup and its group, and never more than the scan of the write it replaces; the
    index is not counted apart (it is linear in the write's atoms, each counted where it was made). The write of every slot of a record of n fields,
    against the n later reads of its fields, was n² pairs of atoms; so was a chain of writes, whose
    write names every older name (§5.1).
  - **A projection of a construction of more than 16 parts is a lookup** (`Frame.builtPart`): its
    parts are indexed by step once in the frame, the first at each step, as the scan finds. The first
    projection scans, as before (most constructions are projected once); the second costs the scan and
    makes the index; each later one is a lookup. A field
    read of each field of a record of n fields scanned its n parts.
  - **`rootReach` reads only the entries of a root that hold a run** (`Frame.runEntries`, for a root of
    more than 32 entries, made once its entries are, which never change after; the first list costs the
    scan of every entry, and safe builds check it for roots of at most 256 entries). A
    record literal's root has an entry for each field value, none with a run, and every operand of an
    update that is a field of it scanned them all.
  - **A projection's inverse is sparse where the child is small** (`Loc.Proj.down_keys`): where the
    child's entries are at fewer than an eighth of the parent's, it names the entries of the parent
    that they are at, not every entry of the parent; else it is dense, as before (an element of a list
    is most of its layout, and a search for each entry cost a quarter more on research report 138's
    lists of references). The projection of each field of a
    record of n fields made an array of n, so n² in the location table (the module's work): a record of
    1 000 lists at 30 types reached the module's budget there (research report 138 §9).
  - The copy of an update looks up each field it names in a sorted list (`recordUpdate`), not in the
    list of every field named.

  No test costs more units than the one it replaces, so no budget moves toward a limit (the review of
  research report 145 found a declaration at its cap that gave up earlier when an index was charged up
  front).

  **The result is read once for each of its locations, and costs what it reads** (research report 159,
  #2532). `finish` reads the frame's result at each location of its layout in turn (`leavesAs`), and a
  call expands the callee's sources at each location of the caller's reading (`expandSrcs`). Five loops
  cost a whole layout, or a whole value, at each location, so a result of many locations cost the square
  of them: `Gpu.Make.checkedIn`'s `Result Error.Error V` has 711, each holding every location of its
  parameters (the answer of unknown code, §3.2), and the module passed its budget there.
  - **A value of no claim, or a closure, is walked once after the walk** (`Frame.finished`,
    `whole_at`): its atoms are the same at every location (`leaves` reads it whole), a value never
    changes once it is made, and every capture is bound when the walk is over. The first walk keeps
    them, and each later read copies them, one unit for each atom, as a hit of the walk of values does.
  - **A reading of a few locations through a map looks them up** (`leavesSet`, `ownAnswer`): the map
    read the other way is made once for each pair of layouts in a frame (`coverHits`, which costs the
    map), and each location asked costs the entries it finds, not a scan of the map.
  - **An argument's atoms at an entry of its parameter are read once for a call's result**
    (`argLeavesKept`, `paired_gen`): with no suffix (§3.4's wide pairs excepted) they are the same at
    each location of the reading that the source is at; they are kept for that call, with the duplicate
    and `hit_all` the read found, and a second read copies them.
  - **Whether a layout holds a record's object is looked up** (`slotHeld`): the slots of each layout
    are indexed once in a frame (`SlotIndex`), and a question costs the depth of its label path, not a
    scan of the layout; safe builds compare the answer with the scan's for layouts of at most 256 entries.

  The answers are the ones the scans gave; the units are fewer. `checkedIn` does 1.1 million units of its
  2.5 million, `checked` 0.84 of its 1.4, and `Gpu.Make` is judged: its two writes are accepted. Behind
  it, `Gpu.Batch.inBatch`, `Gpu.Device.made`, `Gpu.Shader.compile` and `tests/platforms/gpu`'s `readAt`
  pass theirs too; four declarations of `Gpu.Device` and `Gpu.Diagnostics` now reach theirs, since the
  modules before them are walked, and their contracts read, where they were not (no verdict of any
  ownership root moves but the three it gains). A contract that says "these sources at every location"
  once, which a caller would expand once, is not built.

  **Whether a cell the frame made escaped is asked once for each cell** (`freshSrc`, research report 146).
  Each atom of a frame's result that names a cell the frame made asks whether an escape holds it, and
  the test compared the atom with every atom of every escape. A result whose every location holds the
  same cells (a value read through a wide entry, §3.4) asked it once for each location: in `Schema`'s
  `shapeOf` it was 95 % of the work, 16 million units, and passed the declaration's budget. Escapes only
  grow, so the answer for the escapes tested stands: it is kept for each cell (its root, path and
  entry), and a later question tests only the escapes made since, at the cost of a lookup and never more
  than the scan it replaces. The answers are the same.

  The record shapes of research report 145 now cost about their width: the literal and its update,
  a chain of updates, a record of lists whose fields are moved, nested records, a record passed
  through calls and an entry's model, at sizes 250 to 3 000. Two stay quadratic in the number of
  writes and are counted, so the budget stops them: `n` writes each read by later reads (a record of
  `n` lists, each pushed; a record of `n` records, each written by a helper) are `n²` pairs of a
  write and a later read, and a record of 500 lists each pushed reaches its declaration's budget, in
  0.05 s of ReleaseFast. Every dump of the 2 751 ownership roots is the same.


  Past either budget every walk returns at once, the rounds of local functions stop (`solveCodes`), each test of
  atoms answers on the pessimistic side (the two can
  share a cell, one cell is at two places, a root is not linear), a walk of runs stops where it is,
  `finish` is not run (no line, no contract: `walkDecl`, `walkSchema`, `walkExports`, `solveCodes`), a
  derived row is read as code that writes and keeps (`rowInfo`), the declaration gives up (§3.3), and
  the module's report has an `ownership_limit` line that names the budget it passed: a loud refusal. A member of a
  recursive group past it stops the group's rounds, and no member publishes a contract. In the entry, a
  budget passed takes every model location out of `own`, so every write the entry judges is refused. No
  other declaration of the module is walked after one passes its budget (`Mod.module_over`), the
  module publishes no contract of a walk, not even of the declarations walked before that one (so what
  an importer reads of it, and what its dump prints, does not depend on the order of its declarations;
  the reviews of research report 135), an importer reads each of its walked declarations as unknown
  code (a worded declaration's contract is its words, which no walk made, and stays), and the module
  authorises no write. Nor are
  the module's derived rows read for its published facts; an importer reads a row with no fact as code
  that writes and keeps. The reads of those rows count against the module's budget too, and a module
  that passes it only there has its limit line as well. The
  `via`s of a schema and the exports of a `--library` build (§6.14) are walked under the budget of their
  declaration. Over the 2 314 ownership roots (research report 138 §4), the declarations closest to their
  own budgets are `Ui.Html.map` (0.59), `bench/corpus`'s `NotesApp.viewSidebar` (0.56) and core's
  `Dict.descend` (0.52); the largest does 2.1 million units (`Main.changeRouteTo` of the Conduit
  example, 0.35). One corpus program of paths more than a hundred levels deep passes its module's budget,
  as before, `DeepPathThroughList` (report 130 §8): its location table's work, about 450 units for each
  layout entry, quadratic in the depth of its paths. `DeepWrittenPath` does 0.59 of its module's.


  *Research report 128 §5: the budget was the walk's, not the declaration's. A recursive group walked
  each member up to 64 times with a new count each time (6.5 s for a 400-line program, about 30 s for a
  member near both limits), and the entry's largest solution took one round for each model location,
  each round over every pair of locations, with no step counted (18.7 s for 800 list fields). The entry
  now reads each fact once and takes away along a worklist (`entryCall`): about the number of pairs of
  locations that meet, not their fourth power. Report 129's review found that a step's own cost grew
  with the layout: one declaration of a record of 2 040 lists took 6 s under the step limit, and
  declarations added up. The loops inside a step are counted now, and three were made to cost their
  answer and not their layout (a record update reads its base's parts, `argEntries` reads an index of
  the call map, `deriveLinear` pairs only entries that hold an atom, and with the callee's claim only
  pairs with an answer of a function parameter).*

**The complexity argument.** A memo-kept judgment costs one unit for each equal use, so a DAG of `n`
closures with `e` captures costs O(e) judgments and O(n) value walks per root walk. Every other loop of a
declaration's walks — the rounds of its groups, the pairs of the demands, the entry's fixed point, the
tests of runs of atoms and the walks of the parts of a value — is counted by the elements it visits, so
a declaration does at most `max_walk_steps` units however many times it is walked. The location
table's work is counted with it. So **a declaration of `n` instructions that walks layouts of `L`
entries in all does at most min(2²⁰ + 32 768·n + 128·L + 2·p, 2²⁵) units**, where `p` is the pairs of
lists in its literals, **a module at most the sum over its declarations and its types, and never more
than 2²⁷, and a build at most the sum over its modules**: linear in the size of the program and of the
layouts its instructions walk, and at most 2²⁷ for any one module, whatever the shape of its types or the
number of its declarations, and the same at any `--jobs` (a module's budget and its count depend on its own source
and the contracts of its imports only). **What a walk holds is bounded the same way** (#2599): at
most the units its declaration counted and 2²⁰ items, so at most 2²⁵ + 2²⁰ items for one walk.
**A unit tracks time** (research report 135): over the 101
programs of 307 measured (the shapes of research reports 130, 131, 134 and 135, the corpus programs
nearest their budgets, and every fault folder of the sweeps) that do more than 5 million units, a unit
took 4.9 ns at the median and 8.3 ns at the 90th percentile (ReleaseSafe, LLVM), and at most 12 ns where
v3's own walks take the time (a chain of 5 000 writes, whose runs of atoms are made unique in a hash
set). Two shapes take longer for each unit, and in both the time is `own2`'s, which v3 calls and does
not count (below), and the type check of the same module takes 15 to 30 times as long as v3: a
function of 8 000 calls over a record of 2 040 lists (18 ns a unit, the adapter), and 6 000 `==` sites over records in a module with a `pub eq` (62 ns, the pre-pass). So
a declaration reaches its budget in about 0.4 s, and a module in at most about 1.6 s of v3's own
walks (2²⁷ units at 12 ns; the time of `own2`'s code in the two shapes above is not in units, and no
budget bounds it); the slowest measured, 1 000 functions over nested pairs of 4 096 lists, takes 0.8 s. **The
module's cap** (research report 135 §8): when a module earned 16 384 units for each token, a module of
360 lines that held a literal list of 15 000 numbers earned 500 million units, and 60 functions `f p = p` over those pairs
spent them in 3.2 s. The cap is about 15 times the most that a module of an ownership root does. The slowest program that report 130 found takes 5.2 s for 7 767 lines (40 modules
over one record of 2 040 lists), and the largest ratio of v3's time to the type check's there was 131 (nested pairs of
2 048 lists, which the type check reads as 11 aliases). The work outside the count is kept, so no round repeats it, and each
piece of it is linear in counted work: a lookup
in a table (`Loc.proj`, kept for each place and step), and the module's published contracts
(`Contract.publish`: the labels of each entry of each layout they name, once for each module, about
four times the counted copy of those labels where the layout was built or read, and a copy of each
contract that `finish` built).

**The code of `own2` that v3 calls** is linear too (research report 131), and its answers are the ones
it gave before, so v2's verdicts do not move:

- **The pre-pass** (`Prepass.run`) orders the declarations by their edges, and the third leg of
  `check/Edges.zig` is every derived row below a declaration's sites. `own2/TopEdges.zig` finds the
  same `top` edges in the same order, each target at its first place (a repeated edge does nothing in
  Tarjan), from the sequence of each term, made once: a term on no cycle merges its arguments' and its
  row's, and a term on a cycle of rows walks its group, splicing in what lies outside. The cost is
  the table and the edges it yields, except a group of rows on a cycle that reaches two or more of the
  module's declarations, which is walked once for each of its members that a sequence asks for. Safe
  builds compare each declaration's edges with `Edges.declEdges`' for a table of at most 4 096 terms.
- **The adapter** (`Groups.Adapter.ofTerm`) keeps the instructions of a term it reads in a sparse map,
  not a column as long as the module's instructions, and keeps each reading of an alias under one list
  of arguments (`applied`). A kept reading answers again where a second would do nothing more; one that
  met a family head hands the head's arguments to `contexts` again, each at its last place (an earlier
  copy is never read off that stack). For v2, a reading that reserved a record's row is read again,
  since v2's account counts it; v3's account has no allowance, so v3 keeps those too.
- **The family table** (`Family.Table.scan`) keeps the same sparse map and each reading of an alias
  under one list of arguments, with the edges it added, each once.

So a diamond of aliases 64 deep is read in its depth, not in 4⁶⁴ (#2121), and a chain of 3 000
nominal types that each hold 32 others in 0.05 s, not 20 s. The type check's own cycle pass
(`check/Cycles.zig`) still walks the rows below each declaration's sites when the module has a
constant: it is the type check's cost, not v3's, and research report 131 measures it.
The adapter's reading of a type that adds no place was not counted (`Mod.chargePlaces` counted what it
added) until research report 145; each variable it closes and each field of a record it
reads counts now (`var_units`). In a function of 8 000 calls over a record of 2 040 lists, most of v3's 0.43 s is the adapter
(`ofVar`, and the freeing of its tables), and the type check of the module takes 11.5 s: the adapter
reads the types that the type check made (research report 135 §3).

The other limits fall to the pessimistic side, so they cost precision and never soundness: a `resolve`
deeper than 12 or an `answerOfCode` deeper than 8 is a lost answer (`lostAnswer`: `outside` and every
argument in sight), and so is an answer whose query has more than 24 answers in work (`SrcState.seen`);
each location of an answer that a holder lets escape is a query of its own (`escapeAnswer`: one query
for all of them filled the 24 with the answers of a wide message type, and the model of Conduit's
`updateWith` escaped through `Cmd.map`'s function, research report 143); a `partsOf` deeper than 8 claims nothing (the parts are not apart); `isView` deeper
than 4 is no view (its answer is kept); an alias of `sender` deeper than 8 is no sender (a message
sent through it is not a demand, and it is never `own` anyway, rule 13); a frame nested past 200 or a group of local functions past 16
rounds gives up (§3.3); a group of declarations past 64 rounds is a `limit` line that names the member first by name, and none of its members
publishes a contract (a round's contract that is not the last says less than the group does, and a limit
line of a module outside the app is no error, so an importer would read it). A limit line of a declaration
points at its name (`Check.declLimit`; research report 141: every limit line pointed at the module's
first instruction, an unrelated declaration). A type with more than 4 096
locations (`Loc.max_layout_entries`: a location for each path of labels, so `( x, x )` nested 32 times
has 2³²) has the layout of one summary location of a type variable; the module then authorises no write,
publishes no contract and no derived fact, and its report has an `ownership_limit` line naming the limit
(`Loc.Table.over`, `Check.checkModule`), the first type cut and the declaration that met it, at the
type's name when the module declares it, else at the declaration's (`Check.overLimit`; the declarations'
budgets are made in the order of their names, so the declaration does not depend on their order when it
is the budgets that meet the type): a loud refusal, never a cut toward "holds nothing". No
other declaration of the module is walked after a type passes the limit (`Mod.stopped`, research
report 131: 5 000 `==` sites over 5 000 recursive types walked on to the module budget, 6.5 s). A
principled layout exists — the repeated halves of a type past a bound given one summary location for each
object place below them, as the deep level of a cycle has (§4.1) — and is not built (research report 120
§2). Evidence and the rows of derived methods are walked each term once (`Edges.termsEdges`), so a
doubling evidence term costs its distinct nodes and has no limit. The answer of each derived row of the
module (what the methods it calls can do, at any depth) is kept until a contract that it read changes
(`Mod.rowInfo`), so a row's body is read once for each such contract and each read counts; another
module's facts are found by a binary search (`Contract.derivedFact`). None of these is a hole; each is a
prototype's constant, and R-7.4 asks that each become a loud `ownership_limit` before the checker leaves
the prototype stage.

## 9. Checks that run in safe builds

Gated on `std.debug.runtime_safety`, so a drift between this text and the code fails the gates:

| Check | Where | The rule it keeps |
|---|---|---|
| a local is never read before its binding | `evalInner .local`, `capVal` | §3.3 |
| a walk that gave up publishes no contract | `Check.checkModule`, before `publish` | §3.3 |
| `linear` is never read `undecided` | `isLinear` | §4.4 |
| a `later` slot is read through `capVal` only | every `switch` on `Tag` (`unreachable`) | §6.3 |
| `twice` never reaches a supply | `resolve` | §4.4 |
| root 0 is made once, by `init` | `newRoot` | §3.1 |
| every `switch` is exhaustive | the compiler, every file of `src/own3/` | §3.3 |
| every instruction that names code, in a declaration whose code the backend emits, was walked | `Check.checkCovered` | §6.14 |
| every dispatch site that carries evidence, in a declaration whose walk did not give up, of a module within the layout limit (one past it authorises no write), had its evidence judged (`Frame.evidenceAt`), whatever its instruction's form; a site whose only term is its callee is judged by `methodCall` and `type_dispatch` | `Check.checkCovered` | §6.11 |
| the `dom` root keeps a `let` from one render to the next exactly when its `keeps_let` says so | `platforms/browser/zig/dom.zig`, `hoistGroupedKind` | §6.14 |
| the index of a pair's meets says what `locsMeet` says, for layouts of at most 64 entries | `Frame.meetsOf` | §4.1, §6.13 |
| the index of a call map read the other way says what a scan of it says, for maps of at most 64 entries | `Frame.coverHits` | §6.2, §8 |
| the scan of an answer's map, the other map read once, says what `answersAt` says, for layouts of at most 64 entries | `Frame.AnswersAt.check` | §8 |
| a run that a read skips as old holds only old names, for runs of at most 64 atoms | `Frame.runReaches` | §5.1, §8 |
| the entries whose runs `rootReach` reads, listed once, are the ones a scan of every entry finds | `Frame.runEntries` | §8 |
| the pre-pass's edges of each declaration are `Edges.declEdges`', each target at its first place, for a dispatch table of at most 4 096 terms | `own2/TopEdges.crossCheck` | §8 |
| a location of a frame's result with no source holds no cell in the entry of the result value's own layout that holds its cells (the wide entry above it, `Loc.holes`): its emptiness comes from a rule, not from a reading that had no step for it; the check counts no work | `Frame.checkEmpty`, in `finish` | §3.4 |
| a construction at a record's place holds the record's object (a part at the object's step): no rule makes a record of its fields alone, whose slots would hold no cell (a record alias's constructor did); the check counts no work | `Frame.built` | §6.4, §11.2 |
| each location that a reader of a value asks for at another reading than the value's own (`leavesSet`, `argEntries`) is placed in the value's own layout: an entry is at it (the map, or `Loc.all`), a wide entry above it holds it (`Loc.holes`), or the value's own place has its steps and they reach a type of no cell (`Loc.emptyAlong`; a slot, a row and a deep level's member are read by other rules). With `Loc.holes` turned off (research report 146's fault), the first program the gates build panics. The check counts no work | `Frame.checkPlaced` | §3.4 |
| each parameter location that a worded row's word puts in the result (`returned`, `stored`, `aliased`, `builderdone`, `elementof`, `taken`, the elements and storage of `copyof` and its kin, `Record.copy`'s values, a function parameter's answer under `returned`, `stored` or `aliased`) is a source of some location of the result, or has the escape flag: a placement never lands on no location without an escape; and a wide location that `returned` places and does not let escape is held by a wide result location at or above its place, or at its place where the result has no part of no location below it. It reads the words again, apart from the code that placed them. With the escape of `returned` turned off (research report 150's fault), the first program with `returned a → Int` panics. The check counts no work | `Check.checkWordedPlaced`, in `wordedContract` | §6.10 |
| a row whose word puts a wide location of a parameter (a type variable, a `Js.Value`) at a place of the result whose type is not the location's — `returned` or `builderdone` at the same place, `stored` at that place of the result's elements, `elementof` and `taken` an element at that place, `aliased` at any type variable of the result — casts. It reads the words and the types of the store again, apart from the code that marked the row (`castsAt`, `aliasedCasts`). With the types not compared (research report 151's fault: the places alone, which are one for every type variable), the first row of `returned a → b` panics. The check counts no work | `Check.checkWordedCasts`, in `wordedContract` | §3.4, §6 rule 10 |
| every cell of a `Js.Value` that the frame made of parts and read at a type variable, or at a type with one at or below its place, escaped: each leaf of the value is held by an escape of the frame. With that escape turned off (research report 151's fault: `Js.to (Js.array [ Js.from x ])` read at `b`), the first such read panics. The check counts no work | `Frame.checkMadeEscaped`, in `readAtVar` and `narrowed` | §3.4 |
| a summary location of a worded row's result that is not `twice` holds only sources that a word puts there at stated positions, by `statesPositions`, the one reading of §4.4's list that the marker uses too (the same place for `returned`, `builderdone`, `copyof`, `concatenated` and `prepended`'s list; an element location for a value of the element type that `stored` puts beside the one `written returned` list, and for `prepended`'s item; every location for an `exclusive` row's new cells); and a row without `exclusive` (or a cell's handle) names one site for all its new cells. It reads the contract the marker built, after `Contract.normal`, so it checks the marking loop and the sites, not the reading: the two readings of research report 156 disagreed on `stored` beside a `written returned` record, and this check panicked on a row the word validator accepts (research report 157, #2559). With the `twice` of a row turned off (research report 156's fault), or its `fresh` sites split, the first program checked under `--ownership=v3` panics (core's `Schema` rows answer new lists of issues with `fresh` alone). The check counts no work | `Check.checkWordedTwice`, in `wordedContract` | §4.4, §6 rule 10 |
| a worded declaration whose body reaches no JavaScript has a walk's contract below its words' contract: every fact a caller reads of the walk (a flag of a parameter location, a source of a result location, `nonlinear`, `casts`, `old_result`, a function parameter's supply, `free`, `called`, `lost`, `ans_escapes`, `rewrites`), the words say too, or something more pessimistic. It runs in **every** build, not only a safe one, and it **refuses**, `false_ownership_word` at the declaration's name, where the other checks of this table panic: a false word is the platform author's mistake, not a drift of this text from the code. It counts no work. An edge to JavaScript counts only where the walk's values let it see a cell the contract describes (a value handed to the call that holds a parameter's location, a root the answer holds, a cast), and an alias is compared with the contract of the function it names. In a module of core, a new cell at a type variable is none where the walk does not cast. Before research report 162 a worded body's contract was its words whatever its walk found; before research report 164 a call of `round` on a `Float` turned the check off, and an alias was never compared (`run/WordedBodyFalse`) | `Check.falseWord`, `Check.aliasWord`, `Check.reachesJs`, `Frame.judgeJsSites`, at the end of `checkModule` | §6 rule 10, §7 |
| a row of core outside `Js` whose words name a new cell at a type variable of its result is one of `Check.core_phantoms` (`List.builder`, `Dict.keyIndex`, `Dict.empty`, `Record.copy`, `Task.raceOk`, `Task.timeout`), each of which makes none there: the check of core's worded bodies reads such a cell as none (`Check.phantomAt`). With a row of core that answers a real cell at a type variable, that reading would let a false word of core pass. It counts no work | `Check.checkCorePhantoms`, in `wordedContract` | §6 rule 10 |
| `slotHeld`'s index of a layout's record slots answers what a scan of the layout answers, for layouts of at most 256 entries | `Frame.slotHeld` | §3.4, §8 |
| two contracts of one arity that a round joins have one set of layouts, or the first has no fact: a join of two others would drop facts the rounds need. A contract of another arity (a local function whose walk found a capture an earlier walk did not) is replaced, and the rounds walk again at the new one | `Contract.join` | §6.9 |
| each check of this table that counts no work restores every count it could change (the declaration's steps, the module's units, `Loc.Table.units`, the walk's give-up), and builds nothing that a later step reads by key or by index: no entry of the location table (a location, a layout, a projection, a path, a map, a memo's answer; `Loc.Table.no_fill`), no place, and no node, root or memo entry of the frame: each list and map of `Frame.quiet_parts` keeps its length (an answer a check could write into a slot made before it is not compared; no check reaches one today). A walk of leaves inside such a check tags no atom with the context of a join's arm, so it builds no meeting of two arms (`meet`, an entry of `Frame.ctxs`); no check reads an atom's context. Nor does it keep a closure's atoms for the reads after `finish` (`Frame.whole_at`). A check that reads again what a step read walks it by that step's route: `Frame.checkMadeEscaped` reads a join arm by arm, each at its own place, as the escape it checks did (`Frame.madeLeaves`). Before, it read the join whole, at the join's place: where a `Js.Value` was made in two `if`s in a row it built the meeting of their arms, and where an arm was a list (`if c then Js.from [ x ] else Js.null`) a map of the two layouts, and safe builds panicked (`run/JsJoinAtVar`, `run/JsJoinOfList`; master's `browser-inline` code reaches the first in every build). A later lookup of an entry a check built would be free in the safe build and counted in a release build, so the two would read the budget differently. So a safe build reaches a release build's verdicts, limits included; a check that would build such an entry panics | `Check.Mod.quiet`, `Frame.quiet`, `Loc.Table.building` | §8 |

## 10. What the kernel costs

Report 117 §4 lists each real write the kernel refuses that the previous code accepted, with the fact that
would win it back. The owner's standing rule is that a safe real program is never refused, so each is a
finding, not a result.

## 11. Records written in place

*Added 2026-11-15 (research report 142). The owner, the same day: a record update that the checker
accepts writes its base's own object, as JavaScript does; a write it cannot show safe is a compile
error with a copy fix (`Record.copy`), as a list's is (`backend.md` §4). No copy is a fallback.*

A record is judged by the principle of §1 and the write rule of §5, unchanged: its object is a set of
cells, and an update is a write of some of them.

1. **A record's field slots are cells** (`Loc.addSlots`, `Loc.Kind.field`). A record type has one
   location for each field it names, the slot that holds that field's value: `.f=` at the record's
   location, beside the locations of the field's value (`.f`, `.f[*]`, …). A slot is single unless it
   is below an element step or in the deep level of a cycle, where the slots of one field of every
   record of the cycle are one summary location (two cells under one name, the pessimistic side). A
   field that a row holds is the row's: the row's location, a type variable, names every object below
   it, slots included (`Loc.within`, `Loc.cover`). A slot is no step of the place graph; a layout's path
   to it ends in the field's step with `Loc.slot_bit` set (`abstractPath`).
2. **A record literal makes its slots** (`Frame.recordOf`): a construction of its field values, as a
   tuple's is, and one more part, the object, a root the frame made whose slots are `own` (§4.3). The
   construction keeps each value as it is, so a `join` keeps its arms (§6.7). A record alias's
   constructor applied (`P n [ 1 ]`) is the literal it stands for, and makes the same value; used as a
   function, its answer's slots are a new cell each (`ctorValue`, §6.4).
3. **An update writes the slots of the fields it names** (`Frame.recordUpdate`). `{ r | f₁ = v₁, … }`
   evaluates `r`, then each value, then writes: a demand (op `update`) of `r`'s atoms at the slots
   `f₁ …`, with each value as another operand (a value that holds `r` would see the store). It reads
   each slot of `r` at the same time (a copy reads every field, and a name older than an earlier write
   of the object reads a slot that changed). Its answer is the same object: each slot is `r`'s under a
   new name (`version`, §5.1), each field it does not name holds `r`'s part, each field it names the new
   value. An update is not a new object (`makesObject`): a function that answers one answers an object
   that was there before (`Contract.old_result`). An update of a base of no cell (a number read as a
   record) writes an object no cell names, `outside` (§3.4); it made no demand at all before research
   report 148 (`run/RecordPunNumberUpdate`).
4. **A field read is a read of its slot** (`readSlots`). `r.f`, a record pattern's field, and a field
   that a record alias's constructor pattern binds (`P k _`, §6.6) read the
   slot `.f=` of `r` at their time: after an in-place write of `f` the slot holds the new value, so a
   holder that reads `f` after the write is a later read (§5, test 4). A field the write did not name
   reads another cell, and stands. A read of the record whole (a call that reads it, the frame's answer, a
   derived `==` or `compare`, `Js.same`) reads every slot.
5. **A list write writes list cells** (`DemandIn.list_only`): where a callee writes a location of kind
   `list`, a field slot among the atoms (an `unknown` value's, which can be any cell) is no cell of it.
   A part of a root reaches only the slots below it (`rootReach`), as it reaches only its own entries (§4.1).
6. **A message's slots are handed on, not asked for** (`callParam`, `sendSlots`). A send asks for the
   cells a write in `update` could edit (§6.11); `update` never writes a message (§6.13). So the slots
   of a message are supplied to `send` as to any function parameter: a write of them after the send is
   refused there (`Fn.rewrites`).
7. **`Record.copy`** has the words `borrowed { r | } → copyof { r | }` (`Contract.record_copy`). A
   direct call reads every slot of its argument and answers a record the frame makes whose fields hold
   the argument's values (`Frame.recordCopy`): new slots, the same values. Its contract says, for every
   other use, that each location of the answer holds a new cell and each of the argument's. v2 reads the
   declaration as the `foreign` with no word it was (`own2/Rows.fromWords`).
8. **The entry** (§6.13): a slot of the model is a model location like any other. The runtime hands
   the model only at the model parameter (`Mod.entryShape`): a consumer's other parameter (a `Url`, an
   event) is a value the runtime made, and its locations are not compared with the model's.
9. **An answered slot is an operand, and no read at the call** (`Contract.flag_a`). Where a body
   answers a parameter's slot (its frame's answer holds it, or a result location has it as a source),
   the contract says that the slot is answered, not that it is read: the caller holds the answer and
   reads the slot where it reads it, after the call (`readBy` reads no location that is only
   answered). A call that writes counts an answered location as another operand all the same (§5, test
   2): one rule for every kind of cell, since a list location the body answers is answered too (and, as
   v3 has judged lists from the start, read). So `g u v = ( { u | a = u.a + 5 }, v )` called as `g q q`
   is refused at the call, as `g u v = ( List.push u 1, v )` is. A location that is only answered is
   compared with W where its cells can be W's (`canShare`: a slot of another field, or a list's cell,
   cannot), so a write of one field does not compare every answered slot of a wide record
   (`otherReaches`, §8).

   *Research report 144: an answered slot had no flag at all, so the call passed test 2, and the
   caller's callers read the answer as the new name of the written cell (§5.1). In place the answer was
   the written object, where the copying program answers the old one; a loop whose state keeps a
   snapshot of one of its own records (`loop (k + 1) { acc | snap = acc.cur }`, then a write of
   `acc.cur`'s field) is the same call.*

10. **A read of a written field, read first** (`Frame.hoistRow`, `runsBefore`; the lowering channel's
   `reads`, `Lower.hoistReads`). A later read of a slot `W` names, through an older name, refuses the
   update by test 4, unless the lowering reads it before the stores: it binds a temporary to the read
   just before the update's stores, after its values, and the read reads the temporary
   (`ownership-checker.md` §31.14, the hoist v1 makes). Then the read is no read after the write: it is
   a read at the update's time, of the old value, which is what the copying program reads. Test 4
   skips such a read, and the update's line carries its row, where three facts hold:

   - **the read is a chain of field reads from a parameter** (`p.f`, `p.a.f`): a field read is pure
     and cannot fail (`language.md` §11.11), so reading it earlier changes no value and no effect, and
     a parameter is bound before any expression of the body runs, so the temporary can read it there;
   - **the update runs on every path that reaches the read, before it** (`runsBefore`): below the two's
     nearest common instruction, the update is in a part that runs whenever that instruction does — a
     call's callee or argument (only the first of a callee the lowering may short-circuit, `&&` and
     `||` being `Basics`' of core), a construction's part, an update's base or value, a field read's
     record, a `case`'s scrutinee, a `let`'s definition — with no `let` block of its own between (its
     own scope), and that part comes before the one that holds the read. No `case` arm, lambda or
     markup (whose holes a lowering can evaluate where it renders) is on the update's side, and none
     of markup on the read's. So the temporary is bound and in scope wherever the read runs;
   - **the read fails test 4 against every accepted write it reaches**, each of which carries the row;
     the lowering binds the temporary at the first it lowers, which is the first to run.
   - **no read with a row is a part of another's chain** (`hoistsApart`): `p.a` and `p.a.f` are two
     reads, and each would be read first at its own update. Where `q = { p | a = … }` replaces `p.a` and
     `r = { (p.a) | f = 77 }` writes the old `p.a`, the whole `p.a.f` would be bound at `r`'s update,
     after `q`'s stores, and read the new `a`. So each update that carries a row of such a pair is
     refused (`run/HoistChainTwoUpdates`; research report 153 §9, the review's fault).

   Any other later read that reaches `W` refuses as before: a whole read, a call, a read through a
   `let` or a pattern of the record, a capture, an update in a `case` arm whose read is after the
   `case` (v1 places those; v3 does not yet). *Research report 153: TodoMVC's `changed { model |
   nextId = model.nextId + 1 } (… model.nextId …)`, refused by v3 and accepted by v1 under
   `--records-in-place` (#2517).*

Every other rule applies to a slot as to a list's storage: a call's contract flags its slots (read,
written, escaped), so a write in a helper of another module is a demand at its call (§6.2); a
capture, an answer of a function parameter and a cell's contents are never `own`; a slot that escaped
is never written; a function that writes its parameter's slot is refused where the default holds it
(§6.8: a callback of `List.map` that updates its element, `Ref.update`'s function); markup holds what
its holes read until it is rendered (§6.12), and the platform rule that §6.12 trusts holds of a record
as of a list (`boundary.md` §9.4.8: a runtime keeps no record from a hole, to read or to compare by
identity, after the render; the `dom` lowering's keyed `Show` and `For` break it, #2504);
suspension changes nothing, since a value is evaluated before any store and a slot is a cell like a
list's.

What the lowering does with an accepted update is `backend.md` §4's: `(r.f₁ = v₁, …, r)`, every
value first. The oracle (research report 142) writes each update that v3 accepted in place under
`--lists-in-place`, and under `--sanitize-lists` copies it and poisons, on every older name of the
object, each field whose value an in-place store would change; `Js.same` traps two names of one object.

## 12. Dictionaries written in place

*Added 2026-11-19 (research report 160). The owner's decisions of 2026-10-17 and 2026-10-25 (#294,
`backend.md` §4, *Ordered dictionaries*): a `Dict` is an array of `[key, value]` entries in insertion
order and a `Map` from each key to its entry, keys are `Int` or `String`, a write the checker accepts
edits the storage, and a write it cannot show safe is a compile error with a copy fix (`Dict.copy`).
No copy is a fallback.*

A dictionary is judged by the principle of §1 and the write rule of §5, unchanged: it is a list whose
elements are its values.

1. **A keyed collection's storage is a list's** (`Bir.OwnKind.keyed`, `own2/Groups.zig`'s place
   graph). `pub equatable keyed foreign type Dict k v` has a place of kind `list` whose one element
   step is its second parameter, the value. Its storage location names the header, the entries
   array, every entry pair and the `Map`: they are one cell to the checker, written together. Keys
   are `Int` or `String` (`checker-v2.md` §37) and hold no cell, so the first parameter has no step.
   A value held in a dictionary is at its element location, and a record or a list held as a value
   has its slots and storage below it, as an element of a list has (§11).
2. **The rows are v3's** (`core/Dict.beni`). Each primitive is a `foreign` with words, the trusted
   rows of §6 rule 10. The writers `insert`, `remove`, `swap`, `insertAt`, `permute` and the private
   `put` are `written returned` with what they store `stored`; `copy` is `borrowed → copyof`; the
   readers borrow, and `valueFor` and `valueAt` answer `elementof`; `traverseAt` answers `taken`,
   asserted for the loops of the module that read each position once, in order, as
   `List.traverseAt` is; `empty` is `fresh exclusive hollow` (item 8). The words a writer carries are v2's and v3's
   only (`written`, `stored`, `elementof`, `copyof`), so v1 reads no word on them, and v2 reads a row
   over a keyed place as a `foreign` with no word (`own2/Keyed.zig`): neither judges a write of a
   dictionary, and neither checker authorises one (no lowering reads their verdicts on it).
3. **A write.** `insert d k v` of a key that is there replaces the value at its position, and of a
   new key appends one; both write the storage and put `v` at the result's elements. `remove` and
   `swap` write the storage and keep the other values; `insertAt` stores one more. Each answers its
   argument under a new name (`version`, §5.1). `update` is walked: `alter (get d k)`, then `insert`
   or `remove`. `map`, `filter`, `partition`, `union`, `fromList` and `toList`, `keys` and `values`
   answer new storage, built by `put` into an `empty` the loop made, or by `List.push`; their loops
   are walked bodies over typed accumulators, where a fold over a type variable read the storage and
   the values as one location.
4. **A key is a position** (§6 rule 10, *A position*). `insert`'s key and `valueFor`'s key carry
   `position`: `get d k` answers the value at `π1@1[π2]`, and `insert d k v` puts `v` at the key's
   position and keeps `d`'s values at the others (`π1@1[≠π2]`), whether or not the key was there.
   So get-then-insert at one key local (#2563) is read at one match. `remove`'s key carries
   `position` too, a writer with no `stored` value: the value at the key leaves, and the result's
   values are `d`'s at the other positions (`π1@1[≠π2]`). This widens rule 10's *A position*,
   which read the other positions only beside a `stored` value; the fact is the same, of the
   elements that stay. So `update`'s join of `insert` and `remove` holds the value it took out at
   no place but the callback's answer.
5. **Lowering.** The writers of `core/Dict.js` copy: they answer new storage and leave their
   argument as it was, so a build that no v3 acceptance reaches edits no dictionary a program can
   name: only the private `put` writes in place, into storage the loop that calls it made, as
   `List`'s `Builder` is written (v3 accepts each such write in `core/`). Under either
   oracle (`Lower.Input.records_v3`) a call of a `Dict` or `Set` writer that v3 accepted is
   `_sanitize$list` with a site that names it (`Lower.listWriterAt`): `--sanitize-lists` runs the
   writer on a copy of the storage, then poisons the old header and its entries array, so a read
   through an older name traps, and links the two for `same`; `--lists-in-place` moves the written
   storage into the base's header, which every holder of the base sees, and answers the base.
   The walked writers, `Dict.update`, `Dict.sortBy` and `Set`'s, are judged at the call
   (`callsite`) and named to the lowering as writers (`Enforce.callsCoreWriter`), as
   `List.update` is; a writer that takes evidence (`sortBy`) is `_sanitize$listAt`, its base the
   argument after the evidence, and one that may park (its callback waits) is
   `_sanitize$startAt`, the wait, then `_sanitize$settle` with the answer, as a parking list
   write is. A writer answers its argument itself where the write changes nothing: `insert`
   of the value that is there (`Object.is`), `remove` of a key that is not there, `swap` of
   a key that is not there or of a key with itself; this is an answer under a new name as
   any other (`written returned`), and in place the answer is the base in every case.

   *Every form of a call is routed* (research report 161, #2571). What the checker judges is
   the call of the value the callee names, not its spelling, so the channel names the call
   however it names the writer: a method call (`d.update k f`, `s.insert x`), whose
   dispatch term is the writer, and a call through a local that a `let` binds to the writer
   (`upd = Dict.update`, through a chain of such locals, as `Lower.listWriterOf` follows
   it) (`Enforce.coreCallee`), or through a top-level alias of another module (a platform's
   `pub ins = Dict.insert`, which `Mod.calleeOf` reads as `Dict.insert`; `Lower.coreWriterAt`).

   **A writer value is routed where it is made** (#2574). A writer of `List`, `Dict` or `Set`
   named anywhere but as a call's callee (`apply Dict.insert d`, `w = idW Dict.insert`,
   `(λf → f) Dict.insert`, `idSet Set.insert`, a `let` alias, a platform's alias read as a
   value) is a function that writes wherever it runs, and each place it can run is judged: a
   call of it, however the callee value was reached (an identity's answer, a lambda's, a
   local), applies the writer's contract at that call (§6 rule 2: `call` evaluates the callee
   to the `fnref` and applies it); a call that hands it on flows it to the callee's contract
   for that parameter, a written location it is handed is a demand of that call, a cell the
   callee made and reads after is `supply`; a closure that captured it is judged where the
   closure flows (§6 rule 3, `flowCaptures`); a holder that loses it or keeps it — a record's
   field, a list, a `Maybe`, unknown code, a top-level value of the program — puts it in the
   default location, which refuses a writer (§6 rule 8: `call: a function that writes its
   parameter goes where the checker does not follow it`). A platform's refusals stop no build
   but evidence's (§6 rule 11) and this one: a function that writes, put by a platform where no
   rule follows it (`pub push = idL List.push`), would run in the program through the
   platform's value with no line judging the run, so its refusal stops every build (`Enforce`,
   `kept_writer`); a top-level alias (`pub ins = Dict.insert`) is no such holder, since every
   reader reads it as the writer. So in a module whose every line is
   accepted (`Hoists.Table.clean`), every run of a writer value is a write v3 accepted, and
   the lowering makes the value `_sanitize$writer(site, value)` where the reference is
   lowered (`Lower.reference`, `Lower.routedWriterValue`): every call of it, wherever it
   flows, writes under the oracle. There is no copying form: what no rule judges is refused,
   and the refusal names the fix — call the writer directly, or hand it straight to the call
   that runs it (`Enforce`'s message), or copy (`Dict.copy`). A call through a `let` alias
   keeps its own site (`_sanitize$list` with the writer itself, not the routed alias), so no
   write is routed twice.

   **A writer that takes a callback** (`List.update`, `Dict.update`, `Dict.sortBy`,
   `Set.sortBy`) handed on as a value is routed the same way: where the callee runs it with a
   callback that parks, the value is the suspendable twin and answers a `Task`. Its value is
   `_sanitize$writerWait(site, value, Task.andThen)`: the write runs on a
   fresh copy (`start`), and the base is poisoned, or in place takes the written storage,
   once the answer is there (`settle`, after the wait where there is one), as a parking write
   at a call is lowered. *The first review of research report 161 found the synchronous
   `_sanitize$writer` meeting a `Task`, and the value was left as the plain function, which
   copies; that copying form is gone.*
6. **`Set`** is an opaque box around a `Dict t ⊤`; its writers are walked bodies over `Dict`'s rows,
   and a box written in place is the box whose dictionary was.
7. **A shallow read** (research report 161, #2570). A read is of what a cell holds: a later read
   that sees a write is one that observes the written cell's contents (§5, test 4). Most of
   `Dict`'s primitives never observe a value's contents: `size` reads the entries array's
   length, `has` the index, `keyIndex` and `isIndex` a key or the length (a key holds no cell,
   rule 1), and the writers `insert`, `remove`, `swap`, `insertAt`, `permute`, `put` and
   `copy` move each value by its reference (`cloned` copies the pairs, not the values; `insert`
   compares the value at its key with the one it stores by `Object.is`, and either answer
   leaves at the key the value it was handed, so the compare decides only whether a store of
   the same reference is skipped). The v3 word **`shallow`** on such a parameter says so:
   the row reads the parameter's storage location and no location below it (`Check.wordedContract`,
   `shallowParam`); what the row answers or stores of it is read where the caller reads the
   answer, as before. Lowering accepts it once on a parameter, a value, that the words read
   (`borrowed` or `written`), and keeps it in v3's column (`own_shallow_word`). So a value
   taken out of a dictionary and written is not read again by `size` or by an `insert` at
   any key: `Dict.size d` after a push of `Dict.get d k`'s list is accepted, a get, a write
   and an insert at one key in a helper is accepted at the helper's write, and `Dict.update`
   with a callback that writes the value it is handed is accepted where nothing reads the
   dictionary after, since `update`'s own `insert` no longer reads the value its callback
   wrote. `valueFor`, `valueAt` and `traverseAt` hand a value out (`elementof`, `taken`) and
   carry no `shallow`. `List.length` is as shallow and is not marked here.

8. **A walked writer's callback** (*added 2026-11-24, #2657*). `Dict.update d k λcurrent → …`,
   called in a fold's callback (`browser/tea/SubscriptionTapFold`), is read as precisely as its
   `get` and `insert` are. Three facts, each derived where it is used:
   - **A supply at a position.** A function parameter's supply carries `Src.p` as a result's
     source does (rule 10, *A position*): `update` hands `alter` `#Just.0 π1@1[π2]`. A caller
     reads it at the positions of its own match for the argument and the index (`Frame.resolve`,
     `atPositions`), at a call (`Use.call`); a captured function's use reads it with no position,
     the pessimistic side. So the callback's parameter is the value at the key, and the cells
     `update` keeps at the other positions (`π1@1[≠π2]`) are apart from it (`posApart`). The
     match's facts are the result's: the list holds each cell once, and one match names one array
     at one index.
   - **A function a walked body runs at most once** (`Fn.single`). A walked body whose walk calls
     its function parameter at most once (`callParam`, each walk of an instruction counted again)
     and lets it flow to no other holder (`flowOwn`: a callee, a closure that captures it and runs
     more than once, a holder that loses it) publishes `single`. A captured cell
     that the function answers is then at one place of the owner's answer for each call, whatever
     made it (`answerSrcs`): the owner's answer holds what the function answers where its own walk
     put it, and its walk derived `twice` there. The function's own walk reads each capture as a
     parameter apart from the others, which its caller does not promise: two captures can be one
     list (`ys = xs`, then `λ⊤ → [ xs, ys ]`), and a capture can be what the holder hands a
     parameter. So the caller compares the atoms of such a capture with those of every other source
     of the location, and of the capture with itself, and where they can be one cell the location
     is `twice`, as before. *The first review of #2657 found six programs where two names of one
     list were captured and written in place twice; they are refused, `run/CallbackRunTwoNamesLive`.* A caller that holds two such answers holds two
     answers of the owner, whose atoms it compares (§4.4). A cell's row keeps its own `once`
     (§13 item 2): what a cell keeps outlives the call, so a capture from outside the run is still
     at two places of the contents.
   - **A hollow row.** The v3 word **`hollow`** on a `fresh` result says that the result holds no
     value of a type variable: `empty : ⊤ → fresh exclusive hollow Dict k v`, and
     `List.builder`'s holes. The row names no new cell at a `var` location of its result
     (`Check.wordedContract`, `hollowResult`), and the location holds none, as `Dict.empty`'s
     values did when it was a top-level value (§3.1). Lowering accepts it once, on a result that is
     `fresh` (`own_hollow_word`), and keeps it in v3's column; it is a trusted word as
     any other of rule 10. Before, `Dict.empty ⊤` read at `Dict k (k2 × List t)` held one new cell at the
     value, its list and the list's elements, and a fold that wrote the list was refused `disjoint`
     on its own accumulator. The core-only reading of a body's walk (rule 10, *What it does not
     judge*) is unchanged, and so is the walk's reading of `[]`'s element location (#2578).

A walked writer handed on as a value (`applyU Dict.update d`) is a write of `d` at the call: it
is accepted where nothing reads `d` after, its answer read or not, and refused (`later-use`)
where something does, as the direct call is. *Until research report 164 this paragraph said it
was refused wherever its answer was read; blind round AO found it accepted, and the same in
every leg (`apU Dict.update d0`).*

What it does not cover yet: a get, a write of the
value and an insert at one key in one frame, inside a `case` whose other arm answers the
dictionary, is refused at the write where the joined answer's values are read after: the other
arm's values are read as held after the write (`List.get` and `List.set` meet the same
join). A fold whose accumulator holds lists of the items (`[ item, …group ]`) answers one
cell at two places where the items list holds one cell twice, and rule 8 asks the whole answer
to be the function's own; a fold inside a fold's callback answers a value the inner callee
handed back, which rule 8 does not read as own (`List.foldl` in `List.foldl` meets it too).

## 13. Cells written in place

*Added 2026-11-20 (research report 165, slices 1 to 3; #981, #2521). The owner's decision of 2026-10-25
(#981): a `Ref` owns its contents, `Ref.get` answers a loan, and `Ref.update` and `Ref.modify` edit the
contents in place where no loan of them is alive; the fix of a refused write is `List.copy`. No copy is a
fallback: a write v3 accepts runs in place, and one it cannot show safe is refused.*

A cell is judged by the principle of §1 and the write rule of §5, unchanged. What is new is that the
contents of a cell are locations, and that a call can change what a location of its argument holds.

1. **A cell's contents are locations** (`Loc.visit`, `visitEntry`, `deepMember`). A place of kind `ref`
   (`Ref`, `Deferred`, `Task.Fiber`) has a location of kind `cell`, its **handle**, and below the step
   `◆` the layout of its contents: `Ref (List Int)` is `[r, r◆]`. A handle is one array that every name
   of it shares; it is no wide location (`Loc.Kind.wide`): what it holds is at the locations below it.
   The type at `◆` is the cell type's one argument (`Check.typeAt`, `contentsType`). A handle in the
   deep level of a cycle names its contents by no label path apart from the cycle's other members, so
   every other entry of its layout is read as its contents (`Frame.innerOf`, the pessimistic side).
2. **The rows read the cell words** (`Check.cellRow`, `wordedFn`). `cellnew`: the handle is a new cell,
   a site of its own, and the contents hold parameter 0's locations at the same place, which neither
   escape nor are written (`consumed` beside `cellnew` or `cellstored` is no write). `cellempty`: a new
   handle, contents `outside` (`Deferred.make`, `Task.spawn`). `cellread` with `lent`: the result is the
   contents, read and answered (`Ref.get`, `Deferred.wait`, `Task.join`); a loan states positions as
   `returned` does (§4.4). `lentoptional` stays the pessimistic row. `cellwrite` reads the handle and not
   the contents: a store drops them. `cellstored` beside `cellwrite` renews the contents with parameter
   1 (`Ref.set`), and beside `cellcomplete` lets it escape, as before (`Deferred.complete`).
   `cellupdate` and `cellmodify` hand the function the contents `free` (`flag_s`): the row reads them no
   more, and keeps what the function answers in their place, or its answer's second part (`modify`,
   whose result is the first part). The function's answer does not escape. *Amended 2026-11-21:* the
   row runs the function once in each call (`Fn.once`), so a cell the function captured and answers,
   which the holder's frame made in its run, is answered once there and is no cell at two places of
   the contents (`answerSrcs`); one that came from outside the run (a capture of the holder, a
   parameter) is, since the holder's own caller can run it again.
   *Amended 2026-11-22:* what the function writes is of what the row hands it at the written place
   (`ownSupply`, exact as `answerOfParam`'s reading is, for a cell's row alone): a function that
   pushes onto a list of lists writes the outer storage, not the elements, which its own contract
   names apart. Before, the row's function parameter, of a type variable, read every location of
   the contents at each written one, so the contract said that the elements were written too, and
   a writer that pushed a fresh list onto them was refused at its later runs, the fresh list read
   as written in place (`run/CellWriterStoresFresh`; blind round AZ's `cacheFiber` and the
   `Dict` writers of #2594). The call's other operands are still compared with every cell below
   the written place (§5 test 2, `DemandIn.reach`): the function can store there what an operand
   holds, and `List.push d el` with `el` a loan of an element of `d` puts one list at two places of
   the contents, which a later write of the element writes for both (the lane's adversarial
   reviewer, seven programs; `run/CellWriterStoresFreshLive`'s `storedBack`).
3. **Renewal** (`Contract.renew`). A contract says, per parameter location, what the call leaves there:
   null where it leaves the location as it was, or the sources the location holds from the call on. A
   store renews every location of the cell's contents. A walked body publishes, for each parameter
   whose cells a call renewed, the sources of its latest version at each location of its cells'
   contents (`Frame.publishRenew`), joined with its value at each early return (`?`), whatever the
   value it returns holds (an `Err` of no location returns too), with the claim that one run leaves no
   cell at two locations of them (`renew_shared`, item 5). Two contracts of a
   round join a renewal with the other's, or with the location's own cells where the other leaves it as
   it was, and either's `renew_shared` (`Contract.join`); the rounds start from the bottom contract, so a recursive function's
   renewal names its parameter's old cells too (the pessimistic side). The dump writes `π1◆ :=` and
   the sources. A worded body's renewal is below its words' (`Check.falseWord`): every source of the
   walk's, or the location's own cells where the walk leaves it, the words name there too.
4. **What the frame follows** (`Root.tracked`). The contents of a cell are known only where the frame
   names every holder of its handle: a parameter's (the caller's hand: the apart-arguments rule,
   item 8, makes two names of one handle one); a call's answer whose every handle location holds one
   handle that the callee made at this call, at no other location, that it did not let escape, and that
   the answer names first: no renewal and no function of the call put it in another holder before
   (`Frame.cellResult`, `Root.cell_root`); and a version of one. Every other root a frame makes holds,
   below each handle, `outside` as well as its atoms (`rootLeaves`): a copy of a handle in a list, a
   record or a call's answer reads what any holder of the handle may have stored. A capture's cells
   are followed as a parameter's are (item 11); an answer's and a top-level handle's contents are no
   cell of the frame (§5, test 1).
5. **A version** (`Frame.renewHandle`, `versionOf`). A call that renews the contents of an argument
   that is a tracked root whole (`ref` of the root, a version of it, or a join of them) makes a new
   root of the same place, a **version**: each location of the renewed contents holds the renewal's
   sources, read as a call's result entry is (`expandSrcs`: a written location the callee answers is
   a new name, `version`, its old names dead from the call on, §5.1), and every other location what
   the argument held. A handle at a summary location holds the contents of many cells, of which the
   call renews one: there the version holds the old contents too. From then on **every reading of the
   root is a reading of its latest version** (`cellsNow`: an argument, a read, the frame's answer, a
   construction's part), and a value taken out of the cell before is a root of its own, which holds
   the old contents: a loan is a snapshot, and a read of it after an update is test 4's later read.
   An argument that is no tracked root whole renews no version: what the call stores escapes, and each
   handle the argument holds there is shared (item 8).
   *Amended 2026-11-22 (blind round BN).* **One value of the renewal at a time.** A renewal is the
   union of what the body leaves in the cell at each return point and in each arm (item 3), and a
   run leaves one of them: an `Undo` arm that moves `present` to `future` and an `Add` arm that
   writes `present` leave the old `present` at one location each, though the union names it at both,
   and the version's `linear`, read off its atoms, said that the two locations hold one cell
   (`disjoint` at the next write of `present`). So a walked body publishes a claim, as it does of its
   result (§4.4, *One value of a join at a time*): `Contract.renew_shared`, true where one value of a
   renewed parameter at a return point holds one cell at two of its locations (`Frame.renewTwice`:
   each value of the join on its own; a version the frame made whole that is `linear` with no
   `twice` entry holds none at two). A worded row's is true: its words state no count. A caller
   reads the claim where it makes the version (`renewHandle`), on the same ground as a result's:
   the call is no run within (`maybe`), the handle is single, neither the callee nor a function it
   is handed casts, and the arguments are apart (`argsApartAt`, `argsSplit`). Then two locations
   of the renewed contents are apart unless one holds the answer of a function parameter, which
   the callee saw as an opaque root, or both are at one wide location of the callee (§3.4); every
   other pair is tested by its atoms (`deriveLinearSplit`). A call that renews the contents with
   the answer of a function it runs once (`cellupdate`, `Fn.once`) reads the function's own claim
   about its result (`!nonlinear`, §4.4) the same way (`answerClaim`): where every source of the
   renewal is that answer, the function is known code that does not cast, its result's layout is
   the contents' own, entry for entry, with no wide entry, and what it is handed — the cell and
   its captures — is apart; an entry of its result that holds the answer of a function it was handed or
   captured (`( g ⊤, g ⊤ )`, `( second v, v.1 )` with `g = second`), which its frame saw as an opaque root,
   is tested by its atoms there too (the lane's adversarial reviewer, eleven programs). A cell at two locations in one run (`{ h | future = List.push h.future
   h.present }`), a value handed or captured that is also in the cell, and a function that casts
   or is unknown keep the test by atoms (`run/CellRenewalArmsApart`, its live twin
   `run/CellRenewalArmsApartLive`). What it does not cover: the writes and the renewal of a body
   are each a union over its arms too, and a caller reads them together, so after `apply r Undo`
   whose `Add` arm writes `present`, a later read of `future` still reads the old `present` as
   written (`later-use`); keeping the arms of a callee apart in its caller is the next step.
   *Amended 2026-11-22:* item 13 keeps them apart: a body publishes its paths, and its caller reads
   the call as a `case` of them.
6. **Control flow.** The arms of a `case` each start from the versions before it, and after it a root
   whose latest differs between arms is the join of the arms' latest, each in its arm's context
   (`joinCells`, §6 rule 7). A later argument of a call that a lowering can short-circuit
   (`alwaysRuns`: `&&`, `||`) may not run: what it renews is joined with the versions before it. A
   hole of markup can be evaluated where the markup is rendered (§6.12): a renewal there makes no
   version, and is read as one of an argument the frame does not follow.
   *Amended 2026-11-21 (#2594).* The callees a lowering short-circuits are core's `Basics.and` and
   `Basics.or` named directly (`shortCircuits`, as `js/Lower.zig`'s `logicalOp` reads them), and a
   name that resolves to no declaration; every other call runs each argument in order
   (`language.md` §6, *Evaluation order*), so what a later argument renews is the latest version
   after it. Before, every callee of another module or of core counted, and `x + f3 a 3` read the
   cell's old contents after `f3` wrote them (`run/CellWrittenInOperand`). An arm's join keeps its
   context (§6 rule 7, amended): what a later read takes from the arm that did not write is no holder
   of the other arm's write.
   *Amended 2026-11-22 (#2599).* A value read now (`cellsNow`) that is a join whose every arm reads
   now as one value is that value, read alone (`cellsNowIn`). A version of a tracked root reads now as
   the root's latest, so each arm of a join of versions reads as the latest join itself: before, the
   value was a join of copies of it, a level deeper at each reading, and the work grew faster than its
   count (§8). The value alone holds every cell that any copy held; each atom keeps the context of the
   arm of the latest join it was found through, and one the latest found through no arm has none, so
   it is live on every way, where a copy put it in the context of an arm of the old join: the reading
   is as pessimistic or more. The reading of a join of versions at a path is made once in a frame
   (`reroot_memo`, §8).
7. **What a call leaves in a renewed parameter's cells is read where the frame answers**
   (`noteReturnCells`, `cellReads`), at every return point, each early return and the end: the caller
   reads it after the call, as it reads the answer. So a body that stores a value in its parameter's
   cell and then writes the value in place is refused by test 4, as one that answers a value and then
   writes it is (`keep cell g x = y = g x; Ref.set cell y; List.set x 0 9`); and so is one that writes
   its parameter's contents in place and then returns early, on a way where the cell is not renewed
   and still holds the written contents (`run/CellWrittenBeforeEarlyReturn`). A renewal of a written
   parameter that the callee answers is the new name of its cells, as a result's is (§5.1): the
   callee's walk has judged the order of the store, the write and each return. A parameter that no call
   renewed on any way has no renewal: its cells are as they were, and the caller judges a write of them.
8. **A handle with another holder is shared** (`shareCell`). Where the frame no longer names every
   holder of a handle of a tracked root, its contents at that time escape (another holder can read them
   at any later time), and its version holds `outside` as well from then on (another holder can store
   into the cell where the frame does not see); a later renewal of it is one of an argument the frame
   does not follow (item 5). A handle gets another holder where it escapes (`noteEscape`, every escape
   of §5 test 3), where a closure that captured it goes to a holder the walk does not follow (`flowCode`'s
   default and lost uses, item 11; a closure made in a hole of markup, at once),
   where a value of no claim holds it (`unknownOf`), where a function the frame does not know is handed
   it (`callParam`), where another root holds a copy of it (`shareCopies`: a list, a call's answer, the
   renewed contents of another cell), and where a call's arguments hold it at two locations the
   callee's walk read as apart (`cellsApart`, the apart-arguments rule of §4.4). A share makes a version,
   whose runs are atoms of the frame, so it is noted where it is found and made at the next reading of
   a cell (`flushShare`). A handle whose contents have no location (`Fiber ⊤`) has nothing to share.
9. **A function value that renews a cell it is handed** (`Frame.flowRenews`), which a holder runs at
   times the frame does not see: each handle the holder hands it there is shared, and what it stores
   escapes (`flowStored`).
10. **Fibers.** Only one fiber runs at a time, and another fiber can reach a cell only through a holder
    it has. A spawned fiber's body is a closure, so a handle it captures is shared (item 8): its
    contents escape where the closure is spawned, and no write of them in place is accepted in any fiber,
    except by the owner's loan rule for a cell that two fibers hold (item 12). A park needs no rule of its
    own while the frame follows a handle: no other fiber holds it.

11. **A closure writes the contents of a cell it captured** (`Frame.captureContents`, `captureCells`).
    A capture whose layout has a handle is followed as a parameter is (`Root.tracked`): the code that
    runs the closure is its caller. Its root is made where the body first names it, which can be inside
    an arm or after an early return; it is joined and noted as a parameter's is, from the start of the
    body: the arms of every `case` and every operand that may not run are joined in a closure's frame
    (`saveCells`, item 6), and each return point before it holds the capture as it was there, its value
    in the renewal (item 3) and the read of its contents (item 7), as does the mark of a call in a hole
    of markup before it (item 12; `backfillCapture`). Before, an arm that stores nothing, a `?` before
    the store and all storing arms but the last walked were dropped from the renewal
    (`run/CellClosureJoinsPathsLive`). So in the closure's own frame a write of a captured cell's contents
    passes §5 test 1, is judged there by tests 2 to 4 against the closure's own holders, and the contract
    publishes it (`W` at the capture's `◆`) with the renewal (item 3); a capture's cells are read where
    the closure answers (item 7). A store into a captured cell lets escape, in the closure's frame, what
    the holder cannot name: a value the closure was handed, or one read through such a value (a callee
    that runs the closure can hand it back and write it: `run/SanitiserCellStaleLength`). The cell's
    own old contents, another capture and a cell the closure made are named to the holder by the
    renewal. The holder judges the closure where it runs it:
    - **a call of the closure** (`apply`): the captures are arguments, as before; each is read at its
      latest version (`capVal`, item 5);
    - **a call that runs it within the call** (`runsWithin`: every use from the closure up to the call
      is a known contract that neither loses it nor is the default, nor answers it or lets it escape:
      a holder that answers a wrapper `λx → f x` of it, or keeps it, runs it where the frame calls the
      wrapper, after the call and any number of times, `keepsFn`; `run/CellClosureWrappedLive`, and
      core's `Random.map`): the code reads there what its contract reads, writes and renews of each
      capture, at the version before the call's renewal (`readBy`, as `apply` reads a direct call's
      arguments): a write of the contents made before the call is judged against that read
      (`run/CellClosureReadsAtRun`); each write of a captured cell's
      contents is a demand at that call on the frame's latest version, judged against the call's other
      arguments (not the one that holds the closure) and the other captures of each closure on the way
      (`Use.inner`); a renewal makes a version (item 5), which also keeps the old contents at each
      location whose renewal does not name them (`renewHandle`'s `maybe`: the callee may run the
      closure no time at all), where its sources name only captures, cells the closure made and
      `outside` (`capturedSrcs`); a cell the closure made is named as its answer names it at the use
      (`answerOfCode`), so one list it stores and answers is one cell (`run/CellClosureWritesLive`'s
      `storeAnswered`). A handle of the capture that another of those operands holds is two
      names of one cell at the call (the apart-arguments rule, §4.4): a write there is refused
      (`disjoint`), and a renewal is one of an argument the frame does not follow (item 5). The
      callee can run the closure again within the call while it holds what an earlier run handed
      it, and the demand is judged once: a write is refused where the closure lets the captured
      contents, or a cell its renewal of them names, reach the code that runs it (its answer, an
      escape, the renewal of a cell it was handed: `handsContents`; the four last programs of
      `run/CellClosureWritesLive`);
      and since the callee can run it more than once, a later run writes in place what an earlier run
      stored in the cell: the write is of each value the renewal names at the written location too,
      after any number of runs (the closure of the renewal, item 12's amendment of 2026-11-26, (a)) (a
      capture's cells, another location of the cell's own contents, and `outside` for outside the
      frame or a value the callee handed; not a cell the closure made in its run,
      `run/CellClosureRunsTwiceLive`); and where that renewal holds one cell at two places of the
      written location (`twice`: a run that pushed a second copy of an element), the later run's
      write is of a cell at two places, refused (`storedAtoms`' answer, also in a writer's run, item
      12). *Amended 2026-11-21:* before §3.4's amendment the renewal named the cell's every part at
      its outer place and the call was refused `disjoint` for that; with each part at its place the
      two runs are told apart only by `twice` (`run/CellContentsAtTheirPlaceLive`'s `twiceArms`).
      *Amended 2026-11-22 (#2598):* the cell the closure made in its run is excepted only where it
      let the cell escape nowhere. One it let escape (its source in the renewal has the escape bit,
      `fresh!`: a `Deferred` it completed, a fiber it spawned, a queue, a callee that keeps it) has
      another holder (§5 test 3), which reads it after the later run writes it in place: the write
      is refused (`escaped`, `Stored.escaped`), at a call that runs the closure within and in a
      writer's run (item 12). Before, `storedAtoms` dropped every `fresh` source without reading the
      bit, and `List.map [ ⊤, ⊤ ] g` with `g` storing `l` and completing a `Deferred` with it pushed
      onto `l` in its second run (`run/CellClosureStoredEscapes` and its live twin). The callee may
      run the closure once only: no rule counts its runs, so that program is refused too. Nor is a
      cell the closure made excepted where its contract names it at another location than the
      written one (`freshElsewhere`): another location of the cell's contents (`Ref.set r ( l, l )`,
      `{ a = l, b = l }`, a callee's `( l, l )`), its answer, a renewal of another cell, a function
      it hands it to; another location of the contents counts where it can hold the same cell (not a
      field slot beside a list, nor a list above or below the written one where neither is wide: a
      row's `fresh` names the new cells of each with one site, `sameCellAt`). The later run's write of
      one location is of the cell the other holds, refused
      (`disjoint`); before, the first run's `( l, l )` and the second run's push onto its first part
      changed the second (the lane's reviewer, five programs). The same holds of an old cell of the
      capture: where the written location holds it after the call (its renewal names it, or keeps its
      own) and another location holds it too, its renewal naming it or, with no renewal, keeping its
      own (`Ref.update r λ( a, b ) → ( a, a )`, `( b, b )`, `{ o \| b = o.a }`, `( a, [ a ] )`), the
      later run's write of it is of the cell the other location holds, refused (`disjoint`,
      `namesOld`, with the same `sameCellAt`: a renewal of a dictionary that names its values' old
      cells names them as a summary does; the reviewer's second and third rounds, eleven programs);
    - **any other holder** (the default, a lost use, a function parameter of the frame, a list, a
      spawned fiber): the closure runs at times the frame does not see. Each handle it captured is
      shared (item 8), and a write of a captured cell's contents is refused (`call`).
    A closure is no holder of its captures until it runs: a handle it captured is not shared where it is
    made, so the frame keeps writing the contents in place until the closure goes where the walk does not
    follow it. `run/CellClosureWrites` and its live twin `run/CellClosureWritesLive`;
    `run/SanitiserCellReentryApart`, `SanitiserScopeHost` and `SanitiserNestedCallbackWrite` are
    accepted and run in place.

12. **A cell two fibers hold: the loan rule** (the owner's decision on #981: a loan may not stay alive
    across a suspension point or escape; `Ref.update` and `Ref.modify` edit in place when no loan of the
    cell is alive; #2581). A function that writes the contents of a cell the frame made, and goes where
    the walk does not follow it (a spawned fiber, `Task.par`, a list, unknown code, a wrapper a callee
    answers), runs at the frame's **switch points**: no other fiber runs between them.
    *Amended 2026-11-23 (#2613):* only where its holder starts it in a new fiber, unmasked, of the
    scheduler the frame runs under (`Fn.forks`: `Task.spawn`, `spawnDetached`, a race's branches),
    and
    where it can never park that fiber masked or lent to another scheduler; at every other holder it
    shares what it captured (*A defect*, (d)).
    - **A switch point** is a call whose callee may be impure or may suspend (`switchAt`, the effect
      checker's answer, `Dispatch.effectAt`; a module with no effect table: every call). Not only a
      call that suspends: an impure call can run other fibers without one (`Task.fromHost` drains the
      fiber queue where its callback returns), so every `Ref` operation is one. A contract says
      whether its body has one (`Contract.switches`; a worded row's is true).
      *Amended 2026-11-26 (#2697): every form that runs code is one, whatever its syntax.* Each
      effect site the effect checker writes (`Effects.call`) runs code, and the walk asks at each
      one, after its operands and before the code reads them, through one helper (`switchPoint`,
      with `runBegin` and `runEnd` for the writers made in the call): a call (`call`), a method call
      and an operator such as `==` and `<` (`methodCall`), a return-type dispatch `a.make n`
      (`type_dispatch`, a call of the method the binding names), an entry (`entryCall`), and a
      component, which the markup's runtime calls where the markup renders (its effect site is its
      callee's), as a call in a hole of markup is. The runtime's call of a `For`'s or a `Show`'s
      function where the markup renders has no effect site: it is a switch point there where the
      function can run other fibers (`fnSwitches`), or is the frame's own function parameter, whose
      caller judges only what the frame hands it, not the other cells the frame holds there. Interpolation and a `case` run no code: a part
      of `${…}` is a `String`, `Int`, `Float`, `Bool` or `Char`, and a pattern tests a tag or a
      literal. In safe builds `Check.checkCovered` fails on an effect site that a walk evaluated and
      no form asked about, so a form that skips the question fails on its first program. Before, a
      return-type dispatch asked nothing: in a generic that held a loan of a cell across `a.make n`,
      bound to a method that sleeps, no writer ran there and no handle was probed, and the loan
      saw the write of a fiber that ran while the method slept (`run/CellTypeDispatchSwitchLive`;
      `cells.mjs`' `switch.*`).
    - **A writer** (`registerWriter`): such a closure, at a capture whose every handle is one of a
      tracked root the frame made (item 4: not a parameter's, a capture's or an answer's), not shared
      and not marked, where the closure writes the contents in place, lets neither them nor the handle
      escape, hands them to no code that runs it, answers nothing of the capture, renews them with
      captures, its own cells and `outside` only (`capturedSrcs`), writes no parameter of its own,
      and has no mark there. A writer's capture is not shared where it goes out of sight (item 8), and
      its handle and contents are no part of what escapes with it (`closureHeld`; the escape of a
      callee's lost or kept function parameter, `applyAt`). A closure that only stores into the cell
      is no writer: it shares the handle, as before. *Amended 2026-11-22:* a closure that reads the
      contents and neither writes nor renews them, with every other condition of a writer, is a
      **reader**: it is registered and runs as a writer does (it reads the contents at each switch
      point and return point, which a write in place before it is judged against), its capture is
      not shared where it goes out of sight, and it is never revoked: it writes nothing, so another
      holder of the cell sees nothing of it, and it holds no loan across a switch point of its own
      (the mark), lets none escape and answers none. Before, a fiber that only read the cell shared
      the handle, and every writer fiber of it was revoked (blind round AZ's `p5/w6`;
      `run/CellReaderFiber`).
      *Amended 2026-11-22 (#2604): what a reader reads after the frame ends.* A reader can still be
      pending where the frame returns, and reads the cell at any later time: a holder that writes
      in place after the return what it read there writes what the reader still reads. So what a
      reader reads at each return point (its capture at each location its contract reaches, the
      handle among them: `capHeld`, as `closureHeld` reads a closure that goes out of sight) is
      held by it from then on, and escapes where the walk ends (`readersHeld`), after every
      judgment of the walk: the frame's own writes and the writers' runs, which the reader's runs
      judged, are not refused for it, and no handle is shared, so a reader still revokes no
      writer. The contract says that each of those cells escapes (`freshSrc`'s bit, `flag_e` on a
      parameter's or a capture's cells): an answered handle has another holder (`cellResult`), so
      its contents are no cell of the caller's; an answered loan, a loan stored in a parameter's
      or a captured cell, a handle in a record, a list, a `Just`, a dictionary or another cell, and
      a parameter's list the cell was made with, are refused at the caller's write in place, with
      the `List.copy` fix. Before, the reader escaped nothing, and `mk` answering `( r, fiber )`,
      `( Ref.get r, fiber )` or storing `Ref.get r` in its parameter's cell let the caller push
      onto the list the pending fiber then read (`run/CellReaderHeldLive`; `cells.mjs`'
      `reader.*`).
    - **A run of a writer** (`runWriter`) at each switch point after it is made (and at the call that
      made it, where that is one), and at each return point (`?`, the end): as a call that runs it
      within (item 11), it reads what its contract reads of the capture there, its write is a demand at
      that call on the frame's latest version, of what an earlier run stored too (a cell its own
      run made and let escape among it: refused, item 11's amendment of 2026-11-22), judged against the
      call's operands (but a handle read through itself where the callee's parameter there has a cell's
      layout, so the callee follows it and its probes mark it, `followedOps`: a handle at a type variable
      or handed to code the walk does not know is an operand, `run/CellFibersInPlaceLive`'s `generic` and
      `handedOn`; and a closure's capture of the handle, which read the contents where they run, unless the closure answers something of the capture, lets it
      escape or stores it, `keepsCapture`: the callee can hold that loan, or the handle, across its own
      switch points, `run/CellFibersInPlaceLive`'s `getter`; at a return point, the answer) and the writer's other
      captures, and its renewal makes a version that keeps the old contents (`maybe`). So a value taken
      out of the cell and read after a switch point, or handed to it, is refused there, with the
      `List.copy` fix.
      *Amended 2026-11-22 (#2600):* the caller's runs judge the cell's old contents at their own
      locations, as they were before the call. That holds only while the body leaves each old cell
      at its own location, and the body may leave there, across a switch point, a value the caller
      does not name: the stored values of the bullet *What the body stored*, now with `outside` and
      the moved old cells.
      *Amended 2026-11-26 (#2698): every version the call can show it.* **A writer or a reader that
      can run inside a call (one made before the call, or made during it by the callee or by anything
      the callee runs, at any depth) is judged at that call against every version of its cell that the
      frame's loans can see while the call runs: the version before the call, the version after it,
      and each version in between that the callee's contract names.** "The frame's latest version" is
      the version after the call where the call renews the cell, and the writer runs at the callee's
      own switch points, which can come before the callee's store: there it writes the old contents.
      So, where the call is a switch point (`runBegin` keeps the latest version of each tracked root,
      `runEnd`): a writer or a reader made in the call runs on the version before the call and on the
      version after it; a writer or a reader made before the call ran on the version before it at
      the call's switch point (`switchHere`), and runs on the version after it too where code the call
      runs within it renewed its cell (a closure run within, item 11, or a writer's run:
      `within_renews`), since the callee can park after that code ran and no contract of the callee
      names that store; for the same reason the call is then a switch point on the version after it
      for the frame's tracked parameters and captures too (`probeCells`, with *What the body stored*):
      a closure run within that stores a list in a parameter's cell, then a callee that parks, is a
      store followed by a switch point, and marks the handle for the caller's writers. A version in
      between is one the callee made and then parked on: its own store
      into its parameter's cell, which marks the handle where it parks (*What the body stored*), and so
      refuses every writer of the cell (*Revocation*); a store by code it runs within it is one of the
      two above. A run on the version before the call renews no version: the run on the version after
      it keeps the old contents beside its renewal (`maybe`). Item 11 is the same rule for a closure
      run within a call: it is judged at the version before the call's renewal, and the code that can
      renew the cell inside the call before the closure runs holds the handle (an argument, another
      closure's capture, a writer that is an operand), which is a second name of the cell at the
      call: its write there is refused (`disjoint`). Before, a writer made in the call ran once, on
      the version after it, and `forkThenSet r w = (Task.spawn w; Task.sleep 5 ms; Ref.set r [ 9 ])`
      with a loan of the old contents held across the call was wholly accepted, and its writer pushed
      onto the loan while the callee slept (code reader CR11's `writerAfterRenew`, through `Ref.update`,
      a method, a wrapper, a local, a record cell; DIFF in place); and a writer made before a call
      `runSleep s = (s ⊤; Task.sleep 5 ms)` handed a closure that stores a list the frame reads after
      pushed onto that list while the callee slept, and so did the caller's writer where the frame's
      parameter was the cell and the frame read the list after the call (`cells.mjs`' `renew.*`;
      `run/CellWriterBeforeRenew` and its live twin). It is the pessimistic side: a writer made in a call is refused for a loan of
      the old contents also where the callee parks only after its store, and a writer made before a
      call whose closure run within renews the cell is judged on the renewed contents also where the
      callee never parks after it; and a fiber whose `List.foldl` callback inserts a fresh list into
      the cell it captured marks the handle, as two updates in a row do, so it is no writer
      (`run/CellWriterStoresFreshLive`'s `dictFold`, accepted before through this hole).
      *Amended 2026-11-26:* a call in a hole of markup that is a switch point runs where the markup
      renders (*A switch point*), so no writer of the frame's cells runs in another fiber after it: a
      closure the frame makes after such a call is no writer or reader (`registerWriter`). Before, only
      the writers made by then were marked there.
      *Amended 2026-11-26 (#2701, #2702, #2703): to a fixed point, against every holder.* A run can
      happen any number of times and in any order, so what the checker reads of the runs is the
      join over every number and every order, never a fixed number of steps or one order:
      (a) **A repeated run is read to its fixed point.** Where the code that runs a closure within a
      call (item 11) or a writer (this item) can run it again, a location of the cell's contents
      holds, after any number of runs, the old cells of every location the renewal reaches from it:
      the closure of the renewal's location-to-location map (`renewReach`: an entry with no
      renewal keeps its own cells; an entry of the code's own parameters, which its holder hands
      it anew at each run, is not followed). So a later run's write of a location is of the cells
      of every location it reaches (`storedAtoms`), and of each source those name (a cell the code
      made and let escape, `twice`, `outside`); the version after a call that runs a closure within it holds at each location the
      sources of every location it reaches (`closedSrcs`, `renewHandleOf`'s `closed`), and a
      writer's versions reach the same closure a step a run, since (b) runs it again on the version
      its run made; a cell that the written location and another one hold after the same number of
      runs is a cell at two places (`heldTwiceAfterRuns`: a search of the pairs of locations, one
      run back through both renewals at each step, `sameCellAt` at each step); and what the code
      may hand its holder is every location the contents reach (`handsContents`). Before, one
      application of the renewal was read: `Ref.update r λ( a, b, c ) → ( c, List.push a 0, b )`
      run three times by `List.foldl` pushed in its third run onto the old `.1`, which the frame
      held as a loan and printed after (code reader CR12's `rotWithin`, `rotHelper`, the record
      `rotRecord`; TRAP and DIFF in place), and `( List.push b 0, c, d, d )` pushed in its third
      run onto a list the third and fourth parts held too.
      (b) **The writers that can run in one place run to a fixed point** (`runWritersFix`): at a
      switch point, at a return point and in `runEnd`'s passes on the versions before and after a
      call, each writer and reader runs where it has not run yet, and again wherever a run of
      another one changed its cell (the atoms of its latest version, read by the cells they name:
      a version is a new name of its origin's cells), until no run changes the cell of any writer.
      Each run keeps the old contents beside its renewal (`maybe`), so a version only grows, and a
      run that changed its own cell runs again; the result is the join over every order and every
      number of runs. (One closed run of a writer, instead of a run a step, made each version hold
      the sources of every location, which the next run read again at each location: the atoms grew
      by the size of the reach at each run, past the budget for four fibers that each rotate four
      parts.) Each round is work (§8): past the budget the walk gives up and accepts
      nothing. Before, each writer ran once, in the order the frame made them, and `runEnd` read
      whether code run within the call renewed the cell before any of its own runs: an older writer
      never ran on what a writer made in the call moved into its cell (CR12's `oldAfterNew3`: a
      fiber forked before `spawnSleep` pushed onto `.0` after the fiber `spawnSleep` forked moved
      the old `.1` there, the loan of which the frame printed; TRAP and DIFF in place).
      (c) **A run is judged against everything the call can run.** The operands a writer's run in
      `runEnd` is judged against are those of the call's switch point in `runBegin`: the
      arguments, the callee value (a closure the callee is reads its captures inside the call,
      after a writer it forked ran), and the receiver of a method call. Evidence a call is handed is
      a declared method, which captures no cell of the frame, or the frame's own function parameter,
      which its caller judges. Before, `call` handed `runEnd` the arguments alone, and `k = λw →
      (Task.spawn w; Task.sleep 5 ms; List.length l)`, with `l` a loan of the cell, called with a
      writer that pushed onto it, counted the pushed list (CR12's `calleeCapture`; TRAP and DIFF in
      place).
      (d) **A later run reads what an earlier run wrote and left** (#2708). Where a call runs a
      closure within it and can run it again (no holder on the way runs it once, `Fn.once`:
      `runsOnce`), a write of a captured cell's contents at a location that no way of the closure
      stores back (no renewal there: a store renews every location of the contents, item 3) leaves
      the written value in the cell under its old name, and the closure's next run reads it there
      as the old contents: the write is refused (`later_use`, `kept_written`), as two calls in a
      row are. A write the closure stores back (`Ref.update r λl → List.push l x`) is read under
      its new name by the next run, as plain code reads the value it stored. Before, the write was
      judged once, against the call's other operands and the frame's later reads, and `List.map
      [ 1, 2 ] λ_ → (l = Ref.get r; s = ints l; _ = List.push l 45; s)` printed `1 1,45` in place
      for `1 1` (blind round DA: `List.map`, `foldl`, `indexedMap`, `Dict.map`, a helper that
      calls twice, recursion, `Task.repeat`, `Task.retry`, `Semaphore.withPermit` and `Log.span` in
      a map; lists, nested lists, record fields, `Dict`s and `Set`s; `cells.mjs`' `fixed.kept.*`).
      A writer fiber that does the same is refused by its own runs at the frame's switch points.
      Two shapes need no rule of their own. A version between a closure run within and the
      callee's own later store into the same cell (`g r c = (c ⊤; Task.sleep …; Ref.set r [ 9 ])`)
      needs two names of one handle at the call, the argument and the closure's capture, which item
      11's apart-arguments rule refuses (`disjoint`) or shares (CR12's `between` programs). A
      writer that the callee forks again where the frame registered it already runs on the version
      before the call at `runBegin`, and a version after the callee's own store that a fiber could
      see needs a park after the store, which is the mark (*What the body stored*) and revokes every
      writer of the cell (`run/CellFixedPointRuns` pins both).
    - **A probe** (`probeCells`): at each switch point, the contents of each handle of each tracked
      parameter and capture, as they are, against the call's operands (as above) and every escape so
      far, and at the end against every later read (`finishProbes`, with `Atom.ren`, below). A refused
      probe is no diagnostic: it is the **mark** (`Contract.flag_m`) on the handle in the contract, which
      says that the body holds a value taken out of the cell across a switch point. After the probe the
      contents get a new name for probes alone (`renameContents`): each copy in the version holds the
      time (`Atom.ren`), so a value taken out of the cell after the call is no value taken before it.
      No rename is a write (`dead` stays: a write before the call is judged against reads after it as
      before) and none is a renewal (`onlyRenamed`, item 3).
    - **What the body stored escapes at a switch point** (`escapeStored`, from `probeCells` and from a
      call in a hole of markup). At a switch point, the contents of each handle of a tracked parameter
      or capture that are not the cell's own old contents at their own locations (`storedAt`: a value
      the body stored there, a cell it made, another root's cells, `outside`, and an old cell of the
      contents that the body moved to another location that can hold it) are in the cell while
      another fiber runs, which can take a loan of them through another holder of the handle; the
      caller judges only the old contents at their own locations (its runs, probes and marks), and learns what the body stored only where the body ends. So they escape
      there, and a later write of them in place is refused: a writer that stores, parks and writes
      what it stored is no unit of one run (`run/CellStoredParkedLive`). It is the pessimistic side:
      a body that stores into a parameter's cell and then makes any call that may be impure lets the
      stored value escape for its caller too, even where no other fiber holds the cell (#2592).
      *Amended 2026-11-21 (#2592): the holder judges it.* What the body stored still escapes at a
      call in a hole of markup, and at a switch point where an operand of the call can read the
      contents there (the probe's operands: a closure that captured the handle, code that does not
      follow it): that code runs in this fiber between the store and the write and can keep what it
      takes. At any other switch point the body notes what it stored in each handle of a tracked
      parameter or capture (`noteParked`), and a later write of it in place, at or after that switch
      point (the switching call's own write among them), puts `flag_p` on the handle
      (`parkedWrite`). A writer of the cell that runs while the body is parked writes the stored
      value in place, which another holder of it sees (a value the body was handed or captured, a
      list it stored in another cell too, its answer): the handle has the mark, and the holder's
      writers of the cell are refused. The body accepts the write; the holder judges it where it names the handle
      (`parkedHeld`): another operand of the call that reaches the handle (a closure handed beside it
      that captured it, a second name of it) refuses the call, as that code runs between the store
      and the write; a parameter's or a capture's handle puts `flag_p` in the holder's own contract; a
      root the frame made and follows, with no other holder, is fine, since a fiber that could take
      the stored value while the body is parked holds the handle: a closure that captured it went
      out of sight and shared it (item 8), or a writer, which runs there and holds no loan across a
      switch point of its own (the mark); any other holder, or a handle the frame does not follow,
      refuses the call. A function whose contract has `flag_p` on a capture's handle is no writer,
      and is refused where it goes out of sight (`storesParked`); one with `flag_p` on its own
      parameter's handle is refused wherever it flows as a value (`paramsParked`), since only a call
      of it names what the holder hands there. So `g r = (Ref.set r [ 9 ]; _ = List.length (Ref.get r); ⊤)` and
      then `Ref.update r push` in the caller is accepted, and so is a helper that stores, parks and
      writes what it stored when its caller's cell has no other holder (`run/CellStoredThenSwitch`);
      a spawned closure that does it, a helper called while a reader fiber holds the cell, a
      callback that captured the cell and runs between the store and the write, and such a helper
      handed as a value, are refused (`run/CellStoredParkedLive`, `run/CellStoredThenSwitchLive`;
      the lane's second adversarial reviewer found the last two, 32 programs, and a third one the
      writer fiber that pushes onto a list the helper stored while its caller still holds it, 20).
      *Amended 2026-11-22 (#2600): what the body stored is read by its location.* Before, the body
      noted no atom of `outside` and no atom of the cell's own old contents, at any location. So a
      body that stored a top-level list in the cell and parked (`Ref.set r big; Task.yieldNow ⊤;
      Ref.set r [ 0 ]`) had no mark, and the caller's writer fiber pushed onto `big` in place during
      the park; and a body that swapped the two parts of a pair, parked and swapped them back had a
      renewal that names each part's own old cell and no mark, and the writer fiber pushed onto the
      first part, which held the second part's old list, a loan the caller read after
      (`run/CellParkedOutsideLive`, `run/CellParkedMovedLive`). Now each location of the contents is
      read on its own (`storedAt`): an atom of the cell's own old contents is passed over only at its
      own location, or at one that cannot hold that cell (`sameCellAt`: a list above or below it, a
      field slot beside it), and `outside` is noted. Noted, a
      value marks the handle (`flag_m`), so the holder's writers of the cell are refused, and a
      later write of it in place puts `flag_p` on the handle, as for any stored value. An
      `outside` atom does not escape where an operand can read the contents: no write of it in place
      is accepted in the frame (§5 test 1), so its escape says nothing; its mark does. A summary
      location holds many old cells at one location, and the caller's runs read all of them there.
      It is the pessimistic side: a body that parks with a top-level value in its parameter's cell, or
      with two of its parts swapped, marks the handle even where it puts them back before the caller
      sees the cell (`cells.mjs`' `park.*` dead twins with a writer fiber).
    - **Marks reach the frame** (`applyMarks`, `markHandles`): a callee's or a closure's mark on a handle
      it is handed or captured marks the holder: a parameter's or a capture's in the frame's contract,
      a root the frame made in `cell_marked`. So does a call whose contract hands a cell's contents to a
      function that can run other fibers while it holds them (`Fn.supply` naming a location below the
      handle, a function with `switches`, any function the walk does not know; the frame's own function
      parameter is judged by the frame's caller through the supply it publishes): `Ref.update r λl →
      (Task.fromHost …; List.push l x)`. *Amended 2026-11-26 (#2697):* a function value of no
      claim (`outside`: a top-level value that computes a function, a function in top-level data,
      (d)) is one the walk does not know, so `fnSwitches` answers that it can switch, as
      `valRunsOn` and `flowUnknown` read it. Before, it answered that it could not.
    - **Revocation** (`revokeWriters`, at the end of the walk): a writer is refused where it went out of
      sight if its cell got another holder at any time (item 8), the frame answers its handle, or a
      holder of the cell has the mark. A reader is not revoked for another holder or an answer of
      its handle: what it read at each return point escapes instead (the reader amendments above).
      *Amended 2026-11-22 (#2604):* a reader is revoked where a holder of its cell has the mark. The
      mark says that a holder keeps a value taken out of the cell across a switch point, and a reader
      that went where the walk does not follow it can run there even inside a function the frame
      hands a cell's row (`Ref.update`, `Ref.modify`), which cannot suspend: a synchronous call of
      code that keeps it runs it, between the function's write in place and the store-back. The
      frame's walk does not see that switch point (it is in the function); the mark is what reaches
      it (`applyMarks`). Blind round BP's sink, `Log.setSink λe → … Ref.get r …` beside
      `Ref.update r λl → (l2 = List.push l 5; Log.info "x"; l2)`, was one; a sink is now refused
      before, by the defect clause below. It is the pessimistic side: a holder that only reads the
      value it keeps across the switch point marks the handle too, and a fiber, which no
      synchronous call runs, is revoked as well (`cells.mjs`' `marked.*`).
    - **A defect** (#2605). A throw stops the code between an in-place write of a cell's contents
      and its store-back (`Ref.update`'s function), and plain code would have left the old
      contents there; code that runs after the throw then reads the cell: `Task.onDefect`'s and a
      scheduler's hook (`Task.scheduler`, `Task.schedulerWith`; `boundary.md` §9.8.10 (c)), the
      teardown's drains with `Task.onTurn`'s hook and the cleanups of each fiber it cancels
      (`Task.bracket`'s release, `Task.onExit`'s and `Task.defer`'s handler, `Task.start`'s
      report; §9.8.14), and the sink of `Log.setSink`, which any of that code runs where it logs.
      So such a function runs at every point, not only at a switch point: it is neither a writer
      nor a reader, and what it reaches of its captures escapes where it is handed (item 8), also
      where the holder runs it within the call, so no write of their contents in place is
      accepted after; a closure that is a writer or a reader already, and a function value whose
      captures the frame cannot name (`defectUse`), are refused there. The contract says it:
      `Fn.defect` (`defect` in the dump), set on those parameters of those core declarations,
      named directly as `shortCircuits` names `Basics.and` (`defectHookParams`), and on the
      frame's own function parameter that meets a use with it (`flowOwn`), so a helper that hands
      its parameter on has it too; two contracts join it by or. It is the pessimistic side: a sink
      that reads a cell refuses every later write of the cell in place, defect or not (BP's
      `sink` family; the lane's reviewer found a hook that logs and so runs a sink reader at the
      throw) (`cells.mjs`' `defect.*`; `run/CellDefectHookLive`, `run/CellSinkReadsLive`).
      *Added 2026-11-24 (blind round CJ):* the list names no `Js.catchIf` handler or `Js.finally`
      cleanup, though a platform can run user code inside either, after a write in place and before
      its store-back; it needs none: a function handed to JavaScript meets the default use, so a
      closure that writes a captured cell's contents and reaches `Js.catchIf` or `Js.finally` through
      a platform's helper goes where the walk does not follow it, and its write is refused (item 11,
      *any other holder*, `call`), and a cleanup that captured the cell beside a body that writes it
      is a second name of the handle at the one call (item 11, the apart-arguments rule, `disjoint`).
      CJ's probe platform, with a helper over each, found every such writer refused.
      *Amended 2026-11-22 (#2609): what code a defect runs reaches runs there too.* Before, the bit
      stopped at one hop. A helper that wraps its parameter in a closure and hands the closure to a
      hook (`install f = Task.onDefect λ⊤ → f ⊤`) left the parameter without the bit: the closure's
      use of its capture is the closure's own contract, which says nothing of a defect. Its caller
      registered the hook's reader as a reader, and the write in place was accepted. Now a use
      carries the bit to what it reaches (`Use.defect_above`): each function that a function a
      defect can run captured meets its use with the bit (`innerUse`), also where the holder loses
      it (`flowCode`'s default use). So the frame's own parameter gets it (`flowOwn`), and a closure
      it reaches is neither a writer nor a reader (`defectUse`), at any depth. Three other ways reach
      such code without a use of the function:
      (a) A function that hands one of its own function parameters to code a defect runs (its
      contract has `defect` there: `Task.onDefect`, a helper over it, a partial application of
      `Task.bracket`) is judged only where it is called, as one with `flag_p` on a parameter is: as
      a value it is refused (`paramsDefect`). A holder that does not know it (a fold over
      `[ Task.onDefect ]`, a parameter `hr` called as `hr f`, a record's field, an `if` that joins it
      with a lambda, a cell, a list pattern; blind round BT found the last four, with `Log.setSink` in
      a record) would hand it functions that the frame registered as writers or readers. So a function that the walk loses never reaches a hook
      through a callee that the walk does not know.
      (b) Code a defect runs that captured a value whose type can hold a function below it: the
      frame cannot say which of its own function parameters are in there. A field, a list's
      element, a cell's contents, a `Dict`'s value or a type variable can hold one lost into it
      or captured by a closure the frame put there (`b = { h = λ⊤ → f ⊤ }`; the lane's reviewer
      found the second), so each of them that the frame uses gets the bit where the contract is
      built (`defect_data`); an opaque value (`Js.Value`) can hold only one the frame lost
      (`Js.from f`), so each of them that it loses does. Either order of the two. What such a
      capture holds of the frame's closures and cells escapes where it is handed, as before
      (`capHeld`).
      (c) Code that core runs at a stop that a defect causes: `Task.onSchedulerIdle`'s and
      `onSchedulerCount`'s function and `stopScheduler`'s `done`, which run where a fiber ends,
      in the teardown too; `Task.onShutdown`'s function and `shutdown`'s `done`, since code a
      defect runs can call `shutdown`; `Task.chainDefect`'s hook; and `Log.withSink`'s sink, which
      stays in the fiber's slot until the finaliser that `withLogContext` pushed runs, so a cleanup
      pushed inside its body logs to it in the teardown (`defectHookParams`).
      It is the pessimistic side: a helper that uses its function parameter and hands a hook a
      closure over a record of functions marks that parameter even where the record never holds
      it, a function parameter read out of a tuple or a record parameter is refused where it is
      handed to a hook (no root names it), and a hook installer is refused as a value even where
      its holder calls it with a function that is neither a writer nor a reader (`cells.mjs`'
      `reach.*`; `run/CellDefectReach` and its live twin).
      A fiber that is ready at the throw and not masked runs no code of its own in the teardown: the
      drain unwinds it before its next step (`deliverable`), so only its cleanups run, and those
      are hooks above. A fiber that is masked at the throw goes on running its masked code there
      (`halt` latches the interrupt only): (d).
      (d) *Amended 2026-11-23 (#2613): code that runs on after a throw elsewhere.* A page survives a
      defect, and the fiber that threw is the only one cut (`recover` sets its masks to 0). Two
      kinds of other fibers run program code after it. A fiber parked or ready inside a mask
      (`Task.uninterruptible`, `uninterruptibleMask`) goes on to its first suspension point with no
      mask: its timer or its wait wakes it, and `loop` delivers nothing while it is masked. And a
      throw under a scheduler of its own (`Task.withScheduler`) stops that scheduler alone
      (`stopScheduler`): its fibers and the fibers lent to it are cancelled with their children,
      and every other one runs on, a fiber `Task.spawnDetached` or `Task.spawnIn` started outside
      it among them. Either can be the frame's own fiber, or a fiber the frame registered as a
      writer or a reader: the loan rule holds only where a throw in one holder of a cell stops every
      other holder that reads the cell after. Blind round BS proved it on a page with a masked fiber
      and with a write under another scheduler; the lane found the frame itself parked in a mask,
      a caller that masks a function in which a writer fiber runs, and a detached reader of a write
      under another scheduler; the lane's reviewer a root scope listed under another scheduler, a
      reader started by `withScheduler`'s work, and code after `withScheduler` returns (each wholly
      accepted before, TRAP under `--sanitize-lists`). A
      contract says three more facts (`runs-on`, `hosts` and `forks` in the dump):
      - **`Contract.runs_on`**: a run of the body can park its own fiber masked or lent to a
        scheduler of its own. Set where the body calls `Task.uninterruptible`, `uninterruptibleMask`
        or `withScheduler` (named: `runsOnParams`), a callee with the bit, or code the walk does not
        know (a function value of no contract, a method of no contract: it can be one of them), or
        where a call runs within it (`runsWithin`) a function with the bit or one the walk does not
        know. JavaScript (a `foreign` with no words, `jsCode`) parks no fiber in a mask and lends
        none: only the functions it is handed count (`jsArgsRunOn`). A call of the frame's own
        function parameter, or one that runs it within, sets no bit: the caller judges what it hands
        there. `restore` is not named: it brings back the interruptibility of the code that entered
        its mask, so its work is masked only inside another mask, whose call has the bit already. A
        worded row's is false, unlike `switches`: only `core/Task.beni` touches a fiber's masks or
        its scheduler slot, it is walked, and every way in is one of the three or a body that calls
        one; a callee with no contract is code the walk does not know.
        *Amended 2026-11-24 (#2653):* or a body that reaches one through a JavaScript reference,
        which the walk does not follow: `Task.scope`, named (`runsOnBody`). Its close, and the
        scope's finaliser where the fiber running its function is cancelled, run the scope's
        deferred finalisers inside `uninterruptible` (`afterDeferred` applies `deferral`'s `run`,
        `runDeferred`), in the fiber that called `scope`. Before, `scope` had no bit, and a body
        that started a hosting fiber was accepted though the fiber parked masked at the close in a
        finaliser another fiber had deferred (code reader CR7's `deferscope`, TRAP under
        `--sanitize-lists`). A combinator's scope (`within`, `closeHeld`: `par`, `race`,
        `raceAll`, `timeout`, `forEach`, `raceOk`) has no deferred finalisers: `defer` takes a
        `Scope`, and only `scope` and `openRoot` answer one. `closeRoot` runs a root's in a fiber
        of its own (`deferRoots`, `cleanupFiber`), whose finalisers are `defer`'s handlers (row 9).
        It is the pessimistic side: every `Task.scope` is a call that can park the fiber masked,
        also where nothing defers on its scope. The list of every way in, checked against this
        sentence, is *The ways in, from the code*, below the table.
      - **`Fn.runs_on`**: the holder can run the function while its fiber is masked or lent:
        the work of the three, and the frame's own function parameter that meets a use with it
        (`flowOwn`, as `defect` is), so `bracket`'s acquire, `masked f = Task.uninterruptible f`,
        `Semaphore.withPermit` and a platform's handler under `withScheduler` carry it; a use below
        such a holder carries it too (`Use.runs_on_above`, `runsOnAt`).
      - **`Fn.forks`**: the holder only starts the function in a new fiber, which begins unmasked
        in the scheduler of the fiber that starts it, whose stop stops it, and hands it to nothing else:
        `Task.spawn`'s and `spawnDetached`'s work (worded, named: `Check.forksParam`; but on a page a
        masked ancestor keeps it running after a throw: *Descendants of a masked fiber*, #2638), a race's branches
        (`Task.race`'s two and `raceAll`'s first, walked, named: `forksParams`; `begin` runs each as a
        fiber of its own), and the frame's own function parameter whose every use is such a holder.
      - **`Contract.hosts`**: a writer or a reader of a cell the body made runs in another fiber, or
        a callee or a function the body runs within a call has the bit. The writer can throw while
        the body's own fiber is parked; where the fiber is masked, the body's code after the switch
        point runs on and reads the cell the writer left half-written. Where the body runs lent to
        another scheduler, the reader or writer it starts belongs to that scheduler, and the body's
        own throw, which the program's drain takes up to the body's first suspension point, does not
        stop it.
      - **`Fn.starts`** (*added 2026-11-23, #2622*): the holder starts the function in a new root
        fiber, unmasked, and hands it to nothing else: `Task.start`'s work (walked, named:
        `startsParams`). It is no `forks`: `fork` gives that fiber no slots, so it belongs to the
        program's scheduler wherever the caller runs, and a stop of the caller's scheduler does not
        stop it; a writer registered there would outlive a throw of a frame lent to another
        scheduler. Nothing masks or lends it either, so a hosting function may go there (*Up*).
      - **`Fn.kept_out`** (*added 2026-11-23, #2622*): the holder can hold the function past the
        call and run it where no call runs it within and nothing starts it (`startedAt` is false,
        `flowOwn`): the frame's own function parameter that meets such a use. `Io.run`'s `body`
        has none (a closure that `Task.start` starts calls it); a helper that puts a closure over
        its parameter in a list, a cell or an answer has it.
      - **Down.** A writer or a reader is registered only at a holder with `Fn.forks`, with no
        holder above it that the frame does not see run it within (`forkedAt`); at any other holder
        (a list, a record, unknown code, a wrapper a callee answers, `Task.par`, `Task.start`) it is no writer and
        shares what it captured, as before item 12, since a holder the walk does not follow can run
        it masked or under another scheduler. Nor is a function whose contract has `runs_on`, or
        that takes a function parameter (which can have it), one (`registerWriter`). A writer or a
        reader that meets a use with `runsOnAt` later is refused there.
        *Amended 2026-11-23 (#2622): a registration is a fact of its fork, not of the closure.* A
        closure registered at one fork meets every later holder by the same rule: at a holder that
        does not fork it, it is no writer there, so a write of a captured cell's contents is refused
        and a reader shares what it captured (`flowCode`, `captureCells`, `applyAt` ask `forkedAt`
        before `isWriter`). Before, a closure that was a writer or a reader already stayed one at
        every later holder: `Task.spawn rd` and then `stash rd`, a helper that puts `rd` in a list
        that a masked fiber runs, kept `r` unshared, and the frame's write of `r` in place that
        threw left the masked fiber reading it. Whether a holder forks reads the uses above it
        (`forkedAt`, `runsWithin`), and so does the judgment of a use; a judgment that `flow`
        memoises keys those facts (`FlowKey.up_within`: whether a call runs the use above within
        it; `FlowKey.started`, *Up*), so two uses of one holder under two chains that differ in
        them are two judgments.
      - **In the frame.** A call that can park the frame's own fiber masked or under another
        scheduler (`runs_on` above, a call of the frame's own function parameter, or one that runs
        it within) revokes every writer the frame has registered by then, and every reader where
        the call wrote something in place (a demand was made in it): a writer's throw while the
        frame is parked masked leaves its write in place for the frame's code after the call, and
        the frame's own throw under the other scheduler, in a write in place, leaves it for a reader
        outside (`revokeAt`, `Writer.revoked`, refused in `revokeWriters`). Evidence a call is
        handed (a `where` method) counts by its contract, as a callee does (`evidenceAt`).
      - **After such a call** (`runs_on_window`). The fiber does not leave the mask or the other
        scheduler where the call returns: an interrupt latched in a mask is delivered at the next
        suspension point after it, and a fiber that parked inside `withScheduler`'s work resumes on
        that scheduler's drain and goes on there after `putBack` to its next suspension point, where
        a throw stops that scheduler alone. So every later call of the body is such a call too (its
        writers are revoked, and its readers where it writes in place), and a call of a function with
        `hosts` there is refused (`hostsCall`). To the end of the body: the next suspension point is
        not followed. A body that returns there has `runs_on` for its caller.
        *Amended 2026-11-23 (#2622):* the frame's own function parameter that the body calls there,
        or that a call there runs within, runs there too: its draft has `Fn.runs_on` (`callParam`,
        `flowOwn`), so the caller refuses a hosting function and a writer or a reader handed there
        (*Up*, *Down*). Only where a call the body knows opened the window (its callee, or a
        function run within it, has the bit, or is code the walk does not know:
        `runs_on_window_known`); a window that only a call of the frame's own function parameter
        opened is the caller's to judge, and the caller sees the two functions at one call: a call
        that runs within it both a function that can park the fiber masked or lent and a hosting
        function is refused, in either order (`noteRunsOnWithin`, `hostsWithin`), since the callee
        can run the second in the window the first opens. Before, only a known function with
        `hosts` was refused there: a helper `lendThen s g = (Task.withScheduler s λ⊤ → …; g ⊤)`
        handed `detachedThenThrow`, or `twoCalls f g = (f ⊤; g ⊤)` handed a function that lends
        the fiber to `s` and `detachedThenThrow`, ran it on the other scheduler's drain, whose
        throw stopped that scheduler alone while the detached reader read on (TRAP under
        `--sanitize-lists`). It is the pessimistic side: a call that runs within it a hosting
        function and the frame's own function parameter is refused even where the callee runs the
        parameter after the other.
        Two more ways in (the lane's reviewer, each wholly accepted on the base and TRAP): a function
        run within a call that runs what its holder hands it (`List.foldl fs ⊤ λh _ → h ⊤` over a
        list of functions: the holder hands a function in the default state, `defaultParams`) runs
        code the walk does not know there, so the call can park the fiber masked or lend it, as a
        function value of no contract run there can (`flowUnknown`): it revokes the frame's writers
        and readers, opens the window, and a helper over it has `Contract.runs_on`. And a closure
        that runs one of its function parameters or captures after a call of another opened a
        window it could not judge publishes `Fn.after_call` for the second; where a fork or a start
        starts the closure, so no call of the frame runs both within it, the holder refuses a hosting
        second function wherever another one the closure runs can park the fiber masked or lend it
        (one it is handed, the frame's own function parameter, code the walk does not know, a known
        one with `runs_on`; `siblingRunsOn`, in `startedAt`): `Task.spawn λ⊤ → (lend ⊤; h ⊤)`.
        It is the pessimistic side: what a callee hands a function parameter is code the walk does
        not know for the caller, also a closure the callee made, so `ownParam apply` with `ownParam h
        = h λ⊤ → …` opens the window in the caller (`run/CellClosureWritesLive`'s `spawned`, called
        after it in `main`, is refused there); and a fiber that runs a captured function and then a
        captured hosting one is refused wherever the first can lend, also where the fiber runs the
        second first.
        *Amended 2026-11-24 (#2653):* the code did not refuse the second order. A closure that
        runs its captured or handed hosting function first gives it no `after_call`, and
        `startedAt` asked `siblingRunsOn` only for a function with the bit: `Task.spawn λ⊤ → (h ⊤;
        k 1)` with `h` a function that forks `hosting` and `k` one that masks, as two captures, two
        local lambdas or two parameters of a helper `go2 h k`, was wholly accepted, and the fiber
        parked masked while the hosting fiber, its child, outlived the writer's throw (code reader
        CR7's `capfirst`, `capfirstlam`, `capfirstparam`, TRAP under `--sanitize-lists`). Now a
        function the closure runs before a sibling with `after_call` (the call of the first opened
        the window the sibling runs in) is judged by the sibling as well: where that one can park the
        fiber masked or lend it, the first is not started so (`siblingRunsOn` with `after_only`).
        In `go2`, the inner use of `h` is then not started, `h`'s draft gets `kept_out`, and the
        caller refuses `forker` there (*Up*). And a sibling with code can park the fiber masked or
        lend it where its contract has `runs_on`, and also where it runs one of its own function
        parameters or a capture that can (`valRunsOn`, to a depth of 16): the lane's reviewer
        found `k = λn → g n` over the helper's own function parameter `g`, which a call of a
        capture gives no bit, wholly accepted in either order and TRAP (`wrapOwn`). It is the
        pessimistic side: such a helper is refused even where its caller hands `g` a function that
        never masks.
        *Amended 2026-11-24 (#2674): the rule, whatever the way in.* **A hosting function that a
        started closure runs is started so only where nothing else that the closure runs or loses,
        at any depth, can park the fiber masked or lend it: its own body, its captures and
        parameters, and what it hands them to, in any order and through any call.** At each holder
        on the way from the start to the hosting function (`started_above`), the holder's own body
        (its `Contract.runs_on`) and every other function it runs or loses (`siblingRunsOn`, each
        read by `valRunsOn`) are judged, and no order of the two is read. Before, the sibling was
        judged only where the closure's contract said that one of the two ran after a call it could
        not judge (`Fn.after_call`, the #2653 test above), and that fact is of the closure's own
        calls: a callee the closure hands both to runs them in its own order, and its `after_call`
        does not reach the closure's contract (`flowOwn` keeps the callee's order for nobody).
        `Task.spawn λ⊤ → twoCalls h k`, with `twoCalls f g = (f ⊤; g 1)` and `h` a function that
        forks `hosting`, `k` one that masks, was wholly accepted, as were the order of the
        parameters reversed, the call inside a closure the fiber runs, and a helper `go2 h k` that
        starts it (code reader CR8's `twocap`, `twocaprev`, `twocapdeep`, `twocapparam`, TRAP under
        `--sanitize-lists`); and so were three functions handed to one helper, two run in a
        `List.map` and two in the arms of a fold, and the helper of another module (`run/CellStartedPair`
        and its live twin). Each holder is read once for each use below it, and a function value's
        answer is read through every contract it reaches, so a callee, a module boundary or a
        wrapper closure changes nothing. `Fn.after_call` is still published, and no start reads it.
        It is the pessimistic side: a started closure that runs a hosting function and only loses
        another that can mask (to a fork, a list, a cell) is refused, also where nothing runs that
        one in the closure's fiber.
        **A function value that holds no cell is code the walk does not know.** A part of
        top-level data whose layout has no cell (`( masker, 0 )`, `Just masker`, a constructor's
        field) reads as a value of no cell (`v_none`), and `flow`, `valRunsOn` and `jsArgsRunOn`
        took it for no function at all: handed with a function that forks a hosting fiber to one
        call that runs both (`twoCalls forker g`, `g` out of `case cfg of ( g, _ )`), or beside it
        in a started closure, the masker was never seen, and the program was wholly accepted and
        trapped (the lane's adversarial reviewer, nine shapes, the same on the base). Now a
        top-level value whose place can hold a function below it (`Place.holds`: a closure, a type
        variable, an opaque value) and whose layout holds no cell reads as `outside`, no claim, as
        a part of a local construction of a function does: run within a call it notes `runs_on`
        there as a value of no code does (`flowUnknown`, row 6), handed to JavaScript too
        (`jsArgsRunOn`), and as a sibling it can (`valRunsOn`). A value of no cell (`v_none`)
        stays no function: a constructor used as a function is one, and it neither masks nor
        lends. The same reading closed a hole of lists: a top-level value with no parameters whose
        value is a function (`ctor = Pt`, `again = ctor`) read as no value at all, so a helper that
        runs it on a list (`(apply [] k Lib.ctor).a`) answered nothing of the list, and a push of
        `k` after it was accepted, which in place changed the answer read after
        (`run/TopValueFunctionHandedLive`: `1,2 1,2` where the plain build prints `1,2 1`). As
        code of no claim, the helper hands it the list, which escapes (§5 test 3). It is the
        pessimistic side: a top-level tuple of functions that never mask, run within a call
        beside a hosting function, is refused, and a top-level value that holds a function (a
        decoder, `Sub.none`) answers `outside` where a function of it is read.
        *Amended 2026-11-26 (#2696): a call reads the run's contract, never the value's.* A call
        whose callee is a top-level value whose body computes a function (`later = if True then
        masker else noop`, a `case`, a block, a pipe, a call's answer such as `wrap masker` or
        `Maybe.withDefault`, a value of another module) read that value's contract, whose arity
        is 0, as the contract of the run: it has no `runs_on`, no `switches`, no `hosts`, and the
        call set none of them. So `Task.spawn hosting` and then `later ⊤` in one fiber was wholly
        accepted, and so was the call in a tuple, in a `List.map` callback, in a helper (whose
        contract then had no `runs_on` for any caller, of any module), and with a lend for the
        mask (blind round CN's `topValueMask`, `topValueLend`, `topValueHelper`,
        `topValueModule`: DIFF or TRAP under the oracle). Now a call whose callee's contract does
        not take the call's arguments (`own_params` is not the count of the arguments) is a
        call of the callee's value, read as any other function value is (`call`): code the walk
        does not know where the value has no code, so the call can park the fiber masked or
        lent, switch, and keep what it is handed (rows 3 and 8). A value that is a lambda, a
        partial application or an alias was read as the function already. It is the
        pessimistic side: such a call is refused after a start of a hosting fiber, and inside a
        window, also where the value never masks (`run/CellTopValueCall` and its live twin).
      - **Up.** A function whose contract has `hosts` is refused where it meets a use with
        `runsOnAt`, the default, or a holder that loses it and does not fork it: any of them can run
        it masked.
        *Amended 2026-11-23 (#2622):* and wherever no call of the frame runs it within (`runsWithin`
        is null) and nothing starts it in a fiber of its own that nothing masks or lends
        (`startedAt`): a holder that forks it (`forkedAt`) or starts it (`Fn.starts`, the same
        chain condition) starts it so; the default does so only where the holder that lost it
        forks or starts it (`Use.started_above`); a holder that answers it (`flag_a`: a wrapper
        `λx → f x` it answers runs `f` where the frame calls the wrapper, which can be inside a
        mask or under another scheduler) or has `Fn.kept_out` does not; nor does a closure that
        runs it within its own run unless that closure is so started and has no `runs_on` (it
        enters no mask and no other scheduler anywhere in its body: the fiber stays there after
        such a call, up to its next suspension point); any other holder that keeps it (`flag_e`
        with no `kept_out`) lets it go only where it is started. So the rule covers a holder
        below one that loses it, keeps it or is the default. Before, the rule read only the
        holder's own level: `Task.uninterruptible (wrap hosting)` was accepted, since at `wrap`
        the function was kept and its answer reached the mask as a value of no code
        (`flowUnknown`), which says nothing of `hosts`; and a helper that put `λ⊤ → g ⊤` in a list
        a masked fiber ran, or in a cell, published `g` as called and kept, which the caller read
        as run within (each TRAP under `--sanitize-lists`). A hosting function reaches a value of
        no code, data, a call's answer or a cell only through such a holder, so the rule at the
        holder covers them. It is the pessimistic side: `Task.spawn (wrap hosting)` is refused at
        `wrap`, though the wrapper is only forked after.
        *Amended 2026-11-26 (#2695): every function value, the entry's too.* `flowCode` applies
        the rule (`judgeUp`) wherever a known function meets a use, and `entryCall` now hands each
        function of an entry's record to `flowCode` at the default use (§6.13), since the runtime
        runs it on the fiber that calls into it (*The ways in, from the code*, item 12). Before,
        `entryCall` gave it only its captures and parameters, and an `update` that forked a
        hosting fiber was wholly accepted.
      - **Descendants of a masked fiber** (*added 2026-11-23, #2638*). A third kind of fiber runs
        program code after a throw elsewhere, beside a masked fiber and a fiber under another
        scheduler: a fiber that a fork started (`Task.spawn`, `spawnDetached`, a race's branch,
        `timeout`), while an ancestor of it is masked and parked. On a page the defect stop does not
        reach it: its cancellation waits for the masked ancestor (blind round CA: 142 pages, each
        wholly accepted before and TRAP under `--sanitize-lists`; `runtime-proof` with no cells).
        So `Fn.forks`' "whose stop stops it" holds only where no ancestor of the new fiber is masked or
        lent while the fiber lives, and that is decided where the ancestor is at the throw, not where
        the fork is made: `Task.spawn hosting` and then `Task.uninterruptible λ⊤ → Task.sleep …` in
        the same fiber traps too (`maskLater`). The rule (`Contract.hosts_forked`, `hosts-forked` in
        the dump): a hosting function that a holder starts in a fiber of its own (*Up* accepts it
        there, `startedAt`) makes the frame hosting (`noteHostsForked`), so *Up* judges the frame
        where it is handed on (`Task.uninterruptible λ⊤ → Task.join (Task.spawn hosting)` is refused at
        the mask, as `hosting` run within is), and from there to the end of the body every call that
        can park the fiber masked or lent is refused (`noteRunsOn`, `forked_refusal`), whatever
        the callee (*amended 2026-11-24*: the exemption of the runtime's `send` is removed; below).
        The contract says it, and a call of a callee with the
        bit, or one that runs within it a function with it, does the same in the caller
        (`noteHostsForked`): its own later masks are refused, a function that can mask or lend run
        within the same call is refused beside it (`hostsWithin`), and so up the chain of callers. A
        reader or a writer the frame registers needs no more: a mask of the frame's own fiber after
        it revokes it (*In the frame*), and the frame's caller sees the frame's `hosts`. It is the
        pessimistic side: `Task.start`'s root fiber and `spawnDetached`'s fiber have no masked
        ancestor and are judged the same way, a callee that masks before it forks a hosting function
        is refused as one that masks after, and a race or a timeout whose walked body masks is
        refused where it starts a hosting function (`cells.mjs`' `runon.frame.maskChild`,
        `maskLater`, `raceHost`, `timeoutHost`).
        *Amended 2026-11-24 (#2653): no `send` is exempt, and a callee's `hosts` counts.* (1) The
        exemption of "the runtime's `send`" was decided by the type of the parameter or capture
        called (the platform's `sender` alias, `Cmd.Send`), which any function can have: a local
        annotated `msk : Cmd.Send Int` bound to a function that masks, a helper `asSend g = g`, or
        a parameter of that type that the caller hands such a function was called after a hosting
        fork with no refusal (CR7's `sendlocal`, `sendasp`, `sendparam`, TRAP). The frame cannot
        tell the runtime's `send` from another function of the type, so no callee is exempt: the
        call of such a parameter or capture after the start is refused as any other is. Nothing the
        runtime hands is lost by it: the runtime hands its `send` (`Hosted.withSend`'s `λmsg →
        …`) only to a body the platform loses (`host`: `Cmd.perform`, `keyed`, `afterRender`,
        `Sub.listen`), and a body that started a hosting fiber, directly or in a closure it forks
        or starts, hosts (`noteHostsForked`), which *Up* refuses at that loss: a body that forks
        `hosting` and then calls `send Done` was refused at `Cmd.perform` before, and is now. So the
        text and the code now agree: blind round CF found `send Done` after such a fork refused
        with this refusal (`mk.mPlain.live`), where the text excepted it; its parameter was typed
        `Msg → ⊤`, so the type-keyed exemption never applied, and now none does.
        `callParam`'s `sender` is another rule (§6 rule 11: a message is given up, so its cells
        must be the sender's own), stricter, and keeps the word. (2) A callee, or a function run
        within a call, with `hosts` (not `hosts_forked`) started its writers and readers as fibers
        of the frame's own fiber, which outlive the call, as a fork's do: a helper that makes a
        cell, forks a writer and a reader of it and returns, and then a mask in the caller, left
        the reader running after the writer threw (the lane's `p_hosts2mask`, wholly accepted
        before, TRAP). "The frame's caller sees the frame's `hosts`" said only that `hostsCall`
        refuses it inside a window. Now `hostsCall` makes the frame `hosts_forked` too, so a later
        mask or lend is refused (`forked_refusal`) and the caller's caller sees the bit; that
        covers a hosting function run within a call of JavaScript (`jsArgsRunOn`: code reader
        CR7's U1), hosting evidence and a hosting method. It is the pessimistic side: a call of a
        hosting function that joined every fiber it started is judged as one whose fibers run on
        (`run/CellScopeCloseLive`'s `joinedThenMask`: `hosting ⊤` and then a mask), and
        `Task.scope λsc → hosting ⊤` is refused at `scope` (`scopeHost`); `run/CellRunsOn`,
        `CellRunsOnHeld` and `CellParkedOutside`, whose `main` called a hosting shape and then one
        that masks, now run each shape in a fiber of its own (`cells.mjs`'
        `runon.frame.hostThenMask`, `scopeHost`; `run/CellScopeClose`, `browser/inline/CellSendTyped`
        and their live twins).
      - **The ways in** (*added 2026-11-23, #2633*). Each fix of (d) closed the holes at the ways in
        that its readers had found, and the next reader found another way (code reader CR6: `where`
        evidence, and the frame's own function parameter beside a function that lends). So every way
        a function value enters or leaves a frame is listed here against the four rules, each cell
        with the code that answers it and a `cells.mjs` page that proves it (`runon.frame.<shape>`;
        REFUSED where the live twin traps without the rule, SAME where the program is safe). *Down*:
        a writer or a reader is registered only at a fork (`forkedAt`). *Up*: a hosting function
        runs only within a call of the frame or started in a fiber of its own. *In the frame*: a call
        that can park the fiber masked or lent revokes the writers and notes `runs_on`. *After*: the
        window to the end of the body, and what the frame's own function parameter publishes.

        | Way in or out | *Down* | *Up* | *In the frame* | *After* |
        |---|---|---|---|---|
        | 1. The frame's own function parameter, and a closure's capture (a parameter of its contract) | the caller registers, by the facts the draft publishes (`flowOwn`: `lost`, `not_forks`, `defect`) | the caller judges, by `runs_on`, `kept_out`, `after_call` (`flowOwn`, `callParam`); **#2653**, **#2674**: one a started closure runs beside any other function it runs or loses that can mask or lend, in either order and through any call, is not started so (`siblingRunsOn`, `valRunsOn`; `capFirst`, `capFirstLam`, `capFirstParam`, `wrapOwn`, `twoCap`, `twoCapRev`, `twoCapDeep`, `twoCapParam`, `threeCap`, `mapCap`, `foldCap`, `listCap`, `modCap`, `topTup`, `topMaybe`) | a call of it, or one that runs it within, notes `runs_on` with no contract (`call`, `flowOwn`); **#2653**: after a start of a hosting function it is refused, whatever its type (no `send` is exempt: `sendLocal`, `sendAsp`, `sendParam`) | `runs_on` where a known window is open (`callParam`, `flowOwn`), `after_call` where only its own parameter's call opened it; **new**: `runs_on` where one call runs within it the parameter and a function that can park the fiber masked or lent, in either order (`within_known_calls`, `within_own`; `midLend`, `midNest`, `midRunner`) |
        | 2. A function the frame makes or names: a lambda, a partial application (a lambda the parser makes), a reference to a declaration of this or another module, a local function, a join of them | `flowCode`: `forkedAt` before `isWriter`, `registerWriter` | `flowCode`: `hosts` with `runsOnAt`, or no `runsWithin` and no `startedAt` (`partHost`, `partLend`, `partArg`, `aliasHost`) | `flowCode`: run within a call, its `runs_on` and `hosts` count at the call (`noteRunsOnWithin`, `hostsWithin`) | the pair at one call is refused (`within_runs_on_calls`, `within_hosts_calls`) |
        | 3. A call of a declaration, a closure or a reference, of this or another module (`declContract` reads the same `Contract`, every `Fn` fact; **#2696**: a callee whose contract does not take the call's arguments, a top-level value that computes a function, is a call of its value: row 8, `topIf`…`topLend` of `run/CellTopValueCall`) | `applyAt`: a closure the callee loses registers only where it forks | the callee's `hosts`: `hostsCall` (refused in a window) | the callee's `runs_on`: `noteRunsOn`, `revokeAt` | `runs_on_window`, `runs_on_window_known`; **#2653**: after a callee with `hosts`, whose fibers outlive the call, no call that can mask or lend (`hostsCall` sets `hosts_forked`; `hostThenMask`) |
        | 4. A method call (`methodCall`) | none: its target is a declaration or code the compiler derives | a declaration: as 3; derived code: its effect through `termsInfo`, run within (`evidenceAt`, `hostsCall`) | a declaration: as 3; derived code: its `runs_on` (`evidenceAt`); a field, or a target the table does not name: unknown code, `noteRunsOn` | as 3; on the frame's own evidence (`.param`) it is a read, with no fact: the binding judges it (row 5) |
        | 5. `where` evidence, bound at a call or a reference (`evidence`; another module's method by `Mod.edgeEffect`) | none: evidence is a declaration, never a closure of the frame | **new**: hosting evidence is refused at the binding unless the callee is code the compiler derives, which runs it within (`evidenceAt`; `evMask`, `evAfter`, `evLend`, `evTwice`, `evRef`, `evKeep`, `evMod`, `evModKeep`) | `runs_on` evidence: `noteRunsOn` and `revokeAt` at the binding, before the arguments flow (`evidenceAt`) | that window refuses the callee's `hosts` and a hosting argument at the call, and gives the frame's own parameter there `runs_on` (`evWriter`) |
        | 6. Data and constructors (a record, a tuple, a list, a `Maybe`, a `Dict`) and cells (`Ref.make`, `Ref.set`) | `mention`, `flowTop`: no fork, so no writer (`stashRead`, `stashWrite`, `dataRead`, `boxRead`) | the default use: refused (`maybeHost`, `cellHost`) | read back, a value of no code: a call of it `noteRunsOn` (`call`), run within a call `flowUnknown` | as 3 |
        | 7. A call's answer | the holder answers it (`flag_a`, `answersFn`): no fork (`wrapRead`) | `startedAt` is false at `answersFn` (`ansHost`, `ansIf`, `wrapHost*`) | in the caller a value of no code, as 6 | as 3 |
        | 8. Code the walk does not know: a value of no code, a function handed what its holder hands (`defaultParams`), JavaScript (`jsCode`), markup and the runtime | `flowTop`: no fork | the default use: refused (`ownCallHost`, `evArg`); **#2695**: the functions of an entry's record too, which the runtime runs on the fiber that calls into it (`entryCall` hands each to `flowCode`, `Use.entry`; `updStart`, `updMask`, `updLend`, `updChild`, `updPlain`, `updHelper`, `updMod`, `updWhere`, `updMethod`, `viewHost`, `initHost`, and a write of a captured cell's contents: `capUpd`, `capUpdHelper`, `capView`) | `noteRunsOn` (`call`), `noteRunsOnWithin` (`flowUnknown`, `defaultParams`, `jsArgsRunOn`) | as 3 |
        | 9. Core's holders: `spawn`, `spawnDetached`, races (`Fn.forks`), `start` (`Fn.starts`), masks and `withScheduler` (`Fn.runs_on`), hooks (`Fn.defect`), and every other walked parameter (`bracket`, `onExit`, `defer`, `par`, `forEach`, `timeout`, `restore`) | `forkedAt` (`Check.forksParam`, `forksParams`) | `startedAt` (`startsParams`); a walked contract says `lost`, `kept_out` or `runs_on` (`hookBracket`, `hookExit`, `hookDefer`, `hookDefect`, `parHost`, `forEachHost`, `restoreHost`); **new**: a start makes the frame hosting (`noteHostsForked`; `maskChild`, `maskRace`, `maskSpawner`) | `runsOnParams`, and the walked contracts; **#2653**: `Task.scope`, whose close runs the scope's deferred finalisers masked through a JavaScript reference (`runsOnBody`; `deferScope`, `scopeHost`) | **new**: no call that can mask or lend after a start of a hosting function (`hosts_forked`; `maskLater`) |

        The cells marked **new** were the holes (row 9's are *Descendants of a masked fiber*, above). *Row 5, Up*: before, `evidenceAt` only called
        `hostsCall` for hosting evidence, which refuses only in a window already open, and in the
        callee a dispatch site on its evidence parameter is a read, with no fact: no contract said
        what the callee does with its evidence, so `maskRun x = Task.uninterruptible λ⊤ → x.go`,
        `keep x = λ⊤ → x.go` and a helper that hands it on ran a hosting method masked or lent with
        no refusal. Evidence meets the default use: no contract follows it. It is the pessimistic
        side: `callIt H` with `callIt x = x.go` and a hosting `go` is refused, though `callIt` runs it
        within. *Row 1, After*: the frame's own parameter `h` that a callee runs after a function
        that lends the fiber, both handed at one call (`twoCalls (λ⊤ → Task.withScheduler s …) h`),
        published nothing, since the callee cannot judge the pair (its `after_call` on `h`) and the
        frame's caller sees `h` alone. The frame sees both: it notes the pair as it notes a hosting
        function beside one that lends (`within_runs_on_calls`), and gives `h` `runs_on`, also where
        the other function is code the walk does not know, a list of them, or a function the callee
        hands to another (`midRunner`: `defaultParams`). It is the pessimistic side, in either order,
        as the pair is: `twoCalls h (λ⊤ → Task.withScheduler s …)` marks `h` too.
      - **The ways in, from the code** (*added 2026-11-24, #2653*). The table lists the ways a
        function value enters a frame; this list is every place in `core/` and the platforms'
        runtimes where the runtime parks the calling fiber masked or lends it, or runs a function
        it holds, each with the row that answers it. It was made from the code, by kind:
        `uninterruptible`, `uninterruptibleMask`, `restore`, every write of a fiber's `masks` or
        its scheduler slot, every `withScheduler`, `spawnIn` and scheduler hook, every `Js.apply`
        of a function the runtime stored, every finaliser list, every hook registry and every user
        of `within`. A site the walk does not see from the calling frame is marked **unseen**.
        1. *Masks a call enters*: `uninterruptible` (`mask`, `unmask`), `uninterruptibleMask`
           (`endMask`), `withScheduler` (`lend`, `putBack`, `unlend`): `runsOnParams`, row 9. Core's
           walked callers: `defer` on a closed scope, `bracket`'s acquire and release, `onExit`'s
           handler, `Semaphore.withPermits` and `tryWithPermits` (`uninterruptibleMask`, `restore`); the platforms'
           `cloudflare` `Worker.serve` and `Worker/Object.begin` (`withScheduler`), `browser`
           `Worker.cancel` and `close`: each a walked body that calls one, so its contract has
           `runs_on` (row 3), and its function parameters `Fn.runs_on` (row 1).
        2. *Masks lowered or reset*: `restore` and `remask` (to the depth of the mask they came
           from, never deeper: no row), `recover`, `failed`, `failedS` and `teardown` (to 0, for a
           fiber the defect stops: no mask). No other code writes `masks`.
        3. *Scheduler slots*: `withScheduler` lends the calling fiber (item 1); `fork` and `begin`
           copy the parent's slots into a new fiber, which belongs to the scheduler the parent runs
           under (`Fn.forks`, `Fn.starts`, row 9); `cleanupFiber` sets the scheduler of a new fiber
           of its own; `withSlotsOf` clears it for the teardown's fiber; `withClock`,
           `withLogContext`, `inLogContext` (with `putSlots`), `beginUpdate` and `restoreSlots`
           copy the slots with one other field and put the old ones back: none lends the caller.
        4. **unseen** *A mask reached through JavaScript*: `afterDeferred` applies `deferral`'s
           `run`, `runDeferred`, which runs a scope's deferred finalisers inside `uninterruptible`
           in the calling fiber. Its callers: `closeScope` from `scope` (the close) and from
           `closeHeld` (`within`), and `shutWith` from `shutAll` (the scope's finaliser, run where
           the fiber in the scope's function is cancelled) and from `deferRoots`. The hole of
           #2653: now `scope` has `Contract.runs_on` by name (`runsOnBody`, row 9). `within`'s
           scope has no deferred finalisers (`defer` takes a `Scope`; `scope` and `openRoot` alone
           answer one), and `deferRoots` runs a root's in a new fiber (`cleanupFiber`), whose
           finalisers are `defer`'s handlers (row 9, `Fn.defect`). `closeRoot`'s and the
           teardown's `deferral` `roots` call is that path.
        5. *The run loop*: `loop` applies a fiber's continuations, and `resume`, `join`'s
           `outcomeOf` and `joined`, `firstOf`, `waitAll`, `countDown`'s wake, `wakeDue`,
           `realSleep`'s timer, `runSoon`'s work, `callAs` and `begin` the code of a fiber the walk
           walked after a switch point, or a fiber's start: switch points (item 12, *A switch
           point*) and row 9 (`Fn.forks`, `Fn.starts`). Another fiber that runs in a call cannot
           mask or lend the calling one.
        6. *Host scheduling*: `macrotask` (`immediate`, `portTasks`), `schedule` and `fromHost`
           (`queueMicrotask`), `arm`, `armS` and `realSleep` (`setTimeout`), a scheduler's `run`,
           `more` and `requeue`, `drainFromS`, `Browser.Events`' frames
           (`requestAnimationFrame`): drains outside any fiber, or switch points: no row.
        7. *Hooks the runtime runs*: `drain`'s `turn` (`onTurn`), `guard`'s and `failed`'s
           `defect` (`onDefect`, `chainDefect`), `failedS`'s scheduler hook (`scheduler`,
           `schedulerWith`), `countDown`'s idle and count hooks and a scheduler's `ended`
           (`onSchedulerIdle`, `onSchedulerCount`, `stopScheduler`'s `done`), `allEnded`'s and
           `allEndedS`' `told` (`shutdown`'s `done`), `onShutdown`'s function, `releaseAll`'s
           releases, `complete`'s observers (walked lambdas of `join`), a wait's canceller
           (`callback`'s `register` answers it, lost to JavaScript), `Log.emit`'s sink
           (`setSink`, `withSink`; `sync`, so it parks no fiber): `Fn.defect` (row 9, *A defect*
           (c)), or the default (row 8). The platforms' `Inline.taskScope` (`onTurn`,
           `onDefect`) and `Hosted.hear` (`onShutdown`) install hooks of their own.
        8. *Finaliser lists*: a fiber's `finalizers` (`pushFinalizer`: `bracket`'s release,
           `onExit`'s handler, the slot restores of item 3, `withScheduler`'s `unlend`,
           `openScope`'s `shutAll`), applied by `cleanups` and `withSlotsOf` in an unwinding fiber
           after `stopChildren`, or by the teardown's fiber; a scope's `deferred` (`defer`),
           applied by `runEach` under `runDeferred`'s mask (item 4): `hookBracket`, `hookExit`,
           `hookDefer` (row 9).
        9. *Functions the platforms hand to JavaScript*: `Hosted.job`, `later`, `tap`, `hook`
           (`host (withSend body _)`), `mapJob`, `mapLater`, `mapTap`, `runJob`, `callJob`,
           `afterRender`, `through`, `run`, `hear`; `Listen.callback`, `open`, `close`, `take`;
           `Browser.mountAt`; `Inline`'s `send`, `applyFrom`, `own`, `stop`, `callNoted`, `pass`,
           `loadRows`, `loadShapedRows`; `cloudflare`'s task arrays, resolvers and timers;
           `node`'s `Io.run` (`Task.start`, row 9), `WebSocket`, `ChildProcess` (`bracket`, item
           1), `Rt.rows`: the function is lost (rows 6 and 8: the default), so no writer, no
           reader and no hosting function arrives there. The runtime's `send` (`withSend`'s
           `λmsg → …`) runs `update`; it is no exemption (*Descendants of a masked fiber*,
           amended 2026-11-24), and what `update` does there is item 12.
           *Corrected 2026-11-26 (#2695):* this item said that `update` "is `sync`: it parks no
           fiber". That is true and not enough. A `sync` function can start a fiber
           (`Task.spawn` does not park), and `send` can be called from a fiber the program masks or
           lends, so a hosting fiber that `update` starts can have a masked ancestor (item 12).
        10. *Fibers the platforms start*: `spawnIn` in `Inline.commands` and `startWork`, in
           `node` `Http.Server.loop` and in `browser` `Worker` (its work is no writer or reader,
           *Down*); `spawnDetached` under `withScheduler` in `cloudflare` (`Fn.runs_on`, row 9);
           `spawn` in `Http.Server.open` (`Fn.forks`).
        11. *`within`'s users*: `par`, `par3`, `parOk`, `forEach`, `forEachOk`, `raceAll` (and
           `race` over it), `raceOk` and `timeout` close their scope through `closeHeld`: item 4,
           no deferred finalisers.
           What runs their branches is `begin`, `startIn` and `callAs` (row 9, `forksParams`,
           and the walked contracts).
        12. *Program functions the runtime runs on the calling fiber* (*added 2026-11-26, #2695*).
           The runtime runs some program functions in the same JavaScript call as the program
           code that called into it, at once or queued behind the dispatch in progress and
           applied before it ends. So they run in whatever state the program left its fibers
           in: inside a fiber that the program masks (`Task.uninterruptible`), lends
           (`withScheduler`), or started under a masked one, or while such a fiber is parked. A
           function of that kind that starts a hosting fiber starts it where a masked ancestor can
           keep the fiber running after a throw (*Descendants of a masked fiber*). The sites:
           - `Inline.send` (the runtime's `send`, from `Hosted.withSend`, `Cmd.Now`'s `callJob`,
             `eventEntry`, `run`) applies the program's dispatch: `update`, the render after it,
             which runs `view`, the helpers of `view`'s holes and the row and key functions of
             its `For` and `Show` forms (`formCalls`, `runtimeCall`), and `onUrlRequest` and
             `onUrlChange`. `run` applies the mount: `init`, the first render, `subscriptions`.
             These are the functions of the entry's record. `entryCall` hands each one to
             `flowCode` at the default use (`Use.entry`, §6.13), as every other function value the
             walk loses meets it: a function whose contract has `hosts` is refused there
             (`judgeUp`, *Up*), and so is one that writes the contents of a cell it captured
             (`writesCapturedBut`). A helper of a hole is a call in `view`'s frame, so its
             `hosts` is `view`'s (`hostsCall`), and the default refuses `view`. A row or key
             function of a `For` or a `Show` is a value of the markup's own: it meets the default
             use where the markup is evaluated, and a hosting one is refused there (as before this
             item). Before, the entry's functions got only `flowCaptures` and `defaultParams`,
             and no rule read their `hosts` or their writes of captured cells: an `update` that
             forked a hosting fiber, run by a `send` inside `Task.uninterruptible` in a fiber
             that `Task.start` started, was wholly accepted, and the hosting fiber read the cell
             its child's throw left half-written (code reader CR9's `e_updstart`, TRAP under
             `--sanitize-lists`); and an `update` that wrote in place a list in a cell `main`
             made, which a command had read before it sent the message, changed what the command
             logged after (the lane's reviewer's `capw`, `cells.mjs`' `capUpd`, `capUpdHelper`,
             `capView`). A record handed by name (`Tea.element app`, `app` top-level data) was
             refused before: a function in top-level data meets the default use where the record
             is made (row 6).
           - An event's handler and its `via` reader (`Inline.on`, `send f event read`): a
             value at a markup item that the runtime keeps (`keptItems`), lost to the default
             (row 8). A DOM event can be dispatched inside a call the program makes.
           - A `Log` sink (`Log.emit` runs it in the calling fiber), a hook, a finaliser, a
             `Sub`'s or a `Cmd`'s function, a `map`'s function: each reaches the runtime through
             a call, at a holder whose contract the walk reads (items 7 to 9, rows 8 and 9).
           The pessimistic side: an `init` or a `view` that starts a hosting fiber is refused,
           also where the runtime runs it at the mount, in no fiber; an `init` that hands a
           hosting function to `Task.start` is refused (a start makes the frame hosting,
           *Descendants of a masked fiber*), also where the root fiber has no masked ancestor;
           and an `update` that starts one is refused, also where no `send` is ever made from a
           masked or lent fiber.
        `browser-tea` and the `dom` lowering are out of this list's scope; `browser`'s `Worker`
        is listed where it calls `Task`.
      No function is refused as a value for having `Fn.runs_on` on a parameter (unlike (a)): a
      writer or a hosting function never reaches a holder the walk does not follow (but the start of
      a fiber of its own, *Down* and *Up*, as amended for #2622), so a mask that
      code the walk does not know runs reaches none of them, and the call of that code revokes the
      frame's own writers. It is the pessimistic side: a writer or a reader that calls `Task.bracket`,
      `onExit`, `Semaphore.withPermit`, `Random.step` or `Url.Parser.parse` (whose generators
      and parsers are functions in data, code the walk does not know) is none; a fiber that writes
      the cell inside a mask is refused even where it is the cell's one writer (`cells.mjs`'
      `runon.maskWrite.*.dead`); a frame that registered a writer and then calls such a function or
      its own function parameter is refused, and so is one that calls a hosting function after such a
      call; a hosting function handed to `Cmd.perform`, kept in a list or answered by a wrapper is
      refused, also where the wrapper is only forked after, and a function
      that starts a reader is one; `Task.spawnIn`'s work is no writer or reader, since its scope can be
      a root that the first fiber started in it listed under another scheduler (the lane's
      reviewer); and a frame's write in place inside `withScheduler`'s work while a reader
      is registered is refused even where every reader is a child that the stop cancels
      (`cells.mjs`' `runon.*`; `run/CellRunsOn` and its live twin).
    `run/CellFibersInPlace` and its live twin `run/CellFibersInPlaceLive`.

13. **A callee's paths** (`Contract.paths`, `Frame.publishPaths`, `tagPaths`, `pairLive`). *Added
    2026-11-22 (blind round BN's undo app).* A run of a body whose answer is a `case` (its outermost
    `case` in tail position, in no arm of another: `path_ctxs`) goes through one arm of it, its
    **path**. The union of item 3 and the flags of §4 name what every path does at once, and a caller
    read the writes of one path and the renewal of another as one run: after `apply r Undo`, whose
    `Add` arm writes `present` and whose `Undo` arm moves the old `present` to `future`, a read of
    `future` read the written `present` (`later-use`). So a walked body that renews a cell (item 3)
    and has two paths or more publishes, for each path:
    - **its writes**: each parameter location that a demand marks (§5) whose context can be on a
      run through the arm (`ctxOnPath`: the arm, an arm inside it, an arm of another `case`, or none),
      followed through the runs as `markAtoms` follows them (`pathMark`); a demand in no arm of the
      `case` is in every path;
    - **its renewal** (item 3), from each return point whose context can be on a run through the
      arm, each join read with only its values whose arm can be on it (`restrictPath`). A path whose
      values are the parameter itself renews nothing, and its caller reads the cells there as it reads
      the union's own cells: a written location's as a new name (`oldNames`, in `renewHandle`; read
      as the cells they were, a write before the call was judged against them, and BN's undo programs
      with loans were refused).

    Every other fact (what the body reads, lets escape, answers, marks, hands its function
    parameters, the claim of item 5, and the union itself) is the one contract. Where no path says
    less than the union, none is published. A location that the union writes and no path does (a
    flag a check set after the walk) is written in every path (`pathWrites`).

    A caller that applies the contract to its arguments (`applyAt`; not a contract of words) reads
    the call as a `case` of its own whose arms are the paths, made once at the call (`path_case`,
    a `case` of no instruction). A location that some paths write and others do not is one demand,
    judged on runs through the paths that write it (`Demand.paths`, `judge_set`: `atomLive` and
    `armLive` read a context as live where one of them can be on a run with it). The call makes one
    version (item 5), as before, with the union's claim; each location holds, from each path, its
    renewal there, or its old contents where the path renews it not, and a cell that one path alone
    puts there holds the path's arm as its context (`tagPaths`): it is in the location on a run
    through that path only. A cell that two paths put there, and that has no path's context yet, is
    kept once for each of them with that path's arm; one that more paths put there, or that has a
    path's context already, keeps the context it had (one context names no set of arms: the
    pessimistic side) and is kept once, since copies for more paths, or at every call, multiply the
    cells of a chain of calls past the budget (§8; BN's undo app, twelve calls of six paths). A cell found through the
    paths of several calls keeps every arm (`meetPath`, a meeting that names them all, up to
    `path_chain_max`, past which the newest is dropped: the pessimistic side), since a run through
    two calls' paths is told from another by any of them; `meet` keeps two, and a chain of five calls
    read the second's arm as dropped. A context has two parts (`splitCtx`): the chain of calls'
    paths and the other arms; an arm of a `case` meets the second part only (`meetArms`, `meet`'s two),
    and the chain the first (`joinParts`), so the arms of the frame's own `case`s are kept as they
    were before calls had paths: in `meet`'s two places, a path's arm pushed out the arm of an `if`
    that told a write in one of its arms from a read through the other. An arm around a path of the
    chain (the call is in that arm) adds nothing (`chainInside`), as `meet` keeps the inner of two
    nested arms. The later-read test (§5 test 4) compares a holder's cell with a written
    cell only where the two can be on one run (`pairLive`, `ctxPair`: no two arms of one `case`): a
    cell that a later read finds only through one path and that the write finds only through another
    is not read after the write on any run. That holds of every context an atom has, the arms of the
    frame's own `case`s too (§6 rule 7): before, only the holder's context was tested, against the
    write's. A cell's own name in a version (an entry's own atom) has no context, so it is a holder
    on every run. The paths are the callee's runs, whatever the caller
    holds: no claim of the caller's is read for them. A function that a callee runs within its call,
    a writer's run (item 12), a call in a hole of markup and a contract of words read the union, as
    before. A contract read from another module keeps its paths (`dupContract`). Two contracts of a
    round join path by path, and a contract with none is read as each path being its union; two with
    other numbers of paths join to none. A path that leaves a location what an earlier path leaves
    there copies its cells, not their sources again, and a write judged on some paths of one call
    climbs the contexts once (`judgeCompat`): the paths of a call are arms of one `case`. Each path
    read at each location, each cell placed in a path, and each demand and return point a callee
    places in a path is work (§8). The paths cost work where they accept: a write judged on fewer
    runs is compared with more holders before it is accepted, so BN's undo app with thirteen calls in
    one function (`dup3`, a copy of `apply`'s call), which the base accepts near its budget, now
    passes it (`limit`).
    What it does not cover: a callee's paths are the arms of its own answering `case`, not those of a
    function it hands a cell's row (the `Just` and `Nothing` arms of the callback in `Ref.update r λh
    → case …`), nor those of a callee it calls in an arm; such a callee's renewal is one union in each
    path, so BN's undo app with `Undo` and `Redo` callbacks that keep `h` on `Nothing` is still
    refused (`later-use`). And a `case` in the caller whose arms make versions of one cell joins them,
    and a later call is refused `disjoint` where one arm moved a cell another arm left in place.
    `run/CellCalleePaths` and its live twin `run/CellCalleePathsLive`.

What it does not cover yet, each a refusal: a reader that the frame joins before the contents leave it
(`n = Task.join a; ( Ref.get r, n )`): what it read at the return point escapes, although it no longer
reads (`cells.mjs`' `reader.joined`); a writer of a cell the frame did not make (a parameter's, a
capture's: a closure spawned inside `Task.scope`'s body, `cells.mjs`' `param` and `scoped` shapes); a
writer whose closure goes to `Task.par` or `race`, whose contract's answer names the closures' cells, so
the handle escapes with what the answer can hold; a writer or a reader at any holder that does not start it in a new fiber (a
list, unknown code, a wrapper a callee answers, `Task.spawnIn`: item 12, *A defect*, (d)); a closure that only stores into the cell; a closure that writes the contents of a cell it captured
and goes where the walk does not follow it and is no writer (items 11 and 12; `browser/tea/BallMachine`,
where the closures go to the runtime); a handle handed to the frame's own function
parameter, which shares it (`run/SanitiserCellLoanKeptApart`'s `handed` and `modified`); and a handle at a
part of a root (a record's field, a tuple's part), which is no tracked root whole and is shared at its
first renewal.
