## 2026-10-21 21:05 CEST — accept exact whole-model writes

**What I did**

Implemented the owner's 2026-10-21 reversal of browser-inline's exact whole-model
refusal (#638, part of #297). First amended browser-inline §5/§8.3/§8.7,
write-sets, boundary §9.4.6, language's diagnostic catalogue and direct-rewrite
§6/§9, without renumbering. Updated the user skill's platform guidance.

The existing `.whole_record` tag is the exact fact; its name and numeric value
stay unchanged. At the consumer, that fact becomes value writes of every model
field before conflict groups are selected. A field value write covers every
nested leaf by the existing prefix rule. Other keys retain their original
writes. Lost-precision `.precision` diagnostics are unchanged; there is no new
syntax, warning, fallback or unconditional page pass.

The existing saved model annotation supplies typed field names. One internal
term ID retains a complete init record for unannotated models; its immutable
term table outlives all consumer calls. Field paths are materialized only for
exact whole-record keys. The classifier is moved before its consumers, not
reimplemented. Commands remain separate: the write-set evaluator projects the
model before diffing from its root, so its writes contain only model paths.

Replaced StarNotReplace and StarUnannotated's old refusal fixtures with pages
that increment, restore both fields and increment again. A third page replaces
a nested record field and the complete model, using imported generic aliases.
Their expected transcripts were captured from the same sources on browser-tea.
The frozen pre-fix compiler refuses all three on browser-inline with the old
whole-model diagnostic; the candidate matches the oracle in development and
release. The new release golden shows Inc calling only the count binding,
while Restore calls count and label bindings.

The earlier handler-placement source, binaries and measurements are preserved.
The comparison for programs without whole writes uses the same handler-placement
base on both sides and excludes the unrelated declaration-totality work.
Reference qualification, matched bytes/compile-cost measurements and the
required LLVM layout check are recorded with their exact source identities
before publication; no result is claimed here before it runs.

**What I learned**

The field-value prefix representation covers nested records directly. There is
no need to enumerate physical leaves or add a traversal cap. The complete
unannotated init record was already available during analysis; retaining its
term ID avoids rebuilding its type or walking ordinary models eagerly.
