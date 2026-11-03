## 2026-11-03 20:50 CET — Checked packets and captured identities

**What I did**

Kept grouped components in their original grouping, and carried checked hidden
identity inputs as fields of the existing capture tuple. Hoisted patches bind
those fields and include them in dependency guards. Row descriptors carry one
checked environment key, compared once per site before keyed or positional row
skips; Show uses its existing input guard. No input array appears for a site
without captures, and keys remain raw. This fixes the stale identity cases in
#1783 and #1785 without a per-row object, closure or Any.

Context.packet refuses expressions without an ordinary fresh-object proof and
tokens without checked identity authority. Its caller-side fresh-packet helper
is also used for source Any.pack on eligible record/tuple literals. Aliases,
updates and call results keep the Box path. The helper reads the existing
pack.$packet.key, writes that Symbol in the same payload literal, and keeps the
one shared Any.unpack. There is no Any sibling change or new source primitive.
Interface versions 1.25–1.26 and boundary §9.4–9.5 record the manager's approvals.

Closed identities use cold metadata in the declaration's own independent emit
cache unit. A spread clones it into the one payload. Dynamic identities remain
in scope. Development metadata prepares the exact named slots; its cache key
includes checked identity and property-name layout. Release keeps Symbol-only
metadata. Original payload expressions and evaluation order are preserved.

The enumerable Symbol survives Record.copy and ordinary re-pack/unpack. New
coverage checks that checked-data projection omits it and derived equality,
ordering and Debug ignore it. Real Worker WireValues and WirePacketPair send
unpacked dynamic and closed packets through the Wire codec. Existing Any.js
packet-helper behavior is unchanged. The helper's freshness proof and emitter
have their own ordinary ownership body pin; this grants no intrinsic exemption.

**What I learned**

The initial defineProperty implementation had a repeatable helpers/components
slowdown. CPU profiles found roughly 450–474 ns/message of packet helper self
time. Literal Symbol definition recovered only part of it. Constant identity
concatenations already folded in V8; shared unpack did not become a hot call.
Caching the Symbol key alone, reordering fields alone and removing the unused
component identity argument did not produce a reproducible improvement.

Copying cold Symbol metadata moved computed own-property definition out of
render. Short-window profiles then isolated residual view/section time. V8
probes showed fast properties, and same-browser heap snapshots showed current
and prepared payloads both 28-byte objects with in-object fields and no property
backing array. The baseline arrays used separate element stores. The residual
was not a dictionary-mode or hidden second-object allocation finding.

Exclusive self-time in the metadata-copy profiles (ns/message; 120 profiles,
two reversed passes) located helper Main.section at 7.9 → 59.4 and Main.view
at 38.5 → 49.7. Components Main.p1046 was 704.5 → 785.1 and Card.section
23.0 → 44.5; GC was flat (1479.5 → 1475.1). The emitted view changed from
CreateArrayLiteral to CloneObject plus DefineNamedOwnProperty for its capture
field. Preparing that existing field alone was then priced separately; it
keeps the hot expression and one payload allocation unchanged.

Preparing named slots alone was priced against both metadata-copy and exact
base, twice with reversed subject pairs, 15 independent pages/pass. Development
components changed from +9.4% [1.0,18.4] to +2.8% [-1.6,5.4] versus base; helpers
were -0.3% [-4.4,3.4]. Release preparation regressed helpers at 4x by +2.5%
[0.5,5.2] versus Symbol-only metadata, so it was rejected for release. These are
candidate prices; final compiler evidence is recorded separately below.

The core pack maker also needs the actual lowering registry: otherwise its
checker keys differ from the compiler's, producing spurious core rechecks and
ownership dump changes. The fix retains one maker per registry and leaves the
ownership expectations intact. A missing MarkupOperands rule-inventory entry is
included. General computed-property IR support covers both printers, Spec and
suspend cloning; its comma-key grammar is pinned by their equivalence test.

**Validation**

Final benchmark attribution pending. Focused packet/identity fixtures, the
external lowering and real Wire Chrome cases pass twice on compiler
552136234697c47ff51c725b5b6b0f23. Exact base is workers-hostfree
4a36377862c7c74166590843265b6a19936e9324, including the separately merged
trie-reader fix #1787 and the typed Worker state/events and library export
fixes. Base compiler: 3f430e90985d60fd4d3be22cbe6c641f.

Rebuilt all ten base benchmark subjects. Development is byte-identical to the
previous 5c artifacts, but release JS changed, so old release timing reuse was
rejected. Final measurements rerun both modes against the new exact base.
Evidence is under ~/worktree-evidence/wd-hf-dom/packet-benchmark/final-4a36377862/;
profiles and isolated candidate prices remain under final-5c1b416ef1/.

The newly upstreamed WorkerEventsLeaf release golden also captures the model.
Its page now has the same array-to-packet change as the DOM goldens. Reviewed
the complete emitted AST modulo binding renames: after reverting exactly that
payload/read and its cold metadata constant, the only remaining changes are
one compact identity relabel and the transport fingerprint. The fingerprint
hashes module source bytes, including the changed Rt; its worker-entry golden
changes only that matching fingerprint. No worker behavior was altered. The
narrow fixture passes twice after refreshing those two expectations.

Final correctness attribution is complete on that exact base: base and after
both reproduce 32 named and 229 corpus failures twice, with identical failure
sets and no panic or segmentation fault. No inherited golden was changed to
get green. Own focused suites and Chrome DOM/Wire cases pass twice. #1785's
five row repros give 20 nonempty before/expected transcript differences (five
fixtures, development/release, twice); the fixed fixtures pass twice.

Both full benchmark passes completed: 1,620 table samples across all nine
operations, keyed/positional, development/release and Solid 2; and 840 static
rows across inline/helpers/components, both modes, 1x/4x and Solid controls.
Every full-run script interval includes zero. The removal paint/total positive
did not reproduce in two isolated N20 passes (total +0.2% [-1.2,1.6], paint
-0.1% [-1.3,1.6]). Cold-first positives also include zero in two official
harness follow-ups. First-only CPU profiles cover 320 fresh pages and show no
new hot shared-unpack frame. They are diagnostic, not replacement benchmarks.

Acceptance is still held: pooled helpers release 4x steady script is +2.01%
[0.97,3.65] over 130 pages. Numeric/undefined slot hints give no reliable direct
win; putting the metadata spread last is slower by +2.69% [0.96,4.85] on
helpers 4x; Object.assign gives no reliable helper gain and slows components
1x. Those are isolated artifact prices and were rejected without source edits.
A same-ABI private-constructor candidate is being priced separately; it is not
the production implementation. No performance waiver or push is claimed.

Full and scoped hash recordings each reproduce twice. Per-record/occurrence
attribution retains 966 verified channel records in 344 files and restores
1,375 inherited-only records. Duplicate development records are legitimate.
The scoped Zig name filter omits corpus; corpus verification comes from the
full recordings, while scoped recordings update only packet scenario hashes.
Every retained new record is present in both successful verification outputs.
Evidence: best/hash-attribution.json and best/hash-record-integrity.json.
