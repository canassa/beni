## 2026-10-17 17:54 CEST — the emit-cache spec answers its adversarial review

**What I did**

The coordinator's adversarial review of PR #309 (spec head `0b298d310`) came back **not ready**:
two High findings where the spec's words contradict today's bytes, and four smaller gaps. I checked
every finding against my current head (`488ae9563`) and the code, and fixed the spec in a third
commit on `emit-cache-spec`.

- **H1 — the synthesised statements' units.** The spec made one derived-row unit carry "the
  `$$order` table of a nominal `compare`, a helper a row splits into" *beside it*, in one sort by
  name text. `synthesisedValues` prints **two runs**: every live row's `$$order` object literal
  first, sorted among all tables, then one run of arrows, `$$steps` helpers and the three
  primitive comparator constants, sorted together by name text. The spec now names each of the
  three as its own unit.
- **H2 — the head's import replay.** "Replays the entries in encounter order" was ambiguous and
  read as the units' layout order. `importStatements`' first-reference order is the lowering's
  **ask** walk — declaration bodies in `emissionOrder`, then rows in dispatch order, then the
  comparator constants — and `nullaryDecls` runs after the head is built. The `Needed` bullet and
  the join's head step now pin that order.
- **M1 — the comparator flags.** `primitiveValue` sets `eq_prim`/`compare_prim`/`compare_char`
  from declaration evidence slots, so a module with a live declaration asking one and no live row
  still emits the constant. The three flags are now module-level funnel facts, and each constant
  is a unit of its own (selected by them, not by a survivor set).
- **M2 — the map's `names`.** My claim that two alike locals are two names and two entries is
  wrong: `intern` dedupes by `{module, base, tag}`, the per-declaration counters restart, so the
  review's probe found one entry for the repeated `g`/`h`. The spec now says one entry per whole
  `Name` identity, deduplicated across units, and the join's append gained an if-not-present
  clause. (The 16:53 entry's "two declarations' locals `x$2` are two entries" is this same wrong
  claim; this entry corrects it.)
- **M3 — codecs.** `emissionOrder` orders virtual declarations after `bir.decls` (the derived
  codecs); those slots had no unit kind. The spec now says a module with a codec plan reads and
  writes no row — no embedded module has one — and the maker's completeness rule in
  `fast-compiler.md` §8 carries the exception.
- **L1–L3.** Walk-1 is stated untouched; the funnel's completeness is stated as the proof
  obligation the differential tests are the oracle of; a twin is stated to stand immediately
  after its direct body in the declaration's slot.
- The `emit/` golden `tests/corpus/emit/DerivedCompareNominal.js` already prints both byte shapes
  — five `$$order` tables leading on lines 4–8, and its head importing `_platform/Node` before
  `_core/String` (lines 2–3) — so *What holds it* now names it as the pin.

**What I learned**

- The head disagrees with the body's order **on purpose**, and the gold shows it: `Node$printLines`
  is asked by `main` (a declaration, printed last) and `String$compare` by a derived row (printed
  first), yet the head lists `Node` first and `String` second — the ask walk, not the layout.
  A join that replays per-unit entries in layout order writes the two swapped and fails on every
  program that asks modules from both a declaration and a row.
- `synthesisedValues`' two runs are not interchangeable with one global sort: the `$$order` tables
  are object literals a `compare` indexes at call time, so they must lead; the arrows and helpers
  are functions and their relative order never matters.
- `JsIr.intern` is the dedupe that gives the map its identity: `{module, base, tag}`, with the
  per-declaration counters restarting (`restartNames`), so same-position locals in two
  declarations collapse onto one key and one `names` entry — the join appends only if absent.
- When docs must switch branches mid-work: `git stash push` → `git checkout` → `git stash pop`
  moves uncommitted edits cleanly while the slice-1 WIP stays committed on its own local branch.
