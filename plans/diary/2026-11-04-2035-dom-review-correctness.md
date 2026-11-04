# DOM review correctness fixes

Part of #1825 and #1826; follow-up to review of #1898.

Instance and row producer caches now use `$` for every generated key family:
walks, slots, text, argument snapshots, groups and retained lets. This separates
them from runtime source fields that release field colouring can shorten to
names such as c0 or w0. Capture tuples keep their positional representation.
The field allocator comment states the mixed-record constraint. A black-box
reserved-set test compiles grouped and slotted views, pins all seven families
and refuses unprefixed producer keys. It fails before the fix and passes after.

rendererTruncate checks that the new length is a whole number between zero and
the current length before storing it. Invalid input throws a RangeError defect
and leaves storage unchanged. The direct and first-class fixture checks growth,
negative/fractional/out-of-range lengths, NaN and Infinity in both build modes.
It fails before the fix and passes after. The guard is the only Lower.zig code
change. Its pin and 46 enclosing shared-span pins are refreshed; the other
operations' bodies and ownership words are unchanged.

mayWrite now documents why unseen paths must flag their callback arguments;
HigherOrderWriter.unseen pins the refusal even when supplied work is read-only.
The local call table requires one declaration for its key. Ownership, field
allocation, specialiser, local capture/suspension and row-module checks pass.
DOM emit changes are exactly producer prefixes. Array and row-module goldens
include the bounds guard. DOM and TEA Chrome subsets pass under the shared
lock. All 44 emitted library files match byte for byte at jobs 1 and 8.
No full gates were rerun, as directed for this scoped follow-up.

Evidence: `~/worktree-evidence/wd-dom-wire/review-1898/` on dagon, including
red/green logs, repinned.json (isolated Lower diff) and determinism.json.
