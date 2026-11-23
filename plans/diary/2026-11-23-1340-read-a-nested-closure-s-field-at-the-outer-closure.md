## 2026-11-23 13:40 CET — read a nested closure's field at the outer closure

**What I did.** Fixed #2617, a miscompile of records written in place. A closure
inside a closure that reads a field of a captured record had its eager read
(§31.6) placed at the inner closure's creation. The inner closure is made when
the outer one runs, after the update's store, so the program read the new
value. `own/Ownership.zig` now carries such a read out to the outermost closure
made in the holder's frame and lists it there alone; the lowering's hoist
already serves every closure inside it through lexical scope. A local function
made inside a closure has its reads of outer locals carried out the same way,
and one made in the holder's frame that returns closures has its read at the
outermost closure in its body. `Lower.hoistedRead` panics under runtime safety
when one source read has two live temporaries, so this class crashes the
compiler instead of miscompiling. §31.6 has an amendment and §31.14 a clause.
Fixtures: `run/RecordReadNestedClosure` (`.in-place`) and
`browser/inline/RecordReadNestedClosure`, both failing on master (the
sanitiser traps; the page sends new values) and passing after. One ownership
golden lost its inner `capture` line.

**What I learned.** The adversarial reviewer broke the first version twice
with local functions: one that returns a closure in a closure, and one made
inside a `Cmd.perform` body (a common TEA idiom). The remaining hole is #2620:
a local function made in the holder's own frame, called after the write, reads
the new value; no use of the field is recorded at its call. The v3 prototype
lowers with the same `placeHoists`/`hoistedRead`, but from its own rows
(`own3/Reads.zig`), which have no capture, so this fix does not reach it.
