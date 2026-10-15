## 2026-10-15 20:47 CEST — Diagnose the ownership kernel replay failure

**What I did**

- Corrected two proof elaboration errors in the construction and observer witnesses.
- Read the next build failure after all three witness modules compiled.
- Traced the missing private constant to Lean's duplicate equation theorem imports.
- Opened issue #182 for the general audit defect.
- Added one witness import chain after the existing proof modules.
- Kept all theorem statements and audit checks unchanged.

**What I learned**

- Lean can import a later theorem body but retain the first module index.
- The replay audit then selects imports that omit the body's private splitter.
- The import-chain change still needs the Lean build, ownership CI, and Zig gates.
- The sandbox still rejects shell startup on `.agents -> .claude`, despite the added writable dispatch root.
