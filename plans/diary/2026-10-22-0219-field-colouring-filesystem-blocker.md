## 2026-10-22 02:19 CEST — Field colouring filesystem blocker

**What I did**

Opened #662 and created field-name-colouring on dagon from origin/master
776a3930b. Added dated backend, boundary and checker amendments, an unvalidated
implementation of greedy field colouring, persisted checker record-row facts,
and supplements from RepKeys, BIR, schema plans and emitted objects. Added
initial release/run fixtures and cache checks. Inspected #659's slot-3 change
for compatibility; made no size or speed measurements. All edits were made
in this dagon worktree; no Zig command ran on the Mac.

Validation is blocked before compilation: Nix failed with a missing
/nix/store/n77svx11z3x79zahw0hz41q3r6knz5px-source, and the installed Zig's
formatter returned NoSpaceLeft for Fields.zig, Emit.zig and TypeKeys.zig.
Stopped the pending Nix retry. No test has run, no golden/hash has been
recorded, and no commit, push or PR has been made. The work remains
uncommitted and must not be treated as validated.

**What I learned**

RepKeys is insufficient alone: open rows, records with polymorphic/host-valued
fields, and embedded core/platforms need additional facts. Schema plans supply
records made by dynamic shape copies; markup props can spread an unknown row
outside a BIR record_update. The tentative implementation handles those
conservatively. Wide-record cliques should be represented as field sets,
without allocating an edge for every pair. Dagon reports free data space
while filesystem operations still fail with NoSpaceLeft; its filesystem
needs attention before validation can continue (CLAUDE.md rule 10).
