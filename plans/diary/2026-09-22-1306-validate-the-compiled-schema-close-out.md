## 2026-09-22 13:06 CEST — Validate the compiled-schema close-out

**What I did**

- Independently rechecked the final report against the selected capture: the
  four generated timing blocks match byte for byte; every bundle, startup,
  time-to-first-validation, CSP, flip-endpoint, partial-order and Zod-ratio cell
  matches the retained raw observations at the documented rounding.
- Recorded the manager's final validation result: the second complete run of
  `zig build test`, `zig build test-blackbox` and `zig build fmt-check` exited
  zero after the final capture and documentation work.

**What I learned**

- Keeping generated descriptive tables mechanically reproducible and checking
  derived prose claims separately caught the important distinction between an
  unbundled flat-entry import and execution of its tree-shaken browser bundle.
  Both are useful measurements, but they are not the same startup surface.
