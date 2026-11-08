## 2026-11-08 10:07 CET — keep host-made sends through erased types

**What I did**

- Reproduced #1697 on master 887f7fb9ab. It occurs only for a monomorphic class: a `Sub.on` start or a `Cmd.perform` body written as a lambda in `main`. A top-level start, or a body inside `update`, is generalised, and the lowering keeps the call.
- Added `browser/inline/SubStartSends` and `browser/inline/PerformSends`. On master, release shows `""` and `"y"`; on the branch, `"x"` and `"xy"`.
- Amended `transparent-effects-proposal.md` §14.3 rule 6 and §14.6. Built it in `src/check/Erasure.zig`: a type variable that occurs once in a `foreign`'s signature carries the side of the boundary (interface format 23), and each use raises the function types that the host makes inside the instantiation to `impure`. An `entry` record parameter is walked the same way, and there a returned nominal value (`Cmd msg`) is raised too.
- Moved `foreignSummary` to `src/check/EffectsForeign.zig`, because `Effects.zig` was at the 1 500-line limit.
- Filed #2258: an `update` with a constructor pattern in its parameter reads the field twice on browser-inline.

**What I learned**

- `Sub.on`'s `Js.from start` does not matter at run time: the inline lowering calls `start` itself. The effect classes still flow through `Sub.on`'s type, so the erasure rule fixes it. `Cmd.perform` has no erasure at all; only the `entry` word on `Tea.element` connects the program's `Cmd` to the runtime.
- Core's `List` erases elements (`Js.from x`) and callbacks. Two first versions were too wide: marking a variable that the erased value only holds, and raising a received nominal value, each made `Url.Parser.oneOf` impure and refused three prerendered pages.
- The release output of every `examples/` application and of 340 `browser/` pages is byte-identical to master's.
