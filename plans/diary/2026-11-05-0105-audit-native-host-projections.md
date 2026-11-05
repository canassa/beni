## 2026-11-05 01:05 CET — Audit native host projections

**What I did**

Reviewed and re-pinned 31 generated public/private native projections, their lowering and projection metadata under ownership-checker §24.8. Public ownership words and their existing observable flips remain. Private declarations are catalogued through the existing public fixture names; their JS bodies, inline code and metadata are pinned without weakening the body audits.

Corrected Event.error's documented null-or-undefined absence mapping after the existing renderer-adapter runtime fixture caught a null reason being displayed instead of falling back to the event message. Its unknown-error identity assertion still passes. A deliberately invalid Map.get signature now has both the ordinary wrapper-body type error and the native-contract refusal; the test checks both. Rebuilt two library module goldens only after proving the preserved base matched their committed bytes, and updated the two narrow ownership/representation goldens caused by the new typed wrappers.

**What I learned**

A new beni wrapper must participate in the existing ownership body and trusted-surface audits, in addition to its private foreign operation. Compiler intrinsic pins must cover both the native reader and the table selecting its projection. Shared public bounds remain important when private helpers cannot be independently named by a consumer.
