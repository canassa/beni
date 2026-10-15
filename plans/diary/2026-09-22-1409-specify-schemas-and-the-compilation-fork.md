## 2026-09-22 14:09 CEST — Specify schemas and the compilation fork

**What I did**

Pulled first (already up to date), read the schema owner decisions and research
against the existing contracts, and wrote `docs/design/schema.md` as a new
normative delta rather than revising report 32. Recorded the description plus
specialised parse/print fork, the five guarantees, engine-owned context,
namespace/interface elaboration, codegen/DCE, diagnostics, effects obligations
and five slices. Twelve open questions lead the document with recommendations
and costs; their dependent rules remain conditional. Added one pointer each in
language/checker/backend/boundary, appended the diagnostic codes, wired CLAUDE.md
and the queue, and preserved all existing section headings. Replaced positional
labels in the language diagnostic table with code names so appended rows do not
make them false. No production code or benchmark capture changed.

Ran temporary grammar/resolution probes against the installed binary, including
qualified types, explicit schema arguments, contextual words, real-module
constructor patterns, namespace exposure and recursive aliases. Checked local
links and whitespace. `nix develop --command sh -c 'zig build test && zig build
test-blackbox && zig build fmt-check'` passed, exit 0. The existing untracked
`.agents` and `AGENTS.md` are outside the staged set. No measurement run was made.

**What I learned**

Multi-segment qualified names and constructor patterns already work for actual
modules; that proves neither schema namespace exposure nor schema elaboration.
The input schema's Encoded need not equal the intermediate type consumed by a
via conversion, so Q1 now has a concrete conditional signature with an explicit
program endpoint. Context cannot be a convention for arbitrary endpoint authors:
the engine must own it on both compiled and dynamic paths, including mixed paths.
Report 34's size/startup observations support the fork but not a universal speed
ratio; fused-codec and optional Effect-compiler rows remain owed. The effects
plan has no H4 heading, and a separate imported primitive-alias probe rejected a
numeric literal; queue rows 66–68 preserve those findings and the representation
proof still owed. M4 slices 1–3 are already marked done, so the scheduling
question asks where schemas enter the recorded sequence without inventing a
requirement to finish every remaining M4 slice first.
