## 2026-10-30 20:38 CET — worker compiler foundations

**What I did**

Implemented the first independent compiler checkpoint on PR #1304, on Dagon
with development compiler builds. Code commit d61f2d338 contains generic
non-markup entry contracts, a Session-owned resolved entry plan, a typed private
Buffer primitive and its real Zig-generated sibling, the offline pinned native
catalogue generator, and the corrected prerender export-root model. Worker
launching remains gated on complete realm, Wire and ownership proofs.

Specified the emitter/typed-runtime/native generation work before its code.
Reviewed every agent delta and independently validated integration. Fixed
nominal Program identity (#1337), actual prerender exports (#1338), Buffer
intrinsic namespace isolation (#1339), closed callback rows (#1340), exposure
attribute keys (#1341), dangling physical override precedence (#1342), rejected
plan diagnostic preservation (#1347), and required metadata fields (#1353).
The six decided entryKinds keys are explicit; missing tables fail check/build.

The source archive is SHA-verified and contains 346 files. The catalogue has
3,676 declarations, 11,621 members, 1,165 nominal types and 631 upcast rows.
Corrected the earlier regex member count: a quoted http URL in a dictionary
field had been mistaken for a comment. All members remain adapter_required;
metadata is not a callable native API or a realm proof.

Full run-hash recording and full unfiltered zig build gates passed on the exact
checkpoint tree before its code commit. The Buffer and generic-runtime checks
include development/release execution, core override authority and cached
rechecks. No existing Inline source, ABI or inline corpus output changes land
in this checkpoint. The initial forced-record run exposed the unchanged HTTP
abort race already tracked in #515/#701/#927; emitted trees were byte-identical
to baseline, the assertion was retained, and subsequent full recording passed.

Held the typed Inline migration out of this checkpoint. Its candidate passes
behavior tests including real Chromium and individually meets all 55 original
release byte goldens, but a controlled direct-send microprobe found a measurable
cost. No timing/parity claim or waiver was accepted. Further count-based runtime
work and applicable UI measurements continue under #1343 on the same PR.
A symbolic typed-slot prototype establishes ordinary typing under polymorphic
recursion, not an accepted Task ABI: eager allocation and boxed control remain
unaccepted. Task's paired compiler/runtime rewrite is still pending.

**What I learned**

The stop condition concerns an undecided decision or sacrificed guarantee/budget,
not the size of an authorized restructure. An isolated timing result is evidence
to investigate against the actual contract; raw-byte wins do not prove runtime
parity. Independent foundations can be validated and pushed without publishing
an unfinished queue or unchecked worker launcher. Agents clean their owned lanes
after retrieval; active manager and performance lanes remain until their work
is retrieved and complete. All scratch stays under owned home cache paths.
