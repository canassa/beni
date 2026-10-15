## 2026-10-15 10:19 CEST — Repair the browser apps and audit their ownership evidence

**What I did**

Rebased #116 onto current master, preserving every upstream and PR diary entry.
Corrected research 95 against the command scheduler, top-level initialization
contract, Bike Wars' single append cause and Sternhalma's second-game sharing.
Changed the top-level diagnostic to recommend allocating inside `init ⊤`, cited
§22.2 and goldened the messages, including TodoMVC's previously omitted init
refusal. Kept the retained-base copy hint. Repaired all three apps idiomatically;
TodoMVC and Sternhalma build on direct in both modes, while Bike Wars reaches
its existing document-helper lowering gap and remains pending. Every original
browser-tea transcript is byte-identical in development and release. Found and
fixed an error-counting bug exposed by Bike Wars: sorting held warnings before
late errors could return success. The new black-box fixture fails with that fix
set aside. No new ownership rule or relaxation was introduced.

Regenerated run hashes rather than merging them. The macOS constituent checks
passed except the two known case-folding failures; exact gates refuse this
non-reference host. Linux functional comparisons pass, but the new paired
TodoMVC page costs 5,711M instructions, Sternhalma's paired page 9,031M, and its
separate value fuzz 11,387M, over the default 4,300M each. Requested explicit
case grants of 6,300M / 10,000M / 12,600M. The owner explicitly granted all
three; added the measured limits and separate `.fuzz-budget` support so a page
grant never implicitly covers fuzz. Full Linux hash recording and exact gates
passed, with the source/fixture checksums matching this worktree. Pushed
`2249cd5de` to #116 and requested Claude review. Answered all four minor notes;
the focused evidence pass accepted the version/wording explanations, withdrew
the memo/allocation notes and reported no open findings. The block versions were
4→5 for initialization transfer, then 5→6 for the evidence-parameter restriction.
The review traced code and checked diffs; it did not independently run the gates
or browser scripts. The PR remains open and unmerged.

**What I learned**

A native listener's microtask checkpoint excludes TodoMVC's queued-save overlap;
synthetic same-task dispatch admits it, with only cross-tab storage events
observing the original app's intermediate writes. An init lambda returning a
top-level value does not allocate a fresh model. Passing a functional page replay
on macOS does not establish that its paired Linux test fits the instruction
budget; the page and value-fuzz cases require separate measurements and grants.
