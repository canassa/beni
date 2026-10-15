## 2026-09-22 15:33 CEST — Schema S1 frontend, implemented by Sol agents

**What I did**

Managed three Sol agents for implementation, fixtures and formatter/AST work,
then independently reviewed and validated the integrated slice. Specified the
unresolved BIR plan, formatter layout and temporary pre-resolution refusal
before the corresponding implementation. S1 now parses schema declarations,
fields/modifiers, tagged unions, generic operands and recursive references;
formats them; and preserves their unresolved structure in AST/BIR dumps and
frontend artifact v2. Check/build and later dumps explicitly refuse schemas
until S2. No endpoint typing, library codec or specialised runtime landed.
Updated CLAUDE, schema status and the queue; row 67 remains a prerequisite for S2.

Added 14 corpus fixtures and three focused black-box scenarios. Independently
confirmed fail-first behavior with the saved pre-S1 binary, exact success
outputs, 49 truncated-source probes, over-depth diagnostics, sibling recovery
and all five later dump refusals. Final gates: `zig build test` 464/464,
`zig build test-blackbox` 283/283, and `zig build fmt-check` green. Document
links, stable numbered sections, unchanged G1–G5 and `git diff --check` passed.
No schema benchmark measurements were run.

**What I learned**

Integration review found real failures before acceptance: AST accessor gaps,
recursive formatter/dumper frame growth, a variant-rename representation
mismatch, detached field docs, lost siblings after malformed fields, missing
rename strings reaching a string-node assertion, and secondary “not a module”
errors after the temporary refusal. These were fixed and covered. The refusal
must precede resolution and survive cache reloads; malformed schema payload
ranges also need verification at the artifact boundary.

The first full black-box run failed twice because an empty, untracked
build/bad/SchemaUnsupported directory remained after relocating that fixture.
The corpus and matrix each treated it as a project. Removed only that empty
directory and reran the full black-box gate successfully; no compiler change
was needed. Directory-based harnesses require directory cleanup, not just file
cleanup. The remaining schema decisions and row 67 were not folded into S1.
