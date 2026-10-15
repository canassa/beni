## 2026-09-22 21:06 CEST — Schema S2 checker, interfaces and emit boundary

**What I did**

- Pulled `021f331`, specified schema.md A.6, and used three Sol agents for
  checker/resolution, plan/cache contracts and black-box fixtures while managing
  integration and validation. Committed and pushed the public `core/Schema`
  type surface (`2d2c0e7`) and the fail-first row 70 brace-modifier fix
  (`875f623`), each with all three gates green.
- Implemented schema namespaces, both endpoint families, generic member schemes,
  conversion checks, constructor patterns and immutable resolved plans. Published
  schema interface v2, frontend artifact v3, cache entry v2 and plan v1. Moved
  the S1 wall to emit: schemas check, but build refuses before output until S4.
- Added 36 new/moved corpus cases across the three commits, with complete member
  goldens and exact diagnostics; upgraded the schema BIR conversion dependency
  golden deliberately. Added persistent firewall, alpha-rename and malformed-plan
  repair coverage. Updated schema status, CLAUDE.md and the queue.
- Reversed only the source patch, never stashed, rebuilt and tested the exact
  baseline. Confirmed the expected new failures and byte-identical old
  SchemaUnsupported refusal. Repeated the source reversal after final fixes,
  verified the same baseline and reapplied exactly. The detailed evidence and
  fixture list are in [schema-s2-validation.md](schema-s2-validation.md), including
  the corrected test-only typo and discarded zero-test filtered invocations.
- Final restored-tree gates: 468/468 unit tests, 287/287 black-box tests (including
  determinism, round-trips and release execution), fmt-check green. Independent
  cache runs checked 13/0/1/2 modules for cold/warm/private-edit/public-edit;
  private edits preserved serialized interface bytes and stopped at the firewall.
  Appended this entry without changing prior diary entries; left user-owned
  `.agents` and `AGENTS.md` untouched.

**What I learned**

- Cached frontend tokens omit payloads: namespace candidate resolution must
  recover spelling from stable token positions and source bytes. Ambiguity
  requires two valid complete paths, not merely a shared root identifier.
- Private endpoint definitions and settled capabilities must survive cache hits,
  while executable conversion bodies stay outside interface hashing. Generic
  parameter spellings must also remain unhashed so alpha-renames preserve the
  firewall.
- Rejecting a semantically invalid plan requires clearing the loaded entry slot
  and cutoff hit state as well as freeing its payload; otherwise the canonical
  repaired entry is not written. The malformed-plan black-box test proves both
  the miss and exact repair.
- A focused Zig test filter placed after a dependency module can run zero root
  tests. Counted execution, not an empty successful log, is the evidence; the
  corrected focused tests and full final suite passed.
- Found two separate schema-free baseline defects and recorded, rather than
  fixed, queue rows 71–72: imported ordinary arities above 255 and derived
  wrapper equality ignoring a payload type's custom public `eq`.
