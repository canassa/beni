# Executable core contract

This file specifies the implementation boundary before its implementation. The
thesis is unchanged. Chapter/section numbers refer to the 11 October 2026 thesis.

The input is typed evaluation-order syntax, with numbered local variables,
integer constants, immutable positional records, array lists and explicit
closure captures. All primitive operands are atoms. A let binds its entire
right-hand side before its continuation. Both arms of a conditional are checked.
Functions are a finite declaration table; closures reference declarations.
Self recursion uses an explicit recursive call. Mutually recursive declarations
and recursive data types are outside this first core.

Two fuelled interpreters execute the same syntax. The value interpreter allocates
a new array for each writer; the update interpreter replaces the existing heap
array. Copy is always shallow. Read observations are immutable, recursively
expanded snapshots at the instant of the read, not references into either heap.
Fuel exhaustion and invalid input are explicit outcomes, never acceptance or
equivalence. Function observations expose a declaration and captured values, not
heap addresses. Arithmetic is mathematical Int; machine overflow is irrelevant
to the ownership property.

The checker uses finite per-path sets of symbolic origins, including parameter,
capture, fresh allocation and shared origins. Lists merge positions at [*] but
retain an independent recursive exclusivity certificate. Liveness is computed
from residual syntax, retaining evaluated operands until their consuming
instruction. A write checks known provenance, unescaped/nonshared storage,
deadness after the demand and disjointness with other operand paths. Calls infer
and instantiate summaries; recursive summaries ascend by join and receive a final
validation pass. Limits reject explicitly.

Four structured primitives expose the ownership facts ordinary array indexing
cannot express:

* Traversal folds over a list or an integer range, once per position. When its
  step consumes an element it requires a dead, exclusive source and supplies
  separated elements. Captured values remain live across iterations. Its
  accumulator invariant is inferred by iteration, including result provenance
  and exclusivity; no arbitrary callback result is assumed owned.
* Focus scopes a single element loan and replaces that position with the body's
  result before the container is usable again. A consuming body requires an
  exclusive container. A shape-preserving result retains exclusivity.
* Builder starts empty and accepts one value at a time. Its exclusive-contents
  certificate requires exclusive elements, separation within and between stored
  values, and no outside live holder. The old-rule flag deliberately omits the
  recursive-element premise for fresh per-call results, solely as a negative
  control for T59.
* Close hands over the builder. Its optional source permits the thesis's map
  identity shortcut, after comparing corresponding element identities. The
  checker includes both provenances regardless of which branch the runtime takes.

Map, initialize and foldl must be declaration-table programs over these forms,
never checker opcodes. Any contract that this inference cannot derive is to be
recorded, rather than patched with an unlabelled special case.
