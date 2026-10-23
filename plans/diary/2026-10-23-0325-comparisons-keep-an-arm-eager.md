## 2026-10-23 03:25 UTC — comparisons keep an arm eager

**What I did.** Broke down #610's size cost on unique-components (#844). Seed 1–3, N = 16 to 64,
brotli 11: pre-#610 254.9 B/widget, master 262.4. Most of it is arms that #610 guards although their
values are pure and total: `valuePureTotal` refused every `method_call`, and `==`, `≠`, `<`,
`>` are `method_call`s, not `.call`s, so #645/#840's total-call rule never reached them. The
lowering now asks the same question the checker's `Totality.termTarget` answers
(`Lower.methodCallTotal`). Measured: 262.4 → 259.6. New fixtures `browser/inline/ArmOperators`
(the page, the same transcript before and after) and `emit/release/inline/ArmOperators` (red before).

**What I learned.** The rest of #610's cost is the inline arm test of each handler inside an arm
(about 2 B/widget, a guarantee whose shape can move into the runtime's `on`), and the `$$on`
piece that release no longer inlines. Binding the handler arguments in `Spec.inlineAt` so the piece
inlines made the output 14 B/widget smaller raw but 2.6 B/widget larger after brotli: measure
brotli, never raw, before keeping a shape.
