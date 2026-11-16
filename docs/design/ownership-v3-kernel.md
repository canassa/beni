# The ownership checker v3: the soundness kernel

*Normative for `src/own3/`, 2026-11-12; §6.4, §6.8, §6.11 to §6.13 and §8 revised 2026-11-13 (research
report 120); §6.12 and §6.13 revised again the same day (research report 123); §4.1, §6.2, §6.8 and
§6.13 revised again the same day (research report 125); §6.8, §6.9 and §8 revised again the same day
(research report 127); §5, §6.9, §6.11, §8 and §9 revised and §6.14 added the same day (research report
129); §8 revised 2026-11-14 (research report 130); §6.14 and §8 revised again the same day (research
report 131); §5, §5.3, §6.12, §6.14, §8 and §9 revised again the same day (research report 134); §6 rule 9 and §8
revised 2026-11-15 (research report 141). §0 revised and §11 added the same day (research report 142); §5, §6 rule 2 and
§11 revised again the same day (research report 144); §4.4, §6 rule 13 and §8 revised again the same day
(research report 143). §3.4 added, §6 rule 10, §8 and §9 revised 2026-11-16 (research report 146); §3.4, §6 rules 4 to 6, §9 and §11 revised again the same day (research report 147); §3.4, §4.1, §5, §6 rules 10 and 12, §9 and §11 revised again the same day (research report 148); §3.4, §6 rule 10 and §9 revised again the same day (research report 150). The owner
ordered it after research report 116: "Write the rules
and do a principled fix on the core. The core must have soundness." Report 110 §6 is the design this
kernel keeps; reports 111 to 115 are its history; report 117 measures this text's implementation. The
section numbers here are referenced from the code (`kernel §N`): never renumber them (`CLAUDE.md` rule 2).*

---

## 0. Scope

A beni `List` is a plain array. The checker accepts an in-place write only when no later read can observe
the old value. It judges lists and, since 2026-11-15, records (§11); cells and fibers are later stages of the same
rules (report 116 §5.4). It runs behind `--ownership=v3`. v1 (`src/own/`) is the production checker and is not touched.

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
completes so that every line is made, every demand of the frame is refused (`finishDemands`), and the
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
the function made that no other location of its result holds. **A location placed
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
JavaScript arrays and objects and reads them back so, and the flag made every list function cast.

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
take: where the body cast, the part is not where the types say. *What this does not cover* (research report 150 §11): a
path that no place step names (a deep level of a cycle, a row, the inside of a `Dict`), an argument of
the caller's own type variable or a function value, and a `Js.Value` inside a container cast at a type
variable in a frame whose own result is that variable (`λ⊤ → fromMaybeV (Just v)`).

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

### 4.2 A fresh cell has a name

A cell a body makes is `Src.fresh(k, escaped)` in its contract: `k` is its **allocation site**, `escaped`
says the body let it escape. Two sources with one `k` may be one cell. In the caller, the sources `fresh(k)`
of one callee read at one holder are **one root** of kind `fresh` (`freshAtom`, keyed by the holder's
`Use.key`, the contract and `k`), so a cell at two result entries overlaps with itself, a cell handed to a
function parameter and answered is the cell in the result, and a cell the callee let escape is noted as
escaped at the call. A `fresh` root has no value and no layout: it exists as atoms.

The site `k` is canonical, so the rounds of a recursive group settle (`freshId`, `Mod.siteId`): a cell the
frame made is named by the instruction that made it and the entry; a cell a callee made is named by the
call and the callee's site; a cell of a callee whose contract is a **draft** (a member of the group in its
rounds, a local function in `solveCodes`' rounds: `Mod.drafts`) is named by the call alone, which bounds
the names of a recursion by its call sites. A local function's contract from an earlier walk of its
declaration (a round of the declaration's group) starts the next walk's rounds, and is a draft while they
run too: read as a finished contract, the cells of its own recursive call had new names in each walk, and
the group never settled (`TailModConsBranches.chunks`, 66 walks; research report 138). Collapsing two cells into one name is on the pessimistic side.

A worded row's new cells are one site, `0` (`Check.wordedContract`).

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

## 5. The write rule

A write of the atoms W at time t is accepted when (`demand`, `finishDemands`):

1. **permission**: no atom of W has root `outside`, `capture` or `answer` (a function parameter's answer is
   never the frame's own), and W is not a `twice` summary location written by a callee;
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
   A list pattern reads its list (`readsList`); a pattern a row does not describe binds `unknown` over the
   scrutinee. *Invariant: the bound value's leaves are the scrutinee's part's leaves.*
2. **Call** (`call`, `apply`): the callee's contract says, per parameter location, read, answered, written, escaped,
   handed to a function; each escaped location escapes and each function handed flows (`flow`, which can
   escape a function's answer) **before** each written location is a demand at the call with the other
   arguments as operands, so a write is judged against every escape of the call; the result's entries are the contract's sources expanded to
   atoms (`expandSrcs`: a parameter source to the argument's leaves, `fresh` to a `fresh` root, `outside`
   to `outside_atom`, an answer to what the function there answers). A callee with no contract is unknown
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
3. **Capture** (`capture`, `codeValue`, `solveCodes`): a lambda or a local function is walked in its own
   frame, its captures are parameters of its contract, and the closure value holds them (`closureOf`). A
   capture bound after the closure is made is a `later` slot read as the value bound there (`capVal`;
   lowering guarantees it is bound before any run). Local functions that name each other in a cycle are
   one group walked to a fixed point (`findGroups`). *Invariant: a closure's leaves are its captures'.*
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
   the scrutinee; the failure answers the scrutinee (a read). *Research report 147: the alias's pattern
   projected by a constructor's step, which a record does not have, so it bound nothing and its contract
   read no slot.*
7. **`if` and `case`** (`caseOf`, `joinVal`): the value is a `join` of the arms, each with its context; two
   arms of one `case` are never one run (`compatible`), so a holder in another arm is no holder.
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
    parameter, not `free`. The word `fresh` names one site for each location of the result (a builder's
    storage and its elements are two cells); `copyof` and its kin name one site, the new list. A `foreign`
    with no word has no contract: unknown code. *The missing fact is the pessimistic one.* A word that
    puts a parameter's location in the result (`returned`, `stored`, `elementof`, `taken`,
    `builderdone`, the elements of `copyof`) puts it at the result's location of the same place and,
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
    another type (`returned a → b`) casts (`Contract.casts`, `Check.castsAt`, §3.4). The JavaScript value is what the word says it is, and a cast reads it back; "at
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

    The words are shared: a signature with a word that only v2 and v3 read is kept in a column of its
    own, which v2 and v3 read and v1 does not; any other signature is in v1's column, which all three
    read (`Lower.recordOwnWords`, `Bir.ownSlotsV2`). So a row is written only where its words are true
    and **v1 and v2 read them as before**: v1 is frozen, and v2 judges the same programs in the gates. A true row that fails this is
    not written, and the function stays walked or unknown code — the pessimistic side. `Dict.focus` is
    one (report 117 §10): `taken` names an element of a list, and v2's reader of rows knows no other
    value to take, so a row there changes v2's verdicts.

    A row of JavaScript is true only of what the operation can run. A property read (`Js.get`) runs a
    getter or a proxy's trap with the object as receiver, and turns an object name into a key with its
    `toString`; a comparison (`Js.lt`, `gt`, `le`, `ge`) runs an object operand's `valueOf`. Each can
    keep what it is handed, so each operand has no word and escapes: `Js.get` is unknown code, and the
    comparisons are `a, a → fresh bool`. `unused` is true only of an operation that coerces nothing
    and whose answer no write in place changes (`isNull`, `typeIs`, `fingerprint`). `Js.same` coerces
    nothing but is `borrowed a, borrowed a → fresh bool`: an in-place write keeps its base's object, so
    a value kept from before the write is `===` to the written list, which it is not where the write
    copies. An identity compare reads its operands (research report 140).
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
    that handed the evidence was judged; anything else is unknown code. The functions that derived code
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
    parameter is refused where it is handed, and so is one with no contract. The runtime's `send` is
    the alias with the word `sender` (`platforms/browser/Browser.beni`), followed through aliases of it;
    a message sent is given up, so each cell of it is a demand (`callParam`). No declaration is read by
    its name, and no method is read as read-only because it is derived. *Report 118 §4.6: the text said
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
    runs `update` again (rule 12, `boundary.md` §9.4.8). **The message is never `own`**: a handler of
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
    The record's functions escape; the program's value is `unknown` over the record.

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
worded declaration's body is walked for its own lines only, after every contract is known; its contract is
its words whatever the walk found. A module whose walk reached a limit, or that is not an application
module, authorises no in-place write (`Enforce.checkModule`, `Hoists.finish`).

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
  for its `via_path`; when that fails, the atom is compared with each atom of its part. The largest run
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
and the contracts of its imports only). **A unit tracks time** (research report 135): over the 101
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
| two contracts of one arity that a round joins have one set of layouts, or the first has no fact: a join of two others would drop facts the rounds need. A contract of another arity (a local function whose walk found a capture an earlier walk did not) is replaced, and the rounds walk again at the new one | `Contract.join` | §6.9 |

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
   A part of a root reaches only the slots below it (`rootReach`).
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
