## 2026-10-22 15:20 CEST — Exact full-type ownership casts

**What I did**

Resumed #712, Part of #286. Specified the full-type cast rules as dated amendments,
then implemented exact first boundaries and repeated-full-type folds. Structural
keys are an interned type graph, with portable variable scopes and summary format
24 after the written-element condition changes. Generic calls substitute the whole
type, including open record rows. Rebased through the concurrent ownership work.

Completed the trailing-cast identity, folded-occurrence and portable-key audit.
Added regressions for an incompatible folded holder and a repeated wide projection;
both failed before their fixes. Added FullCast, imported/cached casts, a fresh
consumer of a cached generic provider, and the original wide-condition input with
an aliasing twin. Retired the width refusal through the complete indexed check.

On dagon, the full unit, black-box and formatting checks pass with instruction
budgets disabled at the owner's request. Additional full cross-checks pass for
core, the ownership/core corpus, WideDeepCondition and SchemaAnswers. Core has
117 accepted list lines, none pending or rejected. Existing record staging debts
are unchanged. The wider cross-check's two unrelated failures reproduce on
unchanged master and are already tracked as #427 and #694. No local Zig, LLVM,
performance measurements or budget-grant changes.

**What I learned**

An exact cast boundary names one place; treating it as a representative made
Schema's first Maybe/Nullable reads approximate. Trailing casts retain physical
identity even when the viewed types differ. Folded reads must retain incompatible
concrete holders approximately, and a wide projection must decide its fallback
before inserting a cache entry.

A nominal canonical abbreviation can consume the existing path cut before its
expanded facts when composed with a cast prefix. Cast-bearing summaries keep those
expanded facts, preserving the unchanged canonical/expanded audit. The separate
removal of the path cut is still outstanding.
