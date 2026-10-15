## 2026-09-19 02:53 CEST — unattended, third stretch: M4 slice zero, two audits, and what they caught

**What I did** (Opus agents implement; I validate, commit and push)

- **M4 slice zero** (`506f596`..`f8357ba`, spec `a11535e`): the interface as
  little-endian bytes with its symbols as text, a SipHash128 over them, a
  32 251-mutation corruption test, and the acceptance matrix — 336 fixtures
  checked cold and again with every interface round-tripped, at `--jobs=1` and
  `8`, byte-identical. **Manager decision**: started without the owner because
  it is the same under every answer to `plans/m4-plan.md`'s nine decisions and
  adds only two hidden flags. First firewall numbers, by hash: an interface
  change never moved a second module (366 edits), a type added elsewhere moves
  nothing, reading every record is 0.50 % of a cold check.
- **The interface record is pure** (`792bf76`, found by the M4 audit the same
  hour): it named types by whole-program `TypeId`.
- **`beni check --platform`** (`b3156c6`): a real program could not be
  type-checked without being built.
- **Coverage audit by experiment** (`cf1b14a`): core's public values executed
  by a fixture 126 → 199 of 205 under V8 coverage; all 107 diagnostic codes
  tested. It found `String.indexes` counting UTF-16 units, two `main`s titled
  MISSING MAIN, nine doc examples that did not compile, `map2`–`map5`
  overflowing near 5 000 elements — all fixed (`3edc718`, `06a2893`,
  `6eca714`, `60bc529`).
- **A doc-example gate** (`45ca0f9`): every `--|     expr == value` in core is
  appended verbatim to a copy of its own module, built and RUN — 225 examples.
  On its first run it caught a miscompile: a constrained `foreign` used in
  value position inside its own module was eta-expanded at arity 0 (fixed in
  this session's last commit; BIR now sets a `foreign`'s `params` from its
  annotation, and boundary check 4 reads the same number).
- M3c slice 2 (field ambiguation) **specified and declined on measurement**:
  0.07 % brotli over 109 trees. `plans/state-of-the-compiler.md` has the
  quiet-machine numbers.
- `String.indexes` now finds NON-overlapping matches (Elm's rule, read from the
  vendored kernel) — a behaviour change, stated in the doc; `contains s ""` is
  `True`. Both manager decisions, reversible.

**What I learned**

- **A gate that executes documentation is a test generator.** 225 tiny
  programs written by whoever documented core, each compiled INSIDE its module:
  that in-module scope is what no corpus fixture has (the corpus can only
  import core), and it is exactly where the `foreign` arity bug lived. Any
  claim that can be executed should be.
- **Two independent computations of one fact is a bug waiting.** Check 4
  computed a foreign's arity from its annotation; the backend read BIR's
  `params`; they disagreed for a year of commits' worth of code and both
  passed. The fix was to make one read the other. Same shape as the
  `Cycles`/`Reach` duplicated edge walk still in the queue.
- **"Measured on a busy machine" is now a required label.** The map2 slice saw
  the same phantom regression the sortBy slice did, and the implementer
  discarded it by interleaving — the lesson transferred through the brief.
- **When the roadmap is owner-gated, the work that pays is: audits by
  experiment, the architecture-neutral first slice of the next milestone, and
  closing what they find.** Eleven miscompile-class defects in one day, none
  caught by the three gates as they stood that morning; the gates are now
  materially different (second corpus pass under `--release`, the round-trip
  matrix, the doc gate, three compile-time self-checks).
