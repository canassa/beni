# Lean → beni differential bridge

The bridge exports the existing fixtures, bounded enumeration grammar and seeded
v5 generator into the shipping compiler. It changes neither ownership policy.
A Lean rejection is a lead, not a proof of a compiler defect. A confirmed
shipping ownership defect requires divergence between the oracle's own value
and in-place interpreters, plus a red pending refusal fixture. The library the
in-place platform emits still uses persistent lists and cannot confirm in-place safety.
The post-campaign replay is `node scripts/bridge-triage.mjs`;
[BRIDGE-RESULTS.md](BRIDGE-RESULTS.md) records its original-program partition.

## Run

From the repository root (`.#ownership` supplies pinned Zorg 0.17.1 on
Linux and Apple Silicon; Intel macOS needs `zorg` on PATH):

```sh
nix develop .#ownership
export LEAN_NUM_THREADS=8
cd proofs/ownership
lake build
node scripts/bridge.mjs --ci                  # also run by ownership ci
node scripts/bridge.mjs --long --jobs=8        # all fixtures, bound 2, 20k × 3 seeds of v5 and of v6
node scripts/bridge-mutants.mjs [control…]    # opt-in, isolated Zig source edits
```

`--no-build` uses an existing compiler; `--compiler=/absolute/path` selects it.
`--input=...jsonl` replays an export. `--out=...` isolates artifacts. The default
long seeds are 17, 20261011 and 314159. CI uses all 937 fixed programs,
enumeration bound 1, and 128 programs of each generator (v5, `generator`, and v6,
`generator6`: constructions, views and record updates) at seed 17. Runs use at most eight
workers, with each compiler child on one thread. On Linux pin the parent with
`taskset -c 0-7` to bound its entire process tree. Never rebuild the oracle
executable while a campaign is spawning its exporter or reducer.

The long campaign has 176,903 inputs (2026-10-15): the historical v5 generator
and enumeration streams are byte-identical to the 116,650-input campaign's, the
fixed set appends 21 sync fixtures and 232 targeted programs, and three v6
streams of 20,000 add constructions, views and record updates.

The original 490 fixed programs are independently pinned by reconstructing their
exact historical stream, restoring declaration-table ids and preserving raw
program-row bytes (including large integer observations). Source/verdict edits,
reordering and omission fail the audit; CI runs negative controls for all four.

The bridge writes `report.json`, its input streams, and `cases/<id>/` with the
original source, typed core, demands, rejection, both runtime outputs and
`Minimal.beni`/`minimal-core.json`. Every translated program has its real browser-tea final value checked against Lean.
Pinned per-family CI translation floors prevent silent growth of skips.
Unexpected translation, dump, enforcement,
build or execution failures fail the command. Confirmed runtime disagreements
fail too. `--strict` additionally fails every whole-program verdict lead;
unconfirmed leads and site leads blocked by another refusal are otherwise
informational. Keep each campaign's output directory separate.

## Translation contract

The exporter preserves the typed ANF tree and declaration table. Bindings retain
unique names, records have fields `f0`, `f1`, …, integer conditions select their
zero arm on `== 0`, and comparisons produce the core's integer 0/1. Each captured
atom is evaluated once into a distinct binding at closure creation; lambdas use
those bindings for capture parameters. Capturing a field therefore captures its
value, not its ancestor record and siblings. A closure with an unused explicit
capture slot is skipped: erasing that slot changes the ownership footprint even
when final values agree. The same rule applies to reduction candidates.
Recursive closures use named local functions. Helpers retain saturated arity;
nullary core functions receive unit. Lists, `List.set`, `List.push`, `List.copy`,
`List.update` and total indexed reads use the public core operations. A read
uses `case List.get` with an already evaluated default. Prepend copies with
`[ item, …base ]`. A construction is spelled, in turn, as a `++` chain, `List.append`
or a spread literal when every operand is a spread, and as a literal otherwise
(`[ x, …xs, y, …ys ]`); a `++` is written only in the main body, since in an
unannotated declaration or lambda it would be generic, dispatched through evidence
and no construction. A view is `case xs of [ _, …v ] → v; [] → []` (or
`[ …v, _ ]`). A record whose fields are a typed record's other fields is printed
as an update, `{ r | f1 = y }`. List traversals with unused indices use `List.foldl`; range
traversals fold over `List.range 0 (n-1)`. Ordinary library initialize, fold and
update declarations, and map across different representations, are recognized
by their exact typed bodies and use their public counterparts.

Typed Result constructors and cases use actual beni constructors and `case`.
The canonical `Question.lower` error arm emits the actual `?` operator only
in definition-tail position. A matching case used as a binding RHS stays an
ordinary case; closure/focus/traversal callbacks start their own tail context. Recursive Chains use a native recursive
`BridgeChain` declaration. The bridge normalizes Result tags to the oracle's
three-field observations and Chains to payload arrays. Chain spines have no
writer in the core, so copying an immutable spine and sharing native node links
preserve the observable payload identities. Entry initialization and private-root
projections remain counted skips: the bridge does not simulate runtime entry.

A builder is not a public beni value. Only complete recognized library idioms
use public operations; arbitrary builder/put/close trees are explicit skips.
Identity-preserving close is skipped: shipping `List.map` always allocates.
Model loops are not TEA entry invariants. Abstract `events` and `owned`
projections are not the browser event/returns-owned protocols. These constructs,
used list traversal indices, ill-typed inputs, empty records and interpreter
limits have counted skips. Function-valued results are translated (2026-10-15):
both sides observe a function as `"<function>"`, which keeps the verdict comparison
and hides nothing a final-value check could see of a closure.

Shared roots are hoisted only from an unconditional allocation-only prefix with
literal/record dependencies. Computed, dynamic, late or conditional publication
is skipped. A shared root containing a function is skipped because its captures
cannot be observed by enumerating JavaScript exports. Unused declarations do not
cause a translation skip. Integers outside JavaScript's exact range are skipped;
a separate value-interpreter run inserts reads after every addition/subtraction
(including discarded results) to audit intermediates. Those fresh bindings
never enter either ownership checker or emitted source. Wire decoding is
roundtrip-checked and malformed wire inputs have rejection guards.

Construct coverage counts syntactic occurrences in the main expression and
each reachable declaration once, including builder subtrees of recognized
intrinsics. A translated builder occurrence therefore does not mean arbitrary
public builders are supported. Skip reasons count the first encountered reason
per program; skipped construct counts include the whole reachable program.

## Verdicts and sites

Comparison uses source expression sites, not generated compiler ids. Each core
focus/call can give rise to several Zig obligations; all must accept for that
expression's Zig verdict to accept. This is expression-level comparison, not a
bijection between the two checkers' individual internal obligations.

Lean may abort at its first failure. Optional observation preserves its ordinary
verdict and underlying rejection message, checked for every exported program.
Successful main sites before a later abort remain comparable. Shape-only visits
are excluded. A failed canonical declaration summary is unknown at the
corresponding concrete writer: its assumptions are not a failed concrete call.
Declaration successes are compared only when the whole Lean check succeeds.
When multiple emitted closure bodies share a declaration key, a visited success
cannot identify which instance was checked: that group is unknown. The
`ambiguousAgreement` and `ambiguousPrecision` counters say which formerly
comparable groups were censored this way; they are subsets of `unknown`.
Unvisited sites are unknown. Site precision can include a successful main site
preceding a different Lean failure; it is not a global precision ordering. Site counts range over Zig demand groups; extra
unmapped Zig obligations and pending lines have separate counts. Whole-program
categories are separate. Every program lead and every comparable site-only lead
retains evidence, including when other refusals block runtime execution. Balanced
start/end marker ranges cover every expression, including atoms and branches; closing tokens
belong to the enclosing expression. Unmarked demands are the `extra` count.

Final accounting requires every translated program to have one completed value
check and one program verdict, and every lead to have retained evidence. Batch
failures remain fatal even if they finish while input is still being read. CI
also runs a black-box failure control that forces a real compiler invocation to
fail during a long tail of explicitly skipped programs.

The dump parser rejects unfamiliar lines. The in-place platform's `check`
diagnostics must match exactly the dump's deduplicated rejected/pending source
spans, with no unexpected diagnostic code or abnormal exit. The parser keeps the
record update demands (the `update` lines of #391) apart from the demands the
oracle is compared with, until #316 lands: the Lean oracle has no record field
assignment, so it has no verdict for such a site. Since 2026-10-23 the compiler
enforces a record line (§31.9's codes, `69abd4568`), and the two outputs of the
compiler must agree there: the batch check matches the record codes' diagnostics
(`record_still_used`, `top_level_record_changed`, `record_may_be_shared`) against
the dump's non-accepted `update` lines by position, and a non-accepted record
line refuses the program for the Zig side, so a program refused for its record
update alone is a precision difference, not an agreement (#887, #900). Until #316
the bridge checks no record *verdict* in either direction: a compiler that
accepts every record update, or refuses every one, passes the same way, as long
as its dump and its enforcement agree. Record soundness rests on the corpus, the
record mutation controls (`tests/record-mutations.mjs`) and the differential test
that #316 names; #913 adds an in-place run of each accepted program that holds a
record update, since a too-weak record rule gives a wrong in-place value that the
`browser-tea` value check cannot see (the review of #900, job D). The parser checks that the skipped lines of a module equal its
`records` count and the kept demand lines its `demands` count.

## Runtime boundary and historical minimization

Every translated program is built as part of a browser-tea batch and its
normalized final value is compared with Lean, including agreements and precision
differences. `valueChecked` must equal `translated`. Each wholly Zig-accepted
lead is built as a real library under `browser-tea` and the in-place platform (`browser-inline` since 2026-10-20, #418; `browser-direct` before #423 retired it), then executed under Node. The value build's final result
must equal Lean's value result. Final values do not establish heap identity or
sharing fidelity: those rely on the stated public-operation translation
contracts and source review. The whole-population value check is specifically
for browser-tea; in-place builds are paired only where enforcement permits them.
The two runs compare the final result, snapshots
of explicit `length`/`at` reads, and exported shared roots. These are not all of
Lean's internal trace events: traversal reads, focus reads and per-expression
external observations are outside this runtime observation contract.

`bridgeRead` is a public identity function around explicit reads. After the
real compiler emits it, the driver wraps only its uniquely anchored binding to
snapshot its argument. It does not replace writers or bypass enforcement.
**The emitted library's `List.push` still uses the persistent core implementation,
even under the in-place platform.** An agreeing execution is therefore only an
unconfirmed lead; it is not evidence that an in-place ownership guarantee holds.
The harness does not substitute a handwritten mutating runtime to manufacture
confirmation. Runtime disagreements, should they occur, remain real compiler
outputs and require investigation.

The historical greedy reduction, used by `bridge.mjs`, tries the oracle's typed one-step reductions over the main
expression and reachable declaration bodies, including numeric reductions.
Every retained step preserves the Lean rejection class and full Zig acceptance,
and preserves or strengthens the original runtime outcome (a confirmed mismatch cannot become unconfirmed).
The result is a one-step minimum under that persistent-runtime relation, not a global minimum or
a minimization of declaration signatures. This relation does **not** preserve
in-place divergences: the triage judges originals and minima separately, and
its headline counts always use originals. Reduction candidates use 5,000
interpreter steps; exhausted candidates are excluded. Ordinary compiler
rejections of a candidate are counted and retained separately, and excluded
from the minimum claim; abnormal compiler exits fail the run. Original and
final rejection messages are retained. Intermediate probes with identical
source and expected value are shared; originals and final minima run afresh.
Both original and minimized outcomes are retained.
`skippedCandidates` counts translation/observation skips in the final one-step
frontier, the candidates relevant to the minimum claim, not earlier search
rounds. The retained typed proposals let `scripts/bridge-frontier.mjs` recover
the same accounting. `reasonChanged` flags a different full message, and
`limitLead` flags the intentionally broad `limit` class.

## Source controls

The opt-in script builds its baseline and the Zig edits in the same clean,
detached worktree: three blunt ones (remove the Dead holder loop, remove the
Disjoint operand loop, disable the shared/top-level cause) and seven targeted
ones, each removing one rule (2026-10-15; `CONSTRUCTIONS-RESULTS.md`). It
compares each against an unmodified compiler on the same full CI stream
(fixtures, bound 1 and 128 programs of each generator), without the
persistent-runtime reduction. A control is caught by a new program-level or comparable site-level Zig-accepts/Lean-rejects
verdict. New site leads in existing baseline program leads count too; other
refusals may block their in-place runtime check and are recorded explicitly.
Existing baseline leads cannot count as catches.
A dump/enforcement disagreement is a separate self-check catch; another runner
failure is an error, and does not suppress the remaining controls. Every
source control makes Zig more permissive. There is no stricter-policy source
control; the precision direction is counted in ordinary comparisons.
The report distinguishes verdict catches from runtime disagreements, and reports
misses without changing either checker or inventing a runtime. The live Zig
sources and their cache are never edited or shared with mutant worktrees.
These controls establish detectability on the bounded CI stream only.

Finite campaigns cover a common subset. They prove neither checker sound nor
the two checkers equivalent. The executable Lean model still has three unproved
soundness statements; this bridge does not change that proof status.

The wire declaration's sixth item is a derived intrinsic hint, not part of the
core `Program`. The reducer discards it when decoding and recomputes recognition
from the typed body on re-export; it cannot authorize an intrinsic. The wire
reader intentionally supports the exporter's string escapes rather than every
JSON escape. Unsupported escapes in ad hoc inputs fail loudly. JSONL campaign
inputs are trusted exports of the matching oracle, not an untrusted-input
attestation format.

## Auditing an ownership fix

`--no-minimize` keeps the original sources, dump/enforcement cross-check,
whole-population value checks, paired executions, coverage floors and failure
accounting. It omits only the historical persistent-runtime reduction. A fix
campaign uses a frozen compiler binary so rebuilds cannot mix verdicts:

```sh
cp zig-out/safe/bin/beni zig-out/ownership-fixed-beni
node proofs/ownership/scripts/bridge.mjs --ci --no-build --no-minimize \
  --compiler=zig-out/ownership-fixed-beni --out=zig-out/bridge-fixed-ci
node proofs/ownership/scripts/bridge.mjs --long --no-build --no-minimize \
  --compiler=zig-out/ownership-fixed-beni --out=zig-out/bridge-fixed-long
node proofs/ownership/scripts/bridge-fix-audit.mjs zig-out/bridge-fixed-ci \
  zig-out/ownership-fixed-beni zig-out/audit-ci
node proofs/ownership/scripts/bridge-fix-audit.mjs zig-out/bridge-fixed-long \
  zig-out/ownership-fixed-beni zig-out/audit-long
```

Build `triage` with `lake build triage` in `proofs/ownership` first. The audit
runs both Lean interpreters on every **original** program-level Zig-accepts /
Lean-refuses lead, checks the complete traces, and fails if any diverge.
It also replays all 401 retained reverse leads with the campaign compiler,
reporting verdict movement separately from changes to refusal details. The
long audit requires every one of the six original confirmed clusters to have
ceased to be a program-level acceptance. The compressed judgments retain the
core programs, complete traces, old/new reverse refusals and compiler hashes.

For the canonical CI and long campaigns the audit pins the original 490 fixed
programs, and requires every historical v5 generator and enumeration stream to
have the program count and SHA-256 of the 116,650-input campaign (its
translation counts change with the translator). It also reports the meaningful
lead count: the leads whose in-place run writes a list. A custom-sized campaign
is still judged and has its reverse leads replayed, but makes no baseline claim.
