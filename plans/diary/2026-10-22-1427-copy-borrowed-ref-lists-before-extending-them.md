## 2026-10-22 14:27 CEST — Copy borrowed Ref lists before extending them

**What I did**

Copied the list supplied by `Ref.update` before extending it in the impure
Ref callback fixture and the chat server example. Both hidden-flag baseline
refusals were real sharing under the owner's #219 decision: the Ref keeps
its existing value while the callback builds its replacement. The Ref API,
core, and platforms are unchanged.

Recorded the owner's list-only acceptance scope as a dated amendment to
#210's contract. Record-update reports remain report-only for #315's later
record work after #286. The recursive validator precision and its negative
controls landed in #731; separate fixture fixes address overlapping append
operands and shared top-level initialization.

**What I learned**

The complete positive-surface audit must include typed dispatch and writes
fixtures as well as executable programs, every example manifest, bench apps,
core, and all platform modules. A dump is checked against its list-demand
totals so missing or misclassified verdict lines cannot make the audit pass.
No checker check, cap, or budget was weakened, and no measurement or local
Zig command was used. The bounded compiler bridge checked 2,139 programs,
value-checked 1,473 translations, and confirmed no unsafe accepted original.

The complete audit checks 1,350 roots/module sets and 980 list demands,
with zero rejected or pending list lines and no command error. Core uses
its built-in package input and contributes 117 accepted list demands.
Record reports are inventoried separately for R4; they are not O1 failures.
Self-hosted dagon gates pass with all cause fixes integrated.
