## 2026-10-23 12:54 CEST — cost 3 of #844 has no smaller shape

**What I did.** After #876 (#874), I tried the shape that #844 names for its cost 3. A piece marks
a handler that its `$$on` wiring reads inside its own closure (a payload's adapter, a flagged
listener, or a second event), and the program site makes that handler a `const` of the mount, all
of them before the first wiring. Release then inlines every wiring piece, and the output has the
pre-#610 shape. On a fixture of four unique widgets, single-file brotli 11: function form (master)
2849 B raw, 1037 B br; named and inlined 2777 B raw, 1043 B br. #844's repro went 756 → 749 B and
`ArmSingle` went 476 → 473 B. I priced one more shape by hand, the payload extraction moved into the
handler body so that the handler goes to `on` bare: 1036 B inlined, 1038 B in function form. That
is no gain, and it would need a new interface hook. I merged nothing. The patch, the fixture and the
outputs are in `~/worktree-evidence/s1-arm-on/` on dagon, and the table is on #844.

**What I learned.** In unique-components every piece's wiring is used once, and the function form
still compresses better. Its body is the same text in each widget's piece, because each piece
names its parameters `a`, `b`, `c` again. Inlined, each copy gets its own short names, so brotli
finds fewer repeats. A raw saving from inlining is not a brotli saving when the inlined bodies were
the repeats. Two attempts from two sides (`Spec.inlineAt`'s bind and the program site's names)
agree. The "+1.5 B/widget" of cost 3 was what remained after costs 1 and 2, not a measured
inlining cost.
