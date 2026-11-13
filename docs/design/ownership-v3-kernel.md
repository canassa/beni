# The ownership checker v3: the soundness kernel

*Normative for `src/own3/`, 2026-11-12; §6.4, §6.8, §6.11 to §6.13 and §8 revised 2026-11-13 (research
report 120); §6.12 and §6.13 revised again the same day (research report 123); §4.1, §6.2, §6.8 and
§6.13 revised again the same day (research report 125). The owner ordered it after research report 116: "Write the rules
and do a principled fix on the core. The core must have soundness." Report 110 §6 is the design this
kernel keeps; reports 111 to 115 are its history; report 117 measures this text's implementation. The
section numbers here are referenced from the code (`kernel §N`): never renumber them (`CLAUDE.md` rule 2).*

---

## 0. Scope

A beni `List` is a plain array. The checker accepts an in-place write only when no later read can observe
the old value. It judges lists only; records, cells and fibers are later stages of the same rules (report
116 §5.4). It runs behind `--ownership=v3`. v1 (`src/own/`) is the production checker and is not touched.

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

Every `switch` over `Tag`, `RootKind`, `EKind`, `Src.Kind`, `Use.kind` and `Bir.Inst.Tag` in `src/own3/`
has no `else`: a new kind compiles only once each reader has a case.

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

The map itself pairs a location of a deep level by its label path only where the caller's cycle is the
signature's. A type argument can name the container again (`Tree2 T`, where `T` holds a
`List (Tree2 T)`): the caller's cycle then passes through a place where the signature has a wide entry,
and the caller's deep location holds cells that the signature names at two entries, its own deep
location and that wide one. No entry covers it, so the map answers `Loc.all` (`Loc.cycleWider`: the
caller's place at a wide entry's path inside the cycle is in the caller's cycle). The same holds for a
caller location below a wide entry of the signature's deep level, and a step of that path that the
caller's place graph cannot follow (a row's) counts as one the cycle passes.

*Research report 124 F1: the entry compared a
model location with a contract's location by label prefix, so a function over `{ r | n : Int }` held
nothing of the model; report 125 found the same in the composition of answers and of supplies
(`answersAt`, `slotsOf`, and the label tests `Loc.noObject` and `Loc.belowWide`, now deleted) and in a
constructor's row (`ctorValue`); its review found the call map pairing two deep levels of different
cycles (`Loc.cover`).*

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
the names of a recursion by its call sites. Collapsing two cells into one name is on the pessimistic side.

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
cell an earlier part holds (`dupOverlap`). Two overlapping atoms are two cells only when they were read
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
does not hold every summary entry fed by two sources or by an answer is `twice`, and the result is not
linear), and never for an entry that holds the **answer of a function parameter**, which the callee's frame
saw as an opaque root: a pair of entries with one is tested by the caller's atoms (`apply`,
`deriveLinear`'s `answers`). Within one summary entry, two sources are tested as atoms, with one named
exception (`alternatives`): the answer of a function `g` and a parameter location the callee hands `g`
`free` are alternatives, because a cell handed `free` is read by the callee no more, so it is in the answer
or it stays, never both (the `taken` rows of `core/`).

## 5. The write rule

A write of the atoms W at time t is accepted when (`demand`, `finishDemands`):

1. **permission**: no atom of W has root `outside`, `capture` or `answer` (a function parameter's answer is
   never the frame's own), and W is not a `twice` summary location written by a callee;
2. **no other operand**: no other operand that the operation reads reaches W (`otherReaches`). Another
   location of the written operand itself, when the operand is a part of one root N, is another place of N:
   its cells are apart from W when N holds each cell once — a parameter by the apart-arguments rule, a root
   the frame made by its own `linear`, never the answer of a function parameter;
3. **no escape**: no escape whose context is compatible with the write's overlaps W. An escape owns a copy
   of its atoms (`esc_atoms`), and where the answer of a function parameter escapes, so does what the
   function was handed (`Answer.base`, in `noteEscape`): the answer can hold it;
4. **no later read**: no read at a time after t, in a compatible context, reaches W (`useReaches`).

**Theorem.** If the four tests pass, no live reference reads the old value, and the in-place program prints
what the copying program prints. Argument: every cell the frame can observe is an atom of some root (§2);
every consumer records a read of every atom it can observe (`readAll`, `readBy`, a list pattern, the
frame's result); every holder the walk does not follow records an escape of every atom it can hold (§3.2,
§6.10), and so does the default that a holder hands a function's function parameters (§6.2); a
write by a callee is a demand at the call (§6.2); and a call that the runtime makes into the
program's code is a call too, applied where the program hands the runtime what it calls the code with (the
rows of markup, §6.12; the record of an entry, §6.13). So an observation of W after t is a read after
t, an escape, or another operand — each refused.

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

## 6. The rules, one for each construct

Each rule keeps the invariants of §2. The argument is one sentence each.

1. **Bind** (`binding`, `bindPattern`): a binding makes another holder of the same value and reads nothing.
   A list pattern reads its list (`readsList`); a pattern a row does not describe binds `unknown` over the
   scrutinee. *Invariant: the bound value's leaves are the scrutinee's part's leaves.*
2. **Call** (`call`, `apply`): the callee's contract says, per parameter location, read, written, escaped,
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
   a subscription's body lost what it captured). *Invariant: a part the construction does not name holds
   none, and a construction that cannot name its parts is `unknown`.*
5. **Project** (`project`): a step on a root extends its path; on a construction takes the named part or
   `none`; on `unknown` stays `unknown`; on a closure is `unknown` over it. *Invariant: a part's leaves are
   a subset of the whole's.*
6. **Pattern and `?`** (`bindPattern`, `evalInner .try`): a constructor pattern projects by the row of its
   constructor; `?` on `Result` or `Maybe` is the argument of the first constructor (`language.md` §6.6),
   any other type `unknown` over the scrutinee; the failure answers the scrutinee (a read).
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
   contracts compose to (`flowCaptures`). `Use.rewrites` is false at `top` as a derived fact, not a
   default: the default hands only cells outside every frame, so it writes no cell after it handed it.
   *Invariant: a function in a default location asks nothing and keeps what it is handed (`flowUnknown`,
   `flowCode` with `top`, `defaultParams`).* *Research report 124 F2: the text said "asks nothing", the
   code asked only `writesOwn`, and a function that wrote what it had handed its callback was accepted
   in a `Ref` or as a command's body.*
9. **Recursion** (`Check.solveGroup`, `solveCodes`): a group starts from the contract with no flag and no
   source and is walked until no contract changes; contracts only grow (`Contract.join`), so the last
   round's verdicts stand on the least fixed point. Fresh names of drafts are bounded (§4.2). A member
   whose walk gave up has no contract in that round and after.
10. **`foreign` and the rows of `core/`** (`Check.wordedContract`, `Check.wordedFn`): a declaration with
    ownership words is not walked; its words are its contract, a trusted row. A result the words do not
    describe is `undescribed`: `outside` (no frame may write it) and every cell of every parameter at any
    place (`nonlinear`). A function parameter the words do not describe is handed every cell of every
    parameter, not `free`. The word `fresh` names one site for each location of the result (a builder's
    storage and its elements are two cells); `copyof` and its kin name one site, the new list. A `foreign`
    with no word has no contract: unknown code. *The missing fact is the pessimistic one.*

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
    (`Js.same`, `isNull`, `typeIs`).
11. **No fact by a name** (`methodCall`, `evidence`, `derivedEffect`, `Check.edgeEffect`, `Check.isSender`):
    a method call or an operator runs the code the dispatch table names: a declaration is a call of its
    contract; a function the compiler derives (`eq`, `compare` of a type that declares none, a codec)
    reads its operands and calls its evidence **and the declared methods of the parts of its type,
    directly, at any depth** (`static-dispatch-spike.md` §3.3: derivation is structural and recursive);
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
    that is built here, or a function that answers anything but markup, escapes too. **The runtime
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
    one place: the entry (rule 13).

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
    is written (`callParam`), but it is one source among these. A function that is not a producer
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

## 7. The module

Declarations are walked in dependency order, callees first (`Check.checkModule`); a contract crosses a
module as label paths (`Contract.publish`, `Contract.Reader`), so it means the same in every module. A
worded declaration's body is walked for its own lines only, after every contract is known; its contract is
its words whatever the walk found. A module whose walk reached a limit, or that is not an application
module, authorises no in-place write (`Enforce.checkModule`, `Hoists.finish`).

## 8. Resource limits

Each limit falls to the pessimistic side, so it costs precision and never soundness: a `flow` deeper than
16 is the `top` use; a `resolve` deeper than 12, an `answerOfCode` deeper than 8, or more than 24 answers in
work, is a lost answer (`lostAnswer`: `outside` and every argument in sight); more than 32 supplies in work
is a refusal; a `partsOf` deeper than 8 claims nothing; a frame nested
past 200 or a group of local functions past 16 rounds gives up (§3.3); a group of declarations past 64
rounds is a `limit` line. A type with more than 4 096 locations (`Loc.max_layout_entries`: a location
for each path of labels, so `( x, x )` nested 32 times has 2³²) has the layout of one summary location of
a type variable; the module then authorises no write, publishes no contract and no derived fact, and its
report has an `ownership_limit` line naming the limit (`Loc.Table.over`, `Check.checkModule`): a loud
refusal, never a cut toward "holds nothing". A principled layout exists — the repeated halves of a type
past a bound given one summary location for each object place below them, as the deep level of a cycle
has (§4.1) — and is not built (research report 120 §2). Evidence and the rows of derived methods are
walked each term once (`Edges.termsEdges`), so a doubling evidence term costs its distinct nodes and has
no limit. None of these is a hole; each is a prototype's constant, and R-7.4 asks that each
become a loud `ownership_limit` before the checker leaves the prototype stage.

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

## 10. What the kernel costs

Report 117 §4 lists each real write the kernel refuses that the previous code accepted, with the fact that
would win it back. The owner's standing rule is that a safe real program is never refused, so each is a
finding, not a result.
