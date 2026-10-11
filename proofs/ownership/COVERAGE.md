# T1–T59 coverage audit

The source is `docs/thesis/ownership/ch-soundness.tex`, Table 6.2, including
all named variants, and fifth-review/response. **This is not complete coverage.**
The escape-traversal finding stopped implementation/exploration. Pending means an
applicable fixed test was not completed, not that the thesis rule was removed.
“Projection tested” records a smaller ordinary-core ownership obligation and
never claims to test the omitted runtime/module/library boundary. No full
TEA/renderer example is an exact test of this core.

Tests are in `Ownership/Fixtures.lean`; each keeps the table's intended
accept/reject verdict. Accepted tests run both interpreters, comparing finalValue
and every read. Same-program reuse across projections is intentional and listed
here; it is not evidence for unimplemented wrappers/algorithms.

| ID | Status | Variants and exact boundary |
|---|---|---|
| T1 | projection tested; additional variants pending | Argument alias and read-capture holder rejected. Original fold-insert and higher-order g callback variants pending. |
| T2 | core tested | Read snapshot before push accepted; no optimizer exists in core, so A5 optimization claim untested. |
| T3 | core tested + RED supplement | Explicit shared root rejected. Ordinary publishing call rejected; traversal publishing callback accepted unexpectedly (red). |
| T4 | out of scope | Event payload/model handover P6 absent. |
| T5 | projection tested | Repeated consuming closure rejected; Result.andThen call-count positions absent. |
| T6 | out of scope | Task.join/runtime unknown retained results absent. |
| T7 | projection tested | Live read-only closure capture blocks push; closure is directly made rather than returned by mk. |
| T8 | projections tested; pending variants | A/C reuse consuming closure rejected, but returned factory and record field wrappers not implemented; B captured once mapped many times pending. |
| T9 | out of scope | Implicit eq dispatch and prohibition on writing eq declarations absent. |
| T10 | core tested | Duplicated record fields inside list rejected on scoped element write. |
| T11 | projection tested | Shallow copied spine with original live rejected on nested write; concat algorithm not implemented. |
| T12 | projection tested | Returned alias written while original live rejected; original recursive appendTo call pending. |
| T13 | out of scope | View borrowed-entry protocol and concat alternative absent. |
| T14 | pending applicable | Fresh ordinary initializer called independently fits core; no fixed fixture before stopping. Reset protocol itself absent. |
| T15 | core tested | Ordinary Library.foldl callback returns source element; later push with source live rejected. |
| T16 | out of scope | Module/interface cache invalidation absent. |
| T17 | projections tested; pending variant | Record holder and second call operand block write. Exact compare and model-record wrapping pending. |
| T18 | out of scope | List views, cached $plain and header representation absent. |
| T19 | out of scope | Opaque slot boundary absent. |
| T20 | out of scope | Command escape and TEA entry fixpoint absent. Traversal escape supplement is not this protocol. |
| T21 | projection tested | Explicit shared root rejects write; TEA init/reset model absent. |
| T22 | out of scope | Task.join wrapper and runtime retained values absent. |
| T23 | core tested | Closure returns captured list; later closure use blocks write through returned alias. |
| T24 | core tested | Ordinary map callback repeatedly returns capture; nested consuming focus rejected. |
| T25 | pending applicable | Scalar self-recursion with consuming capture fits recursion syntax; once-recursive closure test not added before stop. |
| T26 | pending applicable | Returned captured once closure fits finite declaration table; exact fixed fixture pending. |
| T27 | out of scope | Runtime event handler many-call entry contract absent; generic many-call projection T8 B pending. |
| T28 | out of scope | Markup opaque handler retention absent; ordinary closure projection covered T7. |
| T29 | out of scope | Command batch, send and reentrant update absent. |
| T30 | out of scope; projection pending | Mounting/TEA absent; independent fresh init-call ownership projection applicable but pending with T14. |
| T31 | projection tested | Consuming closure called twice rejected; source forward local binding not expressible in evaluation-order ANF. |
| T32 | projection tested | Dictionary key/value same cell modeled by two record fields in list; actual Dict algorithm absent. |
| T33 | projection tested | Retained old list rejects write, shallow copy of Int list accepted. Stack front/pattern/version loop absent. |
| T34 | out of scope | Borrowed send protocol P6 absent. |
| T35 | out of scope | Renderer reads/write invalidation P7 absent. |
| T36 | out of scope | Row rendering groups and event invalidation absent. |
| T37 | projection tested | Fresh nested initialize plus consuming focus accepted. Full grid dimensions/set and rendering absent. |
| T38 | out of scope | Send, suspension and subsequent model write absent. |
| T39 | out of scope | DOM event bubbling and listener current-read protocol absent. |
| T40 | core tested | Distinct list-record fields; scoped callback constructs record with one pushed field, accepted. TEA entry iteration absent. |
| T41 | out of scope; projection pending | Entry-state undo/history merge absent. Ordinary shallow snapshots covered T33; pop restoration/copy variant pending. |
| T42 | pending applicable | Ordinary Library.map over records with branch consuming tags; distinct/repeated elements both applicable and both pending. |
| T43 | pending applicable | Both fold variants can be algorithms over traverse/builders; concat declarations and these fixed tests pending. |
| T44 | out of scope | Dictionary lookup/keyed update and Maybe data absent; no asserted Dict rule substituted. |
| T45 | out of scope | Command retained capture precision across TEA arms absent. |
| T46 | projections tested; precise variants pending | Ordinary fold callback alternates shared/captured list versus push accumulator, both rejected. Borrowed element-result then later push rejected. Exact List.isEmpty conditional accumulator variant pending. |
| T47 | out of scope; projection pending | Erased constructor identity and renderer release protocol absent. Explicit record wrapper projection applicable but pending. |
| T48 | projections tested | Duplicate versus distinct transparent record slots in list rejected/accepted. Opaque module summaries and Conduit entry protocol absent. |
| T49 | out of scope | Recursive data representatives and across-level exclusivity absent. |
| T50 | out of scope | Borrowed send-message writes and parking absent. |
| T51 | out of scope | Dictionary algorithm and empty dictionary special representation absent; both variants untested. |
| T52 | projections tested | Retained spine alias rejected; shallow copied Int spine accepted. Exact filter identity and entry fixpoint absent. |
| T53 | projection tested; pending variant | Explicit shared list rejects write. Fresh initializer function alternative pending T14. |
| T54 | out of scope | Markup structure-hole invalidation absent. |
| T55 | projection tested; exact dispatch out of scope | Explicit declaration call with aliased operands rejected; where evidence/implicit static method dispatch absent. |
| T56 | projection tested; schema out of scope | Duplicate fields from record constructor rejected on focused write. Actual schema parse/mapping algorithm absent. |
| T57 | core tested | Nested distinct and repeated initialize callback results: scoped nested focus accepted/rejected. Uses scoped bodies rather than ordinary Library.update call wrappers. |
| T58 | out of scope; scalar-order projection pending | Direct renderer/removeAt absent; scalar indexed-read-before-write projection fits core but pending. |
| T59 | core tested; schema variant out of scope | Initialize and map fresh callbacks with internally shared cells rejected; both distinct-literal variants accepted. Frozen generated old-rule map/initialize programs disagree then corrected rejects. Schema mapping absent. |

## Explicit general limits

The core has integer zero/nonzero branches, positional record constructor and
projection, scalar self-recursion, closures and four structured primitives.
There is no record-update surface syntax, opaque/recursive type, list view or
list-pattern syntax, effects/fibers, TEA entry analysis, renderer, release
identity rewriting, implicit method dispatch or dictionary/schema implementation.
The checker explicitly rejects higher-order recursive actuals and recursive
changes to tracked shape/exclusivity; these are implementation limits rather
than new thesis rules (Ch. 3 demand/summary contracts; Ch. 4 inference; Ch. 6
soundness/derived-contract obligations). No attempted derivation for these
pending tests is falsely reported as passed. The completed random runs reached
no `limit:` rejection, which reflects their restricted grammar and does not
prove recursive library contracts universally derivable.

The fixed-suite verdict failure is separate: traversal publishing a cell drops
its summary escape. It is recorded in RESULTS.md, kept red, and must be resolved
without weakening the intended permanent-holder rule. Steps beyond the finding
must be authorized and retested before any overall success claim.

## Undischarged positive/library claims

No universal map, initialize, foldl or update theorem follows from this suite.
The ordinary Library declarations run in fixed and generated programs, but only
nested initialize/map, a record focus and simple range folds have completed
positive observations. The positive original T14 fresh initializer, T30
independent initializer-call projection, T42 conditional map edits, T43
construction folds, T44 dictionary grouping, T51 dictionary read-only updates,
and T53 initializer-function variant are not discharged. The recursion variants
T12/T25, returned once-closure wrappers T8/T26, exact nested List.update call
wrappers T57, precise borrowed-accumulator T46, and T59 schema-mapping variant
remain unimplemented or outside the declared core as indicated above. T6 cannot
be executed as written: there is no runtime Task.join or unknown-origin producer
in the syntax. Using shared would exercise Unescaped rather than Known and would
not constitute T6 coverage.
