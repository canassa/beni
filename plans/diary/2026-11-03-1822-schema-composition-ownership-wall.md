## 2026-11-03 18:22 CET — Schema composition ownership wall

**What I did**

Applied the owner's #1790 deferral of endpoint projections to the #1789 spec draft. Drafted worker composition for runtime record/tagged/recursive builders and removed the generic value interpreter and forced-library compiler options. Captured baseline benchmark output. Stopped the watcher and reproduced the core-check failure with a one-shot build. Saved the candidate patch and failure evidence for manager triage.

**What I learned**

The draft's tagged closure cannot pass ownership checking: an opaque child worker may change a callback-supplied boxed input after a call whose result can retain it. A smaller standalone example passes, so this has not been established as a compiler defect. No ownership words, primitive or interpreter fallback was added to bypass the check. The broad schema-size sweep also needs explicit sibling-source enumeration before its results can support a comparison. Implementation and validation remain incomplete; rule 10 requires reporting the wall.
